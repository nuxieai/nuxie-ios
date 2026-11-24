import UIKit
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
///
/// The story is played in light and in dark: the host starts in dark with
/// `--nuxie-machine-appearance dark`, standing in for a phone set to dark,
/// and the paywall follows the phone. What a screen reader reads is the
/// same in both, word for word; only the colors differ, read from the
/// sheet's ground in each screenshot.
///
/// A sheet is told no insets: the paywall is laid out inside the sheet's
/// safe area, and the band below it shows the platform's sheet background.
/// Each story keeps one still of that, `place-sheet-light` or
/// `place-sheet-dark`.
final class StillwaterPaywallSheetUITests: XCTestCase {
    private static let errorLine = "The purchase did not go through. Try again in a moment."
    private static let termsLine = "Billed through the store after the trial. Cancel any time."

    /// What a screen reader reads on the sheet at each of the story's five
    /// frames, in light and in dark alike.
    private static let readings: [String: [String]] = {
        let open = [
            "text \"Ten quiet minutes,\nevery day.\"",
            "group \"Plan\"",
            "button \"Yearly $59.99\", selected",
            "button \"Monthly $9.99\"",
            "button \"Continue\"",
            "button \"Not now\"",
            "button \"Restore purchases\"",
            "button \"About the trial\"",
        ]
        var monthly = open
        monthly[2] = "button \"Yearly $59.99\""
        monthly[3] = "button \"Monthly $9.99\", selected"
        var buying = monthly
        buying[4] = "button \"Continue\", not enabled"
        var failed = monthly
        failed.insert("text \"\(StillwaterPaywallSheetUITests.errorLine)\"", at: 5)
        return [
            "1-open": open,
            "2-monthly-chosen": monthly,
            "3-buying": buying,
            "4-failed": failed,
            "5-details-open": failed + ["text \"\(StillwaterPaywallSheetUITests.termsLine)\""],
        ]
    }()

    /// The sheet's ground, Stillwater's `night`: #f6f8f7 in light and
    /// #0d1214 in dark.
    private enum Ground: String {
        case light, dark
    }

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testThePaywallStoryInFiveFrames() throws {
        try playTheStory(in: .light)
    }

    func testThePaywallStoryInFiveFramesInDark() throws {
        try playTheStory(in: .dark)
    }

    /// The paywall follows the phone while it is open: the phone turns dark
    /// and the open sheet is drawn again in dark, then light again, with
    /// the same reading throughout.
    ///
    /// The phone is turned the way the story's dark start stands in for it,
    /// on the host's window, by a Darwin notification the host listens for.
    /// `XCUIDevice.shared.appearance` was tried first: on the iOS 27.0
    /// simulator it did not reach the running app at all (twelve seconds
    /// after it, UIKit's own status bar and the host behind the sheet were
    /// still light).
    func testTheOpenPaywallFollowsThePhone() throws {
        let app = launch(.light)
        let screen = try openPaywall(app)
        XCTAssertTrue(app.buttons["Continue"].waitForExistence(timeout: 15), app.debugDescription)
        waitFor(app, screen, ground: .light, "the paywall opened on a light phone is not light")
        keep("switch-1-light", app, screen, expecting: "1-open")

        turnThePhone(.dark)
        waitFor(app, screen, ground: .dark, "the open paywall did not turn dark with the phone")
        keep("switch-2-dark", app, screen, expecting: "1-open")

        turnThePhone(.light)
        waitFor(app, screen, ground: .light, "the open paywall did not turn light again with the phone")
        keep("switch-3-light-again", app, screen, expecting: "1-open")
    }

