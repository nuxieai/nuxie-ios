import Foundation

/// Protocol defining the FeatureService interface
protocol FeatureServiceProtocol: AnyObject, Sendable {
    /// Check feature access from cache (instant, non-blocking)
    func getCached(featureId: String, entityId: String?) async -> FeatureAccess?

    /// Get all cached features from profile
    func getAllCached() async -> [String: FeatureAccess]

    /// Check feature access via real-time API call
    func check(
        featureId: String,
        requiredBalance: Double?,
        entityId: String?
    ) async throws -> FeatureCheckResult

    /// Check feature access with cache-first strategy
    func checkWithCache(
        featureId: String,
        requiredBalance: Double?,
        entityId: String?,
        forceRefresh: Bool
    ) async throws -> FeatureAccess

    /// Clear all feature cache
    func clearCache() async

    /// Handle user identity change
    func handleUserChange(from oldDistinctId: String, to newDistinctId: String) async

    /// Sync FeatureInfo from profile cache (call after profile refresh)
    func syncFeatureInfo() async

    /// Update feature cache from a purchase response for the customer who
    /// initiated the transaction sync.
    func updateFromPurchase(
        _ features: [PurchaseFeature],
        distinctId: String
    ) async

    /// Commit the server-authoritative result of an atomic purchase-backed
    /// Feature use for the customer who initiated it.
    func applyAuthoritativeUse(
        _ result: FeatureCheckResult,
        requestedFeatureId: String,
        distinctId: String,
        entityId: String?
    ) async

    /// Apply the immutable Product-to-feature mapping immediately after a
    /// verified native purchase. Durable balances still reconcile from the
    /// server; this projection is only the offline/local access view.
    func applyLocalPurchase(
        grants: [StoreProduct.LocalEntitlementGrant],
        transactionId: String
    ) async

    /// Remove locally projected access when StoreKit reports that the
    /// purchase was revoked. The provider still owns its receipt lifecycle;
    /// this only clears Nuxie's optimistic offline projection.
    func removeLocalPurchase(
        transactionId: String,
        grants: [StoreProduct.LocalEntitlementGrant]
    ) async
}

extension FeatureServiceProtocol {
    func applyAuthoritativeUse(
        _ result: FeatureCheckResult,
        requestedFeatureId: String,
        distinctId: String,
        entityId: String?
    ) async {}

    func applyLocalPurchase(
        grants: [StoreProduct.LocalEntitlementGrant],
        transactionId: String
    ) async {}

    func removeLocalPurchase(
        transactionId: String,
        grants: [StoreProduct.LocalEntitlementGrant] = []
    ) async {}
}

