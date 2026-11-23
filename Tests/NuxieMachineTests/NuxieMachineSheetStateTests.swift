#if os(iOS) && !targetEnvironment(macCatalyst)
import XCTest
import NuxieMachine

/// The presenter's state machine with no UIKit: events in, the state and the
/// UIKit, timer and edge work it asks for out. Each expectation is what a
/// person would see: a presentation the machine no longer shows is gone, a
/// sheet the person swiped away does not come back, a sheet over a cover is
/// two native presentations, and the host says what happened to the record.
final class NuxieMachineSheetStateTests: XCTestCase {
    private typealias State = NuxieMachineSheetState

    private let paywall = NuxieMachinePresented(shown: NuxieMachineShown(journey: 1, instance: 2), route: "paywall",
                                                presentation: .sheet)
    private let offer = NuxieMachinePresented(shown: NuxieMachineShown(journey: 1, instance: 5), route: "offer",
                                              presentation: .cover)
    private let cover = NuxieMachinePresented(shown: NuxieMachineShown(journey: 1, instance: 1), route: "first",
                                              presentation: .cover)
    private let sheet = NuxieMachinePresented(shown: NuxieMachineShown(journey: 1, instance: 3), route: "second",
                                              presentation: .sheet)
    private let evening: Int64 = 18 * 3_600_000
    private let noArtwork = NuxieMachineEdgeFault(code: "edge.no-artwork", detail: "present offer")

    private func shows(_ shown: [NuxieMachinePresented], _ rows: [NuxieMachineHostRow] = []) -> State.Event {
        .report(.delivered(shown: shown, rows: rows))
    }

    /// Started, presented, and up, as after "Finish onboarding".
    private func sheetUp() -> State {
        var state = State()
        XCTAssertEqual(state.handle(.started), [])
        XCTAssertEqual(state.handle(shows([paywall])), [.present(paywall, over: nil)])
        XCTAssertEqual(state.natives, [State.Native(presented: paywall, phase: .arriving)])
        XCTAssertEqual(state.handle(.presented(paywall.shown)), [])
        XCTAssertEqual(state.natives, [State.Native(presented: paywall, phase: .up)])
        XCTAssertEqual(state.record, .open(wakeAt: nil))
        return state
    }

    /// After "Not now": the sheet is gone and the record waits for 18:00.
    private func waitingForEvening() -> State {
        var state = sheetUp()
        XCTAssertEqual(state.handle(shows([], [.dismiss(reason: "paywall_closed"), .wakeAt(evening)])),
                       [.schedule(evening), .dismiss(paywall.shown)])
        XCTAssertEqual(state.handle(.dismissed(paywall.shown)), [])
        XCTAssertEqual(state.natives, [])
        XCTAssertEqual(state.record, .open(wakeAt: evening))
        return state
    }

    /// A cover up, then a sheet presented over it and up.
    private func sheetOverCover() -> State {
        var state = State()
        _ = state.handle(.started)
        XCTAssertEqual(state.handle(shows([cover])), [.present(cover, over: nil)])
        XCTAssertEqual(state.handle(.presented(cover.shown)), [])
        XCTAssertEqual(state.handle(shows([cover, sheet])), [.present(sheet, over: cover.shown)])
        XCTAssertEqual(state.handle(.presented(sheet.shown)), [])
        XCTAssertEqual(state.natives.map(\.shown), [cover.shown, sheet.shown])
        return state
    }

    // MARK: Who a screen reader reaches

