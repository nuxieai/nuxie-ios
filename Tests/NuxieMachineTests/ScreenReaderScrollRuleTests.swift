#if os(iOS) && !targetEnvironment(macCatalyst)
import CoreGraphics
import Foundation
import UIKit
import XCTest
import NuxieMachine
import NuxieRuntime

/// How a machine component's `scroll`s answer a screen reader, checked as
/// pure functions of a capture with no engine: a region's position read by
/// the size the runtime answered, which nodes have elements and where, when
/// a reveal goes and how often, a tap that waits behind one, a page, when a
/// Screen is at rest, and each row of the table at the top of
/// `NuxieMachineScreenReaderScroll.swift`.
/// The engine's side is checked on Stillwater in
/// [`ScreenReaderScrollingTests`].
@MainActor
final class ScreenReaderScrollRuleTests: XCTestCase {
    private static let surface = CGRect(x: 0, y: 0, width: 390, height: 844)
    private static let tap: UInt32 = 1 << NuxieNativeSemanticAction.tap.rawValue
    private static let top = NuxieNativeScrollRegion.towardTop
    private static let bottom = NuxieNativeScrollRegion.towardBottom
    private static let left = NuxieNativeScrollRegion.towardLeft
    private static let right = NuxieNativeScrollRegion.towardRight

    // MARK: The wrapper

    /// A region's position and range are read only from an answer that
    /// covers all four fields: 48 bytes. A runtime older than them answers
    /// 32 and leaves them alone, so whatever the struct holds there is not
    /// read.
    func testARegionsPositionIsReadOnlyWhenTheAnswerCoversIt() throws {
        XCTAssertEqual(NuxieNativeScrollRegion.positionSize, 48)
        XCTAssertNil(NuxieNativeScrollRegion.position(answeredSize: 32, scrollX: 7, scrollY: 8, rangeX: 9, rangeY: 10))
        XCTAssertNil(NuxieNativeScrollRegion.position(answeredSize: 44, scrollX: 7, scrollY: 8, rangeX: 9, rangeY: 10),
                     "an answer that stops short of the last field fills none")
        let read = try XCTUnwrap(NuxieNativeScrollRegion.position(answeredSize: 48, scrollX: 0, scrollY: 120,
                                                                  rangeX: 0, rangeY: 316))
        XCTAssertEqual(read.scroll, CGPoint(x: 0, y: 120))
        XCTAssertEqual(read.range, CGSize(width: 0, height: 316))
        XCTAssertNotNil(NuxieNativeScrollRegion.position(answeredSize: 64, scrollX: 0, scrollY: 0, rangeX: 0,
                                                         rangeY: 0), "a newer runtime's larger answer covers them")
    }

    // MARK: Elements

    /// A node a `scroll` moved off the surface keeps an element, at its own
    /// box off the surface; one under no `scroll` drawn nowhere on the
    /// surface still has none. A node on the surface stands where it is
    /// drawn on it, cut to the surface.
    func testANodeOutOfViewWithARegionKeepsItsOwnFrameAndOneWithoutHasNone() throws {
        let below = CGRect(x: 24, y: 900, width: 160, height: 44)
        let out = try XCTUnwrap(project(node(1, below, region: 0)), "a node scrolled out of view has an element")
        XCTAssertEqual(out.frame, below, "its frame is its own box, below the surface")
        XCTAssertNil(project(node(2, below, region: nil)), "a node under no scroll drawn off the surface has none")
        let across = CGRect(x: 24, y: 820, width: 160, height: 44)
        XCTAssertEqual(project(node(3, across, region: 0))?.frame,
                       CGRect(x: 24, y: 820, width: 160, height: 24), "a node partly on the surface is cut to it")
    }

    /// A button inside a `scroll` takes an activation though the engine
    /// offers it no tap while it is clipped away: the activation waits for
    /// its reveal. A disabled one does not, nor one outside any `scroll`
    /// that offers no tap.
    func testAButtonInAScrollTakesAnActivationUnlessItIsDisabled() throws {
        let below = CGRect(x: 24, y: 900, width: 160, height: 44)
        XCTAssertEqual(project(node(1, below, region: 0, actions: 0))?.actions, Self.tap)
        XCTAssertEqual(project(node(2, below, region: 0, actions: 0, flags: NuxieNativeSemanticNode.disabled))?.actions,
                       0)
        let shown = CGRect(x: 24, y: 400, width: 160, height: 44)
        XCTAssertEqual(project(node(3, shown, region: nil, actions: 0))?.actions, 0)
        XCTAssertEqual(project(node(4, shown, region: nil, actions: Self.tap))?.actions, Self.tap)
        XCTAssertEqual(project(node(5, below, region: 0, actions: 0, role: .text))?.actions, 0, "text takes no tap")
    }

    // MARK: At rest

    /// A step that reports itself settled is at rest. One that does not is
    /// at rest after `stillFrames` drawn frames in a row that change
    /// nothing, which takes `stillFrames + 1` frames: three, at half a
    /// point.
    func testASettledStepIsAtRestAndAnUnsettledOneAfterThreeStillFrames() {
        let rule = NuxieMachineScreenReaderScroll.self
        XCTAssertEqual(rule.stillFrames, 3)
        XCTAssertEqual(rule.stillDistance, 0.5)
        let still = NuxieMachineRestSample(positions: [CGPoint(x: 0, y: 120)], node: 1,
                                           box: CGRect(x: 24, y: 400, width: 160, height: 44))
        XCTAssertTrue(rule.isAtRest(settled: true, frames: []), "settled is at rest, seen or not")
        XCTAssertFalse(rule.isAtRest(settled: false, frames: []))
        XCTAssertFalse(rule.isAtRest(settled: false, frames: Array(repeating: still, count: rule.stillFrames)),
                       "three frames are two still frames")
        XCTAssertTrue(rule.isAtRest(settled: false, frames: Array(repeating: still, count: rule.stillFrames + 1)))
        let moving = NuxieMachineRestSample(positions: [CGPoint(x: 0, y: 120)], node: 1,
                                            box: CGRect(x: 24, y: 410, width: 160, height: 44))
        XCTAssertTrue(rule.isAtRest(settled: false, frames: [moving] + Array(repeating: still, count: 4)),
                      "only the last frames count")
        XCTAssertFalse(rule.isAtRest(settled: false, frames: Array(repeating: still, count: 3) + [moving]))
    }

    /// A scroller still moving never counts as at rest, however long it
    /// moves: its node's box changes every frame, by more than half a point
    /// at an edge, while the region's position already reads where it is
    /// going.
    func testAScrollerStillMovingIsNeverAtRest() {
        let rule = NuxieMachineScreenReaderScroll.self
        var frames: [NuxieMachineRestSample] = []
        for index in 0..<2000 {
            // Easing toward its stop and never reaching it: each frame moves
            // at least 0.6 points, more at first.
            let travelled = CGFloat(index) * 0.6 + 400 * (1 - pow(0.9, CGFloat(index)))
            frames.append(NuxieMachineRestSample(positions: [CGPoint(x: 0, y: 1592)], node: 7,
                                                 box: CGRect(x: 24, y: 2400 - travelled, width: 160, height: 44)))
            XCTAssertFalse(rule.isAtRest(settled: false, frames: frames), "frame \(index) is moving")
        }
        frames = []
        for index in 0..<2000 {
            frames.append(NuxieMachineRestSample(positions: [CGPoint(x: 0, y: CGFloat(index))], node: 7,
                                                 box: CGRect(x: 24, y: 400, width: 160, height: 44)))
            XCTAssertFalse(rule.isAtRest(settled: false, frames: frames), "the region's position moves")
        }
        frames = []
        for index in 0..<2000 {
            // A box that grows at one edge only moves.
            frames.append(NuxieMachineRestSample(positions: [CGPoint(x: 0, y: 0)], node: 7,
                                                 box: CGRect(x: 24, y: 400, width: 160, height: 44 + CGFloat(index))))
            XCTAssertFalse(rule.isAtRest(settled: false, frames: frames), "the box's bottom moves")
        }
    }

