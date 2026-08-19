#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import Foundation

struct ExperienceEventCausality: Equatable, Sendable {
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

struct ScreenEventRouterRun: Equatable, Sendable {
    let journeyId: String
    let experienceId: String
    let customerId: String
    let executionOwnershipEpoch: UInt64
    let lifecycleGeneration: UInt64
    let presentationEpoch: UInt64
    let terminal: Bool
    let causality: ExperienceEventCausality
}

struct JourneyIngressRunScope: Equatable, Sendable {
    let experienceId: String
    let journeyId: String
    let executionOwnershipEpoch: UInt64
    let lifecycleGeneration: UInt64
}

enum JourneyIngressSource: Equatable, Sendable {
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

enum ScreenCustomerEventSource: Equatable, Sendable {
    case screen(
        experienceId: String,
        journeyId: String,
        source: ScreenEmissionSource
    )
    case ingress(JourneyIngressSource)
}

struct ScreenCustomerEvent: Equatable, Sendable {
    let id: String
    let customerId: String
    let occurredAt: String
    let name: String
    let payload: [String: ScreenEmissionValue]
    let source: ScreenCustomerEventSource
    let causality: ExperienceEventCausality
}

enum ScreenLocalRouteRequest: Equatable, Sendable {
    case screen(screenId: String, eventName: String)
    case journey(eventName: String)
    case effectOutcome(
        effect: String,
        invocationId: String,
        outcome: String
    )
}

struct AcceptedScreenLocalRoute: Equatable, Sendable {
    let admissionId: String
    let key: ScreenLocalRouteRequest
    let routeRevision: String
}

enum ScreenLocalRouteDisposition: Equatable, Sendable {
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

enum ScreenEventRouterDiagnosticCode: Equatable, Sendable {
    case routePayloadInvalid
    case responseEmissionRejected
    case reservedNameInvalid
    case eventNameInvalid
    case customerEventAcceptanceFailed
}

struct ScreenEventRouterDiagnostic: Equatable, Sendable {
    let code: ScreenEventRouterDiagnosticCode
    let journeyId: String?
    let emissionId: String
    let message: String
}

enum ScreenEventRouterSkipReason: Equatable, Sendable {
    case runMissing
    case ownershipStale
    case lifecycleStale
    case presentationStale
    case runTerminal
    case batchSequenceOutOfOrder
    case responseRejected
    case reservedNameInvalid
    case eventNameInvalid
    case customerEventAcceptanceFailed
}

struct ScreenEventRouterSkippedTail: Equatable, Sendable {
    let journeyId: String
    let invocationId: String
    let batchSequence: UInt64
    let reason: ScreenEventRouterSkipReason
    let emissionIds: [String]
}

enum ScreenEventRouterDrainStatus: Equatable, Sendable {
    case drained
    case rejected
    case aborted
    case invalidated
}

struct ScreenEventRouterDrainResult: Equatable, Sendable {
    let status: ScreenEventRouterDrainStatus
    let acceptedEmissionIds: [String]
    let skippedEmissionIds: [String]
    let reason: ScreenEventRouterSkipReason?
}

enum ScreenResponseEmissionResult: Equatable, Sendable {
    case accepted
    case rejected(message: String)
}

enum ScreenIngressRejection: Error, Equatable, Sendable {
    case eventNameInvalid
    case customerEventAcceptanceFailed
    case runMissing
    case runIdentityMismatch
    case ownershipStale
    case lifecycleStale
    case runTerminal
    case effectOutcomeInvalid
}

struct ScreenEventRouterAuthority: Sendable {
    let acceptIngress: @Sendable (
        JourneyIngressEvent
    ) async -> Result<ScreenCustomerEventAdmission, ScreenIngressRejection>
}

struct ScreenBatchRecovery: Sendable {
    let lastProcessedSequence: UInt64?
    let result: ScreenEventRouterDrainResult?
}

struct ScreenEmissionRouterPorts: Sendable {
    let createCausalityId: @Sendable () -> String
    let readRun: @Sendable (String) async -> ScreenEventRouterRun?
    let applyResponse: @Sendable (
        ScreenEventRouterRun,
        ScreenEmissionSource,
        ScreenEmission
    ) async -> ScreenResponseEmissionResult
    /// One durable transaction owns Customer Event deduplication, source-run
    /// logging, optional route admission/checkpointing, analytics sync, and
    /// the global outbox under the event's existing id.
    let acceptCustomerEvent: @Sendable (
        ScreenCustomerEventAcceptance
    ) async throws -> ScreenCustomerEventAdmission
    /// Reconstructs completion from durable response, event, route, tail,
    /// wait, and lifecycle receipts before the router evaluates live epochs.
    /// The recovered result remains authoritative if a crash happened before
    /// the derived progress index below was checkpointed.
    let recoverBatch: @Sendable (ScreenEmissionBatch) async -> ScreenBatchRecovery
    /// Optional durable index; correctness remains owned by `recoverBatch`.
    let recordBatchResult: @Sendable (
        String,
        UInt64,
        String,
        ScreenEventRouterDrainResult
    ) async -> Void
    let resolveEffectOutcomeParent: @Sendable (
        ScreenEventRouterRun,
        String,
        String
    ) async -> String?
    let runRouteToStableBoundary: @Sendable (
        AcceptedScreenLocalRoute,
        ScreenCustomerEvent,
        ScreenEventRouterAuthority
    ) async -> Void
    let finishSourceEvent: @Sendable (
        ScreenCustomerEvent,
        ScreenEventRouterAuthority
    ) async -> Void
    let recordDiagnostic: @Sendable (ScreenEventRouterDiagnostic) async -> Void
    let recordSkippedTail: @Sendable (ScreenEventRouterSkippedTail) async -> Void
}

final class ScreenEmissionRouter: Sendable {
    private let ports: ScreenEmissionRouterPorts
    private let gates = ScreenEmissionRouterGateRegistry()

