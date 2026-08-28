import Foundation

/// Internal control-flow error used when an identity transition makes an
/// in-flight profile response obsolete. This is not a configuration failure.
struct ProfileRefreshCancellationError: LocalizedError, Sendable {
    var errorDescription: String? {
        "Stale profile fetch discarded because the active user changed"
    }
}

/// Protocol defining the ProfileService interface
protocol ProfileServiceProtocol: AnyObject, Sendable {
    /// Get cached profile if available and valid
    func getCachedProfile(distinctId: String) async -> ProfileResponse?

    /// Authenticated identities available for routing. Behavior is loaded
    /// through ExperienceService and never projected through legacy delivery.
    func getEffectiveExperienceReferences(
        distinctId: String
    ) async -> [ExperienceReference]?

    /// References eligible for new enrollment. Pinned releases remain
    /// available through the effective catalog for exact restore/mailbox
    /// lookup, but never participate in trigger scans.
    func getActiveExperienceReferences(
        distinctId: String
    ) async -> [ExperienceReference]?

    /// One atomically published generation for trigger routing.
    func getTriggerAdmission(
        distinctId: String
    ) async -> ProfileTriggerAdmission?

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
    func getEffectiveExperienceReferences(
        distinctId: String
    ) async -> [ExperienceReference]? {
        nil
    }
    func getActiveExperienceReferences(
        distinctId: String
    ) async -> [ExperienceReference]? {
        nil
    }
    func getTriggerAdmission(
        distinctId: String
    ) async -> ProfileTriggerAdmission? {
        _ = distinctId
        return nil
    }
    func setJourneyMailboxHandler(
        _ handler: (@Sendable ([JourneyMailboxEntry], String) async -> Void)?
    ) async {}

    /// Refetch for the current user.
    @discardableResult
    func refetchProfile() async throws -> ProfileResponse {
        try await refetchProfile(distinctId: nil)
    }
}

struct ProfileTriggerAdmission: Sendable {
    let effectiveExperienceReferences: [ExperienceReference]
    let activeExperienceReferences: [ExperienceReference]
    let userProperties: [String: AnyCodable]
    let segmentMemberships: SegmentMembershipSeed
    let routingCatalog: ExperienceRoutingCatalog
}

/// Wrapper for cached profile data with metadata
struct CachedProfile: Codable, Sendable {
    public let response: ProfileResponse
    public let distinctId: String
    public let cachedAt: Date
    public let validator: ProfileCacheValidator?
    public let locale: String?
    
