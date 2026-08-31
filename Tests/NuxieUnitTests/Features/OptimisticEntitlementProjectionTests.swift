import Combine
import Foundation
import XCTest
@testable import Nuxie

final class OptimisticEntitlementProjectionTests: XCTestCase {
    private struct Fixture: Decodable {
        let cases: [Case]

        struct Case: Decodable {
            let name: String
            let distinctId: String
            let profileAdmitted: Bool
            let authoritative: [String: Access]?
            let evidence: [Evidence]?
            let descriptors: [String: [Allowance]]?
            let externalPurchaseDeclarations: [ExternalDeclaration]?
            let expectedOverlay: [String: ExpectedOverlay]?
            let expectedVisible: [String: Access]
            let expectedState: String
            let transitions: [Transition]?
        }

        struct Transition: Decodable {
            let name: String
            let distinctId: String
            let profileAdmitted: Bool
            let authoritative: [String: Access]?
            let evidence: [Evidence]?
            let descriptors: [String: [Allowance]]?
            let expectedOverlay: [String: ExpectedOverlay]?
            let expectedVisible: [String: Access]
            let expectedState: String
        }

        struct Evidence: Decodable {
            let transactionId: String
            let distinctId: String
            let backendSynced: Bool
            let revoked: Bool
        }

        /// Raw signed-descriptor fields; classification into an allowance kind
        /// is the runner's job, so both SDKs must agree on the derivation.
        struct Allowance: Decodable {
            let featureId: String
            let featureExternalId: String?
            let allowanceType: String?
            let allowance: Double?
        }

        /// An input runners must consume and must never derive an overlay
        /// from: external billing produces no verified evidence.
        struct ExternalDeclaration: Decodable {
            let productId: String
            let source: String?
        }

        struct Access: Decodable {
            let allowed: Bool
            let unlimited: Bool
            let balance: Double?
            let type: FeatureType
        }

        struct ExpectedOverlay: Decodable {
            let kind: OptimisticEntitlementAllowance.Kind
            let unlimited: Bool
            let allowance: Double?
        }
    }

