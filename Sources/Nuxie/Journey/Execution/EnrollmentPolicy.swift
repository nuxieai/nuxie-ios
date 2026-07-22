import Foundation

/// Reentry/suppression decision for starting a journey.
///
/// Data-in/data-out: the campaign's reentry policy plus lazy
/// completion-history lookups in, a suppression reason (or nil = may start)
/// out. Lookups stay closures so only the branch the policy needs runs —
/// mirroring the store access pattern the service had inline. This shape is
/// the portable spec for other SDK platforms.
enum EnrollmentPolicy {
    static func suppressionReason(
        reentry: CampaignReentry,
        hasLiveJourney: Bool,
        hasCompleted: () -> Bool,
        lastCompletionAt: () -> Date?,
        timeIntervalSinceLastCompletion: (Date) -> TimeInterval
    ) -> SuppressReason? {
        if hasLiveJourney { return .alreadyActive }

        switch reentry {
        case .everyTime:
            return nil
        case .oneTime:
            return hasCompleted() ? .reentryLimited : nil
        case .oncePerWindow(let window):
            guard let lastCompletion = lastCompletionAt() else {
                return nil
            }
            let allowed = timeIntervalSinceLastCompletion(lastCompletion) >= windowInterval(window)
            return allowed ? nil : .reentryLimited
        }
    }

    static func windowInterval(_ window: Window) -> TimeInterval {
        switch window.unit {
        case .minute: return TimeInterval(window.amount * 60)
        case .hour: return TimeInterval(window.amount * 3600)
        case .day: return TimeInterval(window.amount * 86400)
        case .week: return TimeInterval(window.amount * 604800)
        }
    }
}
