#if canImport(UIKit) && canImport(QuartzCore)
import Foundation
import NuxieRuntime
import QuartzCore
import UIKit

enum ExperienceRuntimeScreenEmission: Equatable, Sendable {
    case control(
        screenId: String,
        invocation: ScreenActionInvocation,
        additionalDrafts: [ScreenEmissionDraft]
    )
    case effects(source: ScreenEmissionSource, drafts: [ScreenEmissionDraft])
}

enum ExperienceRuntimeProjectedEmission {
    case link(ExperienceRendererOpenLinkRequest)
    case control(screenId: String, invocation: ScreenActionInvocation)
    case draft(ScreenEmissionDraft, source: ScreenEmissionSource)
}

struct ExperienceRuntimeScreenEmissionAssembler {
    enum AssemblyError: Error, Equatable {
        case multipleControls
    }

    private var control: (screenId: String, invocation: ScreenActionInvocation)?
    private var drafts: [ScreenEmissionDraft] = []
    private var source: ScreenEmissionSource?
    private var hasMultipleControls = false

    mutating func appendControl(
        screenId: String,
        invocation: ScreenActionInvocation
    ) {
        if control == nil {
            control = (screenId, invocation)
        } else {
            hasMultipleControls = true
        }
    }

    mutating func appendDraft(
        _ draft: ScreenEmissionDraft,
        source: ScreenEmissionSource
    ) {
        drafts.append(draft)
        self.source = self.source ?? source
    }

    func assembled() -> Result<ExperienceRuntimeScreenEmission?, AssemblyError> {
        guard !hasMultipleControls else { return .failure(.multipleControls) }
        if let control {
            return .success(.control(
                screenId: control.screenId,
                invocation: control.invocation,
                additionalDrafts: drafts
            ))
        }
        guard !drafts.isEmpty, let source else { return .success(nil) }
        return .success(.effects(source: source, drafts: drafts))
    }
}

@MainActor
protocol ExperienceScreenViewControllerDelegate: AnyObject {
    func experienceScreenViewControllerDidAdvance(_ controller: ExperienceScreenViewController)

    func screenEmissionRun(
        for controller: ExperienceScreenViewController
    ) -> ScreenEmissionRun?

    func experienceScreenViewController(
        _ controller: ExperienceScreenViewController,
        didEmitScreenEmission input: ExperienceRuntimeScreenEmission,
        originatingRun: ScreenEmissionRun?,
        frameSources: ExperienceEmissionSources?
    ) async

    func experienceScreenViewController(
        _ controller: ExperienceScreenViewController,
        didEmitViewModelChange change: ExperienceRendererViewModelChange
    )

    func captureLinkHandler(for controller: ExperienceScreenViewController) -> (@MainActor (ExperienceRendererOpenLinkRequest) async -> Void)?

    func experienceScreenViewController(
        _ controller: ExperienceScreenViewController,
        didRequestOpenLink request: ExperienceRendererOpenLinkRequest
    ) async

    func experienceScreenViewController(
        _ controller: ExperienceScreenViewController,
        didPresentDrawable drawable: ExperienceRuntimePresentedDrawable,
        frameNumber: UInt64
    )

    func experienceScreenViewController(
        _ controller: ExperienceScreenViewController,
        didAcceptPointerInput input: ExperienceRuntimeAcceptedPointerInput
    )
}

extension ExperienceScreenViewControllerDelegate {
    func captureLinkHandler(for controller: ExperienceScreenViewController) -> (@MainActor (ExperienceRendererOpenLinkRequest) async -> Void)? {
        { [self, controller] request in await experienceScreenViewController(controller, didRequestOpenLink: request) }
    }
}

private enum ExperienceInteractiveScreenControllerError: LocalizedError {
    case alreadyMounted
    case unavailable

    var errorDescription: String? {
        switch self {
        case .alreadyMounted:
            "This experience screen is already mounted"
        case .unavailable:
            "This experience screen is not mounted"
        }
    }
}

/// UIKit owner for one native page surface and its retained Screen rows.
///
/// The controller owns product routing and Apple presentation policy. Its
/// screen actor owns generic native handles and typed operations only.
@MainActor
final class ExperienceScreenViewController: UIViewController {
    struct CompletionWaiter {
        let id: UUID
        let stream: AsyncStream<Void>
    }

    private let experience: Experience
    private let artifact: LoadedExperienceArtifact
    private var screen: NativeExperienceScreen
    private let saveDisplayObserverID = UUID()
    private let runValues: ExperienceRunValues
    private let surfaceView = ExperienceRuntimeSurfaceView(frame: .zero)
    private let textInputOverlayBridge = ExperienceTextInputOverlayBridge()
    private var nativeEditingTarget: ExperienceTextInputOverlayBridge.InputTarget?
    private var nativeEditingOwnerID: UInt64?
    private let videoCaptionOverlay = ExperienceVideoCaptionOverlay()
    private let videoDecoderPool: ExperienceVideoDecoderPool?
    private var requiresSceneSemantics: Bool {
        artifact.payload.requiredCapabilities.contains("experience-accessibility") ||
            artifact.renderPlan.textInputs.contains {
                $0.screenId == screenId && $0.editable
            }
    }
    private lazy var semanticContainer = ExperienceSemanticAccessibilityContainer(view: surfaceView)

