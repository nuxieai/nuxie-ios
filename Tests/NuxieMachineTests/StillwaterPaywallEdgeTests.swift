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
/// from Stillwater's five `.nux` files, and the paywall drawn from
/// `paywall.nux` and its `plan-card.nux` alone, as the session's records
/// open it. Real pointers go in, inside the engine's step the session's
/// driver carries the machine, and each frame is drawn with Metal and read
/// back with its semantic snapshot. Where a control is comes from that
/// snapshot: the place a screen reader would name.
///
/// The script is the parent repository's headless story of the same
/// paywall, in five frames: open, Monthly chosen, buying, failed, and the
/// trial's terms open. Then "Not now", or a swipe down in a second run.
///
/// Pixel checks compare a region of one frame with the same region of the
/// frame before, both drawn at twice the layout size. A region "changes"
/// when at least `changedAtLeast` of its pixels move by more than
/// `difference` in some channel, and "holds" when at most `steadyAtMost`
/// do: a selection ring, a dot, a dim or a line of text moves far more
/// pixels than that, and antialiasing far fewer.
final class StillwaterPaywallEdgeTests: XCTestCase {
    private static let difference = 48
    private static let changedAtLeast = 600
    private static let steadyAtMost = 96
    /// How far a control's region grows on every side, in points: a card's
    /// border draws on its bounds' last row and column.
    private static let edge: CGFloat = 2

    /// 09:00 on day zero, in milliseconds.
    private static let nine: Int64 = 9 * 3_600_000
    private static let hour: Int64 = 3_600_000
    private static let minute: Int64 = 60_000
    /// 18:00 and 20:00 on day zero: the evening offer's start and end.
    private static let evening: Int64 = 18 * 3_600_000
    private static let offerEnds: Int64 = 20 * 3_600_000
    /// 17:00 on day zero, an hour before the evening offer.
    private static let five: Int64 = 17 * 3_600_000
    private static let day: Int64 = 24 * 3_600_000
    /// How far apart two places read from the semantic tree may be and
    /// still be the same place, in points.
    private static let near: CGFloat = 0.5
    /// The gap between two plan cards: the "Plan" column's `gap`.
    private static let cardGap: CGFloat = 12
    /// One frame at 60 frames a second.
    static let tick: Float = 1.0 / 60.0

    static let errorLine = "The purchase did not go through. Try again in a moment."
    static let termsLine = "Billed through the store after the trial. Cancel any time."

    // MARK: The story in five frames

    func testThePaywallStoryInFiveFrames() async throws {
        let run = try Run(holdingStore: true)
        do {
            // 1. The start presents the paywall as a sheet, drawn from its
            // compiled view: every line and button is there, and nothing
            // under an `if` shows.
            await run.edge.start(event: "onboarding_completed", now: run.now)
            let presented = await run.edge.log.compactMap { entry -> String? in
                if case .present(let route, _, let presentation) = entry, presentation == .sheet { return route }
                return nil
            }
            XCTAssertEqual(presented, ["paywall"], "the start presents the paywall as a sheet")
            try await run.layOut()
            try await run.settle()
            let open = try await run.look("1-open")
            XCTAssertTrue(open.has("Ten quiet minutes,"), "\(open.reading)")
            XCTAssertTrue(try open.node("Yearly").label.contains("$59.99"), "\(open.reading)")
            XCTAssertTrue(try open.node("Monthly").label.contains("$9.99"), "\(open.reading)")
            XCTAssertTrue(try open.isEnabled("Continue"), "\(open.reading)")
            XCTAssertTrue(open.has("Not now"), "\(open.reading)")
            XCTAssertTrue(open.has("Restore purchases"), "\(open.reading)")
            XCTAssertTrue(open.has("About the trial"), "\(open.reading)")
            XCTAssertFalse(open.has(Self.errorLine), "\(open.reading)")
            XCTAssertFalse(open.has(Self.termsLine), "\(open.reading)")

            // 2. A pointer on the Monthly card: the record's plan is
            // monthly, and both cards look different; nothing else does.
            // The cards are rows of `for choice in plans key=choice.plan`,
            // and the tap's report names Monthly's row; the machine reads
            // that row's key itself, so this slot is the row report checked
            // by its effect: `choose` ran with Monthly's own plan.
            try await run.tap(open.center(of: "Monthly"))
            let plan = try await run.edge.slot("plan")
            XCTAssertEqual(plan, .enumeration("monthly"), "the tap in Monthly's row did not choose Monthly's plan")
            let monthly = try await run.look("2-monthly-chosen")
            let cards = [try open.region(of: "Yearly"), try open.region(of: "Monthly")]
            XCTAssertTrue(Self.changes(open, monthly, cards[1]), "the Monthly card looks the same")
            XCTAssertTrue(Self.changes(open, monthly, cards[0]), "the Yearly card looks the same")
            XCTAssertTrue(Self.holds(open, monthly, outside: cards), "something outside the two cards changed")

            // 3. A pointer on the buy button: one awaited purchase reaches
            // the store, which holds its answer. The button is disabled, read
            // as not enabled, and dimmed.
            var written = await run.edge.log.count
            try await run.tap(monthly.center(of: "Continue"))
            let buying = try await run.look("3-buying")
            XCTAssertEqual(run.store.calls.map(\.externName), ["purchase"])
            XCTAssertEqual(run.store.calls.map(\.awaited), [true])
            XCTAssertFalse(try buying.isEnabled("Continue"), "\(buying.reading)")
            let buy = try monthly.region(of: "Continue")
            XCTAssertTrue(Self.changes(monthly, buying, buy), "the buy button never looks busy")

            // 4. The store answers a purchase whose status is `failed`: the
            // button is enabled again and the error line shows, with no
            // touch.
            run.store.release()
            await run.edge.storeAnswered()
            try await run.settle()
            let failed = try await run.look("4-failed")
            let answered = await run.edge.log.dropFirst(written).compactMap { entry -> NuxieMachineReply? in
                if case .reply(_, let reply) = entry { return reply }
                return nil
            }
            XCTAssertEqual(answered, [.purchase(.failed)])
            let marked = try await run.edge.slot("purchase_failed")
            XCTAssertEqual(marked, .bool(true))
            XCTAssertTrue(failed.has(Self.errorLine), "\(failed.reading)")
            XCTAssertTrue(try failed.isEnabled("Continue"), "\(failed.reading)")
            XCTAssertTrue(Self.changes(monthly, failed, try failed.region(of: Self.errorLine)),
                          "the error line does not show")
            XCTAssertTrue(Self.holds(monthly, failed, buy), "the buy button stays dimmed")

            // 5. A pointer on "About the trial": the terms line shows.
            try await run.tap(failed.center(of: "About the trial"))
            let details = try await run.look("5-details-open")
            XCTAssertTrue(details.has(Self.termsLine), "\(details.reading)")
            XCTAssertTrue(Self.changes(failed, details, try details.region(of: Self.termsLine)),
                          "the terms line does not show")

            // Then "Not now": the paywall is dismissed, the record stays
            // open, and the evening offer's wake is recorded.
            written = await run.edge.log.count
            try await run.tap(details.center(of: "Not now"))
            let closing = await Array(run.edge.log.dropFirst(written))
            XCTAssertTrue(closing.contains(.dismiss(reason: "paywall_closed")), "\(closing)")
            XCTAssertTrue(closing.contains(.wakeAt(18 * Self.hour)), "\(closing)")
            XCTAssertEqual(run.owner.dismissals, [.machine(reason: "paywall_closed")], "the owner hears one dismissal")
            let stillOpen = try await run.edge.recordOpen()
            XCTAssertTrue(stillOpen, "the record waits for the evening offer")
            let noFault = await run.edge.fault
            XCTAssertNil(noFault)
            XCTAssertEqual(run.store.calls.count, 1, "one call in the whole script")
            try await run.close()
        } catch {
            run.store.release()
            try? await run.close()
            throw error
        }
    }

