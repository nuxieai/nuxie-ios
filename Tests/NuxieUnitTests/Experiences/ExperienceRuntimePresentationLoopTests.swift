#if canImport(UIKit) && canImport(QuartzCore)
import Metal
import NuxieRuntimeSupport
import QuartzCore
import XCTest
@testable import Nuxie

final class ExperienceRuntimePresentationLoopTests: XCTestCase {
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
    func testZeroSizeTimeoutAndIOSOcclusionReachNativeAsExplicitOutcomes() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is unavailable")
        }
        let zeroRecorder = PresentationSessionRecorder(device: device)
        let (zeroWindow, zeroView) = makePresentationSurface(size: .zero)
        let zeroLoop = makeLoop(recorder: zeroRecorder, view: zeroView, acquireDrawable: { _ in nil })
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
            acquireDrawable: { _ in nil }
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
        let occludedLoop = makeLoop(recorder: occludedRecorder, view: occludedView)
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
        XCTAssertEqual(sizes.count, 2)
        XCTAssertEqual(sizes.last?.pixelWidth, UInt32(900))
        XCTAssertEqual(sizes.last?.pixelHeight, UInt32(450))

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
        let loop = ExperienceRuntimePresentationLoop(
            session: session,
            surfaceView: view,
            usesSystemDisplayLink: false
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
        let pointer = await recorder.steps().last?.pointers.first
        XCTAssertEqual(pointer?.x, 0)
        XCTAssertEqual(pointer?.y, 0)
        XCTAssertEqual(pointer?.pointerID, 1)
        XCTAssertEqual(pointer?.timestamp, 7)
        await loop.shutdown()
        _ = window
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
    private var renderHealth: [ExperienceRuntimePresentationRenderOutcome.Health] = []
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
            return .session(keepsAnimating: false)
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
    func setCompletionMode(_ mode: CompletionMode) { completionMode = mode }
    func enqueueRenderHealth(_ values: [ExperienceRuntimePresentationRenderOutcome.Health]) {
        renderHealth.append(contentsOf: values)
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
        ExperienceRuntimePresentationRenderOutcome(
            disposition: disposition,
            health: health,
            pixelWidth: currentSize.pixelWidth,
            pixelHeight: currentSize.pixelHeight,
            drawCalls: disposition == .presented ? 1 : 0
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
#endif
