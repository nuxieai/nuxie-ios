import Foundation

/// Joins metadata-only delivery pointers with signed package journey content.
actor ExperienceStore {
    private struct ExperienceVersionKey: Hashable {
        let experienceId: String
        let versionId: String
    }

    private struct PendingLoad {
        let id: UUID
        let releaseID: AuthenticatedExperienceReleaseID?
        let task: Task<Experience, Error>
    }

    private struct StoredReleaseArtifact {
        let releaseID: AuthenticatedExperienceReleaseID
        let initialScreenID: String
        let artifact: AcquiredExperiencePackage
    }

    private var pointersByVersion: [ExperienceVersionKey: RemoteExperience] = [:]
    private var assetBaseURLByVersion: [ExperienceVersionKey: URL] = [:]
    private var latestAssetBaseURL: URL?
    private var experiencesByVersion: [ExperienceVersionKey: Experience] = [:]
    private var pendingFetches: [ExperienceVersionKey: PendingLoad] = [:]
    private var releasesByVersion: [ExperienceVersionKey:
        AuthenticatedExperienceReleaseDefinition] = [:]
    private var releaseArtifactsByVersion: [ExperienceVersionKey: StoredReleaseArtifact] = [:]

    private let api: ExperienceFetching
    private let productService: ProductService
    private let packageStore: ExperiencePackageStore
    private let packageAuthenticator: any ExperiencePackageAuthenticating
    private let releaseStore: (any ExperienceReleaseAcquiring)?

    init(
        api: ExperienceFetching,
        productService: ProductService,
        packageStore: ExperiencePackageStore,
        packageAuthenticator: any ExperiencePackageAuthenticating =
            SwiftExperiencePackageAuthenticator(),
        releaseStore: (any ExperienceReleaseAcquiring)? = nil
    ) {
        self.api = api
        self.productService = productService
        self.packageStore = packageStore
        self.packageAuthenticator = packageAuthenticator
        self.releaseStore = releaseStore
    }

    func replaceReleaseProfile(
        _ profile: ExperienceReleaseProfileV1?
    ) async throws -> [ExperienceReference]? {
        guard let profile else {
            cancelPendingSignedLoads()
            for key in releasesByVersion.keys {
                experiencesByVersion[key] = nil
            }
            releasesByVersion.removeAll()
            releaseArtifactsByVersion.removeAll()
            return nil
        }
        guard let releaseStore else {
            throw ExperienceReleaseAcquisitionError.requiredObjectUnavailable(
                "release authentication unavailable"
            )
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
        // Authentication, conflict resolution, and replay admission all finish
        // before the actor-visible catalog is replaced.
        cancelPendingSignedLoads()
        for key in Set(releasesByVersion.keys).union(installed.keys) {
            experiencesByVersion[key] = nil
        }
        releasesByVersion = installed
        releaseArtifactsByVersion.removeAll()
        return catalog.references
    }

    func authenticatedReleaseReferences() -> [ExperienceReference] {
        releasesByVersion.values.map(\.reference).sorted {
            $0.versionId < $1.versionId
        }
    }

    func registerExperiences(
        _ remotes: [RemoteExperience],
        assetBaseURL: URL
    ) {
        latestAssetBaseURL = assetBaseURL
        for remote in remotes {
            let key = ExperienceVersionKey(
                experienceId: remote.experienceId,
                versionId: remote.versionId
            )
            pointersByVersion[key] = remote
            assetBaseURLByVersion[key] = assetBaseURL
        }
    }

    func preloadPackages(
        _ remotes: [RemoteExperience],
        assetBaseURL: URL
    ) async {
        await withTaskGroup(of: Void.self) { group in
            for remote in remotes {
                let key = ExperienceVersionKey(
                    experienceId: remote.experienceId,
                    versionId: remote.versionId
                )
                guard releasesByVersion[key] == nil else { continue }
                group.addTask { [weak self] in
                    guard let self else { return }
                    await self.packageStore.preloadPackage(
                        for: remote,
                        assetBaseURL: assetBaseURL
                    )
                }
            }
        }
    }

    func removeExperience(versionId: String) {
        pointersByVersion = pointersByVersion.filter {
            $0.key.versionId != versionId
        }
        assetBaseURLByVersion = assetBaseURLByVersion.filter {
            $0.key.versionId != versionId
        }
        experiencesByVersion = experiencesByVersion.filter {
            $0.key.versionId != versionId
        }
        let removedTasks = pendingFetches.filter {
            $0.key.versionId == versionId
        }
        for pending in removedTasks.values {
            pending.task.cancel()
        }
        pendingFetches = pendingFetches.filter {
            $0.key.versionId != versionId
        }
    }

    func clearCache() {
        pointersByVersion.removeAll()
        assetBaseURLByVersion.removeAll()
        latestAssetBaseURL = nil
        experiencesByVersion.removeAll()
        releasesByVersion.removeAll()
        releaseArtifactsByVersion.removeAll()
        for pending in pendingFetches.values {
            pending.task.cancel()
        }
        pendingFetches.removeAll()
    }

    func cachedExperience(versionId: String) -> Experience? {
        experiencesByVersion.first {
            $0.key.versionId == versionId
        }?.value
    }

    func experience(
        experienceId: String,
        versionId: String,
        presentationTraceContext: ExperiencePresentationTraceContext? = nil
    ) async throws -> Experience {
        let resolutionSpan = presentationTraceContext?.begin(
            .experienceResolution,
            attributes: ["experience_version_id": versionId]
        )
        let key = ExperienceVersionKey(
            experienceId: experienceId,
            versionId: versionId
        )
        if let pending = pendingFetches[key] {
            do {
                let experience = try await pending.task.value
                if let resolutionSpan {
                    presentationTraceContext?.complete(
                        resolutionSpan,
                        attributes: ["source": "joined_in_flight"]
                    )
                }
                return experience
            } catch {
                if let resolutionSpan {
                    presentationTraceContext?.fail(
                        resolutionSpan,
                        error: error,
                        attributes: ["source": "joined_in_flight"]
                    )
                }
                throw error
            }
        }
        if let cached = experiencesByVersion[key] {
            if let resolutionSpan {
                presentationTraceContext?.complete(
                    resolutionSpan,
                    attributes: ["source": "memory_cache"]
                )
            }
            return cached
        }

        let loadID = UUID()
        let task = Task<Experience, Error> { [weak self] in
            guard let self else { throw CancellationError() }
            let signedRelease = await self.release(key: key)
            let behavior: ExperienceBehaviorDefinition
            let remote: RemoteExperience?
            let assetBaseURL: URL
            if let signedRelease {
                behavior = signedRelease.behavior
                remote = nil
                guard behavior.reference.experienceId == experienceId,
                      behavior.reference.versionId == versionId else {
                    throw ExperiencePackageStoreError.identityMismatch
                }
                guard let signedAssetBaseURL = URL(
                    string: signedRelease.delivery.assetBaseUrl
                ) else {
                    throw ExperiencePackageStoreError.invalidAssetBaseURL(
                        signedRelease.delivery.assetBaseUrl
                    )
                }
                assetBaseURL = signedAssetBaseURL
            } else {
                let resolved: RemoteExperience
                if let delivered = await self.pointer(key: key) {
                    resolved = delivered
                } else {
                    resolved = try await self.api.fetchExperience(
                        experienceId: experienceId,
                        versionId: versionId
                    )
                    await self.record(
                        resolved,
                        assetBaseURL: await self.latestBaseURL()
                    )
                }
                guard resolved.experienceId == experienceId,
                      resolved.versionId == versionId else {
                    throw ExperiencePackageStoreError.identityMismatch
                }
                guard let resolvedAssetBaseURL = await self.assetBaseURL(key: key) else {
                    throw ExperiencePackageStoreError.invalidAssetBaseURL(
                        "profile assetBaseUrl is unavailable"
                    )
                }
                behavior = ExperienceBehaviorDefinition(remote: resolved)
                remote = resolved
                assetBaseURL = resolvedAssetBaseURL
            }
            try Task.checkCancellation()
            if let signedRelease {
                let productIDs = signedRelease.appleProductIDs
                let productSpan = productIDs.isEmpty ? nil : presentationTraceContext?.begin(
                    .storeKitProductLookup,
                    attributes: ["product_count": String(productIDs.count)]
                )
                let products: [ExperienceProduct]
                do {
                    products = try await self.fetchProducts(
                        for: signedRelease.journey,
                        productIDs: productIDs
                    )
                    if let productSpan {
                        presentationTraceContext?.complete(productSpan)
                    }
                } catch {
                    if let productSpan {
                        presentationTraceContext?.fail(productSpan, error: error)
                    }
                    throw error
                }
                try Task.checkCancellation()
                let experience = Experience(
                    behavior: behavior,
                    journey: signedRelease.journey,
                    assetBaseURL: assetBaseURL,
                    authenticatedReleaseID: signedRelease.releaseID,
                    products: products
                )
                guard await self.commitExperience(
                    experience,
                    legacyRemote: nil,
                    key: key,
                    loadID: loadID
                ) else {
                    throw CancellationError()
                }
                return experience
            }

            let acquisitionSpan = presentationTraceContext?.begin(
                .artifactPackageAcquisition,
                attributes: ["experience_version_id": versionId]
            )
            let acquired: AcquiredExperiencePackage
            do {
                guard let remote else {
                    throw ExperiencePackageStoreError.invalidPointer(
                        "legacy experience delivery is unavailable"
                    )
                }
                acquired = try await self.packageStore.getOrDownloadPackage(
                    for: remote,
                    assetBaseURL: assetBaseURL,
                    presentationTraceContext: presentationTraceContext
                )
                if let acquisitionSpan {
                    presentationTraceContext?.complete(
                        acquisitionSpan,
                        attributes: [
                            "source": acquired.source.rawValue,
                            "bytes": String(acquired.packageBytes.count)
                        ]
                    )
                }
            } catch {
                if let acquisitionSpan {
                    presentationTraceContext?.fail(acquisitionSpan, error: error)
                }
                throw error
            }
            try Task.checkCancellation()
            let authenticationSpan = presentationTraceContext?.begin(
                .packageAuthentication
            )
            let payload: AuthenticatedRuntimePayload
            do {
                payload = try await self.packageAuthenticator.authenticate(acquired)
                if let authenticationSpan {
                    presentationTraceContext?.complete(authenticationSpan)
                }
            } catch {
                if let authenticationSpan {
                    presentationTraceContext?.fail(authenticationSpan, error: error)
                }
                throw error
            }
            let package = LoadedExperiencePackage(acquired: acquired, payload: payload)
            try Task.checkCancellation()

            // StoreKit warm-up is intentionally behind authenticated package
            // loading because product IDs live only in the signed journey.
            let productIDs = await self.extractProductIds(from: package.journey)
            let productSpan = productIDs.isEmpty ? nil : presentationTraceContext?.begin(
                .storeKitProductLookup,
                attributes: ["product_count": String(productIDs.count)]
            )
            let products: [ExperienceProduct]
            do {
                products = try await self.fetchProducts(
                    for: package.journey,
                    productIDs: productIDs
                )
                if let productSpan {
                    presentationTraceContext?.complete(productSpan)
                }
            } catch {
                if let productSpan {
                    presentationTraceContext?.fail(productSpan, error: error)
                }
                throw error
            }
            try Task.checkCancellation()
            guard let remote else {
                throw ExperiencePackageStoreError.invalidPointer(
                    "experience delivery is unavailable"
                )
            }
            let experience = Experience(
                remote: remote,
                journey: package.journey,
                assetBaseURL: assetBaseURL,
                products: products
            )
            guard await self.commitExperience(
                experience,
                legacyRemote: remote,
                key: key,
                loadID: loadID
            ) else {
                throw CancellationError()
            }
            return experience
        }
        pendingFetches[key] = PendingLoad(
            id: loadID,
            releaseID: releasesByVersion[key]?.releaseID,
            task: task
        )
        defer {
            if pendingFetches[key]?.id == loadID {
                pendingFetches[key] = nil
            }
        }
        do {
            let experience = try await task.value
            if let resolutionSpan {
                presentationTraceContext?.complete(
                    resolutionSpan,
                    attributes: ["source": "loaded"]
                )
            }
            return experience
        } catch {
            if let resolutionSpan {
                presentationTraceContext?.fail(resolutionSpan, error: error)
            }
            throw error
        }
    }

    /// Returns authenticated descriptor behavior without acquiring the RIV,
    /// external objects, or StoreKit products. Legacy delivery has no such
    /// split and continues through the ordinary authenticated load.
    func experienceForJourneyControl(
        experienceId: String,
        versionId: String
    ) async throws -> Experience {
        let key = ExperienceVersionKey(
            experienceId: experienceId,
            versionId: versionId
        )
        if let release = releasesByVersion[key] {
            guard release.reference.experienceId == experienceId,
                  release.reference.versionId == versionId,
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
        return try await experience(
            experienceId: experienceId,
            versionId: versionId
        )
    }

    func validatesPresentationCommit(
        _ commit: JourneyPendingPresentation
    ) -> Bool {
        let key = ExperienceVersionKey(
            experienceId: commit.experienceId,
            versionId: commit.experienceVersionId
        )
        if let releaseID = commit.releaseID {
            guard commit.presentationStyle == .fullScreen else { return false }
            return releasesByVersion[key]?.releaseID == releaseID
        }
        return pointersByVersion[key] != nil
            && commit.presentationStyle == .legacyPackage
    }

    func experience(
        versionId: String,
        presentationTraceContext: ExperiencePresentationTraceContext? = nil
    ) async throws -> Experience {
        let references = Set(
            pointersByVersion.values
                .filter { $0.versionId == versionId }
                .map(\.reference)
            + releasesByVersion.values
                .filter { $0.reference.versionId == versionId }
                .map(\.reference)
        )
        guard references.count <= 1 else {
            throw ExperiencePackageStoreError.invalidPointer(
                "versionId is ambiguous without experienceId"
            )
        }
        guard let experienceId = references.first?.experienceId else {
            throw ExperiencePackageStoreError.invalidPointer(
                "experience version was not delivered by the current profile"
            )
        }
        return try await experience(
            experienceId: experienceId,
            versionId: versionId,
            presentationTraceContext: presentationTraceContext
        )
    }

    func evictPackages(retaining remotes: [RemoteExperience]) async {
        await packageStore.evictUnreferencedPackages(retaining: remotes)
    }

    private func pointer(key: ExperienceVersionKey) -> RemoteExperience? {
        pointersByVersion[key]
    }

    private func release(
        key: ExperienceVersionKey
    ) -> AuthenticatedExperienceReleaseDefinition? { releasesByVersion[key] }

    private func recordReleaseArtifact(
        _ artifact: AcquiredExperiencePackage,
        key: ExperienceVersionKey,
        releaseID: AuthenticatedExperienceReleaseID,
        initialScreenID: String
    ) -> Bool {
        guard releasesByVersion[key]?.releaseID == releaseID else { return false }
        releaseArtifactsByVersion[key] = StoredReleaseArtifact(
            releaseID: releaseID,
            initialScreenID: initialScreenID,
            artifact: artifact
        )
        return true
    }

    func presentationArtifact(
        for experience: Experience,
        initialScreenID: String?
    ) async throws -> AcquiredExperiencePackage {
        let key = ExperienceVersionKey(
            experienceId: experience.id,
            versionId: experience.versionId
        )
        if let expectedReleaseID = experience.authenticatedReleaseID {
            guard releasesByVersion[key]?.releaseID == expectedReleaseID else {
                throw CancellationError()
            }
        }
        if let stored = releaseArtifactsByVersion[key] {
            if releasesByVersion[key]?.releaseID == stored.releaseID,
               experience.authenticatedReleaseID == stored.releaseID,
               initialScreenID == stored.initialScreenID {
                return stored.artifact
            }
            releaseArtifactsByVersion[key] = nil
        }
        if let release = releasesByVersion[key] {
            guard experience.authenticatedReleaseID == release.releaseID else {
                throw CancellationError()
            }
            guard let initialScreenID else {
                throw ExperienceReleaseAcquisitionError.invalidProfileEntry
            }
            guard let releaseStore else {
                throw ExperienceReleaseAcquisitionError.requiredObjectUnavailable(
                    release.reference.versionId
                )
            }
            let artifact = try await releaseStore.presentationPackage(
                definition: release,
                initialScreenID: initialScreenID
            )
            guard releasesByVersion[key]?.releaseID == release.releaseID,
                  experience.authenticatedReleaseID == release.releaseID else {
                throw CancellationError()
            }
            guard recordReleaseArtifact(
                artifact,
                key: key,
                releaseID: release.releaseID,
                initialScreenID: initialScreenID
            ) else {
                throw CancellationError()
            }
            return artifact
        }
        guard let remote = experience.legacyRemote else {
            throw ExperiencePackageStoreError.invalidPointer(
                "legacy package pointer is unavailable"
            )
        }
        return try await packageStore.getOrDownloadPackage(
            for: remote,
            assetBaseURL: experience.assetBaseURL
        )
    }

    private func assetBaseURL(key: ExperienceVersionKey) -> URL? {
        assetBaseURLByVersion[key]
    }

    private func latestBaseURL() -> URL? {
        latestAssetBaseURL
    }

    private func record(_ remote: RemoteExperience, assetBaseURL: URL?) {
        let key = ExperienceVersionKey(
            experienceId: remote.experienceId,
            versionId: remote.versionId
        )
        pointersByVersion[key] = remote
        if let assetBaseURL {
            assetBaseURLByVersion[key] = assetBaseURL
        }
    }

    private func commitExperience(
        _ experience: Experience,
        legacyRemote: RemoteExperience?,
        key: ExperienceVersionKey,
        loadID: UUID
    ) -> Bool {
        guard pendingFetches[key]?.id == loadID else {
            return false
        }
        if let release = releasesByVersion[key] {
            guard pendingFetches[key]?.releaseID == release.releaseID,
                  release.behavior.buildId == experience.buildId else { return false }
        } else {
            guard let legacyRemote,
                  let current = pointersByVersion[key],
                  current.buildId == legacyRemote.buildId,
                  current.artifact.sha256 == legacyRemote.artifact.sha256 else {
                return false
            }
        }
        experiencesByVersion[key] = experience
        return true
    }

    private func cancelPendingSignedLoads() {
        let signed = pendingFetches.filter { $0.value.releaseID != nil }
        for pending in signed.values { pending.task.cancel() }
        pendingFetches = pendingFetches.filter { $0.value.releaseID == nil }
    }

    private func fetchProducts(
        for journey: JourneyDocument,
        productIDs: [String]? = nil
    ) async throws -> [ExperienceProduct] {
        let ids = productIDs ?? extractProductIds(from: journey)
        guard !ids.isEmpty else { return [] }
        let products = try await productService.fetchProducts(for: Set(ids))
        return products.map {
            ExperienceProduct(
                id: $0.id,
                name: $0.displayName,
                price: $0.displayPrice,
                period: mapSubscriptionPeriod($0.subscriptionPeriod)
            )
        }
    }

    private func extractProductIds(from journey: JourneyDocument) -> [String] {
        var ids = Set<String>()
        for value in journey.viewModelValues ?? [] {
            guard value.path.split(separator: "/").last == "productId" else {
                continue
            }
            if let string = value.value.value as? String {
                ids.insert(string)
            } else if let dictionary = value.value.value as? [String: Any],
                      let id = dictionary["productId"] as? String
                        ?? dictionary["id"] as? String {
                ids.insert(id)
            } else if let dictionary = value.value.value as? [String: AnyCodable],
                      let id = dictionary["productId"]?.value as? String
                        ?? dictionary["id"]?.value as? String {
                ids.insert(id)
            }
        }
        return Array(ids)
    }

    private func mapSubscriptionPeriod(
        _ subscriptionPeriod: SubscriptionPeriod?
    ) -> ProductPeriod? {
        guard let period = subscriptionPeriod else { return nil }
        switch period.unit {
        case .week: return ProductPeriod.week
        case .month: return ProductPeriod.month
        case .year: return ProductPeriod.year
        case .day: return ProductPeriod.week
        }
    }
}
