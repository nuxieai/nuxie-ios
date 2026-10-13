import XCTest
import Vision

final class ParlaSheetPresentationTests: XCTestCase {
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
        try tap("Save this offer", observations: medium, app: app)

        let saved = screen("scr_screens_ssaved", app: app)
        waitForPresentation(saved)
        XCTAssertLessThan(saved.frame.height, mediumFrame.height)
        XCTAssertGreaterThan(saved.frame.minY, mediumFrame.minY)
        _ = try capture("ios-fit-content", text: "Saved!")
        swipeSheet(saved, app: app)
        XCTAssertTrue(offer.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(saved.exists)
        _ = try capture("ios-fit-content-dismissed", text: "Special offer")

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
