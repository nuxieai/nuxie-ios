#if os(iOS) && !targetEnvironment(macCatalyst)
import XCTest
import NuxieMachine
import NuxieRuntime

/// One delivery whose rows begin a presentation and end it, or end one and
/// begin another. A delivery's rows are a log of what the machine did in
/// it, and the record's presented stack is where the last row left it, so
/// the edge opens nothing from the rows: when the delivery is over it shows
/// what the stack holds. A presentation begun and ended in one delivery is
/// never opened and never reaches the screen, and one that outlives the
/// delivery is opened once. Every case draws the plan's compiled views.
///
/// A start the machine says did not happen is one delivery too: with
/// nothing wrong it is no fault, nothing is opened, and the edge goes on;
/// with something wrong it is still a fault.
final class OneDeliveryEdgeTests: XCTestCase {
    private static let hour: Int64 = 3_600_000

    // MARK: Begun and ended in one delivery

    /// A start whose step presents a page and dismisses it changed
    /// nothing, so the machine answers that it did not happen (`unstarted`):
    /// no fault, no record, and the edge goes on.
    func testAScreenPresentedAndDismissedInOneDeliveryIsNeverOpened() async throws {
        let run = try OneDelivery(compiled: Self.compiled(["go(clock)", "dismiss(\"gone\")"]))
        await run.edge.start(event: "opened", now: run.now)
        try await expectNotStarted(run, on: "opened", reason: "unstarted")
        try await run.edge.close()
    }

    /// A start whose step presents a page and exits changed nothing either:
    /// it did not happen (`unstarted`), with no fault and no record.
    func testAScreenPresentedThenExitedInOneDeliveryIsNeverOpened() async throws {
        let run = try OneDelivery(compiled: Self.compiled(["go(clock)", "exit"]))
        await run.edge.start(event: "opened", now: run.now)
        try await expectNotStarted(run, on: "opened", reason: "unstarted")
        try await run.edge.close()
    }

    /// A start whose step presents a page and goes back changed nothing
    /// either: it did not happen (`unstarted`), with no fault and no record.
    func testAScreenPresentedThenPoppedInOneDeliveryIsNeverOpened() async throws {
        let run = try OneDelivery(compiled: Self.compiled(["go(clock)", "back"]))
        await run.edge.start(event: "opened", now: run.now)
        try await expectNotStarted(run, on: "opened", reason: "unstarted")
        try await run.edge.close()
    }

    // MARK: A start that did not happen

    /// A start on an event no entry starts on did not happen, and nothing
    /// is wrong: no fault and no reason, and the edge goes on, so a later
    /// start on the entry's own event is delivered and opens its page.
    func testAStartOnAnEventNoEntryStartsOnIsQuietAndTheEdgeGoesOn() async throws {
        let run = try OneDelivery(compiled: Self.compiled(["go(clock)"]))
        await run.edge.start(event: "nope", now: run.now)
        try await expectNotStarted(run, on: "nope", reason: nil)

        let heard = run.owner.reports.count
        await run.edge.start(event: "opened", now: run.now + 2)
        let fault = await run.edge.fault
        XCTAssertNil(fault, "the start on the entry's own event faulted")
        let stack = await run.edge.stack
        XCTAssertEqual(stack.map(\.route), ["clock"], "the start on the entry's own event opened nothing")
        let reports = Array(run.owner.reports.dropFirst(heard))
        guard reports.count == 1, case .delivered(let shown, _) = reports[0] else {
            return XCTFail("one report for the start: \(reports)")
        }
        XCTAssertEqual(shown, stack)
        try await run.edge.close()
    }

