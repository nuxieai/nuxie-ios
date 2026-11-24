import XCTest

/// Stillwater's paywall as a native sheet in the runtime host app, driven by
/// the Nux machine, with no person. The host launches with
/// `--nuxie-machine-paywall`; "Finish onboarding" starts a record with
/// `onboarding_completed`, and the machine's `present` row opens the
/// paywall as a sheet, drawn from `paywall.nux` and its `plan-card.nux`
/// alone. The host's store answers a purchase with status `failed` after a
/// second and a half, so the paywall is seen while it buys.
///
/// The paywall is found the way a screen reader finds it: each line is a
/// static text and each button a button named by the words beneath it,
/// made from the engine's semantic snapshot, with the words the Screen
/// draws and where it draws them. The plans are a radio group read by its
/// label, "Plan", before its two cards; each card is a radio, read as a
/// button that is selected while its plan is the chosen one. Every tap is a real tap where a button
/// says it is. At each of the story's five frames a screenshot is kept,
/// and what a screen reader reads on the sheet, top to bottom, is kept
/// beside it and printed to the log.
///
/// What the record holds is read from the Screen's accessibility value while
/// the sheet is up (the host's two lines are behind it), and from the host's
/// two lines once the sheet is gone.
final class StillwaterPaywallSheetUITests: XCTestCase {
    private static let errorLine = "The purchase did not go through. Try again in a moment."
    private static let termsLine = "Billed through the store after the trial. Cancel any time."

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testThePaywallStoryInFiveFrames() throws {
        let app = launch()
        let screen = try openPaywall(app)

        // 1. Open: the headline, both plans with their prices, and the
        // buttons, read top to bottom; nothing under an `if` is read.
        let title = text(app, beginningWith: "Ten quiet minutes,")
        XCTAssertTrue(title.waitForExistence(timeout: 15), app.debugDescription)
        let yearly = button(app, beginningWith: "Yearly")
        let monthly = button(app, beginningWith: "Monthly")
        let buy = app.buttons["Continue"]
        let notNow = app.buttons["Not now"]
        let restore = app.buttons["Restore purchases"]
        let details = app.buttons["About the trial"]
        for element in [yearly, monthly, buy, notNow, restore, details] {
            XCTAssertTrue(element.exists, "\(element) is not read: \(app.debugDescription)")
            XCTAssertTrue(element.isEnabled, "\(element) is not enabled")
        }
        XCTAssertTrue(yearly.label.contains("$59.99"), yearly.label)
        XCTAssertTrue(monthly.label.contains("$9.99"), monthly.label)
        XCTAssertTrue(yearly.isSelected, "the chosen plan, yearly, is not read as selected")
        XCTAssertFalse(monthly.isSelected, "monthly is read as selected while yearly is chosen")
        let opened = reading(app, on: screen.frame)
        let group = try XCTUnwrap(opened.firstIndex(of: "group \"Plan\""), "the plans' group is not read: \(opened)")
        let first = try XCTUnwrap(opened.firstIndex { $0.hasPrefix("button \"Yearly") }, "\(opened)")
        XCTAssertLessThan(group, first, "the group's label is read before its cards: \(opened)")
        XCTAssertFalse(app.staticTexts[Self.errorLine].exists, "the error line is read")
        XCTAssertFalse(app.staticTexts[Self.termsLine].exists, "the terms line is read")
        XCTAssertFalse(app.staticTexts["Continue"].exists, "a button's words are read twice")
        XCTAssertLessThan(title.frame.minY, yearly.frame.minY)
        XCTAssertLessThan(yearly.frame.minY, monthly.frame.minY)
        XCTAssertLessThan(monthly.frame.minY, buy.frame.minY)
        XCTAssertLessThan(buy.frame.minY, notNow.frame.minY)
        keep("1-open", app, screen)

        // 2. Monthly chosen: the record's plan is monthly, and the selected
        // card moves from yearly to monthly.
        monthly.tap()
        waitFor(screen, valueContaining: "Selected plan: monthly.")
        waitFor(monthly, "selected == true", "monthly is not read as selected after its tap")
        XCTAssertFalse(yearly.isSelected, "yearly is still read as selected after monthly was tapped")
        keep("2-monthly-chosen", app, screen)

        // 3. Buying: one purchase is under way, and the buy button is read
        // as not enabled until the store answers.
        buy.tap()
        waitFor(buy, "enabled == false", "the buy button stayed enabled while it bought")
        keep("3-buying", app, screen)

        // 4. Failed: the purchase's status is `failed`; the error line is read
        // under the button, which is enabled again.
        XCTAssertTrue(app.staticTexts[Self.errorLine].waitForExistence(timeout: 10), app.debugDescription)
        waitFor(buy, "enabled == true", "the buy button stayed disabled after the answer")
        XCTAssertLessThan(buy.frame.minY, app.staticTexts[Self.errorLine].frame.minY)
        XCTAssertTrue(monthly.isSelected, "monthly is no longer read as selected after the purchase failed")
        XCTAssertFalse(yearly.isSelected)
        keep("4-failed", app, screen)

        // 5. Details open: "About the trial" shows the terms line.
        details.tap()
        XCTAssertTrue(app.staticTexts[Self.termsLine].waitForExistence(timeout: 10), app.debugDescription)
        keep("5-details-open", app, screen)

        // "Not now": Stillwater's `close` marks the evening offer due and
        // dismisses. The sheet goes, nothing is presented, and the record
        // stays open with its wake moment.
        notNow.tap()
        waitUntilGone(screen)
        waitFor(app.staticTexts["nuxie-machine-record"], labelContaining: "Record: open, wakes at ")
        XCTAssertEqual(app.staticTexts["nuxie-machine-plan"].label, "Selected plan: monthly")
        keep("6-after-not-now", app, nil)
    }

