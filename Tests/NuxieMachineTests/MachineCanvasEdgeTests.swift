#if os(iOS) && !targetEnvironment(macCatalyst)
import CoreGraphics
import Foundation
import XCTest
import NuxieMachine
import NuxieRuntime

/// What a presented surface shows where its page paints nothing: the
/// canvas the edge reports for the presentation, CSS's `Canvas`, opaque
/// white. A Screen's view clears its surface to it before each draw, as
/// Chrome paints the page's white base behind the top-level page. Each
/// frame here is drawn over the canvas the edge holds for what is shown,
/// with no window, read back and kept as an attachment.
final class MachineCanvasEdgeTests: XCTestCase {
    static let white: UInt32 = 0xFFFF_FFFF
    /// How far a channel may be from the color expected, as the other
    /// pixel checks allow.
    private static let tolerance = 3

    /// A cover whose page writes no `background-color` and whose title
    /// writes no `color`: the title is read, dark, on the white canvas.
    func testAPageWithNoBackgroundReadsItsText() async throws {
        let run = try Counter(plan: Self.plan(named: "quiet", page: """
            component Quiet
              view
                column padding=40
                  text "Quiet hours" font-size=32 id="title"
            """))
        do {
            let drawing = try await Self.opened(run)
            XCTAssertEqual(drawing.canvas, Self.white, "the cover's canvas is not opaque white")
            let read = try await DrawnFrame.read(drawing.player, reported: [], name: "canvas-quiet",
                                                 clearColor: drawing.canvas)
            let title = try read.box(of: "Quiet hours")
            let look = try await Self.look(drawing, "canvas-quiet-pixels")
            XCTAssertTrue(Self.close(look.color(at: CGPoint(x: 20, y: 400)), 0xFF_FFFF),
                          "the ground is #\(Self.hex(look.color(at: CGPoint(x: 20, y: 400)))), not white")
            let ink = look.darkest(in: title)
            XCTAssertTrue([16, 8, 0].allSatisfy { (ink >> UInt32($0)) & 0xFF < 0x60 },
                          "the title's darkest ink is #\(Self.hex(ink)), not dark")
            try await run.close()
        } catch {
            try? await run.close()
            throw error
        }
    }

    /// Card is presented by a route of its own, so it has a canvas, and is
    /// also used inside a page painted #0d1214. The use paints nothing
    /// behind itself: inside it, where Card paints nothing, the page shows.
    func testANestedUsePaintsNothingBehindItself() async throws {
        let run = try Counter(plan: Self.plan(named: "page", props: "(more=more)", also: """
                card  Card  sheet
            """, actions: """

              action more
                go(card)
            """, page: """
            component Page
              props
                more: action

              view
                column width=100% height=100% padding=40 gap=20 align-items=flex-start background-color=#0d1214
                  Card
                  button id="more" press=more
                    text "More" color=#eef3f1

            component Card
              view
                column width=200 height=120
                  text "Card" color=#eef3f1
            """))
        do {
            let drawing = try await Self.opened(run)
            XCTAssertEqual(drawing.canvas, Self.white, "the page's canvas is not opaque white")
            let look = try await Self.look(drawing, "canvas-nested")
            // Inside the card (40...240, 40...160), right of and below its
            // one line.
            let inside = look.color(at: CGPoint(x: 220, y: 150))
            XCTAssertTrue(Self.close(inside, 0x0D_1214), "inside the nested Card is #\(Self.hex(inside)), not #0d1214")
            try await run.close()
        } catch {
            try? await run.close()
            throw error
        }
    }

    /// A cover whose root is painted half-transparent red: it reads over the
    /// white canvas, about (255, 127, 127).
    func testATranslucentRootReadsOverWhite() async throws {
        let run = try Counter(plan: Self.plan(named: "tint", page: """
            component Tint
              view
                column width=100% height=100% background-color=#ff000080
            """))
        do {
            let drawing = try await Self.opened(run)
            let look = try await Self.look(drawing, "canvas-translucent")
            let got = look.color(at: CGPoint(x: 195, y: 422))
            XCTAssertTrue(Self.close(got, 0xFF_7F7F), "the root reads #\(Self.hex(got)), not about #ff7f7f")
            try await run.close()
        } catch {
            try? await run.close()
            throw error
        }
    }

