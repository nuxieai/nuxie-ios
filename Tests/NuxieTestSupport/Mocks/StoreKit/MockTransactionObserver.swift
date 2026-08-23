import Foundation
@_spi(Testing) @testable import Nuxie

public actor MockTransactionObserver: TransactionObserverProtocol {
    public private(set) var startListeningCalled = false
    public private(set) var stopListeningCalled = false
    public private(set) var syncCurrentEntitlementsCalled = false
    public private(set) var syncCurrentEntitlementsDistinctIds: [String] = []
    public private(set) var profileReadyRecoveryCalls = 0
    public private(set) var recordedPurchaseIds: [String] = []
    public private(set) var recordedPurchaseDistinctIds: [String] = []
    public private(set) var recordedPurchaseFinishRequirements: [Bool] = []
    public private(set) var syncCalls: [(transactionJws: String, transactionId: String, productId: String?, originalTransactionId: String?)] = []
    public var nextSyncResult: Bool = true
    public var nextPurchaseBackedUsageResult: FeatureUsageResult?
    public private(set) var purchaseBackedUsageCalls: [(
        distinctId: String,
        featureId: String,
        amount: Double,
        entityId: String?
    )] = []
    private var completedPurchaseTransactionIds: Set<String> = []

    public init() {}

    public func startListening() {
        startListeningCalled = true
    }

    public func stopListening() async {
        stopListeningCalled = true
    }

    public func retryAfterProfileReady() async {
        guard !stopListeningCalled else { return }
        profileReadyRecoveryCalls += 1
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

    public func syncCurrentEntitlements(distinctId: String) async {
        syncCurrentEntitlementsCalled = true
        syncCurrentEntitlementsDistinctIds.append(distinctId)
    }

    @_spi(Testing) public func useFeatureWithPendingPurchase(
        distinctId: String,
        featureId: String,
        amount: Double,
        entityId: String?,
        metadata: [String: AnyCodable]?
    ) async throws -> FeatureUsageResult? {
        _ = metadata
        purchaseBackedUsageCalls.append((distinctId, featureId, amount, entityId))
        return nextPurchaseBackedUsageResult
    }

    public func setNextPurchaseBackedUsageResult(_ result: FeatureUsageResult?) {
        nextPurchaseBackedUsageResult = result
    }

    public func recordVerifiedPurchase(
        evidence: StoreTransactionEvidence,
        product: StoreProduct,
        distinctId: String,
        finishRequired: Bool
    ) async -> Bool {
        recordedPurchaseIds.append(evidence.transactionId)
        recordedPurchaseDistinctIds.append(distinctId)
        recordedPurchaseFinishRequirements.append(finishRequired)
        return true
    }

    public func setNextSyncResult(_ value: Bool) {
        nextSyncResult = value
    }

    public func claimPurchaseCompletion(transactionId: String) async -> Bool {
        completedPurchaseTransactionIds.insert(transactionId).inserted
    }

    public func purchaseCompletionEventId(transactionId: String) async -> String {
        "purchase-completed:test-fixture:test:appStore:\(transactionId)"
    }
}
