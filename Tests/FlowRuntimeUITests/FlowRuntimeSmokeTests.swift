import UIKit
import XCTest

final class FlowRuntimeSmokeTests: XCTestCase {
    private var app: XCUIApplication!
    private let fixtureNames = [
        "layout-paint",
        "published-font",
        "pressable-interaction",
    ]
    private let transitionEventName = "__nuxie_test_run_transition"

    override func setUpWithError() throws {
        continueAfterFailure = false

        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    func testPublishedFixturesRenderAndHandleNativeInput() throws {
        app.launchArguments = [
            "--nuxie-fixtures",
            fixtureNames.joined(separator: ","),
        ]
        app.launch()

        try selectFixture(named: "layout-paint")
        try waitForSurface()
        app.otherElements["nuxie-flow-surface"]
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .tap()
        try captureScreenshot(named: "layout-paint")

        try selectFixture(named: "published-font")
        try waitForSurface()

        let emailField = app.textFields["nuxie-text-input-text-input/screen_1/email_input"]
        XCTAssertTrue(
            emailField.waitForExistence(timeout: 10),
            "Expected the published editable text input overlay to mount"
        )

        emailField.tap()
        emailField.typeText("+native")

        XCTAssertTrue(
            emailField.waitForValue(containing: "+native", timeout: 5),
            "Expected typing in the native overlay to update the UIKit text input"
        )

        try captureScreenshot(named: "published-font")

        try selectFixture(named: "pressable-interaction")
        try waitForSurface()

        let surface = app.otherElements["nuxie-flow-surface"]
        let pressPoint = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let releasePoint = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.22))

        Thread.sleep(forTimeInterval: 0.3)
        try captureScreenshot(named: "pressable-interaction-released-before")

        try captureScreenshotDuringGesture(
            named: "pressable-interaction-pressed",
            after: 0.35
        ) {
            pressPoint.press(forDuration: 0.8, thenDragTo: releasePoint)
        }

        Thread.sleep(forTimeInterval: 0.25)
        try captureScreenshot(named: "pressable-interaction-released-after")

        pressPoint.tap()

        let eventLog = app.staticTexts["nuxie-flow-event-log"]
        XCTAssertTrue(
            eventLog.waitForExistence(timeout: 5),
            "Expected the fixture runtime event log to mount"
        )
        XCTAssertTrue(
            eventLog.waitForLabel(containing: "screen:screen_2", timeout: 10),
            "Expected tapping the published Pressable to emit a native interaction and reach the target screen"
        )

