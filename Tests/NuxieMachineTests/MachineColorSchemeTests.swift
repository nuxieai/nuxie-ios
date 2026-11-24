#if os(iOS) && !targetEnvironment(macCatalyst)
import CoreGraphics
import Foundation
import UIKit
import XCTest
import NuxieMachine
import NuxieRuntime

/// Light and dark on the machine path, on a simulator with no window of the
/// host's: the session is told the client's environment, and Stillwater's
/// paywall, whose every color is a light and dark pair, is drawn in it.
///
/// Three colors are read from each frame, each at a point that only it
/// covers: the page's ground (`night`), the Monthly card's face (`panel`)
/// and the buy button's (`mint`). Each must be its scheme's half of the
/// pair, within `tolerance` in every channel.
///
/// The presenter's own checks use a host in a window whose style stands in
/// for the phone's setting, and a plan that presents nothing, so no sheet
/// is needed: what the presenter tells the session is read from its edge's
/// log.
final class MachineColorSchemeTests: XCTestCase {
    private static let nine: Int64 = 9 * 3_600_000
    private static let tolerance = 3

    /// Stillwater's pairs for the three colors read, from `paywall.nux`.
    private struct Palette {
        let night: UInt32
        let panel: UInt32
        let mint: UInt32

        static let light = Palette(night: 0xF6F8F7, panel: 0xFFFFFF, mint: 0x2F7D63)
        static let dark = Palette(night: 0x0D1214, panel: 0x151C1F, mint: 0x9FCDB9)
    }

    // MARK: The session, told directly

    /// Dark told before the start: the start's first frame, the only one
    /// stepped, is already dark. Told nothing, or light, it is light.
    func testDarkToldBeforeTheStartDrawsTheFirstFrameDark() async throws {
        for (told, palette) in [(nil, Palette.light), (false, .light), (true, .dark)] as [(Bool?, Palette)] {
            let edge = try NuxieMachineEdge(plan: Fixture.load(), store: NuxieMachineStandInStore(),
                                            onReport: { _ in })
            if let told {
                await edge.environment(NuxieMachineEnvironment(dark: told), now: Self.nine)
                let log = await edge.log
                XCTAssertEqual(log, [.environment(NuxieMachineEnvironment(dark: told))],
                               "before the start the session keeps the environment and leaves no rows")
            }
            await edge.start(event: "onboarding_completed", now: Self.nine)
            try await Self.layOut(edge)
            await edge.frame(elapsedSeconds: StillwaterPaywallEdgeTests.tick, now: Self.nine)
            let first = try await Self.look(edge, "first-frame-told-\(told.map { "\($0)" } ?? "nothing")")
            try Self.expect(first, drawnIn: palette, "the first frame, told \(String(describing: told))")
            try await edge.close()
        }
    }