/// Manages feature access checking with caching
/// Uses ProfileService's cached features as primary source, with real-time API fallback
internal actor FeatureService: FeatureServiceProtocol {

    private struct FeatureCacheKey: Hashable {
        let featureId: String
        let entityId: String?
    }

    private struct CachedFeatureOverride {
        let type: FeatureType
        let unlimited: Bool
        let balance: Double?
        let allowed: Bool
        /// When set, `balance` belongs to a different credit-system Feature.
        /// The opaque requested-feature snapshot is reusable only for the
        /// exact requirement the server evaluated.
        let opaqueRequiredBalance: Double?

        init(result: FeatureCheckResult) {
            self.type = result.type
            self.unlimited = result.unlimited
            self.balance = result.balance
            self.allowed = result.allowed
            self.opaqueRequiredBalance = nil
        }

        init(authoritative result: FeatureCheckResult, requestedFeatureId: String) {
            let access = FeatureAccess(
                authoritative: result,
                requestedFeatureId: requestedFeatureId
            )
            self.type = access.type
            self.unlimited = access.unlimited
            self.balance = access.balance
            self.allowed = access.allowed
            self.opaqueRequiredBalance = result.featureId == requestedFeatureId
                ? nil
                : result.requiredBalance
        }

        init(purchase: PurchaseFeature) {
            self.type = purchase.type
            self.unlimited = purchase.unlimited
            self.balance = purchase.balance
            self.allowed = purchase.allowed
            self.opaqueRequiredBalance = nil
        }

        init(type: FeatureType, unlimited: Bool, balance: Double?, allowed: Bool) {
            self.type = type
            self.unlimited = unlimited
            self.balance = balance
            self.allowed = allowed
            self.opaqueRequiredBalance = nil
        }

        func access(requiredBalance: Double?) -> FeatureAccess {
            if let opaqueRequiredBalance {
                let matchesRequirement = (requiredBalance ?? 1)
                    == opaqueRequiredBalance
                return FeatureAccess(
                    allowed: matchesRequirement && allowed,
                    unlimited: matchesRequirement && unlimited,
                    balance: nil,
                    type: type,
                    opaqueRequiredBalance: opaqueRequiredBalance
                )
            }
            switch type {
            case .boolean:
                return FeatureAccess(
                    allowed: allowed,
                    unlimited: unlimited,
                    balance: balance,
                    type: type
                )
            case .metered, .creditSystem:
                if unlimited {
                    return FeatureAccess(
                        allowed: true,
                        unlimited: true,
                        balance: balance,
                        type: type
                    )
                }

                if let balance {
                    return FeatureAccess(
                        allowed: balance >= (requiredBalance ?? 1),
                        unlimited: false,
                        balance: balance,
                        type: type
                    )
                }

                return FeatureAccess(
                    allowed: allowed,
                    unlimited: unlimited,
                    balance: nil,
                    type: type
                )
            }
        }

        /// The raw server decision published to FeatureInfo. Unlike a public
        /// default-balance cache query, this retains the exact amount that an
        /// opaque transitive decision covered so gate plans can evaluate it.
        func publishedAccess() -> FeatureAccess {
            guard let opaqueRequiredBalance else {
                return access(requiredBalance: nil)
            }
            return FeatureAccess(
                allowed: allowed,
                unlimited: unlimited,
                balance: nil,
                type: type,
                opaqueRequiredBalance: opaqueRequiredBalance
            )
        }

        func isExactOpaqueSnapshot(requiredBalance: Double?) -> Bool {
            guard let opaqueRequiredBalance else { return false }
            return (requiredBalance ?? 1) == opaqueRequiredBalance
        }
    }

    // MARK: - Properties

    // In-memory cache for fresh feature access overrides from real-time checks and purchase syncs.
    // These values are newer than the profile snapshot and should win until they expire.
    private var realTimeCache: [FeatureCacheKey: (override: CachedFeatureOverride, cachedAt: Date)] = [:]
    /// Access projected from a verified purchase mapping. Unlike a real-time
    /// feature check, this remains valid while the customer is offline; the
    /// transaction/evidence lifecycle is responsible for rehydrating it after
    /// relaunch and identity changes clear it explicitly.
    private var localPurchaseCache: [FeatureCacheKey: CachedFeatureOverride] = [:]
    /// Fail-closed access for a locally verified purchase that StoreKit later
    /// removed or revoked. This outranks a stale cached profile until a fresh
    /// server check or purchase response reconciles the feature.
    private var revokedPurchaseCache: [FeatureCacheKey: CachedFeatureOverride] = [:]
    private var localPurchaseTransactions: Set<String> = []
    private var localPurchaseOverrides: [String: [FeatureCacheKey: CachedFeatureOverride]] = [:]
    private var durableAccessHydratedDistinctId: String?
    /// Monotonic per-feature mutation revision. A feature check captures this
    /// before suspending so an older response cannot erase a purchase grant or
    /// a newer server reconciliation that completed while it was in flight.
    private var featureMutationRevisions: [String: UInt64] = [:]
    /// Monotonic generation for all customer-scoped feature state. Unlike the
    /// per-feature counters, this is never reset, so A -> B -> A cannot make an
    /// old request look current again.
    private var stateGeneration: UInt64 = 0
    /// Revision of the value actually committed for a concrete feature/entity
    /// key. Merely starting a newer request advances the feature revision, but
    /// must not make an older completed request return stale profile data.
    private var committedCacheRevisions: [FeatureCacheKey: UInt64] = [:]
    /// Identity that owns every in-memory cache above. IdentityService changes
    /// synchronously, while the broader user-transition fan-out is
    /// asynchronous, so every FeatureService boundary validates this scope
    /// before reading or mutating access.
    private var cacheDistinctId: String

    // Constructor-injected collaborators (Phase 4c composition root).
    private let api: FeatureChecking
    private let identityService: IdentityServiceProtocol
    private let profileService: ProfileServiceProtocol
    private let dateProvider: DateProviderProtocol
    private let realTimeCacheTTL: TimeInterval
    private let featureInfo: FeatureInfo
    private let localPurchaseAccessStore: LocalPurchaseAccessStoreProtocol?

    // MARK: - Init

    init(
        api: FeatureChecking,
        identity: IdentityServiceProtocol,
        profile: ProfileServiceProtocol,
        dateProvider: DateProviderProtocol,
        featureInfo: FeatureInfo,
        cacheTTL: TimeInterval,
        localPurchaseAccessStore: LocalPurchaseAccessStoreProtocol? = nil
    ) {
        self.api = api
        self.identityService = identity
        self.profileService = profile
        self.dateProvider = dateProvider
        self.featureInfo = featureInfo
        self.realTimeCacheTTL = cacheTTL
        self.localPurchaseAccessStore = localPurchaseAccessStore
        self.cacheDistinctId = identity.getDistinctId()
    }

    // MARK: - Public Methods

    /// Get cached feature access (instant, non-blocking)
    /// First checks fresh overrides, then falls back to the profile snapshot.
    func getCached(featureId: String, entityId: String?) async -> FeatureAccess? {
        await getCached(featureId: featureId, requiredBalance: nil, entityId: entityId)
    }

    private func getCached(
        featureId: String,
        requiredBalance: Double?,
        entityId: String?
    ) async -> FeatureAccess? {
        await synchronizeCustomerScopeIfNeeded()
        hydrateDurableRevocationsIfNeeded()
        let cacheKey = makeCacheKey(featureId: featureId, entityId: entityId)
        if let revoked = revokedPurchaseCache[cacheKey] {
            return revoked.access(requiredBalance: requiredBalance)
        }
        if let local = localPurchaseCache[cacheKey] {
            return local.access(requiredBalance: requiredBalance)
        }
        if let cached = realTimeCache[cacheKey] {
            let age = dateProvider.timeIntervalSince(cached.cachedAt)
            if age < realTimeCacheTTL {
                return cached.override.access(requiredBalance: requiredBalance)
            }
        }
        let distinctId = identityService.getDistinctId()

        // Fall back to the profile cache (features from profile response)
        if let profile = await profileService.getCachedProfile(distinctId: distinctId),
           let features = profile.features,
           let feature = features.first(where: { $0.id == featureId }) {
            // For entity-based features, check entity balance
            if let entityId = entityId, let entities = feature.entities {
                if let entityBalance = entities[entityId] {
                    return FeatureAccess(
                        from: Feature(
                            id: feature.id,
                            type: feature.type,
                            balance: entityBalance.balance,
                            unlimited: feature.unlimited,
                            nextResetAt: feature.nextResetAt,
                            interval: feature.interval,
                            entities: nil
                        )
                    )
                }
                // Entity not in cache - return denied instead of nil
                // This allows callers to distinguish "feature exists but entity denied"
                // from "not cached at all"
                return FeatureAccess.notFound
            }
            return FeatureAccess(from: feature)
        }

        return nil
    }

    /// Returns only a value committed after startup by a purchase or real-time
    /// check. Profile snapshots are deliberately excluded: they may predate
    /// the request that just completed.
    private func getCommittedCached(
        featureId: String,
        requiredBalance: Double?,
        entityId: String?
    ) -> FeatureAccess? {
        let cacheKey = makeCacheKey(featureId: featureId, entityId: entityId)
        if let revoked = revokedPurchaseCache[cacheKey] {
            return revoked.access(requiredBalance: requiredBalance)
        }
        if let local = localPurchaseCache[cacheKey] {
            return local.access(requiredBalance: requiredBalance)
        }
        if let cached = realTimeCache[cacheKey],
           dateProvider.timeIntervalSince(cached.cachedAt) < realTimeCacheTTL {
            return cached.override.access(requiredBalance: requiredBalance)
        }
        return nil
    }

    /// Returns an opaque transitive-credit snapshot only when the caller asks
    /// the exact quantity the server evaluated. A different quantity must go
    /// back to the server because wallet units cannot be converted here.
    private func getExactOpaqueCached(
        featureId: String,
        requiredBalance: Double?,
        entityId: String?
    ) -> FeatureAccess? {
        let cacheKey = makeCacheKey(featureId: featureId, entityId: entityId)
        guard revokedPurchaseCache[cacheKey] == nil,
              localPurchaseCache[cacheKey] == nil,
              let cached = realTimeCache[cacheKey],
              dateProvider.timeIntervalSince(cached.cachedAt) < realTimeCacheTTL,
              cached.override.isExactOpaqueSnapshot(
                  requiredBalance: requiredBalance
              ) else {
            return nil
        }
        return cached.override.access(requiredBalance: requiredBalance)
    }

    /// Get all cached features from profile
    func getAllCached() async -> [String: FeatureAccess] {
        await synchronizeCustomerScopeIfNeeded()
        hydrateDurableRevocationsIfNeeded()
        let distinctId = identityService.getDistinctId()
        var result: [String: FeatureAccess] = [:]
        if let profile = await profileService.getCachedProfile(distinctId: distinctId),
           let features = profile.features {
            for feature in features {
                result[feature.id] = FeatureAccess(from: feature)
            }
        }

        let now = dateProvider.now()
        for (cacheKey, cached) in realTimeCache {
            guard cacheKey.entityId == nil else { continue }
            let age = now.timeIntervalSince(cached.cachedAt)
            guard age < realTimeCacheTTL else { continue }
            result[cacheKey.featureId] = cached.override.publishedAccess()
        }
        // A verified purchase is newer than any pre-paywall profile or
        // real-time denial. A later server response explicitly reconciles and
        // removes this projection before writing its own value.
        for (cacheKey, local) in localPurchaseCache {
            guard cacheKey.entityId == nil else { continue }
            result[cacheKey.featureId] = local.access(requiredBalance: nil)
        }
        for (cacheKey, revoked) in revokedPurchaseCache {
            guard cacheKey.entityId == nil else { continue }
            result[cacheKey.featureId] = revoked.access(requiredBalance: nil)
        }
        return result
    }

    /// Check feature via real-time API (always fresh)
    func check(
        featureId: String,
        requiredBalance: Double? = nil,
        entityId: String? = nil
    ) async throws -> FeatureCheckResult {
        let checked = try await performCheck(
            featureId: featureId,
            requiredBalance: requiredBalance,
            entityId: entityId
        )
        let cacheKey = makeCacheKey(featureId: featureId, entityId: entityId)
        if let committedRevision = committedCacheRevisions[cacheKey],
           committedRevision > checked.requestRevision {
            // The remote response completed after a purchase, revocation, or
            // newer request committed. Returning it would contradict the
            // access state the SDK has already published.
            throw CancellationError()
        }
        return checked.result
    }

    private func performCheck(
        featureId: String,
        requiredBalance: Double?,
        entityId: String?
    ) async throws -> (result: FeatureCheckResult, requestRevision: UInt64) {
        await synchronizeCustomerScopeIfNeeded()
        hydrateDurableRevocationsIfNeeded()
        let customerId = identityService.getDistinctId()
        let requestGeneration = stateGeneration
        featureMutationRevisions[featureId, default: 0] &+= 1
        let requestRevision = featureMutationRevisions[featureId, default: 0]

        let result = try await api.checkFeature(
            customerId: customerId,
            featureId: featureId,
            requiredBalance: requiredBalance,
            entityId: entityId
        )

        // A response belongs only to the identity that initiated it. Returning
        // customer A's access after identify/reset would expose that access to
        // customer B even if the shared cache correctly rejected the write.
        guard identityService.getDistinctId() == customerId,
              stateGeneration == requestGeneration else {
            throw CancellationError()
        }

        // A purchase or newer check may have completed while the request was
        // suspended. Return the response to the original caller, but never let
        // stale work mutate the shared access view.
        guard featureMutationRevisions[featureId] == requestRevision else {
            return (result, requestRevision)
        }

        // A credit-system response names its balance source, not necessarily
        // the requested Feature. Keep the requested decision opaque while
        // caching the wallet's units under the wallet key.
        let affectedFeatureIds = Set([featureId, result.featureId])
        if result.featureId != featureId {
            featureMutationRevisions[result.featureId, default: 0] &+= 1
        }
        let requestedOverride = CachedFeatureOverride(
            authoritative: result,
            requestedFeatureId: featureId
        )
        let balanceSourceOverride = CachedFeatureOverride(result: result)
        let featureOverrides = Dictionary(uniqueKeysWithValues:
            affectedFeatureIds.map { affectedFeatureId in
                (
                    affectedFeatureId,
                    affectedFeatureId == featureId
                        ? requestedOverride
                        : balanceSourceOverride
                )
            }
        )
        let allowedFeatureIds = Set(featureOverrides.compactMap { featureId, value in
            value.publishedAccess().allowed ? featureId : nil
        })
        reconcileLocalPurchase(featureIds: affectedFeatureIds)
        if !allowedFeatureIds.isEmpty {
            guard retireDurableRevocations(
                featureIds: allowedFeatureIds,
                distinctId: customerId
            ) else {
                throw CancellationError()
            }
            revokedPurchaseCache = revokedPurchaseCache.filter {
                !allowedFeatureIds.contains($0.key.featureId)
            }
        }
        let cachedAt = dateProvider.now()
        for affectedFeatureId in affectedFeatureIds {
            guard let featureOverride = featureOverrides[affectedFeatureId] else {
                continue
            }
            let cacheKey = makeCacheKey(
                featureId: affectedFeatureId,
                entityId: entityId
            )
            realTimeCache[cacheKey] = (
                override: featureOverride,
                cachedAt: cachedAt
            )
            committedCacheRevisions[cacheKey] =
                featureMutationRevisions[affectedFeatureId]
            await notifyFeatureInfoUpdate(
                featureId: affectedFeatureId,
                access: featureOverride.publishedAccess()
            )
        }

        return (result, requestRevision)
    }

    /// Check feature with cache-first strategy
    func checkWithCache(
        featureId: String,
        requiredBalance: Double? = nil,
        entityId: String? = nil,
        forceRefresh: Bool = false
    ) async throws -> FeatureAccess {
        if !forceRefresh {
            // Try cache first
            if let cached = await getCached(
                featureId: featureId,
                requiredBalance: requiredBalance,
                entityId: entityId
            ) {
                if let opaque = getExactOpaqueCached(
                    featureId: featureId,
                    requiredBalance: requiredBalance,
                    entityId: entityId
                ) {
                    return opaque
                }
                // For boolean features, cache is good enough
                if cached.type == .boolean {
                    return cached
                }

                // For metered features, check if we need to verify balance
                let required = requiredBalance ?? 1
                if cached.unlimited || (cached.balance ?? 0) >= required {
                    return cached
                }

                // Balance might be insufficient, do real-time check
            }
        }

        // No valid cache or force refresh, fetch from network
        let checked = try await performCheck(
            featureId: featureId,
            requiredBalance: requiredBalance,
            entityId: entityId
        )
        let cacheKey = makeCacheKey(featureId: featureId, entityId: entityId)
        if let committedRevision = committedCacheRevisions[cacheKey],
           committedRevision >= checked.requestRevision,
           let cached = getCommittedCached(
               featureId: featureId,
               requiredBalance: requiredBalance,
               entityId: entityId
           ) {
            return cached
        }
        return FeatureAccess(from: checked.result)
    }

    /// Clear all cached data
    func clearCache() async {
        clearCustomerScopedState(
            for: identityService.getDistinctId()
        )
        let info = featureInfo
        await MainActor.run { info.clear() }
        LogInfo("Feature cache cleared")
    }

    /// Handle user identity change
    func handleUserChange(from oldDistinctId: String, to newDistinctId: String) async {
        await clearCache()
        await notifyFeatureInfoUpdate()
        LogInfo("Feature cache cleared due to user change")
    }

    /// Sync FeatureInfo from profile cache (call after profile refresh)
    func syncFeatureInfo() async {
        await notifyFeatureInfoUpdate()
    }

    // MARK: - Private Methods

    private func makeCacheKey(featureId: String, entityId: String?) -> FeatureCacheKey {
        FeatureCacheKey(featureId: featureId, entityId: entityId)
    }

    /// Update FeatureInfo with current cached features (for SwiftUI reactivity)
    private func notifyFeatureInfoUpdate() async {
        let allFeatures = await getAllCached()
        let info = featureInfo
        await MainActor.run {
            info.update(allFeatures)
        }
    }

    /// Update FeatureInfo with a single feature (after real-time check)
    private func notifyFeatureInfoUpdate(featureId: String, access: FeatureAccess) async {
        let info = featureInfo
        await MainActor.run {
            info.update(featureId, access: access)
        }
    }

    /// Update feature cache from purchase response
    /// Called after a successful transaction sync to immediately reflect new entitlements
    func updateFromPurchase(
        _ features: [PurchaseFeature],
        distinctId: String
    ) async {
        await synchronizeCustomerScopeIfNeeded()
        // Transaction sync can cross an actor hop after checking identity.
        // Revalidate here, at the feature-state mutation boundary, and keep
        // durable reconciliation explicitly scoped to the initiating customer.
        guard identityService.getDistinctId() == distinctId else {
            LogDebug("Ignoring purchase feature response for an inactive customer")
            return
        }
        LogInfo("Updating feature cache from purchase response with \(features.count) features")

        // Update FeatureInfo for SwiftUI reactivity
        var accessMap: [String: FeatureAccess] = [:]
        let cachedAt = dateProvider.now()
        let allowedFeatureIds = Set(
            features.filter(\.allowed).map(\.id)
        )
        let retiredAllowedRevocations = retireDurableRevocations(
            featureIds: allowedFeatureIds,
            distinctId: distinctId
        )
        for purchaseFeature in features {
            guard !purchaseFeature.allowed || retiredAllowedRevocations else {
                continue
            }
            featureMutationRevisions[purchaseFeature.id, default: 0] &+= 1
            let access = purchaseFeature.toFeatureAccess
            accessMap[purchaseFeature.id] = access
            let cacheKey = makeCacheKey(featureId: purchaseFeature.id, entityId: nil)
            reconcileLocalPurchase(featureIds: [purchaseFeature.id])
            if purchaseFeature.allowed {
                revokedPurchaseCache = revokedPurchaseCache.filter {
                    $0.key.featureId != purchaseFeature.id
                }
            }
            realTimeCache[cacheKey] = (override: CachedFeatureOverride(purchase: purchaseFeature), cachedAt: cachedAt)
            committedCacheRevisions[cacheKey] = featureMutationRevisions[purchaseFeature.id]
        }

        let updates = accessMap
        let info = featureInfo
        await MainActor.run {
            info.update(updates)
        }

        LogInfo("Feature cache updated from purchase")
    }

    func applyAuthoritativeUse(
        _ result: FeatureCheckResult,
        requestedFeatureId: String,
        distinctId: String,
        entityId: String?
    ) async {
        await synchronizeCustomerScopeIfNeeded()
        guard identityService.getDistinctId() == distinctId else { return }
        let affectedFeatureIds = Set([requestedFeatureId, result.featureId])
        for featureId in affectedFeatureIds {
            featureMutationRevisions[featureId, default: 0] &+= 1
        }
        let requestedOverride = CachedFeatureOverride(
            authoritative: result,
            requestedFeatureId: requestedFeatureId
        )
        let balanceSourceOverride = CachedFeatureOverride(result: result)
        let featureOverrides = Dictionary(uniqueKeysWithValues:
            affectedFeatureIds.map { featureId in
                (
                    featureId,
                    featureId == requestedFeatureId
                        ? requestedOverride
                        : balanceSourceOverride
                )
            }
        )
        let allowedFeatureIds = Set(featureOverrides.compactMap { featureId, value in
            value.publishedAccess().allowed ? featureId : nil
        })
        reconcileLocalPurchase(featureIds: affectedFeatureIds)
        if !allowedFeatureIds.isEmpty {
            guard retireDurableRevocations(
                featureIds: allowedFeatureIds,
                distinctId: distinctId
            ) else { return }
            revokedPurchaseCache = revokedPurchaseCache.filter {
                !allowedFeatureIds.contains($0.key.featureId)
            }
        }
        let cachedAt = dateProvider.now()
        for featureId in affectedFeatureIds {
            guard let featureOverride = featureOverrides[featureId] else {
                continue
            }
            let cacheKey = makeCacheKey(featureId: featureId, entityId: entityId)
            realTimeCache[cacheKey] = (
                override: featureOverride,
                cachedAt: cachedAt
            )
            committedCacheRevisions[cacheKey] = featureMutationRevisions[featureId]
            await notifyFeatureInfoUpdate(
                featureId: featureId,
                access: featureOverride.publishedAccess()
            )
        }
    }

    func applyLocalPurchase(
        grants: [StoreProduct.LocalEntitlementGrant],
        transactionId: String
    ) async {
        await synchronizeCustomerScopeIfNeeded()
        guard !grants.isEmpty else { return }
        guard !localPurchaseTransactions.contains(transactionId) else { return }
        localPurchaseTransactions.insert(transactionId)

        var accessMap: [String: FeatureAccess] = [:]
        for grant in grants {
            let (key, override) = purchaseOverride(for: grant)
            let featureId = key.featureId
            featureMutationRevisions[featureId, default: 0] &+= 1
            realTimeCache = realTimeCache.filter { $0.key.featureId != featureId }
            revokedPurchaseCache.removeValue(forKey: key)
            accessMap[featureId] = override.access(requiredBalance: nil)
            localPurchaseCache[key] = override
            localPurchaseOverrides[transactionId, default: [:]][key] = override
            committedCacheRevisions[key] = featureMutationRevisions[featureId]
        }
        guard !accessMap.isEmpty else { return }
        let updates = accessMap
        let info = featureInfo
        await MainActor.run { info.update(updates) }
    }

    func removeLocalPurchase(
        transactionId: String,
        grants: [StoreProduct.LocalEntitlementGrant] = []
    ) async {
        await synchronizeCustomerScopeIfNeeded()
        localPurchaseTransactions.remove(transactionId)
        let removedOverrides = localPurchaseOverrides.removeValue(
            forKey: transactionId
        ) ?? [:]
        var affectedOverrides = removedOverrides
        for grant in grants {
            let (key, override) = purchaseOverride(for: grant)
            affectedOverrides[key] = override
        }
        guard !affectedOverrides.isEmpty else { return }

        // Older in-process projections may also exist in the short-lived
        // real-time cache. A server response reconciles the local transaction
        // before writing its own entry, so a still-owned key is safe to clear
        // as part of revocation.
        for key in affectedOverrides.keys {
            featureMutationRevisions[key.featureId, default: 0] &+= 1
            realTimeCache.removeValue(forKey: key)
        }

        localPurchaseCache.removeAll()
        for overrides in localPurchaseOverrides.values {
            for (key, override) in overrides {
                localPurchaseCache[key] = override
            }
        }
        for (key, removed) in affectedOverrides where localPurchaseCache[key] == nil {
            revokedPurchaseCache[key] = CachedFeatureOverride(
                type: removed.type,
                unlimited: false,
                balance: removed.type == .boolean ? nil : 0,
                allowed: false
            )
            committedCacheRevisions[key] = featureMutationRevisions[key.featureId]
        }

        let allFeatures = await getAllCached()
        let info = featureInfo
        await MainActor.run { info.update(allFeatures) }
    }

    private func purchaseOverride(
        for grant: StoreProduct.LocalEntitlementGrant
    ) -> (FeatureCacheKey, CachedFeatureOverride) {
        let featureId = grant.featureExternalId ?? grant.featureId
        let allowanceType = grant.allowanceType?.lowercased()
        let unlimited = allowanceType == "unlimited"
        // Boolean entitlements are represented by a null allowance type in
        // signed Product mappings. Both forms mean simple local access.
        let isBoolean = allowanceType == nil || allowanceType == "boolean"
        let featureType: FeatureType = allowanceType == "credits"
            || allowanceType == "credit_system"
            ? .creditSystem
            : (isBoolean ? .boolean : .metered)
        let balance: Double? = isBoolean || unlimited
            ? nil
            : (grant.allowance ?? 0)
        return (
            makeCacheKey(featureId: featureId, entityId: nil),
            CachedFeatureOverride(
                type: featureType,
                unlimited: unlimited,
                balance: balance,
                allowed: isBoolean || unlimited || (balance ?? 0) > 0
            )
        )
    }

    /// Fail closed as soon as the synchronous identity store changes, rather
    /// than waiting for the serialized profile/segment/Journey transition to
    /// reach FeatureService. This makes an immediate cache-first read for the
    /// new customer safe.
    private func synchronizeCustomerScopeIfNeeded() async {
        let distinctId = identityService.getDistinctId()
        guard cacheDistinctId != distinctId else { return }
        clearCustomerScopedState(for: distinctId)
        let info = featureInfo
        await MainActor.run { info.clear() }
    }

    private func clearCustomerScopedState(for distinctId: String) {
        stateGeneration &+= 1
        realTimeCache.removeAll()
        localPurchaseCache.removeAll()
        revokedPurchaseCache.removeAll()
        localPurchaseTransactions.removeAll()
        localPurchaseOverrides.removeAll()
        durableAccessHydratedDistinctId = nil
        featureMutationRevisions.removeAll()
        committedCacheRevisions.removeAll()
        cacheDistinctId = distinctId
    }

    private func hydrateDurableRevocationsIfNeeded() {
        guard let localPurchaseAccessStore else { return }
        let distinctId = identityService.getDistinctId()
        guard durableAccessHydratedDistinctId != distinctId else { return }

        let accesses = localPurchaseAccessStore.load().values.filter {
            $0.distinctId == distinctId
        }
        let activeFeatureIds = Set(
            accesses
                .filter { $0.state == .active }
                .flatMap(\.grants)
                .map { $0.featureExternalId ?? $0.featureId }
        )
        for access in accesses where access.state == .revoked {
            for storedGrant in access.grants {
                let featureId = storedGrant.featureExternalId
                    ?? storedGrant.featureId
                guard !activeFeatureIds.contains(featureId) else { continue }
                let grant = StoreProduct.LocalEntitlementGrant(
                    featureId: storedGrant.featureId,
                    featureExternalId: storedGrant.featureExternalId,
                    allowanceType: storedGrant.allowanceType,
                    allowance: storedGrant.allowance
                )
                let (key, removed) = purchaseOverride(for: grant)
                revokedPurchaseCache[key] = CachedFeatureOverride(
                    type: removed.type,
                    unlimited: false,
                    balance: removed.type == .boolean ? nil : 0,
                    allowed: false
                )
            }
        }
        durableAccessHydratedDistinctId = distinctId
    }

    private func retireDurableRevocations(
        featureIds: Set<String>,
        distinctId: String
    ) -> Bool {
        guard !featureIds.isEmpty, let localPurchaseAccessStore else {
            return true
        }
        return localPurchaseAccessStore.removeRevokedGrants(
            distinctId: distinctId,
            featureIds: featureIds
        )
    }

    /// Remove only optimistic purchase projections covered by a newer server
    /// response. Server/profile caches remain authoritative and are not
    /// deleted when an older local purchase is revoked or reconciled.
    private func reconcileLocalPurchase(featureIds: Set<String>) {
        guard !featureIds.isEmpty else { return }
        for transactionId in Array(localPurchaseOverrides.keys) {
            guard let overrides = localPurchaseOverrides[transactionId] else { continue }
            let remaining = overrides.filter {
                !featureIds.contains($0.key.featureId)
            }
            if remaining.isEmpty {
                localPurchaseOverrides.removeValue(forKey: transactionId)
                localPurchaseTransactions.remove(transactionId)
            } else {
                localPurchaseOverrides[transactionId] = remaining
            }
        }
        localPurchaseCache = localPurchaseOverrides.values.reduce(into: [:]) { result, overrides in
            for (key, override) in overrides {
                result[key] = override
            }
        }
    }
}
