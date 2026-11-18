#if os(iOS) && !targetEnvironment(macCatalyst)
import XCTest
import NuxieMachine

/// The sheet presenter's state machine with no UIKit: events in, the state
/// and the UIKit, timer and edge work it asks for out. Each expectation is
/// what a person would see: a sheet that the machine dismissed is gone, a
/// sheet the person swiped away does not come back, and the host says what
/// happened to the record.
final class NuxieMachineSheetStateTests: XCTestCase {
    private typealias State = NuxieMachineSheetState

    private let paywall = NuxieMachineShown(showing: 1, instance: 2)
    private let evening: Int64 = 18 * 3_600_000
    private let noArtwork = NuxieMachineEdgeFault(code: "edge.no-artwork", detail: "present offer")

    /// Started, presented, and up, as after "Finish onboarding".
    private func sheetUp() -> State {
        var state = State()
        XCTAssertEqual(state.handle(.started), [])
        XCTAssertEqual(state.handle(.report(.rows([.present(paywall, presentation: .sheet)]))), [.present(paywall)])
        XCTAssertEqual(state.sheet, .arriving(paywall, leaving: false))
        XCTAssertEqual(state.handle(.presented), [])
        XCTAssertEqual(state.sheet, .up(paywall))
        XCTAssertEqual(state.record, .open(wakeAt: nil))
        return state
    }

    /// After "Not now": the sheet is gone and the record waits for 18:00.
    private func waitingForEvening() -> State {
        var state = sheetUp()
        XCTAssertEqual(state.handle(.report(.rows([.dismiss(reason: "paywall_closed"), .wakeAt(evening)]))),
                       [.dismiss, .schedule(evening)])
        XCTAssertEqual(state.handle(.dismissed), [])
        XCTAssertEqual(state.sheet, .none)
        XCTAssertEqual(state.record, .open(wakeAt: evening))
        return state
    }

    // MARK: A fault the log never shows (finding 1)

    /// The evening wake presents a route with no artwork: the edge reports
    /// only the fault. The record is faulted, the timer is cancelled, and
    /// everything stops, with no sheet to dismiss.
    func testAFaultReportedWithNoRowsFaultsTheRecord() {
        var state = waitingForEvening()
        XCTAssertEqual(state.dueWake(at: evening), evening)
        XCTAssertEqual(state.handle(.wakeTaken(evening)), [.schedule(nil)])
        XCTAssertEqual(state.record, .open(wakeAt: nil))
        XCTAssertEqual(state.handle(.report(.fault(noArtwork))), [.schedule(nil), .stop(noArtwork), .release])
        XCTAssertEqual(state.record, .faulted(noArtwork))
        XCTAssertEqual(state.sheet, .none)
        XCTAssertNil(state.dueWake(at: .max))
    }

    /// An engine step that fails while the sheet is up: the sheet goes.
    func testAFaultWhileTheSheetIsUpDismissesIt() {
        var state = sheetUp()
        let step = NuxieMachineEdgeFault(code: "engine.step", detail: "closed")
        XCTAssertEqual(state.handle(.report(.fault(step))), [.schedule(nil), .stop(step), .dismiss])
        XCTAssertEqual(state.sheet, .leaving(paywall))
        XCTAssertEqual(state.handle(.dismissed), [.release])
        XCTAssertEqual(state.sheet, .none)
        XCTAssertEqual(state.record, .faulted(step))
    }

    // MARK: A machine dismissal during a swipe (finding 2)

    /// The machine dismisses while the person is swiping, and the person
    /// lets go: the swipe is cancelled and the sheet comes back, so the
    /// machine's dismissal is performed then. The machine is not told
    /// `closed`.
    func testAMachineDismissalDuringACancelledSwipeIsPerformedAfterIt() {
        var state = sheetUp()
        XCTAssertEqual(state.handle(.swipeBegan), [])
        XCTAssertEqual(state.handle(.report(.rows([.dismiss(reason: "paywall_closed")]))), [],
                       "nothing is dismissed while UIKit runs the swipe")
        XCTAssertEqual(state.sheet, .swiping(paywall, leaving: true))
        XCTAssertEqual(state.handle(.swipeEnded(completed: false)), [.dismiss])
        XCTAssertEqual(state.sheet, .leaving(paywall))
        XCTAssertEqual(state.handle(.dismissed), [])
        XCTAssertEqual(state.sheet, .none)
        XCTAssertEqual(state.record, .open(wakeAt: nil))
    }

