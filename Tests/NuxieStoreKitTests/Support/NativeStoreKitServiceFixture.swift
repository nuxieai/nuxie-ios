import Foundation
import StoreKit
@testable import Nuxie
@testable import NuxieTestSupport

final class NativeStoreKitServiceFixture: @unchecked Sendable {
    static let customerId = "storekit-test-customer"

    let settings: NuxieRuntimeSettings
    let identity: MockIdentityService
    let dateProvider: MockDateProvider
    let directObserver: MockTransactionObserver
    let ownershipStore: InMemoryPurchaseAccountOwnershipStore
    let scope: PurchaseStorageScope
    let service: TransactionService

    init(
        mode: NuxieConfiguration.PurchaseHandlingMode,
        delegate: NuxiePurchaseDelegate? = nil
    ) {
        let configuration = NuxieConfiguration(apiKey: "storekit-test")
        configuration.purchaseHandlingMode = mode
        configuration.purchaseDelegate = delegate

        let settings = NuxieRuntimeSettings(configuration: configuration)
        let identity = MockIdentityService()
        identity.setDistinctId(Self.customerId)
        let dateProvider = MockDateProvider()
        let directObserver = MockTransactionObserver()
        let ownershipStore = InMemoryPurchaseAccountOwnershipStore()
        let scope = PurchaseStorageScope(
            appIdentifierHash: "storekit-test-app",
            environment: "qualification",
            storeEnvironment: .appStore
        )

        self.settings = settings
        self.identity = identity
        self.dateProvider = dateProvider
        self.directObserver = directObserver
        self.ownershipStore = ownershipStore
        self.scope = scope
        service = TransactionService(
            productService: MockProductService(),
            transactionObserver: directObserver,
            pendingPurchaseStore: InMemoryPendingPurchaseStore(),
            accountOwnershipStore: ownershipStore,
            dateProvider: dateProvider,
            settings: settings,
            eventSink: StoreKitRecordingEventSink(),
            purchaseStorageScope: scope,
            identityService: identity,
            nativePurchaseAdapter: NativeStoreKitPurchaseAdapter()
        )
    }

    func preparedProduct(
        from store: NativeStoreKitTestHarness,
        id: NativeStoreKitTestProduct = .consumable
    ) async throws -> StoreProduct {
        var product = try await store.product(id: id)
        product.purchaseContext = PurchaseCommercialContext(
            release: AuthenticatedExperienceReleaseID(
                identity: ExperienceReleaseIdentity(
                    appId: "storekit-test-app",
                    environment: "qualification",
                    experienceId: "storekit-test-experience",
                    experienceVersionId: "storekit-test-version",
                    buildId: "storekit-test-build",
                    versionNumber: 1,
                    releaseCreatedAt: "2026-08-23T00:00:00Z",
                    releaseSequence: 1
                ),
                descriptorSHA256: String(repeating: "a", count: 64)
            ),
            placementId: product.placementId,
            productId: product.productId,
            storeProductId: product.storeProductId,
            displayPrice: product.price
        )
        return product
    }

    func makeRecoveryObserver(api: StoreKitRecordingPurchaseAPI) -> TransactionObserver {
        let service = service
        return TransactionObserver(
            api: api,
            features: StoreKitNoopFeatureService(),
            identity: identity,
            settings: settings,
            eventSink: StoreKitRecordingEventSink(),
            transactionServiceProvider: { service },
            evidenceStore: InMemoryTransactionEvidenceStore(),
            purchaseStorageScope: scope,
            dateProvider: dateProvider,
            activeStoreOriginalTransactionIDs: { [] }
        )
    }
}

actor StoreKitRecordingPurchaseAPI: PurchaseSynchronizing {
    private var transactionJWSs: [String] = []

    func syncTransaction(
        transactionJwt: String,
        distinctId: String
    ) async throws -> PurchaseResponse {
        _ = distinctId
        transactionJWSs.append(transactionJwt)
        return PurchaseResponse(
            success: true,
            customerId: NativeStoreKitServiceFixture.customerId,
            features: [],
            error: nil
        )
    }

    func callCount() -> Int { transactionJWSs.count }
}

actor StoreKitNoopFeatureService: FeatureServiceProtocol {
    func getCached(featureId: String, entityId: String?) async -> FeatureAccess? { nil }
    func getAllCached() async -> [String: FeatureAccess] { [:] }
    func check(
        featureId: String,
        requiredBalance: Double?,
        entityId: String?
    ) async throws -> FeatureCheckResult {
        throw NuxieNetworkError.invalidResponse
    }
    func checkWithCache(
        featureId: String,
        requiredBalance: Double?,
        entityId: String?,
        forceRefresh: Bool
    ) async throws -> FeatureAccess {
        .notFound
    }
    func clearCache() async {}
    func handleUserChange(from oldDistinctId: String, to newDistinctId: String) async {}
    func syncFeatureInfo() async {}
    func updateFromPurchase(_ features: [PurchaseFeature], distinctId: String) async {}
}

final class StoreKitRecordingEventSink: SystemEventSink, @unchecked Sendable {
    func emit(_ name: String, properties: [String: Any]?) {}
}

final class StoreKitProviderPurchaseDelegate: NuxiePurchaseDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedTransactionId: String?
    private var calls = 0

    var purchaseCallCount: Int { lock.withLock { calls } }
    var transactionId: String? { lock.withLock { recordedTransactionId } }

    func purchase(product: StoreProduct) async -> PurchaseResult {
        lock.withLock { calls += 1 }
        guard let rawProduct = product.rawProduct else {
            return .failed(StoreKitError.productNotFound(product.storeProductId))
        }
        do {
            switch try await rawProduct.purchase(options: product.storeKitPurchaseOptions) {
            case .success(.verified(let transaction)):
                lock.withLock { recordedTransactionId = String(transaction.id) }
                // The provider owns this transaction and deliberately does not
                // transfer signed evidence or finishing authority to Nuxie.
                return .purchased
            case .success(.unverified(_, let error)):
                return .failed(error)
            case .userCancelled:
                return .cancelled
            case .pending:
                return .pending
            @unknown default:
                return .failed(StoreKitError.unknown(underlying: nil))
            }
        } catch {
            return .failed(error)
        }
    }

    func restorePurchases() async -> RestoreResult { .noPurchases }
}
