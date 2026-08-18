import Foundation
@testable import Nuxie

public actor MockTransactionObserver: TransactionObserverProtocol {
    public private(set) var startListeningCalled = false
    public private(set) var stopListeningCalled = false
    public private(set) var syncCurrentEntitlementsCalled = false
    public private(set) var recordedPurchaseIds: [String] = []
    public private(set) var syncCalls: [(transactionJws: String, transactionId: String, productId: String?, originalTransactionId: String?)] = []
    public var nextSyncResult: Bool = true

    public init() {}

    public func startListening() {
        startListeningCalled = true
    }

    public func stopListening() {
        stopListeningCalled = true
    }

    public func syncTransaction(
        transactionJws: String,
        transactionId: String,
        productId: String?,
        originalTransactionId: String?
    ) async -> Bool {
        syncCalls.append((
            transactionJws: transactionJws,
            transactionId: transactionId,
            productId: productId,
            originalTransactionId: originalTransactionId
        ))
        return nextSyncResult
    }

    public func syncCurrentEntitlements() async {
        syncCurrentEntitlementsCalled = true
    }

    public func recordVerifiedPurchase(
        evidence: StoreTransactionEvidence,
        product: StoreProduct
    ) async {
        recordedPurchaseIds.append(evidence.transactionId)
    }

    public func setNextSyncResult(_ value: Bool) {
        nextSyncResult = value
    }
}
