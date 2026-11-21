#if os(iOS) && !targetEnvironment(macCatalyst)
import UIKit
import XCTest
import NuxieMachine

/// What a sheet presenter owns really goes, on a simulator with no window:
/// a real presenter over Stillwater's Screen and the engine. The host is a
/// view controller in no window, so a sheet can never be presented, which
/// is enough for the two ends a presenter has with no sheet: a record that
/// faulted (let go of), and a record waiting for its wake (kept, until the
/// presenter itself is freed).
///
/// The store is an object the checks hold weakly: the edge holds it, the
/// Screen's view controller holds the edge, and the edge holds the session,
/// so the store freed means the edge, the session and the Screen are gone.
final class NuxieMachineSheetPresenterTests: XCTestCase {
    /// A plan whose start asks for a wake at the next 18:00 and presents
    /// nothing, as Stillwater's record does after "Not now".
    private static let waitsForTheEvening = """
        component App
          state due = false
          entry
            on event "go"
            do arm
          action arm
            due = true
          wait later
            while due
            until next 18:00
            then fire within 6h
            else exit
          action fire
            due = false

        """

    /// Stillwater's start presents the paywall, and the host cannot present
    /// it: the record faults with no sheet, and the presenter lets go of
    /// the Screen, its edge and session once the lane drains. The host's two
    /// lines still say what happened.
    @MainActor
    func testAFaultWithNoSheetLetsGoOfTheScreenItsEdgeAndSession() async throws {
        let fixture = try Fixture.load()
        let host = UIViewController()
        let lines = HostLines()
        let presenter = NuxieMachineSheetPresenter(host: host) { lines.status = $0 }
        weak var edgeStore: ProbeStore?
        do {
            let store = ProbeStore()
            edgeStore = store
            await presenter.start(plan: fixture.plan, screen: fixture.screen, store: store,
                                  event: "onboarding_completed")
        }

        XCTAssertEqual(presenter.status.record, .fault("edge.no-host"))
        try await waitUntil("the edge is freed") { edgeStore == nil }
        XCTAssertNil(presenter.scheduledWake)
        XCTAssertEqual(presenter.status.record, .fault("edge.no-host"))
        XCTAssertEqual(lines.status, presenter.status, "the host was told the last status")
        withExtendedLifetime(host) {}
    }

    /// A record waiting for its wake with no sheet keeps everything: the
    /// timer is set and the edge stays. Freed while it waits, the presenter
    /// leaves nothing behind: the timer is cancelled, and the Screen, its
    /// edge and session go.
    @MainActor
    func testAPresenterFreedWhileItsRecordWaitsLeavesNothingScheduled() async throws {
        let fixture = try Fixture.load()
        let plan = NuxieMachinePlanSource(
            files: [NuxieMachineSourceFile(path: "main.nux", text: Self.waitsForTheEvening)],
            root: "main", app: "app", experience: "evening", version: 1)
        let host = UIViewController()
        var presenter: NuxieMachineSheetPresenter? = NuxieMachineSheetPresenter(host: host) { _ in }
        weak let heldPresenter = presenter
        weak var edgeStore: ProbeStore?
        do {
            let store = ProbeStore()
            edgeStore = store
            await presenter?.start(plan: plan, screen: fixture.screen, store: store, event: "go")
        }

        let status = try XCTUnwrap(presenter?.status)
        guard case .open(let moment?) = status.record else { return XCTFail("\(status)") }
        XCTAssertGreaterThan(Double(moment) / 1000, Date().timeIntervalSince1970, "the wake is still to come")
        let wake = try XCTUnwrap(presenter?.scheduledWake)
        // Frames run meanwhile; the open record's edge stays.
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(wake.isCancelled)
        XCTAssertNotNil(edgeStore, "an open record's edge was let go of")

        presenter = nil
        try await waitUntil("the presenter is freed") { heldPresenter == nil }
        XCTAssertTrue(wake.isCancelled, "the wake timer outlived its presenter")
        try await waitUntil("the edge is freed") { edgeStore == nil }
        withExtendedLifetime(host) {}
    }

    // MARK: Each presentation laid out as its own style

    /// A sheet and a cover are each a controller of their own, laid out and
    /// set up as their style.
    @MainActor
    func testASheetAndACoverAreEachLaidOutAsTheirOwnStyle() throws {
        let loop = try Self.loop()
        for presentation in [NuxieMachinePresentation.sheet, .cover] {
            let (controller, window) = Self.screen(presenting: presentation, loop: loop)
            try Self.expect(controller, laidOutAs: presentation)
            withExtendedLifetime(window) {}
        }
    }

