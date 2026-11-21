#if os(iOS) && !targetEnvironment(macCatalyst)
import Metal
import NuxieRuntime
import QuartzCore
import UIKit

/// Hosts the one Screen a [`NuxieMachineEdge`] drives: the Metal surface the
/// engine draws into and the display link that runs the edge's frames. What
/// it draws is the edge's [`screen`](NuxieMachineEdge.screen()) at each frame:
/// the published Screen, or the player of the presented instance's compiled
/// view, which changes with each presentation.
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
/// The loop rests when nothing asks for a frame. The edge asks for one
/// whenever it leaves work only a frame consumes (a step owed, a store's
/// answer to deliver), wherever that work came from: a frame, a wake, a
/// close, a start or the store ([`NuxieMachineEdge.frameAsks`]). The view
/// asks for its own reasons: a touch, a new size, coming back to the
/// foreground, a drawable it did not get, and on screen the engine's step
/// saying it needs another. The view keeps no record of the edge's work.
/// Off screen (its sheet gone, or its scene in the background), it draws
/// nothing and runs frames only when the edge asks, so rows that arrive
/// after the sheet is gone are still delivered.
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
    /// value once its first frame is drawn, followed by how many frames have
    /// been drawn. A Screen's own controls have no accessibility elements
    /// yet, so this is the one a check can read.
    package var statusText = "" {
        didSet { updateAccessibility() }
    }

    /// Frames drawn to the screen so far.
    package private(set) var framesDrawn = 0

    /// How the Screen is presented now, as the last [`configure`] said.
    package private(set) var presentation: NuxieMachinePresentation = .sheet

    private let surface = NuxieMachineSurfaceView()
    /// The container's ground and the two ways the surface sits in it: in
    /// the safe area, for a cover, or across the whole view, for a sheet.
    /// Made once with the view; which one is active is [`applyStyle`]'s.
    private let container = UIView()
    private lazy var inSafeArea: [NSLayoutConstraint] = {
        let bounds = container.safeAreaLayoutGuide
        return [
            surface.leadingAnchor.constraint(equalTo: bounds.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: bounds.trailingAnchor),
            surface.topAnchor.constraint(equalTo: bounds.topAnchor),
            surface.bottomAnchor.constraint(equalTo: bounds.bottomAnchor),
        ]
    }()
    private lazy var acrossView: [NSLayoutConstraint] = [
        surface.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        surface.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        surface.topAnchor.constraint(equalTo: container.topAnchor),
        surface.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ]
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
    /// The size the engine lays the Screen out at and draws, once applied,
    /// and the Screen it was applied to.
    private var appliedSize: Size?
    private var sizedScreen: ObjectIdentifier?
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
        edge.frameAsks.listen { [weak self] in
            Task { @MainActor in self?.requestFrame() }
        }
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
        surface.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(surface)
        view = container
        applyStyle()
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

    /// Set this controller up for one presentation, before UIKit presents
    /// it. A record keeps one Screen for its whole life (its lane and its
    /// loop outlive every presentation, and run with none), so the same
    /// controller is presented again, in either style: everything a
    /// presentation decides is set here, for every presentation.
    ///
    /// - Its style ([`applyStyle`]): everything that depends on a sheet or
    ///   a cover. Any other presentation is laid out as a sheet; the
    ///   presenter refuses it before it gets here.
    /// - What belonged to the presentation before: pointers not yet handed
    ///   to a frame are dropped, and the count of frames drawn starts again,
    ///   so the accessibility value says "loading" until this
    ///   presentation's Screen has drawn its first frame.
    package func configure(for presentation: NuxieMachinePresentation) {
        self.presentation = presentation
        pendingPointers = []
        framesDrawn = 0
        updateAccessibility()
        applyStyle()
    }

    /// Everything that depends on how the Screen is presented, set from
    /// [`presentation`]: the one place each of these is decided, read when
    /// the view loads and again at every [`configure`].
    ///
    /// - A cover: full screen, which has no swipe; the Screen in the safe
    ///   area over a black ground, since a view's safe areas do not reach
    ///   the engine yet.
    /// - A sheet: a page sheet at the large detent with no grabber, which
    ///   the person can swipe down (the native close); the Screen across
    ///   the whole sheet over no ground.
    private func applyStyle() {
        let covers = presentation == .cover
        modalPresentationStyle = covers ? .fullScreen : .pageSheet
        isModalInPresentation = covers
        if !covers, let sheet = sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = false
        }
        guard isViewLoaded else { return }
        container.backgroundColor = covers ? .black : .clear
        NSLayoutConstraint.deactivate(covers ? acrossView : inSafeArea)
        NSLayoutConstraint.activate(covers ? inSafeArea : acrossView)
    }

    /// Ask for a frame. Every ask the edge makes comes here.
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
            // The Screen this frame steps, sized before the step lays it out.
            let screen = drawing ? await edge.screen() : nil
            if let screen { try await applySize(screen) }
            frame = await edge.frame(pointers: pointers, elapsedSeconds: elapsedSeconds, now: now)
            doing = "render"
            if drawing, !stopped {
                // A delivery in the frame may have closed the Screen or
                // presented a new one: only the Screen the frame sized and
                // stepped is drawn, and a new one waits for the next frame.
                let after = await edge.screen()
                if let after, after === screen {
                    try await draw(after)
                } else if after != nil {
                    frameRequested = true
                }
            }
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

    /// Rest unless something asks for another frame: an ask since this
    /// frame began (the edge's or the view's own), a pointer, or on screen
    /// the engine's step.
    private func rest(after frame: NuxieMachineFrame) {
        guard !stopped else { return }
        let another = frameRequested || !pendingPointers.isEmpty || (isDrawable && frame.keepGoing)
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
    private func applySize(_ runtime: NuxieNativeRuntime) async throws {
        let scale = surface.displayScale
        let size = Size(pixelWidth: Self.pixels(surface.bounds.width, scale),
                        pixelHeight: Self.pixels(surface.bounds.height, scale), scale: Float(scale))
        let identity = ObjectIdentifier(runtime)
        guard size != appliedSize || identity != sizedScreen else { return }
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
        sizedScreen = identity
    }

    /// Draw the Screen as the last step left it, and wait for the GPU.
    private func draw(_ runtime: NuxieNativeRuntime) async throws {
        guard let size = appliedSize else { return }
        guard let drawable = surface.metalLayer.nextDrawable() else {
            // No drawable this tick: ask for another frame to draw it.
            frameRequested = true
            return
        }
        let completion = NuxieMachineFrameCompletion()
        let outcome = try await runtime.render(
            layoutScaleFactor: size.scale, drawable: .available(NuxieNativeDrawable(drawable)),
            completion: { completion.fire() })
        await completion.wait()
        try Self.requireHealthy(outcome, doing: "render")
        if outcome.disposition == .presented {
            framesDrawn += 1
            updateAccessibility()
        } else {
            frameRequested = true
        }
    }

    private func updateAccessibility() {
        surface.accessibilityValue = framesDrawn > 0 ? "\(statusText) Frames drawn: \(framesDrawn)." : "loading"
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
