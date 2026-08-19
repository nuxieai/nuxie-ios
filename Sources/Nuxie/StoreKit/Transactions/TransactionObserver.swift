import Foundation
import StoreKit

func providerLocalAccessTransactionId(storeProductId: String) -> String {
    "nuxie-provider-\(storeProductId)"
}

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
        product: StoreProduct,
        distinctId: String,
        finishRequired: Bool
    ) async -> Bool
    func markTransactionFinished(transactionId: String) async
    func retryStoredEvidence() async
}

extension TransactionObserverProtocol {
    func recordVerifiedPurchase(
        evidence: StoreTransactionEvidence,
        product: StoreProduct,
        distinctId: String,
        finishRequired: Bool
    ) async -> Bool { true }
    func markTransactionFinished(transactionId: String) async {}
    func retryStoredEvidence() async {}
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
    private let localAccessStore: LocalPurchaseAccessStoreProtocol
    private let activeStoreOriginalTransactionIDs: @Sendable () async -> Set<String>
    private var isProviderOwnedMode: Bool {
        settings.purchaseDelegate() != nil
    }

    private var isObserverMode: Bool {
        isProviderOwnedMode || settings.purchaseHandlingMode() == .observer
    }

    // MARK: - Properties

    /// Task observing Transaction.updates
    private var updateTask: Task<Void, Never>?

