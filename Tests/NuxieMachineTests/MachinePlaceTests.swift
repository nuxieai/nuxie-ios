#if os(iOS) && !targetEnvironment(macCatalyst)
import CoreGraphics
import Foundation
import UIKit
import XCTest
import NuxieMachine
import NuxieRuntime

/// Where each presentation is shown, on a simulator with no window of the
/// host's: the session is told a presentation's place, and Stillwater's
/// paywall, whose page is padded by its safe area's top and bottom insets,
/// is drawn in it.
///
/// The oracle is the page's padding: told a top inset, the headline sits
/// that much lower than told none; told a bottom inset, "Not now" sits that
/// much higher. Each look is kept as a PNG attachment named `place-<name>`.
///
/// What a Screen says its place is, and what the presenter tells once, are
/// checked on their own: a Screen in a window at a phone's size, as a cover
/// and as a sheet, and the presenter's record of what it last told.
final class MachinePlaceTests: XCTestCase {
    private static let nine: Int64 = 9 * 3_600_000
    private static let tolerance: CGFloat = 0.5

    /// A cover on a phone held upright: the status bar's inset above, the
    /// home indicator's below, the whole screen's size.
    private static let upright = NuxieMachineScreenPlace(
        top: 59, right: 0, bottom: 34, left: 0, width: 390, height: 844)
    /// The same cover with the status bar hidden: only the bottom inset.
    private static let barHidden = NuxieMachineScreenPlace(
        top: 0, right: 0, bottom: 34, left: 0, width: 390, height: 844)
    /// Side insets, as a phone on its side has (the sensor's on one side and
    /// the same on the other), told at the upright size so only the insets
    /// differ from a run told none.
    private static let sides = NuxieMachineScreenPlace(
        top: 0, right: 59, bottom: 21, left: 59, width: 390, height: 844)

    // MARK: The edge, told directly

    /// A place told after the start and before the first frame is in that
    /// frame: the headline is lower by the top inset and "Not now" higher by
    /// the bottom inset than in the same frame told none. The place is
    /// logged once, for the presentation it was told for.
    ///
    /// Stillwater presents its paywall as a sheet, and this tells it a
    /// cover's insets on purpose: the edge and the session hold no rule
    /// about which insets a presentation gets, so the page must draw in
    /// whatever place it is told. The presenter tells a sheet zero; that is
    /// checked on a Screen's own place, below.
    func testAPlaceToldBeforeTheFirstFrameIsDrawnInIt() async throws {
        let untold = try await Self.firstFrame(told: nil)
        let told = try await Self.firstFrame(told: Self.upright)
        try Self.expect(told, at: Self.upright, against: untold, "the first frame")
    }

    /// Side insets are drawn too: the page pads all four sides by its
    /// safe area, so the Yearly card, as wide as the content, starts the
    /// left inset further in and ends the right inset further in.
    func testAPlacesSideInsetsAreDrawnInsideThePage() async throws {
        let untold = try await Self.firstFrame(told: nil)
        let told = try await Self.firstFrame(told: Self.sides)
        try Self.expect(told, at: Self.sides, against: untold, "the first frame told side insets")
    }

