#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import XCTest
@testable import Nuxie

final class ScreenEmissionRouterTests: XCTestCase {
    func testResponseClassificationAndTrackingOnlyCustomerEventUseBatchFIFO() async {
        let harness = RouterHarness()
        let router = ScreenEmissionRouter(ports: await harness.ports())

        let result = await router.drain(batch(
            sequence: 0,
            emissions: [
                emission(
                    id: "response-1",
                    sequence: 0,
                    name: "$response_set",
                    payload: ["field": .string("reason"), "value": .string("price")]
                ),
                emission(id: "event-1", sequence: 1, name: "analytics_only"),
            ]
        ))

        XCTAssertEqual(result, ScreenEventRouterDrainResult(
            status: .drained,
            acceptedEmissionIds: ["response-1", "event-1"],
            skippedEmissionIds: [],
            reason: nil
        ))
        let trace = await harness.trace()
        let customerEventIds = await harness.customerEventIds()
        XCTAssertEqual(trace, ["response:response-1", "accept:event-1"])
        XCTAssertEqual(customerEventIds, ["event-1"])
        let acceptance = await harness.acceptance(at: 0)
        XCTAssertEqual(
            acceptance?.localRoute,
            .screen(screenId: "question", eventName: "analytics_only")
        )
        XCTAssertEqual(acceptance?.excludeExperienceId, "experience-1")
    }

    func testPayloadRejectionKeepsAcceptedCustomerEvent() async {
        let harness = RouterHarness()
        await harness.setRouteDisposition(.payloadInvalid(
            key: .screen(screenId: "question", eventName: "submit"),
            routeRevision: "route-r7"
        ))
        let router = ScreenEmissionRouter(ports: await harness.ports())

        let result = await router.drain(batch(
            sequence: 0,
            emissions: [emission(id: "event-1", sequence: 0, name: "submit")]
        ))

        XCTAssertEqual(result.status, .drained)
        let customerEventIds = await harness.customerEventIds()
        let routeEventIds = await harness.routeEventIds()
        let diagnosticCodes = await harness.diagnosticCodes()
        XCTAssertEqual(customerEventIds, ["event-1"])
        XCTAssertEqual(routeEventIds, [])
        XCTAssertEqual(diagnosticCodes, [.routePayloadInvalid])
    }

    func testReplayUsesExactlyOneCustomerEventAndDoesNotRunTheRouteTwice() async {
        let harness = RouterHarness()
        await harness.setRouteDisposition(.ready(AcceptedScreenLocalRoute(
            admissionId: "admission-1",
            key: .screen(screenId: "question", eventName: "submit"),
            routeRevision: "route-r1"
        )))
        let router = ScreenEmissionRouter(ports: await harness.ports())
        let input = batch(
            sequence: 0,
            emissions: [emission(id: "event-1", sequence: 0, name: "submit")]
        )

        _ = await router.drain(input)
        _ = await router.drain(input)

        let customerEventIds = await harness.customerEventIds()
        let routeEventIds = await harness.routeEventIds()
        XCTAssertEqual(customerEventIds, ["event-1"])
        XCTAssertEqual(routeEventIds, ["event-1"])
    }

    func testResponseRejectionAbortsTheCurrentEmissionAndTail() async {
        let harness = RouterHarness()
        await harness.setResponseResult(.rejected(message: "capture is not authorized"))
        let router = ScreenEmissionRouter(ports: await harness.ports())

        let result = await router.drain(batch(
            sequence: 0,
            emissions: [
                emission(id: "response-1", sequence: 0, name: "$response_set"),
                emission(id: "event-1", sequence: 1, name: "submit"),
            ]
        ))

        XCTAssertEqual(result, ScreenEventRouterDrainResult(
            status: .aborted,
            acceptedEmissionIds: [],
            skippedEmissionIds: ["response-1", "event-1"],
            reason: .responseRejected
        ))
        let customerEventIds = await harness.customerEventIds()
        XCTAssertEqual(customerEventIds, [])
    }

