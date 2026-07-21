import Foundation
import Network

// @unchecked Sendable: `baseURL` is written only by the listener state
// handler during init (before concurrent use); connections are handled on the
// private serial `queue`.
final class LocalHTTPServer: @unchecked Sendable {
    struct Request {
        let method: String
        let path: String
        let query: [String: String]
        let headers: [String: String]
        let body: Data
    }

    struct Response {
        let statusCode: Int
        let headers: [String: String]
        let body: Data

        static func text(
            _ text: String,
            statusCode: Int = 200,
            headers: [String: String] = [:]
        ) -> Response {
            var responseHeaders = headers
            responseHeaders["Content-Type"] =
                responseHeaders["Content-Type"] ?? "text/plain; charset=utf-8"
            return Response(statusCode: statusCode, headers: responseHeaders, body: Data(text.utf8))
        }

        static func html(_ html: String, statusCode: Int = 200) -> Response {
            Response(
                statusCode: statusCode,
                headers: ["Content-Type": "text/html; charset=utf-8"],
                body: Data(html.utf8)
            )
        }

        static func json(_ data: Data, statusCode: Int = 200) -> Response {
            Response(
                statusCode: statusCode,
                headers: ["Content-Type": "application/json; charset=utf-8"],
                body: data
            )
        }
    }

    typealias Handler = (Request) -> Response

    private let handler: Handler
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.nuxie.tests.local-http-server")

    private(set) var baseURL: URL

    init(handler: @escaping Handler) throws {
        self.handler = handler
        self.listener = try NWListener(using: .tcp, on: .any)
        self.baseURL = URL(string: "http://127.0.0.1:0")!

        let ready = DispatchSemaphore(value: 0)

        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let port = self?.listener.port?.rawValue {
                    self?.baseURL = URL(string: "http://127.0.0.1:\(port)")!
                }
                ready.signal()
            case .failed(_), .cancelled:
                ready.signal()
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }

        listener.start(queue: queue)

        _ = ready.wait(timeout: .now() + 2)
        if baseURL.port == 0 {
            throw NSError(
                domain: "LocalHTTPServer",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to start listener"]
            )
        }
    }

    deinit {
        stop()
    }

    func stop() {
        listener.cancel()
    }

    // MARK: - Connection handling

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveHeaders(connection, buffer: Data())
    }

    private func receiveHeaders(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, error in
            guard let self else { return }
            if error != nil {
                connection.cancel()
                return
            }

            var nextBuffer = buffer
            if let data {
                nextBuffer.append(data)
            }

            guard let headerRange = nextBuffer.range(of: Data("\r\n\r\n".utf8)) else {
                self.receiveHeaders(connection, buffer: nextBuffer)
                return
            }

            let headerData = nextBuffer[..<headerRange.lowerBound]
            let remaining = nextBuffer[headerRange.upperBound...]

            guard let request = self.parseRequest(headerData: headerData, bodyData: Data(remaining)) else {
                self.send(connection, response: Response.text("Bad Request", statusCode: 400))
                return
            }

            let contentLength = Int(request.headers["content-length"] ?? "") ?? 0
            if contentLength > request.body.count {
                self.receiveBody(
                    connection,
                    request: request,
                    expectedLength: contentLength,
                    buffer: request.body
                )
                return
            }

            let body = contentLength > 0 ? Data(request.body.prefix(contentLength)) : request.body
            let finalRequest = Request(
                method: request.method,
                path: request.path,
                query: request.query,
                headers: request.headers,
                body: body
            )

            let response = self.handler(finalRequest)
            self.send(connection, response: response)
        }
    }

    private func receiveBody(
        _ connection: NWConnection,
        request: Request,
        expectedLength: Int,
        buffer: Data
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, error in
            guard let self else { return }
            if error != nil {
                connection.cancel()
                return
            }

            var nextBuffer = buffer
            if let data {
                nextBuffer.append(data)
            }

            guard nextBuffer.count < 10 * 1024 * 1024 else {
                self.send(connection, response: Response.text("Request too large", statusCode: 400))
                return
            }

            if nextBuffer.count < expectedLength {
                self.receiveBody(
                    connection,
                    request: request,
                    expectedLength: expectedLength,
                    buffer: nextBuffer
                )
                return
            }

            let body = Data(nextBuffer.prefix(expectedLength))
            let finalRequest = Request(
                method: request.method,
                path: request.path,
                query: request.query,
                headers: request.headers,
                body: body
            )

            let response = self.handler(finalRequest)
            self.send(connection, response: response)
        }
    }

    private func parseRequest(headerData: Data, bodyData: Data) -> Request? {
        let headerString = String(decoding: headerData, as: UTF8.self)
        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, !requestLine.isEmpty else {
            return nil
        }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let target = String(parts[1])

        let comps = URLComponents(string: "http://localhost\(target)")
        let path = comps?.path ?? target

        var query: [String: String] = [:]
        for item in comps?.queryItems ?? [] {
            if let value = item.value {
                query[item.name] = value
            }
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.isEmpty { continue }
            guard let idx = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }

        return Request(method: method, path: path, query: query, headers: headers, body: bodyData)
    }

    private func send(_ connection: NWConnection, response: Response) {
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = "close"

        let reason = reasonPhrase(for: response.statusCode)
        var headerLines = "HTTP/1.1 \(response.statusCode) \(reason)\r\n"
        for (key, value) in headers {
            headerLines += "\(key): \(value)\r\n"
        }
        headerLines += "\r\n"

        var payload = Data(headerLines.utf8)
        payload.append(response.body)

        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        default: return "OK"
        }
    }
}
