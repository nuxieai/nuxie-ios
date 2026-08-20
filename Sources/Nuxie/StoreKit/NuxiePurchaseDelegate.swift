import Foundation

/// The result of launching checkout for the StoreProduct shown to the customer.
public enum PurchaseResult: Equatable, Sendable {
    /// Checkout completed successfully.
    case purchased
    /// The customer cancelled checkout.
    case cancelled
    /// Checkout failed.
    case failed(Error)
    /// The store deferred completion, for example for Ask to Buy approval.
    case pending
    
    public static func == (lhs: PurchaseResult, rhs: PurchaseResult) -> Bool {
        switch (lhs, rhs) {
        case (.purchased, .purchased):
            return true
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
    /// Restore completed and found one or more purchases.
    case restored
    /// Restore failed.
    case failed(Error)
    /// Restore completed and found no current purchases.
    case noPurchases
    
    public static func == (lhs: RestoreResult, rhs: RestoreResult) -> Bool {
        switch (lhs, rhs) {
        case (.restored, .restored):
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
