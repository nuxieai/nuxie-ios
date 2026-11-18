#if os(iOS) && !targetEnvironment(macCatalyst)
import Foundation

/// Where a sheet presenter is, as one small state machine with no UIKit in
/// it: events go in ([`handle`]), the state moves, and what the presenter
/// must do with UIKit, its timer and the edge comes out as effects.
///
/// Two facts make up where it is, because they change apart: the record
/// (not started, open with its wake moment, ended, or faulted), and the
/// sheet's life in UIKit (none, going up, up, going because something asked
/// it to, or being swiped by the person). A record can stay open with no
/// sheet (after "Not now"), and a fault can arrive while a swipe is under
/// way, so neither can stand in for the other.
///
/// - The edge's reports are the only way the presenter learns what the
///   machine did, a fault included.
/// - A UIKit transition is followed to its end. A sheet asked to go while it
///   is going up, or while the person swipes it, goes once that transition
///   is over: at once if the swipe was cancelled, not at all if the swipe
///   took it.
/// - The machine hears `closed` only for a swipe that took the sheet while
///   the record was open and nothing had asked the sheet to go.
/// - An ended or faulted record is final. Nothing moves it again, and a
///   fault is never overwritten.
package struct NuxieMachineSheetState: Equatable, Sendable {
    package enum Record: Equatable, Sendable {
        case notStarted
        /// Open, and asking for a wake at this moment (milliseconds since
        /// the Unix epoch) or at none.
        case open(wakeAt: Int64?)
        case ended
        case faulted(NuxieMachineEdgeFault)
    }

    package enum Sheet: Equatable, Sendable {
        /// No sheet is on screen.
        case none
        /// UIKit is presenting the sheet for this showing. `leaving` once
        /// something asked it to go before it was up.
        case arriving(NuxieMachineShown, leaving: Bool)
        /// The sheet is up, at rest.
        case up(NuxieMachineShown)
        /// UIKit is dismissing the sheet because the machine, the record's
        /// end or a fault asked it to.
        case leaving(NuxieMachineShown)
        /// The person is swiping the sheet down. `leaving` once something
        /// asked it to go meanwhile.
        case swiping(NuxieMachineShown, leaving: Bool)
    }

    package enum Event: Equatable, Sendable {
        /// The record started.
        case started
        /// The edge's report for one delivery.
        case report(NuxieMachineEdgeReport)
        /// UIKit finished presenting the sheet.
        case presented
        /// The sheet could not be presented.
        case presentFailed(NuxieMachineEdgeFault)
        /// UIKit finished a dismissal the presenter asked for.
        case dismissed
        /// The person began swiping the sheet down.
        case swipeBegan
        /// The person's swipe ended: it took the sheet, or it was cancelled
        /// and the sheet is back up.
        case swipeEnded(completed: Bool)
        /// The presenter is about to deliver the wake at this moment.
        case wakeTaken(Int64)
        /// Something outside the edge failed: the edge would not open, or
        /// drawing failed.
        case hostFault(NuxieMachineEdgeFault)
    }

    package enum Effect: Equatable, Sendable {
        /// Present the sheet for this showing.
        case present(NuxieMachineShown)
        /// Dismiss the sheet.
        case dismiss
        /// Tell the edge the person closed this showing.
        case close(NuxieMachineShown)
        /// Set the wake timer for this moment, or cancel it.
        case schedule(Int64?)
        /// Stop the loop and release the session; log the fault if one
        /// ended it.
        case stop(NuxieMachineEdgeFault?)
    }

    package private(set) var record: Record = .notStarted
    package private(set) var sheet: Sheet = .none

    package init() {}

    /// The wake the record asks for, if its moment is at or before `now`.
    package func dueWake(at now: Int64) -> Int64? {
        if case .open(let moment?) = record, moment <= now { return moment }
        return nil
    }

    /// Move the state for `event`, and say what to do about it.
    package mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .started:
            guard record == .notStarted else { return [] }
            record = .open(wakeAt: nil)
            return []
        case .report(.fault(let fault)), .hostFault(let fault):
            return fail(fault)
        case .report(.rows(let rows)):
            var effects: [Effect] = []
            for row in rows {
                guard case .open = record else { break }
                effects += perform(row)
            }
            return effects
        case .presentFailed(let fault):
            if case .arriving = sheet { sheet = .none }
            return fail(fault)
        case .presented:
            guard case .arriving(let shown, let leaving) = sheet else { return [] }
            sheet = leaving ? .leaving(shown) : .up(shown)
            return leaving ? [.dismiss] : []
        case .dismissed:
            guard case .leaving = sheet else { return [] }
            sheet = .none
            return []
        case .swipeBegan:
            guard case .up(let shown) = sheet else { return [] }
            sheet = .swiping(shown, leaving: false)
            return []
        case .swipeEnded(let completed):
            guard case .swiping(let shown, let leaving) = sheet else { return [] }
            if !completed {
                sheet = leaving ? .leaving(shown) : .up(shown)
                return leaving ? [.dismiss] : []
            }
            sheet = .none
            // A swipe that took a sheet nothing else had asked to go is the
            // person's close, for the showing it took.
            guard !leaving, case .open = record else { return [] }
            return [.close(shown)]
        case .wakeTaken(let moment):
            guard record == .open(wakeAt: moment) else { return [] }
            record = .open(wakeAt: nil)
            return [.schedule(nil)]
        }
    }

    // MARK: Rows

    private mutating func perform(_ row: NuxieMachineHostRow) -> [Effect] {
        switch row {
        case .present(let shown, let presentation):
            guard presentation == .sheet else {
                return fail(NuxieMachineEdgeFault(code: "edge.unsupported-presentation",
                    detail: "present showing \(shown.showing) as \(presentation); only a sheet is built"))
            }
            guard sheet == .none else {
                return fail(NuxieMachineEdgeFault(code: "edge.no-host",
                    detail: "present showing \(shown.showing) while the last sheet is still on screen"))
            }
            sheet = .arriving(shown, leaving: false)
            return [.present(shown)]
        case .pop(let shown):
            return leave(only: shown)
        case .dismiss:
            return leave(only: nil)
        case .wakeAt(let moment):
            record = .open(wakeAt: moment)
            return [.schedule(moment)]
        case .end:
            record = .ended
            return [.schedule(nil), .stop(nil)] + leave(only: nil)
        }
    }

    /// Ask the sheet to go: the one for `only`, or whichever is on screen.
    /// A sheet in a transition goes when the transition is over.
    private mutating func leave(only: NuxieMachineShown?) -> [Effect] {
        switch sheet {
        case .none, .leaving:
            return []
        case .arriving(let shown, _):
            guard only == nil || only == shown else { return [] }
            sheet = .arriving(shown, leaving: true)
            return []
        case .up(let shown):
            guard only == nil || only == shown else { return [] }
            sheet = .leaving(shown)
            return [.dismiss]
        case .swiping(let shown, _):
            guard only == nil || only == shown else { return [] }
            sheet = .swiping(shown, leaving: true)
            return []
        }
    }

    /// The one path for faults. The first end of a record stands: a fault
    /// after it changes nothing.
    private mutating func fail(_ fault: NuxieMachineEdgeFault) -> [Effect] {
        switch record {
        case .ended, .faulted:
            return []
        case .notStarted, .open:
            record = .faulted(fault)
            return [.schedule(nil), .stop(fault)] + leave(only: nil)
        }
    }
}
#endif
