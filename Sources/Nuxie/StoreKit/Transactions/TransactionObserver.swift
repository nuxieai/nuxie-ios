import CryptoKit
import Foundation
import StoreKit

enum PurchaseOutcomeSource: String, Equatable, Sendable {
    case checkout
    case transactionStream = "transaction_stream"
    case startupRecovery = "startup_recovery"
    case deferredUpdate = "deferred_update"
    case externalDelegate = "external_delegate"
}

struct VerifiedPurchaseEvidence: Sendable {
    let transactionJws: String
    let transactionId: String
    let originalTransactionId: String
    let productId: String
    let appAccountToken: UUID?
    let attributedDistinctId: String?
    let recordedAt: Date?
    let productFeatureIds: [String]
    let commercialContext: PurchaseCommercialContext?
    let checkoutCompletionEventId: String?
    let completionDeliveredAt: Date?
    let backendSyncedAt: Date?
    let finishRequired: Bool?
    let resolvesPendingPurchase: Bool
    let allowsDurableCheckoutAuthority: Bool
    let requiresAuthorityResolution: Bool
    /// Checkout recovery claims a transaction BECAUSE its account token says
    /// it is ours: attribution must come from token-derived ownership alone,
    /// never from the caller's expectation or the active customer.
    let requiresTokenOwnership: Bool
    let isRevoked: Bool
    let isUpgraded: Bool
    let finish: (@Sendable () async -> Void)?

    init(
        transactionJws: String,
        transactionId: String,
        originalTransactionId: String,
        productId: String,
        appAccountToken: UUID? = nil,
        attributedDistinctId: String? = nil,
        recordedAt: Date? = nil,
        productFeatureIds: [String] = [],
        commercialContext: PurchaseCommercialContext? = nil,
        checkoutCompletionEventId: String? = nil,
        completionDeliveredAt: Date? = nil,
        backendSyncedAt: Date? = nil,
        finishRequired: Bool? = nil,
        resolvesPendingPurchase: Bool,
        allowsDurableCheckoutAuthority: Bool,
        requiresAuthorityResolution: Bool = true,
        requiresTokenOwnership: Bool = false,
        isRevoked: Bool = false,
        isUpgraded: Bool = false,
        finish: (@Sendable () async -> Void)? = nil
    ) {
        self.transactionJws = transactionJws
        self.transactionId = transactionId
        self.originalTransactionId = originalTransactionId
        self.productId = productId
        self.appAccountToken = appAccountToken
        self.attributedDistinctId = attributedDistinctId
        self.recordedAt = recordedAt
        self.productFeatureIds = productFeatureIds
        self.commercialContext = commercialContext
        self.checkoutCompletionEventId = checkoutCompletionEventId
        self.completionDeliveredAt = completionDeliveredAt
        self.backendSyncedAt = backendSyncedAt
        self.finishRequired = finishRequired
        self.resolvesPendingPurchase = resolvesPendingPurchase
        self.allowsDurableCheckoutAuthority = allowsDurableCheckoutAuthority
        self.requiresAuthorityResolution = requiresAuthorityResolution
        self.requiresTokenOwnership = requiresTokenOwnership
        self.isRevoked = isRevoked
        self.isUpgraded = isUpgraded
        self.finish = finish
    }
}

struct ExternalPurchaseDeclaration: Sendable {
    enum Kind: Sendable {
        case purchased(
            context: PurchaseCommercialContext,
            transactionId: String?,
            testStore: Bool
        )
        case restored(testStore: Bool)
    }

    let operationId: String
    let distinctId: String
    let kind: Kind
}

enum PurchaseOutcome: Sendable {
    case verified(VerifiedPurchaseEvidence, source: PurchaseOutcomeSource)
    case external(ExternalPurchaseDeclaration, source: PurchaseOutcomeSource)
    case cancelled(source: PurchaseOutcomeSource)
    case pending(source: PurchaseOutcomeSource)
    case failed(reason: String, source: PurchaseOutcomeSource)

    var source: PurchaseOutcomeSource {
        switch self {
        case .verified(_, let source),
             .external(_, let source),
             .cancelled(let source),
             .pending(let source),
             .failed(_, let source):
            return source
        }
    }
}

struct PurchaseCommitResult: Sendable {
    let committed: Bool
    let syncTask: Task<Bool, Never>?
    let isTerminal: Bool

    init(
        committed: Bool,
        syncTask: Task<Bool, Never>?,
        isTerminal: Bool? = nil
    ) {
        self.committed = committed
        self.syncTask = syncTask
        self.isTerminal = isTerminal ?? committed
    }

    static let handled = Self(
        committed: false,
        syncTask: nil,
        isTerminal: true
    )
    static let rejected = Self(
        committed: false,
        syncTask: nil,
        isTerminal: false
    )
}

/// Immutable verified StoreKit update consumed by the transaction handler.
/// Snapshotting StoreKit's value lets tests exercise the same ownership path
/// used by `Transaction.updates` without manufacturing a StoreKit transaction.
struct VerifiedStoreTransactionUpdate: Sendable {
    let transactionId: String
    let originalTransactionId: String
    let productId: String
    let appAccountToken: UUID?
    let isRevoked: Bool
    let isUpgraded: Bool
    let finish: @Sendable () async -> Void

    init(
        transactionId: String,
        originalTransactionId: String,
        productId: String,
        appAccountToken: UUID?,
        isRevoked: Bool,
        isUpgraded: Bool,
        finish: @escaping @Sendable () async -> Void
    ) {
        self.transactionId = transactionId
        self.originalTransactionId = originalTransactionId
        self.productId = productId
        self.appAccountToken = appAccountToken
        self.isRevoked = isRevoked
        self.isUpgraded = isUpgraded
        self.finish = finish
    }

    init(_ transaction: Transaction) {
        transactionId = String(transaction.id)
        originalTransactionId = String(transaction.originalID)
        productId = transaction.productID
        appAccountToken = transaction.appAccountToken
        isRevoked = transaction.revocationDate != nil
        isUpgraded = transaction.isUpgraded
        finish = { await transaction.finish() }
    }
}

final class TransactionFinishOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func markFinished() {
        lock.withLock { value = true }
    }

    var didFinish: Bool {
        lock.withLock { value }
    }
}

struct StoreTransactionRecoveryItem: Sendable {
    let update: VerifiedStoreTransactionUpdate
    let jwsRepresentation: String
    let finishOutcome: TransactionFinishOutcome?

    init(
        update: VerifiedStoreTransactionUpdate,
        jwsRepresentation: String,
        finishOutcome: TransactionFinishOutcome? = nil
    ) {
        self.jwsRepresentation = jwsRepresentation
        if let finishOutcome {
            self.update = update
            self.finishOutcome = finishOutcome
        } else {
            let outcome = TransactionFinishOutcome()
            self.update = VerifiedStoreTransactionUpdate(
                transactionId: update.transactionId,
                originalTransactionId: update.originalTransactionId,
                productId: update.productId,
                appAccountToken: update.appAccountToken,
                isRevoked: update.isRevoked,
                isUpgraded: update.isUpgraded,
                finish: {
                    await update.finish()
                    outcome.markFinished()
                }
            )
            self.finishOutcome = outcome
        }
    }
}

struct StoreTransactionRecoverySources: Sendable {
    let unfinished: @Sendable () async -> [StoreTransactionRecoveryItem]
    let currentEntitlements: @Sendable () async -> [StoreTransactionRecoveryItem]
}

struct TransactionProcessingPolicy: Equatable {
    let providerOwnsTransaction: Bool
    let finishAfterRecording: Bool
    let resolvesPendingPurchase: Bool
}

func transactionProcessingPolicy(
    resolvesPendingPurchase: Bool,
    evidenceAuthority: PurchaseEvidenceAuthority,
    observerMode: Bool
) -> TransactionProcessingPolicy {
    let providerOwnsTransaction = evidenceAuthority == .providerConnector
        || evidenceAuthority == .ambiguous
    return TransactionProcessingPolicy(
        providerOwnsTransaction: providerOwnsTransaction,
        finishAfterRecording: !providerOwnsTransaction && !observerMode,
        resolvesPendingPurchase: resolvesPendingPurchase
    )
}

protocol TransactionObserverProtocol: Actor {
    func startListening()
    func stopListening() async
    func commit(_ outcome: PurchaseOutcome) async -> PurchaseCommitResult
    func syncCurrentEntitlements(distinctId: String) async
    func retryStoredEvidence() async
    func retryAfterProfileReady() async
    /// Atomically reconciles a matching unsynchronized StoreKit purchase and
    /// the caller's first authoritative Feature use. Returns `nil` when no
    /// protected purchase evidence applies, so the ordinary usage command can
    /// run instead.
    func useFeatureWithPendingPurchase(
        distinctId: String,
        featureId: String,
        amount: Double,
        entityId: String?,
        metadata: [String: AnyCodable]?
    ) async throws -> FeatureUsageResult?
}

extension TransactionObserverProtocol {
    func commit(_ outcome: PurchaseOutcome) async -> PurchaseCommitResult {
        switch outcome {
        case .verified, .external:
            return PurchaseCommitResult(committed: true, syncTask: nil)
        case .cancelled, .pending, .failed:
            return .handled
        }
    }
    func retryStoredEvidence() async {}
    func retryAfterProfileReady() async { await retryStoredEvidence() }
    func useFeatureWithPendingPurchase(
        distinctId: String,
        featureId: String,
        amount: Double,
        entityId: String?,
        metadata: [String: AnyCodable]?
    ) async throws -> FeatureUsageResult? {
        _ = distinctId
        return nil
    }
}

