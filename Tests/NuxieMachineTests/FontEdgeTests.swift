#if os(iOS) && !targetEnvironment(macCatalyst)
import CoreGraphics
import CoreText
import Foundation
import XCTest
import NuxieMachine
import NuxieRuntime

/// `Fixtures/views-font` on a simulator, with no window: a page whose
/// title, "Quiet hours begin at nine" at 24 points, is drawn in the brand
/// face the folder's `assets/brand.ttf` holds (`font "Brand"`), then the
/// same words at the same size in the phone's own font, then a "Close"
/// button in the brand face. The host hands in the folder's rows (the face
/// as a font, its license as another file) and a byte source for the
/// folder; the edge asks the source for the face's bytes when it opens the
/// page, and the page is imported with them.
///
/// The face is a subset of Roboto Regular holding Basic Latin. HarfBuzz
/// shapes the title's words in it with no kerning, no ligature and no
/// offset, so each letter stands at the sum of the advances before it and
/// the title's width is the sum of its letters' advances.
final class FontEdgeTests: XCTestCase {
    static let tick: Float = 1.0 / 60.0
    static let words = "Quiet hours begin at nine"
    static let size: CGFloat = 24
    static let page: UInt32 = 0x0D_1214

    /// The page opens with the face's bytes from the folder. The title in
    /// the brand face is as wide as the face's own tables say those words
    /// are at 24 points, measured twice: its box, which is laid out to the
    /// sum of the letters' advances, and the ink drawn in it, which runs
    /// from the first letter's left edge to the last letter's right edge.
    /// The same words in the phone's font are drawn to another width.
    ///
    /// The oracle is worked out here from the file's bytes with CoreText:
    /// each letter's glyph, its advance and its outline's bounds at the
    /// size. Each width may differ from it by 1 point: the frame is drawn
    /// at 2 pixels a point and its edges are smoothed, so the ink found at
    /// each end may be half a point short of or past the outline, and a
    /// box may be laid out to a whole pixel. The two fonts' inks must
    /// differ by more than twice that.
    func testTheTitleIsDrawnInTheBrandFaceAtTheWidthItsTablesGive() async throws {
        let run = try FontRun(plan: FontFolder.plan(), bytes: NuxieMachineFolderByteSource(folder: FontFolder.url()))
        do {
            await run.edge.start(event: "opened", now: run.now)
            let fault = await run.edge.fault
            XCTAssertNil(fault, "the page did not open: \(String(describing: fault))")
            let look = try await run.look("widths")
            let (brand, phone) = try Self.titles(in: look)
            let face = try BrandFace(size: Self.size)

            XCTAssertEqual(brand.bounds.width, try face.advanceWidth(of: Self.words), accuracy: 1,
                           "the brand title's box is not as wide as its letters' advances")
            let brandInk = try XCTUnwrap(look.ink(within: brand.bounds, on: Self.page),
                                         "the brand title drew nothing")
            let phoneInk = try XCTUnwrap(look.ink(within: phone.bounds, on: Self.page),
                                         "the phone's title drew nothing")
            XCTAssertEqual(brandInk.width, try face.inkWidth(of: Self.words), accuracy: 1,
                           "the brand title's ink is not as wide as its letters' outlines")
            XCTAssertGreaterThan(abs(brandInk.width - phoneInk.width), 2,
                                 "the brand title (\(brandInk.width)) and the phone's (\(phoneInk.width)) "
                                     + "are drawn to one width")
            try await run.close()
        } catch {
            try? await run.close()
            throw error
        }
    }

    /// A screen reader reads the title in the brand face as it reads the
    /// same words in the phone's font: the same role, the same words, the
    /// same traits and state.
    func testAScreenReaderReadsTheTitleTheSameInEitherFont() async throws {
        let run = try FontRun(plan: FontFolder.plan(), bytes: NuxieMachineFolderByteSource(folder: FontFolder.url()))
        do {
            await run.edge.start(event: "opened", now: run.now)
            let look = try await run.look("read-aloud")
            let (brand, phone) = try Self.titles(in: look)
            XCTAssertEqual(brand.label, Self.words)
            XCTAssertEqual(brand.role, phone.role)
            XCTAssertEqual(brand.label, phone.label)
            XCTAssertEqual(brand.traitFlags, phone.traitFlags)
            XCTAssertEqual(brand.stateFlags, phone.stateFlags)
            try await run.close()
        } catch {
            try? await run.close()
            throw error
        }
    }

