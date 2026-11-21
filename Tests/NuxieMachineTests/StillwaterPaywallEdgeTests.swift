#if os(iOS) && !targetEnvironment(macCatalyst)
import CoreGraphics
import Foundation
import ImageIO
import Metal
import QuartzCore
import XCTest
import NuxieMachine
import NuxieRuntime

/// Stillwater's paywall on a simulator, with no window: the machine compiled
/// from Stillwater's four `.nux` files drives the published Screen through
/// the engine and Metal, real pointers go in, and the frames are read back.
/// The script and what every cell holds are the parent repository's Mac
/// play test of the same Screen (`stillwater_paywall_tests`): start, a
/// pointer on Monthly, on the buy button (the store answers `failed`), on
/// "About the trial", then "Not now", or a swipe down in a second run.
///
/// Pixel checks compare a region of one frame with the same region of the
/// frame before. A region "changes" when at least `changedAtLeast` of its
/// pixels move by more than `difference` in some channel, and "holds" when
/// at most `steadyAtMost` do: a selection ring, a dot, a dim or a line of
/// text moves far more pixels than that, and antialiasing far fewer.
final class StillwaterPaywallEdgeTests: XCTestCase {
    // MARK: The Screen's known layout

    /// Boxes on the 390 by 844 Screen, `[x0, y0, x1, y1]`, worked out from
    /// its CSS alone, as the Mac play test's `BOXES` are. The error line and
    /// the terms line keep their slots shown or not, so no box moves.
    private enum Box {
        static let title: [Int] = [24, 134, 366, 210]
        static let annual: [Int] = [24, 250, 366, 322]
        static let monthly: [Int] = [24, 334, 366, 406]
        static let buy: [Int] = [24, 434, 366, 490]
        static let error: [Int] = [24, 490, 366, 542]
        static let close: [Int] = [24, 666, 366, 714]
        static let restore: [Int] = [24, 718, 189, 762]
        static let details: [Int] = [201, 718, 366, 762]
        static let terms: [Int] = [24, 770, 366, 810]
    }

    private static let width = 390
    private static let height = 844
    private static let difference = 48
    private static let changedAtLeast = 150
    private static let steadyAtMost = 24
    private static let edge = 2

    /// 09:00 on day zero, in milliseconds, as the Mac test starts.
    private static let nine: Int64 = 9 * 3_600_000
    private static let hour: Int64 = 3_600_000
    /// One frame at 60 frames a second.
    private static let tick: Float = 1.0 / 60.0

    // MARK: The script

    func testAPointerOnAPlanCardSelectsItThroughTheMachine() async throws {
        let run = try await Run()
        do {
            // 1. The start presents the paywall as a sheet, and after one
            // frame every cell holds what the machine wrote.
            await run.edge.start(event: "onboarding_completed", now: run.now)
            let presented = await run.edge.log.compactMap { entry -> String? in
                if case .present(let route, _, let presentation) = entry, presentation == .sheet { return route }
                return nil
            }
            XCTAssertEqual(presented, ["paywall"], "the start presents the paywall as a sheet")
            try await run.settle()
            let cells = try await run.cells()
            XCTAssertEqual(cells["title_text"], .bytes(Data("Ten quiet minutes,\nevery day.".utf8)))
            XCTAssertEqual(cells["annual_selected"], .bool(true))
            XCTAssertEqual(cells["annual_price"], .bytes(Data("$59.99".utf8)))
            XCTAssertEqual(cells["monthly_selected"], .bool(false))
            XCTAssertEqual(cells["monthly_price"], .bytes(Data("$9.99".utf8)))
            XCTAssertEqual(cells["buy_label"], .bytes(Data("Continue".utf8)))
            XCTAssertEqual(cells["buy_busy"], .bool(false))
            XCTAssertEqual(cells["error_visible"], .bool(false))
            XCTAssertEqual(cells["terms_visible"], .bool(false))
            let start = try await run.frame("start")

            // 2. A pointer on the Monthly card: one `tap_monthly`, the
            // record's plan is monthly, and both cards look different.
            var written = await run.edge.log.count
            let monthlyTap = try await run.tap(Box.monthly)
            XCTAssertEqual(monthlyTap, ["tap_monthly"])
            let plan = try await run.edge.slot("plan")
            XCTAssertEqual(plan, .enumeration("monthly"))
            let monthlyWrites = await run.writes(since: written)
            XCTAssertEqual(monthlyWrites.filter { $0.cell == "monthly_selected" }.map(\.value), [.bool(true)])
            XCTAssertEqual(monthlyWrites.filter { $0.cell == "annual_selected" }.map(\.value), [.bool(false)])
            let monthly = try await run.frame("monthly")
            XCTAssertTrue(Self.changes(start, monthly, Box.monthly), "the Monthly card looks the same")
            XCTAssertTrue(Self.changes(start, monthly, Box.annual), "the Yearly card looks the same")
            XCTAssertTrue(Self.holds(start, monthly, outside: [Box.annual, Box.monthly]),
                          "something outside the two cards changed")

            // 3. A pointer on the buy button: one awaited purchase reaches
            // the store, which answers `failed`; the button is busy, then not,
            // and the error line shows. The answer is applied after the step
            // of the first frame that begins after it arrived, so the frame
            // after the tap draws the busy button whenever the store answers.
            // Once it has answered, two more frames apply and show it.
            written = await run.edge.log.count
            let buyTap = try await run.tap(Box.buy, framesAfter: 1)
            XCTAssertEqual(buyTap, ["tap_buy"])
            let buying = try await run.frame("buying")
            await run.edge.storeAnswered()
            try await run.settle(frames: 2)
            let failed = try await run.frame("failed")
            let calls = run.store.calls
            XCTAssertEqual(calls.map(\.externName), ["purchase"])
            XCTAssertEqual(calls.map(\.awaited), [true])
            let answered = await run.edge.log.dropFirst(written).compactMap { entry -> String? in
                if case .answer(_, let outcome) = entry { return outcome }
                return nil
            }
            XCTAssertEqual(answered, ["failed"])
            let buyWrites = await run.writes(since: written)
            XCTAssertEqual(buyWrites.filter { $0.cell == "buy_busy" }.map(\.value), [.bool(true), .bool(false)])
            XCTAssertEqual(buyWrites.filter { $0.cell == "error_visible" }.map(\.value), [.bool(true)])
            XCTAssertTrue(Self.changes(monthly, failed, Box.error), "the error line does not show")
            XCTAssertTrue(Self.holds(monthly, failed, Box.buy), "the buy button stays dimmed")
            XCTAssertTrue(Self.changes(monthly, buying, Box.buy), "the buy button never looks busy")

            // 4. A pointer on "About the trial": the terms line shows.
            let detailsTap = try await run.tap(Box.details)
            XCTAssertEqual(detailsTap, ["tap_details"])
            let details = try await run.frame("details")
            XCTAssertTrue(Self.changes(failed, details, Box.terms), "the terms line does not show")

            // 5. A pointer on "Not now": the paywall is dismissed, the record
            // stays open, and the evening offer's wake is recorded.
            written = await run.edge.log.count
            let closeTap = try await run.tap(Box.close)
            XCTAssertEqual(closeTap, ["tap_close"])
            let closing = await Array(run.edge.log.dropFirst(written))
            XCTAssertTrue(closing.contains(.dismiss(reason: "paywall_closed")), "\(closing)")
            XCTAssertTrue(closing.contains(.wakeAt(18 * Self.hour)), "\(closing)")
            XCTAssertEqual(run.owner.dismissals.count, 1, "the owner hears one dismissal")
            XCTAssertEqual(run.owner.dismissals, [.machine(reason: "paywall_closed")])
            let stillOpen = try await run.edge.recordOpen()
            XCTAssertTrue(stillOpen, "the record waits for the evening offer")
            let noFault = await run.edge.fault
            XCTAssertNil(noFault)
            XCTAssertEqual(run.store.calls.count, 1, "one call in the whole script")
            try await run.close()
        } catch {
            try? await run.close()
            throw error
        }
    }

