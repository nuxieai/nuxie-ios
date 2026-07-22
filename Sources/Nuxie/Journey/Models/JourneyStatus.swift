import Foundation

/// Status of a journey through its lifecycle
public enum JourneyStatus: String, Codable {
    /// Journey created but not yet started
    
    /// Journey is actively executing nodes
    case active = "active"
    
    /// Journey is waiting (for time, event, or condition)
    case paused = "paused"
    
    /// Journey reached a natural exit
    case completed = "completed"
    
    /// Journey timed out or expired
    
    /// Journey was manually cancelled or replaced
    case cancelled = "cancelled"
    
    /// Check if journey is in an active state (can still progress)
    var isActive: Bool {
        switch self {
        case .active, .paused:
            return true
        case .completed, .cancelled:
            return false
        }
    }
    
    /// Check if journey is in a terminal state (cannot progress)
    var isTerminal: Bool {
        !isActive
    }
    
    /// Check if journey is live (running or paused, but not terminal)
    var isLive: Bool {
        switch self {
        case .active, .paused:
            return true
        case .completed, .cancelled:
            return false
        }
    }
}

/// Reason why a journey exited
public enum JourneyExitReason: String, Codable {
    /// Journey reached an exit node naturally
    case completed = "completed"

    /// User dismissed the flow before a natural terminal exit
    case dismissed = "dismissed"
    
    /// Campaign goal was achieved
    case goalMet = "goal_met"
    
    /// No longer meets trigger criteria
    case triggerUnmatched = "trigger_unmatched"

    /// Server-configured exit node with reason "expired"
    case expired = "expired"
    
    /// Journey timeout reached
    
    /// Manually cancelled (user change, etc)
    case cancelled = "cancelled"
    
    /// Unrecoverable error occurred
    case error = "error"
}

// Legacy workflow execution types removed (Experience FSM handles execution state)

extension JourneyExitReason {
    /// Maps an exit action's reason string onto the exit-reason enum;
    /// unknown or absent reasons default to `.completed`.
    static func fromActionReason(_ reason: String?) -> JourneyExitReason {
        switch reason {
        case "dismissed":
            return .dismissed
        case "goal_met":
            return .goalMet
        case "trigger_unmatched":
            return .triggerUnmatched
        case "expired":
            return .expired
        case "error":
            return .error
        case "cancelled":
            return .cancelled
        default:
            return .completed
        }
    }
}