    /// Any change between two of the last frames breaks the run: a
    /// region's position, a region more or fewer, another node waited on,
    /// a box that appears or goes, or one that moves half a point or more
    /// at an edge, from one frame to the next or across the run, or is not
    /// a number. Less than half a point is still, and a box the same
    /// exactly, a placeholder's included.
    func testAChangeBetweenTwoOfTheLastFramesIsNotRest() {
        let rule = NuxieMachineScreenReaderScroll.self
        let box = CGRect(x: 24, y: 400, width: 160, height: 44)
        func sample(_ positions: [CGPoint?] = [.zero], node: UInt32? = 1, box: CGRect? = box) -> NuxieMachineRestSample {
            NuxieMachineRestSample(positions: positions, node: node, box: box)
        }
        func rests(_ last: NuxieMachineRestSample) -> Bool {
            rule.isAtRest(settled: false, frames: Array(repeating: sample(), count: 3) + [last])
        }
        XCTAssertFalse(rests(sample([CGPoint(x: 0, y: 1)])), "a position")
        XCTAssertFalse(rests(sample([.zero, .zero])), "a region more")
        XCTAssertFalse(rests(sample([nil])), "a position no longer read")
        XCTAssertFalse(rests(sample(node: 2)), "another node")
        XCTAssertFalse(rests(sample(node: nil, box: nil)), "no node")
        XCTAssertFalse(rests(sample(box: nil)), "a box that went")
        XCTAssertFalse(rests(sample(box: box.offsetBy(dx: 0, dy: 0.5))), "half a point")
        XCTAssertFalse(rests(sample(box: box.offsetBy(dx: -0.5, dy: 0))), "half a point sideways")
        XCTAssertFalse(rests(sample(box: CGRect(x: 24, y: CGFloat.nan, width: 160, height: 44))), "not a number")
        XCTAssertTrue(rests(sample(box: box.offsetBy(dx: 0.3, dy: -0.49))), "less than half a point")
        let creeping = (0...3).map { sample(box: box.offsetBy(dx: 0, dy: -0.3 * CGFloat($0))) }
        XCTAssertFalse(rule.isAtRest(settled: false, frames: creeping),
                       "0.3 points a frame is 0.9 across the run: an ease's tail is still moving")
        let settling = (0...3).map { sample(box: box.offsetBy(dx: 0, dy: -0.15 * CGFloat($0))) }
        XCTAssertTrue(rule.isAtRest(settled: false, frames: settling), "0.45 across the run")
        let placeholder = CGRect(x: CGFloat(Float.greatestFiniteMagnitude), y: CGFloat(Float.greatestFiniteMagnitude),
                                 width: -CGFloat.infinity, height: -CGFloat.infinity)
        XCTAssertTrue(rule.isAtRest(settled: false, frames: Array(repeating: sample(box: placeholder), count: 4)),
                      "a box the same exactly")
        XCTAssertFalse(rule.isAtRest(settled: false, frames: Array(repeating: sample(node: nil, box: nil), count: 4)),
                       "nothing waited on: positions read where a region is going, so only a settled step is rest")
        XCTAssertTrue(rule.isAtRest(settled: true, frames: Array(repeating: sample(node: nil, box: nil), count: 4)))
    }

    /// A focus right after a page moved waits a whole run of still frames
    /// of the newly focused node before its reveal goes, and still frames
    /// with nothing waited on, however many, are not rest.
    func testAFocusRightAfterAPageMovedWaitsAWholeRunOnTheNewNode() throws {
        let capture = try Self.capture([node(1, CGRect(x: 24, y: 400, width: 160, height: 44)), node(5, Self.below(0))],
                                       regions: [Self.page()])
        var scrolling = NuxieMachineScreenReaderScrolling()
        for _ in 0..<10 { scrolling.ended([], settled: false, drawn: capture) }
        XCTAssertFalse(scrolling.atRest, "frames with nothing waited on do not count")
        scrolling.page(.showBelow, from: 1, region: 0)
        let paged = NuxieMachineScrollRequest.page(captureID: capture.id, region: 0, dx: 0, dy: -796)
        XCTAssertEqual(scrolling.take(capture).scrolls, [paged])
        scrolling.ended([NuxieMachineScrolled(paged, .moved)], settled: false, drawn: capture)
        scrolling.focus(5)
        for frame in 0...NuxieMachineScreenReaderScroll.stillFrames {
            XCTAssertEqual(scrolling.take(capture).scrolls, [], "frame \(frame) of the run on node 5")
            scrolling.ended([], settled: false, drawn: capture)
        }
        XCTAssertTrue(scrolling.atRest)
        XCTAssertEqual(scrolling.take(capture).scrolls, [.reveal(captureID: capture.id, nodeID: 5)],
                       "after a whole run of still frames of node 5")
    }

    /// Rest seen for one node is not rest for another: focus moving to a
    /// new node starts the run over, and a settled step is rest whatever
    /// waits.
    func testRestForOneNodeIsNotRestForAnother() throws {
        let capture = try Self.capture([node(5, Self.below(0)), node(6, Self.below(100))], regions: [Self.page()])
        var scrolling = NuxieMachineScreenReaderScrolling()
        scrolling.focus(5)
        for _ in 0...NuxieMachineScreenReaderScroll.stillFrames {
            scrolling.ended([], settled: false, drawn: capture)
        }
        XCTAssertTrue(scrolling.atRest, "a run of still frames of node 5")
        scrolling.focus(6)
        XCTAssertFalse(scrolling.atRest, "is not rest for node 6")
        XCTAssertEqual(scrolling.take(capture).scrolls, [])
        for _ in 0...NuxieMachineScreenReaderScroll.stillFrames {
            XCTAssertEqual(scrolling.take(capture).scrolls, [])
            scrolling.ended([], settled: false, drawn: capture)
        }
        XCTAssertEqual(scrolling.take(capture).scrolls, [.reveal(captureID: capture.id, nodeID: 6)])
        var settled = NuxieMachineScreenReaderScrolling()
        settled.ended([], settled: true, drawn: capture)
        settled.focus(5)
        XCTAssertTrue(settled.atRest, "a settled step is rest whatever waits")
        XCTAssertEqual(settled.take(capture).scrolls, [.reveal(captureID: capture.id, nodeID: 5)])
    }

    // MARK: Reveals

    /// A reveal goes only at rest, and only for the latest node focus
    /// reached: a move made while one settles would overshoot.
    func testARevealWaitsForRestAndOnlyTheLatestFocusIsRevealed() throws {
        let capture = try Self.capture([node(1, Self.below(0)), node(2, Self.below(100))], regions: [Self.page()])
        var scrolling = NuxieMachineScreenReaderScrolling()
        scrolling.focus(1)
        XCTAssertEqual(scrolling.take(capture).scrolls, [], "nothing goes before a frame is seen at rest")
        scrolling.ended([], settled: false, drawn: capture)
        XCTAssertEqual(scrolling.take(capture).scrolls, [], "nor while the frame is unsettled")
        scrolling.focus(2)
        scrolling.ended([], settled: true, drawn: capture)
        XCTAssertEqual(scrolling.take(capture).scrolls, [.reveal(captureID: capture.id, nodeID: 2)],
                       "the latest focus is revealed at rest")
        scrolling.ended([NuxieMachineScrolled(.reveal(captureID: capture.id, nodeID: 2), .moved)], settled: false,
                        drawn: capture)
        XCTAssertEqual(scrolling.settling, 2)
        scrolling.focus(1)
        XCTAssertEqual(scrolling.take(capture).scrolls, [],
                       "a reveal that moved and has not been seen at rest holds the next")
        scrolling.ended([], settled: true, drawn: capture)
        XCTAssertNil(scrolling.settling)
        XCTAssertEqual(scrolling.take(capture).scrolls, [.reveal(captureID: capture.id, nodeID: 1)])
    }

    /// A node already whole inside its `scroll` is not revealed, and one
    /// under no `scroll` neither.
    func testANodeThatShowsIsNotRevealed() throws {
        let capture = try Self.capture([node(1, CGRect(x: 24, y: 400, width: 160, height: 44)),
                                        node(2, Self.below(0), region: nil)], regions: [Self.page()])
        var scrolling = NuxieMachineScreenReaderScrolling()
        scrolling.ended([], settled: true, drawn: capture)
        scrolling.focus(1)
        XCTAssertEqual(scrolling.take(capture).scrolls, [])
        XCTAssertNil(scrolling.target, "nothing waits")
        scrolling.focus(2)
        XCTAssertEqual(scrolling.take(capture).scrolls, [])
        XCTAssertFalse(scrolling.wantsFrames)
    }

    /// Once a reveal is at rest, a node still not whole inside its regions
    /// is revealed again, at most as many times in all as it has regions
    /// around it: twice for a node in a `scroll` inside a `scroll`, once
    /// for a node in one.
    func testANodeStillNotWholeAfterARevealIsRevealedAgainUpToItsNesting() throws {
        let outer = Self.page()
        let inner = NuxieNativeScrollRegion(bounds: CGRect(x: 0, y: 600, width: 390, height: 200),
                                            canScroll: Self.bottom, parent: 0)
        let capture = try Self.capture([node(1, Self.below(0), region: 1), node(2, Self.below(0), region: 0)],
                                       regions: [outer, inner])
        var scrolling = NuxieMachineScreenReaderScrolling()
        scrolling.ended([], settled: true, drawn: capture)
        scrolling.focus(1)
        for round in 1...2 {
            XCTAssertEqual(scrolling.take(capture).scrolls, [.reveal(captureID: capture.id, nodeID: 1)],
                           "reveal \(round) of a node in two regions")
            scrolling.ended([NuxieMachineScrolled(.reveal(captureID: capture.id, nodeID: 1), .moved)],
                            settled: false, drawn: capture)
            scrolling.ended([], settled: true, drawn: capture)
        }
        XCTAssertEqual(scrolling.take(capture).scrolls, [], "no third reveal")
        XCTAssertNil(scrolling.target)

        scrolling.focus(2)
        XCTAssertEqual(scrolling.take(capture).scrolls, [.reveal(captureID: capture.id, nodeID: 2)])
        scrolling.ended([NuxieMachineScrolled(.reveal(captureID: capture.id, nodeID: 2), .stayed)], settled: true,
                        drawn: capture)
        XCTAssertEqual(scrolling.take(capture).scrolls, [], "one region, one reveal")
        XCTAssertFalse(scrolling.wantsFrames)
    }

