import Foundation
import XCTest
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

final class RecoverySyncAPI: PurchaseSynchronizing, @unchecked Sendable {
    private let lock = NSLock()
    private var customers: [String] = []
    let succeeds: Bool

    init(succeeds: Bool) { self.succeeds = succeeds }

    func syncTransaction(
        transactionJwt _: String,
        distinctId: String
    ) async throws -> PurchaseResponse {
        lock.withLock { customers.append(distinctId) }
        if !succeeds { throw URLError(.notConnectedToInternet) }
        return PurchaseResponse(
            success: true,
            customerId: distinctId,
            features: nil,
            error: nil
        )
    }

    var recordedCustomers: [String] { lock.withLock { customers } }
}

private actor ControlledConcurrentRecoverySyncAPI: PurchaseSynchronizing {
    private var customers: [String] = []
    private var firstRequestWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private var cancelled = false

    func syncTransaction(
        transactionJwt _: String,
        distinctId: String
    ) async throws -> PurchaseResponse {
        customers.append(distinctId)
        let requestWaiters = firstRequestWaiters
        firstRequestWaiters.removeAll()
        requestWaiters.forEach { $0.resume() }
        await withTaskCancellationHandler {
            if !released {
                await withCheckedContinuation { continuation in
                    releaseWaiters.append(continuation)
                }
            }
        } onCancel: {
            Task { await self.recordCancellation() }
        }
        return PurchaseResponse(
            success: true,
            customerId: distinctId,
            features: nil,
            error: nil
        )
    }

    func waitForFirstRequest() async {
        guard customers.isEmpty else { return }
        await withCheckedContinuation { continuation in
            firstRequestWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitForCancellation() async {
        guard !cancelled else { return }
        await withCheckedContinuation { continuation in
            cancellationWaiters.append(continuation)
        }
    }

    private func recordCancellation() {
        cancelled = true
        let waiters = cancellationWaiters
        cancellationWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func recordedCustomers() -> [String] { customers }

    func waitForRequestCount(
        _ count: Int,
        timeoutNanoseconds: UInt64 = 500_000_000
    ) async -> Bool {
        if customers.count >= count { return true }
        try? await Task.sleep(nanoseconds: timeoutNanoseconds)
        return customers.count >= count
    }
}

private actor SequencedRecoverySyncAPI: PurchaseSynchronizing {
    private var results: [Bool]
    private var requestCount = 0

    init(results: [Bool]) { self.results = results }

    func syncTransaction(
        transactionJwt _: String,
        distinctId: String
    ) async throws -> PurchaseResponse {
        _ = distinctId
        requestCount += 1
        let succeeds = results.isEmpty ? true : results.removeFirst()
        return PurchaseResponse(
            success: succeeds,
            customerId: distinctId,
            features: nil,
            error: succeeds ? nil : "temporary failure"
        )
    }

    func requests() -> Int { requestCount }
}

private actor ShutdownControlledSyncAPI: PurchaseSynchronizing {
    private var started = false
    private var cancelled = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var requestContinuation: CheckedContinuation<Void, Error>?
    private var requestCount = 0

    func syncTransaction(
        transactionJwt _: String,
        distinctId: String
    ) async throws -> PurchaseResponse {
        requestCount += 1
        if requestCount > 1 {
            return PurchaseResponse(
                success: true,
                customerId: distinctId,
                features: nil,
                error: nil
            )
        }
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    requestContinuation = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelRequest() }
        }
        return PurchaseResponse(
            success: true,
            customerId: distinctId,
            features: nil,
            error: nil
        )
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func waitForCancellation() async -> Bool {
        for _ in 0..<20 {
            if cancelled { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return cancelled
    }

    func release() {
        requestContinuation?.resume()
        requestContinuation = nil
    }

    func requests() -> Int { requestCount }

    private func cancelRequest() {
        cancelled = true
        requestContinuation?.resume(throwing: CancellationError())
        requestContinuation = nil
    }
}

final class RecoveryEventSink: SystemEventSink, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(name: String, properties: [String: Any]?)] = []
    private var routedCaptures = 0
    private var captureOnlyCaptures = 0

    func emit(_ name: String, properties: [String: Any]?) {
        lock.withLock { storage.append((name, properties)) }
    }

    func capture(
        _ request: StableSystemEventCaptureRequest
    ) async -> Bool {
        lock.withLock {
            routedCaptures += 1
            storage.append((request.name, request.properties))
        }
        return true
    }

    func captureOnly(
        _ request: StableSystemEventCaptureRequest
    ) async -> Bool {
        lock.withLock {
            captureOnlyCaptures += 1
            storage.append((request.name, request.properties))
        }
        return true
    }

    var events: [(name: String, properties: [String: Any]?)] {
        lock.withLock { storage }
    }
    var routedCaptureCount: Int { lock.withLock { routedCaptures } }
    var captureOnlyCount: Int { lock.withLock { captureOnlyCaptures } }
}

private final class ControlledRecoveryEventSink:
    SystemEventSink,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var captureSucceeds: Bool
    private var captured: [(name: String, eventId: String)] = []
    private var capturedOnly: [(name: String, eventId: String)] = []
    private var attemptedEventIds: [String] = []
    private var routedAttempts = 0
    private var captureOnlyAttempts = 0

    init(captureSucceeds: Bool) {
        self.captureSucceeds = captureSucceeds
    }

    func emit(_ name: String, properties: [String: Any]?) {}

    func capture(
        _ request: StableSystemEventCaptureRequest
    ) async -> Bool {
        lock.withLock {
            routedAttempts += 1
            attemptedEventIds.append(request.eventId)
            guard captureSucceeds else { return false }
            captured.append((request.name, request.eventId))
            return true
        }
    }

    func captureOnly(
        _ request: StableSystemEventCaptureRequest
    ) async -> Bool {
        return lock.withLock {
            captureOnlyAttempts += 1
            attemptedEventIds.append(request.eventId)
            guard captureSucceeds else { return false }
            capturedOnly.append((request.name, request.eventId))
            return true
        }
    }

    func setCaptureSucceeds(_ succeeds: Bool) {
        lock.withLock { captureSucceeds = succeeds }
    }

    var captures: [(name: String, eventId: String)] {
        lock.withLock { captured + capturedOnly }
    }

    var routedCaptureCount: Int { lock.withLock { captured.count } }
    var captureOnlyCount: Int { lock.withLock { capturedOnly.count } }
    var routedAttemptCount: Int { lock.withLock { routedAttempts } }
    var captureOnlyAttemptCount: Int { lock.withLock { captureOnlyAttempts } }
    var attemptedCompletionEventIds: [String] {
        lock.withLock { attemptedEventIds }
    }
}

private final class DurableEventLogSink: SystemEventSink, Sendable {
    private let eventLog: EventLog

    init(eventLog: EventLog) { self.eventLog = eventLog }

    func emit(_ name: String, properties: [String: Any]?) {}

    func capture(
        _ request: StableSystemEventCaptureRequest
    ) async -> Bool {
        await captureOnly(request)
    }

    func captureOnly(
        _ request: StableSystemEventCaptureRequest
    ) async -> Bool {
        await eventLog.captureSystemEvent(
            request.name,
            properties: request.properties,
            eventId: request.eventId,
            distinctId: request.distinctId
        ) != nil
    }
}

private final class ControlledTransactionEvidenceStore:
    TransactionEvidenceStoreProtocol,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var entries: [String: StoredTransactionEvidence]
    private var saveSucceeds: Bool

    init(
        entries: [String: StoredTransactionEvidence],
        saveSucceeds: Bool
    ) {
        self.entries = entries
        self.saveSucceeds = saveSucceeds
    }

    func load() -> StoreReadResult<[String: StoredTransactionEvidence]> {
        lock.withLock { .value(entries) }
    }

    func save(_ entries: [String: StoredTransactionEvidence]) -> Bool {
        lock.withLock {
            guard saveSucceeds else { return false }
            self.entries = entries
            return true
        }
    }

    func setSaveSucceeds(_ succeeds: Bool) {
        lock.withLock { saveSucceeds = succeeds }
    }
}

actor FinishCounter {
    private var value = 0
    func increment() { value += 1 }
    func count() -> Int { value }
}

private actor SuspendedProductAuthority {
    private var resolution: ActiveProductEvidenceAuthorityResolution = .unavailable

    func set(_ resolution: ActiveProductEvidenceAuthorityResolution) {
        self.resolution = resolution
    }

    func resolve(_ productId: String) -> ActiveProductEvidenceAuthorityResolution {
        _ = productId
        return resolution
    }
}

actor RecoveryTransactionSourceProbe {
    private var unfinished: [StoreTransactionRecoveryItem] = []
    private var currentEntitlements: [StoreTransactionRecoveryItem] = []
    private var unfinishedReads = 0
    private var currentEntitlementReads = 0

    func setUnfinished(_ items: [StoreTransactionRecoveryItem]) {
        unfinished = items
    }

    func setCurrentEntitlements(_ items: [StoreTransactionRecoveryItem]) {
        currentEntitlements = items
    }

    func unfinishedItems() -> [StoreTransactionRecoveryItem] {
        unfinishedReads += 1
        return unfinished
    }
    func currentEntitlementItems() -> [StoreTransactionRecoveryItem] {
        currentEntitlementReads += 1
        return currentEntitlements
    }

    func readCounts() -> (unfinished: Int, currentEntitlements: Int) {
        (unfinishedReads, currentEntitlementReads)
    }
}

private actor UnusedProductAuthorityReleaseStore: ExperienceReleaseAcquiring {
    func authenticateProfile(
        _ profile: ExperienceReleaseProfile
    ) async throws -> AuthenticatedExperienceReleaseCatalog {
        _ = profile
        throw ExperienceReleaseAcquisitionError.invalidProfileEntry
    }

    func prepare(
        definition: AuthenticatedExperienceReleaseDefinition,
        intent: ExperienceReleasePreparationIntent
    ) async throws -> PreparedExperienceRelease {
        _ = definition
        _ = intent
        throw ExperienceReleaseAcquisitionError.invalidProfileEntry
    }
}

private actor AsyncCallCounter {
    private var value = 0
    func increment() { value += 1 }
    func count() -> Int { value }
}

actor RecoveryFeatureRecorder: FeatureServiceProtocol {
    private var suspendPurchaseUpdate = false
    private var purchaseUpdateStarted = false
    private var purchaseUpdateWaiters: [CheckedContinuation<Void, Never>] = []
    private var purchaseUpdateRelease: [CheckedContinuation<Void, Never>] = []
    private var completedPurchaseUpdates = 0

    func getCached(featureId: String, entityId: String?) async -> FeatureAccess? {
        nil
    }
    func getAllCached() async -> [String: FeatureAccess] { [:] }
    func check(
        featureId: String,
        requiredBalance: Double?,
        entityId: String?
    ) async throws -> FeatureCheckResult {
        throw NuxieNetworkError.invalidResponse
    }
    func checkWithCache(
        featureId: String,
        requiredBalance: Double?,
        entityId: String?,
        forceRefresh: Bool
    ) async throws -> FeatureAccess {
        .notFound
    }
    func clearCache() async {}
    func handleUserChange(from oldDistinctId: String, to newDistinctId: String) async {}
    func syncFeatureInfo() async {}
    func updateFromPurchase(
        _ features: [PurchaseFeature],
        distinctId: String
    ) async {
        _ = features
        _ = distinctId
        purchaseUpdateStarted = true
        let waiters = purchaseUpdateWaiters
        purchaseUpdateWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if suspendPurchaseUpdate {
            await withCheckedContinuation { purchaseUpdateRelease.append($0) }
        }
        completedPurchaseUpdates += 1
    }
    func suspendNextPurchaseUpdate() { suspendPurchaseUpdate = true }

    func waitForPurchaseUpdate() async {
        guard !purchaseUpdateStarted else { return }
        await withCheckedContinuation { purchaseUpdateWaiters.append($0) }
    }

    func releasePurchaseUpdate() {
        suspendPurchaseUpdate = false
        let waiters = purchaseUpdateRelease
        purchaseUpdateRelease.removeAll()
        waiters.forEach { $0.resume() }
    }

    func purchaseUpdateCount() -> Int { completedPurchaseUpdates }
}

private final class FeaturePurchaseSyncAPI: PurchaseSynchronizing, Sendable {
    func syncTransaction(
        transactionJwt _: String,
        distinctId: String
    ) async throws -> PurchaseResponse {
        PurchaseResponse(
            success: true,
            customerId: distinctId,
            features: [
                PurchaseFeature(
                    id: "feature-1",
                    extId: "pro",
                    type: .boolean,
                    allowed: true,
                    balance: nil,
                    unlimited: false
                ),
            ],
            error: nil
        )
    }
}

private final class FailingPendingPurchaseStore:
    PendingPurchaseStoreProtocol,
    @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: PendingPurchaseRecord]

    init(entries: [String: PendingPurchaseRecord]) {
        self.entries = entries
    }

    func load() -> StoreReadResult<[String: PendingPurchaseRecord]> {
        lock.withLock { .value(entries) }
    }

    func save(_: [String: PendingPurchaseRecord]) -> Bool { false }
}

