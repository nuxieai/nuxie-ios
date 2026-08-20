import Foundation
import StoreKit
import Quick
import Nimble
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

private final class RecordingPurchaseExperienceViewController: MockExperienceViewController {
    private(set) var emittedSystemEvents: [(name: String, properties: [String: Any])] = []
    private(set) var requestedDismissalReasons: [CloseReason] = []

    override func emitSystemEvent(_ name: String, properties: [String: Any]) {
        emittedSystemEvents.append((name, properties))
    }

    override func performDismiss(reason: CloseReason = .userDismissed) {
        requestedDismissalReasons.append(reason)
    }
}

private final class RecordingTransactionEventSink: SystemEventSink, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(name: String, properties: [String: Any]?)] = []
    private var routedCaptures = 0
    private var captureOnlyCaptures = 0
    private var capturedEventIds: [String] = []

    func emit(_ name: String, properties: [String: Any]?) {
        lock.lock()
        storage.append((name, properties))
        lock.unlock()
    }

    func capture(
        _ name: String,
        properties: [String: Any]?,
        eventId: String,
        distinctId: String
    ) async -> Bool {
        _ = distinctId
        lock.withLock {
            routedCaptures += 1
            capturedEventIds.append(eventId)
            storage.append((name, properties))
        }
        return true
    }

    func captureOnly(
        _ name: String,
        properties: [String: Any]?,
        eventId: String,
        distinctId: String
    ) async -> Bool {
        _ = eventId
        _ = distinctId
        lock.withLock {
            captureOnlyCaptures += 1
            storage.append((name, properties))
        }
        return true
    }

    var events: [(name: String, properties: [String: Any]?)] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var routedCaptureCount: Int { lock.withLock { routedCaptures } }
    var captureOnlyCount: Int { lock.withLock { captureOnlyCaptures } }
    var routedEventIds: [String] { lock.withLock { capturedEventIds } }
}

private actor RecordingIntroEligibilityTokenProvider:
    IntroEligibilityTokenProviding
{
    private var token: String?
    private var recorded: [IntroEligibilityTokenRequest] = []

    init(token: String? = nil) { self.token = token }

    func setToken(_ token: String?) { self.token = token }

    func token(for request: IntroEligibilityTokenRequest) async throws -> String? {
        recorded.append(request)
        return token
    }

    func requests() -> [IntroEligibilityTokenRequest] { recorded }
}

private actor MockNuxieTestStore: NuxieTestStorePurchasing {
    var purchaseCalls = 0
    var restoreCalls = 0
    var purchaseDistinctIds: [String] = []
    var restoreDistinctIds: [String] = []
    var purchaseResponse = NuxieTestStorePurchaseResponse(
        result: .purchased(nil),
        transactionId: "test-transaction"
    )
    var restoreResponse = NuxieTestStoreRestoreResponse(result: .noPurchases)

    func setRestoreResponse(_ response: NuxieTestStoreRestoreResponse) {
        restoreResponse = response
    }

    func purchase(
        product _: StoreProduct,
        distinctId: String
    ) async -> NuxieTestStorePurchaseResponse {
        purchaseCalls += 1
        purchaseDistinctIds.append(distinctId)
        return purchaseResponse
    }

    func restorePurchases(distinctId: String) async -> NuxieTestStoreRestoreResponse {
        restoreCalls += 1
        restoreDistinctIds.append(distinctId)
        return restoreResponse
    }
}

private actor RecordingFeatureService: FeatureServiceProtocol {
    private(set) var localPurchases: [(
        grants: [StoreProduct.LocalEntitlementGrant],
        transactionId: String
    )] = []

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
    func updateFromPurchase(
        _ features: [PurchaseFeature],
        distinctId: String
    ) async {}

    func applyLocalPurchase(
        grants: [StoreProduct.LocalEntitlementGrant],
        transactionId: String
    ) async {
        localPurchases.append((grants, transactionId))
    }
}

private actor SuspendedNativePurchaseAdapter: NativeStoreKitPurchasing {
    private var product: StoreProduct?
    private var continuation: CheckedContinuation<NativePurchaseResult, Never>?

    func purchase(product: StoreProduct) async -> NativePurchaseResult {
        self.product = product
        return await withCheckedContinuation { continuation = $0 }
    }

    func restorePurchases() async -> NativeRestoreResult { .noPurchases }

    func receivedProduct() -> StoreProduct? { product }

    func complete(_ result: NativePurchaseResult) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}

private final class CheckoutRecoveryDeletionFailureStore:
    PendingPurchaseStoreProtocol,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var entries: [String: PendingPurchaseRecord] = [:]

    func load() -> [String: PendingPurchaseRecord] {
        lock.withLock { entries }
    }

    func save(_ entries: [String: PendingPurchaseRecord]) -> Bool {
        lock.withLock {
            guard !entries.isEmpty else { return false }
            self.entries = entries
            return true
        }
    }
}

private final class PendingTransitionFailureStore:
    PendingPurchaseStoreProtocol,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var entries: [String: PendingPurchaseRecord] = [:]

    func load() -> [String: PendingPurchaseRecord] {
        lock.withLock { entries }
    }

    func save(_ entries: [String: PendingPurchaseRecord]) -> Bool {
        lock.withLock {
            if entries.values.contains(where: { $0.state == .pending }) {
                return false
            }
            self.entries = entries
            return true
        }
    }
}

