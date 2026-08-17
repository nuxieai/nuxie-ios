import Foundation

// MARK: - Batch Response

struct BatchResponse: Codable, Sendable {
    public let status: String
    public let processed: Int
    public let failed: Int
    public let total: Int
    public let errors: [BatchError]?
}

struct BatchError: Codable, Sendable {
    public let index: Int
    public let event: String
    public let error: String
}

// MARK: - Profile Response

public struct ProfileResponse: Codable, Sendable {
    /// Signed release control plane and sole experience-delivery authority.
    let releases: ExperienceReleaseProfileV2?
    /// Segment definitions available for local evaluation.
    let segments: [Segment]
    let userProperties: [String: AnyCodable]?
    /// Server-computed experiment variant assignments (experimentKey -> assignment)
    let experiments: [String: ExperimentAssignment]?
    /// Customer's feature access (from active subscriptions)
    let features: [Feature]?
    /// Authoritative server-evaluated membership snapshot.
    let segmentMemberships: SegmentMembershipSeed?
    /// Undelivered server-born journey facts.
    let facts: [JourneyDownFact]?
    /// Pending or parked journeys offered for an epoch-safe device claim.
    let mailbox: [JourneyMailboxEntry]?

    init(
        segments: [Segment],
        releases: ExperienceReleaseProfileV2? = nil,
        userProperties: [String: AnyCodable]? = nil,
        experiments: [String: ExperimentAssignment]? = nil,
        features: [Feature]? = nil,
        segmentMemberships: SegmentMembershipSeed? = nil,
        facts: [JourneyDownFact]? = nil,
        mailbox: [JourneyMailboxEntry]? = nil
    ) {
        self.releases = releases
        self.segments = segments
        self.userProperties = userProperties
        self.experiments = experiments
        self.features = features
        self.segmentMemberships = segmentMemberships
        self.facts = facts
        self.mailbox = mailbox
    }

}

/// Discriminates server-pending work from a parked-device takeover offer.
enum JourneyMailboxKind: String, Codable, Sendable {
    /// A server-owned device region waiting for a device.
    case pending
    /// A parked device-owned run another device may take over.
    case claimable
}

/// A journey offered to this device for an epoch-safe claim.
struct JourneyMailboxEntry: Codable, Sendable {
    /// Whether the offer is server-pending work or a parked-device takeover.
    public let kind: JourneyMailboxKind
    /// Stable journey identifier.
    public let journeyId: String
    /// Experience definition identifier.
    public let experienceId: String
    /// Published experience version containing the offered region.
    public let experienceVersion: String
    /// Ownership epoch required by the compare-and-swap claim.
    public let epoch: Int
    /// Envelope version advertised independently for cheap compatibility checks.
    public let stateVersion: Int
    /// Canonical state to apply after a successful claim.
    public let envelope: JourneyStateEnvelope
    /// Deadline after which the server may execute the unclaimed fallback.
    public let expiresAt: Date
    /// Checkpoint cursor surfaced for takeover presentation.
    public let resumeNodeId: String?
    /// Age source for an honestly stale takeover checkpoint.
    public let checkpointAt: Date?

    /// Creates a journey mailbox offer.
    ///
    /// - Parameters:
    ///   - kind: Whether the offer is pending server work or a takeover.
    ///   - journeyId: Stable journey identifier.
    ///   - experienceId: Experience definition identifier.
    ///   - experienceVersion: Exact experience version required for resume.
    ///   - epoch: Ownership epoch offered to the claimant.
    ///   - stateVersion: Advertised state-envelope version.
    ///   - envelope: Checkpoint to restore after a successful claim.
    ///   - expiresAt: Deadline after which the offer is no longer claimable.
    ///   - resumeNodeId: Optional node used to describe takeover continuation.
    ///   - checkpointAt: Optional time at which the source device parked.
    public init(
        kind: JourneyMailboxKind = .pending,
        journeyId: String,
        experienceId: String,
        experienceVersion: String,
        epoch: Int,
        stateVersion: Int,
        envelope: JourneyStateEnvelope,
        expiresAt: Date,
        resumeNodeId: String? = nil,
        checkpointAt: Date? = nil
    ) {
        self.kind = kind
        self.journeyId = journeyId
        self.experienceId = experienceId
        self.experienceVersion = experienceVersion
        self.epoch = epoch
        self.stateVersion = stateVersion
        self.envelope = envelope
        self.expiresAt = expiresAt
        self.resumeNodeId = resumeNodeId
        self.checkpointAt = checkpointAt
    }

