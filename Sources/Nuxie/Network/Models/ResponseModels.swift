import Foundation

// MARK: - Batch Response

public struct BatchResponse: Codable, Sendable {
    public let status: String
    public let processed: Int
    public let failed: Int
    public let total: Int
    public let errors: [BatchError]?
}

public struct BatchError: Codable, Sendable {
    public let index: Int
    public let event: String
    public let error: String
}

// MARK: - Profile Response

public struct ProfileResponse: Codable, Sendable {
    public let campaigns: [Campaign]
    public let segments: [Segment]
    public let flows: [RemoteFlow]
    public let userProperties: [String: AnyCodable]?
    /// Server-computed experiment variant assignments (experimentKey -> assignment)
    public let experiments: [String: ExperimentAssignment]?
    /// Customer's feature access (from active subscriptions)
    public let features: [Feature]?
    /// Authoritative server-evaluated membership snapshot.
    public let segmentMemberships: SegmentMembershipSeed?
    /// Undelivered server-born journey facts.
    public let facts: [JourneyDownFact]?

    public init(
        campaigns: [Campaign],
        segments: [Segment],
        flows: [RemoteFlow],
        userProperties: [String: AnyCodable]? = nil,
        experiments: [String: ExperimentAssignment]? = nil,
        features: [Feature]? = nil,
        segmentMemberships: SegmentMembershipSeed? = nil,
        facts: [JourneyDownFact]? = nil
    ) {
        self.campaigns = campaigns
        self.segments = segments
        self.flows = flows
        self.userProperties = userProperties
        self.experiments = experiments
        self.features = features
        self.segmentMemberships = segmentMemberships
        self.facts = facts
    }
}

/// Authoritative server snapshot for the segment definitions delivered with a profile response.
public struct SegmentMembershipSeed: Codable, Equatable, Sendable {
    /// Time at which the server last evaluated the snapshot, when available.
    public let evaluatedAt: Date?
    /// Active memberships in the delivered segment closure.
    public let memberships: [SeededSegmentMembership]

    /// Creates an authoritative segment membership snapshot.
    public init(evaluatedAt: Date?, memberships: [SeededSegmentMembership]) {
        self.evaluatedAt = evaluatedAt
        self.memberships = memberships
    }
}

/// One active membership in a server-provided segment snapshot.
public struct SeededSegmentMembership: Codable, Equatable, Sendable {
    /// Stable segment identifier.
    public let segmentId: String
    /// Server-owned time at which the customer entered the segment.
    public let enteredAt: Date

    /// Creates a seeded membership while preserving its server-owned entry time.
    public init(segmentId: String, enteredAt: Date) {
        self.segmentId = segmentId
        self.enteredAt = enteredAt
    }
}

// MARK: - Feature Models

/// The type of feature
public enum FeatureType: String, Codable, Sendable {
    case boolean
    case metered
    case creditSystem
}

/// Balance information for entity-based features (per-project limits, etc.)
public struct EntityBalance: Codable, Sendable {
    public let balance: Int
}

/// Feature access state returned from server
/// Represents what features a customer has access to based on their subscriptions
public struct Feature: Codable, Sendable {
    /// External feature ID
    public let id: String
    /// Feature type (boolean, metered, creditSystem)
    public let type: FeatureType
    /// Current balance (nil if unlimited or boolean)
    public let balance: Int?
    /// Whether this feature has unlimited access
    public let unlimited: Bool
    /// When the balance resets (Unix timestamp ms, nil if no reset)
    public let nextResetAt: Int?
    /// Reset interval (minute, hour, day, week, month, etc.)
    public let interval: String?
    /// Entity-based balances for per-entity limits (optional)
    public let entities: [String: EntityBalance]?
}

/// Pre-computed experiment variant assignment from server
public struct ExperimentAssignment: Codable, Sendable {
    public let experimentKey: String
    public let variantKey: String? // nil when draft/paused
    public let status: String
    public let isHoldout: Bool? // nil when variantKey is nil
}

// MARK: - Campaign Models

// MARK: - Trigger Models

public struct EventTriggerConfig: Codable, Sendable {
    public let eventName: String
    public let condition: IREnvelope? // Optional IR condition for event properties

    public init(eventName: String, condition: IREnvelope?) {
        self.eventName = eventName
        self.condition = condition
    }
}

public struct SegmentTriggerConfig: Codable, Sendable {
    public let condition: IREnvelope // Required IR condition for segment membership

    public init(condition: IREnvelope) {
        self.condition = condition
    }
}

public enum CampaignTrigger: Codable, Sendable {
    case event(EventTriggerConfig)
    case segment(SegmentTriggerConfig)
    
    private enum CodingKeys: String, CodingKey, Sendable {
        case type
        case config
    }
    
    private enum TriggerType: String, Codable, Sendable {
        case event
        case segment
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(TriggerType.self, forKey: .type)
        
