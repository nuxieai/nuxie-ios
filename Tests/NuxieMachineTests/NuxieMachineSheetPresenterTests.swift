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

    // MARK: A start that did not happen

    /// A plan whose start changes nothing, so the machine answers that it
    /// did not happen (`unstarted`).
    private static let changesNothing = """
        component Quiet
          platforms ios android

          state n = 0

          entry
            on event "go"
            once
            do look

          action look
            n = 0

        """

    /// A presenter started on an event that does not start a record
    /// presents nothing and lets go of its edge at once, and the host hears
    /// one status, that the record did not start, and never `open` first:
    /// for an event no entry starts on, and for a start the machine says
    /// changed nothing. No fault is told.
    @MainActor
    func testAStartThatDidNotHappenPresentsNothingAndTellsTheHostOnce() async throws {
        for (source, event) in [(Self.waitsForTheEvening, "nope"), (Self.changesNothing, "go")] {
            let plan = NuxieMachinePlanSource(
                files: [NuxieMachineSourceFile(path: "main.nux", text: source)],
                assets: [], root: "main", app: "app", experience: "quiet", version: 1)
            let host = UIViewController()
            let heard = HostHeard()
            let presenter = NuxieMachineSheetPresenter(host: host) { heard.statuses.append($0) }
            weak var edgeStore: ProbeStore?
            do {
                let store = ProbeStore()
                edgeStore = store
                await presenter.start(plan: plan, store: store, bytes: NoFolderFiles(), event: event)
            }

            XCTAssertEqual(heard.statuses.map(\.record), [.didNotStart], "the host heard \(heard.statuses) on \(event)")
            XCTAssertEqual(presenter.status.record, .didNotStart, event)
            XCTAssertNil(host.presentedViewController, "something was presented on \(event)")
            XCTAssertNil(presenter.edge, "the presenter kept its edge on \(event)")
            XCTAssertNil(presenter.scheduledWake, event)
            try await waitUntil("the edge is freed") { edgeStore == nil }
            withExtendedLifetime(host) {}
        }
    }

    /// A presenter started on an event no entry starts on, over a page that
    /// draws a picture: the start asked the byte source for the picture
    /// before the machine said nothing starts. The presenter closes its
    /// edge as for an end, so that ask is cancelled rather than left
    /// running, and the host hears only that the record did not start.
    @MainActor
    func testAStartThatDidNotHappenCancelsTheFilesItAskedFor() async throws {
        let host = UIViewController()
        let heard = HostHeard()
        let presenter = NuxieMachineSheetPresenter(host: host) { heard.statuses.append($0) }
        let bytes = CancelledBytes()
        await presenter.start(plan: try PictureFolder.plan(), store: ProbeStore(), bytes: bytes, event: "nope")

        XCTAssertEqual(heard.statuses.map(\.record), [.didNotStart], "the host heard \(heard.statuses)")
        XCTAssertNil(presenter.edge, "the presenter kept its edge")
        try await waitUntil("the picture is asked for") { bytes.asked == ["assets/hero.png"] }
        try await waitUntil("the ask is cancelled") { bytes.cancelled == ["assets/hero.png"] }
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

    /// A sheet and a cover are each a segment of their own, a navigation
    /// controller with its bar hidden, set up as their style and laid out
    /// alike: the Screen fills its view.
    @MainActor
    func testASheetAndACoverAreEachLaidOutAsTheirOwnStyle() throws {
        let loop = try Self.loop()
        for presentation in [NuxieMachinePresentation.sheet, .cover, .push] {
            let (_, controller, window) = Self.screen(presenting: presentation, loop: loop)
            try Self.expect(controller, laidOutAs: presentation)
            withExtendedLifetime(window) {}
        }
    }

    /// A pushed page fills its segment as its first page does, and is told
    /// the segment's place, with no bar's height in it: in a cover, the
    /// window's safe area with the cover's own added, the same place a
    /// cover's only page is told; in a sheet, the sheet's own.
    ///
    /// The window's safe area is the simulator's, which this runner does
    /// not choose (a window 390 by 844 on a phone 402 by 874 has 62 at the
    /// top and 4 at the bottom), so the place is checked against it, not
    /// against fixed numbers.
    @MainActor
    func testAPushedPageIsPlacedAsItsSegment() async throws {
        let loop = try Self.loop()
        let added = UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)
        let (cover, window) = Self.segment([Self.page(1, .cover), Self.page(2, .push)], loop: loop)
        cover.additionalSafeAreaInsets = added
        window.layoutIfNeeded()
        let pushed = try XCTUnwrap(cover.pages.last)
        XCTAssertTrue(cover.topViewController === pushed)
        let screenInsets = window.safeAreaInsets
        let expected = NuxieMachineScreenPlace(
            top: Double(screenInsets.top + added.top), right: 0,
            bottom: Double(screenInsets.bottom + added.bottom), left: 0, width: 390, height: 844)
        XCTAssertEqual(pushed.place, expected, "a pushed page in a cover is not placed as the cover")

        let (alone, aloneWindow) = Self.segment([Self.page(3, .cover)], loop: loop)
        alone.additionalSafeAreaInsets = added
        aloneWindow.layoutIfNeeded()
        XCTAssertEqual(try XCTUnwrap(alone.pages.first).place, pushed.place,
                       "a pushed page is placed apart from a cover's only page")

        let host = UIViewController()
        let sheetWindow = Self.window(host)
        let sheet = NuxieMachineSegmentController(pages: [Self.page(4, .sheet), Self.page(5, .push)].map {
            NuxieMachineScreenViewController(presenting: $0, loop: loop)
        })
        var presented = false
        host.present(sheet, animated: false) { presented = true }
        try await waitUntil("the sheet is presented", seconds: 5) { presented }
        sheetWindow.layoutIfNeeded()
        let inSheet = try XCTUnwrap(sheet.pages.last)
        try await waitUntil("the pushed page in the sheet has a place", seconds: 5) {
            sheetWindow.layoutIfNeeded()
            return inSheet.place != nil
        }
        let place = try XCTUnwrap(inSheet.place, "a pushed page in a sheet has no place")
        let view = try XCTUnwrap(sheet.view)
        XCTAssertEqual(place.width, Double(view.bounds.width))
        XCTAssertEqual(place.height, Double(view.bounds.height), "a pushed page does not fill its sheet")
        XCTAssertEqual(place.top, Double(view.safeAreaInsets.top), "a pushed page is not told its sheet's insets")
        XCTAssertEqual(place.bottom, Double(view.safeAreaInsets.bottom), "a pushed page is not told its sheet's insets")
        withExtendedLifetime((window, aloneWindow, sheetWindow)) {}
    }

    // MARK: What a swipe down on a sheet does

    /// Whether UIKit lets the person swipe a sheet away is the machine's
    /// answer for the sheet's own entry, held on the segment: a swipe that
    /// closes runs natively; one that presses a control or does nothing is
    /// held. The answer each report brings is taken at once. A cover has no
    /// swipe, whatever is said.
    @MainActor
    func testIsModalInPresentationFollowsWhatTheSwipeDoesAfterEachReport() throws {
        let loop = try Self.loop()
        let shown = NuxieMachineShown(journey: 1, instance: 1)
        let (segment, _, window) = Self.screen(presenting: .sheet, loop: loop, swipeDown: .closes)
        XCTAssertFalse(segment.isModalInPresentation, "a swipe that closes is held")
        for (answer, held) in [(NuxieMachineSwipeWould.presses, true), (.stays, true), (.closes, false)] {
            segment.follow(NuxieMachinePresented(shown: shown, route: "screen", presentation: .sheet,
                                                 swipeDown: answer))
            XCTAssertEqual(segment.swipeDown, answer)
            XCTAssertEqual(segment.isModalInPresentation, held, "\(answer)")
            XCTAssertEqual(segment.modalReasons, held ? [.swipeRefused] : [], "\(answer)")
        }
        // A report for another presentation changes nothing here.
        segment.follow(NuxieMachinePresented(shown: NuxieMachineShown(journey: 1, instance: 2), route: "other",
                                             presentation: .sheet, swipeDown: .stays))
        XCTAssertFalse(segment.isModalInPresentation)
        let (cover, _, coverWindow) = Self.screen(presenting: .cover, loop: loop)
        XCTAssertEqual(cover.modalReasons, [.swipeRefused])
        XCTAssertTrue(cover.isModalInPresentation)
        withExtendedLifetime((window, coverWindow)) {}
    }

    /// The reasons combine on the segment: a sheet presented before its
    /// page's files are in shows the loading screen, which holds it, so a
    /// sheet whose swipe closes still cannot be swiped away, and the screen
    /// reader's escape is not delivered; and a sheet whose swipe is refused
    /// stays held once the loading is over.
    @MainActor
    func testTheReasonsASheetIsHeldCombine() throws {
        let loop = try Self.loop()
        let shown = NuxieMachineShown(journey: 1, instance: 1)
        let (segment, controller, window) = Self.screen(presenting: .sheet, loop: loop, swipeDown: .closes,
                                                        assets: .waiting(["assets/hero.png"]))
        controller.loadViewIfNeeded()
        XCTAssertEqual(segment.modalReasons, [.loading])
        XCTAssertTrue(segment.isModalInPresentation, "a loading sheet whose swipe closes can be swiped away")
        var delivered: [(NuxieMachineSwipeGesture, NuxieMachineShown)] = []
        segment.onHeldSwipe = { delivered.append(($0, $1)) }
        XCTAssertFalse(controller.accessibilityPerformEscape(), "the escape closed a loading sheet")
        XCTAssertTrue(delivered.isEmpty)
        segment.follow(NuxieMachinePresented(shown: shown, route: "screen", presentation: .sheet,
                                             swipeDown: .stays))
        XCTAssertEqual(segment.modalReasons, [.loading, .swipeRefused])
        segment.modalReasons.remove(.loading)
        XCTAssertTrue(segment.isModalInPresentation, "the refused swipe went with the loading")
        segment.follow(NuxieMachinePresented(shown: shown, route: "screen", presentation: .sheet,
                                             swipeDown: .closes))
        XCTAssertFalse(segment.isModalInPresentation)
        withExtendedLifetime(window) {}
    }

    /// A page that waits for its files holds its whole segment, pushed or
    /// not, while the edge swipe on it reads only its own answer.
    @MainActor
    func testAPushedPageThatWaitsHoldsItsSegment() throws {
        let loop = try Self.loop()
        let pages = [Self.page(1, .sheet, swipeDown: .closes), Self.page(2, .push, swipeBack: .closes)]
        let screens = pages.enumerated().map { index, page in
            NuxieMachineScreenViewController(presenting: page, loop: loop,
                                             assets: index == 1 ? .waiting(["assets/hero.png"]) : .ready)
        }
        let segment = NuxieMachineSegmentController(pages: screens)
        XCTAssertEqual(segment.modalReasons, [.loading])
        XCTAssertTrue(segment.isModalInPresentation)
        let window = Self.window(segment)
        XCTAssertTrue(segment.popMayBegin(), "loading held the edge swipe")
        withExtendedLifetime(window) {}
    }

    /// A sheet and a page pushed on it arrive together while their files
    /// are coming, so both wait and the sheet is held. The files arrive:
    /// both stop waiting, the page under the top one too, though it has
    /// never drawn a frame, and the sheet is no longer held for loading.
    @MainActor
    func testFilesArrivingFreeEveryWaitingPageOfASegment() throws {
        let loop = try Self.loop()
        let coming = NuxieMachineAssets.waiting(["assets/hero.png"])
        let pages = [Self.page(1, .sheet, swipeDown: .closes), Self.page(2, .push, swipeBack: .closes)].map {
            NuxieMachineScreenViewController(presenting: $0, loop: loop, assets: coming)
        }
        let segment = NuxieMachineSegmentController(pages: pages)
        let window = Self.window(segment)
        window.layoutIfNeeded()
        XCTAssertTrue(pages.allSatisfy(\.waitsForFiles))
        XCTAssertEqual(segment.modalReasons, [.loading])
        for page in pages { page.assets = .ready }
        XCTAssertEqual(pages[0].framesDrawn, 0, "the page under the top one drew")
        XCTAssertFalse(pages[0].waitsForFiles, "the page under the top one still waits")
        XCTAssertEqual(segment.modalReasons, [], "the sheet is still held for loading")
        XCTAssertFalse(segment.isModalInPresentation)
        withExtendedLifetime(window) {}
    }

    // MARK: The screen reader's escape

    /// The screen reader's escape on a sheet's first page is a swipe down,
    /// read from the sheet's answer: where the swipe does nothing it is
    /// passed on and nothing is delivered; where it presses or closes, it is
    /// delivered once, for the sheet, and the escape is taken.
    @MainActor
    func testTheEscapeOnASheetIsASwipeDownForEachAnswer() throws {
        let loop = try Self.loop()
        for (answer, taken) in [(NuxieMachineSwipeWould.stays, false), (.presses, true), (.closes, true)] {
            let (segment, controller, window) = Self.screen(presenting: .sheet, loop: loop, swipeDown: answer)
            var delivered: [(NuxieMachineSwipeGesture, NuxieMachineShown)] = []
            segment.onHeldSwipe = { delivered.append(($0, $1)) }
            XCTAssertEqual(controller.accessibilityPerformEscape(), taken, "\(answer)")
            XCTAssertEqual(delivered.map(\.0), taken ? [.down] : [], "\(answer)")
            XCTAssertEqual(delivered.map(\.1), taken ? [segment.id] : [], "\(answer)")
            withExtendedLifetime(window) {}
        }
    }

    /// The escape on a cover's first page has no gesture: it is passed on.
    @MainActor
    func testTheEscapeOnACoversFirstPageIsPassedOn() throws {
        let loop = try Self.loop()
        for presentation in [NuxieMachinePresentation.cover, .push] {
            let (segment, controller, window) = Self.screen(presenting: presentation, loop: loop)
            var delivered = 0
            segment.onHeldSwipe = { _, _ in delivered += 1 }
            XCTAssertFalse(controller.accessibilityPerformEscape(), "\(presentation)")
            XCTAssertEqual(delivered, 0)
            withExtendedLifetime(window) {}
        }
    }

    /// The escape on a pushed page, with a page of its segment beneath it,
    /// is a swipe back, read from the page's own answer, in a sheet as in a
    /// cover: where it does nothing it is passed on; where it presses or
    /// closes, it is delivered once, for the page.
    @MainActor
    func testTheEscapeOnAPushedPageIsASwipeBackForEachAnswer() throws {
        let loop = try Self.loop()
        for bottom in [NuxieMachinePresentation.sheet, .cover] {
            for (answer, taken) in [(NuxieMachineSwipeWould.stays, false), (.presses, true), (.closes, true)] {
                let pages = [Self.page(1, bottom, swipeDown: .closes), Self.page(2, .push, swipeBack: answer)]
                let (segment, window) = Self.segment(pages, loop: loop)
                var delivered: [(NuxieMachineSwipeGesture, NuxieMachineShown)] = []
                segment.onHeldSwipe = { delivered.append(($0, $1)) }
                let pushed = try XCTUnwrap(segment.pages.last)
                XCTAssertEqual(pushed.accessibilityPerformEscape(), taken, "\(bottom) \(answer)")
                XCTAssertEqual(delivered.map(\.0), taken ? [.back] : [], "\(bottom) \(answer)")
                XCTAssertEqual(delivered.map(\.1), taken ? [pages[1].shown] : [], "\(bottom) \(answer)")
                withExtendedLifetime(window) {}
            }
        }
    }

    // MARK: The edge swipe

    /// The edge swipe is the navigation controller's own pop recognizer,
    /// whose delegate is not the segment, and it asks the machine's answer
    /// for the page on top before it begins: a swipe that closes the page
    /// begins and is not delivered yet; one that presses a control or does
    /// nothing does not begin, and is delivered once as held. With no page
    /// beneath, it never begins.
    @MainActor
    func testTheEdgeSwipeBeginsOnlyWhereItClosesThePage() throws {
        let loop = try Self.loop()
        for (answer, begins) in [(NuxieMachineSwipeWould.stays, false), (.presses, false), (.closes, true)] {
            let pages = [Self.page(1, .cover), Self.page(2, .push, swipeBack: answer)]
            let (segment, window) = Self.segment(pages, loop: loop)
            var delivered: [(NuxieMachineSwipeGesture, NuxieMachineShown)] = []
            segment.onHeldSwipe = { delivered.append(($0, $1)) }
            let pop = try XCTUnwrap(segment.interactivePopGestureRecognizer)
            let delegate = try XCTUnwrap(pop.delegate, "with the bar hidden, the pop needs a delegate")
            XCTAssertFalse(delegate === segment, "the segment is the pop's delegate")
            XCTAssertEqual(delegate.gestureRecognizerShouldBegin?(pop), begins, "\(answer)")
            XCTAssertEqual(delivered.map(\.0), begins ? [] : [.back], "\(answer)")
            XCTAssertEqual(delivered.map(\.1), begins ? [] : [pages[1].shown], "\(answer)")
            withExtendedLifetime(window) {}
        }
        let (alone, window) = Self.segment([Self.page(1, .cover, swipeBack: .closes)], loop: loop)
        var delivered = 0
        alone.onHeldSwipe = { _, _ in delivered += 1 }
        let pop = try XCTUnwrap(alone.interactivePopGestureRecognizer)
        XCTAssertEqual(pop.delegate?.gestureRecognizerShouldBegin?(pop), false, "a first page popped")
        XCTAssertEqual(delivered, 0)
        withExtendedLifetime(window) {}
    }

    // MARK: A change of pages

    /// A replace of the page on top is one change of the segment's pages,
    /// which UIKit animates as a push: its new top page is new. The change
    /// is followed to the transition's own end, and then UIKit holds the
    /// new pages.
    @MainActor
    func testAReplaceIsOneChangeAnimatedAsAPush() async throws {
        let loop = try Self.loop()
        let (segment, window) = Self.segment([Self.page(1, .cover), Self.page(2, .push)], loop: loop)
        let kept = try XCTUnwrap(segment.pages.first)
        let replacing = NuxieMachineScreenViewController(presenting: Self.page(3, .push), loop: loop)
        try await expectOneChange(segment, to: [kept, replacing], animatedAs: .push)
        withExtendedLifetime(window) {}
    }

    /// A pop to the page two below is one change of the segment's pages,
    /// which UIKit animates as a pop: its new top page is a kept one.
    @MainActor
    func testAPopToAPageIsOneChangeAnimatedAsAPop() async throws {
        let loop = try Self.loop()
        let (segment, window) = Self.segment([Self.page(1, .cover), Self.page(2, .push), Self.page(3, .push)],
                                             loop: loop)
        let kept = try XCTUnwrap(segment.pages.first)
        try await expectOneChange(segment, to: [kept], animatedAs: .pop)
        withExtendedLifetime(window) {}
    }

    /// Set `segment`'s pages to `pages` and check the change: the segment
    /// holds them at once; UIKit runs one animated transition, asked for as
    /// `operation`; the completion comes from that transition's end, not
    /// before it; and once it has come UIKit holds exactly `pages`.
    @MainActor
    private func expectOneChange(_ segment: NuxieMachineSegmentController,
                                 to pages: [NuxieMachineScreenViewController],
                                 animatedAs operation: UINavigationController.Operation) async throws {
        XCTAssertNotNil(segment.view.window, "the segment is not on screen, so nothing animates")
        var done = 0
        segment.setPages(pages) { done += 1 }
        XCTAssertEqual(segment.pages.map(\.shown), pages.map(\.shown))
        XCTAssertNotNil(segment.transitionCoordinator, "the change is not an animated transition")
        XCTAssertEqual(done, 0, "the change was told over before its transition ran")
        try await waitUntil("UIKit asked how to animate the change") { segment.lastOperation != .none }
        XCTAssertEqual(segment.lastOperation, operation)
        try await waitUntil("the transition is over") { done > 0 }
        XCTAssertEqual(done, 1)
        XCTAssertNil(segment.transitionCoordinator, "the change was told over while its transition ran")
        XCTAssertEqual(segment.viewControllers.map { ($0 as? NuxieMachineScreenViewController)?.shown },
                       pages.map(\.shown), "UIKit does not hold the pages set")
    }

    // MARK: A sheet's heights

    /// A sheet rests at the heights its row writes, in its order until the
    /// height it can take is known: medium and large are the system's, a
    /// height in points and a percent are detents of this module's, named by
    /// their kind and number. A row that writes none rests at large. The
    /// segment holds them, from its first entry.
    @MainActor
    func testASheetRestsAtTheDetentsItsRowWrites() throws {
        guard #available(iOS 16.0, *) else { throw XCTSkip("custom detents need iOS 16") }
        let loop = try Self.loop()
        let (segment, _, window) = Self.screen(presenting: .sheet, loop: loop,
                                               detents: [.medium, .percent(40), .points(320), .fitContent])
        let sheet = try XCTUnwrap(segment.sheetPresentationController)
        XCTAssertEqual(sheet.detents.map(\.identifier),
                       [.medium, .init(rawValue: "nuxie.percent.40.0"), .init(rawValue: "nuxie.points.320.0"),
                        .init(rawValue: "nuxie.fit-content")])
        let (plain, _, plainWindow) = Self.screen(presenting: .sheet, loop: loop)
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
        let order = NuxieMachineSegmentController.nativeOrder(of:maximum:contentHeight:)
        XCTAssertEqual(order(authored, 790, nil), [.percent(40), .points(320), .medium])
        XCTAssertEqual(order(authored, 360, nil), [.percent(40), .medium, .points(320)])
        XCTAssertEqual(order(authored, nil, nil), authored, "with no height known the row's order stands")
        XCTAssertEqual(order([.large, .medium, .large], 790, nil), [.medium, .large])
        XCTAssertEqual(order([.fitContent, .medium], 790, 200), [.fitContent, .medium])
        XCTAssertEqual(order([.fitContent, .medium], 790, 600), [.medium, .fitContent])

        guard #available(iOS 16.0, *) else { throw XCTSkip("custom detents need iOS 16") }
        let loop = try Self.loop()
        let (segment, _, window) = Self.screen(presenting: .sheet, loop: loop, detents: authored)
        let sheet = try XCTUnwrap(segment.sheetPresentationController)
        let percent = UISheetPresentationController.Detent.Identifier(rawValue: "nuxie.percent.40.0")
        let points = UISheetPresentationController.Detent.Identifier(rawValue: "nuxie.points.320.0")
        segment.orderDetents(estimatedMaximum: 790)
        XCTAssertEqual(sheet.detents.map(\.identifier), [percent, points, .medium])
        XCTAssertEqual(segment.detents, authored, "the row's order was lost")
        sheet.selectedDetentIdentifier = .medium
        segment.resolved(maximum: 360)
        XCTAssertEqual(sheet.detents.map(\.identifier), [percent, .medium, points])
        XCTAssertEqual(sheet.selectedDetentIdentifier, .medium, "the sheet moved off the detent it rests at")
        XCTAssertEqual(segment.detents, authored, "the row's order was lost")
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
        let order = NuxieMachineSegmentController.nativeOrder(of:maximum:contentHeight:)
        XCTAssertEqual(order(authored, 844 - 59, nil), [.points(320), .percent(42)])
        XCTAssertEqual(order(authored, 844 - 59 - 34, nil), [.percent(42), .points(320)])

        guard #available(iOS 16.0, *) else { throw XCTSkip("custom detents need iOS 16") }
        let loop = try Self.loop()
        let (segment, _, window) = Self.screen(presenting: .sheet, loop: loop, detents: authored)
        let sheet = try XCTUnwrap(segment.sheetPresentationController)
        let percent = UISheetPresentationController.Detent.Identifier(rawValue: "nuxie.percent.42.0")
        let points = UISheetPresentationController.Detent.Identifier(rawValue: "nuxie.points.320.0")
        segment.orderDetents(estimatedMaximum: 844 - 59)
        XCTAssertEqual(sheet.detents.map(\.identifier), [points, percent])
        segment.resolved(maximum: 844 - 59 - 34)
        XCTAssertEqual(sheet.detents.map(\.identifier), [percent, points], "not ordered as UIKit resolves")
        segment.orderDetents(estimatedMaximum: 844 - 59)
        XCTAssertEqual(sheet.detents.map(\.identifier), [percent, points], "an estimate overrode UIKit")
        XCTAssertEqual(segment.detents, authored, "the row's order was lost")
        withExtendedLifetime(window) {}
    }

    /// A sheet first rests at its shortest detent, whatever order its row
    /// writes them in. `large 320 30%`, tallest first, on a phone that
    /// leaves a sheet 751 points: 30% is 225.3, then 320, then large. The
    /// sheet names no detent to open at, and UIKit opens a sheet that names
    /// none at the first of its detents, the shortest, so the detent it
    /// opens at is 30%; and still 30% once UIKit's own maximum orders them.
    @MainActor
    func testASheetFirstRestsAtItsShortestDetent() throws {
        guard #available(iOS 16.0, *) else { throw XCTSkip("custom detents need iOS 16") }
        let loop = try Self.loop()
        let authored: [NuxieMachineDetent] = [.large, .points(320), .percent(30)]
        let (segment, _, window) = Self.screen(presenting: .sheet, loop: loop, detents: authored)
        let sheet = try XCTUnwrap(segment.sheetPresentationController)
        let percent = UISheetPresentationController.Detent.Identifier(rawValue: "nuxie.percent.30.0")
        let points = UISheetPresentationController.Detent.Identifier(rawValue: "nuxie.points.320.0")
        segment.orderDetents(estimatedMaximum: 751)
        XCTAssertEqual(sheet.detents.map(\.identifier), [percent, points, .large])
        XCTAssertNil(sheet.selectedDetentIdentifier, "the sheet names a detent to open at")
        XCTAssertEqual(sheet.selectedDetentIdentifier ?? sheet.detents.first?.identifier, percent,
                       "the sheet does not open at its shortest detent")
        segment.resolved(maximum: 700)
        XCTAssertEqual(sheet.selectedDetentIdentifier ?? sheet.detents.first?.identifier, percent,
                       "the sheet does not open at its shortest detent")
        XCTAssertEqual(segment.detents, authored, "the row's order was lost")
        withExtendedLifetime(window) {}
    }

    /// The height each of this module's detents rests at, for a sheet that
    /// can be at most 800 points: points and a percent as written, never
    /// more than the most; the content's height as measured, never more
    /// than the most, and the most until it is measured.
    func testEachDetentsHeightAndFitContentFromAMeasuredHeight() {
        let height = NuxieMachineSegmentController.height(of:maximum:contentHeight:)
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
        let (segment, _, window) = Self.screen(presenting: .sheet, loop: loop, detents: [.fitContent])
        XCTAssertTrue(segment.fitsContent)
        XCTAssertNil(segment.contentHeight)
        segment.measured(contentHeight: 412)
        XCTAssertEqual(segment.contentHeight, 412)
        segment.measured(contentHeight: nil)
        segment.measured(contentHeight: .nan)
        XCTAssertEqual(segment.contentHeight, 412)
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

    /// A Screen for one presentation, the only page of its segment, the
    /// root of a window at a phone's size. Its safe areas are the device's,
    /// with a status bar's and a home indicator's added, so both edges have
    /// one.
    @MainActor
    private static func screen(
        presenting presentation: NuxieMachinePresentation, loop: NuxieMachineScreenLoop,
        shown: NuxieMachineShown = NuxieMachineShown(journey: 1, instance: 1), route: String = "screen",
        detents: [NuxieMachineDetent] = [], swipeDown: NuxieMachineSwipeWould? = nil,
        assets: NuxieMachineAssets = .ready
    ) -> (NuxieMachineSegmentController, NuxieMachineScreenViewController, UIWindow) {
        let presented = NuxieMachinePresented(shown: shown, route: route, presentation: presentation,
                                              detents: detents, swipeDown: swipeDown)
        let controller = NuxieMachineScreenViewController(presenting: presented, loop: loop, assets: assets)
        controller.additionalSafeAreaInsets = UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)
        let segment = NuxieMachineSegmentController(pages: [controller])
        return (segment, controller, window(segment))
    }

    /// One entry, the `instance`th, shown as `presentation`.
    private static func page(_ instance: UInt64, _ presentation: NuxieMachinePresentation,
                             swipeDown: NuxieMachineSwipeWould? = nil,
                             swipeBack: NuxieMachineSwipeWould? = nil) -> NuxieMachinePresented {
        NuxieMachinePresented(shown: NuxieMachineShown(journey: 1, instance: instance), route: "page\(instance)",
                              presentation: presentation, swipeDown: swipeDown, swipeBack: swipeBack)
    }

    /// A segment holding a page for each of `pages`, bottom first, the root
    /// of a window at a phone's size.
    @MainActor
    private static func segment(_ pages: [NuxieMachinePresented], loop: NuxieMachineScreenLoop)
        -> (NuxieMachineSegmentController, UIWindow) {
        let segment = NuxieMachineSegmentController(pages: pages.map {
            NuxieMachineScreenViewController(presenting: $0, loop: loop)
        })
        return (segment, window(segment))
    }

    /// A window at a phone's size with `root` as its root, shown and laid
    /// out, so a segment's page on top is in it.
    @MainActor
    private static func window(_ root: UIViewController) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = root
        window.isHidden = false
        window.layoutIfNeeded()
        return window
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
        let (_, controller, window) = Self.screen(presenting: .cover, loop: loop, shown: firstShown.shown,
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
    /// surface has the view's insets. Its segment is a navigation
    /// controller with no bar: a cover, or a first page shown as a push, is
    /// full screen with no swipe; a sheet a page sheet at the large detent
    /// with no grabber, which the person can swipe down.
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
        let segment = try XCTUnwrap(controller.navigationController as? NuxieMachineSegmentController,
                                    "a \(presentation) is not a page of a segment")
        XCTAssertTrue(segment.isNavigationBarHidden, "a \(presentation) shows a navigation bar")
        XCTAssertEqual(view.bounds.size, segment.view.bounds.size, "a \(presentation) does not fill its segment")
        switch presentation {
        case .sheet:
            XCTAssertEqual(segment.modalPresentationStyle, .pageSheet)
            XCTAssertFalse(segment.isModalInPresentation, "the person can swipe a sheet down")
            let sheet = try XCTUnwrap(segment.sheetPresentationController)
            if #available(iOS 16.0, *) {
                XCTAssertEqual(sheet.detents.map(\.identifier), [.large])
            }
            XCTAssertFalse(sheet.prefersGrabberVisible)
        default:
            XCTAssertEqual(segment.modalPresentationStyle, .fullScreen)
            XCTAssertTrue(segment.isModalInPresentation, "a cover has no swipe")
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

/// Every status the host was told, in order.
@MainActor
private final class HostHeard {
    var statuses: [NuxieMachineSheetStatus] = []
}

/// A byte source whose asks never answer on their own: each waits until it
/// is cancelled. It keeps the paths asked for, and those whose ask was
/// cancelled, in order.
private final class CancelledBytes: NuxieMachineByteSource, @unchecked Sendable {
    private let lock = NSLock()
    private var askedPaths: [String] = []
    private var cancelledPaths: [String] = []

    var asked: [String] { lock.withLock { askedPaths } }
    var cancelled: [String] { lock.withLock { cancelledPaths } }

    func bytes(for path: String) async throws -> Data {
        lock.withLock { askedPaths.append(path) }
        do {
            try await Task.sleep(nanoseconds: 3_600_000_000_000)
        } catch {
            lock.withLock { cancelledPaths.append(path) }
            throw error
        }
        throw NuxieMachineByteSourceFault.noFile(path)
    }
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
