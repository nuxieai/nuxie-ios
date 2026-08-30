import Foundation
import Quick
import Nimble
import XCTest
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

private final class TransactionEvidenceEventSink: SystemEventSink, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func emit(_ name: String, properties _: [String: Any]?) {
        lock.withLock { storage.append(name) }
    }

    var names: [String] { lock.withLock { storage } }
}

private final class SuccessfulPurchaseSyncAPI: PurchaseSynchronizing, @unchecked Sendable {
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
}

private final class UnavailablePurchaseSyncAPI: PurchaseSynchronizing, @unchecked Sendable {
    func syncTransaction(
        transactionJwt _: String,
        distinctId _: String
    ) async throws -> PurchaseResponse {
        throw URLError(.notConnectedToInternet)
    }
}

private final class RevokedPurchaseSyncAPI: PurchaseSynchronizing, @unchecked Sendable {
    func syncTransaction(
        transactionJwt _: String,
        distinctId: String
    ) async throws -> PurchaseResponse {
        PurchaseResponse(
            success: true,
            customerId: distinctId,
            features: [
                PurchaseFeature(
                    id: "feature-revoked",
                    extId: nil,
                    type: .boolean,
                    allowed: false,
                    balance: nil,
                    unlimited: false
                ),
            ],
            error: nil
        )
    }
}

private actor OptimisticProjectionRecorder {
    private var snapshots: [[OptimisticPurchaseEvidence]?] = []

    func record(_ evidence: [OptimisticPurchaseEvidence]?) {
        snapshots.append(evidence)
    }

    func latest() -> [OptimisticPurchaseEvidence]? {
        snapshots.last ?? nil
    }
}

private actor ActiveAuthoritySwitch {
    private var value: ActiveProductEvidenceAuthorityResolution = .readyNoMatch

    func set(_ value: ActiveProductEvidenceAuthorityResolution) {
        self.value = value
    }

    func get() -> ActiveProductEvidenceAuthorityResolution { value }
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
                    productFeatureIds: ["feature-1", "feature"],
                    isRevoked: false
                )

                store.save([evidence.transactionId: evidence])
                expect(store.load().valueTreatingAbsentAsEmpty([:])![evidence.transactionId]) == evidence
                store.save([:])
                expect(store.load().valueTreatingAbsentAsEmpty([:])!).to(beEmpty())
            }

            it("re-derives optimistic access after relaunch without persisting allowances") {
                let root = FileManager.default.temporaryDirectory
                    .appendingPathComponent("evidence-relaunch-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: root) }
                let evidence = StoredTransactionEvidence(
                    transactionJws: "signed-jws",
                    transactionId: "transaction-relaunch",
                    originalTransactionId: "original-relaunch",
                    productId: "product-relaunch",
                    distinctId: "customer-1",
                    recordedAt: Date(timeIntervalSince1970: 10),
                    isRevoked: false
                )
                TransactionEvidenceStore(customStoragePath: root).save([
                    evidence.transactionId: evidence,
                ])

                let relaunchedEvidence = TransactionEvidenceStore(customStoragePath: root)
                    .load()
                    .valueTreatingAbsentAsEmpty([:])!
                    .values
                    .map {
                        OptimisticPurchaseEvidence(
                            transactionId: $0.transactionId,
                            distinctId: $0.distinctId,
                            backendSynced: $0.backendSyncedAt != nil,
                            revoked: $0.isRevoked
                        )
                    }
                let projection = OptimisticEntitlementProjection.derive(
                    evidence: relaunchedEvidence,
                    descriptorAllowances: [
                        evidence.transactionId: [OptimisticEntitlementAllowance(
                            featureId: "premium",
                            kind: .boolean,
                            unlimited: false,
                            allowance: nil
                        )],
                    ],
                    distinctId: "customer-1"
                )

                expect(projection?["premium"]?.kind) == .boolean
            }

        }
    }
}