    /// A loop over an edge whose session presents nothing.
    @MainActor
    private static func loop(
        plan: NuxieMachinePlanSource = NuxieMachinePlanSource(
            files: [NuxieMachineSourceFile(path: "main.nux", text: waitsForTheEvening)],
            root: "main", app: "app", experience: "evening", version: 1)
    ) throws -> NuxieMachineScreenLoop {
        let edge = try NuxieMachineEdge(plan: plan, store: NuxieMachineStandInStore(), onReport: { _ in })
        return NuxieMachineScreenLoop(edge: edge)
    }

    /// A Screen for one presentation, the root of a window at a phone's
    /// size. Its safe areas are the device's, with a status bar's and a home
    /// indicator's added, so both edges have one.
    @MainActor
    private static func screen(
        presenting presentation: NuxieMachinePresentation, loop: NuxieMachineScreenLoop,
        shown: NuxieMachineShown = NuxieMachineShown(journey: 1, instance: 1), route: String = "screen"
    ) -> (NuxieMachineScreenViewController, UIWindow) {
        let presented = NuxieMachinePresented(shown: shown, route: route, presentation: presentation)
        let controller = NuxieMachineScreenViewController(presenting: presented, loop: loop)
        controller.additionalSafeAreaInsets = UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.isHidden = false
        return (controller, window)
    }

    /// A compiled Screen presented, dismissed and presented again at the
    /// same size: each presentation is a new controller over a new player,
    /// and each is laid out at its surface's size, not at the size it opened
    /// with. The first player is freed before the second opens, so the
    /// second can take its address; nothing of the first presentation may
    /// decide how the second is sized.
    @MainActor
    func testACompiledScreenPresentedAgainAtTheSameSizeIsSizedToItsSurface() async throws {
        let loop = try Self.loop(plan: Self.presentsTwice)
        let edge = loop.edge
        let hour: Int64 = 3_600_000
        await loop.inLane { await edge.start(event: "opened", now: 9 * hour) }
        let firstStack = await edge.stack
        let firstShown = try XCTUnwrap(firstStack.last)
        let (controller, window) = Self.screen(presenting: .cover, loop: loop, shown: firstShown.shown,
                                               route: firstShown.route)
        loop.screens = [controller]
        loop.start()
        let surface = try XCTUnwrap(controller.view.subviews.first, "the Screen's surface")
        window.layoutIfNeeded()
        let expected = surface.bounds.size
        let first = try await Self.laidOut(edge, at: expected, "the first presentation", first: nil)

        // The noon wake dismisses the Screen; the evening's presents it again.
        await loop.inLane { await edge.wake(now: 12 * hour) }
        let between = await edge.screen()
        XCTAssertNil(between, "the dismiss freed the first player")
        loop.screens = []
        await loop.inLane { await edge.wake(now: 18 * hour) }
        let secondStack = await edge.stack
        let secondShown = try XCTUnwrap(secondStack.last)
        XCTAssertNotEqual(secondShown.shown, firstShown.shown, "presented again is a new presentation")
        let again = NuxieMachineScreenViewController(presenting: secondShown, loop: loop)
        again.additionalSafeAreaInsets = controller.additionalSafeAreaInsets
        window.rootViewController = again
        loop.screens = [again]
        _ = try await Self.laidOut(edge, at: expected, "the second presentation", first: first)
        loop.stop()
        withExtendedLifetime(window) {}
    }

    /// A record that presents its Screen as a cover, dismisses it at noon
    /// and presents it again in the evening, with no touch.
    private static let presentsTwice = NuxieMachinePlanSource(
        files: [
            NuxieMachineSourceFile(path: "main.nux", text: """
                use Clock from "clock"

                component Again
                  platforms ios android

                  state first_up = false
                  state later = false

                  entry
                    on event "opened"
                    do start

                  routes
                    clock  Clock(close=close)  cover

                  action start
                    first_up = true
                    go(clock)

                  wait noon
                    while first_up
                    until next 12:00
                    then hide within 6h
                    else give_up

                  action hide
                    first_up = false
                    later = true
                    dismiss("hidden")

                  wait evening
                    while later
                    until next 18:00
                    then show_again within 6h
                    else give_up

                  action show_again
                    later = false
                    go(clock)

                  action give_up
                    first_up = false
                    later = false
                    exit

                  action close
                    dismiss("closed")
                    exit

                """),
            NuxieMachineSourceFile(path: "clock.nux", text: """
                component Clock
                  props
                    close: action

                  view
                    column padding=24 gap=12 background-color=#0d1214
                      text "The same Screen, again." color=#eef3f1 font-size=24 id="line"
                      button padding=12 press=close id="close"
                        text "Close" color=#8a9794 font-size=16

                """),
        ],
        root: "main", app: "app", experience: "again", version: 1)

