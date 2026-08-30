import Foundation
import XCTest
@testable import Nuxie

final class OptimisticEntitlementProjectionTests: XCTestCase {
    private struct Fixture: Decodable {
        let cases: [Case]

        struct Case: Decodable {
            let name: String
            let distinctId: String
            let evidence: [Evidence]?
            let descriptors: [String: [Allowance]]?
            let expected: [String: Expected]?
        }

        struct Evidence: Decodable {
            let transactionId: String
            let distinctId: String
            let backendSynced: Bool
            let revoked: Bool
        }

        struct Allowance: Decodable {
            let featureId: String
            let kind: OptimisticEntitlementAllowance.Kind
            let unlimited: Bool?
            let allowance: Double?
        }

        struct Expected: Decodable {
            let kind: OptimisticEntitlementAllowance.Kind
            let unlimited: Bool
            let allowance: Double?
        }
    }

    func testProjectionMatchesPortableFixture() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("fixtures/features/optimistic-entitlement-projection.json")
        let fixture = try JSONDecoder().decode(
            Fixture.self,
            from: Data(contentsOf: fixtureURL)
        )

        for vector in fixture.cases {
            let evidence = vector.evidence?.map {
                OptimisticPurchaseEvidence(
                    transactionId: $0.transactionId,
                    distinctId: $0.distinctId,
                    backendSynced: $0.backendSynced,
                    revoked: $0.revoked
                )
            }
            let descriptors = vector.descriptors?.mapValues { allowances in
                allowances.map {
                    OptimisticEntitlementAllowance(
                        featureId: $0.featureId,
                        kind: $0.kind,
                        unlimited: $0.unlimited ?? false,
                        allowance: $0.allowance
                    )
                }
            }
            let actual = OptimisticEntitlementProjection.derive(
                evidence: evidence,
                descriptorAllowances: descriptors,
                distinctId: vector.distinctId
            )

            XCTAssertEqual(actual?.count, vector.expected?.count, vector.name)
            for (featureId, expected) in vector.expected ?? [:] {
                let projected = try XCTUnwrap(actual?[featureId], vector.name)
                XCTAssertEqual(projected.kind, expected.kind, vector.name)
                XCTAssertEqual(projected.unlimited, expected.unlimited, vector.name)
                XCTAssertEqual(projected.allowance, expected.allowance, vector.name)
            }
        }
    }

    @MainActor
    func testFeatureInfoJoinsOverlayWithoutAdvancingAuthority() throws {
        let info = FeatureInfo()
        XCTAssertEqual(info.state, .unknown)

        info.admitProfileSnapshot([
            "premium": FeatureAccess(
                allowed: false,
                unlimited: false,
                balance: nil,
                type: .boolean
            ),
            "credits": FeatureAccess.withBalance(
                5,
                unlimited: false,
                type: .metered
            ),
        ], admittedAt: Date())
        let authorityBeforeProjection = info.balanceAuthority(for: "credits")
        XCTAssertEqual(info.state, .ready)

        info.replaceOptimisticProjection(
            evidence: [OptimisticPurchaseEvidence(
                transactionId: "transaction-1",
                distinctId: "customer-a",
                backendSynced: false,
                revoked: false
            )],
            descriptorAllowances: [
                "transaction-1": [
                    OptimisticEntitlementAllowance(
                        featureId: "premium",
                        kind: .boolean,
                        unlimited: false,
                        allowance: nil
                    ),
                    OptimisticEntitlementAllowance(
                        featureId: "credits",
                        kind: .metered,
                        unlimited: false,
                        allowance: 10
                    ),
                ],
            ],
            distinctId: "customer-a"
        )

        XCTAssertEqual(info.state, .reconciling)
        XCTAssertTrue(info.isAllowed("premium"))
        XCTAssertEqual(info.balance("credits"), 15)
        XCTAssertEqual(
            info.balanceAuthority(for: "credits"),
            authorityBeforeProjection
        )

        info.decrementBalance("credits", amount: 1)
        XCTAssertEqual(info.balance("credits"), 14)
        XCTAssertEqual(
            info.balanceAuthority(for: "credits"),
            authorityBeforeProjection,
            "visual usage feedback must not consume overlay or authority"
        )

        let spendEmission = info.commitCommandBalanceIfFresh(
            "credits",
            balance: 4,
            responseAuthority: authorityBeforeProjection
        )
        info.emitCommandBalance(try XCTUnwrap(spendEmission))
        XCTAssertEqual(
            info.balance("credits"),
            14,
            "ordered command application decrements the visible join only"
        )
        XCTAssertEqual(
            info.balanceAuthority(for: "credits"),
            authorityBeforeProjection
        )

        info.update(
            "credits",
            access: .withBalance(2, unlimited: false, type: .metered)
        )
        let snapshotAuthority = info.balanceAuthority(for: "credits")
        XCTAssertEqual(snapshotAuthority.generation, authorityBeforeProjection.generation + 1)
        XCTAssertEqual(info.balance("credits"), 12)

        info.replaceOptimisticProjection(
            evidence: [OptimisticPurchaseEvidence(
                transactionId: "transaction-1",
                distinctId: "customer-a",
                backendSynced: true,
                revoked: false
            )],
            descriptorAllowances: [
                "transaction-1": [OptimisticEntitlementAllowance(
                    featureId: "credits",
                    kind: .metered,
                    unlimited: false,
                    allowance: 10
                )],
            ],
            distinctId: "customer-a"
        )

        XCTAssertEqual(info.state, .ready)
        XCTAssertEqual(info.balance("credits"), 2)
        XCTAssertEqual(info.balanceAuthority(for: "credits"), snapshotAuthority)
    }

    @MainActor
    func testFeatureInfoScopesProjectionToIdentityAndRestoresItOnReturn() {
        let info = FeatureInfo()
        info.admitProfileSnapshot([:], admittedAt: Date())
        info.replaceOptimisticProjection(
            evidence: [OptimisticPurchaseEvidence(
                transactionId: "transaction-1",
                distinctId: "customer-a",
                backendSynced: false,
                revoked: false
            )],
            descriptorAllowances: [
                "transaction-1": [OptimisticEntitlementAllowance(
                    featureId: "premium",
                    kind: .boolean,
                    unlimited: false,
                    allowance: nil
                )],
            ],
            distinctId: "customer-a"
        )
        XCTAssertTrue(info.isAllowed("premium"))

        info.setProjectionDistinctId("customer-b")
        XCTAssertFalse(info.isAllowed("premium"))
        XCTAssertEqual(info.state, .ready)

        info.setProjectionDistinctId("customer-a")
        XCTAssertTrue(info.isAllowed("premium"))
        XCTAssertEqual(info.state, .reconciling)
    }

    @MainActor
    func testOlderProjectionPublicationCannotResurrectClearedEvidence() {
        let info = FeatureInfo()
        let publicationEpoch = UUID()
        info.beginOptimisticProjectionPublication(
            epoch: publicationEpoch,
            distinctId: "customer-a"
        )
        info.admitProfileSnapshot([:], admittedAt: Date())
        let evidence = [OptimisticPurchaseEvidence(
            transactionId: "transaction-1",
            distinctId: "customer-a",
            backendSynced: false,
            revoked: false
        )]
        let allowances = [
            "transaction-1": [OptimisticEntitlementAllowance(
                featureId: "premium",
                kind: .boolean,
                unlimited: false,
                allowance: nil
            )],
        ]

        info.replaceOptimisticProjection(
            evidence: evidence,
            descriptorAllowances: allowances,
            distinctId: "customer-a",
            publicationEpoch: publicationEpoch,
            publicationGeneration: 1
        )
        XCTAssertTrue(info.isAllowed("premium"))

        info.replaceOptimisticProjection(
            evidence: nil,
            descriptorAllowances: nil,
            distinctId: "customer-a",
            publicationEpoch: publicationEpoch,
            publicationGeneration: 2
        )
        info.replaceOptimisticProjection(
            evidence: evidence,
            descriptorAllowances: allowances,
            distinctId: "customer-a",
            publicationEpoch: publicationEpoch,
            publicationGeneration: 1
        )

        XCTAssertFalse(info.isAllowed("premium"))
        XCTAssertEqual(info.state, .ready)
    }

    @MainActor
    func testNewPublicationEpochRejectsOldObserverAndRestartsGeneration() {
        let info = FeatureInfo()
        let oldEpoch = UUID()
        let newEpoch = UUID()
        let evidence = [OptimisticPurchaseEvidence(
            transactionId: "transaction-1",
            distinctId: "customer-b",
            backendSynced: false,
            revoked: false
        )]
        let allowances = [
            "transaction-1": [OptimisticEntitlementAllowance(
                featureId: "premium",
                kind: .boolean,
                unlimited: false,
                allowance: nil
            )],
        ]

        info.beginOptimisticProjectionPublication(
            epoch: oldEpoch,
            distinctId: "customer-a"
        )
        info.replaceOptimisticProjection(
            evidence: nil,
            descriptorAllowances: nil,
            distinctId: "customer-a",
            publicationEpoch: oldEpoch,
            publicationGeneration: 99
        )
        info.beginOptimisticProjectionPublication(
            epoch: newEpoch,
            distinctId: "customer-b"
        )
        info.replaceOptimisticProjection(
            evidence: evidence,
            descriptorAllowances: allowances,
            distinctId: "customer-b",
            publicationEpoch: oldEpoch,
            publicationGeneration: 100
        )
        XCTAssertFalse(info.isAllowed("premium"))
        XCTAssertEqual(info.state, .unknown)

        info.admitProfileSnapshot([:], admittedAt: Date())
        info.replaceOptimisticProjection(
            evidence: evidence,
            descriptorAllowances: allowances,
            distinctId: "customer-b",
            publicationEpoch: newEpoch,
            publicationGeneration: 1
        )
        XCTAssertTrue(info.isAllowed("premium"))
        XCTAssertEqual(info.state, .reconciling)
    }
}
