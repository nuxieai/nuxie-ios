import Foundation
import NuxieMachine
import UIKit

// FOR TESTS ONLY. This module exists only while the Nux machine's library is
// staged, and the runtime host app shows it for `--nuxie-machine-paywall`.

/// A plain app screen at the end of onboarding. "Finish onboarding" starts a
/// record with the event `onboarding_completed`, standing in for the SDK
/// seeing the app's own event, and the machine opens Stillwater's paywall
/// as a sheet. The paywall is drawn from `paywall.nux` alone, compiled on
/// this phone, and the machine writes it from inside the engine's step. Two lines say what the record holds: the
/// selected plan, read from the session's root slot, and the record's
/// state.
@MainActor
public final class NuxieMachineHostViewController: UIViewController {
    private let titleLabel = UILabel()
    private let bodyLabel = UILabel()
    private let finishButton = UIButton(configuration: .filled())
    private let planLabel = UILabel()
    private let recordLabel = UILabel()
    private var presenter: NuxieMachineSheetPresenter?

    public init() {
        super.init(nibName: nil, bundle: nil)
        title = "Stillwater"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override public func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        titleLabel.text = "You're all set"
        titleLabel.font = .preferredFont(forTextStyle: .largeTitle).withTraits(.traitBold)
        titleLabel.adjustsFontForContentSizeCategory = true
        bodyLabel.text = "Your evening reminder is on and your first session is ready."
        bodyLabel.font = .preferredFont(forTextStyle: .body)
        bodyLabel.textColor = .secondaryLabel
        bodyLabel.numberOfLines = 0

        finishButton.configuration?.title = "Finish onboarding"
        finishButton.configuration?.cornerStyle = .large
        finishButton.configuration?.buttonSize = .large
        finishButton.accessibilityIdentifier = "nuxie-machine-finish-onboarding"
        finishButton.addAction(UIAction { [weak self] _ in self?.finishOnboarding() }, for: .primaryActionTriggered)

        for (label, identifier) in [(planLabel, "nuxie-machine-plan"), (recordLabel, "nuxie-machine-record")] {
            label.font = .preferredFont(forTextStyle: .footnote)
            label.textColor = .secondaryLabel
            label.numberOfLines = 0
            label.accessibilityIdentifier = identifier
        }
        show(NuxieMachineSheetStatus(plan: nil, record: .notStarted))

        let lines = UIStackView(arrangedSubviews: [planLabel, recordLabel])
        lines.axis = .vertical
        lines.spacing = 4
        let stack = UIStackView(arrangedSubviews: [titleLabel, bodyLabel, finishButton, lines])
        stack.axis = .vertical
        stack.spacing = 16
        stack.setCustomSpacing(32, after: bodyLabel)
        stack.setCustomSpacing(28, after: finishButton)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        let margins = view.layoutMarginsGuide
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
        ])
    }

    private func finishOnboarding() {
        guard presenter == nil else { return }
        finishButton.isEnabled = false
        let presenter = NuxieMachineSheetPresenter(host: self) { [weak self] status in self?.show(status) }
        self.presenter = presenter
        Task { @MainActor [weak self] in
            do {
                let plan = try NuxieMachineStillwaterFixture.load(from: .main)
                await presenter.start(plan: plan, store: NuxieMachineSlowStore(), event: "onboarding_completed")
            } catch {
                self?.recordLabel.text = "Record: the fixture did not load (\(error))"
            }
        }
    }

    private func show(_ status: NuxieMachineSheetStatus) {
        planLabel.text = "Selected plan: \(status.plan ?? "none")"
        recordLabel.text = "Record: " + NuxieMachineSheetPresenter.describe(status.record)
    }
}

/// A purchase that takes a moment, as a store's own sheet does: the
/// stand-in store's answer (`failed`), given a second and a half after the
/// call, so a person sees the paywall while it buys.
struct NuxieMachineSlowStore: NuxieMachineStore {
    private let answering = NuxieMachineStandInStore()

    func perform(_ call: NuxieMachineCall) async throws -> String {
        try await Task.sleep(nanoseconds: 1_500_000_000)
        return try await answering.perform(call)
    }
}

/// Stillwater as the staged host app bundles it under `stillwater/`: its
/// four `.nux` files and the plan's header. The same files the machine's
/// simulator suite uses.
enum NuxieMachineStillwaterFixture {
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
        var description: String { "stillwater/\(name) is not in the app bundle" }
    }

    static func load(from bundle: Bundle) throws -> NuxieMachinePlanSource {
        func data(_ name: String) throws -> Data {
            let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
            guard let url = bundle.url(forResource: parts[0], withExtension: parts[1],
                                       subdirectory: "stillwater") else { throw Missing(name: name) }
            return try Data(contentsOf: url)
        }
        let provenance = try JSONDecoder().decode(Provenance.self, from: data("provenance.json"))
        let files = try ["main.nux", "paywall.nux", "screens.nux", "done.nux"].map {
            NuxieMachineSourceFile(path: $0, text: String(decoding: try data($0), as: UTF8.self))
        }
        return NuxieMachinePlanSource(files: files, root: provenance.plan.root, app: provenance.plan.app,
                                      experience: provenance.plan.experience, version: provenance.plan.version)
    }
}

private extension UIFont {
    func withTraits(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(traits) else { return self }
        return UIFont(descriptor: descriptor, size: 0)
    }
}
