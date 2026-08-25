import CryptoKit
import Foundation
import StoreKit

func providerLocalAccessTransactionId(storeProductId: String) -> String {
    "nuxie-provider-\(storeProductId)"
}

enum TransactionProcessingSource {
    case storeUpdates
    case nuxieEntitlementSync(distinctId: String)

    var distinctId: String? {
        guard case .nuxieEntitlementSync(let distinctId) = self else {
            return nil
        }
        return distinctId
    }
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
    source: TransactionProcessingSource,
    evidenceAuthority: PurchaseEvidenceAuthority,
    observerMode: Bool
) -> TransactionProcessingPolicy {
    switch source {
    case .storeUpdates:
        let providerOwnsTransaction = evidenceAuthority == .providerConnector
            || evidenceAuthority == .ambiguous
        return TransactionProcessingPolicy(
            providerOwnsTransaction: providerOwnsTransaction,
            finishAfterRecording: !providerOwnsTransaction && !observerMode,
            resolvesPendingPurchase: true
        )
    case .nuxieEntitlementSync:
        // Restore outcomes carry no receipt-ownership assertion. Preserve the
        // product authority captured before checkout: native/outcome-only
        // StoreKit evidence belongs to Nuxie, while signed Connector evidence
        // remains in the provider synchronization path. Native current
        // entitlements are durably recorded before Nuxie finishes them.
        let providerOwnsTransaction = evidenceAuthority == .providerConnector
            || evidenceAuthority == .ambiguous
        return TransactionProcessingPolicy(
            providerOwnsTransaction: providerOwnsTransaction,
            finishAfterRecording: !providerOwnsTransaction && !observerMode,
            resolvesPendingPurchase: false
        )
    }
}