/// Observes StoreKit 2 Transaction.updates stream and syncs verified transactions with the backend
///
/// By observing Transaction.updates directly, we catch all purchases regardless of how they
/// were initiated (via SDK, app's own StoreKit code, or even the App Store directly).
internal actor TransactionObserver: TransactionObserverProtocol {

    enum CheckoutRecoveryResult: Equatable {
        case noMatch
        case recovered
    }

    // MARK: - Dependencies

    private let api: PurchaseSynchronizing
    private let featureService: FeatureServiceProtocol
    private let identityService: IdentityServiceProtocol
    private let settings: PurchaseSettingsProviding
    private let eventSink: SystemEventSink
    private let transactionServiceProvider: @Sendable () -> TransactionService
    private let evidenceStore: TransactionEvidenceStoreProtocol
    private let descriptorAllowanceProvider:
        @Sendable (StoredTransactionEvidence) async -> [OptimisticEntitlementAllowance]?
    private let projectionPublisher: @Sendable (
        [OptimisticPurchaseEvidence]?,
        [String: [OptimisticEntitlementAllowance]]?,
        String,
        UInt64
    ) async -> Void
    private let purchaseStorageScope: PurchaseStorageScope
    private let dateProvider: DateProviderProtocol
    private let unfinishedRecoveryTransactions:
        @Sendable () async -> [StoreTransactionRecoveryItem]
    private let currentEntitlementRecoveryTransactions:
        @Sendable () async -> [StoreTransactionRecoveryItem]
    // MARK: - Properties

    /// Task observing Transaction.updates
    private var updateTask: Task<Void, Never>?
    /// Startup and profile-ready recovery can arrive concurrently. Coalesce
    /// them into one scan so actor reentrancy across StoreKit/backend awaits
    /// cannot submit the same signed receipt twice.
    private var evidenceRecoveryTask: Task<Void, Never>?
    private var evidenceRecoveryRequestGeneration: UInt64 = 0
    private var profileReadyEntitlementScanRequested = false
    /// A stopped observer is a hard collaborator boundary. Generation also
    /// rejects responses that began under an earlier setup of this actor.
    private var lifecycleGeneration: UInt64 = 0
    private var isStopped = false

    private enum PurchaseCommitKey: Hashable, Sendable {
        case verified(transactionId: String, revoked: Bool)
        case external(operationId: String)
    }

    private struct PurchaseCommitOperation: Sendable {
        let id: UUID
        let task: Task<PurchaseCommitResult, Never>
    }

    private struct CompletedPurchaseCommit: Sendable {
        let id: UUID
        let result: PurchaseCommitResult
    }

    /// The actor may re-enter while evidence or events are being persisted.
    /// Install the whole-commit operation before the first suspension so every
    /// producer of the same evidence joins one ordered interpretation.
    private var purchaseCommitOperations: [PurchaseCommitKey: PurchaseCommitOperation] = [:]
    private var completedPurchaseCommits: [PurchaseCommitKey: CompletedPurchaseCommit] = [:]
    /// A nonterminal stable-event/Journey capture retries the exact same
    /// committer identity. External callbacks are never invoked again, and a
    /// verified retry reuses its durable evidence rather than finishing twice.
    private var retryablePurchaseOutcomes: [PurchaseCommitKey: PurchaseOutcome] = [:]
    private var purchaseCommitRetryTask: Task<Void, Never>?
    /// Journey authority is process-local. Preserve it across a transient
    /// routed-capture failure, but never across observer teardown/relaunch.
    private var purchaseCommitJourneyRouting: Set<PurchaseCommitKey> = []

    /// Set of transaction IDs we've already synced (to avoid duplicates within session)
    private var syncedTransactionIds: Set<String> = []
    private struct TransactionSyncOperation: Sendable {
        let id: UUID
        let task: Task<Bool, Never>
    }

    /// StoreKit updates and the direct purchase callback can enter the actor
    /// while the same backend request is suspended. The observer owns one task
    /// per receipt identity so every caller and shutdown can join it.
    private var transactionSyncOperations: [String: TransactionSyncOperation] = [:]
    private var evidenceByTransactionId: [String: StoredTransactionEvidence]?
    private var evidenceStoreUnreadable = false
    /// Purchase-backed use and projection refresh share this actor-owned
    /// routing state. While any refresh is suspended resolving descriptor
    /// allowances, spends conservatively use the durable command journal.
    private var projectionRefreshGeneration: UInt64 = 0
    private var projectionRefreshesInFlight = 0
    private var optimisticProjectionIsActive = false
    private var optimisticProjectionDistinctId: String?
    /// Verified revocations retained for the observer lifetime even when a
    /// transaction evidence store is unreadable. This revocation evidence is not persisted
    /// entitlement state and prevents a later recompute from resurrecting access
    /// before the durable evidence record can be updated.
    private var revokedOriginalTransactionIds: Set<String> = []
    /// Serializes the one purchase-backed Feature command that may consume a
    /// transaction's initial metered grant. Actor reentrancy otherwise lets a
    /// background receipt sync race the atomic command while its request is
    /// suspended.
    private var purchaseUsageClaims: Set<String> = []
    private var purchaseUsageWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    /// SDK teardown waits for accepted purchase-backed requests to finish
    /// retiring their exact evidence before another observer can open the
    /// same protected store under a new setup lifecycle.
    private var purchaseUsageDrainWaiters: [CheckedContinuation<Void, Never>] = []

    /// Receipt/JWS evidence is a retry queue, not permanent customer state.
    /// StoreKit remains the durable transaction authority after this window.
    static let evidenceRetention: TimeInterval = 90 * 24 * 3600

    // MARK: - Init

    init(
        api: PurchaseSynchronizing,
        features: FeatureServiceProtocol,
        identity: IdentityServiceProtocol,
        settings: PurchaseSettingsProviding,
        eventSink: SystemEventSink,
        transactionServiceProvider: @escaping @Sendable () -> TransactionService,
        evidenceStore: TransactionEvidenceStoreProtocol = TransactionEvidenceStore(),
        descriptorAllowanceProvider: @escaping @Sendable (
            StoredTransactionEvidence
        ) async -> [OptimisticEntitlementAllowance]? = { _ in nil },
        projectionPublisher: @escaping @Sendable (
            [OptimisticPurchaseEvidence]?,
            [String: [OptimisticEntitlementAllowance]]?,
            String,
            UInt64
        ) async -> Void = { _, _, _, _ in },
        purchaseStorageScope: PurchaseStorageScope = .testFixture,
        dateProvider: DateProviderProtocol = SystemDateProvider(),
        activeStoreOriginalTransactionIDs: @escaping @Sendable () async -> Set<String> = {
            var originalTransactionIDs: Set<String> = []
            for await result in Transaction.currentEntitlements {
                guard case .verified(let transaction) = result,
                      transaction.revocationDate == nil,
                      !transaction.isUpgraded else { continue }
                originalTransactionIDs.insert(String(transaction.originalID))
            }
            return originalTransactionIDs
        },
        unfinishedRecoveryTransactions: @escaping @Sendable () async ->
            [StoreTransactionRecoveryItem] = {
                var items: [StoreTransactionRecoveryItem] = []
                for await result in Transaction.unfinished {
                    switch result {
                    case .verified(let transaction):
                        let outcome = TransactionFinishOutcome()
                        items.append(StoreTransactionRecoveryItem(
                            update: VerifiedStoreTransactionUpdate(
                                transactionId: String(transaction.id),
                                originalTransactionId: String(transaction.originalID),
                                productId: transaction.productID,
                                appAccountToken: transaction.appAccountToken,
                                isRevoked: transaction.revocationDate != nil,
                                isUpgraded: transaction.isUpgraded,
                                finish: {
                                    await transaction.finish()
                                    outcome.markFinished()
                                }
                            ),
                            jwsRepresentation: result.jwsRepresentation,
                            finishOutcome: outcome
                        ))
                    case .unverified(let transaction, let error):
                        LogError("TransactionObserver: Unverified transaction \(transaction.id): \(error)")
                    }
                }
                return items
            },
        currentEntitlementRecoveryTransactions: @escaping @Sendable () async ->
            [StoreTransactionRecoveryItem] = {
                var items: [StoreTransactionRecoveryItem] = []
                for await result in Transaction.currentEntitlements {
                    switch result {
                    case .verified(let transaction):
                        let outcome = TransactionFinishOutcome()
                        items.append(StoreTransactionRecoveryItem(
                            update: VerifiedStoreTransactionUpdate(
                                transactionId: String(transaction.id),
                                originalTransactionId: String(transaction.originalID),
                                productId: transaction.productID,
                                appAccountToken: transaction.appAccountToken,
                                isRevoked: transaction.revocationDate != nil,
                                isUpgraded: transaction.isUpgraded,
                                finish: {
                                    await transaction.finish()
                                    outcome.markFinished()
                                }
                            ),
                            jwsRepresentation: result.jwsRepresentation,
                            finishOutcome: outcome
                        ))
                    case .unverified(let transaction, let error):
                        LogError("TransactionObserver: Unverified transaction \(transaction.id): \(error)")
                    }
                }
                return items
            },
        recoverySources: StoreTransactionRecoverySources? = nil
    ) {
        self.api = api
        self.featureService = features
        self.identityService = identity
        self.settings = settings
        self.eventSink = eventSink
        self.transactionServiceProvider = transactionServiceProvider
        self.evidenceStore = evidenceStore
        self.descriptorAllowanceProvider = descriptorAllowanceProvider
        self.projectionPublisher = projectionPublisher
        self.purchaseStorageScope = purchaseStorageScope
        self.dateProvider = dateProvider
        _ = activeStoreOriginalTransactionIDs
        self.unfinishedRecoveryTransactions = recoverySources?.unfinished
            ?? unfinishedRecoveryTransactions
        self.currentEntitlementRecoveryTransactions = recoverySources?.currentEntitlements
            ?? currentEntitlementRecoveryTransactions
    }

    // MARK: - Lifecycle

    /// Start listening to Transaction.updates
    /// Call this during SDK setup
    func startListening() {
        guard !isStopped else {
            LogDebug("TransactionObserver: Refusing to restart a stopped observer")
            return
        }
        guard updateTask == nil else {
            LogDebug("TransactionObserver: Already listening")
            return
        }
        lifecycleGeneration &+= 1

        LogInfo("TransactionObserver: Starting to listen for transaction updates")

        updateTask = Task { [weak self] in
            await self?.retryStoredEvidence()

            // Then listen for new transaction updates
            for await result in Transaction.updates {
                guard let self = self else { break }
                _ = await self.handleTransactionResult(
                    result,
                    source: .transactionStream
                )
            }
        }
    }

    /// Stop listening to Transaction.updates
    func stopListening() async {
        isStopped = true
        lifecycleGeneration &+= 1
        let listeningTask = updateTask
        updateTask = nil
        let recoveryTask = evidenceRecoveryTask
        let commitRetryTask = purchaseCommitRetryTask
        let commitTasks = purchaseCommitOperations.values.map(\.task)
        let syncTasks = transactionSyncOperations.values.map(\.task)
        listeningTask?.cancel()
        recoveryTask?.cancel()
        commitRetryTask?.cancel()
        commitTasks.forEach { $0.cancel() }
        syncTasks.forEach { $0.cancel() }
        for task in commitTasks { _ = await task.value }
        for task in syncTasks { _ = await task.value }
        await commitRetryTask?.value
        await recoveryTask?.value
        await listeningTask?.value
        if !purchaseUsageClaims.isEmpty {
            await withCheckedContinuation { continuation in
                purchaseUsageDrainWaiters.append(continuation)
            }
        }
        purchaseCommitOperations.removeAll()
        retryablePurchaseOutcomes.removeAll()
        purchaseCommitJourneyRouting.removeAll()
        transactionSyncOperations.removeAll()
        evidenceRecoveryTask = nil
        purchaseCommitRetryTask = nil
        let usageWaiters = purchaseUsageWaiters.values.flatMap { $0 }
        purchaseUsageWaiters.removeAll()
        purchaseUsageClaims.removeAll()
        usageWaiters.forEach { $0.resume() }
        LogInfo("TransactionObserver: Stopped listening")
    }

    // MARK: - Transaction Processing

    /// Process any unfinished transactions from previous app sessions
    private func processUnfinishedTransactions() async {
        LogDebug("TransactionObserver: Checking for unfinished transactions")

        for item in await unfinishedRecoveryTransactions() {
            await handleVerifiedTransaction(
                item.update,
                jwsRepresentation: item.jwsRepresentation,
                source: .startupRecovery
            )
        }

        LogDebug("TransactionObserver: Finished processing unfinished transactions")
    }

    /// Retry evidence that was safely recorded and finished locally while the
    /// backend was unavailable. StoreKit will not replay a transaction after
    /// finishing, so this queue is the recovery source on relaunch.
    private func processStoredEvidence() async {
        for evidence in storedEvidence().values {
            guard !Task.isCancelled else { return }
            let result = await commit(.verified(
                VerifiedPurchaseEvidence(
                    transactionJws: evidence.transactionJws,
                    transactionId: evidence.transactionId,
                    originalTransactionId: evidence.originalTransactionId,
                    productId: evidence.productId,
                    appAccountToken: evidence.scope.appAccountToken(
                        distinctId: evidence.distinctId
                    ),
                    attributedDistinctId: evidence.distinctId,
                    recordedAt: evidence.recordedAt,
                    productFeatureIds: evidence.productFeatureIds,
                    commercialContext: evidence.commercialContext,
                    checkoutCompletionEventId: evidence.checkoutCompletionEventId,
                    completionDeliveredAt: evidence.completionDeliveredAt,
                    backendSyncedAt: evidence.backendSyncedAt,
                    finishRequired: evidence.finishRequired,
                    resolvesPendingPurchase: false,
                    allowsDurableCheckoutAuthority: false,
                    requiresAuthorityResolution: false,
                    isRevoked: evidence.isRevoked
                ),
                source: .startupRecovery
            ))
            _ = await result.syncTask?.value
            guard !Task.isCancelled else { return }
            if let retained = storedEvidence()[evidence.transactionId],
               retained.backendSyncedAt != nil,
               !retained.finishRequired,
               retained.commercialContext == nil
                || retained.completionDeliveredAt != nil {
                _ = await removeEvidence(transactionId: evidence.transactionId)
            }
        }
    }

    /// Retry all durable evidence after an identity transition. Evidence is
    /// always submitted to the customer it was recorded for; its derived
    /// projection is visible only when that customer is active.
    func retryStoredEvidence() async {
        guard !isStopped else { return }
        evidenceRecoveryRequestGeneration &+= 1
        if let evidenceRecoveryTask {
            await evidenceRecoveryTask.value
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.performStoredEvidenceRecoveryPump()
        }
        evidenceRecoveryTask = task
        await task.value
    }

    func retryAfterProfileReady() async {
        guard !isStopped else { return }
        profileReadyEntitlementScanRequested = true
        await retryStoredEvidence()
    }

    private func performStoredEvidenceRecoveryPump() async {
        while true {
            guard !Task.isCancelled else {
                evidenceRecoveryTask = nil
                return
            }
            let processingGeneration = evidenceRecoveryRequestGeneration
            let scanCurrentEntitlements = profileReadyEntitlementScanRequested
            profileReadyEntitlementScanRequested = false
            await retryPendingPurchaseOutcomes()
            guard !Task.isCancelled else {
                evidenceRecoveryTask = nil
                return
            }
            await refreshOptimisticProjection()
            guard !Task.isCancelled else {
                evidenceRecoveryTask = nil
                return
            }
            await processUnfinishedTransactions()
            guard !Task.isCancelled else {
                evidenceRecoveryTask = nil
                return
            }
            if scanCurrentEntitlements {
                await processCurrentEntitlements(
                    distinctId: identityService.getDistinctId()
                )
            }
            guard !Task.isCancelled else {
                evidenceRecoveryTask = nil
                return
            }
            await processStoredEvidence()
            guard !Task.isCancelled else {
                evidenceRecoveryTask = nil
                return
            }
            guard evidenceRecoveryRequestGeneration == processingGeneration else {
                // A profile-ready or identity request arrived while this pass
                // was suspended. Serialize a fresh pass after the in-flight
                // one so newly available Journey/catalog authority is used.
                continue
            }
            evidenceRecoveryTask = nil
            return
        }
    }

    /// Handle a transaction verification result
    private func handleTransactionResult(
        _ result: VerificationResult<Transaction>,
        source: PurchaseOutcomeSource
    ) async -> String? {
        switch result {
        case .verified(let transaction):
            let transactionJwt = result.jwsRepresentation
            let finishOutcome = TransactionFinishOutcome()
            await handleVerifiedTransaction(
                VerifiedStoreTransactionUpdate(
                    transactionId: String(transaction.id),
                    originalTransactionId: String(transaction.originalID),
                    productId: transaction.productID,
                    appAccountToken: transaction.appAccountToken,
                    isRevoked: transaction.revocationDate != nil,
                    isUpgraded: transaction.isUpgraded,
                    finish: {
                        await transaction.finish()
                        finishOutcome.markFinished()
                    }
                ),
                jwsRepresentation: transactionJwt,
                source: source
            )
            return finishOutcome.didFinish ? String(transaction.id) : nil

        case .unverified(let transaction, let error):
            LogError("TransactionObserver: Unverified transaction \(transaction.id): \(error)")
            // Don't sync unverified transactions - they may be fraudulent
            return nil
        }
    }

    private func resolvedEvidenceAuthority(
        transactionService: TransactionService,
        appAccountToken: UUID?,
        productId: String,
        checkoutRecovery: PendingPurchaseRecord?,
        allowsDurableCheckoutAuthority: Bool
    ) async -> PurchaseEvidenceAuthority? {
        // A configured external billing delegate owns receipt processing. Its
        // declarations never open a StoreKit reconciliation window in Nuxie.
        if settings.purchaseDelegate() != nil {
            return .providerConnector
        }
        let active = await transactionService.activePurchaseEvidenceAuthority(
            productId: productId
        )
        guard active != .unavailable else { return nil }
        guard allowsDurableCheckoutAuthority else {
            return active.resolvedAuthority
        }
        let durableResult = await transactionService.durablePurchaseEvidenceAuthority(
            appAccountToken: appAccountToken,
            productId: productId
        )
        let durable: PurchaseEvidenceAuthority?
        switch durableResult {
        case .absent:
            durable = nil
        case .value(let authority):
            durable = authority
        case .unreadable:
            return nil
        }
        return checkoutRecovery?.evidenceAuthority.durableProductAuthority
            ?? durable
            ?? active.resolvedAuthority
    }

    func handleVerifiedTransaction(
        _ transaction: VerifiedStoreTransactionUpdate,
        jwsRepresentation transactionJwt: String,
        source: PurchaseOutcomeSource,
        attributedDistinctId: String? = nil,
        resolvesPendingPurchase: Bool = true,
        allowsDurableCheckoutAuthority: Bool = true
    ) async {
        var resolvedSource = source
        if source == .transactionStream,
           resolvesPendingPurchase,
           case .unique = await transactionServiceProvider()
            .pendingPurchaseOwnership(productId: transaction.productId) {
            resolvedSource = .deferredUpdate
        }
        _ = await commit(.verified(
            VerifiedPurchaseEvidence(
                transactionJws: transactionJwt,
                transactionId: transaction.transactionId,
                originalTransactionId: transaction.originalTransactionId,
                productId: transaction.productId,
                appAccountToken: transaction.appAccountToken,
                attributedDistinctId: attributedDistinctId,
                resolvesPendingPurchase: resolvesPendingPurchase,
                allowsDurableCheckoutAuthority: allowsDurableCheckoutAuthority,
                isRevoked: transaction.isRevoked,
                isUpgraded: transaction.isUpgraded,
                finish: transaction.finish
            ),
            source: resolvedSource
        ))
    }

    func commit(_ outcome: PurchaseOutcome) async -> PurchaseCommitResult {
        guard !isStopped else { return .rejected }
        guard let key = purchaseCommitKey(for: outcome) else {
            LogDebug(
                "TransactionObserver: Handled \(outcome.source.rawValue) purchase outcome"
            )
            return .handled
        }

        while true {
            if let completed = completedPurchaseCommits[key] {
                // Keep one exact sync task for every accepted commit attempt. A
                // failed receipt submission invalidates only the in-memory
                // marker; durable evidence and completion state make the next
                // producer a safe retry without replaying Journey advancement.
                if case .verified = outcome,
                   let syncTask = completed.result.syncTask {
                    let synced = await syncTask.value
                    guard !isStopped else { return .rejected }
                    // Another waiter may have invalidated and replaced this
                    // completion while the actor was suspended. Re-evaluate
                    // the newest completed/in-flight state before proceeding.
                    guard completedPurchaseCommits[key]?.id == completed.id else {
                        continue
                    }
                    if synced {
                        return completed.result
                    }
                    completedPurchaseCommits.removeValue(forKey: key)
                    // A duplicate checkout-recovery producer reports the
                    // recovery; it never resubmits a failed receipt itself.
                    // The invalidated completion leaves the retry to the
                    // stored-evidence pump's next pass.
                    if case .verified(let evidence, _) = outcome,
                       evidence.requiresTokenOwnership {
                        return completed.result
                    }
                    continue
                }
                return completed.result
            }
            guard !isStopped else { return .rejected }
            if let operation = purchaseCommitOperations[key] {
                return await operation.task.value
            }

            let operationId = UUID()
            let task = Task { [weak self] in
                guard let self else { return PurchaseCommitResult.rejected }
                return await self.performPurchaseCommit(outcome)
            }
            purchaseCommitOperations[key] = PurchaseCommitOperation(
                id: operationId,
                task: task
            )
            let result = await task.value
            if purchaseCommitOperations[key]?.id == operationId {
                purchaseCommitOperations.removeValue(forKey: key)
            }
            if result.isTerminal {
                completedPurchaseCommits[key] = CompletedPurchaseCommit(
                    id: UUID(),
                    result: result
                )
                retryablePurchaseOutcomes.removeValue(forKey: key)
                purchaseCommitJourneyRouting.remove(key)
            } else if shouldRetainPurchaseCommitRetry(outcome, key: key) {
                retryablePurchaseOutcomes[key] = preferredPurchaseCommitRetry(
                    existing: retryablePurchaseOutcomes[key],
                    candidate: outcome
                )
                if shouldSchedulePurchaseCommitRetry(outcome, key: key) {
                    schedulePurchaseCommitRetry()
                }
            }
            return result
        }
    }

    /// Read-only acceptance probe for the cross-SDK fixture. The committer's
    /// completed identities are independent from evidence-row and event counts.
    func completedSuccessfulPurchaseCommitCount() -> Int {
        completedPurchaseCommits.values.filter(\.result.committed).count
    }

    private func schedulePurchaseCommitRetry() {
        guard !isStopped, purchaseCommitRetryTask == nil else { return }
        purchaseCommitRetryTask = Task { [weak self] in
            guard let self else { return }
            await self.performPurchaseCommitRetryPump()
        }
    }

    private func performPurchaseCommitRetryPump() async {
        var delayNanoseconds: UInt64 = 250_000_000
        while !isStopped, !Task.isCancelled {
            guard retryablePurchaseOutcomes.contains(where: {
                shouldSchedulePurchaseCommitRetry($0.value, key: $0.key)
            }) else {
                purchaseCommitRetryTask = nil
                return
            }
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !isStopped, !Task.isCancelled else { break }
            await retryPendingPurchaseOutcomes(immediateOnly: true)
            delayNanoseconds = min(delayNanoseconds * 2, 5_000_000_000)
        }
        purchaseCommitRetryTask = nil
    }

    private func retryPendingPurchaseOutcomes(
        immediateOnly: Bool = false
    ) async {
        let pending = retryablePurchaseOutcomes
        for (key, outcome) in pending {
            guard !isStopped, !Task.isCancelled else { return }
            if immediateOnly,
               !shouldSchedulePurchaseCommitRetry(outcome, key: key) {
                continue
            }
            let result = await commit(outcome)
            if result.isTerminal,
               retryablePurchaseOutcomes[key] != nil {
                retryablePurchaseOutcomes.removeValue(forKey: key)
            }
        }
    }

    private func shouldRetainPurchaseCommitRetry(
        _ outcome: PurchaseOutcome,
        key: PurchaseCommitKey
    ) -> Bool {
        switch outcome {
        case .external:
            return true
        case .verified:
            return purchaseCommitJourneyRouting.contains(key)
        case .cancelled, .pending, .failed:
            return false
        }
    }

    private func preferredPurchaseCommitRetry(
        existing: PurchaseOutcome?,
        candidate: PurchaseOutcome
    ) -> PurchaseOutcome {
        guard let existing,
              case .verified(let existingEvidence, _) = existing,
              case .verified(let candidateEvidence, _) = candidate,
              existingEvidence.finish != nil,
              candidateEvidence.finish == nil else {
            return candidate
        }
        // Stored-evidence replay intentionally has no StoreKit finish closure.
        // Never let it replace the exact producer outcome still needed to
        // clear a durable finishRequired flag after a failed state save.
        return existing
    }

    private func shouldSchedulePurchaseCommitRetry(
        _ outcome: PurchaseOutcome,
        key: PurchaseCommitKey
    ) -> Bool {
        switch outcome {
        case .external:
            return true
        case .verified(let evidence, _):
            guard purchaseCommitJourneyRouting.contains(key) else {
                return false
            }
            let distinctId = storedEvidence()[evidence.transactionId]?.distinctId
                ?? evidence.attributedDistinctId
            return distinctId == nil
                || distinctId == identityService.getDistinctId()
        case .cancelled, .pending, .failed:
            return false
        }
    }

    private func purchaseCommitKey(
        for outcome: PurchaseOutcome
    ) -> PurchaseCommitKey? {
        switch outcome {
        case .verified(let evidence, _):
            return .verified(
                transactionId: evidence.transactionId,
                revoked: evidence.isRevoked
            )
        case .external(let declaration, _):
            return .external(operationId: declaration.operationId)
        case .cancelled, .pending, .failed:
            return nil
        }
    }

    private func performPurchaseCommit(
        _ outcome: PurchaseOutcome
    ) async -> PurchaseCommitResult {
        switch outcome {
        case .verified(let evidence, let source):
            return await performVerifiedCommit(evidence, source: source)
        case .external(let declaration, let source):
            return await performExternalCommit(declaration, source: source)
        case .cancelled, .pending, .failed:
            return .handled
        }
    }

    private func performExternalCommit(
        _ declaration: ExternalPurchaseDeclaration,
        source: PurchaseOutcomeSource
    ) async -> PurchaseCommitResult {
        let eventId = (["purchase-outcome", source.rawValue]
            + purchaseStorageScope.storageComponents
            + [declaration.operationId]).joined(separator: ":")
        let routeToJourneys = declaration.distinctId
            == identityService.getDistinctId()
        var captured = false
        // A false result can mean that the stable event is already durable but
        // local Journey routing was temporarily unavailable. Retry the exact
        // operation once immediately; later recovery hooks retain the same
        // operation ID until routing reports terminal completion.
        for _ in 0..<2 where !captured {
            switch declaration.kind {
            case .purchased(let context, let transactionId, let testStore):
                captured = await capturePurchaseCompletion(
                    properties: purchaseCompletionProperties(
                        context: context,
                        transactionId: transactionId,
                        testStore: testStore,
                        source: source
                    ),
                    eventId: eventId,
                    distinctId: declaration.distinctId,
                    routeToJourneys: routeToJourneys,
                    ensureDurableCarrier: true
                )
            case .restored(let testStore):
                captured = await eventSink.captureStableSystemEvent(
                    SystemEventNames.restoreCompleted,
                    properties: [
                        "source": source.rawValue,
                        "test_store": testStore,
                    ],
                    eventId: eventId,
                    distinctId: declaration.distinctId,
                    routeToJourneys: routeToJourneys,
                    ensureDurableCarrier: true
                )
            }
        }
        if !captured {
            LogWarning(
                "TransactionObserver: External declaration accepted before event routing completed"
            )
        }
        // The host has already completed the commercial operation. A local
        // EventLog/Journey routing failure must never turn that declaration
        // into a repurchase-safe failure. Keep the operation nonterminal so an
        // exact same-operation retry can re-enter the stable event capture.
        return PurchaseCommitResult(
            committed: true,
            syncTask: nil,
            isTerminal: captured
        )
    }

    private func performVerifiedCommit(
        _ verified: VerifiedPurchaseEvidence,
        source: PurchaseOutcomeSource
    ) async -> PurchaseCommitResult {
        let commitKey = PurchaseCommitKey.verified(
            transactionId: verified.transactionId,
            revoked: verified.isRevoked
        )
        var existing = storedEvidence()[verified.transactionId]
        if verified.isRevoked {
            await publishImmediateRevocation(
                originalTransactionId: verified.originalTransactionId
            )
            await persistImmediateRevocation(
                transactionId: verified.transactionId,
                originalTransactionId: verified.originalTransactionId,
                transactionJws: verified.transactionJws
            )
            existing = storedEvidence()[verified.transactionId]
        }
        guard !evidenceStoreUnreadable else { return .rejected }

        let needsTransactionService = verified.resolvesPendingPurchase
            || (existing == nil && verified.requiresAuthorityResolution)
        let transactionService = needsTransactionService
            ? transactionServiceProvider()
            : nil
        let checkoutRecovery: PendingPurchaseRecord?
        if let transactionService {
            checkoutRecovery = await transactionService.checkoutRecoveryRecord(
                appAccountToken: verified.appAccountToken,
                productId: verified.productId
            )
            guard !(await transactionService.pendingPurchaseStoreIsUnreadable()) else {
                return .rejected
            }
        } else {
            checkoutRecovery = nil
        }

        let policy: TransactionProcessingPolicy
        if existing != nil || !verified.requiresAuthorityResolution {
            policy = TransactionProcessingPolicy(
                providerOwnsTransaction: false,
                finishAfterRecording: verified.finishRequired
                    ?? (settings.purchaseHandlingMode() != .observer),
                resolvesPendingPurchase: verified.resolvesPendingPurchase
            )
        } else {
            guard let transactionService else { return .rejected }
            guard let authority = await resolvedEvidenceAuthority(
                transactionService: transactionService,
                appAccountToken: verified.appAccountToken,
                productId: verified.productId,
                checkoutRecovery: checkoutRecovery,
                allowsDurableCheckoutAuthority: verified
                    .allowsDurableCheckoutAuthority
            ) else { return .rejected }
            policy = transactionProcessingPolicy(
                resolvesPendingPurchase: verified.resolvesPendingPurchase,
                evidenceAuthority: authority,
                observerMode: settings.purchaseHandlingMode() == .observer
            )
        }

        if policy.providerOwnsTransaction {
            LogDebug(
                "TransactionObserver: Verified transaction left to external billing"
            )
            // Provider ownership reflects the CURRENT release profile's
            // authority, not this transaction forever: a later authority
            // convergence must be able to reprocess it, so never cache
            // this decision as a terminal commit.
            return PurchaseCommitResult(
                committed: false,
                syncTask: nil,
                isTerminal: false
            )
        }
        if verified.isUpgraded {
            if policy.finishAfterRecording, let finish = verified.finish {
                await finish()
            }
            return PurchaseCommitResult(committed: true, syncTask: nil)
        }
        guard !verified.transactionJws.isEmpty || existing?.backendSyncedAt != nil else {
            LogError(
                "TransactionObserver: Empty JWS for transaction \(verified.transactionId)"
            )
            return .rejected
        }

        let activeDistinctId = identityService.getDistinctId()
        if let existing,
           let attributedDistinctId = verified.attributedDistinctId,
           existing.distinctId != attributedDistinctId {
            LogWarning(
                "TransactionObserver: Refusing to move a purchase between customers"
            )
            return .rejected
        }

        let expectedDistinctId = verified.attributedDistinctId ?? activeDistinctId
        let deterministicAccountOwner: String? = if verified.appAccountToken
            == purchaseStorageScope.appAccountToken(
                distinctId: expectedDistinctId
            ) {
            expectedDistinctId
        } else {
            nil
        }
        let accountOwner: String?
        if existing == nil, let transactionService {
            let accountOwnerResult = await transactionService.purchaseAccountOwner(
                appAccountToken: verified.appAccountToken
            )
            guard !accountOwnerResult.isUnreadable else { return .rejected }
            accountOwner = accountOwnerResult.readableValue
        } else {
            accountOwner = nil
        }

        let pendingRecord: PendingPurchaseRecord?
        if policy.resolvesPendingPurchase {
            if let checkoutRecovery {
                pendingRecord = checkoutRecovery
            } else {
                guard let transactionService else { return .rejected }
                switch await transactionService.pendingPurchaseOwnership(
                    productId: verified.productId
                ) {
                case .none:
                    pendingRecord = nil
                case .unique(let record):
                    pendingRecord = record
                case .ambiguous:
                    LogWarning(
                        "TransactionObserver: Deferred purchase owner is ambiguous"
                    )
                    return .rejected
                case .unavailable:
                    return .rejected
                }
            }
        } else {
            pendingRecord = nil
        }

        // Recovery attributes strictly from token-derived ownership: a
        // checkout record, durable account ownership, or the deterministic
        // Nuxie token. An unrecognized token is not ours — never fall back
        // to the caller's expectation or the active customer.
        let recoveredOwner = checkoutRecovery?.distinctId
            ?? pendingRecord?.distinctId
            ?? accountOwner
            ?? deterministicAccountOwner
        if verified.requiresTokenOwnership, existing == nil,
           recoveredOwner == nil {
            LogDebug(
                "TransactionObserver: Leaving unrecognized account token unattributed"
            )
            // Ownership may still arrive later (durable attribution from a
            // checkout on another path); do not cache the refusal.
            return PurchaseCommitResult(
                committed: false,
                syncTask: nil,
                isTerminal: false
            )
        }

        // Once durable state records that finishing completed (or that the host
        // owns it in observer mode), a retrying producer must not reassert its
        // original finish requirement and finish the transaction twice.
        let shouldFinish = existing?.finishRequired
            ?? verified.finishRequired
            ?? policy.finishAfterRecording
        var committedEvidence = StoredTransactionEvidence(
            scope: existing?.scope ?? pendingRecord?.scope ?? purchaseStorageScope,
            // A revoked row's signed payload is authoritative: an active
            // producer arriving after revocation must not rewrite it
            // (monotonic revocation; the row stays exactly as revoked).
            transactionJws: (existing?.isRevoked == true && !verified.isRevoked)
                ? existing!.transactionJws
                : (verified.transactionJws.isEmpty
                    ? existing?.transactionJws ?? ""
                    : verified.transactionJws),
            transactionId: verified.transactionId,
            originalTransactionId: verified.originalTransactionId,
            productId: verified.productId,
            distinctId: existing?.distinctId
                ?? (verified.requiresTokenOwnership
                    // Recovery: token-derived ownership outranks the
                    // caller's expected customer (see the guard above).
                    ? recoveredOwner ?? activeDistinctId
                    : verified.attributedDistinctId
                        ?? pendingRecord?.distinctId
                        ?? accountOwner
                        ?? deterministicAccountOwner
                        ?? activeDistinctId),
            recordedAt: existing?.recordedAt
                ?? verified.recordedAt
                ?? pendingRecord?.recordedAt
                ?? dateProvider.now(),
            productFeatureIds: existing?.productFeatureIds.isEmpty == false
                ? existing!.productFeatureIds
                : (verified.productFeatureIds.isEmpty
                    ? pendingRecord?.productFeatureIds ?? []
                    : verified.productFeatureIds),
            isRevoked: verified.isRevoked || existing?.isRevoked == true,
            finishRequired: shouldFinish,
            commercialContext: existing?.commercialContext
                ?? verified.commercialContext
                ?? pendingRecord?.commercialContext,
            checkoutCompletionEventId: existing?.checkoutCompletionEventId
                ?? verified.checkoutCompletionEventId
                ?? pendingRecord?.checkoutCompletionEventId,
            completionDeliveredAt: existing?.completionDeliveredAt
                ?? verified.completionDeliveredAt,
            backendSyncedAt: existing?.backendSyncedAt
                ?? verified.backendSyncedAt
        )
        let routeCompletionToJourneys: Bool
        if purchaseCommitJourneyRouting.contains(commitKey) {
            routeCompletionToJourneys = true
        } else if pendingRecord?.state == .pending {
            // A deferred purchase explicitly survives the original checkout;
            // its pending marker is the authority to resume the Journey.
            routeCompletionToJourneys = true
        } else if let transactionService {
            routeCompletionToJourneys = await transactionService.isActiveCheckout(
                appAccountToken: verified.appAccountToken,
                productId: verified.productId,
                distinctId: committedEvidence.distinctId
            )
        } else {
            // Stored evidence on a later process launch preserves analytics
            // and server delivery without resurrecting the ended paywall.
            routeCompletionToJourneys = false
        }
        if routeCompletionToJourneys {
            purchaseCommitJourneyRouting.insert(commitKey)
        }
        // A replay whose row is already durable exactly as computed must not
        // die on a failing store write: completion capture comes first (the
        // claim is persisted only after the event is durably captured), and
        // the unchanged row carries everything the capture needs.
        var evidenceChanged = false
        if existing != committedEvidence {
            guard await persistEvidence(
                committedEvidence,
                refreshProjection: false
            ) else { return .rejected }
            evidenceChanged = true
        }

        if let checkoutRecovery {
            guard await retireCheckoutRecovery(
                appAccountToken: checkoutRecovery.appAccountToken,
                productId: verified.productId,
                checkoutRecoveryExists: true
            ) else { return .rejected }
        } else if pendingRecord?.state == .pending {
            guard let transactionService else { return .rejected }
            guard await transactionService.consumePendingPurchase(
                productId: verified.productId,
                distinctId: committedEvidence.distinctId
            ) else { return .rejected }
        }

        if committedEvidence.finishRequired, let finish = verified.finish {
            await finish()
            committedEvidence = replacingCommitState(
                committedEvidence,
                finishRequired: false
            )
            guard await persistEvidence(
                committedEvidence,
                refreshProjection: false
            ) else { return .rejected }
            evidenceChanged = true
        }

        var completionAccepted = committedEvidence.commercialContext == nil
            || committedEvidence.isRevoked
            || committedEvidence.completionDeliveredAt != nil
        if !committedEvidence.isRevoked,
           committedEvidence.completionDeliveredAt == nil,
           committedEvidence.distinctId == identityService.getDistinctId(),
           let context = committedEvidence.commercialContext {
            let captured = await capturePurchaseCompletion(
                properties: purchaseCompletionProperties(
                    context: context,
                    transactionId: committedEvidence.transactionId,
                    testStore: committedEvidence.scope.storeEnvironment == .testStore,
                    source: source
                ),
                eventId: committedEvidence.checkoutCompletionEventId
                    ?? purchaseCompletionEventId(
                        transactionId: committedEvidence.transactionId
                    ),
                distinctId: committedEvidence.distinctId,
                routeToJourneys: routeCompletionToJourneys
            )
            if captured {
                purchaseCommitJourneyRouting.remove(commitKey)
                committedEvidence = replacingCommitState(
                    committedEvidence,
                    completionDeliveredAt: dateProvider.now()
                )
                completionAccepted = await persistEvidence(
                    committedEvidence,
                    refreshProjection: false
                )
                evidenceChanged = evidenceChanged || completionAccepted
            }
        }
        let commitComplete = completionAccepted
            && !committedEvidence.finishRequired

        // A commit that changed no durable evidence must not re-derive the
        // projection: recovery scans refresh once per pass, and per-commit
        // re-derivation for unchanged replays double-counts allowances work.
        if evidenceChanged {
            await refreshOptimisticProjection()
        }
        // A duplicate token-ownership recovery producer whose commit changed
        // nothing durable never resubmits the receipt; the stored-evidence
        // pump owns retries of previously recorded failures.
        let syncTask = (verified.requiresTokenOwnership && !evidenceChanged)
            ? nil
            : scheduleSync(for: committedEvidence)
        return PurchaseCommitResult(
            committed: true,
            syncTask: syncTask,
            isTerminal: commitComplete
        )
    }

    private func scheduleSync(
        for evidence: StoredTransactionEvidence
    ) -> Task<Bool, Never>? {
        guard evidence.backendSyncedAt == nil,
              !evidence.transactionJws.isEmpty else { return nil }
        return Task { [weak self] in
            guard let self else { return false }
            return await self.syncTransactionWithOptions(
                transactionJws: evidence.transactionJws,
                transactionId: evidence.transactionId,
                productId: evidence.productId,
                originalTransactionId: evidence.originalTransactionId,
                updateLocalFeatures: evidence.distinctId
                    == self.identityService.getDistinctId(),
                isRevoked: evidence.isRevoked
            )
        }
    }

    private func capturePurchaseCompletion(
        properties: [String: Any],
        eventId: String,
        distinctId: String,
        routeToJourneys: Bool,
        ensureDurableCarrier: Bool = false
    ) async -> Bool {
        await eventSink.captureStableSystemEvent(
            SystemEventNames.purchaseCompleted,
            properties: properties,
            eventId: eventId,
            distinctId: distinctId,
            routeToJourneys: routeToJourneys,
            ensureDurableCarrier: ensureDurableCarrier
        )
    }

    func purchaseCompletionEventId(transactionId: String) -> String {
        (["purchase-completed"] + purchaseStorageScope.storageComponents
            + [transactionId]).joined(separator: ":")
    }

    private func replacingCommitState(
        _ evidence: StoredTransactionEvidence,
        finishRequired: Bool? = nil,
        completionDeliveredAt: Date? = nil
    ) -> StoredTransactionEvidence {
        StoredTransactionEvidence(
            scope: evidence.scope,
            transactionJws: evidence.transactionJws,
            transactionId: evidence.transactionId,
            originalTransactionId: evidence.originalTransactionId,
            productId: evidence.productId,
            distinctId: evidence.distinctId,
            recordedAt: evidence.recordedAt,
            productFeatureIds: evidence.productFeatureIds,
            isRevoked: evidence.isRevoked,
            finishRequired: finishRequired ?? evidence.finishRequired,
            commercialContext: evidence.commercialContext,
            checkoutCompletionEventId: evidence.checkoutCompletionEventId,
            completionDeliveredAt: completionDeliveredAt
                ?? evidence.completionDeliveredAt,
            backendSyncedAt: evidence.backendSyncedAt
        )
    }

    /// Completes the crash-recovery boundary in durable order: retire exact
    /// checkout attribution before finishing the transaction. If persistence
    /// fails, StoreKit redelivers and the observer retries without reusing a
    /// stale marker after a successful finish.
    func finishRecoveredTransaction(
        appAccountToken: UUID?,
        productId: String,
        checkoutRecoveryExists: Bool,
        finish: @escaping @Sendable () async -> Void
    ) async -> Bool {
        guard await retireCheckoutRecovery(
            appAccountToken: appAccountToken,
            productId: productId,
            checkoutRecoveryExists: checkoutRecoveryExists
        ) else { return false }
        // `finishRequired` is set only when Nuxie's native transaction path
        // accepted lifecycle ownership.
        await finish()
        return true
    }

    /// Compatibility entry point for recovery tests and callers that already
    /// hold durable evidence. Recovery still enters the single committer.
    func completeStoredTransactionRecovery(
        _ evidence: StoredTransactionEvidence,
        appAccountToken: UUID?,
        checkoutRecoveryExists: Bool,
        finish: @escaping @Sendable () async -> Void
    ) async -> Bool {
        _ = checkoutRecoveryExists
        let result = await commit(.verified(
            VerifiedPurchaseEvidence(
                transactionJws: evidence.transactionJws,
                transactionId: evidence.transactionId,
                originalTransactionId: evidence.originalTransactionId,
                productId: evidence.productId,
                appAccountToken: appAccountToken,
                attributedDistinctId: evidence.distinctId,
                recordedAt: evidence.recordedAt,
                productFeatureIds: evidence.productFeatureIds,
                commercialContext: evidence.commercialContext,
                checkoutCompletionEventId: evidence.checkoutCompletionEventId,
                completionDeliveredAt: evidence.completionDeliveredAt,
                backendSyncedAt: evidence.backendSyncedAt,
                finishRequired: true,
                resolvesPendingPurchase: true,
                allowsDurableCheckoutAuthority: true,
                requiresAuthorityResolution: false,
                isRevoked: evidence.isRevoked,
                finish: finish
            ),
            source: .startupRecovery
        ))
        _ = await result.syncTask?.value
        return result.committed
    }

    private func retireCheckoutRecovery(
        appAccountToken: UUID?,
        productId: String,
        checkoutRecoveryExists: Bool
    ) async -> Bool {
        guard checkoutRecoveryExists else { return true }
        guard let appAccountToken else { return false }
        return await transactionServiceProvider().retireCheckoutRecovery(
            appAccountToken: appAccountToken,
            productId: productId
        )
    }

    /// Sync a verified transaction JWS with backend and update features
    /// Returns true if the transaction is synced or already known.
    func syncTransaction(
        transactionJws: String,
        transactionId: String,
        productId: String?,
        originalTransactionId: String?
    ) async -> Bool {
        await syncTransactionWithOptions(
            transactionJws: transactionJws,
            transactionId: transactionId,
            productId: productId,
            originalTransactionId: originalTransactionId,
            updateLocalFeatures: true
        )
    }

    private func syncTransactionWithOptions(
        transactionJws: String,
        transactionId: String,
        productId: String?,
        originalTransactionId: String?,
        updateLocalFeatures: Bool = true,
        isRevoked: Bool = false,
        retainEvidenceAfterSync: Bool = false
    ) async -> Bool {
        guard !isStopped else { return false }
        guard !purchaseUsageClaims.contains(transactionId) else { return false }
        let requestLifecycleGeneration = lifecycleGeneration
        // Each renewal is a distinct verified transaction. Deduping by the
        // original subscription ID would silently drop later renewals.
        let preferredId = transactionId.isEmpty
            ? (originalTransactionId?.isEmpty == false ? originalTransactionId : nil)
            : transactionId
        let baseDedupeKey = preferredId ?? transactionJws
        // StoreKit reports revocation for the original transaction identity.
        // It is a new state transition and must not be swallowed by the
        // successful-purchase dedupe entry for that same transaction.
        let dedupeKey = isRevoked
            ? "\(baseDedupeKey):revoked"
            : baseDedupeKey

        if syncedTransactionIds.contains(dedupeKey) {
            LogDebug("TransactionObserver: Transaction already synced, finishing fast path")
            return await reconcileEvidenceAfterDeduplicatedSync(
                transactionId: transactionId,
                retainEvidenceAfterSync: retainEvidenceAfterSync
            )
        }

        if let operation = transactionSyncOperations[dedupeKey] {
            let synced = await operation.task.value
            guard synced,
                  !isStopped,
                  lifecycleGeneration == requestLifecycleGeneration else {
                return false
            }
            return await reconcileEvidenceAfterDeduplicatedSync(
                transactionId: transactionId,
                retainEvidenceAfterSync: retainEvidenceAfterSync
            )
        }

        let durableEvidence = storedEvidence()[transactionId]
        guard !evidenceStoreUnreadable else { return false }
        let distinctId = durableEvidence?.distinctId
            ?? identityService.getDistinctId()
        let operationId = UUID()
        let task = Task { [weak self] in
            guard let self else { return false }
            return await self.submitTransactionWithOptions(
                transactionJws: transactionJws,
                transactionId: transactionId,
                productId: productId,
                originalTransactionId: originalTransactionId,
                distinctId: distinctId,
                dedupeKey: dedupeKey,
                lifecycleGeneration: requestLifecycleGeneration,
                updateLocalFeatures: updateLocalFeatures,
                retainEvidenceAfterSync: retainEvidenceAfterSync
            )
        }
        transactionSyncOperations[dedupeKey] = TransactionSyncOperation(
            id: operationId,
            task: task
        )
        let synced = await task.value
        if transactionSyncOperations[dedupeKey]?.id == operationId {
            transactionSyncOperations.removeValue(forKey: dedupeKey)
        }
        return synced
    }

    private func reconcileEvidenceAfterDeduplicatedSync(
        transactionId: String,
        retainEvidenceAfterSync: Bool
    ) async -> Bool {
        // Transaction.updates can win the race with the direct purchase
        // callback. The callback may persist the same evidence after the
        // observer already synced it, so the deduplicated path must drain
        // that late write as well.
        if let stored = storedEvidence()[transactionId],
           retainEvidenceAfterSync
            || stored.finishRequired
            || (stored.commercialContext != nil
                && stored.completionDeliveredAt == nil) {
            return await persistEvidence(stored.replacing(
                backendSyncedAt: dateProvider.now()
            ))
        }
        if !retainEvidenceAfterSync,
           storedEvidence()[transactionId]?.finishRequired != true {
            return await removeEvidence(transactionId: transactionId)
        }
        return true
    }

    private func submitTransactionWithOptions(
        transactionJws: String,
        transactionId: String,
        productId: String?,
        originalTransactionId: String?,
        distinctId: String,
        dedupeKey: String,
        lifecycleGeneration requestLifecycleGeneration: UInt64,
        updateLocalFeatures: Bool,
        retainEvidenceAfterSync: Bool
    ) async -> Bool {

        do {
            let response = try await api.syncTransaction(
                transactionJwt: transactionJws,
                distinctId: distinctId
            )

            if response.success {
                // The current service returns its internal UUID rather than
                // echoing distinctId. That representation is not comparable
                // here, so validate only customer IDs the service echoes in
                // the initiating representation until the wire contract is
                // corrected.
                if let responseCustomerId = response.customerId,
                   responseCustomerId != distinctId,
                   UUID(uuidString: responseCustomerId) == nil {
                    LogError(
                        "TransactionObserver: Invalid sync customer for \(transactionId)"
                    )
                    return false
                }
                let acceptedEvidence = storedEvidence()[transactionId]
                guard !evidenceStoreUnreadable else { return false }
                guard !isStopped,
                      lifecycleGeneration == requestLifecycleGeneration else {
                    return false
                }
                if updateLocalFeatures,
                   identityService.getDistinctId() == distinctId,
                   let features = response.features {
                    await featureService.updateFromPurchase(
                        features,
                        distinctId: distinctId
                    )
                }
                guard !isStopped,
                      lifecycleGeneration == requestLifecycleGeneration else {
                    return false
                }
                syncedTransactionIds.insert(dedupeKey)
                if let stored = storedEvidence()[transactionId],
                   retainEvidenceAfterSync
                    || stored.finishRequired
                    || (stored.commercialContext != nil
                        && stored.completionDeliveredAt == nil) {
                    guard await persistEvidence(stored.replacing(
                        backendSyncedAt: dateProvider.now()
                    )) else { return false }
                } else if !retainEvidenceAfterSync,
                          storedEvidence()[transactionId]?.finishRequired != true {
                    guard await removeEvidence(transactionId: transactionId) else {
                        return false
                    }
                }

                if identityService.getDistinctId() == distinctId {
                    var properties: [String: Any] = [
                        "transaction_id": transactionId,
                        "original_transaction_id": originalTransactionId ?? "",
                        "product_id": productId ?? "",
                        "customer_id": distinctId
                    ]
                    if let context = acceptedEvidence?.commercialContext {
                        properties["experience_id"] = context.experienceId
                        properties["experience_version"] =
                            context.release.identity.experienceVersionId
                        properties["placement_id"] = context.placementId
                    }
                    eventSink.emit(
                        SystemEventNames.purchaseSynced,
                        properties: properties
                    )
                }

                return true
            }

            LogError(
                "TransactionObserver: Backend sync failed for transaction \(transactionId): \(response.error ?? "Unknown error")"
            )
            return false
        } catch {
            LogError("TransactionObserver: Failed to sync transaction \(transactionId): \(error)")
            return false
        }
    }

    // MARK: - Manual Sync

    /// Manually sync current entitlements (e.g., after restore purchases)
    func syncCurrentEntitlements(distinctId: String) async {
        LogInfo("TransactionObserver: Syncing current entitlements")

        await refreshOptimisticProjection()
        await processCurrentEntitlements(distinctId: distinctId)

        LogInfo("TransactionObserver: Finished syncing current entitlements")
    }

    private func processCurrentEntitlements(distinctId: String) async {
        for item in await currentEntitlementRecoveryTransactions() {
            await handleVerifiedTransaction(
                item.update,
                jwsRepresentation: item.jwsRepresentation,
                source: .startupRecovery,
                attributedDistinctId: distinctId,
                // A current-entitlement scan can race unfinished/updates for
                // the same deferred native purchase. Let the committer attach
                // and retire any exact pending marker so the scan cannot win
                // with a context-free terminal commit that suppresses Journey
                // advancement from the later producer.
                resolvesPendingPurchase: true,
                allowsDurableCheckoutAuthority: false
            )
        }
    }

    func recordVerifiedPurchase(
        evidence: StoreTransactionEvidence,
        product: StoreProduct,
        distinctId: String,
        finishRequired: Bool
    ) async -> Bool {
        guard evidence.productId == product.storeProductId else {
            LogWarning("TransactionObserver: Refusing mismatched StoreKit evidence")
            return false
        }
        let result = await commit(.verified(
            VerifiedPurchaseEvidence(
                transactionJws: evidence.transactionJws,
                transactionId: evidence.transactionId,
                originalTransactionId: evidence.originalTransactionId,
                productId: evidence.productId,
                appAccountToken: product.nativeCheckoutAppAccountToken,
                attributedDistinctId: distinctId,
                productFeatureIds: storeProductFeatureIds(
                    product.localEntitlementGrants
                ),
                commercialContext: product.purchaseContext,
                finishRequired: finishRequired,
                resolvesPendingPurchase: false,
                allowsDurableCheckoutAuthority: true,
                requiresAuthorityResolution: false,
                finish: evidence.finish
            ),
            source: .checkout
        ))
        return result.committed
    }

    func useFeatureWithPendingPurchase(
        distinctId: String,
        featureId: String,
        amount: Double,
        entityId: String?,
        metadata: [String: AnyCodable]?
    ) async throws -> FeatureUsageResult? {
        // External declarations never create transaction evidence.
        guard !isStopped,
              purchaseStorageScope.storeEnvironment == .appStore,
              amount.isFinite,
              amount > 0,
              let usageApi = api as? PurchaseBackedFeatureUsing else {
            return nil
        }
        guard projectionRefreshesInFlight == 0,
              optimisticProjectionDistinctId == nil
                || optimisticProjectionDistinctId == distinctId,
              !optimisticProjectionIsActive else {
            return nil
        }

        while true {
            guard !isStopped else { return nil }
            guard identityService.getDistinctId() == distinctId else {
                throw CancellationError()
            }
            let evidenceById = storedEvidence()
            if evidenceStoreUnreadable {
                // An unreadable evidence file must not demote a protected
                // purchase to the ordinary usage command; the caller retries
                // once the store is readable again (A12).
                throw TransactionEvidenceError.unreadable
            }
            let candidates = evidenceById.values
                .filter({ evidence in
                    evidence.distinctId == distinctId
                        && evidence.scope == purchaseStorageScope
                        && !evidence.isRevoked
                        && evidence.backendSyncedAt == nil
                        && !evidence.transactionJws.isEmpty
                        && evidence.productFeatureIds.contains(featureId)
                })
            guard candidates.count == 1, let evidence = candidates.first else {
                return nil
            }

            if let receiptSync = transactionSyncOperations[evidence.transactionId] {
                let synced = await receiptSync.task.value
                if transactionSyncOperations[evidence.transactionId]?.id
                    == receiptSync.id {
                    transactionSyncOperations.removeValue(
                        forKey: evidence.transactionId
                    )
                }
                // Linearize the fallback decision with identify/reset. The
                // ordinary command queue repeats the same atomic admission,
                // so a later identity change cannot cross either boundary.
                let ordinaryFallbackAdmitted = identityService
                    .performIfCurrentDistinctIdMatches(distinctId) { _ in true }
                guard ordinaryFallbackAdmitted == true else {
                    throw CancellationError()
                }
                if synced { return nil }
                continue
            }

            if purchaseUsageClaims.contains(evidence.transactionId) {
                await withCheckedContinuation { continuation in
                    purchaseUsageWaiters[evidence.transactionId, default: []]
                        .append(continuation)
                }
                continue
            }

            purchaseUsageClaims.insert(evidence.transactionId)
            let requestGeneration = lifecycleGeneration
            let request = PurchaseBackedFeatureUseRequest(
                customerId: distinctId,
                featureId: featureId,
                requiredBalance: amount,
                eventData: .init(value: amount, properties: metadata),
                entityId: entityId,
                purchase: .init(
                    transactionJwt: evidence.transactionJws,
                    eventId: purchaseUsageEventId(
                        evidence: evidence,
                        featureId: featureId,
                        amount: amount,
                        entityId: entityId
                    )
                )
            )

            do {
                let response = try await usageApi.useFeatureWithPurchase(request)
                guard response.customerId == distinctId else {
                    releasePurchaseUsageClaim(transactionId: evidence.transactionId)
                    throw NuxieNetworkError.invalidResponse
                }

                var purchaseSyncedProperties: [String: Any] = [
                    "transaction_id": evidence.transactionId,
                    "original_transaction_id": evidence.originalTransactionId,
                    "product_id": evidence.productId,
                    "customer_id": response.customerId
                ]
                if let context = evidence.commercialContext {
                    purchaseSyncedProperties["experience_id"] = context.experienceId
                    purchaseSyncedProperties["experience_version"] =
                        context.release.identity.experienceVersionId
                    purchaseSyncedProperties["placement_id"] = context.placementId
                }
                let purchaseSynced = await eventSink.capture(
                    SystemEventNames.purchaseSynced,
                    properties: purchaseSyncedProperties,
                    eventId: purchaseSyncedEventId(evidence: evidence),
                    distinctId: distinctId
                )
                guard purchaseSynced else {
                    releasePurchaseUsageClaim(transactionId: evidence.transactionId)
                    throw NuxieNetworkError.invalidResponse
                }

                // A decoded 2xx response means the purchase and usage command
                // committed, and the stable purchase event is now durably
                // captured. `allowed` is the post-use access state, so it is
                // false after consuming the final finite unit.
                let acceptedAt = dateProvider.now()
                guard let current = storedEvidence()[evidence.transactionId],
                      current.distinctId == distinctId,
                      current.transactionJws == evidence.transactionJws,
                      await persistEvidence(current.replacing(
                          backendSyncedAt: acceptedAt
                      )) else {
                    releasePurchaseUsageClaim(
                        transactionId: evidence.transactionId
                    )
                    throw NuxieNetworkError.invalidResponse
                }
                syncedTransactionIds.insert(evidence.transactionId)
                if !current.finishRequired
                    && (current.commercialContext == nil
                        || current.completionDeliveredAt != nil) {
                    _ = await removeEvidence(transactionId: evidence.transactionId)
                }
                releasePurchaseUsageClaim(transactionId: evidence.transactionId)

                guard !isStopped,
                      lifecycleGeneration == requestGeneration,
                      identityService.getDistinctId() == distinctId else {
                    throw CancellationError()
                }
                let check = response.featureCheckResult(
                    requiredBalance: amount
                )
                await featureService.applyAuthoritativeUse(
                    check,
                    requestedFeatureId: featureId,
                    distinctId: distinctId,
                    entityId: entityId
                )
                let access = FeatureAccess(
                    authoritative: check,
                    requestedFeatureId: featureId
                )
                return FeatureUsageResult(
                    success: true,
                    featureId: featureId,
                    amountUsed: amount,
                    message: nil,
                    usage: nil,
                    authoritativeAccess: access
                )
            } catch {
                releasePurchaseUsageClaim(transactionId: evidence.transactionId)
                throw error
            }
        }
    }

    private func purchaseUsageEventId(
        evidence: StoredTransactionEvidence,
        featureId: String,
        amount: Double,
        entityId: String?
    ) -> String {
        let material = (
            purchaseStorageScope.storageComponents
                + [
                    evidence.transactionId,
                    featureId,
                    entityId ?? "",
                    String(amount.bitPattern),
                ]
        ).joined(separator: "\u{1f}")
        let digest = SHA256.hash(data: Data(material.utf8))
        return "purchase-use:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    private func purchaseSyncedEventId(
        evidence: StoredTransactionEvidence
    ) -> String {
        let material = (
            purchaseStorageScope.storageComponents
                + [
                    SystemEventNames.purchaseSynced,
                    evidence.distinctId,
                    evidence.transactionId,
                ]
        ).joined(separator: "\u{1f}")
        let digest = SHA256.hash(data: Data(material.utf8))
        return "purchase-synced:" + digest.map {
            String(format: "%02x", $0)
        }.joined()
    }

    private func releasePurchaseUsageClaim(transactionId: String) {
        purchaseUsageClaims.remove(transactionId)
        let waiters = purchaseUsageWaiters.removeValue(forKey: transactionId) ?? []
        waiters.forEach { $0.resume() }
        if purchaseUsageClaims.isEmpty {
            let drainWaiters = purchaseUsageDrainWaiters
            purchaseUsageDrainWaiters.removeAll()
            drainWaiters.forEach { $0.resume() }
        }
    }

    /// Relaunch recovery path shared by StoreKit's unfinished/update streams
    /// and integration tests. The durable pre-checkout record, not mutable
    /// current identity, owns attribution.
    func recoverCheckoutTransaction(
        evidence: StoreTransactionEvidence,
        appAccountToken: UUID?,
        finishRequired: Bool,
        attributedDistinctId: String? = nil
    ) async -> CheckoutRecoveryResult {
        guard let appAccountToken else { return .noMatch }
        let result = await commit(.verified(
            VerifiedPurchaseEvidence(
                transactionJws: evidence.transactionJws,
                transactionId: evidence.transactionId,
                originalTransactionId: evidence.originalTransactionId,
                productId: evidence.productId,
                appAccountToken: appAccountToken,
                attributedDistinctId: attributedDistinctId,
                finishRequired: finishRequired,
                resolvesPendingPurchase: true,
                allowsDurableCheckoutAuthority: true,
                requiresTokenOwnership: true,
                finish: evidence.finish
            ),
            source: .startupRecovery
        ))
        // Checkout recovery completes its backend submission before
        // reporting: callers (and the crash-recovery boundary) treat a
        // recovered transaction as durably attributed and synced.
        if let syncTask = result.syncTask {
            _ = await syncTask.value
        }
        let matched = result.committed
            || storedEvidence()[evidence.transactionId] != nil
        return matched ? .recovered : .noMatch
    }

    private func storedEvidence() -> [String: StoredTransactionEvidence] {
        if let evidenceByTransactionId { return evidenceByTransactionId }
        let allEntries: [String: StoredTransactionEvidence]
        switch evidenceStore.load() {
        case .absent:
            allEntries = [:]
        case .value(let entries):
            allEntries = entries
        case .unreadable:
            evidenceStoreUnreadable = true
            return [:]
        }
        evidenceStoreUnreadable = false
        let loaded = allEntries.filter {
            $0.value.scope == purchaseStorageScope
        }
        let cutoff = dateProvider.date(
            byAddingTimeInterval: -Self.evidenceRetention,
            to: dateProvider.now()
        )
        let expiredUnsyncedCount = loaded.values.filter {
            $0.recordedAt <= cutoff && $0.backendSyncedAt == nil
        }.count
        if expiredUnsyncedCount > 0 {
            LogWarning(
                "TransactionObserver: Retaining \(expiredUnsyncedCount, privacy: .publicValue) old unsynced receipts"
            )
        }
        // Acknowledged evidence is bounded by the retention horizon. Unsynced
        // evidence is bounded by the small number of transactions still waiting
        // for backend retry, which runs on every launch, so it must not expire.
        let retained = loaded.filter {
            $0.value.backendSyncedAt == nil || $0.value.recordedAt > cutoff
        }
        revokedOriginalTransactionIds.formUnion(
            loaded.values.lazy.filter(\.isRevoked).map(\.originalTransactionId)
        )
        if retained.count != loaded.count {
            guard evidenceStore.save(retained) else {
                // Do not cache a pruned snapshot that was not durably written.
                // Return it for this pass so expired evidence is never
                // processed, then retry the durable prune on the next access.
                return retained
            }
        }
        evidenceByTransactionId = retained
        return retained
    }

    private func persistEvidence(
        _ evidence: StoredTransactionEvidence,
        refreshProjection: Bool = true
    ) async -> Bool {
        guard evidence.scope == purchaseStorageScope else { return false }
        var entries = storedEvidence()
        guard !evidenceStoreUnreadable else { return false }
        let existingRevocation = entries[evidence.transactionId].flatMap {
            $0.isRevoked ? $0 : nil
        }
        let mustRemainRevoked = evidence.isRevoked
            || revokedOriginalTransactionIds.contains(evidence.originalTransactionId)
            || entries.values.contains {
                $0.originalTransactionId == evidence.originalTransactionId
                    && $0.isRevoked
            }
        let evidenceToPersist = mustRemainRevoked && !evidence.isRevoked
            ? evidenceWithRevocation(evidence, preserving: existingRevocation)
            : evidence
        entries[evidence.transactionId] = evidenceToPersist
        guard evidenceStore.save(entries) else { return false }
        evidenceByTransactionId = entries
        if refreshProjection {
            await refreshOptimisticProjection()
        }
        return true
    }

    @discardableResult
    func removeEvidence(transactionId: String) async -> Bool {
        var entries = storedEvidence()
        guard !evidenceStoreUnreadable else { return false }
        if let removed = entries[transactionId], removed.isRevoked {
            revokedOriginalTransactionIds.insert(removed.originalTransactionId)
        }
        entries.removeValue(forKey: transactionId)
        guard evidenceStore.save(entries) else { return false }
        evidenceByTransactionId = entries
        await refreshOptimisticProjection()
        return true
    }

    private func refreshOptimisticProjection() async {
        projectionRefreshGeneration &+= 1
        let refreshGeneration = projectionRefreshGeneration
        projectionRefreshesInFlight += 1
        defer { projectionRefreshesInFlight -= 1 }

        let entries = storedEvidence()
        guard !evidenceStoreUnreadable else {
            let distinctId = identityService.getDistinctId()
            guard refreshGeneration == projectionRefreshGeneration else { return }
            optimisticProjectionIsActive = false
            optimisticProjectionDistinctId = distinctId
            await projectionPublisher(nil, nil, distinctId, refreshGeneration)
            return
        }
        let evidence = entries.values.map { stored in
            OptimisticPurchaseEvidence(
                transactionId: stored.transactionId,
                distinctId: stored.distinctId,
                backendSynced: stored.backendSyncedAt != nil,
                revoked: stored.isRevoked
                    || revokedOriginalTransactionIds.contains(
                        stored.originalTransactionId
                    )
            )
        }
        var allowances: [String: [OptimisticEntitlementAllowance]] = [:]
        for stored in entries.values
        where stored.backendSyncedAt == nil
            && !stored.isRevoked
            && !revokedOriginalTransactionIds.contains(
                stored.originalTransactionId
            ) {
            if let resolved = await descriptorAllowanceProvider(stored) {
                allowances[stored.transactionId] = resolved
            }
        }
        guard refreshGeneration == projectionRefreshGeneration else { return }
        let evidenceInput = evidence.isEmpty ? nil : evidence
        let allowanceInput = allowances.isEmpty ? nil : allowances
        let distinctId = identityService.getDistinctId()
        optimisticProjectionIsActive = OptimisticEntitlementProjection.derive(
            evidence: evidenceInput,
            descriptorAllowances: allowanceInput,
            distinctId: distinctId
        ) != nil
        optimisticProjectionDistinctId = distinctId
        await projectionPublisher(
            evidenceInput,
            allowanceInput,
            distinctId,
            refreshGeneration
        )
    }

    private func publishImmediateRevocation(
        originalTransactionId: String
    ) async {
        revokedOriginalTransactionIds.insert(originalTransactionId)
        await refreshOptimisticProjection()
    }

    /// Commits revocation evidence before purchase-authority and pending-store
    /// checks that may defer the rest of transaction processing. A volatile
    /// marker remains for the process lifetime so a delayed active callback
    /// cannot downgrade or recreate revoked evidence after a durable drain.
    private func persistImmediateRevocation(
        transactionId: String,
        originalTransactionId: String,
        transactionJws: String
    ) async {
        var entries = storedEvidence()
        guard !evidenceStoreUnreadable else { return }
        var changed = false
        for (key, stored) in entries
        where stored.originalTransactionId == originalTransactionId
            && !stored.isRevoked {
            entries[key] = StoredTransactionEvidence(
                scope: stored.scope,
                transactionJws: key == transactionId && !transactionJws.isEmpty
                    ? transactionJws
                    : stored.transactionJws,
                transactionId: stored.transactionId,
                originalTransactionId: stored.originalTransactionId,
                productId: stored.productId,
                distinctId: stored.distinctId,
                recordedAt: stored.recordedAt,
                productFeatureIds: stored.productFeatureIds,
                isRevoked: true,
                finishRequired: stored.finishRequired,
                commercialContext: stored.commercialContext,
                checkoutCompletionEventId: stored.checkoutCompletionEventId,
                completionDeliveredAt: stored.completionDeliveredAt,
                backendSyncedAt: stored.backendSyncedAt
            )
            changed = true
        }
        guard !changed || evidenceStore.save(entries) else { return }
        evidenceByTransactionId = entries
        await refreshOptimisticProjection()
    }

    private func evidenceWithRevocation(
        _ evidence: StoredTransactionEvidence,
        preserving existing: StoredTransactionEvidence? = nil
    ) -> StoredTransactionEvidence {
        StoredTransactionEvidence(
            scope: existing?.scope ?? evidence.scope,
            transactionJws: existing?.transactionJws ?? evidence.transactionJws,
            transactionId: existing?.transactionId ?? evidence.transactionId,
            originalTransactionId: existing?.originalTransactionId
                ?? evidence.originalTransactionId,
            productId: existing?.productId ?? evidence.productId,
            distinctId: existing?.distinctId ?? evidence.distinctId,
            recordedAt: existing?.recordedAt ?? evidence.recordedAt,
            productFeatureIds: existing?.productFeatureIds.isEmpty == false
                ? existing!.productFeatureIds
                : evidence.productFeatureIds,
            isRevoked: true,
            finishRequired: existing?.finishRequired == true || evidence.finishRequired,
            commercialContext: existing?.commercialContext ?? evidence.commercialContext,
            checkoutCompletionEventId: existing?.checkoutCompletionEventId
                ?? evidence.checkoutCompletionEventId,
            completionDeliveredAt: evidence.completionDeliveredAt
                ?? existing?.completionDeliveredAt,
            backendSyncedAt: evidence.backendSyncedAt ?? existing?.backendSyncedAt
        )
    }
}
