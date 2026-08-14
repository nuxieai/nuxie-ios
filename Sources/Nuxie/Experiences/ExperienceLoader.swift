import Foundation

/// Authenticates release profiles and resolves descriptor-native experiences.
actor ExperienceLoader {
    private struct ExperienceVersionKey: Hashable {
        let experienceId: String
        let versionId: String
    }

    private struct PendingLoad {
        let id: UUID
        let releaseID: AuthenticatedExperienceReleaseID
        let task: Task<Experience, Error>
    }

    private struct StoredPreparedRelease {
        let releaseID: AuthenticatedExperienceReleaseID
        let prepared: PreparedExperienceRelease
    }

    private struct PendingPreparation {
        let id: UUID
        let task: Task<PreparedExperienceRelease, Error>
    }

    private struct WarmTask {
        let id: UUID
        let task: Task<Void, Never>
    }

    private var experiencesByVersion: [ExperienceVersionKey: Experience] = [:]
    private var pendingFetches: [ExperienceVersionKey: PendingLoad] = [:]
    private var releasesByVersion: [
        ExperienceVersionKey: AuthenticatedExperienceReleaseDefinition
    ] = [:]
    private var preparedReleasesByVersion: [ExperienceVersionKey: StoredPreparedRelease] = [:]
    private var pendingPreparations: [
        AuthenticatedExperienceReleaseID: PendingPreparation
    ] = [:]
    private var warmTasksByRelease: [AuthenticatedExperienceReleaseID: WarmTask] = [:]

    private let productService: ProductService
    private let releaseStore: any ExperienceReleaseAcquiring
    private let warmLoadLimiter: ExperienceWarmLoadLimiter

    init(
        productService: ProductService,
        releaseStore: any ExperienceReleaseAcquiring,
        maximumConcurrentWarmLoads: Int = 4
    ) {
        self.productService = productService
        self.releaseStore = releaseStore
        self.warmLoadLimiter = ExperienceWarmLoadLimiter(
            maximumConcurrentLoads: maximumConcurrentWarmLoads
        )
    }

    func replaceReleaseProfile(
        _ profile: ExperienceReleaseProfileV1?
    ) async throws -> [ExperienceReference]? {
        guard let profile else {
            cancelWarmTasks()
            cancelPendingLoads()
            cancelPendingPreparations()
            experiencesByVersion.removeAll()
            releasesByVersion.removeAll()
            preparedReleasesByVersion.removeAll()
            return nil
        }

        let catalog = try await releaseStore.authenticateProfile(profile)
        for rejection in catalog.rejections {
            LogError(
                "Experience release rejected independently: "
                    + "\(rejection.locator.experienceId)/"
                    + "\(rejection.locator.experienceVersionId) "
                    + rejection.contractCode
            )
        }
        var installed: [ExperienceVersionKey: AuthenticatedExperienceReleaseDefinition] = [:]
        for definition in catalog.definitions {
            let key = ExperienceVersionKey(
                experienceId: definition.reference.experienceId,
                versionId: definition.reference.versionId
            )
            if let existing = installed[key], existing.releaseID != definition.releaseID {
                throw ExperienceReleaseAcquisitionError.invalidProfileEntry
            }
            installed[key] = definition
        }

        cancelWarmTasks()
        cancelPendingLoads()
        cancelPendingPreparations()
        experiencesByVersion.removeAll()
        releasesByVersion = installed
        preparedReleasesByVersion.removeAll()
        beginWarming(installed.values)
        return catalog.references
    }

    func clearCache() {
        cancelWarmTasks()
        cancelPendingLoads()
        cancelPendingPreparations()
        experiencesByVersion.removeAll()
        releasesByVersion.removeAll()
        preparedReleasesByVersion.removeAll()
    }

    /// Drops memory-heavy prepared bytes while retaining authenticated
    /// descriptor authority. A later presentation can safely rehydrate from
    /// the verified content-addressed disk cache.
    func handleMemoryPressure() {
        cancelWarmTasks()
        cancelPendingLoads()
        cancelPendingPreparations()
        experiencesByVersion.removeAll()
        preparedReleasesByVersion.removeAll()
    }

    func cachedExperience(versionId: String) -> Experience? {
        experiencesByVersion.first { $0.key.versionId == versionId }?.value
    }

    func experience(
        experienceId: String,
        versionId: String,
        presentationTraceContext: ExperiencePresentationTraceContext? = nil
    ) async throws -> Experience {
        let key = ExperienceVersionKey(
            experienceId: experienceId,
            versionId: versionId
        )
        guard let release = releasesByVersion[key] else {
            throw ExperienceReleaseAcquisitionError.invalidProfileEntry
        }
        if let pending = pendingFetches[key] {
            return try await pending.task.value
        }
        if let cached = experiencesByVersion[key] {
            return cached
        }

        let loadID = UUID()
        let releaseID = release.releaseID
        let task = Task<Experience, Error> { [weak self] in
            guard let self else { throw CancellationError() }
            guard release.reference.experienceId == experienceId,
                  release.reference.versionId == versionId,
                  let assetBaseURL = URL(string: release.delivery.assetBaseUrl) else {
                throw ExperienceReleaseAcquisitionError.invalidProfileEntry
            }
            let productIDs = release.appleProductIDs
            let productSpan = productIDs.isEmpty ? nil : presentationTraceContext?.begin(
                .storeKitProductLookup,
                attributes: ["product_count": String(productIDs.count)]
            )
            let products: [ExperienceProduct]
            do {
                products = try await self.fetchProducts(productIDs)
                if let productSpan { presentationTraceContext?.complete(productSpan) }
            } catch {
                if let productSpan {
                    presentationTraceContext?.fail(productSpan, error: error)
                }
                throw error
            }
            try Task.checkCancellation()
            let experience = Experience(
                behavior: release.behavior,
                journey: release.journey,
                assetBaseURL: assetBaseURL,
                authenticatedReleaseID: releaseID,
                products: products
            )
            guard await self.commitExperience(
                experience,
                key: key,
                loadID: loadID,
                releaseID: releaseID
            ) else {
                throw CancellationError()
            }
            return experience
        }
        pendingFetches[key] = PendingLoad(id: loadID, releaseID: releaseID, task: task)
        defer {
            if pendingFetches[key]?.id == loadID { pendingFetches[key] = nil }
        }
        return try await task.value
    }

    /// Returns authenticated behavior without acquiring render objects or products.
    func experienceForJourneyControl(
        experienceId: String,
        versionId: String
    ) throws -> Experience {
        let key = ExperienceVersionKey(
            experienceId: experienceId,
            versionId: versionId
        )
        guard let release = releasesByVersion[key],
              let assetBaseURL = URL(string: release.delivery.assetBaseUrl) else {
            throw ExperienceReleaseAcquisitionError.invalidProfileEntry
        }
        return Experience(
            behavior: release.behavior,
            journey: release.journey,
            assetBaseURL: assetBaseURL,
            authenticatedReleaseID: release.releaseID
        )
    }

    func validatesPresentationCommit(_ commit: JourneyPendingPresentation) -> Bool {
        guard let releaseID = commit.releaseID,
              commit.presentationStyle == .fullScreen else { return false }
        let key = ExperienceVersionKey(
            experienceId: commit.experienceId,
            versionId: commit.experienceVersionId
        )
        return releasesByVersion[key]?.releaseID == releaseID
    }

    func experience(
        versionId: String,
        presentationTraceContext: ExperiencePresentationTraceContext? = nil
    ) async throws -> Experience {
        let references = releasesByVersion.values.filter {
            $0.reference.versionId == versionId
        }.map(\.reference)
        guard references.count == 1, let reference = references.first else {
            throw ExperienceReleaseAcquisitionError.invalidProfileEntry
        }
        return try await experience(
            experienceId: reference.experienceId,
            versionId: reference.versionId,
            presentationTraceContext: presentationTraceContext
        )
    }

    func presentationArtifact(
        for experience: Experience,
        initialScreenID: String?
    ) async throws -> AcquiredExperienceArtifact {
        let key = ExperienceVersionKey(
            experienceId: experience.id,
            versionId: experience.versionId
        )
        guard let release = releasesByVersion[key],
              experience.authenticatedReleaseID == release.releaseID,
              let initialScreenID,
              release.screenIDs.contains(initialScreenID) else {
            throw CancellationError()
        }
        let prepared = try await preparedRelease(for: key, release: release)
        guard releasesByVersion[key]?.releaseID == release.releaseID,
              experience.authenticatedReleaseID == release.releaseID else {
            throw CancellationError()
        }
        return try prepared.presentationArtifact(
            identity: .init(
                experienceId: release.reference.experienceId,
                buildId: release.behavior.buildId
            ),
            initialScreenID: initialScreenID
        )
    }

    private func preparedRelease(
        for key: ExperienceVersionKey,
        release: AuthenticatedExperienceReleaseDefinition
    ) async throws -> PreparedExperienceRelease {
        if let stored = preparedReleasesByVersion[key],
           stored.releaseID == release.releaseID {
            return stored.prepared
        }

        let load: PendingPreparation
        let ownsLoad: Bool
        if let pending = pendingPreparations[release.releaseID] {
            load = pending
            ownsLoad = false
        } else {
            let created = PendingPreparation(
                id: UUID(),
                task: Task { [releaseStore] in
                    try await releaseStore.prepare(definition: release)
                }
            )
            pendingPreparations[release.releaseID] = created
            load = created
            ownsLoad = true
        }
        defer {
            if ownsLoad, pendingPreparations[release.releaseID]?.id == load.id {
                pendingPreparations[release.releaseID] = nil
            }
        }
        let prepared = try await load.task.value
        guard releasesByVersion[key]?.releaseID == release.releaseID else {
            throw CancellationError()
        }
        preparedReleasesByVersion[key] = StoredPreparedRelease(
            releaseID: release.releaseID,
            prepared: prepared
        )
        return prepared
    }

    private func commitExperience(
        _ experience: Experience,
        key: ExperienceVersionKey,
        loadID: UUID,
        releaseID: AuthenticatedExperienceReleaseID
    ) -> Bool {
        guard pendingFetches[key]?.id == loadID,
              pendingFetches[key]?.releaseID == releaseID,
              releasesByVersion[key]?.releaseID == releaseID else { return false }
        experiencesByVersion[key] = experience
        return true
    }

    private func cancelPendingLoads() {
        for pending in pendingFetches.values { pending.task.cancel() }
        pendingFetches.removeAll()
    }

    private func cancelPendingPreparations() {
        for pending in pendingPreparations.values { pending.task.cancel() }
        pendingPreparations.removeAll()
    }

    private func beginWarming(
        _ definitions: Dictionary<ExperienceVersionKey, AuthenticatedExperienceReleaseDefinition>.Values
    ) {
        for definition in definitions {
            let releaseID = definition.releaseID
            let taskID = UUID()
            let task = Task { [weak self] in
                guard let self else { return }
                await warmLoadLimiter.perform {
                    guard !Task.isCancelled else { return }
                    await self.warm(definition, taskID: taskID)
                }
            }
            warmTasksByRelease[releaseID] = WarmTask(id: taskID, task: task)
        }
    }

    private func warm(
        _ definition: AuthenticatedExperienceReleaseDefinition,
        taskID: UUID
    ) async {
        let releaseID = definition.releaseID
        defer {
            if warmTasksByRelease[releaseID]?.id == taskID {
                warmTasksByRelease[releaseID] = nil
            }
        }
        do {
            async let hydrated = experience(
                experienceId: definition.reference.experienceId,
                versionId: definition.reference.versionId
            )
            async let prepared = preparedRelease(
                for: ExperienceVersionKey(
                    experienceId: definition.reference.experienceId,
                    versionId: definition.reference.versionId
                ),
                release: definition
            )
            _ = try await (hydrated, prepared)
        } catch is CancellationError {
            return
        } catch {
            LogDebug("Experience release warming failed: \(error)")
        }
    }

    private func cancelWarmTasks() {
        for task in warmTasksByRelease.values { task.task.cancel() }
        warmTasksByRelease.removeAll()
    }

    private func fetchProducts(_ ids: [String]) async throws -> [ExperienceProduct] {
        guard !ids.isEmpty else { return [] }
        return try await productService.fetchProducts(for: Set(ids)).map {
            ExperienceProduct(
                id: $0.id,
                name: $0.displayName,
                price: $0.displayPrice,
                period: mapSubscriptionPeriod($0.subscriptionPeriod)
            )
        }
    }

    private func mapSubscriptionPeriod(
        _ subscriptionPeriod: SubscriptionPeriod?
    ) -> ProductPeriod? {
        guard let period = subscriptionPeriod else { return nil }
        switch period.unit {
        case .week: return .week
        case .month: return .month
        case .year: return .year
        case .day: return .week
        }
    }
}

private actor ExperienceWarmLoadLimiter {
    private let maximumConcurrentLoads: Int
    private var activeLoads = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(maximumConcurrentLoads: Int) {
        self.maximumConcurrentLoads = max(1, maximumConcurrentLoads)
    }

    func perform(_ operation: @Sendable () async -> Void) async {
        await acquire()
        await operation()
        release()
    }

    private func acquire() async {
        if activeLoads < maximumConcurrentLoads {
            activeLoads += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            activeLoads -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}