private final class RecoveryDeletionFailureStore:
    PendingPurchaseStoreProtocol,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var entries: [String: PendingPurchaseRecord] = [:]

    func load() -> StoreReadResult<[String: PendingPurchaseRecord]> {
        lock.withLock { .value(entries) }
    }

    func save(_ entries: [String: PendingPurchaseRecord]) -> Bool {
        lock.withLock {
            guard !entries.isEmpty else { return false }
            self.entries = entries
            return true
        }
    }
}

final class PurchaseRecoveryScopeTests: XCTestCase {
    private func commercialContext() -> PurchaseCommercialContext {
        PurchaseCommercialContext(
            release: AuthenticatedExperienceReleaseID(
                identity: ExperienceReleaseIdentity(
                    appId: "app-1",
                    environment: "live",
                    experienceId: "experience-1",
                    experienceVersionId: "version-1",
                    buildId: "build-1",
                    versionNumber: 1,
                    releaseCreatedAt: "2026-08-19T00:00:00Z",
                    releaseSequence: 1
                ),
                descriptorSHA256: String(repeating: "b", count: 64)
            ),
            placementId: "placement-1",
            productId: "product-1",
            storeProductId: "store-product-1",
            displayPrice: "$9.99",
            price: 9.99
        )
    }

    func testPurchaseCompletionEventIdentityIsScopedAcrossAppEnvironmentAndStore() async {
        let mocks = MockFactory.shared
        let configuration = NuxieConfiguration(apiKey: "scope-test")
        let settings = NuxieRuntimeSettings(configuration: configuration)
        let features = FeatureService(
            api: mocks.nuxieApi,
            identity: mocks.identityService,
            profile: mocks.profileService,
            dateProvider: mocks.dateProvider,
            featureInfo: FeatureInfo(),
            cacheTTL: NuxieInternalConfiguration().featureCacheTTL
        )
        func makeObserver(scope: PurchaseStorageScope) -> TransactionObserver {
            TransactionObserver(
                api: RecoverySyncAPI(succeeds: true),
                features: features,
                identity: mocks.identityService,
                settings: settings,
                eventSink: RecoveryEventSink(),
                transactionServiceProvider: { fatalError("unused") },
                evidenceStore: InMemoryTransactionEvidenceStore(),
                purchaseStorageScope: scope,
                dateProvider: mocks.dateProvider,
                activeStoreOriginalTransactionIDs: { [] }
            )
        }

        let scopes = [
            PurchaseStorageScope(
                appIdentifierHash: "app-a",
                environment: "production",
                storeEnvironment: .appStore
            ),
            PurchaseStorageScope(
                appIdentifierHash: "app-b",
                environment: "production",
                storeEnvironment: .appStore
            ),
            PurchaseStorageScope(
                appIdentifierHash: "app-a",
                environment: "staging",
                storeEnvironment: .appStore
            ),
            PurchaseStorageScope(
                appIdentifierHash: "app-a",
                environment: "production",
                storeEnvironment: .testStore
            ),
        ]
        var eventIds: [String] = []
        for scope in scopes {
            eventIds.append(await makeObserver(scope: scope)
                .purchaseCompletionEventId(transactionId: "transaction-1"))
        }

        XCTAssertEqual(Set(eventIds).count, scopes.count)
        XCTAssertEqual(
            eventIds[0],
            "purchase-completed:app-a:production:appStore:transaction-1"
        )
        XCTAssertEqual(
            eventIds[3],
            "purchase-completed:app-a:production:testStore:transaction-1"
        )
    }

    func testCanonicalCompletionPayloadChangesOnlyInSourceProvenance() {
        let context = commercialContext()
        let directCallback = purchaseCompletionProperties(
            context: context,
            transactionId: "transaction-1",
            testStore: false,
            source: .checkout
        )
        let storeUpdateRecovery = purchaseCompletionProperties(
            context: context,
            transactionId: "transaction-1",
            testStore: false,
            source: .transactionStream
        )

        XCTAssertEqual(
            directCallback["source"] as? String,
            PurchaseOutcomeSource.checkout.rawValue
        )
        XCTAssertEqual(
            storeUpdateRecovery["source"] as? String,
            PurchaseOutcomeSource.transactionStream.rawValue
        )

        var directPayload = directCallback
        var recoveryPayload = storeUpdateRecovery
        directPayload.removeValue(forKey: "source")
        recoveryPayload.removeValue(forKey: "source")

        XCTAssertEqual(
            directPayload as NSDictionary,
            recoveryPayload as NSDictionary
        )
        XCTAssertEqual(
            directPayload as NSDictionary,
            [
                "product_id": "product-1",
                "placement_id": "placement-1",
                "store_product_id": "store-product-1",
                "experience_id": "experience-1",
                "test_store": false,
                "transaction_id": "transaction-1",
                "display_price": "$9.99",
                "price": 9.99,
            ] as NSDictionary
        )
    }

    func testAccountTokenIsStableOnlyInsideExactRuntimeScope() {
        let live = PurchaseStorageScope(
            appIdentifierHash: "app-a",
            environment: "production",
            storeEnvironment: .appStore
        )
        let test = PurchaseStorageScope(
            appIdentifierHash: "app-a",
            environment: "development",
            storeEnvironment: .testStore
        )

        XCTAssertEqual(
            live.appAccountToken(distinctId: "customer-a"),
            live.appAccountToken(distinctId: "customer-a")
        )
        XCTAssertNotEqual(
            live.appAccountToken(distinctId: "customer-a"),
            live.appAccountToken(distinctId: "customer-b")
        )
        XCTAssertNotEqual(
            live.appAccountToken(distinctId: "customer-a"),
            test.appAccountToken(distinctId: "customer-a")
        )
    }

    func testAppScopeSurvivesPublishableKeyRotation() {
        let firstConfiguration = NuxieConfiguration(apiKey: "pk-old")
        let rotatedConfiguration = NuxieConfiguration(apiKey: "pk-new")
        let first = PurchaseStorageScope(
            appIdentifier: "com.example.host-app",
            environment: firstConfiguration.environment,
            testStoreEnabled: firstConfiguration.testStoreEnabled
        )
        let rotated = PurchaseStorageScope(
            appIdentifier: "com.example.host-app",
            environment: rotatedConfiguration.environment,
            testStoreEnabled: rotatedConfiguration.testStoreEnabled
        )

        XCTAssertEqual(first, rotated)
        XCTAssertEqual(
            first.appAccountToken(distinctId: "customer"),
            rotated.appAccountToken(distinctId: "customer")
        )
    }

    func testRenewalUsesDurableAccountOwnerAfterCheckoutContextRetires() async {
        let mocks = MockFactory.shared
        mocks.identityService.setDistinctId("customer-b")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("purchase-owner-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = PurchaseStorageScope(
            appIdentifierHash: "app-a",
            environment: "production",
            storeEnvironment: .appStore
        )
        let token = scope.appAccountToken(distinctId: "customer-a")
        let ownershipStore = PurchaseAccountOwnershipStore(
            customStoragePath: root,
            scope: scope
        )
        XCTAssertTrue(ownershipStore.upsert(StoredPurchaseAccountOwnership(
            scope: scope,
            appAccountToken: token,
            distinctId: "customer-a",
            productAuthorities: ["store-product-1": .nativeStoreKit]
        )))
        let relaunchedOwnershipStore = PurchaseAccountOwnershipStore(
            customStoragePath: root,
            scope: scope
        )
        let settings = NuxieRuntimeSettings(
            configuration: NuxieConfiguration(apiKey: "rotated-key")
        )
        let service = TransactionService(
            productService: mocks.productService,
            transactionObserver: MockTransactionObserver(),
            pendingPurchaseStore: InMemoryPendingPurchaseStore(),
            accountOwnershipStore: relaunchedOwnershipStore,
            dateProvider: mocks.dateProvider,
            settings: settings,
            eventSink: RecoveryEventSink(),
            purchaseStorageScope: scope,
            identityService: mocks.identityService
        )
        let features = FeatureService(
            api: mocks.nuxieApi,
            identity: mocks.identityService,
            profile: mocks.profileService,
            dateProvider: mocks.dateProvider,
            featureInfo: FeatureInfo(),
            cacheTTL: 300
        )
        let api = RecoverySyncAPI(succeeds: true)
        let observer = TransactionObserver(
            api: api,
            features: features,
            identity: mocks.identityService,
            settings: settings,
            eventSink: RecoveryEventSink(),
            transactionServiceProvider: { service },
            evidenceStore: InMemoryTransactionEvidenceStore(),
            purchaseStorageScope: scope,
            dateProvider: mocks.dateProvider,
            activeStoreOriginalTransactionIDs: { [] }
        )
        let finishes = FinishCounter()
        let renewal = StoreTransactionEvidence(
            transactionJws: "renewal-jws",
            transactionId: "renewal-transaction",
            originalTransactionId: "original-transaction",
            productId: "store-product-1",
            finish: { await finishes.increment() }
        )

        let result = await observer.recoverCheckoutTransaction(
            evidence: renewal,
            appAccountToken: token,
            finishRequired: true
        )

        XCTAssertEqual(result, .recovered)
        XCTAssertEqual(api.recordedCustomers, ["customer-a"])
        let finishCount = await finishes.count()
        XCTAssertEqual(finishCount, 1)
    }

    func testProviderOwnershipOverridesPersistedNuxieTokenForRenewal() async {
        let mocks = MockFactory.shared
        mocks.identityService.setDistinctId("customer-a")
        let scope = PurchaseStorageScope(
            appIdentifierHash: "app-a",
            environment: "production",
            storeEnvironment: .appStore
        )
        let token = scope.appAccountToken(distinctId: "customer-a")
        let ownershipStore = InMemoryPurchaseAccountOwnershipStore()
        XCTAssertTrue(ownershipStore.upsert(StoredPurchaseAccountOwnership(
            scope: scope,
            appAccountToken: token,
            distinctId: "customer-a",
            productAuthorities: ["store-product-1": .providerConnector]
        )))
        let settings = NuxieRuntimeSettings(
            configuration: NuxieConfiguration(apiKey: "app-a")
        )
        settings.setPurchaseDelegate(MockPurchaseDelegate())
        let service = TransactionService(
            productService: mocks.productService,
            transactionObserver: MockTransactionObserver(),
            pendingPurchaseStore: InMemoryPendingPurchaseStore(),
            accountOwnershipStore: ownershipStore,
            dateProvider: mocks.dateProvider,
            settings: settings,
            eventSink: RecoveryEventSink(),
            purchaseStorageScope: scope,
            identityService: mocks.identityService
        )
        let features = FeatureService(
            api: mocks.nuxieApi,
            identity: mocks.identityService,
            profile: mocks.profileService,
            dateProvider: mocks.dateProvider,
            featureInfo: FeatureInfo(),
            cacheTTL: 300
        )
        let api = RecoverySyncAPI(succeeds: true)
        let evidenceStore = InMemoryTransactionEvidenceStore()
        let observer = TransactionObserver(
            api: api,
            features: features,
            identity: mocks.identityService,
            settings: settings,
            eventSink: RecoveryEventSink(),
            transactionServiceProvider: { service },
            evidenceStore: evidenceStore,
            purchaseStorageScope: scope,
            dateProvider: mocks.dateProvider,
            activeStoreOriginalTransactionIDs: { [] }
        )
        let finishes = FinishCounter()
        let renewal = StoreTransactionEvidence(
            transactionJws: "provider-renewal-jws",
            transactionId: "provider-renewal",
            originalTransactionId: "provider-original",
            productId: "store-product-1",
            finish: { await finishes.increment() }
        )

        let result = await observer.recoverCheckoutTransaction(
            evidence: renewal,
            appAccountToken: token,
            finishRequired: true
        )

        XCTAssertEqual(result, .noMatch)
        XCTAssertTrue(api.recordedCustomers.isEmpty)
        XCTAssertTrue(evidenceStore.load().valueTreatingAbsentAsEmpty([:])!.isEmpty)
        let finishCount = await finishes.count()
        XCTAssertEqual(finishCount, 0)
    }

