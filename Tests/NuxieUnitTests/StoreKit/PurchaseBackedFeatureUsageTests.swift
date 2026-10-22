import Foundation
import XCTest
@_spi(Testing) @testable import Nuxie
@testable import NuxieTestSupport

private struct AtomicPurchaseSyncFixture: Decodable {
    struct Event: Decodable {
        let name: String
        let properties: [String]
    }

    struct Retry: Decodable {
        let requestIdentity: String
        let retainEvidenceOnFailure: Bool
        let emitOnFailure: Bool

        enum CodingKeys: String, CodingKey {
            case requestIdentity = "request_identity"
            case retainEvidenceOnFailure = "retain_evidence_on_failure"
            case emitOnFailure = "emit_on_failure"
        }
    }

    struct Acceptance: Decodable {
        struct PostUseAccess: Decodable {
            let allowedAfterFinalFiniteUnit: Bool
            let balanceAfterFinalFiniteUnit: Double

            enum CodingKeys: String, CodingKey {
                case allowedAfterFinalFiniteUnit = "allowed_after_final_finite_unit"
                case balanceAfterFinalFiniteUnit = "balance_after_final_finite_unit"
            }
        }

        let boundary: String
        let commandSuccess: Bool
        let postUseAccess: PostUseAccess
        let captureBeforeRetiringEvidence: Bool
        let emissionsPerAcceptedReceipt: Int
        let ordinaryUsageFallback: Bool

        enum CodingKeys: String, CodingKey {
            case boundary
            case commandSuccess = "command_success"
            case postUseAccess = "post_use_access"
            case captureBeforeRetiringEvidence = "capture_before_retiring_evidence"
            case emissionsPerAcceptedReceipt = "emissions_per_accepted_receipt"
            case ordinaryUsageFallback = "ordinary_usage_fallback"
        }
    }

    let suite: String
    let version: Int
    let event: Event
    let retry: Retry
    let acceptance: Acceptance

    static func load() throws -> Self {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("fixtures/events/atomic-purchase-sync.json")
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: fixture))
    }
}

private actor PurchaseBackedUsageAPI: PurchaseSynchronizing, PurchaseBackedFeatureUsing {
    private var requests: [PurchaseBackedFeatureUseRequest] = []
    private var results: [Result<PurchaseBackedFeatureUseResponse, Error>]
    private let onUse: @Sendable () -> Void
    private let syncFailureCustomerIds: Set<String>

    init(
        results: [Result<PurchaseBackedFeatureUseResponse, Error>],
        syncFailureCustomerIds: Set<String> = [],
        onUse: @escaping @Sendable () -> Void = {}
    ) {
        self.results = results
        self.syncFailureCustomerIds = syncFailureCustomerIds
        self.onUse = onUse
    }

    func syncTransaction(_ request: PurchaseRequest) async throws -> PurchaseResponse {
        let distinctId = request.distinctId
        if syncFailureCustomerIds.contains(distinctId) { throw URLError(.timedOut) }
        return PurchaseResponse(
            success: true,
            customerId: distinctId,
            features: nil,
            error: nil
        )
    }

    func useFeatureWithPurchase(
        _ request: PurchaseBackedFeatureUseRequest
    ) async throws -> PurchaseBackedFeatureUseResponse {
        requests.append(request)
        onUse()
        guard !results.isEmpty else { throw NuxieNetworkError.invalidResponse }
        return try results.removeFirst().get()
    }

    func recordedRequests() -> [PurchaseBackedFeatureUseRequest] { requests }
}

/// An evidence store whose writes the test can make fail, as a full disk
/// would.
private final class WriteRefusingEvidenceStore: TransactionEvidenceStoreProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: StoredTransactionEvidence]
    private var refusesWritesStorage = false

    init(entries: [String: StoredTransactionEvidence] = [:]) {
        self.entries = entries
    }

    var refusesWrites: Bool {
        get { lock.withLock { refusesWritesStorage } }
        set { lock.withLock { refusesWritesStorage = newValue } }
    }

    func load() -> StoreReadResult<[String: StoredTransactionEvidence]> {
        lock.withLock { .value(entries) }
    }

    @discardableResult
    func save(_ entries: [String: StoredTransactionEvidence]) -> Bool {
        lock.withLock {
            guard !refusesWritesStorage else { return false }
            self.entries = entries
            return true
        }
    }
}

private final class ProfileRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func record(_ distinctId: String) { lock.withLock { storage.append(distinctId) } }
    var requests: [String] { lock.withLock { storage } }
}

private final class OrdinaryReceiptSyncAPI {
    private let responseCustomerId: String?
    private let lock = NSLock()
    private var requestCount = 0

    init(responseCustomerId: String?) {
        self.responseCustomerId = responseCustomerId
    }

