import Foundation

// MARK: - IR Adapter Protocols

/// Adapter protocol for user property access
protocol IRUserProps {
    /// Get user property by key
    func userProperty(for key: String) async -> Any?
}

/// Adapter protocol for event queries
protocol IREventQueries {
    /// The earliest lower bound this source can answer exactly. Production
    /// device history is retention-bounded; fixtures may be complete.
    func historyCoverage() async throws -> EventHistoryCoverage

    /// Check if event exists
    func exists(name: String, since: Date?, until: Date?, where predicate: IRPredicate?) async throws -> Bool
    
    /// Count events
    func count(name: String, since: Date?, until: Date?, where predicate: IRPredicate?) async throws -> Int
    
    /// Get first time event occurred
    func firstTime(name: String, where predicate: IRPredicate?) async throws -> Date?
    
    /// Get last time event occurred
    func lastTime(name: String, where predicate: IRPredicate?) async throws -> Date?
    
    /// Aggregate event property values
    func aggregate(_ agg: Aggregate, name: String, prop: String, since: Date?, until: Date?, where predicate: IRPredicate?) async throws -> Double?
    
    /// Check if events occurred in order
    func inOrder(steps: [StepQuery], overallWithin: TimeInterval?, perStepWithin: TimeInterval?, since: Date?, until: Date?) async throws -> Bool
    
    /// Check if user was active in periods
    func activePeriods(name: String, period: Period, total: Int, min: Int, where predicate: IRPredicate?) async throws -> Bool
    
    /// Check if user stopped performing event
    func stopped(name: String, inactiveFor: TimeInterval, where predicate: IRPredicate?) async throws -> Bool
    
    /// Check if user restarted performing event
    func restarted(name: String, inactiveFor: TimeInterval, within: TimeInterval, where predicate: IRPredicate?) async throws -> Bool
}

enum EventHistoryQueryError: Error, Equatable, Sendable {
    case truncated(limit: Int)
}

/// Completeness contract for the history visible to IR evaluation.
enum EventHistoryCoverage: Equatable, Sendable {
    case complete
    case retainedWindow(startingAt: Date)

    /// A query is exact only when its complete authored window is inside the
    /// source's guaranteed coverage. An unbounded query needs complete history.
    func contains(since: Date?) -> Bool {
        switch self {
        case .complete:
            return true
        case .retainedWindow(let startingAt):
            guard let since else { return false }
            return since >= startingAt
        }
    }
}

/// Adapter protocol for segment queries
protocol IRSegmentQueries {
    /// Check if user is member of segment
    func isMember(_ segmentId: String) async -> Bool

    /// Get when user entered segment
    func enteredAt(_ segmentId: String) async -> Date?
}

/// Adapter protocol for feature access queries (entitlements)
protocol IRFeatureQueries {
    /// Check if user has access to feature (boolean or has remaining balance)
    func has(_ featureId: String) async -> Bool

    /// Check if feature is unlimited
    func isUnlimited(_ featureId: String) async -> Bool

    /// Get current balance for metered/credit features
    func getBalance(_ featureId: String) async -> Double?
}

// MARK: - Supporting Types

/// Aggregation functions
enum Aggregate: String, Sendable {
    case sum
    case avg
    case min
    case max
    case unique
}

/// Step in a sequence query
struct StepQuery: Sendable {
    public let name: String
    public let predicate: IRPredicate?
    
    public init(name: String, predicate: IRPredicate?) {
        self.name = name
        self.predicate = predicate
    }
}

/// Time period for activity checks
enum Period: String, Sendable {
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

    /// Inclusive start of the calendar-bucket window used by ActivePeriods.
    /// Centralizing this keeps query execution and completeness checks aligned.
    func activePeriodsWindowStart(total: Int, now: Date) -> Date? {
        guard total > 0 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let component: Calendar.Component
        switch self {
        case .day: component = .day
        case .week: component = .weekOfYear
        case .month: component = .month
        case .year: component = .year
        }
        guard let currentPeriodStart = calendar.dateInterval(
            of: component, for: now
        )?.start else { return nil }
        return calendar.date(
            byAdding: component,
            value: -(total - 1),
            to: currentPeriodStart
        )
    }
}

// MARK: - Evaluation Context

/// Context for IR evaluation
struct EvalContext {
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

    /// Exact run-owned snapshot. Evaluation never queries response transport.
    public let responseSession: ResponseSessionSnapshot?

    public init(
        now: Date,
        user: IRUserProps? = nil,
        events: IREventQueries? = nil,
        segments: IRSegmentQueries? = nil,
        features: IRFeatureQueries? = nil,
        event: NuxieEvent? = nil,
        journeyId: String? = nil,
        responseSession: ResponseSessionSnapshot? = nil
    ) {
        self.now = now
        self.user = user
        self.events = events
        self.segments = segments
        self.features = features
        self.event = event
        self.journeyId = journeyId
        self.responseSession = responseSession
    }
}
