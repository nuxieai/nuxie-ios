#if os(iOS) && !targetEnvironment(macCatalyst)
import CoreGraphics
import CoreText
import Foundation
import UIKit
import XCTest
import NuxieMachine
import NuxieRuntime

/// `Fixtures/views-text-styles` on a simulator, with no window: a page of
/// four lines in the phone's own font, each sized by one of the phone's
/// text styles. "Quiet hours" is `font=title1`, "Begin at nine"
/// `font=headline`, "Every evening" `font=caption1`, and "Until seven"
/// `font-size=caption1`, which takes the style's size and not its weight.
/// The folder has no other file, so nothing is asked of the byte source.
///
/// Each run tells the session the environment the presenter would tell for
/// the test's traits ([`NuxieMachineSheetPresenter.environment(dark:in:)`])
/// before the start, as the presenter does, so the first frame is drawn in
/// it.
final class TextStyleEdgeTests: XCTestCase {
    static let title = "Quiet hours"
    static let headline = "Begin at nine"
    static let caption = "Every evening"
    static let captionSize = "Until seven"

    /// At the default text size, each line's box is as wide as CoreText
    /// says its letters are in the font UIKit gives its style: Title 1,
    /// Headline and Caption 1 at their own sizes and weights, and the line
    /// written `font-size=caption1` at Caption 1's size in the regular
    /// weight.
    ///
    /// The oracle is CoreText on `UIFont.preferredFont(forTextStyle:compatibleWith:)`
    /// for the traits (the regular system font at that size for the
    /// size-only line): each letter's glyph and advance, summed here, as
    /// `FontEdgeTests` and `ItalicEdgeTests` sum them. A box may differ from
    /// it by 1 point, as there. Headline is semibold, and the regular face's
    /// advances for its words differ from the semibold face's by more than
    /// that, so its width shows its weight was drawn as well as its size.
    func testEachStyledLineIsAsWideAsUIKitsFontForItsStyle() async throws {
        let traits = UITraitCollection(preferredContentSizeCategory: .large)
        let look = try await Self.look(TextStyleFolder.plan(), traits: traits, name: "default")
        let widths: [(String, UIFont)] = [
            (Self.title, Self.font(.title1, traits)),
            (Self.headline, Self.font(.headline, traits)),
            (Self.caption, Self.font(.caption1, traits)),
            (Self.captionSize, UIFont.systemFont(ofSize: Self.font(.caption1, traits).pointSize, weight: .regular)),
        ]
        for (words, font) in widths {
            let line = try Self.line(words, in: look)
            XCTAssertEqual(line.bounds.width, try FaceTables(font: font as CTFont).advanceWidth(of: words),
                           accuracy: 1, "\"\(words)\" is not as wide as \(font.fontName) at \(font.pointSize)")
        }

        let headline = Self.font(.headline, traits)
        let regular = UIFont.systemFont(ofSize: headline.pointSize, weight: .regular)
        let semiboldWidth = try FaceTables(font: headline as CTFont).advanceWidth(of: Self.headline)
        let regularWidth = try FaceTables(font: regular as CTFont).advanceWidth(of: Self.headline)
        XCTAssertGreaterThan(abs(semiboldWidth - regularWidth), 1,
                             "Headline's face and the regular one give its words one width")
    }

    /// With the person's text size at the largest standard setting, the
    /// title grows to Title 1's size there: its box is as wide as CoreText
    /// says its letters are in the font UIKit gives Title 1 for those
    /// traits, and wider than at the default setting.
    ///
    /// The oracle is CoreText on `UIFont.preferredFont(forTextStyle: .title1,
    /// compatibleWith:)` for each setting's traits, its advances summed.
    func testTheTitleGrowsToTitle1sSizeAtALargerTextSize() async throws {
        let plan = try TextStyleFolder.plan()
        var widths: [UIContentSizeCategory: CGFloat] = [:]
        for category in [UIContentSizeCategory.large, .extraExtraExtraLarge] {
            let traits = UITraitCollection(preferredContentSizeCategory: category)
            let look = try await Self.look(plan, traits: traits, name: category.rawValue)
            let title = try Self.line(Self.title, in: look)
            let font = Self.font(.title1, traits)
            XCTAssertEqual(title.bounds.width, try FaceTables(font: font as CTFont).advanceWidth(of: Self.title),
                           accuracy: 1, "the title is not drawn at Title 1's \(font.pointSize) at \(category.rawValue)")
            widths[category] = title.bounds.width
        }
        let larger = try XCTUnwrap(widths[.extraExtraExtraLarge]), standard = try XCTUnwrap(widths[.large])
        XCTAssertGreaterThan(larger, standard + 1, "the title did not grow: \(standard) then \(larger)")
    }

    // MARK: The environment

    /// UIKit's text styles in the header's order, written out here rather
    /// than read from the SDK.
    static let styles: [UIFont.TextStyle] = [
        .largeTitle, .title1, .title2, .title3, .headline, .body, .callout, .subheadline, .footnote, .caption1,
        .caption2,
    ]

