import Foundation

/// Resolves `{literal:}` / `{ref:}` value expressions from journey actions.
///
/// Data-in/data-out: a value tree, the trigger payload, and a synchronous
/// view-model lookup go in; a plain value comes out. No runner state — this
/// shape is the portable spec for other SDK platforms.
struct ValueRefResolver {
    /// Trigger payload for `{kind: "payload"}` refs.
    let payload: [String: Any]?
    /// Synchronous view-model value lookup for `{kind: "path"}` refs.
    let lookup: (VmPathRef) -> Any?

    func resolve(_ value: Any) -> Any {
        if let list = value as? [Any] {
            return list.map { resolve($0) }
        }
        if let list = value as? [AnyCodable] {
            return list.map { resolve($0.value) }
        }
        if let dict = value as? [String: Any] {
            if dict.count == 1, let literal = dict["literal"] {
                return literal
            }
            if dict.count == 1, let refValue = dict["ref"], let ref = Self.parseRefPath(refValue) {
                return lookup(ref) as Any
            }
            if dict.count == 1, let refValue = dict["ref"], let payloadPath = Self.parsePayloadRefPath(refValue) {
                return Self.resolvePayloadPath(payloadPath, in: payload) as Any
            }
            var resolved: [String: Any] = [:]
            for (key, entry) in dict {
                resolved[key] = resolve(entry)
            }
            return resolved
        }
        if let dict = value as? [String: AnyCodable] {
            if dict.count == 1, let literal = dict["literal"]?.value {
                return literal
            }
            if dict.count == 1, let refValue = dict["ref"]?.value, let ref = Self.parseRefPath(refValue) {
                return lookup(ref) as Any
            }
            if dict.count == 1, let refValue = dict["ref"]?.value, let payloadPath = Self.parsePayloadRefPath(refValue) {
                return Self.resolvePayloadPath(payloadPath, in: payload) as Any
            }
            var resolved: [String: Any] = [:]
            for (key, entry) in dict {
                resolved[key] = resolve(entry.value)
            }
            return resolved
        }
        return value
    }

    static func parseRefPath(_ value: Any) -> VmPathRef? {
        if let ref = value as? VmPathRef { return ref }
        if let dict = value as? [String: Any] {
            if dict["kind"] as? String == "path", let path = dict["path"] as? String {
                return VmPathRef(
                    viewModelName: dict["viewModelName"] as? String,
                    path: path,
                    isRelative: dict["isRelative"] as? Bool
                )
            }
        }
        if let dict = value as? [String: AnyCodable] {
            if dict["kind"]?.value as? String == "path", let path = dict["path"]?.value as? String {
                return VmPathRef(
                    viewModelName: dict["viewModelName"]?.value as? String,
                    path: path,
                    isRelative: dict["isRelative"]?.value as? Bool
                )
            }
        }
        return nil
    }

    static func parsePayloadRefPath(_ value: Any) -> String? {
        if let dict = value as? [String: Any],
           dict["kind"] as? String == "payload",
           let path = dict["path"] as? String,
           !path.isEmpty {
            return path
        }
        if let dict = value as? [String: AnyCodable],
           dict["kind"]?.value as? String == "payload",
           let path = dict["path"]?.value as? String,
           !path.isEmpty {
            return path
        }
        return nil
    }

    static func resolvePayloadPath(_ path: String, in payload: [String: Any]?) -> Any? {
        guard let payload else { return nil }
        var current: Any? = payload
        for segment in path.split(separator: ".").map(String.init) {
            if let dict = current as? [String: Any] {
                current = dict[segment]
            } else if let dict = current as? [String: AnyCodable] {
                current = dict[segment]?.value
            } else {
                return nil
            }
        }
        return current
    }

    static func unwrapRuntimeValue(_ value: Any) -> Any {
        if let anyCodable = value as? AnyCodable {
            return unwrapRuntimeValue(anyCodable.value)
        }
        return value
    }
}

/// Payload-schema gating for host event declarations: an event only
/// dispatches when its payload satisfies the declared field types.
enum EventPayloadSchemaMatcher {
    static func matches(_ payload: [String: Any], schema: EventPayloadSchema) -> Bool {
        for (field, expectedType) in schema {
            guard let value = ValueRefResolver.resolvePayloadPath(field, in: payload) else {
                return false
            }
            if !self.value(value, matches: expectedType) {
                return false
            }
        }
        return true
    }

    static func value(_ value: Any, matches expectedType: EventPayloadFieldType) -> Bool {
        let unwrapped = ValueRefResolver.unwrapRuntimeValue(value)
        switch expectedType {
        case .string:
            return unwrapped is String
        case .number:
            return unwrapped is Int || unwrapped is Double || unwrapped is Float || unwrapped is NSNumber
        case .boolean:
            return unwrapped is Bool
        case .object:
            return unwrapped is [String: Any] || unwrapped is [String: AnyCodable]
        case .array:
            return unwrapped is [Any] || unwrapped is [AnyCodable]
        }
    }
}