    func syncTransaction(_ request: PurchaseRequest) async throws -> PurchaseResponse {
        lock.withLock { requestCount += 1 }
        return PurchaseResponse(
            success: true,
            customerId: responseCustomerId,
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

    func recordedRequestCount() -> Int {
        lock.withLock { requestCount }
    }
}

extension OrdinaryReceiptSyncAPI: PurchaseSynchronizing, @unchecked Sendable {}

private final class UnreadablePendingPurchaseStore: PendingPurchaseStoreProtocol, @unchecked Sendable {
    func load() -> StoreReadResult<[String: PendingPurchaseRecord]> { .unreadable }
    @discardableResult
    func save(_ entries: [String: PendingPurchaseRecord]) -> Bool { false }
}

private actor PurchaseBackedFeatureRecorder: FeatureServiceProtocol {
    private var updates: [(FeatureCheckResult, String, String, String?)] = []
    private var purchaseUpdateCount = 0
    private var invalidations = 0

    func invalidateAccess(featureId: String, entityId: String?, distinctId: String) async { invalidations += 1 }
    func invalidationCount() -> Int { invalidations }

    func getCached(featureId: String, entityId: String?) async -> FeatureAccess? { nil }
    func getAllCached() async -> [String: FeatureAccess] { [:] }
    func check(
        featureId: String,
        requiredBalance: Double?,
        entityId: String?
    ) async throws -> FeatureCheckResult { throw NuxieNetworkError.invalidResponse }
    func checkWithCache(
        featureId: String,
        requiredBalance: Double?,
        entityId: String?,
        forceRefresh: Bool
    ) async throws -> FeatureAccess { .notFound }
    func clearCache() async {}
    func handleUserChange(from oldDistinctId: String, to newDistinctId: String) async {}
    func syncFeatureInfo() async {}
    func updateFromPurchase(_ features: [PurchaseFeature], distinctId: String) async {
        _ = features
        _ = distinctId
        purchaseUpdateCount += 1
    }
    func applyAuthoritativeUse(
        _ result: FeatureCheckResult,
        requestedFeatureId: String,
        distinctId: String,
        entityId: String?
    ) async {
        updates.append((result, requestedFeatureId, distinctId, entityId))
    }

    func recordedUpdates() -> [(FeatureCheckResult, String, String, String?)] { updates }
    func recordedPurchaseUpdateCount() -> Int { purchaseUpdateCount }
}

private final class PurchaseBackedEventSink: SystemEventSink, @unchecked Sendable {
    struct Capture {
        let name: String
        let properties: [String: Any]?
        let eventId: String
        let distinctId: String
    }

    private let lock = NSLock()
    private var capturedEvents: [(String, [String: Any]?)] = []
    private var captures: [Capture] = []
    private var captureResults: [Bool]

    init(captureResults: [Bool] = []) {
        self.captureResults = captureResults
    }

    func emit(_ name: String, properties: [String: Any]?) {
        lock.withLock { capturedEvents.append((name, properties)) }
    }

    func events() -> [(String, [String: Any]?)] {
        lock.withLock { capturedEvents }
    }

    func capture(
        _ request: StableSystemEventCaptureRequest
    ) async -> Bool {
        lock.withLock {
            let result = captureResults.isEmpty ? true : captureResults.removeFirst()
            captures.append(Capture(
                name: request.name,
                properties: request.properties,
                eventId: request.eventId,
                distinctId: request.distinctId
            ))
            if result { capturedEvents.append((request.name, request.properties)) }
            return result
        }
    }

    func captureAttempts() -> [Capture] {
        lock.withLock { captures }
    }
}

private actor ControlledPurchaseBackedUsageAPI:
    PurchaseSynchronizing,
    PurchaseBackedFeatureUsing
{
    private var request: PurchaseBackedFeatureUseRequest?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var responseWaiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private var syncRequestCount = 0

    func syncTransaction(_ request: PurchaseRequest) async throws -> PurchaseResponse {
        let distinctId = request.distinctId
        syncRequestCount += 1
        return PurchaseResponse(
            success: true,
            customerId: distinctId,
            features: nil,
            error: nil
        )
    }

    func useFeatureWithPurchase(
        _ request: PurchaseBackedFeatureUseRequest
    ) async throws -> PurchaseBackedFeatureUseResponse {
        self.request = request
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if !released {
            await withCheckedContinuation { responseWaiters.append($0) }
        }
        return PurchaseBackedFeatureUseResponse(
            customerId: request.customerId,
            featureId: request.featureId,
            code: "entitled",
            allowed: true,
            unlimited: false,
            balance: 4,
            type: .creditSystem
        )
    }

    func waitUntilStarted() async {
        guard request == nil else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        released = true
        let waiters = responseWaiters
        responseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func requestCount() -> Int { request == nil ? 0 : 1 }
    func recordedSyncRequestCount() -> Int { syncRequestCount }
}

/// A server whose purchase-backed Feature use waits until the test releases
/// it and leaves 4 credits, and whose `POST /purchase` grants 9.
private actor RestoreAfterUseAPI: PurchaseSynchronizing, PurchaseBackedFeatureUsing {
    private var useStarted = false
    private var useReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var responseWaiters: [CheckedContinuation<Void, Never>] = []

    func syncTransaction(_ request: PurchaseRequest) async throws -> PurchaseResponse {
        PurchaseResponse(
            success: true,
            customerId: request.distinctId,
            features: [PurchaseFeature(
                id: "feature-credits", extId: "credits", type: .creditSystem,
                allowed: true, balance: 9, unlimited: false
            )],
            error: nil
        )
    }

    func useFeatureWithPurchase(
        _ request: PurchaseBackedFeatureUseRequest
    ) async throws -> PurchaseBackedFeatureUseResponse {
        useStarted = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        if !useReleased {
            await withCheckedContinuation { responseWaiters.append($0) }
        }
        return PurchaseBackedFeatureUseResponse(
            customerId: request.customerId,
            featureId: request.featureId,
            code: "entitled",
            allowed: true,
            unlimited: false,
            balance: 4,
            type: .creditSystem
        )
    }

    func waitUntilUseStarted() async {
        guard !useStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseUse() {
        useReleased = true
        responseWaiters.forEach { $0.resume() }
        responseWaiters.removeAll()
    }
}

/// Records every Feature write in order, and holds the first cache
/// invalidation until the test lets it go.
private actor OrderedFeatureWrites: FeatureServiceProtocol {
    private var writes: [String] = []
    private var holdsNextInvalidation = true
    private var invalidationHeld = false
    private var heldWaiters: [CheckedContinuation<Void, Never>] = []
    private var held: [CheckedContinuation<Void, Never>] = []

    func invalidateAccess(featureId: String, entityId: String?, distinctId: String) async {
        if holdsNextInvalidation {
            holdsNextInvalidation = false
            invalidationHeld = true
            heldWaiters.forEach { $0.resume() }
            heldWaiters.removeAll()
            await withCheckedContinuation { held.append($0) }
        }
        writes.append("invalidate \(featureId)")
    }

    func updateFromPurchase(_ features: [PurchaseFeature], distinctId: String) async {
        writes.append(contentsOf: features.map { "purchase \($0.featureKey) \($0.balance ?? 0)" })
    }

    func applyAuthoritativeUse(
        _ result: FeatureCheckResult,
        requestedFeatureId: String,
        distinctId: String,
        entityId: String?
    ) async {
        writes.append("use \(requestedFeatureId) \(result.balance ?? 0)")
    }

    func waitUntilInvalidationHeld() async {
        guard !invalidationHeld else { return }
        await withCheckedContinuation { heldWaiters.append($0) }
    }

    func releaseInvalidation() {
        held.forEach { $0.resume() }
        held.removeAll()
    }

    func recordedWrites() -> [String] { writes }

    func getCached(featureId: String, entityId: String?) async -> FeatureAccess? { nil }
    func getAllCached() async -> [String: FeatureAccess] { [:] }
    func check(
        featureId: String,
        requiredBalance: Double?,
        entityId: String?
    ) async throws -> FeatureCheckResult { throw NuxieNetworkError.invalidResponse }
    func checkWithCache(
        featureId: String,
        requiredBalance: Double?,
        entityId: String?,
        forceRefresh: Bool
    ) async throws -> FeatureAccess { .notFound }
    func clearCache() async {}
    func handleUserChange(from oldDistinctId: String, to newDistinctId: String) async {}
    func syncFeatureInfo() async {}
}

/// Signals once a Restore's scan has read the store's current entitlements.
private actor ScanArrival {
    private var arrived = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func arrive() {
        arrived = true
        let held = waiters
        waiters.removeAll()
        held.forEach { $0.resume() }
    }

    func wait() async {
        guard !arrived else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private actor ControlledReceiptSyncAPI:
    PurchaseSynchronizing,
    PurchaseBackedFeatureUsing
{
    private var syncStarted = false
    private var syncStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var syncResponseWaiters: [CheckedContinuation<Void, Never>] = []
    private var syncReleased = false
    private var usageRequestCount = 0

    func syncTransaction(_ request: PurchaseRequest) async throws -> PurchaseResponse {
        let distinctId = request.distinctId
        syncStarted = true
        let waiters = syncStartWaiters
        syncStartWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if !syncReleased {
            await withCheckedContinuation { syncResponseWaiters.append($0) }
        }
        return PurchaseResponse(
            success: true,
            customerId: distinctId,
            features: nil,
            error: nil
        )
    }

    func useFeatureWithPurchase(
        _ request: PurchaseBackedFeatureUseRequest
    ) async throws -> PurchaseBackedFeatureUseResponse {
        usageRequestCount += 1
        return PurchaseBackedFeatureUseResponse(
            customerId: request.customerId,
            featureId: request.featureId,
            code: "feature_found",
            allowed: true,
            unlimited: false,
            balance: 1,
            type: .creditSystem
        )
    }

    func waitUntilSyncStarted() async {
        guard !syncStarted else { return }
        await withCheckedContinuation { syncStartWaiters.append($0) }
    }

    func releaseSync() {
        syncReleased = true
        let waiters = syncResponseWaiters
        syncResponseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func recordedUsageRequestCount() -> Int { usageRequestCount }
}

private actor ControlledDescriptorAllowanceProvider {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func resolve(
        _ evidence: StoredTransactionEvidence
    ) async -> [OptimisticEntitlementAllowance]? {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if !released {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
        return [OptimisticEntitlementAllowance(
            featureId: evidence.productFeatureIds[0],
            kind: .creditSystem,
            unlimited: false,
            allowance: 5
        )]
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

final class PurchaseBackedFeatureUsageTests: XCTestCase {
    private let scope = PurchaseStorageScope(
        appIdentifierHash: "purchase-use-app",
        environment: "production",
        storeEnvironment: .appStore
    )

    func testPurchaseBackedUseCarriesTheAdmittedCustomerKind() async throws {
        for kind in [PurchaseCustomerKind.anonymous, .identified] {
            let identity = MockIdentityService()
            identity.reset(keepAnonymousId: true)
            identity.setAnonymousId("customer-a")
            if kind == .identified { identity.setDistinctId("customer-a") }
            let admittedKind = try XCTUnwrap(identity.purchaseCustomerKind(of: "customer-a"))
            XCTAssertEqual(admittedKind, kind)
            let store = InMemoryTransactionEvidenceStore()
            XCTAssertTrue(store.save([
                "transaction-1": evidence(
                    transactionId: "transaction-1", distinctId: "customer-a",
                    // Deliberately differ from the earlier purchase admission.
                    featureIds: ["credits"], customerKind: kind == .anonymous ? .identified : .anonymous
                ),
            ]))
            let api = PurchaseBackedUsageAPI(results: [.success(.init(
                customerId: "customer-a", featureId: "credits", code: "consumed",
                allowed: true, unlimited: false, balance: 4, type: .metered
            ))])
            let observer = makeObserver(
                api: api, features: PurchaseBackedFeatureRecorder(), identity: identity, store: store
            )

            _ = try await observer.useFeatureWithPendingPurchase(
                distinctId: "customer-a", featureId: "credits", amount: 1,
                entityId: nil, metadata: nil
            )

            let requests = await api.recordedRequests()
            XCTAssertEqual(requests.count, 1)
            XCTAssertEqual(requests.first?.customerKind, kind)
            await observer.stopListening()
        }
    }

    func testRetryAndRelaunchKeepAnonymousKindAfterCustomerSignsIn() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("purchase-use-kind-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = MockIdentityService()
        identity.reset(keepAnonymousId: true)
        identity.setAnonymousId("customer-a")
        let store = TransactionEvidenceStore(customStoragePath: root, scope: scope)
        XCTAssertTrue(store.save([
            "transaction-1": evidence(
                transactionId: "transaction-1", distinctId: "customer-a", featureIds: ["credits"],
                customerKind: try XCTUnwrap(identity.purchaseCustomerKind(of: "customer-a"))
            ),
        ]))
        let response = PurchaseBackedFeatureUseResponse(
            customerId: "customer-a", featureId: "credits", code: "consumed",
            allowed: true, unlimited: false, balance: 4, type: .metered
        )
        let api = PurchaseBackedUsageAPI(results: [
            .failure(URLError(.timedOut)), .failure(URLError(.timedOut)), .success(response),
        ])
        let observer = makeObserver(
            api: api, features: PurchaseBackedFeatureRecorder(), identity: identity, store: store
        )

        // The same distinct id can change kind through identify. Keeping the
        // id isolates the declaration from the queue's customer fence.
        for attempt in 0..<2 {
            if attempt == 1 { identity.setDistinctId("customer-a") }
            do {
                _ = try await observer.useFeatureWithPendingPurchase(
                    distinctId: "customer-a", featureId: "credits", amount: 1,
                    entityId: nil, metadata: nil
                )
                XCTFail("Expected a timeout")
            } catch let error as URLError {
                XCTAssertEqual(error.code, .timedOut)
            }
        }
        await observer.stopListening()
        XCTAssertEqual(identity.purchaseCustomerKind(of: "customer-a"), .identified)

        let reopenedStore = TransactionEvidenceStore(customStoragePath: root, scope: scope)
        XCTAssertEqual(reopenedStore.load().readableValue?["transaction-1"]?.customerKind, .anonymous)
        let firstRequests = await api.recordedRequests()
        let operationId = try XCTUnwrap(firstRequests.first?.purchase.eventId)
        XCTAssertEqual(
            reopenedStore.load().readableValue?["transaction-1"]?.featureUseCustomerKinds?[operationId],
            .anonymous
        )
        let relaunched = makeObserver(
            api: api, features: PurchaseBackedFeatureRecorder(), identity: identity, store: reopenedStore
        )
        _ = try await relaunched.useFeatureWithPendingPurchase(
            distinctId: "customer-a", featureId: "credits", amount: 1,
            entityId: nil, metadata: nil
        )
        let requests = await api.recordedRequests()
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests.map(\.customerKind), [.anonymous, .anonymous, .anonymous])
        XCTAssertEqual(Set(requests.map(\.purchase.eventId)).count, 1)
        XCTAssertEqual(Set(requests.map(\.purchase.transactionJwt)), ["signed-transaction-1"])
        await relaunched.stopListening()
    }

    func testLegacyEvidenceRetryAfterSignInKeepsCustomerKindUndeclared() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-consume-kind-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = MockIdentityService()
        identity.reset(keepAnonymousId: true)
        identity.setAnonymousId("customer-a")
        let store = TransactionEvidenceStore(customStoragePath: root, scope: scope)
        XCTAssertTrue(store.save([
            "transaction-1": evidence(
                transactionId: "transaction-1", distinctId: "customer-a", featureIds: ["credits"],
                customerKind: .anonymous
            ),
        ]))
        // The pre-upgrade SDK retained only the purchase evidence after the
        // consume timed out. It did not persist a consume declaration.
        let file = scope.storageDirectory(customStoragePath: root)
            .appendingPathComponent("transaction-evidence.json")
        var rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var legacy = try XCTUnwrap(rows["transaction-1"] as? [String: Any])
        legacy.removeValue(forKey: "featureUseCustomerKinds")
        rows["transaction-1"] = legacy
        try JSONSerialization.data(withJSONObject: rows).write(to: file)
        XCTAssertNil(store.load().readableValue?["transaction-1"]?.featureUseCustomerKinds)
        identity.setDistinctId("customer-a")

        let api = PurchaseBackedUsageAPI(results: [
            .failure(URLError(.timedOut)), .success(.init(
                customerId: "customer-a", featureId: "credits", code: "consumed",
                allowed: true, unlimited: false, balance: 4, type: .metered
            )),
        ])
        // Relaunch once more after another timeout to catch accidental
        // backfilling of the declaration during the upgraded retry.
        for attempt in 0..<2 {
            let observer = makeObserver(
                api: api, features: PurchaseBackedFeatureRecorder(), identity: identity,
                store: TransactionEvidenceStore(customStoragePath: root, scope: scope)
            )
            do {
                let result = try await observer.useFeatureWithPendingPurchase(
                    distinctId: "customer-a", featureId: "credits", amount: 1,
                    entityId: nil, metadata: nil
                )
                XCTAssertEqual(attempt, 1, "The first upgraded retry should time out")
                XCTAssertEqual(result?.success, true)
            } catch let error as URLError {
                XCTAssertEqual(attempt, 0)
                XCTAssertEqual(error.code, .timedOut)
            }
            await observer.stopListening()
            XCTAssertNil(store.load().readableValue?["transaction-1"]?.featureUseCustomerKinds)
        }
        let requests = await api.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.customerKind == nil })
        XCTAssertEqual(Set(requests.map(\.purchase.eventId)).count, 1)
        XCTAssertEqual(Set(requests.map(\.purchase.transactionJwt)), ["signed-transaction-1"])
    }

    func testRetryAfterAnotherCustomersRestoreAndOwnershipMoveKeepsAnonymousKind() async throws {
        try await assertRetryKindSurvivesRestoreAndOwnershipMove(legacy: false)
    }

    func testLegacyRetryAfterAnotherCustomersRestoreAndOwnershipMoveKeepsKindUndeclared() async throws {
        try await assertRetryKindSurvivesRestoreAndOwnershipMove(legacy: true)
    }

    private func assertRetryKindSurvivesRestoreAndOwnershipMove(legacy: Bool) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("purchase-use-claim-kind-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = MockIdentityService()
        identity.reset(keepAnonymousId: true)
        identity.setAnonymousId("customer-a")
        let store = TransactionEvidenceStore(customStoragePath: root, scope: scope)
        XCTAssertTrue(store.save([
            "transaction-1": evidence(
                transactionId: "transaction-1", distinctId: "customer-a",
                featureIds: ["credits"], customerKind: .anonymous
            ),
        ]))
        if legacy {
            // Pre-upgrade evidence has no consume declaration, even if its
            // reconstructed operation already reached the server.
            let file = scope.storageDirectory(customStoragePath: root)
                .appendingPathComponent("transaction-evidence.json")
            var rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            var row = try XCTUnwrap(rows["transaction-1"] as? [String: Any])
            row.removeValue(forKey: "featureUseCustomerKinds")
            rows["transaction-1"] = row
            try JSONSerialization.data(withJSONObject: rows).write(to: file)
        }
        let api = PurchaseBackedUsageAPI(
            results: [
                .failure(URLError(.timedOut)),
                .failure(URLError(.timedOut)),
                .success(.init(
                    customerId: "customer-a", featureId: "credits", code: "consumed",
                    allowed: true, unlimited: false, balance: 4, type: .metered
                )),
            ],
            // Keep A's returning purchase pending so the same use can retry.
            syncFailureCustomerIds: ["customer-a"]
        )
        let first = makeObserver(
            api: api, features: PurchaseBackedFeatureRecorder(), identity: identity, store: store
        )
        do {
            _ = try await first.useFeatureWithPendingPurchase(
                distinctId: "customer-a", featureId: "credits", amount: 1,
                entityId: nil, metadata: nil
            )
            XCTFail("Expected a timeout")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut)
        }
        await first.stopListening()
        let firstRequests = await api.recordedRequests()
        let operationId = try XCTUnwrap(firstRequests.first?.purchase.eventId)
        let expectedKinds: [String: PurchaseCustomerKind]? = legacy ? nil : [operationId: .anonymous]
        XCTAssertEqual(store.load().readableValue?["transaction-1"]?.featureUseCustomerKinds, expectedKinds)

        // Another customer's explicit Restore replaces A's retained entry
        // through admitClaim. The server answers it, settling B's entry.
        identity.setDistinctId("customer-b")
        let restoreStore = TransactionEvidenceStore(customStoragePath: root, scope: scope)
        let item = StoreTransactionRecoveryItem(
            update: VerifiedStoreTransactionUpdate(
                transactionId: "transaction-1", originalTransactionId: "original-transaction-1",
                productId: "product-transaction-1",
                appAccountToken: scope.appAccountToken(distinctId: "customer-a"),
                isRevoked: false, isUpgraded: false, finish: {}
            ),
            jwsRepresentation: "signed-transaction-1"
        )
        let restoring = TransactionObserver(
            api: api, features: PurchaseBackedFeatureRecorder(), identity: identity,
            settings: NuxieRuntimeSettings(configuration: NuxieConfiguration(apiKey: "purchase-use-test")),
            eventSink: PurchaseBackedEventSink(),
            transactionServiceProvider: { fatalError("retained cross-customer claim needs no checkout binding") },
            evidenceStore: restoreStore, purchaseStorageScope: scope,
            dateProvider: MockDateProvider(initialDate: Date(timeIntervalSince1970: 100)),
            activeStoreOriginalTransactionIDs: { [] },
            unfinishedRecoveryTransactions: { [] },
            currentEntitlementRecoveryTransactions: { [item] }
        )
        let restored = await restoring.syncCurrentEntitlements(distinctId: "customer-b", purpose: .restore)
        XCTAssertEqual(restored.granted, 1)
        await restoring.stopListening()

        let returningStore = TransactionEvidenceStore(customStoragePath: root, scope: scope)
        let claimed = try XCTUnwrap(returningStore.load().readableValue?["transaction-1"])
        XCTAssertEqual(claimed.distinctId, "customer-b")
        XCTAssertTrue(claimed.isSettled)
        XCTAssertEqual(claimed.featureUseCustomerKinds, expectedKinds)

        // A signs in with the same id. A verified producer now replaces B's
        // settled entry through performVerifiedCommit, restoring selection
        // metadata but preserving the earlier consume's admission.
        identity.setDistinctId("customer-a")
        let returning = makeObserver(
            api: api, features: PurchaseBackedFeatureRecorder(), identity: identity, store: returningStore
        )
        let moved = await returning.commit(.verified(
            VerifiedPurchaseEvidence(
                transactionJws: "signed-transaction-1", transactionId: "transaction-1",
                originalTransactionId: "original-transaction-1", productId: "product-transaction-1",
                appAccountToken: scope.appAccountToken(distinctId: "customer-a"),
                requester: .named("customer-a"), productFeatureIds: ["credits"],
                finishRequired: false, resolvesPendingPurchase: false,
                allowsDurableCheckoutAuthority: false, requiresAuthorityResolution: false,
                syncReason: .purchase
            ),
            source: .checkout
        ))
        XCTAssertTrue(moved.committed)
        let synced = await moved.syncTask?.value
        XCTAssertEqual(synced, false)
        await returning.stopListening()

        // Reopen after both ownership changes, then retry across another
        // timeout and relaunch. Every request must retain the first kind.
        for attempt in 0..<2 {
            let reopenedStore = TransactionEvidenceStore(customStoragePath: root, scope: scope)
            let retained = try XCTUnwrap(reopenedStore.load().readableValue?["transaction-1"])
            XCTAssertEqual(retained.distinctId, "customer-a")
            XCTAssertEqual(retained.customerKind, .identified)
            XCTAssertEqual(retained.featureUseCustomerKinds, expectedKinds)
            let observer = makeObserver(
                api: api, features: PurchaseBackedFeatureRecorder(), identity: identity, store: reopenedStore
            )
            do {
                let result = try await observer.useFeatureWithPendingPurchase(
                    distinctId: "customer-a", featureId: "credits", amount: 1,
                    entityId: nil, metadata: nil
                )
                XCTAssertEqual(attempt, 1, "The first retry should time out")
                XCTAssertEqual(result?.success, true)
            } catch let error as URLError {
                XCTAssertEqual(attempt, 0)
                XCTAssertEqual(error.code, .timedOut)
            }
            await observer.stopListening()
        }
        let requests = await api.recordedRequests()
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests.map(\.customerKind), Array(repeating: legacy ? nil : .anonymous, count: 3))
        XCTAssertEqual(Set(requests.map(\.purchase.eventId)), [operationId])
        XCTAssertEqual(Set(requests.map(\.purchase.transactionJwt)), ["signed-transaction-1"])
    }

    func testUnsavedConsumeAdmissionFallsBackWithoutSendingPurchaseEvidence() async throws {
        let identity = MockIdentityService()
        identity.setDistinctId("customer-a")
        let store = WriteRefusingEvidenceStore(entries: [
            "transaction-1": evidence(
                transactionId: "transaction-1", distinctId: "customer-a", featureIds: ["credits"]
            ),
        ])
        store.refusesWrites = true
        let api = PurchaseBackedUsageAPI(results: [])
        let observer = makeObserver(
            api: api, features: PurchaseBackedFeatureRecorder(), identity: identity, store: store
        )
        let result = try await observer.useFeatureWithPendingPurchase(
            distinctId: "customer-a", featureId: "credits", amount: 1, entityId: nil, metadata: nil
        )
        XCTAssertNil(result)
        let requests = await api.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(store.load().readableValue?["transaction-1"]?.featureUseCustomerKinds, [:])
        await observer.stopListening()
    }

    func testAtomicRequestEncodesTheServerContract() throws {
        let request = PurchaseBackedFeatureUseRequest(
            customerId: "customer-a",
            featureId: "credits",
            requiredBalance: 2.5,
            eventData: .init(
                value: 2.5,
                properties: ["source": AnyCodable("export")]
            ),
            entityId: "workspace-1",
            purchase: .init(
                transactionJwt: "signed-jws",
                eventId: "stable-event"
            )
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request))
                as? [String: Any]
        )
        XCTAssertEqual(object["customerId"] as? String, "customer-a")
        XCTAssertEqual(object["featureId"] as? String, "credits")
        XCTAssertEqual(object["requiredBalance"] as? Double, 2.5)
        XCTAssertEqual(object["idempotencyKey"] as? String, "stable-event")
        XCTAssertEqual(object["entityId"] as? String, "workspace-1")
        let purchase = try XCTUnwrap(object["purchase"] as? [String: Any])
        XCTAssertEqual(purchase["transaction_jwt"] as? String, "signed-jws")
        XCTAssertEqual(purchase["event_id"] as? String, "stable-event")
        let eventData = try XCTUnwrap(object["eventData"] as? [String: Any])
        XCTAssertEqual(eventData["value"] as? Double, 2.5)
        XCTAssertEqual(
            (eventData["properties"] as? [String: Any])?["source"] as? String,
            "export"
        )
    }

    func testAtomicResponseDecodesFractionalAuthoritativeBalance() throws {
        let data = Data(
            #"{"customerId":"customer-a","featureId":"credits","code":"entitled","allowed":true,"unlimited":false,"balance":2.5,"type":"creditSystem"}"#.utf8
        )

        let response = try JSONDecoder().decode(
            PurchaseBackedFeatureUseResponse.self,
            from: data
        )

        XCTAssertEqual(response.balance, 2.5)
        XCTAssertEqual(
            response.featureCheckResult(requiredBalance: 1).balance,
            2.5
        )
    }

    func testMatchingPurchaseEvidenceIsAppliedAndConsumedAtomically() async throws {
        for replay in [false, true] {
            let identity = MockIdentityService()
            identity.setDistinctId("customer-a")
            let store = InMemoryTransactionEvidenceStore()
            XCTAssertTrue(store.save([
                "transaction-1": evidence(
                    transactionId: "transaction-1",
                    distinctId: "customer-a",
                    featureIds: ["credits"]
                ),
            ]))
            let response = PurchaseBackedFeatureUseResponse(
                customerId: "customer-a",
                featureId: "credits",
                code: "entitled",
                allowed: true,
                unlimited: false,
                balance: 3,
                type: .creditSystem, idempotentReplay: replay
            )
            let api = PurchaseBackedUsageAPI(results: [.success(response)])
            let features = PurchaseBackedFeatureRecorder()
            let observer = makeObserver(
                api: api,
                features: features,
                identity: identity,
                store: store
            )

            let result = try await observer.useFeatureWithPendingPurchase(
                distinctId: "customer-a",
                featureId: "credits",
                amount: 2,
                entityId: "workspace-1",
                metadata: ["source": AnyCodable("export")]
            )

            XCTAssertNil(result?.usage)
            XCTAssertEqual(result?.authoritativeAccess?.balance, 3)
            let recordedRequests = await api.recordedRequests()
            let request = try XCTUnwrap(recordedRequests.first)
            XCTAssertEqual(request.customerId, "customer-a")
            XCTAssertEqual(request.featureId, "credits")
            XCTAssertEqual(request.requiredBalance, 2)
            XCTAssertEqual(request.entityId, "workspace-1")
            XCTAssertEqual(request.purchase.transactionJwt, "signed-transaction-1")
            XCTAssertEqual(request.eventData.value, 2)
            XCTAssertEqual(request.eventData.properties?["source"], AnyCodable("export"))
            XCTAssertFalse(request.purchase.eventId.isEmpty)
            XCTAssertEqual(request.idempotencyKey, request.purchase.eventId)
            let updateCount = await features.recordedUpdates().count
            XCTAssertEqual(updateCount, replay ? 0 : 1)
            let invalidationCount = await features.invalidationCount()
            XCTAssertEqual(invalidationCount, 1)
            XCTAssertNotNil(store.load().valueTreatingAbsentAsEmpty([:])!["transaction-1"]?.answeredAt)
        }
    }

    func testProjectionRefreshRoutesConcurrentSpendAwayFromAtomicShortcut() async throws {
        let identity = MockIdentityService()
        identity.setDistinctId("customer-a")
        let store = InMemoryTransactionEvidenceStore()
        XCTAssertTrue(store.save([
            "transaction-1": evidence(
                transactionId: "transaction-1",
                distinctId: "customer-a",
                featureIds: ["credits"]
            ),
        ]))
        let api = PurchaseBackedUsageAPI(results: [])
        let allowances = ControlledDescriptorAllowanceProvider()
        let observer = TransactionObserver(
            api: api,
            features: PurchaseBackedFeatureRecorder(),
            identity: identity,
            settings: NuxieRuntimeSettings(
                configuration: NuxieConfiguration(apiKey: "purchase-use-test")
            ),
            eventSink: DiscardingSystemEventSink(),
            transactionServiceProvider: { fatalError("unused") },
            evidenceStore: store,
            descriptorAllowanceProvider: { evidence in
                await allowances.resolve(evidence)
            },
            purchaseStorageScope: scope,
            dateProvider: MockDateProvider(
                initialDate: Date(timeIntervalSince1970: 100)
            ),
            activeStoreOriginalTransactionIDs: { [] }
        )

        let refresh = Task { await observer.retryStoredEvidence() }
        await allowances.waitUntilStarted()

        let result = try await observer.useFeatureWithPendingPurchase(
            distinctId: "customer-a",
            featureId: "credits",
            amount: 1,
            entityId: nil,
            metadata: nil
        )

        XCTAssertNil(result)
        let requestCount = await api.recordedRequests().count
        XCTAssertEqual(requestCount, 0)
        await allowances.release()
        await refresh.value
    }

    func testFinalAtomicCreditReportsSuccessfulCommandAndPostUseAccess() async throws {
        let contract = try AtomicPurchaseSyncFixture.load()
        let identity = MockIdentityService()
        identity.setDistinctId("customer-a")
        let store = InMemoryTransactionEvidenceStore()
        XCTAssertTrue(store.save([
            "transaction-1": evidence(
                transactionId: "transaction-1",
                distinctId: "customer-a",
                featureIds: ["api_calls"]
            ),
        ]))
        let response = PurchaseBackedFeatureUseResponse(
            customerId: "customer-a",
            featureId: "credit_wallet",
            code: "feature_found",
            allowed: false,
            unlimited: false,
            balance: 0,
            type: .creditSystem
        )
        let events = PurchaseBackedEventSink()
        let observer = makeObserver(
            api: PurchaseBackedUsageAPI(results: [.success(response)]),
            features: PurchaseBackedFeatureRecorder(),
            identity: identity,
            store: store,
            eventSink: events
        )

        let result = try await observer.useFeatureWithPendingPurchase(
            distinctId: "customer-a",
            featureId: "api_calls",
            amount: 1,
            entityId: nil,
            metadata: nil
        )

        XCTAssertEqual(result?.success, contract.acceptance.commandSuccess)
        XCTAssertEqual(
            result?.authoritativeAccess?.allowed,
            contract.acceptance.postUseAccess.allowedAfterFinalFiniteUnit
        )
        XCTAssertEqual(
            result?.authoritativeAccess?.balance,
            contract.acceptance.postUseAccess.balanceAfterFinalFiniteUnit
        )
        XCTAssertNotNil(store.load().valueTreatingAbsentAsEmpty([:])!["transaction-1"]?.answeredAt)
        XCTAssertEqual(
            events.events().map(\.0),
            Array(
                repeating: contract.event.name,
                count: contract.acceptance.emissionsPerAcceptedReceipt
            )
        )
    }

    func testAcceptedAtomicUseEmitsPurchaseSynchronized() async throws {
        let contract = try AtomicPurchaseSyncFixture.load()
        let identity = MockIdentityService()
        identity.setDistinctId("customer-a")
        let store = InMemoryTransactionEvidenceStore()
        XCTAssertTrue(store.save([
            "transaction-1": evidence(
                transactionId: "transaction-1",
                distinctId: "customer-a",
                featureIds: ["credits"]
            ),
        ]))
        let response = PurchaseBackedFeatureUseResponse(
            customerId: "customer-a",
            featureId: "credits",
            code: "entitled",
            allowed: true,
            unlimited: false,
            balance: 3,
            type: .creditSystem
        )
        let events = PurchaseBackedEventSink()
        let observer = makeObserver(
            api: PurchaseBackedUsageAPI(results: [.success(response)]),
            features: PurchaseBackedFeatureRecorder(),
            identity: identity,
            store: store,
            eventSink: events
        )

        _ = try await observer.useFeatureWithPendingPurchase(
            distinctId: "customer-a",
            featureId: "credits",
            amount: 2,
            entityId: nil,
            metadata: nil
        )

        let emitted = events.events()
        XCTAssertEqual(emitted.count, contract.acceptance.emissionsPerAcceptedReceipt)
        XCTAssertEqual(emitted[0].0, contract.event.name)
        XCTAssertEqual(emitted[0].1?.keys.sorted(), contract.event.properties)
        XCTAssertEqual(emitted[0].1?["transaction_id"] as? String, "transaction-1")
        XCTAssertEqual(
            emitted[0].1?["original_transaction_id"] as? String,
            "original-transaction-1"
        )
        XCTAssertEqual(
            emitted[0].1?["product_id"] as? String,
            "product-transaction-1"
        )
        XCTAssertEqual(emitted[0].1?["customer_id"] as? String, "customer-a")
    }

    func testRetryUsesStableEventIdentityAndRetainsEvidenceUntilSuccess() async throws {
        let contract = try AtomicPurchaseSyncFixture.load()
        XCTAssertEqual(contract.suite, "events/atomic-purchase-sync")
        XCTAssertEqual(contract.version, 2)
        XCTAssertEqual(contract.retry.requestIdentity, "stable_purchase_use_event_id")
        XCTAssertEqual(contract.acceptance.boundary, "decoded_2xx")
        XCTAssertTrue(contract.acceptance.captureBeforeRetiringEvidence)
        XCTAssertFalse(contract.acceptance.ordinaryUsageFallback)
        let identity = MockIdentityService()
        identity.setDistinctId("customer-a")
        let store = InMemoryTransactionEvidenceStore()
        XCTAssertTrue(store.save([
            "transaction-1": evidence(
                transactionId: "transaction-1",
                distinctId: "customer-a",
                featureIds: ["credits"]
            ),
        ]))
        let response = PurchaseBackedFeatureUseResponse(
            customerId: "customer-a",
            featureId: "credits",
            code: "entitled",
            allowed: true,
            unlimited: false,
            balance: 4,
            type: .creditSystem
        )
        let api = PurchaseBackedUsageAPI(results: [
            .failure(URLError(.timedOut)),
            .success(response),
        ])
        let events = PurchaseBackedEventSink()
        let observer = makeObserver(
            api: api,
            features: PurchaseBackedFeatureRecorder(),
            identity: identity,
            store: store,
            eventSink: events
        )

        do {
            _ = try await observer.useFeatureWithPendingPurchase(
                distinctId: "customer-a",
                featureId: "credits",
                amount: 1,
                entityId: nil,
                metadata: nil
            )
            XCTFail("Expected the first request to fail")
        } catch is URLError {}
        if contract.retry.retainEvidenceOnFailure {
            XCTAssertEqual(
                store.load().valueTreatingAbsentAsEmpty([:])!["transaction-1"]?.transactionJws,
                "signed-transaction-1"
            )
        }
        if !contract.retry.emitOnFailure {
            XCTAssertTrue(events.events().isEmpty)
        }

        _ = try await observer.useFeatureWithPendingPurchase(
            distinctId: "customer-a",
            featureId: "credits",
            amount: 1,
            entityId: nil,
            metadata: nil
        )

        let requests = await api.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].purchase.eventId, requests[1].purchase.eventId)
        XCTAssertEqual(requests[0].idempotencyKey, requests[0].purchase.eventId)
        XCTAssertEqual(requests[0].idempotencyKey, requests[1].idempotencyKey)
        XCTAssertEqual(
            events.events().map(\.0),
            Array(
                repeating: contract.event.name,
                count: contract.acceptance.emissionsPerAcceptedReceipt
            )
        )

        let duplicate = try await observer.useFeatureWithPendingPurchase(
            distinctId: "customer-a",
            featureId: "credits",
            amount: 1,
            entityId: nil,
            metadata: nil
        )
        XCTAssertNil(duplicate)
        XCTAssertEqual(
            events.events().map(\.0),
            Array(
                repeating: contract.event.name,
                count: contract.acceptance.emissionsPerAcceptedReceipt
            )
        )
    }

