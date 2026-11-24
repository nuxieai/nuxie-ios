import Foundation
import NuxieMachine
import UIKit

// FOR TESTS ONLY. This module exists only while the Nux machine's library is
// staged, and the runtime host app shows it for `--nuxie-machine-paywall`.

/// A plain app screen at the end of onboarding. "Finish onboarding" starts a
/// record with the event `onboarding_completed`, standing in for the SDK
/// seeing the app's own event, and the machine opens Stillwater's paywall
/// as a sheet. The paywall is drawn from `paywall.nux` and its
/// `plan-card.nux` alone, compiled on this phone, and the machine writes it
/// from inside the engine's step. Two lines say what the record holds: the
/// selected plan, read from the session's root slot, and the record's
/// state.
///
/// `--nuxie-machine-appearance dark` (or `light`) starts the app in that
/// appearance: it is set on the app's window, standing in for the phone's
/// own setting, and the paywall, which follows the phone, draws in it.
/// While the app runs, the Darwin notification
/// `dev.nuxie.machine.appearance.dark` (or `.light`) turns the window to
/// that appearance the same way, so a UI test can turn the phone while the
/// paywall is open: the simulator's own appearance setting does not reach a
/// running app on every simulator.
///
/// `--nuxie-machine-paywall-cover` presents the same paywall as a cover:
/// Stillwater's files as bundled, with the one word of the paywall's route
/// that says how it is presented swapped in memory ([`asCover`]). The app
/// then also shows UIKit's own safe-area insets for the screen, in a
/// window above the cover that takes no touches, as the element
/// `nuxie-machine-safe-area` ([`NuxieMachineSafeAreaWindow`]), so a UI test
/// can check the cover's place against them.
@MainActor
public final class NuxieMachineHostViewController: UIViewController {
    /// The Darwin notifications that turn the window, with the appearance
    /// each one turns it to.
    public static let appearanceNotifications: [String: UIUserInterfaceStyle] = [
        "dev.nuxie.machine.appearance.dark": .dark,
        "dev.nuxie.machine.appearance.light": .light,
    ]
    /// The host the notifications turn: the one on screen.
    private static weak var shown: NuxieMachineHostViewController?

    private let titleLabel = UILabel()
    private let bodyLabel = UILabel()
    private let finishButton = UIButton(configuration: .filled())
    private let planLabel = UILabel()
    private let recordLabel = UILabel()
    private var presenter: NuxieMachineSheetPresenter?
    private var safeArea: NuxieMachineSafeAreaWindow?

    /// Whether the paywall is presented as a cover.
    private static var presentsACover: Bool {
        ProcessInfo.processInfo.arguments.contains("--nuxie-machine-paywall-cover")
    }

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

