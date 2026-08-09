#if canImport(UIKit) && canImport(QuartzCore)
import Foundation
import Metal
import NuxieRuntimeSupport
import QuartzCore
import UIKit

struct ExperienceRuntimePresentationRenderOutcome: Equatable, Sendable {
    enum Disposition: Equatable, Sendable {
        case none
        case presented
        case skippedZeroSize
        case skippedTimeout
        case skippedOccluded
        case reconfigured
        case recreated
        case deviceLost
        case outOfMemory
    }

    enum Health: Equatable, Sendable {
        case healthy
        case deviceLost
        case outOfMemory
        case failed
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
}

struct ExperienceRuntimePresentationDrawable: @unchecked Sendable {
    let value: any CAMetalDrawable
}

enum ExperienceRuntimePresentationDrawableState: @unchecked Sendable {
    case available(ExperienceRuntimePresentationDrawable)
    case timeout
    case occluded
}

/// Owns one native completion token. The portable C interface promises to
/// consume a valid callback pair exactly once and never invoke it inline; this
/// gate also makes a late or accidentally repeated callback harmless in Swift.
final class ExperienceRuntimePresentationFrameCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable () -> Void)?

    init(_ callback: @escaping @Sendable () -> Void) {
        self.callback = callback
    }

    func signalFromNative() {
        let callback = lock.withLock {
            defer { self.callback = nil }
            return self.callback
        }
        callback?()
    }
}

enum ExperienceRuntimePresentationSessionOperation: @unchecked Sendable {
    case copyMetalDevice
    case step(ExperienceRuntimePresentationStep)
    case resize(ExperienceRuntimeSurfaceSize)
    case render(
        ExperienceRuntimePresentationDrawableState,
        completion: ExperienceRuntimePresentationFrameCompletion
    )
    case detach
    case reattach(ExperienceRuntimeSurfaceSize)
    case resetPlayerRendererDomain
    case close
}

struct ExperienceRuntimePresentationSessionResult: @unchecked Sendable {
    enum Value: @unchecked Sendable {
        case none
        case metalDevice(any MTLDevice)
        case session(keepsAnimating: Bool)
        case renderer(ExperienceRuntimePresentationRenderOutcome)
    }

    let value: Value
    private let deliverOnMainActor: (@MainActor @Sendable () -> Void)?

    private init(
        _ value: Value,
        deliverOnMainActor: (@MainActor @Sendable () -> Void)? = nil
    ) {
        self.value = value
        self.deliverOnMainActor = deliverOnMainActor
    }

    static let none = Self(.none)

    static func metalDevice(_ device: any MTLDevice) -> Self {
        Self(.metalDevice(device))
    }

    static func session(
        keepsAnimating: Bool,
        deliverOnMainActor: (@MainActor @Sendable () -> Void)? = nil
    ) -> Self {
        Self(
            .session(keepsAnimating: keepsAnimating),
            deliverOnMainActor: deliverOnMainActor
        )
    }

    static func renderer(_ outcome: ExperienceRuntimePresentationRenderOutcome) -> Self {
        Self(.renderer(outcome))
    }

    @MainActor
    func deliver() {
        deliverOnMainActor?()
    }
}

/// Type-erased, single-operation seam between the MainActor presentation loop
/// and an actor whose implementation serializes every C call on its pinned OS
/// thread. The operation result is fully Swift-owned before it crosses back.
struct ExperienceRuntimePresentationSession: Sendable {
    typealias Perform = @Sendable (
        ExperienceRuntimePresentationSessionOperation
    ) async throws -> ExperienceRuntimePresentationSessionResult

    private let performOperation: Perform

    init(perform: @escaping Perform) {
        performOperation = perform
    }

    func perform(
        _ operation: ExperienceRuntimePresentationSessionOperation
    ) async throws -> ExperienceRuntimePresentationSessionResult {
        try await performOperation(operation)
    }
}

/// Swift-owned presentation policy for one direct-C interactive screen.
///
/// UIKit, CAMetalLayer, drawable acquisition, display cadence, and lifecycle
/// remain MainActor-confined. The session seam above owns no UI state and may
/// execute only the matching generic native operation on its pinned thread.
@MainActor
final class ExperienceRuntimePresentationLoop: NSObject {
    private let session: ExperienceRuntimePresentationSession
    private weak var surfaceView: ExperienceRuntimeSurfaceView?
    private let notificationCenter: NotificationCenter
    private let usesSystemDisplayLink: Bool
    private let onSessionResult: @MainActor () -> Void
    private let onError: @MainActor (Error) -> Void
    private let drawableGate: ExperienceRuntimeDrawableGate