    func testASwipeDownEndsTheRecord() async throws {
        let run = try await Run()
        do {
            await run.edge.start(event: "onboarding_completed", now: run.now)
            try await run.settle()
            var tapped = try await run.tap(Box.monthly)
            tapped += try await run.tap(Box.buy)
            // The store's answer is applied in the frames of the next tap.
            await run.edge.storeAnswered()
            tapped += try await run.tap(Box.details)
            XCTAssertEqual(tapped, ["tap_monthly", "tap_buy", "tap_details"])
            let written = await run.edge.log.count
            let current = await run.edge.shown
            let shown = try XCTUnwrap(current)
            await run.edge.closed(shown, now: run.advance())
            let closing = await Array(run.edge.log.dropFirst(written))
            XCTAssertEqual(closing.filter {
                if case .pop = $0 { return true }
                if case .end = $0 { return true }
                return false
            }, [.pop(instance: 2), .end(reason: .finished, fault: nil)])
            let open = try await run.edge.recordOpen()
            XCTAssertFalse(open, "a swipe down ends the record")
            let noFault = await run.edge.fault
            XCTAssertNil(noFault)
            XCTAssertTrue(run.owner.dismissals.isEmpty, "a swipe down has already closed the sheet")
            try await run.close()
        } catch {
            try? await run.close()
            throw error
        }
    }

    /// A reported event the plan does not handle ends in the one fault path:
    /// the edge stops, records the code, and tells its owner to dismiss. A
    /// stopped edge steps nothing more.
    func testAnEventThePlanDoesNotHandleFaults() async throws {
        let run = try await Run()
        do {
            await run.edge.start(event: "onboarding_completed", now: run.now)
            try await run.settle()
            await run.edge.handleReported("tap_nothing", now: run.advance())
            let recorded = await run.edge.fault
            let fault = try XCTUnwrap(recorded)
            XCTAssertEqual(fault.code, "machine.unknown_object")
            XCTAssertEqual(run.owner.dismissals.count, 1, "the owner hears one dismissal")
            XCTAssertEqual(run.owner.dismissals, [.fault(fault)])
            let afterFault = try await run.tap(Box.monthly)
            XCTAssertEqual(afterFault, [], "a stopped edge steps nothing")
            await run.edge.handleReported("tap_nothing", now: run.advance())
            XCTAssertEqual(run.owner.dismissals.count, 1, "a stopped edge tells nothing more")
            try await run.close()
        } catch {
            try? await run.close()
            throw error
        }
    }

    /// A store asked for an extern it cannot perform ends in the same fault
    /// path. "Restore purchases" calls `restore`, which the stand-in store
    /// does not answer.
    func testAStoreAskedForAnUnknownExternFaults() async throws {
        let run = try await Run()
        do {
            await run.edge.start(event: "onboarding_completed", now: run.now)
            try await run.settle()
            let restoreTap = try await run.tap(Box.restore)
            XCTAssertEqual(restoreTap, ["tap_restore"])
            // The store's refusal arrives as an answer, which the next frame
            // delivers.
            await run.edge.storeAnswered()
            try await run.settle(frames: 1)
            let recorded = await run.edge.fault
            let fault = try XCTUnwrap(recorded)
            XCTAssertEqual(fault.code, "store.unknown-extern")
            XCTAssertEqual(run.store.calls.map(\.externName), ["restore"])
            XCTAssertEqual(run.owner.dismissals.count, 1, "the owner hears one dismissal")
            XCTAssertEqual(run.owner.dismissals, [.fault(fault)])
            let afterFault = try await run.tap(Box.monthly)
            XCTAssertEqual(afterFault, [], "a stopped edge steps nothing")
            XCTAssertEqual(run.owner.dismissals.count, 1, "a stopped edge tells nothing more")
            try await run.close()
        } catch {
            try? await run.close()
            throw error
        }
    }

    /// A Screen whose view has an `if` with an `else`: presenting it shows
    /// the `else`, a write the machine's C interface cannot carry (the
    /// interface crate's `tests/refusals.rs`, its route renamed so the
    /// Stillwater Screen is its artwork). The header documents what the
    /// call leaves: the effects up to that write, a dismiss with no reason,
    /// and an end whose fault is "engine.failed".
    private static let showsARegion = """
        component App
          routes
            paywall  Card(on=false)  sheet
          entry
            on event "go"
            do go(paywall)

        component Card
          props
            on: boolean
          view
            column
              text "Hi" id="label"
              if on
                box id="yes"
              else
                box id="no"

        """

    /// A write the machine cannot carry ends in the one fault path, and the
    /// owner hears that fault alone: not the machine's dismiss row before
    /// it. The record keeps both rows.
    func testAWriteTheMachineCannotCarryTellsOneFaultDismissal() async throws {
        let plan = NuxieMachinePlanSource(
            files: [NuxieMachineSourceFile(path: "main.nux", text: Self.showsARegion)],
            root: "main", app: "app", experience: "card", version: 1)
        let run = try await Run(plan: plan)
        do {
            await run.edge.start(event: "go", now: run.now)
            let log = await run.edge.log
            XCTAssertTrue(log.contains { entry in
                if case .present("paywall", _, .sheet) = entry { return true }
                return false
            }, "\(log)")
            XCTAssertEqual(Array(log.suffix(2)), [.dismiss(reason: nil), .end(reason: .fault, fault: "engine.failed")])
            let recorded = await run.edge.fault
            let fault = try XCTUnwrap(recorded)
            XCTAssertEqual(fault.code, "engine.failed")
            XCTAssertEqual(run.owner.dismissals.count, 1, "the owner hears one dismissal")
            XCTAssertEqual(run.owner.dismissals, [.fault(fault)])
            let open = try await run.edge.recordOpen()
            XCTAssertFalse(open, "the fault ended the session")

            // A stopped edge takes nothing more and tells nothing more.
            let presented = try XCTUnwrap(Self.presentedInstance(log))
            await run.edge.start(event: "go", now: run.advance())
            await run.edge.closed(NuxieMachineShown(journey: 1, instance: presented), now: run.advance())
            await run.edge.handleReported("tap_label", now: run.advance())
            try await run.settle()
            let after = await run.edge.log
            XCTAssertEqual(after, log, "a stopped edge records nothing more")
            XCTAssertEqual(run.owner.dismissals.count, 1, "a stopped edge tells nothing more")
            try await run.close()
        } catch {
            try? await run.close()
            throw error
        }
    }

    // MARK: Deliveries that meet

    /// A swipe down while the store has not answered the purchase is a
    /// normal close, as the machine's rows say: it pops the paywall with no
    /// `dismiss` row (the gesture has already closed the sheet) and asks for
    /// no wake, and the record stays open for the purchase. The owner hears no dismissal and
    /// nothing faults. The store's answer, released after, goes to the
    /// session, whose rows end the record; it tells nothing.
    func testASwipeDownWhileThePurchaseWaitsIsANormalClose() async throws {
        let run = try await Run(holdingStore: true)
        do {
            await run.edge.start(event: "onboarding_completed", now: run.now)
            try await run.settle()
            let buyTap = try await run.tap(Box.buy)
            XCTAssertEqual(buyTap, ["tap_buy"])
            let written = await run.edge.log.count
            let current = await run.edge.shown
            let shown = try XCTUnwrap(current)
            await run.edge.closed(shown, now: run.advance())
            let closing = await Array(run.edge.log.dropFirst(written))
            let whole = await run.edge.log
            let presented = try XCTUnwrap(Self.presentedInstance(whole))
            XCTAssertEqual(closing, [.pop(instance: presented), .wakeAt(nil), .gone(shown)])
            let waiting = try await run.edge.recordOpen()
            XCTAssertTrue(waiting, "the record waits for the purchase")
            let noFault = await run.edge.fault
            XCTAssertNil(noFault)
            XCTAssertEqual(run.owner.dismissals, [], "the machine's rows hold no dismiss: the sheet is already closed")

            // The store answers after the close.
            run.store.release()
            await run.edge.storeAnswered()
            let beforeAnswer = await run.edge.log.count
            try await run.settle(frames: 2)
            let late = await Array(run.edge.log.dropFirst(beforeAnswer))
            let call = try XCTUnwrap(run.store.calls.first)
            XCTAssertEqual(call.externName, "purchase")
            XCTAssertEqual(late, [.answer(call.id, outcome: "failed"), .note(.ended),
                                  .end(reason: .finished, fault: nil)])
            let open = try await run.edge.recordOpen()
            XCTAssertFalse(open, "the answer ends the record")
            let stillNoFault = await run.edge.fault
            XCTAssertNil(stillNoFault)
            XCTAssertEqual(run.owner.dismissals, [], "the answer tells nothing")
            XCTAssertEqual(run.store.calls.count, 1)
            try await run.close()
        } catch {
            run.store.release()
            try? await run.close()
            throw error
        }
    }

