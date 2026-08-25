#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import Darwin
import Foundation
import Metal
import QuartzCore
import XCTest
@testable import NuxieRuntime

final class NuxieNativeRuntimeTests: XCTestCase {
    func testPreparedFileOpensFreshIndependentSessionsFromOneImport() async throws {
        let prepared = try await NuxieNativePreparedFile.prepare(
            bytes: try fixture(named: "data_binding_test", extension: "riv"),
            importMode: .portable
        )
        async let firstLoad = prepared.openSession(
            artboardName: "Artboard",
            player: .stateMachine("State Machine 1"),
            pixelWidth: 1,
            pixelHeight: 1,
            bindDefaultViewModel: true
        )
        async let secondLoad = prepared.openSession(
            artboardName: "Artboard",
            player: .stateMachine("State Machine 1"),
            pixelWidth: 1,
            pixelHeight: 1,
            bindDefaultViewModel: true
        )
        let (first, second) = try await (firstLoad, secondLoad)
        defer {
            Task {
                try? await first.close()
                try? await second.close()
            }
        }

        let firstRoot = try await first.rootViewModelReference()
        _ = try await first.mutateViewModel([
            .setNumber(instance: firstRoot, path: "Number", value: 91)
        ])
        let firstNumber = try await first.snapshot().values.first {
            $0.name == "Number"
        }?.value
        let secondNumber = try await second.snapshot().values.first {
            $0.name == "Number"
        }?.value
        XCTAssertEqual(firstNumber, .number(91))
        XCTAssertNotEqual(secondNumber, .number(91))

        try await first.close()
        let secondPlayerKind = try await second.playerInfo().kind
        XCTAssertEqual(secondPlayerKind, .stateMachine)
        let metrics = await prepared.metrics()
        XCTAssertEqual(metrics.fileImportCount, 1)
        XCTAssertEqual(metrics.openedSessionCount, 2)
    }

    func testPreparedFileFailedSessionDoesNotPoisonRePresentation() async throws {
        let prepared = try await NuxieNativePreparedFile.prepare(
            bytes: try fixture(named: "data_binding_test", extension: "riv")
        )
        do {
            _ = try await prepared.openSession(
                artboardName: "missing",
                player: .defaultScene,
                pixelWidth: 1,
                pixelHeight: 1
            )
            XCTFail("Expected the undeclared artboard to fail")
        } catch {}

        let first = try await prepared.openSession(
            artboardName: "Artboard",
            player: .stateMachine("State Machine 1"),
            pixelWidth: 1,
            pixelHeight: 1,
            bindDefaultViewModel: true
        )
        let root = try await first.rootViewModelReference()
        _ = try await first.mutateViewModel([
            .setNumber(instance: root, path: "Number", value: 77),
        ])
        try await first.close()

        let replacement = try await prepared.openSession(
            artboardName: "Artboard",
            player: .stateMachine("State Machine 1"),
            pixelWidth: 1,
            pixelHeight: 1,
            bindDefaultViewModel: true
        )
        defer { Task { try? await replacement.close() } }
        let replacementNumber = try await replacement.snapshot().values.first {
            $0.name == "Number"
        }?.value
        XCTAssertNotEqual(replacementNumber, .number(77))
        let metrics = await prepared.metrics()
        XCTAssertEqual(metrics.fileImportCount, 1)
        XCTAssertEqual(metrics.openedSessionCount, 2)
    }

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

