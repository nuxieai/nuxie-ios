import Foundation

enum ActivityCuration {
  static let curatedNames: Set<String> = [
    SystemEventNames.appBackgrounded,
    SystemEventNames.appInstalled,
    SystemEventNames.appOpened,
    SystemEventNames.appUpdated,
    JourneyEvents.experienceArtifactLoadFailed,
    JourneyEvents.experienceDismissed,
    JourneyEvents.experienceErrored,
    JourneyEvents.experienceShown,
    JourneyEvents.experimentExposure,
    SystemEventNames.featureUsed,
    JourneyEvents.journeyStarted,
    JourneyEvents.journeyCompleted,
    JourneyEvents.journeyMilestone,
    SystemEventNames.notificationsDenied,
    SystemEventNames.notificationsEnabled,
    SystemEventNames.permissionDenied,
    SystemEventNames.permissionGranted,
    SystemEventNames.productsUnavailable,
    SystemEventNames.purchaseCancelled,
    SystemEventNames.purchaseCompleted,
    SystemEventNames.purchaseFailed,
    SystemEventNames.purchasePending,
    SystemEventNames.purchaseSynced,
    SystemEventNames.restoreCompleted,
    SystemEventNames.restoreFailed,
    SystemEventNames.restoreNoPurchases,
    SystemEventNames.screenDismissed,
    SystemEventNames.screenShown,
    SystemEventNames.trackingAuthorized,
    SystemEventNames.trackingDenied,
  ]

  static let hiddenNames: Set<String> = [
    JourneyEvents.appActionRequested,
    JourneyEvents.customerUpdated,
    JourneyEvents.experienceArtifactLoadSucceeded,
    SystemEventNames.identify,
  ]

  static var classifiedNames: Set<String> { curatedNames.union(hiddenNames) }