    func testPresentationChangeInvalidatesUnprocessedTail() async {
        let harness = RouterHarness()
        await harness.setRouteDisposition(.ready(AcceptedScreenLocalRoute(
            admissionId: "admission-1",
            key: .screen(screenId: "question", eventName: "next"),
            routeRevision: "route-r1"
        )))
        await harness.changePresentationAfterRoute()
        let router = ScreenEmissionRouter(ports: await harness.ports())

        let result = await router.drain(batch(
            sequence: 0,
            emissions: [
                emission(id: "event-1", sequence: 0, name: "next"),
                emission(id: "event-2", sequence: 1, name: "must_not_run"),
            ]
        ))

        XCTAssertEqual(result, ScreenEventRouterDrainResult(
            status: .invalidated,
            acceptedEmissionIds: ["event-1"],
            skippedEmissionIds: ["event-2"],
            reason: .presentationStale
        ))
        let customerEventIds = await harness.customerEventIds()
        XCTAssertEqual(customerEventIds, ["event-1"])
    }

    func testLaterSuccessfulBatchWaitsForItsCommittedPredecessor() async {
        let harness = RouterHarness()
        let router = ScreenEmissionRouter(ports: await harness.ports())

        async let later = router.drain(batch(
            sequence: 2,
            previousCommittedSequence: 1,
            emissions: [emission(id: "event-2", sequence: 2, name: "later")]
        ))
        await Task.yield()
        let beforePredecessor = await harness.customerEventIds()
        XCTAssertEqual(beforePredecessor, [])
        async let delayedEarlier = router.drain(batch(
            sequence: 1,
            previousCommittedSequence: nil,
            emissions: [emission(id: "event-1", sequence: 1, name: "earlier")]
        ))

        let earlierResult = await delayedEarlier
        let laterResult = await later
        XCTAssertEqual(earlierResult.status, .drained)
        XCTAssertEqual(laterResult.status, .drained)
        let customerEventIds = await harness.customerEventIds()
        XCTAssertEqual(customerEventIds, ["event-1", "event-2"])
    }

    func testStaleLaterBatchStillWaitsForItsValidCommittedPredecessor() async {
        let harness = RouterHarness()
        let router = ScreenEmissionRouter(ports: await harness.ports())
        async let stale = router.drain(staleBatch(
            sequence: 9,
            previousCommittedSequence: 1,
            emissions: [emission(id: "stale", sequence: 9, name: "stale")]
        ))
        async let valid = router.drain(batch(
            sequence: 1,
            previousCommittedSequence: nil,
            emissions: [emission(id: "valid", sequence: 1, name: "valid")]
        ))

        let validResult = await valid
        let staleResult = await stale
        XCTAssertEqual(staleResult.reason, .presentationStale)
        XCTAssertEqual(validResult.status, .drained)
        let customerEventIds = await harness.customerEventIds()
        XCTAssertEqual(customerEventIds, ["valid"])
    }

    func testEmptyScreenEventNameIsRejectedBeforeCustomerEventAcceptance() async {
        let harness = RouterHarness()
        let router = ScreenEmissionRouter(ports: await harness.ports())

        let result = await router.drain(batch(
            sequence: 0,
            emissions: [emission(id: "event-1", sequence: 0, name: "")]
        ))

        XCTAssertEqual(result, ScreenEventRouterDrainResult(
            status: .aborted,
            acceptedEmissionIds: [],
            skippedEmissionIds: ["event-1"],
            reason: .eventNameInvalid
        ))
        let customerEventIds = await harness.customerEventIds()
        XCTAssertEqual(customerEventIds, [])
    }

