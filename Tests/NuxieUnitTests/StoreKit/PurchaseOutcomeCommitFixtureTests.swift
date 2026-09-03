import Foundation
import XCTest
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

private struct PurchaseCommitTerminalOutcome: Decodable, Equatable, Sendable {
    let kind: String
    let source: String
    let reason: String?
    let terminal: Bool
}

private struct PurchaseOutcomeCommitFixture: Decodable {
    struct Product: Decodable {
        struct LocalEntitlementGrant: Decodable {
            let featureId: String
        }

        let productId: String
        let storeProductId: String
        let placementId: String
        let experienceId: String
        let experienceVersion: String
        let displayPrice: String
        let price: Double
        let localEntitlementGrants: [LocalEntitlementGrant]
    }

    struct Evidence: Decodable {
        let identity: String
        let originalIdentity: String
        let signedPayload: String
        let product: String
    }

    struct Action: Decodable {
        let entry: String
        let operation: String?
        let outcome: String
        let evidence: String?
        let product: String?
        let reason: String?
        let carrierCaptureSucceeds: Bool?
        let expectedCarrierCaptureAttemptDelta: Int?
    }

    struct Expectation: Decodable {
        let successfulCommits: Int
        let uniqueEvidenceRows: Int
        let journeyAdvancements: Int
        let purchaseCompletedEvents: Int
        let restoreCompletedEvents: Int
        let purchaseFailedEvents: Int
        let serverSyncRequests: Int
        let scheduledSyncTasks: Int
        let pendingRecords: Int
        let overlayEverPresent: Bool
        let storeEntitlementQueries: Int
        let storeFinalizationCalls: Int?
        let checkoutErrors: [String]
        let committerTerminalOutcomes: [PurchaseCommitTerminalOutcome]
        let completionSources: [String]
        let completionCarriesEvidenceIdentity: Bool
        let completionCarriesProductMapping: Bool
        let completionEventIdsDistinct: Bool?
        let minimumCarrierCaptureAttempts: Int?
        let successfulCarrierCaptures: Int?
        let carrierCaptureOperationIdentityCount: Int?
        let retainedCarrierRetryRoundLimit: Int?
        let carrierCaptureAttemptsStopAtRetryLimit: Bool?
    }

    struct Case: Decodable {
        let name: String
        let actions: [Action]
        let expect: Expectation
    }

    let suite: String
    let version: Int
    let sources: [String]
    let products: [String: Product]
    let evidence: [String: Evidence]
    let cases: [Case]
}

private struct RecordedPurchaseOutcomeEvent: Sendable {
    let name: String
    let routed: Bool
    let source: String?
    let eventId: String?
    let transactionId: String?
    let productId: String?
    let storeProductId: String?
    let placementId: String?
    let experienceId: String?
    let displayPrice: String?
    let price: Double?
}

