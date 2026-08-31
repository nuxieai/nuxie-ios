import Combine
import Foundation
import XCTest
@testable import Nuxie

final class FeatureInfoPublicationTests: XCTestCase {
    @MainActor
    func testStaleStorageRepairDoesNotEmitADelegateTransition() {
        let info = FeatureInfo()
        info.admitProfileSnapshot([
            "credits": .withBalance(
                10,
                unlimited: false,
                type: .metered
            ),
        ], admittedAt: Date())

        var delegateTransitions: [(old: Double?, new: Double?)] = []
        info.onFeatureChange = { featureId, oldAccess, newAccess in
            guard featureId == "credits" else { return }
            delegateTransitions.append((oldAccess?.balance, newAccess.balance))
        }

        var shouldPublishNestedValue = true
        var observedBalances: [Double?] = []
        var observedStates: [FeatureInfo.State] = []
        let cancellable = info.$all.dropFirst().sink { features in
            observedBalances.append(features["credits"]?.balance)
            observedStates.append(info.state)
            guard shouldPublishNestedValue,
                  features["credits"]?.balance == 20 else { return }
            shouldPublishNestedValue = false
            info.update(
                "credits",
                access: .withBalance(
                    30,
                    unlimited: false,
                    type: .metered
                )
            )
        }

        info.update(
            "credits",
            access: .withBalance(
                20,
                unlimited: false,
                type: .metered
            )
        )

        withExtendedLifetime(cancellable) {
            XCTAssertEqual(observedBalances, [20, 30, 30])
            XCTAssertEqual(observedStates, [.ready, .ready, .ready])
            XCTAssertEqual(delegateTransitions.count, 1)
            XCTAssertEqual(delegateTransitions.first?.old, 10)
            XCTAssertEqual(delegateTransitions.first?.new, 30)
            XCTAssertEqual(info.balance("credits"), 30)
        }
    }

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

    @MainActor
    func testAdmittedProfileBalanceOutranksARecoveredPriorProcessResponse() {
        let info = FeatureInfo()
        info.beginOptimisticProjectionPublication(
            epoch: UUID(),
            distinctId: "customer-a"
        )
        let currentEpoch = info.balanceAuthority(for: "credits").epoch
        let firstPriorEpoch = UUID(
            uuidString: "00000000-0000-0000-0000-000000000001"
        )!
        let priorEpoch = currentEpoch == firstPriorEpoch
            ? UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
            : firstPriorEpoch
        info.admitProfileSnapshot([
            "credits": .withBalance(5, unlimited: false, type: .metered),
        ], admittedAt: Date())

        let recovered = info.commitCommandBalanceIfFresh(
            "credits",
            balance: 3,
            responseAuthority: FeatureBalanceAuthority(
                epoch: priorEpoch,
                generation: 7
            )
        )
        XCTAssertNil(
            recovered,
            """
            an admitted profile balance outranks a recovered prior-process \
            response: the response's server-side effect is already durable \
            and the newer profile reflects it (Orchestration contract)
            """
        )
        XCTAssertEqual(info.balance("credits"), 5)
    }

    @MainActor
    func testCrossEpochResponseCannotUseOverlayForFeatureOmittedByProfile() {
        let info = FeatureInfo()
        info.beginOptimisticProjectionPublication(
            epoch: UUID(),
            distinctId: "customer-a"
        )
        let currentEpoch = info.balanceAuthority(for: "bonus-credits").epoch
        let firstPriorEpoch = UUID(
            uuidString: "00000000-0000-0000-0000-000000000001"
        )!
        let priorEpoch = currentEpoch == firstPriorEpoch
            ? UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
            : firstPriorEpoch
        info.admitProfileSnapshot([:], admittedAt: Date())

        let activeEvidence = [OptimisticPurchaseEvidence(
            transactionId: "transaction-1",
            distinctId: "customer-a",
            backendSynced: false,
            revoked: false
        )]
        let allowances = [
            "transaction-1": [OptimisticEntitlementAllowance(
                featureId: "bonus-credits",
                kind: .metered,
                unlimited: false,
                allowance: 10
            )],
        ]
        info.replaceOptimisticProjection(
            evidence: activeEvidence,
            descriptorAllowances: allowances,
            distinctId: "customer-a"
        )

        XCTAssertEqual(info.balance("bonus-credits"), 10)
        XCTAssertEqual(info.state, .reconciling)
        XCTAssertEqual(
            info.balanceAuthority(for: "bonus-credits").generation,
            0,
            "an overlay must not advance the authority fence"
        )

        let recoveredResponse = info.commitCommandBalanceIfFresh(
            "bonus-credits",
            balance: 3,
            responseAuthority: FeatureBalanceAuthority(
                epoch: priorEpoch,
                generation: 0
            )
        )
        XCTAssertNil(recoveredResponse)
        if let recoveredResponse {
            info.emitCommandBalance(recoveredResponse)
        }

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

        XCTAssertNil(info.feature("bonus-credits"))
        XCTAssertEqual(info.state, .ready)
    }
}
