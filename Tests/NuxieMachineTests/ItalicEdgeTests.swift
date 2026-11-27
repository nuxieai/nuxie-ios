#if os(iOS) && !targetEnvironment(macCatalyst)
import CoreGraphics
import CoreText
import Foundation
import UIKit
import XCTest
import NuxieMachine
import NuxieRuntime

/// `Fixtures/views-italic` on a simulator, with no window: a page whose
/// first line, "Quiet hours begin at nine" at 17 points, is italic in the
/// phone's own font (`font-style=italic`, no `font-family`), then the same
/// words at the same size upright, then a "Close" button, upright. The
/// folder has no other file, so nothing is asked of the byte source: both
/// faces are the phone's, leased from the system font cache.
final class ItalicEdgeTests: XCTestCase {
    static let words = "Quiet hours begin at nine"
    static let size: CGFloat = 17
    static let page: UInt32 = 0x0D_1214

    /// The italic line is drawn in the phone's italic face: its box is as
    /// wide as that face's own advances for its letters at 17 points, and
    /// its ink falls in other columns than the upright line's, which is the
    /// same letters at the same size from the same left edge. The scene
    /// lists the phone's upright font, then its italic.
    ///
    /// The oracle is CoreText on `UIFont.italicSystemFont(ofSize:)` at the
    /// line's size: each letter's glyph and advance, summed here. The box
    /// may differ from it by 1 point, as in `FontEdgeTests`. One face at one
    /// place inks the same columns, so the two lines' columns differing by
    /// more than 5 points' worth says two faces were drawn.
    func testAnItalicLineInThePhonesFontIsDrawnInItsItalicFace() async throws {
        let plan = try ItalicFolder.plan()
        XCTAssertEqual(try FontFolder.session(plan).sceneAssets(), [.platformFont(.normal), .platformFont(.italic)])
        let run = try FontRun(plan: plan, bytes: NoFolderFiles())
        do {
            await run.edge.start(event: "opened", now: run.now)
            let fault = await run.edge.fault
            XCTAssertNil(fault, "the page did not open: \(String(describing: fault))")
            let look = try await run.look("italic")
            let (italic, upright) = try Self.lines(in: look)
            let face = FaceTables(font: UIFont.italicSystemFont(ofSize: Self.size) as CTFont)

            XCTAssertEqual(italic.bounds.width, try face.advanceWidth(of: Self.words), accuracy: 1,
                           "the italic line's box is not as wide as the italic face's advances")
            let slanted = look.inkedColumns(within: italic.bounds, on: Self.page)
            let straight = look.inkedColumns(within: upright.bounds, on: Self.page)
            XCTAssertFalse(slanted.isEmpty, "the italic line drew nothing")
            XCTAssertFalse(straight.isEmpty, "the upright line drew nothing")
            XCTAssertGreaterThan(slanted.symmetricDifference(straight).count, 5 * Look.scale,
                                 "the italic and upright lines ink the same columns")
            try await run.close()
        } catch {
            try? await run.close()
            throw error
        }
    }

    /// The page with its upright line taken out and its "Close" italic, so
    /// every text is italic in the phone's font: the scene lists the
    /// phone's italic font alone, and opening it takes one lease, of the
    /// italic face. Once imported, a lease is kept in the process's system
    /// font cache, which then holds the italic face and not the upright one.
    func testAPageWhoseOnlyTextIsItalicTakesOnlyTheItalicFace() async throws {
        let plan = try ItalicFolder.plan(main: ItalicFolder.allItalic())
        XCTAssertEqual(try FontFolder.session(plan).sceneAssets(), [.platformFont(.italic)])

        try SystemFace.forget(.normal)
        try SystemFace.forget(.italic)
        let run = try FontRun(plan: plan, bytes: NoFolderFiles())
        do {
            await run.edge.start(event: "opened", now: run.now)
            let look = try await run.look("all-italic")
            let lines = look.nodes.filter { $0.label == Self.words }
            XCTAssertEqual(lines.count, 1, "the lines read are \(lines)")
            if let line = lines.first {
                XCTAssertNotNil(look.ink(within: line.bounds, on: Self.page), "the line drew nothing")
            }
            XCTAssertTrue(try SystemFace.kept(.italic), "the page took no lease of the italic face")
            XCTAssertFalse(try SystemFace.kept(.normal), "a page with no upright text took the upright face")
            try await run.close()
        } catch {
            try? await run.close()
            throw error
        }
    }

