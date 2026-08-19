import Foundation
@testable import Nuxie

public final class MockNativeStoreKitPurchaseAdapter:
    NativeStoreKitPurchasing,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var purchaseResultStorage: NativePurchaseResult = .cancelled
    private var restoreResultStorage: NativeRestoreResult = .noPurchases
    private var purchasedProductsStorage: [StoreProduct] = []
    private var restoreCallCountStorage = 0
    private var finishCallCountStorage = 0

    var purchaseResult: NativePurchaseResult {
        get { lock.withLock { purchaseResultStorage } }
        set { lock.withLock { purchaseResultStorage = newValue } }
    }

    public var restoreResult: NativeRestoreResult {
        get { lock.withLock { restoreResultStorage } }
        set { lock.withLock { restoreResultStorage = newValue } }
    }

    public var purchasedProducts: [StoreProduct] {
        lock.withLock { purchasedProductsStorage }
    }

    public var restoreCallCount: Int {
        lock.withLock { restoreCallCountStorage }
    }

    public var finishCallCount: Int {
        lock.withLock { finishCallCountStorage }
    }

    public init() {}

    public func configurePurchased() {
        purchaseResult = .purchased(nil)
    }

    public func configureVerifiedPurchase(
        transactionJws: String = "transaction-jws",
        transactionId: String = "transaction-id",
        originalTransactionId: String = "original-id",
        productId: String = "store-product"
    ) {
        purchaseResult = .purchased(StoreTransactionEvidence(
            transactionJws: transactionJws,
            transactionId: transactionId,
            originalTransactionId: originalTransactionId,
            productId: productId,
            finish: { [weak self] in
                self?.lock.withLock {
                    self?.finishCallCountStorage += 1
                }
            }
        ))
    }

    public func configureCancelled() {
        purchaseResult = .cancelled
    }

    public func configurePending() {
        purchaseResult = .pending
    }

    public func configureFailed(_ error: Error) {
        purchaseResult = .failed(error)
    }

    public func configureInvalidEligibilityOverride(_ error: Error) {
        purchaseResult = .invalidEligibilityOverride(error)
    }

    public func configureAlreadyOwned() {
        purchaseResult = .alreadyOwned
    }

    public func configureSubscriptionChangeRequired() {
        purchaseResult = .subscriptionChangeRequired
    }

    public func purchase(product: StoreProduct) async -> NativePurchaseResult {
        lock.withLock {
            purchasedProductsStorage.append(product)
            return purchaseResultStorage
        }
    }

    public func restorePurchases() async -> NativeRestoreResult {
        lock.withLock {
            restoreCallCountStorage += 1
            return restoreResultStorage
        }
    }
}