    init(ports: ScreenEmissionRouterPorts) {
        self.ports = ports
    }

    func drain(
        _ batch: ScreenEmissionBatch
    ) async -> ScreenEventRouterDrainResult {
        let gate = await gates.gate(for: "run:\(batch.journeyId)")
        let sequenceLane = await gates.sequenceLane(for: batch.journeyId)
        let recovery = await ports.recoverBatch(batch)
        return await sequenceLane.submit(
            batch,
            durableLastProcessedSequence: recovery.lastProcessedSequence,
            durableResult: recovery.result,
            process: { [ports] in
                let result = await gate.withLock {
                    await Self.drain(batch, ports: ports)
                }
                await ports.recordBatchResult(
                    batch.journeyId,
                    batch.batchSequence,
                    batch.invocationId,
                    result
                )
                return result
            },
            reject: { [ports] in
                let skipped = await Self.skipTail(
                    batch,
                    from: 0,
                    reason: .batchSequenceOutOfOrder,
                    ports: ports
                )
                return ScreenEventRouterDrainResult(
                    status: .rejected,
                    acceptedEmissionIds: [],
                    skippedEmissionIds: skipped,
                    reason: .batchSequenceOutOfOrder
                )
            }
        )
    }

    func acceptIngress(
        _ event: JourneyIngressEvent
    ) async -> Result<ScreenCustomerEventAdmission, ScreenIngressRejection> {
        guard Self.isValidIngressName(event) else {
            return .failure(.eventNameInvalid)
        }
        let scope = Self.runScope(event.source)
        let key = scope.map { "run:\($0.journeyId)" } ?? "customer:\(event.customerId)"
        let gate = await gates.gate(for: key)
        return await gate.withLock { [ports] in
            await Self.acceptIngress(event, context: nil, ports: ports)
        }
    }

    private struct IngressAuthorityContext: Sendable {
        let journeyId: String
        let parentEventId: String
    }