    // MARK: Helpers

    /// A root that presents `page`'s first component as a cover when the app
    /// sends `opened`, with the routes in `also` and the actions in
    /// `actions` beside it, and `page` after it.
    private static func plan(named route: String, props: String = "", also: String = "", actions: String = "",
                             page: String) -> NuxieMachinePlanSource {
        let component = page.split(separator: "\n").first.map { $0.replacingOccurrences(of: "component ", with: "") }
            ?? ""
        let main = """
            component App
              platforms ios android

              entry
                on event "opened"
                do open

              routes
                \(route)  \(component)\(props)  cover
            \(also)
              action open
                go(\(route))
            \(actions)

            \(page)

            """
        return NuxieMachinePlanSource(files: [NuxieMachineSourceFile(path: "main.nux", text: main)],
                                      assets: [], root: "main", app: "app", experience: "canvas", version: 1)
    }

    /// The cover opened, laid out at a phone's size, its first step taken,
    /// and what the edge draws for it with its canvas.
    private static func opened(_ run: Counter) async throws
        -> (player: NuxieNativeRuntime, canvas: UInt32) {
        await run.edge.start(event: "opened", now: run.now)
        let fault = await run.edge.fault
        XCTAssertNil(fault, "the start faulted")
        try await run.layOut()
        let top = await run.edge.shown
        let shown = try XCTUnwrap(top, "nothing is presented")
        await run.edge.frame(on: shown, elapsedSeconds: CounterDriverEdgeTests.tick, now: run.advance())
        let drawing = await run.edge.drawing(for: shown)
        return try XCTUnwrap(drawing, "the edge draws nothing for what it shows")
    }

    /// The frame drawn over the presentation's canvas, at the phone's size.
    private static func look(_ drawing: (player: NuxieNativeRuntime, canvas: UInt32),
                             _ name: String) async throws -> Look {
        let width = Look.scale * Int(Look.size.width)
        let height = Look.scale * Int(Look.size.height)
        let (pixels, _) = try await Pixels.render(drawing.player, width: width, height: height,
                                                  scale: Float(Look.scale), clearColor: drawing.canvas,
                                                  capturesSemantics: false)
        try await Pixels.attach(pixels, width: width, height: height, name: name)
        return Look(pixels: pixels, nodes: [])
    }

    private static func close(_ got: UInt32, _ want: UInt32) -> Bool {
        [16, 8, 0].allSatisfy { shift in
            abs(Int((got >> UInt32(shift)) & 0xFF) - Int((want >> UInt32(shift)) & 0xFF)) <= tolerance
        }
    }

    private static func hex(_ color: UInt32) -> String {
        String(format: "%06x", color)
    }
}

private extension Look {
    /// The darkest color drawn in `box`, in points, as 0xRRGGBB.
    func darkest(in box: CGRect) -> UInt32 {
        var darkest: UInt32 = 0xFF_FFFF
        var least = Int.max
        for y in stride(from: Int(box.minY.rounded(.down)), through: Int(box.maxY.rounded(.up)), by: 1) {
            for x in stride(from: Int(box.minX.rounded(.down)), through: Int(box.maxX.rounded(.up)), by: 1) {
                guard x >= 0, y >= 0, x < Int(Look.size.width), y < Int(Look.size.height) else { continue }
                let drawn = color(at: CGPoint(x: x, y: y))
                let sum = Int(drawn >> 16 & 0xFF) + Int(drawn >> 8 & 0xFF) + Int(drawn & 0xFF)
                if sum < least {
                    least = sum
                    darkest = drawn
                }
            }
        }
        return darkest
    }
}
#endif