    func testConcurrentBatchesWaitForTheEarlierRouteBoundary() async {
        let gate = RouterTestGate()
        let harness = RouterHarness(routeGate: gate)
        await harness.setRouteDisposition(.ready(AcceptedScreenLocalRoute(
            admissionId: "admission-1",
            key: .screen(screenId: "question", eventName: "next"),
            routeRevision: "route-r1"
        )))
        let router = ScreenEmissionRouter(ports: await harness.ports())

        async let first = router.drain(batch(
            sequence: 0,
            emissions: [emission(id: "event-1", sequence: 0, name: "next")]
        ))
        await gate.waitUntilEntered()
        let secondTask = Task {
            await router.drain(batch(
                sequence: 1,
                previousCommittedSequence: 0,
                emissions: [emission(id: "event-2", sequence: 1, name: "later")]
            ))
        }
        try? await Task.sleep(nanoseconds: 30_000_000)
        let blockedTrace = await harness.trace()
        XCTAssertFalse(blockedTrace.contains("accept:event-2"))

        await gate.release()
        _ = await first
        _ = await secondTask.value
        let finalTrace = await harness.trace()
        XCTAssertEqual(finalTrace, [
            "accept:event-1",
            "route:event-1",
            "accept:event-2",
            "route:event-2",
        ])
    }

    func testReplayJoinsAnInFlightBatch() async {
        let gate = RouterTestGate()
        let harness = RouterHarness(routeGate: gate)
        await harness.setRouteDisposition(.ready(AcceptedScreenLocalRoute(
            admissionId: "admission-1",
            key: .screen(screenId: "question", eventName: "next"),
            routeRevision: "route-r1"
        )))
        let router = ScreenEmissionRouter(ports: await harness.ports())
        let input = batch(
            sequence: 0,
            emissions: [emission(id: "event-1", sequence: 0, name: "next")]
        )

        async let original = router.drain(input)
        await gate.waitUntilEntered()
        async let replay = router.drain(input)
        await gate.release()
        let originalResult = await original
        let replayResult = await replay

        XCTAssertEqual(replayResult, originalResult)
        let trace = await harness.trace()
        let skippedCount = await harness.skippedCount()
        XCTAssertEqual(trace.filter { $0 == "accept:event-1" }.count, 1)
        XCTAssertEqual(skippedCount, 0)
    }

    func testOnlyLiveUncorrelatedSDKRunIngressRequestsAJourneyRoute() async throws {
        let harness = RouterHarness()
        await harness.setRouteDisposition(.ready(AcceptedScreenLocalRoute(
            admissionId: "sdk-admission-1",
            key: .journey(eventName: "$screen_shown"),
            routeRevision: "route-r2"
        )))
        let router = ScreenEmissionRouter(ports: await harness.ports())
        let scope = JourneyIngressRunScope(
            experienceId: "experience-1",
            journeyId: "journey-1",
            executionOwnershipEpoch: 3,
            lifecycleGeneration: 4
        )

        let result = await router.acceptIngress(JourneyIngressEvent(
            id: "sdk-1",
            customerId: "customer-1",
            occurredAt: "2026-08-17T20:00:00.000-07:00",
            name: "$screen_shown",
            payload: [:],
            source: .sdkSystemRun(scope: scope, effectInvocationId: nil)
        ))
        _ = try result.get()

        let acceptance = await harness.acceptance(at: 0)
        let routeEventIds = await harness.routeEventIds()
        XCTAssertEqual(
            acceptance?.localRoute,
            .journey(eventName: "$screen_shown")
        )
        XCTAssertEqual(routeEventIds, ["sdk-1"])

        let stale = await router.acceptIngress(JourneyIngressEvent(
            id: "sdk-stale",
            customerId: "customer-1",
            occurredAt: "2026-08-17T20:00:01.000-07:00",
            name: "$screen_shown",
            payload: [:],
            source: .sdkSystemRun(
                scope: JourneyIngressRunScope(
                    experienceId: "experience-1",
                    journeyId: "journey-1",
                    executionOwnershipEpoch: 99,
                    lifecycleGeneration: 4
                ),
                effectInvocationId: nil
            )
        ))
        XCTAssertEqual(stale.failure, .ownershipStale)
        let customerEventIds = await harness.customerEventIds()
        XCTAssertEqual(customerEventIds, ["sdk-1"])
    }

