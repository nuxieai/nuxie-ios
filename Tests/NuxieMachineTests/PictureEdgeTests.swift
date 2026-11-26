#if os(iOS) && !targetEnvironment(macCatalyst)
import CoreGraphics
import Foundation
import XCTest
import NuxieMachine
import NuxieRuntime

/// `Fixtures/views-picture` on a simulator, with no window: a page that
/// shows the folder's `assets/hero.png` three times, each in a box 200
/// points square, then a "Close" button. The host hands in the folder's
/// one other file as a row (its path, a picture 120 by 60 pixels, its size
/// in bytes) and a byte source for the folder; the edge asks the source for
/// the picture's bytes when it opens the page, and the page is imported
/// with them.
///
/// The picture is four flat quadrants, each 60 by 30 pixels: red
/// (#d83030) at the top left, green (#30a848) at the top right, blue
/// (#3058d8) at the bottom left and yellow (#f0c820) at the bottom right.
/// The page is #0d1214 behind it. The boxes, from the page's top left,
/// with 20 points of padding and 20 between them:
///
/// - `fit=fill`, with `label="Four colors"`, at (20, 20): the picture is
///   stretched to the box, so each quadrant fills a quarter of it.
/// - `fit=cover` at (20, 240): the picture is scaled to cover the box,
///   400 by 200 points, centered, and the box clips the 100 points that
///   reach past it on each side. Each quadrant fills a quarter of the box,
///   as with `fill`: the quadrants meet at the picture's center, which
///   both rules put at the box's center, so their colors agree at every
///   point inside it. What tells `cover` apart is the clip: past the box's
///   left and right edges the page shows, where the picture would reach.
/// - `fit=contain` at (20, 460): the picture is scaled to fit inside the
///   box, 200 by 100 points, centered, so the page shows in a band 50
///   points tall above and below it, where `fill` shows the picture.
final class PictureEdgeTests: XCTestCase {
    static let tick: Float = 1.0 / 60.0

    static let red: UInt32 = 0xD8_3030
    static let green: UInt32 = 0x30_A848
    static let blue: UInt32 = 0x30_58D8
    static let yellow: UInt32 = 0xF0_C820
    static let page: UInt32 = 0x0D_1214

    static let fill = CGRect(x: 20, y: 20, width: 200, height: 200)
    static let cover = CGRect(x: 20, y: 240, width: 200, height: 200)
    static let contain = CGRect(x: 20, y: 460, width: 200, height: 200)

    /// The page opens with the picture's bytes from the folder, and each
    /// box draws the colors its `fit` gives at named points: `fill` all
    /// four quadrants at the box's quarter points; `cover` the same four,
    /// and the page just past the box's left and right edges, where the
    /// picture scaled to cover reaches but the box clips it; `contain` the
    /// four quadrants inside the picture's band, and the page above and
    /// below it, at the points where `fill` shows red and blue.
    func testEachFitDrawsThePicturesColorsWhereItsRuleSays() async throws {
        let run = try PictureRun(bytes: NuxieMachineFolderByteSource(folder: PictureFolder.url()))
        do {
            await run.edge.start(event: "opened", now: run.now)
            let fault = await run.edge.fault
            XCTAssertNil(fault, "the page did not open: \(String(describing: fault))")
            let look = try await run.look("each-fit")

            for (name, box) in [("fill", Self.fill), ("cover", Self.cover)] {
                look.expect([
                    ("top left", Self.point(box, 50, 50), Self.red),
                    ("top right", Self.point(box, 150, 50), Self.green),
                    ("bottom left", Self.point(box, 50, 150), Self.blue),
                    ("bottom right", Self.point(box, 150, 150), Self.yellow),
                ], in: name)
            }
            look.expect([
                ("the band above the picture", Self.point(Self.fill, 50, 25), Self.red),
                ("the band below the picture", Self.point(Self.fill, 50, 175), Self.blue),
            ], in: "fill, where contain shows the page")
            look.expect([
                ("left of the box, where the picture would reach", Self.point(Self.cover, -10, 50), Self.page),
                ("right of the box, where the picture would reach", Self.point(Self.cover, 240, 150), Self.page),
            ], in: "cover, clipped by its box")
            look.expect([
                ("the band above the picture", Self.point(Self.contain, 50, 25), Self.page),
                ("the band below the picture", Self.point(Self.contain, 50, 175), Self.page),
                ("top left", Self.point(Self.contain, 50, 75), Self.red),
                ("top right", Self.point(Self.contain, 150, 75), Self.green),
                ("bottom left", Self.point(Self.contain, 50, 125), Self.blue),
                ("bottom right", Self.point(Self.contain, 150, 125), Self.yellow),
            ], in: "contain")
            try await run.close()
        } catch {
            try? await run.close()
            throw error
        }
    }

