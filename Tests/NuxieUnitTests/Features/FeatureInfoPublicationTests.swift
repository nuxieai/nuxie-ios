import Combine
import Foundation
import XCTest
@testable import Nuxie

final class FeatureInfoPublicationTests: XCTestCase {
    @MainActor
    func testReentrantIdentityChangeWinsProvisionalBalancePublication() {
        let info = FeatureInfo()
        info.beginOptimisticProjectionPublication(
            epoch: UUID(),
            distinctId: "customer-a"
        )
        info.admitProfileSnapshot([
            "credits": .withBalance(
                10,
                unlimited: false,
                type: .metered
            ),
        ], admittedAt: Date())

        var shouldSwitchIdentity = true
        let cancellable = info.$all.dropFirst().sink { features in
            guard shouldSwitchIdentity,
                  features["credits"]?.balance == 9 else { return }
            shouldSwitchIdentity = false
            info.setProjectionDistinctId("customer-b")
        }

        info.decrementBalance("credits", amount: 1)

        withExtendedLifetime(cancellable) {
            XCTAssertTrue(info.all.isEmpty)
            XCTAssertEqual(info.state, .unknown)
        }
    }

    @MainActor
    func testCompleteSnapshotFencesAnOmittedOverlayFeature() throws {
        let info = FeatureInfo()
        info.beginOptimisticProjectionPublication(
            epoch: UUID(),
            distinctId: "customer-a"
        )
        info.admitProfileSnapshot([
            "credits": .withBalance(
                5,
                unlimited: false,
                type: .metered
            ),
        ], admittedAt: Date())
        let evidence = [OptimisticPurchaseEvidence(
            transactionId: "transaction-1",
            distinctId: "customer-a",
            backendSynced: false,
            revoked: false
        )]
        let allowances = [
            "transaction-1": [OptimisticEntitlementAllowance(
                featureId: "credits",
                kind: .metered,
                unlimited: false,
                allowance: 10
            )],
        ]
        info.replaceOptimisticProjection(
            evidence: evidence,
            descriptorAllowances: allowances,
            distinctId: "customer-a"
        )
        let authorityBeforeSnapshot = info.balanceAuthority(for: "credits")

        info.admitProfileSnapshot([:], admittedAt: Date())
        XCTAssertEqual(info.balance("credits"), 10)

        let staleResponse = info.commitCommandBalanceIfFresh(
            "credits",
            balance: 1,
            responseAuthority: authorityBeforeSnapshot
        )
        XCTAssertNil(staleResponse)

        info.replaceOptimisticProjection(
            evidence: [OptimisticPurchaseEvidence(
                transactionId: "transaction-1",
                distinctId: "customer-a",
                backendSynced: true,
                revoked: false
            )],
            descriptorAllowances: allowances,
            distinctId: "customer-a"
        )

        XCTAssertNil(info.feature("credits"))
        XCTAssertEqual(info.state, .ready)
    }
}
