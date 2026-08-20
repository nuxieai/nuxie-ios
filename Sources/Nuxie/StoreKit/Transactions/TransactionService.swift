import Foundation
import StoreKit

func optimisticLocalEntitlementGrants(
    _ grants: [StoreProduct.LocalEntitlementGrant]
) -> [StoreProduct.LocalEntitlementGrant] {
    grants.filter {
        let allowanceType = $0.allowanceType?.lowercased()
        // Boolean ownership can be proven from the signed Product mapping.
        // Quotas and credits remain server-authoritative because a local
        // retry cannot safely determine their current balance.
        return allowanceType == nil
            || allowanceType == "boolean"
            || allowanceType == "unlimited"
    }
}

func storeProductFeatureIds(
    _ grants: [StoreProduct.LocalEntitlementGrant]
) -> [String] {
    Array(Set(grants.flatMap { grant in
        ([grant.featureId, grant.featureExternalId] + grant.purchaseUsageFeatureIds)
            .compactMap { featureId in
                guard let featureId, !featureId.isEmpty else { return nil }
                return featureId
            }
    })).sorted()
}

struct PurchaseSyncResult: Sendable {
    public let syncTask: Task<Bool, Never>?

    public init(syncTask: Task<Bool, Never>? = nil) {
        self.syncTask = syncTask
    }
}

enum PendingPurchaseOwnershipResolution: Sendable {
    case none
    case unique(PendingPurchaseRecord)
    case ambiguous
}