    /// A screen reader reaches the top presentation that is not leaving: a
    /// cover is out of reach from the moment a sheet starts to arrive over
    /// it, and in reach again from the moment the sheet starts to leave. A
    /// sheet being swiped is still in reach.
    func testAScreenReaderReachesOnlyTheTopPresentation() {
        var state = State()
        XCTAssertNil(state.reachable)
        _ = state.handle(.started)
        XCTAssertEqual(state.handle(shows([cover])), [.present(cover, over: nil)])
        XCTAssertEqual(state.reachable, cover.shown, "a cover is in reach as it arrives")
        _ = state.handle(.presented(cover.shown))
        XCTAssertEqual(state.handle(shows([cover, sheet])), [.present(sheet, over: cover.shown)])
        XCTAssertEqual(state.reachable, sheet.shown, "the cover is out of reach as the sheet arrives")
        _ = state.handle(.presented(sheet.shown))
        XCTAssertEqual(state.reachable, sheet.shown)
        _ = state.handle(.swipeBegan(sheet.shown))
        XCTAssertEqual(state.reachable, sheet.shown, "a sheet being swiped is still in reach")
        _ = state.handle(.swipeEnded(sheet.shown, completed: false))
        XCTAssertEqual(state.handle(shows([cover])), [.dismiss(sheet.shown)])
        XCTAssertEqual(state.reachable, cover.shown, "the cover is in reach again as the sheet leaves")
        _ = state.handle(.dismissed(sheet.shown))
        XCTAssertEqual(state.reachable, cover.shown)
        XCTAssertEqual(state.handle(shows([])), [.dismiss(cover.shown)])
        XCTAssertNil(state.reachable, "nothing is in reach as the last presentation leaves")
    }

    // MARK: A fault the log never shows

    /// The evening wake presents a route with no artwork: the edge reports
    /// only the fault. The record is faulted, the timer is cancelled, and
    /// everything stops, with nothing to dismiss.
    func testAFaultReportedWithNoRowsFaultsTheRecord() {
        var state = waitingForEvening()
        XCTAssertEqual(state.dueWake(at: evening), evening)
        XCTAssertEqual(state.handle(.wakeTaken(evening)), [.schedule(nil)])
        XCTAssertEqual(state.record, .open(wakeAt: nil))
        XCTAssertEqual(state.handle(.report(.fault(noArtwork))), [.schedule(nil), .stop(noArtwork), .release])
        XCTAssertEqual(state.record, .faulted(noArtwork))
        XCTAssertEqual(state.natives, [])
        XCTAssertNil(state.dueWake(at: .max))
    }

    /// An engine step that fails while the sheet is up: the sheet goes.
    func testAFaultWhileTheSheetIsUpDismissesIt() {
        var state = sheetUp()
        let step = NuxieMachineEdgeFault(code: "engine.step", detail: "closed")
        XCTAssertEqual(state.handle(.report(.fault(step))), [.schedule(nil), .stop(step), .dismiss(paywall.shown)])
        XCTAssertEqual(state.natives, [State.Native(presented: paywall, phase: .leaving)])
        XCTAssertEqual(state.handle(.dismissed(paywall.shown)), [.release])
        XCTAssertEqual(state.natives, [])
        XCTAssertEqual(state.record, .faulted(step))
    }

    /// A fault with a sheet over a cover dismisses both at once, from the
    /// cover, and lets go once UIKit is done.
    func testAFaultWithASheetOverACoverDismissesBothOnce() {
        var state = sheetOverCover()
        let step = NuxieMachineEdgeFault(code: "engine.step", detail: "closed")
        XCTAssertEqual(state.handle(.report(.fault(step))), [.schedule(nil), .stop(step), .dismiss(cover.shown)])
        XCTAssertEqual(state.natives.map(\.phase), [.leaving, .leaving])
        XCTAssertEqual(state.handle(.dismissed(cover.shown)), [.release])
        XCTAssertEqual(state.natives, [])
    }

    // MARK: A machine dismissal during a swipe

    /// The machine dismisses while the person is swiping, and the person
    /// lets go: the swipe is cancelled and the sheet comes back, so the sync
    /// dismisses it then. The machine is not told `closed`.
    func testAMachineDismissalDuringACancelledSwipeIsPerformedAfterIt() {
        var state = sheetUp()
        XCTAssertEqual(state.handle(.swipeBegan(paywall.shown)), [])
        XCTAssertEqual(state.handle(shows([], [.dismiss(reason: "paywall_closed")])), [],
                       "nothing is dismissed while UIKit runs the swipe")
        XCTAssertEqual(state.natives, [State.Native(presented: paywall, phase: .swiping)])
        XCTAssertEqual(state.handle(.swipeEnded(paywall.shown, completed: false)), [.dismiss(paywall.shown)])
        XCTAssertEqual(state.handle(.dismissed(paywall.shown)), [])
        XCTAssertEqual(state.natives, [])
        XCTAssertEqual(state.record, .open(wakeAt: nil))
    }