    private var frameClock = ExperienceRuntimeFrameClock()
    // MainActor-confined; deinit has exclusive access to the last reference.
    private nonisolated(unsafe) var displayLink: CADisplayLink?
    private var displayLinkProxy: ExperienceRuntimePresentationDisplayLinkProxy?
    private weak var displayLinkScreen: UIScreen?
    // MainActor-confined; deinit has exclusive access to the last reference.
    private nonisolated(unsafe) var notificationTokens: [NSObjectProtocol] = []
    private var isStarted = false
    private var isShuttingDown = false
    private var operationInFlight = false
    private var pendingTimestamp: TimeInterval?
    private var pendingRender = false
    private var keepsAnimating = true
    private var applicationIsActive = true
    private var isPresentationVisible = true
    private var lastAppliedSize: ExperienceRuntimeSurfaceSize?
    private var frameSequence: UInt64 = 0
    private var inFlightFrameIDs: Set<UInt64> = []
    private var terminalError: Error?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        session: ExperienceRuntimePresentationSession,
        surfaceView: ExperienceRuntimeSurfaceView,
        notificationCenter: NotificationCenter = .default,
        drawableGate: ExperienceRuntimeDrawableGate? = nil,
        usesSystemDisplayLink: Bool = true,
        onSessionResult: @escaping @MainActor () -> Void = {},
        onError: @escaping @MainActor (Error) -> Void = { _ in }
    ) {
        self.session = session
        self.surfaceView = surfaceView
        self.notificationCenter = notificationCenter
        self.drawableGate = drawableGate ?? ExperienceRuntimeDrawableGate(
            capacity: ExperienceRuntimeAppleSurfacePolicy.maximumDrawableCount
        )
        self.usesSystemDisplayLink = usesSystemDisplayLink
        self.onSessionResult = onSessionResult
        self.onError = onError
        super.init()
    }

    func start() async throws {
        guard !isStarted else { return }
        guard !isShuttingDown, let surfaceView else { throw CancellationError() }

        applicationIsActive = UIApplication.shared.applicationState == .active
        let deviceResult = try await session.perform(.copyMetalDevice)
        guard case .metalDevice(let device) = deviceResult.value else {
            throw ExperienceRuntimePresentationLoopError.unexpectedSessionResult
        }
        configure(surfaceView.metalLayer, with: device)
        let size = surfaceSize(for: surfaceView)
        let resizeResult = try await session.perform(.resize(size))
        guard case .renderer = resizeResult.value else {
            throw ExperienceRuntimePresentationLoopError.unexpectedSessionResult
        }
        lastAppliedSize = size
        frameClock.reset()
        isStarted = true
        surfaceView.runtimeObserver = self
        installApplicationObservers()
        updateDisplayLinkForCurrentScreen()
        reconcileDisplayLink()
    }

    func shutdown() async {
        guard isStarted || operationInFlight else { return }
        isShuttingDown = true
        isStarted = false
        pendingTimestamp = nil
        pendingRender = false
        invalidateDisplayLink()
        removeApplicationObservers()
        surfaceView?.runtimeObserver = nil
        await waitForOperationToFinish()

        do {
            _ = try await session.perform(.detach)
        } catch {
            onError(error)
        }
        do {
            _ = try await session.perform(.close)
        } catch {
            onError(error)
        }
        surfaceView?.metalLayer.device = nil
        lastAppliedSize = nil
        isShuttingDown = false
    }

    func displayLinkDidFire(at timestamp: TimeInterval) {
        guard shouldPresent else {
            reconcileDisplayLink()
            return
        }
        pendingTimestamp = timestamp
        drain()
    }

    func setPresentationVisible(_ visible: Bool) {
        guard isPresentationVisible != visible else { return }
        isPresentationVisible = visible
        frameClock.reset()
        if visible { keepsAnimating = true }
        reconcileDisplayLink()
    }

    func runtimeSurfaceViewGeometryDidChange() {
        updateDisplayLinkForCurrentScreen()
        guard isStarted, let surfaceView else { return }
        let size = surfaceSize(for: surfaceView)
        if size != lastAppliedSize {
            pendingTimestamp = CACurrentMediaTime()
        }
        drain()
    }

    func runtimeSurfaceViewVisibilityDidChange() {
        frameClock.reset()
        updateDisplayLinkForCurrentScreen()
        reconcileDisplayLink()
    }

    deinit {
        displayLink?.invalidate()
        notificationTokens.forEach(notificationCenter.removeObserver)
    }

    private func drain() {
        guard !operationInFlight,
              isStarted,
              !isShuttingDown,
              terminalError == nil,
              let surfaceView else { return }

        let operation: ExperienceRuntimePresentationSessionOperation
        if surfaceSize(for: surfaceView) != lastAppliedSize {
            operation = .resize(surfaceSize(for: surfaceView))
        } else if pendingRender {
            pendingRender = false
            operation = makeRenderOperation(for: surfaceView)
        } else if let timestamp = pendingTimestamp {
            pendingTimestamp = nil
            operation = .step(ExperienceRuntimePresentationStep(
                elapsedSeconds: Float(frameClock.frame(at: timestamp).delta),
                pointers: []
            ))
        } else {
            reconcileDisplayLink()
            return
        }

        operationInFlight = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await self.session.perform(operation)
                try self.consume(result, for: operation)
            } catch {
                if case .render(_, let completion) = operation {
                    completion.signalFromNative()
                }
                self.reportTerminal(error)
            }
            self.operationInFlight = false
            self.resumeIdleWaiters()
            if self.isStarted { self.drain() }
        }
    }

    private func consume(
        _ result: ExperienceRuntimePresentationSessionResult,
        for operation: ExperienceRuntimePresentationSessionOperation
    ) throws {
        switch (operation, result.value) {
        case (.resize(let size), .renderer):
            lastAppliedSize = size
            pendingTimestamp = pendingTimestamp ?? CACurrentMediaTime()
        case (.step, .session(let keepsAnimating)):
            self.keepsAnimating = keepsAnimating
            result.deliver()
            onSessionResult()
            // Finish every accepted visible step with an explicit renderer
            // outcome. If visibility changed while the pinned-thread step was
            // running, report OCCLUDED instead of silently dropping the frame.
            pendingRender = true
        case (.render, .renderer(let outcome)):
            if outcome.health != .healthy {
                throw ExperienceRuntimePresentationLoopError.rendererFailed(outcome.health)
            }
        default:
            throw ExperienceRuntimePresentationLoopError.unexpectedSessionResult
        }
    }

    private func makeRenderOperation(
        for surfaceView: ExperienceRuntimeSurfaceView
    ) -> ExperienceRuntimePresentationSessionOperation {
        frameSequence &+= 1
        let frameID = frameSequence
        inFlightFrameIDs.insert(frameID)
        let completion = ExperienceRuntimePresentationFrameCompletion { [weak self] in
            Task { @MainActor [weak self] in
                self?.completeFrame(frameID)
            }
        }
        guard shouldPresent else {
            return .render(.occluded, completion: completion)
        }
        let size = lastAppliedSize
        guard size?.pixelWidth != 0,
              size?.pixelHeight != 0,
              let permit = drawableGate.tryAcquire() else {
            return .render(.timeout, completion: completion)
        }
        guard let drawable = surfaceView.metalLayer.nextDrawable() else {
            permit.release()
            return .render(.timeout, completion: completion)
        }
        let wrappedCompletion = ExperienceRuntimePresentationFrameCompletion {
            permit.release()
            completion.signalFromNative()
        }
        return .render(
            .available(ExperienceRuntimePresentationDrawable(value: drawable)),
            completion: wrappedCompletion
        )
    }

    private func completeFrame(_ frameID: UInt64) {
        guard inFlightFrameIDs.remove(frameID) != nil else { return }
        reconcileDisplayLink()
    }

    private func configure(_ layer: CAMetalLayer, with device: any MTLDevice) {
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.maximumDrawableCount = ExperienceRuntimeAppleSurfacePolicy.maximumDrawableCount
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

    private var shouldPresent: Bool {
        guard isStarted,
              !isShuttingDown,
              applicationIsActive,
              isPresentationVisible,
              let surfaceView,
              let window = surfaceView.window,
              !window.isHidden,
              window.alpha > 0,
              !surfaceView.isHidden,
              surfaceView.alpha > 0 else { return false }
        if let scene = window.windowScene {
            return scene.activationState == .foregroundActive
        }
        return true
    }

    private func reconcileDisplayLink() {
        displayLink?.isPaused = !(shouldPresent && keepsAnimating)
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
                    self?.reconcileDisplayLink()
                }
            },
            notificationCenter.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.applicationIsActive = true
                    self?.keepsAnimating = true
                    self?.frameClock.reset()
                    self?.pendingTimestamp = CACurrentMediaTime()
                    self?.drain()
                }
            },
        ]
    }

    private func removeApplicationObservers() {
        notificationTokens.forEach(notificationCenter.removeObserver)
        notificationTokens.removeAll()
    }

    private func reportTerminal(_ error: Error) {
        guard terminalError == nil else { return }
        terminalError = error
        pendingTimestamp = nil
        pendingRender = false
        displayLink?.isPaused = true
        onError(error)
    }

    private func waitForOperationToFinish() async {
        guard operationInFlight else { return }
        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
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
        // Pointer projection is integrated with ExperienceInteractiveScreen in
        // the next vertical slice; until then a UI sample only requests a tick.
        guard !events.isEmpty else { return }
        pendingTimestamp = CACurrentMediaTime()
        drain()
    }
}

enum ExperienceRuntimePresentationLoopError: Error, Equatable {
    case unexpectedSessionResult
    case rendererFailed(ExperienceRuntimePresentationRenderOutcome.Health)
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
