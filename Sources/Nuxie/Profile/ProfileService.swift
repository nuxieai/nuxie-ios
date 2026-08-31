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

    /// Invalidates in-flight profile admissions after the effective locale
    /// mutates, before the replacing fetch begins.
    func localeDidChange() async

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

    @discardableResult
    func store(
        _ item: CachedProfile,
        forKey key: String,
        admission: ProfileSideEffectAdmission
    ) async throws -> Bool {
        guard admission() else { return false }
        let encoded = try JSONEncoder().encode(item)
        storage[key] = Entry(value: item, storedAt: Date(), sizeBytes: Int64(encoded.count))
        return true
    }

    func retrieve(forKey key: String, allowStale: Bool) async -> CachedProfile? {
        storage[key]?.value
    }

    func remove(forKey key: String) async {
        storage.removeValue(forKey: key)
    }

    @discardableResult
    func remove(
        forKey key: String,
        admission: ProfileSideEffectAdmission
    ) async -> Bool {
        guard admission() else { return false }
        storage.removeValue(forKey: key)
        return true
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

/// Lock-backed because cache actors must validate a generation without hopping
/// back through the reentrant ProfileService actor.
private final class ProfileAdmissionGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var current: UInt64 = 0

    func claim() -> UInt64 {
        lock.withLock {
            current &+= 1
            return current
        }
    }

    func invalidate() {
        _ = claim()
    }

    func matches(_ generation: UInt64) -> Bool {
        lock.withLock { current == generation }
    }
}