    /// The machine dismisses while the person is swiping, and the swipe
    /// takes the sheet: it is gone once, and the machine, which already
    /// dismissed it, is not told `closed`.
    func testAMachineDismissalDuringACompletedSwipeClosesNothing() {
        var state = sheetUp()
        _ = state.handle(.swipeBegan(paywall.shown))
        _ = state.handle(shows([], [.dismiss(reason: "paywall_closed")]))
        XCTAssertEqual(state.handle(.swipeEnded(paywall.shown, completed: true)), [])
        XCTAssertEqual(state.natives, [])
        // UIKit's second word on the same swipe changes nothing.
        XCTAssertEqual(state.handle(.swipeEnded(paywall.shown, completed: true)), [])
        XCTAssertEqual(state.record, .open(wakeAt: nil))
    }

    /// The mirror: the person's swipe takes the sheet first, and the
    /// machine's dismissal arrives just after (from a delivery already under
    /// way). The machine hears `closed` for the presentation the swipe took,
    /// and the late report dismisses nothing.
    func testAMachineDismissalJustAfterASwipeDismissesNothing() {
        var state = sheetUp()
        _ = state.handle(.swipeBegan(paywall.shown))
        XCTAssertEqual(state.handle(.swipeEnded(paywall.shown, completed: true)), [.close(paywall.shown)])
        XCTAssertEqual(state.natives, [])
        XCTAssertEqual(state.handle(shows([], [.dismiss(reason: "paywall_closed")])), [])
        XCTAssertEqual(state.handle(shows([], [.end(.finished)])), [.schedule(nil), .stop(nil), .release])
        XCTAssertEqual(state.natives, [])
        XCTAssertEqual(state.record, .ended)
    }

    /// A swipe the person lets go of, with nothing else asking, leaves the
    /// sheet up, and a later machine dismissal still dismisses it.
    func testACancelledSwipeLeavesTheSheetUp() {
        var state = sheetUp()
        _ = state.handle(.swipeBegan(paywall.shown))
        XCTAssertEqual(state.handle(.swipeEnded(paywall.shown, completed: false)), [])
        XCTAssertEqual(state.natives, [State.Native(presented: paywall, phase: .up)])
        XCTAssertEqual(state.handle(shows([], [.dismiss(reason: nil)])), [.dismiss(paywall.shown)])
    }

    /// A swiped sheet the edge still shows, before the machine has answered
    /// the close, is not presented again; once the edge's report no longer
    /// shows it, what it shows comes up.
    func testASwipedSheetIsNotPresentedAgainBeforeTheCloseIsAnswered() {
        var state = sheetOverCover()
        _ = state.handle(.swipeBegan(sheet.shown))
        XCTAssertEqual(state.handle(.swipeEnded(sheet.shown, completed: true)), [.close(sheet.shown)])
        XCTAssertEqual(state.natives.map(\.shown), [cover.shown])
        // A report from a delivery that was under way still shows the sheet.
        XCTAssertEqual(state.handle(shows([cover, sheet])), [], "the swiped sheet came back")
        XCTAssertEqual(state.handle(shows([cover])), [])
        XCTAssertEqual(state.closing, [])
        XCTAssertEqual(state.natives.map(\.shown), [cover.shown])
    }

    /// A dismissal that arrives while the sheet is still going up waits for
    /// it to be up.
    func testADismissalWhileTheSheetArrivesWaitsForIt() {
        var state = State()
        _ = state.handle(.started)
        _ = state.handle(shows([paywall]))
        XCTAssertEqual(state.handle(shows([], [.dismiss(reason: nil)])), [])
        XCTAssertEqual(state.handle(.presented(paywall.shown)), [.dismiss(paywall.shown)])
        XCTAssertEqual(state.natives, [State.Native(presented: paywall, phase: .leaving)])
    }

    // MARK: A failed presentation stays a fault

