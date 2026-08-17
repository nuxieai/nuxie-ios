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
        eventSink: SystemEventSink
    ) {
        self.productService = productService
        self.transactionObserver = transactionObserver
        self.pendingPurchaseStore = pendingPurchaseStore
        self.dateProvider = dateProvider
        self.settings = settings
        self.eventSink = eventSink
    }
    
    /// Purchase a product
    /// - Parameter product: The product to purchase
    /// - Throws: StoreKitError if purchase fails or delegate not configured
    @discardableResult
    public func purchase(
        _ product: any StoreProductProtocol,
        offerId: String? = nil
    ) async throws -> PurchaseSyncResult {
        guard let delegate = purchaseDelegate else {
            LogError("TransactionService: No purchase delegate configured")
            throw StoreKitError.notConfigured
        }
        
        LogDebug("TransactionService: Starting purchase for product: \(product.id)")
        
        let applicableOffers = await product.applicableStoreOffers()
        let selectedOffer = offerId.flatMap { selectedId in
            applicableOffers.first(where: { $0.id == selectedId })
        }
        if let offerId, selectedOffer == nil {
            throw StoreKitError.offerUnavailable(offerId)
        }
        let outcome: PurchaseOutcome
        if let selectedOffer, selectedOffer.type != .introductory {
            guard let offerDelegate = delegate as? any NuxieStoreOfferPurchaseDelegate else {
                throw StoreKitError.offerPurchaseNotConfigured
            }
            outcome = await offerDelegate.purchaseOutcome(product, offer: selectedOffer)
        } else {
            outcome = await delegate.purchaseOutcome(product)
        }

        switch outcome.result {
        case .success:
            LogInfo("TransactionService: Purchase completed successfully for product: \(product.id)")
            // Track immediate UI success
            let chargedPrice = selectedOffer?.price ?? product.price
            let chargedDisplayPrice = selectedOffer?.displayPrice ?? product.displayPrice
            var properties: [String: Any] = [
                "product_id": product.id,
                "price": NSDecimalNumber(decimal: chargedPrice).doubleValue,
                "display_price": chargedDisplayPrice,
                "renewal_price": NSDecimalNumber(decimal: product.price).doubleValue,
                "renewal_display_price": product.displayPrice
            ]
            if let selectedOffer {
                properties["offer_id"] = selectedOffer.id
                properties["offer_type"] = selectedOffer.type.rawValue
                properties["offer_display_price"] = selectedOffer.displayPrice
            }
            eventSink.emit(SystemEventNames.purchaseCompleted, properties: properties)

            var syncTask: Task<Bool, Never>?
            if let jws = outcome.transactionJws {
                let transactionId = outcome.transactionId ?? ""
                let originalId = outcome.originalTransactionId
                syncTask = Task {
                    let synced = await transactionObserver.syncTransaction(
                        transactionJws: jws,
                        transactionId: transactionId,
                        productId: outcome.productId ?? product.id,
                        originalTransactionId: originalId
                    )
                    if synced {
                        LogInfo("TransactionService: Purchase synced successfully for product: \(product.id)")
                    }
                    return synced
                }
            }

            return PurchaseSyncResult(syncTask: syncTask)
            
        case .cancelled:
            LogInfo("TransactionService: Purchase cancelled by user for product: \(product.id)")
            throw StoreKitError.purchaseCancelled
            
        case .failed(let error):
            LogError("TransactionService: Purchase failed for product: \(product.id), error: \(error)")
            // Track failed purchase event
            eventSink.emit(SystemEventNames.purchaseFailed, properties: [
                "product_id": product.id,
                "error": error.localizedDescription
            ])
            throw StoreKitError.purchaseFailed(error)
            
        case .pending:
            LogInfo("TransactionService: Purchase pending for product: \(product.id)")
            var entries = pendingPurchases()
            entries[product.id] = dateProvider.now()
            setPendingPurchases(entries)
            throw StoreKitError.purchasePending
        }
    }
    
    /// Restore previous purchases
    /// - Throws: StoreKitError if restore fails or delegate not configured
    public func restore() async throws {
        guard let delegate = purchaseDelegate else {
            LogError("TransactionService: No purchase delegate configured for restore")
            throw StoreKitError.notConfigured
        }
        
        LogDebug("TransactionService: Starting restore purchases")
        
        let result = await delegate.restore()
        
        switch result {
        case .success(let restoredCount):
            LogInfo("TransactionService: Restore completed successfully, restored \(restoredCount) purchases")
            // Restored transactions do not re-emit through Transaction.updates,
            // so sync current entitlements to the backend explicitly — otherwise
            // a restore on a new device never updates server-side entitlements.
            await transactionObserver.syncCurrentEntitlements()
            // Track successful restore event
            eventSink.emit(SystemEventNames.restoreCompleted, properties: [
                "restored_count": restoredCount
            ])
            
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