    /// Told the same place again, the edge writes nothing and asks for no
    /// frame; a different place (the status bar hidden) asks for the frame
    /// that draws it, and that frame has it. The record stays open and on
    /// the same plan.
    func testTheSamePlaceAgainWritesNothingAndANewOneIsDrawnInTheNextFrame() async throws {
        let untold = try await Self.firstFrame(told: nil)
        let edge = try Self.edge()
        var now = Self.nine
        await edge.start(event: "onboarding_completed", now: now)
        let shown = try await Self.top(edge)
        await edge.place(Self.upright, for: shown, now: now)
        try await Self.layOut(edge)
        try await Self.settle(edge, now: now)
        let upright = try await Self.look(edge, "upright")
        try Self.expect(upright, at: Self.upright, against: untold, "upright")

        now += 1000
        let written = await edge.log.count
        await edge.place(Self.upright, for: shown, now: now)
        let same = await edge.waitingForFrame()
        XCTAssertFalse(same, "the same place again wrote something")
        await edge.frame(elapsedSeconds: StillwaterPaywallEdgeTests.tick, now: now)
        let again = try await Self.look(edge, "upright-again")
        try Self.expect(again, at: Self.upright, against: untold, "the same place again")

        now += 1000
        await edge.place(Self.barHidden, for: shown, now: now)
        let asks = await edge.waitingForFrame()
        XCTAssertTrue(asks, "a new place asks for no frame")
        await edge.frame(elapsedSeconds: StillwaterPaywallEdgeTests.tick, now: now)
        let hidden = try await Self.look(edge, "bar-hidden")
        try Self.expect(hidden, at: Self.barHidden, against: untold, "the frame after the status bar hid")
        XCTAssertEqual(hidden.reading, upright.reading, "what a screen reader reads changed with the place")

        let places = await Array(edge.log.dropFirst(written)).compactMap { entry -> NuxieMachineScreenPlace? in
            if case .place(let to, let place) = entry, to == shown { return place }
            return nil
        }
        XCTAssertEqual(places, [Self.upright, Self.barHidden], "each place told is logged as it was taken")
        let open = try await edge.recordOpen()
        XCTAssertTrue(open, "a place ended the record")
        let plan = try await edge.slot("plan")
        XCTAssertEqual(plan, .enumeration("annual"), "a place moved the record")
        let fault = await edge.fault
        XCTAssertNil(fault)
        try await edge.close()
    }

    /// The environment holds no insets and no size: dark told before the
    /// start and after the place leaves the place as it was, and the frame
    /// is drawn dark in it.
    func testTheEnvironmentCarriesNoInsetsOrSize() async throws {
        let untold = try await Self.firstFrame(told: nil)
        let edge = try Self.edge()
        var now = Self.nine
        await edge.environment(NuxieMachineEnvironment(dark: true), now: now)
        await edge.start(event: "onboarding_completed", now: now)
        let shown = try await Self.top(edge)
        await edge.place(Self.upright, for: shown, now: now)
        try await Self.layOut(edge)
        try await Self.settle(edge, now: now)
        let dark = try await Self.look(edge, "dark")
        try Self.expect(dark, at: Self.upright, against: untold, "dark, told before the start")
        let ground = dark.color(at: CGPoint(x: 12, y: 30))
        XCTAssertTrue(Self.close(ground, 0x0D1214), "the page's ground is #\(String(format: "%06x", ground)), not dark")

        now += 1000
        await edge.environment(NuxieMachineEnvironment(dark: false), now: now)
        await edge.frame(elapsedSeconds: StillwaterPaywallEdgeTests.tick, now: now)
        let light = try await Self.look(edge, "light-after")
        try Self.expect(light, at: Self.upright, against: untold, "light, told after the place")
        let fault = await edge.fault
        XCTAssertNil(fault)
        try await edge.close()
    }

    /// A place for a presentation the edge no longer holds goes to no one:
    /// it is logged as dropped, and the session is not asked.
    func testAPlaceForAClosedPresentationIsDropped() async throws {
        let edge = try Self.edge()
        var now = Self.nine
        await edge.start(event: "onboarding_completed", now: now)
        let shown = try await Self.top(edge)
        await edge.place(Self.upright, for: shown, now: now)
        now += 1000
        await edge.closed(shown, now: now)
        let written = await edge.log.count
        now += 1000
        await edge.place(Self.barHidden, for: shown, now: now)
        let late = await Array(edge.log.dropFirst(written)).filter { entry in
            switch entry {
            case .place, .droppedPlace: true
            default: false
            }
        }
        XCTAssertEqual(late, [.droppedPlace(shown)], "a late place reached the session")
        let fault = await edge.fault
        XCTAssertNil(fault, "a late place faulted the edge")
        try await edge.close()
    }

    // MARK: A Screen's place