    /// A Screen whose `close` dismisses and exits while the `restore` call
    /// it started has not been answered. Its route is renamed so the
    /// Stillwater Screen is its artwork, and its buttons hold no state, so
    /// it writes no cell.
    private static let leavesWhileRestoring = """
        use restore from "nuxie/store"

        component App
          routes
            paywall  Card  sheet
              restore=restore_purchases
              close=leave
          entry
            on event "go"
            do go(paywall)

          action restore_purchases
            restore(completed=leave)

          action leave
            dismiss("left")
            exit

        component Card
          props
            restore: action
            close: action
          view
            column
              button id="restore" press=restore
                text "Restore purchases"
              button id="close" press=close
                text "Not now"

        """

    /// An answer that arrives after its record ended is dropped: the
    /// machine dropped the call when the record ended, so it is recorded as
    /// dropped, applies nothing, tells nothing and is no fault, even when
    /// the store failed the call.
    func testAnAnswerAfterTheRecordEndedIsDropped() async throws {
        let plan = NuxieMachinePlanSource(
            files: [NuxieMachineSourceFile(path: "main.nux", text: Self.leavesWhileRestoring)],
            root: "main", app: "app", experience: "leaves", version: 1)
        let run = try await Run(plan: plan, holdingStore: true)
        do {
            await run.edge.start(event: "go", now: run.now)
            try await run.settle()
            await run.edge.handleReported("tap_restore", now: run.advance())
            await run.edge.handleReported("tap_close", now: run.advance())
            let open = try await run.edge.recordOpen()
            XCTAssertFalse(open, "leaving ends the record")
            XCTAssertEqual(run.owner.dismissals, [.machine(reason: "left")], "the owner hears one dismissal")

            // The stand-in store fails `restore`, after the record ended.
            run.store.release()
            await run.edge.storeAnswered()
            let beforeAnswer = await run.edge.log.count
            try await run.settle(frames: 2)
            let late = await Array(run.edge.log.dropFirst(beforeAnswer))
            let call = try XCTUnwrap(run.store.calls.first)
            XCTAssertEqual(call.externName, "restore")
            XCTAssertEqual(late, [.dropped(call.id, outcome: nil)])
            let noFault = await run.edge.fault
            XCTAssertNil(noFault, "a late answer is no fault")
            XCTAssertEqual(run.owner.dismissals, [.machine(reason: "left")], "a late answer tells nothing")
            try await run.close()
        } catch {
            run.store.release()
            try? await run.close()
            throw error
        }
    }

    private static let leavesPlan = NuxieMachinePlanSource(
        files: [NuxieMachineSourceFile(path: "main.nux", text: leavesWhileRestoring)],
        root: "main", app: "app", experience: "leaves", version: 1)

    /// An answer belongs to the record that issued its call, not to the
    /// record open when it arrives. A store refusal of the first record's
    /// `restore`, released after that record ended and a second started,
    /// is dropped.
    func testARefusalForAnEndedRecordLeavesTheNextRecordAlone() async throws {
        try await checkAnAnswerForAnEndedRecord(answering: [:], dropped: nil)
    }

    /// The same with a successful awaited answer: it is dropped, not handed
    /// to the second record (whose machine would answer `unknown_call`).
    func testAnAnswerForAnEndedRecordLeavesTheNextRecordAlone() async throws {
        try await checkAnAnswerForAnEndedRecord(answering: ["restore": "completed"], dropped: "completed")
    }

    /// Hold `restore`, close (the record ends), start `go` again (a second
    /// record), then release the store. The second record's showing is
    /// untouched, its owner hears nothing for it, the log has one dropped
    /// entry for the old call, nothing faults, and a tap on the second
    /// record is still handled.
    private func checkAnAnswerForAnEndedRecord(answering: [String: String], dropped outcome: String?) async throws {
        let run = try await Run(plan: Self.leavesPlan, holdingStore: true, answering: answering)
        do {
            await run.edge.start(event: "go", now: run.now)
            try await run.settle()
            await run.edge.handleReported("tap_restore", now: run.advance())
            await run.edge.handleReported("tap_close", now: run.advance())
            let firstOpen = try await run.edge.recordOpen()
            XCTAssertFalse(firstOpen, "leaving ends the first record")
            XCTAssertEqual(run.owner.dismissals, [.machine(reason: "left")])

            await run.edge.start(event: "go", now: run.advance())
            try await run.settle()
            let second = await run.edge.shown
            let secondShown = try XCTUnwrap(second, "the second record shows the paywall")
            let secondOpen = try await run.edge.recordOpen()
            XCTAssertTrue(secondOpen, "the second record is open")

            run.store.release()
            await run.edge.storeAnswered()
            let beforeAnswer = await run.edge.log.count
            try await run.settle(frames: 2)
            let late = await Array(run.edge.log.dropFirst(beforeAnswer))
            let call = try XCTUnwrap(run.store.calls.first)
            XCTAssertEqual(call.externName, "restore")
            XCTAssertEqual(late, [.dropped(call.id, outcome: outcome)])
            let whole = await run.edge.log
            XCTAssertEqual(whole.filter {
                if case .dropped = $0 { return true }
                return false
            }.count, 1, "one dropped entry for the old call")
            let noFault = await run.edge.fault
            XCTAssertNil(noFault, "an answer for an ended record is no fault")
            let still = await run.edge.shown
            XCTAssertEqual(still, secondShown, "the second record's showing is untouched")
            let stillOpen = try await run.edge.recordOpen()
            XCTAssertTrue(stillOpen, "the second record is still open")
            XCTAssertEqual(run.owner.dismissals, [.machine(reason: "left")],
                           "the owner hears nothing for the second record")

            // The second record still works: a tap on "Not now" is handled.
            let closeTap = try await run.tap(Box.close)
            XCTAssertEqual(closeTap, ["tap_close"])
            XCTAssertEqual(run.owner.dismissals, [.machine(reason: "left"), .machine(reason: "left")])
            let finalFault = await run.edge.fault
            XCTAssertNil(finalFault)
            XCTAssertEqual(run.store.calls.count, 1)
            try await run.close()
        } catch {
            run.store.release()
            try? await run.close()
            throw error
        }
    }

    /// An answer for the open record's own unanswered call is delivered,
    /// once: `restore` answered `completed` runs `leave`.
    func testAnAnswerForTheOpenRecordsOwnCallIsDeliveredOnce() async throws {
        let run = try await Run(plan: Self.leavesPlan, holdingStore: true, answering: ["restore": "completed"])
        do {
            await run.edge.start(event: "go", now: run.now)
            try await run.settle()
            await run.edge.handleReported("tap_restore", now: run.advance())
            let written = await run.edge.log.count
            run.store.release()
            await run.edge.storeAnswered()
            try await run.settle(frames: 3)
            let after = await Array(run.edge.log.dropFirst(written))
            let call = try XCTUnwrap(run.store.calls.first)
            XCTAssertEqual(after.filter {
                switch $0 {
                case .answer, .dropped: return true
                default: return false
                }
            }, [.answer(call.id, outcome: "completed")], "\(after)")
            XCTAssertTrue(after.contains(.dismiss(reason: "left")), "\(after)")
            XCTAssertTrue(after.contains(.end(reason: .exited, fault: nil)), "\(after)")
            let noFault = await run.edge.fault
            XCTAssertNil(noFault)
            XCTAssertEqual(run.owner.dismissals, [.machine(reason: "left")])
            let open = try await run.edge.recordOpen()
            XCTAssertFalse(open, "the answer's `leave` ends the record")
            try await run.close()
        } catch {
            run.store.release()
            try? await run.close()
            throw error
        }
    }

