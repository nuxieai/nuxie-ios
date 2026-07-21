import Foundation

// MARK: - Experience

/// The **Experience** is the SDK's single domain currency: the **screens**
/// (riv bundle wire model) enriched with StoreKit **products**, plus the
/// **journey definition** when one exists. A **Journey** is a runtime run of
/// an experience for a user.
///
/// The wire layer stays split (`Campaign` + `RemoteFlow`, joined by flowId)
/// and is composed here — `journey` is nil only for bare server-directed
/// presentations (a gate plan's showFlow that references screens without a
/// campaign).
public struct Experience {
    /// Journey definition: trigger, reentry policy, goal/exit config.
    /// Nil for bare presentations with no campaign behind them.
    public let journey: Campaign?

    // IMPORTANT: RemoteFlow is immutable server data - never modify
    /// Screens bundle (riv artifact wire model).
    public let screens: RemoteFlow

    // Client-side enrichments
    public var products: [ExperienceProduct]  // Products fetched from StoreKit

    /// Stable experience id (the campaign id when a journey exists,
    /// otherwise the screens id).
    public var id: String { journey?.id ?? screens.id }
    public var name: String { journey?.name ?? screens.id }

    /// Screens-bundle id (the wire `flows[].id`).
    public var screensId: String { screens.id }

    // Convenience accessors proxy to the screens bundle
    public var manifest: BuildManifest { screens.flowArtifact.manifest }
    public var url: String { screens.flowArtifact.url }

    public init(
        screens: RemoteFlow,
        products: [ExperienceProduct] = [],
        journey: Campaign? = nil
    ) {
        self.screens = screens
        self.products = products
        self.journey = journey
    }
}

// MARK: - Wire-compat adapter

extension ProfileResponse {
    /// Compose the legacy `campaigns[]` + `flows[]` wire shape into
    /// `[Experience]`. This join exists in exactly one place — here. Only
    /// campaigns whose screens arrived compose; campaigns stay directly
    /// accessible for triggering (which needs no screens).
    public var experiences: [Experience] {
        let flowsById = Dictionary(uniqueKeysWithValues: flows.map { ($0.id, $0) })
        return campaigns.compactMap { campaign in
            guard let screens = flowsById[campaign.flowId] else { return nil }
            return Experience(screens: screens, journey: campaign)
        }
    }
}

// MARK: - Close Reason

public enum CloseReason: Equatable {
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

public enum ProductPeriod: String, Codable, Equatable {
    case week
    case month
    case year
    case lifetime
}

// MARK: - Experience Product

/// Product with StoreKit data and experience metadata
public struct ExperienceProduct: Equatable, Codable {
    public let id: String
    public let name: String
    public let price: String  // Formatted price string (e.g., "$9.99")
    public let period: ProductPeriod?
}

// MARK: - Experience Cache Key

/// Cache key for experiences (plain screens id — variant/segment dimensions
/// were never used)
public struct ExperienceCacheKey: Hashable {
    public let id: String

    public init(id: String) {
        self.id = id
    }
}