        switch type {
        case .event:
            let config = try container.decode(EventTriggerConfig.self, forKey: .config)
            self = .event(config)
        case .segment:
            let config = try container.decode(SegmentTriggerConfig.self, forKey: .config)
            self = .segment(config)
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        switch self {
        case .event(let config):
            try container.encode(TriggerType.event, forKey: .type)
            try container.encode(config, forKey: .config)
        case .segment(let config):
            try container.encode(TriggerType.segment, forKey: .type)
            try container.encode(config, forKey: .config)
        }
    }
}

// MARK: - Reentry Policy

public struct Window: Codable, Sendable {
    public let amount: Int
    public let unit: WindowUnit
}

public enum WindowUnit: String, Codable, Sendable {
    case minute
    case hour
    case day
    case week
}

public enum CampaignReentry: Codable, Sendable {
    case oneTime
    case everyTime
    case oncePerWindow(Window)

    private enum CodingKeys: String, CodingKey, Sendable {
        case type
        case window
    }

    private enum ReentryType: String, Codable, Sendable {
        case oneTime = "one_time"
        case everyTime = "every_time"
        case oncePerWindow = "once_per_window"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ReentryType.self, forKey: .type)

        switch type {
        case .oneTime:
            self = .oneTime
        case .everyTime:
            self = .everyTime
        case .oncePerWindow:
            let window = try container.decode(Window.self, forKey: .window)
            self = .oncePerWindow(window)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .oneTime:
            try container.encode(ReentryType.oneTime, forKey: .type)
        case .everyTime:
            try container.encode(ReentryType.everyTime, forKey: .type)
        case .oncePerWindow(let window):
            try container.encode(ReentryType.oncePerWindow, forKey: .type)
            try container.encode(window, forKey: .window)
        }
    }
}

public struct Campaign: Codable, Sendable {
    public let id: String
    public let name: String
    public let flowId: String
    public let flowNumber: Int
    public let flowName: String?
    public let reentry: CampaignReentry
    public let publishedAt: String
    
    // Trigger configuration (discriminated union)
    public let trigger: CampaignTrigger
    
    // Goal and exit configuration (optional for backward compatibility)
    public let goal: GoalConfig?
    public let exitPolicy: ExitPolicy?
    public let conversionAnchor: String? // Default: "last_flow_shown"
    public let campaignType: String? // Used for default conversion windows
}

/// Declares where a segment definition is evaluated.
public enum SegmentEvaluation: String, Codable, Sendable {
    /// The server owns membership evaluation and sends authoritative snapshots.
    case server

    /// Decodes unknown future modes conservatively as server-owned.
    public init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        self = SegmentEvaluation(rawValue: rawValue) ?? .server
    }
}

/// A server-evaluated segment definition delivered in a profile response.
public struct Segment: Codable, Sendable {
    /// Stable segment identifier.
    public let id: String
    /// Display name.
    public let name: String
    /// Compiled IR retained for compatibility and inspection.
    public let condition: IREnvelope  // Compiled IR expression from backend
    /// Evaluation owner. E1 supports server ownership.
    public let evaluation: SegmentEvaluation

    /// Creates a segment definition.
    public init(
        id: String,
        name: String,
        condition: IREnvelope,
        evaluation: SegmentEvaluation = .server
    ) {
        self.id = id
        self.name = name
        self.condition = condition
        self.evaluation = evaluation
    }

    private enum CodingKeys: String, CodingKey, Sendable {
        case id
        case name
        case condition
        case evaluation
    }

    /// Decodes a segment, defaulting older payloads without an owner to server evaluation.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        condition = try container.decode(IREnvelope.self, forKey: .condition)
        evaluation = try container.decodeIfPresent(SegmentEvaluation.self, forKey: .evaluation) ?? .server
    }
}

public struct BuildManifest: Codable, Equatable, Sendable {
    public let totalFiles: Int
    public let totalSize: Int
    public let contentHash: String
    public let files: [BuildFile]
}

public struct BuildFile: Codable, Equatable, Hashable, Sendable {
    public let path: String
    public let size: Int
    public let contentType: String
}

// MARK: - Event Response

/// A server-authored journey fact delivered to the SDK.
public struct JourneyDownFact: Codable, Equatable, Sendable {
    /// Supported server-to-device journey fact names.
    public enum Event: String, Codable, Sendable {
        /// The server authoritatively attributed a conversion.
        case converted = "$journey_converted"
    }

    /// Stable idempotency identifier.
    public let id: String
    /// Canonical journey event name.
    public let event: Event
    /// Time the server authored the fact.
    public let timestamp: Date
    /// Canonical converted-fact properties.
    public let properties: JourneyConvertedProperties