    /// The host cannot present the sheet: the record is faulted and stays
    /// faulted, whatever comes after.
    func testAPresentationThatFailsStaysAFault() {
        var state = State()
        _ = state.handle(.started)
        XCTAssertEqual(state.handle(shows([paywall], [.wakeAt(evening)])),
                       [.schedule(evening), .present(paywall, over: nil)])
        let noHost = NuxieMachineEdgeFault(code: "edge.no-host", detail: "the host is off screen")
        XCTAssertEqual(state.handle(.presentFailed(paywall.shown, noHost)), [.schedule(nil), .stop(noHost), .release])
        XCTAssertEqual(state.record, .faulted(noHost))
        XCTAssertEqual(state.natives, [])

        // Nothing later moves it.
        XCTAssertEqual(state.handle(shows([paywall], [.wakeAt(evening)])), [])
        XCTAssertEqual(state.handle(.presented(paywall.shown)), [])
        XCTAssertEqual(state.handle(shows([], [.end(.finished)])), [])
        XCTAssertEqual(state.handle(.hostFault(noArtwork)), [])
        XCTAssertEqual(state.handle(.started), [])
        XCTAssertEqual(state.record, .faulted(noHost))
    }

    /// A cover is presented as a sheet is, over the whole screen, and the
    /// machine's dismissal takes it away again.
    func testACoverIsPresentedAndTheMachineDismissesIt() {
        var state = State()
        _ = state.handle(.started)
        XCTAssertEqual(state.handle(shows([offer])), [.present(offer, over: nil)])
        XCTAssertEqual(state.handle(.presented(offer.shown)), [])
        XCTAssertEqual(state.handle(shows([], [.dismiss(reason: "closed"), .end(.exited)])),
                       [.schedule(nil), .stop(nil), .dismiss(offer.shown)])
        XCTAssertEqual(state.handle(.dismissed(offer.shown)), [.release])
        XCTAssertEqual(state.record, .ended)
    }

    /// A presentation that is neither a sheet nor a cover is a fault, and
    /// what is up goes.
    func testAPresentationThatIsNotASheetOrACoverFaults() {
        var state = State()
        _ = state.handle(.started)
        let pushed = NuxieMachinePresented(shown: paywall.shown, route: "paywall", presentation: .push)
        let effects = state.handle(shows([pushed]))
        guard case .faulted(let fault) = state.record else { return XCTFail("\(state.record)") }
        XCTAssertEqual(fault.code, "edge.unsupported-presentation")
        XCTAssertEqual(effects, [.schedule(nil), .stop(fault), .release])

        var over = sheetUp()
        let pushedOver = NuxieMachinePresented(shown: offer.shown, route: "offer", presentation: .push)
        let overEffects = over.handle(shows([paywall, pushedOver]))
        guard case .faulted(let second) = over.record else { return XCTFail("\(over.record)") }
        XCTAssertEqual(second.code, "edge.unsupported-presentation")
        XCTAssertEqual(overEffects, [.schedule(nil), .stop(second), .dismiss(paywall.shown)])
    }

    // MARK: Several presentations

    /// A sheet over a cover is presented from the cover, and a pop of the
    /// sheet dismisses only the sheet.
    func testASheetOverACoverIsPresentedFromItAndPoppedAlone() {
        var state = sheetOverCover()
        XCTAssertEqual(state.handle(shows([cover])), [.dismiss(sheet.shown)])
        XCTAssertEqual(state.natives.map(\.phase), [.up, .leaving])
        XCTAssertEqual(state.handle(.dismissed(sheet.shown)), [])
        XCTAssertEqual(state.natives, [State.Native(presented: cover, phase: .up)])
    }

    /// Two presentations shown in one report come up one at a time, each
    /// over the one below, once UIKit has finished the one before.
    func testTwoPresentationsShownTogetherComeUpOneAtATime() {
        var state = State()
        _ = state.handle(.started)
        XCTAssertEqual(state.handle(shows([cover, sheet])), [.present(cover, over: nil)])
        XCTAssertEqual(state.handle(.presented(cover.shown)), [.present(sheet, over: cover.shown)])
        XCTAssertEqual(state.handle(.presented(sheet.shown)), [])
        XCTAssertEqual(state.natives.map(\.phase), [.up, .up])
    }

