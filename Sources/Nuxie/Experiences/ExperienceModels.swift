import Foundation

// MARK: - Experience

/// Hydrated domain model projected from an authenticated release descriptor.
public struct Experience: Codable, Sendable {
    /// Stable experience definition identifier.
    public let id: String
    /// Published version identifier used by journeys and version fetches.
    public let versionId: String
    /// Immutable release build identity authenticated by the native runtime.
    public let buildId: String
    /// Verified delivery content digest used by artifact telemetry.
    let artifactContentHash: String?
    let authenticatedReleaseID: AuthenticatedExperienceReleaseID?
    let behaviorPresentationStyle: ExperienceBehaviorPresentationStyle?
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
    /// StoreKit products resolved only after descriptor authentication.
    public var products: [ExperienceProduct]

    /// Descriptor-authenticated screen and action document.
    public var screens: JourneyDocument { journey }
    /// Identifier retained by renderer-facing APIs for the published version.
    public var screensId: String { versionId }
    init(
        behavior: ExperienceBehaviorDefinition,
        journey: JourneyDocument,
        assetBaseURL: URL,
        authenticatedReleaseID: AuthenticatedExperienceReleaseID? = nil,
        products: [ExperienceProduct] = []
    ) {
        id = behavior.reference.experienceId
        versionId = behavior.reference.versionId
        buildId = behavior.buildId
        artifactContentHash = behavior.artifactContentHash
        self.authenticatedReleaseID = authenticatedReleaseID
        behaviorPresentationStyle = behavior.presentationStyle
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
        self.id = id
        self.versionId = versionId
        self.buildId = buildId
        artifactContentHash = String(repeating: "0", count: 64)
        authenticatedReleaseID = nil
        behaviorPresentationStyle = .fullScreen
        self.assetBaseURL = assetBaseURL
        self.name = name
        self.reentry = reentry
        self.publishedAt = publishedAt
        self.trigger = trigger
        self.goal = goal
        self.exitPolicy = exitPolicy
        self.conversionAnchor = conversionAnchor
        self.timeLimitSeconds = timeLimitSeconds
        self.experienceType = experienceType
        self.journey = journey
        self.products = products
    }

    /// Rehydrates authenticated metadata with a decoded journey document in tests and
    /// descriptor-native orchestration seams without recreating a wire model.
    init(
        metadata: Experience,
        journey: JourneyDocument,
        assetBaseURL: URL? = nil
    ) {
        id = metadata.id
        versionId = metadata.versionId
        buildId = metadata.buildId
        artifactContentHash = metadata.artifactContentHash
        authenticatedReleaseID = metadata.authenticatedReleaseID
        behaviorPresentationStyle = metadata.behaviorPresentationStyle
        self.assetBaseURL = assetBaseURL ?? metadata.assetBaseURL
        name = metadata.name
        reentry = metadata.reentry
        publishedAt = metadata.publishedAt
        trigger = metadata.trigger
        goal = metadata.goal
        exitPolicy = metadata.exitPolicy
        conversionAnchor = metadata.conversionAnchor
        timeLimitSeconds = metadata.timeLimitSeconds
        experienceType = metadata.experienceType
        self.journey = journey
        products = metadata.products
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
