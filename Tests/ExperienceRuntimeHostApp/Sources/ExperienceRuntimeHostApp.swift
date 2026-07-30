import Nuxie
import SwiftUI
import UIKit

@main
struct NuxieExperienceRuntimeHostApp: App {
    var body: some Scene {
        WindowGroup {
            ExperienceRuntimeHostView()
                .ignoresSafeArea()
        }
    }
}

private struct ExperienceRuntimeHostView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        let configuration = ExperienceRuntimeHostConfiguration.current()
        let list = ExperienceRuntimeFixtureListViewController(configuration: configuration)
        let navigation = UINavigationController(rootViewController: list)
        navigation.navigationBar.prefersLargeTitles = true
        return navigation
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

private struct ExperienceRuntimeHostConfiguration {
    let fixtureNames: [String]
    let initialScreenID: String?
    let initialNavigationStack: [String]
    let hideNavigation: Bool

    static func current() -> Self {
        let availableFixtureNames = loadFixtureIndex().fixtures.map(\.id)
        let listed = argument(named: "--nuxie-fixtures").map {
            $0.split(separator: ",").map(String.init).filter { !$0.isEmpty }
        }
        let selected = argument(named: "--nuxie-fixture")
        let requestedFixtureNames: [String]
        if let listed, !listed.isEmpty {
            requestedFixtureNames = listed
        } else if let selected {
            requestedFixtureNames = [selected]
        } else {
            requestedFixtureNames = availableFixtureNames
        }
        precondition(
            requestedFixtureNames.allSatisfy(availableFixtureNames.contains),
            "Requested fixture is absent from fixture-index.json"
        )
        return Self(
            fixtureNames: requestedFixtureNames,
            initialScreenID: argument(named: "--nuxie-initial-screen"),
            initialNavigationStack: argument(named: "--nuxie-initial-navigation-stack")
                .map { $0.split(separator: ",").map(String.init) } ?? [],
            hideNavigation: ProcessInfo.processInfo.arguments.contains("--nuxie-hide-navigation")
        )
    }

    private static func loadFixtureIndex() -> ExperienceRuntimeFixtureIndex {
        let candidates = [
            Bundle.main.url(
                forResource: "fixture-index",
                withExtension: "json",
                subdirectory: "Fixtures"
            ),
            Bundle.main.resourceURL?
                .appendingPathComponent("Fixtures", isDirectory: true)
                .appendingPathComponent("fixture-index.json"),
        ].compactMap { $0 }
        guard let url = candidates.first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) else {
            preconditionFailure("fixture-index.json is missing from the host bundle")
        }
        do {
            let index = try JSONDecoder().decode(
                ExperienceRuntimeFixtureIndex.self,
                from: Data(contentsOf: url)
            )
            precondition(
                index.schemaVersion == "nuxie-sdk-fixtures.v1",
                "Unsupported SDK fixture index"
            )
            return index
        } catch {
            preconditionFailure("Invalid fixture-index.json: \(error)")
        }
    }

    private static func argument(named name: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: name),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}

private struct ExperienceRuntimeFixtureIndex: Decodable {
    struct Fixture: Decodable {
        let id: String
    }

    let schemaVersion: String
    let fixtures: [Fixture]
}

private final class ExperienceRuntimeFixtureListViewController: UITableViewController {
    private let configuration: ExperienceRuntimeHostConfiguration

    init(configuration: ExperienceRuntimeHostConfiguration) {
        self.configuration = configuration
        super.init(style: .insetGrouped)
        title = "SDK .nux fixtures"
        navigationItem.largeTitleDisplayMode = .always
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.accessibilityIdentifier = "nuxie-fixture-list"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "fixture")
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        configuration.fixtureNames.count
    }

    override func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "fixture", for: indexPath)
        let name = configuration.fixtureNames[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = name
        content.secondaryText = "signed experience.nux"
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        cell.accessibilityIdentifier = "nuxie-fixture-\(name)"
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        navigationController?.pushViewController(
            ExperienceRuntimeHostRootViewController(
                fixtureName: configuration.fixtureNames[indexPath.row],
                configuration: configuration
            ),
            animated: true
        )
    }
}

