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

    /// Product ids with an Ask-to-Buy/SCA purchase awaiting approval. When
    /// the deferred transaction later arrives via Transaction.updates, the
    /// observer consumes the entry and emits \$purchase_completed so the
    /// waiting paywall resolves.
    private var pendingPurchaseProductIds: Set<String> = []

    /// Called by TransactionObserver when a transaction lands for a product
    /// that had a pending (deferred) purchase. Returns true exactly once.
    func consumePendingPurchase(productId: String) -> Bool {
        pendingPurchaseProductIds.remove(productId) != nil
    }

    init(
        productService: ProductService,
        transactionObserver: TransactionObserverProtocol,
        configurationProvider: @escaping () -> NuxieConfiguration
    ) {
        self.productService = productService
        self.transactionObserver = transactionObserver
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
            NuxieSDK.shared.trigger("$purchase_completed", properties: [
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
            NuxieSDK.shared.trigger("$purchase_failed", properties: [
                "product_id": product.id,
                "error": error.localizedDescription
            ])
            throw StoreKitError.purchaseFailed(error)
            
        case .pending:
            LogInfo("TransactionService: Purchase pending for product: \(product.id)")
            pendingPurchaseProductIds.insert(product.id)
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
            NuxieSDK.shared.trigger("$restore_completed", properties: [
                "restored_count": restoredCount
            ])
            
        case .failed(let error):
            LogError("TransactionService: Restore failed, error: \(error)")
            // Track failed restore event
            NuxieSDK.shared.trigger("$restore_failed", properties: [
                "error": error.localizedDescription
            ])
            throw StoreKitError.restoreFailed(error)
            
        case .noPurchases:
            LogInfo("TransactionService: No purchases to restore")
            // Track no purchases event
            NuxieSDK.shared.trigger("$restore_no_purchases")
        }
    }
}
