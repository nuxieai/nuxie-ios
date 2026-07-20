#if canImport(UIKit)
import FactoryKit
import UIKit
import XCTest
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

final class FlowViewControllerRuntimeOwnershipTests: XCTestCase {
    @MainActor
    func testImportDiagnosticsAreSurfacedExactlyOnceBeforeReady() async throws {
        let fixture = try ControllerRuntimeFixture.make()
        defer { fixture.remove() }
        _ = configureControllerRuntimeDependencies()
        let diagnostics = [
            FlowRuntimeDiagnostic(
                severity: .warning,
                code: "flow_runtime.script_authorization_unknown_key",
                message: "No matching Nuxie validation key"
            ),
            FlowRuntimeDiagnostic(
                severity: .debug,
                code: "flow_runtime.script_authorization_visual_only",
                message: "Imported without script authorization"
            ),
        ]
        let adapter = FakeFlowRuntimeAdapter(
            operationResults: [.success(.settledControllerTestResult)],
            importResult: FlowRuntimeImportResult(
                scriptAuthorization: .visualOnly,
                diagnostics: diagnostics
            ),
            bootstrap: .controllerStateBootstrap
        )
        let factory = FlowRuntimeContextFactory(adapter: adapter)
        let controller = FlowViewController(
            flow: fixture.flow,
            artifactStore: fixture.artifactStore
        )
        let delegate = ControllerRuntimeDelegate()
        controller.runtimeDelegate = delegate
        controller.runtimeContextProvider = { _ in
            try await factory.makeContext(for: .controllerTestRequest)
        }
        var surfacedDiagnostics: [FlowRuntimeDiagnostic] = []
        controller.runtimeDiagnosticHandler = {
            surfacedDiagnostics.append($0)
        }

        controller.preloadView()
        let didBecomeReady = await waitForControllerRuntime {
            delegate.readyCount == 1
        }

        XCTAssertTrue(didBecomeReady)
        XCTAssertEqual(surfacedDiagnostics, diagnostics)
        await controller.shutdownRuntime()
    }

    @MainActor
    func testPreReadyNavigationWaitsForLazyMountBeforeApplyingTargetedValue() async throws {
        let fixture = try ControllerRuntimeFixture.make()
        defer { fixture.remove() }
        let eventService = configureControllerRuntimeDependencies()
        let gate = ControllerRuntimeContextGate()
        let adapter = FakeFlowRuntimeAdapter(
            operationResults: [.success(.settledControllerTestResult)],
            bootstrap: .controllerStateBootstrap
        )
        let factory = FlowRuntimeContextFactory(adapter: adapter)
        let controller = FlowViewController(
            flow: fixture.flow,
            artifactStore: fixture.artifactStore
        )
        let delegate = ControllerRuntimeDelegate()
        controller.runtimeDelegate = delegate
        controller.runtimeContextProvider = { _ in
            await gate.suspend()
            return try await factory.makeContext(for: .controllerTestRequest)
        }

        controller.loadViewIfNeeded()
        await gate.waitUntilSuspended()
        controller.navigate(to: "details", transition: ["type": "none"])
        controller.applyViewModelValue(
            path: VmPathRef(viewModelName: "Main", path: "title"),
            value: "queued for details",
            screenId: "details"
        )

        XCTAssertEqual(delegate.readyCount, 0)
        XCTAssertTrue(adapter.contextDrivers.isEmpty)
        gate.resume()

        let didFinishQueuedCommands = await waitForControllerRuntime {
            delegate.changedScreenIDs == ["details"]
                && adapter.contextDrivers.first?.sessionDrivers.count == 2
        }
        XCTAssertTrue(didFinishQueuedCommands)
        let contextDriver = try XCTUnwrap(adapter.contextDrivers.first)
        let entryDriver = contextDriver.sessionDrivers[0]
        let detailsDriver = contextDriver.sessionDrivers[1]
        let didApplyDetailsValue = await waitForControllerRuntime {
            detailsDriver.performedOperations.contains { operation in
                guard case .stateBatch = operation else { return false }
                return true
            }
        }
        XCTAssertTrue(didApplyDetailsValue)

        XCTAssertEqual(delegate.readyCount, 1)
        XCTAssertFalse(entryDriver.performedOperations.contains { operation in
            guard case .stateBatch = operation else { return false }
            return true
        })
        let stateBatch = try XCTUnwrap(detailsDriver.performedOperations.compactMap {
            operation -> FlowRuntimeStateBatch? in
            guard case .stateBatch(let batch) = operation else { return nil }
            return batch
        }.first)
        XCTAssertTrue(stateBatch.mutations.contains { mutation in
            guard case let .setValue(_, path, value) = mutation else { return false }
            return path == "title" && value == .string("queued for details")
        })
        XCTAssertEqual(
            eventService.trackedEvents.filter {
                $0.name == JourneyEvents.flowArtifactLoadSucceeded
            }.count,
            1
        )

        await controller.shutdownRuntime()
    }

