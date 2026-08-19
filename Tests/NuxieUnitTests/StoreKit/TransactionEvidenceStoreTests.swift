import Foundation
import Quick
import Nimble
import XCTest
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

private final class TransactionEvidenceEventSink: SystemEventSink, @unchecked Sendable {
    func emit(_: String, properties _: [String: Any]?) {}
}

final class TransactionEvidenceStoreTests: QuickSpec {
    override class func spec() {
        describe("TransactionEvidenceStore") {
            it("round trips minimum evidence and removes it when drained") {
                let root = FileManager.default.temporaryDirectory
                    .appendingPathComponent("evidence-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: root) }
                let store = TransactionEvidenceStore(customStoragePath: root)
                let evidence = StoredTransactionEvidence(
                    transactionJws: "signed-jws",
                    transactionId: "transaction-1",
                    originalTransactionId: "original-1",
                    productId: "product-1",
                    distinctId: "customer-1",
                    recordedAt: Date(timeIntervalSince1970: 10),
                    localEntitlementGrants: [
                        StoredLocalEntitlementGrant(
                            featureId: "feature-1",
                            featureExternalId: "feature",
                            allowanceType: "boolean",
                            allowance: nil
                        ),
                    ]
                )

                store.save([evidence.transactionId: evidence])
                expect(store.load()[evidence.transactionId]) == evidence
                store.save([:])
                expect(store.load()).to(beEmpty())
            }
        }
    }
}

final class TransactionObserverEvidenceRaceTests: XCTestCase {
    func testDeduplicatedSyncDrainsEvidencePersistedAfterObserverWonRace() async {
        let mocks = MockFactory.shared
        let configuration = NuxieConfiguration(apiKey: "isolated")
        let settings = NuxieRuntimeSettings(configuration: configuration)
        let evidenceStore = InMemoryTransactionEvidenceStore()
        let features = FeatureService(
            api: mocks.nuxieApi,
            identity: mocks.identityService,
            profile: mocks.profileService,
            dateProvider: mocks.dateProvider,
            featureInfo: FeatureInfo(),
            cacheTTL: configuration.featureCacheTTL
        )
        let observer = TransactionObserver(
            api: mocks.nuxieApi,
            features: features,
            identity: mocks.identityService,
            settings: settings,
            eventSink: TransactionEvidenceEventSink(),
            transactionServiceProvider: { fatalError("unused in this test") },
            evidenceStore: evidenceStore
        )
        let evidence = StoreTransactionEvidence(
            transactionJws: "signed-jws",
            transactionId: "transaction-race",
            originalTransactionId: "original-race",
            productId: "product-race",
            finish: {}
        )
        let product = StoreProduct(
            productId: "product-race",
            placementId: "placement-race",
            name: "Product",
            price: "$1.00",
            period: nil
        )

        let firstRecord = await observer.recordVerifiedPurchase(
            evidence: evidence,
            product: product
        )
        XCTAssertTrue(firstRecord)
        let firstSync = await observer.syncTransaction(
            transactionJws: evidence.transactionJws,
            transactionId: evidence.transactionId,
            productId: evidence.productId,
            originalTransactionId: evidence.originalTransactionId
        )
        XCTAssertTrue(firstSync)
        XCTAssertNil(evidenceStore.load()[evidence.transactionId])

        // Model the direct purchase callback persisting after the observer has
        // already completed the same transaction from Transaction.updates.
        let lateRecord = await observer.recordVerifiedPurchase(
            evidence: evidence,
            product: product
        )
        XCTAssertTrue(lateRecord)
        XCTAssertNotNil(evidenceStore.load()[evidence.transactionId])
        let deduplicatedSync = await observer.syncTransaction(
            transactionJws: evidence.transactionJws,
            transactionId: evidence.transactionId,
            productId: evidence.productId,
            originalTransactionId: evidence.originalTransactionId
        )
        XCTAssertTrue(deduplicatedSync)
        XCTAssertNil(evidenceStore.load()[evidence.transactionId])
    }
}
