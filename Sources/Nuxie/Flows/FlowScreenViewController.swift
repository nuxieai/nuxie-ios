#if canImport(UIKit) && canImport(QuartzCore)
import Foundation
import QuartzCore
import UIKit

@MainActor
protocol FlowScreenViewControllerDelegate: AnyObject {
    func flowScreenViewControllerDidAdvance(_ controller: FlowScreenViewController)

    func flowScreenViewController(
        _ controller: FlowScreenViewController,
        didEmitEvent event: FlowRendererEvent
    )

    func flowScreenViewController(
        _ controller: FlowScreenViewController,
        didEmitViewModelChange change: FlowRendererViewModelChange
    )

    func flowScreenViewController(
        _ controller: FlowScreenViewController,
        didRequestOpenLink request: FlowRendererOpenLinkRequest
    )
}

private enum FlowScreenRuntimeError: LocalizedError {
    case differentSessionAlreadyMounted
    case stateResultWithoutRequest
    case stateResultMissingOriginal
    case stateQueueLostHead
    case runtimeSessionUnavailable

    var errorDescription: String? {
        switch self {
        case .differentSessionAlreadyMounted:
            "This flow screen already owns a different runtime session"
        case .stateResultWithoutRequest:
            "The runtime returned state work without an active canonical request"
        case .stateResultMissingOriginal:
            "The runtime state completion had no matching original output batch"
        case .stateQueueLostHead:
            "The canonical state queue changed while its head was in flight"
        case .runtimeSessionUnavailable:
            "The flow screen has no mounted runtime session"
        }
    }
}

/// UIKit owner for one independently mutable runtime screen session.
///
/// Context import deliberately lives above this controller. A presentation
/// creates one shared `FlowRuntimeContext`, creates an independent session for
/// each screen from it, then injects that already-created session through
/// `mountRuntimeSession(_:)`.
@MainActor
final class FlowScreenViewController: UIViewController {
    private struct PendingCanonicalInput {
        let id: UUID
        let input: FlowRuntimeCanonicalStateInput
    }

    private let flow: Flow
    private let artifact: LoadedFlowArtifact
    private let screen: FlowArtifactScreen
    private let surfaceView = FlowRuntimeSurfaceView(frame: .zero)
    private let textInputOverlayBridge = FlowTextInputOverlayBridge()
    private let stateCoordinator: FlowViewModelStateCoordinator

    private var runtimeSession: FlowRenderSession?
    private var displayHost: FlowRuntimeDisplayHost?
    private var stateBridge: FlowRuntimeStateBridge?
    private var hostCommandRouter = FlowRuntimeHostCommandRouter()
    private var pendingCanonicalInputs: [PendingCanonicalInput] = []
    private var activeCanonicalInputID: UUID?
    private var activeCanonicalInputWasPrepared = false
    private var activeStateOriginalResult: FlowRuntimeOperationResult?
    private var runtimeFailure: Error?
    private var isShuttingDownRuntime = false
    private var shutdownTask: Task<Void, Never>?
    private var terminalShutdownTask: Task<Void, Never>?
    private var contentHidden = false
    private var controllerIsVisible = false
    private var lastPushedSafeAreaInsets: FlowSafeAreaInsets?
    private var hasLoggedSafeAreaUnsupported = false

    /// Called for terminal failures that happen after an initially successful
    /// asynchronous mount. Mount-time failures are also thrown to the caller.
    var onRuntimeFailure: ((Error) -> Void)?

    weak var delegate: FlowScreenViewControllerDelegate?

    var screenId: String {
        screen.screenId
    }

