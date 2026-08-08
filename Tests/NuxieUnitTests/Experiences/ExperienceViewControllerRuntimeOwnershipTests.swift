#if canImport(UIKit)
import UIKit
import XCTest
import NuxieRuntime
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

final class ExperienceViewControllerRuntimeOwnershipTests: XCTestCase {
    @MainActor
    func testImportDiagnosticsAreSurfacedExactlyOnceBeforeReady() async throws {
        let fixture = try await ControllerRuntimeFixture.make()
        defer { fixture.remove() }
        let eventLog = configureControllerRuntimeDependencies()
        let diagnostics = [
            ExperienceRuntimeDiagnostic(
                severity: .warning,
                code: "experience_runtime.test_warning",
                message: "No matching Nuxie validation key"
            ),
            ExperienceRuntimeDiagnostic(
                severity: .debug,
                code: "experience_runtime.test_debug",
                message: "Package import debug detail"
            ),
        ]
        let adapter = FakeExperienceRuntimeAdapter(
            operationResults: [.success(.settledControllerTestResult)],
            importResult: ExperienceRuntimeImportResult(
                authenticatedKeyId: "test-key",
                diagnostics: diagnostics
            ),
            bootstrap: .controllerStateBootstrap
        )
        let factory = ExperienceRuntimeContextFactory(adapter: adapter)
        let controller = makeControllerRuntimeController(
            fixture: fixture,
            eventLog: eventLog
        )
        let delegate = ControllerRuntimeDelegate()
        controller.runtimeDelegate = delegate
        controller.runtimeContextProvider = { acquisition in
            let context = try await factory.makeContext(for: .controllerTestRequest)
            return try authenticatedRuntime(
                acquisition: acquisition,
                authenticatedPackage: fixture.package,
                context: context
            )
        }
        var surfacedDiagnostics: [ExperienceRuntimeDiagnostic] = []
        controller.runtimeDiagnosticHandler = {
            surfacedDiagnostics.append($0)
        }

        _ = controller.view
        let didBecomeReady = await waitForControllerRuntime {
            delegate.readyCount == 1
        }

        XCTAssertTrue(didBecomeReady)
        XCTAssertEqual(surfacedDiagnostics, diagnostics)
        await controller.shutdownRuntime()
    }

    @MainActor
    func testPreReadyNavigationWaitsForLazyMountBeforeApplyingTargetedValue() async throws {
        let fixture = try await ControllerRuntimeFixture.make()
        defer { fixture.remove() }
        let eventLog = configureControllerRuntimeDependencies()
        let gate = ControllerRuntimeContextGate()
        let adapter = FakeExperienceRuntimeAdapter(
            operationResults: [.success(.settledControllerTestResult)],
            bootstrap: .controllerStateBootstrap
        )
        let factory = ExperienceRuntimeContextFactory(adapter: adapter)
        let controller = makeControllerRuntimeController(
            fixture: fixture,
            eventLog: eventLog
        )
        let delegate = ControllerRuntimeDelegate()
        controller.runtimeDelegate = delegate
        controller.runtimeContextProvider = { acquisition in
            await gate.suspend()
            let context = try await factory.makeContext(for: .controllerTestRequest)
            return try authenticatedRuntime(
                acquisition: acquisition,
                authenticatedPackage: fixture.package,
                context: context
            )
        }

        controller.loadViewIfNeeded()
        await gate.waitUntilSuspended()
        controller.navigate(to: "ab_two", transition: ["type": "none"])
        controller.applyViewModelValue(
            path: VmPathRef(viewModelName: "Main", path: "title"),
            value: "queued for second screen",
            screenId: "ab_two"
        )

        XCTAssertEqual(delegate.readyCount, 0)
        XCTAssertTrue(adapter.contextDrivers.isEmpty)
        gate.resume()

        let didFinishQueuedCommands = await waitForControllerRuntime {
            delegate.changedScreenIDs == ["ab_two"]
                && adapter.contextDrivers.first?.sessionDrivers.count == 2
        }
        guard didFinishQueuedCommands else {
            XCTFail("queued navigation and targeted value did not finish")
            await controller.shutdownRuntime()
            return
        }
        let contextDriver = try XCTUnwrap(adapter.contextDrivers.first)
        let entryDriver = contextDriver.sessionDrivers[0]
        let secondScreenDriver = contextDriver.sessionDrivers[1]
        let didApplySecondScreenValue = await waitForControllerRuntime {
            secondScreenDriver.performedOperations.contains { operation in
                guard case .stateBatch = operation else { return false }
                return true
            }
        }
        XCTAssertTrue(didApplySecondScreenValue)

        XCTAssertEqual(delegate.readyCount, 1)
        XCTAssertFalse(entryDriver.performedOperations.contains { operation in
            guard case .stateBatch = operation else { return false }
            return true
        })
        let stateBatch = try XCTUnwrap(secondScreenDriver.performedOperations.compactMap {
            operation -> ExperienceRuntimeStateBatch? in
            guard case .stateBatch(let batch) = operation else { return nil }
            return batch
        }.first)
        XCTAssertTrue(stateBatch.mutations.contains { mutation in
            guard case let .setValue(_, path, value) = mutation else { return false }
            return path == "title" && value == .string("queued for second screen")
        })
        XCTAssertEqual(
            eventLog.trackedEvents.filter {
                $0.name == JourneyEvents.experienceArtifactLoadSucceeded
            }.count,
            1
        )

        await controller.shutdownRuntime()
    }