    /// A reveal asked of a snapshot an earlier call in its frame spent is
    /// asked again of the next, a bounded number of times, and does not
    /// count against the node's reveals.
    func testARevealAskedOfASpentSnapshotIsAskedAgainABoundedNumberOfTimes() throws {
        let capture = try Self.capture([node(1, Self.below(0))], regions: [Self.page()])
        var scrolling = NuxieMachineScreenReaderScrolling()
        scrolling.ended([], settled: true, drawn: capture)
        scrolling.focus(1)
        for attempt in 0...NuxieMachineScreenReaderScrolling.staleRetries {
            XCTAssertEqual(scrolling.take(capture).scrolls, [.reveal(captureID: capture.id, nodeID: 1)],
                           "attempt \(attempt)")
            scrolling.ended([NuxieMachineScrolled(.reveal(captureID: capture.id, nodeID: 1), .stale)],
                            settled: true, drawn: capture)
        }
        XCTAssertEqual(scrolling.take(capture).scrolls, [], "let go after the retries")
        XCTAssertFalse(scrolling.wantsFrames)
    }

    /// A reveal and a tap behind it wait however long the page takes to
    /// come to rest, and go in the first frame after it does.
    func testARevealWaitsForRestHoweverLongItTakes() throws {
        var scrolling = NuxieMachineScreenReaderScrolling()
        scrolling.focus(1)
        _ = scrolling.hold(tap: 1)
        var last: NuxieNativeSemanticCapture?
        for index in 0..<1000 {
            // The node is drawn a point higher each frame: something moves it.
            let capture = try Self.capture([node(1, Self.below(CGFloat(1000 - index)), actions: 0)],
                                           regions: [Self.page()])
            scrolling.ended([], settled: false, drawn: capture)
            XCTAssertEqual(scrolling.take(capture).scrolls, [])
            last = capture
        }
        XCTAssertTrue(scrolling.wantsFrames)
        XCTAssertEqual(scrolling.heldTap, 1)
        let capture = try XCTUnwrap(last)
        scrolling.ended([], settled: true, drawn: capture)
        XCTAssertEqual(scrolling.take(capture).scrolls, [.reveal(captureID: capture.id, nodeID: 1)])
    }

    /// Each input to a reveal waiting or moving, cell by cell of the table
    /// at the top of `NuxieMachineScreenReaderScroll.swift`.
    func testTheRevealRow() throws {
        let capture = try Self.capture([node(1, Self.below(0)), node(2, Self.below(100))], regions: [Self.page()])
        let one = NuxieMachineScrollRequest.reveal(captureID: capture.id, nodeID: 1)
        let two = NuxieMachineScrollRequest.reveal(captureID: capture.id, nodeID: 2)
        var scrolling = NuxieMachineScreenReaderScrolling()
        scrolling.ended([], settled: true, drawn: capture)

        // Another node asked: it replaces the first.
        scrolling.focus(1)
        scrolling.focus(2)
        XCTAssertEqual(scrolling.take(capture).scrolls, [two], "another node: the latest focus")

        // Frame not drawn: not at rest, so a moving reveal stays moving and
        // no reveal goes, even when the step reports itself settled.
        scrolling.ended([NuxieMachineScrolled(two, .moved)], settled: false, drawn: nil)
        XCTAssertEqual(scrolling.settling, 2, "answer moved: it waits for rest")
        scrolling.ended([], settled: true, drawn: nil)
        XCTAssertFalse(scrolling.atRest, "frame not drawn: not at rest")
        XCTAssertEqual(scrolling.settling, 2, "frame not drawn: one moving stays moving")
        scrolling.focus(1)
        XCTAssertEqual(scrolling.take(capture).scrolls, [], "frame not drawn: no reveal goes")
        scrolling.ended([], settled: true, drawn: capture)
        XCTAssertNil(scrolling.settling, "a drawn frame at rest lets it go")
        XCTAssertEqual(scrolling.take(capture).scrolls, [one])

        // Answer stayed: checked at the next rest; a node still not whole
        // in one region has had its one reveal.
        scrolling.ended([NuxieMachineScrolled(one, .stayed)], settled: true, drawn: capture)
        XCTAssertEqual(scrolling.target, 1, "answer stayed: checked again at the next take")
        XCTAssertEqual(scrolling.take(capture).scrolls, [], "and let go: one region, one reveal")
        XCTAssertNil(scrolling.target)
        let shown = try Self.capture([node(1, CGRect(x: 24, y: 400, width: 160, height: 44))], regions: [Self.page()])
        scrolling.focus(2)
        XCTAssertEqual(scrolling.take(capture).scrolls, [two])
        scrolling.ended([NuxieMachineScrolled(two, .stayed)], settled: true, drawn: capture)
        scrolling.focus(1)
        XCTAssertEqual(scrolling.take(shown).scrolls, [], "answer stayed, the node shows whole: let go")
        XCTAssertNil(scrolling.target)

        // Answer refused: let go. An earlier node's answer: nothing.
        scrolling.focus(1)
        XCTAssertEqual(scrolling.take(capture).scrolls, [one])
        scrolling.focus(2)
        scrolling.ended([NuxieMachineScrolled(one, .refused)], settled: true, drawn: capture)
        scrolling.ended([NuxieMachineScrolled(one, .stale)], settled: true, drawn: capture)
        XCTAssertEqual(scrolling.target, 2, "an earlier node's answer leaves the later focus")
        XCTAssertEqual(scrolling.take(capture).scrolls, [two])
        scrolling.ended([NuxieMachineScrolled(two, .refused)], settled: true, drawn: capture)
        XCTAssertNil(scrolling.target, "answer refused: let go")

        // Answer stale: sent again (bounded: see the spent-snapshot test).
        scrolling.focus(1)
        XCTAssertEqual(scrolling.take(capture).scrolls, [one])
        scrolling.ended([NuxieMachineScrolled(one, .stale)], settled: true, drawn: capture)
        XCTAssertEqual(scrolling.take(capture).scrolls, [one], "answer stale: sent again")
        scrolling.ended([NuxieMachineScrolled(one, .moved)], settled: true, drawn: capture)

        // A node under no `scroll` focused: let go. Focus leaving another
        // node: nothing. Focus leaving its node: let go.
        scrolling.focus(2)
        scrolling.focusOutside()
        XCTAssertNil(scrolling.target, "a node under no scroll focused: let go")
        XCTAssertEqual(scrolling.take(capture).scrolls, [])
        scrolling.focus(2)
        scrolling.focusLeft(1)
        XCTAssertEqual(scrolling.target, 2, "focus leaving another node: nothing")
        scrolling.focusLeft(2)
        XCTAssertNil(scrolling.target, "focus leaving its node: let go")
        XCTAssertEqual(scrolling.take(capture).scrolls, [])

        // A page goes in the frame: no reveal goes with it, and the page's
        // move starts the still frames over.
        let pageable = try Self.capture([node(1, Self.below(0)), node(3, CGRect(x: 24, y: 400, width: 160, height: 44))],
                                        regions: [Self.page()])
        scrolling.ended([], settled: true, drawn: pageable)
        scrolling.focus(1)
        scrolling.page(.showBelow, from: 3, region: 0)
        let paged = NuxieMachineScrollRequest.page(captureID: pageable.id, region: 0, dx: 0, dy: -796)
        XCTAssertEqual(scrolling.take(pageable).scrolls, [paged], "a page goes in the frame: no reveal with it")
        scrolling.ended([NuxieMachineScrolled(paged, .moved)], settled: false, drawn: pageable)
        XCTAssertFalse(scrolling.atRest, "the page's move starts the still frames over")
        scrolling.ended([], settled: true, drawn: pageable)
        XCTAssertEqual(scrolling.take(pageable).scrolls, [.reveal(captureID: pageable.id, nodeID: 1)])
        scrolling.ended([NuxieMachineScrolled(.reveal(captureID: pageable.id, nodeID: 1), .moved)], settled: true,
                        drawn: capture)

        // The capture loses the node: let go at the next take.
        let without = try Self.capture([node(2, Self.below(100))], regions: [Self.page()])
        scrolling.focus(2)
        scrolling.focus(1)
        XCTAssertEqual(scrolling.take(without).scrolls, [], "the capture lost the node")
        XCTAssertNil(scrolling.target, "let go")
        XCTAssertFalse(scrolling.wantsFrames)
    }

