import Foundation

// MARK: - Experience

/// The SDK's single experience model. Profile responses decode the authoring
/// settings and active published version together; no client-side wire join is
/// required. StoreKit products are a local enrichment and are never encoded.
public struct Experience: Codable, Sendable {
    /// Stable experience definition identifier.
    public let id: String
    /// Human-readable experience name.
    public let name: String
    /// Enrollment policy applied after a prior or live journey.
    public let reentry: ExperienceReentry
    /// Publication timestamp supplied by the profile service.
    public let publishedAt: String
    /// Optional enrollment trigger.
    public let trigger: ExperienceTrigger?
    /// Optional conversion goal.
    public let goal: GoalConfig?
    /// Optional policy for completing the journey.
    public let exitPolicy: ExitPolicy?
    /// Event that anchors the conversion window.
    public let conversionAnchor: String?
    /// Maximum journey duration, in seconds.
    public let timeLimitSeconds: Int?
    /// Server-defined experience category used for runtime defaults.
    public let experienceType: String?
    /// Active published artifact embedded in the profile response.
    public let version: RemoteFlow
    /// StoreKit-enriched products available to the experience.
    public var products: [ExperienceProduct]

    /// Runtime artifact for the published version.
    public var screens: RemoteFlow { version }
    /// Identifier of the published version artifact.
    public var screensId: String { version.id }
    /// Compatibility accessor for the published version identifier.
    public var flowId: String { version.id }
    /// Build manifest for the published version.
    public var manifest: BuildManifest { version.flowArtifact.manifest }
    /// Download URL for the published version.
    public var url: String { version.flowArtifact.url }

    /// Creates an experience from its settings and embedded published version.
    ///
    /// - Parameters:
    ///   - id: Stable experience definition identifier.
    ///   - name: Human-readable experience name.
    ///   - reentry: Enrollment policy after a prior or live journey.
    ///   - publishedAt: Publication timestamp supplied by the profile service.
    ///   - trigger: Optional enrollment trigger.
    ///   - goal: Optional conversion goal.
    ///   - exitPolicy: Optional journey completion policy.
    ///   - conversionAnchor: Event anchoring the conversion window.
    ///   - timeLimitSeconds: Maximum journey duration, in seconds.
    ///   - experienceType: Server-defined experience category.
    ///   - version: Embedded published artifact.
    ///   - products: Locally enriched StoreKit products.
    public init(
        id: String,
        name: String,
        reentry: ExperienceReentry,
        publishedAt: String,
        trigger: ExperienceTrigger? = nil,
        goal: GoalConfig? = nil,
        exitPolicy: ExitPolicy? = nil,
        conversionAnchor: String? = nil,
        timeLimitSeconds: Int? = nil,
        experienceType: String? = nil,
        version: RemoteFlow,
        products: [ExperienceProduct] = []
    ) {
        self.id = id
        self.name = name
        self.reentry = reentry
        self.publishedAt = publishedAt
        self.trigger = trigger
        self.goal = goal
        self.exitPolicy = exitPolicy
        self.conversionAnchor = conversionAnchor
        self.timeLimitSeconds = timeLimitSeconds
        self.experienceType = experienceType
        self.version = version
        self.products = products
    }

    /// Creates a presentation-only value from a published artifact.
    ///
    /// - Parameters:
    ///   - screens: Published artifact to present.
    ///   - products: Locally enriched StoreKit products.
    public init(screens: RemoteFlow, products: [ExperienceProduct] = []) {
        self.init(
            id: screens.id,
            name: screens.id,
            reentry: .everyTime,
            publishedAt: "",
            version: screens,
            products: products
        )
    }

