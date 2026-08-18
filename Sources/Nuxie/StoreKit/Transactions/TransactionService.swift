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

    /// Purchase delegate from configuration (injected, not reached through
    /// the NuxieSDK singleton)
    private var purchaseDelegate: NuxiePurchaseDelegate? {
        settings.purchaseDelegate()
    }

    private let pendingPurchaseStore: PendingPurchaseStoreProtocol
    private let dateProvider: DateProviderProtocol

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
    private var cachedPendingPurchases: [String: Date]?

    /// Called by TransactionObserver when a transaction lands for a product
    /// that had a pending (deferred) purchase. Returns true exactly once.
    func consumePendingPurchase(productId: String) -> Bool {
        var entries = pendingPurchases()
        guard entries.removeValue(forKey: productId) != nil else { return false }
        setPendingPurchases(entries)
        return true
    }

    /// The current (TTL-pruned) marker set, loading from disk on first use.
    private func pendingPurchases() -> [String: Date] {
        let loaded = cachedPendingPurchases ?? pendingPurchaseStore.load()
        let cutoff = dateProvider.date(
            byAddingTimeInterval: -Self.pendingPurchaseTTL, to: dateProvider.now()
        )
        let pruned = loaded.filter { $0.value > cutoff }
        if pruned.count != loaded.count {
            setPendingPurchases(pruned)
        } else {
            cachedPendingPurchases = pruned
        }
        return pruned
    }

    private func setPendingPurchases(_ entries: [String: Date]) {
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
        nativePurchaseAdapter: any NativeStoreKitPurchasing = NativeStoreKitPurchaseAdapter()
    ) {
        self.productService = productService
        self.transactionObserver = transactionObserver
        self.pendingPurchaseStore = pendingPurchaseStore
        self.dateProvider = dateProvider
        self.settings = settings
        self.eventSink = eventSink
        self.nativePurchaseAdapter = nativePurchaseAdapter
    }
    
    /// Purchase a product
    /// - Parameter product: The exact StoreProduct retained after presentation.
    /// - Throws: StoreKitError when checkout does not complete.
    @discardableResult
    public func purchase(_ product: StoreProduct) async throws -> PurchaseSyncResult {
        LogDebug("TransactionService: Starting purchase for product: \(product.productId)")

        let outcome: NativePurchaseResult
        let usesNativeStoreKit = purchaseDelegate == nil
        if let delegate = purchaseDelegate {
            switch await delegate.purchase(product: product) {
            case .purchased:
                outcome = .purchased(nil)
            case .cancelled:
                outcome = .cancelled
            case .failed(let error):
                outcome = .failed(error)
            case .pending:
                outcome = .pending
            }
        } else {
            outcome = await nativePurchaseAdapter.purchase(product: product)
        }

        switch outcome {
        case .purchased(let evidence):
            LogInfo("TransactionService: Purchase completed successfully for product: \(product.productId)")
            var properties: [String: Any] = [
                "product_id": product.productId,
                "placement_id": product.placementId,
                "store_product_id": product.storeProductId,
                "display_price": product.price
            ]
            if let price = product.appStoreProduct?.price {
                properties["price"] = NSDecimalNumber(decimal: price).doubleValue
            }
            eventSink.emit(SystemEventNames.purchaseCompleted, properties: properties)

            var syncTask: Task<Bool, Never>?
            if let evidence {
                syncTask = Task {
                    let synced = await transactionObserver.syncTransaction(
                        transactionJws: evidence.transactionJws,
                        transactionId: evidence.transactionId,
                        productId: evidence.productId,
                        originalTransactionId: evidence.originalTransactionId
                    )
                    if synced {
                        await evidence.finish()
                        LogInfo("TransactionService: Purchase synced successfully for product: \(product.productId)")
                    }
                    return synced
                }
            }

            return PurchaseSyncResult(syncTask: syncTask)
            
        case .alreadyOwned:
            LogInfo("TransactionService: Product already owned; reconciling access for \(product.productId)")
            await transactionObserver.syncCurrentEntitlements()
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
            var entries = pendingPurchases()
            entries[product.storeProductId] = dateProvider.now()
            setPendingPurchases(entries)
            throw StoreKitError.purchasePending
        }
    }
    
    /// Restore previous purchases
    /// - Throws: StoreKitError when restore fails.
    public func restore() async throws {
        LogDebug("TransactionService: Starting restore purchases")

        let result: RestoreResult
        if let delegate = purchaseDelegate {
            result = await delegate.restorePurchases()
        } else {
            result = await nativePurchaseAdapter.restorePurchases()
        }
        
        switch result {
        case .restored:
            LogInfo("TransactionService: Restore completed successfully")
            // Restored transactions do not re-emit through Transaction.updates,
            // so sync current entitlements to the backend explicitly — otherwise
            // a restore on a new device never updates server-side entitlements.
            await transactionObserver.syncCurrentEntitlements()
            // Track successful restore event
            eventSink.emit(SystemEventNames.restoreCompleted, properties: nil)
            
        case .failed(let error):
            LogError("TransactionService: Restore failed, error: \(error)")
            // Track failed restore event
            eventSink.emit(SystemEventNames.restoreFailed, properties: [
                "error": error.localizedDescription
            ])
            throw StoreKitError.restoreFailed(error)
            
        case .noPurchases:
            LogInfo("TransactionService: No purchases to restore")
            // Track no purchases event
            eventSink.emit(SystemEventNames.restoreNoPurchases, properties: nil)
        }
    }
}
