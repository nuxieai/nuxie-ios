import Foundation

/// A durably captured Nuxie activity suitable for forwarding to an analytics tool.
public struct NuxieActivityInfo: Sendable {
  /// Contract version of the typed activity and its flat wire encoding.
  public static let schemaVersion = 1

  /// Stable identity of the captured event.
  public let id: String
  /// Time the activity happened.
  public let timestamp: Date
  /// Time this device learned of the activity.
  public let receivedAt: Date
  /// Typed activity payload.
  public let activity: NuxieActivity
  /// Stable analytics-ready activity name.
  public var name: String { activity.wireName }
  /// Flat JSON-safe activity properties.
  public var properties: [String: NuxieActivityValue] { activity.wireProperties }

  init(id: String, timestamp: Date, receivedAt: Date, activity: NuxieActivity) {
    self.id = id
    self.timestamp = timestamp
    self.receivedAt = receivedAt
    self.activity = activity
  }
}

/// JSON-safe scalar used by the flat forwarding view.
public enum NuxieActivityValue: Sendable {
  /// A string scalar.
  case string(String)
  /// An integer scalar.
  case int(Int)
  /// A floating-point scalar.
  case double(Double)
  /// A Boolean scalar.
  case bool(Bool)
}

/// Curated activities emitted by the Nuxie engine.
public enum NuxieActivity: Sendable {
  /// An experience became visible.
  case experienceShown(ExperienceRef)
  /// An experience closed with a known reason.
  case experienceDismissed(ExperienceRef, reason: DismissReason)
  /// Experience execution failed.
  case experienceErrored(ExperienceRef, message: String)

  /// A journey enrolled and began.
  case journeyStarted(ExperienceRef)
  /// This device started one leg of a pinned journey.
  case journeyLegStarted(ExperienceRef, legId: String, generation: Int)
  /// This device queued a leg completion; the server may continue the chain.
  case journeyLegCompleted(ExperienceRef, legId: String, generation: Int, outcome: String)
  /// A journey milestone was reached.
  case milestoneReached(ExperienceRef, milestoneId: String)
  /// The server attributed a conversion to a journey.
  case journeyConverted(ExperienceRef, journeyId: String)
  /// A journey reached a terminal outcome.
  case journeyEnded(ExperienceRef, exitReason: JourneyExitReason)

  /// A presentation-scoped purchase completed.
  case purchaseCompleted(PurchaseInfo)
  /// A presentation-scoped purchase failed.
  case purchaseFailed(PurchaseInfo, message: String)
  /// A presentation-scoped purchase was cancelled.
  case purchaseCancelled(PurchaseInfo)
  /// A presentation-scoped purchase is pending external approval.
  case purchasePending(PurchaseInfo)
  /// Restore completed with at least one purchase.
  case restoreCompleted
  /// Restore failed.
  case restoreFailed(message: String)
  /// Restore completed without purchases.
  case restoreNoPurchases

  /// A receipt was accepted authoritatively.
  case purchaseSynced(
    transactionId: String,
    originalTransactionId: String?,
    productId: String,
    experience: ExperienceRef?
  )

  /// A feature-use command was accepted authoritatively.
  case featureUsed(featureId: String, amount: Double, entityId: String?)

  /// A real server-assigned experiment exposure occurred.
  case experimentExposure(
    ExperienceRef,
    experimentKey: String,
    variantKey: String,
    isHoldout: Bool
  )
  /// Experiment assignment failed.
  case experimentError(ExperienceRef, experimentKey: String, message: String)

  /// Required products were unavailable for an experience.
  case productsUnavailable(ExperienceRef, productIds: [String])
  /// An experience screen became active.
  case screenShown(ExperienceRef, screenId: String)
  /// An experience screen was dismissed.
  case screenDismissed(ExperienceRef, screenId: String)
  /// A published experience artifact failed to load.
  case experienceLoadFailed(ExperienceRef, message: String)

  /// An experience-scoped or app-scoped permission request resolved.
  case permissionResolved(ExperienceRef?, kind: PermissionKind, granted: Bool)

  /// The app was installed.
  case appInstalled
  /// The app version changed.
  case appUpdated(fromVersion: String?, toVersion: String)
  /// The app opened.
  case appOpened
  /// The app entered the background.
  case appBackgrounded
}

/// Why an experience presentation ended.
public enum DismissReason: String, Sendable {
  /// The user dismissed the experience.
  case user
  /// The experience goal was met.
  case goalMet
  /// Execution ended because of an error.
  case error
  /// The host app dismissed the experience.
  case host
}

/// Purchase details captured at the presentation boundary.
public struct PurchaseInfo: Sendable {
  /// Nuxie's catalog product identity, when product resolution succeeded.
  public let productId: String?
  /// The App Store product identifier, when product resolution succeeded.
  public let storeProductId: String?
  /// The signed placement shown to the customer.
  public let placementId: String?
  /// The experience that initiated the purchase, when present.
  public let experience: ExperienceRef?
  /// The localized numeric price, when available.
  public let price: Decimal?
  /// The localized display price, when available.
  public let displayPrice: String?
  /// The completed transaction identifier, when available.
  public let transactionId: String?
  /// Whether the purchase used Nuxie's development Test Store.
  public let isTestStore: Bool

