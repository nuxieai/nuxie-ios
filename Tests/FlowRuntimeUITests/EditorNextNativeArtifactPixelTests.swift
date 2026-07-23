import CoreGraphics
import UIKit
import XCTest

final class EditorNextNativeArtifactPixelTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
        XCUIDevice.shared.orientation = .portrait
    }

    func testEveryExactP17ScreenAndSignedGPUCanvasRenderOpaquePixels() throws {
        let corpus = try Self.loadResource(
            NativePixelCorpus.self,
            named: "native-corpus-manifest"
        )
        XCTAssertEqual(
            corpus.schemaVersion,
            "nuxie-editor-next-native-corpus.v1"
        )
        XCTAssertEqual(
            corpus.entries.map(\.id),
            [
                "animation-event",
                "external-image",
                "ordinary-assets",
                "font-converter",
                "projection",
                "multi-screen",
                "scripted-resources",
                "animation-operations",
            ]
        )

        for entry in corpus.entries {
            for screen in entry.screens {
                XCTContext.runActivity(
                    named: "Exact native pixels: \(entry.id)/\(screen.screenId)"
                ) { _ in
                    do {
                        let visual = try XCTUnwrap(
                            entry.visualExpectations.first {
                                $0.screenId == screen.screenId
                            }
                        )
                        try assertPixels(
                            fixtureID: entry.id,
                            screen: screen,
                            visual: visual
                        )
                    } catch {
                        XCTFail(
                            "\(entry.id)/\(screen.screenId): "
                                + String(reflecting: error)
                        )
                    }
                }
            }
        }

        let gpuProof = try Self.loadResource(
            NativeGPUCanvasProof.self,
            named: "native-gpu-canvas-proof"
        )
        XCTAssertEqual(
            gpuProof.schemaVersion,
            "nuxie-editor-next-native-gpu-canvas-proof.v1"
        )
        XCTContext.runActivity(named: "Exact signed GPU canvas pixels") { _ in
            do {
                let visual = try XCTUnwrap(
                    gpuProof.visualExpectations.first {
                        $0.screenId == gpuProof.screen.screenId
                    }
                )
                let capture = try capture(
                    fixtureID: "gpu-canvas",
                    screen: gpuProof.screen
                )
                try assertVisual(
                    capture,
                    screen: gpuProof.screen,
                    visual: visual,
                    skipSampleIDs: ["inert-script-background"]
                )
                try assertSignedGPUCanvas(
                    capture,
                    screen: gpuProof.screen,
                    proof: gpuProof
                )
            } catch {
                XCTFail("gpu-canvas/screen: \(String(reflecting: error))")
            }
        }
    }

    private func assertPixels(
        fixtureID: String,
        screen: NativePixelScreen,
        visual: NativeScreenVisualExpectation
    ) throws {
        let capture = try capture(fixtureID: fixtureID, screen: screen)
        try assertVisual(capture, screen: screen, visual: visual)
    }

    private func capture(
        fixtureID: String,
        screen: NativePixelScreen
    ) throws -> NativePixelCapture {
        app?.terminate()
        app = XCUIApplication()
        app.launchArguments = [
            "--nuxie-fixture",
            fixtureID,
            "--nuxie-editor-next-artifact",
            "--nuxie-initial-screen",
            screen.screenId,
            "--nuxie-hide-navigation",
        ]
        app.launch()

        let fixtureRow = app.cells["nuxie-fixture-\(fixtureID)"]
        guard fixtureRow.waitForExistence(timeout: 10) else {
            throw NativePixelError.missingFixture(fixtureID)
        }
        fixtureRow.tap()

        let surface = app.otherElements
            .matching(identifier: "nuxie-flow-surface")
            .matching(NSPredicate(format: "label == %@", screen.screenId))
            .firstMatch
        guard surface.waitForExistence(timeout: 20) else {
            throw NativePixelError.missingSurface(
                fixture: fixtureID,
                screen: screen.screenId
            )
        }

        Thread.sleep(forTimeInterval: 1.25)
        let fixtureLabel = app.staticTexts["nuxie-current-fixture"]
        guard fixtureLabel.label == fixtureID else {
            throw NativePixelError.fixtureFailed(fixtureLabel.label)
        }

        let screenshot = XCUIScreen.main.screenshot()
        let pngBytes = screenshot.pngRepresentation
        let attachment = XCTAttachment(
            data: pngBytes,
            uniformTypeIdentifier: "public.png"
        )
        attachment.name = "editor-next-\(fixtureID)-\(screen.screenId).png"
        attachment.lifetime = .keepAlways
        add(attachment)

        guard let image = UIImage(data: pngBytes),
              let pixels = NativeRGBAImage(image: image) else {
            throw NativePixelError.invalidPNG
        }
        let window = app.windows.firstMatch
        guard window.exists,
              window.frame.width > 0,
              window.frame.height > 0 else {
            throw NativePixelError.missingWindow
        }

        return NativePixelCapture(
            image: pixels,
            surfaceFrame: surface.frame,
            screenshotPixelsPerPoint: CGFloat(pixels.width) / window.frame.width
        )
    }

    private func assertVisual(
        _ capture: NativePixelCapture,
        screen: NativePixelScreen,
        visual: NativeScreenVisualExpectation,
        skipSampleIDs: Set<String> = []
    ) throws {
        guard visual.coordinateSpace == "artboard-pixels-top-left",
              visual.fit == "contain" else {
            throw NativePixelError.unsupportedVisualContract
        }
        let transform = try NativeArtboardPixelTransform(
            capture: capture,
            screen: screen
        )

        for sample in visual.samples where !skipSampleIDs.contains(sample.id) {
            let pixel = try capture.image.pixel(
                at: transform.screenshotPoint(for: sample.point)
            )
            XCTAssertTrue(
                sample.rgbaThresholds.contains(pixel),
                "\(screen.screenId)/\(sample.id) got \(pixel)"
            )
        }

        for region in visual.matchingRegions {
            let screenshotBounds = transform.screenshotRect(for: region.bounds)
            let matchingPixels = capture.image.countPixels(
                in: screenshotBounds,
                matching: region.rgbaThresholds
            )
            let physicalScale = transform.artboardUnitScale
            let minimum = Int(
                ceil(
                    Double(region.minimumMatchingAreaAtOneX)
                        * physicalScale * physicalScale
                )
            )
            XCTAssertGreaterThanOrEqual(
                matchingPixels,
                minimum,
                "\(screen.screenId)/\(region.id) matched "
                    + "\(matchingPixels), expected at least \(minimum)"
            )
        }

        let artboardBounds = transform.screenshotRect(
            for: NativePixelRect(
                x: 0,
                y: 0,
                width: screen.width,
                height: screen.height
            )
        )
        let opaqueNonblack = capture.image.countPixels(
            in: artboardBounds
        ) { pixel in
            pixel.alpha >= 0.98
                && max(pixel.red, pixel.green, pixel.blue) >= 0.02
        }
        XCTAssertGreaterThan(
            opaqueNonblack,
            100,
            "\(screen.screenId) did not persist decoded nonblank opaque pixels"
        )

        if let letterboxPoint = transform.letterboxSamplePoint {
            let pixel = try capture.image.pixel(at: letterboxPoint)
            XCTAssertTrue(
                visual.letterboxRgbaThresholds.contains(pixel),
                "\(screen.screenId) letterbox got \(pixel)"
            )
        }
    }

    private func assertSignedGPUCanvas(
        _ capture: NativePixelCapture,
        screen: NativePixelScreen,
        proof: NativeGPUCanvasProof
    ) throws {
        let transform = try NativeArtboardPixelTransform(
            capture: capture,
            screen: screen
        )
        let artboardBounds = transform.screenshotRect(
            for: NativePixelRect(
                x: 0,
                y: 0,
                width: screen.width,
                height: screen.height
            )
        )
        let redPixels = capture.image.countPixels(in: artboardBounds) { pixel in
            pixel.red >= proof.expectedPixel.redMin
                && pixel.green <= proof.expectedPixel.greenMax
                && pixel.blue <= proof.expectedPixel.blueMax
                && pixel.alpha >= 0.98
        }
        XCTAssertGreaterThan(
            redPixels,
            100,
            "Verified signed GPU script did not render its red canvas"
        )
    }

    private static func loadResource<Value: Decodable>(
        _ type: Value.Type,
        named name: String
    ) throws -> Value {
        let bundle = Bundle(for: EditorNextNativeArtifactPixelTests.self)
        guard let url = bundle.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "GeneratedEditorNextFixtures"
        ) else {
            throw NativePixelError.missingResource(name)
        }
        return try JSONDecoder().decode(
            type,
            from: Data(contentsOf: url)
        )
    }
}

