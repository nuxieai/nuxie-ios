import XCTest

final class ExperienceRuntimePackageSmokeTests: XCTestCase {
    /// Installed-app client coverage; this does not simulate VoiceOver gestures.
    func testAccessibilityQualificationHostRunsSignedJourneyWithoutDiagnosticElements() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--nuxie-accessibility-qualification"]
        app.launch()
        let start = app.buttons["start-accessibility-journey"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        let password = app.secureTextFields["Password"]
        XCTAssertTrue(password.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Choose your plan"].exists, app.debugDescription)
        XCTAssertTrue(app.buttons["Continue"].exists, app.debugDescription)
        for identifier in ["nuxie-current-fixture", "nuxie-runtime-status", "nuxie-safe-area-probe"] {
            XCTAssertFalse(app.descendants(matching: .any)[identifier].exists)
        }
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "signed-accessibility-qualification-host"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testNativeTextFieldIsAccessibleAndEditableWithoutDiagnostics() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--nuxie-fixture", "rendered-text-input"]
        app.launch()
        let row = app.cells["nuxie-fixture-rendered-text-input"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()

        let field = app.textFields["nuxie-text-input-text-input/screen_1/email_input"]
        XCTAssertTrue(field.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertEqual(field.value as? String, "levi@nuxie.dev")
        field.tap()
        field.typeText("x")
        XCTAssertEqual(field.value as? String, "levi@nuxie.devx")
        XCTAssertFalse(app.otherElements.matching(NSPredicate(format: "label == %@", "screen_1")).firstMatch.exists)
    }

    func testSDKBehaviorPackagesCreateNativeRuntimeSurfaces() throws {
        let app = XCUIApplication()
        let indexedFixtures = [
            "animation-event",
            "external-image",
            "font-converter",
            "multi-screen",
            "scripted-resources",
        ]
        app.launchArguments.append("--nuxie-presentation-diagnostics")
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
            let presentedSurface = app.otherElements
                .matching(identifier: "nuxie-experience-surface")
                .matching(NSPredicate(
                    format: "value MATCHES %@",
                    "first-frame-presentation:(confirmed|provisional)"
                ))
                .firstMatch
            XCTAssertTrue(
                presentedSurface.waitForExistence(timeout: 10),
                "Expected \(fixture) to confirm a presented drawable"
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
