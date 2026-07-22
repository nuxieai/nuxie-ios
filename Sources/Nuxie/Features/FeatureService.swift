import Foundation

/// Protocol defining the FeatureService interface
public protocol FeatureServiceProtocol: AnyObject, Sendable {
    /// Check feature access from cache (instant, non-blocking)
    func getCached(featureId: String, entityId: String?) async -> FeatureAccess?

    /// Get all cached features from profile
    func getAllCached() async -> [String: FeatureAccess]

    /// Check feature access via real-time API call
    func check(
        featureId: String,
        requiredBalance: Int?,
        entityId: String?
    ) async throws -> FeatureCheckResult

    /// Check feature access with cache-first strategy
    func checkWithCache(
        featureId: String,
        requiredBalance: Int?,
        entityId: String?,
        forceRefresh: Bool
    ) async throws -> FeatureAccess

    /// Clear all feature cache
    func clearCache() async

    /// Handle user identity change
    func handleUserChange(from oldDistinctId: String, to newDistinctId: String) async

    /// Sync FeatureInfo from profile cache (call after profile refresh)
    func syncFeatureInfo() async

    /// Update feature cache from purchase response
    func updateFromPurchase(_ features: [PurchaseFeature]) async
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
        let balance: Int?
        let allowed: Bool

        init(result: FeatureCheckResult) {
            self.type = result.type
            self.unlimited = result.unlimited
            self.balance = result.balance
            self.allowed = result.allowed
        }

        init(purchase: PurchaseFeature) {
            self.type = purchase.type
            self.unlimited = purchase.unlimited
            self.balance = purchase.balance
            self.allowed = purchase.allowed
        }

        func access(requiredBalance: Int?) -> FeatureAccess {
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
    }

    // MARK: - Properties

    // In-memory cache for fresh feature access overrides from real-time checks and purchase syncs.
    // These values are newer than the profile snapshot and should win until they expire.
    private var realTimeCache: [FeatureCacheKey: (override: CachedFeatureOverride, cachedAt: Date)] = [:]

    // Constructor-injected collaborators (Phase 4c composition root).
    // Configuration is a provider, not a value: tests construct this service
    // before registering their configuration, and a re-setup's fresh
    // configuration must be honored.
    private let api: NuxieApiProtocol
    private let identityService: IdentityServiceProtocol
    private let profileService: ProfileServiceProtocol
    private let dateProvider: DateProviderProtocol
    private let configProvider: @Sendable () -> NuxieConfiguration
    private var config: NuxieConfiguration { configProvider() }
    private let featureInfo: FeatureInfo

    // Cache TTL for real-time results (from configuration)
    private var realTimeCacheTTL: TimeInterval {
        config.featureCacheTTL
    }

    // MARK: - Init

    init(
        api: NuxieApiProtocol,
        identity: IdentityServiceProtocol,
        profile: ProfileServiceProtocol,
        dateProvider: DateProviderProtocol,
        featureInfo: FeatureInfo,
        configProvider: @escaping @Sendable () -> NuxieConfiguration
    ) {
        self.api = api
        self.identityService = identity
        self.profileService = profile
        self.dateProvider = dateProvider
        self.featureInfo = featureInfo
        self.configProvider = configProvider
    }

    // MARK: - Public Methods

    /// Get cached feature access (instant, non-blocking)
    /// First checks fresh overrides, then falls back to the profile snapshot.
    func getCached(featureId: String, entityId: String?) async -> FeatureAccess? {
        await getCached(featureId: featureId, requiredBalance: nil, entityId: entityId)
    }

    private func getCached(
        featureId: String,
        requiredBalance: Int?,
        entityId: String?
    ) async -> FeatureAccess? {
        let cacheKey = makeCacheKey(featureId: featureId, entityId: entityId)
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

    /// Get all cached features from profile
    func getAllCached() async -> [String: FeatureAccess] {
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
            result[cacheKey.featureId] = cached.override.access(requiredBalance: nil)
        }
        return result
    }

    /// Check feature via real-time API (always fresh)
    func check(
        featureId: String,
        requiredBalance: Int? = nil,
        entityId: String? = nil
    ) async throws -> FeatureCheckResult {
        let customerId = identityService.getDistinctId()

        let result = try await api.checkFeature(
            customerId: customerId,
            featureId: featureId,
            requiredBalance: requiredBalance,
            entityId: entityId
        )

        // Cache the result
        let cacheKey = makeCacheKey(featureId: featureId, entityId: entityId)
        realTimeCache[cacheKey] = (override: CachedFeatureOverride(result: result), cachedAt: dateProvider.now())

        // Update FeatureInfo for SwiftUI reactivity
        await notifyFeatureInfoUpdate(featureId: featureId, access: FeatureAccess(from: result))

        return result
    }

    /// Check feature with cache-first strategy
    func checkWithCache(
        featureId: String,
        requiredBalance: Int? = nil,
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
        let result = try await check(
            featureId: featureId,
            requiredBalance: requiredBalance,
            entityId: entityId
        )

        return FeatureAccess(from: result)
    }

    /// Clear all cached data
    func clearCache() async {
        realTimeCache.removeAll()
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
    func updateFromPurchase(_ features: [PurchaseFeature]) async {
        LogInfo("Updating feature cache from purchase response with \(features.count) features")

        // Update FeatureInfo for SwiftUI reactivity
        var accessMap: [String: FeatureAccess] = [:]
        let cachedAt = dateProvider.now()
        for purchaseFeature in features {
            let access = purchaseFeature.toFeatureAccess
            accessMap[purchaseFeature.id] = access
            let cacheKey = makeCacheKey(featureId: purchaseFeature.id, entityId: nil)
            realTimeCache[cacheKey] = (override: CachedFeatureOverride(purchase: purchaseFeature), cachedAt: cachedAt)
        }

        let updates = accessMap
        let info = featureInfo
        await MainActor.run {
            info.update(updates)
        }

        LogInfo("Feature cache updated from purchase")
    }
}