final class TransactionObserverEvidenceRaceTests: XCTestCase {
    func testRejectsEvidenceForAnotherStoreProduct() async {
        let mocks = MockFactory.shared
        mocks.identityService.setDistinctId("customer-1")
        let settings = NuxieRuntimeSettings(
            configuration: NuxieConfiguration(apiKey: "isolated")
        )
        let evidenceStore = InMemoryTransactionEvidenceStore()
        let features = FeatureService(
            api: mocks.nuxieApi,
            identity: mocks.identityService,
            profile: mocks.profileService,
            dateProvider: mocks.dateProvider,
            featureInfo: FeatureInfo(),
            cacheTTL: 300
        )
        let observer = TransactionObserver(
            api: SuccessfulPurchaseSyncAPI(),
            features: features,
            identity: mocks.identityService,
            settings: settings,
            eventSink: TransactionEvidenceEventSink(),
            transactionServiceProvider: { fatalError("unused in this test") },
            evidenceStore: evidenceStore
        )
        let product = StoreProduct(
            productId: "catalog-product",
            storeProductId: "store-product",
            placementId: "placement",
            name: "Product",
            price: "$1.00",
            period: nil
        )
        let mismatched = StoreTransactionEvidence(
            transactionJws: "signed-jws",
            transactionId: "transaction-mismatch",
            originalTransactionId: "original-mismatch",
            productId: "different-store-product",
            finish: {}
        )

        let recorded = await observer.recordVerifiedPurchase(
            evidence: mismatched,
            product: product,
            distinctId: "customer-1",
            finishRequired: true
        )

        XCTAssertFalse(recorded)
        XCTAssertTrue(evidenceStore.load().valueTreatingAbsentAsEmpty([:])!.isEmpty)
    }

    func testVerifiedEvidenceProjectsImmediatelyAndRevocationRemovesIt() async {
        let mocks = MockFactory.shared
        mocks.identityService.setDistinctId("test-user")
        let settings = NuxieRuntimeSettings(configuration: NuxieConfiguration(
            apiKey: "isolated"
        ))
        let features = FeatureService(
            api: mocks.nuxieApi,
            identity: mocks.identityService,
            profile: mocks.profileService,
            dateProvider: mocks.dateProvider,
            featureInfo: FeatureInfo(),
            cacheTTL: NuxieInternalConfiguration().featureCacheTTL
        )
        let authority = ActiveAuthoritySwitch()
        let pendingService = TransactionService(
            productService: mocks.productService,
            transactionObserver: MockTransactionObserver(),
            pendingPurchaseStore: InMemoryPendingPurchaseStore(),
            dateProvider: mocks.dateProvider,
            settings: settings,
            eventSink: TransactionEvidenceEventSink(),
            identityService: mocks.identityService,
            featureService: features,
            activeProductEvidenceAuthority: { _ in await authority.get() }
        )
        let recorder = OptimisticProjectionRecorder()
        let evidenceStore = InMemoryTransactionEvidenceStore()
        let observer = TransactionObserver(
            api: UnavailablePurchaseSyncAPI(),
            features: features,
            identity: mocks.identityService,
            settings: settings,
            eventSink: TransactionEvidenceEventSink(),
            transactionServiceProvider: { pendingService },
            evidenceStore: evidenceStore,
            descriptorAllowanceProvider: { _ in
                [OptimisticEntitlementAllowance(
                    featureId: "premium",
                    kind: .boolean,
                    unlimited: false,
                    allowance: nil
                )]
            },
            projectionPublisher: { evidence, _, _, _ in
                await recorder.record(evidence)
            }
        )
        let active = VerifiedStoreTransactionUpdate(
            transactionId: "transaction-projection",
            originalTransactionId: "original-projection",
            productId: "product-projection",
            appAccountToken: nil,
            isRevoked: false,
            isUpgraded: false,
            finish: {}
        )

        await observer.handleVerifiedTransaction(
            active,
            jwsRepresentation: "active-jws",
            source: .storeUpdates
        )
        let activeProjection = await recorder.latest()
        XCTAssertEqual(activeProjection?.first?.revoked, false)

        await authority.set(.unavailable)
        await observer.handleVerifiedTransaction(
            VerifiedStoreTransactionUpdate(
                transactionId: active.transactionId,
                originalTransactionId: active.originalTransactionId,
                productId: active.productId,
                appAccountToken: nil,
                isRevoked: true,
                isUpgraded: false,
                finish: {}
            ),
            jwsRepresentation: "revoked-jws",
            source: .storeUpdates
        )
        let revokedProjection = await recorder.latest()
        XCTAssertEqual(revokedProjection?.first?.revoked, true)
        let retainedAfterBlockedRevocation = evidenceStore.load()
            .valueTreatingAbsentAsEmpty([:])?[active.transactionId]
        XCTAssertEqual(
            retainedAfterBlockedRevocation?.isRevoked,
            true,
            "revocation persists before later authority checks can defer processing"
        )

        await observer.retryStoredEvidence()
        let recomputedProjection = await recorder.latest()
        XCTAssertEqual(
            recomputedProjection?.first?.revoked,
            true,
            "later recomputation must retain verified revocation evidence"
        )
    }

