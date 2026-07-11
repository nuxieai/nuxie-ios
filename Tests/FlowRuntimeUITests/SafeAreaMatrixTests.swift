import UIKit
import XCTest

/// Simulator-matrix proof for the safe-area env system: a published flow
/// authored with `env(safe-area-inset-*)` must adapt to each device's real
/// insets through the SDK's inset push (`FlowViewModelBridge` +
/// `FlowSafeAreaInsetMapper` `.contain` correction).
///
/// The `safe-area-env` fixture (publish-path provenance: compiled from
/// `tools/rive-compiler/fixtures/publish-path/safe-area-env-device-proof.json`
/// by the real rive compiler backend) renders a 402x874 artboard:
/// - full-bleed navy column (`#0f172a`) with `paddingTop:
///   env(safe-area-inset-top)`
/// - blue hero bar (`#2563eb`, 48pt) as the column's first child — its top
///   edge is the resolved top inset
/// - green CTA (`#16a34a`, 48pt) absolutely anchored `bottom:
///   max(env(safe-area-inset-bottom), 16px)`
/// - amber badge (`#f59e0b`) absolutely anchored `top:
///   max(env(safe-area-inset-top), 20px)`
/// Screen 2 repeats the scene in a distinct palette (indigo/purple/red/cyan)
/// so the sheet-presentation proof can tell the sheet's rendering apart from
/// the dimmed presenting screen.
///
/// Ground truth comes from the host app's `nuxie-safe-area-probe` (its own
/// view's `safeAreaInsets` + bounds); expected pixel rows are derived through
/// the same `.contain` letterbox math the SDK uses, then asserted against
/// the actual rendered pixels of a screen capture.
final class SafeAreaMatrixTests: XCTestCase {
    private var app: XCUIApplication!

    private let artboardSize = CGSize(width: 402, height: 874)
    private let transitionEventName = "__nuxie_test_run_transition"

    // Fixture fill colors (sRGB 0-1).
    private let navy = FixtureColor(red: 0x0f, green: 0x17, blue: 0x2a)
    private let heroBlue = FixtureColor(red: 0x25, green: 0x63, blue: 0xeb)
    private let ctaGreen = FixtureColor(red: 0x16, green: 0xa3, blue: 0x4a)
    private let badgeAmber = FixtureColor(red: 0xf5, green: 0x9e, blue: 0x0b)
    private let sheetIndigo = FixtureColor(red: 0x31, green: 0x2e, blue: 0x81)
    private let sheetPurple = FixtureColor(red: 0xa8, green: 0x55, blue: 0xf7)
    private let sheetRed = FixtureColor(red: 0xef, green: 0x44, blue: 0x44)

