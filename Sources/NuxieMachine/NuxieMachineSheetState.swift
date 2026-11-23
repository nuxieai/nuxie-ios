#if os(iOS) && !targetEnvironment(macCatalyst)
import Foundation

/// Where a presenter is, as one small state machine with no UIKit in it:
/// events go in ([`handle`]), the state moves, and what the presenter must do
/// with UIKit, its timer and the edge comes out as effects.
///
/// Three facts make up where it is, because they change apart: the record
/// (not started, open with its wake moment, ended, or faulted), what the
/// edge last said is shown ([`wanted`]), and the native presentations UIKit
/// holds, each where UIKit has it ([`natives`]). A record can stay open with
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
/// - The machine hears `closed` only for a swipe that took a sheet the edge
///   still showed while the record was open. Until the edge's next report
///   no longer shows it, the sync opens nothing in its place.
/// - An ended or faulted record is final: nothing is shown, nothing moves it
///   again, and a fault is never overwritten.
/// - What the presenter owns (the Screens with their edge and session, the
///   wake timer, the display loop) is let go of once: at the moment the
///   record is final and no native is on screen or in a transition,
///   whichever of the two came last ([`Effect.release`]). An open record
///   keeps everything, with a presentation or without one.
package struct NuxieMachineSheetState: Equatable, Sendable {
    package enum Record: Equatable, Sendable {
        case notStarted
        /// Open, and asking for a wake at this moment (milliseconds since
        /// the Unix epoch) or at none.
        case open(wakeAt: Int64?)
        case ended
        case faulted(NuxieMachineEdgeFault)
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
        /// The record started.
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
        /// The presenter is about to deliver the wake at this moment.
        case wakeTaken(Int64)
        /// Something outside the edge failed: the edge would not open, or
        /// drawing failed.
        case hostFault(NuxieMachineEdgeFault)
    }

    package enum Effect: Equatable, Sendable {
        /// Present this presentation over the native `over` (none: over the
        /// host), as a sheet or a cover over the whole screen.
        case present(NuxieMachinePresented, over: NuxieMachineShown?)
        /// Dismiss this native presentation and every one above it.
        case dismiss(NuxieMachineShown)
        /// Tell the edge the person closed this presentation.
        case close(NuxieMachineShown)
        /// Set the wake timer for this moment, or cancel it.
        case schedule(Int64?)
        /// The record is final: stop the loop and close the edge; log the
        /// fault if one ended it.
        case stop(NuxieMachineEdgeFault?)
        /// Let go of everything the presenter owns. Comes once, after the
        /// record's `stop`, when no native is left for UIKit to finish.
        case release
    }

    package private(set) var record: Record = .notStarted
    /// What is shown, bottom first, as the edge last reported it. Nothing
    /// once the record is final.
    package private(set) var wanted: [NuxieMachinePresented] = []
    /// The native presentations UIKit holds, bottom first.
    package private(set) var natives: [Native] = []
    /// Presentations the person swiped away whose close the edge has not
    /// answered yet: still in [`wanted`], and not to be opened again.
    package private(set) var closing: [NuxieMachineShown] = []
    /// Whether [`Effect.release`] has been said.
    package private(set) var released = false

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
            // person's close, for the presentation it took.
            guard case .open = record, wanted.contains(where: { $0.shown == shown }) else { return [] }
            closing.append(shown)
            return [.close(shown)]
        case .wakeTaken(let moment):
            guard record == .open(wakeAt: moment) else { return [] }
            record = .open(wakeAt: nil)
            return [.schedule(nil)]
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
        }
    }

    /// The one path for faults. The first end of a record stands: a fault
    /// after it changes nothing. A fault shows nothing.
    private mutating func fail(_ fault: NuxieMachineEdgeFault) -> [Effect] {
        switch record {
        case .ended, .faulted:
            return []
        case .notStarted, .open:
            record = .faulted(fault)
            wanted = []
            return [.schedule(nil), .stop(fault)]
        }
    }
}

extension NuxieMachineSheetState.Record {
    /// Ended or faulted: nothing moves it again.
    var isFinal: Bool {
        switch self {
        case .ended, .faulted: true
        case .notStarted, .open: false
        }
    }
}
#endif
