import Foundation
import XCTest
@testable import Nuxie

/// Records Test Store grants, answering each in turn; the last answer repeats.
actor RecordingTestStoreGrants: TestStoreGranting {
    struct Grant: Equatable {
        let productId: String
        let transactionId: String
        let distinctId: String
    }

    private(set) var grants: [Grant] = []
    private var answers: [Result<PurchaseResponse, Error>]

    init(answer: Result<PurchaseResponse, Error>) {
        self.answers = [answer]
    }

    init(answers: [Result<PurchaseResponse, Error>]) {
        self.answers = answers
    }

    func grantTestStorePurchase(
        productId: String,
        transactionId: String,
        distinctId: String
    ) async throws -> PurchaseResponse {
        grants.append(Grant(productId: productId, transactionId: transactionId, distinctId: distinctId))
        return try (answers.count > 1 ? answers.removeFirst() : answers[0]).get()
    }
}

/// Holds the first grant open until released; every grant succeeds.
actor HeldTestStoreGrants: TestStoreGranting {
    private(set) var transactionIds: [String] = []
    private var release: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func grantTestStorePurchase(
        productId: String,
        transactionId: String,
        distinctId: String
    ) async throws -> PurchaseResponse {
        transactionIds.append(transactionId)
        if transactionIds.count == 1 {
            startWaiters.forEach { $0.resume() }
            startWaiters = []
            await withCheckedContinuation { release = $0 }
        }
        return PurchaseResponse(success: true, customerId: "customer-1", features: [], error: nil)
    }

    func firstGrantStarted() async {
        guard transactionIds.isEmpty else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseFirst() {
        release?.resume()
        release = nil
    }
}

final class TestStoreGrantTests: XCTestCase {
    private let pro = PurchaseFeature(
        id: "feature_pro", extId: "pro-training", type: .boolean,
        allowed: true, balance: nil, unlimited: false
    )

    private func annual(published: Bool = true) -> StoreProduct {
        var product = StoreProduct(
            productId: "annual", storeProductId: "cadence_pro:annual",
            placementId: "paywall", name: "Annual", price: "$59.99", period: nil
        )
        guard published else { return product }
        product.purchaseContext = PurchaseCommercialContext(
            release: AuthenticatedJourneyReleaseID(
                identity: JourneyReleaseIdentity(
                    appId: "app-1", environment: "test", experienceId: "experience-1",
                    experienceVersionId: "version-1", buildId: "build-1", versionNumber: 1,
                    publishedAt: "2026-10-20T00:00:00Z", publishedAtSeq: 1
                ),
                descriptorSHA256: String(repeating: "a", count: 64)
            ),
            placementId: "paywall",
            productId: "prd_annual",
            storeProductId: "cadence_pro:annual",
            displayPrice: "$59.99",
            price: 59.99
        )
        return product
    }

    private func success(_ features: [PurchaseFeature]) -> PurchaseResponse {
        PurchaseResponse(success: true, customerId: "customer-1", features: features, error: nil)
    }

    func testAPurchaseIsGrantedByTheServerAndCarriesTheGrantedAccess() async {
        let grants = RecordingTestStoreGrants(answer: .success(success([pro])))
        let store = NuxieTestStore(granting: grants)

        let response = await store.complete(.purchased, product: annual(), distinctId: "rider-1")

        guard case .purchased(let evidence) = response.result else {
            return XCTFail("Expected a purchase, got \(response.result)")
        }
        XCTAssertNil(evidence)
        let recorded = await grants.grants
        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(recorded.first?.productId, "prd_annual")
        XCTAssertEqual(recorded.first?.distinctId, "rider-1")
        XCTAssertEqual(recorded.first?.transactionId, response.transactionId)
        XCTAssertTrue(response.transactionId?.hasPrefix("nuxie-test-") == true)
        XCTAssertEqual(response.features?.map(\.id), ["feature_pro"])
        let restored = await store.restoreResponse(for: .restored, distinctId: "rider-1")
        XCTAssertEqual(restored.products.map(\.storeProductId), ["cadence_pro:annual"])
    }

    func testAPurchaseTheServerDoesNotGrantFailsAndLeavesNothingToRestore() async {
        let answers: [Result<PurchaseResponse, Error>] = [
            .failure(NuxieNetworkError.invalidResponse),
            .success(PurchaseResponse(success: false, customerId: nil, features: nil, error: "refused")),
        ]
        for answer in answers {
            let store = NuxieTestStore(granting: RecordingTestStoreGrants(answer: answer))

            let response = await store.complete(.purchased, product: annual(), distinctId: "rider-1")

            guard case .failed = response.result else {
                return XCTFail("Expected a failed purchase, got \(response.result)")
            }
            XCTAssertNil(response.transactionId)
            XCTAssertNil(response.features)
            let restored = await store.restoreResponse(for: .restored, distinctId: "rider-1")
            XCTAssertTrue(restored.products.isEmpty)
        }
    }

    func testAnUnansweredGrantIsReplayedByTheNextPurchaseOfTheSameProduct() async {
        let grants = RecordingTestStoreGrants(answers: [
            .failure(NuxieNetworkError.timeout),
            .failure(NuxieNetworkError.httpError(statusCode: 503, message: "unavailable")),
            .success(success([pro])),
        ])
        let store = NuxieTestStore(granting: grants)

        let unanswered = await store.complete(.purchased, product: annual(), distinctId: "rider-1")
        let unavailable = await store.complete(.purchased, product: annual(), distinctId: "rider-1")
        let granted = await store.complete(.purchased, product: annual(), distinctId: "rider-1")

        guard case .failed = unanswered.result, case .failed = unavailable.result,
              case .purchased = granted.result else {
            return XCTFail("Expected two failures, then a purchase")
        }
        let ids = await grants.grants.map(\.transactionId)
        XCTAssertEqual(ids.count, 3)
        XCTAssertEqual(Set(ids).count, 1, "Every attempt must replay the first transaction")
        XCTAssertEqual(granted.transactionId, ids.first)
    }

    func testARefusedOrSettledGrantStartsANewTransactionNextTime() async {
        let grants = RecordingTestStoreGrants(answers: [
            .failure(NuxieNetworkError.httpError(statusCode: 403, message: "live key")),
            .success(success([pro])),
            .success(success([pro])),
        ])
        let store = NuxieTestStore(granting: grants)

        _ = await store.complete(.purchased, product: annual(), distinctId: "rider-1")
        _ = await store.complete(.purchased, product: annual(), distinctId: "rider-1")
        _ = await store.complete(.purchased, product: annual(), distinctId: "rider-1")

        let ids = await grants.grants.map(\.transactionId)
        XCTAssertEqual(Set(ids).count, 3)
    }

    func testAPurchaseThatOverlapsOneInFlightIsAPurchaseOfItsOwn() async {
        let grants = HeldTestStoreGrants()
        let store = NuxieTestStore(granting: grants)
        let product = annual()

        let first = Task { await store.complete(.purchased, product: product, distinctId: "rider-1") }
        await grants.firstGrantStarted()
        let second = await store.complete(.purchased, product: product, distinctId: "rider-1")
        await grants.releaseFirst()
        let firstResponse = await first.value

        guard case .purchased = firstResponse.result, case .purchased = second.result else {
            return XCTFail("Expected both purchases to succeed")
        }
        let ids = await grants.transactionIds
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(Set(ids).count, 2, "An overlapping purchase must not share the transaction in flight")
    }

    func testAnUnansweredGrantIsKeptForItsOwnCustomerAndProduct() async {
        let grants = RecordingTestStoreGrants(answers: [
            .failure(NuxieNetworkError.timeout),
            .success(success([pro])),
        ])
        let store = NuxieTestStore(granting: grants)

        _ = await store.complete(.purchased, product: annual(), distinctId: "rider-1")
        _ = await store.complete(.purchased, product: annual(), distinctId: "rider-2")

        let ids = await grants.grants.map(\.transactionId)
        XCTAssertEqual(Set(ids).count, 2)
    }

    func testTheGrantRequestNamesTheCatalogProductTransactionAndCustomer() throws {
        let body = try JSONEncoder().encode(TestStorePurchaseRequest(
            productId: "prd_annual", transactionId: "nuxie-test-1", distinctId: "rider-1"
        ))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json, [
            "type": "test_store",
            "catalog_product_id": "prd_annual",
            "transaction_id": "nuxie-test-1",
            "distinct_id": "rider-1",
        ])
    }

    func testOnlyAPublishedProductPurchaseReachesTheServer() async {
        let grants = RecordingTestStoreGrants(answer: .success(success([pro])))
        let store = NuxieTestStore(granting: grants)

        let unpublished = await store.complete(.purchased, product: annual(published: false), distinctId: "rider-1")
        let cancelled = await store.complete(.cancelled, product: annual(), distinctId: "rider-1")

        guard case .failed = unpublished.result else {
            return XCTFail("Expected a failed purchase, got \(unpublished.result)")
        }
        guard case .cancelled = cancelled.result else {
            return XCTFail("Expected a cancelled purchase, got \(cancelled.result)")
        }
        let recorded = await grants.grants
        XCTAssertTrue(recorded.isEmpty)
    }
}
