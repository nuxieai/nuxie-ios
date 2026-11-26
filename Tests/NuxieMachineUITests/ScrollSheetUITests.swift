import UIKit
import XCTest

/// A paywall whose page is a `scroll`, shown as a native sheet in the
/// runtime host app, driven by the Nux machine, with no person. The host
/// launches with `--nuxie-machine-paywall --nuxie-machine-scroll-sheet`;
/// "Finish onboarding" starts a record with `onboarding_completed`, and the
/// machine opens the `views-scroll` paywall as a sheet: a header 120 points
/// tall with the app's name, the page's `scroll` below it, and a "Restore"
/// button floating over the page near its bottom right.
///
/// The sheet's swipe and the page share the vertical drag. A drag that goes
/// down outside the `scroll` pulls the sheet, as on any sheet. Over the
/// `scroll`, the page keeps the drag (up, sideways, or down while it is
/// scrolled), except a drag down while it is at its top, which pulls the
/// sheet. Every drag is a real drag on the simulator.
///
/// Where the page stands is read from where its title is, an element made
/// from the engine's semantic snapshot; whether the sheet stayed from its
/// frame; and the record's state from the Screen's accessibility value while
/// the sheet is up and the host's line once it is gone. A screenshot is kept
/// after each drag.
///
/// These tests check what the sheet's answer owns: whether the sheet takes
/// the drag, and that a drag it leaves to the page reaches the page. What
/// the page then does with a drag that is not up and down (a sideways drag
/// on a card, or one that starts on the floating button) is the engine's,
/// and is not checked here.
final class ScrollSheetUITests: XCTestCase {
    private static let title = "Sleep better, a little every night."

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// 1. Dragged up over the page: the page scrolls and the sheet stays.
    func testADragUpScrollsThePageAndKeepsTheSheet() throws {
        let (app, screen) = try openSheet()
        let resting = screen.frame
        let title = app.staticTexts[Self.title]
        let before = try settled(title)

        let from = pagePoint(on: resting, at: 0.7)
        drag(app, from: from, to: CGPoint(x: from.x, y: from.y - 300))
        let after = try settled(title)
        keep("1-dragged-up", app)
        XCTAssertLessThan(after.minY, before.minY - 100, "the page did not scroll up: the title was at \(before), "
                          + "and is at \(after)")
        XCTAssertEqual(screen.frame, resting, "the sheet moved")
        waitFor(screen, valueContaining: "Record: open")
    }

    /// 2. Scrolled, then dragged down over the page: the page moves back
    ///    toward its top and the sheet stays for that drag.
    func testADragDownOnAScrolledPageScrollsBackAndKeepsTheSheet() throws {
        let (app, screen) = try openSheet()
        let resting = screen.frame
        let title = app.staticTexts[Self.title]
        let top = try settled(title)
        let from = pagePoint(on: resting, at: 0.7)
        drag(app, from: from, to: CGPoint(x: from.x, y: from.y - 300))
        let scrolled = try settled(title)
        XCTAssertLessThan(scrolled.minY, top.minY - 100, "the page did not scroll up first")

        let down = pagePoint(on: resting, at: 0.4)
        drag(app, from: down, to: CGPoint(x: down.x, y: down.y + 150))
        let back = try settled(title)
        keep("2-scrolled-then-dragged-down", app)
        XCTAssertTrue(screen.exists, "the drag took the sheet")
        XCTAssertEqual(screen.frame, resting, "the sheet moved")
        XCTAssertGreaterThan(back.minY, scrolled.minY + 40, "the page did not move back toward its top: the "
                             + "title was at \(scrolled) and is at \(back)")
        waitFor(screen, valueContaining: "Record: open")
    }

    /// 3. At its top, dragged down over the page: the sheet is pulled and
    ///    dismissed, and the machine hears `closed`, which ends the record.
    func testADragDownOnAPageAtItsTopTakesTheSheet() throws {
        let (app, screen) = try openSheet()
        let sheet = screen.frame
        let from = pagePoint(on: sheet, at: 0.35)
        let bottom = try insets(app).bottom
        let to = CGPoint(x: from.x, y: min(app.frame.maxY - bottom - 8, from.y + sheet.height * 0.6))
        drag(app, from: from, to: to)
        waitUntilGone(screen, "the drag from \(from) to \(to) on a page at its top did not take the sheet \(sheet)")
        waitFor(app.staticTexts["nuxie-machine-record"], labelContaining: "Record: ended")
        keep("3-pulled-at-the-top", app)
    }

