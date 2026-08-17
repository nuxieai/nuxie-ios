@_spi(Testing) import Nuxie
import UIKit

/// On-device browser for the SDK's presentation states.
///
/// Every row presents a signed presentation-state fixture through the real
/// shell path under one acquisition condition, so the loading treatment,
/// recovery affordances, floating controls, and each presentation mode can be
/// reviewed as a user would see them.
final class PresentationStatesBrowserViewController: UITableViewController {
    private struct Scenario {
        let id: String
        let title: String
        let summary: String
        let style: String
    }

    private struct Row {
        let scenario: Scenario
        let condition: ExperiencePresentationStateHost.Condition
    }

    private let scenarios: [Scenario]
    private var rows: [Row] { scenarios.flatMap { scenario in
        ExperiencePresentationStateHost.Condition.allCases.map {
            Row(scenario: scenario, condition: $0)
        }
    } }
    private var presentation: ExperiencePresentationStateHost.Presentation?
    private var didPresentLaunchArgumentScenario = false

    init() {
        scenarios = Self.loadScenarios()
        super.init(style: .insetGrouped)
        title = "Presentation states"
        navigationItem.largeTitleDisplayMode = .always
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.accessibilityIdentifier = "nuxie-presentation-state-list"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "state")
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        presentLaunchArgumentScenarioIfNeeded()
    }

    /// Presents the scenario named on the command line so a capture run can
    /// address one state directly instead of driving the list by hand.
    private func presentLaunchArgumentScenarioIfNeeded() {
        guard !didPresentLaunchArgumentScenario,
              let id = Self.argument(named: "--nuxie-presentation-state"),
              let scenario = scenarios.first(where: { $0.id == id }) else {
            return
        }
        didPresentLaunchArgumentScenario = true
        let condition = Self.argument(named: "--nuxie-presentation-condition")
            .flatMap(ExperiencePresentationStateHost.Condition.init(rawValue:))
            ?? .normal
        Task { await present(scenario: scenario, condition: condition) }
    }

    private static func argument(named name: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: name),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        scenarios.count
    }

    override func tableView(
        _ tableView: UITableView,
        titleForHeaderInSection section: Int
    ) -> String? {
        let scenario = scenarios[section]
        return "\(scenario.title) — \(scenario.summary)"
    }

    override func tableView(
        _ tableView: UITableView,
        numberOfRowsInSection section: Int
    ) -> Int {
        ExperiencePresentationStateHost.Condition.allCases.count
    }

    override func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "state", for: indexPath)
        let scenario = scenarios[indexPath.section]
        let condition = ExperiencePresentationStateHost.Condition.allCases[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = Self.label(for: condition)
        content.secondaryText = Self.detail(for: condition)
        cell.contentConfiguration = content
        cell.accessibilityIdentifier =
            "nuxie-presentation-state-\(scenario.id)-\(condition.rawValue)"
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let scenario = scenarios[indexPath.section]
        let condition = ExperiencePresentationStateHost.Condition.allCases[indexPath.row]
        Task { await present(scenario: scenario, condition: condition) }
    }

    @MainActor
    private func present(
        scenario: Scenario,
        condition: ExperiencePresentationStateHost.Condition
    ) async {
        guard let fixtureBaseURL = Self.stateFixturesRoot?
            .appendingPathComponent(scenario.id, isDirectory: true) else {
            return
        }
        // A fresh cache per run keeps `normal` and `slow` honest: a shared
        // cache would make the second run memory-warm and hide the very state
        // the row exists to show.
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("nuxie-presentation-states", isDirectory: true)
            .appendingPathComponent(
                "\(scenario.id)-\(condition.rawValue)-\(UUID().uuidString)",
                isDirectory: true
            )
        do {
            presentation = try await ExperiencePresentationStateHost.present(
                .init(
                    fixtureBaseURL: fixtureBaseURL,
                    cacheRootURL: cacheRoot,
                    condition: condition
                ),
                from: self,
                onClose: { [weak self] in self?.presentation = nil }
            )
        } catch {
            let alert = UIAlertController(
                title: "Could not present",
                message: error.localizedDescription,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
    }

    private static func label(
        for condition: ExperiencePresentationStateHost.Condition
    ) -> String {
        switch condition {
        case .normal: "Cold present"
        case .slow: "Slow acquisition"
        case .failure: "Offline failure"
        case .warm: "Memory warm"
        }
    }

    private static func detail(
        for condition: ExperiencePresentationStateHost.Condition
    ) -> String {
        switch condition {
        case .normal: "Loading shell, then reveal"
        case .slow: "Sustained loading, then recovery affordances"
        case .failure: "Recovery state"
        case .warm: "Reveals without loading treatment"
        }
    }

    private static var stateFixturesRoot: URL? {
        Bundle.main.resourceURL?
            .appendingPathComponent("PresentationStates", isDirectory: true)
    }

    private static func loadScenarios() -> [Scenario] {
        struct Index: Decodable {
            struct Entry: Decodable {
                let id: String
                let title: String
                let summary: String
                let style: String
            }

            let schemaVersion: String
            let scenarios: [Entry]
        }

        guard let url = stateFixturesRoot?
            .appendingPathComponent("states-index.json"),
            FileManager.default.fileExists(atPath: url.path) else {
            preconditionFailure("states-index.json is missing from the host bundle")
        }
        do {
            let index = try JSONDecoder().decode(Index.self, from: Data(contentsOf: url))
            precondition(
                index.schemaVersion == "nuxie-sdk-presentation-states.v1",
                "Unsupported presentation-state index"
            )
            return index.scenarios.map {
                Scenario(id: $0.id, title: $0.title, summary: $0.summary, style: $0.style)
            }
        } catch {
            preconditionFailure("Invalid states-index.json: \(error)")
        }
    }
}
