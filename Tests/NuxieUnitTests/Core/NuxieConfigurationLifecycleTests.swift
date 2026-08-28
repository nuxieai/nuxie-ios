import XCTest
@_spi(Testing) @_spi(Companion) @testable import Nuxie
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

private actor SuspendingTransactionObserver: TransactionObserverProtocol {
    private var usageStarted = false
    private var listeningStopped = false
    private var usageStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var usageReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var listeningStoppedWaiters: [CheckedContinuation<Void, Never>] = []

    func startListening() {}
    func stopListening() async {
        listeningStopped = true
        let waiters = listeningStoppedWaiters
        listeningStoppedWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func syncTransaction(
        transactionJws: String,
        transactionId: String,
        productId: String?,
        originalTransactionId: String?
    ) async -> Bool {
        false
    }

    func syncCurrentEntitlements(distinctId: String) async {}

    func purchaseCompletionEventId(transactionId: String) async -> String {
        "purchase-completed:lifecycle:\(transactionId)"
    }

    func useFeatureWithPendingPurchase(
        distinctId: String,
        featureId: String,
        amount: Double,
        entityId: String?,
        metadata: [String: AnyCodable]?
    ) async throws -> FeatureUsageResult? {
        usageStarted = true
        let waiters = usageStartedWaiters
        usageStartedWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { usageReleaseWaiters.append($0) }
        return nil
    }

    func waitUntilUsageStarts() async {
        guard !usageStarted else { return }
        await withCheckedContinuation { usageStartedWaiters.append($0) }
    }

    func releaseUsage() {
        let waiters = usageReleaseWaiters
        usageReleaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitUntilListeningStops() async {
        guard !listeningStopped else { return }
        await withCheckedContinuation { listeningStoppedWaiters.append($0) }
    }
}

private actor ShutdownCompletionProbe {
    private var completed = false

    func recordCompletion() {
        completed = true
    }

    func isComplete() -> Bool {
        completed
    }
}

private final class LifecycleCancellationSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var isSignalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            guard !isSignalled else { return [] }
            isSignalled = true
            let waiters = self.waiters
            self.waiters.removeAll()
            return waiters
        }
        waiters.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let alreadySignalled = lock.withLock { () -> Bool in
                guard !isSignalled else { return true }
                waiters.append(continuation)
                return false
            }
            if alreadySignalled {
                continuation.resume()
            }
        }
    }
}

