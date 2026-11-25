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
///
/// The person's text size takes the same path, as one more field of the
/// environment: told before the start and again on a change, once per
/// value. Stillwater's headline is sized in `rem`, so its height, read from
/// the frame's semantic snapshot, grows with the size told. A window's
/// trait override stands in for the person's setting.
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
                await edge.environment(NuxieMachineEnvironment(dark: told, textSize: 17), now: Self.nine)
                let log = await edge.log
                XCTAssertEqual(log, [.environment(NuxieMachineEnvironment(dark: told, textSize: 17))],
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
        await edge.environment(NuxieMachineEnvironment(dark: false, textSize: 17), now: now)
        await edge.start(event: "onboarding_completed", now: now)
        try await Self.layOut(edge)
        try await Self.settle(edge, now: now)
        let light = try await Self.look(edge, "open-light")
        try Self.expect(light, drawnIn: .light, "opened in light")

        now += 1000
        await edge.environment(NuxieMachineEnvironment(dark: true, textSize: 17), now: now)
        let asks = await edge.waitingForFrame()
        XCTAssertTrue(asks, "a change of scheme while open asks for no frame")
        await edge.frame(elapsedSeconds: StillwaterPaywallEdgeTests.tick, now: now)
        let dark = try await Self.look(edge, "switched-dark")
        try Self.expect(dark, drawnIn: .dark, "the frame after the change")
        XCTAssertEqual(dark.reading, light.reading, "what a screen reader reads changed with the scheme")
        let stillAsks = await edge.waitingForFrame()
        XCTAssertFalse(stillAsks, "one frame did not draw the change")

        now += 1000
        await edge.environment(NuxieMachineEnvironment(dark: true, textSize: 17), now: now)
        let again = await edge.waitingForFrame()
        XCTAssertFalse(again, "the same environment again wrote something")
        await edge.frame(elapsedSeconds: StillwaterPaywallEdgeTests.tick, now: now)
        let darkAgain = try await Self.look(edge, "dark-again")
        try Self.expect(darkAgain, drawnIn: .dark, "the same environment again")

        now += 1000
        await edge.environment(NuxieMachineEnvironment(dark: false, textSize: 17), now: now)
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
            let told = try XCTUnwrap(presenter.environment, "nothing was told before the start")
            XCTAssertEqual(told.dark, dark, "a \(mode) app on a phone in \(phone.rawValue)")
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
        XCTAssertEqual(presenter.environment?.dark, false)

        window.overrideUserInterfaceStyle = .dark
        window.layoutIfNeeded()
        presenter.environmentChanged()
        try await waitUntil("the session is told dark") { presenter.environment?.dark == true }

        // Said again and again, with frames running between: nothing more.
        for _ in 0..<3 {
            presenter.environmentChanged()
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        var told = await Self.environments(edge)
        XCTAssertEqual(told, [false, true], "the same scheme was told more than once")

        window.overrideUserInterfaceStyle = .light
        window.layoutIfNeeded()
        presenter.environmentChanged()
        try await waitUntil("the session is told light") { presenter.environment?.dark == false }
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
        controller.onEnvironmentChange = { changes += 1 }
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

    // MARK: The text size

    /// The size the presenter tells is UIKit's body size for the traits:
    /// 17 at the default size, 23 at the largest standard size and 53 at the
    /// largest accessibility size, Dynamic Type's own body sizes.
    @MainActor
    func testTheTextSizeIsUIKitsBodySize() {
        let sizes: [(UIContentSizeCategory, Double)] = [
            (.large, 17), (.extraExtraExtraLarge, 23), (.accessibilityExtraExtraExtraLarge, 53),
        ]
        for (category, points) in sizes {
            let traits = UITraitCollection(preferredContentSizeCategory: category)
            XCTAssertEqual(NuxieMachineSheetPresenter.bodyTextSize(in: traits), points, accuracy: 0.5,
                           "the body size at \(category.rawValue)")
        }
    }

    /// A text size told before the start sizes the start's first frame: the
    /// headline, whose size and line height are in `rem`, is taller at 23
    /// than at 17, and the plans still sit below it, in order, with the buy
    /// button below them.
    func testATextSizeToldBeforeTheStartSizesTheFirstFrame() async throws {
        var titles: [Double: CGRect] = [:]
        for points in [17.0, 23.0] {
            let edge = try NuxieMachineEdge(plan: Fixture.load(), store: NuxieMachineStandInStore(),
                                            onReport: { _ in })
            await edge.environment(NuxieMachineEnvironment(dark: false, textSize: points), now: Self.nine)
            await edge.start(event: "onboarding_completed", now: Self.nine)
            try await Self.layOut(edge)
            await edge.frame(elapsedSeconds: StillwaterPaywallEdgeTests.tick, now: Self.nine)
            let first = try await Self.look(edge, "text-size-first-frame-\(Int(points))")
            titles[points] = try first.region(of: Self.headline)
            try Self.expectInOrder(first, "the first frame at \(points)")
            try await edge.close()
        }
        let at17 = try XCTUnwrap(titles[17]), at23 = try XCTUnwrap(titles[23])
        XCTAssertGreaterThan(at23.height, at17.height * 1.2,
                             "the headline is \(at23.height) tall at 23 and \(at17.height) at 17")
    }

    /// Open at 17, then 23 while the paywall is open: the edge asks for the
    /// frame that draws it, and in that frame the headline is taller, the
    /// engine having measured its text again, with the same reading. 23
    /// again writes nothing and asks for no frame. 17 again draws the
    /// headline as tall as it first was.
    func testATextSizeChangeWhileOpenIsMeasuredInTheNextFrameAndTheSameAgainWritesNothing() async throws {
        let edge = try NuxieMachineEdge(plan: Fixture.load(), store: NuxieMachineStandInStore(), onReport: { _ in })
        var now = Self.nine
        await edge.environment(NuxieMachineEnvironment(dark: false, textSize: 17), now: now)
        await edge.start(event: "onboarding_completed", now: now)
        try await Self.layOut(edge)
        try await Self.settle(edge, now: now)
        let at17 = try await Self.look(edge, "text-size-open-17")
        let title17 = try at17.region(of: Self.headline)

        now += 1000
        await edge.environment(NuxieMachineEnvironment(dark: false, textSize: 23), now: now)
        let asks = await edge.waitingForFrame()
        XCTAssertTrue(asks, "a change of text size while open asks for no frame")
        await edge.frame(elapsedSeconds: StillwaterPaywallEdgeTests.tick, now: now)
        let at23 = try await Self.look(edge, "text-size-changed-23")
        let title23 = try at23.region(of: Self.headline)
        XCTAssertGreaterThan(title23.height, title17.height * 1.2,
                             "the headline is \(title23.height) tall after the change, \(title17.height) before")
        try Self.expectInOrder(at23, "the frame after the change")
        XCTAssertEqual(at23.reading, at17.reading, "what a screen reader reads changed with the text size")
        let stillAsks = await edge.waitingForFrame()
        XCTAssertFalse(stillAsks, "one frame did not draw the change")

        now += 1000
        await edge.environment(NuxieMachineEnvironment(dark: false, textSize: 23), now: now)
        let again = await edge.waitingForFrame()
        XCTAssertFalse(again, "the same text size again wrote something")

        now += 1000
        await edge.environment(NuxieMachineEnvironment(dark: false, textSize: 17), now: now)
        await edge.frame(elapsedSeconds: StillwaterPaywallEdgeTests.tick, now: now)
        let back = try await Self.look(edge, "text-size-back-17")
        XCTAssertEqual(try back.region(of: Self.headline).height, title17.height, accuracy: 0.5,
                       "17 again does not draw the headline as it first was")

        let open = try await edge.recordOpen()
        XCTAssertTrue(open, "a change of text size ended the record")
        let plan = try await edge.slot("plan")
        XCTAssertEqual(plan, .enumeration("annual"), "a change of text size moved the record")
        let fault = await edge.fault
        XCTAssertNil(fault)
        try await edge.close()
    }

    /// The presenter tells the text size the host's traits give, before the
    /// start, and again before the next frame after it changes; the same
    /// size is told once, however many times a Screen says its traits
    /// changed. The scheme stays as it was throughout. A window's trait
    /// override stands in for the person's setting (iOS 17 or later).
    @MainActor
    func testThePresenterTellsEachTextSizeOnce() async throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("trait overrides need iOS 17") }
        let (host, window) = Self.host(.light)
        window.traitOverrides.preferredContentSizeCategory = .large
        host.updateTraitsIfNeeded()
        let presenter = NuxieMachineSheetPresenter(host: host) { _ in }
        await presenter.start(plan: Self.waitsForTheEvening, store: NuxieMachineStandInStore(), event: "go")
        let edge = try XCTUnwrap(presenter.edge)
        let first = try XCTUnwrap(presenter.environment, "nothing was told before the start")
        XCTAssertEqual(first.textSize, 17, accuracy: 0.5, "the default size was not told before the start")
        let log = await edge.log
        XCTAssertEqual(log.first, .environment(first), "the environment was not told before the start: \(log)")

        window.traitOverrides.preferredContentSizeCategory = .extraExtraExtraLarge
        window.layoutIfNeeded()
        host.updateTraitsIfNeeded()
        presenter.environmentChanged()
        try await waitUntil("the session is told 23") { abs((presenter.environment?.textSize ?? 0) - 23) < 0.5 }

        // Said again and again, with frames running between: nothing more.
        for _ in 0..<3 {
            presenter.environmentChanged()
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        var told = await Self.textSizes(edge)
        Self.expect(told, [17, 23], "the same text size was told more than once")

        window.traitOverrides.preferredContentSizeCategory = .large
        window.layoutIfNeeded()
        host.updateTraitsIfNeeded()
        presenter.environmentChanged()
        try await waitUntil("the session is told 17") { abs((presenter.environment?.textSize ?? 0) - 17) < 0.5 }
        told = await Self.textSizes(edge)
        Self.expect(told, [17, 23, 17], "a change and its return are not each told once")
        let schemes = await Self.environments(edge)
        XCTAssertEqual(schemes, [false, false, false], "a change of text size changed the scheme")
        let open = try await edge.recordOpen()
        XCTAssertTrue(open, "a change of text size ended the record")

        // A host already at the largest standard size: 23 is told before the
        // start.
        let (larger, largerWindow) = Self.host(.light)
        largerWindow.traitOverrides.preferredContentSizeCategory = .extraExtraExtraLarge
        larger.updateTraitsIfNeeded()
        let second = NuxieMachineSheetPresenter(host: larger) { _ in }
        await second.start(plan: Self.waitsForTheEvening, store: NuxieMachineStandInStore(), event: "go")
        let secondEdge = try XCTUnwrap(second.edge)
        let toldFirst = await Self.textSizes(secondEdge)
        Self.expect(toldFirst, [23], "23 was not told before the start")
        withExtendedLifetime((window, largerWindow)) {}
    }

    /// A Screen says when its text size changes, and only then, as it says
    /// when its colors change: the window's size category changing is a
    /// change, the same category again and a change of safe area are not.
    @MainActor
    func testAScreenSaysWhenItsTextSizeChanges() async throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("trait overrides need iOS 17") }
        let edge = try NuxieMachineEdge(plan: Self.waitsForTheEvening, store: NuxieMachineStandInStore(),
                                        onReport: { _ in })
        let loop = NuxieMachineScreenLoop(edge: edge)
        let presented = NuxieMachinePresented(shown: NuxieMachineShown(journey: 1, instance: 1), route: "screen",
                                              presentation: .sheet)
        let controller = NuxieMachineScreenViewController(presenting: presented, loop: loop)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.overrideUserInterfaceStyle = .light
        window.traitOverrides.preferredContentSizeCategory = .large
        window.rootViewController = controller
        window.isHidden = false
        window.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        // Counted from here: joining the window is not the person changing
        // their text size.
        var changes = 0
        controller.onEnvironmentChange = { changes += 1 }

        window.traitOverrides.preferredContentSizeCategory = .extraExtraExtraLarge
        window.layoutIfNeeded()
        try await waitUntil("the Screen says its text size changed") { changes == 1 }
        XCTAssertEqual(NuxieMachineSheetPresenter.bodyTextSize(in: controller.traitCollection), 23, accuracy: 0.5)

        window.traitOverrides.preferredContentSizeCategory = .extraExtraExtraLarge
        window.layoutIfNeeded()
        controller.additionalSafeAreaInsets = UIEdgeInsets(top: 1, left: 0, bottom: 0, right: 0)
        window.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(changes, 1, "a Screen said its text size changed when it did not")
        loop.stop()
        withExtendedLifetime(window) {}
    }

    // MARK: Helpers

    /// The paywall's headline, as the fallback arm writes it.
    private static let headline = "Ten quiet minutes,"

    /// The headline, the two plans and the buy button, top to bottom, each
    /// below the one before it.
    private static func expectInOrder(_ look: Look, _ what: String) throws {
        let boxes = try [headline, "Yearly", "Monthly", "Continue"].map { try look.region(of: $0) }
        for (above, below) in zip(boxes, boxes.dropFirst()) {
            XCTAssertLessThanOrEqual(above.maxY, below.minY + 0.5, "\(what): \(above) runs into \(below)")
        }
    }

    /// The text size of each environment the edge took, in order.
    private static func textSizes(_ edge: NuxieMachineEdge) async -> [Double] {
        await edge.log.compactMap { entry in
            if case .environment(let environment) = entry { return environment.textSize }
            return nil
        }
    }

    /// `told` is `want`, one size for one, each within half a point.
    private static func expect(_ told: [Double], _ want: [Double], _ message: String) {
        XCTAssertTrue(told.count == want.count && zip(told, want).allSatisfy { abs($0 - $1) < 0.5 },
                      "\(message): told \(told), not \(want)")
    }

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
