import Foundation

// MARK: - IRPredicate

/// Predicate structure for event property filtering
public enum IRPredicate: Sendable {
    case atom(op: String, key: String, value: IRValue?)
    case and([IRPredicate])
    case or([IRPredicate])
}

// MARK: - PredicateEval

/// Predicate evaluator for event properties
public struct PredicateEval: Sendable {
    
    /// Evaluate a predicate against event properties
    public static func eval(_ predicate: IRPredicate, props: [String: Any]) -> Bool {
        switch predicate {
        case .and(let predicates):
            return predicates.allSatisfy { eval($0, props: props) }
            
        case .or(let predicates):
            return predicates.contains { eval($0, props: props) }
            
        case .atom(let op, let key, let value):
            let raw = props[key]
            return evalAtom(op: op, raw: raw, value: value)
        }
    }
    
    /// Evaluate an atomic predicate
    private static func evalAtom(op: String, raw: Any?, value: IRValue?) -> Bool {
        switch op {
        case "is_set":
            return raw != nil && !(raw is NSNull)
            
        case "is_not_set":
            return raw == nil || raw is NSNull
            
        case "eq", "equals":
            return Comparer.compare(.eq, raw, unwrap(value))
            
        case "neq", "not_equals":
            return Comparer.compare(.neq, raw, unwrap(value))
            
        case "gt":
            return Comparer.compare(.gt, raw, unwrap(value))
            
        case "gte":
            return Comparer.compare(.gte, raw, unwrap(value))
            
        case "lt":
            return Comparer.compare(.lt, raw, unwrap(value))
            
        case "lte":
            return Comparer.compare(.lte, raw, unwrap(value))
            
        case "icontains", "contains":
            guard let stringValue = Coercion.asString(unwrap(value)) else { return false }
            return Comparer.icontains(raw, stringValue)
            
        case "regex":
            guard let pattern = Coercion.asString(unwrap(value)) else { return false }
            return Comparer.regex(raw, pattern: pattern)
            
        case "in":
            if case .list(let arr) = value ?? .list([]) {
                return Comparer.member(raw, arr.map { $0.toAny() })
            }
            return false
            
        case "not_in":
            if case .list(let arr) = value ?? .list([]) {
                return !Comparer.member(raw, arr.map { $0.toAny() })
            }
            return true
            
        case "is_date_exact":
            guard let ts = Coercion.asTimestamp(raw),
                  case .timestamp(let target)? = value else {
                return false
            }
            // Define "exact" as same day (floor to day boundary)
            let calendar = Calendar.current
            let date1 = Date(timeIntervalSince1970: ts)
            let date2 = Date(timeIntervalSince1970: target)
            return calendar.isDate(date1, inSameDayAs: date2)
            
        case "is_date_after":
            guard let ts = Coercion.asTimestamp(raw),
                  case .timestamp(let target)? = value else {
                return false
            }
            return ts > target
            
        case "is_date_before":
            guard let ts = Coercion.asTimestamp(raw),
                  case .timestamp(let target)? = value else {
                return false
            }
            return ts < target
            
        default:
            return false
        }
    }
    
    /// Unwrap IRValue to Any for comparison
    private static func unwrap(_ value: IRValue?) -> Any {
        guard let value = value else {
            return NSNull()
        }
        return value.toAny()
    }
}

