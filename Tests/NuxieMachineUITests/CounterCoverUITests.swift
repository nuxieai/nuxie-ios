import XCTest

/// A counter drawn from its Nux alone, as a full screen cover in the runtime
/// host app, with no person. The host launches with
/// `--nuxie-machine-counter`; "Open the counter" starts a record with
/// `opened`, and the machine's `present` row opens the counter. The Screen is
/// the plan's compiled view, and the machine writes it from inside the
/// engine's step.
///
/// The counter is found the way a screen reader finds it: each line is a
/// static text and each button a button, made from the engine's semantic
/// snapshot, with the words the Screen draws and where it draws them. Every
/// tap is a real tap where a button says it is, and every count is read
/// from the count line's element. Screenshots are kept as attachments. The
/// Screen's accessibility value carries the record and the number of frames
/// its view has drawn, which is how the test sees that the Screen goes
/// quiet.
final class CounterCoverUITests: XCTestCase {
    private static let note = "You have counted at least once."
    private static let below = "This line sits below the note."

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testTheCounterIsReadCountsShowsItsNoteHidesItAndGoesQuiet() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--nuxie-machine-counter"]
        app.launch()
        let open = app.buttons["nuxie-machine-open-counter"]
        XCTAssertTrue(open.waitForExistence(timeout: 20), app.debugDescription)
        open.tap()
        let screen = app.descendants(matching: .any)["nuxie-machine-screen"]
        XCTAssertTrue(screen.waitForExistence(timeout: 30), app.debugDescription)
        waitFor(screen, valueContaining: "Record: open")

        // The first frame: the count at 0, no note, and the buttons, read
        // top to bottom.
        XCTAssertTrue(app.staticTexts["Tapped 0 times"].waitForExistence(timeout: 15), app.debugDescription)
        let below = app.staticTexts[Self.below]
        let count = app.buttons["Count"]
        let hide = app.buttons["Hide the note"]
        for element in [below, count, hide, app.buttons["Close"]] {
            XCTAssertTrue(element.exists, "\(element) is not read: \(app.debugDescription)")
            XCTAssertTrue(element.isEnabled, "\(element) is not enabled")
        }
        XCTAssertFalse(app.staticTexts[Self.note].exists, "the line under if is read")
        XCTAssertFalse(app.staticTexts["Count"].exists, "a button's words are read twice")
        let resting = below.frame
        XCTAssertLessThan(app.staticTexts["Tapped 0 times"].frame.minY, resting.minY)
        XCTAssertLessThan(resting.minY, count.frame.minY)
        keep("1-open", app)
        try expectQuiet(screen, name: "the opened counter")

        // A tap on "Count": the count line changes, the note is read below
        // it, and the line below moves down.
        count.tap()
        XCTAssertTrue(app.staticTexts["Tapped 1 times"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts[Self.note].exists, app.debugDescription)
        XCTAssertGreaterThan(below.frame.minY - resting.minY, 12, "the line below did not move: \(resting) to \(below.frame)")
        keep("2-after-first-tap", app)

        count.tap()
        XCTAssertTrue(app.staticTexts["Tapped 2 times"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts[Self.note].exists, app.debugDescription)
        keep("3-after-second-tap", app)
        try expectQuiet(screen, name: "the counter with its note")

        // "Hide the note": the note goes, and the line below comes back.
        hide.tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                             object: app.staticTexts[Self.note])
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 10), .completed, "the note is still read")
        XCTAssertTrue(app.staticTexts["Tapped 2 times"].exists, app.debugDescription)
        XCTAssertEqual(below.frame.minY, resting.minY, accuracy: 2, "the line below did not come back")
        keep("4-note-hidden", app)
        try expectQuiet(screen, name: "the counter with its note hidden")
        waitFor(screen, valueContaining: "Record: open")
    }

    // MARK: Driving the host

    private func waitFor(_ element: XCUIElement, valueContaining text: String) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", text), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 20), .completed,
                       "expected \(text) in \(String(describing: element.value))")
    }

    /// The Screen draws nothing while nothing happens: the number of frames
    /// its view has drawn stays the same over two seconds.
    private func expectQuiet(_ screen: XCUIElement, name: String) throws {
        let before = try framesDrawn(screen)
        Thread.sleep(forTimeInterval: 2)
        let after = try framesDrawn(screen)
        XCTAssertEqual(after, before, "\(name) kept drawing")
    }

    private func framesDrawn(_ screen: XCUIElement) throws -> Int {
        let value = String(describing: screen.value ?? "")
        let marker = "Frames drawn: "
        let start = try XCTUnwrap(value.range(of: marker), "no frame count in \(value)").upperBound
        let digits = value[start...].prefix { $0.isNumber }
        return try XCTUnwrap(Int(digits), "no frame count in \(value)")
    }

    /// A screenshot of the app, kept as `name`.
    private func keep(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
