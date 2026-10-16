import CoreText
import UIKit
import XCTest

final class TypedFontFallbackTests: XCTestCase {
    func testPublishedTwoFieldFormRetainsTypedScripts() throws {
        try qualify([("japanese", "日本語"), ("arabic", "مرحبا"),
                     ("hebrew", "שלום"), ("hindi", "नमस्ते"),
                     ("latin", "café é"), ("symbols", "▷ ✶ ●")])
    }

    func testPublishedTwoFieldFormDrawsCommittedColorEmoji() throws {
        try qualify([("emoji", "😀🎉👍🏽")])
    }

    private func qualify(_ samples: [(String, String)]) throws {
        continueAfterFailure = false
        for (script, value) in samples {
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
            if script == "emoji" { XCTAssertEqual(initialValue, "Ada") }
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
            let screenshot = app.screenshot()
            let committed = XCTAttachment(screenshot: screenshot)
            committed.name = "text-fallback-\(script)-committed"
            committed.lifetime = .keepAlways
            add(committed)
            if script == "emoji" {
                let image = try XCTUnwrap(screenshot.image.cgImage)
                let scaleX = CGFloat(image.width) / app.frame.width
                let scaleY = CGFloat(image.height) / app.frame.height
                // Exclude field borders; only the text interior can satisfy the ink check.
                let rect = field.frame.insetBy(dx: 2, dy: 1)
                    .offsetBy(dx: -app.frame.minX, dy: -app.frame.minY)
                let crop = try XCTUnwrap(image.cropping(to: CGRect(x: rect.minX * scaleX,
                    y: rect.minY * scaleY, width: rect.width * scaleX, height: rect.height * scaleY)))
                let attachment = XCTAttachment(image: UIImage(cgImage: crop))
                attachment.name = "text-fallback-emoji-committed-field"
                attachment.lifetime = .keepAlways
                add(attachment)
                XCTAssertGreaterThan(try saturatedPixels(crop), 40,
                    "The committed first field must contain colour emoji, not just a retained string or outline")
            }
            app.terminate()
        }
    }

    private func saturatedPixels(_ image: CGImage) throws -> Int {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return try withExtendedLifetime(bitmap) {
            let bytes = try XCTUnwrap(bitmap.data).assumingMemoryBound(to: UInt8.self)
            return stride(from: 0, to: image.width * image.height * 4, by: 4).reduce(0) { count, at in
                let channels = [bytes[at], bytes[at + 1], bytes[at + 2]]
                return count + (Int(channels.max()!) - Int(channels.min()!) > 60
                    && channels.max()! > 120 ? 1 : 0)
            }
        }
    }
}
