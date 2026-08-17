import Foundation
import Quick
import Nimble
import NuxieRuntime
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

// @unchecked Sendable: `_events` is only accessed under `lock`.
private final class OrderingRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [String] = []

    func append(_ event: String) {
        lock.withLock {
            _events.append(event)
        }
    }

    func clear() {
        lock.withLock {
            _events.removeAll()
        }
    }

    var events: [String] {
        lock.withLock { _events }
    }
}

private final class OrderingJourneyStore: MockJourneyStore, @unchecked Sendable {
    private let recorder: OrderingRecorder

    init(recorder: OrderingRecorder) {
        self.recorder = recorder
        super.init()
    }

    override func recordCompletion(_ record: JourneyCompletionRecord) throws {
        try super.recordCompletion(record)
        recorder.append("complete:\(record.experienceId)")
    }
}

private final class RejectingCheckpointJourneyStore: MockJourneyStore, @unchecked Sendable {
    enum RejectedCheckpoint {
        case presentation
        case pause
    }

    let rejected: RejectedCheckpoint

    init(rejected: RejectedCheckpoint) {
        self.rejected = rejected
        super.init()
    }

    override func saveJourney(_ journey: JourneySnapshot) throws {
        switch rejected {
        case .presentation where journey.executionState.pendingPresentation != nil:
            throw NSError(domain: "RejectedCheckpoint", code: 1)
        case .pause where journey.executionState.pendingAction != nil:
            throw NSError(domain: "RejectedCheckpoint", code: 2)
        default:
            try super.saveJourney(journey)
        }
    }
}

private class OrderingExperiencePresentationService: MockExperiencePresentationService, @unchecked Sendable {
    private let recorder: OrderingRecorder

    init(recorder: OrderingRecorder) {
        self.recorder = recorder
        super.init()
    }

    @discardableResult
    @MainActor
    override func presentExperience(
        _ flowId: String,
        from journey: Journey?,
        runtimeDelegate: ExperienceRuntimeDelegate?
    ) async throws -> ExperienceViewController {
        return try await presentExperience(
            flowId,
            from: journey,
            runtimeDelegate: runtimeDelegate,
            colorSchemeMode: .light
        )
    }

    @discardableResult
    @MainActor
    override func presentExperience(
        _ flowId: String,
        from journey: Journey?,
        runtimeDelegate: ExperienceRuntimeDelegate?,
        colorSchemeMode: ExperienceColorSchemeMode
    ) async throws -> ExperienceViewController {
        recorder.append("present:\(flowId)")
        return try await super.presentExperience(
            flowId,
            from: journey,
            runtimeDelegate: runtimeDelegate,
            colorSchemeMode: colorSchemeMode
        )
    }
}

private final class DismissingOrderingExperiencePresentationService: OrderingExperiencePresentationService, @unchecked Sendable {
    private let dismissalRecorder: OrderingRecorder

    override init(recorder: OrderingRecorder) {
        self.dismissalRecorder = recorder
        super.init(recorder: recorder)
    }

    @discardableResult
    @MainActor
    override func presentExperience(
        _ flowId: String,
        from journey: Journey?,
        runtimeDelegate: ExperienceRuntimeDelegate?,
        colorSchemeMode: ExperienceColorSchemeMode
    ) async throws -> ExperienceViewController {
        if isPresentingExperience {
            await dismissCurrentExperience()
            dismissalRecorder.append("dismiss-before-present")
        }
        return try await super.presentExperience(
            flowId,
            from: journey,
            runtimeDelegate: runtimeDelegate,
            colorSchemeMode: colorSchemeMode
        )
    }
}

private final class ReentrantRuntimeReadyExperiencePresentationService: MockExperiencePresentationService, @unchecked Sendable {
    private let emitsStaleLifecycleAfterReplacement: Bool
    @MainActor private(set) var presentedControllers: [ExperienceViewController] = []
    @MainActor private(set) var capturedTraceTokens: [ExperiencePresentationTraceToken?] = []

    init(emitsStaleLifecycleAfterReplacement: Bool = false) {
        self.emitsStaleLifecycleAfterReplacement = emitsStaleLifecycleAfterReplacement
        super.init()
    }

    @discardableResult
    @MainActor
    override func presentExperience(
        _ flowId: String,
        from journey: Journey?,
        runtimeDelegate: ExperienceRuntimeDelegate?,
        colorSchemeMode: ExperienceColorSchemeMode
    ) async throws -> ExperienceViewController {
        let scopedTraceDelegate = runtimeDelegate as? any ExperiencePresentationScopedTraceDelegate
        capturedTraceTokens.append(scopedTraceDelegate?.activePresentationTraceToken)
        let controller = try await super.presentExperience(
            flowId,
            from: journey,
            runtimeDelegate: runtimeDelegate,
            colorSchemeMode: colorSchemeMode
        )
        presentedControllers.append(controller)
        guard presentExperienceCallCount == 1 else {
            if emitsStaleLifecycleAfterReplacement {
                let staleToken = capturedTraceTokens[0]
                scopedTraceDelegate?.experienceViewControllerDidBecomeReady(
                    presentedControllers[0],
                    traceToken: staleToken
                )
                scopedTraceDelegate?.experienceViewControllerDidPresentShell(
                    presentedControllers[0],
                    traceToken: staleToken
                )
                scopedTraceDelegate?.experienceViewControllerDidReveal(
                    presentedControllers[0],
                    traceToken: staleToken
                )
                scopedTraceDelegate?.experienceViewController(
                    presentedControllers[0],
                    didPresentDrawable: ExperienceRuntimePresentedDrawable(
                        presentedTime: ExperiencePresentationTimestamp.monotonicNow(),
                        pixelWidth: 1,
                        pixelHeight: 1,
                        drawCalls: 1,
                        provenance: .injectedTestObserver
                    ),
                    screenId: "stale",
                    frameNumber: 1,
                    traceToken: staleToken
                )
                scopedTraceDelegate?.experienceViewController(
                    presentedControllers[0],
                    didAcceptPointerInput: ExperienceRuntimeAcceptedPointerInput(eventCount: 1),
                    screenId: "stale",
                    traceToken: staleToken
                )
                scopedTraceDelegate?.experienceViewControllerDidFinishPresentation(
                    presentedControllers[0],
                    traceToken: staleToken
                )
            }
            return controller
        }

        scopedTraceDelegate?.experienceViewControllerDidBecomeReady(
            controller,
            traceToken: capturedTraceTokens[0]
        )

        // Keep the first presentation suspended long enough for the ready
        // callback to synchronously re-enter JourneyService's cached-runtime
        // show-screen path. Before the regression fix, trace setup in that
        // path self-awaited the forwarding task and no second presentation
        // could begin.
        try? await Task.sleep(nanoseconds: 500_000_000)
        return controller
    }
}

private final class CachedFastActivationPresentationService:
    MockExperiencePresentationService,
    @unchecked Sendable
{
    @MainActor private(set) var preactivationAccepted: Bool?
    @MainActor var afterPreactivation: (() -> Void)?
    @MainActor var failAfterPreactivation = false

    @discardableResult
    @MainActor
    override func presentExperience(
        _ experienceVersionId: String,
        from journey: Journey?,
        runtimeDelegate: ExperienceRuntimeDelegate?,
        colorSchemeMode: ExperienceColorSchemeMode,
        commit: JourneyPendingPresentation
    ) async throws -> ExperienceViewController {
        let controller = try await super.presentExperience(
            experienceVersionId,
            from: journey,
            runtimeDelegate: runtimeDelegate,
            colorSchemeMode: colorSchemeMode,
            commit: commit
        )
        preactivationAccepted = await runtimeDelegate?
            .experienceViewControllerWillActivateInitialScreen(controller)
        afterPreactivation?()
        if failAfterPreactivation {
            throw ExperiencePresentationError.presentationSuperseded
        }
        return controller
    }
}

private final class SuspendedFailingExperiencePresentationService:
    MockExperiencePresentationService,
    @unchecked Sendable
{
    @MainActor private(set) weak var capturedRuntimeDelegate: ExperienceRuntimeDelegate?
    @MainActor private var failureContinuation: CheckedContinuation<Void, Never>?

    @discardableResult
    @MainActor
    override func presentExperience(
        _ flowId: String,
        from journey: Journey?,
        runtimeDelegate: ExperienceRuntimeDelegate?,
        colorSchemeMode: ExperienceColorSchemeMode
    ) async throws -> ExperienceViewController {
        capturedRuntimeDelegate = runtimeDelegate
        await withCheckedContinuation { continuation in
            failureContinuation = continuation
        }
        throw ExperiencePresentationError.noActiveScene
    }

    @MainActor
    func resumeWithFailure() {
        failureContinuation?.resume()
        failureContinuation = nil
    }
}

private final class OrderingMockExperienceViewController: MockExperienceViewController {
    private let recorder: OrderingRecorder

    init(mockExperienceVersionId: String, recorder: OrderingRecorder) {
        self.recorder = recorder
        super.init(mockExperienceVersionId: mockExperienceVersionId)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func navigate(to screenId: String, transition: Any? = nil) {
        recorder.append("navigate:\(screenId)")
    }
}

private final class UnsupportedTrackingAuthorizationHandler: TrackingAuthorizationHandling {
    func authorizationStatus() -> TrackingAuthorizationStatus {
        .unsupported
    }

    func requestAuthorization() async -> TrackingAuthorizationStatus {
        .unsupported
    }
}

private final class DelayedTrackingAuthorizationHandler: TrackingAuthorizationHandling {
    let delayNanoseconds: UInt64
    let result: TrackingAuthorizationStatus

    init(delayNanoseconds: UInt64, result: TrackingAuthorizationStatus) {
        self.delayNanoseconds = delayNanoseconds
        self.result = result
    }

    func authorizationStatus() -> TrackingAuthorizationStatus {
        .notDetermined
    }

