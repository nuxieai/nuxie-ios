import Foundation

// MARK: - Journey Expression Schema

/// The portable value vocabulary used by the signed Journey route contract.
///
/// This is deliberately distinct from `AnyCodable`: the tagged reference cases
/// (`Event.Field` and `Response.Field`) must survive decoding all the way to the
/// interpreter instead of being lowered into an untyped IR envelope.
enum JourneyValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JourneyValue])
    case object(ExactJSONObject<JourneyValue>)
    case eventField(String)
    case responseField(String)

    private enum CodingKeys: String, CodingKey {
        case type
        case value
        case items
        case fields
        case key
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "Null": self = .null
        case "Boolean": self = .bool(try container.decode(Bool.self, forKey: .value))
        case "Number": self = .number(try container.decode(Double.self, forKey: .value))
        case "String": self = .string(try container.decode(String.self, forKey: .value))
        case "Array": self = .array(try container.decode([JourneyValue].self, forKey: .items))
        case "Object": self = .object(try container.decode(ExactJSONObject<JourneyValue>.self, forKey: .fields))
        case "Event.Field": self = .eventField(try container.decode(String.self, forKey: .key))
        case "Response.Field": self = .responseField(try container.decode(String.self, forKey: .key))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "unknown JourneyValue type: \(type)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .null: try container.encode("Null", forKey: .type)
        case .bool(let value):
            try container.encode("Boolean", forKey: .type)
            try container.encode(value, forKey: .value)
        case .number(let value):
            try container.encode("Number", forKey: .type)
            try container.encode(value, forKey: .value)
        case .string(let value):
            try container.encode("String", forKey: .type)
            try container.encode(value, forKey: .value)
        case .array(let values):
            try container.encode("Array", forKey: .type)
            try container.encode(values, forKey: .items)
        case .object(let values):
            try container.encode("Object", forKey: .type)
            try container.encode(values, forKey: .fields)
        case .eventField(let key):
            try container.encode("Event.Field", forKey: .type)
            try container.encode(key, forKey: .key)
        case .responseField(let key):
            try container.encode("Response.Field", forKey: .type)
            try container.encode(key, forKey: .key)
        }
    }

    var foundationValue: Any {
        switch self {
        case .null: NSNull()
        case .bool(let value): value
        case .number(let value): value
        case .string(let value): value
        case .array(let values): values.map(\.foundationValue)
        case .object(let values): values.mapValues(\.foundationValue).dictionary
        case .eventField(let key): ["type": "Event.Field", "key": key]
        case .responseField(let key): ["type": "Response.Field", "key": key]
        }
    }

    static func fromFoundation(_ value: Any) -> JourneyValue {
        switch value {
        case is NSNull: return .null
        case let value as Bool: return .bool(value)
        case let value as NSNumber: return .number(value.doubleValue)
        case let value as String: return .string(value)
        case let value as [Any]: return .array(value.map(Self.fromFoundation))
        case let value as [String: Any]: return .object(ExactJSONObject(value.mapValues(Self.fromFoundation)))
        default: return .null
        }
    }
}

indirect enum JourneyCondition: Codable, Sendable, Equatable {
    case truthy(JourneyValue)
    case compare(op: String, left: JourneyValue, right: JourneyValue)
    case contains(collection: JourneyValue, value: JourneyValue)
    case all([JourneyCondition])
    case any([JourneyCondition])
    case not(JourneyCondition)

    private enum CodingKeys: String, CodingKey {
        case type
        case value
        case op
        case left
        case right
        case collection
        case conditions
        case condition
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "Truthy": self = .truthy(try c.decode(JourneyValue.self, forKey: .value))
        case "Compare":
            self = .compare(
                op: try c.decode(String.self, forKey: .op),
                left: try c.decode(JourneyValue.self, forKey: .left),
                right: try c.decode(JourneyValue.self, forKey: .right)
            )
        case "Contains":
            self = .contains(
                collection: try c.decode(JourneyValue.self, forKey: .collection),
                value: try c.decode(JourneyValue.self, forKey: .value)
            )
        case "All": self = .all(try c.decode([JourneyCondition].self, forKey: .conditions))
        case "Any": self = .any(try c.decode([JourneyCondition].self, forKey: .conditions))
        case "Not": self = .not(try c.decode(JourneyCondition.self, forKey: .condition))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: c,
                debugDescription: "unknown JourneyCondition type"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .truthy(let value):
            try c.encode("Truthy", forKey: .type)
            try c.encode(value, forKey: .value)
        case .compare(let op, let left, let right):
            try c.encode("Compare", forKey: .type)
            try c.encode(op, forKey: .op)
            try c.encode(left, forKey: .left)
            try c.encode(right, forKey: .right)
        case .contains(let collection, let value):
            try c.encode("Contains", forKey: .type)
            try c.encode(collection, forKey: .collection)
            try c.encode(value, forKey: .value)
        case .all(let conditions):
            try c.encode("All", forKey: .type)
            try c.encode(conditions, forKey: .conditions)
        case .any(let conditions):
            try c.encode("Any", forKey: .type)
            try c.encode(conditions, forKey: .conditions)
        case .not(let condition):
            try c.encode("Not", forKey: .type)
            try c.encode(condition, forKey: .condition)
        }
    }
}

