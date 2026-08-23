import XCTest
@testable import Nuxie
@testable import NuxieTestSupport

private actor StartupLifecycleProbe {
    private let failRefetchAfterRelease: Bool
    private var refetchStarted = false
    private var refetchWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []
    private var recoveryCalls = 0
    private var featureSyncCalls = 0
    private var observerStopped = false

    init(failRefetchAfterRelease: Bool = false) {
        self.failRefetchAfterRelease = failRefetchAfterRelease
    }

    func refetch() async throws {
        refetchStarted = true
        let waiters = refetchWaiters
        refetchWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { releaseContinuations.append($0) }
        if failRefetchAfterRelease {
            throw NuxieNetworkError.invalidResponse
        }
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
    func testSetupRejectsInvalidDeliveryCounts() async {
        await assertSetupRejects(
            { $0.eventBatchSize = 0 },
            reason: "eventBatchSize must be between 1 and \(Int32.max)"
        )
        await assertSetupRejects(
            { $0.flushAt = 0 },
            reason: "flushAt must be between 1 and \(Int32.max)"
        )
        await assertSetupRejects(
            { $0.maxQueueSize = -1 },
            reason: "maxQueueSize must be between 1 and \(Int32.max)"
        )
        await assertSetupRejects(
            {
                $0.flushAt = 11
                $0.maxQueueSize = 10
            },
            reason: "flushAt must not exceed maxQueueSize"
        )

        let unsupportedCount = Int(Int32.max) + 1
        await assertSetupRejects(
            { $0.eventBatchSize = unsupportedCount },
            reason: "eventBatchSize must be between 1 and \(Int32.max)"
        )
        await assertSetupRejects(
            {
                $0.flushAt = unsupportedCount
                $0.maxQueueSize = unsupportedCount
            },
            reason: "flushAt must be between 1 and \(Int32.max)"
        )
        await assertSetupRejects(
            { $0.maxQueueSize = unsupportedCount },
            reason: "maxQueueSize must be between 1 and \(Int32.max)"
        )
        await assertSetupRejects(
            { $0.maxQueueSize = Int.max },
            reason: "maxQueueSize must be between 1 and \(Int32.max)"
        )
    }

    func testValidatorAcceptsMaximumSupportedDeliveryCounts() throws {
        let configuration = NuxieConfiguration(apiKey: "configuration-key")
        let maximumCount = Int(Int32.max)
        configuration.eventBatchSize = maximumCount
        configuration.flushAt = maximumCount
        configuration.maxQueueSize = maximumCount

        XCTAssertNoThrow(try NuxieConfigurationValidator.validate(configuration))
    }

    func testValidatorRejectsDeliveryCountAboveSupportedMaximum() throws {
        let configuration = NuxieConfiguration(apiKey: "configuration-key")
        configuration.eventBatchSize = Int(Int32.max) + 1

        XCTAssertThrowsError(try NuxieConfigurationValidator.validate(configuration))
    }

    func testPendingDeliveryQueryLimitIncludesDirectDeliveriesWithoutOverflow() {
        let maximumSupported = Int(Int32.max)
        XCTAssertEqual(
            EventLog.pendingDeliveryQueryLimit(
                queueCapacity: maximumSupported,
                activeDirectDeliveryCount: 1
            ),
            maximumSupported + 1
        )
        XCTAssertEqual(
            EventLog.pendingDeliveryQueryLimit(
                queueCapacity: Int.max,
                activeDirectDeliveryCount: 1
            ),
            Int.max
        )
    }

    func testSetupRejectsInvalidRetryConfiguration() async {
        await assertSetupRejects(
            { $0.retryCount = -1 },
            reason: "retryCount must be nonnegative"
        )
        await assertSetupRejects(
            { $0.retryDelay = .nan },
            reason: "retryDelay must be finite and nonnegative"
        )
        await assertSetupRejects(
            { $0.retryDelay = -.infinity },
            reason: "retryDelay must be finite and nonnegative"
        )
        await assertSetupRejects(
            {
                $0.retryCount = 1_025
                $0.retryDelay = 1
            },
            reason: "retryCount and retryDelay produce an unschedulable backoff"
        )
    }

    func testSetupRejectsInvalidTimerAndCacheIntervals() async {
        await assertSetupRejects(
            { $0.flushInterval = 0 },
            reason: "flushInterval must be finite and greater than zero"
        )
        await assertSetupRejects(
            { $0.flushInterval = -1 },
            reason: "flushInterval must be finite and greater than zero"
        )
        await assertSetupRejects(
            { $0.flushInterval = .nan },
            reason: "flushInterval must be finite and greater than zero"
        )
        await assertSetupRejects(
            { $0.flushInterval = .infinity },
            reason: "flushInterval must be finite and greater than zero"
        )
        await assertSetupRejects(
            { $0.flushInterval = TimeInterval(UInt64.max) / 1_000_000_000 },
            reason: "flushInterval is too large to schedule safely"
        )
        await assertSetupRejects(
            { $0.flushInterval = .leastNonzeroMagnitude },
            reason: "flushInterval is too small to schedule safely"
        )
        await assertSetupRejects(
            { $0.featureCacheTTL = 0 },
            reason: "featureCacheTTL must be finite and greater than zero"
        )
        await assertSetupRejects(
            { $0.featureCacheTTL = -1 },
            reason: "featureCacheTTL must be finite and greater than zero"
        )
        await assertSetupRejects(
            { $0.featureCacheTTL = .nan },
            reason: "featureCacheTTL must be finite and greater than zero"
        )
        await assertSetupRejects(
            { $0.featureCacheTTL = .infinity },
            reason: "featureCacheTTL must be finite and greater than zero"
        )
    }

    func testValidatorAcceptsOneNanosecondFlushIntervalBoundary() throws {
        let configuration = NuxieConfiguration(apiKey: "configuration-key")
        configuration.flushInterval = 1 / 1_000_000_000

        XCTAssertNoThrow(try NuxieConfigurationValidator.validate(configuration))
    }

    func testSetupAcceptsZeroRetryDelayAndExistingDefaults() async throws {
        let sdk = NuxieSDK.shared
        await sdk.shutdown()

        let configuration = NuxieConfiguration(apiKey: "configuration-key")
        configuration.retryDelay = 0
        configuration.trackApplicationLifecycleEvents = false

        try sdk.setup(with: configuration)
        XCTAssertTrue(sdk.isSetup)
        await sdk.shutdown()
    }

    func testShutdownStopsObserverBeforeAwaitingCancelledProfilePrefetch() async {
        let probe = StartupLifecycleProbe(failRefetchAfterRelease: true)
        let profilePrefetch = Task {
            await NuxieSDK.runProfilePrefetch(
                refetch: { try await probe.refetch() },
                recoverProfileDependentState: { await probe.recordRecovery() },
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

    func testOfflineProfileRefreshStillWakesPurchaseRecoveryWithoutFeatureSync() async {
        let probe = StartupLifecycleProbe(failRefetchAfterRelease: true)
        let profilePrefetch = Task {
            await NuxieSDK.runProfilePrefetch(
                refetch: { try await probe.refetch() },
                recoverProfileDependentState: { await probe.recordRecovery() },
                syncFeatures: { await probe.recordFeatureSync() }
            )
        }
        await probe.waitForRefetch()
        await probe.releaseRefetch()
        await profilePrefetch.value

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.recovery, 1)
        XCTAssertEqual(snapshot.featureSync, 0)
        XCTAssertFalse(snapshot.stopped)
    }

    func testSuccessfulProfileRefreshWakesRecoveryThenSyncsFeatures() async {
        let probe = StartupLifecycleProbe()
        let profilePrefetch = Task {
            await NuxieSDK.runProfilePrefetch(
                refetch: { try await probe.refetch() },
                recoverProfileDependentState: { await probe.recordRecovery() },
                syncFeatures: { await probe.recordFeatureSync() }
            )
        }
        await probe.waitForRefetch()
        await probe.releaseRefetch()
        await profilePrefetch.value

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.recovery, 1)
        XCTAssertEqual(snapshot.featureSync, 1)
        XCTAssertFalse(snapshot.stopped)
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

    private func assertSetupRejects(
        _ configure: (NuxieConfiguration) -> Void,
        reason expectedReason: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let sdk = NuxieSDK.shared
        await sdk.shutdown()
        let configuration = NuxieConfiguration(apiKey: "configuration-key")
        configure(configuration)

        XCTAssertThrowsError(try sdk.setup(with: configuration), file: file, line: line) { error in
            guard case .invalidConfiguration(let reason) = error as? NuxieError else {
                return XCTFail("expected invalid configuration", file: file, line: line)
            }
            XCTAssertEqual(reason, expectedReason, file: file, line: line)
        }
        XCTAssertFalse(sdk.isSetup, file: file, line: line)
    }
}