    /// A close belongs to the showing the person closed. Instance numbers
    /// start over with each record, so the host names the showing. Closing
    /// the first record's showing after a second record shows its own is
    /// dropped and leaves the second alone; closing the second's is handled.
    func testACloseForAnEndedShowingIsDropped() async throws {
        let run = try await Run(plan: Self.leavesPlan)
        do {
            await run.edge.start(event: "go", now: run.now)
            try await run.settle()
            let firstShown = await run.edge.shown
            let first = try XCTUnwrap(firstShown)
            await run.edge.handleReported("tap_close", now: run.advance())
            XCTAssertEqual(run.owner.dismissals, [.machine(reason: "left")])

            await run.edge.start(event: "go", now: run.advance())
            try await run.settle()
            let secondShown = await run.edge.shown
            let second = try XCTUnwrap(secondShown)
            XCTAssertNotEqual(first, second)

            var written = await run.edge.log.count
            await run.edge.closed(first, now: run.advance())
            let stale = await Array(run.edge.log.dropFirst(written))
            XCTAssertEqual(stale, [.droppedClose(first)])
            let untouched = await run.edge.shown
            XCTAssertEqual(untouched, second, "the second record's showing is untouched")
            let open = try await run.edge.recordOpen()
            XCTAssertTrue(open)
            var noFault = await run.edge.fault
            XCTAssertNil(noFault)
            XCTAssertEqual(run.owner.dismissals, [.machine(reason: "left")])

            written = await run.edge.log.count
            await run.edge.closed(second, now: run.advance())
            let closing = await Array(run.edge.log.dropFirst(written))
            XCTAssertTrue(closing.contains(.pop(instance: second.instance)), "\(closing)")
            noFault = await run.edge.fault
            XCTAssertNil(noFault)
            let gone = await run.edge.shown
            XCTAssertNil(gone)
            try await run.close()
        } catch {
            try? await run.close()
            throw error
        }
    }

    /// An engine event belongs to the showing the frame stepped. One frame
    /// whose pointers tap "Not now" and then "About the trial": "Not now"
    /// dismisses the paywall, so "About the trial", reported for the same
    /// showing, is dropped rather than heard by nothing or by another.
    func testAnEventReportedAfterItsShowingEndedInTheSameFrameIsDropped() async throws {
        let run = try await Run()
        do {
            await run.edge.start(event: "onboarding_completed", now: run.now)
            try await run.settle()
            let written = await run.edge.log.count
            func center(_ box: [Int]) -> (Float, Float) {
                (Float(box[0] + box[2]) / 2, Float(box[1] + box[3]) / 2)
            }
            let (closeX, closeY) = center(Box.close)
            let (detailsX, detailsY) = center(Box.details)
            let touched = await run.edge.shown
            let frame = await run.edge.frame(pointers: [
                NuxieNativePointerEvent(kind: .down, x: closeX, y: closeY),
                NuxieNativePointerEvent(kind: .up, x: closeX, y: closeY),
                NuxieNativePointerEvent(kind: .down, x: detailsX, y: detailsY),
                NuxieNativePointerEvent(kind: .up, x: detailsX, y: detailsY),
            ], on: touched, elapsedSeconds: Self.tick, now: run.advance())
            XCTAssertEqual(frame.reported.filter { !$0.hasPrefix("$") && !$0.isEmpty }, ["tap_close", "tap_details"])
            let after = await Array(run.edge.log.dropFirst(written))
            XCTAssertTrue(after.contains(.reported("tap_close")), "\(after)")
            XCTAssertTrue(after.contains(.dismiss(reason: "paywall_closed")), "\(after)")
            XCTAssertFalse(after.contains(.reported("tap_details")), "\(after)")
            XCTAssertTrue(after.contains(.droppedReport("tap_details")), "\(after)")
            let noFault = await run.edge.fault
            XCTAssertNil(noFault)
            XCTAssertEqual(run.owner.dismissals, [.machine(reason: "paywall_closed")])
            try await run.close()
        } catch {
            try? await run.close()
            throw error
        }
    }

    /// A touch belongs to the showing the person touched. "Not now" ends
    /// the paywall, and while its sheet animates away the person taps "Not
    /// now" again: those pointers touched a showing that has ended, so they
    /// go to no one. The frames still run, the Screen reports nothing, and
    /// the record waits for the evening offer as before, with no fault.
    func testATouchOnAPaywallThatHasGoneGoesNowhere() async throws {
        let run = try await Run()
        do {
            await run.edge.start(event: "onboarding_completed", now: run.now)
            try await run.settle()
            let firstShown = await run.edge.shown
            let first = try XCTUnwrap(firstShown)
            _ = try await run.tap(Box.close)
            XCTAssertEqual(run.owner.dismissals, [.machine(reason: "paywall_closed")])
            let reports = run.owner.reports.count
            let written = await run.edge.log.count

            let reported = try await run.tap(Box.close, touching: first)
            XCTAssertEqual(reported, [], "the departing paywall took the touch")
            let after = await Array(run.edge.log.dropFirst(written))
            XCTAssertEqual(after.filter { if case .droppedTouches = $0 { return true }; return false },
                           [.droppedTouches(first), .droppedTouches(first)], "each frame's pointers go to no one")
            XCTAssertFalse(after.contains { if case .reported = $0 { return true }; return false }, "\(after)")
            let noFault = await run.edge.fault
            XCTAssertNil(noFault)
            let open = try await run.edge.recordOpen()
            XCTAssertTrue(open, "the record waits for the evening offer")
            XCTAssertEqual(run.owner.reports.count, reports, "the owner was told something")
            try await run.close()
        } catch {
            try? await run.close()
            throw error
        }
    }

    /// One frame whose pointers tap Monthly and then "Not now": Monthly's
    /// writes are for the paywall that "Not now" dismisses in the same
    /// frame. They belong to a Screen that is gone by the end of the
    /// delivery, so none lands: the sheet leaves showing what it showed, and
    /// the record still holds the person's choice.
    func testWritesForAPaywallDismissedLaterInTheSameFrameAreDropped() async throws {
        let run = try await Run()
        do {
            await run.edge.start(event: "onboarding_completed", now: run.now)
            try await run.settle()
            let written = await run.edge.log.count
            func center(_ box: [Int]) -> (Float, Float) {
                (Float(box[0] + box[2]) / 2, Float(box[1] + box[3]) / 2)
            }
            let (monthlyX, monthlyY) = center(Box.monthly)
            let (closeX, closeY) = center(Box.close)
            let touched = await run.edge.shown
            let frame = await run.edge.frame(pointers: [
                NuxieNativePointerEvent(kind: .down, x: monthlyX, y: monthlyY),
                NuxieNativePointerEvent(kind: .up, x: monthlyX, y: monthlyY),
                NuxieNativePointerEvent(kind: .down, x: closeX, y: closeY),
                NuxieNativePointerEvent(kind: .up, x: closeX, y: closeY),
            ], on: touched, elapsedSeconds: Self.tick, now: run.advance())
            XCTAssertEqual(frame.reported.filter { !$0.hasPrefix("$") && !$0.isEmpty }, ["tap_monthly", "tap_close"])
            let after = await Array(run.edge.log.dropFirst(written))
            XCTAssertTrue(after.contains(.reported("tap_monthly")), "\(after)")
            XCTAssertTrue(after.contains(.dismiss(reason: "paywall_closed")), "\(after)")
            XCTAssertEqual(Self.writes(after).map(\.cell), [], "a write landed in a Screen that is gone: \(after)")
            let cells = try await run.cells()
            XCTAssertEqual(cells["monthly_selected"], .bool(false))
            XCTAssertEqual(cells["annual_selected"], .bool(true))
            let plan = try await run.edge.slot("plan")
            XCTAssertEqual(plan, .enumeration("monthly"), "the record holds the choice")
            let noFault = await run.edge.fault
            XCTAssertNil(noFault)
            XCTAssertEqual(run.owner.dismissals, [.machine(reason: "paywall_closed")])
            try await run.close()
        } catch {
            try? await run.close()
            throw error
        }
    }

