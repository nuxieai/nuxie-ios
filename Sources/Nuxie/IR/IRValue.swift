import Foundation

/// Shared ISO8601 formatter — allocating one per call sat in the hot
/// asString/asTimestamp coercion paths.
// nonisolated(unsafe): ISO8601DateFormatter is documented thread-safe.
private nonisolated(unsafe) let iso8601Formatter = ISO8601DateFormatter()

// MARK: - IRValue

/// Unified value representation for IR evaluation
public enum IRValue: Equatable, Sendable {
    case bool(Bool)
    case number(Double)
    case string(String)
    case timestamp(Double)  // epoch seconds
    case duration(Double)   // seconds
    case list([IRValue])
    case null
    
    /// Check if value is truthy according to IR semantics
    public var isTruthy: Bool {
        switch self {
        case .bool(let b):
            return b
        case .number(let n):
            return n != 0
        case .string(let s):
            return !s.isEmpty
        case .list(let xs):
            return !xs.isEmpty
        case .timestamp(let t):
            return t != 0
        case .duration(let d):
            return d != 0
        case .null:
            return false
        }
    }
    
    /// Convert to Any for comparison operations
    public func toAny() -> Any {
        switch self {
        case .bool(let b):
            return b
        case .number(let n):
            return n
        case .string(let s):
            return s
        case .timestamp(let t):
            return t
        case .duration(let d):
            return d
        case .list(let xs):
            return xs.map { $0.toAny() }
        case .null:
            return NSNull()
        }
    }
}

// MARK: - Coercion

/// Type coercion utilities for flexible comparisons. Stateless namespace.
public struct Coercion: Sendable {
    
    /// Coerce value to number if possible
    public static func asNumber(_ value: Any?) -> Double? {
        switch value {
        case let x as Double:
            return x
        case let x as Float:
            return Double(x)
        case let x as Int:
            return Double(x)
        case let x as Int32:
            return Double(x)
        case let x as Int64:
            return Double(x)
        case let x as NSNumber:
            return x.doubleValue
        case let s as String:
            return Double(s)
        case let d as Date:
            return d.timeIntervalSince1970
        default:
            return nil
        }
    }
    
    /// Coerce value to string if possible
    public static func asString(_ value: Any?) -> String? {
        switch value {
        case let s as String:
            return s
        case let n as NSNumber:
            return n.stringValue
        case let b as Bool:
            return b ? "true" : "false"
        case let d as Date:
            return iso8601Formatter.string(from: d)
        case let n as Double:
            return String(n)
        case let n as Int:
            return String(n)
        default:
            return nil
        }
    }
    
    /// Coerce value to timestamp if possible
    public static func asTimestamp(_ value: Any?) -> Double? {
        // Try as number first
        if let n = asNumber(value) {
            return n
        }
        
        // Try parsing as ISO date string
        if let s = value as? String {
            let formatter = iso8601Formatter
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            
            // Try with fractional seconds first
            if let date = formatter.date(from: s) {
                return date.timeIntervalSince1970
            }
            
            // Fallback to without fractional seconds
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: s) {
                return date.timeIntervalSince1970
            }
        }
        
        return nil
    }
    
    /// Coerce value to boolean if possible
    public static func asBool(_ value: Any?) -> Bool? {
        switch value {
        case let b as Bool:
            return b
        case let n as NSNumber:
            return n.boolValue
        case let s as String:
            switch s.lowercased() {
            case "true", "yes", "1":
                return true
            case "false", "no", "0":
                return false
            default:
                return nil
            }
        case let n as Double:
            return n != 0
        case let n as Int:
            return n != 0
        default:
            return nil
        }
    }
}

// MARK: - CompareOp

/// Comparison operators
public enum CompareOp: String, Sendable {
    case eq = "=="
    case neq = "!="
    case gt = ">"
    case gte = ">="
    case lt = "<"
    case lte = "<="
    case `in` = "in"
    case notIn = "not_in"
}

// MARK: - Comparer

/// Comparison utilities for IR evaluation. Stateless namespace.
public struct Comparer: Sendable {
    
    /// Compare two values with given operator
    public static func compare(_ op: CompareOp, _ lhs: Any?, _ rhs: Any?) -> Bool {
        // Handle in/not_in specially
        if op == .in || op == .notIn {
            let result = member(lhs, rhs)
            return op == .in ? result : !result
        }
        
        // Try numeric comparison first
        if let l = Coercion.asNumber(lhs), let r = Coercion.asNumber(rhs) {
            switch op {
            case .eq:
                return l == r
            case .neq:
                return l != r
            case .gt:
                return l > r
            case .gte:
                return l >= r
            case .lt:
                return l < r
            case .lte:
                return l <= r
            default:
                return false
            }
        }
        
        // Try string comparison
        if let l = Coercion.asString(lhs), let r = Coercion.asString(rhs) {
            switch op {
            case .eq:
                return l == r
            case .neq:
                return l != r
            case .gt:
                return l > r
            case .gte:
                return l >= r
            case .lt:
                return l < r
            case .lte:
                return l <= r
            default:
                return false
            }
        }
        
        // Try boolean comparison for equality
        if op == .eq || op == .neq {
            if let l = Coercion.asBool(lhs), let r = Coercion.asBool(rhs) {
                return op == .eq ? (l == r) : (l != r)
            }
        }
        
        // Handle null comparisons
        let lhsIsNull = lhs == nil || lhs is NSNull
        let rhsIsNull = rhs == nil || rhs is NSNull
        
        if lhsIsNull || rhsIsNull {
            switch op {
            case .eq:
                return lhsIsNull && rhsIsNull
            case .neq:
                return !(lhsIsNull && rhsIsNull)
            default:
                return false
            }
        }
        
        return false
    }
    
    /// Case-insensitive string contains
    public static func icontains(_ haystack: Any?, _ needle: String) -> Bool {
        if let s = Coercion.asString(haystack) {
            return s.range(of: needle, options: .caseInsensitive) != nil
        }
        
        if let arr = haystack as? [Any] {
            return arr.contains { item in
                if let itemStr = Coercion.asString(item) {
                    return itemStr.localizedCaseInsensitiveContains(needle)
                }
                return false
            }
        }
        
        return false
    }
    
    /// Regular expression match
    public static func regex(_ haystack: Any?, pattern: String) -> Bool {
        guard let s = Coercion.asString(haystack) else {
            return false
        }
        
        do {
            let regex = try NSRegularExpression(pattern: pattern, options: [])
            let range = NSRange(location: 0, length: s.utf16.count)
            return regex.firstMatch(in: s, options: [], range: range) != nil
        } catch {
            // Invalid regex pattern
            return false
        }
    }
    
    /// Check if value is member of list
    public static func member(_ value: Any?, _ list: Any?) -> Bool {
        // Convert list to array
        let array: [Any]
        if let arr = list as? [Any] {
            array = arr
        } else if let irValues = list as? [IRValue] {
            array = irValues.map { $0.toAny() }
        } else {
            return false
        }
        
        // Try string membership
        if let s = Coercion.asString(value) {
            return array.contains { item in
                Coercion.asString(item) == s
            }
        }
        
        // Try number membership
        if let n = Coercion.asNumber(value) {
            return array.contains { item in
                if let itemNum = Coercion.asNumber(item) {
                    return abs(itemNum - n) < Double.ulpOfOne
                }
                return false
            }
        }
        
        // Try boolean membership
        if let b = Coercion.asBool(value) {
            return array.contains { item in
                Coercion.asBool(item) == b
            }
        }
        
        return false
    }
}