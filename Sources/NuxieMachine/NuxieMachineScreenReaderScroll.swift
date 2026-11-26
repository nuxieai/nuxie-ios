#if os(iOS) && !targetEnvironment(macCatalyst)
// What a screen reader has asked of a machine Screen's `scroll`s and is not
// done, and what each input does to it ([`NuxieMachineScreenReaderScrolling`]).
// "Nothing" leaves it as it is. Every other cell is checked by its row's test
// in ScreenReaderScrollRuleTests (`testTheRevealRow`, `testTheHeldTapRow`,
// `testThePageInFlightRow`, `testTheQueuedPagesRow`,
// `testTheAnnouncementRow`); the surface going away, on the engine, by
// ScreenReaderScrollingTests' `testTheSurfaceGoingAwayDropsEverything`.
//
// "At rest" is a drawn frame whose step reported itself settled, or the last
// of `stillFrames` drawn frames in a row in which no region's position changed
// and the waited-on node's box moved less than `stillDistance`, each frame and
// across the run
// ([`NuxieMachineScreenReaderScroll.isAtRest`]). A frame that steps but is not
// drawn shows no capture of its step, so it is never at rest.
//
// Reveal (`target`; `settling` once it moved)
//   same node asked again       nothing
//   another node asked          replaces it: the latest focus is the one revealed
//   a page, either way          nothing
//   frame not drawn             not at rest: no reveal goes, one moving stays moving
//   answer moved                waits for rest (`settling`), then is checked again
//   answer stayed               checked at the next rest: let go if it shows whole,
//                               else sent again, at most once per region around it
//   answer stale                sent again, at most `staleRetries` times
//   answer refused              let go
//   answer for an earlier node  nothing (stale or refused)
//   capture loses the node      let go at the next take
//   surface goes away           dropped (`stop` clears everything)
//
// Held tap (`heldTap`)
//   same node tapped again      answers false: one tap waits
//   another node tapped         replaces it, and its node is the one revealed
//   a page, either way          nothing
//   frame not drawn             not at rest: it does not go
//   its reveal moved            waits for rest
//   its reveal stayed, stale    goes at the next rest if its node then offers a tap,
//     past retries, or refused  else dropped
//   capture loses the node      dropped at the next take
//   surface goes away           dropped
//
// Page in flight (`paging`: the one page a frame carries)
//   a page asked, any node,     nothing: it is queued for a later frame
//     region or way
//   frame not drawn             nothing: its answer is a fact of the step
//   answer moved                done; its region's line waits to be told
//   answer stayed or refused    done, nothing told
//   answer stale                queued again first: joined by its region's queued
//                               page its way, dropped for one the other way; at
//                               most `staleRetries` times
//   answer to another request   nothing
//   capture loses the region    the engine answers refused
//   surface goes away           dropped
//
// Pages queued (`pages`: one per region, kept in the order asked)
//   same region, same way       adds a page to it (from whichever node)
//   same region, other way      replaces it: the latest way asked
//   another region              a page of its own, after those asked before it
//   frame not drawn             nothing: a page is a move by a distance and does
//                               not wait for rest
//   any answer                  nothing (answers touch only the page in flight)
//   capture loses the node      dropped when its frame takes it; one whose node now
//     or no region can move     moves no region that way too
//   surface goes away           dropped
//
// Page announcement (`announcing`: a page that moved, not yet told)
//   a page asked                nothing
//   another page moved          replaced: the reader hears what shows last
//   another page stayed, stale  nothing
//     or refused
//   frame not drawn             held: the capture on screen is from before the move
//   frame drawn                 told, "Page n of m" read from that frame's capture
//   capture loses the region    told with nothing to say
//   surface goes away           dropped untold

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
    /// included.
    package static func isAtRest(settled: Bool, frames: [NuxieMachineRestSample]) -> Bool {
        if settled { return true }
        guard frames.count > stillFrames else { return false }
        let recent = Array(frames.suffix(stillFrames + 1))
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
/// and overshoots. Focus can move faster than a reveal settles, so only the
/// latest node is held. Once a reveal has come to rest, a node still not
/// whole inside its regions is revealed again (each scroller's move is
/// worked out from where the node was drawn before the scrollers inside it
/// moved), at most as many times in all as it has regions around it.
///
/// A screen reader's tap on a node that waits for a reveal (its own, or one
/// that does not show and offers no tap until it does) waits behind it, and
/// goes in the first frame at rest after, to the snapshot of that frame, if
/// the node then offers a tap. A page does not wait for rest: it starts from
/// where the content is going. A frame carries one page; pages are kept one
/// per region, so pages asked from nodes in different regions each go to
/// their own. The line for a page that moved is told after a frame whose
/// capture shows the move, one that was drawn.
///
/// What a frame carries is kept apart from what is asked while it is in
/// flight: a frame's answers settle only the requests it carried, so a page,
/// focus or tap asked before it ends waits for the next frame.
package struct NuxieMachineScreenReaderScrolling: Equatable, Sendable {
    /// The node focus reached last that still needs a reveal.
    package private(set) var target: UInt32?
    /// A tap waiting behind a reveal.
    package private(set) var heldTap: UInt32?
    /// The node of the reveal that moved and has not come to rest.
    package private(set) var settling: UInt32?
    /// Whether the last frame was at rest
    /// ([`NuxieMachineScreenReaderScroll.isAtRest`]); none is before the
    /// first drawn frame.
    package private(set) var atRest = false
    /// Reveals sent for `target`.
    private var reveals = 0
    /// Calls asked of a spent snapshot, sent again.
    private var stale = 0
    /// Pages asked for and not yet sent, one per region, oldest first.
    private var pages: [Page] = []
    /// The page a frame carries and has not answered, and the request it
    /// went as; only its answer touches it.
    private var paging: Flight?
    /// A page that moved and whose line is not yet told: its region and
    /// whether it moved along y.
    private var announcing: Told?
    /// The drawn frames the rest rule reads, the latest last.
    private var frames: [NuxieMachineRestSample] = []

    /// A page that moved, to be told: its region and whether it moved
    /// along y.
    private struct Told: Equatable, Sendable {
        let region: Int
        let vertical: Bool
    }

    /// A page in flight and the request it went as.
    private struct Flight: Equatable, Sendable {
        let page: Page
        let request: NuxieMachineScrollRequest
    }

    /// Pages asked for and not yet sent: the region they were asked of, the
    /// node the first was asked from, which way, and how many.
    private struct Page: Equatable, Sendable {
        var region: Int
        let node: UInt32
        let direction: NuxieMachineScrollDirection
        var count: Int
        var stale = 0
    }

    /// The most times a call asked of a spent snapshot is sent again.
    package static let staleRetries = 4

    package init() {}

    /// Focus reached `node`, which has a region: it is the one to reveal.
    package mutating func focus(_ node: UInt32) {
        guard target != node else { return }
        target = node
        reveals = 0
        stale = 0
    }

    /// A tap on `node` waits behind its reveal; one already waiting for it
    /// stands, so a second answers false.
    package mutating func hold(tap node: UInt32) -> Bool {
        guard heldTap != node else { return false }
        heldTap = node
        if target != node && settling != node { focus(node) }
        return true
    }

    /// Whether a tap on `node` has to wait behind a reveal: one is asked
    /// for it, or moving and not at rest.
    package func revealPending(for node: UInt32) -> Bool {
        target == node || settling == node
    }

    /// One more page `direction` from `node`, which takes region `region`
    /// of the capture it was asked of ([`NuxieMachineScreenReaderScroll.page`]).
    /// Pages asked of a region before a frame takes them add up its way;
    /// one the other way replaces them.
    package mutating func page(_ direction: NuxieMachineScrollDirection, from node: UInt32, region: Int) {
        if let index = pages.firstIndex(where: { $0.region == region }) {
            if pages[index].direction == direction {
                pages[index].count += 1
                return
            }
            pages.remove(at: index)
        }
        pages.append(Page(region: region, node: node, direction: direction, count: 1))
    }

    /// Whether anything waits for a frame: something to send, a rest to
    /// see, or a line to tell once a frame is drawn.
    package var wantsFrames: Bool {
        target != nil || heldTap != nil || settling != nil || !pages.isEmpty || paging != nil
            || announcing != nil
    }

    /// The pages waiting, one per region, oldest first, as region, way and
    /// count, for checks.
    package var queuedPages: [(region: Int, direction: NuxieMachineScrollDirection, count: Int)] {
        pages.map { ($0.region, $0.direction, $0.count) }
    }

    /// What the coming frame carries, asked of `capture`, the snapshot on
    /// screen: the oldest page that can still go, and, at rest, a reveal or
    /// a tap that waited.
    package mutating func take(_ capture: NuxieNativeSemanticCapture?)
        -> (scrolls: [NuxieMachineScrollRequest], tap: NuxieMachineSemanticTap?) {
        guard let capture else { return ([], nil) }
        var scrolls: [NuxieMachineScrollRequest] = []
        var tap: NuxieMachineSemanticTap?
        let nodes = capture.tree.nodes
        while !pages.isEmpty {
            var waiting = pages.removeFirst()
            guard let node = nodes.first(where: { $0.id == waiting.node }),
                  let move = NuxieMachineScreenReaderScroll.page(waiting.direction, from: node,
                                                                 in: capture.scrollRegions)
            else { continue }
            let request = NuxieMachineScrollRequest.page(captureID: capture.id, region: move.region,
                                                         dx: move.dx * Float(waiting.count),
                                                         dy: move.dy * Float(waiting.count))
            waiting.region = move.region
            scrolls.append(request)
            paging = Flight(page: waiting, request: request)
            break
        }
        guard atRest, settling == nil else { return (scrolls, nil) }
        if let wanted = target {
            if let node = nodes.first(where: { $0.id == wanted }),
               !NuxieMachineScreenReaderScroll.isShown(node, in: capture.scrollRegions),
               reveals < NuxieMachineScreenReaderScroll.regions(of: node, in: capture.scrollRegions).count {
                reveals += 1
                scrolls.append(.reveal(captureID: capture.id, nodeID: wanted))
                return (scrolls, nil)
            }
            target = nil
        }
        if let held = heldTap {
            heldTap = nil
            let tapBit: UInt32 = 1 << NuxieNativeSemanticAction.tap.rawValue
            if let node = nodes.first(where: { $0.id == held }), node.actions & tapBit != 0 {
                tap = NuxieMachineSemanticTap(captureID: capture.id, nodeID: held)
            }
        }
        return (scrolls, tap)
    }

    /// The frame that carried what [`take`] gave ended: `scrolled` is what
    /// came of each request, `settled` whether its step reported itself
    /// settled, and `drawn` the capture of the frame it drew, none when it
    /// drew none. Answers what the reader is told now, if anything: the line
    /// of a page that moved, once a drawn frame shows it.
    @discardableResult
    package mutating func ended(_ scrolled: [NuxieMachineScrolled], settled: Bool,
                                drawn capture: NuxieNativeSemanticCapture?) -> NuxieMachinePageAnnouncement? {
        for result in scrolled {
            switch result.request {
            case .reveal(_, let node):
                switch result.outcome {
                case .moved:
                    settling = node
                case .stayed:
                    break
                case .stale:
                    if target == node {
                        stale += 1
                        reveals -= 1
                        if stale > Self.staleRetries { target = nil }
                    }
                case .refused:
                    if target == node { target = nil }
                }
            case .page(_, _, _, let dy):
                guard let flying = paging, flying.request == result.request else { continue }
                paging = nil
                switch result.outcome {
                case .moved:
                    announcing = Told(region: flying.page.region, vertical: dy != 0)
                case .stayed, .refused:
                    break
                case .stale:
                    requeue(flying.page)
                }
            }
        }
        guard let capture else {
            atRest = false
            return nil
        }
        frames.append(NuxieMachineRestSample(capture, waitingOn: settling ?? target ?? heldTap))
        if frames.count > NuxieMachineScreenReaderScroll.stillFrames + 1 { frames.removeFirst() }
        atRest = NuxieMachineScreenReaderScroll.isAtRest(settled: settled, frames: frames)
        if atRest { settling = nil }
        guard let told = announcing else { return nil }
        announcing = nil
        let regions = capture.scrollRegions
        return NuxieMachinePageAnnouncement(line: regions.indices.contains(told.region)
            ? NuxieMachineScreenReaderScroll.pageLine(regions[told.region], vertical: told.vertical) : nil)
    }

    /// A page in flight that came back stale goes again first, a bounded
    /// number of times: pages its region asked since its way join it; one
    /// the other way stands instead, being what was asked last.
    private mutating func requeue(_ page: Page) {
        guard page.stale < Self.staleRetries else { return }
        var again = page
        again.stale += 1
        if let index = pages.firstIndex(where: { $0.region == again.region }) {
            guard pages[index].direction == again.direction else { return }
            again.count += pages.remove(at: index).count
        }
        pages.insert(again, at: 0)
    }
}
#endif