    /// A cover reaches every edge of the screen, so its place is the
    /// screen's insets and the whole screen's size. A sheet is laid out
    /// inside its safe area, so its place has no insets and the size inside
    /// them.
    @MainActor
    func testACoverIsToldTheScreensInsetsAndASheetNone() throws {
        let loop = try Self.loop()
        for presentation in [NuxieMachinePresentation.cover, .sheet] {
            let (controller, window) = Self.screen(presenting: presentation, loop: loop)
            let insets = controller.view.safeAreaInsets
            XCTAssertGreaterThan(insets.top, 0, "the window's safe area reached the view")
            XCTAssertGreaterThan(insets.bottom, 0, "the window's safe area reached the view")
            let place = try XCTUnwrap(controller.place, "a \(presentation) in a window has a place")
            switch presentation {
            case .cover:
                XCTAssertEqual(place, Self.place(insets, controller.view.bounds.size),
                               "a cover is told the screen's insets and size")
            default:
                let inside = controller.view.bounds.inset(by: insets).size
                XCTAssertEqual(place, Self.place(.zero, inside), "a sheet is told no insets and the size inside them")
            }
            withExtendedLifetime(window) {}
        }
        loop.stop()
    }

    /// A cover turned on its side has the insets and the size of the screen
    /// turned: the status bar's inset goes, the sides take the sensor's, and
    /// width and height swap. Out of a window, a Screen has no place.
    @MainActor
    func testARotatedCoverHasTheTurnedScreensPlace() throws {
        let loop = try Self.loop()
        let (controller, window) = Self.screen(presenting: .cover, loop: loop)
        let upright = try XCTUnwrap(controller.place)

        controller.additionalSafeAreaInsets = UIEdgeInsets(top: 0, left: 59, bottom: 21, right: 59)
        window.frame = CGRect(x: 0, y: 0, width: 844, height: 390)
        controller.view.setNeedsLayout()
        window.layoutIfNeeded()
        let turned = try XCTUnwrap(controller.place)
        XCTAssertEqual(turned, Self.place(controller.view.safeAreaInsets, CGSize(width: 844, height: 390)))
        XCTAssertNotEqual(turned, upright, "turning the screen left the place as it was")
        XCTAssertEqual(turned.width, upright.height)
        XCTAssertEqual(turned.height, upright.width)

        let detached = NuxieMachineScreenViewController(
            presenting: NuxieMachinePresented(shown: NuxieMachineShown(journey: 1, instance: 2), route: "screen",
                                              presentation: .cover),
            loop: loop)
        detached.loadViewIfNeeded()
        XCTAssertNil(detached.place, "a Screen out of a window has a place")
        loop.stop()
        withExtendedLifetime(window) {}
    }

    // MARK: What the presenter tells

    /// Each presentation is told its place once: read again unchanged it is
    /// not told, turned it is told the new one, and one with no place yet is
    /// passed over until it has one. Each is told its own.
    func testEachPlaceIsToldOnceAndEachChangeAgain() {
        let cover = NuxieMachineShown(journey: 1, instance: 1)
        let sheet = NuxieMachineShown(journey: 1, instance: 2)
        let inside = NuxieMachineScreenPlace(top: 0, right: 0, bottom: 0, left: 0, width: 390, height: 751)
        let turned = NuxieMachineScreenPlace(top: 0, right: 59, bottom: 21, left: 59, width: 844, height: 390)
        var told = NuxieMachineToldPlaces()

        var changes = told.changes([(shown: cover, place: Self.upright), (shown: sheet, place: nil)])
        XCTAssertEqual(changes.map { $0.shown }, [cover], "a presentation with no place yet was told one")
        XCTAssertEqual(changes.map { $0.place }, [Self.upright])

        changes = told.changes([(shown: cover, place: Self.upright), (shown: sheet, place: inside)])
        XCTAssertEqual(changes.map { $0.shown }, [sheet], "the cover's same place was told again")
        XCTAssertEqual(changes.map { $0.place }, [inside])

        changes = told.changes([(shown: cover, place: Self.upright), (shown: sheet, place: inside)])
        XCTAssertTrue(changes.isEmpty, "the same places were told again")

        changes = told.changes([(shown: cover, place: turned), (shown: sheet, place: inside)])
        XCTAssertEqual(changes.map { $0.shown }, [cover], "only the place that changed is told")
        XCTAssertEqual(changes.map { $0.place }, [turned])
        XCTAssertEqual(told.places, [cover: turned, sheet: inside])
    }

