#if os(iOS) && !targetEnvironment(macCatalyst)
// What a screen reader has asked of a machine Screen's `scroll`s and is not
// done, and what each input does to it ([`NuxieMachineScreenReaderScrolling`]).
// "Nothing" leaves it as it is. Every other cell is checked by its row's test
// in ScreenReaderScrollRuleTests (`testTheRevealRow`, `testTheHeldTapRow`,
// `testTheAskedPageRow`, `testThePageInFlightRow`, `testTheAnnouncementRow`,
// `testDetachingLeavesNothingPending`); the Screen going away, on the engine,
// by ScreenReaderScrollingTests' `testTheSurfaceGoingAwayDropsEverything`,
// `testAnySequenceEndingInADetachLetsTheLoopRest` and
// `testATapQueuedForAScreenWithNoSizeIsDropped`.
//
// Every input below reaches the rule. Each request a frame carried gets its
// answer, even when the Screen was not stepped or drew nothing; a Screen that
// cannot be stepped (no window or size) is sent no request. Only rest and the
// page line wait for a drawn frame.
//
// "At rest" is a drawn frame whose step reported itself settled, or the last
// of `stillFrames` drawn frames in a row of the node waited on now (one moving,
// else a held tap's, else the focused one) in which no region's position
// changed and its box moved less than `stillDistance`, each frame and across
// the run ([`NuxieMachineScreenReaderScroll.isAtRest`]). The run starts over
// when the node waited on changes (from none too) and when a page or reveal
// moved; frames with no node waited on never count, so then only a settled
// step is rest. A frame that steps but is not drawn shows no capture of its
// step, so it is never at rest.
//
// Reveal (`target`; `settling` once it moved)
//   same node focused again     nothing
//   another node in a `scroll`  replaces it: the latest focus is the one revealed,
//     focused                   after still frames of that node
//   a node under no `scroll`    let go, unless a tap is held (its row)
//     focused
//   focus leaves its node       let go (`accessibilityElementDidLoseFocus`)
//   focus leaves another node   nothing
//   a page asked                nothing
//   a page goes in the frame    no reveal in that frame; the page's move starts
//                               the still frames over
//   frame not drawn             not at rest: no reveal goes, one moving stays moving
//   answer moved                waits for rest (`settling`), then is checked again;
//                               the still frames start over
//   answer stayed               checked at the next rest: let go if it shows whole,
//                               else sent again, at most once per region around it
//   answer stale                sent again, at most `staleRetries` times
//   answer refused              let go
//   answer for an earlier node  nothing (stale or refused)
//   answer after a detach       nothing: the reveal no longer counts
//   capture loses the node      let go at the next take (its element goes with it)
//   VoiceOver turns off         nothing: a reveal under way finishes, one waiting
//                               still goes (one move of the page, no harm)
//   Screen leaves its window,   dropped (`detach`); `stop` drops it too
//     is covered or leaves the
//     loop's Screens
//   Screen loses its size       kept, asking for no frame until the size is back
//
// Held tap (`heldTap`)
//   same node tapped again      answers false: one tap waits
//   another clipped node tapped replaces it: the newest activation wins
//   a node in view tapped       replaces it: that tap goes at once and the held one
//                               is dropped (newest wins); a tap held after a tap not
//                               yet sent replaces that tap the same way
//   focus moves to another      nothing: the tap was a deliberate activation, so
//     node, under a `scroll`    its node is revealed and tapped first, and the
//     or not, or leaves         focused node revealed after
//   a page asked                nothing
//   a page goes in the frame    it does not go in that frame
//   frame not drawn             not at rest: it does not go
//   its reveal moved            waits for rest
//   its reveal stayed, stale    goes at the next rest if its node then offers a tap,
//     past retries, or refused  else dropped
//   capture loses the node      dropped at the next take
//   VoiceOver turns off         nothing: it still goes
//   Screen leaves its window,   dropped
//     is covered or leaves the
//     loop's Screens
//   Screen loses its size       kept, asking for no frame until the size is back
//
// Asked page (`asked`: at most one, as its node and way)
//   another page asked, any     replaces it: the latest wins (pages do not add up)
//     node or way
//   a page in flight            it waits, and goes in the first frame after the
//                               answer
//   frame not drawn             nothing: it goes all the same; a page is a move by
//                               a distance and does not wait for rest
//   any answer                  nothing (a stale answer does not replace it)
//   capture loses the node, or  dropped when its frame takes it; its region is found
//     no region around it can   from the node in that frame's capture, never kept
//     move that way             from an earlier one
//   Screen leaves its window,   dropped
//     is covered or leaves the
//     loop's Screens
//   Screen loses its size       kept, asking for no frame until the size is back
//
// Page in flight (`paging`: one at a time)
//   a page asked                nothing: it is the asked page and waits
//   frame not drawn, or the     nothing: its answer still comes
//     Screen not stepped
//   answer moved                done; its line waits to be told
//   answer stayed or refused    done, nothing told
//   answer stale                asked again, the same node and way, at most
//                               `staleRetries` times, unless a newer page was asked
//                               (then that one goes instead)
//   answer to another request   nothing
//   Screen leaves its window,   dropped; its answer, when it comes, changes nothing
//     is covered or leaves the
//     loop's Screens
//   Screen loses its size       its answer still comes (the frame carried it)
//
// Page announcement (`announcing`: a page that moved, not yet told)
//   a page asked                nothing
//   another page moved          replaced: the reader hears what shows last
//   another page stayed, stale  nothing
//     or refused
//   frame not drawn             held: the capture on screen is from before the move
//   frame drawn                 told, "Page n of m" read from that frame's capture,
//                               the region found again from the page's node
//   capture loses the node or   told with nothing to say
//     the region
//   Screen leaves its window,   dropped untold
//     is covered or leaves the
//     loop's Screens
//   Screen loses its size       held: no frame is drawn, and none is asked for
//
// Queued tap (the controller's `semanticTap`: a tap on a node in view, or a
// held tap whose node now offers one, waiting for the next frame)
//   another activation          the newest wins (Held tap row); one of the same
//                               snapshot is refused
//   next frame, Screen stepped  sent with that frame, beside its pointers
//   next frame, Screen cannot   dropped: its answer could not reach it, and kept
//     be stepped                it would keep the loop from resting
//   Screen leaves its window,   dropped
//     is covered or leaves the
//     loop's Screens; the loop
//     stops
//
// What keeps frames coming. The loop rests once no Screen has input
// (`hasInput`: pointers, a queued tap, or, while it can be stepped, anything
// in the rows above, `wantsFrames`), nothing asked for a frame since the last
// began, and the engine's drawn step does not ask for another. Every piece of
// state that feeds those, and what each of four changes does to it:
//
//   state                  leaves window   loses size      covered         leaves Screens
//   reveal, settling,      dropped         kept; no frame  dropped         dropped
//     held tap, asked                      asked
//     page, page in
//     flight, page line
//   stale counts, reveal   reset           kept            reset           reset
//     counts, rest window
//   queued tap             dropped         dropped at the  dropped         dropped
//                                          next take
//   pointers (not this     kept; sent with kept; sent with kept; sent with kept, never read
//     PR's)                the next frame  the next frame  the next frame
//   a frame asked          one frame, then one frame, then one frame, then one frame, then
//     (`requestFrame`)     rest            rest            rest            rest
//   the sheet pan's touch  cleared         kept until the  kept until the  kept until the
//     and regions (not                     touch ends      touch ends      touch ends
//     this PR's; never
//     asks for a frame)