/// Profile manager for user profile data with memory-first caching and disk backup.
/// Profile execution fields follow `nuxie-dev/specs/experience-execution-model-spec.md`.
internal actor ProfileService: ProfileServiceProtocol {

    /// Immutable authority claimed before any profile work suspends. Locale is
    /// intentionally re-read by `isCurrentAdmission` because runtime settings
    /// can change without first entering this actor.
    private struct ProfileAdmission: Sendable {
        let distinctId: String
        let generation: UInt64
        let locale: String
    }

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
    private let profileAdmissionGeneration = ProfileAdmissionGeneration()
    private var journeyMailboxHandler:
        (@Sendable ([JourneyMailboxEntry], String) async -> Void)?
    private var mailboxRefreshInFlight = false
    /// Highest admission generation whose customer-scoped portions committed.
    /// A stale request's reduced commit must not land after a NEWER admission
    /// (a replacement fetch under the new locale) already committed.
    private var latestCustomerScopedCommitGeneration: UInt64 = 0

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
        let admission = beginProfileRequest(distinctId: distinctId)
        if let cached = await diskCache.retrieve(forKey: distinctId, allowStale: true) {
            guard isCurrentAdmission(admission) else { return }
            guard cached.locale == admission.locale else {
                LogDebug("Discarding cached profile from a different locale")
                _ = await diskCache.remove(
                    forKey: distinctId,
                    admission: cacheStoreAdmission(for: admission)
                )
                return
            }
            guard isFresh(cached) else {
                LogDebug("Discarding expired cached profile before admission")
                await discardInvalidCachedProfileAndRefresh(
                    admission: admission
                )
                return
            }
            do {
                _ = try await admitProfile(
                    cached,
                    admission: admission,
                    persistToDisk: false
                )
            } catch {
                LogError("Cached release profile authentication failed: \(error)")
                guard isCurrentAdmission(admission) else { return }
                await discardInvalidCachedProfileAndRefresh(
                    admission: admission
                )
                return
            }
        }
    }

    /// Refresh profile from network
    private func refreshProfile(distinctId: String) async throws -> ProfileResponse {
        do {
            let admission = beginProfileRequest(distinctId: distinctId)
            let locale = admission.locale
            let cached = cachedProfileForDistinctId(distinctId)
            let validator = cached?.locale == locale ? cached?.validator : nil
            let result = try await api.fetchProfile(
                for: distinctId,
                locale: locale,
                revalidating: validator
            )

            // Identity changes have a dedicated cancellation contract. The
            // admission checks below additionally reject superseding profile
            // generations and runtime-locale changes.
            guard identityService.getDistinctId() == distinctId else {
                LogWarning("Discarding stale profile fetch for \(NuxieLogger.shared.logDistinctID(distinctId)) — user changed mid-flight")
                throw ProfileRefreshCancellationError()
            }
            switch result {
            case .modified(let fresh, let nextValidator):
                guard isCurrentAdmission(admission) else {
                    LogDebug("Discarding stale profile generation \(admission.generation)")
                    // Customer-scoped payloads are locale-independent: the
                    // same facts, properties, and mailbox work arrive under
                    // any locale and their dedupe is correct, so an identity-
                    // current response still commits them even though its
                    // locale-scoped state is discarded.
                    await commitIdentityScopedPortions(of: fresh, admission: admission)
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
                    admission: admission,
                    persistToDisk: true
                )
                guard admitted else {
                    LogDebug("Discarding stale profile generation \(admission.generation) after authentication")
                    // A locale flip during authentication or a locale-scoped
                    // commit lands here with facts/mailbox not yet reached
                    // inside admitProfile (they run last), so the customer-
                    // scoped portions still commit once, idempotently.
                    await commitIdentityScopedPortions(of: fresh, admission: admission)
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
                guard isCurrentAdmission(admission) else {
                    LogDebug("Discarding stale profile generation \(admission.generation)")
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
                    let stored = try await diskCache.store(
                        refreshed,
                        forKey: distinctId,
                        admission: cacheStoreAdmission(for: admission)
                    )
                    guard stored else {
                        LogDebug("Discarding stale profile cache revalidation")
                        return cached.response
                    }
                } catch {
                    LogWarning("Failed to revalidate disk cache: \(error)")
                }
                guard isCurrentAdmission(admission) else {
                    LogDebug("Discarding stale profile generation \(admission.generation) after revalidation")
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
        admission: ProfileAdmission
    ) async {
        guard isCurrentAdmission(admission) else { return }
        guard await diskCache.remove(
            forKey: admission.distinctId,
            admission: cacheStoreAdmission(for: admission)
        ) else { return }
        guard isCurrentAdmission(admission) else { return }
        cachedProfile = nil
        triggerAdmission = nil
        let clearedReleases = try? await experienceService.prepareReleaseProfile(nil)
        guard isCurrentAdmission(admission) else { return }
        if let clearedReleases {
            _ = try? await experienceService.commitReleaseProfile(
                clearedReleases,
                generation: admission.generation,
                admission: cacheStoreAdmission(for: admission)
            )
        }
        guard isCurrentAdmission(admission) else { return }
        _ = await segmentService.replaceSnapshot(
            .empty,
            definitions: [],
            for: admission.distinctId,
            profileGeneration: admission.generation,
            admission: cacheStoreAdmission(for: admission)
        )
        guard isCurrentAdmission(admission) else { return }
        await refreshInBackground(distinctId: admission.distinctId)
    }

    /// Stages every suspending dependency before publishing the in-memory
    /// profile. Generation-stamped collaborators reject late older commits;
    /// every side effect is preceded by the same identity/generation/locale
    /// admission check.
    private func admitProfile(
        _ item: CachedProfile,
        admission: ProfileAdmission,
        persistToDisk: Bool
    ) async throws -> Bool {
        let profile = item.response
        let distinctId = item.distinctId
        guard distinctId == admission.distinctId,
              item.locale == admission.locale,
              isCurrentAdmission(admission) else { return false }

        let prepared = try await experienceService.prepareReleaseProfile(profile.releases)
        guard isCurrentAdmission(admission) else { return false }

        if persistToDisk {
            do {
                let stored = try await diskCache.store(
                    item,
                    forKey: distinctId,
                    admission: cacheStoreAdmission(for: admission)
                )
                guard stored else { return false }
                LogDebug("Updated disk cache for \(NuxieLogger.shared.logDistinctID(distinctId))")
            } catch {
                LogWarning("Failed to update disk cache: \(error)")
            }
            guard isCurrentAdmission(admission) else { return false }
        }

        guard let routingCatalog = try await experienceService.commitReleaseProfile(
            prepared,
            generation: admission.generation,
            admission: cacheStoreAdmission(for: admission)
        ) else { return false }
        guard isCurrentAdmission(admission) else { return false }

        let installedMembership = await segmentService.replaceSnapshot(
            profile.segmentMemberships,
            definitions: profile.segments,
            for: distinctId,
            profileGeneration: admission.generation,
            admission: cacheStoreAdmission(for: admission)
        )
        guard installedMembership,
              isCurrentAdmission(admission) else { return false }

        if let userProps = profile.userProperties {
            let properties = Dictionary(uniqueKeysWithValues: userProps.map { ($0.key, $0.value.value) })
            guard identityService.setUserProperties(
                properties,
                ifCurrentDistinctIdMatches: distinctId
            ) else { return false }
            LogInfo("Updated \(properties.count) user properties from server")
        }

        guard isCurrentAdmission(admission) else { return false }
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

        // Server facts and mailbox work are customer-scoped, not localized:
        // committing them from a response fetched under an older locale is
        // harmless (the same facts arrive under any locale, and their dedupe
        // is correct), so they gate on identity only.
        latestCustomerScopedCommitGeneration = max(
            latestCustomerScopedCommitGeneration,
            admission.generation
        )
        if let facts = profile.facts, !facts.isEmpty {
            guard isCurrentIdentity(admission) else { return true }
            await eventLog.commitServerFacts(facts, distinctId: distinctId)
            guard isCurrentIdentity(admission) else { return true }
        }
        if let mailbox = profile.mailbox, !mailbox.isEmpty {
            guard isCurrentIdentity(admission) else { return true }
            await journeyMailboxHandler?(mailbox, distinctId)
            guard isCurrentIdentity(admission) else { return true }
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
        invalidateProfileRequests()
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
        invalidateProfileRequests()
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
            let admission = beginProfileRequest(distinctId: distinctId)
            await discardInvalidCachedProfileAndRefresh(
                admission: admission
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
        let admission = beginProfileRequest(distinctId: newDistinctId)

        guard isCurrentAdmission(admission) else { return }
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
            profileGeneration: admission.generation
        )
        guard isCurrentAdmission(admission) else { return }

        // Clear old user's disk cache
        guard await diskCache.remove(
            forKey: oldDistinctId,
            admission: cacheStoreAdmission(for: admission)
        ) else { return }
        guard isCurrentAdmission(admission) else { return }

        let clearedReleases = try? await experienceService.prepareReleaseProfile(nil)
        guard isCurrentAdmission(admission) else { return }
        if let clearedReleases {
            _ = try? await experienceService.commitReleaseProfile(
                clearedReleases,
                generation: admission.generation,
                admission: cacheStoreAdmission(for: admission)
            )
        }
        guard isCurrentAdmission(admission) else { return }
        
        // Try to load new user's cache from disk
        if let cached = await diskCache.retrieve(forKey: newDistinctId, allowStale: true) {
            guard isCurrentAdmission(admission) else { return }
            guard cached.locale == admission.locale else {
                LogDebug("Discarding new user's cached profile from a different locale")
                guard await diskCache.remove(
                    forKey: newDistinctId,
                    admission: cacheStoreAdmission(for: admission)
                ) else { return }
                guard isCurrentAdmission(admission) else { return }
                await refreshInBackground(distinctId: newDistinctId)
                return
            }
            guard isFresh(cached) else {
                LogDebug("Discarding expired cached profile before user-change admission")
                await discardInvalidCachedProfileAndRefresh(
                    admission: admission
                )
                return
            }
            do {
                let admitted = try await admitProfile(
                    cached,
                    admission: admission,
                    persistToDisk: false
                )
                guard admitted else { return }
            } catch {
                LogError("Cached release profile authentication failed: \(error)")
                guard isCurrentAdmission(admission) else { return }
                await discardInvalidCachedProfileAndRefresh(
                    admission: admission
                )
                return
            }
            LogDebug("Loaded new user's profile from disk")
            
            // Refresh if stale
            let age = dateProvider.timeIntervalSince(cached.cachedAt)
            if age > backgroundRefreshAge {
                guard isCurrentAdmission(admission) else { return }
                await refreshInBackground(distinctId: newDistinctId)
            }
        } else {
            guard isCurrentAdmission(admission) else { return }
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
    
    private func beginProfileRequest(distinctId: String) -> ProfileAdmission {
        return ProfileAdmission(
            distinctId: distinctId,
            generation: profileAdmissionGeneration.claim(),
            locale: effectiveLocale
        )
    }

    private func invalidateProfileRequests() {
        profileAdmissionGeneration.invalidate()
    }

    /// Called synchronously after the effective locale mutates, before the
    /// replacing fetch begins: an in-flight fetch under the old locale is
    /// invalidated even though no new request has claimed a generation yet.
    func localeDidChange() {
        invalidateProfileRequests()
    }

    /// Commits the customer-scoped, locale-independent portions of a profile
    /// response whose locale-scoped state was discarded as stale.
    private func commitIdentityScopedPortions(
        of profile: ProfileResponse,
        admission: ProfileAdmission
    ) async {
        // Only the locale-flip discard qualifies: a generation-superseded
        // fetch is plain old data and must not overwrite the newer
        // admission's customer state. That includes the combined case where
        // a replacement fetch under the new locale has ALREADY committed:
        // its generation is newer, so the stale request skips entirely.
        guard admission.locale != effectiveLocale,
              admission.generation > latestCustomerScopedCommitGeneration,
              isCurrentIdentity(admission) else { return }
        latestCustomerScopedCommitGeneration = admission.generation
        if let userProps = profile.userProperties {
            let properties = Dictionary(
                uniqueKeysWithValues: userProps.map { ($0.key, $0.value.value) }
            )
            _ = identityService.setUserProperties(
                properties,
                ifCurrentDistinctIdMatches: admission.distinctId
            )
        }
        if let facts = profile.facts, !facts.isEmpty {
            guard isCurrentIdentity(admission) else { return }
            await eventLog.commitServerFacts(facts, distinctId: admission.distinctId)
        }
        if let mailbox = profile.mailbox, !mailbox.isEmpty {
            guard isCurrentIdentity(admission) else { return }
            await journeyMailboxHandler?(mailbox, admission.distinctId)
        }
    }

    private func isCurrentIdentity(_ admission: ProfileAdmission) -> Bool {
        identityService.getDistinctId() == admission.distinctId
    }

    private func isCurrentAdmission(_ admission: ProfileAdmission) -> Bool {
        profileAdmissionGeneration.matches(admission.generation)
            && identityService.getDistinctId() == admission.distinctId
            && effectiveLocale == admission.locale
    }

    private func cacheStoreAdmission(
        for admission: ProfileAdmission
    ) -> ProfileSideEffectAdmission {
        let generation = profileAdmissionGeneration
        let identity = identityService
        let locale = localeProvider
        return ProfileSideEffectAdmission {
            generation.matches(admission.generation)
                && identity.getDistinctId() == admission.distinctId
                && locale.localeIdentifier() == admission.locale
        }
    }

}
