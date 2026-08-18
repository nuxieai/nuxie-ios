#if canImport(UIKit) && canImport(QuartzCore)
import Foundation
import QuartzCore
import UIKit

enum ExperienceInteractiveStepDeliveryItem: Equatable, Sendable {
    case effect(ExperienceInteractiveEffect)
    case textInputLayout
}

enum ExperienceInteractiveStepDeliveryPlanner {
    static func items(
        effects: [ExperienceInteractiveEffect],
        includesTextInputLayout: Bool
    ) -> [ExperienceInteractiveStepDeliveryItem] {
        var result: [ExperienceInteractiveStepDeliveryItem] = []
        result.reserveCapacity(effects.count + (includesTextInputLayout ? 1 : 0))
        var insertedLayout = false
        for effect in effects {
            if includesTextInputLayout,
               !insertedLayout,
               isHostPhase(effect.kind) {
                result.append(.textInputLayout)
                insertedLayout = true
            }
            result.append(.effect(effect))
        }
        if includesTextInputLayout, !insertedLayout {
            result.append(.textInputLayout)
        }
        return result
    }

    private static func isHostPhase(_ effect: ExperienceInteractiveEffectKind) -> Bool {
        switch effect {
        case .reportedEvent, .stateChange, .viewModelChange:
            false
        case .responseSet, .responseUnset, .journeyEvent, .navigate, .hostCommand,
             .rejectedHostCommand:
            true
        }
    }
}

@MainActor
protocol ExperienceScreenViewControllerDelegate: AnyObject {
    func experienceScreenViewControllerDidAdvance(_ controller: ExperienceScreenViewController)

    func experienceScreenViewController(
        _ controller: ExperienceScreenViewController,
        didEmitEvent event: ExperienceRendererEvent
    )

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
        didRequestNavigationTo screenID: String,
        transition: Any?
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

