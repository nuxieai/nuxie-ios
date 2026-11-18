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
