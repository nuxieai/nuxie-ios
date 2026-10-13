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
        let offer = app.buttons["Explore Parla Plus"]
        XCTAssertTrue(offer.waitForExistence(timeout: 30), app.debugDescription)
        try capture("ios-fullscreen", text: "Say hello")
        offer.tap()
        let save = app.buttons["Save this offer"]
        XCTAssertTrue(save.waitForExistence(timeout: 30), app.debugDescription)
        try capture("ios-medium", text: "Special offer")
        let mediumTop = save.frame.minY
        XCTAssertGreaterThan(mediumTop, app.frame.height * 0.5)
        save.tap()
        let done = app.buttons["Back to learning"]
        XCTAssertTrue(done.waitForExistence(timeout: 30), app.debugDescription)
        try capture("ios-fit-content", text: "Saved!")
        XCTAssertGreaterThan(done.frame.minY, mediumTop)
        swipeSheet(app, title: "Saved!")
        XCTAssertTrue(save.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(done.exists)
        try capture("ios-fit-content-dismissed", text: "Special offer")
        swipeSheet(app, title: "Special offer")
        XCTAssertTrue(offer.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(save.exists)
        try capture("ios-medium-dismissed", text: "Say hello")
    }

    private func swipeSheet(_ app: XCUIApplication, title: String) {
        let heading = app.staticTexts[title]
        let top = heading.frame.minY - 18
        let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.midX, dy: top))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98))
        start.press(forDuration: 0.1, thenDragTo: end)
    }

    private func capture(_ name: String, text: String) throws {
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
        let recognized = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        XCTAssertTrue(recognized.contains(text), "Expected rendered \(text), recognized \(recognized)")
    }
}