    /// A late completion names its own presentation, so it never moves a
    /// newer one: the paywall's dismissal heard twice, the second time after
    /// the offer that replaced it is arriving, leaves the offer arriving.
    func testALateCompletionNeverRemovesANewerPresentation() {
        var state = sheetUp()
        XCTAssertEqual(state.handle(shows([offer], [.dismiss(reason: "swapped")])), [.dismiss(paywall.shown)])
        XCTAssertEqual(state.handle(.dismissed(paywall.shown)), [.present(offer, over: nil)])
        XCTAssertEqual(state.handle(.dismissed(paywall.shown)), [], "the late completion moved something")
        XCTAssertEqual(state.handle(.swipeEnded(paywall.shown, completed: true)), [])
        XCTAssertEqual(state.natives, [State.Native(presented: offer, phase: .arriving)])
        XCTAssertEqual(state.handle(.presented(offer.shown)), [])
        XCTAssertEqual(state.natives, [State.Native(presented: offer, phase: .up)])
    }

    // MARK: One Screen replaced by another in one delivery

    /// The machine dismisses the paywall and presents the next Screen in
    /// one delivery. The sheet goes down once, and the next one comes up
    /// when it has gone, and the record does not fault.
    func testAReplacementComesUpOnceTheSheetItReplacesHasGone() {
        var state = sheetUp()
        XCTAssertEqual(state.handle(shows([offer], [.dismiss(reason: "swapped")])), [.dismiss(paywall.shown)])
        XCTAssertEqual(state.natives, [State.Native(presented: paywall, phase: .leaving)])
        XCTAssertEqual(state.record, .open(wakeAt: nil))
        XCTAssertEqual(state.handle(.dismissed(paywall.shown)), [.present(offer, over: nil)])
        XCTAssertEqual(state.natives, [State.Native(presented: offer, phase: .arriving)])
        XCTAssertEqual(state.handle(.presented(offer.shown)), [])
        XCTAssertEqual(state.natives, [State.Native(presented: offer, phase: .up)])
    }

    /// The same while the person is swiping the paywall: the replacement
    /// waits for the swipe to finish either way, and the machine, which
    /// ended the paywall itself, hears no close.
    func testAReplacementWaitsForTheSwipe() {
        var taken = sheetUp()
        _ = taken.handle(.swipeBegan(paywall.shown))
        XCTAssertEqual(taken.handle(shows([offer])), [])
        XCTAssertEqual(taken.handle(.swipeEnded(paywall.shown, completed: true)), [.present(offer, over: nil)])
        XCTAssertEqual(taken.natives, [State.Native(presented: offer, phase: .arriving)])

        var kept = sheetUp()
        _ = kept.handle(.swipeBegan(paywall.shown))
        _ = kept.handle(shows([offer]))
        XCTAssertEqual(kept.handle(.swipeEnded(paywall.shown, completed: false)), [.dismiss(paywall.shown)])
        XCTAssertEqual(kept.handle(.dismissed(paywall.shown)), [.present(offer, over: nil)])
    }

    /// A replacement the machine ends before the sheet it replaces has
    /// gone, or a fault meanwhile: it is never presented, and a fault lets
    /// go once the sheet has gone.
    func testAReplacementEndedBeforeItComesUpIsNeverPresented() {
        var popped = sheetUp()
        _ = popped.handle(shows([offer], [.dismiss(reason: "swapped")]))
        XCTAssertEqual(popped.handle(shows([])), [])
        XCTAssertEqual(popped.handle(.dismissed(paywall.shown)), [])
        XCTAssertEqual(popped.natives, [])
        XCTAssertEqual(popped.record, .open(wakeAt: nil))

        var faulted = sheetUp()
        _ = faulted.handle(shows([offer], [.dismiss(reason: "swapped")]))
        XCTAssertEqual(faulted.handle(.report(.fault(noArtwork))), [.schedule(nil), .stop(noArtwork)])
        XCTAssertEqual(faulted.handle(.dismissed(paywall.shown)), [.release])
        XCTAssertEqual(faulted.natives, [])
    }

    // MARK: Waking and ending