    @MainActor
    func testSynchronousInstallFailureNeverReportsReadyOrSuccess() async throws {
        let fixture = try await ControllerRuntimeFixture.make()
        defer { fixture.remove() }
        let eventLog = configureControllerRuntimeDependencies()
        let lifecycle = FakeExperienceRuntimeLifecycleRecorder()
        let adapter = FakeExperienceRuntimeAdapter(
            operationResults: [],
            creationResult: ExperienceRuntimeOperationResult(
                renderOutcome: .notRequested,
                isDirty: false,
                isSettled: true
            ),
            lifecycleRecorder: lifecycle
        )
        let factory = ExperienceRuntimeContextFactory(adapter: adapter)
        let controller = makeControllerRuntimeController(
            fixture: fixture,
            eventLog: eventLog
        )
        let delegate = ControllerRuntimeDelegate()
        controller.runtimeDelegate = delegate
        controller.runtimeContextProvider = { acquisition in
            let context = try await factory.makeContext(for: .controllerTestRequest)
            return try authenticatedRuntime(
                acquisition: acquisition,
                authenticatedPackage: fixture.package,
                context: context
            )
        }

        controller.loadViewIfNeeded()

        let didReportFailure = await waitForControllerRuntime {
            eventLog.trackedEvents.contains {
                $0.name == JourneyEvents.experienceArtifactLoadFailed
            }
        }
        XCTAssertTrue(didReportFailure)
        XCTAssertEqual(delegate.readyCount, 0)
        XCTAssertTrue(eventLog.trackedEvents.filter {
            $0.name == JourneyEvents.experienceArtifactLoadSucceeded
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
        let fixture = try await ControllerRuntimeFixture.make()
        defer { fixture.remove() }
        let eventLog = configureControllerRuntimeDependencies()
        let lifecycle = FakeExperienceRuntimeLifecycleRecorder()
        let gate = ControllerRuntimeContextGate()
        let adapter = FakeExperienceRuntimeAdapter(
            operationResults: [],
            lifecycleRecorder: lifecycle
        )
        let factory = ExperienceRuntimeContextFactory(adapter: adapter)
        let controller = makeControllerRuntimeController(
            fixture: fixture,
            eventLog: eventLog
        )
        let delegate = ControllerRuntimeDelegate()
        controller.runtimeDelegate = delegate
        controller.runtimeContextProvider = { acquisition in
            let context = try await factory.makeContext(for: .controllerTestRequest)
            await gate.suspend()
            return try authenticatedRuntime(
                acquisition: acquisition,
                authenticatedPackage: fixture.package,
                context: context
            )
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
        XCTAssertTrue(eventLog.trackedEvents.filter {
            $0.name == JourneyEvents.experienceArtifactLoadSucceeded
        }.isEmpty)
        await Task.yield()
        XCTAssertEqual(delegate.readyCount, 0)
    }

    @MainActor
    func testOverlappingPreparationAndShutdownJoinTheSameRuntimeTeardown() async throws {
        let fixture = try await ControllerRuntimeFixture.make()
        defer { fixture.remove() }
        let eventLog = configureControllerRuntimeDependencies()
        let lifecycle = FakeExperienceRuntimeLifecycleRecorder()
        let gate = ControllerRuntimeContextGate()
        let adapter = FakeExperienceRuntimeAdapter(
            operationResults: [],
            lifecycleRecorder: lifecycle
        )
        let factory = ExperienceRuntimeContextFactory(adapter: adapter)
        let controller = makeControllerRuntimeController(
            fixture: fixture,
            eventLog: eventLog
        )
        let delegate = ControllerRuntimeDelegate()
        controller.runtimeDelegate = delegate
        controller.runtimeContextProvider = { acquisition in
            let context = try await factory.makeContext(for: .controllerTestRequest)
            await gate.suspend()
            return try authenticatedRuntime(
                acquisition: acquisition,
                authenticatedPackage: fixture.package,
                context: context
            )
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
        XCTAssertTrue(eventLog.trackedEvents.filter {
            $0.name == JourneyEvents.experienceArtifactLoadSucceeded
        }.isEmpty)
    }

    @MainActor
    func testLoadingTimeoutInvalidatesDelayedNativeMountBeforeLateContextReturns() async throws {
        let fixture = try await ControllerRuntimeFixture.make()
        defer { fixture.remove() }
        let eventLog = configureControllerRuntimeDependencies()
        let lifecycle = FakeExperienceRuntimeLifecycleRecorder()
        let gate = ControllerRuntimeContextGate()
        let adapter = FakeExperienceRuntimeAdapter(
            operationResults: [],
            lifecycleRecorder: lifecycle
        )
        let factory = ExperienceRuntimeContextFactory(adapter: adapter)
        let controller = makeControllerRuntimeController(
            fixture: fixture,
            eventLog: eventLog,
            loadingTimeoutSeconds: 0.25
        )
        let delegate = ControllerRuntimeDelegate()
        controller.runtimeDelegate = delegate
        controller.runtimeContextProvider = { acquisition in
            let context = try await factory.makeContext(for: .controllerTestRequest)
            await gate.suspend()
            return try authenticatedRuntime(
                acquisition: acquisition,
                authenticatedPackage: fixture.package,
                context: context
            )
        }

        controller.loadViewIfNeeded()
        await gate.waitUntilSuspended()
        let didTimeOut = await waitForControllerRuntime {
            !controller.errorView.isHidden
                && eventLog.trackedEvents.contains {
                    $0.name == JourneyEvents.experienceArtifactLoadFailed
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
        XCTAssertTrue(eventLog.trackedEvents.filter {
            $0.name == JourneyEvents.experienceArtifactLoadSucceeded
        }.isEmpty)

        await controller.shutdownRuntime()
    }

    @MainActor
    func testStaleScreenCallbacksDoNotReachDelegateAfterControllerReuse() async throws {
        let fixture = try await ControllerRuntimeFixture.make()
        defer { fixture.remove() }
        let eventLog = configureControllerRuntimeDependencies()
        let adapter = FakeExperienceRuntimeAdapter(
            operationResults: Array(
                repeating: .success(ExperienceRuntimeOperationResult(
                    renderOutcome: .notRequested,
                    isDirty: false,
                    isSettled: true
                )),
                count: 4
            ),
            creationResult: ExperienceRuntimeOperationResult(
                renderOutcome: .notRequested,
                isDirty: false,
                isSettled: true,
                bootstrap: .fake
            )
        )
        let factory = ExperienceRuntimeContextFactory(adapter: adapter)
        let controller = makeControllerRuntimeController(
            fixture: fixture,
            eventLog: eventLog
        )
        controller.runtimeContextProvider = { acquisition in
            let context = try await factory.makeContext(for: .controllerTestRequest)
            return try authenticatedRuntime(
                acquisition: acquisition,
                authenticatedPackage: fixture.package,
                context: context
            )
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
            firstNavigationController.topViewController as? ExperienceScreenViewController
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
            currentNavigationController.topViewController as? ExperienceScreenViewController
        )
        XCTAssertFalse(staleScreen === currentScreen)

        controller.experienceScreenViewController(
            staleScreen,
            didEmitEvent: ExperienceRendererEvent(
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

private final class ControllerRuntimeDelegate: ExperienceRuntimeDelegate {
    private(set) var readyCount = 0
    private(set) var changedScreenIDs: [String] = []
    private(set) var emittedEventNames: [String] = []

    func experienceViewControllerDidBecomeReady(_ controller: ExperienceViewController) {
        readyCount += 1
    }

    func experienceViewController(
        _ controller: ExperienceViewController,
        didChangeScreen screenId: String
    ) {
        changedScreenIDs.append(screenId)
    }

    func experienceViewController(
        _ controller: ExperienceViewController,
        didEmitEvent event: ExperienceRendererEvent
    ) {
        emittedEventNames.append(event.name)
    }

    func experienceViewControllerDidRequestDismiss(
        _ controller: ExperienceViewController,
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
    let experience: Experience
    let package: LoadedExperiencePackage
    let packageStore: ExperiencePackageStore

    @MainActor
    static func make() async throws -> ControllerRuntimeFixture {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "controller-runtime-\(UUID().uuidString)",
                isDirectory: true
            )
        let package = try await RuntimePackageFixtureSupport.loadedPackage(
            named: "multi-screen",
            bundle: Bundle(for: ExperienceViewControllerRuntimeOwnershipTests.self)
        )
        let fixtureRoot = package.packageURL.deletingLastPathComponent()
        let experience = Experience(
            remote: package.remote,
            journey: package.journey,
            assetBaseURL: fixtureRoot
        )
        return ControllerRuntimeFixture(
            rootURL: rootURL,
            experience: experience,
            package: package,
            packageStore: ExperiencePackageStore(
                cacheDirectory: rootURL.appendingPathComponent("packages"),
                assetCacheDirectory: rootURL.appendingPathComponent("assets"),
                authorizationKeys: try ExperienceTrustRoots.keys(for: .development)
            )
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

@MainActor
private func configureControllerRuntimeDependencies() -> MockEventLog {
    MockEventLog()
}

@MainActor
private func makeControllerRuntimeController(
    fixture: ControllerRuntimeFixture,
    eventLog: MockEventLog,
    loadingTimeoutSeconds: TimeInterval = 15.0
) -> ExperienceViewController {
    let productService = MockProductService()
    return ExperienceViewController(
        experience: fixture.experience,
        packageStore: fixture.packageStore,
        eventLog: eventLog,
        loadingTimeoutSeconds: loadingTimeoutSeconds,
        transactionService: TransactionService(
            productService: productService,
            transactionObserver: MockTransactionObserver(),
            pendingPurchaseStore: InMemoryPendingPurchaseStore(),
            dateProvider: MockDateProvider(),
            configurationProvider: { NuxieConfiguration(apiKey: "controller-runtime-tests") }
        ),
        productService: productService
    )
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

@MainActor
private func authenticatedRuntime(
    acquisition: AcquiredExperiencePackage,
    authenticatedPackage: LoadedExperiencePackage,
    context: ExperienceRuntimeContext
) throws -> AuthenticatedExperienceRuntimeContext {
    guard acquisition.packageBytes == authenticatedPackage.packageBytes else {
        throw ExperiencePackageStoreError.identityMismatch
    }
    return AuthenticatedExperienceRuntimeContext(
        package: authenticatedPackage,
        context: context
    )
}

private extension ExperienceRuntimeImportRequest {
    static let controllerTestRequest = ExperienceRuntimeImportRequest.testStub()
}

private extension ExperienceRuntimeOperationResult {
    static let settledControllerTestResult = ExperienceRuntimeOperationResult(
        renderOutcome: .notRequested,
        isDirty: false,
        isSettled: true
    )
}

private extension ExperienceRuntimeBootstrap {
    static let controllerStateBootstrap: ExperienceRuntimeBootstrap = {
        let rootID = ExperienceRuntimeInstanceID(rawValue: 1)!
        return ExperienceRuntimeBootstrap(
            player: ExperienceRuntimePlayerMetadata(
                kind: .staticArtboard,
                selection: .staticArtboard,
                index: nil,
                artboardName: "Entry",
                playerName: nil,
                bounds: ExperienceRuntimeArtboardBounds(
                    minX: 0,
                    minY: 0,
                    maxX: 390,
                    maxY: 844
                )
            ),
            catalog: ExperienceRuntimeCatalog(
                schemas: [
                    ExperienceRuntimeSchema(
                        id: "Main",
                        name: "Main",
                        properties: [
                            ExperienceRuntimeSchemaProperty(
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
                    ExperienceRuntimeInstance(
                        id: rootID,
                        schemaID: "Main",
                        name: "Default",
                        isRoot: true,
                        valueRootIndex: 0
                    ),
                ]
            ),
            values: ExperienceRuntimeValueArena(
                nodes: [
                    ExperienceRuntimeValueNode(value: .viewModel(
                        schemaID: "Main",
                        instanceID: rootID,
                        fields: [ExperienceRuntimeValueEdge(key: "title", nodeIndex: 1)]
                    )),
                    ExperienceRuntimeValueNode(value: .scalar(.string("initial"))),
                ],
                roots: [ExperienceRuntimeValueRoot(instanceID: rootID, nodeIndex: 0)]
            )
        )
    }()
}
#endif
