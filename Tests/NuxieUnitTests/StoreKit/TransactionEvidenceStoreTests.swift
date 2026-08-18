import Foundation
import Quick
import Nimble
@testable import Nuxie

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