    /// Set of transaction IDs we've already synced (to avoid duplicates within session)
    private var syncedTransactionIds: Set<String> = []
    private var evidenceByTransactionId: [String: StoredTransactionEvidence]?
    private var localAccessByTransactionId: [String: StoredLocalPurchaseAccess]?

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
        activeStoreOriginalTransactionIDs: @escaping @Sendable () async -> Set<String> = {
            var originalTransactionIDs: Set<String> = []
            for await result in Transaction.currentEntitlements {
                guard case .verified(let transaction) = result,
                      transaction.revocationDate == nil,
                      !transaction.isUpgraded else { continue }
                originalTransactionIDs.insert(String(transaction.originalID))
            }
            return originalTransactionIDs
        }
    ) {
        self.api = api
        self.featureService = features
        self.identityService = identity
        self.settings = settings
        self.eventSink = eventSink
        self.transactionServiceProvider = transactionServiceProvider
        self.evidenceStore = evidenceStore
        self.localAccessStore = localAccessStore
        self.activeStoreOriginalTransactionIDs = activeStoreOriginalTransactionIDs
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
            await self?.reconcileLocalAccessWithCurrentEntitlements()
            // First, process any unfinished transactions from previous sessions
            await self?.processUnfinishedTransactions()
            // Anything still stored after the unfinished scan was already
            // finished before the previous process died. Retry its backend
            // submission, then retire it once accepted.
            await self?.processStoredEvidence()

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
        for evidence in storedEvidence().values {
            let synced = await syncTransactionWithOptions(
                transactionJws: evidence.transactionJws,
                transactionId: evidence.transactionId,
                productId: evidence.productId,
                originalTransactionId: evidence.originalTransactionId,
                updateLocalFeatures: evidence.distinctId == currentDistinctId,
                isRevoked: evidence.isRevoked
            )
            if synced {
                // Transaction.unfinished was drained before this method. A
                // finish-required record that remains here represents the
                // narrow crash window after StoreKit finished but before the
                // evidence flag was cleared, so it is now safe to retire.
                removeEvidence(transactionId: evidence.transactionId)
                // Pending markers and Journey events are customer-scoped.
                // Evidence may be retried for its recorded owner after an
                // identity transition, but it must not resolve the active
                // customer's pending paywall or emit completion for them.
                if evidence.distinctId == currentDistinctId {
                    let resolvedPending = await transactionServiceProvider()
                        .consumePendingPurchase(
                            productId: evidence.productId,
                            distinctId: evidence.distinctId
                        )
                    if resolvedPending {
                        eventSink.emit(SystemEventNames.purchaseCompleted, properties: [
                            "product_id": evidence.productId,
                            "transaction_id": evidence.transactionId,
                            "source": "deferred_transaction"
                        ])
                    }
                }
            }
        }
    }

    /// Retry all durable evidence after an identity transition. Evidence is
    /// always submitted to the customer it was recorded for; local grants are
    /// only re-applied when that customer is still active.
    func retryStoredEvidence() async {
        await reconcileLocalAccessWithCurrentEntitlements()
        await processUnfinishedTransactions()
        await processStoredEvidence()
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
        let isRevoked = transaction.revocationDate != nil
        let stored = storedEvidence()[transactionIdString]

        if isRevoked {
            LogDebug("TransactionObserver: Transaction \(transaction.id) is revoked")
            // Provider-owned purchases are projected locally for immediate
            // offline access, but the provider remains the receipt authority.
            // Remove both the provider's product-scoped projection and any
            // native evidence projection before any recovery or sync path.
            if isProviderOwnedMode {
                await featureService.removeLocalPurchase(
                    transactionId: providerLocalAccessTransactionId(
                        storeProductId: transaction.productID
                    )
                )
            }
            await featureService.removeLocalPurchase(transactionId: transactionIdString)
            await removeLocalAccess(
                originalTransactionId: String(transaction.originalID)
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
                    LogError("TransactionObserver: Empty revocation JWS for transaction \(transaction.id)")
                    return
                }
                recoveryEvidence = StoredTransactionEvidence(
                    transactionJws: transactionJwt,
                    transactionId: transactionIdString,
                    originalTransactionId: String(transaction.originalID),
                    productId: transaction.productID,
                    distinctId: stored.distinctId,
                    recordedAt: stored.recordedAt,
                    localEntitlementGrants: stored.localEntitlementGrants,
                    isRevoked: true,
                    finishRequired: true
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
            let synced = await syncTransactionWithOptions(
                transactionJws: recoveryEvidence.transactionJws,
                transactionId: recoveryEvidence.transactionId,
                productId: recoveryEvidence.productId,
                originalTransactionId: recoveryEvidence.originalTransactionId,
                updateLocalFeatures: true,
                isRevoked: recoveryEvidence.isRevoked
            )
            guard synced else { return }
            // `finishRequired` is set only when Nuxie accepted lifecycle
            // ownership (native default mode or explicit delegate transfer).
            await transaction.finish()
            await markTransactionFinished(transactionId: transactionIdString)
            return
        }

        if isRevoked, isProviderOwnedMode {
            LogDebug("TransactionObserver: Revoked provider-owned transaction left to delegate")
            return
        }

        // A configured provider owns receipt submission, entitlement state,
        // and transaction finishing. Nuxie only observes the delegate result
        // for Journey UX; it must not become a second transaction owner.
        guard !isProviderOwnedMode else {
            let currentDistinctId = identityService.getDistinctId()
            let transactionService = transactionServiceProvider()
            if await transactionService.pendingPurchaseRecord(
                productId: transaction.productID,
                distinctId: currentDistinctId
            ) != nil {
                let storedGrants = await transactionService.pendingPurchaseGrants(
                    productId: transaction.productID,
                    distinctId: currentDistinctId
                ) ?? []
                if await transactionService.consumePendingPurchase(
                    productId: transaction.productID,
                    distinctId: currentDistinctId
                ) {
                    if !storedGrants.isEmpty {
                        await featureService.applyLocalPurchase(
                            grants: storedGrants.map {
                                StoreProduct.LocalEntitlementGrant(
                                    featureId: $0.featureId,
                                    featureExternalId: $0.featureExternalId,
                                    allowanceType: $0.allowanceType,
                                    allowance: $0.allowance
                                )
                            },
                            transactionId: transactionIdString
                        )
                    }
                    eventSink.emit(SystemEventNames.purchaseCompleted, properties: [
                        "product_id": transaction.productID,
                        "transaction_id": transactionIdString,
                        "source": "deferred_transaction"
                    ])
                }
            }
            LogDebug("TransactionObserver: Provider-owned transaction \(transaction.id) left to delegate")
            return
        }

        LogInfo("TransactionObserver: Processing verified transaction \(transaction.id) for product \(transaction.productID)")

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

        if let stored, stored.distinctId != identityService.getDistinctId() {
            LogWarning("TransactionObserver: Ignoring evidence for a different Nuxie customer")
            // Durable evidence has already captured this transaction. Drain
            // StoreKit's unfinished queue when Nuxie owns finishing; otherwise
            // observer mode intentionally leaves finishing to the host.
            if !isObserverMode {
                await transaction.finish()
            }
            return
        }
        let pendingOwnership = await transactionServiceProvider()
            .pendingPurchaseOwnership(productId: transaction.productID)
        let pendingRecord: PendingPurchaseRecord?
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
        let pendingDistinctId = pendingRecord?.distinctId
        let pendingGrants = pendingRecord?.localEntitlementGrants
        let evidenceDistinctId = stored?.distinctId
            ?? pendingDistinctId
            ?? identityService.getDistinctId()
        let evidenceRecordedAt = stored?.recordedAt ?? Date()
        let evidenceGrants = stored?.localEntitlementGrants
            ?? pendingGrants
            ?? []
        let evidence = StoredTransactionEvidence(
            transactionJws: transactionJwt,
            transactionId: transactionIdString,
            originalTransactionId: String(transaction.originalID),
            productId: transaction.productID,
            distinctId: evidenceDistinctId,
            recordedAt: evidenceRecordedAt,
            localEntitlementGrants: evidenceGrants,
            isRevoked: isRevoked,
            finishRequired: stored?.finishRequired ?? false
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

        // StoreKit finishing is local lifecycle work. It follows durable
        // evidence/access recording and never waits for Nuxie's backend.
        if !isObserverMode {
            await transaction.finish()
        }

        let synced = await syncTransactionWithOptions(
            transactionJws: transactionJwt,
            transactionId: transactionIdString,
            productId: transaction.productID,
            originalTransactionId: String(transaction.originalID),
            updateLocalFeatures: true,
            isRevoked: isRevoked
        )

        if synced {
            LogDebug("TransactionObserver: Transaction \(transaction.id) finished")

            // Resolve an Ask-to-Buy/SCA purchase that the paywall is still
            // waiting on: the deferred transaction arrives via
            // Transaction.updates, not the original purchase() call.
            let resolvedPending = await transactionServiceProvider()
                .consumePendingPurchase(
                    productId: transaction.productID,
                    distinctId: evidence.distinctId
                )
            if resolvedPending,
               evidence.distinctId == identityService.getDistinctId() {
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
        isRevoked: Bool = false
    ) async -> Bool {
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
            // Transaction.updates can win the race with the direct purchase
            // callback. The callback may persist the same evidence after the
            // observer already synced it, so the deduplicated path must drain
            // that late write as well.
            if storedEvidence()[transactionId]?.finishRequired != true {
                removeEvidence(transactionId: transactionId)
            }
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
                if updateLocalFeatures,
                   identityService.getDistinctId() == distinctId,
                   let features = response.features {
                    await featureService.updateFromPurchase(features)
                }

                syncedTransactionIds.insert(dedupeKey)
                if storedEvidence()[transactionId]?.finishRequired != true {
                    removeEvidence(transactionId: transactionId)
                }

                if identityService.getDistinctId() == distinctId {
                    eventSink.emit(SystemEventNames.purchaseSynced, properties: [
                        "transaction_id": transactionId,
                        "original_transaction_id": originalTransactionId ?? "",
                        "product_id": productId ?? "",
                        "customer_id": response.customerId ?? ""
                    ])
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
    func syncCurrentEntitlements() async {
        LogInfo("TransactionObserver: Syncing current entitlements")

        await reconcileLocalAccessWithCurrentEntitlements()
        for await result in Transaction.currentEntitlements {
            await handleTransactionResult(result)
        }

        LogInfo("TransactionObserver: Finished syncing current entitlements")
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
        let stored = StoredTransactionEvidence(
            transactionJws: evidence.transactionJws,
            transactionId: evidence.transactionId,
            originalTransactionId: evidence.originalTransactionId,
            productId: evidence.productId,
            distinctId: distinctId,
            recordedAt: existing?.recordedAt ?? Date(),
            localEntitlementGrants: retainedGrants,
            isRevoked: false,
            finishRequired: existing?.finishRequired == true || finishRequired
        )
        guard persistEvidence(stored) else { return false }
        guard persistLocalAccess(stored) else { return false }
        if identityService.getDistinctId() == distinctId {
            await applyLocalAccess(stored)
        }
        return true
    }

    func markTransactionFinished(transactionId: String) async {
        guard var stored = storedEvidence()[transactionId] else { return }
        stored = StoredTransactionEvidence(
            transactionJws: stored.transactionJws,
            transactionId: stored.transactionId,
            originalTransactionId: stored.originalTransactionId,
            productId: stored.productId,
            distinctId: stored.distinctId,
            recordedAt: stored.recordedAt,
            localEntitlementGrants: stored.localEntitlementGrants,
            isRevoked: stored.isRevoked,
            finishRequired: false
        )
        if syncedTransactionIds.contains(transactionId) {
            removeEvidence(transactionId: transactionId)
        } else {
            _ = persistEvidence(stored)
        }
    }

    private func storedEvidence() -> [String: StoredTransactionEvidence] {
        if let evidenceByTransactionId { return evidenceByTransactionId }
        let loaded = evidenceStore.load()
        evidenceByTransactionId = loaded
        return loaded
    }

    private func persistEvidence(_ evidence: StoredTransactionEvidence) -> Bool {
        var entries = storedEvidence()
        entries[evidence.transactionId] = evidence
        guard evidenceStore.save(entries) else { return false }
        evidenceByTransactionId = entries
        return true
    }

    private func removeEvidence(transactionId: String) {
        var entries = storedEvidence()
        entries.removeValue(forKey: transactionId)
        evidenceByTransactionId = entries
        _ = evidenceStore.save(entries)
    }

    private func storedLocalAccess() -> [String: StoredLocalPurchaseAccess] {
        if let localAccessByTransactionId { return localAccessByTransactionId }
        let loaded = localAccessStore.load()
        localAccessByTransactionId = loaded
        return loaded
    }

    @discardableResult
    private func persistLocalAccess(_ evidence: StoredTransactionEvidence) -> Bool {
        guard !evidence.localEntitlementGrants.isEmpty else { return true }
        var entries = storedLocalAccess()
        entries[evidence.transactionId] = StoredLocalPurchaseAccess(
            transactionId: evidence.transactionId,
            originalTransactionId: evidence.originalTransactionId,
            productId: evidence.productId,
            distinctId: evidence.distinctId,
            grants: evidence.localEntitlementGrants
        )
        guard localAccessStore.save(entries) else { return false }
        localAccessByTransactionId = entries
        return true
    }

    private func removeLocalAccess(originalTransactionId: String) async {
        var entries = storedLocalAccess()
        let removed = entries.values.filter {
            $0.originalTransactionId == originalTransactionId
        }
        guard !removed.isEmpty else { return }
        for access in removed {
            entries.removeValue(forKey: access.transactionId)
            if access.distinctId == identityService.getDistinctId() {
                await featureService.removeLocalPurchase(
                    transactionId: access.transactionId
                )
            }
        }
        localAccessByTransactionId = entries
        _ = localAccessStore.save(entries)
    }

    private func rehydrateLocalAccessForCurrentCustomer() async {
        let distinctId = identityService.getDistinctId()
        for access in storedLocalAccess().values where access.distinctId == distinctId {
            await applyLocalAccess(access)
        }
    }

    private func reconcileLocalAccessWithCurrentEntitlements() async {
        let activeOriginalTransactionIDs = await activeStoreOriginalTransactionIDs()

        var entries = storedLocalAccess()
        let removed = entries.values.filter {
            !activeOriginalTransactionIDs.contains($0.originalTransactionId)
        }
        for access in removed {
            entries.removeValue(forKey: access.transactionId)
            if access.distinctId == identityService.getDistinctId() {
                await featureService.removeLocalPurchase(
                    transactionId: access.transactionId
                )
            }
        }
        if removed.isEmpty == false {
            localAccessByTransactionId = entries
            _ = localAccessStore.save(entries)
        }
        await rehydrateLocalAccessForCurrentCustomer()
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
            transactionId: evidence.transactionId
        )
    }

    private func applyLocalAccess(_ access: StoredLocalPurchaseAccess) async {
        let grants = access.grants.map {
            StoreProduct.LocalEntitlementGrant(
                featureId: $0.featureId,
                featureExternalId: $0.featureExternalId,
                allowanceType: $0.allowanceType,
                allowance: $0.allowance
            )
        }
        await featureService.applyLocalPurchase(
            grants: grants,
            transactionId: access.transactionId
        )
    }
}