    /// A source with no bytes for the face: the page is never opened, and
    /// the edge stops with `edge.unsupplied-asset`, naming the face's path.
    func testAFaceTheSourceHasNoBytesForStopsTheEdgeNamingIt() async throws {
        let run = try FontRun(plan: FontFolder.plan(), bytes: NoFolderFiles())
        await run.edge.start(event: "opened", now: run.now)
        let fault = await run.edge.fault
        XCTAssertEqual(fault?.code, "edge.unsupplied-asset", "\(String(describing: fault))")
        XCTAssertTrue(fault?.detail.contains("assets/brand.ttf") ?? false, "\(String(describing: fault))")
        let stack = await run.edge.stack
        XCTAssertEqual(stack, [], "a page opened without its face")
        XCTAssertEqual(run.owner.reports.last, fault.map { NuxieMachineEdgeReport.fault($0) },
                       "the owner was not told the fault")
        try await run.close()
    }

    /// The page with the line in the phone's font taken out, so every text
    /// has a face: its scene holds the brand face and no platform font,
    /// where the page as written holds both, the platform font first. It
    /// opens and draws its title, and no lease of the phone's face is
    /// taken: once imported, such a lease is kept in the process's system
    /// font cache, which holds none after it opens. The page as written,
    /// opened next, leaves one there, so the cache does show a lease.
    func testAPageWhoseEveryTextHasAFaceOpensWithNoPlatformFont() async throws {
        let written = try FontFolder.plan()
        let faced = try FontFolder.plan(main: FontFolder.withoutThePhonesLine(FontFolder.main()))
        XCTAssertEqual(try FontFolder.session(written).sceneAssets(),
                       [.platformFont, .font(path: "assets/brand.ttf")])
        XCTAssertEqual(try FontFolder.session(faced).sceneAssets(), [.font(path: "assets/brand.ttf")])

        try SystemFace.forget()
        let run = try FontRun(plan: faced, bytes: NuxieMachineFolderByteSource(folder: FontFolder.url()))
        do {
            await run.edge.start(event: "opened", now: run.now)
            let fault = await run.edge.fault
            XCTAssertNil(fault, "the page did not open: \(String(describing: fault))")
            let stack = await run.edge.stack
            XCTAssertEqual(stack.map(\.route), ["words"])
            let look = try await run.look("every-text-faced")
            let titles = look.nodes.filter { $0.label == Self.words }
            XCTAssertEqual(titles.count, 1, "the titles read are \(titles)")
            if let title = titles.first {
                XCTAssertNotNil(look.ink(within: title.bounds, on: Self.page), "the title drew nothing")
            }
            XCTAssertFalse(try SystemFace.kept(), "a page whose every text has a face took the phone's face")
            try await run.close()
        } catch {
            try? await run.close()
            throw error
        }

        let control = try FontRun(plan: written, bytes: NuxieMachineFolderByteSource(folder: FontFolder.url()))
        do {
            await control.edge.start(event: "opened", now: control.now)
            let fault = await control.edge.fault
            XCTAssertNil(fault, "the page as written did not open: \(String(describing: fault))")
            XCTAssertTrue(try SystemFace.kept(), "the page as written took no lease of the phone's face")
            try await control.close()
        } catch {
            try? await control.close()
            throw error
        }
    }

    /// A program whose `font` names a file no row handed in names is
    /// refused as the compiler refuses it: the edge is never made, and the
    /// compiler's `asset.missing` text, naming the path, is what it throws.
    func testAFontWithNoRowHandedInIsRefusedAsTheCompilerRefusesIt() throws {
        let plan = try FontFolder.plan(assets: [])
        XCTAssertThrowsError(try NuxieMachineEdge(plan: plan, store: NuxieMachineStandInStore(),
                                                  bytes: NuxieMachineFolderByteSource(folder: FontFolder.url()),
                                                  onReport: { _ in })) { error in
            guard case NuxieMachineError.refused(let text) = error else {
                return XCTFail("not a refusal: \(error)")
            }
            XCTAssertTrue(text.contains("asset.missing"), text)
            XCTAssertTrue(text.contains("assets/brand.ttf"), text)
        }
    }

    struct NotTwoTitles: Error, CustomStringConvertible {
        let reading: [String]
        var description: String { "not two titles read as \"\(FontEdgeTests.words)\": \(reading)" }
    }

