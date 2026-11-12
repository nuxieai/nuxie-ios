#if canImport(UIKit) && canImport(QuartzCore)
import Foundation
import Metal
import NuxieRuntime
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
}

struct ExperienceRuntimePresentationStep: Equatable, Sendable {
    let elapsedSeconds: Float
    let pointers: [ExperienceInteractivePointerEvent]
    let focusInputs: [NuxieNativeFocusInput]
    let requestsRender: Bool

    init(
        elapsedSeconds: Float,
        pointers: [ExperienceInteractivePointerEvent],
        focusInputs: [NuxieNativeFocusInput] = [],
        requestsRender: Bool = true
    ) {
        self.elapsedSeconds = elapsedSeconds
        self.pointers = pointers
        self.focusInputs = focusInputs
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

    mutating func takeNativeTap(at point: CGPoint) -> [ExperienceInteractivePointerEvent] {
        // Already queued native editing owns this reserved two-event slot.
        // Later scene pointers stay queued until their ordinary frame.
        events.insert(contentsOf: [
            .init(kind: .down, x: Float(point.x), y: Float(point.y), pointerID: 0),
            .init(kind: .up, x: Float(point.x), y: Float(point.y), pointerID: 0),
        ], at: 0)
        return takeBatch(maximumCount: 2)
    }

    mutating func takeBatch(maximumCount: Int = ExperienceRuntimePointerInputRouter.maximumActivePointers) -> [ExperienceInteractivePointerEvent] {
        let count = min(events.count, maximumCount)
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
    private var presentedWork: (@Sendable () -> Void)?
    private var hasRegisteredPresentedWork = false
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
        deliverReadyWork()
    }

    func recordRenderOutcome(_ outcome: ExperienceRuntimePresentationRenderOutcome) {
        deliverPresentedDrawable(lock.withLock {
            renderOutcome = outcome
            return takePresentedDrawableIfReady()
        })
        deliverReadyWork()
    }

    func signalDrawablePresented(
        at time: TimeInterval,
        provenance: ExperienceRuntimePresentedDrawable.Provenance
    ) {
        deliverPresentedDrawable(lock.withLock {
            presentationObservation = (time, provenance)
            return takePresentedDrawableIfReady()
        })
        deliverReadyWork()
    }

    /// Registration may race the render result and presentation observation.
    /// Delivery consumes the callback once, outside the native-completion lock.
    func recordPresentedWork(_ work: @escaping @Sendable () -> Void) {
        lock.withLock {
            guard !hasRegisteredPresentedWork else { return }
            hasRegisteredPresentedWork = true
            presentedWork = work
        }
        deliverReadyWork()
    }

    private func deliverReadyWork() {
        let work: (@Sendable () -> Void)? = lock.withLock {
            guard let outcome = renderOutcome else { return nil }
            guard outcome.health == .healthy, outcome.disposition == .presented else {
                presentedWork = nil
                return nil
            }
            guard presentationObservation != nil else { return nil }
            defer { presentedWork = nil }
            return presentedWork
        }
        work?()
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
    /// A page step begins when this work lands: the frame clock counts from
    /// that moment, so no frame of the step carries time from before it.
    let startsStepClock: Bool

    init(startsStepClock: Bool = false, perform: @escaping Perform) {
        self.startsStepClock = startsStepClock
        self.perform = perform
    }
}

enum ExperienceRuntimePresentationSessionOperation: @unchecked Sendable {
    case copyMetalDevice
    case setMediaVisible(Bool)
    case step(ExperienceRuntimePresentationStep)
    case resize(ExperienceRuntimeSurfaceSize)
    /// The session accepts ownership of `completion` and must consume it on
    /// every success or failure path. Presentation never guesses whether a
    /// render reached native code and therefore never synthesizes completion.
    case render(
        ExperienceRuntimePresentationDrawableState,
        layoutScaleFactor: Float,
        completion: ExperienceRuntimePresentationFrameCompletion
    )
    case queued(ExperienceRuntimePresentationQueuedWork)
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
    /// A step left media that wants frames, such as a playing video.
    let mediaActive: Bool
    private let deliverOnMainActor: (@MainActor @Sendable () async -> Void)?

    private init(
        _ value: Value,
        mediaActive: Bool = false,
        deliverOnMainActor: (@MainActor @Sendable () async -> Void)? = nil
    ) {
        self.value = value
        self.mediaActive = mediaActive
        self.deliverOnMainActor = deliverOnMainActor
    }

    static let none = Self(.none)

    static func metalDevice(_ device: any MTLDevice) -> Self {
        Self(.metalDevice(device))
    }

    static func session(
        mediaActive: Bool = false,
        deliverOnMainActor: (@MainActor @Sendable () async -> Void)? = nil
    ) -> Self {
        Self(.session, mediaActive: mediaActive, deliverOnMainActor: deliverOnMainActor)
    }

    static func work(
        requestsFrame: Bool,
        deliverOnMainActor: (@MainActor @Sendable () async -> Void)? = nil
    ) -> Self {
        Self(.work(requestsFrame: requestsFrame), deliverOnMainActor: deliverOnMainActor)
    }

    static func renderer(_ outcome: ExperienceRuntimePresentationRenderOutcome,
        deliverOnMainActor: (@MainActor @Sendable () async -> Void)? = nil) -> Self {
        Self(.renderer(outcome), deliverOnMainActor: deliverOnMainActor)
    }

    var hasDelivery: Bool { deliverOnMainActor != nil }

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

    let artboardBounds: @Sendable () -> CGRect
    let observesEveryPresentation: Bool
    private let performOperation: Perform

    init(
        artboardBounds: @escaping @Sendable () -> CGRect = { .zero },
        observesEveryPresentation: Bool = false,
        perform: @escaping Perform
    ) {
        self.artboardBounds = artboardBounds
        self.observesEveryPresentation = observesEveryPresentation
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
        onSemantics: (@MainActor @Sendable (NuxieNativeSemanticCapture) -> Void)? = nil,
        onTextFrame: (@MainActor @Sendable (ExperienceInteractiveTextFrame) -> Void)? = nil,
        onCaptions: (@MainActor @Sendable ([ExperienceInteractiveVideoCaption]) -> Void)? = nil,
        onFocus: (@MainActor @Sendable (NuxieNativeFocusState) -> Void)? = nil,
        onStep: @escaping @MainActor @Sendable ([ExperienceInteractiveEffect]) async -> Void
    ) -> ExperienceRuntimePresentationSession {
        let screen = self
        return ExperienceRuntimePresentationSession(artboardBounds: { screen.artboardBounds },
            observesEveryPresentation: onSemantics != nil || onTextFrame != nil || onCaptions != nil) { operation in
            switch operation {
            case .copyMetalDevice:
                if onSemantics != nil { try await screen.enableSemantics() }
                return .metalDevice(try await screen.metalDevice().value)
            case .setMediaVisible(let visible):
                try await screen.setMediaVisible(visible)
                return .none
            case .step(let step):
                let result = try await screen.step(
                    pointers: step.pointers,
                    focusInputs: step.focusInputs,
                    elapsedSeconds: step.elapsedSeconds,
                    capturesTextLayout: onTextFrame != nil
                )
                return .session {
                    if let state = result.focusState { onFocus?(state) }
                    await onStep(result.effects)
                }
            case .resize(let size):
                return .renderer(Self.presentationOutcome(try await screen.resize(
                    pixelWidth: size.pixelWidth,
                    pixelHeight: size.pixelHeight,
                    layoutScaleFactor: size.layoutScaleFactor
                )))
            case .render(let drawableState, let layoutScaleFactor, let completion):
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
                let frame = try await screen.renderFrame(
                    layoutScaleFactor: layoutScaleFactor,
                    drawable: drawable,
                    isOccluded: isOccluded,
                    capturesSemantics: onSemantics != nil,
                    capturesCaptions: onCaptions != nil,
                    completion: { completion.signalFromNative() }
                )
                if frame.semantics != nil || frame.text != nil || frame.captions != nil {
                    return .renderer(Self.presentationOutcome(frame.outcome)) {
                        // Install this frame's editor geometry before semantic
                        // admission enables fields and drains their initial writes.
                        if let text = frame.text { onTextFrame?(text) }
                        if let semantics = frame.semantics { onSemantics?(semantics) }
                        if let captions = frame.captions { onCaptions?(captions) }
                    }
                }
                return .renderer(Self.presentationOutcome(frame.outcome))
            case .queued(let work):
                return try await work.perform()
            case .close:
                try await screen.close()
                return .none
            }
        }
    }

    nonisolated static func presentationOutcome(
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

extension ExperienceInteractivePage {
    nonisolated func presentationSession(
        onSemantics: (@MainActor @Sendable (NuxieNativeSemanticCapture) -> Void)?,
        onTextFrame: (@MainActor @Sendable (ExperienceInteractiveTextFrame) -> Void)?,
        onCaptions: (@MainActor @Sendable ([ExperienceInteractiveVideoCaption]) -> Void)?,
        onFocus: @escaping @MainActor @Sendable (NuxieNativeFocusState) -> Void,
        onStep: @escaping @MainActor @Sendable (Step) async -> Void
    ) -> ExperienceRuntimePresentationSession {
        ExperienceRuntimePresentationSession(artboardBounds: { self.artboardBounds },
            observesEveryPresentation: onSemantics != nil || onTextFrame != nil || onCaptions != nil) { operation in
            switch operation {
            case .step(let step):
                let result = try await self.step(pointers: step.pointers.map(ExperienceInteractiveScreen.nativePointer),
                    focusInputs: step.focusInputs, elapsedSeconds: step.elapsedSeconds,
                    capturesTextLayout: onTextFrame != nil)
                return .session(mediaActive: result.videoActive) {
                    if let state = result.native.focusState { onFocus(state) }
                    await onStep(result)
                }
            case .close:
                try await self.close()
                return .none
            case .copyMetalDevice:
                return .metalDevice(try await self.metalDevice(enablesSemantics: onSemantics != nil).value)
            case .setMediaVisible(let visible):
                try await self.setMediaVisible(visible)
                return .none
            case .resize(let size):
                return .renderer(ExperienceInteractiveScreen.presentationOutcome(try await self.resize(
                    pixelWidth: size.pixelWidth, pixelHeight: size.pixelHeight, layoutScaleFactor: size.layoutScaleFactor)))
            case .render(let drawableState, let layoutScaleFactor, let completion):
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
                let frame = try await self.renderFrame(
                    layoutScaleFactor: layoutScaleFactor,
                    drawable: drawable,
                    isOccluded: isOccluded,
                    capturesSemantics: onSemantics != nil,
                    capturesCaptions: onCaptions != nil,
                    completion: { completion.signalFromNative() }
                )
                if frame.semantics != nil || frame.text != nil || frame.captions != nil {
                    return .renderer(ExperienceInteractiveScreen.presentationOutcome(frame.outcome)) {
                        // Install this frame's editor geometry before semantic
                        // admission enables fields and drains their initial writes.
                        if let text = frame.text { onTextFrame?(text) }
                        if let semantics = frame.semantics { onSemantics?(semantics) }
                        if let captions = frame.captions { onCaptions?(captions) }
                    }
                }
                return .renderer(ExperienceInteractiveScreen.presentationOutcome(frame.outcome))
            case .queued(let work):
                return try await work.perform()
            }
        }
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
/// in flight, and session close waits for every native frame completion.
@MainActor
final class ExperienceRuntimePresentationLoop: NSObject {
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
    private var pendingFocus = ExperienceFocusInputQueue()
    private var inputEnabled = true

    // Track submitted touches, including the operation currently in flight.
    // Queued downs that never reached the player need no synthetic exit.
    private var submittedPointers: [Int32: ExperienceInteractivePointerEvent] = [:]
    private var pendingInputEnd: ExperienceRuntimePresentationStep?

    func endActiveInput() {
        let exits = submittedPointers.values.sorted { $0.pointerID < $1.pointerID }.map {
            ExperienceInteractivePointerEvent(kind: .exit, x: $0.x, y: $0.y,
                pointerID: $0.pointerID, timestamp: $0.timestamp)
        }
        // Withdrawing keyboard ownership is silent. A synthetic key-up would
        // run authored handlers after editing, hiding, or discarding the press.
        if !exits.isEmpty {
            pendingInputEnd = .init(elapsedSeconds: 0,
                pointers: (pendingInputEnd?.pointers ?? []) + exits,
                focusInputs: [], requestsRender: false)
        }
        submittedPointers.removeAll()
        pendingPointers.removeAll()
        pendingFocus.removeAll()
        pointerInput.reset()
        semanticPresentationEpoch &+= 1
        reconcile()
    }

    private func recordSubmittedInput(_ step: ExperienceRuntimePresentationStep) {
        for pointer in step.pointers {
            switch pointer.kind {
            case .down, .move: submittedPointers[pointer.pointerID] = pointer
            case .up, .exit: submittedPointers.removeValue(forKey: pointer.pointerID)
            }
        }
    }

    func setInputEnabled(_ enabled: Bool) {
        guard inputEnabled != enabled else { return }
        inputEnabled = enabled
        semanticPresentationEpoch &+= 1
        if !enabled { endActiveInput() }
    }
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
    /// The pending zero-delta request is a page step's first frame: when it
    /// presents, it advances to its own time instead of holding at zero.
    private var pendingFrameAdvancesToNow = false
    /// The display link's time base, injectable so tests own the clock.
    private let now: @MainActor () -> TimeInterval
    /// The latest display tick's target: when its picture is due on screen.
    private var lastDisplayTime: TimeInterval?
    /// The display's refresh interval, once a tick has reported it.
    private var displayInterval: TimeInterval?
    /// When the latest presented picture is shown: the one place that fact
    /// lives. Only a render whose outcome is presented sets it.
    private var lastPictureTime: TimeInterval?
    /// The display time the next render's picture was evaluated at.
    private var pendingPictureTime: TimeInterval?
    /// The display time of the render in flight. It takes its refresh only
    /// if the render presents; a skipped render takes none.
    private var renderPictureTime: TimeInterval?
    private var zeroDeltaRequestGeneration: UInt64 = 0
    private var zeroDeltaStepGeneration: UInt64?
    private var zeroDeltaRenderGeneration: UInt64?
    private var zeroDeltaGenerationByFrameID: [UInt64: UInt64] = [:]
    private var completedZeroDeltaGeneration: UInt64 = 0
    private var requestedPresentedGeneration: UInt64 = 0
    private var completedPresentedGeneration: UInt64 = 0
    private var pendingRender = false
    private var submittedPresentationContext: (epoch: UInt64, generation: UInt64)?
    private var applicationIsActive = true
    private var owningSceneIsActive = true
    private var appliedMediaVisibility = true
    private var isPresentationVisible = true
    private var isTimelineActive = true
    /// A stopped clock on a page that stays on screen, such as a Journey checkpoint.
    private var isTimelineHeld = false
    /// Whether the latest step left media that wants frames. It is a copy taken
    /// by that step: a step that sampled the media while suspended says no, and
    /// a suspension can lift off the step path, even while a step is in flight.
    /// So a lift never consults it; `refreshHeldMedia` always asks again.
    private var stepMediaActive = false
    private var sessionIsOpen = false
    var needsSessionCleanup: Bool { sessionIsOpen }
    private(set) var hasTakenSessionOwnership = false
    private var lastAppliedSize: ExperienceRuntimeSurfaceSize?
    private var frameSequence: UInt64 = 0
    private var lifecycleGeneration: UInt64 = 0
    private var semanticPresentationEpoch: UInt64 = 0
    private var lastSemanticFrame: UInt64 = 0
    private var semanticDeliveriesInFlight = 0
    private var inFlightFrameIDs: Set<UInt64> = []
    private var terminalError: Error?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var retirementTask: Task<Void, Never>?
    var retirementTimeoutNanoseconds = ExperienceRuntimeRetirement.timeoutNanoseconds

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
        onError: @escaping @MainActor (Error) -> Void = { _ in },
        now: @escaping @MainActor () -> TimeInterval = { CACurrentMediaTime() }
    ) {
        self.now = now
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
        // Ownership begins with the first session operation, including failed startup.
        hasTakenSessionOwnership = true
        sessionIsOpen = true
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
        frameClock.reset()
        isStarted = true
        surfaceView.runtimeObserver = self
        installApplicationObservers()
        updateOwningSceneObservers()
        updateDisplayLinkForCurrentScreen()
        reconcile()
    }

    func shutdown() async {
        guard let task = beginRetirement() else { return }
        do {
            // Retiring the loop is native work alone.
            try await ExperienceRuntimeRetirement.wait(timeoutNanoseconds: retirementTimeoutNanoseconds, authoredTime: nil) {
                await task.value
            }
        } catch { reportTerminal(error) }
    }

    /// Used only inside a bounded, owning retirement task. Joining this work
    /// retains the session and its resources after the host deadline expires.
    func retireSession() async {
        guard let task = beginRetirement() else { return }
        await task.value
    }

    private func beginRetirement() -> Task<Void, Never>? {
        if let retirementTask { return retirementTask }
        guard isStarted || operationInFlight || sessionIsOpen else { return nil }
        // Fence admission and cancel queued work in the caller's MainActor
        // turn. Only draining accepted work and native cleanup may be deferred.
        isShuttingDown = true
        endActiveInput()
        lifecycleGeneration &+= 1
        isStarted = false
        pendingTimestamp = nil
        pendingZeroDeltaFrame = false
        pendingFrameAdvancesToNow = false
        zeroDeltaStepGeneration = nil
        zeroDeltaRenderGeneration = nil
        zeroDeltaGenerationByFrameID.removeAll()
        pendingRender = false
        pendingPointers.removeAll()
        pendingFocus.removeAll()
        pointerInput.reset()
        cancelPendingWork(with: CancellationError())
        resumeIdleWaiters()
        invalidateDisplayLink()
        removeApplicationObservers()
        surfaceView?.runtimeObserver = nil
        let task = Task { @MainActor in
            await self.finishRetirement()
            self.retirementTask = nil
        }
        retirementTask = task
        return task
    }

    private func finishRetirement() async {
        await waitForStartToFinish()
        await waitForOperationToFinish()
        await waitForFramesToFinish()

        if sessionIsOpen {
            if let ending = pendingInputEnd {
                pendingInputEnd = nil
                do {
                    let result = try await session.perform(.step(ending))
                    await result.deliver()
                } catch { onError(error) }
            }
            do {
                _ = try await session.perform(.close)
                sessionIsOpen = false
            } catch {
                // Keep ownership so another shutdown can retry failed cleanup.
                onError(error)
            }
        }
        surfaceView?.metalLayer.device = nil
        lastAppliedSize = nil
        isShuttingDown = false
    }

    /// Queues product work behind all previously accepted native operations.
    /// Its result delivery and completion run exactly once on MainActor.
    @discardableResult
    func enqueue(
        _ work: ExperienceRuntimePresentationQueuedWork,
        completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void = { _ in }
    ) -> Bool {
        guard terminalError == nil, !isShuttingDown else {
            completion(.failure(terminalError ?? CancellationError()))
            return false
        }
        let acceptedWorkCount = pendingWork.count + (inFlightWork == nil ? 0 : 1)
        guard acceptedWorkCount < ExperienceRuntimePresentationLimits.pendingWork else {
            completion(.failure(ExperienceRuntimePresentationLoopError.pendingWorkOverflow))
            return false
        }
        pendingWork.append(PendingWork(
            work: work,
            completion: ExperienceRuntimePresentationWorkCompletion(completion)
        ))
        drain()
        return true
    }

    /// Interactive work belongs to the visibility/lifecycle generation that admitted it.
    /// Host commands use enqueue directly because they may intentionally run while hidden.
    @discardableResult
    func enqueueInteraction(
        _ work: ExperienceRuntimePresentationQueuedWork,
        isEligible: @escaping @MainActor @Sendable () -> Bool,
        completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void = { _ in }
    ) -> Bool {
        guard inputEnabled, shouldPresent, isEligible() else {
            completion(.failure(CancellationError()))
            return false
        }
        let epoch = semanticPresentationEpoch
        let generation = lifecycleGeneration
        return enqueue(ExperienceRuntimePresentationQueuedWork { [weak self] in
            let eligible = await MainActor.run { [weak self] in
                guard let self, self.inputEnabled, self.shouldPresent,
                      self.semanticPresentationEpoch == epoch,
                      self.lifecycleGeneration == generation else { return false }
                return isEligible()
            }
            guard eligible else { throw CancellationError() }
            return try await work.perform()
        }, completion: completion)
    }

    /// Called within serialized native editing work, before later scene input.
    func takeNativeEditingTap(at point: CGPoint) -> [[ExperienceInteractivePointerEvent]] {
        [pendingPointers.takeNativeTap(at: point)]
    }

    @discardableResult
    func enqueueFocus(_ input: NuxieNativeFocusInput) -> Bool {
        guard inputEnabled, shouldPresent, terminalError == nil else { return false }
        pendingFocus.append(input)
        return true
    }

    private func takeFocusBatch() -> [NuxieNativeFocusInput] {
        let batch = pendingFocus.takeBatch()
        if !pendingFocus.isEmpty { pendingTimestamp = pendingTimestamp ?? requestedDisplayTime() }
        return batch
    }

    /// A display tick. `timestamp` is when the tick's picture is due on screen
    /// (the display link's `targetTimestamp`), and `interval` the display's
    /// refresh interval when the display link knows it.
    func displayLinkDidFire(at timestamp: TimeInterval, interval: TimeInterval? = nil) {
        if let interval, interval.isFinite, interval > 0 { displayInterval = interval }
        if timestamp.isFinite { lastDisplayTime = timestamp }
        guard shouldAdvance || presentsHeldMedia else {
            reconcile()
            return
        }
        pendingTimestamp = timestamp
        drain()
    }

    /// The time to ask for a picture drawn now, outside a display tick: the
    /// latest tick's target, which `pictureTime(for:)` moves on to the refresh
    /// the picture can reach. Before any tick reports its interval, the later
    /// of now and that target.
    private func requestedDisplayTime() -> TimeInterval {
        guard let lastDisplayTime else { return now() }
        return displayInterval == nil ? max(lastDisplayTime, now()) : lastDisplayTime
    }

    /// When a picture asked for at `requested` is shown, the time every picture
    /// is evaluated at, as Core Animation evaluates a layer animation (UNIV-6118):
    /// the first refresh on the display's grid that is still ahead of now, and
    /// after the refresh the previous picture took, since each presented picture
    /// takes its own refresh. Without a known interval, `requested` itself.
    private func pictureTime(for requested: TimeInterval) -> TimeInterval {
        guard let interval = displayInterval, requested.isFinite else { return requested }
        let current = now()
        var time = requested
        if time <= current { time += (floor((current - time) / interval) + 1) * interval }
        if let lastPictureTime, time < lastPictureTime + interval / 2 { time = lastPictureTime + interval }
        return time
    }

    private(set) var timelineElapsedSeconds: Double = 0

    func setPresentationVisible(_ visible: Bool) {
        guard isPresentationVisible != visible else { return }
        isPresentationVisible = visible
        if !visible { endActiveInput() }
        semanticPresentationEpoch &+= 1
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
    ///
    /// `held` marks a stopped clock on a page that stays on screen, as during a
    /// Journey checkpoint. Only authored time holds: the page is still on screen
    /// for its media, so a playing video is neither paused nor suspended, and
    /// while it wants frames each display tick steps by zero and draws.
    func setTimelineActive(_ active: Bool, held: Bool = false) {
        let held = held && !active
        guard isTimelineActive != active else {
            guard isTimelineHeld != held else { return }
            isTimelineHeld = held
            reconcile()
            return
        }
        // Both facts change before any reconcile, so a hold never reads as hidden.
        isTimelineHeld = held
        isTimelineActive = active
        if !active { endActiveInput() }
        semanticPresentationEpoch &+= 1
        pendingTimestamp = nil
        frameClock.reset()
        if active {
            // Delta-0 resume per the lifecycle contract; never a time jump.
            pendingZeroDeltaFrame = true
        }
        reconcile()
    }

    /// Media on a held page can want frames again with no step to say so, as
    /// when its video's suspension lifts after the page was hidden, after an
    /// audio interruption or while the app was inactive. While suspended its
    /// demand is unknown, so every lift on a held page queues one zero-delta
    /// step that draws nothing, whatever the latest step said. Operations run
    /// one at a time, so it follows any step in flight and its answer, sampled
    /// after the lift, is the one the held ticks follow. A suspension that
    /// begins off the step path needs nothing: the next held tick finds no
    /// demand and stops the ticks.
    func refreshHeldMedia() {
        guard isTimelineHeld else { return }
        pendingZeroDeltaFrame = true
        reconcile()
    }

    var hasCompletedLatestFrame: Bool {
        !operationInFlight && !pendingRender && !pendingZeroDeltaFrame &&
            pendingTimestamp == nil && pendingWork.isEmpty && pendingFocus.isEmpty &&
            inFlightFrameIDs.isEmpty && frameSequence > 0
    }

    /// Includes semantic delivery, which can follow native frame completion.
    var hasDeliveredLatestSemanticFrame: Bool {
        hasCompletedLatestFrame && lastSemanticFrame == frameSequence && semanticDeliveriesInFlight == 0
    }

    func advanceZeroDelta(after work: ExperienceRuntimePresentationQueuedWork? = nil, awaitsPresentation: Bool = false) async throws {
        guard isStarted, !isShuttingDown, terminalError == nil else {
            throw terminalError ?? CancellationError()
        }
        let lifecycle = lifecycleGeneration
        zeroDeltaRequestGeneration &+= 1
        let generation = zeroDeltaRequestGeneration
        let needsPresentation = awaitsPresentation && shouldPresent
        if needsPresentation { requestedPresentedGeneration = generation }
        pendingZeroDeltaFrame = true
        if let work {
            // Reserve the zero step in the same MainActor turn as its write.
            // A queued display tick must not advance time between them.
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                enqueue(work, completion: { continuation.resume(with: $0) })
            }
        } else {
            reconcile()
        }
        try await withTaskCancellationHandler {
            while (completedZeroDeltaGeneration < generation || (needsPresentation && completedPresentedGeneration < generation)),
                  terminalError == nil, !isShuttingDown, lifecycleGeneration == lifecycle {
                try Task.checkCancellation()
                await withCheckedContinuation { idleWaiters.append($0) }
            }
            try Task.checkCancellation()
        } onCancel: {
            Task { @MainActor [weak self] in self?.resumeIdleWaiters() }
        }
        if let terminalError { throw terminalError }
        guard isStarted, !isShuttingDown, lifecycleGeneration == lifecycle else {
            throw CancellationError()
        }
    }

    /// Presents a page step's first frame. Like `advanceZeroDelta(awaitsPresentation: true)`,
    /// except that while the timeline runs and presents, the frame advances from the step's
    /// begin (`ExperienceRuntimePresentationQueuedWork.startsStepClock`) to the time it is
    /// shown, as a display frame does, so the step is already moving when it first reaches
    /// the screen. The next display tick then counts from this frame's display time.
    func advanceStepFrame() async throws {
        pendingFrameAdvancesToNow = true
        try await advanceZeroDelta(awaitsPresentation: true)
    }

    func runtimeSurfaceViewGeometryDidChange() {
        semanticPresentationEpoch &+= 1
        updateOwningSceneObservers()
        updateDisplayLinkForCurrentScreen()
        guard isStarted else { return }
        reconcile()
    }

    func runtimeSurfaceViewVisibilityDidChange() {
        semanticPresentationEpoch &+= 1
        refreshOwningSceneActivity()
        updateOwningSceneObservers()
        updateDisplayLinkForCurrentScreen()
        if shouldAdvance {
            pendingTimestamp = pendingTimestamp ?? requestedDisplayTime()
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
        displayLink?.isPaused = !shouldAdvance && !presentsHeldMedia
        drain()
    }

    private func drain() {
        guard !operationInFlight,
              isStarted,
              !isShuttingDown,
              terminalError == nil,
              let operation = nextOperation() else { return }

        operationInFlight = true
        if case .step(let step) = operation { recordSubmittedInput(step) }
        let context: (epoch: UInt64, generation: UInt64)
        if case .render = operation, let submitted = submittedPresentationContext {
            context = submitted
            submittedPresentationContext = nil
        } else {
            context = (semanticPresentationEpoch, lifecycleGeneration)
        }
        let semanticEpoch = context.epoch
        let generation = context.generation
        let frame = frameSequence
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await self.session.perform(operation)
                try await self.consume(result, for: operation, semanticEpoch: semanticEpoch, generation: generation, frame: frame)
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
        // Input termination precedes lifecycle writes, row batches and rendering.
        if let ending = pendingInputEnd {
            pendingInputEnd = nil
            return .step(ending)
        }
        guard let surfaceView else {
            reportTerminal(ExperienceRuntimePresentationLoopError.disposedSurface)
            return nil
        }

        if shouldPresent || presentsHeldMedia {
            let size = surfaceSize(for: surfaceView)
            if size != lastAppliedSize {
                pendingRender = false
                pendingPictureTime = nil
                submittedPresentationContext = nil
                return .resize(size)
            }
        }

        // Render settled geometry before lifecycle work, including visibility
        // changes that arrived while the step was in flight.
        if pendingRender {
            pendingRender = false
            return makeRenderOperation(for: surfaceView)
        }

        // Media must observe visibility even when no display tick or render is
        // pending. Keep the transition serialized with all other screen work.
        // It follows real visibility, not the clock: a held page is on screen.
        if appliedMediaVisibility != isOnScreen {
            return .setMediaVisible(isOnScreen)
        }

        if !shouldAdvance {
            if !pendingWork.isEmpty { return takeNextQueuedOperation() }
            if pendingZeroDeltaFrame {
                pendingZeroDeltaFrame = false
                pendingFrameAdvancesToNow = false
                zeroDeltaStepGeneration = zeroDeltaRequestGeneration
                return .step(ExperienceRuntimePresentationStep(
                    elapsedSeconds: 0,
                    pointers: [],
                    requestsRender: false
                ))
            }
            // A held page keeps presenting its media: each display tick steps
            // by zero, so new video pictures reach the screen and nothing
            // authored moves. With no media wanting frames it draws nothing.
            if presentsHeldMedia, let timestamp = pendingTimestamp {
                pendingTimestamp = nil
                // Nothing authored moves, but the picture takes its refresh.
                pendingPictureTime = pictureTime(for: timestamp)
                return .step(ExperienceRuntimePresentationStep(
                    elapsedSeconds: 0,
                    pointers: [],
                    requestsRender: true
                ))
            }
            return nil
        }

        if !shouldPresent {
            if !pendingWork.isEmpty { return takeNextQueuedOperation() }
            if pendingZeroDeltaFrame {
                pendingZeroDeltaFrame = false
                pendingFrameAdvancesToNow = false
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
                elapsedSeconds: Float(frameClock.frame(at: pictureTime(for: timestamp)).delta),
                pointers: pointers,
                requestsRender: false
            ))
        }

        if !pendingWork.isEmpty { return takeNextQueuedOperation() }
        if pendingZeroDeltaFrame {
            pendingZeroDeltaFrame = false
            zeroDeltaStepGeneration = zeroDeltaRequestGeneration
            // A page step's first frame is evaluated at the time it is shown,
            // as every display frame is: at least one refresh after the step
            // began, so it already shows the step moving.
            let shown = pictureTime(for: requestedDisplayTime())
            pendingPictureTime = shown
            let frame = pendingFrameAdvancesToNow
                ? frameClock.frame(at: shown)
                : frameClock.zeroDeltaFrame(at: shown)
            pendingFrameAdvancesToNow = false
            return .step(ExperienceRuntimePresentationStep(
                elapsedSeconds: Float(frame.delta),
                pointers: [],
                focusInputs: takeFocusBatch(),
                requestsRender: true
            ))
        }
        guard let timestamp = pendingTimestamp else { return nil }
        pendingTimestamp = nil
        let pointers = pendingPointers.takeBatch()
        if !pendingPointers.isEmpty { pendingTimestamp = timestamp }
        let shown = pictureTime(for: timestamp)
        pendingPictureTime = shown
        return .step(ExperienceRuntimePresentationStep(
            elapsedSeconds: Float(frameClock.frame(at: shown).delta),
            pointers: pointers,
            focusInputs: takeFocusBatch(),
            requestsRender: true
        ))
    }

    private func consume(
        _ result: ExperienceRuntimePresentationSessionResult,
        for operation: ExperienceRuntimePresentationSessionOperation,
        semanticEpoch: UInt64, generation: UInt64, frame: UInt64
    ) async throws {
        switch (operation, result.value) {
        case (.copyMetalDevice, .metalDevice(let device)):
            guard let layer = surfaceView?.metalLayer else {
                throw ExperienceRuntimePresentationLoopError.disposedSurface
            }
            configure(layer, with: device)
        case (.resize(let size), .renderer(let outcome)):
            try requireHealthy(outcome)
            lastAppliedSize = size
            pendingTimestamp = nil
            pendingZeroDeltaFrame = true
        case (.setMediaVisible(let visible), .none):
            appliedMediaVisibility = visible
        case (.step(let step), .session):
            timelineElapsedSeconds += Double(step.elapsedSeconds)
            stepMediaActive = result.mediaActive
            await result.deliver()
            if !step.pointers.isEmpty {
                onAcceptedPointerInput(.init(eventCount: step.pointers.count))
            }
            onSessionResult()
            pendingRender = step.requestsRender
            submittedPresentationContext = step.requestsRender ? (semanticEpoch, generation) : nil
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
        case (.render(_, _, let completion), .renderer(let outcome)):
            if outcome.disposition == .presented, outcome.health == .healthy, let picture = renderPictureTime {
                lastPictureTime = max(lastPictureTime ?? picture, picture)
            }
            renderPictureTime = nil
            if result.hasDelivery {
                completion.recordPresentedWork { [weak self] in
                    Task { @MainActor [weak self] in
                        // A held page's frames are on screen too.
                        guard let self, self.isOnScreen, self.terminalError == nil,
                              self.lifecycleGeneration == generation,
                              self.semanticPresentationEpoch == semanticEpoch,
                              frame > self.lastSemanticFrame else { return }
                        self.lastSemanticFrame = frame
                        self.semanticDeliveriesInFlight += 1
                        defer { self.semanticDeliveriesInFlight -= 1 }
                        await result.deliver()
                    }
                }
            }
            completion.recordRenderOutcome(outcome)
            try consumeRenderOutcome(outcome)
        case (.queued(let work), .work(let requestsFrame)):
            if work.startsStepClock {
                // The step begins now. A tick taken before it would carry
                // time from before the step, so it is dropped, not drawn.
                // Pictures are timed when they are shown, so the last shown
                // picture may still be due; the step then counts from it, so
                // time already on screen is never stepped twice. The clock
                // never rewinds either: after a tick whose picture was never
                // shown, the runtime was already advanced to that tick's time,
                // and one elapsed time moves every timeline. Continuing
                // timelines stay exact; the new step starts at that time, at
                // most one refresh late, only in that case.
                frameClock.restart(at: max(now(), lastPictureTime ?? -.infinity))
                pendingTimestamp = nil
            }
            await result.deliver()
            finishInFlightWork(.success(()))
            if requestsFrame {
                if shouldAdvance {
                    pendingTimestamp = pendingTimestamp ?? requestedDisplayTime()
                } else {
                    pendingZeroDeltaFrame = true
                }
            }
        default:
            throw ExperienceRuntimePresentationLoopError.unexpectedSessionResult
        }
    }

    private func consumeRenderOutcome(
        _ outcome: ExperienceRuntimePresentationRenderOutcome
    ) throws {
        switch outcome.health {
        case .healthy:
            break
        case .deviceLost:
            throw ExperienceRuntimePresentationLoopError.rendererFailed(.deviceLost)
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
    ) -> ExperienceRuntimePresentationSessionOperation? {
        guard let size = lastAppliedSize else {
            reportTerminal(ExperienceRuntimePresentationLoopError.unexpectedSessionResult)
            return nil
        }
        let scale = size.layoutScaleFactor
        renderPictureTime = pendingPictureTime
        pendingPictureTime = nil
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
        // An occluded render suspends media, so only a page off screen gets one.
        guard isOnScreen else {
            return .render(.occluded, layoutScaleFactor: scale, completion: completion)
        }
        guard size.pixelWidth > 0,
              size.pixelHeight > 0,
              let permit = drawableGate.tryAcquire() else {
            return .render(.timeout, layoutScaleFactor: scale, completion: completion)
        }
        guard let drawable = acquireDrawable(surfaceView.metalLayer) else {
            permit.release()
            return .render(.timeout, layoutScaleFactor: scale, completion: completion)
        }
        let firstPresentedDrawableGate = firstPresentedDrawableGate
        // A later frame still carries the phase writes if their first drawable was skipped.
        let phaseGeneration = max(zeroDeltaGenerationByFrameID.values.max() ?? 0, completedZeroDeltaGeneration)
        let shouldNotifyPresentation = !firstPresentedDrawableGate.isClaimed
            || requestedPresentedGeneration > completedPresentedGeneration
        let shouldObservePresentation = session.observesEveryPresentation || shouldNotifyPresentation
        let presentedDrawableCallback: (@Sendable (
            ExperienceRuntimePresentedDrawable
        ) -> Void)? = if shouldNotifyPresentation {
            { [weak self] drawable in
                let isFirst = drawable.isComplete && firstPresentedDrawableGate.claim()
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.completedPresentedGeneration = max(self.completedPresentedGeneration, phaseGeneration)
                    self.resumeIdleWaiters()
                    if isFirst { self.onPresentedDrawable(drawable) }
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
            layoutScaleFactor: scale,
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
        let scale = surfaceView.runtimeDisplayScale
        if scale.isFinite, scale > 0 { surfaceView.metalLayer.contentsScale = scale }
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

    private var shouldAdvance: Bool { isTimelineActive && isLive }

    /// Started, in a window, scene or screen, with the app and scene active.
    private var isLive: Bool {
        guard isStarted,
              !isShuttingDown,
              applicationIsActive,
              let surfaceView,
              surfaceView.window != nil
                || observedWindowScene != nil
                || displayLinkScreen != nil,
              owningSceneIsActive else { return false }
        return true
    }

    private var shouldPresent: Bool { isTimelineActive && isOnScreen }

    /// Real visibility: a running or held clock (presented, not hidden below),
    /// a live host and a visible surface. Media follows this, not the clock.
    private var isOnScreen: Bool {
        guard isTimelineActive || isTimelineHeld,
              isLive,
              isPresentationVisible,
              let surfaceView,
              surfaceView.runtimeDisplayScale.isFinite,
              surfaceView.runtimeDisplayScale > 0,
              surfaceViewIsEffectivelyVisible(surfaceView) else { return false }
        return true
    }

    /// A held page on screen whose latest step left media wanting frames keeps
    /// stepping by zero and drawing on each display tick.
    private var presentsHeldMedia: Bool { isTimelineHeld && stepMediaActive && isOnScreen }

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
                    self?.semanticPresentationEpoch &+= 1
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
                    self?.semanticPresentationEpoch &+= 1
                    self?.applicationIsActive = true
                    self?.refreshOwningSceneActivity()
                    self?.frameClock.reset()
                    self?.pendingTimestamp = self?.requestedDisplayTime()
                    self?.reconcile()
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
                    self?.semanticPresentationEpoch &+= 1
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
                    self?.semanticPresentationEpoch &+= 1
                    self?.owningSceneIsActive = true
                    self?.frameClock.reset()
                    self?.pendingTimestamp = self?.requestedDisplayTime()
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
        pendingFrameAdvancesToNow = false
        zeroDeltaStepGeneration = nil
        zeroDeltaRenderGeneration = nil
        zeroDeltaGenerationByFrameID.removeAll()
        pendingRender = false
        pendingPointers.removeAll()
        pendingFocus.removeAll()
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

    private func resumeIdleWaiters() {
        let waiters = idleWaiters
        idleWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

}

extension ExperienceRuntimePresentationLoop: ExperienceRuntimeSurfaceViewObserver {
    func runtimeSurfaceViewDidReceivePointerEvents(
        _ events: [ExperienceRuntimeViewPointerEvent]
    ) {
        guard inputEnabled, isPresentationVisible, isTimelineActive, isStarted,
              !isShuttingDown,
              terminalError == nil,
              let surfaceView,
              let transform = ExperienceLayoutTransform(
                  artboardBounds: session.artboardBounds(),
                  viewportBounds: surfaceView.bounds
              ) else { return }
        let projected = pointerInput.runtimeEvents(for: events, transform: transform)
        guard !projected.isEmpty else { return }
        pendingPointers.enqueue(projected)
        pendingTimestamp = requestedDisplayTime()
        drain()
    }
}

enum ExperienceRuntimePresentationLoopError: Error, Equatable {
    case unexpectedSessionResult
    case rendererFailed(ExperienceRuntimePresentationRenderOutcome.Health)
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
        // `timestamp` is the refresh that already began; `targetTimestamp` is
        // when this tick's picture is shown, the time it is evaluated at.
        loop?.displayLinkDidFire(at: displayLink.targetTimestamp,
                                 interval: displayLink.targetTimestamp - displayLink.timestamp)
    }
}
#endif
