import Foundation
import NuxieMachine
import UIKit

// FOR TESTS ONLY. This module exists only while the Nux machine's library is
// staged, and the runtime host app shows this screen for
// `--nuxie-machine-counter`.

/// A plain app screen that opens a small counter drawn from its Nux alone.
/// "Open the counter" starts a record with the event `opened`, and the
/// machine's `present` row opens the counter as a cover. The edge draws
/// the plan's own compiled view, and the machine writes it from inside the
/// engine's step. One line says what the record holds.
@MainActor
public final class NuxieMachineCounterHostViewController: UIViewController {
    private let titleLabel = UILabel()
    private let bodyLabel = UILabel()
    private let openButton = UIButton(configuration: .filled())
    private let recordLabel = UILabel()
    private var presenter: NuxieMachineSheetPresenter?

    public init() {
        super.init(nibName: nil, bundle: nil)
        title = "Tally"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override public func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        titleLabel.text = "Counter"
        titleLabel.font = .preferredFont(forTextStyle: .largeTitle)
        titleLabel.adjustsFontForContentSizeCategory = true
        bodyLabel.text = "The counter opens over this screen. Its view comes from its Nux source, compiled on this phone."
        bodyLabel.font = .preferredFont(forTextStyle: .body)
        bodyLabel.textColor = .secondaryLabel
        bodyLabel.numberOfLines = 0

        openButton.configuration?.title = "Open the counter"
        openButton.configuration?.cornerStyle = .large
        openButton.configuration?.buttonSize = .large
        openButton.accessibilityIdentifier = "nuxie-machine-open-counter"
        openButton.addAction(UIAction { [weak self] _ in self?.openCounter() }, for: .primaryActionTriggered)

        recordLabel.font = .preferredFont(forTextStyle: .footnote)
        recordLabel.textColor = .secondaryLabel
        recordLabel.numberOfLines = 0
        recordLabel.accessibilityIdentifier = "nuxie-machine-record"
        show(NuxieMachineSheetStatus(plan: nil, record: .notStarted))

        let stack = UIStackView(arrangedSubviews: [titleLabel, bodyLabel, openButton, recordLabel])
        stack.axis = .vertical
        stack.spacing = 16
        stack.setCustomSpacing(32, after: bodyLabel)
        stack.setCustomSpacing(28, after: openButton)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        let margins = view.layoutMarginsGuide
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
        ])
    }

    private func openCounter() {
        guard presenter == nil else { return }
        openButton.isEnabled = false
        let presenter = NuxieMachineSheetPresenter(host: self) { [weak self] status in self?.show(status) }
        self.presenter = presenter
        Task { @MainActor [weak self] in
            do {
                let plan = try NuxieMachineCounterFixture.load(from: .main)
                await presenter.start(plan: plan, store: NuxieMachineStandInStore(), event: "opened")
            } catch {
                self?.recordLabel.text = "Record: the fixture did not load (\(error))"
            }
        }
    }

    private func show(_ status: NuxieMachineSheetStatus) {
        recordLabel.text = "Record: " + NuxieMachineSheetPresenter.describe(status.record)
    }
}

/// The counter as the staged host app bundles it under `views-slice-1/`:
/// its two `.nux` files and the plan's header. The same files the machine's
/// simulator suite uses.
enum NuxieMachineCounterFixture {
    private struct Provenance: Decodable {
        struct Plan: Decodable {
            let root: String
            let app: String
            let experience: String
            let version: UInt32
        }
        let plan: Plan
    }

    struct Missing: Error, CustomStringConvertible {
        let name: String
        var description: String { "views-slice-1/\(name) is not in the app bundle" }
    }

    static func load(from bundle: Bundle) throws -> NuxieMachinePlanSource {
        func data(_ name: String) throws -> Data {
            let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
            guard let url = bundle.url(forResource: parts[0], withExtension: parts[1],
                                       subdirectory: "views-slice-1") else { throw Missing(name: name) }
            return try Data(contentsOf: url)
        }
        let provenance = try JSONDecoder().decode(Provenance.self, from: data("provenance.json"))
        let files = try ["main.nux", "counter.nux"].map {
            NuxieMachineSourceFile(path: $0, text: String(decoding: try data($0), as: UTF8.self))
        }
        return NuxieMachinePlanSource(files: files, root: provenance.plan.root, app: provenance.plan.app,
                                      experience: provenance.plan.experience, version: provenance.plan.version)
    }
}