    /// Whether both advertised and embedded envelope versions are supported.
    public var hasSupportedStateVersion: Bool {
        stateVersion == JourneyStateEnvelope.currentVersion
            && envelope.isSupported
            && envelope.executionState.plane == .device
    }

    /// Metadata a presentation layer can use for "continue from…" copy.
    public var resumePoint: JourneyResumePoint? {
        guard kind == .claimable,
              resumeNodeId != nil || checkpointAt != nil else {
            return nil
        }
        return JourneyResumePoint(
            nodeId: resumeNodeId,
            checkpointAt: checkpointAt
        )
    }
}

/// Authoritative server snapshot for the segment definitions delivered with a profile response.
struct SegmentMembershipSeed: Codable, Equatable, Sendable {
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
struct SeededSegmentMembership: Codable, Equatable, Sendable {
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
struct EntityBalance: Codable, Sendable {
    public let balance: Int
}

/// Feature access state returned from server
/// Represents what features a customer has access to based on their subscriptions
struct Feature: Codable, Sendable {
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
struct ExperimentAssignment: Codable, Sendable {
    public let experimentKey: String
    public let variantKey: String? // nil when draft/paused
    public let status: String
    public let isHoldout: Bool? // nil when variantKey is nil
}

// MARK: - Trigger Models

public struct EventTriggerConfig: Codable, Sendable {
    public let eventName: String
    public let condition: IREnvelope? // Optional IR condition for event properties

    public init(eventName: String, condition: IREnvelope?) {
        self.eventName = eventName
        self.condition = condition
    }
}

/// Enrollment trigger embedded in an experience profile entry.
public enum ExperienceTrigger: Codable, Sendable {
    case event(EventTriggerConfig)
    
    private enum CodingKeys: String, CodingKey, Sendable {
        case type
        case config
    }
    
    private enum TriggerType: String, Codable, Sendable {
        case event
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(TriggerType.self, forKey: .type)
        
