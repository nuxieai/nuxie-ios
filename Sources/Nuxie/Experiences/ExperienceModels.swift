import Foundation

// MARK: - Experience

/// Hydrated domain model projected from an authenticated release descriptor.
public struct Experience: Codable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case id, versionId, buildId, artifactContentHash, authenticatedReleaseID
        case behaviorPresentationStyle, behaviorPresentation
        case behaviorPresentationScreens, assetBaseURL, name, reentry, publishedAt
        case trigger, goal, exitPolicy, conversionAnchor, timeLimitSeconds
        case experienceType, journey, products
    }

    /// Stable experience definition identifier.
    public let id: String
    /// Published version identifier used by journeys and version fetches.
    public let versionId: String
    /// Immutable release build identity authenticated by the native runtime.
    public let buildId: String
    /// Verified delivery content digest used by artifact telemetry.
    let artifactContentHash: String?
    let authenticatedReleaseID: AuthenticatedExperienceReleaseID?
    let behaviorPresentation: ExperienceBehaviorPresentation?
    let behaviorPresentationScreens: [String: ExperienceBehaviorScreenGeometry]
    var behaviorPresentationStyle: ExperienceBehaviorPresentationStyle? {
        behaviorPresentation?.style
    }
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
        behaviorPresentation = behavior.presentation
        behaviorPresentationScreens = behavior.presentationScreens
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
        behaviorPresentation = .fullScreenDefault
        behaviorPresentationScreens = [:]
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
        behaviorPresentation = metadata.behaviorPresentation
        behaviorPresentationScreens = metadata.behaviorPresentationScreens
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

    func shellContract(screenId: String?) -> ExperienceShellContract? {
        guard let presentation = behaviorPresentation,
              let screenId = screenId
                ?? (behaviorPresentationScreens.count == 1
                    ? behaviorPresentationScreens.keys.first
                    : nil),
              let screen = behaviorPresentationScreens[screenId] else {
            return nil
        }
        return ExperienceShellContract(presentation: presentation, screen: screen)
    }

    /// Decodes a persisted experience while retaining compatibility with
    /// records written before descriptor-native shell metadata was added.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        versionId = try container.decode(String.self, forKey: .versionId)
        buildId = try container.decode(String.self, forKey: .buildId)
        artifactContentHash = try container.decodeIfPresent(
            String.self,
            forKey: .artifactContentHash
        )
        authenticatedReleaseID = try container.decodeIfPresent(
            AuthenticatedExperienceReleaseID.self,
            forKey: .authenticatedReleaseID
        )
        let legacyStyle = try container.decodeIfPresent(
            ExperienceBehaviorPresentationStyle.self,
            forKey: .behaviorPresentationStyle
        )
        behaviorPresentation = try container.decodeIfPresent(
            ExperienceBehaviorPresentation.self,
            forKey: .behaviorPresentation
        ) ?? legacyStyle.map { style in
            let fallback = ExperienceBehaviorPresentation.fullScreenDefault
            return ExperienceBehaviorPresentation(
                style: style,
                orientation: fallback.orientation,
                backgroundColor: fallback.backgroundColor,
                sheet: nil,
                drawer: nil
            )
        }
        behaviorPresentationScreens = try container.decodeIfPresent(
            [String: ExperienceBehaviorScreenGeometry].self,
            forKey: .behaviorPresentationScreens
        ) ?? [:]
        assetBaseURL = try container.decode(URL.self, forKey: .assetBaseURL)
        name = try container.decode(String.self, forKey: .name)
        reentry = try container.decode(ExperienceReentry.self, forKey: .reentry)
        publishedAt = try container.decode(String.self, forKey: .publishedAt)
        trigger = try container.decodeIfPresent(ExperienceTrigger.self, forKey: .trigger)
        goal = try container.decodeIfPresent(GoalConfig.self, forKey: .goal)
        exitPolicy = try container.decodeIfPresent(ExitPolicy.self, forKey: .exitPolicy)
        conversionAnchor = try container.decodeIfPresent(
            String.self,
            forKey: .conversionAnchor
        )
        timeLimitSeconds = try container.decodeIfPresent(
            Int.self,
            forKey: .timeLimitSeconds
        )
        experienceType = try container.decodeIfPresent(
            String.self,
            forKey: .experienceType
        )
        journey = try container.decode(JourneyDocument.self, forKey: .journey)
        products = try container.decodeIfPresent(
            [ExperienceProduct].self,
            forKey: .products
        ) ?? []
    }

    /// Encodes the authenticated experience projection for durable reuse.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(versionId, forKey: .versionId)
        try container.encode(buildId, forKey: .buildId)
        try container.encodeIfPresent(artifactContentHash, forKey: .artifactContentHash)
        try container.encodeIfPresent(authenticatedReleaseID, forKey: .authenticatedReleaseID)
        try container.encodeIfPresent(behaviorPresentationStyle, forKey: .behaviorPresentationStyle)
        try container.encodeIfPresent(behaviorPresentation, forKey: .behaviorPresentation)
        try container.encode(behaviorPresentationScreens, forKey: .behaviorPresentationScreens)
        try container.encode(assetBaseURL, forKey: .assetBaseURL)
        try container.encode(name, forKey: .name)
        try container.encode(reentry, forKey: .reentry)
        try container.encode(publishedAt, forKey: .publishedAt)
        try container.encodeIfPresent(trigger, forKey: .trigger)
        try container.encodeIfPresent(goal, forKey: .goal)
        try container.encodeIfPresent(exitPolicy, forKey: .exitPolicy)
        try container.encodeIfPresent(conversionAnchor, forKey: .conversionAnchor)
        try container.encodeIfPresent(timeLimitSeconds, forKey: .timeLimitSeconds)
        try container.encodeIfPresent(experienceType, forKey: .experienceType)
        try container.encode(journey, forKey: .journey)
        try container.encode(products, forKey: .products)
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
    case day
    case week
    case month
    case year
    case lifetime
}

