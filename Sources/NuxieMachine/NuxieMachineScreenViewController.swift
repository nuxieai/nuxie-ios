#if os(iOS) && !targetEnvironment(macCatalyst)
import Metal
import NuxieRuntime
import QuartzCore
import UIKit

/// One native presentation of what an edge shows: the Metal surface the
/// engine draws one presentation's Screen into, presented as a sheet or a
/// cover and filling it to every edge. It is made for one presentation and
/// lives as long as that presentation does, so nothing of one presentation
/// reaches another: a route shown again is a new presentation and gets a
/// new controller.
///
/// What it draws is the edge's Screen for its presentation
/// ([`NuxieMachineEdge.screen(for:)`]), at each frame of the loop it belongs
/// to ([`NuxieMachineScreenLoop`]). Once the edge no longer shows that
/// presentation it draws nothing more, so a Screen leaving the screen keeps
/// its last frame and never shows the presentation that replaced it. The
/// Screen is laid out by the engine at its surface's size, as the SDK's
/// Screens are, and drawn at the display's scale. Where it is shown (its
/// surface's safe-area insets and size) is its place ([`place`]), which the
/// presenter tells the session.
@MainActor
package final class NuxieMachineScreenViewController: UIViewController {
    /// The presentation this controller shows.
    package let presented: NuxieMachinePresented
    package var shown: NuxieMachineShown { presented.shown }

    /// What the host knows about the record, as the accessibility value of
    /// this Screen's view once its first frame is drawn, followed by how
    /// many frames have been drawn. The view is no element of its own: a
    /// check finds it by its identifier, and a screen reader reads only the
    /// Screen's lines and buttons.
    package var statusText = "" {
        didSet { updateAccessibility() }
    }

    /// Whether a screen reader can reach this Screen: false while another
    /// presentation is over it, from the moment that one starts to arrive.
    /// The Screen under a sheet keeps its elements, hidden, so its place is
    /// kept for when the sheet has gone, and none of them takes an action
    /// until then.
    package var reachable = true {
        didSet { viewIfLoaded?.accessibilityElementsHidden = !reachable }
    }

    /// Frames drawn to the screen.
    package private(set) var framesDrawn = 0

    /// Told when the session's environment would change with this Screen's
    /// traits: its colors (the phone turned dark or light, or a style was
    /// forced on it or lifted) or the person's text size. The presenter
    /// reads the session's environment again then.
    package var onEnvironmentChange: (@MainActor () -> Void)?

    /// Pointers that arrived and wait for the next frame.
    fileprivate var pointers: [NuxieNativePointerEvent] = []
    /// A screen reader's tap that waits for the next frame ([`activate`]).
    /// At most one: a tap is asked of the snapshot shown now, and queuing it
    /// spends that snapshot, so a second activation of the same snapshot is
    /// refused and one of a newer snapshot replaces it (the engine would
    /// refuse the older one anyway).
    fileprivate var semanticTap: NuxieMachineSemanticTap?
    /// The size the engine lays this presentation's Screen out at and draws,
    /// once applied.
    fileprivate var sized: Size?
    /// The size the last frame that reached the screen was drawn at.
    private var drawnAt: Size?

    private weak var loop: NuxieMachineScreenLoop?
    private let surface = NuxieMachineSurfaceView()
    private let container = UIView()
    /// The Screen's lines and buttons, as its surface's accessibility
    /// elements: the engine's semantic snapshot of each frame drawn, shown
    /// the way every Screen the engine draws shows it.
    private lazy var semantics = ExperienceSemanticAccessibilityContainer(view: surface)
    /// The snapshot the elements show now; an activation acts on it only.
    private var latest: NuxieNativeSemanticCapture?
    /// Whether the surface's layer has been given the engine's Metal device,
    /// which every Screen the engine opens shares.
    private var deviceConfigured = false

    fileprivate struct Size: Equatable {
        let pixelWidth: UInt32
        let pixelHeight: UInt32
        let scale: Float
    }

    /// A controller for `presented`, whose frames `loop` runs. How it is
    /// presented is set here, once:
    ///
    /// - A cover: full screen, which has no swipe.
    /// - A sheet: a page sheet at the large detent with no grabber, which
    ///   the person can swipe down (the native close). Over a `scroll`, a
    ///   drag stays with the page unless it is downward with the page at
    ///   its top ([`NuxieMachineSheetPan`]).
    ///
    /// Either way the Screen fills what it is presented in, to every edge,
    /// under the status bar and the home indicator where they reach it, and
    /// is told that presentation's insets so its page keeps its content
    /// clear of them ([`place`]). A sheet's top inset is 0, as the sheet
    /// starts below the status bar; its bottom is the home indicator's.
    ///
    /// Any presentation other than a cover is presented as a sheet; the
    /// presenter refuses the others before they get here.
    package init(presenting presented: NuxieMachinePresented, loop: NuxieMachineScreenLoop) {
        self.presented = presented
        self.loop = loop
        super.init(nibName: nil, bundle: nil)
        let covers = presented.presentation == .cover
        modalPresentationStyle = covers ? .fullScreen : .pageSheet
        isModalInPresentation = covers
        if !covers, let sheet = sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = false
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override package func loadView() {
        container.accessibilityIdentifier = "nuxie-machine-screen"
        container.accessibilityLabel = "Screen"
        container.accessibilityElementsHidden = !reachable
        surface.isAccessibilityElement = false
        semantics.setActive(true)
        surface.onPointers = { [weak self] pointers in
            guard let self, let loop = self.loop, !loop.stopped else { return }
            self.pointers += pointers
            loop.requestFrame()
        }
        surface.onGeometryChange = { [weak self] in self?.loop?.requestFrame() }
        surface.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(surface)
        view = container
        // The surface reaches every edge of what the Screen is presented
        // in, a cover's screen or a sheet; its place is the safe-area insets
        // that gives it.
        container.backgroundColor = .clear
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            surface.topAnchor.constraint(equalTo: container.topAnchor),
            surface.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        updateAccessibility()
    }

    override package func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        let colors = traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection)
        let textSize = traitCollection.preferredContentSizeCategory
            != previousTraitCollection?.preferredContentSizeCategory
        guard colors || textSize else { return }
        onEnvironmentChange?()
    }

    /// The safe area changed with no change of size (the status bar came or
    /// went): the place is read again before the next frame, as a change of
    /// size or rotation reads it through the surface's geometry.
    override package func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        loop?.requestFrame()
    }

    /// Where this Screen is shown, as the session is told it: its surface's
    /// safe-area insets and the size the engine lays it out at. The surface
    /// fills what it is presented in, so its insets are that presentation's:
    /// a cover's the screen's, a sheet's the sheet's own as UIKit gives
    /// them. None until the surface is in a window with a size.
    package var place: NuxieMachineScreenPlace? {
        guard let size = measured else { return nil }
        let insets = surface.safeAreaInsets
        return NuxieMachineScreenPlace(
            top: Double(insets.top), right: Double(insets.right), bottom: Double(insets.bottom),
            left: Double(insets.left), width: Double(size.pixelWidth) / Double(size.scale),
            height: Double(size.pixelHeight) / Double(size.scale))
    }

    /// What the surface is and what it last drew, read now, for checks.
    package var surfaceFacts: NuxieMachineSurfaceFacts {
        let layer = surface.metalLayer
        return NuxieMachineSurfaceFacts(
            bounds: surface.bounds.size, place: place, drawableSize: layer.drawableSize,
            contentsScale: layer.contentsScale,
            drawn: drawnAt.map { CGSize(width: Int($0.pixelWidth), height: Int($0.pixelHeight)) })
    }

    /// Whether this Screen's view is in a window, with a size: what the
    /// engine lays it out at.
    fileprivate var hasSize: Bool {
        surface.window != nil && surface.bounds.width > 0 && surface.bounds.height > 0
            && surface.displayScale.isFinite && surface.displayScale > 0
    }

    /// Whether this Screen is in a window of a scene in the foreground,
    /// with a size: whether it is drawn.
    fileprivate var isDrawable: Bool {
        guard hasSize, let scene = surface.window?.windowScene,
              scene.activationState == .foregroundActive || scene.activationState == .foregroundInactive
        else { return false }
        return true
    }

    /// The surface's size in pixels and the scale it is drawn at, while it
    /// has a size ([`hasSize`]). The sizes follow the SDK's Screen: pixels
    /// are the points times the scale, rounded up, and the layout size is
    /// the pixels over the scale.
    private var measured: Size? {
        guard hasSize else { return nil }
        let scale = surface.displayScale
        return Size(pixelWidth: Self.pixels(surface.bounds.width, scale),
                    pixelHeight: Self.pixels(surface.bounds.height, scale), scale: Float(scale))
    }

    /// Lay the Screen out at its surface's size and size the renderer to
    /// its pixels ([`measured`]), before the step that lays it out: at its
    /// first frame, and again whenever the surface's size changes.
    fileprivate func applySize(_ runtime: NuxieNativeRuntime) async throws {
        guard let size = measured, sized != size else { return }
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
        sized = size
    }

    /// Draw the Screen as the last step left it, and wait for the GPU.
    /// Whether it reached the screen: false when it needs another frame.
    ///
    /// The Screen is read again with every frame drawn: the frame's step
    /// settled every write the machine made, its settle passes included, so
    /// the snapshot taken with the frame is what the frame shows ([`show`]).
    fileprivate func draw(_ runtime: NuxieNativeRuntime) async throws -> Bool {
        guard let size = sized else { return true }
        guard let drawable = surface.metalLayer.nextDrawable() else { return false }
        let completion = NuxieMachineFrameCompletion()
        let frame = try await runtime.renderFrame(
            layoutScaleFactor: size.scale, drawable: .available(NuxieNativeDrawable(drawable)),
            capturesSemantics: true, completion: { completion.fire() })
        await completion.wait()
        try Self.requireHealthy(frame.outcome, doing: "render")
        guard frame.outcome.disposition == .presented else { return false }
        framesDrawn += 1
        drawnAt = size
        updateAccessibility()
        if let semantics = frame.semantics { show(semantics) }
        return true
    }

    /// Show `capture`, the semantic snapshot of a frame this Screen drew,
    /// as its surface's accessibility elements, in the order it is read:
    /// each line as static text, each button as a button named by the words
    /// beneath it, each where the frame drew it. An element the frame no
    /// longer has goes; one it still has is the same element, read anew.
    /// When elements appear, go or move, the reader is told the layout
    /// changed.
    package func show(_ capture: NuxieNativeSemanticCapture) {
        latest = capture
        // A sheet's swipe asks the surface about the scroll regions of the
        // frame on screen ([`NuxieMachineSheetPan`]).
        surface.scrollRegions = capture.scrollRegions
        semantics.update(capture: capture, nativeControls: [:], project: { [surface] node in
            Self.projection(for: node, on: surface.bounds)
        }, submit: { [weak self] captureID, nodeID, action in
            self?.activate(nodeID, in: captureID, action) ?? false
        })
    }

    /// How a machine Screen whose surface has `bounds` shows `node`, or none
    /// for a node no element stands for: one with no role UIKit reads, or
    /// one drawn nowhere on the surface. A button or a link takes a tap when
    /// its node offers one. The engine offers none for a disabled button or
    /// one a `scroll` clips wholly away; such a node is still read, and its
    /// activation answers false. A radio is a button, selected while its
    /// check state is checked; one not checked, or mixed, is not selected.
    package static func projection(
        for node: NuxieNativeSemanticNode,
        on bounds: CGRect
    ) -> ExperienceSemanticAccessibilityContainer.Projection? {
        guard var traits = ExperienceSemanticAccessibilityContainer.traits(for: node) else { return nil }
        // The artboard is laid out at the surface's size with its origin
        // at zero: a point on it is the same point on the surface.
        let frame = node.bounds.intersection(bounds)
        guard !frame.isNull, !frame.isInfinite, !frame.isEmpty else { return nil }
        if node.role == NuxieNativeSemanticRole.radioButton.rawValue,
           node.stateFlags & checkState == NuxieNativeSemanticNode.checked {
            traits.insert(.selected)
        }
        let presses = traits.contains(.button) || traits.contains(.link)
        let tap: UInt32 = 1 << NuxieNativeSemanticAction.tap.rawValue
        return .init(frame: frame, traits: traits, value: node.value.isEmpty ? nil : node.value,
                     actions: presses ? node.actions & tap : 0)
    }

    /// The engine's check state: two bits of a node's state, unchecked,
    /// checked (`NuxieNativeSemanticNode.checked`) or mixed
    /// (`NuxieNativeSemanticNode.mixed`).
    private static let checkState = NuxieNativeSemanticNode.checked | NuxieNativeSemanticNode.mixed

    /// Activating an element is the node's own semantic tap, never a touch
    /// at a point: the tap waits for the next frame, which queues it on the
    /// player before it steps ([`NuxieMachineEdge.frame`]), so the listener
    /// that hears a press hears it once, for this node, whatever is drawn at
    /// its place. An element whose node offers no tap never gets here (it
    /// refuses), nor does an activation of a snapshot already replaced, nor
    /// one while this Screen is out of reach or its loop has stopped. A
    /// snapshot takes one tap ([`semanticTap`]).
    private func activate(_ nodeID: UInt32, in captureID: UUID, _ action: NuxieNativeSemanticAction) -> Bool {
        guard reachable, action == .tap, let loop, !loop.stopped, let capture = latest, capture.id == captureID,
              capture.tree.nodes.contains(where: { $0.id == nodeID }),
              semanticTap?.captureID != captureID else { return false }
        semanticTap = NuxieMachineSemanticTap(captureID: captureID, nodeID: nodeID)
        loop.requestFrame()
        return true
    }

    /// The pointers that arrived for this Screen since the last frame took
    /// them, oldest first; the next frame carries them.
    package func takePointers() -> [NuxieNativePointerEvent] {
        defer { pointers = [] }
        return pointers
    }

    /// The screen reader's tap waiting for this Screen, if any, as the list
    /// the edge takes; the next frame carries it beside the pointers
    /// ([`takePointers`]).
    package func takeSemanticTaps() -> [NuxieMachineSemanticTap] {
        defer { semanticTap = nil }
        return semanticTap.map { [$0] } ?? []
    }

    /// Whether input waits for the next frame: pointers or a tap.
    fileprivate var hasInput: Bool { !pointers.isEmpty || semanticTap != nil }

    private func updateAccessibility() {
        container.accessibilityValue = framesDrawn > 0 ? "\(statusText) Frames drawn: \(framesDrawn)." : "loading"
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

/// A Screen's surface as it is and as it last drew, for checks: its bounds
/// in points, its place as the session is told it ([`place`], none before
/// it has a size), its Metal layer's drawable size in pixels and its scale,
/// and the pixel size of the last frame that reached the screen (none
/// before the first). After a change of size, the drawable is the bounds
/// times the scale, rounded up, and the next frame drawn is that size.
package struct NuxieMachineSurfaceFacts: Equatable, Sendable {
    package let bounds: CGSize
    package let place: NuxieMachineScreenPlace?
    package let drawableSize: CGSize
    package let contentsScale: CGFloat
    package let drawn: CGSize?
}

/// The display loop that runs one edge's frames and draws every native
/// presentation of it ([`screens`]).
///
/// Each display tick is one frame: the pointers and the screen reader's tap
/// that arrived, with the presentation they touched (the edge drops them
/// when it no longer shows it), the edge's frame (each presentation's engine
/// step, which carries the machine, and the store's answers), then a draw of
/// each Screen the frame stepped. Frames run in the loop's lane ([`inLane`]),
/// where the owner makes its own calls to the edge, so the edge hears a
/// frame, a wake and a close in the order they were asked for. One frame is
/// in flight at a time, and a frame's draws wait for the GPU, so a frame
/// never starts before the last one is on screen.
///
/// The loop rests when nothing asks for a frame. The edge asks for one
/// whenever it leaves work only a frame consumes (a step owed, a store's
/// answer to deliver), wherever that work came from: a frame, a wake, a
/// close, a start or the store ([`NuxieMachineEdge.frameAsks`]). The views
/// ask for their own reasons: a touch, a new size, coming back to the
/// foreground, a drawable not got, and on screen the engine's step saying it
/// needs another. The loop keeps no record of the edge's work. With nothing
/// on screen (every presentation gone, or the scene in the background), it
/// draws nothing and runs frames only when the edge asks, so rows that
/// arrive after the last presentation is gone are still delivered.
@MainActor
package final class NuxieMachineScreenLoop {
    /// The edge this loop runs frames for. It owns the session.
    package let edge: NuxieMachineEdge

    /// Told before each frame with the moment the frame runs at, so the
    /// owner can deliver what is due by then first (a wake the machine asked
    /// for at an earlier moment).
    package var beforeFrame: (@MainActor (Int64) async -> Void)?
    /// Told after each frame, once its turn is over and its draws are done.
    package var onFrame: (@MainActor (NuxieMachineFrame) async -> Void)?
    /// Told once when drawing fails; the loop has stopped by then.
    package var onFault: (@MainActor (NuxieMachineEdgeFault) -> Void)?
    /// The moment each frame runs at: the wall clock, unless the owner
    /// reads the machine's clock from elsewhere.
    package var clock: @MainActor () -> Int64 = { nuxieMachineNow() }

    /// The native presentations the loop draws, bottom first, as the owner
    /// holds them.
    package var screens: [NuxieMachineScreenViewController] = [] {
        didSet { requestFrame() }
    }

    package private(set) var stopped = false
    // Touched off the main actor only by `deinit`, after every other use.
    private nonisolated(unsafe) var displayLink: CADisplayLink?
    private var frameInFlight = false
    private var frameRequested = true
    /// Whether the lane is held, and the calls waiting for it in order.
    private var laneHeld = false
    private var laneWaiting: [CheckedContinuation<Void, Never>] = []
    /// The display time of the last frame; none after a rest, so the frame
    /// that wakes the loop advances by zero, not by the time it rested.
    private var lastTimestamp: CFTimeInterval?
    // Touched off the main actor only by `deinit`, after every other use.
    private nonisolated(unsafe) var notificationTokens: [NSObjectProtocol] = []

    package init(edge: NuxieMachineEdge) {
        self.edge = edge
        edge.frameAsks.listen { [weak self] in
            Task { @MainActor in self?.requestFrame() }
        }
    }

    deinit {
        displayLink?.invalidate()
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
    }

    /// Start the display loop. The first frame steps each Screen as the
    /// machine has written it so far and draws it once its view has a size.
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

    /// Ask for a frame. Every ask the edge makes comes here.
    package func requestFrame() {
        guard !stopped else { return }
        frameRequested = true
        displayLink?.isPaused = false
    }

    /// Run `body` holding the loop's lane, after every call asked for
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
        for screen in screens {
            screen.pointers = []
            screen.semanticTap = nil
        }
    }

    // MARK: Frames

    fileprivate func tick(at timestamp: CFTimeInterval) {
        guard !stopped, !frameInFlight else { return }
        frameRequested = false
        frameInFlight = true
        // The pointers and the screen reader's tap go with the presentation
        // they touched, the top one that has any; the rest wait for the next
        // frame. The frame's wakes run first and may end it, and the edge
        // then drops them.
        let touching = screens.last { $0.hasInput }
        let touched = touching?.shown
        let pointers = touching?.takePointers() ?? []
        let semanticTaps = touching?.takeSemanticTaps() ?? []
        let elapsed = lastTimestamp.map { Float(max(0, timestamp - $0)) } ?? 0
        lastTimestamp = timestamp
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.inLane {
                await self.runFrame(pointers: pointers, semanticTaps: semanticTaps, touched: touched,
                                    elapsedSeconds: elapsed)
            }
        }
    }

    private func runFrame(pointers: [NuxieNativePointerEvent], semanticTaps: [NuxieMachineSemanticTap],
                          touched: NuxieMachineShown?, elapsedSeconds: Float) async {
        let frame: NuxieMachineFrame
        var doing = "resize"
        let now = clock()
        await beforeFrame?(now)
        guard !stopped else {
            frameInFlight = false
            return
        }
        var drawing = false
        do {
            // Each presentation's Screen this frame steps, sized before the
            // step lays it out whenever its view has a size, drawn only when
            // it is on screen.
            var stepped: [(screen: NuxieMachineScreenViewController, runtime: NuxieNativeRuntime)] = []
            for screen in screens where screen.hasSize {
                guard let runtime = await edge.screen(for: screen.shown) else { continue }
                try await screen.applySize(runtime)
                stepped.append((screen, runtime))
            }
            frame = await edge.frame(pointers: pointers, semanticTaps: semanticTaps, on: touched,
                                     elapsedSeconds: elapsedSeconds, now: now)
            doing = "render"
            for (screen, runtime) in stepped where screen.isDrawable && !stopped {
                drawing = true
                // A delivery in the frame may have ended the presentation:
                // only the Screen the frame sized and stepped is drawn.
                let after = await edge.screen(for: screen.shown)
                if let after, after === runtime {
                    let drawn = try await screen.draw(after)
                    if !drawn { frameRequested = true }
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
        rest(after: frame, drawing: drawing)
    }

    /// Rest unless something asks for another frame: an ask since this
    /// frame began (the edge's or a view's own), a pointer or a screen
    /// reader's tap waiting, or on screen the engine's step.
    private func rest(after frame: NuxieMachineFrame, drawing: Bool) {
        guard !stopped else { return }
        let input = screens.contains { $0.hasInput }
        let another = frameRequested || input || (drawing && frame.keepGoing)
        displayLink?.isPaused = !another
        if !another { lastTimestamp = nil }
    }
}

/// Milliseconds since the Unix epoch, the clock the machine reads.
func nuxieMachineNow() -> Int64 {
    Int64((Date().timeIntervalSince1970 * 1000).rounded(.down))
}

/// The display link's target, holding the loop weakly so the link does not
/// keep it alive.
@MainActor
private final class DisplayLinkTarget: NSObject {
    private weak var loop: NuxieMachineScreenLoop?

    init(_ loop: NuxieMachineScreenLoop) {
        self.loop = loop
    }

    @objc func tick(_ link: CADisplayLink) {
        loop?.tick(at: link.targetTimestamp)
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
