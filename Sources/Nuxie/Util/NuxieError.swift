import Foundation

/// SDK-level errors. Only cases with real throw sites exist — add cases when
/// you add the throw, not before.
public enum NuxieError: LocalizedError, Sendable {
    case notConfigured
    case invalidConfiguration(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Nuxie SDK is not configured"
        case .invalidConfiguration(let reason):
            return "Invalid configuration: \(reason)"
        }
    }
}

/// Engine-only failure used while persisting or routing a captured event.
/// TriggerService translates it to the public TriggerError vocabulary.
enum EventRoutingError: LocalizedError, Sendable {
    case eventRoutingFailed

    var errorDescription: String? {
        "Event routing failed"
    }
}

/// Internal terminal outcome for an event rejected by the host's beforeSend
/// hook before it reaches persistence, delivery, or local trigger routing.
struct EventBeforeSendDropError: LocalizedError, Sendable {
    var errorDescription: String? {
        "Event dropped by beforeSend"
    }
}
