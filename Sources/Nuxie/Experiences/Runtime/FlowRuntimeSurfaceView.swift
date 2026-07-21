#if canImport(UIKit) && canImport(QuartzCore)
import Foundation
import Metal
import QuartzCore
import UIKit

@MainActor
protocol FlowRuntimeSurfaceViewObserver: AnyObject {
    func runtimeSurfaceViewGeometryDidChange()
    func runtimeSurfaceViewVisibilityDidChange()
    func runtimeSurfaceViewDidReceivePointerEvents(
        _ events: [FlowRuntimeViewPointerEvent]
    )
}

/// Transparent UIKit host whose backing layer remains owned and configured by Swift.
@MainActor
final class FlowRuntimeSurfaceView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    weak var runtimeObserver: (any FlowRuntimeSurfaceViewObserver)?

    override var isHidden: Bool {
        didSet {
            if isHidden != oldValue {
                runtimeObserver?.runtimeSurfaceViewVisibilityDidChange()
            }
        }
    }

    override var alpha: CGFloat {
        didSet {
            if alpha != oldValue {
                runtimeObserver?.runtimeSurfaceViewVisibilityDidChange()
            }
        }
    }

    var metalLayer: CAMetalLayer {
        // `layerClass` makes this cast an invariant of the view type.
        layer as! CAMetalLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayer()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.scale ?? contentScaleFactor
        contentScaleFactor = scale
        metalLayer.contentsScale = scale
        runtimeObserver?.runtimeSurfaceViewGeometryDidChange()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        runtimeObserver?.runtimeSurfaceViewVisibilityDidChange()
        runtimeObserver?.runtimeSurfaceViewGeometryDidChange()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        deliver(touches, as: .down)
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        deliver(touches, as: .move)
        super.touchesMoved(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        // Rust expands Up into Up -> Exit -> immediate advance. Sending a
        // second Exit here would duplicate authored pointer-exit behavior.
        deliver(touches, as: .up)
        super.touchesEnded(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        // Rust performs the matching Cancel -> Exit sequence internally.
        deliver(touches, as: .cancel)
        super.touchesCancelled(touches, with: event)
    }

    private func configureLayer() {
        isOpaque = false
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        metalLayer.isOpaque = false
        metalLayer.backgroundColor = UIColor.clear.cgColor
        metalLayer.contentsScale = contentScaleFactor

        let recognizer = UIHoverGestureRecognizer(
            target: self,
            action: #selector(handleHover(_:))
        )
        recognizer.cancelsTouchesInView = false
        addGestureRecognizer(recognizer)
    }

    private func deliver(_ touches: Set<UITouch>, as kind: FlowRuntimePointerKind) {
        guard !touches.isEmpty else { return }
        runtimeObserver?.runtimeSurfaceViewDidReceivePointerEvents(
            touches.map { pointerEvent(for: $0, as: kind) }
        )
    }

    func pointerEvent(
        for touch: UITouch,
        as kind: FlowRuntimePointerKind
    ) -> FlowRuntimeViewPointerEvent {
        FlowRuntimeViewPointerEvent(
            source: FlowRuntimePointerSourceID(touch),
            kind: kind,
            location: touch.location(in: self),
            timestampSeconds: touch.timestamp
        )
    }

    @objc private func handleHover(_ recognizer: UIHoverGestureRecognizer) {
        let kind: FlowRuntimePointerKind
        switch recognizer.state {
        case .began, .changed:
            kind = .move
        case .ended, .cancelled, .failed:
            // Hover has no preceding Up/Cancel, so this is a standalone Exit.
            kind = .exit
        case .possible:
            return
        @unknown default:
            return
        }
        runtimeObserver?.runtimeSurfaceViewDidReceivePointerEvents([
            FlowRuntimeViewPointerEvent(
                source: FlowRuntimePointerSourceID(recognizer),
                kind: kind,
                location: recognizer.location(in: self),
                timestampSeconds: CACurrentMediaTime()
            )
        ])
    }
}

/// Mirrors Rive's proven nonblocking drawable budget: the main actor checks a
/// permit before calling `nextDrawable()`, and the native command-buffer
/// completion releases it. This prevents GPU backpressure from stalling UIKit.
@MainActor
final class FlowRuntimeDrawableGate {
    private let semaphore: DispatchSemaphore

    init(capacity: Int) {
        precondition(capacity > 0)
        semaphore = DispatchSemaphore(value: capacity)
    }

    func tryAcquire() -> FlowRuntimeDrawablePermit? {
        guard semaphore.wait(timeout: .now()) == .success else { return nil }
        return FlowRuntimeDrawablePermit(semaphore: semaphore)
    }
}

final class FlowRuntimeDrawablePermit: @unchecked Sendable {
    private let semaphore: DispatchSemaphore
    private let lock = NSLock()
    private var isReleased = false

    fileprivate init(semaphore: DispatchSemaphore) {
        self.semaphore = semaphore
    }

    func release() {
        lock.lock()
        guard !isReleased else {
            lock.unlock()
            return
        }
        isReleased = true
        lock.unlock()
        semaphore.signal()
    }

    deinit {
        release()
    }
}

enum FlowRuntimeDisplayHostError: LocalizedError, Equatable {
    case pendingPointerInputOverflow(limit: Int)
    case pendingHostWorkOverflow(limit: Int)

    var errorDescription: String? {
        switch self {
        case .pendingPointerInputOverflow(let limit):
            "Pending runtime pointer input exceeded its fixed \(limit)-event budget"
        case .pendingHostWorkOverflow(let limit):
            "Pending runtime host work exceeded its fixed \(limit)-operation budget"
        }
    }
}

extension FlowRuntimeDisplayHostError: FlowRuntimeSessionFailureDisposition {
    /// Queue admission failures reject only the current host input. They do
    /// not prove that the native session's serialized lane is unusable.
    var invalidatesSession: Bool { false }
}

private struct FlowRuntimePendingPointerInput {
    static let maximumEventCount = FlowRuntimeSessionLimits.pointerEvents * 2

    private var batches: [[FlowRuntimePointerEvent]] = []
    private var eventCount = 0
    private var activePointerIDs: Set<Int32> = []

    var isEmpty: Bool { batches.isEmpty }

    mutating func enqueue(_ events: [FlowRuntimePointerEvent]) throws {
        var nextBatch: [FlowRuntimePointerEvent] = []
        nextBatch.reserveCapacity(min(events.count, Self.maximumEventCount))
        for event in events {
            switch event.kind {
            case .move:
                if activePointerIDs.contains(event.pointerID) {
                    if removeSupersededMove(
                        pointerID: event.pointerID,
                        from: &nextBatch
                    ) {
                        eventCount -= 1
                    }
                    // A move is transient. When lifecycle events consume the
                    // fixed budget, retaining the last accepted coordinate is
                    // safer than displacing a down or its reserved terminal.
                    guard hasCapacity(forAdditionalEvents: 1) else { continue }
                } else {
                    try reserveNewPointer(event.pointerID)
                }
            case .down:
                if activePointerIDs.contains(event.pointerID) {
                    try requireCapacity(forAdditionalEvents: 1)
                } else {
                    try reserveNewPointer(event.pointerID)
                }
            case .up, .cancel, .exit:
                if activePointerIDs.remove(event.pointerID) == nil {
                    try requireCapacity(forAdditionalEvents: 1)
                }
            }
            nextBatch.append(event)
            eventCount += 1
        }
        if !nextBatch.isEmpty {
            batches.append(nextBatch)
        }
    }

    mutating func takeBatch() -> [FlowRuntimePointerEvent]? {
        guard !batches.isEmpty else { return nil }
        let batch: [FlowRuntimePointerEvent]
        if batches[0].count <= FlowRuntimeSessionLimits.pointerEvents {
            batch = batches.removeFirst()
        } else {
            batch = Array(batches[0].prefix(FlowRuntimeSessionLimits.pointerEvents))
            batches[0].removeFirst(FlowRuntimeSessionLimits.pointerEvents)
        }
        eventCount -= batch.count
        return batch
    }

    mutating func removeAll() {
        batches.removeAll(keepingCapacity: false)
        activePointerIDs.removeAll(keepingCapacity: false)
        eventCount = 0
    }

    private mutating func reserveNewPointer(_ pointerID: Int32) throws {
        // Every admitted pointer reserves one additional slot for its future
        // up/cancel/exit. That terminal can therefore never be displaced by
        // moves or by another pointer start.
        try requireCapacity(forAdditionalEvents: 2)
        activePointerIDs.insert(pointerID)
    }

    private func requireCapacity(forAdditionalEvents count: Int) throws {
        guard hasCapacity(forAdditionalEvents: count) else {
            throw FlowRuntimeDisplayHostError.pendingPointerInputOverflow(
                limit: Self.maximumEventCount
            )
        }
    }

    private func hasCapacity(forAdditionalEvents count: Int) -> Bool {
        eventCount + activePointerIDs.count + count <= Self.maximumEventCount
    }

    @discardableResult
    private mutating func removeSupersededMove(
        pointerID: Int32,
        from nextBatch: inout [FlowRuntimePointerEvent]
    ) -> Bool {
        if let index = pendingMoveIndex(
            pointerID: pointerID,
            in: nextBatch
        ) {
            nextBatch.remove(at: index)
            return true
        }
        if nextBatch.contains(where: {
            $0.pointerID == pointerID && $0.kind != .move
        }) {
            return false
        }

        for batchIndex in batches.indices.reversed() {
            if let index = pendingMoveIndex(
                pointerID: pointerID,
                in: batches[batchIndex]
            ) {
                batches[batchIndex].remove(at: index)
                if batches[batchIndex].isEmpty {
                    batches.remove(at: batchIndex)
                }
                return true
            }
            if batches[batchIndex].contains(where: {
                $0.pointerID == pointerID && $0.kind != .move
            }) {
                return false
            }
        }
        return false
    }

    private func pendingMoveIndex(
        pointerID: Int32,
        in events: [FlowRuntimePointerEvent]
    ) -> Int? {
        for index in events.indices.reversed() where events[index].pointerID == pointerID {
            return events[index].kind == .move ? index : nil
        }
        return nil
    }
}

typealias FlowRuntimeOperationCompletion = @MainActor (
    Result<FlowRuntimeOperationResult, Error>
) -> Void

typealias FlowRuntimeTextRunCompletion = FlowRuntimeOperationCompletion

enum FlowRuntimeDisplayResultSource: Equatable, Sendable {
    case stateBatch
    case textRun
    case textRender
    case pointerBatch
    case frame
}

private struct FlowRuntimePendingStateBatches {
    struct Entry {
        let prepare: @MainActor () throws -> FlowRuntimeStateBatch
        let completion: FlowRuntimeOperationCompletion
    }

    private var entries: [Entry] = []

    var count: Int { entries.count }

    mutating func enqueue(_ entry: Entry) {
        entries.append(entry)
    }

    mutating func takeFirst() -> Entry? {
        guard !entries.isEmpty else { return nil }
        return entries.removeFirst()
    }

    mutating func removeAll() -> [Entry] {
        defer { entries.removeAll(keepingCapacity: false) }
        return entries
    }
}

private struct FlowRuntimePendingTextRuns {
    struct Entry {
        var mutation: FlowRuntimeTextRunMutation
        var completions: [FlowRuntimeTextRunCompletion]
    }

    private var orderedKeys: [Data] = []
    private var entriesByUTF8Name: [Data: Entry] = [:]
    private(set) var completionCount = 0

    var isEmpty: Bool { orderedKeys.isEmpty }

    mutating func enqueue(
        _ mutation: FlowRuntimeTextRunMutation,
        completion: @escaping FlowRuntimeTextRunCompletion
    ) {
        let key = Data(mutation.name.utf8)
        if var entry = entriesByUTF8Name[key] {
            entry.mutation = mutation
            entry.completions.append(completion)
            entriesByUTF8Name[key] = entry
            completionCount += 1
            return
        }
        orderedKeys.append(key)
        entriesByUTF8Name[key] = Entry(
            mutation: mutation,
            completions: [completion]
        )
        completionCount += 1
    }

    mutating func takeFirst() -> Entry? {
        guard !orderedKeys.isEmpty else { return nil }
        let key = orderedKeys.removeFirst()
        let entry = entriesByUTF8Name.removeValue(forKey: key)
        completionCount -= entry?.completions.count ?? 0
        return entry
    }

    mutating func removeAll() -> [Entry] {
        let entries = orderedKeys.compactMap { entriesByUTF8Name[$0] }
        orderedKeys.removeAll(keepingCapacity: false)
        entriesByUTF8Name.removeAll(keepingCapacity: false)
        completionCount = 0
        return entries
    }
}

/// Reference display driver for one visual session and one UIKit surface.
///
/// The driver keeps at most one async runtime operation in flight. While an
/// operation is running, display timestamps are reduced to the newest pending
/// value; detach, reattach, and resize take priority over that pending frame.
/// Its required result sink receives every successful session result exactly
/// once on `MainActor`, in serial completion order.
@MainActor
final class FlowRuntimeDisplayHost: NSObject {
    private enum SurfaceRecoveryStage: Equatable {
        case idle
        case detachRequired
        case reattachRequired
        case redrawRequired
        case awaitingRedraw
    }

    private enum PendingOperation {
        case detach
        case reattach(FlowRuntimeAppleSurfaceTarget)
        case recoveryDetach
        case recoveryReattach(FlowRuntimeAppleSurfaceTarget)
        case recoveryRedraw(FlowRuntimeFrameTime)
        case resize(FlowRuntimeSurfaceSize)
        case stateBatch(FlowRuntimePendingStateBatches.Entry)
        case textRun(FlowRuntimePendingTextRuns.Entry)
        case textRender(FlowRuntimeFrameTime)
        case pointerBatch([FlowRuntimePointerEvent])
        case offscreenAdvance(FlowRuntimeFrameTime)
        case frame(FlowRuntimeFrameTime)
    }

    private let session: FlowRenderSession
    private weak var surfaceView: FlowRuntimeSurfaceView?
    private let notificationCenter: NotificationCenter
    private let resultProjector: @MainActor (
        FlowRuntimeOperationResult
    ) -> FlowRuntimeOperationResult
    private let onResult: @MainActor (
        _ original: FlowRuntimeOperationResult,
        _ projected: FlowRuntimeOperationResult,
        _ source: FlowRuntimeDisplayResultSource
    ) -> Void
    private let onError: @MainActor (Error) -> Void
    private let drawableGate: FlowRuntimeDrawableGate
    private let usesSystemDisplayLink: Bool

    private var surface: FlowRenderSurface?
    private var displayLink: CADisplayLink?
    private var displayLinkProxy: FlowRuntimeDisplayLinkProxy?
    private weak var displayLinkScreen: UIScreen?
    private var notificationTokens: [NSObjectProtocol] = []
    private var frameClock = FlowRuntimeFrameClock()
    private var pointerInput = FlowRuntimePointerInputRouter()
    private var pendingPointerInput = FlowRuntimePendingPointerInput()
    private var pendingStateBatches = FlowRuntimePendingStateBatches()
    private var pendingTextRuns = FlowRuntimePendingTextRuns()
    private var textRenderRequested = false
    private var pointerBatchDispatchedSinceLastFrame = false
    private var pendingTimestamp: TimeInterval?
    private var lastAppliedSize: FlowRuntimeSurfaceSize?
    private var applicationIsActive = true
    private var isPresentationVisible = true
    private var isStarting = false
    private var isStarted = false
    private var isShuttingDown = false
    private var lifecycleGeneration: UInt64 = 0
    private var operationInFlight = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var lastStartupError: Error?
    private var terminalError: Error?
    private var surfaceRecoveryStage: SurfaceRecoveryStage = .idle
    private var deviceLossAwaitingSuccessfulFrame = false
    private var runtimeIsSettled: Bool
    private var runtimeWakeAfter: TimeInterval?
    private var visibleFrameRequested = true
    private var logicalAdvanceRequested = false
    private var runtimeWakeRequested = false
    private var runtimeWakeTask: Task<Void, Never>?
    private var offscreenTickTask: Task<Void, Never>?

    init(
        session: FlowRenderSession,
        surfaceView: FlowRuntimeSurfaceView,
        notificationCenter: NotificationCenter = .default,
        drawableGate: FlowRuntimeDrawableGate? = nil,
        usesSystemDisplayLink: Bool = true,
        resultProjector: @escaping @MainActor (
            FlowRuntimeOperationResult
        ) -> FlowRuntimeOperationResult = { $0 },
        onResult: @escaping @MainActor (
            _ original: FlowRuntimeOperationResult,
            _ projected: FlowRuntimeOperationResult,
            _ source: FlowRuntimeDisplayResultSource
        ) -> Void,
        onError: @escaping @MainActor (Error) -> Void = { _ in }
    ) {
        self.session = session
        self.surfaceView = surfaceView
        self.notificationCenter = notificationCenter
        self.drawableGate = drawableGate ?? FlowRuntimeDrawableGate(
            capacity: FlowRuntimeAppleSurfacePolicy.maximumDrawableCount
        )
        self.usesSystemDisplayLink = usesSystemDisplayLink
        self.resultProjector = resultProjector
        self.onResult = onResult
        self.onError = onError
        runtimeIsSettled = session.creationResult.isSettled
        runtimeWakeAfter = session.creationResult.wakeAfter
        super.init()
    }

    convenience init(
        session: FlowRenderSession,
        surfaceView: FlowRuntimeSurfaceView,
        notificationCenter: NotificationCenter = .default,
        drawableGate: FlowRuntimeDrawableGate? = nil,
        usesSystemDisplayLink: Bool = true,
        resultProjector: @escaping @MainActor (
            FlowRuntimeOperationResult
        ) -> FlowRuntimeOperationResult = { $0 },
        onResult: @escaping @MainActor (FlowRuntimeOperationResult) -> Void,
        onError: @escaping @MainActor (Error) -> Void = { _ in }
    ) {
        self.init(
            session: session,
            surfaceView: surfaceView,
            notificationCenter: notificationCenter,
            drawableGate: drawableGate,
            usesSystemDisplayLink: usesSystemDisplayLink,
            resultProjector: resultProjector,
            onResult: { _, projected, _ in onResult(projected) },
            onError: onError
        )
    }

    func start() async throws {
        if isShuttingDown {
            await waitForShutdownToFinish()
        }
        guard !isStarted else { return }
        if isStarting {
            await waitForStartToFinish()
            if isStarted { return }
            throw lastStartupError ?? CancellationError()
        }

        isStarting = true
        isShuttingDown = false
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        lastStartupError = nil
        terminalError = nil
        surfaceRecoveryStage = .idle
        deviceLossAwaitingSuccessfulFrame = false
        visibleFrameRequested = true
        runtimeWakeRequested = false
        applicationIsActive = UIApplication.shared.applicationState == .active

        defer {
            isStarting = false
            resumeStartWaiters()
        }

        guard let surfaceView else {
            let error = FlowRuntimeHostError.disposedSurface
            lastStartupError = error
            reportTerminalFailure(error)
            throw error
        }
        let target = surfaceTarget(for: surfaceView)
        let surface: FlowRenderSurface
        do {
            surface = try await session.attachAppleSurface(to: target)
        } catch {
            lastStartupError = error
            reportTerminalFailure(error)
            throw error
        }
        guard !isShuttingDown,
              lifecycleGeneration == generation else {
            surface.dispose()
            let error = CancellationError()
            lastStartupError = error
            throw error
        }
        self.surface = surface
        lastAppliedSize = target.size
        frameClock.reset()
        isStarted = true
        surfaceView.runtimeObserver = self
        installApplicationObservers()
        updateDisplayLinkForCurrentScreen()
        scheduleRuntimeWake(after: runtimeWakeAfter)
        reconcile()
    }

    func shutdown() async {
        if isShuttingDown {
            await waitForShutdownToFinish()
            return
        }
        guard isStarted || surface != nil || isStarting || pendingHostWorkCount > 0 else {
            return
        }
        isShuttingDown = true
        lifecycleGeneration &+= 1
        isStarted = false
        pendingTimestamp = nil
        pendingPointerInput.removeAll()
        cancelPendingHostWork()
        textRenderRequested = false
        pointerBatchDispatchedSinceLastFrame = false
        pointerInput.reset()
        frameClock.reset()
        surfaceRecoveryStage = .idle
        deviceLossAwaitingSuccessfulFrame = false
        visibleFrameRequested = true
        logicalAdvanceRequested = false
        runtimeWakeRequested = false
        cancelRuntimeWake()
        cancelOffscreenTick()
        invalidateDisplayLink()
        removeApplicationObservers()
        surfaceView?.runtimeObserver = nil

        if isStarting {
            await waitForStartToFinish()
        }
        await waitForOperationToFinish()
        if surface?.state == .attached {
            do {
                _ = try await surface?.detach()
            } catch {
                onError(error)
            }
        }
        surface?.dispose()
        surface = nil
        lastAppliedSize = nil
        isShuttingDown = false
        resumeShutdownWaiters()
    }

    /// The owning screen coordinator supplies navigation/cache visibility.
    /// This covers ancestor/controller visibility that a leaf UIView cannot
    /// observe reliably on its own.
    func setPresentationVisible(_ isVisible: Bool) {
        guard isPresentationVisible != isVisible else { return }
        isPresentationVisible = isVisible
        pendingTimestamp = nil
        frameClock.reset()
        cancelOffscreenTick()
        if isVisible { visibleFrameRequested = true }
        reconcile()
    }

    func runtimeSurfaceViewGeometryDidChange() {
        updateDisplayLinkForCurrentScreen()
        reconcile()
    }

    func runtimeSurfaceViewVisibilityDidChange() {
        updateDisplayLinkForCurrentScreen()
        if !shouldPresent {
            pendingTimestamp = nil
            frameClock.reset()
            cancelOffscreenTick()
        } else {
            visibleFrameRequested = true
            frameClock.reset()
        }
        reconcile()
    }

    func displayLinkDidFire(at timestamp: TimeInterval) {
        guard shouldPresent, surface?.state == .attached else {
            reconcile()
            return
        }
        guard hasVisibleFrameDemand else {
            reconcile()
            return
        }
        // Overwrite rather than queue: a stale animation tick has no value.
        pendingTimestamp = timestamp
        drain()
    }

    /// Explicit zero-time nudge used by navigation/layout work. Unlike a raw
    /// display-link tick, this wakes a settled session.
    func requestAdvance() {
        requestLogicalAdvance()
    }

    /// Queues one root-level named `TextValueRun` replacement on the same
    /// serialized lane as pointer input and rendering.
    ///
    /// Pending writes to the same byte-exact UTF-8 name coalesce to the newest
    /// text. Every completion retained by that entry receives the operation
    /// result associated with the newest text.
    func setText(
        _ text: String,
        forRunNamed name: String,
        completion: @escaping FlowRuntimeTextRunCompletion = { _ in }
    ) {
        if let terminalError {
            completion(.failure(terminalError))
            return
        }
        if isShuttingDown {
            completion(.failure(CancellationError()))
            return
        }
        guard reservePendingHostWork(for: completion) else { return }
        pendingTextRuns.enqueue(
            FlowRuntimeTextRunMutation(name: name, text: text),
            completion: completion
        )
        requestLogicalAdvance()
        drain()
    }

    /// Queues canonical state work without preparing it ahead of earlier
    /// in-flight runtime results. The closure executes only when this FIFO entry
    /// reaches the head of the serialized session lane.
    func performStateBatch(
        prepare: @escaping @MainActor () throws -> FlowRuntimeStateBatch,
        completion: @escaping FlowRuntimeOperationCompletion = { _ in }
    ) {
        if let terminalError {
            completion(.failure(terminalError))
            return
        }
        if isShuttingDown {
            completion(.failure(CancellationError()))
            return
        }
        guard reservePendingHostWork(for: completion) else { return }
        pendingStateBatches.enqueue(
            FlowRuntimePendingStateBatches.Entry(
                prepare: prepare,
                completion: completion
            )
        )
        requestLogicalAdvance()
        drain()
    }

    func runtimeSurfaceViewDidReceivePointerEvents(
        _ events: [FlowRuntimeViewPointerEvent]
    ) {
        guard isStarted,
              !isShuttingDown,
              terminalError == nil,
              let surfaceView,
              let transform = pointerTransform(for: surfaceView) else {
            return
        }
        var candidatePointerInput = pointerInput
        let runtimeEvents = candidatePointerInput.runtimeEvents(
            for: events,
            transform: transform
        )
        guard !runtimeEvents.isEmpty else { return }

        var candidatePendingPointerInput = pendingPointerInput
        do {
            try candidatePendingPointerInput.enqueue(runtimeEvents)
            pointerInput = candidatePointerInput
            pendingPointerInput = candidatePendingPointerInput
            requestLogicalAdvance()
        } catch {
            if flowRuntimeOperationFailureInvalidatesSession(error) {
                reportTerminalFailure(error)
            } else {
                // Both routers are value-semantic candidates. Rejecting this
                // sample therefore preserves already-admitted lifecycle input
                // while avoiding a mapping for a Down the runtime cannot see.
                // Saturated transient input is intentionally dropped without
                // invoking the terminal error sink.
            }
        }
        drain()
    }

    deinit {
        runtimeWakeTask?.cancel()
        offscreenTickTask?.cancel()
        displayLink?.invalidate()
        notificationTokens.forEach(notificationCenter.removeObserver)
    }

    private var shouldPresent: Bool {
        guard isStarted,
              !isShuttingDown,
              terminalError == nil,
              applicationIsActive,
              isPresentationVisible,
              let surfaceView,
              surfaceViewIsEffectivelyVisible(surfaceView),
              let window = surfaceView.window else {
            return false
        }
        if let scene = window.windowScene {
            return scene.activationState == .foregroundActive
        }
        return true
    }

    private var canAdvanceLogicalWork: Bool {
        guard isStarted,
              !isShuttingDown,
              terminalError == nil,
              applicationIsActive else {
            return false
        }
        if let scene = surfaceView?.window?.windowScene {
            return scene.activationState == .foregroundActive
        }
        return true
    }

    private var hasVisibleFrameDemand: Bool {
        visibleFrameRequested
            || logicalAdvanceRequested
            || runtimeWakeRequested
            || !runtimeIsSettled
            || textRenderRequested
            || !pendingPointerInput.isEmpty
            || pendingTimestamp != nil
    }

    private var shouldRunVisibleDisplayLink: Bool {
        shouldPresent
            && surface?.state == .attached
            && hasVisibleFrameDemand
    }

    private func updateDisplayLinkForCurrentScreen() {
        guard usesSystemDisplayLink else {
            invalidateDisplayLink()
            return
        }
        guard isStarted, let screen = surfaceView?.window?.screen else {
            invalidateDisplayLink()
            return
        }
        if displayLink != nil, displayLinkScreen === screen { return }
        invalidateDisplayLink()
        let proxy = FlowRuntimeDisplayLinkProxy(host: self)
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
                    self?.applicationDidBecomeInactive()
                }
            },
            notificationCenter.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.applicationDidBecomeActive()
                }
            },
            notificationCenter.addObserver(
                forName: UIApplication.didReceiveMemoryWarningNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.applicationDidReceiveMemoryWarning()
                }
            },
            notificationCenter.addObserver(
                forName: UIScene.willDeactivateNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                Task { @MainActor [weak self] in
                    self?.sceneLifecycleDidChange(notification)
                }
            },
            notificationCenter.addObserver(
                forName: UIScene.didActivateNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                Task { @MainActor [weak self] in
                    self?.sceneLifecycleDidChange(notification)
                }
            },
        ]
    }

    private func removeApplicationObservers() {
        notificationTokens.forEach(notificationCenter.removeObserver)
        notificationTokens.removeAll()
    }

    private func applicationDidBecomeInactive() {
        applicationIsActive = false
        pendingTimestamp = nil
        runtimeWakeRequested = false
        frameClock.reset()
        cancelRuntimeWake(clearDeadline: true)
        cancelOffscreenTick()
        reconcile()
    }

    private func applicationDidBecomeActive() {
        applicationIsActive = true
        frameClock.reset()
        visibleFrameRequested = true
        logicalAdvanceRequested = true
        reconcile()
    }

    private func applicationDidReceiveMemoryWarning() {
        guard applicationIsActive,
              isStarted,
              !isShuttingDown,
              terminalError == nil,
              surfaceRecoveryStage == .idle,
              let surface else {
            return
        }
        pendingTimestamp = nil
        frameClock.reset()
        switch surface.state {
        case .attached:
            surfaceRecoveryStage = .detachRequired
        case .detached:
            // A hidden surface remains detached. Its eventual reattach will
            // refresh the native device and be followed by one zero-time draw.
            surfaceRecoveryStage = .reattachRequired
        case .disposed:
            reportTerminalFailure(FlowRuntimeHostError.disposedSurface)
            return
        }
        reconcile()
    }

    private func sceneLifecycleDidChange(_ notification: Notification) {
        guard let scene = notification.object as? UIWindowScene,
              scene === surfaceView?.window?.windowScene else {
            return
        }
        pendingTimestamp = nil
        frameClock.reset()
        if canAdvanceLogicalWork {
            visibleFrameRequested = true
            logicalAdvanceRequested = true
        } else {
            runtimeWakeRequested = false
            cancelRuntimeWake(clearDeadline: true)
            cancelOffscreenTick()
        }
        reconcile()
    }

    private func reconcile() {
        guard isStarted, !isShuttingDown else {
            displayLink?.isPaused = true
            cancelOffscreenTick()
            return
        }
        updateDisplayLinkForCurrentScreen()
        if !shouldPresent {
            pendingTimestamp = nil
            if !canAdvanceLogicalWork {
                frameClock.reset()
                cancelOffscreenTick()
            }
        }
        displayLink?.isPaused = !shouldRunVisibleDisplayLink
        drain()
    }

    private func drain() {
        guard !operationInFlight,
              !isShuttingDown,
              terminalError == nil else {
            return
        }
        guard surfaceView != nil else {
            reportTerminalFailure(FlowRuntimeHostError.disposedSurface)
            resumeIdleWaiters()
            return
        }
        let operationSurface = surface
        guard let operation = nextOperation(for: operationSurface) else {
            displayLink?.isPaused = !shouldRunVisibleDisplayLink
            updateOffscreenTickScheduling()
            return
        }

        cancelOffscreenTick()
        operationInFlight = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.perform(operation, on: operationSurface)
            } catch {
                if !self.handleRecoverableOperationFailure(error) {
                    self.reportTerminalFailure(error)
                }
            }
            self.operationInFlight = false
            self.resumeIdleWaiters()
            if !self.isShuttingDown {
                self.drain()
            }
        }
    }

    private func nextOperation(for surface: FlowRenderSurface?) -> PendingOperation? {
        if surfaceRecoveryStage == .detachRequired {
            guard let surface else { return nil }
            switch surface.state {
            case .attached:
                return .recoveryDetach
            case .detached:
                surfaceRecoveryStage = .reattachRequired
            case .disposed:
                return nil
            }
        }
        if deviceLossAwaitingSuccessfulFrame,
           let surface,
           let surfaceView {
            // Device loss invalidates the session's presentation factory, not
            // just the visible layer. Rebuild it even if the screen became
            // hidden while the failed drawable was draining so offscreen state
            // and host work do not remain blocked until a later presentation.
            // The ordinary hidden-state branch below detaches the recovered
            // surface again immediately after the zero-time retry.
            let target = surfaceTarget(for: surfaceView)
            if surfaceRecoveryStage == .reattachRequired,
               surface.state == .attached {
                surfaceRecoveryStage = .redrawRequired
            }
            if surfaceRecoveryStage == .reattachRequired,
               surface.state == .detached {
                return .recoveryReattach(target)
            }
            if surface.state == .attached, target.size != lastAppliedSize {
                return .resize(target.size)
            }
            if surfaceRecoveryStage == .redrawRequired,
               surface.state == .attached {
                return .recoveryRedraw(
                    frameClock.zeroDeltaFrame(at: CACurrentMediaTime())
                )
            }
        }
        if !shouldPresent {
            if surface?.state == .attached {
                return .detach
            }
            guard isStarted, surface?.state == .detached else { return nil }
            guard !deviceLossAwaitingSuccessfulFrame else { return nil }
            guard canAdvanceLogicalWork else { return nil }
            if let stateBatch = pendingStateBatches.takeFirst() {
                return .stateBatch(stateBatch)
            }
            if let textRun = pendingTextRuns.takeFirst() {
                return .textRun(textRun)
            }
            if pendingTextRuns.isEmpty, textRenderRequested {
                textRenderRequested = false
                logicalAdvanceRequested = false
                runtimeWakeRequested = false
                return .offscreenAdvance(
                    frameClock.zeroDeltaFrame(at: CACurrentMediaTime())
                )
            }
            if let events = pendingPointerInput.takeBatch() {
                return .pointerBatch(events)
            }
            if logicalAdvanceRequested {
                logicalAdvanceRequested = false
                runtimeWakeRequested = false
                return .offscreenAdvance(
                    frameClock.zeroDeltaFrame(at: CACurrentMediaTime())
                )
            }
            if runtimeWakeRequested {
                runtimeWakeRequested = false
                return .offscreenAdvance(
                    frameClock.frame(at: CACurrentMediaTime())
                )
            }
            return nil
        }
        guard let surface, let surfaceView else { return nil }
        let target = surfaceTarget(for: surfaceView)
        if surfaceRecoveryStage == .reattachRequired,
           surface.state == .attached {
            // A warning can arrive while an ordinary visibility reattach is
            // already in flight. That reattach satisfies the requested device
            // refresh; retain only the required zero-time redraw.
            surfaceRecoveryStage = .redrawRequired
        }
        if surfaceRecoveryStage == .reattachRequired,
           surface.state == .detached {
            return .recoveryReattach(target)
        }
        if surface.state == .detached {
            return .reattach(target)
        }
        if surface.state == .attached, target.size != lastAppliedSize {
            return .resize(target.size)
        }
        if surfaceRecoveryStage == .redrawRequired,
           surface.state == .attached {
            return .recoveryRedraw(
                frameClock.zeroDeltaFrame(at: CACurrentMediaTime())
            )
        }
        if surface.state == .attached,
           let stateBatch = pendingStateBatches.takeFirst() {
            return .stateBatch(stateBatch)
        }
        if surface.state == .attached,
           let textRun = pendingTextRuns.takeFirst() {
            return .textRun(textRun)
        }
        if surface.state == .attached,
           pendingTextRuns.isEmpty,
           textRenderRequested {
            textRenderRequested = false
            logicalAdvanceRequested = false
            runtimeWakeRequested = false
            visibleFrameRequested = false
            let timestamp = pendingTimestamp ?? CACurrentMediaTime()
            pendingTimestamp = nil
            pointerBatchDispatchedSinceLastFrame = false
            return .textRender(frameClock.zeroDeltaFrame(at: timestamp))
        }
        if surface.state == .attached,
           pendingTimestamp != nil,
           pointerBatchDispatchedSinceLastFrame {
            guard let timestamp = pendingTimestamp else { return nil }
            pendingTimestamp = nil
            pointerBatchDispatchedSinceLastFrame = false
            return .frame(takeVisibleFrame(at: timestamp))
        }
        if surface.state == .attached,
           let events = pendingPointerInput.takeBatch() {
            pointerBatchDispatchedSinceLastFrame = true
            return .pointerBatch(events)
        }
        if surface.state == .attached, let timestamp = pendingTimestamp {
            pendingTimestamp = nil
            pointerBatchDispatchedSinceLastFrame = false
            return .frame(takeVisibleFrame(at: timestamp))
        }
        return nil
    }

    private func takeVisibleFrame(
        at timestamp: TimeInterval
    ) -> FlowRuntimeFrameTime {
        visibleFrameRequested = false
        logicalAdvanceRequested = false
        runtimeWakeRequested = false
        return frameClock.frame(at: timestamp)
    }

    private func requestLogicalAdvance() {
        if runtimeIsSettled {
            // An explicit mutation wakes a paused session without consuming the
            // wall time it spent settled.
            frameClock.reset()
        }
        logicalAdvanceRequested = true
        runtimeWakeRequested = false
        cancelRuntimeWake(clearDeadline: true)
        reconcile()
    }

    private func acceptRuntimeSchedule(
        from result: FlowRuntimeOperationResult,
        requestsVisibleRender: Bool
    ) {
        runtimeIsSettled = result.isSettled
        runtimeWakeRequested = false
        if requestsVisibleRender {
            // Offscreen logical advancement may consume the mutation wake, but
            // its pixels remain dirty until the screen is visible again.
            visibleFrameRequested = true
        }
        if result.isSettled,
           !logicalAdvanceRequested,
           !runtimeWakeRequested {
            // Drop a display tick coalesced while the settling operation was in
            // flight. New input or an explicit redraw will request a fresh one.
            pendingTimestamp = nil
        }
        scheduleRuntimeWake(after: result.wakeAfter)
        if result.isSettled {
            cancelOffscreenTick()
        }
    }

    private func scheduleRuntimeWake(after delay: TimeInterval?) {
        cancelRuntimeWake(clearDeadline: false)
        runtimeWakeAfter = delay
        guard isStarted,
              !isShuttingDown,
              terminalError == nil,
              canAdvanceLogicalWork,
              let delay,
              delay.isFinite,
              delay >= 0 else {
            return
        }

        let task = Task<Void, Never> { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(
                    nanoseconds: Self.nanoseconds(for: delay)
                )
            } else {
                await Task.yield()
            }
            guard !Task.isCancelled,
                  let self,
                  self.isStarted,
                  !self.isShuttingDown,
                  self.terminalError == nil else {
                return
            }
            self.runtimeWakeTask = nil
            self.runtimeWakeAfter = nil
            self.runtimeWakeRequested = true
            self.reconcile()
        }
        runtimeWakeTask = task
    }

    private func cancelRuntimeWake(clearDeadline: Bool = false) {
        runtimeWakeTask?.cancel()
        runtimeWakeTask = nil
        if clearDeadline { runtimeWakeAfter = nil }
    }

    private func updateOffscreenTickScheduling() {
        guard canAdvanceLogicalWork,
              !shouldPresent,
              surface?.state == .detached,
              !runtimeIsSettled,
              !logicalAdvanceRequested,
              !runtimeWakeRequested else {
            cancelOffscreenTick()
            return
        }
        guard offscreenTickTask == nil else { return }

        offscreenTickTask = Task<Void, Never> { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 16_666_667)
            guard !Task.isCancelled,
                  let self,
                  self.canAdvanceLogicalWork,
                  !self.shouldPresent,
                  self.surface?.state == .detached,
                  !self.runtimeIsSettled else {
                return
            }
            self.offscreenTickTask = nil
            self.runtimeWakeRequested = true
            self.drain()
        }
    }

    private func cancelOffscreenTick() {
        offscreenTickTask?.cancel()
        offscreenTickTask = nil
    }

    private static func nanoseconds(for delay: TimeInterval) -> UInt64 {
        let maximumDelay = Double(UInt64.max) / 1_000_000_000
        return UInt64(min(delay, maximumDelay) * 1_000_000_000)
    }

    private func perform(
        _ operation: PendingOperation,
        on surface: FlowRenderSurface?
    ) async throws {
        switch operation {
        case .detach:
            guard let surface else { throw FlowRuntimeHostError.disposedSurface }
            _ = try await surface.detach()
            lastAppliedSize = nil
            frameClock.reset()
        case .reattach(let target):
            guard let surface else { throw FlowRuntimeHostError.disposedSurface }
            _ = try await surface.reattach(to: target)
            lastAppliedSize = target.size
            frameClock.reset()
            visibleFrameRequested = true
        case .recoveryDetach:
            guard let surface else { throw FlowRuntimeHostError.disposedSurface }
            _ = try await surface.detach()
            lastAppliedSize = nil
            frameClock.reset()
            surfaceRecoveryStage = .reattachRequired
        case .recoveryReattach(let target):
            guard let surface else { throw FlowRuntimeHostError.disposedSurface }
            _ = try await surface.reattach(to: target)
            lastAppliedSize = target.size
            frameClock.reset()
            surfaceRecoveryStage = .redrawRequired
        case .recoveryRedraw(let frameTime):
            guard let surface else { throw FlowRuntimeHostError.disposedSurface }
            surfaceRecoveryStage = .awaitingRedraw
            // Hidden device-loss recovery rebuilds logical presentation state
            // without asking CAMetalLayer for a drawable. Once the retry has
            // succeeded, the normal visibility lane detaches the surface again.
            let acquiredDrawable = shouldPresent
                ? acquireDrawable(for: surface)
                : nil
            let result = try await session.perform(
                .advanceAndRender(frameTime),
                drawable: acquiredDrawable
            )
            acceptRuntimeSchedule(from: result, requestsVisibleRender: false)
            let projectedResult = resultProjector(result)
            onResult(result, projectedResult, .frame)
            surfaceRecoveryStage = .idle
            deviceLossAwaitingSuccessfulFrame = false
            if shouldPresent { visibleFrameRequested = false }
        case .resize(let size):
            guard let surface else { throw FlowRuntimeHostError.disposedSurface }
            _ = try await surface.resize(to: size)
            lastAppliedSize = size
            visibleFrameRequested = true
        case .stateBatch(let entry):
            let batch: FlowRuntimeStateBatch
            do {
                batch = try entry.prepare()
            } catch {
                entry.completion(.failure(error))
                if flowRuntimeOperationFailureInvalidatesSession(error) {
                    throw error
                }
                return
            }
            do {
                let result = try await session.perform(.stateBatch(batch))
                acceptRuntimeSchedule(
                    from: result,
                    requestsVisibleRender: result.isDirty
                )
                let projectedResult = resultProjector(result)
                onResult(result, projectedResult, .stateBatch)
                entry.completion(.success(projectedResult))
            } catch {
                entry.completion(.failure(error))
                if flowRuntimeOperationFailureInvalidatesSession(error) {
                    throw error
                }
            }
        case .textRun(let entry):
            do {
                let result = try await session.perform(
                    .textRunBatch(FlowRuntimeTextRunBatch(mutations: [entry.mutation]))
                )
                acceptRuntimeSchedule(
                    from: result,
                    requestsVisibleRender: result.isDirty
                )
                let projectedResult = resultProjector(result)
                onResult(result, projectedResult, .textRun)
                entry.completions.forEach { $0(.success(projectedResult)) }
                textRenderRequested = true
            } catch {
                entry.completions.forEach { $0(.failure(error)) }
                if flowRuntimeOperationFailureInvalidatesSession(error) {
                    throw error
                }
            }
        case .textRender(let frameTime):
            guard let surface else { throw FlowRuntimeHostError.disposedSurface }
            let acquiredDrawable = acquireDrawable(for: surface)
            let result = try await session.perform(
                .advanceAndRender(frameTime),
                drawable: acquiredDrawable
            )
            acceptRuntimeSchedule(from: result, requestsVisibleRender: false)
            let projectedResult = resultProjector(result)
            onResult(result, projectedResult, .textRender)
        case .pointerBatch(let events):
            let result = try await session.perform(.pointerBatch(events))
            acceptRuntimeSchedule(
                from: result,
                requestsVisibleRender: result.isDirty
            )
            let projectedResult = resultProjector(result)
            onResult(result, projectedResult, .pointerBatch)
        case .offscreenAdvance(let frameTime):
            let result = try await session.perform(.advance(frameTime))
            acceptRuntimeSchedule(from: result, requestsVisibleRender: result.isDirty)
            let projectedResult = resultProjector(result)
            onResult(result, projectedResult, .frame)
        case .frame(let frameTime):
            guard let surface else { throw FlowRuntimeHostError.disposedSurface }
            let acquiredDrawable = acquireDrawable(for: surface)
            let result = try await session.perform(
                .advanceAndRender(frameTime),
                drawable: acquiredDrawable
            )
            acceptRuntimeSchedule(from: result, requestsVisibleRender: false)
            let projectedResult = resultProjector(result)
            onResult(result, projectedResult, .frame)
        }
    }

    private func acquireDrawable(
        for surface: FlowRenderSurface
    ) -> FlowRuntimeAppleDrawableTarget? {
        guard let lastAppliedSize,
              lastAppliedSize.pixelWidth > 0,
              lastAppliedSize.pixelHeight > 0,
              let surfaceView,
              let permit = drawableGate.tryAcquire() else {
            return nil
        }
        guard let drawable = surfaceView.metalLayer.nextDrawable() else {
            permit.release()
            return nil
        }
        return surface.makeDrawableTarget(drawable) {
            permit.release()
        }
    }

    private func surfaceTarget(
        for view: FlowRuntimeSurfaceView
    ) -> FlowRuntimeAppleSurfaceTarget {
        let scale = view.window?.screen.scale ?? view.contentScaleFactor
        view.metalLayer.contentsScale = scale
        return FlowRuntimeAppleSurfaceTarget(
            layer: view.metalLayer,
            size: FlowRuntimeSurfaceSizing.pixels(
                width: view.bounds.width,
                height: view.bounds.height,
                scale: scale
            )
        )
    }

    private func pointerTransform(
        for view: FlowRuntimeSurfaceView
    ) -> FlowContainCenterTransform? {
        let bounds = session.bootstrap.player.bounds
        return FlowContainCenterTransform(
            artboardBounds: CGRect(
                x: bounds.minX,
                y: bounds.minY,
                width: bounds.width,
                height: bounds.height
            ),
            viewportBounds: view.bounds
        )
    }

    private func reportTerminalFailure(_ error: Error) {
        guard terminalError == nil else { return }
        terminalError = error
        pendingTimestamp = nil
        pendingPointerInput.removeAll()
        let pendingState = pendingStateBatches.removeAll()
        let pendingText = pendingTextRuns.removeAll()
        textRenderRequested = false
        pointerInput.reset()
        logicalAdvanceRequested = false
        runtimeWakeRequested = false
        cancelRuntimeWake(clearDeadline: true)
        cancelOffscreenTick()
        displayLink?.isPaused = true
        // Let the owning screen invalidate its request state before queued,
        // not-yet-prepared completions run. A completion may otherwise try to
        // drain the next request back into this already-terminal host and
        // recurse synchronously through the entire bounded queue.
        onError(error)
        pendingState.forEach { $0.completion(.failure(error)) }
        pendingText.flatMap(\.completions).forEach { $0(.failure(error)) }
    }

    /// Device loss is the only native operation failure that can preserve the
    /// logical session. Native guarantees that this result did not commit the
    /// authored advance or outputs, so Swift can rebuild only this surface and
    /// retry presentation at zero elapsed time. A second loss before that
    /// recovery frame succeeds is bounded and terminal.
    private func handleRecoverableOperationFailure(_ error: Error) -> Bool {
        guard let hostError = error as? FlowRuntimeHostError,
              case .recoverableSurface(.deviceLost) = hostError else {
            return false
        }
        guard !deviceLossAwaitingSuccessfulFrame else {
            reportTerminalFailure(
                FlowRuntimeHostError.unrecoverableSurface(.deviceLost)
            )
            return true
        }
        guard let surface else {
            reportTerminalFailure(FlowRuntimeHostError.disposedSurface)
            return true
        }

        deviceLossAwaitingSuccessfulFrame = true
        pendingTimestamp = nil
        frameClock.reset()
        switch surface.state {
        case .attached:
            surfaceRecoveryStage = .detachRequired
        case .detached:
            surfaceRecoveryStage = .reattachRequired
        case .disposed:
            reportTerminalFailure(FlowRuntimeHostError.disposedSurface)
        }
        return true
    }

    private func cancelPendingHostWork() {
        let pendingState = pendingStateBatches.removeAll()
        pendingState.forEach { $0.completion(.failure(CancellationError())) }
        let pendingText = pendingTextRuns.removeAll()
        pendingText.flatMap(\.completions).forEach {
            $0(.failure(CancellationError()))
        }
    }

    private var pendingHostWorkCount: Int {
        pendingStateBatches.count + pendingTextRuns.completionCount
    }

    private func reservePendingHostWork(
        for completion: FlowRuntimeOperationCompletion
    ) -> Bool {
        guard pendingHostWorkCount < FlowRuntimeSessionLimits.batchItems else {
            completion(.failure(FlowRuntimeDisplayHostError.pendingHostWorkOverflow(
                limit: FlowRuntimeSessionLimits.batchItems
            )))
            return false
        }
        return true
    }

    private func waitForOperationToFinish() async {
        guard operationInFlight else { return }
        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }

    private func waitForStartToFinish() async {
        guard isStarting else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    private func waitForShutdownToFinish() async {
        guard isShuttingDown else { return }
        await withCheckedContinuation { continuation in
            shutdownWaiters.append(continuation)
        }
    }

    private func resumeIdleWaiters() {
        let waiters = idleWaiters
        idleWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func resumeStartWaiters() {
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func resumeShutdownWaiters() {
        let waiters = shutdownWaiters
        shutdownWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func surfaceViewIsEffectivelyVisible(
        _ view: FlowRuntimeSurfaceView
    ) -> Bool {
        guard let window = view.window,
              !window.isHidden,
              window.alpha > 0,
              !view.isHidden,
              view.alpha > 0 else {
            return false
        }
        var ancestor = view.superview
        while let current = ancestor {
            if current.isHidden || current.alpha <= 0 {
                return false
            }
            ancestor = current.superview
        }
        return true
    }
}

extension FlowRuntimeDisplayHost: FlowRuntimeSurfaceViewObserver {}

@MainActor
private final class FlowRuntimeDisplayLinkProxy: NSObject {
    weak var host: FlowRuntimeDisplayHost?

    init(host: FlowRuntimeDisplayHost) {
        self.host = host
    }

    @objc func tick(_ displayLink: CADisplayLink) {
        host?.displayLinkDidFire(at: displayLink.timestamp)
    }
}
#endif
