import Foundation

// MARK: - IR Adapter Protocols

/// Adapter protocol for user property access
public protocol IRUserProps {
    /// Get user property by key
    func userProperty(for key: String) async -> Any?
}

/// Adapter protocol for event queries
public protocol IREventQueries {
    /// Check if event exists
    func exists(name: String, since: Date?, until: Date?, where predicate: IRPredicate?) async -> Bool
    
    /// Count events
    func count(name: String, since: Date?, until: Date?, where predicate: IRPredicate?) async -> Int
    
    /// Get first time event occurred
    func firstTime(name: String, where predicate: IRPredicate?) async -> Date?
    
    /// Get last time event occurred
    func lastTime(name: String, where predicate: IRPredicate?) async -> Date?
    
    /// Aggregate event property values
    func aggregate(_ agg: Aggregate, name: String, prop: String, since: Date?, until: Date?, where predicate: IRPredicate?) async -> Double?
    
    /// Check if events occurred in order
    func inOrder(steps: [StepQuery], overallWithin: TimeInterval?, perStepWithin: TimeInterval?, since: Date?, until: Date?) async -> Bool
    
    /// Check if user was active in periods
    func activePeriods(name: String, period: Period, total: Int, min: Int, where predicate: IRPredicate?) async -> Bool
    
    /// Check if user stopped performing event
    func stopped(name: String, inactiveFor: TimeInterval, where predicate: IRPredicate?) async -> Bool
    
    /// Check if user restarted performing event
    func restarted(name: String, inactiveFor: TimeInterval, within: TimeInterval, where predicate: IRPredicate?) async -> Bool
}

/// Adapter protocol for segment queries
public protocol IRSegmentQueries {
    /// Check if user is member of segment
    func isMember(_ segmentId: String) async -> Bool

    /// Get when user entered segment
    func enteredAt(_ segmentId: String) async -> Date?
}

/// Adapter protocol for feature access queries (entitlements)
public protocol IRFeatureQueries {
    /// Check if user has access to feature (boolean or has remaining balance)
    func has(_ featureId: String) async -> Bool

    /// Check if feature is unlimited
    func isUnlimited(_ featureId: String) async -> Bool

    /// Get current balance for metered/credit features
    func getBalance(_ featureId: String) async -> Int?
}

// MARK: - Supporting Types

/// Aggregation functions
public enum Aggregate: String, Sendable {
    case sum
    case avg
    case min
    case max
    case unique
}

/// Step in a sequence query
public struct StepQuery: Sendable {
    public let name: String
    public let predicate: IRPredicate?
    
    public init(name: String, predicate: IRPredicate?) {
        self.name = name
        self.predicate = predicate
    }
}

/// Time period for activity checks
public enum Period: String, Sendable {
    case day
    case week
    case month
    case year
    
    /// Get the number of seconds in this period
    public var seconds: TimeInterval {
        switch self {
        case .day:
            return 86400
        case .week:
            return 7 * 86400
        case .month:
            return 30 * 86400  // Approximate
        case .year:
            return 365 * 86400  // Approximate
        }
    }
}

// MARK: - Evaluation Context

/// Context for IR evaluation
public struct EvalContext {
    /// Current date/time
    public let now: Date

    /// User property adapter (optional)
    public let user: IRUserProps?

    /// Event queries adapter (optional)
    public let events: IREventQueries?

    /// Segment queries adapter (optional)
    public let segments: IRSegmentQueries?

    /// Feature queries adapter (optional)
    public let features: IRFeatureQueries?

    /// Event for predicate evaluation (when evaluating trigger conditions)
    public let event: NuxieEvent?

    /// Current journey ID for goal scoping (when evaluating goal conditions)
    public let journeyId: String?

    public init(
        now: Date,
        user: IRUserProps? = nil,
        events: IREventQueries? = nil,
        segments: IRSegmentQueries? = nil,
        features: IRFeatureQueries? = nil,
        event: NuxieEvent? = nil,
        journeyId: String? = nil
    ) {
        self.now = now
        self.user = user
        self.events = events
        self.segments = segments
        self.features = features
        self.event = event
        self.journeyId = journeyId
    }
}