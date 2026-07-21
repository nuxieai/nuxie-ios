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
}

/// Observes StoreKit 2 Transaction.updates stream and syncs verified transactions with the backend
///
/// By observing Transaction.updates directly, we catch all purchases regardless of how they
/// were initiated (via SDK, app's own StoreKit code, or even the App Store directly).
internal actor TransactionObserver: TransactionObserverProtocol {

    // MARK: - Dependencies

    private let api: NuxieApiProtocol
    private let featureService: FeatureServiceProtocol
    private let identityService: IdentityServiceProtocol
    /// Providers, not values: a re-setup's fresh configuration must be
    /// honored, and TransactionService is constructed after the observer.
    private let configurationProvider: @Sendable () -> NuxieConfiguration
    private let transactionServiceProvider: @Sendable () -> TransactionService
    private var isObserverMode: Bool {
        configurationProvider().purchaseHandlingMode == .observer
    }

    // MARK: - Properties

    /// Task observing Transaction.updates
    private var updateTask: Task<Void, Never>?

    /// Set of transaction IDs we've already synced (to avoid duplicates within session)
    private var syncedTransactionIds: Set<String> = []

    // MARK: - Init

    init(
        api: NuxieApiProtocol,
        features: FeatureServiceProtocol,
        identity: IdentityServiceProtocol,
        configurationProvider: @escaping @Sendable () -> NuxieConfiguration,
        transactionServiceProvider: @escaping @Sendable () -> TransactionService
    ) {
        self.api = api
        self.featureService = features
        self.identityService = identity
        self.configurationProvider = configurationProvider
        self.transactionServiceProvider = transactionServiceProvider
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
                await transaction.finish()
                LogDebug("TransactionObserver: Transaction \(transaction.id) finished")
            }

            // Resolve an Ask-to-Buy/SCA purchase that the paywall is still
            // waiting on: the deferred transaction arrives via
            // Transaction.updates, not the original purchase() call.
            let resolvedPending = await transactionServiceProvider()
                .consumePendingPurchase(productId: transaction.productID)
            if resolvedPending {
                NuxieSDK.shared.trigger("$purchase_completed", properties: [
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
        let preferredId = (originalTransactionId?.isEmpty == false)
            ? originalTransactionId
            : (transactionId.isEmpty ? nil : transactionId)
        let dedupeKey = preferredId ?? transactionJws

        if syncedTransactionIds.contains(dedupeKey) {
            LogDebug("TransactionObserver: Transaction already synced, finishing fast path")
            return true
        }

        let distinctId = identityService.getDistinctId()

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

                NuxieSDK.shared.trigger("$purchase_synced", properties: [
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
}
