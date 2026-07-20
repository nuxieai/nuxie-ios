import Foundation

// MARK: - Envelope

/// Top-level IR container with version and metadata
public struct IREnvelope: Codable, Equatable {
    public let ir_version: Int
    public let engine_min: String?
    public let compiled_at: Double?
    public let expr: IRExpr

    /// The IR engine version this SDK implements. The server stamps
    /// `engine_min` on envelopes that need newer engine behavior; those are
    /// skipped (fail-closed) with telemetry instead of misevaluated.
    public static let engineVersion = 1

    /// Whether this SDK's engine can evaluate the envelope.
    public var isSupportedByThisEngine: Bool {
        guard let engineMin = engine_min,
              let required = Int(engineMin.split(separator: ".").first.map(String.init) ?? engineMin)
        else { return true }
        return required <= Self.engineVersion
    }
    
    enum CodingKeys: String, CodingKey {
        case ir_version
        case engine_min
        case compiled_at
        case expr
    }
}

// MARK: - Expression nodes (v1)

/// IR expression node types
public indirect enum IRExpr: Codable, Equatable {
    // Scalars / containers
    case bool(Bool)
    case number(Double)
    case string(String)
    case timestamp(Double)       // epoch seconds
    case duration(Double)        // seconds
    case list([IRExpr])
    
    // Boolean composition
    case and([IRExpr])
    case or([IRExpr])
    case not(IRExpr)
    
    // Generic compare (used when both sides are values)
    case compare(op: String, left: IRExpr, right: IRExpr)
    
    // User (identity)
    case user(op: String, key: String, value: IRExpr?)
    
    // Event (current trigger event)
    case event(op: String, key: String, value: IRExpr?)
    
    // Segment membership
    case segment(op: String, id: String, within: IRExpr?)

    // Feature access (entitlements)
    case feature(op: String, id: String, value: IRExpr?)

    // Predicates over event properties
    case pred(op: String, key: String, value: IRExpr?)
    case predAnd([IRExpr])
    case predOr([IRExpr])
    
    // Event queries
    case eventsExists(name: String, since: IRExpr?, until: IRExpr?, within: IRExpr?, where_: IRExpr?)
    case eventsCount(name: String, since: IRExpr?, until: IRExpr?, within: IRExpr?, where_: IRExpr?)
    case eventsFirstTime(name: String, where_: IRExpr?)
    case eventsLastTime(name: String, where_: IRExpr?)
    case eventsLastAge(name: String, where_: IRExpr?)
    case eventsAggregate(agg: String, name: String, prop: String, since: IRExpr?, until: IRExpr?, within: IRExpr?, where_: IRExpr?)
    case eventsInOrder(steps: [Step], overallWithin: IRExpr?, perStepWithin: IRExpr?, since: IRExpr?, until: IRExpr?)
    case eventsActivePeriods(name: String, period: String, totalPeriods: Int, minPeriods: Int, where_: IRExpr?)
    case eventsStopped(name: String, inactiveFor: IRExpr, where_: IRExpr?)
    case eventsRestarted(name: String, inactiveFor: IRExpr, within: IRExpr, where_: IRExpr?)
    
    // Time helpers
    case timeNow
    case timeAgo(duration: IRExpr)
    case timeWindow(value: Int, interval: String)

    // Journey context
    case journeyId

    /// Forward compatibility: an IR node type this SDK version doesn't know.
    /// Decodes tolerantly (one new server op must never brick the whole
    /// profile/campaign decode) and evaluates fail-closed (false).
    case unknown(type: String)
    
    /// Step in a sequence query
    public struct Step: Codable, Equatable {
        public let name: String
        public let where_: IRExpr?
        
        enum CodingKeys: String, CodingKey {
            case name
            case where_ = "where"
        }
    }
    
    // MARK: - Codable
    
    enum CodingKeys: String, CodingKey {
        case type
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        
        switch type {
        case "Bool":
            let valueContainer = try decoder.container(keyedBy: ValueCodingKeys.self)
            let value = try valueContainer.decode(Bool.self, forKey: .value)
            self = .bool(value)
            
        case "Number":
            let valueContainer = try decoder.container(keyedBy: ValueCodingKeys.self)
            let value = try valueContainer.decode(Double.self, forKey: .value)
            self = .number(value)
            
        case "String":
            let valueContainer = try decoder.container(keyedBy: ValueCodingKeys.self)
            let value = try valueContainer.decode(String.self, forKey: .value)
            self = .string(value)
            
        case "Timestamp":
            let valueContainer = try decoder.container(keyedBy: ValueCodingKeys.self)
            let value = try valueContainer.decode(Double.self, forKey: .value)
            self = .timestamp(value)
            
        case "Duration":
            let valueContainer = try decoder.container(keyedBy: ValueCodingKeys.self)
            let value = try valueContainer.decode(Double.self, forKey: .value)
            self = .duration(value)
            
        case "List":
            let valueContainer = try decoder.container(keyedBy: ValueCodingKeys.self)
            let value = try valueContainer.decode([IRExpr].self, forKey: .value)
            self = .list(value)
            
        case "And":
            let argsContainer = try decoder.container(keyedBy: ArgsCodingKeys.self)
            let args = try argsContainer.decode([IRExpr].self, forKey: .args)
            self = .and(args)
            
        case "Or":
            let argsContainer = try decoder.container(keyedBy: ArgsCodingKeys.self)
            let args = try argsContainer.decode([IRExpr].self, forKey: .args)
            self = .or(args)
            
        case "Not":
            let argContainer = try decoder.container(keyedBy: ArgCodingKeys.self)
            let arg = try argContainer.decode(IRExpr.self, forKey: .arg)
            self = .not(arg)
            
        case "Compare":
            let compareContainer = try decoder.container(keyedBy: CompareCodingKeys.self)
            let op = try compareContainer.decode(String.self, forKey: .op)
            let left = try compareContainer.decode(IRExpr.self, forKey: .left)
            let right = try compareContainer.decode(IRExpr.self, forKey: .right)
            self = .compare(op: op, left: left, right: right)
            
        case "User":
            let userContainer = try decoder.container(keyedBy: UserCodingKeys.self)
            let op = try userContainer.decode(String.self, forKey: .op)
            let key = try userContainer.decode(String.self, forKey: .key)
            let value = try userContainer.decodeIfPresent(IRExpr.self, forKey: .value)
            self = .user(op: op, key: key, value: value)
            
        case "Event":
            let eventContainer = try decoder.container(keyedBy: UserCodingKeys.self)
            let op = try eventContainer.decode(String.self, forKey: .op)
            let key = try eventContainer.decode(String.self, forKey: .key)
            let value = try eventContainer.decodeIfPresent(IRExpr.self, forKey: .value)
            self = .event(op: op, key: key, value: value)
            
        case "Segment":
            let segmentContainer = try decoder.container(keyedBy: SegmentCodingKeys.self)
            let op = try segmentContainer.decode(String.self, forKey: .op)
            let id = try segmentContainer.decode(String.self, forKey: .id)
            let within = try segmentContainer.decodeIfPresent(IRExpr.self, forKey: .within)
            self = .segment(op: op, id: id, within: within)

        case "Feature":
            let featureContainer = try decoder.container(keyedBy: FeatureCodingKeys.self)
            let op = try featureContainer.decode(String.self, forKey: .op)
            let id = try featureContainer.decode(String.self, forKey: .id)
            let value = try featureContainer.decodeIfPresent(IRExpr.self, forKey: .value)
            self = .feature(op: op, id: id, value: value)

        case "Pred":
            let predContainer = try decoder.container(keyedBy: PredCodingKeys.self)
            let op = try predContainer.decode(String.self, forKey: .op)
            let key = try predContainer.decode(String.self, forKey: .key)
            let value = try predContainer.decodeIfPresent(IRExpr.self, forKey: .value)
            self = .pred(op: op, key: key, value: value)
            
        case "PredAnd":
            let argsContainer = try decoder.container(keyedBy: ArgsCodingKeys.self)
            let args = try argsContainer.decode([IRExpr].self, forKey: .args)
            self = .predAnd(args)
            
        case "PredOr":
            let argsContainer = try decoder.container(keyedBy: ArgsCodingKeys.self)
            let args = try argsContainer.decode([IRExpr].self, forKey: .args)
            self = .predOr(args)
            
        case "Events.Exists":
            let eventsContainer = try decoder.container(keyedBy: EventsCodingKeys.self)
            let name = try eventsContainer.decode(String.self, forKey: .name)
            let since = try eventsContainer.decodeIfPresent(IRExpr.self, forKey: .since)
            let until = try eventsContainer.decodeIfPresent(IRExpr.self, forKey: .until)
            let within = try eventsContainer.decodeIfPresent(IRExpr.self, forKey: .within)
            let where_ = try eventsContainer.decodeIfPresent(IRExpr.self, forKey: .where)
            self = .eventsExists(name: name, since: since, until: until, within: within, where_: where_)
            
        case "Events.Count":
            let eventsContainer = try decoder.container(keyedBy: EventsCodingKeys.self)
            let name = try eventsContainer.decode(String.self, forKey: .name)
            let since = try eventsContainer.decodeIfPresent(IRExpr.self, forKey: .since)
            let until = try eventsContainer.decodeIfPresent(IRExpr.self, forKey: .until)
            let within = try eventsContainer.decodeIfPresent(IRExpr.self, forKey: .within)
            let where_ = try eventsContainer.decodeIfPresent(IRExpr.self, forKey: .where)
            self = .eventsCount(name: name, since: since, until: until, within: within, where_: where_)
            
        case "Events.FirstTime":
            let eventsContainer = try decoder.container(keyedBy: EventsCodingKeys.self)
            let name = try eventsContainer.decode(String.self, forKey: .name)
            let where_ = try eventsContainer.decodeIfPresent(IRExpr.self, forKey: .where)
            self = .eventsFirstTime(name: name, where_: where_)
            
        case "Events.LastTime":
            let eventsContainer = try decoder.container(keyedBy: EventsCodingKeys.self)
            let name = try eventsContainer.decode(String.self, forKey: .name)
            let where_ = try eventsContainer.decodeIfPresent(IRExpr.self, forKey: .where)
            self = .eventsLastTime(name: name, where_: where_)
            
        case "Events.LastAge":
            let eventsContainer = try decoder.container(keyedBy: EventsCodingKeys.self)
            let name = try eventsContainer.decode(String.self, forKey: .name)
            let where_ = try eventsContainer.decodeIfPresent(IRExpr.self, forKey: .where)
            self = .eventsLastAge(name: name, where_: where_)
            
        case "Events.Aggregate":
            let aggContainer = try decoder.container(keyedBy: AggregateCodingKeys.self)
            let agg = try aggContainer.decode(String.self, forKey: .agg)
            let name = try aggContainer.decode(String.self, forKey: .name)
            let prop = try aggContainer.decode(String.self, forKey: .prop)
            let since = try aggContainer.decodeIfPresent(IRExpr.self, forKey: .since)
            let until = try aggContainer.decodeIfPresent(IRExpr.self, forKey: .until)
            let within = try aggContainer.decodeIfPresent(IRExpr.self, forKey: .within)
            let where_ = try aggContainer.decodeIfPresent(IRExpr.self, forKey: .where)
            self = .eventsAggregate(agg: agg, name: name, prop: prop, since: since, until: until, within: within, where_: where_)
            
        case "Events.InOrder":
            let orderContainer = try decoder.container(keyedBy: InOrderCodingKeys.self)
            let steps = try orderContainer.decode([Step].self, forKey: .steps)
            let overallWithin = try orderContainer.decodeIfPresent(IRExpr.self, forKey: .overallWithin)
            let perStepWithin = try orderContainer.decodeIfPresent(IRExpr.self, forKey: .perStepWithin)
            let since = try orderContainer.decodeIfPresent(IRExpr.self, forKey: .since)
            let until = try orderContainer.decodeIfPresent(IRExpr.self, forKey: .until)
            self = .eventsInOrder(steps: steps, overallWithin: overallWithin, perStepWithin: perStepWithin, since: since, until: until)
            
        case "Events.ActivePeriods":
            let periodsContainer = try decoder.container(keyedBy: ActivePeriodsCodingKeys.self)
            let name = try periodsContainer.decode(String.self, forKey: .name)
            let period = try periodsContainer.decode(String.self, forKey: .period)
            let totalPeriods = try periodsContainer.decode(Int.self, forKey: .totalPeriods)
            let minPeriods = try periodsContainer.decode(Int.self, forKey: .minPeriods)
            let where_ = try periodsContainer.decodeIfPresent(IRExpr.self, forKey: .where)
            self = .eventsActivePeriods(name: name, period: period, totalPeriods: totalPeriods, minPeriods: minPeriods, where_: where_)
            
        case "Events.Stopped":
            let stoppedContainer = try decoder.container(keyedBy: StoppedCodingKeys.self)
            let name = try stoppedContainer.decode(String.self, forKey: .name)
            let inactiveFor = try stoppedContainer.decode(IRExpr.self, forKey: .inactiveFor)
            let where_ = try stoppedContainer.decodeIfPresent(IRExpr.self, forKey: .where)
            self = .eventsStopped(name: name, inactiveFor: inactiveFor, where_: where_)
            
        case "Events.Restarted":
            let restartedContainer = try decoder.container(keyedBy: RestartedCodingKeys.self)
            let name = try restartedContainer.decode(String.self, forKey: .name)
            let inactiveFor = try restartedContainer.decode(IRExpr.self, forKey: .inactiveFor)
            let within = try restartedContainer.decode(IRExpr.self, forKey: .within)
            let where_ = try restartedContainer.decodeIfPresent(IRExpr.self, forKey: .where)
            self = .eventsRestarted(name: name, inactiveFor: inactiveFor, within: within, where_: where_)
            
        case "Time.Now":
            self = .timeNow
            
        case "Time.Ago":
            let timeContainer = try decoder.container(keyedBy: TimeAgoCodingKeys.self)
            let duration = try timeContainer.decode(IRExpr.self, forKey: .duration)
            self = .timeAgo(duration: duration)
            
        case "Time.Window":
            let windowContainer = try decoder.container(keyedBy: TimeWindowCodingKeys.self)
            let value = try windowContainer.decode(Int.self, forKey: .value)
            let interval = try windowContainer.decode(String.self, forKey: .interval)
            self = .timeWindow(value: value, interval: interval)

        case "Journey.Id":
            self = .journeyId

        default:
            // Tolerant decode: unknown ops evaluate fail-closed instead of
            // failing the enclosing experience/profile decode.
            LogWarning("IR: unknown node type '\(type)' — evaluating fail-closed")
            self = .unknown(type: type)
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var typeContainer = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .bool(let value):
            try typeContainer.encode("Bool", forKey: .type)
            var valueContainer = encoder.container(keyedBy: ValueCodingKeys.self)
            try valueContainer.encode(value, forKey: .value)

        case .number(let value):
            try typeContainer.encode("Number", forKey: .type)
            var valueContainer = encoder.container(keyedBy: ValueCodingKeys.self)
            try valueContainer.encode(value, forKey: .value)

        case .string(let value):
            try typeContainer.encode("String", forKey: .type)
            var valueContainer = encoder.container(keyedBy: ValueCodingKeys.self)
            try valueContainer.encode(value, forKey: .value)

        case .timestamp(let value):
            try typeContainer.encode("Timestamp", forKey: .type)
            var valueContainer = encoder.container(keyedBy: ValueCodingKeys.self)
            try valueContainer.encode(value, forKey: .value)

        case .duration(let value):
            try typeContainer.encode("Duration", forKey: .type)
            var valueContainer = encoder.container(keyedBy: ValueCodingKeys.self)
            try valueContainer.encode(value, forKey: .value)

        case .list(let value):
            try typeContainer.encode("List", forKey: .type)
            var valueContainer = encoder.container(keyedBy: ValueCodingKeys.self)
            try valueContainer.encode(value, forKey: .value)

        case .and(let args):
            try typeContainer.encode("And", forKey: .type)
            var argsContainer = encoder.container(keyedBy: ArgsCodingKeys.self)
            try argsContainer.encode(args, forKey: .args)

        case .or(let args):
            try typeContainer.encode("Or", forKey: .type)
            var argsContainer = encoder.container(keyedBy: ArgsCodingKeys.self)
            try argsContainer.encode(args, forKey: .args)

        case .not(let arg):
            try typeContainer.encode("Not", forKey: .type)
            var argContainer = encoder.container(keyedBy: ArgCodingKeys.self)
            try argContainer.encode(arg, forKey: .arg)

        case .compare(let op, let left, let right):
            try typeContainer.encode("Compare", forKey: .type)
            var compareContainer = encoder.container(keyedBy: CompareCodingKeys.self)
            try compareContainer.encode(op, forKey: .op)
            try compareContainer.encode(left, forKey: .left)
            try compareContainer.encode(right, forKey: .right)

        case .user(let op, let key, let value):
            try typeContainer.encode("User", forKey: .type)
            var userContainer = encoder.container(keyedBy: UserCodingKeys.self)
            try userContainer.encode(op, forKey: .op)
            try userContainer.encode(key, forKey: .key)
            try userContainer.encodeIfPresent(value, forKey: .value)

        case .event(let op, let key, let value):
            try typeContainer.encode("Event", forKey: .type)
            var eventContainer = encoder.container(keyedBy: UserCodingKeys.self)
            try eventContainer.encode(op, forKey: .op)
            try eventContainer.encode(key, forKey: .key)
            try eventContainer.encodeIfPresent(value, forKey: .value)

        case .segment(let op, let id, let within):
            try typeContainer.encode("Segment", forKey: .type)
            var segmentContainer = encoder.container(keyedBy: SegmentCodingKeys.self)
            try segmentContainer.encode(op, forKey: .op)
            try segmentContainer.encode(id, forKey: .id)
            try segmentContainer.encodeIfPresent(within, forKey: .within)

        case .feature(let op, let id, let value):
            try typeContainer.encode("Feature", forKey: .type)
            var featureContainer = encoder.container(keyedBy: FeatureCodingKeys.self)
            try featureContainer.encode(op, forKey: .op)
            try featureContainer.encode(id, forKey: .id)
            try featureContainer.encodeIfPresent(value, forKey: .value)

        case .pred(let op, let key, let value):
            try typeContainer.encode("Pred", forKey: .type)
            var predContainer = encoder.container(keyedBy: PredCodingKeys.self)
            try predContainer.encode(op, forKey: .op)
            try predContainer.encode(key, forKey: .key)
            try predContainer.encodeIfPresent(value, forKey: .value)

        case .predAnd(let args):
            try typeContainer.encode("PredAnd", forKey: .type)
            var argsContainer = encoder.container(keyedBy: ArgsCodingKeys.self)
            try argsContainer.encode(args, forKey: .args)

        case .predOr(let args):
            try typeContainer.encode("PredOr", forKey: .type)
            var argsContainer = encoder.container(keyedBy: ArgsCodingKeys.self)
            try argsContainer.encode(args, forKey: .args)

        case .eventsExists(let name, let since, let until, let within, let where_):
            try typeContainer.encode("Events.Exists", forKey: .type)
            var eventsContainer = encoder.container(keyedBy: EventsCodingKeys.self)
            try eventsContainer.encode(name, forKey: .name)
            try eventsContainer.encodeIfPresent(since, forKey: .since)
            try eventsContainer.encodeIfPresent(until, forKey: .until)
            try eventsContainer.encodeIfPresent(within, forKey: .within)
            try eventsContainer.encodeIfPresent(where_, forKey: .where)

        case .eventsCount(let name, let since, let until, let within, let where_):
            try typeContainer.encode("Events.Count", forKey: .type)
            var eventsContainer = encoder.container(keyedBy: EventsCodingKeys.self)
            try eventsContainer.encode(name, forKey: .name)
            try eventsContainer.encodeIfPresent(since, forKey: .since)
            try eventsContainer.encodeIfPresent(until, forKey: .until)
            try eventsContainer.encodeIfPresent(within, forKey: .within)
            try eventsContainer.encodeIfPresent(where_, forKey: .where)

        case .eventsFirstTime(let name, let where_):
            try typeContainer.encode("Events.FirstTime", forKey: .type)
            var eventsContainer = encoder.container(keyedBy: EventsCodingKeys.self)
            try eventsContainer.encode(name, forKey: .name)
            try eventsContainer.encodeIfPresent(where_, forKey: .where)

        case .eventsLastTime(let name, let where_):
            try typeContainer.encode("Events.LastTime", forKey: .type)
            var eventsContainer = encoder.container(keyedBy: EventsCodingKeys.self)
            try eventsContainer.encode(name, forKey: .name)
            try eventsContainer.encodeIfPresent(where_, forKey: .where)

        case .eventsLastAge(let name, let where_):
            try typeContainer.encode("Events.LastAge", forKey: .type)
            var eventsContainer = encoder.container(keyedBy: EventsCodingKeys.self)
            try eventsContainer.encode(name, forKey: .name)
            try eventsContainer.encodeIfPresent(where_, forKey: .where)

        case .eventsAggregate(let agg, let name, let prop, let since, let until, let within, let where_):
            try typeContainer.encode("Events.Aggregate", forKey: .type)
            var aggContainer = encoder.container(keyedBy: AggregateCodingKeys.self)
            try aggContainer.encode(agg, forKey: .agg)
            try aggContainer.encode(name, forKey: .name)
            try aggContainer.encode(prop, forKey: .prop)
            try aggContainer.encodeIfPresent(since, forKey: .since)
            try aggContainer.encodeIfPresent(until, forKey: .until)
            try aggContainer.encodeIfPresent(within, forKey: .within)
            try aggContainer.encodeIfPresent(where_, forKey: .where)

        case .eventsInOrder(let steps, let overallWithin, let perStepWithin, let since, let until):
            try typeContainer.encode("Events.InOrder", forKey: .type)
            var orderContainer = encoder.container(keyedBy: InOrderCodingKeys.self)
            try orderContainer.encode(steps, forKey: .steps)
            try orderContainer.encodeIfPresent(overallWithin, forKey: .overallWithin)
            try orderContainer.encodeIfPresent(perStepWithin, forKey: .perStepWithin)
            try orderContainer.encodeIfPresent(since, forKey: .since)
            try orderContainer.encodeIfPresent(until, forKey: .until)

        case .eventsActivePeriods(let name, let period, let totalPeriods, let minPeriods, let where_):
            try typeContainer.encode("Events.ActivePeriods", forKey: .type)
            var periodsContainer = encoder.container(keyedBy: ActivePeriodsCodingKeys.self)
            try periodsContainer.encode(name, forKey: .name)
            try periodsContainer.encode(period, forKey: .period)
            try periodsContainer.encode(totalPeriods, forKey: .totalPeriods)
            try periodsContainer.encode(minPeriods, forKey: .minPeriods)
            try periodsContainer.encodeIfPresent(where_, forKey: .where)

        case .eventsStopped(let name, let inactiveFor, let where_):
            try typeContainer.encode("Events.Stopped", forKey: .type)
            var stoppedContainer = encoder.container(keyedBy: StoppedCodingKeys.self)
            try stoppedContainer.encode(name, forKey: .name)
            try stoppedContainer.encode(inactiveFor, forKey: .inactiveFor)
            try stoppedContainer.encodeIfPresent(where_, forKey: .where)

        case .eventsRestarted(let name, let inactiveFor, let within, let where_):
            try typeContainer.encode("Events.Restarted", forKey: .type)
            var restartedContainer = encoder.container(keyedBy: RestartedCodingKeys.self)
            try restartedContainer.encode(name, forKey: .name)
            try restartedContainer.encode(inactiveFor, forKey: .inactiveFor)
            try restartedContainer.encode(within, forKey: .within)
            try restartedContainer.encodeIfPresent(where_, forKey: .where)

        case .timeNow:
            try typeContainer.encode("Time.Now", forKey: .type)

        case .timeAgo(let duration):
            try typeContainer.encode("Time.Ago", forKey: .type)
            var timeContainer = encoder.container(keyedBy: TimeAgoCodingKeys.self)
            try timeContainer.encode(duration, forKey: .duration)

        case .timeWindow(let value, let interval):
            try typeContainer.encode("Time.Window", forKey: .type)
            var windowContainer = encoder.container(keyedBy: TimeWindowCodingKeys.self)
            try windowContainer.encode(value, forKey: .value)
            try windowContainer.encode(interval, forKey: .interval)

        case .journeyId:
            try typeContainer.encode("Journey.Id", forKey: .type)

        case .unknown(let type):
            try typeContainer.encode(type, forKey: .type)
        }
    }
    
    // MARK: - Private Coding Keys
    
    private enum ValueCodingKeys: String, CodingKey {
        case value
    }
    
    private enum ArgsCodingKeys: String, CodingKey {
        case args
    }
    
    private enum ArgCodingKeys: String, CodingKey {
        case arg
    }
    
    private enum CompareCodingKeys: String, CodingKey {
        case op, left, right
    }
    
    private enum UserCodingKeys: String, CodingKey {
        case op, key, value
    }
    
    private enum SegmentCodingKeys: String, CodingKey {
        case op, id, within
    }

    private enum FeatureCodingKeys: String, CodingKey {
        case op, id, value
    }

    private enum PredCodingKeys: String, CodingKey {
        case op, key, value
    }
    
    private enum EventsCodingKeys: String, CodingKey {
        case name, since, until, within
        case `where`
    }
    
    private enum AggregateCodingKeys: String, CodingKey {
        case agg, name, prop, since, until, within
        case `where`
    }
    
    private enum InOrderCodingKeys: String, CodingKey {
        case steps, overallWithin, perStepWithin, since, until
    }
    
    private enum ActivePeriodsCodingKeys: String, CodingKey {
        case name, period, totalPeriods, minPeriods
        case `where`
    }
    
    private enum StoppedCodingKeys: String, CodingKey {
        case name, inactiveFor
        case `where`
    }
    
    private enum RestartedCodingKeys: String, CodingKey {
        case name, inactiveFor, within
        case `where`
    }
    
    private enum TimeAgoCodingKeys: String, CodingKey {
        case duration
    }
    
    private enum TimeWindowCodingKeys: String, CodingKey {
        case value, interval
    }
    
}

// MARK: - Errors

public enum IRError: Error, LocalizedError {
    case encodingNotImplemented
    case invalidNodeType(String)
    case invalidOperator(String)
    case typeMismatch(expected: String, got: String)
    case evaluationError(String)
    
    public var errorDescription: String? {
        switch self {
        case .encodingNotImplemented:
            return "IR encoding is not implemented"
        case .invalidNodeType(let type):
            return "Invalid IR node type: \(type)"
        case .invalidOperator(let op):
            return "Invalid operator: \(op)"
        case .typeMismatch(let expected, let got):
            return "Type mismatch: expected \(expected), got \(got)"
        case .evaluationError(let message):
            return "Evaluation error: \(message)"
        }
    }
}