    func testExternalBillingIgnoresVerifiedUpdatesForEveryAccountTokenMatch() async {
        let mocks = MockFactory.shared
        let identity = MockIdentityService()
        identity.setDistinctId("customer-b")
        let scope = PurchaseStorageScope(
            appIdentifierHash: "app-a",
            environment: "production",
            storeEnvironment: .appStore
        )
        let customerAToken = scope.appAccountToken(distinctId: "customer-a")
        let customerBToken = scope.appAccountToken(distinctId: "customer-b")
        let pendingStore = InMemoryPendingPurchaseStore()
        let pending = PendingPurchaseRecord(
            scope: scope,
            distinctId: "customer-b",
            appAccountToken: customerBToken,
            commercialContext: commercialContext(),
            recordedAt: mocks.dateProvider.now(),
            localEntitlementGrants: [],
            state: .pending,
            evidenceAuthority: .nativeStoreKit
        )
        XCTAssertTrue(pendingStore.save([
            "customer-b::store-product-1": pending,
        ]))
        let ownershipStore = InMemoryPurchaseAccountOwnershipStore()
        XCTAssertTrue(ownershipStore.upsert(StoredPurchaseAccountOwnership(
            scope: scope,
            appAccountToken: customerAToken,
            distinctId: "customer-a",
            productAuthorities: ["store-product-1": .nativeStoreKit]
        )))
        XCTAssertTrue(ownershipStore.upsert(StoredPurchaseAccountOwnership(
            scope: scope,
            appAccountToken: customerBToken,
            distinctId: "customer-b",
            productAuthorities: ["store-product-1": .nativeStoreKit]
        )))
        let settings = NuxieRuntimeSettings(
            configuration: NuxieConfiguration(apiKey: "app-a")
        )
        settings.setPurchaseDelegate(MockPurchaseDelegate())
        let events = RecoveryEventSink()
        let features = RecoveryFeatureRecorder()
        let service = TransactionService(
            productService: mocks.productService,
            transactionObserver: MockTransactionObserver(),
            pendingPurchaseStore: pendingStore,
            accountOwnershipStore: ownershipStore,
            dateProvider: mocks.dateProvider,
            settings: settings,
            eventSink: events,
            purchaseStorageScope: scope,
            identityService: identity,
            featureService: features,
            activeProductEvidenceAuthority: { _ in .providerConnector }
        )
        let api = RecoverySyncAPI(succeeds: true)
        let evidenceStore = InMemoryTransactionEvidenceStore()
        let observer = TransactionObserver(
            api: api,
            features: features,
            identity: identity,
            settings: settings,
            eventSink: events,
            transactionServiceProvider: { service },
            evidenceStore: evidenceStore,
            purchaseStorageScope: scope,
            dateProvider: mocks.dateProvider,
            activeStoreOriginalTransactionIDs: { [] }
        )
        let finishes = FinishCounter()
        let accountTokens: [UUID?] = [
            nil,
            UUID(),
            customerAToken,
            customerBToken,
        ]

        for (index, appAccountToken) in accountTokens.enumerated() {
            await observer.handleVerifiedTransaction(
                VerifiedStoreTransactionUpdate(
                    transactionId: "external-owned-update-\(index)",
                    originalTransactionId: "external-owned-original-\(index)",
                    productId: "store-product-1",
                    appAccountToken: appAccountToken,
                    isRevoked: false,
                    isUpgraded: false,
                    finish: { await finishes.increment() }
                ),
                jwsRepresentation: "external-owned-jws-\(index)",
                source: .transactionStream
            )
        }

        XCTAssertTrue(api.recordedCustomers.isEmpty)
        XCTAssertTrue(events.events.isEmpty)
        XCTAssertTrue(
            evidenceStore.load().valueTreatingAbsentAsEmpty([:])!.isEmpty
        )
        let finishCount = await finishes.count()
        XCTAssertEqual(finishCount, 0)
        let retainedPending = await service.pendingPurchaseRecord(
            productId: "store-product-1",
            distinctId: "customer-b"
        )
        XCTAssertEqual(retainedPending, pending)
    }

    func testNoCacheOfflineStartupRecoversOnceAfterProductAuthorityAdmission() async {
        let mocks = MockFactory.shared
        let identity = MockIdentityService()
        identity.setDistinctId("customer-a")
        let dateProvider = MockDateProvider()
        let scope = PurchaseStorageScope(
            appIdentifierHash: "app-a",
            environment: "production",
            storeEnvironment: .appStore
        )
        let settings = NuxieRuntimeSettings(
            configuration: NuxieConfiguration(apiKey: "app-a")
        )
        settings.setPurchaseDelegate(MockPurchaseDelegate())

        let providerAuthority = SuspendedProductAuthority()
        let providerSource = RecoveryTransactionSourceProbe()
        let providerFinishes = FinishCounter()
        await providerSource.setUnfinished([StoreTransactionRecoveryItem(
            update: VerifiedStoreTransactionUpdate(
                transactionId: "provider-cold-unfinished",
                originalTransactionId: "provider-cold-original",
                productId: "store-product-1",
                appAccountToken: nil,
                isRevoked: false,
                isUpgraded: false,
                finish: { await providerFinishes.increment() }
            ),
            jwsRepresentation: "provider-cold-jws"
        )])
        let providerAPI = RecoverySyncAPI(succeeds: true)
        let providerFeatures = RecoveryFeatureRecorder()
        let providerService = TransactionService(
            productService: mocks.productService,
            transactionObserver: MockTransactionObserver(),
            pendingPurchaseStore: InMemoryPendingPurchaseStore(),
            accountOwnershipStore: InMemoryPurchaseAccountOwnershipStore(),
            dateProvider: dateProvider,
            settings: settings,
            eventSink: RecoveryEventSink(),
            purchaseStorageScope: scope,
            identityService: identity,
            featureService: providerFeatures,
            activeProductEvidenceAuthority: { productId in
                await providerAuthority.resolve(productId)
            }
        )
        let providerObserver = TransactionObserver(
            api: providerAPI,
            features: providerFeatures,
            identity: identity,
            settings: settings,
            eventSink: RecoveryEventSink(),
            transactionServiceProvider: { providerService },
            evidenceStore: InMemoryTransactionEvidenceStore(),
            purchaseStorageScope: scope,
            dateProvider: dateProvider,
            activeStoreOriginalTransactionIDs: { [] },
            unfinishedRecoveryTransactions: {
                await providerSource.unfinishedItems()
            },
            currentEntitlementRecoveryTransactions: {
                await providerSource.currentEntitlementItems()
            }
        )

        await providerObserver.retryStoredEvidence()
        XCTAssertTrue(providerAPI.recordedCustomers.isEmpty)
        let providerFinishBeforeReady = await providerFinishes.count()
        XCTAssertEqual(providerFinishBeforeReady, 0)

        let providerFeatureSyncs = AsyncCallCounter()
        await NuxieSDK.runProfilePrefetch(
            refetch: {
                throw NuxieNetworkError.invalidResponse
            },
            recoverProfileDependentState: {},
            syncFeatures: { await providerFeatureSyncs.increment() }
        )
        let providerReadsWhileOffline = await providerSource.readCounts()
        XCTAssertEqual(providerReadsWhileOffline.unfinished, 1)
        XCTAssertEqual(providerReadsWhileOffline.currentEntitlements, 0)
        let providerAdmission = ExperienceLoader(
            productService: mocks.productService,
            releaseStore: UnusedProductAuthorityReleaseStore()
        )
        await providerAdmission.setProductAuthorityChangeHandler {
            await providerObserver.retryAfterProfileReady()
        }
        await providerAuthority.set(.providerConnector)
        _ = try? await providerAdmission.replaceReleaseProfile(nil)
        XCTAssertTrue(providerAPI.recordedCustomers.isEmpty)
        let providerFinishAfterReady = await providerFinishes.count()
        XCTAssertEqual(providerFinishAfterReady, 0)
        let providerReads = await providerSource.readCounts()
        XCTAssertEqual(providerReads.unfinished, 2)
        XCTAssertEqual(providerReads.currentEntitlements, 1)
        let providerFeatureSyncCount = await providerFeatureSyncs.count()
        XCTAssertEqual(providerFeatureSyncCount, 0)
        _ = try? await providerAdmission.replaceReleaseProfile(nil)
        let providerReadsAfterRepeatedAdmission = await providerSource.readCounts()
        XCTAssertEqual(providerReadsAfterRepeatedAdmission.unfinished, 2)
        XCTAssertEqual(providerReadsAfterRepeatedAdmission.currentEntitlements, 1)

        let nativeAuthority = SuspendedProductAuthority()
        let nativeSource = RecoveryTransactionSourceProbe()
        let nativeFinishes = FinishCounter()
        let nativeRecoveryItem = StoreTransactionRecoveryItem(
            update: VerifiedStoreTransactionUpdate(
                transactionId: "native-cold-entitlement",
                originalTransactionId: "native-cold-original",
                productId: "store-product-1",
                appAccountToken: scope.appAccountToken(distinctId: "customer-a"),
                isRevoked: false,
                isUpgraded: false,
                finish: { await nativeFinishes.increment() }
            ),
            jwsRepresentation: "native-cold-jws"
        )
        // StoreKit may expose the same active subscription through both the
        // unfinished queue and current entitlements during one ready pass.
        await nativeSource.setUnfinished([nativeRecoveryItem])
        await nativeSource.setCurrentEntitlements([nativeRecoveryItem])
        let nativeAPI = RecoverySyncAPI(succeeds: true)
        let nativeFeatures = RecoveryFeatureRecorder()
        let nativeSettings = NuxieRuntimeSettings(
            configuration: NuxieConfiguration(apiKey: "app-a")
        )
        let nativeService = TransactionService(
            productService: mocks.productService,
            transactionObserver: MockTransactionObserver(),
            pendingPurchaseStore: InMemoryPendingPurchaseStore(),
            accountOwnershipStore: InMemoryPurchaseAccountOwnershipStore(),
            dateProvider: dateProvider,
            settings: nativeSettings,
            eventSink: RecoveryEventSink(),
            purchaseStorageScope: scope,
            identityService: identity,
            featureService: nativeFeatures,
            activeProductEvidenceAuthority: { productId in
                await nativeAuthority.resolve(productId)
            }
        )
        let nativeObserver = TransactionObserver(
            api: nativeAPI,
            features: nativeFeatures,
            identity: identity,
            settings: nativeSettings,
            eventSink: RecoveryEventSink(),
            transactionServiceProvider: { nativeService },
            evidenceStore: InMemoryTransactionEvidenceStore(),
            purchaseStorageScope: scope,
            dateProvider: dateProvider,
            activeStoreOriginalTransactionIDs: { [] },
            unfinishedRecoveryTransactions: {
                await nativeSource.unfinishedItems()
            },
            currentEntitlementRecoveryTransactions: {
                await nativeSource.currentEntitlementItems()
            }
        )

        await nativeObserver.retryStoredEvidence()
        XCTAssertTrue(nativeAPI.recordedCustomers.isEmpty)
        let nativeFinishBeforeReady = await nativeFinishes.count()
        XCTAssertEqual(nativeFinishBeforeReady, 0)

        let nativeFeatureSyncs = AsyncCallCounter()
        await NuxieSDK.runProfilePrefetch(
            refetch: {
                throw NuxieNetworkError.invalidResponse
            },
            recoverProfileDependentState: {},
            syncFeatures: { await nativeFeatureSyncs.increment() }
        )
        let nativeReadsWhileOffline = await nativeSource.readCounts()
        XCTAssertEqual(nativeReadsWhileOffline.unfinished, 1)
        XCTAssertEqual(nativeReadsWhileOffline.currentEntitlements, 0)
        let nativeAdmission = ExperienceLoader(
            productService: mocks.productService,
            releaseStore: UnusedProductAuthorityReleaseStore()
        )
        await nativeAdmission.setProductAuthorityChangeHandler {
            await nativeObserver.retryAfterProfileReady()
        }
        await nativeAuthority.set(.readyNoMatch)
        _ = try? await nativeAdmission.replaceReleaseProfile(nil)
        XCTAssertEqual(nativeAPI.recordedCustomers, ["customer-a"])
        let nativeFinishAfterReady = await nativeFinishes.count()
        XCTAssertEqual(nativeFinishAfterReady, 1)
        let nativeReads = await nativeSource.readCounts()
        XCTAssertEqual(nativeReads.unfinished, 2)
        XCTAssertEqual(nativeReads.currentEntitlements, 1)
        let nativeFeatureSyncCount = await nativeFeatureSyncs.count()
        XCTAssertEqual(nativeFeatureSyncCount, 0)
        _ = try? await nativeAdmission.replaceReleaseProfile(nil)
        let nativeReadsAfterRepeatedAdmission = await nativeSource.readCounts()
        XCTAssertEqual(nativeReadsAfterRepeatedAdmission.unfinished, 2)
        XCTAssertEqual(nativeReadsAfterRepeatedAdmission.currentEntitlements, 1)
    }

