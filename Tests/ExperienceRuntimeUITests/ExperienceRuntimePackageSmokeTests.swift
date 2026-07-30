import XCTest

final class ExperienceRuntimePackageSmokeTests: XCTestCase {
    func testSDKBehaviorPackagesCreateNativeRuntimeSurfaces() throws {
        let app = XCUIApplication()
        let indexedFixtures = [
            "animation-event",
            "external-image",
            "font-converter",
            "multi-screen",
            "scripted-resources",
        ]
        app.launch()

        for fixture in indexedFixtures {
            XCTAssertTrue(
                app.cells["nuxie-fixture-\(fixture)"].waitForExistence(timeout: 10),
                "Expected the host to enumerate \(fixture) from fixture-index.json"
            )
        }

        for fixture in ["animation-event", "external-image", "multi-screen"] {
            let row = app.cells["nuxie-fixture-\(fixture)"]
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            row.tap()

            let surface = app.otherElements["nuxie-experience-surface"]
            XCTAssertTrue(
                surface.waitForExistence(timeout: 15),
                "Expected \(fixture) to authenticate and create a native screen session"
            )
            let status = app.staticTexts
                .matching(identifier: "nuxie-runtime-status")
                .matching(NSPredicate(format: "label == %@", "ready:\(fixture)"))
                .firstMatch
            XCTAssertTrue(status.waitForExistence(timeout: 10))

            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = "signed-package-\(fixture)"
            attachment.lifetime = .keepAlways
            add(attachment)
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
    }
}
