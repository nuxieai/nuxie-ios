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
    let answeredAt: Date?
    let finishRequired: Bool?
    let resolvesPendingPurchase: Bool
    let allowsDurableCheckoutAuthority: Bool
    let requiresAuthorityResolution: Bool
    /// Checkout recovery claims a transaction only for the checkout binding
    /// that started it; a transaction no checkout is waiting for is left.
    let requiresCheckoutBinding: Bool
    let isRevoked: Bool
    let isUpgraded: Bool
    /// Why the producer sends this receipt. Checkout says purchase, an
    /// explicit Restore says restore, and every passive producer says sync.
    let syncReason: PurchaseSyncReason
    /// Whether the attributed customer had signed in when the producer
    /// started, when it knows; otherwise the committer derives it.
    let customerKind: PurchaseCustomerKind?
    /// The admission of the outbox entry this commit sends again (the
    /// outbox pass). Once that entry was answered or admitted again, the
    /// commit leaves it to its own send rather than writing it back.
    let outboxAdmissionId: UUID?
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
        answeredAt: Date? = nil,
        finishRequired: Bool? = nil,
        resolvesPendingPurchase: Bool,
        allowsDurableCheckoutAuthority: Bool,
        requiresAuthorityResolution: Bool = true,
        requiresCheckoutBinding: Bool = false,
        isRevoked: Bool = false,
        isUpgraded: Bool = false,
        syncReason: PurchaseSyncReason = .sync,
        customerKind: PurchaseCustomerKind? = nil,
        outboxAdmissionId: UUID? = nil,
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
        self.answeredAt = answeredAt
        self.finishRequired = finishRequired
        self.resolvesPendingPurchase = resolvesPendingPurchase
        self.allowsDurableCheckoutAuthority = allowsDurableCheckoutAuthority
        self.requiresAuthorityResolution = requiresAuthorityResolution
        self.requiresCheckoutBinding = requiresCheckoutBinding
        self.isRevoked = isRevoked
        self.isUpgraded = isUpgraded
        self.syncReason = syncReason
        self.customerKind = customerKind
        self.outboxAdmissionId = outboxAdmissionId
        self.finish = finish
    }
}

extension IdentityServiceProtocol {
    /// Whether `distinctId` names a signed-in customer, read atomically with
    /// the current identity. The current customer's kind is always known, as
    /// is the device's anonymous id; any other customer's is not.
    func purchaseCustomerKind(of distinctId: String) -> PurchaseCustomerKind? {
        if let kind = performIfCurrentDistinctIdMatches(distinctId, { snapshot in
            snapshot.isIdentified
                ? PurchaseCustomerKind.identified
                : PurchaseCustomerKind.anonymous
        }) {
            return kind
        }
        return distinctId == getAnonymousId() ? .anonymous : nil
    }
}

/// What the server answered for one receipt sent for one customer.
enum PurchaseSyncOutcome: Equatable, Sendable {
    /// 2xx: the purchase is the customer's and the server granted its access.
    case accepted
    /// 409 or 400: the server will not attach the purchase to this customer.
    case refused
    /// No answer the SDK can act on (transport, 5xx, auth, local storage);
    /// retained evidence retries later.
    case failed
}

/// Why an explicit current-entitlement scan runs. A passive scan has none.
enum CurrentEntitlementSyncPurpose: Equatable, Sendable {
    /// The customer's Restore: every current entitlement is sent as a
    /// restore, so the server may move it to them.
    case restore
    /// The customer tried to buy a product StoreKit says they already own:
    /// that product is sent as a purchase; the others refresh as syncs.
    case purchase(storeProductId: String)

    func reason(forStoreProductId productId: String) -> PurchaseSyncReason {
        switch self {
        case .restore:
            return .restore
        case .purchase(let storeProductId):
            return storeProductId == productId ? .purchase : .sync
        }
    }
}

/// The server's answers for the entitlements an explicit scan claimed (sent
/// as a restore or purchase). Refreshes sent as syncs are not counted.
struct CurrentEntitlementSyncResult: Equatable, Sendable {
    /// The server granted the customer access.
    var granted = 0
    /// The server refused them for this customer.
    var refused = 0
    /// No usable answer yet.
    var failed = 0

    init(granted: Int = 0, refused: Int = 0, failed: Int = 0) {
        self.granted = granted
        self.refused = refused
        self.failed = failed
    }

    /// Nothing was eligible to claim.
    var isEmpty: Bool { granted + refused + failed == 0 }

