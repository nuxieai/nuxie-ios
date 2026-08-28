import Foundation

// MARK: - Goal Configuration

/// Configuration for experience goals
struct GoalConfig: Codable, Sendable {
    /// Types of goals supported
    enum Kind: String, Codable, Sendable {
        case event = "event"
        case milestone = "milestone"
        case segmentEnter = "segment_enter"
        case segmentLeave = "segment_leave"
        case attribute = "attribute"
    }
    
    /// The type of goal
    let kind: Kind
    
    /// Event name (required for event goals)
    let eventName: String?
    
    /// Optional IR filter for event properties
    let eventFilter: IREnvelope?

    /// Milestone ID (required for milestone goals)
    let milestoneId: String?
    
    /// Segment ID (required for segment goals)
    let segmentId: String?
    
    /// IR expression for attribute goals
    let attributeExpr: IREnvelope?
    
    /// Conversion window in seconds.
    /// - For `.event` goals: counts if the qualifying event's timestamp is within [anchor, anchor + window],
    ///   even if evaluation happens later (e.g., offline sync).
    /// - For `.segmentEnter`, `.segmentLeave`, `.attribute` goals: the condition must be met when evaluated
    ///   and before [anchor + window].
    let window: TimeInterval?
    
    /// Initialize a goal configuration
    init(
        kind: Kind,
        eventName: String? = nil,
        eventFilter: IREnvelope? = nil,
        milestoneId: String? = nil,
        segmentId: String? = nil,
        attributeExpr: IREnvelope? = nil,
        window: TimeInterval? = nil
    ) {
        self.kind = kind
        self.eventName = eventName
        self.eventFilter = eventFilter
        self.milestoneId = milestoneId
        self.segmentId = segmentId
        self.attributeExpr = attributeExpr
        self.window = window
    }
}

// MARK: - Exit Policy

/// Policy for when a journey should exit
struct ExitPolicy: Codable, Sendable {
    /// Exit modes
    enum Mode: String, Codable, Sendable {
        /// Exit when goal is achieved
        case onGoal = "on_goal"
        
        /// Never exit early (run to completion)
        case never = "never"
    }
    
    /// The exit mode
    let mode: Mode
    
    /// Initialize an exit policy
    init(mode: Mode) {
        self.mode = mode
    }
}

// MARK: - Conversion Window Configuration

/// Default conversion window for experiences.
struct ConversionWindowDefaults: Sendable {
    /// Default window for deferred conversions (14 days)
    public static let defaultWindowValue: TimeInterval = 14 * 24 * 60 * 60

    /// Get the default window for any experience type.
    ///
    /// - Parameter experienceType: Server-defined experience category, when available.
    /// - Returns: Default conversion window in seconds.
    public static func defaultWindow(for experienceType: String?) -> TimeInterval {
        _ = experienceType
        return defaultWindowValue
    }
}

// MARK: - Conversion Anchor Types

/// Types of conversion anchors supported
enum ConversionAnchor: String, Codable, Sendable {
    /// Anchor to journey start
    case journeyStart = "journey_start"
    
    /// Anchor to last experience shown (default)
    case lastExperienceShown = "last_experience_shown"
    
    /// Anchor to the last authored experience interaction.
    case lastExperienceInteraction = "last_experience_interaction"
}
