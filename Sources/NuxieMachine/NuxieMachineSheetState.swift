#if os(iOS) && !targetEnvironment(macCatalyst)
import Foundation

/// Where a presenter is, as one small state machine with no UIKit in it:
/// events go in ([`handle`]), the state moves, and what the presenter must do
/// with UIKit, its timer and the edge comes out as effects.
///
/// Three facts make up where it is, because they change apart: the record
/// (not started, open with its wake moment, ended, faulted, or declined
/// when its start did not happen), what the edge last said is shown
/// ([`wanted`]), and the native presentations UIKit holds, each with its
/// pages, each where UIKit has it ([`segments`]). A record can stay open
/// with nothing shown (after "Not now"), and a fault can arrive while a
/// swipe is under way, so none can stand in for another.
///
/// - The edge's reports are the only way the presenter learns what the
///   machine did, a fault included. Each says what is shown, bottom first.
/// - What is shown is cut into segments ([`cut(_:)`]). A segment is one
///   native presentation holding a run of pages: a sheet or a cover starts
///   one, and so does the first entry when it says `push` (or nothing),
///   which arrives as a cover over the whole screen. Every later push is a
///   page inside the segment below it. A row that says `fade`, `none` or
///   `move` is not presented: it is a fault.
/// - One sync ([`sync`]) makes the segments follow what is shown, by
///   identity, one step at a time: it dismisses the first segment that is
///   no longer shown, with every one above it; else it changes the pages
///   of the first kept segment whose pages differ, in one change UIKit
///   animates as a push when the new top page is new and as a pop when it
///   is a kept one (a push, the machine's back, a replace, a pop to a page,
///   and on the first segment a clear); else it presents the first segment
///   missing, over the one below it.
/// - A UIKit transition is followed to its end. While one is under way
///   (presenting, dismissing, changing pages, or the person swiping), the
///   sync waits, and it runs again when the transition ends. Every UIKit
///   event names the segment or the page it is for, so a completion that
///   arrives late moves only its own segment and never a newer one.
/// - The machine hears a swipe (`swipe`) only on a presentation the edge
///   still shows while the record is open: once for a swipe UIKit held (the
///   machine said it presses a control or does nothing, or the screen
///   reader's escape asked), and once for one that took the sheet or the
///   page natively. A swipe down is the sheet's, at its own entry; a swipe
///   back from the edge is the pushed page's. A presentation a swipe took
///   is not shown again until the edge has answered the swipe
///   ([`closing`]); then the sync shows what the machine says, which
///   presents the sheet or pushes the page again when the machine kept it.
/// - Where the files the pages draw stand is the edge's to say, in its
///   reports ([`assets`]); every page shows it. While a page waits, Try
///   Again asks for the failed files again, and the close is the host's own
///   fault, which the edge reports back as the record's fault.
/// - An ended, faulted or declined record is final: nothing is shown,
///   nothing moves it again, and a fault is never overwritten.
/// - A start the machine says did not happen is no fault: the record is
///   declined, nothing was asked of UIKit, the edge is stopped and closed
///   as for an end (so the files it asked for are no longer fetched), and
///   the presenter lets go.
/// - What the presenter owns (the Screens with their edge and session, the
///   wake timer, the display loop) is let go of once: at the moment the
///   record is final and no segment is on screen or in a transition,
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

    /// Where UIKit has one segment.
    package enum Phase: Equatable, Sendable {
        /// UIKit is presenting it.
        case arriving
        /// It is up, at rest.
        case up
        /// UIKit is dismissing it, because the sync asked.
        case leaving
        /// The person is swiping it down.
        case swiping
        /// UIKit is changing its pages, because the sync asked.
        case changing
        /// The person is swiping its top page back from the edge.
        case popping
    }

    /// One segment the presenter holds: one native presentation, and the
    /// pages it holds, bottom first, as the sync last set them.
    package struct Segment: Equatable, Sendable {
        /// Its identity: the identity of its first page when it was
        /// presented. Every UIKit event for the segment names it. Only the
        /// first segment's first page can change while it is up (a replace,
        /// or a clear and a push); a sheet's and a cover's never does.
        package let id: NuxieMachineShown
        package var pages: [NuxieMachinePresented]
        package var phase: Phase

        package init(pages: [NuxieMachinePresented], phase: Phase) {
            self.init(id: pages[0].shown, pages: pages, phase: phase)
        }

        package init(id: NuxieMachineShown, pages: [NuxieMachinePresented], phase: Phase) {
            precondition(!pages.isEmpty, "a segment holds a page")
            self.id = id
            self.pages = pages
            self.phase = phase
        }

        /// The entry that starts the segment: the sheet or the cover, or
        /// the first page shown as a push.
        package var bottom: NuxieMachinePresented { pages[0] }
        /// The page on top, the one showing.
        package var top: NuxieMachineShown { pages[pages.count - 1].shown }
    }

    package enum Event: Equatable, Sendable {
        /// The record started. The presenter sends it once the edge has
        /// answered the start, unless the answer is `notStarted`.
        case started
        /// The edge's report for one delivery.
        case report(NuxieMachineEdgeReport)
        /// UIKit finished presenting this segment.
        case presented(NuxieMachineShown)
        /// This segment could not be presented.
        case presentFailed(NuxieMachineShown, NuxieMachineEdgeFault)
        /// UIKit finished dismissing this segment, and every one above it,
        /// as the sync asked.
        case dismissed(NuxieMachineShown)
        /// UIKit finished changing the pages of this segment, as the sync
        /// asked.
        case pagesChanged(NuxieMachineShown)
        /// The person began swiping this segment, a sheet, down.
        case swipeBegan(NuxieMachineShown)
        /// The person's swipe of this segment ended: it took the sheet, or
        /// it was cancelled and the sheet is back up.
        case swipeEnded(NuxieMachineShown, completed: Bool)
        /// UIKit held the person's swipe down on this segment, a sheet,
        /// because the machine said it presses a control or does nothing;
        /// or the screen reader's escape asked to close it. The sheet stays
        /// up.
        case swipeRefused(NuxieMachineShown)
        /// The person began swiping this page, on top of its segment, back
        /// from the edge.
        case edgeSwipeBegan(NuxieMachineShown)
        /// The person's swipe back of this page ended: UIKit popped it, or
        /// the swipe was let go and the page is back.
        case edgeSwipeEnded(NuxieMachineShown, completed: Bool)
        /// UIKit held the person's swipe back on this page, because the
        /// machine said it presses a control or does nothing; or the screen
        /// reader's escape asked to go back from it. The page stays.
        case edgeSwipeRefused(NuxieMachineShown)
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
        /// Present a segment holding these pages, bottom first, over the
        /// segment `over` (none: over the host): as a sheet when its first
        /// page is a sheet, else as a cover over the whole screen.
        case present([NuxieMachinePresented], over: NuxieMachineShown?)
        /// Dismiss this segment and every one above it.
        case dismiss(NuxieMachineShown)
        /// Set the pages of this segment to these, bottom first, in one
        /// change: a push when the new top page is new, a pop when it is
        /// a kept one.
        case setPages(NuxieMachineShown, [NuxieMachinePresented])
        /// Deliver this swipe on this presentation to the edge: down on a
        /// sheet's own entry, back on a pushed page.
        case swipe(NuxieMachineShown, NuxieMachineSwipeGesture)
        /// Set the wake timer for this moment, or cancel it.
        case schedule(Int64?)
        /// The record is final: stop the loop and close the edge; log the
        /// fault if one ended it.
        case stop(NuxieMachineEdgeFault?)
        /// Let go of everything the presenter owns. Comes once, after the
        /// record's `stop`, when no segment is left for UIKit to finish.
        case release
        /// Show every page where the files stand.
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
    /// The segments UIKit holds, bottom first.
    package private(set) var segments: [Segment] = []
    /// Presentations the person swiped away natively (a sheet down, or a
    /// page back from the edge) whose swipe the edge has not answered yet:
    /// not to be shown again until it has.
    package private(set) var closing: [NuxieMachineShown] = []
    /// Whether [`Effect.release`] has been said.
    package private(set) var released = false
    /// Where the files the shown pages draw stand, as the edge last
    /// reported it.
    package private(set) var assets: NuxieMachineAssets = .ready

    /// The page a screen reader reaches: the top page of the top segment
    /// that is not leaving. Every page under it is covered, from the moment
    /// the segment over it starts to arrive until it starts to leave, and a
    /// page under another in its own segment is off screen.
    package var reachable: NuxieMachineShown? {
        segments.last { $0.phase != .leaving }?.top
    }

    package init() {}

    /// The wake the record asks for, if its moment is at or before `now`.
    package func dueWake(at now: Int64) -> Int64? {
        if case .open(let moment?) = record, moment <= now { return moment }
        return nil
    }

    /// What is shown, cut into segments, bottom first: a segment starts at
    /// the first entry and at every entry that is not a push; each push
    /// after the first entry is a page of the segment below it.
    package static func cut(_ shown: [NuxieMachinePresented]) -> [[NuxieMachinePresented]] {
        var cut: [[NuxieMachinePresented]] = []
        for presented in shown {
            if cut.isEmpty || presented.presentation != .push {
                cut.append([presented])
            } else {
                cut[cut.count - 1].append(presented)
            }
        }
        return cut
    }

    /// Move the state for `event`, and say what to do about it. The one
    /// place [`Effect.release`] is said: after any event that leaves the
    /// record final and no segment, the first time both hold.
    package mutating func handle(_ event: Event) -> [Effect] {
        var effects = move(event)
        effects += sync()
        if !released, segments.isEmpty, record.isFinal {
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
                return [.stop(nil)]
            case .open(wakeAt: nil) where wanted.isEmpty && segments.isEmpty:
                record = .declined
                return [.stop(nil)]
            case .open, .ended, .faulted, .declined:
                return []
            }
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
        case .presentFailed(let id, let fault):
            segments.removeAll { $0.id == id && $0.phase == .arriving }
            return fail(fault)
        case .presented(let id):
            guard let index = index(of: id), segments[index].phase == .arriving else { return [] }
            segments[index].phase = .up
            return []
        case .dismissed(let id):
            guard let index = index(of: id), segments[index].phase == .leaving else { return [] }
            segments.removeSubrange(index...)
            return []
        case .pagesChanged(let id):
            guard let index = index(of: id), segments[index].phase == .changing else { return [] }
            segments[index].phase = .up
            return []
        case .swipeBegan(let id):
            guard let index = index(of: id), segments[index].phase == .up else { return [] }
            segments[index].phase = .swiping
            return []
        case .swipeEnded(let id, let completed):
            guard let index = index(of: id), segments[index].phase == .swiping else { return [] }
            guard completed else {
                segments[index].phase = .up
                return []
            }
            let sheet = segments[index].bottom.shown
            segments.removeSubrange(index...)
            // A swipe that took a sheet the edge still shows is the
            // person's swipe, for the sheet's own entry.
            return took(sheet, .down)
        case .swipeRefused(let id):
            // Held by UIKit, the sheet is still up: the machine decides.
            guard let index = index(of: id), segments[index].phase == .up else { return [] }
            return held(segments[index].bottom.shown, .down)
        case .edgeSwipeBegan(let page):
            guard let index = segments.firstIndex(where: { $0.top == page && $0.pages.count > 1 }),
                  segments[index].phase == .up else { return [] }
            segments[index].phase = .popping
            return []
        case .edgeSwipeEnded(let page, let completed):
            guard let index = segments.firstIndex(where: { $0.top == page && $0.phase == .popping })
            else { return [] }
            segments[index].phase = .up
            guard completed else { return [] }
            segments[index].pages.removeLast()
            // A swipe that popped a page the edge still shows is the
            // person's swipe, for the page it popped.
            return took(page, .back)
        case .edgeSwipeRefused(let page):
            // Held by UIKit, the page is still on top: the machine decides.
            guard let index = segments.firstIndex(where: { $0.top == page && $0.pages.count > 1 }),
                  segments[index].phase == .up else { return [] }
            return held(page, .back)
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

    private func index(of id: NuxieMachineShown) -> Int? {
        segments.firstIndex { $0.id == id }
    }

    /// A swipe UIKit ran natively took `shown`: while the edge still shows
    /// it and the record is open, the machine hears it once, and `shown` is
    /// not shown again until it has answered.
    private mutating func took(_ shown: NuxieMachineShown, _ gesture: NuxieMachineSwipeGesture) -> [Effect] {
        guard case .open = record, wanted.contains(where: { $0.shown == shown }) else { return [] }
        closing.append(shown)
        return [.swipe(shown, gesture)]
    }

    /// A swipe UIKit held on `shown`: while the edge still shows it and the
    /// record is open, the machine hears it once.
    private func held(_ shown: NuxieMachineShown, _ gesture: NuxieMachineSwipeGesture) -> [Effect] {
        guard case .open = record, wanted.contains(where: { $0.shown == shown }) else { return [] }
        return [.swipe(shown, gesture)]
    }

    // MARK: The sync

    /// Make the segments follow what is shown, cut into segments. Waits
    /// while any segment is in a transition: the event that ends it runs
    /// the sync again. Otherwise it keeps the segments both have from the
    /// bottom up ([`continues`]); dismisses the first held segment past
    /// that, with every one above it; or else sets the pages of the first
    /// kept segment whose pages differ, by identity; or else presents the
    /// first segment missing, over the one below it. One step at a time,
    /// each finished by UIKit before the next.
    private mutating func sync() -> [Effect] {
        guard segments.allSatisfy({ $0.phase == .up }) else { return [] }
        let cut = Self.cut(wanted)
        var keep = 0
        while keep < segments.count, keep < cut.count, continues(segments[keep], at: keep, as: cut[keep]) {
            keep += 1
        }
        if keep < segments.count {
            for index in keep..<segments.count { segments[index].phase = .leaving }
            return [.dismiss(segments[keep].id)]
        }
        guard case .open = record else { return [] }
        for index in 0..<keep {
            let pages = cut[index]
            let had = segments[index].pages.map(\.shown)
            guard pages.map(\.shown) != had else {
                // The same pages: take what the session says of them now.
                segments[index].pages = pages
                continue
            }
            // A page swiped away stays in what is shown until the edge
            // answers its close; it is not pushed again meanwhile.
            guard !pages.contains(where: { !had.contains($0.shown) && closing.contains($0.shown) }) else {
                return []
            }
            segments[index].pages = pages
            segments[index].phase = .changing
            return [.setPages(segments[index].id, pages)]
        }
        guard keep < cut.count else { return [] }
        let next = cut[keep]
        // A swiped presentation stays in what is shown until the edge
        // answers its close; nothing opens in its place meanwhile.
        guard !next.contains(where: { closing.contains($0.shown) }) else { return [] }
        let first = next[0]
        guard first.presentation == .sheet || first.presentation == .cover || first.presentation == .push else {
            return fail(NuxieMachineEdgeFault(code: "edge.unsupported-presentation",
                detail: "present \(first.route) as \(first.presentation); only a push, a sheet and a cover are presented"))
                + sync()
        }
        segments.append(Segment(pages: next, phase: .arriving))
        return [.present(next, over: keep > 0 ? segments[keep - 1].id : nil)]
    }

    /// Whether the held segment `held`, at `index` of the segments, is the
    /// one native presentation for `pages`, a segment of what is shown: its
    /// first page is the same, by identity; or both are the first segment
    /// and each starts with a page shown as a push, so the cover stays and
    /// only its pages change (a replace of its first page, or a clear and a
    /// push).
    private func continues(_ held: Segment, at index: Int, as pages: [NuxieMachinePresented]) -> Bool {
        if held.bottom.shown == pages[0].shown { return true }
        return index == 0 && held.bottom.presentation == .push && pages[0].presentation == .push
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