    public init(
        response: ProfileResponse,
        distinctId: String,
        cachedAt: Date,
        validator: ProfileCacheValidator? = nil,
        locale: String? = nil
    ) {
        self.response = response
        self.distinctId = distinctId
        self.cachedAt = cachedAt
        self.validator = validator
        self.locale = locale
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
    /// Nil means no complete catalog generation has been admitted yet. An
    /// admitted empty catalog is represented by a non-nil snapshot whose
    /// reference arrays are empty; durable commerce recovery depends on that
    /// distinction.
    private var triggerAdmission: ProfileTriggerAdmission?
    
    // Disk cache for persistence
    private let diskCache: any CachedProfileStore
    
    // Background refresh timer
    private var refreshTimer: Task<Void, Never>?
    private var nextProfileGeneration: UInt64 = 0
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
    private let localeProvider: LocaleIdentifierProviding

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
        localeProvider: LocaleIdentifierProviding,
        customStoragePath: URL? = nil
    ) {
        self.identityService = identity
        self.api = api
        self.segmentService = segments
        self.experienceService = experiences
        self.eventLog = eventLog
        self.dateProvider = dateProvider
        self.sleepProvider = sleepProvider
        self.localeProvider = localeProvider
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
        sleepProvider: SleepProviderProtocol,
        localeProvider: LocaleIdentifierProviding
    ) {
        self.identityService = identity
        self.api = api
        self.segmentService = segments
        self.experienceService = experiences
        self.eventLog = eventLog
        self.dateProvider = dateProvider
        self.sleepProvider = sleepProvider
        self.localeProvider = localeProvider
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
    private var effectiveLocale: String { localeProvider.localeIdentifier() }

    private func activeReferences(
        in profile: ProfileResponse,
        authenticated: [ExperienceReference]?
    ) -> [ExperienceReference] {
        guard let authenticated else { return [] }
        let activeRoutes = Set(
            (profile.releases?.active ?? []).map {
                ExperienceReference(
                    experienceId: $0.locator.experienceId,
                    versionId: $0.locator.experienceVersionId
                )
            }
        )
        return authenticated.filter(activeRoutes.contains)
    }

    /// Load profile from disk cache into memory on startup
    private func loadFromDisk() async {
        let distinctId = identityService.getDistinctId()
        let generation = beginProfileRequest()
        if let cached = await diskCache.retrieve(forKey: distinctId, allowStale: true) {
            guard isCurrentAdmission(generation, distinctId: distinctId) else { return }
            guard isFresh(cached) else {
                LogDebug("Discarding expired cached profile before admission")
                await discardInvalidCachedProfileAndRefresh(
                    distinctId: distinctId,
                    generation: generation
                )
                return
            }
            do {
                _ = try await admitProfile(
                    cached,
                    generation: generation,
                    persistToDisk: false
                )
            } catch {
                LogError("Cached release profile authentication failed: \(error)")
                guard isCurrentAdmission(generation, distinctId: distinctId) else { return }
                await discardInvalidCachedProfileAndRefresh(
                    distinctId: distinctId,
                    generation: generation
                )
                return
            }
        }
    }

    /// Refresh profile from network
    private func refreshProfile(distinctId: String) async throws -> ProfileResponse {
        do {
            let locale = effectiveLocale
            let cached = cachedProfileForDistinctId(distinctId)
            let validator = cached?.locale == locale ? cached?.validator : nil
            let generation = beginProfileRequest()
            let result = try await api.fetchProfile(
                for: distinctId,
                locale: locale,
                revalidating: validator
            )

            // Staleness guard: if the user changed while this fetch was in
            // flight, applying it would push the OLD user's properties,
            // segments and journeys onto the NEW user (and clobber their
            // cache). Discard instead — the transition coordinator triggers a
            // fresh fetch for the new user.
            guard identityService.getDistinctId() == distinctId else {
                LogWarning("Discarding stale profile fetch for \(NuxieLogger.shared.logDistinctID(distinctId)) — user changed mid-flight")
                throw ProfileRefreshCancellationError()
            }
            switch result {
            case .modified(let fresh, let nextValidator):
                guard isCurrentAdmission(generation, distinctId: distinctId) else {
                    LogDebug("Discarding stale profile generation \(generation)")
                    return fresh
                }

                LogInfo("Network fetch succeeded; updating cache (locale: \(locale))")
                let admitted = try await admitProfile(
                    CachedProfile(
                        response: fresh,
                        distinctId: distinctId,
                        cachedAt: dateProvider.now(),
                        validator: nextValidator,
                        locale: locale
                    ),
                    generation: generation,
                    persistToDisk: true
                )
                guard admitted else {
                    LogDebug("Discarding stale profile generation \(generation) after authentication")
                    return fresh
                }
                return fresh

            case .notModified:
                guard let validator,
                      let cached = cachedProfileForDistinctId(distinctId),
                      cached.validator == validator,
                      cached.locale == locale else {
                    throw NuxieNetworkError.invalidResponse
                }
                guard isCurrentAdmission(generation, distinctId: distinctId) else {
                    LogDebug("Discarding stale profile generation \(generation)")
                    return cached.response
                }

                let refreshed = CachedProfile(
                    response: cached.response,
                    distinctId: distinctId,
                    cachedAt: dateProvider.now(),
                    validator: validator,
                    locale: locale
                )
                do {
                    try await diskCache.store(refreshed, forKey: distinctId)
                } catch {
                    LogWarning("Failed to revalidate disk cache: \(error)")
                }
                guard isCurrentAdmission(generation, distinctId: distinctId) else {
                    LogDebug("Discarding stale profile generation \(generation) after revalidation")
                    return cached.response
                }
                cachedProfile = refreshed
                startRefreshTimer()
                LogInfo("Cached profile revalidated (locale: \(locale))")
                return refreshed.response
            }
        } catch let error as ProfileRefreshCancellationError {
            throw error
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

    /// An unauthentic signed disk snapshot is not a usable offline fallback.
    /// Remove it before fetching so later startup readers cannot repeatedly
    /// encounter the same poison entry or observe stale release authority.
    private func discardInvalidCachedProfileAndRefresh(
        distinctId: String,
        generation: UInt64
    ) async {
        await diskCache.remove(forKey: distinctId)
        guard isCurrentAdmission(generation, distinctId: distinctId) else { return }
        cachedProfile = nil
        triggerAdmission = nil
        let clearedReleases = try? await experienceService.prepareReleaseProfile(nil)
        guard isCurrentAdmission(generation, distinctId: distinctId) else { return }
        if let clearedReleases {
            _ = try? await experienceService.commitReleaseProfile(
                clearedReleases,
                generation: generation
            )
        }
        guard isCurrentAdmission(generation, distinctId: distinctId) else { return }
        _ = await segmentService.replaceSnapshot(
            .empty,
            definitions: [],
            for: distinctId,
            profileGeneration: generation
        )
        guard isCurrentAdmission(generation, distinctId: distinctId) else { return }
        await refreshInBackground(distinctId: distinctId)
    }

    /// Stages every suspending dependency before publishing the in-memory
    /// profile. Generation-stamped collaborators reject late older commits;
    /// the final synchronous block is the sole observable admission point.
    private func admitProfile(
        _ item: CachedProfile,
        generation: UInt64,
        persistToDisk: Bool
    ) async throws -> Bool {
        let profile = item.response
        let distinctId = item.distinctId
        guard isCurrentAdmission(generation, distinctId: distinctId) else { return false }

        let prepared = try await experienceService.prepareReleaseProfile(profile.releases)
        guard isCurrentAdmission(generation, distinctId: distinctId) else { return false }

        if persistToDisk {
            do {
                try await diskCache.store(item, forKey: distinctId)
                LogDebug("Updated disk cache for \(NuxieLogger.shared.logDistinctID(distinctId))")
            } catch {
                LogWarning("Failed to update disk cache: \(error)")
            }
            guard isCurrentAdmission(generation, distinctId: distinctId) else { return false }
        }

        guard let routingCatalog = try await experienceService.commitReleaseProfile(
            prepared,
            generation: generation
        ) else { return false }
        guard isCurrentAdmission(generation, distinctId: distinctId) else { return false }

        let installedMembership = await segmentService.replaceSnapshot(
            profile.segmentMemberships,
            definitions: profile.segments,
            for: distinctId,
            profileGeneration: generation
        )
        guard installedMembership,
              isCurrentAdmission(generation, distinctId: distinctId) else { return false }

        if let userProps = profile.userProperties {
            let properties = Dictionary(uniqueKeysWithValues: userProps.map { ($0.key, $0.value.value) })
            guard identityService.setUserProperties(
                properties,
                ifCurrentDistinctIdMatches: distinctId
            ) else { return false }
            LogInfo("Updated \(properties.count) user properties from server")
        }

        guard isCurrentAdmission(generation, distinctId: distinctId) else { return false }
        let nextEffective = routingCatalog.references
        let nextActive = activeReferences(
            in: profile,
            authenticated: nextEffective
        )
        triggerAdmission = ProfileTriggerAdmission(
            effectiveExperienceReferences: nextEffective,
            activeExperienceReferences: nextActive,
            userProperties: identityService.getUserProperties().mapValues(AnyCodable.init),
            segmentMemberships: profile.segmentMemberships.filtered(to: profile.segments),
            routingCatalog: routingCatalog
        )
        cachedProfile = item
        LogDebug("Updated memory cache for \(NuxieLogger.shared.logDistinctID(distinctId))")
        LogInfo("Admitted segment membership snapshot for user \(NuxieLogger.shared.logDistinctID(distinctId))")
        startRefreshTimer()

        if let facts = profile.facts, !facts.isEmpty {
            await eventLog.commitServerFacts(facts, distinctId: distinctId)
            guard isCurrentAdmission(generation, distinctId: distinctId) else { return true }
        }
        if let mailbox = profile.mailbox, !mailbox.isEmpty {
            await journeyMailboxHandler?(mailbox, distinctId)
            guard isCurrentAdmission(generation, distinctId: distinctId) else { return true }
        }
        return true
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

    func getEffectiveExperienceReferences(
        distinctId: String
    ) async -> [ExperienceReference]? {
        await awaitInitialDiskLoad()
        guard let cachedProfile,
              cachedProfile.distinctId == distinctId,
              dateProvider.timeIntervalSince(cachedProfile.cachedAt) < cacheTTL else {
            return nil
        }
        return triggerAdmission?.effectiveExperienceReferences
    }

    func getActiveExperienceReferences(
        distinctId: String
    ) async -> [ExperienceReference]? {
        await awaitInitialDiskLoad()
        guard let cachedProfile,
              cachedProfile.distinctId == distinctId,
              dateProvider.timeIntervalSince(cachedProfile.cachedAt) < cacheTTL else {
            return nil
        }
        return triggerAdmission?.activeExperienceReferences
    }

    func getTriggerAdmission(
        distinctId: String
    ) async -> ProfileTriggerAdmission? {
        await awaitInitialDiskLoad()
        guard let cachedProfile,
              cachedProfile.distinctId == distinctId,
              dateProvider.timeIntervalSince(cachedProfile.cachedAt) < cacheTTL else {
            return nil
        }
        return triggerAdmission
    }

    func clearCache(distinctId: String) async {
        _ = beginProfileRequest()
        // Clear memory
        cachedProfile = nil
        triggerAdmission = nil
        
        // Clear disk
        await diskCache.remove(forKey: distinctId)
        
        // Cancel refresh timer
        refreshTimer?.cancel()
        refreshTimer = nil
        
        LogDebug("Cleared cached profile for \(NuxieLogger.shared.logDistinctID(distinctId))")
    }

    func clearAllCache() async {
        _ = beginProfileRequest()
        // Clear memory
        cachedProfile = nil
        triggerAdmission = nil
        
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

        // Let a valid startup snapshot contribute its validator before the
        // network request. Invalid disk state still performs its own recovery
        // through the private refresh path without recursively awaiting this
        // task.
        await awaitInitialDiskLoad()

        // Force revalidation from the network (bypasses cache freshness).
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

        let distinctId = identityService.getDistinctId()
        guard isFresh(cached) else {
            LogDebug("Discarding expired resident profile before refresh")
            let generation = beginProfileRequest()
            await discardInvalidCachedProfileAndRefresh(
                distinctId: distinctId,
                generation: generation
            )
            return
        }
        
        let age = dateProvider.timeIntervalSince(cached.cachedAt)
        if age > 15 * 60 { // 15 minutes
            LogDebug("App became active with stale cache (age: \(Int(age/60))m), refreshing")
            await refreshInBackground(distinctId: distinctId)
        }
    }

    func setJourneyMailboxHandler(
        _ handler: (@Sendable ([JourneyMailboxEntry], String) async -> Void)?
    ) async {
        journeyMailboxHandler = handler
        if handler == nil {
            await eventLog.setMailboxPendingHandler(nil)
        } else {
            await installMailboxPendingHandler()
        }
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
        let generation = beginProfileRequest()

        guard isCurrentAdmission(generation, distinctId: newDistinctId) else { return }
        cachedProfile = nil
        triggerAdmission = nil
        refreshTimer?.cancel()
        refreshTimer = nil

        // Profile admission owns the membership read snapshot. Clear the old identity before
        // attempting disk or network admission for the replacement identity.
        _ = await segmentService.replaceSnapshot(
            .empty,
            definitions: [],
            for: newDistinctId,
            profileGeneration: generation
        )
        guard isCurrentAdmission(generation, distinctId: newDistinctId) else { return }

        // Clear old user's disk cache
        await diskCache.remove(forKey: oldDistinctId)
        guard isCurrentAdmission(generation, distinctId: newDistinctId) else { return }

        let clearedReleases = try? await experienceService.prepareReleaseProfile(nil)
        guard isCurrentAdmission(generation, distinctId: newDistinctId) else { return }
        if let clearedReleases {
            _ = try? await experienceService.commitReleaseProfile(
                clearedReleases,
                generation: generation
            )
        }
        guard isCurrentAdmission(generation, distinctId: newDistinctId) else { return }
        
        // Try to load new user's cache from disk
        if let cached = await diskCache.retrieve(forKey: newDistinctId, allowStale: true) {
            guard isCurrentAdmission(generation, distinctId: newDistinctId) else { return }
            guard isFresh(cached) else {
                LogDebug("Discarding expired cached profile before user-change admission")
                await discardInvalidCachedProfileAndRefresh(
                    distinctId: newDistinctId,
                    generation: generation
                )
                return
            }
            do {
                let admitted = try await admitProfile(
                    cached,
                    generation: generation,
                    persistToDisk: false
                )
                guard admitted else { return }
            } catch {
                LogError("Cached release profile authentication failed: \(error)")
                guard isCurrentAdmission(generation, distinctId: newDistinctId) else { return }
                await discardInvalidCachedProfileAndRefresh(
                    distinctId: newDistinctId,
                    generation: generation
                )
                return
            }
            LogDebug("Loaded new user's profile from disk")
            
            // Refresh if stale
            let age = dateProvider.timeIntervalSince(cached.cachedAt)
            if age > backgroundRefreshAge {
                guard isCurrentAdmission(generation, distinctId: newDistinctId) else { return }
                await refreshInBackground(distinctId: newDistinctId)
            }
        } else {
            guard isCurrentAdmission(generation, distinctId: newDistinctId) else { return }
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

    private func isFresh(_ cached: CachedProfile) -> Bool {
        dateProvider.timeIntervalSince(cached.cachedAt) < cacheTTL
    }
    
    private func beginProfileRequest() -> UInt64 {
        nextProfileGeneration &+= 1
        return nextProfileGeneration
    }

    private func isCurrentAdmission(_ generation: UInt64, distinctId: String) -> Bool {
        generation == nextProfileGeneration
            && identityService.getDistinctId() == distinctId
    }

}
