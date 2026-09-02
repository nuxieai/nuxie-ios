import XCTest
@_spi(Testing) @testable import Nuxie
@testable import NuxieTestSupport

final class InternalServiceDependencyTests: XCTestCase {
    private final class EventSink: SystemEventSink, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [(String, [String: Any]?)] = []

        func emit(_ name: String, properties: [String: Any]?) {
            lock.lock()
            storage.append((name, properties))
            lock.unlock()
        }

        var names: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storage.map(\.0)
        }
    }

    @MainActor
    func testRuntimeControllerUsesInjectedEventSinkWithoutSDKSetup() {
        let sink = EventSink()
        let controller = MockExperienceViewController(systemEventSink: sink)

        controller.emitSystemEvent("runtime_event", properties: ["source": "test"])

        XCTAssertEqual(sink.names, ["runtime_event"])
    }

    func testPurchaseServicesConstructFromNarrowCapabilitiesWithoutSDKSetup() async {
        let mocks = MockFactory.shared
        let configuration = NuxieConfiguration(apiKey: "isolated")
        let settings = NuxieRuntimeSettings(configuration: configuration)
        let sink = EventSink()
        let serviceBox = LateBound<TransactionService>()
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
            eventSink: sink,
            transactionServiceProvider: { serviceBox.get() }
        )
        let nativePurchaseAdapter = MockNativeStoreKitPurchaseAdapter()
        nativePurchaseAdapter.configureCancelled()
        let service = TransactionService(
            productService: mocks.productService,
            transactionObserver: observer,
            pendingPurchaseStore: InMemoryPendingPurchaseStore(),
            dateProvider: mocks.dateProvider,
            settings: settings,
            eventSink: sink,
            nativePurchaseAdapter: nativePurchaseAdapter
        )
        serviceBox.set(service)

        do {
            let appStoreProduct = MockStoreProduct(
                id: "product",
                displayName: "Product",
                price: 1,
                displayPrice: "$1"
            )
            var product = StoreProduct(
                productId: "product",
                placementId: "placement",
                name: appStoreProduct.displayName,
                price: appStoreProduct.displayPrice,
                period: nil,
                appStoreProduct: appStoreProduct
            )
            product.purchaseContext = PurchaseCommercialContext(
                release: AuthenticatedExperienceReleaseID(
                    identity: ExperienceReleaseIdentity(
                        appId: "app-1",
                        environment: "live",
                        experienceId: "experience-1",
                        experienceVersionId: "version-1",
                        buildId: "build-1",
                        versionNumber: 1,
                        releaseCreatedAt: "2026-08-19T00:00:00Z",
                        releaseSequence: 1
                    ),
                    descriptorSHA256: String(repeating: "a", count: 64)
                ),
                placementId: "placement",
                productId: "product",
                storeProductId: appStoreProduct.id
            )
            _ = try await service.purchase(product)
            XCTFail("purchase should surface the native adapter outcome")
        } catch StoreKitError.purchaseCancelled {
            XCTAssertTrue(sink.names.isEmpty)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testTransactionObserverReturnsOnlyActiveCurrentEntitlementProductIds() async {
        let mocks = MockFactory.shared
        let settings = NuxieRuntimeSettings(
            configuration: NuxieConfiguration(apiKey: "entitlement-snapshot")
        )
        let features = FeatureService(
            api: mocks.nuxieApi,
            identity: mocks.identityService,
            profile: mocks.profileService,
            dateProvider: mocks.dateProvider,
            featureInfo: FeatureInfo(),
            cacheTTL: NuxieInternalConfiguration().featureCacheTTL
        )
        let currentEntitlements = [
            recoveryItem(productId: "active"),
            recoveryItem(productId: "revoked", isRevoked: true),
            recoveryItem(productId: "upgraded", isUpgraded: true),
            recoveryItem(productId: "active"),
        ]
        let observer = TransactionObserver(
            api: mocks.nuxieApi,
            features: features,
            identity: mocks.identityService,
            settings: settings,
            eventSink: EventSink(),
            transactionServiceProvider: { fatalError("unused in this test") },
            recoverySources: StoreTransactionRecoverySources(
                unfinished: { [] },
                currentEntitlements: { currentEntitlements }
            )
        )

        let productIds = await observer.currentEntitledStoreProductIds()

        XCTAssertEqual(productIds, ["active"])
    }

    func testCoreWiresEachProductAuthorityAdmissionToOneLifecycleGatedRecovery() async throws {
        let configuration = NuxieConfiguration(apiKey: "authority-admission")
        let observer = MockTransactionObserver()
        var overrides = NuxieCoreOverrides()
        overrides.transactionObserver = observer
        let core = NuxieCore(
            configuration: configuration,
            overrides: overrides
        )

        _ = try await core.experiences.replaceReleaseProfile(nil)
        for _ in 0..<100 where await observer.profileReadyRecoveryCalls == 0 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let firstAdmissionCalls = await observer.profileReadyRecoveryCalls
        XCTAssertEqual(firstAdmissionCalls, 1)

        _ = try await core.experiences.replaceReleaseProfile(nil)
        try await Task.sleep(nanoseconds: 25_000_000)
        let repeatedAdmissionCalls = await observer.profileReadyRecoveryCalls
        XCTAssertEqual(repeatedAdmissionCalls, 1)

        await observer.stopListening()
        await core.experiences.clearCache()
        _ = try await core.experiences.replaceReleaseProfile(nil)
        try await Task.sleep(nanoseconds: 25_000_000)
        let postStopCalls = await observer.profileReadyRecoveryCalls
        XCTAssertEqual(postStopCalls, 1)
    }

    func testCoreBindsTransactionServiceBeforeDeliveringPendingAuthorityAdmission() async throws {
        let configuration = NuxieConfiguration(apiKey: "eager-authority-admission")
        let customStoragePath = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        configuration.testingOverrides.customStoragePath = customStoragePath
        defer { try? FileManager.default.removeItem(at: customStoragePath) }
        let identity = MockIdentityService()
        identity.setDistinctId("customer-a")
        let source = RecoveryTransactionSourceProbe()
        let finishes = FinishCounter()
        await source.setUnfinished([StoreTransactionRecoveryItem(
            update: VerifiedStoreTransactionUpdate(
                transactionId: "eager-authority-transaction",
                originalTransactionId: "eager-authority-original",
                productId: "eager-authority-product",
                appAccountToken: nil,
                isRevoked: false,
                isUpgraded: false,
                finish: { await finishes.increment() }
            ),
            jwsRepresentation: "eager-authority-jws"
        )])
        let sink = EventSink()
        var overrides = NuxieCoreOverrides()
        overrides.api = MockNuxieApi()
        overrides.identity = identity
        let experiences = MockExperienceService()
        experiences.configureEagerProductAuthorityAdmission(.readyNoMatch)
        overrides.experiences = experiences
        overrides.systemEvents = sink
        overrides.transactionRecoverySources = StoreTransactionRecoverySources(
            unfinished: { await source.unfinishedItems() },
            currentEntitlements: { await source.currentEntitlementItems() }
        )

        let core = NuxieCore(configuration: configuration, overrides: overrides)
        // Finishing the unfinished item happens before the recovery pump scans
        // current entitlements. Waiting only for `finish` races the very next
        // actor hop and made this assertion intermittently observe zero on CI.
        for _ in 0..<100 {
            let reads = await source.readCounts()
            let finishCount = await finishes.count()
            let syncedCount = sink.names.filter {
                $0 == SystemEventNames.purchaseSynced
            }.count
            if reads.unfinished == 1,
               reads.currentEntitlements == 1,
               finishCount == 1,
               syncedCount == 1 {
                break
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        let reads = await source.readCounts()
        XCTAssertEqual(reads.unfinished, 1)
        XCTAssertEqual(reads.currentEntitlements, 1)
        let finishCount = await finishes.count()
        XCTAssertEqual(finishCount, 1)
        XCTAssertEqual(sink.names.filter { $0 == SystemEventNames.purchaseSynced }.count, 1)
        await core.transactionObserver.stopListening()
    }

    private func recoveryItem(
        productId: String,
        isRevoked: Bool = false,
        isUpgraded: Bool = false
    ) -> StoreTransactionRecoveryItem {
        StoreTransactionRecoveryItem(
            update: VerifiedStoreTransactionUpdate(
                transactionId: "transaction-\(productId)",
                originalTransactionId: "original-\(productId)",
                productId: productId,
                appAccountToken: nil,
                isRevoked: isRevoked,
                isUpgraded: isUpgraded,
                finish: {}
            ),
            jwsRepresentation: "jws-\(productId)"
        )
    }
}
