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

    func emit(_ name: String, properties: [String: Any]?) {
        lock.lock()
        storage.append((name, properties))
        lock.unlock()
    }

    var events: [(name: String, properties: [String: Any]?)] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
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

            /// A TransactionService over the durable pending-purchase store in
            /// `pendingStorageURL` — building a second one models a process
            /// relaunch over the same storage.
            func makeTransactionService() -> TransactionService {
                let activeSettings = settings!
                let activeEventSink = eventSink!
                return TransactionService(
                    productService: mocks.productService,
                    transactionObserver: mockTransactionObserver,
                    pendingPurchaseStore: PendingPurchaseStore(customStoragePath: pendingStorageURL),
                    dateProvider: dateProvider,
                    settings: activeSettings,
                    eventSink: activeEventSink,
                    introEligibilityTokenProvider: introTokenProvider,
                    introEligibilityOverrideHealth: introOverrideHealth,
                    nativePurchaseAdapter: mockNativePurchaseAdapter
                )
            }

            beforeEach {
                mocks = MockFactory.shared

                // Keep StoreKit's real transaction observer out of unit tests
                mockTransactionObserver = MockTransactionObserver()

                // Create mock purchase delegate
                mockPurchaseDelegate = MockPurchaseDelegate()
                mockNativePurchaseAdapter = MockNativeStoreKitPurchaseAdapter()

                // Create a test configuration with the purchase delegate
                configuration = NuxieConfiguration(apiKey: "test-api-key")
                configuration.purchaseDelegate = mockPurchaseDelegate
                settings = NuxieRuntimeSettings(configuration: configuration)
                eventSink = RecordingTransactionEventSink()
                introTokenProvider = RecordingIntroEligibilityTokenProvider()
                introOverrideHealth = IntroEligibilityOverrideHealth()

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
            }

            afterEach {
                // Clean up
                mockPurchaseDelegate.reset()
                if let pendingStorageURL {
                    try? FileManager.default.removeItem(at: pendingStorageURL)
                }
            }
            
            describe("purchase") {
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

                    it("mints a fresh eligibility token before invoking the delegate") {
                        let token = "e30.e30.Y2hlY2tvdXQ"
                        await introTokenProvider.setToken(token)
                        mockPurchaseDelegate.configureForSuccess()
                        let overrideProduct = StoreProduct(
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
                                    distinctId: "customer-1",
                                    journeyId: "journey-1"
                                )
                            ),
                            appStoreProduct: mockAppStoreProduct
                        )

                        await expect {
                            try await transactionService.purchase(overrideProduct)
                        }.toNot(throwError())

                        guard let purchased = mockPurchaseDelegate.lastPurchasedProduct else {
                            fail("Expected the delegate to receive the checkout product")
                            return
                        }
                        var expected = Set<Product.PurchaseOption>()
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
                                    distinctId: "customer-1",
                                    journeyId: "journey-1"
                                )
                            ),
                        ]
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
                    
                    it("should throw purchasePending when purchase is pending") {
                        mockPurchaseDelegate.configureForPending()
                        
                        await expect {
                            try await transactionService.purchase(mockProduct)
                        }.to(throwError(StoreKitError.purchasePending))
                        
                        expect(mockPurchaseDelegate.purchaseCalled).to(beTrue())
                    }

                    it("should not emit purchase_failed from native purchase when purchase is pending") {
                        mockPurchaseDelegate.simulatedDelay = 0
                        mockPurchaseDelegate.configureForPending()
                        mocks.productService.mockProducts = [mockAppStoreProduct]
                        let pendingAppStoreProduct = mockAppStoreProduct!
                        let activeTransactionService = transactionService!
                        let activeEventSink = eventSink!
                        let controller = await MainActor.run {
                            RecordingPurchaseExperienceViewController(
                                mockExperienceVersionId: "flow-purchase-pending",
                                products: [
                                    StoreProduct(
                                        productId: "product",
                                        storeProductId: pendingAppStoreProduct.id,
                                        placementId: "placement",
                                        name: pendingAppStoreProduct.displayName,
                                        price: pendingAppStoreProduct.displayPrice,
                                        period: nil,
                                        appStoreProduct: pendingAppStoreProduct
                                    )
                                ],
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
                        let resolved = StoreProduct(
                            productId: "destination-product",
                            storeProductId: destinationProduct.id,
                            placementId: "destination:placement",
                            name: destinationProduct.displayName,
                            price: destinationProduct.displayPrice,
                            period: nil,
                            appStoreProduct: destinationProduct
                        )

                        await MainActor.run {
                            controller.mergeResolvedProducts([resolved])
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
                        let calls = await mockTransactionObserver.syncCalls
                        expect(calls.count) == 1
                        expect(calls.first?.productId) == mockProduct.storeProductId
                        expect(mockNativePurchaseAdapter.finishCallCount) == 1
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

                    it("aborts when live StoreKit terms changed after reveal") {
                        settings.setPurchaseDelegate(nil)
                        let shownNative = MockStoreProduct(
                            id: "com.test.subscription",
                            displayName: "Pro",
                            price: 9.99,
                            displayPrice: "$9.99",
                            productType: .autoRenewable,
                            subscriptionPeriod: .init(value: 1, unit: .month)
                        )
                        let shown = try await StoreProductResolver().resolve(
                            experienceVersionId: "version-terms",
                            authorization: nil,
                            productId: "pro",
                            placementId: "paywall:pro",
                            productType: .autoRenewable,
                            appStoreProduct: shownNative,
                            options: .default
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
                        }.to(throwError(StoreKitError.productTermsChanged(shownNative.id)))

                        expect(mockNativePurchaseAdapter.purchasedProducts).to(beEmpty())
                    }

                    it("uses one fresh eligibility token for revalidation and checkout") {
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
                        let shown = try await resolver.resolve(
                            experienceVersionId: "version-single-token",
                            authorization: .init(
                                distinctId: "customer-1",
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
                        mocks.productService.mockProducts = [native]

                        await expect {
                            try await transactionService.purchase(shown)
                        }.toNot(throwError())

                        // One probe allowed the offer to be shown. Checkout
                        // mints exactly one more JWS and reuses it while
                        // refreshing StoreKit terms and invoking the delegate.
                        let tokenRequests = await introTokenProvider.requests()
                        expect(tokenRequests.count) == 2
                        expect(
                            mockPurchaseDelegate.lastPurchasedProduct?
                                .introductoryOfferEligibilityJWS
                        ) == token
                    }

                    it("surfaces changed terms and closes a direct presentation") {
                        let shownNative = MockStoreProduct(
                            id: "com.test.direct-terms",
                            displayName: "Pro",
                            price: 9.99,
                            displayPrice: "$9.99",
                            productType: .autoRenewable,
                            subscriptionPeriod: .init(value: 1, unit: .month)
                        )
                        let shown = try await StoreProductResolver().resolve(
                            experienceVersionId: "version-direct-terms",
                            authorization: nil,
                            productId: "pro",
                            placementId: "paywall:pro",
                            productType: .autoRenewable,
                            appStoreProduct: shownNative,
                            options: .default
                        )
                        mocks.productService.mockProducts = [MockStoreProduct(
                            id: shownNative.id,
                            displayName: "Pro",
                            price: 12.99,
                            displayPrice: "$12.99",
                            productType: .autoRenewable,
                            subscriptionPeriod: .init(value: 1, unit: .month)
                        )]
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
                        let shown = try await resolver.resolve(
                            experienceVersionId: "version-trial",
                            authorization: .init(
                                distinctId: "customer-1",
                                journeyId: "journey-1"
                            ),
                            productId: "trial",
                            placementId: "paywall:trial",
                            productType: .autoRenewable,
                            appStoreProduct: native,
                            options: options
                        )
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
                                distinctId: "customer-1",
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
                            distinctId: "customer-1",
                            journeyId: "journey-1"
                        )
                        let resolver = StoreProductResolver(
                            tokenProvider: introTokenProvider,
                            overrideHealth: introOverrideHealth
                        )
                        let shown = try await resolver.resolve(
                            experienceVersionId: "version-invalid-trial",
                            authorization: authorization,
                            productId: "trial",
                            placementId: "paywall:invalid-trial",
                            productType: .autoRenewable,
                            appStoreProduct: native,
                            options: options
                        )
                        mocks.productService.mockProducts = [native]
                        mockNativePurchaseAdapter.configureInvalidEligibilityOverride(
                            StoreKitError.apiMisuse(reason: "invalid eligibility JWS")
                        )

                        await expect {
                            try await transactionService.purchase(shown)
                        }.to(throwError())
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
                    it("records the product so the observer can resolve it exactly once") {
                        mockPurchaseDelegate.purchaseResult = .pending

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
                        mockPurchaseDelegate.purchaseResult = .pending

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
                        mockPurchaseDelegate.purchaseResult = .pending

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
                            try await transactionService.purchase(mockProduct)
                        }.to(throwError(StoreKitError.purchasePending))
                        dateProvider.advance(by: TransactionService.pendingPurchaseTTL + 1)
                        let afterTTL = makeTransactionService()
                        await expect {
                            await afterTTL.consumePendingPurchase(productId: mockProduct.storeProductId)
                        }.to(beFalse())
                    }
                }
            }

            describe("restore") {
                context("with purchase delegate configured") {
                    it("syncs current entitlements to the backend after a successful restore") {
                        mockPurchaseDelegate.restoreResult = .restored

                        await expect {
                            try await transactionService.restore()
                        }.toNot(throwError())

                        await expect { await mockTransactionObserver.syncCurrentEntitlementsCalled }
                            .to(beTrue())
                        expect(eventSink.events.map(\.name).filter {
                            $0 == SystemEventNames.restoreCompleted
                        }.count) == 1
                        expect(eventSink.events.first?.properties).to(beNil())
                    }

                    it("should successfully restore purchases") {
                        mockPurchaseDelegate.restoreResult = .restored
                        
                        await expect {
                            try await transactionService.restore()
                        }.toNot(throwError())
                        
                        expect(mockPurchaseDelegate.restoreCalled).to(beTrue())
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
