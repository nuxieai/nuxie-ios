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
        let runtime: PreparedRuntimeRelease
        let resourceMetricOwner: ExperienceReleaseResourceMetricOwner
        var unreportedAcquisitionMetrics: ExperienceReleaseResourceMetrics
    }

    private struct PendingPreparation {
        let id: UUID
        let resourceMetricOwner: ExperienceReleaseResourceMetricOwner
        let task: Task<PreparedRuntimeRelease, Error>
    }

    private struct PreparedRuntimeRelease: Sendable {
        let acquired: PreparedExperienceRelease
        let interactivePreparation: ExperienceInteractivePreparationHandle
    }

    private struct WarmTask {
        let id: UUID
        let key: ExperienceVersionKey
        let task: Task<Void, Never>
    }

    private struct ActivePreloadAccounting {
        let context: ExperiencePresentationTraceContext
        let span: ExperiencePresentationTraceSpan
        let selectedReleaseID: AuthenticatedExperienceReleaseID
        var metrics: ExperienceReleaseResourceMetrics
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
    private var preloadMetricsByRelease: [
        AuthenticatedExperienceReleaseID: ExperienceReleaseResourceMetrics
    ] = [:]
    private var reportedPreloadMetricsByRelease: [
        AuthenticatedExperienceReleaseID: ExperienceReleaseResourceMetrics
    ] = [:]
    private var activePreloadAccounting: ActivePreloadAccounting?
    private var warmLoadsSuspended = false

    private let productService: ProductService
    private let releaseStore: any ExperienceReleaseAcquiring
    private let warmLoadLimiter: ExperienceWarmLoadLimiter
    private let interactivePreparationCache: ExperienceInteractivePreparationCache

    init(
        productService: ProductService,
        releaseStore: any ExperienceReleaseAcquiring,
        maximumConcurrentWarmLoads: Int = 4,
        warmLoadsInitiallySuspended: Bool = false,
        interactivePreparationCache: ExperienceInteractivePreparationCache =
            ExperienceInteractivePreparationCache()
    ) {
        self.productService = productService
        self.releaseStore = releaseStore
        self.warmLoadLimiter = ExperienceWarmLoadLimiter(
            maximumConcurrentLoads: maximumConcurrentWarmLoads
        )
        self.warmLoadsSuspended = warmLoadsInitiallySuspended
        self.interactivePreparationCache = interactivePreparationCache
    }

    func replaceReleaseProfile(
        _ profile: ExperienceReleaseProfileV1?
    ) async throws -> [ExperienceReference]? {
        guard let profile else {
            cancelWarmTasks()
            finishPreloadAccounting(cancelled: true)
            cancelPendingLoads()
            cancelPendingPreparations()
            experiencesByVersion.removeAll()
            releasesByVersion.removeAll()
            preparedReleasesByVersion.removeAll()
            await interactivePreparationCache.removeAll()
            preloadMetricsByRelease.removeAll()
            reportedPreloadMetricsByRelease.removeAll()
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
        finishPreloadAccounting(cancelled: true)
        cancelPendingLoads()
        cancelPendingPreparations()
        experiencesByVersion.removeAll()
        releasesByVersion = installed
        preparedReleasesByVersion = preparedReleasesByVersion.filter { key, stored in
            installed[key]?.releaseID == stored.releaseID
        }
        await interactivePreparationCache.retainPreparations(
            for: Set(installed.values.map { $0.releaseID.descriptorSHA256 })
        )
        preloadMetricsByRelease.removeAll()
        reportedPreloadMetricsByRelease.removeAll()
        beginWarming(installed.values)
        return catalog.references
    }

    func clearCache() async {
        cancelWarmTasks()
        finishPreloadAccounting(cancelled: true)
        cancelPendingLoads()
        cancelPendingPreparations()
        experiencesByVersion.removeAll()
        releasesByVersion.removeAll()
        preparedReleasesByVersion.removeAll()
        await interactivePreparationCache.removeAll()
        preloadMetricsByRelease.removeAll()
        reportedPreloadMetricsByRelease.removeAll()
    }

    /// Drops memory-heavy prepared bytes while retaining authenticated
    /// descriptor authority. A later presentation can safely rehydrate from
    /// the verified content-addressed disk cache.
    func handleMemoryPressure() async {
        cancelWarmTasks()
        finishPreloadAccounting(cancelled: true)
        cancelPendingLoads()
        cancelPendingPreparations()
        experiencesByVersion.removeAll()
        preparedReleasesByVersion.removeAll()
        await interactivePreparationCache.removeAll()
    }

    /// Waits for the profile generation's bounded speculative work to settle.
    /// Qualification and deterministic tests use this to establish a true
    /// memory-warm boundary without reaching into task implementation details.
    func waitForWarmLoadsToSettle() async {
        let tasks = warmTasksByRelease.values.map(\.task)
        for task in tasks { await task.value }
    }

    /// Prevents future profile installs from starting speculative artifact or
    /// runtime preparation. Qualification uses this before profile admission
    /// to establish genuine cold and disk-only boundaries.
    func suspendWarmLoads() async {
        warmLoadsSuspended = true
        cancelWarmTasks()
        finishPreloadAccounting(cancelled: true)
        cancelPendingPreparations()
        preparedReleasesByVersion.removeAll()
        await interactivePreparationCache.removeAll()
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
        initialScreenID: String?,
        presentationTraceContext: ExperiencePresentationTraceContext? = nil
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
        beginPreloadAccountingIfNeeded(
            selectedReleaseID: release.releaseID,
            context: presentationTraceContext
        )
        let runtime: PreparedRuntimeRelease
        do {
            runtime = try await preparedRelease(
                for: key,
                release: release,
                resourceMetricOwner: .presentation
            )
        } catch let failure as ExperienceReleaseResourceFailure {
            throw failure
        }
        guard releasesByVersion[key]?.releaseID == release.releaseID,
              experience.authenticatedReleaseID == release.releaseID else {
            throw CancellationError()
        }
        let acquisitionMetrics = consumeAcquisitionMetrics(
            for: key,
            releaseID: release.releaseID,
            resourceMetricOwner: .presentation
        )
        return try runtime.acquired.presentationArtifact(
            identity: .init(
                experienceId: release.reference.experienceId,
                buildId: release.behavior.buildId
            ),
            initialScreenID: initialScreenID,
            interactivePreparation: runtime.interactivePreparation,
            resourceMetrics: acquisitionMetrics
        )
    }

    private func preparedRelease(
        for key: ExperienceVersionKey,
        release: AuthenticatedExperienceReleaseDefinition,
        resourceMetricOwner: ExperienceReleaseResourceMetricOwner
    ) async throws -> PreparedRuntimeRelease {
        if let stored = preparedReleasesByVersion[key],
           stored.releaseID == release.releaseID {
            return stored.runtime
        }

        let load: PendingPreparation
        let ownsLoad: Bool
        if let pending = pendingPreparations[release.releaseID] {
            load = pending
            ownsLoad = false
        } else {
            let cache = interactivePreparationCache
            let created = PendingPreparation(
                id: UUID(),
                resourceMetricOwner: resourceMetricOwner,
                task: Task { [releaseStore] in
                    let acquired = try await releaseStore.prepare(definition: release)
                    guard let firstScreenID = acquired.payloadsByScreenID.keys.sorted().first,
                          let payload = acquired.payloadsByScreenID[firstScreenID] else {
                        throw ExperienceReleaseAcquisitionError.invalidRuntimeBinding(
                            "release has no prepared screen payload"
                        )
                    }
                    return PreparedRuntimeRelease(
                        acquired: acquired,
                        interactivePreparation: ExperienceInteractivePreparationHandle(
                            cache: cache,
                            provenance: release.releaseID.descriptorSHA256,
                            payload: payload
                        )
                    )
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
        if pendingPreparations[release.releaseID]?.id != load.id {
            guard let committed = preparedReleasesByVersion[key],
                  committed.releaseID == release.releaseID else {
                throw CancellationError()
            }
            return committed.runtime
        }
        guard releasesByVersion[key]?.releaseID == release.releaseID else {
            throw CancellationError()
        }
        if preparedReleasesByVersion[key]?.releaseID != release.releaseID {
            preparedReleasesByVersion[key] = StoredPreparedRelease(
                releaseID: release.releaseID,
                runtime: prepared,
                resourceMetricOwner: load.resourceMetricOwner,
                unreportedAcquisitionMetrics: prepared.acquired.resourceMetrics
            )
        }
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
        guard !warmLoadsSuspended else { return }
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
            let key = ExperienceVersionKey(
                experienceId: definition.reference.experienceId,
                versionId: definition.reference.versionId
            )
            warmTasksByRelease[releaseID] = WarmTask(
                id: taskID,
                key: key,
                task: task
            )
        }
    }

    private func warm(
        _ definition: AuthenticatedExperienceReleaseDefinition,
        taskID: UUID
    ) async {
        let releaseID = definition.releaseID
        let key = ExperienceVersionKey(
            experienceId: definition.reference.experienceId,
            versionId: definition.reference.versionId
        )
        defer {
            if warmTasksByRelease[releaseID]?.id == taskID {
                recordPreloadMetrics(
                    consumeAcquisitionMetrics(
                        for: key,
                        releaseID: releaseID,
                        resourceMetricOwner: .preload
                    ),
                    for: releaseID
                )
                warmTasksByRelease[releaseID] = nil
                finishPreloadAccountingIfSettled()
            }
        }
        do {
            async let hydrated = experience(
                experienceId: definition.reference.experienceId,
                versionId: definition.reference.versionId
            )
            async let prepared = preparedRelease(
                for: key,
                release: definition,
                resourceMetricOwner: .preload
            )
            let (_, runtime) = try await (hydrated, prepared)
            recordPreloadMetrics(
                consumeAcquisitionMetrics(
                    for: key,
                    releaseID: releaseID,
                    resourceMetricOwner: .preload
                ),
                for: releaseID
            )
            _ = try await runtime.interactivePreparation.preparation(
                resourceMetricOwner: .preload
            )
            recordPreloadMetrics(
                await runtime.interactivePreparation.consumeResourceMetrics(
                    resourceMetricOwner: .preload
                ),
                for: releaseID
            )
        } catch is CancellationError {
            return
        } catch let failure as ExperienceReleaseResourceFailure {
            if warmTasksByRelease[releaseID]?.id == taskID {
                recordPreloadMetrics(failure.resourceMetrics, for: releaseID)
            }
            LogDebug("Experience release warming failed: \(failure.underlying)")
        } catch {
            LogDebug("Experience release warming failed: \(error)")
        }
    }

    private func consumeAcquisitionMetrics(
        for key: ExperienceVersionKey,
        releaseID: AuthenticatedExperienceReleaseID,
        resourceMetricOwner: ExperienceReleaseResourceMetricOwner
    ) -> ExperienceReleaseResourceMetrics {
        guard var stored = preparedReleasesByVersion[key],
              stored.releaseID == releaseID,
              stored.resourceMetricOwner == resourceMetricOwner else { return .zero }
        let metrics = stored.unreportedAcquisitionMetrics
        stored.unreportedAcquisitionMetrics = .zero
        preparedReleasesByVersion[key] = stored
        return metrics
    }

    private func recordPreloadMetrics(
        _ metrics: ExperienceReleaseResourceMetrics,
        for releaseID: AuthenticatedExperienceReleaseID
    ) {
        guard metrics != .zero else { return }
        preloadMetricsByRelease[releaseID] =
            (preloadMetricsByRelease[releaseID] ?? .zero).adding(metrics)
        appendUnreportedPreloadMetrics(for: releaseID)
    }

    private func beginPreloadAccountingIfNeeded(
        selectedReleaseID: AuthenticatedExperienceReleaseID,
        context: ExperiencePresentationTraceContext?
    ) {
        guard activePreloadAccounting == nil,
              let context,
              !warmTasksByRelease.isEmpty || !preloadMetricsByRelease.isEmpty else {
            return
        }
        activePreloadAccounting = ActivePreloadAccounting(
            context: context,
            span: context.begin(
                .externalAssetPreparation,
                attributes: ["phase": "profile_preload"]
            ),
            selectedReleaseID: selectedReleaseID,
            metrics: .zero
        )
        for releaseID in preloadMetricsByRelease.keys.sorted(by: releaseIDSort) {
            appendUnreportedPreloadMetrics(for: releaseID)
        }
        finishPreloadAccountingIfSettled()
    }

    private func appendUnreportedPreloadMetrics(
        for releaseID: AuthenticatedExperienceReleaseID
    ) {
        guard var accounting = activePreloadAccounting,
              let metrics = preloadMetricsByRelease[releaseID] else { return }
        let reported = reportedPreloadMetricsByRelease[releaseID] ?? .zero
        let delta = metrics.subtracting(reported)
        guard delta != .zero else { return }
        accounting.metrics = accounting.metrics.adding(
            delta.attributedToPreload(
                unused: releaseID != accounting.selectedReleaseID
            )
        )
        activePreloadAccounting = accounting
        reportedPreloadMetricsByRelease[releaseID] = metrics
    }

    private func finishPreloadAccountingIfSettled() {
        guard warmTasksByRelease.isEmpty else { return }
        finishPreloadAccounting(cancelled: false)
    }

    private func finishPreloadAccounting(cancelled: Bool) {
        guard let accounting = activePreloadAccounting else { return }
        var attributes = accounting.metrics.qualificationTraceAttributes
        attributes["phase"] = "profile_preload"
        attributes["cancelled"] = String(cancelled)
        accounting.context.complete(accounting.span, attributes: attributes)
        activePreloadAccounting = nil
    }

    private func releaseIDSort(
        _ lhs: AuthenticatedExperienceReleaseID,
        _ rhs: AuthenticatedExperienceReleaseID
    ) -> Bool {
        if lhs.identity.experienceId != rhs.identity.experienceId {
            return lhs.identity.experienceId < rhs.identity.experienceId
        }
        if lhs.identity.experienceVersionId != rhs.identity.experienceVersionId {
            return lhs.identity.experienceVersionId < rhs.identity.experienceVersionId
        }
        return lhs.descriptorSHA256 < rhs.descriptorSHA256
    }

    private func cancelWarmTasks() {
        for (releaseID, warmTask) in warmTasksByRelease {
            recordPreloadMetrics(
                consumeAcquisitionMetrics(
                    for: warmTask.key,
                    releaseID: releaseID,
                    resourceMetricOwner: .preload
                ),
                for: releaseID
            )
            warmTask.task.cancel()
        }
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
