import Foundation
import Quick
import Nimble
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

@MainActor
private final class ExperiencePresentationLifecycleRecorder {
    private(set) var shellWasPresented = false
    private(set) var cleanupCompleted = false
    private(set) var shellTraceTokens: [ExperiencePresentationTraceToken?] = []
    private(set) var completedTraceTokens: [ExperiencePresentationTraceToken?] = []
    private(set) var hostDismissalStarted = false
    private(set) var hostDismissalFinished = false
    private(set) var hostDismissalAttemptCount = 0
    private(set) var ordinaryDismissalReasons: [CloseReason] = []
    var activePresentationTraceToken: ExperiencePresentationTraceToken?
    var presentationTraceContext: ExperiencePresentationTraceContext?
    var isShellPresented: () -> Bool = { false }
    var hostDismissalWillHandler: (@MainActor () async -> Void)?
    var hostDismissalHandler: (@MainActor () async -> Void)?
    var hostDismissalResult = true
}

extension ExperiencePresentationLifecycleRecorder:
    ExperiencePresentationTraceContextProviding {}

extension ExperiencePresentationLifecycleRecorder: ExperienceRuntimeDelegate {
    func experienceViewControllerDidPresentShell(_ controller: ExperienceViewController) {
        shellWasPresented = isShellPresented()
    }

    func experienceViewControllerDidFinishPresentation(_ controller: ExperienceViewController) {
        cleanupCompleted = true
    }

    func experienceViewControllerDidRequestDismiss(
        _ controller: ExperienceViewController,
        reason: CloseReason
    ) async -> Bool {
        ordinaryDismissalReasons.append(reason)
        return true
    }

    @discardableResult
    func experienceViewControllerDidRequestHostDismiss(
        _ controller: ExperienceViewController
    ) async -> Bool {
        hostDismissalStarted = true
        hostDismissalAttemptCount += 1
        await hostDismissalHandler?()
        hostDismissalFinished = true
        return hostDismissalResult
    }

    func experienceViewControllerWillRequestHostDismiss(
        _ controller: ExperienceViewController
    ) async {
        await hostDismissalWillHandler?()
    }
}

extension ExperiencePresentationLifecycleRecorder: ExperiencePresentationScopedTraceDelegate {
    func experienceViewControllerDidBecomeReady(
        _ controller: ExperienceViewController,
        traceToken: ExperiencePresentationTraceToken?
    ) {}

    func experienceViewControllerDidPresentShell(
        _ controller: ExperienceViewController,
        traceToken: ExperiencePresentationTraceToken?
    ) {
        shellTraceTokens.append(traceToken)
        experienceViewControllerDidPresentShell(controller)
    }

    func experienceViewControllerDidReveal(
        _ controller: ExperienceViewController,
        traceToken: ExperiencePresentationTraceToken?
    ) async {}

    func experienceViewController(
        _ controller: ExperienceViewController,
        didPresentDrawable drawable: ExperienceRuntimePresentedDrawable,
        screenId: String,
        frameNumber: UInt64,
        traceToken: ExperiencePresentationTraceToken?
    ) {}

    func experienceViewController(
        _ controller: ExperienceViewController,
        didAcceptPointerInput input: ExperienceRuntimeAcceptedPointerInput,
        screenId: String,
        traceToken: ExperiencePresentationTraceToken?
    ) {}

    func experienceViewControllerDidFinishPresentation(
        _ controller: ExperienceViewController,
        traceToken: ExperiencePresentationTraceToken?
    ) {
        cleanupCompleted = true
        completedTraceTokens.append(traceToken)
    }
}