private actor PurchaseOutcomeCaptureGate {
    private var armed = false
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func suspendNextPurchaseCompletion() {
        armed = true
        started = false
        released = false
    }

    func pauseIfArmed(eventName: String) async {
        guard eventName == SystemEventNames.purchaseCompleted, armed else { return }
        armed = false
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private final class PurchaseOutcomeEventSink {
    private let lock = NSLock()
    private let captureGate = PurchaseOutcomeCaptureGate()
    private var storage: [RecordedPurchaseOutcomeEvent] = []
    private var routedCaptureResult = true
    private var carrierCaptureResult = true
    private var routedCaptureAttempts = 0
    private var captureOnlyAttempts = 0
    private var captureOnlyEventIds: [String] = []
    private var successfulCarrierCaptures = 0

    func emit(_ name: String, properties: [String: Any]?) {
        append(name: name, properties: properties, eventId: nil, routed: false)
    }

    func capture(
        _ request: StableSystemEventCaptureRequest
    ) async -> Bool {
        await captureGate.pauseIfArmed(eventName: request.name)
        let routes = lock.withLock {
            routedCaptureAttempts += 1
            return routedCaptureResult
        }
        if routes {
            append(
                name: request.name,
                properties: request.properties,
                eventId: request.eventId,
                routed: true
            )
        }
        return routes
    }

    func captureOnly(
        _ request: StableSystemEventCaptureRequest
    ) async -> Bool {
        await captureGate.pauseIfArmed(eventName: request.name)
        let captures = lock.withLock {
            captureOnlyAttempts += 1
            captureOnlyEventIds.append(request.eventId)
            return carrierCaptureResult
        }
        guard captures else { return false }
        if append(
            name: request.name,
            properties: request.properties,
            eventId: request.eventId,
            routed: false
        ) {
            lock.withLock { successfulCarrierCaptures += 1 }
        }
        return true
    }

    func setRoutedCaptureResult(_ result: Bool) {
        lock.withLock { routedCaptureResult = result }
    }

    func setCarrierCaptureResult(_ result: Bool) {
        lock.withLock { carrierCaptureResult = result }
    }

    func suspendNextPurchaseCompletionCapture() async {
        await captureGate.suspendNextPurchaseCompletion()
    }

    func waitUntilPurchaseCompletionCaptureStarts() async {
        await captureGate.waitUntilStarted()
    }

    func releasePurchaseCompletionCapture() async {
        await captureGate.release()
    }

    var routedAttemptCount: Int {
        lock.withLock { routedCaptureAttempts }
    }

    var captureOnlyAttemptCount: Int {
        lock.withLock { captureOnlyAttempts }
    }

    var successfulCarrierCaptureCount: Int {
        lock.withLock { successfulCarrierCaptures }
    }

    var carrierCaptureOperationIdentityCount: Int {
        lock.withLock { Set(captureOnlyEventIds).count }
    }

    func events(named name: String) -> [RecordedPurchaseOutcomeEvent] {
        lock.withLock { storage.filter { $0.name == name } }
    }

    @discardableResult
    private func append(
        name: String,
        properties: [String: Any]?,
        eventId: String?,
        routed: Bool
    ) -> Bool {
        let event = RecordedPurchaseOutcomeEvent(
            name: name,
            routed: routed,
            source: properties?["source"] as? String,
            eventId: eventId,
            transactionId: properties?["transaction_id"] as? String,
            productId: properties?["product_id"] as? String,
            storeProductId: properties?["store_product_id"] as? String,
            placementId: properties?["placement_id"] as? String,
            experienceId: properties?["experience_id"] as? String,
            displayPrice: properties?["display_price"] as? String,
            price: properties?["price"] as? Double
        )
        return lock.withLock {
            if let eventId,
               let index = storage.firstIndex(where: { $0.eventId == eventId }) {
                // Stable EventLog identity is idempotent. A later successful
                // routed capture upgrades the one durable carrier in place.
                if routed, !storage[index].routed {
                    storage[index] = event
                }
                return false
            } else {
                storage.append(event)
                return true
            }
        }
    }
}

extension PurchaseOutcomeEventSink: SystemEventSink, @unchecked Sendable {}

private final class RecordingPurchaseEvidenceStore {
    private let lock = NSLock()
    private var entries: [String: StoredTransactionEvidence] = [:]
    private var persistedTransactionIds: Set<String> = []

    func load() -> StoreReadResult<[String: StoredTransactionEvidence]> {
        lock.withLock { .value(entries) }
    }

    @discardableResult
    func save(_ entries: [String: StoredTransactionEvidence]) -> Bool {
        lock.withLock {
            self.entries = entries
            persistedTransactionIds.formUnion(entries.keys)
        }
        return true
    }

    var uniquePersistedCount: Int {
        lock.withLock { persistedTransactionIds.count }
    }

    func evidence(transactionId: String) -> StoredTransactionEvidence? {
        lock.withLock { entries[transactionId] }
    }
}

extension RecordingPurchaseEvidenceStore:
    TransactionEvidenceStoreProtocol,
    @unchecked Sendable
{}

private final class RecordingPendingPurchaseStore {
    private let lock = NSLock()
    private var entries: [String: PendingPurchaseRecord] = [:]

    func load() -> StoreReadResult<[String: PendingPurchaseRecord]> {
        lock.withLock { .value(entries) }
    }

    @discardableResult
    func save(_ entries: [String: PendingPurchaseRecord]) -> Bool {
        lock.withLock { self.entries = entries }
        return true
    }

    var count: Int { lock.withLock { entries.count } }
}

extension RecordingPendingPurchaseStore:
    PendingPurchaseStoreProtocol,
    @unchecked Sendable
{}

private actor PurchaseOutcomeSyncAPI {
    private var requests: [(transactionJwt: String, distinctId: String)] = []
    private var responseSuccesses: [Bool] = []

    func setResponseSuccesses(_ successes: [Bool]) {
        responseSuccesses = successes
    }

    func syncTransaction(
        transactionJwt: String,
        distinctId: String
    ) async throws -> PurchaseResponse {
        requests.append((transactionJwt, distinctId))
        let success = responseSuccesses.isEmpty
            ? true
            : responseSuccesses.removeFirst()
        return PurchaseResponse(
            success: success,
            customerId: distinctId,
            features: nil,
            error: success ? nil : "fixture receipt rejection"
        )
    }

    var requestCount: Int { requests.count }
    var requestedTransactionJWSs: [String] { requests.map(\.transactionJwt) }
}

extension PurchaseOutcomeSyncAPI: PurchaseSynchronizing {}

private final class PurchaseOutcomeSyncTaskProbe {
    private let lock = NSLock()
    private var scheduledTransactionIds: [String] = []

    func record(transactionId: String) {
        lock.withLock { scheduledTransactionIds.append(transactionId) }
    }

    var count: Int { lock.withLock { scheduledTransactionIds.count } }
}

extension PurchaseOutcomeSyncTaskProbe: @unchecked Sendable {}

private actor PurchaseOutcomeFeatureService {
    func getCached(featureId: String, entityId: String?) async -> FeatureAccess? {
        _ = featureId
        _ = entityId
        return nil
    }

    func getAllCached() async -> [String: FeatureAccess] { [:] }

    func check(
        featureId: String,
        requiredBalance: Double?,
        entityId: String?
    ) async throws -> FeatureCheckResult {
        _ = featureId
        _ = requiredBalance
        _ = entityId
        throw NuxieNetworkError.invalidResponse
    }

    func checkWithCache(
        featureId: String,
        requiredBalance: Double?,
        entityId: String?,
        forceRefresh: Bool
    ) async throws -> FeatureAccess {
        _ = featureId
        _ = requiredBalance
        _ = entityId
        _ = forceRefresh
        return .notFound
    }

    func clearCache() async {}
    func handleUserChange(from oldDistinctId: String, to newDistinctId: String) async {}
    func syncFeatureInfo() async {}
    func updateFromPurchase(_ features: [PurchaseFeature], distinctId: String) async {}
}

extension PurchaseOutcomeFeatureService: FeatureServiceProtocol {}

private actor PurchaseOutcomeProjectionProbe {
    private var observedOverlay = false

    func observe(_ present: Bool) {
        observedOverlay = observedOverlay || present
    }

    var overlayEverPresent: Bool { observedOverlay }
}

private final class PurchaseOutcomeFinalizationProbe {
    private let lock = NSLock()
    private var finalizationCount = 0

    func finalize() async {
        lock.withLock { finalizationCount += 1 }
    }

    var count: Int { lock.withLock { finalizationCount } }
}

extension PurchaseOutcomeFinalizationProbe: @unchecked Sendable {}

private actor PurchaseOutcomeStoreRecoveryProbe {
    private var currentEntitlements: [StoreTransactionRecoveryItem] = []
    private var storeEntitlementQueryCount = 0

    func enqueueCurrentEntitlement(_ item: StoreTransactionRecoveryItem) {
        currentEntitlements.append(item)
    }

    func drainUnfinished() -> [StoreTransactionRecoveryItem] {
        []
    }

    func queryCurrentEntitlements() -> [StoreTransactionRecoveryItem] {
        storeEntitlementQueryCount += 1
        defer { currentEntitlements.removeAll() }
        return currentEntitlements
    }

    var entitlementQueryCount: Int { storeEntitlementQueryCount }
}

private final class PurchaseOutcomeStoreAdapter {
    private let lock = NSLock()
    private var nextPurchaseResult: NativePurchaseResult = .cancelled
    private var purchaseCalls = 0
    private var restoreCalls = 0

    func setPurchaseResult(_ result: NativePurchaseResult) {
        lock.withLock { nextPurchaseResult = result }
    }

    func purchase(product: StoreProduct) async -> NativePurchaseResult {
        _ = product
        return lock.withLock {
            purchaseCalls += 1
            return nextPurchaseResult
        }
    }

    func restorePurchases() async -> NativeRestoreResult {
        lock.withLock {
            restoreCalls += 1
            return .noPurchases
        }
    }

    var purchaseCallCount: Int { lock.withLock { purchaseCalls } }
    var restoreCallCount: Int { lock.withLock { restoreCalls } }
}

extension PurchaseOutcomeStoreAdapter: NativeStoreKitPurchasing, @unchecked Sendable {}

private actor PurchaseOutcomeDelegate {
    private var purchaseResult: PurchaseResult = .purchased
    private var restoreResult: RestoreResult = .restored

    func setPurchaseResult(_ result: PurchaseResult) {
        purchaseResult = result
    }

    func setRestoreResult(_ result: RestoreResult) {
        restoreResult = result
    }

    func purchase(product: StoreProduct) async -> PurchaseResult {
        _ = product
        return purchaseResult
    }

    func restorePurchases() async -> RestoreResult { restoreResult }
}

extension PurchaseOutcomeDelegate: NuxiePurchaseDelegate {}

private actor PurchaseOutcomeCommitRecorder {
    private let observer: TransactionObserver
    private var terminalOutcomes: [PurchaseCommitTerminalOutcome] = []

    init(observer: TransactionObserver) {
        self.observer = observer
    }

    // The fixture owns the real observer lifecycle directly. This seam exists
    // only to observe the TransactionService -> committer boundary.
    func startListening() {}

    func stopListening() async {
        await observer.stopListening()
    }

    func commit(_ outcome: PurchaseOutcome) async -> PurchaseCommitResult {
        let result = await observer.commit(outcome)
        switch outcome {
        case .cancelled(let source):
            terminalOutcomes.append(PurchaseCommitTerminalOutcome(
                kind: "cancelled",
                source: source.rawValue,
                reason: nil,
                terminal: result.isTerminal
            ))
        case .pending(let source):
            terminalOutcomes.append(PurchaseCommitTerminalOutcome(
                kind: "pending",
                source: source.rawValue,
                reason: nil,
                terminal: result.isTerminal
            ))
        case .failed(let reason, let source):
            terminalOutcomes.append(PurchaseCommitTerminalOutcome(
                kind: "failed",
                source: source.rawValue,
                reason: reason,
                terminal: result.isTerminal
            ))
        case .verified, .external:
            break
        }
        return result
    }

    func syncCurrentEntitlements(distinctId: String) async {
        await observer.syncCurrentEntitlements(distinctId: distinctId)
    }

    var observedTerminalOutcomes: [PurchaseCommitTerminalOutcome] {
        terminalOutcomes
    }
}

extension PurchaseOutcomeCommitRecorder: TransactionObserverProtocol {}

private struct PurchaseOutcomeDateProvider {
    private let date = Date(timeIntervalSince1970: 2_000_000_000)

    func now() -> Date { date }
    func timeIntervalSince(_ date: Date) -> TimeInterval {
        self.date.timeIntervalSince(date)
    }
    func date(byAddingTimeInterval interval: TimeInterval, to date: Date) -> Date {
        date.addingTimeInterval(interval)
    }
}

extension PurchaseOutcomeDateProvider: DateProviderProtocol {}

private final class PurchaseOutcomeFixtureHarness: @unchecked Sendable {
    let observer: TransactionObserver
    let commitRecorder: PurchaseOutcomeCommitRecorder
    let service: TransactionService
    let evidenceStore = RecordingPurchaseEvidenceStore()
    let pendingStore = RecordingPendingPurchaseStore()
    let eventSink = PurchaseOutcomeEventSink()
    let syncAPI = PurchaseOutcomeSyncAPI()
    let syncTaskProbe = PurchaseOutcomeSyncTaskProbe()
    let projection = PurchaseOutcomeProjectionProbe()
    let finalizationProbe = PurchaseOutcomeFinalizationProbe()
    let storeRecovery = PurchaseOutcomeStoreRecoveryProbe()
    let storeAdapter = PurchaseOutcomeStoreAdapter()
    let delegate = PurchaseOutcomeDelegate()
    let identity = MockIdentityService()
    let scope: PurchaseStorageScope

    private let products: [String: PurchaseOutcomeCommitFixture.Product]
    private let evidence: [String: PurchaseOutcomeCommitFixture.Evidence]
    private let vectorName: String
    private let minimumCarrierCaptureAttempts: Int?
    private(set) var retainedRetryCaptureAttemptDeltas: [Int] = []

    init(
        fixture: PurchaseOutcomeCommitFixture,
        vector: PurchaseOutcomeCommitFixture.Case,
        vectorIndex: Int
    ) {
        products = fixture.products
        evidence = fixture.evidence
        vectorName = vector.name
        minimumCarrierCaptureAttempts = vector.expect.minimumCarrierCaptureAttempts
        identity.setDistinctId("fixture-customer")
        scope = PurchaseStorageScope(
            appIdentifierHash: "purchase-outcome-fixture-\(vectorIndex)",
            environment: "test",
            storeEnvironment: .appStore
        )
        let usesExternalDelegate = vector.actions.contains {
            $0.entry == "external_delegate"
        }
        let settings = NuxieRuntimeSettings(
            localeIdentifier: nil,
            purchaseDelegate: usesExternalDelegate ? delegate : nil,
            purchaseHandlingMode: .full
        )
        let featureService = PurchaseOutcomeFeatureService()
        let serviceBox = LateBound<TransactionService>()
        let realObserver = TransactionObserver(
            api: syncAPI,
            features: featureService,
            identity: identity,
            settings: settings,
            eventSink: eventSink,
            transactionServiceProvider: { serviceBox.get() },
            evidenceStore: evidenceStore,
            descriptorAllowanceProvider: { evidence in
                evidence.productFeatureIds.map {
                    OptimisticEntitlementAllowance(
                        featureId: $0,
                        kind: .boolean,
                        unlimited: false,
                        allowance: nil
                    )
                }
            },
            projectionPublisher: { [projection] evidence, allowances, distinctId, _ in
                let overlay = OptimisticEntitlementProjection.derive(
                    evidence: evidence,
                    descriptorAllowances: allowances,
                    distinctId: distinctId
                ) != nil
                await projection.observe(overlay)
            },
            purchaseStorageScope: scope,
            dateProvider: PurchaseOutcomeDateProvider(),
            unfinishedRecoveryTransactions: { [storeRecovery] in
                await storeRecovery.drainUnfinished()
            },
            currentEntitlementRecoveryTransactions: { [storeRecovery] in
                await storeRecovery.queryCurrentEntitlements()
            },
            syncTaskScheduled: { [syncTaskProbe] transactionId in
                syncTaskProbe.record(transactionId: transactionId)
            }
        )
        observer = realObserver
        let recorder = PurchaseOutcomeCommitRecorder(observer: realObserver)
        commitRecorder = recorder
        service = TransactionService(
            productService: ProductService(),
            transactionObserver: recorder,
            pendingPurchaseStore: pendingStore,
            dateProvider: PurchaseOutcomeDateProvider(),
            settings: settings,
            eventSink: eventSink,
            purchaseStorageScope: scope,
            identityService: identity,
            nativePurchaseAdapter: storeAdapter,
            featureService: featureService
        )
        serviceBox.set(service)
    }

    func run(_ action: PurchaseOutcomeCommitFixture.Action) async throws -> String? {
        if action.entry != "retry_retained_outcomes",
           let carrierCaptureSucceeds = action.carrierCaptureSucceeds {
            eventSink.setCarrierCaptureResult(carrierCaptureSucceeds)
        }
        switch action.entry {
        case "checkout":
            let productKey = try required(action.product, field: "product", action: action)
            let product = try makeProduct(key: productKey)
            storeAdapter.setPurchaseResult(try nativeResult(for: action))
            do {
                let result = try await service.purchase(product)
                _ = await result.syncTask?.value
                return nil
            } catch StoreKitError.purchaseCancelled {
                return "cancelled"
            } catch StoreKitError.purchasePending {
                return "pending"
            } catch StoreKitError.purchaseFailed(_) {
                return "failed"
            }

        case "transaction_stream":
            await observer.handleVerifiedTransaction(
                try verifiedUpdate(for: action),
                jwsRepresentation: try fixtureEvidence(for: action).signedPayload,
                source: .transactionStream,
                attributedDistinctId: identity.getDistinctId()
            )
            return nil

        case "startup_recovery":
            let fixtureEvidence = try fixtureEvidence(for: action)
            await storeRecovery.enqueueCurrentEntitlement(StoreTransactionRecoveryItem(
                update: try verifiedUpdate(for: action),
                jwsRepresentation: fixtureEvidence.signedPayload
            ))
            await observer.retryAfterProfileReady()
            return nil

        case "deferred_update":
            await observer.handleVerifiedTransaction(
                try verifiedUpdate(for: action),
                jwsRepresentation: try fixtureEvidence(for: action).signedPayload,
                source: .transactionStream,
                attributedDistinctId: identity.getDistinctId()
            )
            return nil

        case "external_delegate":
            switch action.operation {
            case "purchase":
                let productKey = try required(
                    action.product,
                    field: "product",
                    action: action
                )
                await delegate.setPurchaseResult(.purchased)
                let result = try await service.purchase(try makeProduct(key: productKey))
                _ = await result.syncTask?.value
            case "restore":
                await delegate.setRestoreResult(.restored)
                try await service.restore()
            default:
                throw FixtureRunnerError.unsupportedAction(
                    "external operation \(action.operation ?? "nil")"
                )
            }
            return nil

        case "retry_retained_outcomes":
            if action.carrierCaptureSucceeds == true,
               let minimumCarrierCaptureAttempts {
                eventSink.setCarrierCaptureResult(false)
                while eventSink.captureOnlyAttemptCount
                    < minimumCarrierCaptureAttempts - 1 {
                    let attemptsBeforeFailure = eventSink.captureOnlyAttemptCount
                    await observer.retryStoredEvidence()
                    guard eventSink.captureOnlyAttemptCount
                        > attemptsBeforeFailure else { break }
                }
            }
            if let carrierCaptureSucceeds = action.carrierCaptureSucceeds {
                eventSink.setCarrierCaptureResult(carrierCaptureSucceeds)
            }
            let attemptsBeforeRetry = eventSink.captureOnlyAttemptCount
            await observer.retryStoredEvidence()
            let attemptDelta = eventSink.captureOnlyAttemptCount - attemptsBeforeRetry
            retainedRetryCaptureAttemptDeltas.append(attemptDelta)
            if let expectedDelta = action.expectedCarrierCaptureAttemptDelta {
                XCTAssertEqual(
                    attemptDelta,
                    expectedDelta,
                    "\(vectorName): retained retry carrier-attempt delta"
                )
            }
            return nil

        default:
            throw FixtureRunnerError.unsupportedAction(action.entry)
        }
    }

    func shutdown() async {
        await observer.stopListening()
    }

    func carriesKnownEvidenceIdentity(
        _ event: RecordedPurchaseOutcomeEvent
    ) -> Bool {
        evidence.values.contains { $0.identity == event.transactionId }
    }

    func carriesKnownProductMapping(
        _ event: RecordedPurchaseOutcomeEvent
    ) -> Bool {
        products.values.contains {
            $0.productId == event.productId
                && $0.storeProductId == event.storeProductId
                && $0.placementId == event.placementId
                && $0.experienceId == event.experienceId
                && $0.displayPrice == event.displayPrice
                && $0.price == event.price
        }
    }

    func commitVerifiedOutcome(
        evidenceKey: String,
        source: PurchaseOutcomeSource
    ) async throws -> PurchaseCommitResult {
        guard let fixtureEvidence = evidence[evidenceKey] else {
            throw FixtureRunnerError.missingFixtureValue(
                "evidence.\(evidenceKey)"
            )
        }
        let product = try makeProduct(key: fixtureEvidence.product)
        return await observer.commit(.verified(
            VerifiedPurchaseEvidence(
                transactionJws: fixtureEvidence.signedPayload,
                transactionId: fixtureEvidence.identity,
                originalTransactionId: fixtureEvidence.originalIdentity,
                productId: product.storeProductId,
                appAccountToken: scope.appAccountToken(
                    distinctId: identity.getDistinctId()
                ),
                attributedDistinctId: identity.getDistinctId(),
                productFeatureIds: storeProductFeatureIds(
                    product.localEntitlementGrants
                ),
                commercialContext: product.purchaseContext,
                finishRequired: true,
                resolvesPendingPurchase: false,
                allowsDurableCheckoutAuthority: false,
                requiresAuthorityResolution: false,
                finish: { [finalizationProbe] in await finalizationProbe.finalize() }
            ),
            source: source
        ))
    }

    func commitRevokedOutcome(
        evidenceKey: String,
        transactionJws: String
    ) async throws -> PurchaseCommitResult {
        guard let fixtureEvidence = evidence[evidenceKey] else {
            throw FixtureRunnerError.missingFixtureValue(
                "evidence.\(evidenceKey)"
            )
        }
        let product = try makeProduct(key: fixtureEvidence.product)
        return await observer.commit(.verified(
            VerifiedPurchaseEvidence(
                transactionJws: transactionJws,
                transactionId: fixtureEvidence.identity,
                originalTransactionId: fixtureEvidence.originalIdentity,
                productId: product.storeProductId,
                appAccountToken: scope.appAccountToken(
                    distinctId: identity.getDistinctId()
                ),
                attributedDistinctId: identity.getDistinctId(),
                productFeatureIds: storeProductFeatureIds(
                    product.localEntitlementGrants
                ),
                commercialContext: product.purchaseContext,
                finishRequired: false,
                resolvesPendingPurchase: false,
                allowsDurableCheckoutAuthority: false,
                requiresAuthorityResolution: false,
                isRevoked: true
            ),
            source: .transactionStream
        ))
    }

    private func nativeResult(
        for action: PurchaseOutcomeCommitFixture.Action
    ) throws -> NativePurchaseResult {
        switch action.outcome {
        case "verified":
            let fixtureEvidence = try fixtureEvidence(for: action)
            return .purchased(StoreTransactionEvidence(
                transactionJws: fixtureEvidence.signedPayload,
                transactionId: fixtureEvidence.identity,
                originalTransactionId: fixtureEvidence.originalIdentity,
                productId: try productFixture(for: fixtureEvidence).storeProductId,
                finish: { [finalizationProbe] in await finalizationProbe.finalize() }
            ))
        case "cancelled":
            return .cancelled
        case "pending":
            return .pending
        case "failed":
            return .failed(FixturePurchaseFailure(
                reason: action.reason ?? "fixture_failure"
            ))
        default:
            throw FixtureRunnerError.unsupportedOutcome(action.outcome)
        }
    }

    private func verifiedUpdate(
        for action: PurchaseOutcomeCommitFixture.Action
    ) throws -> VerifiedStoreTransactionUpdate {
        let fixtureEvidence = try fixtureEvidence(for: action)
        return VerifiedStoreTransactionUpdate(
            transactionId: fixtureEvidence.identity,
            originalTransactionId: fixtureEvidence.originalIdentity,
            productId: try productFixture(for: fixtureEvidence).storeProductId,
            appAccountToken: scope.appAccountToken(distinctId: identity.getDistinctId()),
            isRevoked: false,
            isUpgraded: false,
            finish: { [finalizationProbe] in await finalizationProbe.finalize() }
        )
    }

    private func fixtureEvidence(
        for action: PurchaseOutcomeCommitFixture.Action
    ) throws -> PurchaseOutcomeCommitFixture.Evidence {
        let key = try required(action.evidence, field: "evidence", action: action)
        guard let fixtureEvidence = evidence[key] else {
            throw FixtureRunnerError.missingFixtureValue("evidence.\(key)")
        }
        return fixtureEvidence
    }

    private func productFixture(
        for fixtureEvidence: PurchaseOutcomeCommitFixture.Evidence
    ) throws -> PurchaseOutcomeCommitFixture.Product {
        guard let product = products[fixtureEvidence.product] else {
            throw FixtureRunnerError.missingFixtureValue(
                "products.\(fixtureEvidence.product)"
            )
        }
        return product
    }

    private func makeProduct(key: String) throws -> StoreProduct {
        guard let fixtureProduct = products[key] else {
            throw FixtureRunnerError.missingFixtureValue("products.\(key)")
        }
        var product = StoreProduct(
            productId: fixtureProduct.productId,
            storeProductId: fixtureProduct.storeProductId,
            placementId: fixtureProduct.placementId,
            name: fixtureProduct.productId,
            price: fixtureProduct.displayPrice,
            period: nil
        )
        product.purchaseContext = PurchaseCommercialContext(
            release: AuthenticatedJourneyReleaseID(
                identity: JourneyReleaseIdentity(
                    appId: "fixture-app",
                    environment: "test",
                    experienceId: fixtureProduct.experienceId,
                    experienceVersionId: fixtureProduct.experienceVersion,
                    buildId: "fixture-build",
                    versionNumber: 1,
                    releaseCreatedAt: "2026-08-31T00:00:00Z",
                    releaseSequence: 1
                ),
                descriptorSHA256: String(repeating: "f", count: 64)
            ),
            placementId: fixtureProduct.placementId,
            productId: fixtureProduct.productId,
            storeProductId: fixtureProduct.storeProductId,
            displayPrice: fixtureProduct.displayPrice,
            price: fixtureProduct.price
        )
        product.localEntitlementGrants = fixtureProduct.localEntitlementGrants.map {
            StoreProduct.LocalEntitlementGrant(
                featureId: $0.featureId,
                featureExternalId: nil,
                allowanceType: nil,
                allowance: nil
            )
        }
        return product
    }

    private func required(
        _ value: String?,
        field: String,
        action: PurchaseOutcomeCommitFixture.Action
    ) throws -> String {
        guard let value else {
            throw FixtureRunnerError.missingFixtureValue(
                "\(field) for \(action.entry)"
            )
        }
        return value
    }
}

private enum FixtureRunnerError: Error {
    case missingFixtureValue(String)
    case unsupportedAction(String)
    case unsupportedOutcome(String)
}

private struct FixturePurchaseFailure: LocalizedError, Sendable {
    let reason: String
    var errorDescription: String? { reason }
}

final class PurchaseOutcomeCommitFixtureTests: XCTestCase {
    func testProductionEntryPointsMatchCrossSDKOutcomeCommitContract() async throws {
        let fixture = try Self.loadFixture()
        XCTAssertEqual(fixture.suite, "purchases/outcome-commit")
        XCTAssertEqual(fixture.version, 1)
        XCTAssertEqual(fixture.sources, [
            "checkout",
            "transaction_stream",
            "startup_recovery",
            "deferred_update",
            "external_delegate",
        ])

        for (index, vector) in fixture.cases.enumerated() {
            let harness = PurchaseOutcomeFixtureHarness(
                fixture: fixture,
                vector: vector,
                vectorIndex: index
            )
            var checkoutErrors: [String] = []
            do {
                for action in vector.actions {
                    if let error = try await harness.run(action) {
                        checkoutErrors.append(error)
                    }
                }
            } catch {
                XCTFail("\(vector.name): fixture action failed: \(error)")
            }

            await assert(vector, against: harness, checkoutErrors: checkoutErrors)
            await harness.shutdown()
        }
    }

    func testConcurrentVerifiedSourcesJoinOneLogicalCommit() async throws {
        let fixture = try Self.loadFixture()
        let vector = try XCTUnwrap(fixture.cases.first)
        let harness = PurchaseOutcomeFixtureHarness(
            fixture: fixture,
            vector: vector,
            vectorIndex: 100
        )

        let results: (PurchaseCommitResult, PurchaseCommitResult)
        do {
            async let checkout = harness.commitVerifiedOutcome(
                evidenceKey: "pro-transaction",
                source: .checkout
            )
            async let stream = harness.commitVerifiedOutcome(
                evidenceKey: "pro-transaction",
                source: .transactionStream
            )
            results = try await (checkout, stream)
        } catch {
            await harness.shutdown()
            throw error
        }
        let checkoutSynced = await results.0.syncTask?.value
        let streamSynced = await results.1.syncTask?.value
        let completed = harness.eventSink.events(
            named: SystemEventNames.purchaseCompleted
        )
        let requestCount = await harness.syncAPI.requestCount

        XCTAssertTrue(results.0.committed)
        XCTAssertTrue(results.1.committed)
        XCTAssertEqual(checkoutSynced, true)
        XCTAssertEqual(streamSynced, true)
        XCTAssertEqual(harness.evidenceStore.uniquePersistedCount, 1)
        XCTAssertEqual(completed.count, 1)
        XCTAssertEqual(completed.filter(\.routed).count, 0)
        XCTAssertEqual(harness.eventSink.captureOnlyAttemptCount, 1)
        XCTAssertEqual(completed.first?.transactionId, "transaction-pro-1")
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(harness.syncTaskProbe.count, 1)
        XCTAssertEqual(harness.finalizationProbe.count, 1)
        await harness.shutdown()
    }

    func testVerifiedRetryResubmitsReceiptWithoutReplayingCompletion() async throws {
        let fixture = try Self.loadFixture()
        let vector = try XCTUnwrap(fixture.cases.first)
        let harness = PurchaseOutcomeFixtureHarness(
            fixture: fixture,
            vector: vector,
            vectorIndex: 101
        )
        await harness.syncAPI.setResponseSuccesses([false, true])

        let first: PurchaseCommitResult
        let retry: PurchaseCommitResult
        do {
            first = try await harness.commitVerifiedOutcome(
                evidenceKey: "pro-transaction",
                source: .checkout
            )
            let firstSynced = await first.syncTask?.value
            XCTAssertEqual(firstSynced, false)
            retry = try await harness.commitVerifiedOutcome(
                evidenceKey: "pro-transaction",
                source: .transactionStream
            )
        } catch {
            await harness.shutdown()
            throw error
        }
        let retrySynced = await retry.syncTask?.value
        let completed = harness.eventSink.events(
            named: SystemEventNames.purchaseCompleted
        )
        let requestCount = await harness.syncAPI.requestCount

        XCTAssertTrue(first.committed)
        XCTAssertTrue(retry.committed)
        XCTAssertEqual(retrySynced, true)
        XCTAssertEqual(harness.evidenceStore.uniquePersistedCount, 1)
        XCTAssertEqual(completed.count, 1)
        XCTAssertEqual(completed.filter(\.routed).count, 0)
        XCTAssertEqual(harness.eventSink.captureOnlyAttemptCount, 1)
        XCTAssertEqual(completed.first?.source, PurchaseOutcomeSource.checkout.rawValue)
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(harness.finalizationProbe.count, 1)
        await harness.shutdown()
    }

    func testRevocationDuringCompletionCaptureKeepsRevokedEvidenceAndSkipsActiveSync() async throws {
        let fixture = try Self.loadFixture()
        let vector = try XCTUnwrap(fixture.cases.first)
        let checkoutAction = try XCTUnwrap(vector.actions.first)
        let harness = PurchaseOutcomeFixtureHarness(
            fixture: fixture,
            vector: vector,
            vectorIndex: 105
        )
        await harness.eventSink.suspendNextPurchaseCompletionCapture()

        let checkout = Task {
            try await harness.run(checkoutAction)
        }
        await harness.eventSink.waitUntilPurchaseCompletionCaptureStarts()

        let revoked = try await harness.commitRevokedOutcome(
            evidenceKey: "pro-transaction",
            transactionJws: "revoked-pro-1"
        )
        let revokedSynced = await revoked.syncTask?.value
        await harness.eventSink.releasePurchaseCompletionCapture()
        let checkoutError = try await checkout.value

        let retained = try XCTUnwrap(
            harness.evidenceStore.evidence(transactionId: "transaction-pro-1")
        )
        let completed = harness.eventSink.events(
            named: SystemEventNames.purchaseCompleted
        )
        let requestedJWSs = await harness.syncAPI.requestedTransactionJWSs

        XCTAssertNil(checkoutError)
        XCTAssertEqual(revokedSynced, true)
        XCTAssertEqual(completed.count, 1, "the mid-capture emission race is accepted")
        XCTAssertTrue(retained.isRevoked)
        XCTAssertEqual(retained.transactionJws, "")
        XCTAssertNotNil(retained.backendSyncedAt)
        XCTAssertNotNil(retained.completionDeliveredAt)
        XCTAssertEqual(requestedJWSs, ["revoked-pro-1"])
        XCTAssertEqual(harness.syncTaskProbe.count, 1)
        await harness.shutdown()
    }

    func testCompletionClaimPreservesAcknowledgementLandingDuringCapture() async throws {
        let fixture = try Self.loadFixture()
        let vector = try XCTUnwrap(fixture.cases.first)
        let checkoutAction = try XCTUnwrap(vector.actions.first)
        let evidence = try XCTUnwrap(fixture.evidence["pro-transaction"])
        let product = try XCTUnwrap(fixture.products[evidence.product])
        let harness = PurchaseOutcomeFixtureHarness(
            fixture: fixture,
            vector: vector,
            vectorIndex: 106
        )
        await harness.eventSink.suspendNextPurchaseCompletionCapture()

        let checkout = Task {
            try await harness.run(checkoutAction)
        }
        await harness.eventSink.waitUntilPurchaseCompletionCaptureStarts()

        let synced = await harness.observer.syncTransaction(
            transactionJws: evidence.signedPayload,
            transactionId: evidence.identity,
            productId: product.storeProductId,
            originalTransactionId: evidence.originalIdentity
        )
        let acknowledgedDuringCapture = try XCTUnwrap(
            harness.evidenceStore.evidence(transactionId: evidence.identity)
        )
        XCTAssertTrue(synced)
        XCTAssertEqual(acknowledgedDuringCapture.transactionJws, "")
        XCTAssertNotNil(acknowledgedDuringCapture.backendSyncedAt)

        await harness.eventSink.releasePurchaseCompletionCapture()
        let checkoutError = try await checkout.value
        let retained = try XCTUnwrap(
            harness.evidenceStore.evidence(transactionId: evidence.identity)
        )
        let requestedJWSs = await harness.syncAPI.requestedTransactionJWSs

        XCTAssertNil(checkoutError)
        XCTAssertEqual(retained.transactionJws, "")
        XCTAssertNotNil(retained.backendSyncedAt)
        XCTAssertNotNil(retained.completionDeliveredAt)
        XCTAssertEqual(requestedJWSs, [evidence.signedPayload])
        XCTAssertEqual(harness.syncTaskProbe.count, 0)
        await harness.shutdown()
    }

    func testExternalDeclarationDurablyCapturesCarrierBeforeRoutingCompletes() async throws {
        let fixture = try Self.loadFixture()
        let vector = try XCTUnwrap(fixture.cases.first(where: {
            $0.actions.contains {
                $0.entry == "external_delegate" && $0.operation == "purchase"
            }
        }))
        let action = try XCTUnwrap(vector.actions.first)
        let harness = PurchaseOutcomeFixtureHarness(
            fixture: fixture,
            vector: vector,
            vectorIndex: 102
        )
        harness.eventSink.setRoutedCaptureResult(false)

        let checkoutError = try await harness.run(action)
        let completed = harness.eventSink.events(
            named: SystemEventNames.purchaseCompleted
        )

        XCTAssertNil(checkoutError)
        XCTAssertEqual(completed.count, 1)
        XCTAssertEqual(completed.filter(\.routed).count, 0)
        XCTAssertEqual(
            completed.first?.source,
            PurchaseOutcomeSource.externalDelegate.rawValue
        )
        XCTAssertGreaterThanOrEqual(harness.eventSink.captureOnlyAttemptCount, 2)
        XCTAssertGreaterThanOrEqual(harness.eventSink.routedAttemptCount, 2)
        await harness.shutdown()
    }

    func testVerifiedCommitRetainsJourneyRoutingUntilStableCaptureCompletes() async throws {
        let fixture = try Self.loadFixture()
        let vector = try XCTUnwrap(fixture.cases.first)
        let checkoutAction = try XCTUnwrap(vector.actions.first)
        let streamAction = try XCTUnwrap(vector.actions.first(where: {
            $0.entry == "transaction_stream"
        }))
        let harness = PurchaseOutcomeFixtureHarness(
            fixture: fixture,
            vector: vector,
            vectorIndex: 103
        )
        harness.eventSink.setRoutedCaptureResult(false)

        let checkoutError = try await harness.run(checkoutAction)
        let retainedAfterCaptureFailure = try XCTUnwrap(
            harness.evidenceStore.evidence(transactionId: "transaction-pro-1")
        )
        XCTAssertNil(checkoutError)
        XCTAssertTrue(harness.eventSink.events(
            named: SystemEventNames.purchaseCompleted
        ).isEmpty)
        XCTAssertNotNil(retainedAfterCaptureFailure.commercialContext)
        XCTAssertNotNil(retainedAfterCaptureFailure.checkoutCompletionEventId)
        XCTAssertNil(retainedAfterCaptureFailure.completionDeliveredAt)
        XCTAssertNotNil(retainedAfterCaptureFailure.backendSyncedAt)
        XCTAssertEqual(retainedAfterCaptureFailure.transactionJws, "")

        harness.eventSink.setRoutedCaptureResult(true)
        _ = try await harness.run(streamAction)
        let completed = harness.eventSink.events(
            named: SystemEventNames.purchaseCompleted
        )
        let commitCount = await harness.observer
            .completedSuccessfulPurchaseCommitCount()
        let retainedAfterStoreUpdate = try XCTUnwrap(
            harness.evidenceStore.evidence(transactionId: "transaction-pro-1")
        )
        let requestCount = await harness.syncAPI.requestCount

        XCTAssertEqual(completed.count, 1)
        XCTAssertEqual(completed.filter(\.routed).count, 1)
        XCTAssertEqual(commitCount, 1)
        XCTAssertNotNil(retainedAfterStoreUpdate.completionDeliveredAt)
        XCTAssertEqual(retainedAfterStoreUpdate.transactionJws, "")
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(harness.syncTaskProbe.count, 1)
        XCTAssertEqual(harness.finalizationProbe.count, 1)
        await harness.shutdown()
    }

    private static func loadFixture() throws -> PurchaseOutcomeCommitFixture {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("fixtures/purchases/outcome-commit.json")
        return try JSONDecoder().decode(
            PurchaseOutcomeCommitFixture.self,
            from: Data(contentsOf: fixtureURL)
        )
    }

    private func assert(
        _ vector: PurchaseOutcomeCommitFixture.Case,
        against harness: PurchaseOutcomeFixtureHarness,
        checkoutErrors: [String]
    ) async {
        let expectation = vector.expect
        let completed = harness.eventSink.events(
            named: SystemEventNames.purchaseCompleted
        )
        let restored = harness.eventSink.events(
            named: SystemEventNames.restoreCompleted
        )
        let failed = harness.eventSink.events(
            named: SystemEventNames.purchaseFailed
        )
        // Count logical commits from their dedupe identities, independently
        // from Journey/event emission: verified evidence commits once per
        // persisted identity, while declarations commit once per callback.
        let successfulCommits = await harness.observer
            .completedSuccessfulPurchaseCommitCount()
        let journeyAdvancements = completed.filter(\.routed).count
            + restored.filter(\.routed).count
        let hasEvidenceIdentity = !completed.isEmpty
            && completed.allSatisfy { harness.carriesKnownEvidenceIdentity($0) }
        let hasProductMapping = !completed.isEmpty
            && completed.allSatisfy { harness.carriesKnownProductMapping($0) }
        let serverSyncRequests = await harness.syncAPI.requestCount
        let scheduledSyncTasks = harness.syncTaskProbe.count
        let overlayEverPresent = await harness.projection.overlayEverPresent
        let storeEntitlementQueries = await harness.storeRecovery.entitlementQueryCount
        let terminalOutcomes = await harness.commitRecorder.observedTerminalOutcomes

        XCTAssertEqual(
            successfulCommits,
            expectation.successfulCommits,
            "\(vector.name): successful commits"
        )
        XCTAssertEqual(
            harness.evidenceStore.uniquePersistedCount,
            expectation.uniqueEvidenceRows,
            "\(vector.name): unique evidence rows"
        )
        XCTAssertEqual(
            journeyAdvancements,
            expectation.journeyAdvancements,
            "\(vector.name): journey advancements"
        )
        XCTAssertEqual(
            completed.count,
            expectation.purchaseCompletedEvents,
            "\(vector.name): purchase completion events"
        )
        XCTAssertEqual(
            restored.count,
            expectation.restoreCompletedEvents,
            "\(vector.name): restore completion events"
        )
        XCTAssertEqual(
            failed.count,
            expectation.purchaseFailedEvents,
            "\(vector.name): purchase failure events"
        )
        XCTAssertEqual(
            serverSyncRequests,
            expectation.serverSyncRequests,
            "\(vector.name): server sync requests"
        )
        XCTAssertEqual(
            scheduledSyncTasks,
            expectation.scheduledSyncTasks,
            "\(vector.name): scheduled sync tasks"
        )
        XCTAssertEqual(
            harness.pendingStore.count,
            expectation.pendingRecords,
            "\(vector.name): pending records"
        )
        XCTAssertEqual(
            overlayEverPresent,
            expectation.overlayEverPresent,
            "\(vector.name): optimistic overlay"
        )
        XCTAssertEqual(
            storeEntitlementQueries,
            expectation.storeEntitlementQueries,
            "\(vector.name): store entitlement queries"
        )
        if let storeFinalizationCalls = expectation.storeFinalizationCalls {
            XCTAssertEqual(
                harness.finalizationProbe.count,
                storeFinalizationCalls,
                "\(vector.name): store finalization calls"
            )
        }
        XCTAssertEqual(
            checkoutErrors,
            expectation.checkoutErrors,
            "\(vector.name): checkout errors"
        )
        XCTAssertEqual(
            terminalOutcomes,
            expectation.committerTerminalOutcomes,
            "\(vector.name): terminal outcomes routed through committer"
        )
        XCTAssertEqual(
            completed.compactMap(\.source),
            expectation.completionSources,
            "\(vector.name): completion provenance"
        )
        XCTAssertEqual(
            hasEvidenceIdentity,
            expectation.completionCarriesEvidenceIdentity,
            "\(vector.name): evidence identity carrier"
        )
        XCTAssertEqual(
            hasProductMapping,
            expectation.completionCarriesProductMapping,
            "\(vector.name): product mapping carrier"
        )
        if expectation.completionEventIdsDistinct == true {
            XCTAssertEqual(
                Set(completed.compactMap(\.eventId)).count,
                completed.count,
                "\(vector.name): callback operation event IDs"
            )
        }

        if let minimumAttempts = expectation.minimumCarrierCaptureAttempts {
            XCTAssertGreaterThanOrEqual(
                harness.eventSink.captureOnlyAttemptCount,
                minimumAttempts,
                "\(vector.name): carrier capture attempts"
            )
        }
        if let successfulCaptures = expectation.successfulCarrierCaptures {
            XCTAssertEqual(
                harness.eventSink.successfulCarrierCaptureCount,
                successfulCaptures,
                "\(vector.name): successful carrier captures"
            )
        }
        if let identityCount = expectation.carrierCaptureOperationIdentityCount {
            XCTAssertEqual(
                harness.eventSink.carrierCaptureOperationIdentityCount,
                identityCount,
                "\(vector.name): retained carrier operation identity"
            )
        }
        if let retryRoundLimit = expectation.retainedCarrierRetryRoundLimit {
            let iOSCaptureAttemptsPerCommit = 2
            XCTAssertEqual(
                harness.eventSink.captureOnlyAttemptCount,
                iOSCaptureAttemptsPerCommit * (1 + retryRoundLimit),
                "\(vector.name): iOS carrier-attempt cap"
            )
        }
        if expectation.carrierCaptureAttemptsStopAtRetryLimit == true {
            guard let retryRoundLimit = expectation.retainedCarrierRetryRoundLimit else {
                XCTFail("\(vector.name): stopped-at-cap requires a retry-round limit")
                return
            }
            guard harness.retainedRetryCaptureAttemptDeltas.count
                > retryRoundLimit else {
                XCTFail("\(vector.name): missing post-cap recovery probe")
                return
            }
            XCTAssertEqual(
                harness.retainedRetryCaptureAttemptDeltas[retryRoundLimit],
                0,
                "\(vector.name): capture attempts after retry cap"
            )
        }

        if vector.actions.allSatisfy({
            $0.entry == "external_delegate" || $0.entry == "retry_retained_outcomes"
        }) {
            XCTAssertEqual(
                harness.storeAdapter.purchaseCallCount,
                0,
                "\(vector.name): external billing must not open StoreKit checkout"
            )
            XCTAssertEqual(
                harness.storeAdapter.restoreCallCount,
                0,
                "\(vector.name): external restore must not invoke StoreKit restore"
            )
        }
    }
}