    func testCausalityRejectsCyclesAndBranchesBeyondThirtyTwoHops() throws {
        let source = ExperienceEventCausality(
            chainId: "chain-1",
            parentEventId: "entry-1",
            visitedExperienceIds: ["experience-1"],
            hopCount: 1
        )

        XCTAssertEqual(
            extendExperienceAdmissionCausality(
                source,
                targetExperienceId: "experience-1"
            ).failure,
            .experienceCycle
        )
        XCTAssertEqual(
            extendExperienceAdmissionCausality(
                ExperienceEventCausality(
                    chainId: source.chainId,
                    parentEventId: source.parentEventId,
                    visitedExperienceIds: source.visitedExperienceIds,
                    hopCount: 32
                ),
                targetExperienceId: "experience-2"
            ).failure,
            .experienceHopLimit
        )
        XCTAssertEqual(
            try extendExperienceAdmissionCausality(
                source,
                targetExperienceId: "experience-2"
            ).get(),
            ExperienceEventCausality(
                chainId: "chain-1",
                parentEventId: "entry-1",
                visitedExperienceIds: ["experience-1", "experience-2"],
                hopCount: 2
            )
        )
    }

    func testRunScopedIngressRejectsADifferentCustomer() async {
        let harness = RouterHarness()
        let router = ScreenEmissionRouter(ports: await harness.ports())

        let result = await router.acceptIngress(JourneyIngressEvent(
            id: "sdk-1",
            customerId: "customer-2",
            occurredAt: "2026-08-17T20:00:00.000-07:00",
            name: "$screen_shown",
            payload: [:],
            source: .sdkSystemRun(
                scope: JourneyIngressRunScope(
                    experienceId: "experience-1",
                    journeyId: "journey-1",
                    executionOwnershipEpoch: 3,
                    lifecycleGeneration: 4
                ),
                effectInvocationId: nil
            )
        ))

        XCTAssertEqual(result.failure, .runIdentityMismatch)
        let customerEventIds = await harness.customerEventIds()
        XCTAssertEqual(customerEventIds, [])
    }

    private func batch(
        sequence: UInt64,
        previousCommittedSequence: UInt64? = nil,
        emissions: [ScreenEmission]
    ) -> ScreenEmissionBatch {
        ScreenEmissionBatch(
            journeyId: "journey-1",
            executionOwnershipEpoch: 3,
            lifecycleGeneration: 4,
            presentationEpoch: 5,
            batchSequence: sequence,
            previousCommittedBatchSequence: previousCommittedSequence,
            invocationId: "invocation-\(sequence)",
            source: ScreenEmissionSource(
                screenId: "question",
                actionId: "submit",
                componentId: "survey-button",
                instanceId: "survey-button-2"
            ),
            emissions: emissions
        )
    }

    private func emission(
        id: String,
        sequence: UInt64,
        name: String,
        payload: [String: ScreenEmissionValue] = [:]
    ) -> ScreenEmission {
        ScreenEmission(
            id: id,
            sequence: sequence,
            occurredAt: "2026-08-17T20:00:0\(sequence).000-07:00",
            name: name,
            payload: payload
        )
    }

    private func staleBatch(
        sequence: UInt64,
        previousCommittedSequence: UInt64?,
        emissions: [ScreenEmission]
    ) -> ScreenEmissionBatch {
        let current = batch(
            sequence: sequence,
            previousCommittedSequence: previousCommittedSequence,
            emissions: emissions
        )
        return ScreenEmissionBatch(
            journeyId: current.journeyId,
            executionOwnershipEpoch: current.executionOwnershipEpoch,
            lifecycleGeneration: current.lifecycleGeneration,
            presentationEpoch: current.presentationEpoch + 1,
            batchSequence: current.batchSequence,
            previousCommittedBatchSequence: current.previousCommittedBatchSequence,
            invocationId: current.invocationId,
            source: current.source,
            emissions: current.emissions
        )
    }
}

