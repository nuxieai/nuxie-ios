import FactoryKit
import Foundation

/// Protocol defining the ProfileService interface
protocol ProfileServiceProtocol: AnyObject {
    /// Get cached profile if available and valid
    func getCachedProfile(distinctId: String) async -> ProfileResponse?

    /// Clear cached profile for user
    func clearCache(distinctId: String) async

    /// Clear all cached profiles
    func clearAllCache() async

    /// Clean up expired profiles
    @discardableResult
    func cleanupExpired() async -> Int

    /// Force-fetch the profile from the network for the given user
    /// (nil = current user), update caches, and apply the response.
    @discardableResult
    func refetchProfile(distinctId: String?) async throws -> ProfileResponse
    
    /// Handle user change - clear old cache and load new
    func handleUserChange(from oldDistinctId: String, to newDistinctId: String) async

    func onAppBecameActive() async
}

extension ProfileServiceProtocol {
    /// Refetch for the current user.
    @discardableResult
    func refetchProfile() async throws -> ProfileResponse {
        try await refetchProfile(distinctId: nil)
    }
}

/// Wrapper for cached profile data with metadata
public struct CachedProfile: Codable {
    public let response: ProfileResponse
    public let distinctId: String
    public let cachedAt: Date
    
    public init(response: ProfileResponse, distinctId: String, cachedAt: Date) {
        self.response = response
        self.distinctId = distinctId
        self.cachedAt = cachedAt
    }
}

/// In-memory fallback used only when the disk cache fails to initialize.
/// (Distinct from NuxieTestSupport.InMemoryCachedProfileStore, the test store.)
private actor FallbackCachedProfileStore: CachedProfileStore {
    private struct Entry {
        let value: CachedProfile
        let storedAt: Date
        let sizeBytes: Int64
    }

    private var storage: [String: Entry] = [:]

    func store(_ item: CachedProfile, forKey key: String) async throws {
        let encoded = try JSONEncoder().encode(item)
        storage[key] = Entry(value: item, storedAt: Date(), sizeBytes: Int64(encoded.count))
    }

    func retrieve(forKey key: String, allowStale: Bool) async -> CachedProfile? {
        storage[key]?.value
    }

    func remove(forKey key: String) async {
        storage.removeValue(forKey: key)
    }

    func clearAll() async {
        storage.removeAll()
    }

    @discardableResult
    func cleanupExpired() async -> Int {
        0
    }

    func getAllKeys() async -> [String] {
        Array(storage.keys)
    }

    func getMetadata(forKey key: String) async -> DiskCacheMetadata? {
        guard let entry = storage[key] else { return nil }
        return DiskCacheMetadata(
            key: key,
            lastModified: entry.storedAt,
            size: entry.sizeBytes,
            age: Date().timeIntervalSince(entry.storedAt)
        )
    }
}