    /// The two titles a screen reader reads by the words, top first: the
    /// brand face's, then the phone font's.
    private static func titles(in look: Look) throws
        -> (brand: NuxieNativeSemanticNode, phone: NuxieNativeSemanticNode)
    {
        let titles = look.nodes.filter { $0.label == words }.sorted { $0.bounds.minY < $1.bounds.minY }
        guard titles.count == 2 else { throw NotTwoTitles(reading: look.reading) }
        return (titles[0], titles[1])
    }
}

// MARK: - The folder

/// `Fixtures/views-font`, the SDK's own fixture: `main.nux`,
/// `assets/brand.ttf` and the face's license beside it.
enum FontFolder {
    private final class Anchor {}

    /// The line of the title in the phone's font, as written.
    static let phonesLine =
        "      text \"Quiet hours begin at nine\" font-size=24 color=#eef3f1 id=\"phone\"\n"

    struct NoPhoneLine: Error, CustomStringConvertible {
        var description: String { "views-font/main.nux does not have the phone's line exactly once" }
    }

    static func url() throws -> URL {
        try XCTUnwrap(Bundle(for: Anchor.self).url(forResource: "views-font", withExtension: nil),
                      "the test bundle carries views-font/")
    }

    static func main() throws -> String {
        try String(contentsOf: url().appendingPathComponent("main.nux"), encoding: .utf8)
    }

    /// `main` with the title in the phone's font taken out.
    static func withoutThePhonesLine(_ main: String) throws -> String {
        guard main.components(separatedBy: phonesLine).count == 2 else { throw NoPhoneLine() }
        return main.replacingOccurrences(of: phonesLine, with: "")
    }

    /// The folder's other files as the host finds them: the face as a
    /// font and its license as another file, each with its size in bytes,
    /// in the order of their paths.
    static func rows() throws -> [NuxieMachineAsset] {
        func size(_ path: String) throws -> UInt64 {
            let file = try url().appendingPathComponent(path)
            return try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)
                .uint64Value
        }
        return [
            NuxieMachineAsset(path: "assets/LICENSE-ROBOTO.txt", kind: .other,
                              byteCount: try size("assets/LICENSE-ROBOTO.txt")),
            NuxieMachineAsset(path: "assets/brand.ttf", kind: .font, byteCount: try size("assets/brand.ttf")),
        ]
    }

    /// The folder's plan, with `main` as its one source file (the
    /// folder's own by default) and `assets` as its rows (the folder's own
    /// by default).
    static func plan(main: String? = nil, assets: [NuxieMachineAsset]? = nil) throws -> NuxieMachinePlanSource {
        let text = try main ?? Self.main()
        return NuxieMachinePlanSource(files: [NuxieMachineSourceFile(path: "main.nux", text: text)],
                                      assets: try assets ?? rows(), root: "main", app: "app",
                                      experience: "hours", version: 1)
    }

    /// A session over `plan`, to read its scene's assets.
    static func session(_ plan: NuxieMachinePlanSource) throws -> NuxieMachineSession {
        try NuxieMachineSession(files: plan.files.map { ($0.path, $0.text) }, assets: plan.assets,
                                root: plan.root, app: plan.app, experience: plan.experience,
                                version: plan.version)
    }
}

// MARK: - The oracle

/// The brand face at a size, read with CoreText from the folder's own
/// `assets/brand.ttf`: what its tables say a run of words is.
struct BrandFace {
    let font: CTFont

    init(size: CGFloat) throws {
        let bytes = try Data(contentsOf: FontFolder.url().appendingPathComponent("assets/brand.ttf"))
        let provider = try XCTUnwrap(CGDataProvider(data: bytes as CFData))
        let graphics = try XCTUnwrap(CGFont(provider), "assets/brand.ttf is not a face CoreText reads")
        font = CTFontCreateWithGraphicsFont(graphics, size, nil, nil)
    }

    /// Each letter's glyph: one for each, as the face maps it.
    func glyphs(of words: String) throws -> [CGGlyph] {
        let units = Array(words.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        let mapped = CTFontGetGlyphsForCharacters(font, units, &glyphs, units.count)
        XCTAssertTrue(mapped, "the face has no glyph for some letter of \"\(words)\"")
        return glyphs
    }

    /// Each letter's advance, in points at the size.
    func advances(of words: String) throws -> [CGFloat] {
        let glyphs = try glyphs(of: words)
        var advances = [CGSize](repeating: .zero, count: glyphs.count)
        CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, glyphs.count)
        return advances.map(\.width)
    }

