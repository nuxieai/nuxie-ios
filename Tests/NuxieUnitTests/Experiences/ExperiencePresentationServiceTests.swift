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
    ) {
        ordinaryDismissalReasons.append(reason)
    }

    @discardableResult
    func experienceViewControllerDidRequestHostDismiss(
        _ controller: ExperienceViewController
    ) async -> Bool {
        hostDismissalStarted = true
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
    ) {}

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
                eventLog: mockEventLog,
                triggerBroker: TriggerBroker(),
                dateProvider: MockDateProvider()
            )
        }

        func makeExperience(id: String) -> Experience {
            let releaseCreatedAt = ISO8601DateFormatter().string(from: Date())
            return Experience(
                id: id,
                versionId: "flow-test",
                name: "Test Experience",
                reentry: .oneTime,
                releaseCreatedAt: releaseCreatedAt,
                trigger: .event(EventTriggerConfig(eventName: "test_event", condition: nil)),
                goal: nil,
                exitPolicy: nil,
                conversionAnchor: nil,
                experienceType: nil
            )
        }

        func makeSignedExperience(
            versionId: String,
            shell: ExperienceShellContract,
            screenId: String = "screen-selected",
            additionalScreenID: String? = nil
        ) -> Experience {
            var screens = [screenId: shell.screen]
            if let additionalScreenID {
                screens[additionalScreenID] = shell.screen
            }
            return Experience(
                behavior: ExperienceBehaviorDefinition(
                    reference: .init(
                        experienceId: "experience",
                        versionId: versionId
                    ),
                    buildId: "build-\(versionId)",
                    artifactContentHash: String(repeating: "a", count: 64),
                    name: "Signed shell",
                    reentry: .everyTime,
                    releaseCreatedAt: "2026-08-15T00:00:00Z",
                    trigger: nil,
                    goal: nil,
                    exitPolicy: nil,
                    conversionAnchor: nil,
                    timeLimitSeconds: nil,
                    experienceType: nil,
                    presentation: shell.presentation,
                    presentationScreens: screens
                ),
                journey: JourneyDocument(screens: screens.keys.sorted().map {
                    .init(id: $0)
                }),
                assetBaseURL: URL(string: "https://assets.nuxie.test/")!,
                authenticatedReleaseID: .init(
                    identity: .init(
                        appId: "app",
                        environment: "test",
                        experienceId: "experience",
                        experienceVersionId: versionId,
                        buildId: "build-\(versionId)",
                        versionNumber: 1,
                        releaseCreatedAt: "2026-08-15T00:00:00Z",
                        releaseSequence: 1
                    ),
                    descriptorSHA256: String(repeating: "a", count: 64)
                )
            )
        }
        
        afterEach { @MainActor in
            // Clean up
            mockWindowProvider.reset()
        }
        
        describe("presentExperience") {
            context("when presenting for a journey") {
                it("tracks $experience_shown exactly once on success") { @MainActor in
                    let flowId = "test-flow-journey"
                    let mockVC = MockExperienceViewController(mockExperienceVersionId: flowId)
                    mockExperienceService.mockViewControllers[flowId] = mockVC
                    let experience = makeExperience(id: "experience-1")
                    let journey = Journey(experience: experience, distinctId: "user-1", now: Date())

                    try! await service.presentExperience(flowId, from: journey, runtimeDelegate: nil)

                    let experienceShownCount = mockEventLog.trackedEvents
                        .filter { $0.name == JourneyEvents.experienceShown }
                        .count
                    expect(experienceShownCount).to(equal(1))
                }

                it("does not track $experience_shown when presentation fails") { @MainActor in
                    let experience = makeExperience(id: "experience-1")
                    let journey = Journey(experience: experience, distinctId: "user-1", now: Date())

                    mockExperienceService.shouldFailExperienceDisplay = true
                    mockExperienceService.failureError = MockExperienceServiceError.experienceNotFound("missing-flow")

                    do {
                        _ = try await service.presentExperience("missing-flow", from: journey, runtimeDelegate: nil)
                        fail("Expected presentExperience to throw")
                    } catch {
                        // Expected.
                    }

                    let experienceShownCount = mockEventLog.trackedEvents
                        .filter { $0.name == JourneyEvents.experienceShown }
                        .count
                    expect(experienceShownCount).to(equal(0))
                }
            }

            context("when window scene is available") {
                it("should create a presentation window") { @MainActor in
                    // Setup
                    let flowId = "test-flow-1"
                    let mockVC = MockExperienceViewController(mockExperienceVersionId: flowId)
                    mockExperienceService.mockViewControllers[flowId] = mockVC
                    
                    // Act
                    do {
                        _ = try await service.presentExperience(flowId, from: nil, runtimeDelegate: nil)
                    } catch {
                        fail("Unexpected presentExperience error: \(error)")
                    }
                    
                    // Assert
                    expect(service.isExperiencePresented).to(beTrue())
                    expect(mockWindowProvider.createdWindows.count).to(equal(1))
                    
                    let window = mockWindowProvider.createdWindows.first
                    expect(window?.presentCalled).to(beTrue())
                    expect(window?.presentedViewController).to(equal(mockVC))
                }

                it("reports shell presentation only after the window has presented") { @MainActor in
                    let flowId = "test-flow-shell-milestone"
                    let mockVC = MockExperienceViewController(mockExperienceVersionId: flowId)
                    mockExperienceService.mockViewControllers[flowId] = mockVC
                    let recorder = ExperiencePresentationLifecycleRecorder()
                    recorder.isShellPresented = {
                        mockWindowProvider.createdWindows.first?.presentedViewController === mockVC
                    }

                    try! await service.presentExperience(
                        flowId,
                        from: nil,
                        runtimeDelegate: recorder
                    )

                    expect(recorder.shellWasPresented).to(beTrue())
                    expect(recorder.cleanupCompleted).to(beFalse())

                    await service.dismissCurrentExperience()

                    expect(recorder.cleanupCompleted).to(beTrue())
                    expect(mockVC.shutdownRuntimeCallCount).to(equal(1))
                    expect(mockWindowProvider.createdWindows.first?.destroyCalled).to(beTrue())
                }

                it("ignores a persisted shell that disagrees with the authenticated release") { @MainActor in
                    let versionId = "signed-drawer-shell"
                    let authenticatedShell = ExperienceShellContract(
                        presentation: .init(
                            style: .drawer,
                            orientation: .portrait,
                            backgroundColor: "#102030FF",
                            sheet: nil,
                            drawer: .init(
                                edge: .bottom,
                                extentRatio: 0.72,
                                cornerRadius: 24,
                                dismissible: true
                            )
                        ),
                        screen: .init(width: 390, height: 640)
                    )
                    let persistedShell = ExperienceShellContract(
                        presentation: .fullScreenDefault,
                        screen: .init(width: 1, height: 1)
                    )
                    let mockVC = MockExperienceViewController(
                        mockExperienceVersionId: versionId,
                        mockExperience: makeSignedExperience(
                            versionId: versionId,
                            shell: authenticatedShell
                        )
                    )
                    mockExperienceService.mockViewControllers[versionId] = mockVC
                    let commit = JourneyPendingPresentation(
                        experienceId: "experience",
                        experienceVersionId: versionId,
                        releaseID: nil,
                        presentationStyle: .drawer,
                        shell: persistedShell,
                        screenId: "screen-selected",
                        transition: nil,
                        continuation: []
                    )

                    _ = try! await service.presentExperience(
                        versionId,
                        from: nil,
                        runtimeDelegate: nil,
                        colorSchemeMode: .dark,
                        commit: commit
                    )

                    expect(
                        mockWindowProvider.createdWindows.first?.presentedShellContract
                    ).to(equal(authenticatedShell))
                }

                it("suppresses the loading treatment for an exact memory-warm release") { @MainActor in
                    let versionId = "signed-memory-warm"
                    let shell = ExperienceShellContract(
                        presentation: .init(
                            style: .fullScreen,
                            orientation: .any,
                            backgroundColor: "#102030FF",
                            sheet: nil,
                            drawer: nil
                        ),
                        screen: .init(width: 390, height: 844)
                    )
                    let mockVC = MockExperienceViewController(
                        mockExperienceVersionId: versionId,
                        mockExperience: makeSignedExperience(
                            versionId: versionId,
                            shell: shell
                        )
                    )
                    mockExperienceService.mockViewControllers[versionId] = mockVC
                    mockExperienceService.presentationCommitIsMemoryWarm = true
                    let commit = JourneyPendingPresentation(
                        experienceId: "experience",
                        experienceVersionId: versionId,
                        releaseID: nil,
                        presentationStyle: .fullScreen,
                        shell: shell,
                        screenId: "screen-selected",
                        transition: nil,
                        continuation: []
                    )

                    _ = try! await service.presentExperience(
                        versionId,
                        from: nil,
                        runtimeDelegate: nil,
                        colorSchemeMode: .light,
                        commit: commit
                    )

                    expect(mockVC.suppressesLoadingTreatmentForPresentation).to(beTrue())
                    expect(
                        mockWindowProvider.createdWindows.first?.presentedShellContract
                    ).to(equal(shell))
                }

                it("suppresses loading for a memory-warm direct presentation") { @MainActor in
                    let versionId = "signed-memory-warm-direct"
                    let shell = ExperienceShellContract(
                        presentation: .fullScreenDefault,
                        screen: .init(width: 390, height: 844)
                    )
                    let mockVC = MockExperienceViewController(
                        mockExperienceVersionId: versionId,
                        mockExperience: makeSignedExperience(
                            versionId: versionId,
                            shell: shell
                        )
                    )
                    mockExperienceService.mockViewControllers[versionId] = mockVC
                    mockExperienceService.presentationCommitIsMemoryWarm = true

                    _ = try! await service.presentExperience(
                        versionId,
                        from: nil,
                        runtimeDelegate: nil
                    )

                    expect(mockVC.suppressesLoadingTreatmentForPresentation).to(beTrue())
                }

                it("fails closed when a direct signed presentation has no authoritative screen") { @MainActor in
                    let versionId = "signed-direct-multiscreen"
                    let shell = ExperienceShellContract(
                        presentation: .init(
                            style: .drawer,
                            orientation: .portrait,
                            backgroundColor: "#102030FF",
                            sheet: nil,
                            drawer: .init(
                                edge: .bottom,
                                extentRatio: 0.72,
                                cornerRadius: 24,
                                dismissible: true
                            )
                        ),
                        screen: .init(width: 390, height: 640)
                    )
                    mockExperienceService.mockViewControllers[versionId] =
                        MockExperienceViewController(
                            mockExperienceVersionId: versionId,
                            mockExperience: makeSignedExperience(
                                versionId: versionId,
                                shell: shell,
                                additionalScreenID: "screen-other"
                            )
                        )

                    do {
                        _ = try await service.presentExperience(
                            versionId,
                            from: nil,
                            runtimeDelegate: nil
                        )
                        fail("Expected an ambiguous direct presentation to fail closed")
                    } catch let error as ExperiencePresentationError {
                        guard case .presentationSuperseded = error else {
                            return fail("Unexpected presentation error: \(error)")
                        }
                    } catch {
                        fail("Unexpected error: \(error)")
                    }
                    expect(mockWindowProvider.createdWindows).to(beEmpty())
                }

                it("attributes window presentation through the shell milestone") { @MainActor in
                    let flowId = "test-flow-shell-attribution"
                    let mockVC = MockExperienceViewController(
                        mockExperienceVersionId: flowId
                    )
                    mockExperienceService.mockViewControllers[flowId] = mockVC
                    let trace = InMemoryExperiencePresentationTrace()
                    let attempt = ExperiencePresentationAttempt.make(
                        triggerEvent: "qualification_present",
                        startedAt: Date()
                    )
                    let recorder = ExperiencePresentationLifecycleRecorder()
                    recorder.presentationTraceContext =
                        ExperiencePresentationTraceContext(
                            attempt: attempt,
                            recorder: trace
                        )

                    try! await service.presentExperience(
                        flowId,
                        from: nil,
                        runtimeDelegate: recorder
                    )

                    let displayEvents = trace.qualificationSnapshot(
                        for: attempt.id
                    ).events.filter { $0.work == "display_presentation" }
                    expect(displayEvents.map(\.stage)).to(equal([
                        "work_started",
                        "work_completed",
                    ]))
                    expect(displayEvents.allSatisfy {
                        $0.attributes["phase"] == "shell"
                    }).to(beTrue())
                }
                
                it("should set up dismissal handler on flow view controller") { @MainActor in
                    // Setup
                    let flowId = "test-flow-handler"
                    let mockVC = MockExperienceViewController(mockExperienceVersionId: flowId)
                    mockExperienceService.mockViewControllers[flowId] = mockVC
                    
                    // Present flow
                    try! await service.presentExperience(flowId, from: nil, runtimeDelegate: nil)
                    
                    // Verify onClose handler is set
                    expect(mockVC.onClose).toNot(beNil())
                }

                it("prepares a fresh runtime presentation before showing a cached controller") { @MainActor in
                    let flowId = "test-flow-reuse"
                    let mockVC = MockExperienceViewController(mockExperienceVersionId: flowId)
                    mockExperienceService.mockViewControllers[flowId] = mockVC

                    try! await service.presentExperience(flowId, from: nil, runtimeDelegate: nil)
                    expect(mockVC.prepareForPresentationCallCount).to(equal(1))

                    await service.dismissCurrentExperience()
                    expect(mockVC.shutdownRuntimeCallCount).to(equal(1))

                    try! await service.presentExperience(flowId, from: nil, runtimeDelegate: nil)
                    expect(mockVC.prepareForPresentationCallCount).to(equal(2))
                }

                it("returns the captured trace token when replacing a cached controller") { @MainActor in
                    let flowId = "captured-trace-token-reuse"
                    let mockVC = MockExperienceViewController(mockExperienceVersionId: flowId)
                    mockExperienceService.mockViewControllers[flowId] = mockVC
                    let recorder = ExperiencePresentationLifecycleRecorder()
                    let firstToken = ExperiencePresentationTraceToken(id: UUID())
                    let replacementToken = ExperiencePresentationTraceToken(id: UUID())

                    recorder.activePresentationTraceToken = firstToken
                    try! await service.presentExperience(
                        flowId,
                        from: nil,
                        runtimeDelegate: recorder
                    )

                    recorder.activePresentationTraceToken = replacementToken
                    try! await service.presentExperience(
                        flowId,
                        from: nil,
                        runtimeDelegate: recorder
                    )

                    expect(recorder.completedTraceTokens).to(equal([firstToken]))
                    expect(recorder.shellTraceTokens).to(equal([
                        firstToken,
                        replacementToken,
                    ]))
                    expect(service.currentExperienceViewController).to(beIdenticalTo(mockVC))

                    await service.dismissCurrentExperience()

                    expect(recorder.completedTraceTokens).to(equal([
                        firstToken,
                        replacementToken,
                    ]))
                }
                
                it("should handle flow dismissal and cleanup") { @MainActor in
                    // Setup
                    let flowId = "test-flow-dismissal"
                    let mockVC = MockExperienceViewController(mockExperienceVersionId: flowId)
                    mockExperienceService.mockViewControllers[flowId] = mockVC
                    
                    // Present flow
                    try! await service.presentExperience(flowId, from: nil, runtimeDelegate: nil)
                    expect(mockWindowProvider.createdWindows.count).to(equal(1))
                    
                    // Simulate dismissal via onClose callback
                    mockVC.onClose?(.userDismissed)
                    
                    // Wait for cleanup to complete
                    await polling(expect(service.isExperiencePresented)).value
                        .toEventually(beFalse(), timeout: .seconds(2))
                    
                    // Verify window was cleaned up
                    let window = mockWindowProvider.createdWindows.first
                    expect(window?.destroyCalled).to(beTrue())
                    expect(window?.presentedViewController).to(beNil())
                }
                
                it("should dismiss existing flow before presenting new one") { @MainActor in
                    // Present first flow
                    let flowId1 = "flow-1"
                    let mockVC1 = MockExperienceViewController(mockExperienceVersionId: flowId1)
                    mockExperienceService.mockViewControllers[flowId1] = mockVC1
                    
                    try! await service.presentExperience(flowId1, from: nil, runtimeDelegate: nil)
                    expect(service.isExperiencePresented).to(beTrue())
                    expect(mockWindowProvider.createdWindows.count).to(equal(1))
                    
                    // Present second flow
                    let flowId2 = "flow-2"
                    let mockVC2 = MockExperienceViewController(mockExperienceVersionId: flowId2)
                    mockExperienceService.mockViewControllers[flowId2] = mockVC2
                    
                    try! await service.presentExperience(flowId2, from: nil, runtimeDelegate: nil)
                    
                    // Should still be presenting (the new one)
                    expect(service.isExperiencePresented).to(beTrue())
                    
                    // Should have created a new window
                    expect(mockWindowProvider.createdWindows.count).to(equal(2))
                }

                it("ignores an old controller close callback after a newer flow is presented") { @MainActor in
                    let firstExperienceVersionId = "stale-close-first"
                    let firstVC = MockExperienceViewController(mockExperienceVersionId: firstExperienceVersionId)
                    mockExperienceService.mockViewControllers[firstExperienceVersionId] = firstVC
                    try! await service.presentExperience(firstExperienceVersionId, from: nil, runtimeDelegate: nil)
                    let staleOnClose = firstVC.onClose

                    let secondExperienceVersionId = "stale-close-second"
                    let secondVC = MockExperienceViewController(mockExperienceVersionId: secondExperienceVersionId)
                    mockExperienceService.mockViewControllers[secondExperienceVersionId] = secondVC
                    try! await service.presentExperience(secondExperienceVersionId, from: nil, runtimeDelegate: nil)
                    let secondWindow = mockWindowProvider.createdWindows[1]

                    staleOnClose?(.userDismissed)
                    await Task.yield()

                    expect(service.currentExperienceId).to(equal(secondExperienceVersionId))
                    expect(service.currentExperienceViewController).to(beIdenticalTo(secondVC))
                    expect(secondWindow.destroyCalled).to(beFalse())
                    expect(service.isExperiencePresented).to(beTrue())
                }

                it("ignores a delayed close fallback after reusing the same controller") { @MainActor in
                    let flowId = "stale-close-reused-controller"
                    let mockVC = MockExperienceViewController(mockExperienceVersionId: flowId)
                    mockExperienceService.mockViewControllers[flowId] = mockVC
                    try! await service.presentExperience(flowId, from: nil, runtimeDelegate: nil)

                    mockVC.performDismiss(reason: .userDismissed)
                    await polling(expect(service.isExperiencePresented)).value
                        .toEventually(beFalse(), timeout: .seconds(1))

                    try! await service.presentExperience(flowId, from: nil, runtimeDelegate: nil)
                    try? await Task.sleep(nanoseconds: 600_000_000)

                    expect(service.currentExperienceViewController).to(beIdenticalTo(mockVC))
                    expect(service.isExperiencePresented).to(beTrue())
                }

                it("serializes cached-controller cleanup before a third presentation claims it") { @MainActor in
                    let flowId = "serialized-cleanup"
                    let mockVC = MockExperienceViewController(mockExperienceVersionId: flowId)
                    mockExperienceService.mockViewControllers[flowId] = mockVC
                    try! await service.presentExperience(flowId, from: nil, runtimeDelegate: nil)
                    mockWindowProvider.createdWindows[0].dismissDelay = 0.2

                    let superseded = Task { @MainActor in
                        // Boxed: Task success types must be Sendable.
                        PollingBox(try await service.presentExperience(flowId, from: nil, runtimeDelegate: nil))
                    }
                    await polling(expect { mockWindowProvider.createdWindows[0].dismissCalled }).value
                        .toEventually(beTrue(), timeout: .seconds(1))

                    let newest = Task { @MainActor in
                        // Boxed: Task success types must be Sendable.
                        PollingBox(try await service.presentExperience(flowId, from: nil, runtimeDelegate: nil))
                    }
                    do {
                        _ = try await superseded.value
                        fail("Expected the middle presentation attempt to be superseded")
                    } catch is CancellationError {
                        // Expected.
                    }
                    let newestController = try await newest.value.value

                    expect(newestController).to(beIdenticalTo(mockVC))
                    // The lifecycle contract inserts a dismissal-preparation
                    // step (exit handshake) before the superseded
                    // presentation's shutdown.
                    expect(mockVC.runtimeLifecycleEvents).to(equal([
                        "prepare",
                        "prepare-dismissal",
                        "shutdown",
                        "prepare",
                    ]))
                    expect(mockWindowProvider.createdWindows.count).to(equal(2))
                    expect(service.currentExperienceViewController).to(beIdenticalTo(mockVC))
                }

                it("cancels an owned presentation attempt and tears down its window") { @MainActor in
                    let flowId = "cancelled-presentation"
                    let mockVC = MockExperienceViewController(mockExperienceVersionId: flowId)
                    let gate = ExperiencePresentationTestGate()
                    mockVC.prepareForPresentationHandler = {
                        await gate.wait()
                    }
                    mockExperienceService.mockViewControllers[flowId] = mockVC

                    let presentation = Task { @MainActor in
                        // Boxed: Task success types must be Sendable.
                        PollingBox(try await service.presentExperience(flowId, from: nil, runtimeDelegate: nil))
                    }
                    await gate.waitUntilSuspended()
                    presentation.cancel()
                    gate.resume()

                    do {
                        _ = try await presentation.value
                        fail("Expected presentation cancellation")
                    } catch is CancellationError {
                        // Expected.
                    }

                    expect(mockVC.shutdownRuntimeCallCount).to(equal(1))
                    expect(mockWindowProvider.createdWindows.first?.destroyCalled).to(beTrue())
                    expect(service.currentExperienceViewController).to(beNil())
                    expect(service.isExperiencePresented).to(beFalse())
                }

                it("tears down owned presentation when its exact commit is replaced during prepare") { @MainActor in
                    let flowId = "replaced-presentation"
                    let mockVC = MockExperienceViewController(mockExperienceVersionId: flowId)
                    let gate = ExperiencePresentationTestGate()
                    mockVC.prepareForPresentationHandler = { await gate.wait() }
                    mockExperienceService.mockViewControllers[flowId] = mockVC
                    let commit = JourneyPendingPresentation(
                        experienceId: "experience",
                        experienceVersionId: flowId,
                        releaseID: nil,
                        presentationStyle: .fullScreen,
                        screenId: "screen-selected",
                        transition: nil,
                        continuation: []
                    )

                    let presentation = Task { @MainActor in
                        try await service.presentExperience(
                            flowId,
                            from: nil,
                            runtimeDelegate: nil,
                            colorSchemeMode: .light,
                            commit: commit
                        )
                    }
                    await gate.waitUntilSuspended()
                    mockExperienceService.presentationCommitIsValid = false
                    gate.resume()

                    do {
                        _ = try await presentation.value
                        fail("expected superseded commit")
                    } catch ExperiencePresentationError.presentationSuperseded {
                        // Expected.
                    }
                    expect(mockVC.shutdownRuntimeCallCount).to(equal(1))
                    expect(mockWindowProvider.createdWindows.first?.presentCalled).to(beFalse())
                    expect(mockWindowProvider.createdWindows.first?.destroyCalled).to(beTrue())
                    expect(service.isExperiencePresented).to(beFalse())
                }
                it("an invalid commit does not cancel a valid suspended presentation") { @MainActor in
                    // Round-6 regression: commit validation must precede the attempt
                    // generation advance, or an invalid request cancels a valid
                    // suspended presentation.
                    let flowId = "invalid-commit-no-supersede"
                    let mockVC = MockExperienceViewController(mockExperienceVersionId: flowId)
                    let gate = ExperiencePresentationTestGate()
                    mockVC.prepareForPresentationHandler = { await gate.wait() }
                    mockExperienceService.mockViewControllers[flowId] = mockVC
                    let validCommit = JourneyPendingPresentation(
                        experienceId: "experience",
                        experienceVersionId: flowId,
                        releaseID: nil,
                        presentationStyle: .fullScreen,
                        screenId: "screen-selected",
                        transition: nil,
                        continuation: []
                    )
                    let validPresentation = Task { @MainActor in
                        try await service.presentExperience(
                            flowId,
                            from: nil,
                            runtimeDelegate: nil,
                            colorSchemeMode: .light,
                            commit: validCommit
                        )
                    }
                    await gate.waitUntilSuspended()

                    mockExperienceService.presentationCommitIsValid = false
                    let invalidCommit = JourneyPendingPresentation(
                        experienceId: "experience",
                        experienceVersionId: flowId,
                        releaseID: nil,
                        presentationStyle: .fullScreen,
                        screenId: "screen-selected",
                        transition: nil,
                        continuation: []
                    )
                    do {
                        _ = try await service.presentExperience(
                            flowId,
                            from: nil,
                            runtimeDelegate: nil,
                            colorSchemeMode: .light,
                            commit: invalidCommit
                        )
                        fail("expected superseded commit")
                    } catch ExperiencePresentationError.presentationSuperseded {
                        // Expected.
                    }

                    // The mock's validity flag is global; the valid call
                    // re-validates after resuming, so restore it first.
                    mockExperienceService.presentationCommitIsValid = true
                    gate.resume()
                    _ = try await validPresentation.value
                    expect(service.isExperiencePresented).to(beTrue())
                }
                
                it("should present view controller in window") { @MainActor in
                    // Setup
                    let flowId = "test-key-window"
                    let mockVC = MockExperienceViewController(mockExperienceVersionId: flowId)
                    mockExperienceService.mockViewControllers[flowId] = mockVC
                    
                    // Present flow
                    try! await service.presentExperience(flowId, from: nil, runtimeDelegate: nil)
                    
                    // Verify window presentation
                    let window = mockWindowProvider.createdWindows.first
                    expect(window?.presentCalled).to(beTrue())
                    expect(window?.isPresenting).to(beTrue())
                    expect(window?.presentedViewController).to(equal(mockVC))
                }
            }
            
            context("when window scene is not available") {
                beforeEach { @MainActor in
                    mockWindowProvider.simulateNoScene()
                }
                
                it("should throw noActiveScene error") { @MainActor in
                    do {
                        _ = try await service.presentExperience("test-flow", from: nil, runtimeDelegate: nil)
                        fail("Expected presentExperience to throw noActiveScene")
                    } catch let error as ExperiencePresentationError {
                        guard case .noActiveScene = error else {
                            fail("Expected .noActiveScene, got \(error)")
                            return
                        }
                    } catch {
                        fail("Unexpected error: \(error)")
                    }
                    
                    // Should not create any windows
                    expect(mockWindowProvider.createdWindows).to(beEmpty())
                }
            }
            
            context("when flow service fails") {
                it("should propagate flow service errors") { @MainActor in
                    // Setup flow service to fail
                    mockExperienceService.shouldFailExperienceDisplay = true
                    mockExperienceService.failureError = MockExperienceServiceError.experienceNotFound("missing-flow")
                    
                    // Act & Assert
                    do {
                        _ = try await service.presentExperience("missing-flow", from: nil, runtimeDelegate: nil)
                        fail("Expected presentExperience to throw")
                    } catch {
                        // Expected.
                    }
                    
                    // Should not create any windows
                    expect(mockWindowProvider.createdWindows).to(beEmpty())
                    expect(service.isExperiencePresented).to(beFalse())
                }
            }
        }
        
        describe("dismissCurrentExperience") {
            it("waits for an owned in-flight window presentation before host cleanup") { @MainActor in
                let flowId = "host-dismiss-during-window-presentation"
                let mockVC = MockExperienceViewController(mockExperienceVersionId: flowId)
                let recorder = ExperiencePresentationLifecycleRecorder()
                let presentationGate = ExperiencePresentationTestGate()
                let hostDismissalStarted = ExperiencePresentationTestSignal()
                mockExperienceService.mockViewControllers[flowId] = mockVC
                mockWindowProvider.presentHandler = {
                    await presentationGate.wait()
                }
                recorder.hostDismissalWillHandler = {
                    hostDismissalStarted.signal()
                }

                let presentation = Task { @MainActor in
                    PollingBox(try await service.presentExperience(
                        flowId,
                        from: nil,
                        runtimeDelegate: recorder
                    ))
                }
                await presentationGate.waitUntilSuspended()

                let dismissal = Task { @MainActor in
                    await service.dismissCurrentExperienceFromHost()
                }
                await hostDismissalStarted.wait()
                presentationGate.resume()
                await dismissal.value

                do {
                    _ = try await presentation.value.value
                    fail("the in-flight presentation should observe host cancellation")
                } catch is CancellationError {
                    // Expected.
                } catch {
                    fail("expected CancellationError, received \(error)")
                }
                let window = mockWindowProvider.createdWindows.first
                expect(recorder.hostDismissalFinished).to(beTrue())
                expect(window?.dismissCalled).to(beTrue())
                expect(window?.destroyCalled).to(beTrue())
                expect(window?.presentedViewController).to(beNil())
                expect(service.isExperiencePresented).to(beFalse())
            }

            it("does not cancel controller acquisition when host dismissal finds no current presentation") { @MainActor in
                let flowId = "host-dismiss-during-controller-acquisition"
                let mockVC = MockExperienceViewController(mockExperienceVersionId: flowId)
                mockExperienceService.mockViewControllers[flowId] = mockVC
                let acquisitionGate = ExperiencePresentationTestGate()
                let suspendedExperiences = SuspendedViewControllerExperienceService(
                    base: mockExperienceService,
                    gate: acquisitionGate
                )
                service = ExperiencePresentationService(
                    windowProvider: mockWindowProvider,
                    experiences: suspendedExperiences,
                    eventLog: mockEventLog,
                    triggerBroker: TriggerBroker(),
                    dateProvider: MockDateProvider()
                )

                let presentation = Task { @MainActor in
                    PollingBox(try await service.presentExperience(
                        flowId,
                        from: nil,
                        runtimeDelegate: nil
                    ))
                }
                await acquisitionGate.waitUntilSuspended()
                expect(service.isExperiencePresented).to(beFalse())

                await service.dismissCurrentExperienceFromHost()
                acquisitionGate.resume()

                do {
                    let presentedController = try await presentation.value.value
                    expect(presentedController).to(beIdenticalTo(mockVC))
                } catch {
                    fail("Host dismissal without a current presentation cancelled acquisition: \(error)")
                }
                expect(service.isExperiencePresented).to(beTrue())
                expect(mockWindowProvider.createdWindows).to(haveCount(1))
                expect(mockWindowProvider.createdWindows.first?.presentCalled).to(beTrue())
            }

            it("shutdown invalidates and joins a presentation suspended before publication") { @MainActor in
                let flowId = "shutdown-during-controller-acquisition"
                let mockVC = MockExperienceViewController(mockExperienceVersionId: flowId)
                let recorder = ExperiencePresentationLifecycleRecorder()
                mockExperienceService.mockViewControllers[flowId] = mockVC
                let acquisitionGate = ExperiencePresentationTestGate()
                let shutdownStarted = ExperiencePresentationTestSignal()
                let suspendedExperiences = SuspendedViewControllerExperienceService(
                    base: mockExperienceService,
                    gate: acquisitionGate
                )
                service = ExperiencePresentationService(
                    windowProvider: mockWindowProvider,
                    experiences: suspendedExperiences,
                    eventLog: mockEventLog,
                    triggerBroker: TriggerBroker(),
                    dateProvider: MockDateProvider()
                )

                let presentation = Task { @MainActor in
                    PollingBox(try await service.presentExperience(
                        flowId,
                        from: nil,
                        runtimeDelegate: recorder
                    ))
                }
                await acquisitionGate.waitUntilSuspended()
                let shutdown = Task { @MainActor in
                    shutdownStarted.signal()
                    await service.shutdownCurrentExperience()
                }
                await shutdownStarted.wait()
                await Task.yield()

                acquisitionGate.resume()
                await shutdown.value

                do {
                    _ = try await presentation.value.value
                    fail("the in-flight presentation should observe shutdown cancellation")
                } catch is CancellationError {
                    // Expected.
                } catch {
                    fail("expected CancellationError, received \(error)")
                }
                expect(mockWindowProvider.createdWindows).to(beEmpty())
                expect(service.isExperiencePresented).to(beFalse())
                expect(recorder.shellWasPresented).to(beFalse())
                expect(recorder.cleanupCompleted).to(beFalse())
                expect(recorder.shellTraceTokens).to(beEmpty())
                expect(recorder.completedTraceTokens).to(beEmpty())
                expect(recorder.hostDismissalStarted).to(beFalse())
                expect(recorder.hostDismissalFinished).to(beFalse())
                expect(recorder.ordinaryDismissalReasons).to(beEmpty())
            }

            it("does not wait for an unrelated stale controller acquisition") { @MainActor in
                let staleFlowId = "stale-controller-acquisition"
                let currentFlowId = "current-during-stale-acquisition"
                mockExperienceService.mockViewControllers[staleFlowId] =
                    MockExperienceViewController(mockExperienceVersionId: staleFlowId)
                let currentController = MockExperienceViewController(
                    mockExperienceVersionId: currentFlowId
                )
                mockExperienceService.mockViewControllers[currentFlowId] = currentController
                let acquisitionGate = ExperiencePresentationTestGate()
                let suspendedExperiences = SuspendedViewControllerExperienceService(
                    base: mockExperienceService,
                    gate: acquisitionGate,
                    suspendedVersionID: staleFlowId
                )
                service = ExperiencePresentationService(
                    windowProvider: mockWindowProvider,
                    experiences: suspendedExperiences,
                    eventLog: mockEventLog,
                    triggerBroker: TriggerBroker(),
                    dateProvider: MockDateProvider()
                )

                let stalePresentation = Task { @MainActor in
                    PollingBox(try await service.presentExperience(
                        staleFlowId,
                        from: nil,
                        runtimeDelegate: nil
                    ))
                }
                await acquisitionGate.waitUntilSuspended()

                let recorder = ExperiencePresentationLifecycleRecorder()
                _ = try! await service.presentExperience(
                    currentFlowId,
                    from: nil,
                    runtimeDelegate: recorder
                )
                let hostDismissal = Task { @MainActor in
                    await service.dismissCurrentExperienceFromHost()
                }

                for _ in 0..<100 where !recorder.hostDismissalFinished {
                    try? await Task.sleep(nanoseconds: 1_000_000)
                }
                let finishedBeforeStaleAcquisition = recorder.hostDismissalFinished

                acquisitionGate.resume()
                do {
                    _ = try await stalePresentation.value.value
                    fail("the superseded acquisition should be cancelled")
                } catch is CancellationError {
                    // Expected.
                } catch {
                    fail("expected CancellationError, received \(error)")
                }
                await hostDismissal.value

                expect(finishedBeforeStaleAcquisition).to(beTrue())
                expect(mockWindowProvider.createdWindows.first?.dismissCalled).to(beTrue())
                expect(service.isExperiencePresented).to(beFalse())
            }

            it("treats host dismissal as a no-op when no experience is presented") { @MainActor in
                expect(service.isExperiencePresented).to(beFalse())

                await service.dismissCurrentExperienceFromHost()

                expect(service.isExperiencePresented).to(beFalse())
                expect(mockWindowProvider.createdWindows).to(beEmpty())
            }

            it("attributes host dismissal to the journey identity") { @MainActor in
                let flowId = "host-dismiss-identity"
                let journeyDistinctId = "journey-user"
                let identity = MockIdentityService()
                identity.setDistinctId("replacement-user")
                mockEventLog.identity = identity

                let journey = Journey(
                    experience: makeExperience(id: "identity-experience"),
                    distinctId: journeyDistinctId,
                    now: Date()
                )
                let mockVC = MockExperienceViewController(
                    mockExperienceVersionId: flowId
                )
                mockExperienceService.mockViewControllers[flowId] = mockVC
                try! await service.presentExperience(
                    flowId,
                    from: journey,
                    runtimeDelegate: nil
                )

                await service.dismissCurrentExperienceFromHost()

                let dismissed = mockEventLog.routedEvents.filter {
                    $0.name == JourneyEvents.experienceDismissed
                }
                expect(dismissed).to(haveCount(1))
                expect(dismissed.first?.distinctId).to(equal(journeyDistinctId))
            }

            it("preserves presentation when terminalization fails") { @MainActor in
                let flowId = "host-dismiss-terminalization-retry"
                let mockVC = MockExperienceViewController(
                    mockExperienceVersionId: flowId
                )
                let recorder = ExperiencePresentationLifecycleRecorder()
                recorder.hostDismissalResult = false
                mockExperienceService.mockViewControllers[flowId] = mockVC
                try! await service.presentExperience(
                    flowId,
                    from: nil,
                    runtimeDelegate: recorder
                )
                let window = mockWindowProvider.createdWindows.first

                await service.dismissCurrentExperienceFromHost()

                expect(service.isExperiencePresented).to(beTrue())
                expect(service.currentExperienceViewController).to(beIdenticalTo(mockVC))
                expect(window?.dismissCalled).to(beFalse())
                expect(window?.destroyCalled).to(beFalse())
                expect(mockVC.prepareForDismissalCallCount).to(equal(0))
                expect(mockVC.shutdownRuntimeCallCount).to(equal(0))

                recorder.hostDismissalResult = true
                await service.dismissCurrentExperienceFromHost()

                expect(service.isExperiencePresented).to(beFalse())
                expect(window?.dismissCalled).to(beTrue())
                expect(window?.destroyCalled).to(beTrue())
                expect(mockVC.prepareForDismissalCallCount).to(equal(1))
                expect(mockVC.shutdownRuntimeCallCount).to(equal(1))
            }

            it("shutdown overrides retry-required host dismissal ownership") { @MainActor in
                let flowId = "shutdown-host-dismiss-terminalization-retry"
                let mockVC = MockExperienceViewController(
                    mockExperienceVersionId: flowId
                )
                let recorder = ExperiencePresentationLifecycleRecorder()
                recorder.hostDismissalResult = false
                mockExperienceService.mockViewControllers[flowId] = mockVC
                try! await service.presentExperience(
                    flowId,
                    from: nil,
                    runtimeDelegate: recorder
                )
                let window = mockWindowProvider.createdWindows.first

                await service.dismissCurrentExperienceFromHost()
                await service.shutdownCurrentExperience()

                expect(service.isExperiencePresented).to(beFalse())
                expect(window?.dismissCalled).to(beTrue())
                expect(window?.destroyCalled).to(beTrue())
                expect(mockVC.prepareForDismissalCallCount).to(equal(1))
                expect(mockVC.shutdownRuntimeCallCount).to(equal(1))
            }

            it("releases host dismissal ownership after identity cancellation removes its journey") { @MainActor in
                let cancelledFlowId = "host-dismiss-cancelled-journey"
                let cancelledVC = MockExperienceViewController(
                    mockExperienceVersionId: cancelledFlowId
                )
                let replacementFlowId = "host-dismiss-after-identity-cancellation"
                let replacementVC = MockExperienceViewController(
                    mockExperienceVersionId: replacementFlowId
                )
                let recorder = ExperiencePresentationLifecycleRecorder()
                recorder.hostDismissalResult = false
                let journey = Journey(
                    experience: makeExperience(id: "cancelled-presentation-journey"),
                    distinctId: "old-user",
                    now: Date()
                )
                mockExperienceService.mockViewControllers[cancelledFlowId] = cancelledVC
                mockExperienceService.mockViewControllers[replacementFlowId] = replacementVC
                try! await service.presentExperience(
                    cancelledFlowId,
                    from: journey,
                    runtimeDelegate: recorder
                )
                let cancelledWindow = mockWindowProvider.createdWindows[0]

                // Identity transition cancellation has already removed this
                // journey from its owner before the host callback arrives.
                await journey.cancel(at: Date())
                await service.dismissCurrentExperienceFromHost()

                expect(service.isExperiencePresented).to(beFalse())
                expect(cancelledWindow.dismissCalled).to(beTrue())
                expect(cancelledWindow.destroyCalled).to(beTrue())
                expect(cancelledVC.shutdownRuntimeCallCount).to(equal(1))

                let replacement = try! await service.presentExperience(
                    replacementFlowId,
                    from: nil,
                    runtimeDelegate: nil
                )
                expect(replacement).to(beIdenticalTo(replacementVC))
                expect(service.currentExperienceViewController)
                    .to(beIdenticalTo(replacementVC))
            }

            it("keeps queued replacement behind a failed host dismissal until retry succeeds") { @MainActor in
                let currentFlowId = "host-dismiss-failed-current"
                let currentVC = MockExperienceViewController(
                    mockExperienceVersionId: currentFlowId
                )
                let replacementFlowId = "host-dismiss-failed-replacement"
                let replacementVC = MockExperienceViewController(
                    mockExperienceVersionId: replacementFlowId
                )
                let recorder = ExperiencePresentationLifecycleRecorder()
                let firstTerminalizationGate = ExperiencePresentationTestGate()
                recorder.hostDismissalResult = false
                recorder.hostDismissalHandler = {
                    await firstTerminalizationGate.wait()
                }
                mockExperienceService.mockViewControllers[currentFlowId] = currentVC
                mockExperienceService.mockViewControllers[replacementFlowId] = replacementVC
                try! await service.presentExperience(
                    currentFlowId,
                    from: nil,
                    runtimeDelegate: recorder
                )
                let currentWindow = mockWindowProvider.createdWindows[0]

                let failedDismissal = Task { @MainActor in
                    await service.dismissCurrentExperienceFromHost()
                }
                await firstTerminalizationGate.waitUntilSuspended()

                let replacementStarted = ExperiencePresentationTestSignal()
                let replacement = Task { @MainActor in
                    replacementStarted.signal()
                    return PollingBox(try await service.presentExperience(
                        replacementFlowId,
                        from: nil,
                        runtimeDelegate: nil
                    ))
                }
                await replacementStarted.wait()
                await Task.yield()

                firstTerminalizationGate.resume()
                await failedDismissal.value
                for _ in 0..<100
                where !currentWindow.destroyCalled
                    && replacementVC.prepareForPresentationCallCount == 0 {
                    await Task.yield()
                }

                expect(service.currentExperienceViewController).to(beIdenticalTo(currentVC))
                expect(currentWindow.dismissCalled).to(beFalse())
                expect(currentWindow.destroyCalled).to(beFalse())
                expect(currentVC.shutdownRuntimeCallCount).to(equal(0))
                expect(replacementVC.prepareForPresentationCallCount).to(equal(0))
                expect(mockWindowProvider.createdWindows).to(haveCount(1))

                recorder.hostDismissalHandler = nil
                recorder.hostDismissalResult = true
                await service.dismissCurrentExperienceFromHost()
                let presentedReplacement = try! await replacement.value.value

                expect(currentWindow.dismissCalled).to(beTrue())
                expect(currentWindow.destroyCalled).to(beTrue())
                expect(currentVC.shutdownRuntimeCallCount).to(equal(1))
                expect(presentedReplacement).to(beIdenticalTo(replacementVC))
                expect(service.currentExperienceViewController).to(beIdenticalTo(replacementVC))
                expect(mockWindowProvider.createdWindows).to(haveCount(2))
            }

            it("releases concurrent host callers after a failed attempt without releasing presentation ownership") { @MainActor in
                let flowId = "host-dismiss-concurrent-failure"
                let mockVC = MockExperienceViewController(
                    mockExperienceVersionId: flowId
                )
                let recorder = ExperiencePresentationLifecycleRecorder()
                let firstTerminalizationGate = ExperiencePresentationTestGate()
                recorder.hostDismissalResult = false
                recorder.hostDismissalHandler = {
                    await firstTerminalizationGate.wait()
                }
                mockExperienceService.mockViewControllers[flowId] = mockVC
                try! await service.presentExperience(
                    flowId,
                    from: nil,
                    runtimeDelegate: recorder
                )
                let window = mockWindowProvider.createdWindows[0]

                let failedDismissal = Task { @MainActor in
                    await service.dismissCurrentExperienceFromHost()
                }
                await firstTerminalizationGate.waitUntilSuspended()

                let concurrentDismissalStarted = ExperiencePresentationTestSignal()
                let concurrentDismissalFinished = ExperiencePresentationTestSignal()
                let concurrentDismissal = Task { @MainActor in
                    concurrentDismissalStarted.signal()
                    await service.dismissCurrentExperienceFromHost()
                    concurrentDismissalFinished.signal()
                }
                await concurrentDismissalStarted.wait()

                firstTerminalizationGate.resume()
                await failedDismissal.value
                for _ in 0..<100 where !concurrentDismissalFinished.isSignaled {
                    await Task.yield()
                }

                expect(concurrentDismissalFinished.isSignaled).to(beTrue())
                expect(service.currentExperienceViewController).to(beIdenticalTo(mockVC))
                expect(window.dismissCalled).to(beFalse())
                expect(window.destroyCalled).to(beFalse())

                recorder.hostDismissalHandler = nil
                recorder.hostDismissalResult = true
                await service.dismissCurrentExperienceFromHost()
                await concurrentDismissal.value

                expect(service.isExperiencePresented).to(beFalse())
                expect(window.dismissCalled).to(beTrue())
                expect(window.destroyCalled).to(beTrue())
            }

            it("waits for an in-flight purchase before host dismissal") { @MainActor in
                let testStore = SuspendedExperienceTestStore()
                let transactionService = TransactionService(
                    productService: ProductService(),
                    transactionObserver: MockTransactionObserver(),
                    pendingPurchaseStore: InMemoryPendingPurchaseStore(),
                    dateProvider: MockDateProvider(),
                    settings: NuxieRuntimeSettings(
                        configuration: NuxieConfiguration(apiKey: "host-dismiss-purchase")
                    ),
                    eventSink: DiscardingSystemEventSink(),
                    testStore: testStore
                )
                var product = StoreProduct(
                    productId: "product-1",
                    placementId: "placement-1",
                    name: "Test product",
                    price: "$1.00",
                    period: nil
                )
                product.isTestStoreProduct = true
                let flowId = "host-dismiss-purchase"
                let mockVC = MockExperienceViewController(
                    mockExperienceVersionId: flowId,
                    products: [product],
                    transactionService: transactionService
                )
                let recorder = ExperiencePresentationLifecycleRecorder()
                let hostReservationEntered = ExperiencePresentationTestSignal()
                let hostReservationGate = ExperiencePresentationTestSignal()
                recorder.hostDismissalWillHandler = {
                    hostReservationEntered.signal()
                    await hostReservationGate.wait()
                }
                mockExperienceService.mockViewControllers[flowId] = mockVC
                try! await service.presentExperience(
                    flowId,
                    from: nil,
                    runtimeDelegate: recorder
                )

                mockVC.performPurchase(placementId: product.placementId)
                await testStore.waitUntilPurchaseStarts()
                let dismissal = Task { @MainActor in
                    await service.dismissCurrentExperienceFromHost()
                }
                await hostReservationEntered.wait()

                expect(service.isExperiencePresented).to(beTrue())
                expect(mockWindowProvider.createdWindows.first?.dismissCalled).to(beFalse())

                mockVC.performDismiss(reason: .userDismissed)
                await Task.yield()
                expect(recorder.ordinaryDismissalReasons).to(beEmpty())

                hostReservationGate.signal()
                await testStore.resolvePurchase(.cancelled)
                await dismissal.value

                expect(service.isExperiencePresented).to(beFalse())
                expect(mockWindowProvider.createdWindows.first?.dismissCalled).to(beTrue())
                expect(recorder.hostDismissalFinished).to(beTrue())
                expect(recorder.ordinaryDismissalReasons).to(beEmpty())
            }

            it("waits for an in-flight restore before host dismissal") { @MainActor in
                let testStore = SuspendedExperienceTestStore()
                let transactionService = TransactionService(
                    productService: ProductService(),
                    transactionObserver: MockTransactionObserver(),
                    pendingPurchaseStore: InMemoryPendingPurchaseStore(),
                    dateProvider: MockDateProvider(),
                    settings: NuxieRuntimeSettings(
                        configuration: NuxieConfiguration(apiKey: "host-dismiss-restore")
                    ),
                    eventSink: DiscardingSystemEventSink(),
                    testStore: testStore
                )
                let flowId = "host-dismiss-restore"
                let mockVC = MockExperienceViewController(
                    mockExperienceVersionId: flowId,
                    transactionService: transactionService
                )
                let recorder = ExperiencePresentationLifecycleRecorder()
                mockExperienceService.mockViewControllers[flowId] = mockVC
                try! await service.presentExperience(
                    flowId,
                    from: nil,
                    runtimeDelegate: recorder
                )

                mockVC.performRestore()
                await testStore.waitUntilRestoreStarts()
                let dismissal = Task { @MainActor in
                    await service.dismissCurrentExperienceFromHost()
                }
                await Task.yield()

                expect(service.isExperiencePresented).to(beTrue())
                expect(mockWindowProvider.createdWindows.first?.dismissCalled).to(beFalse())

                await testStore.resolveRestore()
                await dismissal.value

                expect(service.isExperiencePresented).to(beFalse())
                expect(mockWindowProvider.createdWindows.first?.dismissCalled).to(beTrue())
                expect(recorder.hostDismissalFinished).to(beTrue())
            }

            it("serializes replacement behind purchase-gated host dismissal") { @MainActor in
                let testStore = SuspendedExperienceTestStore()
                let transactionService = TransactionService(
                    productService: ProductService(),
                    transactionObserver: MockTransactionObserver(),
                    pendingPurchaseStore: InMemoryPendingPurchaseStore(),
                    dateProvider: MockDateProvider(),
                    settings: NuxieRuntimeSettings(
                        configuration: NuxieConfiguration(apiKey: "host-dismiss-replacement")
                    ),
                    eventSink: DiscardingSystemEventSink(),
                    testStore: testStore
                )
                var product = StoreProduct(
                    productId: "product-1",
                    placementId: "placement-1",
                    name: "Test product",
                    price: "$1.00",
                    period: nil
                )
                product.isTestStoreProduct = true
                let currentFlowId = "purchase-current"
                let currentVC = MockExperienceViewController(
                    mockExperienceVersionId: currentFlowId,
                    products: [product],
                    transactionService: transactionService
                )
                let replacementFlowId = "purchase-replacement"
                let replacementVC = MockExperienceViewController(
                    mockExperienceVersionId: replacementFlowId
                )
                mockExperienceService.mockViewControllers[currentFlowId] = currentVC
                mockExperienceService.mockViewControllers[replacementFlowId] = replacementVC

                var lifecycle: [String] = []
                let recorder = ExperiencePresentationLifecycleRecorder()
                let terminalizationGate = ExperiencePresentationTestSignal()
                recorder.hostDismissalHandler = {
                    lifecycle.append("host-terminalization-started")
                    await terminalizationGate.wait()
                    lifecycle.append("host-terminalized")
                }
                var replacementSawHostTerminalization = false
                replacementVC.prepareForPresentationHandler = {
                    replacementSawHostTerminalization = recorder.hostDismissalFinished
                    lifecycle.append("replacement-prepare")
                }
                try! await service.presentExperience(
                    currentFlowId,
                    from: nil,
                    runtimeDelegate: recorder
                )
                let currentWindow = mockWindowProvider.createdWindows[0]

                currentVC.performPurchase(placementId: product.placementId)
                await testStore.waitUntilPurchaseStarts()
                let dismissal = Task { @MainActor in
                    await service.dismissCurrentExperienceFromHost()
                }
                await Task.yield()

                let replacementStarted = ExperiencePresentationTestSignal()
                let replacement = Task { @MainActor in
                    replacementStarted.signal()
                    return PollingBox(try await service.presentExperience(
                        replacementFlowId,
                        from: nil,
                        runtimeDelegate: nil
                    ))
                }
                await replacementStarted.wait()
                await Task.yield()
                let staleDismissal = Task { @MainActor in
                    await service.dismissCurrentExperience(reason: .userDismissed)
                }
                await Task.yield()

                expect(service.currentExperienceViewController).to(beIdenticalTo(currentVC))
                expect(currentWindow.dismissCalled).to(beFalse())
                expect(currentWindow.destroyCalled).to(beFalse())
                expect(currentVC.shutdownRuntimeCallCount).to(equal(0))
                expect(replacementVC.prepareForPresentationCallCount).to(equal(0))
                expect(mockWindowProvider.createdWindows).to(haveCount(1))

                await testStore.resolvePurchase(.cancelled)
                await polling(expect { recorder.hostDismissalStarted }).value
                    .toEventually(beTrue(), timeout: .seconds(1))

                expect(recorder.hostDismissalFinished).to(beFalse())
                expect(service.currentExperienceViewController).to(beIdenticalTo(currentVC))
                expect(currentWindow.dismissCalled).to(beFalse())
                expect(currentWindow.destroyCalled).to(beFalse())
                expect(currentVC.shutdownRuntimeCallCount).to(equal(0))
                expect(replacementVC.prepareForPresentationCallCount).to(equal(0))
                expect(mockWindowProvider.createdWindows).to(haveCount(1))

                terminalizationGate.signal()
                await dismissal.value
                let presentedReplacement = try! await replacement.value.value
                await staleDismissal.value

                expect(lifecycle).to(equal([
                    "host-terminalization-started",
                    "host-terminalized",
                    "replacement-prepare",
                ]))
                expect(recorder.hostDismissalFinished).to(beTrue())
                expect(replacementSawHostTerminalization).to(beTrue())
                expect(currentWindow.dismissCalled).to(beTrue())
                expect(currentWindow.destroyCalled).to(beTrue())
                expect(currentVC.shutdownRuntimeCallCount).to(equal(1))
                expect(presentedReplacement).to(beIdenticalTo(replacementVC))
                expect(service.currentExperienceViewController).to(beIdenticalTo(replacementVC))
                expect(mockWindowProvider.createdWindows).to(haveCount(2))
                expect(mockWindowProvider.createdWindows[1].presentedViewController)
                    .to(beIdenticalTo(replacementVC))
            }

            it("lets host dismissal own cleanup that a replacement already started") { @MainActor in
                let testStore = SuspendedExperienceTestStore()
                let transactionService = TransactionService(
                    productService: ProductService(),
                    transactionObserver: MockTransactionObserver(),
                    pendingPurchaseStore: InMemoryPendingPurchaseStore(),
                    dateProvider: MockDateProvider(),
                    settings: NuxieRuntimeSettings(
                        configuration: NuxieConfiguration(apiKey: "host-dismiss-started-cleanup")
                    ),
                    eventSink: DiscardingSystemEventSink(),
                    testStore: testStore
                )
                var product = StoreProduct(
                    productId: "product-1",
                    placementId: "placement-1",
                    name: "Test product",
                    price: "$1.00",
                    period: nil
                )
                product.isTestStoreProduct = true

                let currentFlowId = "started-cleanup-current"
                let currentVC = MockExperienceViewController(
                    mockExperienceVersionId: currentFlowId,
                    products: [product],
                    transactionService: transactionService
                )
                let cleanupGate = ExperiencePresentationTestGate()
                currentVC.prepareForDismissalHandler = {
                    await cleanupGate.wait()
                }
                let replacementFlowId = "started-cleanup-replacement"
                let replacementVC = MockExperienceViewController(
                    mockExperienceVersionId: replacementFlowId
                )
                let recorder = ExperiencePresentationLifecycleRecorder()
                mockExperienceService.mockViewControllers[currentFlowId] = currentVC
                mockExperienceService.mockViewControllers[replacementFlowId] = replacementVC

                try! await service.presentExperience(
                    currentFlowId,
                    from: nil,
                    runtimeDelegate: recorder
                )
                let currentWindow = mockWindowProvider.createdWindows[0]
                currentVC.performPurchase(placementId: product.placementId)
                await testStore.waitUntilPurchaseStarts()

                let replacement = Task { @MainActor in
                    PollingBox(try await service.presentExperience(
                        replacementFlowId,
                        from: nil,
                        runtimeDelegate: nil
                    ))
                }
                await cleanupGate.waitUntilSuspended()

                let hostDismissal = Task { @MainActor in
                    await service.dismissCurrentExperienceFromHost()
                }
                await Task.yield()
                cleanupGate.resume()

                do {
                    _ = try await replacement.value.value
                    fail("replacement should be cancelled once host dismissal owns the presentation")
                } catch is CancellationError {
                    // Expected.
                } catch {
                    fail("expected CancellationError, received \(error)")
                }

                expect(service.currentExperienceViewController).to(beIdenticalTo(currentVC))
                expect(currentWindow.dismissCalled).to(beFalse())
                expect(currentWindow.destroyCalled).to(beFalse())
                expect(replacementVC.prepareForPresentationCallCount).to(equal(0))

                await testStore.resolvePurchase(.cancelled)
                await hostDismissal.value

                expect(recorder.hostDismissalFinished).to(beTrue())
                expect(service.isExperiencePresented).to(beFalse())
                expect(currentWindow.dismissCalled).to(beTrue())
                expect(currentWindow.destroyCalled).to(beTrue())
            }

            it("should dismiss presented flow") { @MainActor in
                // Present a flow first
                let flowId = "test-dismiss"
                let mockVC = MockExperienceViewController(mockExperienceVersionId: flowId)
                mockExperienceService.mockViewControllers[flowId] = mockVC
                
                try! await service.presentExperience(flowId, from: nil, runtimeDelegate: nil)
                expect(service.isExperiencePresented).to(beTrue())
                
                // Dismiss it
                await service.dismissCurrentExperience()
                
                // Verify dismissal
                expect(service.isExperiencePresented).to(beFalse())
                let window = mockWindowProvider.createdWindows.first
                expect(window?.dismissCalled).to(beTrue())
            }
            
            it("should handle dismissal when no flow is presented") { @MainActor in
                // No flow presented
                expect(service.isExperiencePresented).to(beFalse())
                
                // Should not crash
                await service.dismissCurrentExperience()
                
                // Still no flow
                expect(service.isExperiencePresented).to(beFalse())
            }

            it("detaches runtime ownership before destroying the window") { @MainActor in
                var lifecycle: [String] = []
                mockWindowProvider.onWindowLifecycleEvent = { lifecycle.append($0) }
                let flowId = "ordered-cleanup"
                let mockVC = MockExperienceViewController(mockExperienceVersionId: flowId)
                mockVC.onRuntimeLifecycleEvent = { lifecycle.append("runtime-\($0)") }
                mockExperienceService.mockViewControllers[flowId] = mockVC
                try! await service.presentExperience(flowId, from: nil, runtimeDelegate: nil)
                lifecycle.removeAll()

                await service.dismissCurrentExperience()

                expect(lifecycle).to(equal([
                    "runtime-prepare-dismissal",
                    "window-dismiss",
                    "runtime-shutdown",
                    "window-destroy",
                ]))
            }

            it("delivers screen dismissal before runtime teardown") { @MainActor in
                var lifecycle: [String] = []
                mockWindowProvider.onWindowLifecycleEvent = { lifecycle.append($0) }
                let flowId = "screen-dismissal-order"
                let mockVC = MockExperienceViewController(mockExperienceVersionId: flowId)
                mockVC.shutdownRuntimeHandler = {
                    lifecycle.append("runtime-shutdown")
                }
                let runtimeDelegate = ScreenDismissalOrderRuntimeDelegate {
                    lifecycle.append("$screen_dismissed")
                }
                mockExperienceService.mockViewControllers[flowId] = mockVC
                try! await service.presentExperience(
                    flowId,
                    from: nil,
                    runtimeDelegate: runtimeDelegate
                )
                lifecycle.removeAll()

                await service.dismissCurrentExperience()

                expect(lifecycle).to(equal([
                    "$screen_dismissed",
                    "window-dismiss",
                    "runtime-shutdown",
                    "window-destroy",
                ]))
            }
        }
        
        describe("isExperiencePresented") {
            it("should reflect presentation state accurately") { @MainActor in
                // Initially no flow
                expect(service.isExperiencePresented).to(beFalse())
                
                // Present flow
                let flowId = "state-test"
                let mockVC = MockExperienceViewController(mockExperienceVersionId: flowId)
                mockExperienceService.mockViewControllers[flowId] = mockVC
                
                try! await service.presentExperience(flowId, from: nil, runtimeDelegate: nil)
                expect(service.isExperiencePresented).to(beTrue())
                
                // Dismiss flow
                await service.dismissCurrentExperience()
                expect(service.isExperiencePresented).to(beFalse())
            }
        }
        
        describe("journey integration") {
            it("should accept journey context") { @MainActor in
                // Create mock experience and journey using TestBuilders
                let experience = makeExperience(id: "experience-1")

                let journey = Journey(
                    experience: experience,
                    distinctId: "user-1",
                    now: Date()
                )
                
                // Present with journey
                let flowId = "journey-flow"
                let mockVC = MockExperienceViewController(mockExperienceVersionId: flowId)
                mockExperienceService.mockViewControllers[flowId] = mockVC
                
                do {
                    _ = try await service.presentExperience(flowId, from: journey, runtimeDelegate: nil)
                } catch {
                    fail("Unexpected presentExperience error: \(error)")
                }
                
                // Verify presentation
                expect(service.isExperiencePresented).to(beTrue())
                
                // Verify journey context is stored
                expect(service.currentJourney?.id).toNot(beNil())
            }
            
            it("should handle nil journey context") { @MainActor in
                let flowId = "no-journey-flow"
                let mockVC = MockExperienceViewController(mockExperienceVersionId: flowId)
                mockExperienceService.mockViewControllers[flowId] = mockVC
                
                do {
                    _ = try await service.presentExperience(flowId, from: nil, runtimeDelegate: nil)
                } catch {
                    fail("Unexpected presentExperience error: \(error)")
                }
                
                expect(service.isExperiencePresented).to(beTrue())
                expect(service.currentJourney).to(beNil())
            }
        }
        
        describe("window management") {
            it("should create window and present view controller") { @MainActor in
                let flowId = "window-props"
                let mockVC = MockExperienceViewController(mockExperienceVersionId: flowId)
                mockExperienceService.mockViewControllers[flowId] = mockVC
                
                try! await service.presentExperience(flowId, from: nil, runtimeDelegate: nil)
                
                let window = mockWindowProvider.createdWindows.first
                expect(window).toNot(beNil())
                expect(window?.presentCalled).to(beTrue())
                expect(window?.presentedViewController).to(equal(mockVC))
                expect(window?.isPresenting).to(beTrue())
            }
            
            it("should properly clean up window on dismissal") { @MainActor in
                let flowId = "cleanup-test"
                let mockVC = MockExperienceViewController(mockExperienceVersionId: flowId)
                mockExperienceService.mockViewControllers[flowId] = mockVC
                
                try! await service.presentExperience(flowId, from: nil, runtimeDelegate: nil)
                let window = mockWindowProvider.createdWindows.first
                
                // Simulate dismissal
                mockVC.onClose?(.userDismissed)
                
                // Wait for cleanup
                await polling(expect(service.isExperiencePresented)).value
                    .toEventually(beFalse(), timeout: .seconds(2))
                
                // Verify cleanup
                expect(window?.destroyCalled).to(beTrue())
                expect(window?.presentedViewController).to(beNil())
            }
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
    ) {}
}