    /// `views-font` with its font's one file listed as its 400 italic row
    /// and its title italic: the title is drawn in that file, the brand
    /// face, not in the phone's italic. The scene lists the phone's upright
    /// font (for the line in the phone's font) and the file, and no phone
    /// italic. The compiler does not look inside the file, so what this
    /// shows is which file is drawn. The oracle is the brand face's own
    /// advances, read with CoreText from the file, as in `FontEdgeTests`.
    func testAnItalicLineInAFontsItalicRowIsDrawnInThatRowsFile() async throws {
        let main = try ItalicFolder.brandItalic(FontFolder.main())
        let plan = try FontFolder.plan(main: main)
        XCTAssertEqual(try FontFolder.session(plan).sceneAssets(),
                       [.platformFont(.normal), .font(path: "assets/brand.ttf")])
        let run = try FontRun(plan: plan, bytes: NuxieMachineFolderByteSource(folder: FontFolder.url()))
        do {
            await run.edge.start(event: "opened", now: run.now)
            let look = try await run.look("brand-italic")
            let titles = look.nodes.filter { $0.label == FontEdgeTests.words }
                .sorted { $0.bounds.minY < $1.bounds.minY }
            let brand = try XCTUnwrap(titles.first, "no title is read: \(look.reading)")
            XCTAssertEqual(brand.bounds.width,
                           try FaceTables.brand(size: FontEdgeTests.size).advanceWidth(of: FontEdgeTests.words),
                           accuracy: 1, "the italic title is not drawn in its row's file")
            try await run.close()
        } catch {
            try? await run.close()
            throw error
        }
    }

    struct NotTwoLines: Error, CustomStringConvertible {
        let reading: [String]
        var description: String { "not two lines read as \"\(ItalicEdgeTests.words)\": \(reading)" }
    }

    /// The two lines a screen reader reads by the words, top first: the
    /// italic one, then the upright one.
    private static func lines(in look: Look) throws
        -> (italic: NuxieNativeSemanticNode, upright: NuxieNativeSemanticNode)
    {
        let lines = look.nodes.filter { $0.label == words }.sorted { $0.bounds.minY < $1.bounds.minY }
        guard lines.count == 2 else { throw NotTwoLines(reading: look.reading) }
        return (lines[0], lines[1])
    }
}

// MARK: - The folder

/// `Fixtures/views-italic`, the SDK's own fixture: `main.nux` and no other
/// file.
enum ItalicFolder {
    private final class Anchor {}

    struct NotOnce: Error, CustomStringConvertible {
        let line: String
        var description: String { "the page does not have \"\(line)\" exactly once" }
    }

    static func url() throws -> URL {
        try XCTUnwrap(Bundle(for: Anchor.self).url(forResource: "views-italic", withExtension: nil),
                      "the test bundle carries views-italic/")
    }

    static func main() throws -> String {
        try String(contentsOf: url().appendingPathComponent("main.nux"), encoding: .utf8)
    }

    /// `main` with `line` replaced by `replacement`; `line` must be there
    /// once.
    static func replacing(_ line: String, with replacement: String, in main: String) throws -> String {
        guard main.components(separatedBy: line).count == 2 else { throw NotOnce(line: line) }
        return main.replacingOccurrences(of: line, with: replacement)
    }

    /// The page with its upright line taken out and its "Close" italic.
    static func allItalic() throws -> String {
        let upright = "      text \"Quiet hours begin at nine\" font-size=17 color=#eef3f1 id=\"upright\"\n"
        let close = "text \"Close\" font-size=16 color=#eef3f1"
        return try replacing(close, with: "text \"Close\" font-size=16 font-style=italic color=#eef3f1",
                             in: replacing(upright, with: "", in: main()))
    }

    /// `views-font`'s `main` with its font's one file as its 400 italic
    /// row, and its title italic.
    static func brandItalic(_ main: String) throws -> String {
        let font = try replacing("font \"Brand\" = \"assets/brand.ttf\"\n",
                                 with: "font \"Brand\"\n  400 italic = \"assets/brand.ttf\"\n", in: main)
        return try replacing("font-family=\"Brand\" font-size=24 color=#eef3f1 id=\"brand\"",
                             with: "font-family=\"Brand\" font-size=24 font-style=italic color=#eef3f1 id=\"brand\"",
                             in: font)
    }

    /// The folder's plan, with `main` as its one source file (the folder's
    /// own by default) and no other file.
    static func plan(main: String? = nil) throws -> NuxieMachinePlanSource {
        let text = try main ?? Self.main()
        return NuxieMachinePlanSource(files: [NuxieMachineSourceFile(path: "main.nux", text: text)],
                                      assets: [], root: "main", app: "app", experience: "hours", version: 1)
    }
}

extension Look {
    /// The columns of pixels across the rows of `box` in which some pixel
    /// differs from `background` by more than 40 in a channel.
    func inkedColumns(within box: CGRect, on background: UInt32) -> Set<Int> {
        let width = Look.scale * Int(Look.size.width)
        let height = Look.scale * Int(Look.size.height)
        let top = max(0, Int((box.minY * CGFloat(Look.scale)).rounded(.down)))
        let bottom = min(height, Int((box.maxY * CGFloat(Look.scale)).rounded(.up)))
        guard top < bottom else { return [] }
        return Set((0..<width).filter { column in
            (top..<bottom).contains { row in
                let at = pixels.startIndex + (row * width + column) * 4
                let drawn = UInt32(pixels[at + 2]) << 16 | UInt32(pixels[at + 1]) << 8 | UInt32(pixels[at])
                return [16, 8, 0].contains { shift in
                    abs(Int((drawn >> UInt32(shift)) & 0xFF) - Int((background >> UInt32(shift)) & 0xFF)) > 40
                }
            }
        })
    }
}
#endif
