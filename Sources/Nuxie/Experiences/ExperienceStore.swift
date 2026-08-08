import Foundation

/// Joins metadata-only delivery pointers with signed package journey content.
actor ExperienceStore {
    private struct ExperienceVersionKey: Hashable {
        let experienceId: String
        let versionId: String
    }

    private struct PendingLoad {
        let id: UUID
        let task: Task<Experience, Error>
    }

    private var pointersByVersion: [ExperienceVersionKey: RemoteExperience] = [:]
    private var assetBaseURLByVersion: [ExperienceVersionKey: URL] = [:]
    private var latestAssetBaseURL: URL?
    private var experiencesByVersion: [ExperienceVersionKey: Experience] = [:]
    private var pendingFetches: [ExperienceVersionKey: PendingLoad] = [:]

    private let api: NuxieApiProtocol
    private let productService: ProductService
    private let packageStore: ExperiencePackageStore
    private let packageAuthenticator: any ExperiencePackageAuthenticating

    init(
        api: NuxieApiProtocol,
        productService: ProductService,
        packageStore: ExperiencePackageStore,
        packageAuthenticator: any ExperiencePackageAuthenticating =
            SwiftExperiencePackageAuthenticator()
    ) {
        self.api = api
        self.productService = productService
        self.packageStore = packageStore
        self.packageAuthenticator = packageAuthenticator
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
        versionId: String
    ) async throws -> Experience {
        let key = ExperienceVersionKey(
            experienceId: experienceId,
            versionId: versionId
        )
        if let pending = pendingFetches[key] {
            return try await pending.task.value
        }
        if let cached = experiencesByVersion[key] {
            return cached
        }

        let loadID = UUID()
        let task = Task<Experience, Error> { [weak self] in
            guard let self else { throw CancellationError() }
            let remote: RemoteExperience
            if let delivered = await self.pointer(key: key) {
                remote = delivered
            } else {
                remote = try await self.api.fetchExperience(
                    experienceId: experienceId,
                    versionId: versionId
                )
                await self.record(
                    remote,
                    assetBaseURL: await self.latestBaseURL()
                )
            }
            try Task.checkCancellation()
            guard remote.experienceId == experienceId,
                  remote.versionId == versionId else {
                throw ExperiencePackageStoreError.identityMismatch
            }
            guard let assetBaseURL = await self.assetBaseURL(key: key) else {
                throw ExperiencePackageStoreError.invalidAssetBaseURL(
                    "profile assetBaseUrl is unavailable"
                )
            }
            let acquired = try await self.packageStore.getOrDownloadPackage(
                for: remote,
                assetBaseURL: assetBaseURL
            )
            try Task.checkCancellation()
            let payload = try await self.packageAuthenticator.authenticate(acquired)
            let package = LoadedExperiencePackage(acquired: acquired, payload: payload)
            try Task.checkCancellation()

            // StoreKit warm-up is intentionally behind authenticated package
            // loading because product IDs live only in the signed journey.
            let products = try await self.fetchProducts(for: package.journey)
            try Task.checkCancellation()
            let experience = Experience(
                remote: remote,
                journey: package.journey,
                assetBaseURL: assetBaseURL,
                products: products
            )
            guard await self.commitExperience(
                experience,
                remote: remote,
                key: key,
                loadID: loadID
            ) else {
                throw CancellationError()
            }
            return experience
        }
        pendingFetches[key] = PendingLoad(id: loadID, task: task)
        defer {
            if pendingFetches[key]?.id == loadID {
                pendingFetches[key] = nil
            }
        }
        return try await task.value
    }

    func experience(versionId: String) async throws -> Experience {
        let matchingPointers = pointersByVersion.values.filter {
            $0.versionId == versionId
        }
        guard matchingPointers.count <= 1 else {
            throw ExperiencePackageStoreError.invalidPointer(
                "versionId is ambiguous without experienceId"
            )
        }
        guard let experienceId = matchingPointers.first?.experienceId else {
            throw ExperiencePackageStoreError.invalidPointer(
                "experience version was not delivered by the current profile"
            )
        }
        return try await experience(
            experienceId: experienceId,
            versionId: versionId
        )
    }

    func evictPackages(retaining remotes: [RemoteExperience]) async {
        await packageStore.evictUnreferencedPackages(retaining: remotes)
    }

    private func pointer(key: ExperienceVersionKey) -> RemoteExperience? {
        pointersByVersion[key]
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
        remote: RemoteExperience,
        key: ExperienceVersionKey,
        loadID: UUID
    ) -> Bool {
        guard pendingFetches[key]?.id == loadID,
              let current = pointersByVersion[key],
              current.buildId == remote.buildId,
              current.artifact.sha256 == remote.artifact.sha256 else {
            return false
        }
        experiencesByVersion[key] = experience
        return true
    }

    private func fetchProducts(
        for journey: JourneyDocument
    ) async throws -> [ExperienceProduct] {
        let ids = extractProductIds(from: journey)
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