    private static func acceptIngress(
        _ event: JourneyIngressEvent,
        context: IngressAuthorityContext?,
        ports: ScreenEmissionRouterPorts
    ) async -> Result<ScreenCustomerEventAdmission, ScreenIngressRejection> {
        guard isValidIngressName(event) else { return .failure(.eventNameInvalid) }
        let scope = runScope(event.source)
        if let context, scope?.journeyId != context.journeyId {
            return .failure(.runIdentityMismatch)
        }
        var sourceRun: ScreenEventRouterRun?
        if let scope {
            guard let run = await ports.readRun(scope.journeyId) else {
                return .failure(.runMissing)
            }
            guard run.journeyId == scope.journeyId,
                  run.experienceId == scope.experienceId,
                  run.customerId == event.customerId else {
                return .failure(.runIdentityMismatch)
            }
            guard run.executionOwnershipEpoch == scope.executionOwnershipEpoch else {
                return .failure(.ownershipStale)
            }
            guard run.lifecycleGeneration == scope.lifecycleGeneration else {
                return .failure(.lifecycleStale)
            }
            guard !run.terminal else { return .failure(.runTerminal) }
            sourceRun = run
        }

        let directRoute = ingressRoute(event)
        var parentEventId = context?.parentEventId ?? sourceRun?.causality.parentEventId
        if case .effectOutcome(let effect, let invocationId, _) = directRoute {
            guard let run = sourceRun,
                  let resolved = await ports.resolveEffectOutcomeParent(
                      run,
                      effect,
                      invocationId
                  ) else {
                return .failure(.effectOutcomeInvalid)
            }
            parentEventId = resolved
        }
        let causality = if let sourceRun {
            ExperienceEventCausality(
                chainId: sourceRun.causality.chainId,
                parentEventId: parentEventId,
                visitedExperienceIds: sourceRun.causality.visitedExperienceIds,
                hopCount: sourceRun.causality.hopCount
            )
        } else {
            ExperienceEventCausality(
                chainId: ports.createCausalityId(),
                parentEventId: nil,
                visitedExperienceIds: [],
                hopCount: 0
            )
        }
        let customerEvent = ScreenCustomerEvent(
            id: event.id,
            customerId: event.customerId,
            occurredAt: event.occurredAt,
            name: event.name,
            payload: event.payload,
            source: .ingress(event.source),
            causality: causality
        )
        let authority = ScreenEventRouterAuthority { nested in
            await acceptIngress(
                nested,
                context: scope.map {
                    IngressAuthorityContext(
                        journeyId: $0.journeyId,
                        parentEventId: customerEvent.id
                    )
                },
                ports: ports
            )
        }
        do {
            let admission = try await ports.acceptCustomerEvent(
                ScreenCustomerEventAcceptance(
                    event: customerEvent,
                    localRoute: directRoute,
                    excludeExperienceId: scope?.experienceId
                )
            )
            await handleRouteDisposition(
                admission,
                event: customerEvent,
                journeyId: scope?.journeyId,
                authority: authority,
                ports: ports
            )
            if scope != nil {
                await ports.finishSourceEvent(customerEvent, authority)
            }
            return .success(admission)
        } catch {
            await ports.recordDiagnostic(ScreenEventRouterDiagnostic(
                code: .customerEventAcceptanceFailed,
                journeyId: scope?.journeyId,
                emissionId: event.id,
                message: String(describing: error)
            ))
            return .failure(.customerEventAcceptanceFailed)
        }
    }

