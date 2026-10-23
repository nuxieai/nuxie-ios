import Foundation

struct JourneyRun {
    /// Profile values that an admitted Journey still needs after delivery changes
    /// or disappears. Execution ownership is positional and cannot depend on
    /// the server continuing to advertise an already-started leg.
    struct ExecutionSnapshot: Codable, Sendable {
        let delivery: JourneyReleaseDelivery
        let assignments: ExactJSONObject<JourneyFactTable.Assignment?>
        var customer: ExactJSONObject<JourneyReleaseJSONValue>? = nil
    }

    struct Park {
        let wakeAt: Date?
        let anchorAt: Date?

        init(
            wakeAt: Date?,
            anchorAt: Date? = nil
        ) {
            self.wakeAt = wakeAt
            self.anchorAt = anchorAt
        }
    }
    struct ExperimentExposure: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable {
            case assigned
            case fallback
        }

        let experimentId: String
        let variantId: String
        let isHoldout: Bool
        let kind: Kind
        let eventId: String
        let selectedAt: Date
        /// The authenticated screen activation that first made this selected
        /// path visible. An unrelated later screen cannot expose it.
        var presentationScreenId: String?
        var shownAt: Date?
    }

    struct PendingCommerce: Codable, Sendable {
        let stepId: String
        let effectId: String
        let context: ArmedJourney.Context
        let placementId: String?
    }

    struct PendingCommerceOutcome: Sendable {
        let eventId: String
        let effectId: String
        let event: JourneyControlExecutor.Event
    }

    let journeyId: String
    let generation: Int
    let reference: ArmedJourney.Reference
    let executionSnapshot: ExecutionSnapshot
    var artifactSHA256s: [String]
    let reentry: Journey.Frequency
    let startedAt: Date
    let isEnrollment: Bool
    let startedEventId: String
    let completedEventId: String
    var executionStatus: String = "executing"
    var cursorRevision: Int64 = 0
    var executionEpoch: Int64 = 0
    var inputEventId: String? = nil
    var evaluationAt: Int64? = nil
    var initialLagMillis: Int64? = nil
    var lastConsumed: CustomerLogPosition? = nil
    var stepId: String
    var park: Park?
    var nativeSnapshot: ExperienceRunSnapshot? = nil
    var context: ArmedJourney.Context
    var outputs = ArmedJourney.Context(event: [:], responses: [:])
    /// Stable effect identities claimed before any host-visible side effect.
    /// A claimed effect is deliberately not a resume point: process death
    /// after this write abandons the Journey instead of replaying the effect.
    var effectReceipts: [String: String] = [:]
    var pendingCommerce: PendingCommerce? = nil
    var authoredCloseOutcome: String? = nil
    var pendingCommerceOutcome: PendingCommerceOutcome? = nil
    /// Experiment decisions survive until a selected variant reaches a visible
    /// presentation. A stable event identity makes post-show reporting
    /// idempotent across retries and process recovery.
    var experimentExposures: [ExperimentExposure] = []
    var id: String { "\(journeyId):\(generation)" }
}

struct JourneyStateArmReceipt: Codable, Hashable, Sendable {
    let reference: ArmedJourney.Reference
    let binding: ArmedJourney.Binding
    let entryKind: JourneyEntryCondition.Kind

    init(reference: ArmedJourney.Reference, binding: ArmedJourney.Binding, entryKind: JourneyEntryCondition.Kind) {
        self.reference = reference
        self.binding = binding
        self.entryKind = entryKind
    }

    init(_ arm: ArmedJourney) {
        reference = arm.reference
        binding = arm.binding
        entryKind = arm.entryCondition.type
    }
}

enum JourneyExecutionError: Error {
    case invalidState, unsupportedVersion, storageLimit
}


extension JourneyRun: Sendable {}
extension JourneyRun.Park: Equatable, Sendable {}