private struct NativePixelCorpus: Decodable {
    let schemaVersion: String
    let entries: [NativePixelCorpusEntry]
}

private struct NativePixelCorpusEntry: Decodable {
    let id: String
    let screens: [NativePixelScreen]
    let visualExpectations: [NativeScreenVisualExpectation]
}

private struct NativeGPUCanvasProof: Decodable {
    struct ExpectedPixel: Decodable {
        let redMin: Double
        let greenMax: Double
        let blueMax: Double
    }

    let schemaVersion: String
    let screen: NativePixelScreen
    let expectedPixel: ExpectedPixel
    let visualExpectations: [NativeScreenVisualExpectation]
}

private struct NativePixelScreen: Decodable {
    let screenId: String
    let width: Double
    let height: Double
}

private struct NativeScreenVisualExpectation: Decodable {
    let screenId: String
    let coordinateSpace: String
    let fit: String
    let letterboxRgbaThresholds: NativeRGBAThresholds
    let samples: [NativePixelSample]
    let matchingRegions: [NativePixelRegion]
}

private struct NativePixelSample: Decodable {
    let id: String
    let point: NativePixelPoint
    let rgbaThresholds: NativeRGBAThresholds
}

private struct NativePixelRegion: Decodable {
    let id: String
    let bounds: NativePixelRect
    let rgbaThresholds: NativeRGBAThresholds
    let minimumMatchingAreaAtOneX: Int
}

