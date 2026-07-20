import Foundation
import StoreKit
import Nuxie

/// Mock implementation of NuxiePurchaseDelegate for testing
public class MockPurchaseDelegate: NuxiePurchaseDelegate {

    // MARK: - Configuration Properties

    /// Set this to control what purchase() returns
    public var purchaseResult: PurchaseResult = .success

    /// Set this to control what restore() returns
    public var restoreResult: RestoreResult = .success(restoredCount: 0)

    /// Override purchaseOutcome when you need transaction data
    public var purchaseOutcomeOverride: PurchaseOutcome?

    /// Delay in seconds before returning results (simulates network delay)
    public var simulatedDelay: TimeInterval = 0.5

    /// Should throw an error before returning result
    public var shouldThrowError: Bool = false

    /// Custom error to throw
    public var customError: Error = StoreKitError.networkUnavailable

    // MARK: - Tracking Properties

    /// Track if purchase was called
    public private(set) var purchaseCalled = false

    /// Track the last product that was attempted to purchase
    public private(set) var lastPurchasedProduct: (any StoreProductProtocol)?

    /// Track if restore was called
    public private(set) var restoreCalled = false

    /// Track number of purchase attempts
    public private(set) var purchaseCallCount = 0

    /// Track number of restore attempts
    public private(set) var restoreCallCount = 0

    // MARK: - Initialization

    public init() {}

    // MARK: - NuxiePurchaseDelegate Implementation

    public func purchase(_ product: any StoreProductProtocol) async -> PurchaseResult {
        purchaseCalled = true
        purchaseCallCount += 1
        lastPurchasedProduct = product

        // Simulate network delay if configured
        if simulatedDelay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(simulatedDelay * 1_000_000_000))
        }

        // Throw error if configured
        if shouldThrowError {
            // We can't throw from this method, so return failed instead
            return .failed(customError)
        }
        return purchaseResult
    }

    public func purchaseOutcome(_ product: any StoreProductProtocol) async -> PurchaseOutcome {
        if let override = purchaseOutcomeOverride {
            return override
        }
        let result = await purchase(product)
        return PurchaseOutcome(result: result, productId: product.id)
    }

    public func restore() async -> RestoreResult {
        restoreCalled = true
        restoreCallCount += 1

        // Simulate network delay if configured
        if simulatedDelay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(simulatedDelay * 1_000_000_000))
        }

        // Throw error if configured
        if shouldThrowError {
            // We can't throw from this method, so return failed instead
            return .failed(customError)
        }
        return restoreResult
    }

    // MARK: - Helper Methods for Testing

    /// Reset all tracking properties
    public func reset() {
        purchaseCalled = false
        lastPurchasedProduct = nil
        restoreCalled = false
        purchaseCallCount = 0
        restoreCallCount = 0
        purchaseResult = .success
        restoreResult = .success(restoredCount: 0)
        purchaseOutcomeOverride = nil
        simulatedDelay = 0.5
        shouldThrowError = false
        customError = StoreKitError.networkUnavailable
    }

    /// Configure to simulate successful purchase
    public func configureForSuccess() {
        purchaseResult = .success
        restoreResult = .success(restoredCount: 2)
        shouldThrowError = false
    }

    /// Configure to simulate cancelled purchase
    public func configureForCancellation() {
        purchaseResult = .cancelled
        shouldThrowError = false
    }

    /// Configure to simulate failed purchase
    public func configureForFailure(error: Error? = nil) {
        let errorToUse = error ?? StoreKitError.purchaseFailed(nil)
        purchaseResult = .failed(errorToUse)
        restoreResult = .failed(errorToUse)
        shouldThrowError = false
    }

    /// Configure to simulate pending purchase (parental approval, etc.)
    public func configureForPending() {
        purchaseResult = .pending
        shouldThrowError = false
    }

    /// Configure to simulate no purchases to restore
    public func configureForNoPurchases() {
        restoreResult = .noPurchases
        shouldThrowError = false
    }
}
