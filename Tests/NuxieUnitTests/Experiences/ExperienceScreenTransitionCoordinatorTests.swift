#if canImport(UIKit)
import XCTest
import UIKit
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

final class ExperienceScreenTransitionCoordinatorTests: XCTestCase {
    @MainActor
    func testSharesOneContextAndCachesOneIndependentSessionPerScreen() async throws {
        let harness = try await CoordinatorHarness.make()

        try await harness.coordinator.install()

        let navigated = expectation(description: "navigated to details")
        XCTAssertTrue(harness.coordinator.navigate(
            to: "details",
            transition: ["type": "none"]
        ) { didNavigate, screenID in
            XCTAssertTrue(didNavigate)
            XCTAssertEqual(screenID, "details")
            navigated.fulfill()
        })
        await fulfillment(of: [navigated], timeout: 1)

        let returned = expectation(description: "returned to entry")
        XCTAssertTrue(harness.coordinator.navigate(
            to: "entry",
            transition: ["type": "none"]
        ) { didNavigate, screenID in
            XCTAssertTrue(didNavigate)
            XCTAssertEqual(screenID, "entry")
            returned.fulfill()
        })
        await fulfillment(of: [returned], timeout: 1)

        let contextDrivers = harness.adapter.contextDrivers
        XCTAssertEqual(contextDrivers.count, 1)
        XCTAssertEqual(
            contextDrivers[0].sessionDescriptors.map(\.artboardName),
            ["Entry", "Details"]
        )
        XCTAssertEqual(contextDrivers[0].sessionDrivers.count, 2)
        await harness.coordinator.tearDown()
    }

    @MainActor
    func testWaitsForMountAndSerializesNavigationInAdmissionOrder() async throws {
        let gate = FakeExperienceRuntimeSurfaceAttachmentGate()
        let harness = try await CoordinatorHarness.make(
            surfaceAttachmentGate: gate
        )

        let installTask = Task { @MainActor in
            try await harness.coordinator.install()
        }
        await gate.waitUntilAttachmentIsSuspended()
        XCTAssertNil(harness.coordinator.activeScreenId)
        gate.resumeAttachment()
        try await installTask.value

        var completions: [String] = []
        let detailsCompletion = expectation(description: "details completed")
        let checkoutCompletion = expectation(description: "checkout completed")
        XCTAssertTrue(harness.coordinator.navigate(
            to: "details",
            transition: ["type": "none"]
        ) { didNavigate, screenID in
            XCTAssertTrue(didNavigate)
            completions.append(screenID)
            detailsCompletion.fulfill()
        })
        await gate.waitUntilAttachmentIsSuspended()
        XCTAssertEqual(harness.coordinator.activeScreenId, "entry")

        XCTAssertTrue(harness.coordinator.navigate(
            to: "checkout",
            transition: ["type": "none"]
        ) { didNavigate, screenID in
            XCTAssertTrue(didNavigate)
            completions.append(screenID)
            checkoutCompletion.fulfill()
        })
        await Task.yield()
        XCTAssertEqual(
            harness.adapter.contextDrivers[0].sessionDescriptors.map(\.artboardName),
            ["Entry", "Details"]
        )
        XCTAssertTrue(completions.isEmpty)

        gate.resumeAttachment()
        await gate.waitUntilAttachmentIsSuspended()
        XCTAssertEqual(completions, ["details"])
        XCTAssertEqual(harness.coordinator.activeScreenId, "details")

        gate.resumeAttachment()
        await fulfillment(
            of: [detailsCompletion, checkoutCompletion],
            timeout: 1
        )
        XCTAssertEqual(completions, ["details", "checkout"])
        XCTAssertEqual(harness.coordinator.activeScreenId, "checkout")
        await harness.coordinator.tearDown()
    }

    @MainActor
    func testKeepsBothScreenSessionsLiveThroughAnimatedReplacement() async throws {
        let harness = try await CoordinatorHarness.make()
        try await harness.coordinator.install()

        let navigated = expectation(description: "fade completed")
        XCTAssertTrue(harness.coordinator.navigate(
            to: "details",
            transition: ["type": "fade"]
        ) { didNavigate, screenID in
            XCTAssertTrue(didNavigate)
            XCTAssertEqual(screenID, "details")
            navigated.fulfill()
        })

        let mountedBothScreens = await waitUntil {
            harness.adapter.contextDrivers[0].sessionDrivers.count == 2
        }
        XCTAssertTrue(mountedBothScreens)
        XCTAssertEqual(
            harness.adapter.lifecycleRecorder.events.surfaceAttachmentCount,
            2
        )
        XCTAssertEqual(
            harness.adapter.lifecycleRecorder.events.sessionDisposalCount,
            0
        )

        await fulfillment(of: [navigated], timeout: 2)
        let returned = expectation(description: "return fade completed")
        XCTAssertTrue(harness.coordinator.navigate(
            to: "entry",
            transition: ["type": "fade"]
        ) { didNavigate, screenID in
            XCTAssertTrue(didNavigate)
            XCTAssertEqual(screenID, "entry")
            returned.fulfill()
        })
        await fulfillment(of: [returned], timeout: 2)

        XCTAssertEqual(
            harness.adapter.contextDrivers[0].sessionDescriptors.map(\.artboardName),
            ["Entry", "Details"]
        )
        XCTAssertEqual(
            harness.adapter.lifecycleRecorder.events.sessionDisposalCount,
            0
        )
        await harness.coordinator.tearDown()
    }

