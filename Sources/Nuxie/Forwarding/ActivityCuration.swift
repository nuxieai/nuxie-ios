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
    JourneyEvents.experimentExposureError,
    SystemEventNames.featureUsed,
    JourneyEvents.journeyConverted,
    JourneyEvents.journeyEnrolled,
    JourneyEvents.journeyExited,
    JourneyEvents.journeyMilestone,
    JourneyEvents.journeySuperseded,
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
    JourneyEvents.eventSent,
    JourneyEvents.experienceArtifactLoadSucceeded,
    JourneyEvents.experimentExposureFallback,
    SystemEventNames.identify,
    JourneyEvents.journeyClaimed,
    JourneyEvents.journeyEffectCompleted,
    JourneyEvents.journeyEffectRequested,
    JourneyEvents.journeyHandoff,
    JourneyEvents.journeyParked,
    SystemEventNames.journeyStarted,
    JourneyEvents.journeyTransition,
    SystemEventNames.responseSet,
    SystemEventNames.responseUnset,
  ]

  static var classifiedNames: Set<String> { curatedNames.union(hiddenNames) }

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
    case JourneyEvents.journeyEnrolled:
      return experienceRef(properties).map(NuxieActivity.journeyStarted)
    case JourneyEvents.journeyMilestone:
      guard let ref = experienceRef(properties),
            let milestoneId = string(properties, "milestone_id")
      else { return missing(internalName) }
      return .milestoneReached(ref, milestoneId: milestoneId)
    case JourneyEvents.journeyConverted:
      guard let ref = experienceRef(properties, requireVersion: true),
            let journeyId = string(properties, "journey_id")
      else { return missing(internalName) }
      return .journeyConverted(ref, journeyId: journeyId)
    case JourneyEvents.journeyExited:
      guard let ref = experienceRef(properties),
            let rawReason = string(properties, "reason")
      else { return missing(internalName) }
      let reason: JourneyExitReason
      if rawReason == "cancelled", string(properties, "dismissed_by") == "user" {
        reason = .dismissed
      } else if let mapped = journeyExitReason(rawReason) {
        reason = mapped
      } else {
        return missing(internalName)
      }
      return .journeyEnded(ref, exitReason: reason)
    case JourneyEvents.journeySuperseded:
      guard let ref = experienceRef(properties) else { return missing(internalName) }
      return .journeyEnded(ref, exitReason: .superseded)
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
    case JourneyEvents.experimentExposureError:
      guard let ref = experienceRef(properties),
            let experimentKey = string(properties, "experiment_key")
      else { return missing(internalName) }
      return .experimentError(
        ref,
        experimentKey: experimentKey,
        message: string(properties, "reason") ?? ""
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

  private static func journeyExitReason(_ value: String) -> JourneyExitReason? {
    switch value {
    case "completed": .completed
    case "dismissed": .dismissed
    case "goal_met", "converted_exit": .goalMet
    case "trigger_unmatched", "stopped_matching": .triggerUnmatched
    case "expired", "time_limit": .expired
    case "cancelled": .cancelled
    case "error": .error
    case "superseded": .superseded
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
