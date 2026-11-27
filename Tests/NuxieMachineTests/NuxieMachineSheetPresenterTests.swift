#if os(iOS) && !targetEnvironment(macCatalyst)
import UIKit
import XCTest
import NuxieMachine

/// What a sheet presenter owns really goes, on a simulator with no window:
/// a real presenter over Stillwater's plan and the engine. The host is a
/// view controller in no window, so a sheet can never be presented, which
/// is enough for the two ends a presenter has with no sheet: a record that
/// faulted (let go of), and a record waiting for its wake (kept, until the
/// presenter itself is freed).
///
/// The store is an object the checks hold weakly: the edge holds it, the
/// Screen's view controller holds the edge, and the edge holds the session
/// and each presentation's player, so the store freed means the edge, the
/// session and the Screen are gone.
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
          task later  when due
            after(next 18:00, fire)
          action fire
            due = false

        """

    /// Stillwater's start presents the paywall, opened from the session's
    /// records, and the host cannot present it: the record faults with no
    /// sheet, and the presenter lets go of the Screen, its edge and session
    /// once the lane drains. The host's two lines still say what happened.
    @MainActor
    func testAFaultWithNoSheetLetsGoOfTheScreenItsEdgeAndSession() async throws {
        let plan = try Fixture.load()
        let host = UIViewController()
        let lines = HostLines()
        let presenter = NuxieMachineSheetPresenter(host: host) { lines.status = $0 }
        weak var edgeStore: ProbeStore?
        do {
            let store = ProbeStore()
            edgeStore = store
            await presenter.start(plan: plan, store: store, bytes: NoFolderFiles(), event: "onboarding_completed")
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
        let plan = NuxieMachinePlanSource(
            files: [NuxieMachineSourceFile(path: "main.nux", text: Self.waitsForTheEvening)],
            assets: [], root: "main", app: "app", experience: "evening", version: 1)
        let host = UIViewController()
        var presenter: NuxieMachineSheetPresenter? = NuxieMachineSheetPresenter(host: host) { _ in }
        weak let heldPresenter = presenter
        weak var edgeStore: ProbeStore?
        do {
            let store = ProbeStore()
            edgeStore = store
            await presenter?.start(plan: plan, store: store, bytes: NoFolderFiles(), event: "go")
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

    // MARK: The clock at its default

    /// The test seam for the clock, at its default, leaves the presenter on
    /// the wall clock: `clockAhead` is 0, and the start is handed the wall
    /// clock's moment, so the record's wake is the next 18:00 (UTC) after
    /// the wall clock's now. A moment a day off, or the clock's own offset
    /// added to it, would ask for another day's 18:00. The wake timer is set
    /// and still to come. Its deadline cannot be read: a dispatch timer does
    /// not give it back.
    @MainActor
    func testTheClockAtItsDefaultIsTheWallClock() async throws {
        let plan = NuxieMachinePlanSource(
            files: [NuxieMachineSourceFile(path: "main.nux", text: Self.waitsForTheEvening)],
            assets: [], root: "main", app: "app", experience: "evening", version: 1)
        let host = UIViewController()
        let presenter = NuxieMachineSheetPresenter(host: host) { _ in }
        XCTAssertEqual(presenter.clockAhead, 0, "the clock's offset is not 0 by default")

        let before = Self.wallNow()
        await presenter.start(plan: plan, store: ProbeStore(), bytes: NoFolderFiles(), event: "go")
        let after = Self.wallNow()

        guard case .open(let moment?) = presenter.status.record else { return XCTFail("\(presenter.status)") }
        let expected = Set([Self.nextEvening(after: before), Self.nextEvening(after: after)])
        XCTAssertTrue(expected.contains(moment),
                      "the record waits for \(moment), not the next 18:00 after the wall clock: \(expected)")
        let wake = try XCTUnwrap(presenter.scheduledWake, "no wake timer is set")
        XCTAssertFalse(wake.isCancelled)
        withExtendedLifetime(host) {}
    }

    /// Milliseconds since the Unix epoch on the wall clock.
    private static func wallNow() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded(.down))
    }

    /// The first 18:00 UTC after `now`, as `after(next 18:00, …)` reads it.
    private static func nextEvening(after now: Int64) -> Int64 {
        let day: Int64 = 86_400_000
        let evening = now / day * day + 18 * 3_600_000
        return evening > now ? evening : evening + day
    }

    // MARK: Leaving the app and coming back

    /// Stillwater's evening offer with nothing shown, so a presenter with
    /// no window can run it: the start leaves the offer due, as "Not now"
    /// does, and asks for 18:00. At 18:00 the offer is ready. With her here
    /// it is taken at once (`taken`); with her away it waits six hours for
    /// her, and is then given up, which ends the record.
    private static let theEveningOffer = """
        component App
          state offer_due = false
          state ready = false
          state taken = false
          entry
            on event "go"
            do arm
          action arm
            offer_due = true
          task offer_time  when offer_due
            after(next 18:00, offer_ready)
          task evening_offer  when ready and here
            change(show_offer)
          task offer_lapses  when ready and not here
            after(6h, give_up)
          action offer_ready
            offer_due = false
            ready = true
          action show_offer
            ready = false
            taken = true
          action give_up
            ready = false
            exit

        """

    private static let hour: Int64 = 3_600_000
    private static let day: Int64 = 86_400_000

    /// A presenter whose record starts at 17:00 (UTC) today on its clock
    /// and waits for 18:00, its edge, and today's midnight.
    @MainActor
    private func startTheEveningAtFive(_ host: UIViewController) async throws
        -> (NuxieMachineSheetPresenter, NuxieMachineEdge, Int64) {
        let plan = NuxieMachinePlanSource(
            files: [NuxieMachineSourceFile(path: "main.nux", text: Self.theEveningOffer)],
            assets: [], root: "main", app: "app", experience: "evening", version: 1)
        let presenter = NuxieMachineSheetPresenter(host: host) { _ in }
        let midnight = Self.wallNow() / Self.day * Self.day
        Self.move(presenter, to: midnight + 17 * Self.hour)
        await presenter.start(plan: plan, store: ProbeStore(), bytes: NoFolderFiles(), event: "go")
        let edge = try XCTUnwrap(presenter.edge, "the record did not stay open")
        XCTAssertEqual(presenter.status.record, .open(wakeAt: midnight + 18 * Self.hour))
        XCTAssertTrue(presenter.here, "a session starts with her here")
        return (presenter, edge, midnight)
    }

    /// Move the presenter's clock to `moment`, as the test host's film
    /// clock does.
    @MainActor
    private static func move(_ presenter: NuxieMachineSheetPresenter, to moment: Int64) {
        presenter.clockAhead = moment - wallNow()
    }

    /// Every presence the session took, in order.
    private static func presences(_ edge: NuxieMachineEdge) async -> [Bool] {
        await edge.log.compactMap { entry -> Bool? in
            if case .presence(let here) = entry { return here }
            return nil
        }
    }

    /// (a) Away at 17:00, back at 09:00 the next day: the presence call
    /// delivers the 18:00 wake she missed with her away, so the offer
    /// waits six hours for her and is given up at midnight, as Stillwater's
    /// is, and the record ends. Had the wake been delivered with her here,
    /// the offer would have been taken and the record would stay open. The
    /// presenter itself delivers no wake: none is left due once she is back.
    @MainActor
    func testBackTheNextMorningTheMissedWakeIsDeliveredWithHerAway() async throws {
        let host = UIViewController()
        let (presenter, edge, midnight) = try await startTheEveningAtFive(host)
        await presenter.presence(here: false)
        XCTAssertFalse(presenter.here)

        Self.move(presenter, to: midnight + Self.day + 9 * Self.hour)
        await presenter.presence(here: true)
        XCTAssertTrue(presenter.here)
        XCTAssertEqual(presenter.status.record, .ended, "the offer was not given up")
        let told = await Self.presences(edge)
        XCTAssertEqual(told, [false, true])
        let log = await edge.log
        XCTAssertTrue(log.contains(.end(reason: .exited, fault: nil)), "\(log)")
        XCTAssertEqual(presenter.wakesDelivered, [], "the presenter delivered a wake the presence call delivers")
        XCTAssertNil(presenter.scheduledWake, "a wake is still scheduled after the end")
        withExtendedLifetime(host) {}
    }

    /// (b) Away at 17:00, and the app still running at 18:00: the timer
    /// delivers the wake as it does with her here, and the machine judges
    /// it with her away. The offer is ready and waits for her until
    /// midnight; it is not taken.
    @MainActor
    func testATimerWakeWhileSheIsAwayIsDeliveredAndJudgedWithHerAway() async throws {
        let host = UIViewController()
        let (presenter, edge, midnight) = try await startTheEveningAtFive(host)
        await presenter.presence(here: false)

        let evening = midnight + 18 * Self.hour
        Self.move(presenter, to: evening + 60_000)
        try await waitUntil("the timer delivers 18:00") { presenter.wakesDelivered == [evening] }
        try await waitUntil("the record waits for midnight") {
            presenter.status.record == .open(wakeAt: evening + 6 * Self.hour)
        }
        let ready = try await edge.slot("ready")
        XCTAssertEqual(ready, .bool(true), "the offer is not ready")
        let taken = try await edge.slot("taken")
        XCTAssertEqual(taken, .bool(false), "the offer was taken with her away")
        XCTAssertFalse(presenter.here)
        withExtendedLifetime(host) {}
    }

    /// (c) Away told twice is told to the session once: the second changes
    /// nothing, and the record waits for 18:00 as before.
    @MainActor
    func testTheSamePresenceToldTwiceIsToldOnce() async throws {
        let host = UIViewController()
        let (presenter, edge, midnight) = try await startTheEveningAtFive(host)
        await presenter.presence(here: false)
        await presenter.presence(here: false)
        let told = await Self.presences(edge)
        XCTAssertEqual(told, [false], "the same presence reached the session twice")
        XCTAssertFalse(presenter.here)
        XCTAssertEqual(presenter.status.record, .open(wakeAt: midnight + 18 * Self.hour))
        XCTAssertEqual(presenter.wakesDelivered, [])
        withExtendedLifetime(host) {}
    }

    /// (d) Away at 17:00 and back at 17:30, with nothing missed: only the
    /// told value changes. The record waits for 18:00 as before, no wake is
    /// delivered, and the offer is still due.
    @MainActor
    func testBackWithNothingMissedChangesOnlyWhereSheIs() async throws {
        let host = UIViewController()
        let (presenter, edge, midnight) = try await startTheEveningAtFive(host)
        let before = presenter.status
        await presenter.presence(here: false)
        Self.move(presenter, to: midnight + 17 * Self.hour + 30 * 60_000)
        await presenter.presence(here: true)
        XCTAssertTrue(presenter.here)
        XCTAssertEqual(presenter.status, before, "coming back with nothing missed moved the record")
        XCTAssertEqual(presenter.wakesDelivered, [])
        let told = await Self.presences(edge)
        XCTAssertEqual(told, [false, true])
        for (slot, value) in [("offer_due", true), ("ready", false), ("taken", false)] {
            let read = try await edge.slot(slot)
            XCTAssertEqual(read, .bool(value), "\(slot) changed")
        }
        XCTAssertNotNil(presenter.scheduledWake, "the 18:00 wake is no longer scheduled")
        withExtendedLifetime(host) {}
    }

    /// Away before the start is kept, and told before it: the session is
    /// told the environment, then that she is away, then starts. At 18:00
    /// the timer's wake is judged with her away.
    @MainActor
    func testAwayBeforeTheStartIsToldBeforeIt() async throws {
        let plan = NuxieMachinePlanSource(
            files: [NuxieMachineSourceFile(path: "main.nux", text: Self.theEveningOffer)],
            assets: [], root: "main", app: "app", experience: "evening", version: 1)
        let host = UIViewController()
        let presenter = NuxieMachineSheetPresenter(host: host) { _ in }
        let midnight = Self.wallNow() / Self.day * Self.day
        Self.move(presenter, to: midnight + 17 * Self.hour)
        await presenter.presence(here: false)
        XCTAssertTrue(presenter.here, "the session was told before it was made")
        XCTAssertEqual(presenter.presencesWaiting.map(\.here), [false], "away was not kept for the start")
        await presenter.start(plan: plan, store: ProbeStore(), bytes: NoFolderFiles(), event: "go")
        XCTAssertFalse(presenter.here)
        XCTAssertEqual(presenter.presencesWaiting, [], "away was kept after the start told it")
        let edge = try XCTUnwrap(presenter.edge)
        let log = await edge.log
        XCTAssertEqual(Array(log.prefix(2).dropFirst()), [.presence(here: false)],
                       "away was not told right after the environment, before the start: \(log)")

        let evening = midnight + 18 * Self.hour
        Self.move(presenter, to: evening + 60_000)
        try await waitUntil("the record waits for midnight") {
            presenter.status.record == .open(wakeAt: evening + 6 * Self.hour)
        }
        withExtendedLifetime(host) {}
    }

    /// Away at 17:30 and back at 19:00, both received while a frame holds
    /// the loop's lane, and the lane reached only the next morning: each
    /// is told, in order, at the moment it was received. Away is told
    /// before the 18:00 wake, so the presenter delivers no wake as here;
    /// back is told at 19:00, so the machine delivers 18:00 inside that
    /// call with her away, and she is then here, so the offer is taken.
    /// Taking it presents nothing and leaves no task armed, so the record
    /// finishes. Told only at the lane's moment, the next morning, the offer
    /// would have been given up at midnight, and the record would have
    /// exited instead.
    @MainActor
    func testAwayAndBackWhileTheLaneIsHeldAreEachToldAtTheirOwnMoment() async throws {
        let host = UIViewController()
        let (presenter, edge, midnight) = try await startTheEveningAtFive(host)
        let gate = try await holdTheLane(of: presenter)

        Self.move(presenter, to: midnight + 17 * Self.hour + 30 * 60_000)
        let away = Task { @MainActor in await presenter.presence(here: false) }
        try await waitUntil("away is received") { presenter.presencesWaiting.count == 1 }
        Self.move(presenter, to: midnight + 19 * Self.hour)
        let back = Task { @MainActor in await presenter.presence(here: true) }
        try await waitUntil("back is received") { presenter.presencesWaiting.count == 2 }
        let received = presenter.presencesWaiting
        XCTAssertEqual(received.map(\.here), [false, true], "the two notices were not both kept, in order")
        XCTAssertLessThan(received[0].at, midnight + 18 * Self.hour, "away was not taken at 17:30")
        XCTAssertGreaterThanOrEqual(received[1].at, midnight + 19 * Self.hour, "back was not taken at 19:00")
        Self.move(presenter, to: midnight + Self.day + 9 * Self.hour)

        gate.open()
        await away.value
        await back.value
        XCTAssertEqual(presenter.presencesWaiting, [])
        XCTAssertEqual(presenter.presencesTold, received,
                       "away and back were not each told, in order, at the moment each was received")
        let told = await Self.presences(edge)
        XCTAssertEqual(told, [false, true], "away and back did not each reach the session, in order")
        XCTAssertTrue(presenter.here)
        XCTAssertFalse(presenter.wakesDelivered.contains(midnight + 18 * Self.hour),
                       "18:00 was delivered by the presenter as here, not by the return with her away")
        let taken = try await edge.slot("taken")
        XCTAssertEqual(taken, .bool(true), "the offer was not taken when she came back at 19:00")
        XCTAssertEqual(presenter.status.record, .ended, "the record did not end once the offer was taken")
        let log = await edge.log
        XCTAssertTrue(log.contains(.end(reason: .finished, fault: nil)), "the record did not finish: \(log)")
        XCTAssertFalse(log.contains(.end(reason: .exited, fault: nil)), "the offer was given up: \(log)")
        withExtendedLifetime(host) {}
    }

    /// Away received at 17:30 while a frame holds the loop's lane, and the
    /// lane reached only at 18:30: the departure is told at 17:30, before
    /// the 18:00 wake, so the wake is judged with her away. The offer is
    /// ready and waits for her until midnight; it is not taken.
    @MainActor
    func testADepartureReceivedBeforeAWakeHasTheWakeJudgedWithHerAway() async throws {
        let host = UIViewController()
        let (presenter, edge, midnight) = try await startTheEveningAtFive(host)
        let gate = try await holdTheLane(of: presenter)

        Self.move(presenter, to: midnight + 17 * Self.hour + 30 * 60_000)
        let away = Task { @MainActor in await presenter.presence(here: false) }
        try await waitUntil("away is received") { presenter.presencesWaiting.count == 1 }
        let evening = midnight + 18 * Self.hour
        Self.move(presenter, to: evening + 30 * 60_000)

        gate.open()
        await away.value
        try await waitUntil("18:00 is delivered") { presenter.wakesDelivered == [evening] }
        let told = await Self.presences(edge)
        XCTAssertEqual(told, [false])
        XCTAssertEqual(presenter.status.record, .open(wakeAt: evening + 6 * Self.hour),
                       "18:00 was not judged with her away")
        let ready = try await edge.slot("ready")
        XCTAssertEqual(ready, .bool(true), "the offer is not ready")
        let taken = try await edge.slot("taken")
        XCTAssertEqual(taken, .bool(false), "the offer was taken with her away")
        withExtendedLifetime(host) {}
    }

    /// Away received at 17:30 while a frame holds the loop's lane, and the
    /// lane reached at 17:45: that run tells away at 17:30, and while it
    /// waits on the session, back is received at 01:00 the next morning,
    /// after the 18:00 wake, which is past the run's moment and not yet
    /// delivered. Back is not told early, at the run's 17:45: it waits for
    /// the next run and is told at 01:00, after 18:00, so the machine
    /// delivers 18:00 with her away inside that call, and midnight too: the
    /// offer waited for her and was given up, and the record exited. Told
    /// at 17:45, she would have been here at 18:00 and the offer taken.
    @MainActor
    func testAReturnReceivedWhileARunWaitsIsToldAfterTheWakeBeforeIt() async throws {
        let host = UIViewController()
        let (presenter, edge, midnight) = try await startTheEveningAtFive(host)
        let lane = try await holdTheLane(of: presenter)

        Self.move(presenter, to: midnight + 17 * Self.hour + 30 * 60_000)
        let away = Task { @MainActor in await presenter.presence(here: false) }
        try await waitUntil("away is received") { presenter.presencesWaiting.count == 1 }
        let departure = presenter.presencesWaiting[0]
        Self.move(presenter, to: midnight + 17 * Self.hour + 45 * 60_000)
        let turn = try await holdTheTurn(of: edge)
        lane.open()
        try await waitUntil("the run tells away and waits on the session") {
            presenter.presencesWaiting.isEmpty && !presenter.here
        }

        let lapse = midnight + 24 * Self.hour
        Self.move(presenter, to: lapse + Self.hour)
        let back = Task { @MainActor in await presenter.presence(here: true) }
        try await waitUntil("back is received") { presenter.presencesWaiting.count == 1 }
        let comeBack = presenter.presencesWaiting[0]
        XCTAssertTrue(comeBack.here)
        XCTAssertGreaterThanOrEqual(comeBack.at, lapse + Self.hour, "back was not received at 01:00")
        turn.open()
        await away.value
        await back.value

        XCTAssertEqual(presenter.presencesWaiting, [])
        XCTAssertEqual(presenter.presencesTold, [departure, comeBack],
                       "back was not told at the moment it was received, after 18:00")
        XCTAssertEqual(presenter.wakesDelivered, [], "the presenter delivered 18:00 with her here")
        XCTAssertTrue(presenter.here)
        let taken = try await edge.slot("taken")
        XCTAssertEqual(taken, .bool(false), "the offer was taken: 18:00 was judged with her here")
        XCTAssertEqual(presenter.status.record, .ended, "the offer was not given up")
        let log = await edge.log
        XCTAssertTrue(log.contains(.end(reason: .exited, fault: nil)), "the offer was not given up: \(log)")
        withExtendedLifetime(host) {}
    }

    /// Hold `presenter`'s lane, as a frame in flight holds it, until the
    /// gate is opened.
    @MainActor
    private func holdTheLane(of presenter: NuxieMachineSheetPresenter) async throws -> Gate {
        let loop = try XCTUnwrap(presenter.screenLoop, "the presenter holds no loop")
        let gate = Gate()
        Task { @MainActor in await loop.inLane { await gate.wait() } }
        try await waitUntil("the lane is held") { gate.holding }
        return gate
    }

    /// Hold `edge`'s turn, as a delivery in flight holds it, until the gate
    /// is opened: a delivery asked for meanwhile waits for it.
    @MainActor
    private func holdTheTurn(of edge: NuxieMachineEdge) async throws -> Gate {
        let gate = Gate()
        Task { await edge.holdingTurn { await gate.wait() } }
        try await waitUntil("the edge's turn is held") { gate.holding }
        return gate
    }

    // MARK: Each presentation laid out as its own style

    /// A sheet and a cover are each a controller of their own, set up as
    /// their style and laid out alike: the Screen fills its view.
    @MainActor
    func testASheetAndACoverAreEachLaidOutAsTheirOwnStyle() throws {
        let loop = try Self.loop()
        for presentation in [NuxieMachinePresentation.sheet, .cover] {
            let (controller, window) = Self.screen(presenting: presentation, loop: loop)
            try Self.expect(controller, laidOutAs: presentation)
            withExtendedLifetime(window) {}
        }
    }

    // MARK: What a swipe down on a sheet does

    /// Whether UIKit lets the person swipe a sheet away is the machine's
    /// answer: a swipe that closes runs natively; one that presses a control
    /// or does nothing is held. The answer each report brings is taken at
    /// once. A cover has no swipe, whatever is said.
    @MainActor
    func testIsModalInPresentationFollowsWhatTheSwipeDoesAfterEachReport() throws {
        let loop = try Self.loop()
        let shown = NuxieMachineShown(journey: 1, instance: 1)
        let (controller, window) = Self.screen(presenting: .sheet, loop: loop, swipeDown: .closes)
        XCTAssertFalse(controller.isModalInPresentation, "a swipe that closes is held")
        for (answer, held) in [(NuxieMachineSwipeWould.presses, true), (.stays, true), (.closes, false)] {
            controller.follow(NuxieMachinePresented(shown: shown, route: "screen", presentation: .sheet,
                                                    swipeDown: answer))
            XCTAssertEqual(controller.swipeDown, answer)
            XCTAssertEqual(controller.isModalInPresentation, held, "\(answer)")
            XCTAssertEqual(controller.modalReasons, held ? [.swipeRefused] : [], "\(answer)")
        }
        // A report for another presentation changes nothing here.
        controller.follow(NuxieMachinePresented(shown: NuxieMachineShown(journey: 1, instance: 2), route: "other",
                                                presentation: .sheet, swipeDown: .stays))
        XCTAssertFalse(controller.isModalInPresentation)
        let (cover, coverWindow) = Self.screen(presenting: .cover, loop: loop)
        XCTAssertEqual(cover.modalReasons, [.swipeRefused])
        XCTAssertTrue(cover.isModalInPresentation)
        withExtendedLifetime((window, coverWindow)) {}
    }

    /// The reasons combine: a sheet presented before its page's files are
    /// in shows the loading screen, which holds it, so a sheet whose swipe
    /// closes still cannot be swiped away, and neither a held swipe nor the
    /// screen reader's escape is delivered; and a sheet whose swipe is
    /// refused stays held once the loading is over.
    @MainActor
    func testTheReasonsASheetIsHeldCombine() throws {
        let loop = try Self.loop()
        let shown = NuxieMachineShown(journey: 1, instance: 1)
        let (controller, window) = Self.screen(presenting: .sheet, loop: loop, swipeDown: .closes,
                                               assets: .waiting(["assets/hero.png"]))
        controller.loadViewIfNeeded()
        XCTAssertEqual(controller.modalReasons, [.loading])
        XCTAssertTrue(controller.isModalInPresentation, "a loading sheet whose swipe closes can be swiped away")
        var delivered = 0
        controller.onEscape = { delivered += 1 }
        XCTAssertFalse(controller.accessibilityPerformEscape(), "the escape closed a loading sheet")
        XCTAssertEqual(delivered, 0)
        controller.follow(NuxieMachinePresented(shown: shown, route: "screen", presentation: .sheet,
                                                swipeDown: .stays))
        XCTAssertEqual(controller.modalReasons, [.loading, .swipeRefused])
        controller.modalReasons.remove(.loading)
        XCTAssertTrue(controller.isModalInPresentation, "the refused swipe went with the loading")
        controller.follow(NuxieMachinePresented(shown: shown, route: "screen", presentation: .sheet,
                                                swipeDown: .closes))
        XCTAssertFalse(controller.isModalInPresentation)
        withExtendedLifetime(window) {}
    }

    /// The screen reader's escape is a swipe down, read from the same
    /// answer: where the swipe does nothing it is passed on and nothing is
    /// delivered; where it presses or closes, it is delivered once and the
    /// escape is taken. A cover passes it on.
    @MainActor
    func testTheScreenReadersEscapeIsASwipeDownForEachAnswer() throws {
        let loop = try Self.loop()
        for (answer, taken) in [(NuxieMachineSwipeWould.stays, false), (.presses, true), (.closes, true)] {
            let (controller, window) = Self.screen(presenting: .sheet, loop: loop, swipeDown: answer)
            var delivered = 0
            controller.onEscape = { delivered += 1 }
            XCTAssertEqual(controller.accessibilityPerformEscape(), taken, "\(answer)")
            XCTAssertEqual(delivered, taken ? 1 : 0, "\(answer)")
            withExtendedLifetime(window) {}
        }
        let (cover, window) = Self.screen(presenting: .cover, loop: loop)
        var delivered = 0
        cover.onEscape = { delivered += 1 }
        XCTAssertFalse(cover.accessibilityPerformEscape())
        XCTAssertEqual(delivered, 0)
        withExtendedLifetime(window) {}
    }

    /// A sheet rests at the heights its row writes, in its order until the
    /// height it can take is known: medium and large are the system's, a
    /// height in points and a percent are detents of this module's, named by
    /// their kind and number. A row that writes none rests at large.
    @MainActor
    func testASheetRestsAtTheDetentsItsRowWrites() throws {
        guard #available(iOS 16.0, *) else { throw XCTSkip("custom detents need iOS 16") }
        let loop = try Self.loop()
        let (controller, window) = Self.screen(presenting: .sheet, loop: loop,
                                               detents: [.medium, .percent(40), .points(320), .fitContent])
        let sheet = try XCTUnwrap(controller.sheetPresentationController)
        XCTAssertEqual(sheet.detents.map(\.identifier),
                       [.medium, .init(rawValue: "nuxie.percent.40.0"), .init(rawValue: "nuxie.points.320.0"),
                        .init(rawValue: "nuxie.fit-content")])
        let (plain, plainWindow) = Self.screen(presenting: .sheet, loop: loop)
        XCTAssertEqual(try XCTUnwrap(plain.sheetPresentationController).detents.map(\.identifier), [.large])
        withExtendedLifetime((window, plainWindow)) {}
    }

    /// UIKit takes a sheet's detents shortest first, so they are ordered by
    /// the height each rests at for the most the sheet can be, while what
    /// the machine shows keeps the row's order. `medium 40% 320` on a phone
    /// held upright (790 points at most, the presenter's estimate): 40% is
    /// 316, then 320, then medium at about 395. Turned on its side, UIKit
    /// resolves against 360: 40% is 144, medium about 180, then 320. The
    /// detent the sheet rests at stays selected when the order changes.
    @MainActor
    func testUIKitTakesTheDetentsShortestFirstWhileTheRowKeepsItsOrder() throws {
        let authored: [NuxieMachineDetent] = [.medium, .percent(40), .points(320)]
        let order = NuxieMachineScreenViewController.nativeOrder(of:maximum:contentHeight:)
        XCTAssertEqual(order(authored, 790, nil), [.percent(40), .points(320), .medium])
        XCTAssertEqual(order(authored, 360, nil), [.percent(40), .medium, .points(320)])
        XCTAssertEqual(order(authored, nil, nil), authored, "with no height known the row's order stands")
        XCTAssertEqual(order([.large, .medium, .large], 790, nil), [.medium, .large])
        XCTAssertEqual(order([.fitContent, .medium], 790, 200), [.fitContent, .medium])
        XCTAssertEqual(order([.fitContent, .medium], 790, 600), [.medium, .fitContent])

        guard #available(iOS 16.0, *) else { throw XCTSkip("custom detents need iOS 16") }
        let loop = try Self.loop()
        let (controller, window) = Self.screen(presenting: .sheet, loop: loop, detents: authored)
        let sheet = try XCTUnwrap(controller.sheetPresentationController)
        let percent = UISheetPresentationController.Detent.Identifier(rawValue: "nuxie.percent.40.0")
        let points = UISheetPresentationController.Detent.Identifier(rawValue: "nuxie.points.320.0")
        controller.orderDetents(estimatedMaximum: 790)
        XCTAssertEqual(sheet.detents.map(\.identifier), [percent, points, .medium])
        XCTAssertEqual(controller.detents, authored, "the row's order was lost")
        sheet.selectedDetentIdentifier = .medium
        controller.resolved(maximum: 360)
        XCTAssertEqual(sheet.detents.map(\.identifier), [percent, .medium, points])
        XCTAssertEqual(sheet.selectedDetentIdentifier, .medium, "the sheet moved off the detent it rests at")
        XCTAssertEqual(controller.detents, authored, "the row's order was lost")
        withExtendedLifetime(window) {}
    }

    /// The order is made with the maximum UIKit resolves against, which for
    /// a sheet at the bottom of a phone leaves out the bottom inset too. On
    /// a phone 844 points tall with insets of 59 and 34, a height that left
    /// out only the top inset (785) puts 320 (as written) below 42% (329.7);
    /// UIKit resolves against 751, where 42% is 315.4, under 320. Once UIKit
    /// has resolved, an estimate changes nothing.
    @MainActor
    func testTheOrderFollowsTheMaximumUIKitResolvesAgainst() throws {
        let authored: [NuxieMachineDetent] = [.points(320), .percent(42)]
        let order = NuxieMachineScreenViewController.nativeOrder(of:maximum:contentHeight:)
        XCTAssertEqual(order(authored, 844 - 59, nil), [.points(320), .percent(42)])
        XCTAssertEqual(order(authored, 844 - 59 - 34, nil), [.percent(42), .points(320)])

        guard #available(iOS 16.0, *) else { throw XCTSkip("custom detents need iOS 16") }
        let loop = try Self.loop()
        let (controller, window) = Self.screen(presenting: .sheet, loop: loop, detents: authored)
        let sheet = try XCTUnwrap(controller.sheetPresentationController)
        let percent = UISheetPresentationController.Detent.Identifier(rawValue: "nuxie.percent.42.0")
        let points = UISheetPresentationController.Detent.Identifier(rawValue: "nuxie.points.320.0")
        controller.orderDetents(estimatedMaximum: 844 - 59)
        XCTAssertEqual(sheet.detents.map(\.identifier), [points, percent])
        controller.resolved(maximum: 844 - 59 - 34)
        XCTAssertEqual(sheet.detents.map(\.identifier), [percent, points], "not ordered as UIKit resolves")
        controller.orderDetents(estimatedMaximum: 844 - 59)
        XCTAssertEqual(sheet.detents.map(\.identifier), [percent, points], "an estimate overrode UIKit")
        XCTAssertEqual(controller.detents, authored, "the row's order was lost")
        withExtendedLifetime(window) {}
    }

    /// The height each of this module's detents rests at, for a sheet that
    /// can be at most 800 points: points and a percent as written, never
    /// more than the most; the content's height as measured, never more
    /// than the most, and the most until it is measured.
    func testEachDetentsHeightAndFitContentFromAMeasuredHeight() {
        let height = NuxieMachineScreenViewController.height(of:maximum:contentHeight:)
        XCTAssertEqual(height(.points(320), 800, nil), 320)
        XCTAssertEqual(height(.points(1200), 800, nil), 800)
        XCTAssertEqual(height(.percent(40), 800, nil), 320)
        XCTAssertEqual(height(.fitContent, 800, 412), 412)
        XCTAssertEqual(height(.fitContent, 800, 1200), 800)
        XCTAssertEqual(height(.fitContent, 800, nil), 800)
        XCTAssertEqual(height(.fitContent, 800, 0), 800)
        XCTAssertNil(height(.medium, 800, nil))
        XCTAssertNil(height(.large, 800, nil))
    }

    /// A fit-content sheet takes the content's height as the engine
    /// measures it after a frame; a height the engine cannot give leaves it.
    @MainActor
    func testAFitContentSheetTakesTheMeasuredHeight() throws {
        let loop = try Self.loop()
        let (controller, window) = Self.screen(presenting: .sheet, loop: loop, detents: [.fitContent])
        XCTAssertNil(controller.contentHeight)
        controller.measured(contentHeight: 412)
        XCTAssertEqual(controller.contentHeight, 412)
        controller.measured(contentHeight: nil)
        controller.measured(contentHeight: .nan)
        XCTAssertEqual(controller.contentHeight, 412)
        withExtendedLifetime(window) {}
    }

    /// A loop over an edge whose session presents nothing.
    @MainActor
    private static func loop(
        plan: NuxieMachinePlanSource = NuxieMachinePlanSource(
            files: [NuxieMachineSourceFile(path: "main.nux", text: waitsForTheEvening)],
            assets: [], root: "main", app: "app", experience: "evening", version: 1)
    ) throws -> NuxieMachineScreenLoop {
        let edge = try NuxieMachineEdge(plan: plan, store: NuxieMachineStandInStore(),
                                        bytes: NoFolderFiles(), onReport: { _ in })
        return NuxieMachineScreenLoop(edge: edge)
    }

    /// A Screen for one presentation, the root of a window at a phone's
    /// size. Its safe areas are the device's, with a status bar's and a home
    /// indicator's added, so both edges have one.
    @MainActor
    private static func screen(
        presenting presentation: NuxieMachinePresentation, loop: NuxieMachineScreenLoop,
        shown: NuxieMachineShown = NuxieMachineShown(journey: 1, instance: 1), route: String = "screen",
        detents: [NuxieMachineDetent] = [], swipeDown: NuxieMachineSwipeWould? = nil,
        assets: NuxieMachineAssets = .ready
    ) -> (NuxieMachineScreenViewController, UIWindow) {
        let presented = NuxieMachinePresented(shown: shown, route: route, presentation: presentation,
                                              detents: detents, swipeDown: swipeDown)
        let controller = NuxieMachineScreenViewController(presenting: presented, loop: loop, assets: assets)
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
                  state ready = false

                  entry
                    on event "opened"
                    do start

                  routes
                    clock  Clock(close=close)  cover

                  action start
                    first_up = true
                    go(clock)

                  task noon  when first_up
                    after(next 12:00, hide)

                  action hide
                    first_up = false
                    later = true
                    dismiss("hidden")

                  task evening  when later
                    after(next 18:00, mark_ready)

                  task show  when ready and here
                    change(show_again)

                  action mark_ready
                    later = false
                    ready = true

                  action show_again
                    ready = false
                    go(clock)

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
        assets: [], root: "main", app: "app", experience: "again", version: 1)

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

    /// Lay out `controller`, made for `presentation`, and check it: either
    /// one's Screen fills its view to every edge over no ground, so the
    /// surface has the view's insets; a cover is full screen with no swipe,
    /// a sheet a page sheet at the large detent with no grabber, which the
    /// person can swipe down.
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
        XCTAssertEqual(surface.frame, view.bounds, "a \(presentation) does not fill its view")
        XCTAssertEqual(surface.safeAreaInsets, insets, "a \(presentation)'s surface does not have its view's insets")
        XCTAssertEqual(view.backgroundColor, .clear, "a \(presentation) shows a ground of its own")
        switch presentation {
        case .cover:
            XCTAssertEqual(controller.modalPresentationStyle, .fullScreen)
            XCTAssertTrue(controller.isModalInPresentation, "a cover has no swipe")
        default:
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

/// Holds a loop's lane or an edge's turn from inside it until it is
/// opened.
@MainActor
private final class Gate {
    private(set) var holding = false
    private var waiting: CheckedContinuation<Void, Never>?
    private var opened = false

    func wait() async {
        holding = true
        guard !opened else { return }
        await withCheckedContinuation { waiting = $0 }
    }

    func open() {
        opened = true
        waiting?.resume()
        waiting = nil
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

    func perform(_ call: NuxieMachineCall) async throws -> NuxieMachineReply {
        try await standIn.perform(call)
    }
}
#endif