    func testASwipeDownEndsTheRecord() throws {
        let app = launch()
        let screen = try openPaywall(app)
        XCTAssertTrue(app.buttons["Continue"].waitForExistence(timeout: 15), app.debugDescription)

        // A swipe down has no action behind it: the machine hears `closed`,
        // and the record ends.
        let start = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: screen.frame.midX, dy: screen.frame.minY + 12))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98))
        start.press(forDuration: 0.1, thenDragTo: end)
        waitUntilGone(screen)
        waitFor(app.staticTexts["nuxie-machine-record"], labelContaining: "Record: ended")
        keep("1-after-swipe", app, nil)
    }

    func testASwipeThePersonLetsGoOfKeepsTheSheet() throws {
        let app = launch()
        let screen = try openPaywall(app)
        XCTAssertTrue(app.buttons["Continue"].waitForExistence(timeout: 15), app.debugDescription)
        let resting = screen.frame

        // A short, slow pull that the person lets go of: UIKit cancels the
        // dismissal and the sheet settles back. The machine hears nothing.
        let start = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: resting.midX, dy: resting.minY + 12))
        let short = start.withOffset(CGVector(dx: 0, dy: 90))
        start.press(forDuration: 0.1, thenDragTo: short, withVelocity: .slow, thenHoldForDuration: 0.4)
        let deadline = Date().addingTimeInterval(10)
        while screen.exists, screen.frame != resting, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTAssertTrue(screen.exists, "the swipe took the sheet")
        XCTAssertEqual(screen.frame, resting, "the sheet did not settle back")
        waitFor(screen, valueContaining: "Record: open.")
        XCTAssertTrue(app.buttons["Continue"].exists, app.debugDescription)
        keep("1-after-cancelled-swipe", app, screen)

        // The machine's own dismissal still takes the sheet.
        app.buttons["Not now"].tap()
        waitUntilGone(screen)
        waitFor(app.staticTexts["nuxie-machine-record"], labelContaining: "Record: open, wakes at ")
    }

    // MARK: Driving the host

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--nuxie-machine-paywall"]
        app.launch()
        return app
    }

    /// Tap "Finish onboarding" and wait for the sheet: its Screen drawn and
    /// its frame settled.
    private func openPaywall(_ app: XCUIApplication) throws -> XCUIElement {
        let finish = app.buttons["nuxie-machine-finish-onboarding"]
        XCTAssertTrue(finish.waitForExistence(timeout: 20), app.debugDescription)
        finish.tap()
        let screen = app.descendants(matching: .any)["nuxie-machine-screen"]
        XCTAssertTrue(screen.waitForExistence(timeout: 30), app.debugDescription)
        waitFor(screen, valueContaining: "Record: open")
        var last = screen.frame
        let deadline = Date().addingTimeInterval(10)
        repeat {
            Thread.sleep(forTimeInterval: 0.4)
            let now = screen.frame
            if now == last { break }
            last = now
        } while Date() < deadline
        XCTAssertLessThan(last.minY, app.frame.height / 4, "the sheet is at its large detent")
        return screen
    }

    private func button(_ app: XCUIApplication, beginningWith words: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", words)).firstMatch
    }

    private func text(_ app: XCUIApplication, beginningWith words: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", words)).firstMatch
    }

    private func waitFor(_ element: XCUIElement, _ format: String, _ message: String) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed, message)
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

    private func waitUntilGone(_ element: XCUIElement) {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 20), .completed, "the sheet is still up")
    }

    // MARK: Keeping each frame

    /// A screenshot of the app, kept as `name`, and, while the sheet is up,
    /// what a screen reader reads on it, kept as `name-reading` and printed
    /// to the log one element a line.
    private func keep(_ name: String, _ app: XCUIApplication, _ screen: XCUIElement?) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let screen else { return }
        let reading = self.reading(app, on: screen.frame)
        let text = reading.joined(separator: "\n")
        let kept = XCTAttachment(string: text)
        kept.name = name + "-reading"
        kept.lifetime = .keepAlways
        add(kept)
        for line in reading { print("READING \(name): \(line)") }
    }

    /// The elements on the sheet a screen reader reads, in its order: each
    /// line of text, each button, and each group read by its label (an
    /// element with no trait of its own and no children), with its words
    /// and whether it is selected and enabled. The Screen's own element,
    /// which carries the record for these checks, is left out.
    private func reading(_ app: XCUIApplication, on sheet: CGRect) -> [String] {
        guard let root = try? app.snapshot() else { return ["(no snapshot of the app)"] }
        var lines: [String] = []
        func walk(_ element: XCUIElementSnapshot) {
            let kind: String? = switch element.elementType {
            case .button: "button"
            case .staticText: "text"
            case .image: "image"
            case .link: "link"
            case .other where element.children.isEmpty && !element.label.isEmpty: "group"
            default: nil
            }
            if let kind, sheet.contains(CGPoint(x: element.frame.midX, y: element.frame.midY)),
               !element.identifier.hasPrefix("nuxie-machine-") {
                lines.append("\(kind) \"\(element.label)\"\(element.isSelected ? ", selected" : "")"
                    + (element.isEnabled ? "" : ", not enabled"))
            }
            for child in element.children { walk(child) }
        }
        walk(root)
        return lines
    }
}
