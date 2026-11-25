#if os(iOS) && !targetEnvironment(macCatalyst)
import CoreGraphics
import Foundation
import XCTest
import NuxieMachine
import NuxieRuntime

/// What the edge shows is the record's presented stack, on a simulator with
/// no window, over `Fixtures/two-screens`: a cover, `first`, and a sheet,
/// `second`, each a Card with buttons that present the sheet ("Deeper"),
/// pop the top ("Back"), replace the top with the sheet ("Swap"), present
/// the sheet and pop it in one tap ("Blink"), present it and dismiss
/// everything in one tap ("Flash"), and close. Real pointers go in through
/// each presentation's own player; the buttons are found with text
/// recognition. After every delivery the edge holds exactly what the
/// session shows, by identity, each presentation with a player of its own.
final class PresentedStackEdgeTests: XCTestCase {
    /// A sheet presented over the cover is a second presentation with a
    /// player of its own; the cover's stays as it is. Back closes only the
    /// sheet.
    func testASecondScreenOverTheFirstIsItsOwnPresentationAndBackClosesOnlyIt() async throws {
        let run = try Stack()
        do {
            await run.edge.start(event: "opened", now: run.now)
            let started = await run.edge.stack
            XCTAssertEqual(started.map(\.route), ["first"])
            XCTAssertEqual(started.map(\.presentation), [.cover])
            let first = try XCTUnwrap(started.first).shown
            let firstPlayer = try await run.player(first)
            XCTAssertEqual(run.owner.shown.last, started, "the start tells the owner what is shown")

            var written = await run.edge.log.count
            try await run.tap("Deeper", on: first)
            let deeper = await run.edge.stack
            XCTAssertEqual(deeper.map(\.route), ["first", "second"])
            XCTAssertEqual(deeper.map(\.presentation), [.cover, .sheet])
            XCTAssertEqual(deeper[0].shown, first, "the cover is the same presentation")
            let second = deeper[1].shown
            XCTAssertEqual(second.journey, first.journey)
            XCTAssertNotEqual(second.instance, first.instance, "the sheet is its own instance")
            let keptPlayer = try await run.player(first)
            XCTAssertTrue(keptPlayer === firstPlayer, "the cover's player was opened again")
            let secondPlayer = try await run.player(second)
            XCTAssertFalse(secondPlayer === firstPlayer, "the sheet has no player of its own")
            var since = await Array(run.edge.log.dropFirst(written))
            XCTAssertEqual(since.filter(Self.isSync), [.opened(second)], "\(since)")
            XCTAssertEqual(run.owner.shown.last, deeper, "the tap tells the owner what is shown")

            written = await run.edge.log.count
            try await run.tap("Back", on: second)
            let back = await run.edge.stack
            XCTAssertEqual(back.map(\.shown), [first])
            since = await Array(run.edge.log.dropFirst(written))
            XCTAssertEqual(since.filter(Self.isSync), [.gone(second)], "\(since)")
            let gone = await run.edge.screen(for: second)
            XCTAssertNil(gone, "the popped sheet still draws")
            let stays = try await run.player(first)
            XCTAssertTrue(stays === firstPlayer, "the cover's player changed")
            let noFault = await run.edge.fault
            XCTAssertNil(noFault)
            try await run.close()
        } catch {
            try? await run.close()
            throw error
        }
    }

    /// A swipe that closes the sheet is the person's close: the machine pops
    /// it and the cover stays. A second close for the same sheet goes to no
    /// one.
    func testASwipeClosesTheSheetAndTheCoverStays() async throws {
        let run = try Stack()
        do {
            await run.edge.start(event: "opened", now: run.now)
            let first = try await run.top()
            try await run.tap("Deeper", on: first)
            let second = try await run.top()
            await run.edge.closed(second, now: run.advance())
            let after = await run.edge.stack
            XCTAssertEqual(after.map(\.shown), [first])
            XCTAssertNil(run.owner.dismissals.first, "a swipe tells no dismissal")

            let written = await run.edge.log.count
            await run.edge.closed(second, now: run.advance())
            let late = await Array(run.edge.log.dropFirst(written))
            XCTAssertEqual(late, [.droppedClose(second)])
            let still = await run.edge.stack
            XCTAssertEqual(still.map(\.shown), [first])
            let noFault = await run.edge.fault
            XCTAssertNil(noFault)
            try await run.close()
        } catch {
            try? await run.close()
            throw error
        }
    }