    @MainActor
    func testTearDownCancelsInstallAndAwaitsInflightScreenShutdown() async throws {
        let gate = FakeExperienceRuntimeSurfaceAttachmentGate()
        let harness = try await CoordinatorHarness.make(
            surfaceAttachmentGate: gate
        )

        let installTask = Task { @MainActor in
            try await harness.coordinator.install()
        }
        await gate.waitUntilAttachmentIsSuspended()
        let teardownTask = Task { @MainActor in
            await harness.coordinator.tearDown()
        }
        await Task.yield()
        XCTAssertEqual(
            harness.adapter.lifecycleRecorder.events.sessionDisposalCount,
            0
        )

        gate.resumeAttachment()
        await teardownTask.value
        switch await installTask.result {
        case .failure(let error):
            XCTAssertTrue(error is CancellationError)
        case .success:
            XCTFail("cancelled installation unexpectedly succeeded")
        }
        XCTAssertNil(harness.coordinator.activeScreenId)
        XCTAssertEqual(
            harness.adapter.lifecycleRecorder.events.sessionDisposalCount,
            1
        )
    }

    @MainActor
    func testReportsTerminalFailureOnceWithoutPoisoningSiblingScreen() async throws {
        var failedScreenIDs: [String] = []
        let failureReported = expectation(description: "screen failure reported")
        let harness = try await CoordinatorHarness.make(
            // Every newly activated screen receives one explicit zero-time
            // advance. Let that activation settle, then fail the targeted
            // details mutation under test.
            operationResults: [
                .success(coordinatorSettledOperationResult),
                .failure(CoordinatorTerminalTestError.failed),
            ],
            bootstrap: CoordinatorHarness.stateBootstrap,
            onRuntimeFailure: { screenID, _ in
                failedScreenIDs.append(screenID)
                failureReported.fulfill()
            }
        )
        try await harness.coordinator.install()

        let detailsMounted = expectation(description: "details mounted")
        XCTAssertTrue(harness.coordinator.navigate(
            to: "details",
            transition: ["type": "none"]
        ) { didNavigate, _ in
            XCTAssertTrue(didNavigate)
            detailsMounted.fulfill()
        })
        await fulfillment(of: [detailsMounted], timeout: 1)

        XCTAssertTrue(harness.coordinator.applyValue(
            path: VmPathRef(viewModelName: "Main", path: "title"),
            value: "fails only this replica",
            screenId: "details",
            instanceId: "details-root"
        ))
        await fulfillment(of: [failureReported], timeout: 1)
        XCTAssertEqual(failedScreenIDs, ["details"])
        XCTAssertFalse(harness.coordinator.applyValue(
            path: VmPathRef(viewModelName: "Main", path: "title"),
            value: "ignored after terminal failure",
            screenId: "details",
            instanceId: "details-root"
        ))

        let checkoutMounted = expectation(description: "healthy sibling mounted")
        XCTAssertTrue(harness.coordinator.navigate(
            to: "checkout",
            transition: ["type": "none"]
        ) { didNavigate, screenID in
            XCTAssertTrue(didNavigate)
            XCTAssertEqual(screenID, "checkout")
            checkoutMounted.fulfill()
        })
        await fulfillment(of: [checkoutMounted], timeout: 1)
        XCTAssertEqual(harness.coordinator.activeScreenId, "checkout")
        XCTAssertEqual(failedScreenIDs, ["details"])
        XCTAssertEqual(
            harness.adapter.contextDrivers[0].sessionDrivers.count,
            3
        )
        await harness.coordinator.tearDown()
    }
}

private enum CoordinatorTerminalTestError: Error {
    case failed
}

private let coordinatorSettledOperationResult = ExperienceRuntimeOperationResult(
    renderOutcome: .notRequested,
    isDirty: false,
    isSettled: true
)