    /// Rendered-edge tolerance in points (antialiasing + inset rounding).
    private let tolerance: CGFloat = 3.0

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
        app = nil
    }

    // MARK: - Full-screen matrix cell (portrait + landscape + rotation)

    func testEnvBoundFlowAdaptsToDeviceInsetsInPortraitAndLandscape() throws {
        XCUIDevice.shared.orientation = .portrait
        launchSafeAreaFixture()

        let portrait = try readSafeAreaProbe()
        XCTAssertLessThan(
            portrait.viewSize.width,
            portrait.viewSize.height,
            "Expected a portrait window before the portrait cell"
        )
        try assertRenderedGeometryMatchesEnvironment(
            probe: portrait,
            cellName: "portrait"
        )

        // Rotation must re-resolve the environment through
        // viewSafeAreaInsetsDidChange and reflow the published scene.
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape = try waitForProbeChange(from: portrait)
        XCTAssertGreaterThan(
            landscape.viewSize.width,
            landscape.viewSize.height,
            "Expected a landscape window after rotation"
        )
        try assertRenderedGeometryMatchesEnvironment(
            probe: landscape,
            cellName: "landscape"
        )

        // And back: positions must return to the portrait resolution.
        XCUIDevice.shared.orientation = .portrait
        let portraitAgain = try waitForProbeChange(from: landscape)
        try assertRenderedGeometryMatchesEnvironment(
            probe: portraitAgain,
            cellName: "portrait-after-rotation"
        )
    }

    // MARK: - Sheet presentation cell (screen reads its own insets)

    func testSheetPresentedScreenResolvesSheetInsetsNotDeviceInsets() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("The sheet cell targets iPhone pageSheet presentation")
        }
        XCUIDevice.shared.orientation = .portrait
        launchSafeAreaFixture(extraArguments: [
            "--nuxie-flow-description-variant", "modal",
            "--nuxie-manual-event", transitionEventName,
        ])

        let probe = try readSafeAreaProbe()
        XCTAssertGreaterThan(
            probe.insets.top,
            20.0 - tolerance,
            "Sheet cell expects a device with a real top inset"
        )

        let startButton = app.buttons["nuxie-flow-manual-start"]
        XCTAssertTrue(
            startButton.waitForExistence(timeout: 10),
            "Expected the manual transition control"
        )
        startButton.tap()

        let eventLog = app.staticTexts["nuxie-flow-event-log"]
        XCTAssertTrue(
            eventLog.waitForExistence(timeout: 10)
                && eventLog.waitForLabel(containing: "navigated:screen_2", timeout: 10),
            "Expected the modal transition to reach screen_2"
        )
        Thread.sleep(forTimeInterval: 1.5)

        let capture = try captureScreenPixels(named: "sheet")
        let centerX = capture.windowSize.width / 2

        // The sheet's own top inset is 0, so screen_2's purple hero must sit
        // at the very top of the sheet's indigo column: scanning down the
        // center, purple appears before (or with) any indigo.
        guard let firstPurple = capture.firstY(matching: sheetPurple, atX: centerX) else {
            XCTFail("Sheet hero (purple) not found in capture")
            return
        }
        let firstIndigo = capture.firstY(matching: sheetIndigo, atX: centerX)
        if let firstIndigo {
            XCTAssertGreaterThan(
                firstIndigo,
                firstPurple - tolerance,
                "Sheet resolved a non-zero top inset: indigo padding band found above the hero (sheet must read its own view's insets, not the device's \(probe.insets.top))"
            )
        }

        // The CTA must still clear the home indicator: the sheet runs to the
        // screen bottom, so its bottom inset equals the device's.
        guard let lastRed = capture.lastY(matching: sheetRed, atX: centerX),
              let lastIndigo = capture.lastY(matching: sheetIndigo, atX: centerX)
        else {
            XCTFail("Sheet CTA (red) or column (indigo) not found in capture")
            return
        }
        let renderedArtboardHeight = lastIndigo - firstPurple
        XCTAssertGreaterThan(
            renderedArtboardHeight,
            artboardSize.height / 2,
            "Sheet artboard should render at a sane scale"
        )
        let scale = renderedArtboardHeight / artboardSize.height
        let expectedGap = max(probe.insets.bottom, 16 * scale)
        XCTAssertEqual(
            lastIndigo - lastRed,
            expectedGap,
            accuracy: tolerance,
            "Sheet CTA must clear the home indicator via max(env(safe-area-inset-bottom), 16px)"
        )
    }

    // MARK: - Cell assertion core

    private struct SafeAreaProbe: Equatable {
        var insets: UIEdgeInsets
        var viewSize: CGSize
    }

    private func launchSafeAreaFixture(extraArguments: [String] = []) {
        var arguments = [
            "--nuxie-fixture", "safe-area-env",
            "--nuxie-hide-navigation",
        ]
        arguments.append(contentsOf: extraArguments)
        app.launchArguments = arguments
        app.launch()

        let fixtureRow = app.cells["nuxie-fixture-safe-area-env"]
        XCTAssertTrue(
            fixtureRow.waitForExistence(timeout: 10),
            "Expected the safe-area-env fixture row"
        )
        fixtureRow.tap()

        let surface = app.otherElements["nuxie-flow-surface"]
        XCTAssertTrue(
            surface.waitForExistence(timeout: 20),
            "Expected the native Rive flow surface to mount"
        )
        // Let the first bind push insets and the runtime settle a frame.
        Thread.sleep(forTimeInterval: 1.5)
    }

    private func readSafeAreaProbe() throws -> SafeAreaProbe {
        let element = app.staticTexts["nuxie-safe-area-probe"]
        XCTAssertTrue(
            element.waitForExistence(timeout: 10),
            "Expected the host safe-area probe element"
        )
        guard let probe = Self.parseProbe(element.label) else {
            throw SafeAreaMatrixError.malformedProbe(element.label)
        }
        return probe
    }

    private func waitForProbeChange(from previous: SafeAreaProbe) throws -> SafeAreaProbe {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let probe = try? readSafeAreaProbe(), probe != previous {
                // Give the SDK's inset push + Rive relayout a beat.
                Thread.sleep(forTimeInterval: 1.5)
                return try readSafeAreaProbe()
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTFail("Safe-area probe did not change after rotation")
        throw SafeAreaMatrixError.probeUnchanged
    }

    private static func parseProbe(_ label: String) -> SafeAreaProbe? {
        var values: [String: CGFloat] = [:]
        for token in label.split(separator: " ") {
            let parts = token.split(separator: ":")
            guard parts.count == 2, let value = Double(parts[1]) else { return nil }
            values[String(parts[0])] = CGFloat(value)
        }
        guard let top = values["t"], let left = values["l"], let bottom = values["b"],
              let right = values["r"], let width = values["w"], let height = values["h"],
              width > 0, height > 0
        else {
            return nil
        }
        return SafeAreaProbe(
            insets: UIEdgeInsets(top: top, left: left, bottom: bottom, right: right),
            viewSize: CGSize(width: width, height: height)
        )
    }

    /// Expected rendered rows, in window points, from the device environment
    /// through the same `.contain` math as `FlowSafeAreaInsetMapper`.
    private struct ExpectedGeometry {
        var heroTop: CGFloat
        var ctaBottom: CGFloat
        var badgeTop: CGFloat
        var badgeCenterX: CGFloat
        var scale: CGFloat
        var letterboxX: CGFloat
        var letterboxY: CGFloat
    }

    private func expectedGeometry(for probe: SafeAreaProbe) -> ExpectedGeometry {
        let scale = min(
            probe.viewSize.width / artboardSize.width,
            probe.viewSize.height / artboardSize.height
        )
        let letterboxX = (probe.viewSize.width - artboardSize.width * scale) / 2
        let letterboxY = (probe.viewSize.height - artboardSize.height * scale) / 2
        let vmTop = max(0, (probe.insets.top - letterboxY) / scale)
        let vmBottom = max(0, (probe.insets.bottom - letterboxY) / scale)
        return ExpectedGeometry(
            heroTop: letterboxY + scale * vmTop,
            ctaBottom: probe.viewSize.height - letterboxY - scale * max(vmBottom, 16),
            badgeTop: letterboxY + scale * max(vmTop, 20),
            badgeCenterX: letterboxX + scale * (20 + 40),
            scale: scale,
            letterboxX: letterboxX,
            letterboxY: letterboxY
        )
    }

    private func assertRenderedGeometryMatchesEnvironment(
        probe: SafeAreaProbe,
        cellName: String
    ) throws {
        let expected = expectedGeometry(for: probe)
        let capture = try captureScreenPixels(named: cellName)

        XCTAssertEqual(
            capture.windowSize.width,
            probe.viewSize.width,
            accuracy: 1.0,
            "Window and probe disagree on view width in \(cellName)"
        )

        let centerX = capture.windowSize.width / 2

        guard let heroTop = capture.firstY(matching: heroBlue, atX: centerX) else {
            XCTFail("Hero (blue) not found at center column in \(cellName)")
            return
        }
        XCTAssertEqual(
            heroTop,
            expected.heroTop,
            accuracy: tolerance,
            "\(cellName): hero top edge must sit at the device top inset (insets=\(probe.insets), view=\(probe.viewSize))"
        )

        guard let ctaBottom = capture.lastY(matching: ctaGreen, atX: centerX) else {
            XCTFail("CTA (green) not found at center column in \(cellName)")
            return
        }
        XCTAssertEqual(
            ctaBottom,
            expected.ctaBottom,
            accuracy: tolerance,
            "\(cellName): CTA bottom edge must clear max(bottom inset, 16px) (insets=\(probe.insets), view=\(probe.viewSize))"
        )

        guard let badgeTop = capture.firstY(matching: badgeAmber, atX: expected.badgeCenterX) else {
            XCTFail("Badge (amber) not found in \(cellName)")
            return
        }
        XCTAssertEqual(
            badgeTop,
            expected.badgeTop,
            accuracy: tolerance,
            "\(cellName): badge top edge must sit at max(top inset, 20px)"
        )

        // The navy column is edge-to-edge: on the touching axis it reaches the
        // window edge; past the letterbox band there must be fixture pixels.
        if expected.letterboxX > tolerance {
            let insideX = expected.letterboxX + max(2, expected.letterboxX / 8)
            let midY = capture.windowSize.height / 2
            XCTAssertTrue(
                capture.matches(color: navy, atX: insideX, y: midY),
                "\(cellName): expected the artboard's navy fill just inside the letterbox band (letterboxX=\(expected.letterboxX))"
            )
        }
    }

    // MARK: - Pixel capture

    private struct FixtureColor {
        var red: CGFloat
        var green: CGFloat
        var blue: CGFloat

        init(red: Int, green: Int, blue: Int) {
            self.red = CGFloat(red) / 255
            self.green = CGFloat(green) / 255
            self.blue = CGFloat(blue) / 255
        }
    }

    /// How window points map into the captured pixel buffer. Simulator
    /// screenshots stay portrait-up while the interface rotates, so
    /// landscape captures sample through a rotation.
    private enum PixelMapping {
        case identity
        /// Device .landscapeLeft (interface landscape-right): the physical
        /// top edge is on the interface's left.
        case deviceLandscapeLeft
        /// Device .landscapeRight (interface landscape-left).
        case deviceLandscapeRight
    }

    private struct ScreenCapture {
        var pixels: [UInt8]
        var pixelWidth: Int
        var pixelHeight: Int
        var pixelsPerPoint: CGFloat
        var windowSize: CGSize
        var mapping: PixelMapping

        /// Channel tolerance for color matching (wide-gamut rendering and
        /// compositing shift exact values slightly).
        static let channelTolerance: CGFloat = 0.08

        func matches(color: FixtureColor, atX x: CGFloat, y: CGFloat) -> Bool {
            guard let sample = sample(atX: x, y: y) else { return false }
            return abs(sample.0 - color.red) <= Self.channelTolerance
                && abs(sample.1 - color.green) <= Self.channelTolerance
                && abs(sample.2 - color.blue) <= Self.channelTolerance
        }

        func sample(atX x: CGFloat, y: CGFloat) -> (CGFloat, CGFloat, CGFloat)? {
            let xPx = Int((x * pixelsPerPoint).rounded())
            let yPx = Int((y * pixelsPerPoint).rounded())
            let px: Int
            let py: Int
            switch mapping {
            case .identity:
                px = xPx
                py = yPx
            case .deviceLandscapeLeft:
                px = pixelWidth - 1 - yPx
                py = xPx
            case .deviceLandscapeRight:
                px = yPx
                py = pixelHeight - 1 - xPx
            }
            guard px >= 0, px < pixelWidth, py >= 0, py < pixelHeight else { return nil }
            let offset = (py * pixelWidth + px) * 4
            return (
                CGFloat(pixels[offset]) / 255,
                CGFloat(pixels[offset + 1]) / 255,
                CGFloat(pixels[offset + 2]) / 255
            )
        }

        /// Topmost window-point row matching `color` at column `x`, requiring
        /// a short continuous run so antialiased strays don't match.
        func firstY(matching color: FixtureColor, atX x: CGFloat) -> CGFloat? {
            scanY(matching: color, atX: x, from: 0, step: 1)
        }

        /// Bottommost matching window-point row at column `x`.
        func lastY(matching color: FixtureColor, atX x: CGFloat) -> CGFloat? {
            scanY(matching: color, atX: x, from: windowSize.height - 1 / pixelsPerPoint, step: -1)
        }

        private func scanY(
            matching color: FixtureColor,
            atX x: CGFloat,
            from startY: CGFloat,
            step: CGFloat
        ) -> CGFloat? {
            let pointStep = step / pixelsPerPoint
            var y = startY
            while y >= 0 && y < windowSize.height {
                if matches(color: color, atX: x, y: y) {
                    // Require a 4px run toward the scan direction.
                    let runOK = (1...4).allSatisfy { offset in
                        matches(color: color, atX: x, y: y + CGFloat(offset) * pointStep)
                    }
                    if runOK {
                        return y
                    }
                }
                y += pointStep
            }
            return nil
        }
    }

    private func captureScreenPixels(named name: String) throws -> ScreenCapture {
        // Window-element screenshots follow the interface orientation
        // (XCUIScreen captures stay portrait-up in landscape).
        let screenshot = app.windows.firstMatch.screenshot()
        recordScreenshot(screenshot, named: name)

        guard let cgImage = screenshot.image.cgImage else {
            throw SafeAreaMatrixError.missingImage(name)
        }
        let window = app.windows.firstMatch.frame.size
        guard window.width > 0, window.height > 0 else {
            throw SafeAreaMatrixError.missingWindow
        }

        let widthRatio = CGFloat(cgImage.width) / window.width
        let heightRatio = CGFloat(cgImage.height) / window.height
        let transposedRatio = CGFloat(cgImage.width) / window.height
        let mapping: PixelMapping
        let pixelsPerPoint: CGFloat
        if abs(widthRatio - heightRatio) <= 0.05 {
            mapping = .identity
            pixelsPerPoint = widthRatio
        } else {
            // Simulator captures stay portrait-up while the interface
            // rotates; sample through the rotation for the orientation the
            // test drove.
            XCTAssertEqual(
                transposedRatio,
                CGFloat(cgImage.height) / window.width,
                accuracy: 0.05,
                "Screenshot matches neither the window nor its transpose (\(cgImage.width)x\(cgImage.height) px vs \(window) pt)"
            )
            switch XCUIDevice.shared.orientation {
            case .landscapeRight:
                mapping = .deviceLandscapeRight
            default:
                mapping = .deviceLandscapeLeft
            }
            pixelsPerPoint = transposedRatio
        }

        var pixels = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixels,
            width: cgImage.width,
            height: cgImage.height,
            bitsPerComponent: 8,
            bytesPerRow: cgImage.width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw SafeAreaMatrixError.missingImage(name)
        }
        context.draw(
            cgImage,
            in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        )

        return ScreenCapture(
            pixels: pixels,
            pixelWidth: cgImage.width,
            pixelHeight: cgImage.height,
            pixelsPerPoint: pixelsPerPoint,
            windowSize: window,
            mapping: mapping
        )
    }

    private func recordScreenshot(_ screenshot: XCUIScreenshot, named name: String) {
        XCTContext.runActivity(named: "Screenshot: \(name)") { activity in
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }

        guard let outputDirectory = ProcessInfo.processInfo.environment["NUXIE_FLOW_RUNTIME_OUTPUT_DIR"],
              !outputDirectory.isEmpty else {
            return
        }
        let screenshotsURL = URL(fileURLWithPath: outputDirectory)
            .appendingPathComponent("screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: screenshotsURL,
            withIntermediateDirectories: true
        )
        try? screenshot.pngRepresentation.write(
            to: screenshotsURL.appendingPathComponent("\(name).png"),
            options: .atomic
        )
    }
}

private enum SafeAreaMatrixError: Error {
    case malformedProbe(String)
    case probeUnchanged
    case missingImage(String)
    case missingWindow
}

private extension XCUIElement {
    func waitForLabel(containing expectedValue: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", expectedValue)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