    // MARK: A tap behind a reveal

    /// A tap on a node being revealed waits behind the reveal and goes in
    /// the first frame at rest after, asked of that frame's snapshot, once
    /// the node offers a tap. One tap waits at a time.
    func testATapWaitsBehindItsRevealAndGoesOnceTheNodeOffersOne() throws {
        let before = try Self.capture([node(1, Self.below(0), actions: 0)], regions: [Self.page()])
        var scrolling = NuxieMachineScreenReaderScrolling()
        scrolling.ended([], settled: true, drawn: before)
        XCTAssertTrue(scrolling.hold(tap: 1), "a tap on a node out of view waits")
        XCTAssertFalse(scrolling.hold(tap: 1), "a second waits for none")
        XCTAssertTrue(scrolling.revealPending(for: 1), "holding a tap asks for its node's reveal")
        var taken = scrolling.take(before)
        XCTAssertEqual(taken.scrolls, [.reveal(captureID: before.id, nodeID: 1)])
        XCTAssertNil(taken.tap, "the tap does not go with the reveal")
        scrolling.ended([NuxieMachineScrolled(.reveal(captureID: before.id, nodeID: 1), .moved)], settled: false,
                        drawn: before)
        XCTAssertTrue(scrolling.revealPending(for: 1), "still pending while it moves")
        taken = scrolling.take(before)
        XCTAssertEqual(taken.scrolls, [])
        XCTAssertNil(taken.tap, "nor while it moves")
        let after = try Self.capture([node(1, CGRect(x: 24, y: 700, width: 160, height: 44), actions: Self.tap)],
                                     regions: [Self.page()])
        scrolling.ended([], settled: true, drawn: after)
        taken = scrolling.take(after)
        XCTAssertEqual(taken.scrolls, [])
        XCTAssertEqual(taken.tap, NuxieMachineSemanticTap(captureID: after.id, nodeID: 1),
                       "the tap goes at rest, asked of the snapshot shown then")
        XCTAssertNil(scrolling.heldTap)
        XCTAssertFalse(scrolling.wantsFrames)
    }

    /// A tap that waited for a node that still offers none once the reveal
    /// is done goes nowhere: the engine would refuse it.
    func testATapThatWaitedForANodeThatStillOffersNoneIsDropped() throws {
        let capture = try Self.capture([node(1, Self.below(0), actions: 0)], regions: [Self.page()])
        var scrolling = NuxieMachineScreenReaderScrolling()
        scrolling.ended([], settled: true, drawn: capture)
        _ = scrolling.hold(tap: 1)
        _ = scrolling.take(capture)
        let shown = try Self.capture([node(1, CGRect(x: 24, y: 400, width: 160, height: 44), actions: 0)],
                                     regions: [Self.page()])
        scrolling.ended([NuxieMachineScrolled(.reveal(captureID: capture.id, nodeID: 1), .stayed)], settled: true,
                        drawn: shown)
        let taken = scrolling.take(shown)
        XCTAssertNil(taken.tap)
        XCTAssertFalse(scrolling.wantsFrames)
    }

    /// Each input to a held tap, cell by cell of the table at the top of
    /// `NuxieMachineScreenReaderScroll.swift`.
    func testTheHeldTapRow() throws {
        let out = try Self.capture([node(1, Self.below(0), actions: 0), node(2, Self.below(100), actions: 0)],
                                   regions: [Self.page()])
        let inView = try Self.capture([node(1, CGRect(x: 24, y: 400, width: 160, height: 44), actions: Self.tap),
                                       node(2, CGRect(x: 24, y: 500, width: 160, height: 44), actions: Self.tap)],
                                      regions: [Self.page()])
        var scrolling = NuxieMachineScreenReaderScrolling()
        scrolling.ended([], settled: true, drawn: out)

        // Same node tapped again: false. Another node: replaces it, and is
        // the node revealed.
        XCTAssertTrue(scrolling.hold(tap: 1))
        XCTAssertFalse(scrolling.hold(tap: 1), "same node: one tap waits")
        XCTAssertTrue(scrolling.hold(tap: 2), "another node")
        XCTAssertEqual(scrolling.heldTap, 2, "replaces it")
        XCTAssertTrue(scrolling.revealPending(for: 2), "and its node is the one revealed")
        XCTAssertFalse(scrolling.revealPending(for: 1))

        // Frame not drawn: it does not go, though the node offers a tap.
        scrolling.ended([], settled: true, drawn: nil)
        var taken = scrolling.take(inView)
        XCTAssertNil(taken.tap, "frame not drawn: the tap does not go")
        XCTAssertEqual(taken.scrolls, [])
        XCTAssertEqual(scrolling.heldTap, 2)

        // Its reveal moved: waits for rest; then goes, its node offering one.
        scrolling.ended([], settled: true, drawn: out)
        taken = scrolling.take(out)
        XCTAssertEqual(taken.scrolls, [.reveal(captureID: out.id, nodeID: 2)])
        scrolling.ended([NuxieMachineScrolled(.reveal(captureID: out.id, nodeID: 2), .moved)], settled: false,
                        drawn: inView)
        XCTAssertNil(scrolling.take(inView).tap, "its reveal moved: waits for rest")
        scrolling.ended([], settled: true, drawn: inView)
        XCTAssertEqual(scrolling.take(inView).tap, NuxieMachineSemanticTap(captureID: inView.id, nodeID: 2))

        // Its reveal refused: goes at the next rest if its node offers a tap.
        XCTAssertTrue(scrolling.hold(tap: 1))
        XCTAssertEqual(scrolling.take(out).scrolls, [.reveal(captureID: out.id, nodeID: 1)])
        scrolling.ended([NuxieMachineScrolled(.reveal(captureID: out.id, nodeID: 1), .refused)], settled: true,
                        drawn: inView)
        XCTAssertEqual(scrolling.take(inView).tap, NuxieMachineSemanticTap(captureID: inView.id, nodeID: 1),
                       "its reveal refused, the node offers a tap: it goes")
        XCTAssertTrue(scrolling.hold(tap: 1))
        XCTAssertEqual(scrolling.take(out).scrolls, [.reveal(captureID: out.id, nodeID: 1)])
        scrolling.ended([NuxieMachineScrolled(.reveal(captureID: out.id, nodeID: 1), .refused)], settled: true,
                        drawn: out)
        XCTAssertNil(scrolling.take(out).tap, "its reveal refused, the node offers none: dropped")
        XCTAssertNil(scrolling.heldTap)

        // Focus moves to another node in a `scroll`: the held tap's node is
        // revealed and tapped first, the focused node revealed after.
        XCTAssertTrue(scrolling.hold(tap: 1))
        scrolling.focus(2)
        XCTAssertEqual(scrolling.take(out).scrolls, [.reveal(captureID: out.id, nodeID: 1)],
                       "focus moved on: the tap's node is revealed first")
        scrolling.ended([NuxieMachineScrolled(.reveal(captureID: out.id, nodeID: 1), .moved)], settled: true,
                        drawn: inView)
        XCTAssertEqual(scrolling.take(inView).tap, NuxieMachineSemanticTap(captureID: inView.id, nodeID: 1),
                       "and the tap goes")
        XCTAssertEqual(scrolling.target, 2, "the focused node waits its turn")
        scrolling.ended([], settled: true, drawn: out)
        XCTAssertEqual(scrolling.take(out).scrolls, [.reveal(captureID: out.id, nodeID: 2)], "then it is revealed")
        scrolling.ended([NuxieMachineScrolled(.reveal(captureID: out.id, nodeID: 2), .moved)], settled: true,
                        drawn: inView)
        _ = scrolling.take(inView)

        // Focus moves to a node under no `scroll`, or leaves the node: the
        // tap still goes.
        XCTAssertTrue(scrolling.hold(tap: 1))
        scrolling.focusOutside()
        scrolling.focusLeft(1)
        XCTAssertEqual(scrolling.heldTap, 1, "focus moving away keeps the tap")
        XCTAssertEqual(scrolling.take(out).scrolls, [.reveal(captureID: out.id, nodeID: 1)])
        scrolling.ended([NuxieMachineScrolled(.reveal(captureID: out.id, nodeID: 1), .moved)], settled: true,
                        drawn: inView)
        XCTAssertEqual(scrolling.take(inView).tap, NuxieMachineSemanticTap(captureID: inView.id, nodeID: 1),
                       "and it goes")

        // A page goes in the frame: the tap waits for the next rest.
        let pageable = try Self.capture([node(1, CGRect(x: 24, y: 400, width: 160, height: 44), actions: Self.tap)],
                                        regions: [NuxieNativeScrollRegion(bounds: Self.surface, canScroll: Self.bottom,
                                                                          parent: nil)])
        XCTAssertTrue(scrolling.hold(tap: 1))
        scrolling.page(.showBelow, from: 1, region: 0)
        let paged = scrolling.take(pageable)
        XCTAssertEqual(paged.scrolls.count, 1, "the page goes")
        XCTAssertNil(paged.tap, "a page goes in the frame: the tap does not")
        scrolling.ended([NuxieMachineScrolled(paged.scrolls[0], .moved)], settled: true, drawn: pageable)
        XCTAssertEqual(scrolling.take(pageable).tap?.nodeID, 1, "it goes at the next rest")

        // The capture loses the node: dropped.
        let without = try Self.capture([node(2, Self.below(100), actions: Self.tap)], regions: [Self.page()])
        XCTAssertTrue(scrolling.hold(tap: 1))
        scrolling.ended([], settled: true, drawn: without)
        XCTAssertNil(scrolling.take(without).tap, "the capture lost the node: dropped")
        XCTAssertNil(scrolling.heldTap)
        XCTAssertFalse(scrolling.wantsFrames)
    }

