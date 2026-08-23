import Foundation

/// The complete forwarding policy for the SDK's internal event catalog.
/// New `$` event constants must be classified here as mapped or hidden.
enum ActivityCuration {
    enum Classification: Equatable, Sendable {
        case mapped
        case hidden
    }

    static let mappedNames: Set<String> = [
        SystemEventNames.appInstalled,
        SystemEventNames.appUpdated,
        SystemEventNames.appOpened,
        SystemEventNames.appBackgrounded,
        SystemEventNames.productsUnavailable,
        SystemEventNames.featureUsed,
        SystemEventNames.screenShown,
        SystemEventNames.screenDismissed,
        SystemEventNames.purchaseCompleted,
        SystemEventNames.purchaseFailed,
        SystemEventNames.purchaseCancelled,
        SystemEventNames.purchasePending,
        SystemEventNames.purchaseSynced,
        SystemEventNames.restoreCompleted,
        SystemEventNames.restoreFailed,
        SystemEventNames.restoreNoPurchases,
        SystemEventNames.notificationsEnabled,
        SystemEventNames.notificationsDenied,
        SystemEventNames.permissionGranted,
        SystemEventNames.permissionDenied,
        SystemEventNames.trackingAuthorized,
        SystemEventNames.trackingDenied,
        JourneyEvents.journeyEnrolled,
        JourneyEvents.journeyMilestone,
        JourneyEvents.journeyConverted,
        JourneyEvents.journeyExited,
        JourneyEvents.experienceShown,
        JourneyEvents.experienceDismissed,
        JourneyEvents.experiencePurchased,
        JourneyEvents.experienceTimedOut,
        JourneyEvents.experienceErrored,
        JourneyEvents.experienceArtifactLoadFailed,
        JourneyEvents.experimentExposure,
        JourneyEvents.experimentExposureFallback,
        JourneyEvents.experimentExposureError,
    ]

    static let hiddenNames: Set<String> = [
        SystemEventNames.identify,
        SystemEventNames.journeyStarted,
        SystemEventNames.responseSet,
        SystemEventNames.responseUnset,
        JourneyEvents.journeyTransition,
        JourneyEvents.journeyEffectRequested,
        JourneyEvents.journeyEffectCompleted,
        JourneyEvents.journeyClaimed,
        JourneyEvents.journeyHandoff,
        JourneyEvents.journeyParked,
        JourneyEvents.journeySuperseded,
        JourneyEvents.experienceArtifactLoadSucceeded,
        JourneyEvents.customerUpdated,
        JourneyEvents.eventSent,
        JourneyEvents.appActionRequested,
    ]

    static func classification(for name: String) -> Classification {
        if mappedNames.contains(name) { return .mapped }
        return .hidden
    }

