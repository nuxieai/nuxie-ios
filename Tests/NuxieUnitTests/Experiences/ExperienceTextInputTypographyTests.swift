#if canImport(UIKit)
import UIKit
import CoreText
import XCTest
@testable import NuxieRuntime
@testable import Nuxie

@MainActor
final class ExperienceTextInputTypographyTests: XCTestCase {
    private struct Fixture: Decodable {
        let text: String
        let cases: [Case]
        struct Case: Decodable {
            let name: String
            let fontSize: Double
            let lineHeight: Double
            let containScale: Double
            let geometryScale: Double
            let expectedFontSize: Double
            let expectedBaselineDistance: Double?
        }
    }

    func testSharedMultilineBaselinesAndRestyling() throws {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/journeys/planes/text-input-typography.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: path))
        for item in fixture.cases {
            let bridge = ExperienceTextInputOverlayBridge()
            defer { bridge.clear() }
            let size = 400 * item.containScale
            let surface = UIView(frame: CGRect(x: 0, y: 0, width: size, height: size))
            var writes = 0
            var commits = 0
            bridge.onCommitText = { _, _ in commits += 1 }
            bridge.bind(screenID: "screen", renderPlan: plan(item, text: fixture.text), surfaceView: surface,
                artboardBounds: CGRect(x: 0, y: 0, width: 400, height: 400),
                textWriter: { _, _, done in writes += 1; done(.success(())) })
            func snapshot(scale: Double) -> ExperienceInteractiveViewModelSnapshot {
                ExperienceInteractiveViewModelSnapshot(rootInstanceID: 1, instances: [],
                    values: [("x", Float(10)), ("y", 10), ("w", 240), ("h", 180), ("r", 0),
                             ("sx", Float(scale)), ("sy", Float(scale))]
                        .enumerated().map { index, entry in
                            .init(ownerInstanceID: 1, propertyIndex: index, name: entry.0, value: .number(entry.1))
                        })
            }
            bridge.update(snapshot: snapshot(scale: item.geometryScale))
            let editor = try XCTUnwrap(surface.subviews.compactMap { $0 as? UITextView }.first)
            let oracle = UITextView(frame: editor.bounds)
            oracle.textContainerInset = .zero
            oracle.textContainer.lineFragmentPadding = 0
            let paragraph = NSMutableParagraphStyle()
            if let height = item.expectedBaselineDistance {
                paragraph.minimumLineHeight = height
                paragraph.maximumLineHeight = height
            }
            oracle.attributedText = NSAttributedString(string: fixture.text, attributes: [
                .font: UIFont.systemFont(ofSize: item.expectedFontSize), .paragraphStyle: paragraph,
            ])
            XCTAssertEqual(try XCTUnwrap(editor.font).pointSize, item.expectedFontSize, accuracy: 0.01, item.name)
            let actual = baselines(editor)
            let expected = baselines(oracle)
            XCTAssertEqual(actual.count, 3, item.name)
            XCTAssertEqual(expected.count, 3, item.name)
            for line in 1..<min(actual.count, expected.count) {
                XCTAssertEqual(actual[line] - actual[line - 1], expected[line] - expected[line - 1],
                    accuracy: 0.1, "\(item.name) baseline \(line)")
            }
            editor.selectedRange = NSRange(location: 1, length: 3)
            #if NUXIE_HOSTED_INPUT_TESTS
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
            let controller = UIViewController()
            window.rootViewController = controller
            controller.view.addSubview(surface)
            window.makeKeyAndVisible()
            defer {
                editor.resignFirstResponder()
                window.isHidden = true
                window.rootViewController = nil
            }
            XCTAssertTrue(editor.becomeFirstResponder(), item.name)
            editor.setMarkedText("lph", selectedRange: NSRange(location: 0, length: 3))
            let marked = try XCTUnwrap(editor.markedTextRange, item.name)
            XCTAssertEqual(editor.offset(from: editor.beginningOfDocument, to: marked.start), 1, item.name)
            XCTAssertEqual(editor.offset(from: marked.start, to: marked.end), 3, item.name)
            #endif
            let before = writes
            if let height = item.expectedBaselineDistance {
                // Force changed paragraph attributes while marked text exists.
                bridge.update(snapshot: snapshot(scale: item.geometryScale * 1.25))
                let changed = baselines(editor)
                XCTAssertEqual(changed.count, 3, item.name)
                for line in 1..<changed.count {
                    XCTAssertEqual(changed[line] - changed[line - 1], height * 1.25,
                        accuracy: 0.1, "\(item.name) changed baseline \(line)")
                }
            } else {
                bridge.update(snapshot: snapshot(scale: item.geometryScale))
            }
            XCTAssertEqual(editor.text, fixture.text, item.name)
            XCTAssertEqual(editor.selectedRange, NSRange(location: 1, length: 3), item.name)
            XCTAssertEqual(writes, before, "\(item.name) styling cannot write a response")
            XCTAssertEqual(commits, 0, item.name)
            #if NUXIE_HOSTED_INPUT_TESTS
            let retained = try XCTUnwrap(editor.markedTextRange, item.name)
            XCTAssertEqual(editor.offset(from: editor.beginningOfDocument, to: retained.start), 1, item.name)
            XCTAssertEqual(editor.offset(from: retained.start, to: retained.end), 3, item.name)
            #endif
        }
    }

    func testEffectiveMetricsRestyleAnUnchangedFrameWithoutTextTransactions() throws {
        let item = Fixture.Case(name: "effective", fontSize: 18, lineHeight: 24, containScale: 1,
            geometryScale: 1, expectedFontSize: 18, expectedBaselineDistance: 24)
        let text = "Alpha\nBravo\nCharlie"
        let bridge = ExperienceTextInputOverlayBridge()
        defer { bridge.clear() }
        let surface = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        var writes = 0
        bridge.bind(screenID: "screen", renderPlan: plan(item, text: text, prefix: "nuxieTextInputs/field/"),
            surfaceView: surface, artboardBounds: surface.bounds,
            textWriter: { _, _, done in writes += 1; done(.success(())) })
        func snapshot(_ size: Float?, _ height: Float?) -> ExperienceInteractiveViewModelSnapshot {
            var values: [ExperienceInteractiveViewModelSnapshot.Value] = [
                .init(ownerInstanceID: 1, propertyIndex: 0, name: "nuxieTextInputs", value: .referencedInstance(2)),
                .init(ownerInstanceID: 2, propertyIndex: 0, name: "field", value: .referencedInstance(3)),
            ]
            var numbers: [(String, Float)] = [("x", 10), ("y", 10), ("w", 240), ("h", 180), ("r", 0), ("sx", 1), ("sy", 1)]
            if let size { numbers.append(("fontSize", size)) }
            if let height { numbers.append(("lineHeight", height)) }
            values += numbers.enumerated().map { .init(ownerInstanceID: 3, propertyIndex: $0.offset,
                name: $0.element.0, value: .number($0.element.1)) }
            return .init(rootInstanceID: 1, instances: [], values: values)
        }
        bridge.update(snapshot: snapshot(nil, nil))
        let editor = try XCTUnwrap(surface.subviews.compactMap { $0 as? UITextView }.first)
        XCTAssertEqual(editor.font?.pointSize, 18)
        let originalFrame = editor.frame
        editor.selectedRange = NSRange(location: 1, length: 3)
        #if NUXIE_HOSTED_INPUT_TESTS
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        let controller = UIViewController()
        window.rootViewController = controller
        controller.view.addSubview(surface)
        window.makeKeyAndVisible()
        defer {
            editor.resignFirstResponder()
            window.isHidden = true
            window.rootViewController = nil
        }
        XCTAssertTrue(editor.becomeFirstResponder())
        editor.setMarkedText("lph", selectedRange: NSRange(location: 0, length: 3))
        XCTAssertNotNil(editor.markedTextRange)
        #endif
        let before = writes
        for (size, height): (Float, Float) in [(36, 48), (18, 24)] {
            bridge.update(snapshot: snapshot(size, height))
            XCTAssertEqual(editor.frame, originalFrame)
            XCTAssertEqual(editor.font?.pointSize, CGFloat(size))
            let lines = baselines(editor)
            XCTAssertEqual(lines.count, 3)
            for line in 1..<lines.count {
                XCTAssertEqual(lines[line] - lines[line - 1], CGFloat(height), accuracy: 0.1)
            }
            XCTAssertEqual(editor.text, text)
            XCTAssertEqual(editor.selectedRange, NSRange(location: 1, length: 3))
            XCTAssertEqual(writes, before)
            #if NUXIE_HOSTED_INPUT_TESTS
            let marked = try XCTUnwrap(editor.markedTextRange)
            XCTAssertEqual(editor.offset(from: editor.beginningOfDocument, to: marked.start), 1)
            XCTAssertEqual(editor.offset(from: marked.start, to: marked.end), 3)
            #endif
        }
        bridge.update(snapshot: snapshot(36, nil))
        XCTAssertTrue(editor.isHidden)
        XCTAssertFalse(editor.isEditable)
        editor.text = "late edit"
        bridge.textViewDidChange(editor)
        XCTAssertEqual(writes, before)
        XCTAssertEqual(editor.text, text)
        bridge.update(snapshot: snapshot(18, 24))
        XCTAssertFalse(editor.isHidden)
        XCTAssertTrue(editor.isEditable)
        let restored = baselines(editor)
        XCTAssertEqual(restored.count, 3)
        for line in 1..<restored.count {
            XCTAssertEqual(restored[line] - restored[line - 1], 24, accuracy: 0.1)
        }
    }

    func testPresentedAffineGeometryPreservesEditingAndRejectsUnavailableFields() throws {
        let item = Fixture.Case(name: "affine", fontSize: 18, lineHeight: 24, containScale: 1,
            geometryScale: 1, expectedFontSize: 18, expectedBaselineDistance: 24)
        let text = "Alpha\nBravo\nCharlie"
        let bridge = ExperienceTextInputOverlayBridge()
        defer { bridge.clear() }
        let surface = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        var writes = 0
        bridge.bind(screenID: "screen", renderPlan: plan(item, text: text), surfaceView: surface,
            artboardBounds: surface.bounds, textWriter: { _, _, done in writes += 1; done(.success(())) })
        let snapshot = ExperienceInteractiveViewModelSnapshot(rootInstanceID: 1, instances: [], values: [])
        func update(_ transform: CGAffineTransform) {
            bridge.update(frame: .init(snapshot: snapshot, geometry: .captured(["run": .init(renderRevision: 1,
                worldTransform: transform, contentTransform: transform, textBounds: .zero,
                layout: .init(transform: transform, bounds: CGRect(x: 0, y: 0, width: 240, height: 180)),
                firstBaseline: 20)])))
        }
        update(.init(translationX: 24, y: 32))
        let editor = try XCTUnwrap(surface.subviews.compactMap { $0 as? UITextView }.first)
        XCTAssertFalse(editor.isHidden, "Presented geometry works without local VM geometry paths")
        editor.selectedRange = NSRange(location: 1, length: 3)
        #if NUXIE_HOSTED_INPUT_TESTS
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        let controller = UIViewController()
        window.rootViewController = controller
        controller.view.addSubview(surface)
        window.makeKeyAndVisible()
        defer { editor.resignFirstResponder(); window.isHidden = true; window.rootViewController = nil }
        XCTAssertTrue(editor.becomeFirstResponder())
        editor.setMarkedText("lph", selectedRange: NSRange(location: 0, length: 3))
        #endif
        let before = writes
        for matrix in [CGAffineTransform(a: 1, b: 0.5, c: 0.3, d: 1, tx: 24, ty: 32),
                       CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 300, ty: 32)] {
            update(matrix)
            XCTAssertEqual(editor.transform.a, matrix.a)
            XCTAssertEqual(editor.transform.b, matrix.b)
            XCTAssertEqual(editor.transform.c, matrix.c)
            XCTAssertEqual(editor.transform.d, matrix.d)
            XCTAssertEqual(editor.font?.pointSize, 18, "Font metrics remain field-local under affine scaling")
            XCTAssertEqual(editor.text, text)
            XCTAssertEqual(editor.selectedRange, NSRange(location: 1, length: 3))
            XCTAssertEqual(writes, before)
            #if NUXIE_HOSTED_INPUT_TESTS
            let marked = try XCTUnwrap(editor.markedTextRange)
            XCTAssertEqual(editor.offset(from: editor.beginningOfDocument, to: marked.start), 1)
            XCTAssertEqual(editor.offset(from: marked.start, to: marked.end), 3)
            #endif
        }
        update(.init(a: 1, b: 2, c: 2, d: 4, tx: 24, ty: 32))
        XCTAssertTrue(editor.isHidden)
        XCTAssertFalse(editor.isEditable)
        editor.text = "late edit"
        bridge.textViewDidChange(editor)
        XCTAssertEqual(editor.text, text)
        XCTAssertEqual(writes, before)
        update(.init(translationX: 24, y: 32))
        XCTAssertFalse(editor.isHidden)
        XCTAssertTrue(editor.isEditable)
        bridge.update(frame: .init(snapshot: snapshot, geometry: .captured([:])))
        XCTAssertTrue(editor.isHidden)
        XCTAssertFalse(editor.isEditable)
        update(.init(translationX: 24, y: 32))
        surface.bounds = .zero
        bridge.layout()
        XCTAssertTrue(editor.isHidden)
        XCTAssertFalse(editor.isEditable)
        editor.text = "late zero-size edit"
        bridge.textViewDidChange(editor)
        XCTAssertEqual(editor.text, text)
        XCTAssertEqual(writes, before)
        surface.bounds = CGRect(x: 0, y: 0, width: 400, height: 400)
        bridge.layout()
        XCTAssertFalse(editor.isHidden)
        XCTAssertTrue(editor.isEditable)
        bridge.update(frame: .init(snapshot: nil, geometry: .notRequested))
        XCTAssertTrue(editor.isHidden)
        XCTAssertFalse(editor.isEditable)
    }

    func testPublishedRuntimeFontBaselinesMatchNativeEditors() async throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/runtime/font-metrics-binding")
        struct PublishedInput: Decodable {
            struct Style: Decodable {
                let fontFamily: String; let fontWeight: String; let fontStyle: String
                let fontSize: Double; let lineHeight: Double; let letterSpacing: Double
                let color: UInt32; let fontAssetRiveUniqueName: String; let textAlign: String?
            }
            let viewNodeId: String; let renderedNodeId: String; let artboardId: String
            let riveTextObjectKey: String; let riveTextRunObjectKey: String
            let riveTextName: String; let riveTextRunName: String; let value: String
            let editable: Bool; let multiline: Bool; let style: Style
        }
        struct Report: Decodable {
            struct Metadata: Decodable { let textInputs: [PublishedInput] }
            let builtPackageMetadata: Metadata
        }
        struct Expected: Decodable {
            struct Field: Decodable { let path: String; let runName: String }
            struct Metrics: Decodable { let fontSize: Float; let lineHeight: Float }
            let geometry: [Field]; let cases: [Metrics]
        }
        let report = try JSONDecoder().decode(Report.self, from: Data(contentsOf: directory.appendingPathComponent("report.json")))
        let expected = try JSONDecoder().decode(Expected.self, from: Data(contentsOf: directory.appendingPathComponent("expectations.json")))
        let sha = "2898476918b21c3f9b5ba22e86853c6d63b544f92da277a92533011a28c93af5"
        let fontBytes = try Data(contentsOf: directory.appendingPathComponent("\(sha).otf"))
        let inputs = try report.builtPackageMetadata.textInputs.map { item in
            let prefix = try XCTUnwrap(expected.geometry.first { $0.runName == item.riveTextRunName }).path
            return NativeExperienceTextInput(inputId: item.viewNodeId, screenId: "screen", artboardId: item.artboardId,
                viewNodeId: item.viewNodeId, renderedNodeId: item.renderedNodeId,
                riveTextObjectKey: item.riveTextObjectKey, riveTextRunObjectKey: item.riveTextRunObjectKey,
                riveTextName: item.riveTextName, riveTextRunName: item.riveTextRunName,
                value: item.value, placeholder: nil, editable: item.editable,
                geometry: .init(xPath: "\(prefix)/x", yPath: "\(prefix)/y", widthPath: "\(prefix)/width",
                    heightPath: "\(prefix)/height", rotationPath: "\(prefix)/rotation", scaleXPath: "\(prefix)/scaleX", scaleYPath: "\(prefix)/scaleY"),
                style: .init(fontFamily: item.style.fontFamily, fontWeight: item.style.fontWeight,
                    fontStyle: item.style.fontStyle, fontSize: item.style.fontSize, lineHeight: item.style.lineHeight,
                    letterSpacing: item.style.letterSpacing, color: item.style.color,
                    fontAssetRiveUniqueName: item.style.fontAssetRiveUniqueName, textAlign: item.style.textAlign),
                keyboardType: nil, secureTextEntry: false, multiline: item.multiline, maxLength: nil, responseFieldKey: nil)
        }
        let fontName = try XCTUnwrap(inputs.first).style.fontAssetRiveUniqueName
        let scope = ExperienceRuntimeFontScope()
        defer { scope.close() }
        let registeredName = try XCTUnwrap(ExperienceRuntimeFontRegistry.registerFont(riveUniqueName: fontName, data: fontBytes, in: scope))
        let plan = NativeExperienceRenderPlan(identity: .init(experienceId: "e", buildId: "published", appId: "a", environment: "test"),
            scene: .init(key: "scene", sha256: "", sizeBytes: 0), entry: .init(screenId: "screen"),
            screens: [], transitions: [], textInputs: inputs, images: [], fonts: [
                .init(location: .external(key: sha), riveAssetId: 0, riveUniqueName: fontName,
                    family: "Fixture Sans", weight: "400", style: "normal", sha256: sha,
                    sizeBytes: fontBytes.count, contentType: "font/otf", format: "otf", required: true)
            ])
        let scene = try Data(contentsOf: directory.appendingPathComponent("screen.riv"))
        let assets = try await NuxieNativeRuntime.inspectAssets(bytes: scene)
        let font = try XCTUnwrap(assets.first { $0.kind == .font })
        let runtime = try await NuxieNativeRuntime.open(bytes: scene, artboardName: "Paywall", player: .staticArtboard,
            pixelWidth: 390, pixelHeight: 844, bindDefaultViewModel: true,
            importMode: .configured(moduleName: "nuxie", expectedAssets: assets, externalAssets: [font.ordinal: fontBytes]))
        defer { Task { try? await runtime.close() } }
        let root = try await runtime.rootViewModelReference()
        let layer = CAMetalLayer()
        layer.device = try await runtime.metalDevice().value
        layer.pixelFormat = .bgra8Unorm
        layer.drawableSize = CGSize(width: 390, height: 844)
        let surface = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let bridge = ExperienceTextInputOverlayBridge()
        defer { bridge.clear() }
        var writes = 0
        bridge.bind(screenID: "screen", renderPlan: plan, surfaceView: surface,
            artboardBounds: surface.bounds, textWriter: { _, _, done in writes += 1; done(.success(())) })
        var initialWrites = writes
        var lastSnapshot: ExperienceInteractiveViewModelSnapshot?
        #if NUXIE_HOSTED_INPUT_TESTS
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 900))
        let controller = UIViewController()
        window.rootViewController = controller
        controller.view.addSubview(surface)
        window.makeKeyAndVisible()
        defer { surface.endEditing(true); window.isHidden = true; window.rootViewController = nil }
        #endif
        for (caseIndex, item) in expected.cases.enumerated() {
            _ = try await runtime.mutateViewModel([
                .setNumber(instance: root, path: "requestedFontSize", value: item.fontSize),
                .setNumber(instance: root, path: "requestedLineHeight", value: item.lineHeight),
            ])
            let step = try await runtime.step(elapsedSeconds: 0, textRunNames: inputs.map(\.riveTextRunName))
            guard case .captured(let geometry) = step.textGeometry else { return XCTFail("No native geometry") }
            let native = try await runtime.snapshot()
            let snapshot = ExperienceInteractiveViewModelSnapshot(rootInstanceID: native.rootInstanceID,
                instances: native.instances.map { .init(id: $0.id, schemaIndex: $0.schemaIndex, valueRange: $0.valueRange) },
                values: native.values.map { entry in
                    let value: ExperienceInteractiveViewModelValue
                    switch entry.value {
                    case .number(let n): value = .number(n)
                    case .referencedInstance(let id): value = .referencedInstance(id)
                    case .bytes(let bytes): value = .bytes(bytes)
                    case .bool(let bool): value = .bool(bool)
                    case .integer(let n): value = .integer(n)
                    case .list(let ids): value = .list(ids)
                    case .unsupported: value = .unsupported
                    }
                    return .init(ownerInstanceID: entry.ownerInstanceID, propertyIndex: entry.propertyIndex, name: entry.name, value: value)
                })
            lastSnapshot = snapshot
            guard let drawable = layer.nextDrawable() else { throw XCTSkip("No Metal drawable") }
            let completed = expectation(description: "published frame completed")
            let outcome = try await runtime.render(drawable: .available(.init(drawable)), completion: { completed.fulfill() })
            await fulfillment(of: [completed], timeout: 2)
            XCTAssertEqual(outcome.disposition, .presented)
            bridge.update(frame: .init(snapshot: snapshot, geometry: step.textGeometry))
            let editors = surface.subviews.compactMap { $0 as? UITextView }.sorted { $0.center.y < $1.center.y }
            XCTAssertEqual(editors.count, inputs.count)
            for (index, editor) in editors.enumerated() {
                let field = try XCTUnwrap(geometry[inputs[index].riveTextRunName])
                let baseline = try XCTUnwrap(field.firstBaseline)
                let expectedPoint = CGPoint(x: 0, y: baseline).applying(field.contentTransform)
                let first = try XCTUnwrap(baselines(editor).first)
                let actualPoint = editor.convert(CGPoint(x: 0, y: editor.textContainerInset.top + first), to: surface)
                XCTAssertEqual(actualPoint.y, expectedPoint.y, accuracy: 0.5, "\(inputs[index].inputId) font size \(item.fontSize)")
                XCTAssertEqual(editor.font?.fontName, registeredName)
                XCTAssertEqual(editor.font?.pointSize, index == 0 ? CGFloat(item.fontSize) : 18)
                XCTAssertEqual(editor.text, inputs[index].value)
                XCTAssertEqual(writes, initialWrites)
                let lines = baselines(editor)
                XCTAssertEqual(lines.count, 3)
                let interval = index == 0 ? item.lineHeight : 24
                if interval > 0 {
                    for line in 1..<lines.count {
                        XCTAssertEqual(lines[line] - lines[line - 1], CGFloat(interval), accuracy: 0.1)
                    }
                }
                if index == 0 {
                    if caseIndex == 0 {
                        editor.selectedRange = NSRange(location: 1, length: 3)
                        #if NUXIE_HOSTED_INPUT_TESTS
                        XCTAssertTrue(editor.becomeFirstResponder())
                        editor.setMarkedText("lph", selectedRange: NSRange(location: 0, length: 3))
                        #endif
                        // Creating composition is an explicit user edit. Only
                        // subsequent geometry/style frames must be write-free.
                        initialWrites = writes
                    }
                    XCTAssertEqual(editor.selectedRange, NSRange(location: 1, length: 3))
                    #if NUXIE_HOSTED_INPUT_TESTS
                    let marked = try XCTUnwrap(editor.markedTextRange)
                    XCTAssertEqual(editor.offset(from: editor.beginningOfDocument, to: marked.start), 1)
                    XCTAssertEqual(editor.offset(from: marked.start, to: marked.end), 3)
                    #endif
                }
            }
        }
        let editor = try XCTUnwrap(surface.subviews.compactMap { $0 as? UITextView }.min { $0.center.y < $1.center.y })
        let priorInset = editor.textContainerInset
        let caret = editor.caretRect(for: editor.beginningOfDocument)
        _ = try await runtime.setTextRuns(inputs.map { .init(name: $0.riveTextRunName, text: Data()) })
        let blank = try await runtime.step(elapsedSeconds: 0, textRunNames: inputs.map(\.riveTextRunName))
        guard case .captured(let blankGeometry) = blank.textGeometry else { return XCTFail("No blank geometry") }
        XCTAssertTrue(blankGeometry.values.allSatisfy { $0.firstBaseline == nil })
        guard let drawable = layer.nextDrawable() else { throw XCTSkip("No blank drawable") }
        let blankCompleted = expectation(description: "blank frame completed")
        _ = try await runtime.render(drawable: .available(.init(drawable)), completion: { blankCompleted.fulfill() })
        await fulfillment(of: [blankCompleted], timeout: 2)
        bridge.update(frame: .init(snapshot: try XCTUnwrap(lastSnapshot), geometry: blank.textGeometry))
        XCTAssertEqual(editor.textContainerInset, priorInset)
        XCTAssertEqual(editor.caretRect(for: editor.beginningOfDocument), caret)
        XCTAssertEqual(editor.selectedRange, NSRange(location: 1, length: 3))
        XCTAssertEqual(editor.text, inputs[0].value)
        XCTAssertEqual(writes, initialWrites)
        #if NUXIE_HOSTED_INPUT_TESTS
        XCTAssertNotNil(editor.markedTextRange)
        #endif
        try await runtime.close()
    }

    func testSingleLineAndSecureFieldsUseCapturedFirstBaseline() throws {
        let item = Fixture.Case(name: "single-line", fontSize: 18, lineHeight: 24, containScale: 1,
            geometryScale: 1, expectedFontSize: 18, expectedBaselineDistance: 24)
        var ordinaryCarets: [CGRect] = []
        for secure in [false, true] {
            let bridge = ExperienceTextInputOverlayBridge()
            defer { bridge.clear() }
            let surface = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
            var writes = 0
            bridge.bind(screenID: "screen", renderPlan: plan(item, text: "AAAAA", prefix: "nuxieTextInputs/field/", multiline: false, secure: secure),
                surfaceView: surface, artboardBounds: surface.bounds,
                textWriter: { _, _, done in writes += 1; done(.success(())) })
            let matrix = CGAffineTransform(translationX: 24, y: 24)
            func update(size: Float, height: Float, baseline: CGFloat?) {
                let snapshot = ExperienceInteractiveViewModelSnapshot(rootInstanceID: 1, instances: [], values: [
                    .init(ownerInstanceID: 1, propertyIndex: 0, name: "nuxieTextInputs", value: .referencedInstance(2)),
                    .init(ownerInstanceID: 2, propertyIndex: 0, name: "field", value: .referencedInstance(3)),
                    .init(ownerInstanceID: 3, propertyIndex: 0, name: "fontSize", value: .number(size)),
                    .init(ownerInstanceID: 3, propertyIndex: 1, name: "lineHeight", value: .number(height)),
                ])
                bridge.update(frame: .init(snapshot: snapshot, geometry: .captured(["run": .init(renderRevision: 1,
                    worldTransform: matrix, contentTransform: matrix, textBounds: .zero,
                    layout: .init(transform: matrix, bounds: CGRect(x: 0, y: 0, width: 240, height: 180)), firstBaseline: baseline)])))
            }
            update(size: 18, height: 24, baseline: 18)
            let field = try XCTUnwrap(surface.subviews.compactMap { $0 as? UITextField }.first)
            #if NUXIE_HOSTED_INPUT_TESTS
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
            let controller = UIViewController()
            window.rootViewController = controller
            controller.view.addSubview(surface)
            window.makeKeyAndVisible()
            defer { field.resignFirstResponder(); window.isHidden = true; window.rootViewController = nil }
            XCTAssertTrue(field.becomeFirstResponder())
            #endif
            let start = try XCTUnwrap(field.position(from: field.beginningOfDocument, offset: 1))
            let end = try XCTUnwrap(field.position(from: start, offset: 3))
            field.selectedTextRange = field.textRange(from: start, to: end)
            #if NUXIE_HOSTED_INPUT_TESTS
            if !secure { field.setMarkedText("AAA", selectedRange: NSRange(location: 0, length: 3)) }
            #endif
            let before = writes
            let cases: [(Float, Float)] = [(18, 24), (36, 48), (24, -1), (18, 36), (18, 24)]
            for (index, metrics) in cases.enumerated() {
                let (size, height) = metrics
                update(size: size, height: height, baseline: CGFloat(size))
                surface.layoutIfNeeded()
                if !secure {
                    try assertSingleLineInkBaseline(field, surface: surface, baseline: 24 + CGFloat(size))
                }
                let caret = field.textInputView.convert(field.caretRect(for: field.beginningOfDocument), to: surface)
                // Secure UIKit carets use the font height; ordinary carets also
                // include explicit paragraph spacing. Preserve native behavior.
                let native = UITextField()
                native.defaultTextAttributes = field.defaultTextAttributes
                native.isSecureTextEntry = secure
                native.text = "AAAAA"
                native.contentVerticalAlignment = .top
                native.frame = CGRect(x: 300, y: 0, width: 240, height: native.intrinsicContentSize.height)
                surface.addSubview(native)
                native.layoutIfNeeded()
                let naturalCaret = native.textInputView.convert(native.caretRect(for: native.beginningOfDocument), to: surface)
                XCTAssertEqual(caret.height, naturalCaret.height, accuracy: 0.1)
                native.removeFromSuperview()
                if secure {
                    XCTAssertEqual(caret.minY, ordinaryCarets[index].minY, accuracy: 1)
                } else {
                    ordinaryCarets.append(caret)
                }
                XCTAssertEqual(field.isSecureTextEntry, secure)
                XCTAssertEqual(field.font?.pointSize, CGFloat(size))
                XCTAssertEqual(field.text, "AAAAA")
                XCTAssertEqual(writes, before)
                let range = try XCTUnwrap(field.selectedTextRange)
                XCTAssertEqual(field.offset(from: field.beginningOfDocument, to: range.start), 1)
                XCTAssertEqual(field.offset(from: range.start, to: range.end), 3)
                #if NUXIE_HOSTED_INPUT_TESTS
                if !secure { XCTAssertNotNil(field.markedTextRange) }
                #endif
            }
            let caret = field.textInputView.convert(field.caretRect(for: field.beginningOfDocument), to: surface)
            update(size: 18, height: 24, baseline: nil)
            surface.layoutIfNeeded()
            if !secure { try assertSingleLineInkBaseline(field, surface: surface, baseline: 42) }
            XCTAssertEqual(field.textInputView.convert(field.caretRect(for: field.beginningOfDocument), to: surface), caret)
            XCTAssertEqual(writes, before)
            XCTAssertEqual(field.text, "AAAAA")
            XCTAssertTrue(field.point(inside: CGPoint(x: 120, y: 170), with: nil), "Baseline correction preserves the entire authored touch area")
            #if NUXIE_HOSTED_INPUT_TESTS
            if !secure { XCTAssertNotNil(field.markedTextRange) }
            #endif
        }
    }

    /// Compare actual UIKit ink with a CoreText line at the captured baseline.
    /// Baseline anchors on the stretched production field are not a valid oracle.
    private func assertSingleLineInkBaseline(_ field: UITextField, surface: UIView, baseline: CGFloat,
        file: StaticString = #filePath, line: UInt = #line) throws {
        field.textColor = .black
        let font = try XCTUnwrap(field.font)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let bitmap = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 400), format: format).image { drawing in
            UIColor.white.setFill()
            drawing.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
            surface.layer.render(in: drawing.cgContext)
            drawing.cgContext.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            drawing.cgContext.textPosition = CGPoint(x: 300, y: baseline)
            let reference = CTLineCreateWithAttributedString(NSAttributedString(string: "AAAAA",
                attributes: [.font: font, .foregroundColor: UIColor.black]))
            CTLineDraw(reference, drawing.cgContext)
        }
        let image = try XCTUnwrap(bitmap.cgImage)
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        func inkRows(_ range: Range<Int>) -> [Int] {
            (0..<image.height).filter { y in
                range.contains { x in
                    let offset = (y * image.width + x) * 4
                    return pixels[offset] < 128 && pixels[offset + 1] < 128 && pixels[offset + 2] < 128
                }
            }
        }
        let actual = inkRows(24..<264)
        let expected = inkRows(300..<600)
        let actualTop = try XCTUnwrap(actual.first)
        let actualBottom = try XCTUnwrap(actual.last)
        let expectedTop = try XCTUnwrap(expected.first)
        let expectedBottom = try XCTUnwrap(expected.last)
        if abs(actualTop - expectedTop) > 1 || abs(actualBottom - expectedBottom) > 1 {
            let attachment = XCTAttachment(image: bitmap)
            attachment.name = "UIKit field and CoreText baseline reference"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertEqual(Double(actualTop), Double(expectedTop), accuracy: 1, "font=\(font.pointSize), baseline=\(baseline)", file: file, line: line)
        XCTAssertEqual(Double(actualBottom), Double(expectedBottom), accuracy: 1, "font=\(font.pointSize), baseline=\(baseline)", file: file, line: line)
    }

    private func baselines(_ view: UITextView) -> [CGFloat] {
        let manager = view.layoutManager
        manager.ensureLayout(for: view.textContainer)
        var result: [CGFloat] = []
        var character = 0
        for line in view.text.components(separatedBy: "\n") {
            let glyph = manager.glyphIndexForCharacter(at: character)
            let fragment = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            result.append(fragment.minY + manager.location(forGlyphAt: glyph).y)
            character += line.utf16.count + 1
        }
        return result
    }

    private func plan(_ item: Fixture.Case, text: String, prefix: String = "", multiline: Bool = true, secure: Bool = false) -> NativeExperienceRenderPlan {
        let input = NativeExperienceTextInput(inputId: "input", screenId: "screen", artboardId: "a",
            viewNodeId: "v", renderedNodeId: "r", riveTextObjectKey: "text", riveTextRunObjectKey: "run",
            riveTextName: "text", riveTextRunName: "run", value: text, placeholder: nil, editable: true,
            geometry: .init(xPath: "\(prefix)x", yPath: "\(prefix)y", widthPath: "\(prefix)w", heightPath: "\(prefix)h", rotationPath: "\(prefix)r",
                scaleXPath: "\(prefix)sx", scaleYPath: "\(prefix)sy"),
            style: .init(fontFamily: "system", fontWeight: "normal", fontStyle: "normal", fontSize: item.fontSize,
                lineHeight: item.lineHeight, letterSpacing: 0, color: 0, fontAssetRiveUniqueName: "", textAlign: nil),
            keyboardType: nil, secureTextEntry: secure, multiline: multiline, maxLength: nil, responseFieldKey: "answer")
        return NativeExperienceRenderPlan(identity: .init(experienceId: "e", buildId: "b", appId: "a", environment: "test"),
            scene: .init(key: "scene", sha256: "", sizeBytes: 0), entry: .init(screenId: "screen"),
            screens: [], transitions: [], textInputs: [input], images: [], fonts: [])
    }
}
#endif