    /// The answer is saved before purchase synced is captured, so a report
    /// that cannot be captured does not undo it: the use still returns the
    /// server's result, the entry stays answered, and the next use takes the
    /// ordinary Feature command.
    func testAcceptedUseIsSavedBeforeItsPurchaseSyncedReport() async throws {
        let identity = MockIdentityService()
        identity.setDistinctId("customer-a")
        let store = InMemoryTransactionEvidenceStore()
        XCTAssertTrue(store.save([
            "transaction-1": evidence(
                transactionId: "transaction-1",
                distinctId: "customer-a",
                featureIds: ["credits"]
            ),
        ]))
        let response = PurchaseBackedFeatureUseResponse(
            customerId: "customer-a",
            featureId: "credits",
            code: "feature_found",
            allowed: true,
            unlimited: false,
            balance: 4,
            type: .creditSystem
        )
        let api = PurchaseBackedUsageAPI(results: [.success(response)])
        let events = PurchaseBackedEventSink(captureResults: [false])
        let observer = makeObserver(
            api: api,
            features: PurchaseBackedFeatureRecorder(),
            identity: identity,
            store: store,
            eventSink: events
        )

        let used = try await observer.useFeatureWithPendingPurchase(
            distinctId: "customer-a",
            featureId: "credits",
            amount: 1,
            entityId: nil,
            metadata: nil
        )
        XCTAssertEqual(used?.success, true, "the server consumed the Feature")
        XCTAssertNotNil(store.load().valueTreatingAbsentAsEmpty([:])!["transaction-1"]?.answeredAt)
        XCTAssertEqual(events.captureAttempts().count, 1)
        XCTAssertTrue(events.events().isEmpty)

        let next = try await observer.useFeatureWithPendingPurchase(
            distinctId: "customer-a",
            featureId: "credits",
            amount: 1,
            entityId: nil,
            metadata: nil
        )
        XCTAssertNil(next, "the next use takes the ordinary Feature command")
        let requests = await api.recordedRequests()
        XCTAssertEqual(requests.count, 1)
    }