    func testProjectionMatchesPortableFixture() async throws {
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
            // The declarations input is deliberately consumed and never fed
            // into derivation: external billing produces no overlay.
            _ = vector.externalPurchaseDeclarations
            var currentEvidence = Self.evidence(vector.evidence)
            var currentDescriptors = Self.descriptors(vector.descriptors)
            let evidence = currentEvidence
            let descriptors = currentDescriptors
            let actual = OptimisticEntitlementProjection.derive(
                evidence: evidence,
                descriptorAllowances: descriptors,
                distinctId: vector.distinctId
            )

            XCTAssertEqual(actual?.count, vector.expectedOverlay?.count, vector.name)
            for (featureId, expected) in vector.expectedOverlay ?? [:] {
                let projected = try XCTUnwrap(actual?[featureId], vector.name)
                XCTAssertEqual(projected.kind, expected.kind, vector.name)
                XCTAssertEqual(projected.unlimited, expected.unlimited, vector.name)
                XCTAssertEqual(projected.allowance, expected.allowance, vector.name)
            }

            let info = await MainActor.run { FeatureInfo() }
            await MainActor.run {
                info.beginOptimisticProjectionPublication(
                    epoch: UUID(),
                    distinctId: vector.distinctId
                )
                if vector.profileAdmitted {
                    info.admitProfileSnapshot(
                        vector.authoritative?.mapValues(Self.featureAccess) ?? [:],
                        admittedAt: Date()
                    )
                }
                info.replaceOptimisticProjection(
                    evidence: evidence,
                    descriptorAllowances: descriptors,
                    distinctId: vector.distinctId
                )
            }
            try await MainActor.run {
                XCTAssertEqual(info.all.count, vector.expectedVisible.count, vector.name)
                for (featureId, expected) in vector.expectedVisible {
                    let visible = try XCTUnwrap(info.feature(featureId), vector.name)
                    Self.assertAccess(visible, equals: expected, message: vector.name)
                }
                XCTAssertEqual(info.state, Self.state(vector.expectedState), vector.name)
            }

            for transition in vector.transitions ?? [] {
                // Transitions may replace the durable inputs to express
                // acknowledgement, revocation, and descriptor changes.
                if let replaced = transition.evidence {
                    currentEvidence = Self.evidence(replaced)
                }
                if let replaced = transition.descriptors {
                    currentDescriptors = Self.descriptors(replaced)
                }
                let transitionOverlay = OptimisticEntitlementProjection.derive(
                    evidence: currentEvidence,
                    descriptorAllowances: currentDescriptors,
                    distinctId: transition.distinctId
                )
                XCTAssertEqual(
                    transitionOverlay?.count,
                    transition.expectedOverlay?.count,
                    transition.name
                )
                for (featureId, expected) in transition.expectedOverlay ?? [:] {
                    let projected = try XCTUnwrap(
                        transitionOverlay?[featureId],
                        transition.name
                    )
                    XCTAssertEqual(projected.kind, expected.kind, transition.name)
                    XCTAssertEqual(projected.unlimited, expected.unlimited, transition.name)
                    XCTAssertEqual(projected.allowance, expected.allowance, transition.name)
                }
                let transitionEvidence = currentEvidence
                let transitionDescriptors = currentDescriptors
                let inputsChanged = transition.evidence != nil
                    || transition.descriptors != nil
                await MainActor.run {
                    info.setProjectionDistinctId(transition.distinctId)
                    if transition.profileAdmitted {
                        info.admitProfileSnapshot(
                            transition.authoritative?.mapValues(Self.featureAccess) ?? [:],
                            admittedAt: Date()
                        )
                    }
                    if inputsChanged {
                        info.replaceOptimisticProjection(
                            evidence: transitionEvidence,
                            descriptorAllowances: transitionDescriptors,
                            distinctId: transition.distinctId
                        )
                    }
                }
                try await MainActor.run {
                    XCTAssertEqual(
                        info.all.count,
                        transition.expectedVisible.count,
                        transition.name
                    )
                    for (featureId, expected) in transition.expectedVisible {
                        let visible = try XCTUnwrap(
                            info.feature(featureId),
                            transition.name
                        )
                        Self.assertAccess(
                            visible,
                            equals: expected,
                            message: transition.name
                        )
                    }
                    XCTAssertEqual(
                        info.state,
                        Self.state(transition.expectedState),
                        transition.name
                    )
                }
            }
        }
    }

    func testDescriptorAllowanceClassificationIsSchemaFaithfulAndDeterministic() {
        let boolean = OptimisticEntitlementAllowance(
            featureId: "boolean",
            featureExternalId: nil,
            allowanceType: nil,
            allowance: nil
        )
        let fixed = OptimisticEntitlementAllowance(
            featureId: "balance",
            featureExternalId: nil,
            allowanceType: "fixed",
            allowance: 10
        )
        let unlimited = OptimisticEntitlementAllowance(
            featureId: "balance",
            featureExternalId: nil,
            allowanceType: "unlimited",
            allowance: nil
        )

        XCTAssertEqual(boolean.kind, .boolean)
        XCTAssertEqual(fixed.kind, .metered)
        XCTAssertEqual(unlimited.kind, .metered)
        let evidence = [
            OptimisticPurchaseEvidence(
                transactionId: "transaction-fixed",
                distinctId: "customer-a",
                backendSynced: false,
                revoked: false
            ),
            OptimisticPurchaseEvidence(
                transactionId: "transaction-unlimited",
                distinctId: "customer-a",
                backendSynced: false,
                revoked: false
            ),
        ]
        for evidenceOrder in [evidence, Array(evidence.reversed())] {
            let projection = OptimisticEntitlementProjection.derive(
                evidence: evidenceOrder,
                descriptorAllowances: [
                    "transaction-fixed": [fixed],
                    "transaction-unlimited": [unlimited],
                ],
                distinctId: "customer-a"
            )
            XCTAssertEqual(projection?["balance"]?.kind, .metered)
            XCTAssertEqual(projection?["balance"]?.unlimited, true)
        }
    }

    private static func evidence(
        _ raw: [Fixture.Evidence]?
    ) -> [OptimisticPurchaseEvidence]? {
        raw?.map {
            OptimisticPurchaseEvidence(
                transactionId: $0.transactionId,
                distinctId: $0.distinctId,
                backendSynced: $0.backendSynced,
                revoked: $0.revoked
            )
        }
    }

    private static func descriptors(
        _ raw: [String: [Fixture.Allowance]]?
    ) -> [String: [OptimisticEntitlementAllowance]]? {
        raw?.mapValues { allowances in
            allowances.map {
                OptimisticEntitlementAllowance(
                    featureId: $0.featureId,
                    featureExternalId: $0.featureExternalId,
                    allowanceType: $0.allowanceType,
                    allowance: $0.allowance
                )
            }
        }
    }

    private static func featureAccess(_ access: Fixture.Access) -> FeatureAccess {
        FeatureAccess(
            allowed: access.allowed,
            unlimited: access.unlimited,
            balance: access.balance,
            type: access.type
        )
    }

    private static func assertAccess(
        _ actual: FeatureAccess,
        equals expected: Fixture.Access,
        message: String
    ) {
        XCTAssertEqual(actual.allowed, expected.allowed, message)
        XCTAssertEqual(actual.unlimited, expected.unlimited, message)
        XCTAssertEqual(actual.balance, expected.balance, message)
        XCTAssertEqual(actual.type, expected.type, message)
    }

    private static func state(_ rawValue: String) -> FeatureInfo.State {
        switch rawValue {
        case "unknown": return .unknown
        case "reconciling": return .reconciling
        case "ready": return .ready
        default:
            XCTFail("unknown fixture state: \(rawValue)")
            return .unknown
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
        info.admitProfileSnapshot([
            "customer-a-only": FeatureAccess(
                allowed: true,
                unlimited: false,
                balance: nil,
                type: .boolean
            ),
        ], admittedAt: Date())
        info.replaceOptimisticProjection(
            evidence: [
                OptimisticPurchaseEvidence(
                    transactionId: "transaction-a",
                    distinctId: "customer-a",
                    backendSynced: false,
                    revoked: false
                ),
                OptimisticPurchaseEvidence(
                    transactionId: "transaction-b",
                    distinctId: "customer-b",
                    backendSynced: false,
                    revoked: false
                ),
            ],
            descriptorAllowances: [
                "transaction-a": [OptimisticEntitlementAllowance(
                    featureId: "premium",
                    kind: .boolean,
                    unlimited: false,
                    allowance: nil
                )],
                "transaction-b": [OptimisticEntitlementAllowance(
                    featureId: "credits",
                    kind: .metered,
                    unlimited: false,
                    allowance: 10
                )],
            ],
            distinctId: "customer-a"
        )
        XCTAssertTrue(info.isAllowed("premium"))

        info.setProjectionDistinctId("customer-b")
        XCTAssertFalse(info.isAllowed("premium"))
        XCTAssertNil(info.feature("customer-a-only"))
        XCTAssertEqual(info.balance("credits"), 10)
        XCTAssertEqual(info.state, .unknown)

        info.setProjectionDistinctId("customer-a")
        XCTAssertTrue(info.isAllowed("premium"))
        XCTAssertNil(info.feature("customer-a-only"))
        XCTAssertEqual(info.state, .unknown)
    }

    @MainActor
    func testAllSubscribersObserveMatchingReadiness() {
        let info = FeatureInfo()
        info.admitProfileSnapshot([:], admittedAt: Date())
        var observedStates: [FeatureInfo.State] = []
        let cancellable = info.$all.dropFirst().sink { _ in
            observedStates.append(info.state)
        }

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
        info.replaceOptimisticProjection(
            evidence: [OptimisticPurchaseEvidence(
                transactionId: "transaction-1",
                distinctId: "customer-a",
                backendSynced: true,
                revoked: false
            )],
            descriptorAllowances: [:],
            distinctId: "customer-a"
        )

        withExtendedLifetime(cancellable) {
            XCTAssertEqual(observedStates, [.reconciling, .ready])
        }
    }

    @MainActor
    func testOverlayRemovalEmitsDeniedDelegateTransition() throws {
        let info = FeatureInfo()
        info.admitProfileSnapshot([:], admittedAt: Date())
        var removal: (FeatureAccess?, FeatureAccess)?
        info.onFeatureChange = { featureId, oldAccess, newAccess in
            guard featureId == "premium", oldAccess != nil, !newAccess.allowed else {
                return
            }
            removal = (oldAccess, newAccess)
        }
        let allowances = [
            "transaction-1": [OptimisticEntitlementAllowance(
                featureId: "premium",
                kind: .boolean,
                unlimited: false,
                allowance: nil
            )],
        ]

        info.replaceOptimisticProjection(
            evidence: [OptimisticPurchaseEvidence(
                transactionId: "transaction-1",
                distinctId: "customer-a",
                backendSynced: false,
                revoked: false
            )],
            descriptorAllowances: allowances,
            distinctId: "customer-a"
        )
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

        XCTAssertTrue(try XCTUnwrap(removal?.0).allowed)
        XCTAssertFalse(try XCTUnwrap(removal?.1).allowed)
        XCTAssertNil(info.feature("premium"))
    }

    @MainActor
    func testDelegateLoopStopsAfterReentrantIdentityChange() {
        let info = FeatureInfo()
        info.admitProfileSnapshot([:], admittedAt: Date())
        var emissions: [String] = []
        info.onFeatureChange = { featureId, _, _ in
            emissions.append(featureId)
            guard emissions.count == 1 else { return }
            info.onFeatureChange = nil
            info.setProjectionDistinctId("customer-b")
        }

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
                        featureId: "a-feature",
                        kind: .boolean,
                        unlimited: false,
                        allowance: nil
                    ),
                    OptimisticEntitlementAllowance(
                        featureId: "b-feature",
                        kind: .boolean,
                        unlimited: false,
                        allowance: nil
                    ),
                ],
            ],
            distinctId: "customer-a"
        )

        XCTAssertEqual(emissions, ["a-feature"])
        XCTAssertEqual(info.state, .unknown)
        XCTAssertTrue(info.all.isEmpty)
    }

    @MainActor
    func testFeatureChangeDelegateIdentitySwitchWinsNestedPublication() {
        let info = FeatureInfo()
        info.admitProfileSnapshot([:], admittedAt: Date())
        var delegateObservedAllowed: Bool?
        var delegateObservedState: FeatureInfo.State?
        info.onFeatureChange = { _, _, _ in
            guard delegateObservedAllowed == nil else { return }
            delegateObservedAllowed = info.isAllowed("premium")
            delegateObservedState = info.state
            info.setProjectionDistinctId("customer-b")
        }

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

        XCTAssertEqual(delegateObservedAllowed, true)
        XCTAssertEqual(delegateObservedState, .reconciling)
        XCTAssertFalse(info.isAllowed("premium"))
        // The identity switch drops the prior customer's profile admission,
        // so the new customer starts unknown rather than inheriting ready.
        XCTAssertEqual(info.state, .unknown)
    }

    @MainActor
    func testFeatureCombineIdentitySwitchWinsNestedPublication() {
        let info = FeatureInfo()
        info.admitProfileSnapshot([:], admittedAt: Date())
        var shouldSwitchIdentity = false
        let cancellable = info.$all.sink { features in
            guard shouldSwitchIdentity, features["premium"]?.allowed == true else {
                return
            }
            shouldSwitchIdentity = false
            info.setProjectionDistinctId("customer-b")
        }

        shouldSwitchIdentity = true
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

        withExtendedLifetime(cancellable) {
            XCTAssertFalse(info.isAllowed("premium"))
            XCTAssertEqual(info.state, .unknown)
        }
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