  init(
    productId: String?,
    storeProductId: String?,
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

/// Permission family resolved by an experience request.
public enum PermissionKind: String, Sendable {
  /// Notification authorization.
  case notifications
  /// App tracking transparency authorization.
  case tracking
  /// Another authored permission kind.
  case other
}

extension NuxieActivityInfo: Equatable {}
extension NuxieActivityValue: Equatable {}
extension NuxieActivity: Equatable {}
extension PurchaseInfo: Equatable {}

extension NuxieActivity {
  var wireName: String {
    switch self {
    case .experienceShown: "experience_shown"
    case .experienceDismissed: "experience_dismissed"
    case .experienceErrored: "experience_errored"
    case .journeyStarted: "journey_started"
    case .journeyLegStarted: "journey_leg_started"
    case .journeyLegCompleted: "journey_leg_completed"
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
    var properties: [String: NuxieActivityValue] = [:]
    switch self {
    case .experienceShown(let ref), .journeyStarted(let ref):
      properties.add(ref)
    case .journeyLegStarted(let ref, let legId, let generation):
      properties.add(ref)
      properties["leg_id"] = .string(legId)
      properties["leg_generation"] = .int(generation)
    case .journeyLegCompleted(let ref, let legId, let generation, let outcome):
      properties.add(ref)
      properties["leg_id"] = .string(legId)
      properties["leg_generation"] = .int(generation)
      properties["outcome"] = .string(outcome)
    case .experienceDismissed(let ref, let reason):
      properties.add(ref)
      properties["reason"] = .string(reason.rawValue)
    case .experienceErrored(let ref, let message),
         .experienceLoadFailed(let ref, let message):
      properties.add(ref)
      properties["message"] = .string(message)
    case .milestoneReached(let ref, let milestoneId):
      properties.add(ref)
      properties["milestone_id"] = .string(milestoneId)
    case .journeyConverted(let ref, let journeyId):
      properties.add(ref)
      properties["journey_id"] = .string(journeyId)
    case .journeyEnded(let ref, let exitReason):
      properties.add(ref)
      properties["exit_reason"] = .string(exitReason.rawValue)
    case .purchaseCompleted(let info),
         .purchaseCancelled(let info),
         .purchasePending(let info):
      properties.add(info)
    case .purchaseFailed(let info, let message):
      properties.add(info)
      properties["message"] = .string(message)
    case .restoreCompleted, .restoreNoPurchases, .appInstalled, .appOpened,
         .appBackgrounded:
      break
    case .restoreFailed(let message):
      properties["message"] = .string(message)
    case .purchaseSynced(
      let transactionId,
      let originalTransactionId,
      let productId,
      let experience
    ):
      properties["transaction_id"] = .string(transactionId)
      properties.add("original_transaction_id", originalTransactionId)
      properties["product_id"] = .string(productId)
      properties.addPurchaseSyncExperience(experience)
    case .featureUsed(let featureId, let amount, let entityId):
      properties["feature_id"] = .string(featureId)
      properties["amount"] = .double(amount)
      properties.add("entity_id", entityId)
    case .experimentExposure(
      let ref,
      let experimentKey,
      let variantKey,
      let isHoldout
    ):
      properties.add(ref)
      properties["experiment_key"] = .string(experimentKey)
      properties["variant_key"] = .string(variantKey)
      properties["is_holdout"] = .bool(isHoldout)
    case .experimentError(let ref, let experimentKey, let message):
      properties.add(ref)
      properties["experiment_key"] = .string(experimentKey)
      properties["message"] = .string(message)
    case .productsUnavailable(let ref, let productIds):
      properties.add(ref)
      properties["product_ids"] = .string(productIds.joined(separator: ","))
    case .screenShown(let ref, let screenId),
         .screenDismissed(let ref, let screenId):
      properties.add(ref)
      properties["screen_id"] = .string(screenId)
    case .permissionResolved(let ref, let kind, let granted):
      if let ref { properties.add(ref) }
      properties["kind"] = .string(kind.rawValue)
      properties["granted"] = .bool(granted)
    case .appUpdated(let fromVersion, let toVersion):
      properties.add("from_version", fromVersion)
      properties["to_version"] = .string(toVersion)
    }
    return properties
  }
}

private extension Dictionary where Key == String, Value == NuxieActivityValue {
  mutating func add(_ ref: ExperienceRef) {
    self["experience_id"] = .string(ref.experienceId)
    add("experience_version", ref.experienceVersion)
    add("journey_id", ref.journeyId)
  }

  mutating func addPurchaseSyncExperience(_ ref: ExperienceRef?) {
    guard let ref else { return }
    self["experience_id"] = .string(ref.experienceId)
    add("journey_id", ref.journeyId)
  }

  mutating func add(_ info: PurchaseInfo) {
    add("product_id", info.productId)
    add("store_product_id", info.storeProductId)
    add("placement_id", info.placementId)
    if let experience = info.experience {
      self["experience_id"] = .string(experience.experienceId)
    }
    if let price = info.price {
      self["price"] = .double(NSDecimalNumber(decimal: price).doubleValue)
    }
    add("display_price", info.displayPrice)
    add("transaction_id", info.transactionId)
    self["test_store"] = .bool(info.isTestStore)
  }

  mutating func add(_ key: String, _ value: String?) {
    guard let value else { return }
    self[key] = .string(value)
  }
}