    /// Wait until the presented Screen is laid out at `expected`, as the
    /// Screen's frames lay it out, and give its address. Only the address is
    /// kept, so the check holds no player alive; `first` is the first
    /// presentation's, to say whether the second took it.
    @MainActor
    private static func laidOut(_ edge: NuxieMachineEdge, at expected: CGSize, _ what: String,
                                first: ObjectIdentifier?) async throws -> ObjectIdentifier {
        let deadline = Date().addingTimeInterval(10)
        var seen: CGSize?
        var address: ObjectIdentifier?
        while Date() < deadline {
            if let screen = await edge.screen() {
                address = ObjectIdentifier(screen)
                let size = try await screen.layoutSize()
                seen = size
                if abs(size.width - expected.width) < 1, abs(size.height - expected.height) < 1 {
                    return ObjectIdentifier(screen)
                }
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let reused = first.map { $0 == address } ?? false
        let took = first == nil ? "" : "; it took the first player's address: \(reused)"
        XCTFail("\(what) was laid out at \(String(describing: seen)), not its surface's \(expected)\(took)")
        throw NotLaidOut()
    }

    private struct NotLaidOut: Error {}

    /// Lay out `controller`, made for `presentation`, and check it:
    /// a cover draws inside the safe area over a black ground, full screen,
    /// with no swipe; a sheet draws across its whole view over no ground, as
    /// a page sheet at the large detent with no grabber, which the person
    /// can swipe down.
    @MainActor
    private static func expect(_ controller: NuxieMachineScreenViewController,
                               laidOutAs presentation: NuxieMachinePresentation) throws {
        let view = try XCTUnwrap(controller.view)
        let window = try XCTUnwrap(view.window, "the Screen is in its window")
        view.setNeedsLayout()
        window.layoutIfNeeded()
        let insets = view.safeAreaInsets
        XCTAssertGreaterThan(insets.top, 0, "the window's safe area reached the view")
        XCTAssertGreaterThan(insets.bottom, 0, "the window's safe area reached the view")
        let surface = try XCTUnwrap(view.subviews.first, "the Screen's surface")
        switch presentation {
        case .cover:
            XCTAssertEqual(surface.frame, view.bounds.inset(by: insets), "a cover draws inside the safe area")
            XCTAssertEqual(view.backgroundColor, .black)
            XCTAssertEqual(controller.modalPresentationStyle, .fullScreen)
            XCTAssertTrue(controller.isModalInPresentation, "a cover has no swipe")
        default:
            XCTAssertEqual(surface.frame, view.bounds, "a sheet draws across its whole view")
            XCTAssertEqual(view.backgroundColor, .clear)
            XCTAssertEqual(controller.modalPresentationStyle, .pageSheet)
            XCTAssertFalse(controller.isModalInPresentation, "the person can swipe a sheet down")
            let sheet = try XCTUnwrap(controller.sheetPresentationController)
            if #available(iOS 16.0, *) {
                XCTAssertEqual(sheet.detents.map(\.identifier), [.large])
            }
            XCTAssertFalse(sheet.prefersGrabberVisible)
        }
    }

    @MainActor
    private func waitUntil(_ what: String, seconds: Double = 10, _ done: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !done() {
            guard Date() < deadline else { return XCTFail("timed out waiting until \(what)") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

/// The host's two lines: the status it was last told.
@MainActor
private final class HostLines {
    var status: NuxieMachineSheetStatus?
}

/// The stand-in store as an object, so a check can see when the edge that
/// holds it is freed.
private final class ProbeStore: NuxieMachineStore {
    private let standIn = NuxieMachineStandInStore()

    func perform(_ call: NuxieMachineCall) async throws -> String {
        try await standIn.perform(call)
    }
}
#endif