    @MainActor
    func testSynchronousInstallFailureNeverReportsReadyOrSuccess() async throws {
        let fixture = try ControllerRuntimeFixture.make()
        defer { fixture.remove() }
        let eventService = configureControllerRuntimeDependencies()
        let lifecycle = FakeFlowRuntimeLifecycleRecorder()
        let adapter = FakeFlowRuntimeAdapter(
            operationResults: [],
            creationResult: FlowRuntimeOperationResult(
                renderOutcome: .notRequested,
                isDirty: false,
                isSettled: true
            ),
            lifecycleRecorder: lifecycle
        )
        let factory = FlowRuntimeContextFactory(adapter: adapter)
        let controller = FlowViewController(
            flow: fixture.flow,
            artifactStore: fixture.artifactStore
        )
        let delegate = ControllerRuntimeDelegate()
        controller.runtimeDelegate = delegate
        controller.runtimeContextProvider = { _ in
            try await factory.makeContext(for: .controllerTestRequest)
        }

        controller.loadViewIfNeeded()

        let didReportFailure = await waitForControllerRuntime {
            eventService.trackedEvents.contains {
                $0.name == JourneyEvents.flowArtifactLoadFailed
            }
        }
        XCTAssertTrue(didReportFailure)
        XCTAssertEqual(delegate.readyCount, 0)
        XCTAssertTrue(eventService.trackedEvents.filter {
            $0.name == JourneyEvents.flowArtifactLoadSucceeded
        }.isEmpty)
        XCTAssertFalse(controller.errorView.isHidden)
        let didDisposeFailedInstall = await waitForControllerRuntime {
            lifecycle.events.contains(.sessionDisposed)
                && lifecycle.events.contains(.contextDisposed)
        }
        XCTAssertTrue(didDisposeFailedInstall)

        await controller.shutdownRuntime()
    }

    @MainActor
    func testShutdownDuringDelayedContextImportPreventsLateReadyAndDisposesContext() async throws {
        let fixture = try ControllerRuntimeFixture.make()
        defer { fixture.remove() }
        let eventService = configureControllerRuntimeDependencies()
        let lifecycle = FakeFlowRuntimeLifecycleRecorder()
        let gate = ControllerRuntimeContextGate()
        let adapter = FakeFlowRuntimeAdapter(
            operationResults: [],
            lifecycleRecorder: lifecycle
        )
        let factory = FlowRuntimeContextFactory(adapter: adapter)
        let controller = FlowViewController(
            flow: fixture.flow,
            artifactStore: fixture.artifactStore
        )
        let delegate = ControllerRuntimeDelegate()
        controller.runtimeDelegate = delegate
        controller.runtimeContextProvider = { _ in
            let context = try await factory.makeContext(for: .controllerTestRequest)
            await gate.suspend()
            return context
        }

        controller.loadViewIfNeeded()
        await gate.waitUntilSuspended()
        XCTAssertEqual(adapter.contextDrivers.count, 1)

        let shutdown = Task { @MainActor in
            await controller.shutdownRuntime()
        }
        await Task.yield()
        XCTAssertEqual(delegate.readyCount, 0)
        gate.resume()
        await shutdown.value

        let didDisposeCancelledContext = await waitForControllerRuntime {
            lifecycle.events.contains(.contextDisposed)
        }
        XCTAssertTrue(didDisposeCancelledContext)
        XCTAssertFalse(lifecycle.events.contains(.sessionDisposed))
        XCTAssertEqual(delegate.readyCount, 0)
        XCTAssertTrue(eventService.trackedEvents.filter {
            $0.name == JourneyEvents.flowArtifactLoadSucceeded
        }.isEmpty)
        await Task.yield()
        XCTAssertEqual(delegate.readyCount, 0)
    }