    /// The machine dismisses while the person is swiping, and the swipe
    /// takes the sheet: it is gone once, and the machine, which already
    /// dismissed it, is not told `closed`.
    func testAMachineDismissalDuringACompletedSwipeClosesNothing() {
        var state = sheetUp()
        _ = state.handle(.swipeBegan)
        _ = state.handle(.report(.rows([.dismiss(reason: "paywall_closed")])))
        XCTAssertEqual(state.handle(.swipeEnded(completed: true)), [])
        XCTAssertEqual(state.sheet, .none)
        // UIKit's second word on the same swipe changes nothing.
        XCTAssertEqual(state.handle(.swipeEnded(completed: true)), [])
        XCTAssertEqual(state.record, .open(wakeAt: nil))
    }

    /// The mirror: the person's swipe takes the sheet first, and the
    /// machine's dismissal arrives just after (from a delivery already under
    /// way). The machine hears `closed` for the showing the swipe took, and
    /// its late dismissal and pop dismiss nothing.
    func testAMachineDismissalJustAfterASwipeDismissesNothing() {
        var state = sheetUp()
        _ = state.handle(.swipeBegan)
        XCTAssertEqual(state.handle(.swipeEnded(completed: true)), [.close(paywall)])
        XCTAssertEqual(state.sheet, .none)
        XCTAssertEqual(state.handle(.report(.rows([.dismiss(reason: "paywall_closed")]))), [])
        XCTAssertEqual(state.handle(.report(.rows([.pop(paywall), .end(.finished)]))),
                       [.schedule(nil), .stop(nil), .release])
        XCTAssertEqual(state.sheet, .none)
        XCTAssertEqual(state.record, .ended)
    }

    /// A swipe the person lets go of, with nothing else asking, leaves the
    /// sheet up, and a later machine dismissal still dismisses it.
    func testACancelledSwipeLeavesTheSheetUp() {
        var state = sheetUp()
        _ = state.handle(.swipeBegan)
        XCTAssertEqual(state.handle(.swipeEnded(completed: false)), [])
        XCTAssertEqual(state.sheet, .up(paywall))
        XCTAssertEqual(state.handle(.report(.rows([.dismiss(reason: nil)]))), [.dismiss])
    }

    /// A dismissal that arrives while the sheet is still going up waits for
    /// it to be up.
    func testADismissalWhileTheSheetArrivesWaitsForIt() {
        var state = State()
        _ = state.handle(.started)
        _ = state.handle(.report(.rows([.present(paywall, presentation: .sheet)])))
        XCTAssertEqual(state.handle(.report(.rows([.dismiss(reason: nil)]))), [])
        XCTAssertEqual(state.handle(.presented), [.dismiss])
        XCTAssertEqual(state.sheet, .leaving(paywall))
    }

    // MARK: A failed presentation stays a fault (finding 3)

    /// The host cannot present the sheet: the record is faulted and stays
    /// faulted, whatever comes after.
    func testAPresentationThatFailsStaysAFault() {
        var state = State()
        _ = state.handle(.started)
        XCTAssertEqual(state.handle(.report(.rows([.present(paywall, presentation: .sheet), .wakeAt(evening)]))),
                       [.present(paywall), .schedule(evening)])
        let noHost = NuxieMachineEdgeFault(code: "edge.no-host", detail: "the host is off screen")
        XCTAssertEqual(state.handle(.presentFailed(noHost)), [.schedule(nil), .stop(noHost), .release])
        XCTAssertEqual(state.record, .faulted(noHost))
        XCTAssertEqual(state.sheet, .none)

        // Nothing later moves it.
        XCTAssertEqual(state.handle(.report(.rows([.wakeAt(evening)]))), [])
        XCTAssertEqual(state.handle(.presented), [])
        XCTAssertEqual(state.handle(.report(.rows([.end(.finished)]))), [])
        XCTAssertEqual(state.handle(.hostFault(noArtwork)), [])
        XCTAssertEqual(state.handle(.started), [])
        XCTAssertEqual(state.record, .faulted(noHost))
    }

