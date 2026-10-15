import CoreText
import XCTest

final class TypedFontFallbackTests: XCTestCase {
    func testPublishedTwoFieldFormRetainsTypedScripts() throws {
        continueAfterFailure = false
        for (script, value) in [("japanese", "日本語"), ("arabic", "مرحبا"),
                                ("hebrew", "שלום"), ("hindi", "नमस्ते"),
                                ("latin", "café é"), ("emoji", "😀"), ("symbols", "▷ ✶ ●")] {
            let app = XCUIApplication()
            app.launchArguments = ["--nuxie-fixture", "published-two-fields",
                                   "--nuxie-hide-navigation", "--nuxie-keyboard-qualification",
                                   "--nuxie-font-fallback-oracle"]
            app.launch()
            let row = app.cells["nuxie-fixture-published-two-fields"]
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            row.tap()
            let ready = app.staticTexts.matching(NSPredicate(format:
                "identifier == 'nuxie-runtime-status' AND label BEGINSWITH 'ready:'")).firstMatch
            XCTAssertTrue(ready.waitForExistence(timeout: 30), "The native presentation must be ready")
            let fields = app.textFields.matching(NSPredicate(format:
                "identifier BEGINSWITH 'nuxie-text-input-'"))
            XCTAssertTrue(fields.firstMatch.waitForExistence(timeout: 20))
            XCTAssertEqual(fields.count, 2)
            let field = fields.element(boundBy: 0)
            let positioned = XCTNSPredicateExpectation(predicate:
                NSPredicate(format: "hittable == true"), object: field)
            XCTAssertEqual(XCTWaiter.wait(for: [positioned], timeout: 20), .completed,
                           "The first field must be available for input")
            let initialValue = try XCTUnwrap(field.value as? String)
            field.tap()
            field.typeText(value)
            XCTAssertEqual(field.value as? String, initialValue + value,
                          "The editable field must retain the exact typed value")
            let editing = XCTAttachment(screenshot: app.screenshot())
            editing.name = "text-fallback-\(script)-editing"
            editing.lifetime = .keepAlways
            add(editing)
            fields.element(boundBy: 1).tap()
            XCTAssertEqual(field.value as? String, initialValue + value,
                          "Moving focus must preserve the committed value")
            var expectedScalar = ["japanese", "arabic", "hebrew", "hindi"].contains(script)
                ? value.unicodeScalars.first : nil
            if script == "symbols" {
                let primary = try XCTUnwrap(CTFontCreateUIFontForLanguage(.system, 17, nil))
                expectedScalar = value.unicodeScalars.first { scalar in
                    guard scalar.value != 0x20 else { return false }
                    var character = UniChar(scalar.value), glyph: CGGlyph = 0
                    _ = CTFontGetGlyphsForCharacters(primary, &character, &glyph, 1)
                    return glyph == 0
                }
            }
            if let scalar = expectedScalar {
                let prefix = String(format: "%04X=", scalar.value)
                let oracle = app.staticTexts["nuxie-font-fallback-oracle"]
                let matches = XCTNSPredicateExpectation(predicate: NSPredicate(format:
                    "label CONTAINS %@ AND NOT label CONTAINS ':wrong'", prefix), object: oracle)
                XCTAssertEqual(XCTWaiter.wait(for: [matches], timeout: 10), .completed,
                               "The actual C hook must select CoreText's face for the typed script")
                XCTAssertTrue(oracle.label.contains(":match"))
            }
            Thread.sleep(forTimeInterval: 1)
            let committed = XCTAttachment(screenshot: app.screenshot())
            committed.name = "text-fallback-\(script)-committed"
            committed.lifetime = .keepAlways
            add(committed)
            app.terminate()
        }
    }
}