    private var interactiveScreen: ExperienceInteractiveScreen?
    private(set) var interactivePage: ExperienceInteractivePage?
    private var rowScreens: [String: JourneyScreen] = [:]
    private var rowBindings: [String: ExperienceInteractiveScreen] = [:]
    /// Counts each Screen's rows, so editors can tell a revisit's row from the removed one.
    private var rowGenerations: [String: UInt64] = [:]
    private var heldRowWrites: [String: [ExperienceInteractiveStateCommand]] = [:]
    private(set) var pageHistory: ExperiencePageHistory
    private var pageStepInProgress = false
    weak var orientationHost: UIViewController?

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        orientationHost?.supportedInterfaceOrientations ?? super.supportedInterfaceOrientations
    }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        orientationHost?.preferredInterfaceOrientationForPresentation ?? super.preferredInterfaceOrientationForPresentation
    }
    var retainedScreenIDs: [String] { interactivePage == nil ? [screenId] : Array(rowBindings.keys) }
    private var detectedPageHost = false
    var isPageController: Bool { detectedPageHost || artifact.renderPlan.pageHost != nil }
    private var lifecycleIncludesExitReason = false
    private let usesSystemDisplayLink: Bool
    private let acquireDrawable: @MainActor (CAMetalLayer) -> (any CAMetalDrawable)?
    private var presentationLoop: ExperienceRuntimePresentationLoop?
    private var runtimeFailure: Error?
    private var isShuttingDown = false
    private var shutdownTask: Task<Void, Never>?
    private(set) var shutdownInvocationCount = 0
    private var contentHidden = false
    private var semanticFocusLifecycle = ExperienceSemanticFocusLifecycle()
    private var controllerIsVisible = false
    private var pressedHardwareKeys: Set<Int> = []
    private(set) var riveFocusState = NuxieNativeFocusState(hasFocus: false, expectsKeyboardInput: false)
    private var lastPushedSafeAreaInsets: ExperienceSafeAreaInsets?
    private var lastPushedViewport: ExperienceViewportEnvironment?
    private var lastPushedFold: ExperienceFoldEnvironment?
    private var environmentWriteQueued = false
    private var lastPushedColorScheme: ExperienceColorScheme?
    private var colorSchemeWriteQueued = false
    private var lifecycleState: ExperienceScreenLifecycleState
    private var lifecycleWritesUnavailable = false
    private var didLogUnavailableLifecycleWrite = false
    private var exitWaiters: [UUID: (
        eventName: String,
        continuation: AsyncStream<Void>.Continuation
    )] = [:]
    private var didReportFirstPresentation = false
    private let presentationDiagnosticsEnabled: Bool

    /// Terminal failures after a successful mount are surfaced here. A queued
    /// SDK mutation can be rejected without poisoning the presentation lane.
    var onRuntimeFailure: ((Error) -> Void)?
    var onPageStep: ((ExperienceInteractivePage.Step) -> Void)?
    // Observes real completion waits without replacing their watchdog or streams.
    var onExitCompletionWait: (() -> Void)?
    /// Lets hosted tests hold a shutdown to see who waits for it.
    var onShutdown: (@MainActor () async -> Void)?
    /// The Experience's authored waits, so its retirement limits pause during them.
    var authoredTime: ExperienceAuthoredTime?
    var onSemanticCapture: ((NuxieNativeSemanticCapture) -> Void)?
    var hasCompletedLatestFrame: Bool { presentationLoop?.hasCompletedLatestFrame ?? false }
    var hasDeliveredLatestSemanticFrame: Bool { presentationLoop?.hasDeliveredLatestSemanticFrame ?? false }

    weak var delegate: ExperienceScreenViewControllerDelegate?

    var screenId: String { screen.screenId }
    var hasPresentedRuntimeFrame: Bool { didReportFirstPresentation }

    func runtimeSnapshot() async throws -> ExperienceInteractiveViewModelSnapshot {
        guard let interactiveScreen else { throw ExperienceInteractiveScreenControllerError.unavailable }
        return try await interactiveScreen.snapshot()
    }
    func runtimeEnvironmentSnapshot() async throws -> NuxieNativeViewModelSnapshot? {
        if let interactivePage { return try await interactivePage.environmentSnapshot() }
        guard let interactiveScreen else { throw ExperienceInteractiveScreenControllerError.unavailable }
        return try await interactiveScreen.environmentSnapshot()
    }
    var lifecycleAppearances: UInt64 { lifecycleState.appearances }
    var lifecyclePhase: ExperienceScreenLifecyclePhase { lifecycleState.phase }
    var lifecycleExitReason: ExperienceScreenExitReason { lifecycleState.exitReason }

    private var journeyScreen: JourneyScreen? {
        if let row = rowScreens[screenId] { return row }
        return experience.screens.screens.first { $0.id == screenId }
    }

    init(
        experience: Experience,
        artifact: LoadedExperienceArtifact,
        screen: NativeExperienceScreen,
        runValues: ExperienceRunValues = ExperienceRunValues(),
        reduceMotion: Bool,
        usesSystemDisplayLink: Bool = true,
        acquireDrawable: @escaping @MainActor (CAMetalLayer) -> (any CAMetalDrawable)? = { $0.nextDrawable() },
        presentationDiagnosticsEnabled: Bool = false,
        videoDecoderPool: ExperienceVideoDecoderPool? = nil,
        delegate: ExperienceScreenViewControllerDelegate?
    ) {
        self.experience = experience
        self.usesSystemDisplayLink = usesSystemDisplayLink
        self.acquireDrawable = acquireDrawable
        self.artifact = artifact
        self.screen = screen
        pageHistory = ExperiencePageHistory(root: screen.screenId)
        self.runValues = runValues
        self.presentationDiagnosticsEnabled = presentationDiagnosticsEnabled
        self.videoDecoderPool = videoDecoderPool
        lifecycleState = ExperienceScreenLifecycleState(reduceMotion: reduceMotion)
        self.delegate = delegate
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        surfaceView.onEnvironmentChange = { [weak self] in self?.syncSafeAreaInsets() }
        NotificationCenter.default.addObserver(self, selector: #selector(clearHardwareKeys),
            name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(nativeEditorDidBeginEditing(_:)),
            name: UITextField.textDidBeginEditingNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(nativeEditorDidBeginEditing(_:)),
            name: UITextView.textDidBeginEditingNotification, object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(contentSizeCategoryDidChange),
            name: UIContentSizeCategory.didChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(contentSizeCategoryDidChange),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        view.backgroundColor = .clear
        view.clipsToBounds = true
        view.accessibilityIdentifier = presentationDiagnosticsEnabled
            ? "nuxie-experience-surface"
            : "nuxie-screen-controller-\(screenId)"
        if presentationDiagnosticsEnabled {
            view.accessibilityLabel = screenId
            view.accessibilityValue = "first-frame-presentation:pending"
        }

        surfaceView.translatesAutoresizingMaskIntoConstraints = false
        // Keep qualification on the containing view: the surface's explicit
        // accessibility children are the authored controls and reading order.
        surfaceView.accessibilityIdentifier = presentationDiagnosticsEnabled
            ? nil : "nuxie-experience-surface"
        surfaceView.isAccessibilityElement = false
        surfaceView.isHidden = contentHidden
        view.addSubview(surfaceView)
        NSLayoutConstraint.activate([
            surfaceView.topAnchor.constraint(equalTo: view.topAnchor),
            surfaceView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            surfaceView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            surfaceView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        videoCaptionOverlay.translatesAutoresizingMaskIntoConstraints = false
        videoCaptionOverlay.isHidden = contentHidden
        view.addSubview(videoCaptionOverlay)
        NSLayoutConstraint.activate([
            videoCaptionOverlay.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            videoCaptionOverlay.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            videoCaptionOverlay.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
        ])

        // Fixture hosts own any qualification-only badge overlays.
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        // Back in a window, the screen's own traits are current again: one changed while
        // it was out of the window (beneath a modal, behind another screen) is written
        // before it shows.
        syncColorScheme()
        // Standalone screens can finish mounting and activate before didAppear.
        // Their focus admission needs the same window visibility as page hosts.
        controllerIsVisible = true
        updatePresentationVisibility()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        controllerIsVisible = true
        if !hasNativeTextFocus(view) { becomeFirstResponder() }
        updatePresentationVisibility()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        controllerIsVisible = false
        clearHardwareKeys()
        updatePresentationVisibility()
    }

    override var canBecomeFirstResponder: Bool { true }

    @objc private func clearHardwareKeys() {
        presentationLoop?.endActiveInput()
        pressedHardwareKeys.removeAll()
    }

    @objc private func nativeEditorDidBeginEditing(_ notification: Notification) {
        // Our overlay withdraws scene input in shouldBeginEditing, before its
        // didBeginEditing callback queues native focus. UIKit posts this notification
        // afterward; withdrawing again would cancel that new work's input epoch.
        if let editor = notification.object as? UIView, editor.isDescendant(of: surfaceView) { return }
        clearHardwareKeys()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = routeHardwarePresses(presses, pressed: true)
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = routeHardwarePresses(presses, pressed: false)
        if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = routeHardwarePresses(presses, pressed: false)
        if !unhandled.isEmpty { super.pressesCancelled(unhandled, with: event) }
    }

    private func routeHardwarePresses(_ presses: Set<UIPress>, pressed: Bool) -> Set<UIPress> {
        guard controllerIsVisible, !coveredByLayer else { return presses }
        var unhandled: Set<UIPress> = []
        for press in presses.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard let key = press.key else { unhandled.insert(press); continue }
            let hid = key.keyCode.rawValue
            if hasNativeTextFocus(view), hid != UIKeyboardHIDUsage.keyboardTab.rawValue {
                pressedHardwareKeys.remove(hid)
                unhandled.insert(press)
                continue
            }
            guard pressed || pressedHardwareKeys.contains(hid) else {
                unhandled.insert(press)
                continue
            }
            let repeatPress = pressed && pressedHardwareKeys.contains(hid)
            let modifiers = ExperienceHardwareKey.modifiers(key.modifierFlags)
            let accepted = receiveHardwareKey(hid: hid, modifiers: modifiers, pressed: pressed, repeated: repeatPress)
            if !accepted { unhandled.insert(press) }
        }
        return unhandled
    }

    @discardableResult
    func receiveHardwareKey(hid: Int, modifiers: UInt8, pressed: Bool, repeated: Bool) -> Bool {
        defer { if !pressed { pressedHardwareKeys.remove(hid) } }
        let isTab = hid == UIKeyboardHIDUsage.keyboardTab.rawValue
        guard !repeated || pressedHardwareKeys.contains(hid) else { return false }
        guard !pageStepInProgress, controllerIsVisible, !coveredByLayer, isTab || !hasNativeTextFocus(view),
              hid == UIKeyboardHIDUsage.keyboardTab.rawValue || riveFocusState.hasFocus || pressedHardwareKeys.contains(hid),
              let input = ExperienceHardwareKey.input(hid: hid, modifiers: modifiers, pressed: pressed, repeated: repeated)
        else { return false }
        let accepted = receiveFocusInput(input)
        if pressed && accepted {
            pressedHardwareKeys.insert(hid)
            if isTab && hasNativeTextFocus(view) { becomeFirstResponder() }
        }
        return accepted
    }

    @discardableResult
    func receiveFocusInput(_ input: NuxieNativeFocusInput) -> Bool {
        guard !pageStepInProgress else { return false }
        return presentationLoop?.enqueueFocus(input) ?? false
    }

    private func hasNativeTextFocus(_ view: UIView) -> Bool {
        (view.isFirstResponder && view is any UITextInput) || view.subviews.contains { hasNativeTextFocus($0) }
    }

    private weak var heightPresentationTarget: UIViewController?
    private var measuresContentHeight = false
    private var availablePresentationHeight: CGFloat?
    private var coveredByLayer = false

    // Native-page visibility is owned here; UIKit appearance alone cannot resume
    // a retained page or distinguish it from a page beneath a sheet.
    var pageLifecycleSnapshot: ExperienceScreenLifecycleSnapshot { lifecycleState.snapshot }

    func coverPage(reduceMotion: Bool, restoring snapshot: ExperienceScreenLifecycleSnapshot? = nil) async {
        presentationLoop?.setInputEnabled(false)
        clearHardwareKeys()
        setCoveredByLayer(true)
        if let snapshot {
            presentationLoop?.setTimelineActive(false)
            lifecycleState = .init(snapshot: snapshot)
            await applyLifecycleSnapshot(snapshot)
            try? await presentationLoop?.advanceZeroDelta()
        } else { await hide(reduceMotion: reduceMotion) }
    }

    func revealPage(reduceMotion: Bool, starting: Bool = false) async {
        if starting {
            if lifecycleState.phase == .hidden {
                setCoveredByLayer(false)
                presentationLoop?.setInputEnabled(false)
                view.isUserInteractionEnabled = false
                await enter(reduceMotion: reduceMotion)
            }
            return
        }
        setCoveredByLayer(false)
        presentationLoop?.setInputEnabled(true)
        presentationLoop?.setTimelineActive(true)
        await activate(reduceMotion: reduceMotion)
        updatePresentationVisibility()
    }

    var timelineElapsedSeconds: Double { presentationLoop?.timelineElapsedSeconds ?? 0 }

    func setCoveredByLayer(_ covered: Bool) {
        coveredByLayer = covered
        if interactivePage == nil { interactiveScreen?.setCoveredByLayer(covered) }
        view.isUserInteractionEnabled = !covered && !pageStepInProgress
        textInputOverlayBridge.setHidden(contentHidden || covered)
        if covered { view.endEditing(true) }
        updatePresentationVisibility()
    }
    private var lastPresentedHeight: CGFloat?

    func configurePresentationHeight(_ presentation: ExperienceLayerPresentation,
                                     target: UIViewController, availableSize: CGSize) async throws {
        heightPresentationTarget = target
        availablePresentationHeight = availableSize.height
        lastPresentedHeight = nil
        if let interactivePage {
            // F5: a page sheet keeps the large detent until page content heights land (UNIV-5595).
            try await interactivePage.configurePresentationHeight(fitContent: presentation.fitsContent, size: availableSize)
            if presentation.fitsContent {
                target.preferredContentSize.height = 0
                ExperienceLayerPresentationConfigurator.updateContentHeight(target, height: 0)
            }
            return
        }
        guard let interactiveScreen, let presentationLoop else { throw CancellationError() }
        try await presentationLoop.advanceZeroDelta(after: ExperienceRuntimePresentationQueuedWork { [weak self] in
            let available = try await interactiveScreen.setPresentationHeight(
                fitContent: presentation.fitsContent, availableSize: availableSize)
            return .work(requestsFrame: false) { [weak self = self] in
                self?.measuresContentHeight = presentation.fitsContent && available
            }
        })
        if presentation.fitsContent {
            if measuresContentHeight { publishContentHeight() }
            else { ExperienceLayerPresentationConfigurator.updateContentHeight(target, height: 0) }
        }
    }

    func setHeightPresentationTarget(_ target: UIViewController) {
        heightPresentationTarget = target
        lastPresentedHeight = nil
        publishContentHeight()
    }

    private func publishContentHeight() {
        guard measuresContentHeight, let target = heightPresentationTarget,
              let height = interactiveScreen?.intrinsicPresentationHeight,
              height.isFinite, height > 0, lastPresentedHeight != height else { return }
        if let navigation = target as? UINavigationController,
           navigation.topViewController !== self { return }
        lastPresentedHeight = height
        ExperienceLayerPresentationConfigurator.updateContentHeight(target, height: height)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        syncSafeAreaInsets()
        textInputOverlayBridge.layout()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        syncSafeAreaInsets()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        syncSafeAreaInsets(force: true)
        syncColorScheme()
    }

    /// The host's appearance, for the time the screen's view is out of a window: before
    /// it first joins the host, and while it waits behind another screen or in a cache,
    /// where its own traits are the system's or stale.
    private var detachedHostStyle: UIUserInterfaceStyle?

    /// The screen's own appearance while its view is in a window or one is forced on
    /// it, else the host's.
    private var colorScheme: ExperienceColorScheme {
        if let detachedHostStyle, overrideUserInterfaceStyle == .unspecified,
           viewIfLoaded?.window == nil {
            return ExperienceColorScheme(detachedHostStyle)
        }
        return ExperienceColorScheme(traitCollection.userInterfaceStyle)
    }

    @objc private func contentSizeCategoryDidChange() {
        syncSafeAreaInsets(force: true)
    }

    static func fontScale(for traits: UITraitCollection) -> Double {
        Double(UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits).pointSize / 17)
    }

    /// Mounts the screen. A screen mounts before it joins the host's hierarchy, so
    /// `hostTraits` gives the appearance it will inherit there: a host that forces light
    /// or dark draws its first frame in that appearance, not the system's.
    func mountInteractiveScreen(hostTraits: UITraitCollection? = nil) async throws {
        guard interactiveScreen == nil, presentationLoop == nil else {
            throw ExperienceInteractiveScreenControllerError.alreadyMounted
        }
        guard !isShuttingDown else {
            throw ExperienceInteractiveScreenControllerError.unavailable
        }
        loadViewIfNeeded()

        let initialWidth = Self.pixelDimension(screen.width)
        let initialHeight = Self.pixelDimension(screen.height)
        detachedHostStyle = hostTraits?.userInterfaceStyle
        let initialColorScheme = colorScheme
        let preparation = try await artifact.acquired.interactivePreparation.preparation()
        detectedPageHost = preparation.hasPageHost
        let interactive: ExperienceInteractiveScreen
        if isPageController {
            let layer = try await preparation.openPage(runValues: runValues, pixelWidth: initialWidth,
                pixelHeight: initialHeight, reduceMotion: lifecycleState.snapshot.reduceMotion,
                fontScale: Self.fontScale(for: traitCollection),
                safeArea: experienceSafeAreaInsets(for: view), colorScheme: initialColorScheme,
                videoDecoderPool: videoDecoderPool)
            interactivePage = layer
            interactive = try await layer.prepareRow(screenID: screenId, products: artifact.acquired.products)
            rowBindings[screenId] = interactive
            rowGenerations[screenId, default: 0] += 1
            rowScreens[screenId] = try await layer.screen(screenID: screenId)
            try await layer.insert(screenID: screenId, at: 0)
            let entering = lifecycleState.move(to: .entering)
            try await layer.applyLifecycleSnapshot(entering, screenID: screenId)
        } else {
            interactive = try await preparation.openScreen(
                screenID: screenId,
                runValues: runValues,
                products: artifact.acquired.products,
                pixelWidth: initialWidth,
                pixelHeight: initialHeight,
                initialReduceMotion: lifecycleState.snapshot.reduceMotion,
                initialFontScale: Self.fontScale(for: traitCollection),
                initialSafeArea: experienceSafeAreaInsets(for: view),
                initialColorScheme: initialColorScheme,
                videoDecoderPool: videoDecoderPool
            )
        }
        if let name = journeyScreen?.defaultViewModelName {
            lifecycleIncludesExitReason = await interactive.supportsScreenExitReason(viewModelName: name)
        } else {
            lifecycleIncludesExitReason = false
        }
        interactiveScreen = interactive
        lastPushedColorScheme = initialColorScheme
        await runValues.observeSaveDisplays(id: saveDisplayObserverID) { [weak self] in
            guard let self, !self.isShuttingDown else { return }
            _ = self.presentationLoop?.enqueue(ExperienceRuntimePresentationQueuedWork {
                .work(requestsFrame: true) {}
            })
        }

        let includesTextInputSnapshot = isPageController || artifact.renderPlan.textInputs.contains {
            $0.screenId == screenId && $0.editable
        }
        let semanticConsumer: (@MainActor @Sendable (NuxieNativeSemanticCapture) -> Void)?
        if requiresSceneSemantics || isPageController {
            semanticConsumer = { [weak self] capture in self?.applySemantics(capture) }
        } else {
            semanticConsumer = nil
        }
        let textConsumer: (@MainActor @Sendable (ExperienceInteractiveTextFrame) -> Void)?
        if includesTextInputSnapshot || isPageController {
            textConsumer = { [weak self] frame in
                guard let self else { return }
                self.textInputOverlayBridge.update(frame: frame)
            }
        } else {
            textConsumer = nil
        }
        let captionConsumer: (@MainActor @Sendable ([ExperienceInteractiveVideoCaption]) -> Void)?
        if artifact.renderPlan.videos.isEmpty { captionConsumer = nil }
        else {
            captionConsumer = { [weak self] captions in
                guard let self, !self.isShuttingDown, self.runtimeFailure == nil else { return }
                self.videoCaptionOverlay.update(captions)
            }
        }
        let session: ExperienceRuntimePresentationSession
        if let interactivePage {
            session = interactivePage.presentationSession(onSemantics: semanticConsumer, onTextFrame: textConsumer,
                onCaptions: captionConsumer, onFocus: { [weak self] state in self?.riveFocusState = state },
                onStep: { [weak self] step in await self?.deliverPageStep(step) })
        } else {
            session = interactive.presentationSession(
                onSemantics: semanticConsumer,
                onTextFrame: textConsumer,
                onCaptions: captionConsumer,
                onFocus: { [weak self] state in self?.riveFocusState = state }
            ) { [weak self] effects in
                await self?.deliverStep(effects: effects)
            }
        }
        let loop = ExperienceRuntimePresentationLoop(
            session: session,
            surfaceView: surfaceView,
            usesSystemDisplayLink: usesSystemDisplayLink,
            acquireDrawable: acquireDrawable,
            onSessionResult: { [weak self] in
                guard let self else { return }
                if let bounds = self.interactivePage?.artboardBounds ?? self.interactiveScreen?.artboardBounds {
                    self.textInputOverlayBridge.updateArtboardBounds(bounds)
                }
                self.publishContentHeight()
                self.delegate?.experienceScreenViewControllerDidAdvance(self)
            },
            onPresentedDrawable: { [weak self] drawable in
                self?.didPresentDrawable(drawable)
            },
            onAcceptedPointerInput: { [weak self] input in
                guard let self else { return }
                self.delegate?.experienceScreenViewController(
                    self,
                    didAcceptPointerInput: input
                )
            },
            onError: { [weak self] error in
                self?.handleTerminalFailure(error)
            }
        )
        presentationLoop = loop
        loop.setPresentationVisible((controllerIsVisible || coveredByLayer) && !contentHidden)

        do {
            let insets = experienceSafeAreaInsets(for: view)
            let viewport = viewportEnvironment()
            let fold = surfaceView.foldEnvironment
            if let interactivePage {
                try await interactivePage.updateEnvironment(reduceMotion: lifecycleState.snapshot.reduceMotion,
                    fontScale: Self.fontScale(for: traitCollection), safeArea: insets, viewport: viewport, fold: fold)
            } else {
                try await interactive.updateEnvironment(
                    reduceMotion: lifecycleState.snapshot.reduceMotion,
                    fontScale: Self.fontScale(for: traitCollection), safeArea: insets,
                    viewport: viewport, fold: fold)
            }
            lastPushedSafeAreaInsets = insets
            lastPushedViewport = viewport
            lastPushedFold = fold
            try await loop.start()
            configureTextInputCallbacks()
            bindTextInputs(to: interactive, loop: loop)
            await publishPageRows()
            refreshTextInputLayouts()
            syncSafeAreaInsets(force: true)
            syncColorScheme()
            loop.setTimelineActive(false)
            await applyLifecycleSnapshot(lifecycleState.snapshot)
            try? await loop.advanceZeroDelta()
        } catch {
            presentationLoop = nil
            interactiveScreen = nil
            lifecycleIncludesExitReason = false
            await loop.shutdown()
            if loop.needsSessionCleanup { presentationLoop = loop }
            if !loop.hasTakenSessionOwnership {
                // Preparation opened the native resource before the loop took ownership.
                if let interactivePage { try? await interactivePage.close() }
                else { try? await interactive.close() }
            }
            interactivePage = nil
            rowBindings.removeAll()
            rowScreens.removeAll()
            throw error
        }
    }

    /// Editors of a removed or replaced row retire instead of waiting hidden.
    private func publishPageRows() async {
        guard let interactivePage else { return }
        var rows: [String: UInt64] = [:]
        for (id, generation) in rowGenerations where rowBindings[id] != nil {
            if !(await interactivePage.isRowRemoved(screenID: id)) { rows[id] = generation }
        }
        textInputOverlayBridge.setPageRows(rows)
    }

    func preparePageRow(screenID: String, products: [StoreProduct]) async throws {
        guard let interactivePage else { throw ExperienceInteractiveScreenControllerError.unavailable }
        let row = try await interactivePage.prepareRow(screenID: screenID, products: products)
        if rowBindings[screenID] !== row { rowGenerations[screenID, default: 0] += 1 }
        rowBindings[screenID] = row
        rowScreens[screenID] = try await interactivePage.screen(screenID: screenID)
        await publishPageRows()
        // Writes held while Back had removed this Screen reach its new row, seeded first (R6b).
        if heldRowWrites[screenID] != nil { _ = enqueueRowWrite(nil, screenID: screenID) }
    }

    private func deliverPageStep(_ step: ExperienceInteractivePage.Step) async {
        onPageStep?(step)
        for id in step.rows.keys.sorted() {
            if let row = step.rows[id] { await deliverStep(effects: row.effects, screenID: id) }
        }
        if !step.unattributedEvents.isEmpty {
            LogWarning("ExperienceScreenViewController: layer step has effects without a unique Screen owner")
        }
    }

    private func pageWork(_ work: @escaping @Sendable () async throws -> ExperienceInteractivePage.Step?) async throws {
        guard let presentationLoop, runtimeFailure == nil, !isShuttingDown else { throw CancellationError() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            presentationLoop.enqueue(.init {
                let step = try await work()
                return .work(requestsFrame: false) { [weak self = self] in
                    if let step { await self?.deliverPageStep(step) }
                }
            }, completion: { continuation.resume(with: $0) })
        }
    }

    /// `isEligible` admits the step before its first change. From then on the step
    /// runs to the end while `isLive` holds; nothing is undone halfway.
    func navigatePage(to targetID: String, spec: ExperienceScreenTransitionSpec, isBack: Bool,
                       reduceMotion: Bool, backSteps: Int? = nil, coveredCut: Bool = false, isEligible: @escaping () -> Bool,
                       isLive: @escaping () -> Bool,
                       onHidden: @escaping () async -> Void, onActive: @escaping () async -> Void) async throws {
        guard let layer = interactivePage, let loop = presentationLoop,
              let target = artifact.renderPlan.screens.first(where: { $0.screenId == targetID }) else {
            throw ExperienceInteractiveScreenControllerError.unavailable
        }
        let sourceID = screenId
        if sourceID == targetID {
            if isBack {
                pageHistory.back(to: targetID, steps: backSteps)
                let reachable = Set(pageHistory.screenIDs)
                try await pageWork {
                    try await layer.apply([.retire], source: sourceID, target: targetID, reachable: reachable, reduceMotion: reduceMotion)
                }
                await publishPageRows()
            }
            return
        }
        let effectiveID = spec.transitionId
        let plan = effectiveID.flatMap {
            ExperienceScreenCustomTransitionPlan.resolve(transitionId: $0, sourceScreenId: sourceID,
                destinationScreenId: targetID, declarations: artifact.renderPlan.transitions)
        }
        let playedSpec = plan.map { _ in ExperienceScreenTransitionSpec(kind: spec.kind, transitionId: effectiveID) } ?? .none
        var waiters: [(String, ExperienceInteractivePage.Completion)] = []
        var nextHistory = pageHistory
        if isBack { nextHistory.back(to: targetID, steps: backSteps) }
        else { nextHistory.visit(targetID, transition: playedSpec) }
        let reachable = Set(nextHistory.screenIDs)
        let operations = ExperiencePageStep.Operations(
            setInputEnabled: { [self] enabled in
                setPageInputEnabled(enabled)
            }, prepare: { [self] in
                guard isEligible(), isLive(), rowBindings[targetID] != nil else { throw CancellationError() }
                await layer.beginPresentationStep()
            }, register: { id, name in
                let waiter = try await layer.registerCompletion(screenID: id, eventName: name)
                waiters.append((id, waiter))
                return waiter.events
            }, batch: { [self] changes in
                guard isLive() else { throw CancellationError() }
                try await pageWork {
                    try await layer.apply(changes, source: sourceID, target: targetID,
                        reachable: reachable, reduceMotion: reduceMotion)
                }
                lifecycleState = await layer.state(screenID: sourceID) ?? lifecycleState
            }, present: {
                loop.setTimelineActive(true)
                try await loop.advanceZeroDelta(awaitsPresentation: true)
            }, wait: { [self] streams, milliseconds in
                onExitCompletionWait?()
                await ExperienceScreenExitWatchdog.wait(for: streams, watchdogMilliseconds: milliseconds)
            }, authoredTime: authoredTime, release: {
                for (id, waiter) in waiters { await layer.removeCompletion(screenID: id, id: waiter.id) }
                waiters.removeAll()
            }, hidden: onHidden, active: { [self] in
                guard isLive(), runtimeFailure == nil, !isShuttingDown else { throw CancellationError() }
                try await layer.selectActiveRow(targetID)
                screen = target
                interactiveScreen = rowBindings[targetID]
                lifecycleState = await layer.state(screenID: targetID) ?? .init(reduceMotion: reduceMotion)
                pageHistory = nextHistory
                semanticFocusLifecycle = ExperienceSemanticFocusLifecycle()
                let write = semanticFocusLifecycle.beginWrite(phase: coveredCut ? .hidden : .active)
                _ = semanticFocusLifecycle.completeWrite(write, succeeded: true)
                semanticContainer.requestFocusOnNextPresentation()
                if let interactiveScreen {
                    bindTextInputs(to: interactiveScreen, loop: loop, preservingNativeFields: true)
                }
                await publishPageRows()
                try await loop.advanceZeroDelta()
                await onActive()
            }, drain: {
                guard isLive() else { throw CancellationError() }
                // Completion waits for result delivery, not merely native advancement.
                try await loop.advanceZeroDelta()
            })
        do {
            try await ExperiencePageStep.perform(source: sourceID, target: targetID, style: spec.kind,
                isBack: isBack, plan: plan, exit: .init(declaration: screen.exit, reduceMotion: reduceMotion),
                reduceMotion: reduceMotion, coveredCut: coveredCut, operations: operations)
        } catch {
            for (id, waiter) in waiters { await layer.removeCompletion(screenID: id, id: waiter.id) }
            // A step stops early only when its page is leaving, which discards it.
            // Any other failure leaves the rows mid-step, so it ends the page.
            if !(error is CancellationError) { handleTerminalFailure(error) }
            throw error
        }
        for (id, waiter) in waiters { await layer.removeCompletion(screenID: id, id: waiter.id) }
    }

    func setPageInputEnabled(_ enabled: Bool, pausingTimeline: Bool = false) {
        pageStepInProgress = !enabled
        presentationLoop?.setInputEnabled(enabled && !coveredByLayer)
        view.isUserInteractionEnabled = enabled && !coveredByLayer
        textInputOverlayBridge.setStepInProgress(!enabled)
        if !enabled {
            // A durable checkpoint may wait indefinitely before the step starts.
            // Keep the source's last frame, without playing an exit underneath it.
            if pausingTimeline { presentationLoop?.setTimelineActive(false) }
            clearHardwareKeys()
            semanticContainer.clear()
        } else {
            presentationLoop?.setTimelineActive(!coveredByLayer)
            updatePresentationVisibility()
        }
    }

    private func didPresentDrawable(_ drawable: ExperienceRuntimePresentedDrawable) {
        guard !didReportFirstPresentation else { return }
        didReportFirstPresentation = true
        if presentationDiagnosticsEnabled {
            view.accessibilityValue = drawable.isConfirmedDisplayPresentation
                ? "first-frame-presentation:confirmed"
                : "first-frame-presentation:provisional"
        }
        delegate?.experienceScreenViewController(
            self,
            didPresentDrawable: drawable,
            frameNumber: drawable.frameNumber
        )
    }

    /// A coordinator retires each page once, whichever step removed it.
    var hasStartedShutdown: Bool { shutdownInvocationCount > 0 }

    func shutdownInteractiveScreen() async {
        shutdownInvocationCount += 1
        if let onShutdown { await onShutdown() }
        if shutdownTask == nil {
            // Strong ownership is intentional: this controller owns its release
            // lease until all native work actually retires, even after timeout.
            shutdownTask = Task<Void, Never> { @MainActor [self] in
                self.isShuttingDown = true
                await self.runValues.removeSaveDisplayObserver(id: self.saveDisplayObserverID)
                let loop = self.presentationLoop
                let layer = self.interactivePage
                self.presentationLoop = nil
                self.interactiveScreen = nil
                self.interactivePage = nil
                self.rowBindings.removeAll()
                self.rowScreens.removeAll()
                self.lifecycleIncludesExitReason = false
                self.finishExitWaiters()
                self.semanticContainer.clear()
                self.semanticFocusLifecycle = ExperienceSemanticFocusLifecycle()
                self.textInputOverlayBridge.clear()
                self.videoCaptionOverlay.update([])
                self.videoCaptionOverlay.isHidden = true
                await loop?.retireSession()
                if let loop, loop.needsSessionCleanup { self.presentationLoop = loop }
                if loop == nil {
                    do { try await layer?.close() }
                    catch { self.handleTerminalFailure(error) }
                }
                self.isShuttingDown = false
            }
        }
        guard let task = shutdownTask else { return }
        do { try await ExperienceRuntimeRetirement.wait(authoredTime: authoredTime) { await task.value } }
        catch { handleTerminalFailure(error) }
        if !isShuttingDown { shutdownTask = nil }
    }

    func setContentHidden(_ hidden: Bool) {
        if hidden { clearHardwareKeys() }
        contentHidden = hidden
        if hidden, requiresSceneSemantics { semanticContainer.setActive(false) }
        surfaceView.isHidden = hidden
        textInputOverlayBridge.setHidden(hidden || coveredByLayer)
        updatePresentationVisibility()
    }

    func layoutTextInputs() {
        textInputOverlayBridge.layout()
    }

    @discardableResult
    func applySnapshot(
        _ snapshot: ExperienceViewModelSnapshot,
        screenId targetScreenId: String?
    ) -> Bool {
        guard !isPageController || targetScreenId == nil || retainedScreenIDs.contains(targetScreenId!) else { return false }
        do {
            return enqueueJourneyStateCommand(try .snapshot(snapshot), screenID: targetScreenId)
        } catch {
            logRejectedState(error)
            return false
        }
    }

    @discardableResult
    func applyValue(
        path: VmPathRef,
        value: Any,
        screenId targetScreenId: String?,
        instanceId: String?
    ) -> Bool {
        guard targetScreenId == nil || retainedScreenIDs.contains(targetScreenId!) else { return false }
        do {
            return try enqueueJourneyStateCommand(screenID: targetScreenId) { row in
                try .value(
                    path: path,
                    rawValue: value,
                    instanceID: instanceId,
                    defaultViewModelName: row?.defaultViewModelName
                )
            }
        } catch {
            logRejectedState(error)
            return false
        }
    }

    @discardableResult
    func applyListOperation(
        _ operation: ExperienceViewModelListOperation,
        path: VmPathRef,
        payload: [String: Any],
        screenId targetScreenId: String?,
        instanceId: String?
    ) -> Bool {
        guard targetScreenId == nil || retainedScreenIDs.contains(targetScreenId!) else { return false }
        do {
            return try enqueueJourneyStateCommand(screenID: targetScreenId) { row in
                try .list(
                    operation: operation,
                    path: path,
                    payload: payload,
                    instanceID: instanceId,
                    defaultViewModelName: row?.defaultViewModelName
                )
            }
        } catch {
            logRejectedState(error)
            return false
        }
    }

    @discardableResult
    func fireTrigger(
        path: VmPathRef,
        screenId targetScreenId: String?,
        instanceId: String?
    ) -> Bool {
        guard targetScreenId == nil || retainedScreenIDs.contains(targetScreenId!) else { return false }
        do {
            return try enqueueJourneyStateCommand(screenID: targetScreenId) { row in
                guard let viewModelName = path.viewModelName ?? row?.defaultViewModelName else {
                    throw ExperienceInteractiveStateCommandError.invalidValue(
                        "Trigger path '\(path.path)' has no view-model identity"
                    )
                }
                return .trigger(viewModelName: viewModelName, instanceID: instanceId,
                    instanceName: nil, path: path.path)
            }
        } catch {
            logRejectedState(error)
            return false
        }
    }

    func advance(delta: Double = 0) {
        let timestamp = delta > 0 ? CACurrentMediaTime() + delta : CACurrentMediaTime()
        presentationLoop?.displayLinkDidFire(at: timestamp)
    }

    /// Native presentation starts after these writes, without waiting for a Screen timeline.
    func preparePagePresentationPhase(_ phase: ExperienceScreenLifecyclePhase, reduceMotion: Bool) async throws {
        guard let page = interactivePage else { throw ExperienceInteractiveScreenControllerError.unavailable }
        let id = screenId
        if phase == .entering, lifecycleState.phase == .entering {
            // A page mounted entering plays through UIKit's presentation with no second entering edge.
            presentationLoop?.setTimelineActive(true)
            return
        }
        try await pageWork {
            guard !(await page.isRowRemoved(screenID: id)) else { throw CancellationError() }
            try await page.setPhases([(id, phase)], reduceMotion: reduceMotion)
            return nil
        }
        lifecycleState = await page.state(screenID: id) ?? lifecycleState
        presentationLoop?.setTimelineActive(true)
    }

    func enter(reduceMotion: Bool) async {
        presentationLoop?.setTimelineActive(true)
        if isPageController, lifecycleState.phase == .entering {
            await updateReduceMotion(reduceMotion)
            return
        }
        let snapshot = lifecycleState.move(
            to: .entering,
            reduceMotion: reduceMotion
        )
        await applyLifecycleSnapshot(snapshot)
        try? await presentationLoop?.advanceZeroDelta()
    }

    func activate(reduceMotion: Bool) async {
        let snapshot = lifecycleState.move(
            to: .active,
            reduceMotion: reduceMotion
        )
        let write = await applyLifecycleSnapshot(snapshot)
        if requiresSceneSemantics, let write, semanticFocusLifecycle.admitsHandoff(from: write) {
            semanticContainer.requestFocusOnNextPresentation()
        }
        try? await presentationLoop?.advanceZeroDelta()
    }

    func hide(reduceMotion: Bool) async {
        clearHardwareKeys()
        presentationLoop?.setTimelineActive(false)
        let snapshot = lifecycleState.move(
            to: .hidden,
            reduceMotion: reduceMotion
        )
        await applyLifecycleSnapshot(snapshot)
        try? await presentationLoop?.advanceZeroDelta()
    }

    func writeCustomTransitionPhase(
        _ phase: ExperienceScreenLifecyclePhase,
        transitionId: String,
        reduceMotion: Bool,
        exitReason: ExperienceScreenExitReason
    ) async {
        if phase == .entering {
            presentationLoop?.setTimelineActive(true)
        }
        let snapshot = lifecycleState.move(
            to: phase,
            transition: transitionId,
            reduceMotion: reduceMotion,
            exitReason: exitReason
        )
        await applyLifecycleSnapshot(snapshot)
        try? await presentationLoop?.advanceZeroDelta()
    }

    func registerCompletionWaiter(eventName: String) -> CompletionWaiter {
        let id = UUID()
        let pair = AsyncStream<Void>.makeStream()
        exitWaiters[id] = (eventName, pair.continuation)
        return CompletionWaiter(id: id, stream: pair.stream)
    }

    func removeCompletionWaiter(_ waiter: CompletionWaiter) {
        if let registered = exitWaiters.removeValue(forKey: waiter.id) {
            registered.continuation.finish()
        }
    }

    func updateReduceMotion(_ reduceMotion: Bool) async {
        let snapshot = lifecycleState.updateReduceMotion(reduceMotion)
        await applyLifecycleSnapshot(snapshot)
        try? await presentationLoop?.advanceZeroDelta()
    }

    func performExitHandshake(reduceMotion: Bool, exitReason: ExperienceScreenExitReason) async {
        let plan = ExperienceScreenExitPlan(
            declaration: screen.exit,
            reduceMotion: reduceMotion
        )
        let waiter = plan.completionEventName.map(registerCompletionWaiter(eventName:))
        let snapshot = lifecycleState.move(
            to: .exiting,
            reduceMotion: reduceMotion,
            exitReason: exitReason
        )
        await applyLifecycleSnapshot(snapshot)
        try? await presentationLoop?.advanceZeroDelta()

        guard let watchdogMilliseconds = plan.watchdogMilliseconds,
              let waiter else { return }
        onExitCompletionWait?()
        await ExperienceAuthoredTime.during(authoredTime) {
            await ExperienceScreenExitWatchdog.wait(
                for: waiter.stream,
                watchdogMilliseconds: watchdogMilliseconds
            )
        }
        removeCompletionWaiter(waiter)
    }

    func markExiting(reduceMotion: Bool, exitReason: ExperienceScreenExitReason) async {
        let snapshot = lifecycleState.move(
            to: .exiting,
            reduceMotion: reduceMotion,
            exitReason: exitReason
        )
        await applyLifecycleSnapshot(snapshot)
        try? await presentationLoop?.advanceZeroDelta()
    }

    func syncSafeAreaInsets(force: Bool = false) {
        if force { lastPushedSafeAreaInsets = nil; lastPushedViewport = nil; lastPushedFold = nil }
        guard isViewLoaded, !isShuttingDown, runtimeFailure == nil,
              !environmentWriteQueued, let interactiveScreen, let presentationLoop else { return }
        let insets = experienceSafeAreaInsets(for: view)
        let viewport = viewportEnvironment()
        let fold = surfaceView.foldEnvironment
        guard insets != lastPushedSafeAreaInsets || viewport != lastPushedViewport || fold != lastPushedFold else { return }
        environmentWriteQueued = true
        if !presentationLoop.enqueue(ExperienceRuntimePresentationQueuedWork { [weak self] in
            guard let values = await self?.takeLatestEnvironment() else { return .work(requestsFrame: false) }
            if let layer = await self?.interactivePage {
                try await layer.updateEnvironment(fontScale: values.3, safeArea: values.0, viewport: values.1, fold: values.2)
            } else {
                try await interactiveScreen.updateEnvironment(fontScale: values.3,
                    safeArea: values.0, viewport: values.1, fold: values.2)
            }
            return .work(requestsFrame: true)
        }, completion: { [weak self] result in
            guard let self else { return }
            environmentWriteQueued = false
            if case .failure(let error) = result { handleTerminalFailure(error) }
            else { syncSafeAreaInsets() }
        }) {
            environmentWriteQueued = false
        }
    }

    /// Takes the host's current appearance for the time the screen is detached, and
    /// writes it if it changed, ahead of any work the screen is given next.
    func adoptHostTraits(_ hostTraits: UITraitCollection?) {
        detachedHostStyle = hostTraits?.userInterfaceStyle
        syncColorScheme()
    }

    /// Writes `env.colorScheme` and binds the matching `Theme` instance when the appearance
    /// changes. One write is in flight at a time, and it reads the latest appearance when it runs.
    func syncColorScheme() {
        guard isViewLoaded, !isShuttingDown, runtimeFailure == nil,
              !colorSchemeWriteQueued, let interactiveScreen, let presentationLoop,
              colorScheme != lastPushedColorScheme else { return }
        colorSchemeWriteQueued = true
        if !presentationLoop.enqueue(ExperienceRuntimePresentationQueuedWork { [weak self] in
            guard let colorScheme = await self?.takeLatestColorScheme() else { return .work(requestsFrame: false) }
            if let layer = await self?.interactivePage { try await layer.updateEnvironment(colorScheme: colorScheme) }
            else { try await interactiveScreen.updateEnvironment(colorScheme: colorScheme) }
            return .work(requestsFrame: true)
        }, completion: { [weak self] result in
            guard let self else { return }
            colorSchemeWriteQueued = false
            if case .failure(let error) = result { handleTerminalFailure(error) }
            else { syncColorScheme() }
        }) {
            colorSchemeWriteQueued = false
        }
    }

    private func takeLatestColorScheme() -> ExperienceColorScheme? {
        let latest = colorScheme
        guard !isShuttingDown, runtimeFailure == nil, latest != lastPushedColorScheme else { return nil }
        lastPushedColorScheme = latest
        return latest
    }

    private func viewportEnvironment() -> ExperienceViewportEnvironment {
        ExperienceViewportEnvironment(width: Double(surfaceView.bounds.width),
            height: Double(measuresContentHeight ? (availablePresentationHeight ?? surfaceView.bounds.height) : surfaceView.bounds.height))
    }

    /// Reads at execution time so rapid hinge callbacks cannot grow the queue.
    private func takeLatestEnvironment() -> (ExperienceSafeAreaInsets, ExperienceViewportEnvironment, ExperienceFoldEnvironment, Double)? {
        guard !isShuttingDown, runtimeFailure == nil else { return nil }
        let values = (experienceSafeAreaInsets(for: view), viewportEnvironment(), surfaceView.foldEnvironment,
                      Self.fontScale(for: traitCollection))
        lastPushedSafeAreaInsets = values.0
        lastPushedViewport = values.1
        lastPushedFold = values.2
        return values
    }

    /// Reads the captured field through the same serial lane as input and presentation.
    func readPresentedFieldString(captureID: UUID, nodeID: UInt32, name: String) async throws -> String {
        guard !isShuttingDown, runtimeFailure == nil,
              let interactiveScreen, let presentationLoop else { throw CancellationError() }
        return try await withCheckedThrowingContinuation { continuation in
            presentationLoop.enqueue(ExperienceRuntimePresentationQueuedWork {
                let value = try await interactiveScreen.readPresentedFieldString(
                    captureID: captureID, nodeID: nodeID, name: name)
                return .work(requestsFrame: false) { continuation.resume(returning: value) }
            }, completion: { result in
                if case .failure(let error) = result { continuation.resume(throwing: error) }
            })
        }
    }

    private func enqueueStateCommand(
        _ command: ExperienceInteractiveStateCommand,
        logFailure: Bool = true,
        reduceMotion: Bool? = nil,
        requestsFrame: Bool = true,
        completion: (@MainActor @Sendable (Result<Void, Error>) -> Void)? = nil
    ) -> Bool {
        guard !isShuttingDown,
              runtimeFailure == nil,
              let interactiveScreen,
              let presentationLoop else { return false }
        let sourceID = screenId
        return presentationLoop.enqueue(
            ExperienceRuntimePresentationQueuedWork {
                try await interactiveScreen.updateEnvironment(reduceMotion: reduceMotion)
                let result = try await interactiveScreen.applyStateCommand(command)
                return .work(requestsFrame: requestsFrame) { [weak self = self] in
                    await self?.deliverStep(effects: result.effects, screenID: sourceID)
                }
            },
            completion: { [weak self] result in
                if logFailure, case .failure(let error) = result {
                    self?.logRejectedState(error)
                }
                completion?(result)
            }
        )
    }

    /// A Journey write to one page row. The row is looked up when the write runs,
    /// because a revisit may have replaced it. A removed row takes no writes (R6b):
    /// they wait, in order, and reach the Screen's next row before any later write.
    /// A nil command only delivers the writes that are waiting.
    private func enqueueRowWrite(_ command: ExperienceInteractiveStateCommand?, screenID: String) -> Bool {
        guard !isShuttingDown, runtimeFailure == nil, rowBindings[screenID] != nil,
              let presentationLoop else { return false }
        return presentationLoop.enqueue(
            ExperienceRuntimePresentationQueuedWork { [weak self] in
                guard let row = await self?.rowBindings[screenID] else { return .work(requestsFrame: false) {} }
                if await row.isRemovedPageRow {
                    return .work(requestsFrame: false) { [weak self] in
                        self?.holdRowWrite(command, screenID: screenID, removedRow: row)
                    }
                }
                let commands = (await self?.takeHeldRowWrites(screenID) ?? []) + (command.map { [$0] } ?? [])
                guard !commands.isEmpty else { return .work(requestsFrame: false) {} }
                try await row.updateEnvironment(reduceMotion: nil)
                var applied: [ExperienceInteractiveEffect] = []
                for pending in commands { applied += try await row.applyStateCommand(pending).effects }
                let effects = applied
                return .work(requestsFrame: true) { [weak self] in
                    await self?.deliverStep(effects: effects, screenID: screenID)
                }
            },
            completion: { [weak self] result in
                if case .failure(let error) = result { self?.logRejectedState(error) }
            }
        )
    }

    private func holdRowWrite(_ command: ExperienceInteractiveStateCommand?, screenID: String,
                              removedRow: ExperienceInteractiveScreen) {
        if let command { heldRowWrites[screenID, default: []].append(command) }
        // A revisit may have seeded the next row while this write was looking.
        if rowBindings[screenID] !== removedRow, heldRowWrites[screenID] != nil {
            _ = enqueueRowWrite(nil, screenID: screenID)
        }
    }

    private func takeHeldRowWrites(_ screenID: String) -> [ExperienceInteractiveStateCommand] {
        heldRowWrites.removeValue(forKey: screenID) ?? []
    }

    private func journeyScreen(for id: String?) -> JourneyScreen? {
        rowScreens[id ?? screenId] ?? experience.screens.screens.first { $0.id == (id ?? screenId) }
    }

    private func enqueueJourneyStateCommand(_ command: ExperienceInteractiveStateCommand, screenID: String? = nil) -> Bool {
        enqueueJourneyStateCommand(screenID: screenID) { _ in command }
    }

    private func enqueueJourneyStateCommand(
        screenID: String?,
        commandForScreen: (JourneyScreen?) throws -> ExperienceInteractiveStateCommand
    ) rethrows -> Bool {
        if !isPageController {
            guard let filtered = try commandForScreen(journeyScreen).suppressingLifecycleReservedJourneyWrites(
                rootViewModelName: journeyScreen?.defaultViewModelName,
                rootInstanceID: journeyScreen?.defaultInstanceId) else { return true }
            return enqueueStateCommand(filtered)
        }
        let ids = screenID.map { [$0] } ?? retainedScreenIDs
        var accepted = false
        for id in ids {
            let row = journeyScreen(for: id)
            guard let filtered = try commandForScreen(row).suppressingLifecycleReservedJourneyWrites(
                rootViewModelName: row?.defaultViewModelName, rootInstanceID: row?.defaultInstanceId) else {
                accepted = true
                continue
            }
            accepted = enqueueRowWrite(filtered, screenID: id) || accepted
        }
        return accepted
    }

    private func applySemantics(_ capture: NuxieNativeSemanticCapture) {
        if pageStepInProgress {
            _ = textInputOverlayBridge.applySemantics(capture)
            return
        }
        guard !pageStepInProgress, !isShuttingDown, !contentHidden, controllerIsVisible,
              let interactiveScreen, let presentationLoop,
              let transform = ExperienceLayoutTransform(
                artboardBounds: interactivePage?.artboardBounds ?? interactiveScreen.artboardBounds,
                viewportBounds: surfaceView.bounds) else { return }
        onSemanticCapture?(capture)
        let nativeControls = textInputOverlayBridge.applySemantics(capture)
        semanticContainer.update(capture: capture, nativeControls: nativeControls, project: { [weak self] node in
            guard let self, let role = NuxieNativeSemanticRole(rawValue: node.role), role != .none else { return nil }
            let frame = transform.viewportRect(fromArtboard: node.bounds).intersection(self.surfaceView.bounds)
            guard !frame.isNull, !frame.isInfinite, !frame.isEmpty else { return nil }
            var traits: UIAccessibilityTraits = []
            switch role {
            case .button, .checkbox, .switchControl, .radioButton, .tab: traits.insert(.button)
            case .link: traits.insert(.link)
            case .slider: traits.insert(.adjustable)
            case .text: traits.insert(.staticText)
            case .image: traits.insert(.image)
            case .group, .list, .listItem, .tabList, .dialog, .alertDialog, .radioGroup:
                guard !node.label.isEmpty else { return nil }
            case .none, .textField: break
            }
            if node.headingLevel > 0 { traits.insert(.header) }
            return .init(frame: frame, traits: traits)
        }, submit: { [weak self] captureID, nodeID, action in
            guard let self else { return false }
            return presentationLoop.enqueueInteraction(ExperienceRuntimePresentationQueuedWork {
                guard !(await interactiveScreen.isRemovedPageRow) else { throw CancellationError() }
                try await interactiveScreen.queueSemanticAction(captureID: captureID, nodeID: nodeID, action: action)
                return .work(requestsFrame: true)
            }, isEligible: { [weak self] in self?.semanticInputIsEligible == true })
        })
    }

    private func configureTextInputCallbacks() {
        textInputOverlayBridge.onAcceptedTextChange = { [weak self] _, _ in
            guard let self, let screen = self.interactiveScreen,
                  let loop = self.presentationLoop else { return }
            loop.enqueueInteraction(ExperienceRuntimePresentationQueuedWork {
                let step = try await screen.step(elapsedSeconds: 0)
                return .work(requestsFrame: true) { [weak self = self] in
                    await self?.deliverStep(step)
                }
            }, isEligible: { [weak self] in self?.semanticInputIsEligible == true }, completion: { [weak self] result in
                if case .failure(let error) = result, !(error is CancellationError) {
                    self?.handleTerminalFailure(error)
                }
            })
        }
        textInputOverlayBridge.onEditingEvent = { [weak self] input, event in
            // The signed input policy selects one lifecycle event. Return and
            // editing-ended may both occur, but invoke this action only once.
            guard event.kind == (input.actionEvent ?? .editingEnded),
                  let self, let interactiveScreen = self.interactiveScreen,
                  let loop = self.presentationLoop else { return }
            let originatingRun = self.delegate?.screenEmissionRun(for: self)
            loop.enqueueInteraction(ExperienceRuntimePresentationQueuedWork {
                guard !(await interactiveScreen.isRemovedPageRow) else { throw CancellationError() }
                let result = try await interactiveScreen.commitTextInput(inputID: input.inputId, value: event.text, ownerInstanceID: event.ownerInstanceID)
                return .work(requestsFrame: result != nil) { [weak self = self] in
                    guard let self, self.semanticInputIsEligible else { return }
                    if let result {
                        await self.deliverStep(effects: result.effects)
                    } else if let invocation = input.declarativeInvocation(for: event) {
                        await self.delegate?.experienceScreenViewController(
                            self,
                            didEmitScreenEmission: .control(
                                screenId: input.screenId,
                                invocation: invocation,
                                additionalDrafts: []
                            ),
                            originatingRun: originatingRun,
                            frameSources: nil
                        )
                    }
                }
            }, isEligible: { [weak self] in self?.semanticInputIsEligible == true }, completion: { [weak self] result in
                if case .failure(let error) = result { self?.logRejectedState(error) }
            })
        }
    }

    private var semanticInputIsEligible: Bool {
        !pageStepInProgress && !isShuttingDown && runtimeFailure == nil && !contentHidden && controllerIsVisible && !coveredByLayer && lifecyclePhase == .active
            && ExperienceSemanticAccessibilityElement.allowsInteraction(in: surfaceView)
    }

    /// Runs only inside the presentation loop's serialized interaction work.
    private func performNativeEditing(
        screen: ExperienceInteractiveScreen, loop: ExperienceRuntimePresentationLoop,
        captureID: UUID?, target: ExperienceTextInputOverlayBridge.InputTarget,
        point: CGPoint?, text: String? = nil, ending: Bool = false, ownerID: UInt64? = nil
    ) async throws {
        guard !(await screen.isRemovedPageRow) else { throw CancellationError() }
        func apply(_ step: ExperienceInteractiveStepResult) async {
            await deliverStep(step)
        }
        if ending {
            if nativeEditingTarget == target && nativeEditingOwnerID == ownerID {
                nativeEditingTarget = nil
                await apply(try await screen.step(focusInputs: [.clear], elapsedSeconds: 0))
            }
            return
        }
        guard let captureID, let nodeID = target.nodeID else { throw CancellationError() }
        // Validate the exact presented occurrence before any tap or text input.
        let source = try await screen.readSemanticText(captureID: captureID, inputID: target.inputID, nodeID: nodeID)
        if text == nil || nativeEditingTarget != target || nativeEditingOwnerID != source.ownerInstanceID || !riveFocusState.hasFocus || !riveFocusState.expectsKeyboardInput {
            guard let point else { throw CancellationError() }
            nativeEditingTarget = nil
            for pointers in loop.takeNativeEditingTap(at: point) {
                guard semanticInputIsEligible else { throw CancellationError() }
                await apply(try await screen.step(pointers: pointers, elapsedSeconds: 0))
            }
            guard riveFocusState.hasFocus && riveFocusState.expectsKeyboardInput else { throw CancellationError() }
            nativeEditingTarget = target
            nativeEditingOwnerID = source.ownerInstanceID
        }
        if let text {
            let input = artifact.renderPlan.textInputs.first { $0.screenId == screenId && $0.inputId == target.inputID }
            let text = ExperienceTextInputLimit.apply(text, maximum: input?.maxLength)
            var inputs = ExperienceFocusInputQueue()
            inputs.append(.key(code: 65, modifiers: 8, pressed: true, repeated: false))
            inputs.append(.key(code: 65, modifiers: 8, pressed: false, repeated: false))
            if text.isEmpty {
                inputs.append(.key(code: 259, modifiers: 0, pressed: true, repeated: false))
                inputs.append(.key(code: 259, modifiers: 0, pressed: false, repeated: false))
            } else { inputs.append(.text(text)) }
            while !inputs.isEmpty {
                guard semanticInputIsEligible else { throw CancellationError() }
                await apply(try await screen.step(focusInputs: inputs.takeBatch(), elapsedSeconds: 0))
            }
        }
    }

    private func bindTextInputs(
        to interactiveScreen: ExperienceInteractiveScreen,
        loop: ExperienceRuntimePresentationLoop,
        preservingNativeFields: Bool = false
    ) {
        if !preservingNativeFields { nativeEditingTarget = nil }
        textInputOverlayBridge.onWillBeginEditing = { [weak self] in self?.clearHardwareKeys() }
        textInputOverlayBridge.onNativeEditing = { [weak self] captureID, target, point, editing, ownerID, completion in
            loop.enqueueInteraction(ExperienceRuntimePresentationQueuedWork { [weak self] in
                guard let self else { throw CancellationError() }
                do {
                    try await self.performNativeEditing(screen: interactiveScreen, loop: loop,
                        captureID: captureID, target: target, point: point, ending: !editing, ownerID: ownerID)
                    return .work(requestsFrame: true) { completion(.accepted) }
                } catch NuxieNativeRuntimeError.callFailed(let diagnostic) where diagnostic.status == .handleMismatch {
                    return .work(requestsFrame: true) { completion(.staleCapture) }
                }
            }, isEligible: { [weak self] in self?.semanticInputIsEligible == true }, completion: { result in
                if case .failure = result { completion(.rejected) }
            })
        }
        let semanticWriter: ExperienceTextInputOverlayBridge.SemanticTextWriter? = requiresSceneSemantics
            ? { [weak self] captureID, target, text, completion in
                let point = self?.textInputOverlayBridge.editingPoint(for: target)
                loop.enqueueInteraction(ExperienceRuntimePresentationQueuedWork { [weak self] in
                    guard let self else { throw CancellationError() }
                    do {
                        try await self.performNativeEditing(screen: interactiveScreen, loop: loop,
                            captureID: captureID, target: target, point: point, text: text)
                        return .work(requestsFrame: true) { completion(.accepted) }
                    } catch NuxieNativeRuntimeError.callFailed(let diagnostic)
                        where diagnostic.status == .handleMismatch {
                        return .work(requestsFrame: true) { completion(.staleCapture) }
                    } catch {
                        return .work(requestsFrame: false) { completion(.rejected) }
                    }
                }, isEligible: { [weak self] in self?.semanticInputIsEligible == true }, completion: { result in
                    if case .failure = result { completion(.rejected) }
                })
            }
            : nil
        textInputOverlayBridge.bind(
            screenID: screenId,
            preservingNativeFields: preservingNativeFields,
            renderPlan: artifact.renderPlan,
            surfaceView: surfaceView,
            artboardBounds: interactivePage?.artboardBounds ?? interactiveScreen.artboardBounds,
            semanticTextWriter: semanticWriter,
            semanticContentOffsetWriter: { [weak self] captureID, target, offset, completion in
                loop.enqueueInteraction(ExperienceRuntimePresentationQueuedWork {
                    guard let nodeID = target.nodeID else {
                        return .work(requestsFrame: false) { completion(.rejected) }
                    }
                    do {
                        guard !(await interactiveScreen.isRemovedPageRow) else { throw CancellationError() }
                        try await interactiveScreen.setSemanticInputContentOffset(captureID: captureID,
                            inputID: target.inputID, nodeID: nodeID, offset: offset)
                        return .work(requestsFrame: true) { completion(.accepted) }
                    } catch NuxieNativeRuntimeError.callFailed(let diagnostic)
                        where diagnostic.status == .handleMismatch {
                        return .work(requestsFrame: true) { completion(.staleCapture) }
                    } catch {
                        return .work(requestsFrame: false) { completion(.rejected) }
                    }
                }, isEligible: { [weak self] in self?.semanticInputIsEligible == true }, completion: { result in
                    if case .failure = result { completion(.rejected) }
                })
            },
            semanticTextReader: { captureID, target, completion in
                // Source initialization also runs during first presentation, before
                // interaction admission opens. The capture and owner fence the read.
                loop.enqueue(ExperienceRuntimePresentationQueuedWork {
                    guard let nodeID = target.nodeID else {
                        return .work(requestsFrame: false) {
                            completion(.failure(ExperienceInteractiveScreenError.stateContract("Missing native input occurrence")))
                        }
                    }
                    do {
                        let value = try await interactiveScreen.readSemanticText(
                            captureID: captureID, inputID: target.inputID, nodeID: nodeID)
                        return .work(requestsFrame: false) { completion(.success(value)) }
                    } catch {
                        let stale = if case NuxieNativeRuntimeError.callFailed(let diagnostic) = error {
                            diagnostic.status == .handleMismatch
                        } else { false }
                        return .work(requestsFrame: stale) { completion(.failure(error)) }
                    }
                }, completion: { result in
                    if case .failure(let error) = result { completion(.failure(error)) }
                })
            }
        )
    }

    private func refreshTextInputLayouts() {
        guard artifact.renderPlan.textInputs.contains(where: {
            $0.screenId == screenId && $0.editable
        }), let presentationLoop else { return }
        presentationLoop.enqueue(ExperienceRuntimePresentationQueuedWork {
            .work(requestsFrame: true)
        })
    }

    private var pendingFramePublications = 0

    func deliverStep(_ step: ExperienceInteractiveStepResult, screenID: String? = nil) async {
        if let state = step.focusState { riveFocusState = state }
        if let pageStep = step.pageStep {
            await deliverPageStep(pageStep)
        } else {
            await deliverStep(effects: step.effects, screenID: screenID)
        }
    }

    func deliverStep(effects: [ExperienceInteractiveEffect], screenID: String? = nil) async {
        let screenId = screenID ?? self.screenId
        let interactiveBinding = rowBindings[screenId] ?? interactiveScreen
        guard !isShuttingDown, runtimeFailure == nil else { return }
        let originatingRun = delegate?.screenEmissionRun(for: self)
        let openLink = delegate?.captureLinkHandler(for: self)
        var assembler = ExperienceRuntimeScreenEmissionAssembler()
        var frameSources = ExperienceEmissionSources()
        var links: [ExperienceRendererOpenLinkRequest] = []
        for effect in effects {
            guard !isShuttingDown, runtimeFailure == nil else { return }
            if let request = effect.responseSave {
                frameSources.saves.append(ExperienceFrameSave(request: request, screenID: screenId,
                    onConfirmed: { [weak self] in
                        guard let self, let originatingRun,
                              self.delegate?.screenEmissionRun(for: self) == originatingRun,
                              !self.isShuttingDown, self.runtimeFailure == nil,
                              let interactive = interactiveBinding,
                              let path = request.awaitTrigger else { return }
                        _ = self.presentationLoop?.enqueue(ExperienceRuntimePresentationQueuedWork {
                            let step = try await interactive.confirmResponseSave(trigger: path, kept: request.kept)
                            return .work(requestsFrame: true) { [weak self = self] in
                                await self?.deliverStep(step, screenID: screenId)
                            }
                        })
                    }))
                continue
            }
            guard let projected = await route(effect, screenID: screenId) else { continue }
            switch projected {
            case .link(let request):
                links.append(request)
            case .control(let screenId, let invocation):
                if case .controlAction(_, let event) = effect.kind {
                    frameSources.control = event.resolvedSource
                }
                assembler.appendControl(screenId: screenId, invocation: invocation)
            case .draft(let draft, let draftSource):
                guard !draft.isReservedEvent else { continue }
                if case .reportedEvent(let event) = effect.kind {
                    frameSources.drafts.append(event.resolvedSource)
                } else {
                    frameSources.drafts.append(nil)
                }
                assembler.appendDraft(draft, source: draftSource)
            }
        }
        var emission: ExperienceRuntimeScreenEmission?
        switch assembler.assembled() {
        case .failure:
            LogWarning(
                "ExperienceScreenViewController: rejected native transaction with multiple controls"
            )
            emission = nil
        case .success(let assembled):
            emission = assembled
        }
        if emission == nil && !frameSources.saves.isEmpty {
            emission = .effects(source: ScreenEmissionSource(screenId: screenId,
                actionId: "runtime-save", componentId: nil, instanceId: nil), drafts: [])
        }
        let frameLinks = ExperienceFrameLinks {
            for link in links { await openLink?(link) }
        }
        frameSources.frameLinks = frameLinks
        let publish = { @MainActor [self, delegate, frameSources] in
            if let emission {
                await delegate?.experienceScreenViewController(
                    self,
                    didEmitScreenEmission: emission,
                    originatingRun: originatingRun,
                    frameSources: frameSources
                )
            }
            // JourneyService consumes these before continuing an accepted batch.
            // Rejected and link-only frames still own their independent links.
            await frameLinks.perform()
        }
        // A link-bearing frame returns before its emission publishes.
        // The publication gate preserves emission order across frames.
        if links.isEmpty && pendingFramePublications == 0 {
            await publish()
        } else {
            pendingFramePublications += 1
            Task { @MainActor in
                defer { pendingFramePublications -= 1 }
                await publish()
            }
        }
    }

    func route(
        _ effect: ExperienceInteractiveEffect, screenID: String? = nil
    ) async -> ExperienceRuntimeProjectedEmission? {
        let screenId = screenID ?? self.screenId
        let interactiveScreen = rowBindings[screenId] ?? self.interactiveScreen
        switch effect.kind {
        case .controlAction(let actionId, let event):
            guard Set(event.properties.map(\.key)).count == event.properties.count else { return nil }
            let properties = Dictionary(uniqueKeysWithValues: event.properties.map {
                ($0.key, Self.rendererValue($0.value))
            })
            let eventScreenID = isPageController ? screenId : Self.stringProperty(
                ["screenId", "screen_id"],
                in: properties
            ) ?? screenId
            return .control(
                screenId: eventScreenID,
                invocation: ScreenActionInvocation(
                    actionId: actionId,
                    value: properties["value"].map(ScreenEmissionValue.init(rendererValue:)),
                    componentId: Self.stringProperty(
                        ["componentId", "component_id", "elementId", "element_id"],
                        in: properties
                    ),
                    instanceId: Self.stringProperty(
                        ["instanceId", "instance_id"],
                        in: properties
                    )
                )
            )
        case .reportedEvent(let event):
            if screenId == self.screenId { resolveExitWaiters(eventName: event.name) }
            let properties = Dictionary(event.properties.map {
                ($0.key, Self.rendererValue($0.value))
            }, uniquingKeysWith: { first, _ in first })
            // Whose event it is comes from the runtime's report, never from
            // its values: a field named screenId or instanceId is the
            // author's (D2.54).
            let instanceID = event.sourceRejection == nil ? event.sourceInstanceAlias : nil
            if !event.url.isEmpty {
                return .link(ExperienceRendererOpenLinkRequest(
                    urlString: event.url,
                    target: event.target,
                    screenId: screenId,
                    instanceId: instanceID
                ))
            } else if !event.name.isEmpty {
                return .draft(
                    .event(name: event.name, payload: properties.mapValues(
                        ScreenEmissionValue.init(rendererValue:)
                    )),
                    source: ScreenEmissionSource(
                        screenId: screenId,
                        actionId: "runtime:\(effect.correlationID)",
                        componentId: nil,
                        instanceId: instanceID
                    )
                )
            }
            return nil
        case .viewModelChange(let change):
            guard change.origin == .runtime, let interactiveScreen else { return nil }
            do {
                let resolved = try await interactiveScreen.resolveViewModelChange(change)
                delegate?.experienceScreenViewController(
                    self,
                    didEmitViewModelChange: ExperienceRendererViewModelChange(
                        path: VmPathRef(
                            viewModelName: resolved.viewModelName,
                            path: resolved.path
                        ),
                        value: Self.rendererValue(resolved.value),
                        source: "runtime",
                        screenId: screenId,
                        instanceId: resolved.instanceID,
                        isTrigger: resolved.isTrigger
                    )
                )
            } catch {
                handleTerminalFailure(error)
            }
            return nil
        case .journeyEvent(let name, let payload),
             .hostCommand(let name, let payload):
            let properties = Self.rendererProperties(payload)
            return .draft(
                .event(
                    name: name,
                    payload: properties.mapValues(ScreenEmissionValue.init(rendererValue:))
                ),
                source: ScreenEmissionSource(
                    screenId: isPageController ? screenId : Self.stringProperty(
                        ["screenId", "screen_id"], in: properties
                    ) ?? screenId,
                    actionId: "runtime:\(effect.correlationID)",
                    componentId: Self.stringProperty(
                        ["componentId", "component_id", "elementId", "element_id"],
                        in: properties
                    ),
                    instanceId: Self.stringProperty(
                        ["instanceId", "instance_id"], in: properties
                    )
                )
            )
        case .rejectedHostCommand(let name, let reason):
            LogWarning(
                "ExperienceScreenViewController: rejected host command '\(name)' on \(screenId): \(reason)"
            )
            return nil
        }
    }

    private func runtimeEmissionSource(
        for effect: ExperienceInteractiveEffect
    ) -> ScreenEmissionSource {
        ScreenEmissionSource(
            screenId: screenId,
            actionId: "runtime:\(effect.correlationID)",
            componentId: nil,
            instanceId: nil
        )
    }

    private func updatePresentationVisibility() {
        if controllerIsVisible && !contentHidden { syncSafeAreaInsets(force: true) }
        if requiresSceneSemantics {
            semanticContainer.setActive(semanticInputIsEligible && semanticFocusLifecycle.canExposeCurrentScene)
        }
        textInputOverlayBridge.setHidden(contentHidden || coveredByLayer || !controllerIsVisible)
        videoCaptionOverlay.isHidden = !controllerIsVisible || coveredByLayer || contentHidden || runtimeFailure != nil
        if videoCaptionOverlay.isHidden { videoCaptionOverlay.update([]) }
        presentationLoop?.setPresentationVisible(
            (isPageController ? controllerIsVisible && !coveredByLayer : controllerIsVisible || coveredByLayer) && !contentHidden)
    }

    private func handleTerminalFailure(_ error: Error) {
        guard (!isShuttingDown || error is ExperienceRuntimeRetirementError), runtimeFailure == nil else { return }
        runtimeFailure = error
        videoCaptionOverlay.update([])
        videoCaptionOverlay.isHidden = true
        if requiresSceneSemantics { semanticContainer.clear() }
        finishExitWaiters()
        surfaceView.isHidden = true
        textInputOverlayBridge.setHidden(true)
        LogError(
            "ExperienceScreenViewController: interactive screen \(screenId) failed: \(error)"
        )
        onRuntimeFailure?(error)
    }

    private func logRejectedState(_ error: Error) {
        LogWarning(
            "ExperienceScreenViewController: rejected state for \(screenId): \(error)"
        )
    }

    @discardableResult
    private func applyLifecycleSnapshot(_ snapshot: ExperienceScreenLifecycleSnapshot) async -> UUID? {
        let write = semanticFocusLifecycle.beginWrite(phase: snapshot.phase)
        if requiresSceneSemantics {
            semanticContainer.setActive(semanticInputIsEligible && semanticFocusLifecycle.canExposeCurrentScene)
        }
        if let interactivePage, let presentationLoop {
            let id = screenId
            do {
                try await presentationLoop.advanceZeroDelta(after: .init {
                    try await interactivePage.updateEnvironment(reduceMotion: snapshot.reduceMotion)
                    if !(await interactivePage.isRowRemoved(screenID: id)) {
                        try await interactivePage.applyLifecycleSnapshot(snapshot, screenID: id)
                    }
                    return .work(requestsFrame: false)
                })
                _ = semanticFocusLifecycle.completeWrite(write, succeeded: true)
                updatePresentationVisibility()
                return write
            } catch {
                _ = semanticFocusLifecycle.completeWrite(write, succeeded: false)
                handleTerminalFailure(error)
                return nil
            }
        }
        guard !lifecycleWritesUnavailable else { return nil }
        // Rootless screens still receive the file's global device values.
        let command: ExperienceInteractiveStateCommand
        if let name = journeyScreen?.defaultViewModelName {
            command = snapshot.stateCommand(
                viewModelName: name,
                instanceID: journeyScreen?.defaultInstanceId,
                includesExitReason: lifecycleIncludesExitReason
            )
        } else {
            command = .snapshot([])
        }
        let result: Result<Void, Error> = await withCheckedContinuation { continuation in
            let accepted = enqueueStateCommand(
                command,
                logFailure: false,
                reduceMotion: snapshot.reduceMotion,
                requestsFrame: false,
                completion: { continuation.resume(returning: $0) }
            )
            if !accepted {
                continuation.resume(returning: .failure(
                    ExperienceInteractiveScreenControllerError.unavailable
                ))
            }
        }
        if case .failure(let error) = result {
            semanticFocusLifecycle.completeWrite(write, succeeded: false)
            updatePresentationVisibility()
            markLifecycleWritesUnavailable(error.localizedDescription)
            return nil
        }
        guard semanticFocusLifecycle.completeWrite(write, succeeded: true) else { return nil }
        updatePresentationVisibility()
        return write
    }

    private func markLifecycleWritesUnavailable(_ reason: String) {
        lifecycleWritesUnavailable = true
        guard !didLogUnavailableLifecycleWrite else { return }
        didLogUnavailableLifecycleWrite = true
        LogWarning(
            """
            ExperienceScreenViewController: lifecycle state is unavailable \
            for \(screenId); skipping host writes: \(reason)
            """
        )
    }

    private func resolveExitWaiters(eventName: String) {
        guard !eventName.isEmpty else { return }
        let matches = exitWaiters.filter { $0.value.eventName == eventName }
        for (id, waiter) in matches {
            exitWaiters.removeValue(forKey: id)
            waiter.continuation.yield(())
            waiter.continuation.finish()
        }
    }

    private func finishExitWaiters() {
        let waiters = exitWaiters.values
        exitWaiters.removeAll()
        waiters.forEach { $0.continuation.finish() }
    }

    private static func rendererProperties(
        _ value: ExperienceInteractiveValue
    ) -> [String: Any] {
        guard case .object(let fields) = value else {
            return ["value": rendererValue(value)]
        }
        return Dictionary(uniqueKeysWithValues: fields.map {
            ($0.key, rendererValue($0.value))
        })
    }

    private static func rendererValue(_ value: ExperienceInteractiveValue) -> Any {
        switch value {
        case .null: NSNull()
        case .bool(let value): value
        case .number(let value): value
        case .string(let value): value
        case .bytes(let value): String(data: value, encoding: .utf8) ?? value
        case .list(let values): values.map(rendererValue)
        case .object(let fields): Dictionary(uniqueKeysWithValues: fields.map {
            ($0.key, rendererValue($0.value))
        })
        }
    }

    private static func stringProperty(
        _ names: [String],
        in properties: [String: Any]
    ) -> String? {
        for name in names {
            if let value = properties[name] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    private static func pixelDimension(_ value: Double) -> UInt32 {
        guard value.isFinite, value > 0 else { return 1 }
        return UInt32(min(value.rounded(.up), Double(UInt32.max)))
    }

    deinit {
        let loop = presentationLoop
        NotificationCenter.default.removeObserver(self)
        Task { @MainActor in
            await loop?.shutdown()
        }
    }
}
#endif
