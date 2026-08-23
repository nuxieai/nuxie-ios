import Foundation

/// A captured SDK activity curated for forwarding to a host analytics tool.
public struct NuxieActivityInfo: Sendable, Equatable {
    /// Contract version of the activity cases and their wire encoding.
    public static let schemaVersion = 1

    /// Stable identity of the captured event.
    public let id: String
    /// When the activity happened.
    public let timestamp: Date
    /// When the device learned of the activity.
    public let receivedAt: Date
    /// The typed activity.
    public let activity: NuxieActivity

    /// Stable analytics-ready event name. It is never dollar-prefixed.
    public var name: String { activity.wireName }
    /// Flat, JSON-safe analytics properties.
    public var properties: [String: NuxieActivityValue] { activity.wireProperties }

    /// Creates a forwarded activity envelope.
    public init(id: String, timestamp: Date, receivedAt: Date, activity: NuxieActivity) {
        self.id = id
        self.timestamp = timestamp
        self.receivedAt = receivedAt
        self.activity = activity
    }
}

/// A curated, typed SDK activity suitable for exhaustive switching.
public enum NuxieActivity: Sendable, Equatable {
    // MARK: Experiences

    /// An experience became visible.
    case experienceShown(ExperienceRef)
    /// An experience closed for the supplied reason.
    case experienceDismissed(ExperienceRef, reason: DismissReason)
    /// An experience reached its presentation timeout.
    case experienceTimedOut(ExperienceRef)
    /// An experience failed while it was being presented.
    case experienceErrored(ExperienceRef, message: String)

    // MARK: Journeys

    /// A customer entered a journey.
    case journeyStarted(ExperienceRef)
    /// A journey reached a designer-authored milestone.
    case milestoneReached(ExperienceRef, milestoneId: String)
    /// The server confirmed the journey's conversion goal.
    case journeyConverted(ExperienceRef)
    /// A journey reached a terminal state.
    case journeyEnded(ExperienceRef, exitReason: JourneyExitReason)

    // MARK: Commerce

    /// A purchase completed successfully.
    case purchaseCompleted(PurchaseInfo)
    /// A purchase failed.
    case purchaseFailed(PurchaseInfo, message: String)
    /// A customer cancelled a purchase.
    case purchaseCancelled(PurchaseInfo)
    /// A purchase is awaiting external approval or completion.
    case purchasePending(PurchaseInfo)
    /// Restore completed and recovered at least one purchase.
    case restoreCompleted
    /// Restore failed.
    case restoreFailed(message: String)
    /// Restore completed without finding a purchase.
    case restoreNoPurchases
    /// A StoreKit receipt was accepted by Nuxie.
    case purchaseSynced(
        transactionId: String,
        originalTransactionId: String?,
        productId: String
    )

    // MARK: Features

    /// A feature unit was accepted for consumption.
    case featureUsed(featureId: String, amount: Double, entityId: String?)

    // MARK: Experiments

    /// An experiment variant or fallback was exposed.
    case experimentExposure(
        ExperienceRef,
        experimentKey: String,
        variantKey: String,
        isHoldout: Bool,
        isFallback: Bool
    )
    /// Experiment assignment failed and no exposure was recorded.
    case experimentError(ExperienceRef, experimentKey: String, message: String)
    /// Required store products could not be loaded.
    case productsUnavailable(ExperienceRef, productIds: [String])
    /// An experience screen became visible.
    case screenShown(ExperienceRef, screenId: String)
    /// An experience screen was dismissed.
    case screenDismissed(ExperienceRef, screenId: String)
    /// An experience artifact could not be loaded.
    case experienceLoadFailed(ExperienceRef, message: String)

    // MARK: Permissions

    /// A permission request resolved with its final authorization state.
    case permissionResolved(ExperienceRef?, kind: PermissionKind, granted: Bool)

    // MARK: Application lifecycle

    /// The SDK observed the application's first installation launch.
    case appInstalled
    /// The SDK observed the first launch after an application update.
    case appUpdated(fromVersion: String?, toVersion: String)
    /// The application entered an active session.
    case appOpened
    /// The application moved to the background.
    case appBackgrounded
}

