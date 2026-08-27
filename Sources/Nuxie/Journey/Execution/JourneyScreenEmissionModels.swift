#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import Foundation

struct ExperienceEventCausality: Codable, Equatable, Sendable {
    let chainId: String
    let parentEventId: String?
    let visitedExperienceIds: [String]
    let hopCount: UInt8
}

enum ExperienceAdmissionCausalityError: Error, Equatable, Sendable {
    case experienceCycle
    case experienceHopLimit
}

func extendExperienceAdmissionCausality(
    _ source: ExperienceEventCausality,
    targetExperienceId: String
) -> Result<ExperienceEventCausality, ExperienceAdmissionCausalityError> {
    guard !source.visitedExperienceIds.contains(targetExperienceId) else {
        return .failure(.experienceCycle)
    }
    guard source.hopCount < 32 else { return .failure(.experienceHopLimit) }
    return .success(ExperienceEventCausality(
        chainId: source.chainId,
        parentEventId: source.parentEventId,
        visitedExperienceIds: source.visitedExperienceIds + [targetExperienceId],
        hopCount: source.hopCount + 1
    ))
}

struct JourneyScreenEmissionRunState: Equatable, Sendable {
    let journeyId: String
    let experienceId: String
    let customerId: String
    let executionOwnershipEpoch: UInt64
    let lifecycleGeneration: UInt64
    let presentationEpoch: UInt64
    let screenId: String?
    let terminal: Bool
    let causality: ExperienceEventCausality
}

struct JourneyIngressRunScope: Codable, Equatable, Sendable {
    let experienceId: String
    let journeyId: String
    let executionOwnershipEpoch: UInt64
    let lifecycleGeneration: UInt64
}

enum JourneyIngressSource: Codable, Equatable, Sendable {
    case hostApp
    case sdkSystemGlobal
    case sdkSystemRun(scope: JourneyIngressRunScope, effectInvocationId: String?)
    case journeySystem(scope: JourneyIngressRunScope)
    case journeyAction(scope: JourneyIngressRunScope, routeKey: String, actionPath: String)
}

struct JourneyIngressEvent: Equatable, Sendable {
    let id: String
    let customerId: String
    let occurredAt: String
    let name: String
    let payload: [String: ScreenEmissionValue]
    let source: JourneyIngressSource
}

enum ScreenCustomerEventSource: Codable, Equatable, Sendable {
    case screen(
        experienceId: String,
        journeyId: String,
        source: ScreenEmissionSource
    )
    case ingress(JourneyIngressSource)
}

struct ScreenCustomerEvent: Codable, Equatable, Sendable {
    let id: String
    let customerId: String
    let occurredAt: String
    let name: String
    let payload: [String: ScreenEmissionValue]
    let source: ScreenCustomerEventSource
    let causality: ExperienceEventCausality
}

enum ScreenLocalRouteRequest: Codable, Equatable, Sendable {
    case screen(screenId: String, eventName: String)
    case journey(eventName: String)
    case effectOutcome(
        effect: String,
        invocationId: String,
        outcome: String
    )
}

struct AcceptedScreenLocalRoute: Codable, Equatable, Sendable {
    let admissionId: String
    let key: ScreenLocalRouteRequest
    let routeRevision: String
}

enum ScreenLocalRouteDisposition: Codable, Equatable, Sendable {
    case none
    case ready(AcceptedScreenLocalRoute)
    case alreadyProcessed
    case payloadInvalid(key: ScreenLocalRouteRequest, routeRevision: String)
}

struct ScreenCustomerEventAdmission: Equatable, Sendable {
    enum Disposition: Equatable, Sendable {
        case accepted
        case duplicate
    }

    let disposition: Disposition
    let localRoute: ScreenLocalRouteDisposition
}

struct ScreenCustomerEventAcceptance: Sendable {
    let event: ScreenCustomerEvent
    let localRoute: ScreenLocalRouteRequest?
    let excludeExperienceId: String?
}

enum JourneyIngressRejection: Error, Equatable, Sendable {
    case eventNameInvalid
    case customerEventAcceptanceFailed
    case runMissing
    case runIdentityMismatch
    case ownershipStale
    case lifecycleStale
    case runTerminal
    case effectOutcomeInvalid
}

struct JourneyIngressAuthority: Sendable {
    let accept: @Sendable (
        JourneyIngressEvent
    ) async -> Result<ScreenCustomerEventAdmission, JourneyIngressRejection>
}

enum JourneyScreenEmissionSkipReason: Codable, Equatable, Sendable {
    case runMissing
    case ownershipStale
    case lifecycleStale
    case presentationStale
    case screenStale
    case runTerminal
    case batchSequenceOutOfOrder
    case responseRejected
    case reservedNameInvalid
    case eventNameInvalid
    case customerEventAcceptanceFailed
}

enum JourneyScreenEmissionDrainStatus: Codable, Equatable, Sendable {
    case drained
    case rejected
    case aborted
    case invalidated
}

struct JourneyScreenEmissionDrainResult: Codable, Equatable, Sendable {
    let status: JourneyScreenEmissionDrainStatus
    let acceptedEmissionIds: [String]
    let skippedEmissionIds: [String]
    let reason: JourneyScreenEmissionSkipReason?
}

enum JourneyScreenResponseEmissionResult: Equatable, Sendable {
    case accepted
    case rejected(message: String)
}

struct JourneyScreenBatchRecovery: Sendable {
    let lastProcessedSequence: UInt64?
    let result: JourneyScreenEmissionDrainResult?
}
#endif
