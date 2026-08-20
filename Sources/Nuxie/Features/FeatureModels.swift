import Foundation

// MARK: - Feature Access

/// Result of a feature access check
/// Provides a simplified view for SDK consumers
public struct FeatureAccess: Sendable {
    /// Whether the user is allowed to use this feature
    public let allowed: Bool

    /// Whether the feature has unlimited access (no balance tracking)
    public let unlimited: Bool

    /// Current balance (nil if unlimited or boolean feature)
    public let balance: Double?

    /// The feature type
    public let type: FeatureType

    /// The exact requested-feature amount covered by a server-authoritative
    /// decision whose balance is expressed in another Feature's units.
    /// Ordinary metered access never carries this provenance.
    internal let opaqueRequiredBalance: Double?

    /// Convenience: returns true if allowed
    public var hasAccess: Bool { allowed }

    /// Convenience: returns true if unlimited or balance > 0
    public var hasBalance: Bool {
        unlimited || (balance ?? 0) > 0
    }

    /// Create from a cached Feature (from profile response)
    init(from feature: Feature, requiredBalance: Double = 1) {
        self.type = feature.type
        self.unlimited = feature.unlimited
        self.balance = feature.balance
        self.opaqueRequiredBalance = nil

        switch feature.type {
        case .boolean:
            // Boolean features: just check presence
            self.allowed = true
        case .metered, .creditSystem:
            // Metered/Credit: check balance or unlimited
            if feature.unlimited {
                self.allowed = true
            } else {
                self.allowed = (feature.balance ?? 0) >= requiredBalance
            }
        }
    }

    /// Create from a FeatureCheckResult (from real-time API)
    init(from result: FeatureCheckResult) {
        self.allowed = result.allowed
        self.unlimited = result.unlimited
        self.balance = result.balance
        self.type = result.type
        self.opaqueRequiredBalance = nil
    }

    /// Create the access snapshot for the feature the caller requested. A
    /// transitive credit-system response names and measures the balance-source
    /// wallet, so its units must not be exposed as the requested feature's
    /// balance.
    init(authoritative result: FeatureCheckResult, requestedFeatureId: String) {
        guard result.featureId != requestedFeatureId else {
            self.init(from: result)
            return
        }
        self.init(
            allowed: result.allowed,
            unlimited: result.unlimited,
            // Zero is invariant under every positive conversion ratio; any
            // non-zero wallet balance is opaque in requested-feature units.
            balance: result.balance == 0 ? 0 : nil,
            type: .metered,
            opaqueRequiredBalance: result.requiredBalance
        )
    }

    /// Create from a PurchaseFeature (from purchase sync response)
    init(from purchase: PurchaseFeature) {
        self.allowed = purchase.allowed
        self.unlimited = purchase.unlimited
        self.balance = purchase.balance
        self.type = purchase.type
        self.opaqueRequiredBalance = nil
    }

    /// Create a "not found" result
    static var notFound: FeatureAccess {
        FeatureAccess(allowed: false, unlimited: false, balance: nil, type: .boolean)
    }

    /// Create with a specific balance (for local balance updates)
    static func withBalance(_ balance: Double, unlimited: Bool, type: FeatureType) -> FeatureAccess {
        FeatureAccess(
            allowed: unlimited || balance >= 1,
            unlimited: unlimited,
            balance: balance,
            type: type
        )
    }

    init(
        allowed: Bool,
        unlimited: Bool,
        balance: Double?,
        type: FeatureType,
        opaqueRequiredBalance: Double? = nil
    ) {
        self.allowed = allowed
        self.unlimited = unlimited
        self.balance = balance
        self.type = type
        self.opaqueRequiredBalance = opaqueRequiredBalance
    }
}

// MARK: - Feature Check Result

/// Response from the real-time /entitled endpoint
struct FeatureCheckResult: Codable, Sendable {
    public let customerId: String
    public let featureId: String
    public let requiredBalance: Double
    public let code: String
    public let allowed: Bool
    public let unlimited: Bool
    public let balance: Double?
    public let type: FeatureType
    public let preview: AnyCodable?
}

// MARK: - Feature Check Request

/// Request parameters for entitlement check
struct FeatureCheckRequest: Codable {
    let customerId: String
    let featureId: String
    let requiredBalance: Double?
    let entityId: String?
}

// MARK: - Purchase Request

/// Request for syncing App Store transactions
struct PurchaseRequest: Codable {
    /// Purchase type discriminator - always "appstore" for iOS SDK
    let type: String = "appstore"
    /// Signed transaction JWT from StoreKit 2
    let transactionJwt: String
    /// User's distinct ID for customer lookup
    let distinctId: String

    enum CodingKeys: String, CodingKey {
        case type
        case transactionJwt = "transaction_jwt"
        case distinctId = "distinct_id"
    }
}

