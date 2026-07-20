import Foundation

// MARK: - IRInterpreter

/// Interpreter for evaluating IR expressions
public final class IRInterpreter {
    
    // MARK: - Properties
    
    private let ctx: EvalContext
    
    // MARK: - Initialization
    
    public init(ctx: EvalContext) {
        self.ctx = ctx
    }
    
    // MARK: - Public Methods
    
    /// Evaluate expression to boolean
    public func evalBool(_ expr: IRExpr) async throws -> Bool {
        switch expr {
        case .bool(let b):
            return b

        case .unknown(let type):
            // Forward compat: fail-closed — don't trigger/allow on ops this
            // engine can't evaluate.
            LogWarning("IR: evaluating unknown node type '\(type)' as false")
            return false
            
        case .and(let expressions):
            for expr in expressions {
                if try await !evalBool(expr) {
                    return false
                }
            }
            return true
            
        case .or(let expressions):
            for expr in expressions {
                if try await evalBool(expr) {
                    return true
                }
            }
            return false
            
        case .not(let expr):
            return try await !evalBool(expr)
            
        case .compare(let op, let left, let right):
            let leftValue = try await evalValue(left)
            let rightValue = try await evalValue(right)
            return compareValues(op: op, left: leftValue, right: rightValue)
            
        case .user(let op, let key, let value):
            return try await evalUser(op: op, key: key, value: value)
            
        case .event(let op, let key, let value):
            guard let event = ctx.event else { return false }
            return try await evalEvent(op: op, key: key, value: value, event: event)
            
        case .segment(let op, let id, let within):
            guard let segments = ctx.segments else {
                return false
            }

            switch op {
            case "is_member", "in":
                return await segments.isMember(id)
            case "not_member", "not_in":
                return await !segments.isMember(id)
            case "entered_within":
                guard let within = within else { return false }
                let duration = try await evalDuration(within)
                guard let entered = await segments.enteredAt(id) else { return false }
                return ctx.now.timeIntervalSince(entered) <= duration
            default:
                return false
            }

        case .feature(let op, let id, let value):
            return try await evalFeature(op: op, id: id, value: value)

        case .eventsExists(let name, let since, let until, let within, let where_):
            guard let events = ctx.events else { return false }
            let (s, u) = try await window(since: since, until: until, within: within)
            let predicate = try await exprToPredicate(where_)
            return await events.exists(name: name, since: s, until: u, where: predicate)
            
        case .eventsCount(let name, let since, let until, let within, let where_):
            guard let events = ctx.events else { return false }
            let (s, u) = try await window(since: since, until: until, within: within)
            let predicate = try await exprToPredicate(where_)
            return await events.count(name: name, since: s, until: u, where: predicate) > 0
            
        case .eventsFirstTime(let name, let where_):
            guard let events = ctx.events else { return false }
            let predicate = try await exprToPredicate(where_)
            return await events.firstTime(name: name, where: predicate) != nil
            
        case .eventsLastTime(let name, let where_):
            guard let events = ctx.events else { return false }
            let predicate = try await exprToPredicate(where_)
            return await events.lastTime(name: name, where: predicate) != nil
            
        case .eventsLastAge(let name, let where_):
            guard let events = ctx.events else { return false }
            let predicate = try await exprToPredicate(where_)
            guard let lastTime = await events.lastTime(name: name, where: predicate) else {
                return false
            }
            return ctx.now.timeIntervalSince(lastTime) >= 0
            
        case .eventsAggregate(let agg, let name, let prop, let since, let until, let within, let where_):
            guard let events = ctx.events else { return false }
            let (s, u) = try await window(since: since, until: until, within: within)
            let predicate = try await exprToPredicate(where_)
            guard let aggType = Aggregate(rawValue: agg) else {
                throw IRError.invalidOperator(agg)
            }
            let value = await events.aggregate(aggType, name: name, prop: prop, since: s, until: u, where: predicate)
            return (value ?? 0) != 0
            
        case .eventsInOrder(let steps, let overallWithin, let perStepWithin, let since, let until):
            guard let events = ctx.events else { return false }
            let (s, u) = try await window(since: since, until: until, within: nil)
            let overall = try await overallWithin.asyncMap { try await evalDuration($0) }
            let perStep = try await perStepWithin.asyncMap { try await evalDuration($0) }
            var stepQueries: [StepQuery] = []
            for step in steps {
                let predicate = try await exprToPredicate(step.where_)
                stepQueries.append(StepQuery(name: step.name, predicate: predicate))
            }
            return await events.inOrder(steps: stepQueries, overallWithin: overall, perStepWithin: perStep, since: s, until: u)
            
        case .eventsActivePeriods(let name, let period, let totalPeriods, let minPeriods, let where_):
            guard let events = ctx.events else { return false }
            let predicate = try await exprToPredicate(where_)
            guard let periodType = Period(rawValue: period) else {
                throw IRError.invalidOperator(period)
            }
            return await events.activePeriods(name: name, period: periodType, total: totalPeriods, min: minPeriods, where: predicate)
            
        case .eventsStopped(let name, let inactiveFor, let where_):
            guard let events = ctx.events else { return false }
            let duration = try await evalDuration(inactiveFor)
            let predicate = try await exprToPredicate(where_)
            return await events.stopped(name: name, inactiveFor: duration, where: predicate)
            
        case .eventsRestarted(let name, let inactiveFor, let within, let where_):
            guard let events = ctx.events else { return false }
            let inactiveDuration = try await evalDuration(inactiveFor)
            let withinDuration = try await evalDuration(within)
            let predicate = try await exprToPredicate(where_)
            return await events.restarted(name: name, inactiveFor: inactiveDuration, within: withinDuration, where: predicate)
            
        // Values used in boolean position - treat as truthy
        case .timeNow, .timeAgo, .timeWindow, .journeyId, .number, .string, .timestamp, .duration, .list:
            let value = try await evalValue(expr)
            return value.isTruthy
            
        case .pred(let op, let key, let value):
            // Evaluate predicate against event properties (for trigger conditions)
            guard let event = ctx.event else {
                // No event context - can't evaluate predicates
                return false
            }
            return try await evalPredicate(op: op, key: key, value: value, event: event)
            
        case .predAnd(let predicates):
            // All predicates must be true
            guard ctx.event != nil else { return false }
            for pred in predicates {
                if try await !evalBool(pred) {
                    return false
                }
            }
            return true
            
        case .predOr(let predicates):
            // At least one predicate must be true
            guard ctx.event != nil else { return false }
            for pred in predicates {
                if try await evalBool(pred) {
                    return true
                }
            }
            return false
        }
    }
    
