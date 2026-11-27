import Foundation
import NuxieMachine
import UIKit

// FOR TESTS ONLY. This module exists only while the Nux machine's library is
// staged, and the runtime host app shows this screen for
// `--nuxie-machine-gallery`.

/// A plain app screen that opens a gallery of one picture as a sheet.
/// "Open the gallery" starts a record with the event `opened`, and the
/// machine opens the `views-picture` page, its route turned into a sheet in
/// memory ([`NuxieMachineGalleryFixture`]). One line says what the record
/// holds.
///
/// With `--nuxie-machine-files-never-come` the picture's bytes never come
/// ([`NuxieMachineUnansweredBytes`]), so the sheet waits on its loading
/// screen; otherwise they are read from the bundled folder.
@MainActor
public final class NuxieMachineGalleryHostViewController: UIViewController {
    private let titleLabel = UILabel()
    private let bodyLabel = UILabel()
    private let openButton = UIButton(configuration: .filled())
    private let recordLabel = UILabel()
    private var presenter: NuxieMachineSheetPresenter?

    /// Whether the picture's bytes never come.
    private static var filesNeverCome: Bool {
        ProcessInfo.processInfo.arguments.contains("--nuxie-machine-files-never-come")
    }

    public init() {
        super.init(nibName: nil, bundle: nil)
        title = "Gallery"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override public func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        titleLabel.text = "Today's picture"
        titleLabel.font = .preferredFont(forTextStyle: .largeTitle)
        titleLabel.adjustsFontForContentSizeCategory = true
        bodyLabel.text = "The gallery opens over this screen as a sheet."
        bodyLabel.font = .preferredFont(forTextStyle: .body)
        bodyLabel.textColor = .secondaryLabel
        bodyLabel.numberOfLines = 0

        openButton.configuration?.title = "Open the gallery"
        openButton.configuration?.cornerStyle = .large
        openButton.configuration?.buttonSize = .large
        openButton.accessibilityIdentifier = "nuxie-machine-open-gallery"
        openButton.addAction(UIAction { [weak self] _ in self?.openGallery() }, for: .primaryActionTriggered)

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

    private func openGallery() {
        guard presenter == nil else { return }
        openButton.isEnabled = false
        let presenter = NuxieMachineSheetPresenter(host: self) { [weak self] status in self?.show(status) }
        self.presenter = presenter
        Task { @MainActor [weak self] in
            do {
                let plan = try NuxieMachineGalleryFixture.load(from: .main)
                let folder = try NuxieMachineFolder(named: NuxieMachineGalleryFixture.folder, in: .main)
                let bytes: any NuxieMachineByteSource
                if Self.filesNeverCome {
                    bytes = NuxieMachineUnansweredBytes()
                } else {
                    bytes = folder.bytes
                }
                await presenter.start(plan: plan, store: NuxieMachineStandInStore(), bytes: bytes, event: "opened")
            } catch {
                self?.recordLabel.text = "Record: the fixture did not load (\(error))"
            }
        }
    }

    private func show(_ status: NuxieMachineSheetStatus) {
        recordLabel.text = "Record: " + NuxieMachineSheetPresenter.describe(status.record)
    }
}

/// A byte source that never answers: each ask waits until the edge stops
/// asking, as a phone whose request never comes back.
struct NuxieMachineUnansweredBytes: NuxieMachineByteSource {
    func bytes(for path: String) async throws -> Data {
        while true {
            try await Task.sleep(nanoseconds: 3_600_000_000_000)
        }
    }
}

/// The picture page as the staged host app bundles it under
/// `views-picture/`: its one source file, with its route presenting a sheet
/// where the folder presents a cover, changed in memory, and the rows of
/// the folder's other files as bundled. The same files the machine's
/// simulator suite uses.
enum NuxieMachineGalleryFixture {
    /// The folder in the app bundle.
    static let folder = "views-picture"

    static let coverRoute = "fits  Fits(close=close)  cover"
    static let sheetRoute = "fits  Fits(close=close)  sheet"

    struct Missing: Error, CustomStringConvertible {
        let what: String
        var description: String { "views-picture: \(what)" }
    }

    static func load(from bundle: Bundle) throws -> NuxieMachinePlanSource {
        guard let url = bundle.url(forResource: "main", withExtension: "nux", subdirectory: folder)
        else { throw Missing(what: "main.nux is not in the app bundle") }
        let main = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        guard main.components(separatedBy: coverRoute).count == 2 else {
            throw Missing(what: "main.nux does not have the page's route exactly once")
        }
        return NuxieMachinePlanSource(
            files: [NuxieMachineSourceFile(path: "main.nux",
                                           text: main.replacingOccurrences(of: coverRoute, with: sheetRoute))],
            assets: try NuxieMachineFolder(named: folder, in: bundle).assets(), root: "main", app: "app",
            experience: "gallery", version: 1)
    }
}
