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
/// The person's text size is stood in for the same way, on the same window:
/// `--nuxie-machine-text-size UICTContentSizeCategoryXXXL` (any of UIKit's
/// size categories, by its raw value) starts the app at that size, and the
/// Darwin notification `dev.nuxie.machine.text-size.<raw value>`, for the
/// sizes in [`textSizeNotifications`], changes it while the app runs. Both
/// set the window's trait override, so they need iOS 17 or later; on an
/// older system they do nothing. Every environment the session was told is
/// shown as the element `nuxie-machine-environments`.
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
///
/// `--nuxie-machine-clock 17:59,18:00,20:00` gives the session a clock of
/// its own, for a film of the evening ([`FilmClock`]): the record starts
/// with the machine's clock at the first time of day, and the Darwin
/// notification `dev.nuxie.machine.clock.<time>` for each later one moves
/// it there while the app runs, forward only. The times are of the day the
/// app was launched, in UTC, the day the machine reads `next 18:00` in; a
/// time written `09:00+1d` is that time a day later. Between moves the
/// clock runs at the wall clock's pace. A move goes through the
/// presenter's one seam for it, [`NuxieMachineSheetPresenter.clockAhead`],
/// so a wake it makes due fires through the presenter's own timer.
///
/// The Darwin notifications `dev.nuxie.machine.presence.away` and
/// `dev.nuxie.machine.presence.back` stand in for the person leaving the
/// app and coming back ([`presenceNotifications`]): each calls the
/// presenter's [`NuxieMachineSheetPresenter.presence(here:)`], the entry
/// UIKit's background and foreground notices call, with the app still in
/// the foreground. A UI test cannot hold the app in the background across
/// a move of the clock, so it says away, moves the clock and says back.
/// Every presence the session took is shown as the element
/// `nuxie-machine-presences`.
///
/// `--nuxie-machine-scroll-sheet` opens a paywall whose page is a `scroll`,
/// as a sheet, in place of Stillwater's: the `views-scroll` paywall, under a
/// header and with a floating button over its page ([`NuxieMachineScrollSheetFixture`]).
/// "Finish onboarding" starts its record the same way.
///
/// `--nuxie-machine-router-sheet` plays the machine suite's `router-sheet`
/// in place of Stillwater ([`NuxieMachineRouterSheetFixture`]): "Finish
/// onboarding" opens its `home` cover, whose "Offer" opens the `plans`
/// sheet. That sheet rests at its row's detents, and what a swipe down on
/// it does is the machine's: it closes the sheet while no control is
/// showing, and presses its `close` once "Allow" has shown it.
@MainActor
public final class NuxieMachineHostViewController: UIViewController {
    /// The Darwin notifications that turn the window, with the appearance
    /// each one turns it to.
    public static let appearanceNotifications: [String: UIUserInterfaceStyle] = [
        "dev.nuxie.machine.appearance.dark": .dark,
        "dev.nuxie.machine.appearance.light": .light,
    ]
    /// The Darwin notifications that change the window's text size, with the
    /// size category each one sets: the default, the largest standard and
    /// the largest accessibility size.
    public static let textSizeNotifications: [String: UIContentSizeCategory] = Dictionary(
        uniqueKeysWithValues: [UIContentSizeCategory.large, .extraExtraExtraLarge, .accessibilityExtraExtraExtraLarge]
            .map { ("dev.nuxie.machine.text-size.\($0.rawValue)", $0) })
    /// The Darwin notifications that stand in for the person leaving the
    /// app and coming back, with whether each says she is here.
    public static let presenceNotifications: [String: Bool] = [
        "dev.nuxie.machine.presence.away": false,
        "dev.nuxie.machine.presence.back": true,
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

    /// Whether the paywall is the `views-scroll` one shown as a sheet.
    private static var showsScrollSheet: Bool {
        ProcessInfo.processInfo.arguments.contains("--nuxie-machine-scroll-sheet")
    }

    /// Whether the plan is the machine suite's `router-sheet`.
    private static var showsRouterSheet: Bool {
        ProcessInfo.processInfo.arguments.contains("--nuxie-machine-router-sheet")
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
        if let textSize = Self.launchTextSize {
            Self.set(textSize, on: view.window)
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
    /// [`appearanceNotifications`], change its text size when it posts one
    /// of [`textSizeNotifications`], move the film clock, or tell its
    /// presenter the person left or came back ([`presenceNotifications`]).
    /// Listens once per app run.
    private static var listening = false
    private static func listenForAppearance(turning host: NuxieMachineHostViewController) {
        shown = host
        host.appearedIn = host.view.window
        guard !listening else { return }
        listening = true
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let clockMoves = Array((FilmClock.launched?.moves ?? [:]).keys)
        let names = Array(appearanceNotifications.keys) + Array(textSizeNotifications.keys) + clockMoves
            + Array(presenceNotifications.keys)
        for name in names {
            CFNotificationCenterAddObserver(center, nil, { _, _, name, _, _ in
                guard let name else { return }
                let raw = name.rawValue as String
                Task { @MainActor in
                    let window = NuxieMachineHostViewController.shown?.appearedIn
                    if let style = NuxieMachineHostViewController.appearanceNotifications[raw] {
                        window?.overrideUserInterfaceStyle = style
                    } else if let textSize = NuxieMachineHostViewController.textSizeNotifications[raw] {
                        NuxieMachineHostViewController.set(textSize, on: window)
                    } else if let moment = FilmClock.launched?.moves[raw],
                              let presenter = NuxieMachineHostViewController.shown?.presenter {
                        FilmClock.move(presenter, to: moment)
                    } else if let here = NuxieMachineHostViewController.presenceNotifications[raw],
                              let presenter = NuxieMachineHostViewController.shown?.presenter {
                        await presenter.presence(here: here)
                    }
                }
            }, name as CFString, nil, .deliverImmediately)
        }
    }

    /// Set `window`'s text size to `category`, standing in for the person's
    /// setting: its trait override, which every view and presentation in it
    /// inherits. Needs iOS 17 or later.
    private static func set(_ category: UIContentSizeCategory, on window: UIWindow?) {
        guard #available(iOS 17.0, *) else { return }
        window?.traitOverrides.preferredContentSizeCategory = category
    }

    /// The text size `--nuxie-machine-text-size` names by its raw value, if
    /// any.
    private static var launchTextSize: UIContentSizeCategory? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let at = arguments.firstIndex(of: "--nuxie-machine-text-size"), at + 1 < arguments.count
        else { return nil }
        let category = UIContentSizeCategory(rawValue: arguments[at + 1])
        return category == .unspecified ? nil : category
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
        if let clock = FilmClock.launched {
            // Set before the start, so the record starts at the first time.
            presenter.clockAhead = clock.start - FilmClock.wallNow()
        }
        self.presenter = presenter
        Task { @MainActor [weak self] in
            do {
                let plan: NuxieMachinePlanSource
                let named: String
                if Self.showsRouterSheet {
                    plan = try NuxieMachineRouterSheetFixture.load(from: .main)
                    named = NuxieMachineRouterSheetFixture.folder
                } else if Self.showsScrollSheet {
                    plan = try NuxieMachineScrollSheetFixture.load(from: .main)
                    named = NuxieMachineScrollSheetFixture.folder
                } else {
                    plan = try NuxieMachineStillwaterFixture.load(from: .main, asCover: Self.presentsACover)
                    named = NuxieMachineStillwaterFixture.folder
                }
                let folder = try NuxieMachineFolder(named: named, in: .main)
                await presenter.start(plan: plan, store: NuxieMachineSlowStore(), bytes: folder.bytes,
                                      event: "onboarding_completed")
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

/// The film clock `--nuxie-machine-clock` names: times of day (`HH:MM`,
/// comma separated) on the day the app was launched, in UTC, or with `+Nd`
/// (`09:00+1d`) that many days later. The record starts at the first; each
/// later one is a move a test asks for with the Darwin notification
/// `dev.nuxie.machine.clock.<time as written>`.
struct FilmClock {
    private static let day: Int64 = 24 * 3_600_000

    /// The machine's clock when the record starts, in milliseconds since the
    /// Unix epoch.
    let start: Int64
    /// Each later time, by the notification that moves the clock to it.
    let moves: [String: Int64]

    /// The clock the launch arguments name, if any. Read once, so every
    /// time is on the same day.
    static let launched: FilmClock? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let at = arguments.firstIndex(of: "--nuxie-machine-clock"), at + 1 < arguments.count else { return nil }
        let midnight = wallNow() / day * day
        let times = arguments[at + 1].split(separator: ",").map(String.init)
        let moments = times.compactMap { written -> Int64? in
            let halves = written.split(separator: "+", maxSplits: 1).map(String.init)
            var days: Int64 = 0
            if halves.count == 2 {
                guard halves[1].hasSuffix("d"), let count = Int64(halves[1].dropLast()) else { return nil }
                days = count
            }
            let parts = halves[0].split(separator: ":").compactMap { Int64($0) }
            guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return nil }
            return midnight + days * day + (parts[0] * 60 + parts[1]) * 60_000
        }
        guard moments.count == times.count, let start = moments.first else { return nil }
        let moves = Dictionary(zip(times.dropFirst().map { "dev.nuxie.machine.clock.\($0)" }, moments.dropFirst()),
                               uniquingKeysWith: { first, _ in first })
        return FilmClock(start: start, moves: moves)
    }()

    /// Milliseconds since the Unix epoch on the wall clock.
    static func wallNow() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded(.down))
    }

    /// Move `presenter`'s clock to `moment`, if that is later than it reads
    /// now: the machine takes nothing earlier than its last step.
    @MainActor
    static func move(_ presenter: NuxieMachineSheetPresenter, to moment: Int64) {
        let ahead = moment - wallNow()
        guard ahead > presenter.clockAhead else { return }
        presenter.clockAhead = ahead
    }
}

/// A purchase that takes a moment, as a store's own sheet does: the
/// stand-in store's answer (a `Purchase` whose status is `failed`), given
/// four seconds after the call, so a person sees the paywall while it buys
/// and a check has time to keep a still and a reading of it.
struct NuxieMachineSlowStore: NuxieMachineStore {
    private let answering = NuxieMachineStandInStore()

    func perform(_ call: NuxieMachineCall) async throws -> NuxieMachineReply {
        try await Task.sleep(nanoseconds: 4_000_000_000)
        return try await answering.perform(call)
    }
}

/// Stillwater as the staged host app bundles it under `stillwater/`: its
/// five program files, the plan's header, and the rows of the folder's
/// other files. The same files the machine's simulator suite uses. The
/// bundled `main.test.nux` is there for provenance only; `load` names the
/// program files, so it is never loaded.
enum NuxieMachineStillwaterFixture {
    /// The folder in the app bundle.
    static let folder = "stillwater"

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
                                       subdirectory: folder) else { throw Missing(name: name) }
            return try Data(contentsOf: url)
        }
        let provenance = try JSONDecoder().decode(Provenance.self, from: data("provenance.json"))
        let files = try ["main.nux", "paywall.nux", "plan-card.nux", "screens.nux", "done.nux"].map { name in
            let text = String(decoding: try data(name), as: UTF8.self)
            let swapped = asCover && name == "main.nux" ? try Self.asCover(text) : text
            return NuxieMachineSourceFile(path: name, text: swapped)
        }
        let assets = try NuxieMachineFolder(named: folder, in: bundle).assets()
        return NuxieMachinePlanSource(files: files, assets: assets, root: provenance.plan.root,
                                      app: provenance.plan.app, experience: provenance.plan.experience,
                                      version: provenance.plan.version)
    }
}

