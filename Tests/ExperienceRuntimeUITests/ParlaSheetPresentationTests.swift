import XCTest
import Vision

final class ParlaSheetPresentationTests: XCTestCase {
    func testPublishedParlaLargeSheetRejectsSwipeDismissal() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--nuxie-sheets-qualification", "--nuxie-sheets-large"]
        app.launch()
        let start = app.buttons["start-accessibility-journey"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "SDK started;")).firstMatch.waitForExistence(timeout: 10))
        app.buttons["open-parla-lesson"].tap()
        let lesson = screen("scr_screens_slesson", app: app)
        waitForPresentation(lesson)
        let fullHeight = lesson.frame.height
        let full = try capture("ios-large-underlay", text: "Say hello")
        try tap("Explore Parla Plus", observations: full, app: app)

        let offer = screen("scr_screens_soffer", app: app)
        waitForPresentation(offer)
        let largeFrame = offer.frame
        // A native large detent fills the available height below platform chrome.
        // The bound uses the running device, not the authored artboard's size.
        XCTAssertGreaterThan(largeFrame.height, fullHeight * 0.8)
        XCTAssertLessThanOrEqual(largeFrame.height, fullHeight)
        _ = try capture("ios-large", text: "Special offer")
        swipeSheet(offer, app: app)
        let afterSwipe = try capture("ios-large-swipe-blocked", text: "Special offer")
        waitForPresentation(offer)
        XCTAssertEqual(offer.frame, largeFrame, "closedby none keeps the native large sheet mounted")

        // Blocking system dismissal must leave the authored control usable.
        try tap("Save this offer", observations: afterSwipe, app: app)
        let saved = screen("scr_screens_ssaved", app: app)
        waitForPresentation(saved)
        XCTAssertLessThan(saved.frame.height, largeFrame.height)
        _ = try capture("ios-large-fit-content", text: "Saved!")
        swipeSheet(saved, app: app)
        _ = try capture("ios-large-revealed", text: "Special offer")
        XCTAssertFalse(saved.exists)
        XCTAssertTrue(offer.exists)
        XCTAssertEqual(offer.frame, largeFrame)
    }

    func testPublishedParlaSheetsAndSwipeDismissal() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--nuxie-sheets-qualification"]
        app.launch()
        let start = app.buttons["start-accessibility-journey"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "SDK started;")).firstMatch.waitForExistence(timeout: 10))
        app.buttons["open-parla-lesson"].tap()

        let lesson = screen("scr_screens_slesson", app: app)
        waitForPresentation(lesson)
        let fullscreenFrame = lesson.frame
        XCTAssertEqual(fullscreenFrame.width, app.frame.width, accuracy: 1)
        XCTAssertEqual(fullscreenFrame.height, app.frame.height, accuracy: 1)
        let full = try capture("ios-fullscreen", text: "Say hello")
        try tap("Explore Parla Plus", observations: full, app: app)

        let offer = screen("scr_screens_soffer", app: app)
        waitForPresentation(offer)
        let mediumFrame = offer.frame
        XCTAssertGreaterThan(mediumFrame.height, fullscreenFrame.height * 0.4)
        XCTAssertLessThan(mediumFrame.height, fullscreenFrame.height * 0.6)
        let medium = try capture("ios-medium", text: "Special offer")
        let lessonTitle = try XCTUnwrap(full.first { $0.topCandidates(1).first?.string == "Say hello" })
        let coveredLessonTitle = try XCTUnwrap(medium.first { $0.topCandidates(1).first?.string == "Say hello" })
        XCTAssertEqual(lessonTitle.boundingBox.midY, coveredLessonTitle.boundingBox.midY,
            accuracy: 2 / app.frame.height, "Opening a sheet must retain the lesson's own safe-area padding")
        try tap("Save this offer", observations: medium, app: app)

        let saved = screen("scr_screens_ssaved", app: app)
        waitForPresentation(saved)
        XCTAssertLessThan(saved.frame.height, mediumFrame.height)
        XCTAssertGreaterThan(saved.frame.minY, mediumFrame.minY)
        let savedText = try capture("ios-fit-content", text: "Saved!")
        try tap("Back to learning", observations: savedText, app: app)
        XCTAssertTrue(offer.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(saved.exists)
        let revealedOffer = try capture("ios-fit-content-dismissed", text: "Special offer")
        XCTAssertEqual(offer.frame, mediumFrame)
        // A second authored Save proves the Journey is still parked on Offer.
        try tap("Save this offer", observations: revealedOffer, app: app)
        waitForPresentation(saved)
        _ = try capture("ios-fit-content-open-again", text: "Saved!")
        swipeSheet(saved, app: app)
        _ = try capture("ios-fit-content-swiped", text: "Special offer")

        swipeSheet(offer, app: app)
        XCTAssertTrue(lesson.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(offer.exists)
        XCTAssertEqual(lesson.frame, fullscreenFrame)
        _ = try capture("ios-medium-dismissed", text: "Say hello")
    }

    private func screen(_ id: String, app: XCUIApplication) -> XCUIElement {
        app.otherElements.matching(identifier: "nuxie-experience-surface")
            .matching(NSPredicate(format: "label == %@", id)).firstMatch
    }

    private func waitForPresentation(_ screen: XCUIElement) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(
            format: "exists == true AND value MATCHES %@", "first-frame-presentation:(confirmed|provisional)"), object: screen)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed)
    }

    private func tap(_ label: String, observations: [VNRecognizedTextObservation], app: XCUIApplication) throws {
        let observation = try XCTUnwrap(observations.first { $0.topCandidates(1).first?.string == label })
        let box = observation.boundingBox
        app.coordinate(withNormalizedOffset: CGVector(dx: box.midX, dy: 1 - box.midY)).tap()
    }

    private func swipeSheet(_ screen: XCUIElement, app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: app.frame.midX, dy: screen.frame.minY + 12))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98))
        start.press(forDuration: 0.1, thenDragTo: end)
    }

    private func capture(_ name: String, text: String) throws -> [VNRecognizedTextObservation] {
        Thread.sleep(forTimeInterval: 1)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let banner = springboard.descendants(matching: .any).matching(identifier: "NotificationShortLookView").firstMatch
        if banner.exists {
            banner.swipeUp()
            Thread.sleep(forTimeInterval: 1)
        }
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let image = try XCTUnwrap(screenshot.image.cgImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: image).perform([request])
        let observations = request.results ?? []
        let recognized = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        XCTAssertTrue(recognized.contains(text), "Expected rendered \(text), recognized \(recognized)")
        return observations
    }
}