    /// Stillwater's entry is `once`. A second start on its event while the
    /// paywall is up did not happen (`once`), and nothing is wrong: the
    /// owner hears that and nothing else, nothing is applied, and the open
    /// record keeps what it shows and the player it draws with.
    func testASecondStartOnAOnceEntryIsQuietAndLeavesTheOpenRecordAsItWas() async throws {
        let run = try OneDelivery(compiled: Fixture.load())
        await run.edge.start(event: "onboarding_completed", now: run.now)
        let stack = await run.edge.stack
        XCTAssertEqual(stack.map(\.route), ["paywall"], "the first start presents the paywall")
        let firstScreen = await run.edge.screen()
        let player = try XCTUnwrap(firstScreen, "the first start opens a player")
        let heard = run.owner.reports.count
        let written = await run.edge.log.count

        await run.edge.start(event: "onboarding_completed", now: run.now + 1000)
        let fault = await run.edge.fault
        XCTAssertNil(fault, "a second start on a `once` entry faulted")
        XCTAssertEqual(Array(run.owner.reports.dropFirst(heard)), [.notStarted(reason: "once")])
        let after = await Array(run.edge.log.dropFirst(written))
        XCTAssertEqual(after, [], "the start that did not happen applied \(after)")
        let still = await run.edge.stack
        XCTAssertEqual(still, stack, "the open record's stack moved")
        let screen = await run.edge.screen()
        XCTAssertTrue(screen === player, "the open record's page lost its player")
        let open = try await run.edge.recordOpen()
        XCTAssertTrue(open, "the open record was closed")
        try await run.edge.close()
    }

    /// A start the machine declines for a reason that says something is
    /// wrong is still a fault: the event's action needs a value the start
    /// does not give (`fields`). The owner hears the fault `machine.declined`,
    /// whose detail names the reason, and the stopped edge delivers nothing
    /// for a later start.
    func testAStartDeclinedForAWrongReasonIsStillAFault() async throws {
        let run = try OneDelivery(compiled: Self.needsAValue)
        await run.edge.start(event: "signed_up", now: run.now)
        let fault = await run.edge.fault
        XCTAssertEqual(fault?.code, "machine.declined", "\(String(describing: fault))")
        XCTAssertTrue(fault?.detail.contains("fields") == true,
                      "the detail does not name the reason: \(String(describing: fault))")
        guard run.owner.reports.count == 1, case .fault(let told) = run.owner.reports[0] else {
            return XCTFail("one report, the fault: \(run.owner.reports)")
        }
        XCTAssertEqual(told, fault)
        let open = try await run.edge.recordOpen()
        XCTAssertFalse(open, "a declined start left a record")

        let written = await run.edge.log.count
        await run.edge.start(event: "signed_up", now: run.now + 1)
        let later = await Array(run.edge.log.dropFirst(written))
        XCTAssertEqual(later, [], "the stopped edge did \(later)")
        XCTAssertEqual(run.owner.reports.count, 1, "\(run.owner.reports)")
        try await run.edge.close()
    }

    // MARK: Two presentations that both outlive the delivery

    /// Two Screens presented in one delivery are both on the stack when it
    /// is over: each is opened once, bottom first, with a player of its own,
    /// and the owner is told both in one report.
    func testTwoScreensPresentedInOneDeliveryAreEachOpenedOnce() async throws {
        let run = try OneDelivery(compiled: Self.compiled(["go(clock)", "go(other)"], twoRoutes: true))
        await run.edge.start(event: "opened", now: run.now)
        let fault = await run.edge.fault
        XCTAssertNil(fault)
        let stack = await run.edge.stack
        XCTAssertEqual(stack.map(\.route), ["clock", "other"])
        let opened = await run.edge.log.filter { if case .opened = $0 { true } else { false } }
        XCTAssertEqual(opened, stack.map { .opened($0.shown) })
        let bottom = await run.edge.screen(for: stack[0].shown)
        let top = await run.edge.screen(for: stack[1].shown)
        XCTAssertNotNil(bottom)
        XCTAssertNotNil(top)
        XCTAssertFalse(bottom === top, "the two presentations share a player")
        XCTAssertEqual(run.owner.reports.count, 1, "\(run.owner.reports)")
        guard case .delivered(let shown, _)? = run.owner.reports.first else { return XCTFail("\(run.owner.reports)") }
        XCTAssertEqual(shown, stack)
        try await run.edge.close()
    }

    // MARK: One presentation replaced by another in one delivery