    mutating func record(_ outcome: PurchaseSyncOutcome) {
        switch outcome {
        case .accepted: granted += 1
        case .refused: refused += 1
        case .failed: failed += 1
        }
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
    let outcomeEventId: String?

    init(
        operationId: String,
        distinctId: String,
        kind: Kind,
        outcomeEventId: String? = nil
    ) {
        self.operationId = operationId
        self.distinctId = distinctId
        self.kind = kind
        self.outcomeEventId = outcomeEventId
    }
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
    /// The result is another producer's commit of the purchase, made earlier
    /// or still running, not this call's own. Its send is not this
    /// producer's, so a Restore or purchase claim never counts its answer.
    let isReplay: Bool

    init(
        committed: Bool,
        syncTask: Task<Bool, Never>?,
        isTerminal: Bool? = nil,
        isReplay: Bool = false
    ) {
        self.committed = committed
        self.syncTask = syncTask
        self.isTerminal = isTerminal ?? committed
        self.isReplay = isReplay
    }

    func asReplay() -> Self {
        Self(committed: committed, syncTask: syncTask, isTerminal: isTerminal, isReplay: true)
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
    /// Sends the current App Store account's entitlements for `distinctId`
    /// and reports what the server answered for the ones `purpose` claims.
    func syncCurrentEntitlements(
        distinctId: String,
        purpose: CurrentEntitlementSyncPurpose
    ) async -> CurrentEntitlementSyncResult
    func retryStoredEvidence() async
    func retryAfterProfileReady() async
    /// Returns the current App Store account's verified, active product IDs.
    /// Enumeration completion is the readiness barrier for an offline Journey
    /// entitlement gate; no profile or backend response is required.
    func currentEntitledStoreProductIds() async -> Set<String>
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
    func currentEntitledStoreProductIds() async -> Set<String> { [] }
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
    private let syncTaskScheduled: @Sendable (String) -> Void
    /// Fetches the customer's profile again after the server answers one of
    /// their purchases.
    private let refreshProfile: @Sendable (String) async -> Void
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
        /// The customer the commit was made for. Only a producer for the same
        /// customer reuses it, so a session acceptance never crosses
        /// customers.
        let customer: String?
    }

    private struct PurchaseCommitRetryState: Sendable {
        var outcome: PurchaseOutcome
        var externalRetryRounds = 0
        var retryInProgress = false
    }

    /// The actor may re-enter while evidence or events are being persisted.
    /// Install the whole-commit operation before the first suspension so every
    /// producer of the same evidence joins one ordered interpretation.
    private var purchaseCommitOperations: [PurchaseCommitKey: PurchaseCommitOperation] = [:]
    private var completedPurchaseCommits: [PurchaseCommitKey: CompletedPurchaseCommit] = [:]
    /// A nonterminal stable-event/Journey capture retries the exact same
    /// committer identity. External callbacks are never invoked again and have
    /// a bounded in-process tail; verified retries retain their finish closure.
    private var retryablePurchaseCommits: [PurchaseCommitKey: PurchaseCommitRetryState] = [:]
    private var purchaseCommitRetryTask: Task<Void, Never>?
    /// Journey authority is process-local. Preserve it across a transient
    /// routed-capture failure, but never across observer teardown/relaunch.
    private var purchaseCommitJourneyRouting: Set<PurchaseCommitKey> = []

    /// Receipts the server accepted this session, keyed by transaction and
    /// the customer they were sent for (to avoid duplicates within session)
    private var syncedTransactionIds: Set<String> = []
    private struct TransactionSyncOperation: Sendable {
        let id: UUID
        /// Why this send was made; a sync's refusal does not answer a send
        /// that claims the purchase.
        let reason: PurchaseSyncReason
        /// The admission of the outbox entry this send carries, if any.
        let admissionId: UUID?
        let task: Task<PurchaseSyncOutcome, Never>
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
    /// The answer of each claiming send (restore or purchase) an explicit
    /// scan is waiting on, by sync key; read once by that scan.
    private var claimOutcomes: [String: PurchaseSyncOutcome] = [:]
    /// The one outbox timer, due at `outboxRetryDueAt`.
    private var outboxRetryTask: Task<Void, Never>?
    /// When the outbox timer fires: the earliest time a failed entry is due
    /// again, or now when one already is. Nil when no failed entry is waiting.
    private(set) var outboxRetryDueAt: Date?
    /// Whether the next recovery pass sends every unsent entry (launch,
    /// identify or reset, profile load) instead of only the ones that are due.
    private var everyEntryPassRequested = false
    /// One profile refresh per customer at a time after the server answers
    /// a purchase; answers that land meanwhile ask for one more.
    private var profileRefreshes: [String: Bool] = [:]
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
    private static let externalPurchaseCommitRetryLimit = 3

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
        recoverySources: StoreTransactionRecoverySources? = nil,
        syncTaskScheduled: @escaping @Sendable (String) -> Void = { _ in },
        refreshProfile: @escaping @Sendable (String) async -> Void = { _ in }
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
        self.syncTaskScheduled = syncTaskScheduled
        self.refreshProfile = refreshProfile
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
        outboxRetryTask?.cancel()
        outboxRetryTask = nil
        outboxRetryDueAt = nil
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
        retryablePurchaseCommits.removeAll()
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
    /// finishing, so this queue is the recovery source on relaunch. A pass of
    /// the outbox timer sends only the failed entries whose time has passed.
    private func processStoredEvidence(sendingEveryEntry: Bool) async {
        let now = dateProvider.now()
        for read in storedEvidence().values {
            guard !Task.isCancelled else { return }
            // An entry answered while this pass ran is not sent again.
            guard let evidence = storedEvidence()[read.transactionId] else { continue }
            if !sendingEveryEntry, evidence.isUnsent,
               let dueAt = evidence.retryDueAt, dueAt > now {
                continue
            }
            let result = await commit(.verified(
                VerifiedPurchaseEvidence(
                    transactionJws: evidence.transactionJws,
                    transactionId: evidence.transactionId,
                    originalTransactionId: evidence.originalTransactionId,
                    productId: evidence.productId,
                    appAccountToken: evidence.appAccountToken,
                    attributedDistinctId: evidence.distinctId,
                    recordedAt: evidence.recordedAt,
                    productFeatureIds: evidence.productFeatureIds,
                    commercialContext: evidence.commercialContext,
                    checkoutCompletionEventId: evidence.checkoutCompletionEventId,
                    completionDeliveredAt: evidence.completionDeliveredAt,
                    answeredAt: evidence.answeredAt,
                    finishRequired: evidence.finishRequired,
                    resolvesPendingPurchase: false,
                    allowsDurableCheckoutAuthority: false,
                    requiresAuthorityResolution: false,
                    isRevoked: evidence.isRevoked,
                    // A retry is the same send: it keeps the reason and the
                    // customer kind recorded when it was admitted.
                    syncReason: evidence.reason,
                    customerKind: evidence.customerKind,
                    outboxAdmissionId: evidence.admissionId
                ),
                source: .startupRecovery
            ))
            _ = await result.syncTask?.value
            guard !Task.isCancelled else { return }
            // A due entry this pass tried without getting an answer (a
            // purchase-backed Feature command holds it, say) counts a failed
            // attempt, so its time moves on and the timer does not fire on it
            // again at once.
            if let dueAt = evidence.retryDueAt, dueAt <= now,
               storedEvidence()[evidence.transactionId]?.retryDueAt == dueAt {
                await recordFailedSend(
                    transactionId: evidence.transactionId,
                    admissionId: evidence.admissionId
                )
            }
            if let retained = storedEvidence()[evidence.transactionId],
               retained.answeredAt != nil,
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
        everyEntryPassRequested = true
        await requestEvidenceRecoveryPass()
    }

    /// The outbox timer's pass: it sends the failed entries that are due.
    func retryDueOutboxEntries() async {
        guard !isStopped else { return }
        await requestEvidenceRecoveryPass()
    }

    private func requestEvidenceRecoveryPass() async {
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
            let sendsEveryEntry = everyEntryPassRequested
            everyEntryPassRequested = false
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
            await processStoredEvidence(sendingEveryEntry: sendsEveryEntry)
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
            rescheduleOutboxRetry()
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

    @discardableResult
    func handleVerifiedTransaction(
        _ transaction: VerifiedStoreTransactionUpdate,
        jwsRepresentation transactionJwt: String,
        source: PurchaseOutcomeSource,
        attributedDistinctId: String? = nil,
        syncReason: PurchaseSyncReason = .sync,
        resolvesPendingPurchase: Bool = true,
        allowsDurableCheckoutAuthority: Bool = true
    ) async -> PurchaseCommitResult {
        var resolvedSource = source
        if source == .transactionStream,
           resolvesPendingPurchase,
           case .unique = await transactionServiceProvider()
            .pendingPurchaseOwnership(productId: transaction.productId) {
            resolvedSource = .deferredUpdate
        }
        return await commit(.verified(
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
                syncReason: syncReason,
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

        let customer = commitCustomer(for: outcome)
        while true {
            if let completed = completedPurchaseCommits[key],
               completed.customer == customer {
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
                        return completed.result.asReplay()
                    }
                    completedPurchaseCommits.removeValue(forKey: key)
                    // A duplicate checkout-recovery producer reports the
                    // recovery; it never resubmits a failed receipt itself.
                    // The invalidated completion leaves the retry to the
                    // stored-evidence pump's next pass.
                    if case .verified(let evidence, _) = outcome,
                       evidence.requiresCheckoutBinding {
                        return completed.result.asReplay()
                    }
                    continue
                }
                return completed.result.asReplay()
            }
            guard !isStopped else { return .rejected }
            if let operation = purchaseCommitOperations[key] {
                return await operation.task.value.asReplay()
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
                    result: result,
                    customer: customer
                )
                retryablePurchaseCommits.removeValue(forKey: key)
                purchaseCommitJourneyRouting.remove(key)
            } else if shouldRetainPurchaseCommitRetry(outcome, key: key) {
                var retry = retryablePurchaseCommits[key]
                    ?? PurchaseCommitRetryState(outcome: outcome)
                retry.outcome = preferredPurchaseCommitRetry(
                    existing: retry.outcome,
                    candidate: outcome
                )
                retryablePurchaseCommits[key] = retry
                if shouldSchedulePurchaseCommitRetry(retry.outcome, key: key) {
                    schedulePurchaseCommitRetry()
                }
            } else {
                retryablePurchaseCommits.removeValue(forKey: key)
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
            guard retryablePurchaseCommits.contains(where: {
                shouldSchedulePurchaseCommitRetry($0.value.outcome, key: $0.key)
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
        let pendingKeys = Array(retryablePurchaseCommits.keys)
        for key in pendingKeys {
            guard !isStopped, !Task.isCancelled else { return }
            guard var retry = retryablePurchaseCommits[key],
                  !retry.retryInProgress else { continue }
            if immediateOnly,
               !shouldSchedulePurchaseCommitRetry(retry.outcome, key: key) {
                continue
            }

            if case .external = key {
                guard retry.externalRetryRounds
                    < Self.externalPurchaseCommitRetryLimit else {
                    abandonExternalPurchaseCommitRetry(for: key)
                    continue
                }
                retry.externalRetryRounds += 1
            }
            retry.retryInProgress = true
            retryablePurchaseCommits[key] = retry

            let result = await commit(retry.outcome)
            guard !result.isTerminal,
                  var retained = retryablePurchaseCommits[key] else { continue }
            retained.retryInProgress = false
            if case .external = key,
               retained.externalRetryRounds >= Self.externalPurchaseCommitRetryLimit {
                abandonExternalPurchaseCommitRetry(for: key)
            } else if shouldRetainPurchaseCommitRetry(retained.outcome, key: key) {
                retryablePurchaseCommits[key] = retained
            } else {
                retryablePurchaseCommits.removeValue(forKey: key)
                purchaseCommitJourneyRouting.remove(key)
            }
        }
    }

    private func abandonExternalPurchaseCommitRetry(for key: PurchaseCommitKey) {
        guard case .external = key,
              retryablePurchaseCommits.removeValue(forKey: key) != nil else { return }
        LogWarning(
            "TransactionObserver: External declaration event was lost after bounded in-process retries"
        )
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

    /// The customer a producer commits for, as far as it says: the one it
    /// names, else the current customer.
    private func commitCustomer(for outcome: PurchaseOutcome) -> String? {
        switch outcome {
        case .verified(let evidence, _):
            return evidence.attributedDistinctId ?? identityService.getDistinctId()
        case .external(let declaration, _):
            return declaration.distinctId
        case .cancelled, .pending, .failed:
            return nil
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
        let eventId = declaration.outcomeEventId
            ?? (["purchase-outcome", source.rawValue]
                + purchaseStorageScope.storageComponents
                + [declaration.operationId]).joined(separator: ":")
        let routeToJourneys = declaration.distinctId
            == identityService.getDistinctId()
        var captured = false
        // A false result can mean that the stable event is already durable but
        // local Journey routing was temporarily unavailable. Retry the exact
        // operation once immediately; later recovery hooks use the same
        // operation ID for the bounded in-process retry tail.
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
                captured = await eventSink.captureStableSystemEvent(.init(
                    name: SystemEventNames.restoreCompleted,
                    properties: [
                        "source": source.rawValue,
                        "test_store": testStore,
                    ],
                    eventId: eventId,
                    distinctId: declaration.distinctId
                ),
                    routeToJourneys: routeToJourneys,
                    ensureDurableCarrier: true
                )
            }
        }
        // The host has already completed the commercial operation. A local
        // EventLog/Journey routing failure must never turn that declaration
        // into a repurchase-safe failure. Keep the operation nonterminal for a
        // bounded set of exact same-operation retries.
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
        if let admissionId = verified.outboxAdmissionId,
           storedEvidence()[verified.transactionId]?.admissionId != admissionId {
            // The entry the outbox pass read was answered or admitted again
            // since; it is not this pass's to send.
            return PurchaseCommitResult(committed: false, syncTask: nil, isTerminal: false)
        }
        var existing = storedEvidence()[verified.transactionId]
        if verified.isRevoked, let current = existing, !current.isRevoked {
            // A refund stops the entry unlocking at once, before checks that
            // may defer the rest of processing, and its signed revocation is
            // what the entry sends next.
            _ = reloadAndApplyEvidenceChange(transactionId: verified.transactionId) {
                $0.map { Self.revoking($0, with: verified.transactionJws) }
            }
            await refreshOptimisticProjection()
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
        guard !verified.transactionJws.isEmpty || existing?.answeredAt != nil else {
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

        // The phone never works out who owns a purchase; the server says.
        // A checkout binding only matches a StoreKit delivery to the checkout
        // that started it, so its customer is the one the purchase is sent
        // for.
        let boundRequester = checkoutRecovery?.distinctId ?? pendingRecord?.distinctId
        if verified.requiresCheckoutBinding, existing == nil, boundRequester == nil {
            LogDebug(
                "TransactionObserver: Leaving a transaction no checkout is waiting for"
            )
            // A binding may still arrive from a checkout on another path; do
            // not cache the decision.
            return PurchaseCommitResult(
                committed: false,
                syncTask: nil,
                isTerminal: false
            )
        }

        // An explicit producer names its customer; a delivery bound to a
        // checkout goes to that checkout's customer; any other StoreKit
        // delivery is sent for the current customer.
        let newRecordOwner = verified.requiresCheckoutBinding
            ? boundRequester ?? activeDistinctId
            : verified.attributedDistinctId
                ?? boundRequester
                ?? activeDistinctId
        let routeCompletionToJourneys: Bool
        // StoreKit can deliver a checkout's transaction through its update
        // stream before the checkout callback commits it. A delivery that
        // belongs to a checkout still running in this process is that
        // checkout's purchase, whichever producer commits it first.
        let deliversLiveCheckout: Bool
        if purchaseCommitJourneyRouting.contains(commitKey) {
            routeCompletionToJourneys = true
            deliversLiveCheckout = false
        } else if pendingRecord?.state == .pending {
            // A deferred purchase explicitly survives the original checkout;
            // its pending marker is the authority to resume the Journey.
            routeCompletionToJourneys = true
            deliversLiveCheckout = false
        } else if let transactionService {
            deliversLiveCheckout = await transactionService.isActiveCheckout(
                appAccountToken: verified.appAccountToken,
                productId: verified.productId,
                distinctId: existing?.distinctId ?? newRecordOwner
            )
            routeCompletionToJourneys = deliversLiveCheckout
        } else {
            // Stored evidence on a later process launch preserves analytics
            // and server delivery without resurrecting the ended paywall.
            routeCompletionToJourneys = false
            deliversLiveCheckout = false
        }
        let makeCommittedEvidence = {
            [self] (existing: StoredTransactionEvidence?) -> StoredTransactionEvidence in
            let owner = existing?.distinctId ?? newRecordOwner
            let incomingReason = deliversLiveCheckout
                ? PurchaseSyncReason.purchase.strongest(verified.syncReason)
                : verified.syncReason
            // A refund the entry has not sent yet is a new send, as a sync.
            let sendsRevocation = verified.isRevoked && existing?.isRevoked != true
            let reason: PurchaseSyncReason
            if sendsRevocation {
                reason = .sync
            } else if let existing {
                // An unsent entry takes a later purchase or Restore's reason;
                // an answered one is claimed again only by a direct send, so
                // it keeps what it has.
                reason = existing.answeredAt == nil && incomingReason.claimsOwnership
                    ? incomingReason.strongest(existing.reason)
                    : existing.reason
            } else {
                reason = incomingReason
            }
            // Once durable state records that finishing completed (or that the
            // host owns it in observer mode), a retrying producer must not
            // reassert its original requirement and finish twice.
            let shouldFinish = existing?.finishRequired
                ?? verified.finishRequired
                ?? policy.finishAfterRecording
            let transactionJws: String
            if sendsRevocation, !verified.transactionJws.isEmpty {
                transactionJws = verified.transactionJws
            } else if existing?.answeredAt != nil {
                // Backend acknowledgement owns the cleared receipt even if a
                // producer still carries its original signed payload.
                transactionJws = existing!.transactionJws
            } else if purchaseCommitJourneyRouting.contains(commitKey),
                      let existing {
                // A routed-capture retry rebuilds from the current durable row.
                transactionJws = existing.transactionJws
            } else if existing?.isRevoked == true && !verified.isRevoked {
                transactionJws = existing!.transactionJws
            } else if verified.transactionJws.isEmpty {
                transactionJws = existing?.transactionJws ?? ""
            } else {
                transactionJws = verified.transactionJws
            }
            return StoredTransactionEvidence(
                scope: existing?.scope ?? pendingRecord?.scope ?? purchaseStorageScope,
                // A revoked row's signed payload is authoritative: an active
                // producer arriving after revocation must not rewrite it.
                transactionJws: transactionJws,
                transactionId: verified.transactionId,
                originalTransactionId: verified.originalTransactionId,
                productId: verified.productId,
                distinctId: owner,
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
                answeredAt: sendsRevocation
                    ? nil
                    : existing?.answeredAt ?? verified.answeredAt,
                // A durable entry keeps the facts it was admitted with.
                appAccountToken: existing == nil
                    ? verified.appAccountToken
                    : existing?.appAccountToken,
                reason: reason,
                // Recorded once, at admission; a retry never works it out
                // again. Unknown reads as identified: the server merges only
                // owners declared anonymous.
                customerKind: existing?.customerKind
                    ?? verified.customerKind
                    ?? identityService.purchaseCustomerKind(of: owner)
                    ?? .identified,
                sendAttempts: sendsRevocation ? 0 : existing?.sendAttempts ?? 0,
                retryDueAt: sendsRevocation ? nil : existing?.retryDueAt
            )
        }
        if routeCompletionToJourneys {
            purchaseCommitJourneyRouting.insert(commitKey)
        }
        // A replay whose row is already durable exactly as computed must not
        // die on a failing store write: completion capture comes first (the
        // claim is persisted only after the event is durably captured), and
        // the unchanged row carries everything the capture needs.
        guard let initialChange = reloadAndApplyEvidenceChange(
            transactionId: verified.transactionId,
            makeCommittedEvidence
        ) else { return .rejected }
        var committedEvidence = initialChange.evidence
        var evidenceChanged = initialChange.changed

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
            guard let finishChange = reloadAndApplyEvidenceChange(
                transactionId: verified.transactionId,
                { current in
                    guard let current else { return nil }
                    return replacingCommitState(
                        current,
                        finishRequired: false
                    )
                }
            ) else { return .rejected }
            committedEvidence = finishChange.evidence
            evidenceChanged = evidenceChanged || finishChange.changed
        }

        // Actor reentrancy in pending-record retirement or StoreKit finishing
        // can admit a revocation commit under its separate key. Completion is
        // always interpreted from the current canonical row.
        if let currentEvidence = storedEvidence()[verified.transactionId] {
            committedEvidence = currentEvidence
        }

        var completionAccepted = committedEvidence.commercialContext == nil
            || committedEvidence.isRevoked
            || committedEvidence.completionDeliveredAt != nil
        if !committedEvidence.isRevoked,
           committedEvidence.completionDeliveredAt == nil,
           committedEvidence.distinctId == identityService.getDistinctId(),
           let context = committedEvidence.commercialContext {
            // A revocation may land while capture is suspended. This emission
            // race is accepted: the admitted completion may still emit, as in
            // the historical refund window, and the server reconciles it.
            // Durable evidence and sync eligibility reload after this await.
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
                let deliveredAt = dateProvider.now()
                if let completionChange = reloadAndApplyEvidenceChange(
                    transactionId: verified.transactionId,
                    { current in
                        guard let current else { return nil }
                        return replacingCommitState(
                            current,
                            completionDeliveredAt: deliveredAt
                        )
                    }
                ) {
                    committedEvidence = completionChange.evidence
                    completionAccepted = committedEvidence.commercialContext == nil
                        || committedEvidence.isRevoked
                        || committedEvidence.completionDeliveredAt != nil
                    evidenceChanged = evidenceChanged || completionChange.changed
                } else {
                    completionAccepted = false
                }
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
        let currentEvidence = reloadAndApplyEvidenceChange(
            transactionId: verified.transactionId,
            { $0 }
        )?.evidence
        let syncTask: Task<Bool, Never>?
        if verified.requiresCheckoutBinding && !evidenceChanged {
            syncTask = nil
        } else if currentEvidence?.answeredAt != nil {
            syncTask = nil
        } else if currentEvidence?.isRevoked == true && !verified.isRevoked {
            // A revocation announced while this active producer was suspended
            // may coerce its persist before the revocation JWS itself lands.
            // The revoked producer exclusively owns that sync; never submit
            // the active producer's receipt under revoked semantics.
            syncTask = nil
        } else if let currentEvidence {
            syncTask = scheduleSync(for: currentEvidence)
        } else {
            syncTask = nil
        }
        return PurchaseCommitResult(
            committed: true,
            syncTask: syncTask,
            isTerminal: commitComplete
        )
    }

    private func scheduleSync(
        for evidence: StoredTransactionEvidence
    ) -> Task<Bool, Never>? {
        guard evidence.isUnsent else { return nil }
        syncTaskScheduled(evidence.transactionId)
        return Task { [weak self] in
            guard let self else { return false }
            return await self.syncTransactionWithOptions(
                transactionJws: evidence.transactionJws,
                transactionId: evidence.transactionId,
                productId: evidence.productId,
                originalTransactionId: evidence.originalTransactionId,
                distinctId: evidence.distinctId,
                reason: evidence.reason,
                customerKind: evidence.customerKind,
                admissionId: evidence.admissionId,
                updateLocalFeatures: evidence.distinctId
                    == self.identityService.getDistinctId(),
                isRevoked: evidence.isRevoked
            ) == .accepted
        }
    }

    private func capturePurchaseCompletion(
        properties: sending [String: Any],
        eventId: String,
        distinctId: String,
        routeToJourneys: Bool,
        ensureDurableCarrier: Bool = false
    ) async -> Bool {
        await eventSink.captureStableSystemEvent(.init(
            name: SystemEventNames.purchaseCompleted,
            properties: properties,
            eventId: eventId,
            distinctId: distinctId
        ),
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
            answeredAt: evidence.answeredAt,
            appAccountToken: evidence.appAccountToken,
            reason: evidence.reason,
            customerKind: evidence.customerKind,
            sendAttempts: evidence.sendAttempts,
            retryDueAt: evidence.retryDueAt,
            admissionId: evidence.admissionId
        )
    }

    /// The entry after StoreKit reports its purchase refunded: it no longer
    /// unlocks, and the signed revocation is its next send, as a sync.
    private static func revoking(
        _ evidence: StoredTransactionEvidence,
        with revokedJws: String
    ) -> StoredTransactionEvidence {
        StoredTransactionEvidence(
            scope: evidence.scope,
            transactionJws: revokedJws.isEmpty ? evidence.transactionJws : revokedJws,
            transactionId: evidence.transactionId,
            originalTransactionId: evidence.originalTransactionId,
            productId: evidence.productId,
            distinctId: evidence.distinctId,
            recordedAt: evidence.recordedAt,
            productFeatureIds: evidence.productFeatureIds,
            isRevoked: true,
            finishRequired: evidence.finishRequired,
            commercialContext: evidence.commercialContext,
            checkoutCompletionEventId: evidence.checkoutCompletionEventId,
            completionDeliveredAt: evidence.completionDeliveredAt,
            answeredAt: revokedJws.isEmpty ? evidence.answeredAt : nil,
            appAccountToken: evidence.appAccountToken,
            reason: .sync,
            customerKind: evidence.customerKind,
            sendAttempts: 0
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
                answeredAt: evidence.answeredAt,
                finishRequired: true,
                resolvesPendingPurchase: true,
                allowsDurableCheckoutAuthority: true,
                requiresAuthorityResolution: false,
                isRevoked: evidence.isRevoked,
                syncReason: evidence.reason,
                customerKind: evidence.customerKind,
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
        ) == .accepted
    }

    /// One receipt's in-process sync identity. It names the customer the
    /// receipt is sent for: the server's answer for one customer says
    /// nothing about another.
    private func syncKey(
        transactionId: String,
        originalTransactionId: String? = nil,
        transactionJws: String = "",
        distinctId: String,
        isRevoked: Bool = false
    ) -> String {
        // Each renewal is a distinct verified transaction. Deduping by the
        // original subscription ID would silently drop later renewals.
        let preferredId = transactionId.isEmpty
            ? (originalTransactionId?.isEmpty == false ? originalTransactionId : nil)
            : transactionId
        let base = (preferredId ?? transactionJws) + "\u{1f}" + distinctId
        // StoreKit reports revocation for the original transaction identity.
        // It is a new state transition and must not be swallowed by the
        // successful-purchase dedupe entry for that same transaction.
        return isRevoked ? "\(base):revoked" : base
    }

    private func syncTransactionWithOptions(
        transactionJws: String,
        transactionId: String,
        productId: String?,
        originalTransactionId: String?,
        distinctId requestedDistinctId: String? = nil,
        reason: PurchaseSyncReason = .sync,
        customerKind recordedCustomerKind: PurchaseCustomerKind? = nil,
        admissionId requestedAdmissionId: UUID? = nil,
        updateLocalFeatures: Bool = true,
        isRevoked: Bool = false,
        retainEvidenceAfterSync: Bool = false,
        refreshProviderState: Bool = false
    ) async -> PurchaseSyncOutcome {
        guard !isStopped else { return .failed }
        let requestLifecycleGeneration = lifecycleGeneration
        let durableEvidence = storedEvidence()[transactionId]
        guard !evidenceStoreUnreadable else { return .failed }
        // A receipt goes to the customer its entry was admitted for unless an
        // explicit Restore or purchase sends it for its own customer.
        let distinctId = requestedDistinctId
            ?? durableEvidence?.distinctId
            ?? identityService.getDistinctId()
        // The send carries the admission it was made for: the outbox entry's
        // that asked for it, else the requester's entry as it stands now.
        let admissionId = requestedAdmissionId
            ?? (durableEvidence?.distinctId == distinctId
                ? durableEvidence?.admissionId
                : nil)
        // A purchase-backed Feature command holding this purchase sends it
        // itself. This send counts a failed attempt, so the outbox timer
        // sends the entry again if the command's answer does not settle it.
        guard !purchaseUsageClaims.contains(transactionId) else {
            await recordFailedSend(transactionId: transactionId, admissionId: admissionId)
            return .failed
        }
        let dedupeKey = syncKey(
            transactionId: transactionId,
            originalTransactionId: originalTransactionId,
            transactionJws: transactionJws,
            distinctId: distinctId,
            isRevoked: isRevoked
        )

        if syncedTransactionIds.contains(dedupeKey), !refreshProviderState {
            LogDebug("TransactionObserver: Transaction already synced, finishing fast path")
            return await reconcileEvidenceAfterDeduplicatedSync(
                transactionId: transactionId,
                admissionId: admissionId,
                retainEvidenceAfterSync: retainEvidenceAfterSync
            ) ? .accepted : .failed
        }

        var joinedOperationId: UUID?
        while let operation = transactionSyncOperations[dedupeKey],
              operation.id != joinedOperationId {
            joinedOperationId = operation.id
            let outcome = await operation.task.value
            guard !isStopped,
                  lifecycleGeneration == requestLifecycleGeneration else {
                return .failed
            }
            // A Restore claim counts only its own send: one of the same
            // admission. Otherwise an acceptance for this customer answers any
            // send of the purchase; a refusal or failure answers only a send
            // of the same admission, and never a refresh or a send that
            // claims the purchase when the earlier send did not.
            let answersThisSend = reason == .restore
                ? operation.admissionId == admissionId
                : outcome == .accepted
                    || (operation.admissionId == admissionId
                        && !refreshProviderState
                        && (operation.reason.claimsOwnership || !reason.claimsOwnership))
            guard answersThisSend else { continue }
            guard outcome == .accepted else { return outcome }
            return await reconcileEvidenceAfterDeduplicatedSync(
                transactionId: transactionId,
                admissionId: admissionId,
                retainEvidenceAfterSync: retainEvidenceAfterSync
            ) ? .accepted : .failed
        }

        // An entry sends the kind recorded when it was admitted; a send
        // admitted now reads it with the identity it names. Unknown kind is
        // "identified": the server merges only owners declared anonymous, so
        // such a customer can be moved but never merged away.
        let customerKind = recordedCustomerKind
            ?? (durableEvidence?.distinctId == distinctId
                ? durableEvidence?.customerKind
                : nil)
            ?? identityService.purchaseCustomerKind(of: distinctId)
            ?? .identified
        let request = PurchaseRequest(
            transactionJwt: transactionJws,
            distinctId: distinctId,
            reason: reason,
            customerKind: customerKind
        )
        let operationId = UUID()
        let task = Task { [weak self] in
            guard let self else { return PurchaseSyncOutcome.failed }
            return await self.submitTransactionWithOptions(
                request,
                transactionId: transactionId,
                productId: productId,
                originalTransactionId: originalTransactionId,
                dedupeKey: dedupeKey,
                admissionId: admissionId,
                lifecycleGeneration: requestLifecycleGeneration,
                updateLocalFeatures: updateLocalFeatures,
                retainEvidenceAfterSync: retainEvidenceAfterSync,
                emitSyncedEvent: !refreshProviderState
            )
        }
        transactionSyncOperations[dedupeKey] = TransactionSyncOperation(
            id: operationId,
            reason: reason,
            admissionId: admissionId,
            task: task
        )
        let outcome = await task.value
        if transactionSyncOperations[dedupeKey]?.id == operationId {
            transactionSyncOperations.removeValue(forKey: dedupeKey)
        }
        if reason.claimsOwnership {
            claimOutcomes[dedupeKey] = outcome
        }
        return outcome
    }

    private func reconcileEvidenceAfterDeduplicatedSync(
        transactionId: String,
        admissionId: UUID?,
        retainEvidenceAfterSync: Bool
    ) async -> Bool {
        // An entry admitted since this send (or another customer's entry) is
        // answered only by its own send.
        if let stored = storedEvidence()[transactionId],
           stored.admissionId != admissionId {
            return true
        }
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
                answeredAt: dateProvider.now()
            ))
        }
        if !retainEvidenceAfterSync,
           storedEvidence()[transactionId]?.finishRequired != true {
            return await removeEvidence(transactionId: transactionId)
        }
        return true
    }

    /// The server will not attach this purchase to the customer it was sent
    /// for: it belongs to someone else (409), or it is not a purchase this
    /// customer can hold (400).
    private static func refusesPurchase(_ error: NuxieNetworkError) -> Bool {
        error.httpStatusCode == 409 || error.httpStatusCode == 400
    }

    private func submitTransactionWithOptions(
        _ request: PurchaseRequest,
        transactionId: String,
        productId: String?,
        originalTransactionId: String?,
        dedupeKey: String,
        admissionId: UUID?,
        lifecycleGeneration requestLifecycleGeneration: UInt64,
        updateLocalFeatures: Bool,
        retainEvidenceAfterSync: Bool,
        emitSyncedEvent: Bool
    ) async -> PurchaseSyncOutcome {
        let distinctId = request.distinctId
        // Whatever the answer, the outbox timer follows the entries it left.
        defer { rescheduleOutboxRetry() }
        let response: PurchaseResponse
        do {
            response = try await api.syncTransaction(request)
        } catch let error as NuxieNetworkError where Self.refusesPurchase(error) {
            LogWarning(
                "TransactionObserver: Server refused transaction \(transactionId) for this customer: \(error)"
            )
            guard !isStopped,
                  lifecycleGeneration == requestLifecycleGeneration else {
                return .refused
            }
            // A refusal answers the send like an acceptance: the entry is done.
            // Access is whatever the profile the server sends next says.
            guard await retireAnsweredEntry(
                transactionId: transactionId,
                admissionId: admissionId,
                retainEvidenceAfterSync: retainEvidenceAfterSync
            ) else { return .failed }
            await refreshProfileAfterAnswer(for: distinctId)
            return .refused
        } catch {
            LogError("TransactionObserver: Failed to sync transaction \(transactionId): \(error)")
            await recordFailedSend(transactionId: transactionId, admissionId: admissionId)
            return .failed
        }

        guard response.success else {
            LogError(
                "TransactionObserver: Backend sync failed for transaction \(transactionId): \(response.error ?? "Unknown error")"
            )
            await recordFailedSend(transactionId: transactionId, admissionId: admissionId)
            return .failed
        }
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
            await recordFailedSend(transactionId: transactionId, admissionId: admissionId)
            return .failed
        }
        let acceptedEvidence = storedEvidence()[transactionId]
        guard !evidenceStoreUnreadable else { return .failed }
        guard !isStopped,
              lifecycleGeneration == requestLifecycleGeneration else {
            return .failed
        }
        // The 200's Features hold in memory only until the profile refresh
        // below lands; the profile is where access comes from.
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
            return .failed
        }
        syncedTransactionIds.insert(dedupeKey)
        guard await retireAnsweredEntry(
            transactionId: transactionId,
            admissionId: admissionId,
            retainEvidenceAfterSync: retainEvidenceAfterSync
        ) else { return .failed }

        if emitSyncedEvent, identityService.getDistinctId() == distinctId {
            var properties: [String: Any] = [
                "transaction_id": transactionId,
                "original_transaction_id": originalTransactionId ?? "",
                "product_id": productId ?? "",
                "customer_id": distinctId
            ]
            if let context = acceptedEvidence?.commercialContext {
                properties["experience_id"] = context.experienceId
                properties["experience_version_id"] =
                    context.release.identity.experienceVersionId
                properties["journey_id"] = context.journeyId
                properties["placement_id"] = context.placementId
            }
            eventSink.emit(
                SystemEventNames.purchaseSynced,
                properties: properties
            )
        }
        await refreshProfileAfterAnswer(for: distinctId)
        return .accepted
    }

    /// The server answered (accepted or refused) a send, so the entry whose
    /// admission it carried is done. It stays only while its StoreKit finish
    /// or completion delivery is outstanding. An entry admitted since the
    /// send, or another customer's entry, is left to its own send.
    private func retireAnsweredEntry(
        transactionId: String,
        admissionId: UUID?,
        retainEvidenceAfterSync: Bool
    ) async -> Bool {
        let stored = storedEvidence()[transactionId]
        if let stored, stored.admissionId != admissionId {
            return true
        }
        if let stored,
           retainEvidenceAfterSync
            || stored.finishRequired
            || (stored.commercialContext != nil
                && stored.completionDeliveredAt == nil) {
            return await persistEvidence(stored.replacing(
                answeredAt: dateProvider.now()
            ))
        }
        if !retainEvidenceAfterSync {
            return await removeEvidence(transactionId: transactionId)
        }
        return true
    }

    /// A send failed without an answer (transport, 5xx, auth): the entry
    /// stays and is due again after a backoff that grows with each failure.
    /// It is also sent at every launch, sign-in and profile load. Only the
    /// admission the send carried counts the failure.
    private func recordFailedSend(transactionId: String, admissionId: UUID?) async {
        guard !isStopped else { return }
        let failedAt = dateProvider.now()
        _ = reloadAndApplyEvidenceChange(transactionId: transactionId) { current in
            guard let current, current.admissionId == admissionId,
                  current.isUnsent else { return current }
            return current.replacingAfterFailedSend(at: failedAt)
        }
        rescheduleOutboxRetry()
    }

    /// The delay before the outbox is sent again after `attempts` failures.
    static func outboxRetryDelay(afterAttempts attempts: Int) -> TimeInterval {
        let exponent = Double(max(0, min(attempts, 16) - 1))
        return min(
            outboxRetryInitialDelay * pow(2, exponent),
            outboxRetryMaximumDelay
        )
    }

    static let outboxRetryInitialDelay: TimeInterval = 30
    static let outboxRetryMaximumDelay: TimeInterval = 3600

    /// Sets the one outbox timer for the earliest time a failed entry is due
    /// again, or for now when one already is (its time passed while the app
    /// was suspended), replacing a timer set for any other time; with no
    /// failed entry waiting it is cancelled. It runs after every send result
    /// and after every recovery pass, the first of which runs at launch.
    private func rescheduleOutboxRetry() {
        guard !isStopped else { return }
        let now = dateProvider.now()
        let dueAt = storedEvidence().values
            .filter(\.isUnsent)
            .compactMap(\.retryDueAt)
            .min()
            .map { max($0, now) }
        if outboxRetryTask != nil, outboxRetryDueAt == dueAt { return }
        outboxRetryTask?.cancel()
        outboxRetryTask = nil
        outboxRetryDueAt = dueAt
        guard let dueAt else { return }
        let delay = dueAt.timeIntervalSince(now)
        outboxRetryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            await self.finishOutboxRetryWait()
        }
    }

    /// Whether a timed outbox retry is waiting.
    var hasScheduledOutboxRetry: Bool { outboxRetryTask != nil }

    private func finishOutboxRetryWait() async {
        // A timer replaced while it woke leaves its successor alone.
        guard !Task.isCancelled else { return }
        outboxRetryTask = nil
        outboxRetryDueAt = nil
        guard !isStopped else { return }
        await retryDueOutboxEntries()
    }

    /// Every answer can change what the customer holds, so their profile is
    /// fetched again; the profile, not this answer, is their access.
    private func refreshProfileAfterAnswer(for distinctId: String) async {
        guard !isStopped, identityService.getDistinctId() == distinctId else { return }
        await refreshProfile(distinctId)
    }

    // MARK: - Manual Sync

    /// Sends the current App Store account's entitlements for `distinctId`
    /// after a Restore, or after a checkout found its product already owned,
    /// and waits for the server's answers.
    func syncCurrentEntitlements(
        distinctId: String,
        purpose: CurrentEntitlementSyncPurpose
    ) async -> CurrentEntitlementSyncResult {
        LogInfo("TransactionObserver: Syncing current entitlements")

        await refreshOptimisticProjection()
        let result = await processCurrentEntitlements(
            distinctId: distinctId,
            purpose: purpose
        )

        LogInfo("TransactionObserver: Finished syncing current entitlements")
        return result
    }

    /// Commits every current entitlement for `distinctId`. Without a purpose
    /// (launch and identity scans) each is sent as a sync in the background.
    /// With one, each entitlement the purpose claims is sent as a restore or
    /// purchase, even when it was synced before or another customer on this
    /// device recorded it, and the server's answers are returned.
    @discardableResult
    private func processCurrentEntitlements(
        distinctId: String,
        purpose: CurrentEntitlementSyncPurpose? = nil
    ) async -> CurrentEntitlementSyncResult {
        let items = await currentEntitlementRecoveryTransactions()
        return await withTaskGroup(of: PurchaseSyncOutcome?.self) { group in
            for item in items {
                let update = item.update
                let reason = purpose?.reason(forStoreProductId: update.productId)
                    ?? .sync
                let claimable = !update.isRevoked && !update.isUpgraded
                    && !item.jwsRepresentation.isEmpty
                if reason.claimsOwnership {
                    // A Restore or purchase claim writes the purchase's entry
                    // only after a purchase-backed Feature command holding it
                    // is done, so their answers never cross on the entry.
                    await waitForPurchaseUsage(transactionId: update.transactionId)
                }
                let retained = storedEvidence()[update.transactionId]
                if reason.claimsOwnership, let retained,
                   retained.distinctId != distinctId {
                    // Another customer's record of this purchase stays theirs.
                    // This Restore or purchase asks for it for its own
                    // customer, and the server decides whether it moves.
                    if claimable {
                        group.addTask {
                            PurchaseSyncOutcome?.some(await self.claimCurrentEntitlement(
                                item, distinctId: distinctId, reason: reason
                            ))
                        }
                    }
                    continue
                }
                let previouslySynced = syncedTransactionIds.contains(syncKey(
                    transactionId: update.transactionId,
                    distinctId: distinctId
                )) || retained?.answeredAt != nil
                let ownsRefresh: Bool
                if purpose != nil, !reason.claimsOwnership, previouslySynced {
                    ownsRefresh = currentEntitlementBelongsToCustomer(
                        update, distinctId: distinctId
                    )
                } else {
                    ownsRefresh = false
                }
                let result = await handleVerifiedTransaction(
                    update,
                    jwsRepresentation: item.jwsRepresentation,
                    source: .startupRecovery,
                    attributedDistinctId: distinctId,
                    syncReason: reason,
                    // A current-entitlement scan can race unfinished/updates for
                    // the same deferred native purchase. Let the committer attach
                    // and retire any exact pending marker so the scan cannot win
                    // with a context-free terminal commit that suppresses Journey
                    // advancement from the later producer.
                    resolvesPendingPurchase: true,
                    allowsDurableCheckoutAuthority: false
                )
                guard purpose != nil else { continue }
                if reason.claimsOwnership {
                    guard claimable else { continue }
                    guard result.committed else {
                        // StoreKit holds this purchase but Nuxie could not
                        // record it; the claim has no answer yet.
                        group.addTask { PurchaseSyncOutcome.failed }
                        continue
                    }
                    if !previouslySynced, !result.isReplay,
                       let syncTask = result.syncTask {
                        // This commit admitted the claim and is sending it for
                        // this customer with this reason; its answer is the
                        // claim's. Another producer's commit is never counted.
                        group.addTask {
                            guard await syncTask.value else {
                                return await self.claimAfterUnacceptedSync(
                                    item, distinctId: distinctId, reason: reason
                                )
                            }
                            return PurchaseSyncOutcome.accepted
                        }
                    } else {
                        // Nothing new to send for this record (it was synced
                        // or refused before): ask again with this reason.
                        group.addTask {
                            PurchaseSyncOutcome?.some(await self.claimCurrentEntitlement(
                                item, distinctId: distinctId, reason: reason
                            ))
                        }
                    }
                } else if result.committed, ownsRefresh,
                          identityService.getDistinctId() == distinctId,
                          claimable {
                    // Explicit Restore refreshes provider authority while the
                    // commit above retains the original purchase's delivery and
                    // ownership decisions.
                    group.addTask {
                        _ = await self.claimCurrentEntitlement(
                            item, distinctId: distinctId, reason: .sync
                        )
                        return nil
                    }
                } else if let syncTask = result.syncTask {
                    group.addTask {
                        _ = await syncTask.value
                        return nil
                    }
                }
            }
            var summary = CurrentEntitlementSyncResult()
            for await outcome in group {
                if let outcome { summary.record(outcome) }
            }
            return summary
        }
    }

    /// Sends one current entitlement for `distinctId` with `reason`, bypassing
    /// the in-process record of earlier syncs: an explicit Restore or purchase
    /// always asks the server.
    private func claimCurrentEntitlement(
        _ item: StoreTransactionRecoveryItem,
        distinctId: String,
        reason: PurchaseSyncReason
    ) async -> PurchaseSyncOutcome {
        // A purchase-backed Feature command holding this purchase answers
        // first; a Restore or purchase claim is admitted and sent after it.
        if reason.claimsOwnership {
            await waitForPurchaseUsage(transactionId: item.update.transactionId)
        }
        // A child can start after an identity change. Check the initiating owner
        // on this actor immediately before creating the sync operation.
        guard !isStopped, identityService.getDistinctId() == distinctId else { return .failed }
        // A Restore or purchase claim is queued like any other send before it
        // goes out, so a claim the server never answers is retried, also
        // after a relaunch.
        var customerKind: PurchaseCustomerKind?
        var admissionId: UUID?
        if reason.claimsOwnership {
            guard let admitted = await admitClaim(
                item, distinctId: distinctId, reason: reason
            ) else { return .failed }
            customerKind = admitted.customerKind
            admissionId = admitted.admissionId
        }
        let outcome = await syncTransactionWithOptions(
            transactionJws: item.jwsRepresentation,
            transactionId: item.update.transactionId,
            productId: item.update.productId,
            originalTransactionId: item.update.originalTransactionId,
            distinctId: distinctId,
            reason: reason,
            customerKind: customerKind,
            admissionId: admissionId,
            refreshProviderState: true
        )
        claimOutcomes.removeValue(forKey: syncKey(
            transactionId: item.update.transactionId,
            originalTransactionId: item.update.originalTransactionId,
            transactionJws: item.jwsRepresentation,
            distinctId: distinctId
        ))
        return outcome
    }

    /// Writes a claim into the outbox as the claiming customer's entry. Their
    /// earlier entry for the purchase keeps its bookkeeping and takes the
    /// claim as its next send. Another customer's entry gives way, since the
    /// claim is the newer intent for the purchase; a checkout completion that
    /// customer never delivered goes with it.
    private func admitClaim(
        _ item: StoreTransactionRecoveryItem,
        distinctId: String,
        reason: PurchaseSyncReason
    ) async -> StoredTransactionEvidence? {
        let update = item.update
        let customerKind = identityService.purchaseCustomerKind(of: distinctId) ?? .identified
        let admittedAt = dateProvider.now()
        let change = reloadAndApplyEvidenceChange(transactionId: update.transactionId) {
            [purchaseStorageScope] current in
            let own = current?.distinctId == distinctId ? current : nil
            if let current, own == nil,
               current.commercialContext != nil, current.completionDeliveredAt == nil {
                LogWarning(
                    "TransactionObserver: A Restore claim replaces another customer's entry with an undelivered completion"
                )
            }
            return StoredTransactionEvidence(
                scope: current?.scope ?? purchaseStorageScope,
                transactionJws: item.jwsRepresentation,
                transactionId: update.transactionId,
                originalTransactionId: update.originalTransactionId,
                productId: update.productId,
                distinctId: distinctId,
                recordedAt: own?.recordedAt ?? admittedAt,
                productFeatureIds: own?.productFeatureIds ?? [],
                isRevoked: update.isRevoked,
                finishRequired: current?.finishRequired ?? false,
                commercialContext: own?.commercialContext,
                checkoutCompletionEventId: own?.checkoutCompletionEventId,
                completionDeliveredAt: own?.completionDeliveredAt,
                answeredAt: nil,
                appAccountToken: update.appAccountToken,
                reason: reason,
                customerKind: customerKind,
                sendAttempts: 0
            )
        }
        guard let change else { return nil }
        // The claim is a new send: an earlier commit or acceptance of this
        // purchase in this session no longer answers it, so recovery commits
        // and sends it afresh.
        completedPurchaseCommits.removeValue(forKey: .verified(
            transactionId: update.transactionId,
            revoked: false
        ))
        syncedTransactionIds.remove(syncKey(
            transactionId: update.transactionId,
            originalTransactionId: update.originalTransactionId,
            transactionJws: item.jwsRepresentation,
            distinctId: distinctId
        ))
        if change.changed {
            await refreshOptimisticProjection()
        }
        return change.evidence
    }

    /// A scheduled sync reports only whether the server accepted it. When a
    /// claiming send (this restore or purchase) was answered, that answer is
    /// the claim's; when only an earlier sync was, this claim asks itself.
    private func claimAfterUnacceptedSync(
        _ item: StoreTransactionRecoveryItem,
        distinctId: String,
        reason: PurchaseSyncReason
    ) async -> PurchaseSyncOutcome {
        let key = syncKey(
            transactionId: item.update.transactionId,
            originalTransactionId: item.update.originalTransactionId,
            transactionJws: item.jwsRepresentation,
            distinctId: distinctId
        )
        if let outcome = claimOutcomes.removeValue(forKey: key) {
            return outcome
        }
        return await claimCurrentEntitlement(item, distinctId: distinctId, reason: reason)
    }

    func currentEntitledStoreProductIds() async -> Set<String> {
        let distinctId = identityService.getDistinctId()
        guard let identity = identityService.performWithCurrentIdentityFence(
            distinctId, { _ in () }
        ) else { return [] }
        let items = await currentEntitlementRecoveryTransactions()
        var products: Set<String> = []
        for item in items {
            let update = item.update
            guard !update.isRevoked && !update.isUpgraded else { continue }
            guard currentEntitlementBelongsToCustomer(
                update, distinctId: distinctId
            ) else { continue }
            products.insert(update.productId)
        }
        return identityService.performIfCurrentIdentityFenceToken(identity.token) {
            products
        } ?? []
    }

    /// Whether StoreKit's entitlement is the customer's own purchase: its
    /// account token is the one Nuxie derives for them. The phone never works
    /// out an owner beyond that; the server says who owns a purchase.
    private func currentEntitlementBelongsToCustomer(
        _ update: VerifiedStoreTransactionUpdate,
        distinctId: String
    ) -> Bool {
        update.appAccountToken == purchaseStorageScope.appAccountToken(distinctId: distinctId)
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
                syncReason: .purchase,
                customerKind: identityService.purchaseCustomerKind(of: distinctId),
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
                        && evidence.answeredAt == nil
                        && !evidence.transactionJws.isEmpty
                        && evidence.productFeatureIds.contains(featureId)
                })
            guard candidates.count == 1, let evidence = candidates.first else {
                return nil
            }

            let receiptSyncKey = syncKey(
                transactionId: evidence.transactionId,
                distinctId: evidence.distinctId
            )
            if let receiptSync = transactionSyncOperations[receiptSyncKey] {
                let synced = await receiptSync.task.value == .accepted
                if transactionSyncOperations[receiptSyncKey]?.id
                    == receiptSync.id {
                    transactionSyncOperations.removeValue(
                        forKey: receiptSyncKey
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
                    purchaseSyncedProperties["experience_version_id"] =
                        context.release.identity.experienceVersionId
                    purchaseSyncedProperties["journey_id"] = context.journeyId
                    purchaseSyncedProperties["placement_id"] = context.placementId
                }
                let purchaseSynced = await eventSink.capture(.init(
                    name: SystemEventNames.purchaseSynced,
                    properties: purchaseSyncedProperties,
                    eventId: purchaseSyncedEventId(evidence: evidence),
                    distinctId: distinctId
                ))
                guard purchaseSynced else {
                    releasePurchaseUsageClaim(transactionId: evidence.transactionId)
                    throw NuxieNetworkError.invalidResponse
                }

                // A decoded 2xx response means the purchase and usage command
                // committed, and the stable purchase event is now durably
                // captured. `allowed` is the post-use access state, so it is
                // false after consuming the final finite unit.
                // The answer settles the entry only while it still holds the
                // admission this command sent. An entry admitted since (a
                // refund, say) waits for its own send. The command's result
                // is the caller's either way: the server consumed the Feature.
                let acceptedAt = dateProvider.now()
                if let current = storedEvidence()[evidence.transactionId],
                   current.admissionId == evidence.admissionId {
                    guard await persistEvidence(current.replacing(
                        answeredAt: acceptedAt
                    )) else {
                        releasePurchaseUsageClaim(
                            transactionId: evidence.transactionId
                        )
                        throw NuxieNetworkError.invalidResponse
                    }
                    if !current.finishRequired
                        && (current.commercialContext == nil
                            || current.completionDeliveredAt != nil) {
                        _ = await removeEvidence(transactionId: evidence.transactionId)
                    }
                }
                syncedTransactionIds.insert(receiptSyncKey)
                releasePurchaseUsageClaim(transactionId: evidence.transactionId)

                guard !isStopped,
                      lifecycleGeneration == requestGeneration,
                      identityService.getDistinctId() == distinctId else {
                    throw CancellationError()
                }
                let check = response.featureCheckResult(
                    requiredBalance: amount
                )
                await featureService.invalidateAccess(featureId: featureId, entityId: entityId, distinctId: distinctId)
                if response.featureId != featureId {
                    await featureService.invalidateAccess(featureId: response.featureId, entityId: entityId, distinctId: distinctId)
                }
                if response.idempotentReplay != true {
                    await featureService.applyAuthoritativeUse(
                        check,
                        requestedFeatureId: featureId,
                        distinctId: distinctId,
                        entityId: entityId
                    )
                }
                let access = FeatureAccess(
                    authoritative: check,
                    requestedFeatureId: featureId
                )
                var result = FeatureUsageResult(
                    success: true,
                    featureId: featureId,
                    amountUsed: amount,
                    message: nil,
                    usage: nil,
                    authoritativeAccess: access
                )
                result.consumptionReceipt = response.consumptionReceipt
                return result
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

    /// Waits while a purchase-backed Feature command holds `transactionId`.
    private func waitForPurchaseUsage(transactionId: String) async {
        while !isStopped, purchaseUsageClaims.contains(transactionId) {
            await withCheckedContinuation { continuation in
                purchaseUsageWaiters[transactionId, default: []].append(continuation)
            }
        }
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
    /// and integration tests. Only a durable checkout binding names the
    /// customer a recovered transaction is sent for.
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
                requiresCheckoutBinding: true,
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
            $0.recordedAt <= cutoff && $0.answeredAt == nil
        }.count
        if expiredUnsyncedCount > 0 {
            LogWarning(
                "TransactionObserver: Retaining \(expiredUnsyncedCount, privacy: .publicValue) old unsynced receipts"
            )
        }
        // Answered entries are bounded by the retention horizon. Unsent
        // entries are bounded by the small number of purchases still waiting
        // for the server, retried on every launch, so they must not expire.
        let retained = loaded.filter {
            $0.value.answeredAt == nil || $0.value.recordedAt > cutoff
        }
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

    /// Reloads the actor-canonical row and applies one replacement without an
    /// actor suspension between the read and durable write. The verified
    /// committer expresses every post-await change as a transformation of this
    /// current row rather than persisting a pre-await snapshot.
    private func reloadAndApplyEvidenceChange(
        transactionId: String,
        _ change: (StoredTransactionEvidence?) -> StoredTransactionEvidence?
    ) -> (evidence: StoredTransactionEvidence, changed: Bool)? {
        var entries = storedEvidence()
        let current = entries[transactionId]
        // A write that changes what the entry sends is a new admission.
        guard !evidenceStoreUnreadable,
              let proposed = change(current)?.admitted(over: current),
              proposed.scope == purchaseStorageScope,
              proposed.transactionId == transactionId else { return nil }
        guard entries[transactionId] != proposed else {
            return (proposed, false)
        }
        entries[transactionId] = proposed
        guard evidenceStore.save(entries) else { return nil }
        evidenceByTransactionId = entries
        return (proposed, true)
    }

    private func persistEvidence(
        _ evidence: StoredTransactionEvidence,
        refreshProjection: Bool = true
    ) async -> Bool {
        guard reloadAndApplyEvidenceChange(
            transactionId: evidence.transactionId,
            { _ in evidence }
        ) != nil else { return false }
        if refreshProjection {
            await refreshOptimisticProjection()
        }
        return true
    }

    @discardableResult
    func removeEvidence(transactionId: String) async -> Bool {
        var entries = storedEvidence()
        guard !evidenceStoreUnreadable else { return false }
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
                backendSynced: stored.answeredAt != nil,
                revoked: stored.isRevoked
            )
        }
        // Access comes from the server profile. The one exception is the
        // customer's own unanswered purchase (its account token names them),
        // which unlocks until the server answers. A StoreKit transaction
        // bought outside Nuxie or by another customer waits for the server.
        let distinctId = identityService.getDistinctId()
        var allowances: [String: [OptimisticEntitlementAllowance]] = [:]
        for stored in entries.values where stored.unlocksEarly(for: distinctId) {
            if let resolved = await descriptorAllowanceProvider(stored) {
                allowances[stored.transactionId] = resolved
            }
        }
        guard refreshGeneration == projectionRefreshGeneration else { return }
        let evidenceInput = evidence.isEmpty ? nil : evidence
        let allowanceInput = allowances.isEmpty ? nil : allowances
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
}