    /// A present the presenter cannot build is a fault, and so is a second
    /// sheet while the first is still on screen.
    func testAPresentationThatIsNotASheetFaults() {
        var state = State()
        _ = state.handle(.started)
        let effects = state.handle(.report(.rows([.present(paywall, presentation: .push)])))
        guard case .faulted(let fault) = state.record else { return XCTFail("\(state.record)") }
        XCTAssertEqual(fault.code, "edge.unsupported-presentation")
        XCTAssertEqual(effects, [.schedule(nil), .stop(fault), .release])

        var twice = sheetUp()
        _ = twice.handle(.report(.rows([.present(NuxieMachineShown(showing: 2, instance: 3), presentation: .sheet)])))
        guard case .faulted(let second) = twice.record else { return XCTFail("\(twice.record)") }
        XCTAssertEqual(second.code, "edge.no-host")
        XCTAssertEqual(twice.sheet, .leaving(paywall))
    }

    // MARK: Waking and ending

    /// The record's wake moment follows its last `wake at`; a wake is taken
    /// only at that moment; the end cancels the timer and stops.
    func testWakesAndTheEnd() {
        var state = waitingForEvening()
        XCTAssertNil(state.dueWake(at: evening - 1))
        XCTAssertEqual(state.handle(.wakeTaken(evening + 1)), [], "a wake at another moment is not the one asked for")
        XCTAssertEqual(state.record, .open(wakeAt: evening))
        XCTAssertEqual(state.handle(.report(.rows([.wakeAt(nil)]))), [.schedule(nil)])
        XCTAssertNil(state.dueWake(at: .max))
        XCTAssertEqual(state.handle(.report(.rows([.end(.exited)]))), [.schedule(nil), .stop(nil), .release])
        XCTAssertEqual(state.record, .ended)
        XCTAssertEqual(state.handle(.report(.fault(noArtwork))), [], "an ended record stays ended")
        XCTAssertEqual(state.record, .ended)
    }

    /// The record ends while the person swipes (a store answer that ends
    /// it), and the swipe is cancelled: the sheet still goes.
    func testAnEndDuringACancelledSwipeStillDismisses() {
        var state = sheetUp()
        _ = state.handle(.swipeBegan)
        XCTAssertEqual(state.handle(.report(.rows([.end(.finished)]))), [.schedule(nil), .stop(nil)])
        XCTAssertEqual(state.handle(.swipeEnded(completed: false)), [.dismiss])
        XCTAssertEqual(state.sheet, .leaving(paywall))
        XCTAssertEqual(state.handle(.dismissed), [.release])
    }

    // MARK: Letting go (review round 2)

    /// Every event a presenter can still hear once it has let go. None of
    /// them says `release` again or moves the record.
    private func lateEvents() -> [State.Event] {
        [.dismissed, .presented, .swipeBegan, .swipeEnded(completed: true), .swipeEnded(completed: false),
         .report(.rows([.dismiss(reason: nil), .wakeAt(evening), .end(.finished)])),
         .report(.fault(noArtwork)), .hostFault(noArtwork), .wakeTaken(evening), .started,
         .presentFailed(noArtwork)]
    }

    private func assertReleasedForGood(_ state: State, file: StaticString = #filePath, line: UInt = #line) {
        var state = state
        XCTAssertTrue(state.released, file: file, line: line)
        let record = state.record
        for event in lateEvents() {
            XCTAssertFalse(state.handle(event).contains(.release), "\(event)", file: file, line: line)
        }
        XCTAssertEqual(state.record, record, file: file, line: line)
    }

    /// The record ends while the sheet is up: the edge stops at once, and
    /// the presenter lets go only once UIKit has finished the dismissal.
    func testAnEndReleasesOnceTheDismissalIsOver() {
        var state = sheetUp()
        XCTAssertEqual(state.handle(.report(.rows([.end(.finished)]))), [.schedule(nil), .stop(nil), .dismiss])
        XCTAssertFalse(state.released, "the sheet is still leaving")
        XCTAssertEqual(state.handle(.dismissed), [.release])
        assertReleasedForGood(state)
    }

    /// The person's swipe takes the sheet, the machine hears `closed`, and
    /// its answer ends the record: the presenter lets go then, with the end.
    func testASwipeThatTookTheSheetThenTheEndReleasesWithTheEnd() {
        var state = sheetUp()
        _ = state.handle(.swipeBegan)
        XCTAssertEqual(state.handle(.swipeEnded(completed: true)), [.close(paywall)])
        XCTAssertFalse(state.released, "the record is still open")
        XCTAssertEqual(state.handle(.report(.rows([.pop(paywall), .end(.finished)]))),
                       [.schedule(nil), .stop(nil), .release])
        assertReleasedForGood(state)
    }