    func testImmediateRevocationWithoutStoredEvidenceRejectsLateActiveWrite() async {
        let mocks = MockFactory.shared
        mocks.identityService.setDistinctId("test-user")
        let settings = NuxieRuntimeSettings(configuration: NuxieConfiguration(
            apiKey: "isolated"
        ))
        let features = FeatureService(
            api: mocks.nuxieApi,
            identity: mocks.identityService,
            profile: mocks.profileService,
            dateProvider: mocks.dateProvider,
            featureInfo: FeatureInfo(),
            cacheTTL: NuxieInternalConfiguration().featureCacheTTL
        )
        let authority = ActiveAuthoritySwitch()
        await authority.set(.unavailable)
        let pendingService = TransactionService(
            productService: mocks.productService,
            transactionObserver: MockTransactionObserver(),
            pendingPurchaseStore: InMemoryPendingPurchaseStore(),
            dateProvider: mocks.dateProvider,
            settings: settings,
            eventSink: TransactionEvidenceEventSink(),
            identityService: mocks.identityService,
            featureService: features,
            activeProductEvidenceAuthority: { _ in await authority.get() }
        )
        let evidenceStore = InMemoryTransactionEvidenceStore()
        let observer = TransactionObserver(
            api: UnavailablePurchaseSyncAPI(),
            features: features,
            identity: mocks.identityService,
            settings: settings,
            eventSink: TransactionEvidenceEventSink(),
            transactionServiceProvider: { pendingService },
            evidenceStore: evidenceStore
        )
        let transactionId = "transaction-late-active"
        let originalTransactionId = "original-late-active"

        await observer.handleVerifiedTransaction(
            VerifiedStoreTransactionUpdate(
                transactionId: transactionId,
                originalTransactionId: originalTransactionId,
                productId: "product-late-active",
                appAccountToken: nil,
                isRevoked: true,
                isUpgraded: false,
                finish: {}
            ),
            jwsRepresentation: "revoked-jws",
            source: .storeUpdates
        )
        XCTAssertTrue(evidenceStore.load().valueTreatingAbsentAsEmpty([:])!.isEmpty)

        let recorded = await observer.recordVerifiedPurchase(
            evidence: StoreTransactionEvidence(
                transactionJws: "late-active-jws",
                transactionId: transactionId,
                originalTransactionId: originalTransactionId,
                productId: "product-late-active",
                finish: {}
            ),
            product: StoreProduct(
                productId: "product-late-active",
                placementId: "placement-late-active",
                name: "Product",
                price: "$1.00",
                period: nil
            ),
            distinctId: "test-user",
            finishRequired: true
        )

        XCTAssertTrue(recorded)
        XCTAssertEqual(
            evidenceStore.load().valueTreatingAbsentAsEmpty([:])?[transactionId]?.isRevoked,
            true
        )
    }

