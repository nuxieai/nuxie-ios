import XCTest

final class JapaneseKeyboardTests: XCTestCase {
    func testRealJapaneseComposition() throws {
        continueAfterFailure = false
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        settings.staticTexts["General"].tap()
        settings.staticTexts["Keyboard"].tap()
        settings.cells["KEYBOARDS"].tap()
        if !settings.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Japanese' AND label CONTAINS 'Romaji'")).firstMatch.exists {
            settings.cells["AddNewKeyboard"].tap()
            settings.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Japanese'")).firstMatch.tap()
            settings.staticTexts["Romaji"].tap()
            settings.buttons["Done"].tap()
        }
        settings.terminate()

        let app = XCUIApplication()
        app.launchArguments = ["--nuxie-fixture", "published-two-fields", "--nuxie-hide-navigation", "--nuxie-keyboard-qualification"]
        app.launch()
        let row = app.cells["nuxie-fixture-published-two-fields"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let fields = app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH 'nuxie-text-input-'"))
        XCTAssertTrue(fields.firstMatch.waitForExistence(timeout: 20))
        XCTAssertEqual(fields.count, 2)
        let field = fields.element(boundBy: 0)
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        // Hold the globe and select the real Japanese Romaji keyboard.
        let globe = app.buttons["Next keyboard"]
        if globe.exists {
            globe.press(forDuration: 1)
            let japanese = app.cells.matching(NSPredicate(format: "label CONTAINS '日本語' OR label CONTAINS 'Japanese'")).firstMatch
            XCTAssertTrue(japanese.waitForExistence(timeout: 5))
            japanese.tap()
        }
        for key in ["n", "i", "h", "o", "n"] {
            let button = app.keys[key]
            XCTAssertTrue(button.waitForExistence(timeout: 5), "Japanese Romaji key must be available")
            button.tap()
        }
        let composing = XCTAttachment(screenshot: app.screenshot())
        composing.name = "M8-Japanese-composing"
        composing.lifetime = .keepAlways
        add(composing)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "M8-nonsecure-keyboard-tree"
        tree.lifetime = .keepAlways
        add(tree)
        XCTAssertTrue((field.value as? String)?.contains("にほ") == true, "Real keyboard must produce Japanese composition")
    }
}
