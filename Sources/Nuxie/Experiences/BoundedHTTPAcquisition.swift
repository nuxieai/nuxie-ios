import Foundation

enum BoundedHTTPAcquisitionError: Error, Equatable {
    case httpStatus(Int)
    case declaredValueExceedsLimit(actual: Int, limit: Int)
    case valueExceedsLimit(actual: Int, limit: Int)
}

struct BoundedHTTPTransportError: Error {
    let underlyingError: Error
    let receivedByteCount: Int
}

struct BoundedHTTPDownload {
    let temporaryURL: URL
    let byteCount: Int
}

final class BoundedHTTPRedirectDelegate: NSObject, URLSessionTaskDelegate,
    @unchecked Sendable
{
    let validator: @Sendable (URL) -> Bool
    init(validator: @escaping @Sendable (URL) -> Bool) { self.validator = validator }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(request.url.map(validator) == true ? request : nil)
    }
}

/// Streams bytes through the caller's exact URL session into a bounded temporary file.
enum BoundedHTTPAcquisition {
    private static let writeChunkBytes = 64 * 1_024

    static func download(
        from url: URL,
        using urlSession: URLSession,
        maximumBytes: Int,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        allowsConstrainedNetworkAccess: Bool = true,
        responseValidator: (@Sendable (URLResponse) throws -> Void)? = nil,
        redirectValidator: (@Sendable (URL) -> Bool)? = nil
    ) async throws -> BoundedHTTPDownload {
        precondition(maximumBytes >= 0)
        try Task.checkCancellation()

        let requestSession: URLSession
        let derivedSession: URLSession?
        if let redirectValidator {
            let session = URLSession(
                configuration: urlSession.configuration,
                delegate: BoundedHTTPRedirectDelegate(validator: redirectValidator),
                delegateQueue: nil
            )
            requestSession = session
            derivedSession = session
        } else {
            requestSession = urlSession
            derivedSession = nil
        }
        defer { derivedSession?.finishTasksAndInvalidate() }
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            var request = URLRequest(url: url)
            request.allowsConstrainedNetworkAccess = allowsConstrainedNetworkAccess
            (bytes, response) = try await requestSession.bytes(for: request)
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw BoundedHTTPTransportError(
                underlyingError: error,
                receivedByteCount: 0
            )
        }
        var completedTransfer = false
        defer {
            if !completedTransfer {
                bytes.task.cancel()
            }
        }
        try Task.checkCancellation()
        try responseValidator?(response)
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw BoundedHTTPAcquisitionError.httpStatus(httpResponse.statusCode)
        }

        let declaredBytes = response.expectedContentLength
        if declaredBytes != NSURLSessionTransferSizeUnknown,
           declaredBytes > Int64(maximumBytes) {
            throw BoundedHTTPAcquisitionError.declaredValueExceedsLimit(
                actual: boundedInt(declaredBytes),
                limit: maximumBytes
            )
        }

        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        let temporaryURL = temporaryDirectory
            .appendingPathComponent("nuxie-http-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporaryURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: temporaryURL)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
        var shouldRemoveTemporaryFile = true
        defer {
            try? handle.close()
            if shouldRemoveTemporaryFile {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
        }

        var byteCount = 0
        do {
            var iterator = bytes.makeAsyncIterator()
            var buffer = Data()
            buffer.reserveCapacity(min(writeChunkBytes, maximumBytes))
            while let byte = try await iterator.next() {
                try Task.checkCancellation()
                guard byteCount < maximumBytes else {
                    throw BoundedHTTPAcquisitionError.valueExceedsLimit(
                        actual: incremented(byteCount),
                        limit: maximumBytes
                    )
                }
                buffer.append(byte)
                byteCount += 1
                if buffer.count == writeChunkBytes {
                    try handle.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
            }
            try handle.close()
            shouldRemoveTemporaryFile = false
            completedTransfer = true
            return BoundedHTTPDownload(
                temporaryURL: temporaryURL,
                byteCount: byteCount
            )
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            if error is BoundedHTTPAcquisitionError {
                throw error
            }
            if error is CancellationError {
                throw CancellationError()
            }
            throw BoundedHTTPTransportError(
                underlyingError: error,
                receivedByteCount: byteCount
            )
        }
    }

    private static func boundedInt(_ value: Int64) -> Int {
        value <= Int64(Int.max) ? Int(value) : Int.max
    }

    private static func incremented(_ value: Int) -> Int {
        let (result, overflowed) = value.addingReportingOverflow(1)
        return overflowed ? Int.max : result
    }
}