private actor RouterHarness {
    private var run = ScreenEventRouterRun(
        journeyId: "journey-1",
        experienceId: "experience-1",
        customerId: "customer-1",
        executionOwnershipEpoch: 3,
        lifecycleGeneration: 4,
        presentationEpoch: 5,
        terminal: false,
        causality: ExperienceEventCausality(
            chainId: "chain-1",
            parentEventId: "entry-1",
            visitedExperienceIds: ["experience-1"],
            hopCount: 1
        )
    )
    private var recordedTrace: [String] = []
    private var events: [String: ScreenCustomerEvent] = [:]
    private var acceptances: [ScreenCustomerEventAcceptance] = []
    private var routedEvents: [ScreenCustomerEvent] = []
    private var diagnostics: [ScreenEventRouterDiagnostic] = []
    private var skipped: [ScreenEventRouterSkippedTail] = []
    private var routeDisposition: ScreenLocalRouteDisposition = .none
    private var responseResult: ScreenResponseEmissionResult = .accepted
    private var shouldChangePresentation = false
    private let routeGate: RouterTestGate?

    init(routeGate: RouterTestGate? = nil) {
        self.routeGate = routeGate
    }

    func ports() -> ScreenEmissionRouterPorts {
        ScreenEmissionRouterPorts(
            createCausalityId: { "new-chain" },
            readRun: { [self] _ in await currentRun() },
            applyResponse: { [self] _, _, emission in
                await recordResponse(emission)
                return await currentResponseResult()
            },
            acceptCustomerEvent: { [self] acceptance in
                await accept(acceptance)
            },
            runRouteToStableBoundary: { [self] _, event in
                await route(event)
            },
            recordDiagnostic: { [self] diagnostic in
                await record(diagnostic)
            },
            recordSkippedTail: { [self] tail in
                await record(tail)
            }
        )
    }

    func setRouteDisposition(_ value: ScreenLocalRouteDisposition) {
        routeDisposition = value
    }

    func changePresentationAfterRoute() {
        shouldChangePresentation = true
    }

    func setResponseResult(_ value: ScreenResponseEmissionResult) {
        responseResult = value
    }

    func trace() -> [String] { recordedTrace }
    func customerEventIds() -> [String] { Array(events.keys).sorted() }
    func routeEventIds() -> [String] { routedEvents.map(\.id) }
    func diagnosticCodes() -> [ScreenEventRouterDiagnosticCode] { diagnostics.map(\.code) }
    func skippedCount() -> Int { skipped.count }
    func acceptance(at index: Int) -> ScreenCustomerEventAcceptance? {
        acceptances.indices.contains(index) ? acceptances[index] : nil
    }

    private func currentRun() -> ScreenEventRouterRun { run }
    private func currentResponseResult() -> ScreenResponseEmissionResult { responseResult }

    private func recordResponse(_ emission: ScreenEmission) {
        recordedTrace.append("response:\(emission.id)")
    }

    private func accept(
        _ acceptance: ScreenCustomerEventAcceptance
    ) -> ScreenCustomerEventAdmission {
        recordedTrace.append("accept:\(acceptance.event.id)")
        acceptances.append(acceptance)
        if events[acceptance.event.id] != nil {
            return ScreenCustomerEventAdmission(
                disposition: .duplicate,
                localRoute: .alreadyProcessed
            )
        }
        events[acceptance.event.id] = acceptance.event
        return ScreenCustomerEventAdmission(
            disposition: .accepted,
            localRoute: acceptance.localRoute == nil ? .none : routeDisposition
        )
    }

    private func route(_ event: ScreenCustomerEvent) async {
        recordedTrace.append("route:\(event.id)")
        routedEvents.append(event)
        if let routeGate { await routeGate.block() }
        if shouldChangePresentation {
            run = ScreenEventRouterRun(
                journeyId: run.journeyId,
                experienceId: run.experienceId,
                customerId: run.customerId,
                executionOwnershipEpoch: run.executionOwnershipEpoch,
                lifecycleGeneration: run.lifecycleGeneration,
                presentationEpoch: run.presentationEpoch + 1,
                terminal: run.terminal,
                causality: run.causality
            )
        }
    }

    private func record(_ diagnostic: ScreenEventRouterDiagnostic) {
        diagnostics.append(diagnostic)
    }

    private func record(_ tail: ScreenEventRouterSkippedTail) {
        skipped.append(tail)
    }
}

private actor RouterTestGate {
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func block() async {
        entered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters.removeAll()
        if released { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private extension Result {
    var failure: Failure? {
        guard case .failure(let error) = self else { return nil }
        return error
    }
}
#endif
