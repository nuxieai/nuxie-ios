#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import Darwin
import Foundation
import QuartzCore
import XCTest
@testable import NuxieRuntime

final class NuxieNativeRuntimeTests: XCTestCase {
    func testOneBatchCanAttachAndMutateADetachedViewModel() async throws {
        let runtime = try await NuxieNativeRuntime.open(
            bytes: try fixture(named: "data_binding_test", extension: "riv"),
            artboardName: "Artboard",
            player: .stateMachine("State Machine 1"),
            pixelWidth: 1,
            pixelHeight: 1,
            bindDefaultViewModel: true
        )
        defer { Task { try? await runtime.close() } }
        let root = try await runtime.rootViewModelReference()
        let child = try await runtime.makeViewModel(schemaIndex: 1)

        let result = try await runtime.mutateViewModel(
            [
                .listClear(instance: root, path: "List"),
                .listInsert(instance: root, path: "List", index: 0, value: child),
                .setString(
                    instance: child,
                    path: "String",
                    value: Data("atomic".utf8)
                ),
            ],
            correlationID: 1
        )
        XCTAssertEqual(result.appliedCount, 3)
        XCTAssertEqual(result.changes.count, 2)
        let snapshot = try await runtime.snapshot()
        guard case .list(let rows) = snapshot.values.first(where: {
            $0.ownerInstanceID == snapshot.rootInstanceID && $0.name == "List"
        })?.value,
        let row = rows.first else { return XCTFail("Expected attached row") }
        XCTAssertEqual(snapshot.values.first(where: {
            $0.ownerInstanceID == row && $0.name == "String"
        })?.value, .bytes(Data("atomic".utf8)))
    }

    func testAbandonedDetachedViewModelCanBeReleased() async throws {
        let runtime = try await NuxieNativeRuntime.open(
            bytes: try fixture(named: "data_binding_test", extension: "riv"),
            artboardName: "Artboard",
            player: .stateMachine("State Machine 1"),
            pixelWidth: 1,
            pixelHeight: 1,
            bindDefaultViewModel: true
        )
        defer { Task { try? await runtime.close() } }
        let child = try await runtime.makeViewModel(schemaIndex: 1)
        try await runtime.releaseViewModels([child])

        do {
            _ = try await runtime.mutateViewModel([
                .setString(instance: child, path: "String", value: Data("late".utf8))
            ])
            XCTFail("Expected a released detached handle to be unavailable")
        } catch let error as NuxieNativeRuntimeError {
            XCTAssertEqual(error, .missingHandle("view model \(child.rawValue)"))
        }
    }
    func testExecutorPinsEveryOperationToOneDedicatedOSThread() async throws {
        let executor = NuxieRuntimePinnedThreadExecutor()
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
        let executor = NuxieRuntimePinnedThreadExecutor()
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
        let holder = RuntimeExecutorHolder(NuxieRuntimePinnedThreadExecutor())
        holder.withExecutor { executor in
            executor.enqueue {
                holder.clearExecutor()
                released.fulfill()
            }
        }

        await fulfillment(of: [released], timeout: 1)
        XCTAssertFalse(holder.hasExecutor)
    }