    /// A replace takes the cover away and shows the sheet in its place: a
    /// new presentation, opened from nothing, and the cover's player freed.
    func testReplaceShowsANewPresentationInTheOldOnesPlace() async throws {
        let run = try Stack()
        do {
            await run.edge.start(event: "opened", now: run.now)
            let first = try await run.top()
            let written = await run.edge.log.count
            try await run.tap("Swap", on: first)
            let swapped = await run.edge.stack
            XCTAssertEqual(swapped.map(\.route), ["second"])
            let second = try XCTUnwrap(swapped.first).shown
            XCTAssertNotEqual(second, first)
            let since = await Array(run.edge.log.dropFirst(written))
            XCTAssertEqual(since.filter(Self.isSync), [.gone(first), .opened(second)], "\(since)")
            let old = await run.edge.screen(for: first)
            XCTAssertNil(old, "the replaced cover still draws")
            _ = try await run.player(second)
            let noFault = await run.edge.fault
            XCTAssertNil(noFault)
            try await run.close()
        } catch {
            try? await run.close()
            throw error
        }
    }

    /// A sheet presented and popped in one tap is never opened, and the
    /// cover under it is untouched; the owner is told of no dismissal, and
    /// every report shows the cover alone.
    func testASheetPresentedAndPoppedInOneTapIsNeverOpened() async throws {
        let run = try Stack()
        do {
            await run.edge.start(event: "opened", now: run.now)
            let first = try await run.top()
            let firstPlayer = try await run.player(first)
            let written = await run.edge.log.count
            let reports = run.owner.reports.count
            try await run.tap("Blink", on: first)
            let after = await run.edge.stack
            XCTAssertEqual(after.map(\.shown), [first])
            let since = await Array(run.edge.log.dropFirst(written))
            XCTAssertTrue(since.contains { if case .present("second", _, _) = $0 { true } else { false } },
                          "the machine did not present the sheet: \(since)")
            XCTAssertEqual(since.filter(Self.isSync), [], "\(since)")
            let told = Array(run.owner.reports.dropFirst(reports))
            for report in told {
                guard case .delivered(let shown, let rows) = report else { return XCTFail("\(told)") }
                XCTAssertEqual(shown.map(\.shown), [first], "\(told)")
                XCTAssertNil(report.dismissal, "\(told)")
                XCTAssertFalse(rows.contains { if case .dismiss = $0 { true } else { false } }, "\(told)")
            }
            let stays = try await run.player(first)
            XCTAssertTrue(stays === firstPlayer)
            try await run.close()
        } catch {
            try? await run.close()
            throw error
        }
    }

    /// A sheet presented and dismissed with everything in one tap is never
    /// opened; the cover is closed once, and the owner hears the dismissal
    /// and the end, with nothing shown.
    func testASheetPresentedAndDismissedInOneTapIsNeverOpened() async throws {
        let run = try Stack()
        do {
            await run.edge.start(event: "opened", now: run.now)
            let first = try await run.top()
            let written = await run.edge.log.count
            try await run.tap("Flash", on: first)
            let after = await run.edge.stack
            XCTAssertEqual(after, [])
            let since = await Array(run.edge.log.dropFirst(written))
            XCTAssertEqual(since.filter(Self.isSync), [.gone(first)], "\(since)")
            guard case .delivered(let shown, let rows)? = run.owner.reports.last else {
                return XCTFail("\(run.owner.reports)")
            }
            XCTAssertEqual(shown, [])
            XCTAssertEqual(rows.filter { if case .wakeAt = $0 { false } else { true } },
                           [.dismiss(reason: "flashed"), .end(.finished)])
            let open = try await run.edge.recordOpen()
            XCTAssertFalse(open)
            try await run.close()
        } catch {
            try? await run.close()
            throw error
        }
    }

