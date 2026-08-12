#if canImport(UIKit) && canImport(QuartzCore)
import Foundation
import Metal
import QuartzCore
import UIKit

private enum ExperienceRuntimePresentationLimits {
    static let pendingWork = 64
    static let maximumDrawableCount = 3
}

private final class ExperienceRuntimeOneShotGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }

    var isClaimed: Bool {
        lock.withLock { claimed }
    }
}

struct ExperienceRuntimePresentationRenderOutcome: Equatable, Sendable {
    enum Disposition: Equatable, Sendable {
        case none, presented, skippedZeroSize, skippedTimeout, skippedOccluded
        case reconfigured, recreated, deviceLost, outOfMemory
    }

    enum Health: Equatable, Sendable {
        case healthy, deviceLost, outOfMemory, failed
    }

    let disposition: Disposition
    let health: Health
    let pixelWidth: UInt32
    let pixelHeight: UInt32
    let drawCalls: UInt64

    static let detached = Self(
        disposition: .none,
        health: .healthy,
        pixelWidth: 0,
        pixelHeight: 0,
        drawCalls: 0
    )

    static func recreated(_ size: ExperienceRuntimeSurfaceSize) -> Self {
        Self(
            disposition: .recreated,
            health: .healthy,
            pixelWidth: size.pixelWidth,
            pixelHeight: size.pixelHeight,
            drawCalls: 0
        )
    }
}

struct ExperienceRuntimePresentationStep: Equatable, Sendable {
    let elapsedSeconds: Float
    let pointers: [ExperienceInteractivePointerEvent]
    let requestsRender: Bool

    init(
        elapsedSeconds: Float,
        pointers: [ExperienceInteractivePointerEvent],
        requestsRender: Bool = true
    ) {
        self.elapsedSeconds = elapsedSeconds
        self.pointers = pointers
        self.requestsRender = requestsRender
    }
}

/// Bounded input staging between UIKit callbacks and one native player step.
/// Active pointers reserve room for their terminal event, while superseded
/// moves coalesce without displacing down/exit ordering.
private struct ExperienceRuntimePresentationPointerQueue {
    private static let maximumEventCount = ExperienceRuntimePointerInputRouter.maximumActivePointers * 2

    private var events: [ExperienceInteractivePointerEvent] = []
    private var activePointerIDs: Set<Int32> = []

    var isEmpty: Bool { events.isEmpty }

    mutating func enqueue(_ incoming: [ExperienceInteractivePointerEvent]) {
        for event in incoming {
            switch event.kind {
            case .move:
                if activePointerIDs.contains(event.pointerID) {
                    removeSupersededMove(for: event.pointerID)
                    guard hasCapacity(forAdditionalEvents: 1) else { continue }
                } else {
                    guard reserveNewPointer(event.pointerID) else { continue }
                }
            case .down:
                if activePointerIDs.contains(event.pointerID) {
                    guard hasCapacity(forAdditionalEvents: 1) else { continue }
                } else {
                    guard reserveNewPointer(event.pointerID) else { continue }
                }
            case .up, .exit:
                if activePointerIDs.remove(event.pointerID) == nil,
                   !hasCapacity(forAdditionalEvents: 1) {
                    continue
                }
            }
            events.append(event)
        }
    }

    mutating func takeBatch() -> [ExperienceInteractivePointerEvent] {
        let count = min(events.count, ExperienceRuntimePointerInputRouter.maximumActivePointers)
        let batch = Array(events.prefix(count))
        events.removeFirst(count)
        return batch
    }

    mutating func removeAll() {
        events.removeAll(keepingCapacity: false)
        activePointerIDs.removeAll(keepingCapacity: false)
    }

    private mutating func reserveNewPointer(_ pointerID: Int32) -> Bool {
        guard hasCapacity(forAdditionalEvents: 2) else { return false }
        activePointerIDs.insert(pointerID)
        return true
    }

    private func hasCapacity(forAdditionalEvents count: Int) -> Bool {
        events.count + activePointerIDs.count + count <= Self.maximumEventCount
    }

    private mutating func removeSupersededMove(for pointerID: Int32) {
        for index in events.indices.reversed() where events[index].pointerID == pointerID {
            guard events[index].kind == .move else { return }
            events.remove(at: index)
            return
        }
    }
}

struct ExperienceRuntimePresentationDrawable: @unchecked Sendable {
    let value: any CAMetalDrawable
}

enum ExperienceRuntimePresentationDrawableState: @unchecked Sendable {
    case available(ExperienceRuntimePresentationDrawable)
    case timeout
    case occluded
}