        try captureScreenshot(named: "pressable-interaction")
    }

    func testPublishedScriptedPressableWritesResponseFieldThroughJourneyRunner() throws {
        try launchFixture(
            named: "scripted-response-set",
            scenarioTitle: "Published listenerAction script writes a response field",
            scenarioExpectation: "Tap the published Pressable; the script should call Nuxie.response.set and the fixture runner should record the response write."
        )

        try waitForSurface()
        let surface = app.otherElements["nuxie-flow-surface"]
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.86)).tap()

        let eventLog = app.staticTexts["nuxie-flow-event-log"]
        XCTAssertTrue(
            eventLog.waitForExistence(timeout: 10),
            "Expected the fixture runtime event log to mount"
        )
        XCTAssertTrue(
            eventLog.waitForLabel(containing: "response_set:plan=pro", timeout: 10),
            "Expected tapping the published scripted Pressable to write the response field through the journey runner; event log: \(eventLog.label)"
        )
    }

    func testTextInputMotionMovesWholeEditableField() throws {
        try launchFixture(
            named: "text-input-motion",
            scenarioTitle: "Animated TextInput follows its rendered field",
            scenarioExpectation: "The entire TextInput node moves to the right; the native editor overlay should stay aligned with the Rive field background."
        )

        try waitForSurface()
        let movingFieldIdentifier = "nuxie-text-input-text-input/screen_1/email_input"
        let emailField = app.textFields[movingFieldIdentifier]
        XCTAssertTrue(
            emailField.waitForExistence(timeout: 10),
            "Expected the moving editable text input overlay to mount"
        )

        let initialMovingFieldFrame = emailField.frame
        XCTAssertGreaterThan(initialMovingFieldFrame.width, 1, "Expected the text input overlay to have a visible width")
        XCTAssertGreaterThan(initialMovingFieldFrame.height, 1, "Expected the text input overlay to have a visible height")
        try captureScreenshot(named: "text-input-motion-before")

        Thread.sleep(forTimeInterval: 1.4)
        let movedFieldFrame = emailField.frame
        XCTAssertGreaterThan(movedFieldFrame.width, 1, "Expected the text input overlay to remain visible after animation playback")
        XCTAssertGreaterThan(movedFieldFrame.height, 1, "Expected the text input overlay to remain visible after animation playback")

        try captureScreenshot(named: "text-input-motion-after")
        pauseForRecordedReview()
    }

    func testSystemPushTransitionUsesTwoLiveRiveSurfacesUntilCompletion() throws {
        try launchFixture(
            named: "screen-transition-push",
            manualEventName: transitionEventName,
            scenarioTitle: "System push: screen_1 -> screen_2",
            scenarioExpectation: "Tap Run transition; screen_2 should push in as a second live Rive surface, then become current."
        )

        try waitForSurface()
        let eventLog = app.staticTexts["nuxie-flow-event-log"]
        XCTAssertTrue(
            eventLog.waitForExistence(timeout: 10),
            "Expected the fixture runtime event log to mount"
        )

        pauseForRecordedReview()
        try captureScreenshot(named: "screen-transition-push-before")
        tapManualStart()

        XCTAssertTrue(
            eventLog.waitForLabel(containing: "navigated:screen_2", timeout: 10),
            "Expected the fixture start action to request a push transition"
        )
        pauseForRecordedReview(0.2)
        try captureScreenshot(named: "screen-transition-push-during")

        XCTAssertTrue(
            eventLog.waitForLabel(containing: "screen:screen_2", timeout: 10),
            "Expected screen_shown to arrive after the push transition completes"
        )
        pauseForRecordedReview()
        try captureScreenshot(named: "screen-transition-push-after")
    }

    func testSystemModalTransitionReachesDestinationScreen() throws {
        try launchFixture(
            named: "screen-transition-push",
            variant: "modal",
            manualEventName: transitionEventName,
            scenarioTitle: "System modal: screen_1 opens screen_2",
            scenarioExpectation: "Tap Run transition; UIKit should open screen_2 as a native sheet modal with its own live Rive surface."
        )

        try waitForSurface()
        pauseForRecordedReview()
        tapManualStart()
        pauseForRecordedReview(0.2)
        try captureScreenshot(named: "screen-transition-modal-during")

        XCTAssertTrue(
            waitForSurfaceLabel(containing: "screen_2", timeout: 10),
            "Expected the presented sheet controller to mount a live screen_2 Rive surface"
        )

        let presentedSurface = surfaceElement(containing: "screen_2")
        XCTAssertTrue(
            presentedSurface.exists,
            "Expected to locate the presented screen_2 surface"
        )
        XCTAssertGreaterThan(
            presentedSurface.frame.minY,
            app.windows.element(boundBy: 0).frame.minY + 1,
            "Expected modal transition to use a sheet modal, not a full-screen cover"
        )
        pauseForRecordedReview()
        try captureScreenshot(named: "screen-transition-modal-after")
    }

    func testSystemModalSwipeDismissReturnsToPresentingScreen() throws {
        try launchFixture(
            named: "screen-transition-push",
            variant: "modal",
            manualEventName: transitionEventName,
            scenarioTitle: "System modal dismissal: screen_2 -> screen_1",
            scenarioExpectation: "Tap Run transition; swipe down the sheet. The coordinator should report screen_2 dismissed and the journey should return to screen_1."
        )

        try waitForSurface()
        let eventLog = app.staticTexts["nuxie-flow-event-log"]
        XCTAssertTrue(
            eventLog.waitForExistence(timeout: 10),
            "Expected the fixture runtime event log to mount"
        )

        pauseForRecordedReview()
        tapManualStart()
        XCTAssertTrue(
            waitForSurfaceLabel(containing: "screen_2", timeout: 10),
            "Expected the presented sheet controller to mount a live screen_2 Rive surface"
        )
        pauseForRecordedReview()
        try captureScreenshot(named: "screen-transition-modal-dismissible-before")

        let presentedSurface = surfaceElement(containing: "screen_2")
        let start = presentedSurface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08))
        let end = app.windows.element(boundBy: 0).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92))
        start.press(forDuration: 0.1, thenDragTo: end)

        XCTAssertTrue(
            eventLog.waitForLabel(containing: "screen_dismissed:screen_2", timeout: 10),
            "Expected native sheet dismissal to be reported to the fixture runner"
        )
        XCTAssertTrue(
            eventLog.waitForLabel(containing: "screen:screen_1", timeout: 10),
            "Expected native sheet dismissal to reveal and re-enter screen_1"
        )
        XCTAssertTrue(
            waitForSurfaceLabel(containing: "screen_1", timeout: 10),
            "Expected the underlying screen_1 Rive surface to be current after sheet dismissal"
        )
        pauseForRecordedReview()
        try captureScreenshot(named: "screen-transition-modal-dismissible-after")
    }

    func testBackTransitionReturnsWithPushPayload() throws {
        try launchFixture(
            named: "screen-transition-push",
            variant: "back-push",
            initialNavigationStack: ["screen_1"],
            manualEventName: transitionEventName,
            scenarioTitle: "Back transition: screen_2 -> screen_1",
            scenarioExpectation: "Tap Run transition; screen_2 pushes in, then its screen_shown action backs out to screen_1."
        )

        try waitForSurface()
        let eventLog = app.staticTexts["nuxie-flow-event-log"]
        XCTAssertTrue(
            eventLog.waitForExistence(timeout: 10),
            "Expected the fixture runtime event log to mount"
        )

        pauseForRecordedReview()
        tapManualStart()

        XCTAssertTrue(
            eventLog.waitForLabel(containing: "navigated:screen_2", timeout: 10),
            "Expected the fixture start action to push to screen_2"
        )
        XCTAssertTrue(
            eventLog.waitForLabel(containing: "screen:screen_2", timeout: 10),
            "Expected the destination screen to be shown before the back action runs"
        )
        XCTAssertTrue(
            eventLog.waitForLabel(containing: "navigated:screen_1", timeout: 10),
            "Expected the screen_2 screen_shown interaction to request back with a push transition"
        )
        pauseForRecordedReview(0.2)
        try captureScreenshot(named: "screen-transition-back-push-during")

        XCTAssertTrue(
            eventLog.waitForLabel(containing: "screen:screen_1", timeout: 10),
            "Expected the push back transition to complete on screen_1"
        )
        pauseForRecordedReview()
        try captureScreenshot(named: "screen-transition-back-push-after")
    }

    func testReduceMotionFallsBackToImmediateReplacement() throws {
        try launchFixture(
            named: "screen-transition-push",
            variant: "reduce-motion-fade",
            forceReduceMotion: true,
            manualEventName: transitionEventName,
            scenarioTitle: "Reduce motion: skip authored fade",
            scenarioExpectation: "Tap Run transition; the fixture asks for a fade, but forced reduce motion should replace it immediately."
        )

        try waitForSurface()
        let eventLog = app.staticTexts["nuxie-flow-event-log"]
        XCTAssertTrue(
            eventLog.waitForExistence(timeout: 10),
            "Expected the fixture runtime event log to mount"
        )

        pauseForRecordedReview()
        let startButton = waitForManualStartButton()
        let startedAt = Date()
        startButton.tap()
        XCTAssertTrue(
            eventLog.waitForLabel(containing: "screen:screen_2", timeout: 3.5),
            "Expected forced reduce motion to skip the authored fade and show screen_2 quickly"
        )
        XCTAssertLessThan(
            Date().timeIntervalSince(startedAt),
            3.5,
            "Expected reduce motion replacement to complete quickly"
        )
        pauseForRecordedReview()
        try captureScreenshot(named: "screen-transition-reduce-motion-after")
    }

    func testTextInputOverlayRebindsAfterBackTransition() throws {
        try launchFixture(
            named: "screen-transition-push",
            variant: "back-push",
            initialNavigationStack: ["screen_1"],
            manualEventName: transitionEventName,
            scenarioTitle: "Static native text input survives screen transitions",
            scenarioExpectation: "Tap Run transition; after push and back, the UIKit text input overlay should remount on screen_1 and remain editable."
        )

        try waitForSurface()
        let eventLog = app.staticTexts["nuxie-flow-event-log"]
        XCTAssertTrue(
            eventLog.waitForExistence(timeout: 10),
            "Expected the fixture runtime event log to mount"
        )
        pauseForRecordedReview()
        tapManualStart()
        XCTAssertTrue(
            eventLog.waitForLabel(containing: "navigated:screen_2", timeout: 10),
            "Expected the fixture to navigate away from the input-owning screen"
        )
        XCTAssertTrue(
            eventLog.waitForLabel(containing: "screen:screen_2", timeout: 10),
            "Expected the destination screen to be shown before the back action runs"
        )
        XCTAssertTrue(
            eventLog.waitForLabel(containing: "navigated:screen_1", timeout: 10),
            "Expected the screen_2 screen_shown interaction to request the back transition"
        )
        XCTAssertTrue(
            eventLog.waitForLabel(containing: "screen:screen_1", timeout: 10),
            "Expected the fixture to complete back on the input-owning screen"
        )

        let emailField = app.textFields["nuxie-text-input-text-input/screen_1/email_input"]
        XCTAssertTrue(
            emailField.waitForExistence(timeout: 10),
            "Expected the screen_1 editable text input overlay to remount after the back transition"
        )
        XCTAssertTrue(
            emailField.isHittable,
            "Expected the remounted text input overlay to be active on the current screen"
        )

        emailField.tap()
        emailField.typeText("+afterback")
        XCTAssertTrue(
            emailField.waitForValue(containing: "+afterback", timeout: 5),
            "Expected typing after the transition to update the rebound UIKit text input"
        )
        pauseForRecordedReview()
        try captureScreenshot(named: "screen-transition-text-input-after-back")
    }

    private func launchFixture(
        named fixtureName: String,
        variant: String? = nil,
        initialNavigationStack: [String] = [],
        forceReduceMotion: Bool = false,
        manualEventName: String? = nil,
        scenarioTitle: String? = nil,
        scenarioExpectation: String? = nil
    ) throws {
        var arguments = [
            "--nuxie-fixture",
            fixtureName,
        ]
        if let variant {
            arguments.append(contentsOf: [
                "--nuxie-flow-description-variant",
                variant,
            ])
        }
        if forceReduceMotion {
            arguments.append("--nuxie-force-reduce-motion")
        }
        if let manualEventName {
            arguments.append(contentsOf: [
                "--nuxie-manual-event",
                manualEventName,
                "--nuxie-show-screen-debug-badges",
            ])
        }
        if !initialNavigationStack.isEmpty {
            arguments.append(contentsOf: [
                "--nuxie-initial-navigation-stack",
                initialNavigationStack.joined(separator: ","),
            ])
        }
        if let scenarioTitle {
            arguments.append(contentsOf: [
                "--nuxie-scenario-title",
                scenarioTitle,
            ])
        }
        if let scenarioExpectation {
            arguments.append(contentsOf: [
                "--nuxie-scenario-expectation",
                scenarioExpectation,
            ])
        }
        app.launchArguments = arguments
        app.launch()
        try selectFixture(named: fixtureName)
    }

    private func selectFixture(named fixtureName: String) throws {
        let currentFixtureLabel = app.staticTexts["nuxie-current-fixture"]
        if currentFixtureLabel.exists && currentFixtureLabel.label == fixtureName {
            return
        }

        if currentFixtureLabel.exists {
            let backButton = app.navigationBars.buttons["Fixtures"]
            XCTAssertTrue(
                backButton.waitForExistence(timeout: 10),
                "Expected navigation back button to return to the fixture list"
            )
            backButton.tap()
        }

        let fixtureRow = app.cells["nuxie-fixture-\(fixtureName)"]
        XCTAssertTrue(
            fixtureRow.waitForExistence(timeout: 10),
            "Expected fixture table row for \(fixtureName)"
        )
        fixtureRow.tap()
    }

    private func waitForSurface() throws {
        let surface = app.otherElements["nuxie-flow-surface"]
        XCTAssertTrue(
            surface.waitForExistence(timeout: 20),
            "Expected the native Rive flow surface to mount"
        )
    }

    private func waitForSurfaceLabel(containing expectedValue: String, timeout: TimeInterval) -> Bool {
        let query = app.otherElements.matching(identifier: "nuxie-flow-surface")
        let predicate = NSPredicate { _, _ in
            guard query.count > 0 else { return false }
            for index in 0..<query.count {
                if query.element(boundBy: index).label.contains(expectedValue) {
                    return true
                }
            }
            return false
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func surfaceElement(containing expectedValue: String) -> XCUIElement {
        let query = app.otherElements.matching(identifier: "nuxie-flow-surface")
        for index in 0..<query.count {
            let element = query.element(boundBy: index)
            if element.label.contains(expectedValue) {
                return element
            }
        }
        return query.element(boundBy: 0)
    }

    private func tapManualStart() {
        waitForManualStartButton().tap()
    }

    private func waitForManualStartButton() -> XCUIElement {
        let button = app.buttons["nuxie-flow-manual-start"]
        XCTAssertTrue(
            button.waitForExistence(timeout: 10),
            "Expected the fixture harness to show the manual start control"
        )
        return button
    }

    private func pauseForRecordedReview(_ duration: TimeInterval = 0.45) {
        Thread.sleep(forTimeInterval: duration)
    }

    @discardableResult
    private func captureScreenshot(named name: String) throws -> XCUIScreenshot {
        let screenshot = XCUIScreen.main.screenshot()
        try recordScreenshot(screenshot, named: name)
        return screenshot
    }

    private func captureScreenshotDuringGesture(
        named name: String,
        after delay: TimeInterval,
        gesture: () -> Void
    ) throws -> XCUIScreenshot {
        let expectation = expectation(description: "capture \(name)")
        let lock = NSLock()
        var capturedScreenshot: XCUIScreenshot?

        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) {
            let screenshot = XCUIScreen.main.screenshot()
            lock.lock()
            capturedScreenshot = screenshot
            lock.unlock()
            expectation.fulfill()
        }

        gesture()

        XCTAssertEqual(
            XCTWaiter().wait(for: [expectation], timeout: delay + 2),
            .completed,
            "Expected to capture \(name) while the gesture was still active"
        )

        lock.lock()
        let screenshot = capturedScreenshot
        lock.unlock()

        guard let screenshot else {
            throw FlowRuntimeUITestError.missingScreenshot(name)
        }

        try recordScreenshot(screenshot, named: name)
        return screenshot
    }

    private func recordScreenshot(_ screenshot: XCUIScreenshot, named name: String) throws {
        XCTContext.runActivity(named: "Screenshot: \(name)") { activity in
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }

        guard let outputDirectory = ProcessInfo.processInfo.environment["NUXIE_FLOW_RUNTIME_OUTPUT_DIR"],
              !outputDirectory.isEmpty else {
            return
        }

        let screenshotsURL = URL(fileURLWithPath: outputDirectory)
            .appendingPathComponent("screenshots", isDirectory: true)
        try FileManager.default.createDirectory(
            at: screenshotsURL,
            withIntermediateDirectories: true
        )
        try screenshot.pngRepresentation.write(
            to: screenshotsURL.appendingPathComponent("\(name).png"),
            options: .atomic
        )
    }

}

private extension XCUIElement {
    func waitForLabel(containing expectedValue: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", expectedValue)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    func waitForValue(containing expectedValue: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "value CONTAINS %@", expectedValue)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}

private enum FlowRuntimeUITestError: Error {
    case missingScreenshot(String)
}