    /// Frames and a tap on another control while the store has not answered
    /// are handled, in order; the answer, released after, applies its rows
    /// once, after the tap's.
    func testATapWhileThePurchaseWaitsIsHandledAndTheAnswerAppliesOnce() async throws {
        let run = try await Run(holdingStore: true)
        do {
            await run.edge.start(event: "onboarding_completed", now: run.now)
            try await run.settle()
            let written = await run.edge.log.count
            let buyTap = try await run.tap(Box.buy)
            XCTAssertEqual(buyTap, ["tap_buy"])
            let detailsTap = try await run.tap(Box.details)
            XCTAssertEqual(detailsTap, ["tap_details"])
            let waiting = try await run.cells()
            XCTAssertEqual(waiting["buy_busy"], .bool(true), "the button is busy while the store has not answered")
            XCTAssertEqual(waiting["terms_visible"], .bool(true), "the tap was handled while the store worked")

            run.store.release()
            await run.edge.storeAnswered()
            try await run.settle(frames: 2)
            let after = await Array(run.edge.log.dropFirst(written))
            let answers = after.indices.filter {
                if case .answer = after[$0] { return true }
                return false
            }
            XCTAssertEqual(answers.count, 1, "the answer applies once: \(after)")
            let details = try XCTUnwrap(after.firstIndex(of: .reported("tap_details")))
            let answer = try XCTUnwrap(answers.first)
            XCTAssertLessThan(details, answer, "the tap is handled before the answer arrives")
            let writes = Self.writes(after)
            XCTAssertEqual(writes.filter { $0.cell == "buy_busy" }.map(\.value), [.bool(true), .bool(false)])
            XCTAssertEqual(writes.filter { $0.cell == "error_visible" }.map(\.value), [.bool(true)])
            XCTAssertEqual(writes.filter { $0.cell == "terms_visible" }.map(\.value), [.bool(true)])
            let answeredWrites = Self.writes(Array(after[answer...]))
            XCTAssertEqual(Set(answeredWrites.map(\.cell)), ["buy_busy", "error_visible"],
                           "the answer's rows come after it")
            let settled = try await run.cells()
            XCTAssertEqual(settled["buy_busy"], .bool(false))
            XCTAssertEqual(settled["error_visible"], .bool(true))
            XCTAssertEqual(settled["terms_visible"], .bool(true))
            let noFault = await run.edge.fault
            XCTAssertNil(noFault)
            XCTAssertEqual(run.owner.dismissals, [])
            XCTAssertEqual(run.store.calls.map(\.externName), ["purchase"])
            try await run.close()
        } catch {
            run.store.release()
            try? await run.close()
            throw error
        }
    }

    /// Requests asked for together, none awaited before the next is asked,
    /// are applied in arrival order, each whole: a pointer down and up on
    /// Monthly and a frame after (whose `tap_monthly` writes suspend on the
    /// engine), "About the trial" reported, then a swipe down. Were a
    /// delivery to start while another is suspended, the swipe down would pop
    /// the paywall between Monthly's writes, and the rest would fault.
    ///
    /// The tasks start on the main actor in the order they are made, so each
    /// reaches the edge before the next one is asked.
    @MainActor
    func testRequestsAskedTogetherApplyInArrivalOrderEachWhole() async throws {
        let run = try await Run()
        do {
            await run.edge.start(event: "onboarding_completed", now: run.now)
            try await run.settle()
            let written = await run.edge.log.count
            let edge = run.edge
            let current = await edge.shown
            let shown = try XCTUnwrap(current)
            let x = Float(Box.monthly[0] + Box.monthly[2]) / 2
            let y = Float(Box.monthly[1] + Box.monthly[3]) / 2
            let at = run.advance()
            let tick = Self.tick
            let requests = [
                Task { _ = await edge.frame(pointers: [NuxieNativePointerEvent(kind: .down, x: x, y: y)],
                                            on: shown, elapsedSeconds: tick, now: at) },
                Task { _ = await edge.frame(pointers: [NuxieNativePointerEvent(kind: .up, x: x, y: y)],
                                            on: shown, elapsedSeconds: tick, now: at) },
                Task { _ = await edge.frame(elapsedSeconds: tick, now: at) },
                Task { await edge.handleReported("tap_details", now: at) },
                Task { await edge.closed(shown, now: at) },
            ]
            for request in requests { await request.value }

            let after = await Array(edge.log.dropFirst(written))
            let noFault = await edge.fault
            XCTAssertNil(noFault, "\(after)")
            let whole = await edge.log
            let presented = try XCTUnwrap(Self.presentedInstance(whole))
            XCTAssertEqual(after.filter { entry in
                if case .reported = entry { return true }
                return Self.isPresentation(entry)
            }, [.reported("tap_monthly"), .reported("tap_details"), .pop(instance: presented),
                .end(reason: .finished, fault: nil)])
            let monthly = try XCTUnwrap(after.firstIndex(of: .reported("tap_monthly")))
            let details = try XCTUnwrap(after.firstIndex(of: .reported("tap_details")))
            let pop = try XCTUnwrap(after.firstIndex(of: .pop(instance: presented)))
            let monthlyWrites = Self.writes(Array(after[monthly..<details]))
            XCTAssertEqual(monthlyWrites.filter { $0.cell == "monthly_selected" }.map(\.value), [.bool(true)])
            XCTAssertEqual(monthlyWrites.filter { $0.cell == "annual_selected" }.map(\.value), [.bool(false)])
            XCTAssertEqual(Self.writes(Array(after[details..<pop])).map(\.cell), ["terms_visible"])
            XCTAssertEqual(Self.writes(Array(after[pop...])).count, 0)
            let open = try await edge.recordOpen()
            XCTAssertFalse(open)
            XCTAssertEqual(run.owner.dismissals, [])
            try await run.close()
        } catch {
            try? await run.close()
            throw error
        }
    }

    // MARK: What the owner hears

    /// The owner hears each delivery's rows for it, in one report, with
    /// what is shown: the start shows the paywall, with the identity the
    /// session gave it; a tap on a plan shows the same and dismisses
    /// nothing; "Not now" shows nothing and tells its `dismiss` and its
    /// wake. (The machine restates its wake moment, none until "Not now",
    /// in each delivery.)
    func testEachDeliveryReportsTheRowsItsOwnerPerforms() async throws {
        let run = try await Run()
        do {
            await run.edge.start(event: "onboarding_completed", now: run.now)
            let log = await run.edge.log
            let instance = try XCTUnwrap(Self.presentedInstance(log))
            guard case .delivered(let shown, let started)? = run.owner.reports.first, run.owner.reports.count == 1
            else {
                return XCTFail("\(run.owner.reports)")
            }
            let paywall = NuxieMachinePresented(shown: NuxieMachineShown(journey: 1, instance: instance),
                                                route: "paywall", presentation: .sheet)
            XCTAssertEqual(shown, [paywall])
            XCTAssertFalse(started.contains(.wakeAt(18 * Self.hour)), "\(started)")
            try await run.settle()
            let beforeMonthly = run.owner.reports.count
            _ = try await run.tap(Box.monthly)
            for case .delivered(let shownNow, let rows) in run.owner.reports.dropFirst(beforeMonthly) {
                XCTAssertTrue(rows.allSatisfy { $0 == .wakeAt(nil) }, "a plan tap dismisses nothing: \(rows)")
                XCTAssertEqual(shownNow, [paywall], "a plan tap changes what is shown")
            }
            XCTAssertNil(run.owner.reports.dropFirst(beforeMonthly).compactMap(\.dismissal).first)

            _ = try await run.tap(Box.close)
            guard case .delivered(let closedShown, let rows)? = run.owner.reports.last else {
                return XCTFail("\(run.owner.reports)")
            }
            XCTAssertEqual(closedShown, [])
            XCTAssertTrue(rows.contains(.dismiss(reason: "paywall_closed")), "\(rows)")
            XCTAssertTrue(rows.contains(.wakeAt(18 * Self.hour)), "\(rows)")
            XCTAssertEqual(run.owner.dismissals, [.machine(reason: "paywall_closed")])
            try await run.close()
        } catch {
            try? await run.close()
            throw error
        }
    }

    /// A swipe down's close tells the owner that nothing is shown and the
    /// record's normal end, with no dismissal.
    func testASwipeDownReportsThePopAndTheEnd() async throws {
        let run = try await Run()
        do {
            await run.edge.start(event: "onboarding_completed", now: run.now)
            try await run.settle()
            let current = await run.edge.shown
            let shown = try XCTUnwrap(current)
            await run.edge.closed(shown, now: run.advance())
            guard case .delivered(let shownNow, let rows)? = run.owner.reports.last else {
                return XCTFail("\(run.owner.reports)")
            }
            XCTAssertEqual(shownNow, [], "\(rows)")
            XCTAssertEqual(rows.last, .end(.finished), "\(rows)")
            XCTAssertEqual(run.owner.dismissals, [], "the person already took the sheet")
            try await run.close()
        } catch {
            try? await run.close()
            throw error
        }
    }