    /// The sum of the letters' advances: where the pen ends.
    func advanceWidth(of words: String) throws -> CGFloat {
        try advances(of: words).reduce(0, +)
    }

    /// From the first letter's outline's left edge to the last letter's
    /// outline's right edge, each letter standing at the sum of the
    /// advances before it.
    func inkWidth(of words: String) throws -> CGFloat {
        let glyphs = try glyphs(of: words)
        let advances = try advances(of: words)
        var bounds = [CGRect](repeating: .zero, count: glyphs.count)
        CTFontGetBoundingRectsForGlyphs(font, .horizontal, glyphs, &bounds, glyphs.count)
        guard let first = bounds.first, let last = bounds.last else { return 0 }
        let lastOrigin = advances.dropLast().reduce(0, +)
        return lastOrigin + last.maxX - first.minX
    }
}

/// The phone's regular face in the process's system font cache, where an
/// edge's lease of it is kept once the scene it filled is imported.
enum SystemFace {
    private struct NotKept: Error {}

    /// Drop the regular face from the cache.
    static func forget() throws {
        let lease = try ExperienceRuntimeSystemFontCache.shared.prepare(weight: "400", style: "normal")
        ExperienceRuntimeSystemFontCache.shared.didFailImport([lease])
    }

    /// Whether the cache holds the regular face.
    static func kept() throws -> Bool {
        let identity = try ExperienceRuntimeSystemFontProvider.requestIdentity(weight: "400", style: "normal")
        do {
            _ = try ExperienceRuntimeSystemFontCache.shared.candidate(for: identity) { throw NotKept() }
            return true
        } catch is NotKept {
            return false
        }
    }
}

// MARK: - One run

/// A fresh session over a plan of the folder, its clock, what its owner
/// heard and its asks for a frame.
private final class FontRun {
    let edge: NuxieMachineEdge
    let owner = CounterOwner()
    let asks: FrameAskCount
    let now: Int64 = 9 * 3_600_000

    init(plan: NuxieMachinePlanSource, bytes: any NuxieMachineByteSource) throws {
        let owner = self.owner
        edge = try NuxieMachineEdge(plan: plan, store: NuxieMachineStandInStore(), bytes: bytes,
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
            await edge.frame(elapsedSeconds: FontEdgeTests.tick, now: now)
        }
        let fault = await edge.fault
        XCTAssertNil(fault, "a frame faulted")
        let width = Look.scale * Int(Look.size.width)
        let height = Look.scale * Int(Look.size.height)
        let (pixels, semantics) = try await Pixels.render(screen, width: width, height: height,
                                                          scale: Float(Look.scale), capturesSemantics: true)
        try await Pixels.attach(pixels, width: width, height: height, name: "font-\(name)")
        let capture = try XCTUnwrap(semantics, "the frame has no semantic snapshot")
        return Look(pixels: pixels, nodes: capture.tree.visibleReadingOrder)
    }

    func close() async throws {
        try await edge.close()
    }
}

extension Look {
    /// Where ink is drawn across the rows of `box`, in points: from the
    /// left edge of the first column of pixels in which some pixel differs
    /// from `background` by more than 40 in a channel, to the right edge of
    /// the last. None when every pixel there is the background.
    func ink(within box: CGRect, on background: UInt32) -> (left: CGFloat, right: CGFloat, width: CGFloat)? {
        let width = Look.scale * Int(Look.size.width)
        let height = Look.scale * Int(Look.size.height)
        let top = max(0, Int((box.minY * CGFloat(Look.scale)).rounded(.down)))
        let bottom = min(height, Int((box.maxY * CGFloat(Look.scale)).rounded(.up)))
        guard top < bottom else { return nil }
        var left: Int?
        var right: Int?
        for column in 0..<width {
            let inked = (top..<bottom).contains { row in
                let at = pixels.startIndex + (row * width + column) * 4
                let drawn = UInt32(pixels[at + 2]) << 16 | UInt32(pixels[at + 1]) << 8 | UInt32(pixels[at])
                return [16, 8, 0].contains { shift in
                    abs(Int((drawn >> UInt32(shift)) & 0xFF) - Int((background >> UInt32(shift)) & 0xFF)) > 40
                }
            }
            guard inked else { continue }
            if left == nil { left = column }
            right = column
        }
        guard let left, let right else { return nil }
        let scale = CGFloat(Look.scale)
        return (CGFloat(left) / scale, CGFloat(right + 1) / scale, CGFloat(right + 1 - left) / scale)
    }
}
#endif
