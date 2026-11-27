#if os(iOS) && !targetEnvironment(macCatalyst)
import UIKit
import XCTest
import NuxieMachine
import NuxieRuntime

/// A presenter whose page waits for its picture, on a simulator: a real
/// presenter over `Fixtures/views-picture` and the engine, presenting from a
/// host that is the root of a window at a phone's size, with a byte source
/// the test answers or fails path by path.
///
/// What the person sees is the SDK's own loading and recovery screens over
/// the page's Screen, and the oracle for their order, timing and words is
/// the SDK's experience screen, whose tests say the same of the same views
/// (`ExperienceShellPresentationChromeTests`): the shimmer with no close
/// while loading, the recovery screen and the close together, Try Again
/// back to the shimmer with the close hidden, and the copy by reason. The
/// close's fault is the one `nux_machine_host_fault`'s header text gives.
///
/// The window has no scene, so no frame of the page is ever drawn in it:
/// the loading screen stays up once the files are in, as it does on a
/// phone until the first frame is drawn under it.
final class AssetWaitPresenterTests: XCTestCase {
    private static let hero = "assets/hero.png"

    /// A sheet waiting for its picture: the native sheet is up at once with
    /// the loading screen and the shimmer, and no close; it cannot be swiped
    /// away. Once the picture is in, the loading screen stays until the
    /// first frame is drawn under it, with still no close.
    @MainActor
    func testASheetWaitingForItsPictureShowsTheLoadingScreenAtOnce() async throws {
        try await expectLoadingAtOnce(sheet: true)
    }

    /// The same for a cover.
    @MainActor
    func testACoverWaitingForItsPictureShowsTheLoadingScreenAtOnce() async throws {
        try await expectLoadingAtOnce(sheet: false)
    }

    @MainActor
    private func expectLoadingAtOnce(sheet: Bool) async throws {
        let run = try await Run.presenting(sheet: sheet, delay: 5)
        defer { run.finish() }
        let screen = run.screen
        XCTAssertEqual(screen.navigationController?.modalPresentationStyle, sheet ? .pageSheet : .fullScreen)
        try Self.expectLoading(screen, "while the picture is coming")
        XCTAssertEqual(screen.framesDrawn, 0)

        try await run.bytes.untilAsked(Self.hero)
        try await run.bytes.answer(Self.hero)
        try await waitUntil("the Screen is told the picture is in") { screen.assets == .ready }
        try Self.expectLoading(screen, "once the picture is in, with no frame drawn", filesIn: true)
    }

    /// With the delay at 0, the recovery screen and the close show in place
    /// of the shimmer while the picture is still coming, in the neutral
    /// words: nothing has failed.
    @MainActor
    func testTheRecoveryScreenAndTheCloseShowOnceTheDelayHasPassed() async throws {
        let run = try await Run.presenting(sheet: true, delay: 0)
        defer { run.finish() }
        try await waitUntil("the recovery screen shows") { try !Self.recovery(run.screen).isHidden }
        try Self.expectRecovery(run.screen, ["Something Went Wrong", "There was a problem loading this content."],
                                "after the delay")
    }

    /// A file that fails shows the recovery screen and the close at once,
    /// well before the five seconds: "No Connection" when it failed
    /// offline, "Something Went Wrong" for any other reason.
    @MainActor
    func testAFailedFileShowsTheRecoveryScreenAtOnceInItsReasonsWords() async throws {
        let cases: [(error: any Error, words: [String])] = [
            (offlineError, ["No Connection", "Reconnect to the internet and try again."]),
            (NuxieMachineByteSourceFault.noFile(Self.hero),
             ["Something Went Wrong", "There was a problem loading this content."]),
        ]
        for (error, words) in cases {
            let run = try await Run.presenting(sheet: true, delay: 5)
            defer { run.finish() }
            try await run.bytes.untilAsked(Self.hero)
            run.bytes.fail(Self.hero, with: error)
            try await waitUntil("the recovery screen shows", seconds: 2) { try !Self.recovery(run.screen).isHidden }
            try Self.expectRecovery(run.screen, words, "after \(error)")
        }
    }

    /// Try Again asks the source again for the failed file, and only it;
    /// the shimmer is back at once with the close hidden; the answer brings
    /// the files in.
    @MainActor
    func testTryAgainAsksOnlyForTheFailedFileAndShowsTheLoadingScreen() async throws {
        let run = try await Run.presenting(sheet: true, delay: 5)
        defer { run.finish() }
        try await run.bytes.untilAsked(Self.hero)
        run.bytes.fail(Self.hero, with: offlineError)
        try await waitUntil("the recovery screen shows") { try !Self.recovery(run.screen).isHidden }

        try Self.recovery(run.screen).primaryActionButton.sendActions(for: .touchUpInside)
        try Self.expectLoading(run.screen, "right after Try Again")
        try await run.bytes.untilAsked(Self.hero, times: 2)
        XCTAssertEqual(run.bytes.asked, [Self.hero, Self.hero])
        try await run.bytes.answer(Self.hero)
        try await waitUntil("the Screen is told the picture is in") { run.screen.assets == .ready }
        try Self.expectLoading(run.screen, "once the picture is in")
    }

