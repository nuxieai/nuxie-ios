import Foundation

/// URLProtocol subclass for intercepting and stubbing network requests in tests
final class StubURLProtocol: URLProtocol {
    
    // MARK: - Types
    
    typealias Matcher = (URLRequest) -> Bool
    typealias Handler = (URLRequest) throws -> (HTTPURLResponse, Data?)
    
    // MARK: - Static Properties
    
    // nonisolated(unsafe): only accessed under `lock`.
    private nonisolated(unsafe) static var handlers: [(Matcher, Handler)] = []
    private static let lock = NSLock()
    
    // MARK: - Registration
    
    /// Register a matcher and handler for intercepting requests
    static func register(matcher: @escaping Matcher, handler: @escaping Handler) {
        lock.lock()
        defer { lock.unlock() }
        handlers.append((matcher, handler))
    }
    
    /// Reset all registered handlers
    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        handlers.removeAll()
    }
    
    // MARK: - URLProtocol Overrides
    
    override class func canInit(with request: URLRequest) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return handlers.contains { $0.0(request) }
    }
    
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }
    
    override func startLoading() {
        Self.lock.lock()
        let match = Self.handlers.first { $0.0(request) }?.1
        Self.lock.unlock()
        
        guard let handler = match else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        
        // Try to read body from stream if httpBody is nil
        var mutableRequest = request
        if mutableRequest.httpBody == nil, let bodyStream = request.httpBodyStream {
            bodyStream.open()
            defer { bodyStream.close() }
            
            var data = Data()
            let bufferSize = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }
            
            while bodyStream.hasBytesAvailable {
                let bytesRead = bodyStream.read(buffer, maxLength: bufferSize)
                if bytesRead > 0 {
                    data.append(buffer, count: bytesRead)
                } else if bytesRead < 0 {
                    break
                }
            }
            
            mutableRequest.httpBody = data
        }
        
        do {
            let (response, data) = try handler(mutableRequest)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let data = data {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    
    override func stopLoading() {
        // No-op for our stub implementation
    }
}

// MARK: - Helper Extensions

extension StubURLProtocol {
    
    /// Register a simple success response for a URL path
    static func registerSuccess(
        path: String,
        data: Data,
        statusCode: Int = 200,
        headers: [String: String]? = nil
    ) {
        register(
            matcher: { $0.url?.path == path },
            handler: { request in
                var allHeaders = headers ?? [:]
                if allHeaders["Content-Type"] == nil {
                    allHeaders["Content-Type"] = "application/json"
                }
                
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: statusCode,
                    httpVersion: nil,
                    headerFields: allHeaders
                )!
                return (response, data)
            }
        )
    }
    
    /// Register a simple error response for a URL path
    static func registerError(
        path: String,
        error: Error
    ) {
        register(
            matcher: { $0.url?.path == path },
            handler: { _ in throw error }
        )
    }
    
    /// Register a JSON response for a URL path
    static func registerJSON<T: Encodable>(
        path: String,
        response: T,
        statusCode: Int = 200
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(response)
        
        registerSuccess(
            path: path,
            data: data,
            statusCode: statusCode,
            headers: ["Content-Type": "application/json"]
        )
    }
    
    /// Register handler for specific HTTP method and path
    static func register(
        method: String,
        path: String,
        handler: @escaping Handler
    ) {
        register(
            matcher: { $0.httpMethod == method && $0.url?.path == path },
            handler: handler
        )
    }
    
    /// Register handler with custom validation of request body
    static func registerWithBodyValidation(
        path: String,
        bodyValidator: @escaping (Data?) -> Bool,
        handler: @escaping Handler
    ) {
        register(
            matcher: { request in
                guard request.url?.path == path else { return false }
                
                // Handle both regular and gzipped bodies
                var bodyData = request.httpBody
                if let body = bodyData,
                   request.value(forHTTPHeaderField: "Content-Encoding") == "gzip" {
                    // Try to decompress gzipped data for validation
                    bodyData = try? body.gunzipped()
                }
                
                return bodyValidator(bodyData)
            },
            handler: handler
        )
    }
}