    /// 4. A sideways drag over the page, starting on a plan card: the sheet
    ///    stays and nothing scrolls. Which card does not matter: Monthly's
    ///    when its card is wholly on screen in the sheet, otherwise Yearly's
    ///    (on a short phone Monthly is below the fold, and the screen reader
    ///    does not read it). The drag runs along a row of the card's visible
    ///    part, above the screen's bottom inset, and stays clear of the
    ///    floating button: on a row the button does not cover when the card
    ///    has one, otherwise ending short of the button. Whether the card is
    ///    pressed is the engine's, and is not checked.
    func testASidewaysDragKeepsTheSheetAndScrollsNothing() throws {
        let (app, screen) = try openSheet()
        let resting = screen.frame
        let title = app.staticTexts[Self.title]
        let before = try settled(title)
        let yearly = button(app, beginningWith: "Yearly")
        XCTAssertTrue(yearly.waitForExistence(timeout: 10), app.debugDescription)
        let bottomInset = try insets(app).bottom
        let shown = CGRect(x: resting.minX, y: resting.minY, width: resting.width,
                           height: resting.maxY - bottomInset - resting.minY)
        let monthly = button(app, beginningWith: "Monthly")
        let onMonthly = monthly.exists && shown.contains(monthly.frame)
        let name = onMonthly ? "Monthly" : "Yearly"
        let card = (onMonthly ? monthly : yearly).frame
        let visible = card.intersection(shown)
        XCTAssertGreaterThan(visible.isNull ? 0 : visible.height, 16,
                             "\(name)'s card \(card) is not on screen in the sheet \(shown)")
        let restore = app.buttons["Restore"]
        let floating = restore.exists ? restore.frame : .null

        // The rows of the visible card the floating button does not cover,
        // each kept 8 points from the button and from the card's visible edge.
        let margin: CGFloat = 8
        var bands: [(top: CGFloat, bottom: CGFloat)] = []
        if floating.isNull || floating.maxX <= visible.minX || floating.minX >= visible.maxX
            || floating.maxY <= visible.minY || floating.minY >= visible.maxY {
            bands = [(visible.minY, visible.maxY)]
        } else {
            if floating.minY > visible.minY { bands.append((visible.minY, floating.minY)) }
            if floating.maxY < visible.maxY { bands.append((floating.maxY, visible.maxY)) }
        }
        let clear = bands.filter { $0.bottom - $0.top >= 2 * margin }.max { $0.bottom - $0.top < $1.bottom - $1.top }
        var end = visible.maxX - 30
        let row: CGFloat
        if let clear {
            row = (clear.top + clear.bottom) / 2
        } else {
            row = visible.midY
            end = min(end, floating.minX - 20)
        }
        let from = CGPoint(x: visible.minX + 30, y: row)
        XCTAssertGreaterThan(end - from.x, 100, "\(name)'s card \(card), visible as \(visible), leaves no room for a "
                             + "sideways drag at y \(row) clear of the floating button \(floating)")
        drag(app, from: from, to: CGPoint(x: end, y: from.y))
        let after = try settled(title)
        keep("4-sideways", app)
        XCTAssertEqual(screen.frame, resting, "the sheet moved")
        XCTAssertEqual(after.minY, before.minY, accuracy: 1, "the page scrolled")
        waitFor(screen, valueContaining: "Record: open")
    }

    /// 5. A drag down that starts on the header, above the `scroll`, pulls
    ///    the sheet as on any sheet.
    func testADragDownOnTheHeaderTakesTheSheet() throws {
        let (app, screen) = try openSheet()
        let sheet = screen.frame
        let heading = app.staticTexts["Quietly"]
        XCTAssertTrue(heading.waitForExistence(timeout: 10), app.debugDescription)
        let screenInsets = try insets(app)
        let from = CGPoint(x: sheet.midX, y: max(heading.frame.midY, screenInsets.top + 24))
        XCTAssertLessThan(from.y, sheet.minY + 120, "the drag starts below the header")
        let to = CGPoint(x: from.x, y: min(app.frame.maxY - screenInsets.bottom - 8, from.y + sheet.height * 0.8))
        drag(app, from: from, to: to)
        waitUntilGone(screen, "the drag from \(from) to \(to) on the header did not take the sheet \(sheet)")
        waitFor(app.staticTexts["nuxie-machine-record"], labelContaining: "Record: ended")
        keep("5-pulled-by-the-header", app)
    }

    /// 6. A drag up that starts on the button floating over the page: the
    ///    sheet stays. The button lies inside the page's box, so the drag
    ///    goes down over the `scroll`. What the page does with a drag that
    ///    starts on a layer over it is the engine's, and is not checked.
    func testADragUpOnTheFloatingButtonKeepsTheSheet() throws {
        let (app, screen) = try openSheet()
        let resting = screen.frame
        let floating = app.buttons["Restore"]
        XCTAssertTrue(floating.waitForExistence(timeout: 10), app.debugDescription)
        let from = CGPoint(x: floating.frame.midX, y: floating.frame.midY)
        drag(app, from: from, to: CGPoint(x: from.x, y: from.y - 250))
        _ = try settled(screen)
        keep("6-dragged-from-the-floating-button", app)
        XCTAssertEqual(screen.frame, resting, "the sheet moved")
        waitFor(screen, valueContaining: "Record: open")
    }