    /// A fault with no row of its own still reaches the owner, as the
    /// fault: here the engine's step fails because its Screen was closed
    /// under the edge. The log says only that the paywall went.
    func testAnEngineStepFailureTellsTheOwnerTheFault() async throws {
        let run = try await Run()
        do {
            await run.edge.start(event: "onboarding_completed", now: run.now)
            try await run.settle()
            let written = await run.edge.log.count
            let stack = await run.edge.stack
            let paywall = try XCTUnwrap(stack.last).shown
            try await run.edge.screen()?.close()
            await run.edge.frame(elapsedSeconds: Self.tick, now: run.advance())
            let recorded = await run.edge.fault
            let fault = try XCTUnwrap(recorded, "the step failed")
            XCTAssertEqual(fault.code, "engine.step")
            let after = await Array(run.edge.log.dropFirst(written))
            XCTAssertEqual(after, [.gone(paywall)], "the failed step logged a row")
            XCTAssertEqual(run.owner.reports.last, .fault(fault))
            XCTAssertEqual(run.owner.dismissals.filter { $0 == .fault(fault) }.count, 1)
            try await run.close()
        } catch {
            try? await run.close()
            throw error
        }
    }

    // MARK: Waking and resting

    /// "Not now" leaves the evening offer owed and asks for a wake at 18:00.
    /// Delivered then, the wake runs Stillwater's `show_offer`, which goes
    /// to the `offer` route: a route this edge has no artwork for, so the
    /// wake ends in the one fault path, and the owner hears that fault once.
    func testAWakeAtTheEveningMomentIsDeliveredToTheMachine() async throws {
        let run = try await Run()
        do {
            await run.edge.start(event: "onboarding_completed", now: run.now)
            try await run.settle()
            _ = try await run.tap(Box.close)
            let asked = await run.edge.log
            XCTAssertTrue(asked.contains(.wakeAt(18 * Self.hour)), "\(asked)")
            XCTAssertEqual(run.owner.dismissals, [.machine(reason: "paywall_closed")])
            let written = asked.count

            await run.edge.wake(now: 18 * Self.hour)
            let recorded = await run.edge.fault
            let fault = try XCTUnwrap(recorded, "the wake reached the machine")
            XCTAssertEqual(fault.code, "edge.no-artwork")
            XCTAssertTrue(fault.detail.contains("offer"), fault.detail)
            XCTAssertEqual(run.owner.dismissals, [.machine(reason: "paywall_closed"), .fault(fault)])
            XCTAssertEqual(run.owner.reports.last, .fault(fault), "the fault reaches the owner as its report")
            let after = await Array(run.edge.log.dropFirst(written))
            XCTAssertFalse(after.contains { if case .opened = $0 { return true }; return false },
                           "an offer with no artwork was opened: \(after)")
            try await run.close()
        } catch {
            try? await run.close()
            throw error
        }
    }

    /// The machine takes a wake only at the moment it asked for. A wake
    /// delivered at another moment, here two days late, changes nothing: no
    /// rows, no fault, the record still open. The wake at the moment asked
    /// for still reaches it afterwards. So a host that comes back late
    /// delivers each wake at its own moment, not at the clock's.
    func testAWakeAtAMomentTheRecordDidNotAskForChangesNothing() async throws {
        let run = try await Run()
        do {
            await run.edge.start(event: "onboarding_completed", now: run.now)
            try await run.settle()
            _ = try await run.tap(Box.close)
            let written = await run.edge.log.count

            await run.edge.wake(now: 2 * 24 * Self.hour + Self.nine)
            let after = await Array(run.edge.log.dropFirst(written))
            XCTAssertEqual(after, [], "a wake at another moment is not the one asked for")
            let open = try await run.edge.recordOpen()
            XCTAssertTrue(open)
            let noFault = await run.edge.fault
            XCTAssertNil(noFault)
            XCTAssertEqual(run.owner.dismissals, [.machine(reason: "paywall_closed")])

            await run.edge.wake(now: 18 * Self.hour)
            let recorded = await run.edge.fault
            XCTAssertEqual(recorded?.code, "edge.no-artwork", "the wake at the moment asked for reached the machine")
            try await run.close()
        } catch {
            try? await run.close()
            throw error
        }
    }

    /// "Not now" dismisses the paywall, and the evening's wake starts a
    /// purchase (in this variant of the plan) that writes no cell: nothing
    /// is presented. The store answers with no frame running, and only a
    /// frame delivers an answer: the record takes it with no touch.
    func testAWakeThatStartsAPurchaseOnTheRowPathMovesTheRecordOnWithNoTouch() async throws {
        let run = try await Run(plan: Fixture.load().purchasingInTheEvening())
        do {
            await run.edge.start(event: "onboarding_completed", now: run.now)
            try await run.settle()
            _ = try await run.tap(Box.close)
            XCTAssertEqual(run.owner.dismissals, [.machine(reason: "paywall_closed")])
            try await run.afterDelivery(onScreen: false)

            let written = await run.edge.log.count
            run.jump(to: 18 * Self.hour)
            await run.edge.wake(now: run.now)
            try await run.afterDelivery(onScreen: false)
            let after = await Array(run.edge.log.dropFirst(written))
            let failed = try await run.edge.slot("failed")
            XCTAssertEqual(failed, .bool(true), "the store's answer never reached the record: \(after)")
            let fault = await run.edge.fault
            XCTAssertNil(fault)
            try await run.close()
        } catch {
            try? await run.close()
            throw error
        }
    }

    /// The edge asks for a frame exactly when it leaves work only a frame
    /// consumes: a write to show (it shows on the next step) or a store's
    /// answer to deliver. A purchase in flight is not such work: its answer
    /// asks when it arrives, so nothing has to run frames while it is held.
    func testTheEdgeAsksForAFrameExactlyWhenOneHasWorkWaiting() async throws {
        let run = try await Run(holdingStore: true)
        do {
            await run.edge.start(event: "onboarding_completed", now: run.now)
            XCTAssertTrue(run.asks.take(), "the start's writes wait for a step")
            await run.edge.frame(elapsedSeconds: Self.tick, now: run.now)
            XCTAssertFalse(run.asks.take(), "the first step showed the start's writes")
            try await run.settle()
            _ = run.asks.take()
            await run.edge.frame(elapsedSeconds: Self.tick, now: run.now)
            XCTAssertFalse(run.asks.take(), "a quiet frame leaves nothing waiting")
            let quiet = await run.edge.waitingForFrame()
            XCTAssertFalse(quiet)

            // The pointer's up reports `tap_buy`: the machine writes the busy
            // button and calls the store, which holds its answer.
            let x = Float(Box.buy[0] + Box.buy[2]) / 2
            let y = Float(Box.buy[1] + Box.buy[3]) / 2
            let at = run.advance()
            let touched = await run.edge.shown
            await run.edge.frame(pointers: [NuxieNativePointerEvent(kind: .down, x: x, y: y)],
                                 on: touched, elapsedSeconds: Self.tick, now: at)
            _ = run.asks.take()
            let tapped = await run.edge.frame(pointers: [NuxieNativePointerEvent(kind: .up, x: x, y: y)],
                                              on: touched, elapsedSeconds: Self.tick, now: at)
            XCTAssertEqual(tapped.reported.filter { !$0.hasPrefix("$") && !$0.isEmpty }, ["tap_buy"])
            XCTAssertTrue(run.asks.take(), "the busy button was written")
            await run.edge.frame(elapsedSeconds: Self.tick, now: at)
            XCTAssertFalse(run.asks.take(), "a purchase in flight waits on the store, not on a frame")
            let holding = await run.edge.waitingForFrame()
            XCTAssertFalse(holding)

            // The answer arrives, asks for the frame that delivers it, and
            // that frame's delivery asks for the step that shows it.
            run.store.release()
            await run.edge.storeAnswered()
            XCTAssertTrue(run.asks.take(), "the answer asked for its frame")
            let arrived = await run.edge.waitingForFrame()
            XCTAssertTrue(arrived)
            await run.edge.frame(elapsedSeconds: Self.tick, now: at)
            XCTAssertTrue(run.asks.take(), "the answer wrote the error line and the button")
            await run.edge.frame(elapsedSeconds: Self.tick, now: at)
            XCTAssertFalse(run.asks.take(), "nothing waits once the answer has shown")
            let rested = await run.edge.waitingForFrame()
            XCTAssertFalse(rested)
            try await run.close()
        } catch {
            run.store.release()
            try? await run.close()
            throw error
        }
    }

