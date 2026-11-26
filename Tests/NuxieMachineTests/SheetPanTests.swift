#if os(iOS) && !targetEnvironment(macCatalyst)
import CoreGraphics
import Foundation
import XCTest
import NuxieMachine
import NuxieRuntime

/// When a sheet's swipe may take a drag on a machine component
/// ([`NuxieMachineSheetPan.mayBegin`]), and the scroll regions a frame's
/// capture lists for it.
///
/// The rule is checked as a pure function of where the drag went down, how
/// far it has moved, and the regions. The regions are checked on the
/// `views-scroll` paywall, whose page is one `scroll` filling the surface,
/// drawn by the engine with no window: at its top, moved a little, and at
/// its end.
final class SheetPanTests: XCTestCase {
    private static let top = NuxieNativeScrollRegion.towardTop
    private static let bottom = NuxieNativeScrollRegion.towardBottom
    private static let down = CGPoint(x: 0, y: 10)
    private static let up = CGPoint(x: 0, y: -10)

    /// A page filling a phone's surface, at its top or scrolled down.
    private static func page(scrolled: Bool) -> NuxieNativeScrollRegion {
        NuxieNativeScrollRegion(bounds: CGRect(x: 0, y: 0, width: 390, height: 844),
                                canScroll: scrolled ? top | bottom : bottom, parent: nil)
    }

    // MARK: The rule

    /// A drag that went down outside every region is the sheet's, whichever
    /// way it goes, and so is any drag on a component with no `scroll`.
    func testADragOutsideEveryRegionIsTheSheets() {
        let page = NuxieNativeScrollRegion(bounds: CGRect(x: 0, y: 120, width: 390, height: 724),
                                           canScroll: Self.top | Self.bottom, parent: nil)
        let header = CGPoint(x: 195, y: 60)
        XCTAssertTrue(NuxieMachineSheetPan.mayBegin(from: header, moving: Self.down, over: [page]))
        XCTAssertTrue(NuxieMachineSheetPan.mayBegin(from: header, moving: Self.up, over: [page]))
        XCTAssertTrue(NuxieMachineSheetPan.mayBegin(from: header, moving: CGPoint(x: 10, y: 0), over: [page]))
        XCTAssertTrue(NuxieMachineSheetPan.mayBegin(from: header, moving: Self.down, over: []))
    }

    /// Over a page at its top, a downward drag pulls the sheet.
    func testADownwardDragOverAPageAtItsTopIsTheSheets() {
        let start = CGPoint(x: 195, y: 400)
        XCTAssertTrue(NuxieMachineSheetPan.mayBegin(from: start, moving: Self.down, over: [Self.page(scrolled: false)]))
        XCTAssertTrue(NuxieMachineSheetPan.mayBegin(from: start, moving: CGPoint(x: 6, y: 8),
                                                    over: [Self.page(scrolled: false)]),
                      "a drag more down than sideways is downward")
    }

    /// Over a page scrolled down, a downward drag moves the page back.
    func testADownwardDragOverAScrolledPageIsThePages() {
        XCTAssertFalse(NuxieMachineSheetPan.mayBegin(from: CGPoint(x: 195, y: 400), moving: Self.down,
                                                     over: [Self.page(scrolled: true)]))
    }

    /// Over a page, an upward drag scrolls it, at its top or scrolled, and
    /// at its end, where it springs.
    func testAnUpwardDragOverAPageIsThePages() {
        let start = CGPoint(x: 195, y: 400)
        let end = NuxieNativeScrollRegion(bounds: CGRect(x: 0, y: 0, width: 390, height: 844),
                                          canScroll: Self.top, parent: nil)
        for page in [Self.page(scrolled: false), Self.page(scrolled: true), end] {
            XCTAssertFalse(NuxieMachineSheetPan.mayBegin(from: start, moving: Self.up, over: [page]),
                           "can scroll \(page.canScroll)")
        }
    }

    /// Over a page, a sideways drag is not the sheet's, even one a little
    /// downward, and even at the page's top.
    func testASidewaysDragOverAPageIsNotTheSheets() {
        let start = CGPoint(x: 195, y: 400)
        for moving in [CGPoint(x: 10, y: 0), CGPoint(x: -10, y: 0), CGPoint(x: 10, y: 8), CGPoint(x: -8, y: 8)] {
            XCTAssertFalse(NuxieMachineSheetPan.mayBegin(from: start, moving: moving,
                                                         over: [Self.page(scrolled: false)]),
                           "moving \(moving)")
        }
    }

