#if os(iOS) && !targetEnvironment(macCatalyst)
import Metal
import NuxieRuntime
import QuartzCore
import UIKit

/// Hosts the one Screen a [`NuxieMachineEdge`] drives: the Metal surface the
/// engine draws into and the display link that runs the edge's frames. What
/// it draws is the edge's Screen for the presentation it was configured for
/// ([`NuxieMachineEdge.screen(for:)`]) at each frame: the published Screen,
/// or the player of the presented instance's compiled view, which changes
/// with each presentation. Once a row has ended that presentation it draws
/// nothing more, so a Screen leaving the screen keeps its last frame and
/// never shows the presentation that replaced it.
///
/// Each display tick is one frame: the pointers that arrived, each batch
/// with the presentation it touched (the edge drops a batch whose
/// presentation is no longer the one presented), the edge's
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

    /// Everything that belongs to one presentation of the Screen, in one
    /// value: made whole by [`configure`] before UIKit presents the Screen,
    /// and dropped whole once UIKit has dismissed it. Nothing of a
    /// presentation is kept anywhere else in the controller, so nothing of
    /// one can survive into the next by being forgotten; what outlives a
    /// presentation (the lane, the loop, the edge and the view) is kept
    /// outside it.
    private struct Presented {
        /// The edge's presentation this one shows.
        let shown: NuxieMachineShown
        /// How the Screen is presented: a sheet or a cover.
        let style: NuxieMachinePresentation
        /// Pointers that arrived and wait for the next frame.
        var pointers: [NuxieNativePointerEvent] = []
        /// Frames drawn to the screen.
        var framesDrawn = 0
        /// The size the engine lays this presentation's Screen out at and
        /// draws, once applied. One presentation draws one Screen, so the
        /// size alone says what was done; nothing names the Screen.
        var sized: Size?
    }

    /// The presentation under way, from its [`configure`] until UIKit has
    /// dismissed it.
    private var presented: Presented?

    /// Frames drawn in the presentation under way.
    package var framesDrawn: Int { presented?.framesDrawn ?? 0 }

    /// How the Screen is presented now, while a presentation is under way.
    package var presentation: NuxieMachinePresentation? { presented?.style }

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
    private var frameInFlight = false
    private var frameRequested = true
    private var stopped = false
    /// Whether the lane is held, and the calls waiting for it in order.
    private var laneHeld = false
    private var laneWaiting: [CheckedContinuation<Void, Never>] = []
    /// The display time of the last frame; none after a rest, so the frame
    /// that wakes the loop advances by zero, not by the time it rested.
    private var lastTimestamp: CFTimeInterval?
    /// Whether the surface's layer has been given the engine's Metal device,
    /// which every Screen the engine opens shares.
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
            // A pointer belongs to the presentation it touched; with none
            // under way it goes to no one.
            guard let self, !self.stopped, self.presented != nil else { return }
            self.presented?.pointers += pointers
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

    /// Begin one presentation, the edge's `shown`, before UIKit presents the
    /// Screen: a new
    /// [`Presented`] replaces whatever was there, whole, and the controller
    /// is set up for its style. A record keeps one Screen controller for its
    /// whole life (its lane and its loop outlive every presentation, and run
    /// with none), so the same controller is presented again, in either
    /// style; a presentation starts from nothing each time. Until its Screen
    /// draws its first frame, the accessibility value says "loading".
    package func configure(for presentation: NuxieMachinePresentation, showing shown: NuxieMachineShown) {
        presented = Presented(shown: shown, style: presentation)
        updateAccessibility()
        applyStyle()
    }

    /// The presentation is over once UIKit has dismissed the Screen, by the
    /// presenter or by the person's swipe: everything of it goes, whole.
    override package func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed { presented = nil }
    }

    /// Everything that depends on how the Screen is presented, set from the
    /// presentation under way: the one place each of these is decided, read
    /// when the view loads and again at every [`configure`]. With no
    /// presentation under way nothing is laid out. Any style other than a
    /// cover is laid out as a sheet; the presenter refuses the others before
    /// they get here.
    ///
    /// - A cover: full screen, which has no swipe; the Screen in the safe
    ///   area over a black ground, since a view's safe areas do not reach
    ///   the engine yet.
    /// - A sheet: a page sheet at the large detent with no grabber, which
    ///   the person can swipe down (the native close); the Screen across
    ///   the whole sheet over no ground.
    private func applyStyle() {
        guard let style = presented?.style else { return }
        let covers = style == .cover
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
        presented?.pointers = []
    }

    // MARK: Frames

    fileprivate func tick(at timestamp: CFTimeInterval) {
        guard !stopped, !frameInFlight else { return }
        frameRequested = false
        frameInFlight = true
        // The pointers go with the presentation they touched. The frame's
        // wakes run first and may end it, and the edge then drops them.
        let touched = presented?.shown
        let pointers = presented?.pointers ?? []
        presented?.pointers = []
        let elapsed = lastTimestamp.map { Float(max(0, timestamp - $0)) } ?? 0
        lastTimestamp = timestamp
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.inLane {
                await self.runFrame(pointers: pointers, touched: touched, elapsedSeconds: elapsed)
            }
        }
    }

    private func runFrame(pointers: [NuxieNativePointerEvent], touched: NuxieMachineShown?,
                          elapsedSeconds: Float) async {
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
            // The presentation's Screen this frame steps, sized before the
            // step lays it out whenever its view has a size, drawn only when
            // it is on screen.
            let showing = presented?.shown
            var screen: NuxieNativeRuntime?
            if hasSize, let showing { screen = await edge.screen(for: showing) }
            if let screen, let showing { try await applySize(screen, for: showing) }
            frame = await edge.frame(pointers: pointers, on: touched, elapsedSeconds: elapsedSeconds, now: now)
            doing = "render"
            if drawing, !stopped, let showing {
                // A delivery in the frame may have ended the presentation:
                // only the Screen the frame sized and stepped is drawn.
                let after = await edge.screen(for: showing)
                if let after, after === screen {
                    try await draw(after, for: showing)
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
        let pointers = !(presented?.pointers.isEmpty ?? true)
        let another = frameRequested || pointers || (isDrawable && frame.keepGoing)
        displayLink?.isPaused = !another
        if !another { lastTimestamp = nil }
    }

    /// Whether this Screen's view is in a window, with a size: what the
    /// engine lays it out at.
    private var hasSize: Bool {
        surface.window != nil && surface.bounds.width > 0 && surface.bounds.height > 0
            && surface.displayScale.isFinite && surface.displayScale > 0
    }

    /// Whether this Screen is in a window of a scene in the foreground,
    /// with a size: whether it is drawn.
    private var isDrawable: Bool {
        guard hasSize, let scene = surface.window?.windowScene,
              scene.activationState == .foregroundActive || scene.activationState == .foregroundInactive
        else { return false }
        return true
    }

    /// Lay the presentation's Screen out at the view's size and size the
    /// renderer to its pixels, before the step that lays it out: at its
    /// first frame, and again whenever the view's size changes. The sizes
    /// follow the SDK's Screen: pixels are the points times the scale,
    /// rounded up, and the layout size is the pixels over the scale. Only
    /// the presentation `showing` is sized, while it is the one under way.
    private func applySize(_ runtime: NuxieNativeRuntime, for showing: NuxieMachineShown) async throws {
        let scale = surface.displayScale
        let size = Size(pixelWidth: Self.pixels(surface.bounds.width, scale),
                        pixelHeight: Self.pixels(surface.bounds.height, scale), scale: Float(scale))
        guard let current = presented, current.shown == showing, current.sized != size else { return }
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
        if presented?.shown == showing { presented?.sized = size }
    }

    /// Draw the Screen as the last step left it, and wait for the GPU.
    private func draw(_ runtime: NuxieNativeRuntime, for showing: NuxieMachineShown) async throws {
        guard let current = presented, current.shown == showing, let size = current.sized else { return }
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
            if presented?.shown == showing { presented?.framesDrawn += 1 }
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
