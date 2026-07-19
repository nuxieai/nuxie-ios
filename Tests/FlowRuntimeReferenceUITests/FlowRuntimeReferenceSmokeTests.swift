import XCTest

final class FlowRuntimeReferenceSmokeTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testCurrentRivPresentsThroughStandaloneRustRuntimeApp() throws {
        let app = XCUIApplication()
        app.launch()

        let surface = app.otherElements["nuxie-runtime-metal-surface"]
        XCTAssertTrue(
            surface.waitForExistence(timeout: 10),
            "Expected the standalone CAMetalLayer-backed runtime surface"
        )

        let presented = app.staticTexts
            .matching(identifier: "nuxie-runtime-status")
            .matching(NSPredicate(format: "label == %@", "presented:layout-paint"))
            .firstMatch
        XCTAssertTrue(
            presented.waitForExistence(timeout: 10),
            "Expected a positive first-frame presentation result from NuxieRuntime"
        )

        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "nuxie-runtime-layout-paint-presented"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSwitchingFixturesStartsTheReplacementRenderer() throws {
        let app = XCUIApplication()
        app.launch()

        let initialStatus = app.staticTexts
            .matching(identifier: "nuxie-runtime-status")
            .matching(NSPredicate(format: "label == %@", "presented:layout-paint"))
            .firstMatch
        XCTAssertTrue(initialStatus.waitForExistence(timeout: 10))

        let fixtureSelector = app.segmentedControls["nuxie-reference-fixture-selector"]
        XCTAssertTrue(fixtureSelector.waitForExistence(timeout: 2))
        fixtureSelector.buttons["pressable-interaction"].tap()

        let replacementStatus = app.staticTexts
            .matching(identifier: "nuxie-runtime-status")
            .matching(NSPredicate(format: "label == %@", "presented:pressable-interaction"))
            .firstMatch
        XCTAssertTrue(
            replacementStatus.waitForExistence(timeout: 10),
            "Expected the replacement child to start its Rust renderer"
        )
    }
}