    func testExistingRevocationCannotBeDowngradedByPurchaseRecording() async {
        let mocks = MockFactory.shared
        mocks.identityService.setDistinctId("test-user")
        let settings = NuxieRuntimeSettings(configuration: NuxieConfiguration(
            apiKey: "isolated"
        ))
        let evidenceStore = InMemoryTransactionEvidenceStore()
        let revoked = StoredTransactionEvidence(
            transactionJws: "revoked-jws",
            transactionId: "transaction-revoked-write",
            originalTransactionId: "original-revoked-write",
            productId: "product-revoked-write",
            distinctId: "test-user",
            recordedAt: Date(),
            isRevoked: true
        )
        XCTAssertTrue(evidenceStore.save([revoked.transactionId: revoked]))
        let observer = TransactionObserver(
            api: UnavailablePurchaseSyncAPI(),
            features: FeatureService(
                api: mocks.nuxieApi,
                identity: mocks.identityService,
                profile: mocks.profileService,
                dateProvider: mocks.dateProvider,
                featureInfo: FeatureInfo(),
                cacheTTL: NuxieInternalConfiguration().featureCacheTTL
            ),
            identity: mocks.identityService,
            settings: settings,
            eventSink: TransactionEvidenceEventSink(),
            transactionServiceProvider: { fatalError("unused in this test") },
            evidenceStore: evidenceStore
        )

        let recorded = await observer.recordVerifiedPurchase(
            evidence: StoreTransactionEvidence(
                transactionJws: "late-active-jws",
                transactionId: revoked.transactionId,
                originalTransactionId: revoked.originalTransactionId,
                productId: revoked.productId,
                finish: {}
            ),
            product: StoreProduct(
                productId: revoked.productId,
                placementId: "placement-revoked-write",
                name: "Product",
                price: "$1.00",
                period: nil
            ),
            distinctId: "test-user",
            finishRequired: true
        )

        XCTAssertTrue(recorded)
        XCTAssertEqual(
            evidenceStore.load().valueTreatingAbsentAsEmpty([:])?[revoked.transactionId]?.isRevoked,
            true
        )
        XCTAssertEqual(
            evidenceStore.load().valueTreatingAbsentAsEmpty([:])?[revoked.transactionId]?
                .transactionJws,
            "revoked-jws"
        )
    }

    func testStoredEvidenceDoesNotEmitSyncForAnotherActiveCustomer() async {
        let mocks = MockFactory.shared
        mocks.identityService.setDistinctId("customer-b")
        let configuration = NuxieConfiguration(apiKey: "isolated")
        let settings = NuxieRuntimeSettings(configuration: configuration)
        let evidenceStore = InMemoryTransactionEvidenceStore()
        let features = FeatureService(
            api: mocks.nuxieApi,
            identity: mocks.identityService,
            profile: mocks.profileService,
            dateProvider: mocks.dateProvider,
            featureInfo: FeatureInfo(),
            cacheTTL: NuxieInternalConfiguration().featureCacheTTL
        )
        let evidence = StoredTransactionEvidence(
            transactionJws: "signed-jws",
            transactionId: "transaction-customer-a",
            originalTransactionId: "original-customer-a",
            productId: "store-product",
            distinctId: "customer-a",
            recordedAt: Date(),
            isRevoked: false,
            finishRequired: false
        )
        XCTAssertTrue(evidenceStore.save([evidence.transactionId: evidence]))
        let eventSink = TransactionEvidenceEventSink()
        let observer = TransactionObserver(
            api: SuccessfulPurchaseSyncAPI(),
            features: features,
            identity: mocks.identityService,
            settings: settings,
            eventSink: eventSink,
            transactionServiceProvider: { fatalError("unused in this test") },
            evidenceStore: evidenceStore
        )

        await observer.retryStoredEvidence()

        XCTAssertFalse(eventSink.names.contains(SystemEventNames.purchaseSynced))
        XCTAssertTrue(evidenceStore.load().valueTreatingAbsentAsEmpty([:])!.isEmpty)
    }

