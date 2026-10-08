#if canImport(UIKit)
import UIKit
import QuartzCore
import Metal
import OSLog
import XCTest
@testable import Nuxie
@testable import NuxieRuntime
#if NUXIE_HOSTED_INPUT_TESTS
@testable import NuxieTestSupport
#endif

@MainActor
final class ExperienceTextInputSemanticsTests: XCTestCase {
    #if NUXIE_HOSTED_INPUT_TESTS
    func testQualifiedSecureInputKeepsTextOutOfSemanticsAndSDKLogs() async throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/runtime/text-editing-experiment")
        let payload = try await ExperienceInputFixture.payload(defaultViewModelName: nil,
            scene: Data(contentsOf: directory.appendingPathComponent("text_input_secure_observed.riv")),
            artboardName: "Text Input - Multiline", semantics: true)
        let preparation = try await ExperienceInteractivePreparation.prepare(payload: payload)
        let run = ExperienceRunValues()
        addTeardownBlock { await run.retire() }
        let screen = try await preparation.openScreen(runValues: run, pixelWidth: 393, pixelHeight: 852)
        addTeardownBlock { try await screen.close() }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        let field = UITextField(frame: CGRect(x: 20, y: 40, width: 300, height: 40))
        field.isSecureTextEntry = true
        controller.view.addSubview(field)
        XCTAssertTrue(field.becomeFirstResponder())
        let secret = UUID().uuidString
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let position = store.position(date: Date())
        NuxieLogger.shared.configure(logLevel: .verbose, enableConsoleLogging: true, redactSensitiveData: false)
        defer { NuxieLogger.shared.configure(logLevel: .debug, enableConsoleLogging: true, redactSensitiveData: true) }
        field.insertText(secret)
        XCTAssertTrue(field.text == secret, "The native secure control must retain the typed text")
        try await screen.enableSemantics()
        let layer = CAMetalLayer()
        layer.device = try await screen.metalDevice().value
        layer.pixelFormat = .bgra8Unorm
        layer.drawableSize = CGSize(width: 393, height: 852)
        func renderCapture() async throws -> NuxieNativeSemanticCapture {
            let drawable = try XCTUnwrap(layer.nextDrawable())
            let frame = try await screen.renderFrame(layoutScaleFactor: 1,
                drawable: ExperienceInteractiveDrawable(drawable), capturesSemantics: true)
            return try XCTUnwrap(frame.semantics)
        }
        _ = try await screen.step(elapsedSeconds: 0)
        _ = try await renderCapture()
        let focused = try await screen.step(focusInputs: [.next], elapsedSeconds: 0.016)
        XCTAssertEqual(focused.focusState?.hasFocus, true)
        _ = try await renderCapture()
        _ = try await screen.step(focusInputs: [
            .key(code: 65, modifiers: 8, pressed: true, repeated: false),
            .key(code: 259, modifiers: 0, pressed: true, repeated: false)], elapsedSeconds: 0.016)
        _ = try await renderCapture()
        _ = try await screen.step(focusInputs: [.text(try XCTUnwrap(field.text))], elapsedSeconds: 0.016)
        let capture = try await renderCapture()
        let node = try XCTUnwrap(capture.tree.nodes.first { $0.role == NuxieNativeSemanticRole.textField.rawValue })
        XCTAssertTrue(node.stateFlags & NuxieNativeSemanticNode.obscured != 0)
        XCTAssertFalse(capture.containsNativeObscuredValue, "The native semantic capture must omit obscured values before SDK redaction")
        XCTAssertFalse(String(describing: capture.tree).contains(secret), "Secure text must be absent from the entire semantic capture")
        let current = try await screen.readPresentedFieldString(captureID: capture.id, nodeID: node.id, name: "experiment-input")
        XCTAssertTrue(current == secret, "The qualified narrow read must retain the typed text")
        let marker = "Secure boundary " + UUID().uuidString
        LogError("\(marker, privacy: .publicValue)")
        var messages: [String] = []
        let deadline = Date().addingTimeInterval(5)
        repeat {
            messages = try store.getEntries(at: position).compactMap { entry in
                guard let entry = entry as? OSLogEntryLog, entry.subsystem == "io.nuxie.sdk" else { return nil }
                return entry.composedMessage
            }
            if messages.contains(where: { $0.contains(marker) }) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        } while Date() < deadline
        XCTAssertTrue(messages.contains { $0.contains(marker) }, "SDK log capture must be active")
        XCTAssertFalse(messages.contains { $0.contains(secret) }, "Secure text must not enter SDK log output")
    }

    func testPublishedInputLocatorReadsFocusedOccurrence() async throws {
        let expected = try PublishedInputFixture.expectations()
        let preparation = try await ExperienceInteractivePreparation.prepare(payload:
            SharedValuesFixture.payload(directory: PublishedInputFixture.directory, screens: expected.screens))
        let run = ExperienceRunValues()
        addTeardownBlock { await run.retire() }
        let screen = try await preparation.openScreen(screenID: "input", runValues: run, pixelWidth: 393, pixelHeight: 852)
        addTeardownBlock { try await screen.close() }
        try await screen.enableSemantics()
        _ = try await screen.step(focusInputs: [.next], elapsedSeconds: 0)
        let table = try JSONSerialization.jsonObject(with: Data(contentsOf:
            PublishedInputFixture.directory.appendingPathComponent("text-inputs.json"))) as? [[String: Any]]
        let locator = try XCTUnwrap(table?.first?["textInputName"] as? String)
        let layer = CAMetalLayer()
        layer.device = try await screen.metalDevice().value
        layer.pixelFormat = .bgra8Unorm
        layer.drawableSize = CGSize(width: 393, height: 852)
        let drawable = try XCTUnwrap(layer.nextDrawable())
        let frame = try await screen.renderFrame(layoutScaleFactor: 1,
            drawable: ExperienceInteractiveDrawable(drawable), capturesSemantics: true)
        let capture = try XCTUnwrap(frame.semantics)
        let fields = capture.tree.nodes.filter { $0.role == NuxieNativeSemanticRole.textField.rawValue }
        XCTAssertEqual(fields.count, 1)
        let occurrence = try XCTUnwrap(fields.first)
        XCTAssertEqual(occurrence.stateFlags & (NuxieNativeSemanticNode.hidden | NuxieNativeSemanticNode.disabled), 0)
        let text = try await screen.readPresentedFieldString(captureID: capture.id,
            nodeID: occurrence.id, name: locator)
        XCTAssertEqual(text, expected.startingValues.name,
            "Seed from the delivered TextInput locator, not the table's empty value")
    }

    func testNativeBeginEditingFocusesPublishedInput() async throws {
        let directory = PublishedInputFixture.directory.deletingLastPathComponent().appendingPathComponent("typing-probes")
        let input = NativeExperienceTextInput(inputId: "name", screenId: "input", artboardId: "input",
            viewNodeId: "scr_screens_sinput::v2", renderedNodeId: "scr_screens_sinput::v2",
            textInputName: "scr_screens_sinput::v2 editable value", value: "", placeholder: nil, editable: true,
            geometry: .init(xPath: "x", yPath: "y", widthPath: "w", heightPath: "h", rotationPath: "r", scaleXPath: "sx", scaleYPath: "sy"),
            style: .init(fontFamily: "System", fontWeight: "400", fontStyle: "normal", fontSize: 16,
                lineHeight: -1, letterSpacing: 0, color: 0xFF111827,
                fontAssetUniqueName: "font-system-400-normal-6cda3de3-0", textAlign: "left"),
            keyboardType: nil, secureTextEntry: false, multiline: false, maxLength: nil, responseFieldKey: nil)
        let payload = try SharedValuesFixture.payload(directory: PublishedInputFixture.directory, screens: ["input"],
            scene: Data(contentsOf: directory.appendingPathComponent("f3-field-in-flow.riv")), textInputs: [input])
        let probe = InputStepProbe()
        let controller = try ExperienceInputFixture.makeController(payload, probe: probe,
            fixtureName: "f3-field-in-flow", directory: directory)
        var latestCapture: NuxieNativeSemanticCapture?
        controller.onSemanticCapture = { latestCapture = $0 }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await controller.mountInteractiveScreen()
        await controller.enter(reduceMotion: true)
        await controller.activate(reduceMotion: true)
        func settle() async throws {
            controller.advance(delta: 0.016)
            let deadline = Date().addingTimeInterval(5)
            while !controller.hasCompletedLatestFrame, Date() < deadline {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            if let failure = probe.failure { throw failure }
            XCTAssertTrue(controller.hasCompletedLatestFrame)
        }
        func findField(_ view: UIView) -> UITextField? {
            (view as? UITextField) ?? view.subviews.lazy.compactMap { findField($0) }.first
        }
        do {
            try await settle()
            let field = try XCTUnwrap(findField(controller.view))
            XCTAssertEqual(field.text, "Ada")
            XCTAssertTrue(field.becomeFirstResponder())
            try await settle()
            XCTAssertTrue(controller.riveFocusState.hasFocus, "Native begin editing must focus Rive")
            XCTAssertTrue(controller.riveFocusState.expectsKeyboardInput)
            let focusedSnapshot = try await controller.runtimeSnapshot()
            XCTAssertEqual(focusedSnapshot.values.first { $0.name == "focused" }?.value, .number(1))
            XCTAssertEqual(focusedSnapshot.values.first { $0.name == "typed" }?.value, .number(0))
            var callbacks: [String] = []
            field.addAction(UIAction { _ in
                callbacks.append("text=\(field.text ?? ""), marked=\(field.markedTextRange != nil)")
            }, for: .editingChanged)
            func verify(_ expected: String) async throws {
                try await settle()
                let snapshot = try await controller.runtimeSnapshot()
                XCTAssertEqual(snapshot.values.first { $0.name == "name" }?.value, .bytes(Data(expected.utf8)))
                let capture = try XCTUnwrap(latestCapture)
                let occurrence = try XCTUnwrap(capture.nativeInputs[input.textInputName]?.first)
                let actual = try await controller.readPresentedFieldString(captureID: capture.id,
                    nodeID: occurrence.nodeID, name: input.textInputName)
                XCTAssertEqual(actual, expected)
                XCTAssertEqual(field.text, expected)
            }
            field.selectedTextRange = field.textRange(from: field.beginningOfDocument, to: field.endOfDocument)
            field.insertText("Grace")
            try await verify("Grace")
            field.selectedTextRange = field.textRange(from: field.beginningOfDocument, to: field.endOfDocument)
            field.insertText("")
            try await verify("")
            field.insertText("👍🏽")
            try await verify("👍🏽")
            field.selectedTextRange = field.textRange(from: field.beginningOfDocument, to: field.endOfDocument)
            field.setMarkedText("ぐれ", selectedRange: NSRange(location: 2, length: 0))
            field.sendActions(for: .editingChanged)
            try await verify("ぐれ")
            XCTContext.runActivity(named: "A0 native composition decorations, nonsecure") { activity in
                let image = UIGraphicsImageRenderer(bounds: field.bounds).image { _ in
                    field.drawHierarchy(in: field.bounds, afterScreenUpdates: true)
                }
                let attachment = XCTAttachment(image: image)
                attachment.lifetime = .keepAlways
                activity.add(attachment)
            }
            field.insertText("グレース")
            field.sendActions(for: .editingChanged)
            try await verify("グレース")
            _ = field.delegate?.textFieldShouldReturn?(field)
            try await settle()
            XCTAssertFalse(controller.riveFocusState.hasFocus, "Done must clear Rive focus")
            XCTAssertFalse(field.isFirstResponder)
            let blurredSnapshot = try await controller.runtimeSnapshot()
            XCTAssertEqual(blurredSnapshot.values.first { $0.name == "blurred" }?.value, .number(1))
            // Programmatic changes and autofill need the same focus guard.
            field.text = "Grace"
            field.sendActions(for: .editingChanged)
            try await verify("Grace")
            XCTAssertTrue(controller.riveFocusState.expectsKeyboardInput)
            XCTContext.runActivity(named: "Native nonsecure callbacks: " + callbacks.joined(separator: "; ")) { _ in }
        } catch {
            await controller.shutdownInteractiveScreen()
            throw error
        }
        await controller.shutdownInteractiveScreen()
    }

    func testNativeEditingSecondPublishedFieldKeepsFirstValue() async throws {
        let directory = PublishedInputFixture.directory.deletingLastPathComponent()
            .appendingPathComponent("published-two-fields")
        let payload = try await authenticatedTwoFieldPayload(directory)
        XCTAssertEqual(payload.renderPlan.textInputs.count, 2)
        let probe = InputStepProbe()
        let controller = try ExperienceInputFixture.makeController(payload, probe: probe,
            fixtureName: "screen", directory: directory)
        var capture: NuxieNativeSemanticCapture?
        controller.onSemanticCapture = { capture = $0 }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await controller.mountInteractiveScreen()
        await controller.enter(reduceMotion: true)
        await controller.activate(reduceMotion: true)
        func settle(awaitingKeyboardFocus: Bool = false) async throws {
            let deadline = Date().addingTimeInterval(5)
            repeat {
                controller.advance(delta: 0.016)
                while !controller.hasDeliveredLatestSemanticFrame, Date() < deadline {
                    try await Task.sleep(nanoseconds: 1_000_000)
                }
                if let failure = probe.failure { throw failure }
                if !awaitingKeyboardFocus || (controller.riveFocusState.hasFocus && controller.riveFocusState.expectsKeyboardInput) { break }
                // Blur can retire the preceding capture. Drive the next normal frame
                // so field 2 can focus from a newly presented occurrence.
            } while Date() < deadline
            XCTAssertTrue(controller.hasDeliveredLatestSemanticFrame)
        }
        func fields(in view: UIView) -> [UITextField] {
            if let field = view as? UITextField { return [field] }
            return view.subviews.flatMap { fields(in: $0) }
        }
        do {
            try await settle()
            let editors = fields(in: controller.view)
            XCTAssertEqual(editors.count, 2)
            let first = try XCTUnwrap(editors.first { $0.text == "Ada" })
            let second = try XCTUnwrap(editors.first { $0.text == "Hopper" })
            XCTAssertGreaterThan(second.convert(second.bounds, to: window).midY,
                first.convert(first.bounds, to: window).midY)
            XCTAssertTrue(first.becomeFirstResponder())
            try await settle()
            XCTAssertTrue(controller.riveFocusState.expectsKeyboardInput)
            // Native begin editing sends the real Rive pointer tap at field 2's geometry.
            XCTAssertTrue(second.becomeFirstResponder())
            try await settle(awaitingKeyboardFocus: true)
            XCTAssertTrue(controller.riveFocusState.hasFocus)
            XCTAssertTrue(controller.riveFocusState.expectsKeyboardInput)
            XCTAssertFalse(first.isFirstResponder)
            XCTAssertTrue(second.isFirstResponder)
            second.selectedTextRange = second.textRange(from: second.beginningOfDocument, to: second.endOfDocument)
            second.insertText("Grace")
            try await settle()
            let snapshot = try await controller.runtimeSnapshot()
            XCTAssertEqual(snapshot.values.first { $0.name == "name" }?.value, .bytes(Data("Ada".utf8)))
            XCTAssertEqual(snapshot.values.first { $0.name == "surname" }?.value, .bytes(Data("Grace".utf8)))
            XCTAssertEqual(first.text, "Ada")
            XCTAssertEqual(second.text, "Grace")
            let current = try XCTUnwrap(capture)
            var fieldValues: [String] = []
            for input in payload.renderPlan.textInputs {
                let occurrence = try XCTUnwrap(current.nativeInputs[input.textInputName]?.first)
                fieldValues.append(try await controller.readPresentedFieldString(captureID: current.id,
                    nodeID: occurrence.nodeID, name: input.textInputName))
            }
            XCTAssertEqual(fieldValues.sorted(), ["Ada", "Grace"])
            let middle = try XCTUnwrap(second.position(from: second.beginningOfDocument, offset: 2))
            second.selectedTextRange = second.textRange(from: middle, to: middle)
            XCTAssertEqual(second.offset(from: second.beginningOfDocument, to: try XCTUnwrap(second.selectedTextRange).start), 2)
            // Let UIKit paint its updated selection before retaining the combined image.
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTContext.runActivity(named: "Two nonsecure fields, native middle caret over Rive text") { activity in
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let attachment = XCTAttachment(image: image)
                attachment.lifetime = .keepAlways
                activity.add(attachment)
            }
            second.selectAll(nil)
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTContext.runActivity(named: "Two nonsecure fields, native selection over Rive text") { activity in
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let attachment = XCTAttachment(image: image)
                attachment.lifetime = .keepAlways
                activity.add(attachment)
            }
            _ = second.delegate?.textFieldShouldReturn?(second)
            try await settle()
            XCTAssertFalse(controller.riveFocusState.hasFocus)
        } catch {
            await controller.shutdownInteractiveScreen()
            throw error
        }
        await controller.shutdownInteractiveScreen()
    }

    private func authenticatedTwoFieldPayload(_ directory: URL) async throws -> AuthenticatedRuntimePayload {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        let profile = try JourneyPlaneProfile.decode(Data(contentsOf: directory.appendingPathComponent("profile.json")))
        let host = try XCTUnwrap(URL(string: profile.delivery.renderBaseUrl)?.host)
        StubURLProtocol.register(matcher: { $0.url?.host == host }) { request in
            let url = try XCTUnwrap(request.url)
            let bytes = try Data(contentsOf: directory.appendingPathComponent(String(url.path.dropFirst())))
            return (try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/vnd.nuxie.scene", "Content-Length": String(bytes.count)])), bytes)
        }
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("two-fields-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cache) }
        let store = JourneyReleaseAcquisitionStore(cacheDirectory: cache,
            urlSession: TestURLSessionProvider.createTestSession())
        let catalog = JourneyProfileCatalog(authorizationKeys: try JourneyTrustRoots.keys(for: .development),
            supportedRuntime: JourneyReleaseRuntime.current, highWaterStore: InMemoryJourneyReleaseHighWaterStore())
        let entry = try XCTUnwrap(profile.releases.first)
        let authenticated = try await catalog.prepare(profile,
            authority: ProfileDeliveryAuthority(appId: entry.locator.appId, environment: entry.locator.environment)).snapshot
        let release = try XCTUnwrap(authenticated.releasesByDigest.values.first)
        let screenID = try XCTUnwrap(release.descriptor.leg.screens.first?.id)
        let presentation = try await store.preparePresentation(release: release, delivery: profile.delivery,
            pinnedArtifacts: nil, productResolver: { _ in [] })
        return try await presentation.artifactLoader(presentation.experience, nil, screenID).payload
    }

    func testPublishedInputReplacementPreservesNativeCompositionAndCorrection() async throws {
        let expected = try PublishedInputFixture.expectations()
        let preparation = try await ExperienceInteractivePreparation.prepare(payload:
            SharedValuesFixture.payload(directory: PublishedInputFixture.directory, screens: expected.screens))
        let run = ExperienceRunValues()
        addTeardownBlock { await run.retire() }
        let screen = try await preparation.openScreen(screenID: "input", runValues: run, pixelWidth: 393, pixelHeight: 852)
        addTeardownBlock { try await screen.close() }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        let field = UITextField(frame: CGRect(x: 20, y: 40, width: 300, height: 40))
        controller.view.addSubview(field)
        defer { window.isHidden = true; window.rootViewController = nil }
        field.text = expected.startingValues.name
        _ = try await screen.step(focusInputs: [.next], elapsedSeconds: 0)
        XCTAssertTrue(field.becomeFirstResponder())
        let root = try await screen.rootViewModel()
        func sendNativeReplacement(_ expectedText: String) async throws {
            let current = try XCTUnwrap(field.text)
            XCTAssertEqual(current, expectedText)
            _ = try await screen.step(elapsedSeconds: 0)
            _ = try await screen.mutateState([.setNumber(root, path: "state/typed", value: 0)])
            // The native editor owns composition and replacement. These are
            // existing Rive select-all and insertion inputs, in one step.
            let replacement: NuxieNativeFocusInput = current.isEmpty
                ? .key(code: 259, modifiers: 0, pressed: true, repeated: false)
                : .text(current)
            _ = try await screen.step(focusInputs: [
                .key(code: 65, modifiers: 8, pressed: true, repeated: false), replacement,
            ], elapsedSeconds: 0)
            let values = try await run.journeyValues()
            XCTAssertEqual(values["name"], .string(expectedText))
            let immediate = try await screen.snapshot()
            XCTAssertEqual(immediate.values.first { $0.name == "typed" }?.value, .number(0),
                "F3 dispatches the input handler on the next advance")
            _ = try await screen.step(elapsedSeconds: 0)
            let snapshot = try await screen.snapshot()
            XCTAssertEqual(snapshot.values.first { $0.name == "typed" }?.value, .number(1))
        }
        field.selectedTextRange = field.textRange(from: field.beginningOfDocument, to: field.endOfDocument)
        field.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0))
        XCTAssertNotNil(field.markedTextRange)
        try await sendNativeReplacement("に")
        field.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0))
        XCTAssertNotNil(field.markedTextRange)
        try await sendNativeReplacement("日本")
        field.unmarkText()
        XCTAssertNil(field.markedTextRange)
        field.selectedTextRange = field.textRange(from: field.beginningOfDocument, to: field.endOfDocument)
        field.insertText("teh")
        try await sendNativeReplacement("teh")
        field.selectedTextRange = field.textRange(from: field.beginningOfDocument, to: field.endOfDocument)
        field.insertText("the")
        try await sendNativeReplacement("the")
        field.selectedTextRange = field.textRange(from: field.beginningOfDocument, to: field.endOfDocument)
        field.insertText("")
        try await sendNativeReplacement("")
    }

    func testTypingTransportExperiment() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        let surface = UIView(frame: window.bounds)
        controller.view.addSubview(surface)
        let bridge = ExperienceTextInputOverlayBridge()
        var kept = ""
        bridge.bind(screenID: "screen", renderPlan: makePlan(),
            surfaceView: surface, artboardBounds: surface.bounds,
            semanticTextWriter: { _, _, text, done in kept = text; done(.accepted) },
            semanticTextReader: { _, _, done in done(.success(.init(text: kept))) })
        defer { bridge.clear() }
        presentField(on: bridge)
        let native = try XCTUnwrap(bridge.applySemantics(try nativeCapture(ids: [1], secure: false))[1] as? UITextField)
        XCTAssertTrue(native.becomeFirstResponder())
        func clearNative() {
            native.selectedTextRange = native.textRange(from: native.beginningOfDocument, to: native.endOfDocument)
            native.insertText("")
            bridge.flushTextChange(for: native)
        }
        clearNative()
        native.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0))
        XCTAssertNotNil(native.markedTextRange)
        native.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0))
        native.unmarkText()
        bridge.flushTextChange(for: native)
        let compositionNative = kept
        XCTAssertEqual(compositionNative, "日本")
        clearNative()
        native.insertText("teh")
        native.selectedTextRange = native.textRange(from: native.beginningOfDocument, to: native.endOfDocument)
        native.insertText("the")
        bridge.flushTextChange(for: native)
        let correctionNative = kept
        XCTAssertEqual(correctionNative, "the")

        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/runtime/text-editing-experiment")
        native.resignFirstResponder()
        let clear: [NuxieNativeFocusInput] = [
            .key(code: 65, modifiers: 8, pressed: true, repeated: false),
            .key(code: 259, modifiers: 0, pressed: true, repeated: false)
        ]
        func experiment(secure: Bool) async throws -> [String: String] {
            let name = secure ? "text_input_secure_observed" : "text_input_observed"
            let payload = try await ExperienceInputFixture.payload(defaultViewModelName: nil,
                scene: Data(contentsOf: directory.appendingPathComponent(name + ".riv")),
                artboardName: "Text Input - Multiline", semantics: true)
            let probe = InputStepProbe()
            var lastDrawable: (any CAMetalDrawable)?
            let screen = try ExperienceInputFixture.makeController(payload, probe: probe,
                fixtureName: name, directory: directory, acquireDrawable: { layer in
                    layer.framebufferOnly = false
                    let drawable = layer.nextDrawable()
                    lastDrawable = drawable
                    return drawable
                })
            let riveWindow = UIWindow(windowScene: scene)
            riveWindow.frame = window.frame
            riveWindow.rootViewController = screen
            riveWindow.makeKeyAndVisible()
            defer { riveWindow.isHidden = true; riveWindow.rootViewController = nil }
            screen.view.layoutIfNeeded()
            var lastCapture: NuxieNativeSemanticCapture?
            screen.onSemanticCapture = { capture in lastCapture = capture }
            do {
                try await screen.mountInteractiveScreen()
                await screen.enter(reduceMotion: true)
                await screen.activate(reduceMotion: true)
                func waitForPresentedFrames() async throws {
                    let deadline = Date().addingTimeInterval(5)
                    while !screen.hasDeliveredLatestSemanticFrame, Date() < deadline, probe.failure == nil {
                        try await Task.sleep(nanoseconds: 1_000_000)
                    }
                    XCTAssertNil(probe.failure)
                    XCTAssertTrue(screen.hasDeliveredLatestSemanticFrame, "Both native completion and semantic delivery must settle")
                }
                try await waitForPresentedFrames()
                func apply(_ inputs: [NuxieNativeFocusInput]) async throws -> (node: NuxieNativeSemanticNode, text: String) {
                    lastCapture = nil
                    for input in inputs { XCTAssertTrue(screen.receiveFocusInput(input)) }
                    screen.advance(delta: 0.016)
                    try await waitForPresentedFrames()
                    let capture = try XCTUnwrap(lastCapture, "The input's frame must deliver a fresh capture")
                    let node = try XCTUnwrap(capture.tree.nodes.first {
                        $0.role == NuxieNativeSemanticRole.textField.rawValue
                    })
                    let text = try await screen.readPresentedFieldString(
                        captureID: capture.id, nodeID: node.id, name: "experiment-input")
                    return (node, text)
                }
                _ = try await apply([.next])
                XCTAssertEqual(screen.riveFocusState.hasFocus, true)
                let empty = try await apply(clear)
                XCTAssertTrue(empty.text.isEmpty, "Clearing the field must remove its text")
                var result: [String: String]
                if secure {
                    let field = try await apply([.text("private-test")])
                    let obscured = field.node.stateFlags & NuxieNativeSemanticNode.obscured != 0
                    XCTAssertTrue(obscured)
                    XCTAssertFalse(field.node.value.contains("private-test"))
                    XCTAssertTrue(field.text == "private-test", "Secure field must retain the typed text")
                    func pixels() async throws -> Data {
                        let texture = try XCTUnwrap(lastDrawable?.texture)
                        let rowBytes = ((texture.width * 4 + 255) / 256) * 256
                        let buffer = try XCTUnwrap(texture.device.makeBuffer(length: rowBytes * texture.height,
                            options: .storageModeShared))
                        let queue = try XCTUnwrap(texture.device.makeCommandQueue())
                        let command = try XCTUnwrap(queue.makeCommandBuffer())
                        let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
                        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(),
                            sourceSize: .init(width: texture.width, height: texture.height, depth: 1),
                            to: buffer, destinationOffset: 0, destinationBytesPerRow: rowBytes,
                            destinationBytesPerImage: rowBytes * texture.height)
                        blit.endEncoding()
                        let copied = expectation(description: "Presented secure frame copied")
                        command.addCompletedHandler { _ in copied.fulfill() }
                        command.commit()
                        await fulfillment(of: [copied], timeout: 5)
                        XCTAssertEqual(command.status, .completed)
                        var data = Data()
                        let bytes = buffer.contents().assumingMemoryBound(to: UInt8.self)
                        for row in 0..<texture.height { data.append(bytes + row * rowBytes, count: texture.width * 4) }
                        return data
                    }
                    let first = try await pixels()
                    _ = try await apply(clear + [.text("hidden-value")])
                    let sameLength = try await pixels()
                    _ = try await apply(clear + [.text("tiny")])
                    let shorter = try await pixels()
                    XCTAssertTrue(first == sameLength, "Secure drawing conceals which same-length text was typed")
                    XCTAssertTrue(first != shorter, "Typing must change the secure drawing")
                    result = ["obscured": String(obscured), "semanticValueEmpty": String(field.node.value.isEmpty),
                        "sameLengthPixelsMatch": String(first == sameLength), "shorterPixelsDiffer": String(first != shorter)]
                } else {
                    let marked = try await apply([.text("に")])
                    let composition = try await apply([.text("日本")])
                    XCTAssertNotEqual(marked.text, composition.text, "The second composition payload must reach Rive")
                    _ = try await apply(clear)
                    let word = try await apply([.text("teh")])
                    let correction = try await apply([.text("the")])
                    XCTAssertNotEqual(word.text, correction.text, "The replacement payload must reach Rive")
                    result = ["composition": composition.text, "wordReplacement": correction.text]
                }
                await screen.shutdownInteractiveScreen()
                return result
            } catch { await screen.shutdownInteractiveScreen(); throw error }
        }
        let rive = try await experiment(secure: false)
        let editingData = try JSONSerialization.data(withJSONObject: rive, options: [.sortedKeys])
        print("TYPING_EDITING " + String(decoding: editingData, as: UTF8.self))
        window.makeKeyAndVisible()
        bridge.clear()
        bridge.bind(screenID: "screen", renderPlan: makePlan(secure: true),
            surfaceView: surface, artboardBounds: surface.bounds,
            semanticTextWriter: { _, _, text, done in kept = text; done(.accepted) },
            semanticTextReader: { _, _, done in done(.success(.init(text: kept))) })
        presentField(on: bridge)
        let secureNative = try XCTUnwrap(bridge.applySemantics(try nativeCapture(ids: [1], secure: true))[1] as? UITextField)
        XCTAssertTrue(secureNative.becomeFirstResponder())
        secureNative.selectedTextRange = secureNative.textRange(from: secureNative.beginningOfDocument, to: secureNative.endOfDocument)
        secureNative.insertText("private-test")
        bridge.flushTextChange(for: secureNative)
        XCTAssertTrue(secureNative.isSecureTextEntry)
        XCTAssertTrue(kept == "private-test", "Native secure editor must retain the typed text")
        secureNative.resignFirstResponder()
        let secureRive = try await experiment(secure: true)
        let observations = ["composition": ["native": compositionNative, "rive": rive["composition"] ?? "missing"],
            "wordReplacement": ["native": correctionNative, "rive": rive["wordReplacement"] ?? "missing"],
            "secure": ["native": String(secureNative.isSecureTextEntry), "rive": secureRive["obscured"] ?? "missing",
                "riveSemanticValueEmpty": secureRive["semanticValueEmpty"] ?? "missing",
                "sameLengthPixelsMatch": secureRive["sameLengthPixelsMatch"] ?? "missing",
                "shorterPixelsDiffer": secureRive["shorterPixelsDiffer"] ?? "missing"]]
        let data = try JSONSerialization.data(withJSONObject: observations, options: [.sortedKeys])
        print("TYPING_EXPERIMENT " + String(decoding: data, as: UTF8.self))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "typing-experiment.json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    #endif

    func testSecureSelectionSurvivesViewportRelayout() throws {
        let bridge = ExperienceTextInputOverlayBridge()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        let surface = UIView(frame: window.bounds)
        controller.view.addSubview(surface)
        var source = ""
        bridge.bind(screenID: "screen", renderPlan: makePlan(secure: true),
            surfaceView: surface, artboardBounds: surface.bounds,
            semanticTextWriter: { _, _, text, done in source = text; done(.accepted) },
            semanticTextReader: { _, _, done in done(.success(.init(text: source))) })
        defer { bridge.clear(); window.isHidden = true }
        presentField(on: bridge)
        let field = try XCTUnwrap(bridge.applySemantics(try nativeCapture(ids: [1], secure: true))[1] as? UITextField)
        XCTAssertTrue(field.becomeFirstResponder())
        field.insertText("Alpha beta")
        for (start, end) in [(9, 9), (5, 6)] {
            let first = try XCTUnwrap(field.position(from: field.beginningOfDocument, offset: start))
            let last = try XCTUnwrap(field.position(from: field.beginningOfDocument, offset: end))
            field.selectedTextRange = field.textRange(from: first, to: last)
            surface.bounds.size.width += 20
            bridge.layout()
            let selection = try XCTUnwrap(field.selectedTextRange)
            XCTAssertEqual(field.offset(from: field.beginningOfDocument, to: selection.start), start)
            XCTAssertEqual(field.offset(from: field.beginningOfDocument, to: selection.end), end)
            XCTAssertTrue(field.text == "Alpha beta", "Secure text must survive viewport relayout")
        }
    }

    func testSecureDeletionPreservesCharactersAndNativeUndo() throws {
        let bridge = ExperienceTextInputOverlayBridge()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        let surface = UIView(frame: window.bounds)
        controller.view.addSubview(surface)
        var source = ""
        bridge.bind(screenID: "screen", renderPlan: makePlan(secure: true),
            surfaceView: surface, artboardBounds: surface.bounds,
            semanticTextWriter: { _, _, text, done in source = text; done(.accepted) },
            semanticTextReader: { _, _, done in done(.success(.init(text: source))) })
        defer { bridge.clear(); window.isHidden = true }
        presentField(on: bridge)
        let field = try XCTUnwrap(bridge.applySemantics(try nativeCapture(ids: [1], secure: true))[1] as? UITextField)
        XCTAssertTrue(field.becomeFirstResponder())
        let undo = try XCTUnwrap(field.undoManager)
        // Literal UTF-16 caret offsets, including deletion in the middle of text.
        let cases: [(String, Int, String)] = [
            ("A👩🏽‍💻Z", 8, "AZ"),
            ("Ae\u{301}Z", 3, "AZ"),
            ("A🇯🇵Z", 5, "AZ"),
            ("A😀Z", 3, "AZ"),
            ("ABC", 2, "AC"),
        ]
        for (original, caret, expected) in cases {
            field.selectedTextRange = field.textRange(from: field.beginningOfDocument, to: field.endOfDocument)
            field.insertText(original)
            bridge.flushTextChange(for: field)
            XCTAssertTrue(source == original, "Secure source must retain the original text")
            let position = try XCTUnwrap(field.position(from: field.beginningOfDocument, offset: caret))
            field.selectedTextRange = field.textRange(from: position, to: position)
            undo.removeAllActions()
            undo.beginUndoGrouping()
            field.deleteBackward()
            undo.endUndoGrouping()
            bridge.flushTextChange(for: field)
            XCTAssertTrue(field.text == expected, "Secure field must reflect deletion")
            XCTAssertTrue(source == expected, "Secure source must reflect deletion")
            XCTAssertTrue(undo.canUndo)
            undo.undo()
            bridge.flushTextChange(for: field)
            XCTAssertTrue(field.text == original, "Undo must restore the complete character")
            XCTAssertTrue(source == original, "Secure source must retain the original text")
            XCTAssertTrue(undo.canRedo)
            undo.redo()
            bridge.flushTextChange(for: field)
            XCTAssertTrue(source == expected, "Secure source must reflect deletion")
        }
        field.selectedTextRange = field.textRange(from: field.beginningOfDocument, to: field.endOfDocument)
        field.insertText("A😀BC")
        let start = try XCTUnwrap(field.position(from: field.beginningOfDocument, offset: 3))
        field.selectedTextRange = field.textRange(from: start, to: field.endOfDocument)
        field.deleteBackward()
        bridge.flushTextChange(for: field)
        XCTAssertTrue(source == "A😀", "An explicit selection must not expand into the preceding emoji")
        field.selectedTextRange = field.textRange(from: field.beginningOfDocument, to: field.beginningOfDocument)
        field.deleteBackward()
        bridge.flushTextChange(for: field)
        XCTAssertTrue(source == "A😀", "Backspace at the beginning must be a no-op")
    }

    func testMultilineAccessibilityBoundsFollowScaledAndRotatedViewport() throws {
        let bridge = ExperienceTextInputOverlayBridge()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        let surface = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        controller.view.addSubview(surface)
        bindCapturedFixture(bridge, screenID: "screen", renderPlan: makePlan(multiline: true),
            surfaceView: surface, artboardBounds: surface.bounds) { _, _, done in done(.success(())) }
        defer { bridge.clear(); window.isHidden = true }
        presentField(on: bridge)
        let field = try XCTUnwrap(bridge.applySemantics(try capture(flags: 0))[1] as? UITextView)
        field.bounds = CGRect(x: 0, y: 0, width: 200, height: 80)
        field.center = CGPoint(x: 200, y: 300)
        // Literal screen rectangles for a 200 × 80 viewport centered at (200, 300).
        // Scrolling changes content coordinates, not the accessible viewport.
        let cases: [(CGAffineTransform, CGRect)] = [
            (.identity, CGRect(x: 100, y: 260, width: 200, height: 80)),
            (.init(scaleX: 1.1, y: 1.1), CGRect(x: 90, y: 256, width: 220, height: 88)),
            (.init(rotationAngle: .pi / 2), CGRect(x: 160, y: 200, width: 80, height: 200)),
        ]
        for (transform, expected) in cases {
            field.transform = transform
            for offset in [CGPoint.zero, CGPoint(x: 0, y: 100)] {
                field.bounds.origin = offset
                let actual = field.accessibilityFrame
                XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.5)
                XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.5)
                XCTAssertEqual(actual.width, expected.width, accuracy: 0.5)
                XCTAssertEqual(actual.height, expected.height, accuracy: 0.5)
            }
        }
    }

    func testInputRelayoutDoesNotReportAnUnchangedSurfaceAsNewGeometry() {
        final class Observer: ExperienceRuntimeSurfaceViewObserver {
            var geometryChanges = 0
            func runtimeSurfaceViewGeometryDidChange() { geometryChanges += 1 }
            func runtimeSurfaceViewVisibilityDidChange() {}
            func runtimeSurfaceViewDidReceivePointerEvents(_ events: [ExperienceRuntimeViewPointerEvent]) {}
        }
        let observer = Observer()
        let surface = ExperienceRuntimeSurfaceView(frame: CGRect(x: 0, y: 0, width: 320, height: 600))
        surface.runtimeObserver = observer
        surface.layoutSubviews()
        let initial = observer.geometryChanges
        let field = UITextField(frame: CGRect(x: 20, y: 20, width: 280, height: 50))
        surface.addSubview(field)
        field.text = ""
        surface.layoutSubviews()
        XCTAssertEqual(observer.geometryChanges, initial, "Relayout must not invalidate an already admitted text edit")
        surface.bounds.size.height = 400
        surface.layoutSubviews()
        XCTAssertEqual(observer.geometryChanges, initial + 1, "Actual resizing must still invalidate old coordinates")
        surface.layoutSubviews()
        XCTAssertEqual(observer.geometryChanges, initial + 1)
    }

    func testSourceReadStartedBeforeClearCannotRestoreAcceptedOldValue() throws {
        for secure in [false, true] {
            let bridge = ExperienceTextInputOverlayBridge()
            let view = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
            var source = "saved"
            var deferRead = false
            var pendingRead: (() -> Void)?
            var events: [ExperienceTextInputEvent] = []
            bridge.onEditingEvent = { _, event in events.append(event) }
            bridge.bind(screenID: "screen", renderPlan: makePlan(secure: secure),
                surfaceView: view, artboardBounds: view.bounds,
                semanticTextWriter: { _, _, text, done in source = text; done(.accepted) },
                semanticTextReader: { _, _, done in
                    let snapshot = source
                    if deferRead { pendingRead = { done(.success(.init(text: snapshot))) } }
                    else { done(.success(.init(text: snapshot))) }
                })
            defer { bridge.clear() }
            presentField(on: bridge)
            let field = try XCTUnwrap(bridge.applySemantics(try nativeCapture(ids: [1], secure: secure))[1] as? UITextField)
            deferRead = true
            _ = bridge.applySemantics(try nativeCapture(ids: [1], secure: secure, revision: 2))
            field.text = ""
            field.sendActions(for: .editingChanged)
            XCTAssertEqual(source, "")
            try XCTUnwrap(pendingRead)()
            XCTAssertEqual(field.text, "", "A read begun before the edit cannot undo an admitted clear")
            bridge.textFieldDidEndEditing(field)
            XCTAssertEqual(events.map(\.text), [""])
        }
    }

    func testNativeViewportWaitsForAcceptedTextAndRetriesOnlyWithFreshCapture() throws {
        let bridge = ExperienceTextInputOverlayBridge()
        let surface = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        var source = "saved"
        var textCompletion: (@MainActor @Sendable (ExperienceSemanticTextDraft.Outcome) -> Void)?
        var offsets: [(UUID, CGPoint, @MainActor @Sendable (ExperienceSemanticTextDraft.Outcome) -> Void)] = []
        bridge.bind(screenID: "screen", renderPlan: makePlan(),
            surfaceView: surface, artboardBounds: surface.bounds,
            semanticTextWriter: { _, _, text, done in source = text; textCompletion = done },
            semanticContentOffsetWriter: { id, _, offset, done in offsets.append((id, offset, done)) },
            semanticTextReader: { _, _, done in done(.success(.init(text: source))) })
        defer { bridge.clear() }
        presentField(on: bridge)
        let first = try nativeCapture(ids: [1], secure: false)
        let field = try XCTUnwrap(bridge.applySemantics(first)[1] as? UITextField)
        field.text = "edited"
        bridge.flushTextChange(for: field)
        bridge.textFieldDidChangeSelection(field)
        XCTAssertTrue(offsets.isEmpty, "Viewport writes must not overtake an unaccepted edit")
        try XCTUnwrap(textCompletion)(.accepted)

        let second = try nativeCapture(ids: [1], secure: false, revision: 2)
        _ = bridge.applySemantics(second)
        XCTAssertEqual(offsets.count, 1)
        XCTAssertEqual(offsets[0].0, second.id)
        XCTAssertEqual(offsets[0].1, .zero, "A blurred field restores the unscrolled viewport")
        offsets[0].2(.staleCapture)
        bridge.textFieldDidChangeSelection(field)
        _ = bridge.applySemantics(second)
        XCTAssertEqual(offsets.count, 1, "Do not spin against the same stale capture")

        let third = try nativeCapture(ids: [1], secure: false, revision: 3)
        _ = bridge.applySemantics(third)
        XCTAssertEqual(offsets.count, 2)
        XCTAssertEqual(offsets[1].0, third.id)
        offsets[1].2(.accepted)
        _ = bridge.applySemantics(try nativeCapture(ids: [1], secure: false, revision: 4))
        bridge.textFieldDidChangeSelection(field)
        XCTAssertEqual(offsets.count, 2, "An unchanged accepted viewport needs no further writes")
        bridge.clear()
        offsets[1].2(.accepted)
        XCTAssertNil(field.superview, "A late callback cannot resurrect a retired occurrence")
    }

    func testNativePlaceholdersNeverBecomeValuesAndTrackSourceRefreshes() throws {
        for multiline in [false, true] {
            for secure in [false, true] {
                let bridge = ExperienceTextInputOverlayBridge()
                let surface = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
                var source = ""
                var writes: [String] = []
                bridge.bind(screenID: "screen",
                    renderPlan: makePlan(secure: secure, multiline: multiline),
                    surfaceView: surface, artboardBounds: surface.bounds,
                    semanticTextWriter: { _, _, text, done in writes.append(text); done(.accepted) },
                    semanticTextReader: { _, _, done in done(.success(.init(text: source))) })
                presentField(on: bridge)
                let control = try XCTUnwrap(bridge.applySemantics(
                    try nativeCapture(ids: [1], secure: secure))[1])
                XCTAssertFalse(control.isHidden)
                XCTAssertFalse(control.isFirstResponder, "Hints must work before focus")
                if let field = control as? UITextField {
                    XCTAssertEqual(field.text, "")
                    XCTAssertEqual(field.attributedPlaceholder?.string, "Name")
                    let color = try XCTUnwrap(field.attributedPlaceholder?.attribute(.foregroundColor,
                        at: 0, effectiveRange: nil) as? UIColor)
                    XCTAssertEqual(color, UIColor(red: 0x12 / 255.0, green: 0x34 / 255.0,
                        blue: 0x56 / 255.0, alpha: 1))
                } else {
                    let editor = try XCTUnwrap(control as? UITextView)
                    let hint = try XCTUnwrap(editor.subviews.compactMap { $0 as? UILabel }.first)
                    editor.layoutIfNeeded()
                    XCTAssertEqual(hint.text, "Name")
                    XCTAssertFalse(hint.isHidden)
                    XCTAssertFalse(hint.isAccessibilityElement)
                    XCTAssertGreaterThan(hint.frame.width, 0)
                    XCTAssertEqual(editor.text, "")
                    XCTAssertEqual(editor.textStorage.string, "")
                    editor.text = "draft"
                    bridge.textViewDidChange(editor)
                    XCTAssertTrue(hint.isHidden)
                    editor.text = ""
                    bridge.textViewDidChange(editor)
                    XCTAssertFalse(hint.isHidden)
                    XCTAssertEqual(writes, ["draft", ""], "Hints never enter the write path")
                }
                source = "runtime value"
                _ = bridge.applySemantics(try nativeCapture(ids: [1], secure: secure, revision: 2))
                if let field = control as? UITextField {
                    XCTAssertEqual(field.text, source)
                    XCTAssertTrue(writes.isEmpty)
                } else {
                    let editor = try XCTUnwrap(control as? UITextView)
                    XCTAssertEqual(editor.text, source)
                    XCTAssertTrue(try XCTUnwrap(editor.subviews.compactMap { $0 as? UILabel }.first).isHidden)
                    source = ""
                    _ = bridge.applySemantics(try nativeCapture(ids: [1], secure: secure, revision: 3))
                    XCTAssertFalse(try XCTUnwrap(editor.subviews.compactMap { $0 as? UILabel }.first).isHidden)
                }
                bridge.clear()
                XCTAssertNil(control.superview)
            }
        }
    }

    func testRepeatedNativeSecureInputsReadAndWriteTheirOwnOccurrence() throws {
        let bridge = ExperienceTextInputOverlayBridge()
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        var values: [UInt32: String] = [1: "first", 2: "second"]
        var writes: [(UInt32, String)] = []
        var commits: [String] = []
        var editingOwners: [UInt64?] = []
        bridge.onEditingEvent = { _, event in editingOwners.append(event.ownerInstanceID) }
        bridge.onAcceptedTextChange = { input, value in
            XCTAssertEqual(input.inputId, "input", "Occurrence identity must not change authored action routing")
            commits.append(value)
        }
        bridge.bind(screenID: "screen", renderPlan: makePlan(secure: true),
            surfaceView: view, artboardBounds: view.bounds,
            semanticTextWriter: { _, target, value, done in
                guard let node = target.nodeID else { return XCTFail("Missing occurrence") }
                writes.append((node, value))
                values[node] = value
                done(.accepted)
            }, semanticTextReader: { _, target, done in
                guard let node = target.nodeID, let value = values[node] else { return XCTFail("Unknown occurrence") }
                done(.success(.init(text: value, ownerInstanceID: UInt64(node))))
            })
        presentField(on: bridge)
        let controls = bridge.applySemantics(try nativeCapture(ids: [1, 2]))
        let first = try XCTUnwrap(controls[1] as? UITextField)
        let second = try XCTUnwrap(controls[2] as? UITextField)
        XCTAssertEqual(first.text, "first")
        XCTAssertEqual(second.text, "second")
        XCTAssertTrue(first.isSecureTextEntry && second.isSecureTextEntry)
        XCTAssertTrue(writes.isEmpty, "Discovery reads the bound value; it must not overwrite it with an authored default")
        first.text = "new secret"
        bridge.flushTextChange(for: first)
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.first?.0, 1)
        XCTAssertEqual(writes.first?.1, "new secret", "The obscured TextInput receives the real value")
        XCTAssertEqual(commits, ["new secret"])
        XCTAssertEqual(second.text, "second")
        XCTAssertEqual(values[2], "second")
        XCTAssertFalse(first.accessibilityValue?.contains("new secret") ?? false)
        // Changing reading order preserves the controls and their owners.
        let reordered = bridge.applySemantics(try nativeCapture(ids: [2, 1]))
        XCTAssertTrue(reordered[1] === first)
        XCTAssertTrue(reordered[2] === second)
        bridge.textFieldDidEndEditing(first)
        bridge.textFieldDidEndEditing(second)
        XCTAssertEqual(editingOwners, [1, 2], "Reordering must preserve each input action's owner")
        bridge.clear()
    }

    func testReboundNativeFieldDiscardsThePreviousOwnersPendingDraft() throws {
        let bridge = ExperienceTextInputOverlayBridge()
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        var source = ExperienceTextInputSource(text: "first", ownerInstanceID: 11)
        var pending: (@MainActor @Sendable (ExperienceSemanticTextDraft.Outcome) -> Void)?
        var events: [ExperienceTextInputEvent] = []
        bridge.onEditingEvent = { _, event in events.append(event) }
        bridge.bind(screenID: "screen", renderPlan: makePlan(),
            surfaceView: view, artboardBounds: view.bounds,
            semanticTextWriter: { _, _, _, done in pending = done },
            semanticTextReader: { _, _, done in done(.success(source)) })
        presentField(on: bridge)
        let controls = bridge.applySemantics(try nativeCapture(ids: [1], secure: false))
        let field = try XCTUnwrap(controls[1] as? UITextField)
        field.text = "old owner's draft"
        bridge.textFieldDidEndEditing(field)
        XCTAssertNotNil(pending)
        source = .init(text: "second", ownerInstanceID: 22)
        _ = bridge.applySemantics(try nativeCapture(ids: [1], secure: false))
        pending?(.accepted)
        XCTAssertEqual(field.text, "second")
        XCTAssertTrue(events.isEmpty, "An old completion cannot emit an action for the new owner")
        bridge.textFieldDidEndEditing(field)
        XCTAssertEqual(events, [.init(kind: .editingEnded, text: "second", ownerInstanceID: 22)])
        bridge.clear()
    }

    func testRetiredNativeOccurrenceCannotCommitIntoItsReplacement() throws {
        let bridge = ExperienceTextInputOverlayBridge()
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        var pending: (@MainActor @Sendable (ExperienceSemanticTextDraft.Outcome) -> Void)?
        var source = "original"
        var commits: [String] = []
        bridge.onAcceptedTextChange = { _, value in commits.append(value) }
        bridge.bind(screenID: "screen", renderPlan: makePlan(secure: true),
            surfaceView: view, artboardBounds: view.bounds,
            semanticTextWriter: { _, _, _, done in pending = done },
            semanticTextReader: { _, _, done in done(.success(.init(text: source))) })
        presentField(on: bridge)
        let first = try XCTUnwrap(bridge.applySemantics(try nativeCapture(ids: [1]))[1] as? UITextField)
        first.text = "pending secret"
        bridge.flushTextChange(for: first)
        XCTAssertNotNil(pending)
        _ = bridge.applySemantics(try nativeCapture(ids: []))
        XCTAssertNil(first.superview)
        source = "replacement"
        let replacement = try XCTUnwrap(bridge.applySemantics(try nativeCapture(ids: [1]))[1] as? UITextField)
        XCTAssertFalse(replacement === first)
        pending?(.accepted)
        XCTAssertEqual(replacement.text, "replacement")
        XCTAssertTrue(commits.isEmpty)
        bridge.clear()
    }

    func testNativeSourceRefreshDoesNotOverwritePendingUserEdit() throws {
        let bridge = ExperienceTextInputOverlayBridge()
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        var source = "initial"
        var pending: (@MainActor @Sendable (ExperienceSemanticTextDraft.Outcome) -> Void)?
        bridge.bind(screenID: "screen", renderPlan: makePlan(secure: false),
            surfaceView: view, artboardBounds: view.bounds,
            semanticTextWriter: { _, _, _, done in pending = done },
            semanticTextReader: { _, _, done in done(.success(.init(text: source))) })
        presentField(on: bridge)
        let field = try XCTUnwrap(bridge.applySemantics(try nativeCapture(ids: [1], secure: false))[1] as? UITextField)
        source = "updated externally"
        _ = bridge.applySemantics(try nativeCapture(ids: [1], secure: false))
        XCTAssertEqual(field.text, source)
        field.text = "typing"
        bridge.flushTextChange(for: field)
        source = "another update"
        _ = bridge.applySemantics(try nativeCapture(ids: [1], secure: false))
        XCTAssertEqual(field.text, "typing")
        pending?(.accepted)
        bridge.clear()
    }

    func testHiddenNativeInputRestoresRuntimeValueInsteadOfReplayingOldDraft() throws {
        let bridge = ExperienceTextInputOverlayBridge()
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        var source = "initial"
        var pending: (@MainActor @Sendable (ExperienceSemanticTextDraft.Outcome) -> Void)?
        var writes = 0
        var commits: [String] = []
        bridge.onAcceptedTextChange = { _, value in commits.append(value) }
        bridge.bind(screenID: "screen", renderPlan: makePlan(secure: true),
            surfaceView: view, artboardBounds: view.bounds,
            semanticTextWriter: { _, _, value, done in source = value; writes += 1; pending = done },
            semanticTextReader: { _, _, done in done(.success(.init(text: source))) })
        presentField(on: bridge)
        let first = try XCTUnwrap(bridge.applySemantics(try nativeCapture(ids: [1]))[1] as? UITextField)
        first.text = "accepted in runtime"
        bridge.flushTextChange(for: first)
        bridge.setHidden(true)
        XCTAssertNil(first.superview)
        bridge.setHidden(false)
        let replacement = try XCTUnwrap(bridge.applySemantics(try nativeCapture(ids: [1]))[1] as? UITextField)
        pending?(.accepted)
        XCTAssertEqual(replacement.text, "accepted in runtime")
        XCTAssertEqual(writes, 1, "Returning must not replay the old accepted UI value over the native source")
        XCTAssertTrue(commits.isEmpty)
        bridge.clear()
    }

    func testSecureNativeGeometryCannotPopulateAnOrdinaryControl() throws {
        let bridge = ExperienceTextInputOverlayBridge()
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        bridge.bind(screenID: "screen", renderPlan: makePlan(secure: false),
            surfaceView: view, artboardBounds: view.bounds,
            semanticTextWriter: { _, _, _, _ in XCTFail("Mismatched field wrote a value") },
            semanticTextReader: { _, _, _ in XCTFail("Mismatched field read a secure value") })
        presentField(on: bridge)
        XCTAssertTrue(bridge.applySemantics(try nativeCapture(ids: [1])).isEmpty)
        XCTAssertTrue(view.subviews.isEmpty)
        bridge.clear()
    }

    func testSecureSourceRefreshesWhenOnlyThePresentedFrameChanges() throws {
        let bridge = ExperienceTextInputOverlayBridge()
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        var source = "first"
        var reads = 0
        bridge.bind(screenID: "screen", renderPlan: makePlan(secure: true),
            surfaceView: view, artboardBounds: view.bounds,
            semanticTextWriter: { _, _, _, _ in XCTFail("Source refresh is not a user edit") },
            semanticTextReader: { _, _, done in reads += 1; done(.success(.init(text: source))) })
        presentField(on: bridge)
        let captureID = UUID()
        let firstCapture = try nativeCapture(ids: [1], captureID: captureID)
        let field = try XCTUnwrap(bridge.applySemantics(firstCapture)[1] as? UITextField)
        _ = bridge.applySemantics(firstCapture)
        XCTAssertEqual(reads, 1)
        source = "changed without semantic disclosure"
        _ = bridge.applySemantics(try nativeCapture(ids: [1], captureID: captureID, revision: 2))
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(field.text, source)
        XCTAssertFalse(field.accessibilityValue?.contains(source) ?? false)
        bridge.clear()
    }

    private func nativeCapture(ids: [UInt32], secure: Bool = true, captureID: UUID = UUID(),
                               revision: UInt64 = 1) throws -> NuxieNativeSemanticCapture {
        let nodes = ids.enumerated().map { index, id in
            NuxieNativeSemanticNode(id: id, parentID: nil, siblingIndex: UInt32(index),
                role: NuxieNativeSemanticRole.textField.rawValue,
                stateFlags: secure ? NuxieNativeSemanticNode.obscured : 0, traitFlags: 0,
                headingLevel: 0, actions: 0, bounds: CGRect(x: 0, y: index * 45, width: 100, height: 40),
                label: "Repeated field", value: "", hint: "")
        }
        let occurrences = nodes.map { node in
            let transform = CGAffineTransform(translationX: 0, y: node.bounds.minY)
            return NuxieNativeInputOccurrence(nodeID: node.id, geometry: .init(renderRevision: revision,
                worldTransform: transform, textBounds: .zero,
                layout: .init(transform: transform, bounds: CGRect(x: 0, y: 0, width: 100, height: 40)),
                firstBaseline: nil, obscured: secure, multiline: false))
        }
        return .init(id: captureID, tree: try .init(renderRevision: revision, treeVersion: 1, nodes: nodes),
            fieldsByTextRun: [:], nativeInputs: ["editable": occurrences])
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
        bindCapturedFixture(bridge, screenID: "screen", renderPlan: makePlan(multiline: true), surfaceView: view, artboardBounds: view.bounds,
            semanticTextWriter: { _, _, _, done in done(.accepted) })
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
        bindCapturedFixture(bridge, screenID: "screen", renderPlan: makePlan(), surfaceView: view, artboardBounds: view.bounds,
            semanticTextWriter: { _, _, _, done in done(.accepted) })
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
        bindCapturedFixture(bridge, screenID: "screen", renderPlan: plan, surfaceView: view, artboardBounds: view.bounds) { _, text, done in
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
        XCTAssertTrue(writes.isEmpty, "Initial native text is read, not rewritten")
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
            bindCapturedFixture(bridge, screenID: "screen", renderPlan: makePlan(secure: secure, multiline: multiline),
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
                XCTAssertTrue(field.text == "saved", "Native control must retain its source value")
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
        bindCapturedFixture(bridge, screenID: "screen", renderPlan: makePlan(), surfaceView: view, artboardBounds: view.bounds,
            semanticTextWriter: { id, _, text, done in
                pending.append((id, text, done))
            })
        let field = try XCTUnwrap(view.subviews.compactMap { $0 as? UITextField }.first)
        presentField(on: bridge)
        XCTAssertTrue(pending.isEmpty)
        _ = bridge.applySemantics(try capture(flags: 0))
        XCTAssertTrue(pending.isEmpty, "Initial native text is read, not rewritten")
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

    func testSecureNativeWriterReceivesTextWithoutExposingItToAccessibility() throws {
        let bridge = ExperienceTextInputOverlayBridge()
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        var writes: [String] = []
        var commits: [String] = []
        bridge.onAcceptedTextChange = { _, text in commits.append(text) }
        bindCapturedFixture(bridge, screenID: "screen", renderPlan: makePlan(secure: true), surfaceView: view,
            artboardBounds: view.bounds,
            semanticTextWriter: { _, _, text, done in writes.append(text); done(.accepted) })
        presentField(on: bridge)
        _ = bridge.applySemantics(try capture(flags: NuxieNativeSemanticNode.obscured))
        let field = try XCTUnwrap(view.subviews.compactMap { $0 as? UITextField }.first)
        XCTAssertTrue(field.isSecureTextEntry)
        field.text = "secret"
        field.sendActions(for: .editingChanged)
        bridge.flushTextChange(for: field)
        XCTAssertTrue(writes == ["secret"], "The captured native writer must receive the secure edit")
        XCTAssertTrue(commits == ["secret"], "The accepted callback must carry the secure edit")
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
        do {
            for multiline in [false, true] {
                let bridge = ExperienceTextInputOverlayBridge()
                let view = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
                var commits: [String] = []
                bridge.onAcceptedTextChange = { _, text in commits.append(text) }
                bridge.bind(screenID: "screen", renderPlan: makePlan(multiline: multiline),
                    surfaceView: view, artboardBounds: view.bounds,
                    semanticTextWriter: { _, _, _, done in done(.accepted) },
                    semanticTextReader: { _, _, done in done(.success(.init(text: "saved"))) })
                presentField(on: bridge)
                _ = bridge.applySemantics(try nativeCapture(ids: [1], secure: false))
                let editor = try XCTUnwrap(view.subviews.first as? (UIView & UITextInput))
                editor.selectedTextRange = editor.textRange(from: editor.endOfDocument, to: editor.endOfDocument)
                editor.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0))
                XCTAssertNotNil(editor.markedTextRange)
                bridge.flushTextChange(for: editor)
                _ = bridge.applySemantics(try nativeCapture(ids: [1], secure: false))
                XCTAssertTrue(commits.isEmpty, "An unfinished IME composition is not a response")
                editor.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0))
                editor.unmarkText()
                XCTAssertNil(editor.markedTextRange)
                bridge.flushTextChange(for: editor)
                XCTAssertEqual(commits, ["saved한"])
                bridge.clear()
            }
        }
    }
    #endif

    /// Supply a presented native occurrence and a backing value for isolated UIKit tests.
    private func bindCapturedFixture(
        _ bridge: ExperienceTextInputOverlayBridge, screenID: String,
        renderPlan: NativeExperienceRenderPlan, surfaceView: UIView, artboardBounds: CGRect,
        semanticTextWriter: ExperienceTextInputOverlayBridge.SemanticTextWriter? = nil,
        textWriter: @escaping (_ inputID: String, _ text: String, _ completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void) -> Void = { _, _, _ in XCTFail("Fixture requires its captured writer") }
    ) {
        var value = renderPlan.textInputs[0].value
        bridge.bind(screenID: screenID, renderPlan: renderPlan, surfaceView: surfaceView,
            artboardBounds: artboardBounds,
            semanticTextWriter: { captureID, target, text, done in
                if let semanticTextWriter {
                    semanticTextWriter(captureID, target, text) { outcome in
                        if case .accepted = outcome { value = text }
                        done(outcome)
                    }
                } else {
                    textWriter(target.inputID, text) { result in
                        switch result {
                        case .success: value = text; done(.accepted)
                        case .failure: done(.rejected)
                        }
                    }
                }
            }, semanticTextReader: { _, _, done in done(.success(.init(text: value))) })
        let flags = renderPlan.textInputs[0].secureTextEntry == true ? NuxieNativeSemanticNode.obscured : 0
        do { _ = bridge.applySemantics(try capture(flags: flags)) }
        catch { XCTFail("Native fixture capture must be valid") }
    }

    /// These tests isolate semantic ownership; geometry is an explicit frame fixture.
    private func presentField(on bridge: ExperienceTextInputOverlayBridge, textRunName: String = "run") {
        bridge.update(frame: .init(snapshot: .init(rootInstanceID: 1, instances: [], values: []),
            geometry: .captured([textRunName: .init(renderRevision: 1,
                worldTransform: .identity, contentTransform: .identity, textBounds: .zero,
                layout: .init(transform: .identity, bounds: CGRect(x: 0, y: 0, width: 100, height: 40)),
                firstBaseline: nil)])))
    }

    private func makePlan(secure: Bool? = nil, textInputName: String = "editable", multiline: Bool? = nil) -> NativeExperienceRenderPlan {
        let input = NativeExperienceTextInput(inputId: "input", screenId: "screen", artboardId: "a",
            viewNodeId: "v", renderedNodeId: "r", textInputName: textInputName, value: "saved", placeholder: "Name", editable: true,
            geometry: .init(xPath: "x", yPath: "y", widthPath: "w", heightPath: "h", rotationPath: "r",
                scaleXPath: "sx", scaleYPath: "sy"),
            style: .init(fontFamily: "system", fontWeight: "normal", fontStyle: "normal", fontSize: 16,
                lineHeight: 20, letterSpacing: 0, color: 0xFF123456, fontAssetUniqueName: "", textAlign: nil),
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
            renderRevision: 1, treeVersion: 1, nodes: [node]), fieldsByTextRun: [:], nativeInputs: ["editable": [.init(nodeID: 1, geometry: .init(
                renderRevision: 1, worldTransform: .identity, textBounds: .zero,
                layout: .init(transform: .identity, bounds: CGRect(x: 0, y: 0, width: 100, height: 40)),
                firstBaseline: nil, obscured: flags & NuxieNativeSemanticNode.obscured != 0, multiline: false))]])
    }
}
#endif