    /// Open in light, then dark while the paywall is open: the edge asks
    /// for the frame that draws it, and that frame is dark, with the same
    /// reading. Dark again writes nothing, and asks for no frame: the
    /// machine itself makes the same environment harmless. Light again
    /// draws light.
    func testAChangeWhileOpenIsDrawnInTheNextFrameAndTheSameAgainWritesNothing() async throws {
        let edge = try NuxieMachineEdge(plan: Fixture.load(), store: NuxieMachineStandInStore(), onReport: { _ in })
        var now = Self.nine
        await edge.environment(NuxieMachineEnvironment(dark: false), now: now)
        await edge.start(event: "onboarding_completed", now: now)
        try await Self.layOut(edge)
        try await Self.settle(edge, now: now)
        let light = try await Self.look(edge, "open-light")
        try Self.expect(light, drawnIn: .light, "opened in light")

        now += 1000
        await edge.environment(NuxieMachineEnvironment(dark: true), now: now)
        let asks = await edge.waitingForFrame()
        XCTAssertTrue(asks, "a change of scheme while open asks for no frame")
        await edge.frame(elapsedSeconds: StillwaterPaywallEdgeTests.tick, now: now)
        let dark = try await Self.look(edge, "switched-dark")
        try Self.expect(dark, drawnIn: .dark, "the frame after the change")
        XCTAssertEqual(dark.reading, light.reading, "what a screen reader reads changed with the scheme")
        let stillAsks = await edge.waitingForFrame()
        XCTAssertFalse(stillAsks, "one frame did not draw the change")

        now += 1000
        await edge.environment(NuxieMachineEnvironment(dark: true), now: now)
        let again = await edge.waitingForFrame()
        XCTAssertFalse(again, "the same environment again wrote something")
        await edge.frame(elapsedSeconds: StillwaterPaywallEdgeTests.tick, now: now)
        let darkAgain = try await Self.look(edge, "dark-again")
        try Self.expect(darkAgain, drawnIn: .dark, "the same environment again")

        now += 1000
        await edge.environment(NuxieMachineEnvironment(dark: false), now: now)
        await edge.frame(elapsedSeconds: StillwaterPaywallEdgeTests.tick, now: now)
        let lightAgain = try await Self.look(edge, "light-again")
        try Self.expect(lightAgain, drawnIn: .light, "light again")

        let open = try await edge.recordOpen()
        XCTAssertTrue(open, "a change of scheme ended the record")
        let plan = try await edge.slot("plan")
        XCTAssertEqual(plan, .enumeration("annual"), "a change of scheme moved the record")
        let fault = await edge.fault
        XCTAssertNil(fault)
        try await edge.close()
    }

    // MARK: The presenter

    /// The app's fixed scheme overrides the phone, and `system` follows it:
    /// whichever it is, the session is told before its start, as the first
    /// entry of its edge's log.
    @MainActor
    func testAFixedSchemeOverridesThePhoneAndSystemFollowsIt() async throws {
        let cases: [(phone: UIUserInterfaceStyle, mode: ExperienceColorSchemeMode, dark: Bool)] = [
            (.light, .system, false),
            (.dark, .system, true),
            (.light, .dark, true),
            (.dark, .light, false),
        ]
        for (phone, mode, dark) in cases {
            let (host, window) = Self.host(phone)
            let presenter = NuxieMachineSheetPresenter(host: host) { _ in }
            presenter.colorSchemeMode = mode
            await presenter.start(plan: Self.waitsForTheEvening, store: NuxieMachineStandInStore(), event: "go")
            let told = NuxieMachineEnvironment(dark: dark)
            XCTAssertEqual(presenter.environment, told, "a \(mode) app on a phone in \(phone.rawValue)")
            let log = try await XCTUnwrap(presenter.edge).log
            XCTAssertEqual(log.first, .environment(told), "the environment was not told before the start: \(log)")
            XCTAssertTrue(log.contains { if case .wakeAt = $0 { true } else { false } }, "the start ran: \(log)")
            withExtendedLifetime(window) {}
        }
    }

