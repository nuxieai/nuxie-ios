#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import CoreText
import Darwin
import Foundation
import ImageIO
import Metal
import QuartzCore
import XCTest
@testable import NuxieRuntime

final class NuxieNativeRuntimeTests: XCTestCase {
    #if os(iOS)
    func testMixedSystemAndCDNFontsRenderBothTextRows() async throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/runtime/system-font-axes")
        struct Font: Decodable { let location: String; let riveAssetId: UInt32 }
        struct Scene: Decodable { let name: String; let fonts: [Font]? }
        struct Provenance: Decodable { let scenes: [Scene] }
        let provenance = try JSONDecoder().decode(Provenance.self,
            from: Data(contentsOf: directory.appendingPathComponent("provenance.json")))
        let fonts = try XCTUnwrap(provenance.scenes.first { $0.name == "mixed" }?.fonts)
        let systemID = try XCTUnwrap(fonts.first { $0.location == "system" }?.riveAssetId)
        let bytes = try Data(contentsOf: directory.appendingPathComponent("mixed.nux"))
        let assets = try await NuxieNativeRuntime.inspectAssets(bytes: bytes)
        XCTAssertEqual(assets.count, 2)
        let system = try ExperienceRuntimeSystemFontProvider.prepare(weight: "400", style: "normal")
        let cdn = try Data(contentsOf: directory.appendingPathComponent("mixed-cdn.ttf"))
        let external = Dictionary(uniqueKeysWithValues: assets.map {
            ($0.ordinal, $0.authoredID == systemID ? system.bytes : cdn)
        })
        let runtime = try await NuxieNativeRuntime.open(bytes: bytes, artboardName: "One",
            player: .staticArtboard, pixelWidth: 320, pixelHeight: 640, bindDefaultViewModel: false,
            importMode: .configured(moduleName: "nuxie", expectedAssets: assets, externalAssets: external))
        do {
            _ = try await runtime.step(elapsedSeconds: 0)
            let rendered = try await renderPixels(runtime, width: 320, height: 640)
            XCTAssertEqual(rendered.outcome.disposition, .presented)
            for rows in [16..<112, 144..<240] {
                let ink = rows.reduce(0) { total, y in
                    total + (0..<320).reduce(0) { $0 + max(0, Int(rendered.pixels[(y * 320 + $1) * 4 + 2]) - 0x11) }
                }
                XCTAssertGreaterThan(ink, 10_000, "Both System and CDN rows must contain visible glyphs")
            }
            try await runtime.close()
        } catch {
            try? await runtime.close()
            throw error
        }
    }

    func testDeviceSystemFontWeightAndOpticalSizeChangeRenderedGlyphs() async throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/runtime/system-font-axes")
        func pixels(_ name: String, weight: String, fallback: Bool) async throws -> Data {
            let bytes = try Data(contentsOf: directory.appendingPathComponent("\(name).nux"))
            let assets = try await NuxieNativeRuntime.inspectAssets(bytes: bytes)
            let fonts = assets.filter { $0.kind == .font }
            XCTAssertEqual(fonts.count, 1)
            let font = try XCTUnwrap(fonts.first)
            let candidate = fallback
                ? try ExperienceRuntimeSystemFontProvider.prepare(weight: weight, style: "normal", readFile: { _ in Data() })
                : try ExperienceRuntimeSystemFontProvider.prepare(weight: weight, style: "normal")
            let runtime = try await NuxieNativeRuntime.open(bytes: bytes, artboardName: "One",
                player: .staticArtboard, pixelWidth: 320, pixelHeight: 640, bindDefaultViewModel: false,
                importMode: .configured(moduleName: "nuxie", expectedAssets: assets,
                    externalAssets: [font.ordinal: candidate.bytes]))
            do {
                _ = try await runtime.step(elapsedSeconds: 0)
                let rendered = try await renderPixels(runtime, width: 320, height: 640)
                XCTAssertEqual(rendered.outcome.disposition, .presented)
                try await runtime.close()
                return rendered.pixels
            } catch {
                try? await runtime.close()
                throw error
            }
        }
        func ink(_ pixels: Data) -> Int {
            // White glyph coverage above the render helper's dark clear color.
            stride(from: 2, to: pixels.count, by: 4).reduce(0) { $0 + max(0, Int(pixels[$1]) - 0x11) }
        }
        var fileRegular: Data?
        for fallback in [false, true] {
            let candidate = fallback
                ? try ExperienceRuntimeSystemFontProvider.prepare(weight: "400", style: "normal", readFile: { _ in Data() })
                : try ExperienceRuntimeSystemFontProvider.prepare(weight: "400", style: "normal")
            let provider = try XCTUnwrap(CGDataProvider(data: candidate.bytes as CFData))
            let graphicsFont = try XCTUnwrap(CGFont(provider))
            let nativeFont = CTFontCreateWithGraphicsFont(graphicsFont, 32, nil, nil)
            func outlines(opticalSize: Double) throws -> [CGPath] {
                let attributes: [CFString: Any] = [
                    kCTFontVariationAttribute: [NSNumber(value: 0x6f70737a): opticalSize],
                    kCTFontOpticalSizeAttribute: opticalSize,
                ]
                let descriptor = CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
                let font = CTFontCreateCopyWithAttributes(nativeFont, 32, nil, descriptor)
                let characters = Array("Hamburgefonts 0123".utf16)
                var glyphs = [CGGlyph](repeating: 0, count: characters.count)
                XCTAssertTrue(CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count))
                return glyphs.compactMap { CTFontCreatePathForGlyph(font, $0, nil) }
            }
            XCTAssertNotEqual(try outlines(opticalSize: 17), try outlines(opticalSize: 32),
                "CoreText must independently confirm that the control coordinates change this device font")
            let regular = try await pixels("regular", weight: "400", fallback: fallback)
            let bold = try await pixels("bold", weight: "700", fallback: fallback)
            let sharedFaceBold = try await pixels("bold", weight: "400", fallback: fallback)
            let baseline = try await pixels("optical-baseline", weight: "400", fallback: fallback)
            let opticalControl = try await pixels("optical-control", weight: "400", fallback: fallback)
            XCTAssertGreaterThan(ink(regular), 10_000, "The scene must contain visible glyphs")
            XCTAssertGreaterThan(ink(bold), ink(regular), "Authored bold must increase glyph coverage")
            XCTAssertEqual(sharedFaceBold, bold,
                "The authored wght axis must select bold even when both styles share the regular variable face")
            XCTAssertEqual(baseline, regular, "Test serialization must preserve production rendering")
            XCTAssertNotEqual(opticalControl, baseline,
                "Only opsz changes, with authored size and weight held fixed; table fallback: \(fallback)")
            if let fileRegular {
                XCTAssertEqual(regular, fileRegular, "Table fallback must preserve the extracted face's rendering")
            } else {
                fileRegular = regular
            }
        }
    }
    #endif

    func testPublishedFontScalePolicyAfterOneStep() async throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/runtime/font-scale-policy")
        struct Case: Decodable { let scale: Float; let expected: [String: Float] }
        struct Fixture: Decodable { let fontScalePath: String; let cases: [Case] }
        struct Provenance: Decodable { let fontSha256: String }
        let fixture = try JSONDecoder().decode(Fixture.self,
            from: Data(contentsOf: directory.appendingPathComponent("cases.json")))
        let provenance = try JSONDecoder().decode(Provenance.self,
            from: Data(contentsOf: directory.appendingPathComponent("provenance.json")))
        let scene = try Data(contentsOf: directory.appendingPathComponent("screen.riv"))
        let assets = try await NuxieNativeRuntime.inspectAssets(bytes: scene)
        let font = try XCTUnwrap(assets.first { $0.kind == .font })
        let fontBytes = try Data(contentsOf: directory.appendingPathComponent("\(provenance.fontSha256).otf"))
        let runtime = try await NuxieNativeRuntime.open(bytes: scene, artboardName: "Paywall",
            player: .defaultScene, pixelWidth: 390, pixelHeight: 844, bindDefaultViewModel: true,
            importMode: .configured(moduleName: "nuxie", expectedAssets: assets,
                externalAssets: [font.ordinal: fontBytes]))
        defer { Task { try? await runtime.close() } }
        let root = try await runtime.rootViewModelReference()
        var baselinePixels: Data?
        for (index, item) in fixture.cases.enumerated() {
            _ = try await runtime.mutateViewModel([
                .setNumber(instance: root, path: fixture.fontScalePath, value: item.scale)
            ])
            let step = try await runtime.step(elapsedSeconds: 0,
                textRunNames: ["bound Run", "fixed Run", "natural Run"])
            guard case .captured(let fields) = step.textGeometry else {
                return XCTFail("Expected same-frame text geometry: \(step.textGeometry)")
            }
            XCTAssertEqual(fields.count, 3)
            XCTAssertEqual(Set(fields.values.map(\.renderRevision)).count, 1)
            let snapshot = try await runtime.snapshot()
            for (name, expected) in item.expected {
                let value = try XCTUnwrap(snapshot.values.first {
                    $0.ownerInstanceID == snapshot.rootInstanceID && $0.name == name
                })
                guard case .number(let actual) = value.value else {
                    return XCTFail("Expected numeric metric: \(name)")
                }
                XCTAssertEqual(actual, expected, accuracy: 0.0001, "\(name) at scale \(item.scale)")
            }
            for name in ["bound Run", "fixed Run", "natural Run"] {
                let geometry = try XCTUnwrap(fields[name])
                let size: CGFloat = name == "fixed Run" ? 18 : 18 * CGFloat(item.scale)
                XCTAssertEqual(try XCTUnwrap(geometry.firstBaseline), 1929 / 2048 * size, accuracy: 0.001)
            }
            let frame = try await renderPixels(runtime, width: 390, height: 844)
            XCTAssertEqual(frame.outcome.disposition, .presented)
            if let baselinePixels {
                let fixedRange = (264 * 390 * 4)..<(484 * 390 * 4)
                XCTAssertEqual(frame.pixels.subdata(in: fixedRange), baselinePixels.subdata(in: fixedRange))
                if index == fixture.cases.count - 1 {
                    XCTAssertEqual(frame.pixels, baselinePixels, "Reset restores the original rendered frame")
                } else {
                    XCTAssertNotEqual(frame.pixels, baselinePixels, "System scaling changes rendered text")
                }
            } else { baselinePixels = frame.pixels }
        }
        try await runtime.close()
    }

    func testPublishedTextStyleMetricsReverseBindAfterOneStep() async throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/runtime/font-metrics-binding")
        let scene = try Data(contentsOf: directory.appendingPathComponent("screen.riv"))
        let assets = try await NuxieNativeRuntime.inspectAssets(bytes: scene)
        let font = try XCTUnwrap(assets.first { $0.kind == .font })
        let fontBytes = try Data(contentsOf: directory.appendingPathComponent(
            "2898476918b21c3f9b5ba22e86853c6d63b544f92da277a92533011a28c93af5.otf"))
        let runtime = try await NuxieNativeRuntime.open(bytes: scene, artboardName: "Paywall",
            player: .staticArtboard, pixelWidth: 390, pixelHeight: 844, bindDefaultViewModel: true,
            importMode: .configured(moduleName: "nuxie", expectedAssets: assets,
                externalAssets: [font.ordinal: fontBytes]))
        defer { Task { try? await runtime.close() } }
        struct Case: Decodable { let fontSize: Float; let lineHeight: Float }
        struct Field: Decodable {
            let runName: String
            let path: String
            let x: CGFloat; let y: CGFloat; let width: CGFloat; let height: CGFloat
        }
        struct Fixture: Decodable { let cases: [Case]; let geometry: [Field] }
        let fixture = try JSONDecoder().decode(Fixture.self,
            from: Data(contentsOf: directory.appendingPathComponent("expectations.json")))
        let root = try await runtime.rootViewModelReference()
        try await runtime.enableSemantics()
        var baselinePixels: Data?
        var firstGeometry: NuxieNativeTextRunGeometry?
        for (index, item) in fixture.cases.enumerated() {
            _ = try await runtime.mutateViewModel([
                .setNumber(instance: root, path: "requestedFontSize", value: item.fontSize),
                .setNumber(instance: root, path: "requestedLineHeight", value: item.lineHeight),
            ])
            let step = try await runtime.step(elapsedSeconds: 0,
                textRunNames: fixture.geometry.map(\.runName))
            guard case .captured(let fields) = step.textGeometry else {
                return XCTFail("Expected frame-qualified field geometry: \(step.textGeometry)")
            }
            XCTAssertEqual(fields.count, fixture.geometry.count)
            XCTAssertEqual(Set(fields.values.map(\.renderRevision)).count, 1)
            for (fieldIndex, expected) in fixture.geometry.enumerated() {
                let geometry = try XCTUnwrap(fields[expected.runName])
                XCTAssertGreaterThan(geometry.renderRevision, 0)
                let layout = try XCTUnwrap(geometry.layout)
                let box = layout.bounds.applying(layout.transform)
                XCTAssertEqual(box.minX, expected.x, accuracy: 0.001)
                XCTAssertEqual(box.minY, expected.y, accuracy: 0.001)
                XCTAssertEqual(box.width, expected.width, accuracy: 0.001)
                XCTAssertEqual(box.height, expected.height, accuracy: 0.001)
                XCTAssertEqual(geometry.worldTransform.tx, expected.x, accuracy: 0.001)
                // Production lowering preserves this authored first-line offset.
                XCTAssertEqual(geometry.worldTransform.ty, expected.y + 1.0458984, accuracy: 0.001)
                let fontSize = fieldIndex == 0 ? CGFloat(item.fontSize) : 18
                // The bundled font's independently rounded 2048-unit typo ascent.
                XCTAssertEqual(try XCTUnwrap(geometry.firstBaseline), CGFloat(1929) / 2048 * fontSize, accuracy: 0.001)
                if index == 0 && fieldIndex == 0 { firstGeometry = geometry }
            }
            let snapshot = try await runtime.snapshot()
            func number(_ path: String) throws -> Float {
                let segments = path.split(separator: "/").map(String.init)
                var owner = snapshot.rootInstanceID
                for name in segments.dropLast() {
                    let entry = try XCTUnwrap(snapshot.values.first { $0.ownerInstanceID == owner && $0.name == name })
                    guard case .referencedInstance(let child) = entry.value else {
                        throw NSError(domain: "FontMetricsFixture", code: 2)
                    }
                    owner = child
                }
                let entry = try XCTUnwrap(snapshot.values.first {
                    $0.ownerInstanceID == owner && $0.name == segments.last
                })
                guard case .number(let value) = entry.value else {
                    throw NSError(domain: "FontMetricsFixture", code: 1)
                }
                return value
            }
            XCTAssertEqual(try number("observedFontSize"), item.fontSize)
            XCTAssertEqual(try number("observedLineHeight"), item.lineHeight)
            XCTAssertEqual(try number("fixedFontSize"), 18)
            XCTAssertEqual(try number("fixedLineHeight"), 24)
            for (fieldIndex, field) in fixture.geometry.enumerated() {
                XCTAssertEqual(try number("\(field.path)/fontSize"), fieldIndex == 0 ? item.fontSize : 18)
                XCTAssertEqual(try number("\(field.path)/lineHeight"), fieldIndex == 0 ? item.lineHeight : 24)
            }
            let frame = try await renderPixels(runtime, width: 390, height: 844)
            XCTAssertEqual(frame.outcome.disposition, .presented)
            if index == 0 {
                let repeated = try await renderPixels(runtime, width: 390, height: 844)
                XCTAssertEqual(repeated.outcome.disposition, .presented)
                if frame.pixels != repeated.pixels {
                    try attachMetricPixels(frame.pixels, name: "unchanged-first")
                    try attachMetricPixels(repeated.pixels, name: "unchanged-second")
                }
                XCTAssertEqual(frame.pixels, repeated.pixels,
                    "An unchanged scene should retain its pixels across consecutive presentations")
            }
            let presented = try await runtime.captureSemantics()
            XCTAssertEqual(Set(fields.values.map(\.renderRevision)), [presented.tree.renderRevision],
                "Copied geometry must identify the exact presented revision")
            if let baselinePixels {
                // The fixed input begins at y=264; only the upper input is bound.
                let fixedRange = (264 * 390 * 4)..<frame.pixels.count
                if frame.pixels.subdata(in: fixedRange) != baselinePixels.subdata(in: fixedRange) ||
                    (index == fixture.cases.count - 1 && frame.pixels != baselinePixels) {
                    try attachMetricPixels(baselinePixels, name: "baseline-\(index)")
                    try attachMetricPixels(frame.pixels, name: "actual-\(index)")
                }
                XCTAssertEqual(frame.pixels.subdata(in: fixedRange), baselinePixels.subdata(in: fixedRange))
                if index == fixture.cases.count - 1 {
                    XCTAssertEqual(frame.pixels, baselinePixels, "Restoring authored metrics restores the rendered frame")
                } else {
                    XCTAssertNotEqual(frame.pixels, baselinePixels, "The bound style must change actual rendered text")
                }
            } else {
                baselinePixels = frame.pixels
            }
        }
        try await runtime.close()
        XCTAssertEqual(firstGeometry?.worldTransform.tx, 24,
            "Copied geometry survives later mutations, step-result frees and runtime close")
    }

    func testPresentedSemanticCaptureCopiesUnicodeAndRejectsRetiredCaptureActions() async throws {
        let prepared = try await NuxieNativePreparedFile.prepare(
            bytes: try fixture(named: "semantic_text", extension: "riv"), importMode: .portable)
        let artboards = try await prepared.artboards()
        let name = try XCTUnwrap(artboards.first).name
        let runtime = try await prepared.openSession(artboardName: name, player: .defaultScene,
            pixelWidth: 64, pixelHeight: 64)
        defer { Task { try? await runtime.close() } }
        try await runtime.enableSemantics()
        _ = try await runtime.step(elapsedSeconds: 0)
        do {
            _ = try await runtime.captureSemantics()
            XCTFail("An unpresented revision must not publish semantics")
        } catch NuxieNativeRuntimeError.callFailed(let diagnostic) {
            XCTAssertEqual(diagnostic.status, .handleMismatch)
        }
        let outcome = try await render(runtime)
        XCTAssertEqual(outcome.disposition, .presented)
        let first = try await runtime.captureSemantics(textRuns: ["field/名前", "missing"])
        XCTAssertEqual(first.tree.nodes.count, 1)
        let field = try XCTUnwrap(first.fieldsByTextRun["field/名前"])
        XCTAssertEqual(field.role, 6)
        XCTAssertEqual(field.label, "Prénom 👋")
        XCTAssertNil(field.parentID)
        XCTAssertNil(first.fieldsByTextRun["missing"])
        let unchanged = try await runtime.captureSemantics(textRuns: ["field/名前", "missing"])
        XCTAssertEqual(unchanged.tree.renderRevision, first.tree.renderRevision)
        XCTAssertEqual(unchanged.tree.treeVersion, first.tree.treeVersion)
        XCTAssertEqual(unchanged.id, first.id,
            "An unchanged presented capture must preserve queued UIKit action ownership")
        _ = try await runtime.step(elapsedSeconds: 0)
        _ = try await render(runtime)
        let nextFrame = try await runtime.captureSemantics(textRuns: ["field/名前", "missing"])
        XCTAssertNotEqual(nextFrame.tree.renderRevision, first.tree.renderRevision)
        XCTAssertEqual(nextFrame.tree.treeVersion, first.tree.treeVersion)
        XCTAssertEqual(nextFrame.id, first.id,
            "A fresh frame with unchanged semantics must preserve accepted UIKit intent")
        let second = try await runtime.captureSemantics()
        XCTAssertNotEqual(first.id, second.id)
        do {
            try await runtime.queueSemanticAction(captureID: first.id, nodeID: field.id, action: .tap)
            XCTFail("Replacing a capture must retire its action identity")
        } catch NuxieNativeRuntimeError.callFailed(let diagnostic) {
            XCTAssertEqual(diagnostic.status, .handleMismatch)
        }
        try await runtime.retireSemanticCapture()
        do {
            try await runtime.queueSemanticAction(captureID: second.id, nodeID: field.id, action: .tap)
            XCTFail("Retired captures must reject actions")
        } catch NuxieNativeRuntimeError.callFailed(let diagnostic) {
            XCTAssertEqual(diagnostic.status, .handleMismatch)
        }
        let fresh = try await runtime.captureSemantics()
        XCTAssertNotEqual(fresh.id, second.id,
            "Explicit retirement must never revive ownership even for an unchanged tree")
        try await runtime.close()
        XCTAssertEqual(first.tree.nodes.first?.label, "Prénom 👋")
    }

    func testSemanticTextWriteRequiresCurrentCapturedOwner() async throws {
        let prepared = try await NuxieNativePreparedFile.prepare(
            bytes: try fixture(named: "semantic_text", extension: "riv"), importMode: .portable)
        let artboards = try await prepared.artboards()
        let runtime = try await prepared.openSession(artboardName: XCTUnwrap(artboards.first).name,
            player: .defaultScene, pixelWidth: 64, pixelHeight: 64)
        defer { Task { try? await runtime.close() } }
        try await runtime.enableSemantics()
        _ = try await runtime.step(elapsedSeconds: 0)
        _ = try await render(runtime)
        let capture = try await runtime.captureSemantics(textRuns: ["field/名前"])
        let changed = try await runtime.setSemanticTextRun(captureID: capture.id, name: "field/名前", text: Data("Alice".utf8))
        XCTAssertTrue(changed)
        _ = try await runtime.step(elapsedSeconds: 0)
        do {
            _ = try await runtime.setSemanticTextRun(captureID: capture.id, name: "field/名前", text: Data("stale".utf8))
            XCTFail("A new runtime revision must reject the old presented editor capture")
        } catch NuxieNativeRuntimeError.callFailed(let diagnostic) {
            XCTAssertEqual(diagnostic.status, .handleMismatch)
        }
        _ = try await render(runtime)
        let replacement = try await runtime.captureSemantics(textRuns: ["field/名前"])
        let replacementChanged = try await runtime.setSemanticTextRun(captureID: replacement.id,
            name: "field/名前", text: Data("Bob".utf8))
        XCTAssertTrue(replacementChanged)
        try await runtime.retireSemanticCapture()
        do {
            _ = try await runtime.setSemanticTextRun(captureID: replacement.id, name: "field/名前", text: Data("late".utf8))
            XCTFail("Retired editor ownership must reject mutation")
        } catch NuxieNativeRuntimeError.callFailed(let diagnostic) {
            XCTAssertEqual(diagnostic.status, .handleMismatch)
        }
        let changedAfterRejection = try await runtime.setTextRuns([
            NuxieNativeTextRunMutation(name: "field/名前", text: Data("Bob".utf8))
        ])
        XCTAssertFalse(changedAfterRejection, "Rejected stale writes must leave the accepted native text intact")
        try await runtime.close()
    }

    func testSemanticTapExecutesAuthoredDropdownTransition() async throws {
        let prepared = try await NuxieNativePreparedFile.prepare(
            bytes: try fixture(named: "semantic_dropdown", extension: "riv"), importMode: .portable)
        let artboards = try await prepared.artboards()
        let name = try XCTUnwrap(artboards.first).name
        let runtime = try await prepared.openSession(artboardName: name, player: .defaultScene,
            pixelWidth: 64, pixelHeight: 64, bindDefaultViewModel: true)
        defer { Task { try? await runtime.close() } }
        try await runtime.enableSemantics()
        for _ in 0..<10 { _ = try await runtime.step(elapsedSeconds: 0.1) }
        let firstPresentation = try await render(runtime)
        XCTAssertEqual(firstPresentation.disposition, .presented)
        let before = try await runtime.captureSemantics()
        let button = try XCTUnwrap(before.tree.nodes.first { $0.label == "Select a fandom" })
        XCTAssertEqual(button.actions, 1)
        XCTAssertNotEqual(button.stateFlags & 1, 0, "Authored dropdown begins expanded")
        try await runtime.queueSemanticAction(captureID: before.id, nodeID: button.id, action: .tap)
        do {
            try await runtime.queueSemanticAction(captureID: before.id, nodeID: button.id, action: .tap)
            XCTFail("Accepted action must invalidate its presented capture")
        } catch NuxieNativeRuntimeError.callFailed(let diagnostic) {
            XCTAssertEqual(diagnostic.status, .handleMismatch)
        }
        for _ in 0..<10 { _ = try await runtime.step(elapsedSeconds: 0.1) }
        let nextPresentation = try await render(runtime)
        XCTAssertEqual(nextPresentation.disposition, .presented)
        let after = try await runtime.captureSemantics()
        let changed = try XCTUnwrap(after.tree.nodes.first { $0.id == button.id })
        XCTAssertEqual(changed.stateFlags & 1, 0, "Authored tap closes the dropdown after normal stepping")
        try await runtime.close()
    }

    func testPreparedFileOpensFreshIndependentRendererBoundSessions() async throws {
        let prepared = try await NuxieNativePreparedFile.prepare(
            bytes: try fixture(named: "data_binding_test", extension: "riv"),
            importMode: .portable
        )
        async let firstLoad = prepared.openSession(
            artboardName: "Artboard",
            player: .stateMachine("State Machine 1"),
            pixelWidth: 1,
            pixelHeight: 1,
            bindDefaultViewModel: true
        )
        async let secondLoad = prepared.openSession(
            artboardName: "Artboard",
            player: .stateMachine("State Machine 1"),
            pixelWidth: 1,
            pixelHeight: 1,
            bindDefaultViewModel: true
        )
        let (first, second) = try await (firstLoad, secondLoad)
        defer {
            Task {
                try? await first.close()
                try? await second.close()
            }
        }

        let firstRoot = try await first.rootViewModelReference()
        _ = try await first.mutateViewModel([
            .setNumber(instance: firstRoot, path: "Number", value: 91)
        ])
        let firstNumber = try await first.snapshot().values.first {
            $0.name == "Number"
        }?.value
        let secondNumber = try await second.snapshot().values.first {
            $0.name == "Number"
        }?.value
        XCTAssertEqual(firstNumber, .number(91))
        XCTAssertNotEqual(secondNumber, .number(91))

        try await first.close()
        let secondPlayerKind = try await second.playerInfo().kind
        XCTAssertEqual(secondPlayerKind, .stateMachine)
        let metrics = await prepared.metrics()
        XCTAssertEqual(metrics.fileImportCount, 3)
        XCTAssertEqual(metrics.openedSessionCount, 2)
    }

    func testPreparedFileFailedSessionDoesNotPoisonRePresentation() async throws {
        let prepared = try await NuxieNativePreparedFile.prepare(
            bytes: try fixture(named: "data_binding_test", extension: "riv")
        )
        do {
            _ = try await prepared.openSession(
                artboardName: "missing",
                player: .defaultScene,
                pixelWidth: 1,
                pixelHeight: 1
            )
            XCTFail("Expected the undeclared artboard to fail")
        } catch {}

        let first = try await prepared.openSession(
            artboardName: "Artboard",
            player: .stateMachine("State Machine 1"),
            pixelWidth: 1,
            pixelHeight: 1,
            bindDefaultViewModel: true
        )
        let root = try await first.rootViewModelReference()
        _ = try await first.mutateViewModel([
            .setNumber(instance: root, path: "Number", value: 77),
        ])
        try await first.close()

        let replacement = try await prepared.openSession(
            artboardName: "Artboard",
            player: .stateMachine("State Machine 1"),
            pixelWidth: 1,
            pixelHeight: 1,
            bindDefaultViewModel: true
        )
        defer { Task { try? await replacement.close() } }
        let replacementNumber = try await replacement.snapshot().values.first {
            $0.name == "Number"
        }?.value
        XCTAssertNotEqual(replacementNumber, .number(77))
        let metrics = await prepared.metrics()
        XCTAssertEqual(metrics.fileImportCount, 4)
        XCTAssertEqual(metrics.openedSessionCount, 2)
    }

    func testOneBatchCanAttachAndMutateADetachedViewModel() async throws {
        let runtime = try await NuxieNativeRuntime.open(
            bytes: try exactComponentListFixture(),
            artboardName: "Main",
            player: .staticArtboard,
            pixelWidth: 1,
            pixelHeight: 1,
            bindDefaultViewModel: true
        )
        defer { Task { try? await runtime.close() } }
        let root = try await runtime.rootViewModelReference()
        let child = try await runtime.makeViewModel(schemaIndex: 0)

        let result = try await runtime.mutateViewModel(
            [
                .listClear(instance: root, path: "items"),
                .listInsert(instance: root, path: "items", index: 0, value: child),
                .setNumber(
                    instance: child,
                    path: "value",
                    value: 42
                ),
            ],
            correlationID: 1
        )
        XCTAssertEqual(result.appliedCount, 3)
        XCTAssertEqual(result.changes.count, 3)
        let snapshot = try await runtime.snapshot()
        guard case .list(let rows) = snapshot.values.first(where: {
            $0.ownerInstanceID == snapshot.rootInstanceID && $0.name == "items"
        })?.value,
        let row = rows.first else { return XCTFail("Expected attached row") }
        XCTAssertEqual(snapshot.values.first(where: {
            $0.ownerInstanceID == row && $0.name == "value"
        })?.value, .number(42))
    }

    func testAbandonedDetachedViewModelCanBeReleased() async throws {
        let runtime = try await NuxieNativeRuntime.open(
            bytes: try fixture(named: "data_binding_test", extension: "riv"),
            artboardName: "Artboard",
            player: .stateMachine("State Machine 1"),
            pixelWidth: 1,
            pixelHeight: 1,
            bindDefaultViewModel: true
        )
        defer { Task { try? await runtime.close() } }
        let child = try await runtime.makeViewModel(schemaIndex: 1)
        try await runtime.releaseViewModels([child])

        do {
            _ = try await runtime.mutateViewModel([
                .setString(instance: child, path: "String", value: Data("late".utf8))
            ])
            XCTFail("Expected a released detached handle to be unavailable")
        } catch let error as NuxieNativeRuntimeError {
            XCTAssertEqual(error, .missingHandle("view model \(child.rawValue)"))
        }
    }
    func testExecutorPinsEveryOperationToOneDedicatedOSThread() async throws {
        let executor = NuxieRuntimePinnedThreadExecutor()
        let caller = UInt64(pthread_mach_thread_np(pthread_self()))

        async let first = executor.call {
            UInt64(pthread_mach_thread_np(pthread_self()))
        }
        async let second = executor.call {
            UInt64(pthread_mach_thread_np(pthread_self()))
        }
        let identities = try await [first, second]

        XCTAssertEqual(Set(identities).count, 1)
        XCTAssertNotEqual(identities[0], caller)
    }

    func testExecutorShutdownIsIdempotentAndRejectsNewWork() async {
        let executor = NuxieRuntimePinnedThreadExecutor()
        executor.shutdown()
        executor.shutdown()

        do {
            _ = try await executor.call { 1 }
            XCTFail("Expected a closed executor error")
        } catch {
            XCTAssertEqual(error as? NuxieRuntimeExecutorError, .closed)
        }
    }

    func testExecutorCanReleaseItsLastOwnerOnTheWorkerThread() async {
        let released = expectation(description: "executor released on its worker")
        let holder = RuntimeExecutorHolder(NuxieRuntimePinnedThreadExecutor())
        holder.withExecutor { executor in
            executor.enqueue {
                holder.clearExecutor()
                released.fulfill()
            }
        }

        await fulfillment(of: [released], timeout: 1)
        XCTAssertFalse(holder.hasExecutor)
    }

    func testFinalExecutorOperationShutsDownAfterThrowing() async {
        enum Expected: Error {
            case failure
        }

        let executor = NuxieRuntimePinnedThreadExecutor()
        do {
            try await executor.callThenShutdown {
                throw Expected.failure
            }
            XCTFail("Expected the final operation to throw")
        } catch Expected.failure {
            // The original native destruction error remains observable.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        do {
            _ = try await executor.call { 1 }
            XCTFail("Expected the executor to be closed after the failure")
        } catch {
            XCTAssertEqual(error as? NuxieRuntimeExecutorError, .closed)
        }
    }

    func testStaticFixtureRendersThroughSwiftNativeCWrappers() async throws {
        let runtime = try await NuxieNativeRuntime.open(
            bytes: try staticFixture(),
            artboardName: "Two",
            player: .staticArtboard,
            pixelWidth: 64,
            pixelHeight: 64
        )
        let artboards = try await runtime.artboards()
        let playerInfo = try await runtime.playerInfo()
        XCTAssertEqual(artboards.map(\.name), ["Two", "One"])
        XCTAssertEqual(playerInfo.kind, .staticArtboard)

        _ = try await runtime.step(elapsedSeconds: 0)
        let outcome = try await render(runtime)
        XCTAssertEqual(outcome.disposition, .presented)
        XCTAssertEqual(outcome.health, .healthy)
        XCTAssertGreaterThan(outcome.drawCalls, 0)

        try await runtime.close()
        try await runtime.close()
        XCTAssertEqual(artboards.map(\.name), ["Two", "One"])
    }

    func testRendererCompletionAndResizeStayOnTheNativeSeam() async throws {
        let runtime = try await NuxieNativeRuntime.open(
            bytes: try staticFixture(),
            artboardName: "Two",
            player: .staticArtboard,
            pixelWidth: 64,
            pixelHeight: 64
        )
        defer { Task { try? await runtime.close() } }
        let device = try await runtime.metalDevice()
        let firstLayer = makeLayer(device: device.value, width: 64, height: 64)
        let firstDrawable = try XCTUnwrap(firstLayer.nextDrawable())
        let firstCompletion = expectation(description: "first native frame completion")
        firstCompletion.expectedFulfillmentCount = 1

        let first = try await runtime.render(
            drawable: .available(NuxieNativeDrawable(firstDrawable)),
            completion: { firstCompletion.fulfill() }
        )
        XCTAssertEqual(first.disposition, .presented)
        await fulfillment(of: [firstCompletion], timeout: 1)

        let resized = try await runtime.resize(
            pixelWidth: 64,
            pixelHeight: 64
        )
        XCTAssertEqual(resized.disposition, .reconfigured)

        let secondLayer = makeLayer(device: device.value, width: 64, height: 64)
        let secondDrawable = try XCTUnwrap(secondLayer.nextDrawable())
        let secondCompletion = expectation(description: "reattached native frame completion")
        let second = try await runtime.render(
            drawable: .available(NuxieNativeDrawable(secondDrawable)),
            completion: { secondCompletion.fulfill() }
        )
        XCTAssertEqual(second.disposition, .presented)
        await fulfillment(of: [secondCompletion], timeout: 1)

        try await runtime.close()
        let rejectedCompletion = expectation(description: "rejected frame completion")
        do {
            _ = try await runtime.render(
                drawable: .timeout,
                completion: { rejectedCompletion.fulfill() }
            )
            XCTFail("Expected a closed runtime")
        } catch {
            XCTAssertEqual(error as? NuxieNativeRuntimeError, .closed)
        }
        await fulfillment(of: [rejectedCompletion], timeout: 1)
    }

    func testStateMachineDataBindingCopiesOwnedResultsBeforeClose() async throws {
        let runtime = try await NuxieNativeRuntime.open(
            bytes: try fixture(named: "data_binding_test", extension: "riv"),
            artboardName: "Artboard",
            player: .stateMachine("State Machine 1"),
            pixelWidth: 64,
            pixelHeight: 64,
            bindDefaultViewModel: true
        )
        let catalog = try await runtime.viewModelCatalog()
        let testSchema = try XCTUnwrap(catalog.schemas.first { $0.name == "Test" })
        XCTAssertTrue(
            catalog.properties[testSchema.propertyRange].contains {
                $0.name == "Number" && $0.kind == .number
            }
        )
        let mutation = try await runtime.setNumber(42, path: "Number", correlationID: 77)
        XCTAssertEqual(mutation.appliedCount, 1)
        XCTAssertEqual(mutation.correlationID, 77)
        XCTAssertEqual(mutation.changes.count, 1)
        XCTAssertEqual(mutation.changes.first?.origin, .caller)
        XCTAssertEqual(mutation.changes.first?.value, .number(42))

        let snapshot = try await runtime.snapshot()
        XCTAssertEqual(
            snapshot.values.first(where: { $0.name == "Number" })?.value,
            .number(42)
        )
        let step = try await runtime.step(elapsedSeconds: 0.016, correlationID: 78)
        let outcome = try await render(runtime)
        XCTAssertFalse(step.events.contains { $0.name.isEmpty && !$0.properties.isEmpty })
        XCTAssertEqual(outcome.disposition, .presented)

        try await runtime.close()
        XCTAssertEqual(
            snapshot.values.first(where: { $0.name == "Number" })?.name,
            "Number"
        )
        XCTAssertEqual(mutation.changes.first?.correlationID, 77)
        XCTAssertEqual(catalog.schemas.first { $0.name == "Test" }?.name, "Test")
    }

    func testViewModelBatchSupportsScalarTriggerAndReferenceMutationsAtomically() async throws {
        let runtime = try await NuxieNativeRuntime.open(
            bytes: try fixture(named: "data_binding_test", extension: "riv"),
            artboardName: "Artboard",
            player: .stateMachine("State Machine 1"),
            pixelWidth: 64,
            pixelHeight: 64,
            bindDefaultViewModel: true
        )
        defer { Task { try? await runtime.close() } }

        let root = try await runtime.rootViewModelReference()
        let nested = try await runtime.makeViewModel(
            schemaIndex: 1,
            authoredInstanceIndex: 0
        )
        let result = try await runtime.mutateViewModel(
            [
                .setString(instance: root, path: "String", value: Data("swift".utf8)),
                .setNumber(instance: root, path: "Number", value: 23),
                .setBool(instance: root, path: "Boolean", value: true),
                .setColor(instance: root, path: "Color", value: 0xFF11_2233),
                .setEnumeration(instance: root, path: "Enum", value: 1),
                .fireTrigger(instance: root, path: "Trigger Blue"),
                .setViewModel(instance: root, path: "Nested", value: nested),
            ],
            correlationID: 99
        )
        XCTAssertEqual(result.appliedCount, 7)
        XCTAssertEqual(result.correlationID, 99)
        XCTAssertEqual(result.changes.count, 7)
        XCTAssertTrue(result.changes.allSatisfy { $0.origin == .caller && $0.correlationID == 99 })

        let snapshot = try await runtime.snapshot()
        let rootValues = snapshot.values.filter { $0.ownerInstanceID == root.rawValue }
        XCTAssertEqual(rootValues.first { $0.name == "String" }?.value, .bytes(Data("swift".utf8)))
        XCTAssertEqual(rootValues.first { $0.name == "Number" }?.value, .number(23))
        XCTAssertEqual(rootValues.first { $0.name == "Boolean" }?.value, .bool(true))
        XCTAssertEqual(rootValues.first { $0.name == "Color" }?.value, .integer(0xFF11_2233))
        XCTAssertEqual(rootValues.first { $0.name == "Enum" }?.value, .integer(1))
        XCTAssertTrue(result.changes.contains {
            $0.value == .referencedInstance(nested.rawValue)
        })
        guard case .referencedInstance(let linked) = rootValues.first(where: {
            $0.name == "Nested"
        })?.value else {
            return XCTFail("Expected the committed reference snapshot")
        }
        XCTAssertEqual(
            snapshot.instances.first(where: { $0.id == linked })?.schemaIndex,
            1
        )
    }

    func testDetachedViewModelCanBeHydratedBeforeStructuralCommit() async throws {
        let runtime = try await NuxieNativeRuntime.open(
            bytes: try fixture(named: "data_binding_test", extension: "riv"),
            artboardName: "Artboard",
            player: .stateMachine("State Machine 1"),
            pixelWidth: 64,
            pixelHeight: 64,
            bindDefaultViewModel: true
        )
        defer { Task { try? await runtime.close() } }
        let root = try await runtime.rootViewModelReference()
        let nested = try await runtime.makeViewModel(
            schemaIndex: 1,
            authoredInstanceIndex: nil
        )
        _ = try await runtime.mutateViewModel(
            [.setString(instance: nested, path: "String", value: Data("child".utf8))],
            correlationID: 1
        )
        _ = try await runtime.mutateViewModel(
            [.setViewModel(instance: root, path: "Nested", value: nested)],
            correlationID: 2
        )
        let snapshot = try await runtime.snapshot()
        let rootValues = snapshot.values.filter { $0.ownerInstanceID == root.rawValue }
        guard case .referencedInstance(let linked) = rootValues.first(where: {
            $0.name == "Nested"
        })?.value else { return XCTFail("Expected linked child") }
        XCTAssertEqual(snapshot.values.first(where: {
            $0.ownerInstanceID == linked && $0.name == "String"
        })?.value, .bytes(Data("child".utf8)))
    }

    func testMountedSelectedProductReferenceSwitchesLiveValues() async throws {
        let runtime = try await NuxieNativeRuntime.open(
            bytes: try fixture(named: "data_binding_test", extension: "riv"),
            artboardName: "Artboard",
            player: .stateMachine("State Machine 1"),
            pixelWidth: 64,
            pixelHeight: 64,
            bindDefaultViewModel: true
        )
        defer { Task { try? await runtime.close() } }
        let paywall = try await runtime.rootViewModelReference()
        let monthly = try await runtime.makeViewModel(
            schemaIndex: 1,
            authoredInstanceIndex: nil
        )
        let annual = try await runtime.makeViewModel(
            schemaIndex: 1,
            authoredInstanceIndex: nil
        )
        _ = try await runtime.mutateViewModel([
            .setString(
                instance: monthly,
                path: "String",
                value: Data("$0.00 trial".utf8)
            ),
            .setString(
                instance: annual,
                path: "String",
                value: Data("$1.99 for 3 months".utf8)
            ),
            .setViewModel(instance: paywall, path: "Nested", value: monthly),
        ])
        var snapshot = try await runtime.snapshot()
        var selected = try XCTUnwrap(snapshot.values.first {
            $0.ownerInstanceID == paywall.rawValue && $0.name == "Nested"
        })
        guard case .referencedInstance(let monthlyID) = selected.value else {
            return XCTFail("Expected the mounted paywall to reference monthly")
        }
        XCTAssertEqual(snapshot.values.first {
            $0.ownerInstanceID == monthlyID && $0.name == "String"
        }?.value, .bytes(Data("$0.00 trial".utf8)))

        let switched = try await runtime.mutateViewModel([
            .setViewModel(instance: paywall, path: "Nested", value: annual),
        ])
        XCTAssertEqual(switched.appliedCount, 1)
        snapshot = try await runtime.snapshot()
        selected = try XCTUnwrap(snapshot.values.first {
            $0.ownerInstanceID == paywall.rawValue && $0.name == "Nested"
        })
        guard case .referencedInstance(let annualID) = selected.value else {
            return XCTFail("Expected the mounted paywall to reference annual")
        }
        XCTAssertEqual(snapshot.values.first {
            $0.ownerInstanceID == annualID && $0.name == "String"
        }?.value, .bytes(Data("$1.99 for 3 months".utf8)))
    }

    func testRejectedViewModelBatchRollsBackItsValidPrefix() async throws {
        let runtime = try await NuxieNativeRuntime.open(
            bytes: try fixture(named: "data_binding_test", extension: "riv"),
            artboardName: "Artboard",
            player: .stateMachine("State Machine 1"),
            pixelWidth: 64,
            pixelHeight: 64,
            bindDefaultViewModel: true
        )
        defer { Task { try? await runtime.close() } }

        let root = try await runtime.rootViewModelReference()
        let before = try await runtime.snapshot().values.first { $0.name == "Number" }?.value
        do {
            _ = try await runtime.mutateViewModel(
                [
                    .setNumber(instance: root, path: "Number", value: 91),
                    .setNumber(instance: root, path: "missing", value: 12),
                ],
                correlationID: 100
            )
            XCTFail("Expected the invalid batch to fail")
        } catch {
            // The native transaction publishes the error and rolls back.
        }
        let after = try await runtime.snapshot().values.first { $0.name == "Number" }?.value
        XCTAssertEqual(after, before)
    }

    func testGeneratedInputCommitUsesExistingViewModelBatchAndListener() async throws {
        let fixtureDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/runtime/scripted-input")
        let bytes = try Data(contentsOf: fixtureDirectory.appendingPathComponent("screen.riv"))
        let assets = try await NuxieNativeRuntime.inspectAssets(bytes: bytes)
        let runtime = try await NuxieNativeRuntime.open(
            bytes: bytes, artboardName: "Paywall",
            player: .defaultSceneWithInputStateMachine("Generated Nuxie Pressable Interaction"),
            pixelWidth: 390, pixelHeight: 844, bindDefaultViewModel: true,
            importMode: .configured(moduleName: "nuxie", expectedAssets: assets, externalAssets: [:])
        )
        defer { Task { try? await runtime.close() } }
        let root = try await runtime.rootViewModelReference()
        func value(_ control: String) async throws -> Data {
            let snapshot = try await runtime.snapshot()
            func child(_ owner: UInt64, _ name: String) throws -> UInt64 {
                guard case .referencedInstance(let id) = snapshot.values.first(where: {
                    $0.ownerInstanceID == owner && $0.name == name
                })?.value else { throw ScriptedInputFixtureError.missingValue }
                return id
            }
            let controls = try child(root.rawValue, "controls")
            let input = try child(controls, control)
            guard case .bytes(let value) = snapshot.values.first(where: {
                $0.ownerInstanceID == input && $0.name == "value"
            })?.value else { throw ScriptedInputFixtureError.missingValue }
            return value
        }
        _ = try await runtime.step(elapsedSeconds: 0)
        for text in ["Evening ease", "", "静かな夜", "静かな夜"] {
            _ = try await runtime.mutateViewModel([
                .setString(instance: root, path: "controls/cta/value", value: Data(text.utf8)),
            ])
            _ = try await runtime.step(elapsedSeconds: 0)
            let edited = try await value("cta")
            XCTAssertEqual(edited, Data(text.utf8), "Editing alone must not submit")
            _ = try await runtime.mutateViewModel([
                .setString(instance: root, path: "controls/cta/value", value: Data(text.utf8)),
                .fireTrigger(instance: root, path: "controls/cta/commit"),
            ])
            let afterMutation = try await value("cta")
            _ = try await runtime.step(elapsedSeconds: 0)
            let committed = try await value("cta")
            XCTAssertEqual(String(decoding: committed, as: UTF8.self), "committed:\(text)",
                "after mutation: \(String(decoding: afterMutation, as: UTF8.self))")
            _ = try await runtime.step(elapsedSeconds: 0)
            let settled = try await value("cta")
            let other = try await value("second-input")
            XCTAssertEqual(settled, committed, "An advance must not replay the commit")
            XCTAssertEqual(other, Data("untouched".utf8))
        }
    }

    private enum ScriptedInputFixtureError: Error { case missingValue }

    func testTrustedScriptedFixtureReturnsGenericCommandsInAuthoredOrder() async throws {
        let scene = try descriptorSceneFixture()
        let catalog = try await NuxieNativeRuntime.inspectAssets(bytes: scene)
        XCTAssertEqual(catalog.map(\.kind), [.script])
        let runtime = try await NuxieNativeRuntime.open(
            bytes: scene,
            artboardName: "Paywall",
            player: .defaultSceneWithInputStateMachine(
                "Generated Nuxie Pressable Interaction"
            ),
            pixelWidth: 64,
            pixelHeight: 64,
            importMode: .configured(
                moduleName: "nuxie",
                expectedAssets: catalog,
                externalAssets: [:]
            )
        )
        defer { Task { try? await runtime.close() } }

        let authoredStateMachineCount = try await runtime.artboards().first?.stateMachines.count ?? 0
        XCTAssertGreaterThan(
            authoredStateMachineCount,
            1,
            "the compiler contract keeps visual and interaction machines distinct"
        )
        let primaryPlayerName = try await runtime.playerInfo().name
        XCTAssertNotEqual(
            primaryPlayerName,
            "Generated Nuxie Pressable Interaction",
            "the authored/default scene remains the rendered primary player"
        )

        _ = try await render(runtime)
        _ = try await runtime.step(elapsedSeconds: 0.016)
        let result = try await runtime.step(
            pointers: [
                NuxieNativePointerEvent(kind: .down, x: 100, y: 728, pointerID: 1),
                NuxieNativePointerEvent(kind: .up, x: 100, y: 728, pointerID: 1),
            ],
            elapsedSeconds: 0.016,
            correlationID: 42,
            textRunNames: ["missing geometry run"]
        )
        guard case .failed(.callFailed(let diagnostic)) = result.textGeometry else {
            return XCTFail("A missing geometry run must report capture failure without losing commands")
        }
        XCTAssertEqual(diagnostic.status, .notFound)

        XCTAssertEqual(
            result.hostCommands.map(\.name),
            [
                "$response_set",
                "purchase_tapped",
                "selection_changed",
                "custom.analytics",
                "$response_set",
            ]
        )
        guard result.hostCommands.count == 5 else {
            return XCTFail("Expected five generic commands, got \(result.hostCommands.count)")
        }
        guard case .object(let validResponse) = result.hostCommands[0].value,
              case .string("plan") = validResponse.first(where: { $0.key == "field" })?.value,
              case .string("pro") = validResponse.first(where: { $0.key == "value" })?.value,
              case .object(let invalidResponse) = result.hostCommands[4].value,
              case .number(42) = invalidResponse.first(where: { $0.key == "field" })?.value else {
            return XCTFail("Expected the exact structured response command trees")
        }
    }

    func testCompositePlayerRoutesNamedInputOnlyToAuxiliaryOwner() async throws {
        let inputs: [NuxieNativePlayerInput] = [.trigger(name: "interaction")]

        XCTAssertEqual(
            nuxieNativeInputs(inputs, forPlayerAt: 0, playerCount: 2),
            []
        )
        XCTAssertEqual(
            nuxieNativeInputs(inputs, forPlayerAt: 1, playerCount: 2),
            inputs
        )
        XCTAssertEqual(
            nuxieNativeInputs(inputs, forPlayerAt: 0, playerCount: 1),
            inputs
        )
    }

    func testConfiguredImportDecodesAnEmbeddedImageAgainstItsInspectedCatalog() async throws {
        let encoded = try fixture(named: "in_band_asset", extension: "riv.base64")
        guard let scene = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let catalog = try await NuxieNativeRuntime.inspectAssets(bytes: scene)
        XCTAssertEqual(catalog.count, 1)
        XCTAssertEqual(catalog.first?.kind, .image)
        XCTAssertEqual(catalog.first?.isEmbedded, true)

        let runtime = try await NuxieNativeRuntime.open(
            bytes: scene,
            artboardName: "New Artboard",
            player: .staticArtboard,
            pixelWidth: 16,
            pixelHeight: 16,
            importMode: .configured(
                moduleName: "nuxie",
                expectedAssets: catalog,
                externalAssets: [:]
            )
        )
        defer { Task { try? await runtime.close() } }
        let player = try await runtime.playerInfo()
        XCTAssertEqual(player.kind, .staticArtboard)
    }

    func testInlineBoundTextRunAcceptsEmptyAndLongProductValues() async throws {
        let scene = try fixture(named: "inline_text_data_binding", extension: "riv")
        let catalog = try await NuxieNativeRuntime.inspectAssets(bytes: scene)
        let font = try XCTUnwrap(catalog.first(where: { $0.kind == .font }))
        let testsDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fontBytes = try Data(contentsOf: testsDirectory.appendingPathComponent(
            "ExperienceRuntimeHostApp/Fixtures/font-converter/assets/sha256/" +
                "b481b059ee94961c7b18585a596935aaa7cc44b68879c096d2cd06922e0431b1.ttf"
        ))
        let runtime = try await NuxieNativeRuntime.open(
            bytes: scene,
            artboardName: "Inline text",
            player: .staticArtboard,
            pixelWidth: 320,
            pixelHeight: 160,
            bindDefaultViewModel: true,
            importMode: .configured(
                moduleName: "nuxie",
                expectedAssets: catalog,
                externalAssets: [font.ordinal: fontBytes]
            )
        )
        defer { Task { try? await runtime.close() } }

        let initialSnapshot = try await runtime.snapshot()
        let selectedProduct = try XCTUnwrap(initialSnapshot.values.first {
            $0.name == "selectedProductId"
        })
        let root = try await runtime.rootViewModelReference()
        XCTAssertEqual(
            selectedProduct.value,
            .bytes(Data("draft:before".utf8))
        )
        let preview = try await runtime.mutateViewModel([
            .setString(
                instance: root,
                path: "paywall/selectedProductId",
                value: Data("before".utf8)
            )
        ])
        XCTAssertEqual(preview.appliedCount, 1)
        _ = try await runtime.step(elapsedSeconds: 0)
        let initialRender = try await renderPixels(runtime, width: 320, height: 160)
        XCTAssertEqual(initialRender.outcome.disposition, .presented)

        let empty = try await runtime.mutateViewModel([
            .setString(
                instance: root,
                path: "paywall/selectedProductId",
                value: Data()
            )
        ])
        XCTAssertEqual(empty.appliedCount, 1)
        _ = try await runtime.step(elapsedSeconds: 0)
        let emptySnapshot = try await runtime.snapshot()
        XCTAssertEqual(
            emptySnapshot.values.first {
                $0.name == "selectedProductId"
            }?.value,
            .bytes(Data())
        )
        let emptyRender = try await renderPixels(runtime, width: 320, height: 160)
        XCTAssertEqual(emptyRender.outcome.disposition, .presented)
        XCTAssertGreaterThan(emptyRender.outcome.drawCalls, 0)
        XCTAssertNotEqual(emptyRender.pixels, initialRender.pixels)
        let removedRunDifference = changedPixelExtent(
            between: initialRender.pixels,
            and: emptyRender.pixels,
            width: 320
        )
        XCTAssertGreaterThan(
            removedRunDifference.pixelCount,
            0,
            "Removing the bound run must change the rendered line"
        )

        let restored = try await runtime.mutateViewModel([
            .setString(
                instance: root,
                path: "paywall/selectedProductId",
                value: Data("before".utf8)
            )
        ])
        XCTAssertEqual(restored.appliedCount, 1)
        _ = try await runtime.step(elapsedSeconds: 0)
        let restoredRender = try await renderPixels(runtime, width: 320, height: 160)
        let restoredDifference = changedPixelExtent(
            between: restoredRender.pixels,
            and: initialRender.pixels,
            width: 320
        )
        XCTAssertLessThan(
            restoredDifference.pixelCount,
            removedRunDifference.pixelCount / 2,
            "Restoring the bound run must at least halve the visual distance to the original line"
        )

        let longLocalizedValue =
            "votre période d’essai gratuite de quatre-vingt-dix jours avec toutes les fonctionnalités"
        let long = try await runtime.mutateViewModel([
            .setString(
                instance: root,
                path: "paywall/selectedProductId",
                value: Data(longLocalizedValue.utf8)
            )
        ])
        XCTAssertEqual(long.appliedCount, 1)
        _ = try await runtime.step(elapsedSeconds: 0)
        let longSnapshot = try await runtime.snapshot()
        XCTAssertEqual(
            longSnapshot.values.first {
                $0.name == "selectedProductId"
            }?.value,
            .bytes(Data(longLocalizedValue.utf8))
        )
        let rendered = try await renderPixels(runtime, width: 320, height: 160)
        XCTAssertEqual(rendered.outcome.disposition, .presented)
        XCTAssertGreaterThan(rendered.outcome.drawCalls, 0)
        XCTAssertNotEqual(rendered.pixels, initialRender.pixels)
        XCTAssertNotEqual(rendered.pixels, emptyRender.pixels)
        let longRunDifference = changedPixelExtent(
            between: rendered.pixels,
            and: emptyRender.pixels,
            width: 320
        )
        XCTAssertGreaterThan(
            longRunDifference.pixelCount,
            removedRunDifference.pixelCount,
            "A long localized value must affect more of the rendered line"
        )
        XCTAssertGreaterThan(
            longRunDifference.rowSpan,
            removedRunDifference.rowSpan,
            "A long localized value must wrap onto additional rendered rows"
        )
    }

    func testTextRunBatchRollsBackItsValidPrefix() async throws {
        let encoded = try fixture(named: "text_run_apple_seam", extension: "riv.base64")
        guard let scene = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let runtime = try await NuxieNativeRuntime.open(
            bytes: scene,
            artboardName: "Root",
            player: .staticArtboard,
            pixelWidth: 16,
            pixelHeight: 16
        )
        defer { Task { try? await runtime.close() } }

        let initiallyChanged = try await runtime.setTextRuns([
            NuxieNativeTextRunMutation(name: "headline", text: Data("accepted".utf8))
        ])
        XCTAssertTrue(initiallyChanged)
        do {
            _ = try await runtime.setTextRuns([
                NuxieNativeTextRunMutation(name: "headline", text: Data("leaked".utf8)),
                NuxieNativeTextRunMutation(name: "missing", text: Data("invalid".utf8)),
            ])
            XCTFail("Expected an unknown run to reject the batch")
        } catch {
            // The native text transaction rejects the whole batch.
        }
        let changedAfterFailure = try await runtime.setTextRuns([
            NuxieNativeTextRunMutation(name: "headline", text: Data("accepted".utf8))
        ])
        XCTAssertFalse(changedAfterFailure)
    }

    func testActorUsesOneNoncallerThreadAndRejectsCallsAfterClose() async throws {
        let runtime = try await NuxieNativeRuntime.open(
            bytes: try staticFixture(),
            artboardName: "Two",
            player: .staticArtboard,
            pixelWidth: 16,
            pixelHeight: 16
        )
        let caller = UInt64(pthread_mach_thread_np(pthread_self()))
        async let first = runtime.executorThreadIdentity()
        async let second = runtime.executorThreadIdentity()
        let identities = try await [first, second]
        XCTAssertEqual(Set(identities).count, 1)
        XCTAssertNotEqual(identities[0], caller)

        try await runtime.close()
        do {
            _ = try await runtime.playerInfo()
            XCTFail("Expected closed runtime")
        } catch {
            XCTAssertEqual(error as? NuxieNativeRuntimeError, .closed)
        }
    }

    func testActorDeinitDoesNotRetainItself() async throws {
        weak var weakRuntime: NuxieNativeRuntime?
        do {
            var runtime: NuxieNativeRuntime? = try await NuxieNativeRuntime.open(
                bytes: try staticFixture(),
                artboardName: "Two",
                player: .staticArtboard,
                pixelWidth: 16,
                pixelHeight: 16
            )
            weakRuntime = runtime
            runtime = nil
        }
        for _ in 0..<20 where weakRuntime != nil {
            await Task.yield()
        }
        XCTAssertNil(weakRuntime)
    }

    private func render(_ runtime: NuxieNativeRuntime) async throws
        -> NuxieNativeRendererOutcome
    {
        let device = try await runtime.metalDevice()
        let layer = CAMetalLayer()
        layer.device = device.value
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.drawableSize = CGSize(width: 64, height: 64)
        layer.maximumDrawableCount = 2
        layer.allowsNextDrawableTimeout = true
        guard let drawable = layer.nextDrawable() else {
            throw XCTSkip("This host cannot vend a CAMetalDrawable")
        }
        return try await runtime.render(
            drawable: .available(NuxieNativeDrawable(drawable)),
            clearColor: 0xFF11_2233
        )
    }

    private func attachMetricPixels(_ pixels: Data, name: String) throws {
        let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
        let image = try XCTUnwrap(CGImage(width: 390, height: 844, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 390 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let bytes = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let attachment = XCTAttachment(data: bytes as Data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func renderPixels(
        _ runtime: NuxieNativeRuntime,
        width: Int,
        height: Int
    ) async throws -> (
        outcome: NuxieNativeRendererOutcome,
        pixels: Data
    ) {
        let device = try await runtime.metalDevice().value
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false
        layer.drawableSize = CGSize(width: width, height: height)
        layer.maximumDrawableCount = 2
        layer.allowsNextDrawableTimeout = true
        guard let drawable = layer.nextDrawable() else {
            throw XCTSkip("This host cannot vend a CAMetalDrawable")
        }
        let bytesPerPixel = 4
        let bytesPerRow = (width * bytesPerPixel + 255) & ~255
        let buffer = try XCTUnwrap(device.makeBuffer(
            length: bytesPerRow * height,
            options: .storageModeShared
        ), "Allocate shared storage for the submitted frame")
        let readback = NuxieNativeFrameReadback(buffer: buffer, bytesPerRow: bytesPerRow)
        let completion = expectation(description: "native text frame completion")
        let outcome = try await runtime.render(
            drawable: .available(NuxieNativeDrawable(drawable)),
            clearColor: 0xFF11_2233,
            readback: readback,
            completion: { completion.fulfill() }
        )
        await fulfillment(of: [completion], timeout: 2)

        let source = buffer.contents().assumingMemoryBound(to: UInt8.self)
        var pixels = Data(capacity: width * height * bytesPerPixel)
        for row in 0..<height {
            pixels.append(source + row * bytesPerRow, count: width * bytesPerPixel)
        }
        return (outcome, pixels)
    }

    private func changedPixelExtent(
        between first: Data,
        and second: Data,
        width: Int
    ) -> (pixelCount: Int, rowSpan: Int) {
        precondition(first.count == second.count)
        let bytesPerPixel = 4
        var pixelCount = 0
        var minimumY = first.count / (width * bytesPerPixel)
        var maximumY = -1
        first.withUnsafeBytes { firstBuffer in
            second.withUnsafeBytes { secondBuffer in
                let firstBytes = firstBuffer.bindMemory(to: UInt8.self)
                let secondBytes = secondBuffer.bindMemory(to: UInt8.self)
                for offset in stride(from: 0, to: firstBytes.count, by: bytesPerPixel) {
                    guard !firstBytes[offset..<(offset + bytesPerPixel)]
                        .elementsEqual(secondBytes[offset..<(offset + bytesPerPixel)]) else {
                        continue
                    }
                    let pixelIndex = offset / bytesPerPixel
                    let y = pixelIndex / width
                    pixelCount += 1
                    minimumY = min(minimumY, y)
                    maximumY = max(maximumY, y)
                }
            }
        }
        let rowSpan = maximumY >= minimumY ? maximumY - minimumY + 1 : 0
        return (pixelCount, rowSpan)
    }

    private func makeLayer(
        device: any MTLDevice,
        width: Int,
        height: Int
    ) -> CAMetalLayer {
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.drawableSize = CGSize(width: width, height: height)
        layer.maximumDrawableCount = 2
        layer.allowsNextDrawableTimeout = true
        return layer
    }

    private func staticFixture() throws -> Data {
        let encoded = try fixture(named: "nuxie_runtime_two_artboards", extension: "riv.base64")
        guard let decoded = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return decoded
    }

    private func descriptorSceneFixture() throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Fixtures/scripted-generic-commands/renders/sha256/8b0d173101d37e5ac152344a6ab40805897fd1c193d7400f119e231f56e36b07.riv"
            )
        return try Data(contentsOf: url)
    }

    private func fixture(named name: String, extension fileExtension: String) throws -> Data {
        let testBundle = Bundle(for: Self.self)
        if let url = testBundle.url(
            forResource: name,
            withExtension: fileExtension
        ) {
            return try Data(contentsOf: url)
        }

        // SwiftPM puts processed test resources in a sibling bundle, while
        // Xcode copies them into the XCTest bundle itself. Search only those
        // immediate sibling bundles so this remains deterministic.
        let siblings = try FileManager.default.contentsOfDirectory(
            at: testBundle.bundleURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )
        for sibling in siblings where sibling.pathExtension == "bundle" {
            if let url = Bundle(url: sibling)?.url(
                forResource: name,
                withExtension: fileExtension
            ) {
                return try Data(contentsOf: url)
            }
        }
        throw CocoaError(.fileNoSuchFile)
    }
}

/// Small exact-upstream fixture with a `Doc.items` list and a matching
/// `ItemVM` row artboard. The prior `data_binding_test.riv` list coverage was
/// invalid because that file has no artboard for its `Nested` schema.
func exactComponentListFixture() throws -> Data {
    let encoded =
        "UklWRQcCAMQB7gPzA4QEhgSlBKYEqgStBLYEvwTHBMoEzATVBNYE3gTfBOAE7QTuBO8E8ATyBI8FkAXSBgCgAAAAAgAAACEAAAAEAAAAAAAAAAAAAAAAAAAAFwCzA60EBkl0ZW1WTQCvA60EBXZhbHVlALUDtgQABAJJMQC6A78EAACAP6oEAAC1A7YEAAQCSTIAugO/BAAAAECqBAAAtQO2BAAEAkkzALoDvwQAAEBAqgQAALUDtgQABAJJNAC6A78EAACAQKoEAAC1A7YEAAQCSTUAugO/BAAAoECqBAAAtQO2BAAEAkk2ALoDvwQAAMBAqgQAALMDrQQDRG9jALIDrQQFaXRlbXMAtQO2BAEECEluc3RhbmNlALkDqgQAAKsDpQQApgQAAKsDpQQApgQBAKsDpQQApgQCAKsDpQQApgQDAKsDpQQApgQEAKsDpQQApgQFAAHHBAHEAQEHAADIQwgAAMhD7gMDBARNYWluABQECkJhY2tncm91bmQFAAASJRAQEP8EBUNvbG9yBQEApAMEDkFydGJvYXJkIFN0eWxlBQAAmQMHAADIQwgAACBC7gMHBAdPdmVybGF5BQAAFAQLT3ZlcmxheUZpbGwFBAASJf8AAP8EBUNvbG9yBQUApAPVBALtBAHuBAHwBAEEDU92ZXJsYXkgU3R5bGUFBACZA8QBAQcAAEhDCAAASEPuAwkECFZpZXdwb3J0BQAApAOEBAAAyEKGBAAAyELVBALtBAHvBAEEDlZpZXdwb3J0IFN0eWxlBQgAmQMHAABIQwgAAEhD7gMLBAdDb250ZW50BQgApAPzAwAAIEGPBQGQBQLWBADeBAHfBAPgBAPyBAEEDUNvbnRlbnQgU3R5bGUFCgCvBAQETGlzdAUKAL8DzAQCAQDKBKAGAIkE0gYBBAZTY3JvbGwFCgABxAEAxwQABwAASEMIAABIQu4DAwQESXRlbQAUBAhJdGVtRmlsbAUAABIlAP8A/wQFQ29sb3IFAQCkAwQKSXRlbSBTdHlsZQUAAA=="
    guard let decoded = Data(base64Encoded: encoded) else {
        throw CocoaError(.fileReadCorruptFile)
    }
    return decoded
}

private final class RuntimeExecutorHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var executor: NuxieRuntimePinnedThreadExecutor?

    init(_ executor: NuxieRuntimePinnedThreadExecutor) {
        self.executor = executor
    }

    var hasExecutor: Bool {
        lock.withLock { executor != nil }
    }

    func withExecutor(_ operation: (NuxieRuntimePinnedThreadExecutor) -> Void) {
        lock.withLock {
            if let executor {
                operation(executor)
            }
        }
    }

    func clearExecutor() {
        lock.withLock {
            executor = nil
        }
    }
}
#endif