    func testMountedSelectedProductReferenceSwitchesLiveValues() async throws {
        let runtime = try await NuxieNativeRuntime.open(
            bytes: try fixture(named: "data_binding_test", extension: "riv"),
            artboardName: "Artboard",
            player: .stateMachine("State Machine 1"),
            pixelWidth: 64,
            pixelHeight: 64,
            bindDefaultViewModel: true
        )
        defer { Task { try? await runtime.close() } }
        let paywall = try await runtime.rootViewModelReference()
        let monthly = try await runtime.makeViewModel(
            schemaIndex: 1,
            authoredInstanceIndex: nil
        )
        let annual = try await runtime.makeViewModel(
            schemaIndex: 1,
            authoredInstanceIndex: nil
        )
        _ = try await runtime.mutateViewModel([
            .setString(
                instance: monthly,
                path: "String",
                value: Data("$0.00 trial".utf8)
            ),
            .setString(
                instance: annual,
                path: "String",
                value: Data("$1.99 for 3 months".utf8)
            ),
            .setViewModel(instance: paywall, path: "Nested", value: monthly),
        ])
        var snapshot = try await runtime.snapshot()
        var selected = try XCTUnwrap(snapshot.values.first {
            $0.ownerInstanceID == paywall.rawValue && $0.name == "Nested"
        })
        guard case .referencedInstance(let monthlyID) = selected.value else {
            return XCTFail("Expected the mounted paywall to reference monthly")
        }
        XCTAssertEqual(snapshot.values.first {
            $0.ownerInstanceID == monthlyID && $0.name == "String"
        }?.value, .bytes(Data("$0.00 trial".utf8)))

        let switched = try await runtime.mutateViewModel([
            .setViewModel(instance: paywall, path: "Nested", value: annual),
        ])
        XCTAssertEqual(switched.appliedCount, 1)
        snapshot = try await runtime.snapshot()
        selected = try XCTUnwrap(snapshot.values.first {
            $0.ownerInstanceID == paywall.rawValue && $0.name == "Nested"
        })
        guard case .referencedInstance(let annualID) = selected.value else {
            return XCTFail("Expected the mounted paywall to reference annual")
        }
        XCTAssertEqual(snapshot.values.first {
            $0.ownerInstanceID == annualID && $0.name == "String"
        }?.value, .bytes(Data("$1.99 for 3 months".utf8)))
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
        let scene = try descriptorSceneFixture()
        let catalog = try await NuxieNativeRuntime.inspectAssets(bytes: scene)
        XCTAssertEqual(catalog.map(\.kind), [.script])
        let runtime = try await NuxieNativeRuntime.open(
            bytes: scene,
            artboardName: "Paywall",
            player: .defaultSceneWithInputStateMachine(
                "Generated Nuxie Pressable Interaction"
            ),
            pixelWidth: 64,
            pixelHeight: 64,
            importMode: .configured(
                moduleName: "nuxie",
                expectedAssets: catalog,
                externalAssets: [:]
            )
        )
        defer { Task { try? await runtime.close() } }

        let authoredStateMachineCount = try await runtime.artboards().first?.stateMachines.count ?? 0
        XCTAssertGreaterThan(
            authoredStateMachineCount,
            1,
            "the compiler contract keeps visual and interaction machines distinct"
        )
        let primaryPlayerName = try await runtime.playerInfo().name
        XCTAssertNotEqual(
            primaryPlayerName,
            "Generated Nuxie Pressable Interaction",
            "the authored/default scene remains the rendered primary player"
        )

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

    func testCompositePlayerRoutesNamedInputOnlyToAuxiliaryOwner() async throws {
        let inputs: [NuxieNativePlayerInput] = [.trigger(name: "interaction")]

        XCTAssertEqual(
            nuxieNativeInputs(inputs, forPlayerAt: 0, playerCount: 2),
            []
        )
        XCTAssertEqual(
            nuxieNativeInputs(inputs, forPlayerAt: 1, playerCount: 2),
            inputs
        )
        XCTAssertEqual(
            nuxieNativeInputs(inputs, forPlayerAt: 0, playerCount: 1),
            inputs
        )
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

    func testInlineBoundTextRunAcceptsEmptyAndLongProductValues() async throws {
        let scene = try fixture(named: "inline_text_data_binding", extension: "riv")
        let catalog = try await NuxieNativeRuntime.inspectAssets(bytes: scene)
        let font = try XCTUnwrap(catalog.first(where: { $0.kind == .font }))
        let testsDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fontBytes = try Data(contentsOf: testsDirectory.appendingPathComponent(
            "ExperienceRuntimeHostApp/Fixtures/font-converter/assets/sha256/" +
                "b481b059ee94961c7b18585a596935aaa7cc44b68879c096d2cd06922e0431b1.ttf"
        ))
        let runtime = try await NuxieNativeRuntime.open(
            bytes: scene,
            artboardName: "Inline text",
            player: .staticArtboard,
            pixelWidth: 320,
            pixelHeight: 160,
            bindDefaultViewModel: true,
            importMode: .configured(
                moduleName: "nuxie",
                expectedAssets: catalog,
                externalAssets: [font.ordinal: fontBytes]
            )
        )
        defer { Task { try? await runtime.close() } }

        let initialSnapshot = try await runtime.snapshot()
        let selectedProduct = try XCTUnwrap(initialSnapshot.values.first {
            $0.name == "selectedProductId"
        })
        let root = try await runtime.rootViewModelReference()
        XCTAssertEqual(
            selectedProduct.value,
            .bytes(Data())
        )
        let preview = try await runtime.mutateViewModel([
            .setString(
                instance: root,
                path: "paywall/selectedProductId",
                value: Data("before".utf8)
            )
        ])
        XCTAssertEqual(preview.appliedCount, 1)
        let initialRender = try await renderPixels(runtime, width: 320, height: 160)
        XCTAssertEqual(initialRender.outcome.disposition, .presented)

        let empty = try await runtime.mutateViewModel([
            .setString(
                instance: root,
                path: "paywall/selectedProductId",
                value: Data()
            )
        ])
        XCTAssertEqual(empty.appliedCount, 1)
        let emptySnapshot = try await runtime.snapshot()
        XCTAssertEqual(
            emptySnapshot.values.first {
                $0.name == "selectedProductId"
            }?.value,
            .bytes(Data())
        )
        let emptyRender = try await renderPixels(runtime, width: 320, height: 160)
        XCTAssertEqual(emptyRender.outcome.disposition, .presented)
        XCTAssertGreaterThan(emptyRender.outcome.drawCalls, 0)
        XCTAssertNotEqual(emptyRender.pixels, initialRender.pixels)
        let removedRunDifference = changedPixelExtent(
            between: initialRender.pixels,
            and: emptyRender.pixels,
            width: 320
        )
        XCTAssertGreaterThan(
            removedRunDifference.pixelCount,
            0,
            "Removing the bound run must change the rendered line"
        )

        let restored = try await runtime.mutateViewModel([
            .setString(
                instance: root,
                path: "paywall/selectedProductId",
                value: Data("before".utf8)
            )
        ])
        XCTAssertEqual(restored.appliedCount, 1)
        let restoredRender = try await renderPixels(runtime, width: 320, height: 160)
        let restoredDifference = changedPixelExtent(
            between: restoredRender.pixels,
            and: initialRender.pixels,
            width: 320
        )
        XCTAssertLessThan(
            restoredDifference.pixelCount,
            removedRunDifference.pixelCount / 2,
            "Restoring the bound run must at least halve the visual distance to the original line"
        )

        let longLocalizedValue =
            "votre période d’essai gratuite de quatre-vingt-dix jours avec toutes les fonctionnalités"
        let long = try await runtime.mutateViewModel([
            .setString(
                instance: root,
                path: "paywall/selectedProductId",
                value: Data(longLocalizedValue.utf8)
            )
        ])
        XCTAssertEqual(long.appliedCount, 1)
        let longSnapshot = try await runtime.snapshot()
        XCTAssertEqual(
            longSnapshot.values.first {
                $0.name == "selectedProductId"
            }?.value,
            .bytes(Data(longLocalizedValue.utf8))
        )
        let rendered = try await renderPixels(runtime, width: 320, height: 160)
        XCTAssertEqual(rendered.outcome.disposition, .presented)
        XCTAssertGreaterThan(rendered.outcome.drawCalls, 0)
        XCTAssertNotEqual(rendered.pixels, initialRender.pixels)
        XCTAssertNotEqual(rendered.pixels, emptyRender.pixels)
        let longRunDifference = changedPixelExtent(
            between: rendered.pixels,
            and: emptyRender.pixels,
            width: 320
        )
        XCTAssertGreaterThan(
            longRunDifference.pixelCount,
            removedRunDifference.pixelCount,
            "A long localized value must affect more of the rendered line"
        )
        XCTAssertGreaterThan(
            longRunDifference.rowSpan,
            removedRunDifference.rowSpan,
            "A long localized value must wrap onto additional rendered rows"
        )
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

    private func renderPixels(
        _ runtime: NuxieNativeRuntime,
        width: Int,
        height: Int
    ) async throws -> (
        outcome: NuxieNativeRendererOutcome,
        pixels: Data
    ) {
        let device = try await runtime.metalDevice().value
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false
        layer.drawableSize = CGSize(width: width, height: height)
        layer.maximumDrawableCount = 2
        layer.allowsNextDrawableTimeout = true
        guard let drawable = layer.nextDrawable() else {
            throw XCTSkip("This host cannot vend a CAMetalDrawable")
        }
        let texture = drawable.texture

        let completion = expectation(description: "native text frame completion")
        let outcome = try await runtime.render(
            drawable: .available(NuxieNativeDrawable(drawable)),
            clearColor: 0xFF11_2233,
            completion: { completion.fulfill() }
        )
        await fulfillment(of: [completion], timeout: 2)

        guard
            let queue = device.makeCommandQueue(),
            let commandBuffer = queue.makeCommandBuffer(),
            let blit = commandBuffer.makeBlitCommandEncoder()
        else {
            throw XCTSkip("This host cannot read a rendered Metal texture")
        }
        let bytesPerPixel = 4
        let bytesPerRow = (width * bytesPerPixel + 255) & ~255
        guard let buffer = device.makeBuffer(
            length: bytesPerRow * height,
            options: .storageModeShared
        ) else {
            throw XCTSkip("This host cannot allocate a shared Metal buffer")
        }
        blit.copy(
            from: texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: buffer,
            destinationOffset: 0,
            destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: bytesPerRow * height
        )
        blit.endEncoding()
        await withCheckedContinuation { continuation in
            commandBuffer.addCompletedHandler { _ in continuation.resume() }
            commandBuffer.commit()
        }
        guard commandBuffer.status == .completed else {
            throw XCTSkip("This host could not complete the Metal readback")
        }

        let source = buffer.contents().assumingMemoryBound(to: UInt8.self)
        var pixels = Data(capacity: width * height * bytesPerPixel)
        for row in 0..<height {
            pixels.append(source + row * bytesPerRow, count: width * bytesPerPixel)
        }
        return (outcome, pixels)
    }

    private func changedPixelExtent(
        between first: Data,
        and second: Data,
        width: Int
    ) -> (pixelCount: Int, rowSpan: Int) {
        precondition(first.count == second.count)
        let bytesPerPixel = 4
        var pixelCount = 0
        var minimumY = first.count / (width * bytesPerPixel)
        var maximumY = -1
        first.withUnsafeBytes { firstBuffer in
            second.withUnsafeBytes { secondBuffer in
                let firstBytes = firstBuffer.bindMemory(to: UInt8.self)
                let secondBytes = secondBuffer.bindMemory(to: UInt8.self)
                for offset in stride(from: 0, to: firstBytes.count, by: bytesPerPixel) {
                    guard !firstBytes[offset..<(offset + bytesPerPixel)]
                        .elementsEqual(secondBytes[offset..<(offset + bytesPerPixel)]) else {
                        continue
                    }
                    let pixelIndex = offset / bytesPerPixel
                    let y = pixelIndex / width
                    pixelCount += 1
                    minimumY = min(minimumY, y)
                    maximumY = max(maximumY, y)
                }
            }
        }
        let rowSpan = maximumY >= minimumY ? maximumY - minimumY + 1 : 0
        return (pixelCount, rowSpan)
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

    private func descriptorSceneFixture() throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Fixtures/scripted-generic-commands/renders/sha256/8b0d173101d37e5ac152344a6ab40805897fd1c193d7400f119e231f56e36b07.riv"
            )
        return try Data(contentsOf: url)
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