    /// Try Again while still offline: the source fails again, and the
    /// recovery screen shows once more, in the same sheet. There is one
    /// recovery screen in it and one native presentation, never a second.
    @MainActor
    func testTryAgainStillOfflineShowsTheRecoveryScreenOnceMore() async throws {
        let run = try await Run.presenting(sheet: true, delay: 5)
        defer { run.finish() }
        try await run.bytes.untilAsked(Self.hero)
        run.bytes.fail(Self.hero, with: offlineError)
        try await waitUntil("the recovery screen shows") { try !Self.recovery(run.screen).isHidden }

        try Self.recovery(run.screen).primaryActionButton.sendActions(for: .touchUpInside)
        try await run.bytes.untilAsked(Self.hero, times: 2)
        run.bytes.fail(Self.hero, with: offlineError)
        try await waitUntil("the recovery screen shows again") { try !Self.recovery(run.screen).isHidden }
        try Self.expectRecovery(run.screen, ["No Connection", "Reconnect to the internet and try again."],
                                "after the second failure")
        XCTAssertEqual(Self.views("nuxie-experience-recovery-shell", in: run.screen.view).count, 1,
                       "a second recovery screen was stacked")
        XCTAssertTrue(run.host.presentedViewController === run.screen.navigationController,
                      "the sheet is not the one presented")
        XCTAssertNil(run.screen.navigationController?.presentedViewController, "something was presented over the sheet")
    }

    /// A tap on the close reaches the edge, and the record ends in the
    /// host's fault `first_frame.deadline`, as the presenter's status says.
    /// That is all this runner can show: it never finishes UIKit's animated
    /// present, and the presenter dismisses nothing until a transition is
    /// over. The sheet going and the app back on its own screen are proved
    /// in the runtime host app, by `GalleryWaitSheetUITests`.
    @MainActor
    func testATapOnTheCloseEndsTheRecordInTheFirstFrameDeadline() async throws {
        let (host, window) = Self.host()
        let presenter = NuxieMachineSheetPresenter(host: host) { _ in }
        let bytes = AskedBytes(folder: try PictureFolder.url())
        await presenter.start(plan: try PictureFolder.plan(main: PictureFolder.asASheet()),
                              store: NuxieMachineStandInStore(), bytes: bytes, event: "opened")
        let screen = try await Self.presented(on: host)
        try await bytes.untilAsked(Self.hero)
        bytes.fail(Self.hero, with: offlineError)
        try await waitUntil("the recovery screen shows") { try !Self.recovery(screen).isHidden }
        XCTAssertEqual(presenter.status.record, .open(wakeAt: nil))

        let close = try XCTUnwrap(Self.views("nuxie-experience-close", in: screen.view).first as? UIControl)
        XCTAssertFalse(close.isHidden, "the close is hidden on the recovery screen")
        close.sendActions(for: .touchUpInside)
        try await waitUntil("the record ends in the fault") {
            presenter.status.record == .fault("first_frame.deadline")
        }
        bytes.dropAll()
        withExtendedLifetime(window) {}
    }

    // MARK: Looking at a Screen

    /// The loading view and its shimmer up, the recovery screen and the
    /// close hidden; and no swipe until the files are in. Once they are,
    /// the loading view stays until the first frame, but the page no
    /// longer holds its segment: only the route's own swipe decides.
    @MainActor
    private static func expectLoading(_ screen: NuxieMachineScreenViewController, _ when: String,
                                      filesIn: Bool = false) throws {
        let loading = try one("nuxie-experience-loading-shell", in: screen)
        let shimmer = try XCTUnwrap(one("nuxie-experience-shimmer", in: screen) as? ExperienceShellShimmerView)
        XCTAssertFalse(loading.isHidden, "the loading screen is hidden \(when)")
        XCTAssertEqual(loading.accessibilityLabel, "Experience loading")
        XCTAssertTrue(shimmer.isAnimating || UIAccessibility.isReduceMotionEnabled, "the shimmer is still \(when)")
        XCTAssertTrue(try recovery(screen).isHidden, "the recovery screen shows \(when)")
        XCTAssertTrue(try one("nuxie-experience-close", in: screen).isHidden, "the close shows \(when)")
        let segment = try XCTUnwrap(screen.navigationController as? NuxieMachineSegmentController)
        XCTAssertEqual(screen.waitsForFiles, !filesIn, when)
        XCTAssertEqual(segment.modalReasons.contains(.loading), !filesIn, "the loading hold \(when)")
        if !filesIn {
            XCTAssertTrue(segment.isModalInPresentation, "the page can be swiped away \(when)")
        }
    }

