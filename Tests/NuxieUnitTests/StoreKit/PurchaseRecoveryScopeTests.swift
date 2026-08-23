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

private actor SuspendedOutcomePurchaseDelegate: NuxiePurchaseDelegate {
    private var callCount = 0

    func purchase(product _: StoreProduct) async -> PurchaseResult {
        callCount += 1
        do {
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return .purchased
        } catch {
            return .failed(error)
        }
    }

    func restorePurchases() async -> RestoreResult { .noPurchases }

    func calls() -> Int { callCount }
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
        _ name: String,
        properties: [String: Any]?,
        eventId: String,
        distinctId: String
    ) async -> Bool {
        _ = eventId
        _ = distinctId
        lock.withLock {
            routedCaptures += 1
            storage.append((name, properties))
        }
        return true
    }

    func captureOnly(
        _ name: String,
        properties: [String: Any]?,
        eventId: String,
        distinctId: String
    ) async -> Bool {
        _ = eventId
        _ = distinctId
        lock.withLock {
            captureOnlyCaptures += 1
            storage.append((name, properties))
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
        _ name: String,
        properties: [String: Any]?,
        eventId: String,
        distinctId: String
    ) async -> Bool {
        lock.withLock {
            routedAttempts += 1
            attemptedEventIds.append(eventId)
            guard captureSucceeds else { return false }
            captured.append((name, eventId))
            return true
        }
    }

    func captureOnly(
        _ name: String,
        properties: [String: Any]?,
        eventId: String,
        distinctId: String
    ) async -> Bool {
        _ = properties
        _ = distinctId
        return lock.withLock {
            captureOnlyAttempts += 1
            attemptedEventIds.append(eventId)
            guard captureSucceeds else { return false }
            capturedOnly.append((name, eventId))
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
        _ name: String,
        properties: [String: Any]?,
        eventId: String,
        distinctId: String
    ) async -> Bool {
        await captureOnly(
            name,
            properties: properties,
            eventId: eventId,
            distinctId: distinctId
        )
    }

    func captureOnly(
        _ name: String,
        properties: [String: Any]?,
        eventId: String,
        distinctId: String
    ) async -> Bool {
        await eventLog.captureSystemEvent(
            name,
            properties: properties,
            eventId: eventId,
            distinctId: distinctId
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

    func load() -> [String: StoredTransactionEvidence] {
        lock.withLock { entries }
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
    private var appliedTransactionIds: [String] = []
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
    func applyLocalPurchase(
        grants: [StoreProduct.LocalEntitlementGrant],
        transactionId: String
    ) async {
        appliedTransactionIds.append(transactionId)
    }

    func appliedTransactions() -> [String] { appliedTransactionIds }

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

private enum ProviderUpdateToken {
    case exactCheckout
    case historicalCustomer
    case unrecognized
    case missing
}

private struct ProviderUpdateHarness {
    let appAccountToken: UUID?
    let observer: TransactionObserver
    let service: TransactionService
    let api: RecoverySyncAPI
    let evidenceStore: InMemoryTransactionEvidenceStore
    let eventSink: RecoveryEventSink
    let features: RecoveryFeatureRecorder
    let finishes: FinishCounter
    let pending: PendingPurchaseRecord

    func handle(
        source: TransactionProcessingSource = .storeUpdates
    ) async {
        await observer.handleVerifiedTransaction(
            VerifiedStoreTransactionUpdate(
                transactionId: "provider-update",
                originalTransactionId: "provider-original",
                productId: "store-product-1",
                appAccountToken: appAccountToken,
                isRevoked: false,
                isUpgraded: false,
                finish: { await finishes.increment() }
            ),
            jwsRepresentation: "provider-update-jws",
            source: source
        )
    }
}

private struct OutcomeOnlyDelegateUpdateHarness {
    let appAccountToken: UUID
    let observer: TransactionObserver
    let service: TransactionService
    let api: RecoverySyncAPI
    let eventSink: RecoveryEventSink
    let localAccessStore: InMemoryLocalPurchaseAccessStore
    let pendingStore: InMemoryPendingPurchaseStore
    let finishes: FinishCounter

    func handle() async {
        await observer.handleVerifiedTransaction(
            VerifiedStoreTransactionUpdate(
                transactionId: "outcome-only-update",
                originalTransactionId: "outcome-only-original",
                productId: "store-product-1",
                appAccountToken: appAccountToken,
                isRevoked: false,
                isUpgraded: false,
                finish: { await finishes.increment() }
            ),
            jwsRepresentation: "outcome-only-jws",
            source: .storeUpdates
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

    func load() -> [String: PendingPurchaseRecord] {
        lock.withLock { entries }
    }

    func save(_: [String: PendingPurchaseRecord]) -> Bool { false }
}

private final class RecoveryDeletionFailureStore:
    PendingPurchaseStoreProtocol,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var entries: [String: PendingPurchaseRecord] = [:]

    func load() -> [String: PendingPurchaseRecord] {
        lock.withLock { entries }
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
                    publishedAt: "2026-08-19T00:00:00Z",
                    publishedAtSeq: 1
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
        func makeObserver(scope: PurchaseStorageScope) -> any TransactionObserverProtocol {
            TransactionObserver(
                api: RecoverySyncAPI(succeeds: true),
                features: features,
                identity: mocks.identityService,
                settings: settings,
                eventSink: RecoveryEventSink(),
                transactionServiceProvider: { fatalError("unused") },
                evidenceStore: InMemoryTransactionEvidenceStore(),
                localAccessStore: InMemoryLocalPurchaseAccessStore(),
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

    func testCanonicalCompletionPayloadIsIndependentOfRaceWinner() {
        let context = commercialContext()
        let directCallback = purchaseCompletionProperties(
            context: context,
            transactionId: "transaction-1",
            testStore: false
        )
        let storeUpdateRecovery = purchaseCompletionProperties(
            context: context,
            transactionId: "transaction-1",
            testStore: false
        )

        XCTAssertEqual(
            directCallback as NSDictionary,
            storeUpdateRecovery as NSDictionary
        )
        XCTAssertEqual(directCallback["display_price"] as? String, "$9.99")
        XCTAssertEqual(directCallback["price"] as? Double, 9.99)
        XCTAssertEqual(directCallback["source"] as? String, "purchase")
        XCTAssertEqual(directCallback["transaction_id"] as? String, "transaction-1")
    }

    private func providerUpdateHarness(
        token: ProviderUpdateToken
    ) -> ProviderUpdateHarness {
        let mocks = MockFactory.shared
        mocks.identityService.setDistinctId("customer-b")
        let scope = PurchaseStorageScope(
            appIdentifierHash: "app-a",
            environment: "production",
            storeEnvironment: .appStore
        )
        let ownershipStore = InMemoryPurchaseAccountOwnershipStore()
        XCTAssertTrue(ownershipStore.upsert(StoredPurchaseAccountOwnership(
            scope: scope,
            appAccountToken: scope.appAccountToken(distinctId: "customer-b"),
            distinctId: "customer-b",
            productAuthorities: ["store-product-1": .providerConnector]
        )))
        let appAccountToken: UUID?
        switch token {
        case .exactCheckout:
            appAccountToken = scope.appAccountToken(distinctId: "customer-b")
        case .historicalCustomer:
            let historicalToken = scope.appAccountToken(distinctId: "customer-a")
            XCTAssertTrue(ownershipStore.upsert(StoredPurchaseAccountOwnership(
                scope: scope,
                appAccountToken: historicalToken,
                distinctId: "customer-a",
                productAuthorities: ["store-product-1": .providerConnector]
            )))
            appAccountToken = historicalToken
        case .unrecognized:
            appAccountToken = UUID()
        case .missing:
            appAccountToken = nil
        }
        let pendingStore = InMemoryPendingPurchaseStore()
        let pending = PendingPurchaseRecord(
            scope: scope,
            distinctId: "customer-b",
            appAccountToken: scope.appAccountToken(distinctId: "customer-b"),
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
            state: .pending,
            evidenceAuthority: .providerConnector
        )
        XCTAssertTrue(pendingStore.save([
            "customer-b::store-product-1": pending,
        ]))
        let settings = NuxieRuntimeSettings(
            configuration: NuxieConfiguration(apiKey: "app-a")
        )
        settings.setPurchaseDelegate(MockPurchaseDelegate())
        let eventSink = RecoveryEventSink()
        let features = RecoveryFeatureRecorder()
        let service = TransactionService(
            productService: mocks.productService,
            transactionObserver: MockTransactionObserver(),
            pendingPurchaseStore: pendingStore,
            accountOwnershipStore: ownershipStore,
            dateProvider: mocks.dateProvider,
            settings: settings,
            eventSink: eventSink,
            purchaseStorageScope: scope,
            identityService: mocks.identityService,
            featureService: features,
            activeProductEvidenceAuthority: { productId in
                productId == "store-product-1"
                    ? .providerConnector
                    : .readyNoMatch
            }
        )
        let api = RecoverySyncAPI(succeeds: true)
        let evidenceStore = InMemoryTransactionEvidenceStore()
        let observer = TransactionObserver(
            api: api,
            features: features,
            identity: mocks.identityService,
            settings: settings,
            eventSink: eventSink,
            transactionServiceProvider: { service },
            evidenceStore: evidenceStore,
            localAccessStore: InMemoryLocalPurchaseAccessStore(),
            purchaseStorageScope: scope,
            dateProvider: mocks.dateProvider,
            activeStoreOriginalTransactionIDs: { [] }
        )
        return ProviderUpdateHarness(
            appAccountToken: appAccountToken,
            observer: observer,
            service: service,
            api: api,
            evidenceStore: evidenceStore,
            eventSink: eventSink,
            features: features,
            finishes: FinishCounter(),
            pending: pending
        )
    }

    private func outcomeOnlyDelegateUpdateHarness(
        observationExpired: Bool
    ) -> OutcomeOnlyDelegateUpdateHarness {
        let mocks = MockFactory.shared
        let identity = MockIdentityService()
        identity.setDistinctId("customer-a")
        let dateProvider = MockDateProvider()
        let scope = PurchaseStorageScope(
            appIdentifierHash: "app-a",
            environment: "production",
            storeEnvironment: .appStore
        )
        let token = scope.appAccountToken(distinctId: "customer-a")
        let pendingStore = InMemoryPendingPurchaseStore()
        let pending = PendingPurchaseRecord(
            scope: scope,
            distinctId: "customer-a",
            appAccountToken: token,
            commercialContext: commercialContext(),
            recordedAt: dateProvider.now(),
            localEntitlementGrants: [
                StoredLocalEntitlementGrant(
                    featureId: "premium",
                    featureExternalId: nil,
                    allowanceType: "boolean",
                    allowance: nil
                ),
            ],
            state: .checkout,
            evidenceAuthority: .outcomeOnlyDelegate,
            storeKitObservationDeadline: dateProvider.date(
                byAddingTimeInterval: TransactionService
                    .outcomeOnlyStoreKitObservationTTL,
                to: dateProvider.now()
            )
        )
        XCTAssertTrue(pendingStore.save([
            "customer-a::store-product-1": pending,
        ]))
        let ownershipStore = InMemoryPurchaseAccountOwnershipStore()
        XCTAssertTrue(ownershipStore.upsert(StoredPurchaseAccountOwnership(
            scope: scope,
            appAccountToken: token,
            distinctId: "customer-a",
            productAuthorities: ["store-product-1": .nativeStoreKit]
        )))
        if observationExpired {
            dateProvider.advance(
                by: TransactionService.outcomeOnlyStoreKitObservationTTL + 1
            )
        }
        let settings = NuxieRuntimeSettings(
            configuration: NuxieConfiguration(apiKey: "app-a")
        )
        settings.setPurchaseDelegate(MockPurchaseDelegate())
        let eventSink = RecoveryEventSink()
        let features = RecoveryFeatureRecorder()
        let service = TransactionService(
            productService: mocks.productService,
            transactionObserver: MockTransactionObserver(),
            pendingPurchaseStore: pendingStore,
            accountOwnershipStore: ownershipStore,
            dateProvider: dateProvider,
            settings: settings,
            eventSink: eventSink,
            purchaseStorageScope: scope,
            identityService: identity,
            featureService: features
        )
        let api = RecoverySyncAPI(succeeds: true)
        let localAccessStore = InMemoryLocalPurchaseAccessStore()
        let observer = TransactionObserver(
            api: api,
            features: features,
            identity: identity,
            settings: settings,
            eventSink: eventSink,
            transactionServiceProvider: { service },
            evidenceStore: InMemoryTransactionEvidenceStore(),
            localAccessStore: localAccessStore,
            purchaseStorageScope: scope,
            dateProvider: dateProvider,
            activeStoreOriginalTransactionIDs: { [] }
        )
        return OutcomeOnlyDelegateUpdateHarness(
            appAccountToken: token,
            observer: observer,
            service: service,
            api: api,
            eventSink: eventSink,
            localAccessStore: localAccessStore,
            pendingStore: pendingStore,
            finishes: FinishCounter()
        )
    }

    private func assertProviderUpdateIsIgnored(
        token: ProviderUpdateToken,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let harness = providerUpdateHarness(token: token)
        await harness.handle()

        XCTAssertTrue(harness.api.recordedCustomers.isEmpty, file: file, line: line)
        XCTAssertTrue(harness.evidenceStore.load().isEmpty, file: file, line: line)
        XCTAssertTrue(harness.eventSink.events.isEmpty, file: file, line: line)
        let appliedTransactions = await harness.features.appliedTransactions()
        XCTAssertTrue(appliedTransactions.isEmpty, file: file, line: line)
        let finishCount = await harness.finishes.count()
        XCTAssertEqual(finishCount, 0, file: file, line: line)
        let retainedPending = await harness.service.pendingPurchaseRecord(
            productId: "store-product-1",
            distinctId: "customer-b"
        )
        XCTAssertEqual(retainedPending, harness.pending, file: file, line: line)
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
            localAccessStore: InMemoryLocalPurchaseAccessStore(),
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
            localAccessStore: InMemoryLocalPurchaseAccessStore(),
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
        XCTAssertTrue(evidenceStore.load().isEmpty)
        let finishCount = await finishes.count()
        XCTAssertEqual(finishCount, 0)
    }

    func testProviderUpdateDoesNotResolveAnotherCustomersPendingPurchaseFromNuxieToken() async {
        await assertProviderUpdateIsIgnored(token: .historicalCustomer)
    }

    func testProviderUpdateWithoutAccountTokenDoesNotResolvePendingPurchase() async {
        await assertProviderUpdateIsIgnored(token: .missing)
    }

    func testProviderUpdateWithUnrecognizedAccountTokenDoesNotResolvePendingPurchase() async {
        await assertProviderUpdateIsIgnored(token: .unrecognized)
    }

    func testProviderUpdateWithExactCheckoutTokenResolvesPendingPurchase() async {
        let harness = providerUpdateHarness(token: .exactCheckout)
        await harness.handle()

        XCTAssertTrue(harness.api.recordedCustomers.isEmpty)
        XCTAssertTrue(harness.evidenceStore.load().isEmpty)
        XCTAssertEqual(
            harness.eventSink.events.map(\.name),
            [SystemEventNames.purchaseCompleted]
        )
        XCTAssertEqual(harness.eventSink.routedCaptureCount, 0)
        XCTAssertEqual(harness.eventSink.captureOnlyCount, 1)
        let appliedTransactions = await harness.features.appliedTransactions()
        XCTAssertEqual(appliedTransactions, ["provider-update"])
        let finishCount = await harness.finishes.count()
        XCTAssertEqual(finishCount, 0)
        let consumedPending = await harness.service.pendingPurchaseRecord(
            productId: "store-product-1",
            distinctId: "customer-b"
        )
        XCTAssertNil(consumedPending)
    }

    func testProviderCurrentEntitlementRemainsInConnectorPath() async {
        let harness = providerUpdateHarness(token: .exactCheckout)
        await harness.handle(
            source: .nuxieEntitlementSync(distinctId: "customer-b")
        )

        XCTAssertTrue(harness.api.recordedCustomers.isEmpty)
        XCTAssertTrue(harness.evidenceStore.load().isEmpty)
        XCTAssertTrue(harness.eventSink.events.isEmpty)
        let appliedTransactions = await harness.features.appliedTransactions()
        XCTAssertTrue(appliedTransactions.isEmpty)
        let finishCount = await harness.finishes.count()
        XCTAssertEqual(finishCount, 0)
        let retainedPending = await harness.service.pendingPurchaseRecord(
            productId: "store-product-1",
            distinctId: "customer-b"
        )
        XCTAssertEqual(retainedPending, harness.pending)
    }

    func testUnsignedDelegateFreshRestoreSyncsAndFinishesCurrentEntitlement() async {
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
        let service = TransactionService(
            productService: mocks.productService,
            transactionObserver: MockTransactionObserver(),
            pendingPurchaseStore: InMemoryPendingPurchaseStore(),
            accountOwnershipStore: InMemoryPurchaseAccountOwnershipStore(),
            dateProvider: dateProvider,
            settings: settings,
            eventSink: eventSink,
            purchaseStorageScope: scope,
            identityService: identity,
            featureService: features,
            activeProductEvidenceAuthority: { productId in
                productId == "store-product-1" ? .nativeStoreKit : .readyNoMatch
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
            localAccessStore: InMemoryLocalPurchaseAccessStore(),
            purchaseStorageScope: scope,
            dateProvider: dateProvider,
            activeStoreOriginalTransactionIDs: { [] }
        )
        let finishes = FinishCounter()
        await observer.handleVerifiedTransaction(
            VerifiedStoreTransactionUpdate(
                transactionId: "restored-transaction",
                originalTransactionId: "restored-original",
                productId: "store-product-1",
                appAccountToken: scope.appAccountToken(
                    distinctId: "customer-a"
                ),
                isRevoked: false,
                isUpgraded: false,
                finish: { await finishes.increment() }
            ),
            jwsRepresentation: "restored-jws",
            source: .nuxieEntitlementSync(distinctId: "customer-a")
        )

        XCTAssertEqual(api.recordedCustomers, ["customer-a"])
        let finishCount = await finishes.count()
        XCTAssertEqual(finishCount, 1)
        XCTAssertEqual(
            eventSink.events.map(\.name),
            [SystemEventNames.purchaseSynced]
        )
        XCTAssertTrue(evidenceStore.load().isEmpty)
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
            localAccessStore: InMemoryLocalPurchaseAccessStore(),
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
        let nativeService = TransactionService(
            productService: mocks.productService,
            transactionObserver: MockTransactionObserver(),
            pendingPurchaseStore: InMemoryPendingPurchaseStore(),
            accountOwnershipStore: InMemoryPurchaseAccountOwnershipStore(),
            dateProvider: dateProvider,
            settings: settings,
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
            settings: settings,
            eventSink: RecoveryEventSink(),
            transactionServiceProvider: { nativeService },
            evidenceStore: InMemoryTransactionEvidenceStore(),
            localAccessStore: InMemoryLocalPurchaseAccessStore(),
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

    func testSignedProviderFreshRestoreRemainsConnectorOwnedWithoutCheckoutHistory() async {
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
            localAccessStore: InMemoryLocalPurchaseAccessStore(),
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
            source: .nuxieEntitlementSync(distinctId: "customer-a")
        )

        XCTAssertTrue(api.recordedCustomers.isEmpty)
        let finishCount = await finishes.count()
        XCTAssertEqual(finishCount, 0)
        XCTAssertTrue(eventSink.events.isEmpty)
        XCTAssertTrue(evidenceStore.load().isEmpty)

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
            source: .nuxieEntitlementSync(distinctId: "customer-a")
        )
        XCTAssertTrue(api.recordedCustomers.isEmpty)
        let retainedFinishCount = await finishes.count()
        XCTAssertEqual(retainedFinishCount, 0)
        XCTAssertTrue(evidenceStore.load().isEmpty)
    }

    func testLateNativeStoreUpdateKeepsDurableAuthorityAfterProviderRollout() async {
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
        let token = scope.appAccountToken(distinctId: "customer-a")
        let ownershipStore = InMemoryPurchaseAccountOwnershipStore()
        XCTAssertTrue(ownershipStore.upsert(StoredPurchaseAccountOwnership(
            scope: scope,
            appAccountToken: token,
            distinctId: "customer-a",
            productAuthorities: ["store-product-1": .nativeStoreKit]
        )))
        let eventSink = RecoveryEventSink()
        let features = RecoveryFeatureRecorder()
        let service = TransactionService(
            productService: mocks.productService,
            transactionObserver: MockTransactionObserver(),
            pendingPurchaseStore: InMemoryPendingPurchaseStore(),
            accountOwnershipStore: ownershipStore,
            dateProvider: dateProvider,
            settings: settings,
            eventSink: eventSink,
            purchaseStorageScope: scope,
            identityService: identity,
            featureService: features,
            activeProductEvidenceAuthority: { _ in .providerConnector }
        )
        let api = RecoverySyncAPI(succeeds: true)
        let observer = TransactionObserver(
            api: api,
            features: features,
            identity: identity,
            settings: settings,
            eventSink: eventSink,
            transactionServiceProvider: { service },
            evidenceStore: InMemoryTransactionEvidenceStore(),
            localAccessStore: InMemoryLocalPurchaseAccessStore(),
            purchaseStorageScope: scope,
            dateProvider: dateProvider,
            activeStoreOriginalTransactionIDs: { [] }
        )
        let finishes = FinishCounter()

        await observer.handleVerifiedTransaction(
            VerifiedStoreTransactionUpdate(
                transactionId: "late-native-transaction",
                originalTransactionId: "late-native-original",
                productId: "store-product-1",
                appAccountToken: token,
                isRevoked: false,
                isUpgraded: false,
                finish: { await finishes.increment() }
            ),
            jwsRepresentation: "late-native-jws",
            source: .storeUpdates
        )

        XCTAssertEqual(api.recordedCustomers, ["customer-a"])
        let finishCount = await finishes.count()
        XCTAssertEqual(finishCount, 1)
        XCTAssertEqual(
            eventSink.events.map(\.name),
            [SystemEventNames.purchaseSynced]
        )
    }

    func testOutcomeOnlyDelegateStoreUpdateInsideWindowRecoversExactCheckout() async {
        let harness = outcomeOnlyDelegateUpdateHarness(
            observationExpired: false
        )

        await harness.handle()

        XCTAssertEqual(harness.api.recordedCustomers, ["customer-a"])
        let finishCount = await harness.finishes.count()
        XCTAssertEqual(finishCount, 1)
        let retainedCoordination = harness.pendingStore.load().values.first
        XCTAssertEqual(
            retainedCoordination?.observedTransactionId,
            "outcome-only-update"
        )
        XCTAssertNotNil(retainedCoordination?.completionReportedAt)
        XCTAssertEqual(
            harness.eventSink.events.map(\.name),
            [SystemEventNames.purchaseCompleted, SystemEventNames.purchaseSynced]
        )
        XCTAssertEqual(
            harness.localAccessStore.load()["outcome-only-update"]?.grants
                .map(\.featureId),
            ["premium"]
        )
    }

    func testOutcomeOnlyStoreUpdateBeforeCallbackCompletesPurchaseOnce() async throws {
        let mocks = MockFactory.shared
        let identity = MockIdentityService()
        identity.setDistinctId("customer-a")
        let dateProvider = MockDateProvider()
        let scope = PurchaseStorageScope(
            appIdentifierHash: "app-a",
            environment: "production",
            storeEnvironment: .appStore
        )
        let delegate = MockPurchaseDelegate()
        delegate.simulatedDelay = 0.2
        delegate.purchaseResult = .purchased
        let settings = NuxieRuntimeSettings(
            configuration: NuxieConfiguration(apiKey: "app-a")
        )
        settings.setPurchaseDelegate(delegate)
        let eventSink = RecoveryEventSink()
        let features = RecoveryFeatureRecorder()
        let service = TransactionService(
            productService: mocks.productService,
            transactionObserver: MockTransactionObserver(),
            pendingPurchaseStore: InMemoryPendingPurchaseStore(),
            accountOwnershipStore: InMemoryPurchaseAccountOwnershipStore(),
            dateProvider: dateProvider,
            settings: settings,
            eventSink: eventSink,
            purchaseStorageScope: scope,
            identityService: identity,
            featureService: features
        )
        let api = RecoverySyncAPI(succeeds: true)
        let observer = TransactionObserver(
            api: api,
            features: features,
            identity: identity,
            settings: settings,
            eventSink: eventSink,
            transactionServiceProvider: { service },
            evidenceStore: InMemoryTransactionEvidenceStore(),
            localAccessStore: InMemoryLocalPurchaseAccessStore(),
            purchaseStorageScope: scope,
            dateProvider: dateProvider,
            activeStoreOriginalTransactionIDs: { [] }
        )
        let native = MockStoreProduct(
            id: "store-product-1",
            displayName: "Premium",
            price: 9.99,
            displayPrice: "$9.99"
        )
        var product = StoreProduct(
            productId: "product-1",
            storeProductId: native.id,
            placementId: "placement-1",
            name: native.displayName,
            price: native.displayPrice,
            period: nil,
            productType: native.productType,
            appStoreProduct: native
        )
        product.purchaseContext = commercialContext()
        let purchase = Task { try await service.purchase(product) }
        for _ in 0..<100 where !delegate.purchaseCalled {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(delegate.purchaseCalled)

        let finishes = FinishCounter()
        await observer.handleVerifiedTransaction(
            VerifiedStoreTransactionUpdate(
                transactionId: "race-transaction",
                originalTransactionId: "race-original",
                productId: product.storeProductId,
                appAccountToken: scope.appAccountToken(
                    distinctId: "customer-a"
                ),
                isRevoked: false,
                isUpgraded: false,
                finish: { await finishes.increment() }
            ),
            jwsRepresentation: "race-jws",
            source: .storeUpdates
        )
        _ = try await purchase.value

        XCTAssertEqual(
            eventSink.events.filter {
                $0.name == SystemEventNames.purchaseCompleted
            }.count,
            1
        )
        XCTAssertEqual(eventSink.routedCaptureCount, 1)
        XCTAssertEqual(api.recordedCustomers, ["customer-a"])
        let finishCount = await finishes.count()
        XCTAssertEqual(finishCount, 1)
    }

    func testOutcomeOnlyCallbackBeforeStoreUpdateCompletesPurchaseOnce() async throws {
        let mocks = MockFactory.shared
        let identity = MockIdentityService()
        identity.setDistinctId("customer-a")
        let dateProvider = MockDateProvider()
        let scope = PurchaseStorageScope(
            appIdentifierHash: "app-a",
            environment: "production",
            storeEnvironment: .appStore
        )
        let delegate = MockPurchaseDelegate()
        delegate.simulatedDelay = 0
        delegate.purchaseResult = .purchased
        let settings = NuxieRuntimeSettings(
            configuration: NuxieConfiguration(apiKey: "app-a")
        )
        settings.setPurchaseDelegate(delegate)
        let eventSink = RecoveryEventSink()
        let features = RecoveryFeatureRecorder()
        let service = TransactionService(
            productService: mocks.productService,
            transactionObserver: MockTransactionObserver(),
            pendingPurchaseStore: InMemoryPendingPurchaseStore(),
            accountOwnershipStore: InMemoryPurchaseAccountOwnershipStore(),
            dateProvider: dateProvider,
            settings: settings,
            eventSink: eventSink,
            purchaseStorageScope: scope,
            identityService: identity,
            featureService: features
        )
        let api = RecoverySyncAPI(succeeds: true)
        let observer = TransactionObserver(
            api: api,
            features: features,
            identity: identity,
            settings: settings,
            eventSink: eventSink,
            transactionServiceProvider: { service },
            evidenceStore: InMemoryTransactionEvidenceStore(),
            localAccessStore: InMemoryLocalPurchaseAccessStore(),
            purchaseStorageScope: scope,
            dateProvider: dateProvider,
            activeStoreOriginalTransactionIDs: { [] }
        )
        let native = MockStoreProduct(
            id: "store-product-1",
            displayName: "Premium",
            price: 9.99,
            displayPrice: "$9.99"
        )
        var product = StoreProduct(
            productId: "product-1",
            storeProductId: native.id,
            placementId: "placement-1",
            name: native.displayName,
            price: native.displayPrice,
            period: nil,
            productType: native.productType,
            appStoreProduct: native
        )
        product.purchaseContext = commercialContext()

        _ = try await service.purchase(product)
        XCTAssertEqual(
            eventSink.events.filter {
                $0.name == SystemEventNames.purchaseCompleted
            }.count,
            1
        )
        XCTAssertEqual(eventSink.routedCaptureCount, 1)

        let finishes = FinishCounter()
        await observer.handleVerifiedTransaction(
            VerifiedStoreTransactionUpdate(
                transactionId: "race-transaction",
                originalTransactionId: "race-original",
                productId: product.storeProductId,
                appAccountToken: scope.appAccountToken(
                    distinctId: "customer-a"
                ),
                isRevoked: false,
                isUpgraded: false,
                finish: { await finishes.increment() }
            ),
            jwsRepresentation: "race-jws",
            source: .storeUpdates
        )

        XCTAssertEqual(
            eventSink.events.filter {
                $0.name == SystemEventNames.purchaseCompleted
            }.count,
            1
        )
        XCTAssertEqual(eventSink.routedCaptureCount, 1)
        XCTAssertEqual(api.recordedCustomers, ["customer-a"])
        let finishCount = await finishes.count()
        XCTAssertEqual(finishCount, 1)
    }

    func testCallbackCaptureFailureRetainsDurableCheckoutCompletionForStoreUpdate() async throws {
        let mocks = MockFactory.shared
        let identity = MockIdentityService()
        identity.setDistinctId("customer-a")
        let dateProvider = MockDateProvider()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("callback-capture-failure-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = PurchaseStorageScope(
            appIdentifierHash: "app-a",
            environment: "production",
            storeEnvironment: .appStore
        )
        let delegate = MockPurchaseDelegate()
        delegate.purchaseResult = .purchased
        let settings = NuxieRuntimeSettings(
            configuration: NuxieConfiguration(apiKey: "app-a")
        )
        settings.setPurchaseDelegate(delegate)
        let eventSink = ControlledRecoveryEventSink(captureSucceeds: false)
        let pendingStore = PendingPurchaseStore(
            customStoragePath: root,
            scope: scope
        )
        let service = TransactionService(
            productService: mocks.productService,
            transactionObserver: MockTransactionObserver(),
            pendingPurchaseStore: pendingStore,
            accountOwnershipStore: PurchaseAccountOwnershipStore(
                customStoragePath: root,
                scope: scope
            ),
            dateProvider: dateProvider,
            settings: settings,
            eventSink: eventSink,
            purchaseStorageScope: scope,
            identityService: identity
        )
        let api = RecoverySyncAPI(succeeds: true)
        let evidenceStore = TransactionEvidenceStore(
            customStoragePath: root,
            scope: scope
        )
        let observer = TransactionObserver(
            api: api,
            features: RecoveryFeatureRecorder(),
            identity: identity,
            settings: settings,
            eventSink: eventSink,
            transactionServiceProvider: { service },
            evidenceStore: evidenceStore,
            localAccessStore: LocalPurchaseAccessStore(
                customStoragePath: root,
                scope: scope
            ),
            purchaseStorageScope: scope,
            dateProvider: dateProvider,
            activeStoreOriginalTransactionIDs: { [] }
        )
        let native = MockStoreProduct(
            id: "store-product-1",
            displayName: "Premium",
            price: 9.99,
            displayPrice: "$9.99"
        )
        var product = StoreProduct(
            productId: "product-1",
            storeProductId: native.id,
            placementId: "placement-1",
            name: native.displayName,
            price: native.displayPrice,
            period: nil,
            productType: native.productType,
            appStoreProduct: native
        )
        product.purchaseContext = commercialContext()

        // The commercial purchase succeeded. Capture failure must retain
        // recovery without surfacing a false failure that invites repurchase.
        _ = try await service.purchase(product)
        let retained = try XCTUnwrap(pendingStore.load().values.first)
        XCTAssertNil(retained.completionReportedAt)
        XCTAssertFalse(retained.checkoutCompletionEventId.isEmpty)
        XCTAssertEqual(eventSink.routedAttemptCount, 1)

        eventSink.setCaptureSucceeds(true)
        let finishes = FinishCounter()
        await observer.handleVerifiedTransaction(
            VerifiedStoreTransactionUpdate(
                transactionId: "capture-retry-transaction",
                originalTransactionId: "capture-retry-original",
                productId: product.storeProductId,
                appAccountToken: scope.appAccountToken(
                    distinctId: "customer-a"
                ),
                isRevoked: false,
                isUpgraded: false,
                finish: { await finishes.increment() }
            ),
            jwsRepresentation: "capture-retry-jws",
            source: .storeUpdates
        )

        XCTAssertEqual(eventSink.routedAttemptCount, 1)
        XCTAssertEqual(eventSink.captureOnlyAttemptCount, 1)
        XCTAssertEqual(eventSink.routedCaptureCount, 0)
        XCTAssertEqual(eventSink.captureOnlyCount, 1)
        XCTAssertEqual(
            Set(eventSink.attemptedCompletionEventIds),
            [retained.checkoutCompletionEventId]
        )
        XCTAssertEqual(api.recordedCustomers, ["customer-a"])
        let finishCount = await finishes.count()
        XCTAssertEqual(finishCount, 1)
    }

    func testProviderUpdateRetriesFailedCheckoutCompletionWithoutOwningReceipt() async throws {
        let mocks = MockFactory.shared
        let identity = MockIdentityService()
        identity.setDistinctId("customer-a")
        let dateProvider = MockDateProvider()
        let scope = PurchaseStorageScope(
            appIdentifierHash: "app-a",
            environment: "production",
            storeEnvironment: .appStore
        )
        let delegate = MockPurchaseDelegate()
        delegate.purchaseResult = .purchased
        let settings = NuxieRuntimeSettings(
            configuration: NuxieConfiguration(apiKey: "app-a")
        )
        settings.setPurchaseDelegate(delegate)
        let eventSink = ControlledRecoveryEventSink(captureSucceeds: false)
        let pendingStore = InMemoryPendingPurchaseStore()
        let ownershipStore = InMemoryPurchaseAccountOwnershipStore()
        let features = RecoveryFeatureRecorder()
        let service = TransactionService(
            productService: mocks.productService,
            transactionObserver: MockTransactionObserver(),
            pendingPurchaseStore: pendingStore,
            accountOwnershipStore: ownershipStore,
            dateProvider: dateProvider,
            settings: settings,
            eventSink: eventSink,
            purchaseStorageScope: scope,
            identityService: identity,
            featureService: features,
            activeProductEvidenceAuthority: { _ in .providerConnector }
        )
        let api = RecoverySyncAPI(succeeds: true)
        let observer = TransactionObserver(
            api: api,
            features: features,
            identity: identity,
            settings: settings,
            eventSink: eventSink,
            transactionServiceProvider: { service },
            evidenceStore: InMemoryTransactionEvidenceStore(),
            localAccessStore: InMemoryLocalPurchaseAccessStore(),
            purchaseStorageScope: scope,
            dateProvider: dateProvider,
            activeStoreOriginalTransactionIDs: { [] }
        )
        let native = MockStoreProduct(
            id: "store-product-1",
            displayName: "Premium",
            price: 9.99,
            displayPrice: "$9.99"
        )
        var product = StoreProduct(
            productId: "product-1",
            storeProductId: native.id,
            placementId: "placement-1",
            name: native.displayName,
            price: native.displayPrice,
            period: nil,
            productType: native.productType,
            appStoreProduct: native
        )
        product.purchaseContext = commercialContext()
        product.providerFeatureAccess = "revenuecat"
        product.localEntitlementGrants = [StoreProduct.LocalEntitlementGrant(
            featureId: "premium",
            featureExternalId: "premium",
            allowanceType: "boolean",
            allowance: nil
        )]

        _ = try await service.purchase(product)
        let retained = try XCTUnwrap(pendingStore.load().values.first)
        XCTAssertEqual(retained.state, .checkout)
        XCTAssertNil(retained.completionReportedAt)
        XCTAssertEqual(eventSink.routedAttemptCount, 1)
        let appliedAfterCallback = await features.appliedTransactions()
        XCTAssertEqual(appliedAfterCallback, [
            providerLocalAccessTransactionId(storeProductId: product.storeProductId),
        ])

        eventSink.setCaptureSucceeds(true)
        let finishes = FinishCounter()
        await observer.handleVerifiedTransaction(
            VerifiedStoreTransactionUpdate(
                transactionId: "provider-capture-retry-transaction",
                originalTransactionId: "provider-capture-retry-original",
                productId: product.storeProductId,
                appAccountToken: retained.appAccountToken,
                isRevoked: false,
                isUpgraded: false,
                finish: { await finishes.increment() }
            ),
            jwsRepresentation: "provider-capture-retry-jws",
            source: .storeUpdates
        )

        XCTAssertEqual(eventSink.captureOnlyAttemptCount, 1)
        XCTAssertEqual(eventSink.captureOnlyCount, 1)
        XCTAssertEqual(
            Set(eventSink.attemptedCompletionEventIds),
            [retained.checkoutCompletionEventId]
        )
        let appliedAfterUpdate = await features.appliedTransactions()
        XCTAssertEqual(appliedAfterUpdate, [
            providerLocalAccessTransactionId(storeProductId: product.storeProductId),
        ])
        XCTAssertTrue(api.recordedCustomers.isEmpty)
        let finishCount = await finishes.count()
        XCTAssertEqual(finishCount, 0)
        XCTAssertTrue(pendingStore.load().isEmpty)
    }

    func testRelaunchAfterPreCallbackWindowUsesOnlyStableTokenOwnership() async throws {
        let mocks = MockFactory.shared
        let identity = MockIdentityService()
        identity.setDistinctId("customer-a")
        let dateProvider = MockDateProvider()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pre-callback-relaunch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = PurchaseStorageScope(
            appIdentifierHash: "app-a",
            environment: "production",
            storeEnvironment: .appStore
        )
        let delegate = SuspendedOutcomePurchaseDelegate()
        let settings = NuxieRuntimeSettings(
            configuration: NuxieConfiguration(apiKey: "app-a")
        )
        settings.setPurchaseDelegate(delegate)
        let eventSink = RecoveryEventSink()
        let features = RecoveryFeatureRecorder()
        let service = TransactionService(
            productService: mocks.productService,
            transactionObserver: MockTransactionObserver(),
            pendingPurchaseStore: PendingPurchaseStore(
                customStoragePath: root,
                scope: scope
            ),
            accountOwnershipStore: PurchaseAccountOwnershipStore(
                customStoragePath: root,
                scope: scope
            ),
            dateProvider: dateProvider,
            settings: settings,
            eventSink: eventSink,
            purchaseStorageScope: scope,
            identityService: identity,
            featureService: features
        )
        let native = MockStoreProduct(
            id: "store-product-1",
            displayName: "Premium",
            price: 9.99,
            displayPrice: "$9.99"
        )
        var product = StoreProduct(
            productId: "product-1",
            storeProductId: native.id,
            placementId: "placement-1",
            name: native.displayName,
            price: native.displayPrice,
            period: nil,
            productType: native.productType,
            appStoreProduct: native
        )
        product.purchaseContext = commercialContext()
        product.localEntitlementGrants = [
            StoreProduct.LocalEntitlementGrant(
                featureId: "premium",
                featureExternalId: "premium",
                allowanceType: "boolean",
                allowance: nil
            ),
        ]
        let purchase = Task { try await service.purchase(product) }
        for _ in 0..<100 where await delegate.calls() < 1 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let delegateCalls = await delegate.calls()
        XCTAssertEqual(delegateCalls, 1)

        identity.setDistinctId("customer-b")
        let timelyPurchase = Task { try await service.purchase(product) }
        for _ in 0..<100 where await delegate.calls() < 2 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let api = RecoverySyncAPI(succeeds: true)
        let localAccessStore = InMemoryLocalPurchaseAccessStore()
        let finishes = FinishCounter()
        let timelyRelaunch = TransactionService(
            productService: mocks.productService,
            transactionObserver: MockTransactionObserver(),
            pendingPurchaseStore: PendingPurchaseStore(
                customStoragePath: root,
                scope: scope
            ),
            accountOwnershipStore: PurchaseAccountOwnershipStore(
                customStoragePath: root,
                scope: scope
            ),
            dateProvider: dateProvider,
            settings: settings,
            eventSink: eventSink,
            purchaseStorageScope: scope,
            identityService: identity,
            featureService: features
        )
        let timelyObserver = TransactionObserver(
            api: api,
            features: features,
            identity: identity,
            settings: settings,
            eventSink: eventSink,
            transactionServiceProvider: { timelyRelaunch },
            evidenceStore: InMemoryTransactionEvidenceStore(),
            localAccessStore: localAccessStore,
            purchaseStorageScope: scope,
            dateProvider: dateProvider,
            activeStoreOriginalTransactionIDs: { [] }
        )
        await timelyObserver.handleVerifiedTransaction(
            VerifiedStoreTransactionUpdate(
                transactionId: "inside-window-transaction",
                originalTransactionId: "inside-window-original",
                productId: product.storeProductId,
                appAccountToken: scope.appAccountToken(
                    distinctId: "customer-b"
                ),
                isRevoked: false,
                isUpgraded: false,
                finish: { await finishes.increment() }
            ),
            jwsRepresentation: "inside-window-jws",
            source: .storeUpdates
        )
        XCTAssertEqual(
            eventSink.events.map(\.name),
            [
                SystemEventNames.purchaseCompleted,
                SystemEventNames.purchaseSynced,
            ]
        )
        XCTAssertEqual(
            localAccessStore.load()["inside-window-transaction"]?
                .grants.map(\.featureId),
            ["premium"]
        )

        dateProvider.advance(
            by: TransactionService.outcomeOnlyStoreKitObservationTTL + 1
        )
        identity.setDistinctId("customer-a")
        let relaunchedService = TransactionService(
            productService: mocks.productService,
            transactionObserver: MockTransactionObserver(),
            pendingPurchaseStore: PendingPurchaseStore(
                customStoragePath: root,
                scope: scope
            ),
            accountOwnershipStore: PurchaseAccountOwnershipStore(
                customStoragePath: root,
                scope: scope
            ),
            dateProvider: dateProvider,
            settings: settings,
            eventSink: eventSink,
            purchaseStorageScope: scope,
            identityService: identity,
            featureService: features
        )
        let observer = TransactionObserver(
            api: api,
            features: features,
            identity: identity,
            settings: settings,
            eventSink: eventSink,
            transactionServiceProvider: { relaunchedService },
            evidenceStore: InMemoryTransactionEvidenceStore(),
            localAccessStore: localAccessStore,
            purchaseStorageScope: scope,
            dateProvider: dateProvider,
            activeStoreOriginalTransactionIDs: { [] }
        )
        await observer.handleVerifiedTransaction(
            VerifiedStoreTransactionUpdate(
                transactionId: "post-crash-transaction",
                originalTransactionId: "post-crash-original",
                productId: product.storeProductId,
                appAccountToken: scope.appAccountToken(
                    distinctId: "customer-a"
                ),
                isRevoked: false,
                isUpgraded: false,
                finish: { await finishes.increment() }
            ),
            jwsRepresentation: "post-crash-jws",
            source: .storeUpdates
        )

        XCTAssertEqual(
            api.recordedCustomers,
            ["customer-b", "customer-a"]
        )
        let finishCount = await finishes.count()
        XCTAssertEqual(finishCount, 2)
        XCTAssertEqual(
            eventSink.events.map(\.name),
            [
                SystemEventNames.purchaseCompleted,
                SystemEventNames.purchaseSynced,
                SystemEventNames.purchaseSynced,
            ]
        )
        XCTAssertNil(localAccessStore.load()["post-crash-transaction"])
        XCTAssertTrue(PendingPurchaseStore(
            customStoragePath: root,
            scope: scope
        ).load().isEmpty)

        purchase.cancel()
        timelyPurchase.cancel()
        _ = try? await purchase.value
        _ = try? await timelyPurchase.value
    }

    func testExpiredOutcomeOnlyCorrelationStillSyncsAndFinishesByStableToken() async {
        let harness = outcomeOnlyDelegateUpdateHarness(
            observationExpired: true
        )

        await harness.handle()

        XCTAssertEqual(harness.api.recordedCustomers, ["customer-a"])
        let finishCount = await harness.finishes.count()
        XCTAssertEqual(finishCount, 1)
        XCTAssertTrue(harness.pendingStore.load().isEmpty)
        XCTAssertEqual(
            harness.eventSink.events.map(\.name),
            [SystemEventNames.purchaseSynced]
        )
        XCTAssertNil(
            harness.localAccessStore.load()["outcome-only-update"]
        )
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
            localAccessStore: InMemoryLocalPurchaseAccessStore(),
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
        XCTAssertEqual(store.load()["customer::store-product-1"], record)
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
            localEntitlementGrants: [],
            isRevoked: false
        )

        XCTAssertTrue(liveStore.save([evidence.transactionId: evidence]))
        XCTAssertEqual(liveStore.load()[evidence.transactionId], evidence)
        XCTAssertTrue(testStore.load().isEmpty)

        let liveAccess = LocalPurchaseAccessStore(
            customStoragePath: root,
            scope: live
        )
        let testAccess = LocalPurchaseAccessStore(
            customStoragePath: root,
            scope: test
        )
        let access = StoredLocalPurchaseAccess(
            scope: live,
            transactionId: "transaction",
            originalTransactionId: "original",
            productId: "product",
            distinctId: "customer",
            grants: [],
            state: .active
        )
        XCTAssertTrue(liveAccess.save([access.transactionId: access]))
        XCTAssertNotNil(liveAccess.load()[access.transactionId])
        XCTAssertTrue(testAccess.load().isEmpty)

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
        XCTAssertNotNil(liveRecovery.load()["recovery"])
        XCTAssertTrue(testRecovery.load().isEmpty)

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
            evidenceAuthority: .outcomeOnlyDelegate,
            storeKitObservationDeadline: mocks.dateProvider.date(
                byAddingTimeInterval: TransactionService
                    .outcomeOnlyStoreKitObservationTTL,
                to: mocks.dateProvider.now()
            )
        )
        XCTAssertTrue(recoveryStore.save(["customer-a::store-product-1": recovery]))

        let accessStore = InMemoryLocalPurchaseAccessStore()
        let evidenceStore = InMemoryTransactionEvidenceStore()
        let features = FeatureService(
            api: mocks.nuxieApi,
            identity: mocks.identityService,
            profile: mocks.profileService,
            dateProvider: mocks.dateProvider,
            featureInfo: FeatureInfo(),
            cacheTTL: 300,
            localPurchaseAccessStore: accessStore
        )
        let settings = NuxieRuntimeSettings(
            configuration: NuxieConfiguration(apiKey: "app-a")
        )
        settings.setPurchaseDelegate(MockPurchaseDelegate())
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
            localAccessStore: accessStore,
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
        let retainedCoordination = recoveryStore.load().values.first
        XCTAssertEqual(
            retainedCoordination?.observedTransactionId,
            evidence.transactionId
        )
        XCTAssertNil(retainedCoordination?.completionReportedAt)
        XCTAssertEqual(
            evidenceStore.load()[evidence.transactionId]?.commercialContext,
            commercialContext()
        )
        XCTAssertEqual(
            accessStore.load()[evidence.transactionId]?.distinctId,
            "customer-a"
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
            localAccessStore: InMemoryLocalPurchaseAccessStore(),
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
            recoveryStore.load()["customer-a::store-product-1"],
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
            localAccessStore: InMemoryLocalPurchaseAccessStore(),
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
        XCTAssertTrue(store.load().isEmpty)
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
            localAccessStore: InMemoryLocalPurchaseAccessStore(),
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
        XCTAssertEqual(store.load()["customer-a::store-product-1"], recovery)
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
            localEntitlementGrants: [],
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
            localAccessStore: InMemoryLocalPurchaseAccessStore(),
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
        XCTAssertTrue(recoveryStore.load().isEmpty)
        XCTAssertEqual(evidenceStore.load()[evidence.transactionId]?.finishRequired, false)
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
            "purchase"
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
            localEntitlementGrants: [],
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
                localAccessStore: LocalPurchaseAccessStore(
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
        ).load()[evidence.transactionId])
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
        ).load().isEmpty)
        XCTAssertTrue(finalEvents.events.filter {
            $0.name == SystemEventNames.purchaseCompleted
        }.isEmpty)
    }

    func testExpiredReceiptEvidenceIsPrunedWithoutCrossingScope() async {
        let mocks = MockFactory.shared
        mocks.identityService.setDistinctId("customer-a")
        let scope = PurchaseStorageScope(
            appIdentifierHash: "app-a",
            environment: "production",
            storeEnvironment: .appStore
        )
        let evidenceStore = InMemoryTransactionEvidenceStore()
        let expired = StoredTransactionEvidence(
            scope: scope,
            transactionJws: "expired-jws",
            transactionId: "expired",
            originalTransactionId: "original",
            productId: "product",
            distinctId: "customer-a",
            recordedAt: Date(timeIntervalSince1970: 0),
            localEntitlementGrants: [],
            isRevoked: false
        )
        XCTAssertTrue(evidenceStore.save([expired.transactionId: expired]))
        let features = FeatureService(
            api: mocks.nuxieApi,
            identity: mocks.identityService,
            profile: mocks.profileService,
            dateProvider: mocks.dateProvider,
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
        let observer = TransactionObserver(
            api: RecoverySyncAPI(succeeds: false),
            features: features,
            identity: mocks.identityService,
            settings: settings,
            eventSink: RecoveryEventSink(),
            transactionServiceProvider: { service },
            evidenceStore: evidenceStore,
            localAccessStore: InMemoryLocalPurchaseAccessStore(),
            purchaseStorageScope: scope,
            dateProvider: mocks.dateProvider,
            activeStoreOriginalTransactionIDs: { [] }
        )

        await observer.retryStoredEvidence()

        XCTAssertTrue(evidenceStore.load().isEmpty)
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
            localEntitlementGrants: [],
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
                localAccessStore: InMemoryLocalPurchaseAccessStore(),
                purchaseStorageScope: scope,
                dateProvider: mocks.dateProvider,
                activeStoreOriginalTransactionIDs: { [] }
            )
        }

        await makeObserver().retryStoredEvidence()
        XCTAssertNil(evidenceStore.load()[evidence.transactionId]?
            .completionDeliveredAt)
        XCTAssertTrue(events.captures.isEmpty)

        events.setCaptureSucceeds(true)
        evidenceStore.setSaveSucceeds(false)
        await makeObserver().retryStoredEvidence()
        XCTAssertNil(evidenceStore.load()[evidence.transactionId]?
            .completionDeliveredAt)
        XCTAssertEqual(events.captures.count, 1)

        evidenceStore.setSaveSucceeds(true)
        await makeObserver().retryStoredEvidence()
        XCTAssertNotNil(evidenceStore.load()[evidence.transactionId]?
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
            localEntitlementGrants: [],
            isRevoked: false,
            commercialContext: commercialContext(),
            backendSyncedAt: mocks.dateProvider.now()
        )
        let evidenceStore = InMemoryTransactionEvidenceStore()
        XCTAssertTrue(evidenceStore.save([evidence.transactionId: evidence]))
        let eventStore = MockEventStore()
        let eventLog = EventLog(
            identity: mocks.identityService,
            sessions: MockSessionService(),
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
            localAccessStore: InMemoryLocalPurchaseAccessStore(),
            purchaseStorageScope: scope,
            dateProvider: mocks.dateProvider,
            activeStoreOriginalTransactionIDs: { [] }
        )

        await observer.retryStoredEvidence()
        let eventId = await observer.purchaseCompletionEventId(
            transactionId: evidence.transactionId
        )

        XCTAssertTrue(evidenceStore.load().isEmpty)
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
            localEntitlementGrants: [],
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
            localAccessStore: InMemoryLocalPurchaseAccessStore(),
            purchaseStorageScope: scope,
            dateProvider: mocks.dateProvider,
            activeStoreOriginalTransactionIDs: { [] }
        )

        await observer.retryStoredEvidence()

        XCTAssertEqual(api.recordedCustomers, ["customer-a"])
        let retained = evidenceStore.load()[evidence.transactionId]
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
            localEntitlementGrants: [],
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
            localAccessStore: InMemoryLocalPurchaseAccessStore(),
            purchaseStorageScope: scope,
            dateProvider: mocks.dateProvider,
            activeStoreOriginalTransactionIDs: { [] }
        )

        await observer.retryStoredEvidence()

        let retained = evidenceStore.load()[evidence.transactionId]
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
            localEntitlementGrants: [],
            isRevoked: false
        )
        let evidenceStore = InMemoryTransactionEvidenceStore()
        XCTAssertTrue(evidenceStore.save([evidence.transactionId: evidence]))
        let api = ControlledConcurrentRecoverySyncAPI()
        let entitlementScans = AsyncCallCounter()
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
            localAccessStore: InMemoryLocalPurchaseAccessStore(),
            purchaseStorageScope: scope,
            dateProvider: mocks.dateProvider,
            activeStoreOriginalTransactionIDs: {
                await entitlementScans.increment()
                return []
            }
        )

        let firstRetry = Task { await observer.retryStoredEvidence() }
        await api.waitForFirstRequest()
        let concurrentRetry = Task { await observer.retryStoredEvidence() }
        _ = await api.waitForRequestCount(2)
        await api.release()
        await firstRetry.value
        await concurrentRetry.value

        let recordedCustomers = await api.recordedCustomers()
        let scanCount = await entitlementScans.count()
        XCTAssertEqual(recordedCustomers, ["customer-a"])
        XCTAssertEqual(scanCount, 2)
        XCTAssertTrue(evidenceStore.load().isEmpty)
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
            localAccessStore: InMemoryLocalPurchaseAccessStore(),
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
            localAccessStore: InMemoryLocalPurchaseAccessStore(),
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
            localEntitlementGrants: [],
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
            localAccessStore: InMemoryLocalPurchaseAccessStore(),
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
        XCTAssertNotNil(evidenceStore.load()[evidence.transactionId])
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
            localEntitlementGrants: [],
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
            localAccessStore: InMemoryLocalPurchaseAccessStore(),
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
            evidenceStore.load()[evidence.transactionId]?.transactionJws,
            "signed-jws"
        )
        XCTAssertNil(evidenceStore.load()[evidence.transactionId]?.backendSyncedAt)
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
            localAccessStore: InMemoryLocalPurchaseAccessStore(),
            purchaseStorageScope: scope,
            dateProvider: mocks.dateProvider,
            activeStoreOriginalTransactionIDs: { [] }
        )
        await nextSetup.retryStoredEvidence()
        XCTAssertTrue(evidenceStore.load().isEmpty)
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
            localAccessStore: InMemoryLocalPurchaseAccessStore(),
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
            localEntitlementGrants: [],
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
                localAccessStore: InMemoryLocalPurchaseAccessStore(),
                purchaseStorageScope: scope,
                dateProvider: mocks.dateProvider,
                activeStoreOriginalTransactionIDs: { [] }
            )
        }

        await makeObserver().retryStoredEvidence()
        await makeObserver().retryStoredEvidence()
        let retained = evidenceStore.load()[evidence.transactionId]
        XCTAssertNotNil(retained?.backendSyncedAt)
        XCTAssertNil(retained?.completionDeliveredAt)
        XCTAssertEqual(retained?.transactionJws, "")
        XCTAssertEqual(api.recordedCustomers, ["customer-a"])
        XCTAssertTrue(events.events.filter {
            $0.name == SystemEventNames.purchaseCompleted
        }.isEmpty)

        mocks.identityService.setDistinctId("customer-a")
        await makeObserver().retryStoredEvidence()
        XCTAssertTrue(evidenceStore.load().isEmpty)
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
            localEntitlementGrants: [],
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
            localAccessStore: InMemoryLocalPurchaseAccessStore(),
            purchaseStorageScope: scope,
            dateProvider: mocks.dateProvider,
            activeStoreOriginalTransactionIDs: { [] }
        )

        let firstRemoval = await observer.removeEvidence(
            transactionId: evidence.transactionId
        )
        XCTAssertFalse(firstRemoval)
        XCTAssertNotNil(evidenceStore.load()[evidence.transactionId])
        evidenceStore.setSaveSucceeds(true)
        let secondRemoval = await observer.removeEvidence(
            transactionId: evidence.transactionId
        )
        XCTAssertTrue(secondRemoval)
        XCTAssertTrue(evidenceStore.load().isEmpty)
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
            localEntitlementGrants: [],
            isRevoked: false
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
            localAccessStore: InMemoryLocalPurchaseAccessStore(),
            purchaseStorageScope: scope,
            dateProvider: mocks.dateProvider,
            activeStoreOriginalTransactionIDs: { [] }
        )

        await observer.retryStoredEvidence()
        XCTAssertNotNil(evidenceStore.load()[expired.transactionId])
        XCTAssertTrue(api.recordedCustomers.isEmpty)

        evidenceStore.setSaveSucceeds(true)
        await observer.retryStoredEvidence()
        XCTAssertTrue(evidenceStore.load().isEmpty)
        XCTAssertTrue(api.recordedCustomers.isEmpty)
    }
}