    private var interactiveScreen: ExperienceInteractiveScreen?
    private var presentationLoop: ExperienceRuntimePresentationLoop?
    private var runtimeFailure: Error?
    private var isShuttingDown = false
    private var shutdownTask: Task<Void, Never>?
    private var contentHidden = false
    private var controllerIsVisible = false
    private var lastPushedSafeAreaInsets: ExperienceSafeAreaInsets?
    private var lifecycleState: ExperienceScreenLifecycleState
    private var lifecycleWritesUnavailable = false
    private var didLogUnavailableLifecycleWrite = false
    private var exitWaiters: [UUID: (
        eventName: String,
        continuation: AsyncStream<Void>.Continuation
    )] = [:]
    private var didReportFirstPresentation = false
    private let presentationDiagnosticsEnabled = ProcessInfo.processInfo.arguments.contains(
        "--nuxie-presentation-diagnostics"
    )

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
        delegate: ExperienceScreenViewControllerDelegate?
    ) {
        self.experience = experience
        self.artifact = artifact
        self.screen = screen
        lifecycleState = ExperienceScreenLifecycleState(reduceMotion: reduceMotion)
        self.delegate = delegate
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.clipsToBounds = true
        view.accessibilityIdentifier = "nuxie-screen-controller-\(screenId)"

        surfaceView.translatesAutoresizingMaskIntoConstraints = false
        surfaceView.accessibilityIdentifier = "nuxie-experience-surface"
        surfaceView.accessibilityLabel = screenId
        if presentationDiagnosticsEnabled {
            surfaceView.accessibilityValue = "first-frame-presentation:pending"
        }
        surfaceView.isAccessibilityElement = true
        surfaceView.isHidden = contentHidden
        view.addSubview(surfaceView)
        NSLayoutConstraint.activate([
            surfaceView.topAnchor.constraint(equalTo: view.topAnchor),
            surfaceView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            surfaceView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            surfaceView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        installFixtureScreenBadgeIfNeeded()
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
            pixelHeight: initialHeight
        )
        interactiveScreen = interactive

        let includesTextInputSnapshot = artifact.renderPlan.textInputs.contains {
            $0.screenId == screenId && $0.editable
        }
        let loop = ExperienceRuntimePresentationLoop(
            session: interactive.presentationSession(
                includesSnapshotAfterStep: includesTextInputSnapshot
            ) { [weak self] effects, snapshot in
                await self?.deliverStep(effects: effects, snapshot: snapshot)
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
            self.textInputOverlayBridge.clear()
            await loop?.shutdown()
            self.isShuttingDown = false
        }
        shutdownTask = task
        await task.value
        shutdownTask = nil
    }

    func setContentHidden(_ hidden: Bool) {
        contentHidden = hidden
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
        await applyLifecycleSnapshot(snapshot)
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

    static func responseSetEvent(
        for input: NativeExperienceTextInput,
        text: String
    ) -> ExperienceRendererEvent? {
        guard let fieldKey = input.responseFieldKey, !fieldKey.isEmpty else { return nil }
        return ExperienceRendererEvent(
            name: SystemEventNames.responseSet,
            properties: ["field": fieldKey, "value": text],
            screenId: input.screenId,
            componentId: input.inputId,
            instanceId: nil
        )
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
        let includesTextInputSnapshot = artifact.renderPlan.textInputs.contains {
            $0.screenId == screenId && $0.editable
        }
        presentationLoop.enqueue(
            ExperienceRuntimePresentationQueuedWork {
                let result = try await interactiveScreen.applyStateCommand(command)
                let snapshot: ExperienceInteractiveViewModelSnapshot?
                if includesTextInputSnapshot {
                    snapshot = try? await interactiveScreen.snapshot()
                } else {
                    snapshot = nil
                }
                return .work(requestsFrame: requestsFrame) { [weak self] in
                    await self?.deliverStep(effects: result.effects, snapshot: snapshot)
                }
            },
            completion: { [weak self] result in
                if logFailure, case .failure(let error) = result {
                    self?.logRejectedState(error)
                }
                completion?(result)
            }
        )
        return true
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

    private func configureTextInputCallbacks() {
        textInputOverlayBridge.onCommitText = { [weak self] input, text in
            guard let self,
                  let event = Self.responseSetEvent(for: input, text: text) else { return }
            self.delegate?.experienceScreenViewController(self, didEmitEvent: event)
        }
    }

    private func bindTextInputs(
        to interactiveScreen: ExperienceInteractiveScreen,
        loop: ExperienceRuntimePresentationLoop
    ) {
        textInputOverlayBridge.bind(
            screenID: screenId,
            artifact: artifact,
            surfaceView: surfaceView,
            artboardBounds: CGRect(
                x: 0,
                y: 0,
                width: screen.width,
                height: screen.height
            ),
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
        }),
        let interactiveScreen,
        let presentationLoop else { return }
        presentationLoop.enqueue(
            ExperienceRuntimePresentationQueuedWork {
                let snapshot = try await interactiveScreen.snapshot()
                return .work(requestsFrame: false) { [weak self] in
                    self?.textInputOverlayBridge.update(snapshot: snapshot)
                }
            },
            completion: { error in
                if case .failure(let error) = error {
                    LogWarning(
                        "ExperienceScreenViewController: failed to refresh text layout for \(self.screenId): \(error)"
                    )
                }
            }
        )
    }

    private func deliverStep(
        effects: [ExperienceInteractiveEffect],
        snapshot: ExperienceInteractiveViewModelSnapshot?
    ) async {
        guard !isShuttingDown, runtimeFailure == nil else { return }
        let items = ExperienceInteractiveStepDeliveryPlanner.items(
            effects: effects,
            includesTextInputLayout: snapshot != nil
        )
        for item in items {
            guard !isShuttingDown, runtimeFailure == nil else { return }
            switch item {
            case .effect(let effect):
                await route(effect)
            case .textInputLayout:
                if let snapshot {
                    textInputOverlayBridge.update(snapshot: snapshot)
                }
            }
        }
    }

    private func route(_ effect: ExperienceInteractiveEffect) async {
        switch effect.kind {
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
                emitEvent(
                    name: event.name,
                    properties: properties,
                    screenID: eventScreenID,
                    componentID: Self.stringProperty(
                        ["componentId", "component_id", "elementId", "element_id"],
                        in: properties
                    ),
                    instanceID: instanceID
                )
            }
        case .stateChange:
            break
        case .viewModelChange(let change):
            guard change.origin == .runtime, let interactiveScreen else { return }
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
        case .responseSet(let field, let value):
            emitEvent(
                name: SystemEventNames.responseSet,
                properties: ["field": field, "value": Self.rendererValue(value)]
            )
        case .responseUnset(let field):
            emitEvent(
                name: "$response_unset",
                properties: ["field": field]
            )
        case .journeyEvent(let name, let payload),
             .hostCommand(let name, let payload):
            let properties = Self.rendererProperties(payload)
            emitEvent(
                name: name,
                properties: properties,
                screenID: Self.stringProperty(["screenId", "screen_id"], in: properties),
                componentID: Self.stringProperty(
                    ["componentId", "component_id", "elementId", "element_id"],
                    in: properties
                ),
                instanceID: Self.stringProperty(["instanceId", "instance_id"], in: properties)
            )
        case .navigate(let screenID, let transition):
            delegate?.experienceScreenViewController(
                self,
                didRequestNavigationTo: screenID,
                transition: transition.map(Self.rendererValue)
            )
        case .rejectedHostCommand(let name, let reason):
            LogWarning(
                "ExperienceScreenViewController: rejected host command '\(name)' on \(screenId): \(reason)"
            )
        }
    }

    private func emitEvent(
        name: String,
        properties: [String: Any],
        screenID: String? = nil,
        componentID: String? = nil,
        instanceID: String? = nil
    ) {
        guard !name.isEmpty else { return }
        delegate?.experienceScreenViewController(
            self,
            didEmitEvent: ExperienceRendererEvent(
                name: name,
                properties: properties,
                screenId: screenID ?? screenId,
                componentId: componentID,
                instanceId: instanceID
            )
        )
    }

    private func updatePresentationVisibility() {
        presentationLoop?.setPresentationVisible(controllerIsVisible && !contentHidden)
    }

    private func handleTerminalFailure(_ error: Error) {
        guard !isShuttingDown, runtimeFailure == nil else { return }
        runtimeFailure = error
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

    private func applyLifecycleSnapshot(_ snapshot: ExperienceScreenLifecycleSnapshot) async {
        guard !lifecycleWritesUnavailable else { return }
        guard let defaultViewModelName = journeyScreen?.defaultViewModelName else {
            markLifecycleWritesUnavailable("screen has no default root ViewModel")
            return
        }
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
            markLifecycleWritesUnavailable(error.localizedDescription)
        }
    }

    private func markLifecycleWritesUnavailable(_ reason: String) {
        lifecycleWritesUnavailable = true
        guard !didLogUnavailableLifecycleWrite else { return }
        didLogUnavailableLifecycleWrite = true
        LogWarning(
            "ExperienceScreenViewController: lifecycle state is unavailable "
                + "for \(screenId); skipping host writes: \(reason)"
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

    private func installFixtureScreenBadgeIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains(
            "--nuxie-show-screen-debug-badges"
        ) else { return }

        let badge = UILabel()
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.accessibilityIdentifier = "nuxie-screen-debug-badge-\(screenId)"
        badge.text = "LIVE SCREEN: \(screenId)"
        badge.textAlignment = .center
        badge.textColor = .white
        badge.font = .systemFont(ofSize: 18, weight: .bold)
        badge.backgroundColor = screenId == "screen_1" ? .systemIndigo : .systemGreen
        badge.layer.cornerRadius = 14
        badge.layer.masksToBounds = true
        badge.isAccessibilityElement = true
        badge.accessibilityLabel = "Live screen \(screenId)"
        view.addSubview(badge)
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.leadingAnchor,
                constant: 44
            ),
            badge.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor,
                constant: -44
            ),
            badge.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                constant: -104
            ),
            badge.heightAnchor.constraint(equalToConstant: 52),
        ])
    }

    deinit {
        let loop = presentationLoop
        Task { @MainActor in
            await loop?.shutdown()
        }
    }
}
#endif