    init(
        flow: Flow,
        artifact: LoadedFlowArtifact,
        screen: FlowArtifactScreen,
        delegate: FlowScreenViewControllerDelegate?
    ) throws {
        self.flow = flow
        self.artifact = artifact
        self.screen = screen
        self.delegate = delegate
        self.stateCoordinator = FlowViewModelStateCoordinator(
            remoteFlow: flow.remoteFlow
        )
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
        surfaceView.accessibilityIdentifier = "nuxie-flow-surface"
        surfaceView.accessibilityLabel = screenId
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

    /// Mounts one session created from the presentation's shared runtime
    /// context. The controller never imports an artifact or creates a context.
    func mountRuntimeSession(_ session: FlowRenderSession) async throws {
        guard !isShuttingDownRuntime else {
            throw FlowScreenRuntimeError.runtimeSessionUnavailable
        }
        if let runtimeFailure {
            throw runtimeFailure
        }
        if let runtimeSession {
            guard runtimeSession === session else {
                throw FlowScreenRuntimeError.differentSessionAlreadyMounted
            }
            return
        }

        runtimeSession = session
        loadViewIfNeeded()

        do {
            let imageIdentityResolver = try FlowRuntimeImageIdentityResolver(
                images: artifact.manifest.assets.images
            )
            let stateBridge = try FlowRuntimeStateBridge(
                remoteFlow: flow.remoteFlow,
                screenID: screenId,
                bootstrap: session.bootstrap,
                coordinator: stateCoordinator,
                imageIdentityResolver: imageIdentityResolver
            )
            self.stateBridge = stateBridge

            configureTextInputCallbacks()
            let host = FlowRuntimeDisplayHost(
                session: session,
                surfaceView: surfaceView,
                resultProjector: { [weak self] result in
                    self?.textInputOverlayBridge.consume(result) ?? result
                },
                onResult: { [weak self] original, projected, source in
                    self?.consumeRuntimeResult(
                        original: original,
                        projected: projected,
                        source: source
                    )
                },
                onError: { [weak self] error in
                    self?.handleTerminalRuntimeFailure(error)
                }
            )
            displayHost = host
            host.setPresentationVisible(controllerIsVisible && !contentHidden)

            textInputOverlayBridge.bind(
                screenId: screenId,
                artifact: artifact,
                surfaceView: surfaceView,
                bootstrap: session.bootstrap,
                textWriter: { [weak host] text, runName, completion in
                    guard let host else {
                        completion(.failure(
                            FlowScreenRuntimeError.runtimeSessionUnavailable
                        ))
                        return
                    }
                    host.setText(
                        text,
                        forRunNamed: runName,
                        completion: completion
                    )
                }
            )
            textInputOverlayBridge.setHidden(contentHidden)

            // Creation outputs precede every queued screen operation. Project
            // reserved overlay state before the canonical bridge sees them,
            // while routing events and host commands from the untouched batch.
            let projectedCreation = textInputOverlayBridge.consume(
                session.creationResult
            )
            try routeRuntimeResult(
                original: session.creationResult,
                projected: projectedCreation,
                source: nil
            )

            try await host.start()
            syncSafeAreaInsets(force: true)
            drainCanonicalStateQueue()
        } catch {
            handleTerminalRuntimeFailure(error)
            throw error
        }
    }

    /// Detaches the Apple surface before disposing the screen-owned session.
    /// The retained parent context remains alive for sibling sessions.
    func shutdownRuntimeSession() async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.performRuntimeSessionShutdown()
        }
        shutdownTask = task
        await task.value
        shutdownTask = nil
    }

    private func performRuntimeSessionShutdown() async {
        isShuttingDownRuntime = true
        let host = displayHost
        let session = runtimeSession
        let terminalShutdownTask = terminalShutdownTask
        displayHost = nil
        runtimeSession = nil
        stateBridge = nil
        self.terminalShutdownTask = nil
        textInputOverlayBridge.clear()
        await terminalShutdownTask?.value
        await host?.shutdown()
        session?.dispose()
        activeCanonicalInputID = nil
        activeCanonicalInputWasPrepared = false
        activeStateOriginalResult = nil
        pendingCanonicalInputs.removeAll()
        isShuttingDownRuntime = false
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

    /// Pushes safe-area values through the same serialized canonical state
    /// lane as server state. Values are expressed in authored artboard units.
    func syncSafeAreaInsets(force: Bool = false) {
        if force {
            lastPushedSafeAreaInsets = nil
        }
        guard isViewLoaded,
              !isShuttingDownRuntime,
              runtimeFailure == nil,
              let session = runtimeSession else {
            return
        }

        let viewSize = view.bounds.size
        let bounds = session.bootstrap.player.bounds
        let artboardSize = CGSize(
            width: CGFloat(bounds.width),
            height: CGFloat(bounds.height)
        )
        guard viewSize.width > 0,
              viewSize.height > 0,
              artboardSize.width > 0,
              artboardSize.height > 0 else {
            return
        }

        let artboardInsets = FlowSafeAreaInsetMapper.artboardInsets(
            deviceInsets: FlowSafeAreaInsets(view.safeAreaInsets),
            viewSize: viewSize,
            artboardSize: artboardSize
        )
        guard artboardInsets != lastPushedSafeAreaInsets else { return }

        guard let rootSchema = safeAreaRootSchema(in: session.bootstrap) else {
            lastPushedSafeAreaInsets = artboardInsets
            if !hasLoggedSafeAreaUnsupported {
                hasLoggedSafeAreaUnsupported = true
                LogDebug(
                    "FlowScreenViewController: screen \(screenId) has no safeArea ViewModel; skipping safe-area inset sync"
                )
            }
            return
        }

        let instanceID = flow.remoteFlow.screens.first(where: {
            $0.id == screenId
        })?.defaultInstanceId
        let values: [(String, Double)] = [
            ("safeArea/top", artboardInsets.top),
            ("safeArea/bottom", artboardInsets.bottom),
            ("safeArea/left", artboardInsets.left),
            ("safeArea/right", artboardInsets.right),
        ]
        let inputs = values.map { path, value in
            FlowRuntimeCanonicalStateInput.value(
                path: VmPathRef(viewModelName: rootSchema.name, path: path),
                value: value,
                instanceID: instanceID
            )
        }
        guard enqueueCanonicalInputs(inputs) else { return }
        lastPushedSafeAreaInsets = artboardInsets
    }

    @discardableResult
    func applySnapshot(
        _ snapshot: FlowViewModelSnapshot,
        screenId targetScreenId: String?
    ) -> Bool {
        // A snapshot is canonical presentation state. Every independent screen
        // replica receives it even when one screen triggered the refresh.
        enqueueCanonicalInputs([.snapshot(snapshot)])
    }

    @discardableResult
    func applyValue(
        path: VmPathRef,
        value: Any,
        screenId targetScreenId: String?,
        instanceId: String?
    ) -> Bool {
        guard targetScreenId == nil || targetScreenId == screenId else {
            return false
        }
        return enqueueCanonicalInputs([
            .value(path: path, value: value, instanceID: instanceId),
        ])
    }

    @discardableResult
    func applyListOperation(
        _ operation: FlowViewModelListOperation,
        path: VmPathRef,
        payload: [String: Any],
        screenId targetScreenId: String?,
        instanceId: String?
    ) -> Bool {
        guard targetScreenId == nil || targetScreenId == screenId else {
            return false
        }
        return enqueueCanonicalInputs([
            .list(
                operation: operation,
                path: path,
                payload: payload,
                instanceID: instanceId
            ),
        ])
    }

    @discardableResult
    func fireTrigger(
        path: VmPathRef,
        screenId targetScreenId: String?,
        instanceId: String?
    ) -> Bool {
        guard targetScreenId == nil || targetScreenId == screenId else {
            return false
        }
        return enqueueCanonicalInputs([
            .trigger(path: path, instanceID: instanceId),
        ])
    }

    func advance(delta: Double = 0) {
        // The display host owns frame coalescing and computes the actual delta
        // from the app clock. This method remains the coordinator's zero-frame
        // nudge when layout or navigation changes.
        _ = delta
        displayHost?.requestAdvance()
    }

    /// Maps a committed text-input value to a `$response_set` renderer event
    /// through the publish-resolved response field.
    static func responseSetEvent(
        for input: FlowArtifactTextInput,
        text: String
    ) -> FlowRendererEvent? {
        guard let fieldKey = input.responseFieldKey,
              !fieldKey.isEmpty else {
            return nil
        }
        return FlowRendererEvent(
            name: SystemEventNames.responseSet,
            properties: ["field": fieldKey, "value": text],
            screenId: input.screenId,
            componentId: input.inputId,
            instanceId: nil
        )
    }

    private func configureTextInputCallbacks() {
        textInputOverlayBridge.onCommitText = { [weak self] input, text in
            guard let self,
                  let event = Self.responseSetEvent(for: input, text: text) else {
                return
            }
            delegate?.flowScreenViewController(self, didEmitEvent: event)
        }
        textInputOverlayBridge.onDiagnostic = { diagnostic in
            diagnostic.log()
        }
    }

    private func updatePresentationVisibility() {
        displayHost?.setPresentationVisible(controllerIsVisible && !contentHidden)
    }

    private func enqueueCanonicalInputs(
        _ inputs: [FlowRuntimeCanonicalStateInput]
    ) -> Bool {
        guard !isShuttingDownRuntime, runtimeFailure == nil else { return false }
        guard !inputs.isEmpty else { return true }
        let available = FlowRuntimeSessionLimits.batchItems
            - pendingCanonicalInputs.count
        guard inputs.count <= available else {
            LogWarning(
                "FlowScreenViewController: canonical state queue for \(screenId) exceeded its fixed \(FlowRuntimeSessionLimits.batchItems)-item budget"
            )
            return false
        }
        pendingCanonicalInputs.append(contentsOf: inputs.map {
            PendingCanonicalInput(id: UUID(), input: $0)
        })
        drainCanonicalStateQueue()
        return true
    }

    private func drainCanonicalStateQueue() {
        guard runtimeFailure == nil,
              activeCanonicalInputID == nil,
              let entry = pendingCanonicalInputs.first,
              let displayHost,
              let stateBridge else {
            return
        }

        activeCanonicalInputID = entry.id
        activeCanonicalInputWasPrepared = false
        activeStateOriginalResult = nil
        displayHost.performStateBatch(
            prepare: { [weak self, weak stateBridge] in
                guard let self,
                      let stateBridge,
                      self.pendingCanonicalInputs.first?.id == entry.id else {
                    throw FlowScreenRuntimeError.stateQueueLostHead
                }
                let batch = try stateBridge.prepare(entry.input)
                self.activeCanonicalInputWasPrepared = true
                return batch
            },
            completion: { [weak self] result in
                self?.completeCanonicalStateRequest(entry.id, with: result)
            }
        )
    }

    private func completeCanonicalStateRequest(
        _ id: UUID,
        with result: Result<FlowRuntimeOperationResult, Error>
    ) {
        if isShuttingDownRuntime {
            if activeCanonicalInputWasPrepared {
                stateBridge?.abandonPendingBatch()
            }
            return
        }
        guard activeCanonicalInputID == id,
              pendingCanonicalInputs.first?.id == id else {
            handleTerminalRuntimeFailure(
                FlowScreenRuntimeError.stateQueueLostHead
            )
            return
        }

        switch result {
        case .success(let projected):
            guard let original = activeStateOriginalResult else {
                handleTerminalRuntimeFailure(
                    FlowScreenRuntimeError.stateResultMissingOriginal
                )
                return
            }
            do {
                try routeRuntimeResult(
                    original: original,
                    projected: projected,
                    source: .stateBatch
                )
            } catch {
                handleTerminalRuntimeFailure(error)
                return
            }
        case .failure(let error):
            if activeCanonicalInputWasPrepared {
                stateBridge?.abandonPendingBatch()
            }
            if flowRuntimeOperationFailureInvalidatesSession(error) {
                // DisplayHost reports this through onError immediately after
                // completing the requesting operation, including failures that
                // happen before state preparation begins.
                return
            }
            LogWarning(
                "FlowScreenViewController: rejected canonical state for \(screenId): \(error)"
            )
        }

        pendingCanonicalInputs.removeFirst()
        activeCanonicalInputID = nil
        activeCanonicalInputWasPrepared = false
        activeStateOriginalResult = nil
        drainCanonicalStateQueue()
    }

    private func consumeRuntimeResult(
        original: FlowRuntimeOperationResult,
        projected: FlowRuntimeOperationResult,
        source: FlowRuntimeDisplayResultSource
    ) {
        guard !isShuttingDownRuntime else { return }
        if source == .stateBatch {
            guard activeCanonicalInputID != nil else {
                handleTerminalRuntimeFailure(
                    FlowScreenRuntimeError.stateResultWithoutRequest
                )
                return
            }
            activeStateOriginalResult = original
            return
        }

        do {
            try routeRuntimeResult(
                original: original,
                projected: projected,
                source: source
            )
        } catch {
            handleTerminalRuntimeFailure(error)
        }
    }

    /// Preserves the runtime's phase-family contract: reported platform events,
    /// projected canonical changes, native-control layout, then Luau host work.
    private func routeRuntimeResult(
        original: FlowRuntimeOperationResult,
        projected: FlowRuntimeOperationResult,
        source: FlowRuntimeDisplayResultSource?
    ) throws {
        routeReportedEvents(original.orderedOutputs)

        guard let stateBridge else {
            throw FlowScreenRuntimeError.runtimeSessionUnavailable
        }
        for change in try stateBridge.reconcile(projected) {
            delegate?.flowScreenViewController(
                self,
                didEmitViewModelChange: change
            )
        }

        // Geometry outputs share the ViewModel phase. Apply their UIKit
        // projection after canonical reconciliation and before authored Luau
        // host work can re-enter the application.
        textInputOverlayBridge.layout()

        try hostCommandRouter.enqueue(original)
        for event in hostCommandRouter.drain(currentScreenID: screenId) {
            delegate?.flowScreenViewController(
                self,
                didEmitEvent: FlowRendererEvent(
                    name: event.name,
                    properties: Self.rendererObject(event.properties),
                    screenId: event.screenID,
                    componentId: event.componentID,
                    instanceId: event.instanceID
                )
            )
        }

        original.diagnostics.forEach { $0.log() }
        if source == .frame || source == .textRender {
            delegate?.flowScreenViewControllerDidAdvance(self)
        }
    }

    private func routeReportedEvents(_ outputs: [FlowRuntimeOutput]) {
        for output in outputs {
            guard case let .reportedEvent(
                name,
                _,
                _,
                eventProperties,
                openURL
            ) = output.payload else {
                continue
            }
            var properties: [String: Any] = [:]
            for property in eventProperties {
                guard let name = property.name, !name.isEmpty else { continue }
                properties[name] = Self.rendererScalar(property.value)
            }
            let eventScreenID = Self.stringProperty(
                ["screenId", "screen_id"],
                in: properties
            ) ?? screenId
            let componentID = Self.stringProperty(
                ["componentId", "component_id", "elementId", "element_id"],
                in: properties
            )
            let instanceID = Self.stringProperty(
                ["instanceId", "instance_id"],
                in: properties
            )

            if let openURL {
                delegate?.flowScreenViewController(
                    self,
                    didRequestOpenLink: FlowRendererOpenLinkRequest(
                        urlString: openURL.url,
                        target: openURL.target.isEmpty ? nil : openURL.target,
                        screenId: eventScreenID,
                        instanceId: instanceID
                    )
                )
                continue
            }
            guard let name, !name.isEmpty else { continue }
            delegate?.flowScreenViewController(
                self,
                didEmitEvent: FlowRendererEvent(
                    name: name,
                    properties: properties,
                    screenId: eventScreenID,
                    componentId: componentID,
                    instanceId: instanceID
                )
            )
        }
    }

    private func safeAreaRootSchema(
        in bootstrap: FlowRuntimeBootstrap
    ) -> FlowRuntimeSchema? {
        guard let root = bootstrap.catalog.rootInstance else { return nil }
        let matches = bootstrap.catalog.schemas.filter { $0.id == root.schemaID }
        guard matches.count == 1,
              matches[0].properties.contains(where: {
                  $0.name == "safeArea"
                      && ($0.kind == .object || $0.kind == .viewModel)
              }) else {
            return nil
        }
        return matches[0]
    }

    private func handleTerminalRuntimeFailure(_ error: Error) {
        guard !isShuttingDownRuntime, runtimeFailure == nil else { return }
        runtimeFailure = error
        LogError(
            "FlowScreenViewController: runtime session for \(screenId) failed: \(error)"
        )
        surfaceView.isHidden = true
        textInputOverlayBridge.setHidden(true)
        pendingCanonicalInputs.removeAll()
        activeCanonicalInputID = nil
        activeCanonicalInputWasPrepared = false
        activeStateOriginalResult = nil
        onRuntimeFailure?(error)

        let host = displayHost
        let session = runtimeSession
        displayHost = nil
        runtimeSession = nil
        stateBridge = nil
        terminalShutdownTask = Task { @MainActor in
            await host?.shutdown()
            session?.dispose()
        }
    }

    private func installFixtureScreenBadgeIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains(
            "--nuxie-show-screen-debug-badges"
        ) else {
            return
        }

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

    private static func rendererScalar(_ value: FlowRuntimeScalarValue) -> Any {
        switch value {
        case .null: NSNull()
        case .string(let value): value
        case .number(let value): value
        case .bool(let value): value
        case .enumeration(let value),
             .listIndex(let value),
             .image(let value),
             .trigger(let value): value
        case .color(let value): value
        }
    }

    private static func rendererValue(_ value: FlowRuntimeHostValue) -> Any {
        switch value {
        case .bool(let value): value
        case .number(let value): value
        case .string(let value): value
        case .array(let values): values.map(rendererValue)
        case .object(let object): rendererObject(object)
        }
    }

    private static func rendererObject(
        _ object: FlowRuntimeHostObject
    ) -> [String: Any] {
        object.fields.reduce(into: [:]) { result, field in
            result[field.name] = rendererValue(field.value)
        }
    }

    private static func stringProperty(
        _ names: [String],
        in properties: [String: Any]
    ) -> String? {
        for name in names {
            if let value = properties[name] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    deinit {
        let host = displayHost
        let session = runtimeSession
        Task { @MainActor in
            await host?.shutdown()
            session?.dispose()
        }
    }
}
#endif