    private static func drain(
        _ batch: ScreenEmissionBatch,
        ports: ScreenEmissionRouterPorts
    ) async -> ScreenEventRouterDrainResult {
        var acceptedIds: [String] = []
        let initialRun = await ports.readRun(batch.journeyId)
        if let failure = gateFailure(batch, run: initialRun) {
            let skipped = await skipTail(batch, from: 0, reason: failure, ports: ports)
            return ScreenEventRouterDrainResult(
                status: .rejected,
                acceptedEmissionIds: [],
                skippedEmissionIds: skipped,
                reason: failure
            )
        }

        for (index, emission) in batch.emissions.enumerated() {
            guard let run = await ports.readRun(batch.journeyId) else {
                let skipped = await skipTail(
                    batch,
                    from: index,
                    reason: .runMissing,
                    ports: ports
                )
                return ScreenEventRouterDrainResult(
                    status: .invalidated,
                    acceptedEmissionIds: acceptedIds,
                    skippedEmissionIds: skipped,
                    reason: .runMissing
                )
            }
            if let failure = gateFailure(batch, run: run) {
                let skipped = await skipTail(batch, from: index, reason: failure, ports: ports)
                return ScreenEventRouterDrainResult(
                    status: .invalidated,
                    acceptedEmissionIds: acceptedIds,
                    skippedEmissionIds: skipped,
                    reason: failure
                )
            }

            if emission.name == SystemEventNames.responseSet || emission.name == SystemEventNames.responseUnset {
                switch await ports.applyResponse(run, batch.source, emission) {
                case .accepted:
                    acceptedIds.append(emission.id)
                case .rejected(let message):
                    await ports.recordDiagnostic(ScreenEventRouterDiagnostic(
                        code: .responseEmissionRejected,
                        journeyId: batch.journeyId,
                        emissionId: emission.id,
                        message: message
                    ))
                    let skipped = await skipTail(
                        batch,
                        from: index,
                        reason: .responseRejected,
                        ports: ports
                    )
                    return ScreenEventRouterDrainResult(
                        status: .aborted,
                        acceptedEmissionIds: acceptedIds,
                        skippedEmissionIds: skipped,
                        reason: .responseRejected
                    )
                }
            } else if emission.name.isEmpty || emission.name.hasPrefix("$") {
                let isEmpty = emission.name.isEmpty
                await ports.recordDiagnostic(ScreenEventRouterDiagnostic(
                    code: isEmpty ? .eventNameInvalid : .reservedNameInvalid,
                    journeyId: batch.journeyId,
                    emissionId: emission.id,
                    message: isEmpty
                        ? "screen emission event name must not be empty"
                        : "screen emissions cannot use reserved event name \(emission.name)"
                ))
                let skipped = await skipTail(
                    batch,
                    from: index,
                    reason: isEmpty ? .eventNameInvalid : .reservedNameInvalid,
                    ports: ports
                )
                return ScreenEventRouterDrainResult(
                    status: .aborted,
                    acceptedEmissionIds: acceptedIds,
                    skippedEmissionIds: skipped,
                    reason: isEmpty ? .eventNameInvalid : .reservedNameInvalid
                )
            } else {
                let customerEvent = ScreenCustomerEvent(
                    id: emission.id,
                    customerId: run.customerId,
                    occurredAt: emission.occurredAt,
                    name: emission.name,
                    payload: emission.payload,
                    source: .screen(
                        experienceId: run.experienceId,
                        journeyId: run.journeyId,
                        source: batch.source
                    ),
                    causality: run.causality
                )
                do {
                    let admission = try await ports.acceptCustomerEvent(
                        ScreenCustomerEventAcceptance(
                            event: customerEvent,
                            localRoute: .screen(
                                screenId: batch.source.screenId,
                                eventName: emission.name
                            ),
                            excludeExperienceId: run.experienceId
                        )
                    )
                    acceptedIds.append(customerEvent.id)
                    let authority = ScreenEventRouterAuthority { nested in
                        await acceptIngress(
                            nested,
                            context: IngressAuthorityContext(
                                journeyId: batch.journeyId,
                                parentEventId: customerEvent.id
                            ),
                            ports: ports
                        )
                    }
                    await handleRouteDisposition(
                        admission,
                        event: customerEvent,
                        journeyId: batch.journeyId,
                        authority: authority,
                        ports: ports
                    )
                    await ports.finishSourceEvent(customerEvent, authority)
                } catch {
                    await ports.recordDiagnostic(ScreenEventRouterDiagnostic(
                        code: .customerEventAcceptanceFailed,
                        journeyId: batch.journeyId,
                        emissionId: emission.id,
                        message: String(describing: error)
                    ))
                    let skipped = await skipTail(
                        batch,
                        from: index,
                        reason: .customerEventAcceptanceFailed,
                        ports: ports
                    )
                    return ScreenEventRouterDrainResult(
                        status: .aborted,
                        acceptedEmissionIds: acceptedIds,
                        skippedEmissionIds: skipped,
                        reason: .customerEventAcceptanceFailed
                    )
                }
            }

            if index + 1 < batch.emissions.count,
               let failure = gateFailure(
                   batch,
                   run: await ports.readRun(batch.journeyId)
               ) {
                let skipped = await skipTail(
                    batch,
                    from: index + 1,
                    reason: failure,
                    ports: ports
                )
                return ScreenEventRouterDrainResult(
                    status: .invalidated,
                    acceptedEmissionIds: acceptedIds,
                    skippedEmissionIds: skipped,
                    reason: failure
                )
            }
        }

        return ScreenEventRouterDrainResult(
            status: .drained,
            acceptedEmissionIds: acceptedIds,
            skippedEmissionIds: [],
            reason: nil
        )
    }

    private static func handleRouteDisposition(
        _ admission: ScreenCustomerEventAdmission,
        event: ScreenCustomerEvent,
        journeyId: String?,
        authority: ScreenEventRouterAuthority,
        ports: ScreenEmissionRouterPorts
    ) async {
        switch admission.localRoute {
        case .none, .alreadyProcessed:
            return
        case .ready(let route):
            await ports.runRouteToStableBoundary(route, event, authority)
        case .payloadInvalid(_, let routeRevision):
            await ports.recordDiagnostic(ScreenEventRouterDiagnostic(
                code: .routePayloadInvalid,
                journeyId: journeyId,
                emissionId: event.id,
                message: "payload rejected by route \(routeRevision)"
            ))
        }
    }