/// Owns one native completion token. Native consumes a valid callback pair
/// exactly once and never invokes it inline. The gate also makes an erroneous
/// duplicate or late callback harmless on the Swift side.
final class ExperienceRuntimePresentationFrameCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable () -> Void)?
    private var presentedDrawableCallback: (@Sendable (ExperienceRuntimePresentedDrawable) -> Void)?
    private var renderOutcome: ExperienceRuntimePresentationRenderOutcome?
    private var presentationObservation: (
        time: TimeInterval,
        provenance: ExperienceRuntimePresentedDrawable.Provenance
    )?
    private let nativeCompletionFallback: ExperienceRuntimePresentedDrawable.Provenance?
    private let frameNumber: UInt64

    init(
        _ callback: @escaping @Sendable () -> Void,
        frameNumber: UInt64 = 0,
        onPresentedDrawable: (@Sendable (ExperienceRuntimePresentedDrawable) -> Void)? = nil,
        nativeCompletionFallback: ExperienceRuntimePresentedDrawable.Provenance? = nil
    ) {
        self.callback = callback
        self.frameNumber = frameNumber
        presentedDrawableCallback = onPresentedDrawable
        self.nativeCompletionFallback = nativeCompletionFallback
    }

    func signalFromNative() {
        let (callback, delivery) = lock.withLock {
            defer { self.callback = nil }
            if presentationObservation == nil, let nativeCompletionFallback {
                presentationObservation = (CACurrentMediaTime(), nativeCompletionFallback)
            }
            return (self.callback, takePresentedDrawableIfReady())
        }
        callback?()
        deliverPresentedDrawable(delivery)
    }

    func recordRenderOutcome(_ outcome: ExperienceRuntimePresentationRenderOutcome) {
        deliverPresentedDrawable(lock.withLock {
            renderOutcome = outcome
            return takePresentedDrawableIfReady()
        })
    }

    func signalDrawablePresented(
        at time: TimeInterval,
        provenance: ExperienceRuntimePresentedDrawable.Provenance
    ) {
        deliverPresentedDrawable(lock.withLock {
            presentationObservation = (time, provenance)
            return takePresentedDrawableIfReady()
        })
    }

    private func takePresentedDrawableIfReady() -> (
        (@Sendable (ExperienceRuntimePresentedDrawable) -> Void),
        ExperienceRuntimePresentedDrawable
    )? {
        guard let outcome = renderOutcome else { return nil }
        guard outcome.health == .healthy,
              outcome.disposition == .presented else {
            presentedDrawableCallback = nil
            return nil
        }
        guard let presentationObservation,
              let callback = presentedDrawableCallback else { return nil }
        presentedDrawableCallback = nil
        return (
            callback,
            ExperienceRuntimePresentedDrawable(
                presentedTime: presentationObservation.time,
                frameNumber: frameNumber,
                pixelWidth: outcome.pixelWidth,
                pixelHeight: outcome.pixelHeight,
                drawCalls: outcome.drawCalls,
                provenance: presentationObservation.provenance
            )
        )
    }

    private func deliverPresentedDrawable(_ delivery: (
        (@Sendable (ExperienceRuntimePresentedDrawable) -> Void),
        ExperienceRuntimePresentedDrawable
    )?) {
        guard let (callback, drawable) = delivery else { return }
        callback(drawable)
    }
}

/// Product-owned work can join the presentation FIFO without teaching this
/// policy module about state, text, routing, authentication, or sessions.
struct ExperienceRuntimePresentationQueuedWork: Sendable {
    typealias Perform = @Sendable () async throws
        -> ExperienceRuntimePresentationSessionResult

    let perform: Perform

    init(perform: @escaping Perform) {
        self.perform = perform
    }
}

enum ExperienceRuntimePresentationSessionOperation: @unchecked Sendable {
    case copyMetalDevice
    case step(ExperienceRuntimePresentationStep)
    case resize(ExperienceRuntimeSurfaceSize)
    /// The session accepts ownership of `completion` and must consume it on
    /// every success or failure path. Presentation never guesses whether a
    /// render reached native code and therefore never synthesizes completion.
    case render(
        ExperienceRuntimePresentationDrawableState,
        completion: ExperienceRuntimePresentationFrameCompletion
    )
    case queued(ExperienceRuntimePresentationQueuedWork)
    case detach
    case reattach(ExperienceRuntimeSurfaceSize)
    case resetPlayerRendererDomain
    case close
}

struct ExperienceRuntimePresentationSessionResult: @unchecked Sendable {
    enum Value: @unchecked Sendable {
        case none
        case metalDevice(any MTLDevice)
        case session
        case work(requestsFrame: Bool)
        case renderer(ExperienceRuntimePresentationRenderOutcome)
    }

    let value: Value
    private let deliverOnMainActor: (@MainActor @Sendable () async -> Void)?

    private init(
        _ value: Value,
        deliverOnMainActor: (@MainActor @Sendable () async -> Void)? = nil
    ) {
        self.value = value
        self.deliverOnMainActor = deliverOnMainActor
    }

    static let none = Self(.none)

    static func metalDevice(_ device: any MTLDevice) -> Self {
        Self(.metalDevice(device))
    }

    static func session(
        deliverOnMainActor: (@MainActor @Sendable () async -> Void)? = nil
    ) -> Self {
        Self(.session, deliverOnMainActor: deliverOnMainActor)
    }

    static func work(
        requestsFrame: Bool,
        deliverOnMainActor: (@MainActor @Sendable () async -> Void)? = nil
    ) -> Self {
        Self(.work(requestsFrame: requestsFrame), deliverOnMainActor: deliverOnMainActor)
    }

    static func renderer(_ outcome: ExperienceRuntimePresentationRenderOutcome) -> Self {
        Self(.renderer(outcome))
    }

    @MainActor
    func deliver() async {
        await deliverOnMainActor?()
    }
}

/// One type-erased actor boundary. Its implementation serializes all native
/// calls on the runtime's pinned OS thread. UIKit values are synchronously
/// borrowed only by the matching render operation.
struct ExperienceRuntimePresentationSession: Sendable {
    typealias Perform = @Sendable (
        ExperienceRuntimePresentationSessionOperation
    ) async throws -> ExperienceRuntimePresentationSessionResult

    let artboardBounds: CGRect
    private let performOperation: Perform

    init(
        artboardBounds: CGRect = .zero,
        perform: @escaping Perform
    ) {
        self.artboardBounds = artboardBounds
        performOperation = perform
    }

    func perform(_ operation: ExperienceRuntimePresentationSessionOperation) async throws
        -> ExperienceRuntimePresentationSessionResult
    {
        try await performOperation(operation)
    }
}