    /// A closed presentation's place goes with it; a presentation shown
    /// again is a new presentation, and is told its own even where the old
    /// one's was the same.
    func testAClosedPresentationsPlaceGoesAndANewOneIsToldItsOwn() {
        let first = NuxieMachineShown(journey: 1, instance: 1)
        let sheet = NuxieMachineShown(journey: 1, instance: 2)
        let again = NuxieMachineShown(journey: 1, instance: 3)
        let inside = NuxieMachineScreenPlace(top: 0, right: 0, bottom: 0, left: 0, width: 390, height: 751)
        var told = NuxieMachineToldPlaces()
        _ = told.changes([(shown: first, place: Self.upright), (shown: sheet, place: inside)])

        told.keep([sheet])
        XCTAssertEqual(told.places, [sheet: inside], "the closed presentation's place stayed")

        let changes = told.changes([(shown: sheet, place: inside), (shown: again, place: Self.upright)])
        XCTAssertEqual(changes.map { $0.shown }, [again], "a new presentation was not told its place")
        XCTAssertEqual(changes.map { $0.place }, [Self.upright])
        told.keep([])
        XCTAssertTrue(told.places.isEmpty)
    }

    // MARK: Helpers

    private static func edge() throws -> NuxieMachineEdge {
        try NuxieMachineEdge(plan: Fixture.load(), store: NuxieMachineStandInStore(), onReport: { _ in })
    }

    /// Stillwater's first frame, told `told` after the start and before the
    /// frame, or no place at all.
    private static func firstFrame(told: NuxieMachineScreenPlace?) async throws -> Look {
        let edge = try edge()
        await edge.start(event: "onboarding_completed", now: nine)
        if let told {
            let shown = try await top(edge)
            await edge.place(told, for: shown, now: nine)
            // The start opened the paywall's player and no frame has run, so
            // nothing has stepped it: the place is taken before its first
            // step. Each delivery ends with the record's wake, so the place
            // is not the last entry.
            let log = await edge.log
            let opened = log.firstIndex(of: .opened(shown))
            let placed = log.firstIndex(of: .place(shown, told))
            XCTAssertNotNil(placed, "the place was not taken: \(log)")
            XCTAssertLessThan(try XCTUnwrap(opened), try XCTUnwrap(placed),
                              "the place was taken before the player opened: \(log)")
            XCTAssertEqual(log.filter { if case .place = $0 { true } else { false } }.count, 1,
                           "the place was taken more than once: \(log)")
        }
        try await layOut(edge)
        await edge.frame(elapsedSeconds: StillwaterPaywallEdgeTests.tick, now: nine)
        let name = told.map { "first-frame-\(Int($0.top))-\(Int($0.bottom))" } ?? "first-frame-untold"
        let look = try await look(edge, name)
        let fault = await edge.fault
        XCTAssertNil(fault)
        try await edge.close()
        return look
    }

    /// The headline lower by the top inset and "Not now" higher by the
    /// bottom inset than in `untold`, drawn with no place.
    private static func expect(_ look: Look, at place: NuxieMachineScreenPlace, against untold: Look,
                               _ what: String) throws {
        let title = try look.region(of: "Ten quiet minutes,").minY - untold.region(of: "Ten quiet minutes,").minY
        let footer = try untold.region(of: "Not now").maxY - look.region(of: "Not now").maxY
        XCTAssertEqual(title, CGFloat(place.top), accuracy: tolerance,
                       "\(what): the headline moved \(title), not the top inset \(place.top)")
        XCTAssertEqual(footer, CGFloat(place.bottom), accuracy: tolerance,
                       "\(what): \"Not now\" moved up \(footer), not the bottom inset \(place.bottom)")
        // The Yearly card is as wide as the page's content: its left edge
        // moves in by the left inset and its right edge by the right one.
        let left = try look.region(of: "Yearly").minX - untold.region(of: "Yearly").minX
        let right = try untold.region(of: "Yearly").maxX - look.region(of: "Yearly").maxX
        XCTAssertEqual(left, CGFloat(place.left), accuracy: tolerance,
                       "\(what): the Yearly card moved in \(left) on the left, not the left inset \(place.left)")
        XCTAssertEqual(right, CGFloat(place.right), accuracy: tolerance,
                       "\(what): the Yearly card moved in \(right) on the right, not the right inset \(place.right)")
    }