    override public func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        if let appearance = Self.launchAppearance {
            view.window?.overrideUserInterfaceStyle = appearance
        }
        Self.listenForAppearance(turning: self)
        if Self.presentsACover, safeArea == nil, let scene = view.window?.windowScene {
            safeArea = NuxieMachineSafeAreaWindow(windowScene: scene)
        }
    }

    /// Turn the window `shown` is in when a test posts one of
    /// [`appearanceNotifications`]. Listens once per app run.
    private static var listening = false
    private static func listenForAppearance(turning host: NuxieMachineHostViewController) {
        shown = host
        guard !listening else { return }
        listening = true
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        for name in appearanceNotifications.keys {
            CFNotificationCenterAddObserver(center, nil, { _, _, name, _, _ in
                guard let name else { return }
                let raw = name.rawValue as String
                Task { @MainActor in
                    guard let style = NuxieMachineHostViewController.appearanceNotifications[raw] else { return }
                    NuxieMachineHostViewController.shown?.view.window?.overrideUserInterfaceStyle = style
                }
            }, name as CFString, nil, .deliverImmediately)
        }
    }

    /// The appearance `--nuxie-machine-appearance` names, if any.
    private static var launchAppearance: UIUserInterfaceStyle? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let at = arguments.firstIndex(of: "--nuxie-machine-appearance"), at + 1 < arguments.count
        else { return nil }
        switch arguments[at + 1] {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }

    private func finishOnboarding() {
        guard presenter == nil else { return }
        finishButton.isEnabled = false
        let presenter = NuxieMachineSheetPresenter(host: self) { [weak self] status in self?.show(status) }
        self.presenter = presenter
        Task { @MainActor [weak self] in
            do {
                let plan = try NuxieMachineStillwaterFixture.load(from: .main, asCover: Self.presentsACover)
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
/// stand-in store's answer (a `Purchase` whose status is `failed`), given a
/// second and a half after the call, so a person sees the paywall while it
/// buys.
struct NuxieMachineSlowStore: NuxieMachineStore {
    private let answering = NuxieMachineStandInStore()

    func perform(_ call: NuxieMachineCall) async throws -> NuxieMachineReply {
        try await Task.sleep(nanoseconds: 1_500_000_000)
        return try await answering.perform(call)
    }
}

/// Stillwater as the staged host app bundles it under `stillwater/`: its
/// five `.nux` files and the plan's header. The same files the machine's
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

    /// The paywall's route as bundled, and as a cover.
    static let sheetRoute = "    paywall  Paywall sheet\n"
    static let coverRoute = "    paywall  Paywall cover\n"

    struct NoSheetRoute: Error, CustomStringConvertible {
        var description: String { "stillwater/main.nux does not have the paywall's route exactly once" }
    }

    /// Stillwater's files, or with `asCover` the same files with the
    /// paywall's route presenting a cover: only that one word of `main.nux`
    /// changes, in memory. The bundled files are not touched.
    static func load(from bundle: Bundle, asCover: Bool = false) throws -> NuxieMachinePlanSource {
        func data(_ name: String) throws -> Data {
            let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
            guard let url = bundle.url(forResource: parts[0], withExtension: parts[1],
                                       subdirectory: "stillwater") else { throw Missing(name: name) }
            return try Data(contentsOf: url)
        }
        let provenance = try JSONDecoder().decode(Provenance.self, from: data("provenance.json"))
        let files = try ["main.nux", "paywall.nux", "plan-card.nux", "screens.nux", "done.nux"].map { name in
            let text = String(decoding: try data(name), as: UTF8.self)
            let swapped = asCover && name == "main.nux" ? try Self.asCover(text) : text
            return NuxieMachineSourceFile(path: name, text: swapped)
        }
        return NuxieMachinePlanSource(files: files, root: provenance.plan.root, app: provenance.plan.app,
                                      experience: provenance.plan.experience, version: provenance.plan.version)
    }
}

extension NuxieMachineStillwaterFixture {
    /// `main` with the paywall's route presenting a cover.
    static func asCover(_ main: String) throws -> String {
        guard main.components(separatedBy: sheetRoute).count == 2 else { throw NoSheetRoute() }
        return main.replacingOccurrences(of: sheetRoute, with: coverRoute)
    }
}

/// UIKit's safe-area insets for the whole screen, shown to a UI test: a
/// window over the scene, above the app's own and its cover, that takes no
/// touches and draws nothing. Its one element, `nuxie-machine-safe-area`,
/// is labeled with the window's `safeAreaInsets` as `top right bottom left`
/// in points, read again whenever they change (a rotation, the status bar).
@MainActor
final class NuxieMachineSafeAreaWindow: UIWindow {
    override init(windowScene: UIWindowScene) {
        super.init(windowScene: windowScene)
        windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 1)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        rootViewController = Reader()
        isHidden = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Every touch goes through to the app's own window.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        nil
    }

    /// The view controller whose view's label reads the window's insets. It
    /// leaves the status bar and the orientations to the app's own.
    private final class Reader: UIViewController {
        private let label = UILabel()

        override func loadView() {
            let view = UIView()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
            label.textColor = .clear
            label.font = .systemFont(ofSize: 1)
            label.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
            label.isAccessibilityElement = true
            label.accessibilityIdentifier = "nuxie-machine-safe-area"
            view.addSubview(label)
            self.view = view
        }

        override func viewSafeAreaInsetsDidChange() {
            super.viewSafeAreaInsetsDidChange()
            read()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            read()
        }

        private func read() {
            let insets = view.window?.safeAreaInsets ?? .zero
            let words = [insets.top, insets.right, insets.bottom, insets.left].map { "\(Double($0))" }
            label.accessibilityLabel = words.joined(separator: " ")
        }
    }
}

private extension UIFont {
    func withTraits(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(traits) else { return self }
        return UIFont(descriptor: descriptor, size: 0)
    }
}
