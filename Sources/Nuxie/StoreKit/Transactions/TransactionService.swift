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

struct CommerceOutcomeCorrelation: Equatable, Sendable {
    let eventId: String
    let distinctId: String
}

enum PendingPurchaseOwnershipResolution: Sendable {
    case none
    case unique(PendingPurchaseRecord)
    case ambiguous
    case unavailable
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

    /// Exact pre-checkout contexts, including deferred purchases. Durable,
    /// loaded lazily, scope-checked, and pruned by TTL.
    private var cachedPendingPurchases: [String: PendingPurchaseRecord]?
    private var pendingPurchaseStateUnreadable = false
    /// Process-local Journey authority. Durable checkout records preserve
    /// commercial attribution after relaunch, but only a checkout still
    /// executing in this process may route an ordinary checkout completion.
    private var activeCheckoutKeys: Set<String> = []

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

    private func pendingKey(productId: String, distinctId: String) -> String {
        "\(distinctId)::\(productId)"
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

    /// Returns the signed allowance mapping captured for a pending native purchase.
    /// The marker is consumed only after the verified transaction has
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
        guard !pendingPurchaseStateUnreadable else { return .unavailable }
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
        let loaded: [String: PendingPurchaseRecord]
        if let cachedPendingPurchases {
            loaded = cachedPendingPurchases
        } else {
            switch pendingPurchaseStore.load() {
            case .absent:
                loaded = [:]
            case .value(let entries):
                loaded = entries
            case .unreadable:
                pendingPurchaseStateUnreadable = true
                return [:]
            }
        }
        pendingPurchaseStateUnreadable = false
        let pruned = loaded.filter {
            guard $0.value.scope == purchaseStorageScope else { return false }
            // Unified external declarations never create native recovery
            // markers. Drop any provider/ambiguous marker decoded from an
            // earlier SDK before it can influence StoreKit evidence ownership.
            guard $0.value.evidenceAuthority == .nativeStoreKit else {
                return false
            }
            let cutoff = dateProvider.date(
                byAddingTimeInterval: -Self.pendingPurchaseTTL,
                to: dateProvider.now()
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
        guard !pendingPurchaseStateUnreadable else { return false }
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

    func pendingPurchaseStoreIsUnreadable() -> Bool {
        if cachedPendingPurchases == nil { _ = pendingPurchases() }
        return pendingPurchaseStateUnreadable
    }

    func purchaseAccountOwner(
        appAccountToken: UUID?
    ) -> StoreReadResult<String> {
        guard let appAccountToken else { return .absent }
        switch accountOwnershipStore.load() {
        case .absent:
            return .absent
        case .unreadable:
            return .unreadable
        case .value(let entries):
            let ownership = entries[appAccountToken.uuidString]
            guard ownership?.scope == purchaseStorageScope,
                  let distinctId = ownership?.distinctId else { return .absent }
            return .value(distinctId)
        }
    }

    func activePurchaseEvidenceAuthority(
        productId: String
    ) async -> ActiveProductEvidenceAuthorityResolution {
        await activeProductEvidenceAuthority(productId)
    }

    func durablePurchaseEvidenceAuthority(
        appAccountToken: UUID?,
        productId: String
    ) -> StoreReadResult<PurchaseEvidenceAuthority> {
        let entries: [String: StoredPurchaseAccountOwnership]
        switch accountOwnershipStore.load() {
        case .absent:
            return .absent
        case .unreadable:
            return .unreadable
        case .value(let loaded):
            entries = loaded
        }
        if let appAccountToken,
           let ownership = entries[appAccountToken.uuidString],
           ownership.scope == purchaseStorageScope,
           let authority = ownership.productAuthorities[productId] {
            return .value(authority)
        }
        guard let activeDistinctId = identityService?.getDistinctId() else {
            return .absent
        }
        let token = purchaseStorageScope.appAccountToken(
            distinctId: activeDistinctId
        )
        guard let ownership = entries[token.uuidString],
              ownership.scope == purchaseStorageScope,
              let authority = ownership.productAuthorities[productId] else {
            return .absent
        }
        return .value(authority)
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
        let recovery = checkoutRecoveryRecord(
            appAccountToken: appAccountToken,
            productId: productId
        )
        guard !pendingPurchaseStateUnreadable else { return false }
        guard recovery != nil else { return true }
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
    /// - Parameter outcomeCorrelation: Stable Journey event ownership for the
    ///   resulting purchase outcome, when checkout began in a Journey.
    /// - Throws: StoreKitError when checkout does not complete.
    @discardableResult
    public func purchase(
        _ product: StoreProduct,
        outcomeCorrelation: CommerceOutcomeCorrelation? = nil
    ) async throws -> PurchaseSyncResult {
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
        let initiatingDistinctId = outcomeCorrelation?.distinctId
            ?? identityService?.getDistinctId()
            ?? "anonymous"
        var checkoutProduct: StoreProduct
        let outcome: NativePurchaseResult?
        let purchaseOutcome: PurchaseOutcome
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
            purchaseOutcome = makePurchaseOutcome(
                response.result,
                product: checkoutProduct,
                distinctId: initiatingDistinctId,
                testStoreTransactionId: response.transactionId,
                usesTestStore: true,
                outcomeCorrelation: outcomeCorrelation
            )
        } else {
            let checkoutToken = try await checkoutIntroEligibilityToken(
                for: product,
                distinctId: initiatingDistinctId
            )
            checkoutProduct = product.preparedForCheckout(
                introEligibilityToken: checkoutToken
            )
            if let delegate = checkoutDelegate {
                guard let context = checkoutProduct.purchaseContext else {
                    throw StoreKitError.apiMisuse(
                        reason: "External checkout requires an authenticated release context"
                    )
                }
                switch await delegate.purchase(product: checkoutProduct) {
                case .purchased:
                    outcome = nil
                    purchaseOutcome = .external(
                        ExternalPurchaseDeclaration(
                            operationId: UUID().uuidString.lowercased(),
                            distinctId: initiatingDistinctId,
                            kind: .purchased(
                                context: context,
                                transactionId: nil,
                                testStore: false
                            ),
                            outcomeEventId: outcomeCorrelation?.eventId
                        ),
                        source: .externalDelegate
                    )
                case .cancelled:
                    outcome = .cancelled
                    purchaseOutcome = .cancelled(source: .externalDelegate)
                case .failed(let error):
                    if isProductUnavailable(error) {
                        outcome = .productTermsChanged
                    } else if checkoutProduct.introEligibilityTokenRequest != nil,
                              invalidatesIntroEligibilityOverride(error) {
                        outcome = .invalidEligibilityOverride(error)
                    } else {
                        outcome = .failed(error)
                    }
                    purchaseOutcome = .failed(
                        reason: error.localizedDescription,
                        source: .externalDelegate
                    )
                case .pending:
                    outcome = .pending
                    purchaseOutcome = .pending(source: .externalDelegate)
                }
            } else {
                checkoutProduct = try prepareStoreKitCheckout(
                    product: checkoutProduct,
                    distinctId: initiatingDistinctId,
                    evidenceAuthority: .nativeStoreKit,
                    localEntitlementGrants: optimisticLocalEntitlementGrants(
                        checkoutProduct.localEntitlementGrants
                    ),
                    outcomeEventId: outcomeCorrelation?.eventId
                )
                if let appAccountToken = checkoutProduct.nativeCheckoutAppAccountToken {
                    let key = activeCheckoutKey(
                        appAccountToken: appAccountToken,
                        productId: checkoutProduct.storeProductId
                    )
                    activeCheckoutKeys.insert(key)
                    activeCheckoutKeyToClear = key
                }
                let nativeOutcome = await nativePurchaseAdapter.purchase(
                    product: checkoutProduct
                )
                outcome = nativeOutcome
                purchaseOutcome = makePurchaseOutcome(
                    nativeOutcome,
                    product: checkoutProduct,
                    distinctId: initiatingDistinctId,
                    testStoreTransactionId: nil,
                    usesTestStore: false,
                    outcomeCorrelation: outcomeCorrelation
                )
            }
        }

        let commitResult = await transactionObserver.commit(purchaseOutcome)
        guard let outcome else {
            guard commitResult.committed else {
                throw StoreKitError.purchaseFailed(nil)
            }
            LogInfo(
                "TransactionService: External purchase declared for product: \(product.productId)"
            )
            return PurchaseSyncResult(syncTask: commitResult.syncTask)
        }

        switch outcome {
        case .purchased:
            guard commitResult.committed else {
                throw StoreKitError.purchaseFailed(nil)
            }
            LogInfo(
                "TransactionService: Purchase completed successfully for product: \(product.productId)"
            )
            return PurchaseSyncResult(syncTask: commitResult.syncTask)
            
        case .alreadyOwned:
            removeCheckoutRecovery(for: checkoutProduct)
            LogInfo("TransactionService: Product already owned; reconciling access for \(product.productId)")
            if usesNativeStoreKit {
                await transactionObserver.syncCurrentEntitlements(
                    distinctId: initiatingDistinctId
                )
            }
            await publishCommerceOutcome(
                SystemEventNames.purchaseFailed,
                properties: [
                "product_id": product.productId,
                "placement_id": product.placementId,
                "store_product_id": product.storeProductId,
                "reason": "already_owned",
                "test_store": usesTestStore,
                ],
                correlation: outcomeCorrelation
            )
            return PurchaseSyncResult()

        case .subscriptionChangeRequired:
            removeCheckoutRecovery(for: checkoutProduct)
            let error = StoreKitError.subscriptionChangeRequired(product.storeProductId)
            LogInfo("TransactionService: Subscription change required for product: \(product.productId)")
            await publishCommerceOutcome(
                SystemEventNames.purchaseFailed,
                properties: [
                "product_id": product.productId,
                "placement_id": product.placementId,
                "store_product_id": product.storeProductId,
                "reason": "subscription_change_required",
                "test_store": usesTestStore,
                ],
                correlation: outcomeCorrelation
            )
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
            await publishCommerceOutcome(
                SystemEventNames.purchaseFailed,
                properties: [
                "product_id": product.productId,
                "placement_id": product.placementId,
                "store_product_id": product.storeProductId,
                "error": error.localizedDescription,
                "test_store": usesTestStore,
                ],
                correlation: outcomeCorrelation
            )
            throw StoreKitError.purchaseFailed(error)
            
        case .pending:
            LogInfo("TransactionService: Purchase pending for product: \(product.productId)")
            // Native Ask-to-Buy/SCA remains correlated through the durable
            // pre-checkout marker. External delegates own their pending state.
            if usesNativeStoreKit {
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
                        checkoutCompletionEventId: existing.checkoutCompletionEventId
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

    private func makePurchaseOutcome(
        _ result: NativePurchaseResult,
        product: StoreProduct,
        distinctId: String,
        testStoreTransactionId: String?,
        usesTestStore: Bool,
        outcomeCorrelation: CommerceOutcomeCorrelation?
    ) -> PurchaseOutcome {
        switch result {
        case .purchased(let evidence):
            if usesTestStore, let context = product.purchaseContext {
                return .external(
                    ExternalPurchaseDeclaration(
                        operationId: testStoreTransactionId
                            ?? UUID().uuidString.lowercased(),
                        distinctId: distinctId,
                            kind: .purchased(
                                context: context,
                                transactionId: testStoreTransactionId,
                                testStore: true
                            ),
                            outcomeEventId: outcomeCorrelation?.eventId
                    ),
                    source: .checkout
                )
            }
            guard let evidence else {
                return .failed(
                    reason: "verified_evidence_unavailable",
                    source: .checkout
                )
            }
            return .verified(
                VerifiedPurchaseEvidence(
                    transactionJws: evidence.transactionJws,
                    transactionId: evidence.transactionId,
                    originalTransactionId: evidence.originalTransactionId,
                    productId: evidence.productId,
                    appAccountToken: product.nativeCheckoutAppAccountToken,
                    attributedDistinctId: distinctId,
                    recordedAt: dateProvider.now(),
                    productFeatureIds: storeProductFeatureIds(
                        product.localEntitlementGrants
                    ),
                    commercialContext: product.purchaseContext,
                    checkoutCompletionEventId: outcomeCorrelation?.eventId,
                    finishRequired: settings.purchaseHandlingMode() != .observer,
                    resolvesPendingPurchase: true,
                    allowsDurableCheckoutAuthority: true,
                    requiresAuthorityResolution: false,
                    finish: evidence.finish
                ),
                source: .checkout
            )
        case .alreadyOwned:
            return .failed(reason: "already_owned", source: .checkout)
        case .subscriptionChangeRequired:
            return .failed(
                reason: "subscription_change_required",
                source: .checkout
            )
        case .cancelled:
            return .cancelled(source: .checkout)
        case .pending:
            return .pending(source: .checkout)
        case .productTermsChanged:
            return .failed(reason: "product_terms_changed", source: .checkout)
        case .invalidEligibilityOverride(let error), .failed(let error):
            return .failed(
                reason: error.localizedDescription,
                source: .checkout
            )
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
    /// account token before Nuxie's native StoreKit adapter opens checkout.
    private func prepareStoreKitCheckout(
        product: StoreProduct,
        distinctId: String,
        evidenceAuthority: PurchaseEvidenceAuthority,
        localEntitlementGrants: [StoreProduct.LocalEntitlementGrant],
        outcomeEventId: String?
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
        let recordedAt = dateProvider.now()
        let recovery = PendingPurchaseRecord(
            scope: purchaseStorageScope,
            distinctId: distinctId,
            appAccountToken: appAccountToken,
            commercialContext: commercialContext,
            recordedAt: recordedAt,
            productFeatureIds: storeProductFeatureIds(
                product.localEntitlementGrants
            ),
            localEntitlementGrants: localEntitlementGrants.map {
                StoredLocalEntitlementGrant(
                    featureId: $0.featureId,
                    featureExternalId: $0.featureExternalId,
                    allowanceType: $0.allowanceType,
                    allowance: $0.allowance
                )
            },
            state: .checkout,
            evidenceAuthority: evidenceAuthority,
            checkoutCompletionEventId: outcomeEventId
                ?? (["purchase-completed-checkout"]
                    + purchaseStorageScope.storageComponents
                    + [UUID().uuidString.lowercased()]).joined(separator: ":")
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
        // Record only the signed grants the verified-evidence path may project.
        prepared.localEntitlementGrants = localEntitlementGrants
        return prepared
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

    private func isActiveCustomer(_ distinctId: String) -> Bool {
        (identityService?.getDistinctId() ?? "anonymous") == distinctId
    }
    
    /// Restore previous purchases
    /// - Parameter outcomeCorrelation: Stable Journey event ownership for the
    ///   resulting restore outcome, when restore began in a Journey.
    /// - Throws: StoreKitError when restore fails.
    public func restore(
        outcomeCorrelation: CommerceOutcomeCorrelation? = nil
    ) async throws {
        LogDebug("TransactionService: Starting restore purchases")

        let initiatingDistinctId = outcomeCorrelation?.distinctId
            ?? identityService?.getDistinctId()
            ?? "anonymous"
        // Test Store is an isolated billing environment and has the same
        // precedence for purchase and restore. A configured host delegate is
        // consulted only when Test Store is not active.
        if testStore == nil, let delegate = purchaseDelegate {
            switch await delegate.restorePurchases() {
            case .restored:
                let result = await transactionObserver.commit(.external(
                    ExternalPurchaseDeclaration(
                        operationId: UUID().uuidString.lowercased(),
                        distinctId: initiatingDistinctId,
                        kind: .restored(testStore: false),
                        outcomeEventId: outcomeCorrelation?.eventId
                    ),
                    source: .externalDelegate
                ))
                guard result.committed else {
                    throw StoreKitError.restoreFailed(nil)
                }
                LogInfo("TransactionService: External restore declared successfully")
                return
            case .failed(let error):
                LogError("TransactionService: Restore failed, error: \(error)")
                if outcomeCorrelation != nil || isActiveCustomer(initiatingDistinctId) {
                    await publishCommerceOutcome(
                        SystemEventNames.restoreFailed,
                        properties: [
                        "error": error.localizedDescription,
                        "test_store": false,
                        ],
                        correlation: outcomeCorrelation
                    )
                }
                throw StoreKitError.restoreFailed(error)
            case .noPurchases:
                LogInfo("TransactionService: No purchases to restore")
                if outcomeCorrelation != nil || isActiveCustomer(initiatingDistinctId) {
                    await publishCommerceOutcome(
                        SystemEventNames.restoreNoPurchases,
                        properties: [:],
                        correlation: outcomeCorrelation
                    )
                }
                return
            }
        }

        enum RestoreOutcome {
            case restored
            case testStoreRestored
            case failed(Error)
            case noPurchases
        }
        let result: RestoreOutcome
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
            if outcomeCorrelation != nil || isActiveCustomer(initiatingDistinctId) {
                await publishCommerceOutcome(
                    SystemEventNames.restoreCompleted,
                    properties: usesTestStore ? ["test_store": true] : nil,
                    correlation: outcomeCorrelation
                )
            }
            
        case .failed(let error):
            LogError("TransactionService: Restore failed, error: \(error)")
            // Track failed restore event
            if outcomeCorrelation != nil || isActiveCustomer(initiatingDistinctId) {
                await publishCommerceOutcome(
                    SystemEventNames.restoreFailed,
                    properties: [
                    "error": error.localizedDescription,
                    "test_store": usesTestStore
                    ],
                    correlation: outcomeCorrelation
                )
            }
            throw StoreKitError.restoreFailed(error)
            
        case .noPurchases:
            LogInfo("TransactionService: No purchases to restore")
            // Track no purchases event
            if outcomeCorrelation != nil || isActiveCustomer(initiatingDistinctId) {
                await publishCommerceOutcome(
                    SystemEventNames.restoreNoPurchases,
                    properties: usesTestStore ? ["test_store": true] : nil,
                    correlation: outcomeCorrelation
                )
            }
        }
    }

    private func publishCommerceOutcome(
        _ name: String,
        properties: [String: Any]?,
        correlation: CommerceOutcomeCorrelation?
    ) async {
        let properties = UncheckedSendable(properties)
        guard await eventSink.emitOrCaptureCommerceOutcome(
            name,
            properties: properties,
            correlation: correlation
        ) else {
            LogError(
                "TransactionService: correlated commerce outcome has no capture retry owner"
            )
            return
        }
    }
}