    /// Creates a server-authored journey fact.
    public init(
        id: String,
        event: Event,
        timestamp: Date,
        properties: JourneyConvertedProperties
    ) {
        self.id = id
        self.event = event
        self.timestamp = timestamp
        self.properties = properties
    }
}

/// Canonical properties for a server-authored journey conversion fact.
public struct JourneyConvertedProperties: Codable, Equatable, Sendable {
    /// Run identifier receiving the conversion.
    public let journeyId: String
    /// Authoritative conversion time.
    public let at: Date
    /// Identifier of the source fact used for attribution.
    public let sourceFactRef: String

    /// Creates canonical converted-fact properties.
    public init(journeyId: String, at: Date, sourceFactRef: String) {
        self.journeyId = journeyId
        self.at = at
        self.sourceFactRef = sourceFactRef
    }

    private enum CodingKeys: String, CodingKey, Sendable {
        case journeyId = "journey_id"
        case at
        case sourceFactRef = "source_fact_ref"
    }
}

public struct EventResponse: Codable, Sendable {
    public let status: String
    public let payload: [String: AnyCodable]?
    public let customer: Customer?
    public let eventId: String?
    public let customerId: String?
    public let message: String?
    public let featuresMatched: Int?
    public let deduped: Bool?
    public let merged: Bool?
    public let migratedDistinctIds: [String]?
    public let usage: Usage?
    public let facts: [JourneyDownFact]?

    // Journey-specific response fields (for $journey_start, $journey_node_executed, $journey_completed)
    public let journey: JourneyInfo?
    public let execution: ExecutionResult?

    public struct Customer: Codable, Sendable {
        public let id: String
        public let properties: [String: AnyCodable]?
    }

    public init(
        status: String,
        payload: [String: AnyCodable]? = nil,
        customer: Customer? = nil,
        eventId: String? = nil,
        customerId: String? = nil,
        message: String? = nil,
        featuresMatched: Int? = nil,
        deduped: Bool? = nil,
        merged: Bool? = nil,
        migratedDistinctIds: [String]? = nil,
        usage: Usage? = nil,
        facts: [JourneyDownFact]? = nil,
        journey: JourneyInfo? = nil,
        execution: ExecutionResult? = nil
    ) {
        self.status = status
        self.payload = payload
        self.customer = customer
        self.eventId = eventId
        self.customerId = customerId
        self.message = message
        self.featuresMatched = featuresMatched
        self.deduped = deduped
        self.merged = merged
        self.migratedDistinctIds = migratedDistinctIds
        self.usage = usage
        self.facts = facts
        self.journey = journey
        self.execution = execution
    }

    public struct Usage: Codable, Sendable {
        public let current: Double
        public let limit: Double?
        public let remaining: Double?
    }

    /// Journey state returned from server (for cross-device tracking)
    public struct JourneyInfo: Codable, Sendable {
        public let sessionId: String?
        public let currentNodeId: String?
        public let status: String?  // "active" or "completed"
    }

    /// Execution result for remote nodes
    public struct ExecutionResult: Codable, Sendable {
        public let success: Bool
        public let statusCode: Int?
        public let error: ExecutionError?
        public let contextUpdates: [String: AnyCodable]?

        public struct ExecutionError: Codable, Sendable {
            public let message: String
            public let retryable: Bool
            public let retryAfter: Int?
        }
    }
}


// MARK: - Error Response

struct APIErrorResponse: Codable, Sendable {
    let message: String
    let code: String?
    let details: [String: AnyCodable]?
}

// MARK: - Response Collection Responses

public struct ResponseRecordPayload: Codable, Sendable {
    public let id: String
    public let campaignId: String
    public let journeyId: String
    public let customerId: String
    public let responseSchemaId: String
    public let responseSchemaVersionId: String
    public let schemaVersion: Int
    public let state: String
    public let values: [String: AnyCodable]
    public let createdAt: Date
    public let updatedAt: Date
    public let submittedAt: Date?
    public let abandonedAt: Date?
}

public struct ResponseSchemaFieldPayload: Codable, Sendable {
    public let key: String
    public let type: String
    public let options: [String]?
    public let min: Double?
    public let max: Double?
}

public struct ResponseSchemaVersionPayload: Codable, Sendable {
    public let id: String
    public let responseSchemaId: String
    public let versionSeq: Int
    public let fields: [ResponseSchemaFieldPayload]
    public let createdAt: Date
    public let updatedAt: Date
}

public struct ResponseWriteResponse: Codable, Sendable {
    public let status: String
    public let response: ResponseRecordPayload?
    public let version: ResponseSchemaVersionPayload?
}

public struct ResponseSubmitResponse: Codable, Sendable {
    public let status: String
    public let response: ResponseRecordPayload?
}

public struct ResponseAbandonResponse: Codable, Sendable {
    public let status: String
    public let responses: [ResponseRecordPayload]
}
