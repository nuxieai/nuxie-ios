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
            if let animations = entry.animationExpectations {
                XCTAssertEqual(
                    entry.id,
                    "animation-operations",
                    "Only the animation corpus may declare timeline pixels"
                )
                try assertEveryAnimationChangesPixels(
                    animations,
                    entry: entry
                )
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
                    screen: gpuProof.screen,
                    visual: visual
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

    func testDeclaredBehaviorOperationsRenderExpectedPixels() throws {
        let corpus = try Self.loadResource(
            NativePixelCorpus.self,
            named: "native-corpus-manifest"
        )
        let behaviorEntries = corpus.entries.filter {
            $0.behaviorExpectations != nil
        }
        XCTAssertEqual(
            behaviorEntries.map(\.id),
            ["animation-event", "font-converter", "projection"]
        )

        for entry in behaviorEntries {
            XCTContext.runActivity(
                named: "Declared native behavior pixels: \(entry.id)"
            ) { _ in
                do {
                    if let stateMachine =
                        entry.behaviorExpectations?.stateMachine {
                        try assertStateMachinePixels(
                            stateMachine,
                            entry: entry
                        )
                    }
                    if let converter =
                        entry.behaviorExpectations?.converter {
                        try assertConverterPixels(
                            converter,
                            entry: entry
                        )
                    }
                    if let projection =
                        entry.behaviorExpectations?.projection {
                        try assertProjectionPixels(
                            projection,
                            entry: entry
                        )
                    }
                } catch {
                    XCTFail(
                        "\(entry.id): " + String(reflecting: error)
                    )
                }
            }
        }
    }

    private func assertStateMachinePixels(
        _ expectation: NativeStateMachineExpectation,
        entry: NativePixelCorpusEntry
    ) throws {
        let screen = try XCTUnwrap(entry.screens.first)
        XCTAssertEqual(entry.screens.count, 1)
        let visual = try XCTUnwrap(
            entry.visualExpectations.first {
                $0.screenId == screen.screenId
            }
        )
        XCTAssertEqual(visual.player?.kind, .stateMachine)
        XCTAssertEqual(
            visual.player?.name,
            expectation.stateMachineName
        )

        let surface = try launchFixture(
            fixtureID: entry.id,
            screen: screen,
            player: visual.player,
            timestampSeconds: visual.timestampSeconds ?? 0
        )
        let before = try captureCurrentFrame(
            fixtureID: entry.id,
            surface: surface,
            evidenceName: "\(screen.screenId)-state-machine-before"
        )
        try assertSamples(
            [expectation.beforeSample],
            capture: before,
            screen: screen
        )

        let transform = try NativeArtboardPixelTransform(
            capture: before,
            screen: screen
        )
        surface.coordinate(
            withNormalizedOffset: transform.surfaceNormalizedOffset(
                for: expectation.triggerPointer
            )
        ).tap()
        try waitForFixedFrame(
            surface,
            fixtureID: entry.id,
            screenID: screen.screenId
        )

        let after = try captureCurrentFrame(
            fixtureID: entry.id,
            surface: surface,
            evidenceName: "\(screen.screenId)-state-machine-after"
        )
        try assertSamples(
            [expectation.afterSample],
            capture: after,
            screen: screen
        )
    }

    private func assertConverterPixels(
        _ expectation: NativeConverterExpectation,
        entry: NativePixelCorpusEntry
    ) throws {
        let screen = try XCTUnwrap(entry.screens.first)
        XCTAssertEqual(entry.screens.count, 1)
        let visual = try XCTUnwrap(
            entry.visualExpectations.first {
                $0.screenId == screen.screenId
            }
        )
        let operationSteps = [
            [
                NativeHostBehaviorOperation.setValue(
                    viewModelName: expectation.viewModelName,
                    path: expectation.path,
                    value: .string(expectation.input),
                    screenId: screen.screenId
                ),
            ],
        ]
        let surface = try launchFixture(
            fixtureID: entry.id,
            screen: screen,
            player: visual.player,
            timestampSeconds: visual.timestampSeconds ?? 0,
            behaviorOperationSteps: operationSteps
        )
        let before = try captureCurrentFrame(
            fixtureID: entry.id,
            surface: surface,
            evidenceName: "\(screen.screenId)-converter-before"
        )
        let beforeTransform = try NativeArtboardPixelTransform(
            capture: before,
            screen: screen
        )
        let beforeInkBounds = try XCTUnwrap(
            before.image.matchingPixelBounds(
                in: beforeTransform.screenshotRect(
                    for: expectation.inkRegion.bounds
                ),
                matching: expectation.inkRegion.rgbaThresholds
            ),
            "No baseline ink rendered before converting to "
                + expectation.renderedText
        )

        try applyNextBehaviorOperation(
            index: 0,
            count: operationSteps.count,
            surface: surface,
            fixtureID: entry.id,
            screenID: screen.screenId
        )
        let after = try captureCurrentFrame(
            fixtureID: entry.id,
            surface: surface,
            evidenceName: "\(screen.screenId)-converter-after"
        )
        let afterTransform = try NativeArtboardPixelTransform(
            capture: after,
            screen: screen
        )
        XCTAssertEqual(
            beforeTransform.artboardUnitScale,
            afterTransform.artboardUnitScale
        )
        try assertRegion(
            expectation.inkRegion,
            capture: after,
            screen: screen,
            transform: afterTransform
        )
        let afterInkBounds = try XCTUnwrap(
            after.image.matchingPixelBounds(
                in: afterTransform.screenshotRect(
                    for: expectation.inkRegion.bounds
                ),
                matching: expectation.inkRegion.rgbaThresholds
            ),
            "Converted text \(expectation.renderedText) rendered no ink"
        )
        let inkWidthIncrease = afterInkBounds.width
            - beforeInkBounds.width
        XCTAssertGreaterThanOrEqual(
            Double(inkWidthIncrease),
            expectation.minimumInkWidthIncrease
                * afterTransform.artboardUnitScale,
            "Converted text \(expectation.renderedText) widened ink by "
                + "\(inkWidthIncrease) physical pixels"
        )
    }

    private func assertProjectionPixels(
        _ expectation: NativeProjectionExpectation,
        entry: NativePixelCorpusEntry
    ) throws {
        let screen = try XCTUnwrap(entry.screens.first)
        XCTAssertEqual(entry.screens.count, 1)
        let visual = try XCTUnwrap(
            entry.visualExpectations.first {
                $0.screenId == screen.screenId
            }
        )
        let writeOperations = expectation.writes.map { write in
            NativeHostBehaviorOperation.setValue(
                viewModelName: write.viewModelName
                    ?? expectation.viewModelName,
                path: write.path,
                value: write.value,
                screenId: screen.screenId,
                instanceId: write.instanceId
            )
        }
        var operationSteps = [writeOperations]
        if let listMutation = expectation.listMutation {
            operationSteps.append([
                .listOperation(
                    viewModelName: expectation.viewModelName,
                    path: listMutation.path,
                    operation: listMutation.operation,
                    payload: listMutation.payload,
                    screenId: screen.screenId
                ),
            ])
        }

        let surface = try launchFixture(
            fixtureID: entry.id,
            screen: screen,
            player: visual.player,
            timestampSeconds: visual.timestampSeconds ?? 0,
            behaviorOperationSteps: operationSteps
        )
        let before = try captureCurrentFrame(
            fixtureID: entry.id,
            surface: surface,
            evidenceName: "\(screen.screenId)-projection-before"
        )
        try assertSamples(
            expectation.beforeSamples,
            capture: before,
            screen: screen
        )

        try applyNextBehaviorOperation(
            index: 0,
            count: operationSteps.count,
            surface: surface,
            fixtureID: entry.id,
            screenID: screen.screenId
        )
        let afterWrites = try captureCurrentFrame(
            fixtureID: entry.id,
            surface: surface,
            evidenceName: "\(screen.screenId)-projection-after-writes"
        )
        try assertSamples(
            expectation.afterSamples,
            capture: afterWrites,
            screen: screen
        )

        if let listMutation = expectation.listMutation {
            try applyNextBehaviorOperation(
                index: 1,
                count: operationSteps.count,
                surface: surface,
                fixtureID: entry.id,
                screenID: screen.screenId
            )
            let afterListMutation = try captureCurrentFrame(
                fixtureID: entry.id,
                surface: surface,
                evidenceName: "\(screen.screenId)-projection-after-list-move"
            )
            try assertSamples(
                listMutation.afterSamples,
                capture: afterListMutation,
                screen: screen
            )
        }
    }

    private func assertPixels(
        fixtureID: String,
        screen: NativePixelScreen,
        visual: NativeScreenVisualExpectation
    ) throws {
        let capture = try capture(
            fixtureID: fixtureID,
            screen: screen,
            visual: visual
        )
        try assertVisual(capture, screen: screen, visual: visual)
    }

    private func capture(
        fixtureID: String,
        screen: NativePixelScreen,
        visual: NativeScreenVisualExpectation
    ) throws -> NativePixelCapture {
        try capture(
            fixtureID: fixtureID,
            screen: screen,
            player: visual.player,
            timestampSeconds: visual.timestampSeconds ?? 0,
            evidenceName: screen.screenId
        )
    }

    private func capture(
        fixtureID: String,
        screen: NativePixelScreen,
        player: NativeVisualPlayer?,
        timestampSeconds: Double,
        evidenceName: String
    ) throws -> NativePixelCapture {
        let surface = try launchFixture(
            fixtureID: fixtureID,
            screen: screen,
            player: player,
            timestampSeconds: timestampSeconds
        )
        return try captureCurrentFrame(
            fixtureID: fixtureID,
            surface: surface,
            evidenceName: evidenceName
        )
    }

    private func launchFixture(
        fixtureID: String,
        screen: NativePixelScreen,
        player: NativeVisualPlayer?,
        timestampSeconds: Double,
        behaviorOperationSteps: [[NativeHostBehaviorOperation]] = []
    ) throws -> XCUIElement {
        app?.terminate()
        app = XCUIApplication()
        app.launchArguments = [
            "--nuxie-fixture",
            fixtureID,
            "--nuxie-editor-next-artifact",
            "--nuxie-initial-screen",
            screen.screenId,
            "--nuxie-hide-navigation",
            "--nuxie-player-kind",
            player?.kind.rawValue ?? "default",
            "--nuxie-fixed-timestamp",
            String(timestampSeconds),
        ]
        if let player {
            app.launchArguments += ["--nuxie-player-name", player.name]
        }
        if !behaviorOperationSteps.isEmpty {
            let operations = try JSONEncoder().encode(
                behaviorOperationSteps
            )
            app.launchArguments += [
                "--nuxie-behavior-operations",
                operations.base64EncodedString(),
            ]
        }
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

        try waitForFixedFrame(
            surface,
            fixtureID: fixtureID,
            screenID: screen.screenId
        )
        let fixtureLabel = app.staticTexts["nuxie-current-fixture"]
        guard fixtureLabel.label == fixtureID else {
            throw NativePixelError.fixtureFailed(fixtureLabel.label)
        }
        return surface
    }

    private func waitForFixedFrame(
        _ surface: XCUIElement,
        fixtureID: String,
        screenID: String
    ) throws {
        let fixedFrameReady = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "value == %@",
                "fixed-frame-ready"
            ),
            object: surface
        )
        guard XCTWaiter.wait(
            for: [fixedFrameReady],
            timeout: 20
        ) == .completed else {
            throw NativePixelError.fixedFrameTimedOut(
                fixture: fixtureID,
                screen: screenID
            )
        }
    }

    private func applyNextBehaviorOperation(
        index: Int,
        count: Int,
        surface: XCUIElement,
        fixtureID: String,
        screenID: String
    ) throws {
        let button = app.buttons["nuxie-behavior-next-operation"]
        guard button.waitForExistence(timeout: 5), button.isHittable else {
            throw NativePixelError.missingBehaviorControl
        }
        button.tap()

        let expectedStatus = "applied:\(index + 1)/\(count)"
        let status = app.staticTexts["nuxie-behavior-operation-status"]
        let operationApplied = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "label == %@",
                expectedStatus
            ),
            object: status
        )
        guard XCTWaiter.wait(
            for: [operationApplied],
            timeout: 5
        ) == .completed else {
            throw NativePixelError.behaviorOperationTimedOut(
                expected: expectedStatus,
                actual: status.label
            )
        }
        try waitForFixedFrame(
            surface,
            fixtureID: fixtureID,
            screenID: screenID
        )
    }

    private func captureCurrentFrame(
        fixtureID: String,
        surface: XCUIElement,
        evidenceName: String
    ) throws -> NativePixelCapture {
        let screenshot = XCUIScreen.main.screenshot()
        let pngBytes = screenshot.pngRepresentation
        let attachment = XCTAttachment(
            data: pngBytes,
            uniformTypeIdentifier: "public.png"
        )
        attachment.name = "editor-next-\(fixtureID)-\(evidenceName).png"
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

    private func assertEveryAnimationChangesPixels(
        _ animations: [NativePixelAnimationExpectation],
        entry: NativePixelCorpusEntry
    ) throws {
        let screen = try XCTUnwrap(entry.screens.first)
        XCTAssertEqual(entry.screens.count, 1)
        XCTAssertEqual(animations.count, 28)

        for animation in animations {
            try XCTContext.runActivity(
                named: "Exact native animation pixels: \(animation.name)"
            ) { _ in
                let player = NativeVisualPlayer(
                    kind: .linearAnimation,
                    name: animation.name
                )
                let evidencePrefix = animation.operationKey
                    + "-"
                    + animation.easing
                let start = try capture(
                    fixtureID: entry.id,
                    screen: screen,
                    player: player,
                    timestampSeconds: animation.startSeconds,
                    evidenceName: "\(evidencePrefix)-start"
                )
                let quarter = try capture(
                    fixtureID: entry.id,
                    screen: screen,
                    player: player,
                    timestampSeconds: animation.startSeconds
                        + animation.durationSeconds / 4,
                    evidenceName: "\(evidencePrefix)-quarter"
                )
                let end = try capture(
                    fixtureID: entry.id,
                    screen: screen,
                    player: player,
                    timestampSeconds: animation.endSeconds,
                    evidenceName: "\(evidencePrefix)-end"
                )

                XCTAssertEqual(start.image.width, quarter.image.width)
                XCTAssertEqual(start.image.height, quarter.image.height)
                XCTAssertEqual(start.image.width, end.image.width)
                XCTAssertEqual(start.image.height, end.image.height)
                XCTAssertEqual(start.surfaceFrame, quarter.surfaceFrame)
                XCTAssertEqual(start.surfaceFrame, end.surfaceFrame)

                let transform = try NativeArtboardPixelTransform(
                    capture: start,
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
                let changedPixels = start.image.changedPixelCount(
                    comparedTo: end.image,
                    in: artboardBounds
                )
                let expectedMinimum = Int(
                    ceil(
                        Double(animation.minimumChangedAreaAtOneX)
                            * transform.artboardUnitScale
                            * transform.artboardUnitScale
                    )
                )
                XCTAssertGreaterThanOrEqual(
                    changedPixels,
                    expectedMinimum,
                    "\(animation.name) did not apply "
                        + "\(animation.operationKey) property keys "
                        + "\(animation.propertyKeys): changed "
                        + "\(changedPixels) pixels"
                )

                if let expectedProgress =
                    animation.quarterProgressOpacity {
                    let measuredProgress = quarter.image.colorProgress(
                        from: start.image,
                        to: end.image,
                        in: artboardBounds
                    )
                    XCTAssertEqual(
                        measuredProgress,
                        expectedProgress,
                        accuracy: 0.03,
                        "\(animation.name) did not apply "
                            + "\(animation.easing) easing at quarter progress"
                    )
                }
            }
        }
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

        try assertSamples(
            visual.samples.filter {
                !skipSampleIDs.contains($0.id)
            },
            capture: capture,
            screen: screen,
            transform: transform
        )

        for region in visual.matchingRegions {
            try assertRegion(
                region,
                capture: capture,
                screen: screen,
                transform: transform
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

    private func assertSamples(
        _ samples: [NativePixelSample],
        capture: NativePixelCapture,
        screen: NativePixelScreen,
        transform suppliedTransform: NativeArtboardPixelTransform? = nil
    ) throws {
        let transform = try suppliedTransform
            ?? NativeArtboardPixelTransform(
                capture: capture,
                screen: screen
            )
        for sample in samples {
            let pixel = try capture.image.pixel(
                at: transform.screenshotPoint(for: sample.point)
            )
            XCTAssertTrue(
                sample.rgbaThresholds.contains(pixel),
                "\(screen.screenId)/\(sample.id) got \(pixel)"
            )
        }
    }

    private func assertRegion(
        _ region: NativePixelRegion,
        capture: NativePixelCapture,
        screen: NativePixelScreen,
        transform suppliedTransform: NativeArtboardPixelTransform? = nil
    ) throws {
        let transform = try suppliedTransform
            ?? NativeArtboardPixelTransform(
                capture: capture,
                screen: screen
            )
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
    let behaviorExpectations: NativeBehaviorExpectations?
    let animationExpectations: [NativePixelAnimationExpectation]?
}

private struct NativeBehaviorExpectations: Decodable {
    let stateMachine: NativeStateMachineExpectation?
    let converter: NativeConverterExpectation?
    let projection: NativeProjectionExpectation?
}

private struct NativeStateMachineExpectation: Decodable {
    let stateMachineName: String
    let triggerPointer: NativePixelPoint
    let beforeSample: NativePixelSample
    let afterSample: NativePixelSample
}

private struct NativeConverterExpectation: Decodable {
    let viewModelName: String
    let path: String
    let input: String
    let renderedText: String
    let inkRegion: NativePixelRegion
    let minimumInkWidthIncrease: Double
}

private struct NativeProjectionExpectation: Decodable {
    let viewModelName: String
    let writes: [NativeViewModelWrite]
    let listMutation: NativeListMutationExpectation?
    let beforeSamples: [NativePixelSample]
    let afterSamples: [NativePixelSample]
}

private struct NativeViewModelWrite: Decodable {
    let viewModelName: String?
    let instanceId: String?
    let path: String
    let value: NativeJSONValue
}

private struct NativeListMutationExpectation: Decodable {
    let path: String
    let operation: String
    let payload: [String: NativeJSONValue]
    let expectedProductIds: [String]
    let expectedCount: Int
    let afterSamples: [NativePixelSample]
}

private struct NativeHostBehaviorOperation: Encodable {
    enum Kind: String, Encodable {
        case setValue = "set-value"
        case listOperation = "list-operation"
    }

    let kind: Kind
    let viewModelName: String
    let path: String
    let value: NativeJSONValue?
    let operation: String?
    let payload: [String: NativeJSONValue]?
    let screenId: String?
    let instanceId: String?

    static func setValue(
        viewModelName: String,
        path: String,
        value: NativeJSONValue,
        screenId: String?,
        instanceId: String? = nil
    ) -> NativeHostBehaviorOperation {
        NativeHostBehaviorOperation(
            kind: .setValue,
            viewModelName: viewModelName,
            path: path,
            value: value,
            operation: nil,
            payload: nil,
            screenId: screenId,
            instanceId: instanceId
        )
    }

    static func listOperation(
        viewModelName: String,
        path: String,
        operation: String,
        payload: [String: NativeJSONValue],
        screenId: String?,
        instanceId: String? = nil
    ) -> NativeHostBehaviorOperation {
        NativeHostBehaviorOperation(
            kind: .listOperation,
            viewModelName: viewModelName,
            path: path,
            value: nil,
            operation: operation,
            payload: payload,
            screenId: screenId,
            instanceId: instanceId
        )
    }
}

private enum NativeJSONValue: Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([NativeJSONValue])
    case object([String: NativeJSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([NativeJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode(
            [String: NativeJSONValue].self
        ) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected a JSON behavior value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let values):
            try container.encode(values)
        case .object(let object):
            try container.encode(object)
        }
    }
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
    let player: NativeVisualPlayer?
    let timestampSeconds: Double?
    let letterboxRgbaThresholds: NativeRGBAThresholds
    let samples: [NativePixelSample]
    let matchingRegions: [NativePixelRegion]
}

private struct NativeVisualPlayer {
    enum Kind: String {
        case stateMachine = "state-machine"
        case linearAnimation = "linear-animation"
    }

    let kind: Kind
    let name: String
}

extension NativeVisualPlayer: Decodable {}
extension NativeVisualPlayer.Kind: Decodable {}

private struct NativePixelAnimationExpectation: Decodable {
    let name: String
    let operationKey: String
    let easing: String
    let durationSeconds: Double
    let startSeconds: Double
    let endSeconds: Double
    let propertyKeys: [Int]
    let minimumChangedAreaAtOneX: Int
    let quarterProgressOpacity: Double?
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

    func surfaceNormalizedOffset(
        for point: NativePixelPoint
    ) -> CGVector {
        let screenshotPoint = screenshotPoint(for: point)
        let pointInWindow = CGPoint(
            x: screenshotPoint.x / capture.screenshotPixelsPerPoint,
            y: screenshotPoint.y / capture.screenshotPixelsPerPoint
        )
        return CGVector(
            dx: (pointInWindow.x - capture.surfaceFrame.minX)
                / capture.surfaceFrame.width,
            dy: (pointInWindow.y - capture.surfaceFrame.minY)
                / capture.surfaceFrame.height
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

    func matchingPixelBounds(
        in rect: CGRect,
        matching thresholds: NativeRGBAThresholds
    ) -> CGRect? {
        let bounds = pixelBounds(for: rect)
        var minimumX = width
        var minimumY = height
        var maximumX = -1
        var maximumY = -1
        for y in bounds.minY..<bounds.maxY {
            for x in bounds.minX..<bounds.maxX
            where thresholds.contains(pixel(x: x, y: y)) {
                minimumX = min(minimumX, x)
                minimumY = min(minimumY, y)
                maximumX = max(maximumX, x)
                maximumY = max(maximumY, y)
            }
        }
        guard maximumX >= minimumX, maximumY >= minimumY else {
            return nil
        }
        return CGRect(
            x: CGFloat(minimumX),
            y: CGFloat(minimumY),
            width: CGFloat(maximumX - minimumX + 1),
            height: CGFloat(maximumY - minimumY + 1)
        )
    }

    func changedPixelCount(
        comparedTo other: NativeRGBAImage,
        in rect: CGRect
    ) -> Int {
        precondition(width == other.width && height == other.height)
        let bounds = pixelBounds(for: rect)
        var count = 0
        for y in bounds.minY..<bounds.maxY {
            for x in bounds.minX..<bounds.maxX {
                let offset = (y * width + x) * 4
                if bytes[offset] != other.bytes[offset]
                    || bytes[offset + 1] != other.bytes[offset + 1]
                    || bytes[offset + 2] != other.bytes[offset + 2] {
                    count += 1
                }
            }
        }
        return count
    }

    func colorProgress(
        from start: NativeRGBAImage,
        to end: NativeRGBAImage,
        in rect: CGRect
    ) -> Double {
        precondition(width == start.width && height == start.height)
        precondition(width == end.width && height == end.height)
        let bounds = pixelBounds(for: rect)
        var numerator = 0.0
        var denominator = 0.0
        for y in bounds.minY..<bounds.maxY {
            for x in bounds.minX..<bounds.maxX {
                let offset = (y * width + x) * 4
                for channel in 0..<3 {
                    let startValue = Double(start.bytes[offset + channel])
                    let endVector =
                        Double(end.bytes[offset + channel]) - startValue
                    guard abs(endVector) > 1 else { continue }
                    let quarterVector =
                        Double(bytes[offset + channel]) - startValue
                    numerator += quarterVector * endVector
                    denominator += endVector * endVector
                }
            }
        }
        return denominator == 0 ? .nan : numerator / denominator
    }

    private func pixelBounds(
        for rect: CGRect
    ) -> (minX: Int, minY: Int, maxX: Int, maxY: Int) {
        (
            max(0, Int(rect.minX.rounded(.down))),
            max(0, Int(rect.minY.rounded(.down))),
            min(width, Int(rect.maxX.rounded(.up))),
            min(height, Int(rect.maxY.rounded(.up)))
        )
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
    case fixedFrameTimedOut(fixture: String, screen: String)
    case fixtureFailed(String)
    case missingBehaviorControl
    case behaviorOperationTimedOut(expected: String, actual: String)
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
        case .fixedFrameTimedOut(let fixture, let screen):
            "Production surface did not commit fixed frame \(fixture)/\(screen)"
        case .fixtureFailed(let label):
            "Production fixture host reported \(label)"
        case .missingBehaviorControl:
            "Production fixture host behavior control is unavailable"
        case .behaviorOperationTimedOut(let expected, let actual):
            "Behavior operation did not reach \(expected); host reported \(actual)"
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
