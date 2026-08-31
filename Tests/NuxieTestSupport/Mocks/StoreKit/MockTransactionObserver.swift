import Foundation
@_spi(Testing) @testable import Nuxie

public enum MockPurchaseOutcomeKind: String, Equatable, Sendable {
    case verified
    case externalPurchased
    case externalRestored
    case cancelled
    case pending
    case failed
}

public struct MockPurchaseOutcomeRecord: Sendable {
    public let kind: MockPurchaseOutcomeKind
    public let source: String
    public let operationId: String?
    public let transactionId: String?
    public let distinctId: String?
    public let productId: String?
    public let placementId: String?
    public let storeProductId: String?
    public let testStore: Bool?
    public let failureReason: String?
}

public actor MockTransactionObserver: TransactionObserverProtocol {
    public private(set) var startListeningCalled = false
    public private(set) var stopListeningCalled = false
    public private(set) var syncCurrentEntitlementsCalled = false
    public private(set) var syncCurrentEntitlementsDistinctIds: [String] = []
    public private(set) var profileReadyRecoveryCalls = 0
    public private(set) var committedOutcomes: [MockPurchaseOutcomeRecord] = []
    public private(set) var recordedPurchaseIds: [String] = []
    public private(set) var recordedPurchaseDistinctIds: [String] = []
    public private(set) var recordedPurchaseFinishRequirements: [Bool] = []
    public private(set) var syncCalls: [(
        transactionJws: String,
        transactionId: String,
        productId: String?,
        originalTransactionId: String?
    )] = []
    public var nextSyncResult: Bool = true
    public var nextPurchaseBackedUsageResult: FeatureUsageResult?
    public private(set) var purchaseBackedUsageCalls: [(
        distinctId: String,
        featureId: String,
        amount: Double,
        entityId: String?
    )] = []
    private var nextCommitOverride: (committed: Bool, syncResult: Bool?)?

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

    public func commit(_ outcome: PurchaseOutcome) async -> PurchaseCommitResult {
        let override = nextCommitOverride
        nextCommitOverride = nil
        let committed = override?.committed ?? outcome.isSuccessfulPurchase

        switch outcome {
        case .verified(let evidence, let source):
            committedOutcomes.append(MockPurchaseOutcomeRecord(
                kind: .verified,
                source: source.rawValue,
                operationId: nil,
                transactionId: evidence.transactionId,
                distinctId: evidence.attributedDistinctId,
                productId: evidence.productId,
                placementId: evidence.commercialContext?.placementId,
                storeProductId: evidence.commercialContext?.storeProductId,
                testStore: false,
                failureReason: nil
            ))
            recordedPurchaseIds.append(evidence.transactionId)
            if let distinctId = evidence.attributedDistinctId {
                recordedPurchaseDistinctIds.append(distinctId)
            }
            recordedPurchaseFinishRequirements.append(
                evidence.finishRequired == true
            )
            guard committed else {
                return PurchaseCommitResult(committed: false, syncTask: nil)
            }
            if evidence.finishRequired == true {
                await evidence.finish?()
            }
            syncCalls.append((
                transactionJws: evidence.transactionJws,
                transactionId: evidence.transactionId,
                productId: evidence.productId,
                originalTransactionId: evidence.originalTransactionId
            ))
            if let override {
                let syncTask: Task<Bool, Never>?
                if let syncResult = override.syncResult {
                    syncTask = Task { syncResult }
                } else {
                    syncTask = nil
                }
                return PurchaseCommitResult(
                    committed: true,
                    syncTask: syncTask
                )
            }
            let syncResult = nextSyncResult
            return PurchaseCommitResult(
                committed: true,
                syncTask: Task { syncResult }
            )

        case .external(let declaration, let source):
            let record: MockPurchaseOutcomeRecord
            switch declaration.kind {
            case .purchased(let context, let transactionId, let testStore):
                record = MockPurchaseOutcomeRecord(
                    kind: .externalPurchased,
                    source: source.rawValue,
                    operationId: declaration.operationId,
                    transactionId: transactionId,
                    distinctId: declaration.distinctId,
                    productId: context.productId,
                    placementId: context.placementId,
                    storeProductId: context.storeProductId,
                    testStore: testStore,
                    failureReason: nil
                )
            case .restored(let testStore):
                record = MockPurchaseOutcomeRecord(
                    kind: .externalRestored,
                    source: source.rawValue,
                    operationId: declaration.operationId,
                    transactionId: nil,
                    distinctId: declaration.distinctId,
                    productId: nil,
                    placementId: nil,
                    storeProductId: nil,
                    testStore: testStore,
                    failureReason: nil
                )
            }
            committedOutcomes.append(record)
            let syncTask: Task<Bool, Never>?
            if let syncResult = override?.syncResult {
                syncTask = Task { syncResult }
            } else {
                syncTask = nil
            }
            return PurchaseCommitResult(
                committed: committed,
                syncTask: syncTask
            )

        case .cancelled(let source):
            committedOutcomes.append(MockPurchaseOutcomeRecord(
                kind: .cancelled,
                source: source.rawValue,
                operationId: nil,
                transactionId: nil,
                distinctId: nil,
                productId: nil,
                placementId: nil,
                storeProductId: nil,
                testStore: nil,
                failureReason: nil
            ))
            return .handled

        case .pending(let source):
            committedOutcomes.append(MockPurchaseOutcomeRecord(
                kind: .pending,
                source: source.rawValue,
                operationId: nil,
                transactionId: nil,
                distinctId: nil,
                productId: nil,
                placementId: nil,
                storeProductId: nil,
                testStore: nil,
                failureReason: nil
            ))
            return .handled

        case .failed(let reason, let source):
            committedOutcomes.append(MockPurchaseOutcomeRecord(
                kind: .failed,
                source: source.rawValue,
                operationId: nil,
                transactionId: nil,
                distinctId: nil,
                productId: nil,
                placementId: nil,
                storeProductId: nil,
                testStore: nil,
                failureReason: reason
            ))
            return .handled
        }
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

    public func setNextSyncResult(_ value: Bool) {
        nextSyncResult = value
    }

    public func configureNextCommitResult(
        committed: Bool,
        syncResult: Bool? = nil
    ) {
        nextCommitOverride = (committed, syncResult)
    }
}

private extension PurchaseOutcome {
    var isSuccessfulPurchase: Bool {
        switch self {
        case .verified, .external:
            return true
        case .cancelled, .pending, .failed:
            return false
        }
    }
}