    /// With `system`, the phone turning dark is told before the next frame,
    /// and light again after it. The same scheme is told once, however many
    /// times a Screen says its traits changed: the presenter reads the
    /// scheme before every frame and tells only a change, as the SDK's
    /// experience screens push only a change.
    @MainActor
    func testSystemFollowsThePhoneAndTellsEachSchemeOnce() async throws {
        let (host, window) = Self.host(.light)
        let presenter = NuxieMachineSheetPresenter(host: host) { _ in }
        await presenter.start(plan: Self.waitsForTheEvening, store: NuxieMachineStandInStore(), event: "go")
        let edge = try XCTUnwrap(presenter.edge)
        XCTAssertEqual(presenter.environment, NuxieMachineEnvironment(dark: false))

        window.overrideUserInterfaceStyle = .dark
        window.layoutIfNeeded()
        presenter.colorAppearanceChanged()
        try await waitUntil("the session is told dark") { presenter.environment == NuxieMachineEnvironment(dark: true) }

        // Said again and again, with frames running between: nothing more.
        for _ in 0..<3 {
            presenter.colorAppearanceChanged()
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        var told = await Self.environments(edge)
        XCTAssertEqual(told, [false, true], "the same scheme was told more than once")

        window.overrideUserInterfaceStyle = .light
        window.layoutIfNeeded()
        presenter.colorAppearanceChanged()
        try await waitUntil("the session is told light") { presenter.environment == NuxieMachineEnvironment(dark: false) }
        told = await Self.environments(edge)
        XCTAssertEqual(told, [false, true, false])
        let open = try await edge.recordOpen()
        XCTAssertTrue(open, "a change of scheme ended the record")
        withExtendedLifetime(window) {}
    }

    // MARK: A Screen's own scheme

    /// A Screen says when its colors would change, and only then; it draws
    /// in the scheme forced on it, else in its window's; out of a window,
    /// with nothing forced, in its host's. This is the reading the SDK's
    /// experience screens make, shared.
    @MainActor
    func testAScreenDrawsInItsForcedSchemeOrItsWindowsAndSaysWhenItChanges() async throws {
        let edge = try NuxieMachineEdge(plan: Self.waitsForTheEvening, store: NuxieMachineStandInStore(),
                                        onReport: { _ in })
        let loop = NuxieMachineScreenLoop(edge: edge)
        let presented = NuxieMachinePresented(shown: NuxieMachineShown(journey: 1, instance: 1), route: "screen",
                                              presentation: .sheet)
        let controller = NuxieMachineScreenViewController(presenting: presented, loop: loop)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = controller
        window.isHidden = false
        window.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        // Counted from here: joining the window is not the phone changing.
        var changes = 0
        controller.onColorAppearanceChange = { changes += 1 }
        XCTAssertEqual(ExperienceColorScheme(drawnBy: controller, host: .dark), .light,
                       "in a window, a Screen draws in its own traits, not its host's")

        window.overrideUserInterfaceStyle = .dark
        window.layoutIfNeeded()
        try await waitUntil("the Screen says its colors changed") { changes == 1 }
        XCTAssertEqual(ExperienceColorScheme(drawnBy: controller, host: nil), .dark)

        window.overrideUserInterfaceStyle = .dark
        window.layoutIfNeeded()
        controller.additionalSafeAreaInsets = UIEdgeInsets(top: 1, left: 0, bottom: 0, right: 0)
        window.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(changes, 1, "a Screen said its colors changed when they did not")

        controller.overrideUserInterfaceStyle = ExperienceColorSchemeMode.light.userInterfaceStyle
        window.layoutIfNeeded()
        try await waitUntil("the forced scheme changes the Screen's colors") { changes == 2 }
        XCTAssertEqual(ExperienceColorScheme(drawnBy: controller, host: .dark), .light,
                       "a forced light lost to a dark phone")

        // Out of a window, as a Screen is between being presented and
        // reaching its window.
        let detached = NuxieMachineScreenViewController(presenting: presented, loop: loop)
        detached.loadViewIfNeeded()
        XCTAssertEqual(ExperienceColorScheme(drawnBy: detached, host: .dark), .dark,
                       "out of a window with nothing forced, a Screen draws in its host's scheme")
        detached.overrideUserInterfaceStyle = ExperienceColorSchemeMode.light.userInterfaceStyle
        if #available(iOS 17.0, *) { detached.updateTraitsIfNeeded() }
        detached.view.layoutIfNeeded()
        XCTAssertEqual(ExperienceColorScheme(drawnBy: detached, host: .dark), .light,
                       "out of a window, a forced scheme still wins")
        XCTAssertEqual(ExperienceColorScheme(UIUserInterfaceStyle.unspecified), .light,
                       "an unspecified style draws light")
        loop.stop()
        withExtendedLifetime(window) {}
    }

    // MARK: Helpers

    /// A plan whose start asks for a wake at the next 18:00 and presents
    /// nothing, so its presenter needs no sheet.
    private static let waitsForTheEvening = NuxieMachinePlanSource(
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

    /// A host view controller, the root of a window whose style stands in
    /// for the phone's.
    @MainActor
    private static func host(_ phone: UIUserInterfaceStyle) -> (UIViewController, UIWindow) {
        let host = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.overrideUserInterfaceStyle = phone
        window.rootViewController = host
        window.isHidden = false
        window.layoutIfNeeded()
        return (host, window)
    }

    /// The `dark` of each environment the edge took, in order.
    private static func environments(_ edge: NuxieMachineEdge) async -> [Bool] {
        await edge.log.compactMap { entry in
            if case .environment(let environment) = entry { return environment.dark }
            return nil
        }
    }

    /// Lay the paywall out at a phone's size and size its renderer for a
    /// frame drawn at twice that, as a Screen's view does.
    private static func layOut(_ edge: NuxieMachineEdge) async throws {
        let screen = try await top(edge)
        try await screen.setLayoutSize(width: Float(Look.size.width), height: Float(Look.size.height))
        _ = try await screen.resize(pixelWidth: UInt32(Look.scale) * UInt32(Look.size.width),
                                    pixelHeight: UInt32(Look.scale) * UInt32(Look.size.height))
    }

    private static func settle(_ edge: NuxieMachineEdge, now: Int64) async throws {
        for _ in 0..<3 {
            await edge.frame(elapsedSeconds: StillwaterPaywallEdgeTests.tick, now: now)
        }
    }

    private static func top(_ edge: NuxieMachineEdge) async throws -> NuxieNativeRuntime {
        let screen = await edge.screen()
        return try XCTUnwrap(screen, "nothing is presented")
    }

    /// The paywall drawn now, kept as a PNG attachment named `scheme-<name>`.
    private static func look(_ edge: NuxieMachineEdge, _ name: String) async throws -> Look {
        let runtime = try await top(edge)
        let width = Look.scale * Int(Look.size.width)
        let height = Look.scale * Int(Look.size.height)
        let (pixels, semantics) = try await Pixels.render(runtime, width: width, height: height,
                                                          scale: Float(Look.scale), capturesSemantics: true)
        try await Pixels.attach(pixels, width: width, height: height, name: "scheme-\(name)")
        let capture = try XCTUnwrap(semantics, "the frame has no semantic snapshot")
        return Look(pixels: pixels, nodes: capture.tree.visibleReadingOrder)
    }

    /// The page's ground, the Monthly card's face and the buy button's
    /// face, each its scheme's half of the pair.
    private static func expect(_ look: Look, drawnIn palette: Palette, _ what: String) throws {
        let card = try look.region(of: "Monthly")
        let buy = try look.region(of: "Continue")
        let points: [(String, CGPoint, UInt32)] = [
            ("the ground", CGPoint(x: 12, y: 30), palette.night),
            ("the Monthly card", CGPoint(x: card.minX + 6, y: card.midY), palette.panel),
            ("the buy button", CGPoint(x: buy.minX + 14, y: buy.midY), palette.mint),
        ]
        for (name, point, want) in points {
            let got = look.color(at: point)
            XCTAssertTrue(close(got, want), "\(what): \(name) is #\(hex(got)), not #\(hex(want))")
        }
    }

    private static func close(_ got: UInt32, _ want: UInt32) -> Bool {
        [16, 8, 0].allSatisfy { shift in
            abs(Int((got >> UInt32(shift)) & 0xFF) - Int((want >> UInt32(shift)) & 0xFF)) <= tolerance
        }
    }

    private static func hex(_ color: UInt32) -> String {
        String(format: "%06x", color)
    }

    @MainActor
    private func waitUntil(_ what: String, seconds: Double = 10, _ done: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !done() {
            guard Date() < deadline else { return XCTFail("timed out waiting until \(what)") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

extension Look {
    /// The color drawn at `point`, in points, as 0xRRGGBB: the frame is
    /// BGRA rows at `scale` pixels a point.
    func color(at point: CGPoint) -> UInt32 {
        let width = Look.scale * Int(Look.size.width)
        let x = Int(point.x.rounded(.down)) * Look.scale
        let y = Int(point.y.rounded(.down)) * Look.scale
        let at = pixels.startIndex + (y * width + x) * 4
        let blue = UInt32(pixels[at])
        let green = UInt32(pixels[at + 1])
        let red = UInt32(pixels[at + 2])
        return red << 16 | green << 8 | blue
    }
}
#endif
