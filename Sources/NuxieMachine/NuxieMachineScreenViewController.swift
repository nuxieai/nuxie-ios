#if os(iOS) && !targetEnvironment(macCatalyst)
import Metal
import NuxieRuntime
import QuartzCore
import UIKit

/// Hosts the one Screen a [`NuxieMachineEdge`] drives: the Metal surface the
/// engine draws into and the display link that runs the edge's frames.
///
/// Each display tick is one frame: the pointers that arrived, the edge's
/// frame (engine step, engine events to the machine, writes to cells, the
/// store's answers), then a draw. Frames run in the Screen's lane
/// ([`inLane`]), where the owner makes its own calls to the edge, so the
/// edge hears a frame, a wake and a close in the order they were asked for.
/// The Screen is laid out by the engine at the view's size, as the SDK's
/// Screens are, and drawn at the display's scale. One frame is in flight at a time, and a frame's draw waits for the
/// GPU, so a frame never starts before the last one is on screen.
///
/// The loop rests when nothing asks for a frame: the engine's step says no
/// frame is needed, no write is waiting to show, no pointer has arrived and
/// the store owes the edge nothing. A touch, a store's answer still owed, or
/// [`requestFrame`] from the owner after a delivery wakes it. Off screen (its
/// sheet gone, or its scene in the background), it draws nothing and runs
/// frames only while the store owes an answer, so rows that arrive after the
/// sheet is gone are still delivered.
@MainActor
package final class NuxieMachineScreenViewController: UIViewController {
    /// The edge this controller runs frames for. It owns the session.
    package let edge: NuxieMachineEdge

    /// Told before each frame with the moment the frame runs at, so the
    /// owner can deliver what is due by then first (a wake the machine asked
    /// for at an earlier moment).
    package var beforeFrame: (@MainActor (Int64) async -> Void)?
    /// Told after each frame, once its turn is over and its draw is done.
    package var onFrame: (@MainActor (NuxieMachineFrame) async -> Void)?
    /// Told once when drawing fails; the loop has stopped by then.
    package var onFault: (@MainActor (NuxieMachineEdgeFault) -> Void)?

    /// What the host knows about the record, as this Screen's accessibility
    /// value once its first frame is drawn. A Screen's own controls have no
    /// accessibility elements yet, so this is the one a check can read.
    package var statusText = "" {
        didSet { updateAccessibility() }
    }

    /// Frames drawn to the screen so far.
    package private(set) var framesDrawn = 0

    private let surface = NuxieMachineSurfaceView()
    // Touched off the main actor only by `deinit`, after every other use.
    private nonisolated(unsafe) var displayLink: CADisplayLink?
    private var pendingPointers: [NuxieNativePointerEvent] = []
    private var frameInFlight = false
    private var frameRequested = true
    private var stopped = false
    /// Whether the lane is held, and the calls waiting for it in order.
    private var laneHeld = false
    private var laneWaiting: [CheckedContinuation<Void, Never>] = []
    /// The display time of the last frame; none after a rest, so the frame
    /// that wakes the loop advances by zero, not by the time it rested.
    private var lastTimestamp: CFTimeInterval?
    /// The size the engine lays the Screen out at and draws, once applied.
    private var appliedSize: Size?
    private var deviceConfigured = false
    // Touched off the main actor only by `deinit`, after every other use.
    private nonisolated(unsafe) var notificationTokens: [NSObjectProtocol] = []

    private struct Size: Equatable {
        let pixelWidth: UInt32
        let pixelHeight: UInt32
        let scale: Float
    }

    package init(edge: NuxieMachineEdge) {
        self.edge = edge
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        displayLink?.invalidate()
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
    }

    override package func loadView() {
        surface.isAccessibilityElement = true
        surface.accessibilityIdentifier = "nuxie-machine-screen"
        surface.accessibilityLabel = "Screen"
        surface.onPointers = { [weak self] pointers in
            guard let self, !self.stopped else { return }
            self.pendingPointers += pointers
            self.requestFrame()
        }
        surface.onGeometryChange = { [weak self] in self?.requestFrame() }
        view = surface
        updateAccessibility()
    }

    /// Start the display loop. The first frame steps the Screen as the
    /// machine has written it so far and draws it once the view has a size.
    package func start() {
        guard displayLink == nil, !stopped else { return }
        let link = CADisplayLink(target: DisplayLinkTarget(self), selector: #selector(DisplayLinkTarget.tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        // Coming back to the foreground draws again: whether the scene is in
        // the foreground is read from UIKit at each frame.
        notificationTokens = [
            NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
            ) { [weak self] _ in Task { @MainActor in self?.requestFrame() } },
        ]
        requestFrame()
    }

    /// Ask for a frame: after a delivery outside a frame (a start, a close,
    /// a wake), whose writes show only on the next step and whose calls are
    /// answered only at a frame.
    package func requestFrame() {
        guard !stopped else { return }
        frameRequested = true
        displayLink?.isPaused = false
    }

    /// Run `body` holding the Screen's lane, after every call asked for
    /// before it. Frames run in it, and the owner makes its calls to the
    /// edge in it, so they reach the edge one at a time and in order. The
    /// lane outlives the loop: an owner may still call the edge after
    /// [`stop`].
    package func inLane<Value>(_ body: () async throws -> Value) async rethrows -> Value {
        if laneHeld {
            await withCheckedContinuation { laneWaiting.append($0) }
        } else {
            laneHeld = true
        }
        defer {
            // The next waiting call takes it over still held.
            if laneWaiting.isEmpty {
                laneHeld = false
            } else {
                laneWaiting.removeFirst().resume()
            }
        }
        return try await body()
    }

    /// Stop the loop for good. A frame in flight finishes; none follows.
    /// What the loop scheduled goes with it: the display link and the
    /// foreground observer.
    package func stop() {
        stopped = true
        displayLink?.invalidate()
        displayLink = nil
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
        notificationTokens = []
        pendingPointers = []
    }

    // MARK: Frames

    fileprivate func tick(at timestamp: CFTimeInterval) {
        guard !stopped, !frameInFlight else { return }
        frameRequested = false
        frameInFlight = true
        let pointers = pendingPointers
        pendingPointers = []
        let elapsed = lastTimestamp.map { Float(max(0, timestamp - $0)) } ?? 0
        lastTimestamp = timestamp
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.inLane { await self.runFrame(pointers: pointers, elapsedSeconds: elapsed) }
        }
    }

    private func runFrame(pointers: [NuxieNativePointerEvent], elapsedSeconds: Float) async {
        let frame: NuxieMachineFrame
        var doing = "resize"
        let now = nuxieMachineNow()
        await beforeFrame?(now)
        guard !stopped else {
            frameInFlight = false
            return
        }
        do {
            let drawing = isDrawable
            if drawing { try await applySize() }
            frame = await edge.frame(pointers: pointers, elapsedSeconds: elapsedSeconds, now: now)
            doing = "render"
            if drawing, !stopped { try await draw() }
        } catch {
            frameInFlight = false
            let fault = error as? NuxieMachineEdgeFault
                ?? NuxieMachineEdgeFault(code: "engine.\(doing)", detail: "\(error)")
            stop()
            onFault?(fault)
            return
        }
        frameInFlight = false
        await onFrame?(frame)
        rest(after: frame)
    }

    /// Rest unless something asks for another frame.
    private func rest(after frame: NuxieMachineFrame) {
        guard !stopped else { return }
        let onScreen = isDrawable
        let another = frame.waitsOnStore || frameRequested || !pendingPointers.isEmpty
            || (onScreen && (frame.keepGoing || frame.wrote))
        displayLink?.isPaused = !another
        if !another { lastTimestamp = nil }
    }

    /// Whether this Screen is in a window of a scene in the foreground,
    /// with a size.
    private var isDrawable: Bool {
        guard let scene = surface.window?.windowScene,
              scene.activationState == .foregroundActive || scene.activationState == .foregroundInactive
        else { return false }
        return surface.bounds.width > 0 && surface.bounds.height > 0
            && surface.displayScale.isFinite && surface.displayScale > 0
    }

    /// Lay the Screen out at the view's size and size the renderer to its
    /// pixels when either changed, before the step that lays it out. The
    /// sizes follow the SDK's Screen: pixels are the points times the scale,
    /// rounded up, and the layout size is the pixels over the scale.
    private func applySize() async throws {
        let scale = surface.displayScale
        let size = Size(pixelWidth: Self.pixels(surface.bounds.width, scale),
                        pixelHeight: Self.pixels(surface.bounds.height, scale), scale: Float(scale))
        guard size != appliedSize else { return }
        let runtime = edge.runtime
        if !deviceConfigured {
            let device = try await runtime.metalDevice().value
            let layer = surface.metalLayer
            layer.device = device
            layer.pixelFormat = .bgra8Unorm
            layer.framebufferOnly = true
            layer.maximumDrawableCount = 3
            layer.allowsNextDrawableTimeout = true
            layer.presentsWithTransaction = false
            deviceConfigured = true
        }
        try await runtime.setLayoutSize(width: Float(size.pixelWidth) / size.scale,
                                        height: Float(size.pixelHeight) / size.scale)
        let outcome = try await runtime.resize(pixelWidth: size.pixelWidth, pixelHeight: size.pixelHeight)
        try Self.requireHealthy(outcome, doing: "resize")
        surface.metalLayer.drawableSize = CGSize(width: Int(size.pixelWidth), height: Int(size.pixelHeight))
        appliedSize = size
    }

    /// Draw the Screen as the last step left it, and wait for the GPU.
    private func draw() async throws {
        guard let size = appliedSize else { return }
        guard let drawable = surface.metalLayer.nextDrawable() else {
            // No drawable this tick: ask for another frame to draw it.
            frameRequested = true
            return
        }
        let completion = NuxieMachineFrameCompletion()
        let outcome = try await edge.runtime.render(
            layoutScaleFactor: size.scale, drawable: .available(NuxieNativeDrawable(drawable)),
            completion: { completion.fire() })
        await completion.wait()
        try Self.requireHealthy(outcome, doing: "render")
        if outcome.disposition == .presented {
            framesDrawn += 1
            if framesDrawn == 1 { updateAccessibility() }
        } else {
            frameRequested = true
        }
    }

    private func updateAccessibility() {
        surface.accessibilityValue = framesDrawn > 0 ? statusText : "loading"
    }

    private static func requireHealthy(_ outcome: NuxieNativeRendererOutcome, doing what: String) throws {
        guard outcome.health == .healthy else {
            throw NuxieMachineEdgeFault(code: "engine.\(what)", detail: "the renderer reported \(outcome.health)")
        }
    }

    private static func pixels(_ points: CGFloat, _ scale: CGFloat) -> UInt32 {
        guard points.isFinite, scale.isFinite, points > 0, scale > 0 else { return 0 }
        let value = ceil(Double(points * scale))
        return value < Double(UInt32.max) ? UInt32(value) : UInt32.max
    }
}

/// Milliseconds since the Unix epoch, the clock the machine reads.
func nuxieMachineNow() -> Int64 {
    Int64((Date().timeIntervalSince1970 * 1000).rounded(.down))
}

/// The display link's target, holding the controller weakly so the link
/// does not keep it alive.
@MainActor
private final class DisplayLinkTarget: NSObject {
    private weak var controller: NuxieMachineScreenViewController?

    init(_ controller: NuxieMachineScreenViewController) {
        self.controller = controller
    }

    @objc func tick(_ link: CADisplayLink) {
        controller?.tick(at: link.targetTimestamp)
    }
}

/// The renderer's completion for one frame, called once from any thread,
/// awaited by the frame that drew it.
private final class NuxieMachineFrameCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var waiting: CheckedContinuation<Void, Never>?

    func fire() {
        let resume = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            fired = true
            defer { waiting = nil }
            return waiting
        }
        resume?.resume()
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now = lock.withLock { () -> Bool in
                if fired { return true }
                waiting = continuation
                return false
            }
            if now { continuation.resume() }
        }
    }
}
#endif