  /// A report can be captured on a later launch. Keep occurrence and durable
  /// receipt separate in the public activity envelope, as for server facts.
  static func timestamp(_ event: NuxieEvent) -> Date {
    let field: String
    switch event.forwardingName {
    case JourneyEvents.journeyStarted: field = "started_at"
    case JourneyEvents.journeyCompleted: field = "completed_at"
    default: return event.timestamp
    }
    guard let value = event.properties[field] as? String else { return event.timestamp }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value) ?? event.timestamp
  }

  static func activity(
    internalName: String,
    properties: [String: Any]
  ) -> NuxieActivity? {
    switch internalName {
    case JourneyEvents.experienceShown:
      return experienceRef(properties).map(NuxieActivity.experienceShown)
    case JourneyEvents.experienceDismissed:
      guard let ref = experienceRef(properties),
            let reason = dismissReason(properties["reason"] as? String)
      else { return missing(internalName) }
      return .experienceDismissed(ref, reason: reason)
    case JourneyEvents.experienceErrored:
      guard let ref = experienceRef(properties) else { return missing(internalName) }
      return .experienceErrored(ref, message: string(properties, "error_message") ?? "")
    case JourneyEvents.journeyStarted, JourneyEvents.journeyCompleted:
      guard let ref = experienceRef(properties, requireVersion: true), ref.journeyId != nil,
            let legId = nonemptyString(properties, "leg_id"),
            let number = properties["leg_generation"] as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID(),
            number.doubleValue >= 0, number.doubleValue <= 9_007_199_254_740_991,
            number.doubleValue.rounded() == number.doubleValue
      else { return missing(internalName) }
      if internalName == JourneyEvents.journeyStarted {
        return .journeyStarted(ref, legId: legId, generation: number.intValue)
      }
      guard let outcome = nonemptyString(properties, "outcome") else { return missing(internalName) }
      return .journeyCompleted(ref, legId: legId, generation: number.intValue, outcome: outcome)
    case JourneyEvents.journeyMilestone:
      guard let ref = experienceRef(properties),
            let milestoneId = string(properties, "milestone_id")
      else { return missing(internalName) }
      return .milestoneReached(ref, milestoneId: milestoneId)
    case SystemEventNames.purchaseCompleted:
      return purchaseInfo(properties).map(NuxieActivity.purchaseCompleted)
    case SystemEventNames.purchaseFailed:
      guard let info = purchaseInfo(properties, requiresProductIdentifiers: false),
            let message = string(properties, "error") ?? string(properties, "reason")
      else { return missing(internalName) }
      return .purchaseFailed(info, message: message)
    case SystemEventNames.purchaseCancelled:
      return purchaseInfo(properties).map(NuxieActivity.purchaseCancelled)
    case SystemEventNames.purchasePending:
      return purchaseInfo(properties).map(NuxieActivity.purchasePending)
    case SystemEventNames.restoreCompleted:
      return .restoreCompleted
    case SystemEventNames.restoreFailed:
      guard let message = string(properties, "error") else { return missing(internalName) }
      return .restoreFailed(message: message)
    case SystemEventNames.restoreNoPurchases:
      return .restoreNoPurchases
    case SystemEventNames.purchaseSynced:
      guard let transactionId = string(properties, "transaction_id"),
            let productId = string(properties, "product_id")
      else { return missing(internalName) }
      return .purchaseSynced(
        transactionId: transactionId,
        originalTransactionId: nonemptyString(properties, "original_transaction_id"),
        productId: productId,
        experience: experienceRef(properties)
      )
    case SystemEventNames.featureUsed:
      guard let featureId = string(properties, "feature_id")
              ?? string(properties, "feature_extId"),
            let amount = double(properties, "amount")
      else { return missing(internalName) }
      return .featureUsed(
        featureId: featureId,
        amount: amount,
        entityId: nonemptyString(properties, "entity_id")
      )
    case JourneyEvents.experimentExposure:
      guard let ref = experienceRef(properties),
            let experimentKey = string(properties, "experiment_key"),
            let variantKey = string(properties, "variant_key"),
            let isHoldout = bool(properties, "is_holdout")
      else { return missing(internalName) }
      return .experimentExposure(
        ref,
        experimentKey: experimentKey,
        variantKey: variantKey,
        isHoldout: isHoldout
      )
    case SystemEventNames.productsUnavailable:
      guard let ref = experienceRef(properties),
            let productIds = strings(properties, "product_ids")
      else { return missing(internalName) }
      return .productsUnavailable(ref, productIds: productIds)
    case SystemEventNames.screenShown:
      guard let ref = experienceRef(properties),
            let screenId = string(properties, "screen_id")
      else { return missing(internalName) }
      return .screenShown(ref, screenId: screenId)
    case SystemEventNames.screenDismissed:
      guard let ref = experienceRef(properties),
            let screenId = string(properties, "screen_id")
      else { return missing(internalName) }
      return .screenDismissed(ref, screenId: screenId)
    case JourneyEvents.experienceArtifactLoadFailed:
      guard let ref = experienceRef(properties) else { return missing(internalName) }
      return .experienceLoadFailed(
        ref,
        message: string(properties, "error_message") ?? ""
      )
    case SystemEventNames.notificationsEnabled:
      return .permissionResolved(experienceRef(properties), kind: .notifications, granted: true)
    case SystemEventNames.notificationsDenied:
      return .permissionResolved(experienceRef(properties), kind: .notifications, granted: false)
    case SystemEventNames.trackingAuthorized:
      return .permissionResolved(experienceRef(properties), kind: .tracking, granted: true)
    case SystemEventNames.trackingDenied:
      return .permissionResolved(experienceRef(properties), kind: .tracking, granted: false)
    case SystemEventNames.permissionGranted:
      return .permissionResolved(experienceRef(properties), kind: .other, granted: true)
    case SystemEventNames.permissionDenied:
      return .permissionResolved(experienceRef(properties), kind: .other, granted: false)
    case SystemEventNames.appInstalled:
      return .appInstalled
    case SystemEventNames.appUpdated:
      guard let toVersion = string(properties, "app_version") else { return missing(internalName) }
      return .appUpdated(
        fromVersion: nonemptyString(properties, "previous_version"),
        toVersion: toVersion
      )
    case SystemEventNames.appOpened:
      return .appOpened
    case SystemEventNames.appBackgrounded:
      return .appBackgrounded
    default:
      return nil
    }
  }

  private static func experienceRef(
    _ properties: [String: Any],
    requireVersion: Bool = false
  ) -> ExperienceRef? {
    guard let experienceId = string(properties, "experience_id") else { return nil }
    let experienceVersion = nonemptyString(properties, "experience_version")
      ?? nonemptyString(properties, "experience_version_id")
    guard !requireVersion || experienceVersion != nil else { return nil }
    return ExperienceRef(
      experienceId: experienceId,
      experienceVersion: experienceVersion,
      journeyId: nonemptyString(properties, "journey_id")
    )
  }

  private static func purchaseInfo(
    _ properties: [String: Any],
    requiresProductIdentifiers: Bool = true
  ) -> PurchaseInfo? {
    let productId = string(properties, "product_id")
    let storeProductId = string(properties, "store_product_id")
    if requiresProductIdentifiers && (productId == nil || storeProductId == nil) {
      return nil
    }
    let price = double(properties, "price").map { Decimal($0) }
    return PurchaseInfo(
      productId: productId,
      storeProductId: storeProductId,
      placementId: nonemptyString(properties, "placement_id"),
      experience: experienceRef(properties),
      price: price,
      displayPrice: nonemptyString(properties, "display_price"),
      transactionId: nonemptyString(properties, "transaction_id"),
      isTestStore: bool(properties, "test_store") ?? false
    )
  }

  private static func dismissReason(_ value: String?) -> DismissReason? {
    switch value {
    case "user", "user_dismissed": .user
    case "goal_met": .goalMet
    case "error": .error
    case "host", "host_dismissed": .host
    default: nil
    }
  }

  private static func string(_ properties: [String: Any], _ key: String) -> String? {
    properties[key] as? String
  }

  private static func nonemptyString(_ properties: [String: Any], _ key: String) -> String? {
    guard let value = string(properties, key), !value.isEmpty else { return nil }
    return value
  }

  private static func double(_ properties: [String: Any], _ key: String) -> Double? {
    if let value = properties[key] as? Double { return value }
    if let value = properties[key] as? Int { return Double(value) }
    if let value = properties[key] as? NSNumber { return value.doubleValue }
    return nil
  }

  private static func bool(_ properties: [String: Any], _ key: String) -> Bool? {
    if let value = properties[key] as? Bool { return value }
    if let value = properties[key] as? NSNumber { return value.boolValue }
    return nil
  }

  private static func strings(_ properties: [String: Any], _ key: String) -> [String]? {
    if let value = properties[key] as? [String] { return value }
    if let value = properties[key] as? [Any] {
      let strings = value.compactMap { $0 as? String }
      return strings.count == value.count ? strings : nil
    }
    return nil
  }

  private static func missing(_ internalName: String) -> NuxieActivity? {
    LogError("Suppressing malformed forwarded activity '\(internalName)'")
    return nil
  }
}