    /// Post the Darwin notification the host turns its window with.
    private func turnThePhone(_ appearance: Ground) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("dev.nuxie.machine.appearance.\(appearance.rawValue)" as CFString), nil, nil, true)
    }

    private func playTheStory(in appearance: Ground) throws {
        let app = launch(appearance)
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
        waitFor(app, screen, ground: appearance, "the paywall does not open in \(appearance)")
        keep("1-open", app, screen, expecting: "1-open")

        // The sheet's place: the paywall stays inside the sheet's safe area,
        // and the band below it, the home indicator's, is the platform's
        // sheet background in the same scheme. Kept whole as
        // `place-sheet-<scheme>`.
        let band = CGPoint(x: screen.frame.midX, y: screen.frame.maxY - 8)
        XCTAssertLessThan(notNow.frame.maxY, band.y, "the paywall's footer reaches into the home indicator's band")
        XCTAssertEqual(ground(in: app.screenshot(), at: band), appearance,
                       "the band below the paywall is not the \(appearance) sheet background")
        keep("place-sheet-\(appearance.rawValue)", app, screen, expecting: "1-open")

        // 2. Monthly chosen: the record's plan is monthly, and the selected
        // card moves from yearly to monthly.
        monthly.tap()
        waitFor(screen, valueContaining: "Selected plan: monthly.")
        waitFor(monthly, "selected == true", "monthly is not read as selected after its tap")
        XCTAssertFalse(yearly.isSelected, "yearly is still read as selected after monthly was tapped")
        XCTAssertEqual(ground(app, screen), appearance, "the paywall left \(appearance) when monthly was chosen")
        keep("2-monthly-chosen", app, screen, expecting: "2-monthly-chosen")

        // 3. Buying: one purchase is under way, and the buy button is read
        // as not enabled until the store answers.
        buy.tap()
        waitFor(buy, "enabled == false", "the buy button stayed enabled while it bought")
        keep("3-buying", app, screen, expecting: "3-buying")

        // 4. Failed: the purchase's status is `failed`; the error line is read
        // under the button, which is enabled again.
        XCTAssertTrue(app.staticTexts[Self.errorLine].waitForExistence(timeout: 10), app.debugDescription)
        waitFor(buy, "enabled == true", "the buy button stayed disabled after the answer")
        XCTAssertLessThan(buy.frame.minY, app.staticTexts[Self.errorLine].frame.minY)
        XCTAssertTrue(monthly.isSelected, "monthly is no longer read as selected after the purchase failed")
        XCTAssertFalse(yearly.isSelected)
        keep("4-failed", app, screen, expecting: "4-failed")

        // 5. Details open: "About the trial" shows the terms line.
        details.tap()
        XCTAssertTrue(app.staticTexts[Self.termsLine].waitForExistence(timeout: 10), app.debugDescription)
        keep("5-details-open", app, screen, expecting: "5-details-open")

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

    /// The host, on the phone as it is, or started in `appearance`.
    private func launch(_ appearance: Ground? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--nuxie-machine-paywall"]
        if let appearance {
            app.launchArguments += ["--nuxie-machine-appearance", appearance.rawValue]
        }
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

    /// Wait until the sheet's ground is `expected`: the Screen draws the
    /// frame the new colors land in after the trait change reaches it.
    private func waitFor(_ app: XCUIApplication, _ screen: XCUIElement, ground expected: Ground,
                         _ message: String) {
        let deadline = Date().addingTimeInterval(10)
        var seen = ground(app, screen)
        while seen != expected, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
            seen = ground(app, screen)
        }
        guard seen != expected else { return }
        // What UIKit drew above the sheet says whether the app heard the
        // phone at all: the host behind the sheet follows it on its own.
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "not-\(expected.rawValue)"
        attachment.lifetime = .keepAlways
        add(attachment)
        let above = ground(in: shot, at: CGPoint(x: screen.frame.midX, y: max(2, screen.frame.minY / 2)),
                           lightAtLeast: 150)
        XCTAssertEqual(seen, expected,
                       "\(message); above the sheet UIKit drew \(above.map(\.rawValue) ?? "neither")")
    }

    /// Light or dark, as the sheet's ground reads in a screenshot: a point
    /// in the paywall's top padding, inside the sheet's rounded corner.
    /// Neither when it is neither (the sheet is not drawn there yet).
    private func ground(_ app: XCUIApplication, _ screen: XCUIElement) -> Ground? {
        ground(in: app.screenshot(), at: CGPoint(x: screen.frame.minX + 12, y: screen.frame.minY + 30))
    }

    /// Light or dark at `point` of `shot`: light when every channel is at
    /// least `lightAtLeast`, dark when every channel is at most 48.
    private func ground(in shot: XCUIScreenshot, at point: CGPoint, lightAtLeast: Int = 200) -> Ground? {
        let image = shot.image
        guard let picture = image.cgImage else { return nil }
        let x = Int(point.x * image.scale)
        let y = Int(point.y * image.scale)
        guard x >= 0, y >= 0, x < picture.width, y < picture.height else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn = pixel.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            // The one pixel at (x, y) from the top lands on the context's
            // only pixel.
            context.draw(picture, in: CGRect(x: -x, y: y - picture.height + 1,
                                             width: picture.width, height: picture.height))
            return true
        }
        guard drawn else { return nil }
        let channels = pixel[0..<3].map(Int.init)
        if channels.allSatisfy({ $0 >= lightAtLeast }) { return .light }
        if channels.allSatisfy({ $0 <= 48 }) { return .dark }
        return nil
    }

    private func waitUntilGone(_ element: XCUIElement) {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 20), .completed, "the sheet is still up")
    }

    // MARK: Keeping each frame

    /// A screenshot of the app, kept as `name`, and, while the sheet is up,
    /// what a screen reader reads on it, kept as `name-reading` and printed
    /// to the log one element a line. With `expecting`, the reading is the
    /// story's at that frame, word for word.
    private func keep(_ name: String, _ app: XCUIApplication, _ screen: XCUIElement?,
                      expecting frame: String? = nil) {
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
        if let frame {
            XCTAssertEqual(reading, Self.readings[frame], "what a screen reader reads at \(name) changed")
        }
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
