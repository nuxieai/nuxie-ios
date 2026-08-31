import Combine
import Foundation
import XCTest
@testable import Nuxie

final class IdentityPublicationTests: XCTestCase {
    func testReentrantIdentityMutationAbandonsStaleOuterContinuation() async {
        let storage = FileManager.default.temporaryDirectory
            .appendingPathComponent("identity-publication-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: storage) }

        let identity = IdentityService(customStoragePath: storage)
        let committedOuterTransition = await MainActor.run {
            let info = FeatureInfo()
            identity.setDistinctId("customer-a")
            info.beginOptimisticProjectionPublication(
                epoch: UUID(),
                distinctId: "customer-a"
            )
            info.admitProfileSnapshot([:], admittedAt: Date())
            info.replaceOptimisticProjection(
                evidence: [
                    OptimisticPurchaseEvidence(
                        transactionId: "transaction-b",
                        distinctId: "customer-b",
                        backendSynced: false,
                        revoked: false
                    ),
                    OptimisticPurchaseEvidence(
                        transactionId: "transaction-c",
                        distinctId: "customer-c",
                        backendSynced: false,
                        revoked: false
                    ),
                ],
                descriptorAllowances: [
                    "transaction-b": [OptimisticEntitlementAllowance(
                        featureId: "customer-b-feature",
                        kind: .boolean,
                        unlimited: false,
                        allowance: nil
                    )],
                    "transaction-c": [OptimisticEntitlementAllowance(
                        featureId: "customer-c-feature",
                        kind: .boolean,
                        unlimited: false,
                        allowance: nil
                    )],
                ],
                distinctId: "customer-a"
            )

            var shouldReenter = true
            let cancellable = info.$all.dropFirst().sink { features in
                guard shouldReenter,
                      features["customer-b-feature"]?.allowed == true else {
                    return
                }
                shouldReenter = false
                let inner = identity.mutateIdentity(
                    .identify("customer-c"),
                    publishing: { transition in
                        info.setProjectionDistinctId(transition.current.distinctId)
                    }
                )
                XCTAssertEqual(inner?.current.distinctId, "customer-c")
            }

            let outer = identity.mutateIdentity(
                .identify("customer-b"),
                publishing: { transition in
                    info.setProjectionDistinctId(transition.current.distinctId)
                }
            )

            withExtendedLifetime(cancellable) {
                XCTAssertEqual(identity.getDistinctId(), "customer-c")
                XCTAssertFalse(info.isAllowed("customer-b-feature"))
                XCTAssertTrue(info.isAllowed("customer-c-feature"))
                XCTAssertEqual(info.state, .unknown)
            }
            return outer != nil
        }

        XCTAssertFalse(
            committedOuterTransition,
            "the outer continuation must be abandoned after reentrant identity publication"
        )
    }
}