    /// The record ends while the person swipes, and the swipe takes the
    /// sheet: the presenter lets go when the swipe is over.
    func testAnEndDuringASwipeThatTakesTheSheetReleasesAfterIt() {
        var state = sheetUp()
        _ = state.handle(.swipeBegan)
        XCTAssertEqual(state.handle(.report(.rows([.end(.finished)]))), [.schedule(nil), .stop(nil)])
        XCTAssertFalse(state.released, "UIKit is still running the swipe")
        XCTAssertEqual(state.handle(.swipeEnded(completed: true)), [.release])
        assertReleasedForGood(state)
    }

    /// A fault while the sheet is still going up: it goes once it is up,
    /// and the presenter lets go after that.
    func testAFaultWhileTheSheetArrivesReleasesAfterItHasGone() {
        var state = State()
        _ = state.handle(.started)
        _ = state.handle(.report(.rows([.present(paywall, presentation: .sheet)])))
        XCTAssertEqual(state.handle(.report(.fault(noArtwork))), [.schedule(nil), .stop(noArtwork)])
        XCTAssertFalse(state.released)
        XCTAssertEqual(state.handle(.presented), [.dismiss])
        XCTAssertFalse(state.released)
        XCTAssertEqual(state.handle(.dismissed), [.release])
        assertReleasedForGood(state)
    }

    /// A fault while the person swipes: the presenter lets go when the swipe
    /// takes the sheet, or, when the person lets go of it, after the
    /// dismissal the fault asked for.
    func testAFaultDuringASwipeReleasesWhenTheSheetHasGone() {
        let step = NuxieMachineEdgeFault(code: "engine.step", detail: "closed")
        var taken = sheetUp()
        _ = taken.handle(.swipeBegan)
        XCTAssertEqual(taken.handle(.report(.fault(step))), [.schedule(nil), .stop(step)])
        XCTAssertEqual(taken.handle(.swipeEnded(completed: true)), [.release])
        assertReleasedForGood(taken)

        var kept = sheetUp()
        _ = kept.handle(.swipeBegan)
        _ = kept.handle(.report(.fault(step)))
        XCTAssertEqual(kept.handle(.swipeEnded(completed: false)), [.dismiss])
        XCTAssertFalse(kept.released)
        XCTAssertEqual(kept.handle(.dismissed), [.release])
        assertReleasedForGood(kept)
    }

    /// A fault with no sheet (the evening wake's route has no artwork), a
    /// presentation that failed, and an edge that never opened: the
    /// presenter lets go with the fault.
    func testAFaultWithNoSheetReleasesWithTheFault() {
        var waiting = waitingForEvening()
        XCTAssertEqual(waiting.handle(.report(.fault(noArtwork))), [.schedule(nil), .stop(noArtwork), .release])
        assertReleasedForGood(waiting)

        var failed = State()
        _ = failed.handle(.started)
        _ = failed.handle(.report(.rows([.present(paywall, presentation: .sheet)])))
        let noHost = NuxieMachineEdgeFault(code: "edge.no-host", detail: "the host is off screen")
        XCTAssertEqual(failed.handle(.presentFailed(noHost)), [.schedule(nil), .stop(noHost), .release])
        assertReleasedForGood(failed)

        var neverOpened = State()
        let open = NuxieMachineEdgeFault(code: "edge.open", detail: "the plan did not compile")
        XCTAssertEqual(neverOpened.handle(.hostFault(open)), [.schedule(nil), .stop(open), .release])
        assertReleasedForGood(neverOpened)
    }

    /// An open record keeps everything, with no sheet as with one: after
    /// "Not now", across its wake, and while nothing is presented.
    func testAnOpenRecordWithNoSheetIsNotReleased() {
        var state = waitingForEvening()
        XCTAssertFalse(state.released)
        XCTAssertEqual(state.handle(.wakeTaken(evening)), [.schedule(nil)])
        XCTAssertEqual(state.handle(.report(.rows([.wakeAt(evening + 1)]))), [.schedule(evening + 1)])
        XCTAssertEqual(state.handle(.dismissed), [])
        XCTAssertEqual(state.handle(.swipeEnded(completed: true)), [])
        XCTAssertEqual(state.sheet, .none)
        XCTAssertEqual(state.record, .open(wakeAt: evening + 1))
        XCTAssertFalse(state.released)

        var started = State()
        XCTAssertEqual(started.handle(.started), [])
        XCTAssertFalse(started.released)
    }
}
#endif