extension NuxieMachineStillwaterFixture {
    /// `main` with the paywall's route presenting a cover.
    static func asCover(_ main: String) throws -> String {
        guard main.components(separatedBy: sheetRoute).count == 2 else { throw NoSheetRoute() }
        return main.replacingOccurrences(of: sheetRoute, with: coverRoute)
    }
}

/// The machine suite's `router-sheet` as the staged host app bundles it
/// under `router-sheet/`: its two program files and the plan's header, as
/// bundled. The bundled `main.test.nux` is there for provenance only.
enum NuxieMachineRouterSheetFixture {
    /// The folder in the app bundle.
    static let folder = "router-sheet"

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
        var description: String { "router-sheet/\(name) is not in the app bundle" }
    }

    static func load(from bundle: Bundle) throws -> NuxieMachinePlanSource {
        func data(_ name: String) throws -> Data {
            let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
            guard let url = bundle.url(forResource: parts[0], withExtension: parts[1],
                                       subdirectory: folder) else { throw Missing(name: name) }
            return try Data(contentsOf: url)
        }
        let provenance = try JSONDecoder().decode(Provenance.self, from: data("provenance.json"))
        let files = try ["main.nux", "sheets.nux"].map { name in
            NuxieMachineSourceFile(path: name, text: String(decoding: try data(name), as: UTF8.self))
        }
        return NuxieMachinePlanSource(files: files, assets: try NuxieMachineFolder(named: folder, in: bundle).assets(),
                                      root: provenance.plan.root, app: provenance.plan.app,
                                      experience: provenance.plan.experience, version: provenance.plan.version)
    }
}

