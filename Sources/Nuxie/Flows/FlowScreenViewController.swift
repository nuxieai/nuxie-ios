#if canImport(RiveRuntime) && canImport(UIKit)
import Foundation
import RiveRuntime
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

@MainActor
final class FlowScreenViewController: UIViewController {
    private let flow: Flow
    private let artifact: LoadedFlowArtifact
    private var screen: FlowArtifactScreen

    private var model: RiveModel!
    private var riveViewModel: RiveViewModel!
    private var riveView: RiveView!
    private var viewModelBridge: FlowViewModelBridge!
    private var textInputOverlayBridge: FlowTextInputOverlayBridge!
    private var nuxieScriptBridge: NuxieRiveScriptBridge!
    private var pendingScreenBindingId: String?
    private var contentHidden = false

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
        super.init(nibName: nil, bundle: nil)
        try loadRiveSession(for: screen)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.clipsToBounds = true
        view.accessibilityIdentifier = "nuxie-screen-controller-\(screenId)"

        riveView.translatesAutoresizingMaskIntoConstraints = false
        riveView.accessibilityIdentifier = "nuxie-flow-surface"
        riveView.accessibilityLabel = screenId
        riveView.isAccessibilityElement = true
        riveView.isHidden = contentHidden

        view.addSubview(riveView)
        NSLayoutConstraint.activate([
            riveView.topAnchor.constraint(equalTo: view.topAnchor),
            riveView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            riveView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            riveView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        installFixtureScreenBadgeIfNeeded()
        bindTextInputs()
        riveView.advance(delta: 0)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        textInputOverlayBridge?.layout()
    }

    func setContentHidden(_ hidden: Bool) {
        contentHidden = hidden
        riveView?.isHidden = hidden
        textInputOverlayBridge?.setHidden(hidden)
    }

    func layoutTextInputs() {
        textInputOverlayBridge?.layout()
    }

    @discardableResult
    func applySnapshot(_ snapshot: FlowViewModelSnapshot, screenId targetScreenId: String?) -> Bool {
        let didApply = viewModelBridge?.applySnapshot(snapshot, screenId: targetScreenId) == true
        let shouldBindCurrentScreen = targetScreenId == nil || targetScreenId == screenId || pendingScreenBindingId == screenId
        if shouldBindCurrentScreen,
           viewModelBridge?.bindDefaultInstance(forScreenId: screenId) == true {
            pendingScreenBindingId = nil
            advanceRiveView(delta: 0)
        }
        bindPendingScreenIfNeeded()
        return didApply
    }

    @discardableResult
    func applyValue(
        path: VmPathRef,
        value: Any,
        screenId targetScreenId: String?,
        instanceId: String?
    ) -> Bool {
        viewModelBridge?.applyValue(
            path: path,
            value: value,
            screenId: targetScreenId,
            instanceId: instanceId
        ) == true
    }

    @discardableResult
    func applyListOperation(
        _ operation: FlowViewModelListOperation,
        path: VmPathRef,
        payload: [String: Any],
        screenId targetScreenId: String?,
        instanceId: String?
    ) -> Bool {
        viewModelBridge?.applyListOperation(
            operation,
            path: path,
            payload: payload,
            screenId: targetScreenId,
            instanceId: instanceId
        ) == true
    }

    @discardableResult
    func fireTrigger(path: VmPathRef, screenId targetScreenId: String?, instanceId: String?) -> Bool {
        viewModelBridge?.fireTrigger(
            path: path,
            screenId: targetScreenId,
            instanceId: instanceId
        ) == true
    }

    func advance(delta: Double = 0) {
        advanceRiveView(delta: delta)
    }

    private func loadRiveSession(for screen: FlowArtifactScreen) throws {
        let nuxieScriptBridge = NuxieRiveScriptBridge()
        // Device script gate: embedded scripts register only for flow
        // artifacts whose Nuxie manifest signature verified. This is the
        // ONLY RiveFile entry point that ever enables unverified scripts.
        nuxieScriptBridge.scriptRuntime.allowsUnverifiedScripts =
            artifact.scriptsEnabled
        let riveFile = try Self.makeRiveFile(
            artifact: artifact,
            scriptRuntime: nuxieScriptBridge.scriptRuntime
        )
        let model = RiveModel(riveFile: riveFile)
        let riveViewModel = RiveViewModel(
            model,
            animationName: nil,
            fit: .contain,
            alignment: .center,
            autoPlay: true,
            artboardName: screen.artboardName
        )
        let viewModelBridge = FlowViewModelBridge(
            model: model,
            remoteFlow: flow.remoteFlow,
            imageResolver: { [artifact] imageKey in
                Self.resolveRiveImage(imageKey, artifact: artifact)
            },
            onValueChange: { [weak self] path, value, source in
                guard let self else { return }
                self.delegate?.flowScreenViewController(
                    self,
                    didEmitViewModelChange: FlowRendererViewModelChange(
                        path: path,
                        value: value,
                        source: source,
                        screenId: self.screenId,
                        instanceId: nil,
                        isTrigger: self.viewModelBridge?.isTriggerPath(
                            path: path,
                            screenId: self.screenId,
                            instanceId: nil
                        ) == true
                    )
                )
            }
        )

        if try viewModelBridge.bindDefaultInstanceForActiveArtboard() {
            LogDebug("Bound native flow ViewModel \(viewModelBridge.boundViewModelName ?? "<unknown>")")
        } else {
            LogDebug("Mounted native flow screen \(screen.screenId) without a default ViewModel")
        }

        let riveView = riveViewModel.createRiveView()
        riveView.playerDelegate = self
        riveView.stateMachineDelegate = self

        self.model = model
        self.riveViewModel = riveViewModel
        self.riveView = riveView
        self.viewModelBridge = viewModelBridge
        self.textInputOverlayBridge = FlowTextInputOverlayBridge()
        self.nuxieScriptBridge = nuxieScriptBridge

        do {
            _ = try bindViewModelForCurrentScreen()
        } catch {
            LogWarning("FlowScreenViewController: failed to bind ViewModel for screen \(screen.screenId): \(error)")
        }
    }

    @discardableResult
    private func bindViewModelForCurrentScreen() throws -> Bool {
        if viewModelBridge.bindDefaultInstance(forScreenId: screenId) {
            pendingScreenBindingId = nil
            return true
        }

        if try viewModelBridge.bindDefaultInstanceForActiveArtboard() {
            pendingScreenBindingId = shouldKeepPendingScreenBinding(for: screenId) ? screenId : nil
            return true
        }

        pendingScreenBindingId = screenId
        return false
    }

    private func bindPendingScreenIfNeeded() {
        guard pendingScreenBindingId == screenId else {
            return
        }
        do {
            guard try bindViewModelForCurrentScreen() else {
                return
            }
            advanceRiveView(delta: 0)
        } catch {
            LogWarning("FlowScreenViewController: failed to bind native ViewModel for screen \(screenId): \(error)")
        }
    }

    private func shouldKeepPendingScreenBinding(for screenId: String) -> Bool {
        guard let screen = flow.remoteFlow.screens.first(where: { $0.id == screenId }) else {
            return false
        }
        return screen.defaultViewModelName != nil || screen.defaultInstanceId != nil
    }

    private func installFixtureScreenBadgeIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("--nuxie-show-screen-debug-badges") else {
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
            badge.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 44),
            badge.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -44),
            badge.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -104),
            badge.heightAnchor.constraint(equalToConstant: 52),
        ])
    }

    private func bindTextInputs() {
        // Committed typed values ride the same $response_set path as
        // script-driven Nuxie.response.set — the journey runner resolves the
        // flow's response schema and records the draft field.
        textInputOverlayBridge.onCommitText = { [weak self] input, text in
            guard let self,
                  let event = Self.responseSetEvent(for: input, text: text) else {
                return
            }
            self.delegate?.flowScreenViewController(self, didEmitEvent: event)
        }
        textInputOverlayBridge.bind(
            screenId: screenId,
            artifact: artifact,
            riveView: riveView,
            riveViewModel: riveViewModel,
            viewModelBridge: viewModelBridge
        )
        textInputOverlayBridge.setHidden(contentHidden)
    }

    /// Maps a committed text-input value to a `$response_set` renderer event
    /// via the input's publish-resolved response field. Inputs without a
    /// response binding stay display-only and emit nothing.
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

    private func advanceRiveView(delta: Double) {
        riveView?.advance(delta: delta)
        drainNuxieScriptEvents()
    }

    private func drainNuxieScriptEvents() {
        let events = nuxieScriptBridge?.drainEvents(currentScreenId: screenId) ?? []
        guard !events.isEmpty else {
            return
        }

        for event in events {
            delegate?.flowScreenViewController(
                self,
                didEmitEvent: event
            )
        }
    }

    private static func makeRiveFile(
        artifact: LoadedFlowArtifact,
        scriptRuntime: RiveScriptRuntime
    ) throws -> RiveFile {
        let data = try Data(contentsOf: artifact.rivURL)
        return try RiveFile(
            data: data,
            loadCdn: false,
            customAssetLoader: { asset, embeddedData, factory in
                Self.loadRiveAsset(
                    asset,
                    embeddedData: embeddedData,
                    factory: factory,
                    artifact: artifact
                )
            },
            scriptRuntime: scriptRuntime
        )
    }

    private static func loadRiveAsset(
        _ asset: RiveFileAsset,
        embeddedData: Data,
        factory: RiveFactory,
        artifact: LoadedFlowArtifact
    ) -> Bool {
        let assetName = asset.uniqueName()
        guard let assetURL = artifact.localAssetURL(forRiveUniqueName: assetName) else {
            LogError("Missing prepared runtime asset for Rive asset \(assetName)")
            return false
        }

        let data: Data
        do {
            data = try Data(contentsOf: assetURL)
        } catch {
            LogError("Failed to read prepared runtime asset \(assetName) at \(assetURL.path): \(error)")
            return false
        }

        if let imageAsset = asset as? RiveImageAsset {
            imageAsset.renderImage(factory.decodeImage(data))
            LogDebug("Loaded Rive image asset \(assetName) from \(assetURL.path)")
            return true
        }

        if let fontAsset = asset as? RiveFontAsset {
            _ = FlowRuntimeFontRegistry.registerFont(riveUniqueName: assetName, data: data)
            fontAsset.font(factory.decodeFont(data))
            LogDebug("Loaded Rive font asset \(assetName) from \(assetURL.path)")
            return true
        }

        LogDebug("Unsupported Rive asset type for prepared asset \(assetName)")
        return false
    }

    private static func resolveRiveImage(_ imageKey: String, artifact: LoadedFlowArtifact) -> RiveRenderImage? {
        guard let asset = artifact.manifest.assets.images.first(where: {
            $0.sourceAssetKey == imageKey || $0.riveUniqueName == imageKey || $0.path == imageKey
        }) else {
            return nil
        }
        guard let assetURL = try? artifact.localImageURL(for: asset),
              let data = try? Data(contentsOf: assetURL) else {
            return nil
        }
        return RiveRenderImage(data: data)
    }
}

