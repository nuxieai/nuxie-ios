import Foundation

/// SDK-level errors. Only cases with real throw sites exist — add cases when
/// you add the throw, not before.
public enum NuxieError: LocalizedError, Sendable {
    case notConfigured
    case invalidConfiguration(String)
    case eventRoutingFailed

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Nuxie SDK is not configured"
        case .invalidConfiguration(let reason):
            return "Invalid configuration: \(reason)"
        case .eventRoutingFailed:
            return "Event routing failed"
        }
    }
}