    /// The environment the presenter tells for some traits carries the
    /// twenty-two numbers UIKit gives them: each style's point size, from
    /// smallest setting to the largest accessibility one, and each style's
    /// weight, regular but Headline semibold at every setting (Dynamic
    /// Type's own weights, with the bold text setting off). Its scheme is
    /// the one asked for and its text size is Body's.
    ///
    /// Oracle: `UIFont.preferredFont(forTextStyle:compatibleWith:)` for the
    /// sizes, and Dynamic Type's table for the weights.
    @MainActor
    func testTheEnvironmentCarriesEachStylesSizeAndWeightFromUIKit() {
        let categories: [UIContentSizeCategory] = [
            .extraSmall, .large, .extraExtraExtraLarge, .accessibilityExtraExtraExtraLarge,
        ]
        let weights: [Double] = [400, 400, 400, 400, 600, 400, 400, 400, 400, 400, 400]
        for category in categories {
            let traits = UITraitCollection(preferredContentSizeCategory: category)
            let environment = NuxieMachineSheetPresenter.environment(dark: true, in: traits)
            XCTAssertTrue(environment.dark)
            XCTAssertEqual(environment.textSize, Double(Self.font(.body, traits).pointSize))
            XCTAssertEqual(environment.styleSizes, Self.sizes(in: traits), "the sizes at \(category.rawValue)")
            XCTAssertEqual(environment.styleWeights, weights, "the weights at \(category.rawValue)")
        }
    }

    /// At the default setting the environment carries an iPhone's sizes and
    /// weights, the ones an environment made with no styles carries and the
    /// machine assumes when it is told none.
    ///
    /// Oracle: Dynamic Type's table at the default setting, Large Title 34
    /// down to Caption 2 at 11.
    @MainActor
    func testAtTheDefaultSettingTheEnvironmentIsTheDefaultOne() {
        let traits = UITraitCollection(preferredContentSizeCategory: .large)
        let environment = NuxieMachineSheetPresenter.environment(dark: false, in: traits)
        XCTAssertEqual(environment.styleSizes, [34, 28, 22, 20, 17, 17, 16, 15, 13, 12, 11])
        XCTAssertEqual(environment, NuxieMachineEnvironment(dark: false, textSize: 17),
                       "an environment made with no styles is not an iPhone's at the default setting")
    }

    /// A font's weight is read as CSS numbers it: each of UIKit's nine
    /// system weights is its CSS number, ultra light 100 through black 900.
    ///
    /// Oracle: UIKit's named weights, in order, and CSS's hundreds.
    @MainActor
    func testEachOfUIKitsWeightsIsItsCSSNumber() {
        let named: [(UIFont.Weight, Double)] = [
            (.ultraLight, 100), (.thin, 200), (.light, 300), (.regular, 400), (.medium, 500), (.semibold, 600),
            (.bold, 700), (.heavy, 800), (.black, 900),
        ]
        for (weight, css) in named {
            let font = UIFont.systemFont(ofSize: 17, weight: weight)
            XCTAssertEqual(NuxieMachineSheetPresenter.cssWeight(of: font), css, "\(weight.rawValue) is not \(css)")
        }
    }

    // MARK: Helpers

    struct NotOneLine: Error, CustomStringConvertible {
        let words: String
        let reading: [String]
        var description: String { "not one line read as \"\(words)\": \(reading)" }
    }

    static func font(_ style: UIFont.TextStyle, _ traits: UITraitCollection) -> UIFont {
        UIFont.preferredFont(forTextStyle: style, compatibleWith: traits)
    }

    /// Each style's point size UIKit gives `traits`, in the header's order.
    static func sizes(in traits: UITraitCollection) -> [Double] {
        styles.map { Double(font($0, traits).pointSize) }
    }

    /// The one line a screen reader reads as `words`.
    static func line(_ words: String, in look: Look) throws -> NuxieNativeSemanticNode {
        let lines = look.nodes.filter { $0.label == words }
        guard lines.count == 1, let line = lines.first else { throw NotOneLine(words: words, reading: look.reading) }
        return line
    }

    /// The page opened in a fresh session that was told, before its start,
    /// the environment the presenter tells for `traits`, and drawn.
    static func look(_ plan: NuxieMachinePlanSource, traits: UITraitCollection, name: String) async throws -> Look {
        let environment = await MainActor.run { NuxieMachineSheetPresenter.environment(dark: true, in: traits) }
        let run = try FontRun(plan: plan, bytes: NoFolderFiles())
        do {
            await run.edge.environment(environment, now: run.now)
            await run.edge.start(event: "opened", now: run.now)
            let fault = await run.edge.fault
            XCTAssertNil(fault, "the page did not open: \(String(describing: fault))")
            let look = try await run.look("text-styles-\(name)")
            try await run.close()
            return look
        } catch {
            try? await run.close()
            throw error
        }
    }
}

// MARK: - The folder

/// `Fixtures/views-text-styles`, the SDK's own fixture: `main.nux` and no
/// other file.
enum TextStyleFolder {
    private final class Anchor {}

    static func url() throws -> URL {
        try XCTUnwrap(Bundle(for: Anchor.self).url(forResource: "views-text-styles", withExtension: nil),
                      "the test bundle carries views-text-styles/")
    }

    /// The folder's plan, with its `main.nux` as its one source file.
    static func plan() throws -> NuxieMachinePlanSource {
        let text = try String(contentsOf: url().appendingPathComponent("main.nux"), encoding: .utf8)
        return NuxieMachinePlanSource(files: [NuxieMachineSourceFile(path: "main.nux", text: text)],
                                      assets: [], root: "main", app: "app", experience: "hours", version: 1)
    }
}
#endif