private final class ExperienceRuntimeHostRootViewController: UIViewController {
    private let fixtureName: String
    private let configuration: ExperienceRuntimeHostConfiguration
    private let fixtureLabel = UILabel()
    private let statusLabel = UILabel()
    private let safeAreaProbe = UILabel()

    init(fixtureName: String, configuration: ExperienceRuntimeHostConfiguration) {
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
        installProbe(fixtureLabel, identifier: "nuxie-current-fixture", value: fixtureName)
        installProbe(statusLabel, identifier: "nuxie-runtime-status", value: "loading:\(fixtureName)")
        installProbe(safeAreaProbe, identifier: "nuxie-safe-area-probe", value: "")
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

    private func loadFixture() {
        do {
            guard let resourceURL = Bundle.main.resourceURL else {
                throw ExperienceRuntimeHostError.missingResourceRoot
            }
            let fixtureURL = resourceURL
                .appendingPathComponent("Fixtures", isDirectory: true)
                .appendingPathComponent(fixtureName, isDirectory: true)
            guard FileManager.default.fileExists(
                atPath: fixtureURL.appendingPathComponent("experience.nux").path
            ) else {
                throw ExperienceRuntimeHostError.missingFixture(fixtureName)
            }
            let cacheRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("nuxie-experience-runtime-host", isDirectory: true)
                .appendingPathComponent(fixtureName, isDirectory: true)
            let child = try ExperienceRuntimeFixtureHost.makeViewController(
                fixtureBaseURL: fixtureURL,
                cacheRootURL: cacheRoot,
                initialScreenID: configuration.initialScreenID,
                initialNavigationStack: configuration.initialNavigationStack,
                statusObserver: { [weak self] status in
                    self?.setProbe(self?.statusLabel, value: "\(status):\(self?.fixtureName ?? "")")
                }
            )
            addChild(child)
            child.view.translatesAutoresizingMaskIntoConstraints = false
            view.insertSubview(child.view, at: 0)
            NSLayoutConstraint.activate([
                child.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                child.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                child.view.topAnchor.constraint(equalTo: view.topAnchor),
                child.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])
            child.didMove(toParent: self)
        } catch {
            view.accessibilityIdentifier = "nuxie-experience-host-error"
            setProbe(fixtureLabel, value: "error:\(fixtureName)")
            setProbe(statusLabel, value: "error:\(error.localizedDescription)")
        }
    }

    private func installProbe(_ label: UILabel, identifier: String, value: String) {
        label.accessibilityIdentifier = identifier
        label.isAccessibilityElement = true
        label.textColor = .clear
        label.font = .systemFont(ofSize: 1)
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            label.topAnchor.constraint(equalTo: view.topAnchor),
            label.widthAnchor.constraint(equalToConstant: 1),
            label.heightAnchor.constraint(equalToConstant: 1)
        ])
        setProbe(label, value: value)
    }

    private func setProbe(_ label: UILabel?, value: String) {
        label?.text = value
        label?.accessibilityLabel = value
    }

    private func updateSafeAreaProbe() {
        let insets = view.safeAreaInsets
        let size = view.bounds.size
        setProbe(
            safeAreaProbe,
            value: String(
                format: "t:%.1f l:%.1f b:%.1f r:%.1f w:%.1f h:%.1f",
                insets.top, insets.left, insets.bottom, insets.right,
                size.width, size.height
            )
        )
    }
}

private enum ExperienceRuntimeHostError: LocalizedError {
    case missingResourceRoot
    case missingFixture(String)

    var errorDescription: String? {
        switch self {
        case .missingResourceRoot:
            "Experience runtime host could not resolve Bundle.main.resourceURL"
        case .missingFixture(let fixture):
            "Signed experience package fixture is missing: \(fixture)"
        }
    }
}