    /// Evaluate expression to value
    public func evalValue(_ expr: IRExpr) async throws -> IRValue {
        switch expr {
        case .bool(let b):
            return .bool(b)
            
        case .number(let n):
            return .number(n)
            
        case .string(let s):
            return .string(s)
            
        case .timestamp(let t):
            return .timestamp(t)
            
        case .duration(let d):
            return .duration(d)
            
        case .list(let expressions):
            let values = try await expressions.asyncMap { try await evalValue($0) }
            return .list(values)
            
        case .timeNow:
            return .timestamp(ctx.now.timeIntervalSince1970)
            
        case .timeAgo(let durationExpr):
            let duration = try await evalDuration(durationExpr)
            return .timestamp(ctx.now.timeIntervalSince1970 - duration)
            
        case .timeWindow(let value, let interval):
            let seconds = toSeconds(value, interval)
            return .duration(seconds)

        case .journeyId:
            guard let journeyId = ctx.journeyId else { return .null }
            return .string(journeyId)

        case .eventsCount(let name, let since, let until, let within, let where_):
            // Allow count to be evaluated as a number
            guard let events = ctx.events else { return .number(0) }
            let (s, u) = try await window(since: since, until: until, within: within)
            let predicate = try await exprToPredicate(where_)
            let count = await events.count(name: name, since: s, until: u, where: predicate)
            return .number(Double(count))
            
        case .eventsAggregate(let agg, let name, let prop, let since, let until, let within, let where_):
            // Allow aggregate to be evaluated as a number
            guard let events = ctx.events else { return .number(0) }
            let (s, u) = try await window(since: since, until: until, within: within)
            let predicate = try await exprToPredicate(where_)
            guard let aggType = Aggregate(rawValue: agg) else {
                throw IRError.invalidOperator(agg)
            }
            let value = await events.aggregate(aggType, name: name, prop: prop, since: s, until: u, where: predicate)
            return .number(value ?? 0)
            
        case .eventsFirstTime(let name, let where_):
            // Allow first time to be evaluated as timestamp
            guard let events = ctx.events else { return .null }
            let predicate = try await exprToPredicate(where_)
            if let firstTime = await events.firstTime(name: name, where: predicate) {
                return .timestamp(firstTime.timeIntervalSince1970)
            }
            return .null
            
        case .eventsLastTime(let name, let where_):
            // Allow last time to be evaluated as timestamp
            guard let events = ctx.events else { return .null }
            let predicate = try await exprToPredicate(where_)
            if let lastTime = await events.lastTime(name: name, where: predicate) {
                return .timestamp(lastTime.timeIntervalSince1970)
            }
            return .null
            
        case .eventsLastAge(let name, let where_):
            // Allow last age to be evaluated as duration
            guard let events = ctx.events else { return .null }
            let predicate = try await exprToPredicate(where_)
            if let lastTime = await events.lastTime(name: name, where: predicate) {
                let age = ctx.now.timeIntervalSince(lastTime)
                return .duration(age)
            }
            return .null
            
        default:
            throw IRError.typeMismatch(expected: "value node", got: String(describing: expr))
        }
    }
    