    func testStoredRevocationAppliesServerStateButKeepsUnmatchedFinishOwnership() async {
        let mocks = MockFactory.shared
        mocks.identityService.setDistinctId("test-user")
        let configuration = NuxieConfiguration(apiKey: "isolated")
        let settings = NuxieRuntimeSettings(configuration: configuration)
        let evidenceStore = InMemoryTransactionEvidenceStore()
        let features = FeatureService(
            api: mocks.nuxieApi,
            identity: mocks.identityService,
            profile: mocks.profileService,
            dateProvider: mocks.dateProvider,
            featureInfo: FeatureInfo(),
            cacheTTL: NuxieInternalConfiguration().featureCacheTTL
        )
        await features.updateFromPurchase([
            PurchaseFeature(
                id: "feature-revoked",
                extId: nil,
                type: .boolean,
                allowed: true,
                balance: nil,
                unlimited: false
            ),
        ], distinctId: "test-user")
        let evidence = StoredTransactionEvidence(
            transactionJws: "revocation-jws",
            transactionId: "transaction-revoked",
            originalTransactionId: "original-revoked",
            productId: "product-revoked",
            distinctId: "test-user",
            recordedAt: Date(),
            isRevoked: true,
            finishRequired: true
        )
        XCTAssertTrue(evidenceStore.save([evidence.transactionId: evidence]))
        let pendingService = TransactionService(
            productService: mocks.productService,
            transactionObserver: MockTransactionObserver(),
            pendingPurchaseStore: InMemoryPendingPurchaseStore(),
            dateProvider: mocks.dateProvider,
            settings: settings,
            eventSink: TransactionEvidenceEventSink(),
            identityService: mocks.identityService,
            featureService: features
        )
        let observer = TransactionObserver(
            api: RevokedPurchaseSyncAPI(),
            features: features,
            identity: mocks.identityService,
            settings: settings,
            eventSink: TransactionEvidenceEventSink(),
            transactionServiceProvider: { pendingService },
            evidenceStore: evidenceStore
        )

        await observer.retryStoredEvidence()

        let access = await features.getCached(
            featureId: "feature-revoked",
            entityId: nil
        )
        XCTAssertEqual(access?.allowed, false)
        let retained = evidenceStore.load().valueTreatingAbsentAsEmpty([:])![evidence.transactionId]
        XCTAssertEqual(retained?.finishRequired, true)
        XCTAssertEqual(retained?.transactionJws, "")
        XCTAssertNotNil(retained?.backendSyncedAt)
    }

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
            cacheTTL: NuxieInternalConfiguration().featureCacheTTL
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
            product: product,
            distinctId: "customer-1",
            finishRequired: true
        )
        XCTAssertTrue(firstRecord)
        let firstSync = await observer.syncTransaction(
            transactionJws: evidence.transactionJws,
            transactionId: evidence.transactionId,
            productId: evidence.productId,
            originalTransactionId: evidence.originalTransactionId
        )
        XCTAssertTrue(firstSync)
        XCTAssertTrue(evidenceStore.load().valueTreatingAbsentAsEmpty([:])![evidence.transactionId]?.finishRequired == true)
        await observer.markTransactionFinished(transactionId: evidence.transactionId)
        XCTAssertNil(evidenceStore.load().valueTreatingAbsentAsEmpty([:])![evidence.transactionId])

        // Model the direct purchase callback persisting after the observer has
        // already completed the same transaction from Transaction.updates.
        let lateRecord = await observer.recordVerifiedPurchase(
            evidence: evidence,
            product: product,
            distinctId: "customer-1",
            finishRequired: true
        )
        XCTAssertTrue(lateRecord)
        XCTAssertNotNil(evidenceStore.load().valueTreatingAbsentAsEmpty([:])![evidence.transactionId])
        let deduplicatedSync = await observer.syncTransaction(
            transactionJws: evidence.transactionJws,
            transactionId: evidence.transactionId,
            productId: evidence.productId,
            originalTransactionId: evidence.originalTransactionId
        )
        XCTAssertTrue(deduplicatedSync)
        XCTAssertTrue(evidenceStore.load().valueTreatingAbsentAsEmpty([:])![evidence.transactionId]?.finishRequired == true)
    }
}
