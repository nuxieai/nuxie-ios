import XCTest

final class ExperienceRuntimeReferenceSmokeTests: XCTestCase {
    func testSignedPackagePresentsThroughCustomerSDK() throws {
        let app = XCUIApplication()
        app.launchArguments.append("--nuxie-presentation-diagnostics")
        app.launch()

        XCTAssertTrue(app.otherElements["nuxie-experience-surface"].waitForExistence(timeout: 15))
        XCTAssertTrue(presentedSurface(in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(status("presented:animation-event", in: app).waitForExistence(timeout: 10))

        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "signed-package-animation-event"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSwitchingPackagesCreatesAReplacementSession() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(status("presented:animation-event", in: app).waitForExistence(timeout: 15))

        let selector = app.segmentedControls["nuxie-reference-fixture-selector"]
        XCTAssertTrue(selector.waitForExistence(timeout: 2))
        selector.buttons["multi-screen"].tap()

        XCTAssertTrue(
            status("presented:multi-screen", in: app).waitForExistence(timeout: 15),
            "Expected the replacement signed release to create a new screen session"
        )
    }

    private func status(_ value: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts
            .matching(identifier: "nuxie-runtime-status")
            .matching(NSPredicate(format: "label == %@", value))
            .firstMatch
    }

    private func presentedSurface(in app: XCUIApplication) -> XCUIElement {
        app.otherElements
            .matching(identifier: "nuxie-experience-surface")
            .matching(NSPredicate(
                format: "value MATCHES %@",
                "first-frame-presentation:(confirmed|provisional)"
            ))
            .firstMatch
    }
}
