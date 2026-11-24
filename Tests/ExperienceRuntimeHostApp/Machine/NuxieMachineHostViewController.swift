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
/// that says how it is presented swapped in memory ([`asCover`]). As a
/// sheet or a cover, the app also shows UIKit's own safe-area insets for
/// the screen, in a window above the paywall that takes no touches, as the
/// element `nuxie-machine-safe-area` ([`NuxieMachineSafeAreaWindow`]), so a
/// UI test can check the paywall's place against them, with every place the
/// session was told (`nuxie-machine-places`).
///
/// `--nuxie-machine-sheet-detent medium` turns the presented sheet to
/// UIKit's medium detent once it is up, here in the test host only: the
/// SDK presents a sheet at the large detent, and this lets a UI test record
/// what UIKit gives a sheet of another height.
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
    /// The window this host appeared in. Held here, since a cover takes the
    /// host's view out of its window while it is up.
    private weak var appearedIn: UIWindow?

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

    /// Whether a presented sheet is turned to the medium detent once it is
    /// up (`--nuxie-machine-sheet-detent medium`).
    private static var turnsSheetsMedium: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        guard let at = arguments.firstIndex(of: "--nuxie-machine-sheet-detent"), at + 1 < arguments.count
        else { return false }
        return arguments[at + 1] == "medium"
    }
    /// Looks for a sheet up to turn, four times a second, while the app runs.
    private var detentTimer: Timer?
    /// The sheet last turned, so each is turned once.
    private weak var turnedSheet: UIViewController?

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
        if Self.turnsSheetsMedium {
            detentTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.turnTheSheetMedium() }
            }
        }

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
        if safeArea == nil, let scene = view.window?.windowScene {
            safeArea = NuxieMachineSafeAreaWindow(windowScene: scene) { [weak self] in self?.presenter?.edge }
        }
    }

    /// The paywall's sheet, once it is up and not moving, turned to the
    /// medium detent: its detents set to medium alone and that one chosen,
    /// as UIKit animates a change of detent.
    private func turnTheSheetMedium() {
        guard let screen = presentedViewController as? NuxieMachineScreenViewController, screen !== turnedSheet,
              !screen.isBeingPresented, screen.transitionCoordinator == nil,
              let sheet = screen.sheetPresentationController else { return }
        turnedSheet = screen
        sheet.animateChanges {
            sheet.detents = [.medium()]
            sheet.selectedDetentIdentifier = .medium
        }
    }

    /// Turn the window `shown` appeared in when a test posts one of
    /// [`appearanceNotifications`]. Listens once per app run.
    private static var listening = false
    private static func listenForAppearance(turning host: NuxieMachineHostViewController) {
        shown = host
        host.appearedIn = host.view.window
        guard !listening else { return }
        listening = true
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        for name in appearanceNotifications.keys {
            CFNotificationCenterAddObserver(center, nil, { _, _, name, _, _ in
                guard let name else { return }
                let raw = name.rawValue as String
                Task { @MainActor in
                    guard let style = NuxieMachineHostViewController.appearanceNotifications[raw] else { return }
                    NuxieMachineHostViewController.shown?.appearedIn?.overrideUserInterfaceStyle = style
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
/// Beside it, `nuxie-machine-surface` is labeled with the presented
/// Screen's surface as the app sees it ([`NuxieMachineSurfaceFacts`]):
/// `bounds W H drawable W H scale S drawn W H`, then `view T R B L W H`
/// (the safe-area insets UIKit gives the Screen's view, and the view's
/// size, which a sheet drawn smaller keeps), then `place T R B L W H`
/// once it has a place (the insets and size the session is told). And
/// `nuxie-machine-places` is labeled with every place the session took, in
/// order, from the edge's log (`edge`): `T R B L W H` each, `; ` between, or
/// `none`. Both are read four times a second, so a UI test can tell a frame
/// the app drew wrong from a screenshot taken wrong, and see each place told.
@MainActor
final class NuxieMachineSafeAreaWindow: UIWindow {
    init(windowScene: UIWindowScene, edge: @escaping @MainActor () -> NuxieMachineEdge? = { nil }) {
        super.init(windowScene: windowScene)
        windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 1)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        rootViewController = Reader(edge: edge)
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
        private let surfaceLabel = UILabel()
        private let placesLabel = UILabel()
        private let edge: @MainActor () -> NuxieMachineEdge?
        /// Kept for the app's run, as the window is; it holds this weakly.
        private var timer: Timer?

        init(edge: @escaping @MainActor () -> NuxieMachineEdge?) {
            self.edge = edge
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

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
            surfaceLabel.textColor = .clear
            surfaceLabel.font = .systemFont(ofSize: 1)
            surfaceLabel.frame = CGRect(x: 1, y: 0, width: 1, height: 1)
            surfaceLabel.isAccessibilityElement = true
            surfaceLabel.accessibilityIdentifier = "nuxie-machine-surface"
            surfaceLabel.accessibilityLabel = "no Screen"
            view.addSubview(surfaceLabel)
            placesLabel.textColor = .clear
            placesLabel.font = .systemFont(ofSize: 1)
            placesLabel.frame = CGRect(x: 2, y: 0, width: 1, height: 1)
            placesLabel.isAccessibilityElement = true
            placesLabel.accessibilityIdentifier = "nuxie-machine-places"
            placesLabel.accessibilityLabel = "none"
            view.addSubview(placesLabel)
            self.view = view
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.readSurface()
                    self?.readPlaces()
                }
            }
        }

        /// The presented Screen's surface, from the first Screen presented
        /// in any of the scene's other windows.
        private func readSurface() {
            guard let screen = Self.presentedScreen(in: view.window?.windowScene) else {
                surfaceLabel.accessibilityLabel = "no Screen"
                return
            }
            let facts = screen.surfaceFacts
            let drawn = facts.drawn ?? .zero
            let insets = screen.viewIfLoaded?.safeAreaInsets ?? .zero
            let size = screen.viewIfLoaded?.bounds.size ?? .zero
            let numbers = [facts.bounds.width, facts.bounds.height, facts.drawableSize.width,
                           facts.drawableSize.height, facts.contentsScale, drawn.width, drawn.height]
                .map { "\(Double($0))" }
            let viewInsets = " view " + [insets.top, insets.right, insets.bottom, insets.left, size.width, size.height]
                .map { "\(Double($0))" }.joined(separator: " ")
            let place = facts.place.map {
                " place " + [$0.top, $0.right, $0.bottom, $0.left, $0.width, $0.height].map { "\($0)" }
                    .joined(separator: " ")
            } ?? ""
            surfaceLabel.accessibilityLabel = "bounds \(numbers[0]) \(numbers[1]) drawable \(numbers[2]) \(numbers[3]) "
                + "scale \(numbers[4]) drawn \(numbers[5]) \(numbers[6])" + viewInsets + place
        }

        /// Every place the session took, from the edge's log. Kept as it was
        /// once the edge is let go of.
        private func readPlaces() {
            guard let edge = edge() else { return }
            Task { @MainActor [weak self] in
                let log = await edge.log
                let told = log.compactMap { entry -> NuxieMachineScreenPlace? in
                    if case .place(_, let place) = entry { return place }
                    return nil
                }
                self?.placesLabel.accessibilityLabel = told.isEmpty ? "none" : told.map { place in
                    [place.top, place.right, place.bottom, place.left, place.width, place.height]
                        .map { "\($0)" }.joined(separator: " ")
                }.joined(separator: "; ")
            }
        }

        private static func presentedScreen(in scene: UIWindowScene?) -> NuxieMachineScreenViewController? {
            for window in scene?.windows ?? [] where !(window is NuxieMachineSafeAreaWindow) {
                var controller = window.rootViewController
                while let next = controller?.presentedViewController {
                    if let screen = next as? NuxieMachineScreenViewController { return screen }
                    controller = next
                }
            }
            return nil
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