    private static func gateFailure(
        _ batch: ScreenEmissionBatch,
        run: ScreenEventRouterRun?
    ) -> ScreenEventRouterSkipReason? {
        guard let run else { return .runMissing }
        guard run.executionOwnershipEpoch == batch.executionOwnershipEpoch else {
            return .ownershipStale
        }
        guard run.lifecycleGeneration == batch.lifecycleGeneration else {
            return .lifecycleStale
        }
        guard run.presentationEpoch == batch.presentationEpoch else {
            return .presentationStale
        }
        guard !run.terminal else { return .runTerminal }
        return nil
    }

    private static func skipTail(
        _ batch: ScreenEmissionBatch,
        from index: Int,
        reason: ScreenEventRouterSkipReason,
        ports: ScreenEmissionRouterPorts
    ) async -> [String] {
        guard index < batch.emissions.count else { return [] }
        let ids = batch.emissions[index...].map(\.id)
        await ports.recordSkippedTail(ScreenEventRouterSkippedTail(
            journeyId: batch.journeyId,
            invocationId: batch.invocationId,
            batchSequence: batch.batchSequence,
            reason: reason,
            emissionIds: ids
        ))
        return ids
    }

    private static func runScope(
        _ source: JourneyIngressSource
    ) -> JourneyIngressRunScope? {
        switch source {
        case .hostApp, .sdkSystemGlobal:
            return nil
        case .sdkSystemRun(let scope, _),
             .journeySystem(let scope),
             .journeyAction(let scope, _, _):
            return scope
        }
    }

    private static func ingressRoute(
        _ event: JourneyIngressEvent
    ) -> ScreenLocalRouteRequest? {
        guard case .sdkSystemRun(_, let effectInvocationId) = event.source else {
            return nil
        }
        guard let effectInvocationId else {
            return .journey(eventName: event.name)
        }
        return .effectOutcome(
            effect: event.name.hasPrefix("$purchase_") ? "purchase" : "restore",
            invocationId: effectInvocationId,
            outcome: event.name
        )
    }

    private static func isValidIngressName(_ event: JourneyIngressEvent) -> Bool {
        switch event.source {
        case .hostApp, .journeyAction:
            return !event.name.isEmpty && !event.name.hasPrefix("$")
        case .sdkSystemGlobal:
            return sdkGlobalNames.contains(event.name)
        case .sdkSystemRun(_, let effectInvocationId):
            guard sdkRunNames.contains(event.name) else { return false }
            return effectInvocationId == nil || effectOutcomeNames.contains(event.name)
        case .journeySystem:
            return journeySystemNames.contains(event.name)
        }
    }

    private static let sdkGlobalNames: Set<String> = [
        "$identify", "$app_installed", "$app_updated", "$app_opened",
        "$app_backgrounded", "$feature_used",
    ]

    private static let sdkRunNames: Set<String> = [
        "$screen_shown", "$screen_dismissed", "$purchase_completed",
        "$purchase_failed", "$purchase_cancelled", "$purchase_pending",
        "$purchase_synced", "$restore_completed", "$restore_failed",
        "$restore_no_purchases", "$notifications_enabled",
        "$notifications_denied", "$permission_granted", "$permission_denied",
        "$tracking_authorized", "$tracking_denied",
    ]

    private static let effectOutcomeNames: Set<String> = [
        "$purchase_completed", "$purchase_failed", "$purchase_cancelled",
        "$restore_completed", "$restore_failed", "$restore_no_purchases",
    ]