/// The reason an experience presentation ended.
public enum DismissReason: String, Sendable {
    /// The customer dismissed the experience.
    case user
    /// The experience's goal was met.
    case goalMet = "goal_met"
    /// A purchase caused dismissal.
    case purchase
    /// The experience timed out.
    case timeout
    /// An error caused dismissal.
    case error
    /// The host application dismissed the experience.
    case host
}

/// Analytics-safe context for a purchase outcome.
public struct PurchaseInfo: Sendable, Equatable {
    /// Nuxie's catalog product identity.
    public let productId: String
    /// App Store product identifier.
    public let storeProductId: String
    /// Signed placement the customer saw, when known.
    public let placementId: String?
    /// Experience that presented the product, when known.
    public let experience: ExperienceRef?
    /// Store price, when known.
    public let price: Decimal?
    /// Store-formatted price, when known.
    public let displayPrice: String?
    /// Transaction identity, present for completed purchases when known.
    public let transactionId: String?
    /// Whether the outcome came from a test store.
    public let isTestStore: Bool

    /// Creates purchase context for a forwarded activity.
    public init(
        productId: String,
        storeProductId: String,
        placementId: String?,
        experience: ExperienceRef?,
        price: Decimal?,
        displayPrice: String?,
        transactionId: String?,
        isTestStore: Bool
    ) {
        self.productId = productId
        self.storeProductId = storeProductId
        self.placementId = placementId
        self.experience = experience
        self.price = price
        self.displayPrice = displayPrice
        self.transactionId = transactionId
        self.isTestStore = isTestStore
    }
}

/// Kind of permission resolved by an experience request.
public enum PermissionKind: String, Sendable {
    /// Notification authorization.
    case notifications
    /// App tracking transparency authorization.
    case tracking
    /// Any other experience-requested permission.
    case other
}

extension NuxieActivity {
    var wireName: String {
        switch self {
        case .experienceShown: "experience_shown"
        case .experienceDismissed: "experience_dismissed"
        case .experienceTimedOut: "experience_timed_out"
        case .experienceErrored: "experience_errored"
        case .journeyStarted: "journey_started"
        case .milestoneReached: "milestone_reached"
        case .journeyConverted: "journey_converted"
        case .journeyEnded: "journey_ended"
        case .purchaseCompleted: "purchase_completed"
        case .purchaseFailed: "purchase_failed"
        case .purchaseCancelled: "purchase_cancelled"
        case .purchasePending: "purchase_pending"
        case .restoreCompleted: "restore_completed"
        case .restoreFailed: "restore_failed"
        case .restoreNoPurchases: "restore_no_purchases"
        case .purchaseSynced: "purchase_synced"
        case .featureUsed: "feature_used"
        case .experimentExposure: "experiment_exposure"
        case .experimentError: "experiment_error"
        case .productsUnavailable: "products_unavailable"
        case .screenShown: "screen_shown"
        case .screenDismissed: "screen_dismissed"
        case .experienceLoadFailed: "experience_load_failed"
        case .permissionResolved: "permission_resolved"
        case .appInstalled: "app_installed"
        case .appUpdated: "app_updated"
        case .appOpened: "app_opened"
        case .appBackgrounded: "app_backgrounded"
        }
    }

