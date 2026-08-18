import Foundation
import StoreKit

struct PurchaseSyncResult: Sendable {
    public let syncTask: Task<Bool, Never>?

    public init(syncTask: Task<Bool, Never>? = nil) {
        self.syncTask = syncTask
    }
}

/// Service responsible for managing StoreKit transactions
actor TransactionService {
    private let productService: ProductService
    private let transactionObserver: TransactionObserverProtocol
    private let settings: PurchaseSettingsProviding
    private let eventSink: SystemEventSink
    private let nativePurchaseAdapter: any NativeStoreKitPurchasing
    private let introEligibilityTokenProvider: any IntroEligibilityTokenProviding
    private let introEligibilityOverrideHealth: IntroEligibilityOverrideHealth
    private let featureService: FeatureServiceProtocol?
    private let testStore: (any NuxieTestStorePurchasing)?

    /// Purchase delegate from configuration (injected, not reached through
    /// the NuxieSDK singleton)
    private var purchaseDelegate: NuxiePurchaseDelegate? {
        settings.purchaseDelegate()
    }

    private let pendingPurchaseStore: PendingPurchaseStoreProtocol
    private let dateProvider: DateProviderProtocol
    private let identityService: IdentityServiceProtocol?

    /// How long an unresolved deferred-purchase marker stays valid. Ask-to-Buy
    /// approvals can take days; StoreKit's own pending window is bounded, so a
    /// marker that has not resolved after 30 days is stale (the deferred
    /// transaction was declined or expired) and must not resolve a much later
    /// organic purchase as "deferred".
    static let pendingPurchaseTTL: TimeInterval = 30 * 24 * 3600

    /// Product ids with an Ask-to-Buy/SCA purchase awaiting approval, mapped
    /// to when the purchase deferred. When the deferred transaction later
    /// arrives via Transaction.updates — often in a LATER app launch — the
    /// observer consumes the entry and emits \$purchase_completed so the
    /// waiting paywall/journey resolves. Durable: persisted through
    /// `pendingPurchaseStore`, loaded lazily on first access, pruned by TTL.
    private var cachedPendingPurchases: [String: PendingPurchaseRecord]?

    private func pendingKey(productId: String) -> String {
        let customer = identityService?.getDistinctId() ?? "anonymous"
        return "\(customer)::\(productId)"
    }

    /// Called by TransactionObserver when a transaction lands for a product
    /// that had a pending (deferred) purchase. Returns true exactly once.
    func consumePendingPurchase(productId: String) -> Bool {
        var entries = pendingPurchases()
        guard let key = pendingEntry(productId: productId)?.key else {
            return false
        }
        entries.removeValue(forKey: key)
        setPendingPurchases(entries)
        return true
    }

    /// Returns the local access mapping captured when a native purchase became
    /// pending. The marker is consumed only after the verified transaction has
    /// been durably recorded and synced.
    func pendingPurchaseGrants(productId: String) -> [StoredLocalEntitlementGrant]? {
        pendingEntry(productId: productId)?.record.localEntitlementGrants
    }

    func pendingPurchaseDistinctId(productId: String) -> String? {
        pendingEntry(productId: productId)?.record.distinctId
    }

    private func pendingEntry(productId: String) -> (key: String, record: PendingPurchaseRecord)? {
        let entries = pendingPurchases()
        let currentKey = pendingKey(productId: productId)
        if let record = entries[currentKey] {
            return (currentKey, record)
        }
        return entries.first { key, _ in key.hasSuffix("::\(productId)") }
            .map { ($0.key, $0.value) }
    }

    /// The current (TTL-pruned) marker set, loading from disk on first use.
    private func pendingPurchases() -> [String: PendingPurchaseRecord] {
        let loaded = cachedPendingPurchases ?? pendingPurchaseStore.load()
        let cutoff = dateProvider.date(
            byAddingTimeInterval: -Self.pendingPurchaseTTL, to: dateProvider.now()
        )
        let pruned = loaded.filter { $0.value.recordedAt > cutoff }
        if pruned.count != loaded.count {
            setPendingPurchases(pruned)
        } else {
            cachedPendingPurchases = pruned
        }
        return pruned
    }

    private func setPendingPurchases(_ entries: [String: PendingPurchaseRecord]) {
        cachedPendingPurchases = entries
        pendingPurchaseStore.save(entries)
    }

    init(
        productService: ProductService,
        transactionObserver: TransactionObserverProtocol,
        pendingPurchaseStore: PendingPurchaseStoreProtocol,
        dateProvider: DateProviderProtocol,
        settings: PurchaseSettingsProviding,
        eventSink: SystemEventSink,
        identityService: IdentityServiceProtocol? = nil,
        introEligibilityTokenProvider: any IntroEligibilityTokenProviding =
            UnavailableIntroEligibilityTokenProvider(),
        introEligibilityOverrideHealth: IntroEligibilityOverrideHealth =
            IntroEligibilityOverrideHealth(),
        nativePurchaseAdapter: any NativeStoreKitPurchasing = NativeStoreKitPurchaseAdapter(),
        featureService: FeatureServiceProtocol? = nil,
        testStore: (any NuxieTestStorePurchasing)? = nil
    ) {
        self.productService = productService
        self.transactionObserver = transactionObserver
        self.pendingPurchaseStore = pendingPurchaseStore
        self.dateProvider = dateProvider
        self.settings = settings
        self.eventSink = eventSink
        self.identityService = identityService
        self.introEligibilityTokenProvider = introEligibilityTokenProvider
        self.introEligibilityOverrideHealth = introEligibilityOverrideHealth
        self.nativePurchaseAdapter = nativePurchaseAdapter
        self.featureService = featureService
        self.testStore = testStore
    }
    
    /// Purchase a product
    /// - Parameter product: The exact StoreProduct retained after presentation.
    /// - Throws: StoreKitError when checkout does not complete.
    @discardableResult
    public func purchase(_ product: StoreProduct) async throws -> PurchaseSyncResult {
        LogDebug("TransactionService: Starting purchase for product: \(product.productId)")

        let checkoutProduct: StoreProduct
        let outcome: NativePurchaseResult
        var testStoreTransactionId: String?
        let usesTestStore = testStore != nil
        let usesNativeStoreKit = purchaseDelegate == nil && !usesTestStore
        if let testStore {
            await testStore.setActiveDistinctId(identityService?.getDistinctId() ?? "anonymous")
            checkoutProduct = product
            let response = await testStore.purchase(product: product)
            outcome = response.result
            testStoreTransactionId = response.transactionId
        } else {
            let checkoutToken = try await checkoutIntroEligibilityToken(for: product)
            let currentProduct = try await refreshForCheckout(
                product,
                checkoutIntroEligibilityToken: checkoutToken
            )
            checkoutProduct = currentProduct.preparedForCheckout(
                introEligibilityToken: checkoutToken
            )
            testStoreTransactionId = nil

            if let delegate = purchaseDelegate {
                switch await delegate.purchase(product: checkoutProduct) {
                case .purchased:
                    outcome = .purchased(nil)
                case .cancelled:
                    outcome = .cancelled
                case .failed(let error):
                    outcome = checkoutProduct.introEligibilityTokenRequest != nil
                        && invalidatesIntroEligibilityOverride(error)
                        ? .invalidEligibilityOverride(error)
                        : .failed(error)
                case .pending:
                    outcome = .pending
                }
            } else {
                outcome = await nativePurchaseAdapter.purchase(product: checkoutProduct)
            }
        }

        switch outcome {
        case .purchased(let evidence):
            if let evidence {
                guard await transactionObserver.recordVerifiedPurchase(
                    evidence: evidence,
                    product: checkoutProduct
                ) else {
                    throw StoreKitError.purchaseFailed(nil)
                }
                if settings.purchaseHandlingMode() != .observer {
                    await evidence.finish()
                }
            } else if usesTestStore {
                await featureService?.applyLocalPurchase(
                    grants: checkoutProduct.localEntitlementGrants,
                    transactionId: testStoreTransactionId
                        ?? "nuxie-test-\(checkoutProduct.productId)",
                    observedAt: dateProvider.now()
                )
            }
            LogInfo("TransactionService: Purchase completed successfully for product: \(product.productId)")
            var properties: [String: Any] = [
                "product_id": product.productId,
                "placement_id": product.placementId,
                "store_product_id": product.storeProductId,
                "display_price": product.price,
                "test_store": usesTestStore
            ]
            if let price = product.appStoreProduct?.price {
                properties["price"] = NSDecimalNumber(decimal: price).doubleValue
            }
            eventSink.emit(SystemEventNames.purchaseCompleted, properties: properties)

            var syncTask: Task<Bool, Never>?
            if usesTestStore {
                return PurchaseSyncResult()
            }
            if let evidence {
                syncTask = Task {
                    let synced = await transactionObserver.syncTransaction(
                        transactionJws: evidence.transactionJws,
                        transactionId: evidence.transactionId,
                        productId: evidence.productId,
                        originalTransactionId: evidence.originalTransactionId
                    )
                    if synced {
                        LogInfo("TransactionService: Purchase synced successfully for product: \(product.productId)")
                    }
                    return synced
                }
            }

            return PurchaseSyncResult(syncTask: syncTask)
            
        case .alreadyOwned:
            LogInfo("TransactionService: Product already owned; reconciling access for \(product.productId)")
            if usesNativeStoreKit {
                await transactionObserver.syncCurrentEntitlements()
            }
            eventSink.emit(SystemEventNames.purchaseFailed, properties: [
                "product_id": product.productId,
                "placement_id": product.placementId,
                "store_product_id": product.storeProductId,
                "reason": "already_owned"
            ])
            return PurchaseSyncResult()

        case .subscriptionChangeRequired:
            let error = StoreKitError.subscriptionChangeRequired(product.storeProductId)
            LogInfo("TransactionService: Subscription change required for product: \(product.productId)")
            eventSink.emit(SystemEventNames.purchaseFailed, properties: [
                "product_id": product.productId,
                "placement_id": product.placementId,
                "store_product_id": product.storeProductId,
                "reason": "subscription_change_required"
            ])
            throw error

        case .cancelled:
            LogInfo("TransactionService: Purchase cancelled by user for product: \(product.productId)")
            throw StoreKitError.purchaseCancelled
            
        case .failed(let error):
            if usesNativeStoreKit {
                await productService.invalidate([product.storeProductId])
            }
            LogError("TransactionService: Purchase failed for product: \(product.productId), error: \(error)")
            // Track failed purchase event
            eventSink.emit(SystemEventNames.purchaseFailed, properties: [
                "product_id": product.productId,
                "placement_id": product.placementId,
                "store_product_id": product.storeProductId,
                "error": error.localizedDescription
            ])
            throw StoreKitError.purchaseFailed(error)
            
        case .pending:
            LogInfo("TransactionService: Purchase pending for product: \(product.productId)")
            // Native StoreKit owns deferred-transaction recovery. A configured
            // delegate/provider owns its own pending state and will report the
            // eventual outcome through its entitlement/receipt system.
            if usesNativeStoreKit {
                var entries = pendingPurchases()
                entries[pendingKey(productId: product.storeProductId)] = PendingPurchaseRecord(
                    distinctId: identityService?.getDistinctId() ?? "anonymous",
                    recordedAt: dateProvider.now(),
                    localEntitlementGrants: product.localEntitlementGrants.map {
                        StoredLocalEntitlementGrant(
                            featureId: $0.featureId,
                            featureExternalId: $0.featureExternalId,
                            allowanceType: $0.allowanceType,
                            allowance: $0.allowance
                        )
                    }
                )
                setPendingPurchases(entries)
            }
            throw StoreKitError.purchasePending

        case .invalidEligibilityOverride(let error):
            if let request = checkoutProduct.introEligibilityTokenRequest {
                await introEligibilityOverrideHealth.suppress(request)
            }
            await productService.invalidate([product.storeProductId])
            eventSink.emit(SystemEventNames.purchaseFailed, properties: [
                "product_id": product.productId,
                "placement_id": product.placementId,
                "store_product_id": product.storeProductId,
                "reason": "invalid_introductory_eligibility",
            ])
            throw StoreKitError.purchaseFailed(error)
        }
    }

    private func checkoutIntroEligibilityToken(
        for shown: StoreProduct
    ) async throws -> String? {
        guard let request = shown.introEligibilityTokenRequest else { return nil }
        do {
            guard let token = normalizedCompactJWS(
                try await introEligibilityTokenProvider.token(for: request)
            ) else {
                throw StoreKitError.productTermsChanged(shown.storeProductId)
            }
            return token
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw StoreKitError.productTermsChanged(shown.storeProductId)
        }
    }

    private func refreshForCheckout(
        _ shown: StoreProduct,
        checkoutIntroEligibilityToken: String?
    ) async throws -> StoreProduct {
        guard let context = shown.resolutionContext else { return shown }
        do {
            await productService.invalidate([shown.storeProductId])
            let fetched = try await productService.fetchProducts(for: [shown.storeProductId])
            guard fetched.count == 1, let native = fetched.first else {
                throw StoreKitError.productNotFound(shown.storeProductId)
            }
            var refreshed = try await StoreProductResolver(
                tokenProvider: introEligibilityTokenProvider,
                overrideHealth: introEligibilityOverrideHealth
            ).resolve(
                experienceVersionId: context.experienceVersionId,
                authorization: context.authorization,
                productId: shown.productId,
                placementId: shown.placementId,
                productType: shown.productType,
                appStoreProduct: native,
                options: context.options,
                checkoutIntroEligibilityToken: checkoutIntroEligibilityToken
            )
            refreshed.localEntitlementGrants = shown.localEntitlementGrants
            guard refreshed == shown,
                  refreshed.introEligibilityTokenRequest
                    == shown.introEligibilityTokenRequest else {
                throw StoreKitError.productTermsChanged(shown.storeProductId)
            }
            return refreshed
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw StoreKitError.productTermsChanged(shown.storeProductId)
        }
    }
    
    /// Restore previous purchases
    /// - Throws: StoreKitError when restore fails.
    public func restore() async throws {
        LogDebug("TransactionService: Starting restore purchases")

        let result: RestoreResult
        var testStoreProducts: [StoreProduct] = []
        let usesTestStore = testStore != nil
        if let testStore {
            await testStore.setActiveDistinctId(identityService?.getDistinctId() ?? "anonymous")
            let response = await testStore.restorePurchases()
            result = response.result
            testStoreProducts = response.products
        } else if let delegate = purchaseDelegate {
            result = await delegate.restorePurchases()
        } else {
            result = await nativePurchaseAdapter.restorePurchases()
        }
        
        switch result {
        case .restored:
            LogInfo("TransactionService: Restore completed successfully")
            if usesTestStore {
                for product in testStoreProducts {
                    await featureService?.applyLocalPurchase(
                        grants: product.localEntitlementGrants,
                        transactionId: "nuxie-test-restore-\(product.productId)",
                        observedAt: dateProvider.now()
                    )
                }
            }
            // Restored transactions do not re-emit through Transaction.updates,
            // so sync current entitlements to the backend explicitly — otherwise
            // a restore on a new device never updates server-side entitlements.
            if purchaseDelegate == nil && !usesTestStore {
                await transactionObserver.syncCurrentEntitlements()
            }
            // Track successful restore event
            eventSink.emit(SystemEventNames.restoreCompleted, properties: usesTestStore
                ? ["test_store": true]
                : nil)
            
        case .failed(let error):
            LogError("TransactionService: Restore failed, error: \(error)")
            // Track failed restore event
            eventSink.emit(SystemEventNames.restoreFailed, properties: [
                "error": error.localizedDescription,
                "test_store": usesTestStore
            ])
            throw StoreKitError.restoreFailed(error)
            
        case .noPurchases:
            LogInfo("TransactionService: No purchases to restore")
            // Track no purchases event
            eventSink.emit(SystemEventNames.restoreNoPurchases, properties: usesTestStore
                ? ["test_store": true]
                : nil)
        }
    }
}
