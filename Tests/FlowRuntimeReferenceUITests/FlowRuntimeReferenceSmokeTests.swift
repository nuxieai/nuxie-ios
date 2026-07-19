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
}
