#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import Foundation
import XCTest
@testable import NuxieRuntime
@_spi(Testing) @testable import Nuxie

extension ExperienceInteractiveLayerTests {
    func testNativeRemovalProbeBindingsAreLive() async throws {
        for (mode, expected) in [("quiet", Float(0)), ("readback", 0), ("marker", 125), ("active", 125)] {
            let bytes = try Data(contentsOf: experiencePreparationRepositoryRoot()
                .appendingPathComponent("fixtures/runtime/layer-host-interim/removal-probe-\(mode).riv"))
            let runtime = try await NuxieNativeRuntime.open(bytes: bytes,
                artboardName: "LayerList", player: .stateMachine("Host"),
                pixelWidth: 100, pixelHeight: 100, bindDefaultViewModel: true)
            do {
                let root = try await runtime.rootViewModelReference()
                let row = try await runtime.makeViewModel(schemaIndex: 0)
                _ = try await runtime.mutateViewModel([.listInsert(instance: root, path: "screens", index: 0, value: row)])
                _ = try await runtime.step(elapsedSeconds: 0)
                _ = try await runtime.step(elapsedSeconds: 0.25)
                let snapshot = try await runtime.snapshot(row)
                XCTAssertTrue(snapshot.values.contains { $0.name == "probe" && $0.value == .number(expected) }, mode)
                let width: Float = mode == "readback" || mode == "active" ? 100 : 0
                XCTAssertTrue(snapshot.values.contains { $0.name == "rowWidth" && $0.value == .number(width) }, mode)
                try await runtime.close()
            } catch { try? await runtime.close(); throw error }
        }
    }

    func testNativeRemovalWithQuietBindings() async throws { try await removalMatrix(mode: "quiet") }
    func testNativeRemovalWithReadbackBinding() async throws { try await removalMatrix(mode: "readback") }
    func testNativeRemovalWithMarkerBinding() async throws { try await removalMatrix(mode: "marker") }
    func testNativeRemovalWithActiveBindings() async throws { try await removalMatrix(mode: "active") }

    private func removalMatrix(mode: String) async throws {
        for sequence in ["zero", "timed", "advanced", "two", "revisit"] {
            let bytes = try Data(contentsOf: experiencePreparationRepositoryRoot()
                .appendingPathComponent("fixtures/runtime/layer-host-interim/removal-probe-\(mode).riv"))
            let runtime = try await NuxieNativeRuntime.open(bytes: bytes,
                artboardName: "LayerList", player: .stateMachine("Host"),
                pixelWidth: 100, pixelHeight: 100, bindDefaultViewModel: true)
            var operation = "root and row allocation"
            do {
                let root = try await runtime.rootViewModelReference()
                let a = try await runtime.makeViewModel(schemaIndex: 0)
                operation = "insert A"
                _ = try await runtime.mutateViewModel([.listInsert(instance: root, path: "screens", index: 0, value: a)])
                operation = "first step(0)"
                _ = try await runtime.step(elapsedSeconds: 0)
                if sequence == "advanced" {
                    operation = "mounted step(0.25)"
                    _ = try await runtime.step(elapsedSeconds: 0.25)
                }
                if sequence == "two" {
                    operation = "insert B and step(0)"
                    let b = try await runtime.makeViewModel(schemaIndex: 1)
                    _ = try await runtime.mutateViewModel([.listInsert(instance: root, path: "screens", index: 1, value: b)])
                    _ = try await runtime.step(elapsedSeconds: 0)
                }
                operation = "remove A"
                _ = try await runtime.mutateViewModel([.listRemove(instance: root, path: "screens", index: 0)])
                operation = "snapshot retained A before step"
                let detached = try await runtime.snapshot(a)
                XCTAssertEqual(detached.rootInstanceID, a.rawValue)
                let elapsed: Float = sequence == "timed" || sequence == "two" ? 0.5 : 0
                operation = "first step(\(elapsed)) after removal"
                _ = try await runtime.step(elapsedSeconds: elapsed)
                if sequence == "revisit" {
                    operation = "reinsert kept A"
                    _ = try await runtime.mutateViewModel([.listInsert(instance: root, path: "screens", index: 0, value: a)])
                    operation = "step(0) after reinsert"
                    _ = try await runtime.step(elapsedSeconds: 0)
                    let revisited = try await runtime.snapshot(a)
                    XCTAssertEqual(revisited.rootInstanceID, a.rawValue)
                }
                operation = "following step(0.5)"
                _ = try await runtime.step(elapsedSeconds: 0.5)
                try await runtime.close()
            } catch {
                try? await runtime.close()
                XCTFail("\(mode), \(sequence), \(operation): \(error)")
            }
        }
    }
}
#endif