    /// A Journey that ends and a new one that starts: the new Journey's
    /// cover has the same instance number and is still a new presentation,
    /// told apart by its Journey, with a player of its own. The old one's
    /// identity draws nothing and takes no close.
    func testAJourneyThatEndsAndANewOneStartingIsANewPresentation() async throws {
        let run = try Stack()
        do {
            await run.edge.start(event: "opened", now: run.now)
            let first = try await run.top()
            try await run.tap("Close", on: first)
            let ended = await run.edge.stack
            XCTAssertEqual(ended, [])
            XCTAssertEqual(run.owner.dismissals, [.machine(reason: "closed")])

            let written = await run.edge.log.count
            await run.edge.start(event: "opened", now: run.advance())
            let again = try await run.top()
            XCTAssertEqual(again.instance, first.instance, "the new record numbers its instances afresh")
            XCTAssertEqual(again.journey, first.journey + 1, "the new Journey is told apart")
            let since = await Array(run.edge.log.dropFirst(written))
            XCTAssertEqual(since.filter(Self.isSync), [.opened(again)], "\(since)")
            let old = await run.edge.screen(for: first)
            XCTAssertNil(old, "the ended Journey's presentation still draws")
            _ = try await run.player(again)

            let before = await run.edge.log.count
            await run.edge.closed(first, now: run.advance())
            let stale = await Array(run.edge.log.dropFirst(before))
            XCTAssertEqual(stale, [.droppedClose(first)])
            let untouched = await run.edge.stack
            XCTAssertEqual(untouched.map(\.shown), [again])
            let noFault = await run.edge.fault
            XCTAssertNil(noFault)
            try await run.close()
        } catch {
            try? await run.close()
            throw error
        }
    }

    /// A fault closes every presentation, once, from the top, and the owner
    /// hears the fault alone. A stopped edge delivers nothing more.
    func testAFaultClosesEveryPresentationOnceFromTheTop() async throws {
        let run = try Stack()
        do {
            await run.edge.start(event: "opened", now: run.now)
            let first = try await run.top()
            try await run.tap("Deeper", on: first)
            let second = try await run.top()
            let written = await run.edge.log.count
            let reports = run.owner.reports.count
            // The top player closed under the edge: its next step fails.
            let top = await run.edge.screen(for: second)
            try await XCTUnwrap(top).close()
            await run.edge.frame(elapsedSeconds: CounterDriverEdgeTests.tick, now: run.advance())
            let recorded = await run.edge.fault
            let fault = try XCTUnwrap(recorded)
            XCTAssertEqual(fault.code, "engine.step")
            let since = await Array(run.edge.log.dropFirst(written))
            XCTAssertEqual(since.filter(Self.isSync), [.gone(second), .gone(first)], "\(since)")
            let after = await run.edge.stack
            XCTAssertEqual(after, [])
            XCTAssertEqual(Array(run.owner.reports.dropFirst(reports)), [.fault(fault)])
            await run.edge.frame(elapsedSeconds: CounterDriverEdgeTests.tick, now: run.advance())
            XCTAssertEqual(run.owner.reports.count, reports + 1, "a stopped edge told more")
            try await run.close()
        } catch {
            try? await run.close()
            throw error
        }
    }

    /// Pointers for a presentation the edge no longer holds go to no one,
    /// and the presentation shown now takes nothing from them.
    func testATouchOnAPoppedSheetGoesToNoOne() async throws {
        let run = try Stack()
        do {
            await run.edge.start(event: "opened", now: run.now)
            let first = try await run.top()
            try await run.tap("Deeper", on: first)
            let second = try await run.top()
            let sheet = try await run.look(second, name: "sheet")
            let back = try sheet.center(of: "Back")
            try await run.tap("Back", on: second)

            let written = await run.edge.log.count
            await run.edge.frame(pointers: run.press(at: back), on: second, elapsedSeconds: CounterDriverEdgeTests.tick,
                                 now: run.advance())
            let since = await Array(run.edge.log.dropFirst(written))
            XCTAssertEqual(since, [.droppedTouches(second)])
            let still = await run.edge.stack
            XCTAssertEqual(still.map(\.shown), [first], "the touch reached the cover")
            try await run.close()
        } catch {
            try? await run.close()
            throw error
        }
    }