    // MARK: Pages

    /// One page is what the box shows less 48 points, at least half of it
    /// and at least a point.
    func testAPageIsTheBoxLess48PointsAtLeastHalfOfIt() {
        XCTAssertEqual(NuxieMachineScreenReaderScroll.pageStep(844), 796)
        XCTAssertEqual(NuxieMachineScreenReaderScroll.pageStep(60), 30)
        XCTAssertEqual(NuxieMachineScreenReaderScroll.pageStep(0.5), 1)
    }

    /// The page line counts in page steps, so each page moved reaches the
    /// next: a box 844 points long steps 796, and a range of two whole
    /// steps reads page 1 of 3 at its top, 2 of 3 one step down and 3 of 3
    /// at its end. A range that is not a whole number of steps ends on a
    /// short last stop, and the stop before it is not the last page.
    func testThePageLineCountsInPageSteps() {
        func line(_ position: CGFloat, _ range: CGFloat, _ length: CGFloat) -> String? {
            NuxieMachineScreenReaderScroll.shownPage(position: position, range: range, length: length)
                .map { NuxieMachineScreenReaderScroll.pageWords($0.page, of: $0.of) }
        }
        XCTAssertEqual(line(0, 1592, 844), "Page 1 of 3", "the top")
        XCTAssertEqual(line(796, 1592, 844), "Page 2 of 3", "one step down")
        XCTAssertEqual(line(1592, 1592, 844), "Page 3 of 3", "the end")
        XCTAssertEqual(line(1591.6, 1592, 844), "Page 3 of 3", "within half a point of the end")
        XCTAssertEqual(line(0, 1592.4, 844), "Page 1 of 3", "half a point over two steps adds no page")

        XCTAssertEqual(line(0, 1000, 844), "Page 1 of 3")
        XCTAssertEqual(line(796, 1000, 844), "Page 2 of 3", "one step down, short of the end")
        XCTAssertEqual(line(990, 1000, 844), "Page 2 of 3", "short of the end is never the last page")
        XCTAssertEqual(line(1000, 1000, 844), "Page 3 of 3", "the short last stop")
        XCTAssertEqual(line(300, 1000, 844), "Page 1 of 3", "nearer the top than the next step")
        XCTAssertEqual(line(500, 1000, 844), "Page 2 of 3", "nearer the next step")

        XCTAssertEqual(line(0, 284.6, 844), "Page 1 of 2", "less than a step: two pages")
        XCTAssertEqual(line(284.6, 284.6, 844), "Page 2 of 2")
    }

    /// Pages that cannot be counted have no line: a looping scroller's
    /// unbounded range, a range, position or length that is not a number, a
    /// negative range, or content of more than `mostPages` pages. A position
    /// before the top reads the first page.
    func testAPageLineNeedsPagesThatCanBeCounted() {
        let page = NuxieMachineScreenReaderScroll.shownPage
        XCTAssertNil(page(0, .infinity, 844), "an unbounded range")
        XCTAssertNil(page(0, .nan, 844))
        XCTAssertNil(page(.nan, 1000, 844))
        XCTAssertNil(page(.infinity, 1000, 844))
        XCTAssertNil(page(0, 1000, .nan))
        XCTAssertNil(page(0, 1000, .infinity))
        XCTAssertNil(page(0, -10, 844), "a negative range")
        XCTAssertNil(page(0, 1e12, 844), "far more than the most pages")
        let most = CGFloat(NuxieMachineScreenReaderScroll.mostPages - 2) * 796
        XCTAssertEqual(page(most, most, 844).map { [$0.page, $0.of] },
                       [NuxieMachineScreenReaderScroll.mostPages - 1, NuxieMachineScreenReaderScroll.mostPages - 1])
        XCTAssertEqual(page(-40, 1000, 844).map { [$0.page, $0.of] }, [1, 3], "pulled past the top")
        let looping = NuxieNativeScrollRegion(bounds: Self.surface, canScroll: Self.top | Self.bottom, parent: nil,
                                              scroll: CGPoint(x: 0, y: 400), range: CGSize(width: 0, height: CGFloat.infinity))
        XCTAssertNil(NuxieMachineScreenReaderScroll.pageLine(looping, vertical: true))
    }

    /// No page goes to a region whose box is not a finite length the way
    /// it would move.
    func testNoPageGoesToARegionWithoutAFiniteBox() {
        let endless = NuxieNativeScrollRegion(bounds: CGRect(x: 0, y: 0, width: 390, height: CGFloat.infinity),
                                              canScroll: Self.bottom | Self.right, parent: nil)
        let inside = node(1, CGRect(x: 24, y: 100, width: 100, height: 40), region: 0)
        XCTAssertNil(NuxieMachineScreenReaderScroll.page(.showBelow, from: inside, in: [endless]))
        XCTAssertEqual(NuxieMachineScreenReaderScroll.page(.showRight, from: inside, in: [endless]).map(\.dx), -342)
    }

    /// A region's line reads its position along the axis the page moved: y
    /// down the page, x sideways. None when its position is not read.
    func testARegionsLineReadsTheAxisThePageMoved() {
        let region = NuxieNativeScrollRegion(bounds: CGRect(x: 0, y: 0, width: 200, height: 844),
                                             canScroll: Self.top | Self.left, parent: nil,
                                             scroll: CGPoint(x: 400, y: 0), range: CGSize(width: 600, height: 0))
        XCTAssertEqual(NuxieMachineScreenReaderScroll.pageLine(region, vertical: false), "Page 4 of 5",
                       "x: a box 200 wide steps 152, so 600 is five pages and 400 nearest the fourth")
        XCTAssertEqual(NuxieMachineScreenReaderScroll.pageLine(region, vertical: true), "Page 1 of 1")
        let unread = NuxieNativeScrollRegion(bounds: Self.surface, canScroll: Self.bottom, parent: nil)
        XCTAssertNil(NuxieMachineScreenReaderScroll.pageLine(unread, vertical: true))
    }

    /// A region that fits its box can move no way, so no page goes to it and
    /// no line is asked: the element answers false.
    func testARegionThatFitsIsNeverAskedForALine() {
        let fits = NuxieNativeScrollRegion(bounds: Self.surface, canScroll: 0, parent: nil,
                                           scroll: .zero, range: .zero)
        let inside = node(1, CGRect(x: 24, y: 100, width: 100, height: 40), region: 0)
        for direction in [NuxieMachineScrollDirection.showBelow, .showAbove, .showRight, .showLeft] {
            XCTAssertNil(NuxieMachineScreenReaderScroll.page(direction, from: inside, in: [fits]))
        }
    }

    /// The fingers' way names what shows next: up shows what is below, down
    /// what is above, left what is to the right, right what is to the left;
    /// next is down the page and previous up it.
    func testAScrollGestureNamesTheWayTheContentFollows() {
        let direction = NuxieMachineScreenViewController.direction
        XCTAssertEqual(direction(.up), .showBelow)
        XCTAssertEqual(direction(.next), .showBelow)
        XCTAssertEqual(direction(.down), .showAbove)
        XCTAssertEqual(direction(.previous), .showAbove)
        XCTAssertEqual(direction(.left), .showRight)
        XCTAssertEqual(direction(.right), .showLeft)
    }

