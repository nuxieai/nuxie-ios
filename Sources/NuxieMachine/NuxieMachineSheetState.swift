#if os(iOS) && !targetEnvironment(macCatalyst)
import Foundation

/// Where a presenter is, as one small state machine with no UIKit in it:
/// events go in ([`handle`]), the state moves, and what the presenter must do
/// with UIKit, its timer and the edge comes out as effects.
///
/// Three facts make up where it is, because they change apart: the record
/// (not started, open with its wake moment, ended, faulted, or declined
/// when its start did not happen), what the edge last said is shown
/// ([`wanted`]), and the native presentations UIKit holds, each where UIKit
/// has it ([`natives`]). A record can stay open with
/// nothing shown (after "Not now"), and a fault can arrive while a swipe is
/// under way, so none can stand in for another.
///
/// - The edge's reports are the only way the presenter learns what the
///   machine did, a fault included. Each says what is shown, bottom first.
/// - One sync ([`sync`]) makes the natives follow what is shown, by
///   identity: it dismisses the first native that is no longer shown, with
///   every native above it, and presents what is missing, one at a time,
///   each over the native below it. Each is its own native presentation,
///   presented from the one below. Only a sheet and a cover are presented;
///   any other presentation is a fault.
/// - A UIKit transition is followed to its end. While one is under way
///   (presenting, dismissing, or the person swiping), the sync waits, and it
///   runs again when the transition ends. Every UIKit event names the
///   presentation it is for, so a completion that arrives late moves only
///   its own native and never a newer one.
/// - The machine hears a swipe (`swipe`) only on a sheet the edge still
///   shows while the record is open: once for a swipe UIKit held (the
///   machine said it presses a control or does nothing, or the screen
///   reader's escape asked), and once for one that took the sheet
///   natively. A sheet a swipe took is not opened again until the edge has
///   answered the swipe ([`closing`]); then the sync shows what the machine
///   says, which presents it again when the machine kept it.
/// - Where the files the pages draw stand is the edge's to say, in its
///   reports ([`assets`]); every native presentation shows it. While a page
///   waits, Try Again asks for the failed files again, and the close is the
///   host's own fault, which the edge reports back as the record's fault.
/// - An ended, faulted or declined record is final: nothing is shown,
///   nothing moves it again, and a fault is never overwritten.
/// - A start the machine says did not happen is no fault: the record is
///   declined, nothing was asked of UIKit, and the presenter lets go.
/// - What the presenter owns (the Screens with their edge and session, the
///   wake timer, the display loop) is let go of once: at the moment the
///   record is final and no native is on screen or in a transition,
///   whichever of the two came last ([`Effect.release`]). An open record
///   keeps everything, with a presentation or without one.
package struct NuxieMachineSheetState: Equatable, Sendable {
    package enum Record: Equatable, Sendable {
        /// Nothing has been asked yet.
        case notStarted
        /// Open, and asking for a wake at this moment (milliseconds since
        /// the Unix epoch) or at none.
        case open(wakeAt: Int64?)
        case ended
        case faulted(NuxieMachineEdgeFault)
        /// The start was asked for, and the machine said it did not
        /// happen, with nothing wrong: there is no record, and there will
        /// be none.
        case declined
    }

    /// Where UIKit has one native presentation.
    package enum Phase: Equatable, Sendable {
        /// UIKit is presenting it.
        case arriving
        /// It is up, at rest.
        case up
        /// UIKit is dismissing it, because the sync asked.
        case leaving
        /// The person is swiping it down.
        case swiping
    }

    /// One native presentation the presenter holds.
    package struct Native: Equatable, Sendable {
        package let presented: NuxieMachinePresented
        package var phase: Phase

        package init(presented: NuxieMachinePresented, phase: Phase) {
            self.presented = presented
            self.phase = phase
        }

        package var shown: NuxieMachineShown { presented.shown }
    }

    package enum Event: Equatable, Sendable {
        /// The record started. The presenter sends it once the edge has
        /// answered the start, unless the answer is `notStarted`.
        case started
        /// The edge's report for one delivery.
        case report(NuxieMachineEdgeReport)
        /// UIKit finished presenting this presentation.
        case presented(NuxieMachineShown)
        /// This presentation could not be presented.
        case presentFailed(NuxieMachineShown, NuxieMachineEdgeFault)
        /// UIKit finished dismissing this presentation, and every one above
        /// it, as the sync asked.
        case dismissed(NuxieMachineShown)
        /// The person began swiping this presentation down.
        case swipeBegan(NuxieMachineShown)
        /// The person's swipe of this presentation ended: it took it, or it
        /// was cancelled and it is back up.
        case swipeEnded(NuxieMachineShown, completed: Bool)
        /// UIKit held the person's swipe down on this presentation, because
        /// the machine said it presses a control or does nothing; or the
        /// screen reader's escape asked to close it. The sheet stays up.
        case swipeRefused(NuxieMachineShown)
        /// The edge answered the swipe on this presentation, its report
        /// already handed in. What is shown now says whether it stays.
        case swipeDelivered(NuxieMachineShown)
        /// The presenter is about to deliver the wake at this moment.
        case wakeTaken(Int64)
        /// Something outside the edge failed: the edge would not open, or
        /// drawing failed.
        case hostFault(NuxieMachineEdgeFault)
        /// The person tapped Try Again on the recovery screen.
        case refreshTapped
        /// The person tapped the close on the loading or recovery screen.
        case exitTapped
    }

    package enum Effect: Equatable, Sendable {
        /// Present this presentation over the native `over` (none: over the
        /// host), as a sheet or a cover over the whole screen.
        case present(NuxieMachinePresented, over: NuxieMachineShown?)
        /// Dismiss this native presentation and every one above it.
        case dismiss(NuxieMachineShown)
        /// Deliver a swipe down on this presentation to the edge.
        case swipe(NuxieMachineShown)
        /// Set the wake timer for this moment, or cancel it.
        case schedule(Int64?)
        /// The record is final: stop the loop and close the edge; log the
        /// fault if one ended it.
        case stop(NuxieMachineEdgeFault?)
        /// Let go of everything the presenter owns. Comes once, after the
        /// record's `stop`, when no native is left for UIKit to finish.
        case release
        /// Show every native presentation where the files stand.
        case assets(NuxieMachineAssets)
        /// Ask the edge for the files that failed again.
        case refresh
        /// Tell the edge the host's own fault: the person gave up on a page
        /// whose files never came.
        case hostFault(NuxieMachineHostFault)
    }

    package private(set) var record: Record = .notStarted
    /// What is shown, bottom first, as the edge last reported it. Nothing
    /// once the record is final.
    package private(set) var wanted: [NuxieMachinePresented] = []
    /// The native presentations UIKit holds, bottom first.
    package private(set) var natives: [Native] = []
    /// Presentations the person swiped away natively whose swipe the edge
    /// has not answered yet: not to be opened again until it has.
    package private(set) var closing: [NuxieMachineShown] = []
    /// Whether [`Effect.release`] has been said.
    package private(set) var released = false
    /// Where the files the shown pages draw stand, as the edge last
    /// reported it.
    package private(set) var assets: NuxieMachineAssets = .ready

    /// The native presentation a screen reader reaches: the top one that is
    /// not leaving. Every one under it is covered, from the moment the one
    /// over it starts to arrive until it starts to leave.
    package var reachable: NuxieMachineShown? {
        natives.last { $0.phase != .leaving }?.shown
    }

    package init() {}

    /// The wake the record asks for, if its moment is at or before `now`.
    package func dueWake(at now: Int64) -> Int64? {
        if case .open(let moment?) = record, moment <= now { return moment }
        return nil
    }

    /// Move the state for `event`, and say what to do about it. The one
    /// place [`Effect.release`] is said: after any event that leaves the
    /// record final and no native, the first time both hold.
    package mutating func handle(_ event: Event) -> [Effect] {
        var effects = move(event)
        effects += sync()
        if !released, natives.isEmpty, record.isFinal {
            released = true
            effects.append(.release)
        }
        return effects
    }

    private mutating func move(_ event: Event) -> [Effect] {
        switch event {
        case .started:
            guard record == .notStarted else { return [] }
            record = .open(wakeAt: nil)
            return []
        case .report(.fault(let fault)), .hostFault(let fault):
            return fail(fault)
        case .report(.notStarted):
            // The start did not happen: before anything is open, or with
            // the record the start would have made showing nothing and
            // asking for nothing, there is no record. A start that did not
            // happen changes nothing for a record that is open and shows
            // or waits for something, or is final.
            switch record {
            case .notStarted:
                record = .declined
            case .open(wakeAt: nil) where wanted.isEmpty && natives.isEmpty:
                record = .declined
            case .open, .ended, .faulted, .declined:
                break
            }
            return []
        case .report(.delivered(let shown, let rows)):
            guard case .open = record else { return [] }
            wanted = shown
            closing.removeAll { gone in !shown.contains { $0.shown == gone } }
            var effects: [Effect] = []
            for row in rows {
                guard case .open = record else { break }
                effects += perform(row)
            }
            return effects
        case .presentFailed(let shown, let fault):
            natives.removeAll { $0.shown == shown && $0.phase == .arriving }
            return fail(fault)
        case .presented(let shown):
            guard let index = index(of: shown), natives[index].phase == .arriving else { return [] }
            natives[index].phase = .up
            return []
        case .dismissed(let shown):
            guard let index = index(of: shown), natives[index].phase == .leaving else { return [] }
            natives.removeSubrange(index...)
            return []
        case .swipeBegan(let shown):
            guard let index = index(of: shown), natives[index].phase == .up else { return [] }
            natives[index].phase = .swiping
            return []
        case .swipeEnded(let shown, let completed):
            guard let index = index(of: shown), natives[index].phase == .swiping else { return [] }
            guard completed else {
                natives[index].phase = .up
                return []
            }
            natives.removeSubrange(index...)
            // A swipe that took a presentation the edge still shows is the
            // person's swipe, for the presentation it took.
            guard case .open = record, wanted.contains(where: { $0.shown == shown }) else { return [] }
            closing.append(shown)
            return [.swipe(shown)]
        case .swipeRefused(let shown):
            // Held by UIKit, the sheet is still up: the machine decides.
            guard let index = index(of: shown), natives[index].phase == .up, case .open = record,
                  wanted.contains(where: { $0.shown == shown }) else { return [] }
            return [.swipe(shown)]
        case .swipeDelivered(let shown):
            closing.removeAll { $0 == shown }
            return []
        case .wakeTaken(let moment):
            guard record == .open(wakeAt: moment) else { return [] }
            record = .open(wakeAt: nil)
            return [.schedule(nil)]
        case .refreshTapped:
            // Only a failed file is asked for again; one still coming is
            // already asked for.
            guard case .open = record, case .failed = assets else { return [] }
            return [.refresh]
        case .exitTapped:
            // The close shows only while a page waits for its files. Its
            // answer is a fault the edge reports, which takes the one fault
            // path below like any other.
            guard case .open = record, assets != .ready else { return [] }
            return [.hostFault(.firstFrameDeadline)]
        }
    }

    private func index(of shown: NuxieMachineShown) -> Int? {
        natives.firstIndex { $0.shown == shown }
    }

    // MARK: The sync

    /// Make the natives follow what is shown. Waits while any native is in a
    /// transition: the event that ends it runs the sync again. Otherwise it
    /// keeps what both have from the bottom up, by identity; dismisses the
    /// first native past that, with every one above it; or else presents
    /// the first presentation missing, over the native below it. One step
    /// at a time, each finished by UIKit before the next.
    private mutating func sync() -> [Effect] {
        guard natives.allSatisfy({ $0.phase == .up }) else { return [] }
        var keep = 0
        while keep < natives.count, keep < wanted.count, natives[keep].shown == wanted[keep].shown {
            keep += 1
        }
        if keep < natives.count {
            for index in keep..<natives.count { natives[index].phase = .leaving }
            return [.dismiss(natives[keep].shown)]
        }
        guard keep < wanted.count, case .open = record else { return [] }
        let next = wanted[keep]
        // A swiped presentation stays in what is shown until the edge
        // answers its close; nothing opens in its place meanwhile.
        guard !closing.contains(next.shown) else { return [] }
        guard next.presentation == .sheet || next.presentation == .cover else {
            return fail(NuxieMachineEdgeFault(code: "edge.unsupported-presentation",
                detail: "present \(next.route) as \(next.presentation); only a sheet and a cover are presented"))
                + sync()
        }
        natives.append(Native(presented: next, phase: .arriving))
        return [.present(next, over: keep > 0 ? natives[keep - 1].shown : nil)]
    }

    // MARK: Rows

    private mutating func perform(_ row: NuxieMachineHostRow) -> [Effect] {
        switch row {
        case .dismiss:
            // What is shown already says what the dismissal closed.
            return []
        case .wakeAt(let moment):
            record = .open(wakeAt: moment)
            return [.schedule(moment)]
        case .end:
            record = .ended
            wanted = []
            return [.schedule(nil), .stop(nil)]
        case .assets(let now):
            assets = now
            return [.assets(now)]
        }
    }

    /// The one path for faults. The first end of a record stands: a fault
    /// after it changes nothing. A fault shows nothing.
    private mutating func fail(_ fault: NuxieMachineEdgeFault) -> [Effect] {
        switch record {
        case .ended, .faulted, .declined:
            return []
        case .notStarted, .open:
            record = .faulted(fault)
            wanted = []
            return [.schedule(nil), .stop(fault)]
        }
    }
}

extension NuxieMachineSheetState.Record {
    /// Ended, faulted or declined: nothing moves it again.
    var isFinal: Bool {
        switch self {
        case .ended, .faulted, .declined: true
        case .notStarted, .open: false
        }
    }
}
#endif