    /// The noon wake dismisses the Screen and presents it again: the first
    /// presentation's player is freed, and the second, a new instance, is
    /// opened once, as the session shows it. The owner hears the dismissal
    /// and what is shown now.
    func testAScreenReplacedInOneDeliveryOpensTheNewOneOnce() async throws {
        let run = try OneDelivery(compiled: Self.compiledReplacing)
        await run.edge.start(event: "opened", now: run.now)
        let firstShown = await run.edge.shown
        let first = try XCTUnwrap(firstShown, "the start presents the clock")
        let firstScreen = await run.edge.screen()
        let firstPlayer = try XCTUnwrap(firstScreen, "the start opens a player")
        let written = run.owner.reports.count

        run.jump(to: 12 * Self.hour)
        await run.edge.wake(now: run.now)
        let second = try await expectReplaced(first, in: run, since: written, as: .cover)
        let player = await run.edge.screen()
        let opened = try XCTUnwrap(player, "the new presentation has a player")
        XCTAssertFalse(opened === firstPlayer, "the new presentation opened its own player")
        let top = try await run.edge.topRoute()
        XCTAssertEqual(top?.instance, second.instance, "the player is for the instance the session presents")
        // The Screen leaving draws nothing more, so the new one never shows
        // in it; the new presentation draws its own player.
        let leaving = await run.edge.screen(for: first)
        XCTAssertNil(leaving, "the replaced presentation still draws")
        let arriving = await run.edge.screen(for: second)
        XCTAssertTrue(arriving === opened, "the new presentation draws its player")
        try await run.edge.close()
    }

    // MARK: A touch for the presentation that was replaced

    /// The noon wake replaces the Clock while the person's view still shows
    /// the first one (UIKit has not dismissed it yet), and their tap on its
    /// Close button arrives in the next frame. The tap touched the first
    /// showing, so it goes to no one: the new Clock stays presented, the
    /// owner is told nothing, and the frame still runs. The same tap on the
    /// new Clock, once it is the one shown, closes it.
    func testATapOnTheReplacedScreenGoesToNoOne() async throws {
        let run = try OneDelivery(compiled: Self.compiledReplacing)
        await run.edge.start(event: "opened", now: run.now)
        let firstShown = await run.edge.shown
        let first = try XCTUnwrap(firstShown, "the start presents the clock")
        run.jump(to: 12 * Self.hour)
        await run.edge.wake(now: run.now)
        let secondShown = await run.edge.shown
        let second = try XCTUnwrap(secondShown, "the wake presents the clock again")
        XCTAssertNotEqual(second, first)
        let screen = await run.edge.screen()
        let player = try XCTUnwrap(screen, "the new presentation has a player")
        try await player.setLayoutSize(width: 390, height: 844)
        _ = try await player.resize(pixelWidth: 780, pixelHeight: 1688)
        try await expectTapGoesOnlyToItsShowing(first: first, second: second, in: run, at: Self.clockClose)
    }

    /// Where the Clock's Close button is: below the line, inside the
    /// button's wide padding, whether the column stretches it or not.
    private static let clockClose = (x: Float(150), y: Float(200))

    // MARK: Expectations

    /// A tap at `point` that touched `first`, which a delivery has replaced
    /// with `second`, goes to no one: no fault, `second` still presented,
    /// the owner told nothing, and the pointers recorded as dropped. The
    /// same tap on `second` closes it, which ends the record.
    private func expectTapGoesOnlyToItsShowing(first: NuxieMachineShown, second: NuxieMachineShown,
                                               in run: OneDelivery, at point: (x: Float, y: Float),
                                               file: StaticString = #filePath, line: UInt = #line) async throws {
        // A frame with no pointer first, as the departing Screen animates
        // away: it lays the new Screen out, so a tap that reached it would
        // land on its controls.
        await run.edge.frame(elapsedSeconds: 1.0 / 60.0, now: run.now)
        let reports = run.owner.reports.count
        let written = await run.edge.log.count
        await run.tap(at: point, touching: first)
        var fault = await run.edge.fault
        XCTAssertNil(fault, "a dropped tap faulted", file: file, line: line)
        let still = await run.edge.shown
        XCTAssertEqual(still, second, "the tap on the replaced Screen reached the new one", file: file, line: line)
        XCTAssertEqual(Array(run.owner.reports.dropFirst(reports)), [], "the owner was told", file: file, line: line)
        let after = await Array(run.edge.log.dropFirst(written))
        XCTAssertTrue(after.contains(.droppedTouches(first)), "\(after)", file: file, line: line)

        await run.tap(at: point, touching: second)
        fault = await run.edge.fault
        XCTAssertNil(fault, "the tap on the new Screen faulted", file: file, line: line)
        let told = run.owner.reports.dropFirst(reports).flatMap { report -> [NuxieMachineHostRow] in
            if case .delivered(_, let rows) = report { return rows }
            return []
        }
        XCTAssertTrue(told.contains(.dismiss(reason: "closed")), "the new Screen took no tap: \(told)",
                      file: file, line: line)
        XCTAssertTrue(told.contains(.end(.exited)), "\(told)", file: file, line: line)
        let gone = await run.edge.shown
        XCTAssertNil(gone, file: file, line: line)
        try await run.edge.close()
    }