struct PurchaseBackedFeatureUseRequest: Codable, Sendable {
    struct Purchase: Codable, Sendable {
        let transactionJwt: String
        let eventId: String

        enum CodingKeys: String, CodingKey {
            case transactionJwt = "transaction_jwt"
            case eventId = "event_id"
        }
    }

    struct EventData: Codable, Sendable {
        let value: Double
        let properties: [String: AnyCodable]?
    }

    let customerId: String
    let featureId: String
    let requiredBalance: Double
    let eventData: EventData
    let entityId: String?
    let purchase: Purchase
}

struct PurchaseBackedFeatureUseResponse: Codable, Sendable {
    let customerId: String
    let featureId: String
    let code: String
    let allowed: Bool
    let unlimited: Bool
    let balance: Double?
    let type: FeatureType

    func featureCheckResult(requiredBalance: Double) -> FeatureCheckResult {
        FeatureCheckResult(
            customerId: customerId,
            featureId: featureId,
            requiredBalance: requiredBalance,
            code: code,
            allowed: allowed,
            unlimited: unlimited,
            balance: balance,
            type: type,
            preview: nil
        )
    }
}

// MARK: - Purchase Response

/// Response from the /purchase endpoint after syncing an App Store transaction
struct PurchaseResponse: Codable, Sendable {
    /// Whether the transaction was processed successfully
    public let success: Bool
    /// Customer ID (if successful)
    public let customerId: String?
    /// Updated feature access list
    public let features: [PurchaseFeature]?
    /// Error message (if failed)
    public let error: String?

    enum CodingKeys: String, CodingKey {
        case success
        case customerId = "customer_id"
        case features
        case error
    }
}

/// Feature access from purchase response
struct PurchaseFeature: Codable, Sendable {
    public let id: String
    public let extId: String?
    public let type: FeatureType
    public let allowed: Bool
    public let balance: Double?
    public let unlimited: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case extId = "ext_id"
        case type
        case allowed
        case balance
        case unlimited
    }

    /// Convert to FeatureAccess for cache update
    var toFeatureAccess: FeatureAccess {
        FeatureAccess(from: self)
    }
}

// MARK: - Feature Usage Result

/// Result of a feature usage report
public struct FeatureUsageResult: Sendable {
    /// Whether the usage was recorded successfully
    public let success: Bool

    /// The feature ID that was used
    public let featureId: String

    /// The amount that was consumed
    public let amountUsed: Double

    /// Optional message from the server
    public let message: String?

    /// Updated usage information (if available)
    public let usage: UsageInfo?

    /// Authoritative access returned by an atomic purchase-backed use. This is
    /// nil for ordinary usage events whose response only contains usage data.
    public let authoritativeAccess: FeatureAccess?

    /// Usage information from the server
    public struct UsageInfo: Sendable {
        /// Current usage amount
        public let current: Double
        /// Usage limit (if set)
        public let limit: Double?
        /// Remaining balance (if available)
        public let remaining: Double?

        public init(current: Double, limit: Double?, remaining: Double?) {
            self.current = current
            self.limit = limit
            self.remaining = remaining
        }
    }

    /// Creates a usage result for an ordinary feature-use command.
    ///
    /// Ordinary usage responses do not carry an atomic post-use access
    /// snapshot, so `authoritativeAccess` is initialized to `nil`.
    public init(
        success: Bool,
        featureId: String,
        amountUsed: Double,
        message: String?,
        usage: UsageInfo?
    ) {
        self.init(
            success: success,
            featureId: featureId,
            amountUsed: amountUsed,
            message: message,
            usage: usage,
            authoritativeAccess: nil
        )
    }

    /// Creates a usage result with an authoritative post-use access snapshot.
    ///
    /// `success` reports whether the usage command committed. It is independent
    /// of `authoritativeAccess.allowed`, which reports whether another use is
    /// allowed after this command. Consuming the final finite unit therefore
    /// produces `success == true`, `authoritativeAccess.allowed == false`, and
    /// an authoritative zero balance.
    ///
    /// - Parameters:
    ///   - success: Whether the usage command committed successfully.
    ///   - featureId: The requested feature's external identifier.
    ///   - amountUsed: The amount submitted to the usage command.
    ///   - message: An optional server-provided result message.
    ///   - usage: Ordinary usage counters, when returned by the server.
    ///   - authoritativeAccess: The authoritative post-use access snapshot for
    ///     the requested feature, potentially backed by a credit system.
    public init(
        success: Bool,
        featureId: String,
        amountUsed: Double,
        message: String?,
        usage: UsageInfo?,
        authoritativeAccess: FeatureAccess?
    ) {
        self.success = success
        self.featureId = featureId
        self.amountUsed = amountUsed
        self.message = message
        self.usage = usage
        self.authoritativeAccess = authoritativeAccess
    }
}