protocol TransactionObserverProtocol: Actor {
    func startListening()
    func stopListening() async
    func syncTransaction(
        transactionJws: String,
        transactionId: String,
        productId: String?,
        originalTransactionId: String?
    ) async -> Bool
    func syncCurrentEntitlements(distinctId: String) async
    func recordVerifiedPurchase(
        evidence: StoreTransactionEvidence,
        product: StoreProduct,
        distinctId: String,
        finishRequired: Bool
    ) async -> Bool
    func markTransactionFinished(transactionId: String) async
    func claimPurchaseCompletion(transactionId: String) async -> Bool
    func markPurchaseCompletionCaptured(transactionId: String) async -> Bool
    func releasePurchaseCompletionClaim(transactionId: String) async
    func purchaseCompletionEventId(transactionId: String) async -> String
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
    func recordVerifiedPurchase(
        evidence: StoreTransactionEvidence,
        product: StoreProduct,
        distinctId: String,
        finishRequired: Bool
    ) async -> Bool { true }
    func markTransactionFinished(transactionId: String) async {}
    func claimPurchaseCompletion(transactionId: String) async -> Bool { true }
    func markPurchaseCompletionCaptured(transactionId: String) async -> Bool { true }
    func releasePurchaseCompletionClaim(transactionId: String) async {}
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
    private let localAccessStore: LocalPurchaseAccessStoreProtocol
    private let purchaseStorageScope: PurchaseStorageScope
    private let dateProvider: DateProviderProtocol
    private let activeStoreOriginalTransactionIDs: @Sendable () async -> Set<String>
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
    private var completedPurchaseEventTransactionIds: Set<String> = []
    private var evidenceByTransactionId: [String: StoredTransactionEvidence]?
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
        localAccessStore: LocalPurchaseAccessStoreProtocol = LocalPurchaseAccessStore(),
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
        self.localAccessStore = localAccessStore
        self.purchaseStorageScope = purchaseStorageScope
        self.dateProvider = dateProvider
        self.activeStoreOriginalTransactionIDs = activeStoreOriginalTransactionIDs
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
                    source: .storeUpdates
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
        let syncTasks = transactionSyncOperations.values.map(\.task)
        listeningTask?.cancel()
        recoveryTask?.cancel()
        syncTasks.forEach { $0.cancel() }
        for task in syncTasks { _ = await task.value }
        await recoveryTask?.value
        await listeningTask?.value
        if !purchaseUsageClaims.isEmpty {
            await withCheckedContinuation { continuation in
                purchaseUsageDrainWaiters.append(continuation)
            }
        }
        transactionSyncOperations.removeAll()
        evidenceRecoveryTask = nil
        let usageWaiters = purchaseUsageWaiters.values.flatMap { $0 }
        purchaseUsageWaiters.removeAll()
        purchaseUsageClaims.removeAll()
        usageWaiters.forEach { $0.resume() }
        LogInfo("TransactionObserver: Stopped listening")
    }

    // MARK: - Transaction Processing

    /// Process any unfinished transactions from previous app sessions
    private func processUnfinishedTransactions() async -> (
        processed: Set<String>,
        finished: Set<String>
    ) {
        LogDebug("TransactionObserver: Checking for unfinished transactions")

        var processedTransactionIds: Set<String> = []
        var finishedTransactionIds: Set<String> = []
        for item in await unfinishedRecoveryTransactions() {
            processedTransactionIds.insert(item.update.transactionId)
            await handleVerifiedTransaction(
                item.update,
                jwsRepresentation: item.jwsRepresentation,
                source: .storeUpdates
            )
            if item.finishOutcome?.didFinish == true {
                finishedTransactionIds.insert(item.update.transactionId)
            }
        }

        LogDebug("TransactionObserver: Finished processing unfinished transactions")
        return (processedTransactionIds, finishedTransactionIds)
    }

    /// Retry evidence that was safely recorded and finished locally while the
    /// backend was unavailable. StoreKit will not replay a transaction after
    /// finishing, so this queue is the recovery source on relaunch.
    private func processStoredEvidence(
        finishedTransactionIds: Set<String>
    ) async {
        let currentDistinctId = identityService.getDistinctId()
        for evidence in storedEvidence().values {
            guard !Task.isCancelled else { return }
            // Clear lifecycle ownership only when this exact unfinished
            // transaction was matched and its StoreKit finish returned.
            if evidence.finishRequired,
               finishedTransactionIds.contains(evidence.transactionId) {
                await markTransactionFinished(
                    transactionId: evidence.transactionId
                )
            }

            // A successful store purchase changes local UX independently of
            // backend availability. Preserve its canonical commercial event
            // before retrying receipt submission. Journey routing is allowed
            // only while the exact checkout remains active in this process.
            var retainedEvidence = storedEvidence()[evidence.transactionId]
                ?? evidence

            // Commercial completion is a local-first consequence of verified
            // StoreKit evidence. Capture it durably before attempting the
            // backend so an outage cannot suppress the successful Journey.
            if !retainedEvidence.isRevoked,
               retainedEvidence.commercialContext != nil,
               retainedEvidence.distinctId == currentDistinctId {
                let routeToJourneys = await transactionServiceProvider()
                    .isActiveCheckout(
                        appAccountToken: retainedEvidence.scope.appAccountToken(
                            distinctId: retainedEvidence.distinctId
                        ),
                        productId: retainedEvidence.productId,
                        distinctId: retainedEvidence.distinctId
                    )
                let delivered = await emitRecoveredPurchaseCompletion(
                    evidence: retainedEvidence,
                    routeToJourneys: routeToJourneys
                )
                guard !Task.isCancelled else { return }
                if delivered {
                    retainedEvidence = storedEvidence()[evidence.transactionId]
                        ?? retainedEvidence
                }
            }

            let synced: Bool
            if retainedEvidence.backendSyncedAt == nil {
                synced = await syncTransactionWithOptions(
                    transactionJws: retainedEvidence.transactionJws,
                    transactionId: retainedEvidence.transactionId,
                    productId: retainedEvidence.productId,
                    originalTransactionId: retainedEvidence.originalTransactionId,
                    updateLocalFeatures: retainedEvidence.distinctId == currentDistinctId,
                    isRevoked: retainedEvidence.isRevoked,
                    retainEvidenceAfterSync: true
                )
                guard !Task.isCancelled else { return }
                if synced {
                    // syncTransactionWithOptions durably records backend
                    // acceptance and scrubs the accepted JWS. Reload that
                    // canonical record instead of restoring stale receipt
                    // material from this loop's pre-sync snapshot.
                    retainedEvidence = storedEvidence()[evidence.transactionId]
                        ?? retainedEvidence
                }
            } else {
                synced = true
            }
            if synced {
                if retainedEvidence.finishRequired {
                    // Receipt acceptance is independent, but only StoreKit's
                    // exact unfinished result can retire finish ownership.
                    continue
                }
                if retainedEvidence.commercialContext != nil,
                   retainedEvidence.completionDeliveredAt == nil {
                    // Preserve exact bounded commercial context until its
                    // stable completion event is durably captured. Backend
                    // acknowledgement remains independent and prevents
                    // duplicate receipt submissions meanwhile.
                    continue
                }
                _ = removeEvidence(
                    transactionId: retainedEvidence.transactionId
                )
            }
        }
    }

    /// Retry all durable evidence after an identity transition. Evidence is
    /// always submitted to the customer it was recorded for; local grants are
    /// only re-applied when that customer is still active.
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
            await reconcileLocalAccessWithCurrentEntitlements()
            guard !Task.isCancelled else {
                evidenceRecoveryTask = nil
                return
            }
            let unfinishedRecovery = await processUnfinishedTransactions()
            guard !Task.isCancelled else {
                evidenceRecoveryTask = nil
                return
            }
            if scanCurrentEntitlements {
                await processCurrentEntitlements(
                    distinctId: identityService.getDistinctId(),
                    excludingTransactionIds: unfinishedRecovery.processed
                )
            }
            guard !Task.isCancelled else {
                evidenceRecoveryTask = nil
                return
            }
            await processStoredEvidence(
                finishedTransactionIds: unfinishedRecovery.finished
            )
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
        source: TransactionProcessingSource
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

    /// Provider-owned StoreKit updates may complete a deferred paywall action,
    /// but the provider remains the sole receipt, entitlement, and finishing
    /// authority. Historical Nuxie token ownership must not change that.
    private func processProviderOwnedTransaction(
        _ transaction: VerifiedStoreTransactionUpdate,
        checkoutRecovery: PendingPurchaseRecord?
    ) async {
        let currentDistinctId = identityService.getDistinctId()
        let transactionService = transactionServiceProvider()
        if let checkoutRecovery,
           checkoutRecovery.state == .checkout,
           checkoutRecovery.evidenceAuthority == .providerConnector {
            if checkoutRecovery.completionReportedAt == nil {
                let captured = await eventSink.captureOnly(
                    SystemEventNames.purchaseCompleted,
                    properties: purchaseCompletionProperties(
                        context: checkoutRecovery.commercialContext,
                        transactionId: transaction.transactionId,
                        testStore: checkoutRecovery.scope.storeEnvironment == .testStore
                    ),
                    eventId: checkoutRecovery.checkoutCompletionEventId,
                    distinctId: checkoutRecovery.distinctId
                )
                guard captured else { return }
                guard await transactionService.markCheckoutCompletionReported(
                    appAccountToken: checkoutRecovery.appAccountToken,
                    productId: transaction.productId,
                    completionEventId: checkoutRecovery.checkoutCompletionEventId,
                    reportedAt: dateProvider.now()
                ) else { return }
            }
            _ = await transactionService.retireCheckoutRecovery(
                appAccountToken: checkoutRecovery.appAccountToken,
                productId: transaction.productId
            )
            LogDebug(
                "TransactionObserver: Provider completion recovered without receipt ownership"
            )
            return
        }
        if let pending = await transactionService.pendingPurchaseRecord(
            productId: transaction.productId,
            distinctId: currentDistinctId
        ) {
            let context = pending.commercialContext
            let captured = await eventSink.captureOnly(
                SystemEventNames.purchaseCompleted,
                properties: purchaseCompletionProperties(
                    context: context,
                    transactionId: transaction.transactionId,
                    testStore: pending.scope.storeEnvironment == .testStore
                ),
                eventId: await purchaseCompletionEventId(
                    transactionId: transaction.transactionId
                ),
                distinctId: currentDistinctId
            )
            if captured, await transactionService.consumePendingPurchase(
                productId: transaction.productId,
                distinctId: currentDistinctId
            ), !pending.localEntitlementGrants.isEmpty {
                await featureService.applyLocalPurchase(
                    grants: pending.localEntitlementGrants.map {
                        StoreProduct.LocalEntitlementGrant(
                            featureId: $0.featureId,
                            featureExternalId: $0.featureExternalId,
                            allowanceType: $0.allowanceType,
                            allowance: $0.allowance
                        )
                    },
                    transactionId: transaction.transactionId
                )
            }
        }
        LogDebug(
            "TransactionObserver: Provider-owned transaction \(transaction.transactionId) left to delegate"
        )
    }

    /// Handle a verified transaction by syncing with backend
    private func resolvedEvidenceAuthority(
        transactionService: TransactionService,
        appAccountToken: UUID?,
        productId: String,
        checkoutRecovery: PendingPurchaseRecord?,
        source: TransactionProcessingSource
    ) async -> PurchaseEvidenceAuthority? {
        let active = await transactionService.activePurchaseEvidenceAuthority(
            productId: productId
        )
        guard active != .unavailable else { return nil }
        switch source {
        case .storeUpdates:
            let durable = await transactionService.durablePurchaseEvidenceAuthority(
                appAccountToken: appAccountToken,
                productId: productId
            )
            return checkoutRecovery?.evidenceAuthority.durableProductAuthority
                ?? durable
                ?? active.resolvedAuthority
        case .nuxieEntitlementSync:
            return active.resolvedAuthority
        }
    }

    func handleVerifiedTransaction(
        _ transaction: VerifiedStoreTransactionUpdate,
        jwsRepresentation transactionJwt: String,
        source: TransactionProcessingSource
    ) async {
        let transactionIdString = transaction.transactionId
        let isRevoked = transaction.isRevoked
        let stored = storedEvidence()[transactionIdString]
        let transactionService = transactionServiceProvider()
        let checkoutRecovery = await transactionService.checkoutRecoveryRecord(
            appAccountToken: transaction.appAccountToken,
            productId: transaction.productId
        )
        guard let evidenceAuthority = await resolvedEvidenceAuthority(
            transactionService: transactionService,
            appAccountToken: transaction.appAccountToken,
            productId: transaction.productId,
            checkoutRecovery: checkoutRecovery,
            source: source
        ) else {
            LogDebug(
                "TransactionObserver: Product authority unavailable; deferring \(transactionIdString)"
            )
            return
        }
        let policy = transactionProcessingPolicy(
            source: source,
            evidenceAuthority: evidenceAuthority,
            observerMode: settings.purchaseHandlingMode() == .observer
        )
        let tokenExpectedDistinctId = source.distinctId
            ?? identityService.getDistinctId()
        let deterministicAccountOwner: String? = if transaction.appAccountToken
            == purchaseStorageScope.appAccountToken(
                distinctId: tokenExpectedDistinctId
            ) {
            tokenExpectedDistinctId
        } else {
            nil
        }
        let purchaseAccountOwner = await transactionService.purchaseAccountOwner(
            appAccountToken: transaction.appAccountToken
        ) ?? deterministicAccountOwner
        // Signed connector authority owns its StoreKit updates. An unsigned
        // outcome-only delegate is deliberately different: exact checkout
        // context is bounded, but the deterministic Nuxie account token keeps
        // later native evidence in the SDK sync/finish pipeline.
        if policy.providerOwnsTransaction, !isRevoked,
           stored?.finishRequired != true {
            guard policy.resolvesPendingPurchase else {
                LogDebug(
                    "TransactionObserver: Provider current entitlement left to Connector"
                )
                return
            }
            guard checkoutRecovery?.distinctId
                    == identityService.getDistinctId() else {
                LogDebug(
                    "TransactionObserver: Uncorrelated transaction left to configured provider without resolving pending purchase"
                )
                return
            }
            await processProviderOwnedTransaction(
                transaction,
                checkoutRecovery: checkoutRecovery
            )
            return
        }
        if !isRevoked, !transaction.isUpgraded, stored == nil,
           checkoutRecovery != nil || purchaseAccountOwner != nil {
            let result = await recoverCheckoutTransaction(
                evidence: StoreTransactionEvidence(
                    transactionJws: transactionJwt,
                    transactionId: transactionIdString,
                    originalTransactionId: transaction.originalTransactionId,
                    productId: transaction.productId,
                    finish: transaction.finish
                ),
                appAccountToken: transaction.appAccountToken,
                finishRequired: policy.finishAfterRecording,
                attributedDistinctId: tokenExpectedDistinctId
            )
            if result == .recovered { return }
        }

        if isRevoked {
            LogDebug("TransactionObserver: Transaction \(transaction.transactionId) is revoked")
            // Provider-owned purchases are projected locally for immediate
            // offline access, but the provider remains the receipt authority.
            // Remove both the provider's product-scoped projection and any
            // native evidence projection before any recovery or sync path.
            if policy.providerOwnsTransaction {
                await featureService.removeLocalPurchase(
                    transactionId: providerLocalAccessTransactionId(
                        storeProductId: transaction.productId
                    ),
                    grants: []
                )
            }
            await featureService.removeLocalPurchase(
                transactionId: transactionIdString,
                grants: []
            )
            await removeLocalAccess(
                originalTransactionId: transaction.originalTransactionId
            )
        }

        // A delegate may transfer verified StoreKit evidence to Nuxie and the
        // process may terminate before its finish closure runs. Recover that
        // explicit ownership before the provider-owned early return. If the
        // transaction was revoked while the process was down, replace the
        // purchase evidence with StoreKit's current revocation evidence.
        if let stored, stored.finishRequired {
            let recoveryEvidence: StoredTransactionEvidence
            if isRevoked {
                guard !transactionJwt.isEmpty else {
                    LogError("TransactionObserver: Empty revocation JWS for transaction \(transaction.transactionId)")
                    return
                }
                recoveryEvidence = StoredTransactionEvidence(
                    scope: stored.scope,
                    transactionJws: transactionJwt,
                    transactionId: transactionIdString,
                    originalTransactionId: transaction.originalTransactionId,
                    productId: transaction.productId,
                    distinctId: stored.distinctId,
                    recordedAt: stored.recordedAt,
                    productFeatureIds: stored.productFeatureIds,
                    localEntitlementGrants: stored.localEntitlementGrants,
                    isRevoked: true,
                    finishRequired: true,
                    commercialContext: stored.commercialContext,
                    checkoutCompletionEventId: stored.checkoutCompletionEventId,
                    completionDeliveredAt: stored.completionDeliveredAt,
                    backendSyncedAt: stored.backendSyncedAt
                )
                guard persistEvidence(recoveryEvidence) else { return }
            } else {
                recoveryEvidence = stored
            }
            if !recoveryEvidence.isRevoked,
               !persistLocalAccess(recoveryEvidence) {
                LogError("TransactionObserver: Could not recover local purchase access")
                return
            }
            if !recoveryEvidence.isRevoked,
               recoveryEvidence.distinctId == identityService.getDistinctId() {
                await applyLocalAccess(recoveryEvidence)
            }
            guard await completeStoredTransactionRecovery(
                recoveryEvidence,
                appAccountToken: transaction.appAccountToken,
                checkoutRecoveryExists: checkoutRecovery != nil,
                finish: transaction.finish
            ) else { return }
            return
        }

        if isRevoked, policy.providerOwnsTransaction {
            LogDebug("TransactionObserver: Revoked provider-owned transaction left to delegate")
            return
        }

        // A configured provider owns receipt submission, entitlement state,
        // and transaction finishing. Nuxie only observes the delegate result
        // for Journey UX; it must not become a second transaction owner.
        guard !policy.providerOwnsTransaction else { return }

        LogInfo("TransactionObserver: Processing verified transaction \(transaction.transactionId) for product \(transaction.productId)")

        // Skip upgraded subscriptions (user has a higher tier now)
        if transaction.isUpgraded {
            LogDebug("TransactionObserver: Skipping upgraded transaction \(transaction.transactionId)")
            if policy.finishAfterRecording {
                await transaction.finish()
            }
            return
        }

        guard !transactionJwt.isEmpty else {
            LogError("TransactionObserver: Empty JWS for transaction \(transaction.transactionId)")
            // Don't finish - let StoreKit retry
            return
        }

        let sourceDistinctId = source.distinctId
        let activeDistinctId = identityService.getDistinctId()
        let expectedDistinctId = sourceDistinctId ?? activeDistinctId
        if let stored, stored.distinctId != expectedDistinctId {
            LogWarning("TransactionObserver: Ignoring evidence for a different Nuxie customer")
            // Durable evidence has already captured this transaction. Drain
            // StoreKit's unfinished queue when Nuxie owns finishing; otherwise
            // observer mode intentionally leaves finishing to the host.
            if policy.finishAfterRecording {
                await transaction.finish()
            }
            return
        }
        let pendingRecord: PendingPurchaseRecord?
        if policy.resolvesPendingPurchase {
            if let checkoutRecovery {
                pendingRecord = checkoutRecovery
            } else {
                let pendingOwnership = await transactionServiceProvider()
                    .pendingPurchaseOwnership(productId: transaction.productId)
                switch pendingOwnership {
                case .none:
                    pendingRecord = nil
                case .unique(let record):
                    pendingRecord = record
                case .ambiguous:
                    LogWarning(
                        "TransactionObserver: Deferred purchase owner is ambiguous; leaving transaction unfinished"
                    )
                    return
                }
            }
        } else {
            pendingRecord = nil
        }
        let pendingDistinctId = pendingRecord?.distinctId
        let pendingGrants = pendingRecord?.localEntitlementGrants
        let evidenceDistinctId = stored?.distinctId
            ?? sourceDistinctId
            ?? pendingDistinctId
            ?? purchaseAccountOwner
            ?? activeDistinctId
        let evidenceRecordedAt = stored?.recordedAt
            ?? pendingRecord?.recordedAt
            ?? dateProvider.now()
        let evidenceGrants = stored?.localEntitlementGrants
            ?? pendingGrants
            ?? []
        let evidenceFeatureIds = stored?.productFeatureIds
            ?? pendingRecord?.productFeatureIds
            ?? []
        let evidence = StoredTransactionEvidence(
            scope: stored?.scope ?? pendingRecord?.scope ?? purchaseStorageScope,
            transactionJws: transactionJwt,
            transactionId: transactionIdString,
            originalTransactionId: transaction.originalTransactionId,
            productId: transaction.productId,
            distinctId: evidenceDistinctId,
            recordedAt: evidenceRecordedAt,
            productFeatureIds: evidenceFeatureIds,
            localEntitlementGrants: evidenceGrants,
            isRevoked: isRevoked,
            finishRequired: stored?.finishRequired ?? false,
            commercialContext: stored?.commercialContext
                ?? pendingRecord?.commercialContext,
            checkoutCompletionEventId: stored?.checkoutCompletionEventId
                ?? pendingRecord?.checkoutCompletionEventId,
            completionDeliveredAt: stored?.completionDeliveredAt,
            backendSyncedAt: stored?.backendSyncedAt
        )
        guard persistEvidence(evidence) else {
            LogError("TransactionObserver: Could not durably record transaction (transaction.id); leaving it unfinished")
            return
        }
        if !isRevoked, !persistLocalAccess(evidence) {
            LogError("TransactionObserver: Could not durably record local purchase access")
            return
        }
        if !isRevoked, evidence.distinctId == identityService.getDistinctId() {
            await applyLocalAccess(evidence)
        }
        guard await retireCheckoutRecovery(
            appAccountToken: transaction.appAccountToken,
            productId: transaction.productId,
            checkoutRecoveryExists: checkoutRecovery != nil
        ) else { return }

        // StoreKit finishing is local lifecycle work. It follows durable
        // evidence/access recording and never waits for Nuxie's backend.
        if policy.finishAfterRecording {
            await transaction.finish()
        }

        let synced = await syncTransactionWithOptions(
            transactionJws: transactionJwt,
            transactionId: transactionIdString,
            productId: transaction.productId,
            originalTransactionId: transaction.originalTransactionId,
            updateLocalFeatures: true,
            isRevoked: isRevoked
        )

        if synced {
            LogDebug("TransactionObserver: Transaction \(transaction.transactionId) finished")

            // Resolve an Ask-to-Buy/SCA purchase that the paywall is still
            // waiting on: the deferred transaction arrives via
            // Transaction.updates, not the original purchase() call.
            let resolvedPending = if policy.resolvesPendingPurchase {
                await transactionServiceProvider().consumePendingPurchase(
                    productId: transaction.productId,
                    distinctId: evidence.distinctId
                )
            } else {
                false
            }
            if resolvedPending,
               evidence.distinctId == identityService.getDistinctId() {
                let completed = await emitRecoveredPurchaseCompletion(
                    evidence: evidence,
                    routeToJourneys: false
                )
                if completed {
                    _ = removeEvidence(transactionId: transactionIdString)
                }
            }
        }
    }

    /// Completes the crash-recovery boundary in durable order: retire exact
    /// checkout attribution before finishing the transaction. If persistence
    /// fails, StoreKit redelivers and the observer retries without reusing a
    /// stale marker after a successful finish.
    func finishRecoveredTransaction(
        appAccountToken: UUID?,
        productId: String,
        checkoutRecoveryExists: Bool,
        finish: @Sendable () async -> Void
    ) async -> Bool {
        guard await retireCheckoutRecovery(
            appAccountToken: appAccountToken,
            productId: productId,
            checkoutRecoveryExists: checkoutRecoveryExists
        ) else { return false }
        // `finishRequired` is set only when Nuxie accepted lifecycle ownership
        // (native default mode or explicit delegate transfer).
        await finish()
        return true
    }

    /// Completes recovery from persisted evidence. Local access, StoreKit
    /// finishing, and stable analytics capture do not wait for the backend.
    /// Journey routing occurs only if the exact checkout is still active in
    /// this process; relaunch recovery is capture-only.
    func completeStoredTransactionRecovery(
        _ evidence: StoredTransactionEvidence,
        appAccountToken: UUID?,
        checkoutRecoveryExists: Bool,
        finish: @Sendable () async -> Void
    ) async -> Bool {
        let routeToJourneys = await transactionServiceProvider().isActiveCheckout(
            appAccountToken: appAccountToken,
            productId: evidence.productId,
            distinctId: evidence.distinctId
        )
        guard await finishRecoveredTransaction(
            appAccountToken: appAccountToken,
            productId: evidence.productId,
            checkoutRecoveryExists: checkoutRecoveryExists,
            finish: finish
        ) else { return false }

        await markTransactionFinished(transactionId: evidence.transactionId)
        if !evidence.isRevoked {
            _ = await emitRecoveredPurchaseCompletion(
                evidence: evidence,
                routeToJourneys: routeToJourneys
            )
        }
        let synced = await syncTransactionWithOptions(
            transactionJws: evidence.transactionJws,
            transactionId: evidence.transactionId,
            productId: evidence.productId,
            originalTransactionId: evidence.originalTransactionId,
            updateLocalFeatures: evidence.distinctId
                == identityService.getDistinctId(),
            isRevoked: evidence.isRevoked,
            retainEvidenceAfterSync: evidence.commercialContext != nil
        )
        if synced,
           storedEvidence()[evidence.transactionId]?.completionDeliveredAt != nil {
            removeEvidence(transactionId: evidence.transactionId)
        }
        return true
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
            return reconcileEvidenceAfterDeduplicatedSync(
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
            return reconcileEvidenceAfterDeduplicatedSync(
                transactionId: transactionId,
                retainEvidenceAfterSync: retainEvidenceAfterSync
            )
        }

        let distinctId = storedEvidence()[transactionId]?.distinctId
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
    ) -> Bool {
        // Transaction.updates can win the race with the direct purchase
        // callback. The callback may persist the same evidence after the
        // observer already synced it, so the deduplicated path must drain
        // that late write as well.
        if let stored = storedEvidence()[transactionId],
           retainEvidenceAfterSync
            || stored.finishRequired
            || (stored.commercialContext != nil
                && stored.completionDeliveredAt == nil) {
            return persistEvidence(stored.replacing(
                backendSyncedAt: dateProvider.now()
            ))
        }
        if !retainEvidenceAfterSync,
           storedEvidence()[transactionId]?.finishRequired != true {
            return removeEvidence(transactionId: transactionId)
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

                let acceptedEvidence = storedEvidence()[transactionId]
                syncedTransactionIds.insert(dedupeKey)
                if let stored = storedEvidence()[transactionId],
                   retainEvidenceAfterSync
                    || stored.finishRequired
                    || (stored.commercialContext != nil
                        && stored.completionDeliveredAt == nil) {
                    guard persistEvidence(stored.replacing(
                        backendSyncedAt: dateProvider.now()
                    )) else { return false }
                } else if !retainEvidenceAfterSync,
                          storedEvidence()[transactionId]?.finishRequired != true {
                    _ = removeEvidence(transactionId: transactionId)
                }

                if identityService.getDistinctId() == distinctId {
                    var properties: [String: Any] = [
                        "transaction_id": transactionId,
                        "original_transaction_id": originalTransactionId ?? "",
                        "product_id": productId ?? "",
                        "customer_id": response.customerId ?? ""
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

            LogError("TransactionObserver: Backend sync failed for transaction \(transactionId): \(response.error ?? "Unknown error")")
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

        await reconcileLocalAccessWithCurrentEntitlements()
        await processCurrentEntitlements(distinctId: distinctId)

        LogInfo("TransactionObserver: Finished syncing current entitlements")
    }

    private func processCurrentEntitlements(
        distinctId: String,
        excludingTransactionIds: Set<String> = []
    ) async {
        for item in await currentEntitlementRecoveryTransactions() {
            guard !excludingTransactionIds.contains(
                item.update.transactionId
            ) else { continue }
            await handleVerifiedTransaction(
                item.update,
                jwsRepresentation: item.jwsRepresentation,
                source: .nuxieEntitlementSync(distinctId: distinctId)
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
        let grants = optimisticLocalEntitlementGrants(
            product.localEntitlementGrants
        ).map {
            StoredLocalEntitlementGrant(
                featureId: $0.featureId,
                featureExternalId: $0.featureExternalId,
                allowanceType: $0.allowanceType,
                allowance: $0.allowance
            )
        }
        let existing = storedEvidence()[evidence.transactionId]
        guard existing?.distinctId == nil || existing?.distinctId == distinctId else {
            LogWarning("TransactionObserver: Refusing to move a purchase between customers")
            return false
        }
        guard existing?.productId == nil || existing?.productId == evidence.productId else {
            LogWarning("TransactionObserver: Refusing to move evidence between products")
            return false
        }
        let retainedGrants: [StoredLocalEntitlementGrant]
        if let existing, !existing.localEntitlementGrants.isEmpty {
            retainedGrants = existing.localEntitlementGrants
        } else {
            retainedGrants = grants
        }
        let featureIds = storeProductFeatureIds(product.localEntitlementGrants)
        let retainedFeatureIds = existing?.productFeatureIds.isEmpty == false
            ? existing!.productFeatureIds
            : featureIds
        let stored = StoredTransactionEvidence(
            scope: purchaseStorageScope,
            transactionJws: evidence.transactionJws,
            transactionId: evidence.transactionId,
            originalTransactionId: evidence.originalTransactionId,
            productId: evidence.productId,
            distinctId: distinctId,
            recordedAt: existing?.recordedAt ?? dateProvider.now(),
            productFeatureIds: retainedFeatureIds,
            localEntitlementGrants: retainedGrants,
            isRevoked: false,
            finishRequired: existing?.finishRequired == true || finishRequired,
            commercialContext: existing?.commercialContext ?? product.purchaseContext,
            checkoutCompletionEventId: existing?.checkoutCompletionEventId,
            completionDeliveredAt: existing?.completionDeliveredAt,
            backendSyncedAt: existing?.backendSyncedAt
        )
        guard persistEvidence(stored) else { return false }
        guard persistLocalAccess(stored) else { return false }
        if identityService.getDistinctId() == distinctId {
            await applyLocalAccess(stored)
        }
        return true
    }

    func useFeatureWithPendingPurchase(
        distinctId: String,
        featureId: String,
        amount: Double,
        entityId: String?,
        metadata: [String: AnyCodable]?
    ) async throws -> FeatureUsageResult? {
        // Provider-owned delegate results never create transaction evidence.
        // A delegate that returns StoreKit evidence explicitly transfers that
        // native transaction to Nuxie, so delegate configuration alone must
        // not make an otherwise eligible record unusable here.
        guard !isStopped,
              purchaseStorageScope.storeEnvironment == .appStore,
              amount.isFinite,
              amount > 0,
              let usageApi = api as? PurchaseBackedFeatureUsing else {
            return nil
        }

        while true {
            guard !isStopped else { return nil }
            guard identityService.getDistinctId() == distinctId else {
                throw CancellationError()
            }
            let candidates = storedEvidence().values
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
                guard identityService.getDistinctId() == distinctId else {
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
                      persistEvidence(current.replacing(
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
                    _ = removeEvidence(transactionId: evidence.transactionId)
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
        let transactionService = transactionServiceProvider()
        let recovery = await transactionService.checkoutRecoveryRecord(
            appAccountToken: appAccountToken,
            productId: evidence.productId
        )
        if recovery?.observedTransactionId == evidence.transactionId {
            return .recovered
        }
        guard let evidenceAuthority = await resolvedEvidenceAuthority(
            transactionService: transactionService,
            appAccountToken: appAccountToken,
            productId: evidence.productId,
            checkoutRecovery: recovery,
            source: .storeUpdates
        ) else { return .noMatch }
        guard evidenceAuthority != .providerConnector,
              evidenceAuthority != .ambiguous else { return .noMatch }
        let durableAccountOwner = await transactionService.purchaseAccountOwner(
            appAccountToken: appAccountToken
        )
        let expectedDistinctId = attributedDistinctId
            ?? identityService.getDistinctId()
        let deterministicAccountOwner = appAccountToken
            == purchaseStorageScope.appAccountToken(
                distinctId: expectedDistinctId
            )
            ? expectedDistinctId
            : nil
        let distinctId = recovery?.distinctId
            ?? durableAccountOwner
            ?? deterministicAccountOwner
        guard let distinctId else { return .noMatch }
        let routeToJourneys = await transactionService.isActiveCheckout(
            appAccountToken: appAccountToken,
            productId: evidence.productId,
            distinctId: distinctId
        )
        let completionReportedAt = recovery?.completionReportedAt
        let stored = StoredTransactionEvidence(
            scope: recovery?.scope ?? purchaseStorageScope,
            transactionJws: evidence.transactionJws,
            transactionId: evidence.transactionId,
            originalTransactionId: evidence.originalTransactionId,
            productId: evidence.productId,
            distinctId: distinctId,
            recordedAt: recovery?.recordedAt ?? dateProvider.now(),
            productFeatureIds: recovery?.productFeatureIds ?? [],
            localEntitlementGrants: recovery?.localEntitlementGrants ?? [],
            isRevoked: false,
            finishRequired: finishRequired,
            commercialContext: recovery?.commercialContext,
            checkoutCompletionEventId: recovery?.checkoutCompletionEventId,
            completionDeliveredAt: completionReportedAt,
            backendSyncedAt: nil
        )
        guard persistEvidence(stored), persistLocalAccess(stored) else {
            return .recovered
        }
        if distinctId == identityService.getDistinctId() {
            await applyLocalAccess(stored)
        }
        if let recovery,
           recovery.evidenceAuthority == .outcomeOnlyDelegate,
           recovery.state == .checkout,
           completionReportedAt == nil {
            guard await transactionService.markOutcomeOnlyTransactionObserved(
                recovery,
                transactionId: evidence.transactionId
            ) else { return .recovered }
        } else {
            guard await retireCheckoutRecovery(
                appAccountToken: appAccountToken,
                productId: evidence.productId,
                checkoutRecoveryExists: recovery != nil
            ) else { return .recovered }
        }
        if finishRequired {
            await evidence.finish()
            await markTransactionFinished(transactionId: evidence.transactionId)
        }
        let completionDelivered = if completionReportedAt != nil {
            true
        } else {
            await emitRecoveredPurchaseCompletion(
                evidence: stored,
                routeToJourneys: routeToJourneys
            )
        }
        if completionDelivered,
           completionReportedAt == nil,
           recovery?.evidenceAuthority == .outcomeOnlyDelegate,
           recovery?.state == .checkout {
            guard await transactionService.markOutcomeOnlyCompletionReported(
                appAccountToken: appAccountToken,
                productId: evidence.productId,
                transactionId: evidence.transactionId,
                reportedAt: dateProvider.now()
            ) else { return .recovered }
        }
        let synced = await syncTransactionWithOptions(
            transactionJws: evidence.transactionJws,
            transactionId: evidence.transactionId,
            productId: evidence.productId,
            originalTransactionId: evidence.originalTransactionId,
            updateLocalFeatures: distinctId == identityService.getDistinctId(),
            retainEvidenceAfterSync: stored.commercialContext != nil
        )
        let durablyCompleted = completionDelivered
            || storedEvidence()[evidence.transactionId]?
                .completionDeliveredAt != nil
        if synced, durablyCompleted {
            removeEvidence(transactionId: evidence.transactionId)
        }
        return .recovered
    }

    private func emitRecoveredPurchaseCompletion(
        evidence: StoredTransactionEvidence,
        routeToJourneys: Bool
    ) async -> Bool {
        guard evidence.distinctId == identityService.getDistinctId(),
              let context = evidence.commercialContext else { return false }
        if storedEvidence()[evidence.transactionId]?.completionDeliveredAt != nil {
            return true
        }
        guard await claimPurchaseCompletion(
            transactionId: evidence.transactionId
        ) else { return false }
        let properties = purchaseCompletionProperties(
            context: context,
            transactionId: evidence.transactionId,
            testStore: evidence.scope.storeEnvironment == .testStore
        )
        let transactionCompletionEventId = await purchaseCompletionEventId(
            transactionId: evidence.transactionId
        )
        let eventId = evidence.checkoutCompletionEventId
            ?? transactionCompletionEventId
        let captured = if routeToJourneys {
            await eventSink.capture(
                SystemEventNames.purchaseCompleted,
                properties: properties,
                eventId: eventId,
                distinctId: evidence.distinctId
            )
        } else {
            await eventSink.captureOnly(
                SystemEventNames.purchaseCompleted,
                properties: properties,
                eventId: eventId,
                distinctId: evidence.distinctId
            )
        }
        guard captured else {
            await releasePurchaseCompletionClaim(
                transactionId: evidence.transactionId
            )
            return false
        }
        let marked = await markPurchaseCompletionCaptured(
            transactionId: evidence.transactionId
        )
        if !marked {
            await releasePurchaseCompletionClaim(
                transactionId: evidence.transactionId
            )
        }
        return marked
    }

    func markTransactionFinished(transactionId: String) async {
        guard var stored = storedEvidence()[transactionId] else { return }
        stored = StoredTransactionEvidence(
            scope: stored.scope,
            transactionJws: stored.transactionJws,
            transactionId: stored.transactionId,
            originalTransactionId: stored.originalTransactionId,
            productId: stored.productId,
            distinctId: stored.distinctId,
            recordedAt: stored.recordedAt,
            productFeatureIds: stored.productFeatureIds,
            localEntitlementGrants: stored.localEntitlementGrants,
            isRevoked: stored.isRevoked,
            finishRequired: false,
            commercialContext: stored.commercialContext,
            checkoutCompletionEventId: stored.checkoutCompletionEventId,
            completionDeliveredAt: stored.completionDeliveredAt,
            backendSyncedAt: stored.backendSyncedAt
        )
        if syncedTransactionIds.contains(transactionId),
           stored.commercialContext == nil || stored.completionDeliveredAt != nil {
            _ = removeEvidence(transactionId: transactionId)
        } else {
            _ = persistEvidence(stored)
        }
    }

    func claimPurchaseCompletion(transactionId: String) async -> Bool {
        guard !completedPurchaseEventTransactionIds.contains(transactionId) else {
            return false
        }
        if let stored = storedEvidence()[transactionId] {
            guard stored.completionDeliveredAt == nil else { return false }
        }
        completedPurchaseEventTransactionIds.insert(transactionId)
        return true
    }

    func markPurchaseCompletionCaptured(transactionId: String) async -> Bool {
        guard let stored = storedEvidence()[transactionId] else { return true }
        guard stored.completionDeliveredAt == nil else { return true }
        let delivered = StoredTransactionEvidence(
                scope: stored.scope,
                transactionJws: stored.transactionJws,
                transactionId: stored.transactionId,
                originalTransactionId: stored.originalTransactionId,
                productId: stored.productId,
                distinctId: stored.distinctId,
                recordedAt: stored.recordedAt,
                productFeatureIds: stored.productFeatureIds,
                localEntitlementGrants: stored.localEntitlementGrants,
                isRevoked: stored.isRevoked,
                finishRequired: stored.finishRequired,
                commercialContext: stored.commercialContext,
                checkoutCompletionEventId: stored.checkoutCompletionEventId,
                completionDeliveredAt: dateProvider.now(),
                backendSyncedAt: stored.backendSyncedAt
        )
        guard persistEvidence(delivered) else { return false }
        if syncedTransactionIds.contains(transactionId),
           !delivered.finishRequired {
            return removeEvidence(transactionId: transactionId)
        }
        return true
    }

    func releasePurchaseCompletionClaim(transactionId: String) async {
        completedPurchaseEventTransactionIds.remove(transactionId)
    }

    func purchaseCompletionEventId(transactionId: String) async -> String {
        (["purchase-completed"] + purchaseStorageScope.storageComponents
            + [transactionId]).joined(separator: ":")
    }

    private func storedEvidence() -> [String: StoredTransactionEvidence] {
        if let evidenceByTransactionId { return evidenceByTransactionId }
        let loaded = evidenceStore.load().filter {
            $0.value.scope == purchaseStorageScope
        }
        let cutoff = dateProvider.date(
            byAddingTimeInterval: -Self.evidenceRetention,
            to: dateProvider.now()
        )
        let retained = loaded.filter { $0.value.recordedAt > cutoff }
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

    private func persistEvidence(_ evidence: StoredTransactionEvidence) -> Bool {
        guard evidence.scope == purchaseStorageScope else { return false }
        var entries = storedEvidence()
        entries[evidence.transactionId] = evidence
        guard evidenceStore.save(entries) else { return false }
        evidenceByTransactionId = entries
        return true
    }

    @discardableResult
    func removeEvidence(transactionId: String) -> Bool {
        var entries = storedEvidence()
        entries.removeValue(forKey: transactionId)
        guard evidenceStore.save(entries) else { return false }
        evidenceByTransactionId = entries
        return true
    }

    private func storedLocalAccess() -> [String: StoredLocalPurchaseAccess] {
        localAccessStore.load()
    }

    @discardableResult
    private func persistLocalAccess(_ evidence: StoredTransactionEvidence) -> Bool {
        guard !evidence.localEntitlementGrants.isEmpty else { return true }
        let access = StoredLocalPurchaseAccess(
            scope: evidence.scope,
            transactionId: evidence.transactionId,
            originalTransactionId: evidence.originalTransactionId,
            productId: evidence.productId,
            distinctId: evidence.distinctId,
            grants: evidence.localEntitlementGrants,
            state: .active
        )
        return localAccessStore.upsert(access)
    }

    private func removeLocalAccess(originalTransactionId: String) async {
        guard let revoked = localAccessStore.markRevoked(
            originalTransactionId: originalTransactionId
        ) else {
            LogError("TransactionObserver: Could not persist revoked local access")
            return
        }
        for access in revoked {
            if access.distinctId == identityService.getDistinctId() {
                await featureService.removeLocalPurchase(
                    transactionId: access.transactionId,
                    grants: storeProductGrants(access.grants)
                )
            }
        }
    }

    private func rehydrateLocalAccessForCurrentCustomer() async {
        let distinctId = identityService.getDistinctId()
        let accesses = storedLocalAccess().values.filter {
            $0.scope == purchaseStorageScope && $0.distinctId == distinctId
        }
        // Apply denials first so an independently active transaction for the
        // same feature wins during repurchase or overlapping subscriptions.
        for access in accesses where access.state == .revoked {
            await featureService.removeLocalPurchase(
                transactionId: access.transactionId,
                grants: storeProductGrants(access.grants)
            )
        }
        for access in accesses where access.state == .active {
            await applyLocalAccess(access)
        }
    }

    private func reconcileLocalAccessWithCurrentEntitlements() async {
        let activeOriginalTransactionIDs = await activeStoreOriginalTransactionIDs()

        guard let revoked = localAccessStore.markInactiveRevoked(
            activeOriginalTransactionIds: activeOriginalTransactionIDs
        ) else {
            LogError("TransactionObserver: Could not reconcile local access ledger")
            return
        }
        for access in revoked {
            if access.distinctId == identityService.getDistinctId() {
                await featureService.removeLocalPurchase(
                    transactionId: access.transactionId,
                    grants: storeProductGrants(access.grants)
                )
            }
        }
        await rehydrateLocalAccessForCurrentCustomer()
    }

    private func applyLocalAccess(_ evidence: StoredTransactionEvidence) async {
        let grants = storeProductGrants(evidence.localEntitlementGrants)
        await featureService.applyLocalPurchase(
            grants: grants,
            transactionId: evidence.transactionId
        )
    }

    private func applyLocalAccess(_ access: StoredLocalPurchaseAccess) async {
        let grants = storeProductGrants(access.grants)
        await featureService.applyLocalPurchase(
            grants: grants,
            transactionId: access.transactionId
        )
    }

    private func storeProductGrants(
        _ grants: [StoredLocalEntitlementGrant]
    ) -> [StoreProduct.LocalEntitlementGrant] {
        grants.map {
            StoreProduct.LocalEntitlementGrant(
                featureId: $0.featureId,
                featureExternalId: $0.featureExternalId,
                allowanceType: $0.allowanceType,
                allowance: $0.allowance
            )
        }
    }
}