    // MARK: - Private Methods
    
    /// Single operator evaluation shared by the User, Event, and Predicate
    /// nodes. The three hand-maintained copies this replaces had already
    /// drifted ("contains" was accepted by predicates but not user props —
    /// the superset is now canonical for all three).
    private func evalOp(_ op: String, raw: Any?, value: IRExpr?) async throws -> Bool {
        switch op {
        case "is_set", "has":
            return raw != nil && !(raw is NSNull)
            
        case "is_not_set":
            return raw == nil || raw is NSNull
            
        case "eq", "equals":
            guard let value = value else { return false }
            let compareValue = try await evalValue(value)
            return Comparer.compare(.eq, raw, compareValue.toAny())
            
        case "neq", "not_equals":
            guard let value = value else { return true }
            let compareValue = try await evalValue(value)
            return Comparer.compare(.neq, raw, compareValue.toAny())
            
        case "gt":
            guard let value = value else { return false }
            let compareValue = try await evalValue(value)
            return Comparer.compare(.gt, raw, compareValue.toAny())
            
        case "gte":
            guard let value = value else { return false }
            let compareValue = try await evalValue(value)
            return Comparer.compare(.gte, raw, compareValue.toAny())
            
        case "lt":
            guard let value = value else { return false }
            let compareValue = try await evalValue(value)
            return Comparer.compare(.lt, raw, compareValue.toAny())
            
        case "lte":
            guard let value = value else { return false }
            let compareValue = try await evalValue(value)
            return Comparer.compare(.lte, raw, compareValue.toAny())
            
        case "icontains", "contains":
            guard let value = value else { return false }
            let compareValue = try await evalValue(value)
            let needle = Coercion.asString(compareValue.toAny()) ?? ""
            return Comparer.icontains(raw, needle)
            
        case "regex":
            guard let value = value else { return false }
            let compareValue = try await evalValue(value)
            let pattern = Coercion.asString(compareValue.toAny()) ?? ""
            return Comparer.regex(raw, pattern: pattern)
            
        case "in":
            guard let value = value else { return false }
            let listValue = try await evalValue(value)
            guard case .list(let arr) = listValue else { return false }
            return Comparer.member(raw, arr.map { $0.toAny() })
            
        case "not_in":
            guard let value = value else { return true }
            let listValue = try await evalValue(value)
            guard case .list(let arr) = listValue else { return true }
            return !Comparer.member(raw, arr.map { $0.toAny() })
            
        case "is_date_exact":
            guard let ts = Coercion.asTimestamp(raw),
                  let value = value else {
                return false
            }
            let compareValue = try await evalValue(value)
            guard case .timestamp(let target) = compareValue else {
                return false
            }
            // Same day comparison
            let calendar = Calendar.current
            let date1 = Date(timeIntervalSince1970: ts)
            let date2 = Date(timeIntervalSince1970: target)
            return calendar.isDate(date1, inSameDayAs: date2)
            
        case "is_date_after":
            guard let ts = Coercion.asTimestamp(raw),
                  let value = value else {
                return false
            }
            let compareValue = try await evalValue(value)
            guard case .timestamp(let target) = compareValue else {
                return false
            }
            return ts > target
            
        case "is_date_before":
            guard let ts = Coercion.asTimestamp(raw),
                  let value = value else {
                return false
            }
            let compareValue = try await evalValue(value)
            guard case .timestamp(let target) = compareValue else {
                return false
            }
            return ts < target
            
        default:
            return false
        }
    }

