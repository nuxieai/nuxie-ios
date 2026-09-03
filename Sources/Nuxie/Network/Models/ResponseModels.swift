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

/// App authority established by the authenticated profile transport. This is
/// response metadata, never a field the profile body can nominate.
struct ProfileDeliveryAuthority: Codable, Equatable, Sendable {
    let appId: String
    let environment: String

    var isValid: Bool {
        Self.valid(appId, maximumBytes: 256)
            && Self.valid(environment, maximumBytes: 16)
            && (environment == "live" || environment == "test")
    }

    private static func valid(_ value: String, maximumBytes: Int) -> Bool {
        !value.isEmpty
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && value.utf8.count <= maximumBytes
            && !value.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0)
            }
    }
}

struct ProfileResponse: Codable, Sendable {
    /// The sole SDK delivery contract. The network endpoint returns this body
    /// directly; the wrapper exists only for the SDK cache protocol.
    let planeProfile: JourneyPlaneProfile

    init(planeProfile: JourneyPlaneProfile) {
        self.planeProfile = planeProfile
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        planeProfile = try container.decode(JourneyPlaneProfile.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(planeProfile)
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
    public let balance: Double
}

/// Feature access state returned from server
/// Represents what features a customer has access to based on their subscriptions
struct Feature: Codable, Sendable {
    /// External feature ID
    public let id: String
    /// Feature type (boolean, metered, creditSystem)
    public let type: FeatureType
    /// Current balance (nil if unlimited or boolean)
    public let balance: Double?
    /// Whether this feature has unlimited access
    public let unlimited: Bool
    /// When the balance resets (Unix timestamp ms, nil if no reset)
    public let nextResetAt: Int?
    /// Reset interval (minute, hour, day, week, month, etc.)
    public let interval: String?
    /// Entity-based balances for per-entity limits (optional)
    public let entities: [String: EntityBalance]?
}

// MARK: - Event Response

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
        usage: Usage? = nil
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
    }

    public struct Usage: Codable, Sendable {
        public let current: Double
        public let limit: Double?
        public let remaining: Double?
    }

}


// MARK: - Error Response

struct APIErrorResponse: Codable, Sendable {
    let message: String
    let code: String?
    let details: [String: AnyCodable]?
}