    /// The record's wake moment follows its last `wake at`; a wake is taken
    /// only at that moment; the end cancels the timer and stops.
    func testWakesAndTheEnd() {
        var state = waitingForEvening()
        XCTAssertNil(state.dueWake(at: evening - 1))
        XCTAssertEqual(state.handle(.wakeTaken(evening + 1)), [], "a wake at another moment is not the one asked for")
        XCTAssertEqual(state.record, .open(wakeAt: evening))
        XCTAssertEqual(state.handle(shows([], [.wakeAt(nil)])), [.schedule(nil)])
        XCTAssertNil(state.dueWake(at: .max))
        XCTAssertEqual(state.handle(shows([], [.end(.exited)])), [.schedule(nil), .stop(nil), .release])
        XCTAssertEqual(state.record, .ended)
        XCTAssertEqual(state.handle(.report(.fault(noArtwork))), [], "an ended record stays ended")
        XCTAssertEqual(state.record, .ended)
    }

    /// The record ends while the person swipes (a store answer that ends
    /// it), and the swipe is cancelled: the sheet still goes.
    func testAnEndDuringACancelledSwipeStillDismisses() {
        var state = sheetUp()
        _ = state.handle(.swipeBegan(paywall.shown))
        XCTAssertEqual(state.handle(shows([], [.end(.finished)])), [.schedule(nil), .stop(nil)])
        XCTAssertEqual(state.handle(.swipeEnded(paywall.shown, completed: false)), [.dismiss(paywall.shown)])
        XCTAssertEqual(state.natives, [State.Native(presented: paywall, phase: .leaving)])
        XCTAssertEqual(state.handle(.dismissed(paywall.shown)), [.release])
    }

    // MARK: Letting go

    /// Every event a presenter can still hear once it has let go. None of
    /// them says `release` again or moves the record.
    private func lateEvents() -> [State.Event] {
        [.dismissed(paywall.shown), .presented(paywall.shown), .swipeBegan(paywall.shown),
         .swipeEnded(paywall.shown, completed: true), .swipeEnded(paywall.shown, completed: false),
         shows([paywall], [.dismiss(reason: nil), .wakeAt(evening), .end(.finished)]),
         .report(.fault(noArtwork)), .hostFault(noArtwork), .wakeTaken(evening), .started,
         .presentFailed(paywall.shown, noArtwork)]
    }

    private func assertReleasedForGood(_ state: State, file: StaticString = #filePath, line: UInt = #line) {
        var state = state
        XCTAssertTrue(state.released, file: file, line: line)
        let record = state.record
        for event in lateEvents() {
            let effects = state.handle(event)
            XCTAssertFalse(effects.contains(.release), "\(event)", file: file, line: line)
            XCTAssertFalse(effects.contains { if case .present = $0 { true } else { false } }, "\(event)",
                           file: file, line: line)
        }
        XCTAssertEqual(state.record, record, file: file, line: line)
    }

    /// The record ends while the sheet is up: the edge stops at once, and
    /// the presenter lets go only once UIKit has finished the dismissal.
    func testAnEndReleasesOnceTheDismissalIsOver() {
        var state = sheetUp()
        XCTAssertEqual(state.handle(shows([], [.end(.finished)])), [.schedule(nil), .stop(nil), .dismiss(paywall.shown)])
        XCTAssertFalse(state.released, "the sheet is still leaving")
        XCTAssertEqual(state.handle(.dismissed(paywall.shown)), [.release])
        assertReleasedForGood(state)
    }

    /// The person's swipe takes the sheet, the machine hears `closed`, and
    /// its answer ends the record: the presenter lets go then, with the end.
    func testASwipeThatTookTheSheetThenTheEndReleasesWithTheEnd() {
        var state = sheetUp()
        _ = state.handle(.swipeBegan(paywall.shown))
        XCTAssertEqual(state.handle(.swipeEnded(paywall.shown, completed: true)), [.close(paywall.shown)])
        XCTAssertFalse(state.released, "the record is still open")
        XCTAssertEqual(state.handle(shows([], [.end(.finished)])), [.schedule(nil), .stop(nil), .release])
        assertReleasedForGood(state)
    }

    /// The record ends while the person swipes, and the swipe takes the
    /// sheet: the presenter lets go when the swipe is over.
    func testAnEndDuringASwipeThatTakesTheSheetReleasesAfterIt() {
        var state = sheetUp()
        _ = state.handle(.swipeBegan(paywall.shown))
        XCTAssertEqual(state.handle(shows([], [.end(.finished)])), [.schedule(nil), .stop(nil)])
        XCTAssertFalse(state.released, "UIKit is still running the swipe")
        XCTAssertEqual(state.handle(.swipeEnded(paywall.shown, completed: true)), [.release])
        assertReleasedForGood(state)
    }