    func testFractionalBalanceBelowDefaultUseRequirementIsNotAllowed() {
        let access = FeatureAccess.withBalance(
            0.5,
            unlimited: false,
            type: .creditSystem
        )

        XCTAssertFalse(access.allowed)
        XCTAssertTrue(access.hasBalance)
    }

    func testNon2xxDenialRetainsEvidenceForAChangedAuthoritativeRetry() async throws {
        let identity = MockIdentityService()
        identity.setDistinctId("customer-a")
        let store = InMemoryTransactionEvidenceStore()
        XCTAssertTrue(store.save([
            "transaction-1": evidence(
                transactionId: "transaction-1",
                distinctId: "customer-a",
                featureIds: ["credits"]
            ),
        ]))
        let features = PurchaseBackedFeatureRecorder()
        let events = PurchaseBackedEventSink()
        let observer = makeObserver(
            api: PurchaseBackedUsageAPI(results: [
                .failure(NuxieNetworkError.httpError(
                    statusCode: 402,
                    message: "Insufficient feature balance"
                )),
            ]),
            features: features,
            identity: identity,
            store: store,
            eventSink: events
        )

        do {
            _ = try await observer.useFeatureWithPendingPurchase(
                distinctId: "customer-a",
                featureId: "credits",
                amount: 2,
                entityId: nil,
                metadata: nil
            )
            XCTFail("Expected the rejected command to throw")
        } catch NuxieNetworkError.httpError(let statusCode, _, _, _) {
            XCTAssertEqual(statusCode, 402)
        }

        XCTAssertEqual(store.load().valueTreatingAbsentAsEmpty([:])!["transaction-1"]?.transactionJws, "signed-transaction-1")
        XCTAssertNil(store.load().valueTreatingAbsentAsEmpty([:])!["transaction-1"]?.answeredAt)
        XCTAssertTrue(events.events().isEmpty)
        let updateCount = await features.recordedUpdates().count
        XCTAssertEqual(updateCount, 0)
    }