    /// A tap on the sheet's Bump adds one to the root's `taps`, which the
    /// cover under the sheet shows too. The sheet's round writes for the
    /// cover, and the cover draws the new count in the frame the tap ran,
    /// with no further frame or touch. Then both Screens go quiet: nothing
    /// waits for a frame, and neither engine keeps going.
    func testATapOnTheSheetThatChangesWhatTheCoverShowsIsDrawnOnTheCoverInTheSameFrame() async throws {
        let run = try Stack()
        do {
            await run.edge.start(event: "opened", now: run.now)
            let first = try await run.top()
            let cover = try await run.player(first)
            try await run.tap("Deeper", on: first)
            let second = try await run.top()
            XCTAssertNotEqual(second, first)
            let before = try await run.look(first, name: "cover-before-bump")
            XCTAssertEqual(try Self.taps(before), "Taps: 0")

            try await run.tap("Bump", on: second)
            let counted = try await run.edge.slot("taps")
            XCTAssertEqual(counted, .number(1))
            // The cover is read as the tap's frame left it: no frame since.
            let after = try await DrawnFrame.read(cover, reported: [], name: "stack-cover-after-bump")
            XCTAssertEqual(try Self.taps(after), "Taps: 1", "the cover still shows the count from before the tap")
            let waiting = await run.edge.waitingForFrame()
            XCTAssertFalse(waiting, "the tap's frame left work waiting for another")

            var keepGoing = true
            for _ in 0..<120 where keepGoing {
                keepGoing = await run.edge.frame(elapsedSeconds: CounterDriverEdgeTests.tick, now: run.advance()).keepGoing
            }
            XCTAssertFalse(keepGoing, "the Screens never went quiet")
            let quiet = await run.edge.waitingForFrame()
            XCTAssertFalse(quiet, "a quiet stack still waits for a frame")
            let sheet = try await DrawnFrame.read(try await run.player(second), reported: [], name: "stack-sheet-quiet")
            XCTAssertEqual(try Self.taps(sheet), "Taps: 1")
            let noFault = await run.edge.fault
            XCTAssertNil(noFault)
            try await run.close()
        } catch {
            try? await run.close()
            throw error
        }
    }

    /// The line of `frame` that shows the count of taps.
    private static func taps(_ frame: DrawnFrame) throws -> String {
        try XCTUnwrap(frame.lines.first { $0.text.hasPrefix("Taps") }?.text, "no count among \(frame.lines.map(\.text))")
    }

    private static func isSync(_ entry: NuxieMachineEdgeEntry) -> Bool {
        switch entry {
        case .opened, .gone: return true
        default: return false
        }
    }
}

/// A fresh session of the two-screens plan on the driver path, its clock,
/// and what its owner heard.
private final class Stack {
    let edge: NuxieMachineEdge
    let owner = StackOwner()
    private(set) var now: Int64 = 9 * 3_600_000
    /// The presentations laid out at a phone's size so far.
    private var laidOut: Set<NuxieMachineShown> = []
    private var drawn = 0

    init() throws {
        let owner = self.owner
        edge = try NuxieMachineEdge(plan: Self.plan(), store: NuxieMachineStandInStore(),
                                    onReport: { owner.heard($0) })
    }

    func advance() -> Int64 {
        now += 1000
        return now
    }

    /// The presentation on top.
    func top() async throws -> NuxieMachineShown {
        let shown = await edge.shown
        return try XCTUnwrap(shown, "nothing is shown")
    }

