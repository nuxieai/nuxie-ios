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
}

/// What a machine component has asked of its `scroll`s for a screen reader
/// and not yet sent: the node focus reached, a tap waiting behind its
/// reveal, and a page. Each frame takes what may go now ([`take`]) and hears
/// back what came of it ([`ended`]).
///
/// The rule for reveals: reveal only when the last frame's step reported
/// itself settled, since a reveal while a scroller settles adds the node's
/// remaining travel to where it is going and overshoots. Focus can move
/// faster than a reveal settles, so only the latest node is held. Once a
/// reveal has settled, a node still not whole inside its regions is
/// revealed again (each scroller's move is worked out from where the node
/// was drawn before the scrollers inside it moved), at most as many times
/// in all as it has regions around it.
///
/// A screen reader's tap on a node that waits for a reveal (its own, or one
/// that does not show and offers no tap until it does) waits behind it, and
/// goes in the first settled frame after, to the snapshot of that frame, if
/// the node then offers a tap. A page does not wait for a settle: it starts
/// from where the content is going.
///
/// What a frame carries is kept apart from what is asked while it is in
/// flight: a frame's answers settle only the requests it carried, so a page,
/// focus or tap asked before it ends waits for the next frame.
package struct NuxieMachineScreenReaderScrolling: Equatable, Sendable {
    /// The node focus reached last that still needs a reveal.
    package private(set) var target: UInt32?
    /// A tap waiting behind a reveal.
    package private(set) var heldTap: UInt32?
    /// The node of the reveal that moved and has not settled.
    package private(set) var settling: UInt32?
    /// Reveals sent for `target`.
    private var reveals = 0
    /// Calls asked of a spent snapshot, sent again.
    private var stale = 0
    /// Pages asked for since the last frame took them.
    private var page: Page?
    /// The page a frame carries and has not answered, and the request it
    /// went as; only its answer touches it.
    private var paging: Flight?

    /// A page in flight and the request it went as.
    private struct Flight: Equatable, Sendable {
        let page: Page
        let request: NuxieMachineScrollRequest
    }

    /// A page asked for and not yet sent: from which node, which way, and
    /// how many.
    private struct Page: Equatable, Sendable {
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
    /// for it, or moving and not settled.
    package func revealPending(for node: UInt32) -> Bool {
        target == node || settling == node
    }

    /// One more page `direction` from `node`; pages asked before a frame
    /// takes them add up.
    package mutating func page(_ direction: NuxieMachineScrollDirection, from node: UInt32) {
        if var waiting = page, waiting.direction == direction {
            waiting.count += 1
            page = waiting
        } else {
            page = Page(node: node, direction: direction, count: 1)
        }
    }

    /// Whether anything waits for a frame: something to send or a settle to
    /// see.
    package var wantsFrames: Bool {
        target != nil || heldTap != nil || settling != nil || page != nil || paging != nil
    }

    /// What the coming frame carries, asked of `capture`, the snapshot on
    /// screen, after a frame whose step was `settled` or not: a page, a
    /// reveal, and a tap that waited.
    package mutating func take(_ capture: NuxieNativeSemanticCapture?, settled: Bool)
        -> (scrolls: [NuxieMachineScrollRequest], tap: NuxieMachineSemanticTap?) {
        guard let capture else { return ([], nil) }
        var scrolls: [NuxieMachineScrollRequest] = []
        var tap: NuxieMachineSemanticTap?
        let nodes = capture.tree.nodes
        if let waiting = page {
            page = nil
            if let node = nodes.first(where: { $0.id == waiting.node }),
               let move = NuxieMachineScreenReaderScroll.page(waiting.direction, from: node, in: capture.scrollRegions) {
                let request = NuxieMachineScrollRequest.page(captureID: capture.id, region: move.region,
                                                             dx: move.dx * Float(waiting.count),
                                                             dy: move.dy * Float(waiting.count))
                scrolls.append(request)
                paging = Flight(page: waiting, request: request)
            }
        }
        guard settled, settling == nil else { return (scrolls, nil) }
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
    /// came of each request, and `settled` whether its step reported itself
    /// settled.
    package mutating func ended(_ scrolled: [NuxieMachineScrolled], settled: Bool) {
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
            case .page:
                // Only the page this answers leaves flight; pages asked
                // since stay queued for the next frame. A stale one is asked
                // again, ahead of later pages its way; a later page the other
                // way replaces it, being what was asked last.
                guard let flying = paging, flying.request == result.request else { continue }
                paging = nil
                guard result.outcome == .stale, flying.page.stale < Self.staleRetries else { continue }
                var again = flying.page
                again.stale += 1
                if let queued = page {
                    guard queued.direction == again.direction else { continue }
                    again.count += queued.count
                }
                page = again
            }
        }
        if settled { settling = nil }
    }
}
