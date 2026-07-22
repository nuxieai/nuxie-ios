import Foundation

// MARK: - Goal Configuration

/// Configuration for campaign goals
public struct GoalConfig: Codable, Sendable {
    /// Types of goals supported
    public enum Kind: String, Codable, Sendable {
        case event = "event"
        case segmentEnter = "segment_enter"
        case segmentLeave = "segment_leave"
        case attribute = "attribute"
    }
    
    /// The type of goal
    public let kind: Kind
    
    /// Event name (required for event goals)
    public let eventName: String?
    
    /// Optional IR filter for event properties
    public let eventFilter: IREnvelope?
    
    /// Segment ID (required for segment goals)
    public let segmentId: String?
    
    /// IR expression for attribute goals
    public let attributeExpr: IREnvelope?
    
    /// Conversion window in seconds.
    /// - For `.event` goals: counts if the qualifying event's timestamp is within [anchor, anchor + window],
    ///   even if evaluation happens later (e.g., offline sync).
    /// - For `.segmentEnter`, `.segmentLeave`, `.attribute` goals: the condition must be met when evaluated
    ///   and before [anchor + window].
    public let window: TimeInterval?
    
    /// Initialize a goal configuration
    public init(
        kind: Kind,
        eventName: String? = nil,
        eventFilter: IREnvelope? = nil,
        segmentId: String? = nil,
        attributeExpr: IREnvelope? = nil,
        window: TimeInterval? = nil
    ) {
        self.kind = kind
        self.eventName = eventName
        self.eventFilter = eventFilter
        self.segmentId = segmentId
        self.attributeExpr = attributeExpr
        self.window = window
    }
}

// MARK: - Exit Policy

/// Policy for when a journey should exit
public struct ExitPolicy: Codable, Sendable {
    /// Exit modes
    public enum Mode: String, Codable, Sendable {
        /// Exit when goal is achieved
        case onGoal = "on_goal"
        
        /// Exit when no longer matching trigger conditions
        case onStopMatching = "on_stop_matching"
        
        /// Exit when either goal is met OR stop matching
        case onGoalOrStop = "on_goal_or_stop"
        
        /// Never exit early (run to completion)
        case never = "never"
    }
    
    /// The exit mode
    public let mode: Mode
    
    /// Initialize an exit policy
    public init(mode: Mode) {
        self.mode = mode
    }
}

// MARK: - Conversion Window Configuration

/// Default conversion window for campaigns.
public struct ConversionWindowDefaults: Sendable {
    /// Default window for deferred conversions (14 days)
    public static let defaultWindowValue: TimeInterval = 14 * 24 * 60 * 60

    /// Get the default window for any campaign type.
    public static func defaultWindow(for campaignType: String?) -> TimeInterval {
        _ = campaignType
        return defaultWindowValue
    }
}

// MARK: - Conversion Anchor Types

/// Types of conversion anchors supported
public enum ConversionAnchor: String, Codable, Sendable {
    /// Anchor to journey start
    case journeyStart = "journey_start"
    
    /// Anchor to last flow shown (default)
    case lastFlowShown = "last_flow_shown"
    
    /// Anchor to last flow handler (Phase 3)
    case lastFlowHandler = "last_flow_handler"
}
