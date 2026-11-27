import XCTest

/// The machine suite's `router-push` in the runtime host app, driven by the
/// Nux machine, with real swipes. The host launches with
/// `--nuxie-machine-paywall --nuxie-machine-push-stack`; "Finish onboarding"
/// starts a record with `onboarding_completed`, which opens `home`.
///
/// The oracle is the fixture's rows as written, read as the machine's
/// header says a swipe answers them (`Fixtures/router-push/main.test.nux`
/// says the same in Nux), and UIKit's own push, pop and sheet: a page that
/// is pushed slides in over the one below in the same presentation; a swipe
/// back from the edge that closes the page is the navigation controller's
/// own pop; one on a page that takes no swipe back leaves it where it is.
/// Screenshots are kept.
final class PushStackUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testPagesArePushedAndPoppedNativelyInACoverAndInASheet() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--nuxie-machine-paywall", "--nuxie-machine-push-stack"]
        app.launch()
        let finish = app.buttons["nuxie-machine-finish-onboarding"]
        XCTAssertTrue(finish.waitForExistence(timeout: 20), app.debugDescription)
        finish.tap()

        // The first page, a push, arrives as a cover over the whole screen.
        let next = app.buttons["Next"]
        XCTAssertTrue(next.waitForExistence(timeout: 30), app.debugDescription)
        let home = try settled(screen(holding: "Next", app))
        XCTAssertEqual(home.minY, app.frame.minY, "the first page is not a cover: \(home) in \(app.frame)")
        XCTAssertEqual(home.height, app.frame.height, "the first page is not a cover: \(home) in \(app.frame)")
        keep("push-1-home", app)

        // An edge swipe on the first page does nothing.
        edgeSwipe(app, at: home)
        XCTAssertTrue(next.waitForExistence(timeout: 5), "an edge swipe took the first page: \(app.debugDescription)")
        XCTAssertTrue(next.isHittable, app.debugDescription)

        // Two pushes slide in, each over the one below, in the same cover.
        next.tap()
        XCTAssertTrue(app.buttons["Allow"].waitForExistence(timeout: 10), app.debugDescription)
        waitUntilGone(next, "the pushed page did not cover home")
        app.buttons["Deeper"].tap()
        let back = app.buttons["Return"]
        XCTAssertTrue(back.waitForExistence(timeout: 10), app.debugDescription)
        let stuck = try settled(screen(holding: "Return", app))
        XCTAssertEqual(stuck, home, "a pushed page is not laid out as the cover it is in")
        keep("push-2-stuck", app)

        // `stuck` says `swipe=none`: an edge swipe leaves it where it is.
        edgeSwipe(app, at: stuck)
        XCTAssertTrue(back.waitForExistence(timeout: 5), app.debugDescription)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(back.isHittable, "an edge swipe took a page that takes no swipe: \(app.debugDescription)")

        // Its own Return goes back by the machine's pop; then an edge swipe
        // on `step`, whose back is not showing, pops it natively.
        back.tap()
        XCTAssertTrue(app.buttons["Allow"].waitForExistence(timeout: 10), app.debugDescription)
        waitUntilGone(back, "Return did not go back")
        edgeSwipe(app, at: stuck)
        XCTAssertTrue(next.waitForExistence(timeout: 10), "the edge swipe did not pop step: \(app.debugDescription)")
        waitUntilGone(app.buttons["Allow"], "the edge swipe did not pop step")
        waitFor(try screen(holding: "Next", app), valueContaining: "Record: open")
        keep("push-3-after-edge-swipe", app)

        // A sheet over the pages, with a page pushed inside it.
        next.tap()
        XCTAssertTrue(app.buttons["Deeper"].waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["Deeper"].tap()
        XCTAssertTrue(app.buttons["Offer"].waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["Offer"].tap()
        XCTAssertTrue(app.buttons["Enter"].waitForExistence(timeout: 30), app.debugDescription)
        let sheet = try settled(screen(holding: "Enter", app))
        XCTAssertGreaterThan(sheet.minY, 0, "plans is not a sheet: \(sheet)")
        app.buttons["Enter"].tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 10), app.debugDescription)
        waitUntilGone(app.buttons["Enter"], "detail did not cover plans")
        let detail = try settled(screen(holding: "Done", app))
        XCTAssertEqual(detail, sheet, "a page pushed inside the sheet is not laid out as the sheet")
        keep("push-4-detail-in-sheet", app)

        // An edge swipe inside the sheet pops detail, and the sheet stays.
        edgeSwipe(app, at: detail)
        XCTAssertTrue(app.buttons["Enter"].waitForExistence(timeout: 10),
                      "the edge swipe did not pop detail: \(app.debugDescription)")
        waitUntilGone(app.buttons["Done"], "the edge swipe did not pop detail")
        XCTAssertEqual(try settled(screen(holding: "Enter", app)), sheet, "the edge swipe moved the sheet")
        keep("push-5-after-edge-swipe-in-sheet", app)

        // A swipe down on the sheet presses its close, which goes back by
        // the machine's pop: the cover's pages are as they were.
        swipeDown(app, from: sheet)
        waitUntilGone(app.buttons["Enter"], "the swipe down did not close the sheet")
        XCTAssertTrue(back.waitForExistence(timeout: 10), app.debugDescription)
        keep("push-6-after-swipe-down", app)

        // Back through every page: Return, then an edge swipe, home again.
        back.tap()
        XCTAssertTrue(app.buttons["Allow"].waitForExistence(timeout: 10), app.debugDescription)
        edgeSwipe(app, at: home)
        XCTAssertTrue(next.waitForExistence(timeout: 10), app.debugDescription)
        waitUntilGone(app.buttons["Allow"], "the edge swipe did not pop step")
        waitFor(try screen(holding: "Next", app), valueContaining: "Record: open")
        keep("push-7-home-again", app)
    }

    // MARK: Driving the host

    /// The Screen that holds the button `button`.
    private func screen(holding button: String, _ app: XCUIApplication) throws -> XCUIElement {
        let at = app.buttons[button].frame
        let screens = app.descendants(matching: .any).matching(identifier: "nuxie-machine-screen")
            .allElementsBoundByIndex
        return try XCTUnwrap(screens.first { $0.frame.contains(CGPoint(x: at.midX, y: at.midY)) },
                             "no Screen holds \(button): \(app.debugDescription)")
    }

    /// `element`'s frame once it has stopped moving.
    private func settled(_ element: XCUIElement) throws -> CGRect {
        var last = element.frame
        let deadline = Date().addingTimeInterval(10)
        repeat {
            Thread.sleep(forTimeInterval: 0.4)
            let now = element.frame
            if now == last { return now }
            last = now
        } while Date() < deadline
        throw Unsettled(frame: last)
    }

    private struct Unsettled: Error {
        let frame: CGRect
    }

    /// A swipe back from the left edge of `frame`, at its middle, most of
    /// the way across it.
    private func edgeSwipe(_ app: XCUIApplication, at frame: CGRect) {
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let from = origin.withOffset(CGVector(dx: frame.minX + 1, dy: frame.midY))
        let to = origin.withOffset(CGVector(dx: frame.minX + frame.width * 0.8, dy: frame.midY))
        from.press(forDuration: 0.05, thenDragTo: to)
    }

    /// A swipe down most of the way from near the top of the sheet at
    /// `frame`.
    private func swipeDown(_ app: XCUIApplication, from frame: CGRect) {
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let from = CGPoint(x: frame.midX, y: frame.minY + 24)
        let to = CGPoint(x: from.x, y: min(app.frame.maxY - 40, from.y + frame.height * 0.8))
        origin.withOffset(CGVector(dx: from.x, dy: from.y))
            .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: to.x, dy: to.y)))
    }

    /// Wait until `element`'s value, a Screen's, which carries the host's
    /// record line, holds `text`.
    private func waitFor(_ element: XCUIElement, valueContaining text: String) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", text), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 20), .completed,
                       "expected \(text) in \(String(describing: element.value))")
    }

    private func waitUntilGone(_ element: XCUIElement, _ message: String) {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 10), .completed, message)
    }

    /// A screenshot of the app, kept as `name`.
    private func keep(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