import CoreGraphics
import Foundation
import NuxieRuntime

/// Which way a screen reader asks a `scroll` to move, as what it shows next.
package enum NuxieMachineScrollDirection: Equatable, Sendable {
    /// What is below: the content moves up.
    case showBelow
    /// What is above: the content moves down.
    case showAbove
    /// What is to the right: the content moves left.
    case showRight
    /// What is to the left: the content moves right.
    case showLeft
}

/// A move of one presentation's `scroll` asked of the snapshot `captureID`,
/// queued on its player before a frame's step, beside a screen reader's taps
/// ([`NuxieMachineEdge.frame`]).
package enum NuxieMachineScrollRequest: Equatable, Sendable {
    /// Bring node `nodeID` into view: each scroller above it moves by the
    /// least that shows it.
    case reveal(captureID: UUID, nodeID: UInt32)
    /// Move region `region`'s content by `dx`, `dy` points, a scroll
    /// wheel's sense: a negative `dy` shows what is below.
    case page(captureID: UUID, region: Int, dx: Float, dy: Float)
}

/// What the engine did with a [`NuxieMachineScrollRequest`].
package enum NuxieMachineScrollOutcome: Equatable, Sendable {
    /// A scroller moved; it may still be settling.
    case moved
    /// Nothing moved: the node was in view, or the region at its end.
    case stayed
    /// The snapshot it was asked of is no longer the player's (an earlier
    /// call in the frame spent it): asked again of the next one.
    case stale
    /// The engine refused it otherwise (the node or region is gone), or the
    /// frame dropped it with the presentation it was for.
    case refused
}