    /// A page goes to the first region from the node's own outward that
    /// can still move that way, by a page of that region's box, in a scroll
    /// wheel's sense; with none, no page, which the element answers false.
    func testAPageGoesToTheFirstRegionThatCanMoveThatWay() throws {
        let outer = NuxieNativeScrollRegion(bounds: Self.surface, canScroll: Self.top | Self.bottom, parent: nil)
        let inner = NuxieNativeScrollRegion(bounds: CGRect(x: 0, y: 300, width: 300, height: 200),
                                            canScroll: Self.top | Self.right, parent: 0)
        let deep = node(1, CGRect(x: 24, y: 320, width: 100, height: 40), region: 1)
        let page = NuxieMachineScreenReaderScroll.page
        XCTAssertEqual(page(.showBelow, deep, [outer, inner]).map { [Float($0.region), $0.dx, $0.dy] },
                       [0, 0, -796], "the inner region is at its bottom: the outer one takes it")
        XCTAssertEqual(page(.showAbove, deep, [outer, inner]).map { [Float($0.region), $0.dx, $0.dy] },
                       [1, 0, 152], "the inner region can move toward its top")
        XCTAssertEqual(page(.showRight, deep, [outer, inner]).map { [Float($0.region), $0.dx, $0.dy] },
                       [1, -252, 0])
        XCTAssertNil(page(.showLeft, deep, [outer, inner]), "no region above it moves left")
        XCTAssertNil(page(.showBelow, node(2, Self.below(0), region: nil), [outer]), "a node under no scroll")
    }

    /// Pages asked before a frame takes them add up into one move; one
    /// asked of a spent snapshot is asked again, and one that moved or
    /// stayed is done. A page does not wait for rest.
    func testPagesAskedBeforeAFrameAddUpAndAStaleOneIsAskedAgain() throws {
        let capture = try Self.capture([node(1, CGRect(x: 24, y: 400, width: 160, height: 44))],
                                       regions: [NuxieNativeScrollRegion(bounds: Self.surface,
                                                                          canScroll: Self.bottom, parent: nil)])
        var scrolling = NuxieMachineScreenReaderScrolling()
        scrolling.ended([], settled: false, drawn: capture)
        scrolling.page(.showBelow, from: 1, region: 0)
        scrolling.page(.showBelow, from: 1, region: 0)
        let request = NuxieMachineScrollRequest.page(captureID: capture.id, region: 0, dx: 0, dy: -1592)
        XCTAssertEqual(scrolling.take(capture).scrolls, [request], "a page does not wait for rest; two make one move")
        scrolling.ended([NuxieMachineScrolled(request, .stale)], settled: false, drawn: capture)
        XCTAssertEqual(scrolling.take(capture).scrolls, [request], "asked again")
        scrolling.ended([NuxieMachineScrolled(request, .stayed)], settled: false, drawn: capture)
        XCTAssertEqual(scrolling.take(capture).scrolls, [])
        XCTAssertFalse(scrolling.wantsFrames)
    }

    /// A page asked while a frame carries another waits for the next frame:
    /// the earlier page's answer settles only that page, whichever way the
    /// later one goes.
    func testAPageAskedWhileAnotherIsInFlightGoesNext() throws {
        let capture = try Self.capture([node(1, CGRect(x: 24, y: 400, width: 160, height: 44))],
                                       regions: [NuxieNativeScrollRegion(bounds: Self.surface,
                                                                          canScroll: Self.top | Self.bottom,
                                                                          parent: nil)])
        let down = NuxieMachineScrollRequest.page(captureID: capture.id, region: 0, dx: 0, dy: -796)
        let up = NuxieMachineScrollRequest.page(captureID: capture.id, region: 0, dx: 0, dy: 796)
        var scrolling = NuxieMachineScreenReaderScrolling()
        scrolling.page(.showBelow, from: 1, region: 0)
        XCTAssertEqual(scrolling.take(capture).scrolls, [down])
        scrolling.page(.showBelow, from: 1, region: 0)
        scrolling.ended([NuxieMachineScrolled(down, .moved)], settled: false, drawn: capture)
        XCTAssertEqual(scrolling.take(capture).scrolls, [down], "the page asked in flight goes")
        scrolling.page(.showAbove, from: 1, region: 0)
        scrolling.ended([NuxieMachineScrolled(down, .moved)], settled: false, drawn: capture)
        XCTAssertEqual(scrolling.take(capture).scrolls, [up], "the other way too")
        scrolling.ended([NuxieMachineScrolled(up, .moved)], settled: false, drawn: capture)
        XCTAssertFalse(scrolling.wantsFrames)
    }

    /// A page in flight that comes back stale is asked again, with pages
    /// its way asked since added to it; a page the other way asked since
    /// replaces it. An answer to no page in flight changes nothing.
    func testAStalePageInFlightJoinsOrGivesWayToPagesAskedSince() throws {
        let capture = try Self.capture([node(1, CGRect(x: 24, y: 400, width: 160, height: 44))],
                                       regions: [NuxieNativeScrollRegion(bounds: Self.surface,
                                                                          canScroll: Self.top | Self.bottom,
                                                                          parent: nil)])
        let down = NuxieMachineScrollRequest.page(captureID: capture.id, region: 0, dx: 0, dy: -796)
        var scrolling = NuxieMachineScreenReaderScrolling()
        scrolling.page(.showBelow, from: 1, region: 0)
        XCTAssertEqual(scrolling.take(capture).scrolls, [down])
        scrolling.page(.showBelow, from: 1, region: 0)
        scrolling.ended([NuxieMachineScrolled(down, .stale)], settled: false, drawn: capture)
        let both = NuxieMachineScrollRequest.page(captureID: capture.id, region: 0, dx: 0, dy: -1592)
        XCTAssertEqual(scrolling.take(capture).scrolls, [both], "asked again with the later one")
        scrolling.page(.showAbove, from: 1, region: 0)
        scrolling.ended([NuxieMachineScrolled(both, .stale)], settled: false, drawn: capture)
        let up = NuxieMachineScrollRequest.page(captureID: capture.id, region: 0, dx: 0, dy: 796)
        XCTAssertEqual(scrolling.take(capture).scrolls, [up], "the later way wins")
        scrolling.ended([NuxieMachineScrolled(down, .moved)], settled: false, drawn: capture)
        XCTAssertTrue(scrolling.wantsFrames, "an answer to another page leaves the one in flight")
        scrolling.ended([NuxieMachineScrolled(up, .moved)], settled: false, drawn: capture)
        XCTAssertFalse(scrolling.wantsFrames)
    }

    /// Focus that moves while a reveal is in flight is not undone by the
    /// earlier reveal's answer, stale or refused, and spends none of its own
    /// retries; a tap held while a frame carries an earlier one stays held.
    func testFocusAndATapAskedInFlightOutliveTheEarlierAnswer() throws {
        let capture = try Self.capture([node(1, Self.below(0), actions: 0), node(2, Self.below(100), actions: 0)],
                                       regions: [Self.page()])
        var scrolling = NuxieMachineScreenReaderScrolling()
        scrolling.ended([], settled: true, drawn: capture)
        scrolling.focus(1)
        let first = NuxieMachineScrollRequest.reveal(captureID: capture.id, nodeID: 1)
        XCTAssertEqual(scrolling.take(capture).scrolls, [first])
        scrolling.focus(2)
        for _ in 0...NuxieMachineScreenReaderScrolling.staleRetries {
            scrolling.ended([NuxieMachineScrolled(first, .stale)], settled: true, drawn: capture)
        }
        scrolling.ended([NuxieMachineScrolled(first, .refused)], settled: true, drawn: capture)
        XCTAssertEqual(scrolling.target, 2)
        XCTAssertEqual(scrolling.take(capture).scrolls, [.reveal(captureID: capture.id, nodeID: 2)],
                       "the later focus is revealed")

        let shown = try Self.capture([node(3, CGRect(x: 24, y: 100, width: 160, height: 44),
                                           actions: 1 << NuxieNativeSemanticAction.tap.rawValue)],
                                     regions: [Self.page()])
        var tapping = NuxieMachineScreenReaderScrolling()
        tapping.ended([], settled: true, drawn: shown)
        XCTAssertTrue(tapping.hold(tap: 3))
        XCTAssertEqual(tapping.take(shown).tap?.nodeID, 3)
        XCTAssertTrue(tapping.hold(tap: 3), "a second activation while the first is in flight")
        tapping.ended([], settled: true, drawn: shown)
        XCTAssertEqual(tapping.heldTap, 3, "is not cleared by the first one's frame")
    }