    /// A swipe down pops the paywall, and the record stays open: the
    /// evening offer's tasks, armed when the paywall opened, are still owed,
    /// and a swipe down runs no `close`. So the record asks for 18:00, the
    /// offer's start. Delivered then, the offer goes live with nothing
    /// presented and asks for 20:00, its end; delivered then, nothing is
    /// left owed and the record ends normally, which the owner hears as the
    /// last row, with no dismissal at any point.
    func testASwipeDownPopsThePaywallAndTheRecordEndsWhenTheOfferHasPassed() async throws {
        let run = try Run()
        do {
            await run.edge.start(event: "onboarding_completed", now: run.now)
            try await run.layOut()
            try await run.settle()
            let open = try await run.look("open")
            try await run.tap(open.center(of: "Monthly"))
            try await run.tap(open.center(of: "Continue"))
            // The stand-in store's answer is delivered in the next frames.
            await run.edge.storeAnswered()
            try await run.tap(open.center(of: "About the trial"))
            let detailsOpen = try await run.look("details-open")
            XCTAssertTrue(detailsOpen.has(Self.termsLine), "\(detailsOpen.reading)")
            let written = await run.edge.log.count
            let current = await run.edge.shown
            let shown = try XCTUnwrap(current)
            await run.edge.closed(shown, now: run.advance())
            let closing = await Array(run.edge.log.dropFirst(written))
            XCTAssertEqual(closing.filter {
                if case .pop = $0 { return true }
                if case .end = $0 { return true }
                return false
            }, [.pop(instance: shown.instance)])
            XCTAssertTrue(closing.contains(.wakeAt(Self.evening)), "the offer's start is not asked for: \(closing)")
            let waiting = try await run.edge.recordOpen()
            XCTAssertTrue(waiting, "a swipe down leaves the offer's tasks owed")
            let noFault = await run.edge.fault
            XCTAssertNil(noFault)
            XCTAssertTrue(run.owner.dismissals.isEmpty, "a swipe down has already closed the sheet")

            // 18:00: the offer goes live with nothing presented, and its end
            // is asked for.
            run.jump(to: Self.evening)
            let beforeEvening = await run.edge.log.count
            await run.edge.wake(now: run.now)
            let evening = await Array(run.edge.log.dropFirst(beforeEvening))
            XCTAssertTrue(evening.contains(.wakeAt(Self.offerEnds)), "the offer's end is not asked for: \(evening)")
            XCTAssertFalse(evening.contains { if case .opened = $0 { true } else { false } },
                           "the offer's start presented something: \(evening)")
            let stillOpen = try await run.edge.recordOpen()
            XCTAssertTrue(stillOpen, "the record ended before the offer did")

            // 20:00: the offer ends, nothing is owed, and the record ends.
            run.jump(to: Self.offerEnds)
            let beforeEnd = await run.edge.log.count
            await run.edge.wake(now: run.now)
            let ending = await Array(run.edge.log.dropFirst(beforeEnd))
            XCTAssertTrue(ending.contains(.end(reason: .finished, fault: nil)), "the record did not end: \(ending)")
            let ended = try await run.edge.recordOpen()
            XCTAssertFalse(ended, "the record is open after the offer passed")
            guard case .delivered(let shownAtEnd, let rows)? = run.owner.reports.last else {
                return XCTFail("\(run.owner.reports)")
            }
            XCTAssertEqual(shownAtEnd, [], "\(rows)")
            XCTAssertEqual(rows.last, .end(.finished), "\(rows)")
            XCTAssertTrue(run.owner.dismissals.isEmpty, "the owner heard a dismissal")
            let stillNoFault = await run.edge.fault
            XCTAssertNil(stillNoFault)
            try await run.close()
        } catch {
            try? await run.close()
            throw error
        }
    }

    /// A store asked for an extern it cannot perform ends in the one fault
    /// path. "Restore purchases" calls `restore`, which this test's store
    /// cannot perform. A stopped edge steps nothing more and tells nothing
    /// more.
    func testAStoreAskedForAnUnknownExternFaults() async throws {
        let run = try Run(refusing: ["restore"])
        do {
            await run.edge.start(event: "onboarding_completed", now: run.now)
            try await run.layOut()
            try await run.settle()
            let open = try await run.look("open")
            try await run.tap(open.center(of: "Restore purchases"))
            // The store's refusal arrives as an answer, which the next frame
            // delivers.
            await run.edge.storeAnswered()
            try await run.settle(frames: 1)
            let recorded = await run.edge.fault
            let fault = try XCTUnwrap(recorded)
            XCTAssertEqual(fault.code, "store.unknown-extern")
            XCTAssertEqual(run.store.calls.map(\.externName), ["restore"])
            XCTAssertEqual(run.owner.dismissals, [.fault(fault)], "the owner hears one dismissal")
            let screen = await run.edge.screen()
            XCTAssertNil(screen, "the fault closed the paywall")
            let afterFault = try await run.tap(open.center(of: "Monthly"))
            XCTAssertEqual(afterFault, [], "a stopped edge steps nothing")
            XCTAssertEqual(run.owner.dismissals.count, 1, "a stopped edge tells nothing more")
            try await run.close()
        } catch {
            try? await run.close()
            throw error
        }
    }

    /// "Restore purchases" with the stand-in store: it answers `restore` as
    /// it answers a purchase, with status `failed`. The paywall then shows
    /// the error line under an enabled buy button, as after a failed
    /// purchase, and the record stays open with nothing faulted.
    func testRestorePurchasesThatFailsShowsTheErrorLine() async throws {
        let run = try Run()
        do {
            await run.edge.start(event: "onboarding_completed", now: run.now)
            try await run.layOut()
            try await run.settle()
            let open = try await run.look("open")
            let written = await run.edge.log.count
            try await run.tap(open.center(of: "Restore purchases"))
            await run.edge.storeAnswered()
            try await run.settle()
            let restored = try await run.look("restore-failed")
            XCTAssertEqual(run.store.calls.map(\.externName), ["restore"])
            let answered = await run.edge.log.dropFirst(written).compactMap { entry -> NuxieMachineReply? in
                if case .reply(_, let reply) = entry { return reply }
                return nil
            }
            XCTAssertEqual(answered, [.purchase(.failed)])
            let marked = try await run.edge.slot("purchase_failed")
            XCTAssertEqual(marked, .bool(true))
            XCTAssertTrue(restored.has(Self.errorLine), "\(restored.reading)")
            XCTAssertTrue(try restored.isEnabled("Continue"), "\(restored.reading)")
            let stillOpen = try await run.edge.recordOpen()
            XCTAssertTrue(stillOpen, "a failed restore ended the record")
            let fault = await run.edge.fault
            XCTAssertNil(fault)
            XCTAssertTrue(run.owner.dismissals.isEmpty, "a failed restore dismissed the paywall")
            try await run.close()
        } catch {
            try? await run.close()
            throw error
        }
    }

    // MARK: Deliveries that meet

