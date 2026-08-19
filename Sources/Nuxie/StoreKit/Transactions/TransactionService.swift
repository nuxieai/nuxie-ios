import Foundation
import StoreKit

func optimisticLocalEntitlementGrants(
    _ grants: [StoreProduct.LocalEntitlementGrant]
) -> [StoreProduct.LocalEntitlementGrant] {
    grants.filter {
        let allowanceType = $0.allowanceType?.lowercased()
        // Boolean ownership can be proven from the signed Product mapping.
        // Quotas and credits remain server-authoritative because a local
        // retry cannot safely determine their current balance.
        return allowanceType == nil
            || allowanceType == "boolean"
            || allowanceType == "unlimited"
    }
}

struct PurchaseSyncResult: Sendable {
    public let syncTask: Task<Bool, Never>?

    public init(syncTask: Task<Bool, Never>? = nil) {
        self.syncTask = syncTask
    }
}

enum PendingPurchaseOwnershipResolution: Sendable {
    case none
    case unique(PendingPurchaseRecord)
    case ambiguous
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

    private func pendingKey(productId: String, distinctId: String) -> String {
        "\(distinctId)::\(productId)"
    }

    private func pendingKey(productId: String) -> String {
        pendingKey(
            productId: productId,
            distinctId: identityService?.getDistinctId() ?? "anonymous"
        )
    }

