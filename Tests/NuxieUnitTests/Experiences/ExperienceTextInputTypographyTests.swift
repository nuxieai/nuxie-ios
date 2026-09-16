#if canImport(UIKit)
import UIKit
import XCTest
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

    private func plan(_ item: Fixture.Case, text: String, prefix: String = "") -> NativeExperienceRenderPlan {
        let input = NativeExperienceTextInput(inputId: "input", screenId: "screen", artboardId: "a",
            viewNodeId: "v", renderedNodeId: "r", riveTextObjectKey: "text", riveTextRunObjectKey: "run",
            riveTextName: "text", riveTextRunName: "run", value: text, placeholder: nil, editable: true,
            geometry: .init(xPath: "\(prefix)x", yPath: "\(prefix)y", widthPath: "\(prefix)w", heightPath: "\(prefix)h", rotationPath: "\(prefix)r",
                scaleXPath: "\(prefix)sx", scaleYPath: "\(prefix)sy"),
            style: .init(fontFamily: "system", fontWeight: "normal", fontStyle: "normal", fontSize: item.fontSize,
                lineHeight: item.lineHeight, letterSpacing: 0, color: 0, fontAssetRiveUniqueName: "", textAlign: nil),
            keyboardType: nil, secureTextEntry: false, multiline: true, maxLength: nil, responseFieldKey: "answer")
        return NativeExperienceRenderPlan(identity: .init(experienceId: "e", buildId: "b", appId: "a", environment: "test"),
            scene: .init(key: "scene", sha256: "", sizeBytes: 0), entry: .init(screenId: "screen"),
            screens: [], transitions: [], textInputs: [input], images: [], fonts: [])
    }
}
#endif