@MainActor
private func waitUntil(
    attempts: Int = 100,
    _ predicate: () -> Bool
) async -> Bool {
    for _ in 0..<attempts {
        if predicate() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return predicate()
}

private extension Array where Element == FakeExperienceRuntimeLifecycleEvent {
    var surfaceAttachmentCount: Int {
        reduce(into: 0) { count, event in
            if case .surfaceAttached = event { count += 1 }
        }
    }

    var sessionDisposalCount: Int {
        reduce(into: 0) { count, event in
            if event == .sessionDisposed { count += 1 }
        }
    }
}

@MainActor
private final class CoordinatorHarness {
    let adapter: FakeExperienceRuntimeAdapter
    let coordinator: ExperienceScreenTransitionCoordinator
    let host: UIViewController
    let delegate: CoordinatorScreenDelegate

    private init(
        adapter: FakeExperienceRuntimeAdapter,
        coordinator: ExperienceScreenTransitionCoordinator,
        host: UIViewController,
        delegate: CoordinatorScreenDelegate
    ) {
        self.adapter = adapter
        self.coordinator = coordinator
        self.host = host
        self.delegate = delegate
    }

    static func make(
        operationResults: [Result<ExperienceRuntimeOperationResult, Error>] = Array(
            repeating: .success(coordinatorSettledOperationResult),
            count: 16
        ),
        bootstrap: ExperienceRuntimeBootstrap = .fake,
        surfaceAttachmentGate: FakeExperienceRuntimeSurfaceAttachmentGate? = nil,
        onRuntimeFailure: @escaping (String, Error) -> Void = { _, _ in }
    ) async throws -> CoordinatorHarness {
        let artifact = try makeArtifact()
        let adapter = FakeExperienceRuntimeAdapter(
            operationResults: operationResults,
            bootstrap: bootstrap,
            // Coordinator tests drive navigation and targeted mutations
            // explicitly. Keep the fake session asleep so the real offscreen
            // scheduler does not consume an unrelated scripted result before
            // the assertion under test.
            creationResult: ExperienceRuntimeOperationResult(
                renderOutcome: .notRequested,
                isDirty: false,
                isSettled: true,
                bootstrap: bootstrap
            ),
            surfaceAttachmentGate: surfaceAttachmentGate
        )
        let context = try await ExperienceRuntimeContextFactory(adapter: adapter).makeContext(
            for: ExperienceRuntimeImportRequest.testStub(packageBytes: Data([0x52, 0x49, 0x56]))
        )
        let host = UIViewController()
        host.view = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let delegate = CoordinatorScreenDelegate()
        let coordinator = ExperienceScreenTransitionCoordinator(
            experience: artifact.testExperience,
            artifact: artifact,
            runtimeContext: context,
            hostViewController: host,
            screenDelegate: delegate,
            onPresentedScreenDismissed: { _, _ in },
            onRuntimeFailure: onRuntimeFailure
        )
        return CoordinatorHarness(
            adapter: adapter,
            coordinator: coordinator,
            host: host,
            delegate: delegate
        )
    }

    private static func makeArtifact() throws -> LoadedExperiencePackage {
        let journey = JourneyDocument(
            screens: [
                JourneyScreen(
                    id: "entry",
                    defaultViewModelName: "Main",
                    defaultInstanceId: "entry-root"
                ),
                JourneyScreen(
                    id: "details",
                    defaultViewModelName: "Main",
                    defaultInstanceId: "details-root"
                ),
                JourneyScreen(
                    id: "checkout",
                    defaultViewModelName: "Main",
                    defaultInstanceId: "checkout-root"
                ),
            ],
            viewModelValues: nil
        )
        let packageScreens = [
            NuxPackageScreen(
                screenId: "entry",
                artboardId: "entry",
                artboardName: "Entry",
                width: 390,
                height: 844
            ),
            NuxPackageScreen(
                screenId: "details",
                artboardId: "details",
                artboardName: "Details",
                width: 390,
                height: 844
            ),
            NuxPackageScreen(
                screenId: "checkout",
                artboardId: "checkout",
                artboardName: "Checkout",
                width: 390,
                height: 844
            )
        ]
        return LoadedExperiencePackage.test(
            manifest: .test(
                experienceId: "coordinator-tests",
                buildId: "build-coordinator-tests",
                entryScreenId: "entry",
                screens: packageScreens
            ),
            journey: journey
        )
    }

    static let stateBootstrap: ExperienceRuntimeBootstrap = {
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
                        fields: [
                            ExperienceRuntimeValueEdge(key: "title", nodeIndex: 1),
                        ]
                    )),
                    ExperienceRuntimeValueNode(value: .scalar(.string("initial"))),
                ],
                roots: [
                    ExperienceRuntimeValueRoot(instanceID: rootID, nodeIndex: 0),
                ]
            )
        )
    }()
}

@MainActor
private final class CoordinatorScreenDelegate: ExperienceScreenViewControllerDelegate {
    func experienceScreenViewControllerDidAdvance(_ controller: ExperienceScreenViewController) {}

    func experienceScreenViewController(
        _ controller: ExperienceScreenViewController,
        didEmitEvent event: ExperienceRendererEvent
    ) {}

    func experienceScreenViewController(
        _ controller: ExperienceScreenViewController,
        didEmitViewModelChange change: ExperienceRendererViewModelChange
    ) {}

    func experienceScreenViewController(
        _ controller: ExperienceScreenViewController,
        didRequestOpenLink request: ExperienceRendererOpenLinkRequest
    ) {}
}
#endif