    /// Called by TransactionObserver when a transaction lands for a product
    /// that had a pending (deferred) purchase. Returns true exactly once.
    func consumePendingPurchase(productId: String, distinctId: String? = nil) -> Bool {
        var entries = pendingPurchases()
        let key: String?
        if let distinctId {
            key = "\(distinctId)::\(productId)"
        } else {
            key = pendingEntry(productId: productId)?.key
        }
        guard let key, entries[key] != nil else {
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
        pendingPurchaseRecord(productId: productId)?.localEntitlementGrants
    }

    func pendingPurchaseGrants(
        productId: String,
        distinctId: String
    ) -> [StoredLocalEntitlementGrant]? {
        pendingPurchaseRecord(productId: productId, distinctId: distinctId)?.localEntitlementGrants
    }

    func pendingPurchaseDistinctId(productId: String) -> String? {
        pendingPurchaseRecord(productId: productId)?.distinctId
    }

    /// Resolve a deferred marker only for the active customer. A product ID is
    /// not customer identity, so an orphaned marker must never be attached to
    /// a later account after logout or identify.
    func pendingPurchaseRecord(productId: String) -> PendingPurchaseRecord? {
        let entries = pendingPurchases()
        return entries[pendingKey(productId: productId)]
    }

    /// Returns the deferred marker only when it belongs to the requested
    /// customer. Transaction updates use this form after a customer switch so
    /// a pending purchase cannot resolve another customer's paywall.
    func pendingPurchaseRecord(
        productId: String,
        distinctId: String
    ) -> PendingPurchaseRecord? {
        pendingPurchases()["\(distinctId)::\(productId)"]
    }

    /// Resolve a StoreKit transaction to a deferred customer only when the
    /// durable marker set has one unambiguous owner for this store product.
    /// With multiple customers pending the same product, StoreKit's product ID
    /// alone is insufficient authority and synchronization must wait.
    func pendingPurchaseOwnership(
        productId: String
    ) -> PendingPurchaseOwnershipResolution {
        let suffix = "::\(productId)"
        let matches = pendingPurchases().filter { $0.key.hasSuffix(suffix) }
        switch matches.count {
        case 0:
            return .none
        case 1:
            guard let record = matches.first?.value else { return .none }
            return .unique(record)
        default:
            return .ambiguous
        }
    }

    private func pendingEntry(productId: String) -> (key: String, record: PendingPurchaseRecord)? {
        let entries = pendingPurchases()
        let currentKey = pendingKey(productId: productId)
        if let record = entries[currentKey] {
            return (currentKey, record)
        }
        // A product identifier is not customer identity. Never attach a
        // deferred purchase marker recorded for another customer merely
        // because both customers bought the same product.
        return nil
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

        // Checkout belongs to the customer who initiated it. Every store and
        // provider call below can suspend while identify/reset changes the
        // active SDK identity, so never re-read mutable identity for purchase
        // attribution after this point.
        let initiatingDistinctId = identityService?.getDistinctId() ?? "anonymous"
        let checkoutProduct: StoreProduct
        let outcome: NativePurchaseResult
        var testStoreTransactionId: String?
        let usesTestStore = testStore != nil
        let usesNativeStoreKit = purchaseDelegate == nil && !usesTestStore
        if let testStore {
            checkoutProduct = product
            let response = await testStore.purchase(
                product: product,
                distinctId: initiatingDistinctId
            )
            outcome = response.result
            testStoreTransactionId = response.transactionId
        } else {
            let checkoutToken = try await checkoutIntroEligibilityToken(
                for: product,
                distinctId: initiatingDistinctId
            )
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
                case .providerPurchased:
                    outcome = .purchased(nil)
                case .purchasedWithStoreKitEvidence(let evidence):
                    outcome = .purchased(StoreTransactionEvidence(
                        transactionJws: evidence.transactionJws,
                        transactionId: evidence.transactionId,
                        originalTransactionId: evidence.originalTransactionId,
                        productId: evidence.productId,
                        finish: evidence.finish
                    ))
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
                    product: checkoutProduct,
                    distinctId: initiatingDistinctId,
                    finishRequired: settings.purchaseHandlingMode() != .observer
                        || purchaseDelegate != nil
                ) else {
                    throw StoreKitError.purchaseFailed(nil)
                }
                // A delegate that returns verified StoreKit evidence has
                // explicitly transferred transaction ownership to Nuxie, so
                // finish it even when the host also uses observer mode.
                if settings.purchaseHandlingMode() != .observer || purchaseDelegate != nil {
                    await evidence.finish()
                    await transactionObserver.markTransactionFinished(
                        transactionId: evidence.transactionId
                    )
                }
            } else if usesTestStore, isActiveCustomer(initiatingDistinctId) {
                await featureService?.applyLocalPurchase(
                    grants: optimisticLocalEntitlementGrants(
                        checkoutProduct.localEntitlementGrants
                    ),
                    transactionId: testStoreTransactionId
                        ?? "nuxie-test-\(checkoutProduct.productId)"
                )
            } else if purchaseDelegate != nil,
                      isActiveCustomer(initiatingDistinctId) {
                // A connected provider owns the receipt and durable billing
                // state. Once its reviewed Product mapping is enabled, the
                // signed Product still gives us enough information to project
                // Boolean Feature Access immediately, just like RevenueCat
                // and Superwall do locally. Draft/unmapped provider imports
                // have no grants, so a delegate success cannot grant Nuxie
                // access before the explicit Feature Access cutover.
                let providerFeatureGrants = optimisticLocalEntitlementGrants(
                    checkoutProduct.localEntitlementGrants
                )
                if !providerFeatureGrants.isEmpty {
                    await featureService?.applyLocalPurchase(
                        grants: providerFeatureGrants,
                        transactionId: providerLocalAccessTransactionId(
                            storeProductId: checkoutProduct.storeProductId
                        )
                    )
                }
            }
            LogInfo("TransactionService: Purchase completed successfully for product: \(product.productId)")
            if isActiveCustomer(initiatingDistinctId) {
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
            }

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
                await transactionObserver.syncCurrentEntitlements(
                    distinctId: initiatingDistinctId
                )
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
            // Keep a durable marker for every StoreKit-capable checkout path.
            // Provider delegates may own receipt submission and finishing, but
            // the shared Transaction.updates observer still needs to correlate
            // a later Ask-to-Buy/SCA approval with the paywall action.
            if !usesTestStore && (usesNativeStoreKit || purchaseDelegate != nil) {
                var entries = pendingPurchases()
                entries[pendingKey(
                    productId: checkoutProduct.storeProductId,
                    distinctId: initiatingDistinctId
                )] =
                    PendingPurchaseRecord(
                        distinctId: initiatingDistinctId,
                        recordedAt: dateProvider.now(),
                        localEntitlementGrants: optimisticLocalEntitlementGrants(
                            checkoutProduct.localEntitlementGrants
                        ).map {
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
        for shown: StoreProduct,
        distinctId: String
    ) async throws -> String? {
        guard let request = shown.introEligibilityTokenRequest else { return nil }
        // Eligibility authority is customer-scoped. A controller can remain on
        // screen while identify/reset changes the active SDK identity, so a
        // request prepared for the previous customer must never be signed for
        // checkout under the new one.
        guard request.authorization.distinctId == distinctId else {
            throw StoreKitError.productTermsChanged(shown.storeProductId)
        }
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

    private func isActiveCustomer(_ distinctId: String) -> Bool {
        (identityService?.getDistinctId() ?? "anonymous") == distinctId
    }
    
    /// Restore previous purchases
    /// - Throws: StoreKitError when restore fails.
    public func restore() async throws {
        LogDebug("TransactionService: Starting restore purchases")

        let initiatingDistinctId = identityService?.getDistinctId() ?? "anonymous"
        enum RestoreOutcome {
            case providerRestored
            case storeKitRestored
            case testStoreRestored
            case failed(Error)
            case noPurchases
        }
        let result: RestoreOutcome
        var testStoreProducts: [StoreProduct] = []
        let usesTestStore = testStore != nil
        if let testStore {
            let response = await testStore.restorePurchases(
                distinctId: initiatingDistinctId
            )
            switch response.result {
            case .restored: result = .testStoreRestored
            case .failed(let error): result = .failed(error)
            case .noPurchases: result = .noPurchases
            }
            testStoreProducts = response.products
        } else if let delegate = purchaseDelegate {
            switch await delegate.restorePurchases() {
            case .providerRestored: result = .providerRestored
            case .storeKitRestored: result = .storeKitRestored
            case .failed(let error): result = .failed(error)
            case .noPurchases: result = .noPurchases
            }
        } else {
            switch await nativePurchaseAdapter.restorePurchases() {
            case .restored: result = .storeKitRestored
            case .failed(let error): result = .failed(error)
            case .noPurchases: result = .noPurchases
            }
        }
        
        switch result {
        case .providerRestored, .storeKitRestored, .testStoreRestored:
            LogInfo("TransactionService: Restore completed successfully")
            if usesTestStore, isActiveCustomer(initiatingDistinctId) {
                for product in testStoreProducts {
                    await featureService?.applyLocalPurchase(
                        grants: optimisticLocalEntitlementGrants(
                            product.localEntitlementGrants
                        ),
                        transactionId: "nuxie-test-restore-\(product.productId)"
                    )
                }
            }
            // Restored transactions do not re-emit through Transaction.updates,
            // so sync current entitlements to the backend explicitly — otherwise
            // a restore on a new device never updates server-side entitlements.
            if case .storeKitRestored = result,
               isActiveCustomer(initiatingDistinctId) {
                await transactionObserver.syncCurrentEntitlements(
                    distinctId: initiatingDistinctId
                )
            }
            // Track successful restore event
            if isActiveCustomer(initiatingDistinctId) {
                eventSink.emit(SystemEventNames.restoreCompleted, properties: usesTestStore
                    ? ["test_store": true]
                    : nil)
            }
            
        case .failed(let error):
            LogError("TransactionService: Restore failed, error: \(error)")
            // Track failed restore event
            if isActiveCustomer(initiatingDistinctId) {
                eventSink.emit(SystemEventNames.restoreFailed, properties: [
                    "error": error.localizedDescription,
                    "test_store": usesTestStore
                ])
            }
            throw StoreKitError.restoreFailed(error)
            
        case .noPurchases:
            LogInfo("TransactionService: No purchases to restore")
            // Track no purchases event
            if isActiveCustomer(initiatingDistinctId) {
                eventSink.emit(SystemEventNames.restoreNoPurchases, properties: usesTestStore
                    ? ["test_store": true]
                    : nil)
            }
        }
    }
}