private struct NativePixelPoint: Decodable {
    let x: Double
    let y: Double
}

private struct NativePixelRect: Decodable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

private struct NativeChannelThreshold: Decodable {
    let min: Double
    let max: Double

    func contains(_ value: Double) -> Bool {
        value >= min && value <= max
    }
}

private struct NativeRGBAThresholds: Decodable {
    let red: NativeChannelThreshold
    let green: NativeChannelThreshold
    let blue: NativeChannelThreshold
    let alpha: NativeChannelThreshold

    func contains(_ pixel: NativeRGBA) -> Bool {
        red.contains(pixel.red)
            && green.contains(pixel.green)
            && blue.contains(pixel.blue)
            && alpha.contains(pixel.alpha)
    }
}

private struct NativeRGBA: CustomStringConvertible {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    var description: String {
        "rgba(\(red), \(green), \(blue), \(alpha))"
    }
}

private struct NativePixelCapture {
    let image: NativeRGBAImage
    let surfaceFrame: CGRect
    let screenshotPixelsPerPoint: CGFloat
}

private struct NativeArtboardPixelTransform {
    let artboardOrigin: CGPoint
    let artboardUnitScale: Double
    let capture: NativePixelCapture
    let letterboxSamplePoint: CGPoint?

    init(
        capture: NativePixelCapture,
        screen: NativePixelScreen
    ) throws {
        guard screen.width > 0,
              screen.height > 0,
              capture.surfaceFrame.width > 0,
              capture.surfaceFrame.height > 0,
              capture.screenshotPixelsPerPoint > 0 else {
            throw NativePixelError.invalidGeometry
        }
        let pointScale = min(
            capture.surfaceFrame.width / screen.width,
            capture.surfaceFrame.height / screen.height
        )
        let renderedWidth = screen.width * pointScale
        let renderedHeight = screen.height * pointScale
        let originInPoints = CGPoint(
            x: capture.surfaceFrame.minX
                + (capture.surfaceFrame.width - renderedWidth) / 2,
            y: capture.surfaceFrame.minY
                + (capture.surfaceFrame.height - renderedHeight) / 2
        )
        let pixelScale = capture.screenshotPixelsPerPoint
        self.artboardOrigin = CGPoint(
            x: originInPoints.x * pixelScale,
            y: originInPoints.y * pixelScale
        )
        self.artboardUnitScale = pointScale * pixelScale
        self.capture = capture

        let horizontalBand =
            (capture.surfaceFrame.width - renderedWidth) / 2
        let verticalBand =
            (capture.surfaceFrame.height - renderedHeight) / 2
        if horizontalBand >= 2 {
            self.letterboxSamplePoint = CGPoint(
                x: (capture.surfaceFrame.minX + horizontalBand / 2) * pixelScale,
                y: capture.surfaceFrame.midY * pixelScale
            )
        } else if verticalBand >= 2 {
            self.letterboxSamplePoint = CGPoint(
                x: capture.surfaceFrame.midX * pixelScale,
                y: (capture.surfaceFrame.minY + verticalBand / 2) * pixelScale
            )
        } else {
            self.letterboxSamplePoint = nil
        }
    }

