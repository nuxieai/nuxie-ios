import Foundation

/// Shared feature-access evaluation for gate plans.
///
/// Both TriggerService and JourneyService act on server gate plans; the
/// access rules live here once so the two paths cannot drift (they had
/// already duplicated `hasAccess`/`currentFeatureAccess` verbatim).
enum GatePlanEvaluation {
    /// Whether an access record satisfies the plan's balance requirement.
    static func hasAccess(_ access: FeatureAccess?, requiredBalance: Int?) -> Bool {
        guard let access else { return false }
        if access.type == .boolean {
            return access.allowed
        }
        if access.unlimited {
            return true
        }
        return (access.balance ?? 0) >= (requiredBalance ?? 1)
    }

    /// The current cached access for a feature from the main-actor
    /// FeatureInfo store.
    static func cachedFeatureAccess(
        _ featureInfo: FeatureInfo,
        featureId: String
    ) async -> FeatureAccess? {
        await MainActor.run {
            featureInfo.feature(featureId)
        }
    }
}