    func testFinalExecutorOperationShutsDownAfterThrowing() async {
        enum Expected: Error {
            case failure
        }

        let executor = NuxieRuntimePinnedThreadExecutor()
        do {
            try await executor.callThenShutdown {
                throw Expected.failure
            }
            XCTFail("Expected the final operation to throw")
        } catch Expected.failure {
            // The original native destruction error remains observable.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        do {
            _ = try await executor.call { 1 }
            XCTFail("Expected the executor to be closed after the failure")
        } catch {
            XCTAssertEqual(error as? NuxieRuntimeExecutorError, .closed)
        }
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

    func testRendererCompletionAndDomainLifecycleStayOnTheNativeSeam() async throws {
        let runtime = try await NuxieNativeRuntime.open(
            bytes: try staticFixture(),
            artboardName: "Two",
            player: .staticArtboard,
            pixelWidth: 64,
            pixelHeight: 64
        )
        defer { Task { try? await runtime.close() } }
        let device = try await runtime.metalDevice()
        let firstLayer = makeLayer(device: device.value, width: 64, height: 64)
        let firstDrawable = try XCTUnwrap(firstLayer.nextDrawable())
        let firstCompletion = expectation(description: "first native frame completion")
        firstCompletion.expectedFulfillmentCount = 1

        let first = try await runtime.render(
            drawable: .available(NuxieNativeDrawable(firstDrawable)),
            completion: { firstCompletion.fulfill() }
        )
        XCTAssertEqual(first.disposition, .presented)
        await fulfillment(of: [firstCompletion], timeout: 1)

        let detached = try await runtime.detachRenderer()
        XCTAssertEqual(detached.health, .healthy)
        let reattached = try await runtime.reattachRenderer(
            pixelWidth: 64,
            pixelHeight: 64
        )
        XCTAssertEqual(reattached.disposition, .recreated)
        try await runtime.resetPlayerRendererDomain()

        let replacementDevice = try await runtime.metalDevice()
        let secondLayer = makeLayer(device: replacementDevice.value, width: 64, height: 64)
        let secondDrawable = try XCTUnwrap(secondLayer.nextDrawable())
        let secondCompletion = expectation(description: "reattached native frame completion")
        let second = try await runtime.render(
            drawable: .available(NuxieNativeDrawable(secondDrawable)),
            completion: { secondCompletion.fulfill() }
        )
        XCTAssertEqual(second.disposition, .presented)
        await fulfillment(of: [secondCompletion], timeout: 1)

        try await runtime.close()
        let rejectedCompletion = expectation(description: "rejected frame completion")
        do {
            _ = try await runtime.render(
                drawable: .timeout,
                completion: { rejectedCompletion.fulfill() }
            )
            XCTFail("Expected a closed runtime")
        } catch {
            XCTAssertEqual(error as? NuxieNativeRuntimeError, .closed)
        }
        await fulfillment(of: [rejectedCompletion], timeout: 1)
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

    func testViewModelBatchSupportsScalarTriggerAndStructuralMutationsAtomically() async throws {
        let runtime = try await NuxieNativeRuntime.open(
            bytes: try fixture(named: "data_binding_test", extension: "riv"),
            artboardName: "Artboard",
            player: .stateMachine("State Machine 1"),
            pixelWidth: 64,
            pixelHeight: 64,
            bindDefaultViewModel: true
        )
        defer { Task { try? await runtime.close() } }

        let root = try await runtime.rootViewModelReference()
        let nested = try await runtime.makeViewModel(
            schemaIndex: 1,
            authoredInstanceIndex: 0
        )
        let result = try await runtime.mutateViewModel(
            [
                .setString(instance: root, path: "String", value: Data("swift".utf8)),
                .setNumber(instance: root, path: "Number", value: 23),
                .setBool(instance: root, path: "Boolean", value: true),
                .setColor(instance: root, path: "Color", value: 0xFF11_2233),
                .setEnumeration(instance: root, path: "Enum", value: 2),
                .fireTrigger(instance: root, path: "Trigger Blue"),
                .setViewModel(instance: root, path: "Nested", value: nested),
                .listInsert(instance: root, path: "List", index: 0, value: nested),
            ],
            correlationID: 99
        )
        XCTAssertEqual(result.appliedCount, 8)
        XCTAssertEqual(result.correlationID, 99)
        XCTAssertEqual(result.changes.count, 8)
        XCTAssertTrue(result.changes.allSatisfy { $0.origin == .caller && $0.correlationID == 99 })

        let snapshot = try await runtime.snapshot()
        let rootValues = snapshot.values.filter { $0.ownerInstanceID == root.rawValue }
        XCTAssertEqual(rootValues.first { $0.name == "String" }?.value, .bytes(Data("swift".utf8)))
        XCTAssertEqual(rootValues.first { $0.name == "Number" }?.value, .number(23))
        XCTAssertEqual(rootValues.first { $0.name == "Boolean" }?.value, .bool(true))
        XCTAssertEqual(rootValues.first { $0.name == "Color" }?.value, .integer(0xFF11_2233))
        XCTAssertEqual(result.changes[6].value, .referencedInstance(nested.rawValue))
        XCTAssertEqual(result.changes[7].value, .list([nested.rawValue]))
        guard case .referencedInstance(let linked) = rootValues.first(where: { $0.name == "Nested" })?.value,
              case .list(let listed) = rootValues.first(where: { $0.name == "List" })?.value else {
            return XCTFail("Expected the committed structural snapshot")
        }
        XCTAssertEqual(listed, [linked])
    }

    func testDetachedViewModelCanBeHydratedBeforeStructuralCommit() async throws {
        let runtime = try await NuxieNativeRuntime.open(
            bytes: try fixture(named: "data_binding_test", extension: "riv"),
            artboardName: "Artboard",
            player: .stateMachine("State Machine 1"),
            pixelWidth: 64,
            pixelHeight: 64,
            bindDefaultViewModel: true
        )
        defer { Task { try? await runtime.close() } }
        let root = try await runtime.rootViewModelReference()
        let nested = try await runtime.makeViewModel(
            schemaIndex: 1,
            authoredInstanceIndex: nil
        )
        _ = try await runtime.mutateViewModel(
            [.setString(instance: nested, path: "String", value: Data("child".utf8))],
            correlationID: 1
        )
        _ = try await runtime.mutateViewModel(
            [
                .setViewModel(instance: root, path: "Nested", value: nested),
                .listClear(instance: root, path: "List"),
                .listInsert(instance: root, path: "List", index: 0, value: nested),
            ],
            correlationID: 2
        )
        let snapshot = try await runtime.snapshot()
        let rootValues = snapshot.values.filter { $0.ownerInstanceID == root.rawValue }
        guard case .referencedInstance(let linked) = rootValues.first(where: {
            $0.name == "Nested"
        })?.value else { return XCTFail("Expected linked child") }
        XCTAssertEqual(rootValues.first(where: { $0.name == "List" })?.value, .list([linked]))
        XCTAssertEqual(snapshot.values.first(where: {
            $0.ownerInstanceID == linked && $0.name == "String"
        })?.value, .bytes(Data("child".utf8)))
    }

    func testRejectedViewModelBatchRollsBackItsValidPrefix() async throws {
        let runtime = try await NuxieNativeRuntime.open(
            bytes: try fixture(named: "data_binding_test", extension: "riv"),
            artboardName: "Artboard",
            player: .stateMachine("State Machine 1"),
            pixelWidth: 64,
            pixelHeight: 64,
            bindDefaultViewModel: true
        )
        defer { Task { try? await runtime.close() } }

        let root = try await runtime.rootViewModelReference()
        let before = try await runtime.snapshot().values.first { $0.name == "Number" }?.value
        do {
            _ = try await runtime.mutateViewModel(
                [
                    .setNumber(instance: root, path: "Number", value: 91),
                    .setNumber(instance: root, path: "missing", value: 12),
                ],
                correlationID: 100
            )
            XCTFail("Expected the invalid batch to fail")
        } catch {
            // The native transaction publishes the error and rolls back.
        }
        let after = try await runtime.snapshot().values.first { $0.name == "Number" }?.value
        XCTAssertEqual(after, before)
    }

    func testTrustedScriptedFixtureReturnsGenericCommandsInAuthoredOrder() async throws {
        let scene = try sceneFromSignedPackageFixture()
        let catalog = try await NuxieNativeRuntime.inspectAssets(bytes: scene)
        XCTAssertEqual(catalog.map(\.kind), [.script])
        let runtime = try await NuxieNativeRuntime.open(
            bytes: scene,
            artboardName: "Paywall",
            player: .stateMachine("Generated Nuxie Pressable Interaction"),
            pixelWidth: 64,
            pixelHeight: 64,
            importMode: .configured(
                moduleName: "nuxie",
                expectedAssets: catalog,
                externalAssets: [:]
            )
        )
        defer { Task { try? await runtime.close() } }

        _ = try await render(runtime)
        _ = try await runtime.step(elapsedSeconds: 0.016)
        let result = try await runtime.step(
            pointers: [
                NuxieNativePointerEvent(kind: .down, x: 100, y: 728, pointerID: 1),
                NuxieNativePointerEvent(kind: .up, x: 100, y: 728, pointerID: 1),
            ],
            elapsedSeconds: 0.016,
            correlationID: 42
        )

        XCTAssertEqual(
            result.hostCommands.map(\.name),
            [
                "$response_set",
                "purchase_tapped",
                "selection_changed",
                "custom.analytics",
                "$response_set",
            ]
        )
        guard result.hostCommands.count == 5 else {
            return XCTFail("Expected five generic commands, got \(result.hostCommands.count)")
        }
        guard case .object(let validResponse) = result.hostCommands[0].value,
              case .string("plan") = validResponse.first(where: { $0.key == "field" })?.value,
              case .string("pro") = validResponse.first(where: { $0.key == "value" })?.value,
              case .object(let invalidResponse) = result.hostCommands[4].value,
              case .number(42) = invalidResponse.first(where: { $0.key == "field" })?.value else {
            return XCTFail("Expected the exact structured response command trees")
        }
    }

    func testConfiguredImportDecodesAnEmbeddedImageAgainstItsInspectedCatalog() async throws {
        let encoded = try fixture(named: "in_band_asset", extension: "riv.base64")
        guard let scene = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let catalog = try await NuxieNativeRuntime.inspectAssets(bytes: scene)
        XCTAssertEqual(catalog.count, 1)
        XCTAssertEqual(catalog.first?.kind, .image)
        XCTAssertEqual(catalog.first?.isEmbedded, true)

        let runtime = try await NuxieNativeRuntime.open(
            bytes: scene,
            artboardName: "New Artboard",
            player: .staticArtboard,
            pixelWidth: 16,
            pixelHeight: 16,
            importMode: .configured(
                moduleName: "nuxie",
                expectedAssets: catalog,
                externalAssets: [:]
            )
        )
        defer { Task { try? await runtime.close() } }
        let player = try await runtime.playerInfo()
        XCTAssertEqual(player.kind, .staticArtboard)
    }

    func testTextRunBatchRollsBackItsValidPrefix() async throws {
        let encoded = try fixture(named: "text_run_apple_seam", extension: "riv.base64")
        guard let scene = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let runtime = try await NuxieNativeRuntime.open(
            bytes: scene,
            artboardName: "Root",
            player: .staticArtboard,
            pixelWidth: 16,
            pixelHeight: 16
        )
        defer { Task { try? await runtime.close() } }

        let initiallyChanged = try await runtime.setTextRuns([
            NuxieNativeTextRunMutation(name: "headline", text: Data("accepted".utf8))
        ])
        XCTAssertTrue(initiallyChanged)
        do {
            _ = try await runtime.setTextRuns([
                NuxieNativeTextRunMutation(name: "headline", text: Data("leaked".utf8)),
                NuxieNativeTextRunMutation(name: "missing", text: Data("invalid".utf8)),
            ])
            XCTFail("Expected an unknown run to reject the batch")
        } catch {
            // The native text transaction rejects the whole batch.
        }
        let changedAfterFailure = try await runtime.setTextRuns([
            NuxieNativeTextRunMutation(name: "headline", text: Data("accepted".utf8))
        ])
        XCTAssertFalse(changedAfterFailure)
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

    private func makeLayer(
        device: any MTLDevice,
        width: Int,
        height: Int
    ) -> CAMetalLayer {
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.drawableSize = CGSize(width: width, height: height)
        layer.maximumDrawableCount = 2
        layer.allowsNextDrawableTimeout = true
        return layer
    }

    private func staticFixture() throws -> Data {
        let encoded = try fixture(named: "nuxie_runtime_two_artboards", extension: "riv.base64")
        guard let decoded = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return decoded
    }

    private func sceneFromSignedPackageFixture() throws -> Data {
        let encoded = try fixture(named: "scripted_generic_commands", extension: "nux.base64")
        guard let package = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters),
              package.count >= 16 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let count = Int(package.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self) })
        var cursor = 16
        for _ in 0..<count {
            let nameLength = Int(package.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: cursor, as: UInt16.self)
            })
            cursor += 2
            let name = String(decoding: package[cursor..<(cursor + nameLength)], as: UTF8.self)
            cursor += nameLength
            let offset = Int(package.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: cursor, as: UInt64.self)
            })
            cursor += 8
            let length = Int(package.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: cursor, as: UInt64.self)
            })
            cursor += 8
            if name == "scene" {
                return package.subdata(in: offset..<(offset + length))
            }
        }
        throw CocoaError(.fileReadCorruptFile)
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
    private let lock = NSLock()
    private var executor: NuxieRuntimePinnedThreadExecutor?

    init(_ executor: NuxieRuntimePinnedThreadExecutor) {
        self.executor = executor
    }

    var hasExecutor: Bool {
        lock.withLock { executor != nil }
    }

    func withExecutor(_ operation: (NuxieRuntimePinnedThreadExecutor) -> Void) {
        lock.withLock {
            if let executor {
                operation(executor)
            }
        }
    }

    func clearExecutor() {
        lock.withLock {
            executor = nil
        }
    }
}
#endif