    func testProviderStartupEvidenceRemainsConnectorOwnedWithoutCheckoutHistory() async {
        let mocks = MockFactory.shared
        let identity = MockIdentityService()
        identity.setDistinctId("customer-a")
        let dateProvider = MockDateProvider()
        let scope = PurchaseStorageScope(
            appIdentifierHash: "app-a",
            environment: "production",
            storeEnvironment: .appStore
        )
        let settings = NuxieRuntimeSettings(
            configuration: NuxieConfiguration(apiKey: "app-a")
        )
        settings.setPurchaseDelegate(MockPurchaseDelegate())
        let eventSink = RecoveryEventSink()
        let features = RecoveryFeatureRecorder()
        let pendingStore = InMemoryPendingPurchaseStore()
        let service = TransactionService(
            productService: mocks.productService,
            transactionObserver: MockTransactionObserver(),
            pendingPurchaseStore: pendingStore,
            accountOwnershipStore: InMemoryPurchaseAccountOwnershipStore(),
            dateProvider: dateProvider,
            settings: settings,
            eventSink: eventSink,
            purchaseStorageScope: scope,
            identityService: identity,
            featureService: features,
            activeProductEvidenceAuthority: { productId in
                productId == "store-product-1" ? .providerConnector : .readyNoMatch
            }
        )
        let api = RecoverySyncAPI(succeeds: true)
        let evidenceStore = InMemoryTransactionEvidenceStore()
        let observer = TransactionObserver(
            api: api,
            features: features,
            identity: identity,
            settings: settings,
            eventSink: eventSink,
            transactionServiceProvider: { service },
            evidenceStore: evidenceStore,
            purchaseStorageScope: scope,
            dateProvider: dateProvider,
            activeStoreOriginalTransactionIDs: { [] }
        )
        let finishes = FinishCounter()
        await observer.handleVerifiedTransaction(
            VerifiedStoreTransactionUpdate(
                transactionId: "provider-restored-transaction",
                originalTransactionId: "provider-restored-original",
                productId: "store-product-1",
                appAccountToken: nil,
                isRevoked: false,
                isUpgraded: false,
                finish: { await finishes.increment() }
            ),
            jwsRepresentation: "provider-restored-jws",
            source: .startupRecovery,
            attributedDistinctId: "customer-a",
            resolvesPendingPurchase: false,
            allowsDurableCheckoutAuthority: false
        )

        XCTAssertTrue(api.recordedCustomers.isEmpty)
        let finishCount = await finishes.count()
        XCTAssertEqual(finishCount, 0)
        XCTAssertTrue(eventSink.events.isEmpty)
        XCTAssertTrue(evidenceStore.load().valueTreatingAbsentAsEmpty([:])!.isEmpty)

        let token = scope.appAccountToken(distinctId: "customer-a")
        XCTAssertTrue(pendingStore.save(["customer-a::store-product-1":
            PendingPurchaseRecord(
                scope: scope,
                distinctId: "customer-a",
                appAccountToken: token,
                commercialContext: commercialContext(),
                recordedAt: dateProvider.now(),
                localEntitlementGrants: [],
                state: .checkout,
                evidenceAuthority: .nativeStoreKit
            )
        ]))
        await observer.handleVerifiedTransaction(
            VerifiedStoreTransactionUpdate(
                transactionId: "provider-restored-with-stale-native-checkout",
                originalTransactionId: "provider-restored-stale-original",
                productId: "store-product-1",
                appAccountToken: token,
                isRevoked: false,
                isUpgraded: false,
                finish: { await finishes.increment() }
            ),
            jwsRepresentation: "provider-restored-stale-jws",
            source: .startupRecovery,
            attributedDistinctId: "customer-a",
            resolvesPendingPurchase: false,
            allowsDurableCheckoutAuthority: false
        )
        XCTAssertTrue(api.recordedCustomers.isEmpty)
        let retainedFinishCount = await finishes.count()
        XCTAssertEqual(retainedFinishCount, 0)
        XCTAssertTrue(evidenceStore.load().valueTreatingAbsentAsEmpty([:])!.isEmpty)
    }

    func testReinstallRecognizesNuxieTokenWithoutAttributingHostToken() async {
        let mocks = MockFactory.shared
        mocks.identityService.setDistinctId("customer-a")
        let scope = PurchaseStorageScope(
            appIdentifierHash: "app-a",
            environment: "production",
            storeEnvironment: .appStore
        )
        let settings = NuxieRuntimeSettings(
            configuration: NuxieConfiguration(apiKey: "rotated-key")
        )
        let service = TransactionService(
            productService: mocks.productService,
            transactionObserver: MockTransactionObserver(),
            pendingPurchaseStore: InMemoryPendingPurchaseStore(),
            accountOwnershipStore: InMemoryPurchaseAccountOwnershipStore(),
            dateProvider: mocks.dateProvider,
            settings: settings,
            eventSink: RecoveryEventSink(),
            purchaseStorageScope: scope,
            identityService: mocks.identityService
        )
        let features = FeatureService(
            api: mocks.nuxieApi,
            identity: mocks.identityService,
            profile: mocks.profileService,
            dateProvider: mocks.dateProvider,
            featureInfo: FeatureInfo(),
            cacheTTL: 300
        )
        let api = RecoverySyncAPI(succeeds: true)
        let observer = TransactionObserver(
            api: api,
            features: features,
            identity: mocks.identityService,
            settings: settings,
            eventSink: RecoveryEventSink(),
            transactionServiceProvider: { service },
            evidenceStore: InMemoryTransactionEvidenceStore(),
            purchaseStorageScope: scope,
            dateProvider: mocks.dateProvider,
            activeStoreOriginalTransactionIDs: { [] }
        )
        let nuxieFinishes = FinishCounter()
        let hostFinishes = FinishCounter()
        let nuxieEvidence = StoreTransactionEvidence(
            transactionJws: "reinstall-jws",
            transactionId: "reinstall-transaction",
            originalTransactionId: "reinstall-original",
            productId: "store-product-1",
            finish: { await nuxieFinishes.increment() }
        )
        let hostEvidence = StoreTransactionEvidence(
            transactionJws: "host-jws",
            transactionId: "host-transaction",
            originalTransactionId: "host-original",
            productId: "host-product",
            finish: { await hostFinishes.increment() }
        )

        let restored = await observer.recoverCheckoutTransaction(
            evidence: nuxieEvidence,
            appAccountToken: scope.appAccountToken(distinctId: "customer-a"),
            finishRequired: true,
            attributedDistinctId: "customer-a"
        )
        let hostOwned = await observer.recoverCheckoutTransaction(
            evidence: hostEvidence,
            appAccountToken: UUID(),
            finishRequired: true,
            attributedDistinctId: "customer-a"
        )

        XCTAssertEqual(restored, .recovered)
        XCTAssertEqual(hostOwned, .noMatch)
        XCTAssertEqual(api.recordedCustomers, ["customer-a"])
        let nuxieFinishCount = await nuxieFinishes.count()
        let hostFinishCount = await hostFinishes.count()
        XCTAssertEqual(nuxieFinishCount, 1)
        XCTAssertEqual(hostFinishCount, 0)
    }

    func testFailedDurableMarkerConsumptionReturnsFalse() async {
        let mocks = MockFactory.shared
        mocks.identityService.setDistinctId("customer")
        let scope = PurchaseStorageScope(
            appIdentifierHash: "app-a",
            environment: "production",
            storeEnvironment: .appStore
        )
        let record = PendingPurchaseRecord(
            scope: scope,
            distinctId: "customer",
            appAccountToken: scope.appAccountToken(distinctId: "customer"),
            commercialContext: commercialContext(),
            recordedAt: mocks.dateProvider.now(),
            localEntitlementGrants: [],
            state: .pending
        )
        let store = FailingPendingPurchaseStore(
            entries: ["customer::store-product-1": record]
        )
        let settings = NuxieRuntimeSettings(
            configuration: NuxieConfiguration(apiKey: "rotated-key")
        )
        let service = TransactionService(
            productService: mocks.productService,
            transactionObserver: MockTransactionObserver(),
            pendingPurchaseStore: store,
            dateProvider: mocks.dateProvider,
            settings: settings,
            eventSink: RecoveryEventSink(),
            purchaseStorageScope: scope,
            identityService: mocks.identityService
        )

        let consumed = await service.consumePendingPurchase(
            productId: "store-product-1",
            distinctId: "customer"
        )

        XCTAssertFalse(consumed)
        XCTAssertEqual(store.load().valueTreatingAbsentAsEmpty([:])!["customer::store-product-1"], record)
    }

    func testDurablePurchaseArtifactsCannotCrossRuntimeScopes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("purchase-scope-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let live = PurchaseStorageScope(
            appIdentifierHash: "app-a",
            environment: "production",
            storeEnvironment: .appStore
        )
        let test = PurchaseStorageScope(
            appIdentifierHash: "app-a",
            environment: "development",
            storeEnvironment: .testStore
        )
        let liveStore = TransactionEvidenceStore(
            customStoragePath: root,
            scope: live
        )
        let testStore = TransactionEvidenceStore(
            customStoragePath: root,
            scope: test
        )
        let evidence = StoredTransactionEvidence(
            scope: live,
            transactionJws: "live-jws",
            transactionId: "transaction",
            originalTransactionId: "original",
            productId: "product",
            distinctId: "customer",
            recordedAt: Date(timeIntervalSince1970: 10),
            isRevoked: false
        )

        XCTAssertTrue(liveStore.save([evidence.transactionId: evidence]))
        XCTAssertEqual(liveStore.load().valueTreatingAbsentAsEmpty([:])![evidence.transactionId], evidence)
        XCTAssertTrue(testStore.load().valueTreatingAbsentAsEmpty([:])!.isEmpty)

        let liveRecovery = PendingPurchaseStore(
            customStoragePath: root,
            scope: live
        )
        let testRecovery = PendingPurchaseStore(
            customStoragePath: root,
            scope: test
        )
        let recovery = PendingPurchaseRecord(
            scope: live,
            distinctId: "customer",
            appAccountToken: live.appAccountToken(distinctId: "customer"),
            commercialContext: commercialContext(),
            recordedAt: Date(timeIntervalSince1970: 10),
            localEntitlementGrants: [],
            state: .checkout
        )
        XCTAssertTrue(liveRecovery.save(["recovery": recovery]))
        XCTAssertNotNil(liveRecovery.load().valueTreatingAbsentAsEmpty([:])!["recovery"])
        XCTAssertTrue(testRecovery.load().valueTreatingAbsentAsEmpty([:])!.isEmpty)