    static func activity(
        canonicalName name: String,
        properties: [String: Any],
        journeyExperience: ExperienceRef? = nil
    ) -> NuxieActivity? {
        guard classification(for: name) == .mapped else { return nil }

        switch name {
        case JourneyEvents.experienceShown:
            return .experienceShown(experienceRef(properties))
        case JourneyEvents.experienceDismissed:
            return .experienceDismissed(
                experienceRef(properties),
                reason: dismissReason(properties) ?? .user
            )
        case JourneyEvents.experiencePurchased:
            return .experienceDismissed(experienceRef(properties), reason: .purchase)
        case JourneyEvents.experienceTimedOut:
            return .experienceTimedOut(experienceRef(properties))
        case JourneyEvents.experienceErrored:
            return .experienceErrored(
                experienceRef(properties),
                message: message(properties)
            )
        case JourneyEvents.journeyEnrolled:
            return .journeyStarted(experienceRef(properties))
        case JourneyEvents.journeyMilestone:
            guard let experience = summaryExperienceRef(
                properties,
                cached: journeyExperience,
                eventName: name
            ) else { return nil }
            return .milestoneReached(
                experience,
                milestoneId: string(properties, "milestone_id") ?? ""
            )
        case JourneyEvents.journeyConverted:
            guard let experience = summaryExperienceRef(
                properties,
                cached: journeyExperience,
                eventName: name
            ) else { return nil }
            return .journeyConverted(experience)
        case JourneyEvents.journeyExited:
            guard let experience = summaryExperienceRef(
                properties,
                cached: journeyExperience,
                eventName: name
            ) else { return nil }
            return .journeyEnded(
                experience,
                exitReason: exitReason(properties)
            )
        case SystemEventNames.purchaseCompleted:
            return .purchaseCompleted(purchaseInfo(properties))
        case SystemEventNames.purchaseFailed:
            return .purchaseFailed(purchaseInfo(properties), message: message(properties))
        case SystemEventNames.purchaseCancelled:
            return .purchaseCancelled(purchaseInfo(properties))
        case SystemEventNames.purchasePending:
            return .purchasePending(purchaseInfo(properties))
        case SystemEventNames.restoreCompleted:
            return .restoreCompleted
        case SystemEventNames.restoreFailed:
            return .restoreFailed(message: message(properties))
        case SystemEventNames.restoreNoPurchases:
            return .restoreNoPurchases
        case SystemEventNames.purchaseSynced:
            return .purchaseSynced(
                transactionId: string(properties, "transaction_id") ?? "",
                originalTransactionId: nonEmptyString(properties, "original_transaction_id"),
                productId: string(properties, "product_id") ?? ""
            )
        case SystemEventNames.featureUsed:
            return .featureUsed(
                featureId: string(properties, "feature_extId", "feature_id") ?? "",
                amount: double(properties, "amount", "value") ?? 1,
                entityId: nonEmptyString(properties, "entityId", "entity_id")
            )
        case JourneyEvents.experimentExposure,
             JourneyEvents.experimentExposureFallback:
            return .experimentExposure(
                experienceRef(properties),
                experimentKey: string(properties, "experiment_key") ?? "",
                variantKey: string(properties, "variant_key") ?? "",
                isHoldout: bool(properties, "is_holdout") ?? false,
                isFallback: name == JourneyEvents.experimentExposureFallback
            )
        case JourneyEvents.experimentExposureError:
            return .experimentError(
                experienceRef(properties),
                experimentKey: string(properties, "experiment_key") ?? "",
                message: message(properties)
            )
        case SystemEventNames.productsUnavailable:
            return .productsUnavailable(
                experienceRef(properties),
                productIds: stringArray(properties, "product_ids")
            )
        case SystemEventNames.screenShown:
            return .screenShown(
                experienceRef(properties),
                screenId: string(properties, "screen_id") ?? ""
            )
        case SystemEventNames.screenDismissed:
            return .screenDismissed(
                experienceRef(properties),
                screenId: string(properties, "screen_id") ?? ""
            )
        case JourneyEvents.experienceArtifactLoadFailed:
            return .experienceLoadFailed(
                experienceRef(properties),
                message: message(properties)
            )
        case SystemEventNames.notificationsEnabled:
            return .permissionResolved(optionalExperienceRef(properties), kind: .notifications, granted: true)
        case SystemEventNames.notificationsDenied:
            return .permissionResolved(optionalExperienceRef(properties), kind: .notifications, granted: false)
        case SystemEventNames.permissionGranted:
            return .permissionResolved(optionalExperienceRef(properties), kind: .other, granted: true)
        case SystemEventNames.permissionDenied:
            return .permissionResolved(optionalExperienceRef(properties), kind: .other, granted: false)
        case SystemEventNames.trackingAuthorized:
            return .permissionResolved(optionalExperienceRef(properties), kind: .tracking, granted: true)
        case SystemEventNames.trackingDenied:
            return .permissionResolved(optionalExperienceRef(properties), kind: .tracking, granted: false)
        case SystemEventNames.appInstalled:
            return .appInstalled
        case SystemEventNames.appUpdated:
            return .appUpdated(
                fromVersion: nonEmptyString(properties, "previous_version", "from_version"),
                toVersion: string(properties, "app_version", "to_version") ?? ""
            )
        case SystemEventNames.appOpened:
            return .appOpened
        case SystemEventNames.appBackgrounded:
            return .appBackgrounded
        default:
            // `mappedNames` and this switch are kept in the same file so the
            // source-scan completeness test makes this branch unreachable.
            return nil
        }
    }

    private static func experienceRef(_ properties: [String: Any]) -> ExperienceRef {
        ExperienceRef(
            experienceId: string(properties, "experience_id") ?? "",
            experienceVersion: nonEmptyString(
                properties,
                "experience_version",
                "experience_version_id"
            ),
            journeyId: nonEmptyString(properties, "journey_id")
        )
    }

    /// Extracts the identity carried by the committed events that establish a
    /// journey's presentation context. Journey summaries deliberately do not
    /// put this identity on their wire payloads.
    static func observedJourneyExperienceRef(_ properties: [String: Any]) -> ExperienceRef? {
        guard let journeyId = nonEmptyString(properties, "journey_id"),
              let experienceId = nonEmptyString(properties, "experience_id") else {
            return nil
        }
        return ExperienceRef(
            experienceId: experienceId,
            experienceVersion: nonEmptyString(
                properties,
                "experience_version",
                "experience_version_id"
            ),
            journeyId: journeyId
        )
    }