private actor LifecycleTransitionGate {
    nonisolated let cancellation = LifecycleCancellationSignal()
    private var started = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func suspendUntilReleased() async {
        started = true
        let waiters = startedWaiters
        startedWaiters.removeAll()
        waiters.forEach { $0.resume() }

        await withTaskCancellationHandler {
            await withCheckedContinuation { releaseWaiters.append($0) }
        } onCancel: {
            cancellation.signal()
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func release() {
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private func waitForShutdownCompletion(
    _ probe: ShutdownCompletionProbe,
    attempts: Int = 200
) async -> Bool {
    for _ in 0..<attempts {
        if await probe.isComplete() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return await probe.isComplete()
}

private actor FacadeTaskStartBarrier {
    private var arrived = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        arrived = true
        let waiters = arrivalWaiters
        arrivalWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilArrived() async {
        guard !arrived else { return }
        await withCheckedContinuation { arrivalWaiters.append($0) }
    }

    func release() {
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor SuspendingFacadeTrigger: TriggerServiceProtocol {
    private let updateBeforeSuspending: TriggerUpdate?
    private var triggerStarted = false
    private var observedCancellation = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(updateBeforeSuspending: TriggerUpdate? = nil) {
        self.updateBeforeSuspending = updateBeforeSuspending
    }

    func trigger(
        _ event: String,
        properties: sending [String: Any]?,
        handler: @escaping @Sendable (TriggerUpdate) -> Void
    ) async {
        triggerStarted = true
        let waiters = startedWaiters
        startedWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if let updateBeforeSuspending {
            handler(updateBeforeSuspending)
        }
        await withCheckedContinuation { releaseWaiters.append($0) }
        observedCancellation = Task.isCancelled
    }

    func waitUntilStarted() async {
        guard !triggerStarted else { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func release() {
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func wasCancelled() -> Bool {
        observedCancellation
    }
}

private actor PendingJourneyFacadeTrigger: TriggerServiceProtocol {
    private let reference = ExperienceRef(
        experienceId: "pending-user-input-experience",
        experienceVersion: "1",
        journeyId: "pending-user-input-journey"
    )
    private var handler: (@Sendable (TriggerUpdate) -> Void)?
    private var started = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []

    func trigger(
        _ event: String,
        properties: sending [String: Any]?,
        handler: @escaping @Sendable (TriggerUpdate) -> Void
    ) async {
        // Lifecycle capture is always on (UNIV-2590); automatic $-events
        // must not stand in for the test's pending journey trigger.
        guard !event.hasPrefix("$") else {
            handler(.decision(.noMatch))
            return
        }
        self.handler = handler
        started = true
        let waiters = startedWaiters
        startedWaiters.removeAll()
        waiters.forEach { $0.resume() }
        handler(.decision(.journeyStarted(reference)))
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func finishJourney() {
        handler?(.journey(JourneyUpdate(
            journeyId: reference.journeyId!,
            experienceId: reference.experienceId,
            experienceVersion: reference.experienceVersion,
            exitReason: .completed,
            goalMet: false
        )))
    }
}

final class NuxieConfigurationLifecycleTests: XCTestCase {
    func testSetupRejectsInvalidDeliveryCounts() async {
        await assertSetupRejects(
            { $0.testingOverrides.eventBatchSize = 0 },
            reason: "eventBatchSize must be between 1 and \(Int32.max)"
        )
        await assertSetupRejects(
            { $0.testingOverrides.flushAt = 0 },
            reason: "flushAt must be between 1 and \(Int32.max)"
        )
        await assertSetupRejects(
            { $0.testingOverrides.maxQueueSize = -1 },
            reason: "maxQueueSize must be between 1 and \(Int32.max)"
        )
        await assertSetupRejects(
            {
                $0.testingOverrides.flushAt = 11
                $0.testingOverrides.maxQueueSize = 10
            },
            reason: "flushAt must not exceed maxQueueSize"
        )

        let unsupportedCount = Int(Int32.max) + 1
        await assertSetupRejects(
            { $0.testingOverrides.eventBatchSize = unsupportedCount },
            reason: "eventBatchSize must be between 1 and \(Int32.max)"
        )
        await assertSetupRejects(
            {
                $0.testingOverrides.flushAt = unsupportedCount
                $0.testingOverrides.maxQueueSize = unsupportedCount
            },
            reason: "flushAt must be between 1 and \(Int32.max)"
        )
        await assertSetupRejects(
            { $0.testingOverrides.maxQueueSize = unsupportedCount },
            reason: "maxQueueSize must be between 1 and \(Int32.max)"
        )
        await assertSetupRejects(
            { $0.testingOverrides.maxQueueSize = Int.max },
            reason: "maxQueueSize must be between 1 and \(Int32.max)"
        )
    }

    func testValidatorAcceptsMaximumSupportedDeliveryCounts() throws {
        let configuration = NuxieConfiguration(apiKey: "configuration-key")
        let maximumCount = Int(Int32.max)
        configuration.testingOverrides.eventBatchSize = maximumCount
        configuration.testingOverrides.flushAt = maximumCount
        configuration.testingOverrides.maxQueueSize = maximumCount

        XCTAssertNoThrow(try NuxieConfigurationValidator.validate(
            NuxieInternalConfiguration(testingOverrides: configuration.testingOverrides)
        ))
    }

    func testValidatorRejectsDeliveryCountAboveSupportedMaximum() throws {
        let configuration = NuxieConfiguration(apiKey: "configuration-key")
        configuration.testingOverrides.eventBatchSize = Int(Int32.max) + 1

        XCTAssertThrowsError(try NuxieConfigurationValidator.validate(
            NuxieInternalConfiguration(testingOverrides: configuration.testingOverrides)
        ))
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
            { $0.testingOverrides.retryCount = -1 },
            reason: "retryCount must be nonnegative"
        )
        await assertSetupRejects(
            { $0.testingOverrides.retryDelay = .nan },
            reason: "retryDelay must be finite and nonnegative"
        )
        await assertSetupRejects(
            { $0.testingOverrides.retryDelay = -.infinity },
            reason: "retryDelay must be finite and nonnegative"
        )
        await assertSetupRejects(
            {
                $0.testingOverrides.retryCount = 1_025
                $0.testingOverrides.retryDelay = 1
            },
            reason: "retryCount and retryDelay produce an unschedulable backoff"
        )
    }

    func testSetupRejectsInvalidTimerAndCacheIntervals() async {
        await assertSetupRejects(
            { $0.testingOverrides.flushInterval = 0 },
            reason: "flushInterval must be finite and greater than zero"
        )
        await assertSetupRejects(
            { $0.testingOverrides.flushInterval = -1 },
            reason: "flushInterval must be finite and greater than zero"
        )
        await assertSetupRejects(
            { $0.testingOverrides.flushInterval = .nan },
            reason: "flushInterval must be finite and greater than zero"
        )
        await assertSetupRejects(
            { $0.testingOverrides.flushInterval = .infinity },
            reason: "flushInterval must be finite and greater than zero"
        )
        await assertSetupRejects(
            { $0.testingOverrides.flushInterval = TimeInterval(UInt64.max) / 1_000_000_000 },
            reason: "flushInterval is too large to schedule safely"
        )
        await assertSetupRejects(
            { $0.testingOverrides.flushInterval = .leastNonzeroMagnitude },
            reason: "flushInterval is too small to schedule safely"
        )
        await assertSetupRejects(
            { $0.testingOverrides.featureCacheTTL = 0 },
            reason: "featureCacheTTL must be finite and greater than zero"
        )
        await assertSetupRejects(
            { $0.testingOverrides.featureCacheTTL = -1 },
            reason: "featureCacheTTL must be finite and greater than zero"
        )
        await assertSetupRejects(
            { $0.testingOverrides.featureCacheTTL = .nan },
            reason: "featureCacheTTL must be finite and greater than zero"
        )
        await assertSetupRejects(
            { $0.testingOverrides.featureCacheTTL = .infinity },
            reason: "featureCacheTTL must be finite and greater than zero"
        )
    }

    func testValidatorAcceptsOneNanosecondFlushIntervalBoundary() throws {
        let configuration = NuxieConfiguration(apiKey: "configuration-key")
        configuration.testingOverrides.flushInterval = 1 / 1_000_000_000

        XCTAssertNoThrow(try NuxieConfigurationValidator.validate(
            NuxieInternalConfiguration(testingOverrides: configuration.testingOverrides)
        ))
    }

    func testSetupAcceptsZeroRetryDelayAndExistingDefaults() async throws {
        let sdk = NuxieSDK.shared
        await sdk.shutdown()

        let configuration = NuxieConfiguration(apiKey: "configuration-key")
        configuration.testingOverrides.retryDelay = 0
        configuration.testingOverrides.suppressBackgroundWork = true

        try sdk.setup(with: configuration)
        XCTAssertTrue(sdk.isSetup)
        await sdk.shutdown()
    }

    func testBackgroundWorkSuppressionRequiresAnExplicitTestingOverride() async throws {
        let sdk = NuxieSDK.shared
        await sdk.shutdown()
        let mocks = MockFactory.shared
        await mocks.resetAll()

        let observer = MockTransactionObserver()
        var overrides = mocks.unitTestOverrides()
        overrides.transactionObserver = observer
        let configuration = NuxieConfiguration(apiKey: "explicit-background-work-control")
        configuration.testingOverrides.suppressBackgroundWork = true

        try sdk.setup(with: configuration, overrides: overrides)
        await sdk.waitForStartupTasks()

        XCTAssertEqual(mocks.profileService.fetchCallCount, 0)
        let observerStarted = await observer.startListeningCalled
        XCTAssertFalse(observerStarted)
        await sdk.shutdown()
    }

    func testBackgroundWorkRunsByDefaultWhenXCTestIsAttached() async throws {
        let sdk = NuxieSDK.shared
        await sdk.shutdown()
        let mocks = MockFactory.shared
        await mocks.resetAll()

        let observer = MockTransactionObserver()
        var overrides = mocks.unitTestOverrides()
        overrides.transactionObserver = observer

        try sdk.setup(
            with: NuxieConfiguration(apiKey: "xctest-does-not-change-production-behavior"),
            overrides: overrides
        )
        await sdk.waitForStartupTasks()

        XCTAssertEqual(mocks.profileService.fetchCallCount, 1)
        let observerStarted = await observer.startListeningCalled
        XCTAssertTrue(observerStarted)
        await sdk.shutdown()
    }

    func testShutdownCompletesForTheDefaultTestGraph() async throws {
        let sdk = NuxieSDK.shared
        await sdk.shutdown()
        let mocks = MockFactory.shared
        await mocks.resetAll()
        try sdk.setup(
            with: configurationWithoutBackgroundWork(apiKey: "shutdown-lifecycle-key"),
            overrides: mocks.unitTestOverrides()
        )

        await sdk.shutdown()

        XCTAssertFalse(sdk.isSetup)
        XCTAssertNil(sdk.core)
    }

    func testConcurrentFacadeLifecycleStressLeavesNoRunningGraphOrPresentation() async {
        let sdk = NuxieSDK.shared
        await sdk.shutdown()
        let mocks = MockFactory.shared
        await mocks.resetAll()
        let overrides = UncheckedSendable(mocks.unitTestOverrides())

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<80 {
                switch index % 4 {
                case 0:
                    group.addTask {
                        let configuration = NuxieConfiguration(
                            apiKey: "concurrent-lifecycle-\(index)"
                        )
                        configuration.testingOverrides.suppressBackgroundWork = true
                        try? sdk.setup(
                            with: configuration,
                            overrides: overrides.value
                        )
                    }
                case 1:
                    group.addTask {
                        sdk.trigger("concurrent-lifecycle-trigger")
                    }
                case 2:
                    group.addTask {
                        sdk.identify("concurrent-user-\(index)")
                    }
                default:
                    group.addTask {
                        await sdk.shutdown()
                    }
                }
            }
        }

        await sdk.shutdown()
        sdk.trigger("post-shutdown-trigger")
        sdk.identify("post-shutdown-user")
        await Task.yield()

        XCTAssertFalse(sdk.isSetup)
        XCTAssertNil(sdk.core)
        let isPresented = await mocks.experiencePresentationService.isExperiencePresented
        XCTAssertFalse(isPresented)
    }

    func testShutdownWaitsForSuspendedPublicOperationBeforeReplacementSetup() async throws {
        let sdk = NuxieSDK.shared
        await sdk.shutdown()

        let mocks = MockFactory.shared
        await mocks.resetAll()
        let firstAPI = MockNuxieApi()
        let firstObserver = SuspendingTransactionObserver()
        var firstOverrides = mocks.unitTestOverrides()
        firstOverrides.api = firstAPI
        firstOverrides.transactionObserver = firstObserver

        try sdk.setup(
            with: configurationWithoutBackgroundWork(apiKey: "first-lifecycle-key"),
            overrides: firstOverrides
        )

        let usage = Task {
            try await sdk.useFeatureAndWait("generation-bound-feature")
        }
        await firstObserver.waitUntilUsageStarts()

        let shutdownCompletion = ShutdownCompletionProbe()
        let shutdown = Task {
            await sdk.shutdown()
            await shutdownCompletion.recordCompletion()
        }
        await firstObserver.waitUntilListeningStops()

        XCTAssertFalse(sdk.isSetup)
        XCTAssertNil(sdk.core)
        let shutdownFinishedWhileUsageWasSuspended = await shutdownCompletion.isComplete()
        XCTAssertFalse(shutdownFinishedWhileUsageWasSuspended)

        await firstObserver.releaseUsage()
        let result = try await usage.value
        await shutdown.value

        XCTAssertTrue(result.success)
        let firstAPICalls = await firstAPI.trackEventCallCount
        XCTAssertEqual(firstAPICalls, 1)

        let secondAPI = MockNuxieApi()
        var secondOverrides = mocks.unitTestOverrides()
        secondOverrides.api = secondAPI
        secondOverrides.transactionObserver = MockTransactionObserver()
        try sdk.setup(
            with: configurationWithoutBackgroundWork(apiKey: "second-lifecycle-key"),
            overrides: secondOverrides
        )
        let replacementCore = try XCTUnwrap(sdk.core)
        XCTAssertTrue(sdk.core === replacementCore)
        let secondAPICalls = await secondAPI.trackEventCallCount
        XCTAssertEqual(secondAPICalls, 0)

        await sdk.shutdown()
    }

    func testShutdownCancelsAndWaitsForSuspendedFacadeTrigger() async throws {
        let sdk = NuxieSDK.shared
        await sdk.shutdown()

        let mocks = MockFactory.shared
        await mocks.resetAll()
        let trigger = SuspendingFacadeTrigger()
        let observer = SuspendingTransactionObserver()
        var overrides = mocks.unitTestOverrides()
        overrides.triggers = trigger
        overrides.transactionObserver = observer
        let configuration = NuxieConfiguration(apiKey: "trigger-lifecycle-key")
        configuration.testingOverrides.suppressBackgroundWork = true
        configuration.beforeSend = { event in
            event.name.hasPrefix("$app_") ? nil : event
        }
        try sdk.setup(
            with: configuration,
            overrides: overrides
        )

        sdk.trigger("delayed-before-shutdown")
        await trigger.waitUntilStarted()

        let completion = ShutdownCompletionProbe()
        let shutdown = Task {
            await sdk.shutdown()
            await completion.recordCompletion()
        }
        await observer.waitUntilListeningStops()

        let completedWhileTriggerWasSuspended = await completion.isComplete()
        XCTAssertFalse(completedWhileTriggerWasSuspended)

        await trigger.release()
        await shutdown.value

        let triggerWasCancelled = await trigger.wasCancelled()
        let shutdownCompleted = await completion.isComplete()
        XCTAssertTrue(triggerWasCancelled)
        XCTAssertTrue(shutdownCompleted)
    }

    func testCancelBeforeStartTriggerAndWaitSettlesBeforeShutdownCompletes() async throws {
        let sdk = NuxieSDK.shared
        await sdk.shutdown()

        let mocks = MockFactory.shared
        await mocks.resetAll()
        let startBarrier = FacadeTaskStartBarrier()
        let trigger = SuspendingFacadeTrigger(
            updateBeforeSuspending: .decision(.noMatch)
        )
        let observer = SuspendingTransactionObserver()
        var overrides = mocks.unitTestOverrides()
        overrides.triggers = trigger
        overrides.transactionObserver = observer
        let configuration = NuxieConfiguration(apiKey: "trigger-and-wait-lifecycle-key")
        configuration.testingOverrides.suppressBackgroundWork = true
        configuration.beforeSend = { event in
            event.name.hasPrefix("$app_") ? nil : event
        }
        try sdk.setup(
            with: configuration,
            overrides: overrides,
            facadeTaskStartBarrier: { await startBarrier.wait() }
        )

        let result = Task {
            await sdk.triggerAndWait("cancelled-before-worker-start")
        }
        await startBarrier.waitUntilArrived()

        let completion = ShutdownCompletionProbe()
        let shutdown = Task {
            await sdk.shutdown()
            await completion.recordCompletion()
        }
        await observer.waitUntilListeningStops()

        let completedWhileWorkerWasSuspended = await completion.isComplete()
        XCTAssertFalse(completedWhileWorkerWasSuspended)

        await startBarrier.release()
        await trigger.waitUntilStarted()
        let triggerResult = await result.value
        XCTAssertEqual(triggerResult, .noMatch)

        let completedAfterEarlyResult = await completion.isComplete()
        XCTAssertFalse(completedAfterEarlyResult)

        await trigger.release()
        await shutdown.value

        let triggerWasCancelled = await trigger.wasCancelled()
        let shutdownCompleted = await completion.isComplete()
        XCTAssertTrue(triggerWasCancelled)
        XCTAssertTrue(shutdownCompleted)
    }

    func testShutdownSettlesTriggerAndWaitWhileJourneyAwaitsUserInput() async throws {
        let sdk = NuxieSDK.shared
        await sdk.shutdown()

        let mocks = MockFactory.shared
        await mocks.resetAll()
        let trigger = PendingJourneyFacadeTrigger()
        let observer = SuspendingTransactionObserver()
        var overrides = mocks.unitTestOverrides()
        overrides.triggers = trigger
        overrides.transactionObserver = observer
        let configuration = NuxieConfiguration(apiKey: "pending-journey-lifecycle-key")
        configuration.testingOverrides.suppressBackgroundWork = true
        configuration.beforeSend = { event in
            event.name.hasPrefix("$app_") ? nil : event
        }
        try sdk.setup(
            with: configuration,
            overrides: overrides
        )

        let resultTask = Task {
            await sdk.triggerAndWait("journey-awaiting-user-input")
        }
        await trigger.waitUntilStarted()

        let completion = ShutdownCompletionProbe()
        let shutdown = Task {
            await sdk.shutdown()
            await completion.recordCompletion()
        }
        await observer.waitUntilListeningStops()

        let shutdownSettledPendingJourney = await waitForShutdownCompletion(completion)
        if !shutdownSettledPendingJourney {
            // Let the broken implementation unwind after proving it cannot
            // settle the pending caller on shutdown.
            await trigger.finishJourney()
        }
        let result = await resultTask.value
        await shutdown.value

        XCTAssertTrue(
            shutdownSettledPendingJourney,
            "shutdown must settle a trigger waiting on active-journey user input"
        )
        XCTAssertEqual(
            result,
            .error(TriggerError(
                code: .triggerFailed,
                message: "SDK shutdown began before the journey completed"
            ))
        )
    }

    func testShutdownStopsLifecycleIntakeAndJoinsActiveTransitionBeforeTeardown() async throws {
        let sdk = NuxieSDK.shared
        await sdk.shutdown()

        let mocks = MockFactory.shared
        await mocks.resetAll()
        let gate = LifecycleTransitionGate()
        let experiences = MockExperienceService()
        experiences.onAppBecameActiveHandler = {
            await gate.suspendUntilReleased()
        }
        let journeys = MockJourneyService()
        var overrides = mocks.unitTestOverrides()
        overrides.experiences = experiences
        overrides.journeys = journeys
        try sdk.setup(
            with: configurationWithoutBackgroundWork(apiKey: "notification-lifecycle-key"),
            overrides: overrides
        )

        await MainActor.run {
            NotificationCenter.default.post(
                name: NuxieSystemNotifications.appDidBecomeActive,
                object: nil
            )
        }
        await gate.waitUntilStarted()

        let completion = ShutdownCompletionProbe()
        let shutdown = Task {
            await sdk.shutdown()
            await completion.recordCompletion()
        }
        await gate.cancellation.wait()

        let completedBeforeTransitionJoined = await completion.isComplete()
        let teardownCallsBeforeTransitionJoined = await journeys.shutdownCallCount

        // Intake must already be closed while shutdown joins the in-flight
        // transition; this notification must not enter the old graph.
        await MainActor.run {
            NotificationCenter.default.post(
                name: NuxieSystemNotifications.appDidBecomeActive,
                object: nil
            )
        }

        await gate.release()
        await shutdown.value

        XCTAssertFalse(
            completedBeforeTransitionJoined,
            "shutdown must join the active lifecycle worker"
        )
        XCTAssertEqual(
            teardownCallsBeforeTransitionJoined,
            0,
            "graph teardown must not begin before lifecycle transition intake stops and its worker joins"
        )
        XCTAssertEqual(experiences.foregroundPreparationResumeCallCount, 1)
        let finalTeardownCalls = await journeys.shutdownCallCount
        XCTAssertEqual(finalTeardownCalls, 1)
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
        configuration.testingOverrides.flushAt = 7
        configuration.testingOverrides.featureCacheTTL = 42
        configuration.testingOverrides.presentationDiagnosticsEnabled = true
        configuration.localeIdentifier = "en_US"
        configuration.purchaseHandlingMode = .observer
        let settings = NuxieRuntimeSettings(configuration: configuration)
        let snapshot = NuxieSetupConfiguration(configuration)

        configuration.environment = .development
        configuration.testingOverrides.flushAt = 99
        configuration.testingOverrides.featureCacheTTL = 999
        configuration.testingOverrides.presentationDiagnosticsEnabled = false
        configuration.localeIdentifier = "es_ES"
        configuration.purchaseHandlingMode = .full

        XCTAssertEqual(snapshot.environment, .staging)
        XCTAssertEqual(snapshot.internalConfiguration.flushAt, 7)
        XCTAssertEqual(snapshot.internalConfiguration.featureCacheTTL, 42)
        XCTAssertTrue(snapshot.internalConfiguration.presentationDiagnosticsEnabled)
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
        configuration.testingOverrides.suppressBackgroundWork = true
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
        configuration.testingOverrides.suppressBackgroundWork = true
        configuration.localeIdentifier = "en_US"
        var overrides = mocks.unitTestOverrides()
        overrides.profile = nil
        try sdk.setup(with: configuration, overrides: overrides)
        defer { Task { await sdk.shutdown() } }

        configuration.localeIdentifier = "es_ES"
        _ = try await sdk.core!.profile.refetchProfile()
        let localeAfterBuilderMutation = await mocks.nuxieApi.lastProfileLocale
        XCTAssertEqual(localeAfterBuilderMutation, "en_US")

        try await sdk.setLocaleIdentifier("fr_FR")
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

    private func configurationWithoutBackgroundWork(apiKey: String) -> NuxieConfiguration {
        let configuration = NuxieConfiguration(apiKey: apiKey)
        configuration.testingOverrides.suppressBackgroundWork = true
        return configuration
    }
}