    func requestAuthorization() async -> TrackingAuthorizationStatus {
        try? await Task.sleep(nanoseconds: delayNanoseconds)
        return result
    }
}

final class JourneyServiceExitTimingTests: AsyncSpec {
    override class func spec() {
        // nonisolated(unsafe): Quick runs beforeEach and each example strictly
        // serially, so these spec-level fixtures are never accessed
        // concurrently despite being captured by @MainActor example closures.
        nonisolated(unsafe) var mocks: MockFactory!
        nonisolated(unsafe) var journeyStore: MockJourneyStore!
        nonisolated(unsafe) var service: JourneyService!
        nonisolated(unsafe) var controller: MockExperienceViewController!

        let distinctId = "user_1"
        let flowId = "flow-exit-timing"
        let experienceId = "camp-exit-timing"

        func makeGatePlanResponse(
            decision: String,
            flowId: String? = nil,
            featureId: String? = nil,
            policy: String? = nil,
            requiredBalance: Int? = nil
        ) -> EventResponse {
            var gatePayload: [String: Any] = ["decision": decision]
            if let flowId {
                gatePayload["flowId"] = flowId
            }
            if let featureId {
                gatePayload["featureId"] = featureId
            }
            if let policy {
                gatePayload["policy"] = policy
            }
            if let requiredBalance {
                gatePayload["requiredBalance"] = requiredBalance
            }

            return EventResponse(
                status: "ok",
                payload: ["gate": AnyCodable(gatePayload)],
                customer: nil,
                eventId: nil,
                message: nil,
                featuresMatched: nil,
                usage: nil,
                journey: nil,
            )
        }

        func makeExperience(
            id: String = experienceId,
            flowId: String = flowId,
            trigger: ExperienceTrigger = .event(EventTriggerConfig(eventName: "paywall_trigger", condition: nil)),
            goal: GoalConfig?,
            exitPolicy: ExitPolicy?
        ) -> Experience {
            Experience(
                id: id,
                versionId: flowId,
                name: "Exit Timing Experience",
                reentry: .everyTime,
                publishedAt: Date().ISO8601Format(),
                trigger: trigger,
                goal: goal,
                exitPolicy: exitPolicy,
                conversionAnchor: nil,
                experienceType: nil
            )
        }

        func makeLoadedExperience(
            flowId: String = flowId,
            entryActions: [JourneyAction] = [],
            handlers: JourneyHandlerMap = [:]
        ) -> Experience {
            var resolvedHandlers = handlers
            if !entryActions.isEmpty {
                resolvedHandlers[JourneyDocument.journeyEventHostKey, default: []].append(
                    JourneyEventHandler(
                        id: "start",
                        eventName: SystemEventNames.appOpened,
                        enabled: true,
                        actions: entryActions
                    )
                )
            }
            var events: JourneyEventMap = [:]
            for (hostId, hostHandlers) in resolvedHandlers {
                for handler in hostHandlers {
                    events[hostId, default: []].append(
                        EventDeclaration(
                            id: "\(handler.id):event",
                            eventName: handler.eventName
                        )
                    )
                }
            }
            let screens = JourneyDocument(
                screens: [
                    JourneyScreen(
                        id: "screen-1",
                        defaultViewModelName: nil,
                        defaultInstanceId: nil
                    )
                ],
                events: events,
                handlers: resolvedHandlers,
                viewModelValues: nil
            )
            return Experience.test(
                journey: screens,
                versionId: flowId,
                products: []
            )
        }

        func makeSignedLoadedExperience(
            entryActions: [JourneyAction],
            handlers: JourneyHandlerMap = [:],
            goal: GoalConfig? = nil,
            exitPolicy: ExitPolicy? = nil
        ) -> Experience {
            let content = makeLoadedExperience(
                entryActions: entryActions,
                handlers: handlers
            )
            let identity = ExperienceReleaseIdentityV2(
                appId: "test-app",
                environment: "test",
                experienceId: experienceId,
                experienceVersionId: flowId,
                buildId: "signed-build",
                versionNumber: 1,
                publishedAt: "2026-08-13T00:00:00.000Z",
                publishedAtSeq: 1
            )
            let behavior = ExperienceBehaviorDefinition(
                reference: .init(experienceId: experienceId, versionId: flowId),
                buildId: identity.buildId,
                artifactContentHash: String(repeating: "a", count: 64),
                name: "Signed pre-mount",
                reentry: .everyTime,
                publishedAt: identity.publishedAt,
                trigger: .event(.init(eventName: "paywall_trigger", condition: nil)),
                goal: goal,
                exitPolicy: exitPolicy,
                conversionAnchor: nil,
                timeLimitSeconds: nil,
                experienceType: nil,
                presentationStyle: .fullScreen
            )
            return Experience(
                behavior: behavior,
                journey: content.journey,
                assetBaseURL: URL(string: "https://assets.nuxie.ai/")!,
                authenticatedReleaseID: .init(
                    identity: identity,
                    descriptorSHA256: String(repeating: "b", count: 64)
                )
            )
        }

        func pressHandlers(_ actions: [JourneyAction]) -> JourneyHandlerMap {
            [
                "screen-1": [
                    JourneyEventHandler(
                        id: "press-host-action",
                        eventName: "__nuxie_test_press",
                        actions: actions
                    )
                ]
            ]
        }

        func primeProfile(experience: Experience, package: Experience) async {
            await primeProfile(experiences: [experience], packages: [package])
        }

        func primeProfile(experiences: [Experience], packages: [Experience]) async {
            mocks.identityService.setDistinctId(distinctId)
            let references = experiences.map {
                ExperienceReference(experienceId: $0.id, versionId: $0.versionId)
            }
            mocks.profileService.effectiveExperienceReferences = references
            mocks.profileService.activeExperienceReferences = references
            let metadataByVersion = Dictionary(
                uniqueKeysWithValues: experiences.map { ($0.versionId, $0) }
            )
            for package in packages {
                guard let metadata = metadataByVersion[package.versionId] else { continue }
                mocks.experienceService.mockExperiences[package.versionId] =
                    package.authenticatedReleaseID == nil
                    ? Experience(
                        metadata: metadata,
                        journey: package.journey,
                        assetBaseURL: package.assetBaseURL
                    )
                    : package
            }
            mocks.profileService.setProfileResponse(
                ResponseBuilders.buildProfileResponse(
                    experiences: experiences
                )
            )
            _ = try? await mocks.profileService.refetchProfile(distinctId: distinctId)
        }

        func startJourney() async -> Journey {
            let startEvent = NuxieEvent(
                id: "evt_origin",
                name: "paywall_trigger",
                distinctId: distinctId
            )
            let results = await service.handleEventForTrigger(startEvent)
            return results.compactMap { result -> Journey? in
                if case .started(let journey) = result {
                    return journey
                }
                return nil
            }.first!
        }

        func convertedAt(of journey: Journey?) async -> Date? {
            await journey?.snapshot().convertedAt
        }

        beforeEach { @MainActor in
            mocks = MockFactory.shared
            mocks.dateProvider.setCurrentDate(Date())

            journeyStore = MockJourneyStore()
            service = mocks.makeJourneyService(journeyStore: journeyStore)

            controller = MockExperienceViewController(mockExperienceVersionId: flowId)
            mocks.experiencePresentationService.defaultMockViewController = controller
        }

        describe("journey start persistence") {
            it("rebinds restored presentation evidence to the current qualification attempt") {
                mocks.identityService.setDistinctId(distinctId)
                let presentationTrace = InMemoryExperiencePresentationTrace()
                let restoredAttempt = ExperiencePresentationAttempt(
                    id: "attempt-restored-run",
                    triggerEvent: "$qualification_present",
                    startedAt: Date(timeIntervalSince1970: 2),
                    startedAtMonotonicTime: 2
                )
                service = mocks.makeJourneyService(
                    journeyStore: journeyStore,
                    presentationTrace: presentationTrace,
                    restoredPresentationAttempt: restoredAttempt
                )
                let experience = makeExperience(goal: nil, exitPolicy: nil)
                let journey = Journey(
                    experience: experience,
                    distinctId: distinctId,
                    now: Date(timeIntervalSince1970: 1)
                )
                let interruptedAttempt = ExperiencePresentationAttempt(
                    id: "attempt-interrupted-run",
                    triggerEvent: "$qualification_present",
                    startedAt: Date(timeIntervalSince1970: 1),
                    startedAtMonotonicTime: 1
                )
                await ExperiencePresentationAttemptJourneyContext.store(
                    interruptedAttempt,
                    in: journey,
                    at: Date(timeIntervalSince1970: 1)
                )
                try journeyStore.saveJourney(await journey.snapshot())

                await service.initialize()

                let restored = await service.getActiveJourneys(for: distinctId)
                expect(restored).to(haveCount(1))
                guard let restoredJourney = restored.first else {
                    fail("expected restored journey")
                    return
                }
                let storedAttempt = await ExperiencePresentationAttemptJourneyContext.load(
                    from: restoredJourney
                )
                expect(storedAttempt).to(equal(restoredAttempt))
                expect(presentationTrace.events(for: restoredAttempt.id).map(\.stage))
                    .to(equal([.journeyMatched(journeyId: journey.id)]))
                expect(presentationTrace.events(for: interruptedAttempt.id)).to(beEmpty())
            }

            it("retries a restored signed presentation once its profile authority is ready") { @MainActor in
                let flow = makeSignedLoadedExperience(entryActions: [
                    .navigate(NavigateAction(screenId: "screen-1", transition: nil))
                ])
                await primeProfile(experience: flow, package: flow)
                await service.initialize()
                guard let journey = await service.startJourney(for: flow, distinctId: distinctId) else {
                    fail("expected signed journey")
                    return
                }
                let interruptedState = await journey.snapshot()
                expect(interruptedState.executionState.pendingPresentation).toNot(beNil())

                let restoredPresentation = MockExperiencePresentationService()
                restoredPresentation.defaultMockViewController = MockExperienceViewController(
                    mockExperienceVersionId: flow.versionId
                )
                service = mocks.makeJourneyService(
                    journeyStore: journeyStore,
                    experiencePresentation: restoredPresentation
                )

                await service.initialize()

                await expect {
                    restoredPresentation.presentedExperiences.map(\.experienceVersionId)
                }.toEventually(equal([flow.versionId]), timeout: .seconds(2))
            }

            it("does not restore another identity's signed presentation") { @MainActor in
                let oldDistinctId = "user-before-identify"
                let flow = makeSignedLoadedExperience(entryActions: [
                    .navigate(NavigateAction(screenId: "screen-1", transition: nil))
                ])
                await primeProfile(experience: flow, package: flow)
                await service.initialize()
                guard await service.startJourney(for: flow, distinctId: oldDistinctId) != nil else {
                    fail("expected old identity journey")
                    return
                }

                let restoredPresentation = MockExperiencePresentationService()
                restoredPresentation.defaultMockViewController = MockExperienceViewController(
                    mockExperienceVersionId: flow.versionId
                )
                mocks.identityService.setDistinctId(distinctId)
                service = mocks.makeJourneyService(
                    journeyStore: journeyStore,
                    experiencePresentation: restoredPresentation
                )

                await service.initialize()

                expect(restoredPresentation.presentExperienceCallCount).to(equal(0))
                let oldJourneys = await service.getActiveJourneys(for: oldDistinctId)
                expect(oldJourneys).to(haveCount(1))
            }

            it("retries a restored signed presentation after identify loads its owner") { @MainActor in
                let anonymousDistinctId = "anonymous-before-identify"
                let flow = makeSignedLoadedExperience(entryActions: [
                    .navigate(NavigateAction(screenId: "screen-1", transition: nil))
                ])
                await primeProfile(experience: flow, package: flow)
                await service.initialize()
                guard let journey = await service.startJourney(for: flow, distinctId: distinctId) else {
                    fail("expected identified journey")
                    return
                }
                let interruptedState = await journey.snapshot()
                expect(interruptedState.executionState.pendingPresentation).toNot(beNil())

                let restoredPresentation = MockExperiencePresentationService()
                restoredPresentation.defaultMockViewController = MockExperienceViewController(
                    mockExperienceVersionId: flow.versionId
                )
                mocks.identityService.setDistinctId(anonymousDistinctId)
                service = mocks.makeJourneyService(
                    journeyStore: journeyStore,
                    experiencePresentation: restoredPresentation
                )
                await service.initialize()
                expect(restoredPresentation.presentExperienceCallCount).to(equal(0))

                mocks.identityService.setDistinctId(distinctId)
                await service.handleUserChange(
                    from: anonymousDistinctId,
                    to: distinctId
                )

                await expect {
                    restoredPresentation.presentedExperiences.map(\.experienceVersionId)
                }.toEventually(equal([flow.versionId]), timeout: .seconds(2))
            }

            it("retries a durable presentation on an existing runner after the scene becomes ready") { @MainActor in
                let flow = makeSignedLoadedExperience(entryActions: [
                    .navigate(NavigateAction(screenId: "screen-1", transition: nil))
                ])
                await primeProfile(experience: flow, package: flow)
                await service.initialize()
                mocks.experiencePresentationService.shouldFailPresentation = true
                guard let journey = await service.startJourney(for: flow, distinctId: distinctId) else {
                    fail("expected signed journey")
                    return
                }
                let interruptedState = await journey.snapshot()
                expect(interruptedState.executionState.pendingPresentation).toNot(beNil())
                expect(mocks.experiencePresentationService.presentExperienceCallCount).to(equal(1))

                mocks.experiencePresentationService.shouldFailPresentation = false
                await service.onAppBecameActive()

                expect(mocks.experiencePresentationService.presentExperienceCallCount).to(equal(2))
                expect(mocks.experiencePresentationService.presentedExperiences.map(\.experienceVersionId))
                    .to(equal([flow.versionId]))
            }

            it("does not retry an interrupted presentation inside its trigger route") { @MainActor in
                let flow = makeSignedLoadedExperience(entryActions: [
                    .navigate(NavigateAction(screenId: "screen-1", transition: nil))
                ])
                await primeProfile(experience: flow, package: flow)
                await service.initialize()
                mocks.experiencePresentationService.shouldFailPresentation = true

                _ = await service.handleEventForTrigger(
                    NuxieEvent(
                        id: "evt-interrupted-presentation",
                        name: "paywall_trigger",
                        distinctId: distinctId
                    )
                )

                expect(mocks.experiencePresentationService.presentExperienceCallCount)
                    .to(equal(1))
            }

            it("accepts cached runtime preactivation before presentation returns") { @MainActor in
                let presentation = CachedFastActivationPresentationService()
                service = mocks.makeJourneyService(
                    journeyStore: journeyStore,
                    experiencePresentation: presentation
                )
                let metadata = makeExperience(goal: nil, exitPolicy: nil)
                let signed = makeSignedLoadedExperience(entryActions: [
                    .navigate(.init(screenId: "screen-1", transition: nil))
                ])
                await primeProfile(experience: metadata, package: signed)
                await service.initialize()

                _ = await service.handleEventForTrigger(
                    NuxieEvent(
                        id: "evt-cached-fast-activate",
                        name: "paywall_trigger",
                        distinctId: distinctId
                    ),
                    presentationAttempt: nil
                )

                expect(presentation.preactivationAccepted).to(beTrue())
                await service.shutdown()
            }

            it("rejects and dismisses a presentation whose signed commit changed before activation") { @MainActor in
                let metadata = makeExperience(goal: nil, exitPolicy: nil)
                let signed = makeSignedLoadedExperience(entryActions: [
                    .navigate(.init(screenId: "screen-1", transition: nil))
                ])
                await primeProfile(experience: metadata, package: signed)
                await service.initialize()
                _ = await service.handleEventForTrigger(
                    NuxieEvent(
                        id: "evt-stale-before-ready",
                        name: "paywall_trigger",
                        distinctId: distinctId
                    ),
                    presentationAttempt: nil
                )
                let activeBeforeReplacement = await service.getActiveJourneys(for: distinctId)
                guard let staleJourney = activeBeforeReplacement.first else {
                    fail("expected active stale journey")
                    return
                }
                mocks.experienceService.presentationCommitIsValid = false

                let accepted = await mocks.experiencePresentationService
                    .currentRuntimeDelegate?
                    .experienceViewControllerWillActivateInitialScreen(controller)

                expect(accepted).to(beFalse())
                expect(mocks.experiencePresentationService.dismissCurrentExperienceCallCount)
                    .to(equal(1))
                let activeAfterReplacement = await service.getActiveJourneys(for: distinctId)
                expect(activeAfterReplacement).to(beEmpty())
                expect(journeyStore.loadJourney(id: staleJourney.id)).to(beNil())
                let retired = await staleJourney.snapshot()
                expect(retired.executionState.pendingPresentation).to(beNil())
                expect(retired.executionState.currentPresentation).to(beNil())
                expect(retired.executionState.currentScreenId).to(beNil())
                expect(retired.executionState.viewModelSnapshot).to(beNil())
                mocks.experienceService.presentationCommitIsValid = true
                await service.shutdown()
            }

            it("retires a commit that becomes stale during attachment persistence") { @MainActor in
                let metadata = makeExperience(goal: nil, exitPolicy: nil)
                let signed = makeSignedLoadedExperience(entryActions: [
                    .navigate(.init(screenId: "screen-1", transition: nil))
                ])
                await primeProfile(experience: metadata, package: signed)
                await service.initialize()
                _ = await service.handleEventForTrigger(
                    NuxieEvent(
                        id: "evt-stale-during-attach",
                        name: "paywall_trigger",
                        distinctId: distinctId
                    ),
                    presentationAttempt: nil
                )
                let activeBeforeReplacement = await service.getActiveJourneys(for: distinctId)
                guard let staleJourney = activeBeforeReplacement.first else {
                    fail("expected active stale journey")
                    return
                }
                mocks.experienceService.presentationCommitValidationResults = [true, false]

                let accepted = await mocks.experiencePresentationService
                    .currentRuntimeDelegate?
                    .experienceViewControllerWillActivateInitialScreen(controller)

                expect(accepted).to(beFalse())
                let activeAfterReplacement = await service.getActiveJourneys(for: distinctId)
                expect(activeAfterReplacement).to(beEmpty())
                expect(journeyStore.loadJourney(id: staleJourney.id)).to(beNil())
                let retired = await staleJourney.snapshot()
                expect(retired.executionState.pendingPresentation).to(beNil())
                expect(retired.executionState.currentPresentation).to(beNil())
                expect(retired.executionState.currentScreenId).to(beNil())
                expect(retired.executionState.viewModelSnapshot).to(beNil())
                await service.shutdown()
            }

            it("retires cached preactivation when authority changes before presentation returns") { @MainActor in
                let presentation = CachedFastActivationPresentationService()
                presentation.afterPreactivation = {
                    mocks.experienceService.presentationCommitIsValid = false
                }
                presentation.failAfterPreactivation = true
                service = mocks.makeJourneyService(
                    journeyStore: journeyStore,
                    experiencePresentation: presentation
                )
                let metadata = makeExperience(goal: nil, exitPolicy: nil)
                let signed = makeSignedLoadedExperience(entryActions: [
                    .navigate(.init(screenId: "screen-1", transition: nil))
                ])
                await primeProfile(experience: metadata, package: signed)
                await service.initialize()
                _ = await service.handleEventForTrigger(
                    NuxieEvent(
                        id: "evt-stale-after-cached-preactivation",
                        name: "paywall_trigger",
                        distinctId: distinctId
                    ),
                    presentationAttempt: nil
                )

                expect(presentation.preactivationAccepted).to(beTrue())
                let activeAfterReplacement = await service.getActiveJourneys(for: distinctId)
                expect(activeAfterReplacement).to(beEmpty())
                expect(journeyStore.loadActiveJourneys()).to(beEmpty())
                mocks.experienceService.presentationCommitIsValid = true
                await service.shutdown()
            }

            it("suppresses the initial selected-to-selected transition but keeps later navigation") { @MainActor in
                let metadata = makeExperience(goal: nil, exitPolicy: nil)
                let signed = makeSignedLoadedExperience(entryActions: [
                    .navigate(.init(screenId: "screen-1", transition: nil))
                ])
                await primeProfile(experience: metadata, package: signed)
                await service.initialize()
                _ = await service.handleEventForTrigger(
                    NuxieEvent(
                        id: "evt-initial-screen-transition",
                        name: "paywall_trigger",
                        distinctId: distinctId
                    ),
                    presentationAttempt: nil
                )
                let delegate = mocks.experiencePresentationService.currentRuntimeDelegate
                let activated = await delegate?
                    .experienceViewControllerWillActivateInitialScreen(controller)
                expect(activated).to(beTrue())

                await delegate?.experienceViewController(
                    controller,
                    didChangeScreen: "screen-1"
                )
                await delegate?.experienceViewController(
                    controller,
                    didChangeScreen: "screen-2"
                )

                let transitions = mocks.eventLog.trackWithResponseCalls.filter {
                    $0.event == JourneyEvents.journeyTransition
                }
                expect(transitions).to(haveCount(1))
                expect(transitions.first?.properties?["from_node"] as? String)
                    .to(equal("screen-1"))
                expect(transitions.first?.properties?["to_node"] as? String)
                    .to(equal("screen-2"))
                await service.shutdown()
            }

            it("does not present when the exact signed presentation commit cannot persist") { @MainActor in
                journeyStore = RejectingCheckpointJourneyStore(rejected: .presentation)
                service = mocks.makeJourneyService(journeyStore: journeyStore)
                let metadata = makeExperience(goal: nil, exitPolicy: nil)
                let signed = makeSignedLoadedExperience(entryActions: [
                    .navigate(.init(screenId: "screen-1", transition: nil))
                ])
                await primeProfile(experience: metadata, package: signed)
                await service.initialize()

                _ = await service.handleEventForTrigger(
                    NuxieEvent(
                        id: "evt-persist-present",
                        name: "paywall_trigger",
                        distinctId: distinctId
                    ),
                    presentationAttempt: nil
                )

                expect(mocks.experiencePresentationService.presentExperienceCallCount)
                    .to(equal(0))
            }

            it("does not schedule an unpersisted signed pause checkpoint") { @MainActor in
                journeyStore = RejectingCheckpointJourneyStore(rejected: .pause)
                service = mocks.makeJourneyService(journeyStore: journeyStore)
                let metadata = makeExperience(goal: nil, exitPolicy: nil)
                let signed = makeSignedLoadedExperience(entryActions: [
                    .delay(.init(durationMs: 60_000))
                ])
                await primeProfile(experience: metadata, package: signed)
                await service.initialize()

                _ = await service.handleEventForTrigger(
                    NuxieEvent(
                        id: "evt-persist-pause",
                        name: "paywall_trigger",
                        distinctId: distinctId
                    ),
                    presentationAttempt: nil
                )

                expect(mocks.sleepProvider.sleepCalls).to(beEmpty())
                expect(mocks.experiencePresentationService.presentExperienceCallCount)
                    .to(equal(0))
            }

            it("records the journey match before an initial journey presentation") { @MainActor in
                let presentationTrace = InMemoryExperiencePresentationTrace()
                service = mocks.makeJourneyService(
                    journeyStore: journeyStore,
                    presentationTrace: presentationTrace
                )
                let experience = makeExperience(goal: nil, exitPolicy: nil)
                let flow = makeLoadedExperience()
                await primeProfile(experience: experience, package: flow)
                await service.initialize()
                let attempt = ExperiencePresentationAttempt(
                    id: "attempt-initial",
                    triggerEvent: "paywall_trigger",
                    startedAt: Date(timeIntervalSince1970: 1)
                )

                let results = await service.handleEventForTrigger(
                    NuxieEvent(id: "evt_origin", name: "paywall_trigger", distinctId: distinctId),
                    presentationAttempt: attempt
                )

                let journey = results.compactMap { result -> Journey? in
                    guard case .started(let journey) = result else { return nil }
                    return journey
                }.first
                expect(journey).toNot(beNil())
                expect(presentationTrace.events(for: attempt.id).map(\.stage)).to(equal([
                    .journeyMatched(journeyId: journey?.id ?? "missing"),
                    .presentationRequested(
                        experienceVersionId: flowId,
                        route: .journey
                    ),
                ]))
            }

            it("traces one lifecycle waterfall for a journey presentation") { @MainActor in
                let presentationTrace = InMemoryExperiencePresentationTrace()
                service = mocks.makeJourneyService(
                    journeyStore: journeyStore,
                    presentationTrace: presentationTrace
                )
                let experience = makeExperience(goal: nil, exitPolicy: nil)
                let flow = makeLoadedExperience()
                await primeProfile(experience: experience, package: flow)
                await service.initialize()
                let attempt = ExperiencePresentationAttempt(
                    id: "attempt-journey-lifecycle",
                    triggerEvent: "paywall_trigger",
                    startedAt: Date(timeIntervalSince1970: 1),
                    startedAtMonotonicTime: 1
                )

                let results = await service.handleEventForTrigger(
                    NuxieEvent(id: "evt_origin", name: "paywall_trigger", distinctId: distinctId),
                    presentationAttempt: attempt
                )
                let journey = results.compactMap { result -> Journey? in
                    guard case .started(let journey) = result else { return nil }
                    return journey
                }.first

                let delegate = mocks.experiencePresentationService.currentRuntimeDelegate
                let scopedDelegate = delegate as? any ExperiencePresentationScopedTraceDelegate
                let traceToken = scopedDelegate?.activePresentationTraceToken
                expect(journey).toNot(beNil())
                expect(delegate).toNot(beNil())
                let presentedTime = ExperiencePresentationTimestamp.monotonicNow()
                let drawable = ExperienceRuntimePresentedDrawable(
                    presentedTime: presentedTime,
                    pixelWidth: 20,
                    pixelHeight: 30,
                    drawCalls: 4,
                    provenance: .injectedTestObserver
                )
                await MainActor.run {
                    scopedDelegate?.experienceViewControllerDidBecomeReady(
                        controller,
                        traceToken: traceToken
                    )
                    scopedDelegate?.experienceViewControllerDidBecomeReady(
                        controller,
                        traceToken: traceToken
                    )
                    scopedDelegate?.experienceViewControllerDidPresentShell(
                        controller,
                        traceToken: traceToken
                    )
                    scopedDelegate?.experienceViewControllerDidPresentShell(
                        controller,
                        traceToken: traceToken
                    )
                    scopedDelegate?.experienceViewControllerDidReveal(
                        controller,
                        traceToken: traceToken
                    )
                    scopedDelegate?.experienceViewControllerDidReveal(
                        controller,
                        traceToken: traceToken
                    )
                    scopedDelegate?.experienceViewController(
                        controller,
                        didPresentDrawable: drawable,
                        screenId: "entry",
                        frameNumber: 7,
                        traceToken: traceToken
                    )
                    scopedDelegate?.experienceViewController(
                        controller,
                        didPresentDrawable: drawable,
                        screenId: "entry",
                        frameNumber: 8,
                        traceToken: traceToken
                    )
                    scopedDelegate?.experienceViewController(
                        controller,
                        didPresentDrawable: ExperienceRuntimePresentedDrawable(
                            presentedTime: presentedTime + 0.2,
                            frameNumber: 9,
                            pixelWidth: 30,
                            pixelHeight: 40,
                            drawCalls: 5,
                            provenance: .injectedTestObserver
                        ),
                        screenId: "confirmation",
                        frameNumber: 9,
                        traceToken: traceToken
                    )
                    scopedDelegate?.experienceViewController(
                        controller,
                        didAcceptPointerInput: ExperienceRuntimeAcceptedPointerInput(eventCount: 2),
                        screenId: "entry",
                        traceToken: traceToken
                    )
                    scopedDelegate?.experienceViewController(
                        controller,
                        didAcceptPointerInput: ExperienceRuntimeAcceptedPointerInput(eventCount: 3),
                        screenId: "entry",
                        traceToken: traceToken
                    )
                }

                await polling(expect {
                    presentationTrace.events(for: attempt.id).contains {
                        if case .firstAcceptedInput = $0.stage { return true }
                        return false
                    }
                }).value.toEventually(beTrue(), timeout: .seconds(2))
                await service.handleRuntimeDismiss(
                    journeyId: journey?.id ?? "missing",
                    reason: .userDismissed,
                    controller: controller
                )
                await MainActor.run {
                    scopedDelegate?.experienceViewControllerDidFinishPresentation(
                        controller,
                        traceToken: traceToken
                    )
                    scopedDelegate?.experienceViewControllerDidFinishPresentation(
                        controller,
                        traceToken: traceToken
                    )
                }

                await polling(expect {
                    presentationTrace.events(for: attempt.id).contains {
                        $0.stage == .presentationCleanupCompleted
                    }
                }).value.toEventually(beTrue(), timeout: .seconds(2))

                let lifecycleEvents = presentationTrace.events(for: attempt.id).filter { event in
                    switch event.stage {
                    case .runtimeReady, .shellPresented, .revealed,
                         .firstPresentedDrawable, .firstAcceptedInput,
                         .presentationCleanupCompleted:
                        return true
                    default:
                        return false
                    }
                }
                let expectedLifecycleStages: [ExperiencePresentationTraceStage] = [
                    .runtimeReady,
                    .shellPresented,
                    .revealed,
                    .firstPresentedDrawable(
                        screenId: "entry",
                        frameNumber: 7,
                        pixels: 600,
                        drawCalls: 4,
                        provenance: .injectedTestObserver
                    ),
                    .firstPresentedDrawable(
                        screenId: "confirmation",
                        frameNumber: 9,
                        pixels: 1_200,
                        drawCalls: 5,
                        provenance: .injectedTestObserver
                    ),
                    .firstAcceptedInput(screenId: "entry", eventCount: 2),
                    .presentationCleanupCompleted,
                ]
                expect(lifecycleEvents.map(\.stage)).to(equal(expectedLifecycleStages))
                expect(lifecycleEvents.map(\.attempt.id)).to(
                    equal(Array(repeating: attempt.id, count: lifecycleEvents.count))
                )
                expect(lifecycleEvents.first { event in
                    if case .firstPresentedDrawable = event.stage { return true }
                    return false
                }?.monotonicTime).to(equal(presentedTime))
            }

            it("keeps callback timestamps when journey trace forwarding is delayed") { @MainActor in
                let presentationTrace = InMemoryExperiencePresentationTrace()
                service = mocks.makeJourneyService(
                    journeyStore: journeyStore,
                    presentationTrace: presentationTrace
                )
                let experience = makeExperience(goal: nil, exitPolicy: nil)
                let flow = makeLoadedExperience()
                await primeProfile(experience: experience, package: flow)
                await service.initialize()
                let attempt = ExperiencePresentationAttempt(
                    id: "attempt-delayed-trace-forwarding",
                    triggerEvent: "paywall_trigger",
                    startedAt: Date(timeIntervalSince1970: 1)
                )

                _ = await service.handleEventForTrigger(
                    NuxieEvent(id: "evt_origin", name: "paywall_trigger", distinctId: distinctId),
                    presentationAttempt: attempt
                )
                let scopedDelegate = mocks.experiencePresentationService.currentRuntimeDelegate
                    as? any ExperiencePresentationScopedTraceDelegate
                let traceToken = scopedDelegate?.activePresentationTraceToken
                let callbackWallClock = Date(timeIntervalSince1970: 5_000)
                mocks.dateProvider.setCurrentDate(callbackWallClock)
                let drawablePresentedTime = ExperiencePresentationTimestamp.monotonicNow() - 0.25

                scopedDelegate?.experienceViewControllerDidPresentShell(
                    controller,
                    traceToken: traceToken
                )
                scopedDelegate?.experienceViewController(
                    controller,
                    didPresentDrawable: ExperienceRuntimePresentedDrawable(
                        presentedTime: drawablePresentedTime,
                        pixelWidth: 20,
                        pixelHeight: 30,
                        drawCalls: 4,
                        provenance: .injectedTestObserver
                    ),
                    screenId: "entry",
                    frameNumber: 7,
                    traceToken: traceToken
                )

                // The forwarding tasks cannot run until this MainActor test
                // yields. Move the service clock first to prove recorded wall
                // time came from the callbacks rather than actor delivery.
                mocks.dateProvider.advance(by: 60)

                await polling(expect {
                    presentationTrace.events(for: attempt.id).contains {
                        if case .firstPresentedDrawable = $0.stage { return true }
                        return false
                    }
                }).value.toEventually(beTrue(), timeout: .seconds(2))

                let lifecycleEvents = presentationTrace.events(for: attempt.id)
                let shell = lifecycleEvents.first { $0.stage == .shellPresented }
                let drawable = lifecycleEvents.first { event in
                    if case .firstPresentedDrawable = event.stage { return true }
                    return false
                }
                expect(shell?.occurredAt).to(equal(callbackWallClock))
                expect(drawable?.monotonicTime).to(equal(drawablePresentedTime))
                expect(drawable?.occurredAt.timeIntervalSince(callbackWallClock))
                    .to(beCloseTo(-0.25, within: 0.1))
            }

            it("does not deadlock trace setup when cached runtime readiness re-enters presentation") { @MainActor in
                let presentationTrace = InMemoryExperiencePresentationTrace()
                let presentationService = ReentrantRuntimeReadyExperiencePresentationService()
                presentationService.defaultMockViewController = controller
                service = mocks.makeJourneyService(
                    journeyStore: journeyStore,
                    experiencePresentation: presentationService,
                    presentationTrace: presentationTrace
                )
                let experience = makeExperience(goal: nil, exitPolicy: nil)
                let flow = makeLoadedExperience()
                await primeProfile(experience: experience, package: flow)
                await service.initialize()
                let attempt = ExperiencePresentationAttempt(
                    id: "attempt-reentrant-runtime-ready",
                    triggerEvent: "paywall_trigger",
                    startedAt: Date(timeIntervalSince1970: 1)
                )

                _ = await service.handleEventForTrigger(
                    NuxieEvent(id: "evt_origin", name: "paywall_trigger", distinctId: distinctId),
                    presentationAttempt: attempt
                )

                expect(presentationService.presentExperienceCallCount).to(equal(2))
                let traceEvents = presentationTrace.events(for: attempt.id)
                expect(traceEvents.filter { $0.stage == .runtimeReady }).to(haveCount(1))
                expect(traceEvents.map(\.attempt.id)).to(
                    equal(Array(repeating: attempt.id, count: traceEvents.count))
                )
            }

            it("does not let stale controller lifecycle consume replacement milestones") { @MainActor in
                let presentationTrace = InMemoryExperiencePresentationTrace()
                let presentationService = ReentrantRuntimeReadyExperiencePresentationService(
                    emitsStaleLifecycleAfterReplacement: true
                )
                presentationService.defaultMockViewController = controller
                service = mocks.makeJourneyService(
                    journeyStore: journeyStore,
                    experiencePresentation: presentationService,
                    presentationTrace: presentationTrace
                )
                let experience = makeExperience(goal: nil, exitPolicy: nil)
                let flow = makeLoadedExperience()
                await primeProfile(experience: experience, package: flow)
                await service.initialize()
                let attempt = ExperiencePresentationAttempt(
                    id: "attempt-stale-presentation-cleanup",
                    triggerEvent: "paywall_trigger",
                    startedAt: Date(timeIntervalSince1970: 1)
                )

                _ = await service.handleEventForTrigger(
                    NuxieEvent(id: "evt_origin", name: "paywall_trigger", distinctId: distinctId),
                    presentationAttempt: attempt
                )

                expect(presentationService.presentedControllers).to(haveCount(2))
                guard presentationService.presentedControllers.count == 2,
                      presentationService.capturedTraceTokens.count == 2 else {
                    fail("expected an original and replacement presentation")
                    return
                }
                let replacementController = presentationService.presentedControllers[1]
                let scopedDelegate = replacementController.runtimeDelegate
                    as? any ExperiencePresentationScopedTraceDelegate
                let replacementToken = presentationService.capturedTraceTokens[1]
                scopedDelegate?.experienceViewControllerDidPresentShell(
                    replacementController,
                    traceToken: replacementToken
                )
                scopedDelegate?.experienceViewControllerDidReveal(
                    replacementController,
                    traceToken: replacementToken
                )
                scopedDelegate?.experienceViewController(
                    replacementController,
                    didPresentDrawable: ExperienceRuntimePresentedDrawable(
                        presentedTime: ExperiencePresentationTimestamp.monotonicNow(),
                        pixelWidth: 20,
                        pixelHeight: 30,
                        drawCalls: 4,
                        provenance: .injectedTestObserver
                    ),
                    screenId: "replacement",
                    frameNumber: 7,
                    traceToken: replacementToken
                )
                scopedDelegate?.experienceViewController(
                    replacementController,
                    didAcceptPointerInput: ExperienceRuntimeAcceptedPointerInput(eventCount: 2),
                    screenId: "replacement",
                    traceToken: replacementToken
                )
                scopedDelegate?.experienceViewControllerDidFinishPresentation(
                    replacementController,
                    traceToken: replacementToken
                )

                await polling(expect {
                    presentationTrace.events(for: attempt.id).contains {
                        $0.stage == .presentationCleanupCompleted
                    }
                }).value.toEventually(beTrue(), timeout: .seconds(2))

                let lifecycleStages = presentationTrace.events(for: attempt.id).map(\.stage).filter {
                    switch $0 {
                    case .runtimeReady, .shellPresented, .revealed,
                         .firstPresentedDrawable, .firstAcceptedInput,
                         .presentationCleanupCompleted:
                        return true
                    default:
                        return false
                    }
                }
                let expectedLifecycleStages: [ExperiencePresentationTraceStage] = [
                    .runtimeReady,
                    .shellPresented,
                    .revealed,
                    .firstPresentedDrawable(
                        screenId: "replacement",
                        frameNumber: 7,
                        pixels: 600,
                        drawCalls: 4,
                        provenance: .injectedTestObserver
                    ),
                    .firstAcceptedInput(screenId: "replacement", eventCount: 2),
                    .presentationCleanupCompleted,
                ]
                expect(lifecycleStages).to(equal(expectedLifecycleStages))
            }

            it("uses the current trigger attempt when an active journey presents again") { @MainActor in
                let presentationTrace = InMemoryExperiencePresentationTrace()
                service = mocks.makeJourneyService(
                    journeyStore: journeyStore,
                    presentationTrace: presentationTrace
                )
                let experience = makeExperience(goal: nil, exitPolicy: nil)
                let flow = makeSignedLoadedExperience(entryActions: [], handlers: [
                    JourneyDocument.journeyEventHostKey: [
                        JourneyEventHandler(
                            id: "advance-active-journey",
                            eventName: "advance_journey",
                            actions: [
                                .navigate(NavigateAction(screenId: "screen-2", transition: nil))
                            ]
                        )
                    ]
                ])
                await primeProfile(experience: experience, package: flow)
                await service.initialize()
                let enrollmentAttempt = ExperiencePresentationAttempt(
                    id: "attempt-enrollment",
                    triggerEvent: "paywall_trigger",
                    startedAt: Date(timeIntervalSince1970: 1)
                )
                let currentAttempt = ExperiencePresentationAttempt(
                    id: "attempt-current",
                    triggerEvent: "advance_journey",
                    startedAt: Date(timeIntervalSince1970: 2)
                )

                let results = await service.handleEventForTrigger(
                    NuxieEvent(id: "evt_origin", name: "paywall_trigger", distinctId: distinctId),
                    presentationAttempt: enrollmentAttempt
                )
                let journey = results.compactMap { result -> Journey? in
                    guard case .started(let journey) = result else { return nil }
                    return journey
                }.first
                expect(journey).toNot(beNil())
                presentationTrace.removeAll()
                await mocks.experiencePresentationService.dismissCurrentExperience()

                _ = await service.handleEventForTrigger(
                    NuxieEvent(id: "evt_advance", name: "advance_journey", distinctId: distinctId),
                    presentationAttempt: currentAttempt
                )

                let delegate = mocks.experiencePresentationService.currentRuntimeDelegate
                let scopedDelegate = delegate as? any ExperiencePresentationScopedTraceDelegate
                let traceToken = scopedDelegate?.activePresentationTraceToken
                await MainActor.run {
                    scopedDelegate?.experienceViewControllerDidBecomeReady(
                        controller,
                        traceToken: traceToken
                    )
                }
                await polling(expect {
                    presentationTrace.events(for: currentAttempt.id).contains {
                        $0.stage == .runtimeReady
                    }
                }).value.toEventually(beTrue(), timeout: .seconds(2))

                expect(presentationTrace.events(for: enrollmentAttempt.id)).to(beEmpty())
                expect(presentationTrace.events(for: currentAttempt.id).map(\.stage)).to(equal([
                    .journeyMatched(journeyId: journey?.id ?? "missing"),
                    .presentationRequested(
                        experienceVersionId: flowId,
                        route: .journey
                    ),
                    .runtimeReady,
                ]))
                let storedAttempt = await ExperiencePresentationAttemptJourneyContext.load(from: journey!)
                expect(storedAttempt).to(equal(currentAttempt))
            }

            it("keeps visible presentation callbacks on the attempt that presented it") { @MainActor in
                let presentationTrace = InMemoryExperiencePresentationTrace()
                service = mocks.makeJourneyService(
                    journeyStore: journeyStore,
                    presentationTrace: presentationTrace
                )
                let experience = makeExperience(goal: nil, exitPolicy: nil)
                let flow = makeLoadedExperience(handlers: [
                    JourneyDocument.journeyEventHostKey: [
                        JourneyEventHandler(
                            id: "advance-visible-journey",
                            eventName: "advance_journey",
                            actions: [
                                .navigate(NavigateAction(screenId: "screen-2", transition: nil))
                            ]
                        )
                    ]
                ])
                await primeProfile(experience: experience, package: flow)
                await service.initialize()
                let presentingAttempt = ExperiencePresentationAttempt(
                    id: "attempt-presenting",
                    triggerEvent: "paywall_trigger",
                    startedAt: Date(timeIntervalSince1970: 1)
                )
                let laterAttempt = ExperiencePresentationAttempt(
                    id: "attempt-later",
                    triggerEvent: "advance_journey",
                    startedAt: Date(timeIntervalSince1970: 2)
                )

                let results = await service.handleEventForTrigger(
                    NuxieEvent(id: "evt_origin", name: "paywall_trigger", distinctId: distinctId),
                    presentationAttempt: presentingAttempt
                )
                let journey = results.compactMap { result -> Journey? in
                    guard case .started(let journey) = result else { return nil }
                    return journey
                }.first
                let delegate = mocks.experiencePresentationService.currentRuntimeDelegate
                let scopedDelegate = delegate as? any ExperiencePresentationScopedTraceDelegate
                let traceToken = scopedDelegate?.activePresentationTraceToken
                expect(journey).toNot(beNil())
                expect(delegate).toNot(beNil())

                _ = await service.handleEventForTrigger(
                    NuxieEvent(id: "evt_advance", name: "advance_journey", distinctId: distinctId),
                    presentationAttempt: laterAttempt
                )
                await MainActor.run {
                    scopedDelegate?.experienceViewControllerDidBecomeReady(
                        controller,
                        traceToken: traceToken
                    )
                }
                await polling(expect {
                    presentationTrace.events(for: presentingAttempt.id).contains {
                        $0.stage == .runtimeReady
                    }
                }).value.toEventually(beTrue(), timeout: .seconds(2))

                expect(presentationTrace.events(for: laterAttempt.id).map(\.stage)).to(equal([
                    .journeyMatched(journeyId: journey?.id ?? "missing")
                ]))
                let storedAttempt = await ExperiencePresentationAttemptJourneyContext.load(from: journey!)
                expect(storedAttempt).to(equal(laterAttempt))
            }

            it("invalidates trace callbacks after a terminal presentation failure") { @MainActor in
                let presentationTrace = InMemoryExperiencePresentationTrace()
                service = mocks.makeJourneyService(
                    journeyStore: journeyStore,
                    presentationTrace: presentationTrace
                )
                mocks.experiencePresentationService.configureToFail()
                let experience = makeExperience(goal: nil, exitPolicy: nil)
                let flow = makeLoadedExperience()
                await primeProfile(experience: experience, package: flow)
                await service.initialize()
                let attempt = ExperiencePresentationAttempt(
                    id: "attempt-failed-presentation",
                    triggerEvent: "paywall_trigger",
                    startedAt: Date(timeIntervalSince1970: 1)
                )

                _ = await service.handleEventForTrigger(
                    NuxieEvent(id: "evt_origin", name: "paywall_trigger", distinctId: distinctId),
                    presentationAttempt: attempt
                )
                let failedDelegate = mocks.experiencePresentationService.currentRuntimeDelegate
                expect(failedDelegate).toNot(beNil())
                await MainActor.run {
                    failedDelegate?.experienceViewControllerDidBecomeReady(controller)
                    failedDelegate?.experienceViewControllerDidPresentShell(controller)
                }
                try? await Task.sleep(nanoseconds: 50_000_000)

                let stages = presentationTrace.events(for: attempt.id).map(\.stage)
                expect(stages.contains { stage in
                    if case .presentationFailed(route: .journey, errorCode: _) = stage {
                        return true
                    }
                    return false
                }).to(beTrue())
                expect(stages.contains(.runtimeReady)).to(beFalse())
                expect(stages.contains(.shellPresented)).to(beFalse())
            }

            it("releases the runtime delegate when a journey terminates during presentation load") { @MainActor in
                let presentationTrace = InMemoryExperiencePresentationTrace()
                let presentationService = SuspendedFailingExperiencePresentationService()
                service = mocks.makeJourneyService(
                    journeyStore: journeyStore,
                    experiencePresentation: presentationService,
                    presentationTrace: presentationTrace
                )
                let experience = makeExperience(goal: nil, exitPolicy: nil)
                let terminalHandler = JourneyEventHandler(
                    id: "finish-during-presentation-load",
                    eventName: "finish_during_load",
                    actions: [.exit(ExitAction(reason: "completed"))]
                )
                let flow = makeLoadedExperience(handlers: [
                    JourneyDocument.journeyEventHostKey: [terminalHandler]
                ])
                await primeProfile(experience: experience, package: flow)
                await service.initialize()
                let attempt = ExperiencePresentationAttempt(
                    id: "attempt-terminal-during-load",
                    triggerEvent: "paywall_trigger",
                    startedAt: Date(timeIntervalSince1970: 1)
                )

                let startTask = Task {
                    await service.handleEventForTrigger(
                        NuxieEvent(
                            id: "evt_origin",
                            name: "paywall_trigger",
                            distinctId: distinctId
                        ),
                        presentationAttempt: attempt
                    )
                }
                await polling(expect(presentationService.capturedRuntimeDelegate)).value
                    .toEventuallyNot(beNil(), timeout: .seconds(2))
                weak var retainedDelegate = presentationService.capturedRuntimeDelegate

                await service.handleEvent(
                    NuxieEvent(
                        id: "evt_finish",
                        name: "finish_during_load",
                        distinctId: distinctId
                    )
                )
                await polling(expect {
                    await service.getActiveJourneys(for: distinctId).isEmpty
                }).value.toEventually(beTrue(), timeout: .seconds(2))

                presentationService.resumeWithFailure()
                _ = await startTask.value

                expect(retainedDelegate).to(beNil())
                expect(presentationTrace.events(for: attempt.id).contains { event in
                    if case .presentationFailed(route: .journey, errorCode: _) = event.stage {
                        return true
                    }
                    return false
                }).to(beTrue())
            }

            it("does not replace an active journey attempt for an unrelated trigger") { @MainActor in
                let presentationTrace = InMemoryExperiencePresentationTrace()
                service = mocks.makeJourneyService(
                    journeyStore: journeyStore,
                    presentationTrace: presentationTrace
                )
                let experience = makeExperience(goal: nil, exitPolicy: nil)
                let flow = makeLoadedExperience(handlers: [
                    JourneyDocument.journeyEventHostKey: [
                        JourneyEventHandler(
                            id: "advance-active-journey",
                            eventName: "advance_journey",
                            actions: [
                                .navigate(NavigateAction(screenId: "screen-2", transition: nil))
                            ]
                        )
                    ]
                ])
                await primeProfile(experience: experience, package: flow)
                await service.initialize()
                let enrollmentAttempt = ExperiencePresentationAttempt(
                    id: "attempt-enrollment",
                    triggerEvent: "paywall_trigger",
                    startedAt: Date(timeIntervalSince1970: 1)
                )
                let unrelatedAttempt = ExperiencePresentationAttempt(
                    id: "attempt-unrelated",
                    triggerEvent: "unrelated_event",
                    startedAt: Date(timeIntervalSince1970: 2)
                )

                let results = await service.handleEventForTrigger(
                    NuxieEvent(id: "evt_origin", name: "paywall_trigger", distinctId: distinctId),
                    presentationAttempt: enrollmentAttempt
                )
                let journey = results.compactMap { result -> Journey? in
                    guard case .started(let journey) = result else { return nil }
                    return journey
                }.first
                expect(journey).toNot(beNil())
                presentationTrace.removeAll()

                _ = await service.handleEventForTrigger(
                    NuxieEvent(id: "evt_unrelated", name: "unrelated_event", distinctId: distinctId),
                    presentationAttempt: unrelatedAttempt
                )

                expect(presentationTrace.events(for: unrelatedAttempt.id)).to(beEmpty())
                let storedTimeWindowAttempt = await ExperiencePresentationAttemptJourneyContext.load(
                    from: journey!
                )
                expect(storedTimeWindowAttempt).to(equal(enrollmentAttempt))
            }

            it("does not replace paused delay or time-window attempts for a matching trigger") { @MainActor in
                let presentationTrace = InMemoryExperiencePresentationTrace()
                service = mocks.makeJourneyService(
                    journeyStore: journeyStore,
                    presentationTrace: presentationTrace
                )
                let experience = makeExperience(goal: nil, exitPolicy: nil)
                let flow = makeLoadedExperience(
                    entryActions: [.delay(DelayAction(durationMs: 5_000))],
                    handlers: [
                        JourneyDocument.journeyEventHostKey: [
                            JourneyEventHandler(
                                id: "advance-paused-journey",
                                eventName: "advance_journey",
                                actions: [
                                    .navigate(NavigateAction(screenId: "screen-2", transition: nil))
                                ]
                            )
                        ]
                    ]
                )
                await primeProfile(experience: experience, package: flow)
                await service.initialize()
                let enrollmentAttempt = ExperiencePresentationAttempt(
                    id: "attempt-delay-enrollment",
                    triggerEvent: "paywall_trigger",
                    startedAt: Date(timeIntervalSince1970: 1)
                )
                let ignoredAttempt = ExperiencePresentationAttempt(
                    id: "attempt-delay-ignored",
                    triggerEvent: "advance_journey",
                    startedAt: Date(timeIntervalSince1970: 2)
                )
                let ignoredTimeWindowAttempt = ExperiencePresentationAttempt(
                    id: "attempt-time-window-ignored",
                    triggerEvent: "advance_journey",
                    startedAt: Date(timeIntervalSince1970: 3)
                )

                let results = await service.handleEventForTrigger(
                    NuxieEvent(id: "evt_origin", name: "paywall_trigger", distinctId: distinctId),
                    presentationAttempt: enrollmentAttempt
                )
                let journey = results.compactMap { result -> Journey? in
                    guard case .started(let journey) = result else { return nil }
                    return journey
                }.first
                expect(journey).toNot(beNil())

                mocks.experiencePresentationService.currentRuntimeDelegate?
                    .experienceViewControllerDidBecomeReady(controller)
                await expect { await journey?.snapshot().status }.toEventually(
                    equal(.paused),
                    timeout: .seconds(2)
                )
                let delayState = await journey?.snapshot()
                expect(delayState?.executionState.pendingAction?.kind).to(equal(.delay))
                presentationTrace.removeAll()

                _ = await service.handleEventForTrigger(
                    NuxieEvent(
                        id: "evt_advance",
                        name: "advance_journey",
                        distinctId: distinctId
                    ),
                    presentationAttempt: ignoredAttempt
                )

                expect(presentationTrace.events(for: ignoredAttempt.id)).to(beEmpty())
                let storedAttempt = await ExperiencePresentationAttemptJourneyContext.load(from: journey!)
                expect(storedAttempt).to(equal(enrollmentAttempt))
                let preservedDelayState = await journey?.snapshot()
                expect(preservedDelayState?.executionState.pendingAction?.kind).to(equal(.delay))

                await journey?.update {
                    $0.executionState.pendingAction = JourneyPendingAction(
                        handlerId: "start",
                        screenId: nil,
                        componentId: nil,
                        actionIndex: 0,
                        kind: .timeWindow,
                        resumeAt: Date(timeIntervalSince1970: 10),
                        condition: nil,
                        maxTimeMs: nil,
                        startedAt: Date(timeIntervalSince1970: 2),
                        resumeActions: nil
                    )
                }
                _ = await service.handleEventForTrigger(
                    NuxieEvent(
                        id: "evt_advance_time_window",
                        name: "advance_journey",
                        distinctId: distinctId
                    ),
                    presentationAttempt: ignoredTimeWindowAttempt
                )

                expect(presentationTrace.events(for: ignoredTimeWindowAttempt.id)).to(beEmpty())
                let storedTimeWindowAttempt = await ExperiencePresentationAttemptJourneyContext.load(
                    from: journey!
                )
                expect(storedTimeWindowAttempt).to(equal(enrollmentAttempt))
                let timeWindowState = await journey?.snapshot()
                expect(timeWindowState?.executionState.pendingAction?.kind).to(equal(.timeWindow))
            }

            it("persists journey enrollment synchronously before returning a started journey") {
                let experience = makeExperience(goal: nil, exitPolicy: nil)
                let flow = makeLoadedExperience()
                await primeProfile(experience: experience, package: flow)
                await service.initialize()

                let journey = await startJourney()

                let enrollment = mocks.eventLog.trackWithResponseCalls.first {
                    $0.event == JourneyEvents.journeyEnrolled
                }
                expect(enrollment).toNot(beNil())
                expect(enrollment?.properties?["journey_id"] as? String).to(equal(journey.id))
                expect(enrollment?.properties?["experience_id"] as? String).to(equal(experience.id))
                expect(enrollment?.properties?["experience_version"] as? String).to(equal(experience.versionId))
                expect(enrollment?.properties?["trigger_ref"] as? String).to(equal("evt_origin"))
                expect(enrollment?.properties?["plane"] as? String).to(equal("device"))
                expect(enrollment?.properties?["settings_snapshot"] as? [String: Any]).toNot(beNil())
                expect(enrollment?.flushPendingEvents).to(beTrue())
                expect(enrollment?.flushStrategy).to(equal(.eventLog))
            }

            it("flushes pending events when a routed event starts a journey") {
                let experience = makeExperience(goal: nil, exitPolicy: nil)
                let flow = makeLoadedExperience()
                await primeProfile(experience: experience, package: flow)
                await service.initialize()

                await service.handleEvent(
                    NuxieEvent(
                        id: "evt_origin",
                        name: "paywall_trigger",
                        distinctId: distinctId
                    )
                )

                let enrollment = mocks.eventLog.trackWithResponseCalls.first {
                    $0.event == JourneyEvents.journeyEnrolled
                }
                expect(enrollment).toNot(beNil())
                expect(enrollment?.flushPendingEvents).to(beTrue())
                expect(enrollment?.flushStrategy).to(equal(.eventLog))
            }

            it("does not start a local journey when enrollment persistence fails") {
                let experience = makeExperience(goal: nil, exitPolicy: nil)
                let flow = makeLoadedExperience()
                await primeProfile(experience: experience, package: flow)
                await service.initialize()
                mocks.eventLog.trackWithResponseError = URLError(.notConnectedToInternet)

                let results = await service.handleEventForTrigger(
                    NuxieEvent(id: "evt_origin", name: "paywall_trigger", distinctId: distinctId)
                )

                let started = results.contains { result in
                    if case .started = result { return true }
                    return false
                }
                let suppressedStartFailure = results.contains { result in
                    if case .suppressed(.unknown("start_failed")) = result { return true }
                    return false
                }
                expect(started).to(beFalse())
                expect(suppressedStartFailure).to(beTrue())
                await polling(expect {
                    await service.getActiveJourneys(for: distinctId).isEmpty
                }).value.toEventually(beTrue(), timeout: .seconds(2))
            }

            it("tracks renderer events once while routing them outside the source journey") { @MainActor in
                let ordering = OrderingRecorder()
                let eventController = OrderingMockExperienceViewController(mockExperienceVersionId: flowId, recorder: ordering)
                controller = eventController
                mocks.experiencePresentationService.defaultMockViewController = eventController

                let experience = makeExperience(goal: nil, exitPolicy: nil)
                let routedExperience = makeExperience(
                    id: "camp-renderer-event",
                    flowId: "flow-renderer-event",
                    trigger: .event(EventTriggerConfig(eventName: "renderer_event", condition: nil)),
                    goal: nil,
                    exitPolicy: nil
                )
                let flow = makeLoadedExperience(handlers: [
                    "screen-1": [
                        JourneyEventHandler(
                            id: "renderer-event-handler",
                            eventName: "renderer_event",
                            actions: [.navigate(NavigateAction(screenId: "screen-2", transition: nil))]
                        )
                    ]
                ])
                let routedFlow = makeLoadedExperience(flowId: "flow-renderer-event")
                await primeProfile(experiences: [experience, routedExperience], packages: [flow, routedFlow])
                await service.initialize()
                let journey = await startJourney()
                let pending = JourneyPendingAction(
                    handlerId: "wait-renderer-event",
                    screenId: "screen-1",
                    componentId: nil,
                    actionIndex: 0,
                    kind: .waitUntil,
                    resumeAt: nil,
                    condition: nil,
                    maxTimeMs: nil,
                    startedAt: Date(),
                    resumeActions: [.navigate(NavigateAction(screenId: "screen-3", transition: nil))]
                )
                await journey.update { $0.executionState.pendingAction = pending }

                await controller.runtimeDelegate?.experienceViewController(
                    controller,
                    didChangeScreen: "screen-1"
                )
                emitRendererEvent(controller, name: "renderer_event")

                await polling(expect(ordering.events)).value.toEventually(contain("navigate:screen-2"))
                await polling(expect {
                    ordering.events.filter { $0 == "navigate:screen-2" }
                }).value.toEventually(equal(["navigate:screen-2"]), timeout: .seconds(2))
                await polling(expect {
                    ordering.events
                }).value.toEventually(contain("navigate:screen-3"), timeout: .seconds(2))
                await polling(expect {
                    await service.getActiveJourneys(for: distinctId).map(\.experienceId)
                }).value.toEventually(contain("camp-renderer-event"))
                await polling(expect(mocks.eventLog.trackForTriggerCalls.map(\.event))).value.toEventually(contain("renderer_event"))
                let trackedRendererEvent = mocks.eventLog.routedEvents.first {
                    $0.name == "renderer_event"
                }
                let routedJourney = await service.getActiveJourneys(for: distinctId).first {
                    $0.experienceId == "camp-renderer-event"
                }
                let originEventId = await routedJourney?.getContext("_origin_event_id")?.value as? String
                expect(originEventId)
                    .to(equal(trackedRendererEvent?.id))
                expect(mocks.eventLog.trackedEvents.map(\.name)).toNot(contain("renderer_event"))
            }

            it("tracks tagged renderer events through the event routing path") { @MainActor in
                let ordering = OrderingRecorder()
                let eventController = OrderingMockExperienceViewController(mockExperienceVersionId: flowId, recorder: ordering)
                controller = eventController
                mocks.experiencePresentationService.defaultMockViewController = eventController

                let experience = makeExperience(goal: nil, exitPolicy: nil)
                let routedExperience = makeExperience(
                    id: "camp-tagged-renderer-event",
                    flowId: "flow-tagged-renderer-event",
                    trigger: .event(EventTriggerConfig(eventName: "tagged_renderer_event", condition: nil)),
                    goal: nil,
                    exitPolicy: nil
                )
                let flow = makeLoadedExperience(handlers: [
                    "screen-1": [
                        JourneyEventHandler(
                            id: "tagged-renderer-event-handler",
                            eventName: "tagged_renderer_event",
                            actions: [.navigate(NavigateAction(screenId: "screen-2", transition: nil))]
                        )
                    ]
                ])
                let routedFlow = makeLoadedExperience(flowId: "flow-tagged-renderer-event")
                await primeProfile(experiences: [experience, routedExperience], packages: [flow, routedFlow])
                await service.initialize()
                _ = await startJourney()

                await controller.runtimeDelegate?.experienceViewController(
                    controller,
                    didChangeScreen: "screen-1"
                )
                emitTaggedRendererEvent(controller, name: "tagged_renderer_event")

                await polling(expect(ordering.events)).value.toEventually(contain("navigate:screen-2"))
                await polling(expect {
                    await service.getActiveJourneys(for: distinctId).map(\.experienceId)
                }).value.toEventually(contain("camp-tagged-renderer-event"))
                await polling(expect(mocks.eventLog.trackForTriggerCalls.map(\.event))).value
                    .toEventually(contain("tagged_renderer_event"))
                let trackedRendererEvent = mocks.eventLog.routedEvents.first {
                    $0.name == "tagged_renderer_event"
                }
                let routedJourney = await service.getActiveJourneys(for: distinctId).first {
                    $0.experienceId == "camp-tagged-renderer-event"
                }
                let originEventId = await routedJourney?.getContext("_origin_event_id")?.value as? String
                expect(originEventId)
                    .to(equal(trackedRendererEvent?.id))
            }

            it("honors gate plans returned for renderer events") {
                let orderingPresentationService = OrderingExperiencePresentationService(recorder: OrderingRecorder())
                orderingPresentationService.defaultMockViewController = controller
                service = mocks.makeJourneyService(
                    journeyStore: journeyStore,
                    experiencePresentation: orderingPresentationService
                )

                let experience = makeExperience(goal: nil, exitPolicy: nil)
                let flow = makeLoadedExperience()
                await primeProfile(experience: experience, package: flow)
                await service.initialize()
                _ = await startJourney()
                mocks.eventLog.trackWithResponseResult = makeGatePlanResponse(
                    decision: "show_flow",
                    flowId: "gate-flow"
                )

                let gateController = controller!
                await gateController.runtimeDelegate?.experienceViewController(
                    gateController,
                    didChangeScreen: "screen-1"
                )
                await MainActor.run {
                    emitRendererEvent(gateController, name: "renderer_gate_event")
                }

                await polling(expect {
                    await MainActor.run {
                        orderingPresentationService.wasExperiencePresented("gate-flow")
                    }
                }).value.toEventually(beTrue(), timeout: .seconds(2))
                await polling(expect(mocks.eventLog.trackForTriggerCalls.map(\.event))).value
                    .toEventually(contain("renderer_gate_event"))
            }

            it("evaluates source renderer event goals from snapshots when profile cache is missing") {
                let experience = makeExperience(
                    goal: GoalConfig(kind: .event, eventName: "renderer_goal_event"),
                    exitPolicy: ExitPolicy(mode: .onGoal)
                )
                let flow = makeLoadedExperience()
                await primeProfile(experience: experience, package: flow)
                await service.initialize()
                let journey = await startJourney()
                await MainActor.run { [mocks = mocks!] in
                    mocks.experiencePresentationService.isPresentingExperience = false
                }
                await mocks.profileService.clearCache(distinctId: distinctId)

                let goalController = controller!
                await goalController.runtimeDelegate?.experienceViewController(
                    goalController,
                    didChangeScreen: "screen-1"
                )
                await MainActor.run {
                    emitRendererEvent(goalController, name: "renderer_goal_event")
                }

                await polling(expect {
                    journeyStore.getCompletions(for: distinctId).last { $0.journeyId == journey.id }?.exitReason
                }).value.toEventually(equal(.goalMet), timeout: .seconds(2))
            }

            it("evaluates goals emitted by a signed renderer handler action") {
                let conversionEvent = "experiences.qualification_converted"
                let flow = makeSignedLoadedExperience(entryActions: [], handlers: [
                    "screen-1": [
                        JourneyEventHandler(
                            id: "renderer-interaction-bridge",
                            eventName: "Nuxie Interaction",
                            actions: [
                                .sendEvent(SendEventAction(eventName: conversionEvent))
                            ]
                        )
                    ]
                ], goal: GoalConfig(kind: .event, eventName: conversionEvent),
                   exitPolicy: ExitPolicy(mode: .onGoal))
                await primeProfile(experience: flow, package: flow)
                await service.initialize()
                guard let journey = await service.startJourney(for: flow, distinctId: distinctId) else {
                    fail("expected signed journey")
                    return
                }

                let goalController = controller!
                let runtimeDelegate = mocks.experiencePresentationService.currentRuntimeDelegate
                let accepted = await runtimeDelegate?.experienceViewControllerWillActivateInitialScreen(
                    goalController
                )
                expect(accepted).to(beTrue())
                await runtimeDelegate?.experienceViewController(
                    goalController,
                    didChangeScreen: "screen-1"
                )
                await runtimeDelegate?.experienceViewControllerDidBecomeReady(goalController)
                await expect { await journey.snapshot().executionState.currentScreenId }
                    .toEventually(equal("screen-1"), timeout: .seconds(2))
                mocks.eventLog.trackForTriggerDelayNanoseconds = 2_000_000_000
                await MainActor.run {
                    emitRendererEvent(goalController, name: "Nuxie Interaction")
                }

                await polling(expect {
                    journeyStore.getCompletions(for: distinctId).last {
                        $0.journeyId == journey.id
                    }?.exitReason
                }).value.toEventually(equal(.goalMet), timeout: .milliseconds(750))
                expect(mocks.eventLog.trackForTriggerCalls.map(\.event))
                    .to(contain(conversionEvent))
                expect(mocks.eventLog.trackWithResponseCalls.map(\.event))
                    .to(contain(JourneyEvents.journeyConverted))

                let authoredEvent = mocks.eventLog.routedEvents.last {
                    $0.name == conversionEvent
                }
                let conversionCall = mocks.eventLog.trackWithResponseCalls.last {
                    $0.event == JourneyEvents.journeyConverted
                }
                expect(conversionCall?.properties?["source_fact_ref"] as? String)
                    .to(equal(authoredEvent?.id))
            }

            it("applies signed exit outcomes before authored event responses return") {
                let authoredEvent = "experiences.entry_authored_event"
                let flow = makeSignedLoadedExperience(entryActions: [], handlers: [
                    "screen-1": [
                        JourneyEventHandler(
                            id: "authored-exit",
                            eventName: "Nuxie Interaction",
                            actions: [
                                .sendEvent(SendEventAction(eventName: authoredEvent)),
                                .exit(ExitAction(reason: "completed")),
                            ]
                        )
                    ]
                ])
                await primeProfile(experience: flow, package: flow)
                await service.initialize()
                guard let journey = await service.startJourney(for: flow, distinctId: distinctId) else {
                    fail("expected signed journey")
                    return
                }
                let runtimeDelegate = mocks.experiencePresentationService.currentRuntimeDelegate
                let accepted = await runtimeDelegate?.experienceViewControllerWillActivateInitialScreen(
                    controller
                )
                expect(accepted).to(beTrue())
                await runtimeDelegate?.experienceViewController(controller, didChangeScreen: "screen-1")
                await runtimeDelegate?.experienceViewControllerDidBecomeReady(controller)
                mocks.eventLog.trackForTriggerDelayNanoseconds = 2_000_000_000

                await MainActor.run {
                    emitRendererEvent(controller, name: "Nuxie Interaction")
                }

                await polling(expect {
                    journeyStore.getCompletions(for: distinctId).last {
                        $0.journeyId == journey.id
                    }?.exitReason
                }).value.toEventually(equal(.completed), timeout: .milliseconds(750))
                expect(mocks.eventLog.trackForTriggerCalls.map(\.event))
                    .to(contain(authoredEvent))
                await service.shutdown()
            }

            it("applies signed exit outcomes before nested authored event responses return") {
                let continueEvent = "experiences.entry_continue_event"
                let nestedEvent = "experiences.entry_nested_event"
                let flow = makeSignedLoadedExperience(entryActions: [], handlers: [
                    "screen-1": [
                        JourneyEventHandler(
                            id: "authored-nested-exit",
                            eventName: "Nuxie Interaction",
                            actions: [
                                .sendEvent(SendEventAction(eventName: continueEvent)),
                                .exit(ExitAction(reason: "completed")),
                            ]
                        ),
                        JourneyEventHandler(
                            id: "authored-nested-response",
                            eventName: continueEvent,
                            actions: [
                                .sendEvent(SendEventAction(eventName: nestedEvent))
                            ]
                        ),
                    ]
                ])
                await primeProfile(experience: flow, package: flow)
                await service.initialize()
                guard let journey = await service.startJourney(for: flow, distinctId: distinctId) else {
                    fail("expected signed journey")
                    return
                }
                let runtimeDelegate = mocks.experiencePresentationService.currentRuntimeDelegate
                let accepted = await runtimeDelegate?.experienceViewControllerWillActivateInitialScreen(
                    controller
                )
                expect(accepted).to(beTrue())
                await runtimeDelegate?.experienceViewController(controller, didChangeScreen: "screen-1")
                await runtimeDelegate?.experienceViewControllerDidBecomeReady(controller)
                mocks.eventLog.trackForTriggerDelayNanoseconds = 2_000_000_000

                await MainActor.run {
                    emitRendererEvent(controller, name: "Nuxie Interaction")
                }

                await polling(expect {
                    journeyStore.getCompletions(for: distinctId).last {
                        $0.journeyId == journey.id
                    }?.exitReason
                }).value.toEventually(equal(.completed), timeout: .milliseconds(750))
                expect(mocks.eventLog.trackForTriggerCalls.map(\.event))
                    .to(contain(continueEvent, nestedEvent))
                await service.shutdown()
            }

            it("reconciles nested authored responses in commit order") {
                let firstEvent = "experiences.response_order_first"
                let nestedEvent = "experiences.response_order_nested"
                let firstFlow = "gate-flow-first"
                let nestedFlow = "gate-flow-nested"
                let flow = makeSignedLoadedExperience(entryActions: [], handlers: [
                    "screen-1": [
                        JourneyEventHandler(
                            id: "authored-response-order",
                            eventName: "Nuxie Interaction",
                            actions: [
                                .sendEvent(SendEventAction(eventName: firstEvent))
                            ]
                        ),
                        JourneyEventHandler(
                            id: "authored-response-order-nested",
                            eventName: firstEvent,
                            actions: [
                                .sendEvent(SendEventAction(eventName: nestedEvent))
                            ]
                        ),
                    ]
                ])
                await primeProfile(experience: flow, package: flow)
                await service.initialize()
                _ = await service.startJourney(for: flow, distinctId: distinctId)
                let runtimeDelegate = mocks.experiencePresentationService.currentRuntimeDelegate
                let accepted = await runtimeDelegate?.experienceViewControllerWillActivateInitialScreen(
                    controller
                )
                expect(accepted).to(beTrue())
                await runtimeDelegate?.experienceViewController(
                    controller,
                    didChangeScreen: "screen-1"
                )
                await runtimeDelegate?.experienceViewControllerDidBecomeReady(controller)
                mocks.eventLog.setTrackWithResponseResult(
                    makeGatePlanResponse(decision: "show_flow", flowId: firstFlow),
                    for: firstEvent
                )
                mocks.eventLog.setTrackWithResponseResult(
                    makeGatePlanResponse(decision: "show_flow", flowId: nestedFlow),
                    for: nestedEvent
                )

                await MainActor.run {
                    emitRendererEvent(controller, name: "Nuxie Interaction")
                }

                await polling(expect {
                    mocks.experiencePresentationService.presentedExperiences
                        .map(\.experienceVersionId)
                        .filter { $0 == firstFlow || $0 == nestedFlow }
                }).value.toEventually(
                    equal([firstFlow, nestedFlow]),
                    timeout: .seconds(2)
                )
                await service.shutdown()
            }

            it("reconciles delayed authored gate plans after the source journey exits") {
                let authoredEvent = "experiences.entry_gate_event"
                let flow = makeSignedLoadedExperience(entryActions: [], handlers: [
                    "screen-1": [
                        JourneyEventHandler(
                            id: "authored-gate-exit",
                            eventName: "Nuxie Interaction",
                            actions: [
                                .sendEvent(SendEventAction(eventName: authoredEvent)),
                                .exit(ExitAction(reason: "completed")),
                            ]
                        )
                    ]
                ])
                await primeProfile(experience: flow, package: flow)
                await service.initialize()
                guard let journey = await service.startJourney(for: flow, distinctId: distinctId) else {
                    fail("expected signed journey")
                    return
                }
                let journeyId = journey.id
                let runtimeDelegate = mocks.experiencePresentationService.currentRuntimeDelegate
                let accepted = await runtimeDelegate?.experienceViewControllerWillActivateInitialScreen(
                    controller
                )
                expect(accepted).to(beTrue())
                await runtimeDelegate?.experienceViewController(controller, didChangeScreen: "screen-1")
                await runtimeDelegate?.experienceViewControllerDidBecomeReady(controller)
                mocks.eventLog.trackWithResponseResult = makeGatePlanResponse(
                    decision: "show_flow",
                    flowId: "gate-flow"
                )
                mocks.eventLog.trackForTriggerDelayNanoseconds = 200_000_000

                await MainActor.run {
                    emitRendererEvent(controller, name: "Nuxie Interaction")
                }

                await polling(expect {
                    journeyStore.getCompletions(for: distinctId).last {
                        $0.journeyId == journeyId
                    }?.exitReason
                }).value.toEventually(equal(.completed), timeout: .milliseconds(750))
                await polling(expect {
                    mocks.experiencePresentationService.presentedExperiences
                        .map(\.experienceVersionId)
                }).value.toEventually(contain("gate-flow"), timeout: .seconds(2))
                await service.shutdown()
            }

            it("dispatches a signed authored event through its source screen handlers") {
                let continueEvent = "experiences.continue_pressed"
                let conversionEvent = "experiences.qualification_converted"
                let flow = makeSignedLoadedExperience(entryActions: [], handlers: [
                    "screen-1": [
                        JourneyEventHandler(
                            id: "renderer-interaction-bridge",
                            eventName: "Nuxie Interaction",
                            actions: [
                                .sendEvent(SendEventAction(eventName: continueEvent))
                            ]
                        ),
                        JourneyEventHandler(
                            id: "continue-handler",
                            eventName: continueEvent,
                            actions: [
                                .sendEvent(SendEventAction(eventName: conversionEvent))
                            ]
                        )
                    ]
                ], goal: GoalConfig(kind: .event, eventName: conversionEvent),
                   exitPolicy: ExitPolicy(mode: .onGoal))
                await primeProfile(experience: flow, package: flow)
                await service.initialize()
                guard let journey = await service.startJourney(for: flow, distinctId: distinctId) else {
                    fail("expected signed journey")
                    return
                }

                let goalController = controller!
                let runtimeDelegate = mocks.experiencePresentationService.currentRuntimeDelegate
                let accepted = await runtimeDelegate?.experienceViewControllerWillActivateInitialScreen(
                    goalController
                )
                expect(accepted).to(beTrue())
                await runtimeDelegate?.experienceViewController(
                    goalController,
                    didChangeScreen: "screen-1"
                )
                await runtimeDelegate?.experienceViewControllerDidBecomeReady(goalController)
                await expect { await journey.snapshot().executionState.currentScreenId }
                    .toEventually(equal("screen-1"), timeout: .seconds(2))
                await MainActor.run {
                    emitRendererEvent(goalController, name: "Nuxie Interaction")
                }

                await polling(expect {
                    journeyStore.getCompletions(for: distinctId).last {
                        $0.journeyId == journey.id
                    }?.exitReason
                }).value.toEventually(equal(.goalMet), timeout: .seconds(2))
                expect(mocks.eventLog.trackForTriggerCalls.map(\.event))
                    .to(contain(continueEvent, conversionEvent))
            }

            it("preserves journey-host routing for authored events while a screen is active") {
                let sourceEvent = "experiences.journey_source"
                let followupEvent = "experiences.journey_followup"
                let conversionEvent = "experiences.journey_conversion"
                let flow = makeSignedLoadedExperience(entryActions: [], handlers: [
                    JourneyDocument.journeyEventHostKey: [
                        JourneyEventHandler(
                            id: "journey-source-handler",
                            eventName: sourceEvent,
                            actions: [.sendEvent(SendEventAction(eventName: followupEvent))]
                        ),
                        JourneyEventHandler(
                            id: "journey-followup-handler",
                            eventName: followupEvent,
                            actions: [.sendEvent(SendEventAction(eventName: conversionEvent))]
                        )
                    ]
                ], goal: GoalConfig(kind: .event, eventName: conversionEvent),
                   exitPolicy: ExitPolicy(mode: .onGoal))
                await primeProfile(experience: flow, package: flow)
                await service.initialize()
                guard let journey = await service.startJourney(for: flow, distinctId: distinctId) else {
                    fail("expected signed journey")
                    return
                }

                let runtimeDelegate = mocks.experiencePresentationService.currentRuntimeDelegate
                let accepted = await runtimeDelegate?.experienceViewControllerWillActivateInitialScreen(
                    controller
                )
                expect(accepted).to(beTrue())
                await runtimeDelegate?.experienceViewController(
                    controller,
                    didChangeScreen: "screen-1"
                )
                await runtimeDelegate?.experienceViewControllerDidBecomeReady(controller)
                await service.handleEvent(
                    NuxieEvent(
                        id: "evt_journey_source",
                        name: sourceEvent,
                        distinctId: distinctId
                    )
                )

                await polling(expect {
                    journeyStore.getCompletions(for: distinctId).last {
                        $0.journeyId == journey.id
                    }?.exitReason
                }).value.toEventually(equal(.goalMet), timeout: .seconds(2))
            }

            it("commits and routes each authored event before the next batch event") {
                let firstEvent = "experiences.authored_batch_first"
                let nestedEvent = "experiences.authored_batch_nested"
                let finalEvent = "experiences.authored_batch_final"
                let flow = makeSignedLoadedExperience(entryActions: [], handlers: [
                    "screen-1": [
                        JourneyEventHandler(
                            id: "authored-batch",
                            eventName: "Nuxie Interaction",
                            actions: [
                                .sendEvent(SendEventAction(eventName: firstEvent)),
                                .sendEvent(SendEventAction(eventName: finalEvent)),
                            ]
                        ),
                        JourneyEventHandler(
                            id: "authored-batch-first-handler",
                            eventName: firstEvent,
                            actions: [
                                .sendEvent(SendEventAction(eventName: nestedEvent))
                            ]
                        )
                    ]
                ], goal: GoalConfig(kind: .event, eventName: finalEvent),
                   exitPolicy: ExitPolicy(mode: .onGoal))
                await primeProfile(experience: flow, package: flow)
                await service.initialize()
                guard let journey = await service.startJourney(
                    for: flow,
                    distinctId: distinctId
                ) else {
                    fail("expected signed journey")
                    return
                }

                let runtimeDelegate = mocks.experiencePresentationService.currentRuntimeDelegate
                let accepted = await runtimeDelegate?
                    .experienceViewControllerWillActivateInitialScreen(controller)
                expect(accepted).to(beTrue())
                await runtimeDelegate?.experienceViewController(
                    controller,
                    didChangeScreen: "screen-1"
                )
                await runtimeDelegate?.experienceViewControllerDidBecomeReady(controller)
                await MainActor.run {
                    emitRendererEvent(controller, name: "Nuxie Interaction")
                }

                await polling(expect {
                    journeyStore.getCompletions(for: distinctId).last {
                        $0.journeyId == journey.id
                    }?.exitReason
                }).value.toEventually(equal(.goalMet), timeout: .seconds(2))
                expect(
                    mocks.eventLog.trackForTriggerCalls.map(\.event).filter {
                        $0 == firstEvent || $0 == nestedEvent || $0 == finalEvent
                    }
                ).to(equal([firstEvent, nestedEvent, finalEvent]))
            }

            it("commits a signed authored event before its event-sent rider") {
                let authoredEvent = "experiences.ordered_authored_event"
                let ordering = OrderingRecorder()
                let orderingStore = OrderingJourneyStore(recorder: ordering)
                service = mocks.makeJourneyService(
                    journeyStore: orderingStore,
                    experiencePresentation: mocks.experiencePresentationService
                )
                journeyStore = orderingStore
                let flow = makeSignedLoadedExperience(entryActions: [], handlers: [
                    "screen-1": [
                        JourneyEventHandler(
                            id: "ordered-authored-event",
                            eventName: "Nuxie Interaction",
                            actions: [.sendEvent(SendEventAction(eventName: authoredEvent))]
                        )
                    ]
                ], goal: GoalConfig(kind: .event, eventName: authoredEvent),
                   exitPolicy: ExitPolicy(mode: .onGoal))
                await primeProfile(experience: flow, package: flow)
                await service.initialize()
                _ = await service.startJourney(for: flow, distinctId: distinctId)
                let identityService = mocks.identityService
                mocks.eventLog.preparedTriggerBeforeSend = { event in
                    if event.name == authoredEvent {
                        identityService.setDistinctId("replacement-user")
                    }
                    return event
                }
                mocks.eventLog.capturedEventObserver = { event in
                    guard event.name == JourneyEvents.eventSent,
                          event.properties["event_name"] as? String == authoredEvent else {
                        return
                    }
                    ordering.append("rider")
                }

                let runtimeDelegate = mocks.experiencePresentationService.currentRuntimeDelegate
                let accepted = await runtimeDelegate?.experienceViewControllerWillActivateInitialScreen(
                    controller
                )
                expect(accepted).to(beTrue())
                await runtimeDelegate?.experienceViewController(
                    controller,
                    didChangeScreen: "screen-1"
                )
                await runtimeDelegate?.experienceViewControllerDidBecomeReady(controller)
                await MainActor.run { emitRendererEvent(controller, name: "Nuxie Interaction") }

                await polling(expect {
                    mocks.eventLog.routedEvents.map(\.name).filter {
                        $0 == authoredEvent || $0 == JourneyEvents.eventSent
                    }
                }).value.toEventually(
                    equal([authoredEvent, JourneyEvents.eventSent]),
                    timeout: .seconds(2)
                )
                await polling(expect {
                    ordering.events
                }).value.toEventually(
                    equal(["complete:\(flow.id)", "rider"]),
                    timeout: .seconds(2)
                )
                let rider = mocks.eventLog.routedEvents.first {
                    $0.name == JourneyEvents.eventSent
                        && $0.properties["event_name"] as? String == authoredEvent
                }
                expect(rider?.distinctId).to(equal(distinctId))
            }

            it("marks signed authored events for durable local-first delivery") {
                let authoredEvent = "experiences.durable_authored_event"
                let flow = makeSignedLoadedExperience(entryActions: [], handlers: [
                    "screen-1": [
                        JourneyEventHandler(
                            id: "durable-authored-event",
                            eventName: "Nuxie Interaction",
                            actions: [.sendEvent(SendEventAction(eventName: authoredEvent))]
                        )
                    ]
                ])
                await primeProfile(experience: flow, package: flow)
                await service.initialize()
                guard let journey = await service.startJourney(for: flow, distinctId: distinctId) else {
                    fail("expected signed journey")
                    return
                }

                let runtimeDelegate = mocks.experiencePresentationService.currentRuntimeDelegate
                let accepted = await runtimeDelegate?.experienceViewControllerWillActivateInitialScreen(
                    controller
                )
                expect(accepted).to(beTrue())
                await runtimeDelegate?.experienceViewController(controller, didChangeScreen: "screen-1")
                await runtimeDelegate?.experienceViewControllerDidBecomeReady(controller)
                await MainActor.run { emitRendererEvent(controller, name: "Nuxie Interaction") }

                await polling(expect {
                    mocks.eventLog.trackForTriggerCalls.first { $0.event == authoredEvent }?
                        .persistToHistory
                }).value.toEventually(beTrue(), timeout: .seconds(2))
                let finalState = await journey.snapshot()
                expect(finalState.status.isLive).to(beTrue())
            }

            it("honors beforeSend for signed authored event batches") {
                let droppedEvent = "experiences.authored_dropped"
                let redactedEvent = "experiences.authored_redacted"
                let flow = makeSignedLoadedExperience(entryActions: [], handlers: [
                    "screen-1": [
                        JourneyEventHandler(
                            id: "captured-authored-privacy",
                            eventName: "Nuxie Interaction",
                            actions: [
                                .sendEvent(SendEventAction(
                                    eventName: droppedEvent,
                                    properties: ["secret": AnyCodable("drop")]
                                )),
                                .sendEvent(SendEventAction(
                                    eventName: redactedEvent,
                                    properties: ["secret": AnyCodable("redact")]
                                )),
                            ]
                        )
                    ]
                ])
                await primeProfile(experience: flow, package: flow)
                await service.initialize()
                mocks.eventLog.preparedTriggerBeforeSend = { event in
                    guard event.name != droppedEvent else { return nil }
                    return NuxieEvent(
                        id: event.id,
                        name: event.name,
                        distinctId: event.distinctId,
                        properties: ["privacy": "redacted"],
                        timestamp: event.timestamp
                    )
                }
                _ = await service.startJourney(for: flow, distinctId: distinctId)

                let runtimeDelegate = mocks.experiencePresentationService.currentRuntimeDelegate
                let accepted = await runtimeDelegate?.experienceViewControllerWillActivateInitialScreen(
                    controller
                )
                expect(accepted).to(beTrue())
                await runtimeDelegate?.experienceViewController(controller, didChangeScreen: "screen-1")
                await runtimeDelegate?.experienceViewControllerDidBecomeReady(controller)
                await MainActor.run { emitRendererEvent(controller, name: "Nuxie Interaction") }

                await polling(expect {
                    mocks.eventLog.trackForTriggerCalls.first {
                        $0.event == redactedEvent
                    }?.properties?["privacy"] as? String
                }).value.toEventually(equal("redacted"), timeout: .seconds(2))
                expect(mocks.eventLog.trackForTriggerCalls.map(\.event))
                    .toNot(contain(droppedEvent))
                let redacted = mocks.eventLog.trackForTriggerCalls.first {
                    $0.event == redactedEvent
                }
                expect(redacted?.properties?["secret"]).to(beNil())
            }

            it("does not route a beforeSend identity rewrite into the source journey") {
                let authoredEvent = "experiences.authored_reassigned"
                let reassignedDistinctID = "user_reassigned"
                let flow = makeSignedLoadedExperience(entryActions: [], handlers: [
                    "screen-1": [
                        JourneyEventHandler(
                            id: "captured-authored-reassigned",
                            eventName: "Nuxie Interaction",
                            actions: [.sendEvent(SendEventAction(eventName: authoredEvent))]
                        )
                    ]
                ], goal: GoalConfig(kind: .event, eventName: authoredEvent),
                   exitPolicy: ExitPolicy(mode: .onGoal))
                await primeProfile(experience: flow, package: flow)
                await service.initialize()
                mocks.eventLog.preparedTriggerBeforeSend = { event in
                    NuxieEvent(
                        id: event.id,
                        name: event.name,
                        distinctId: reassignedDistinctID,
                        properties: event.properties,
                        timestamp: event.timestamp
                    )
                }
                guard let journey = await service.startJourney(
                    for: flow,
                    distinctId: distinctId
                ) else {
                    fail("expected signed journey")
                    return
                }

                let runtimeDelegate = mocks.experiencePresentationService.currentRuntimeDelegate
                let accepted = await runtimeDelegate?
                    .experienceViewControllerWillActivateInitialScreen(controller)
                expect(accepted).to(beTrue())
                await runtimeDelegate?.experienceViewController(
                    controller,
                    didChangeScreen: "screen-1"
                )
                await runtimeDelegate?.experienceViewControllerDidBecomeReady(controller)
                await MainActor.run { emitRendererEvent(controller, name: "Nuxie Interaction") }

                await polling(expect {
                    mocks.eventLog.trackForTriggerCalls.first {
                        $0.event == authoredEvent
                    }?.distinctIdOverride
                }).value.toEventually(equal(reassignedDistinctID), timeout: .seconds(2))
                let finalState = await journey.snapshot()
                expect(finalState.status.isLive).to(beTrue())
                expect(journeyStore.getCompletions(for: distinctId).contains {
                    $0.journeyId == journey.id
                }).to(beFalse())
            }

            it("drains an authored event batch after its first event completes the source journey") {
                let completingEvent = "experiences.batch_completes_source"
                let trailingEvent = "experiences.batch_trailing_event"
                let flow = makeSignedLoadedExperience(entryActions: [], handlers: [
                    "screen-1": [
                        JourneyEventHandler(
                            id: "captured-authored-batch",
                            eventName: "Nuxie Interaction",
                            actions: [
                                .sendEvent(SendEventAction(eventName: completingEvent)),
                                .sendEvent(SendEventAction(eventName: trailingEvent)),
                            ]
                        )
                    ]
                ], goal: GoalConfig(kind: .event, eventName: completingEvent),
                   exitPolicy: ExitPolicy(mode: .onGoal))
                await primeProfile(experience: flow, package: flow)
                await service.initialize()
                guard let journey = await service.startJourney(for: flow, distinctId: distinctId) else {
                    fail("expected signed journey")
                    return
                }

                let runtimeDelegate = mocks.experiencePresentationService.currentRuntimeDelegate
                let accepted = await runtimeDelegate?.experienceViewControllerWillActivateInitialScreen(
                    controller
                )
                expect(accepted).to(beTrue())
                await runtimeDelegate?.experienceViewController(controller, didChangeScreen: "screen-1")
                await runtimeDelegate?.experienceViewControllerDidBecomeReady(controller)
                mocks.eventLog.trackForTriggerDelayNanoseconds = 2_000_000_000
                await MainActor.run { emitRendererEvent(controller, name: "Nuxie Interaction") }

                await polling(expect {
                    mocks.eventLog.trackForTriggerCalls.map(\.event)
                }).value.toEventually(
                    contain(completingEvent, trailingEvent),
                    timeout: .milliseconds(750)
                )
                await polling(expect {
                    journeyStore.getCompletions(for: distinctId).contains { $0.journeyId == journey.id }
                }).value.toEventually(beTrue(), timeout: .seconds(3))
            }
        }

        describe("exit deferral during active flow presentation") {
            it("reevaluates goals triggered by dismiss handlers before falling back to dismissed") {
                let dismissGoal = JourneyEventHandler(
                    id: "dismiss-goal",
                    eventName: SystemEventNames.screenDismissed,
                    actions: [
                        .updateCustomer(
                            UpdateCustomerAction(attributes: ["dismissed": AnyCodable(true)])
                        )
                    ]
                )
                let experience = makeExperience(
                    goal: GoalConfig(
                        kind: .attribute,
                        attributeExpr: IREnvelope(
                            ir_version: 1,
                            engine_min: nil,
                            compiled_at: nil,
                            expr: .user(op: "eq", key: "dismissed", value: .bool(true))
                        )
                    ),
                    exitPolicy: ExitPolicy(mode: .onGoal)
                )
                let flow = makeLoadedExperience(handlers: [JourneyDocument.journeyEventHostKey: [dismissGoal]])
                await primeProfile(experience: experience, package: flow)
                await service.initialize()

                _ = await startJourney()
                let activeJourneys = await service.getActiveJourneys(for: distinctId)
                let initialState = await activeJourneys.first?.snapshot()
                expect(initialState?.convertedAt).to(beNil())

                let dismissController = controller!
                await dismissController.prepareForDismissal()
                await MainActor.run {
                    dismissController.runtimeDelegate?.experienceViewControllerDidRequestDismiss(
                        dismissController,
                        reason: .userDismissed
                    )
                }

                await polling(expect {
                    journeyStore.getCompletions(for: distinctId).last?.exitReason
                }).value.toEventually(equal(.goalMet), timeout: .seconds(2))
                expect(journeyStore.getCompletions(for: distinctId).last?.exitReason).toNot(equal(.dismissed))
            }

            it("starts matching experiences from scoped notification outcomes") {
                let notificationExperience = makeExperience(
                    id: "camp-notifications",
                    flowId: "flow-notifications",
                    trigger: .event(EventTriggerConfig(eventName: SystemEventNames.notificationsEnabled, condition: nil)),
                    goal: nil,
                    exitPolicy: nil
                )
                let primaryExperience = makeExperience(goal: nil, exitPolicy: nil)
                let primaryFlow = makeLoadedExperience()
                let notificationFlow = makeLoadedExperience(flowId: "flow-notifications")

                await primeProfile(
                    experiences: [primaryExperience, notificationExperience],
                    packages: [primaryFlow, notificationFlow]
                )
                await service.initialize()

                let journey = await startJourney()

                await MainActor.run { [controller = controller!] in
                    (controller.runtimeDelegate as? NotificationPermissionEventReceiver)?.experienceViewController(
                        controller,
                        didResolveNotificationPermissionEvent: SystemEventNames.notificationsEnabled,
                        properties: ["journey_id": journey.id],
                        journeyId: journey.id
                    )
                }

                await polling(expect {
                    await service.getActiveJourneys(for: distinctId).map(\.experienceId).sorted()
                }).value.toEventually(equal([experienceId, "camp-notifications"].sorted()), timeout: .seconds(2))
            }

            it("completes presented journeys when scoped goal actions fire") {
                let experience = makeExperience(
                    goal: GoalConfig(kind: .event, eventName: JourneyEvents.journeyMilestone),
                    exitPolicy: ExitPolicy(mode: .onGoal)
                )
                let flow = makeLoadedExperience()
                await primeProfile(experience: experience, package: flow)
                await service.initialize()

                let journey = await startJourney()

                await service.handleScopedMilestoneEvent(
                    journeyId: journey.id,
                    milestoneId: "signup_complete",
                    milestoneLabel: "Signed Up",
                    screenId: "screen-1"
                )

                await polling(expect {
                    await service.getActiveJourneys(for: distinctId).isEmpty
                }).value.toEventually(beTrue(), timeout: .seconds(2))
                await polling(expect {
                    await MainActor.run { [mocks = mocks!] in mocks.experiencePresentationService.dismissCurrentExperienceCallCount }
                }).value.toEventually(equal(1), timeout: .seconds(2))
                expect(mocks.eventLog.trackForTriggerCalls.last?.properties?["journey_id"] as? String)
                    .to(equal(journey.id))
                expect(mocks.eventLog.trackForTriggerCalls.last?.properties?["milestone_id"] as? String)
                    .to(equal("signup_complete"))
                expect(mocks.eventLog.trackForTriggerCalls.last?.properties?["epoch"] as? Int).to(equal(0))
                expect(mocks.eventLog.trackForTriggerCalls.last?.properties).to(haveCount(3))

                await polling(expect {
                    journeyStore.getCompletions(for: distinctId).last?.exitReason
                }).value.toEventually(equal(.goalMet), timeout: .seconds(2))
            }

            it("persists scoped goal hits for multi-step attribute goals") {
                let experience = makeExperience(
                    goal: GoalConfig(
                        kind: .attribute,
                        attributeExpr: IREnvelope(
                            ir_version: 1,
                            engine_min: nil,
                            compiled_at: nil,
                            expr: .and([
                                .eventsExists(
                                    name: JourneyEvents.journeyMilestone,
                                    since: nil,
                                    until: nil,
                                    within: nil,
                                    where_: .pred(
                                        op: "eq",
                                        key: "milestone_id",
                                        value: .string("signup_started")
                                    )
                                ),
                                .eventsExists(
                                    name: JourneyEvents.journeyMilestone,
                                    since: nil,
                                    until: nil,
                                    within: nil,
                                    where_: .pred(
                                        op: "eq",
                                        key: "milestone_id",
                                        value: .string("signup_completed")
                                    )
                                ),
                            ])
                        )
                    ),
                    exitPolicy: nil
                )
                let flow = makeLoadedExperience()
                await primeProfile(experience: experience, package: flow)
                await service.initialize()

                let journey = await startJourney()
                let initialState = await journey.snapshot()
                expect(initialState.convertedAt).to(beNil())

                await service.handleScopedMilestoneEvent(
                    journeyId: journey.id,
                    milestoneId: "signup_started",
                    milestoneLabel: nil,
                    screenId: "screen-1"
                )

                let journeyAfterFirstGoal = await service.getActiveJourneys(for: distinctId).first {
                    $0.id == journey.id
                }
                let stateAfterFirstGoal = await journeyAfterFirstGoal?.snapshot()
                expect(stateAfterFirstGoal?.convertedAt).to(beNil())

                await service.handleScopedMilestoneEvent(
                    journeyId: journey.id,
                    milestoneId: "signup_completed",
                    milestoneLabel: nil,
                    screenId: "screen-1"
                )

                await polling(expect {
                    let matchingJourney = await service.getActiveJourneys(for: distinctId).first {
                        $0.id == journey.id
                    }
                    return await matchingJourney?.snapshot().convertedAt
                }).value.toEventuallyNot(beNil(), timeout: .seconds(2))
            }

            it("routes goal-driven closures through dismissal hooks and flow dismissal tracking") {
                let dismissFollowUp = JourneyEventHandler(
                    id: "dismiss-follow-up",
                    eventName: SystemEventNames.screenDismissed,
                    actions: [
                        .sendEvent(
                            SendEventAction(
                                eventName: "dismiss_hook_ran",
                                properties: nil
                            )
                        )
                    ]
                )
                let experience = makeExperience(
                    goal: GoalConfig(kind: .event, eventName: JourneyEvents.journeyMilestone),
                    exitPolicy: ExitPolicy(mode: .onGoal)
                )
                let flow = makeLoadedExperience(handlers: [JourneyDocument.journeyEventHostKey: [dismissFollowUp]])
                await primeProfile(experience: experience, package: flow)
                await service.initialize()

                let journey = await startJourney()
                let dismissNotifications = OrderingRecorder()
                let observer = NotificationCenter.default.addObserver(
                    forName: .nuxieDismiss,
                    object: nil,
                    queue: nil
                ) { notification in
                    if let reason = notification.userInfo?["reason"] as? String {
                        dismissNotifications.append(reason)
                    }
                }
                defer {
                    NotificationCenter.default.removeObserver(observer)
                }

                await service.handleScopedMilestoneEvent(
                    journeyId: journey.id,
                    milestoneId: "signup_complete",
                    milestoneLabel: "Signed Up",
                    screenId: "screen-1"
                )

                await polling(expect {
                    journeyStore.getCompletions(for: distinctId).last?.exitReason
                }).value.toEventually(equal(.goalMet), timeout: .seconds(2))
                await polling(expect {
                    mocks.eventLog.trackedEvents.map(\.name)
                }).value.toEventually(contain(JourneyEvents.experienceDismissed), timeout: .seconds(2))
                await polling(expect {
                    mocks.eventLog.trackedEvents.map(\.name)
                }).value.toEventually(contain("dismiss_hook_ran"), timeout: .seconds(2))
                await polling(expect {
                    dismissNotifications.events.last
                }).value.toEventually(equal("goal_met"), timeout: .seconds(2))
            }

            it("completes presented journeys before scoped goal tracking returns") {
                let experience = makeExperience(
                    goal: GoalConfig(kind: .event, eventName: JourneyEvents.journeyMilestone),
                    exitPolicy: ExitPolicy(mode: .onGoal)
                )
                let flow = makeLoadedExperience()
                await primeProfile(experience: experience, package: flow)
                await service.initialize()

                let journey = await startJourney()
                mocks.eventLog.trackForTriggerDelayNanoseconds = 750_000_000

                let scopedGoalTask = Task {
                    await service.handleScopedMilestoneEvent(
                        journeyId: journey.id,
                        milestoneId: "signup_complete",
                        milestoneLabel: "Signed Up",
                        screenId: "screen-1"
                    )
                }

                await polling(expect {
                    await service.getActiveJourneys(for: distinctId).isEmpty
                }).value.toEventually(beTrue(), timeout: .milliseconds(250))
                await polling(expect {
                    await MainActor.run { [mocks = mocks!] in mocks.experiencePresentationService.dismissCurrentExperienceCallCount }
                }).value.toEventually(equal(1), timeout: .milliseconds(250))
                await polling(expect {
                    journeyStore.getCompletions(for: distinctId).last?.exitReason
                }).value.toEventually(equal(.goalMet), timeout: .milliseconds(250))

                await scopedGoalTask.value
            }

            it("uses journey snapshots when scoped goal actions outlive the cached profile") {
                let experience = makeExperience(
                    goal: GoalConfig(kind: .event, eventName: JourneyEvents.journeyMilestone),
                    exitPolicy: ExitPolicy(mode: .onGoal)
                )
                let flow = makeLoadedExperience()
                await primeProfile(experience: experience, package: flow)
                await service.initialize()

                let journey = await startJourney()
                await mocks.profileService.clearCache(distinctId: distinctId)

                await service.handleScopedMilestoneEvent(
                    journeyId: journey.id,
                    milestoneId: "signup_complete",
                    milestoneLabel: "Signed Up",
                    screenId: "screen-1"
                )

                await polling(expect {
                    await service.getActiveJourneys(for: distinctId).isEmpty
                }).value.toEventually(beTrue(), timeout: .seconds(2))
                await polling(expect {
                    journeyStore.getCompletions(for: distinctId).last?.journeyId
                }).value.toEventually(equal(journey.id), timeout: .seconds(2))
                await polling(expect {
                    journeyStore.getCompletions(for: distinctId).last?.exitReason
                }).value.toEventually(equal(.goalMet), timeout: .seconds(2))
            }

            it("replays source goal-hit handlers after the scoped profile cache expires") {
                let goalHitFollowUp = JourneyEventHandler(
                    id: "goal-hit-follow-up",
                    eventName: JourneyEvents.journeyMilestone,
                    actions: [
                        .sendEvent(
                            SendEventAction(
                                eventName: "goal_follow_up",
                                properties: nil
                            )
                        )
                    ]
                )
                let experience = makeExperience(goal: nil, exitPolicy: nil)
                let flow = makeLoadedExperience(handlers: [JourneyDocument.journeyEventHostKey: [goalHitFollowUp]])
                await primeProfile(experience: experience, package: flow)
                await service.initialize()

                let journey = await startJourney()
                await mocks.profileService.clearCache(distinctId: distinctId)

                await service.handleScopedMilestoneEvent(
                    journeyId: journey.id,
                    milestoneId: "signup_complete",
                    milestoneLabel: "Signed Up",
                    screenId: "screen-1"
                )

                await polling(expect {
                    mocks.eventLog.trackedEvents.map(\.name)
                }).value.toEventually(contain("goal_follow_up"), timeout: .seconds(2))
            }

            it("does not replay scoped goal actions back into the source journey after goal completion") {
                let goalHitFollowUp = JourneyEventHandler(
                    id: "goal-hit-follow-up",
                    eventName: JourneyEvents.journeyMilestone,
                    actions: [
                        .sendEvent(
                            SendEventAction(
                                eventName: "should_not_run",
                                properties: nil
                            )
                        )
                    ]
                )
                let experience = makeExperience(
                    goal: GoalConfig(kind: .event, eventName: JourneyEvents.journeyMilestone),
                    exitPolicy: ExitPolicy(mode: .onGoal)
                )
                let flow = makeLoadedExperience(handlers: [JourneyDocument.journeyEventHostKey: [goalHitFollowUp]])
                await primeProfile(experience: experience, package: flow)
                await service.initialize()

                let journey = await startJourney()

                await service.handleScopedMilestoneEvent(
                    journeyId: journey.id,
                    milestoneId: "signup_complete",
                    milestoneLabel: "Signed Up",
                    screenId: "screen-1"
                )
                try? await Task.sleep(nanoseconds: 200_000_000)

                expect(mocks.eventLog.trackedEvents.map(\.name)).toNot(contain("should_not_run"))
                await polling(expect {
                    await service.getActiveJourneys(for: distinctId).isEmpty
                }).value.toEventually(beTrue(), timeout: .seconds(2))
            }

            it("starts matching experiences from scoped goal actions") {
                let goalExperience = makeExperience(
                    id: "camp-goal-trigger",
                    flowId: "flow-goal-trigger",
                    trigger: .event(EventTriggerConfig(eventName: JourneyEvents.journeyMilestone, condition: nil)),
                    goal: nil,
                    exitPolicy: nil
                )
                let primaryExperience = makeExperience(goal: nil, exitPolicy: nil)
                let primaryFlow = makeLoadedExperience()
                let goalFlow = makeLoadedExperience(flowId: "flow-goal-trigger")

                await primeProfile(
                    experiences: [primaryExperience, goalExperience],
                    packages: [primaryFlow, goalFlow]
                )
                await service.initialize()

                let journey = await startJourney()

                await service.handleScopedMilestoneEvent(
                    journeyId: journey.id,
                    milestoneId: "signup_complete",
                    milestoneLabel: "Signed Up",
                    screenId: "screen-1"
                )

                await polling(expect {
                    await service.getActiveJourneys(for: distinctId).map(\.experienceId).sorted()
                }).value.toEventually(equal([experienceId, "camp-goal-trigger"].sorted()), timeout: .seconds(2))
            }

            it("dispatches source goal-hit handlers before starting goal-triggered flows") { @MainActor in
                let ordering = OrderingRecorder()
                let orderingPresentationService = DismissingOrderingExperiencePresentationService(recorder: ordering)
                let sourceController = OrderingMockExperienceViewController(mockExperienceVersionId: flowId, recorder: ordering)
                orderingPresentationService.mockViewControllers[flowId] = sourceController
                orderingPresentationService.mockViewControllers["flow-goal-trigger"] =
                    MockExperienceViewController(mockExperienceVersionId: "flow-goal-trigger")
                service = mocks.makeJourneyService(
                    journeyStore: journeyStore,
                    experiencePresentation: orderingPresentationService
                )

                let goalHitFollowUp = JourneyEventHandler(
                    id: "goal-hit-follow-up",
                    eventName: JourneyEvents.journeyMilestone,
                    actions: [
                        .navigate(NavigateAction(screenId: "screen-2", transition: nil))
                    ]
                )
                let goalExperience = makeExperience(
                    id: "camp-goal-trigger",
                    flowId: "flow-goal-trigger",
                    trigger: .event(EventTriggerConfig(eventName: JourneyEvents.journeyMilestone, condition: nil)),
                    goal: nil,
                    exitPolicy: nil
                )
                let primaryExperience = makeExperience(goal: nil, exitPolicy: nil)
                let primaryFlow = makeLoadedExperience(handlers: [JourneyDocument.journeyEventHostKey: [goalHitFollowUp]])
                let goalFlow = makeLoadedExperience(flowId: "flow-goal-trigger")

                await primeProfile(
                    experiences: [primaryExperience, goalExperience],
                    packages: [primaryFlow, goalFlow]
                )
                await service.initialize()

                let journey = await startJourney()
                ordering.clear()

                await service.handleScopedMilestoneEvent(
                    journeyId: journey.id,
                    milestoneId: "signup_complete",
                    milestoneLabel: "Signed Up",
                    screenId: "screen-1"
                )

                await polling(expect {
                    ordering.events
                }).value.toEventually(equal(["navigate:screen-2", "dismiss-before-present", "present:flow-goal-trigger"]), timeout: .seconds(2))
            }

            it("primes newly started journeys from the tracked scoped goal event") {
                let goalExperience = makeExperience(
                    id: "camp-goal-triggered-complete",
                    flowId: "flow-goal-triggered-complete",
                    trigger: .event(EventTriggerConfig(eventName: JourneyEvents.journeyMilestone, condition: nil)),
                    goal: GoalConfig(kind: .event, eventName: JourneyEvents.journeyMilestone),
                    exitPolicy: ExitPolicy(mode: .onGoal)
                )
                let primaryExperience = makeExperience(goal: nil, exitPolicy: nil)
                let primaryFlow = makeLoadedExperience()
                let goalFlow = makeLoadedExperience(flowId: "flow-goal-triggered-complete")

                await primeProfile(
                    experiences: [primaryExperience, goalExperience],
                    packages: [primaryFlow, goalFlow]
                )
                await service.initialize()

                let journey = await startJourney()
                mocks.eventLog.trackForTriggerDelayNanoseconds = 200_000_000

                await service.handleScopedMilestoneEvent(
                    journeyId: journey.id,
                    milestoneId: "signup_complete",
                    milestoneLabel: "Signed Up",
                    screenId: "screen-1"
                )

                await polling(expect {
                    let matchingJourney = await service.getActiveJourneys(for: distinctId).first {
                        $0.experienceId == "camp-goal-triggered-complete"
                    }
                    return await matchingJourney?.snapshot().convertedAt
                }).value.toEventuallyNot(beNil(), timeout: .seconds(2))
            }

            it("dismisses the source flow before starting goal-triggered flows") {
                let goalExperience = makeExperience(
                    id: "camp-goal-trigger",
                    flowId: "flow-goal-trigger",
                    trigger: .event(EventTriggerConfig(eventName: JourneyEvents.journeyMilestone, condition: nil)),
                    goal: nil,
                    exitPolicy: nil
                )
                let primaryExperience = makeExperience(
                    goal: GoalConfig(kind: .event, eventName: JourneyEvents.journeyMilestone),
                    exitPolicy: ExitPolicy(mode: .onGoal)
                )
                let primaryFlow = makeLoadedExperience()
                let goalFlow = makeLoadedExperience(flowId: "flow-goal-trigger")

                await primeProfile(
                    experiences: [primaryExperience, goalExperience],
                    packages: [primaryFlow, goalFlow]
                )
                await service.initialize()

                let journey = await startJourney()

                await service.handleScopedMilestoneEvent(
                    journeyId: journey.id,
                    milestoneId: "signup_complete",
                    milestoneLabel: "Signed Up",
                    screenId: "screen-1"
                )

                await polling(expect {
                    await service.getActiveJourneys(for: distinctId).map(\.experienceId)
                }).value.toEventually(equal(["camp-goal-trigger"]), timeout: .seconds(2))
                await polling(expect {
                    await MainActor.run { [mocks = mocks!] in mocks.experiencePresentationService.dismissedExperiences.last }
                }).value.toEventually(equal(flowId), timeout: .seconds(2))
                await polling(expect {
                    await MainActor.run { [mocks = mocks!] in mocks.experiencePresentationService.presentedExperiences.last?.experienceVersionId }
                }).value.toEventually(equal("flow-goal-trigger"), timeout: .seconds(2))
            }

            it("feeds scoped goal actions into all active journeys for goal evaluation") {
                let primaryExperience = makeExperience(
                    id: "camp-primary-goal",
                    flowId: "flow-primary-goal",
                    goal: nil,
                    exitPolicy: nil
                )
                let secondaryExperience = makeExperience(
                    id: "camp-secondary-goal",
                    flowId: "flow-secondary-goal",
                    goal: GoalConfig(kind: .event, eventName: JourneyEvents.journeyMilestone),
                    exitPolicy: nil
                )

                await primeProfile(
                    experiences: [primaryExperience, secondaryExperience],
                    packages: [
                        makeLoadedExperience(flowId: "flow-primary-goal"),
                        makeLoadedExperience(flowId: "flow-secondary-goal"),
                    ]
                )
                await service.initialize()

                _ = await service.handleEventForTrigger(
                    NuxieEvent(id: "evt_goal_scope", name: "paywall_trigger", distinctId: distinctId)
                )

                let activeJourneys = await service.getActiveJourneys(for: distinctId)
                let primaryJourney = activeJourneys.first(where: { $0.experienceId == "camp-primary-goal" })
                let secondaryJourney = activeJourneys.first(where: { $0.experienceId == "camp-secondary-goal" })
                expect(primaryJourney).toNot(beNil())
                let secondaryConvertedAt = await convertedAt(of: secondaryJourney)
                expect(secondaryConvertedAt).to(beNil())

                await service.handleScopedMilestoneEvent(
                    journeyId: primaryJourney!.id,
                    milestoneId: "signup_complete",
                    milestoneLabel: "Signed Up",
                    screenId: "screen-1"
                )

                await polling(expect {
                    let matchingJourney = await service.getActiveJourneys(for: distinctId).first {
                        $0.id == secondaryJourney?.id
                    }
                    return await convertedAt(of: matchingJourney)
                }).value.toEventuallyNot(beNil(), timeout: .seconds(2))
            }

            it("re-evaluates sibling goal exits while another flow stays presented") {
                let primaryExperience = makeExperience(
                    id: "camp-primary-presented",
                    flowId: "flow-primary-presented",
                    goal: nil,
                    exitPolicy: nil
                )
                let siblingExperience = makeExperience(
                    id: "camp-sibling-goal",
                    flowId: "flow-sibling-goal",
                    goal: GoalConfig(kind: .event, eventName: JourneyEvents.journeyMilestone),
                    exitPolicy: ExitPolicy(mode: .onGoal)
                )

                await primeProfile(
                    experiences: [primaryExperience, siblingExperience],
                    packages: [
                        makeLoadedExperience(flowId: "flow-primary-presented"),
                        makeLoadedExperience(flowId: "flow-sibling-goal"),
                    ]
                )

                var siblingJourney = JourneySnapshot(experience: siblingExperience, distinctId: distinctId, now: mocks.dateProvider.now())
                siblingJourney.status = .active
                try? journeyStore.saveJourney(siblingJourney)

                await service.initialize()

                let primaryJourney = await service.startJourney(
                    for: primaryExperience,
                    distinctId: distinctId
                )
                expect(primaryJourney).toNot(beNil())

                await service.handleScopedMilestoneEvent(
                    journeyId: primaryJourney!.id,
                    milestoneId: "signup_complete",
                    milestoneLabel: "Signed Up",
                    screenId: "screen-1"
                )

                await polling(expect {
                    await service.getActiveJourneys(for: distinctId).map(\.experienceId).sorted()
                }).value.toEventually(equal(["camp-primary-presented"]), timeout: .seconds(2))
                await polling(expect {
                    journeyStore.getCompletions(for: distinctId).first(where: {
                        $0.journeyId == siblingJourney.id
                    })?.exitReason
                }).value.toEventually(equal(.goalMet), timeout: .seconds(2))
            }

            it("re-evaluates sibling goal exits from journey snapshots after the cache expires") {
                let primaryExperience = makeExperience(
                    id: "camp-primary-stale",
                    flowId: "flow-primary-stale",
                    goal: nil,
                    exitPolicy: nil
                )
                let siblingExperience = makeExperience(
                    id: "camp-sibling-stale",
                    flowId: "flow-sibling-stale",
                    goal: GoalConfig(kind: .event, eventName: JourneyEvents.journeyMilestone),
                    exitPolicy: ExitPolicy(mode: .onGoal)
                )

                await primeProfile(
                    experiences: [primaryExperience, siblingExperience],
                    packages: [
                        makeLoadedExperience(flowId: "flow-primary-stale"),
                        makeLoadedExperience(flowId: "flow-sibling-stale"),
                    ]
                )

                var siblingJourney = JourneySnapshot(experience: siblingExperience, distinctId: distinctId, now: mocks.dateProvider.now())
                siblingJourney.status = .active
                try? journeyStore.saveJourney(siblingJourney)

                await service.initialize()

                let primaryJourney = await service.startJourney(
                    for: primaryExperience,
                    distinctId: distinctId
                )
                expect(primaryJourney).toNot(beNil())

                await mocks.profileService.clearCache(distinctId: distinctId)

                await service.handleScopedMilestoneEvent(
                    journeyId: primaryJourney!.id,
                    milestoneId: "signup_complete",
                    milestoneLabel: "Signed Up",
                    screenId: "screen-1"
                )

                await polling(expect {
                    await service.getActiveJourneys(for: distinctId).map(\.experienceId).sorted()
                }).value.toEventually(equal(["camp-primary-stale"]), timeout: .seconds(2))
                await polling(expect {
                    journeyStore.getCompletions(for: distinctId).first(where: {
                        $0.journeyId == siblingJourney.id
                    })?.exitReason
                }).value.toEventually(equal(.goalMet), timeout: .seconds(2))
            }

            it("dispatches goal-hit triggers into sibling runners after the cache expires") {
                let siblingFollowUp = JourneyEventHandler(
                    id: "goal-hit-sibling-follow-up",
                    eventName: JourneyEvents.journeyMilestone,
                    actions: [
                        .sendEvent(
                            SendEventAction(
                                eventName: "sibling_follow_up",
                                properties: nil
                            )
                        )
                    ]
                )
                let primaryExperience = makeExperience(
                    id: "camp-primary-sibling-dispatch",
                    flowId: "flow-primary-sibling-dispatch",
                    goal: nil,
                    exitPolicy: nil
                )
                let siblingExperience = makeExperience(
                    id: "camp-sibling-dispatch",
                    flowId: "flow-sibling-dispatch",
                    goal: nil,
                    exitPolicy: nil
                )

                await primeProfile(
                    experiences: [primaryExperience, siblingExperience],
                    packages: [
                        makeLoadedExperience(flowId: "flow-primary-sibling-dispatch"),
                        makeLoadedExperience(
                            flowId: "flow-sibling-dispatch",
                            handlers: [JourneyDocument.journeyEventHostKey: [siblingFollowUp]]
                        ),
                    ]
                )
                await service.initialize()

                let primaryJourney = await service.startJourney(
                    for: primaryExperience,
                    distinctId: distinctId
                )
                let siblingJourney = await service.startJourney(
                    for: siblingExperience,
                    distinctId: distinctId
                )
                expect(primaryJourney).toNot(beNil())
                expect(siblingJourney).toNot(beNil())

                await mocks.profileService.clearCache(distinctId: distinctId)

                await service.handleScopedMilestoneEvent(
                    journeyId: primaryJourney!.id,
                    milestoneId: "signup_complete",
                    milestoneLabel: "Signed Up",
                    screenId: "screen-1"
                )

                await polling(expect {
                    mocks.eventLog.trackedEvents.map(\.name)
                }).value.toEventually(contain("sibling_follow_up"), timeout: .seconds(2))
            }

            it("replays scoped notification outcomes into newly started journeys") {
                let notificationExperience = makeExperience(
                    id: "camp-notifications-replay",
                    flowId: "flow-notifications-replay",
                    trigger: .event(EventTriggerConfig(eventName: SystemEventNames.notificationsEnabled, condition: nil)),
                    goal: GoalConfig(
                        kind: .event,
                        eventName: SystemEventNames.notificationsEnabled,
                        eventFilter: nil,
                        window: 60
                    ),
                    exitPolicy: ExitPolicy(mode: .onGoal)
                )
                let primaryExperience = makeExperience(goal: nil, exitPolicy: nil)
                let primaryFlow = makeLoadedExperience()
                let notificationFlow = makeLoadedExperience(flowId: "flow-notifications-replay")

                await primeProfile(
                    experiences: [primaryExperience, notificationExperience],
                    packages: [primaryFlow, notificationFlow]
                )
                await service.initialize()

                let journey = await startJourney()

                await MainActor.run { [controller = controller!] in
                    (controller.runtimeDelegate as? NotificationPermissionEventReceiver)?.experienceViewController(
                        controller,
                        didResolveNotificationPermissionEvent: SystemEventNames.notificationsEnabled,
                        properties: ["journey_id": journey.id],
                        journeyId: journey.id
                    )
                }

                await polling(expect {
                    let matchingJourney = await service.getActiveJourneys(for: distinctId).first {
                        $0.experienceId == "camp-notifications-replay"
                    }
                    return await convertedAt(of: matchingJourney)
                }).value.toEventuallyNot(beNil(), timeout: .seconds(2))
            }

            it("replays scoped tracking outcomes into newly started journeys") {
                let trackingExperience = makeExperience(
                    id: "camp-tracking-replay",
                    flowId: "flow-tracking-replay",
                    trigger: .event(EventTriggerConfig(eventName: SystemEventNames.trackingAuthorized, condition: nil)),
                    goal: GoalConfig(
                        kind: .event,
                        eventName: SystemEventNames.trackingAuthorized,
                        eventFilter: nil,
                        window: 60
                    ),
                    exitPolicy: ExitPolicy(mode: .onGoal)
                )
                let primaryExperience = makeExperience(goal: nil, exitPolicy: nil)
                let primaryFlow = makeLoadedExperience()
                let trackingFlow = makeLoadedExperience(flowId: "flow-tracking-replay")

                await primeProfile(
                    experiences: [primaryExperience, trackingExperience],
                    packages: [primaryFlow, trackingFlow]
                )
                await service.initialize()

                let journey = await startJourney()

                await MainActor.run { [controller = controller!] in
                    (controller.runtimeDelegate as? TrackingPermissionEventReceiver)?.experienceViewController(
                        controller,
                        didResolveTrackingPermissionEvent: SystemEventNames.trackingAuthorized,
                        properties: ["journey_id": journey.id],
                        journeyId: journey.id
                    )
                }

                await polling(expect {
                    let matchingJourney = await service.getActiveJourneys(for: distinctId).first {
                        $0.experienceId == "camp-tracking-replay"
                    }
                    return await convertedAt(of: matchingJourney)
                }).value.toEventuallyNot(beNil(), timeout: .seconds(2))
            }

            it("replays unsupported scoped tracking outcomes into newly started journeys") {
                let trackingExperience = makeExperience(
                    id: "camp-tracking-denied-replay",
                    flowId: "flow-tracking-denied-replay",
                    trigger: .event(EventTriggerConfig(eventName: SystemEventNames.trackingDenied, condition: nil)),
                    goal: GoalConfig(
                        kind: .event,
                        eventName: SystemEventNames.trackingDenied,
                        eventFilter: nil,
                        window: 60
                    ),
                    exitPolicy: ExitPolicy(mode: .onGoal)
                )
                let primaryExperience = makeExperience(goal: nil, exitPolicy: nil)
                let primaryFlow = makeLoadedExperience(
                    handlers: pressHandlers([
                        .requestTracking(RequestTrackingAction())
                    ])
                )
                let trackingFlow = makeLoadedExperience(flowId: "flow-tracking-denied-replay")

                await primeProfile(
                    experiences: [primaryExperience, trackingExperience],
                    packages: [primaryFlow, trackingFlow]
                )
                await service.initialize()

                _ = await startJourney()
                await MainActor.run { [controller = controller!] in
                    controller.trackingAuthorizationHandler = UnsupportedTrackingAuthorizationHandler()
                    emitScreenPress(controller)
                }

                await polling(expect {
                    let matchingJourney = await service.getActiveJourneys(for: distinctId).first {
                        $0.experienceId == "camp-tracking-denied-replay"
                    }
                    return await convertedAt(of: matchingJourney)
                }).value.toEventuallyNot(beNil(), timeout: .seconds(2))
            }

            it("completes dismissed journeys after unsupported tracking requests") {
                let experience = makeExperience(goal: nil, exitPolicy: nil)
                let flow = makeLoadedExperience(
                    handlers: pressHandlers([
                        .requestTracking(RequestTrackingAction())
                    ])
                )
                await primeProfile(experience: experience, package: flow)
                await service.initialize()

                let journey = await startJourney()
                await MainActor.run { [controller = controller!] in
                    controller.trackingAuthorizationHandler = UnsupportedTrackingAuthorizationHandler()
                }

                await MainActor.run { [controller = controller!] in
                    emitScreenPress(controller)
                }

                try? await Task.sleep(nanoseconds: 50_000_000)

                await MainActor.run { [controller = controller!] in
                    controller.runtimeDelegate?.experienceViewControllerDidRequestDismiss(
                        controller,
                        reason: .userDismissed
                    )
                }

                await polling(expect {
                    await service.getActiveJourneys(for: distinctId).contains { $0.id == journey.id }
                }).value.toEventually(beFalse(), timeout: .seconds(2))

                await polling(expect {
                    journeyStore.getCompletions(for: distinctId).last?.exitReason
                }).value.toEventually(equal(.dismissed), timeout: .seconds(2))
            }

            it("does not defer dismissals for non-permission pending work") {
                let experience = makeExperience(goal: nil, exitPolicy: nil)
                let flow = makeLoadedExperience()
                await primeProfile(experience: experience, package: flow)
                await service.initialize()

                let journey = await startJourney()
                await journey.update { $0.executionState.pendingAction = JourneyPendingAction(
                    handlerId: "wait-generic-dismiss",
                    screenId: nil,
                    componentId: nil,
                    actionIndex: 0,
                    kind: .waitUntil,
                    resumeAt: nil,
                    condition: nil,
                    maxTimeMs: nil,
                    startedAt: Date(),
                    resumeActions: [.exit(ExitAction(reason: "completed"))]
                ) }

                await MainActor.run { [controller = controller!] in
                    controller.runtimeDelegate?.experienceViewControllerDidRequestDismiss(
                        controller,
                        reason: .userDismissed
                    )
                }

                await polling(expect {
                    await service.getActiveJourneys(for: distinctId).contains { $0.id == journey.id }
                }).value.toEventually(beFalse(), timeout: .seconds(2))

                await polling(expect {
                    journeyStore.getCompletions(for: distinctId)
                        .first(where: { $0.journeyId == journey.id })?.exitReason
                }).value.toEventually(equal(.dismissed), timeout: .seconds(2))
            }

            it("completes deferred dismissals after scoped tracking outcomes resolve") {
                let experience = makeExperience(goal: nil, exitPolicy: nil)
                let flow = makeLoadedExperience(
                    handlers: pressHandlers([
                        .requestTracking(RequestTrackingAction())
                    ])
                )
                await primeProfile(experience: experience, package: flow)
                await service.initialize()

                let journey = await startJourney()
                mocks.eventLog.trackForTriggerDelayNanoseconds = 750_000_000

                await MainActor.run { [controller = controller!] in
                    controller.trackingAuthorizationHandler = DelayedTrackingAuthorizationHandler(
                        delayNanoseconds: 100_000_000,
                        result: .authorized
                    )
                    emitScreenPress(controller)
                    controller.runtimeDelegate?.experienceViewControllerDidRequestDismiss(
                        controller,
                        reason: .userDismissed
                    )
                }

                await polling(expect {
                    await service.getActiveJourneys(for: distinctId).contains { $0.id == journey.id }
                }).value.toEventually(beFalse(), timeout: .milliseconds(500))

                await polling(expect {
                    journeyStore.getCompletions(for: distinctId)
                        .first(where: { $0.journeyId == journey.id })?.exitReason
                }).value.toEventually(equal(.dismissed), timeout: .milliseconds(500))

                try? await Task.sleep(nanoseconds: 800_000_000)
            }

            it("completes dismissed journeys after unsupported request permission kinds") {
                let experience = makeExperience(goal: nil, exitPolicy: nil)
                let flow = makeLoadedExperience(
                    handlers: pressHandlers([
                        .requestPermission(RequestPermissionAction(permissionType: "location_always"))
                    ])
                )
                await primeProfile(experience: experience, package: flow)
                await service.initialize()

                let journey = await startJourney()

                await MainActor.run { [controller = controller!] in
                    emitScreenPress(controller)
                }

                try? await Task.sleep(nanoseconds: 50_000_000)

                await MainActor.run { [controller = controller!] in
                    controller.runtimeDelegate?.experienceViewControllerDidRequestDismiss(
                        controller,
                        reason: .userDismissed
                    )
                }

                await polling(expect {
                    await service.getActiveJourneys(for: distinctId).contains { $0.id == journey.id }
                }).value.toEventually(beFalse(), timeout: .milliseconds(500))

                await polling(expect {
                    journeyStore.getCompletions(for: distinctId)
                        .first(where: { $0.journeyId == journey.id })?.exitReason
                }).value.toEventually(equal(.dismissed), timeout: .milliseconds(500))
            }

            it("keeps deferred dismiss waiting when another request permission is still pending") {
                let experience = makeExperience(goal: nil, exitPolicy: nil)
                let flow = makeLoadedExperience(
                    handlers: pressHandlers([
                        .requestPermission(RequestPermissionAction(permissionType: "location_always")),
                        .requestPermission(RequestPermissionAction(permissionType: "camera"))
                    ])
                )
                await primeProfile(experience: experience, package: flow)
                await service.initialize()

                let journey = await startJourney()

                await MainActor.run { [controller = controller!] in
                    controller.cameraPermissionAuthorizationHandler = DelayedRequestPermissionAuthorizationHandler(
                        initialStatus: .notDetermined,
                        delayNanoseconds: 200_000_000,
                        result: .granted
                    )
                    controller.cameraUsageDescriptionProvider = { "Camera usage description" }
                    emitScreenPress(controller)
                }

                try? await Task.sleep(nanoseconds: 50_000_000)

                await MainActor.run { [controller = controller!] in
                    controller.runtimeDelegate?.experienceViewControllerDidRequestDismiss(
                        controller,
                        reason: .userDismissed
                    )
                }

                try? await Task.sleep(nanoseconds: 75_000_000)
                let isStillActive = await service.getActiveJourneys(for: distinctId).contains { $0.id == journey.id }
                expect(isStillActive).to(beTrue())

                await polling(expect {
                    await service.getActiveJourneys(for: distinctId).contains { $0.id == journey.id }
                }).value.toEventually(beFalse(), timeout: .seconds(2))

                await polling(expect {
                    journeyStore.getCompletions(for: distinctId)
                        .first(where: { $0.journeyId == journey.id })?.exitReason
                }).value.toEventually(equal(.dismissed), timeout: .seconds(2))
            }

            it("resumes wait_until work on unsupported tracking requests") {
                let experience = makeExperience(goal: nil, exitPolicy: nil)
                let flow = makeLoadedExperience(
                    handlers: pressHandlers([
                        .requestTracking(RequestTrackingAction())
                    ])
                )
                await primeProfile(experience: experience, package: flow)
                await service.initialize()

                let journey = await startJourney()
                await journey.update { $0.executionState.pendingAction = JourneyPendingAction(
                    handlerId: "wait-unsupported-tracking",
                    screenId: nil,
                    componentId: nil,
                    actionIndex: 0,
                    kind: .waitUntil,
                    resumeAt: nil,
                    condition: nil,
                    maxTimeMs: nil,
                    startedAt: Date(),
                    resumeActions: [.exit(ExitAction(reason: "completed"))]
                ) }

                await MainActor.run { [controller = controller!] in
                    controller.trackingAuthorizationHandler = UnsupportedTrackingAuthorizationHandler()
                    emitScreenPress(controller)
                }

                await polling(expect {
                    journeyStore.getCompletions(for: distinctId)
                        .first(where: { $0.journeyId == journey.id })?.exitReason
                }).value.toEventually(equal(.completed), timeout: .seconds(2))
            }

            it("tracks scoped notification outcomes against the original user across identify races") {
                let experience = makeExperience(goal: nil, exitPolicy: nil)
                let flow = makeLoadedExperience()
                await primeProfile(experience: experience, package: flow)
                await service.initialize()

                let journey = await startJourney()
                mocks.identityService.setDistinctId("user_2")

                await MainActor.run { [controller = controller!] in
                    (controller.runtimeDelegate as? NotificationPermissionEventReceiver)?.experienceViewController(
                        controller,
                        didResolveNotificationPermissionEvent: SystemEventNames.notificationsEnabled,
                        properties: ["journey_id": journey.id],
                        journeyId: journey.id
                    )
                }

                await polling(expect {
                    mocks.eventLog.trackForTriggerCalls.last?.distinctIdOverride
                }).value.toEventually(equal(distinctId), timeout: .seconds(2))
            }

            it("still tracks scoped notification outcomes after the original journey is cancelled") {
                let experience = makeExperience(goal: nil, exitPolicy: nil)
                let flow = makeLoadedExperience()
                await primeProfile(experience: experience, package: flow)
                await service.initialize()

                let journey = await startJourney()
                await service.handleUserChange(from: distinctId, to: "user_2")

                await MainActor.run { [controller = controller!] in
                    (controller.runtimeDelegate as? NotificationPermissionEventReceiver)?.experienceViewController(
                        controller,
                        didResolveNotificationPermissionEvent: SystemEventNames.notificationsEnabled,
                        properties: ["journey_id": journey.id],
                        journeyId: journey.id
                    )
                }

                await polling(expect {
                    mocks.eventLog.trackForTriggerCalls.last?.distinctIdOverride
                }).value.toEventually(equal(distinctId), timeout: .seconds(2))
            }

            it("tracks unsupported scoped tracking outcomes against the original user across identify races") {
                let experience = makeExperience(goal: nil, exitPolicy: nil)
                let flow = makeLoadedExperience(
                    handlers: pressHandlers([
                        .requestTracking(RequestTrackingAction())
                    ])
                )
                await primeProfile(experience: experience, package: flow)
                await service.initialize()

                _ = await startJourney()
                mocks.identityService.setDistinctId("user_2")

                await MainActor.run { [controller = controller!] in
                    controller.trackingAuthorizationHandler = UnsupportedTrackingAuthorizationHandler()
                    emitScreenPress(controller)
                }

                await polling(expect {
                    mocks.eventLog.trackForTriggerCalls.last?.distinctIdOverride
                }).value.toEventually(equal(distinctId), timeout: .seconds(2))
            }

            it("tracks unsupported scoped request permission outcomes against the original user across identify races") {
                let experience = makeExperience(goal: nil, exitPolicy: nil)
                let flow = makeLoadedExperience(
                    handlers: pressHandlers([
                        .requestPermission(RequestPermissionAction(permissionType: "camera"))
                    ])
                )
                await primeProfile(experience: experience, package: flow)
                await service.initialize()

                _ = await startJourney()
                mocks.identityService.setDistinctId("user_2")

                await MainActor.run { [controller = controller!] in
                    controller.cameraPermissionAuthorizationHandler = UnsupportedRequestPermissionAuthorizationHandler()
                    emitScreenPress(controller)
                }

                await polling(expect {
                    mocks.eventLog.trackForTriggerCalls.last?.distinctIdOverride
                }).value.toEventually(equal(distinctId), timeout: .seconds(2))
            }

            it("resumes wait_until work on scoped notification outcomes") {
                let experience = makeExperience(goal: nil, exitPolicy: nil)
                let flow = makeLoadedExperience()
                await primeProfile(experience: experience, package: flow)
                await service.initialize()

                let journey = await startJourney()
                await journey.update { $0.executionState.pendingAction = JourneyPendingAction(
                    handlerId: "wait-notifications",
                    screenId: nil,
                    componentId: nil,
                    actionIndex: 0,
                    kind: .waitUntil,
                    resumeAt: nil,
                    condition: nil,
                    maxTimeMs: nil,
                    startedAt: Date(),
                    resumeActions: [.exit(ExitAction(reason: "completed"))]
                ) }

                await MainActor.run { [controller = controller!] in
                    (controller.runtimeDelegate as? NotificationPermissionEventReceiver)?.experienceViewController(
                        controller,
                        didResolveNotificationPermissionEvent: SystemEventNames.notificationsEnabled,
                        properties: ["journey_id": journey.id],
                        journeyId: journey.id
                    )
                }

                await polling(expect {
                    journeyStore.getCompletions(for: distinctId).last?.exitReason
                }).value.toEventually(equal(.completed), timeout: .seconds(2))
            }

            it("resumes wait_until work on scoped tracking outcomes") {
                let experience = makeExperience(goal: nil, exitPolicy: nil)
                let flow = makeLoadedExperience()
                await primeProfile(experience: experience, package: flow)
                await service.initialize()

                let journey = await startJourney()
                await journey.update { $0.executionState.pendingAction = JourneyPendingAction(
                    handlerId: "wait-tracking",
                    screenId: nil,
                    componentId: nil,
                    actionIndex: 0,
                    kind: .waitUntil,
                    resumeAt: nil,
                    condition: nil,
                    maxTimeMs: nil,
                    startedAt: Date(),
                    resumeActions: [.exit(ExitAction(reason: "completed"))]
                ) }

                await MainActor.run { [controller = controller!] in
                    (controller.runtimeDelegate as? TrackingPermissionEventReceiver)?.experienceViewController(
                        controller,
                        didResolveTrackingPermissionEvent: SystemEventNames.trackingAuthorized,
                        properties: ["journey_id": journey.id],
                        journeyId: journey.id
                    )
                }

                await polling(expect {
                    journeyStore.getCompletions(for: distinctId).last?.exitReason
                }).value.toEventually(equal(.completed), timeout: .seconds(2))
            }

            it("resumes wait_until work on scoped request permission outcomes") {
                let experience = makeExperience(goal: nil, exitPolicy: nil)
                let flow = makeLoadedExperience()
                await primeProfile(experience: experience, package: flow)
                await service.initialize()

                let journey = await startJourney()
                await journey.update { $0.executionState.pendingAction = JourneyPendingAction(
                    handlerId: "wait-permission",
                    screenId: nil,
                    componentId: nil,
                    actionIndex: 0,
                    kind: .waitUntil,
                    resumeAt: nil,
                    condition: nil,
                    maxTimeMs: nil,
                    startedAt: Date(),
                    resumeActions: [.exit(ExitAction(reason: "completed"))]
                ) }

                await MainActor.run { [controller = controller!] in
                    (controller.runtimeDelegate as? RequestPermissionEventReceiver)?.experienceViewController(
                        controller,
                        didResolveRequestPermissionEvent: SystemEventNames.permissionGranted,
                        properties: [
                            "journey_id": journey.id,
                            "type": "camera"
                        ],
                        journeyId: journey.id
                    )
                }

                await polling(expect {
                    journeyStore.getCompletions(for: distinctId).last?.exitReason
                }).value.toEventually(equal(.completed), timeout: .seconds(2))
            }

            it("resumes wait_until work on unsupported request permission kinds") {
                let experience = makeExperience(goal: nil, exitPolicy: nil)
                let flow = makeLoadedExperience()
                await primeProfile(experience: experience, package: flow)
                await service.initialize()

                let journey = await startJourney()
                await journey.update { $0.executionState.pendingAction = JourneyPendingAction(
                    handlerId: "wait-unsupported-permission",
                    screenId: nil,
                    componentId: nil,
                    actionIndex: 0,
                    kind: .waitUntil,
                    resumeAt: nil,
                    condition: nil,
                    maxTimeMs: nil,
                    startedAt: Date(),
                    resumeActions: [.exit(ExitAction(reason: "completed"))]
                ) }

                await MainActor.run { [controller = controller!] in
                    (controller.runtimeDelegate as? RequestPermissionEventReceiver)?.experienceViewController(
                        controller,
                        didIgnoreUnsupportedRequestPermissionType: "location_always",
                        journeyId: journey.id
                    )
                }

                await polling(expect {
                    journeyStore.getCompletions(for: distinctId).last?.exitReason
                }).value.toEventually(equal(.completed), timeout: .seconds(2))
            }

            it("honors gate plans from unsupported scoped request permission outcomes") {
                let orderingPresentationService = OrderingExperiencePresentationService(recorder: OrderingRecorder())
                orderingPresentationService.defaultMockViewController = controller
                service = mocks.makeJourneyService(
                    journeyStore: journeyStore,
                    experiencePresentation: orderingPresentationService
                )

                let experience = makeExperience(goal: nil, exitPolicy: nil)
                let flow = makeLoadedExperience()
                await primeProfile(experience: experience, package: flow)
                await service.initialize()

                let journey = await startJourney()
                mocks.eventLog.trackWithResponseResult = makeGatePlanResponse(
                    decision: "show_flow",
                    flowId: "gate-flow"
                )

                await MainActor.run { [controller = controller!] in
                    (controller.runtimeDelegate as? RequestPermissionEventReceiver)?.experienceViewController(
                        controller,
                        didIgnoreUnsupportedRequestPermissionType: "location_always",
                        journeyId: journey.id
                    )
                }

                await polling(expect {
                    await MainActor.run {
                        orderingPresentationService.wasExperiencePresented("gate-flow")
                    }
                }).value.toEventually(beTrue(), timeout: .seconds(2))
            }

            it("honors gate plans from scoped goal actions") {
                let orderingPresentationService = OrderingExperiencePresentationService(recorder: OrderingRecorder())
                orderingPresentationService.defaultMockViewController = controller
                service = mocks.makeJourneyService(
                    journeyStore: journeyStore,
                    experiencePresentation: orderingPresentationService
                )

                let experience = makeExperience(goal: nil, exitPolicy: nil)
                let flow = makeLoadedExperience()
                await primeProfile(experience: experience, package: flow)
                await service.initialize()

                let journey = await startJourney()
                mocks.eventLog.trackWithResponseResult = makeGatePlanResponse(
                    decision: "show_flow",
                    flowId: "gate-flow"
                )

                await service.handleScopedMilestoneEvent(
                    journeyId: journey.id,
                    milestoneId: "signup_complete",
                    milestoneLabel: "Signed Up",
                    screenId: "screen-1"
                )

                await polling(expect {
                    await MainActor.run {
                        orderingPresentationService.wasExperiencePresented("gate-flow")
                    }
                }).value.toEventually(beTrue(), timeout: .seconds(2))
            }

            it("closes the source journey before presenting goal gate-plan flows") {
                let ordering = OrderingRecorder()
                let orderingStore = OrderingJourneyStore(recorder: ordering)
                let orderingPresentationService = OrderingExperiencePresentationService(recorder: ordering)
                orderingPresentationService.defaultMockViewController = controller
                service = mocks.makeJourneyService(
                    journeyStore: orderingStore,
                    experiencePresentation: orderingPresentationService
                )
                journeyStore = orderingStore

                let experience = makeExperience(goal: nil, exitPolicy: nil)
                let flow = makeLoadedExperience()
                await primeProfile(experience: experience, package: flow)
                await service.initialize()

                let journey = await startJourney()
                mocks.eventLog.trackWithResponseResult = makeGatePlanResponse(
                    decision: "show_flow",
                    flowId: "gate-flow"
                )

                ordering.clear()

                await service.handleScopedMilestoneEvent(
                    journeyId: journey.id,
                    milestoneId: "signup_complete",
                    milestoneLabel: "Signed Up",
                    screenId: "screen-1"
                )

                await polling(expect {
                    ordering.events
                }).value.toEventually(equal(["complete:\(experienceId)", "present:gate-flow"]), timeout: .seconds(2))
                await polling(expect {
                    await service.getActiveJourneys(for: distinctId).isEmpty
                }).value.toEventually(beTrue(), timeout: .seconds(2))
            }

            it("resumes wait_until work before scoped notification tracking returns") {
                let experience = makeExperience(goal: nil, exitPolicy: nil)
                let flow = makeLoadedExperience()
                await primeProfile(experience: experience, package: flow)
                await service.initialize()

                let journey = await startJourney()
                await journey.update { $0.executionState.pendingAction = JourneyPendingAction(
                    handlerId: "wait-notifications",
                    screenId: nil,
                    componentId: nil,
                    actionIndex: 0,
                    kind: .waitUntil,
                    resumeAt: nil,
                    condition: nil,
                    maxTimeMs: nil,
                    startedAt: Date(),
                    resumeActions: [.exit(ExitAction(reason: "completed"))]
                ) }
                mocks.eventLog.trackForTriggerDelayNanoseconds = 750_000_000

                await MainActor.run { [controller = controller!] in
                    (controller.runtimeDelegate as? NotificationPermissionEventReceiver)?.experienceViewController(
                        controller,
                        didResolveNotificationPermissionEvent: SystemEventNames.notificationsEnabled,
                        properties: ["journey_id": journey.id],
                        journeyId: journey.id
                    )
                }

                await polling(expect {
                    journeyStore.getCompletions(for: distinctId).last?.exitReason
                }).value.toEventually(equal(.completed), timeout: .milliseconds(250))

                try? await Task.sleep(nanoseconds: 800_000_000)
            }

            it("uses enriched scoped notification properties during immediate local goal evaluation") {
                let sessionService = MockSessionService()
                sessionService.setSessionId("session-notification")
                mocks.eventLog.sessions = sessionService

                let notificationGoal = GoalConfig(
                    kind: .event,
                    eventName: SystemEventNames.notificationsEnabled,
                    eventFilter: IREnvelope(
                        ir_version: 1,
                        engine_min: nil,
                        compiled_at: nil,
                        expr: .pred(
                            op: "eq",
                            key: "properties.$session_id",
                            value: .string("session-notification")
                        )
                    ),
                    window: 60
                )
                let experience = makeExperience(
                    id: "camp-session-filter",
                    flowId: "flow-session-filter",
                    goal: notificationGoal,
                    exitPolicy: nil
                )

                await primeProfile(
                    experiences: [experience],
                    packages: [makeLoadedExperience(flowId: "flow-session-filter")]
                )
                await service.initialize()

                let journey = await startJourney()
                // The delayed track is the discriminator: conversion must land
                // from the IMMEDIATE local goal evaluation (enriched
                // properties), well before the delayed track's evaluation
                // could. 2s delay vs 750ms window keeps that discrimination
                // with scheduling slack (Swift 6 executors made 250ms flaky).
                mocks.eventLog.trackForTriggerDelayNanoseconds = 2_000_000_000

                await MainActor.run { [controller = controller!] in
                    (controller.runtimeDelegate as? NotificationPermissionEventReceiver)?.experienceViewController(
                        controller,
                        didResolveNotificationPermissionEvent: SystemEventNames.notificationsEnabled,
                        properties: ["journey_id": journey.id],
                        journeyId: journey.id
                    )
                }

                await polling(expect {
                    let matchingJourney = await service.getActiveJourneys(for: distinctId).first {
                        $0.id == journey.id
                    }
                    return await convertedAt(of: matchingJourney)
                }).value.toEventuallyNot(beNil(), timeout: .milliseconds(750))

                try? await Task.sleep(nanoseconds: 2_100_000_000)
            }

            it("feeds scoped notification outcomes into all active journeys for goal evaluation") {
                let notificationGoal = GoalConfig(
                    kind: .event,
                    eventName: SystemEventNames.notificationsEnabled,
                    eventFilter: nil,
                    window: 60
                )
                let primaryExperience = makeExperience(
                    id: "camp-primary",
                    flowId: "flow-primary",
                    goal: nil,
                    exitPolicy: nil
                )
                let secondaryExperience = makeExperience(
                    id: "camp-secondary",
                    flowId: "flow-secondary",
                    goal: notificationGoal,
                    exitPolicy: nil
                )

                await primeProfile(
                    experiences: [primaryExperience, secondaryExperience],
                    packages: [
                        makeLoadedExperience(flowId: "flow-primary"),
                        makeLoadedExperience(flowId: "flow-secondary"),
                    ]
                )
                await service.initialize()

                _ = await service.handleEventForTrigger(
                    NuxieEvent(id: "evt_origin", name: "paywall_trigger", distinctId: distinctId)
                )

                let activeJourneys = await service.getActiveJourneys(for: distinctId)
                let primaryJourney = activeJourneys.first(where: { $0.experienceId == "camp-primary" })
                let secondaryJourney = activeJourneys.first(where: { $0.experienceId == "camp-secondary" })
                expect(primaryJourney).toNot(beNil())
                let secondaryConvertedAt = await convertedAt(of: secondaryJourney)
                expect(secondaryConvertedAt).to(beNil())

                await MainActor.run { [controller = controller!] in
                    (controller.runtimeDelegate as? NotificationPermissionEventReceiver)?.experienceViewController(
                        controller,
                        didResolveNotificationPermissionEvent: SystemEventNames.notificationsEnabled,
                        properties: ["journey_id": primaryJourney!.id],
                        journeyId: primaryJourney!.id
                    )
                }

                await polling(expect {
                    let matchingJourney = await service.getActiveJourneys(for: distinctId).first {
                        $0.experienceId == "camp-secondary"
                    }
                    return await convertedAt(of: matchingJourney)
                }).value.toEventuallyNot(beNil(), timeout: .seconds(2))
            }

            it("feeds scoped notification outcomes into mixed attribute goals") {
                let notificationGoal = GoalConfig(
                    kind: .attribute,
                    attributeExpr: IREnvelope(
                        ir_version: 1,
                        engine_min: nil,
                        compiled_at: nil,
                        expr: .and([
                            .eventsExists(
                                name: SystemEventNames.notificationsEnabled,
                                since: nil,
                                until: nil,
                                within: nil,
                                where_: .pred(
                                    op: "eq",
                                    key: "journey_id",
                                    value: .journeyId
                                )
                            ),
                            .user(op: "eq", key: "plan", value: .string("pro"))
                        ])
                    ),
                    window: 60
                )
                let experience = makeExperience(
                    id: "camp-mixed",
                    flowId: "flow-mixed",
                    goal: notificationGoal,
                    exitPolicy: nil
                )

                await primeProfile(
                    experiences: [experience],
                    packages: [makeLoadedExperience(flowId: "flow-mixed")]
                )
                await service.initialize()
                mocks.identityService.setUserProperty("plan", value: "pro")

                let journey = await startJourney()
                let initialConvertedAt = await convertedAt(of: journey)
                expect(initialConvertedAt).to(beNil())

                await MainActor.run { [controller = controller!] in
                    (controller.runtimeDelegate as? NotificationPermissionEventReceiver)?.experienceViewController(
                        controller,
                        didResolveNotificationPermissionEvent: SystemEventNames.notificationsEnabled,
                        properties: ["journey_id": journey.id],
                        journeyId: journey.id
                    )
                }

                await polling(expect {
                    let matchingJourney = await service.getActiveJourneys(for: distinctId).first {
                        $0.id == journey.id
                    }
                    return await convertedAt(of: matchingJourney)
                }).value.toEventuallyNot(beNil(), timeout: .seconds(2))
            }

            it("processes active journeys before presenting scoped gate flows") {
                let ordering = OrderingRecorder()
                let orderingStore = OrderingJourneyStore(recorder: ordering)
                let orderingPresentationService = OrderingExperiencePresentationService(recorder: ordering)
                orderingPresentationService.defaultMockViewController = controller
                service = mocks.makeJourneyService(
                    journeyStore: orderingStore,
                    experiencePresentation: orderingPresentationService
                )
                journeyStore = orderingStore

                let experience = makeExperience(goal: nil, exitPolicy: nil)
                let flow = makeLoadedExperience()

                await primeProfile(experience: experience, package: flow)
                await service.initialize()

                let journey = await startJourney()
                await journey.update { $0.executionState.pendingAction = JourneyPendingAction(
                    handlerId: "wait-notifications",
                    screenId: nil,
                    componentId: nil,
                    actionIndex: 0,
                    kind: .waitUntil,
                    resumeAt: nil,
                    condition: nil,
                    maxTimeMs: nil,
                    startedAt: Date(),
                    resumeActions: [.exit(ExitAction(reason: "completed"))]
                ) }
                mocks.eventLog.trackWithResponseResult = makeGatePlanResponse(
                    decision: "show_flow",
                    flowId: "gate-flow"
                )

                ordering.clear()

                await MainActor.run { [controller = controller!] in
                    (controller.runtimeDelegate as? NotificationPermissionEventReceiver)?.experienceViewController(
                        controller,
                        didResolveNotificationPermissionEvent: SystemEventNames.notificationsEnabled,
                        properties: ["journey_id": journey.id],
                        journeyId: journey.id
                    )
                }

                await polling(expect {
                    ordering.events
                }).value.toEventually(equal(["complete:\(experienceId)", "present:gate-flow"]), timeout: .seconds(2))
            }

            it("does not present scoped require_feature cache-only flows on deny") {
                let orderingPresentationService = OrderingExperiencePresentationService(recorder: OrderingRecorder())
                orderingPresentationService.defaultMockViewController = controller
                service = mocks.makeJourneyService(
                    journeyStore: journeyStore,
                    experiencePresentation: orderingPresentationService
                )

                let experience = makeExperience(goal: nil, exitPolicy: nil)
                let flow = makeLoadedExperience()
                await primeProfile(experience: experience, package: flow)
                await service.initialize()

                let journey = await startJourney()
                let baselinePresentations = orderingPresentationService.presentExperienceCallCount
                mocks.eventLog.trackWithResponseResult = makeGatePlanResponse(
                    decision: "require_feature",
                    flowId: "gate-flow",
                    featureId: "premium",
                    policy: "cache_only"
                )

                await MainActor.run { [controller = controller!] in
                    (controller.runtimeDelegate as? NotificationPermissionEventReceiver)?.experienceViewController(
                        controller,
                        didResolveNotificationPermissionEvent: SystemEventNames.notificationsEnabled,
                        properties: ["journey_id": journey.id],
                        journeyId: journey.id
                    )
                }

                await polling(expect {
                    orderingPresentationService.presentExperienceCallCount
                }).value.toEventually(equal(baselinePresentations), timeout: .seconds(2))
                expect(orderingPresentationService.wasExperiencePresented("gate-flow")).to(beFalse())
            }
        }

    }
}

private final class DelayedRequestPermissionAuthorizationHandler: PermissionAuthorizationHandling {
    let initialStatus: PermissionAuthorizationStatus
    let delayNanoseconds: UInt64
    let result: PermissionAuthorizationStatus