    /// Test/support initializer for settings-first construction. Runtime
    /// profile decoding always supplies the full `version` object.
    init(
        id: String,
        name: String,
        flowId: String,
        flowNumber: Int,
        flowName: String?,
        reentry: ExperienceReentry,
        publishedAt: String,
        trigger: ExperienceTrigger?,
        goal: GoalConfig?,
        exitPolicy: ExitPolicy?,
        conversionAnchor: String?,
        timeLimitSeconds: Int? = nil,
        experienceType: String?
    ) {
        _ = flowNumber
        _ = flowName
        self.init(
            id: id,
            name: name,
            reentry: reentry,
            publishedAt: publishedAt,
            trigger: trigger,
            goal: goal,
            exitPolicy: exitPolicy,
            conversionAnchor: conversionAnchor,
            timeLimitSeconds: timeLimitSeconds,
            experienceType: experienceType,
            version: RemoteFlow.placeholder(id: flowId)
        )
    }

    /// Returns the same settings paired with an exact published artifact.
    ///
    /// - Parameter version: Active or pinned artifact to use.
    /// - Returns: A copy of this experience with the supplied version.
    public func replacingVersion(_ version: RemoteFlow) -> Experience {
        Experience(
            id: id,
            name: name,
            reentry: reentry,
            publishedAt: publishedAt,
            trigger: trigger,
            goal: goal,
            exitPolicy: exitPolicy,
            conversionAnchor: conversionAnchor,
            timeLimitSeconds: timeLimitSeconds,
            experienceType: experienceType,
            version: version,
            products: products
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case reentry
        case publishedAt
        case trigger
        case goal
        case exitPolicy
        case conversionAnchor
        case timeLimitSeconds
        case experienceType
        case version
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        reentry = try container.decode(ExperienceReentry.self, forKey: .reentry)
        publishedAt = try container.decode(String.self, forKey: .publishedAt)
        trigger = try container.decodeIfPresent(ExperienceTrigger.self, forKey: .trigger)
        goal = try container.decodeIfPresent(GoalConfig.self, forKey: .goal)
        exitPolicy = try container.decodeIfPresent(ExitPolicy.self, forKey: .exitPolicy)
        conversionAnchor = try container.decodeIfPresent(String.self, forKey: .conversionAnchor)
        timeLimitSeconds = try container.decodeIfPresent(Int.self, forKey: .timeLimitSeconds)
        experienceType = try container.decodeIfPresent(String.self, forKey: .experienceType)
        version = try container.decode(RemoteFlow.self, forKey: .version)
        products = []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(reentry, forKey: .reentry)
        try container.encode(publishedAt, forKey: .publishedAt)
        try container.encodeIfPresent(trigger, forKey: .trigger)
        try container.encodeIfPresent(goal, forKey: .goal)
        try container.encodeIfPresent(exitPolicy, forKey: .exitPolicy)
        try container.encodeIfPresent(conversionAnchor, forKey: .conversionAnchor)
        try container.encodeIfPresent(timeLimitSeconds, forKey: .timeLimitSeconds)
        try container.encodeIfPresent(experienceType, forKey: .experienceType)
        try container.encode(version, forKey: .version)
    }
}

// MARK: - Close Reason

public enum CloseReason: Equatable, Sendable {
    case userDismissed
    case goalMet
    case purchaseCompleted
    case timeout
    case error(Error)
    
    public static func == (lhs: CloseReason, rhs: CloseReason) -> Bool {
        switch (lhs, rhs) {
        case (.userDismissed, .userDismissed),
             (.goalMet, .goalMet),
             (.purchaseCompleted, .purchaseCompleted),
             (.timeout, .timeout):
            return true
        case let (.error(e1), .error(e2)):
            return (e1 as NSError) == (e2 as NSError)
        default:
            return false
        }
    }
}

// MARK: - Product Period

public enum ProductPeriod: String, Codable, Equatable, Sendable {
    case week
    case month
    case year
    case lifetime
}

// MARK: - Experience Product

/// Product with StoreKit data and experience metadata
public struct ExperienceProduct: Equatable, Codable, Sendable {
    public let id: String
    public let name: String
    public let price: String  // Formatted price string (e.g., "$9.99")
    public let period: ProductPeriod?
}

// MARK: - Experience Cache Key

/// Cache key for experiences (plain screens id — variant/segment dimensions
/// were never used)
public struct ExperienceCacheKey: Hashable, Sendable {
    public let id: String

    public init(id: String) {
        self.id = id
    }
}
