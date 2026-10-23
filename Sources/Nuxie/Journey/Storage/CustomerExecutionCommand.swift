import Foundation

struct CustomerLogPosition: Sendable, Equatable {
    let milliseconds: Int64
    let eventId: String
}

struct CustomerResponseLaneKey: Sendable, Hashable {
    let journeyId: String
    let formName: String
}

/// Prepared events contain the final privacy projection. Preparation never holds SQL open.
struct CustomerExecutionCommand: Sendable {
    let owner: CustomerStoreOwner
    let epoch: Int64
    let mutation: Mutation
    var events: [StableEventCaptureRecord] = []
    var admission: JourneyCommitAdmission? = nil
    var profileFence: JourneyProfileFence? = nil
    var profileToken: JourneyProfileFenceToken? = nil

    enum Mutation: Sendable {
        case freezePlan(eventId: String, targets: [String])
        case decideTarget(eventId: String, target: String)
        case admit(CustomerAdmission)
        case applyInput(CustomerInputTransition)
        case resolveWait(CustomerInputTransition)
        case beginEvaluation(key: CustomerJourneyKey, revision: Int64, now: Int64, triggeringAt: Int64?)
        case claimEffect(key: CustomerJourneyKey, revision: Int64, stepId: String, effectId: String, kind: String)
        case retainCommerce(key: CustomerJourneyKey, revision: Int64, stepId: String, effectId: String, placementId: String?)
        case receiveEffectResult(key: CustomerJourneyKey, revision: Int64, stepId: String, effectId: String, eventId: String)
        case settleEffect(CustomerInputTransition, effectId: String, stepId: String)
        case authoredClose(key: CustomerJourneyKey, revision: Int64, effectId: String, outcome: String)
        case complete(key: CustomerJourneyKey, revision: Int64, at: Int64, reportId: String)
        case bindExposures(key: CustomerJourneyKey, revision: Int64, screenId: String)
        case publishExposures(key: CustomerJourneyKey, revision: Int64, screenId: String, shownAt: Int64)
        case expireMeasurement(cutoffAcceptedAt: Int64)
        case measure(eventId: String, watches: [String: JourneyConversionWatch], expectedDigest: String)
        case reserveResponse(key: CustomerJourneyKey, formName: String, answers: ExactJSONObject<JourneyReleaseJSONValue>, queued: Bool)
        case normalizeResponseClock(at: Int64)
        case responseReply(JourneyResponseSave, JourneyResponseSaveReply, at: Int64, waiting: Bool)
        case retainArms(Set<JourneyStateArmReceipt>)
        case clearArms(JourneyEntryCondition.Kind)
        case revoke
        case recover([CustomerTerminalBoundary], revoke: Bool)
        case reopen
        case compact(eventId: String)
    }
}

struct CustomerAdmission: Sendable {
    let journey: JourneyRun
    let pins: [CustomerReleasePin]
    let watch: JourneyConversionWatch?
    let arm: JourneyStateArmReceipt
    let sourceEventId: String?
    let targetKey: String
    let stateLatch: Bool
    var policyHash: String = ""
}

/// A pure evaluator proposes this value against the cursor it read.
struct CustomerInputTransition: Sendable {
    let key: CustomerJourneyKey
    let expectedRevision: Int64
    var eventId: String?
    let targetKey: String
    let stepId: String
    let context: ArmedJourney.Context
    var checkpoint: JourneyControlExecutor.Checkpoint? = nil
    var nativeSnapshot: ExperienceRunSnapshot? = nil
    var exposure: JourneyRun.ExperimentExposure? = nil
    var waitKind: String = "event"
    var presentationSource: ScreenEmissionSource? = nil
    var consumesWait = false
    var responsesChanged = false
    var resetEvaluation = false
    var availabilityAt: Int64? = nil
    var resumeInPresentAt: Int64? = nil
    var rendererInvocationId: String? = nil
    var rendererOccurredAt: Int64? = nil
    var commerceToRetain: JourneyRun.PendingCommerce? = nil
    var waitEvaluation: CustomerWaitEvaluation? = nil
}

struct CustomerExecutionResult: Sendable {
    var targets: [String] = []
    var journey: JourneyRun? = nil
    var commits: [StableEventCaptureCommit] = []
    var effectId: String? = nil
    var response: JourneyResponseSave? = nil
    var stopped = false
    var replayed = false
}

/// Publication follows the committed SQL outcome and owns no writer or file lock.
struct CustomerCommandPublication: Sendable {
    let command: CustomerExecutionCommand
    let result: CustomerExecutionResult
}


struct CustomerTerminalBoundary: Sendable {
    let key: CustomerJourneyKey
    let revision: Int64
    let reportId: String
    let at: Int64
}


enum CustomerTransactionFaultPoint: Sendable, Equatable {
    case statement(Int)
    case beforeCommit
    case afterCommit
}


extension CustomerExecutionCommand.Mutation {
    var faultLabel: String {
        switch self {
        case .complete: return "completion"
        case .resolveWait: return "wait"
        case .applyInput: return "input"
        case .admit: return "admission"
        default: return "other"
        }
    }
}


struct CustomerWaitEvaluation: Sendable {
    let step: Journey.Step
    let context: ArmedJourney.Context
    let checkpoint: JourneyControlExecutor.Checkpoint
    let executor: JourneyControlExecutor
    let assignments: ExactJSONObject<JourneyFactTable.Assignment?>
    let customer: ExactJSONObject<JourneyReleaseJSONValue>
}