/// Profile manager for user profile data with memory-first caching and disk backup
internal actor ProfileService: ProfileServiceProtocol {

    // MARK: - Properties

    // Memory cache for instant access
    private var cachedProfile: CachedProfile?
    
    // Disk cache for persistence
    private let diskCache: any CachedProfileStore
    
    // Background refresh timer
    private var refreshTimer: Task<Void, Never>?

    // Constructor-injected collaborators (Phase 4c composition root).
    // Note: journeyService stays lazily resolved in resumeActiveJourneys to
    // avoid the JourneyService → ProfileService → JourneyService cycle until
    // the final 4c slice.
    private let identityService: IdentityServiceProtocol
    private let api: NuxieApiProtocol
    private let segmentService: SegmentServiceProtocol
    private let flowService: ExperienceServiceProtocol
    private let dateProvider: DateProviderProtocol
    private let sleepProvider: SleepProviderProtocol

    // Cache policy
    /// Disk/memory cache validity window; also the background-refresh
    /// threshold on user change.
    private let cacheTTL: TimeInterval = 24 * 60 * 60 // 24h
    private let backgroundRefreshAge: TimeInterval = 5 * 60 // 5 min
    private let refreshInterval: TimeInterval = 30 * 60    // 30 min - periodic refresh

    // MARK: - Init

    // Production initializer
    init(
        identity: IdentityServiceProtocol,
        api: NuxieApiProtocol,
        segments: SegmentServiceProtocol,
        flows: ExperienceServiceProtocol,
        dateProvider: DateProviderProtocol,
        sleepProvider: SleepProviderProtocol,
        customStoragePath: URL? = nil
    ) {
        self.identityService = identity
        self.api = api
        self.segmentService = segments
        self.flowService = flows
        self.dateProvider = dateProvider
        self.sleepProvider = sleepProvider
        // Determine the base directory
        let baseDir: URL
        if let customPath = customStoragePath {
            // Use custom path with nuxie subdirectory for profiles
            baseDir = customPath.appendingPathComponent("nuxie", isDirectory: true)
        } else {
            // Use default Caches/nuxie directory for profile cache
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            baseDir = caches.appendingPathComponent("nuxie", isDirectory: true)
        }
        
        let opts = DiskCacheOptions(
            baseDirectory: baseDir,
            subdirectory: "profiles",
            defaultTTL: cacheTTL,
            maxTotalBytes: 10 * 1024 * 1024,  // 10 MB cap (only one profile)
            excludeFromBackup: true,
            fileProtection: .completeUntilFirstUserAuthentication
        )
        do {
            let disk = try DiskCache<CachedProfile>(options: opts)
            self.diskCache = disk
            
            // Load from disk into memory on startup
            Task { [weak self] in
                await self?.loadFromDisk()
            }
        } catch {
            LogWarning("Failed to initialize DiskCache<CachedProfile>: \(error)")
            self.diskCache = FallbackCachedProfileStore()
        }
    }
    
    // Test initializer
    internal init(
        cache: any CachedProfileStore,
        identity: IdentityServiceProtocol = Container.shared.identityService(),
        api: NuxieApiProtocol = Container.shared.nuxieApi(),
        segments: SegmentServiceProtocol = Container.shared.segmentService(),
        flows: ExperienceServiceProtocol = Container.shared.flowService(),
        dateProvider: DateProviderProtocol = Container.shared.dateProvider(),
        sleepProvider: SleepProviderProtocol = Container.shared.sleepProvider()
    ) {
        self.identityService = identity
        self.api = api
        self.segmentService = segments
        self.flowService = flows
        self.dateProvider = dateProvider
        self.sleepProvider = sleepProvider
        self.diskCache = cache
        
        // Load from disk into memory on startup
        Task { [weak self] in
            await self?.loadFromDisk()
        }
    }
    
    deinit {
        refreshTimer?.cancel()
    }

    // MARK: - Cache-first strategy

    // MARK: - Helpers

    /// Get the effective locale to send in profile requests
    /// Uses configured override or device locale
    private var effectiveLocale: String {
        // Check for configured locale override first
        if let overrideLocale = NuxieSDK.shared.configuration?.localeIdentifier {
            return overrideLocale
        }
        // Fall back to device locale
        return Locale.current.identifier
    }

    /// Load profile from disk cache into memory on startup
    private func loadFromDisk() async {
        let distinctId = identityService.getDistinctId()
        if let cached = await diskCache.retrieve(forKey: distinctId, allowStale: true) {
            self.cachedProfile = cached
            LogDebug("Loaded profile from disk (age: \(Int(cached.cachedAt.timeIntervalSinceNow * -1 / 60))m)")

            await syncFlows(newFlows: cached.response.flows, previousFlows: nil)

            // Periodic background refresh keeps the cache warm.
            startRefreshTimer()
        }
    }

    /// Refresh profile from network
    private func refreshProfile(distinctId: String) async throws -> ProfileResponse {
        do {
            let locale = effectiveLocale
            let previousProfile = cachedProfileForDistinctId(distinctId)?.response
            let fresh = try await api.fetchProfile(for: distinctId, locale: locale)

            // Staleness guard: if the user changed while this fetch was in
            // flight, applying it would push the OLD user's properties,
            // segments and journeys onto the NEW user (and clobber their
            // cache). Discard instead — the transition coordinator triggers a
            // fresh fetch for the new user.
            guard identityService.getDistinctId() == distinctId else {
                LogWarning("Discarding stale profile fetch for \(NuxieLogger.shared.logDistinctID(distinctId)) — user changed mid-flight")
                throw NuxieError.invalidConfiguration("stale profile fetch discarded")
            }

            LogInfo("Network fetch succeeded; updating cache (locale: \(locale))")
            await updateCache(profile: fresh, distinctId: distinctId)
            await handleProfileUpdate(fresh, for: distinctId, previousProfile: previousProfile)
            return fresh
        } catch {
            LogError("Network fetch failed: \(error)")
            throw error
        }
    }

    /// Background refresh without throwing
    private func refreshInBackground(distinctId: String) async {
        do {
            _ = try await refreshProfile(distinctId: distinctId)
        } catch {
            LogDebug("Background refresh failed: \(error)")
        }
    }

    /// Update both memory and disk cache (write-through)
    private func updateCache(profile: ProfileResponse, distinctId: String) async {
        let item = CachedProfile(response: profile, distinctId: distinctId, cachedAt: dateProvider.now())
        
        // Update memory immediately
        self.cachedProfile = item
        LogDebug("Updated memory cache for \(NuxieLogger.shared.logDistinctID(distinctId))")
        
        // Write to disk (awaited to keep cache state consistent)
        do {
            try await diskCache.store(item, forKey: distinctId)
            LogDebug("Updated disk cache for \(NuxieLogger.shared.logDistinctID(distinctId))")
        } catch {
            LogWarning("Failed to update disk cache: \(error)")
        }
        
        // Start refresh timer
        startRefreshTimer()
    }

    /// Start or restart the periodic refresh timer
    private func startRefreshTimer() {
        // Cancel existing timer
        refreshTimer?.cancel()
        
        // Start new timer
        refreshTimer = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { return }
                
                // Sleep for the refresh interval
                try? await self.sleepProvider.sleep(for: self.refreshInterval)
                
                guard !Task.isCancelled else { break }
                
                // Perform background refresh
                let distinctId = await self.identityService.getDistinctId()
                await self.refreshInBackground(distinctId: distinctId)
            }
        }
    }

    // MARK: - Cache management API

    func getCachedProfile(distinctId: String) async -> ProfileResponse? {
        // Return from memory if available and not too stale
        if let cached = cachedProfileForDistinctId(distinctId) {
            let age = dateProvider.timeIntervalSince(cached.cachedAt)
            if age < cacheTTL {
                return cached.response
            }
        }
        return nil
    }

    func clearCache(distinctId: String) async {
        // Clear memory
        cachedProfile = nil
        
        // Clear disk
        await diskCache.remove(forKey: distinctId)
        
        // Cancel refresh timer
        refreshTimer?.cancel()
        refreshTimer = nil
        
        LogDebug("Cleared cached profile for \(NuxieLogger.shared.logDistinctID(distinctId))")
    }

    func clearAllCache() async {
        // Clear memory
        cachedProfile = nil
        
        // Clear disk
        await diskCache.clearAll()
        
        // Cancel refresh timer
        refreshTimer?.cancel()
        refreshTimer = nil
        
        LogInfo("Cleared all profile cache")
    }

    @discardableResult
    func cleanupExpired() async -> Int {
        // For memory-first approach, we only need to clean disk cache
        // Memory cache is always current user's profile
        return await diskCache.cleanupExpired()
    }


    // MARK: - Refetch API

    func refetchProfile(distinctId: String?) async throws -> ProfileResponse {
        let resolvedId = distinctId ?? identityService.getDistinctId()

        // Force refresh from network (bypasses cache)
        LogInfo("Force refreshing profile from network")
        return try await refreshProfile(distinctId: resolvedId)
    }
    
    /// Handle app becoming active - refresh if stale
    func onAppBecameActive() async {
        guard let cached = cachedProfile else {
            // No cache, load from disk or fetch
            await loadFromDisk()
            return
        }
        
        let age = dateProvider.timeIntervalSince(cached.cachedAt)
        if age > 15 * 60 { // 15 minutes
            LogDebug("App became active with stale cache (age: \(Int(age/60))m), refreshing")
            let distinctId = identityService.getDistinctId()
            await refreshInBackground(distinctId: distinctId)
        }
    }
    
    /// Handle user change - clear old cache and load new
    func handleUserChange(from oldDistinctId: String, to newDistinctId: String) async {
        LogInfo("User changed from \(NuxieLogger.shared.logDistinctID(oldDistinctId)) to \(NuxieLogger.shared.logDistinctID(newDistinctId))")
        
        // Clear memory cache
        cachedProfile = nil
        
        // Cancel refresh timer
        refreshTimer?.cancel()
        refreshTimer = nil
        
        // Clear old user's disk cache
        await diskCache.remove(forKey: oldDistinctId)

        await flowService.clearCache()
        
        // Try to load new user's cache from disk
        if let cached = await diskCache.retrieve(forKey: newDistinctId, allowStale: true) {
            self.cachedProfile = cached
            LogDebug("Loaded new user's profile from disk")

            await syncFlows(newFlows: cached.response.flows, previousFlows: nil)
            
            // Refresh if stale
            let age = dateProvider.timeIntervalSince(cached.cachedAt)
            if age > backgroundRefreshAge {
                await refreshInBackground(distinctId: newDistinctId)
            }
        } else {
            // No cache for new user, fetch fresh
            await refreshInBackground(distinctId: newDistinctId)
        }
    }

    private func cachedProfileForDistinctId(_ distinctId: String) -> CachedProfile? {
        guard let cached = cachedProfile, cached.distinctId == distinctId else {
            return nil
        }
        return cached
    }
    
    private func handleProfileUpdate(
        _ profile: ProfileResponse,
        for distinctId: String,
        previousProfile: ProfileResponse?
    ) async {
        
        // Update user properties from server if present
        if let userProps = profile.userProperties {
            var propsDict: [String: Any] = [:]
            for (k, v) in userProps { propsDict[k] = v.value }
            identityService.setUserProperties(propsDict)
            LogInfo("Updated \(propsDict.count) user properties from server")
        }
        
        // Update segments with explicit distinctId to prevent races. Always
        // propagate — an empty server list means deletions, and the scoping
        // to campaign-referenced segments happens inside the service.
        await segmentService.updateSegments(
            profile.segments, referencedBy: profile.campaigns, for: distinctId)
        LogInfo("Updated \(profile.segments.count) segment definitions for user \(NuxieLogger.shared.logDistinctID(distinctId))")

        // NOTE: cross-device resume was deleted (it created inert "zombie"
        // journeys whose only effect was blocking re-enrollment). Its designed
        // replacement — ownership/epoch/claim — is specced in the parent
        // repo's specs/hybrid-journey-execution-spec.md (H2).

        await syncFlows(
            newFlows: profile.flows,
            previousFlows: previousProfile?.flows
        )
    }

    private func syncFlows(newFlows: [RemoteFlow], previousFlows: [RemoteFlow]?) async {
        let previousFlows = previousFlows ?? []
        if newFlows.isEmpty && previousFlows.isEmpty { return }

        let previousById = Dictionary(uniqueKeysWithValues: previousFlows.map { ($0.id, $0) })
        let nextById = Dictionary(uniqueKeysWithValues: newFlows.map { ($0.id, $0) })

        var flowsToPrefetch: [RemoteFlow] = []
        var flowIdsToRemove = Set<String>()

        for flow in newFlows {
            if let previous = previousById[flow.id] {
                if Self.shouldRefreshCachedFlow(previous: previous, next: flow) {
                    flowIdsToRemove.insert(flow.id)
                    flowsToPrefetch.append(flow)
                }
            } else {
                flowsToPrefetch.append(flow)
            }
        }

        for previous in previousFlows where nextById[previous.id] == nil {
            flowIdsToRemove.insert(previous.id)
        }

        if !flowIdsToRemove.isEmpty {
            await flowService.removeFlows(Array(flowIdsToRemove))
        }

        if !flowsToPrefetch.isEmpty {
            flowService.prefetchFlows(flowsToPrefetch)
        }
    }

    static func shouldRefreshCachedFlow(previous: RemoteFlow, next: RemoteFlow) -> Bool {
        let previousArtifact = previous.flowArtifact
        let nextArtifact = next.flowArtifact

        return previousArtifact.buildId != nextArtifact.buildId
            || previousArtifact.url != nextArtifact.url
            || previousArtifact.manifest.contentHash != nextArtifact.manifest.contentHash
    }
}