    /// The machine said the start on `event` did not happen, for `reason`,
    /// and nothing is wrong: the owner heard one report, that the start did
    /// not happen, and nothing about showing; no fault; no presentation was
    /// opened and none is held; and the session holds no record. The edge
    /// is not stopped: a later start on `event` is delivered, and the
    /// machine answers it the same way.
    private func expectNotStarted(_ run: OneDelivery, on event: String, reason: String?,
                                  file: StaticString = #filePath, line: UInt = #line) async throws {
        let fault = await run.edge.fault
        XCTAssertNil(fault, "a start that did not happen faulted", file: file, line: line)
        XCTAssertEqual(run.owner.reports, [.notStarted(reason: reason)], file: file, line: line)
        let shown = await run.edge.shown
        XCTAssertNil(shown, "a presentation is under way", file: file, line: line)
        let stack = await run.edge.stack
        XCTAssertEqual(stack.map(\.shown), [], "the edge holds \(stack)", file: file, line: line)
        let player = await run.edge.screen()
        XCTAssertNil(player, "a player was opened", file: file, line: line)
        let opened = await run.edge.log.filter { if case .opened = $0 { true } else { false } }
        XCTAssertEqual(opened, [], "the edge opened \(opened)", file: file, line: line)
        let open = try await run.edge.recordOpen()
        XCTAssertFalse(open, "a start that did not happen left a record", file: file, line: line)

        // The edge goes on: a later start is delivered.
        await run.edge.start(event: event, now: run.now + 1)
        XCTAssertEqual(run.owner.reports, [.notStarted(reason: reason), .notStarted(reason: reason)],
                       "the later start was not delivered", file: file, line: line)
        let still = await run.edge.fault
        XCTAssertNil(still, "the later start faulted", file: file, line: line)
    }

    /// The delivery since the owner's first `written` reports ended `first`
    /// and presented a new instance as `presentation`, with no fault: the
    /// owner heard the machine's dismissal and then the new presentation,
    /// once each.
    private func expectReplaced(_ first: NuxieMachineShown, in run: OneDelivery, since written: Int,
                                as presentation: NuxieMachinePresentation,
                                file: StaticString = #filePath, line: UInt = #line) async throws -> NuxieMachineShown {
        let fault = await run.edge.fault
        XCTAssertNil(fault, "the replacement faulted", file: file, line: line)
        let shown = await run.edge.shown
        let second = try XCTUnwrap(shown, "nothing is presented after the replacement", file: file, line: line)
        XCTAssertEqual(second.journey, first.journey, file: file, line: line)
        XCTAssertNotEqual(second.instance, first.instance, "the replacement is a new instance", file: file, line: line)
        let reports = Array(run.owner.reports.dropFirst(written))
        guard reports.count == 1, case .delivered(let shownNow, let rows) = reports[0] else {
            XCTFail("one report for the wake: \(reports)", file: file, line: line)
            return second
        }
        XCTAssertEqual(rows.filter { Self.isShowing($0) }, [.dismiss(reason: "swapped")], file: file, line: line)
        XCTAssertEqual(shownNow.map(\.shown), [second], file: file, line: line)
        XCTAssertEqual(shownNow.map(\.presentation), [presentation], file: file, line: line)
        let log = await run.edge.log
        XCTAssertEqual(log.filter { if case .opened = $0 { true } else { false } }.suffix(1), [.opened(second)],
                       file: file, line: line)
        return second
    }