    /// Evaluate predicate against event properties
    private func evalPredicate(op: String, key: String, value: IRExpr?, event: NuxieEvent) async throws -> Bool {
        try await evalOp(op, raw: resolveEventValue(for: key, in: event), value: value)
    }

    /// Convert IR expression to predicate
    private func exprToPredicate(_ expr: IRExpr?) async throws -> IRPredicate? {
        guard let expr = expr else { return nil }
        
        switch expr {
        case .pred(let op, let key, let value):
            let irValue: IRValue?
            if let value = value {
                irValue = try await evalValue(value)
            } else {
                irValue = nil
            }
            return .atom(op: op, key: key, value: irValue)
            
        case .predAnd(let expressions):
            var predicates: [IRPredicate] = []
            for expr in expressions {
                if let predicate = try await exprToPredicate(expr) {
                    predicates.append(predicate)
                }
            }
            return .and(predicates)
            
        case .predOr(let expressions):
            var predicates: [IRPredicate] = []
            for expr in expressions {
                if let predicate = try await exprToPredicate(expr) {
                    predicates.append(predicate)
                }
            }
            return .or(predicates)
            
        case .not(_):
            throw IRError.evaluationError("NOT over predicates not supported in v1")
            
        default:
            throw IRError.typeMismatch(expected: "Pred* node", got: String(describing: expr))
        }
    }
    
    /// Evaluate duration expression
    private func evalDuration(_ expr: IRExpr) async throws -> TimeInterval {
        let value = try await evalValue(expr)
        switch value {
        case .duration(let d):
            return d
        case .number(let n):
            return n
        default:
            throw IRError.typeMismatch(expected: "duration or number", got: String(describing: value))
        }
    }
    
    /// Calculate time window from since/until/within
    private func window(since: IRExpr?, until: IRExpr?, within: IRExpr?) async throws -> (Date?, Date?) {
        var sinceDate: Date? = nil
        var untilDate: Date? = nil
        
        if let since = since {
            let value = try await evalValue(since)
            if case .timestamp(let ts) = value {
                sinceDate = Date(timeIntervalSince1970: ts)
            }
        }
        
        if let until = until {
            let value = try await evalValue(until)
            if case .timestamp(let tu) = value {
                untilDate = Date(timeIntervalSince1970: tu)
            }
        }
        
        if let within = within {
            let value = try await evalValue(within)
            if case .duration(let w) = value {
                let start = Date(timeIntervalSince1970: ctx.now.timeIntervalSince1970 - w)
                // Intersect with since if both are specified
                if let existingSince = sinceDate {
                    sinceDate = max(existingSince, start)
                } else {
                    sinceDate = start
                }
            }
        }
        
        return (sinceDate, untilDate)
    }
    
