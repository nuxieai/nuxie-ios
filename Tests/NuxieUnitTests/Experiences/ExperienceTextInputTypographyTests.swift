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
            let viewSizeScale: Double
            let geometryScale: Double
            let expectedFontSize: Double
            let expectedBaselineDistance: Double?
        }
    }

    func testAuthenticatedSystemInputsUseNativeWeightAtCapturedSize() throws {
        let weights: [(String, UIFont.Weight)] = [("100", .ultraLight), ("200", .thin), ("300", .light),
            ("400", .regular), ("500", .medium), ("600", .semibold), ("700", .bold), ("800", .heavy), ("900", .black)]
        for (weight, nativeWeight) in weights {
            let bridge = ExperienceTextInputOverlayBridge()
            defer { bridge.clear() }
            let surface = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
            let item = Fixture.Case(name: weight, fontSize: 23, lineHeight: -1, viewSizeScale: 1,
                geometryScale: 1, expectedFontSize: 23, expectedBaselineDistance: nil)
            bindNativeFixture(bridge, screenID: "screen", renderPlan: plan(item, text: "System input", systemWeight: weight),
                surfaceView: surface, artboardBounds: surface.bounds,
                textWriter: { _, _, completion in completion(.success(())) })
            let transform = CGAffineTransform(translationX: 10, y: 20)
            updateNativeFixture(bridge, frame: .init(snapshot: .init(rootInstanceID: 1, instances: [], values: []),
                geometry: .captured(["run": .init(renderRevision: 1, worldTransform: transform,
                    contentTransform: transform, textBounds: .zero,
                    layout: .init(transform: transform, bounds: CGRect(x: 0, y: 0, width: 240, height: 180)), firstBaseline: nil)])))
            let editor = try XCTUnwrap(surface.subviews.compactMap { $0 as? UITextView }.first)
            let actual = try XCTUnwrap(editor.font)
            let expected = UIFont.systemFont(ofSize: 23, weight: nativeWeight)
            XCTAssertEqual(actual.fontDescriptor, expected.fontDescriptor, weight)
            XCTAssertEqual(actual.pointSize, 23)
            XCTAssertFalse(editor.isHidden)
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
            let size = 400 * item.viewSizeScale
            let surface = UIView(frame: CGRect(x: 0, y: 0, width: size, height: size))
            var writes = 0
            var commits = 0
            bridge.onAcceptedTextChange = { _, _ in commits += 1 }
            bindNativeFixture(bridge, screenID: "screen", renderPlan: plan(item, text: fixture.text), surfaceView: surface,
                artboardBounds: CGRect(x: 0, y: 0, width: 400, height: 400),
                textWriter: { _, _, done in writes += 1; done(.success(())) })
            func update(scale: Double) {
                let matrix = CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: 10, ty: 10)
                updateNativeFixture(bridge, frame: .init(
                    snapshot: .init(rootInstanceID: 1, instances: [], values: []),
                    geometry: .captured(["run": .init(renderRevision: 1,
                        worldTransform: matrix, contentTransform: matrix, textBounds: .zero,
                        layout: .init(transform: matrix, bounds: CGRect(x: 0, y: 0, width: 240, height: 180)),
                        firstBaseline: nil)])))
            }
            update(scale: item.geometryScale)
            let editor = try XCTUnwrap(surface.subviews.compactMap { $0 as? UITextView }.first)
            let oracle = UITextView(frame: editor.bounds)
            oracle.textContainerInset = .zero
            oracle.textContainer.lineFragmentPadding = 0
            let paragraph = NSMutableParagraphStyle()
            if item.lineHeight > 0 {
                paragraph.minimumLineHeight = item.lineHeight
                paragraph.maximumLineHeight = item.lineHeight
            }
            oracle.attributedText = NSAttributedString(string: fixture.text, attributes: [
                .font: UIFont.systemFont(ofSize: item.fontSize), .paragraphStyle: paragraph,
            ])
            let projectionScale = item.geometryScale
            XCTAssertEqual(try XCTUnwrap(editor.font).pointSize, item.fontSize, accuracy: 0.01, item.name)
            let unitOrigin = editor.convert(CGPoint.zero, to: surface)
            let unitEnd = editor.convert(CGPoint(x: 0, y: 1), to: surface)
            XCTAssertEqual((unitEnd.y - unitOrigin.y) * (try XCTUnwrap(editor.font)).pointSize,
                item.expectedFontSize, accuracy: 0.01, item.name)
            let actual = baselines(editor).map { editor.convert(CGPoint(x: 0, y: $0), to: surface).y }
            let expected = baselines(oracle).map { $0 * projectionScale }
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
                // Project changed geometry while marked text exists.
                update(scale: item.geometryScale * 1.25)
                let changed = baselines(editor).map { editor.convert(CGPoint(x: 0, y: $0), to: surface).y }
                XCTAssertEqual(changed.count, 3, item.name)
                for line in 1..<changed.count {
                    XCTAssertEqual(changed[line] - changed[line - 1], height * 1.25,
                        accuracy: 0.1, "\(item.name) changed baseline \(line)")
                }
            } else {
                update(scale: item.geometryScale)
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
        let item = Fixture.Case(name: "effective", fontSize: 18, lineHeight: 24, viewSizeScale: 1,
            geometryScale: 1, expectedFontSize: 18, expectedBaselineDistance: 24)
        let text = "Alpha\nBravo\nCharlie"
        let bridge = ExperienceTextInputOverlayBridge()
        defer { bridge.clear() }
        let surface = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        var writes = 0
        bindNativeFixture(bridge, screenID: "screen", renderPlan: plan(item, text: text, prefix: "nuxieTextInputs/field/"),
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
        func update(_ size: Float?, _ height: Float?) {
            let matrix = CGAffineTransform(translationX: 10, y: 10)
            updateNativeFixture(bridge, frame: .init(snapshot: snapshot(size, height),
                geometry: .captured(["run": .init(renderRevision: 1,
                    worldTransform: matrix, contentTransform: matrix, textBounds: .zero,
                    layout: .init(transform: matrix, bounds: CGRect(x: 0, y: 0, width: 240, height: 180)),
                    firstBaseline: nil)])))
        }
        update(nil, nil)
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
            update(size, height)
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
        update(36, nil)
        XCTAssertTrue(editor.isHidden)
        XCTAssertFalse(editor.isEditable)
        editor.text = "late edit"
        bridge.textViewDidChange(editor)
        XCTAssertEqual(writes, before)
        XCTAssertEqual(editor.text, text)
        update(18, 24)
        XCTAssertFalse(editor.isHidden)
        XCTAssertTrue(editor.isEditable)
        let restored = baselines(editor)
        XCTAssertEqual(restored.count, 3)
        for line in 1..<restored.count {
            XCTAssertEqual(restored[line] - restored[line - 1], 24, accuracy: 0.1)
        }
    }

    func testPresentedAffineGeometryPreservesEditingAndRejectsUnavailableFields() throws {
        let item = Fixture.Case(name: "affine", fontSize: 18, lineHeight: 24, viewSizeScale: 1,
            geometryScale: 1, expectedFontSize: 18, expectedBaselineDistance: 24)
        let text = "Alpha\nBravo\nCharlie"
        let bridge = ExperienceTextInputOverlayBridge()
        defer { bridge.clear() }
        let surface = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        var writes = 0
        bindNativeFixture(bridge, screenID: "screen", renderPlan: plan(item, text: text), surfaceView: surface,
            artboardBounds: surface.bounds, textWriter: { _, _, done in writes += 1; done(.success(())) })
        let snapshot = ExperienceInteractiveViewModelSnapshot(rootInstanceID: 1, instances: [], values: [])
        func update(_ transform: CGAffineTransform) {
            updateNativeFixture(bridge, frame: .init(snapshot: snapshot, geometry: .captured(["run": .init(renderRevision: 1,
                worldTransform: transform, contentTransform: transform, textBounds: .zero,
                layout: .init(transform: transform, bounds: CGRect(x: 0, y: 0, width: 240, height: 180)),
                firstBaseline: 20)])))
        }
        update(.init(translationX: 24, y: 32))
        var editor = try XCTUnwrap(surface.subviews.compactMap { $0 as? UITextView }.first)
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
        updateNativeFixture(bridge, frame: .init(snapshot: snapshot, geometry: .captured([:])))
        XCTAssertTrue(editor.isHidden)
        XCTAssertFalse(editor.isEditable)
        XCTAssertNil(editor.superview, "An absent native occurrence retires its editor")
        update(.init(translationX: 24, y: 32))
        editor = try XCTUnwrap(surface.subviews.compactMap { $0 as? UITextView }.first)
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
        updateNativeFixture(bridge, frame: .init(snapshot: nil, geometry: .notRequested))
        XCTAssertTrue(editor.isHidden)
        XCTAssertFalse(editor.isEditable)
    }

    func testPublishedOrdinaryTextRunMetricsRemainAvailable() async throws {
        for fixture in ["font-metrics-binding", "text-input-single-line"] {
            let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("fixtures/runtime/\(fixture)")
            struct Expected: Decodable {
                struct Field: Decodable { let path: String; let runName: String; let x: Float; let y: Float; let width: Float; let height: Float; let secure: Bool? }
                struct Metrics: Decodable { let fontSize: Float; let lineHeight: Float }
                let geometry: [Field]; let cases: [Metrics]
            }
            let expected = try JSONDecoder().decode(Expected.self, from: Data(contentsOf: directory.appendingPathComponent("expectations.json")))
            let scene = try Data(contentsOf: directory.appendingPathComponent("screen.riv"))
            let assets = try await NuxieNativeRuntime.inspectAssets(bytes: scene)
            let font = try XCTUnwrap(assets.first { $0.kind == .font })
            let fontBytes = try Data(contentsOf: directory.appendingPathComponent("2898476918b21c3f9b5ba22e86853c6d63b544f92da277a92533011a28c93af5.otf"))
            let runtime = try await NuxieNativeRuntime.open(bytes: scene, artboardName: "Paywall", player: .staticArtboard,
                pixelWidth: 390, pixelHeight: 844, bindDefaultViewModel: true,
                importMode: .configured(moduleName: "nuxie", expectedAssets: assets, externalAssets: [font.ordinal: fontBytes]))
            addTeardownBlock { try await runtime.close() }
            let root = try await runtime.rootViewModelReference()
            for item in expected.cases {
                _ = try await runtime.mutateViewModel([
                    .setNumber(instance: root, path: "requestedFontSize", value: item.fontSize),
                    .setNumber(instance: root, path: "requestedLineHeight", value: item.lineHeight),
                ])
                let frame = try await runtime.step(elapsedSeconds: 0, textRunNames: expected.geometry.map(\.runName))
                guard case .captured(let geometry) = frame.textGeometry else { return XCTFail("Ordinary text-run geometry must remain available") }
                let snapshot = try await runtime.snapshot()
                for (index, field) in expected.geometry.enumerated() {
                    let captured = try XCTUnwrap(geometry[field.runName])
                    let layout = try XCTUnwrap(captured.layout)
                    XCTAssertEqual(layout.bounds.width, CGFloat(field.width), accuracy: 0.1)
                    XCTAssertEqual(layout.bounds.height, CGFloat(field.height), accuracy: 0.1)
                    XCTAssertEqual(layout.transform.tx, CGFloat(field.x), accuracy: 0.1)
                    XCTAssertEqual(layout.transform.ty, CGFloat(field.y), accuracy: 0.1)
                    if field.secure == true { XCTAssertNil(captured.firstBaseline) }
                    else { XCTAssertGreaterThan(try XCTUnwrap(captured.firstBaseline), 0) }
                    let parts = field.path.split(separator: "/").map(String.init)
                    var owner = snapshot.rootInstanceID
                    for part in parts {
                        let entry = try XCTUnwrap(snapshot.values.first { $0.ownerInstanceID == owner && $0.name == part })
                        guard case .referencedInstance(let child) = entry.value else { return XCTFail("Metric owner must remain a model") }
                        owner = child
                    }
                    let fixed = fixture == "font-metrics-binding" && index == 1
                    XCTAssertEqual(snapshot.values.first { $0.ownerInstanceID == owner && $0.name == "fontSize" }?.value,
                        .number(fixed ? 18 : item.fontSize))
                    XCTAssertEqual(snapshot.values.first { $0.ownerInstanceID == owner && $0.name == "lineHeight" }?.value,
                        .number(fixed ? 24 : item.lineHeight))
                }
            }

        }
    }

    func testSingleLineAndSecureFieldsUseCapturedFirstBaseline() throws {
        let item = Fixture.Case(name: "single-line", fontSize: 18, lineHeight: 24, viewSizeScale: 1,
            geometryScale: 1, expectedFontSize: 18, expectedBaselineDistance: 24)
        var ordinaryCarets: [CGRect] = []
        for secure in [false, true] {
            let bridge = ExperienceTextInputOverlayBridge()
            defer { bridge.clear() }
            let surface = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
            var writes = 0
            bindNativeFixture(bridge, screenID: "screen", renderPlan: plan(item, text: "AAAAA", prefix: "nuxieTextInputs/field/", multiline: false, secure: secure),
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
                updateNativeFixture(bridge, frame: .init(snapshot: snapshot, geometry: .captured(["run": .init(renderRevision: 1,
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
                XCTAssertTrue(field.text == "AAAAA", "Native field must retain its text")
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
            XCTAssertTrue(field.text == "AAAAA", "Native field must retain its text")
            XCTAssertTrue(field.point(inside: CGPoint(x: 120, y: 170), with: nil), "Baseline correction preserves the entire authored touch area")
            update(size: 0.5, height: -1, baseline: 0.5)
            XCTAssertEqual(field.font?.pointSize, 0.5, "Positive effective sizes must not be clamped")
            XCTAssertTrue(field.text == "AAAAA", "Native field must retain its text")
            XCTAssertEqual(writes, before)
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
        // Exclude insertion/selection chrome from the black-glyph pixel oracle.
        field.tintColor = .systemBlue
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
        let fieldBottom = min(image.height, Int(ceil(field.convert(field.bounds, to: surface).maxY)))
        func inkRows(_ range: Range<Int>) -> [Int] {
            (0..<fieldBottom).filter { y in
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

    private final class NativeFixtureState {
        let input: NativeExperienceTextInput
        var text: String
        init(_ input: NativeExperienceTextInput) { self.input = input; text = input.value }
    }
    private var nativeFixtures: [ObjectIdentifier: NativeFixtureState] = [:]

    private func bindNativeFixture(_ bridge: ExperienceTextInputOverlayBridge, screenID: String,
        renderPlan: NativeExperienceRenderPlan, surfaceView: UIView, artboardBounds: CGRect,
        textWriter: @escaping (_ inputID: String, _ text: String, _ completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void) -> Void) {
        let state = NativeFixtureState(renderPlan.textInputs[0])
        nativeFixtures[ObjectIdentifier(bridge)] = state
        bridge.bind(screenID: screenID, renderPlan: renderPlan, surfaceView: surfaceView, artboardBounds: artboardBounds,
            semanticTextWriter: { _, target, text, done in
                textWriter(target.inputID, text) { result in
                    switch result {
                    case .success: state.text = text; done(.accepted)
                    case .failure: done(.rejected)
                    }
                }
            }, semanticTextReader: { _, _, done in done(.success(.init(text: state.text))) })
    }

    /// Literal geometry fixtures supply native occurrences, never identities from a published text run.
    private func updateNativeFixture(_ bridge: ExperienceTextInputOverlayBridge, frame: ExperienceInteractiveTextFrame) {
        bridge.update(frame: frame)
        guard let state = nativeFixtures[ObjectIdentifier(bridge)] else { return XCTFail("Missing native fixture") }
        let input = state.input
        let secure = input.secureTextEntry == true
        let geometry: NuxieNativeTextRunGeometry?
        if case .captured(let entries) = frame.geometry { geometry = entries["run"] } else { geometry = nil }
        let nodes: [NuxieNativeSemanticNode] = geometry.map { _ in [.init(id: 1, parentID: nil, siblingIndex: 0,
            role: NuxieNativeSemanticRole.textField.rawValue, stateFlags: secure ? NuxieNativeSemanticNode.obscured : 0,
            traitFlags: 0, headingLevel: 0, actions: 0, bounds: .zero, label: "Input", value: "", hint: "")] } ?? []
        let occurrences: [NuxieNativeInputOccurrence] = geometry.map { [.init(nodeID: 1, geometry: .init(
            renderRevision: $0.renderRevision, worldTransform: $0.contentTransform, textBounds: $0.textBounds,
            layout: $0.layout, firstBaseline: $0.firstBaseline, obscured: secure, multiline: input.multiline == true))] } ?? []
        do {
            _ = bridge.applySemantics(.init(id: UUID(), tree: try .init(renderRevision: 1, treeVersion: 1, nodes: nodes),
                fieldsByTextRun: [:], nativeInputs: [input.textInputName: occurrences]))
        } catch { XCTFail("Literal native geometry fixture must be valid") }
    }

    private func plan(_ item: Fixture.Case, text: String, prefix: String = "", multiline: Bool = true, secure: Bool = false, systemWeight: String? = nil) -> NativeExperienceRenderPlan {
        let input = NativeExperienceTextInput(inputId: "input", screenId: "screen", artboardId: "a",
            viewNodeId: "v", renderedNodeId: "r", textInputName: "native-field", value: text, placeholder: nil, editable: true,
            geometry: .init(xPath: "\(prefix)x", yPath: "\(prefix)y", widthPath: "\(prefix)w", heightPath: "\(prefix)h", rotationPath: "\(prefix)r",
                scaleXPath: "\(prefix)sx", scaleYPath: "\(prefix)sy"),
            style: .init(fontFamily: systemWeight == nil ? "system" : "System", fontWeight: systemWeight ?? "normal", fontStyle: "normal", fontSize: item.fontSize,
                lineHeight: item.lineHeight, letterSpacing: 0, color: 0, fontAssetUniqueName: systemWeight == nil ? "" : "system-1", textAlign: nil),
            keyboardType: nil, secureTextEntry: secure, multiline: multiline, maxLength: nil, responseFieldKey: "answer")
        return NativeExperienceRenderPlan(identity: .init(experienceId: "e", buildId: "b", appId: "a", environment: "test"),
            scene: .init(key: "scene", sha256: "", sizeBytes: 0), entry: .init(screenId: "screen"),
            screens: [], transitions: [], textInputs: [input], images: [], fonts: [],
            systemFonts: systemWeight.map { [.init(authoredAssetId: 1, assetUniqueName: "system-1", weight: $0, style: "normal")] } ?? [])
    }
}
#endif