extension FlowScreenViewController: @preconcurrency RivePlayerDelegate {
    public func player(playedWithModel riveModel: RiveModel?) {}

    public func player(pausedWithModel riveModel: RiveModel?) {}

    public func player(loopedWithModel riveModel: RiveModel?, type: Int) {}

    public func player(stoppedWithModel riveModel: RiveModel?) {}

    public func player(didAdvanceby seconds: Double, riveModel: RiveModel?) {
        viewModelBridge?.updateBoundListeners()
        textInputOverlayBridge?.layout()
        drainNuxieScriptEvents()
        delegate?.flowScreenViewControllerDidAdvance(self)
    }
}

extension FlowScreenViewController: @preconcurrency RiveStateMachineDelegate {
    public func onRiveEventReceived(onRiveEvent riveEvent: RiveEvent) {
        let properties = rendererEventProperties(from: riveEvent)
        let eventScreenId = rendererStringProperty(
            ["screenId", "screen_id"],
            from: properties
        ) ?? screenId
        let componentId = rendererStringProperty(
            ["componentId", "component_id", "elementId", "element_id"],
            from: properties
        )
        let instanceId = rendererStringProperty(
            ["instanceId", "instance_id"],
            from: properties
        )

        if let openUrlEvent = riveEvent as? RiveOpenUrlEvent {
            delegate?.flowScreenViewController(
                self,
                didRequestOpenLink: FlowRendererOpenLinkRequest(
                    urlString: openUrlEvent.url(),
                    target: openUrlEvent.target(),
                    screenId: eventScreenId,
                    instanceId: instanceId
                )
            )
            return
        }

        delegate?.flowScreenViewController(
            self,
            didEmitEvent: FlowRendererEvent(
                name: riveEvent.name(),
                properties: properties,
                screenId: eventScreenId,
                componentId: componentId,
                instanceId: instanceId
            )
        )
    }

    private func rendererEventProperties(from event: RiveEvent) -> [String: Any] {
        guard let rawProperties = event.properties() as? [String: Any] else {
            return [:]
        }
        return rawProperties
    }

    private func rendererStringProperty(
        _ keys: [String],
        from properties: [String: Any]
    ) -> String? {
        for key in keys {
            if let value = properties[key] as? String,
               !value.isEmpty {
                return value
            }
        }
        return nil
    }
}
#endif