    var wireProperties: [String: NuxieActivityValue] {
        switch self {
        case .experienceShown(let experience),
             .experienceTimedOut(let experience),
             .journeyStarted(let experience),
             .journeyConverted(let experience):
            return experience.forwardingProperties
        case .experienceDismissed(let experience, let reason):
            return experience.forwardingProperties.merging(["reason": .string(reason.rawValue)])
        case .experienceErrored(let experience, let message),
             .experienceLoadFailed(let experience, let message):
            return experience.forwardingProperties.merging(["message": .string(message)])
        case .milestoneReached(let experience, let milestoneId):
            return experience.forwardingProperties.merging(["milestone_id": .string(milestoneId)])
        case .journeyEnded(let experience, let exitReason):
            return experience.forwardingProperties.merging([
                "exit_reason": .string(exitReason.rawValue)
            ])
        case .purchaseCompleted(let info),
             .purchaseCancelled(let info),
             .purchasePending(let info):
            return info.forwardingProperties
        case .purchaseFailed(let info, let message):
            return info.forwardingProperties.merging(["message": .string(message)])
        case .restoreCompleted, .restoreNoPurchases, .appInstalled, .appOpened,
             .appBackgrounded:
            return [:]
        case .restoreFailed(let message):
            return ["message": .string(message)]
        case .purchaseSynced(let transactionId, let originalTransactionId, let productId):
            return optionalProperties([
                "transaction_id": .string(transactionId),
                "original_transaction_id": originalTransactionId.map(NuxieActivityValue.string),
                "product_id": .string(productId)
            ])
        case .featureUsed(let featureId, let amount, let entityId):
            return optionalProperties([
                "feature_id": .string(featureId),
                "amount": .double(amount),
                "entity_id": entityId.map(NuxieActivityValue.string)
            ])
        case .experimentExposure(
            let experience,
            let experimentKey,
            let variantKey,
            let isHoldout,
            let isFallback
        ):
            return experience.forwardingProperties.merging([
                "experiment_key": .string(experimentKey),
                "variant_key": .string(variantKey),
                "is_holdout": .bool(isHoldout),
                "is_fallback": .bool(isFallback)
            ])
        case .experimentError(let experience, let experimentKey, let message):
            return experience.forwardingProperties.merging([
                "experiment_key": .string(experimentKey),
                "message": .string(message)
            ])
        case .productsUnavailable(let experience, let productIds):
            return experience.forwardingProperties.merging([
                "product_ids": .string(productIds.forwardingJSONString)
            ])
        case .screenShown(let experience, let screenId),
             .screenDismissed(let experience, let screenId):
            return experience.forwardingProperties.merging(["screen_id": .string(screenId)])
        case .permissionResolved(let experience, let kind, let granted):
            return (experience?.forwardingProperties ?? [:]).merging([
                "kind": .string(kind.rawValue),
                "granted": .bool(granted)
            ])
        case .appUpdated(let fromVersion, let toVersion):
            return optionalProperties([
                "from_version": fromVersion.map(NuxieActivityValue.string),
                "to_version": .string(toVersion)
            ])
        }
    }
}

private extension ExperienceRef {
    var forwardingProperties: [String: NuxieActivityValue] {
        optionalProperties([
            "experience_id": .string(experienceId),
            "experience_version": experienceVersion.map(NuxieActivityValue.string),
            "journey_id": journeyId.map(NuxieActivityValue.string)
        ])
    }
}

private extension PurchaseInfo {
    var forwardingProperties: [String: NuxieActivityValue] {
        optionalProperties([
            "product_id": .string(productId),
            "store_product_id": .string(storeProductId),
            "placement_id": placementId.map(NuxieActivityValue.string),
            "experience_id": experience.map { .string($0.experienceId) },
            "price": price.map { .double(NSDecimalNumber(decimal: $0).doubleValue) },
            "display_price": displayPrice.map(NuxieActivityValue.string),
            "transaction_id": transactionId.map(NuxieActivityValue.string),
            "test_store": .bool(isTestStore)
        ])
    }
}

private func optionalProperties(
    _ values: [String: NuxieActivityValue?]
) -> [String: NuxieActivityValue] {
    values.reduce(into: [:]) { properties, entry in
        if let value = entry.value { properties[entry.key] = value }
    }
}

private extension Dictionary where Key == String, Value == NuxieActivityValue {
    func merging(_ additions: [String: NuxieActivityValue]) -> Self {
        merging(additions) { _, replacement in replacement }
    }
}

private extension Array where Element == String {
    var forwardingJSONString: String {
        guard let data = try? JSONSerialization.data(withJSONObject: self) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }
}
