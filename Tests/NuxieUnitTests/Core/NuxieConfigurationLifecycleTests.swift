import XCTest
@testable import Nuxie
@testable import NuxieTestSupport

private actor StartupLifecycleProbe {
    private var refetchStarted = false
    private var refetchWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []
    private var recoveryCalls = 0
    private var featureSyncCalls = 0
    private var observerStopped = false

    func refetch() async throws {
        refetchStarted = true
        let waiters = refetchWaiters
        refetchWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { releaseContinuations.append($0) }
    }

    func waitForRefetch() async {
        guard !refetchStarted else { return }
        await withCheckedContinuation { refetchWaiters.append($0) }
    }

    func releaseRefetch() {
        let continuations = releaseContinuations
        releaseContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    func recordRecovery() { recoveryCalls += 1 }
    func recordFeatureSync() { featureSyncCalls += 1 }
    func recordObserverStopped() { observerStopped = true }

    func snapshot() -> (recovery: Int, featureSync: Int, stopped: Bool) {
        (recoveryCalls, featureSyncCalls, observerStopped)
    }
}

final class NuxieConfigurationLifecycleTests: XCTestCase {
    func testShutdownStopsObserverBeforeAwaitingCancelledProfilePrefetch() async {
        let probe = StartupLifecycleProbe()
        let profilePrefetch = Task {
            await NuxieSDK.runProfilePrefetch(
                refetch: { try await probe.refetch() },
                recoverPurchases: { await probe.recordRecovery() },
                syncFeatures: { await probe.recordFeatureSync() }
            )
        }
        await probe.waitForRefetch()

        let cleanup = Task {
            await NuxieSDK.stopPurchasesAndAwaitStartupTasks(
                [profilePrefetch],
                stopPurchases: { await probe.recordObserverStopped() }
            )
        }
        try? await Task.sleep(nanoseconds: 25_000_000)
        var snapshot = await probe.snapshot()
        XCTAssertTrue(snapshot.stopped)

        await probe.releaseRefetch()
        await cleanup.value
        snapshot = await probe.snapshot()
        XCTAssertTrue(snapshot.stopped)
        XCTAssertEqual(snapshot.recovery, 0)
        XCTAssertEqual(snapshot.featureSync, 0)
    }

    func testSetupSnapshotDoesNotFollowBuilderMutation() {
        let configuration = NuxieConfiguration(apiKey: "snapshot-key")
        configuration.environment = .staging
        configuration.flushAt = 7
        configuration.featureCacheTTL = 42
        configuration.localeIdentifier = "en_US"
        configuration.purchaseHandlingMode = .observer
        let settings = NuxieRuntimeSettings(configuration: configuration)
        let snapshot = NuxieSetupConfiguration(configuration)

        configuration.environment = .development
        configuration.flushAt = 99
        configuration.featureCacheTTL = 999
        configuration.localeIdentifier = "es_ES"
        configuration.purchaseHandlingMode = .full

        XCTAssertEqual(snapshot.environment, .staging)
        XCTAssertEqual(snapshot.flushAt, 7)
        XCTAssertEqual(snapshot.featureCacheTTL, 42)
        XCTAssertEqual(settings.localeIdentifier(), "en_US")
        XCTAssertFalse(snapshot.testStoreEnabled)
        if case .observer = settings.purchaseHandlingMode() {} else {
            XCTFail("runtime purchase mode should keep its setup value")
        }
    }

    func testTestStoreRequiresDevelopmentEnvironmentAndTestKey() async {
        let sdk = NuxieSDK.shared
        await sdk.shutdown()

        let production = NuxieConfiguration(apiKey: "pk_test_demo")
        production.testStoreEnabled = true
        XCTAssertThrowsError(try sdk.setup(with: production)) { error in
            guard case .invalidConfiguration(let reason) = error as? NuxieError else {
                return XCTFail("expected invalid configuration")
            }
#if os(iOS)
            XCTAssertEqual(reason, "testStoreEnabled requires environment == .development")
#else
            XCTAssertEqual(reason, "testStoreEnabled is supported only on iOS")
#endif
        }

        let developmentWithLiveKey = NuxieConfiguration(apiKey: "pk_live_demo")
        developmentWithLiveKey.environment = .development
        developmentWithLiveKey.testStoreEnabled = true
        XCTAssertThrowsError(try sdk.setup(with: developmentWithLiveKey)) { error in
            guard case .invalidConfiguration(let reason) = error as? NuxieError else {
                return XCTFail("expected invalid configuration")
            }
#if os(iOS)
            XCTAssertEqual(reason, "testStoreEnabled requires a pk_test_ API key")
#else
            XCTAssertEqual(reason, "testStoreEnabled is supported only on iOS")
#endif
        }
    }

    func testRuntimeSettingsApplyOnlyThroughExplicitControls() async {
        let configuration = NuxieConfiguration(apiKey: "runtime-key")
        let firstDelegate = MockPurchaseDelegate()
        let secondDelegate = MockPurchaseDelegate()
        configuration.localeIdentifier = "en_US"
        configuration.purchaseDelegate = firstDelegate
        let settings = NuxieRuntimeSettings(configuration: configuration)

        settings.setLocaleIdentifier("fr_FR")
        settings.setPurchaseDelegate(secondDelegate)
        settings.setPurchaseHandlingMode(.observer)

        XCTAssertEqual(settings.localeIdentifier(), "fr_FR")
        XCTAssertTrue(settings.purchaseDelegate() === secondDelegate)
        if case .observer = settings.purchaseHandlingMode() {} else {
            XCTFail("expected observer mode")
        }

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<100 {
                group.addTask {
                    settings.setLocaleIdentifier("locale-\(index)")
                    _ = settings.localeIdentifier()
                    settings.setPurchaseHandlingMode(index.isMultiple(of: 2) ? .full : .observer)
                    _ = settings.purchaseHandlingMode()
                }
            }
        }
        XCTAssertTrue(settings.localeIdentifier().hasPrefix("locale-"))
    }

    func testSDKLocaleControlRefreshesWhileBuilderMutationIsIgnored() async throws {
        let sdk = NuxieSDK.shared
        await sdk.shutdown()
        let mocks = MockFactory.shared
        await mocks.resetAll()
        let configuration = NuxieConfiguration(apiKey: "runtime-key")
        configuration.localeIdentifier = "en_US"
        var overrides = mocks.unitTestOverrides()
        overrides.profile = nil
        try sdk.setup(with: configuration, overrides: overrides)
        defer { Task { await sdk.shutdown() } }

        configuration.localeIdentifier = "es_ES"
        _ = try await sdk.refreshProfile()
        let localeAfterBuilderMutation = await mocks.nuxieApi.lastProfileLocale
        XCTAssertEqual(localeAfterBuilderMutation, "en_US")

        _ = try await sdk.setLocaleIdentifier("fr_FR")
        let localeAfterRuntimeControl = await mocks.nuxieApi.lastProfileLocale
        XCTAssertEqual(localeAfterRuntimeControl, "fr_FR")
    }
}