    /// 7. Scrolled a few points, then dragged down slowly over the page: the
    ///    sheet stays. The page was scrolled when the finger went down, so
    ///    the drag is the page's even when the page reaches its top before
    ///    the sheet asks. (Whether the page could reach its top within the
    ///    first 10 points is the engine's timing; the unit test
    ///    `testTheSurfaceAnswersFromTheRegionsShownWhenTheTouchWentDown`
    ///    pins the answer itself.)
    func testADragDownOnAPageScrolledAFewPointsKeepsTheSheet() throws {
        let (app, screen) = try openSheet()
        let resting = screen.frame
        let title = app.staticTexts[Self.title]
        let top = try settled(title)
        let from = pagePoint(on: resting, at: 0.6)
        drag(app, from: from, to: CGPoint(x: from.x, y: from.y - 40))
        let scrolled = try settled(title)
        XCTAssertLessThan(scrolled.minY, top.minY - 5, "the page did not scroll a little: the title was at \(top), "
                          + "and is at \(scrolled)")
        XCTAssertGreaterThan(scrolled.minY, top.minY - 80, "the page scrolled more than a little: the title was at "
                             + "\(top), and is at \(scrolled)")

        let down = pagePoint(on: resting, at: 0.4)
        drag(app, from: down, to: CGPoint(x: down.x, y: down.y + 200))
        let back = try settled(title)
        keep("7-a-few-points-then-dragged-down", app)
        XCTAssertTrue(screen.exists, "the drag took the sheet")
        XCTAssertEqual(screen.frame, resting, "the sheet moved")
        XCTAssertEqual(back.minY, top.minY, accuracy: 1, "the page did not come back to its top")
        waitFor(screen, valueContaining: "Record: open")
    }

    // MARK: Driving the host

    /// Launch the host, tap "Finish onboarding" and wait for the sheet: its
    /// Screen drawn, its frame settled at the large detent, and its page's
    /// title read.
    private func openSheet() throws -> (XCUIApplication, XCUIElement) {
        let app = XCUIApplication()
        app.launchArguments = ["--nuxie-machine-paywall", "--nuxie-machine-scroll-sheet"]
        app.launch()
        let finish = app.buttons["nuxie-machine-finish-onboarding"]
        XCTAssertTrue(finish.waitForExistence(timeout: 20), app.debugDescription)
        finish.tap()
        let screen = app.descendants(matching: .any)["nuxie-machine-screen"]
        XCTAssertTrue(screen.waitForExistence(timeout: 30), app.debugDescription)
        waitFor(screen, valueContaining: "Record: open")
        XCTAssertTrue(app.staticTexts[Self.title].waitForExistence(timeout: 15), app.debugDescription)
        let sheet = try settled(screen)
        XCTAssertLessThan(sheet.minY, app.frame.height / 4, "the sheet is at its large detent")
        keep("0-open", app)
        return (app, screen)
    }

    /// A point over the page, on the left of the sheet clear of the floating
    /// button, `along` of the way down the sheet.
    private func pagePoint(on sheet: CGRect, at along: CGFloat) -> CGPoint {
        CGPoint(x: sheet.minX + 60, y: sheet.minY + sheet.height * along)
    }

    /// One finger pressed at `from`, dragged slowly to `to`, and held there
    /// a moment before it lifts, so the drag carries no flick.
    private func drag(_ app: XCUIApplication, from: CGPoint, to: CGPoint) {
        let origin = app.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: from.x, dy: from.y))
            .press(forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(dx: to.x, dy: to.y)),
                   withVelocity: .slow, thenHoldForDuration: 0.3)
    }

    /// `element`'s frame once it is the same twice running, a moment apart:
    /// the page has stopped moving.
    private func settled(_ element: XCUIElement) throws -> CGRect {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "\(element) is not there")
        var last = element.frame
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.4)
            let now = element.frame
            if now == last { return now }
            last = now
        }
        XCTFail("\(element) did not stop moving; last at \(last)")
        return last
    }

    /// UIKit's safe-area insets for the screen, as the host shows them.
    private func insets(_ app: XCUIApplication) throws -> UIEdgeInsets {
        let shown = app.descendants(matching: .any)["nuxie-machine-safe-area"]
        XCTAssertTrue(shown.waitForExistence(timeout: 10), "the host does not show the safe area")
        let words = shown.label.split(separator: " ").compactMap { Double($0) }
        XCTAssertEqual(words.count, 4, "the safe area reads \(shown.label)")
        guard words.count == 4 else { return .zero }
        return UIEdgeInsets(top: words[0], left: words[3], bottom: words[2], right: words[1])
    }

    private func button(_ app: XCUIApplication, beginningWith words: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", words)).firstMatch
    }

    private func waitFor(_ element: XCUIElement, valueContaining text: String) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", text), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 20), .completed,
                       "expected \(text) in \(String(describing: element.value))")
    }

    private func waitFor(_ element: XCUIElement, labelContaining text: String) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", text), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 20), .completed,
                       "expected \(text) in \(element.label)")
    }

    private func waitUntilGone(_ element: XCUIElement, _ message: @autoclosure () -> String) {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 20), .completed, message())
    }

    /// A screenshot of the app, kept as `name`.
    private func keep(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "scroll-sheet-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
