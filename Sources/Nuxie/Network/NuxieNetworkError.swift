import Foundation

enum NuxieNetworkError: LocalizedError, Sendable {
    case invalidResponse
    case httpError(statusCode: Int, message: String, retryAfter: String? = nil)
    case decodingError(Error)
    case timeout
    
    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response received"
        case .httpError(let statusCode, let message, _):
            return "HTTP \(statusCode): \(message)"
        case .decodingError(let error):
            return "Failed to decode response: \(error.localizedDescription)"
        case .timeout:
            return "Request timeout"
        }
    }

    var httpStatusCode: Int? {
        guard case .httpError(let statusCode, _, _) = self else { return nil }
        return statusCode
    }

    var retryAfter: String? {
        guard case .httpError(_, _, let retryAfter) = self else { return nil }
        return retryAfter
    }
}
