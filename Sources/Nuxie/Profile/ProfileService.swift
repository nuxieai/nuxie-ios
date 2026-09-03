import Foundation

/// Internal control-flow error used when an identity or locale transition
/// makes an in-flight profile response obsolete.
struct ProfileRefreshCancellationError: LocalizedError, Sendable {
    var errorDescription: String? {
        "Stale profile fetch discarded because profile authority changed"
    }
}

protocol ProfileServiceProtocol: AnyObject, Sendable {
    func getCachedProfile(distinctId: String) async -> ProfileResponse?
    func localeDidChange() async
    func clearCache(distinctId: String) async
    func clearAllCache() async
    @discardableResult func cleanupExpired() async -> Int
    @discardableResult
    func refetchProfile(distinctId: String?) async throws -> ProfileResponse
    func handleUserChange(from oldDistinctId: String, to newDistinctId: String) async
    func onAppBecameActive() async
}

extension ProfileServiceProtocol {
    @discardableResult
    func refetchProfile() async throws -> ProfileResponse {
        try await refetchProfile(distinctId: nil)
    }
}

struct CachedProfile: Codable, Sendable {
    let response: ProfileResponse
    let distinctId: String
    let cachedAt: Date
    let validator: ProfileCacheValidator?
    let locale: String?

    init(
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

private actor FallbackCachedProfileStore: CachedProfileStore {
    private struct Entry {
        let value: CachedProfile
        let storedAt: Date
        let sizeBytes: Int64
    }

    private var storage: [String: Entry] = [:]

    func store(_ item: CachedProfile, forKey key: String) async throws {
        let encoded = try JSONEncoder().encode(item)
        storage[key] = .init(
            value: item,
            storedAt: Date(),
            sizeBytes: Int64(encoded.count)
        )
    }

    @discardableResult
    func store(
        _ item: CachedProfile,
        forKey key: String,
        admission: ProfileSideEffectAdmission
    ) async throws -> Bool {
        guard admission() else { return false }
        try await store(item, forKey: key)
        return true
    }

    func retrieve(forKey key: String, allowStale: Bool) async -> CachedProfile? {
        _ = allowStale
        return storage[key]?.value
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

    func cleanupExpired() async -> Int { 0 }
    func getAllKeys() async -> [String] { Array(storage.keys) }

    func getMetadata(forKey key: String) async -> DiskCacheMetadata? {
        guard let entry = storage[key] else { return nil }
        return .init(
            key: key,
            lastModified: entry.storedAt,
            size: entry.sizeBytes,
            age: Date().timeIntervalSince(entry.storedAt)
        )
    }
}

private final class ProfileAdmissionGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var current: UInt64 = 0

    func claim() -> UInt64 {
        lock.withLock {
            current &+= 1
            return current
        }
    }

    @discardableResult
    func invalidate() -> UInt64 { claim() }

    func matches(_ generation: UInt64) -> Bool {
        lock.withLock { current == generation }
    }
}

/// Owns the one profile channel described by the Journey plane contract.
/// Cached profiles are durable offline authority; launch and foreground always
/// revalidate them with ETag rather than using an age-based skip.
internal actor ProfileService: ProfileServiceProtocol {
    private enum AuthoritySource {
        case network
        case cache
    }

    private struct Admission {
        let distinctId: String
        let generation: UInt64
        let locale: String
    }

    private var cachedProfile: CachedProfile?
    private let diskCache: any CachedProfileStore
    private let authorityStore: any ProfileAuthorityBindingStore
    private let admissionGeneration = ProfileAdmissionGeneration()
    private var initialDiskLoadTask: Task<Void, Never>?
    private var initialDiskLoadDone = false
    private let initialDiskLoadNeeded: Bool

    private let identity: IdentityServiceProtocol
    private let api: ProfileFetching
    private let experiences: ExperienceServiceProtocol
    private let journeyProfiles: JourneyProfileCatalog
    private let journeys: (any JourneyProfileConsuming)?
    private let dateProvider: DateProviderProtocol
    private let localeProvider: LocaleIdentifierProviding

    init(
        identity: IdentityServiceProtocol,
        api: ProfileFetching,
        experiences: ExperienceServiceProtocol,
        journeyProfiles: JourneyProfileCatalog,
        journeyRuntime: (any JourneyProfileConsuming)? = nil,
        dateProvider: DateProviderProtocol,
        localeProvider: LocaleIdentifierProviding,
        storageScope: ProfileStorageScope,
        customStoragePath: URL? = nil
    ) {
        self.identity = identity
        self.api = api
        self.experiences = experiences
        self.journeyProfiles = journeyProfiles
        self.journeys = journeyRuntime
        self.dateProvider = dateProvider
        self.localeProvider = localeProvider

        let cacheBase: URL
        if let customStoragePath {
            cacheBase = customStoragePath.appendingPathComponent(
                "nuxie",
                isDirectory: true
            )
        } else {
            let caches = FileManager.default.urls(
                for: .cachesDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
            cacheBase = caches.appendingPathComponent("nuxie", isDirectory: true)
        }

        let authorityBase: URL
        if let customStoragePath {
            authorityBase = customStoragePath.appendingPathComponent(
                "nuxie",
                isDirectory: true
            )
        } else {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
            authorityBase = support.appendingPathComponent("nuxie", isDirectory: true)
        }

        do {
            authorityStore = try FileProfileAuthorityBindingStore(
                baseDirectory: authorityBase,
                storageScope: storageScope
            )
        } catch {
            LogWarning("Failed to initialize profile authority store: \(error)")
            authorityStore = InMemoryProfileAuthorityBindingStore()
        }

        do {
            diskCache = try DiskCache<CachedProfile>(options: .init(
                baseDirectory: cacheBase,
                subdirectory: storageScope.cacheSubdirectory,
                // Retrieval always permits stale entries. This value only
                // bounds metadata maintained by the generic cache.
                defaultTTL: 10 * 365 * 24 * 60 * 60,
                maxTotalBytes: 40 * 1024 * 1024,
                excludeFromBackup: true,
                fileProtection: .completeUntilFirstUserAuthentication
            ))
            initialDiskLoadNeeded = true
        } catch {
            LogWarning("Failed to initialize profile cache: \(error)")
            diskCache = FallbackCachedProfileStore()
            initialDiskLoadNeeded = false
        }

        Task { [weak self] in
            await self?.awaitInitialDiskLoad()
        }
    }

    internal init(
        cache: any CachedProfileStore,
        authorityStore: any ProfileAuthorityBindingStore =
            InMemoryProfileAuthorityBindingStore(),
        identity: IdentityServiceProtocol,
        api: ProfileFetching,
        experiences: ExperienceServiceProtocol,
        journeyProfiles: JourneyProfileCatalog,
        journeyRuntime: (any JourneyProfileConsuming)? = nil,
        dateProvider: DateProviderProtocol,
        localeProvider: LocaleIdentifierProviding
    ) {
        self.diskCache = cache
        self.authorityStore = authorityStore
        self.identity = identity
        self.api = api
        self.experiences = experiences
        self.journeyProfiles = journeyProfiles
        self.journeys = journeyRuntime
        self.dateProvider = dateProvider
        self.localeProvider = localeProvider
        initialDiskLoadNeeded = true
        Task { [weak self] in
            await self?.awaitInitialDiskLoad()
        }
    }

    private var effectiveLocale: String {
        localeProvider.localeIdentifier()
    }

    private func awaitInitialDiskLoad() async {
        guard initialDiskLoadNeeded, !initialDiskLoadDone else { return }
        if initialDiskLoadTask == nil {
            initialDiskLoadTask = Task { [weak self] in
                await self?.loadCurrentProfileFromDisk()
            }
        }
        await initialDiskLoadTask?.value
        initialDiskLoadDone = true
        initialDiskLoadTask = nil
    }

    private func loadCurrentProfileFromDisk() async {
        let distinctId = identity.getDistinctId()
        let admission = beginAdmission(distinctId: distinctId)
        guard let cached = await diskCache.retrieve(
            forKey: distinctId,
            allowStale: true
        ) else { return }
        guard cached.locale == admission.locale else {
            _ = await diskCache.remove(
                forKey: distinctId,
                admission: sideEffectAdmission(for: admission)
            )
            return
        }
        do {
            guard try await admit(
                cached,
                admission: admission,
                persistToDisk: false,
                authoritySource: .cache
            ) else { return }
        } catch {
            LogError("Cached Journey profile rejected: \(error)")
            await discard(cached, admission: admission)
        }
    }

    func getCachedProfile(distinctId: String) async -> ProfileResponse? {
        await awaitInitialDiskLoad()
        guard cachedProfile?.distinctId == distinctId else { return nil }
        return cachedProfile?.response
    }

    func refetchProfile(distinctId requestedId: String?) async throws -> ProfileResponse {
        await awaitInitialDiskLoad()
        let distinctId = requestedId ?? identity.getDistinctId()
        let admission = beginAdmission(distinctId: distinctId)
        let previous = cachedProfile?.distinctId == distinctId
            && cachedProfile?.locale == admission.locale
            ? cachedProfile
            : nil
        let result = try await api.fetchProfile(
            for: distinctId,
            locale: admission.locale,
            revalidating: previous?.validator
        )
        guard isCurrent(admission) else {
            throw ProfileRefreshCancellationError()
        }

        switch result {
        case .modified(let response, let validator):
            guard let validator, validator.authority != nil else {
                throw NuxieNetworkError.invalidResponse
            }
            let next = CachedProfile(
                response: response,
                distinctId: distinctId,
                cachedAt: dateProvider.now(),
                validator: validator,
                locale: admission.locale
            )
            guard try await admit(
                next,
                admission: admission,
                persistToDisk: true,
                authoritySource: .network
            ) else {
                throw ProfileRefreshCancellationError()
            }
            return response

        case .notModified:
            guard let previous, previous.validator != nil else {
                throw NuxieNetworkError.invalidResponse
            }
            let refreshed = CachedProfile(
                response: previous.response,
                distinctId: previous.distinctId,
                cachedAt: dateProvider.now(),
                validator: previous.validator,
                locale: previous.locale
            )
            do {
                guard try await diskCache.store(
                    refreshed,
                    forKey: distinctId,
                    admission: sideEffectAdmission(for: admission)
                ) else {
                    throw ProfileRefreshCancellationError()
                }
            } catch is ProfileRefreshCancellationError {
                throw ProfileRefreshCancellationError()
            } catch {
                LogWarning("Failed to persist profile revalidation: \(error)")
            }
            guard isCurrent(admission) else {
                throw ProfileRefreshCancellationError()
            }
            cachedProfile = refreshed
            return refreshed.response
        }
    }

    private func admit(
        _ item: CachedProfile,
        admission: Admission,
        persistToDisk: Bool,
        authoritySource: AuthoritySource
    ) async throws -> Bool {
        guard item.distinctId == admission.distinctId,
              item.locale == admission.locale,
              isCurrent(admission),
              let authority = item.validator?.authority else {
            return false
        }

        let authorityAccepted: Bool
        switch authoritySource {
        case .network:
            authorityAccepted = try await authorityStore.bind(authority)
        case .cache:
            authorityAccepted = try await authorityStore.authority() == authority
        }
        guard authorityAccepted, isCurrent(admission) else {
            throw JourneyReleaseAuthenticationError.invalidDescriptor
        }

        let preparedProfile = try await journeyProfiles.prepare(
            item.response.planeProfile,
            authority: authority
        )
        guard isCurrent(admission) else { return false }
        let preparedArtifacts = try await experiences.prepareJourneyProfile(
            preparedProfile.snapshot
        )
        guard isCurrent(admission) else { return false }

        if persistToDisk {
            do {
                guard try await diskCache.store(
                    item,
                    forKey: item.distinctId,
                    admission: sideEffectAdmission(for: admission)
                ) else { return false }
            } catch {
                LogWarning("Failed to persist Journey profile: \(error)")
            }
            guard isCurrent(admission) else { return false }
        }

        guard try await journeyProfiles.commit(
            preparedProfile,
            distinctId: item.distinctId,
            admission: sideEffectAdmission(for: admission)
        ), isCurrent(admission) else { return false }

        guard await experiences.commitJourneyProfile(
            preparedArtifacts,
            generation: admission.generation,
            admission: sideEffectAdmission(for: admission)
        ), isCurrent(admission) else { return false }

        guard let snapshot = await journeyProfiles.snapshot(
            distinctId: item.distinctId
        ) else { return false }
        cachedProfile = item
        await journeys?.profileDidCommit(
            snapshot,
            artifacts: preparedArtifacts.artifacts,
            authority: authority,
            admissionGeneration: admission.generation,
            distinctId: item.distinctId
        )
        return true
    }

    private func discard(_ item: CachedProfile, admission: Admission) async {
        guard isCurrent(admission) else { return }
        _ = await diskCache.remove(
            forKey: item.distinctId,
            admission: sideEffectAdmission(for: admission)
        )
        guard isCurrent(admission) else { return }
        cachedProfile = nil
        _ = await journeyProfiles.clear(
            distinctId: item.distinctId,
            admission: sideEffectAdmission(for: admission)
        )
        await journeys?.profileDidWithdraw(
            authority: try? await authorityStore.authority(),
            admissionGeneration: admission.generation,
            distinctId: item.distinctId
        )
        await clearPreparedArtifacts(admission: admission)
    }

    private func clearPreparedArtifacts(admission: Admission) async {
        guard isCurrent(admission),
              let prepared = try? await experiences.prepareJourneyProfile(nil),
              isCurrent(admission) else { return }
        _ = await experiences.commitJourneyProfile(
            prepared,
            generation: admission.generation,
            admission: sideEffectAdmission(for: admission)
        )
    }

    func localeDidChange() async {
        let distinctId = identity.getDistinctId()
        let generation = admissionGeneration.invalidate()
        cachedProfile = nil
        _ = await journeyProfiles.clear(distinctId: distinctId)
        await journeys?.profileDidWithdraw(
            authority: try? await authorityStore.authority(),
            admissionGeneration: generation,
            distinctId: distinctId
        )
    }

    func clearCache(distinctId: String) async {
        let generation = admissionGeneration.invalidate()
        cachedProfile = nil
        _ = await journeyProfiles.clear(distinctId: distinctId)
        await journeys?.profileDidWithdraw(
            authority: try? await authorityStore.authority(),
            admissionGeneration: generation,
            distinctId: distinctId
        )
        await diskCache.remove(forKey: distinctId)
    }

    func clearAllCache() async {
        let generation = admissionGeneration.invalidate()
        cachedProfile = nil
        await journeyProfiles.clearAll()
        await journeys?.profileDidClearAll(admissionGeneration: generation)
        await diskCache.clearAll()
    }

    func cleanupExpired() async -> Int {
        // Canonical profiles are durable offline authority, so age alone never
        // removes one. Cache-budget eviction remains owned by DiskCache.
        0
    }

    func onAppBecameActive() async {
        await awaitInitialDiskLoad()
        do {
            _ = try await refetchProfile(distinctId: identity.getDistinctId())
        } catch is ProfileRefreshCancellationError {
            return
        } catch {
            LogDebug("Foreground profile revalidation failed: \(error)")
        }
    }

    func handleUserChange(
        from oldDistinctId: String,
        to newDistinctId: String
    ) async {
        let admission = beginAdmission(distinctId: newDistinctId)
        cachedProfile = nil
        _ = await journeyProfiles.clear(distinctId: oldDistinctId)
        await diskCache.remove(forKey: oldDistinctId)
        guard isCurrent(admission) else { return }

        if let cached = await diskCache.retrieve(
            forKey: newDistinctId,
            allowStale: true
        ), cached.locale == admission.locale {
            do {
                _ = try await admit(
                    cached,
                    admission: admission,
                    persistToDisk: false,
                    authoritySource: .cache
                )
            } catch {
                await discard(cached, admission: admission)
            }
        }
        guard isCurrent(admission) else { return }
        Task { [weak self] in
            do {
                _ = try await self?.refetchProfile(distinctId: newDistinctId)
            } catch {
                LogDebug("Profile refresh after identity change failed: \(error)")
            }
        }
    }

    private func beginAdmission(distinctId: String) -> Admission {
        .init(
            distinctId: distinctId,
            generation: admissionGeneration.claim(),
            locale: effectiveLocale
        )
    }

    private func isCurrent(_ admission: Admission) -> Bool {
        admissionGeneration.matches(admission.generation)
            && identity.getDistinctId() == admission.distinctId
            && effectiveLocale == admission.locale
    }

    private func sideEffectAdmission(
        for admission: Admission
    ) -> ProfileSideEffectAdmission {
        let generations = admissionGeneration
        let identity = identity
        let localeProvider = localeProvider
        return ProfileSideEffectAdmission {
            generations.matches(admission.generation)
                && identity.getDistinctId() == admission.distinctId
                && localeProvider.localeIdentifier() == admission.locale
        }
    }
}