    /// The player of the presentation `shown`, laid out at a phone's size
    /// in points and sized for a frame drawn at twice that, once, as a
    /// Screen's view does before its first step.
    func player(_ shown: NuxieMachineShown) async throws -> NuxieNativeRuntime {
        let screen = await edge.screen(for: shown)
        let player = try XCTUnwrap(screen, "the edge holds no player for \(shown)")
        if !laidOut.contains(shown) {
            try await player.setLayoutSize(width: Float(CounterDriverEdgeTests.width),
                                           height: Float(CounterDriverEdgeTests.height))
            _ = try await player.resize(pixelWidth: UInt32(2 * CounterDriverEdgeTests.width),
                                        pixelHeight: UInt32(2 * CounterDriverEdgeTests.height))
            laidOut.insert(shown)
        }
        return player
    }

    /// One frame with no touch, then the Screen of `shown` read.
    func look(_ shown: NuxieMachineShown, name: String) async throws -> DrawnFrame {
        let player = try await player(shown)
        await edge.frame(elapsedSeconds: CounterDriverEdgeTests.tick, now: advance())
        let fault = await edge.fault
        XCTAssertNil(fault, "the frame faulted")
        drawn += 1
        return try await DrawnFrame.read(player, reported: [], name: "stack-\(drawn)-\(name)")
    }

    /// A press and release at `point`, in one step.
    func press(at point: CGPoint) -> [NuxieNativePointerEvent] {
        [.down, .up].map { NuxieNativePointerEvent(kind: $0, x: Float(point.x), y: Float(point.y)) }
    }

    /// Tap the button that shows `word` on the Screen of `shown`. Text
    /// recognition reads without language correction and now and then
    /// reads a stray mark beside a label ("BlinkR"), so with no line that is
    /// the word alone, the one line that starts with it is the button.
    func tap(_ word: String, on shown: NuxieMachineShown) async throws {
        let seen = try await look(shown, name: word)
        let point: CGPoint
        if let exact = try? seen.center(of: word) {
            point = exact
        } else {
            let starting = seen.lines.filter { $0.text.hasPrefix(word) }
            guard starting.count == 1, let line = starting.first else {
                throw DrawnFrame.Missing(line: word, found: seen.lines.map(\.text))
            }
            point = CGPoint(x: line.box.midX, y: line.box.midY)
        }
        await edge.frame(pointers: press(at: point), on: shown,
                         elapsedSeconds: CounterDriverEdgeTests.tick, now: advance())
        let fault = await edge.fault
        XCTAssertNil(fault, "the tap on \(word) faulted")
    }

    func close() async throws {
        try await edge.close()
    }

    /// The two-screens fixture's two program files, as the test bundle
    /// carries them; the folder's `main.test.nux` is not one of them.
    static func plan() throws -> NuxieMachinePlanSource {
        func text(_ name: String) throws -> String {
            let url = try XCTUnwrap(Bundle(for: Stack.self).url(
                forResource: name, withExtension: "nux", subdirectory: "two-screens"),
                "the test bundle carries two-screens/\(name).nux")
            return try String(contentsOf: url, encoding: .utf8)
        }
        return NuxieMachinePlanSource(
            files: [NuxieMachineSourceFile(path: "main.nux", text: try text("main")),
                    NuxieMachineSourceFile(path: "card.nux", text: try text("card"))],
            root: "main", app: "app", experience: "stack", version: 1)
    }
}

/// The edge's owner: the reports it was told, one per delivery that did
/// something for it.
private final class StackOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var heardReports: [NuxieMachineEdgeReport] = []

    var reports: [NuxieMachineEdgeReport] {
        lock.withLock { heardReports }
    }

    var dismissals: [NuxieMachineEdgeDismissal] {
        reports.compactMap(\.dismissal)
    }

    /// What each report said is shown, for the reports that are not faults.
    var shown: [[NuxieMachinePresented]] {
        reports.compactMap { report in
            if case .delivered(let shown, _) = report { return shown }
            return nil
        }
    }

    func heard(_ report: NuxieMachineEdgeReport) {
        lock.withLock { heardReports.append(report) }
    }
}
#endif
