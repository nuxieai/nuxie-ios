import CoreGraphics
import UIKit
import Vision
import XCTest

/// Stillwater's paywall as a native sheet in the runtime host app, driven by
/// the Nux machine, with no person. The host launches with
/// `--nuxie-machine-paywall`; "Finish onboarding" starts a record with
/// `onboarding_completed`, and the machine's `present` row opens the
/// paywall as a sheet.
///
/// The Screen's controls have no accessibility elements yet, so every tap is
/// a real tap at a screen point, taken from the Screen's layout table (the
/// boxes on its 390 by 844 artboard, as the machine suite has them) and
/// placed on the sheet's frame. The Screen is laid out again at the sheet's
/// size: its top group (headline, cards, buy button, error line) keeps its
/// distance from the top, and its bottom group ("Not now", the links, the
/// terms line) its distance from the bottom, and both keep their x on a
/// sheet at least 390 points wide.
///
/// What the record holds is read from the Screen's accessibility value while
/// the sheet is up (the host's two lines are behind it), and from the host's
/// two lines once the sheet is gone. What the Screen shows is read with text
/// recognition from screenshots, which are kept as attachments.
final class StillwaterPaywallSheetUITests: XCTestCase {
    /// Boxes on the 390 by 844 Screen, `[x0, y0, x1, y1]`.
    private enum Box {
        static let monthly: [CGFloat] = [24, 334, 366, 406]
        static let buy: [CGFloat] = [24, 434, 366, 490]
        static let close: [CGFloat] = [24, 666, 366, 714]
        static let details: [CGFloat] = [201, 718, 366, 762]
    }

    private static let artboardWidth: CGFloat = 390
    private static let artboardHeight: CGFloat = 844
    /// Boxes that start below this belong to the bottom group.
    private static let bottomGroupTop: CGFloat = 600

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testThePaywallOpensAsASheetAndNotNowLeavesTheRecordWaiting() throws {
        let app = launch()
        let screen = try openPaywall(app)
        let opened = try capture("1-sheet-open",
            expecting: ["Ten quiet minutes", "Yearly", "Monthly", "$59.99", "$9.99", "Continue"])

        // A tap on the Monthly card: the record's plan is monthly, and the
        // card looks selected.
        tap(Box.monthly, on: screen, app: app)
        waitFor(screen, valueContaining: "Selected plan: monthly.")
        let monthly = try capture("2-monthly-selected", expecting: ["Monthly"])
        let card = region(Box.monthly, on: screen)
        XCTAssertGreaterThanOrEqual(Self.changedPixels(opened, monthly, in: card), 150,
                                    "the Monthly card looks the same")

        // "Continue": the stand-in store fails the purchase, and the error
        // line shows.
        tap(Box.buy, on: screen, app: app)
        try waitForText("did not go through", name: "3-error-line")

        // "About the trial": the terms line shows.
        tap(Box.details, on: screen, app: app)
        try waitForText("Billed through the store", name: "4-terms-line")

        // "Not now": Stillwater's `close` marks the evening offer due and
        // dismisses. The sheet goes, nothing is presented, and the record
        // stays open with its wake moment.
        tap(Box.close, on: screen, app: app)
        waitUntilGone(screen)
        let record = app.staticTexts["nuxie-machine-record"]
        waitFor(record, labelContaining: "Record: open, wakes at ")
        XCTAssertEqual(app.staticTexts["nuxie-machine-plan"].label, "Selected plan: monthly")
        _ = try capture("5-after-not-now", expecting: ["Finish onboarding"])
    }