    static func journeyId(in properties: [String: Any]) -> String? {
        nonEmptyString(properties, "journey_id")
    }

    private static func summaryExperienceRef(
        _ properties: [String: Any],
        cached: ExperienceRef?,
        eventName: String
    ) -> ExperienceRef? {
        if let direct = observedJourneyExperienceRef(properties) {
            return direct
        }
        if let cached { return cached }
        let journeyId = nonEmptyString(properties, "journey_id") ?? "<missing>"
        LogDebug(
            "Dropping forwarded \(eventName) summary: no experience context for journey \(journeyId)"
        )
        return nil
    }

    private static func optionalExperienceRef(
        _ properties: [String: Any]
    ) -> ExperienceRef? {
        guard nonEmptyString(properties, "experience_id") != nil else { return nil }
        return experienceRef(properties)
    }

    private static func purchaseInfo(_ properties: [String: Any]) -> PurchaseInfo {
        PurchaseInfo(
            productId: string(properties, "product_id") ?? "",
            storeProductId: string(properties, "store_product_id") ?? "",
            placementId: nonEmptyString(properties, "placement_id"),
            experience: optionalExperienceRef(properties),
            price: decimal(properties, "price"),
            displayPrice: nonEmptyString(properties, "display_price"),
            transactionId: nonEmptyString(properties, "transaction_id"),
            isTestStore: bool(properties, "test_store", "is_test_store") ?? false
        )
    }

    private static func dismissReason(_ properties: [String: Any]) -> DismissReason? {
        guard let raw = string(properties, "reason", "close_reason") else { return nil }
        switch raw {
        case "goal_met", "goalMet": return .goalMet
        case "purchase", "purchased": return .purchase
        case "timeout", "timed_out": return .timeout
        case "error", "errored": return .error
        case "host": return .host
        case "user", "dismissed": return .user
        default: return DismissReason(rawValue: raw)
        }
    }

    private static func exitReason(_ properties: [String: Any]) -> JourneyExitReason {
        switch string(properties, "reason", "exit_reason") {
        case "completed": .completed
        case "converted_exit", "goal_met": .goalMet
        case "stopped_matching", "trigger_unmatched": .triggerUnmatched
        case "time_limit", "expired": .expired
        // The pinned wire contract serializes user dismissal as "cancelled"
        // (conformance: journey dismissal vectors), so the two are not
        // distinguishable here by design; host dismissal is recognizable by
        // its dismissed_by property upstream.
        case "cancelled": .cancelled
        case "dismissed": .dismissed
        case "error": .error
        default: .completed
        }
    }

    private static func message(_ properties: [String: Any]) -> String {
        string(properties, "error_message", "message", "error", "reason") ?? ""
    }

    private static func string(
        _ properties: [String: Any],
        _ keys: String...
    ) -> String? {
        for key in keys {
            if let value = properties[key] as? String { return value }
            if let value = properties[key] as? NSNumber { return value.stringValue }
        }
        return nil
    }

    private static func nonEmptyString(
        _ properties: [String: Any],
        _ keys: String...
    ) -> String? {
        for key in keys {
            if let value = string(properties, key), !value.isEmpty { return value }
        }
        return nil
    }

    private static func bool(
        _ properties: [String: Any],
        _ keys: String...
    ) -> Bool? {
        for key in keys {
            if let value = properties[key] as? Bool { return value }
            if let value = properties[key] as? NSNumber { return value.boolValue }
            if let value = properties[key] as? String {
                if value == "true" { return true }
                if value == "false" { return false }
            }
        }
        return nil
    }

    private static func double(
        _ properties: [String: Any],
        _ keys: String...
    ) -> Double? {
        for key in keys {
            if let value = properties[key] as? NSNumber { return value.doubleValue }
            if let value = properties[key] as? Double { return value }
            if let value = properties[key] as? String, let result = Double(value) { return result }
        }
        return nil
    }

    private static func decimal(_ properties: [String: Any], _ key: String) -> Decimal? {
        if let value = properties[key] as? Decimal { return value }
        if let value = properties[key] as? NSNumber { return value.decimalValue }
        if let value = properties[key] as? String { return Decimal(string: value) }
        return nil
    }

    private static func stringArray(_ properties: [String: Any], _ key: String) -> [String] {
        if let values = properties[key] as? [String] { return values }
        if let values = properties[key] as? [Any] { return values.compactMap { $0 as? String } }
        if let value = properties[key] as? String,
           let data = value.data(using: .utf8),
           let values = try? JSONDecoder().decode([String].self, from: data) {
            return values
        }
        return []
    }
}
