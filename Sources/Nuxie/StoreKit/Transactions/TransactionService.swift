import Foundation
import StoreKit

public struct PurchaseSyncResult {
    public let syncTask: Task<Bool, Never>?

    public init(syncTask: Task<Bool, Never>? = nil) {
        self.syncTask = syncTask
    }
}

/// Service responsible for managing StoreKit transactions
public actor TransactionService {
    private let productService: ProductService
    private let transactionObserver: TransactionObserverProtocol
    /// A provider, not a value, so a re-setup's fresh configuration is
    /// always honored.
    private let configurationProvider: () -> NuxieConfiguration
    private var configuration: NuxieConfiguration {
        configurationProvider()
    }

    /// Purchase delegate from configuration (injected, not reached through
    /// the NuxieSDK singleton)
    private var purchaseDelegate: NuxiePurchaseDelegate? {
        configuration.purchaseDelegate
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
        configurationProvider: @escaping () -> NuxieConfiguration
    ) {
        self.productService = productService
        self.transactionObserver = transactionObserver
        self.pendingPurchaseStore = pendingPurchaseStore
        self.dateProvider = dateProvider
        self.configurationProvider = configurationProvider
    }
    
    /// Purchase a product
    /// - Parameter product: The product to purchase
    /// - Throws: StoreKitError if purchase fails or delegate not configured
    @discardableResult
    public func purchase(_ product: any StoreProductProtocol) async throws -> PurchaseSyncResult {
        guard let delegate = purchaseDelegate else {
            LogError("TransactionService: No purchase delegate configured")
            throw StoreKitError.notConfigured
        }
        
        LogDebug("TransactionService: Starting purchase for product: \(product.id)")
        
        let outcome = await delegate.purchaseOutcome(product)

        switch outcome.result {
        case .success:
            LogInfo("TransactionService: Purchase completed successfully for product: \(product.id)")
            // Track immediate UI success
            NuxieSDK.shared.trigger(SystemEventNames.purchaseCompleted, properties: [
                "product_id": product.id,
                "price": NSDecimalNumber(decimal: product.price).doubleValue,
                "display_price": product.displayPrice
            ])

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
            NuxieSDK.shared.trigger(SystemEventNames.purchaseFailed, properties: [
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
            NuxieSDK.shared.trigger(SystemEventNames.restoreCompleted, properties: [
                "restored_count": restoredCount
            ])
            
        case .failed(let error):
            LogError("TransactionService: Restore failed, error: \(error)")
            // Track failed restore event
            NuxieSDK.shared.trigger(SystemEventNames.restoreFailed, properties: [
                "error": error.localizedDescription
            ])
            throw StoreKitError.restoreFailed(error)
            
        case .noPurchases:
            LogInfo("TransactionService: No purchases to restore")
            // Track no purchases event
            NuxieSDK.shared.trigger(SystemEventNames.restoreNoPurchases)
        }
    }
}