extension ExperienceInteractiveScreen {
    /// Adapts the product-owned screen actor to the presentation policy
    /// without moving authentication, command interpretation, or effect
    /// routing into that policy. Effects cross MainActor only after the native
    /// step and product projection both succeed.
    nonisolated func presentationSession(
        includesSnapshotAfterStep: Bool = false,
        onStep: @escaping @MainActor @Sendable (
            [ExperienceInteractiveEffect],
            ExperienceInteractiveViewModelSnapshot?
        ) async -> Void
    ) -> ExperienceRuntimePresentationSession {
        let screen = self
        return ExperienceRuntimePresentationSession(artboardBounds: artboardBounds) { operation in
            switch operation {
            case .copyMetalDevice:
                return .metalDevice(try await screen.metalDevice().value)
            case .step(let step):
                let result = try await screen.step(
                    pointers: step.pointers,
                    elapsedSeconds: step.elapsedSeconds
                )
                let snapshot: ExperienceInteractiveViewModelSnapshot?
                if includesSnapshotAfterStep {
                    snapshot = try? await screen.snapshot()
                } else {
                    snapshot = nil
                }
                return .session {
                    await onStep(result.effects, snapshot)
                }
            case .resize(let size):
                return .renderer(Self.presentationOutcome(try await screen.resize(
                    pixelWidth: size.pixelWidth,
                    pixelHeight: size.pixelHeight
                )))
            case .render(let drawableState, let completion):
                let drawable: ExperienceInteractiveDrawable?
                let isOccluded: Bool
                switch drawableState {
                case .available(let value):
                    drawable = ExperienceInteractiveDrawable(value.value)
                    isOccluded = false
                case .timeout:
                    drawable = nil
                    isOccluded = false
                case .occluded:
                    drawable = nil
                    isOccluded = true
                }
                return .renderer(Self.presentationOutcome(try await screen.render(
                    drawable: drawable,
                    isOccluded: isOccluded,
                    completion: { completion.signalFromNative() }
                )))
            case .queued(let work):
                return try await work.perform()
            case .detach:
                return .renderer(Self.presentationOutcome(try await screen.detachRenderer()))
            case .reattach(let size):
                return .renderer(Self.presentationOutcome(try await screen.reattachRenderer(
                    pixelWidth: size.pixelWidth,
                    pixelHeight: size.pixelHeight
                )))
            case .resetPlayerRendererDomain:
                try await screen.resetPlayerRendererDomain()
                return .none
            case .close:
                try await screen.close()
                return .none
            }
        }
    }

    private nonisolated static func presentationOutcome(
        _ outcome: ExperienceInteractiveRenderOutcome
    ) -> ExperienceRuntimePresentationRenderOutcome {
        let disposition: ExperienceRuntimePresentationRenderOutcome.Disposition =
            switch outcome.disposition {
            case .none: .none
            case .presented: .presented
            case .skippedZeroSize: .skippedZeroSize
            case .skippedTimeout: .skippedTimeout
            case .skippedOccluded: .skippedOccluded
            case .reconfigured: .reconfigured
            case .recreated: .recreated
            case .deviceLost: .deviceLost
            case .outOfMemory: .outOfMemory
            }
        let health: ExperienceRuntimePresentationRenderOutcome.Health = switch outcome.health {
        case .healthy: .healthy
        case .deviceLost: .deviceLost
        case .outOfMemory: .outOfMemory
        case .failed: .failed
        }
        return ExperienceRuntimePresentationRenderOutcome(
            disposition: disposition,
            health: health,
            pixelWidth: outcome.pixelWidth,
            pixelHeight: outcome.pixelHeight,
            drawCalls: outcome.drawCalls
        )
    }
}

private final class ExperienceRuntimePresentationWorkCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@MainActor @Sendable (Result<Void, Error>) -> Void)?

    init(_ callback: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void) {
        self.callback = callback
    }

    @MainActor
    func finish(_ result: Result<Void, Error>) {
        let callback = lock.withLock {
            defer { self.callback = nil }
            return self.callback
        }
        callback?(result)
    }
}

/// Swift-owned presentation policy for one native interactive screen.
///
/// MainActor owns the view, layer, drawables, timestamps, lifecycle and FIFO.
/// The session owns all C handles and calls. At most one session operation is
/// in flight, and detach/reattach waits for every native frame completion.
@MainActor
final class ExperienceRuntimePresentationLoop: NSObject {
    private enum RecoveryStage: Equatable {
        case idle, detach, reattach, resetDomain, refreshDevice, resize, redraw
    }

    private struct PendingWork {
        let work: ExperienceRuntimePresentationQueuedWork
        let completion: ExperienceRuntimePresentationWorkCompletion
    }

    private let session: ExperienceRuntimePresentationSession
    private weak var surfaceView: ExperienceRuntimeSurfaceView?
    private let notificationCenter: NotificationCenter
    private let usesSystemDisplayLink: Bool
    private let onSessionResult: @MainActor () -> Void
    private let onPresentedDrawable: @MainActor (ExperienceRuntimePresentedDrawable) -> Void
    private let onAcceptedPointerInput: @MainActor (ExperienceRuntimeAcceptedPointerInput) -> Void
    private let onError: @MainActor (Error) -> Void
    private let drawableGate: ExperienceRuntimeDrawableGate
    private let acquireDrawable: @MainActor (CAMetalLayer) -> (any CAMetalDrawable)?
    private let observeDrawablePresentation: @MainActor (
        any CAMetalDrawable,
        @escaping @Sendable (
            TimeInterval,
            ExperienceRuntimePresentedDrawable.Provenance
        ) -> Void
    ) -> Void
    private let nativeCompletionPresentationFallback:
        ExperienceRuntimePresentedDrawable.Provenance?
    private let firstPresentedDrawableGate = ExperienceRuntimeOneShotGate()

