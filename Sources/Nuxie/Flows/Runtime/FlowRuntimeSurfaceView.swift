#if canImport(UIKit) && canImport(QuartzCore)
import Foundation
import Metal
import QuartzCore
import UIKit

@MainActor
protocol FlowRuntimeSurfaceViewObserver: AnyObject {
    func runtimeSurfaceViewGeometryDidChange()
    func runtimeSurfaceViewVisibilityDidChange()
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

    private func configureLayer() {
        isOpaque = false
        backgroundColor = .clear
        metalLayer.isOpaque = false
        metalLayer.backgroundColor = UIColor.clear.cgColor
        metalLayer.contentsScale = contentScaleFactor
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

/// Reference display driver for one visual session and one UIKit surface.
///
/// The driver keeps at most one async runtime operation in flight. While an
/// operation is running, display timestamps are reduced to the newest pending
/// value; detach, reattach, and resize take priority over that pending frame.
@MainActor
final class FlowRuntimeDisplayHost: NSObject {
    private enum PendingOperation {
        case detach
        case reattach(FlowRuntimeAppleSurfaceTarget)
        case resize(FlowRuntimeSurfaceSize)
        case frame(FlowRuntimeFrameTime)
    }

    private let session: FlowRenderSession
    private weak var surfaceView: FlowRuntimeSurfaceView?
    private let notificationCenter: NotificationCenter
    private let onError: @MainActor (Error) -> Void
    private let drawableGate: FlowRuntimeDrawableGate
    private let usesSystemDisplayLink: Bool

    private var surface: FlowRenderSurface?
    private var displayLink: CADisplayLink?
    private var displayLinkProxy: FlowRuntimeDisplayLinkProxy?
    private weak var displayLinkScreen: UIScreen?
    private var notificationTokens: [NSObjectProtocol] = []
    private var frameClock = FlowRuntimeFrameClock()
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

    init(
        session: FlowRenderSession,
        surfaceView: FlowRuntimeSurfaceView,
        notificationCenter: NotificationCenter = .default,
        drawableGate: FlowRuntimeDrawableGate? = nil,
        usesSystemDisplayLink: Bool = true,
        onError: @escaping @MainActor (Error) -> Void = { _ in }
    ) {
        self.session = session
        self.surfaceView = surfaceView
        self.notificationCenter = notificationCenter
        self.drawableGate = drawableGate ?? FlowRuntimeDrawableGate(
            capacity: FlowRuntimeAppleSurfacePolicy.maximumDrawableCount
        )
        self.usesSystemDisplayLink = usesSystemDisplayLink
        self.onError = onError
        super.init()
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
        applicationIsActive = UIApplication.shared.applicationState == .active

        defer {
            isStarting = false
            resumeStartWaiters()
        }

        guard let surfaceView else { return }
        let target = surfaceTarget(for: surfaceView)
        let surface: FlowRenderSurface
        do {
            surface = try await session.attachAppleSurface(to: target)
        } catch {
            lastStartupError = error
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
        reconcile()
    }

    func shutdown() async {
        if isShuttingDown {
            await waitForShutdownToFinish()
            return
        }
        guard isStarted || surface != nil || isStarting else { return }
        isShuttingDown = true
        lifecycleGeneration &+= 1
        isStarted = false
        pendingTimestamp = nil
        frameClock.reset()
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
        if !isVisible {
            pendingTimestamp = nil
            frameClock.reset()
        }
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
        }
        reconcile()
    }

    func displayLinkDidFire(at timestamp: TimeInterval) {
        guard shouldPresent, surface?.state == .attached else {
            reconcile()
            return
        }
        // Overwrite rather than queue: a stale animation tick has no value.
        pendingTimestamp = timestamp
        drain()
    }

    deinit {
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
        frameClock.reset()
        reconcile()
    }

    private func applicationDidBecomeActive() {
        applicationIsActive = true
        frameClock.reset()
        reconcile()
    }

    private func sceneLifecycleDidChange(_ notification: Notification) {
        guard let scene = notification.object as? UIWindowScene,
              scene === surfaceView?.window?.windowScene else {
            return
        }
        pendingTimestamp = nil
        frameClock.reset()
        reconcile()
    }

    private func reconcile() {
        guard isStarted, !isShuttingDown else {
            displayLink?.isPaused = true
            return
        }
        updateDisplayLinkForCurrentScreen()
        if !shouldPresent {
            pendingTimestamp = nil
            frameClock.reset()
        }
        displayLink?.isPaused = !(shouldPresent && surface?.state == .attached)
        drain()
    }

    private func drain() {
        guard !operationInFlight,
              !isShuttingDown,
              let surface else {
            return
        }
        guard let operation = nextOperation(for: surface) else {
            displayLink?.isPaused = !(shouldPresent && surface.state == .attached)
            return
        }

        operationInFlight = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.perform(operation, on: surface)
            } catch {
                self.terminalError = error
                self.pendingTimestamp = nil
                self.displayLink?.isPaused = true
                self.onError(error)
            }
            self.operationInFlight = false
            self.resumeIdleWaiters()
            if !self.isShuttingDown {
                self.drain()
            }
        }
    }

    private func nextOperation(for surface: FlowRenderSurface) -> PendingOperation? {
        if !shouldPresent {
            return surface.state == .attached ? .detach : nil
        }
        guard let surfaceView else { return nil }
        let target = surfaceTarget(for: surfaceView)
        if surface.state == .detached {
            return .reattach(target)
        }
        if surface.state == .attached, target.size != lastAppliedSize {
            return .resize(target.size)
        }
        if surface.state == .attached, let timestamp = pendingTimestamp {
            pendingTimestamp = nil
            return .frame(frameClock.frame(at: timestamp))
        }
        return nil
    }

    private func perform(
        _ operation: PendingOperation,
        on surface: FlowRenderSurface
    ) async throws {
        switch operation {
        case .detach:
            _ = try await surface.detach()
            lastAppliedSize = nil
            frameClock.reset()
        case .reattach(let target):
            _ = try await surface.reattach(to: target)
            lastAppliedSize = target.size
            frameClock.reset()
        case .resize(let size):
            _ = try await surface.resize(to: size)
            lastAppliedSize = size
        case .frame(let frameTime):
            let acquiredDrawable = acquireDrawable(for: surface)
            _ = try await session.perform(
                .advanceAndRender(frameTime),
                drawable: acquiredDrawable
            )
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