    /// The picture with a `label` is one image element a screen reader
    /// reads by those words, where its box is; the two with none are
    /// decoration, and no element stands where either is.
    func testAPictureWithWordsIsOneImageElementAndOneWithoutIsNone() async throws {
        let run = try PictureRun(bytes: NuxieMachineFolderByteSource(folder: PictureFolder.url()))
        do {
            await run.edge.start(event: "opened", now: run.now)
            let look = try await run.look("read-aloud")
            let images = look.nodes.filter { $0.role == NuxieNativeSemanticRole.image.rawValue }
            XCTAssertEqual(images.map(\.label), ["Four colors"], "the image elements are \(images)")
            if let image = images.first {
                XCTAssertEqual(image.bounds.minX, Self.fill.minX, accuracy: 0.5)
                XCTAssertEqual(image.bounds.minY, Self.fill.minY, accuracy: 0.5)
                XCTAssertEqual(image.bounds.width, Self.fill.width, accuracy: 0.5)
                XCTAssertEqual(image.bounds.height, Self.fill.height, accuracy: 0.5)
            }
            for (name, box) in [("cover", Self.cover), ("contain", Self.contain)] {
                let there = look.nodes.filter { $0.bounds.intersects(box.insetBy(dx: 1, dy: 1)) }
                XCTAssertEqual(there, [], "the \(name) picture, with no words, has an element: \(there)")
            }
            try await run.close()
        } catch {
            try? await run.close()
            throw error
        }
    }

    /// A source with no bytes for the picture: the page is never opened,
    /// and the edge stops with `edge.unsupplied-asset`, naming the path.
    func testAPictureTheSourceHasNoBytesForStopsTheEdgeNamingIt() async throws {
        let run = try PictureRun(bytes: NoFolderFiles())
        await run.edge.start(event: "opened", now: run.now)
        let fault = await run.edge.fault
        XCTAssertEqual(fault?.code, "edge.unsupplied-asset", "\(String(describing: fault))")
        XCTAssertTrue(fault?.detail.contains("assets/hero.png") ?? false, "\(String(describing: fault))")
        let stack = await run.edge.stack
        XCTAssertEqual(stack, [], "a page opened without its picture")
        XCTAssertEqual(run.owner.reports.last, fault.map { NuxieMachineEdgeReport.fault($0) },
                       "the owner was not told the fault")
        try await run.close()
    }

    /// A source that answers late: the page opens only once it has, with
    /// nothing presented, reported or asked a frame for while it waits;
    /// then the first frame already draws the picture.
    func testThePageOpensOnlyOnceTheSourceAnswersAndNothingIsDrawnBefore() async throws {
        let held = HeldBytes(folder: try PictureFolder.url())
        let run = try PictureRun(bytes: held)
        do {
            let now = run.now
            let edge = run.edge
            let starting = Task { await edge.start(event: "opened", now: now) }
            await held.untilAsked()
            XCTAssertEqual(held.asked, ["assets/hero.png"])
            let waiting = await run.edge.stack
            XCTAssertEqual(waiting, [], "the page opened before its picture's bytes arrived")
            XCTAssertEqual(run.owner.reports, [], "the owner heard of the page before its picture's bytes arrived")
            XCTAssertFalse(run.asks.take(), "a frame was asked for before the picture's bytes arrived")

            held.release()
            await starting.value
            let opened = await run.edge.stack
            XCTAssertEqual(opened.map(\.route), ["fits"], "the page did not open once the bytes arrived")
            let look = try await run.look("after-the-answer")
            look.expect([("top left", Self.point(Self.fill, 50, 50), Self.red),
                         ("bottom right", Self.point(Self.fill, 150, 150), Self.yellow)], in: "fill")
            try await run.close()
        } catch {
            held.release()
            try? await run.close()
            throw error
        }
    }

    /// A program that shows the picture, handed in with no row for it, is
    /// refused as the compiler refuses it: the edge is never made, and the
    /// compiler's `asset.missing` text, naming the path, is what it throws.
    func testAPictureWithNoRowHandedInIsRefusedAsTheCompilerRefusesIt() throws {
        let plan = try PictureFolder.plan(assets: [])
        XCTAssertThrowsError(try NuxieMachineEdge(plan: plan, store: NuxieMachineStandInStore(),
                                                  bytes: NuxieMachineFolderByteSource(folder: PictureFolder.url()),
                                                  onReport: { _ in })) { error in
            guard case NuxieMachineError.refused(let text) = error else {
                return XCTFail("not a refusal: \(error)")
            }
            XCTAssertTrue(text.contains("asset.missing"), text)
            XCTAssertTrue(text.contains("assets/hero.png"), text)
        }
    }

