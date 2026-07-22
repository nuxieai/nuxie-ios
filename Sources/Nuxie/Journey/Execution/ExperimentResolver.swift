import Foundation

/// Decides which experiment variant runs and which exposure record must be
/// emitted. The runner performs the actual event emission, context writes,
/// and variant-action execution.
///
/// Data-in/data-out: variant ids + the server assignment + journey-context
/// snapshots in, a resolution out. This shape is the portable spec for other
/// SDK platforms.
///
/// INVARIANT (experimentation trust): no variant's actions execute without a
/// classifiable exposure record — a real $experiment_exposure, a tagged
/// fallback, or an error that SKIPS execution. Silent variant[0] runs corrupt
/// experiment analysis.
enum ExperimentResolver {
    enum ContextKeys {
        static let frozenVariantsByExperiment = "_experiment_variants"
        static let exposureEmittedByExperiment = "_experiment_exposure_emitted"
    }

    enum Exposure: Equatable {
        /// No exposure event: either one was already emitted for this
        /// experiment in this journey, or no variant runs.
        case none
        /// Real $experiment_exposure: the server-assigned variant matched.
        case real(assignmentSource: String, isHoldout: Bool)
        /// Tagged fallback exposure: the variant still runs (journeys must
        /// work offline) but analysis can exclude or segment these users.
        case fallback(assignmentSource: String)
    }

    struct Resolution: Equatable {
        /// Variant to run; nil means the node executes nothing.
        let variantId: String?
        /// Freeze the resolved variant into journey context so re-execution
        /// stays deterministic.
        let shouldFreezeVariant: Bool
        let exposure: Exposure
        /// Emit $experiment_exposure_error (a running experiment's assigned
        /// variant is missing from this action) — the node is skipped:
        /// exposed-but-invisible users are worse than a skipped node.
        let errorAssignedVariantKey: String?

        static let skip = Resolution(
            variantId: nil,
            shouldFreezeVariant: false,
            exposure: .none,
            errorAssignedVariantKey: nil
        )
    }

    static func resolve(
        variantIds: [String],
        assignment: ExperimentAssignment?,
        frozenVariantKey: String?,
        hasEmittedExposure: Bool
    ) -> Resolution {
        guard !variantIds.isEmpty else { return .skip }

        let frozenVariantId = frozenVariantKey.flatMap { key in
            variantIds.first(where: { $0 == key })
        }
        let status = assignment?.status

        // Error path: a running experiment whose assigned variant does not
        // exist in this action executes NOTHING.
        if frozenVariantId == nil,
           status == "running",
           let assignedKey = assignment?.variantKey,
           !variantIds.contains(assignedKey) {
            return Resolution(
                variantId: nil,
                shouldFreezeVariant: false,
                exposure: .none,
                errorAssignedVariantKey: assignedKey
            )
        }

        let resolved: (variantId: String?, matchedAssignment: Bool) =
            frozenVariantId != nil
            ? (frozenVariantId, assignment?.variantKey == frozenVariantKey)
            : resolveVariant(variantIds: variantIds, assignment: assignment)

        guard let variantId = resolved.variantId else { return .skip }

        let shouldFreeze = status == "running"
            && resolved.matchedAssignment
            && (frozenVariantKey == nil || frozenVariantId == nil)

        let exposure: Exposure
        if hasEmittedExposure {
            exposure = .none
        } else if status == "running", resolved.matchedAssignment {
            exposure = .real(
                assignmentSource: frozenVariantId != nil ? "journey_context" : "profile",
                isHoldout: assignment?.isHoldout ?? false
            )
        } else {
            // Default-branch fallback (no assignment, or experiment not
            // running): never silent.
            exposure = .fallback(
                assignmentSource: assignment == nil
                    ? "no_assignment"
                    : "status_\(status ?? "unknown")"
            )
        }

        return Resolution(
            variantId: variantId,
            shouldFreezeVariant: shouldFreeze,
            exposure: exposure,
            errorAssignedVariantKey: nil
        )
    }

    private static func resolveVariant(
        variantIds: [String],
        assignment: ExperimentAssignment?
    ) -> (variantId: String?, matchedAssignment: Bool) {
        guard let assignment else {
            return (variantIds.first, false)
        }

        switch assignment.status {
        case "running", "concluded":
            if let variantKey = assignment.variantKey, variantIds.contains(variantKey) {
                return (variantKey, true)
            }
            return (variantIds.first, false)
        default:
            return (variantIds.first, false)
        }
    }

    // MARK: - Journey-context snapshot coercion

    /// The frozen variant key recorded in journey context, if any.
    static func frozenVariantKey(in contextValue: Any?, experimentKey: String) -> String? {
        guard let dict = contextValue as? [String: Any] else { return nil }
        return dict[experimentKey] as? String
    }

    /// Whether an exposure was already emitted per the journey-context record
    /// (tolerates Bool/Int/String encodings from persisted context).
    static func exposureEmitted(in contextValue: Any?, experimentKey: String) -> Bool {
        guard let dict = contextValue as? [String: Any] else { return false }
        if let emitted = dict[experimentKey] as? Bool {
            return emitted
        }
        if let emitted = dict[experimentKey] as? Int {
            return emitted != 0
        }
        if let emitted = dict[experimentKey] as? String {
            return emitted == "true" || emitted == "1"
        }
        return false
    }
}