    func screenshotPoint(for point: NativePixelPoint) -> CGPoint {
        CGPoint(
            x: artboardOrigin.x + point.x * artboardUnitScale,
            y: artboardOrigin.y + point.y * artboardUnitScale
        )
    }

    func screenshotRect(for rect: NativePixelRect) -> CGRect {
        CGRect(
            x: artboardOrigin.x + rect.x * artboardUnitScale,
            y: artboardOrigin.y + rect.y * artboardUnitScale,
            width: rect.width * artboardUnitScale,
            height: rect.height * artboardUnitScale
        )
    }
}

private struct NativeRGBAImage {
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init?(image: UIImage) {
        guard let cgImage = image.cgImage else { return nil }
        width = cgImage.width
        height = cgImage.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            return nil
        }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(
            cgImage,
            in: CGRect(x: 0, y: 0, width: width, height: height)
        )
        self.bytes = bytes
    }

    func pixel(at point: CGPoint) throws -> NativeRGBA {
        let x = Int(point.x.rounded(.down))
        let y = Int(point.y.rounded(.down))
        guard x >= 0, x < width, y >= 0, y < height else {
            throw NativePixelError.sampleOutsideImage(point)
        }
        return pixel(x: x, y: y)
    }

    func countPixels(
        in rect: CGRect,
        matching predicate: (NativeRGBA) -> Bool
    ) -> Int {
        let minX = max(0, Int(rect.minX.rounded(.down)))
        let minY = max(0, Int(rect.minY.rounded(.down)))
        let maxX = min(width, Int(rect.maxX.rounded(.up)))
        let maxY = min(height, Int(rect.maxY.rounded(.up)))
        guard minX < maxX, minY < maxY else { return 0 }

        var count = 0
        for y in minY..<maxY {
            for x in minX..<maxX where predicate(pixel(x: x, y: y)) {
                count += 1
            }
        }
        return count
    }

    func countPixels(
        in rect: CGRect,
        matching thresholds: NativeRGBAThresholds
    ) -> Int {
        countPixels(in: rect, matching: thresholds.contains)
    }

    private func pixel(x: Int, y: Int) -> NativeRGBA {
        let offset = (y * width + x) * 4
        return NativeRGBA(
            red: Double(bytes[offset]) / 255,
            green: Double(bytes[offset + 1]) / 255,
            blue: Double(bytes[offset + 2]) / 255,
            alpha: Double(bytes[offset + 3]) / 255
        )
    }
}

private enum NativePixelError: LocalizedError {
    case missingResource(String)
    case missingFixture(String)
    case missingSurface(fixture: String, screen: String)
    case fixtureFailed(String)
    case invalidPNG
    case missingWindow
    case unsupportedVisualContract
    case invalidGeometry
    case sampleOutsideImage(CGPoint)

    var errorDescription: String? {
        switch self {
        case .missingResource(let name):
            "Missing exact generated UI-test resource \(name).json"
        case .missingFixture(let fixture):
            "Missing exact host fixture \(fixture)"
        case .missingSurface(let fixture, let screen):
            "Missing production surface \(fixture)/\(screen)"
        case .fixtureFailed(let label):
            "Production fixture host reported \(label)"
        case .invalidPNG:
            "XCTest screenshot did not decode as RGBA pixels"
        case .missingWindow:
            "Production fixture host window is unavailable"
        case .unsupportedVisualContract:
            "Exact fixture uses an unsupported pixel coordinate contract"
        case .invalidGeometry:
            "Exact fixture has invalid artboard or surface geometry"
        case .sampleOutsideImage(let point):
            "Pixel sample \(point) lies outside the XCTest screenshot"
        }
    }
}
