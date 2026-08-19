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
                    ],
                    isRevoked: false
                )

                store.save([evidence.transactionId: evidence])
                expect(store.load()[evidence.transactionId]) == evidence
                store.save([:])
                expect(store.load()).to(beEmpty())
            }

            it("round trips local access independently from receipt evidence") {
                let root = FileManager.default.temporaryDirectory
                    .appendingPathComponent("access-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: root) }
                let store = LocalPurchaseAccessStore(customStoragePath: root)
                let access = StoredLocalPurchaseAccess(
                    transactionId: "transaction-1",
                    originalTransactionId: "original-1",
                    productId: "store-product-1",
                    distinctId: "customer-1",
                    grants: [
                        StoredLocalEntitlementGrant(
                            featureId: "feature-1",
                            featureExternalId: "feature",
                            allowanceType: "boolean",
                            allowance: nil
                        )
                    ],
                    state: .active
                )

                expect(store.save([access.transactionId: access])).to(beTrue())
                expect(store.load()[access.transactionId]) == access
                expect(store.save([:])).to(beTrue())
                expect(store.load()).to(beEmpty())
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
        let accessStore = InMemoryLocalPurchaseAccessStore()
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
            evidenceStore: evidenceStore,
            localAccessStore: accessStore
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
        XCTAssertTrue(evidenceStore.load().isEmpty)
        XCTAssertTrue(accessStore.load().isEmpty)
    }

    func testLocalAccessSurvivesEvidenceRetirementAndRelaunch() async {
        let mocks = MockFactory.shared
        mocks.identityService.setDistinctId("customer-1")
        let configuration = NuxieConfiguration(apiKey: "isolated")
        let settings = NuxieRuntimeSettings(configuration: configuration)
        let evidenceStore = InMemoryTransactionEvidenceStore()
        let accessStore = InMemoryLocalPurchaseAccessStore()
        let firstFeatures = FeatureService(
            api: mocks.nuxieApi,
            identity: mocks.identityService,
            profile: mocks.profileService,
            dateProvider: mocks.dateProvider,
            featureInfo: FeatureInfo(),
            cacheTTL: configuration.featureCacheTTL
        )
        var product = StoreProduct(
            productId: "catalog-product",
            storeProductId: "store-product",
            placementId: "placement",
            name: "Product",
            price: "$1.00",
            period: nil
        )
        product.localEntitlementGrants = [
            StoreProduct.LocalEntitlementGrant(
                featureId: "premium-export",
                featureExternalId: nil,
                allowanceType: "boolean",
                allowance: nil
            )
        ]
        let evidence = StoreTransactionEvidence(
            transactionJws: "signed-jws",
            transactionId: "transaction-durable-access",
            originalTransactionId: "original-durable-access",
            productId: product.storeProductId,
            finish: {}
        )
        let firstObserver = TransactionObserver(
            api: SuccessfulPurchaseSyncAPI(),
            features: firstFeatures,
            identity: mocks.identityService,
            settings: settings,
            eventSink: TransactionEvidenceEventSink(),
            transactionServiceProvider: { fatalError("unused in this test") },
            evidenceStore: evidenceStore,
            localAccessStore: accessStore
        )

        let recorded = await firstObserver.recordVerifiedPurchase(
            evidence: evidence,
            product: product,
            distinctId: "customer-1",
            finishRequired: false
        )
        XCTAssertTrue(recorded)
        let synced = await firstObserver.syncTransaction(
            transactionJws: evidence.transactionJws,
            transactionId: evidence.transactionId,
            productId: evidence.productId,
            originalTransactionId: evidence.originalTransactionId
        )
        XCTAssertTrue(synced)
        XCTAssertTrue(evidenceStore.load().isEmpty)
        XCTAssertNotNil(accessStore.load()[evidence.transactionId])

        let relaunchedFeatures = FeatureService(
            api: mocks.nuxieApi,
            identity: mocks.identityService,
            profile: mocks.profileService,
            dateProvider: mocks.dateProvider,
            featureInfo: FeatureInfo(),
            cacheTTL: configuration.featureCacheTTL,
            localPurchaseAccessStore: accessStore
        )
        let relaunchedObserver = TransactionObserver(
            api: SuccessfulPurchaseSyncAPI(),
            features: relaunchedFeatures,
            identity: mocks.identityService,
            settings: settings,
            eventSink: TransactionEvidenceEventSink(),
            transactionServiceProvider: { fatalError("unused in this test") },
            evidenceStore: evidenceStore,
            localAccessStore: accessStore,
            activeStoreOriginalTransactionIDs: {
                ["original-durable-access"]
            }
        )

        await relaunchedObserver.retryStoredEvidence()

        let access = await relaunchedFeatures.getCached(
            featureId: "premium-export",
            entityId: nil
        )
        XCTAssertEqual(access?.allowed, true)
    }

    func testExpiredEvidenceCannotRecreateReconciledLocalAccess() async {
        let mocks = MockFactory.shared
        mocks.identityService.setDistinctId("customer-1")
        let configuration = NuxieConfiguration(apiKey: "isolated")
        let evidenceStore = InMemoryTransactionEvidenceStore()
        let accessStore = InMemoryLocalPurchaseAccessStore()
        let features = FeatureService(
            api: mocks.nuxieApi,
            identity: mocks.identityService,
            profile: mocks.profileService,
            dateProvider: mocks.dateProvider,
            featureInfo: FeatureInfo(),
            cacheTTL: configuration.featureCacheTTL
        )
        let grant = StoredLocalEntitlementGrant(
            featureId: "expired-feature",
            featureExternalId: nil,
            allowanceType: "boolean",
            allowance: nil
        )
        let evidence = StoredTransactionEvidence(
            transactionJws: "expired-jws",
            transactionId: "expired-transaction",
            originalTransactionId: "expired-original",
            productId: "expired-product",
            distinctId: "customer-1",
            recordedAt: Date(),
            localEntitlementGrants: [grant],
            isRevoked: false,
            finishRequired: false
        )
        XCTAssertTrue(evidenceStore.save([evidence.transactionId: evidence]))
        XCTAssertTrue(accessStore.save([
            evidence.transactionId: StoredLocalPurchaseAccess(
                transactionId: evidence.transactionId,
                originalTransactionId: evidence.originalTransactionId,
                productId: evidence.productId,
                distinctId: evidence.distinctId,
                grants: [grant],
                state: .active
            )
        ]))
        let observer = TransactionObserver(
            api: UnavailablePurchaseSyncAPI(),
            features: features,
            identity: mocks.identityService,
            settings: NuxieRuntimeSettings(configuration: configuration),
            eventSink: TransactionEvidenceEventSink(),
            transactionServiceProvider: { fatalError("unused in this test") },
            evidenceStore: evidenceStore,
            localAccessStore: accessStore,
            activeStoreOriginalTransactionIDs: { [] }
        )

        await observer.retryStoredEvidence()

        XCTAssertEqual(
            accessStore.load()[evidence.transactionId]?.state,
            .revoked
        )
        let access = await features.getCached(
            featureId: grant.featureId,
            entityId: nil
        )
        XCTAssertEqual(access?.allowed, false)

        // A new service/observer pair represents process relaunch. The
        // durable tombstone must still beat an older allowed profile.
        mocks.profileService.setProfileResponse(ProfileResponse(
            segments: [],
            userProperties: nil,
            experiments: nil,
            features: [Feature(
                id: grant.featureId,
                type: .boolean,
                balance: nil,
                unlimited: true,
                nextResetAt: nil,
                interval: nil,
                entities: nil
            )]
        ))
        _ = try? await mocks.profileService.refetchProfile(
            distinctId: "customer-1"
        )
        let relaunchedFeatures = FeatureService(
            api: mocks.nuxieApi,
            identity: mocks.identityService,
            profile: mocks.profileService,
            dateProvider: mocks.dateProvider,
            featureInfo: FeatureInfo(),
            cacheTTL: configuration.featureCacheTTL,
            localPurchaseAccessStore: accessStore
        )
        let accessBeforeObserverStartup = await relaunchedFeatures.getCached(
            featureId: grant.featureId,
            entityId: nil
        )
        XCTAssertEqual(accessBeforeObserverStartup?.allowed, false)
        let relaunchedObserver = TransactionObserver(
            api: UnavailablePurchaseSyncAPI(),
            features: relaunchedFeatures,
            identity: mocks.identityService,
            settings: NuxieRuntimeSettings(configuration: configuration),
            eventSink: TransactionEvidenceEventSink(),
            transactionServiceProvider: { fatalError("unused in this test") },
            evidenceStore: evidenceStore,
            localAccessStore: accessStore,
            activeStoreOriginalTransactionIDs: { [] }
        )

        await relaunchedObserver.retryStoredEvidence()

        let relaunchedAccess = await relaunchedFeatures.getCached(
            featureId: grant.featureId,
            entityId: nil
        )
        XCTAssertEqual(relaunchedAccess?.allowed, false)
    }

    func testIdentityRetryReconcilesBeforeRehydratingExpiredAccess() async {
        let mocks = MockFactory.shared
        mocks.identityService.setDistinctId("customer-b")
        let configuration = NuxieConfiguration(apiKey: "isolated")
        let accessStore = InMemoryLocalPurchaseAccessStore()
        let access = StoredLocalPurchaseAccess(
            transactionId: "expired-identity-transaction",
            originalTransactionId: "expired-identity-original",
            productId: "expired-identity-product",
            distinctId: "customer-a",
            grants: [
                StoredLocalEntitlementGrant(
                    featureId: "expired-identity-feature",
                    featureExternalId: nil,
                    allowanceType: "boolean",
                    allowance: nil
                )
            ],
            state: .active
        )
        XCTAssertTrue(accessStore.save([access.transactionId: access]))
        let features = FeatureService(
            api: mocks.nuxieApi,
            identity: mocks.identityService,
            profile: mocks.profileService,
            dateProvider: mocks.dateProvider,
            featureInfo: FeatureInfo(),
            cacheTTL: configuration.featureCacheTTL
        )
        let observer = TransactionObserver(
            api: SuccessfulPurchaseSyncAPI(),
            features: features,
            identity: mocks.identityService,
            settings: NuxieRuntimeSettings(configuration: configuration),
            eventSink: TransactionEvidenceEventSink(),
            transactionServiceProvider: { fatalError("unused in this test") },
            evidenceStore: InMemoryTransactionEvidenceStore(),
            localAccessStore: accessStore,
            activeStoreOriginalTransactionIDs: { [] }
        )

        mocks.identityService.setDistinctId("customer-a")
        await observer.retryStoredEvidence()

        XCTAssertEqual(
            accessStore.load()[access.transactionId]?.state,
            .revoked
        )
        let cached = await features.getCached(
            featureId: "expired-identity-feature",
            entityId: nil
        )
        XCTAssertEqual(cached?.allowed, false)
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
            cacheTTL: configuration.featureCacheTTL
        )
        let evidence = StoredTransactionEvidence(
            transactionJws: "signed-jws",
            transactionId: "transaction-customer-a",
            originalTransactionId: "original-customer-a",
            productId: "store-product",
            distinctId: "customer-a",
            recordedAt: Date(),
            localEntitlementGrants: [],
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
            evidenceStore: evidenceStore,
            localAccessStore: InMemoryLocalPurchaseAccessStore()
        )

        await observer.retryStoredEvidence()

        XCTAssertFalse(eventSink.names.contains(SystemEventNames.purchaseSynced))
        XCTAssertTrue(evidenceStore.load().isEmpty)
    }

    func testStoredRevocationAppliesServerStateAndRetiresFinishedEvidence() async {
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
            cacheTTL: configuration.featureCacheTTL
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
            localEntitlementGrants: [],
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
        XCTAssertNil(evidenceStore.load()[evidence.transactionId])
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
        XCTAssertTrue(evidenceStore.load()[evidence.transactionId]?.finishRequired == true)
        await observer.markTransactionFinished(transactionId: evidence.transactionId)
        XCTAssertNil(evidenceStore.load()[evidence.transactionId])

        // Model the direct purchase callback persisting after the observer has
        // already completed the same transaction from Transaction.updates.
        let lateRecord = await observer.recordVerifiedPurchase(
            evidence: evidence,
            product: product,
            distinctId: "customer-1",
            finishRequired: true
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
        XCTAssertTrue(evidenceStore.load()[evidence.transactionId]?.finishRequired == true)
    }
}