    private static func isShowing(_ row: NuxieMachineHostRow) -> Bool {
        switch row {
        case .dismiss: return true
        case .wakeAt, .end, .assets: return false
        }
    }

    // MARK: Plans

    /// A root whose start runs `lines`, over a compiled Clock presented as a
    /// cover (and a second route to it, `other`, with `twoRoutes`).
    private static func compiled(_ lines: [String], twoRoutes: Bool = false) -> NuxieMachinePlanSource {
        compiledPlan(main: """
            use Clock from "clock"

            component Once
              platforms ios android

              entry
                on event "opened"
                do start

              routes
                clock  Clock(close=close)  cover
            \(twoRoutes ? "    other  Clock(close=close)  cover\n" : "")
              action start
            \(lines.map { "    " + $0 }.joined(separator: "\n"))

              action close
                dismiss("closed")
                exit

            """)
    }

    /// A root whose start presents the Clock, and whose noon wake
    /// dismisses it and presents it again in the same action.
    private static let compiledReplacing = compiledPlan(main: """
        use Clock from "clock"

        component Twice
          platforms ios android

          state up = false
          state noon = false

          entry
            on event "opened"
            do start

          routes
            clock  Clock(close=close)  cover

          action start
            up = true
            go(clock)

          task at_noon  when up
            after(next 12:00, mark_noon)

          task swap_now  when noon and here
            change(swap)

          action mark_noon
            up = false
            noon = true

          action swap
            noon = false
            dismiss("swapped")
            go(clock)

          action close
            dismiss("closed")
            exit

        """)

    /// A root that hears `signed_up`, whose action takes the event's first
    /// value. A start with no values cannot give it: declined, `fields`.
    private static let needsAValue = NuxieMachinePlanSource(
        files: [NuxieMachineSourceFile(path: "main.nux", text: """
            event client signed_up(plan: string)

            component Hears
              platforms ios android

              state chosen = ""

              on signed_up
                take

              action take(plan: string)
                chosen = plan

            """)],
        assets: [], root: "main", app: "app", experience: "hears", version: 1)

    private static func compiledPlan(main: String) -> NuxieMachinePlanSource {
        NuxieMachinePlanSource(
            files: [
                NuxieMachineSourceFile(path: "main.nux", text: main),
                NuxieMachineSourceFile(path: "clock.nux", text: """
                    component Clock
                      props
                        close: action

                      view
                        column padding=24 gap=12 background-color=#0d1214
                          text "One delivery." color=#eef3f1 font-size=24 id="line"
                          button padding=120 press=close id="close"
                            text "Close" color=#8a9794 font-size=16

                    """),
            ],
            assets: [], root: "main", app: "app", experience: "once", version: 1)
    }

}

/// One edge, its clock, and what its owner heard.
private final class OneDelivery {
    let edge: NuxieMachineEdge
    let owner = DeliveryOwner()
    private(set) var now: Int64 = 9 * 3_600_000

    init(compiled plan: NuxieMachinePlanSource) throws {
        let owner = self.owner
        edge = try NuxieMachineEdge(plan: plan, store: NuxieMachineStandInStore(),
                                    bytes: NoFolderFiles(), onReport: { owner.heard($0) })
    }

    /// Move the clock to `moment`, as a host does before delivering a wake.
    func jump(to moment: Int64) {
        now = max(now, moment)
    }

    /// One frame whose pointers press and release at `point` on the Screen
    /// of the showing `touched`: the one the person's view showed when they
    /// arrived.
    func tap(at point: (x: Float, y: Float), touching touched: NuxieMachineShown?) async {
        let pointers = [NuxieNativePointerKind.down, .up].map {
            NuxieNativePointerEvent(kind: $0, x: point.x, y: point.y)
        }
        await edge.frame(pointers: pointers, on: touched, elapsedSeconds: 1.0 / 60.0, now: now)
    }
}

/// The edge's owner: the reports it was told, one per delivery that did
/// something for it.
private final class DeliveryOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var heardReports: [NuxieMachineEdgeReport] = []

    var reports: [NuxieMachineEdgeReport] {
        lock.withLock { heardReports }
    }

    func heard(_ report: NuxieMachineEdgeReport) {
        lock.withLock { heardReports.append(report) }
    }
}
#endif