        switch type {
        case .event:
            let config = try container.decode(EventTriggerConfig.self, forKey: .config)
            self = .event(config)
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        switch self {
        case .event(let config):
            try container.encode(TriggerType.event, forKey: .type)
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
    /// A duration measured in seconds.
    case second
    case minute
    case hour
    case day
    case week
}

/// Policy controlling whether an experience may enroll a user again.
public enum ExperienceReentry: Codable, Sendable {
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

/// Declares where a segment definition is evaluated.
enum SegmentEvaluation: String, Codable, Sendable {
    /// The server owns membership evaluation and sends authoritative snapshots.
    case server

    /// Decodes unknown future modes conservatively as server-owned.
    public init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        self = SegmentEvaluation(rawValue: rawValue) ?? .server
    }
}

/// A server-evaluated segment definition delivered in a profile response.
struct Segment: Codable, Sendable {
    /// Stable segment identifier.
    public let id: String
    /// Display name.
    public let name: String
    /// Compiled IR retained for compatibility and inspection.
    public let condition: IREnvelope  // Compiled IR expression from backend
    /// Evaluation owner. Experiences support server ownership.
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

// MARK: - Event Response

/// A server-authored journey fact delivered to the SDK.
struct JourneyDownFact: Codable, Equatable, Sendable {
    /// Supported server-to-device journey fact names.
    public enum Event: String, Codable, Sendable {
        /// The server authoritatively attributed a conversion.
        case converted = "$journey_converted"
        /// A requested server effect reached a terminal result.
        case effectCompleted = "$journey_effect_completed"
        /// The server rejected or explicitly cancelled a device-owned run.
        case superseded = "$journey_superseded"
    }

    /// Stable idempotency identifier.
    public let id: String
    /// Canonical journey event name.
    public let event: Event
    /// Time the server authored the fact.
    public let timestamp: Date
    /// Event-specific canonical properties.
    public let properties: Properties

    public enum Properties: Codable, Equatable, Sendable {
        case converted(JourneyConvertedProperties)
        case effectCompleted(JourneyEffectCompletedProperties)
        case superseded(JourneySupersededProperties)

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let converted = try? container.decode(JourneyConvertedProperties.self) {
                self = .converted(converted)
            } else if let effect = try? container.decode(JourneyEffectCompletedProperties.self) {
                self = .effectCompleted(effect)
            } else {
                self = .superseded(try container.decode(JourneySupersededProperties.self))
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .converted(let properties):
                try container.encode(properties)
            case .effectCompleted(let properties):
                try container.encode(properties)
            case .superseded(let properties):
                try container.encode(properties)
            }
        }
    }

    /// Creates a server-authored journey fact.
    public init(
        id: String,
        event: Event,
        timestamp: Date,
        properties: Properties
    ) {
        self.id = id
        self.event = event
        self.timestamp = timestamp
        self.properties = properties
    }

    public init(
        id: String,
        event: Event = .converted,
        timestamp: Date,
        properties: JourneyConvertedProperties
    ) {
        self.init(id: id, event: event, timestamp: timestamp, properties: .converted(properties))
    }
}

/// Down-fact payload that marks a local journey as a non-accounting ghost.
struct JourneySupersededProperties: Codable, Equatable, Sendable {
    /// Journey that lost the ownership race.
    public let journeyId: String
    /// Journey selected as the winner, when the server reports one.
    public let winnerJourneyId: String?

    private enum CodingKeys: String, CodingKey, Sendable {
        case journeyId = "journey_id"
        case winnerJourneyId = "winner_journey_id"
    }
}

struct JourneyEffectCompletedProperties: Codable, Equatable, Sendable {
    public let journeyId: String
    public let nodeId: String
    public let invocationId: String
    public let status: String
    public let result: AnyCodable?
    public let error: AnyCodable?

    private enum CodingKeys: String, CodingKey, Sendable {
        case journeyId = "journey_id"
        case nodeId = "node_id"
        case invocationId = "invocation_id"
        case status
        case result
        case error
    }
}

/// Canonical properties for a server-authored journey conversion fact.
struct JourneyConvertedProperties: Codable, Equatable, Sendable {
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

struct EventResponse: Codable, Sendable {
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
    /// Hint that a profile refetch can claim server-owned journey work.
    public let mailboxPending: Bool?
    /// Synchronous acknowledgement for a `$journey_claimed` CAS.
    ///
    /// Wire key: `journeyClaim`; fields: `journeyId`, `accepted`, `epoch`,
    /// optional `reason`.
    public let journeyClaim: JourneyClaimAcknowledgement?
    /// Ownership result for a retriable journey decision, including handoff.
    public let journeyOwnership: JourneyOwnershipAcknowledgement?

    // Journey-specific decision response fields.
    public let journey: JourneyInfo?

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
        mailboxPending: Bool? = nil,
        journeyClaim: JourneyClaimAcknowledgement? = nil,
        journeyOwnership: JourneyOwnershipAcknowledgement? = nil,
        journey: JourneyInfo? = nil
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
        self.mailboxPending = mailboxPending
        self.journeyClaim = journeyClaim
        self.journeyOwnership = journeyOwnership
        self.journey = journey
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

    /// Result of a journey ownership compare-and-swap request.
    public struct JourneyClaimAcknowledgement: Codable, Sendable {
        /// Journey whose ownership was requested.
        public let journeyId: String
        /// Whether ownership transferred to the requester.
        public let accepted: Bool
        /// Authoritative ownership epoch after evaluating the request.
        public let epoch: Int
        /// Machine-readable rejection reason, when ownership was not transferred.
        public let reason: String?

        /// Creates a journey ownership acknowledgement.
        public init(
            journeyId: String,
            accepted: Bool,
            epoch: Int,
            reason: String? = nil
        ) {
            self.journeyId = journeyId
            self.accepted = accepted
            self.epoch = epoch
            self.reason = reason
        }
    }

    /// Backward-compatible name for an accepted or rejected journey ownership claim.
    public typealias JourneyOwnershipAcknowledgement =
        JourneyClaimAcknowledgement

}


// MARK: - Error Response

struct APIErrorResponse: Codable, Sendable {
    let message: String
    let code: String?
    let details: [String: AnyCodable]?
}

// MARK: - Response Collection Responses

struct ResponseRecordPayload: Codable, Sendable {
    public let id: String
    /// Stable experience definition identifier associated with the response.
    public let experienceId: String
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

struct ResponseSchemaFieldPayload: Codable, Sendable {
    public let key: String
    public let type: String
    public let options: [String]?
    public let min: Double?
    public let max: Double?
}

struct ResponseSchemaVersionPayload: Codable, Sendable {
    public let id: String
    public let responseSchemaId: String
    public let versionSeq: Int
    public let fields: [ResponseSchemaFieldPayload]
    public let createdAt: Date
    public let updatedAt: Date
}

struct ResponseWriteResponse: Codable, Sendable {
    public let status: String
    public let response: ResponseRecordPayload?
    public let version: ResponseSchemaVersionPayload?
}

struct ResponseSubmitResponse: Codable, Sendable {
    public let status: String
    public let response: ResponseRecordPayload?
}

struct ResponseAbandonResponse: Codable, Sendable {
    public let status: String
    public let responses: [ResponseRecordPayload]
}
