import Foundation

/// Authenticates release profiles and resolves descriptor-native experiences.
actor ExperienceStore {
    private struct ExperienceVersionKey: Hashable {
        let experienceId: String
        let versionId: String
    }

    private struct PendingLoad {
        let id: UUID
        let releaseID: AuthenticatedExperienceReleaseID
        let task: Task<Experience, Error>
    }

    private struct StoredReleaseArtifact {
        let releaseID: AuthenticatedExperienceReleaseID
        let initialScreenID: String
        let artifact: AcquiredExperienceArtifact
    }

    private var experiencesByVersion: [ExperienceVersionKey: Experience] = [:]
    private var pendingFetches: [ExperienceVersionKey: PendingLoad] = [:]
    private var releasesByVersion: [
        ExperienceVersionKey: AuthenticatedExperienceReleaseDefinition
    ] = [:]
    private var releaseArtifactsByVersion: [ExperienceVersionKey: StoredReleaseArtifact] = [:]

    private let productService: ProductService
    private let releaseStore: any ExperienceReleaseAcquiring

    init(
        productService: ProductService,
        releaseStore: any ExperienceReleaseAcquiring
    ) {
        self.productService = productService
        self.releaseStore = releaseStore
    }

    func replaceReleaseProfile(
        _ profile: ExperienceReleaseProfileV1?
    ) async throws -> [ExperienceReference]? {
        guard let profile else {
            cancelPendingLoads()
            experiencesByVersion.removeAll()
            releasesByVersion.removeAll()
            releaseArtifactsByVersion.removeAll()
            return nil
        }

        let catalog = try await releaseStore.authenticateProfile(profile)
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

        cancelPendingLoads()
        experiencesByVersion.removeAll()
        releasesByVersion = installed
        releaseArtifactsByVersion.removeAll()
        return catalog.references
    }

    func clearCache() {
        cancelPendingLoads()
        experiencesByVersion.removeAll()
        releasesByVersion.removeAll()
        releaseArtifactsByVersion.removeAll()
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
              let initialScreenID else {
            throw CancellationError()
        }
        if let stored = releaseArtifactsByVersion[key],
           stored.releaseID == release.releaseID,
           stored.initialScreenID == initialScreenID {
            return stored.artifact
        }

        let artifact = try await releaseStore.presentationArtifact(
            definition: release,
            initialScreenID: initialScreenID
        )
        guard releasesByVersion[key]?.releaseID == release.releaseID,
              experience.authenticatedReleaseID == release.releaseID else {
            throw CancellationError()
        }
        releaseArtifactsByVersion[key] = StoredReleaseArtifact(
            releaseID: release.releaseID,
            initialScreenID: initialScreenID,
            artifact: artifact
        )
        return artifact
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
