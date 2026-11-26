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
/// a reveal goes and how often, a tap that waits behind one, and a page.
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

    // MARK: Reveals

    /// A reveal goes only after a settled frame, and only for the latest
    /// node focus reached: a move made while one settles would overshoot.
    func testARevealWaitsForASettleAndOnlyTheLatestFocusIsRevealed() throws {
        let capture = try Self.capture([node(1, Self.below(0)), node(2, Self.below(100))], regions: [Self.page()])
        var scrolling = NuxieMachineScreenReaderScrolling()
        scrolling.focus(1)
        XCTAssertEqual(scrolling.take(capture, settled: false).scrolls, [], "nothing goes while the frame is unsettled")
        scrolling.focus(2)
        XCTAssertEqual(scrolling.take(capture, settled: true).scrolls, [.reveal(captureID: capture.id, nodeID: 2)],
                       "the latest focus is revealed once settled")
        scrolling.ended([NuxieMachineScrolled(.reveal(captureID: capture.id, nodeID: 2), .moved)], settled: false)
        XCTAssertEqual(scrolling.settling, 2)
        scrolling.focus(1)
        XCTAssertEqual(scrolling.take(capture, settled: true).scrolls, [],
                       "a reveal that moved and has not been seen to settle holds the next")
        scrolling.ended([], settled: false)
        XCTAssertEqual(scrolling.take(capture, settled: false).scrolls, [])
        scrolling.ended([], settled: true)
        XCTAssertNil(scrolling.settling)
        XCTAssertEqual(scrolling.take(capture, settled: true).scrolls, [.reveal(captureID: capture.id, nodeID: 1)])
    }

    /// A node already whole inside its `scroll` is not revealed, and one
    /// under no `scroll` neither.
    func testANodeThatShowsIsNotRevealed() throws {
        let capture = try Self.capture([node(1, CGRect(x: 24, y: 400, width: 160, height: 44)),
                                        node(2, Self.below(0), region: nil)], regions: [Self.page()])
        var scrolling = NuxieMachineScreenReaderScrolling()
        scrolling.focus(1)
        XCTAssertEqual(scrolling.take(capture, settled: true).scrolls, [])
        XCTAssertNil(scrolling.target, "nothing waits")
        scrolling.focus(2)
        XCTAssertEqual(scrolling.take(capture, settled: true).scrolls, [])
        XCTAssertFalse(scrolling.wantsFrames)
    }

    /// Once a reveal settles, a node still not whole inside its regions is
    /// revealed again, at most as many times in all as it has regions
    /// around it: twice for a node in a `scroll` inside a `scroll`, once
    /// for a node in one.
    func testANodeStillNotWholeAfterARevealIsRevealedAgainUpToItsNesting() throws {
        let outer = Self.page()
        let inner = NuxieNativeScrollRegion(bounds: CGRect(x: 0, y: 600, width: 390, height: 200),
                                            canScroll: Self.bottom, parent: 0)
        let capture = try Self.capture([node(1, Self.below(0), region: 1), node(2, Self.below(0), region: 0)],
                                       regions: [outer, inner])
        var scrolling = NuxieMachineScreenReaderScrolling()
        scrolling.focus(1)
        for round in 1...2 {
            XCTAssertEqual(scrolling.take(capture, settled: true).scrolls, [.reveal(captureID: capture.id, nodeID: 1)],
                           "reveal \(round) of a node in two regions")
            scrolling.ended([NuxieMachineScrolled(.reveal(captureID: capture.id, nodeID: 1), .moved)], settled: false)
            scrolling.ended([], settled: true)
        }
        XCTAssertEqual(scrolling.take(capture, settled: true).scrolls, [], "no third reveal")
        XCTAssertNil(scrolling.target)

        scrolling.focus(2)
        XCTAssertEqual(scrolling.take(capture, settled: true).scrolls, [.reveal(captureID: capture.id, nodeID: 2)])
        scrolling.ended([NuxieMachineScrolled(.reveal(captureID: capture.id, nodeID: 2), .stayed)], settled: true)
        XCTAssertEqual(scrolling.take(capture, settled: true).scrolls, [], "one region, one reveal")
        XCTAssertFalse(scrolling.wantsFrames)
    }

    /// A reveal asked of a snapshot an earlier call in its frame spent is
    /// asked again of the next, a bounded number of times, and does not
    /// count against the node's reveals.
    func testARevealAskedOfASpentSnapshotIsAskedAgainABoundedNumberOfTimes() throws {
        let capture = try Self.capture([node(1, Self.below(0))], regions: [Self.page()])
        var scrolling = NuxieMachineScreenReaderScrolling()
        scrolling.focus(1)
        for attempt in 0...NuxieMachineScreenReaderScrolling.staleRetries {
            XCTAssertEqual(scrolling.take(capture, settled: true).scrolls, [.reveal(captureID: capture.id, nodeID: 1)],
                           "attempt \(attempt)")
            scrolling.ended([NuxieMachineScrolled(.reveal(captureID: capture.id, nodeID: 1), .stale)], settled: true)
        }
        XCTAssertEqual(scrolling.take(capture, settled: true).scrolls, [], "let go after the retries")
        XCTAssertFalse(scrolling.wantsFrames)
    }

    /// A reveal and a tap behind it wait however long the page takes to
    /// settle, and go in the first frame after it does.
    func testARevealWaitsForTheSettleHoweverLongItTakes() throws {
        let capture = try Self.capture([node(1, Self.below(0), actions: 0)], regions: [Self.page()])
        var scrolling = NuxieMachineScreenReaderScrolling()
        scrolling.focus(1)
        _ = scrolling.hold(tap: 1)
        for _ in 0..<1000 {
            XCTAssertEqual(scrolling.take(capture, settled: false).scrolls, [])
            scrolling.ended([], settled: false)
        }
        XCTAssertTrue(scrolling.wantsFrames)
        XCTAssertEqual(scrolling.heldTap, 1)
        XCTAssertEqual(scrolling.take(capture, settled: true).scrolls,
                       [.reveal(captureID: capture.id, nodeID: 1)])
    }

    // MARK: A tap behind a reveal

    /// A tap on a node being revealed waits behind the reveal and goes in
    /// the first settled frame after, asked of that frame's snapshot, once
    /// the node offers a tap. One tap waits at a time.
    func testATapWaitsBehindItsRevealAndGoesOnceTheNodeOffersOne() throws {
        let before = try Self.capture([node(1, Self.below(0), actions: 0)], regions: [Self.page()])
        var scrolling = NuxieMachineScreenReaderScrolling()
        XCTAssertTrue(scrolling.hold(tap: 1), "a tap on a node out of view waits")
        XCTAssertFalse(scrolling.hold(tap: 1), "a second waits for none")
        XCTAssertTrue(scrolling.revealPending(for: 1), "holding a tap asks for its node's reveal")
        var taken = scrolling.take(before, settled: true)
        XCTAssertEqual(taken.scrolls, [.reveal(captureID: before.id, nodeID: 1)])
        XCTAssertNil(taken.tap, "the tap does not go with the reveal")
        scrolling.ended([NuxieMachineScrolled(.reveal(captureID: before.id, nodeID: 1), .moved)], settled: false)
        XCTAssertTrue(scrolling.revealPending(for: 1), "still pending while it settles")
        taken = scrolling.take(before, settled: false)
        XCTAssertEqual(taken.scrolls, [])
        XCTAssertNil(taken.tap, "nor while it settles")
        scrolling.ended([], settled: true)
        let after = try Self.capture([node(1, CGRect(x: 24, y: 700, width: 160, height: 44), actions: Self.tap)],
                                     regions: [Self.page()])
        taken = scrolling.take(after, settled: true)
        XCTAssertEqual(taken.scrolls, [])
        XCTAssertEqual(taken.tap, NuxieMachineSemanticTap(captureID: after.id, nodeID: 1),
                       "the tap goes once settled, asked of the snapshot shown then")
        XCTAssertNil(scrolling.heldTap)
        XCTAssertFalse(scrolling.wantsFrames)
    }

    /// A tap that waited for a node that still offers none once the reveal
    /// is done goes nowhere: the engine would refuse it.
    func testATapThatWaitedForANodeThatStillOffersNoneIsDropped() throws {
        let capture = try Self.capture([node(1, Self.below(0), actions: 0)], regions: [Self.page()])
        var scrolling = NuxieMachineScreenReaderScrolling()
        _ = scrolling.hold(tap: 1)
        _ = scrolling.take(capture, settled: true)
        scrolling.ended([NuxieMachineScrolled(.reveal(captureID: capture.id, nodeID: 1), .stayed)], settled: true)
        let shown = try Self.capture([node(1, CGRect(x: 24, y: 400, width: 160, height: 44), actions: 0)],
                                     regions: [Self.page()])
        let taken = scrolling.take(shown, settled: true)
        XCTAssertNil(taken.tap)
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
        func line(_ position: CGFloat, _ range: CGFloat, _ length: CGFloat) -> String {
            let at = NuxieMachineScreenReaderScroll.shownPage(position: position, range: range, length: length)
            return NuxieMachineScreenReaderScroll.pageWords(at.page, of: at.of)
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
    /// stayed is done.
    func testPagesAskedBeforeAFrameAddUpAndAStaleOneIsAskedAgain() throws {
        let capture = try Self.capture([node(1, CGRect(x: 24, y: 400, width: 160, height: 44))],
                                       regions: [NuxieNativeScrollRegion(bounds: Self.surface,
                                                                          canScroll: Self.bottom, parent: nil)])
        var scrolling = NuxieMachineScreenReaderScrolling()
        scrolling.page(.showBelow, from: 1)
        scrolling.page(.showBelow, from: 1)
        let request = NuxieMachineScrollRequest.page(captureID: capture.id, region: 0, dx: 0, dy: -1592)
        XCTAssertEqual(scrolling.take(capture, settled: false).scrolls, [request],
                       "a page does not wait for a settle; two make one move")
        scrolling.ended([NuxieMachineScrolled(request, .stale)], settled: false)
        XCTAssertEqual(scrolling.take(capture, settled: false).scrolls, [request], "asked again")
        scrolling.ended([NuxieMachineScrolled(request, .moved)], settled: false)
        XCTAssertEqual(scrolling.take(capture, settled: true).scrolls, [])
        XCTAssertFalse(scrolling.wantsFrames)
    }

    // MARK: The element

    /// An element tells its screen when focus reaches it, and passes a
    /// scroll gesture on, only for a node inside a `scroll`; its answer is
    /// the screen's. The container tells the reader a page moved with the
    /// line it is given.
    func testAnElementPassesFocusAndScrollOnlyForANodeInAScroll() throws {
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
        }, submit: { _, _, _ in false }, focused: { focused.append($0) }, scroll: { node, direction in
            scrolled.append((node, direction))
            return answer
        })
        let elements = (view.accessibilityElements ?? []).compactMap { $0 as? UIAccessibilityElement }
        let inside = try XCTUnwrap(elements.first { $0.accessibilityLabel == "In" })
        let outside = try XCTUnwrap(elements.first { $0.accessibilityLabel == "Out" })

        inside.accessibilityElementDidBecomeFocused()
        outside.accessibilityElementDidBecomeFocused()
        XCTAssertEqual(focused, [1])
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

    private static func capture(_ nodes: [NuxieNativeSemanticNode],
                                regions: [NuxieNativeScrollRegion]) throws -> NuxieNativeSemanticCapture {
        NuxieNativeSemanticCapture(id: UUID(), tree: try NuxieNativeSemanticTree(renderRevision: 1, treeVersion: 1,
                                                                                 nodes: nodes),
                                   fieldsByTextRun: [:], scrollRegions: regions)
    }
}
#endif
