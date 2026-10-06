#if os(iOS) && !targetEnvironment(macCatalyst)
import UIKit
import QuartzCore
import XCTest
@_spi(Testing) @testable import Nuxie
@testable import NuxieRuntime

@MainActor
final class ExperienceHardwareInputTests: XCTestCase {
    private var directory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/runtime/rive-focus")
    }

    func testUIKitKeysAndTypingReachRiveInTheirStep() async throws {
        let payload = try await ExperienceInputFixture.payload(defaultViewModelName: "ViewModel1",
            scene: Data(contentsOf: directory.appendingPathComponent("text_input_event.riv")))
        let probe = InputStepProbe()
        let controller = try ExperienceInputFixture.makeController(payload, probe: probe)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 640)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        controller.view.layoutIfNeeded()
        do {
            try await controller.mountInteractiveScreen()
            await controller.enter(reduceMotion: true)
            await controller.activate(reduceMotion: true)
            // The upstream default instance starts with three false flags.
            probe.values = ["isFocused": false, "hasKeyed": false, "hasTexted": false]
            XCTAssertFalse(controller.receiveHardwareKey(hid: UIKeyboardHIDUsage.keyboardEscape.rawValue,
                modifiers: 0, pressed: true, repeated: false), "An unfocused Rive player must leave Escape to the platform")
            let tab = HardwarePress(HardwareKey(.keyboardTab), time: 1)
            controller.pressesBegan([tab], with: nil)
            try await advance(controller, probe: probe)
            XCTAssertEqual(controller.riveFocusState, .init(hasFocus: true, expectsKeyboardInput: true))
            XCTAssertTrue(controller.receiveHardwareKey(hid: UIKeyboardHIDUsage.keyboardEscape.rawValue,
                modifiers: 0, pressed: true, repeated: false))
            XCTAssertTrue(controller.receiveHardwareKey(hid: UIKeyboardHIDUsage.keyboardEscape.rawValue,
                modifiers: 0, pressed: false, repeated: false))
            XCTAssertTrue(controller.receiveHardwareKey(hid: UIKeyboardHIDUsage.keyboardEscape.rawValue,
                modifiers: 0, pressed: true, repeated: false))
            XCTAssertTrue(controller.receiveFocusInput(.clear))
            try await advance(controller, probe: probe)
            XCTAssertFalse(controller.riveFocusState.hasFocus)
            XCTAssertTrue(controller.receiveHardwareKey(hid: UIKeyboardHIDUsage.keyboardEscape.rawValue,
                modifiers: 0, pressed: false, repeated: false), "An accepted press keeps its release after Rive loses focus")
            XCTAssertTrue(controller.receiveFocusInput(.next))
            try await advance(controller, probe: probe)
            var observed = [probe.flags]
            controller.pressesBegan([HardwarePress(HardwareKey(.keyboardB), time: 2)], with: nil)
            try await advance(controller, probe: probe)
            observed.append(probe.flags)
            XCTAssertTrue(controller.receiveFocusInput(.text("b")))
            try await advance(controller, probe: probe)
            observed.append(probe.flags)
            let editor = UITextField(frame: CGRect(x: 0, y: 0, width: 100, height: 30))
            controller.view.addSubview(editor)
            XCTAssertTrue(editor.becomeFirstResponder())
            controller.pressesBegan([HardwarePress(HardwareKey(.keyboardA), time: 3)], with: nil)
            try await advance(controller, probe: probe)
            XCTAssertEqual(probe.flags, [true, false, true], "Native editing must not also reach Rive")
            controller.pressesEnded([HardwarePress(HardwareKey(.keyboardA), time: 4, pressed: false)], with: nil)
            editor.resignFirstResponder()
            editor.removeFromSuperview()
            await waitForScreenResponder(controller)
            controller.pressesBegan([HardwarePress(HardwareKey(.keyboardA), time: 5)], with: nil)
            try await advance(controller, probe: probe)
            observed.append(probe.flags)
            struct Oracle: Decodable { struct Text: Decodable { let checks: [[Bool]] }; let text: Text }
            let expected = try JSONDecoder().decode(Oracle.self,
                from: Data(contentsOf: directory.appendingPathComponent("expectations.json")))
            XCTAssertEqual(observed, expected.text.checks)
            XCTAssertNil(probe.failure)
        } catch {
            await controller.shutdownInteractiveScreen()
            throw error
        }
        await controller.shutdownInteractiveScreen()
        XCTAssertFalse(controller.receiveHardwareKey(hid: 4, modifiers: 0, pressed: true, repeated: false))
    }

    func testHardwareKeyboardFixtureMatchesUpstreamCounts() async throws {
        let children: [[String: Any]] = [
            ["viewModelId": "KeyboardInputChildVM", "vmInstanceId": "key-e", "instanceName": "Instance 4"],
            ["viewModelId": "KeyboardInputChildVM", "vmInstanceId": "key-d", "instanceName": "Instance 3"],
            ["viewModelId": "KeyboardInputChildVM", "vmInstanceId": "key-c", "instanceName": "Instance 2"],
            ["viewModelId": "KeyboardInputChildVM", "vmInstanceId": "key-b", "instanceName": "Instance 1"],
            ["viewModelId": "KeyboardInputChildVM", "vmInstanceId": "key-a", "instanceName": "Instance"],
        ]
        let payload = try await ExperienceInputFixture.payload(defaultViewModelName: "KeyboardInputVM",
            values: [JourneyViewModelValue(viewModelName: "KeyboardInputVM", instanceId: "root-sdk-id",
                path: "children", value: AnyCodable(children))],
            scene: Data(contentsOf: directory.appendingPathComponent("keyboard_listener.riv")),
            artboardName: "KeyboardInput")
        let inspection = try await NuxieNativeRuntime.open(bytes: payload.sceneBytes,
            artboardName: "KeyboardInput", player: .stateMachine("State Machine 1"),
            pixelWidth: 64, pixelHeight: 64, bindDefaultViewModel: true)
        let authored: NuxieNativeViewModelSnapshot
        let catalog: NuxieNativeViewModelCatalog
        do {
            catalog = try await inspection.viewModelCatalog()
            authored = try await inspection.snapshot()
        }
        catch { try? await inspection.close(); throw error }
        try await inspection.close()
        let schemaNames = Dictionary(uniqueKeysWithValues: catalog.schemas.map { ($0.index, $0.name) })
        try assertKeyboardGraph(root: authored.rootInstanceID,
            schemas: Dictionary(uniqueKeysWithValues: authored.instances.map { ($0.id, schemaNames[$0.schemaIndex] ?? "") })) { owner, name in
            let value = try XCTUnwrap(authored.values.first { $0.ownerInstanceID == owner && $0.name == name }).value
            switch value {
            case .bytes(let bytes): return .text(try XCTUnwrap(String(data: bytes, encoding: .utf8)))
            case .number(let number): return .number(number)
            case .bool(let flag): return .bool(flag)
            case .list(let ids): return .list(ids)
            default: throw KeyboardGraphError.unexpectedValue
            }
        }
        let boundScreen = try await ExperienceInteractiveScreen.open(payload: payload, pixelWidth: 64, pixelHeight: 64)
        let bound: ExperienceInteractiveViewModelSnapshot
        do { bound = try await boundScreen.snapshot() }
        catch { try? await boundScreen.close(); throw error }
        try await boundScreen.close()
        try assertKeyboardGraph(root: bound.rootInstanceID,
            schemas: Dictionary(uniqueKeysWithValues: bound.instances.map { ($0.id, schemaNames[$0.schemaIndex] ?? "") })) { owner, name in
            let value = try XCTUnwrap(bound.values.first { $0.ownerInstanceID == owner && $0.name == name }).value
            switch value {
            case .bytes(let bytes): return .text(try XCTUnwrap(String(data: bytes, encoding: .utf8)))
            case .number(let number): return .number(number)
            case .bool(let flag): return .bool(flag)
            case .list(let ids): return .list(ids)
            default: throw KeyboardGraphError.unexpectedValue
            }
        }
        let initial = try XCTUnwrap(bound.values.first { $0.ownerInstanceID == bound.rootInstanceID && $0.name == "keyCount" })
        guard case .number(let initialCount) = initial.value else { throw KeyboardGraphError.unexpectedValue }
        let probe = InputStepProbe(modelName: "KeyboardInputVM")
        probe.values["keyCount"] = initialCount
        let controller = try ExperienceInputFixture.makeController(payload, probe: probe, fixtureName: "keyboard_listener")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 640)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        controller.view.layoutIfNeeded()
        do {
            try await controller.mountInteractiveScreen()
            await controller.enter(reduceMotion: true)
            await controller.activate(reduceMotion: true)
            var time: TimeInterval = 0
            func key(_ usage: UIKeyboardHIDUsage, _ pressed: Bool = true, _ modifiers: UIKeyModifierFlags = []) {
                time += 1
                let press = HardwarePress(HardwareKey(usage, flags: modifiers), time: time, pressed: pressed)
                if pressed { controller.pressesBegan([press], with: nil) }
                else { controller.pressesEnded([press], with: nil) }
            }
            key(.keyboardTab)
            key(.keyboardTab, false)
            try await advance(controller, probe: probe)
            var observed: [Double] = []
            func count() -> Double { (probe.values["keyCount"] as? NSNumber)?.doubleValue ?? -1 }
            key(.keyboardA)
            try await advance(controller, probe: probe); observed.append(count())
            key(.keyboardA)
            try await advance(controller, probe: probe); observed.append(count())
            key(.keyboardA, false)
            try await advance(controller, probe: probe); observed.append(count())
            key(.keyboardA, true, .shift)
            try await advance(controller, probe: probe); observed.append(count())
            key(.keyboardE, false); key(.keyboardE); key(.keyboardE)
            observed.append(count()); try await advance(controller, probe: probe)
            key(.keyboardB)
            observed.append(count()); try await advance(controller, probe: probe)
            key(.keyboardB, false)
            try await advance(controller, probe: probe); observed.append(count())
            // The second began is synthetic and proves repeat mapping only. B down is ignored by this fixture.
            key(.keyboardB); key(.keyboardB)
            try await advance(controller, probe: probe); observed.append(count())
            key(.keyboardD)
            try await advance(controller, probe: probe); observed.append(count())
            key(.keyboardD, false); key(.keyboardD, true, [.shift, .command])
            try await advance(controller, probe: probe); observed.append(count())
            key(.keyboardC, true, [.shift, .command])
            try await advance(controller, probe: probe); observed.append(count())
            key(.keyboardC, false, [.shift, .command]); key(.keyboardC, true, .shift)
            try await advance(controller, probe: probe); observed.append(count())
            key(.keyboardX, true, .shift)
            try await advance(controller, probe: probe); observed.append(count())
            struct Oracle: Decodable { struct Keyboard: Decodable { let checks: [Double] }; let keyboard: Keyboard }
            let expected = try JSONDecoder().decode(Oracle.self,
                from: Data(contentsOf: directory.appendingPathComponent("expectations.json")))
            XCTAssertEqual(observed, expected.keyboard.checks)
            key(.keyboardA, false, .shift)
            key(.keyboardA)
            try await advance(controller, probe: probe)
            XCTAssertEqual(count(), 7)
            let editor = UITextField(frame: CGRect(x: 0, y: 0, width: 100, height: 30))
            controller.view.addSubview(editor)
            XCTAssertTrue(editor.becomeFirstResponder())
            // The editor can consume key-up while it owns the keyboard.
            editor.resignFirstResponder()
            editor.removeFromSuperview()
            await waitForScreenResponder(controller)
            key(.keyboardA)
            try await advance(controller, probe: probe)
            XCTAssertEqual(count(), 8, "A press after native editing is not a repeat of the old held key")
            controller.view.addSubview(editor)
            XCTAssertTrue(editor.becomeFirstResponder())
            key(.keyboardB)
            editor.resignFirstResponder()
            editor.removeFromSuperview()
            await waitForScreenResponder(controller)
            key(.keyboardB, false)
            try await advance(controller, probe: probe)
            XCTAssertEqual(count(), 8, "A key released after native editing must not reach a Rive key-up handler")
            controller.setContentHidden(true)
            key(.keyboardB)
            controller.setContentHidden(false)
            key(.keyboardB, false)
            try await advance(controller, probe: probe)
            XCTAssertEqual(count(), 8, "A rejected hidden press must not authorize a later release")
            key(.keyboardB)
            controller.setContentHidden(true)
            controller.setContentHidden(false)
            key(.keyboardB, false)
            try await advance(controller, probe: probe)
            XCTAssertEqual(count(), 8, "Discarding queued input must retire the press ownership too")
            XCTAssertNil(probe.failure)
        } catch {
            await controller.shutdownInteractiveScreen()
            throw error
        }
        await controller.shutdownInteractiveScreen()
    }

    func testIdleFrameRetiresFocusAfterBoundOpacityHidesControl() async throws {
        let bytes = try Data(contentsOf: directory.appendingPathComponent("focus_collapsing.riv"))
        let inspection = try await NuxieNativeRuntime.open(bytes: bytes, artboardName: "Artboard",
            player: .stateMachine("State Machine 1"), pixelWidth: 64, pixelHeight: 64, bindDefaultViewModel: true)
        let modelName: String
        do {
            let snapshot = try await inspection.snapshot()
            let root = try XCTUnwrap(snapshot.instances.first { $0.id == snapshot.rootInstanceID })
            let catalog = try await inspection.viewModelCatalog()
            modelName = try XCTUnwrap(catalog.schemas.first { $0.index == root.schemaIndex }).name
            try await inspection.close()
        } catch { try? await inspection.close(); throw error }
        let payload = try await ExperienceInputFixture.payload(defaultViewModelName: modelName, scene: bytes)
        let probe = InputStepProbe(modelName: modelName)
        let controller = try ExperienceInputFixture.makeController(payload, probe: probe, fixtureName: "focus_collapsing")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 640)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        controller.view.layoutIfNeeded()
        do {
            try await controller.mountInteractiveScreen()
            await controller.enter(reduceMotion: true)
            await controller.activate(reduceMotion: true)
            for _ in 0..<2 {
                XCTAssertTrue(controller.receiveHardwareKey(hid: UIKeyboardHIDUsage.keyboardTab.rawValue,
                    modifiers: 0, pressed: true, repeated: false))
                controller.pressesEnded([HardwarePress(HardwareKey(.keyboardTab), time: 2, pressed: false)], with: nil)
                try await advance(controller, probe: probe)
            }
            XCTAssertTrue(controller.riveFocusState.hasFocus)
            XCTAssertTrue(controller.applyValue(path: .init(viewModelName: modelName, path: "opacity"),
                value: 0, screenId: nil, instanceId: nil))
            try await advance(controller, probe: probe)
            try await advance(controller, probe: probe)
            XCTAssertFalse(controller.riveFocusState.hasFocus)
            XCTAssertFalse(controller.receiveHardwareKey(hid: UIKeyboardHIDUsage.keyboardEscape.rawValue,
                modifiers: 0, pressed: true, repeated: false))
            XCTAssertTrue(controller.applyValue(path: .init(viewModelName: modelName, path: "opacity"),
                value: 1, screenId: nil, instanceId: nil))
            try await advance(controller, probe: probe)
            for _ in 0..<2 {
                XCTAssertTrue(controller.receiveFocusInput(.next))
                try await advance(controller, probe: probe)
            }
            XCTAssertTrue(controller.riveFocusState.hasFocus)
            XCTAssertTrue(controller.receiveHardwareKey(hid: UIKeyboardHIDUsage.keyboardEscape.rawValue,
                modifiers: 0, pressed: true, repeated: false))
            XCTAssertTrue(controller.receiveHardwareKey(hid: UIKeyboardHIDUsage.keyboardEscape.rawValue,
                modifiers: 0, pressed: false, repeated: false))
        } catch {
            await controller.shutdownInteractiveScreen()
            throw error
        }
        await controller.shutdownInteractiveScreen()
    }

    func testOneHeldUIKitKeyProducesOneNonrepeatDownAndOneUp() async throws {
        let children: [[String: Any]] = [
            ["viewModelId": "KeyboardInputChildVM", "vmInstanceId": "key-e", "instanceName": "Instance 4"],
            ["viewModelId": "KeyboardInputChildVM", "vmInstanceId": "key-d", "instanceName": "Instance 3"],
            ["viewModelId": "KeyboardInputChildVM", "vmInstanceId": "key-c", "instanceName": "Instance 2"],
            ["viewModelId": "KeyboardInputChildVM", "vmInstanceId": "key-b", "instanceName": "Instance 1"],
            ["viewModelId": "KeyboardInputChildVM", "vmInstanceId": "key-a", "instanceName": "Instance"],
        ]
        let payload = try await ExperienceInputFixture.payload(defaultViewModelName: "KeyboardInputVM",
            values: [JourneyViewModelValue(viewModelName: "KeyboardInputVM", instanceId: "root-sdk-id",
                path: "children", value: AnyCodable(children))],
            scene: Data(contentsOf: directory.appendingPathComponent("keyboard_listener.riv")),
            artboardName: "KeyboardInput")
        let probe = InputStepProbe(modelName: "KeyboardInputVM")
        probe.values["keyCount"] = 0
        let controller = try ExperienceInputFixture.makeController(payload, probe: probe, fixtureName: "keyboard_listener")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 640)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        controller.view.layoutIfNeeded()
        do {
            try await controller.mountInteractiveScreen()
            await controller.enter(reduceMotion: true)
            await controller.activate(reduceMotion: true)
            controller.pressesBegan([HardwarePress(HardwareKey(.keyboardTab), time: 1)], with: nil)
            controller.pressesEnded([HardwarePress(HardwareKey(.keyboardTab), time: 2, pressed: false)], with: nil)
            try await advance(controller, probe: probe)
            controller.pressesBegan([HardwarePress(HardwareKey(.keyboardA), time: 3)], with: nil)
            try await advance(controller, probe: probe)
            XCTAssertEqual((probe.values["keyCount"] as? NSNumber)?.intValue, 1, "The nonrepeat A-down listener fires once")
            try await advance(controller, probe: probe)
            try await advance(controller, probe: probe)
            XCTAssertEqual((probe.values["keyCount"] as? NSNumber)?.intValue, 1, "A held key synthesizes no more downs")
            controller.pressesEnded([HardwarePress(HardwareKey(.keyboardA), time: 4, pressed: false)], with: nil)
            try await advance(controller, probe: probe)
            XCTAssertEqual((probe.values["keyCount"] as? NSNumber)?.intValue, 2, "The A-up listener fires once")
        } catch {
            await controller.shutdownInteractiveScreen()
            throw error
        }
        await controller.shutdownInteractiveScreen()
    }

    private enum KeyboardGraphError: Error { case unexpectedValue }
    private enum KeyboardValue: Equatable {
        case text(String), number(Float), bool(Bool), list([UInt64])
    }

    private func assertKeyboardGraph(root: UInt64, schemas: [UInt64: String],
        read: (UInt64, String) throws -> KeyboardValue) throws {
        XCTAssertEqual(schemas[root], "KeyboardInputVM")
        XCTAssertEqual(try read(root, "rootKey"), .text("Initial value"))
        XCTAssertEqual(try read(root, "input"), .text("Initial value"))
        XCTAssertEqual(try read(root, "keyCount"), .number(0))
        guard case .list(let children) = try read(root, "children") else { throw KeyboardGraphError.unexpectedValue }
        XCTAssertEqual(children.count, 5)
        XCTAssertEqual(Set(children).count, 5)
        XCTAssertEqual(Set(schemas.keys), Set(children + [root]))
        for (id, key) in zip(children, ["e", "d", "c", "b", "a"]) {
            XCTAssertEqual(schemas[id], "KeyboardInputChildVM")
            XCTAssertEqual(try read(id, "key"), .text(key))
            XCTAssertEqual(try read(id, "isFocused"), .bool(false))
            XCTAssertEqual(try read(id, "isFocused2"), .bool(false))
        }
    }

    private func waitForScreenResponder(_ controller: ExperienceScreenViewController) async {
        let deadline = Date().addingTimeInterval(2)
        while !controller.isFirstResponder, Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(controller.isFirstResponder, "The screen resumes hardware delivery after native editing")
    }

    private func advance(_ controller: ExperienceScreenViewController, probe: InputStepProbe) async throws {
        controller.advance(delta: 0.016)
        let deadline = Date().addingTimeInterval(5)
        while !controller.hasCompletedLatestFrame, Date() < deadline {
            if let failure = probe.failure { throw failure }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        if let failure = probe.failure { throw failure }
        XCTAssertTrue(controller.hasCompletedLatestFrame, "The latest input frame finished")
    }

}

