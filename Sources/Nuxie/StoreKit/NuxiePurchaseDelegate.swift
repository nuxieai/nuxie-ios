import Foundation

/// Verified StoreKit evidence returned by a purchase delegate that performs
/// native StoreKit checkout itself. Nuxie records and syncs this evidence
/// before invoking `finish`, so a provider bridge cannot strand a successful
/// native transaction outside Nuxie's entitlement pipeline.
public struct StoreKitPurchaseEvidence: Sendable {
    public let transactionJws: String
    public let transactionId: String
    public let originalTransactionId: String
    public let productId: String
    public let finish: @Sendable () async -> Void

    public init(
        transactionJws: String,
        transactionId: String,
        originalTransactionId: String,
        productId: String,
        finish: @escaping @Sendable () async -> Void
    ) {
        self.transactionJws = transactionJws
        self.transactionId = transactionId
        self.originalTransactionId = originalTransactionId
        self.productId = productId
        self.finish = finish
    }
}
/// The result of launching checkout for the StoreProduct shown to the customer.
public enum PurchaseResult: Equatable, Sendable {
    /// The configured provider completed the purchase and remains responsible
    /// for receipt submission, transaction finishing, and durable access.
    case providerPurchased
    /// A delegate completed native StoreKit checkout and returned verified
    /// evidence for Nuxie to record, sync, and finish.
    case purchasedWithStoreKitEvidence(StoreKitPurchaseEvidence)
    /// The customer cancelled checkout.
    case cancelled
    /// Checkout failed.
    case failed(Error)
    /// The store deferred completion, for example for Ask to Buy approval.
    case pending
    
    public static func == (lhs: PurchaseResult, rhs: PurchaseResult) -> Bool {
        switch (lhs, rhs) {
        case (.providerPurchased, .providerPurchased):
            return true
        case (.purchasedWithStoreKitEvidence(let lhs), .purchasedWithStoreKitEvidence(let rhs)):
            return lhs.transactionJws == rhs.transactionJws
                && lhs.transactionId == rhs.transactionId
                && lhs.originalTransactionId == rhs.originalTransactionId
                && lhs.productId == rhs.productId
        case (.cancelled, .cancelled):
            return true
        case (.pending, .pending):
            return true
        case (.failed(let lhsError), .failed(let rhsError)):
            return (lhsError as NSError) == (rhsError as NSError)
        default:
            return false
        }
    }
}

/// The result of asking the configured purchase system to restore purchases.
public enum RestoreResult: Equatable, Sendable {
    /// The configured provider restored its purchases and remains the source
    /// of truth for receipt and entitlement state.
    case providerRestored
    /// A custom StoreKit delegate completed `AppStore.sync()`. Nuxie must now
    /// submit the current verified StoreKit entitlements to its backend.
    case storeKitRestored
    /// Restore failed.
    case failed(Error)
    /// Restore completed and found no current purchases.
    case noPurchases
    
    public static func == (lhs: RestoreResult, rhs: RestoreResult) -> Bool {
        switch (lhs, rhs) {
        case (.providerRestored, .providerRestored):
            return true
        case (.storeKitRestored, .storeKitRestored):
            return true
        case (.noPurchases, .noPurchases):
            return true
        case (.failed(let lhsError), .failed(let rhsError)):
            return (lhsError as NSError) == (rhsError as NSError)
        default:
            return false
        }
    }
}

/// Optional checkout seam for RevenueCat, Superwall, or a custom billing stack.
///
/// When this delegate is nil, Nuxie purchases and restores with StoreKit.
public protocol NuxiePurchaseDelegate: AnyObject, Sendable {
    /// Purchases the exact StoreProduct retained after paywall presentation.
    /// Nuxie refreshes signed eligibility immediately before this call; a
    /// custom StoreKit implementation must pass `storeKitPurchaseOptions` to
    /// `rawProduct.purchase(options:)`.
    func purchase(product: StoreProduct) async -> PurchaseResult

    /// Restores purchases through the same billing system used by this delegate.
    func restorePurchases() async -> RestoreResult
}