    @MainActor
    func testOverlappingPreparationAndShutdownJoinTheSameRuntimeTeardown() async throws {
        let fixture = try ControllerRuntimeFixture.make()
        defer { fixture.remove() }
        let eventService = configureControllerRuntimeDependencies()
        let lifecycle = FakeFlowRuntimeLifecycleRecorder()
        let gate = ControllerRuntimeContextGate()
        let adapter = FakeFlowRuntimeAdapter(
            operationResults: [],
            lifecycleRecorder: lifecycle
        )
        let factory = FlowRuntimeContextFactory(adapter: adapter)
        let controller = FlowViewController(
            flow: fixture.flow,
            artifactStore: fixture.artifactStore
        )
        let delegate = ControllerRuntimeDelegate()
        controller.runtimeDelegate = delegate
        controller.runtimeContextProvider = { _ in
            let context = try await factory.makeContext(for: .controllerTestRequest)
            await gate.suspend()
            return context
        }

        controller.loadViewIfNeeded()
        await gate.waitUntilSuspended()
        XCTAssertEqual(adapter.contextDrivers.count, 1)

        var didFinishPreparation = false
        var didFinishShutdown = false
        let preparation = Task { @MainActor in
            await controller.prepareForPresentation()
            didFinishPreparation = true
        }
        await Task.yield()
        let shutdown = Task { @MainActor in
            await controller.shutdownRuntime()
            didFinishShutdown = true
        }
        for _ in 0..<10 { await Task.yield() }

        XCTAssertFalse(didFinishPreparation)
        XCTAssertFalse(didFinishShutdown)
        XCTAssertFalse(lifecycle.events.contains(.contextDisposed))

        gate.resume()
        await preparation.value
        await shutdown.value

        XCTAssertTrue(didFinishPreparation)
        XCTAssertTrue(didFinishShutdown)
        XCTAssertEqual(delegate.readyCount, 0)
        XCTAssertEqual(adapter.contextDrivers.count, 1)
        XCTAssertTrue(lifecycle.events.contains(.contextDisposed))
        XCTAssertTrue(eventService.trackedEvents.filter {
            $0.name == JourneyEvents.flowArtifactLoadSucceeded
        }.isEmpty)
    }

    @MainActor
    func testLoadingTimeoutInvalidatesDelayedNativeMountBeforeLateContextReturns() async throws {
        let fixture = try ControllerRuntimeFixture.make()
        defer { fixture.remove() }
        let eventService = configureControllerRuntimeDependencies()
        let lifecycle = FakeFlowRuntimeLifecycleRecorder()
        let gate = ControllerRuntimeContextGate()
        let adapter = FakeFlowRuntimeAdapter(
            operationResults: [],
            lifecycleRecorder: lifecycle
        )
        let factory = FlowRuntimeContextFactory(adapter: adapter)
        let controller = FlowViewController(
            flow: fixture.flow,
            artifactStore: fixture.artifactStore,
            loadingTimeoutSeconds: 0.25
        )
        let delegate = ControllerRuntimeDelegate()
        controller.runtimeDelegate = delegate
        controller.runtimeContextProvider = { _ in
            let context = try await factory.makeContext(for: .controllerTestRequest)
            await gate.suspend()
            return context
        }

        controller.loadViewIfNeeded()
        await gate.waitUntilSuspended()
        let didTimeOut = await waitForControllerRuntime {
            !controller.errorView.isHidden
                && eventService.trackedEvents.contains {
                    $0.name == JourneyEvents.flowArtifactLoadFailed
                }
        }
        XCTAssertTrue(didTimeOut)
        XCTAssertEqual(delegate.readyCount, 0)

        gate.resume()
        let didDisposeTimedOutContext = await waitForControllerRuntime {
            lifecycle.events.contains(.contextDisposed)
        }
        XCTAssertTrue(didDisposeTimedOutContext)
        XCTAssertEqual(delegate.readyCount, 0)
        XCTAssertEqual(adapter.contextDrivers.count, 1)
        XCTAssertFalse(controller.errorView.isHidden)
        XCTAssertTrue(eventService.trackedEvents.filter {
            $0.name == JourneyEvents.flowArtifactLoadSucceeded
        }.isEmpty)

        await controller.shutdownRuntime()
    }

