import CoreGraphics
import UIKit
import Vision
import XCTest

/// A counter drawn from its Nux alone, as a full screen cover in the runtime
/// host app, with no person. The host launches with
/// `--nuxie-machine-counter`; "Open the counter" starts a record with
/// `opened`, and the machine's `present` row opens the counter. No artwork is
/// handed over: the Screen is the plan's compiled view, and the machine
/// writes it from inside the engine's step.
///
/// Compiled text has no accessibility elements, so the lines are found with
/// text recognition in screenshots (kept as attachments), and every tap is a
/// real tap at the point where a button's label was read. The Screen's
/// accessibility value carries the record and the number of frames its view
/// has drawn, which is how the test sees that the Screen goes quiet.
final class CounterCoverUITests: XCTestCase {
    private static let note = "You have counted at least once."
    private static let below = "This line sits below the note."

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testTheCounterCountsShowsItsNoteHidesItAndGoesQuiet() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--nuxie-machine-counter"]
        app.launch()
        let open = app.buttons["nuxie-machine-open-counter"]
        XCTAssertTrue(open.waitForExistence(timeout: 20), app.debugDescription)
        open.tap()
        let screen = app.descendants(matching: .any)["nuxie-machine-screen"]
        XCTAssertTrue(screen.waitForExistence(timeout: 30), app.debugDescription)
        waitFor(screen, valueContaining: "Record: open")

        // The first frame: the count at 0, and no note.
        let first = try waitForLine("Tapped 0 times", name: "1-open")
        XCTAssertFalse(first.text.contains("You have counted"), "Recognized: \(first.text)")
        let resting = try first.box(of: Self.below)
        try expectQuiet(screen, name: "the opened counter")

        // A tap on "Count": the count changes, the note shows, and the line
        // below it moves down.
        tap(try first.box(of: "Count"), app: app)
        let once = try waitForLine("Tapped 1 times", name: "2-after-first-tap")
        XCTAssertTrue(once.text.contains(Self.note), "Recognized: \(once.text)")
        let pushed = try once.box(of: Self.below)
        XCTAssertGreaterThan(pushed.minY - resting.minY, 12, "the line below did not move: \(resting) to \(pushed)")

        tap(try once.box(of: "Count"), app: app)
        let twice = try waitForLine("Tapped 2 times", name: "3-after-second-tap")
        XCTAssertTrue(twice.text.contains(Self.note), "Recognized: \(twice.text)")
        try expectQuiet(screen, name: "the counter with its note")

        // "Hide the note": the note goes, and the line below comes back.
        tap(try twice.box(of: "Hide the note"), app: app)
        let hidden = try waitUntil(name: "4-note-hidden") { !$0.text.contains("You have counted") }
        XCTAssertTrue(hidden.text.contains("Tapped 2 times"), "Recognized: \(hidden.text)")
        let back = try hidden.box(of: Self.below)
        XCTAssertEqual(back.minY, resting.minY, accuracy: 2, "the line below did not come back")
        try expectQuiet(screen, name: "the counter with its note hidden")
        waitFor(screen, valueContaining: "Record: open")
    }

    // MARK: Driving the host

    /// A real tap at the center of `box`, in screen points.
    private func tap(_ box: CGRect, app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: box.midX, dy: box.midY))
            .tap()
    }

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

    // MARK: Reading the screen

    /// One screenshot and the lines recognized in it, each with its box in
    /// screen points.
    private struct Capture {
        let lines: [(text: String, box: CGRect)]

        var text: String { lines.map(\.text).joined(separator: " ") }

        func box(of line: String) throws -> CGRect {
            try XCTUnwrap(lines.first { $0.text == line }?.box,
                          "no line \"\(line)\" among \(lines.map(\.text))")
        }
    }

    private func waitForLine(_ line: String, name: String) throws -> Capture {
        try waitUntil(name: name) { capture in capture.lines.contains { $0.text == line } }
    }

    /// Screenshots until `done` holds; the last one is kept as `name`.
    private func waitUntil(name: String, _ done: (Capture) -> Bool) throws -> Capture {
        let deadline = Date().addingTimeInterval(15)
        var captured = try screenshot()
        while !done(captured.capture), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.3)
            captured = try screenshot()
        }
        let attachment = XCTAttachment(screenshot: captured.shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertTrue(done(captured.capture), "\(name): recognized \(captured.capture.text)")
        return captured.capture
    }

    private func screenshot() throws -> (shot: XCUIScreenshot, capture: Capture) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let banner = springboard.descendants(matching: .any).matching(identifier: "NotificationShortLookView").firstMatch
        if banner.exists {
            banner.swipeUp()
            Thread.sleep(forTimeInterval: 1)
        }
        let shot = XCUIScreen.main.screenshot()
        let image = try XCTUnwrap(shot.image.cgImage)
        let width = CGFloat(image.width) / shot.image.scale
        let height = CGFloat(image.height) / shot.image.scale
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        let lines = (request.results ?? []).compactMap { observation -> (String, CGRect)? in
            guard let read = observation.topCandidates(1).first?.string else { return nil }
            // Recognition reads a lone zero in the system font as the letter O.
            let text = read.split(separator: " ", omittingEmptySubsequences: false)
                .map { $0 == "O" ? "0" : String($0) }.joined(separator: " ")
            // Vision's box is normalized with its origin at the bottom left.
            let box = observation.boundingBox
            return (text, CGRect(x: box.minX * width, y: (1 - box.maxY) * height,
                                 width: box.width * width, height: box.height * height))
        }
        return (shot, Capture(lines: lines))
    }
}
