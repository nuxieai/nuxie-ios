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

    init(results: [Result<PurchaseBackedFeatureUseResponse, Error>]) {
        self.results = results
    }

    func syncTransaction(
        transactionJwt _: String,
        distinctId: String
    ) async throws -> PurchaseResponse {
        PurchaseResponse(
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
        guard !results.isEmpty else { throw NuxieNetworkError.invalidResponse }
        return try results.removeFirst().get()
    }

    func recordedRequests() -> [PurchaseBackedFeatureUseRequest] { requests }
}

private final class OrdinaryReceiptSyncAPI {
    private let responseCustomerId: String?
    private let lock = NSLock()
    private var requestCount = 0

    init(responseCustomerId: String?) {
        self.responseCustomerId = responseCustomerId
    }

    func syncTransaction(
        transactionJwt _: String,
        distinctId _: String
    ) async throws -> PurchaseResponse {
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
        _ name: String,
        properties: [String: Any]?,
        eventId: String,
        distinctId: String
    ) async -> Bool {
        lock.withLock {
            let result = captureResults.isEmpty ? true : captureResults.removeFirst()
            captures.append(Capture(
                name: name,
                properties: properties,
                eventId: eventId,
                distinctId: distinctId
            ))
            if result { capturedEvents.append((name, properties)) }
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

    func syncTransaction(
        transactionJwt _: String,
        distinctId: String
    ) async throws -> PurchaseResponse {
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

private actor ControlledReceiptSyncAPI:
    PurchaseSynchronizing,
    PurchaseBackedFeatureUsing
{
    private var syncStarted = false
    private var syncStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var syncResponseWaiters: [CheckedContinuation<Void, Never>] = []
    private var syncReleased = false
    private var usageRequestCount = 0

    func syncTransaction(
        transactionJwt _: String,
        distinctId: String
    ) async throws -> PurchaseResponse {
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
        let updateCount = await features.recordedUpdates().count
        XCTAssertEqual(updateCount, 1)
        XCTAssertNil(store.load().valueTreatingAbsentAsEmpty([:])!["transaction-1"])
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
        XCTAssertNil(store.load().valueTreatingAbsentAsEmpty([:])!["transaction-1"])
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

    func testAcceptedUseRetainsEvidenceUntilStablePurchaseEventCaptureSucceeds() async throws {
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
        let api = PurchaseBackedUsageAPI(results: [
            .success(response),
            .success(response),
        ])
        let events = PurchaseBackedEventSink(captureResults: [false, true])
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
            XCTFail("Expected failed durable capture to fail the local command")
        } catch NuxieNetworkError.invalidResponse {}
        XCTAssertEqual(
            store.load().valueTreatingAbsentAsEmpty([:])!["transaction-1"]?.transactionJws,
            "signed-transaction-1"
        )
        XCTAssertNil(store.load().valueTreatingAbsentAsEmpty([:])!["transaction-1"]?.backendSyncedAt)
        XCTAssertTrue(events.events().isEmpty)

        _ = try await observer.useFeatureWithPendingPurchase(
            distinctId: "customer-a",
            featureId: "credits",
            amount: 1,
            entityId: nil,
            metadata: nil
        )

        XCTAssertNil(store.load().valueTreatingAbsentAsEmpty([:])!["transaction-1"])
        let captures = events.captureAttempts()
        XCTAssertEqual(captures.count, 2)
        XCTAssertEqual(captures[0].eventId, captures[1].eventId)
        XCTAssertEqual(captures[0].distinctId, "customer-a")
        XCTAssertEqual(events.events().count, 1)
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
        } catch NuxieNetworkError.httpError(let statusCode, _, _) {
            XCTAssertEqual(statusCode, 402)
        }

        XCTAssertEqual(store.load().valueTreatingAbsentAsEmpty([:])!["transaction-1"]?.transactionJws, "signed-transaction-1")
        XCTAssertNil(store.load().valueTreatingAbsentAsEmpty([:])!["transaction-1"]?.backendSyncedAt)
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
                backendSyncedAt: Date(timeIntervalSince1970: 75)
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

    func testDelegateTransferredStoreKitEvidenceRemainsEligibleWhileTestStoreDoesNot() async throws {
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
        XCTAssertNil(providerStore.load().valueTreatingAbsentAsEmpty([:])!["provider"])
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
        XCTAssertNil(store.load().valueTreatingAbsentAsEmpty([:])!["transaction-1"])
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
        XCTAssertNil(store.load().valueTreatingAbsentAsEmpty([:])!["transaction-1"])
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

    func testUnreadableEvidenceThrowsFromPendingPurchaseUseInsteadOfFallingThrough() async throws {
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
        try Data("{ unreadable".utf8).write(
            to: directory.appendingPathComponent("transaction-evidence.json")
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

        do {
            _ = try await observer.useFeatureWithPendingPurchase(
                distinctId: "customer-a",
                featureId: "feature-1",
                amount: 1,
                entityId: nil,
                metadata: nil
            )
            XCTFail("Expected CommerceStoreError.evidenceUnreadable")
        } catch let error as CommerceStoreError {
            XCTAssertEqual(error, .evidenceUnreadable)
        }
    }

    func testOrdinaryReceiptSyncDoesNotConsumeUnreadableEvidenceAsAbsent() async throws {
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
        try Data("{ unreadable".utf8).write(
            to: directory.appendingPathComponent("transaction-evidence.json")
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

        XCTAssertFalse(accepted)
        XCTAssertEqual(api.recordedRequestCount(), 0)
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
        XCTAssertNil(store.load().valueTreatingAbsentAsEmpty([:])!["transaction-1"]?.backendSyncedAt)
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
        XCTAssertNil(store.load().valueTreatingAbsentAsEmpty([:])!["transaction-1"])
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
        XCTAssertNil(store.load().valueTreatingAbsentAsEmpty([:])!["transaction-1"])
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
        XCTAssertNil(store.load().valueTreatingAbsentAsEmpty([:])!["transaction-1"])
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
        XCTAssertNotNil(evidence.backendSyncedAt)
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
        backendSyncedAt: Date? = nil,
        scope: PurchaseStorageScope? = nil
    ) -> StoredTransactionEvidence {
        StoredTransactionEvidence(
            scope: scope ?? self.scope,
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
            backendSyncedAt: backendSyncedAt
        )
    }

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
            storeProductId: "product-transaction-1"
        )
    }

    private func makeObserver(
        api: PurchaseBackedUsageAPI,
        features: PurchaseBackedFeatureRecorder,
        identity: MockIdentityService,
        store: InMemoryTransactionEvidenceStore,
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
        eventSink: SystemEventSink = PurchaseBackedEventSink()
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
            activeStoreOriginalTransactionIDs: { [] }
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