/// One request a frame carried and what came of it.
package struct NuxieMachineScrolled: Equatable, Sendable {
    package let request: NuxieMachineScrollRequest
    package let outcome: NuxieMachineScrollOutcome

    package init(_ request: NuxieMachineScrollRequest, _ outcome: NuxieMachineScrollOutcome) {
        self.request = request
        self.outcome = outcome
    }
}

/// How a machine component's `scroll`s answer a screen reader, as pure
/// functions of a capture: whether a node shows whole, how far a page goes
/// and which region takes it.
package enum NuxieMachineScreenReaderScroll {
    /// The regions that clip `node`, innermost first: its own, then each
    /// one it is inside. None for a node under no `scroll`.
    package static func regions(of node: NuxieNativeSemanticNode,
                                in regions: [NuxieNativeScrollRegion]) -> [Int] {
        var chain: [Int] = []
        var next = node.scrollRegion
        while let index = next, regions.indices.contains(index), !chain.contains(index) {
            chain.append(index)
            next = regions[index].parent
        }
        return chain
    }

    /// Whether `node` shows whole: its box inside the box of every region
    /// that clips it, to half a point. A node under no `scroll` shows.
    package static func isShown(_ node: NuxieNativeSemanticNode, in regions: [NuxieNativeScrollRegion]) -> Bool {
        let box = node.bounds.insetBy(dx: 0.5, dy: 0.5)
        return Self.regions(of: node, in: regions).allSatisfy { index in
            let port = regions[index].bounds
            return box.isEmpty ? port.contains(CGPoint(x: node.bounds.midX, y: node.bounds.midY))
                : port.contains(box)
        }
    }

    /// One page along an axis whose box is `length` points: what the box
    /// shows less a little kept in view, `max(length - 48, length / 2, 1)`.
    package static func pageStep(_ length: CGFloat) -> CGFloat {
        max(length - 48, length / 2, 1)
    }

    /// The words the reader says after a page moved: which page of how many
    /// the box now shows. English only: translating the SDK's spoken
    /// strings is tracked as UNIV-7117.
    package static func pageWords(_ page: Int, of pages: Int) -> String {
        "Page \(page) of \(pages)"
    }

    /// Which page of how many a box `length` points long shows, scrolled to
    /// `position` of `range`, counted in page steps ([`pageStep`]), so each
    /// page a screen reader moves reaches the next: the first page is at
    /// the top and one more starts at each step, the last at the end,
    /// `1 + ceil(range / step)` in all (half a point short of a whole step
    /// adds none). Within half a point of `range` the box shows the last;
    /// short of it, the step it is nearest, never the last. None when the
    /// pages cannot be counted: a range, position or length that is not a
    /// finite number (a looping scroller's range is unbounded), a negative
    /// range, or more than [`mostPages`].
    package static func shownPage(position: CGFloat, range: CGFloat, length: CGFloat) -> (page: Int, of: Int)? {
        guard range.isFinite, range >= 0, position.isFinite, length.isFinite else { return nil }
        let step = pageStep(length)
        let steps = (max(range - 0.5, 0) / step).rounded(.up)
        guard steps.isFinite, steps < CGFloat(mostPages) else { return nil }
        let pages = 1 + Int(steps)
        if position >= range - 0.5 { return (pages, pages) }
        let nearest = (max(position, 0) / step + 0.5).rounded(.down)
        return (min(pages - 1, Int(min(nearest, CGFloat(pages))) + 1), pages)
    }

    /// The most pages a page line counts; a longer content has none.
    package static let mostPages = 10_000

    /// The line for `region` after a page moved it along y (`vertical`) or
    /// x, read from its position, which is where it is going; none when
    /// the runtime does not read its position or its pages cannot be
    /// counted ([`shownPage`]).
    package static func pageLine(_ region: NuxieNativeScrollRegion, vertical: Bool) -> String? {
        guard let scroll = region.scroll, let range = region.range else { return nil }
        let shown = vertical
            ? shownPage(position: scroll.y, range: range.height, length: region.bounds.height)
            : shownPage(position: scroll.x, range: range.width, length: region.bounds.width)
        return shown.map { pageWords($0.page, of: $0.of) }
    }

    /// The move one page in `direction` asks for, from where `node` is: the
    /// first region from its own outward whose content can still move that
    /// way, and the move in a scroll wheel's sense, a page of that region's
    /// box. None when no region above the node can move that way: at an
    /// end, or under no `scroll`, or when the region's box is not a finite
    /// length that way.
    package static func page(_ direction: NuxieMachineScrollDirection, from node: NuxieNativeSemanticNode,
                             in regions: [NuxieNativeScrollRegion]) -> (region: Int, dx: Float, dy: Float)? {
        let bit: UInt32
        switch direction {
        case .showBelow: bit = NuxieNativeScrollRegion.towardBottom
        case .showAbove: bit = NuxieNativeScrollRegion.towardTop
        case .showRight: bit = NuxieNativeScrollRegion.towardRight
        case .showLeft: bit = NuxieNativeScrollRegion.towardLeft
        }
        guard let index = Self.regions(of: node, in: regions).first(where: { regions[$0].canScroll & bit != 0 })
        else { return nil }
        let box = regions[index].bounds
        let vertical = direction == .showBelow || direction == .showAbove
        let length = vertical ? box.height : box.width
        guard length.isFinite else { return nil }
        let step = Float(pageStep(length))
        switch direction {
        case .showBelow: return (index, 0, -step)
        case .showAbove: return (index, 0, step)
        case .showRight: return (index, -step, 0)
        case .showLeft: return (index, step, 0)
        }
    }

    /// Which way "next" (`forward`) or "previous" goes from `node`: in the
    /// first region from its own outward that can move along y or
    /// sideways that way, down (up) the page when it can move along y, else
    /// further on (back) sideways. None when no region around it can.
    package static func onward(_ forward: Bool, from node: NuxieNativeSemanticNode,
                               in regions: [NuxieNativeScrollRegion]) -> NuxieMachineScrollDirection? {
        let along = forward ? NuxieNativeScrollRegion.towardBottom : NuxieNativeScrollRegion.towardTop
        let sideways = forward ? NuxieNativeScrollRegion.towardRight : NuxieNativeScrollRegion.towardLeft
        guard let index = Self.regions(of: node, in: regions)
            .first(where: { regions[$0].canScroll & (along | sideways) != 0 }) else { return nil }
        if regions[index].canScroll & along != 0 { return forward ? .showBelow : .showAbove }
        return forward ? .showRight : .showLeft
    }

    /// Drawn frames in a row that must change nothing before a Screen
    /// whose step never reports itself settled (an animation that never
    /// stops keeps it going) counts as at rest. One still frame is not
    /// enough: a scroller turning at the end of a spring, or between two
    /// steps of its animation, can draw the same box twice. Three at 60
    /// frames a second is 50 milliseconds, short enough that a reveal on
    /// such a page waits no longer than a person notices.
    package static let stillFrames = 3

    /// The most a waited-on node's box may move, at any edge, from one
    /// drawn frame to the next and across the whole run of still frames, and
    /// still count as still, in points: the half point [`isShown`] allows,
    /// so a move that small cannot change whether the node shows whole. A
    /// scroller easing to a stop creeps less than that each frame for its
    /// last few frames; held to the whole run as well, rest comes only once
    /// what is left of its travel is about that small (on Stillwater's
    /// reveal, a fraction of a point before it stops).
    package static let stillDistance: CGFloat = 0.5

    /// Whether a Screen is at rest after a drawn frame: its step reported
    /// itself settled, or `frames`, the drawn frames so far with the
    /// latest last, end in [`stillFrames`] frames each of which changed
    /// nothing since the one before: no region's position (the position a
    /// region is going to, read as soon as a move is asked), the same
    /// waited-on node, and its box (where it is drawn, which follows the
    /// move as it animates) moved less than [`stillDistance`] at each edge,
    /// from each frame to the next and from the first of the run to the
    /// last. A box that is the same exactly is still, a placeholder's
    /// included. Frames with no node waited on never count: positions read
    /// where a region is going, not where its content is drawn, so only a
    /// node's box shows a move still in flight, and with none only a
    /// settled step is rest.
    package static func isAtRest(settled: Bool, frames: [NuxieMachineRestSample]) -> Bool {
        if settled { return true }
        guard frames.count > stillFrames else { return false }
        let recent = Array(frames.suffix(stillFrames + 1))
        guard recent.allSatisfy({ $0.node != nil }) else { return false }
        let unchanged = zip(recent, recent.dropFirst()).allSatisfy { before, after in
            before.positions == after.positions && before.node == after.node && isStill(before.box, after.box)
        }
        return unchanged && isStill(recent[0].box, recent[stillFrames].box)
    }

    private static func isStill(_ before: CGRect?, _ after: CGRect?) -> Bool {
        guard let before, let after else { return before == nil && after == nil }
        if before == after { return true }
        let moves = [after.minX - before.minX, after.minY - before.minY,
                     after.maxX - before.maxX, after.maxY - before.maxY]
        return moves.allSatisfy { $0.isFinite && abs($0) < stillDistance }
    }
}