    /// The point `x`, `y` points from `box`'s top left.
    private static func point(_ box: CGRect, _ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: box.minX + x, y: box.minY + y)
    }
}

// MARK: - The folder

/// `Fixtures/views-picture`, the SDK's own fixture: `main.nux` and
/// `assets/hero.png`.
enum PictureFolder {
    private final class Anchor {}

    static func url() throws -> URL {
        try XCTUnwrap(Bundle(for: Anchor.self).url(forResource: "views-picture", withExtension: nil),
                      "the test bundle carries views-picture/")
    }

    /// The folder's one other file as the host finds it: its path, a
    /// picture of 120 by 60 pixels, and its size in bytes.
    static func rows() throws -> [NuxieMachineAsset] {
        let file = try url().appendingPathComponent("assets/hero.png")
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)
        return [NuxieMachineAsset(path: "assets/hero.png", kind: .picture(width: 120, height: 60),
                                  byteCount: size.uint64Value)]
    }

    /// The folder's plan, handed `assets` as its rows: the folder's own by
    /// default.
    static func plan(assets: [NuxieMachineAsset]? = nil) throws -> NuxieMachinePlanSource {
        let main = try String(contentsOf: url().appendingPathComponent("main.nux"), encoding: .utf8)
        return NuxieMachinePlanSource(files: [NuxieMachineSourceFile(path: "main.nux", text: main)],
                                      assets: try assets ?? rows(), root: "main", app: "app",
                                      experience: "gallery", version: 1)
    }
}

// MARK: - One run

/// A fresh session over the folder's plan, its clock, what its owner heard
/// and its asks for a frame.
private final class PictureRun {
    let edge: NuxieMachineEdge
    let owner = CounterOwner()
    let asks: FrameAskCount
    let now: Int64 = 9 * 3_600_000

    init(bytes: any NuxieMachineByteSource) throws {
        let owner = self.owner
        edge = try NuxieMachineEdge(plan: PictureFolder.plan(), store: NuxieMachineStandInStore(), bytes: bytes,
                                    onReport: { owner.heard($0) })
        asks = FrameAskCount(edge)
    }

    /// The page laid out at a phone's size, two frames stepped, and drawn
    /// with its semantic snapshot, kept as an attachment.
    func look(_ name: String) async throws -> Look {
        let presented = await edge.screen()
        let screen = try XCTUnwrap(presented, "nothing is presented")
        try await screen.setLayoutSize(width: Float(Look.size.width), height: Float(Look.size.height))
        _ = try await screen.resize(pixelWidth: UInt32(Look.scale) * UInt32(Look.size.width),
                                    pixelHeight: UInt32(Look.scale) * UInt32(Look.size.height))
        for _ in 0..<2 {
            await edge.frame(elapsedSeconds: PictureEdgeTests.tick, now: now)
        }
        let fault = await edge.fault
        XCTAssertNil(fault, "a frame faulted")
        let width = Look.scale * Int(Look.size.width)
        let height = Look.scale * Int(Look.size.height)
        let (pixels, semantics) = try await Pixels.render(screen, width: width, height: height,
                                                          scale: Float(Look.scale), capturesSemantics: true)
        try await Pixels.attach(pixels, width: width, height: height, name: "picture-\(name)")
        let capture = try XCTUnwrap(semantics, "the frame has no semantic snapshot")
        return Look(pixels: pixels, nodes: capture.tree.visibleReadingOrder)
    }

    func close() async throws {
        try await edge.close()
    }
}

extension Look {
    /// Each named point is drawn in its color, within a few steps of each
    /// channel.
    func expect(_ points: [(name: String, at: CGPoint, color: UInt32)], in what: String) {
        for (name, at, want) in points {
            let got = color(at: at)
            let near = [16, 8, 0].allSatisfy { shift in
                abs(Int((got >> UInt32(shift)) & 0xFF) - Int((want >> UInt32(shift)) & 0xFF)) <= 6
            }
            XCTAssertTrue(near, "\(what): \(name) at \(at) is #\(String(format: "%06x", got)), "
                          + "not #\(String(format: "%06x", want))")
        }
    }
}
#endif
