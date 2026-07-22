import Foundation

// MARK: - Batch Request

struct BatchRequest: Codable {
    let historicalMigration: Bool?
    let batch: [BatchEventItem]
    
    init(events: [BatchEventItem], historicalMigration: Bool = false) {
        self.batch = events
        self.historicalMigration = historicalMigration ? historicalMigration : nil
    }
    
    enum CodingKeys: String, CodingKey {
        case historicalMigration = "historical_migration"
        case batch
    }
    
    func asDictionary() throws -> [String: Any]? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        let json = try JSONSerialization.jsonObject(with: data, options: [])
        return json as? [String: Any]
    }
}

extension BatchEventItem {
    /// Canonical captured-event → wire-item conversion.
    ///
    /// This is the single place events become batch payloads; semantics are
    /// pinned by `fixtures/events/batch-item-encoding.json` (conformance
    /// vectors shared with the Android SDK). Notably `idempotencyKey` is the
    /// event's own UUIDv7 id so retried batches dedupe server-side.
    public init(event: NuxieEvent) {
        self.init(
            event: event.name,
            distinctId: event.distinctId,
            anonDistinctId: event.properties["$anon_distinct_id"] as? String,
            timestamp: event.timestamp,
            properties: event.properties,
            idempotencyKey: event.id,
            // NSNumber bridging so Int- and Double-typed amounts both lift
            // (a native Swift Int fails a direct `as? Double` cast).
            value: (event.properties["value"] as? NSNumber)?.doubleValue,
            entityId: event.properties["entityId"] as? String
        )
    }
}

public struct BatchEventItem: Codable, Sendable {
    public let event: String
    public let distinctId: String
    public let anonDistinctId: String?
    public let timestamp: String?
    public let properties: [String: AnyCodable]?
    public let idempotencyKey: String?
    public let value: Double?
    public let entityId: String?
    
    public init(
        event: String,
        distinctId: String,
        anonDistinctId: String? = nil,
        timestamp: Date? = nil,
        properties: [String: Any]? = nil,
        idempotencyKey: String? = nil,
        value: Double? = nil,
        entityId: String? = nil
    ) {
        self.event = event
        self.distinctId = distinctId
        self.anonDistinctId = anonDistinctId
        
        // Convert Date to ISO8601 string
        if let timestamp = timestamp {
            let formatter = ISO8601DateFormatter()
            self.timestamp = formatter.string(from: timestamp)
        } else {
            self.timestamp = nil
        }
        
        self.properties = properties?.mapValues { AnyCodable($0) }
        self.idempotencyKey = idempotencyKey
        self.value = value
        self.entityId = entityId
    }
    
    enum CodingKeys: String, CodingKey {
        case event
        case distinctId = "distinct_id"
        case anonDistinctId = "$anon_distinct_id"
        case timestamp
        case properties
        case idempotencyKey = "idempotency_key"
        case value
        case entityId
    }
}

// MARK: - Profile Request

struct ProfileRequest: Codable {
    let distinctId: String
    let locale: String?
    let groups: [String: AnyCodable]?
    let version: Int?

    init(distinctId: String, locale: String? = nil, groups: [String: Any]? = nil, version: Int = 1) {
        self.distinctId = distinctId
        self.locale = locale
        self.groups = groups?.mapValues { AnyCodable($0) }
        self.version = version
    }

    enum CodingKeys: String, CodingKey {
        case distinctId = "distinct_id"
        case locale
        case groups
        case version
    }
}

// MARK: - Event Tracking Request

struct EventRequest: Codable {
    let event: String
    let distinctId: String
    let anonDistinctId: String?
    let timestamp: Date?
    let properties: [String: AnyCodable]?
    let idempotencyKey: String?
    let value: Double?
    let entityId: String?
    
    init(
        event: String,
        distinctId: String,
        anonDistinctId: String? = nil,
        timestamp: Date? = nil,
        properties: [String: Any]? = nil,
        idempotencyKey: String? = nil,
        value: Double? = nil,
        entityId: String? = nil
    ) {
        self.event = event
        self.distinctId = distinctId
        self.anonDistinctId = anonDistinctId
        self.timestamp = timestamp
        self.properties = properties?.mapValues { AnyCodable($0) }
        self.idempotencyKey = idempotencyKey
        self.value = value
        self.entityId = entityId
    }
    
    enum CodingKeys: String, CodingKey {
        case event
        case distinctId = "distinct_id"
        case anonDistinctId = "$anon_distinct_id"
        case timestamp
        case properties
        case idempotencyKey = "idempotency_key"
        case value
        case entityId
    }
}

// MARK: - Response Collection Requests

struct ResponseFieldRequest: Codable {
    let distinctId: String
    let journeySessionId: String
    let responseSchemaId: String
    let schemaVersion: Int?
    let key: String
    let value: AnyCodable

    enum CodingKeys: String, CodingKey {
        case distinctId = "distinct_id"
        case journeySessionId = "journey_session_id"
        case responseSchemaId = "response_schema_id"
        case schemaVersion = "schema_version"
        case key
        case value
    }
}

struct ResponseSubmitRequest: Codable {
    let distinctId: String
    let journeySessionId: String
    let responseSchemaId: String
    let schemaVersion: Int?

    enum CodingKeys: String, CodingKey {
        case distinctId = "distinct_id"
        case journeySessionId = "journey_session_id"
        case responseSchemaId = "response_schema_id"
        case schemaVersion = "schema_version"
    }
}

struct ResponseAbandonRequest: Codable {
    let distinctId: String
    let journeySessionId: String

    enum CodingKeys: String, CodingKey {
        case distinctId = "distinct_id"
        case journeySessionId = "journey_session_id"
    }
}