    func testAcceptsAuthoritativeBalanceFeatureReturnedByTheServer() async throws {
        let identity = MockIdentityService()
        identity.setDistinctId("customer-a")
        let store = InMemoryTransactionEvidenceStore()
        XCTAssertTrue(store.save([
            "transaction-1": evidence(
                transactionId: "transaction-1",
                distinctId: "customer-a",
                featureIds: ["exports"]
            ),
        ]))
        let response = PurchaseBackedFeatureUseResponse(
            customerId: "customer-a",
            featureId: "credit-wallet",
            code: "feature_found",
            allowed: false,
            unlimited: false,
            balance: 8,
            type: .creditSystem
        )
        let features = PurchaseBackedFeatureRecorder()
        let observer = makeObserver(
            api: PurchaseBackedUsageAPI(results: [.success(response)]),
            features: features,
            identity: identity,
            store: store
        )

        let result = try await observer.useFeatureWithPendingPurchase(
            distinctId: "customer-a",
            featureId: "exports",
            amount: 1,
            entityId: nil,
            metadata: nil
        )

        XCTAssertEqual(result?.featureId, "exports")
        XCTAssertEqual(result?.authoritativeAccess?.allowed, false)
        XCTAssertNil(result?.authoritativeAccess?.balance)
        XCTAssertEqual(result?.authoritativeAccess?.type, .metered)
        let updates = await features.recordedUpdates()
        let update = try XCTUnwrap(updates.first)
        XCTAssertEqual(update.0.featureId, "credit-wallet")
        XCTAssertEqual(update.1, "exports")
    }