enum JourneyWaitTrigger: Codable, Sendable, Equatable {
    case responseChange
    case event(eventName: String, payloadSchema: JourneyEventPayloadSchema?)
    case eventOrResponseChange(eventName: String, payloadSchema: JourneyEventPayloadSchema?)

    private enum CodingKeys: String, CodingKey { case kind, eventName, payloadSchema }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "response_change": self = .responseChange
        case "event":
            self = .event(
                eventName: try c.decode(String.self, forKey: .eventName),
                payloadSchema: try c.decodeIfPresent(JourneyEventPayloadSchema.self, forKey: .payloadSchema)
            )
        case "event_or_response_change":
            self = .eventOrResponseChange(
                eventName: try c.decode(String.self, forKey: .eventName),
                payloadSchema: try c.decodeIfPresent(JourneyEventPayloadSchema.self, forKey: .payloadSchema)
            )
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown wait trigger")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .responseChange: try c.encode("response_change", forKey: .kind)
        case .event(let eventName, let payloadSchema):
            try c.encode("event", forKey: .kind)
            try c.encode(eventName, forKey: .eventName)
            try c.encodeIfPresent(payloadSchema, forKey: .payloadSchema)
        case .eventOrResponseChange(let eventName, let payloadSchema):
            try c.encode("event_or_response_change", forKey: .kind)
            try c.encode(eventName, forKey: .eventName)
            try c.encodeIfPresent(payloadSchema, forKey: .payloadSchema)
        }
    }
}

enum JourneyTimezone: Codable, Sendable, Equatable {
    case device
    case appDefault
    case iana(String)

    private enum CodingKeys: String, CodingKey { case kind, identifier }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "device": self = .device
        case "app_default": self = .appDefault
        case "iana": self = .iana(try c.decode(String.self, forKey: .identifier))
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown Journey timezone")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .device: try c.encode("device", forKey: .kind)
        case .appDefault: try c.encode("app_default", forKey: .kind)
        case .iana(let identifier):
            try c.encode("iana", forKey: .kind)
            try c.encode(identifier, forKey: .identifier)
        }
    }

}

struct EventPayloadFieldSchema: Codable, Sendable, Equatable {
    let key: String
    let required: Bool
    let type: String
    let enumValues: [String]?
    let min: Double?
    let max: Double?

    private enum CodingKeys: String, CodingKey { case key, required, type, `enum`, min, max }

    init(key: String, required: Bool, type: String, enumValues: [String]? = nil, min: Double? = nil, max: Double? = nil) {
        self.key = key
        self.required = required
        self.type = type
        self.enumValues = enumValues
        self.min = min
        self.max = max
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        required = try c.decode(Bool.self, forKey: .required)
        type = try c.decode(String.self, forKey: .type)
        enumValues = try c.decodeIfPresent([String].self, forKey: .enum)
        min = try c.decodeIfPresent(Double.self, forKey: .min)
        max = try c.decodeIfPresent(Double.self, forKey: .max)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(key, forKey: .key)
        try c.encode(required, forKey: .required)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(enumValues, forKey: .enum)
        try c.encodeIfPresent(min, forKey: .min)
        try c.encodeIfPresent(max, forKey: .max)
    }
}

struct JourneyEventPayloadSchema: Codable, Sendable, Equatable {
    let type: String
    let fields: [EventPayloadFieldSchema]
    let additionalProperties: Bool

    init(type: String = "object", fields: [EventPayloadFieldSchema], additionalProperties: Bool) {
        self.type = type
        self.fields = fields
        self.additionalProperties = additionalProperties
    }
}

struct JourneyResponseSchema: Codable, Sendable {
    let responseSchemaId: String
    let responseSchemaVersionId: String?

    init(responseSchemaId: String, responseSchemaVersionId: String? = nil) {
        self.responseSchemaId = responseSchemaId
        self.responseSchemaVersionId = responseSchemaVersionId
    }
}