    /// The recovery screen in `words`, with the close over it, the loading
    /// view hidden, and no swipe.
    @MainActor
    private static func expectRecovery(_ screen: NuxieMachineScreenViewController, _ words: [String],
                                       _ when: String) throws {
        let shown = try recovery(screen)
        XCTAssertFalse(shown.isHidden, "the recovery screen is hidden \(when)")
        for line in words {
            XCTAssertTrue(shown.visibleTextLabels.contains(line), "\"\(line)\" is not shown \(when): "
                          + "\(shown.visibleTextLabels)")
        }
        XCTAssertEqual(shown.primaryActionButton.titleLabelForTesting.text, "Try Again",
                       "Try Again is not offered \(when)")
        let close = try one("nuxie-experience-close", in: screen)
        XCTAssertFalse(close.isHidden, "the close is hidden \(when)")
        XCTAssertEqual(close.accessibilityLabel, "Close")
        XCTAssertTrue(try one("nuxie-experience-loading-shell", in: screen).isHidden,
                      "the loading screen shows under the recovery screen \(when)")
        XCTAssertEqual(screen.navigationController?.isModalInPresentation, true, "the page can be swiped away \(when)")
    }

    @MainActor
    private static func recovery(_ screen: NuxieMachineScreenViewController) throws -> ExperienceShellRecoveryView {
        try XCTUnwrap(one("nuxie-experience-recovery-shell", in: screen) as? ExperienceShellRecoveryView)
    }

    /// The one view in `screen` with the identifier `id`.
    @MainActor
    private static func one(_ id: String, in screen: NuxieMachineScreenViewController) throws -> UIView {
        let found = views(id, in: screen.view)
        XCTAssertEqual(found.count, 1, "\(found.count) views are \(id)")
        return try XCTUnwrap(found.first, "no view is \(id)")
    }

    @MainActor
    static func views(_ id: String, in view: UIView) -> [UIView] {
        (view.accessibilityIdentifier == id ? [view] : []) + view.subviews.flatMap { views(id, in: $0) }
    }

    // MARK: A presenter

    /// A host view controller, the root of a window at a phone's size.
    @MainActor
    static func host() -> (UIViewController, UIWindow) {
        let host = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.isHidden = false
        window.layoutIfNeeded()
        return (host, window)
    }

    /// The Screen the presenter presented from `host`, once UIKit has it:
    /// the page on top of the segment presented.
    @MainActor
    static func presented(on host: UIViewController) async throws -> NuxieMachineScreenViewController {
        func page() -> NuxieMachineScreenViewController? {
            (host.presentedViewController as? NuxieMachineSegmentController)?.topViewController
                as? NuxieMachineScreenViewController
        }
        try await waitUntil("the page is presented", seconds: 2) { page() != nil }
        return try XCTUnwrap(page())
    }

    /// A presenter started over the picture page, presented as a sheet or a
    /// cover, with a byte source the test answers, and its Screen.
    @MainActor
    private final class Run {
        let presenter: NuxieMachineSheetPresenter
        let host: UIViewController
        let window: UIWindow
        let bytes: AskedBytes
        let screen: NuxieMachineScreenViewController

        private init(presenter: NuxieMachineSheetPresenter, host: UIViewController, window: UIWindow,
                     bytes: AskedBytes, screen: NuxieMachineScreenViewController) {
            self.presenter = presenter
            self.host = host
            self.window = window
            self.bytes = bytes
            self.screen = screen
        }

        static func presenting(sheet: Bool, delay: TimeInterval) async throws -> Run {
            let main = try sheet ? PictureFolder.asASheet() : PictureFolder.main()
            let (host, window) = AssetWaitPresenterTests.host()
            let presenter = NuxieMachineSheetPresenter(host: host) { _ in }
            presenter.recoveryAffordanceDelay = delay
            let bytes = AskedBytes(folder: try PictureFolder.url())
            await presenter.start(plan: try PictureFolder.plan(main: main), store: NuxieMachineStandInStore(),
                                  bytes: bytes, event: "opened")
            let screen = try await AssetWaitPresenterTests.presented(on: host)
            return Run(presenter: presenter, host: host, window: window, bytes: bytes, screen: screen)
        }

        /// Let every ask still waiting go, and the window with it.
        func finish() {
            bytes.dropAll()
            window.isHidden = true
        }
    }
}

/// Wait, a little at a time, until `done`, or fail the test after `seconds`.
@MainActor
private func waitUntil(_ what: String, seconds: Double = 10, file: StaticString = #filePath, line: UInt = #line,
                       _ done: () throws -> Bool) async throws {
    let deadline = Date().addingTimeInterval(seconds)
    while try !done() {
        guard Date() < deadline else { return XCTFail("timed out waiting until \(what)", file: file, line: line) }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
}
#endif