    /// Each input to the page a frame carries, cell by cell of the table at
    /// the top of `NuxieMachineScreenReaderScroll.swift`.
    func testThePageInFlightRow() throws {
        let capture = try Self.twoRegions()
        let down0 = NuxieMachineScrollRequest.page(captureID: capture.id, region: 0, dx: 0, dy: -352)
        let down1 = NuxieMachineScrollRequest.page(captureID: capture.id, region: 1, dx: 0, dy: -352)
        var scrolling = NuxieMachineScreenReaderScrolling()
        scrolling.ended([], settled: true, drawn: capture)

        // A page asked while one is in flight, any node, region or way, is
        // queued; the answer to the one in flight does not touch it.
        scrolling.page(.showBelow, from: 1, region: 0)
        XCTAssertEqual(scrolling.take(capture).scrolls, [down0])
        scrolling.page(.showBelow, from: 1, region: 0)
        scrolling.page(.showBelow, from: 2, region: 1)
        XCTAssertEqual(scrolling.queuedPages.map(\.region), [0, 1], "queued, not joined to the one in flight")

        // Frame not drawn: the answer is a fact of the step and still
        // ends the flight.
        scrolling.ended([NuxieMachineScrolled(down0, .moved)], settled: false, drawn: nil)
        XCTAssertEqual(scrolling.take(capture).scrolls, [down0], "the queued page goes next: the flight ended")

        // Answer to another request: nothing; the one in flight stays.
        scrolling.ended([NuxieMachineScrolled(down1, .stale)], settled: false, drawn: capture)
        XCTAssertEqual(scrolling.queuedPages.map(\.region), [1], "an answer to another request requeues nothing")
        XCTAssertTrue(scrolling.wantsFrames)
        // Answer stayed: done, nothing told.
        XCTAssertNil(scrolling.ended([NuxieMachineScrolled(down0, .stayed)], settled: false, drawn: capture))
        XCTAssertEqual(scrolling.take(capture).scrolls, [down1], "a frame carries one page, the next region's")
        XCTAssertNil(scrolling.ended([NuxieMachineScrolled(down1, .stayed)], settled: false, drawn: capture),
                     "answer stayed: nothing told")
        XCTAssertFalse(scrolling.wantsFrames, "answer stayed: done")

        // Answer refused: done.
        scrolling.page(.showBelow, from: 1, region: 0)
        XCTAssertEqual(scrolling.take(capture).scrolls, [down0])
        XCTAssertNil(scrolling.ended([NuxieMachineScrolled(down0, .refused)], settled: false, drawn: capture),
                     "answer refused: nothing told")
        XCTAssertFalse(scrolling.wantsFrames, "answer refused: done")

        // Answer stale: queued again first, ahead of another region's page,
        // joined by its region's page its way.
        scrolling.page(.showBelow, from: 1, region: 0)
        XCTAssertEqual(scrolling.take(capture).scrolls, [down0])
        scrolling.page(.showBelow, from: 2, region: 1)
        scrolling.page(.showBelow, from: 1, region: 0)
        scrolling.ended([NuxieMachineScrolled(down0, .stale)], settled: false, drawn: capture)
        XCTAssertEqual(scrolling.queuedPages.map { [$0.region, $0.count] }, [[0, 2], [1, 1]],
                       "answer stale: first, joined by its region's page its way")
        let twice0 = NuxieMachineScrollRequest.page(captureID: capture.id, region: 0, dx: 0, dy: -704)
        XCTAssertEqual(scrolling.take(capture).scrolls, [twice0])
        // Stale again with its region's page the other way asked since:
        // dropped for it.
        scrolling.page(.showAbove, from: 1, region: 0)
        scrolling.ended([NuxieMachineScrolled(twice0, .stale)], settled: false, drawn: capture)
        XCTAssertEqual(scrolling.queuedPages.map(\.region), [1, 0])
        XCTAssertEqual(scrolling.queuedPages.map(\.direction), [.showBelow, .showAbove],
                       "answer stale, a page the other way asked since: dropped for it")
        XCTAssertEqual(scrolling.take(capture).scrolls, [down1])
        scrolling.ended([NuxieMachineScrolled(down1, .moved)], settled: false, drawn: capture)
        let up0 = NuxieMachineScrollRequest.page(captureID: capture.id, region: 0, dx: 0, dy: 352)
        XCTAssertEqual(scrolling.take(capture).scrolls, [up0])
        scrolling.ended([NuxieMachineScrolled(up0, .moved)], settled: false, drawn: capture)

        // Stale more than `staleRetries` times: dropped.
        scrolling.page(.showBelow, from: 1, region: 0)
        for attempt in 0...NuxieMachineScreenReaderScrolling.staleRetries {
            XCTAssertEqual(scrolling.take(capture).scrolls, [down0], "attempt \(attempt)")
            scrolling.ended([NuxieMachineScrolled(down0, .stale)], settled: false, drawn: capture)
        }
        XCTAssertEqual(scrolling.take(capture).scrolls, [], "let go after the retries")
        XCTAssertFalse(scrolling.wantsFrames)
    }

    /// Each input to the pages waiting for a frame, cell by cell of the
    /// table at the top of `NuxieMachineScreenReaderScroll.swift`. Pages
    /// from nodes in different regions go each to its own region: none is
    /// joined to the first node's.
    func testTheQueuedPagesRow() throws {
        let capture = try Self.twoRegions()
        var scrolling = NuxieMachineScreenReaderScrolling()
        scrolling.ended([], settled: true, drawn: capture)

        // Same region, same way, another node: one more page.
        scrolling.page(.showBelow, from: 1, region: 0)
        scrolling.page(.showBelow, from: 3, region: 0)
        XCTAssertEqual(scrolling.queuedPages.map { [$0.region, $0.count] }, [[0, 2]], "same region, same way")
        // Another region, same way: a page of its own, after.
        scrolling.page(.showBelow, from: 2, region: 1)
        XCTAssertEqual(scrolling.queuedPages.map { [$0.region, $0.count] }, [[0, 2], [1, 1]],
                       "another region: its own page, not joined to the first node's")
        // Same region, other way: replaces it, after the others.
        scrolling.page(.showAbove, from: 1, region: 0)
        XCTAssertEqual(scrolling.queuedPages.map(\.region), [1, 0])
        XCTAssertEqual(scrolling.queuedPages.map(\.direction), [.showBelow, .showAbove], "the latest way asked")
        XCTAssertEqual(scrolling.queuedPages.map(\.count), [1, 1])

        // Frame not drawn: they still go, each to its own region.
        scrolling.ended([], settled: true, drawn: nil)
        let down1 = NuxieMachineScrollRequest.page(captureID: capture.id, region: 1, dx: 0, dy: -352)
        XCTAssertEqual(scrolling.take(capture).scrolls, [down1], "frame not drawn: the page goes all the same")
        scrolling.ended([NuxieMachineScrolled(down1, .moved)], settled: false, drawn: capture)
        let up0 = NuxieMachineScrollRequest.page(captureID: capture.id, region: 0, dx: 0, dy: 352)
        XCTAssertEqual(scrolling.take(capture).scrolls, [up0])
        scrolling.ended([NuxieMachineScrolled(up0, .moved)], settled: false, drawn: capture)

        // The capture loses the node, or its region can no longer move
        // that way: dropped when its frame takes it, and the next goes.
        scrolling.page(.showBelow, from: 1, region: 0)
        scrolling.page(.showBelow, from: 2, region: 1)
        let lost = try Self.twoRegions(without: 1)
        XCTAssertEqual(scrolling.take(lost).scrolls,
                       [.page(captureID: lost.id, region: 1, dx: 0, dy: -352)], "the node is gone: the next goes")
        scrolling.ended([NuxieMachineScrolled(.page(captureID: lost.id, region: 1, dx: 0, dy: -352), .moved)],
                        settled: false, drawn: lost)
        scrolling.page(.showBelow, from: 1, region: 0)
        let atEnd = try Self.twoRegions(canScroll: Self.top)
        XCTAssertEqual(scrolling.take(atEnd).scrolls, [], "its region moves no further that way: dropped")
        XCTAssertFalse(scrolling.wantsFrames)
    }