    private static func isPresentation(_ entry: NuxieMachineEdgeEntry) -> Bool {
        switch entry {
        case .present, .pop, .dismiss, .end: return true
        default: return false
        }
    }

    private static func presentedInstance(_ log: [NuxieMachineEdgeEntry]) -> UInt64? {
        log.lazy.compactMap { entry -> UInt64? in
            if case .present(_, let instance, _) = entry { return instance }
            return nil
        }.first
    }

    private static func writes(_ entries: [NuxieMachineEdgeEntry]) -> [(cell: String, value: NuxieMachineValue)] {
        entries.compactMap { entry in
            if case .write(let cell, let value) = entry { return (cell, value) }
            return nil
        }
    }

    // MARK: Pixels

    /// Whether the region `box` of `after` differs from `before`.
    private static func changes(_ before: Data, _ after: Data, _ box: [Int]) -> Bool {
        moved(before, after, in: box) >= changedAtLeast
    }

    /// Whether the region `box` of `after` is the region of `before`.
    private static func holds(_ before: Data, _ after: Data, _ box: [Int]) -> Bool {
        moved(before, after, in: box) <= steadyAtMost
    }

    /// Whether everything outside the boxes `except` holds. Each box grows
    /// by `edge` on every side: a card's border draws on the box's last row
    /// and column, which the box itself leaves out.
    private static func holds(_ before: Data, _ after: Data, outside except: [[Int]]) -> Bool {
        let grown = except.map { [$0[0] - edge, $0[1] - edge, $0[2] + edge, $0[3] + edge] }
        return moved(before, after, in: [0, 0, width, height], except: grown) <= steadyAtMost
    }

    /// How many pixels in `box`, and not in `except`, move by more than
    /// `difference` in some channel.
    private static func moved(_ before: Data, _ after: Data, in box: [Int], except: [[Int]] = []) -> Int {
        precondition(before.count == after.count && before.count == width * height * 4)
        var count = 0
        before.withUnsafeBytes { first in
            after.withUnsafeBytes { second in
                for y in box[1]..<box[3] {
                    for x in box[0]..<box[2] {
                        if except.contains(where: { x >= $0[0] && x < $0[2] && y >= $0[1] && y < $0[3] }) { continue }
                        let at = (y * width + x) * 4
                        for channel in 0..<4 where abs(Int(first[at + channel]) - Int(second[at + channel])) > difference {
                            count += 1
                            break
                        }
                    }
                }
            }
        }
        return count
    }
}

// MARK: - One run of the script

/// A fresh session and Screen, its clock, and what its store and owner heard.
private final class Run {
    let edge: NuxieMachineEdge
    let store: RecordingStore
    let owner = Owner()
    /// The edge's asks for a frame, as a Screen's view hears them.
    let asks: FrameAskCount
    private(set) var now: Int64 = 9 * 3_600_000
    private var frames = 0

    /// Stillwater's plan over its Screen, or `plan` over the same Screen.
    /// A holding store answers each call only when the test releases it,
    /// and `answering` names an outcome for an extern in place of the
    /// stand-in's.
    init(plan: NuxieMachinePlanSource? = nil, holdingStore: Bool = false,
         answering: [String: String] = [:]) async throws {
        let fixture = try Fixture.load()
        let store = RecordingStore(holds: holdingStore, answering: answering)
        self.store = store
        let owner = self.owner
        edge = try await NuxieMachineEdge(
            plan: plan ?? fixture.plan, screen: fixture.screen, store: store,
            onReport: { owner.heard($0) })
        asks = FrameAskCount(edge)
    }

    /// Move the clock to `moment`, as a host does before delivering a wake:
    /// the machine takes nothing earlier than its last step.
    func jump(to moment: Int64) {
        now = max(now, moment)
    }

    /// The clock a second on, as the Mac test spaces its calls.
    func advance() -> Int64 {
        now += 1000
        return now
    }

    /// Frames with no pointer, for the writes of the last frame to show.
    func settle(frames count: Int = 3) async throws {
        for _ in 0..<count {
            await edge.frame(elapsedSeconds: 1.0 / 60.0, now: now)
        }
    }

    /// What a Screen's view does after a delivery of its own (a start, a
    /// wake): nothing, unless the edge asks. Off screen, the engine's own
    /// animation asks for no frame either.
    func afterDelivery(onScreen: Bool) async throws {
        try await settleAsAView(edge, asks: asks, keepGoing: false, onScreen: onScreen,
                                now: { self.now }, elapsedSeconds: 1.0 / 60.0)
    }

    /// A pointer down and up at the center of `box`, a second after the
    /// last call, each in its own frame, then `framesAfter` frames with no
    /// pointer. The Screen's named events reported in all of them (the
    /// engine's reserved and unnamed ones left out, as the edge leaves them).
    func tap(_ box: [Int], framesAfter: Int = 3) async throws -> [String] {
        try await tap(box, touching: edge.shown, framesAfter: framesAfter)
    }

    /// The same tap, on the Screen of the showing `touched`: the one the
    /// person's view showed when the pointers arrived.
    func tap(_ box: [Int], touching touched: NuxieMachineShown?, framesAfter: Int = 3) async throws -> [String] {
        let x = Float(box[0] + box[2]) / 2
        let y = Float(box[1] + box[3]) / 2
        let at = advance()
        var reported: [String] = []
        for kind in [NuxieNativePointerKind.down, .up] {
            reported += await edge.frame(pointers: [NuxieNativePointerEvent(kind: kind, x: x, y: y)],
                                         on: touched, elapsedSeconds: 1.0 / 60.0, now: at).reported
        }
        for _ in 0..<framesAfter {
            reported += await edge.frame(elapsedSeconds: 1.0 / 60.0, now: at).reported
        }
        return reported.filter { !$0.hasPrefix("$") && !$0.isEmpty }
    }

    /// The writes the edge made after its first `count` log entries.
    func writes(since count: Int) async -> [(cell: String, value: NuxieMachineValue)] {
        await edge.log.dropFirst(count).compactMap { entry in
            if case .write(let cell, let value) = entry { return (cell, value) }
            return nil
        }
    }

    /// The Screen's cells as the engine holds them now.
    func cells() async throws -> [String: NuxieNativeViewModelValue] {
        let screen = await edge.screen()
        let runtime = try XCTUnwrap(screen, "the edge has a Screen")
        let snapshot = try await runtime.snapshot()
        guard case .referencedInstance(let state)? = snapshot.values.first(where: {
            $0.ownerInstanceID == snapshot.rootInstanceID && $0.name == "state"
        })?.value else { return [:] }
        var cells: [String: NuxieNativeViewModelValue] = [:]
        for value in snapshot.values where value.ownerInstanceID == state { cells[value.name] = value.value }
        return cells
    }

    /// The Screen drawn now with Metal, read back as BGRA, and kept as a PNG
    /// attachment named `stillwater-paywall-<name>`.
    func frame(_ name: String) async throws -> Data {
        frames += 1
        let screen = await edge.screen()
        let runtime = try XCTUnwrap(screen, "the edge has a Screen")
        let pixels = try await Pixels.render(runtime, width: 390, height: 844)
        try await Pixels.attach(pixels, width: 390, height: 844, name: "stillwater-paywall-\(frames)-\(name)")
        return pixels
    }

    func close() async throws {
        try await edge.close()
    }
}

/// A store that hands every call to the stand-in, or answers it with the
/// outcome `answering` names for its extern, and keeps them. A holding one
/// gives each answer only when the test releases it: a release that comes
/// before its call lets that call answer at once.
private final class RecordingStore: NuxieMachineStore, @unchecked Sendable {
    private let lock = NSLock()
    private var received: [NuxieMachineCall] = []
    private let standIn = NuxieMachineStandInStore()
    private let holds: Bool
    private let answering: [String: String]
    private var held: [CheckedContinuation<Void, Never>] = []
    private var releasedEarly = 0