    @MainActor
    func testStaleScreenCallbacksDoNotReachDelegateAfterControllerReuse() async throws {
        let fixture = try ControllerRuntimeFixture.make()
        defer { fixture.remove() }
        _ = configureControllerRuntimeDependencies()
        let adapter = FakeFlowRuntimeAdapter(
            operationResults: Array(
                repeating: .success(FlowRuntimeOperationResult(
                    renderOutcome: .notRequested,
                    isDirty: false,
                    isSettled: true
                )),
                count: 4
            ),
            creationResult: FlowRuntimeOperationResult(
                renderOutcome: .notRequested,
                isDirty: false,
                isSettled: true,
                bootstrap: .fake
            )
        )
        let factory = FlowRuntimeContextFactory(adapter: adapter)
        let controller = FlowViewController(
            flow: fixture.flow,
            artifactStore: fixture.artifactStore
        )
        controller.runtimeContextProvider = { _ in
            try await factory.makeContext(for: .controllerTestRequest)
        }
        let firstDelegate = ControllerRuntimeDelegate()
        controller.runtimeDelegate = firstDelegate

        controller.loadViewIfNeeded()
        let didBecomeReady = await waitForControllerRuntime {
            firstDelegate.readyCount == 1
        }
        XCTAssertTrue(didBecomeReady)
        let firstNavigationController = try XCTUnwrap(
            controller.children.compactMap { $0 as? UINavigationController }.first
        )
        let staleScreen = try XCTUnwrap(
            firstNavigationController.topViewController as? FlowScreenViewController
        )

        let secondDelegate = ControllerRuntimeDelegate()
        controller.runtimeDelegate = secondDelegate
        await controller.prepareForPresentation()
        let didReload = await waitForControllerRuntime {
            secondDelegate.readyCount == 1 && adapter.contextDrivers.count == 2
        }
        XCTAssertTrue(didReload)
        let currentNavigationController = try XCTUnwrap(
            controller.children.compactMap { $0 as? UINavigationController }.first
        )
        let currentScreen = try XCTUnwrap(
            currentNavigationController.topViewController as? FlowScreenViewController
        )
        XCTAssertFalse(staleScreen === currentScreen)

        controller.flowScreenViewController(
            staleScreen,
            didEmitEvent: FlowRendererEvent(
                name: "stale",
                properties: [:],
                screenId: "entry",
                componentId: nil,
                instanceId: nil
            )
        )
        XCTAssertTrue(secondDelegate.emittedEventNames.isEmpty)

        await controller.shutdownRuntime()
    }
}

private final class ControllerRuntimeDelegate: FlowRuntimeDelegate {
    private(set) var readyCount = 0
    private(set) var changedScreenIDs: [String] = []
    private(set) var emittedEventNames: [String] = []

    func flowViewControllerDidBecomeReady(_ controller: FlowViewController) {
        readyCount += 1
    }

    func flowViewController(
        _ controller: FlowViewController,
        didChangeScreen screenId: String
    ) {
        changedScreenIDs.append(screenId)
    }

    func flowViewController(
        _ controller: FlowViewController,
        didEmitEvent event: FlowRendererEvent
    ) {
        emittedEventNames.append(event.name)
    }

    func flowViewControllerDidRequestDismiss(
        _ controller: FlowViewController,
        reason: CloseReason
    ) {}
}

@MainActor
private final class ControllerRuntimeContextGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var suspendedWaiters: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let waiters = suspendedWaiters
            suspendedWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func waitUntilSuspended() async {
        guard continuation == nil else { return }
        await withCheckedContinuation { continuation in
            suspendedWaiters.append(continuation)
        }
    }

    func resume() {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume()
    }
}

private struct ControllerRuntimeFixture {
    let rootURL: URL
    let flow: Flow
    let artifactStore: FlowArtifactStore