/// The `views-scroll` paywall as the staged host app bundles it under
/// `views-scroll/`, changed in memory into a page that scrolls on a sheet.
/// The bundled files are not touched. As bundled, the paywall is a cover
/// whose page is a `scroll` filling it. Here:
///
/// - its route presents a sheet;
/// - the page is a `stack` the size of the sheet. Its first layer is a
///   `column` that holds a header 120 points tall, with the app's name,
///   and the same `scroll` below it, taking the rest (`flex=1`); everything
///   inside the `scroll` is as bundled, indented two steps. A drag that
///   starts on the header starts outside the `scroll`;
/// - its second layer is a button floating over the page, pinned near its
///   bottom right, that presses the paywall's `restore`. A drag that starts
///   on it starts over the `scroll`, though not inside it.
///
/// The rows of the folder's other files are as bundled.
enum NuxieMachineScrollSheetFixture {
    /// The folder in the app bundle.
    static let folder = "views-scroll"

    struct Missing: Error, CustomStringConvertible {
        let what: String
        var description: String { "views-scroll: \(what)" }
    }

    static let coverRoute = "    paywall  Paywall cover\n"
    static let sheetRoute = "    paywall  Paywall sheet\n"
    static let page = "    scroll width=100% height=100% background-color=night id=\"page\""

