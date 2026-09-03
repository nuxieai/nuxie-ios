import Foundation

/// Resolves only the leg's declared event and buffered response context. An
/// absent field is unknown; explicit JSON null stays a known value. In
/// particular, negation cannot turn an unavailable input into permission.
enum JourneyValues {
    static func resolve(_ value: JourneyValue, context: ArmedJourney.Context) -> JourneyReleaseJSONValue? {
        switch value {
        case .null: return .null
        case .bool(let value): return .bool(value)
        case .number(let value): return .number(value)
        case .string(let value): return .string(value)
        case .eventField(let key): return exactField(key, in: context.event)
        case .responseField(let key): return exactField(key, in: context.responses)
        case .array(let items):
            var result: [JourneyReleaseJSONValue] = []
            for item in items {
                guard let resolved = resolve(item, context: context) else { return nil }
                result.append(resolved)
            }
            return .array(result)
        case .object(let fields):
            var result: ExactJSONObject<JourneyReleaseJSONValue> = [:]
            for (key, value) in fields {
                guard let resolved = resolve(value, context: context) else { return nil }
                result[key] = resolved
            }
            return .object(result)
        }
    }

    static func evaluate(_ condition: JourneyCondition, context: ArmedJourney.Context) -> Bool? {
        switch condition {
        case .truthy(let expression):
            return resolve(expression, context: context).map(truthy)
        case .not(let child):
            return evaluate(child, context: context).map { !$0 }
        case .all(let children):
            let results = children.map { evaluate($0, context: context) }
            if results.contains(false) { return false }
            return results.contains(nil) ? nil : true
        case .any(let children):
            let results = children.map { evaluate($0, context: context) }
            if results.contains(true) { return true }
            return results.contains(nil) ? nil : false
        case .contains(let collection, let value):
            guard let collection = resolve(collection, context: context),
                  let value = resolve(value, context: context) else { return nil }
            switch (collection, value) {
            case (.array(let items), _): return items.contains { equal($0, value) }
            case (.string(let text), .string(let needle)):
                return contains(text, needle)
            default: return false
            }
        case .compare(let op, let left, let right):
            guard let left = resolve(left, context: context),
                  let right = resolve(right, context: context) else { return nil }
            if op == "==" { return equal(left, right) }
            if op == "!=" { return !equal(left, right) }
            let less: Bool, same: Bool
            switch (left, right) {
            case (.number(let a), .number(let b)): less = a < b; same = a == b
            case (.string(let a), .string(let b)):
                less = a.utf16.lexicographicallyPrecedes(b.utf16)
                same = a.utf16.elementsEqual(b.utf16)
            default: return nil
            }
            switch op {
            case "<": return less
            case "<=": return less || same
            case ">": return !less && !same
            case ">=": return !less
            default: return nil
            }
        }
    }

    /// KMP keeps adversarial repeated-prefix strings linear in input size,
    /// while comparing exact code units instead of Swift's normalized text.
    private static func contains(_ text: String, _ needle: String) -> Bool {
        let target = Array(needle.utf16)
        guard !target.isEmpty else { return true }
        var prefixes = [Int](repeating: 0, count: target.count)
        var matched = 0
        for index in target.indices.dropFirst() {
            while matched > 0 && target[index] != target[matched] { matched = prefixes[matched - 1] }
            if target[index] == target[matched] { matched += 1 }
            prefixes[index] = matched
        }
        matched = 0
        for unit in text.utf16 {
            while matched > 0 && unit != target[matched] { matched = prefixes[matched - 1] }
            if unit == target[matched] { matched += 1 }
            if matched == target.count { return true }
        }
        return false
    }

    private static func exactField(_ key: String, in fields: ExactJSONObject<JourneyReleaseJSONValue>) -> JourneyReleaseJSONValue? {
        // Swift String equality normalizes Unicode; the wire contract uses
        // exact JSON keys and ordinal UTF-16 string comparisons like JS/Kotlin.
        fields[key]
    }

    private static func truthy(_ value: JourneyReleaseJSONValue) -> Bool {
        switch value {
        case .null: false
        case .bool(let value): value
        case .number(let value): value != 0
        case .string(let value): !value.isEmpty
        case .array, .object: true
        }
    }

    private static func equal(_ left: JourneyReleaseJSONValue, _ right: JourneyReleaseJSONValue) -> Bool {
        switch (left, right) {
        case (.null, .null): return true
        case (.bool(let a), .bool(let b)): return a == b
        case (.number(let a), .number(let b)): return a == b
        case (.string(let a), .string(let b)): return a.utf16.elementsEqual(b.utf16)
        case (.array(let a), .array(let b)):
            return a.count == b.count && zip(a, b).allSatisfy { equal($0.0, $0.1) }
        case (.object(let a), .object(let b)):
            let keys = a.keys.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
            let other = b.keys.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
            return keys.count == other.count && zip(keys, other).allSatisfy { leftKey, rightKey in
                leftKey.utf16.elementsEqual(rightKey.utf16) && equal(a[leftKey]!, b[rightKey]!)
            }
        default: return false
        }
    }
}