    /// The presentation on top: Stillwater's start presents the paywall.
    private static func top(_ edge: NuxieMachineEdge) async throws -> NuxieMachineShown {
        let shown = await edge.shown
        return try XCTUnwrap(shown, "nothing is presented")
    }

    /// Lay the paywall out at a phone's size and size its renderer for a
    /// frame drawn at twice that, as a Screen's view does.
    private static func layOut(_ edge: NuxieMachineEdge) async throws {
        let screen = try await runtime(edge)
        try await screen.setLayoutSize(width: Float(Look.size.width), height: Float(Look.size.height))
        _ = try await screen.resize(pixelWidth: UInt32(Look.scale) * UInt32(Look.size.width),
                                    pixelHeight: UInt32(Look.scale) * UInt32(Look.size.height))
    }

    private static func settle(_ edge: NuxieMachineEdge, now: Int64) async throws {
        for _ in 0..<3 {
            await edge.frame(elapsedSeconds: StillwaterPaywallEdgeTests.tick, now: now)
        }
    }

    private static func runtime(_ edge: NuxieMachineEdge) async throws -> NuxieNativeRuntime {
        let screen = await edge.screen()
        return try XCTUnwrap(screen, "nothing is presented")
    }

    /// The paywall drawn now, kept as a PNG attachment named `place-<name>`.
    private static func look(_ edge: NuxieMachineEdge, _ name: String) async throws -> Look {
        let runtime = try await runtime(edge)
        let width = Look.scale * Int(Look.size.width)
        let height = Look.scale * Int(Look.size.height)
        let (pixels, semantics) = try await Pixels.render(runtime, width: width, height: height,
                                                          scale: Float(Look.scale), capturesSemantics: true)
        try await Pixels.attach(pixels, width: width, height: height, name: "place-\(name)")
        let capture = try XCTUnwrap(semantics, "the frame has no semantic snapshot")
        return Look(pixels: pixels, nodes: capture.tree.visibleReadingOrder)
    }

    /// A loop over an edge whose session presents nothing, as the
    /// presenter's checks make one: a Screen needs one, and its place is
    /// read from its view alone.
    @MainActor
    private static func loop() throws -> NuxieMachineScreenLoop {
        let plan = NuxieMachinePlanSource(
            files: [NuxieMachineSourceFile(path: "main.nux", text: """
                component App
                  state due = false
                  entry
                    on event "go"
                    do arm
                  action arm
                    due = true
                  wait later
                    while due
                    until next 18:00
                    then fire within 6h
                    else exit
                  action fire
                    due = false

                """)],
            root: "main", app: "app", experience: "evening", version: 1)
        let edge = try NuxieMachineEdge(plan: plan, store: NuxieMachineStandInStore(), onReport: { _ in })
        return NuxieMachineScreenLoop(edge: edge)
    }

    /// A Screen for one presentation, the root of a window at a phone's
    /// size and laid out. Its safe areas are the device's, with a status
    /// bar's and a home indicator's added, so both edges have one.
    @MainActor
    private static func screen(
        presenting presentation: NuxieMachinePresentation, loop: NuxieMachineScreenLoop
    ) -> (NuxieMachineScreenViewController, UIWindow) {
        let presented = NuxieMachinePresented(shown: NuxieMachineShown(journey: 1, instance: 1), route: "screen",
                                              presentation: presentation)
        let controller = NuxieMachineScreenViewController(presenting: presented, loop: loop)
        controller.additionalSafeAreaInsets = UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.isHidden = false
        controller.view.setNeedsLayout()
        window.layoutIfNeeded()
        return (controller, window)
    }

    /// Within three in every channel, as the scheme's checks read a color.
    private static func close(_ got: UInt32, _ want: UInt32) -> Bool {
        [16, 8, 0].allSatisfy { shift in
            abs(Int((got >> UInt32(shift)) & 0xFF) - Int((want >> UInt32(shift)) & 0xFF)) <= 3
        }
    }

    private static func place(_ insets: UIEdgeInsets, _ size: CGSize) -> NuxieMachineScreenPlace {
        NuxieMachineScreenPlace(top: Double(insets.top), right: Double(insets.right), bottom: Double(insets.bottom),
                          left: Double(insets.left), width: Double(size.width), height: Double(size.height))
    }
}
#endif
