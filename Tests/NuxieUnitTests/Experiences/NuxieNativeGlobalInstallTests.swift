#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import Foundation
import QuartzCore
import XCTest
@testable import NuxieRuntime

final class NuxieNativeGlobalInstallTests: XCTestCase {
    private func expectedLabels(_ key: String) throws -> [String] {
        try XCTUnwrap(expectations()[key] as? [String])
    }
    private func expectations() throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(
            "fixtures/runtime/global-values/expectations.json"))) as? [String: Any])
    }

    private func open(_ player: NuxieNativePlayerSelection = .stateMachine("Main")) async throws -> NuxieNativeRuntime {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let runtime = try await NuxieNativeRuntime.open(bytes: Data(contentsOf: root.appendingPathComponent(
            "fixtures/runtime/global-values/globals.riv")), artboardName: "GlobalValuesScreen",
            player: player, pixelWidth: 400, pixelHeight: 100, bindDefaultViewModel: true)
        addTeardownBlock { try await runtime.close() }
        return runtime
    }

    private func labels(_ runtime: NuxieNativeRuntime) async throws -> [String] {
        _ = try await runtime.step(elapsedSeconds: 0)
        let layer = CAMetalLayer()
        layer.device = try await runtime.metalDevice().value
        layer.pixelFormat = .bgra8Unorm
        layer.drawableSize = CGSize(width: 400, height: 100)
        layer.allowsNextDrawableTimeout = true
        let drawable = try XCTUnwrap(layer.nextDrawable())
        let outcome = try await runtime.render(layoutScaleFactor: 1,
            drawable: .available(NuxieNativeDrawable(drawable)))
        XCTAssertEqual(outcome.disposition, .presented)
        let capture = try await runtime.captureSemantics()
        return capture.tree.nodes.map(\.label).sorted()
    }

    func testNamedGlobalBindingRetainsIdentityAndMutationsReachScreenCopyAndListRow() async throws {
        let runtime = try await open()
        try await runtime.enableSemantics()
        let bound = try await runtime.bindGlobalViewModel(named: "Flags")
        let value = try XCTUnwrap(bound)
        _ = try await runtime.mutateViewModel([.setBool(instance: value, path: "enabled", value: true)])
        let on = try await labels(runtime)
        XCTAssertEqual(on, try expectedLabels("enabledLabels"))
        let missing = try await runtime.bindGlobalViewModel(named: "missing")
        let nonGlobal = try await runtime.bindGlobalViewModel(named: "Root")
        XCTAssertNil(missing)
        XCTAssertNil(nonGlobal)
        let retained = try await runtime.bindGlobalViewModel(named: "Flags")
        XCTAssertEqual(retained, value)
        let unchanged = try await labels(runtime)
        XCTAssertEqual(unchanged, try expectedLabels("enabledLabels"))
        _ = try await runtime.mutateViewModel([.setBool(instance: value, path: "enabled", value: false)])
        let changed = try await labels(runtime)
        XCTAssertEqual(changed, try expectedLabels("disabledLabels"))
    }

    func testOnlyStateMachinePlayersReceiveNamedGlobalBindings() async throws {
        for selection: NuxieNativePlayerSelection in [.staticArtboard, .linearAnimation("Timeline")] {
            let runtime = try await open(selection)
            try await runtime.enableSemantics()
            let before = try await labels(runtime)
            let bound = try await runtime.bindGlobalViewModel(named: "Flags")
            let value = try XCTUnwrap(bound)
            _ = try await runtime.mutateViewModel([.setBool(instance: value, path: "enabled", value: true)])
            let unchanged = try await labels(runtime)
            XCTAssertEqual(unchanged, before, "A player without a state machine retains its unbound drawing")
        }
        let runtime = try await open(.defaultSceneWithInputStateMachine("Main"))
        try await runtime.enableSemantics()
        let bound = try await runtime.bindGlobalViewModel(named: "Flags")
        let value = try XCTUnwrap(bound)
        _ = try await runtime.mutateViewModel([.setBool(instance: value, path: "enabled", value: true)])
        let on = try await labels(runtime)
        XCTAssertEqual(on, try expectedLabels("enabledLabels"))
    }
}
#endif