    static func load(from bundle: Bundle) throws -> NuxieMachinePlanSource {
        func text(_ name: String) throws -> String {
            guard let url = bundle.url(forResource: name, withExtension: "nux", subdirectory: folder)
            else { throw Missing(what: "\(name).nux is not in the app bundle") }
            return String(decoding: try Data(contentsOf: url), as: UTF8.self)
        }
        let main = try text("main")
        guard main.components(separatedBy: coverRoute).count == 2 else {
            throw Missing(what: "main.nux does not have the paywall's route exactly once")
        }
        var lines = try text("paywall").components(separatedBy: "\n")
        guard let at = lines.firstIndex(of: page) else { throw Missing(what: "the paywall's page is not a scroll") }
        guard let end = lines.firstIndex(of: "component Reminder"),
              let last = lines[..<end].lastIndex(where: { !$0.isEmpty }), last > at
        else { throw Missing(what: "the paywall's Reminder does not follow its page") }
        for index in (at + 1)...last where !lines[index].isEmpty {
            lines[index] = "    " + lines[index]
        }
        lines.insert(contentsOf: [
            "      button height=52 padding=\"0 24\" right=24 bottom=48 border-radius=26 background-color=panel"
                + " border-width=1 border-color=edge align-items=center justify-content=center press=restore"
                + " id=\"floating\"",
            "        text \"Restore\" class=RemindLabel",
        ], at: last + 1)
        lines.replaceSubrange(at...at, with: [
            "    stack width=100% height=100% background-color=night id=\"layers\"",
            "      column width=100% height=100% id=\"frame\"",
            "        column height=120 padding=\"0 24\" justify-content=center id=\"header\"",
            "          text \"Quietly\" color=ink font-size=1.25rem font-weight=700 id=\"heading\"",
            "        scroll width=100% flex=1 id=\"page\"",
        ])
        return NuxieMachinePlanSource(
            files: [NuxieMachineSourceFile(path: "main.nux", text: main.replacingOccurrences(of: coverRoute,
                                                                                            with: sheetRoute)),
                    NuxieMachineSourceFile(path: "paywall.nux", text: lines.joined(separator: "\n")),
                    NuxieMachineSourceFile(path: "plan-card.nux", text: try text("plan-card"))],
            assets: try NuxieMachineFolder(named: folder, in: bundle).assets(), root: "main", app: "app",
            experience: "quietly", version: 1)
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
/// `none`. `nuxie-machine-environments` is labeled the same way with every
/// environment the session took, `light 17.0` or `dark 23.0` each, and
/// `nuxie-machine-presences` with every presence, `here` or `away`. All are
/// read four times a second, so a UI test can tell a frame the app drew
/// wrong from a screenshot taken wrong, and see each place and environment
/// told.
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
        private let environmentsLabel = UILabel()
        private let presencesLabel = UILabel()
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
            environmentsLabel.textColor = .clear
            environmentsLabel.font = .systemFont(ofSize: 1)
            environmentsLabel.frame = CGRect(x: 3, y: 0, width: 1, height: 1)
            environmentsLabel.isAccessibilityElement = true
            environmentsLabel.accessibilityIdentifier = "nuxie-machine-environments"
            environmentsLabel.accessibilityLabel = "none"
            view.addSubview(environmentsLabel)
            presencesLabel.textColor = .clear
            presencesLabel.font = .systemFont(ofSize: 1)
            presencesLabel.frame = CGRect(x: 4, y: 0, width: 1, height: 1)
            presencesLabel.isAccessibilityElement = true
            presencesLabel.accessibilityIdentifier = "nuxie-machine-presences"
            presencesLabel.accessibilityLabel = "none"
            view.addSubview(presencesLabel)
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

        /// Every place, environment and presence the session took, from
        /// the edge's log. Kept as they were once the edge is let go of.
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
                let environments = log.compactMap { entry -> String? in
                    guard case .environment(let environment) = entry else { return nil }
                    return "\(environment.dark ? "dark" : "light") \(environment.textSize)"
                }
                self?.environmentsLabel.accessibilityLabel = environments.isEmpty
                    ? "none" : environments.joined(separator: "; ")
                let presences = log.compactMap { entry -> String? in
                    guard case .presence(let here) = entry else { return nil }
                    return here ? "here" : "away"
                }
                self?.presencesLabel.accessibilityLabel = presences.isEmpty ? "none" : presences.joined(separator: "; ")
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