@MainActor
enum ExperienceInputFixture {
    nonisolated static var focusDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/runtime/rive-focus")
    }
    static func makeController(_ payload: AuthenticatedRuntimePayload, probe: InputStepProbe, fixtureName: String = "text_input_event", directory: URL = focusDirectory,
        acquireDrawable: @escaping @MainActor (CAMetalLayer) -> (any CAMetalDrawable)? = { $0.nextDrawable() }) throws -> ExperienceScreenViewController {
        let experience = Experience(id: "state-experience", versionId: "focus-version", buildId: "state-build",
            artifactContentHash: nil, authenticatedReleaseID: nil, behaviorPresentation: .fullScreenDefault,
            behaviorPresentationScreens: [:], assetBaseURL: directory, journey: payload.journey, definition: nil)
        let acquired = AcquiredExperienceArtifact(identity: .init(experienceId: experience.id, buildId: experience.buildId),
            sceneURL: directory.appendingPathComponent(fixtureName + ".riv"), sceneBytes: payload.sceneBytes,
            assetURLsByUniqueName: [:], source: .cache, payload: payload,
            interactivePreparation: ExperienceInteractivePreparationHandle(cache: ExperienceInteractivePreparationCache(),
                provenance: "hosted-focus-" + UUID().uuidString, payload: payload), products: [], resourceMetrics: .zero)
        let controller = ExperienceScreenViewController(experience: experience, artifact: .init(acquired: acquired),
            screen: try XCTUnwrap(payload.renderPlan.screens.first), reduceMotion: true,
            usesSystemDisplayLink: false, acquireDrawable: acquireDrawable, delegate: probe)
        controller.onRuntimeFailure = { probe.failure = $0 }
        return controller
    }

    static func payload(
        defaultViewModelName: String?,
        values: [JourneyViewModelValue]? = nil,
        scene suppliedScene: Data? = nil,
        artboardName: String = "Artboard",
        semantics: Bool = false
    ) async throws -> AuthenticatedRuntimePayload {
        let scene = try XCTUnwrap(suppliedScene)
        let catalog = try await NuxieNativeRuntime.inspectAssets(bytes: scene)
        var images: [NativeExperienceImageAsset] = []
        var fonts: [NativeExperienceFontAsset] = []
        var assetMembers: [(String, Data)] = []
        for descriptor in catalog where descriptor.kind == .image || descriptor.kind == .font {
            guard descriptor.isEmbedded, let authoredID = descriptor.authoredID else {
                throw XCTSkip("State fixture requires only embedded identified assets")
            }
            let uniqueName = "\(descriptor.name)-\(authoredID)"
            let assetBytes = Data("asset-\(descriptor.ordinal)".utf8)
            let assetHash = SHA256Provider.hexDigest(assetBytes)
            let fileExtension = descriptor.kind == .image ? "png" : "ttf"
            let member = "assets/sha256/\(assetHash).\(fileExtension)"
            assetMembers.append((member, assetBytes))
            if descriptor.kind == .image {
                images.append(NativeExperienceImageAsset(
                    location: .embedded(member: member),
                    authoredAssetId: UInt64(authoredID),
                    assetUniqueName: uniqueName,
                    sha256: assetHash,
                    sizeBytes: assetBytes.count,
                    contentType: "image/png",
                    required: true
                ))
            } else {
                fonts.append(NativeExperienceFontAsset(
                    location: .embedded(member: member),
                    authoredAssetId: UInt64(authoredID),
                    assetUniqueName: uniqueName,
                    family: "Inter",
                    weight: "400",
                    style: "normal",
                    sha256: assetHash,
                    sizeBytes: assetBytes.count,
                    contentType: "font/ttf",
                    format: "ttf",
                    required: true
                ))
            }
        }
        let journey = JourneyDocument(
            screens: [JourneyScreen(
                id: "state-screen",
                defaultViewModelName: defaultViewModelName,
                defaultInstanceId: defaultViewModelName == nil ? nil : "root-sdk-id"
            )],
            viewModelValues: values ?? []
        )
        let sceneHash = SHA256Provider.hexDigest(scene)
        let bytesByPath = Dictionary(uniqueKeysWithValues: assetMembers)
        let runtimeAssets = try images.map { image in
            AuthenticatedRuntimeAsset(
                kind: .image,
                authoredAssetID: try XCTUnwrap(UInt32(exactly: image.authoredAssetId)),
                assetUniqueName: image.assetUniqueName,
                sourceKey: image.location.contentAddressedPath,
                contentType: image.contentType,
                sha256: image.sha256,
                required: image.required,
                bytes: bytesByPath[image.location.contentAddressedPath]
            )
        } + fonts.map { font in
            AuthenticatedRuntimeAsset(
                kind: .font,
                authoredAssetID: try XCTUnwrap(UInt32(exactly: font.authoredAssetId)),
                assetUniqueName: font.assetUniqueName,
                sourceKey: font.location.contentAddressedPath,
                contentType: font.contentType,
                sha256: font.sha256,
                required: font.required,
                bytes: bytesByPath[font.location.contentAddressedPath]
            )
        }
        return AuthenticatedRuntimePayload(
            authenticatedKeyID: "TEST_ONLY_DEV_KEYPAIR",
            requiredCapabilities: semantics ? ["experience-accessibility"] : [],
            renderPlan: NativeExperienceRenderPlan(
                identity: .init(
                    experienceId: "state-experience",
                    buildId: "state-build",
                    appId: "test-app",
                    environment: "test"
                ),
                scene: .init(key: "scene.riv", sha256: sceneHash, sizeBytes: scene.count),
                entry: .init(screenId: "state-screen"),
                screens: [NativeExperienceScreen(
                    screenId: "state-screen",
                    artboardId: artboardName,
                    artboardName: artboardName,
                    width: 100,
                    height: 100,
                    exit: nil
                )],
                transitions: [],
                textInputs: [],
                images: images,
                fonts: fonts
            ),
            journey: journey,
            sceneBytes: scene,
            assets: runtimeAssets
        )
    }


}

