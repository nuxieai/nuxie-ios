import Foundation
import StoreKit

protocol TransactionObserverProtocol: Actor {
    func startListening()
    func stopListening()
    func syncTransaction(
        transactionJws: String,
        transactionId: String,
        productId: String?,
        originalTransactionId: String?
    ) async -> Bool
    func syncCurrentEntitlements() async
    func recordVerifiedPurchase(
        evidence: StoreTransactionEvidence,
        product: StoreProduct
    ) async
}

extension TransactionObserverProtocol {
    func recordVerifiedPurchase(
        evidence: StoreTransactionEvidence,
        product: StoreProduct
    ) async {}
}

/// Observes StoreKit 2 Transaction.updates stream and syncs verified transactions with the backend
///
/// By observing Transaction.updates directly, we catch all purchases regardless of how they
/// were initiated (via SDK, app's own StoreKit code, or even the App Store directly).
internal actor TransactionObserver: TransactionObserverProtocol {

    // MARK: - Dependencies

    private let api: PurchaseSynchronizing
    private let featureService: FeatureServiceProtocol
    private let identityService: IdentityServiceProtocol
    private let settings: PurchaseSettingsProviding
    private let eventSink: SystemEventSink
    private let transactionServiceProvider: @Sendable () -> TransactionService
    private let evidenceStore: TransactionEvidenceStoreProtocol
    private var isObserverMode: Bool {
        settings.purchaseDelegate() != nil
            || settings.purchaseHandlingMode() == .observer
    }

    // MARK: - Properties

    /// Task observing Transaction.updates
    private var updateTask: Task<Void, Never>?

    /// Set of transaction IDs we've already synced (to avoid duplicates within session)
    private var syncedTransactionIds: Set<String> = []
    private var evidenceByTransactionId: [String: StoredTransactionEvidence]?

    // MARK: - Init

    init(
        api: PurchaseSynchronizing,
        features: FeatureServiceProtocol,
        identity: IdentityServiceProtocol,
        settings: PurchaseSettingsProviding,
        eventSink: SystemEventSink,
        transactionServiceProvider: @escaping @Sendable () -> TransactionService,
        evidenceStore: TransactionEvidenceStoreProtocol = TransactionEvidenceStore()
    ) {
        self.api = api
        self.featureService = features
        self.identityService = identity
        self.settings = settings
        self.eventSink = eventSink
        self.transactionServiceProvider = transactionServiceProvider
        self.evidenceStore = evidenceStore
    }

    // MARK: - Lifecycle

    /// Start listening to Transaction.updates
    /// Call this during SDK setup
    func startListening() {
        guard updateTask == nil else {
            LogDebug("TransactionObserver: Already listening")
            return
        }

        LogInfo("TransactionObserver: Starting to listen for transaction updates")

        updateTask = Task { [weak self] in
            await self?.processStoredEvidence()
            // First, process any unfinished transactions from previous sessions
            await self?.processUnfinishedTransactions()

            // Then listen for new transaction updates
            for await result in Transaction.updates {
                guard let self = self else { break }
                await self.handleTransactionResult(result)
            }
        }
    }

    /// Stop listening to Transaction.updates
    func stopListening() {
        updateTask?.cancel()
        updateTask = nil
        LogInfo("TransactionObserver: Stopped listening")
    }

    // MARK: - Transaction Processing

    /// Process any unfinished transactions from previous app sessions
    private func processUnfinishedTransactions() async {
        LogDebug("TransactionObserver: Checking for unfinished transactions")

        for await result in Transaction.unfinished {
            await handleTransactionResult(result)
        }

        LogDebug("TransactionObserver: Finished processing unfinished transactions")
    }

    /// Retry evidence that was safely recorded and finished locally while the
    /// backend was unavailable. StoreKit will not replay a transaction after
    /// finishing, so this queue is the recovery source on relaunch.
    private func processStoredEvidence() async {
        let currentDistinctId = identityService.getDistinctId()
        for evidence in storedEvidence().values where evidence.distinctId == currentDistinctId {
            await applyLocalAccess(evidence)
            _ = await syncTransaction(
                transactionJws: evidence.transactionJws,
                transactionId: evidence.transactionId,
                productId: evidence.productId,
                originalTransactionId: evidence.originalTransactionId
            )
        }
    }

    /// Handle a transaction verification result
    private func handleTransactionResult(_ result: VerificationResult<Transaction>) async {
        switch result {
        case .verified(let transaction):
            let transactionJwt = result.jwsRepresentation
            await handleVerifiedTransaction(transaction, jwsRepresentation: transactionJwt)

        case .unverified(let transaction, let error):
            LogError("TransactionObserver: Unverified transaction \(transaction.id): \(error)")
            // Don't sync unverified transactions - they may be fraudulent
        }
    }

    /// Handle a verified transaction by syncing with backend
    private func handleVerifiedTransaction(_ transaction: Transaction, jwsRepresentation transactionJwt: String) async {
        let transactionIdString = String(transaction.id)

        LogInfo("TransactionObserver: Processing verified transaction \(transaction.id) for product \(transaction.productID)")

        if transaction.revocationDate != nil {
            LogDebug("TransactionObserver: Transaction \(transaction.id) is revoked; syncing to notify backend")
        }

        // Skip upgraded subscriptions (user has a higher tier now)
        if transaction.isUpgraded {
            LogDebug("TransactionObserver: Skipping upgraded transaction \(transaction.id)")
            if !isObserverMode {
                await transaction.finish()
            }
            return
        }

        guard !transactionJwt.isEmpty else {
            LogError("TransactionObserver: Empty JWS for transaction \(transaction.id)")
            // Don't finish - let StoreKit retry
            return
        }

        let stored = storedEvidence()[transactionIdString]
        if let stored, stored.distinctId != identityService.getDistinctId() {
            LogWarning("TransactionObserver: Ignoring evidence for a different Nuxie customer")
            return
        }
        persistEvidence(
            StoredTransactionEvidence(
                transactionJws: transactionJwt,
                transactionId: transactionIdString,
                originalTransactionId: String(transaction.originalID),
                productId: transaction.productID,
                distinctId: stored?.distinctId ?? identityService.getDistinctId(),
                recordedAt: stored?.recordedAt ?? Date(),
                localEntitlementGrants: stored?.localEntitlementGrants ?? []
            )
        )
        if let stored {
            await applyLocalAccess(stored)
        }

        // StoreKit finishing is local lifecycle work. It follows durable
        // evidence/access recording and never waits for Nuxie's backend.
        if !isObserverMode {
            await transaction.finish()
        }

        let synced = await syncTransaction(
            transactionJws: transactionJwt,
            transactionId: transactionIdString,
            productId: transaction.productID,
            originalTransactionId: String(transaction.originalID)
        )

        if synced {
            // Observer mode: the host app (or another SDK) owns transaction
            // finishing — finishing here would remove a consumable from
            // Transaction.unfinished before the host delivered its content.
            if isObserverMode {
                LogDebug("TransactionObserver: Observer mode — leaving transaction \(transaction.id) unfinished")
            } else {
                LogDebug("TransactionObserver: Transaction \(transaction.id) finished")
            }

            // Resolve an Ask-to-Buy/SCA purchase that the paywall is still
            // waiting on: the deferred transaction arrives via
            // Transaction.updates, not the original purchase() call.
            let resolvedPending = await transactionServiceProvider()
                .consumePendingPurchase(productId: transaction.productID)
            if resolvedPending {
                eventSink.emit(SystemEventNames.purchaseCompleted, properties: [
                    "product_id": transaction.productID,
                    "transaction_id": String(transaction.id),
                    "source": "deferred_transaction"
                ])
            }
        }
    }

    /// Sync a verified transaction JWS with backend and update features
    /// Returns true if the transaction is synced or already known.
    func syncTransaction(
        transactionJws: String,
        transactionId: String,
        productId: String?,
        originalTransactionId: String?
    ) async -> Bool {
        // Each renewal is a distinct verified transaction. Deduping by the
        // original subscription ID would silently drop later renewals.
        let preferredId = transactionId.isEmpty
            ? (originalTransactionId?.isEmpty == false ? originalTransactionId : nil)
            : transactionId
        let dedupeKey = preferredId ?? transactionJws

        if syncedTransactionIds.contains(dedupeKey) {
            LogDebug("TransactionObserver: Transaction already synced, finishing fast path")
            return true
        }

        let distinctId = storedEvidence()[transactionId]?.distinctId
            ?? identityService.getDistinctId()

        do {
            let response = try await api.syncTransaction(
                transactionJwt: transactionJws,
                distinctId: distinctId
            )

            if response.success {
                if let features = response.features {
                    await featureService.updateFromPurchase(features)
                }

                syncedTransactionIds.insert(dedupeKey)
                removeEvidence(transactionId: transactionId)

                eventSink.emit(SystemEventNames.purchaseSynced, properties: [
                    "transaction_id": transactionId,
                    "original_transaction_id": originalTransactionId ?? "",
                    "product_id": productId ?? "",
                    "customer_id": response.customerId ?? ""
                ])

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
    func syncCurrentEntitlements() async {
        LogInfo("TransactionObserver: Syncing current entitlements")

        for await result in Transaction.currentEntitlements {
            await handleTransactionResult(result)
        }

        LogInfo("TransactionObserver: Finished syncing current entitlements")
    }

    func recordVerifiedPurchase(
        evidence: StoreTransactionEvidence,
        product: StoreProduct
    ) async {
        let distinctId = identityService.getDistinctId()
        let grants = product.localEntitlementGrants.map {
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
            return
        }
        let retainedGrants: [StoredLocalEntitlementGrant]
        if let existing, !existing.localEntitlementGrants.isEmpty {
            retainedGrants = existing.localEntitlementGrants
        } else {
            retainedGrants = grants
        }
        let stored = StoredTransactionEvidence(
            transactionJws: evidence.transactionJws,
            transactionId: evidence.transactionId,
            originalTransactionId: evidence.originalTransactionId,
            productId: evidence.productId,
            distinctId: distinctId,
            recordedAt: existing?.recordedAt ?? Date(),
            localEntitlementGrants: retainedGrants
        )
        persistEvidence(stored)
        await applyLocalAccess(stored)
    }

    private func storedEvidence() -> [String: StoredTransactionEvidence] {
        if let evidenceByTransactionId { return evidenceByTransactionId }
        let loaded = evidenceStore.load()
        evidenceByTransactionId = loaded
        return loaded
    }

    private func persistEvidence(_ evidence: StoredTransactionEvidence) {
        var entries = storedEvidence()
        entries[evidence.transactionId] = evidence
        evidenceByTransactionId = entries
        evidenceStore.save(entries)
    }

    private func removeEvidence(transactionId: String) {
        var entries = storedEvidence()
        entries.removeValue(forKey: transactionId)
        evidenceByTransactionId = entries
        evidenceStore.save(entries)
    }

    private func applyLocalAccess(_ evidence: StoredTransactionEvidence) async {
        let grants = evidence.localEntitlementGrants.map {
            StoreProduct.LocalEntitlementGrant(
                featureId: $0.featureId,
                featureExternalId: $0.featureExternalId,
                allowanceType: $0.allowanceType,
                allowance: $0.allowance
            )
        }
        await featureService.applyLocalPurchase(
            grants: grants,
            transactionId: evidence.transactionId,
            observedAt: evidence.recordedAt
        )
    }
}
