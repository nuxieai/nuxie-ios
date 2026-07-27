import SwiftUI
import UIKit
@testable import Nuxie

@main
struct NuxieFlowRuntimeHostApp: App {
    var body: some Scene {
        WindowGroup {
            FlowRuntimeHostView()
                .ignoresSafeArea()
        }
    }
}

private struct FlowRuntimeHostView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        FlowRuntimeHostNavigationController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

private final class FlowRuntimeHostNavigationController: UINavigationController {
    init() {
        let rootViewController: UIViewController
        do {
            let configuration = try FlowRuntimeHostConfiguration.current()
            rootViewController = FlowRuntimeFixtureListViewController(
                configuration: configuration
            )
        } catch {
            rootViewController = FlowRuntimeHostErrorViewController(error: error)
        }
        super.init(rootViewController: rootViewController)
        navigationBar.prefersLargeTitles = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private struct FlowRuntimeHostConfiguration {
    let fixtureNames: [String]
    let flowDescriptionVariant: String?
    let initialNavigationStack: [String]
    let scenarioTitle: String?
    let scenarioExpectation: String?
    let forceReduceMotion: Bool
    let manualEventName: String?
    let usesEditorNextArtifacts: Bool
    let behaviorOperationSteps: [[FlowRuntimeHostBehaviorOperation]]
    let initialScreenID: String?
    let screenPresentation: FlowRuntimeScreenPresentation?
    /// Hides the navigation bar on the fixture screen so the flow view's
    /// safe-area insets are the device's own (safe-area proofs need the raw
    /// environment, not a nav-bar-extended top inset).
    let hideNavigation: Bool

    static func current() throws -> FlowRuntimeHostConfiguration {
        let fixtureList = launchArgumentValue(named: "--nuxie-fixtures")
            .map { value in
                value
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
        let singleFixture = launchArgumentValue(named: "--nuxie-fixture") ?? "layout-paint"
        let fixtures = fixtureList?.isEmpty == false ? fixtureList! : [singleFixture]

        let initialScreenID = launchArgumentValue(
            named: "--nuxie-initial-screen"
        )
        return FlowRuntimeHostConfiguration(
            fixtureNames: fixtures,
            flowDescriptionVariant: launchArgumentValue(named: "--nuxie-flow-description-variant"),
            initialNavigationStack: launchArgumentValue(named: "--nuxie-initial-navigation-stack")
                .map(commaSeparatedValues) ?? [],
            scenarioTitle: launchArgumentValue(named: "--nuxie-scenario-title"),
            scenarioExpectation: launchArgumentValue(named: "--nuxie-scenario-expectation"),
            forceReduceMotion: ProcessInfo.processInfo.arguments.contains("--nuxie-force-reduce-motion"),
            manualEventName: launchArgumentValue(named: "--nuxie-manual-event"),
            usesEditorNextArtifacts: ProcessInfo.processInfo.arguments.contains(
                "--nuxie-editor-next-artifact"
            ),
            behaviorOperationSteps: try behaviorOperationSteps(),
            initialScreenID: initialScreenID,
            screenPresentation: try screenPresentation(
                initialScreenID: initialScreenID
            ),
            hideNavigation: ProcessInfo.processInfo.arguments.contains("--nuxie-hide-navigation")
        )
    }

    private static func behaviorOperationSteps() throws -> [
        [FlowRuntimeHostBehaviorOperation]
    ] {
        guard let encoded = launchArgumentValue(
            named: "--nuxie-behavior-operations"
        ) else {
            return []
        }
        guard let data = Data(base64Encoded: encoded) else {
            throw FlowRuntimeHostError.invalidBehaviorOperations(
                "the launch value is not base64"
            )
        }
        do {
            return try JSONDecoder().decode(
                [[FlowRuntimeHostBehaviorOperation]].self,
                from: data
            )
        } catch {
            throw FlowRuntimeHostError.invalidBehaviorOperations(
                String(reflecting: error)
            )
        }
    }

    private static func screenPresentation(
        initialScreenID: String?
    ) throws -> FlowRuntimeScreenPresentation? {
        let kind = launchArgumentValue(named: "--nuxie-player-kind")
        let name = launchArgumentValue(named: "--nuxie-player-name")
        let timestamp = launchArgumentValue(named: "--nuxie-fixed-timestamp")
        guard kind != nil || name != nil || timestamp != nil else { return nil }
        guard let initialScreenID, !initialScreenID.isEmpty else {
            throw FlowRuntimeHostError.invalidFixedPresentation(
                "fixed presentation requires --nuxie-initial-screen"
            )
        }
        guard let timestamp,
              let elapsedSeconds = TimeInterval(timestamp),
              elapsedSeconds.isFinite,
              elapsedSeconds >= 0 else {
            throw FlowRuntimeHostError.invalidFixedPresentation(
                "fixed presentation requires a finite nonnegative timestamp"
            )
        }

        let player: FlowRuntimePlayerSelector
        switch kind {
        case "default":
            guard name == nil else {
                throw FlowRuntimeHostError.invalidFixedPresentation(
                    "the default player cannot carry a name"
                )
            }
            player = .default
        case "state-machine":
            guard let name, !name.isEmpty else {
                throw FlowRuntimeHostError.invalidFixedPresentation(
                    "state-machine selection requires a nonempty name"
                )
            }
            player = .stateMachine(named: name)
        case "linear-animation":
            guard let name, !name.isEmpty else {
                throw FlowRuntimeHostError.invalidFixedPresentation(
                    "linear-animation selection requires a nonempty name"
                )
            }
            player = .linearAnimation(named: name)
        default:
            throw FlowRuntimeHostError.invalidFixedPresentation(
                "unknown or missing player kind"
            )
        }
        return FlowRuntimeScreenPresentation(
            player: player,
            timeline: .fixed(elapsedSeconds: elapsedSeconds)
        )
    }

    private static func launchArgumentValue(named name: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: name),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    private static func commaSeparatedValues(_ value: String) -> [String] {
        value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var fixtureListDetail: String? {
        var details: [String] = []
        if let scenarioTitle, !scenarioTitle.isEmpty {
            details.append(scenarioTitle)
        }
        if let flowDescriptionVariant, !flowDescriptionVariant.isEmpty {
            details.append("variant: \(flowDescriptionVariant)")
        }
        if !initialNavigationStack.isEmpty {
            details.append("initial stack: \(initialNavigationStack.joined(separator: " > "))")
        }
        if forceReduceMotion {
            details.append("reduce motion forced")
        }
        if manualEventName?.isEmpty == false {
            details.append("manual trigger")
        }
        return details.isEmpty ? nil : details.joined(separator: " | ")
    }
}

private final class FlowRuntimeFixtureListViewController: UITableViewController {
    private let configuration: FlowRuntimeHostConfiguration

    init(configuration: FlowRuntimeHostConfiguration) {
        self.configuration = configuration
        super.init(style: .insetGrouped)
        title = "Fixtures"
        navigationItem.largeTitleDisplayMode = .always
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.accessibilityIdentifier = "nuxie-fixture-list"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "FixtureCell")
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        configuration.fixtureNames.count
    }

    override func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "FixtureCell", for: indexPath)
        let fixtureName = configuration.fixtureNames[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = fixtureName
        content.secondaryText = configuration.fixtureListDetail
        content.textProperties.font = .preferredFont(forTextStyle: .body)
        content.secondaryTextProperties.font = .preferredFont(forTextStyle: .caption1)
        content.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        cell.accessibilityIdentifier = "nuxie-fixture-\(fixtureName)"
        cell.accessibilityLabel = fixtureName
        cell.accessibilityHint = configuration.scenarioExpectation
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let fixtureName = configuration.fixtureNames[indexPath.row]
        navigationController?.pushViewController(
            FlowRuntimeHostRootViewController(fixtureName: fixtureName, configuration: configuration),
            animated: true
        )
    }
}

private final class FlowRuntimeHostRootViewController: UIViewController {
    private var currentViewController: UIViewController?
    private weak var behaviorFlowViewController: ExperienceViewController?
    private let fixtureName: String
    private let configuration: FlowRuntimeHostConfiguration
    private let currentFixtureLabel = UILabel()
    private let safeAreaProbeLabel = UILabel()
    private let behaviorOperationButton = UIButton(type: .custom)
    private let behaviorOperationStatusLabel = UILabel()
    private var nextBehaviorOperationIndex = 0

    init(fixtureName: String, configuration: FlowRuntimeHostConfiguration) {
        self.fixtureName = fixtureName
        self.configuration = configuration
        super.init(nibName: nil, bundle: nil)
        title = fixtureName
        navigationItem.largeTitleDisplayMode = .never
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        configureCurrentFixtureLabel()
        configureSafeAreaProbeLabel()
        configureBehaviorOperationControls()
        loadFixture()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if configuration.hideNavigation {
            navigationController?.setNavigationBarHidden(true, animated: false)
        }
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        updateSafeAreaProbe()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateSafeAreaProbe()
    }

    private func configureCurrentFixtureLabel() {
        currentFixtureLabel.translatesAutoresizingMaskIntoConstraints = false
        currentFixtureLabel.accessibilityIdentifier = "nuxie-current-fixture"
        currentFixtureLabel.isAccessibilityElement = true
        currentFixtureLabel.textColor = .clear
        currentFixtureLabel.text = fixtureName
        currentFixtureLabel.accessibilityLabel = fixtureName

        view.addSubview(currentFixtureLabel)
        NSLayoutConstraint.activate([
            currentFixtureLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            currentFixtureLabel.topAnchor.constraint(equalTo: view.topAnchor),
            currentFixtureLabel.widthAnchor.constraint(equalToConstant: 1),
            currentFixtureLabel.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    // Exposes this view controller's own safe-area environment (insets and
    // view size in points) to UI tests through a hidden accessibility
    // element, so safe-area proofs can compute expected rendered geometry
    // from the same ground truth the SDK reads.
    private func configureSafeAreaProbeLabel() {
        safeAreaProbeLabel.translatesAutoresizingMaskIntoConstraints = false
        safeAreaProbeLabel.accessibilityIdentifier = "nuxie-safe-area-probe"
        safeAreaProbeLabel.isAccessibilityElement = true
        safeAreaProbeLabel.textColor = .clear
        safeAreaProbeLabel.font = .systemFont(ofSize: 1, weight: .regular)

        view.addSubview(safeAreaProbeLabel)
        NSLayoutConstraint.activate([
            safeAreaProbeLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            safeAreaProbeLabel.topAnchor.constraint(equalTo: view.topAnchor),
            safeAreaProbeLabel.widthAnchor.constraint(equalToConstant: 1),
            safeAreaProbeLabel.heightAnchor.constraint(equalToConstant: 1),
        ])
        updateSafeAreaProbe()
    }

    private func updateSafeAreaProbe() {
        let insets = view.safeAreaInsets
        let size = view.bounds.size
        let probe = String(
            format: "t:%.1f l:%.1f b:%.1f r:%.1f w:%.1f h:%.1f",
            insets.top,
            insets.left,
            insets.bottom,
            insets.right,
            size.width,
            size.height
        )
        safeAreaProbeLabel.text = probe
        safeAreaProbeLabel.accessibilityLabel = probe
        view.bringSubviewToFront(safeAreaProbeLabel)
    }

    private func configureBehaviorOperationControls() {
        guard !configuration.behaviorOperationSteps.isEmpty else { return }

        behaviorOperationButton.translatesAutoresizingMaskIntoConstraints = false
        behaviorOperationButton.accessibilityIdentifier =
            "nuxie-behavior-next-operation"
        behaviorOperationButton.accessibilityLabel =
            "Apply next behavior operation"
        behaviorOperationButton.backgroundColor = .clear
        behaviorOperationButton.addAction(
            UIAction { [weak self] _ in
                self?.applyNextBehaviorOperation()
            },
            for: .touchUpInside
        )

        behaviorOperationStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        behaviorOperationStatusLabel.accessibilityIdentifier =
            "nuxie-behavior-operation-status"
        behaviorOperationStatusLabel.isAccessibilityElement = true
        behaviorOperationStatusLabel.textColor = .clear
        behaviorOperationStatusLabel.font = .systemFont(
            ofSize: 1,
            weight: .regular
        )
        setBehaviorOperationStatus(
            "ready:0/\(configuration.behaviorOperationSteps.count)"
        )

        view.addSubview(behaviorOperationButton)
        view.addSubview(behaviorOperationStatusLabel)
        NSLayoutConstraint.activate([
            behaviorOperationButton.trailingAnchor.constraint(
                equalTo: view.trailingAnchor
            ),
            behaviorOperationButton.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor
            ),
            behaviorOperationButton.widthAnchor.constraint(equalToConstant: 44),
            behaviorOperationButton.heightAnchor.constraint(equalToConstant: 44),
            behaviorOperationStatusLabel.trailingAnchor.constraint(
                equalTo: view.trailingAnchor
            ),
            behaviorOperationStatusLabel.topAnchor.constraint(
                equalTo: view.topAnchor
            ),
            behaviorOperationStatusLabel.widthAnchor.constraint(equalToConstant: 1),
            behaviorOperationStatusLabel.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    private func applyNextBehaviorOperation() {
        guard let behaviorFlowViewController else {
            setBehaviorOperationStatus("error:missing-experience-controller")
            return
        }
        guard configuration.behaviorOperationSteps.indices.contains(
            nextBehaviorOperationIndex
        ) else {
            setBehaviorOperationStatus(
                "complete:\(configuration.behaviorOperationSteps.count)"
            )
            behaviorOperationButton.isEnabled = false
            return
        }

        do {
            let surfaceView = try runtimeSurfaceView()
            let operations = configuration.behaviorOperationSteps[
                nextBehaviorOperationIndex
            ]
            guard !operations.isEmpty else {
                throw FlowRuntimeHostError.invalidBehaviorOperation(
                    "operation steps must not be empty"
                )
            }
            for operation in operations {
                try operation.apply(to: behaviorFlowViewController)
            }
            guard surfaceView.accessibilityValue
                    == "fixed-frame-pending" else {
                throw FlowRuntimeHostError.invalidBehaviorOperation(
                    "the production surface did not invalidate its fixed frame"
                )
            }
            nextBehaviorOperationIndex += 1
            behaviorOperationButton.isEnabled = false
            setBehaviorOperationStatus(
                "submitted:\(nextBehaviorOperationIndex)"
                    + "/\(configuration.behaviorOperationSteps.count)"
            )
            publishBehaviorOperationCompletion(
                index: nextBehaviorOperationIndex,
                surfaceView: surfaceView
            )
        } catch {
            setBehaviorOperationStatus(
                "error:\(nextBehaviorOperationIndex):"
                    + String(reflecting: error)
            )
        }
    }

    private func runtimeSurfaceView() throws -> FlowRuntimeSurfaceView {
        guard let behaviorFlowViewController,
              let surfaceView = Self.runtimeSurfaceView(
                in: behaviorFlowViewController.view
              ) else {
            throw FlowRuntimeHostError.invalidBehaviorOperation(
                "the production FlowRuntimeSurfaceView is unavailable"
            )
        }
        return surfaceView
    }

    private static func runtimeSurfaceView(
        in view: UIView
    ) -> FlowRuntimeSurfaceView? {
        if let surfaceView = view as? FlowRuntimeSurfaceView {
            return surfaceView
        }
        for subview in view.subviews {
            if let surfaceView = runtimeSurfaceView(in: subview) {
                return surfaceView
            }
        }
        return nil
    }

    private func publishBehaviorOperationCompletion(
        index: Int,
        surfaceView: FlowRuntimeSurfaceView
    ) {
        Task { @MainActor [weak self, weak surfaceView] in
            var consecutiveReadyPolls = 0
            for _ in 0..<500 {
                guard let self, let surfaceView else { return }
                if surfaceView.accessibilityValue == "fixed-frame-ready" {
                    consecutiveReadyPolls += 1
                } else {
                    consecutiveReadyPolls = 0
                }
                if consecutiveReadyPolls >= 50 {
                    self.setBehaviorOperationStatus(
                        "applied:\(index)"
                            + "/\(self.configuration.behaviorOperationSteps.count)"
                    )
                    let isComplete = index
                        == self.configuration.behaviorOperationSteps.count
                    self.behaviorOperationButton.isEnabled = !isComplete
                    if isComplete {
                        self.behaviorOperationButton.accessibilityLabel =
                            "All behavior operations applied"
                    }
                    return
                }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            self?.setBehaviorOperationStatus(
                "error:\(index - 1):fixed-frame-timeout"
            )
        }
    }

    private func setBehaviorOperationStatus(_ status: String) {
        behaviorOperationStatusLabel.text = status
        behaviorOperationStatusLabel.accessibilityLabel = status
    }

    private func loadFixture() {
        do {
            let viewController = try makeFlowViewController(fixtureName: fixtureName)
            if !configuration.behaviorOperationSteps.isEmpty {
                viewController.loadViewIfNeeded()
                guard let behaviorFlowViewController =
                    Self.experienceViewController(in: viewController) else {
                    throw FlowRuntimeHostError.missingBehaviorController
                }
                self.behaviorFlowViewController = behaviorFlowViewController
            }
            replaceCurrentViewController(with: viewController)
            currentFixtureLabel.text = fixtureName
            currentFixtureLabel.accessibilityLabel = fixtureName
        } catch {
            replaceCurrentViewController(with: FlowRuntimeHostErrorViewController(error: error))
            currentFixtureLabel.text = "error:\(fixtureName)"
            currentFixtureLabel.accessibilityLabel = "error:\(fixtureName)"
        }
    }

    private static func experienceViewController(
        in viewController: UIViewController
    ) -> ExperienceViewController? {
        if let experienceViewController =
            viewController as? ExperienceViewController {
            return experienceViewController
        }
        for child in viewController.children {
            if let experienceViewController = experienceViewController(
                in: child
            ) {
                return experienceViewController
            }
        }
        return nil
    }

    private func replaceCurrentViewController(with nextViewController: UIViewController) {
        if let currentViewController {
            currentViewController.willMove(toParent: nil)
            currentViewController.view.removeFromSuperview()
            currentViewController.removeFromParent()
        }

        addChild(nextViewController)
        nextViewController.view.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(nextViewController.view, at: 0)
        NSLayoutConstraint.activate([
            nextViewController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            nextViewController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            nextViewController.view.topAnchor.constraint(equalTo: view.topAnchor),
            nextViewController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        nextViewController.didMove(toParent: self)
        currentViewController = nextViewController
        view.bringSubviewToFront(currentFixtureLabel)
        if !configuration.behaviorOperationSteps.isEmpty {
            view.bringSubviewToFront(behaviorOperationButton)
            view.bringSubviewToFront(behaviorOperationStatusLabel)
        }
    }

    private func makeFlowViewController(fixtureName: String) throws -> UIViewController {
        guard let resourceURL = Bundle.main.resourceURL else {
            throw FlowRuntimeHostError.missingResourceRoot
        }

        let fixtureRootName = configuration.usesEditorNextArtifacts
            ? "GeneratedEditorNextFixtures"
            : "Fixtures"
        var fixtureBaseURL = resourceURL
            .appendingPathComponent(fixtureRootName, isDirectory: true)
            .appendingPathComponent(fixtureName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: fixtureBaseURL.path) else {
            throw FlowRuntimeHostError.missingFixture(fixtureName)
        }

        if let flowDescriptionVariant = configuration.flowDescriptionVariant {
            fixtureBaseURL = try Self.fixtureURL(
                fixtureBaseURL,
                replacingFlowDescriptionWithVariant: flowDescriptionVariant,
                fixtureName: fixtureName
            )
        }

        let cacheRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nuxie-flow-runtime-host", isDirectory: true)
            .appendingPathComponent(fixtureName, isDirectory: true)
            .appendingPathComponent(configuration.flowDescriptionVariant ?? "default", isDirectory: true)
        let scriptTrustRoots = try editorNextScriptTrustRoots(
            resourceURL: resourceURL,
            fixtureName: fixtureName
        )
        let screenPresentationsByScreenID: [
            String: FlowRuntimeScreenPresentation
        ]
        if let presentation = configuration.screenPresentation,
           let screenID = configuration.initialScreenID {
            screenPresentationsByScreenID = [screenID: presentation]
        } else {
            screenPresentationsByScreenID = [:]
        }

        return try FlowRuntimeFixtureHost.makeViewController(
            fixtureBaseURL: fixtureBaseURL,
            cacheRootURL: cacheRootURL,
            initialScreenID: configuration.initialScreenID,
            initialNavigationStack: configuration.initialNavigationStack,
            manualEventName: configuration.manualEventName,
            scriptTrustPublicKeysBase64ByKeyId: scriptTrustRoots,
            screenPresentationsByScreenID: screenPresentationsByScreenID
        )
    }

    private func editorNextScriptTrustRoots(
        resourceURL: URL,
        fixtureName: String
    ) throws -> [String: String] {
        guard configuration.usesEditorNextArtifacts,
              fixtureName == "gpu-canvas" else {
            return [:]
        }
        let proofURL = resourceURL
            .appendingPathComponent(
                "GeneratedEditorNextFixtures",
                isDirectory: true
            )
            .appendingPathComponent("native-gpu-canvas-proof.json")
        let proof = try JSONDecoder().decode(
            EditorNextGPUCanvasProof.self,
            from: Data(contentsOf: proofURL)
        )
        guard proof.schemaVersion
                == "nuxie-editor-next-native-gpu-canvas-proof.v1",
              !proof.signing.keyId.isEmpty,
              let publicKey = Data(
                base64Encoded: proof.signing.publicKeyBase64
              ),
              publicKey.count == 32 else {
            throw FlowRuntimeHostError.invalidEditorNextGPUProof
        }
        return [proof.signing.keyId: proof.signing.publicKeyBase64]
    }

    private static func fixtureURL(
        _ fixtureBaseURL: URL,
        replacingFlowDescriptionWithVariant variant: String,
        fixtureName: String
    ) throws -> URL {
        let variantFileName = "flow-description.\(variant).json"
        let variantURL = fixtureBaseURL.appendingPathComponent(variantFileName)
        guard FileManager.default.fileExists(atPath: variantURL.path) else {
            throw FlowRuntimeHostError.missingFixtureVariant(fixtureName, variant)
        }

        let preparedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nuxie-flow-runtime-host-variants", isDirectory: true)
            .appendingPathComponent(fixtureName, isDirectory: true)
            .appendingPathComponent(variant, isDirectory: true)

        if FileManager.default.fileExists(atPath: preparedURL.path) {
            try FileManager.default.removeItem(at: preparedURL)
        }
        try FileManager.default.createDirectory(
            at: preparedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: fixtureBaseURL, to: preparedURL)

        let activeDescriptionURL = preparedURL.appendingPathComponent("flow-description.json")
        if FileManager.default.fileExists(atPath: activeDescriptionURL.path) {
            try FileManager.default.removeItem(at: activeDescriptionURL)
        }
        try FileManager.default.copyItem(
            at: preparedURL.appendingPathComponent(variantFileName),
            to: activeDescriptionURL
        )
        return preparedURL
    }
}

private enum FlowRuntimeHostError: LocalizedError {
    case missingResourceRoot
    case missingFixture(String)
    case missingFixtureVariant(String, String)
    case invalidEditorNextGPUProof
    case invalidFixedPresentation(String)
    case invalidBehaviorOperations(String)
    case missingBehaviorController
    case invalidBehaviorOperation(String)

    var errorDescription: String? {
        switch self {
        case .missingResourceRoot:
            return "Experience runtime host could not resolve Bundle.main.resourceURL"
        case .missingFixture(let fixture):
            return "Experience runtime fixture is missing: \(fixture)"
        case .missingFixtureVariant(let fixture, let variant):
            return "Experience runtime fixture \(fixture) is missing flow description variant \(variant)"
        case .invalidEditorNextGPUProof:
            return "Editor Next GPU canvas proof is invalid"
        case .invalidFixedPresentation(let message):
            return "Editor Next fixed presentation is invalid: \(message)"
        case .invalidBehaviorOperations(let message):
            return "Behavior operation sequence is invalid: \(message)"
        case .missingBehaviorController:
            return "Behavior operation sequence requires an ExperienceViewController"
        case .invalidBehaviorOperation(let message):
            return "Behavior operation is invalid: \(message)"
        }
    }
}

private struct FlowRuntimeHostBehaviorOperation: Decodable {
    enum Kind: String, Decodable {
        case setValue = "set-value"
        case listOperation = "list-operation"
    }

    let kind: Kind
    let viewModelName: String
    let path: String
    let value: FlowRuntimeHostJSONValue?
    let operation: String?
    let payload: [String: FlowRuntimeHostJSONValue]?
    let screenId: String?
    let instanceId: String?

    @MainActor
    func apply(to controller: ExperienceViewController) throws {
        guard !viewModelName.isEmpty, !path.isEmpty else {
            throw FlowRuntimeHostError.invalidBehaviorOperation(
                "viewModelName and path must be nonempty"
            )
        }
        let path = VmPathRef(
            viewModelName: viewModelName,
            path: path
        )
        switch kind {
        case .setValue:
            guard let value else {
                throw FlowRuntimeHostError.invalidBehaviorOperation(
                    "set-value requires value"
                )
            }
            controller.applyViewModelValue(
                path: path,
                value: value.foundationValue,
                screenId: screenId,
                instanceId: instanceId
            )
        case .listOperation:
            guard let operation,
                  let operation = FlowViewModelListOperation(
                    rawValue: operation
                  ),
                  let payload else {
                throw FlowRuntimeHostError.invalidBehaviorOperation(
                    "list-operation requires a known operation and payload"
                )
            }
            controller.applyViewModelListOperation(
                operation,
                path: path,
                payload: payload.mapValues(\.foundationValue),
                screenId: screenId,
                instanceId: instanceId
            )
        }
    }
}

private enum FlowRuntimeHostJSONValue: Decodable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([FlowRuntimeHostJSONValue])
    case object([String: FlowRuntimeHostJSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(
            [FlowRuntimeHostJSONValue].self
        ) {
            self = .array(value)
        } else if let value = try? container.decode(
            [String: FlowRuntimeHostJSONValue].self
        ) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected a JSON behavior value"
            )
        }
    }

    var foundationValue: Any {
        switch self {
        case .null:
            NSNull()
        case .bool(let value):
            value
        case .number(let value):
            value
        case .string(let value):
            value
        case .array(let values):
            values.map(\.foundationValue)
        case .object(let object):
            object.mapValues(\.foundationValue)
        }
    }
}

private struct EditorNextGPUCanvasProof: Decodable {
    struct Signing: Decodable {
        let keyId: String
        let publicKeyBase64: String
    }

    let schemaVersion: String
    let signing: Signing
}

private final class FlowRuntimeHostErrorViewController: UIViewController {
    private let error: Error

    init(error: Error) {
        self.error = error
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.accessibilityIdentifier = "nuxie-flow-host-error"

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .label
        label.text = error.localizedDescription
        label.accessibilityIdentifier = "nuxie-flow-host-error-label"

        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }
}