private actor ExperiencePresentationAcquisitionGate {
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        entered = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilEntered() async {
        while !entered {
            await Task.yield()
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class JourneyPresentationOutcomeRecorder {
    private(set) var outcomes: [JourneySurfaceOutcome] = []
    private(set) var availabilitySignals = 0
    var results: [Bool] = []

    func record(_ outcome: JourneySurfaceOutcome) -> Bool {
        outcomes.append(outcome)
        return results.isEmpty ? true : results.removeFirst()
    }

    func recordAvailability() {
        availabilitySignals += 1
    }
}

private final class RecordingPresentationSystemEventSink: @unchecked Sendable {
    private let lock = NSLock()
    private var capturedNames: [String] = []
    private var capturedEventIds: [String] = []

    func emit(_ name: String, properties: [String: Any]?) {
        _ = properties
        lock.withLock { capturedNames.append(name) }
    }

    func capture(
        _ request: StableSystemEventCaptureRequest
    ) async -> Bool {
        lock.withLock {
            capturedNames.append(request.name)
            capturedEventIds.append(request.eventId)
        }
        return true
    }

    var names: [String] { lock.withLock { capturedNames } }
    var eventIds: [String] { lock.withLock { capturedEventIds } }
}

extension RecordingPresentationSystemEventSink: SystemEventSink {}

@MainActor
private final class CommerceActionRecordingExperienceViewController:
    MockExperienceViewController
{
    private(set) var purchaseRequests: [(
        placementId: String,
        correlation: CommerceOutcomeCorrelation?
    )] = []
    private(set) var restoreCorrelations: [CommerceOutcomeCorrelation?] = []

    override func performPurchase(
        placementId: String,
        outcomeCorrelation: CommerceOutcomeCorrelation?
    ) {
        purchaseRequests.append((placementId, outcomeCorrelation))
    }

    override func performRestore(
        outcomeCorrelation: CommerceOutcomeCorrelation?
    ) {
        restoreCorrelations.append(outcomeCorrelation)
    }
}

@MainActor
private final class JourneyDismissalOrderRecorder {
    private(set) var events: [String] = []

    func screenDismissed() -> JourneyScreenDismissalResult {
        events.append("screen_dismissed")
        return .handled
    }

    func surfaceOutcome() -> Bool {
        events.append("surface_outcome")
        return true
    }
}

final class ExperiencePresentationServiceTests: AsyncSpec {
    override class func spec() {
        // nonisolated(unsafe): Quick runs beforeEach and each example strictly
        // serially, so these spec-level fixtures are never accessed
        // concurrently despite being captured by @MainActor example closures.
        nonisolated(unsafe) var service: ExperiencePresentationService!
        nonisolated(unsafe) var mockExperienceService: MockExperienceService!
        nonisolated(unsafe) var mockEventLog: MockEventLog!
        nonisolated(unsafe) var mockWindowProvider: MockWindowProvider!

        beforeEach { @MainActor in
            // Setup mock flow service
            mockExperienceService = MockExperienceService()

            // Setup mock event service
            mockEventLog = MockEventLog()

            // Setup mock window provider
            mockWindowProvider = MockWindowProvider()

            // Create service with mock collaborators
            service = ExperiencePresentationService(
                windowProvider: mockWindowProvider,
                experiences: mockExperienceService,
                eventLog: mockEventLog
            )
        }

        func makeJourneyRelease(
            versionId: String,
            screenId: String = "screen-selected"
        ) -> AuthenticatedJourneyRelease {
            let identity = JourneyReleaseIdentity(
                appId: "app",
                environment: "test",
                experienceId: "experience",
                experienceVersionId: versionId,
                buildId: "build-\(versionId)",
                versionNumber: 1,
                publishedAt: "2026-08-15T00:00:00Z",
                publishedAtSeq: 1
            )
            let leg = Journey(
                schemaVersion: "nuxie.experience-planes.v1",
                id: String(repeating: "b", count: 64),
                entryCondition: JourneyEntryCondition(
                    type: .appForegrounded,
                    eventName: nil,
                    segmentId: nil,
                    member: nil,
                    condition: nil
                ),
                entryStepId: "show",
                steps: [Journey.Step(
                    kind: .action,
                    id: "show",
                    action: [
                        "type": .string("navigate"),
                        "screenId": .string(screenId),
                    ],
                    outlets: [:],
                    outcome: nil
                )],
                routes: [],
                screens: [Journey.Screen(
                    id: screenId,
                    defaultViewModelName: nil,
                    defaultInstanceId: nil,
                    responseCaptures: []
                )],
                reentry: Journey.Reentry(type: .everyTime, windowSeconds: nil),
                entitlementGate: Journey.EntitlementGate(enabled: false, products: []),
                facts: JourneyFactReferences(
                    propertyKeys: [],
                    segmentIds: [],
                    experimentIds: []
                ),
                inputs: Journey.Boundary(eventFields: [], responseFields: []),
                outputs: [],
                completionOutputs: [:]
            )
            let descriptor = JourneyReleaseDescriptor(
                schemaVersion: JourneyReleaseDescriptor.wireSchemaVersion,
                identity: identity,
                metadata: [:],
                presentation: [:],
                leg: leg,
                products: [],
                placements: [],
                viewModelValues: [],
                screenBehaviors: [],
                render: nil,
                requirements: nil,
                provenance: [:]
            )
            let bytes = try! JSONEncoder().encode(descriptor)
            return AuthenticatedJourneyRelease(
                authenticatedKeyID: "TEST_ONLY_DEV_KEYPAIR",
                exactDescriptorBytes: bytes,
                descriptorSHA256: SHA256Provider.hexDigest(bytes),
                descriptor: descriptor,
                publishedAtSeqToPromote: nil
            )
        }

        func journeyDelivery() -> JourneyReleaseDelivery {
            JourneyReleaseDelivery(
                renderBaseUrl: "https://assets.nuxie.test/render/",
                assetBaseUrl: "https://assets.nuxie.test/assets/"
            )
        }

        afterEach { @MainActor in
            // Clean up
            mockWindowProvider.reset()
        }

        describe("Journey presentation") {
            context("when presenting for a journey") {
            }

            context("when window scene is available") {
                it("tears down the Journey surface while retrying durable host input") { @MainActor in
                    let versionID = "Journey-host-dismiss"
                    let screenID = "screen-selected"
                    let controller = MockExperienceViewController(
                        mockExperienceVersionId: versionID,
                        mockScreenId: screenID
                    )
                    mockExperienceService.mockViewControllers[versionID] = controller
                    let release = makeJourneyRelease(
                        versionId: versionID,
                        screenId: screenID
                    )
                    let outcomes = JourneyPresentationOutcomeRecorder()
                    outcomes.results = [false, true]
                    let reservation = service.reserveJourneyPresentation(
                        ownerDistinctId: "user-1"
                    )
                    let request = JourneyPresentationRequest(
                        release: release,
                        delivery: journeyDelivery(),
                        screenId: screenID,
                        owner: .init(
                            journeyId: "journey-owner",
                            distinctId: "user-1"
                        ),
                        reservation: reservation,
                        onEmissionBatch: { _ in true },
                        onOutcome: { outcome, _ in outcomes.record(outcome) }
                    )

                    let presentationResult = await service.presentJourney(request)
                    expect(presentationResult).to(equal(.shown))
                    expect(service.currentExperienceViewController)
                        .to(beIdenticalTo(controller))

                    await service.dismissCurrentExperienceFromHost()

                    expect(service.isExperiencePresented).to(beFalse())
                    expect(mockWindowProvider.createdWindows.first?.dismissCalled).to(beTrue())
                    await polling(expect(outcomes.outcomes)).value
                        .toEventually(
                            equal([.dismissed, .dismissed]),
                            timeout: .seconds(2)
                        )
                    await polling(expect(controller.shutdownRuntimeCallCount)).value
                        .toEventually(equal(1), timeout: .seconds(1))
                    let dismissal = mockEventLog.trackedEvents.last {
                        $0.name == JourneyEvents.experienceDismissed
                    }
                    expect(dismissal?.properties?["reason"] as? String).to(equal("host"))
                    expect(dismissal?.properties?["journey_id"] as? String)
                        .to(equal("journey-owner"))
                }

                it("acknowledges ordinary user dismissal after screen lifecycle handling") { @MainActor in
                    let versionID = "Journey-user-dismiss"
                    let screenID = "screen-selected"
                    let controller = MockExperienceViewController(
                        mockExperienceVersionId: versionID,
                        mockScreenId: screenID
                    )
                    mockExperienceService.mockViewControllers[versionID] = controller
                    let release = makeJourneyRelease(
                        versionId: versionID,
                        screenId: screenID
                    )
                    let outcomes = JourneyPresentationOutcomeRecorder()
                    let reservation = service.reserveJourneyPresentation(
                        ownerDistinctId: "user-1"
                    )
                    let request = JourneyPresentationRequest(
                        release: release,
                        delivery: journeyDelivery(),
                        screenId: screenID,
                        owner: .init(
                            journeyId: "journey-owner",
                            distinctId: "user-1"
                        ),
                        reservation: reservation,
                        onEmissionBatch: { _ in true },
                        onOutcome: { outcome, _ in outcomes.record(outcome) }
                    )

                    let presentationResult = await service.presentJourney(request)
                    expect(presentationResult).to(equal(.shown))

                    controller.performDismiss(reason: .userDismissed)
                    await polling(expect(service.isExperiencePresented)).value
                        .toEventually(beFalse(), timeout: .seconds(1))

                    expect(outcomes.outcomes).to(beEmpty())
                    expect(mockWindowProvider.createdWindows.first?.destroyCalled).to(beTrue())
                    let dismissal = mockEventLog.trackedEvents.last {
                        $0.name == JourneyEvents.experienceDismissed
                    }
                    expect(dismissal?.properties?["reason"] as? String).to(equal("user"))
                    expect(dismissal?.properties?["journey_id"] as? String)
                        .to(equal("journey-owner"))
                }

                it("settles screen dismissal before the Journey surface outcome") { @MainActor in
                    let versionID = "Journey-dismiss-order"
                    let screenID = "screen-selected"
                    let controller = MockExperienceViewController(
                        mockExperienceVersionId: versionID,
                        mockScreenId: screenID
                    )
                    mockExperienceService.mockViewControllers[versionID] = controller
                    let release = makeJourneyRelease(
                        versionId: versionID,
                        screenId: screenID
                    )
                    let order = JourneyDismissalOrderRecorder()
                    let reservation = service.reserveJourneyPresentation(
                        ownerDistinctId: "user-1"
                    )
                    let request = JourneyPresentationRequest(
                        release: release,
                        delivery: journeyDelivery(),
                        screenId: screenID,
                        owner: .init(
                            journeyId: "journey-owner",
                            distinctId: "user-1"
                        ),
                        reservation: reservation,
                        onScreenDismissed: { _, _, _ in
                            order.screenDismissed()
                        },
                        onEmissionBatch: { _ in true },
                        onOutcome: { _, _ in order.surfaceOutcome() }
                    )
                    let presentationResult = await service.presentJourney(request)
                    expect(presentationResult).to(equal(.shown))

                    controller.performDismiss(reason: .userDismissed)

                    await polling(expect(service.isExperiencePresented)).value
                        .toEventually(beFalse(), timeout: .seconds(1))
                    expect(order.events).to(equal([
                        "screen_dismissed",
                    ]))
                }

                it("declines a competing Journey journey without replacing its owner") { @MainActor in
                    let versionID = "Journey-owner"
                    let screenID = "screen-selected"
                    let controller = MockExperienceViewController(
                        mockExperienceVersionId: versionID,
                        mockScreenId: screenID
                    )
                    mockExperienceService.mockViewControllers[versionID] = controller
                    let release = makeJourneyRelease(
                        versionId: versionID,
                        screenId: screenID
                    )
                    let outcomes = JourneyPresentationOutcomeRecorder()
                    let reservation = service.reserveJourneyPresentation(
                        ownerDistinctId: "user-1"
                    )
                    let ownerRequest = JourneyPresentationRequest(
                        release: release,
                        delivery: journeyDelivery(),
                        screenId: screenID,
                        owner: .init(
                            journeyId: "journey-owner",
                            distinctId: "user-1"
                        ),
                        reservation: reservation,
                        onEmissionBatch: { _ in true },
                        onOutcome: { outcome, _ in outcomes.record(outcome) }
                    )
                    let ownerResult = await service.presentJourney(ownerRequest)
                    expect(ownerResult).to(equal(.shown))

                    let contenderRequest = JourneyPresentationRequest(
                        release: release,
                        delivery: journeyDelivery(),
                        screenId: screenID,
                        owner: .init(
                            journeyId: "journey-contender",
                            distinctId: "user-1"
                        ),
                        reservation: nil,
                        onEmissionBatch: { _ in true },
                        onOutcome: { _, _ in true }
                    )
                    let contenderResult = await service.presentJourney(contenderRequest)
                    expect(contenderResult).to(equal(.declined))

                    expect(service.currentExperienceViewController)
                        .to(beIdenticalTo(controller))
                    expect(controller.shutdownRuntimeCallCount).to(equal(0))
                    expect(mockWindowProvider.createdWindows.count).to(equal(1))
                    await service.shutdownJourneyPresentation(ownerDistinctId: "user-1")
                }

                it("navigates a Journey journey on its existing controller") { @MainActor in
                    let versionID = "Journey-navigation"
                    let screenID = "screen-selected"
                    let controller = MockExperienceViewController(
                        mockExperienceVersionId: versionID,
                        mockScreenId: screenID
                    )
                    mockExperienceService.mockViewControllers[versionID] = controller
                    let release = makeJourneyRelease(
                        versionId: versionID,
                        screenId: screenID
                    )
                    let reservation = service.reserveJourneyPresentation(
                        ownerDistinctId: "user-1"
                    )
                    let request = JourneyPresentationRequest(
                        release: release,
                        delivery: journeyDelivery(),
                        screenId: screenID,
                        owner: .init(
                            journeyId: "journey-owner",
                            distinctId: "user-1"
                        ),
                        reservation: reservation,
                        onEmissionBatch: { _ in true },
                        onOutcome: { _, _ in true }
                    )
                    let presentationResult = await service.presentJourney(request)
                    expect(presentationResult).to(equal(.shown))

                    let result = await service.navigateJourneyPresentation(
                        owner: .init(
                            journeyId: "journey-owner",
                            distinctId: "user-1"
                        ),
                        screenId: "screen-next",
                        transition: .string("crossfade")
                    )

                    expect(result).to(equal(.navigated))
                    expect(service.currentExperienceViewController)
                        .to(beIdenticalTo(controller))
                    expect(controller.navigationScreenIds).to(equal(["screen-next"]))
                    expect(controller.navigationTransitions.first.flatMap { $0 as? String })
                        .to(equal("crossfade"))
                    expect(mockWindowProvider.createdWindows.count).to(equal(1))

                    controller.navigationResult = .productsUnavailable
                    let recoveryResult = await service.navigateJourneyPresentation(
                        owner: .init(
                            journeyId: "journey-owner",
                            distinctId: "user-1"
                        ),
                        screenId: "screen-products",
                        transition: nil
                    )
                    expect(recoveryResult).to(equal(.productsUnavailable))
                    expect(service.isExperiencePresented).to(beTrue())

                    await service.shutdownJourneyPresentation(ownerDistinctId: "user-1")
                }

                it("finishes only the matching Journey presentation owner") { @MainActor in
                    let versionID = "Journey-finish"
                    let screenID = "screen-selected"
                    let controller = MockExperienceViewController(
                        mockExperienceVersionId: versionID,
                        mockScreenId: screenID
                    )
                    mockExperienceService.mockViewControllers[versionID] = controller
                    let release = makeJourneyRelease(
                        versionId: versionID,
                        screenId: screenID
                    )
                    let availability = JourneyPresentationOutcomeRecorder()
                    service.setJourneyPresentationAvailabilityHandler {
                        availability.recordAvailability()
                    }
                    let reservation = service.reserveJourneyPresentation(
                        ownerDistinctId: "user-1"
                    )
                    let request = JourneyPresentationRequest(
                        release: release,
                        delivery: journeyDelivery(),
                        screenId: screenID,
                        owner: .init(
                            journeyId: "journey-owner",
                            distinctId: "user-1"
                        ),
                        reservation: reservation,
                        onEmissionBatch: { _ in true },
                        onOutcome: { _, _ in true }
                    )
                    let presentationResult = await service.presentJourney(request)
                    expect(presentationResult).to(equal(.shown))

                    await service.finishJourneyPresentation(
                        owner: .init(
                            journeyId: "journey-contender",
                            distinctId: "user-1"
                        )
                    )
                    expect(service.isExperiencePresented).to(beTrue())
                    expect(controller.shutdownRuntimeCallCount).to(equal(0))

                    await service.finishJourneyPresentation(
                        owner: .init(
                            journeyId: "journey-owner",
                            distinctId: "user-1"
                        )
                    )

                    expect(service.isExperiencePresented).to(beFalse())
                    expect(controller.shutdownRuntimeCallCount).to(equal(1))
                    expect(mockWindowProvider.createdWindows.first?.destroyCalled).to(beTrue())
                    expect(availability.availabilitySignals).to(equal(1))
                }

                it(
                    "waits for foreground profile refresh before advertising Journey capacity"
                ) { @MainActor in
                    let availability = JourneyPresentationOutcomeRecorder()
                    service.setJourneyPresentationAvailabilityHandler {
                        availability.recordAvailability()
                    }

                    service.onAppDidEnterBackground()
                    service.onAppBecameActive()

                    expect(availability.availabilitySignals).to(equal(0))
                    expect(service.reserveJourneyPresentation(
                        ownerDistinctId: "user-1"
                    )).to(beNil())

                    service.journeyProfileRefreshDidComplete()

                    expect(availability.availabilitySignals).to(equal(1))
                    // The Journey service receives the same lifecycle transition
                    // after the coordinator opens profile authority. A duplicate
                    // callback must not close it again.
                    service.onAppBecameActive()
                    let reservation = service.reserveJourneyPresentation(
                        ownerDistinctId: "user-1"
                    )
                    expect(reservation).toNot(beNil())
                    reservation?.release()
                }

                it("defers active Journey actions until foreground profile authority is ready") { @MainActor in
                    let versionID = "Journey-foreground-action"
                    let screenID = "screen-selected"
                    let controller = MockExperienceViewController(
                        mockExperienceVersionId: versionID,
                        mockScreenId: screenID
                    )
                    mockExperienceService.mockViewControllers[versionID] = controller
                    let release = makeJourneyRelease(
                        versionId: versionID,
                        screenId: screenID
                    )
                    let reservation = service.reserveJourneyPresentation(
                        ownerDistinctId: "user-1"
                    )
                    let request = JourneyPresentationRequest(
                        release: release,
                        delivery: journeyDelivery(),
                        screenId: screenID,
                        owner: .init(
                            journeyId: "journey-owner",
                            distinctId: "user-1"
                        ),
                        reservation: reservation,
                        onEmissionBatch: { _ in true },
                        onOutcome: { _, _ in true }
                    )
                    let presentationResult = await service.presentJourney(request)
                    expect(presentationResult).to(equal(.shown))
                    await controller.runtimeDelegate?.experienceViewController(
                        controller,
                        didChangeScreen: screenID
                    )
                    await controller.runtimeDelegate?.experienceViewController(
                        controller,
                        didChangeScreen: "screen-next"
                    )

                    service.onAppDidEnterBackground()
                    service.onAppBecameActive()
                    let completed = ExperiencePresentationTestSignal()
                    let action = Task { @MainActor in
                        let result = await service.dispatchJourneyPresentationAction(
                            owner: .init(
                                journeyId: "journey-owner",
                                distinctId: "user-1"
                            ),
                            action: [
                                "type": .string("back"),
                                "steps": .number(1),
                            ],
                            effectId: "effect-foreground"
                        )
                        completed.signal()
                        return result
                    }
                    for _ in 0..<20 {
                        await Task.yield()
                    }

                    expect(completed.isSignaled).to(beFalse())
                    expect(controller.navigationScreenIds).to(beEmpty())
                    expect(service.isExperiencePresented).to(beTrue())

                    service.journeyProfileRefreshDidComplete()

                    let actionResult = await action.value
                    expect(actionResult).to(equal(.handled))
                    expect(completed.isSignaled).to(beTrue())
                    expect(controller.navigationScreenIds).to(equal([screenID]))
                    expect(service.isExperiencePresented).to(beTrue())
                    await service.shutdownJourneyPresentation(ownerDistinctId: "user-1")
                }

                it("returns an authenticated permission resolution to the claimed Journey action") { @MainActor in
                    let versionID = "Journey-permission-action"
                    let screenID = "screen-selected"
                    let controller = MockExperienceViewController(
                        mockExperienceVersionId: versionID,
                        mockScreenId: screenID
                    )
                    controller.requestPermissionEvent = .init(
                        name: SystemEventNames.permissionDenied,
                        properties: [
                            "type": "camera",
                            "source": "native",
                        ]
                    )
                    mockExperienceService.mockViewControllers[versionID] = controller
                    let release = makeJourneyRelease(
                        versionId: versionID,
                        screenId: screenID
                    )
                    let reservation = service.reserveJourneyPresentation(
                        ownerDistinctId: "user-1"
                    )
                    let request = JourneyPresentationRequest(
                        release: release,
                        delivery: journeyDelivery(),
                        screenId: screenID,
                        owner: .init(
                            journeyId: "journey-owner",
                            distinctId: "user-1"
                        ),
                        reservation: reservation,
                        onEmissionBatch: { _ in true },
                        onOutcome: { _, _ in true }
                    )
                    let presentationResult = await service.presentJourney(request)
                    expect(presentationResult).to(equal(.shown))

                    let actionResult = await service.dispatchJourneyPresentationAction(
                        owner: .init(
                            journeyId: "journey-owner",
                            distinctId: "user-1"
                        ),
                        action: [
                            "type": .string("request_permission"),
                            "permissionType": .string("camera"),
                        ],
                        effectId: "effect-permission"
                    )

                    expect(actionResult).to(equal(.permissionResolved(
                        outlet: "next",
                        event: .init(
                            name: SystemEventNames.permissionDenied,
                            properties: [
                                "type": "camera",
                                "source": "native",
                            ]
                        )
                    )))
                    expect(controller.requestPermissionResolutionTypes)
                        .to(equal(["camera"]))
                    expect(service.isExperiencePresented).to(beTrue())
                    await service.shutdownJourneyPresentation(ownerDistinctId: "user-1")
                }

                it("correlates purchase and restore outcomes to their claimed effects") { @MainActor in
                    let versionID = "Journey-commerce-action"
                    let screenID = "screen-selected"
                    let controller = CommerceActionRecordingExperienceViewController(
                        mockExperienceVersionId: versionID,
                        mockScreenId: screenID
                    )
                    mockExperienceService.mockViewControllers[versionID] = controller
                    let release = makeJourneyRelease(
                        versionId: versionID,
                        screenId: screenID
                    )
                    let reservation = service.reserveJourneyPresentation(
                        ownerDistinctId: "user-1"
                    )
                    let request = JourneyPresentationRequest(
                        release: release,
                        delivery: journeyDelivery(),
                        screenId: screenID,
                        owner: .init(
                            journeyId: "journey-owner",
                            distinctId: "user-1"
                        ),
                        reservation: reservation,
                        onEmissionBatch: { _ in true },
                        onOutcome: { _, _ in true }
                    )
                    let presentationResult = await service.presentJourney(request)
                    expect(presentationResult).to(equal(.shown))

                    let purchaseResult = await service.dispatchJourneyPresentationAction(
                        owner: .init(
                            journeyId: "journey-owner",
                            distinctId: "user-1"
                        ),
                        action: [
                            "type": .string("purchase"),
                            "placementId": .string("placement-gold"),
                        ],
                        effectId: "effect-purchase"
                    )
                    let restoreResult = await service.dispatchJourneyPresentationAction(
                        owner: .init(
                            journeyId: "journey-owner",
                            distinctId: "user-1"
                        ),
                        action: ["type": .string("restore")],
                        effectId: "effect-restore"
                    )

                    expect(purchaseResult).to(equal(.awaitingOutcome))
                    expect(restoreResult).to(equal(.awaitingOutcome))
                    expect(controller.purchaseRequests.map(\.placementId))
                        .to(equal(["placement-gold"]))
                    expect(controller.purchaseRequests.first?.correlation).to(equal(
                        CommerceOutcomeCorrelation(
                            eventId: "effect-purchase",
                            distinctId: "user-1"
                        )
                    ))
                    expect(controller.restoreCorrelations.first ?? nil).to(equal(
                        CommerceOutcomeCorrelation(
                            eventId: "effect-restore",
                            distinctId: "user-1"
                        )
                    ))
                    await service.shutdownJourneyPresentation(ownerDistinctId: "user-1")
                }

                it("dispatches an authenticated Journey dismiss through the active controller") { @MainActor in
                    let versionID = "Journey-authored-dismiss"
                    let screenID = "screen-selected"
                    let controller = MockExperienceViewController(
                        mockExperienceVersionId: versionID,
                        mockScreenId: screenID
                    )
                    mockExperienceService.mockViewControllers[versionID] = controller
                    let release = makeJourneyRelease(
                        versionId: versionID,
                        screenId: screenID
                    )
                    let outcomes = JourneyPresentationOutcomeRecorder()
                    let reservation = service.reserveJourneyPresentation(
                        ownerDistinctId: "user-1"
                    )
                    let request = JourneyPresentationRequest(
                        release: release,
                        delivery: journeyDelivery(),
                        screenId: screenID,
                        owner: .init(
                            journeyId: "journey-owner",
                            distinctId: "user-1"
                        ),
                        reservation: reservation,
                        onEmissionBatch: { _ in true },
                        onOutcome: { outcome, _ in
                            outcomes.record(outcome)
                        }
                    )
                    let presentationResult = await service.presentJourney(request)
                    expect(presentationResult).to(equal(.shown))

                    let actionResult = await service.dispatchJourneyPresentationAction(
                        owner: .init(
                            journeyId: "journey-owner",
                            distinctId: "user-1"
                        ),
                        action: [
                            "type": .string("dismiss"),
                            "reason": .string("completed"),
                        ],
                        effectId: "effect-dismiss"
                    )

                    expect(actionResult).to(equal(.handled))
                    expect(controller.performDismissReasons).to(equal([.userDismissed]))
                    await expect(service.isExperiencePresented).toEventually(beFalse())
                    expect(outcomes.outcomes).to(beEmpty())
                }

                it("does not advertise capacity when an unused reservation is released") { @MainActor in
                    let availability = JourneyPresentationOutcomeRecorder()
                    service.setJourneyPresentationAvailabilityHandler {
                        availability.recordAvailability()
                    }

                    let reservation = service.reserveJourneyPresentation(
                        ownerDistinctId: "user-1"
                    )
                    expect(reservation).toNot(beNil())
                    reservation?.release()

                    expect(availability.availabilitySignals).to(equal(0))
                    let nextReservation = service.reserveJourneyPresentation(
                        ownerDistinctId: "user-1"
                    )
                    expect(nextReservation).toNot(beNil())
                    nextReservation?.release()
                    expect(availability.availabilitySignals).to(equal(0))
                }

                it("advertises capacity when a contended unused reservation is released") { @MainActor in
                    let availability = JourneyPresentationOutcomeRecorder()
                    service.setJourneyPresentationAvailabilityHandler {
                        availability.recordAvailability()
                    }

                    let reservation = service.reserveJourneyPresentation(
                        ownerDistinctId: "user-1"
                    )
                    expect(reservation).toNot(beNil())
                    let blockedReservation = service.reserveJourneyPresentation(
                        ownerDistinctId: "user-1"
                    )
                    expect(blockedReservation).to(beNil())

                    reservation?.release()

                    expect(availability.availabilitySignals).to(equal(1))
                    let nextReservation = service.reserveJourneyPresentation(
                        ownerDistinctId: "user-1"
                    )
                    expect(nextReservation).toNot(beNil())
                    nextReservation?.release()
                    expect(availability.availabilitySignals).to(equal(1))
                }

                it("fences a Journey presentation acquiring during profile teardown") { @MainActor in
                    let versionID = "Journey-profile-teardown"
                    let screenID = "screen-selected"
                    mockExperienceService.mockViewControllers[versionID] =
                        MockExperienceViewController(
                            mockExperienceVersionId: versionID,
                            mockScreenId: screenID
                        )
                    let gate = ExperiencePresentationAcquisitionGate()
                    mockExperienceService.viewControllerHandler = {
                        await gate.suspend()
                    }
                    let release = makeJourneyRelease(
                        versionId: versionID,
                        screenId: screenID
                    )
                    let reservation = service.reserveJourneyPresentation(
                        ownerDistinctId: "user-1"
                    )
                    let request = JourneyPresentationRequest(
                        release: release,
                        delivery: journeyDelivery(),
                        screenId: screenID,
                        owner: .init(
                            journeyId: "journey-owner",
                            distinctId: "user-1"
                        ),
                        reservation: reservation,
                        onEmissionBatch: { _ in true },
                        onOutcome: { _, _ in true }
                    )
                    let presentation = Task { @MainActor in
                        await service.presentJourney(request)
                    }
                    await gate.waitUntilEntered()
                    let shutdown = Task { @MainActor in
                        await service.shutdownJourneyPresentation(
                            ownerDistinctId: "user-1"
                        )
                    }
                    await Task.yield()

                    await gate.release()
                    await shutdown.value

                    let presentationResult = await presentation.value
                    expect(presentationResult).to(equal(.failed))
                    expect(service.isExperiencePresented).to(beFalse())
                    expect(mockWindowProvider.createdWindows).to(beEmpty())
                }

                it("fences a Journey presentation acquiring as the app backgrounds") { @MainActor in
                    let versionID = "Journey-background"
                    let screenID = "screen-selected"
                    mockExperienceService.mockViewControllers[versionID] =
                        MockExperienceViewController(
                            mockExperienceVersionId: versionID,
                            mockScreenId: screenID
                        )
                    let gate = ExperiencePresentationAcquisitionGate()
                    mockExperienceService.viewControllerHandler = {
                        await gate.suspend()
                    }
                    let release = makeJourneyRelease(
                        versionId: versionID,
                        screenId: screenID
                    )
                    let reservation = service.reserveJourneyPresentation(
                        ownerDistinctId: "user-1"
                    )
                    let request = JourneyPresentationRequest(
                        release: release,
                        delivery: journeyDelivery(),
                        screenId: screenID,
                        owner: .init(
                            journeyId: "journey-owner",
                            distinctId: "user-1"
                        ),
                        reservation: reservation,
                        onEmissionBatch: { _ in true },
                        onOutcome: { _, _ in true }
                    )
                    let presentation = Task { @MainActor in
                        await service.presentJourney(request)
                    }
                    await gate.waitUntilEntered()

                    service.onAppDidEnterBackground()
                    await gate.release()

                    let presentationResult = await presentation.value
                    expect(presentationResult).to(equal(.declined))
                    expect(service.isExperiencePresented).to(beFalse())
                    expect(mockWindowProvider.createdWindows).to(beEmpty())
                }

            }

            context("when window scene is not available") {
                beforeEach { @MainActor in
                    mockWindowProvider.simulateNoScene()
                }

                it("does not reserve Journey capacity") { @MainActor in
                    expect(service.reserveJourneyPresentation(
                        ownerDistinctId: "user-1"
                    )).to(beNil())
                }

            }

            context("when flow service fails") {
            }
        }

        describe("dismissCurrentExperience") {
            it("treats host dismissal as a no-op when no experience is presented") { @MainActor in
                expect(service.isExperiencePresented).to(beFalse())

                await service.dismissCurrentExperienceFromHost()

                expect(service.isExperiencePresented).to(beFalse())
                expect(mockWindowProvider.createdWindows).to(beEmpty())
            }

            it("should handle dismissal when no flow is presented") { @MainActor in
                // No flow presented
                expect(service.isExperiencePresented).to(beFalse())

                // Should not crash
                await service.dismissCurrentExperience()

                // Still no flow
                expect(service.isExperiencePresented).to(beFalse())
            }

        }

        describe("isExperiencePresented") {
        }

        describe("journey integration") {
        }

        describe("window management") {
        }
    }
}

@MainActor
private final class ScreenDismissalOrderRuntimeDelegate: ExperienceRuntimeDelegate {
    private let onDismissed: () -> Void

    init(onDismissed: @escaping () -> Void) {
        self.onDismissed = onDismissed
    }

    func experienceViewControllerDidBecomeReady(_ controller: ExperienceViewController) {}

    func experienceViewController(
        _ controller: ExperienceViewController,
        didChangeScreen screenId: String
    ) async {}

    func experienceViewController(
        _ controller: ExperienceViewController,
        didDismissScreen screenId: String,
        revealingScreenId: String?,
        method: String
    ) async {
        onDismissed()
    }

    func experienceViewController(
        _ controller: ExperienceViewController,
        didEmitViewModelChange change: ExperienceRendererViewModelChange
    ) {}

    func experienceViewController(
        _ controller: ExperienceViewController,
        didRequestOpenLink request: ExperienceRendererOpenLinkRequest
    ) {}

    func experienceViewControllerDidRequestDismiss(
        _ controller: ExperienceViewController,
        reason: CloseReason
    ) async -> Bool { true }
}

@MainActor
private final class ExperiencePresentationTestSignal {
    private var wasSignaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var isSignaled: Bool { wasSignaled }

    func signal() {
        guard !wasSignaled else { return }
        wasSignaled = true
        let waiters = waiters
        self.waiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func wait() async {
        guard !wasSignaled else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private actor SuspendedExperienceTestStore: NuxieTestStorePurchasing {
    private var purchaseContinuation:
        CheckedContinuation<NuxieTestStorePurchaseResponse, Never>?
    private var purchaseStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var restoreContinuation:
        CheckedContinuation<NuxieTestStoreRestoreResponse, Never>?
    private var restoreStartWaiters: [CheckedContinuation<Void, Never>] = []

    func purchase(
        product _: StoreProduct,
        distinctId _: String
    ) async -> NuxieTestStorePurchaseResponse {
        await withCheckedContinuation { continuation in
            purchaseContinuation = continuation
            let waiters = purchaseStartWaiters
            purchaseStartWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func restorePurchases(distinctId _: String) async -> NuxieTestStoreRestoreResponse {
        await withCheckedContinuation { continuation in
            restoreContinuation = continuation
            let waiters = restoreStartWaiters
            restoreStartWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func waitUntilPurchaseStarts() async {
        guard purchaseContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            purchaseStartWaiters.append(continuation)
        }
    }

    func resolvePurchase(_ result: NativePurchaseResult) {
        let continuation = purchaseContinuation
        purchaseContinuation = nil
        continuation?.resume(returning: NuxieTestStorePurchaseResponse(result: result))
    }

    func waitUntilRestoreStarts() async {
        guard restoreContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            restoreStartWaiters.append(continuation)
        }
    }

    func resolveRestore() {
        let continuation = restoreContinuation
        restoreContinuation = nil
        continuation?.resume(
            returning: NuxieTestStoreRestoreResponse(result: .noPurchases)
        )
    }
}
