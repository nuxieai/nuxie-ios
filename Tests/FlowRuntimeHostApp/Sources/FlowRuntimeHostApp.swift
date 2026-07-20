import SwiftUI
import UIKit
import Nuxie

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
        let configuration = FlowRuntimeHostConfiguration.current()
        super.init(rootViewController: FlowRuntimeFixtureListViewController(configuration: configuration))
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
    /// Hides the navigation bar on the fixture screen so the flow view's
    /// safe-area insets are the device's own (safe-area proofs need the raw
    /// environment, not a nav-bar-extended top inset).
    let hideNavigation: Bool

    static func current() -> FlowRuntimeHostConfiguration {
        let fixtureList = launchArgumentValue(named: "--nuxie-fixtures")
            .map { value in
                value
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
        let singleFixture = launchArgumentValue(named: "--nuxie-fixture") ?? "layout-paint"
        let fixtures = fixtureList?.isEmpty == false ? fixtureList! : [singleFixture]

        return FlowRuntimeHostConfiguration(
            fixtureNames: fixtures,
            flowDescriptionVariant: launchArgumentValue(named: "--nuxie-flow-description-variant"),
            initialNavigationStack: launchArgumentValue(named: "--nuxie-initial-navigation-stack")
                .map(commaSeparatedValues) ?? [],
            scenarioTitle: launchArgumentValue(named: "--nuxie-scenario-title"),
            scenarioExpectation: launchArgumentValue(named: "--nuxie-scenario-expectation"),
            forceReduceMotion: ProcessInfo.processInfo.arguments.contains("--nuxie-force-reduce-motion"),
            manualEventName: launchArgumentValue(named: "--nuxie-manual-event"),
            hideNavigation: ProcessInfo.processInfo.arguments.contains("--nuxie-hide-navigation")
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
    private let fixtureName: String
    private let configuration: FlowRuntimeHostConfiguration
    private let currentFixtureLabel = UILabel()
    private let safeAreaProbeLabel = UILabel()

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

    private func loadFixture() {
        do {
            let viewController = try makeFlowViewController(fixtureName: fixtureName)
            replaceCurrentViewController(with: viewController)
            currentFixtureLabel.text = fixtureName
            currentFixtureLabel.accessibilityLabel = fixtureName
        } catch {
            replaceCurrentViewController(with: FlowRuntimeHostErrorViewController(error: error))
            currentFixtureLabel.text = "error:\(fixtureName)"
            currentFixtureLabel.accessibilityLabel = "error:\(fixtureName)"
        }
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
    }

    private func makeFlowViewController(fixtureName: String) throws -> UIViewController {
        guard let resourceURL = Bundle.main.resourceURL else {
            throw FlowRuntimeHostError.missingResourceRoot
        }

        var fixtureBaseURL = resourceURL
            .appendingPathComponent("Fixtures", isDirectory: true)
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

        return try FlowRuntimeFixtureHost.makeViewController(
            fixtureBaseURL: fixtureBaseURL,
            cacheRootURL: cacheRootURL,
            initialNavigationStack: configuration.initialNavigationStack,
            manualEventName: configuration.manualEventName
        )
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

    var errorDescription: String? {
        switch self {
        case .missingResourceRoot:
            return "Flow runtime host could not resolve Bundle.main.resourceURL"
        case .missingFixture(let fixture):
            return "Flow runtime fixture is missing: \(fixture)"
        case .missingFixtureVariant(let fixture, let variant):
            return "Flow runtime fixture \(fixture) is missing flow description variant \(variant)"
        }
    }
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
