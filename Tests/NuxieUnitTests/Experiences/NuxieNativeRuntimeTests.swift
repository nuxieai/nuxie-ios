#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import Darwin
import Foundation
import QuartzCore
import XCTest
@testable import NuxieRuntime

final class NuxieNativeRuntimeTests: XCTestCase {
    func testExecutorPinsEveryOperationToOneDedicatedOSThread() async throws {
        let executor = NuxieRuntimeSerialExecutor()
        let caller = UInt64(pthread_mach_thread_np(pthread_self()))

        async let first = executor.call {
            UInt64(pthread_mach_thread_np(pthread_self()))
        }
        async let second = executor.call {
            UInt64(pthread_mach_thread_np(pthread_self()))
        }
        let identities = try await [first, second]

        XCTAssertEqual(Set(identities).count, 1)
        XCTAssertNotEqual(identities[0], caller)
    }

    func testExecutorShutdownIsIdempotentAndRejectsNewWork() async {
        let executor = NuxieRuntimeSerialExecutor()
        executor.shutdown()
        executor.shutdown()

        do {
            _ = try await executor.call { 1 }
            XCTFail("Expected a closed executor error")
        } catch {
            XCTAssertEqual(error as? NuxieRuntimeExecutorError, .closed)
        }
    }

    func testExecutorCanReleaseItsLastOwnerOnTheWorkerThread() async {
        let released = expectation(description: "executor released on its worker")
        let holder = RuntimeExecutorHolder(NuxieRuntimeSerialExecutor())
        holder.executor?.enqueue {
            holder.executor = nil
            released.fulfill()
        }

        await fulfillment(of: [released], timeout: 1)
        XCTAssertNil(holder.executor)
    }

    func testStaticFixtureRendersThroughSwiftNativeCWrappers() async throws {
        let runtime = try await NuxieNativeRuntime.open(
            bytes: try staticFixture(),
            artboardName: "Two",
            player: .staticArtboard,
            pixelWidth: 64,
            pixelHeight: 64
        )
        let artboards = try await runtime.artboards()
        let playerInfo = try await runtime.playerInfo()
        XCTAssertEqual(artboards.map(\.name), ["Two", "One"])
        XCTAssertEqual(playerInfo.kind, .staticArtboard)

        _ = try await runtime.step(elapsedSeconds: 0)
        let outcome = try await render(runtime)
        XCTAssertEqual(outcome.disposition, .presented)
        XCTAssertEqual(outcome.health, .healthy)
        XCTAssertGreaterThan(outcome.drawCalls, 0)

        try await runtime.close()
        try await runtime.close()
        XCTAssertEqual(artboards.map(\.name), ["Two", "One"])
    }

    func testStateMachineDataBindingCopiesOwnedResultsBeforeClose() async throws {
        let runtime = try await NuxieNativeRuntime.open(
            bytes: try fixture(named: "data_binding_test", extension: "riv"),
            artboardName: "Artboard",
            player: .stateMachine("State Machine 1"),
            pixelWidth: 64,
            pixelHeight: 64,
            bindDefaultViewModel: true
        )
        let catalog = try await runtime.viewModelCatalog()
        let testSchema = try XCTUnwrap(catalog.schemas.first { $0.name == "Test" })
        XCTAssertTrue(
            catalog.properties[testSchema.propertyRange].contains {
                $0.name == "Number" && $0.kind == .number
            }
        )
        let mutation = try await runtime.setNumber(42, path: "Number", correlationID: 77)
        XCTAssertEqual(mutation.appliedCount, 1)
        XCTAssertEqual(mutation.correlationID, 77)
        XCTAssertEqual(mutation.changes.count, 1)
        XCTAssertEqual(mutation.changes.first?.origin, .caller)
        XCTAssertEqual(mutation.changes.first?.value, .number(42))

        let snapshot = try await runtime.snapshot()
        XCTAssertEqual(
            snapshot.values.first(where: { $0.name == "Number" })?.value,
            .number(42)
        )
        let step = try await runtime.step(elapsedSeconds: 0.016, correlationID: 78)
        let outcome = try await render(runtime)
        XCTAssertFalse(step.events.contains { $0.name.isEmpty && !$0.properties.isEmpty })
        XCTAssertEqual(outcome.disposition, .presented)

        try await runtime.close()
        XCTAssertEqual(
            snapshot.values.first(where: { $0.name == "Number" })?.name,
            "Number"
        )
        XCTAssertEqual(mutation.changes.first?.correlationID, 77)
        XCTAssertEqual(catalog.schemas.first { $0.name == "Test" }?.name, "Test")
    }