/// What a drawn frame's capture says about whether a Screen is at rest: each
/// region's position, in order, and the box of the node a reveal or a tap
/// waits on ([`NuxieMachineScreenReaderScroll.isAtRest`]).
package struct NuxieMachineRestSample: Equatable, Sendable {
    package let positions: [CGPoint?]
    package let node: UInt32?
    package let box: CGRect?

    package init(positions: [CGPoint?], node: UInt32?, box: CGRect?) {
        self.positions = positions
        self.node = node
        self.box = box
    }

    /// The sample of `capture` waiting on `node`, whose box is none when the
    /// capture has no such node.
    package init(_ capture: NuxieNativeSemanticCapture, waitingOn node: UInt32?) {
        self.init(positions: capture.scrollRegions.map(\.scroll), node: node,
                  box: node.flatMap { id in capture.tree.nodes.first { $0.id == id }?.bounds })
    }
}

/// What the reader is told after a page moved: the line, or none when there
/// is nothing to say (its pages cannot be counted, or the capture lost its
/// region), told all the same.
package struct NuxieMachinePageAnnouncement: Equatable, Sendable {
    package let line: String?

    package init(line: String?) {
        self.line = line
    }
}

/// What a machine component has asked of its `scroll`s for a screen reader
/// and is not done: the node focus reached, a tap waiting behind its reveal,
/// pages, and the line of a page that moved. Each frame takes what may go now
/// ([`take`]) and hears back what came of it and what it drew ([`ended`]).
/// The table at the top of this file says what each input does to each.
///
/// The rule for reveals: reveal only at rest, since a reveal while a
/// scroller settles adds the node's remaining travel to where it is going
/// and overshoots. Rest is a settled step, or still frames of the node now
/// waited on, counted from when it became the one waited on or from the
/// last move answered, whichever is later. Focus can move faster than a
/// reveal settles, so only the latest node is held. Once a reveal has come
/// to rest, a node still not whole inside its regions is revealed again
/// (each scroller's move is worked out from where the node was drawn before
/// the scrollers inside it moved), at most as many times in all as it has
/// regions around it. Focus that moves to a node under no `scroll`, or
/// leaves the node, lets its reveal go.
///
/// A screen reader's tap on a node that waits for a reveal (its own, or one
/// that does not show and offers no tap until it does) waits behind it, and
/// goes in the first frame at rest after, to the snapshot of that frame, if
/// the node then offers a tap. The tap was a deliberate activation, so focus
/// moving on does not cancel it: its node is revealed and tapped first, and
/// the node focus moved to after. The newest activation wins: a tap pressed
/// at once replaces a held one. A page does not wait for rest: it starts
/// from where the content is going. One page is asked at a time, the
/// latest, as its node and way; its region is found from the node in the
/// capture its frame takes, and one page is in flight at a time. The line
/// for a page that moved is told after a frame whose capture shows the move,
/// one that was drawn, read from the region found again from its node.
///
/// What a frame carries is kept apart from what is asked while it is in
/// flight: a frame's answers settle only the requests it carried, so a page,
/// focus or tap asked before it ends waits for the next frame.
package struct NuxieMachineScreenReaderScrolling: Equatable, Sendable {
    /// The node focus reached last that still needs a reveal.
    package private(set) var target: UInt32?
    /// A tap waiting behind a reveal of its node.
    package private(set) var heldTap: UInt32?
    /// The node of the reveal that moved and has not come to rest.
    package private(set) var settling: UInt32?
    /// The node the reveal counts are for: the last one a reveal went for.
    private var revealing: UInt32?
    /// Reveals sent for `revealing`.
    private var reveals = 0
    /// Calls asked of a spent snapshot, sent again, for `revealing`.
    private var stale = 0
    /// The page asked for and not yet sent: at most one, the latest.
    private var asked: Ask?
    /// The page a frame carries and has not answered, and the request it
    /// went as; only its answer touches it. One at a time.
    private var paging: Flight?
    /// A page that moved and whose line is not yet told.
    private var announcing: Told?
    /// What the last drawn frame showed of rest.
    private var rest = Rest.none
    /// The drawn frames the rest rule reads, the latest last, all of the
    /// node waited on since the last move answered.
    private var frames: [NuxieMachineRestSample] = []

    /// What the last frame showed of rest: none, a settled step (rest
    /// whatever is waited on), or still frames of one node (rest for that
    /// node only).
    private enum Rest: Equatable, Sendable {
        case none
        case settled
        case still(UInt32)
    }

    /// A page that moved, to be told: the node it was asked from, which of
    /// the regions around that node moved (0 its own, 1 the one outside
    /// it, and so on), and whether it moved along y. A region is found
    /// again from its node in each capture, never by its place in an
    /// earlier capture's list.
    private struct Told: Equatable, Sendable {
        let node: UInt32
        let depth: Int
        let vertical: Bool
    }

    /// A page asked: from which node, which way, and how many times it was
    /// sent again after a stale answer. Its region is found from the node
    /// in the capture the frame that sends it takes.
    private struct Ask: Equatable, Sendable {
        let node: UInt32
        let direction: NuxieMachineScrollDirection
        var stale = 0
    }

    /// A page in flight: what was asked, the request it went as, and which
    /// of the regions around its node it went to.
    private struct Flight: Equatable, Sendable {
        let ask: Ask
        let request: NuxieMachineScrollRequest
        let depth: Int
    }

    /// The most times a call asked of a spent snapshot is sent again.
    package static let staleRetries = 4

    package init() {}

    /// The node a reveal or a tap waits on, whose still frames make rest:
    /// one moving, else a held tap's, else the focused one.
    private var waitedOn: UInt32? { settling ?? heldTap ?? target }

    /// Whether the last frame was at rest for what waits now: its step
    /// settled, or it ended a run of still frames of the node waited on now
    /// ([`NuxieMachineScreenReaderScroll.isAtRest`]); never before the
    /// first drawn frame.
    package var atRest: Bool {
        switch rest {
        case .none: return false
        case .settled: return true
        case .still(let node): return node == waitedOn
        }
    }

    /// Focus reached `node`, which has a region: it is the one to reveal,
    /// with its reveals counted afresh.
    package mutating func focus(_ node: UInt32) {
        guard target != node else { return }
        target = node
        afresh(node)
    }

    /// Focus reached a node under no `scroll`: the node focus left needs no
    /// reveal. A held tap still goes.
    package mutating func focusOutside() {
        target = nil
    }

    /// Focus left `node`: if it is the one to reveal, it no longer is. A
    /// held tap still goes.
    package mutating func focusLeft(_ node: UInt32) {
        if target == node { target = nil }
    }

    /// A tap on `node` waits behind its reveal; one already waiting for it
    /// stands, so a second answers false. Another node's replaces it.
    package mutating func hold(tap node: UInt32) -> Bool {
        guard heldTap != node else { return false }
        heldTap = node
        if target != node { afresh(node) }
        return true
    }

    /// A tap pressed at once replaced the held one: the newest activation
    /// wins. A reveal focus asked for stays.
    package mutating func dropHeldTap() {
        heldTap = nil
    }

    /// Whether a tap on `node` has to wait behind a reveal: one is asked
    /// for it, held behind its own, or moving and not at rest.
    package func revealPending(for node: UInt32) -> Bool {
        target == node || settling == node || heldTap == node
    }

    /// A new ask for `node`: its reveals are counted from none.
    private mutating func afresh(_ node: UInt32) {
        guard revealing == node, settling != node else { return }
        reveals = 0
        stale = 0
    }

    /// Whether a reveal of `id`, `node` in `capture`, may go now, counting
    /// it: one more than it has had, at most one per region around it.
    private mutating func mayReveal(_ id: UInt32, _ node: NuxieNativeSemanticNode,
                                    in capture: NuxieNativeSemanticCapture) -> Bool {
        if revealing != id {
            revealing = id
            reveals = 0
            stale = 0
        }
        guard reveals < NuxieMachineScreenReaderScroll.regions(of: node, in: capture.scrollRegions).count
        else { return false }
        reveals += 1
        return true
    }

    /// The reveals of `node` are over: refused, or stale too often.
    private mutating func giveUp(_ node: UInt32) {
        reveals = Int.max
        if target == node { target = nil }
    }

    /// A page `direction` from `node`: the one page asked, replacing any
    /// asked before it and not yet sent. It goes when no page is in flight.
    package mutating func page(_ direction: NuxieMachineScrollDirection, from node: UInt32) {
        asked = Ask(node: node, direction: direction)
    }

    /// Whether anything waits for a frame: something to send, a rest to
    /// see, or a line to tell once a frame is drawn.
    package var wantsFrames: Bool {
        target != nil || heldTap != nil || settling != nil || asked != nil || paging != nil
            || announcing != nil
    }

    /// The page asked and not yet sent, as its node and way, for checks.
    package var askedPage: (node: UInt32, direction: NuxieMachineScrollDirection)? {
        asked.map { ($0.node, $0.direction) }
    }

    /// The Screen went away or left its window: nothing it asked is done,
    /// and nothing waits for a frame.
    package mutating func detach() {
        self = Self()
    }

    /// What the coming frame carries, asked of `capture`, the snapshot on
    /// screen: the page asked, when none is in flight and its node's
    /// regions can still move that way, and, at rest, a reveal or a tap
    /// that waited.
    package mutating func take(_ capture: NuxieNativeSemanticCapture?)
        -> (scrolls: [NuxieMachineScrollRequest], tap: NuxieMachineSemanticTap?) {
        guard let capture else { return ([], nil) }
        var scrolls: [NuxieMachineScrollRequest] = []
        var tap: NuxieMachineSemanticTap?
        let nodes = capture.tree.nodes
        if paging == nil, let ask = asked {
            asked = nil
            if let node = nodes.first(where: { $0.id == ask.node }),
               let move = NuxieMachineScreenReaderScroll.page(ask.direction, from: node, in: capture.scrollRegions),
               let depth = NuxieMachineScreenReaderScroll.regions(of: node, in: capture.scrollRegions)
                .firstIndex(of: move.region) {
                let request = NuxieMachineScrollRequest.page(captureID: capture.id, region: move.region,
                                                             dx: move.dx, dy: move.dy)
                scrolls.append(request)
                paging = Flight(ask: ask, request: request, depth: depth)
            }
        }
        // A page moves the content under a reveal: the reveal waits for rest
        // after it.
        guard scrolls.isEmpty, settling == nil, atRest else { return (scrolls, nil) }
        let tapBit: UInt32 = 1 << NuxieNativeSemanticAction.tap.rawValue
        if let held = heldTap {
            // The tap first: its node is revealed, then tapped.
            let node = nodes.first { $0.id == held }
            if let node, !NuxieMachineScreenReaderScroll.isShown(node, in: capture.scrollRegions),
               mayReveal(held, node, in: capture) {
                scrolls.append(.reveal(captureID: capture.id, nodeID: held))
                return (scrolls, nil)
            }
            heldTap = nil
            if target == held { target = nil }
            if let node, node.actions & tapBit != 0 {
                tap = NuxieMachineSemanticTap(captureID: capture.id, nodeID: held)
            }
            return (scrolls, tap)
        }
        if let wanted = target {
            if let node = nodes.first(where: { $0.id == wanted }),
               !NuxieMachineScreenReaderScroll.isShown(node, in: capture.scrollRegions),
               mayReveal(wanted, node, in: capture) {
                scrolls.append(.reveal(captureID: capture.id, nodeID: wanted))
                return (scrolls, nil)
            }
            target = nil
        }
        return (scrolls, nil)
    }

    /// The frame that carried what [`take`] gave ended: `scrolled` is what
    /// came of each request, `settled` whether its step reported itself
    /// settled, and `drawn` the capture of the frame it drew, none when it
    /// drew none. Answers what the reader is told now, if anything: the line
    /// of a page that moved, once a drawn frame shows it.
    @discardableResult
    package mutating func ended(_ scrolled: [NuxieMachineScrolled], settled: Bool,
                                drawn capture: NuxieNativeSemanticCapture?) -> NuxieMachinePageAnnouncement? {
        var moved = false
        for result in scrolled {
            switch result.request {
            case .reveal(_, let node):
                switch result.outcome {
                case .moved:
                    // Only a reveal this rule sent and still counts: after a
                    // detach none is, and its answer changes nothing.
                    guard revealing == node else { continue }
                    settling = node
                    moved = true
                case .stayed:
                    break
                case .stale:
                    if revealing == node {
                        stale += 1
                        reveals = max(0, reveals - 1)
                        if stale > Self.staleRetries { giveUp(node) }
                    }
                case .refused:
                    if revealing == node { giveUp(node) }
                }
            case .page(_, _, _, let dy):
                guard let flying = paging, flying.request == result.request else { continue }
                paging = nil
                switch result.outcome {
                case .moved:
                    announcing = Told(node: flying.ask.node, depth: flying.depth, vertical: dy != 0)
                    moved = true
                case .stayed, .refused:
                    break
                case .stale:
                    // Asked again, unless a newer page was asked since.
                    if asked == nil, flying.ask.stale < Self.staleRetries {
                        var again = flying.ask
                        again.stale += 1
                        asked = again
                    }
                }
            }
        }
        // The still frames start over when something moved or another node
        // is waited on; frames with none waited on are not kept.
        let node = waitedOn
        if moved || node == nil || frames.last?.node != node { frames = [] }
        guard let capture else {
            rest = .none
            return nil
        }
        if let node {
            frames.append(NuxieMachineRestSample(capture, waitingOn: node))
            if frames.count > NuxieMachineScreenReaderScroll.stillFrames + 1 { frames.removeFirst() }
        }
        rest = settled ? .settled
            : (node.map { NuxieMachineScreenReaderScroll.isAtRest(settled: false, frames: frames) ? .still($0) : .none }
                ?? .none)
        if atRest { settling = nil }
        guard let told = announcing else { return nil }
        announcing = nil
        let regions = capture.scrollRegions
        let chain = capture.tree.nodes.first { $0.id == told.node }
            .map { NuxieMachineScreenReaderScroll.regions(of: $0, in: regions) } ?? []
        return NuxieMachinePageAnnouncement(line: chain.indices.contains(told.depth)
            ? NuxieMachineScreenReaderScroll.pageLine(regions[chain[told.depth]], vertical: told.vertical) : nil)
    }
}
#endif