    private static let journeySystemNames: Set<String> = [
        "$journey_enrolled", "$journey_transition", "$journey_milestone",
        "$journey_converted", "$journey_exited", "$journey_effect_requested",
        "$journey_effect_completed", "$journey_claimed", "$journey_handoff",
        "$journey_parked", "$journey_superseded", "$experience_shown",
        "$experience_dismissed", "$experience_purchased", "$experience_timed_out",
        "$experience_errored", "$experience_artifact_load_succeeded",
        "$experience_artifact_load_failed", "$experiment_exposure",
        "$experiment_exposure_fallback", "$experiment_exposure_error",
    ]
}

private actor ScreenEmissionRouterGateRegistry {
    private var gates: [String: ExperienceInteractiveOperationGate] = [:]
    private var sequenceLanes: [String: ScreenEmissionRouterSequenceLane] = [:]

    func gate(for key: String) -> ExperienceInteractiveOperationGate {
        if let existing = gates[key] { return existing }
        let gate = ExperienceInteractiveOperationGate()
        gates[key] = gate
        return gate
    }

    func sequenceLane(for journeyId: String) -> ScreenEmissionRouterSequenceLane {
        if let existing = sequenceLanes[journeyId] { return existing }
        let lane = ScreenEmissionRouterSequenceLane()
        sequenceLanes[journeyId] = lane
        return lane
    }
}

private actor ScreenEmissionRouterSequenceLane {
    typealias Operation = @Sendable () async -> ScreenEventRouterDrainResult

    private struct Pending: Sendable {
        let batch: ScreenEmissionBatch
        let process: Operation
        let reject: Operation
        var waiters: [CheckedContinuation<ScreenEventRouterDrainResult, Never>]
    }

    private var lastProcessedSequence: UInt64?
    private var initialized = false
    private var pending: [UInt64: Pending] = [:]
    private var processed: [UInt64: (invocationId: String, result: ScreenEventRouterDrainResult)] = [:]
    private var active: Pending?
    private var draining = false

    func submit(
        _ batch: ScreenEmissionBatch,
        durableLastProcessedSequence: UInt64?,
        durableResult: ScreenEventRouterDrainResult?,
        process: @escaping Operation,
        reject: @escaping Operation
    ) async -> ScreenEventRouterDrainResult {
        if !initialized {
            lastProcessedSequence = durableLastProcessedSequence
            initialized = true
        } else if let durableLastProcessedSequence {
            if let current = lastProcessedSequence {
                lastProcessedSequence = max(current, durableLastProcessedSequence)
            } else {
                lastProcessedSequence = durableLastProcessedSequence
            }
            pump()
        }
        if let previous = batch.previousCommittedBatchSequence,
           previous >= batch.batchSequence {
            return await reject()
        }
        if let completed = processed[batch.batchSequence] {
            return completed.invocationId == batch.invocationId
                ? completed.result
                : await reject()
        }
        if let durableResult {
            if let current = lastProcessedSequence {
                lastProcessedSequence = max(current, batch.batchSequence)
            } else {
                lastProcessedSequence = batch.batchSequence
            }
            processed[batch.batchSequence] = (
                invocationId: batch.invocationId,
                result: durableResult
            )
            pump()
            return durableResult
        }
        if let lastProcessedSequence,
           batch.batchSequence <= lastProcessedSequence {
            return await reject()
        }
        if var current = active, current.batch.batchSequence == batch.batchSequence {
            guard current.batch.invocationId == batch.invocationId else {
                return await reject()
            }
            return await withCheckedContinuation { continuation in
                current.waiters.append(continuation)
                active = current
            }
        }

        return await withCheckedContinuation { continuation in
            if var existing = pending[batch.batchSequence] {
                guard existing.batch.invocationId == batch.invocationId else {
                    Task { continuation.resume(returning: await reject()) }
                    return
                }
                existing.waiters.append(continuation)
                pending[batch.batchSequence] = existing
                return
            }
            pending[batch.batchSequence] = Pending(
                batch: batch,
                process: process,
                reject: reject,
                waiters: [continuation]
            )
            pump()
        }
    }

    private func pump() {
        guard !draining else { return }
        let next = pending.values
            .filter { $0.batch.previousCommittedBatchSequence == lastProcessedSequence }
            .min { $0.batch.batchSequence < $1.batch.batchSequence }
        guard let next else { return }
        pending.removeValue(forKey: next.batch.batchSequence)
        active = next
        draining = true
        Task {
            let result = await next.process()
            await self.finished(sequence: next.batch.batchSequence, result: result)
        }
    }

    private func finished(
        sequence: UInt64,
        result: ScreenEventRouterDrainResult
    ) async {
        guard let completed = active,
              completed.batch.batchSequence == sequence else { return }
        lastProcessedSequence = completed.batch.batchSequence
        processed[completed.batch.batchSequence] = (
            invocationId: completed.batch.invocationId,
            result: result
        )
        completed.waiters.forEach { $0.resume(returning: result) }

        let impossible = pending.values.filter { candidate in
            let previous = candidate.batch.previousCommittedBatchSequence
            return candidate.batch.batchSequence <= completed.batch.batchSequence
                || (previous != nil && previous! < completed.batch.batchSequence)
        }
        for candidate in impossible {
            pending.removeValue(forKey: candidate.batch.batchSequence)
            let rejected = await candidate.reject()
            candidate.waiters.forEach { $0.resume(returning: rejected) }
        }

        active = nil
        draining = false
        pump()
    }
}
#endif
