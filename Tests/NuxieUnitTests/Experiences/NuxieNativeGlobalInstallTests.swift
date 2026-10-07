#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import Foundation
import QuartzCore
import XCTest
@testable import NuxieRuntime

final class NuxieNativeGlobalInstallTests: XCTestCase {
    private func expectedLabels(_ key: String) throws -> [String] {
        try XCTUnwrap(expectations()[key] as? [String])
    }
    private func expectedStatus(_ key: String) throws -> NuxieNativeStatus {
        let raw = try XCTUnwrap(expectations()[key] as? NSNumber).uint32Value
        return try XCTUnwrap(NuxieNativeStatus(rawValue: raw))
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

    private func reject(_ status: NuxieNativeStatus, _ call: () async throws -> Void) async {
        do { try await call(); XCTFail("Expected native refusal") }
        catch NuxieNativeRuntimeError.callFailed(let diagnostic) { XCTAssertEqual(diagnostic.status, status) }
        catch { XCTFail("Unexpected error: \(error)") }
    }

    func testGlobalSetRefusalMutationAndClearReachScreenCopyAndListRow() async throws {
        let runtime = try await open()
        try await runtime.enableSemantics()
        let catalog = try await runtime.viewModelCatalog()
        let flags = try XCTUnwrap(catalog.schemas.first { $0.name == "Flags" })
        let root = try XCTUnwrap(catalog.schemas.first { $0.name == "Root" })
        let value = try await runtime.makeViewModel(schemaIndex: flags.index)
        let wrong = try await runtime.makeViewModel(schemaIndex: root.index)
        _ = try await runtime.mutateViewModel([.setBool(instance: value, path: "enabled", value: true)])
        try await runtime.setGlobalViewModel(name: "Flags", instance: value)
        let on = try await labels(runtime)
        XCTAssertEqual(on, try expectedLabels("enabledLabels"))
        await reject(try expectedStatus("notFound")) { try await runtime.setGlobalViewModel(name: "missing", instance: value) }
        await reject(try expectedStatus("notFound")) { try await runtime.setGlobalViewModel(name: "Root", instance: wrong) }
        await reject(try expectedStatus("handleMismatch")) { try await runtime.setGlobalViewModel(name: "Flags", instance: wrong) }
        let retained = try await labels(runtime)
        XCTAssertEqual(retained, try expectedLabels("enabledLabels"))
        _ = try await runtime.mutateViewModel([.setBool(instance: value, path: "enabled", value: false)])
        let changed = try await labels(runtime)
        XCTAssertEqual(changed, try expectedLabels("disabledLabels"))
        _ = try await runtime.mutateViewModel([.setBool(instance: value, path: "enabled", value: true)])
        try await runtime.setGlobalViewModel(name: "Flags", instance: nil)
        let cleared = try await labels(runtime)
        XCTAssertEqual(cleared, try expectedLabels("disabledLabels"))
    }

    func testPrimaryPlayerKindControlsGlobalAdmission() async throws {
        for selection: NuxieNativePlayerSelection in [.staticArtboard, .linearAnimation("Timeline")] {
            let runtime = try await open(selection)
            let catalog = try await runtime.viewModelCatalog()
            let flags = try XCTUnwrap(catalog.schemas.first { $0.name == "Flags" })
            let value = try await runtime.makeViewModel(schemaIndex: flags.index)
            await reject(try expectedStatus("notFound")) { try await runtime.setGlobalViewModel(name: "Flags", instance: value) }
        }
        let runtime = try await open(.defaultSceneWithInputStateMachine("Main"))
        try await runtime.enableSemantics()
        let catalog = try await runtime.viewModelCatalog()
        let flags = try XCTUnwrap(catalog.schemas.first { $0.name == "Flags" })
        let value = try await runtime.makeViewModel(schemaIndex: flags.index)
        _ = try await runtime.mutateViewModel([.setBool(instance: value, path: "enabled", value: true)])
        try await runtime.setGlobalViewModel(name: "Flags", instance: value)
        let on = try await labels(runtime)
        XCTAssertEqual(on, try expectedLabels("enabledLabels"))
    }
}
#endif