    /// A list inside a page: a downward drag on the list pulls the sheet
    /// only when neither can move toward its top. With the list at its top
    /// and the page scrolled down, the page moves first; with the list
    /// scrolled and the page at its top, the list does.
    func testNestedRegionsPullTheSheetOnlyWhenEveryOneUnderTheTouchIsAtItsTop() {
        let start = CGPoint(x: 195, y: 400)
        func regions(page: UInt32, list: UInt32) -> [NuxieNativeScrollRegion] {
            [NuxieNativeScrollRegion(bounds: CGRect(x: 0, y: 0, width: 390, height: 844), canScroll: page,
                                     parent: nil),
             NuxieNativeScrollRegion(bounds: CGRect(x: 24, y: 300, width: 342, height: 200), canScroll: list,
                                     parent: 0)]
        }
        XCTAssertFalse(NuxieMachineSheetPan.mayBegin(
            from: start, moving: Self.down, over: regions(page: Self.top | Self.bottom, list: Self.bottom)),
            "the list at its top, the page scrolled")
        XCTAssertFalse(NuxieMachineSheetPan.mayBegin(
            from: start, moving: Self.down, over: regions(page: Self.bottom, list: Self.top | Self.bottom)),
            "the list scrolled, the page at its top")
        XCTAssertTrue(NuxieMachineSheetPan.mayBegin(
            from: start, moving: Self.down, over: regions(page: Self.bottom, list: Self.bottom)),
            "both at their tops")
        // Beside the list, only the page is under the touch.
        XCTAssertTrue(NuxieMachineSheetPan.mayBegin(
            from: CGPoint(x: 195, y: 700), moving: Self.down,
            over: regions(page: Self.bottom, list: Self.top | Self.bottom)),
            "beside a scrolled list, on a page at its top")
    }

    /// A region is clipped by the region it is inside before the touch is
    /// tested: the part of a list that runs past its page's box is not
    /// under the finger, though the list's own box holds the point.
    func testARegionIsClippedByItsParent() {
        let page = NuxieNativeScrollRegion(bounds: CGRect(x: 0, y: 120, width: 390, height: 500),
                                           canScroll: Self.bottom, parent: nil)
        let list = NuxieNativeScrollRegion(bounds: CGRect(x: 0, y: 500, width: 390, height: 300),
                                           canScroll: Self.top | Self.bottom, parent: 0)
        let below = CGPoint(x: 195, y: 700)
        XCTAssertTrue(list.bounds.contains(below), "the list's own box holds the point")
        XCTAssertTrue(NuxieMachineSheetPan.mayBegin(from: below, moving: Self.down, over: [page, list]),
                      "below the page the touch is outside every region")
        XCTAssertTrue(NuxieMachineSheetPan.mayBegin(from: below, moving: Self.up, over: [page, list]),
                      "whichever way it goes")
        XCTAssertFalse(NuxieMachineSheetPan.mayBegin(from: CGPoint(x: 195, y: 560), moving: Self.down,
                                                     over: [page, list]),
                       "inside the page, the scrolled list is under the touch")
    }

    // MARK: The surface

    /// The surface answers from the regions shown when the touch went down,
    /// not from frames shown since. A page a few points below its top that
    /// a slow drag down scrolls to its top before UIKit asks keeps the drag:
    /// the page was scrolled when the finger went down. The next touch is
    /// answered from what is shown when it goes down.
    @MainActor
    func testTheSurfaceAnswersFromTheRegionsShownWhenTheTouchWentDown() {
        let surface = NuxieMachineSurfaceView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let start = CGPoint(x: 195, y: 400)
        let first = NSObject()
        XCTAssertNil(surface.sheetPanMayBegin(moving: Self.down), "no touch is down")
        surface.touchWentDown(ObjectIdentifier(first), at: start)
        XCTAssertNil(surface.sheetPanMayBegin(moving: Self.down), "the touch went down before any frame was shown")
        surface.touchLifted(ObjectIdentifier(first))

        surface.scrollRegions = [Self.page(scrolled: true)]
        let second = NSObject()
        surface.touchWentDown(ObjectIdentifier(second), at: start)
        surface.scrollRegions = [Self.page(scrolled: false)]
        XCTAssertEqual(surface.sheetPanMayBegin(moving: Self.down), false,
                       "the page was scrolled when the touch went down")
        let other = NSObject()
        surface.touchWentDown(ObjectIdentifier(other), at: CGPoint(x: 195, y: 700))
        surface.touchLifted(ObjectIdentifier(other))
        XCTAssertEqual(surface.sheetPanMayBegin(moving: Self.down), false,
                       "a second finger neither replaces nor clears the first")
        surface.touchLifted(ObjectIdentifier(second))
        XCTAssertNil(surface.sheetPanMayBegin(moving: Self.down), "the touch ended")

        let third = NSObject()
        surface.touchWentDown(ObjectIdentifier(third), at: start)
        XCTAssertEqual(surface.sheetPanMayBegin(moving: Self.down), true,
                       "the next touch goes down on a page at its top")
        withExtendedLifetime([first, second, other, third]) {}
    }