    init(
        initialStatus: PermissionAuthorizationStatus,
        delayNanoseconds: UInt64,
        result: PermissionAuthorizationStatus
    ) {
        self.initialStatus = initialStatus
        self.delayNanoseconds = delayNanoseconds
        self.result = result
    }

    func authorizationStatus() -> PermissionAuthorizationStatus {
        initialStatus
    }

    func requestAuthorization() async -> PermissionAuthorizationStatus {
        try? await Task.sleep(nanoseconds: delayNanoseconds)
        return result
    }
}

private final class UnsupportedRequestPermissionAuthorizationHandler: PermissionAuthorizationHandling {
    func authorizationStatus() -> PermissionAuthorizationStatus {
        .unsupported
    }

    func requestAuthorization() async -> PermissionAuthorizationStatus {
        .unsupported
    }
}


// File-scope helpers (not local functions) so @Sendable closures can call
// them without capturing; MainActor-isolated because they drive the
// MainActor-isolated ExperienceRuntimeDelegate.
@MainActor
private func emitScreenPress(_ controller: ExperienceViewController) {
    controller.runtimeDelegate?.experienceViewController(
        controller,
        didEmitEvent: ExperienceRendererEvent(
            name: "__nuxie_test_press",
            properties: [:],
            screenId: "screen-1",
            componentId: nil,
            instanceId: nil
        )
    )
}

@MainActor
private func emitRendererEvent(_ controller: ExperienceViewController, name: String) {
    controller.runtimeDelegate?.experienceViewController(
        controller,
        didEmitEvent: ExperienceRendererEvent(
            name: name,
            properties: [:],
            screenId: "screen-1",
            componentId: nil,
            instanceId: nil
        )
    )
}

@MainActor
private func emitTaggedRendererEvent(_ controller: ExperienceViewController, name: String) {
    controller.runtimeDelegate?.experienceViewController(
        controller,
        didEmitEvent: ExperienceRendererEvent(
            name: name,
            properties: ["eventName": name],
            screenId: "screen-1",
            componentId: nil,
            instanceId: nil
        )
    )
}