@MainActor
private final class ExperiencePresentationTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let waiters = suspensionWaiters
            suspensionWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func waitUntilSuspended() async {
        guard continuation == nil else { return }
        await withCheckedContinuation { continuation in
            suspensionWaiters.append(continuation)
        }
    }

    func resume() {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume()
    }
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

private final class SuspendedViewControllerExperienceService:
    ExperienceServiceProtocol,
    @unchecked Sendable {
    private let base: MockExperienceService
    private let gate: ExperiencePresentationTestGate
    private let suspendedVersionID: String?

    init(
        base: MockExperienceService,
        gate: ExperiencePresentationTestGate,
        suspendedVersionID: String? = nil
    ) {
        self.base = base
        self.gate = gate
        self.suspendedVersionID = suspendedVersionID
    }

    func fetchExperience(id: String) async throws -> Experience {
        try await base.fetchExperience(id: id)
    }

    func fetchExperience(
        experienceId: String,
        versionId: String
    ) async throws -> Experience {
        try await base.fetchExperience(
            experienceId: experienceId,
            versionId: versionId
        )
    }

    @MainActor
    func viewController(for versionId: String) async throws -> ExperienceViewController {
        try await base.viewController(for: versionId)
    }

    @MainActor
    func viewController(
        for versionId: String,
        colorSchemeMode: ExperienceColorSchemeMode
    ) async throws -> ExperienceViewController {
        try await base.viewController(
            for: versionId,
            colorSchemeMode: colorSchemeMode
        )
    }

    @MainActor
    func viewController(
        for versionId: String,
        runtimeDelegate: ExperienceRuntimeDelegate?
    ) async throws -> ExperienceViewController {
        try await base.viewController(
            for: versionId,
            runtimeDelegate: runtimeDelegate
        )
    }

    @MainActor
    func viewController(
        for versionId: String,
        runtimeDelegate: ExperienceRuntimeDelegate?,
        colorSchemeMode: ExperienceColorSchemeMode
    ) async throws -> ExperienceViewController {
        try await base.viewController(
            for: versionId,
            runtimeDelegate: runtimeDelegate,
            colorSchemeMode: colorSchemeMode
        )
    }

    @MainActor
    func viewController(
        for versionId: String,
        runtimeDelegate: ExperienceRuntimeDelegate?,
        colorSchemeMode: ExperienceColorSchemeMode,
        presentationTraceContext: ExperiencePresentationTraceContext?,
        initialScreenID: String?
    ) async throws -> ExperienceViewController {
        if suspendedVersionID == nil || suspendedVersionID == versionId {
            await gate.wait()
        }
        return try await base.viewController(
            for: versionId,
            runtimeDelegate: runtimeDelegate,
            colorSchemeMode: colorSchemeMode,
            presentationTraceContext: presentationTraceContext,
            initialScreenID: initialScreenID
        )
    }

    func clearCache() async {
        await base.clearCache()
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
