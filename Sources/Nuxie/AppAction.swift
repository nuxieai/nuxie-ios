import Foundation

/// A JSON-safe scalar delivered in an App Action payload.
public enum AppActionValue: Sendable, Equatable {
    /// A string value.
    case string(String)
    /// A signed integer value.
    case int(Int)
    /// A finite floating-point value.
    case double(Double)
    /// A Boolean value.
    case bool(Bool)
}

/// A named action requested by an experience for the host app to perform.
public struct AppAction: Sendable, Equatable {
    /// The designer-authored action name.
    public let name: String
    /// The fully resolved action payload, when one was authored.
    public let payload: [String: AppActionValue]?
    /// The experience and journey that requested the action.
    public let experience: ExperienceRef
}

extension AppAction {
    /// Canonical wrapper encoding pinned by
    /// `fixtures/encodings/app-action.json`.
    @_spi(Testing)
    public var wireValue: [String: AnyCodable] {
        let experienceValue: [String: Any] = [
            "experienceId": experience.experienceId,
            "experienceVersion": experience.experienceVersion ?? NSNull(),
            "journeyId": experience.journeyId ?? NSNull(),
        ]
        let payloadValue: Any = payload.map { payload in
            payload.mapValues(\.wireScalar)
        } ?? NSNull()

        return [
            "name": AnyCodable(name),
            "payload": AnyCodable(payloadValue),
            "experience": AnyCodable(experienceValue),
        ]
    }
}

extension AppActionValue {
    fileprivate var wireScalar: Any {
        switch self {
        case .string(let value): value
        case .int(let value): value
        case .double(let value): value
        case .bool(let value): value
        }
    }

    /// Converts a resolved authored value into the public scalar vocabulary.
    /// Arrays and objects remain lossless as compact JSON strings.
    static func resolved(_ value: Any) -> AppActionValue? {
        if value is NSNull { return nil }
        // NSNumber bridges 0/1 to Bool eagerly; only a true CFBoolean may
        // become .bool, so numeric identifiers and counts stay numeric.
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
            let double = NSDecimalNumber(decimal: value).doubleValue
            guard double.isFinite else { return nil }
            return .double(double)
        }
        if let value = value as? String { return .string(value) }
        if let value = value as? NSNumber {
            // Exact signed-integer round trip: comparing doubleValue against
            // Double(Int.max) admits unsigned values just past Int.max
            // (they round to the same Double) and intValue would wrap them
            // negative, so verify the value survives the conversion intact.
            let candidate = value.intValue
            if NSNumber(value: candidate) == value {
                return .int(candidate)
            }
            let double = value.doubleValue
            guard double.isFinite else { return nil }
            return .double(double)
        }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? DeterministicJSONSerializer.data(withJSONObject: value) else {
            return nil
        }
        return .string(String(decoding: data, as: UTF8.self))
    }

    /// Wire-safe projection of a resolved record: same admission rules as
    /// `resolvedRecord` (non-finite numbers dropped, containers encoded as
    /// JSON strings), returned as plain values for event properties.
    static func sanitizedRecord(_ values: [String: Any]) -> [String: Any] {
        resolvedRecord(values).mapValues { value -> Any in
            switch value {
            case .string(let string): string
            case .int(let int): int
            case .double(let double): double
            case .bool(let bool): bool
            }
        }
    }

    static func resolvedRecord(_ values: [String: Any]) -> [String: AppActionValue] {
        values.reduce(into: [:]) { result, pair in
            result[pair.key] = resolved(pair.value)
        }
    }
}

/// Compact JSON with object keys sorted recursively by raw UTF-16 code units.
private enum DeterministicJSONSerializer {
    enum SerializationError: Error {
        case invalidJSONObject
    }

    static func data(withJSONObject value: Any) throws -> Data {
        guard JSONSerialization.isValidJSONObject(value) else {
            throw SerializationError.invalidJSONObject
        }

        var data = Data()
        try append(value, to: &data)
        return data
    }

    private static func append(_ value: Any, to data: inout Data) throws {
        if let object = value as? [String: Any] {
            data.append(0x7B) // {
            for (index, key) in object.keys.sorted(by: utf16LessThan).enumerated() {
                if index > 0 { data.append(0x2C) } // ,
                try appendScalar(key, to: &data)
                data.append(0x3A) // :
                guard let member = object[key] else {
                    throw SerializationError.invalidJSONObject
                }
                try append(member, to: &data)
            }
            data.append(0x7D) // }
        } else if let array = value as? [Any] {
            data.append(0x5B) // [
            for (index, element) in array.enumerated() {
                if index > 0 { data.append(0x2C) } // ,
                try append(element, to: &data)
            }
            data.append(0x5D) // ]
        } else {
            try appendScalar(value, to: &data)
        }
    }

    private static func appendScalar(_ value: Any, to data: inout Data) throws {
        data.append(try JSONSerialization.data(
            withJSONObject: value,
            options: [.fragmentsAllowed, .withoutEscapingSlashes]
        ))
    }

    private static func utf16LessThan(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf16.lexicographicallyPrecedes(rhs.utf16)
    }
}