    /// Each input to the line of a page that moved and is not yet told,
    /// cell by cell of the table at the top of
    /// `NuxieMachineScreenReaderScroll.swift`. A frame not drawn holds it:
    /// its capture on screen is from before the move.
    func testTheAnnouncementRow() throws {
        let top = try Self.twoRegions(scrollY: 0)
        let oneDown = try Self.twoRegions(scrollY: 352)
        let down0 = NuxieMachineScrollRequest.page(captureID: top.id, region: 0, dx: 0, dy: -352)
        var scrolling = NuxieMachineScreenReaderScrolling()
        scrolling.ended([], settled: true, drawn: top)

        scrolling.page(.showBelow, from: 1, region: 0)
        XCTAssertEqual(scrolling.take(top).scrolls, [down0])
        XCTAssertNil(scrolling.ended([NuxieMachineScrolled(down0, .moved)], settled: false, drawn: nil),
                     "frame not drawn: held")
        XCTAssertTrue(scrolling.wantsFrames, "a frame is wanted to tell it")
        // A page asked meanwhile, and its answers other than moved: nothing.
        scrolling.page(.showBelow, from: 1, region: 0)
        let next = NuxieMachineScrollRequest.page(captureID: top.id, region: 0, dx: 0, dy: -352)
        XCTAssertEqual(scrolling.take(top).scrolls, [next])
        XCTAssertNil(scrolling.ended([NuxieMachineScrolled(next, .stayed)], settled: false, drawn: nil),
                     "another page stayed: still held")
        XCTAssertEqual(scrolling.ended([], settled: false, drawn: oneDown),
                       NuxieMachinePageAnnouncement(line: "Page 2 of 3"),
                       "frame drawn: told from its capture, which shows the move, not the one before it")
        XCTAssertNil(scrolling.ended([], settled: false, drawn: oneDown), "told once")
        XCTAssertFalse(scrolling.wantsFrames)

        // Another page moved before a frame was drawn: the later one is told.
        scrolling.page(.showBelow, from: 1, region: 0)
        let again0 = NuxieMachineScrollRequest.page(captureID: oneDown.id, region: 0, dx: 0, dy: -352)
        XCTAssertEqual(scrolling.take(oneDown).scrolls, [again0])
        scrolling.ended([NuxieMachineScrolled(again0, .moved)], settled: false, drawn: nil)
        scrolling.page(.showRight, from: 2, region: 1)
        let right1 = NuxieMachineScrollRequest.page(captureID: oneDown.id, region: 1, dx: -147, dy: 0)
        XCTAssertEqual(scrolling.take(oneDown).scrolls, [right1])
        scrolling.ended([NuxieMachineScrolled(right1, .moved)], settled: false, drawn: nil)
        let sideways = try Self.twoRegions(scrollY: 704, scrollX1: 147)
        XCTAssertEqual(scrolling.ended([], settled: false, drawn: sideways),
                       NuxieMachinePageAnnouncement(line: "Page 2 of 3"),
                       "replaced: region 1 along x, 147 of 294 in steps of 147")

        // The capture loses the region: told with nothing to say.
        scrolling.page(.showRight, from: 2, region: 1)
        let right1Again = NuxieMachineScrollRequest.page(captureID: sideways.id, region: 1, dx: -147, dy: 0)
        XCTAssertEqual(scrolling.take(sideways).scrolls, [right1Again])
        let oneRegion = try Self.capture([node(1, CGRect(x: 24, y: 100, width: 100, height: 40))],
                                         regions: [Self.page()])
        XCTAssertEqual(scrolling.ended([NuxieMachineScrolled(right1Again, .moved)], settled: false, drawn: oneRegion),
                       NuxieMachinePageAnnouncement(line: nil), "the capture lost the region: nothing to say")
        XCTAssertFalse(scrolling.wantsFrames)
    }

    // MARK: The element

    /// An element tells its screen every time focus reaches it or leaves
    /// it, and passes a scroll gesture on only for a node inside a `scroll`;
    /// its answer is the screen's. The container tells the reader a page
    /// moved with the line it is given.
    func testAnElementPassesEveryFocusChangeAndScrollOnlyForANodeInAScroll() throws {
        let view = UIView(frame: Self.surface)
        var posted: [Any?] = []
        let container = ExperienceSemanticAccessibilityContainer(view: view, focusedElement: { nil },
                                                                 moveFocus: { _ in }, layoutChanged: {},
                                                                 pageScrolled: { posted.append($0) })
        container.setActive(true)
        let capture = try Self.capture([node(1, Self.below(0), region: 0, role: .text, label: "In"),
                                        node(2, CGRect(x: 24, y: 100, width: 100, height: 40), region: nil,
                                             role: .text, label: "Out")],
                                       regions: [Self.page()])
        var focused: [UInt32] = []
        var scrolled: [(UInt32, UIAccessibilityScrollDirection)] = []
        var answer = true
        container.update(capture: capture, nativeControls: [:], project: { node in
            NuxieMachineScreenViewController.projection(for: node, on: Self.surface)
        }, submit: { _, _, _ in false }, focused: { node, gained in
            focused.append(gained ? node : 100 + node)
        }, scroll: { node, direction in
            scrolled.append((node, direction))
            return answer
        })
        let elements = (view.accessibilityElements ?? []).compactMap { $0 as? UIAccessibilityElement }
        let inside = try XCTUnwrap(elements.first { $0.accessibilityLabel == "In" })
        let outside = try XCTUnwrap(elements.first { $0.accessibilityLabel == "Out" })

        inside.accessibilityElementDidBecomeFocused()
        inside.accessibilityElementDidLoseFocus()
        outside.accessibilityElementDidBecomeFocused()
        XCTAssertEqual(focused, [1, 101, 2], "every focus change, under a scroll or not, and focus leaving")
        XCTAssertTrue(inside.accessibilityScroll(.up))
        answer = false
        XCTAssertFalse(inside.accessibilityScroll(.down), "the screen's answer: nothing moves that way")
        XCTAssertFalse(outside.accessibilityScroll(.up), "a node under no scroll scrolls nothing")
        XCTAssertEqual(scrolled.map(\.0), [1, 1])
        XCTAssertEqual(scrolled.map(\.1), [.up, .down])

        container.announcePageScrolled("Page 2 of 3")
        XCTAssertEqual(posted.map { $0 as? String }, ["Page 2 of 3"])
    }

    // MARK: Helpers

    private func project(_ node: NuxieNativeSemanticNode)
        -> ExperienceSemanticAccessibilityContainer.Projection? {
        NuxieMachineScreenViewController.projection(for: node, on: Self.surface)
    }

    /// A box `offset` points below the surface.
    private static func below(_ offset: CGFloat) -> CGRect {
        CGRect(x: 24, y: 900 + offset, width: 160, height: 44)
    }

    /// A page filling the surface that can move toward its bottom.
    private static func page() -> NuxieNativeScrollRegion {
        NuxieNativeScrollRegion(bounds: surface, canScroll: bottom, parent: nil)
    }

    private func node(_ id: UInt32, _ bounds: CGRect, region: Int? = 0, actions: UInt32 = 0, flags: UInt32 = 0,
                      role: NuxieNativeSemanticRole = .button, label: String? = nil) -> NuxieNativeSemanticNode {
        NuxieNativeSemanticNode(id: id, parentID: nil, siblingIndex: id, role: role.rawValue, stateFlags: flags,
                                traitFlags: 0, headingLevel: 0, actions: actions, bounds: bounds,
                                label: label ?? "\(id)", value: "", hint: "", scrollRegion: region)
    }

    /// Two `scroll`s side by side, neither inside the other: region 0, 400
    /// points tall, a page of 352, scrolled to `scrollY` of 704, with nodes
    /// 1 and 3, which moves the ways `canScroll` says; region 1, 195 points
    /// wide, a page of 147 sideways, scrolled to `scrollX1` of 294, with node
    /// 2, which moves every way. Node `without` is left out.
    private static func twoRegions(scrollY: CGFloat = 0, scrollX1: CGFloat = 0, canScroll: UInt32 = top | bottom,
                                   without: UInt32? = nil) throws -> NuxieNativeSemanticCapture {
        let first = NuxieNativeScrollRegion(bounds: CGRect(x: 0, y: 0, width: 390, height: 400), canScroll: canScroll,
                                            parent: nil, scroll: CGPoint(x: 0, y: scrollY),
                                            range: CGSize(width: 0, height: 704))
        let second = NuxieNativeScrollRegion(bounds: CGRect(x: 0, y: 420, width: 195, height: 400),
                                             canScroll: top | bottom | left | right, parent: nil,
                                             scroll: CGPoint(x: scrollX1, y: 0), range: CGSize(width: 294, height: 704))
        func node(_ id: UInt32, _ y: CGFloat, region: Int) -> NuxieNativeSemanticNode {
            NuxieNativeSemanticNode(id: id, parentID: nil, siblingIndex: id, role: NuxieNativeSemanticRole.button.rawValue,
                                    stateFlags: 0, traitFlags: 0, headingLevel: 0, actions: 0,
                                    bounds: CGRect(x: 24, y: y, width: 100, height: 40), label: "\(id)", value: "",
                                    hint: "", scrollRegion: region)
        }
        let nodes = [node(1, 100, region: 0), node(2, 500, region: 1), node(3, 200, region: 0)]
        return try capture(nodes.filter { $0.id != without }, regions: [first, second])
    }

    private static func capture(_ nodes: [NuxieNativeSemanticNode],
                                regions: [NuxieNativeScrollRegion]) throws -> NuxieNativeSemanticCapture {
        NuxieNativeSemanticCapture(id: UUID(), tree: try NuxieNativeSemanticTree(renderRevision: 1, treeVersion: 1,
                                                                                 nodes: nodes),
                                   fieldsByTextRun: [:], scrollRegions: regions)
    }
}
#endif
