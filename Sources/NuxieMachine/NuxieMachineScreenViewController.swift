#if os(iOS) && !targetEnvironment(macCatalyst)
import Metal
import NuxieRuntime
import QuartzCore
import UIKit

/// One page of what an edge shows: the Metal surface the engine draws one
/// presentation's Screen into, a page of a segment
/// ([`NuxieMachineSegmentController`]), the native presentation that holds
/// it, and filling it to every edge. It is made for one presentation and
/// lives as long as that presentation does, so nothing of one presentation
/// reaches another: a route shown again is a new presentation and gets a
/// new controller. How it is presented (its style, a sheet's heights,
/// whether a swipe may take it away) is the segment's; the page carries
/// only its Screen, and what a swipe back from the edge on it does.
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
///
/// A Screen presented before its page's files are in shows the SDK's
/// loading screen over its surface, the moved views of `NuxieRuntime`
/// ([`assets`]): the shimmer at once, then the recovery screen and a close
/// after the delay, or at once when a file fails. Once the files are in,
/// the loading screen stays until the first frame is drawn under it, and
/// then goes, with no fade. While it is up, the sheet that holds the page
/// cannot be swiped away.
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
    /// Covered, it drops what the screen reader asked of it and has not
    /// been sent ([`dropScreenReaderRequests`]): the reader's focus is on
    /// what covers it, and a held tap must not press a node under a sheet.
    package var reachable = true {
        didSet {
            viewIfLoaded?.accessibilityElementsHidden = !reachable
            if !reachable { dropScreenReaderRequests() }
        }
    }

    /// Frames drawn to the screen.
    package private(set) var framesDrawn = 0

    /// What a swipe back from the edge on this page does now, as the
    /// machine last answered it: `nil` for anything not shown as a push.
    /// The presenter sets it from every report ([`follow`]), so it is never
    /// older than the frame on screen, and UIKit's pop recognizer reads it
    /// through the segment when the person starts a swipe from the edge
    /// ([`NuxieMachineSegmentController.popMayBegin()`]).
    package private(set) var swipeBack: NuxieMachineSwipeWould?

    /// Whether the loading screen or the recovery screen holds this page:
    /// while either is up, or before the view loads while the files are
    /// not in. The segment that holds the page reads it: a sheet with a
    /// page that waits cannot be swiped away, since the close is the way
    /// out ([`NuxieMachineModalReason.loading`]).
    package private(set) var waitsForFiles: Bool {
        didSet {
            guard waitsForFiles != oldValue else { return }
            (navigationController as? NuxieMachineSegmentController)?.pageLoadingChanged()
        }
    }

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
    /// What the screen reader asked of this Screen's `scroll`s and is not
    /// done: a reveal of the node it focused, a tap waiting behind it,
    /// pages, a page line to tell, and whether the Screen is at rest
    /// ([`NuxieMachineScreenReaderScrolling`]).
    fileprivate var scrolling = NuxieMachineScreenReaderScrolling()
    /// Whether a snapshot was shown since the last frame ended: the frame
    /// that ends next drew it ([`frameEnded`]).
    private var shownSinceFrame = false
    /// Told when the screen reader's scroll gesture moved a page, with the
    /// argument posted: the page line, "Page n of m". The post itself,
    /// unless a check listens instead.
    package var pageScrolled: (Any?) -> Void = { UIAccessibility.post(notification: .pageScrolled, argument: $0) }
    /// The size the engine lays this presentation's Screen out at and draws,
    /// once applied.
    fileprivate var sized: Size?
    /// The size the last frame that reached the screen was drawn at.
    private var drawnAt: Size?
    /// The color the surface is cleared to before each draw: the
    /// presentation's canvas, as the edge holds it. The loop sets it from
    /// the edge in the same turn it reads the player, before the frame that
    /// sizes, steps and draws it ([`NuxieMachineScreenLoop`]), so no frame
    /// is drawn before it is set. Opaque, so premultiplied and straight are
    /// the same value.
    fileprivate var canvas: UInt32 = 0

    /// Where the files the page draws stand, as the presenter was last told
    /// ([`NuxieMachineAssets`]). A Screen presented with its files in shows
    /// no loading screen. One presented before they are in shows it, and
    /// follows each change until its first frame is drawn:
    ///
    /// - waiting: the shimmer; the recovery screen and the close show once
    ///   the delay has passed, as the SDK's experience screens show them;
    /// - failed: the recovery screen and the close at once, offline only
    ///   when every failed file failed offline;
    /// - ready: the recovery screen and the close go, and the loading screen
    ///   stays until the first frame drawn under it.
    ///
    /// Once its first frame is drawn the loading screen never comes back.
    package var assets: NuxieMachineAssets {
        didSet {
            guard assets != oldValue, isViewLoaded else { return }
            showAssets()
        }
    }

    /// Told when the person taps Try Again on the recovery screen.
    package var onRefresh: (@MainActor () -> Void)?
    /// Told when the person taps the close on the recovery screen.
    package var onExit: (@MainActor () -> Void)?

    /// What shows over the surface.
    private enum Shell {
        /// Nothing: the page is drawn.
        case none
        /// The loading view, with the shimmer.
        case loading
        /// The recovery screen and the close.
        case recovery
    }

    private var shell = Shell.none
    /// How long the shimmer shows before the recovery screen and the close.
    private let recoveryDelay: TimeInterval
    /// The wait for that delay, while one runs.
    private var recoveryReveal: Task<Void, Never>?
    private let loadingView = UIView()
    private let shimmer = ExperienceShellShimmerView()
    private lazy var recovery = ExperienceShellRecoveryView(onRetry: { [weak self] in self?.retry() })
    private let closeControl = ExperienceGlassControl(systemImageName: "xmark", accessibilityLabel: "Close")
    private var palette = ExperienceShellPalette(prefersLightContent: true)

    private weak var loop: NuxieMachineScreenLoop?
    private let surface = NuxieMachineSurfaceView()
    private let container = UIView()
    /// The Screen's lines and buttons, as its surface's accessibility
    /// elements: the engine's semantic snapshot of each frame drawn, shown
    /// the way every Screen the engine draws shows it.
    private lazy var semantics = ExperienceSemanticAccessibilityContainer(
        view: surface, pageScrolled: { [weak self] argument in self?.pageScrolled(argument) })
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

    /// A page for `presented`, whose frames `loop` runs. It fills what it
    /// is shown in, to every edge, under the status bar and the home
    /// indicator where they reach it, and is told those insets so its page
    /// keeps its content clear of them ([`place`]). Inside a segment that is
    /// the segment's: a cover's the screen's, and a sheet's the sheet's own,
    /// whose top inset is 0, as the sheet starts below the status bar, and
    /// whose bottom is the home indicator's. A pushed page gets the insets
    /// of the segment it is pushed in.
    ///
    /// `assets` is where the page's files stand when it is presented, and
    /// `recoveryDelay` how long the shimmer shows before the recovery screen
    /// ([`assets`]).
    package init(presenting presented: NuxieMachinePresented, loop: NuxieMachineScreenLoop,
                 assets: NuxieMachineAssets = .ready, recoveryDelay: TimeInterval = 5.0) {
        self.presented = presented
        self.loop = loop
        self.assets = assets
        self.recoveryDelay = recoveryDelay
        self.swipeBack = presented.swipeBack
        // No swipe down takes a sheet whose page waits for its files: the
        // close is the way out ([`assets`]).
        self.waitsForFiles = assets != .ready
        super.init(nibName: nil, bundle: nil)
    }

    /// Take what the session shows of this presentation now: what a swipe
    /// back from the edge does. The presenter calls it with every report.
    package func follow(_ now: NuxieMachinePresented) {
        guard now.shown == shown, swipeBack != now.swipeBack else { return }
        swipeBack = now.swipeBack
    }

    /// Whether the loading screen holds the page ([`waitsForFiles`]).
    private func holdForLoading(_ held: Bool) {
        waitsForFiles = held
    }

    /// The screen reader's escape (the two-finger Z) on this page: the
    /// gesture it stands for, as the segment that holds the page works it
    /// out ([`NuxieMachineSegmentController.escape(from:)`]); a swipe back
    /// on a pushed page, a swipe down on a sheet, and nothing on a cover's
    /// first page. A page in no segment passes it on.
    override package func accessibilityPerformEscape() -> Bool {
        guard let segment = navigationController as? NuxieMachineSegmentController else { return false }
        return segment.escape(from: self)
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
        surface.onGeometryChange = { [weak self] in
            guard let self else { return }
            // Out of its window the Screen is stepped no more: what the
            // screen reader asked of it goes, so nothing waits for frames.
            if surface.window == nil { dropScreenReaderRequests() }
            loop?.requestFrame()
        }
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
        addShell()
        updateAccessibility()
    }

    // MARK: The loading screen

    /// The loading view with its shimmer, the recovery screen and the close,
    /// over the surface, hidden, each set up and pinned as the SDK's
    /// experience screens set them up; no activity indicator. Then the
    /// loading screen shows when the page is presented before its files are
    /// in.
    private func addShell() {
        loadingView.backgroundColor = .systemBackground
        loadingView.isHidden = true
        loadingView.accessibilityIdentifier = "nuxie-experience-loading-shell"
        loadingView.accessibilityLabel = "Experience loading"
        loadingView.isAccessibilityElement = true
        shimmer.accessibilityIdentifier = "nuxie-experience-shimmer"
        recovery.backgroundColor = .systemBackground
        recovery.isHidden = true
        closeControl.accessibilityIdentifier = "nuxie-experience-close"
        closeControl.isHidden = true
        closeControl.addAction(UIAction { [weak self] _ in self?.onExit?() }, for: .touchUpInside)
        loadingView.addSubview(shimmer)
        container.addSubview(loadingView)
        container.addSubview(recovery)
        container.addSubview(closeControl)
        for view in [loadingView, shimmer, recovery, closeControl] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            loadingView.topAnchor.constraint(equalTo: container.topAnchor),
            loadingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            loadingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            loadingView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            shimmer.topAnchor.constraint(equalTo: loadingView.topAnchor),
            shimmer.leadingAnchor.constraint(equalTo: loadingView.leadingAnchor),
            shimmer.trailingAnchor.constraint(equalTo: loadingView.trailingAnchor),
            shimmer.bottomAnchor.constraint(equalTo: loadingView.bottomAnchor),
            recovery.topAnchor.constraint(equalTo: container.topAnchor),
            recovery.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            recovery.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            recovery.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            closeControl.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 12),
            closeControl.trailingAnchor.constraint(equalTo: container.safeAreaLayoutGuide.trailingAnchor,
                                                   constant: -16),
        ])
        applyPalette()
        switch assets {
        case .ready: break
        case .waiting: showLoading()
        case .failed(let failures): showRecovery(Self.reason(failures))
        }
        holdForLoading(shell != .none)
    }

    /// Follow a change of where the files stand, while the loading screen
    /// is up ([`assets`]).
    private func showAssets() {
        guard shell != .none else { return }
        switch assets {
        case .waiting:
            // Once the delay has shown the recovery screen it stays: the
            // files are still coming, and Try Again is there.
            guard shell != .recovery else { return }
            showLoading()
        case .failed(let failures):
            showRecovery(Self.reason(failures))
        case .ready:
            recoveryReveal?.cancel()
            recoveryReveal = nil
            if framesDrawn > 0 {
                reveal()
            } else {
                showLoading(waitingForRecovery: false)
            }
        }
    }

    /// The loading view with the shimmer running, the recovery screen and
    /// the close hidden; and, unless the files are in, one wait for the
    /// delay, after which the recovery screen and the close show.
    private func showLoading(waitingForRecovery: Bool = true) {
        shell = .loading
        recovery.isHidden = true
        closeControl.isHidden = true
        loadingView.isHidden = false
        shimmer.configure(backgroundColor: .systemBackground, palette: palette,
                          reduceMotion: UIAccessibility.isReduceMotionEnabled)
        container.bringSubviewToFront(loadingView)
        holdForLoading(true)
        guard waitingForRecovery, recoveryReveal == nil else { return }
        let delay = max(0, recoveryDelay)
        recoveryReveal = Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard let self, !Task.isCancelled, self.shell == .loading, self.assets != .ready else { return }
            self.recoveryReveal = nil
            // Nothing has failed yet: the files are only slow.
            self.showRecovery(.unavailable)
        }
    }

    /// The recovery screen for `reason`, with the close over it, in place
    /// of the loading view.
    private func showRecovery(_ reason: ExperienceShellRecoveryReason) {
        recoveryReveal?.cancel()
        recoveryReveal = nil
        shell = .recovery
        shimmer.stopAnimating()
        loadingView.isHidden = true
        recovery.isRetrying = false
        recovery.apply(reason: reason)
        recovery.isHidden = false
        closeControl.isHidden = false
        container.bringSubviewToFront(recovery)
        container.bringSubviewToFront(closeControl)
        holdForLoading(true)
    }

    /// Try Again: the loading view comes back at once with the close hidden,
    /// and the delay starts over, as the SDK's experience screens retry;
    /// then the presenter is told.
    private func retry() {
        showLoading()
        onRefresh?()
    }

    /// The first frame is drawn under the loading screen and the files are
    /// in: the loading screen goes, with no fade, and the route's own swipe
    /// comes back.
    private func reveal() {
        shell = .none
        shimmer.stopAnimating()
        loadingView.isHidden = true
        recovery.isHidden = true
        closeControl.isHidden = true
        holdForLoading(false)
    }

    /// Offline only when every failed file failed offline: one that failed
    /// for another reason is not the connection's.
    private static func reason(_ failures: [NuxieMachineAssetFailure]) -> ExperienceShellRecoveryReason {
        failures.allSatisfy { $0.reason == .offline } ? .offline : .unavailable
    }

    /// The loading screen's colors from its ground: the system background in
    /// this Screen's own traits, the scheme the presenter forces on it.
    private func applyPalette() {
        let ground = UIColor.systemBackground.resolvedColor(with: traitCollection)
        palette = ExperienceShellPalette(backgroundCandidates: [ground])
        recovery.apply(palette)
        closeControl.apply(palette)
        if shell == .loading {
            shimmer.configure(backgroundColor: .systemBackground, palette: palette,
                              reduceMotion: UIAccessibility.isReduceMotionEnabled)
        }
    }

    override package func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        let colors = traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection)
        let textSize = traitCollection.preferredContentSizeCategory
            != previousTraitCollection?.preferredContentSizeCategory
        if colors, isViewLoaded { applyPalette() }
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
            clearColor: canvas, capturesSemantics: true, completion: { completion.fire() })
        await completion.wait()
        try Self.requireHealthy(frame.outcome, doing: "render")
        guard frame.outcome.disposition == .presented else { return false }
        framesDrawn += 1
        drawnAt = size
        if shell != .none, assets == .ready { reveal() }
        updateAccessibility()
        if let semantics = frame.semantics { show(semantics) }
        // A sheet that rests at its content's height reads it from the
        // page on top.
        if let segment = navigationController as? NuxieMachineSegmentController, segment.fitsContent,
           segment.topViewController === self {
            segment.measured(contentHeight: try? await runtime.contentHeight())
        }
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
        shownSinceFrame = true
        // A sheet's swipe asks the surface about the scroll regions of the
        // frame on screen ([`NuxieMachineSheetPan`]).
        surface.scrollRegions = capture.scrollRegions
        semantics.update(capture: capture, nativeControls: [:], project: { [surface] node in
            Self.projection(for: node, on: surface.bounds)
        }, submit: { [weak self] captureID, nodeID, action in
            self?.activate(nodeID, in: captureID, action) ?? false
        }, focused: { [weak self] nodeID, gained in
            self?.focused(nodeID, gained)
        }, scroll: { [weak self] nodeID, direction in
            self?.scroll(from: nodeID, direction) ?? false
        })
    }

    /// How a machine Screen whose surface has `bounds` shows `node`, or none
    /// for a node no element stands for: one with no role UIKit reads, or
    /// one drawn nowhere on the surface and under no `scroll`. A node on the
    /// surface stands where it is drawn on it. One a `scroll` has moved off
    /// the surface keeps its own box, off the surface, as a scroll view's
    /// subview out of view does, so the reader can reach it and bring it
    /// into view ([`focused`]).
    ///
    /// A button or a link takes a tap when its node offers one. The engine
    /// offers none for a disabled button or one a `scroll` clips wholly
    /// away; a button inside a `scroll` that is not disabled still takes an
    /// activation, which waits for it to be brought into view
    /// ([`activate`]). A radio is a button, selected while its check state
    /// is checked; one not checked, or mixed, is not selected.
    package static func projection(
        for node: NuxieNativeSemanticNode,
        on bounds: CGRect
    ) -> ExperienceSemanticAccessibilityContainer.Projection? {
        guard var traits = ExperienceSemanticAccessibilityContainer.traits(for: node) else { return nil }
        // The artboard is laid out at the surface's size with its origin
        // at zero: a point on it is the same point on the surface.
        var frame = node.bounds.intersection(bounds)
        if frame.isNull || frame.isInfinite || frame.isEmpty {
            guard node.scrollRegion != nil, !node.bounds.isNull, !node.bounds.isInfinite,
                  node.bounds.width.isFinite, node.bounds.height.isFinite else { return nil }
            frame = node.bounds
        }
        if node.role == NuxieNativeSemanticRole.radioButton.rawValue,
           node.stateFlags & checkState == NuxieNativeSemanticNode.checked {
            traits.insert(.selected)
        }
        let presses = traits.contains(.button) || traits.contains(.link)
        let tap: UInt32 = 1 << NuxieNativeSemanticAction.tap.rawValue
        let revealable = node.scrollRegion != nil && node.stateFlags & NuxieNativeSemanticNode.disabled == 0
        return .init(frame: frame, traits: traits, value: node.value.isEmpty ? nil : node.value,
                     actions: presses ? (revealable ? tap : node.actions & tap) : 0)
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
    ///
    /// The engine takes no tap on a node a `scroll` clips wholly away. So a
    /// tap on a node that is being brought into view, or that does not
    /// show and offers no tap, waits behind its reveal, and goes in the
    /// first frame at rest after, if the node then offers one
    /// ([`NuxieMachineScreenReaderScrolling`]). Focus normally brought it
    /// into view before the person taps, as it does in a scroll view.
    private func activate(_ nodeID: UInt32, in captureID: UUID, _ action: NuxieNativeSemanticAction) -> Bool {
        guard reachable, action == .tap, let loop, !loop.stopped, let capture = latest, capture.id == captureID,
              let node = capture.tree.nodes.first(where: { $0.id == nodeID }) else { return false }
        let tap: UInt32 = 1 << NuxieNativeSemanticAction.tap.rawValue
        // The newest activation wins: a held tap replaces a tap not yet
        // sent, and a tap pressed at once replaces a held one.
        if scrolling.revealPending(for: nodeID)
            || (node.actions & tap == 0 && node.scrollRegion != nil
                && !NuxieMachineScreenReaderScroll.isShown(node, in: capture.scrollRegions)) {
            guard scrolling.hold(tap: nodeID) else { return false }
            semanticTap = nil
            loop.requestFrame()
            return true
        }
        guard node.actions & tap != 0, semanticTap?.captureID != captureID else { return false }
        semanticTap = NuxieMachineSemanticTap(captureID: captureID, nodeID: nodeID)
        scrolling.dropHeldTap()
        loop.requestFrame()
        return true
    }

    /// The screen reader's focus reached (`gained`) or left the element of
    /// `nodeID`. A node inside a `scroll` is brought into view once the
    /// Screen is at rest; focus on a node under none, or leaving the node,
    /// lets a reveal still waiting for it go
    /// ([`NuxieMachineScreenReaderScrolling`]).
    private func focused(_ nodeID: UInt32, _ gained: Bool) {
        guard reachable, let loop, !loop.stopped else { return }
        guard gained else {
            scrolling.focusLeft(nodeID)
            return
        }
        if latest?.tree.nodes.first(where: { $0.id == nodeID })?.scrollRegion != nil {
            scrolling.focus(nodeID)
            loop.requestFrame()
        } else {
            scrolling.focusOutside()
        }
    }

    /// A scroll gesture with the reader on the element of `nodeID`: the
    /// first `scroll` around the node that can move that way moves one page
    /// in the next frame, and once it moved the reader is told which page
    /// shows ([`frameEnded`]). False when none can, so the reader sounds the
    /// end.
    private func scroll(from nodeID: UInt32, _ direction: UIAccessibilityScrollDirection) -> Bool {
        guard reachable, let loop, !loop.stopped, let capture = latest,
              let node = capture.tree.nodes.first(where: { $0.id == nodeID }),
              let wanted = Self.direction(direction, from: node, in: capture.scrollRegions),
              NuxieMachineScreenReaderScroll.page(wanted, from: node, in: capture.scrollRegions) != nil
        else { return false }
        scrolling.page(wanted, from: nodeID)
        loop.requestFrame()
        return true
    }

    /// What a scroll gesture asks to show, from `node`, by UIKit's
    /// documented meaning of each direction. Up and down name the way the
    /// view moves through its content, as its scroll indicator does: down
    /// shows what is below, up what is above (a three-finger swipe up
    /// arrives as down). Left and right name the way the fingers move: left
    /// shows what is to the right, further on, and right what is before.
    /// Next and previous go down and up the page, or, in a `scroll` that
    /// moves only sideways, further on and back
    /// ([`NuxieMachineScreenReaderScroll.onward`]).
    package static func direction(_ direction: UIAccessibilityScrollDirection, from node: NuxieNativeSemanticNode,
                                  in regions: [NuxieNativeScrollRegion]) -> NuxieMachineScrollDirection? {
        switch direction {
        case .down: return .showBelow
        case .up: return .showAbove
        case .left: return .showRight
        case .right: return .showLeft
        case .next: return NuxieMachineScreenReaderScroll.onward(true, from: node, in: regions)
        case .previous: return NuxieMachineScreenReaderScroll.onward(false, from: node, in: regions)
        @unknown default: return nil
        }
    }

    /// The screen reader's moves of a `scroll` and a tap that waited behind
    /// one, for the next frame, asked of the snapshot shown now. The tap
    /// goes beside any other the frame carries.
    package func takeScrolls() -> [NuxieMachineScrollRequest] {
        let taken = scrolling.take(latest)
        if let tap = taken.tap, semanticTap == nil { semanticTap = tap }
        return taken.scrolls
    }

    /// A frame that stepped this Screen ended: `scrolled` is what came of
    /// the moves it carried for it, and `settled` whether its step reported
    /// itself settled. It drew the snapshot shown since the last frame
    /// ended, if one was: a frame not drawn leaves the snapshot from before
    /// its step on screen, so it is not at rest, and a page that moved is
    /// told only after a drawn frame, with the line read from that frame's
    /// snapshot, which reads where the region is going, or with nothing to
    /// say when the pages cannot be counted. Asks for another frame while
    /// anything waits.
    package func frameEnded(_ scrolled: [NuxieMachineScrolled], settled: Bool) {
        let drawn = shownSinceFrame ? latest : nil
        shownSinceFrame = false
        if let told = scrolling.ended(scrolled, settled: settled, drawn: drawn) {
            semantics.announcePageScrolled(told.line)
        }
        if hasSize, scrolling.wantsFrames { loop?.requestFrame() }
    }

    /// The Screen left its window, was covered or left the loop: the tap it
    /// queued and everything it asked of its `scroll`s go, so nothing of the
    /// screen reader's keeps a frame coming. Answers to requests already in
    /// a frame still arrive and change nothing.
    fileprivate func dropScreenReaderRequests() {
        semanticTap = nil
        scrolling.detach()
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

    /// What the screen reader has asked of this Screen's `scroll`s and has
    /// not been sent, for checks.
    package var screenReaderScrolling: NuxieMachineScreenReaderScrolling { scrolling }

    /// The screen reader's tap queued for the next frame, for checks.
    package var queuedTap: NuxieMachineSemanticTap? { semanticTap }

    /// Whether input waits for the next frame: pointers, a tap, or, while
    /// the Screen can be stepped, a move of a `scroll` the screen reader
    /// asked for.
    package var hasInput: Bool { !pointers.isEmpty || semanticTap != nil || (hasSize && scrolling.wantsFrames) }

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

/// Why a segment does not let the person swipe it away now
/// ([`NuxieMachineSegmentController.modalReasons`]).
package enum NuxieMachineModalReason: Hashable, Sendable {
    /// A swipe down would not close it: it is a cover, which has no swipe,
    /// or the machine says the swipe presses a control or does nothing.
    case swipeRefused
    /// The loading screen or the recovery screen is up on a page of the
    /// segment: the page waits for its files, and the close is the way out.
    case loading
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
    /// A Screen that leaves the list drops what the screen reader asked of
    /// it ([`NuxieMachineScreenViewController.dropScreenReaderRequests`]).
    package var screens: [NuxieMachineScreenViewController] = [] {
        didSet {
            for screen in oldValue where !screens.contains(where: { $0 === screen }) {
                screen.dropScreenReaderRequests()
            }
            requestFrame()
        }
    }

    /// Whether any Screen has input waiting for a frame
    /// ([`NuxieMachineScreenViewController.hasInput`]): while none has, and
    /// nothing else asks, the loop rests.
    package var inputWaits: Bool { screens.contains { $0.hasInput } }

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
            screen.scrolling = NuxieMachineScreenReaderScrolling()
        }
    }

    // MARK: Frames

    fileprivate func tick(at timestamp: CFTimeInterval) {
        guard !stopped, !frameInFlight else { return }
        frameRequested = false
        frameInFlight = true
        let input = takeInput()
        let elapsed = lastTimestamp.map { Float(max(0, timestamp - $0)) } ?? 0
        lastTimestamp = timestamp
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.inLane {
                await self.runFrame(pointers: input.pointers, semanticTaps: input.semanticTaps,
                                    scrolls: input.scrolls, touched: input.touching?.shown,
                                    touching: input.touching, elapsedSeconds: elapsed)
            }
        }
    }

    /// What the next frame carries, taken from the Screens now. The
    /// pointers and the screen reader's requests go with the presentation
    /// they touched, the top one that has any; the rest wait for the next
    /// frame. The frame's wakes run first and may end it, and the edge then
    /// drops them. A Screen that cannot be stepped (no window or size) is
    /// sent no screen reader request, since its answer would not reach it,
    /// and the tap it queued is dropped, so it cannot keep the loop from
    /// resting; its pointers go as before.
    package func takeInput() -> (touching: NuxieMachineScreenViewController?, pointers: [NuxieNativePointerEvent],
                                 scrolls: [NuxieMachineScrollRequest], semanticTaps: [NuxieMachineSemanticTap]) {
        guard let touching = screens.last(where: { $0.hasInput }) else { return (nil, [], [], []) }
        let pointers = touching.takePointers()
        guard touching.hasSize else {
            _ = touching.takeSemanticTaps()
            return (touching, pointers, [], [])
        }
        // The scrolls first: a tap that waited behind a reveal joins the
        // queued tap there.
        let scrolls = touching.takeScrolls()
        return (touching, pointers, scrolls, touching.takeSemanticTaps())
    }

    private func runFrame(pointers: [NuxieNativePointerEvent], semanticTaps: [NuxieMachineSemanticTap],
                          scrolls: [NuxieMachineScrollRequest], touched: NuxieMachineShown?,
                          touching: NuxieMachineScreenViewController?, elapsedSeconds: Float) async {
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
                guard let drawing = await edge.drawing(for: screen.shown) else { continue }
                let runtime = drawing.player
                screen.canvas = drawing.canvas
                try await screen.applySize(runtime)
                stepped.append((screen, runtime))
            }
            frame = await edge.frame(pointers: pointers, semanticTaps: semanticTaps, scrolls: scrolls,
                                     on: touched, elapsedSeconds: elapsedSeconds, now: now)
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
            // Each Screen the frame stepped hears what came of the screen
            // reader's moves it carried, and whether it settled, after its
            // draw: a Screen not drawn this frame still shows the snapshot
            // from before the step ([`frameEnded`]).
            for (screen, _) in stepped where !stopped {
                screen.frameEnded(screen === touching ? frame.scrolled : [],
                                  settled: frame.settled.contains(screen.shown))
            }
            // The Screen whose requests the frame carried hears what came of
            // them though it was not stepped (it lost its size, or its
            // presentation ended): every request gets its answer.
            if let touching, !stopped, !stepped.contains(where: { $0.screen === touching }) {
                touching.frameEnded(frame.scrolled, settled: false)
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
        let another = frameRequested || inputWaits || (drawing && frame.keepGoing)
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