    /// A swipe down while the store has not answered the purchase is a
    /// normal close, as the machine's rows say: it pops the paywall with no
    /// `dismiss` row (the gesture has already closed the sheet), and the
    /// record stays open, asking for 18:00, the evening offer's start, whose
    /// tasks a swipe down leaves owed. The owner hears no dismissal and
    /// nothing faults. The store's answer, released after, goes to the
    /// session; the offer's tasks keep the record open, and it tells
    /// nothing.
    func testASwipeDownWhileThePurchaseWaitsIsANormalCloseAndTheOfferStillWaits() async throws {
        let run = try Run(holdingStore: true)
        do {
            await run.edge.start(event: "onboarding_completed", now: run.now)
            try await run.layOut()
            try await run.settle()
            let open = try await run.look("open")
            try await run.tap(open.center(of: "Continue"))
            XCTAssertEqual(run.store.calls.map(\.externName), ["purchase"])
            let written = await run.edge.log.count
            let current = await run.edge.shown
            let shown = try XCTUnwrap(current)
            await run.edge.closed(shown, now: run.advance())
            let closing = await Array(run.edge.log.dropFirst(written))
            XCTAssertEqual(closing, [.pop(instance: shown.instance), .wakeAt(Self.evening), .gone(shown)])
            let waiting = try await run.edge.recordOpen()
            XCTAssertTrue(waiting, "the record waits for the purchase and the offer")
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
            XCTAssertEqual(late.filter { if case .wakeAt = $0 { false } else { true } },
                           [.reply(call.id, .purchase(.failed)), .handOver], "\(late)")
            let failed = try await run.edge.slot("purchase_failed")
            XCTAssertEqual(failed, .bool(true), "the answer did not reach the record")
            let afterAnswer = try await run.edge.recordOpen()
            XCTAssertTrue(afterAnswer, "the answer ended the record while the offer's tasks are owed")
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

    /// A paywall whose "Not now" dismisses and exits while the `restore`
    /// call it started has not been answered.
    private static let leavesPlan = NuxieMachinePlanSource(
        files: [NuxieMachineSourceFile(path: "main.nux", text: """
            use restore, Purchase, PurchaseStatus from "nuxie/store"

            component App
              mutation restored: Purchase  then restored_purchases

              routes
                paywall  Card  sheet
                  restore=restore_purchases
                  close=leave
              entry
                on event "go"
                do go(paywall)

              action restore_purchases
                send restored = restore()

              action restored_purchases
                if restored != none
                  if restored.status == completed
                    dismiss("left")
                    exit

              action leave
                dismiss("left")
                exit

            component Card
              props
                restore: action
                close: action
              view
                column width=100% height=100% padding=24 gap=12 background-color=#0d1214
                  button height=48 justify-content=center press=restore id="restore"
                    text "Restore purchases" color=#eef3f1 font-size=16
                  button height=48 justify-content=center press=close id="close"
                    text "Not now" color=#c9d3d0 font-size=16

            """)],
        assets: [], root: "main", app: "app", experience: "leaves", version: 1)

    /// An answer that arrives after its record ended is dropped: the
    /// machine dropped the call when the record ended, so it is recorded as
    /// dropped, applies nothing, tells nothing and is no fault, even when
    /// the store failed the call.
    func testAnAnswerAfterTheRecordEndedIsDropped() async throws {
        let run = try Run(plan: Self.leavesPlan, holdingStore: true, refusing: ["restore"])
        do {
            await run.edge.start(event: "go", now: run.now)
            try await run.layOut()
            try await run.settle()
            let card = try await run.look("card")
            try await run.tap(card.center(of: "Restore purchases"))
            try await run.tap(card.center(of: "Not now"))
            let open = try await run.edge.recordOpen()
            XCTAssertFalse(open, "leaving ends the record")
            XCTAssertEqual(run.owner.dismissals, [.machine(reason: "left")], "the owner hears one dismissal")

            // The store cannot perform `restore`, and says so after the
            // record ended.
            run.store.release()
            await run.edge.storeAnswered()
            let beforeAnswer = await run.edge.log.count
            try await run.settle(frames: 2)
            let late = await Array(run.edge.log.dropFirst(beforeAnswer))
            let call = try XCTUnwrap(run.store.calls.first)
            XCTAssertEqual(call.externName, "restore")
            XCTAssertEqual(late, [.dropped(call.id, reply: nil)])
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

    /// An answer belongs to the record that issued its call, not to the
    /// record open when it arrives. A store refusal of the first record's
    /// `restore`, released after that record ended and a second started,
    /// is dropped.
    func testARefusalForAnEndedRecordLeavesTheNextRecordAlone() async throws {
        try await checkAnAnswerForAnEndedRecord(answering: [:], refusing: ["restore"], dropped: nil)
    }

    /// The same with a successful awaited answer: it is dropped, not handed
    /// to the second record (whose machine would answer `unknown_call`).
    func testAnAnswerForAnEndedRecordLeavesTheNextRecordAlone() async throws {
        try await checkAnAnswerForAnEndedRecord(answering: ["restore": .purchase(.completed)],
                                                dropped: .purchase(.completed))
    }

    /// Hold `restore`, leave (the record ends), start `go` again (a second
    /// record), then release the store. The second record's showing is
    /// untouched, its owner hears nothing for it, the log has one dropped
    /// entry for the old call, nothing faults, and a tap on the second
    /// record is still handled.
    private func checkAnAnswerForAnEndedRecord(answering: [String: NuxieMachineReply], refusing: Set<String> = [],
                                               dropped reply: NuxieMachineReply?) async throws {
        let run = try Run(plan: Self.leavesPlan, holdingStore: true, answering: answering, refusing: refusing)
        do {
            await run.edge.start(event: "go", now: run.now)
            try await run.layOut()
            try await run.settle()
            let card = try await run.look("first-card")
            try await run.tap(card.center(of: "Restore purchases"))
            try await run.tap(card.center(of: "Not now"))
            let firstOpen = try await run.edge.recordOpen()
            XCTAssertFalse(firstOpen, "leaving ends the first record")
            XCTAssertEqual(run.owner.dismissals, [.machine(reason: "left")])

            await run.edge.start(event: "go", now: run.advance())
            try await run.layOut()
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
            XCTAssertEqual(late, [.dropped(call.id, reply: reply)])
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
            let again = try await run.look("second-card")
            try await run.tap(again.center(of: "Not now"))
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
    /// once: `restore` answered with status `completed` runs `leave`.
    func testAnAnswerForTheOpenRecordsOwnCallIsDeliveredOnce() async throws {
        let run = try Run(plan: Self.leavesPlan, holdingStore: true, answering: ["restore": .purchase(.completed)])
        do {
            await run.edge.start(event: "go", now: run.now)
            try await run.layOut()
            try await run.settle()
            let card = try await run.look("card")
            try await run.tap(card.center(of: "Restore purchases"))
            let written = await run.edge.log.count
            run.store.release()
            await run.edge.storeAnswered()
            try await run.settle(frames: 3)
            let after = await Array(run.edge.log.dropFirst(written))
            let call = try XCTUnwrap(run.store.calls.first)
            XCTAssertEqual(after.filter {
                switch $0 {
                case .reply, .dropped: return true
                default: return false
                }
            }, [.reply(call.id, .purchase(.completed))], "\(after)")
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

    /// A purchase the store could not reach the store for is replied to with
    /// the store's failure, as it gave it. The machine takes it: the
    /// purchase is no longer pending, so the buy button is enabled again,
    /// and a failure runs no `then`, so no error line shows. Nothing faults
    /// and the paywall stays.
    func testAStoreFailureReachesTheMachineAndRunsNothing() async throws {
        let failure = NuxieMachineFailure(code: .offline, reason: "store.unreachable",
                                          message: "You are offline. Try again when you are connected.")
        let run = try Run(holdingStore: true, answering: ["purchase": .failure(failure)])
        do {
            await run.edge.start(event: "onboarding_completed", now: run.now)
            try await run.layOut()
            try await run.settle()
            let open = try await run.look("open")
            try await run.tap(open.center(of: "Continue"))
            let buying = try await run.look("buying")
            XCTAssertFalse(try buying.isEnabled("Continue"), "\(buying.reading)")
            let written = await run.edge.log.count

            run.store.release()
            await run.edge.storeAnswered()
            try await run.settle()
            let after = await Array(run.edge.log.dropFirst(written))
            let call = try XCTUnwrap(run.store.calls.first)
            XCTAssertEqual(after.filter { if case .reply = $0 { return true }; return false },
                           [.reply(call.id, .failure(failure))], "\(after)")
            let settled = try await run.look("settled")
            XCTAssertTrue(try settled.isEnabled("Continue"), "\(settled.reading)")
            XCTAssertFalse(settled.has(Self.errorLine), "\(settled.reading)")
            let marked = try await run.edge.slot("purchase_failed")
            XCTAssertEqual(marked, .bool(false), "a failure runs no `then`")
            let route = try await run.edge.topRoute()
            XCTAssertEqual(route?.route, "paywall")
            let noFault = await run.edge.fault
            XCTAssertNil(noFault)
            XCTAssertEqual(run.owner.dismissals, [])
            try await run.close()
        } catch {
            run.store.release()
            try? await run.close()
            throw error
        }
    }

    /// A second send into a mutation lets the first go: the first call is
    /// still performed, and its reply, when it comes, is for a send no longer
    /// out. "Restore purchases" twice before the store answers sends
    /// `bought = restore()` twice. The older reply, arriving first, is
    /// dropped: logged, nothing applied, no fault. The newer one lands and
    /// runs `purchased`, so the paywall stays and shows the error line.
    func testAReplyToASendANewerSendLetGoIsDropped() async throws {
        let run = try Run(holdingStore: true, answering: ["restore": .purchase(.failed)])
        do {
            await run.edge.start(event: "onboarding_completed", now: run.now)
            try await run.layOut()
            try await run.settle()
            let open = try await run.look("open")
            try await run.tap(open.center(of: "Restore purchases"))
            try await run.settle()
            try await run.tap(open.center(of: "Restore purchases"))
            try await run.settle()
            let calls = run.store.calls
            XCTAssertEqual(calls.map(\.externName), ["restore", "restore"])
            let resting = await run.edge.waitingForFrame()
            XCTAssertFalse(resting, "nothing waits for a frame while the store holds both")

            // The older call's reply arrives and is delivered alone.
            let beforeOlder = await run.edge.log.count
            run.store.release()
            try await waitUntil("the older reply arrived") { await run.edge.waitingForFrame() }
            try await run.settle()
            let older = await Array(run.edge.log.dropFirst(beforeOlder))
            XCTAssertEqual(older.filter(Self.isReplyOrDropped), [.dropped(calls[0].id, reply: .purchase(.failed))],
                           "\(older)")
            let noFault = await run.edge.fault
            XCTAssertNil(noFault, "a late reply to a send no longer out is no fault")
            let stillOpen = try await run.edge.recordOpen()
            XCTAssertTrue(stillOpen)
            let untouched = try await run.edge.slot("purchase_failed")
            XCTAssertEqual(untouched, .bool(false), "a dropped reply applies nothing")

            // The newer call's reply lands: `purchased` marks the failure.
            let beforeNewer = await run.edge.log.count
            run.store.release()
            await run.edge.storeAnswered()
            try await run.settle()
            let newer = await Array(run.edge.log.dropFirst(beforeNewer))
            XCTAssertEqual(newer.filter(Self.isReplyOrDropped), [.reply(calls[1].id, .purchase(.failed))],
                           "\(newer)")
            let marked = try await run.edge.slot("purchase_failed")
            XCTAssertEqual(marked, .bool(true))
            let settled = try await run.look("settled")
            XCTAssertTrue(settled.has(Self.errorLine), "\(settled.reading)")
            let route = try await run.edge.topRoute()
            XCTAssertEqual(route?.route, "paywall")
            let stillNoFault = await run.edge.fault
            XCTAssertNil(stillNoFault)
            XCTAssertEqual(run.owner.dismissals, [])
            XCTAssertEqual(run.store.calls.count, 2)
            try await run.close()
        } catch {
            run.store.release()
            run.store.release()
            try? await run.close()
            throw error
        }
    }

    private static func isReplyOrDropped(_ entry: NuxieMachineEdgeEntry) -> Bool {
        switch entry {
        case .reply, .dropped: return true
        default: return false
        }
    }

    /// Wait, a little at a time and for two seconds at most, until `done`.
    private func waitUntil(_ what: String, _ done: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await done() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("waited two seconds and \(what) did not happen")
    }

    /// A reply whose fields are not those of the declaration's answer type
    /// (a `Purchase` with no status) is refused by the session, and the
    /// refusal takes the one fault path.
    func testAReplyThatDoesNotFitFaults() async throws {
        let run = try Run(holdingStore: true, answering: ["purchase": .answer([])])
        do {
            await run.edge.start(event: "onboarding_completed", now: run.now)
            try await run.layOut()
            try await run.settle()
            let open = try await run.look("open")
            try await run.tap(open.center(of: "Continue"))
            run.store.release()
            await run.edge.storeAnswered()
            try await run.settle(frames: 1)
            let recorded = await run.edge.fault
            let fault = try XCTUnwrap(recorded)
            XCTAssertEqual(fault.code, "machine.reply_does_not_fit")
            XCTAssertEqual(run.owner.dismissals, [.fault(fault)], "the owner hears one dismissal")
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
        let run = try Run(plan: Self.leavesPlan)
        do {
            await run.edge.start(event: "go", now: run.now)
            try await run.layOut()
            try await run.settle()
            let firstShown = await run.edge.shown
            let first = try XCTUnwrap(firstShown)
            let card = try await run.look("first-card")
            try await run.tap(card.center(of: "Not now"))
            XCTAssertEqual(run.owner.dismissals, [.machine(reason: "left")])

            await run.edge.start(event: "go", now: run.advance())
            try await run.layOut()
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

    /// One frame whose pointers tap "Not now" and then "About the trial":
    /// "Not now" dismisses the paywall, so the second tap, on a paywall
    /// the machine no longer shows, changes nothing. Nothing faults, the
    /// owner hears the one dismissal, and the record waits for the evening
    /// offer.
    func testATapAfterItsPaywallWasDismissedInTheSameFrameChangesNothing() async throws {
        let run = try Run()
        do {
            await run.edge.start(event: "onboarding_completed", now: run.now)
            try await run.layOut()
            try await run.settle()
            let open = try await run.look("open")
            let written = await run.edge.log.count
            let touched = await run.edge.shown
            await run.edge.frame(pointers: try Run.press(at: open.center(of: "Not now"))
                                     + Run.press(at: open.center(of: "About the trial")),
                                 on: touched, elapsedSeconds: Self.tick, now: run.advance())
            let after = await Array(run.edge.log.dropFirst(written))
            XCTAssertEqual(after.filter { if case .dismiss = $0 { return true }; return false },
                           [.dismiss(reason: "paywall_closed")], "\(after)")
            let noFault = await run.edge.fault
            XCTAssertNil(noFault, "\(after)")
            XCTAssertEqual(run.owner.dismissals, [.machine(reason: "paywall_closed")])
            let stack = await run.edge.stack
            XCTAssertEqual(stack, [], "the paywall is still shown")
            let waiting = try await run.edge.recordOpen()
            XCTAssertTrue(waiting, "the record waits for the evening offer")
            try await run.close()
        } catch {
            try? await run.close()
            throw error
        }
    }

    /// A touch belongs to the showing the person touched. "Not now" ends
    /// the paywall, and while its sheet animates away the person taps "Not
    /// now" again: those pointers touched a showing that has ended, so they
    /// go to no one. The frames still run, nothing reports, and the record
    /// waits for the evening offer as before, with no fault.
    func testATouchOnAPaywallThatHasGoneGoesNowhere() async throws {
        let run = try Run()
        do {
            await run.edge.start(event: "onboarding_completed", now: run.now)
            try await run.layOut()
            try await run.settle()
            let firstShown = await run.edge.shown
            let first = try XCTUnwrap(firstShown)
            let open = try await run.look("open")
            let notNow = try open.center(of: "Not now")
            try await run.tap(notNow)
            XCTAssertEqual(run.owner.dismissals, [.machine(reason: "paywall_closed")])
            let reports = run.owner.reports.count
            let written = await run.edge.log.count

            let reported = try await run.tap(notNow, touching: first)
            XCTAssertEqual(reported, [], "the departing paywall took the touch")
            let after = await Array(run.edge.log.dropFirst(written))
            XCTAssertEqual(after.filter { if case .droppedTouches = $0 { return true }; return false },
                           [.droppedTouches(first), .droppedTouches(first)], "each frame's pointers go to no one")
            let noFault = await run.edge.fault
            XCTAssertNil(noFault)
            let waiting = try await run.edge.recordOpen()
            XCTAssertTrue(waiting, "the record waits for the evening offer")
            XCTAssertEqual(run.owner.reports.count, reports, "the owner was told something")
            try await run.close()
        } catch {
            try? await run.close()
            throw error
        }
    }

    /// One frame whose pointers tap Monthly and then "Not now": the choice
    /// lands in the record before "Not now" dismisses the paywall in the
    /// same frame. Nothing faults and the owner hears the one dismissal.
    func testAChoiceAndADismissalInOneFrameBothReachTheRecord() async throws {
        let run = try Run()
        do {
            await run.edge.start(event: "onboarding_completed", now: run.now)
            try await run.layOut()
            try await run.settle()
            let open = try await run.look("open")
            let written = await run.edge.log.count
            let touched = await run.edge.shown
            await run.edge.frame(pointers: try Run.press(at: open.center(of: "Monthly"))
                                     + Run.press(at: open.center(of: "Not now")),
                                 on: touched, elapsedSeconds: Self.tick, now: run.advance())
            let after = await Array(run.edge.log.dropFirst(written))
            XCTAssertTrue(after.contains(.dismiss(reason: "paywall_closed")), "\(after)")
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

    /// A tap on another control while the store has not answered is
    /// handled at once; the answer, released after, applies once, and its
    /// changes join the tap's.
    func testATapWhileThePurchaseWaitsIsHandledAndTheAnswerAppliesOnce() async throws {
        let run = try Run(holdingStore: true)
        do {
            await run.edge.start(event: "onboarding_completed", now: run.now)
            try await run.layOut()
            try await run.settle()
            let open = try await run.look("open")
            let written = await run.edge.log.count
            try await run.tap(open.center(of: "Continue"))
            try await run.tap(open.center(of: "About the trial"))
            let waiting = try await run.look("waiting")
            XCTAssertFalse(try waiting.isEnabled("Continue"), "the button is busy while the store has not answered")
            XCTAssertTrue(waiting.has(Self.termsLine), "the tap was handled while the store worked")

            run.store.release()
            await run.edge.storeAnswered()
            try await run.settle()
            let after = await Array(run.edge.log.dropFirst(written))
            XCTAssertEqual(after.filter { if case .reply = $0 { return true }; return false }.count, 1,
                           "the answer applies once: \(after)")
            let settled = try await run.look("settled")
            XCTAssertTrue(try settled.isEnabled("Continue"), "\(settled.reading)")
            XCTAssertTrue(settled.has(Self.errorLine), "\(settled.reading)")
            XCTAssertTrue(settled.has(Self.termsLine), "\(settled.reading)")
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
    /// Monthly, a frame after, a tap on "About the trial", then a swipe
    /// down. Were a delivery to start while another is suspended, the swipe
    /// down would pop the paywall inside a step, and the rest would fault.
    ///
    /// The tasks start on the main actor in the order they are made, so each
    /// reaches the edge before the next one is asked.
    @MainActor
    func testRequestsAskedTogetherApplyInArrivalOrderEachWhole() async throws {
        let run = try Run()
        do {
            await run.edge.start(event: "onboarding_completed", now: run.now)
            try await run.layOut()
            try await run.settle()
            let open = try await run.look("open")
            let written = await run.edge.log.count
            let edge = run.edge
            let current = await edge.shown
            let shown = try XCTUnwrap(current)
            let monthly = try open.center(of: "Monthly")
            let details = Run.press(at: try open.center(of: "About the trial"))
            let at = run.advance()
            let tick = Self.tick
            let requests = [
                Task { _ = await edge.frame(pointers: [Run.pointer(.down, at: monthly)],
                                            on: shown, elapsedSeconds: tick, now: at) },
                Task { _ = await edge.frame(pointers: [Run.pointer(.up, at: monthly)],
                                            on: shown, elapsedSeconds: tick, now: at) },
                Task { _ = await edge.frame(elapsedSeconds: tick, now: at) },
                Task { _ = await edge.frame(pointers: details, on: shown, elapsedSeconds: tick, now: at) },
                Task { await edge.closed(shown, now: at) },
            ]
            for request in requests { await request.value }

            let after = await Array(edge.log.dropFirst(written))
            let noFault = await edge.fault
            XCTAssertNil(noFault, "\(after)")
            // The swipe pops the paywall; the evening offer's tasks keep the
            // record open.
            XCTAssertEqual(after.filter(Self.isPresentation), [.pop(instance: shown.instance)])
            let plan = try await edge.slot("plan")
            XCTAssertEqual(plan, .enumeration("monthly"), "the Monthly tap landed before the swipe")
            let stillOpen = try await edge.recordOpen()
            XCTAssertTrue(stillOpen, "the swipe ended the record while the offer's tasks are owed")
            XCTAssertEqual(run.owner.dismissals, [])
            try await run.close()
        } catch {
            try? await run.close()
            throw error
        }
    }

    // MARK: The evening offer in the plans

    /// The evening offer joins Stillwater's plans while the paywall is up,
    /// in four frames, at moments the test hands the edge:
    ///
    /// 1. 17:59: Yearly, chosen, and Monthly in the "Plan" group, and
    ///    "Continue".
    /// 2. The wake at 18:00: "Tonight only" joins at the top and is chosen
    ///    (the record's plan is `annual_offer`), Yearly and Monthly move down
    ///    one place, and the buy button reads "Claim the offer". The three
    ///    cards are the same size, the list's gap apart. Outside the group
    ///    nothing changes but the buy button, which the third card pushes
    ///    down by a card and a gap and whose words change.
    /// 3. A tap on Monthly: Monthly is chosen, "Continue", no card moves.
    /// 4. The wake at 20:00: the offer leaves, the two cards move back up
    ///    to their 17:59 places, and Monthly stays chosen. Outside the two
    ///    cards the page is the 17:59 page.
    ///
    /// Kept as `stillwater-<n>-evening-1-1759`, `-evening-2-1800`,
    /// `-evening-3-monthly` and `-evening-4-2000`.
    func testTheEveningOfferJoinsAndLeavesThePlans() async throws {
        let run = try Run()
        do {
            // 1. 17:59.
            run.jump(to: Self.evening - Self.minute)
            await run.edge.start(event: "onboarding_completed", now: run.now)
            let started = await run.edge.log
            XCTAssertTrue(started.contains(.wakeAt(Self.evening)), "the start asks for no wake at 18:00: \(started)")
            try await run.layOut()
            try await run.settle()
            let early = try await run.look("evening-1-1759")
            let (_, before) = try Self.plans(early)
            Self.expect(before, ["Yearly", "Monthly"], chosen: "Yearly", "at 17:59")
            Self.expectStacked(before, "at 17:59")
            XCTAssertTrue(early.has("Continue"), "\(early.reading)")
            XCTAssertFalse(early.has("Claim the offer"), "\(early.reading)")
            let place = try XCTUnwrap(before.count == 2 ? before[1].bounds.minY - before[0].bounds.minY : nil,
                                      "no two cards to measure a place by at 17:59")

            // 2. The wake at 18:00.
            run.jump(to: Self.evening)
            await run.edge.wake(now: run.now)
            try await run.settle()
            let joined = try await run.look("evening-2-1800")
            let (group, three) = try Self.plans(joined)
            Self.expect(three, ["Tonight only", "Yearly", "Monthly"], chosen: "Tonight only", "at 18:00")
            Self.expectStacked(three, "at 18:00")
            let offered = try await run.edge.slot("plan")
            XCTAssertEqual(offered, .enumeration("annual_offer"), "the offer did not take Yearly's choice at 18:00")
            XCTAssertTrue(joined.has("Claim the offer"), "\(joined.reading)")
            XCTAssertFalse(joined.has("Continue"), "\(joined.reading)")
            if three.count == 3, before.count == 2 {
                XCTAssertEqual(three[0].bounds.size.height, before[0].bounds.size.height, accuracy: Self.near,
                               "the offer's card is not the size of the others")
                Self.expectNear(three[0].bounds.minY, before[0].bounds.minY, "the offer is not in Yearly's place")
                Self.expectNear(three[1].bounds.minY, before[0].bounds.minY + place, "Yearly did not move down one")
                Self.expectNear(three[2].bounds.minY, before[1].bounds.minY + place, "Monthly did not move down one")
            }
            let buyEarly = try early.region(of: "Continue")
            let buyJoined = try joined.region(of: "Claim the offer")
            Self.expectNear(buyJoined.minY, buyEarly.minY + place, "the buy button did not move down one card")
            XCTAssertTrue(Self.holds(early, joined, outside: [group, buyEarly, buyJoined]),
                          "something outside the plans and the buy button changed at 18:00")

            // 3. A tap on Monthly.
            try await run.tap(joined.center(of: "Monthly"))
            let chose = try await run.look("evening-3-monthly")
            let (_, tapped) = try Self.plans(chose)
            Self.expect(tapped, ["Tonight only", "Yearly", "Monthly"], chosen: "Monthly", "after Monthly's tap")
            let monthly = try await run.edge.slot("plan")
            XCTAssertEqual(monthly, .enumeration("monthly"), "the tap in Monthly's row did not choose Monthly")
            XCTAssertTrue(chose.has("Continue"), "\(chose.reading)")
            for (card, was) in zip(tapped, three) {
                Self.expectNear(card.bounds.minY, was.bounds.minY, "\(card.name) moved on Monthly's tap")
            }
            let buyChose = try chose.region(of: "Continue")
            XCTAssertTrue(Self.holds(joined, chose, outside: three.map(\.bounds) + [buyJoined, buyChose]),
                          "something outside the cards and the buy button changed on Monthly's tap")

            // 4. The wake at 20:00.
            let asked = await run.edge.log
            XCTAssertTrue(asked.contains(.wakeAt(Self.offerEnds)), "nothing asks for a wake at 20:00: \(asked)")
            run.jump(to: Self.offerEnds)
            await run.edge.wake(now: run.now)
            try await run.settle()
            let late = try await run.look("evening-4-2000")
            let (_, after) = try Self.plans(late)
            Self.expect(after, ["Yearly", "Monthly"], chosen: "Monthly", "at 20:00")
            Self.expectStacked(after, "at 20:00")
            let kept = try await run.edge.slot("plan")
            XCTAssertEqual(kept, .enumeration("monthly"), "the offer's end moved Monthly's choice")
            XCTAssertTrue(late.has("Continue"), "\(late.reading)")
            XCTAssertFalse(late.has("Tonight only"), "\(late.reading)")
            for (card, was) in zip(after, before) {
                Self.expectNear(card.bounds.minY, was.bounds.minY, "\(card.name) is not back in its 17:59 place")
            }
            XCTAssertTrue(Self.holds(early, late, outside: before.map(\.bounds)),
                          "outside the two cards, the page at 20:00 is not the 17:59 page")

            let open = try await run.edge.recordOpen()
            XCTAssertTrue(open, "the record ended")
            let fault = await run.edge.fault
            XCTAssertNil(fault)
            try await run.close()
        } catch {
            try? await run.close()
            throw error
        }
    }

    /// One plan card as the semantic tree reads it.
    private struct PlanCard {
        let name: String
        let checked: Bool
        let bounds: CGRect
    }

    private static let planNames = ["Tonight only", "Yearly", "Monthly"]

    /// The "Plan" radio group's bounds, and the radio buttons inside it, in
    /// reading order: each named by the plan its words begin with (or by
    /// all its words, when none), whether it is checked, and where it is.
    private static func plans(_ look: Look) throws -> (group: CGRect, cards: [PlanCard]) {
        let byID = Dictionary(look.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let found = look.nodes.first { NuxieNativeSemanticRole(rawValue: $0.role) == .radioGroup && $0.label == "Plan" }
        let group = try XCTUnwrap(found, "no \"Plan\" group: \(look.reading)")
        func inGroup(_ node: NuxieNativeSemanticNode) -> Bool {
            var parent = node.parentID
            while let id = parent {
                if id == group.id { return true }
                parent = byID[id]?.parentID
            }
            return false
        }
        let cards = look.nodes.filter { NuxieNativeSemanticRole(rawValue: $0.role) == .radioButton && inGroup($0) }
            .map { node in
                PlanCard(name: planNames.first { node.label.hasPrefix($0) } ?? node.label,
                         checked: node.stateFlags & NuxieNativeSemanticNode.checked != 0, bounds: node.bounds)
            }
        return (group.bounds, cards)
    }

    /// The cards read are `names`, in that order, and only `chosen` is
    /// checked.
    private static func expect(_ cards: [PlanCard], _ names: [String], chosen: String, _ when: String) {
        XCTAssertEqual(cards.map(\.name), names, "\(when): the Plan group reads other cards")
        XCTAssertEqual(cards.filter(\.checked).map(\.name), [chosen], "\(when): another card is checked")
    }

    /// The cards are the same size and stacked top to bottom in reading
    /// order, the list's gap apart.
    private static func expectStacked(_ cards: [PlanCard], _ when: String) {
        guard let first = cards.first else { return XCTFail("\(when): no cards") }
        for card in cards.dropFirst() {
            XCTAssertEqual(card.bounds.width, first.bounds.width, accuracy: near, "\(when): \(card.name)'s width")
            XCTAssertEqual(card.bounds.height, first.bounds.height, accuracy: near, "\(when): \(card.name)'s height")
            XCTAssertEqual(card.bounds.minX, first.bounds.minX, accuracy: near, "\(when): \(card.name)'s left edge")
        }
        for (above, below) in zip(cards, cards.dropFirst()) {
            XCTAssertEqual(below.bounds.minY - above.bounds.maxY, cardGap, accuracy: near,
                           "\(when): the gap between \(above.name) and \(below.name)")
        }
    }

    private static func expectNear(_ value: CGFloat, _ expected: CGFloat, _ message: String) {
        XCTAssertEqual(value, expected, accuracy: near, "\(message): \(value), not \(expected)")
    }

    // MARK: What the owner hears

    /// The owner hears each delivery's rows for it, in one report, with
    /// what is shown: the start shows the paywall, with the identity the
    /// session gave it; a tap on a plan shows the same and dismisses
    /// nothing; "Not now" shows nothing and tells its `dismiss` and its
    /// wake. (The machine restates its wake moment in each delivery: 18:00
    /// from the start, the evening offer joining the plans, and 18:00 again
    /// after "Not now", the offer owed for the evening.)
    func testEachDeliveryReportsTheRowsItsOwnerPerforms() async throws {
        let run = try Run()
        do {
            await run.edge.start(event: "onboarding_completed", now: run.now)
            let log = await run.edge.log
            let instance = try XCTUnwrap(Self.presentedInstance(log))
            guard case .delivered(let shown, let started)? = run.owner.reports.first, run.owner.reports.count == 1
            else {
                return XCTFail("\(run.owner.reports)")
            }
            let paywall = NuxieMachinePresented(shown: NuxieMachineShown(journey: 1, instance: instance),
                                                route: "paywall", presentation: .sheet, swipeDown: .closes)
            XCTAssertEqual(shown, [paywall])
            XCTAssertTrue(started.contains(.wakeAt(Self.evening)), "the start asks for the offer's 18:00: \(started)")
            try await run.layOut()
            try await run.settle()
            let open = try await run.look("open")
            let beforeMonthly = run.owner.reports.count
            try await run.tap(open.center(of: "Monthly"))
            for case .delivered(let shownNow, let rows) in run.owner.reports.dropFirst(beforeMonthly) {
                XCTAssertTrue(rows.allSatisfy { $0 == .wakeAt(Self.evening) }, "a plan tap dismisses nothing: \(rows)")
                XCTAssertEqual(shownNow, [paywall], "a plan tap changes what is shown")
            }
            XCTAssertNil(run.owner.reports.dropFirst(beforeMonthly).compactMap(\.dismissal).first)

            try await run.tap(open.center(of: "Not now"))
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

    /// A swipe down's close tells the owner that nothing is shown, with no
    /// dismissal and no end: its last row restates the wake for 18:00, the
    /// evening offer's start, whose tasks a swipe down leaves owed. (The end
    /// it reaches once the offer has passed is in
    /// `testASwipeDownPopsThePaywallAndTheRecordEndsWhenTheOfferHasPassed`.)
    func testASwipeDownReportsThatNothingIsShownAndTheOffersWake() async throws {
        let run = try Run()
        do {
            await run.edge.start(event: "onboarding_completed", now: run.now)
            try await run.layOut()
            try await run.settle()
            let current = await run.edge.shown
            let shown = try XCTUnwrap(current)
            await run.edge.closed(shown, now: run.advance())
            guard case .delivered(let shownNow, let rows)? = run.owner.reports.last else {
                return XCTFail("\(run.owner.reports)")
            }
            XCTAssertEqual(shownNow, [], "\(rows)")
            XCTAssertEqual(rows.last, .wakeAt(Self.evening), "\(rows)")
            XCTAssertFalse(rows.contains(.end(.finished)), "a swipe down ended the record: \(rows)")
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
        let run = try Run()
        do {
            await run.edge.start(event: "onboarding_completed", now: run.now)
            try await run.layOut()
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
    /// Delivered then, the wake runs Stillwater's `offer_ready`, and with
    /// her here its `evening_offer` task runs `show_offer` in the same
    /// delivery, which presents the offer as a sheet: the edge opens it from
    /// the session's records, as it opened the paywall, and the owner hears
    /// it shown.
    func testAWakeAtTheEveningMomentOpensTheOffer() async throws {
        let run = try Run()
        do {
            await run.edge.start(event: "onboarding_completed", now: run.now)
            try await run.layOut()
            try await run.settle()
            let open = try await run.look("open")
            try await run.tap(open.center(of: "Not now"))
            let asked = await run.edge.log
            XCTAssertTrue(asked.contains(.wakeAt(18 * Self.hour)), "\(asked)")
            XCTAssertEqual(run.owner.dismissals, [.machine(reason: "paywall_closed")])
            let written = asked.count

            run.jump(to: 18 * Self.hour)
            await run.edge.wake(now: run.now)
            let fault = await run.edge.fault
            XCTAssertNil(fault)
            let stack = await run.edge.stack
            let offer = try XCTUnwrap(stack.last, "the wake presents nothing")
            XCTAssertEqual(offer.route, "offer")
            XCTAssertEqual(offer.presentation, .sheet)
            let after = await Array(run.edge.log.dropFirst(written))
            XCTAssertTrue(after.contains(.opened(offer.shown)), "\(after)")
            guard case .delivered(let shown, _)? = run.owner.reports.last else {
                return XCTFail("\(run.owner.reports)")
            }
            XCTAssertEqual(shown, [offer])

            try await run.layOut()
            try await run.settle()
            let drawn = try await run.look("offer")
            XCTAssertTrue(drawn.has("A year of quiet minutes, for less."), "\(drawn.reading)")
            XCTAssertTrue(try drawn.isEnabled("Claim the offer"), "\(drawn.reading)")
            XCTAssertTrue(drawn.has("No thanks"), "\(drawn.reading)")
            try await run.close()
        } catch {
            try? await run.close()
            throw error
        }
    }

    /// "Not now" closes the paywall and leaves the evening offer owed: the
    /// record shows nothing, owes nothing on this device and awaits nothing,
    /// so the machine says `hand over` last, after the dismiss and the wake.
    /// The record has not ended, and with no server to carry it to this host
    /// keeps it: the log holds the dismiss, the wake at 18:00 and the hand
    /// over, in that order; nothing is faulted; the owner hears the one
    /// dismissal; the record stays open. At 18:00 the wake reaches it, and
    /// the evening offer opens on this device as before.
    func testAHandOverAfterACloseKeepsTheRecordAndItsWake() async throws {
        let run = try Run()
        do {
            await run.edge.start(event: "onboarding_completed", now: run.now)
            try await run.layOut()
            try await run.settle()
            let open = try await run.look("open")
            let written = await run.edge.log.count
            try await run.tap(open.center(of: "Not now"))
            let after = await Array(run.edge.log.dropFirst(written))
            let kept = after.filter {
                switch $0 {
                case .dismiss, .wakeAt, .handOver: true
                default: false
                }
            }
            XCTAssertEqual(kept, [.dismiss(reason: "paywall_closed"), .wakeAt(18 * Self.hour), .handOver],
                           "\(after)")
            let fault = await run.edge.fault
            XCTAssertNil(fault)
            XCTAssertEqual(run.owner.dismissals, [.machine(reason: "paywall_closed")])
            let waiting = try await run.edge.recordOpen()
            XCTAssertTrue(waiting, "the record handed over is still open")

            run.jump(to: 18 * Self.hour)
            await run.edge.wake(now: run.now)
            let woken = await run.edge.fault
            XCTAssertNil(woken, "the wake after a hand over faulted")
            let stack = await run.edge.stack
            let offer = try XCTUnwrap(stack.last, "the wake presents nothing")
            XCTAssertEqual(offer.route, "offer")
            XCTAssertEqual(offer.presentation, .sheet)
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
        let run = try Run()
        do {
            await run.edge.start(event: "onboarding_completed", now: run.now)
            try await run.layOut()
            try await run.settle()
            let open = try await run.look("open")
            try await run.tap(open.center(of: "Not now"))
            let written = await run.edge.log.count

            await run.edge.wake(now: 2 * 24 * Self.hour + Self.nine)
            let after = await Array(run.edge.log.dropFirst(written))
            XCTAssertEqual(after, [], "a wake at another moment is not the one asked for")
            let waiting = try await run.edge.recordOpen()
            XCTAssertTrue(waiting)
            let noFault = await run.edge.fault
            XCTAssertNil(noFault)
            XCTAssertEqual(run.owner.dismissals, [.machine(reason: "paywall_closed")])

            await run.edge.wake(now: 18 * Self.hour)
            let route = try await run.edge.topRoute()
            XCTAssertEqual(route?.route, "offer", "the wake at the moment asked for reached the machine")
            try await run.close()
        } catch {
            try? await run.close()
            throw error
        }
    }

    // MARK: Leaving the app and coming back

    /// "Not now" at 17:00 leaves the evening offer due at 18:00, and she
    /// leaves the app at 17:00. Back at 09:00 the next day, the one presence
    /// call delivers what she missed, each wake at its own moment with her
    /// still away: at 18:00 the offer is ready and, with her away, waits
    /// six hours for her; at midnight it is given up, and the record ends.
    /// Only the offer's lapse ends it: had 18:00 found her here, the offer
    /// would be presented. Nothing is presented, and the owner hears the end
    /// as the last row.
    func testAwayFromFiveUntilTheNextMorningTheOfferIsGivenUp() async throws {
        let run = try Run()
        do {
            try await closeThePaywallAndLeave(at: Self.five, run)

            let written = await run.edge.log.count
            run.jump(to: Self.day + Self.nine)
            await run.edge.presence(here: true, now: run.now)
            let back = await Array(run.edge.log.dropFirst(written))
            XCTAssertTrue(back.contains(.end(reason: .exited, fault: nil)), "the offer was not given up: \(back)")
            XCTAssertFalse(back.contains { if case .opened = $0 { true } else { false } },
                           "something was presented the next morning: \(back)")
            let open = try await run.edge.recordOpen()
            XCTAssertFalse(open, "the record is open the next morning")
            let stack = await run.edge.stack
            XCTAssertTrue(stack.isEmpty, "\(stack)")
            guard case .delivered(let shown, let rows)? = run.owner.reports.last else {
                return XCTFail("\(run.owner.reports)")
            }
            XCTAssertEqual(shown, [], "\(rows)")
            XCTAssertEqual(rows.last, .end(.exited), "\(rows)")
            XCTAssertEqual(run.owner.dismissals, [.machine(reason: "paywall_closed")], "the owner heard a dismissal")
            let fault = await run.edge.fault
            XCTAssertNil(fault)
            try await run.close()
        } catch {
            try? await run.close()
            throw error
        }
    }

    /// The same evening, back at 19:30: the presence call delivers 18:00
    /// with her away, so the offer is ready and waits for her, and then she
    /// is here, so the offer is presented as a sheet in that same call. The
    /// edge opens it from the session's records, the owner hears it shown,
    /// and it is drawn with its line and its buttons.
    func testAwayFromFiveAndBackAtHalfPastSevenTheOfferIsPresented() async throws {
        let run = try Run()
        do {
            try await closeThePaywallAndLeave(at: Self.five, run)

            let written = await run.edge.log.count
            run.jump(to: Self.evening + 90 * Self.minute)
            await run.edge.presence(here: true, now: run.now)
            let stack = await run.edge.stack
            let offer = try XCTUnwrap(stack.last, "nothing was presented when she came back")
            XCTAssertEqual(offer.route, "offer")
            XCTAssertEqual(offer.presentation, .sheet)
            let back = await Array(run.edge.log.dropFirst(written))
            XCTAssertTrue(back.contains(.opened(offer.shown)), "\(back)")
            let open = try await run.edge.recordOpen()
            XCTAssertTrue(open, "the record ended when she came back")
            guard case .delivered(let shown, _)? = run.owner.reports.last else {
                return XCTFail("\(run.owner.reports)")
            }
            XCTAssertEqual(shown, [offer])

            try await run.layOut()
            try await run.settle()
            let drawn = try await run.look("back-offer")
            XCTAssertTrue(drawn.has("A year of quiet minutes, for less."), "\(drawn.reading)")
            XCTAssertTrue(try drawn.isEnabled("Claim the offer"), "\(drawn.reading)")
            XCTAssertTrue(drawn.has("No thanks"), "\(drawn.reading)")
            let fault = await run.edge.fault
            XCTAssertNil(fault)
            try await run.close()
        } catch {
            try? await run.close()
            throw error
        }
    }

    /// Open the paywall at `moment`, tap "Not now", which leaves the evening
    /// offer due and asks for 18:00, and leave the app a second later. The
    /// record stays open, waiting for 18:00.
    private func closeThePaywallAndLeave(at moment: Int64, _ run: Run) async throws {
        run.jump(to: moment)
        await run.edge.start(event: "onboarding_completed", now: run.now)
        try await run.layOut()
        try await run.settle()
        let open = try await run.look("away-open")
        try await run.tap(open.center(of: "Not now"))
        let closed = await run.edge.log
        XCTAssertTrue(closed.contains(.wakeAt(Self.evening)), "\"Not now\" does not ask for 18:00: \(closed)")
        XCTAssertEqual(run.owner.dismissals, [.machine(reason: "paywall_closed")])
        let written = closed.count
        await run.edge.presence(here: false, now: run.advance())
        let left = await Array(run.edge.log.dropFirst(written))
        XCTAssertEqual(left.first, .presence(here: false), "\(left)")
        let away = try await run.edge.recordOpen()
        XCTAssertTrue(away, "leaving ended the record")
        let fault = await run.edge.fault
        XCTAssertNil(fault, "leaving faulted")
    }

    /// "Not now" dismisses the paywall, and the evening's wake starts a
    /// purchase (in this variant of the plan) with nothing presented. The
    /// store answers with no frame running, and only a frame delivers an
    /// answer: the record takes it with no touch.
    func testAWakeThatStartsAPurchaseWithNothingPresentedMovesTheRecordOnWithNoTouch() async throws {
        let run = try Run(plan: Fixture.purchasingInTheEvening())
        do {
            await run.edge.start(event: "onboarding_completed", now: run.now)
            try await run.layOut()
            try await run.settle()
            let open = try await run.look("open")
            try await run.tap(open.center(of: "Not now"))
            XCTAssertEqual(run.owner.dismissals, [.machine(reason: "paywall_closed")])
            try await run.afterDelivery(onScreen: false)

            let written = await run.edge.log.count
            run.jump(to: 18 * Self.hour)
            await run.edge.wake(now: run.now)
            try await run.afterDelivery(onScreen: false)
            let after = await Array(run.edge.log.dropFirst(written))
            let failed = try await run.edge.slot("purchase_failed")
            XCTAssertEqual(failed, .bool(true), "the store's answer never reached the record: \(after)")
            let fault = await run.edge.fault
            XCTAssertNil(fault)
            try await run.close()
        } catch {
            try? await run.close()
            throw error
        }
    }

    /// A purchase in flight is no work a frame consumes: while the store
    /// holds its answer the edge asks for no frame. The answer asks for the
    /// frame that delivers it, and frames run as a view runs them show the
    /// error line, then rest.
    func testAPurchaseInFlightAsksForNoFrameAndItsAnswerDoes() async throws {
        let run = try Run(holdingStore: true)
        do {
            await run.edge.start(event: "onboarding_completed", now: run.now)
            XCTAssertTrue(run.asks.take(), "the start's writes wait for the paywall's first step")
            try await run.layOut()
            try await run.settle()
            let open = try await run.look("open")
            try await run.tap(open.center(of: "Continue"))
            // Frames for every ask the tap left, none waiting on the store.
            try await run.answerAsks()
            XCTAssertEqual(run.store.calls.map(\.externName), ["purchase"])
            let holding = await run.edge.waitingForFrame()
            XCTAssertFalse(holding, "a purchase in flight waits on the store, not on a frame")
            XCTAssertFalse(run.asks.take(), "a purchase in flight asked for a frame")

            run.store.release()
            await run.edge.storeAnswered()
            XCTAssertTrue(run.asks.take(), "the answer asked for its frame")
            let arrived = await run.edge.waitingForFrame()
            XCTAssertTrue(arrived)
            try await run.runAsAView()
            let failed = try await run.look("failed")
            XCTAssertTrue(failed.has(Self.errorLine), "\(failed.reading)")
            let rested = await run.edge.waitingForFrame()
            XCTAssertFalse(rested, "work waits once the answer has shown")
            XCTAssertFalse(run.asks.take(), "an ask is left unanswered at rest")
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

    // MARK: Pixels

    /// Whether `region` of `after` differs from `before`.
    private static func changes(_ before: Look, _ after: Look, _ region: CGRect) -> Bool {
        moved(before, after, in: region) >= changedAtLeast
    }

    /// Whether `region` of `after` is the region of `before`.
    private static func holds(_ before: Look, _ after: Look, _ region: CGRect) -> Bool {
        moved(before, after, in: region) <= steadyAtMost
    }

    /// Whether everything outside the regions `except` holds. Each region
    /// grows by `edge` on every side.
    private static func holds(_ before: Look, _ after: Look, outside except: [CGRect]) -> Bool {
        let grown = except.map { $0.insetBy(dx: -edge, dy: -edge) }
        return moved(before, after, in: CGRect(origin: .zero, size: Look.size), except: grown) <= steadyAtMost
    }

    /// How many pixels in `region`, and not in `except`, move by more than
    /// `difference` in some channel. Regions are in points.
    private static func moved(_ before: Look, _ after: Look, in region: CGRect, except: [CGRect] = []) -> Int {
        let scale = CGFloat(Look.scale)
        let width = Int(Look.size.width) * Look.scale
        let height = Int(Look.size.height) * Look.scale
        precondition(before.pixels.count == after.pixels.count && before.pixels.count == width * height * 4)
        let pixelRegion = CGRect(x: region.minX * scale, y: region.minY * scale,
                                 width: region.width * scale, height: region.height * scale)
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        let left = except.map {
            CGRect(x: $0.minX * scale, y: $0.minY * scale, width: $0.width * scale, height: $0.height * scale)
        }
        var count = 0
        before.pixels.withUnsafeBytes { first in
            after.pixels.withUnsafeBytes { second in
                for y in Int(pixelRegion.minY)..<Int(pixelRegion.maxY) {
                    for x in Int(pixelRegion.minX)..<Int(pixelRegion.maxX) {
                        let point = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
                        if left.contains(where: { $0.contains(point) }) { continue }
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

// MARK: - One look at the paywall

/// The top presentation drawn at twice its layout size, read back as BGRA,
/// with its semantic snapshot: the nodes a screen reader reads, in reading
/// order, with where each is in points.
struct Look {
    static let scale = 2
    static let size = CGSize(width: 390, height: 844)

    let pixels: Data
    let nodes: [NuxieNativeSemanticNode]

    struct Missing: LocalizedError, CustomStringConvertible {
        let words: String
        let reading: [String]
        var description: String { "nothing reads \"\(words)\" among \(reading)" }
        var errorDescription: String? { description }
    }

    /// The nodes an element stands for, as the Screen's accessibility
    /// container shows them: those with a role, and groups only when named.
    private var read: [NuxieNativeSemanticNode] {
        nodes.filter { node in
            switch NuxieNativeSemanticRole(rawValue: node.role) {
            case nil, .none?: return false
            case .group?, .list?, .listItem?, .tabList?, .dialog?, .alertDialog?, .radioGroup?:
                return !node.label.isEmpty
            default: return true
            }
        }
    }

    /// What a screen reader reads, top to bottom: each element's role and
    /// words, and "not enabled" for a disabled one.
    var reading: [String] {
        read.map { node in
            let role = NuxieNativeSemanticRole(rawValue: node.role).map { "\($0)" } ?? "\(node.role)"
            let disabled = node.stateFlags & NuxieNativeSemanticNode.disabled != 0 ? ", not enabled" : ""
            return "\(role) \"\(node.label)\"\(disabled)"
        }
    }

    /// Whether some element's words begin with `words`.
    func has(_ words: String) -> Bool {
        read.contains { $0.label.hasPrefix(words) }
    }

    /// The first element whose words begin with `words`: a button is named
    /// by all the words beneath it, so a plan card's name is followed by its
    /// price.
    func node(_ words: String) throws -> NuxieNativeSemanticNode {
        guard let found = read.first(where: { $0.label.hasPrefix(words) }) else {
            throw Missing(words: words, reading: reading)
        }
        return found
    }

    func isEnabled(_ words: String) throws -> Bool {
        try node(words).stateFlags & NuxieNativeSemanticNode.disabled == 0
    }

    /// Where the element is, in points.
    func region(of words: String) throws -> CGRect {
        try node(words).bounds
    }

    /// Where an activation presses the element: its center, in points.
    func center(of words: String) throws -> CGPoint {
        let bounds = try region(of: words)
        return CGPoint(x: bounds.midX, y: bounds.midY)
    }
}

// MARK: - One run of the script

/// A fresh session, its clock, and what its store and owner heard.
private final class Run {
    let edge: NuxieMachineEdge
    let store: RecordingStore
    let owner = Owner()
    /// The edge's asks for a frame, as a Screen's view hears them.
    let asks: FrameAskCount
    private(set) var now: Int64 = 9 * 3_600_000
    private var looked = 0

    /// Stillwater's plan, or `plan`. A holding store answers each call only
    /// when the test releases it, `answering` gives a reply for an extern in
    /// place of the stand-in's, and the store cannot perform the externs
    /// `refusing` names.
    init(plan: NuxieMachinePlanSource? = nil, holdingStore: Bool = false,
         answering: [String: NuxieMachineReply] = [:], refusing: Set<String> = []) throws {
        let store = RecordingStore(holds: holdingStore, answering: answering, refusing: refusing)
        self.store = store
        let owner = self.owner
        edge = try NuxieMachineEdge(plan: plan ?? Fixture.load(), store: store,
                                    bytes: NoFolderFiles(), onReport: { owner.heard($0) })
        asks = FrameAskCount(edge)
    }

    /// Move the clock to `moment`, as a host does before delivering a wake:
    /// the machine takes nothing earlier than its last step.
    func jump(to moment: Int64) {
        now = max(now, moment)
    }

    /// The clock a second on.
    func advance() -> Int64 {
        now += 1000
        return now
    }

    /// Lay the top presentation out at a phone's size in points and size
    /// its renderer for a frame drawn at twice that, as a Screen's view
    /// does before its first step.
    func layOut() async throws {
        let screen = try await top()
        try await screen.setLayoutSize(width: Float(Look.size.width), height: Float(Look.size.height))
        _ = try await screen.resize(pixelWidth: UInt32(Look.scale) * UInt32(Look.size.width),
                                    pixelHeight: UInt32(Look.scale) * UInt32(Look.size.height))
    }

    /// Frames with no pointer.
    func settle(frames count: Int = 3) async throws {
        for _ in 0..<count {
            await edge.frame(elapsedSeconds: StillwaterPaywallEdgeTests.tick, now: now)
        }
    }

    /// What a Screen's view does after a delivery of its own (a start, a
    /// wake): nothing, unless the edge asks. Off screen, the engine's own
    /// animation asks for no frame either.
    func afterDelivery(onScreen: Bool) async throws {
        try await settleAsAView(edge, asks: asks, keepGoing: false, onScreen: onScreen,
                                now: { self.now }, elapsedSeconds: StillwaterPaywallEdgeTests.tick)
    }

    /// One frame for each ask the edge made, until it asks no more. Unlike
    /// a view at rest, this never waits on the store's work in flight.
    func answerAsks() async throws {
        for _ in 0..<240 {
            guard asks.take() else { return }
            await edge.frame(elapsedSeconds: StillwaterPaywallEdgeTests.tick, now: now)
        }
        XCTFail("the edge never stopped asking for frames")
    }

    /// Frames run as a view runs them, for the asks made so far.
    func runAsAView() async throws {
        try await settleAsAView(edge, asks: asks, keepGoing: true, onScreen: true,
                                now: { self.now }, elapsedSeconds: StillwaterPaywallEdgeTests.tick)
    }

    /// A press and release at `point`, in points on the Screen.
    static func press(at point: CGPoint) -> [NuxieNativePointerEvent] {
        [pointer(.down, at: point), pointer(.up, at: point)]
    }

    static func pointer(_ kind: NuxieNativePointerKind, at point: CGPoint) -> NuxieNativePointerEvent {
        NuxieNativePointerEvent(kind: kind, x: Float(point.x), y: Float(point.y))
    }

    /// A pointer down and up at `point`, a second after the last call, each
    /// in its own frame, then `framesAfter` frames with no pointer, on the
    /// presentation shown now. What the engine reported in all of them.
    @discardableResult
    func tap(_ point: CGPoint, framesAfter: Int = 3) async throws -> [String] {
        try await tap(point, touching: edge.shown, framesAfter: framesAfter)
    }

    /// The same tap, on the Screen of the showing `touched`: the one the
    /// person's view showed when the pointers arrived.
    @discardableResult
    func tap(_ point: CGPoint, touching touched: NuxieMachineShown?, framesAfter: Int = 3) async throws -> [String] {
        let at = advance()
        var reported: [String] = []
        for kind in [NuxieNativePointerKind.down, .up] {
            reported += await edge.frame(pointers: [Self.pointer(kind, at: point)], on: touched,
                                         elapsedSeconds: StillwaterPaywallEdgeTests.tick, now: at).reported
        }
        for _ in 0..<framesAfter {
            reported += await edge.frame(elapsedSeconds: StillwaterPaywallEdgeTests.tick, now: at).reported
        }
        return reported
    }

    /// The top presentation drawn now with its semantic snapshot, and kept
    /// as a PNG attachment named `stillwater-<n>-<name>`.
    func look(_ name: String) async throws -> Look {
        looked += 1
        let runtime = try await top()
        let width = Look.scale * Int(Look.size.width)
        let height = Look.scale * Int(Look.size.height)
        let (pixels, semantics) = try await Pixels.render(runtime, width: width, height: height,
                                                          scale: Float(Look.scale), capturesSemantics: true)
        try await Pixels.attach(pixels, width: width, height: height, name: "stillwater-\(looked)-\(name)")
        let capture = try XCTUnwrap(semantics, "the frame has no semantic snapshot")
        return Look(pixels: pixels, nodes: capture.tree.visibleReadingOrder)
    }

    func close() async throws {
        try await edge.close()
    }

    private func top() async throws -> NuxieNativeRuntime {
        let screen = await edge.screen()
        return try XCTUnwrap(screen, "nothing is presented")
    }
}

/// A store that hands every call to the stand-in, or answers it with the
/// reply `answering` gives for its extern, or cannot perform it when
/// `refusing` names its extern, and keeps them. A holding one gives each
/// answer only when the test releases it: a release that comes before its
/// call lets that call answer at once.
private final class RecordingStore: NuxieMachineStore, @unchecked Sendable {
    private let lock = NSLock()
    private var received: [NuxieMachineCall] = []
    private let standIn = NuxieMachineStandInStore()
    private let holds: Bool
    private let answering: [String: NuxieMachineReply]
    private let refusing: Set<String>
    private var held: [CheckedContinuation<Void, Never>] = []
    private var releasedEarly = 0

    init(holds: Bool, answering: [String: NuxieMachineReply], refusing: Set<String>) {
        self.holds = holds
        self.answering = answering
        self.refusing = refusing
    }

    var calls: [NuxieMachineCall] {
        lock.withLock { received }
    }

    func perform(_ call: NuxieMachineCall) async throws -> NuxieMachineReply {
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
        if refusing.contains(call.externName) { throw NuxieMachineStoreFault.unknownExtern(call.externName) }
        if let reply = answering[call.externName] { return reply }
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

/// `Fixtures/stillwater`: Stillwater's five program files and the plan's
/// header, copied from the parent repository's compiler fixtures. The
/// host app bundles the same files. The folder's `main.test.nux` is copied
/// for provenance only: `load()` names the program files, so the session
/// is never handed the tests.
enum Fixture {
    private final class Anchor {}

    private struct Provenance: Decodable {
        struct Plan: Decodable {
            let root: String
            let app: String
            let experience: String
            let version: UInt32
        }
        let plan: Plan
    }

    static func load() throws -> NuxieMachinePlanSource {
        func data(_ name: String) throws -> Data {
            let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
            let url = try XCTUnwrap(Bundle(for: Anchor.self).url(
                forResource: parts[0], withExtension: parts[1], subdirectory: "stillwater"),
                "the test bundle carries stillwater/\(name)")
            return try Data(contentsOf: url)
        }
        let provenance = try JSONDecoder().decode(Provenance.self, from: data("provenance.json"))
        let files = try ["main.nux", "paywall.nux", "plan-card.nux", "screens.nux", "done.nux"].map {
            NuxieMachineSourceFile(path: $0, text: String(decoding: try data($0), as: UTF8.self))
        }
        return NuxieMachinePlanSource(files: files, assets: [], root: provenance.plan.root, app: provenance.plan.app,
                                      experience: provenance.plan.experience, version: provenance.plan.version)
    }

    /// Stillwater's plan with the evening's `show_offer` starting a purchase
    /// of the offer in place of presenting it, so the wake moves the record
    /// on with nothing presented. `show_offer` is run by the
    /// `evening_offer` task, once the offer is ready and she is here.
    static func purchasingInTheEvening() throws -> NuxieMachinePlanSource {
        let plan = try load()
        let presents = "  action show_offer\n    ready = false\n    go(offer)\n"
        let purchases = "  action show_offer\n    ready = false\n"
            + "    send bought = purchase(catalog[annual_offer])\n"
        let files = try plan.files.map { file -> NuxieMachineSourceFile in
            guard file.path == "main.nux" else { return file }
            _ = try XCTUnwrap(file.text.range(of: presents), "main.nux presents the offer in the evening")
            return NuxieMachineSourceFile(path: file.path,
                                          text: file.text.replacingOccurrences(of: presents, with: purchases))
        }
        return NuxieMachinePlanSource(files: files, assets: plan.assets, root: plan.root, app: plan.app,
                                      experience: plan.experience, version: plan.version)
    }
}

// MARK: - Reading frames back

enum Pixels {
    /// One frame of the engine's Screen into a drawable at `scale` pixels a
    /// point, cleared to `clearColor` first, read back as BGRA rows, as the
    /// SDK's native runtime tests read theirs; with `capturesSemantics`,
    /// also its semantic snapshot.
    static func render(_ runtime: NuxieNativeRuntime, width: Int, height: Int, scale: Float,
                       clearColor: UInt32 = 0xFF00_0000,
                       capturesSemantics: Bool) async throws -> (Data, NuxieNativeSemanticCapture?) {
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
        let drawn = Signal()
        let frame = try await runtime.renderFrame(layoutScaleFactor: scale,
            drawable: .available(NuxieNativeDrawable(drawable)), clearColor: clearColor,
            readback: NuxieNativeFrameReadback(buffer: buffer, bytesPerRow: bytesPerRow),
            capturesSemantics: capturesSemantics, completion: { drawn.fire() })
        try await drawn.wait(seconds: 2)
        XCTAssertEqual(frame.outcome.disposition, .presented)
        let source = buffer.contents().assumingMemoryBound(to: UInt8.self)
        var pixels = Data(capacity: width * height * 4)
        for row in 0..<height {
            pixels.append(source + row * bytesPerRow, count: width * 4)
        }
        return (pixels, frame.semantics)
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