        let liveOwnership = PurchaseAccountOwnershipStore(
            customStoragePath: root,
            scope: live
        )
        let testOwnership = PurchaseAccountOwnershipStore(
            customStoragePath: root,
            scope: test
        )
        let token = live.appAccountToken(distinctId: "customer")
        XCTAssertTrue(liveOwnership.upsert(StoredPurchaseAccountOwnership(
            scope: live,
            appAccountToken: token,
            distinctId: "customer"
        )))
        XCTAssertEqual(
            liveOwnership.owner(for: token, scope: live),
            "customer"
        )
        XCTAssertNil(testOwnership.owner(for: token, scope: test))
    }

    func testRelaunchRecoversExactCheckoutOnceForOriginalCustomer() async {
        let mocks = MockFactory.shared
        mocks.identityService.setDistinctId("customer-b")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("purchase-relaunch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = PurchaseStorageScope(
            appIdentifierHash: "app-a",
            environment: "production",
            storeEnvironment: .appStore
        )
        let token = scope.appAccountToken(distinctId: "customer-a")
        let recoveryStore = PendingPurchaseStore(
            customStoragePath: root,
            scope: scope
        )
        let recovery = PendingPurchaseRecord(
            scope: scope,
            distinctId: "customer-a",
            appAccountToken: token,
            commercialContext: commercialContext(),
            recordedAt: mocks.dateProvider.now(),
            localEntitlementGrants: [
                StoredLocalEntitlementGrant(
                    featureId: "premium",
                    featureExternalId: nil,
                    allowanceType: "boolean",
                    allowance: nil
                )
            ],
            state: .checkout,
            evidenceAuthority: .nativeStoreKit
        )
        XCTAssertTrue(recoveryStore.save(["customer-a::store-product-1": recovery]))

        let evidenceStore = InMemoryTransactionEvidenceStore()
        let features = FeatureService(
            api: mocks.nuxieApi,
            identity: mocks.identityService,
            profile: mocks.profileService,
            dateProvider: mocks.dateProvider,
            featureInfo: FeatureInfo(),
            cacheTTL: 300,
        )
        let settings = NuxieRuntimeSettings(
            configuration: NuxieConfiguration(apiKey: "app-a")
        )
        let service = TransactionService(
            productService: mocks.productService,
            transactionObserver: MockTransactionObserver(),
            pendingPurchaseStore: recoveryStore,
            dateProvider: mocks.dateProvider,
            settings: settings,
            eventSink: RecoveryEventSink(),
            purchaseStorageScope: scope,
            identityService: mocks.identityService,
            featureService: features
        )
        let api = RecoverySyncAPI(succeeds: false)
        let observer = TransactionObserver(
            api: api,
            features: features,
            identity: mocks.identityService,
            settings: settings,
            eventSink: RecoveryEventSink(),
            transactionServiceProvider: { service },
            evidenceStore: evidenceStore,
            purchaseStorageScope: scope,
            dateProvider: mocks.dateProvider,
            activeStoreOriginalTransactionIDs: { ["original-1"] }
        )
        let finishes = FinishCounter()
        let evidence = StoreTransactionEvidence(
            transactionJws: "signed-jws",
            transactionId: "transaction-1",
            originalTransactionId: "original-1",
            productId: "store-product-1",
            finish: { await finishes.increment() }
        )

        let first = await observer.recoverCheckoutTransaction(
            evidence: evidence,
            appAccountToken: token,
            finishRequired: true
        )
        let duplicate = await observer.recoverCheckoutTransaction(
            evidence: evidence,
            appAccountToken: token,
            finishRequired: true
        )

        XCTAssertEqual(first, .recovered)
        XCTAssertEqual(duplicate, .recovered)
        let finishCount = await finishes.count()
        XCTAssertEqual(finishCount, 1)
        XCTAssertEqual(api.recordedCustomers, ["customer-a"])
        XCTAssertTrue(
            recoveryStore.load().valueTreatingAbsentAsEmpty([:])!.isEmpty
        )
        XCTAssertEqual(
            evidenceStore.load().valueTreatingAbsentAsEmpty([:])![evidence.transactionId]?.commercialContext,
            commercialContext()
        )
        let activeCustomerAccess = await features.getCached(
            featureId: "premium",
            entityId: nil
        )
        XCTAssertNotEqual(activeCustomerAccess?.allowed, true)
    }

    func testRelaunchDoesNotFinishWhenRecoveryDeletionFails() async {
        let mocks = MockFactory.shared
        mocks.identityService.setDistinctId("customer-a")
        let scope = PurchaseStorageScope(
            appIdentifierHash: "app-a",
            environment: "production",
            storeEnvironment: .appStore
        )
        let token = scope.appAccountToken(distinctId: "customer-a")
        let recoveryStore = RecoveryDeletionFailureStore()
        let recovery = PendingPurchaseRecord(
            scope: scope,
            distinctId: "customer-a",
            appAccountToken: token,
            commercialContext: commercialContext(),
            recordedAt: mocks.dateProvider.now(),
            localEntitlementGrants: [],
            state: .checkout
        )
        XCTAssertTrue(recoveryStore.save([
            "customer-a::store-product-1": recovery,
        ]))
        let settings = NuxieRuntimeSettings(
            configuration: NuxieConfiguration(apiKey: "rotated-key")
        )
        let service = TransactionService(
            productService: mocks.productService,
            transactionObserver: MockTransactionObserver(),
            pendingPurchaseStore: recoveryStore,
            dateProvider: mocks.dateProvider,
            settings: settings,
            eventSink: RecoveryEventSink(),
            purchaseStorageScope: scope,
            identityService: mocks.identityService
        )
        let features = FeatureService(
            api: mocks.nuxieApi,
            identity: mocks.identityService,
            profile: mocks.profileService,
            dateProvider: mocks.dateProvider,
            featureInfo: FeatureInfo(),
            cacheTTL: 300
        )
        let observer = TransactionObserver(
            api: RecoverySyncAPI(succeeds: true),
            features: features,
            identity: mocks.identityService,
            settings: settings,
            eventSink: RecoveryEventSink(),
            transactionServiceProvider: { service },
            evidenceStore: InMemoryTransactionEvidenceStore(),
            purchaseStorageScope: scope,
            dateProvider: mocks.dateProvider,
            activeStoreOriginalTransactionIDs: { [] }
        )
        let finishes = FinishCounter()
        let evidence = StoreTransactionEvidence(
            transactionJws: "signed-jws",
            transactionId: "transaction-delete-failure",
            originalTransactionId: "original-delete-failure",
            productId: "store-product-1",
            finish: { await finishes.increment() }
        )

        let result = await observer.recoverCheckoutTransaction(
            evidence: evidence,
            appAccountToken: token,
            finishRequired: true
        )

        XCTAssertEqual(result, .recovered)
        let finishCount = await finishes.count()
        XCTAssertEqual(finishCount, 0)
        XCTAssertEqual(
            recoveryStore.load().valueTreatingAbsentAsEmpty([:])!["customer-a::store-product-1"],
            recovery
        )
    }

    func testStoredEvidenceRecoveryRetiresCheckoutBeforeFinishing() async {
        let mocks = MockFactory.shared
        mocks.identityService.setDistinctId("customer-a")
        let scope = PurchaseStorageScope(
            appIdentifierHash: "app-a",
            environment: "production",
            storeEnvironment: .appStore
        )
        let token = scope.appAccountToken(distinctId: "customer-a")
        let store = InMemoryPendingPurchaseStore()
        let recovery = PendingPurchaseRecord(
            scope: scope,
            distinctId: "customer-a",
            appAccountToken: token,
            commercialContext: commercialContext(),
            recordedAt: mocks.dateProvider.now(),
            localEntitlementGrants: [],
            state: .checkout
        )
        XCTAssertTrue(store.save(["customer-a::store-product-1": recovery]))
        let settings = NuxieRuntimeSettings(
            configuration: NuxieConfiguration(apiKey: "rotated-key")
        )
        let service = TransactionService(
            productService: mocks.productService,
            transactionObserver: MockTransactionObserver(),
            pendingPurchaseStore: store,
            dateProvider: mocks.dateProvider,
            settings: settings,
            eventSink: RecoveryEventSink(),
            purchaseStorageScope: scope,
            identityService: mocks.identityService
        )
        let features = FeatureService(
            api: mocks.nuxieApi,
            identity: mocks.identityService,
            profile: mocks.profileService,
            dateProvider: mocks.dateProvider,
            featureInfo: FeatureInfo(),
            cacheTTL: 300
        )
        let observer = TransactionObserver(
            api: RecoverySyncAPI(succeeds: true),
            features: features,
            identity: mocks.identityService,
            settings: settings,
            eventSink: RecoveryEventSink(),
            transactionServiceProvider: { service },
            evidenceStore: InMemoryTransactionEvidenceStore(),
            purchaseStorageScope: scope,
            dateProvider: mocks.dateProvider,
            activeStoreOriginalTransactionIDs: { [] }
        )
        let finishes = FinishCounter()

        let didFinish = await observer.finishRecoveredTransaction(
            appAccountToken: token,
            productId: "store-product-1",
            checkoutRecoveryExists: true,
            finish: { await finishes.increment() }
        )

        XCTAssertTrue(didFinish)
        XCTAssertTrue(store.load().valueTreatingAbsentAsEmpty([:])!.isEmpty)
        let finishCount = await finishes.count()
        XCTAssertEqual(finishCount, 1)
    }

    func testStoredEvidenceRecoveryDoesNotFinishWhenRecoveryDeletionFails() async {
        let mocks = MockFactory.shared
        mocks.identityService.setDistinctId("customer-a")
        let scope = PurchaseStorageScope(
            appIdentifierHash: "app-a",
            environment: "production",
            storeEnvironment: .appStore
        )
        let token = scope.appAccountToken(distinctId: "customer-a")
        let store = RecoveryDeletionFailureStore()
        let recovery = PendingPurchaseRecord(
            scope: scope,
            distinctId: "customer-a",
            appAccountToken: token,
            commercialContext: commercialContext(),
            recordedAt: mocks.dateProvider.now(),
            localEntitlementGrants: [],
            state: .checkout
        )
        XCTAssertTrue(store.save(["customer-a::store-product-1": recovery]))
        let settings = NuxieRuntimeSettings(
            configuration: NuxieConfiguration(apiKey: "rotated-key")
        )
        let service = TransactionService(
            productService: mocks.productService,
            transactionObserver: MockTransactionObserver(),
            pendingPurchaseStore: store,
            dateProvider: mocks.dateProvider,
            settings: settings,
            eventSink: RecoveryEventSink(),
            purchaseStorageScope: scope,
            identityService: mocks.identityService
        )
        let features = FeatureService(
            api: mocks.nuxieApi,
            identity: mocks.identityService,
            profile: mocks.profileService,
            dateProvider: mocks.dateProvider,
            featureInfo: FeatureInfo(),
            cacheTTL: 300
        )
        let observer = TransactionObserver(
            api: RecoverySyncAPI(succeeds: true),
            features: features,
            identity: mocks.identityService,
            settings: settings,
            eventSink: RecoveryEventSink(),
            transactionServiceProvider: { service },
            evidenceStore: InMemoryTransactionEvidenceStore(),
            purchaseStorageScope: scope,
            dateProvider: mocks.dateProvider,
            activeStoreOriginalTransactionIDs: { [] }
        )
        let finishes = FinishCounter()

        let didFinish = await observer.finishRecoveredTransaction(
            appAccountToken: token,
            productId: "store-product-1",
            checkoutRecoveryExists: true,
            finish: { await finishes.increment() }
        )

        XCTAssertFalse(didFinish)
        XCTAssertEqual(store.load().valueTreatingAbsentAsEmpty([:])!["customer-a::store-product-1"], recovery)
        let finishCount = await finishes.count()
        XCTAssertEqual(finishCount, 0)
    }

    func testStoredEvidenceRecoveryFinishesAndCompletesBeforeBackendRetry() async {
        let mocks = MockFactory.shared
        mocks.identityService.setDistinctId("customer-a")
        let scope = PurchaseStorageScope(
            appIdentifierHash: "app-a",
            environment: "production",
            storeEnvironment: .appStore
        )
        let token = scope.appAccountToken(distinctId: "customer-a")
        let recoveryStore = InMemoryPendingPurchaseStore()
        let recovery = PendingPurchaseRecord(
            scope: scope,
            distinctId: "customer-a",
            appAccountToken: token,
            commercialContext: commercialContext(),
            recordedAt: mocks.dateProvider.now(),
            localEntitlementGrants: [],
            state: .checkout
        )
        XCTAssertTrue(recoveryStore.save(["customer-a::store-product-1": recovery]))
        let settings = NuxieRuntimeSettings(
            configuration: NuxieConfiguration(apiKey: "rotated-key")
        )
        let service = TransactionService(
            productService: mocks.productService,
            transactionObserver: MockTransactionObserver(),
            pendingPurchaseStore: recoveryStore,
            dateProvider: mocks.dateProvider,
            settings: settings,
            eventSink: RecoveryEventSink(),
            purchaseStorageScope: scope,
            identityService: mocks.identityService
        )
        let evidenceStore = InMemoryTransactionEvidenceStore()
        let evidence = StoredTransactionEvidence(
            scope: scope,
            transactionJws: "signed-jws",
            transactionId: "post-evidence-crash",
            originalTransactionId: "original-1",
            productId: "store-product-1",
            distinctId: "customer-a",
            recordedAt: mocks.dateProvider.now(),
            isRevoked: false,
            finishRequired: true,
            commercialContext: commercialContext()
        )
        XCTAssertTrue(evidenceStore.save([evidence.transactionId: evidence]))
        let api = RecoverySyncAPI(succeeds: false)
        let eventSink = RecoveryEventSink()
        let features = FeatureService(
            api: mocks.nuxieApi,
            identity: mocks.identityService,
            profile: mocks.profileService,
            dateProvider: mocks.dateProvider,
            featureInfo: FeatureInfo(),
            cacheTTL: 300
        )
        let observer = TransactionObserver(
            api: api,
            features: features,
            identity: mocks.identityService,
            settings: settings,
            eventSink: eventSink,
            transactionServiceProvider: { service },
            evidenceStore: evidenceStore,
            purchaseStorageScope: scope,
            dateProvider: mocks.dateProvider,
            activeStoreOriginalTransactionIDs: { [] }
        )
        let finishes = FinishCounter()

        let first = await observer.completeStoredTransactionRecovery(
            evidence,
            appAccountToken: token,
            checkoutRecoveryExists: true,
            finish: { await finishes.increment() }
        )
        let duplicate = await observer.completeStoredTransactionRecovery(
            evidence,
            appAccountToken: token,
            checkoutRecoveryExists: false,
            finish: {}
        )

        XCTAssertTrue(first)
        XCTAssertTrue(duplicate)
        let finishCount = await finishes.count()
        XCTAssertEqual(finishCount, 1)
        XCTAssertTrue(recoveryStore.load().valueTreatingAbsentAsEmpty([:])!.isEmpty)
        XCTAssertEqual(
            evidenceStore.load().valueTreatingAbsentAsEmpty([:])![
                evidence.transactionId
            ]?.finishRequired,
            false
        )
        XCTAssertEqual(api.recordedCustomers, ["customer-a", "customer-a"])
        let completions = eventSink.events.filter {
            $0.name == SystemEventNames.purchaseCompleted
        }
        XCTAssertEqual(completions.count, 1)
        XCTAssertEqual(
            completions.first?.properties?["placement_id"] as? String,
            "placement-1"
        )
        XCTAssertEqual(
            completions.first?.properties?["product_id"] as? String,
            "product-1"
        )
        XCTAssertEqual(
            completions.first?.properties?["store_product_id"] as? String,
            "store-product-1"
        )
        XCTAssertEqual(
            completions.first?.properties?["experience_id"] as? String,
            "experience-1"
        )
        XCTAssertEqual(
            completions.first?.properties?["display_price"] as? String,
            "$9.99"
        )
        XCTAssertEqual(completions.first?.properties?["price"] as? Double, 9.99)
        XCTAssertEqual(
            completions.first?.properties?["transaction_id"] as? String,
            evidence.transactionId
        )
        XCTAssertEqual(
            completions.first?.properties?["source"] as? String,
            PurchaseOutcomeSource.startupRecovery.rawValue
        )
        XCTAssertEqual(completions.first?.properties?["test_store"] as? Bool, false)
    }

    func testFinishedStoredEvidenceCompletesOnlyOnceAcrossColdRelaunches() async {
        let mocks = MockFactory.shared
        mocks.identityService.setDistinctId("customer-a")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("purchase-completion-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = PurchaseStorageScope(
            appIdentifierHash: "app-a",
            environment: "production",
            storeEnvironment: .appStore
        )
        let evidenceStore = TransactionEvidenceStore(
            customStoragePath: root,
            scope: scope
        )
        let evidence = StoredTransactionEvidence(
            scope: scope,
            transactionJws: "signed-jws",
            transactionId: "finished-before-event",
            originalTransactionId: "original-1",
            productId: "store-product-1",
            distinctId: "customer-a",
            recordedAt: mocks.dateProvider.now(),
            isRevoked: false,
            finishRequired: false,
            commercialContext: commercialContext()
        )
        XCTAssertTrue(evidenceStore.save([evidence.transactionId: evidence]))
        let settings = NuxieRuntimeSettings(
            configuration: NuxieConfiguration(apiKey: "rotated-key")
        )
        let features = FeatureService(
            api: mocks.nuxieApi,
            identity: mocks.identityService,
            profile: mocks.profileService,
            dateProvider: mocks.dateProvider,
            featureInfo: FeatureInfo(),
            cacheTTL: 300
        )
        func makeObserver(
            api: RecoverySyncAPI,
            eventSink: RecoveryEventSink
        ) -> TransactionObserver {
            let service = TransactionService(
                productService: mocks.productService,
                transactionObserver: MockTransactionObserver(),
                pendingPurchaseStore: PendingPurchaseStore(
                    customStoragePath: root,
                    scope: scope
                ),
                dateProvider: mocks.dateProvider,
                settings: settings,
                eventSink: eventSink,
                purchaseStorageScope: scope,
                identityService: mocks.identityService
            )
            return TransactionObserver(
                api: api,
                features: features,
                identity: mocks.identityService,
                settings: settings,
                eventSink: eventSink,
                transactionServiceProvider: { service },
                evidenceStore: TransactionEvidenceStore(
                    customStoragePath: root,
                    scope: scope
                ),
                purchaseStorageScope: scope,
                dateProvider: mocks.dateProvider,
                activeStoreOriginalTransactionIDs: { [] }
            )
        }
        let firstEvents = RecoveryEventSink()
        let secondEvents = RecoveryEventSink()
        let finalEvents = RecoveryEventSink()

        await makeObserver(
            api: RecoverySyncAPI(succeeds: false),
            eventSink: firstEvents
        ).retryStoredEvidence()
        await makeObserver(
            api: RecoverySyncAPI(succeeds: false),
            eventSink: secondEvents
        ).retryStoredEvidence()

        XCTAssertNotNil(TransactionEvidenceStore(
            customStoragePath: root,
            scope: scope
        ).load().valueTreatingAbsentAsEmpty([:])![evidence.transactionId])
        XCTAssertEqual(
            firstEvents.events.filter { $0.name == SystemEventNames.purchaseCompleted }.count,
            1
        )
        XCTAssertTrue(secondEvents.events.isEmpty)

        await makeObserver(
            api: RecoverySyncAPI(succeeds: true),
            eventSink: finalEvents
        ).retryStoredEvidence()

        XCTAssertTrue(TransactionEvidenceStore(
            customStoragePath: root,
            scope: scope
        ).load().valueTreatingAbsentAsEmpty([:])!.isEmpty)
        XCTAssertTrue(finalEvents.events.filter {
            $0.name == SystemEventNames.purchaseCompleted
        }.isEmpty)
    }

    func testNinetyOneDayOldUnsyncedConsumableRetriesBeforeBecomingPrunable() async {
        let mocks = MockFactory.shared
        mocks.identityService.setDistinctId("customer-a")
        let now = Date(timeIntervalSince1970: 10_000_000)
        let dateProvider = MockDateProvider(initialDate: now)
        let scope = PurchaseStorageScope(
            appIdentifierHash: "app-a",
            environment: "production",
            storeEnvironment: .appStore
        )
        let evidenceStore = InMemoryTransactionEvidenceStore()
        let unsynced = StoredTransactionEvidence(
            scope: scope,
            transactionJws: "unsynced-consumable-jws",
            transactionId: "unsynced-consumable",
            originalTransactionId: "original",
            productId: "product",
            distinctId: "customer-a",
            recordedAt: now.addingTimeInterval(-91 * 24 * 3600),
            isRevoked: false
        )
        XCTAssertTrue(evidenceStore.save([unsynced.transactionId: unsynced]))
        let features = FeatureService(
            api: mocks.nuxieApi,
            identity: mocks.identityService,
            profile: mocks.profileService,
            dateProvider: dateProvider,
            featureInfo: FeatureInfo(),
            cacheTTL: 300
        )
        let settings = NuxieRuntimeSettings(
            configuration: NuxieConfiguration(apiKey: "app-a")
        )
        let service = TransactionService(
            productService: mocks.productService,
            transactionObserver: MockTransactionObserver(),
            pendingPurchaseStore: InMemoryPendingPurchaseStore(),
            dateProvider: mocks.dateProvider,
            settings: settings,
            eventSink: RecoveryEventSink(),
            purchaseStorageScope: scope,
            identityService: mocks.identityService
        )
        func makeObserver(api: RecoverySyncAPI) -> TransactionObserver {
            TransactionObserver(
                api: api,
                features: features,
                identity: mocks.identityService,
                settings: settings,
                eventSink: RecoveryEventSink(),
                transactionServiceProvider: { service },
                evidenceStore: evidenceStore,
                purchaseStorageScope: scope,
                dateProvider: dateProvider,
                activeStoreOriginalTransactionIDs: { [] }
            )
        }

        let offlineAPI = RecoverySyncAPI(succeeds: false)
        await makeObserver(api: offlineAPI).retryStoredEvidence()
        XCTAssertNotNil(evidenceStore.load().valueTreatingAbsentAsEmpty([:])![unsynced.transactionId])
        XCTAssertEqual(offlineAPI.recordedCustomers, ["customer-a"])

        let acknowledgedAPI = RecoverySyncAPI(succeeds: true)
        await makeObserver(api: acknowledgedAPI).retryStoredEvidence()
        XCTAssertEqual(acknowledgedAPI.recordedCustomers, ["customer-a"])
        XCTAssertTrue(evidenceStore.load().valueTreatingAbsentAsEmpty([:])!.isEmpty)
    }

    func testCompletionIsClaimedOnlyAfterDurableEventCapture() async {
        let mocks = MockFactory.shared
        mocks.identityService.setDistinctId("customer-a")
        let scope = PurchaseStorageScope(
            appIdentifierHash: "app-a",
            environment: "production",
            storeEnvironment: .appStore
        )
        let evidence = StoredTransactionEvidence(
            scope: scope,
            transactionJws: "signed-jws",
            transactionId: "capture-order",
            originalTransactionId: "original-1",
            productId: "store-product-1",
            distinctId: "customer-a",
            recordedAt: mocks.dateProvider.now(),
            isRevoked: false,
            commercialContext: commercialContext()
        )
        let evidenceStore = ControlledTransactionEvidenceStore(
            entries: [evidence.transactionId: evidence],
            saveSucceeds: true
        )
        let settings = NuxieRuntimeSettings(
            configuration: NuxieConfiguration(apiKey: "app-a")
        )
        let events = ControlledRecoveryEventSink(captureSucceeds: false)
        let features = FeatureService(
            api: mocks.nuxieApi,
            identity: mocks.identityService,
            profile: mocks.profileService,
            dateProvider: mocks.dateProvider,
            featureInfo: FeatureInfo(),
            cacheTTL: 300
        )

        func makeObserver() -> TransactionObserver {
            let service = TransactionService(
                productService: mocks.productService,
                transactionObserver: MockTransactionObserver(),
                pendingPurchaseStore: InMemoryPendingPurchaseStore(),
                dateProvider: mocks.dateProvider,
                settings: settings,
                eventSink: events,
                purchaseStorageScope: scope,
                identityService: mocks.identityService
            )
            return TransactionObserver(
                api: RecoverySyncAPI(succeeds: false),
                features: features,
                identity: mocks.identityService,
                settings: settings,
                eventSink: events,
                transactionServiceProvider: { service },
                evidenceStore: evidenceStore,
                purchaseStorageScope: scope,
                dateProvider: mocks.dateProvider,
                activeStoreOriginalTransactionIDs: { [] }
            )
        }

        await makeObserver().retryStoredEvidence()
        XCTAssertNil(evidenceStore.load().valueTreatingAbsentAsEmpty([:])![evidence.transactionId]?
            .completionDeliveredAt)
        XCTAssertTrue(events.captures.isEmpty)

        events.setCaptureSucceeds(true)
        evidenceStore.setSaveSucceeds(false)
        await makeObserver().retryStoredEvidence()
        XCTAssertNil(evidenceStore.load().valueTreatingAbsentAsEmpty([:])![evidence.transactionId]?
            .completionDeliveredAt)
        XCTAssertEqual(events.captures.count, 1)

        evidenceStore.setSaveSucceeds(true)
        await makeObserver().retryStoredEvidence()
        XCTAssertNotNil(evidenceStore.load().valueTreatingAbsentAsEmpty([:])![evidence.transactionId]?
            .completionDeliveredAt)
        XCTAssertEqual(events.captures.count, 2)
        XCTAssertEqual(Set(events.captures.map(\.eventId)).count, 1)

        await makeObserver().retryStoredEvidence()
        XCTAssertEqual(events.captures.count, 2)
    }

    func testTerminalBeforeSendDropRetiresPurchaseEvidenceWithoutDelivery() async throws {
        let mocks = MockFactory.shared
        mocks.identityService.setDistinctId("customer-a")
        let scope = PurchaseStorageScope(
            appIdentifierHash: "app-a",
            environment: "production",
            storeEnvironment: .appStore
        )
        let evidence = StoredTransactionEvidence(
            scope: scope,
            transactionJws: "",
            transactionId: "terminal-drop-evidence",
            originalTransactionId: "original-1",
            productId: "store-product-1",
            distinctId: "customer-a",
            recordedAt: mocks.dateProvider.now(),
            isRevoked: false,
            commercialContext: commercialContext(),
            backendSyncedAt: mocks.dateProvider.now()
        )
        let evidenceStore = InMemoryTransactionEvidenceStore()
        XCTAssertTrue(evidenceStore.save([evidence.transactionId: evidence]))
        let eventStore = MockEventStore()
        let eventLog = EventLog(
            identity: mocks.identityService,
            dateProvider: mocks.dateProvider,
            apiClient: mocks.nuxieApi,
            store: eventStore
        )
        let configuration = NuxieConfiguration(apiKey: "app-a")
        configuration.beforeSend = { event in
            event.name == SystemEventNames.purchaseCompleted ? nil : event
        }
        try await eventLog.configure(configuration: configuration)
        let events = DurableEventLogSink(eventLog: eventLog)
        let settings = NuxieRuntimeSettings(configuration: configuration)
        let service = TransactionService(
            productService: mocks.productService,
            transactionObserver: MockTransactionObserver(),
            pendingPurchaseStore: InMemoryPendingPurchaseStore(),
            dateProvider: mocks.dateProvider,
            settings: settings,
            eventSink: events,
            purchaseStorageScope: scope,
            identityService: mocks.identityService
        )
        let observer = TransactionObserver(
            api: RecoverySyncAPI(succeeds: true),
            features: RecoveryFeatureRecorder(),
            identity: mocks.identityService,
            settings: settings,
            eventSink: events,
            transactionServiceProvider: { service },
            evidenceStore: evidenceStore,
            purchaseStorageScope: scope,
            dateProvider: mocks.dateProvider,
            activeStoreOriginalTransactionIDs: { [] }
        )

        await observer.retryStoredEvidence()
        let eventId = await observer.purchaseCompletionEventId(
            transactionId: evidence.transactionId
        )

        XCTAssertTrue(evidenceStore.load().valueTreatingAbsentAsEmpty([:])!.isEmpty)
        XCTAssertEqual(eventStore.stableDroppedIds, Set([eventId]))
        XCTAssertTrue(eventStore.storedEvents.isEmpty)
        XCTAssertTrue(eventStore.pendingIds.isEmpty)
        await eventLog.close()
    }

    func testFailedJourneyCaptureDoesNotBlockIndependentReceiptSync() async {
        let mocks = MockFactory.shared
        mocks.identityService.setDistinctId("customer-a")
        let scope = PurchaseStorageScope(
            appIdentifierHash: "app-a",
            environment: "production",
            storeEnvironment: .appStore
        )
        let evidence = StoredTransactionEvidence(
            scope: scope,
            transactionJws: "signed-jws",
            transactionId: "capture-down-syncs",
            originalTransactionId: "original-1",
            productId: "store-product-1",
            distinctId: "customer-a",
            recordedAt: mocks.dateProvider.now(),
            isRevoked: false,
            commercialContext: commercialContext()
        )
        let evidenceStore = InMemoryTransactionEvidenceStore()
        XCTAssertTrue(evidenceStore.save([evidence.transactionId: evidence]))
        let api = RecoverySyncAPI(succeeds: true)
        let events = ControlledRecoveryEventSink(captureSucceeds: false)
        let configuration = NuxieConfiguration(apiKey: "app-a")
        let settings = NuxieRuntimeSettings(configuration: configuration)
        let features = FeatureService(
            api: mocks.nuxieApi,
            identity: mocks.identityService,
            profile: mocks.profileService,
            dateProvider: mocks.dateProvider,
            featureInfo: FeatureInfo(),
            cacheTTL: NuxieInternalConfiguration().featureCacheTTL
        )
        let service = TransactionService(
            productService: mocks.productService,
            transactionObserver: MockTransactionObserver(),
            pendingPurchaseStore: InMemoryPendingPurchaseStore(),
            dateProvider: mocks.dateProvider,
            settings: settings,
            eventSink: events,
            purchaseStorageScope: scope,
            identityService: mocks.identityService
        )
        let observer = TransactionObserver(
            api: api,
            features: features,
            identity: mocks.identityService,
            settings: settings,
            eventSink: events,
            transactionServiceProvider: { service },
            evidenceStore: evidenceStore,
            purchaseStorageScope: scope,
            dateProvider: mocks.dateProvider,
            activeStoreOriginalTransactionIDs: { [] }
        )

        await observer.retryStoredEvidence()

        XCTAssertEqual(api.recordedCustomers, ["customer-a"])
        let retained = evidenceStore.load().valueTreatingAbsentAsEmpty([:])![evidence.transactionId]
        XCTAssertNotNil(retained)
        XCTAssertEqual(retained?.transactionJws, "")
        XCTAssertNotNil(retained?.backendSyncedAt)
        XCTAssertNil(retained?.completionDeliveredAt)
        XCTAssertEqual(events.routedAttemptCount, 0)
        XCTAssertEqual(events.captureOnlyAttemptCount, 1)
    }

    func testUnmatchedFinishRequiredEvidenceIsNotMarkedFinished() async {
        let mocks = MockFactory.shared
        mocks.identityService.setDistinctId("customer-a")
        let scope = PurchaseStorageScope(
            appIdentifierHash: "app-a",
            environment: "production",
            storeEnvironment: .appStore
        )
        let evidence = StoredTransactionEvidence(
            scope: scope,
            transactionJws: "signed-jws",
            transactionId: "still-unfinished",
            originalTransactionId: "original-1",
            productId: "store-product-1",
            distinctId: "customer-a",
            recordedAt: mocks.dateProvider.now(),
            isRevoked: false,
            finishRequired: true
        )
        let evidenceStore = InMemoryTransactionEvidenceStore()
        XCTAssertTrue(evidenceStore.save([evidence.transactionId: evidence]))
        let api = RecoverySyncAPI(succeeds: true)
        let configuration = NuxieConfiguration(apiKey: "app-a")
        let settings = NuxieRuntimeSettings(configuration: configuration)
        let features = FeatureService(
            api: mocks.nuxieApi,
            identity: mocks.identityService,
            profile: mocks.profileService,
            dateProvider: mocks.dateProvider,
            featureInfo: FeatureInfo(),
            cacheTTL: NuxieInternalConfiguration().featureCacheTTL
        )
        let observer = TransactionObserver(
            api: api,
            features: features,
            identity: mocks.identityService,
            settings: settings,
            eventSink: RecoveryEventSink(),
            transactionServiceProvider: { fatalError("no unfinished transaction matched") },
            evidenceStore: evidenceStore,
            purchaseStorageScope: scope,
            dateProvider: mocks.dateProvider,
            activeStoreOriginalTransactionIDs: { [] }
        )

        await observer.retryStoredEvidence()

        let retained = evidenceStore.load().valueTreatingAbsentAsEmpty([:])![evidence.transactionId]
        XCTAssertEqual(api.recordedCustomers, ["customer-a"])
        XCTAssertNotNil(retained)
        XCTAssertEqual(retained?.finishRequired, true)
        XCTAssertEqual(retained?.transactionJws, "")
        XCTAssertNotNil(retained?.backendSyncedAt)
    }

    func testConcurrentEvidenceRetriesCoalesceReceiptSubmission() async {
        let mocks = MockFactory.shared
        mocks.identityService.setDistinctId("customer-a")
        let scope = PurchaseStorageScope(
            appIdentifierHash: "app-a",
            environment: "production",
            storeEnvironment: .appStore
        )
        let evidence = StoredTransactionEvidence(
            scope: scope,
            transactionJws: "signed-jws",
            transactionId: "concurrent-retry",
            originalTransactionId: "original-1",
            productId: "store-product-1",
            distinctId: "customer-a",
            recordedAt: mocks.dateProvider.now(),
            isRevoked: false
        )
        let evidenceStore = InMemoryTransactionEvidenceStore()
        XCTAssertTrue(evidenceStore.save([evidence.transactionId: evidence]))
        let api = ControlledConcurrentRecoverySyncAPI()
        let projectionDerivations = AsyncCallCounter()
        let configuration = NuxieConfiguration(apiKey: "app-a")
        let settings = NuxieRuntimeSettings(configuration: configuration)
        let features = FeatureService(
            api: mocks.nuxieApi,
            identity: mocks.identityService,
            profile: mocks.profileService,
            dateProvider: mocks.dateProvider,
            featureInfo: FeatureInfo(),
            cacheTTL: NuxieInternalConfiguration().featureCacheTTL
        )
        let observer = TransactionObserver(
            api: api,
            features: features,
            identity: mocks.identityService,
            settings: settings,
            eventSink: RecoveryEventSink(),
            transactionServiceProvider: { fatalError("unused") },
            evidenceStore: evidenceStore,
            descriptorAllowanceProvider: { _ in
                await projectionDerivations.increment()
                return nil
            },
            purchaseStorageScope: scope,
            dateProvider: mocks.dateProvider
        )

        let firstRetry = Task { await observer.retryStoredEvidence() }
        await api.waitForFirstRequest()
        let concurrentRetry = Task { await observer.retryStoredEvidence() }
        _ = await api.waitForRequestCount(2)
        await api.release()
        await firstRetry.value
        await concurrentRetry.value

        let recordedCustomers = await api.recordedCustomers()
        let derivationCount = await projectionDerivations.count()
        XCTAssertEqual(recordedCustomers, ["customer-a"])
        XCTAssertEqual(derivationCount, 1)
        XCTAssertTrue(evidenceStore.load().valueTreatingAbsentAsEmpty([:])!.isEmpty)
    }

    func testConcurrentTransactionSyncsShareOneBackendSubmissionAndEvent() async {
        let mocks = MockFactory.shared
        mocks.identityService.setDistinctId("customer-a")
        let configuration = NuxieConfiguration(apiKey: "app-a")
        let settings = NuxieRuntimeSettings(configuration: configuration)
        let api = ControlledConcurrentRecoverySyncAPI()
        let events = RecoveryEventSink()
        let features = FeatureService(
            api: mocks.nuxieApi,
            identity: mocks.identityService,
            profile: mocks.profileService,
            dateProvider: mocks.dateProvider,
            featureInfo: FeatureInfo(),
            cacheTTL: NuxieInternalConfiguration().featureCacheTTL
        )
        let observer = TransactionObserver(
            api: api,
            features: features,
            identity: mocks.identityService,
            settings: settings,
            eventSink: events,
            transactionServiceProvider: { fatalError("unused") },
            evidenceStore: InMemoryTransactionEvidenceStore(),
            purchaseStorageScope: .testFixture,
            dateProvider: mocks.dateProvider,
            activeStoreOriginalTransactionIDs: { [] }
        )

        let directCallback = Task {
            await observer.syncTransaction(
                transactionJws: "signed-jws",
                transactionId: "racing-sync",
                productId: "store-product-1",
                originalTransactionId: "original-1"
            )
        }
        await api.waitForFirstRequest()
        let storeUpdate = Task {
            await observer.syncTransaction(
                transactionJws: "signed-jws",
                transactionId: "racing-sync",
                productId: "store-product-1",
                originalTransactionId: "original-1"
            )
        }
        _ = await api.waitForRequestCount(2)
        await api.release()

        let directResult = await directCallback.value
        let updateResult = await storeUpdate.value
        let customers = await api.recordedCustomers()
        XCTAssertTrue(directResult)
        XCTAssertTrue(updateResult)
        XCTAssertEqual(customers, ["customer-a"])
        XCTAssertEqual(
            events.events.filter { $0.name == SystemEventNames.purchaseSynced }.count,
            1
        )
    }

    func testFailedTransactionSyncCanBeRetried() async {
        let mocks = MockFactory.shared
        mocks.identityService.setDistinctId("customer-a")
        let configuration = NuxieConfiguration(apiKey: "app-a")
        let api = SequencedRecoverySyncAPI(results: [false, true])
        let events = RecoveryEventSink()
        let observer = TransactionObserver(
            api: api,
            features: FeatureService(
                api: mocks.nuxieApi,
                identity: mocks.identityService,
                profile: mocks.profileService,
                dateProvider: mocks.dateProvider,
                featureInfo: FeatureInfo(),
                cacheTTL: NuxieInternalConfiguration().featureCacheTTL
            ),
            identity: mocks.identityService,
            settings: NuxieRuntimeSettings(configuration: configuration),
            eventSink: events,
            transactionServiceProvider: { fatalError("unused") },
            evidenceStore: InMemoryTransactionEvidenceStore(),
            purchaseStorageScope: .testFixture,
            dateProvider: mocks.dateProvider,
            activeStoreOriginalTransactionIDs: { [] }
        )

        let first = await observer.syncTransaction(
            transactionJws: "signed-jws",
            transactionId: "retry-sync",
            productId: "store-product-1",
            originalTransactionId: "original-1"
        )
        let second = await observer.syncTransaction(
            transactionJws: "signed-jws",
            transactionId: "retry-sync",
            productId: "store-product-1",
            originalTransactionId: "original-1"
        )
        let requestCount = await api.requests()

        XCTAssertFalse(first)
        XCTAssertTrue(second)
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(
            events.events.filter { $0.name == SystemEventNames.purchaseSynced }.count,
            1
        )
    }

    func testShutdownStopsSuspendedRecoveryBeforeJoiningProfilePrefetch() async {
        let mocks = MockFactory.shared
        mocks.identityService.setDistinctId("customer-a")
        let scope = PurchaseStorageScope.testFixture
        let evidence = StoredTransactionEvidence(
            scope: scope,
            transactionJws: "signed-jws",
            transactionId: "shutdown-recovery",
            originalTransactionId: "original-1",
            productId: "store-product-1",
            distinctId: "customer-a",
            recordedAt: mocks.dateProvider.now(),
            isRevoked: false
        )
        let evidenceStore = InMemoryTransactionEvidenceStore()
        XCTAssertTrue(evidenceStore.save([evidence.transactionId: evidence]))
        let api = ShutdownControlledSyncAPI()
        let configuration = NuxieConfiguration(apiKey: "app-a")
        let observer = TransactionObserver(
            api: api,
            features: FeatureService(
                api: mocks.nuxieApi,
                identity: mocks.identityService,
                profile: mocks.profileService,
                dateProvider: mocks.dateProvider,
                featureInfo: FeatureInfo(),
                cacheTTL: NuxieInternalConfiguration().featureCacheTTL
            ),
            identity: mocks.identityService,
            settings: NuxieRuntimeSettings(configuration: configuration),
            eventSink: RecoveryEventSink(),
            transactionServiceProvider: { fatalError("unused") },
            evidenceStore: evidenceStore,
            purchaseStorageScope: scope,
            dateProvider: mocks.dateProvider,
            activeStoreOriginalTransactionIDs: { [] }
        )

        let profilePrefetch = Task { await observer.retryStoredEvidence() }
        await api.waitUntilStarted()
        await NuxieSDK.stopPurchasesAndAwaitStartupTasks(
            [profilePrefetch],
            stopPurchases: { await observer.stopListening() }
        )
        let wasCancelled = await api.waitForCancellation()
        if !wasCancelled { await api.release() }
        await observer.retryStoredEvidence()
        let requests = await api.requests()

        XCTAssertTrue(wasCancelled)
        XCTAssertEqual(requests, 1)
        XCTAssertNotNil(evidenceStore.load().valueTreatingAbsentAsEmpty([:])![evidence.transactionId])
    }

    func testDirectSyncResponseAfterStopCannotMutateRetainedEvidenceOrEvents() async {
        let mocks = MockFactory.shared
        mocks.identityService.setDistinctId("customer-a")
        let scope = PurchaseStorageScope.testFixture
        let evidence = StoredTransactionEvidence(
            scope: scope,
            transactionJws: "signed-jws",
            transactionId: "sync-across-shutdown",
            originalTransactionId: "original-1",
            productId: "store-product-1",
            distinctId: "customer-a",
            recordedAt: mocks.dateProvider.now(),
            isRevoked: false
        )
        let evidenceStore = InMemoryTransactionEvidenceStore()
        XCTAssertTrue(evidenceStore.save([evidence.transactionId: evidence]))
        let api = ControlledConcurrentRecoverySyncAPI()
        let events = RecoveryEventSink()
        let configuration = NuxieConfiguration(apiKey: "app-a")
        let settings = NuxieRuntimeSettings(configuration: configuration)
        let features = FeatureService(
            api: mocks.nuxieApi,
            identity: mocks.identityService,
            profile: mocks.profileService,
            dateProvider: mocks.dateProvider,
            featureInfo: FeatureInfo(),
            cacheTTL: NuxieInternalConfiguration().featureCacheTTL
        )
        let observer = TransactionObserver(
            api: api,
            features: features,
            identity: mocks.identityService,
            settings: settings,
            eventSink: events,
            transactionServiceProvider: { fatalError("unused") },
            evidenceStore: evidenceStore,
            purchaseStorageScope: scope,
            dateProvider: mocks.dateProvider,
            activeStoreOriginalTransactionIDs: { [] }
        )

        let directSync = Task {
            await observer.syncTransaction(
                transactionJws: evidence.transactionJws,
                transactionId: evidence.transactionId,
                productId: evidence.productId,
                originalTransactionId: evidence.originalTransactionId
            )
        }
        await api.waitForFirstRequest()
        let stop = Task { await observer.stopListening() }
        await api.waitForCancellation()
        await api.release()
        await stop.value
        let staleResult = await directSync.value

        XCTAssertFalse(staleResult)
        XCTAssertEqual(
            evidenceStore.load().valueTreatingAbsentAsEmpty([:])![evidence.transactionId]?.transactionJws,
            "signed-jws"
        )
        XCTAssertNil(evidenceStore.load().valueTreatingAbsentAsEmpty([:])![evidence.transactionId]?.backendSyncedAt)
        XCTAssertTrue(events.events.filter {
            $0.name == SystemEventNames.purchaseSynced
        }.isEmpty)

        let nextSetup = TransactionObserver(
            api: RecoverySyncAPI(succeeds: true),
            features: features,
            identity: mocks.identityService,
            settings: settings,
            eventSink: RecoveryEventSink(),
            transactionServiceProvider: { fatalError("unused") },
            evidenceStore: evidenceStore,
            purchaseStorageScope: scope,
            dateProvider: mocks.dateProvider,
            activeStoreOriginalTransactionIDs: { [] }
        )
        await nextSetup.retryStoredEvidence()
        XCTAssertTrue(evidenceStore.load().valueTreatingAbsentAsEmpty([:])!.isEmpty)
    }

    func testStopListeningJoinsDirectSyncThroughAnInFlightFeatureUpdate() async {
        let mocks = MockFactory.shared
        mocks.identityService.setDistinctId("customer-a")
        let features = RecoveryFeatureRecorder()
        await features.suspendNextPurchaseUpdate()
        let observer = TransactionObserver(
            api: FeaturePurchaseSyncAPI(),
            features: features,
            identity: mocks.identityService,
            settings: NuxieRuntimeSettings(
                configuration: NuxieConfiguration(apiKey: "app-a")
            ),
            eventSink: RecoveryEventSink(),
            transactionServiceProvider: { fatalError("unused") },
            evidenceStore: InMemoryTransactionEvidenceStore(),
            purchaseStorageScope: .testFixture,
            dateProvider: mocks.dateProvider,
            activeStoreOriginalTransactionIDs: { [] }
        )

        let sync = Task {
            await observer.syncTransaction(
                transactionJws: "signed-jws",
                transactionId: "joined-direct-sync",
                productId: "store-product-1",
                originalTransactionId: "original-1"
            )
        }
        await features.waitForPurchaseUpdate()

        let stopFinished = AsyncCallCounter()
        let stop = Task {
            await observer.stopListening()
            await stopFinished.increment()
        }
        try? await Task.sleep(nanoseconds: 25_000_000)
        var stopCount = await stopFinished.count()
        XCTAssertEqual(stopCount, 0)

        await features.releasePurchaseUpdate()
        await stop.value
        let syncResult = await sync.value
        let updateCount = await features.purchaseUpdateCount()
        stopCount = await stopFinished.count()
        XCTAssertFalse(syncResult)
        XCTAssertEqual(updateCount, 1)
        XCTAssertEqual(stopCount, 1)
    }

    func testInactiveCustomerKeepsCompletionContextAfterBackendSync() async {
        let mocks = MockFactory.shared
        mocks.identityService.setDistinctId("customer-b")
        let scope = PurchaseStorageScope(
            appIdentifierHash: "app-a",
            environment: "production",
            storeEnvironment: .appStore
        )
        let evidence = StoredTransactionEvidence(
            scope: scope,
            transactionJws: "signed-jws",
            transactionId: "inactive-owner",
            originalTransactionId: "original-1",
            productId: "store-product-1",
            distinctId: "customer-a",
            recordedAt: mocks.dateProvider.now(),
            isRevoked: false,
            commercialContext: commercialContext()
        )
        let evidenceStore = InMemoryTransactionEvidenceStore()
        XCTAssertTrue(evidenceStore.save([evidence.transactionId: evidence]))
        let api = RecoverySyncAPI(succeeds: true)
        let events = RecoveryEventSink()
        let settings = NuxieRuntimeSettings(
            configuration: NuxieConfiguration(apiKey: "app-a")
        )
        let features = FeatureService(
            api: mocks.nuxieApi,
            identity: mocks.identityService,
            profile: mocks.profileService,
            dateProvider: mocks.dateProvider,
            featureInfo: FeatureInfo(),
            cacheTTL: 300
        )

        func makeObserver() -> TransactionObserver {
            let service = TransactionService(
                productService: mocks.productService,
                transactionObserver: MockTransactionObserver(),
                pendingPurchaseStore: InMemoryPendingPurchaseStore(),
                dateProvider: mocks.dateProvider,
                settings: settings,
                eventSink: events,
                purchaseStorageScope: scope,
                identityService: mocks.identityService
            )
            return TransactionObserver(
                api: api,
                features: features,
                identity: mocks.identityService,
                settings: settings,
                eventSink: events,
                transactionServiceProvider: { service },
                evidenceStore: evidenceStore,
                purchaseStorageScope: scope,
                dateProvider: mocks.dateProvider,
                activeStoreOriginalTransactionIDs: { [] }
            )
        }

        await makeObserver().retryStoredEvidence()
        await makeObserver().retryStoredEvidence()
        let retained = evidenceStore.load().valueTreatingAbsentAsEmpty([:])![evidence.transactionId]
        XCTAssertNotNil(retained?.backendSyncedAt)
        XCTAssertNil(retained?.completionDeliveredAt)
        XCTAssertEqual(retained?.transactionJws, "")
        XCTAssertEqual(api.recordedCustomers, ["customer-a"])
        XCTAssertTrue(events.events.filter {
            $0.name == SystemEventNames.purchaseCompleted
        }.isEmpty)

        mocks.identityService.setDistinctId("customer-a")
        await makeObserver().retryStoredEvidence()
        XCTAssertTrue(evidenceStore.load().valueTreatingAbsentAsEmpty([:])!.isEmpty)
        XCTAssertEqual(api.recordedCustomers, ["customer-a"])
        XCTAssertEqual(events.events.filter {
            $0.name == SystemEventNames.purchaseCompleted
        }.count, 1)
    }

    func testEvidenceDeletionRetriesAfterDurableSaveFailure() async {
        let mocks = MockFactory.shared
        mocks.identityService.setDistinctId("customer-a")
        let scope = PurchaseStorageScope(
            appIdentifierHash: "app-a",
            environment: "production",
            storeEnvironment: .appStore
        )
        let evidence = StoredTransactionEvidence(
            scope: scope,
            transactionJws: "signed-jws",
            transactionId: "delete-retry",
            originalTransactionId: "original-1",
            productId: "store-product-1",
            distinctId: "customer-a",
            recordedAt: mocks.dateProvider.now(),
            isRevoked: false
        )
        let evidenceStore = ControlledTransactionEvidenceStore(
            entries: [evidence.transactionId: evidence],
            saveSucceeds: false
        )
        let settings = NuxieRuntimeSettings(
            configuration: NuxieConfiguration(apiKey: "app-a")
        )
        let service = TransactionService(
            productService: mocks.productService,
            transactionObserver: MockTransactionObserver(),
            pendingPurchaseStore: InMemoryPendingPurchaseStore(),
            dateProvider: mocks.dateProvider,
            settings: settings,
            eventSink: RecoveryEventSink(),
            purchaseStorageScope: scope,
            identityService: mocks.identityService
        )
        let observer = TransactionObserver(
            api: RecoverySyncAPI(succeeds: true),
            features: FeatureService(
                api: mocks.nuxieApi,
                identity: mocks.identityService,
                profile: mocks.profileService,
                dateProvider: mocks.dateProvider,
                featureInfo: FeatureInfo(),
                cacheTTL: 300
            ),
            identity: mocks.identityService,
            settings: settings,
            eventSink: RecoveryEventSink(),
            transactionServiceProvider: { service },
            evidenceStore: evidenceStore,
            purchaseStorageScope: scope,
            dateProvider: mocks.dateProvider,
            activeStoreOriginalTransactionIDs: { [] }
        )

        let firstRemoval = await observer.removeEvidence(
            transactionId: evidence.transactionId
        )
        XCTAssertFalse(firstRemoval)
        XCTAssertNotNil(evidenceStore.load().valueTreatingAbsentAsEmpty([:])![evidence.transactionId])
        evidenceStore.setSaveSucceeds(true)
        let secondRemoval = await observer.removeEvidence(
            transactionId: evidence.transactionId
        )
        XCTAssertTrue(secondRemoval)
        XCTAssertTrue(evidenceStore.load().valueTreatingAbsentAsEmpty([:])!.isEmpty)
    }

    func testExpiredEvidencePruneRetriesDurableSave() async {
        let mocks = MockFactory.shared
        mocks.identityService.setDistinctId("customer-a")
        let scope = PurchaseStorageScope(
            appIdentifierHash: "app-a",
            environment: "production",
            storeEnvironment: .appStore
        )
        let expired = StoredTransactionEvidence(
            scope: scope,
            transactionJws: "expired-jws",
            transactionId: "expired-retry",
            originalTransactionId: "original-1",
            productId: "store-product-1",
            distinctId: "customer-a",
            recordedAt: Date(timeIntervalSince1970: 0),
            isRevoked: false,
            backendSyncedAt: Date(timeIntervalSince1970: 1)
        )
        let evidenceStore = ControlledTransactionEvidenceStore(
            entries: [expired.transactionId: expired],
            saveSucceeds: false
        )
        let api = RecoverySyncAPI(succeeds: true)
        let settings = NuxieRuntimeSettings(
            configuration: NuxieConfiguration(apiKey: "app-a")
        )
        let service = TransactionService(
            productService: mocks.productService,
            transactionObserver: MockTransactionObserver(),
            pendingPurchaseStore: InMemoryPendingPurchaseStore(),
            dateProvider: mocks.dateProvider,
            settings: settings,
            eventSink: RecoveryEventSink(),
            purchaseStorageScope: scope,
            identityService: mocks.identityService
        )
        let observer = TransactionObserver(
            api: api,
            features: FeatureService(
                api: mocks.nuxieApi,
                identity: mocks.identityService,
                profile: mocks.profileService,
                dateProvider: mocks.dateProvider,
                featureInfo: FeatureInfo(),
                cacheTTL: 300
            ),
            identity: mocks.identityService,
            settings: settings,
            eventSink: RecoveryEventSink(),
            transactionServiceProvider: { service },
            evidenceStore: evidenceStore,
            purchaseStorageScope: scope,
            dateProvider: mocks.dateProvider,
            activeStoreOriginalTransactionIDs: { [] }
        )

        await observer.retryStoredEvidence()
        XCTAssertNotNil(evidenceStore.load().valueTreatingAbsentAsEmpty([:])![expired.transactionId])
        XCTAssertTrue(api.recordedCustomers.isEmpty)

        evidenceStore.setSaveSucceeds(true)
        await observer.retryStoredEvidence()
        XCTAssertTrue(evidenceStore.load().valueTreatingAbsentAsEmpty([:])!.isEmpty)
        XCTAssertTrue(api.recordedCustomers.isEmpty)
    }
}