    func testEvidenceForAnotherCustomerOrFeatureIsNeverSubmitted() async throws {
        let identity = MockIdentityService()
        identity.setDistinctId("customer-b")
        let store = InMemoryTransactionEvidenceStore()
        XCTAssertTrue(store.save([
            "transaction-a": evidence(
                transactionId: "transaction-a",
                distinctId: "customer-a",
                featureIds: ["credits"]
            ),
            "transaction-b": evidence(
                transactionId: "transaction-b",
                distinctId: "customer-b",
                featureIds: ["exports"]
            ),
        ]))
        let api = PurchaseBackedUsageAPI(results: [])
        let observer = makeObserver(
            api: api,
            features: PurchaseBackedFeatureRecorder(),
            identity: identity,
            store: store
        )

        let result = try await observer.useFeatureWithPendingPurchase(
            distinctId: "customer-b",
            featureId: "credits",
            amount: 1,
            entityId: nil,
            metadata: nil
        )

        XCTAssertNil(result)
        let requests = await api.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testMultipleMatchingPurchasesFailClosedWithoutSendingSignedEvidence() async throws {
        let identity = MockIdentityService()
        identity.setDistinctId("customer-a")
        let store = InMemoryTransactionEvidenceStore()
        XCTAssertTrue(store.save([
            "transaction-1": evidence(
                transactionId: "transaction-1",
                distinctId: "customer-a",
                featureIds: ["credits"]
            ),
            "transaction-2": evidence(
                transactionId: "transaction-2",
                distinctId: "customer-a",
                featureIds: ["credits"]
            ),
        ]))
        let api = PurchaseBackedUsageAPI(results: [])
        let observer = makeObserver(
            api: api,
            features: PurchaseBackedFeatureRecorder(),
            identity: identity,
            store: store
        )

        let result = try await observer.useFeatureWithPendingPurchase(
            distinctId: "customer-a",
            featureId: "credits",
            amount: 1,
            entityId: nil,
            metadata: nil
        )

        XCTAssertNil(result)
        let requests = await api.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testRevokedSyncedAndEmptyEvidenceNeverEnterTheAtomicCommand() async throws {
        let identity = MockIdentityService()
        identity.setDistinctId("customer-a")
        let store = InMemoryTransactionEvidenceStore()
        XCTAssertTrue(store.save([
            "revoked": evidence(
                transactionId: "revoked",
                distinctId: "customer-a",
                featureIds: ["credits"],
                isRevoked: true
            ),
            "synced": evidence(
                transactionId: "synced",
                distinctId: "customer-a",
                featureIds: ["credits"],
                transactionJws: "",
                answeredAt: Date(timeIntervalSince1970: 75)
            ),
            "empty": evidence(
                transactionId: "empty",
                distinctId: "customer-a",
                featureIds: ["credits"],
                transactionJws: ""
            ),
        ]))
        let api = PurchaseBackedUsageAPI(results: [])
        let observer = makeObserver(
            api: api,
            features: PurchaseBackedFeatureRecorder(),
            identity: identity,
            store: store
        )

        let result = try await observer.useFeatureWithPendingPurchase(
            distinctId: "customer-a",
            featureId: "credits",
            amount: 1,
            entityId: nil,
            metadata: nil
        )

        XCTAssertNil(result)
        let requests = await api.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(store.load().valueTreatingAbsentAsEmpty([:])!.count, 3)
    }

    func testExistingNativeEvidenceRemainsEligibleAfterDelegateConfigurationWhileTestStoreDoesNot() async throws {
        let identity = MockIdentityService()
        identity.setDistinctId("customer-a")

        let providerStore = InMemoryTransactionEvidenceStore()
        XCTAssertTrue(providerStore.save([
            "provider": evidence(
                transactionId: "provider",
                distinctId: "customer-a",
                featureIds: ["credits"]
            ),
        ]))
        let providerApi = PurchaseBackedUsageAPI(results: [.success(
            PurchaseBackedFeatureUseResponse(
                customerId: "customer-a",
                featureId: "credits",
                code: "feature_found",
                allowed: true,
                unlimited: false,
                balance: 4,
                type: .creditSystem
            )
        )])
        let providerConfiguration = NuxieConfiguration(apiKey: "purchase-use-test")
        providerConfiguration.purchaseDelegate = MockPurchaseDelegate()
        let providerObserver = makeObserver(
            api: providerApi,
            features: PurchaseBackedFeatureRecorder(),
            identity: identity,
            store: providerStore,
            configuration: providerConfiguration
        )

        let providerResult = try await providerObserver.useFeatureWithPendingPurchase(
            distinctId: "customer-a",
            featureId: "credits",
            amount: 1,
            entityId: nil,
            metadata: nil
        )

        let testScope = PurchaseStorageScope(
            appIdentifierHash: "purchase-use-app",
            environment: "production",
            storeEnvironment: .testStore
        )
        let testStore = InMemoryTransactionEvidenceStore()
        XCTAssertTrue(testStore.save([
            "test-store": evidence(
                transactionId: "test-store",
                distinctId: "customer-a",
                featureIds: ["credits"],
                scope: testScope
            ),
        ]))
        let testApi = PurchaseBackedUsageAPI(results: [])
        let testObserver = makeObserver(
            api: testApi,
            features: PurchaseBackedFeatureRecorder(),
            identity: identity,
            store: testStore,
            observerScope: testScope
        )

        let testResult = try await testObserver.useFeatureWithPendingPurchase(
            distinctId: "customer-a",
            featureId: "credits",
            amount: 1,
            entityId: nil,
            metadata: nil
        )

        XCTAssertNotNil(providerResult)
        XCTAssertNil(testResult)
        let providerRequests = await providerApi.recordedRequests()
        let testRequests = await testApi.recordedRequests()
        XCTAssertEqual(providerRequests.count, 1)
        XCTAssertTrue(testRequests.isEmpty)
        XCTAssertNotNil(providerStore.load().valueTreatingAbsentAsEmpty([:])!["provider"]?.answeredAt)
        XCTAssertEqual(testStore.load().valueTreatingAbsentAsEmpty([:])!["test-store"]?.transactionJws, "signed-test-store")
    }

    func testConcurrentUsesCannotBothConsumeTheSamePendingPurchase() async throws {
        let identity = MockIdentityService()
        identity.setDistinctId("customer-a")
        let store = InMemoryTransactionEvidenceStore()
        XCTAssertTrue(store.save([
            "transaction-1": evidence(
                transactionId: "transaction-1",
                distinctId: "customer-a",
                featureIds: ["credits"]
            ),
        ]))
        let api = ControlledPurchaseBackedUsageAPI()
        let features = PurchaseBackedFeatureRecorder()
        let settings = NuxieRuntimeSettings(
            configuration: NuxieConfiguration(apiKey: "purchase-use-test")
        )
        let observer = TransactionObserver(
            api: api,
            features: features,
            identity: identity,
            settings: settings,
            eventSink: PurchaseBackedEventSink(),
            transactionServiceProvider: { fatalError("unused") },
            evidenceStore: store,
            purchaseStorageScope: scope,
            dateProvider: MockDateProvider(
                initialDate: Date(timeIntervalSince1970: 100)
            ),
            activeStoreOriginalTransactionIDs: { [] }
        )

        let first = Task {
            try await observer.useFeatureWithPendingPurchase(
                distinctId: "customer-a",
                featureId: "credits",
                amount: 1,
                entityId: nil,
                metadata: nil
            )
        }
        await api.waitUntilStarted()
        let second = Task {
            try await observer.useFeatureWithPendingPurchase(
                distinctId: "customer-a",
                featureId: "credits",
                amount: 1,
                entityId: nil,
                metadata: nil
            )
        }
        let backgroundSync = await observer.syncTransaction(
            transactionJws: "signed-transaction-1",
            transactionId: "transaction-1",
            productId: "product-transaction-1",
            originalTransactionId: "original-transaction-1"
        )
        await api.release()

        let firstResult = try await first.value
        let secondResult = try await second.value
        XCTAssertNotNil(firstResult)
        XCTAssertNil(secondResult)
        XCTAssertFalse(backgroundSync)
        let count = await api.requestCount()
        XCTAssertEqual(count, 1)
        let syncCount = await api.recordedSyncRequestCount()
        XCTAssertEqual(syncCount, 0)
    }

    /// A Restore of a purchase that a purchase-backed Feature command holds
    /// waits for the command, then admits and sends its claim. The claim
    /// gets the server's answer, and the command's own answer still lands.
    func testRestoreWaitsForTheFeatureCommandHoldingThePurchase() async throws {
        let identity = MockIdentityService()
        identity.setDistinctId("customer-a")
        let store = InMemoryTransactionEvidenceStore()
        XCTAssertTrue(store.save([
            "transaction-1": evidence(
                transactionId: "transaction-1",
                distinctId: "customer-a",
                featureIds: ["credits"]
            ),
        ]))
        let item = StoreTransactionRecoveryItem(
            update: VerifiedStoreTransactionUpdate(
                transactionId: "transaction-1",
                originalTransactionId: "original-transaction-1",
                productId: "product-transaction-1",
                appAccountToken: scope.appAccountToken(distinctId: "customer-a"),
                isRevoked: false,
                isUpgraded: false,
                finish: {}
            ),
            jwsRepresentation: "signed-transaction-1"
        )
        let arrival = ScanArrival()
        let api = ControlledPurchaseBackedUsageAPI()
        let settings = NuxieRuntimeSettings(
            configuration: NuxieConfiguration(apiKey: "purchase-use-test")
        )
        let clock = MockDateProvider(initialDate: Date(timeIntervalSince1970: 100))
        let box = LateBound<TransactionService>()
        let observer = TransactionObserver(
            api: api,
            features: PurchaseBackedFeatureRecorder(),
            identity: identity,
            settings: settings,
            eventSink: PurchaseBackedEventSink(),
            transactionServiceProvider: { box.get() },
            evidenceStore: store,
            purchaseStorageScope: scope,
            dateProvider: clock,
            activeStoreOriginalTransactionIDs: { [] },
            unfinishedRecoveryTransactions: { [] },
            currentEntitlementRecoveryTransactions: {
                await arrival.arrive()
                return [item]
            }
        )
        box.set(TransactionService(
            productService: MockFactory.shared.productService,
            transactionObserver: observer,
            pendingPurchaseStore: InMemoryPendingPurchaseStore(),
            dateProvider: clock,
            settings: settings,
            eventSink: PurchaseBackedEventSink(),
            purchaseStorageScope: scope,
            identityService: identity
        ))
        addTeardownBlock { await observer.stopListening() }

        let use = Task {
            try await observer.useFeatureWithPendingPurchase(
                distinctId: "customer-a",
                featureId: "credits",
                amount: 1,
                entityId: nil,
                metadata: nil
            )
        }
        await api.waitUntilStarted()
        let restore = Task {
            await observer.syncCurrentEntitlements(distinctId: "customer-a", purpose: .restore)
        }
        await arrival.wait()
        try await Task.sleep(nanoseconds: 50_000_000)
        await api.release()

        let claims = await restore.value
        XCTAssertEqual(claims.granted, 1, "the claim is sent after the command and answered")
        let syncCount = await api.recordedSyncRequestCount()
        XCTAssertEqual(syncCount, 1)
        let used = try await use.value
        XCTAssertEqual(used?.success, true)
    }

    /// A purchase-backed Feature command writes its post-use result in the
    /// same step as its answer, and lets go of the purchase only after that.
    /// A Restore waiting on the purchase admits its claim afterwards, so the
    /// Restore's newer Features are written last, even while the command's
    /// own writes are slow.
    func testFeatureCommandWritesItsResultBeforeAWaitingRestoreAdmits() async throws {
        let identity = MockIdentityService()
        identity.setDistinctId("customer-a")
        let store = InMemoryTransactionEvidenceStore()
        XCTAssertTrue(store.save([
            "transaction-1": evidence(
                transactionId: "transaction-1",
                distinctId: "customer-a",
                featureIds: ["credits"]
            ),
        ]))
        let item = StoreTransactionRecoveryItem(
            update: VerifiedStoreTransactionUpdate(
                transactionId: "transaction-1",
                originalTransactionId: "original-transaction-1",
                productId: "product-transaction-1",
                appAccountToken: scope.appAccountToken(distinctId: "customer-a"),
                isRevoked: false,
                isUpgraded: false,
                finish: {}
            ),
            jwsRepresentation: "signed-transaction-1"
        )
        let arrival = ScanArrival()
        let api = RestoreAfterUseAPI()
        let features = OrderedFeatureWrites()
        let settings = NuxieRuntimeSettings(
            configuration: NuxieConfiguration(apiKey: "purchase-use-test")
        )
        let clock = MockDateProvider(initialDate: Date(timeIntervalSince1970: 100))
        let box = LateBound<TransactionService>()
        let observer = TransactionObserver(
            api: api,
            features: features,
            identity: identity,
            settings: settings,
            eventSink: PurchaseBackedEventSink(),
            transactionServiceProvider: { box.get() },
            evidenceStore: store,
            purchaseStorageScope: scope,
            dateProvider: clock,
            activeStoreOriginalTransactionIDs: { [] },
            unfinishedRecoveryTransactions: { [] },
            currentEntitlementRecoveryTransactions: {
                await arrival.arrive()
                return [item]
            }
        )
        box.set(TransactionService(
            productService: MockFactory.shared.productService,
            transactionObserver: observer,
            pendingPurchaseStore: InMemoryPendingPurchaseStore(),
            dateProvider: clock,
            settings: settings,
            eventSink: PurchaseBackedEventSink(),
            purchaseStorageScope: scope,
            identityService: identity
        ))
        addTeardownBlock { await observer.stopListening() }

        let use = Task {
            try await observer.useFeatureWithPendingPurchase(
                distinctId: "customer-a",
                featureId: "credits",
                amount: 1,
                entityId: nil,
                metadata: nil
            )
        }
        await api.waitUntilUseStarted()
        let restore = Task {
            await observer.syncCurrentEntitlements(distinctId: "customer-a", purpose: .restore)
        }
        await arrival.wait()
        try await Task.sleep(nanoseconds: 50_000_000)

        // The server answers the command; its first Feature write is slow.
        await api.releaseUse()
        await features.waitUntilInvalidationHeld()
        for _ in 0..<150 {
            if await features.recordedWrites().contains(where: { $0.hasPrefix("purchase") }) { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        await features.releaseInvalidation()

        let used = try await use.value
        XCTAssertEqual(used?.success, true)
        let claims = await restore.value
        XCTAssertEqual(claims.granted, 1)
        let writes = await features.recordedWrites()
        XCTAssertEqual(
            writes,
            ["invalidate credits", "use credits 4.0", "purchase credits 9.0"],
            "the Restore's Features are written after the command's result"
        )
    }

    /// Every answer asks for the requester's profile again, a purchase-backed
    /// Feature command's included: once its entry is answered the early
    /// unlock ends, and any other Feature the product grants comes from the
    /// profile.
    func testAcceptedUseAsksForTheProfileAgain() async throws {
        let identity = MockIdentityService()
        identity.setDistinctId("customer-a")
        let store = InMemoryTransactionEvidenceStore()
        XCTAssertTrue(store.save([
            "transaction-1": evidence(
                transactionId: "transaction-1",
                distinctId: "customer-a",
                featureIds: ["credits"]
            ),
        ]))
        let api = ControlledPurchaseBackedUsageAPI()
        await api.release()
        let profileRequests = ProfileRequestRecorder()
        let observer = makeControlledObserver(
            api: api,
            features: PurchaseBackedFeatureRecorder(),
            identity: identity,
            store: store,
            refreshProfile: { profileRequests.record($0) }
        )
        addTeardownBlock { await observer.stopListening() }

        let used = try await observer.useFeatureWithPendingPurchase(
            distinctId: "customer-a",
            featureId: "credits",
            amount: 1,
            entityId: nil,
            metadata: nil
        )

        XCTAssertEqual(used?.success, true)
        XCTAssertNotNil(store.load().valueTreatingAbsentAsEmpty([:])?["transaction-1"]?.answeredAt)
        XCTAssertEqual(profileRequests.requests, ["customer-a"], "the answer asks for the profile again")
    }

    /// Nothing is published until the answer is saved, `$purchase_synced`
    /// included. A use whose answer cannot be saved still returns the
    /// server's result, since the server consumed the Feature, but reports
    /// no purchase synced.
    func testUseWhoseAnswerCannotBeSavedReportsNoPurchaseSynced() async throws {
        let identity = MockIdentityService()
        identity.setDistinctId("customer-a")
        let store = WriteRefusingEvidenceStore(entries: [
            "transaction-1": evidence(
                transactionId: "transaction-1",
                distinctId: "customer-a",
                featureIds: ["credits"]
            ),
        ])
        let response = PurchaseBackedFeatureUseResponse(
            customerId: "customer-a",
            featureId: "credits",
            code: "entitled",
            allowed: true,
            unlimited: false,
            balance: 3,
            type: .creditSystem
        )
        let events = PurchaseBackedEventSink()
        let observer = makeObserver(
            api: PurchaseBackedUsageAPI(
                results: [.success(response)], onUse: { store.refusesWrites = true }
            ),
            features: PurchaseBackedFeatureRecorder(),
            identity: identity,
            store: store,
            eventSink: events
        )

        let used = try await observer.useFeatureWithPendingPurchase(
            distinctId: "customer-a",
            featureId: "credits",
            amount: 1,
            entityId: nil,
            metadata: nil
        )

        XCTAssertEqual(used?.success, true, "the server consumed the Feature")
        XCTAssertTrue(events.captureAttempts().isEmpty, "no purchase synced for an answer that was not saved")
        XCTAssertTrue(events.events().isEmpty)
    }

    /// A purchase-backed Feature command whose entry is admitted again while
    /// it is in flight (here StoreKit reports a refund) still returns the
    /// server's accepted result. Its answer is superseded, so it changes no
    /// Feature authority or cache and only asks for the profile again; the
    /// newer entry's own send waits on the outbox timer.
    func testAcceptedUseReturnsItsResultWhenTheEntryIsAdmittedAgainMidFlight() async throws {
        let identity = MockIdentityService()
        identity.setDistinctId("customer-a")
        let store = InMemoryTransactionEvidenceStore()
        XCTAssertTrue(store.save([
            "transaction-1": evidence(
                transactionId: "transaction-1",
                distinctId: "customer-a",
                featureIds: ["credits"]
            ),
        ]))
        let api = ControlledPurchaseBackedUsageAPI()
        let features = PurchaseBackedFeatureRecorder()
        let profileRequests = ProfileRequestRecorder()
        let observer = makeControlledObserver(
            api: api,
            features: features,
            identity: identity,
            store: store,
            refreshProfile: { profileRequests.record($0) }
        )
        addTeardownBlock { await observer.stopListening() }

        let use = Task {
            try await observer.useFeatureWithPendingPurchase(
                distinctId: "customer-a",
                featureId: "credits",
                amount: 1,
                entityId: nil,
                metadata: nil
            )
        }
        await api.waitUntilStarted()
        let refund = await observer.commit(.verified(
            VerifiedPurchaseEvidence(
                transactionJws: "revoked-transaction-1",
                transactionId: "transaction-1",
                originalTransactionId: "original-transaction-1",
                productId: "product-transaction-1",
                requester: .named("customer-a"),
                resolvesPendingPurchase: false,
                allowsDurableCheckoutAuthority: false,
                requiresAuthorityResolution: false,
                isRevoked: true
            ),
            source: .transactionStream
        ))
        _ = await refund.syncTask?.value
        await api.release()

        let used = try await use.value
        XCTAssertEqual(used?.success, true, "the server consumed the Feature; the caller gets its result")
        XCTAssertEqual(used?.amountUsed, 1)
        let published = await features.recordedUpdates().count
        XCTAssertEqual(published, 0, "a superseded answer publishes no balance")
        let invalidations = await features.invalidationCount()
        XCTAssertEqual(invalidations, 0, "and changes no Feature authority")
        XCTAssertEqual(profileRequests.requests, ["customer-a"], "it asks for the profile again")
        let entry = try XCTUnwrap(store.load().valueTreatingAbsentAsEmpty([:])?["transaction-1"])
        XCTAssertTrue(entry.isRevoked)
        XCTAssertTrue(entry.isUnsent, "the refund waits for its own send")
        XCTAssertEqual(entry.sendAttempts, 1, "the send the command held back counts a failed attempt")
        let scheduled = await observer.hasScheduledOutboxRetry
        XCTAssertTrue(scheduled)
    }

    /// A due outbox entry the timer's pass cannot send, because a
    /// purchase-backed Feature command holds the purchase, counts a failed
    /// attempt: its time moves on, and the timer waits for that time instead
    /// of firing again at once.
    func testDueEntryHeldByAFeatureCommandWaitsForItsNextTime() async throws {
        let identity = MockIdentityService()
        identity.setDistinctId("customer-a")
        let clock = MockDateProvider(initialDate: Date(timeIntervalSince1970: 100))
        let store = InMemoryTransactionEvidenceStore()
        XCTAssertTrue(store.save([
            "transaction-1": evidence(
                transactionId: "transaction-1",
                distinctId: "customer-a",
                featureIds: ["credits"],
                sendAttempts: 1,
                retryDueAt: clock.now().addingTimeInterval(-1)
            ),
        ]))
        let api = ControlledPurchaseBackedUsageAPI()
        let observer = TransactionObserver(
            api: api,
            features: PurchaseBackedFeatureRecorder(),
            identity: identity,
            settings: NuxieRuntimeSettings(
                configuration: NuxieConfiguration(apiKey: "purchase-use-test")
            ),
            eventSink: PurchaseBackedEventSink(),
            transactionServiceProvider: { fatalError("unused") },
            evidenceStore: store,
            purchaseStorageScope: scope,
            dateProvider: clock,
            activeStoreOriginalTransactionIDs: { [] }
        )
        addTeardownBlock { await observer.stopListening() }

        let use = Task {
            try await observer.useFeatureWithPendingPurchase(
                distinctId: "customer-a",
                featureId: "credits",
                amount: 1,
                entityId: nil,
                metadata: nil
            )
        }
        await api.waitUntilStarted()
        await observer.retryDueOutboxEntries()

        let held = try XCTUnwrap(store.load().valueTreatingAbsentAsEmpty([:])?["transaction-1"])
        XCTAssertEqual(held.sendAttempts, 2)
        XCTAssertEqual(held.retryDueAt, clock.now().addingTimeInterval(60))
        let dueAt = await observer.outboxRetryDueAt
        XCTAssertEqual(dueAt, clock.now().addingTimeInterval(60), "the timer waits for the entry's next time")
        let syncCount = await api.recordedSyncRequestCount()
        XCTAssertEqual(syncCount, 0)

        await api.release()
        _ = try await use.value
    }

    func testReceiptSyncWinningTheClaimFallsBackWithoutSubmittingEvidenceTwice() async throws {
        let identity = MockIdentityService()
        identity.setDistinctId("customer-a")
        let store = InMemoryTransactionEvidenceStore()
        XCTAssertTrue(store.save([
            "transaction-1": evidence(
                transactionId: "transaction-1",
                distinctId: "customer-a",
                featureIds: ["credits"]
            ),
        ]))
        let api = ControlledReceiptSyncAPI()
        let observer = makeReceiptRaceObserver(
            api: api,
            identity: identity,
            store: store
        )
        let sync = Task {
            await observer.syncTransaction(
                transactionJws: "signed-transaction-1",
                transactionId: "transaction-1",
                productId: "product-transaction-1",
                originalTransactionId: "original-transaction-1"
            )
        }
        await api.waitUntilSyncStarted()
        let use = Task {
            try await observer.useFeatureWithPendingPurchase(
                distinctId: "customer-a",
                featureId: "credits",
                amount: 1,
                entityId: nil,
                metadata: nil
            )
        }

        await api.releaseSync()

        let syncResult = await sync.value
        let useResult = try await use.value
        XCTAssertTrue(syncResult)
        XCTAssertNil(useResult)
        let usageCount = await api.recordedUsageRequestCount()
        XCTAssertEqual(usageCount, 0)
        XCTAssertNotNil(store.load().valueTreatingAbsentAsEmpty([:])!["transaction-1"]?.answeredAt)
    }

    func testIdentityChangeWhileAwaitingReceiptSyncCancelsOrdinaryFallback() async throws {
        let identity = MockIdentityService()
        identity.setDistinctId("customer-a")
        let store = InMemoryTransactionEvidenceStore()
        XCTAssertTrue(store.save([
            "transaction-1": evidence(
                transactionId: "transaction-1",
                distinctId: "customer-a",
                featureIds: ["credits"]
            ),
        ]))
        let api = ControlledReceiptSyncAPI()
        let observer = makeReceiptRaceObserver(
            api: api,
            identity: identity,
            store: store
        )
        let sync = Task {
            await observer.syncTransaction(
                transactionJws: "signed-transaction-1",
                transactionId: "transaction-1",
                productId: "product-transaction-1",
                originalTransactionId: "original-transaction-1"
            )
        }
        await api.waitUntilSyncStarted()
        // Suspend the fallback's first identity read so the use task is
        // provably past its entry guards before the identity changes;
        // otherwise a late-starting task observes the post-switch projection
        // state and returns nil without ever reaching the fence.
        identity.suspendNextDistinctIdRead()
        let use = Task {
            try await observer.useFeatureWithPendingPurchase(
                distinctId: "customer-a",
                featureId: "credits",
                amount: 1,
                entityId: nil,
                metadata: nil
            )
        }
        await identity.waitForSuspendedDistinctIdRead()
        identity.resumeSuspendedDistinctIdRead()

        identity.setDistinctId("customer-b")
        await api.releaseSync()

        let syncResult = await sync.value
        XCTAssertTrue(syncResult)
        do {
            _ = try await use.value
            XCTFail("Expected the old customer's fallback to be cancelled")
        } catch is CancellationError {}
        let usageCount = await api.recordedUsageRequestCount()
        XCTAssertEqual(usageCount, 0)
        XCTAssertNotNil(store.load().valueTreatingAbsentAsEmpty([:])!["transaction-1"]?.answeredAt)
    }

    func testOrdinaryReceiptSyncRejectsWrongCustomerResponse() async {
        await assertOrdinaryReceiptSyncRejects(
            responseCustomerId: "customer-b"
        )
    }

    func testOrdinaryReceiptSyncAcceptsMissingCustomerUntilBackendCanEchoDistinctId() async {
        await assertOrdinaryReceiptSyncAccepts(responseCustomerId: nil)
    }

    func testOrdinaryReceiptSyncAcceptsBackendInternalCustomerId() async {
        await assertOrdinaryReceiptSyncAccepts(
            responseCustomerId: "e138a88e-2f67-5cee-a545-5136084333c5"
        )
    }

    /// An outbox that cannot be read right now (its permissions deny
    /// reading, as data protection does before the first unlock) turns the
    /// outbox off for the session, and while it is off no purchase backs a
    /// Feature use: the use takes the ordinary Feature command.
    func testUnreadableEvidenceSendsTheUseThroughTheOrdinaryCommand() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pending-use-corruption-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let directory = scope.storageDirectory(customStoragePath: root)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let file = directory.appendingPathComponent("transaction-evidence.json")
        try Data("{}".utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: file.path
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer-a")
        let api = PurchaseBackedUsageAPI(results: [])
        let features = PurchaseBackedFeatureRecorder()
        let events = PurchaseBackedEventSink()
        let observer = TransactionObserver(
            api: api,
            features: features,
            identity: identity,
            settings: NuxieRuntimeSettings(
                configuration: NuxieConfiguration(apiKey: "purchase-use-test")
            ),
            eventSink: events,
            transactionServiceProvider: { fatalError("unused") },
            evidenceStore: TransactionEvidenceStore(
                customStoragePath: root,
                scope: scope
            ),
            purchaseStorageScope: scope,
            dateProvider: MockDateProvider(),
            activeStoreOriginalTransactionIDs: { [] }
        )

        let result = try await observer.useFeatureWithPendingPurchase(
            distinctId: "customer-a",
            featureId: "feature-1",
            amount: 1,
            entityId: nil,
            metadata: nil
        )
        XCTAssertNil(result, "the use takes the ordinary Feature command")
        let requests = await api.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    /// A purchase-backed use whose answer cannot be saved turns the outbox
    /// off. The use still returns the server's result, and the next use with
    /// the same arguments takes the ordinary Feature command: it is never a
    /// replay of the first that reports success without consuming a unit.
    func testUseWhoseAnswerCannotBeSavedSendsTheNextUseThroughTheOrdinaryCommand() async throws {
        let identity = MockIdentityService()
        identity.setDistinctId("customer-a")
        let store = WriteRefusingEvidenceStore(entries: [
            "transaction-1": evidence(
                transactionId: "transaction-1",
                distinctId: "customer-a",
                featureIds: ["credits"]
            ),
        ])
        let response = PurchaseBackedFeatureUseResponse(
            customerId: "customer-a",
            featureId: "credits",
            code: "entitled",
            allowed: true,
            unlimited: false,
            balance: 3,
            type: .creditSystem,
            idempotentReplay: false
        )
        var replay = response
        replay.idempotentReplay = true
        let api = PurchaseBackedUsageAPI(
            results: [.success(response), .success(replay)],
            onUse: { store.refusesWrites = true }
        )
        let observer = makeObserver(
            api: api,
            features: PurchaseBackedFeatureRecorder(),
            identity: identity,
            store: store
        )
        // The API makes the disk full after admission, before the answer.

        let first = try await observer.useFeatureWithPendingPurchase(
            distinctId: "customer-a",
            featureId: "credits",
            amount: 1,
            entityId: nil,
            metadata: nil
        )
        XCTAssertEqual(first?.success, true, "the server consumed the Feature")
        let second = try await observer.useFeatureWithPendingPurchase(
            distinctId: "customer-a",
            featureId: "credits",
            amount: 1,
            entityId: nil,
            metadata: nil
        )
        XCTAssertNil(second, "the next use takes the ordinary Feature command")
        let requests = await api.recordedRequests()
        XCTAssertEqual(requests.count, 1)
    }

    /// An outbox that cannot be read right now is off for the session: the
    /// receipt is still sent once, and its answer publishes no Features and
    /// reports nothing.
    func testOrdinaryReceiptSyncWithAnUnreadableOutboxIsSentOnceAndChangesNothingLocal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ordinary-sync-corruption-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let directory = scope.storageDirectory(customStoragePath: root)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let file = directory.appendingPathComponent("transaction-evidence.json")
        try Data("{}".utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: file.path
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer-a")
        let api = OrdinaryReceiptSyncAPI(responseCustomerId: "customer-a")
        let features = PurchaseBackedFeatureRecorder()
        let events = PurchaseBackedEventSink()
        let observer = TransactionObserver(
            api: api,
            features: features,
            identity: identity,
            settings: NuxieRuntimeSettings(
                configuration: NuxieConfiguration(apiKey: "purchase-use-test")
            ),
            eventSink: events,
            transactionServiceProvider: { fatalError("unused") },
            evidenceStore: TransactionEvidenceStore(
                customStoragePath: root,
                scope: scope
            ),
            purchaseStorageScope: scope,
            dateProvider: MockDateProvider(),
            activeStoreOriginalTransactionIDs: { [] }
        )

        let accepted = await observer.syncTransaction(
            transactionJws: "signed-transaction-1",
            transactionId: "transaction-1",
            productId: "product-transaction-1",
            originalTransactionId: "original-transaction-1"
        )

        XCTAssertTrue(accepted)
        XCTAssertEqual(api.recordedRequestCount(), 1)
        let purchaseUpdateCount = await features.recordedPurchaseUpdateCount()
        XCTAssertEqual(purchaseUpdateCount, 0)
        XCTAssertTrue(events.events().isEmpty)
    }

    private func assertOrdinaryReceiptSyncRejects(
        responseCustomerId: String?
    ) async {
        let identity = MockIdentityService()
        identity.setDistinctId("customer-a")
        let store = InMemoryTransactionEvidenceStore()
        XCTAssertTrue(store.save([
            "transaction-1": evidence(
                transactionId: "transaction-1",
                distinctId: "customer-a",
                featureIds: ["pro"]
            ),
        ]))
        let features = PurchaseBackedFeatureRecorder()
        let events = PurchaseBackedEventSink()
        let observer = TransactionObserver(
            api: OrdinaryReceiptSyncAPI(responseCustomerId: responseCustomerId),
            features: features,
            identity: identity,
            settings: NuxieRuntimeSettings(
                configuration: NuxieConfiguration(apiKey: "purchase-use-test")
            ),
            eventSink: events,
            transactionServiceProvider: { fatalError("unused") },
            evidenceStore: store,
            purchaseStorageScope: scope,
            dateProvider: MockDateProvider(
                initialDate: Date(timeIntervalSince1970: 100)
            ),
            activeStoreOriginalTransactionIDs: { [] }
        )

        let accepted = await observer.syncTransaction(
            transactionJws: "signed-transaction-1",
            transactionId: "transaction-1",
            productId: "product-transaction-1",
            originalTransactionId: "original-transaction-1"
        )

        XCTAssertFalse(accepted)
        let purchaseUpdateCount = await features.recordedPurchaseUpdateCount()
        XCTAssertEqual(purchaseUpdateCount, 0)
        XCTAssertTrue(events.events().isEmpty)
        XCTAssertEqual(
            store.load().valueTreatingAbsentAsEmpty([:])!["transaction-1"]?.transactionJws,
            "signed-transaction-1"
        )
        XCTAssertNil(store.load().valueTreatingAbsentAsEmpty([:])!["transaction-1"]?.answeredAt)
    }

    private func assertOrdinaryReceiptSyncAccepts(
        responseCustomerId: String?
    ) async {
        let identity = MockIdentityService()
        identity.setDistinctId("customer-a")
        let store = InMemoryTransactionEvidenceStore()
        XCTAssertTrue(store.save([
            "transaction-1": evidence(
                transactionId: "transaction-1",
                distinctId: "customer-a",
                featureIds: ["pro"]
            ),
        ]))
        let features = PurchaseBackedFeatureRecorder()
        let events = PurchaseBackedEventSink()
        let observer = TransactionObserver(
            api: OrdinaryReceiptSyncAPI(responseCustomerId: responseCustomerId),
            features: features,
            identity: identity,
            settings: NuxieRuntimeSettings(
                configuration: NuxieConfiguration(apiKey: "purchase-use-test")
            ),
            eventSink: events,
            transactionServiceProvider: { fatalError("unused") },
            evidenceStore: store,
            purchaseStorageScope: scope,
            dateProvider: MockDateProvider(
                initialDate: Date(timeIntervalSince1970: 100)
            ),
            activeStoreOriginalTransactionIDs: { [] }
        )

        let accepted = await observer.syncTransaction(
            transactionJws: "signed-transaction-1",
            transactionId: "transaction-1",
            productId: "product-transaction-1",
            originalTransactionId: "original-transaction-1"
        )

        XCTAssertTrue(accepted)
        let purchaseUpdateCount = await features.recordedPurchaseUpdateCount()
        XCTAssertEqual(purchaseUpdateCount, 1)
        XCTAssertEqual(events.events().count, 1)
        XCTAssertNotNil(store.load().valueTreatingAbsentAsEmpty([:])!["transaction-1"]?.answeredAt)
    }

    func testShutdownDrainsAcceptedUseBeforeClosingTheEvidenceStoreLifecycle() async throws {
        let identity = MockIdentityService()
        identity.setDistinctId("customer-a")
        let store = InMemoryTransactionEvidenceStore()
        XCTAssertTrue(store.save([
            "transaction-1": evidence(
                transactionId: "transaction-1",
                distinctId: "customer-a",
                featureIds: ["credits"]
            ),
        ]))
        let api = ControlledPurchaseBackedUsageAPI()
        let events = PurchaseBackedEventSink()
        let observer = makeControlledObserver(
            api: api,
            features: PurchaseBackedFeatureRecorder(),
            identity: identity,
            store: store,
            eventSink: events
        )
        let use = Task {
            try await observer.useFeatureWithPendingPurchase(
                distinctId: "customer-a",
                featureId: "credits",
                amount: 1,
                entityId: nil,
                metadata: nil
            )
        }
        await api.waitUntilStarted()
        let stoppedEarly = expectation(description: "observer did not stop early")
        stoppedEarly.isInverted = true
        let stopped = expectation(description: "observer stopped after request drained")
        Task {
            await observer.stopListening()
            stoppedEarly.fulfill()
            stopped.fulfill()
        }

        await fulfillment(of: [stoppedEarly], timeout: 0.05)
        await api.release()
        await fulfillment(of: [stopped], timeout: 1)

        do {
            _ = try await use.value
            XCTFail("Expected teardown to cancel the stale lifecycle result")
        } catch is CancellationError {}
        XCTAssertNotNil(store.load().valueTreatingAbsentAsEmpty([:])!["transaction-1"]?.answeredAt)
        XCTAssertEqual(events.captureAttempts().count, 1)
        XCTAssertEqual(events.events().count, 1)
    }

    func testIdentityChangeAfterServerAcceptanceDoesNotMutateTheNewCustomer() async throws {
        let identity = MockIdentityService()
        identity.setDistinctId("customer-a")
        let store = InMemoryTransactionEvidenceStore()
        XCTAssertTrue(store.save([
            "transaction-1": evidence(
                transactionId: "transaction-1",
                distinctId: "customer-a",
                featureIds: ["credits"]
            ),
        ]))
        let api = ControlledPurchaseBackedUsageAPI()
        let features = PurchaseBackedFeatureRecorder()
        let events = PurchaseBackedEventSink()
        let observer = makeControlledObserver(
            api: api,
            features: features,
            identity: identity,
            store: store,
            eventSink: events
        )
        let use = Task {
            try await observer.useFeatureWithPendingPurchase(
                distinctId: "customer-a",
                featureId: "credits",
                amount: 1,
                entityId: nil,
                metadata: nil
            )
        }
        await api.waitUntilStarted()

        identity.setDistinctId("customer-b")
        await api.release()

        do {
            _ = try await use.value
            XCTFail("Expected the stale customer request to be cancelled")
        } catch is CancellationError {}
        XCTAssertNotNil(store.load().valueTreatingAbsentAsEmpty([:])!["transaction-1"]?.answeredAt)
        let updateCount = await features.recordedUpdates().count
        XCTAssertEqual(updateCount, 0)
        let captures = events.captureAttempts()
        XCTAssertEqual(captures.count, 1)
        XCTAssertEqual(captures[0].distinctId, "customer-a")
        XCTAssertEqual(events.events().count, 1)
    }

    func testAcceptedUsePreservesPendingFinishAndCommercialCompletionContext() async throws {
        let identity = MockIdentityService()
        identity.setDistinctId("customer-a")
        let store = InMemoryTransactionEvidenceStore()
        let retained = evidence(
            transactionId: "transaction-1",
            distinctId: "customer-a",
            featureIds: ["credits"],
            finishRequired: true,
            commercialContext: commercialContext()
        )
        XCTAssertTrue(store.save(["transaction-1": retained]))
        let response = PurchaseBackedFeatureUseResponse(
            customerId: "customer-a",
            featureId: "credits",
            code: "feature_found",
            allowed: true,
            unlimited: false,
            balance: 3,
            type: .creditSystem
        )
        let observer = makeObserver(
            api: PurchaseBackedUsageAPI(results: [.success(response)]),
            features: PurchaseBackedFeatureRecorder(),
            identity: identity,
            store: store
        )

        _ = try await observer.useFeatureWithPendingPurchase(
            distinctId: "customer-a",
            featureId: "credits",
            amount: 1,
            entityId: nil,
            metadata: nil
        )

        let evidence = try XCTUnwrap(store.load().valueTreatingAbsentAsEmpty([:])!["transaction-1"])
        XCTAssertEqual(evidence.transactionJws, "")
        XCTAssertNotNil(evidence.answeredAt)
        XCTAssertTrue(evidence.finishRequired)
        XCTAssertEqual(evidence.commercialContext, commercialContext())
        XCTAssertNil(evidence.completionDeliveredAt)
    }

    private func evidence(
        transactionId: String,
        distinctId: String,
        featureIds: [String],
        finishRequired: Bool = false,
        commercialContext: PurchaseCommercialContext? = nil,
        isRevoked: Bool = false,
        transactionJws: String? = nil,
        answeredAt: Date? = nil,
        scope: PurchaseStorageScope? = nil,
        sendAttempts: Int = 0,
        retryDueAt: Date? = nil,
        customerKind: PurchaseCustomerKind = .identified
    ) -> StoredTransactionEvidence {
        let scope = scope ?? self.scope
        return StoredTransactionEvidence(
            scope: scope,
            transactionJws: transactionJws ?? "signed-\(transactionId)",
            transactionId: transactionId,
            originalTransactionId: "original-\(transactionId)",
            productId: "product-\(transactionId)",
            distinctId: distinctId,
            recordedAt: Date(timeIntervalSince1970: 50),
            productFeatureIds: featureIds,
            isRevoked: isRevoked,
            finishRequired: finishRequired,
            commercialContext: commercialContext,
            answeredAt: answeredAt,
            // The customer's own checkout: its account token names them.
            appAccountToken: scope.appAccountToken(distinctId: distinctId),
            reason: .purchase,
            customerKind: customerKind,
            sendAttempts: sendAttempts,
            retryDueAt: retryDueAt
        )
    }

    private func commercialContext() -> PurchaseCommercialContext {
        PurchaseCommercialContext(
            release: AuthenticatedJourneyReleaseID(
                identity: JourneyReleaseIdentity(
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
            storeProductId: "product-transaction-1"
        )
    }

    private func makeObserver(
        api: PurchaseBackedUsageAPI,
        features: PurchaseBackedFeatureRecorder,
        identity: MockIdentityService,
        store: any TransactionEvidenceStoreProtocol,
        observerScope: PurchaseStorageScope? = nil,
        configuration: NuxieConfiguration? = nil,
        eventSink: SystemEventSink = PurchaseBackedEventSink()
    ) -> TransactionObserver {
        let settings = NuxieRuntimeSettings(
            configuration: configuration
                ?? NuxieConfiguration(apiKey: "purchase-use-test")
        )
        return TransactionObserver(
            api: api,
            features: features,
            identity: identity,
            settings: settings,
            eventSink: eventSink,
            transactionServiceProvider: { fatalError("unused") },
            evidenceStore: store,
            purchaseStorageScope: observerScope ?? scope,
            dateProvider: MockDateProvider(
                initialDate: Date(timeIntervalSince1970: 100)
            ),
            activeStoreOriginalTransactionIDs: { [] }
        )
    }

    private func makeControlledObserver(
        api: ControlledPurchaseBackedUsageAPI,
        features: PurchaseBackedFeatureRecorder,
        identity: MockIdentityService,
        store: InMemoryTransactionEvidenceStore,
        eventSink: SystemEventSink = PurchaseBackedEventSink(),
        refreshProfile: @escaping @Sendable (String) async -> Void = { _ in }
    ) -> TransactionObserver {
        let settings = NuxieRuntimeSettings(
            configuration: NuxieConfiguration(apiKey: "purchase-use-test")
        )
        return TransactionObserver(
            api: api,
            features: features,
            identity: identity,
            settings: settings,
            eventSink: eventSink,
            transactionServiceProvider: { fatalError("unused") },
            evidenceStore: store,
            purchaseStorageScope: scope,
            dateProvider: MockDateProvider(
                initialDate: Date(timeIntervalSince1970: 100)
            ),
            activeStoreOriginalTransactionIDs: { [] },
            refreshProfile: refreshProfile
        )
    }

    private func makeReceiptRaceObserver(
        api: ControlledReceiptSyncAPI,
        identity: MockIdentityService,
        store: InMemoryTransactionEvidenceStore
    ) -> TransactionObserver {
        TransactionObserver(
            api: api,
            features: PurchaseBackedFeatureRecorder(),
            identity: identity,
            settings: NuxieRuntimeSettings(
                configuration: NuxieConfiguration(apiKey: "purchase-use-test")
            ),
            eventSink: DiscardingSystemEventSink(),
            transactionServiceProvider: { fatalError("unused") },
            evidenceStore: store,
            purchaseStorageScope: scope,
            dateProvider: MockDateProvider(
                initialDate: Date(timeIntervalSince1970: 100)
            ),
            activeStoreOriginalTransactionIDs: { [] }
        )
    }
}