// MARK: - Experience Product

/// Product with StoreKit data and experience metadata
public struct ExperienceProduct: Equatable, Codable, Sendable {
    /// Nuxie's stable catalog product identity.
    public let id: String
    /// The App Store product identifier resolved through StoreKit.
    public let storeProductId: String
    /// The exact signed placement shown to the customer.
    public let placementId: String
    /// The localized product name returned by StoreKit.
    public let name: String
    /// The localized product description returned by StoreKit.
    public let description: String
    /// The localized display price returned by StoreKit, such as `$9.99`.
    public let price: String
    /// The normalized renewal period, or `nil` for non-subscription products.
    public let period: ProductPeriod?
    /// The number of normalized period units in one renewal interval.
    public let periodCount: Int?
    /// The localized period label projected into the paywall view model.
    public let periodLabel: String
    /// The localized recurring renewal price.
    public let renewalPrice: String
    /// The localized recurring renewal period.
    public let renewalPeriod: String
    /// The App Store product category.
    public let productType: StoreProductType
    /// The live StoreKit product used for checkout. This value is not serialized.
    public private(set) var storeProduct: (any StoreProductProtocol)? = nil

    /// Whether live introductory terms are available. Base products are not
    /// eligible until introductory terms are resolved in the dedicated flow.
    public var hasTrial: Bool { false }
    /// The localized free-trial duration, empty for a base product.
    public var trialLabel: String { "" }
    /// The localized introductory-offer description, empty for a base product.
    public var introOfferLabel: String { "" }
    /// The localized recurring charge sentence, empty when the product does not renew.
    public var renewalLabel: String {
        guard !renewalPrice.isEmpty else { return "" }
        return renewalPeriod.isEmpty ? renewalPrice : "\(renewalPrice)/\(renewalPeriod)"
    }

    /// Creates the live product projected into an Experience.
    ///
    /// - Parameters:
    ///   - id: Nuxie's stable catalog product identity.
    ///   - storeProductId: The App Store product identifier. Defaults to `id`.
    ///   - placementId: The exact signed placement shown to the customer.
    ///   - name: The localized StoreKit product name.
    ///   - description: The localized StoreKit product description.
    ///   - price: The localized StoreKit display price.
    ///   - period: The normalized renewal period.
    ///   - periodCount: The number of normalized units in one renewal interval.
    ///   - periodLabel: The localized renewal period label.
    ///   - renewalPrice: The localized recurring renewal price.
    ///   - renewalPeriod: The localized recurring renewal period.
    ///   - productType: The App Store product category.
    ///   - storeProduct: The live StoreKit product used for checkout.
    public init(
        id: String,
        storeProductId: String? = nil,
        placementId: String,
        name: String,
        description: String = "",
        price: String,
        period: ProductPeriod?,
        periodCount: Int? = nil,
        periodLabel: String? = nil,
        renewalPrice: String? = nil,
        renewalPeriod: String? = nil,
        productType: StoreProductType = .nonConsumable,
        storeProduct: (any StoreProductProtocol)? = nil
    ) {
        self.id = id
        self.storeProductId = storeProductId ?? id
        self.placementId = placementId
        self.name = name
        self.description = description
        self.price = price
        self.period = period
        self.periodCount = periodCount
        self.periodLabel = periodLabel ?? period?.rawValue ?? "lifetime"
        self.renewalPrice = renewalPrice ?? ""
        self.renewalPeriod = renewalPeriod ?? ""
        self.productType = productType
        self.storeProduct = storeProduct
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
            && lhs.storeProductId == rhs.storeProductId
            && lhs.placementId == rhs.placementId
            && lhs.name == rhs.name
            && lhs.description == rhs.description
            && lhs.price == rhs.price
            && lhs.period == rhs.period
            && lhs.periodCount == rhs.periodCount
            && lhs.periodLabel == rhs.periodLabel
            && lhs.renewalPrice == rhs.renewalPrice
            && lhs.renewalPeriod == rhs.renewalPeriod
            && lhs.productType == rhs.productType
    }

    private enum CodingKeys: String, CodingKey {
        case id, storeProductId, placementId, name, description, price, period
        case periodCount, periodLabel, renewalPrice, renewalPeriod, productType
    }
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
