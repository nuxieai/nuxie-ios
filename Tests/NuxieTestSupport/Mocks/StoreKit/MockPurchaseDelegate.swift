import Foundation
import StoreKit
import Nuxie

/// Mock implementation of NuxiePurchaseDelegate for testing
// @unchecked Sendable: all mutable state is serialized through `lock`.
public final class MockPurchaseDelegate: NuxiePurchaseDelegate, @unchecked Sendable {

    private let lock = NSLock()

    // MARK: - Locked Storage

    private var _purchaseResult: PurchaseResult = .success
    private var _restoreResult: RestoreResult = .success(restoredCount: 0)
    private var _purchaseOutcomeOverride: PurchaseOutcome?
    private var _simulatedDelay: TimeInterval = 0.5
    private var _shouldThrowError: Bool = false
    private var _customError: Error = StoreKitError.networkUnavailable
    private var _purchaseCalled = false
    private var _lastPurchasedProduct: (any StoreProductProtocol)?
    private var _restoreCalled = false
    private var _purchaseCallCount = 0
    private var _restoreCallCount = 0

    // MARK: - Configuration Properties

    /// Set this to control what purchase() returns
    public var purchaseResult: PurchaseResult {
        get { lock.withLock { _purchaseResult } }
        set { lock.withLock { _purchaseResult = newValue } }
    }

    /// Set this to control what restore() returns
    public var restoreResult: RestoreResult {
        get { lock.withLock { _restoreResult } }
        set { lock.withLock { _restoreResult = newValue } }
    }

    /// Override purchaseOutcome when you need transaction data
    public var purchaseOutcomeOverride: PurchaseOutcome? {
        get { lock.withLock { _purchaseOutcomeOverride } }
        set { lock.withLock { _purchaseOutcomeOverride = newValue } }
    }

    /// Delay in seconds before returning results (simulates network delay)
    public var simulatedDelay: TimeInterval {
        get { lock.withLock { _simulatedDelay } }
        set { lock.withLock { _simulatedDelay = newValue } }
    }

    /// Should throw an error before returning result
    public var shouldThrowError: Bool {
        get { lock.withLock { _shouldThrowError } }
        set { lock.withLock { _shouldThrowError = newValue } }
    }

    /// Custom error to throw
    public var customError: Error {
        get { lock.withLock { _customError } }
        set { lock.withLock { _customError = newValue } }
    }

    // MARK: - Tracking Properties

    /// Track if purchase was called
    public var purchaseCalled: Bool {
        lock.withLock { _purchaseCalled }
    }

    /// Track the last product that was attempted to purchase
    public var lastPurchasedProduct: (any StoreProductProtocol)? {
        lock.withLock { _lastPurchasedProduct }
    }

    /// Track if restore was called
    public var restoreCalled: Bool {
        lock.withLock { _restoreCalled }
    }

    /// Track number of purchase attempts
    public var purchaseCallCount: Int {
        lock.withLock { _purchaseCallCount }
    }

    /// Track number of restore attempts
    public var restoreCallCount: Int {
        lock.withLock { _restoreCallCount }
    }

    // MARK: - Initialization

    public init() {}

    // MARK: - NuxiePurchaseDelegate Implementation

    public func purchase(_ product: any StoreProductProtocol) async -> PurchaseResult {
        let (delay, shouldThrow, error, result): (TimeInterval, Bool, Error, PurchaseResult) =
            lock.withLock {
                _purchaseCalled = true
                _purchaseCallCount += 1
                _lastPurchasedProduct = product
                return (_simulatedDelay, _shouldThrowError, _customError, _purchaseResult)
            }

        // Simulate network delay if configured
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }

        // Throw error if configured
        if shouldThrow {
            // We can't throw from this method, so return failed instead
            return .failed(error)
        }
        return result
    }

    public func purchaseOutcome(_ product: any StoreProductProtocol) async -> PurchaseOutcome {
        if let override = purchaseOutcomeOverride {
            return override
        }
        let result = await purchase(product)
        return PurchaseOutcome(result: result, productId: product.id)
    }

    public func restore() async -> RestoreResult {
        let (delay, shouldThrow, error, result): (TimeInterval, Bool, Error, RestoreResult) =
            lock.withLock {
                _restoreCalled = true
                _restoreCallCount += 1
                return (_simulatedDelay, _shouldThrowError, _customError, _restoreResult)
            }

        // Simulate network delay if configured
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }

        // Throw error if configured
        if shouldThrow {
            // We can't throw from this method, so return failed instead
            return .failed(error)
        }
        return result
    }

    // MARK: - Helper Methods for Testing

    /// Reset all tracking properties
    public func reset() {
        lock.withLock {
            _purchaseCalled = false
            _lastPurchasedProduct = nil
            _restoreCalled = false
            _purchaseCallCount = 0
            _restoreCallCount = 0
            _purchaseResult = .success
            _restoreResult = .success(restoredCount: 0)
            _purchaseOutcomeOverride = nil
            _simulatedDelay = 0.5
            _shouldThrowError = false
            _customError = StoreKitError.networkUnavailable
        }
    }

    /// Configure to simulate successful purchase
    public func configureForSuccess() {
        lock.withLock {
            _purchaseResult = .success
            _restoreResult = .success(restoredCount: 2)
            _shouldThrowError = false
        }
    }

    /// Configure to simulate cancelled purchase
    public func configureForCancellation() {
        lock.withLock {
            _purchaseResult = .cancelled
            _shouldThrowError = false
        }
    }

    /// Configure to simulate failed purchase
    public func configureForFailure(error: Error? = nil) {
        let errorToUse = error ?? StoreKitError.purchaseFailed(nil)
        lock.withLock {
            _purchaseResult = .failed(errorToUse)
            _restoreResult = .failed(errorToUse)
            _shouldThrowError = false
        }
    }

    /// Configure to simulate pending purchase (parental approval, etc.)
    public func configureForPending() {
        lock.withLock {
            _purchaseResult = .pending
            _shouldThrowError = false
        }
    }

    /// Configure to simulate no purchases to restore
    public func configureForNoPurchases() {
        lock.withLock {
            _restoreResult = .noPurchases
            _shouldThrowError = false
        }
    }
}