    /// A fault while the sheet is still going up: it goes once it is up,
    /// and the presenter lets go after that.
    func testAFaultWhileTheSheetArrivesReleasesAfterItHasGone() {
        var state = State()
        _ = state.handle(.started)
        _ = state.handle(shows([paywall]))
        XCTAssertEqual(state.handle(.report(.fault(noArtwork))), [.schedule(nil), .stop(noArtwork)])
        XCTAssertFalse(state.released)
        XCTAssertEqual(state.handle(.presented(paywall.shown)), [.dismiss(paywall.shown)])
        XCTAssertFalse(state.released)
        XCTAssertEqual(state.handle(.dismissed(paywall.shown)), [.release])
        assertReleasedForGood(state)
    }

    /// A fault while the person swipes: the presenter lets go when the swipe
    /// takes the sheet, or, when the person lets go of it, after the
    /// dismissal the fault asked for.
    func testAFaultDuringASwipeReleasesWhenTheSheetHasGone() {
        let step = NuxieMachineEdgeFault(code: "engine.step", detail: "closed")
        var taken = sheetUp()
        _ = taken.handle(.swipeBegan(paywall.shown))
        XCTAssertEqual(taken.handle(.report(.fault(step))), [.schedule(nil), .stop(step)])
        XCTAssertEqual(taken.handle(.swipeEnded(paywall.shown, completed: true)), [.release])
        assertReleasedForGood(taken)

        var kept = sheetUp()
        _ = kept.handle(.swipeBegan(paywall.shown))
        _ = kept.handle(.report(.fault(step)))
        XCTAssertEqual(kept.handle(.swipeEnded(paywall.shown, completed: false)), [.dismiss(paywall.shown)])
        XCTAssertFalse(kept.released)
        XCTAssertEqual(kept.handle(.dismissed(paywall.shown)), [.release])
        assertReleasedForGood(kept)
    }

    /// A fault with nothing shown (the evening wake's route has no artwork),
    /// a presentation that failed, and an edge that never opened: the
    /// presenter lets go with the fault.
    func testAFaultWithNoSheetReleasesWithTheFault() {
        var waiting = waitingForEvening()
        XCTAssertEqual(waiting.handle(.report(.fault(noArtwork))), [.schedule(nil), .stop(noArtwork), .release])
        assertReleasedForGood(waiting)

        var failed = State()
        _ = failed.handle(.started)
        _ = failed.handle(shows([paywall]))
        let noHost = NuxieMachineEdgeFault(code: "edge.no-host", detail: "the host is off screen")
        XCTAssertEqual(failed.handle(.presentFailed(paywall.shown, noHost)), [.schedule(nil), .stop(noHost), .release])
        assertReleasedForGood(failed)

        var neverOpened = State()
        let open = NuxieMachineEdgeFault(code: "edge.open", detail: "the plan did not compile")
        XCTAssertEqual(neverOpened.handle(.hostFault(open)), [.schedule(nil), .stop(open), .release])
        assertReleasedForGood(neverOpened)
    }

    /// An open record keeps everything, with nothing shown as with
    /// something: after "Not now", across its wake, and while nothing is
    /// presented.
    func testAnOpenRecordWithNoSheetIsNotReleased() {
        var state = waitingForEvening()
        XCTAssertFalse(state.released)
        XCTAssertEqual(state.handle(.wakeTaken(evening)), [.schedule(nil)])
        XCTAssertEqual(state.handle(shows([], [.wakeAt(evening + 1)])), [.schedule(evening + 1)])
        XCTAssertEqual(state.handle(.dismissed(paywall.shown)), [])
        XCTAssertEqual(state.handle(.swipeEnded(paywall.shown, completed: true)), [])
        XCTAssertEqual(state.natives, [])
        XCTAssertEqual(state.record, .open(wakeAt: evening + 1))
        XCTAssertFalse(state.released)

        var started = State()
        XCTAssertEqual(started.handle(.started), [])
        XCTAssertFalse(started.released)
    }
}
#endif