    // MARK: The capture

    /// The `views-scroll` paywall's capture lists its page as one region:
    /// the `scroll` filling the surface, inside no other, whose box stays
    /// put as it scrolls. At its top it can move only toward its bottom;
    /// dragged up a little, both ways; dragged up past its end, only toward
    /// its top. Never sideways.
    @MainActor
    func testTheCaptureListsThePageWithItsBoxAndTheWaysItCanMove() async throws {
        let run = try Counter(plan: Self.viewsScroll())
        await run.edge.start(event: "onboarding_completed", now: run.now)
        try await run.layOut()
        do {
            let box = CGRect(x: 0, y: 0, width: CounterDriverEdgeTests.width, height: CounterDriverEdgeTests.height)
            var regions = try await capture(run, name: "1-top")
            XCTAssertEqual(regions, [NuxieNativeScrollRegion(bounds: box, canScroll: Self.bottom, parent: nil)])

            try await drag(run, by: -80)
            regions = try await capture(run, name: "2-moved")
            XCTAssertEqual(regions, [NuxieNativeScrollRegion(bounds: box, canScroll: Self.top | Self.bottom,
                                                             parent: nil)])

            try await drag(run, by: -1400)
            regions = try await capture(run, name: "3-end")
            XCTAssertEqual(regions, [NuxieNativeScrollRegion(bounds: box, canScroll: Self.top, parent: nil)])
            try await run.edge.close()
        } catch {
            try? await run.edge.close()
            throw error
        }
    }

    /// The pointer clock a drag's pointers read, in seconds.
    private var clock: Float = 1

    /// One frame stepped and drawn, and its capture's scroll regions.
    @MainActor
    private func capture(_ run: Counter, name: String) async throws -> [NuxieNativeScrollRegion] {
        let touched = await run.edge.shown
        let stepped = await run.edge.frame(pointers: [], on: touched, elapsedSeconds: CounterDriverEdgeTests.tick,
                                           now: run.advance())
        let screen = await run.edge.screen()
        let runtime = try XCTUnwrap(screen, "nothing is presented")
        let frame = try await DrawnFrame.read(runtime, reported: stepped.reported, name: "regions-\(name)",
                                              capturesSemantics: true)
        return try XCTUnwrap(frame.semantics, "the frame has no semantic snapshot").scrollRegions
    }

    /// A drag by one pointer from the page's middle, `distance` points down
    /// (up when negative), in 30 frames, held still for 10 more so it
    /// carries no flick, let go, and left four seconds of frames to settle
    /// and spring back from past an end.
    @MainActor
    private func drag(_ run: Counter, by distance: CGFloat) async throws {
        let start = CGPoint(x: 195, y: 600)
        func step(_ kind: NuxieNativePointerKind?, _ y: CGFloat) async {
            clock += CounterDriverEdgeTests.tick
            let pointers = kind.map {
                [NuxieNativePointerEvent(kind: $0, x: Float(start.x), y: Float(y), pointerID: 1, timestamp: clock)]
            } ?? []
            let touched = await run.edge.shown
            await run.edge.frame(pointers: pointers, on: touched, elapsedSeconds: CounterDriverEdgeTests.tick,
                                 now: run.advance())
        }
        await step(.down, start.y)
        for index in 1...30 {
            await step(.move, start.y + distance * CGFloat(index) / 30)
        }
        for _ in 0..<10 {
            await step(.move, start.y + distance)
        }
        await step(.up, start.y + distance)
        for _ in 0..<240 {
            await step(nil, 0)
        }
        let fault = await run.edge.fault
        XCTAssertNil(fault, "a frame of the drag faulted")
    }

    /// The `views-scroll` paywall's three program files as copied, shown as
    /// a cover.
    static func viewsScroll() throws -> NuxieMachinePlanSource {
        let files = try ["main", "paywall", "plan-card"].map { name in
            let url = try XCTUnwrap(Bundle(for: SheetPanTests.self).url(
                forResource: name, withExtension: "nux", subdirectory: "views-scroll"),
                "the test bundle carries views-scroll/\(name).nux")
            return NuxieMachineSourceFile(path: "\(name).nux", text: try String(contentsOf: url, encoding: .utf8))
        }
        return NuxieMachinePlanSource(files: files, assets: [], root: "main", app: "app", experience: "quietly",
                                      version: 1)
    }
}
#endif
