import Foundation

public enum NuxieNetworkError: LocalizedError, Sendable {
    case invalidResponse
    case httpError(statusCode: Int, message: String)
    case decodingError(Error)
    case timeout
    
    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response received"
        case .httpError(let statusCode, let message):
            return "HTTP \(statusCode): \(message)"
        case .decodingError(let error):
            return "Failed to decode response: \(error.localizedDescription)"
        case .timeout:
            return "Request timeout"
        }
    }
}