final class TransactionServiceTests: AsyncSpec {
    override class func spec() {
        describe("TransactionService") {
            var transactionService: TransactionService!
            var mocks: MockFactory!
            var mockPurchaseDelegate: MockPurchaseDelegate!
            var mockAppStoreProduct: MockStoreProduct!
            var mockProduct: StoreProduct!
            var mockNativePurchaseAdapter: MockNativeStoreKitPurchaseAdapter!
            var mockTransactionObserver: MockTransactionObserver!
            var pendingStorageURL: URL!
            var dateProvider: MockDateProvider!
            var configuration: NuxieConfiguration!
            var settings: NuxieRuntimeSettings!
            var eventSink: RecordingTransactionEventSink!
            var introTokenProvider: RecordingIntroEligibilityTokenProvider!
            var introOverrideHealth: IntroEligibilityOverrideHealth!
            var mockTestStore: MockNuxieTestStore!
            var featureService: RecordingFeatureService!
            var identityService: MockIdentityService!
            var purchaseStorageScope: PurchaseStorageScope!

            /// A TransactionService over the durable pending-purchase store in
            /// `pendingStorageURL` — building a second one models a process
            /// relaunch over the same storage.
            func makeTransactionService() -> TransactionService {
                let activeSettings = settings!
                let activeEventSink = eventSink!
                return TransactionService(
                    productService: mocks.productService,
                    transactionObserver: mockTransactionObserver,
                    pendingPurchaseStore: PendingPurchaseStore(
                        customStoragePath: pendingStorageURL,
                        scope: purchaseStorageScope
                    ),
                    dateProvider: dateProvider,
                    settings: activeSettings,
                    eventSink: activeEventSink,
                    purchaseStorageScope: purchaseStorageScope,
                    identityService: identityService,
                    introEligibilityTokenProvider: introTokenProvider,
                    introEligibilityOverrideHealth: introOverrideHealth,
                    nativePurchaseAdapter: mockNativePurchaseAdapter,
                    featureService: featureService,
                    testStore: mockTestStore
                )
            }

            beforeEach {
                mocks = MockFactory.shared

                // Keep StoreKit's real transaction observer out of unit tests
                mockTransactionObserver = MockTransactionObserver()

                // Create mock purchase delegate
                mockPurchaseDelegate = MockPurchaseDelegate()
                mockNativePurchaseAdapter = MockNativeStoreKitPurchaseAdapter()
                mockTestStore = nil

                // Create a test configuration with the purchase delegate
                configuration = NuxieConfiguration(apiKey: "test-api-key")
                configuration.purchaseDelegate = mockPurchaseDelegate
                settings = NuxieRuntimeSettings(configuration: configuration)
                eventSink = RecordingTransactionEventSink()
                introTokenProvider = RecordingIntroEligibilityTokenProvider()
                introOverrideHealth = IntroEligibilityOverrideHealth()
                featureService = RecordingFeatureService()
                identityService = MockIdentityService()
                purchaseStorageScope = PurchaseStorageScope(
                    appIdentifierHash: "test-app-key",
                    environment: "production",
                    storeEnvironment: .appStore
                )

                pendingStorageURL = URL(
                    fileURLWithPath: NSTemporaryDirectory(), isDirectory: true
                ).appendingPathComponent("nuxie-txn-\(UUID().uuidString)", isDirectory: true)
                dateProvider = MockDateProvider()

                // Create transaction service with explicit collaborators
                transactionService = makeTransactionService()

                // Create mock product
                mockAppStoreProduct = MockStoreProduct(
                    id: "com.test.product",
                    displayName: "Test Product",
                    description: "Test Description",
                    price: 9.99,
                    displayPrice: "$9.99"
                )
                mockProduct = StoreProduct(
                    productId: "product",
                    storeProductId: mockAppStoreProduct.id,
                    placementId: "placement",
                    name: mockAppStoreProduct.displayName,
                    description: mockAppStoreProduct.description,
                    price: mockAppStoreProduct.displayPrice,
                    period: nil,
                    productType: mockAppStoreProduct.productType,
                    appStoreProduct: mockAppStoreProduct
                )
                mockProduct.purchaseContext = PurchaseCommercialContext(
                    release: AuthenticatedExperienceReleaseID(
                        identity: ExperienceReleaseIdentity(
                            appId: "app-1",
                            environment: "live",
                            experienceId: "experience-1",
                            experienceVersionId: "version-1",
                            buildId: "build-1",
                            versionNumber: 1,
                            publishedAt: "2026-08-19T00:00:00Z",
                            publishedAtSeq: 1
                        ),
                        descriptorSHA256: String(repeating: "a", count: 64)
                    ),
                    placementId: "placement",
                    productId: "product",
                    storeProductId: mockAppStoreProduct.id,
                    displayPrice: mockAppStoreProduct.displayPrice,
                    price: NSDecimalNumber(decimal: mockAppStoreProduct.price).doubleValue
                )
            }

            afterEach {
                // Clean up
                mockPurchaseDelegate.reset()
                if let pendingStorageURL {
                    try? FileManager.default.removeItem(at: pendingStorageURL)
                }
            }
            
            describe("purchase") {
                it("persists exact protected recovery context before native StoreKit opens") {
                    settings.setPurchaseDelegate(nil)
                    mockProduct.localEntitlementGrants = [
                        StoreProduct.LocalEntitlementGrant(
                            featureId: "feature_credits",
                            featureExternalId: "credits",
                            purchaseUsageFeatureIds: ["api_calls", "feature_api_calls"],
                            allowanceType: "credits",
                            allowance: 10
                        )
                    ]
                    let suspended = SuspendedNativePurchaseAdapter()
                    transactionService = TransactionService(
                        productService: mocks.productService,
                        transactionObserver: mockTransactionObserver,
                        pendingPurchaseStore: PendingPurchaseStore(
                            customStoragePath: pendingStorageURL,
                            scope: purchaseStorageScope
                        ),
                        dateProvider: dateProvider,
                        settings: settings,
                        eventSink: eventSink,
                        purchaseStorageScope: purchaseStorageScope,
                        identityService: identityService,
                        nativePurchaseAdapter: suspended,
                        featureService: featureService
                    )

                    let purchase = Task {
                        try await transactionService.purchase(mockProduct)
                    }
                    var receivedProduct: StoreProduct?
                    for _ in 0..<100 where receivedProduct == nil {
                        receivedProduct = await suspended.receivedProduct()
                        if receivedProduct == nil {
                            try await Task.sleep(nanoseconds: 10_000_000)
                        }
                    }
                    expect(receivedProduct).toNot(beNil())

                    let entries = PendingPurchaseStore(
                        customStoragePath: pendingStorageURL,
                        scope: purchaseStorageScope
                    ).load()
                    let record = entries.values.first
                    expect(record?.scope) == purchaseStorageScope
                    expect(record?.distinctId) == "test-user"
                    expect(record?.commercialContext.placementId) == "placement"
                    expect(record?.commercialContext.productId) == "product"
                    expect(record?.commercialContext.release.identity.experienceId) ==
                        "experience-1"
                    expect(record?.productFeatureIds) == [
                        "api_calls", "credits", "feature_api_calls", "feature_credits",
                    ]
                    // The selector metadata is retained even though fixed
                    // balances are deliberately not projected locally.
                    expect(record?.localEntitlementGrants).to(beEmpty())
                    expect(record?.appAccountToken) == purchaseStorageScope.appAccountToken(
                        distinctId: "test-user"
                    )
                    expect(receivedProduct?.nativeCheckoutAppAccountToken) == record?.appAccountToken
                    let isActive = await transactionService.isActiveCheckout(
                        appAccountToken: record?.appAccountToken,
                        productId: mockProduct.storeProductId,
                        distinctId: "test-user"
                    )
                    expect(isActive) == true

                    await suspended.complete(.cancelled)
                    await expect { try await purchase.value }.to(
                        throwError(StoreKitError.purchaseCancelled)
                    )
                    expect(PendingPurchaseStore(
                        customStoragePath: pendingStorageURL,
                        scope: purchaseStorageScope
                    ).load()).to(beEmpty())
                    let remainsActive = await transactionService.isActiveCheckout(
                        appAccountToken: record?.appAccountToken,
                        productId: mockProduct.storeProductId,
                        distinctId: "test-user"
                    )
                    expect(remainsActive) == false
                }

                it("uses the isolated Test Store without invoking StoreKit or the delegate") {
                    mockTestStore = MockNuxieTestStore()
                    transactionService = makeTransactionService()
                    settings.setPurchaseDelegate(nil)

                    await expect {
                        try await transactionService.purchase(mockProduct)
                    }.toNot(throwError())

                    let purchaseCalls = await mockTestStore.purchaseCalls
                    expect(purchaseCalls) == 1
                    let purchaseDistinctIds = await mockTestStore.purchaseDistinctIds
                    expect(purchaseDistinctIds) == ["test-user"]
                    expect(mockNativePurchaseAdapter.purchasedProducts).to(beEmpty())
                    expect(mockPurchaseDelegate.purchaseCalled).to(beFalse())
                    expect(eventSink.routedCaptureCount) == 1
                    expect(eventSink.routedEventIds) == [
                        "purchase-completed:test-fixture:test:appStore:test-transaction",
                    ]
                    let completion = eventSink.events.first(where: {
                        $0.name == SystemEventNames.purchaseCompleted
                    })?.properties
                    expect(completion?["test_store"] as? Bool) == true
                    expect(completion?["placement_id"] as? String) == "placement"
                    expect(completion?["product_id"] as? String) == "product"
                    expect(completion?["store_product_id"] as? String)
                        == "com.test.product"
                    expect(completion?["experience_id"] as? String)
                        == "experience-1"
                    expect(completion?["source"] as? String) == "purchase"
                }

                context("with purchase delegate configured") {
                    it("should successfully complete a purchase") {
                        mockPurchaseDelegate.configureForSuccess()
                        
                        await expect {
                            try await transactionService.purchase(mockProduct)
                        }.toNot(throwError())
                        
                        expect(mockPurchaseDelegate.purchaseCalled).to(beTrue())
                        expect(mockPurchaseDelegate.lastPurchasedProduct?.productId).to(equal(mockProduct.productId))
                        expect(mockPurchaseDelegate.lastPurchasedProduct?.placementId) == "placement"
                        expect(mockPurchaseDelegate.lastPurchasedProduct?.storeProductId) == "com.test.product"
                        expect(mockPurchaseDelegate.lastPurchasedProduct?.productType) == .nonConsumable
                        expect(mockPurchaseDelegate.lastPurchasedProduct?.appStoreProduct?.id) == "com.test.product"
                        expect(eventSink.events.map(\.name).filter {
                            $0 == SystemEventNames.purchaseCompleted
                        }.count) == 1
                    }

                    it("passes the exact retained native product object to the delegate") {
                        let native = ReferenceMockStoreProduct(MockStoreProduct(
                            id: "com.test.reference-delegate",
                            displayName: "Reference",
                            price: 2.99,
                            displayPrice: "$2.99"
                        ))
                        var shown = try await StoreProductResolver().resolve(
                            experienceVersionId: "version-reference-delegate",
                            authorization: nil,
                            productId: "reference-delegate",
                            placementId: "paywall:reference-delegate",
                            productType: .nonConsumable,
                            appStoreProduct: native,
                            options: .default
                        )
                        shown.purchaseContext = PurchaseCommercialContext(
                            release: mockProduct.purchaseContext!.release,
                            placementId: shown.placementId,
                            productId: shown.productId,
                            storeProductId: shown.storeProductId
                        )
                        mockPurchaseDelegate.configureForSuccess()

                        _ = try await transactionService.purchase(shown)

                        guard let purchasedNative = mockPurchaseDelegate
                            .lastPurchasedProduct?.appStoreProduct
                            as? ReferenceMockStoreProduct else {
                            fail("Expected the delegate to retain the reference-backed product")
                            return
                        }
                        expect(purchasedNative === native) == true
                    }

                    it("does not grant Nuxie Feature Access for an unmapped provider purchase") {
                        mockPurchaseDelegate.configureForSuccess()

                        await expect {
                            try await transactionService.purchase(mockProduct)
                        }.toNot(throwError())

                        let localPurchases = await featureService.localPurchases
                        expect(localPurchases).to(beEmpty())
                    }

                    it("projects reviewed provider Product entitlements locally after enablement") {
                        mockProduct.localEntitlementGrants = [
                            StoreProduct.LocalEntitlementGrant(
                                featureId: "feature_premium",
                                featureExternalId: "premium",
                                allowanceType: nil,
                                allowance: nil
                            )
                        ]
                        mockPurchaseDelegate.configureForSuccess()

                        await expect {
                            try await transactionService.purchase(mockProduct)
                        }.toNot(throwError())

                        let localPurchases = await featureService.localPurchases
                        expect(localPurchases.count) == 1
                        expect(localPurchases.first?.grants.map(\.featureId)) == [
                            "feature_premium"
                        ]
                        expect(localPurchases.first?.transactionId) ==
                            "nuxie-provider-com.test.product"
                    }

                    it("does not attribute a suspended checkout to a new customer") {
                        mockProduct.localEntitlementGrants = [
                            StoreProduct.LocalEntitlementGrant(
                                featureId: "feature_premium",
                                featureExternalId: "premium",
                                allowanceType: nil,
                                allowance: nil
                            )
                        ]
                        mockPurchaseDelegate.simulatedDelay = 0.2
                        mockPurchaseDelegate.configureForSuccess()

                        let purchase = Task {
                            try await transactionService.purchase(mockProduct)
                        }
                        await expect(mockPurchaseDelegate.purchaseCalled).toEventually(
                            beTrue(),
                            timeout: .seconds(1)
                        )
                        identityService.setDistinctId("customer-b")

                        _ = try await purchase.value

                        let localPurchases = await featureService.localPurchases
                        expect(localPurchases).to(beEmpty())
                        expect(eventSink.events.map(\.name)).toNot(
                            contain(SystemEventNames.purchaseCompleted)
                        )
                    }

                    it("keeps provider fixed quotas and credits server-authoritative") {
                        mockProduct.localEntitlementGrants = [
                            StoreProduct.LocalEntitlementGrant(
                                featureId: "feature_exports",
                                featureExternalId: "exports",
                                allowanceType: "fixed",
                                allowance: 10
                            ),
                            StoreProduct.LocalEntitlementGrant(
                                featureId: "feature_credits",
                                featureExternalId: "credits",
                                allowanceType: "credits",
                                allowance: 10
                            )
                        ]
                        mockPurchaseDelegate.configureForSuccess()

                        await expect {
                            try await transactionService.purchase(mockProduct)
                        }.toNot(throwError())

                        let localPurchases = await featureService.localPurchases
                        expect(localPurchases).to(beEmpty())
                    }

                    it("mints a fresh eligibility token before invoking the delegate") {
                        let token = "e30.e30.Y2hlY2tvdXQ"
                        await introTokenProvider.setToken(token)
                        mockPurchaseDelegate.configureForSuccess()
                        var overrideProduct = StoreProduct(
                            productId: mockProduct.productId,
                            storeProductId: mockProduct.storeProductId,
                            placementId: mockProduct.placementId,
                            name: mockProduct.name,
                            price: mockProduct.price,
                            period: mockProduct.period,
                            productType: mockProduct.productType,
                            billingPlan: .monthly,
                            introEligibilityTokenRequest: .init(
                                experienceVersionId: "version_123",
                                placementId: mockProduct.placementId,
                                authorization: .init(
                                    distinctId: "test-user",
                                    journeyId: "journey-1"
                                )
                            ),
                            appStoreProduct: mockAppStoreProduct
                        )
                        overrideProduct.purchaseContext = PurchaseCommercialContext(
                            release: mockProduct.purchaseContext!.release,
                            placementId: overrideProduct.placementId,
                            productId: overrideProduct.productId,
                            storeProductId: overrideProduct.storeProductId
                        )

                        await expect {
                            try await transactionService.purchase(overrideProduct)
                        }.toNot(throwError())

                        guard let purchased = mockPurchaseDelegate.lastPurchasedProduct else {
                            fail("Expected the delegate to receive the checkout product")
                            return
                        }
                        var expected = Set<Product.PurchaseOption>()
                        expected.insert(.appAccountToken(
                            purchaseStorageScope.appAccountToken(distinctId: "test-user")
                        ))
                        #if compiler(>=6.1)
                        expected.insert(
                            .introductoryOfferEligibility(compactJWS: token)
                        )
                        #endif
                        #if compiler(>=6.3.2)
                        if #available(iOS 26.4, macOS 26.4, tvOS 26.4, watchOS 26.4, *) {
                            expected.insert(.billingPlanType(.monthly))
                        }
                        #endif
                        expect(purchased.storeKitPurchaseOptions) == expected
                        let requests = await introTokenProvider.requests()
                        expect(requests) == [
                            .init(
                                experienceVersionId: "version_123",
                                placementId: mockProduct.placementId,
                                authorization: .init(
                                    distinctId: "test-user",
                                    journeyId: "journey-1"
                                )
                            ),
                        ]
                    }

                    it("rejects eligibility authority prepared for a previous customer") {
                        await introTokenProvider.setToken("e30.e30.c3RhbGU")
                        mockPurchaseDelegate.configureForSuccess()
                        let staleProduct = StoreProduct(
                            productId: mockProduct.productId,
                            storeProductId: mockProduct.storeProductId,
                            placementId: mockProduct.placementId,
                            name: mockProduct.name,
                            price: mockProduct.price,
                            period: mockProduct.period,
                            productType: mockProduct.productType,
                            introEligibilityTokenRequest: .init(
                                experienceVersionId: "version_123",
                                placementId: mockProduct.placementId,
                                authorization: .init(
                                    distinctId: "previous-customer",
                                    journeyId: "journey-1"
                                )
                            ),
                            appStoreProduct: mockAppStoreProduct
                        )

                        await expect {
                            try await transactionService.purchase(staleProduct)
                        }.to(throwError(StoreKitError.productTermsChanged(
                            staleProduct.storeProductId
                        )))

                        expect(mockPurchaseDelegate.purchaseCalled).to(beFalse())
                        let requests = await introTokenProvider.requests()
                        expect(requests).to(beEmpty())
                    }
                    
                    it("should throw purchaseCancelled when user cancels") {
                        mockPurchaseDelegate.configureForCancellation()
                        
                        await expect {
                            try await transactionService.purchase(mockProduct)
                        }.to(throwError(StoreKitError.purchaseCancelled))
                        
                        expect(mockPurchaseDelegate.purchaseCalled).to(beTrue())
                    }
                    
                    it("should throw purchaseFailed when purchase fails") {
                        let error = StoreKitError.networkUnavailable
                        mockPurchaseDelegate.configureForFailure(error: error)
                        
                        await expect {
                            try await transactionService.purchase(mockProduct)
                        }.to(throwError())
                        
                        expect(mockPurchaseDelegate.purchaseCalled).to(beTrue())
                        expect(eventSink.events.map(\.name).filter {
                            $0 == SystemEventNames.purchaseFailed
                        }.count) == 1
                    }

                    it("reloads when a custom delegate reports product unavailable") {
                        mockPurchaseDelegate.configureForFailure(
                            error: Product.PurchaseError.productUnavailable
                        )

                        await expect {
                            try await transactionService.purchase(mockProduct)
                        }.to(throwError(StoreKitError.productTermsChanged(
                            mockProduct.storeProductId
                        )))

                        expect(eventSink.events.map(\.name)).toNot(
                            contain(SystemEventNames.purchaseFailed)
                        )
                    }
                    
                    it("should throw purchasePending when purchase is pending") {
                        mockPurchaseDelegate.configureForPending()
                        
                        await expect {
                            try await transactionService.purchase(mockProduct)
                        }.to(throwError(StoreKitError.purchasePending))
                        
                        expect(mockPurchaseDelegate.purchaseCalled).to(beTrue())
                        // Provider-owned StoreKit paths still need a durable
                        // marker so a later Transaction.updates approval can
                        // resolve the paywall action.
                        await expect {
                            await transactionService.pendingPurchaseDistinctId(
                                productId: mockProduct.storeProductId
                            )
                        }.to(equal("test-user"))
                        let expectedToken = purchaseStorageScope.appAccountToken(
                            distinctId: "test-user"
                        )
                        expect(mockPurchaseDelegate.lastPurchasedProduct?
                            .nativeCheckoutAppAccountToken) == expectedToken
                        let pendingRecord = await transactionService.pendingPurchaseRecord(
                            productId: mockProduct.storeProductId,
                            distinctId: "test-user"
                        )
                        expect(pendingRecord?.appAccountToken) == expectedToken
                        expect(pendingRecord?.state) == .pending

                        let activeTransactionService = transactionService!
                        let observer = TransactionObserver(
                            api: mocks.nuxieApi,
                            features: featureService,
                            identity: identityService,
                            settings: settings,
                            eventSink: eventSink,
                            transactionServiceProvider: { activeTransactionService },
                            evidenceStore: InMemoryTransactionEvidenceStore(),
                            localAccessStore: InMemoryLocalPurchaseAccessStore(),
                            purchaseStorageScope: purchaseStorageScope,
                            dateProvider: dateProvider,
                            activeStoreOriginalTransactionIDs: { [] }
                        )
                        await observer.handleVerifiedTransaction(
                            VerifiedStoreTransactionUpdate(
                                transactionId: "delegate-pending-transaction",
                                originalTransactionId: "delegate-pending-original",
                                productId: mockProduct.storeProductId,
                                appAccountToken: expectedToken,
                                isRevoked: false,
                                isUpgraded: false,
                                finish: {}
                            ),
                            jwsRepresentation: "delegate-pending-jws",
                            source: .storeUpdates
                        )

                        let resolvedRecord = await transactionService.pendingPurchaseRecord(
                            productId: mockProduct.storeProductId,
                            distinctId: "test-user"
                        )
                        expect(resolvedRecord).to(beNil())
                        expect(eventSink.events.map(\.name).filter {
                            $0 == SystemEventNames.purchaseCompleted
                        }.count) == 1
                    }

                    it("should not emit purchase_failed from native purchase when purchase is pending") {
                        mockPurchaseDelegate.simulatedDelay = 0
                        mockPurchaseDelegate.configureForPending()
                        mocks.productService.mockProducts = [mockAppStoreProduct]
                        let pendingAppStoreProduct = mockAppStoreProduct!
                        var pendingProduct = StoreProduct(
                            productId: "product",
                            storeProductId: pendingAppStoreProduct.id,
                            placementId: "placement",
                            name: pendingAppStoreProduct.displayName,
                            price: pendingAppStoreProduct.displayPrice,
                            period: nil,
                            appStoreProduct: pendingAppStoreProduct
                        )
                        pendingProduct.purchaseContext = mockProduct.purchaseContext
                        let retainedPendingProduct = pendingProduct
                        let activeTransactionService = transactionService!
                        let activeEventSink = eventSink!
                        let controller = await MainActor.run {
                            RecordingPurchaseExperienceViewController(
                                mockExperienceVersionId: "flow-purchase-pending",
                                products: [retainedPendingProduct],
                                transactionService: activeTransactionService,
                                systemEventSink: activeEventSink
                            )
                        }

                        await MainActor.run {
                            controller.performPurchase(placementId: "placement")
                        }

                        await expect(mockPurchaseDelegate.purchaseCalled).toEventually(beTrue(), timeout: .seconds(2))
                        try? await Task.sleep(nanoseconds: 50_000_000)
                        let emittedNames = await MainActor.run {
                            controller.emittedSystemEvents.map(\.name)
                        }
                        expect(emittedNames).toNot(contain(SystemEventNames.purchaseFailed))
                        expect(emittedNames.filter {
                            $0 == SystemEventNames.purchasePending
                        }.count) == 1
                    }

                    it("routes cancellation to the Journey exactly once") {
                        mockPurchaseDelegate.simulatedDelay = 0
                        mockPurchaseDelegate.configureForCancellation()
                        let activeTransactionService = transactionService!
                        let activeEventSink = eventSink!
                        let retainedProduct = mockProduct!
                        let controller = await MainActor.run {
                            RecordingPurchaseExperienceViewController(
                                mockExperienceVersionId: "purchase-cancelled",
                                products: [retainedProduct],
                                transactionService: activeTransactionService,
                                systemEventSink: activeEventSink
                            )
                        }

                        await MainActor.run {
                            controller.performPurchase(placementId: retainedProduct.placementId)
                        }

                        await expect(mockPurchaseDelegate.purchaseCalled).toEventually(
                            beTrue(),
                            timeout: .seconds(2)
                        )
                        await expect {
                            await MainActor.run {
                                controller.emittedSystemEvents.filter {
                                    $0.name == SystemEventNames.purchaseCancelled
                                }.count
                            }
                        }.toEventually(equal(1), timeout: .seconds(2))
                    }

                    it("purchases a product resolved after navigating to a later screen") {
                        mockPurchaseDelegate.simulatedDelay = 0
                        mockPurchaseDelegate.configureForSuccess()
                        let destinationProduct = mockAppStoreProduct!
                        mocks.productService.mockProducts = [destinationProduct]
                        let activeTransactionService = transactionService!
                        let activeEventSink = eventSink!
                        let controller = await MainActor.run {
                            RecordingPurchaseExperienceViewController(
                                mockExperienceVersionId: "flow-later-screen-product",
                                products: [],
                                transactionService: activeTransactionService,
                                systemEventSink: activeEventSink
                            )
                        }
                        var resolved = StoreProduct(
                            productId: "destination-product",
                            storeProductId: destinationProduct.id,
                            placementId: "destination:placement",
                            name: destinationProduct.displayName,
                            price: destinationProduct.displayPrice,
                            period: nil,
                            appStoreProduct: destinationProduct
                        )
                        resolved.purchaseContext = PurchaseCommercialContext(
                            release: mockProduct.purchaseContext!.release,
                            placementId: resolved.placementId,
                            productId: resolved.productId,
                            storeProductId: resolved.storeProductId
                        )
                        let retainedResolvedProduct = resolved

                        await MainActor.run {
                            controller.mergeResolvedProducts([retainedResolvedProduct])
                            controller.performPurchase(
                                placementId: "destination:placement"
                            )
                        }

                        await expect(mockPurchaseDelegate.purchaseCalled).toEventually(
                            beTrue(),
                            timeout: .seconds(2)
                        )
                        let purchasedPlacement = await MainActor.run {
                            controller.products.first?.placementId
                        }
                        expect(purchasedPlacement) == "destination:placement"
                    }
                }
                
                context("without purchase delegate configured") {
                    it("uses native StoreKit with the exact retained StoreProduct") {
                        settings.setPurchaseDelegate(nil)
                        mockNativePurchaseAdapter.configurePurchased()

                        await expect {
                            try await transactionService.purchase(mockProduct)
                        }.toNot(throwError())

                        expect(mockNativePurchaseAdapter.purchasedProducts.count) == 1
                        expect(mockNativePurchaseAdapter.purchasedProducts.first) == mockProduct
                        expect(mocks.productService.fetchProductsCalled) == false
                    }

                    it("syncs and finishes verified native evidence") {
                        settings.setPurchaseDelegate(nil)
                        mockNativePurchaseAdapter.configureVerifiedPurchase(
                            productId: mockProduct.storeProductId
                        )

                        let result = try await transactionService.purchase(mockProduct)
                        expect(result.syncTask).toNot(beNil())
                        let synced = await result.syncTask?.value

                        expect(synced) == true
                        let recorded = await mockTransactionObserver.recordedPurchaseIds
                        expect(recorded).to(haveCount(1))
                        let recordedCustomers = await mockTransactionObserver
                            .recordedPurchaseDistinctIds
                        expect(recordedCustomers) == ["test-user"]
                        let calls = await mockTransactionObserver.syncCalls
                        expect(calls.count) == 1
                        expect(calls.first?.productId) == mockProduct.storeProductId
                        expect(mockNativePurchaseAdapter.finishCallCount) == 1
                        let completion = eventSink.events.first {
                            $0.name == SystemEventNames.purchaseCompleted
                        }
                        expect(completion?.properties?["product_id"] as? String) == "product"
                        expect(completion?.properties?["placement_id"] as? String) == "placement"
                        expect(completion?.properties?["store_product_id"] as? String)
                            == "com.test.product"
                        expect(completion?.properties?["experience_id"] as? String)
                            == "experience-1"
                        expect(completion?.properties?["display_price"] as? String) == "$9.99"
                        expect(completion?.properties?["price"] as? Double) == 9.99
                        expect(completion?.properties?["transaction_id"] as? String)
                            == "transaction-id"
                        expect(completion?.properties?["source"] as? String) == "purchase"
                        expect(completion?.properties?["test_store"] as? Bool) == false
                        expect(eventSink.routedCaptureCount) == 1
                        expect(eventSink.captureOnlyCount) == 0
                    }

                    it("emits completion once when transaction updates wins the purchase race") {
                        settings.setPurchaseDelegate(nil)
                        mockNativePurchaseAdapter.configureVerifiedPurchase(
                            transactionId: "racing-transaction",
                            productId: mockProduct.storeProductId
                        )
                        let claimed = await mockTransactionObserver
                            .claimPurchaseCompletion(
                                transactionId: "racing-transaction"
                            )
                        expect(claimed) == true
                        let recoveryProperties = purchaseCompletionProperties(
                            context: mockProduct.purchaseContext!,
                            transactionId: "racing-transaction",
                            testStore: false
                        )
                        let updateCaptured = await eventSink.capture(
                            SystemEventNames.purchaseCompleted,
                            properties: recoveryProperties,
                            eventId: "purchase-completed:test-fixture:test:appStore:racing-transaction",
                            distinctId: "test-user"
                        )
                        expect(updateCaptured) == true

                        let result = try await transactionService.purchase(mockProduct)
                        _ = await result.syncTask?.value

                        let completions = eventSink.events.filter {
                            $0.name == SystemEventNames.purchaseCompleted
                        }
                        expect(completions).to(haveCount(1))
                        expect(completions.first?.properties as NSDictionary?) ==
                            recoveryProperties as NSDictionary
                        expect(eventSink.routedCaptureCount) == 1
                        expect(eventSink.captureOnlyCount) == 0
                    }

                    it("does not finish verified native evidence when recovery deletion fails") {
                        settings.setPurchaseDelegate(nil)
                        mockNativePurchaseAdapter.configureVerifiedPurchase(
                            productId: mockProduct.storeProductId
                        )
                        let recoveryStore = CheckoutRecoveryDeletionFailureStore()
                        transactionService = TransactionService(
                            productService: mocks.productService,
                            transactionObserver: mockTransactionObserver,
                            pendingPurchaseStore: recoveryStore,
                            dateProvider: dateProvider,
                            settings: settings,
                            eventSink: eventSink,
                            purchaseStorageScope: purchaseStorageScope,
                            identityService: identityService,
                            nativePurchaseAdapter: mockNativePurchaseAdapter,
                            featureService: featureService
                        )

                        await expect {
                            try await transactionService.purchase(mockProduct)
                        }.to(throwError())

                        expect(mockNativePurchaseAdapter.finishCallCount) == 0
                        expect(recoveryStore.load().values.first?.commercialContext) ==
                            mockProduct.purchaseContext
                    }

                    it("records but does not finish host-owned evidence in observer mode") {
                        settings.setPurchaseDelegate(nil)
                        settings.setPurchaseHandlingMode(.observer)
                        mockNativePurchaseAdapter.configureVerifiedPurchase(
                            productId: mockProduct.storeProductId
                        )

                        let result = try await transactionService.purchase(mockProduct)
                        _ = await result.syncTask?.value

                        let finishRequirements = await mockTransactionObserver
                            .recordedPurchaseFinishRequirements
                        expect(finishRequirements) == [false]
                        expect(mockNativePurchaseAdapter.finishCallCount) == 0
                    }

                    it("finishes verified native evidence before a failed sync") {
                        settings.setPurchaseDelegate(nil)
                        mockNativePurchaseAdapter.configureVerifiedPurchase(
                            productId: mockProduct.storeProductId
                        )
                        await mockTransactionObserver.setNextSyncResult(false)

                        let result = try await transactionService.purchase(mockProduct)
                        let synced = await result.syncTask?.value

                        expect(synced) == false
                        expect(mockNativePurchaseAdapter.finishCallCount) == 1
                    }

                    it("invalidates stale StoreKit details after native checkout fails") {
                        settings.setPurchaseDelegate(nil)
                        mockNativePurchaseAdapter.configureFailed(StoreKitError.networkUnavailable)

                        await expect {
                            try await transactionService.purchase(mockProduct)
                        }.to(throwError())

                        expect(mocks.productService.invalidatedProductIds) == [
                            mockProduct.storeProductId
                        ]
                    }

                    it("reloads after StoreKit rejects the retained product as unavailable") {
                        settings.setPurchaseDelegate(nil)
                        mockNativePurchaseAdapter.configureProductTermsChanged()

                        await expect {
                            try await transactionService.purchase(mockProduct)
                        }.to(throwError(StoreKitError.productTermsChanged(
                            mockProduct.storeProductId
                        )))

                        expect(mocks.productService.invalidatedProductIds) == [
                            mockProduct.storeProductId
                        ]
                    }

                    it("does not refetch StoreKit and purchases the retained presented product") {
                        settings.setPurchaseDelegate(nil)
                        mockNativePurchaseAdapter.configurePurchased()
                        let shownNative = ReferenceMockStoreProduct(MockStoreProduct(
                            id: "com.test.subscription",
                            displayName: "Pro",
                            price: 9.99,
                            displayPrice: "$9.99",
                            productType: .autoRenewable,
                            subscriptionPeriod: .init(value: 1, unit: .month)
                        ))
                        var shown = try await StoreProductResolver().resolve(
                            experienceVersionId: "version-terms",
                            authorization: nil,
                            productId: "pro",
                            placementId: "paywall:pro",
                            productType: .autoRenewable,
                            appStoreProduct: shownNative,
                            options: .default
                        )
                        shown.purchaseContext = PurchaseCommercialContext(
                            release: mockProduct.purchaseContext!.release,
                            placementId: shown.placementId,
                            productId: shown.productId,
                            storeProductId: shown.storeProductId
                        )
                        mocks.productService.mockProducts = [MockStoreProduct(
                            id: shownNative.id,
                            displayName: "Pro",
                            price: 12.99,
                            displayPrice: "$12.99",
                            productType: .autoRenewable,
                            subscriptionPeriod: .init(value: 1, unit: .month)
                        )]

                        await expect {
                            try await transactionService.purchase(shown)
                        }.toNot(throwError())

                        expect(mocks.productService.fetchProductsCalled) == false
                        expect(mocks.productService.invalidatedProductIds).to(beEmpty())
                        expect(mockNativePurchaseAdapter.purchasedProducts).to(haveCount(1))
                        guard let purchasedNative = mockNativePurchaseAdapter
                            .purchasedProducts.first?.appStoreProduct
                            as? ReferenceMockStoreProduct else {
                            fail("Expected native checkout to retain the reference-backed product")
                            return
                        }
                        expect(purchasedNative === shownNative) == true
                    }

                    it("keeps using the retained product on repeated attempts") {
                        settings.setPurchaseDelegate(nil)
                        let native = MockStoreProduct(
                            id: "com.test.retry",
                            displayName: "Retry",
                            price: 4.99,
                            displayPrice: "$4.99"
                        )
                        var shown = try await StoreProductResolver().resolve(
                            experienceVersionId: "version-retry",
                            authorization: nil,
                            productId: "retry",
                            placementId: "paywall:retry",
                            productType: .nonConsumable,
                            appStoreProduct: native,
                            options: .default
                        )
                        mockNativePurchaseAdapter.configureVerifiedPurchase(
                            productId: shown.storeProductId
                        )
                        shown.purchaseContext = PurchaseCommercialContext(
                            release: mockProduct.purchaseContext!.release,
                            placementId: shown.placementId,
                            productId: shown.productId,
                            storeProductId: shown.storeProductId
                        )

                        _ = try await transactionService.purchase(shown)
                        _ = try await transactionService.purchase(shown)

                        expect(mocks.productService.fetchProductsCalled) == false
                        expect(mockNativePurchaseAdapter.purchasedProducts).to(haveCount(2))
                        expect(
                            mockNativePurchaseAdapter.purchasedProducts.map(\.price)
                        ) == [shown.price, shown.price]
                    }

                    it("uses one fresh eligibility token without re-resolving the product") {
                        let token = "e30.e30.Y2hlY2tvdXQ"
                        await introTokenProvider.setToken(token)
                        mockPurchaseDelegate.configureForSuccess()
                        let native = MockStoreProduct(
                            id: "com.test.single-token",
                            displayName: "Trial",
                            price: 9.99,
                            displayPrice: "$9.99",
                            productType: .autoRenewable,
                            subscriptionPeriod: .init(value: 1, unit: .month),
                            introductoryTerms: .init(
                                price: "$0.00",
                                period: .week,
                                periodCount: 1,
                                cycles: 1,
                                paymentMode: .freeTrial,
                                trialPeriodText: "1 week"
                            )
                        )
                        let resolver = StoreProductResolver(
                            tokenProvider: introTokenProvider,
                            overrideHealth: introOverrideHealth
                        )
                        var shown = try await resolver.resolve(
                            experienceVersionId: "version-single-token",
                            authorization: .init(
                                distinctId: "test-user",
                                journeyId: "journey-1"
                            ),
                            productId: "trial",
                            placementId: "paywall:trial",
                            productType: .autoRenewable,
                            appStoreProduct: native,
                            options: .init(
                                introEligibility: .alwaysEligible,
                                billingPlan: .default
                            )
                        )
                        shown.purchaseContext = PurchaseCommercialContext(
                            release: mockProduct.purchaseContext!.release,
                            placementId: shown.placementId,
                            productId: shown.productId,
                            storeProductId: shown.storeProductId
                        )
                        mocks.productService.mockProducts = [native]

                        await expect {
                            try await transactionService.purchase(shown)
                        }.toNot(throwError())

                        // One probe allowed the offer to be shown. Checkout
                        // mints exactly one more JWS and installs it on the
                        // retained product passed to the delegate.
                        let tokenRequests = await introTokenProvider.requests()
                        expect(tokenRequests.count) == 2
                        expect(mocks.productService.fetchProductsCalled) == false
                        expect(
                            mockPurchaseDelegate.lastPurchasedProduct?
                                .introductoryOfferEligibilityJWS
                        ) == token
                    }

                    it(
                        "fails closed and closes a direct presentation when checkout authorization expires"
                    ) {
                        await introTokenProvider.setToken("e30.e30.cHJlc2VudGF0aW9u")
                        let shownNative = MockStoreProduct(
                            id: "com.test.direct-terms",
                            displayName: "Pro",
                            price: 9.99,
                            displayPrice: "$9.99",
                            productType: .autoRenewable,
                            subscriptionPeriod: .init(value: 1, unit: .month),
                            introductoryTerms: .init(
                                price: "$0.00",
                                period: .week,
                                periodCount: 1,
                                cycles: 1,
                                paymentMode: .freeTrial,
                                trialPeriodText: "1 week"
                            )
                        )
                        let shown = try await StoreProductResolver(
                            tokenProvider: introTokenProvider,
                            overrideHealth: introOverrideHealth
                        ).resolve(
                            experienceVersionId: "version-direct-terms",
                            authorization: .init(
                                distinctId: "test-user",
                                journeyId: "journey-direct"
                            ),
                            productId: "pro",
                            placementId: "paywall:pro",
                            productType: .autoRenewable,
                            appStoreProduct: shownNative,
                            options: .init(
                                introEligibility: .alwaysEligible,
                                billingPlan: .default
                            )
                        )
                        await introTokenProvider.setToken(nil)
                        let activeTransactionService = transactionService!
                        let activeEventSink = eventSink!
                        let controller = await MainActor.run {
                            RecordingPurchaseExperienceViewController(
                                mockExperienceVersionId: "version-direct-terms",
                                products: [shown],
                                transactionService: activeTransactionService,
                                systemEventSink: activeEventSink
                            )
                        }

                        await MainActor.run {
                            controller.performPurchase(placementId: shown.placementId)
                        }

                        await expect {
                            await MainActor.run {
                                controller.emittedSystemEvents.first(where: {
                                    $0.name == SystemEventNames.purchaseFailed
                                })?.properties["reason"] as? String
                            }
                        }.toEventually(
                            equal("product_terms_changed"),
                            timeout: .seconds(2)
                        )
                        await expect {
                            await MainActor.run {
                                controller.requestedDismissalReasons.count
                            }
                        }.toEventually(equal(1), timeout: .seconds(2))
                        let requestedError = await MainActor.run {
                            guard case .error(let error)? =
                                    controller.requestedDismissalReasons.first else {
                                return nil as Nuxie.StoreKitError?
                            }
                            return error as? Nuxie.StoreKitError
                        }
                        expect(requestedError) == .productTermsChanged(shown.storeProductId)
                    }

                    it("routes native product unavailability through one direct failure") {
                        settings.setPurchaseDelegate(nil)
                        mockNativePurchaseAdapter.configureProductTermsChanged()
                        let presentedProduct = mockProduct!
                        let activeTransactionService = transactionService!
                        let activeEventSink = eventSink!
                        let controller = await MainActor.run {
                            RecordingPurchaseExperienceViewController(
                                mockExperienceVersionId: "version-unavailable",
                                products: [presentedProduct],
                                transactionService: activeTransactionService,
                                systemEventSink: activeEventSink
                            )
                        }

                        await MainActor.run {
                            controller.performPurchase(
                                placementId: presentedProduct.placementId
                            )
                        }

                        await expect {
                            await MainActor.run {
                                controller.requestedDismissalReasons.count
                            }
                        }.toEventually(equal(1), timeout: .seconds(2))
                        let failures = await MainActor.run {
                            controller.emittedSystemEvents.filter {
                                $0.name == SystemEventNames.purchaseFailed
                            }
                        }
                        expect(failures.count) == 1
                        expect(failures.first?.properties["reason"] as? String) ==
                            "product_terms_changed"
                    }

                    it("keeps an override retryable after an unrelated purchase failure") {
                        settings.setPurchaseDelegate(nil)
                        await introTokenProvider.setToken("e30.e30.dG9rZW4")
                        let native = MockStoreProduct(
                            id: "com.test.trial",
                            displayName: "Trial",
                            price: 9.99,
                            displayPrice: "$9.99",
                            productType: .autoRenewable,
                            subscriptionPeriod: .init(value: 1, unit: .month),
                            introductoryTerms: .init(
                                price: "$0.00",
                                period: .week,
                                periodCount: 1,
                                cycles: 1,
                                paymentMode: .freeTrial,
                                trialPeriodText: "1 week"
                            )
                        )
                        let options = AppStorePlacementOptions(
                            introEligibility: .alwaysEligible,
                            billingPlan: .default
                        )
                        let resolver = StoreProductResolver(
                            tokenProvider: introTokenProvider,
                            overrideHealth: introOverrideHealth
                        )
                        var shown = try await resolver.resolve(
                            experienceVersionId: "version-trial",
                            authorization: .init(
                                distinctId: "test-user",
                                journeyId: "journey-1"
                            ),
                            productId: "trial",
                            placementId: "paywall:trial",
                            productType: .autoRenewable,
                            appStoreProduct: native,
                            options: options
                        )
                        shown.purchaseContext = mockProduct.purchaseContext
                        mocks.productService.mockProducts = [native]
                        mockNativePurchaseAdapter.configureFailed(
                            StoreKitError.networkUnavailable
                        )

                        await expect {
                            try await transactionService.purchase(shown)
                        }.to(throwError())
                        let retry = try await resolver.resolve(
                            experienceVersionId: "version-trial",
                            authorization: .init(
                                distinctId: "test-user",
                                journeyId: "journey-1"
                            ),
                            productId: "trial",
                            placementId: "paywall:trial",
                            productType: .autoRenewable,
                            appStoreProduct: native,
                            options: options
                        )

                        expect(retry.hasFreeTrial) == true
                        expect(retry.introEligibilityTokenRequest).toNot(beNil())
                    }

                    it("suppresses only a classified invalid eligibility override") {
                        settings.setPurchaseDelegate(nil)
                        await introTokenProvider.setToken("e30.e30.dG9rZW4")
                        let native = MockStoreProduct(
                            id: "com.test.invalid-trial",
                            displayName: "Trial",
                            price: 9.99,
                            displayPrice: "$9.99",
                            productType: .autoRenewable,
                            subscriptionPeriod: .init(value: 1, unit: .month),
                            introductoryTerms: .init(
                                price: "$0.00",
                                period: .week,
                                periodCount: 1,
                                cycles: 1,
                                paymentMode: .freeTrial,
                                trialPeriodText: "1 week"
                            ),
                            eligibleForIntroOffer: false
                        )
                        let options = AppStorePlacementOptions(
                            introEligibility: .alwaysEligible,
                            billingPlan: .default
                        )
                        let authorization = IntroEligibilityAuthorizationContext(
                            distinctId: "test-user",
                            journeyId: "journey-1"
                        )
                        let resolver = StoreProductResolver(
                            tokenProvider: introTokenProvider,
                            overrideHealth: introOverrideHealth
                        )
                        var shown = try await resolver.resolve(
                            experienceVersionId: "version-invalid-trial",
                            authorization: authorization,
                            productId: "trial",
                            placementId: "paywall:invalid-trial",
                            productType: .autoRenewable,
                            appStoreProduct: native,
                            options: options
                        )
                        shown.purchaseContext = mockProduct.purchaseContext
                        mocks.productService.mockProducts = [native]
                        mockNativePurchaseAdapter.configureInvalidEligibilityOverride(
                            StoreKitError.apiMisuse(reason: "invalid eligibility JWS")
                        )

                        await expect {
                            try await transactionService.purchase(shown)
                        }.to(throwError(StoreKitError.productTermsChanged(
                            shown.storeProductId
                        )))
                        await expect {
                            try await transactionService.purchase(shown)
                        }.to(throwError(StoreKitError.productTermsChanged(
                            shown.storeProductId
                        )))
                        let tokenRequests = await introTokenProvider.requests()
                        expect(tokenRequests.count) == 2
                        expect(mockNativePurchaseAdapter.purchasedProducts.count) == 1
                        await expect {
                            try await resolver.resolve(
                                experienceVersionId: "version-invalid-trial",
                                authorization: authorization,
                                productId: "trial",
                                placementId: "paywall:invalid-trial",
                                productType: .autoRenewable,
                                appStoreProduct: native,
                                options: options
                            )
                        }.to(throwError(StoreKitError.noProductsAvailable))
                    }

                    it("reconciles an already-owned product without completing purchase") {
                        settings.setPurchaseDelegate(nil)
                        mockNativePurchaseAdapter.configureAlreadyOwned()

                        _ = try await transactionService.purchase(mockProduct)

                        let reconciled = await mockTransactionObserver.syncCurrentEntitlementsCalled
                        expect(reconciled) == true
                        expect(eventSink.events.map(\.name)).toNot(
                            contain(SystemEventNames.purchaseCompleted)
                        )
                        expect(eventSink.events.map(\.name).filter {
                            $0 == SystemEventNames.purchaseFailed
                        }.count) == 1
                    }

                    it("routes subscription replacement away from acquisition checkout") {
                        settings.setPurchaseDelegate(nil)
                        mockNativePurchaseAdapter.configureSubscriptionChangeRequired()

                        await expect {
                            try await transactionService.purchase(mockProduct)
                        }.to(throwError(StoreKitError.subscriptionChangeRequired(
                            mockProduct.storeProductId
                        )))

                        expect(eventSink.events.map(\.name)).toNot(
                            contain(SystemEventNames.purchaseCompleted)
                        )
                    }

                    it("routes subscription replacement to the failure branch exactly once") {
                        settings.setPurchaseDelegate(nil)
                        mockNativePurchaseAdapter.configureSubscriptionChangeRequired()
                        let activeTransactionService = transactionService!
                        let activeEventSink = eventSink!
                        let retainedProduct = mockProduct!
                        let controller = await MainActor.run {
                            RecordingPurchaseExperienceViewController(
                                mockExperienceVersionId: "subscription-change",
                                products: [retainedProduct],
                                transactionService: activeTransactionService,
                                systemEventSink: activeEventSink
                            )
                        }

                        await MainActor.run {
                            controller.performPurchase(placementId: retainedProduct.placementId)
                        }

                        await expect(eventSink.events.map(\.name).filter {
                            $0 == SystemEventNames.purchaseFailed
                        }.count).toEventually(equal(1), timeout: .seconds(2))
                        let controllerFailures = await MainActor.run {
                            controller.emittedSystemEvents.filter {
                                $0.name == SystemEventNames.purchaseFailed
                            }.count
                        }
                        expect(controllerFailures) == 0
                    }
                }

                context("when the purchase is deferred (Ask-to-Buy / SCA)") {
                    it("fails closed when the pending transition is not durable") {
                        settings.setPurchaseDelegate(nil)
                        mockNativePurchaseAdapter.configurePending()
                        let store = PendingTransitionFailureStore()
                        transactionService = TransactionService(
                            productService: mocks.productService,
                            transactionObserver: mockTransactionObserver,
                            pendingPurchaseStore: store,
                            dateProvider: dateProvider,
                            settings: settings,
                            eventSink: eventSink,
                            purchaseStorageScope: purchaseStorageScope,
                            identityService: identityService,
                            nativePurchaseAdapter: mockNativePurchaseAdapter,
                            featureService: featureService
                        )

                        await expect {
                            try await transactionService.purchase(mockProduct)
                        }.to(throwError(StoreKitError.purchaseFailed(nil)))

                        let retained = store.load().values.first
                        expect(retained?.state) == .checkout
                        expect(retained?.commercialContext.placementId) == "placement"

                        // The physical checkout record is the only evidence
                        // that StoreKit accepted an Ask-to-Buy request when
                        // the state-transition write fails. It must remain
                        // recoverable beyond the short checkout retry window.
                        dateProvider.advance(
                            by: TransactionService.checkoutRecoveryTTL + 1
                        )
                        let recovery = await transactionService.checkoutRecoveryRecord(
                            appAccountToken: retained?.appAccountToken,
                            productId: mockProduct.storeProductId
                        )
                        expect(recovery?.commercialContext.placementId) == "placement"
                    }

                    it("retries after an abandoned checkout recovery window") {
                        settings.setPurchaseDelegate(nil)
                        let store = PendingPurchaseStore(
                            customStoragePath: pendingStorageURL,
                            scope: purchaseStorageScope
                        )
                        let abandoned = PendingPurchaseRecord(
                            scope: purchaseStorageScope,
                            distinctId: "test-user",
                            appAccountToken: purchaseStorageScope.appAccountToken(
                                distinctId: "test-user"
                            ),
                            commercialContext: mockProduct.purchaseContext!,
                            recordedAt: dateProvider.now(),
                            localEntitlementGrants: [],
                            state: .checkout
                        )
                        expect(store.save([
                            "test-user::\(mockProduct.storeProductId)": abandoned,
                        ])) == true
                        dateProvider.advance(
                            by: TransactionService.checkoutRecoveryTTL + 1
                        )
                        mockNativePurchaseAdapter.configureCancelled()
                        transactionService = makeTransactionService()

                        await expect {
                            try await transactionService.purchase(mockProduct)
                        }.to(throwError(StoreKitError.purchaseCancelled))

                        expect(mockNativePurchaseAdapter.purchasedProducts).to(haveCount(1))
                        expect(store.load()).to(beEmpty())
                    }

                    it("rejects a second unresolved checkout for the same customer and product") {
                        settings.setPurchaseDelegate(nil)
                        mockNativePurchaseAdapter.configurePending()

                        await expect {
                            try await transactionService.purchase(mockProduct)
                        }.to(throwError(StoreKitError.purchasePending))

                        var otherPlacement = mockProduct!
                        otherPlacement.purchaseContext = PurchaseCommercialContext(
                            release: mockProduct.purchaseContext!.release,
                            placementId: "other-placement",
                            productId: mockProduct.productId,
                            storeProductId: mockProduct.storeProductId
                        )

                        await expect {
                            try await transactionService.purchase(otherPlacement)
                        }.to(throwError(StoreKitError.apiMisuse(
                            reason: "A purchase is already unresolved for this customer and product"
                        )))

                        let record = await transactionService.pendingPurchaseRecord(
                            productId: mockProduct.storeProductId,
                            distinctId: "test-user"
                        )
                        expect(record?.commercialContext.placementId) == "placement"
                    }

                    it("records the product so the observer can resolve it exactly once") {
                        settings.setPurchaseDelegate(nil)
                        mockNativePurchaseAdapter.configurePending()

                        await expect {
                            try await transactionService.purchase(mockProduct)
                        }.to(throwError(StoreKitError.purchasePending))

                        // The deferred transaction later lands via
                        // Transaction.updates; the observer consumes the entry
                        // (exactly once) and emits $purchase_completed.
                        await expect {
                            await transactionService.consumePendingPurchase(productId: mockProduct.storeProductId)
                        }.to(beTrue())
                        await expect {
                            await transactionService.consumePendingPurchase(productId: mockProduct.storeProductId)
                        }.to(beFalse())
                    }

                    it("persists the marker so it survives a store reload (process kill)") {
                        settings.setPurchaseDelegate(nil)
                        mockNativePurchaseAdapter.configurePending()

                        await expect {
                            try await transactionService.purchase(mockProduct)
                        }.to(throwError(StoreKitError.purchasePending))

                        // "Relaunch": a fresh service over the same storage
                        // still resolves the deferred purchase, exactly once.
                        let relaunched = makeTransactionService()
                        await expect {
                            await relaunched.consumePendingPurchase(productId: mockProduct.storeProductId)
                        }.to(beTrue())
                        await expect {
                            await relaunched.consumePendingPurchase(productId: mockProduct.storeProductId)
                        }.to(beFalse())

                        // Consumption is durable too: yet another relaunch
                        // must not see the already-consumed marker.
                        let relaunchedAgain = makeTransactionService()
                        await expect {
                            await relaunchedAgain.consumePendingPurchase(productId: mockProduct.storeProductId)
                        }.to(beFalse())
                    }

                    it("expires an unresolved marker after the 30-day TTL") {
                        settings.setPurchaseDelegate(nil)
                        mockNativePurchaseAdapter.configurePending()

                        await expect {
                            try await transactionService.purchase(mockProduct)
                        }.to(throwError(StoreKitError.purchasePending))

                        // Just inside the TTL: still resolvable.
                        dateProvider.advance(by: TransactionService.pendingPurchaseTTL - 1)
                        let insideTTL = makeTransactionService()
                        await expect {
                            await insideTTL.consumePendingPurchase(productId: mockProduct.storeProductId)
                        }.to(beTrue())

                        // Re-record, then jump past the TTL: the stale marker
                        // must not resolve (a much later organic purchase is
                        // not the deferred one).
                        await expect {
                            try await insideTTL.purchase(mockProduct)
                        }.to(throwError(StoreKitError.purchasePending))
                        dateProvider.advance(by: TransactionService.pendingPurchaseTTL + 1)
                        let afterTTL = makeTransactionService()
                        await expect {
                            await afterTTL.consumePendingPurchase(productId: mockProduct.storeProductId)
                        }.to(beFalse())
                    }

                    it("preserves the owner of an orphaned pending marker") {
                        settings.setPurchaseDelegate(nil)
                        mockNativePurchaseAdapter.configurePending()

                        await expect {
                            try await transactionService.purchase(mockProduct)
                        }.to(throwError(StoreKitError.purchasePending))

                        identityService.setDistinctId("different-customer")
                        await expect {
                            await transactionService.pendingPurchaseDistinctId(
                                productId: mockProduct.storeProductId
                            )
                        }.to(beNil())
                        await expect {
                            await transactionService.pendingPurchaseGrants(
                                productId: mockProduct.storeProductId
                            )
                        }.to(beNil())
                        await expect {
                            await transactionService.consumePendingPurchase(
                                productId: mockProduct.storeProductId
                            )
                        }.to(beFalse())
                        await expect {
                            await transactionService.consumePendingPurchase(
                                productId: mockProduct.storeProductId,
                                distinctId: "test-user"
                            )
                        }.to(beTrue())
                    }

                    it("resolves a unique deferred owner after the active customer changes") {
                        settings.setPurchaseDelegate(nil)
                        mockNativePurchaseAdapter.configurePending()

                        identityService.setDistinctId("customer-a")
                        await expect {
                            try await transactionService.purchase(mockProduct)
                        }.to(throwError(StoreKitError.purchasePending))
                        identityService.setDistinctId("customer-b")

                        let ownership = await transactionService
                            .pendingPurchaseOwnership(productId: mockProduct.storeProductId)
                        guard case .unique(let record) = ownership else {
                            fail("Expected one durable deferred owner")
                            return
                        }
                        expect(record.distinctId) == "customer-a"
                    }

                    it("refuses to guess when two customers deferred the same product") {
                        settings.setPurchaseDelegate(nil)
                        mockNativePurchaseAdapter.configurePending()

                        identityService.setDistinctId("customer-a")
                        await expect {
                            try await transactionService.purchase(mockProduct)
                        }.to(throwError(StoreKitError.purchasePending))
                        identityService.setDistinctId("customer-b")
                        await expect {
                            try await transactionService.purchase(mockProduct)
                        }.to(throwError(StoreKitError.purchasePending))

                        let ownership = await transactionService
                            .pendingPurchaseOwnership(productId: mockProduct.storeProductId)
                        guard case .ambiguous = ownership else {
                            fail("Expected ambiguous deferred ownership")
                            return
                        }
                    }
                }
            }

            describe("restore") {
                it("honors the Test Store restored outcome without prior purchases") {
                    let store = NuxieTestStore()

                    let response = await store.restoreResponse(
                        for: .restored,
                        distinctId: "test-user"
                    )

                    guard case .restored = response.result else {
                        fail("Expected the Test Store restore to succeed")
                        return
                    }
                    expect(response.products).to(beEmpty())
                }

                it("uses the isolated Test Store restore surface") {
                    mockTestStore = MockNuxieTestStore()
                    transactionService = makeTransactionService()
                    settings.setPurchaseDelegate(nil)
                    await mockTestStore.setRestoreResponse(
                        NuxieTestStoreRestoreResponse(result: .restored)
                    )

                    await expect {
                        try await transactionService.restore()
                    }.toNot(throwError())

                    let restoreCalls = await mockTestStore.restoreCalls
                    expect(restoreCalls) == 1
                    let restoreDistinctIds = await mockTestStore.restoreDistinctIds
                    expect(restoreDistinctIds) == ["test-user"]
                    expect(mockNativePurchaseAdapter.restoreCallCount) == 0
                }

                context("with purchase delegate configured") {
                    it("leaves restore ownership with the provider") {
                        mockPurchaseDelegate.restoreResult = .providerRestored

                        await expect {
                            try await transactionService.restore()
                        }.toNot(throwError())

                        await expect { await mockTransactionObserver.syncCurrentEntitlementsCalled }
                            .to(beFalse())
                        expect(eventSink.events.map(\.name).filter {
                            $0 == SystemEventNames.restoreCompleted
                        }.count) == 1
                        expect(eventSink.events.first?.properties).to(beNil())
                    }

                    it("syncs current StoreKit entitlements after a custom StoreKit restore") {
                        mockPurchaseDelegate.restoreResult = .storeKitRestored
                        
                        await expect {
                            try await transactionService.restore()
                        }.toNot(throwError())
                        
                        expect(mockPurchaseDelegate.restoreCalled).to(beTrue())
                        await expect { await mockTransactionObserver.syncCurrentEntitlementsCalled }
                            .to(beTrue())
                        await expect {
                            await mockTransactionObserver.syncCurrentEntitlementsDistinctIds
                        }.to(equal(["test-user"]))
                    }

                    it("emits purchase events without configuring the SDK singleton") {
                        mockPurchaseDelegate.configureForSuccess()

                        _ = try await transactionService.purchase(mockProduct)

                        expect(eventSink.events.map(\.name)).to(equal([
                            SystemEventNames.purchaseCompleted
                        ]))
                    }
                    
                    it("should handle no purchases to restore") {
                        mockPurchaseDelegate.configureForNoPurchases()
                        
                        await expect {
                            try await transactionService.restore()
                        }.toNot(throwError())
                        
                        expect(mockPurchaseDelegate.restoreCalled).to(beTrue())
                        expect(eventSink.events.map(\.name).filter {
                            $0 == SystemEventNames.restoreNoPurchases
                        }.count) == 1
                    }
                    
                    it("should throw restoreFailed when restore fails") {
                        let error = StoreKitError.networkUnavailable
                        mockPurchaseDelegate.restoreResult = .failed(error)
                        
                        await expect {
                            try await transactionService.restore()
                        }.to(throwError())
                        
                        expect(mockPurchaseDelegate.restoreCalled).to(beTrue())
                        expect(eventSink.events.map(\.name).filter {
                            $0 == SystemEventNames.restoreFailed
                        }.count) == 1
                    }
                }
                
                context("without purchase delegate configured") {
                    it("restores with native StoreKit") {
                        settings.setPurchaseDelegate(nil)
                        mockNativePurchaseAdapter.restoreResult = .restored
                        
                        await expect {
                            try await transactionService.restore()
                        }.toNot(throwError())

                        expect(mockNativePurchaseAdapter.restoreCallCount) == 1
                    }
                }
            }
        }
    }
}