    init(holds: Bool, answering: [String: String]) {
        self.holds = holds
        self.answering = answering
    }

    var calls: [NuxieMachineCall] {
        lock.withLock { received }
    }

    func perform(_ call: NuxieMachineCall) async throws -> String {
        lock.withLock { received.append(call) }
        if holds {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let goes = lock.withLock { () -> Bool in
                    guard releasedEarly == 0 else {
                        releasedEarly -= 1
                        return true
                    }
                    held.append(continuation)
                    return false
                }
                if goes { continuation.resume() }
            }
        }
        if let outcome = answering[call.externName] { return outcome }
        return try await standIn.perform(call)
    }

    /// Let the oldest held call answer, or the next call when none is held.
    func release() {
        guard holds else { return }
        let next = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            guard !held.isEmpty else {
                releasedEarly += 1
                return nil
            }
            return held.removeFirst()
        }
        next?.resume()
    }
}

/// The edge's owner: the reports it was told, one per delivery that did
/// something for it.
private final class Owner: @unchecked Sendable {
    private let lock = NSLock()
    private var heardReports: [NuxieMachineEdgeReport] = []

    var reports: [NuxieMachineEdgeReport] {
        lock.withLock { heardReports }
    }

    /// The dismissals the reports told: at most one each.
    var dismissals: [NuxieMachineEdgeDismissal] {
        reports.compactMap(\.dismissal)
    }

    func heard(_ report: NuxieMachineEdgeReport) {
        lock.withLock { heardReports.append(report) }
    }
}

// MARK: - The fixture

/// `Fixtures/stillwater-paywall`: the published Screen, Stillwater's four
/// `.nux` files, and the System fonts the publisher's report names. The
/// presenter's checks open the same Screen.
struct Fixture {
    let plan: NuxieMachinePlanSource
    let screen: NuxieMachineScreenSource

    static func load() throws -> Fixture {
        func url(_ name: String) throws -> URL {
            let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
            return try XCTUnwrap(Bundle(for: Run.self).url(
                forResource: parts[0], withExtension: parts[1], subdirectory: "stillwater-paywall"),
                "the test bundle carries stillwater-paywall/\(name)")
        }
        struct Provenance: Decodable {
            struct Font: Decodable {
                let authoredAssetId: UInt32
                let assetUniqueName: String
                let weight: String
                let style: String
            }
            let fonts: [Font]
        }
        let provenance = try JSONDecoder().decode(Provenance.self, from: Data(contentsOf: url("provenance.json")))
        let files = try ["main.nux", "paywall.nux", "screens.nux", "done.nux"].map {
            NuxieMachineSourceFile(path: $0, text: try String(contentsOf: url($0), encoding: .utf8))
        }
        return Fixture(
            plan: NuxieMachinePlanSource(files: files, root: "main", app: "app", experience: "stillwater", version: 1),
            screen: NuxieMachineScreenSource(
                bytes: try Data(contentsOf: url("screen.riv")), artboard: "paywall", route: "paywall",
                pixelWidth: 390, pixelHeight: 844,
                systemFonts: provenance.fonts.map {
                    NuxieMachineSystemFont(authoredAssetID: $0.authoredAssetId, assetUniqueName: $0.assetUniqueName,
                                           weight: $0.weight, style: $0.style)
                }))
    }

    /// Stillwater's plan with the evening's `show_offer` starting a purchase
    /// of the offer in place of presenting it, which this Screen has no
    /// artwork for. Its own tests, which expect the offer, are left out.
    func purchasingInTheEvening() throws -> NuxieMachinePlanSource {
        let presents = "  action show_offer\n    offer_due = false\n    go(offer)\n"
        let purchases = "  action show_offer\n    offer_due = false\n"
            + "    purchase(catalog[annual_offer], completed=go(done, replace), failed=mark_failed)\n"
        let files = try plan.files.map { file -> NuxieMachineSourceFile in
            guard file.path == "main.nux" else { return file }
            _ = try XCTUnwrap(file.text.range(of: presents), "main.nux presents the offer in the evening")
            let text = file.text.replacingOccurrences(of: presents, with: purchases)
            let tests = try XCTUnwrap(text.range(of: "  test \"")?.lowerBound, "main.nux has its tests")
            return NuxieMachineSourceFile(path: file.path, text: String(text[..<tests]))
        }
        return NuxieMachinePlanSource(files: files, root: plan.root, app: plan.app,
                                      experience: plan.experience, version: plan.version)
    }
}

// MARK: - Reading frames back

enum Pixels {
    /// One frame of the engine's Screen into a drawable, read back as BGRA
    /// rows, as the SDK's native runtime tests read theirs.
    static func render(_ runtime: NuxieNativeRuntime, width: Int, height: Int) async throws -> Data {
        let device = try await runtime.metalDevice().value
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false
        layer.drawableSize = CGSize(width: width, height: height)
        layer.maximumDrawableCount = 2
        layer.allowsNextDrawableTimeout = true
        guard let drawable = layer.nextDrawable() else {
            throw XCTSkip("This host cannot vend a CAMetalDrawable")
        }
        let bytesPerRow = (width * 4 + 255) & ~255
        let buffer = try XCTUnwrap(device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared))
        let readback = NuxieNativeFrameReadback(buffer: buffer, bytesPerRow: bytesPerRow)
        let drawn = Signal()
        let outcome = try await runtime.render(layoutScaleFactor: 1,
            drawable: .available(NuxieNativeDrawable(drawable)), clearColor: 0xFF00_0000,
            readback: readback, completion: { drawn.fire() })
        try await drawn.wait(seconds: 2)
        XCTAssertEqual(outcome.disposition, .presented)
        let source = buffer.contents().assumingMemoryBound(to: UInt8.self)
        var pixels = Data(capacity: width * height * 4)
        for row in 0..<height {
            pixels.append(source + row * bytesPerRow, count: width * 4)
        }
        return pixels
    }

    /// The BGRA frame as a PNG attachment kept with the test's results.
    /// XCTest takes activities on the main thread.
    @MainActor
    static func attach(_ pixels: Data, width: Int, height: Int, name: String) throws {
        let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let bytes = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let attachment = XCTAttachment(data: bytes as Data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        XCTContext.runActivity(named: name) { $0.add(attachment) }
    }
}

/// The asks an edge made for a frame, as a Screen's view hears them.
final class FrameAskCount: @unchecked Sendable {
    private let lock = NSLock()
    private var asked = 0

    init(_ edge: NuxieMachineEdge) {
        edge.frameAsks.listen { [self] in lock.withLock { asked += 1 } }
    }

    /// Whether the edge asked since the last take.
    func take() -> Bool {
        lock.withLock {
            defer { asked = 0 }
            return asked > 0
        }
    }
}

/// Frames run the way a Screen's view runs them: one for the edge's asks
/// since the last, and on screen while the engine's step keeps going;
/// nothing else. With nothing asked, the store's work in flight is waited
/// for, and its answer must ask by itself. `keepGoing` is what the engine's
/// last step said.
func settleAsAView(_ edge: NuxieMachineEdge, asks: FrameAskCount, keepGoing first: Bool, onScreen: Bool,
                   now: () -> Int64, elapsedSeconds: Float) async throws {
    var keepGoing = first
    for _ in 0..<240 {
        if !asks.take() && !(onScreen && keepGoing) {
            await edge.storeAnswered()
            guard asks.take() else { return }
        }
        let frame = await edge.frame(elapsedSeconds: elapsedSeconds, now: now())
        let fault = await edge.fault
        XCTAssertNil(fault, "a frame faulted")
        keepGoing = frame.keepGoing
    }
    XCTFail("the Screen never came to rest")
}

/// A completion the renderer calls once, awaited with a deadline.
final class Signal: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func fire() { lock.withLock { fired = true } }

    func wait(seconds: Double) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !lock.withLock({ fired }) {
            guard Date() < deadline else {
                throw NSError(domain: "StillwaterPaywallEdgeTests", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "the frame did not complete"])
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }
}
#endif
