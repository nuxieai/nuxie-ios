import Foundation

/// A JSON-safe scalar delivered in forwarded activity and App Action payloads.
public enum NuxieActivityValue: Sendable, Equatable {
    /// A UTF-8 string value.
    case string(String)
    /// A signed integer value.
    case int(Int)
    /// A floating-point value.
    case double(Double)
    /// A Boolean value.
    case bool(Bool)
}

public extension Dictionary where Key == String, Value == NuxieActivityValue {
    /// Converts forwarding values into the ordinary dictionary shape accepted
    /// by analytics SDKs such as Amplitude, Mixpanel, and PostHog.
    var analyticsDictionary: [String: Any] {
        mapValues(\.analyticsValue)
    }
}

extension NuxieActivityValue {
    var analyticsValue: Any {
        switch self {
        case .string(let value): value
        case .int(let value): value
        case .double(let value): value
        case .bool(let value): value
        }
    }

    /// Converts a resolved authored value into the public scalar vocabulary.
    /// Arrays and objects remain lossless by crossing the scalar-only public
    /// seam as compact JSON strings.
    static func resolved(_ value: Any) -> NuxieActivityValue? {
        if value is NSNull { return nil }
        // NSNumber bridges 0/1 to Bool eagerly; only a true CFBoolean may
        // become .bool, so numeric ids and counts stay numeric.
        if let number = value as? NSNumber,
           CFGetTypeID(number) == CFBooleanGetTypeID() {
            return .bool(number.boolValue)
        }
        if let value = value as? Int { return .int(value) }
        if let value = value as? Double {
            guard value.isFinite else { return nil }
            return .double(value)
        }
        if let value = value as? Float {
            guard value.isFinite else { return nil }
            return .double(Double(value))
        }
        if let value = value as? Decimal {
            return .double(NSDecimalNumber(decimal: value).doubleValue)
        }
        if let value = value as? String { return .string(value) }
        if let value = value as? NSNumber {
            let double = value.doubleValue
            if double.isFinite,
               double.rounded() == double,
               double >= Double(Int.min),
               double <= Double(Int.max) {
                return .int(value.intValue)
            }
            guard double.isFinite else { return nil }
            return .double(double)
        }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(
                withJSONObject: value,
                options: [.sortedKeys, .withoutEscapingSlashes]
              ) else {
            return nil
        }
        return .string(String(decoding: data, as: UTF8.self))
    }

    static func resolvedRecord(_ values: [String: Any]) -> [String: NuxieActivityValue] {
        values.reduce(into: [:]) { result, pair in
            result[pair.key] = resolved(pair.value)
        }
    }
}
