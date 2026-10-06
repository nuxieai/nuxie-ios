#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import Foundation
import XCTest
@testable import NuxieRuntime

extension NuxieNativeRuntimeTests {
    private static var focusFixture: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/runtime/rive-focus")
    }

    private func focusRuntime(_ name: String, player: NuxieNativePlayerSelection? = nil) async throws -> NuxieNativeRuntime {
        let file = try await NuxieNativePreparedFile.prepare(
            bytes: Data(contentsOf: Self.focusFixture.appendingPathComponent(name + ".riv")), importMode: .portable)
        let artboardName = name == "keyboard_listener" ? "KeyboardInput" : "Artboard"
        return try await file.openSession(artboardName: artboardName,
            player: player ?? .stateMachine("State Machine 1"), pixelWidth: 64, pixelHeight: 64, bindDefaultViewModel: true)
    }

    func testFocusTextAndKeyChangesAreInTheirStep() async throws {
        let runtime = try await focusRuntime("text_input_event")
        do {
            let first = try await runtime.step(elapsedSeconds: 0)
            let snapshot = try await runtime.snapshot()
            let rootValues = snapshot.values.filter { $0.ownerInstanceID == snapshot.rootInstanceID }
            let names = ["isFocused", "hasKeyed", "hasTexted"]
            let indices = try names.map { name in try XCTUnwrap(rootValues.first { $0.name == name }).propertyIndex }
            var values = Dictionary(uniqueKeysWithValues: rootValues.map { ($0.propertyIndex, $0.value) })
            XCTAssertTrue(first.focusResults.isEmpty)
            let expected = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
                Self.focusFixture.appendingPathComponent("expectations.json"))) as? [String: Any])
            let text = try XCTUnwrap(expected["text"] as? [String: Any])
            let checks = try XCTUnwrap(text["checks"] as? [[Bool]])
            XCTAssertEqual(checks.count, 4)
            XCTAssertTrue(checks.allSatisfy { $0.count == 3 })
            let focus = try XCTUnwrap(expected["focusState"] as? [String: Any])
            let focusState = NuxieNativeFocusState(
                hasFocus: try XCTUnwrap(focus["hasFocus"] as? Bool),
                expectsKeyboardInput: try XCTUnwrap(focus["expectsKeyboardInput"] as? Bool))
            let inputs: [NuxieNativeFocusInput] = [.next,
                .key(code: 66, modifiers: 0, pressed: true, repeated: false), .text("b"),
                .key(code: 65, modifiers: 0, pressed: true, repeated: false)]
            for (input, expected) in zip(inputs, checks) {
                let result = try await runtime.step(focusInputs: [input], elapsedSeconds: 0.016)
                XCTAssertEqual(result.focusResults.count, 1)
                XCTAssertEqual(result.focusState, focusState)
                for change in result.viewModelChanges where change.ownerInstanceID == snapshot.rootInstanceID { values[change.propertyIndex] = change.value }
                XCTAssertEqual(indices.map { values[$0] }, expected.map { .bool($0) })
            }
            let pointerOnly = try await runtime.step(pointers: [
                .init(kind: .move, x: -1, y: -1, pointerID: 1)
            ], elapsedSeconds: 0)
            XCTAssertTrue(pointerOnly.focusResults.isEmpty)
            XCTAssertEqual(pointerOnly.focusState, focusState)
            let idle = try await runtime.step(elapsedSeconds: 0)
            XCTAssertNil(idle.focusState)
            let cleared = try await runtime.step(focusInputs: [.clear], elapsedSeconds: 0)
            XCTAssertEqual(cleared.focusResults, [false])
            for change in cleared.viewModelChanges where change.ownerInstanceID == snapshot.rootInstanceID {
                values[change.propertyIndex] = change.value
            }
            XCTAssertEqual(indices.map { values[$0] }, [.bool(false), .bool(true), .bool(true)])
            XCTAssertEqual(cleared.focusState?.hasFocus, try XCTUnwrap(focus["afterClearHasFocus"] as? Bool))
            let traversed = try await runtime.step(focusInputs: [.next, .clear, .previous], elapsedSeconds: 0)
            XCTAssertEqual(traversed.focusResults, [true, false, true])
            XCTAssertEqual(traversed.focusState, focusState)
            try await runtime.close()
        } catch { try? await runtime.close(); throw error }
        try await assertCompositeFocusDelivery()
    }

    private func assertCompositeFocusDelivery() async throws {
        let directory = Self.focusFixture.deletingLastPathComponent().appendingPathComponent("composite-focus")
        struct Oracle: Decodable {
            struct Expected: Decodable { let next: [String]; let nextAgain: [String]; let previous: [String] }
            let expected: Expected
        }
        let oracle = try JSONDecoder().decode(Oracle.self,
            from: Data(contentsOf: directory.appendingPathComponent("provenance.json")))
        let runtime = try await NuxieNativeRuntime.open(
            bytes: Data(contentsOf: directory.appendingPathComponent("screen.riv")),
            artboardName: "Composite", player: .defaultSceneWithInputStateMachine("Auxiliary"),
            pixelWidth: 100, pixelHeight: 100)
        do {
            let primary = try await runtime.playerInfo()
            XCTAssertEqual(primary.name, "Primary")
            let artboards = try await runtime.artboards()
            XCTAssertEqual(artboards.first?.stateMachines.count, 2)
            _ = try await runtime.step(elapsedSeconds: 0)
            for (input, events) in [(NuxieNativeFocusInput.next, oracle.expected.next),
                                    (.next, oracle.expected.nextAgain), (.previous, oracle.expected.previous)] {
                let step = try await runtime.step(focusInputs: [input], elapsedSeconds: 0)
                XCTAssertEqual(step.focusResults, [true])
                XCTAssertEqual(step.events.map(\.name), events)
                XCTAssertEqual(step.focusState, .init(hasFocus: true, expectsKeyboardInput: false))
                let idle = try await runtime.step(elapsedSeconds: 0)
                XCTAssertEqual(idle.events.map(\.name), [])
            }
            try await runtime.close()
        } catch { try? await runtime.close(); throw error }
    }

    func testKeyboardFixtureKeepsSameStepChanges() async throws {
        let runtime = try await focusRuntime("keyboard_listener")
        do {
            _ = try await runtime.step(elapsedSeconds: 0.016)
            let snapshot = try await runtime.snapshot()
            let counter = try XCTUnwrap(snapshot.values.first { $0.ownerInstanceID == snapshot.rootInstanceID && $0.name == "keyCount" })
            var kept = counter.value
            let tab = NuxieNativeFocusInput.next
            _ = try await runtime.step(focusInputs: [tab], elapsedSeconds: 0.016)
            typealias Key = (code: UInt16, modifiers: UInt8, pressed: Bool, repeated: Bool)
            let stages: [(keys: [Key], before: Bool, after: Bool)] = [
                ([(65, 0, true, false)], false, true),
                ([(65, 0, true, true)], false, true),
                ([(65, 0, false, false)], false, true),
                ([(65, 1, true, false)], false, true),
                ([(69, 0, false, false), (69, 0, true, true), (69, 0, true, false)], true, false),
                ([(66, 0, true, false)], true, false),
                ([(66, 0, false, false)], false, true),
                ([(66, 0, true, true)], false, true),
                ([(68, 0, true, false)], false, true),
                ([(68, 9, true, false)], false, true),
                ([(67, 9, true, false)], false, true),
                ([(67, 1, true, false)], false, true),
                ([(88, 1, true, false)], false, true),
            ]
            var observed: [NuxieNativeViewModelValue] = []
            for stage in stages {
                let inputs = stage.keys.map { key in NuxieNativeFocusInput.key(
                    code: key.code, modifiers: key.modifiers, pressed: key.pressed, repeated: key.repeated) }
                if stage.before { observed.append(kept) }
                let result = try await runtime.step(focusInputs: inputs, elapsedSeconds: 0.016)
                XCTAssertEqual(result.focusResults.count, inputs.count)
                for change in result.viewModelChanges where change.ownerInstanceID == counter.ownerInstanceID && change.propertyIndex == counter.propertyIndex {
                    kept = change.value
                }
                if stage.after { observed.append(kept) }
            }
            struct Oracle: Decodable { struct Keyboard: Decodable { let checks: [Float] }; let keyboard: Keyboard }
            let expected = try JSONDecoder().decode(Oracle.self, from: Data(contentsOf:
                Self.focusFixture.appendingPathComponent("expectations.json")))
            XCTAssertEqual(observed, expected.keyboard.checks.map { .number($0) })
            try await runtime.close()
        } catch { try? await runtime.close(); throw error }
    }

    func testFocusInputLimitsAndNonStateMachine() async throws {
        let runtime = try await focusRuntime("text_input_event")
        do {
            let cases: [[NuxieNativeFocusInput]] = [Array(repeating: .next, count: 4_097),
                [.text(String(repeating: "a", count: 1_048_577))],
                Array(repeating: .text(String(repeating: "a", count: 1_048_576)), count: 5),
                [.key(code: 65, modifiers: 16, pressed: true, repeated: false)]]
            for inputs in cases {
                do { _ = try await runtime.step(focusInputs: inputs, elapsedSeconds: 0); XCTFail("Accepted an oversized focus batch") }
                catch NuxieNativeRuntimeError.invalidNativeValue { }
            }
            let maximumInputs = try await runtime.step(focusInputs: Array(repeating: .clear, count: 4_096), elapsedSeconds: 0)
            XCTAssertEqual(maximumInputs.focusResults, Array(repeating: false, count: 4_096))
            let maximumText = try await runtime.step(focusInputs: Array(
                repeating: .text(String(repeating: "a", count: 1_048_576)), count: 4), elapsedSeconds: 0)
            XCTAssertEqual(maximumText.focusResults, [false, false, false, false])
            try await runtime.close()
        } catch { try? await runtime.close(); throw error }
        for selection: NuxieNativePlayerSelection in [.staticArtboard, .linearAnimation("Timeline 1")] {
            let artwork = try await focusRuntime("text_input_event", player: selection)
            do {
                let result = try await artwork.step(focusInputs: [.next, .text("b")], elapsedSeconds: 0)
                XCTAssertTrue(result.focusResults.isEmpty)
                XCTAssertNil(result.focusState)
                try await artwork.close()
            } catch { try? await artwork.close(); throw error }
        }
    }
}
#endif
