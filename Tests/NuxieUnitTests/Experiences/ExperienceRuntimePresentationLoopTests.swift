#if canImport(UIKit) && canImport(QuartzCore)
import Metal
import QuartzCore
import XCTest
@testable import Nuxie

final class ExperienceRuntimePresentationLoopTests: XCTestCase {
    @MainActor
    func testVisibleSessionKeepsTickingAcrossCompletedSteps() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is unavailable")
        }
        let recorder = PresentationSessionRecorder(device: device)
        let (window, view) = makePresentationSurface()
        let loop = makeLoop(recorder: recorder, view: view)

        try await loop.start()
        loop.displayLinkDidFire(at: 1)
        let firstRender = await recorder.waitForRenderCount(1)
        XCTAssertTrue(firstRender)
        loop.displayLinkDidFire(at: 2)
        let secondRender = await recorder.waitForRenderCount(2)
        XCTAssertTrue(secondRender)
        let steps = await recorder.steps()
        XCTAssertEqual(steps.count, 2)

        await loop.shutdown()
        _ = window
    }

    @MainActor
    func testStepDeliveryCompletesBeforeItsRenderAndAdvanceNotification() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is unavailable")
        }
        let recorder = PresentationSessionRecorder(device: device)
        let (window, view) = makePresentationSurface()
        var advanceCount = 0
        let loop = makeLoop(recorder: recorder, view: view, onSessionResult: {
            advanceCount += 1
        })

        try await loop.start()
        await recorder.holdNextDelivery()
        loop.displayLinkDidFire(at: 1)
        let stepped = await recorder.waitForStepCount(1)
        let namesBeforeDelivery = await recorder.operationNames()
        XCTAssertTrue(stepped)
        XCTAssertFalse(namesBeforeDelivery.contains("render"))
        XCTAssertEqual(advanceCount, 0)

        await recorder.releaseDelivery()
        let rendered = await recorder.waitForOperation(named: "render")
        XCTAssertTrue(rendered)
        XCTAssertEqual(advanceCount, 1)

        await loop.shutdown()
        _ = window
    }

    @MainActor
    func testZeroDeltaAcknowledgementWaitsForNativePresentationCompletion() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is unavailable")
        }
        let recorder = PresentationSessionRecorder(device: device)
        await recorder.setCompletionMode(.held)
        let (window, view) = makePresentationSurface()
        let loop = makeLoop(recorder: recorder, view: view)
        let completion = AsyncBooleanProbe()
        try await loop.start()

        let advance = Task { @MainActor in
            try await loop.advanceZeroDelta()
            await completion.setTrue()
        }
        let rendered = await recorder.waitForOperation(named: "render")
        XCTAssertTrue(rendered)
        await Task.yield()
        let completedBeforeRelease = await completion.value()
        XCTAssertFalse(completedBeforeRelease)

        await recorder.releaseFrames()
        try await advance.value
        let completedAfterRelease = await completion.value()
        XCTAssertTrue(completedAfterRelease)

        await loop.shutdown()
        _ = window
    }

    @MainActor
    func testConfiguresRealCAMetalLayerAndCompletesOneNativeFrameExactlyOnce() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is unavailable")
        }
        let recorder = PresentationSessionRecorder(device: device)
        let (window, view) = makePresentationSurface()
        var deliveredStepCount = 0
        let loop = makeLoop(recorder: recorder, view: view, onSessionResult: {
            deliveredStepCount += 1
        })

        try await loop.start()
        loop.displayLinkDidFire(at: 1)

        let rendered = await recorder.waitForOperation(named: "render")
        let names = await recorder.operationNames()
        let completionCount = await recorder.nativeCompletionCount()
        XCTAssertTrue(rendered)
        XCTAssertEqual(
            names,
            ["metalDevice", "resize", "step", "render"]
        )
        XCTAssertTrue(view.metalLayer.device === device)
        XCTAssertEqual(view.metalLayer.pixelFormat, .bgra8Unorm)
        XCTAssertTrue(view.metalLayer.framebufferOnly)
        XCTAssertEqual(deliveredStepCount, 1)
        XCTAssertEqual(completionCount, 1)

        await loop.shutdown()
        _ = window
    }

    @MainActor
    func testPresentedDrawableWaitsForDisplayPresentation() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is unavailable")
        }
        let recorder = PresentationSessionRecorder(device: device)
        await recorder.setCompletionMode(.held)
        let (window, view) = makePresentationSurface()
        var presentedDrawables: [ExperienceRuntimePresentedDrawable] = []
        var presentationHandler: (@Sendable (
            TimeInterval,
            ExperienceRuntimePresentedDrawable.Provenance
        ) -> Void)?
        let loop = makeLoop(
            recorder: recorder,
            view: view,
            onPresentedDrawable: { presentedDrawables.append($0) },
            observeDrawablePresentation: { _, handler in
                presentationHandler = handler
            },
            nativeCompletionPresentationFallback: nil
        )

        try await loop.start()
        loop.displayLinkDidFire(at: 1)

        let rendered = await recorder.waitForOperation(named: "render")
        XCTAssertTrue(rendered)
        await Task.yield()
        XCTAssertEqual(presentedDrawables.count, 0)

        presentationHandler?(42, .injectedTestObserver)
        presentationHandler?(43, .injectedTestObserver)
        for _ in 0..<300 where presentedDrawables.isEmpty {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(presentedDrawables.count, 1)
        XCTAssertEqual(presentedDrawables.first?.frameNumber, 1)
        XCTAssertEqual(presentedDrawables.first?.provenance, .injectedTestObserver)
        XCTAssertEqual(presentedDrawables.first?.isConfirmedDisplayPresentation, false)

        await recorder.releaseFrames()
        await loop.shutdown()
        _ = window
    }

    @MainActor
    func testPresentedDrawableCarriesRenderSequenceAfterSkippedFrame() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is unavailable")
        }
        let recorder = PresentationSessionRecorder(device: device)
        let (window, view) = makePresentationSurface()
        var acquisitionCount = 0
        var observations: [ExperienceRuntimePresentedDrawable] = []
        let loop = makeLoop(
            recorder: recorder,
            view: view,
            acquireDrawable: { layer in
                acquisitionCount += 1
                return acquisitionCount == 1 ? nil : layer.nextDrawable()
            },
            onPresentedDrawable: { observations.append($0) },
            observeDrawablePresentation: { _, handler in
                handler(42, .injectedTestObserver)
            },
            nativeCompletionPresentationFallback: nil
        )

        try await loop.start()
        loop.displayLinkDidFire(at: 1)
        let firstRendered = await recorder.waitForRenderCount(1)
        XCTAssertTrue(firstRendered)
        loop.displayLinkDidFire(at: 2)
        let secondRendered = await recorder.waitForRenderCount(2)
        XCTAssertTrue(secondRendered)
        for _ in 0..<300 where observations.isEmpty {
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        XCTAssertEqual(observations.first?.frameNumber, 2)
        await loop.shutdown()
        _ = window
    }

    @MainActor
    func testRuntimeCompletionProxyIsExplicitlyProvisional() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is unavailable")
        }
        let recorder = PresentationSessionRecorder(device: device)
        await recorder.setCompletionMode(.held)
        let (window, view) = makePresentationSurface()
        var observations: [ExperienceRuntimePresentedDrawable] = []
        let loop = makeLoop(
            recorder: recorder,
            view: view,
            onPresentedDrawable: { observations.append($0) },
            nativeCompletionPresentationFallback: .runtimeCompletionProxy
        )

        try await loop.start()
        loop.displayLinkDidFire(at: 1)
        let rendered = await recorder.waitForOperation(named: "render")
        XCTAssertTrue(rendered)
        XCTAssertTrue(observations.isEmpty)

        await recorder.releaseFrames()
        for _ in 0..<300 where observations.isEmpty {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(observations.first?.provenance, .runtimeCompletionProxy)
        XCTAssertEqual(observations.first?.isConfirmedDisplayPresentation, false)

        await loop.shutdown()
        _ = window
    }

    func testOnlyPhysicalPresentedHandlerProvenanceQualifiesAsConfirmed() {
        let makeObservation: (ExperienceRuntimePresentedDrawable.Provenance)
            -> ExperienceRuntimePresentedDrawable = {
                ExperienceRuntimePresentedDrawable(
                    presentedTime: 1,
                    pixelWidth: 1,
                    pixelHeight: 1,
                    drawCalls: 1,
                    provenance: $0
                )
            }

        XCTAssertTrue(
            makeObservation(.physicalPresentedHandler).isConfirmedDisplayPresentation
        )
        XCTAssertFalse(
            makeObservation(.runtimeCompletionProxy).isConfirmedDisplayPresentation
        )
        XCTAssertFalse(
            makeObservation(.injectedTestObserver).isConfirmedDisplayPresentation
        )
    }

    @MainActor
    func testPresentedDrawableMilestoneLatchesAfterFirstFrame() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is unavailable")
        }
        let recorder = PresentationSessionRecorder(device: device)
        let (window, view) = makePresentationSurface()
        var handlers: [@Sendable (
            TimeInterval,
            ExperienceRuntimePresentedDrawable.Provenance
        ) -> Void] = []
        var observations: [ExperienceRuntimePresentedDrawable] = []
        let loop = makeLoop(
            recorder: recorder,
            view: view,
            onPresentedDrawable: { observations.append($0) },
            observeDrawablePresentation: { _, handler in handlers.append(handler) },
            nativeCompletionPresentationFallback: nil
        )

        try await loop.start()
        loop.displayLinkDidFire(at: 1)
        let firstRendered = await recorder.waitForRenderCount(1)
        XCTAssertTrue(firstRendered)
        handlers[0](10, .injectedTestObserver)
        for _ in 0..<300 where observations.isEmpty {
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        loop.displayLinkDidFire(at: 2)
        let secondRendered = await recorder.waitForRenderCount(2)
        XCTAssertTrue(secondRendered)
        await Task.yield()

        XCTAssertEqual(handlers.count, 1)
        XCTAssertEqual(observations.count, 1)
        XCTAssertEqual(observations.first?.presentedTime, 10)
        await loop.shutdown()
        _ = window
    }

    @MainActor
    func testPresentedDrawableMilestoneWaitsForFirstCompleteFrame() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is unavailable")
        }
        let recorder = PresentationSessionRecorder(device: device)
        await recorder.enqueuePresentedDrawCalls([0, 1])
        let (window, view) = makePresentationSurface()
        var handlers: [@Sendable (
            TimeInterval,
            ExperienceRuntimePresentedDrawable.Provenance
        ) -> Void] = []
        var observations: [ExperienceRuntimePresentedDrawable] = []
        let loop = makeLoop(
            recorder: recorder,
            view: view,
            onPresentedDrawable: { observations.append($0) },
            observeDrawablePresentation: { _, handler in handlers.append(handler) },
            nativeCompletionPresentationFallback: nil
        )

        try await loop.start()
        loop.displayLinkDidFire(at: 1)
        let firstRendered = await recorder.waitForRenderCount(1)
        XCTAssertTrue(firstRendered)
        handlers[0](10, .injectedTestObserver)
        await Task.yield()
        XCTAssertTrue(observations.isEmpty)

        loop.displayLinkDidFire(at: 2)
        let secondRendered = await recorder.waitForRenderCount(2)
        XCTAssertTrue(secondRendered)
        XCTAssertEqual(handlers.count, 2)
        handlers[1](20, .injectedTestObserver)
        for _ in 0..<300 where observations.isEmpty {
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        XCTAssertEqual(observations.count, 1)
        XCTAssertEqual(observations.first?.frameNumber, 2)
        XCTAssertEqual(observations.first?.drawCalls, 1)
        await loop.shutdown()
        _ = window
    }

    @MainActor
    func testZeroSizeTimeoutAndIOSOcclusionReachNativeAsExplicitOutcomes() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is unavailable")
        }
        var presentedDrawableCount = 0
        let zeroRecorder = PresentationSessionRecorder(device: device)
        let (zeroWindow, zeroView) = makePresentationSurface(size: .zero)
        let zeroLoop = makeLoop(
            recorder: zeroRecorder,
            view: zeroView,
            acquireDrawable: { _ in nil },
            onPresentedDrawable: { _ in presentedDrawableCount += 1 }
        )
        try await zeroLoop.start()
        zeroLoop.displayLinkDidFire(at: 1)
        let zeroRendered = await zeroRecorder.waitForOperation(named: "render")
        let zeroStates = await zeroRecorder.drawableStates()
        let zeroDispositions = await zeroRecorder.renderDispositions()
        XCTAssertTrue(zeroRendered)
        XCTAssertEqual(zeroStates, ["timeout"])
        XCTAssertEqual(zeroDispositions, [.skippedZeroSize])
        await zeroLoop.shutdown()

        let timeoutRecorder = PresentationSessionRecorder(device: device)
        let (timeoutWindow, timeoutView) = makePresentationSurface()
        let timeoutLoop = makeLoop(
            recorder: timeoutRecorder,
            view: timeoutView,
            acquireDrawable: { _ in nil },
            onPresentedDrawable: { _ in presentedDrawableCount += 1 }
        )
        try await timeoutLoop.start()
        timeoutLoop.displayLinkDidFire(at: 1)
        let timeoutRendered = await timeoutRecorder.waitForOperation(named: "render")
        let timeoutStates = await timeoutRecorder.drawableStates()
        let timeoutDispositions = await timeoutRecorder.renderDispositions()
        XCTAssertTrue(timeoutRendered)
        XCTAssertEqual(timeoutStates, ["timeout"])
        XCTAssertEqual(timeoutDispositions, [.skippedTimeout])
        await timeoutLoop.shutdown()

        let occludedRecorder = PresentationSessionRecorder(device: device)
        await occludedRecorder.holdNextStep()
        let (occludedWindow, occludedView) = makePresentationSurface()
        let occludedLoop = makeLoop(
            recorder: occludedRecorder,
            view: occludedView,
            onPresentedDrawable: { _ in presentedDrawableCount += 1 }
        )
        try await occludedLoop.start()
        occludedLoop.displayLinkDidFire(at: 1)
        let stepStarted = await occludedRecorder.waitForOperation(named: "step")
        XCTAssertTrue(stepStarted)
        occludedLoop.setPresentationVisible(false)
        await occludedRecorder.releaseStep()
        let detached = await occludedRecorder.waitForOperation(named: "detach")
        let occludedStates = await occludedRecorder.drawableStates()
        let occludedDispositions = await occludedRecorder.renderDispositions()
        XCTAssertTrue(detached)
        XCTAssertEqual(occludedStates, ["occluded"])
        XCTAssertEqual(occludedDispositions, [.skippedOccluded])
        XCTAssertEqual(presentedDrawableCount, 0)
        await occludedLoop.shutdown()
        _ = [zeroWindow, timeoutWindow, occludedWindow]
    }

    @MainActor
    func testBackgroundDetachWaitsForCompletionThenForegroundResetsDeviceDomain() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is unavailable")
        }
        let recorder = PresentationSessionRecorder(device: device)
        await recorder.setCompletionMode(.held)
        let notificationCenter = NotificationCenter()
        let (window, view) = makePresentationSurface()
        let loop = makeLoop(
            recorder: recorder,
            view: view,
            notificationCenter: notificationCenter
        )
        try await loop.start()
        loop.displayLinkDidFire(at: 1)
        let rendered = await recorder.waitForOperation(named: "render")
        XCTAssertTrue(rendered)

        notificationCenter.post(name: UIApplication.willResignActiveNotification, object: nil)
        await Task.yield()
        let namesBeforeCompletion = await recorder.operationNames()
        XCTAssertFalse(namesBeforeCompletion.contains("detach"))

        await recorder.setCompletionMode(.immediate)
        await recorder.releaseFrames()
        let detached = await recorder.waitForOperation(named: "detach")
        XCTAssertTrue(detached)

        notificationCenter.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        let recovered = await recorder.waitForRenderCount(2)
        XCTAssertTrue(recovered)
        let names = await recorder.operationNames()
        XCTAssertTrue(names.containsSequence([
            "detach", "reattach", "reset", "metalDevice", "resize", "step", "render",
        ]))
        XCTAssertTrue(view.metalLayer.device === device)

        await loop.shutdown()
        let finalNames = await recorder.operationNames()
        XCTAssertEqual(Array(finalNames.suffix(2)), ["detach", "close"])
        _ = window
    }

    @MainActor
    func testHiddenSessionFreezesTimeAppliesWorkAtZeroAndResumesWithoutCatchUp() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is unavailable")
        }
        let recorder = PresentationSessionRecorder(device: device)
        let notificationCenter = NotificationCenter()
        let (window, view) = makePresentationSurface()
        let loop = makeLoop(
            recorder: recorder,
            view: view,
            notificationCenter: notificationCenter
        )
        try await loop.start()

        loop.setPresentationVisible(false)
        loop.setTimelineActive(false)
        view.removeFromSuperview()
        let detached = await recorder.waitForOperation(named: "detach")
        XCTAssertTrue(detached)
        let renderCount = await recorder.renderDispositions().count
        let stepCountAtHide = await recorder.steps().count
        notificationCenter.post(
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
        await Task.yield()
        let namesAfterHiddenWarning = await recorder.operationNames()
        XCTAssertFalse(namesAfterHiddenWarning.contains("reattach"))

        loop.displayLinkDidFire(at: 10)
        await Task.yield()
        let hiddenSteps = await recorder.steps()
        XCTAssertEqual(hiddenSteps.count, stepCountAtHide)

        loop.enqueue(ExperienceRuntimePresentationQueuedWork {
            .work(requestsFrame: true)
        })
        let stepped = await recorder.waitForStepCount(stepCountAtHide + 1)
        let finalRenderCount = await recorder.renderDispositions().count
        let names = await recorder.operationNames()
        XCTAssertTrue(stepped)
        let stepsAfterHiddenWork = await recorder.steps()
        XCTAssertEqual(stepsAfterHiddenWork.last?.elapsedSeconds, 0)
        XCTAssertEqual(finalRenderCount, renderCount)
        XCTAssertTrue(names.containsSequence(["detach", "queued", "step"]))

        window.addSubview(view)
        loop.setTimelineActive(true)
        loop.setPresentationVisible(true)
        let renderedAfterReveal = await recorder.waitForRenderCount(renderCount + 1)
        let revealedNames = await recorder.operationNames()
        XCTAssertTrue(renderedAfterReveal)
        XCTAssertTrue(revealedNames.containsSequence([
            "reattach", "reset", "metalDevice", "resize", "step", "render",
        ]))
        let stepsAfterReveal = await recorder.steps()
        XCTAssertEqual(stepsAfterReveal.last?.elapsedSeconds, 0)

        // The reveal's zero-delta frame seeded the clock at wall-clock "now"
        // (production display-link timestamps share that domain). No catch-up:
        // the first real frame's delta measures from the reveal, never from
        // the synthetic pre-hide timeline or the hidden gap.
        let resumeBase = CACurrentMediaTime() + 0.5
        loop.displayLinkDidFire(at: resumeBase)
        let advancedAfterReveal = await recorder.waitForStepCount(stepCountAtHide + 3)
        XCTAssertTrue(advancedAfterReveal)
        let stepsAfterVisibleAdvance = await recorder.steps()
        let firstResumeDelta = try XCTUnwrap(stepsAfterVisibleAdvance.last?.elapsedSeconds)
        XCTAssertGreaterThanOrEqual(firstResumeDelta, 0)
        XCTAssertLessThan(firstResumeDelta, 10, "resume must not replay the hidden gap")

        // Contract: after a resume, authored time flows again and never
        // replays the hidden gap. Under full-suite load the surface can hit
        // drawable-timeout recovery (which legitimately resets the clock to a
        // delta-0 first frame), so keep firing advancing timestamps and
        // accept the first real nonzero delta; every observed delta must stay
        // far below the hidden gap.
        var realDelta: Float?
        var fireAt = resumeBase + 1
        for _ in 0..<250 {
            loop.displayLinkDidFire(at: fireAt)
            fireAt += 1
            if let last = await recorder.steps().last?.elapsedSeconds, last > 0 {
                realDelta = last
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let resumedDelta = try XCTUnwrap(realDelta, "time must flow again after resume")
        XCTAssertGreaterThan(resumedDelta, 0)
        XCTAssertLessThan(resumedDelta, 5, "resume must never replay the hidden gap")
        let allDeltas = await recorder.steps().map(\.elapsedSeconds)
        XCTAssertNil(
            allDeltas.first(where: { $0 >= 5 }),
            "no step may carry a catch-up jump: \(allDeltas)"
        )

        await loop.shutdown()
        _ = window
    }

    @MainActor
    func testOwningSceneNotificationsPauseAndResumeWithoutApplicationTransition() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is unavailable")
        }
        let recorder = PresentationSessionRecorder(device: device)
        let notificationCenter = NotificationCenter()
        let (window, view) = makePresentationSurface()
        let loop = makeLoop(
            recorder: recorder,
            view: view,
            notificationCenter: notificationCenter
        )
        try await loop.start()

        notificationCenter.post(
            name: UIScene.willDeactivateNotification,
            object: NSObject()
        )
        await Task.yield()
        let namesAfterForeignNotification = await recorder.operationNames()
        XCTAssertFalse(namesAfterForeignNotification.contains("detach"))

        notificationCenter.post(
            name: UIScene.willDeactivateNotification,
            object: window.windowScene
        )
        let detached = await recorder.waitForOperation(named: "detach")
        XCTAssertTrue(detached)

        notificationCenter.post(
            name: UIScene.didActivateNotification,
            object: window.windowScene
        )
        let rendered = await recorder.waitForRenderCount(1)
        let names = await recorder.operationNames()
        XCTAssertTrue(rendered)
        XCTAssertTrue(names.containsSequence([
            "detach", "reattach", "reset", "metalDevice", "resize", "step", "render",
        ]))

        await loop.shutdown()
        _ = window
    }

    @MainActor
    func testMemoryWarningWaitsForNativeCompletionThenCyclesVisibleRenderer() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is unavailable")
        }
        let recorder = PresentationSessionRecorder(device: device)
        await recorder.setCompletionMode(.held)
        let notificationCenter = NotificationCenter()
        let (window, view) = makePresentationSurface()
        let loop = makeLoop(
            recorder: recorder,
            view: view,
            notificationCenter: notificationCenter
        )
        try await loop.start()
        loop.displayLinkDidFire(at: 1)
        let rendered = await recorder.waitForOperation(named: "render")
        XCTAssertTrue(rendered)

        notificationCenter.post(
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
        await Task.yield()
        let namesBeforeCompletion = await recorder.operationNames()
        XCTAssertFalse(namesBeforeCompletion.contains("detach"))

        await recorder.setCompletionMode(.immediate)
        await recorder.releaseFrames()
        let renderedTwice = await recorder.waitForRenderCount(2)
        let names = await recorder.operationNames()
        let recoveryStep = await recorder.steps().last
        XCTAssertTrue(renderedTwice)
        XCTAssertTrue(names.containsSequence([
            "render", "detach", "reattach", "reset", "metalDevice", "resize", "step", "render",
        ]))
        XCTAssertEqual(recoveryStep?.elapsedSeconds, 0)

        await loop.shutdown()
        _ = window
    }

    @MainActor
    func testShutdownDrainsFrameAndClosesExactlyOnceDespiteDuplicateCompletion() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is unavailable")
        }
        let recorder = PresentationSessionRecorder(device: device)
        await recorder.setCompletionMode(.held)
        let (window, view) = makePresentationSurface()
        let loop = makeLoop(recorder: recorder, view: view)
        try await loop.start()
        loop.displayLinkDidFire(at: 1)
        let rendered = await recorder.waitForOperation(named: "render")
        XCTAssertTrue(rendered)

        let shutdown = Task { @MainActor in await loop.shutdown() }
        await Task.yield()
        let namesWhileFrameIsLive = await recorder.operationNames()
        XCTAssertFalse(namesWhileFrameIsLive.contains("detach"))
        XCTAssertFalse(namesWhileFrameIsLive.contains("close"))

        await recorder.releaseFrames()
        await shutdown.value
        let finalNames = await recorder.operationNames()
        XCTAssertEqual(finalNames.filter { $0 == "detach" }.count, 1)
        XCTAssertEqual(finalNames.filter { $0 == "close" }.count, 1)
        _ = window
    }

    @MainActor
    func testCoalescesResizeAndRunsQueuedProductWorkFIFO() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is unavailable")
        }
        let recorder = PresentationSessionRecorder(device: device)
        await recorder.holdNextStep()
        let (window, view) = makePresentationSurface()
        let loop = makeLoop(recorder: recorder, view: view)
        try await loop.start()
        loop.displayLinkDidFire(at: 1)
        let stepStarted = await recorder.waitForOperation(named: "step")
        XCTAssertTrue(stepStarted)

        view.bounds.size = CGSize(width: 200, height: 100)
        loop.runtimeSurfaceViewGeometryDidChange()
        view.bounds.size = CGSize(width: 300, height: 150)
        loop.runtimeSurfaceViewGeometryDidChange()
        await recorder.releaseStep()
        let resized = await recorder.waitForResizeCount(2)
        XCTAssertTrue(resized)
        let sizes = await recorder.resizeSizes()
        let expectedSize = ExperienceRuntimeSurfaceSizing.pixels(
            width: 300,
            height: 150,
            scale: window.screen.scale
        )
        XCTAssertEqual(sizes.count, 2)
        XCTAssertEqual(sizes.last, expectedSize)

        var delivery: [String] = []
        let operationCountBeforeWork = await recorder.operationNames().count
        loop.enqueue(ExperienceRuntimePresentationQueuedWork {
            .work(requestsFrame: false) { delivery.append("effect-1") }
        }) { result in
            if case .success = result { delivery.append("completion-1") }
        }
        loop.enqueue(ExperienceRuntimePresentationQueuedWork {
            .work(requestsFrame: false) { delivery.append("effect-2") }
        }) { result in
            if case .success = result { delivery.append("completion-2") }
        }
        let workFinished = await recorder.waitForOperationCount(operationCountBeforeWork + 2)
        XCTAssertTrue(workFinished)
        XCTAssertEqual(delivery, ["effect-1", "completion-1", "effect-2", "completion-2"])

        await loop.shutdown()
        _ = window
    }

    @MainActor
    func testShutdownCancelsOnlyQueuedWorkAndLetsAcceptedWorkDeliverBeforeClose() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is unavailable")
        }
        let recorder = PresentationSessionRecorder(device: device)
        await recorder.holdNextQueuedWork()
        let (window, view) = makePresentationSurface()
        let loop = makeLoop(recorder: recorder, view: view)
        try await loop.start()

        var delivery: [String] = []
        loop.enqueue(ExperienceRuntimePresentationQueuedWork {
            .work(requestsFrame: false) { delivery.append("accepted-effect") }
        }) { result in
            delivery.append(result.isSuccess ? "accepted-success" : "accepted-failure")
        }
        let accepted = await recorder.waitForOperation(named: "queued")
        XCTAssertTrue(accepted)
        loop.enqueue(ExperienceRuntimePresentationQueuedWork {
            .work(requestsFrame: false) { delivery.append("pending-effect") }
        }) { result in
            delivery.append(result.isSuccess ? "pending-success" : "pending-failure")
        }

        let shutdown = Task { @MainActor in await loop.shutdown() }
        await Task.yield()
        XCTAssertEqual(delivery, ["pending-failure"])

        await recorder.releaseQueuedWork()
        await shutdown.value
        XCTAssertEqual(
            delivery,
            ["pending-failure", "accepted-effect", "accepted-success"]
        )
        let names = await recorder.operationNames()
        XCTAssertEqual(Array(names.suffix(2)), ["detach", "close"])
        _ = window
    }

    @MainActor
    func testTerminalRenderOutcomeKeepsFrameLiveUntilNativeCompletion() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is unavailable")
        }
        let recorder = PresentationSessionRecorder(device: device)
        await recorder.setCompletionMode(.held)
        await recorder.enqueueRenderHealth([.outOfMemory])
        let (window, view) = makePresentationSurface()
        var errors: [ExperienceRuntimePresentationLoopError] = []
        var presentedDrawableCount = 0
        let loop = makeLoop(
            recorder: recorder,
            view: view,
            onPresentedDrawable: { _ in presentedDrawableCount += 1 },
            observeDrawablePresentation: { _, handler in
                handler(42, .injectedTestObserver)
            },
            nativeCompletionPresentationFallback: nil,
            onError: {
                if let error = $0 as? ExperienceRuntimePresentationLoopError {
                    errors.append(error)
                }
            }
        )
        try await loop.start()
        loop.displayLinkDidFire(at: 1)
        let rendered = await recorder.waitForOperation(named: "render")
        XCTAssertTrue(rendered)
        await Task.yield()
        XCTAssertEqual(errors, [.rendererFailed(.outOfMemory)])
        XCTAssertEqual(presentedDrawableCount, 0)

        let shutdown = Task { @MainActor in await loop.shutdown() }
        await Task.yield()
        let namesWhileFrameIsLive = await recorder.operationNames()
        XCTAssertFalse(namesWhileFrameIsLive.contains("detach"))
        XCTAssertFalse(namesWhileFrameIsLive.contains("close"))

        await recorder.releaseFrames()
        await shutdown.value
        let finalNames = await recorder.operationNames()
        XCTAssertEqual(Array(finalNames.suffix(2)), ["detach", "close"])
        _ = window
    }

    @MainActor
    func testDeviceLossGetsOneRecoveryAndARepeatedLossIsTerminal() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is unavailable")
        }
        let recorder = PresentationSessionRecorder(device: device)
        await recorder.enqueueRenderHealth([.deviceLost, .deviceLost])
        let (window, view) = makePresentationSurface()
        var errors: [ExperienceRuntimePresentationLoopError] = []
        let loop = makeLoop(recorder: recorder, view: view, onError: {
            if let error = $0 as? ExperienceRuntimePresentationLoopError { errors.append(error) }
        })
        try await loop.start()
        loop.displayLinkDidFire(at: 1)

        let renderedTwice = await recorder.waitForRenderCount(2)
        let recoveryNames = await recorder.operationNames()
        XCTAssertTrue(renderedTwice)
        XCTAssertTrue(recoveryNames.containsSequence([
            "render", "detach", "reattach", "reset", "metalDevice", "resize", "step", "render",
        ]))
        XCTAssertEqual(errors, [.repeatedDeviceLoss])

        await loop.shutdown()
        _ = window
    }

    @MainActor
    func testPointerProjectionUsesTheSwiftOwnedContainTransform() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is unavailable")
        }
        let recorder = PresentationSessionRecorder(device: device)
        let (window, view) = makePresentationSurface(size: CGSize(width: 200, height: 100))
        let session = ExperienceRuntimePresentationSession(
            artboardBounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            perform: { try await recorder.perform($0) }
        )
        var acceptedInputs: [ExperienceRuntimeAcceptedPointerInput] = []
        await recorder.holdNextDelivery()
        let loop = ExperienceRuntimePresentationLoop(
            session: session,
            surfaceView: view,
            usesSystemDisplayLink: false,
            onAcceptedPointerInput: { acceptedInputs.append($0) }
        )
        try await loop.start()
        let source = NSObject()
        loop.runtimeSurfaceViewDidReceivePointerEvents([
            ExperienceRuntimeViewPointerEvent(
                source: ExperienceRuntimePointerSourceID(source),
                kind: .down,
                location: CGPoint(x: 50, y: 0),
                timestampSeconds: 7
            ),
        ])
        let stepped = await recorder.waitForOperation(named: "step")
        XCTAssertTrue(stepped)
        XCTAssertEqual(acceptedInputs, [])
        await recorder.releaseDelivery()
        for _ in 0..<300 where acceptedInputs.isEmpty {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let pointer = await recorder.steps().last?.pointers.first
        XCTAssertEqual(pointer?.x, 0)
        XCTAssertEqual(pointer?.y, 0)
        XCTAssertEqual(pointer?.pointerID, 1)
        XCTAssertEqual(pointer?.timestamp, 7)
        XCTAssertEqual(
            acceptedInputs,
            [ExperienceRuntimeAcceptedPointerInput(eventCount: 1)]
        )
        await loop.shutdown()
        _ = window
    }

    @MainActor
    func testPointerBackpressureCoalescesMovesAndPreservesExit() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is unavailable")
        }
        let recorder = PresentationSessionRecorder(device: device)
        await recorder.holdNextQueuedWork()
        let (window, view) = makePresentationSurface()
        let loop = makeLoop(recorder: recorder, view: view)
        try await loop.start()
        loop.enqueue(ExperienceRuntimePresentationQueuedWork {
            .work(requestsFrame: false)
        })
        let queued = await recorder.waitForOperation(named: "queued")
        XCTAssertTrue(queued)

        let source = NSObject()
        loop.runtimeSurfaceViewDidReceivePointerEvents([
            ExperienceRuntimeViewPointerEvent(
                source: ExperienceRuntimePointerSourceID(source),
                kind: .down,
                location: CGPoint(x: 1, y: 1)
            ),
        ])
        for coordinate in 2...5_000 {
            loop.runtimeSurfaceViewDidReceivePointerEvents([
                ExperienceRuntimeViewPointerEvent(
                    source: ExperienceRuntimePointerSourceID(source),
                    kind: .move,
                    location: CGPoint(x: coordinate, y: coordinate)
                ),
            ])
        }
        loop.runtimeSurfaceViewDidReceivePointerEvents([
            ExperienceRuntimeViewPointerEvent(
                source: ExperienceRuntimePointerSourceID(source),
                kind: .exit,
                location: CGPoint(x: 5_000, y: 5_000)
            ),
        ])

        await recorder.releaseQueuedWork()
        let stepped = await recorder.waitForStepCount(1)
        let steps = await recorder.steps()
        XCTAssertTrue(stepped)
        let pointers = try XCTUnwrap(steps.first?.pointers)
        XCTAssertEqual(pointers.count, 3)
        XCTAssertEqual(pointers.map(\.kind), [.down, .move, .exit])
        XCTAssertEqual(pointers[1].x, 5_000)
        XCTAssertEqual(pointers[1].y, 5_000)

        await loop.shutdown()
        _ = window
    }
}