    @MainActor
    static func make() throws -> ControllerRuntimeFixture {
        let id = "controller-runtime-\(UUID().uuidString)"
        let buildID = "build-controller"
        let contentHash = "controller-content"
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(id, isDirectory: true)
        let cacheURL = rootURL.appendingPathComponent("cache", isDirectory: true)
        let artifactURL = cacheURL.appendingPathComponent(
            "\(id)_\(buildID)_\(contentHash)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: artifactURL,
            withIntermediateDirectories: true
        )

        let rivBytes = Data("controller-runtime-riv".utf8)
        let rivHash = FlowArtifactStore.sha256Hex(rivBytes)
        let manifestBytes = Data("""
        {
          "version": 1,
          "flowId": "\(id)",
          "buildId": "\(buildID)",
          "renderer": "nuxie-runtime",
          "riv": {
            "path": "flow.riv",
            "sha256": "\(rivHash)",
            "sizeBytes": \(rivBytes.count)
          },
          "entry": {
            "screenId": "entry",
            "artboardId": "entry",
            "artboardName": "Entry",
            "width": 390,
            "height": 844
          },
          "screens": [
            {
              "screenId": "entry",
              "artboardId": "entry",
              "artboardName": "Entry",
              "width": 390,
              "height": 844
            },
            {
              "screenId": "details",
              "artboardId": "details",
              "artboardName": "Details",
              "width": 390,
              "height": 844
            }
          ],
          "assets": { "images": [], "fonts": [] },
          "textInputs": []
        }
        """.utf8)
        try rivBytes.write(to: artifactURL.appendingPathComponent("flow.riv"))
        try manifestBytes.write(
            to: artifactURL.appendingPathComponent(FlowArtifactStore.manifestPath)
        )

        let buildFiles = [
            BuildFile(
                path: FlowArtifactStore.manifestPath,
                size: manifestBytes.count,
                contentType: "application/json"
            ),
            BuildFile(
                path: "flow.riv",
                size: rivBytes.count,
                contentType: "application/octet-stream"
            ),
        ]
        let flow = Flow(
            remoteFlow: RemoteFlow(
                id: id,
                flowArtifact: FlowArtifact(
                    url: "https://example.com/\(id)",
                    buildId: buildID,
                    manifest: BuildManifest(
                        totalFiles: buildFiles.count,
                        totalSize: buildFiles.reduce(0) { $0 + $1.size },
                        contentHash: contentHash,
                        files: buildFiles
                    )
                ),
                screens: [
                    RemoteFlowScreen(
                        id: "entry",
                        defaultViewModelName: "Main",
                        defaultInstanceId: "Default"
                    ),
                    RemoteFlowScreen(
                        id: "details",
                        defaultViewModelName: "Main",
                        defaultInstanceId: "Default"
                    ),
                ],
                viewModelValues: nil
            ),
            products: []
        )
        return ControllerRuntimeFixture(
            rootURL: rootURL,
            flow: flow,
            artifactStore: FlowArtifactStore(cacheDirectory: cacheURL)
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

@MainActor
private func configureControllerRuntimeDependencies() -> MockEventService {
    Container.shared.sdkConfiguration.register {
        NuxieConfiguration(apiKey: "controller-runtime-tests")
    }
    let eventService = MockEventService()
    Container.shared.eventService.register { eventService }
    return eventService
}

@MainActor
private func waitForControllerRuntime(
    attempts: Int = 200,
    _ predicate: () -> Bool
) async -> Bool {
    for _ in 0..<attempts {
        if predicate() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return predicate()
}

private extension FlowRuntimeImportRequest {
    static let controllerTestRequest = FlowRuntimeImportRequest(
        artifactBytes: Data([0x52, 0x49, 0x56])
    )
}

private extension FlowRuntimeOperationResult {
    static let settledControllerTestResult = FlowRuntimeOperationResult(
        renderOutcome: .notRequested,
        isDirty: false,
        isSettled: true
    )
}

private extension FlowRuntimeBootstrap {
    static let controllerStateBootstrap: FlowRuntimeBootstrap = {
        let rootID = FlowRuntimeInstanceID(rawValue: 1)!
        return FlowRuntimeBootstrap(
            player: FlowRuntimePlayerMetadata(
                kind: .staticArtboard,
                selection: .staticArtboard,
                index: nil,
                artboardName: "Entry",
                playerName: nil,
                bounds: FlowRuntimeArtboardBounds(
                    minX: 0,
                    minY: 0,
                    maxX: 390,
                    maxY: 844
                )
            ),
            catalog: FlowRuntimeCatalog(
                schemas: [
                    FlowRuntimeSchema(
                        id: "Main",
                        name: "Main",
                        properties: [
                            FlowRuntimeSchemaProperty(
                                schemaID: "Main",
                                propertyID: "title",
                                name: "title",
                                kind: .string
                            ),
                        ]
                    ),
                ],
                templates: [],
                instances: [
                    FlowRuntimeInstance(
                        id: rootID,
                        schemaID: "Main",
                        name: "Default",
                        isRoot: true,
                        valueRootIndex: 0
                    ),
                ]
            ),
            values: FlowRuntimeValueArena(
                nodes: [
                    FlowRuntimeValueNode(value: .viewModel(
                        schemaID: "Main",
                        instanceID: rootID,
                        fields: [FlowRuntimeValueEdge(key: "title", nodeIndex: 1)]
                    )),
                    FlowRuntimeValueNode(value: .scalar(.string("initial"))),
                ],
                roots: [FlowRuntimeValueRoot(instanceID: rootID, nodeIndex: 0)]
            )
        )
    }()
}
#endif