/// Service responsible for managing StoreKit transactions
actor TransactionService {
    private let productService: ProductService
    private let transactionObserver: TransactionObserverProtocol
    private let settings: PurchaseSettingsProviding
    private let eventSink: SystemEventSink
    private let nativePurchaseAdapter: any NativeStoreKitPurchasing
    private let introEligibilityTokenProvider: any IntroEligibilityTokenProviding
    private let introEligibilityOverrideHealth: IntroEligibilityOverrideHealth
    private let featureService: FeatureServiceProtocol?
    private let testStore: (any NuxieTestStorePurchasing)?
    private let purchaseStorageScope: PurchaseStorageScope
    private let accountOwnershipStore: PurchaseAccountOwnershipStoreProtocol
    private let activeProductEvidenceAuthority:
        @Sendable (String) async -> ActiveProductEvidenceAuthorityResolution

    /// Purchase delegate from configuration (injected, not reached through
    /// the NuxieSDK singleton)
    private var purchaseDelegate: NuxiePurchaseDelegate? {
        settings.purchaseDelegate()
    }

    private let pendingPurchaseStore: PendingPurchaseStoreProtocol
    private let dateProvider: DateProviderProtocol
    private let identityService: IdentityServiceProtocol?

    /// How long unresolved checkout recovery stays valid. This covers both the
    /// multi-day Ask-to-Buy/SCA approval window.
    static let pendingPurchaseTTL: TimeInterval = 30 * 24 * 3600

    /// A `.checkout` marker may be the only durable evidence that StoreKit
    /// returned `.pending` when the checkout -> pending write failed. Keep it
    /// for the full deferred-purchase window, but permit a same-context retry
    /// after this shorter abandonment window.
    static let checkoutRecoveryTTL: TimeInterval = 15 * 60

    /// An outcome-only delegate cannot prove whether `.purchased` came from
    /// StoreKit or another processor. Keep exact checkout correlation briefly
    /// so Transaction.updates can win either side of the callback race, then
    /// retire only the commercial marker. Durable SDK account-token ownership
    /// remains available for later receipt sync and finishing.
    static let outcomeOnlyStoreKitObservationTTL: TimeInterval = 30

    /// Exact pre-checkout contexts, including deferred purchases. Durable,
    /// loaded lazily, scope-checked, and pruned by TTL.
    private var cachedPendingPurchases: [String: PendingPurchaseRecord]?
    /// Process-local authority for Journey routing. Durable recovery markers
    /// restore commercial facts after relaunch, but only a checkout still
    /// executing in this process may advance the paywall's Journey.
    private var activeCheckoutKeys: Set<String> = []

    private func pendingKey(productId: String, distinctId: String) -> String {
        "\(distinctId)::\(productId)"
    }

    private func activeCheckoutKey(
        appAccountToken: UUID,
        productId: String
    ) -> String {
        "\(appAccountToken.uuidString.lowercased())::\(productId)"
    }

    func isActiveCheckout(
        appAccountToken: UUID?,
        productId: String,
        distinctId: String
    ) -> Bool {
        guard let appAccountToken,
              appAccountToken == purchaseStorageScope.appAccountToken(
                distinctId: distinctId
              ) else { return false }
        return activeCheckoutKeys.contains(activeCheckoutKey(
            appAccountToken: appAccountToken,
            productId: productId
        ))
    }

    private func pendingKey(productId: String) -> String {
        pendingKey(
            productId: productId,
            distinctId: identityService?.getDistinctId() ?? "anonymous"
        )
    }

    /// Called by TransactionObserver when a transaction lands for a product
    /// that had a pending (deferred) purchase. Returns true exactly once.
    func consumePendingPurchase(productId: String, distinctId: String? = nil) -> Bool {
        var entries = pendingPurchases()
        let key: String?
        if let distinctId {
            key = "\(distinctId)::\(productId)"
        } else {
            key = pendingEntry(productId: productId)?.key
        }
        guard let key, entries[key] != nil else {
            return false
        }
        entries.removeValue(forKey: key)
        return setPendingPurchases(entries)
    }

    /// Returns the local access mapping captured when a native purchase became
    /// pending. The marker is consumed only after the verified transaction has
    /// been durably recorded and synced.
    func pendingPurchaseGrants(productId: String) -> [StoredLocalEntitlementGrant]? {
        pendingPurchaseRecord(productId: productId)?.localEntitlementGrants
    }

    func pendingPurchaseGrants(
        productId: String,
        distinctId: String
    ) -> [StoredLocalEntitlementGrant]? {
        pendingPurchaseRecord(productId: productId, distinctId: distinctId)?.localEntitlementGrants
    }

    func pendingPurchaseDistinctId(productId: String) -> String? {
        pendingPurchaseRecord(productId: productId)?.distinctId
    }

    /// Resolve a deferred marker only for the active customer. A product ID is
    /// not customer identity, so an orphaned marker must never be attached to
    /// a later account after logout or identify.
    func pendingPurchaseRecord(productId: String) -> PendingPurchaseRecord? {
        let entries = pendingPurchases()
        guard let record = entries[pendingKey(productId: productId)],
              record.state == .pending else { return nil }
        return record
    }

    /// Returns the deferred marker only when it belongs to the requested
    /// customer. Transaction updates use this form after a customer switch so
    /// a pending purchase cannot resolve another customer's paywall.
    func pendingPurchaseRecord(
        productId: String,
        distinctId: String
    ) -> PendingPurchaseRecord? {
        guard let record = pendingPurchases()["\(distinctId)::\(productId)"],
              record.state == .pending else { return nil }
        return record
    }

    /// Resolve a StoreKit transaction to a deferred customer only when the
    /// durable marker set has one unambiguous owner for this store product.
    /// With multiple customers pending the same product, StoreKit's product ID
    /// alone is insufficient authority and synchronization must wait.
    func pendingPurchaseOwnership(
        productId: String
    ) -> PendingPurchaseOwnershipResolution {
        let suffix = "::\(productId)"
        let matches = pendingPurchases().filter {
            $0.key.hasSuffix(suffix) && $0.value.state == .pending
        }
        switch matches.count {
        case 0:
            return .none
        case 1:
            guard let record = matches.first?.value else { return .none }
            return .unique(record)
        default:
            return .ambiguous
        }
    }

    private func pendingEntry(productId: String) -> (key: String, record: PendingPurchaseRecord)? {
        let entries = pendingPurchases()
        let currentKey = pendingKey(productId: productId)
        if let record = entries[currentKey], record.state == .pending {
            return (currentKey, record)
        }
        // A product identifier is not customer identity. Never attach a
        // deferred purchase marker recorded for another customer merely
        // because both customers bought the same product.
        return nil
    }

    /// The current (TTL-pruned) marker set, loading from disk on first use.
    private func pendingPurchases() -> [String: PendingPurchaseRecord] {
        let loaded = cachedPendingPurchases ?? pendingPurchaseStore.load()
        let now = dateProvider.now()
        let pruned = loaded.filter {
            guard $0.value.scope == purchaseStorageScope else { return false }
            if $0.value.state == .checkout,
               let deadline = $0.value.storeKitObservationDeadline,
               deadline <= now {
                return false
            }
            let cutoff = dateProvider.date(
                byAddingTimeInterval: -Self.pendingPurchaseTTL,
                to: now
            )
            return $0.value.recordedAt > cutoff
        }
        if pruned.count != loaded.count {
            setPendingPurchases(pruned)
        } else {
            cachedPendingPurchases = pruned
        }
        return pruned
    }

    @discardableResult
    private func setPendingPurchases(_ entries: [String: PendingPurchaseRecord]) -> Bool {
        guard pendingPurchaseStore.save(entries) else { return false }
        cachedPendingPurchases = entries
        return true
    }

    func checkoutRecoveryRecord(
        appAccountToken: UUID?,
        productId: String
    ) -> PendingPurchaseRecord? {
        guard let appAccountToken else { return nil }
        return pendingPurchases().values.first {
            $0.scope == purchaseStorageScope
                && $0.appAccountToken == appAccountToken
                && $0.commercialContext.storeProductId == productId
        }
    }

    func purchaseAccountOwner(appAccountToken: UUID?) -> String? {
        guard let appAccountToken else { return nil }
        return accountOwnershipStore.owner(
            for: appAccountToken,
            scope: purchaseStorageScope
        )
    }

    func activePurchaseEvidenceAuthority(
        productId: String
    ) async -> ActiveProductEvidenceAuthorityResolution {
        await activeProductEvidenceAuthority(productId)
    }

    func durablePurchaseEvidenceAuthority(
        appAccountToken: UUID?,
        productId: String
    ) -> PurchaseEvidenceAuthority? {
        if let appAccountToken,
           let tokenAuthority = accountOwnershipStore.evidenceAuthority(
               for: appAccountToken,
               productId: productId,
               scope: purchaseStorageScope
           ) {
            return tokenAuthority
        }
        guard let activeDistinctId = identityService?.getDistinctId() else {
            return nil
        }
        return accountOwnershipStore.evidenceAuthority(
            for: purchaseStorageScope.appAccountToken(
                distinctId: activeDistinctId
            ),
            productId: productId,
            scope: purchaseStorageScope
        )
    }

    @discardableResult
    func consumeCheckoutRecovery(
        appAccountToken: UUID,
        productId: String
    ) -> PendingPurchaseRecord? {
        var entries = pendingPurchases()
        guard let match = entries.first(where: {
            $0.value.scope == purchaseStorageScope
                && $0.value.appAccountToken == appAccountToken
                && $0.value.commercialContext.storeProductId == productId
        }) else { return nil }
        entries.removeValue(forKey: match.key)
        guard setPendingPurchases(entries) else { return nil }
        return match.value
    }

    /// Succeeds when the exact marker is durably absent. Another StoreKit
    /// delivery may win the race and retire it first; a failed persistence
    /// attempt leaves the marker cached and therefore fails closed here.
    func retireCheckoutRecovery(
        appAccountToken: UUID,
        productId: String
    ) -> Bool {
        guard checkoutRecoveryRecord(
            appAccountToken: appAccountToken,
            productId: productId
        ) != nil else { return true }
        return consumeCheckoutRecovery(
            appAccountToken: appAccountToken,
            productId: productId
        ) != nil
    }

    init(
        productService: ProductService,
        transactionObserver: TransactionObserverProtocol,
        pendingPurchaseStore: PendingPurchaseStoreProtocol,
        accountOwnershipStore: PurchaseAccountOwnershipStoreProtocol =
            InMemoryPurchaseAccountOwnershipStore(),
        dateProvider: DateProviderProtocol,
        settings: PurchaseSettingsProviding,
        eventSink: SystemEventSink,
        purchaseStorageScope: PurchaseStorageScope = .testFixture,
        identityService: IdentityServiceProtocol? = nil,
        introEligibilityTokenProvider: any IntroEligibilityTokenProviding =
            UnavailableIntroEligibilityTokenProvider(),
        introEligibilityOverrideHealth: IntroEligibilityOverrideHealth =
            IntroEligibilityOverrideHealth(),
        nativePurchaseAdapter: any NativeStoreKitPurchasing = NativeStoreKitPurchaseAdapter(),
        featureService: FeatureServiceProtocol? = nil,
        testStore: (any NuxieTestStorePurchasing)? = nil,
        activeProductEvidenceAuthority: @escaping @Sendable (String) async ->
            ActiveProductEvidenceAuthorityResolution = { _ in .readyNoMatch }
    ) {
        self.productService = productService
        self.transactionObserver = transactionObserver
        self.pendingPurchaseStore = pendingPurchaseStore
        self.accountOwnershipStore = accountOwnershipStore
        self.activeProductEvidenceAuthority = activeProductEvidenceAuthority
        self.dateProvider = dateProvider
        self.settings = settings
        self.eventSink = eventSink
        self.purchaseStorageScope = purchaseStorageScope
        self.identityService = identityService
        self.introEligibilityTokenProvider = introEligibilityTokenProvider
        self.introEligibilityOverrideHealth = introEligibilityOverrideHealth
        self.nativePurchaseAdapter = nativePurchaseAdapter
        self.featureService = featureService
        self.testStore = testStore
    }
    
    /// Purchase a product
    /// - Parameter product: The exact StoreProduct retained after presentation.
    /// - Throws: StoreKitError when checkout does not complete.
    @discardableResult
    public func purchase(_ product: StoreProduct) async throws -> PurchaseSyncResult {
        LogDebug("TransactionService: Starting purchase for product: \(product.productId)")

        var activeCheckoutKeyToClear: String?
        defer {
            if let activeCheckoutKeyToClear {
                activeCheckoutKeys.remove(activeCheckoutKeyToClear)
            }
        }

        // Checkout belongs to the customer who initiated it. Every store and
        // provider call below can suspend while identify/reset changes the
        // active SDK identity, so never re-read mutable identity for purchase
        // attribution after this point.
        let initiatingDistinctId = identityService?.getDistinctId() ?? "anonymous"
        var checkoutProduct: StoreProduct
        let outcome: NativePurchaseResult
        var testStoreTransactionId: String?
        var observedCompletionTransactionId: String?
        var purchaseCompletionAlreadyReported = false
        var checkoutCompletionEventId: String?
        var checkoutRecoveryToRetireAfterCompletion = false
        let usesTestStore = testStore != nil
        // The delegate is checkout identity. Capture it before any suspension
        // so a concurrent configuration change cannot change which provider
        // is authorized to persist optimistic access for this attempt.
        let checkoutDelegate = purchaseDelegate
        let usesNativeStoreKit = checkoutDelegate == nil && !usesTestStore
        if let testStore {
            checkoutProduct = product
            let response = await testStore.purchase(
                product: product,
                distinctId: initiatingDistinctId
            )
            outcome = response.result
            testStoreTransactionId = response.transactionId
        } else {
            let checkoutToken = try await checkoutIntroEligibilityToken(
                for: product,
                distinctId: initiatingDistinctId
            )
            checkoutProduct = product.preparedForCheckout(
                introEligibilityToken: checkoutToken
            )
            checkoutProduct = try prepareStoreKitCheckout(
                product: checkoutProduct,
                distinctId: initiatingDistinctId,
                evidenceAuthority: checkoutEvidenceAuthority(
                    product: checkoutProduct,
                    delegate: checkoutDelegate
                ),
                localEntitlementGrants: usesNativeStoreKit
                    ? optimisticLocalEntitlementGrants(
                        checkoutProduct.localEntitlementGrants
                    )
                    : providerOptimisticGrants(
                        for: checkoutProduct,
                        delegate: checkoutDelegate
                    )
            )
            if let appAccountToken = checkoutProduct.nativeCheckoutAppAccountToken {
                checkoutCompletionEventId = checkoutRecoveryRecord(
                    appAccountToken: appAccountToken,
                    productId: checkoutProduct.storeProductId
                )?.checkoutCompletionEventId
                let key = activeCheckoutKey(
                    appAccountToken: appAccountToken,
                    productId: checkoutProduct.storeProductId
                )
                activeCheckoutKeys.insert(key)
                activeCheckoutKeyToClear = key
            }
            testStoreTransactionId = nil

            if let delegate = checkoutDelegate {
                switch await delegate.purchase(product: checkoutProduct) {
                case .purchased:
                    outcome = .purchased(nil)
                case .cancelled:
                    outcome = .cancelled
                case .failed(let error):
                    if isProductUnavailable(error) {
                        outcome = .productTermsChanged
                    } else if checkoutProduct.introEligibilityTokenRequest != nil,
                              invalidatesIntroEligibilityOverride(error) {
                        outcome = .invalidEligibilityOverride(error)
                    } else {
                        outcome = .failed(error)
                    }
                case .pending:
                    outcome = .pending
                }
            } else {
                outcome = await nativePurchaseAdapter.purchase(product: checkoutProduct)
            }
        }

        switch outcome {
        case .purchased(let evidence):
            if evidence == nil,
               let appAccountToken = checkoutProduct.nativeCheckoutAppAccountToken,
               let recovery = checkoutRecoveryRecord(
                    appAccountToken: appAccountToken,
                    productId: checkoutProduct.storeProductId
               ) {
                switch recovery.evidenceAuthority {
                case .providerConnector, .nativeStoreKit, .ambiguous:
                    checkoutRecoveryToRetireAfterCompletion = true
                case .outcomeOnlyDelegate:
                    if let transactionId = recovery.observedTransactionId {
                        checkoutRecoveryToRetireAfterCompletion = true
                        observedCompletionTransactionId = transactionId
                        purchaseCompletionAlreadyReported = recovery
                            .completionReportedAt != nil
                    } else {
                        let now = dateProvider.now()
                        guard boundOutcomeOnlyStoreKitObservation(
                            recovery,
                            deadline: dateProvider.date(
                                byAddingTimeInterval: Self
                                    .outcomeOnlyStoreKitObservationTTL,
                                to: now
                            )
                        ) else {
                            throw StoreKitError.purchaseFailed(nil)
                        }
                    }
                }
            }
            if let evidence {
                guard await transactionObserver.recordVerifiedPurchase(
                    evidence: evidence,
                    product: checkoutProduct,
                    distinctId: initiatingDistinctId,
                    finishRequired: settings.purchaseHandlingMode() != .observer
                        || checkoutDelegate != nil
                ) else {
                    throw StoreKitError.purchaseFailed(nil)
                }
                if let appAccountToken = checkoutProduct.nativeCheckoutAppAccountToken {
                    guard retireCheckoutRecovery(
                        appAccountToken: appAccountToken,
                        productId: checkoutProduct.storeProductId
                    ) else {
                        throw StoreKitError.purchaseFailed(nil)
                    }
                }
                // A delegate that returns verified StoreKit evidence has
                // explicitly transferred transaction ownership to Nuxie, so
                // finish it even when the host also uses observer mode.
                if settings.purchaseHandlingMode() != .observer || checkoutDelegate != nil {
                    await evidence.finish()
                    await transactionObserver.markTransactionFinished(
                        transactionId: evidence.transactionId
                    )
                }
            } else if usesTestStore, isActiveCustomer(initiatingDistinctId) {
                await featureService?.applyLocalPurchase(
                    grants: optimisticLocalEntitlementGrants(
                        checkoutProduct.localEntitlementGrants
                    ),
                    transactionId: testStoreTransactionId
                        ?? "nuxie-test-\(checkoutProduct.productId)"
                )
            } else if isActiveCustomer(initiatingDistinctId) {
                // A connected provider owns the receipt and durable billing
                // state. Once its reviewed Product mapping is enabled, the
                // signed Product gives the configured checkout delegate enough
                // information to project Boolean Feature Access immediately.
                // This is optimistic local UI state only; durable access,
                // quotas, and credits still require provider synchronization.
                let providerFeatureGrants = providerOptimisticGrants(
                    for: checkoutProduct,
                    delegate: checkoutDelegate
                )
                if !providerFeatureGrants.isEmpty {
                    await featureService?.applyLocalPurchase(
                        grants: providerFeatureGrants,
                        transactionId: providerLocalAccessTransactionId(
                            storeProductId: checkoutProduct.storeProductId
                        )
                    )
                }
            }
            LogInfo("TransactionService: Purchase completed successfully for product: \(product.productId)")
            if !purchaseCompletionAlreadyReported,
               isActiveCustomer(initiatingDistinctId),
               let commercialContext = checkoutProduct.purchaseContext {
                let completionTransactionId = evidence?.transactionId
                    ?? observedCompletionTransactionId
                    ?? testStoreTransactionId
                let properties = purchaseCompletionProperties(
                    context: commercialContext,
                    transactionId: completionTransactionId,
                    testStore: usesTestStore
                )
                var completionCaptured = false
                if let exactTransactionId = evidence?.transactionId
                    ?? observedCompletionTransactionId {
                    if await transactionObserver.claimPurchaseCompletion(
                        transactionId: exactTransactionId
                    ) {
                        let transactionCompletionEventId = await
                            transactionObserver.purchaseCompletionEventId(
                                transactionId: exactTransactionId
                            )
                        let captured = await eventSink.capture(
                            SystemEventNames.purchaseCompleted,
                            properties: properties,
                            eventId: checkoutCompletionEventId
                                ?? transactionCompletionEventId,
                            distinctId: initiatingDistinctId
                        )
                        let marked = if captured {
                            await transactionObserver.markPurchaseCompletionCaptured(
                                transactionId: exactTransactionId
                            )
                        } else {
                            false
                        }
                        if !marked {
                            await transactionObserver.releasePurchaseCompletionClaim(
                                transactionId: exactTransactionId
                            )
                        }
                        completionCaptured = marked
                    }
                } else if usesTestStore,
                          let completionTransactionId {
                    completionCaptured = await eventSink.capture(
                        SystemEventNames.purchaseCompleted,
                        properties: properties,
                        eventId: await transactionObserver.purchaseCompletionEventId(
                            transactionId: completionTransactionId
                        ),
                        distinctId: initiatingDistinctId
                    )
                } else if let checkoutCompletionEventId {
                    completionCaptured = await eventSink.capture(
                        SystemEventNames.purchaseCompleted,
                        properties: properties,
                        eventId: checkoutCompletionEventId,
                        distinctId: initiatingDistinctId
                    )
                } else {
                    eventSink.emit(SystemEventNames.purchaseCompleted, properties: properties)
                    completionCaptured = true
                }
                if completionCaptured,
                   let appAccountToken = checkoutProduct.nativeCheckoutAppAccountToken,
                   let checkoutCompletionEventId {
                    _ = markCheckoutCompletionReported(
                        appAccountToken: appAccountToken,
                        productId: checkoutProduct.storeProductId,
                        completionEventId: checkoutCompletionEventId,
                        reportedAt: dateProvider.now()
                    )
                }
            }

            if checkoutRecoveryToRetireAfterCompletion,
               let appAccountToken = checkoutProduct.nativeCheckoutAppAccountToken,
               checkoutRecoveryRecord(
                   appAccountToken: appAccountToken,
                   productId: checkoutProduct.storeProductId
               )?.completionReportedAt != nil {
                _ = retireCheckoutRecovery(
                    appAccountToken: appAccountToken,
                    productId: checkoutProduct.storeProductId
                )
            }

            var syncTask: Task<Bool, Never>?
            if usesTestStore {
                return PurchaseSyncResult()
            }
            if let evidence {
                syncTask = Task {
                    let synced = await transactionObserver.syncTransaction(
                        transactionJws: evidence.transactionJws,
                        transactionId: evidence.transactionId,
                        productId: evidence.productId,
                        originalTransactionId: evidence.originalTransactionId
                    )
                    if synced {
                        LogInfo("TransactionService: Purchase synced successfully for product: \(product.productId)")
                    }
                    return synced
                }
            }

            return PurchaseSyncResult(syncTask: syncTask)
            
        case .alreadyOwned:
            removeCheckoutRecovery(for: checkoutProduct)
            LogInfo("TransactionService: Product already owned; reconciling access for \(product.productId)")
            if usesNativeStoreKit {
                await transactionObserver.syncCurrentEntitlements(
                    distinctId: initiatingDistinctId
                )
            }
            eventSink.emit(SystemEventNames.purchaseFailed, properties: [
                "product_id": product.productId,
                "placement_id": product.placementId,
                "store_product_id": product.storeProductId,
                "reason": "already_owned"
            ])
            return PurchaseSyncResult()

        case .subscriptionChangeRequired:
            removeCheckoutRecovery(for: checkoutProduct)
            let error = StoreKitError.subscriptionChangeRequired(product.storeProductId)
            LogInfo("TransactionService: Subscription change required for product: \(product.productId)")
            eventSink.emit(SystemEventNames.purchaseFailed, properties: [
                "product_id": product.productId,
                "placement_id": product.placementId,
                "store_product_id": product.storeProductId,
                "reason": "subscription_change_required"
            ])
            throw error

        case .cancelled:
            removeCheckoutRecovery(for: checkoutProduct)
            LogInfo("TransactionService: Purchase cancelled by user for product: \(product.productId)")
            throw StoreKitError.purchaseCancelled
            
        case .failed(let error):
            removeCheckoutRecovery(for: checkoutProduct)
            if usesNativeStoreKit {
                await productService.invalidate([product.storeProductId])
            }
            LogError("TransactionService: Purchase failed for product: \(product.productId), error: \(error)")
            // Track failed purchase event
            eventSink.emit(SystemEventNames.purchaseFailed, properties: [
                "product_id": product.productId,
                "placement_id": product.placementId,
                "store_product_id": product.storeProductId,
                "error": error.localizedDescription
            ])
            throw StoreKitError.purchaseFailed(error)
            
        case .pending:
            LogInfo("TransactionService: Purchase pending for product: \(product.productId)")
            // Keep a durable marker for every StoreKit-capable checkout path.
            // Provider delegates may own receipt submission and finishing, but
            // the shared Transaction.updates observer still needs to correlate
            // a later Ask-to-Buy/SCA approval with the paywall action.
            if !usesTestStore && (usesNativeStoreKit || checkoutDelegate != nil) {
                var entries = pendingPurchases()
                let key = pendingKey(
                    productId: checkoutProduct.storeProductId,
                    distinctId: initiatingDistinctId
                )
                if let existing = entries[key] {
                    entries[key] = PendingPurchaseRecord(
                        scope: existing.scope,
                        distinctId: existing.distinctId,
                        appAccountToken: existing.appAccountToken,
                        commercialContext: existing.commercialContext,
                        recordedAt: existing.recordedAt,
                        productFeatureIds: existing.productFeatureIds,
                        localEntitlementGrants: existing.localEntitlementGrants,
                        state: .pending,
                        evidenceAuthority: existing.evidenceAuthority,
                        checkoutCompletionEventId: existing.checkoutCompletionEventId,
                        storeKitObservationDeadline: nil,
                        completionReportedAt: existing.completionReportedAt,
                        observedTransactionId: existing.observedTransactionId
                    )
                    guard setPendingPurchases(entries) else {
                        throw StoreKitError.purchaseFailed(nil)
                    }
                } else {
                    // Every StoreKit-capable checkout must install its exact
                    // marker before invoking the delegate/adapter. Never
                    // invent token-bearing attribution after an uncorrelated
                    // checkout already returned pending.
                    throw StoreKitError.purchaseFailed(nil)
                }
            }
            throw StoreKitError.purchasePending

        case .productTermsChanged:
            removeCheckoutRecovery(for: checkoutProduct)
            await productService.invalidate([product.storeProductId])
            throw StoreKitError.productTermsChanged(product.storeProductId)

        case .invalidEligibilityOverride:
            removeCheckoutRecovery(for: checkoutProduct)
            if let request = checkoutProduct.introEligibilityTokenRequest {
                await introEligibilityOverrideHealth.suppress(request)
            }
            await productService.invalidate([product.storeProductId])
            throw StoreKitError.productTermsChanged(product.storeProductId)
        }
    }

    private func removeCheckoutRecovery(for product: StoreProduct) {
        guard let token = product.nativeCheckoutAppAccountToken else { return }
        _ = consumeCheckoutRecovery(
            appAccountToken: token,
            productId: product.storeProductId
        )
    }

    /// Persists exact checkout attribution and installs the same deterministic
    /// account token on the StoreProduct before either Nuxie's adapter or a
    /// configured delegate is allowed to open StoreKit.
    private func prepareStoreKitCheckout(
        product: StoreProduct,
        distinctId: String,
        evidenceAuthority: PurchaseEvidenceAuthority,
        localEntitlementGrants: [StoreProduct.LocalEntitlementGrant]
    ) throws -> StoreProduct {
        guard let commercialContext = product.purchaseContext else {
            throw StoreKitError.apiMisuse(
                reason: "StoreKit checkout requires an authenticated release context"
            )
        }
        let appAccountToken = purchaseStorageScope.appAccountToken(
            distinctId: distinctId
        )
        guard accountOwnershipStore.upsert(StoredPurchaseAccountOwnership(
            scope: purchaseStorageScope,
            appAccountToken: appAccountToken,
            distinctId: distinctId,
            productAuthorities: [
                product.storeProductId: evidenceAuthority.durableProductAuthority,
            ]
        )) else {
            throw StoreKitError.purchaseFailed(nil)
        }
        // Unsigned delegates do not receive optimistic grants and cannot
        // project them from an outcome alone. Retain the signed native mapping
        // only in the protected recovery record so a verified StoreKit update
        // inside the observation window can apply it through Nuxie's pipeline.
        let recoveryLocalEntitlementGrants = evidenceAuthority
            == .outcomeOnlyDelegate
            ? optimisticLocalEntitlementGrants(product.localEntitlementGrants)
            : localEntitlementGrants
        let recordedAt = dateProvider.now()
        let preCallbackObservationDeadline = evidenceAuthority
            == .outcomeOnlyDelegate
            ? dateProvider.date(
                byAddingTimeInterval: Self.outcomeOnlyStoreKitObservationTTL,
                to: recordedAt
            )
            : nil
        let recovery = PendingPurchaseRecord(
            scope: purchaseStorageScope,
            distinctId: distinctId,
            appAccountToken: appAccountToken,
            commercialContext: commercialContext,
            recordedAt: recordedAt,
            productFeatureIds: storeProductFeatureIds(
                product.localEntitlementGrants
            ),
            localEntitlementGrants: recoveryLocalEntitlementGrants.map {
                StoredLocalEntitlementGrant(
                    featureId: $0.featureId,
                    featureExternalId: $0.featureExternalId,
                    allowanceType: $0.allowanceType,
                    allowance: $0.allowance
                )
            },
            state: .checkout,
            evidenceAuthority: evidenceAuthority,
            checkoutCompletionEventId: (["purchase-completed-checkout"]
                + purchaseStorageScope.storageComponents
                + [UUID().uuidString.lowercased()]).joined(separator: ":"),
            storeKitObservationDeadline: preCallbackObservationDeadline
        )
        var entries = pendingPurchases()
        let recoveryKey = pendingKey(
            productId: product.storeProductId,
            distinctId: distinctId
        )
        if let existing = entries[recoveryKey] {
            let retryCutoff = dateProvider.date(
                byAddingTimeInterval: -Self.checkoutRecoveryTTL,
                to: dateProvider.now()
            )
            let isSafeSameContextRetry = existing.state == .checkout
                && existing.recordedAt <= retryCutoff
                && existing.commercialContext == recovery.commercialContext
            guard isSafeSameContextRetry else {
                throw StoreKitError.apiMisuse(
                    reason: "A purchase is already unresolved for this customer and product"
                )
            }
        }
        entries[recoveryKey] = recovery
        guard setPendingPurchases(entries) else {
            throw StoreKitError.purchaseFailed(nil)
        }
        var prepared = product.preparedForNativeCheckout(
            appAccountToken: appAccountToken
        )
        // The checkout copy is also the exact value passed to the delegate and
        // recorded with any returned StoreKit evidence. Strip grants here so
        // neither a generic delegate nor a mismatched maintained adapter can
        // reintroduce unauthorised optimistic access through the evidence path.
        prepared.localEntitlementGrants = localEntitlementGrants
        return prepared
    }

    private func checkoutEvidenceAuthority(
        product: StoreProduct,
        delegate: (any NuxiePurchaseDelegate)?
    ) -> PurchaseEvidenceAuthority {
        guard delegate != nil else { return .nativeStoreKit }
        return product.providerFeatureAccess == nil
            ? .outcomeOnlyDelegate
            : .providerConnector
    }

    private func boundOutcomeOnlyStoreKitObservation(
        _ recovery: PendingPurchaseRecord,
        deadline: Date
    ) -> Bool {
        var entries = pendingPurchases()
        let key = pendingKey(
            productId: recovery.commercialContext.storeProductId,
            distinctId: recovery.distinctId
        )
        guard entries[key] == recovery else {
            // Transaction.updates may have already consumed the exact marker.
            return true
        }
        entries[key] = PendingPurchaseRecord(
            scope: recovery.scope,
            distinctId: recovery.distinctId,
            appAccountToken: recovery.appAccountToken,
            commercialContext: recovery.commercialContext,
            recordedAt: recovery.recordedAt,
            productFeatureIds: recovery.productFeatureIds,
            localEntitlementGrants: recovery.localEntitlementGrants,
            state: .checkout,
            evidenceAuthority: recovery.evidenceAuthority,
            checkoutCompletionEventId: recovery.checkoutCompletionEventId,
            storeKitObservationDeadline: deadline,
            completionReportedAt: recovery.completionReportedAt,
            observedTransactionId: recovery.observedTransactionId
        )
        return setPendingPurchases(entries)
    }

    func markOutcomeOnlyTransactionObserved(
        _ recovery: PendingPurchaseRecord,
        transactionId: String
    ) -> Bool {
        guard recovery.evidenceAuthority == .outcomeOnlyDelegate else {
            return false
        }
        var entries = pendingPurchases()
        let key = pendingKey(
            productId: recovery.commercialContext.storeProductId,
            distinctId: recovery.distinctId
        )
        guard entries[key] == recovery else { return false }
        entries[key] = PendingPurchaseRecord(
            scope: recovery.scope,
            distinctId: recovery.distinctId,
            appAccountToken: recovery.appAccountToken,
            commercialContext: recovery.commercialContext,
            recordedAt: recovery.recordedAt,
            productFeatureIds: recovery.productFeatureIds,
            localEntitlementGrants: recovery.localEntitlementGrants,
            state: recovery.state,
            evidenceAuthority: recovery.evidenceAuthority,
            checkoutCompletionEventId: recovery.checkoutCompletionEventId,
            storeKitObservationDeadline: recovery.storeKitObservationDeadline,
            completionReportedAt: recovery.completionReportedAt,
            observedTransactionId: transactionId
        )
        return setPendingPurchases(entries)
    }

    func markOutcomeOnlyCompletionReported(
        appAccountToken: UUID,
        productId: String,
        transactionId: String,
        reportedAt: Date
    ) -> Bool {
        var entries = pendingPurchases()
        guard let entry = entries.first(where: {
            $0.value.appAccountToken == appAccountToken
                && $0.value.commercialContext.storeProductId == productId
                && $0.value.observedTransactionId == transactionId
        }) else { return false }
        let recovery = entry.value
        entries[entry.key] = PendingPurchaseRecord(
            scope: recovery.scope,
            distinctId: recovery.distinctId,
            appAccountToken: recovery.appAccountToken,
            commercialContext: recovery.commercialContext,
            recordedAt: recovery.recordedAt,
            productFeatureIds: recovery.productFeatureIds,
            localEntitlementGrants: recovery.localEntitlementGrants,
            state: recovery.state,
            evidenceAuthority: recovery.evidenceAuthority,
            checkoutCompletionEventId: recovery.checkoutCompletionEventId,
            storeKitObservationDeadline: recovery.storeKitObservationDeadline,
            completionReportedAt: recovery.completionReportedAt ?? reportedAt,
            observedTransactionId: recovery.observedTransactionId
        )
        return setPendingPurchases(entries)
    }

    func markCheckoutCompletionReported(
        appAccountToken: UUID,
        productId: String,
        completionEventId: String,
        reportedAt: Date
    ) -> Bool {
        var entries = pendingPurchases()
        guard let entry = entries.first(where: {
            $0.value.appAccountToken == appAccountToken
                && $0.value.commercialContext.storeProductId == productId
                && $0.value.checkoutCompletionEventId == completionEventId
        }) else { return false }
        let recovery = entry.value
        entries[entry.key] = PendingPurchaseRecord(
            scope: recovery.scope,
            distinctId: recovery.distinctId,
            appAccountToken: recovery.appAccountToken,
            commercialContext: recovery.commercialContext,
            recordedAt: recovery.recordedAt,
            productFeatureIds: recovery.productFeatureIds,
            localEntitlementGrants: recovery.localEntitlementGrants,
            state: recovery.state,
            evidenceAuthority: recovery.evidenceAuthority,
            checkoutCompletionEventId: recovery.checkoutCompletionEventId,
            storeKitObservationDeadline: recovery.storeKitObservationDeadline,
            completionReportedAt: recovery.completionReportedAt ?? reportedAt,
            observedTransactionId: recovery.observedTransactionId
        )
        return setPendingPurchases(entries)
    }

    private func checkoutIntroEligibilityToken(
        for shown: StoreProduct,
        distinctId: String
    ) async throws -> String? {
        guard let request = shown.introEligibilityTokenRequest else { return nil }
        // Eligibility authority is customer-scoped. A controller can remain on
        // screen while identify/reset changes the active SDK identity, so a
        // request prepared for the previous customer must never be signed for
        // checkout under the new one.
        guard request.authorization.distinctId == distinctId else {
            throw StoreKitError.productTermsChanged(shown.storeProductId)
        }
        guard await !introEligibilityOverrideHealth.isSuppressed(request) else {
            throw StoreKitError.productTermsChanged(shown.storeProductId)
        }
        do {
            guard let token = normalizedCompactJWS(
                try await introEligibilityTokenProvider.token(for: request)
            ) else {
                throw StoreKitError.productTermsChanged(shown.storeProductId)
            }
            return token
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw StoreKitError.productTermsChanged(shown.storeProductId)
        }
    }

    private func isProductUnavailable(_ error: Error) -> Bool {
        guard let purchaseError = error as? Product.PurchaseError else { return false }
        return purchaseError == .productUnavailable
    }

    private func providerOptimisticGrants(
        for product: StoreProduct,
        delegate: (any NuxiePurchaseDelegate)?
    ) -> [StoreProduct.LocalEntitlementGrant] {
        guard delegate != nil, product.providerFeatureAccess != nil else {
            return []
        }
        return optimisticLocalEntitlementGrants(product.localEntitlementGrants)
    }

    private func isActiveCustomer(_ distinctId: String) -> Bool {
        (identityService?.getDistinctId() ?? "anonymous") == distinctId
    }
    
    /// Restore previous purchases
    /// - Throws: StoreKitError when restore fails.
    public func restore() async throws {
        LogDebug("TransactionService: Starting restore purchases")

        let initiatingDistinctId = identityService?.getDistinctId() ?? "anonymous"
        enum RestoreOutcome {
            case restored
            case testStoreRestored
            case failed(Error)
            case noPurchases
        }
        let result: RestoreOutcome
        var testStoreProducts: [StoreProduct] = []
        let usesTestStore = testStore != nil
        if let testStore {
            let response = await testStore.restorePurchases(
                distinctId: initiatingDistinctId
            )
            switch response.result {
            case .restored: result = .testStoreRestored
            case .failed(let error): result = .failed(error)
            case .noPurchases: result = .noPurchases
            }
            testStoreProducts = response.products
        } else if let delegate = purchaseDelegate {
            switch await delegate.restorePurchases() {
            case .restored: result = .restored
            case .failed(let error): result = .failed(error)
            case .noPurchases: result = .noPurchases
            }
        } else {
            switch await nativePurchaseAdapter.restorePurchases() {
            case .restored: result = .restored
            case .failed(let error): result = .failed(error)
            case .noPurchases: result = .noPurchases
            }
        }
        
        switch result {
        case .restored, .testStoreRestored:
            LogInfo("TransactionService: Restore completed successfully")
            if usesTestStore, isActiveCustomer(initiatingDistinctId) {
                for product in testStoreProducts {
                    await featureService?.applyLocalPurchase(
                        grants: optimisticLocalEntitlementGrants(
                            product.localEntitlementGrants
                        ),
                        transactionId: "nuxie-test-restore-\(product.productId)"
                    )
                }
            }
            // Restored transactions do not re-emit through Transaction.updates,
            // so sync current entitlements to the backend explicitly — otherwise
            // a restore on a new device never updates server-side entitlements.
            if case .restored = result,
               isActiveCustomer(initiatingDistinctId) {
                await transactionObserver.syncCurrentEntitlements(
                    distinctId: initiatingDistinctId
                )
            }
            // Track successful restore event
            if isActiveCustomer(initiatingDistinctId) {
                eventSink.emit(SystemEventNames.restoreCompleted, properties: usesTestStore
                    ? ["test_store": true]
                    : nil)
            }
            
        case .failed(let error):
            LogError("TransactionService: Restore failed, error: \(error)")
            // Track failed restore event
            if isActiveCustomer(initiatingDistinctId) {
                eventSink.emit(SystemEventNames.restoreFailed, properties: [
                    "error": error.localizedDescription,
                    "test_store": usesTestStore
                ])
            }
            throw StoreKitError.restoreFailed(error)
            
        case .noPurchases:
            LogInfo("TransactionService: No purchases to restore")
            // Track no purchases event
            if isActiveCustomer(initiatingDistinctId) {
                eventSink.emit(SystemEventNames.restoreNoPurchases, properties: usesTestStore
                    ? ["test_store": true]
                    : nil)
            }
        }
    }
}
