#if canImport(UIKit)
import UIKit
import QuartzCore
import XCTest
@testable import Nuxie
@testable import NuxieRuntime

@MainActor
final class ExperienceTextInputSemanticsTests: XCTestCase {
    func testPortableResponseCaptureContract() throws {
        struct Vector: Decodable {
            let name: String
            let mode: NativeExperienceTextInput.ResponseCapture?
            let text: String
            let secure: Bool
            let source: ScreenEmissionValue?
            let expected: ScreenEmissionValue?
            let rejected: Bool?
        }
        struct Fixture: Decodable { let cases: [Vector] }
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/journeys/planes/text-input-response-capture.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: path))
        for vector in fixture.cases {
            var input = makePlan(secure: vector.secure).textInputs[0]
            input.responseCapture = vector.mode
            var values: [ExperienceInteractiveViewModelSnapshot.Value] = [
                .init(ownerInstanceID: 1, propertyIndex: 0, name: "response", value: .referencedInstance(2)),
                .init(ownerInstanceID: 2, propertyIndex: 0, name: "values", value: .referencedInstance(3)),
            ]
            if let source = vector.source {
                let native: ExperienceInteractiveViewModelValue
                switch source {
                case .number(let value): native = .number(Float(value))
                case .string(let value): native = .bytes(Data(value.utf8))
                case .bool(let value): native = .bool(value)
                default: throw ExperienceInteractiveScreenError.stateContract("Unsupported fixture value")
                }
                values.append(.init(ownerInstanceID: 3, propertyIndex: 0, name: "name", value: native))
            }
            let snapshot = ExperienceInteractiveViewModelSnapshot(rootInstanceID: 1, instances: [], values: values)
            if vector.rejected == true {
                XCTAssertThrowsError(try ExperienceScreenViewController.responseSetDraft(for: input, text: vector.text, snapshot: snapshot), vector.name)
            } else {
                XCTAssertEqual(try ExperienceScreenViewController.responseSetDraft(for: input, text: vector.text, snapshot: snapshot),
                               .responseSet(field: "name", value: try XCTUnwrap(vector.expected)), vector.name)
            }
        }
    }

    func testConvertedResponseUsesTypedSourceInsteadOfDisplayedText() throws {
        var input = makePlan().textInputs[0]
        input.responseCapture = .binding
        let snapshot = ExperienceInteractiveViewModelSnapshot(rootInstanceID: 1, instances: [], values: [
            .init(ownerInstanceID: 1, propertyIndex: 0, name: "response", value: .referencedInstance(2)),
            .init(ownerInstanceID: 2, propertyIndex: 0, name: "values", value: .referencedInstance(3)),
            .init(ownerInstanceID: 3, propertyIndex: 0, name: "name", value: .number(0.5)),
        ])
        XCTAssertEqual(try ExperienceScreenViewController.responseSetDraft(for: input, text: "50", snapshot: snapshot),
                       .responseSet(field: "name", value: .number(0.5)))
        XCTAssertThrowsError(try ExperienceScreenViewController.responseSetDraft(for: input, text: "50"),
                             "Missing converted state must not silently become a raw string")
    }

    func testOrdinaryAndSecureResponseCaptureKeepAcceptedText() throws {
        for secure in [false, true] {
            let input = makePlan(secure: secure).textInputs[0]
            XCTAssertEqual(try ExperienceScreenViewController.responseSetDraft(for: input, text: "accepted"),
                           .responseSet(field: "name", value: .string("accepted")))
        }
    }

    func testConvertedResponseRejectsInvalidStateWithoutFallingBackToText() throws {
        var input = makePlan().textInputs[0]
        input.responseCapture = .binding
        func snapshot(_ value: ExperienceInteractiveViewModelValue) -> ExperienceInteractiveViewModelSnapshot {
            .init(rootInstanceID: 1, instances: [], values: [
                .init(ownerInstanceID: 1, propertyIndex: 0, name: "response", value: .referencedInstance(2)),
                .init(ownerInstanceID: 2, propertyIndex: 0, name: "values", value: .referencedInstance(3)),
                .init(ownerInstanceID: 3, propertyIndex: 0, name: "name", value: value),
            ])
        }
        let rejected: [ExperienceInteractiveViewModelValue] = [.number(.nan), .number(.infinity), .bytes(Data([0xff])), .unsupported, .referencedInstance(4)]
        for value in rejected {
            XCTAssertThrowsError(try ExperienceScreenViewController.responseSetDraft(for: input, text: "raw", snapshot: snapshot(value)))
        }
        let accepted: [(ExperienceInteractiveViewModelValue, ScreenEmissionValue)] = [
            (.bool(false), .bool(false)), (.bytes(Data("normalized".utf8)), .string("normalized")),
        ]
        for (value, expected) in accepted {
            XCTAssertEqual(try ExperienceScreenViewController.responseSetDraft(for: input, text: "raw", snapshot: snapshot(value)),
                           .responseSet(field: "name", value: expected))
        }
        let valid = snapshot(.number(0.5))
        let ambiguous = ExperienceInteractiveViewModelSnapshot(rootInstanceID: 1, instances: [], values: valid.values + [valid.values[2]])
        XCTAssertThrowsError(try ExperienceScreenViewController.responseSetDraft(for: input, text: "raw", snapshot: ambiguous))
        var secure = makePlan(secure: true).textInputs[0]
        secure.responseCapture = .binding
        XCTAssertThrowsError(try ExperienceScreenViewController.responseSetDraft(for: secure, text: "secret", snapshot: valid))
    }

    func testAuthoredInputActionChoosesOneEventAndUsesAcceptedValue() throws {
        for selectedEvent in [ExperienceTextInputEventKind.editingEnded, .returnPressed] {
            var input = makePlan().textInputs[0]
            input.actionEvent = selectedEvent
            input.declarativeActionId = "save-name"
            let events: [ExperienceTextInputEvent] = [
                .init(kind: .returnPressed, text: "Alice"),
                .init(kind: .editingEnded, text: "Alice"),
            ]
            XCTAssertEqual(events.compactMap { input.declarativeInvocation(for: $0) }, [
                .init(actionId: "save-name", value: .string("Alice"), componentId: "v"),
            ])
            input.declarativeActionId = nil
            XCTAssertTrue(events.compactMap { input.declarativeInvocation(for: $0) }.isEmpty)
        }
        var defaultInput = makePlan().textInputs[0]
        defaultInput.declarativeActionId = "save-name"
        XCTAssertNil(defaultInput.declarativeInvocation(for: .init(kind: .returnPressed, text: "Alice")))
        XCTAssertNotNil(defaultInput.declarativeInvocation(for: .init(kind: .editingEnded, text: "Alice")))
    }

    func testMultilineReturnInsertsNewlineWithoutAnEditingEvent() throws {
        let bridge = ExperienceTextInputOverlayBridge()
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        var values: [String] = []
        var events: [ExperienceTextInputEvent] = []
        bridge.onAcceptedTextChange = { _, text in values.append(text) }
        bridge.onEditingEvent = { _, event in events.append(event) }
        bridge.bind(screenID: "screen", renderPlan: makePlan(multiline: true), surfaceView: view, artboardBounds: view.bounds,
            semanticTextWriter: { _, _, _, done in done(.accepted) },
            textWriter: { _, _, _ in XCTFail("Expected semantic writer") })
        let textView = try XCTUnwrap(view.subviews.compactMap { $0 as? UITextView }.first)
        presentField(on: bridge)
        _ = bridge.applySemantics(try capture(flags: 0))
        XCTAssertTrue(bridge.textView(textView, shouldChangeTextIn: NSRange(location: 5, length: 0), replacementText: "\n"))
        textView.text = "saved\n"
        bridge.textViewDidChange(textView)
        XCTAssertEqual(values, ["saved\n"])
        XCTAssertTrue(events.isEmpty)
        bridge.textViewDidEndEditing(textView)
        XCTAssertEqual(events, [.init(kind: .editingEnded, text: "saved\n")])
        bridge.clear()
    }

    func testNativeTypingReturnAndEndEditingAreSeparateEvents() throws {
        let bridge = ExperienceTextInputOverlayBridge()
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        var values: [String] = []
        var events: [ExperienceTextInputEvent] = []
        bridge.onAcceptedTextChange = { _, text in values.append(text) }
        bridge.onEditingEvent = { _, event in events.append(event) }
        bridge.bind(screenID: "screen", renderPlan: makePlan(), surfaceView: view, artboardBounds: view.bounds,
            semanticTextWriter: { _, _, _, done in done(.accepted) },
            textWriter: { _, _, _ in XCTFail("Expected semantic writer") })
        let field = try XCTUnwrap(view.subviews.compactMap { $0 as? UITextField }.first)
        presentField(on: bridge)
        _ = bridge.applySemantics(try capture(flags: 0))
        field.text = "Alice"
        let action = try XCTUnwrap(field.actions(forTarget: bridge, forControlEvent: .editingChanged)?.first)
        _ = bridge.perform(NSSelectorFromString(action), with: field)
        XCTAssertEqual(values, ["Alice"], "Capture must not wait for blur or Return")
        XCTAssertTrue(events.isEmpty)
        _ = bridge.textFieldShouldReturn(field)
        XCTAssertEqual(events, [.init(kind: .returnPressed, text: "Alice")])
        bridge.textFieldDidEndEditing(field)
        XCTAssertEqual(events, [.init(kind: .returnPressed, text: "Alice"), .init(kind: .editingEnded, text: "Alice")])
        XCTAssertEqual(values, ["Alice"], "Ending editing does not repeat the value change")
        bridge.clear()
    }

    func testDisabledSemanticFieldRejectsLateEditsAndRestoresEditing() throws {
        let plan = makePlan()
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let bridge = ExperienceTextInputOverlayBridge()
        var writes: [String] = []
        var commits: [String] = []
        bridge.onAcceptedTextChange = { _, text in commits.append(text) }
        bridge.bind(screenID: "screen", renderPlan: plan, surfaceView: view, artboardBounds: view.bounds) { _, text, done in
            writes.append(text); done(.success(()))
        }
        let field = try XCTUnwrap(view.subviews.compactMap { $0 as? UITextField }.first)
        XCTAssertTrue(field.isHidden, "A bound field has no presented placement yet")
        XCTAssertFalse(field.isEnabled, "Geometry admission precedes editing")
        presentField(on: bridge)
        let mapped = bridge.applySemantics(try capture(flags: NuxieNativeSemanticNode.disabled))
        XCTAssertTrue(mapped[1] === field)
        XCTAssertEqual(field.accessibilityLabel, "Your name")
        XCTAssertFalse(field.isEnabled)
        XCTAssertFalse(bridge.textField(field, shouldChangeCharactersIn: NSRange(location: 0, length: 0), replacementString: "late"))
        field.text = "late"
        field.sendActions(for: .editingChanged)
        bridge.flushTextChange(for: field)
        XCTAssertEqual(field.text, "saved")
        XCTAssertEqual(writes, ["saved"])
        XCTAssertTrue(commits.isEmpty)
        _ = bridge.applySemantics(try capture(flags: 0))
        XCTAssertTrue(field.isEnabled)
        field.text = "accepted"
        field.sendActions(for: .editingChanged)
        bridge.flushTextChange(for: field)
        XCTAssertEqual(commits, ["accepted"])
        XCTAssertEqual(writes.last, "accepted")
        _ = bridge.applySemantics(try capture(flags: NuxieNativeSemanticNode.readOnly))
        XCTAssertTrue(field.isEnabled, "Read-only controls retain native interaction")
        XCTAssertFalse(bridge.textField(field, shouldChangeCharactersIn: NSRange(location: 0, length: 0), replacementString: "blocked"))
        field.text = "blocked"
        bridge.flushTextChange(for: field)
        XCTAssertEqual(field.text, "accepted")
        XCTAssertEqual(commits, ["accepted"])
        _ = bridge.applySemantics(try capture(flags: NuxieNativeSemanticNode.hidden))
        XCTAssertTrue(field.isHidden)
        XCTAssertFalse(field.isEnabled)
        bridge.clear()
    }

    func testNativeFieldStateLabelsPreserveNativeValuesAndAuthoredInputName() throws {
        for (secure, multiline) in [(false, false), (true, false), (false, true)] {
            let bridge = ExperienceTextInputOverlayBridge()
            let view = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
            bridge.bind(screenID: "screen", renderPlan: makePlan(secure: secure, multiline: multiline),
                surfaceView: view, artboardBounds: view.bounds) { _, _, done in done(.success(())) }
            presentField(on: bridge)
            let obscured = secure ? NuxieNativeSemanticNode.obscured : 0
            let initial = bridge.applySemantics(try capture(flags: obscured))
            let control = try XCTUnwrap(initial[1])
            let nativeValue = control.accessibilityValue
            let flags = obscured | NuxieNativeSemanticNode.required | NuxieNativeSemanticNode.readOnly
            let updated = bridge.applySemantics(try capture(flags: flags))
            XCTAssertTrue(updated[1] === control)
            XCTAssertEqual(control.accessibilityLabel, "Your name, Required, Read only")
            XCTAssertEqual(control.accessibilityUserInputLabels, ["Your name"])
            XCTAssertEqual(control.accessibilityValue, nativeValue, "State must not replace native or secure text values")
            if let field = control as? UITextField {
                XCTAssertEqual(field.text, "saved")
                XCTAssertFalse(bridge.textField(field, shouldChangeCharactersIn: NSRange(location: 0, length: 0), replacementString: "blocked"))
            } else {
                let textView = try XCTUnwrap(control as? UITextView)
                XCTAssertEqual(textView.text, "saved")
                XCTAssertFalse(textView.isEditable)
            }
            _ = bridge.applySemantics(try capture(flags: obscured))
            XCTAssertEqual(control.accessibilityLabel, "Your name", "Removed state must not linger")
            XCTAssertEqual(control.accessibilityValue, nativeValue)
            bridge.clear()
        }
    }

    func testSemanticWritesCoalesceRetryAndCommitOnlyAcceptedText() throws {
        let bridge = ExperienceTextInputOverlayBridge()
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        var pending: [(UUID, String, @MainActor @Sendable (ExperienceSemanticTextDraft.Outcome) -> Void)] = []
        var commits: [String] = []
        bridge.onAcceptedTextChange = { _, text in commits.append(text) }
        bridge.bind(screenID: "screen", renderPlan: makePlan(), surfaceView: view, artboardBounds: view.bounds,
            semanticTextWriter: { id, _, text, done in
                pending.append((id, text, done))
            },
            textWriter: { _, _, _ in XCTFail("Semantic editor used unrestricted writer") })
        let field = try XCTUnwrap(view.subviews.compactMap { $0 as? UITextField }.first)
        presentField(on: bridge)
        XCTAssertTrue(pending.isEmpty)
        _ = bridge.applySemantics(try capture(flags: 0))
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].1, "saved")
        pending.removeFirst().2(.accepted)
        XCTAssertFalse(field.isHidden)
        XCTAssertTrue(field.isEnabled)
        field.text = "A"
        XCTAssertEqual(field.text, "A")
        let action = try XCTUnwrap(field.actions(forTarget: bridge, forControlEvent: .editingChanged)?.first)
        #if NUXIE_HOSTED_INPUT_TESTS
        // A real application dispatcher exercises the registered UIKit action.
        field.sendActions(for: .editingChanged)
        #else
        // The ordinary unit target has TEST_HOST="" and no application dispatcher.
        _ = bridge.perform(NSSelectorFromString(action), with: field)
        #endif
        XCTAssertEqual(pending.count, 1, "First editor change must reach the writer")
        field.text = "Alice"
        field.sendActions(for: .editingChanged)
        bridge.flushTextChange(for: field)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].1, "A")
        XCTAssertTrue(commits.isEmpty)
        pending.removeFirst().2(.staleCapture)
        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(field.text, "Alice")
        let replacement = try capture(flags: 0)
        _ = bridge.applySemantics(replacement)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].0, replacement.id)
        XCTAssertEqual(pending[0].1, "Alice")
        pending.removeFirst().2(.accepted)
        XCTAssertEqual(commits, ["Alice"])
        field.text = "late"
        field.sendActions(for: .editingChanged)
        bridge.flushTextChange(for: field)
        _ = bridge.applySemantics(try capture(flags: NuxieNativeSemanticNode.disabled))
        XCTAssertEqual(field.text, "Alice")
        pending.removeFirst().2(.accepted)
        XCTAssertEqual(commits, ["Alice"])
        bridge.clear()
    }

    func testWithdrawalRejectsLateEditsAndReconcilesAnEscapedNativeWrite() throws {
        for hideOverlay in [true, false] {
            let bridge = ExperienceTextInputOverlayBridge()
            let view = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
            var pending: [(String, @MainActor @Sendable (ExperienceSemanticTextDraft.Outcome) -> Void)] = []
            var commits: [String] = []
            var nativeText = "saved"
            bridge.onAcceptedTextChange = { _, text in commits.append(text) }
            bridge.bind(screenID: "screen", renderPlan: makePlan(), surfaceView: view,
                artboardBounds: view.bounds,
                semanticTextWriter: { _, _, text, done in pending.append((text, done)) },
                textWriter: { _, _, _ in XCTFail("Semantic editor bypassed captured ownership") })
            presentField(on: bridge)
            _ = bridge.applySemantics(try capture(flags: 0))
            try XCTUnwrap(pending.first).1(.accepted)
            pending.removeAll()
            let field = try XCTUnwrap(view.subviews.compactMap { $0 as? UITextField }.first)
            field.text = "Alice"
            bridge.flushTextChange(for: field)
            let escaped = try XCTUnwrap(pending.first)
            pending.removeAll()
            if hideOverlay { bridge.setHidden(true) }
            else { view.isUserInteractionEnabled = false }
            // Native execution may finish after the outgoing screen loses interaction.
            nativeText = escaped.0
            escaped.1(.accepted)
            field.text = "late callback"
            bridge.flushTextChange(for: field)
            XCTAssertEqual(field.text, "saved")
            XCTAssertTrue(commits.isEmpty)
            XCTAssertTrue(pending.isEmpty)
            view.isUserInteractionEnabled = true
            bridge.setHidden(false)
            _ = bridge.applySemantics(try capture(flags: 0))
            let reconciliation = try XCTUnwrap(pending.first)
            XCTAssertEqual(reconciliation.0, "saved")
            nativeText = reconciliation.0
            reconciliation.1(.accepted)
            XCTAssertEqual(nativeText, "saved")
            XCTAssertTrue(commits.isEmpty)
            bridge.clear()
        }
    }

    func testSecureSemanticWriterReceivesNoPasswordButAcceptedResponseDoes() throws {
        let bridge = ExperienceTextInputOverlayBridge()
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        var writes: [String] = []
        var commits: [String] = []
        bridge.onAcceptedTextChange = { _, text in commits.append(text) }
        bridge.bind(screenID: "screen", renderPlan: makePlan(secure: true), surfaceView: view,
            artboardBounds: view.bounds,
            semanticTextWriter: { _, _, text, done in writes.append(text); done(.accepted) },
            textWriter: { _, _, _ in XCTFail("Semantic editor used unrestricted writer") })
        presentField(on: bridge)
        _ = bridge.applySemantics(try capture(flags: NuxieNativeSemanticNode.obscured))
        let field = try XCTUnwrap(view.subviews.compactMap { $0 as? UITextField }.first)
        XCTAssertTrue(field.isSecureTextEntry)
        field.text = "secret"
        field.sendActions(for: .editingChanged)
        bridge.flushTextChange(for: field)
        XCTAssertEqual(writes, ["", ""])
        XCTAssertEqual(commits, ["secret"])
        // UIKit may expose a masked value. Preserve its native secure semantics
        // without copying plaintext into the accessibility projection.
        let nativeSecureField = UITextField()
        nativeSecureField.isSecureTextEntry = true
        nativeSecureField.text = "secret"
        let exposedValue = field.accessibilityValue
        XCTAssertEqual(exposedValue, nativeSecureField.accessibilityValue)
        XCTAssertFalse(exposedValue?.contains("secret") ?? false)
        bridge.clear()
    }

    #if NUXIE_HOSTED_INPUT_TESTS
    func testMarkedTextDoesNotCommitResponseUntilConfirmed() throws {
        for multiline in [false, true] {
            let bridge = ExperienceTextInputOverlayBridge()
            let view = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
            var commits: [String] = []
            bridge.onAcceptedTextChange = { _, text in commits.append(text) }
            bridge.bind(screenID: "screen", renderPlan: makePlan(multiline: multiline),
                surfaceView: view, artboardBounds: view.bounds,
                semanticTextWriter: { _, _, _, done in done(.accepted) },
                textWriter: { _, _, _ in XCTFail("Semantic editor bypassed captured ownership") })
            presentField(on: bridge)
            _ = bridge.applySemantics(try capture(flags: 0))
            let editor = try XCTUnwrap(view.subviews.first as? (UIView & UITextInput))
            editor.selectedTextRange = editor.textRange(from: editor.endOfDocument, to: editor.endOfDocument)
            editor.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0))
            XCTAssertNotNil(editor.markedTextRange)
            bridge.flushTextChange(for: editor)
            XCTAssertTrue(commits.isEmpty, "An unfinished IME composition is not a response")
            editor.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0))
            editor.unmarkText()
            XCTAssertNil(editor.markedTextRange)
            bridge.flushTextChange(for: editor)
            XCTAssertEqual(commits, ["saved한"])
            bridge.clear()
        }
    }
    #endif

    #if NUXIE_HOSTED_INPUT_TESTS
    func testUIKitEditReachesCapturedNativeOwnerBeforeResponseCommit() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "semantic_text", withExtension: "riv"))
        let prepared = try await NuxieNativePreparedFile.prepare(bytes: Data(contentsOf: url), importMode: .portable)
        let artboards = try await prepared.artboards()
        let runtime = try await prepared.openSession(artboardName: XCTUnwrap(artboards.first).name,
            player: .defaultScene, pixelWidth: 64, pixelHeight: 64)
        defer { Task { try? await runtime.close() } }
        try await runtime.enableSemantics()
        _ = try await runtime.step(elapsedSeconds: 0)
        let layer = CAMetalLayer()
        layer.device = try await runtime.metalDevice().value
        layer.pixelFormat = .bgra8Unorm
        layer.drawableSize = CGSize(width: 64, height: 64)
        let drawable = try XCTUnwrap(layer.nextDrawable(), "Hosted native qualification requires a drawable")
        let outcome = try await runtime.render(drawable: .available(NuxieNativeDrawable(drawable)))
        XCTAssertEqual(outcome.disposition, .presented)
        let capture = try await runtime.captureSemantics(textRuns: ["field/名前"])
        let bridge = ExperienceTextInputOverlayBridge()
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let initialWrite = expectation(description: "Initial value admitted by captured native owner")
        let response = expectation(description: "Response committed after native write")
        var accepted: [String] = []
        var staleRetries = 0
        bridge.onAcceptedTextChange = { _, text in
            XCTAssertEqual(accepted.last, text)
            XCTAssertEqual(text, "Alice")
            response.fulfill()
        }
        bridge.bind(screenID: "screen", renderPlan: makePlan(textRunName: "field/名前"),
            surfaceView: view, artboardBounds: view.bounds,
            semanticTextWriter: { id, _, text, done in
                Task { @MainActor in
                    do {
                        _ = try await runtime.setSemanticTextRun(captureID: id, name: "field/名前", text: Data(text.utf8))
                        accepted.append(text)
                        done(.accepted)
                        if text == "saved" { initialWrite.fulfill() }
                    } catch NuxieNativeRuntimeError.callFailed(let diagnostic)
                        where diagnostic.status == .handleMismatch {
                        staleRetries += 1
                        done(.staleCapture)
                        // Drive the new frame requested by the production presentation FIFO.
                        do {
                            _ = try await runtime.step(elapsedSeconds: 0)
                            let nextDrawable = try XCTUnwrap(layer.nextDrawable())
                            let next = try await runtime.render(drawable: .available(NuxieNativeDrawable(nextDrawable)))
                            XCTAssertEqual(next.disposition, .presented)
                            let replacement = try await runtime.captureSemantics(textRuns: ["field/名前"])
                            _ = bridge.applySemantics(replacement)
                        } catch {
                            XCTFail("Replacement native presentation failed: \(error)")
                        }
                    } catch {
                        XCTFail("Captured native write failed: \(error)")
                        done(.rejected)
                    }
                }
            }, textWriter: { _, _, _ in XCTFail("Semantic editor bypassed captured ownership") })
        presentField(on: bridge, textRunName: "field/名前")
        _ = bridge.applySemantics(capture)
        await fulfillment(of: [initialWrite], timeout: 3)
        let field = try XCTUnwrap(view.subviews.compactMap { $0 as? UITextField }.first)
        field.text = "Alice"
        field.sendActions(for: .editingChanged)
        bridge.flushTextChange(for: field)
        XCTAssertEqual(accepted, ["saved"], "Native executor has not accepted the queued edit synchronously")
        await fulfillment(of: [response], timeout: 3)
        XCTAssertEqual(accepted, ["saved", "Alice"])
        XCTAssertEqual(staleRetries, 1)
        let changed = try await runtime.setTextRuns([
            NuxieNativeTextRunMutation(name: "field/名前", text: Data("Alice".utf8))
        ])
        XCTAssertFalse(changed, "The response value must already be present in the actual native text run")
        bridge.clear()
        try await runtime.close()
    }
    #endif

    /// These tests isolate semantic ownership; geometry is an explicit frame fixture.
    private func presentField(on bridge: ExperienceTextInputOverlayBridge, textRunName: String = "run") {
        bridge.update(frame: .init(snapshot: .init(rootInstanceID: 1, instances: [], values: []),
            geometry: .captured([textRunName: .init(renderRevision: 1,
                worldTransform: .identity, contentTransform: .identity, textBounds: .zero,
                layout: .init(transform: .identity, bounds: CGRect(x: 0, y: 0, width: 100, height: 40)),
                firstBaseline: nil)])))
    }

    private func makePlan(secure: Bool? = nil, textRunName: String = "run", multiline: Bool? = nil) -> NativeExperienceRenderPlan {
        let input = NativeExperienceTextInput(inputId: "input", screenId: "screen", artboardId: "a",
            viewNodeId: "v", renderedNodeId: "r", textObjectKey: "text", textRunObjectKey: "run",
            textName: "text", textRunName: textRunName, value: "saved", placeholder: "Name", editable: true,
            geometry: .init(xPath: "x", yPath: "y", widthPath: "w", heightPath: "h", rotationPath: "r",
                scaleXPath: "sx", scaleYPath: "sy"),
            style: .init(fontFamily: "system", fontWeight: "normal", fontStyle: "normal", fontSize: 16,
                lineHeight: 20, letterSpacing: 0, color: 0, fontAssetUniqueName: "", textAlign: nil),
            keyboardType: nil, secureTextEntry: secure, multiline: multiline, maxLength: nil, responseFieldKey: "name")
        let plan = NativeExperienceRenderPlan(identity: .init(experienceId: "e", buildId: "b", appId: "a", environment: "test"),
            scene: .init(key: "scene", sha256: "", sizeBytes: 0), entry: .init(screenId: "screen"),
            screens: [], transitions: [], textInputs: [input], images: [], fonts: [])
        return plan
    }

    private func capture(flags: UInt32) throws -> NuxieNativeSemanticCapture {
        let node = NuxieNativeSemanticNode(id: 1, parentID: nil, siblingIndex: 0,
            role: NuxieNativeSemanticRole.textField.rawValue, stateFlags: flags, traitFlags: 0,
            headingLevel: 0, actions: 0, bounds: .zero, label: "Your name", value: "", hint: "Enter name")
        return NuxieNativeSemanticCapture(id: UUID(), tree: try NuxieNativeSemanticTree(
            renderRevision: 1, treeVersion: 1, nodes: [node]), fieldsByTextRun: ["run": node])
    }
}
#endif