    func testActorUsesOneNoncallerThreadAndRejectsCallsAfterClose() async throws {
        let runtime = try await NuxieNativeRuntime.open(
            bytes: try staticFixture(),
            artboardName: "Two",
            player: .staticArtboard,
            pixelWidth: 16,
            pixelHeight: 16
        )
        let caller = UInt64(pthread_mach_thread_np(pthread_self()))
        async let first = runtime.executorThreadIdentity()
        async let second = runtime.executorThreadIdentity()
        let identities = try await [first, second]
        XCTAssertEqual(Set(identities).count, 1)
        XCTAssertNotEqual(identities[0], caller)

        try await runtime.close()
        do {
            _ = try await runtime.playerInfo()
            XCTFail("Expected closed runtime")
        } catch {
            XCTAssertEqual(error as? NuxieNativeRuntimeError, .closed)
        }
    }

    func testActorDeinitDoesNotRetainItself() async throws {
        weak var weakRuntime: NuxieNativeRuntime?
        do {
            var runtime: NuxieNativeRuntime? = try await NuxieNativeRuntime.open(
                bytes: try staticFixture(),
                artboardName: "Two",
                player: .staticArtboard,
                pixelWidth: 16,
                pixelHeight: 16
            )
            weakRuntime = runtime
            runtime = nil
        }
        for _ in 0..<20 where weakRuntime != nil {
            await Task.yield()
        }
        XCTAssertNil(weakRuntime)
    }

    private func render(_ runtime: NuxieNativeRuntime) async throws
        -> NuxieNativeRendererOutcome
    {
        let device = try await runtime.metalDevice()
        let layer = CAMetalLayer()
        layer.device = device.value
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.drawableSize = CGSize(width: 64, height: 64)
        layer.maximumDrawableCount = 2
        layer.allowsNextDrawableTimeout = true
        guard let drawable = layer.nextDrawable() else {
            throw XCTSkip("This host cannot vend a CAMetalDrawable")
        }
        return try await runtime.render(
            drawable: .available(NuxieNativeDrawable(drawable)),
            clearColor: 0xFF11_2233
        )
    }

    private func staticFixture() throws -> Data {
        let encoded = try fixture(named: "nuxie_runtime_two_artboards", extension: "riv.base64")
        guard let decoded = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return decoded
    }

    private func fixture(named name: String, extension fileExtension: String) throws -> Data {
        let testBundle = Bundle(for: Self.self)
        if let url = testBundle.url(
            forResource: name,
            withExtension: fileExtension
        ) {
            return try Data(contentsOf: url)
        }

        // SwiftPM puts processed test resources in a sibling bundle, while
        // Xcode copies them into the XCTest bundle itself. Search only those
        // immediate sibling bundles so this remains deterministic.
        let siblings = try FileManager.default.contentsOfDirectory(
            at: testBundle.bundleURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )
        for sibling in siblings where sibling.pathExtension == "bundle" {
            if let url = Bundle(url: sibling)?.url(
                forResource: name,
                withExtension: fileExtension
            ) {
                return try Data(contentsOf: url)
            }
        }
        throw CocoaError(.fileNoSuchFile)
    }
}

private final class RuntimeExecutorHolder: @unchecked Sendable {
    var executor: NuxieRuntimeSerialExecutor?

    init(_ executor: NuxieRuntimeSerialExecutor) {
        self.executor = executor
    }
}
#endif