    /// Compare two values
    private func compareValues(op: String, left: IRValue, right: IRValue) -> Bool {
        guard let compareOp = CompareOp(rawValue: op) else {
            // Try alternative formats
            if op == "in" {
                return Comparer.compare(.in, left.toAny(), right.toAny())
            } else if op == "not_in" {
                return Comparer.compare(.notIn, left.toAny(), right.toAny())
            }
            return false
        }
        return Comparer.compare(compareOp, left.toAny(), right.toAny())
    }
    
    /// Convert time value and interval to seconds
    private func toSeconds(_ value: Int, _ interval: String) -> TimeInterval {
        switch interval {
        case "hour":
            return TimeInterval(value * 3600)
        case "day":
            return TimeInterval(value * 86400)
        case "week":
            return TimeInterval(value * 7 * 86400)
        case "month":
            return TimeInterval(value * 30 * 86400)  // Approximate
        case "year":
            return TimeInterval(value * 365 * 86400)  // Approximate
        default:
            return 0
        }
    }
    
    /// Evaluate user property operations
    private func evalUser(op: String, key: String, value: IRExpr?) async throws -> Bool {
        guard let user = ctx.user else { return false }
        return try await evalOp(op, raw: await user.userProperty(for: key), value: value)
    }

    /// Evaluate Feature node (entitlement access checks)
    private func evalFeature(op: String, id: String, value: IRExpr?) async throws -> Bool {
        guard let features = ctx.features else { return false }

        switch op {
        case "has":
            return await features.has(id)

        case "not_has":
            return await !features.has(id)

        case "is_unlimited":
            return await features.isUnlimited(id)

        case "credits_eq", "credits_neq", "credits_gt", "credits_gte", "credits_lt", "credits_lte":
            guard let value = value else { return false }
            let target = try await evalValue(value)
            guard case .number(let n) = target else { return false }
            guard let balance = await features.getBalance(id) else { return false }
            let targetInt = Int(n)
            switch op {
            case "credits_eq": return balance == targetInt
            case "credits_neq": return balance != targetInt
            case "credits_gt": return balance > targetInt
            case "credits_gte": return balance >= targetInt
            case "credits_lt": return balance < targetInt
            case "credits_lte": return balance <= targetInt
            default: return false
            }

        default:
            return false
        }
    }

    /// Evaluate Event node (same operators as User; source is the event)
    private func evalEvent(op: String, key: String, value: IRExpr?, event: NuxieEvent) async throws -> Bool {
        try await evalOp(op, raw: resolveEventValue(for: key, in: event), value: value)
    }

    /// Resolve event values with support for:
    /// - $name, $timestamp, $distinct_id
    /// - dotted paths (e.g., "properties.amount", "properties.nested.key")
    /// - fallback to properties[key] if top-level miss
    private func resolveEventValue(for key: String, in event: NuxieEvent) -> Any? {
        // Normalize leading $
        let rawKey = key.hasPrefix("$") ? String(key.dropFirst()) : key
        // Well-known top-level fields
        if rawKey == "name" || rawKey == "event" { return event.name }
        if rawKey == "timestamp" { return event.timestamp.timeIntervalSince1970 }
        if rawKey == "distinct_id" || rawKey == "distinctId" {
            return event.distinctId
        }
        // properties.* path
        if rawKey.hasPrefix("properties.") {
            let path = String(rawKey.dropFirst("properties.".count))
            return valueForKeyPath(path, in: event.properties)
        }
        // Direct lookup in properties
        return event.properties[rawKey]
    }
    
    private func valueForKeyPath(_ keyPath: String, in obj: Any?) -> Any? {
        guard var dict = obj as? [String: Any] else { return nil }
        let parts = keyPath.split(separator: ".").map(String.init)
        for (i, part) in parts.enumerated() {
            if i == parts.count - 1 { return dict[part] }
            guard let next = dict[part] as? [String: Any] else { return nil }
            dict = next
        }
        return nil
    }
}

// MARK: - Async Helpers

extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
        switch self {
        case .none:
            return nil
        case .some(let wrapped):
            return try await transform(wrapped)
        }
    }
}

extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var result: [T] = []
        result.reserveCapacity(count)
        for element in self {
            result.append(try await transform(element))
        }
        return result
    }
}
