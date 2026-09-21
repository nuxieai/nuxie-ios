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

private enum ExperienceRuntimeProjectedEmission {
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
        originatingRun: ScreenEmissionRun?
    ) async

    func experienceScreenViewController(
        _ controller: ExperienceScreenViewController,
        didEmitViewModelChange change: ExperienceRendererViewModelChange
    )

    func experienceScreenViewController(
        _ controller: ExperienceScreenViewController,
        didRequestOpenLink request: ExperienceRendererOpenLinkRequest
    )

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

/// UIKit owner for one Swift-authenticated, raw-C interactive screen.
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
    private let screen: NativeExperienceScreen
    private let surfaceView = ExperienceRuntimeSurfaceView(frame: .zero)
    private let textInputOverlayBridge = ExperienceTextInputOverlayBridge()
    private let videoCaptionOverlay = ExperienceVideoCaptionOverlay()
    private let videoDecoderPool: ExperienceVideoDecoderPool?
    private var requiresSceneSemantics: Bool {
        artifact.payload.requiredCapabilities.contains("experience-accessibility") ||
            artifact.renderPlan.textInputs.contains {
                $0.screenId == screenId && $0.editable && $0.editableValueName != nil
            }
    }
    private lazy var semanticContainer = ExperienceSemanticAccessibilityContainer(view: surfaceView)

    private var interactiveScreen: ExperienceInteractiveScreen?
    private var presentationLoop: ExperienceRuntimePresentationLoop?
    private var runtimeFailure: Error?
    private var isShuttingDown = false
    private var shutdownTask: Task<Void, Never>?
    private var contentHidden = false
    private var semanticFocusLifecycle = ExperienceSemanticFocusLifecycle()
    private var controllerIsVisible = false
    private var lastPushedFontScale: Double?
    private var lastPushedSafeAreaInsets: ExperienceSafeAreaInsets?
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

    weak var delegate: ExperienceScreenViewControllerDelegate?

    var screenId: String { screen.screenId }
    var lifecyclePhase: ExperienceScreenLifecyclePhase { lifecycleState.phase }

    private var journeyScreen: JourneyScreen? {
        experience.screens.screens.first { $0.id == screenId }
    }

    init(
        experience: Experience,
        artifact: LoadedExperienceArtifact,
        screen: NativeExperienceScreen,
        reduceMotion: Bool,
        presentationDiagnosticsEnabled: Bool = false,
        videoDecoderPool: ExperienceVideoDecoderPool? = nil,
        delegate: ExperienceScreenViewControllerDelegate?
    ) {
        self.experience = experience
        self.artifact = artifact
        self.screen = screen
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
        view.accessibilityIdentifier = "nuxie-screen-controller-\(screenId)"

        surfaceView.translatesAutoresizingMaskIntoConstraints = false
        surfaceView.accessibilityIdentifier = "nuxie-experience-surface"
        if presentationDiagnosticsEnabled {
            surfaceView.accessibilityValue = "first-frame-presentation:pending"
        }
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

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        controllerIsVisible = true
        updatePresentationVisibility()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        controllerIsVisible = false
        updatePresentationVisibility()
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
        syncFontScale()
    }

    @objc private func contentSizeCategoryDidChange() {
        syncFontScale()
    }

    static func fontScale(for traits: UITraitCollection) -> Double {
        Double(UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits).pointSize / 17)
    }

    private func syncFontScale(force: Bool = false) {
        guard isViewLoaded,
              let viewModelName = journeyScreen?.defaultViewModelName else { return }
        let scale = Self.fontScale(for: traitCollection)
        guard force || scale != lastPushedFontScale else { return }
        let command = ExperienceInteractiveStateCommand.snapshot([
            .init(
                viewModelName: viewModelName,
                instanceID: journeyScreen?.defaultInstanceId,
                instanceName: nil,
                path: "fontScale",
                value: .number(scale)
            ),
        ])
        if enqueueStateCommand(command, logFailure: false) {
            lastPushedFontScale = scale
        }
    }

    func mountInteractiveScreen() async throws {
        guard interactiveScreen == nil, presentationLoop == nil else {
            throw ExperienceInteractiveScreenControllerError.alreadyMounted
        }
        guard !isShuttingDown else {
            throw ExperienceInteractiveScreenControllerError.unavailable
        }
        loadViewIfNeeded()

        let initialWidth = Self.pixelDimension(screen.width)
        let initialHeight = Self.pixelDimension(screen.height)
        let preparation = try await artifact.acquired.interactivePreparation.preparation()
        let interactive = try await preparation.openScreen(
            screenID: screenId,
            products: artifact.acquired.products,
            pixelWidth: initialWidth,
            pixelHeight: initialHeight,
            videoDecoderPool: videoDecoderPool
        )
        interactiveScreen = interactive

        let includesTextInputSnapshot = artifact.renderPlan.textInputs.contains {
            $0.screenId == screenId && $0.editable
        }
        let semanticConsumer: (@MainActor @Sendable (NuxieNativeSemanticCapture) -> Void)?
        if requiresSceneSemantics {
            semanticConsumer = { [weak self] capture in self?.applySemantics(capture) }
        } else {
            semanticConsumer = nil
        }
        let textConsumer: (@MainActor @Sendable (ExperienceInteractiveTextFrame) -> Void)?
        if includesTextInputSnapshot {
            textConsumer = { [weak self] frame in
                self?.textInputOverlayBridge.update(frame: frame)
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
        let loop = ExperienceRuntimePresentationLoop(
            session: interactive.presentationSession(
                onSemantics: semanticConsumer,
                onTextFrame: textConsumer,
                onCaptions: captionConsumer
            ) { [weak self] effects in
                await self?.deliverStep(effects: effects)
            },
            surfaceView: surfaceView,
            onSessionResult: { [weak self] in
                guard let self else { return }
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
        syncFontScale(force: true)
        loop.setPresentationVisible(controllerIsVisible && !contentHidden)

        do {
            try await loop.start()
            configureTextInputCallbacks()
            bindTextInputs(to: interactive, loop: loop)
            refreshTextInputLayouts()
            syncSafeAreaInsets(force: true)
            loop.setTimelineActive(false)
            await applyLifecycleSnapshot(lifecycleState.snapshot)
            try? await loop.advanceZeroDelta()
        } catch {
            presentationLoop = nil
            interactiveScreen = nil
            await loop.shutdown()
            throw error
        }
    }

    private func didPresentDrawable(_ drawable: ExperienceRuntimePresentedDrawable) {
        guard !didReportFirstPresentation else { return }
        didReportFirstPresentation = true
        if presentationDiagnosticsEnabled {
            surfaceView.accessibilityValue = drawable.isConfirmedDisplayPresentation
                ? "first-frame-presentation:confirmed"
                : "first-frame-presentation:provisional"
        }
        delegate?.experienceScreenViewController(
            self,
            didPresentDrawable: drawable,
            frameNumber: drawable.frameNumber
        )
    }

    func shutdownInteractiveScreen() async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            self.isShuttingDown = true
            let loop = self.presentationLoop
            self.presentationLoop = nil
            self.interactiveScreen = nil
            self.finishExitWaiters()
            self.semanticContainer.clear()
            self.semanticFocusLifecycle = ExperienceSemanticFocusLifecycle()
            self.textInputOverlayBridge.clear()
            self.videoCaptionOverlay.update([])
            self.videoCaptionOverlay.isHidden = true
            await loop?.shutdown()
            self.isShuttingDown = false
        }
        shutdownTask = task
        await task.value
        shutdownTask = nil
    }

    func setContentHidden(_ hidden: Bool) {
        contentHidden = hidden
        if hidden, requiresSceneSemantics { semanticContainer.setActive(false) }
        surfaceView.isHidden = hidden
        textInputOverlayBridge.setHidden(hidden)
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
        do {
            return enqueueJourneyStateCommand(try .snapshot(snapshot))
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
        guard targetScreenId == nil || targetScreenId == screenId else { return false }
        do {
            return enqueueJourneyStateCommand(try .value(
                path: path,
                rawValue: value,
                instanceID: instanceId,
                defaultViewModelName: journeyScreen?.defaultViewModelName
            ))
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
        guard targetScreenId == nil || targetScreenId == screenId else { return false }
        do {
            return enqueueJourneyStateCommand(try .list(
                operation: operation,
                path: path,
                payload: payload,
                instanceID: instanceId,
                defaultViewModelName: journeyScreen?.defaultViewModelName
            ))
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
        guard targetScreenId == nil || targetScreenId == screenId,
              let viewModelName = path.viewModelName ?? journeyScreen?.defaultViewModelName else {
            return false
        }
        return enqueueJourneyStateCommand(.trigger(
            viewModelName: viewModelName,
            instanceID: instanceId,
            instanceName: nil,
            path: path.path
        ))
    }

    func advance(delta: Double = 0) {
        let timestamp = delta > 0 ? CACurrentMediaTime() + delta : CACurrentMediaTime()
        presentationLoop?.displayLinkDidFire(at: timestamp)
    }

    func enter(reduceMotion: Bool) async {
        presentationLoop?.setTimelineActive(true)
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
        reduceMotion: Bool
    ) async {
        if phase == .entering {
            presentationLoop?.setTimelineActive(true)
        }
        let snapshot = lifecycleState.move(
            to: phase,
            transition: transitionId,
            reduceMotion: reduceMotion
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

    func performExitHandshake(reduceMotion: Bool) async {
        let plan = ExperienceScreenExitPlan(
            declaration: screen.exit,
            reduceMotion: reduceMotion
        )
        let waiter = plan.completionEventName.map(registerCompletionWaiter(eventName:))
        let snapshot = lifecycleState.move(
            to: .exiting,
            reduceMotion: reduceMotion
        )
        await applyLifecycleSnapshot(snapshot)
        try? await presentationLoop?.advanceZeroDelta()

        guard let watchdogMilliseconds = plan.watchdogMilliseconds,
              let waiter else { return }
        await ExperienceScreenExitWatchdog.wait(
            for: waiter.stream,
            watchdogMilliseconds: watchdogMilliseconds
        )
        removeCompletionWaiter(waiter)
    }

    func markExiting(reduceMotion: Bool) async {
        let snapshot = lifecycleState.move(
            to: .exiting,
            reduceMotion: reduceMotion
        )
        await applyLifecycleSnapshot(snapshot)
        try? await presentationLoop?.advanceZeroDelta()
    }

    func syncSafeAreaInsets(force: Bool = false) {
        if force { lastPushedSafeAreaInsets = nil }
        guard isViewLoaded,
              !isShuttingDown,
              runtimeFailure == nil,
              let defaultViewModelName = journeyScreen?.defaultViewModelName else {
            return
        }
        let viewSize = view.bounds.size
        let artboardSize = CGSize(width: screen.width, height: screen.height)
        guard viewSize.width > 0,
              viewSize.height > 0,
              artboardSize.width > 0,
              artboardSize.height > 0 else { return }

        let insets = ExperienceSafeAreaInsetMapper.artboardInsets(
            deviceInsets: ExperienceSafeAreaInsets(view.safeAreaInsets),
            viewSize: viewSize,
            artboardSize: artboardSize
        )
        guard insets != lastPushedSafeAreaInsets else { return }
        let identity = journeyScreen?.defaultInstanceId
        let values: [(String, Double)] = [
            ("safeArea/top", insets.top),
            ("safeArea/bottom", insets.bottom),
            ("safeArea/left", insets.left),
            ("safeArea/right", insets.right),
        ]
        let command = ExperienceInteractiveStateCommand.snapshot(values.map {
            ExperienceInteractiveStateCommand.Value(
                viewModelName: defaultViewModelName,
                instanceID: identity,
                instanceName: nil,
                path: $0.0,
                value: .number($0.1)
            )
        })
        if enqueueStateCommand(command, logFailure: false) {
            lastPushedSafeAreaInsets = insets
        }
    }

    nonisolated static func responseSetDraft(
        for input: NativeExperienceTextInput,
        text: String,
        snapshot: ExperienceInteractiveViewModelSnapshot? = nil
    ) throws -> ScreenEmissionDraft? {
        guard let fieldKey = input.responseFieldKey, !fieldKey.isEmpty else { return nil }
        guard input.responseCapture == .binding else {
            return .responseSet(field: fieldKey, value: .string(text))
        }
        guard let snapshot else {
            throw ExperienceInteractiveScreenError.stateContract("Input '\(input.inputId)' requires an evaluated response binding")
        }
        var owner = snapshot.rootInstanceID
        let path = ["response", "values", fieldKey]
        for (index, segment) in path.enumerated() {
            let matches = snapshot.values.filter { $0.ownerInstanceID == owner && $0.name == segment }
            guard matches.count == 1 else {
                throw ExperienceInteractiveScreenError.stateContract("Input '\(input.inputId)' response binding is missing or ambiguous")
            }
            let value = matches[0].value
            if index < path.count - 1 {
                guard case .referencedInstance(let child) = value else {
                    throw ExperienceInteractiveScreenError.stateContract("Input '\(input.inputId)' response binding has invalid topology")
                }
                owner = child
                continue
            }
            let captured: ScreenEmissionValue
            switch value {
            case .number(let number) where number.isFinite: captured = .number(Double(number))
            case .bool(let boolean): captured = .bool(boolean)
            case .bytes(let bytes):
                guard let string = String(data: bytes, encoding: .utf8) else {
                    throw ExperienceInteractiveScreenError.stateContract("Input '\(input.inputId)' response binding is not UTF-8")
                }
                captured = .string(string)
            default:
                throw ExperienceInteractiveScreenError.stateContract("Input '\(input.inputId)' response binding is not a supported scalar")
            }
            return .responseSet(field: fieldKey, value: captured)
        }
        return nil
    }

    func applyVideoCommand(_ action: JourneyVideoAction) async -> Bool {
        guard !isShuttingDown, runtimeFailure == nil,
              let interactiveScreen, let presentationLoop else { return false }
        return await withCheckedContinuation { continuation in
            presentationLoop.enqueue(ExperienceRuntimePresentationQueuedWork {
                try await interactiveScreen.applyVideoCommand(action)
                return .work(requestsFrame: true)
            }, completion: { result in
                continuation.resume(returning: (try? result.get()) != nil)
            })
        }
    }

    private func enqueueStateCommand(
        _ command: ExperienceInteractiveStateCommand,
        logFailure: Bool = true,
        requestsFrame: Bool = true,
        completion: (@MainActor @Sendable (Result<Void, Error>) -> Void)? = nil
    ) -> Bool {
        guard !isShuttingDown,
              runtimeFailure == nil,
              let interactiveScreen,
              let presentationLoop else { return false }
        return presentationLoop.enqueue(
            ExperienceRuntimePresentationQueuedWork {
                let result = try await interactiveScreen.applyStateCommand(command)
                return .work(requestsFrame: requestsFrame) { [weak self] in
                    await self?.deliverStep(effects: result.effects)
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

    private func enqueueJourneyStateCommand(
        _ command: ExperienceInteractiveStateCommand
    ) -> Bool {
        guard let command = command.suppressingLifecycleReservedJourneyWrites(
            rootViewModelName: journeyScreen?.defaultViewModelName,
            rootInstanceID: journeyScreen?.defaultInstanceId
        ) else {
            return true
        }
        return enqueueStateCommand(command)
    }

    private func applySemantics(_ capture: NuxieNativeSemanticCapture) {
        guard !isShuttingDown, !contentHidden, controllerIsVisible,
              let interactiveScreen, let presentationLoop,
              let transform = ExperienceContainCenterTransform(
                artboardBounds: interactiveScreen.artboardBounds,
                viewportBounds: surfaceView.bounds) else { return }
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
                try await interactiveScreen.queueSemanticAction(captureID: captureID, nodeID: nodeID, action: action)
                return .work(requestsFrame: true)
            }, isEligible: { [weak self] in self?.semanticInputIsEligible == true })
        })
    }

    private func configureTextInputCallbacks() {
        textInputOverlayBridge.onAcceptedTextChange = { [weak self] input, text in
            guard let self,
                  let interactiveScreen = self.interactiveScreen,
                  let loop = self.presentationLoop else { return }
            let originatingRun = self.delegate?.screenEmissionRun(for: self)
            loop.enqueueInteraction(ExperienceRuntimePresentationQueuedWork {
                // Accepted text reaches the native target before this queued work.
                // Settle its reverse binding before reading the authoritative source.
                let step = input.responseCapture == .binding
                    ? try await interactiveScreen.step(elapsedSeconds: 0) : nil
                let draftResult: Result<ScreenEmissionDraft?, Error>
                do {
                    let snapshot = input.responseCapture == .binding
                        ? try await interactiveScreen.snapshot() : nil
                    draftResult = .success(try Self.responseSetDraft(for: input, text: text, snapshot: snapshot))
                } catch {
                    draftResult = .failure(error)
                }
                return .work(requestsFrame: step != nil) { [weak self] in
                    guard let self else { return }
                    if let step { await self.deliverStep(effects: step.effects) }
                    guard self.semanticInputIsEligible else { return }
                    let draft: ScreenEmissionDraft?
                    switch draftResult {
                    case .success(let value): draft = value
                    case .failure(let error): self.handleTerminalFailure(error); return
                    }
                    guard let draft else { return }
                    await self.delegate?.experienceScreenViewController(
                        self,
                        didEmitScreenEmission: .effects(
                            source: ScreenEmissionSource(
                                screenId: input.screenId,
                                actionId: "text_input:\(input.inputId)",
                                componentId: input.inputId,
                                instanceId: nil
                            ),
                            drafts: [draft]
                        ),
                        originatingRun: originatingRun
                    )
                }
            }, isEligible: { [weak self] in self?.semanticInputIsEligible == true }, completion: { [weak self] result in
                if case .failure(let error) = result {
                    if input.responseCapture == .binding, !(error is CancellationError) {
                        self?.handleTerminalFailure(error)
                    } else {
                        self?.logRejectedState(error)
                    }
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
                let result = try await interactiveScreen.commitTextInput(inputID: input.inputId, value: event.text, ownerInstanceID: event.ownerInstanceID)
                return .work(requestsFrame: result != nil) { [weak self] in
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
                            originatingRun: originatingRun
                        )
                    }
                }
            }, isEligible: { [weak self] in self?.semanticInputIsEligible == true }, completion: { [weak self] result in
                if case .failure(let error) = result { self?.logRejectedState(error) }
            })
        }
    }

    private var semanticInputIsEligible: Bool {
        !isShuttingDown && runtimeFailure == nil && !contentHidden && controllerIsVisible && lifecyclePhase == .active
            && ExperienceSemanticAccessibilityElement.allowsInteraction(in: surfaceView)
    }

    private func bindTextInputs(
        to interactiveScreen: ExperienceInteractiveScreen,
        loop: ExperienceRuntimePresentationLoop
    ) {
        let semanticWriter: ExperienceTextInputOverlayBridge.SemanticTextWriter? = requiresSceneSemantics
            ? { [weak self] captureID, target, text, completion in
                loop.enqueueInteraction(ExperienceRuntimePresentationQueuedWork {
                    do {
                        let changed = try await interactiveScreen.setSemanticText(
                            captureID: captureID, inputID: target.inputID, nodeID: target.nodeID, value: text)
                        return .work(requestsFrame: changed) { completion(.accepted) }
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
            renderPlan: artifact.renderPlan,
            surfaceView: surfaceView,
            artboardBounds: CGRect(
                x: 0,
                y: 0,
                width: screen.width,
                height: screen.height
            ),
            semanticTextWriter: semanticWriter,
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
            },
            textWriter: { inputID, text, completion in
                loop.enqueue(
                    ExperienceRuntimePresentationQueuedWork {
                        let didWrite = try await interactiveScreen.setText(
                            inputID: inputID,
                            value: text
                        )
                        return .work(requestsFrame: didWrite)
                    },
                    completion: completion
                )
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

    private func deliverStep(effects: [ExperienceInteractiveEffect]) async {
        guard !isShuttingDown, runtimeFailure == nil else { return }
        let originatingRun = delegate?.screenEmissionRun(for: self)
        var assembler = ExperienceRuntimeScreenEmissionAssembler()
        for effect in effects {
            guard !isShuttingDown, runtimeFailure == nil else { return }
            guard let projected = await route(effect) else { continue }
            switch projected {
            case .control(let screenId, let invocation):
                assembler.appendControl(screenId: screenId, invocation: invocation)
            case .draft(let draft, let draftSource):
                assembler.appendDraft(draft, source: draftSource)
            }
        }
        let emission: ExperienceRuntimeScreenEmission?
        switch assembler.assembled() {
        case .failure:
            LogWarning(
                "ExperienceScreenViewController: rejected native transaction with multiple controls"
            )
            return
        case .success(let assembled):
            emission = assembled
        }
        if let emission {
            await delegate?.experienceScreenViewController(
                self,
                didEmitScreenEmission: emission,
                originatingRun: originatingRun
            )
        }
    }

    private func route(
        _ effect: ExperienceInteractiveEffect
    ) async -> ExperienceRuntimeProjectedEmission? {
        switch effect.kind {
        case .controlAction(let actionId, let event):
            let properties = Dictionary(uniqueKeysWithValues: event.properties.map {
                ($0.key, Self.rendererValue($0.value))
            })
            let eventScreenID = Self.stringProperty(
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
            resolveExitWaiters(eventName: event.name)
            let properties = Dictionary(uniqueKeysWithValues: event.properties.map {
                ($0.key, Self.rendererValue($0.value))
            })
            let eventScreenID = Self.stringProperty(
                ["screenId", "screen_id"],
                in: properties
            ) ?? screenId
            let instanceID = Self.stringProperty(
                ["instanceId", "instance_id"],
                in: properties
            )
            if !event.url.isEmpty {
                delegate?.experienceScreenViewController(
                    self,
                    didRequestOpenLink: ExperienceRendererOpenLinkRequest(
                        urlString: event.url,
                        target: event.target.isEmpty ? nil : event.target,
                        screenId: eventScreenID,
                        instanceId: instanceID
                    )
                )
            } else if !event.name.isEmpty {
                return .draft(
                    .event(name: event.name, payload: properties.mapValues(
                        ScreenEmissionValue.init(rendererValue:)
                    )),
                    source: ScreenEmissionSource(
                        screenId: eventScreenID,
                        actionId: "runtime:\(effect.correlationID)",
                        componentId: Self.stringProperty(
                            ["componentId", "component_id", "elementId", "element_id"],
                            in: properties
                        ),
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
        case .responseSet(let field, let value):
            return .draft(
                .responseSet(
                    field: field,
                    value: ScreenEmissionValue(rendererValue: Self.rendererValue(value))
                ),
                source: runtimeEmissionSource(for: effect)
            )
        case .responseUnset(let field):
            return .draft(
                .responseUnset(field: field),
                source: runtimeEmissionSource(for: effect)
            )
        case .journeyEvent(let name, let payload),
             .hostCommand(let name, let payload):
            let properties = Self.rendererProperties(payload)
            return .draft(
                .event(
                    name: name,
                    payload: properties.mapValues(ScreenEmissionValue.init(rendererValue:))
                ),
                source: ScreenEmissionSource(
                    screenId: Self.stringProperty(
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
        if controllerIsVisible && !contentHidden { syncFontScale() }
        if requiresSceneSemantics {
            semanticContainer.setActive(semanticInputIsEligible && semanticFocusLifecycle.canExposeCurrentScene)
        }
        videoCaptionOverlay.isHidden = !controllerIsVisible || contentHidden || runtimeFailure != nil
        if videoCaptionOverlay.isHidden { videoCaptionOverlay.update([]) }
        presentationLoop?.setPresentationVisible(controllerIsVisible && !contentHidden)
    }

    private func handleTerminalFailure(_ error: Error) {
        guard !isShuttingDown, runtimeFailure == nil else { return }
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
        guard let defaultViewModelName = journeyScreen?.defaultViewModelName else {
            // Screens without a root ViewModel have no native lifecycle fields
            // to acknowledge. Their host lifecycle still owns semantic focus.
            guard interactiveScreen != nil, !isShuttingDown,
                  semanticFocusLifecycle.completeWrite(write, succeeded: true) else { return nil }
            updatePresentationVisibility()
            return write
        }
        guard !lifecycleWritesUnavailable else { return nil }
        let instanceID = journeyScreen?.defaultInstanceId
        let command = snapshot.stateCommand(
            viewModelName: defaultViewModelName,
            instanceID: instanceID
        )
        let result: Result<Void, Error> = await withCheckedContinuation { continuation in
            let accepted = enqueueStateCommand(
                command,
                logFailure: false,
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
