import UIKit
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
        let alone = try segmentNow(app, pages: 1, kept: "push-segment-plans")
        app.buttons["Enter"].tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 10), app.debugDescription)
        waitUntilGone(app.buttons["Enter"], "detail did not cover plans")
        let detail = try settled(screen(holding: "Done", app))
        XCTAssertEqual(detail, sheet, "a page pushed inside the sheet is not laid out as the sheet")
        let pushed = try segmentNow(app, pages: 2, kept: "push-segment-detail")
        try expectPlacedAsTheSheet(pushed, alone, seen: detail, app)
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

    // MARK: Where a pushed page is placed

    /// The top segment as the host reads it (`nuxie-machine-segment`): its
    /// view's frame in its window, the safe-area insets UIKit gives that
    /// view, how many pages it holds, and the place its page on top is told.
    private struct SegmentFacts: Equatable {
        let frame: CGRect
        let insets: UIEdgeInsets
        let pages: Int
        let placeInsets: UIEdgeInsets
        let placeSize: CGSize

        init?(_ text: String) {
            let numbers = text.split(separator: " ").compactMap { Double($0) }
            guard text.hasPrefix("segment "), text.contains(" place "), numbers.count == 15 else { return nil }
            frame = CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
            insets = UIEdgeInsets(top: numbers[4], left: numbers[7], bottom: numbers[6], right: numbers[5])
            pages = Int(numbers[8])
            placeInsets = UIEdgeInsets(top: numbers[9], left: numbers[12], bottom: numbers[11], right: numbers[10])
            placeSize = CGSize(width: numbers[13], height: numbers[14])
        }
    }

    /// The top segment once it holds `pages` pages, its page on top has a
    /// place, and two readings a moment apart agree; kept as the text
    /// attachment `name`.
    private func segmentNow(_ app: XCUIApplication, pages: Int, kept name: String) throws -> SegmentFacts {
        let shown = app.descendants(matching: .any)["nuxie-machine-segment"]
        XCTAssertTrue(shown.waitForExistence(timeout: 10), "the host does not show the segment")
        let deadline = Date().addingTimeInterval(20)
        var last = ""
        while Date() < deadline {
            let text = shown.label
            if text == last, let facts = SegmentFacts(text), facts.pages == pages {
                let note = XCTAttachment(string: text)
                note.name = name
                note.lifetime = .keepAlways
                add(note)
                return facts
            }
            last = text
            Thread.sleep(forTimeInterval: 0.6)
        }
        throw Unread(what: "the segment with \(pages) pages and a place", last: last)
    }

    /// The window's safe-area insets as the host reads them
    /// (`nuxie-machine-safe-area`, `T R B L`).
    private func screenInsets(_ app: XCUIApplication) throws -> UIEdgeInsets {
        let shown = app.descendants(matching: .any)["nuxie-machine-safe-area"]
        XCTAssertTrue(shown.waitForExistence(timeout: 10), "the host does not show the safe area")
        let numbers = shown.label.split(separator: " ").compactMap { Double($0) }
        guard numbers.count == 4 else { throw Unread(what: "the safe area", last: shown.label) }
        return UIEdgeInsets(top: numbers[0], left: numbers[3], bottom: numbers[2], right: numbers[1])
    }

    private struct Unread: Error {
        let what: String
        let last: String
    }

    /// The page pushed inside the sheet is placed as the sheet, in numbers:
    ///
    /// - the sheet is where a sheet is: below the top of the screen, down
    ///   to its bottom, so UIKit gives it the screen's bottom inset and less
    ///   than the screen's top one;
    /// - the push neither moved nor resized it, and the pushed page's
    ///   Screen, as the screen reader finds it, covers it exactly (`seen`);
    /// - the pushed page is told the sheet's own size and the insets UIKit
    ///   gives the sheet, which is the place the sheet's first page was
    ///   told (`alone`).
    private func expectPlacedAsTheSheet(_ pushed: SegmentFacts, _ alone: SegmentFacts, seen: CGRect,
                                        _ app: XCUIApplication) throws {
        let screen = try screenInsets(app)
        let sheet = pushed.frame
        XCTAssertGreaterThan(sheet.minY, 0, "the sheet starts at the top of the screen: \(sheet)")
        XCTAssertEqual(sheet.maxY, app.frame.maxY, accuracy: 0.5, "the sheet does not reach the bottom: \(sheet)")
        XCTAssertEqual(pushed.insets.bottom, screen.bottom, accuracy: 0.5,
                       "the sheet is not given the screen's bottom inset: \(pushed.insets) on \(screen)")
        XCTAssertLessThan(pushed.insets.top, screen.top, "the sheet is given the status bar: \(pushed.insets)")

        XCTAssertEqual(pushed.frame, alone.frame, "the push moved or resized the sheet")
        XCTAssertEqual(pushed.insets, alone.insets, "the push changed the sheet's insets")
        for (got, want, side) in [(seen.minX, sheet.minX, "left"), (seen.minY, sheet.minY, "top"),
                                  (seen.width, sheet.width, "width"), (seen.height, sheet.height, "height")] {
            XCTAssertEqual(got, want, accuracy: 0.5, "the pushed page's \(side) is not the sheet's: \(seen) in \(sheet)")
        }

        XCTAssertEqual(pushed.placeSize, sheet.size, "the pushed page is not told the sheet's size")
        XCTAssertEqual(pushed.placeInsets, pushed.insets, "the pushed page is not told the sheet's insets")
        XCTAssertEqual(pushed.placeInsets, alone.placeInsets, "the pushed page is placed apart from the sheet's first page")
        XCTAssertEqual(pushed.placeSize, alone.placeSize, "the pushed page is placed apart from the sheet's first page")
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
