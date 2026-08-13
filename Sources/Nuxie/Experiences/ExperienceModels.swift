import Foundation

// MARK: - Experience

/// Hydrated domain model. Delivery metadata comes from `RemoteExperience`;
/// execution content comes exclusively from the signed package journey.
public struct Experience: Codable, Sendable {
    /// Stable experience definition identifier.
    public let id: String
    /// Published version identifier used by journeys and version fetches.
    public let versionId: String
    /// Immutable package build identity authenticated by the native runtime.
    public let buildId: String
    /// Verified delivery content digest used by artifact telemetry.
    let artifactContentHash: String?
    /// Legacy `.nux` delivery pointer. Descriptor-backed releases return
    /// `nil` because their authenticated RIV and assets are acquired directly.
    public let artifact: RemoteExperienceArtifact?
    /// Base URL used to resolve content-addressed external assets.
    public let assetBaseURL: URL
    /// Customer-authored display name.
    public let name: String
    /// Re-enrollment policy supplied by the server.
    public let reentry: ExperienceReentry
    /// ISO-8601 publication timestamp.
    public let publishedAt: String
    /// Optional event enrollment trigger.
    public let trigger: ExperienceTrigger?
    /// Optional conversion goal.
    public let goal: GoalConfig?
    /// Optional early-exit policy.
    public let exitPolicy: ExitPolicy?
    /// Wire conversion-anchor token.
    public let conversionAnchor: String?
    /// Optional maximum journey duration.
    public let timeLimitSeconds: Int?
    /// Optional server-defined experience category.
    public let experienceType: String?
    /// Authenticated execution content from the package journey member.
    public let journey: JourneyDocument
    /// StoreKit products resolved only after package authentication.
    public var products: [ExperienceProduct]

    /// Package-authenticated screen and action document.
    public var screens: JourneyDocument { journey }
    /// Identifier retained by renderer-facing APIs for the published version.
    public var screensId: String { versionId }
    /// Legacy `.nux` download URL, or `nil` for a descriptor-backed release.
    public var url: String? { artifact?.url }

    /// Hydrates a domain experience from delivery metadata and authenticated
    /// package content.
    public init(
        remote: RemoteExperience,
        journey: JourneyDocument,
        assetBaseURL: URL,
        products: [ExperienceProduct] = []
    ) {
        id = remote.experienceId
        versionId = remote.versionId
        buildId = remote.buildId
        artifactContentHash = remote.artifact.sha256
        artifact = remote.artifact
        self.assetBaseURL = assetBaseURL
        name = remote.name
        reentry = remote.reentry
        publishedAt = remote.publishedAt
        trigger = remote.trigger
        goal = remote.goal
        exitPolicy = remote.exitPolicy
        conversionAnchor = remote.conversionAnchor
        timeLimitSeconds = remote.timeLimitSeconds
        experienceType = remote.experienceType
        self.journey = journey
        self.products = products
    }

    init(
        behavior: ExperienceBehaviorDefinition,
        journey: JourneyDocument,
        assetBaseURL: URL,
        products: [ExperienceProduct] = []
    ) {
        id = behavior.reference.experienceId
        versionId = behavior.reference.versionId
        buildId = behavior.buildId
        artifactContentHash = behavior.artifactContentHash
        artifact = nil
        self.assetBaseURL = assetBaseURL
        name = behavior.name
        reentry = behavior.reentry
        publishedAt = behavior.publishedAt
        trigger = behavior.trigger
        goal = behavior.goal
        exitPolicy = behavior.exitPolicy
        conversionAnchor = behavior.conversionAnchor
        timeLimitSeconds = behavior.timeLimitSeconds
        experienceType = behavior.experienceType
        self.journey = journey
        self.products = products
    }

    init(remote: RemoteExperience, assetBaseURL: URL) {
        self.init(remote: remote, journey: .empty, assetBaseURL: assetBaseURL)
    }

    init(
        id: String,
        versionId: String,
        buildId: String = "test-build",
        name: String,
        reentry: ExperienceReentry,
        publishedAt: String,
        trigger: ExperienceTrigger?,
        goal: GoalConfig?,
        exitPolicy: ExitPolicy?,
        conversionAnchor: String?,
        timeLimitSeconds: Int? = nil,
        experienceType: String?,
        journey: JourneyDocument = .empty,
        assetBaseURL: URL = URL(string: "https://assets.nuxie.ai/")!,
        products: [ExperienceProduct] = []
    ) {
        self.init(
            remote: RemoteExperience(
                experienceId: id,
                versionId: versionId,
                buildId: buildId,
                artifact: RemoteExperienceArtifact(
                    url: "file:///dev/null",
                    sha256: String(repeating: "0", count: 64),
                    sizeBytes: 0
                ),
                name: name,
                reentry: reentry,
                publishedAt: publishedAt,
                trigger: trigger,
                goal: goal,
                exitPolicy: exitPolicy,
                conversionAnchor: conversionAnchor,
                timeLimitSeconds: timeLimitSeconds,
                experienceType: experienceType
            ),
            journey: journey,
            assetBaseURL: assetBaseURL,
            products: products
        )
    }

    var legacyRemote: RemoteExperience? {
        guard let artifact else { return nil }
        return RemoteExperience(
            experienceId: id,
            versionId: versionId,
            buildId: buildId,
            artifact: artifact,
            name: name,
            reentry: reentry,
            publishedAt: publishedAt,
            trigger: trigger,
            goal: goal,
            exitPolicy: exitPolicy,
            conversionAnchor: conversionAnchor,
            timeLimitSeconds: timeLimitSeconds,
            experienceType: experienceType
        )
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
struct ExperienceCacheKey: Hashable, Sendable {
    public let id: String

    public init(id: String) {
        self.id = id
    }
}