@MainActor
final class InputStepProbe: ExperienceScreenViewControllerDelegate {
    let modelName: String
    init(modelName: String = "ViewModel1") { self.modelName = modelName }
    var values: [String: Any] = [:]
    var failure: Error?
    var flags: [Bool] { ["isFocused", "hasKeyed", "hasTexted"].map { values[$0] as? Bool ?? false } }
    func experienceScreenViewControllerDidAdvance(_ controller: ExperienceScreenViewController) {}
    func screenEmissionRun(for controller: ExperienceScreenViewController) -> ScreenEmissionRun? { nil }
    func experienceScreenViewController(_ controller: ExperienceScreenViewController, didEmitScreenEmission input: ExperienceRuntimeScreenEmission, originatingRun: ScreenEmissionRun?, frameSources: ExperienceEmissionSources?) async {}
    func experienceScreenViewController(_ controller: ExperienceScreenViewController, didRequestOpenLink request: ExperienceRendererOpenLinkRequest) async { XCTFail("Unexpected link") }
    func experienceScreenViewController(_ controller: ExperienceScreenViewController, didEmitViewModelChange change: ExperienceRendererViewModelChange) {
        if change.path.viewModelName == modelName { values[change.path.path] = change.value }
    }
    func experienceScreenViewController(_ controller: ExperienceScreenViewController, didPresentDrawable drawable: ExperienceRuntimePresentedDrawable, frameNumber: UInt64) {}
    func experienceScreenViewController(_ controller: ExperienceScreenViewController, didAcceptPointerInput input: ExperienceRuntimeAcceptedPointerInput) {}
}

@MainActor
private final class HardwareKey: UIKey {
    let usage: UIKeyboardHIDUsage
    let flags: UIKeyModifierFlags

    init(_ usage: UIKeyboardHIDUsage, flags: UIKeyModifierFlags = []) {
        self.usage = usage
        self.flags = flags
        super.init()
    }

    required init?(coder: NSCoder) { fatalError("Not decoded") }
    override var keyCode: UIKeyboardHIDUsage { usage }
    override var modifierFlags: UIKeyModifierFlags { flags }
    override var characters: String { "" }
    override var charactersIgnoringModifiers: String { "" }
}

@MainActor
private final class HardwarePress: UIPress {
    let hardwareKey: UIKey
    let time: TimeInterval
    let pressPhase: UIPress.Phase

    init(_ key: UIKey, time: TimeInterval, pressed: Bool = true) {
        hardwareKey = key
        self.time = time
        pressPhase = pressed ? .began : .ended
        super.init()
    }

    override var phase: UIPress.Phase { pressPhase }
    override var key: UIKey? { hardwareKey }
    override var timestamp: TimeInterval { time }
}
#endif