    func testASwipeDownEndsTheRecord() throws {
        let app = launch()
        let screen = try openPaywall(app)
        _ = try capture("1-sheet-open", expecting: ["Ten quiet minutes", "Continue"])

        // A swipe down has no action behind it: the machine hears `closed`,
        // and the record ends.
        let start = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: screen.frame.midX, dy: screen.frame.minY + 12))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98))
        start.press(forDuration: 0.1, thenDragTo: end)
        waitUntilGone(screen)
        waitFor(app.staticTexts["nuxie-machine-record"], labelContaining: "Record: ended")
        _ = try capture("2-after-swipe", expecting: ["Finish onboarding"])
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
        XCTAssertGreaterThanOrEqual(last.width, Self.artboardWidth, "the boxes keep their x only on a sheet this wide")
        XCTAssertLessThan(last.minY, app.frame.height / 4, "the sheet is at its large detent")
        return screen
    }

    /// A real tap at the center of `box`, placed on the sheet's frame.
    private func tap(_ box: [CGFloat], on screen: XCUIElement, app: XCUIApplication) {
        let center = region(box, on: screen)
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: center.midX, dy: center.midY))
            .tap()
    }

    /// `box` on the screen, in points: the top group keeps its distance from
    /// the sheet's top, the bottom group from the sheet's bottom.
    private func region(_ box: [CGFloat], on screen: XCUIElement) -> CGRect {
        let frame = screen.frame
        let y = box[1] >= Self.bottomGroupTop
            ? frame.maxY - (Self.artboardHeight - box[1])
            : frame.minY + box[1]
        return CGRect(x: frame.minX + box[0], y: y, width: box[2] - box[0], height: box[3] - box[1])
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

    // MARK: Reading the screen

    private struct Capture {
        let screenshot: CGImage
        let scale: CGFloat
        let text: String
    }

    /// A screenshot, kept as an attachment named `name`, and the text
    /// recognized in it, which must hold each of `expecting`.
    private func capture(_ name: String, expecting: [String]) throws -> Capture {
        let captured = try screenshot(name)
        for text in expecting {
            XCTAssertTrue(captured.text.contains(text), "Missing \(text). Recognized: \(captured.text)")
        }
        return captured
    }

    /// Screenshots until the recognized text holds `text`: the store's
    /// answer and the terms line show a frame or two after the tap.
    private func waitForText(_ text: String, name: String) throws {
        let deadline = Date().addingTimeInterval(15)
        var captured = try screenshot(name)
        while !captured.text.contains(text), Date() < deadline {
            captured = try screenshot(name)
        }
        XCTAssertTrue(captured.text.contains(text), "Missing \(text). Recognized: \(captured.text)")
    }

    private func screenshot(_ name: String) throws -> Capture {
        Thread.sleep(forTimeInterval: 1)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let banner = springboard.descendants(matching: .any).matching(identifier: "NotificationShortLookView").firstMatch
        if banner.exists {
            banner.swipeUp()
            Thread.sleep(forTimeInterval: 1)
        }
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let image = try XCTUnwrap(shot.image.cgImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: image).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        return Capture(screenshot: image, scale: shot.image.scale, text: text)
    }

    /// How many pixels of `region` (in points) move by more than 48 in some
    /// channel between two screenshots of the same size.
    private static func changedPixels(_ earlier: Capture, _ later: Capture, in region: CGRect) -> Int {
        let before = earlier.screenshot, after = later.screenshot
        guard before.width == after.width, before.height == after.height,
              let first = rgba(before), let second = rgba(after) else { return 0 }
        let scale = earlier.scale
        let x0 = max(0, Int(region.minX * scale)), x1 = min(before.width, Int(region.maxX * scale))
        let y0 = max(0, Int(region.minY * scale)), y1 = min(before.height, Int(region.maxY * scale))
        var count = 0
        for y in y0..<max(y0, y1) {
            for x in x0..<max(x0, x1) {
                let at = (y * before.width + x) * 4
                for channel in 0..<3 where abs(Int(first[at + channel]) - Int(second[at + channel])) > 48 {
                    count += 1
                    break
                }
            }
        }
        return count
    }

    private static func rgba(_ image: CGImage) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return drawn ? pixels : nil
    }
}
