import Foundation

/// Protocol defining the ProfileService interface
protocol ProfileServiceProtocol: AnyObject, Sendable {
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

    func setJourneyMailboxHandler(
        _ handler: (@Sendable ([JourneyMailboxEntry], String) async -> Void)?
    ) async
}

extension ProfileServiceProtocol {
    func setJourneyMailboxHandler(
        _ handler: (@Sendable ([JourneyMailboxEntry], String) async -> Void)?
    ) async {}

    /// Refetch for the current user.
    @discardableResult
    func refetchProfile() async throws -> ProfileResponse {
        try await refetchProfile(distinctId: nil)
    }
}

/// Wrapper for cached profile data with metadata
public struct CachedProfile: Codable, Sendable {
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

/// Profile manager for user profile data with memory-first caching and disk backup.
/// Profile execution fields follow `nuxie-dev/specs/experience-execution-model-spec.md`.
internal actor ProfileService: ProfileServiceProtocol {

    // MARK: - Properties

    // Memory cache for instant access
    private var cachedProfile: CachedProfile?
    
    // Disk cache for persistence
    private let diskCache: any CachedProfileStore
    
    // Background refresh timer
    private var refreshTimer: Task<Void, Never>?
    private var nextProfileGeneration: UInt64 = 0
    private var latestAppliedGeneration: UInt64 = 0
    private var journeyMailboxHandler:
        (@Sendable ([JourneyMailboxEntry], String) async -> Void)?
    private var mailboxRefreshInFlight = false

    /// The startup disk-cache load. `getCachedProfile` awaits it on a memory
    /// miss so init-time readers (JourneyService.initialize resuming an
    /// expired-while-dead timer) cannot race the disk load, observe a nil
    /// profile, and cancel a perfectly restorable journey.
    ///
    /// The task is started lazily on the actor (init only schedules a hop via
    /// `awaitInitialDiskLoad`) so the nonisolated initializer never touches
    /// actor state after `self` escapes — a Swift 6 isolation error.
    private var initialDiskLoadTask: Task<Void, Never>?
    private var initialDiskLoadDone = false
    /// False when disk-cache setup failed and there is nothing to load.
    private let initialDiskLoadNeeded: Bool

    /// Starts (first caller) and awaits the one-shot startup disk load.
    private func awaitInitialDiskLoad() async {
        guard initialDiskLoadNeeded, !initialDiskLoadDone else { return }
        if initialDiskLoadTask == nil {
            initialDiskLoadTask = Task { [weak self] in
                await self?.loadFromDisk()
            }
        }
        await initialDiskLoadTask?.value
        initialDiskLoadDone = true
        initialDiskLoadTask = nil
    }

    // Constructor-injected collaborators (Phase 4c composition root).
    // Note: journeyService stays lazily resolved in resumeActiveJourneys to
    // avoid the JourneyService → ProfileService → JourneyService cycle until
    // the final 4c slice.
    private let identityService: IdentityServiceProtocol
    private let api: ProfileFetching
    private let segmentService: SegmentServiceProtocol
    private let experienceService: ExperienceServiceProtocol
    private let eventLog: ProfileEventSink
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
        api: ProfileFetching,
        segments: SegmentServiceProtocol,
        experiences: ExperienceServiceProtocol,
        eventLog: ProfileEventSink,
        dateProvider: DateProviderProtocol,
        sleepProvider: SleepProviderProtocol,
        customStoragePath: URL? = nil
    ) {
        self.identityService = identity
        self.api = api
        self.segmentService = segments
        self.experienceService = experiences
        self.eventLog = eventLog
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
            self.initialDiskLoadNeeded = true
        } catch {
            LogWarning("Failed to initialize DiskCache<CachedProfile>: \(error)")
            self.diskCache = FallbackCachedProfileStore()
            self.initialDiskLoadNeeded = false
        }