    private var frameClock = ExperienceRuntimeFrameClock()
    private var pointerInput = ExperienceRuntimePointerInputRouter()
    private var pendingPointers = ExperienceRuntimePresentationPointerQueue()
    private var pendingWork: [PendingWork] = []
    private var inFlightWork: PendingWork?
    private nonisolated(unsafe) var displayLink: CADisplayLink?
    private var displayLinkProxy: ExperienceRuntimePresentationDisplayLinkProxy?
    private weak var displayLinkScreen: UIScreen?
    private nonisolated(unsafe) var notificationTokens: [NSObjectProtocol] = []
    private nonisolated(unsafe) var sceneNotificationTokens: [NSObjectProtocol] = []
    private weak var observedWindowScene: UIWindowScene?
    private var isStarted = false
    private var isStarting = false
    private var isShuttingDown = false
    private var operationInFlight = false
    private var pendingTimestamp: TimeInterval?
    private var pendingZeroDeltaFrame = false
    private var zeroDeltaRequestGeneration: UInt64 = 0
    private var zeroDeltaStepGeneration: UInt64?
    private var zeroDeltaRenderGeneration: UInt64?
    private var zeroDeltaGenerationByFrameID: [UInt64: UInt64] = [:]
    private var completedZeroDeltaGeneration: UInt64 = 0
    private var pendingRender = false
    private var applicationIsActive = true
    private var owningSceneIsActive = true
    private var isPresentationVisible = true
    private var isTimelineActive = true
    private var rendererIsAttached = true
    private var recoveryStage: RecoveryStage = .idle
    private var deviceLossRecoveryCount = 0
    private var awaitingRecoveryFrame = false
    private var lastAppliedSize: ExperienceRuntimeSurfaceSize?
    private var frameSequence: UInt64 = 0
    private var lifecycleGeneration: UInt64 = 0
    private var inFlightFrameIDs: Set<UInt64> = []
    private var terminalError: Error?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        session: ExperienceRuntimePresentationSession,
        surfaceView: ExperienceRuntimeSurfaceView,
        notificationCenter: NotificationCenter = .default,
        drawableGate: ExperienceRuntimeDrawableGate? = nil,
        usesSystemDisplayLink: Bool = true,
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
        ) -> Void = { drawable, handler in
            #if os(iOS) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)
            drawable.addPresentedHandler { presentedDrawable in
                handler(
                    presentedDrawable.presentedTime,
                    .physicalPresentedHandler
                )
            }
            #else
            // Simulator and UIKit-on-Mac Metal APIs cannot confirm display
            // presentation. Their native completion is reported separately as
            // an explicitly provisional proxy.
            _ = drawable
            _ = handler
            #endif
        },
        nativeCompletionPresentationFallback:
            ExperienceRuntimePresentedDrawable.Provenance? = {
                #if os(iOS) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)
                nil
                #else
                .runtimeCompletionProxy
                #endif
            }(),
        onError: @escaping @MainActor (Error) -> Void = { _ in }
    ) {
        self.session = session
        self.surfaceView = surfaceView
        self.notificationCenter = notificationCenter
        self.drawableGate = drawableGate ?? ExperienceRuntimeDrawableGate(
            capacity: ExperienceRuntimePresentationLimits.maximumDrawableCount
        )
        self.usesSystemDisplayLink = usesSystemDisplayLink
        self.acquireDrawable = acquireDrawable
        self.onSessionResult = onSessionResult
        self.onPresentedDrawable = onPresentedDrawable
        self.onAcceptedPointerInput = onAcceptedPointerInput
        self.observeDrawablePresentation = observeDrawablePresentation
        self.nativeCompletionPresentationFallback = nativeCompletionPresentationFallback
        self.onError = onError
        super.init()
    }

    func start() async throws {
        guard !isStarted else { return }
        if isStarting {
            await waitForStartToFinish()
            guard isStarted else { throw CancellationError() }
            return
        }
        guard !isShuttingDown, let surfaceView else { throw CancellationError() }

        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        isStarting = true
        defer {
            isStarting = false
            resumeIdleWaiters()
        }
        terminalError = nil
        applicationIsActive = UIApplication.shared.applicationState == .active
        refreshOwningSceneActivity()
        let deviceResult = try await session.perform(.copyMetalDevice)
        guard !isShuttingDown, generation == lifecycleGeneration else {
            throw CancellationError()
        }
        guard case .metalDevice(let device) = deviceResult.value else {
            throw ExperienceRuntimePresentationLoopError.unexpectedSessionResult
        }
        configure(surfaceView.metalLayer, with: device)
        let size = surfaceSize(for: surfaceView)
        let resizeResult = try await session.perform(.resize(size))
        guard !isShuttingDown, generation == lifecycleGeneration else {
            throw CancellationError()
        }
        guard case .renderer(let outcome) = resizeResult.value else {
            throw ExperienceRuntimePresentationLoopError.unexpectedSessionResult
        }
        try requireHealthy(outcome)
        lastAppliedSize = size
        rendererIsAttached = true
        frameClock.reset()
        isStarted = true
        surfaceView.runtimeObserver = self
        installApplicationObservers()
        updateOwningSceneObservers()
        updateDisplayLinkForCurrentScreen()
        reconcile()
    }

    func shutdown() async {
        if isShuttingDown {
            await waitForShutdownToFinish()
            return
        }
        guard isStarted || operationInFlight || rendererIsAttached else { return }
        isShuttingDown = true
        lifecycleGeneration &+= 1
        isStarted = false
        pendingTimestamp = nil
        pendingZeroDeltaFrame = false
        zeroDeltaStepGeneration = nil
        zeroDeltaRenderGeneration = nil
        zeroDeltaGenerationByFrameID.removeAll()
        pendingRender = false
        pendingPointers.removeAll()
        pointerInput.reset()
        cancelPendingWork(with: CancellationError())
        invalidateDisplayLink()
        removeApplicationObservers()
        surfaceView?.runtimeObserver = nil
        await waitForStartToFinish()
        await waitForOperationToFinish()
        await waitForFramesToFinish()

        if rendererIsAttached {
            do {
                _ = try await session.perform(.detach)
                rendererIsAttached = false
            } catch {
                onError(error)
            }
        }
        do {
            _ = try await session.perform(.close)
        } catch {
            onError(error)
        }
        surfaceView?.metalLayer.device = nil
        lastAppliedSize = nil
        recoveryStage = .idle
        isShuttingDown = false
        resumeShutdownWaiters()
    }

    /// Queues product work behind all previously accepted native operations.
    /// Its result delivery and completion run exactly once on MainActor.
    func enqueue(
        _ work: ExperienceRuntimePresentationQueuedWork,
        completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void = { _ in }
    ) {
        guard terminalError == nil, !isShuttingDown else {
            completion(.failure(terminalError ?? CancellationError()))
            return
        }
        let acceptedWorkCount = pendingWork.count + (inFlightWork == nil ? 0 : 1)
        guard acceptedWorkCount < ExperienceRuntimePresentationLimits.pendingWork else {
            completion(.failure(ExperienceRuntimePresentationLoopError.pendingWorkOverflow))
            return
        }
        pendingWork.append(PendingWork(
            work: work,
            completion: ExperienceRuntimePresentationWorkCompletion(completion)
        ))
        drain()
    }

    func displayLinkDidFire(at timestamp: TimeInterval) {
        guard shouldAdvance else {
            reconcile()
            return
        }
        pendingTimestamp = timestamp
        drain()
    }

    func setPresentationVisible(_ visible: Bool) {
        guard isPresentationVisible != visible else { return }
        isPresentationVisible = visible
        if visible, isTimelineActive {
            frameClock.reset()
            // Request an immediate delta-0 frame instead of seeding wall-clock
            // time into a display-link-driven timeline.
            pendingZeroDeltaFrame = true
        }
        reconcile()
    }

    /// Controls authored wall-clock advancement independently from drawable
    /// visibility. Hidden lifecycle phases freeze time while queued host work
    /// remains executable through an explicit zero-delta step.
    func setTimelineActive(_ active: Bool) {
        guard isTimelineActive != active else { return }
        isTimelineActive = active
        pendingTimestamp = nil
        frameClock.reset()
        if active {
            // Delta-0 resume per the lifecycle contract; never a time jump.
            pendingZeroDeltaFrame = true
        }
        reconcile()
    }

    func advanceZeroDelta() async throws {
        guard isStarted, !isShuttingDown, terminalError == nil else {
            throw terminalError ?? CancellationError()
        }
        zeroDeltaRequestGeneration &+= 1
        let generation = zeroDeltaRequestGeneration
        pendingZeroDeltaFrame = true
        reconcile()
        while completedZeroDeltaGeneration < generation, terminalError == nil {
            await withCheckedContinuation { idleWaiters.append($0) }
        }
        if let terminalError { throw terminalError }
    }

    func runtimeSurfaceViewGeometryDidChange() {
        updateOwningSceneObservers()
        updateDisplayLinkForCurrentScreen()
        guard isStarted else { return }
        reconcile()
    }

    func runtimeSurfaceViewVisibilityDidChange() {
        refreshOwningSceneActivity()
        updateOwningSceneObservers()
        updateDisplayLinkForCurrentScreen()
        if shouldAdvance {
            pendingTimestamp = pendingTimestamp ?? CACurrentMediaTime()
        } else if !shouldAdvance {
            pendingTimestamp = nil
            frameClock.reset()
        }
        reconcile()
    }

    deinit {
        displayLink?.invalidate()
        notificationTokens.forEach(notificationCenter.removeObserver)
        sceneNotificationTokens.forEach(notificationCenter.removeObserver)
    }

    private func reconcile() {
        updateDisplayLinkForCurrentScreen()
        displayLink?.isPaused = !shouldAdvance
        drain()
    }

    private func drain() {
        guard !operationInFlight,
              isStarted,
              !isShuttingDown,
              terminalError == nil,
              let operation = nextOperation() else { return }

        operationInFlight = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await self.session.perform(operation)
                try await self.consume(result, for: operation)
            } catch {
                if case .queued = operation {
                    self.finishInFlightWork(.failure(error))
                } else {
                    self.reportTerminal(error)
                }
            }
            self.operationInFlight = false
            self.resumeIdleWaiters()
            self.reconcile()
        }
    }

    private func nextOperation() -> ExperienceRuntimePresentationSessionOperation? {
        guard let surfaceView else {
            reportTerminal(ExperienceRuntimePresentationLoopError.disposedSurface)
            return nil
        }

        // Every accepted step gets an explicit render outcome before lifecycle
        // work, even when visibility changed while the step was in flight.
        if pendingRender, rendererIsAttached {
            pendingRender = false
            return makeRenderOperation(for: surfaceView)
        }

        if recoveryStage != .idle {
            return nextRecoveryOperation(for: surfaceView)
        }

        if !shouldAdvance {
            if rendererIsAttached, inFlightFrameIDs.isEmpty { return .detach }
            if !pendingWork.isEmpty { return takeNextQueuedOperation() }
            if pendingZeroDeltaFrame {
                pendingZeroDeltaFrame = false
                zeroDeltaStepGeneration = zeroDeltaRequestGeneration
                return .step(ExperienceRuntimePresentationStep(
                    elapsedSeconds: 0,
                    pointers: [],
                    requestsRender: false
                ))
            }
            return nil
        }

        if !shouldPresent {
            if rendererIsAttached, inFlightFrameIDs.isEmpty { return .detach }
            if !pendingWork.isEmpty { return takeNextQueuedOperation() }
            if pendingZeroDeltaFrame {
                pendingZeroDeltaFrame = false
                zeroDeltaStepGeneration = zeroDeltaRequestGeneration
                return .step(ExperienceRuntimePresentationStep(
                    elapsedSeconds: 0,
                    pointers: [],
                    requestsRender: false
                ))
            }
            guard let timestamp = pendingTimestamp else { return nil }
            pendingTimestamp = nil
            let pointers = pendingPointers.takeBatch()
            if !pendingPointers.isEmpty { pendingTimestamp = timestamp }
            return .step(ExperienceRuntimePresentationStep(
                elapsedSeconds: Float(frameClock.frame(at: timestamp).delta),
                pointers: pointers,
                requestsRender: false
            ))
        }

        let size = surfaceSize(for: surfaceView)
        if !rendererIsAttached { return .reattach(size) }
        if size != lastAppliedSize { return .resize(size) }
        if !pendingWork.isEmpty { return takeNextQueuedOperation() }
        if pendingZeroDeltaFrame {
            pendingZeroDeltaFrame = false
            zeroDeltaStepGeneration = zeroDeltaRequestGeneration
            let frame = frameClock.zeroDeltaFrame(at: CACurrentMediaTime())
            return .step(ExperienceRuntimePresentationStep(
                elapsedSeconds: Float(frame.delta),
                pointers: [],
                requestsRender: true
            ))
        }
        guard let timestamp = pendingTimestamp else { return nil }
        pendingTimestamp = nil
        let pointers = pendingPointers.takeBatch()
        if !pendingPointers.isEmpty { pendingTimestamp = timestamp }
        return .step(ExperienceRuntimePresentationStep(
            elapsedSeconds: Float(frameClock.frame(at: timestamp).delta),
            pointers: pointers,
            requestsRender: true
        ))
    }

    private func nextRecoveryOperation(
        for surfaceView: ExperienceRuntimeSurfaceView
    ) -> ExperienceRuntimePresentationSessionOperation? {
        let size = surfaceSize(for: surfaceView)
        switch recoveryStage {
        case .idle:
            return nil
        case .detach:
            guard inFlightFrameIDs.isEmpty else { return nil }
            if rendererIsAttached { return .detach }
            recoveryStage = .reattach
            return nextRecoveryOperation(for: surfaceView)
        case .reattach:
            return .reattach(size)
        case .resetDomain:
            return .resetPlayerRendererDomain
        case .refreshDevice:
            return .copyMetalDevice
        case .resize:
            return .resize(size)
        case .redraw:
            recoveryStage = .idle
            pendingTimestamp = CACurrentMediaTime()
            return nextOperation()
        }
    }

    private func consume(
        _ result: ExperienceRuntimePresentationSessionResult,
        for operation: ExperienceRuntimePresentationSessionOperation
    ) async throws {
        switch (operation, result.value) {
        case (.copyMetalDevice, .metalDevice(let device)):
            guard let layer = surfaceView?.metalLayer else {
                throw ExperienceRuntimePresentationLoopError.disposedSurface
            }
            configure(layer, with: device)
            if recoveryStage == .refreshDevice { recoveryStage = .resize }
        case (.resize(let size), .renderer(let outcome)):
            try requireHealthy(outcome)
            lastAppliedSize = size
            if recoveryStage == .resize { recoveryStage = .redraw }
            else { pendingTimestamp = pendingTimestamp ?? CACurrentMediaTime() }
        case (.step(let step), .session):
            await result.deliver()
            if !step.pointers.isEmpty {
                onAcceptedPointerInput(.init(eventCount: step.pointers.count))
            }
            onSessionResult()
            pendingRender = step.requestsRender
            if let generation = zeroDeltaStepGeneration {
                zeroDeltaStepGeneration = nil
                if step.requestsRender {
                    zeroDeltaRenderGeneration = generation
                } else {
                    completedZeroDeltaGeneration = max(
                        completedZeroDeltaGeneration,
                        generation
                    )
                }
            }
        case (.render(_, let completion), .renderer(let outcome)):
            completion.recordRenderOutcome(outcome)
            try consumeRenderOutcome(outcome)
        case (.queued, .work(let requestsFrame)):
            await result.deliver()
            finishInFlightWork(.success(()))
            if requestsFrame {
                if shouldAdvance {
                    pendingTimestamp = pendingTimestamp ?? CACurrentMediaTime()
                } else {
                    pendingZeroDeltaFrame = true
                }
            }
        case (.detach, .renderer(let outcome)):
            try requireHealthy(outcome)
            rendererIsAttached = false
            lastAppliedSize = nil
            frameClock.reset()
            if recoveryStage == .detach { recoveryStage = .reattach }
        case (.reattach, .renderer(let outcome)):
            try requireHealthy(outcome)
            rendererIsAttached = true
            frameClock.reset()
            recoveryStage = .resetDomain
        case (.resetPlayerRendererDomain, .none):
            recoveryStage = .refreshDevice
        default:
            throw ExperienceRuntimePresentationLoopError.unexpectedSessionResult
        }
    }

    private func consumeRenderOutcome(
        _ outcome: ExperienceRuntimePresentationRenderOutcome
    ) throws {
        switch outcome.health {
        case .healthy:
            if awaitingRecoveryFrame {
                awaitingRecoveryFrame = false
                deviceLossRecoveryCount = 0
            }
        case .deviceLost:
            guard deviceLossRecoveryCount == 0 else {
                throw ExperienceRuntimePresentationLoopError.repeatedDeviceLoss
            }
            deviceLossRecoveryCount = 1
            awaitingRecoveryFrame = true
            recoveryStage = .detach
            pendingTimestamp = nil
            frameClock.reset()
        case .outOfMemory, .failed:
            throw ExperienceRuntimePresentationLoopError.rendererFailed(outcome.health)
        }
    }

    private func requireHealthy(_ outcome: ExperienceRuntimePresentationRenderOutcome) throws {
        guard outcome.health == .healthy else {
            throw ExperienceRuntimePresentationLoopError.rendererFailed(outcome.health)
        }
    }

    private func makeRenderOperation(
        for surfaceView: ExperienceRuntimeSurfaceView
    ) -> ExperienceRuntimePresentationSessionOperation {
        frameSequence &+= 1
        let frameID = frameSequence
        if let generation = zeroDeltaRenderGeneration {
            zeroDeltaRenderGeneration = nil
            zeroDeltaGenerationByFrameID[frameID] = generation
        }
        let generation = lifecycleGeneration
        inFlightFrameIDs.insert(frameID)
        let completion = ExperienceRuntimePresentationFrameCompletion { [weak self] in
            Task { @MainActor [weak self] in
                self?.completeFrame(frameID, generation: generation)
            }
        }
        guard shouldPresent else {
            return .render(.occluded, completion: completion)
        }
        guard let size = lastAppliedSize,
              size.pixelWidth > 0,
              size.pixelHeight > 0,
              let permit = drawableGate.tryAcquire() else {
            return .render(.timeout, completion: completion)
        }
        guard let drawable = acquireDrawable(surfaceView.metalLayer) else {
            permit.release()
            return .render(.timeout, completion: completion)
        }
        let firstPresentedDrawableGate = firstPresentedDrawableGate
        let shouldObservePresentation = !firstPresentedDrawableGate.isClaimed
        let presentedDrawableCallback: (@Sendable (
            ExperienceRuntimePresentedDrawable
        ) -> Void)? = if shouldObservePresentation {
            { [weak self] drawable in
                guard firstPresentedDrawableGate.claim() else { return }
                Task { @MainActor [weak self] in
                    self?.onPresentedDrawable(drawable)
                }
            }
        } else {
            nil
        }
        let wrappedCompletion = ExperienceRuntimePresentationFrameCompletion(
            {
                permit.release()
                completion.signalFromNative()
            },
            frameNumber: frameID,
            onPresentedDrawable: presentedDrawableCallback,
            nativeCompletionFallback: nativeCompletionPresentationFallback
        )
        if shouldObservePresentation {
            observeDrawablePresentation(drawable) { presentedTime, provenance in
                wrappedCompletion.signalDrawablePresented(
                    at: presentedTime,
                    provenance: provenance
                )
            }
        }
        return .render(
            .available(ExperienceRuntimePresentationDrawable(value: drawable)),
            completion: wrappedCompletion
        )
    }

    private func completeFrame(_ frameID: UInt64, generation: UInt64) {
        guard inFlightFrameIDs.remove(frameID) != nil else { return }
        if let zeroDeltaGeneration = zeroDeltaGenerationByFrameID.removeValue(
            forKey: frameID
        ) {
            completedZeroDeltaGeneration = max(
                completedZeroDeltaGeneration,
                zeroDeltaGeneration
            )
        }
        resumeIdleWaiters()
        if generation == lifecycleGeneration { reconcile() }
    }

    private func configure(_ layer: CAMetalLayer, with device: any MTLDevice) {
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.maximumDrawableCount = ExperienceRuntimePresentationLimits.maximumDrawableCount
        layer.allowsNextDrawableTimeout = true
        layer.presentsWithTransaction = false
    }

    private func surfaceSize(
        for surfaceView: ExperienceRuntimeSurfaceView
    ) -> ExperienceRuntimeSurfaceSize {
        let scale = surfaceView.window?.screen.scale ?? surfaceView.contentScaleFactor
        surfaceView.metalLayer.contentsScale = scale
        let size = ExperienceRuntimeSurfaceSizing.pixels(
            width: surfaceView.bounds.width,
            height: surfaceView.bounds.height,
            scale: scale
        )
        surfaceView.metalLayer.drawableSize = CGSize(
            width: Int(size.pixelWidth),
            height: Int(size.pixelHeight)
        )
        return size
    }

    private var shouldAdvance: Bool {
        guard isStarted,
              !isShuttingDown,
              isTimelineActive,
              applicationIsActive,
              let surfaceView,
              surfaceView.window != nil
                || observedWindowScene != nil
                || displayLinkScreen != nil,
              owningSceneIsActive else { return false }
        return true
    }

    private var shouldPresent: Bool {
        guard shouldAdvance,
              isPresentationVisible,
              let surfaceView,
              surfaceViewIsEffectivelyVisible(surfaceView) else { return false }
        return true
    }

    private func surfaceViewIsEffectivelyVisible(
        _ view: ExperienceRuntimeSurfaceView
    ) -> Bool {
        guard let window = view.window,
              !window.isHidden,
              window.alpha > 0,
              !view.isHidden,
              view.alpha > 0 else { return false }
        var ancestor = view.superview
        while let current = ancestor {
            if current.isHidden || current.alpha <= 0 { return false }
            ancestor = current.superview
        }
        return true
    }

    private func updateDisplayLinkForCurrentScreen() {
        guard usesSystemDisplayLink else {
            invalidateDisplayLink()
            return
        }
        guard isStarted else {
            invalidateDisplayLink()
            return
        }
        guard let screen = surfaceView?.window?.screen else { return }
        if displayLink != nil, displayLinkScreen === screen { return }
        invalidateDisplayLink()
        let proxy = ExperienceRuntimePresentationDisplayLinkProxy(loop: self)
        guard let displayLink = screen.displayLink(
            withTarget: proxy,
            selector: #selector(proxy.tick(_:))
        ) else { return }
        displayLink.isPaused = true
        displayLink.add(to: .main, forMode: .common)
        displayLinkProxy = proxy
        displayLinkScreen = screen
        self.displayLink = displayLink
    }

    private func invalidateDisplayLink() {
        displayLink?.isPaused = true
        displayLink?.invalidate()
        displayLink = nil
        displayLinkProxy = nil
        displayLinkScreen = nil
    }

    private func installApplicationObservers() {
        guard notificationTokens.isEmpty else { return }
        notificationTokens = [
            notificationCenter.addObserver(
                forName: UIApplication.willResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.applicationIsActive = false
                    self?.pendingTimestamp = nil
                    self?.frameClock.reset()
                    self?.reconcile()
                }
            },
            notificationCenter.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.applicationIsActive = true
                    self?.refreshOwningSceneActivity()
                    self?.frameClock.reset()
                    self?.pendingTimestamp = CACurrentMediaTime()
                    self?.reconcile()
                }
            },
            notificationCenter.addObserver(
                forName: UIApplication.didReceiveMemoryWarningNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleMemoryWarning()
                }
            },
        ]
    }

    private func updateOwningSceneObservers() {
        guard let scene = surfaceView?.window?.windowScene else { return }
        guard observedWindowScene !== scene else { return }
        sceneNotificationTokens.forEach(notificationCenter.removeObserver)
        sceneNotificationTokens.removeAll()
        observedWindowScene = scene
        sceneNotificationTokens = [
            notificationCenter.addObserver(
                forName: UIScene.willDeactivateNotification,
                object: scene,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.owningSceneIsActive = false
                    self?.pendingTimestamp = nil
                    self?.frameClock.reset()
                    self?.reconcile()
                }
            },
            notificationCenter.addObserver(
                forName: UIScene.didActivateNotification,
                object: scene,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.owningSceneIsActive = true
                    self?.frameClock.reset()
                    self?.pendingTimestamp = CACurrentMediaTime()
                    self?.reconcile()
                }
            },
        ]
    }

    private func refreshOwningSceneActivity() {
        owningSceneIsActive = (surfaceView?.window?.windowScene ?? observedWindowScene).map {
            $0.activationState == .foregroundActive
        } ?? true
    }

    private func handleMemoryWarning() {
        guard isStarted,
              !isShuttingDown,
              terminalError == nil,
              recoveryStage == .idle else { return }
        guard shouldPresent else {
            reconcile()
            return
        }
        recoveryStage = .detach
        pendingTimestamp = nil
        frameClock.reset()
        reconcile()
    }

    private func removeApplicationObservers() {
        notificationTokens.forEach(notificationCenter.removeObserver)
        notificationTokens.removeAll()
        sceneNotificationTokens.forEach(notificationCenter.removeObserver)
        sceneNotificationTokens.removeAll()
        observedWindowScene = nil
    }

    private func takeNextQueuedOperation() -> ExperienceRuntimePresentationSessionOperation? {
        guard inFlightWork == nil, !pendingWork.isEmpty else { return nil }
        let work = pendingWork.removeFirst()
        inFlightWork = work
        return .queued(work.work)
    }

    private func finishInFlightWork(_ result: Result<Void, Error>) {
        guard let work = inFlightWork else { return }
        inFlightWork = nil
        work.completion.finish(result)
    }

    private func cancelPendingWork(with error: Error) {
        let work = pendingWork
        pendingWork.removeAll()
        work.forEach { $0.completion.finish(.failure(error)) }
    }

    private func reportTerminal(_ error: Error) {
        guard terminalError == nil else { return }
        terminalError = error
        pendingTimestamp = nil
        pendingZeroDeltaFrame = false
        zeroDeltaStepGeneration = nil
        zeroDeltaRenderGeneration = nil
        zeroDeltaGenerationByFrameID.removeAll()
        pendingRender = false
        pendingPointers.removeAll()
        pointerInput.reset()
        displayLink?.isPaused = true
        onError(error)
        cancelPendingWork(with: error)
    }

    private func waitForOperationToFinish() async {
        while operationInFlight {
            await withCheckedContinuation { idleWaiters.append($0) }
        }
    }

    private func waitForStartToFinish() async {
        while isStarting {
            await withCheckedContinuation { idleWaiters.append($0) }
        }
    }

    private func waitForFramesToFinish() async {
        while !inFlightFrameIDs.isEmpty {
            await withCheckedContinuation { idleWaiters.append($0) }
        }
    }

    private func waitForShutdownToFinish() async {
        guard isShuttingDown else { return }
        await withCheckedContinuation { shutdownWaiters.append($0) }
    }

    private func resumeIdleWaiters() {
        let waiters = idleWaiters
        idleWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func resumeShutdownWaiters() {
        let waiters = shutdownWaiters
        shutdownWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

extension ExperienceRuntimePresentationLoop: ExperienceRuntimeSurfaceViewObserver {
    func runtimeSurfaceViewDidReceivePointerEvents(
        _ events: [ExperienceRuntimeViewPointerEvent]
    ) {
        guard isStarted,
              !isShuttingDown,
              terminalError == nil,
              let surfaceView,
              let transform = ExperienceContainCenterTransform(
                  artboardBounds: session.artboardBounds,
                  viewportBounds: surfaceView.bounds
              ) else { return }
        let projected = pointerInput.runtimeEvents(for: events, transform: transform)
        guard !projected.isEmpty else { return }
        pendingPointers.enqueue(projected)
        pendingTimestamp = CACurrentMediaTime()
        drain()
    }
}

enum ExperienceRuntimePresentationLoopError: Error, Equatable {
    case unexpectedSessionResult
    case rendererFailed(ExperienceRuntimePresentationRenderOutcome.Health)
    case repeatedDeviceLoss
    case disposedSurface
    case pendingWorkOverflow
}

@MainActor
private final class ExperienceRuntimePresentationDisplayLinkProxy: NSObject {
    weak var loop: ExperienceRuntimePresentationLoop?

    init(loop: ExperienceRuntimePresentationLoop) {
        self.loop = loop
    }

    @objc func tick(_ displayLink: CADisplayLink) {
        loop?.displayLinkDidFire(at: displayLink.timestamp)
    }
}
#endif