private actor AsyncBooleanProbe {
    private var isTrue = false

    func setTrue() {
        isTrue = true
    }

    func value() -> Bool {
        isTrue
    }
}

private actor PresentationSessionRecorder {
    enum CompletionMode { case immediate, held }

    private let device: any MTLDevice
    private var names: [String] = []
    private var sizes: [ExperienceRuntimeSurfaceSize] = []
    private var recordedSteps: [ExperienceRuntimePresentationStep] = []
    private var states: [String] = []
    private var dispositions: [ExperienceRuntimePresentationRenderOutcome.Disposition] = []
    private var completionCount = 0
    private var completionMode: CompletionMode = .immediate
    private var heldCompletions: [ExperienceRuntimePresentationFrameCompletion] = []
    private var shouldHoldStep = false
    private var stepContinuation: CheckedContinuation<Void, Never>?
    private var shouldHoldDelivery = false
    private var deliveryContinuation: CheckedContinuation<Void, Never>?
    private var shouldHoldQueuedWork = false
    private var queuedWorkContinuation: CheckedContinuation<Void, Never>?
    private var renderHealth: [ExperienceRuntimePresentationRenderOutcome.Health] = []
    private var presentedDrawCalls: [UInt64] = []
    private var currentSize = ExperienceRuntimeSurfaceSize(pixelWidth: 0, pixelHeight: 0)

    init(device: any MTLDevice) {
        self.device = device
    }

    func perform(_ operation: ExperienceRuntimePresentationSessionOperation) async throws
        -> ExperienceRuntimePresentationSessionResult
    {
        switch operation {
        case .copyMetalDevice:
            names.append("metalDevice")
            return .metalDevice(device)
        case .resize(let size):
            names.append("resize")
            sizes.append(size)
            currentSize = size
            return .renderer(outcome(disposition: size.pixelWidth == 0 || size.pixelHeight == 0
                ? .skippedZeroSize
                : .reconfigured))
        case .step(let step):
            names.append("step")
            recordedSteps.append(step)
            if shouldHoldStep {
                shouldHoldStep = false
                await withCheckedContinuation { stepContinuation = $0 }
            }
            return .session { await self.waitForDeliveryIfNeeded() }
        case .render(let state, let completion):
            names.append("render")
            let disposition: ExperienceRuntimePresentationRenderOutcome.Disposition
            switch state {
            case .available:
                states.append("available")
                disposition = .presented
            case .timeout:
                states.append("timeout")
                disposition = currentSize.pixelWidth == 0 || currentSize.pixelHeight == 0
                    ? .skippedZeroSize
                    : .skippedTimeout
            case .occluded:
                states.append("occluded")
                disposition = .skippedOccluded
            }
            dispositions.append(disposition)
            switch completionMode {
            case .immediate:
                completion.signalFromNative()
                completion.signalFromNative()
                completionCount += 1
            case .held:
                heldCompletions.append(completion)
            }
            let health = renderHealth.isEmpty ? .healthy : renderHealth.removeFirst()
            return .renderer(outcome(disposition: disposition, health: health))
        case .queued(let work):
            names.append("queued")
            if shouldHoldQueuedWork {
                shouldHoldQueuedWork = false
                await withCheckedContinuation { queuedWorkContinuation = $0 }
            }
            return try await work.perform()
        case .detach:
            names.append("detach")
            return .renderer(.detached)
        case .reattach(let size):
            names.append("reattach")
            currentSize = size
            return .renderer(.recreated(size))
        case .resetPlayerRendererDomain:
            names.append("reset")
            return .none
        case .close:
            names.append("close")
            return .none
        }
    }

    func holdNextStep() { shouldHoldStep = true }
    func releaseStep() { stepContinuation?.resume(); stepContinuation = nil }
    func holdNextDelivery() { shouldHoldDelivery = true }
    func releaseDelivery() {
        deliveryContinuation?.resume()
        deliveryContinuation = nil
    }
    func holdNextQueuedWork() { shouldHoldQueuedWork = true }
    func releaseQueuedWork() {
        queuedWorkContinuation?.resume()
        queuedWorkContinuation = nil
    }
    func setCompletionMode(_ mode: CompletionMode) { completionMode = mode }
    func enqueueRenderHealth(_ values: [ExperienceRuntimePresentationRenderOutcome.Health]) {
        renderHealth.append(contentsOf: values)
    }

    func enqueuePresentedDrawCalls(_ values: [UInt64]) {
        presentedDrawCalls.append(contentsOf: values)
    }

    func releaseFrames() {
        let completions = heldCompletions
        heldCompletions.removeAll()
        completions.forEach {
            $0.signalFromNative()
            $0.signalFromNative()
            completionCount += 1
        }
    }

    func operationNames() -> [String] { names }
    func resizeSizes() -> [ExperienceRuntimeSurfaceSize] { sizes }
    func steps() -> [ExperienceRuntimePresentationStep] { recordedSteps }
    func drawableStates() -> [String] { states }
    func renderDispositions() -> [ExperienceRuntimePresentationRenderOutcome.Disposition] {
        dispositions
    }
    func nativeCompletionCount() -> Int { completionCount }

    private func waitForDeliveryIfNeeded() async {
        guard shouldHoldDelivery else { return }
        shouldHoldDelivery = false
        await withCheckedContinuation { deliveryContinuation = $0 }
    }

    func waitForOperation(named name: String) async -> Bool {
        await waitUntil { self.names.contains(name) }
    }

    func waitForOperationCount(_ count: Int) async -> Bool {
        await waitUntil { self.names.count >= count }
    }

    func waitForResizeCount(_ count: Int) async -> Bool {
        await waitUntil { self.sizes.count >= count }
    }

    func waitForRenderCount(_ count: Int) async -> Bool {
        await waitUntil { self.states.count >= count }
    }

    func waitForStepCount(_ count: Int) async -> Bool {
        await waitUntil { self.recordedSteps.count >= count }
    }

    private func waitUntil(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<300 {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return false
    }

    private func outcome(
        disposition: ExperienceRuntimePresentationRenderOutcome.Disposition,
        health: ExperienceRuntimePresentationRenderOutcome.Health = .healthy
    ) -> ExperienceRuntimePresentationRenderOutcome {
        let drawCalls = if disposition == .presented {
            presentedDrawCalls.isEmpty ? 1 : presentedDrawCalls.removeFirst()
        } else {
            UInt64(0)
        }
        return ExperienceRuntimePresentationRenderOutcome(
            disposition: disposition,
            health: health,
            pixelWidth: currentSize.pixelWidth,
            pixelHeight: currentSize.pixelHeight,
            drawCalls: drawCalls
        )
    }
}

@MainActor
private func makeLoop(
    recorder: PresentationSessionRecorder,
    view: ExperienceRuntimeSurfaceView,
    notificationCenter: NotificationCenter = .default,
    acquireDrawable: @escaping @MainActor (CAMetalLayer) -> (any CAMetalDrawable)? = {
        $0.nextDrawable()
    },
    onSessionResult: @escaping @MainActor () -> Void = {},
    onPresentedDrawable: @escaping @MainActor (ExperienceRuntimePresentedDrawable) -> Void = { _ in },
    onAcceptedPointerInput: @escaping @MainActor (
        ExperienceRuntimeAcceptedPointerInput
    ) -> Void = { _ in },
    observeDrawablePresentation: @escaping @MainActor (
        any CAMetalDrawable,
        @escaping @Sendable (
            TimeInterval,
            ExperienceRuntimePresentedDrawable.Provenance
        ) -> Void
    ) -> Void = { _, _ in },
    nativeCompletionPresentationFallback:
        ExperienceRuntimePresentedDrawable.Provenance? = .runtimeCompletionProxy,
    onError: @escaping @MainActor (Error) -> Void = { _ in }
) -> ExperienceRuntimePresentationLoop {
    ExperienceRuntimePresentationLoop(
        session: ExperienceRuntimePresentationSession(
            artboardBounds: CGRect(x: 0, y: 0, width: 128, height: 64),
            perform: { try await recorder.perform($0) }
        ),
        surfaceView: view,
        notificationCenter: notificationCenter,
        usesSystemDisplayLink: false,
        acquireDrawable: acquireDrawable,
        onSessionResult: onSessionResult,
        onPresentedDrawable: onPresentedDrawable,
        onAcceptedPointerInput: onAcceptedPointerInput,
        observeDrawablePresentation: observeDrawablePresentation,
        nativeCompletionPresentationFallback: nativeCompletionPresentationFallback,
        onError: onError
    )
}

@MainActor
private func makePresentationSurface(
    size: CGSize = CGSize(width: 128, height: 64)
) -> (UIWindow, ExperienceRuntimeSurfaceView) {
    let window = UIWindow(frame: CGRect(origin: .zero, size: size))
    let view = ExperienceRuntimeSurfaceView(frame: window.bounds)
    window.addSubview(view)
    window.isHidden = false
    view.layoutIfNeeded()
    return (window, view)
}

private extension Array where Element: Equatable {
    func containsSequence(_ sequence: [Element]) -> Bool {
        guard !sequence.isEmpty, sequence.count <= count else { return false }
        return indices.contains { start in
            let end = start + sequence.count
            return end <= count && Array(self[start..<end]) == sequence
        }
    }
}

private extension Result where Success == Void, Failure == Error {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
#endif