        // Kick off the startup disk load eagerly; idempotent with the lazy
        // start in getCachedProfile.
        Task { [weak self] in
            await self?.awaitInitialDiskLoad()
        }
    }
    
    // Test initializer
    internal init(
        cache: any CachedProfileStore,
        identity: IdentityServiceProtocol,
        api: ProfileFetching,
        segments: SegmentServiceProtocol,
        experiences: ExperienceServiceProtocol,
        eventLog: ProfileEventSink,
        dateProvider: DateProviderProtocol,
        sleepProvider: SleepProviderProtocol
    ) {
        self.identityService = identity
        self.api = api
        self.segmentService = segments
        self.experienceService = experiences
        self.eventLog = eventLog
        self.dateProvider = dateProvider
        self.sleepProvider = sleepProvider
        self.diskCache = cache
        self.initialDiskLoadNeeded = true

        // Kick off the startup disk load eagerly; idempotent with the lazy
        // start in getCachedProfile.
        Task { [weak self] in
            await self?.awaitInitialDiskLoad()
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
            await experienceService.registerExperiences(
                cached.response.deliveredVersions,
                assetBaseURL: cached.response.assetBaseUrl
            )
            self.cachedProfile = cached
            LogDebug("Loaded profile from disk (age: \(Int(cached.cachedAt.timeIntervalSinceNow * -1 / 60))m)")

            await handleProfileUpdate(
                cached.response,
                for: distinctId,
                previousProfile: nil,
                generation: 0
            )

            // Periodic background refresh keeps the cache warm.
            startRefreshTimer()
        }
    }

    /// Refresh profile from network
    private func refreshProfile(distinctId: String) async throws -> ProfileResponse {
        do {
            let locale = effectiveLocale
            let previousProfile = cachedProfileForDistinctId(distinctId)?.response
            let generation = beginProfileRequest()
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
            guard claimProfileGeneration(generation) else {
                LogDebug("Discarding stale profile generation \(generation)")
                return fresh
            }

            LogInfo("Network fetch succeeded; updating cache (locale: \(locale))")
            await updateCache(profile: fresh, distinctId: distinctId)
            await handleProfileUpdate(
                fresh,
                for: distinctId,
                previousProfile: previousProfile,
                generation: generation
            )
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

        await experienceService.registerExperiences(
            profile.deliveredVersions,
            assetBaseURL: profile.assetBaseUrl
        )
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
                let distinctId = self.identityService.getDistinctId()
                await self.refreshInBackground(distinctId: distinctId)
            }
        }
    }

    // MARK: - Cache management API

    func getCachedProfile(distinctId: String) async -> ProfileResponse? {
        // Memory miss: make sure the startup disk load finished before
        // reporting "no cached profile" — early callers (journey restore
        // during SDK initialize) would otherwise race the disk read.
        if cachedProfileForDistinctId(distinctId) == nil {
            await awaitInitialDiskLoad()
        }

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

    func setJourneyMailboxHandler(
        _ handler: (@Sendable ([JourneyMailboxEntry], String) async -> Void)?
    ) async {
        journeyMailboxHandler = handler
        await installMailboxPendingHandler()
    }

    private func refreshMailboxImmediately() async {
        guard !mailboxRefreshInFlight else { return }
        mailboxRefreshInFlight = true
        defer { mailboxRefreshInFlight = false }
        do {
            _ = try await refreshProfile(
                distinctId: identityService.getDistinctId()
            )
        } catch {
            LogWarning("Immediate mailbox profile refresh failed: \(error)")
        }
    }

    private func installMailboxPendingHandler() async {
        await eventLog.setMailboxPendingHandler { [weak self] in
            await self?.refreshMailboxImmediately()
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

        await experienceService.clearCache()
        
        // Try to load new user's cache from disk
        if let cached = await diskCache.retrieve(forKey: newDistinctId, allowStale: true) {
            await experienceService.registerExperiences(
                cached.response.deliveredVersions,
                assetBaseURL: cached.response.assetBaseUrl
            )
            self.cachedProfile = cached
            LogDebug("Loaded new user's profile from disk")

            let generation = beginProfileRequest()
            _ = claimProfileGeneration(generation)
            await handleProfileUpdate(
                cached.response,
                for: newDistinctId,
                previousProfile: nil,
                generation: generation
            )
            
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
        previousProfile: ProfileResponse?,
        generation: UInt64
    ) async {
        
        // Update user properties from server if present
        if let userProps = profile.userProperties {
            var propsDict: [String: Any] = [:]
            for (k, v) in userProps { propsDict[k] = v.value }
            identityService.setUserProperties(propsDict)
            LogInfo("Updated \(propsDict.count) user properties from server")
        }
        
        // Definitions and membership seed are one generation-stamped server snapshot.
        await segmentService.updateSegments(profile.segments, for: distinctId)
        _ = await segmentService.applySeed(
            profile.segmentMemberships,
            generation: generation,
            distinctId: distinctId
        )
        LogInfo("Applied \(profile.segments.count) server segment definitions for user \(NuxieLogger.shared.logDistinctID(distinctId))")

        if let facts = profile.facts, !facts.isEmpty {
            await eventLog.commitServerFacts(facts, distinctId: distinctId)
        }

        await syncExperiences(
            newExperiences: profile.deliveredVersions,
            previousExperiences: previousProfile?.deliveredVersions,
            assetBaseURL: profile.assetBaseUrl,
            previousAssetBaseURL: previousProfile?.assetBaseUrl
        )

        if let mailbox = profile.mailbox, !mailbox.isEmpty {
            await journeyMailboxHandler?(mailbox, distinctId)
        }
    }

    private func beginProfileRequest() -> UInt64 {
        nextProfileGeneration &+= 1
        return nextProfileGeneration
    }

    private func claimProfileGeneration(_ generation: UInt64) -> Bool {
        guard generation >= latestAppliedGeneration else { return false }
        latestAppliedGeneration = generation
        return true
    }

    private func syncExperiences(
        newExperiences: [RemoteExperience],
        previousExperiences: [RemoteExperience]?,
        assetBaseURL: String,
        previousAssetBaseURL: String?
    ) async {
        let previousExperiences = previousExperiences ?? []
        let previousById = Dictionary(
            uniqueKeysWithValues: previousExperiences.map { ($0.versionId, $0) }
        )
        let nextById = Dictionary(
            uniqueKeysWithValues: newExperiences.map { ($0.versionId, $0) }
        )

        var versionIdsToRemove = Set<String>()
        if let previousAssetBaseURL, previousAssetBaseURL != assetBaseURL {
            versionIdsToRemove.formUnion(newExperiences.map(\.versionId))
        }

        for experience in newExperiences {
            if let previous = previousById[experience.versionId] {
                if Self.shouldRefreshCachedExperience(
                    previous: previous,
                    next: experience
                ) {
                    versionIdsToRemove.insert(experience.versionId)
                }
            }
        }

        for previous in previousExperiences where nextById[previous.versionId] == nil {
            versionIdsToRemove.insert(previous.versionId)
        }

        if !versionIdsToRemove.isEmpty {
            await experienceService.removeExperiences(Array(versionIdsToRemove))
        }

        await experienceService.retainPackages(for: newExperiences)
        await experienceService.prefetchExperiences(
            newExperiences,
            assetBaseURL: assetBaseURL
        )
    }

    static func shouldRefreshCachedExperience(
        previous: RemoteExperience,
        next: RemoteExperience
    ) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let previousData = try? encoder.encode(previous),
              let nextData = try? encoder.encode(next) else {
            return true
        }
        return previousData != nextData
    }
}
