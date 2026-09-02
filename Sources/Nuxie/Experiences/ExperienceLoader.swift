import Foundation

enum ActiveProductEvidenceAuthorityResolution: Equatable, Sendable {
    case unavailable
    case readyNoMatch
    case nativeStoreKit
    case providerConnector
    case ambiguous

    var resolvedAuthority: PurchaseEvidenceAuthority? {
        switch self {
        case .unavailable:
            return nil
        case .readyNoMatch, .nativeStoreKit:
            return .nativeStoreKit
        case .providerConnector:
            return .providerConnector
        case .ambiguous:
            return .ambiguous
        }
    }
}

func activeProductEvidenceAuthority(
    products: [ExperienceReleaseProductDocument],
    storeProductId: String
) -> ActiveProductEvidenceAuthorityResolution {
    let authorities = Set(products
        .filter {
            $0.store.platform == "apple_app_store"
                && $0.store.productId == storeProductId
        }
        .map {
            $0.providerFeatureAccess == nil
                ? PurchaseEvidenceAuthority.nativeStoreKit
                : .providerConnector
        })
    switch authorities.count {
    case 0:
        return .readyNoMatch
    case 1:
        switch authorities.first {
        case .nativeStoreKit:
            return .nativeStoreKit
        case .providerConnector:
            return .providerConnector
        default:
            return .ambiguous
        }
    default:
        return .ambiguous
    }
}

/// Authenticates release profiles and resolves descriptor-native experiences.
actor ExperienceLoader {
    private struct ExperienceVersionKey: Hashable {
        let experienceId: String
        let versionId: String
    }

    private struct ProductReleaseAuthority {
        let releaseID: AuthenticatedExperienceReleaseID
        let journey: JourneyDocument
        let definition: ExperienceDefinition
        let products: [ExperienceReleaseProductDocument]
        let placements: [ExperienceReleasePlacementDocument]
        let additionalPlacementIDs: Set<String>
        let hasDynamicPurchase: Bool
    }

    /// Product and entitlement authority from one authenticated descriptor,
    /// independent of whether its render runtime is the legacy or device
    /// Journey representation.
    private struct ProductCatalogRelease {
        let releaseID: AuthenticatedExperienceReleaseID
        let isActive: Bool
        let products: [ExperienceReleaseProductDocument]
    }

    private struct OptimisticAllowanceCatalogKey: Hashable {
        let releaseID: AuthenticatedExperienceReleaseID
        let isActive: Bool
        let productID: String
        let platform: String
        let storeProductID: String
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
        let intent: ExperienceReleasePreparationIntent
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
    private var releasesByVersion: [
        ExperienceVersionKey: AuthenticatedExperienceReleaseDefinition
    ] = [:]
    /// App-scoped Product authority rebuilt from authenticated release
    /// descriptors during profile admission, before any paywall is presented.
    private var productMappingsByReleaseAndID: [String: ExperienceReleaseProductDocument] = [:]
    private var productMappingsByReleaseAndStoreID: [String: ExperienceReleaseProductDocument] = [:]
    /// Nil until an authenticated profile (including an authenticated empty
    /// profile) has established the current app's Product authority. The
    /// catalog is the material recovery generation: identical admissions do
    /// not rescan StoreKit, while ownership changes do.
    private var productAuthorityCatalog: [
        String: ActiveProductEvidenceAuthorityResolution
    ]?
    /// Exact signed descriptor inputs that can change the projection even when
    /// StoreKit receipt ownership remains unchanged.
    private var optimisticAllowanceCatalog: [
        OptimisticAllowanceCatalogKey: [OptimisticEntitlementAllowance]
    ]?
    private var productCatalogReleases: [ProductCatalogRelease] = []
    private var productAuthorityChangeHandler: (@Sendable () async -> Void)?
    private var pendingProductAuthorityChangeNotification = false
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
    private var warmLoadsPermanentlySuspended = false
    private var warmLoadsPausedForBackground = false
    private var latestProfileGeneration: UInt64 = 0

    private let productService: ProductService
    private let storeProductResolver: StoreProductResolver
    private let releaseStore: any ExperienceReleaseAcquiring
    private let warmLoadLimiter: ExperienceWarmLoadLimiter
    private let interactivePreparationCache: ExperienceInteractivePreparationCache
    private let testStoreEnabled: Bool

    init(
        productService: ProductService,
        introEligibilityTokenProvider: any IntroEligibilityTokenProviding =
            UnavailableIntroEligibilityTokenProvider(),
        introEligibilityOverrideHealth: IntroEligibilityOverrideHealth =
            IntroEligibilityOverrideHealth(),
        releaseStore: any ExperienceReleaseAcquiring,
        maximumConcurrentWarmLoads: Int = 4,
        warmLoadsInitiallySuspended: Bool = false,
        interactivePreparationCache: ExperienceInteractivePreparationCache =
            ExperienceInteractivePreparationCache(),
        testStoreEnabled: Bool = false
    ) {
        self.productService = productService
        self.storeProductResolver = StoreProductResolver(
            tokenProvider: introEligibilityTokenProvider,
            overrideHealth: introEligibilityOverrideHealth
        )
        self.releaseStore = releaseStore
        self.warmLoadLimiter = ExperienceWarmLoadLimiter(
            maximumConcurrentLoads: maximumConcurrentWarmLoads
        )
        self.warmLoadsPermanentlySuspended = warmLoadsInitiallySuspended
        self.interactivePreparationCache = interactivePreparationCache
        self.testStoreEnabled = testStoreEnabled
    }

    func prepareReleaseProfile(
        _ profile: ExperienceReleaseProfile?
    ) async throws -> PreparedExperienceReleaseProfile {
        guard let profile else {
            return PreparedExperienceReleaseProfile(profile: nil, catalog: nil)
        }
        let catalog = try await releaseStore.authenticateProfile(profile)
        return PreparedExperienceReleaseProfile(profile: profile, catalog: catalog)
    }

    func commitReleaseProfile(
        _ prepared: PreparedExperienceReleaseProfile,
        generation: UInt64
    ) async throws -> ExperienceRoutingCatalog? {
        try await commitReleaseProfile(prepared, generation: generation, admission: nil)
    }

    func commitReleaseProfile(
        _ prepared: PreparedExperienceReleaseProfile,
        generation: UInt64,
        admission: ProfileSideEffectAdmission?
    ) async throws -> ExperienceRoutingCatalog? {
        guard generation >= latestProfileGeneration else { return nil }
        // Mutation-point admission: rejects an invalidated (identity or
        // locale) admission before any newer commit raises the floor.
        if let admission, !admission() { return nil }
        latestProfileGeneration = generation
        return try await installPreparedReleaseProfile(
            prepared,
            guardedBy: generation,
            admission: admission
        )
    }

    /// Direct loader tests and low-level qualification hosts do not own a
    /// ProfileService generation. Production profile admission uses the
    /// generation-stamped prepare/commit pair above.
    func replaceReleaseProfile(
        _ profile: ExperienceReleaseProfile?
    ) async throws -> [ExperienceReference]? {
        let prepared = try await prepareReleaseProfile(profile)
        let committed = try await installPreparedReleaseProfile(prepared, guardedBy: nil)
        return profile == nil ? nil : committed?.references
    }

    private func installPreparedReleaseProfile(
        _ prepared: PreparedExperienceReleaseProfile,
        guardedBy generation: UInt64?,
        admission: ProfileSideEffectAdmission? = nil
    ) async throws -> ExperienceRoutingCatalog? {

        var installed: [ExperienceVersionKey: AuthenticatedExperienceReleaseDefinition] = [:]
        if let catalog = prepared.catalog {
            for rejection in catalog.rejections {
                LogError(
                    """
                    Experience release rejected independently: \
                    \(rejection.locator.experienceId)/\(rejection.locator.experienceVersionId) \
                    \(rejection.contractCode)
                    """
                )
            }
            for definition in catalog.definitions {
                let key = ExperienceVersionKey(
                    experienceId: definition.reference.experienceId,
                    versionId: definition.reference.versionId
                )
                if let existing = installed[key],
                   existing.releaseID != definition.releaseID {
                    throw ExperienceReleaseAcquisitionError.invalidProfileEntry
                }
                installed[key] = definition
            }
        }
        let catalogReleases = try makeProductCatalogReleases(
            legacyDefinitions: installed.values,
            deviceLegSnapshot: prepared.deviceLegSnapshot
        )
        let productMappings = makeProductMappingCache(catalogReleases)
        guard generation == nil || generation == latestProfileGeneration,
              admission?() != false else { return nil }
        let authorityChanged = installProductAuthorityCatalog(
            makeProductAuthorityCatalog(catalogReleases)
        )
        let allowancesChanged = installOptimisticAllowanceCatalog(
            makeOptimisticAllowanceCatalog(catalogReleases)
        )
        productCatalogReleases = catalogReleases
        let clearsAllProductAuthority = prepared.catalog == nil
            && prepared.deviceLegSnapshot == nil

        if hasSameReleaseAuthority(as: installed) {
            // Disk admission and a concurrent network refresh can authenticate
            // the same profile while a restored presentation is acquiring its
            // artifacts. Preserve that exact in-flight work; cancellation is
            // reserved for a real identity, delivery-origin, or mode change.
            releasesByVersion = installed
            if clearsAllProductAuthority {
                productMappingsByReleaseAndID.removeAll()
                productMappingsByReleaseAndStoreID.removeAll()
            } else {
                productMappingsByReleaseAndID.merge(productMappings.byID) {
                    current, _ in current
                }
                productMappingsByReleaseAndStoreID.merge(productMappings.byStoreID) {
                    current, _ in current
                }
            }
            if authorityChanged || allowancesChanged {
                await notifyProductAuthorityChanged()
            }
            return makeRoutingCatalog(
                generation: generation ?? latestProfileGeneration,
                references: prepared.references ?? [],
                releases: installed
            )
        }

        cancelWarmTasks()
        finishPreloadAccounting(cancelled: true)
        cancelPendingPreparations()
        experiencesByVersion.removeAll()
        releasesByVersion = installed
        if clearsAllProductAuthority {
            productMappingsByReleaseAndID.removeAll()
            productMappingsByReleaseAndStoreID.removeAll()
        } else {
            productMappingsByReleaseAndID.merge(productMappings.byID) {
                current, _ in current
            }
            productMappingsByReleaseAndStoreID.merge(productMappings.byStoreID) {
                current, _ in current
            }
        }
        preparedReleasesByVersion = preparedReleasesByVersion.filter { key, stored in
            installed[key]?.releaseID == stored.releaseID
        }
        await interactivePreparationCache.retainPreparations(
            for: Set(installed.values.map { $0.releaseID.descriptorSHA256 })
        )
        guard generation == nil || generation == latestProfileGeneration,
              admission?() != false else { return nil }
        preloadMetricsByRelease.removeAll()
        reportedPreloadMetricsByRelease.removeAll()
        beginWarming(installed.values)
        if authorityChanged || allowancesChanged {
            await notifyProductAuthorityChanged()
        }
        return makeRoutingCatalog(
            generation: generation ?? latestProfileGeneration,
            references: prepared.references ?? [],
            releases: installed
        )
    }

    private func makeRoutingCatalog(
        generation: UInt64,
        references: [ExperienceReference],
        releases: [ExperienceVersionKey: AuthenticatedExperienceReleaseDefinition]
    ) -> ExperienceRoutingCatalog {
        ExperienceRoutingCatalog(
            generation: generation,
            references: references
        ) { experienceId, versionId in
            let key = ExperienceVersionKey(
                experienceId: experienceId,
                versionId: versionId
            )
            guard let release = releases[key],
                  let assetBaseURL = URL(string: release.delivery.assetBaseUrl) else {
                throw ExperienceReleaseAcquisitionError.invalidProfileEntry
            }
            return Experience(
                behavior: release.behavior,
                journey: release.journey,
                definition: release.definition,
                assetBaseURL: assetBaseURL,
                authenticatedReleaseID: release.releaseID
            )
        }
    }

    func setProductAuthorityChangeHandler(
        _ handler: @escaping @Sendable () async -> Void
    ) async {
        productAuthorityChangeHandler = handler
        guard productAuthorityCatalog != nil,
              pendingProductAuthorityChangeNotification else { return }
        pendingProductAuthorityChangeNotification = false
        await handler()
    }

    private func notifyProductAuthorityChanged() async {
        guard let productAuthorityChangeHandler else {
            pendingProductAuthorityChangeNotification = true
            return
        }
        await productAuthorityChangeHandler()
    }

    private func hasSameReleaseAuthority(
        as installed: [ExperienceVersionKey: AuthenticatedExperienceReleaseDefinition]
    ) -> Bool {
        guard installed.count == releasesByVersion.count else { return false }
        return installed.allSatisfy { key, definition in
            guard let current = releasesByVersion[key] else { return false }
            return current.releaseID == definition.releaseID
                && current.delivery == definition.delivery
                && current.mode == definition.mode
        }
    }

    private func makeProductCatalogReleases(
        legacyDefinitions: Dictionary<ExperienceVersionKey,
            AuthenticatedExperienceReleaseDefinition>.Values,
        deviceLegSnapshot: DeviceLegProfileCatalog.Snapshot?
    ) throws -> [ProductCatalogRelease] {
        var releases = legacyDefinitions.map { definition in
            ProductCatalogRelease(
                releaseID: definition.releaseID,
                isActive: definition.mode == .active,
                products: definition.products
            )
        }
        guard let deviceLegSnapshot else { return releases }
        let activeDigests = Set(deviceLegSnapshot.profile.armedLegs.compactMap {
            $0.binding.type == .new ? $0.reference.descriptorSha256 : nil
        })
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for release in deviceLegSnapshot.releasesByDigest.values {
            let products = try decoder.decode(
                [ExperienceReleaseProductDocument].self,
                from: encoder.encode(release.descriptor.products)
            )
            releases.append(ProductCatalogRelease(
                releaseID: .init(
                    identity: release.descriptor.identity,
                    descriptorSHA256: release.descriptorSHA256
                ),
                isActive: activeDigests.contains(release.descriptorSHA256),
                products: products
            ))
        }
        return releases
    }

    private func makeProductMappingCache(
        _ definitions: [ProductCatalogRelease]
    ) -> (
        byID: [String: ExperienceReleaseProductDocument],
        byStoreID: [String: ExperienceReleaseProductDocument]
    ) {
        var byID: [String: ExperienceReleaseProductDocument] = [:]
        var byStoreID: [String: ExperienceReleaseProductDocument] = [:]
        for definition in definitions {
            let releaseKey = definition.releaseID.descriptorSHA256
            for product in definition.products {
                let productKey = "\(releaseKey)\u{0}\(product.id)"
                let storeKey = "\(releaseKey)\u{0}\(product.store.platform)\u{0}"
                    + product.store.productId
                byID[productKey] = product
                byStoreID[storeKey] = product
            }
        }
        return (byID, byStoreID)
    }

    private func makeProductAuthorityCatalog(
        _ definitions: [ProductCatalogRelease]
    ) -> [String: ActiveProductEvidenceAuthorityResolution] {
        let products = definitions
            .filter(\.isActive)
            .flatMap(\.products)
        let storeProductIds = Set(products.compactMap { product in
            product.store.platform == "apple_app_store"
                ? product.store.productId
                : nil
        })
        return Dictionary(uniqueKeysWithValues: storeProductIds.map { storeProductId in
            (
                storeProductId,
                activeProductEvidenceAuthority(
                    products: products,
                    storeProductId: storeProductId
                )
            )
        })
    }

    private func makeOptimisticAllowanceCatalog(
        _ definitions: [ProductCatalogRelease]
    ) -> [OptimisticAllowanceCatalogKey: [OptimisticEntitlementAllowance]] {
        var catalog: [
            OptimisticAllowanceCatalogKey: [OptimisticEntitlementAllowance]
        ] = [:]
        for definition in definitions {
            for product in definition.products {
                let key = OptimisticAllowanceCatalogKey(
                    releaseID: definition.releaseID,
                    isActive: definition.isActive,
                    productID: product.id,
                    platform: product.store.platform,
                    storeProductID: product.store.productId
                )
                catalog[key] = product.entitlements.map {
                    OptimisticEntitlementAllowance(
                        featureId: $0.featureId ?? $0.id,
                        featureExternalId: $0.featureExternalId,
                        allowanceType: $0.allowanceType,
                        allowance: $0.allowance
                    )
                }
            }
        }
        return catalog
    }

    private func installProductAuthorityCatalog(
        _ catalog: [String: ActiveProductEvidenceAuthorityResolution]
    ) -> Bool {
        let changed = productAuthorityCatalog != catalog
        productAuthorityCatalog = catalog
        return changed
    }

    private func installOptimisticAllowanceCatalog(
        _ catalog: [OptimisticAllowanceCatalogKey: [OptimisticEntitlementAllowance]]
    ) -> Bool {
        let changed = optimisticAllowanceCatalog != catalog
        optimisticAllowanceCatalog = catalog
        return changed
    }

    /// Resolves current receipt ownership from the authenticated active release
    /// set. Conflicting active Products fail closed instead of depending on
    /// dictionary iteration order.
    func purchaseEvidenceAuthority(
        storeProductId: String
    ) -> ActiveProductEvidenceAuthorityResolution {
        guard let productAuthorityCatalog else { return .unavailable }
        return productAuthorityCatalog[storeProductId] ?? .readyNoMatch
    }

    func optimisticEntitlementAllowances(
        releaseDescriptorSHA256: String?,
        productId: String?,
        storeProductId: String
    ) async -> [OptimisticEntitlementAllowance]? {
        let product: ExperienceReleaseProductDocument?
        if let releaseDescriptorSHA256, let productId {
            product = await cachedProductMapping(
                releaseDescriptorSHA256: releaseDescriptorSHA256,
                productID: productId
            )
        } else {
            let matches = productCatalogReleases
                .filter(\.isActive)
                .flatMap(\.products)
                .filter {
                    $0.store.platform == "apple_app_store"
                        && $0.store.productId == storeProductId
                }
            guard let first = matches.first,
                  matches.dropFirst().allSatisfy({ $0.entitlements == first.entitlements }) else {
                return nil
            }
            product = first
        }
        guard let product else { return nil }
        return product.entitlements.map {
            OptimisticEntitlementAllowance(
                featureId: $0.featureId ?? $0.id,
                featureExternalId: $0.featureExternalId,
                allowanceType: $0.allowanceType,
                allowance: $0.allowance
            )
        }
    }

    /// Returns authenticated Product authority without requiring an Experience
    /// or paywall to be loaded. Restore and optimistic projection use this seam.
    func cachedProductMapping(
        releaseDescriptorSHA256: String,
        productID: String
    ) async -> ExperienceReleaseProductDocument? {
        let key = "\(releaseDescriptorSHA256)\u{0}\(productID)"
        if let cached = productMappingsByReleaseAndID[key] { return cached }
        await rehydrateProductMappings(for: releaseDescriptorSHA256)
        return productMappingsByReleaseAndID[key]
    }

    /// Resolves authenticated Product authority from a native store identity.
    func cachedProductMapping(
        releaseDescriptorSHA256: String,
        platform: String,
        storeProductID: String
    ) async -> ExperienceReleaseProductDocument? {
        let key = "\(releaseDescriptorSHA256)\u{0}\(platform)\u{0}\(storeProductID)"
        if let cached = productMappingsByReleaseAndStoreID[key] { return cached }
        await rehydrateProductMappings(for: releaseDescriptorSHA256)
        return productMappingsByReleaseAndStoreID[key]
    }

    private func rehydrateProductMappings(for descriptorSHA256: String) async {
        guard let products = await releaseStore.cachedProducts(
            descriptorSHA256: descriptorSHA256
        ) else { return }
        for product in products {
            productMappingsByReleaseAndID[
                "\(descriptorSHA256)\u{0}\(product.id)"
            ] = product
            productMappingsByReleaseAndStoreID[
                "\(descriptorSHA256)\u{0}\(product.store.platform)\u{0}"
                    + product.store.productId
            ] = product
        }
    }

    func clearCache() async {
        cancelWarmTasks()
        finishPreloadAccounting(cancelled: true)
        cancelPendingPreparations()
        experiencesByVersion.removeAll()
        releasesByVersion.removeAll()
        productMappingsByReleaseAndID.removeAll()
        productMappingsByReleaseAndStoreID.removeAll()
        productCatalogReleases.removeAll()
        preparedReleasesByVersion.removeAll()
        await interactivePreparationCache.removeAll()
        preloadMetricsByRelease.removeAll()
        reportedPreloadMetricsByRelease.removeAll()
        productAuthorityCatalog = nil
        optimisticAllowanceCatalog = nil
        pendingProductAuthorityChangeNotification = false
    }

    /// Drops memory-heavy prepared bytes while retaining authenticated
    /// descriptor authority. A later presentation can safely rehydrate from
    /// the verified content-addressed disk cache.
    func handleMemoryPressure() async {
        cancelWarmTasks()
        finishPreloadAccounting(cancelled: true)
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
        warmLoadsPermanentlySuspended = true
        cancelWarmTasks()
        finishPreloadAccounting(cancelled: true)
        cancelPendingPreparations()
        preparedReleasesByVersion.removeAll()
        await interactivePreparationCache.removeAll()
    }

    func onAppDidEnterBackground() {
        warmLoadsPausedForBackground = true
        cancelWarmTasks()
        cancelPendingPreloadPreparations()
        finishPreloadAccounting(cancelled: true)
    }

    func onAppBecameActive() {
        guard warmLoadsPausedForBackground else { return }
        warmLoadsPausedForBackground = false
        beginWarming(releasesByVersion.values)
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
        if let cached = experiencesByVersion[key] {
            return cached
        }
        let releaseID = release.releaseID
        guard release.reference.experienceId == experienceId,
              release.reference.versionId == versionId,
              let assetBaseURL = URL(string: release.delivery.assetBaseUrl) else {
            throw ExperienceReleaseAcquisitionError.invalidProfileEntry
        }
        let experience = Experience(
            behavior: release.behavior,
            journey: release.journey,
            definition: release.definition,
            assetBaseURL: assetBaseURL,
            authenticatedReleaseID: releaseID
        )
        guard releasesByVersion[key]?.releaseID == releaseID else {
            throw CancellationError()
        }
        experiencesByVersion[key] = experience
        return experience
    }

    /// Resolves StoreKit only when the exact authenticated screen consumes a
    /// product-bound view-model value for its first frame. Product failures on
    /// unrelated screens never block reveal.
    func experienceForPresentation(
        experienceId: String,
        versionId: String,
        initialScreenID: String,
        presentationTraceContext: ExperiencePresentationTraceContext? = nil,
        introEligibilityAuthorization: IntroEligibilityAuthorizationContext? = nil
    ) async throws -> Experience {
        let key = ExperienceVersionKey(
            experienceId: experienceId,
            versionId: versionId
        )
        guard let release = releasesByVersion[key] else {
            throw ExperienceReleaseAcquisitionError.invalidProfileEntry
        }
        let base = try await experience(
            experienceId: experienceId,
            versionId: versionId
        )
        let placementIDs = requiredPlacementIDs(for: initialScreenID, in: release)
        guard !placementIDs.isEmpty else {
            return base.scopedForPresentation(
                products: [],
                introEligibilityAuthorization: introEligibilityAuthorization
            )
        }
        let productIDs = requiredProductIDs(for: initialScreenID, in: release)
        guard !productIDs.isEmpty else { throw ExperienceError.productsUnavailable }
        let productSpan = presentationTraceContext?.begin(
            .storeKitProductLookup,
            attributes: [
                "product_count": String(productIDs.count),
                "screen_id": initialScreenID,
            ]
        )
        let products: [StoreProduct]
        do {
            // Storefront, price, billing plans, and introductory eligibility
            // are presentation-time facts. Keep release/artifact caches warm,
            // but never reuse a prior presentation's commercial resolution.
            await productService.invalidate(productIDs)
            products = try await fetchProducts(
                for: initialScreenID,
                in: release,
                introEligibilityAuthorization: introEligibilityAuthorization
            )
            guard Set(products.map(\.storeProductId)) == productIDs,
                  Set(products.map(\.placementId)) == placementIDs else {
                throw ExperienceError.productsUnavailable
            }
            if let productSpan { presentationTraceContext?.complete(productSpan) }
        } catch {
            if let productSpan {
                presentationTraceContext?.fail(productSpan, error: error)
            }
            if error is CancellationError { throw error }
            throw ExperienceError.productsUnavailable
        }
        guard releasesByVersion[key]?.releaseID == release.releaseID else {
            throw CancellationError()
        }
        return base.scopedForPresentation(
            products: products,
            introEligibilityAuthorization: introEligibilityAuthorization
        )
    }

    func experienceForPresentation(
        versionId: String,
        initialScreenID: String,
        presentationTraceContext: ExperiencePresentationTraceContext? = nil,
        introEligibilityAuthorization: IntroEligibilityAuthorizationContext? = nil
    ) async throws -> Experience {
        let references = releasesByVersion.values.filter {
            $0.reference.versionId == versionId
        }.map(\.reference)
        guard references.count == 1, let reference = references.first else {
            throw ExperienceReleaseAcquisitionError.invalidProfileEntry
        }
        return try await experienceForPresentation(
            experienceId: reference.experienceId,
            versionId: reference.versionId,
            initialScreenID: initialScreenID,
            presentationTraceContext: presentationTraceContext,
            introEligibilityAuthorization: introEligibilityAuthorization
        )
    }

    /// Returns a presentation-scoped copy of the authenticated release when
    /// the Journey has not selected a screen yet. Products remain lazy, but
    /// the current Journey authority travels with the copy and never enters
    /// the release cache.
    func experienceForPresentation(
        versionId: String,
        introEligibilityAuthorization: IntroEligibilityAuthorizationContext?
    ) async throws -> Experience {
        let base = try await experience(versionId: versionId)
        return base.scopedForPresentation(
            products: [],
            introEligibilityAuthorization: introEligibilityAuthorization
        )
    }

    func productsForDeviceLegPresentation(
        release: AuthenticatedDeviceLegRelease,
        screenID: String,
        introEligibilityAuthorization: IntroEligibilityAuthorizationContext? = nil
    ) async throws -> [StoreProduct] {
        let authority: ProductReleaseAuthority
        do {
            authority = try productAuthority(release, screenID: screenID)
        } catch {
            throw ExperienceError.productsUnavailable
        }
        let placementIDs = requiredPlacementIDs(
            for: screenID,
            in: authority
        )
        guard !placementIDs.isEmpty else { return [] }
        let productIDs = requiredProductIDs(
            for: screenID,
            in: authority
        )
        guard !productIDs.isEmpty else {
            throw ExperienceError.productsUnavailable
        }
        do {
            await productService.invalidate(productIDs)
            let products = try await fetchProducts(
                for: screenID,
                in: authority,
                introEligibilityAuthorization: introEligibilityAuthorization
            )
            guard Set(products.map(\.storeProductId)) == productIDs,
                  Set(products.map(\.placementId)) == placementIDs else {
                throw ExperienceError.productsUnavailable
            }
            return products
        } catch {
            if error is CancellationError { throw error }
            throw ExperienceError.productsUnavailable
        }
    }

    private func productAuthority(
        _ release: AuthenticatedExperienceReleaseDefinition
    ) -> ProductReleaseAuthority {
        ProductReleaseAuthority(
            releaseID: release.releaseID,
            journey: release.journey,
            definition: release.definition,
            products: release.products,
            placements: release.placements,
            additionalPlacementIDs: [],
            hasDynamicPurchase: false
        )
    }

    private func productAuthority(
        _ release: AuthenticatedDeviceLegRelease,
        screenID: String
    ) throws -> ProductReleaseAuthority {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let products = try decoder.decode(
            [ExperienceReleaseProductDocument].self,
            from: encoder.encode(release.descriptor.products)
        )
        let placements = try decoder.decode(
            [ExperienceReleasePlacementDocument].self,
            from: encoder.encode(release.descriptor.placements)
        )
        let flatRequirements = flatProductRequirements(
            for: screenID,
            in: release.descriptor.leg
        )
        let definition = try ExperienceDefinition(
            deviceLegDescriptor: release.descriptor
        )
        return ProductReleaseAuthority(
            releaseID: .init(
                identity: release.descriptor.identity,
                descriptorSHA256: release.descriptorSHA256
            ),
            journey: definition.renderShell,
            definition: definition,
            products: products,
            placements: placements,
            additionalPlacementIDs: flatRequirements.placementIDs,
            hasDynamicPurchase: flatRequirements.hasDynamicPurchase
        )
    }

    private func flatProductRequirements(
        for screenID: String,
        in leg: DeviceLeg
    ) -> (placementIDs: Set<String>, hasDynamicPurchase: Bool) {
        var stepsByID: [String: DeviceLeg.Step] = [:]
        for step in leg.steps {
            stepsByID[step.id] = step
        }
        var pending = leg.routes.compactMap { route -> String? in
            switch route.host.kind {
            case .journey:
                return route.entryStepId
            case .screen where route.host.screenId == screenID:
                return route.entryStepId
            case .screen:
                return nil
            }
        }
        var visited: Set<String> = []
        var placementIDs: Set<String> = []
        var hasDynamicPurchase = false

        while let stepID = pending.popLast() {
            guard visited.insert(stepID).inserted,
                  let step = stepsByID[stepID] else {
                continue
            }
            if case .string("navigate")? = step.action?["type"] {
                // The destination screen resolves its own first-frame and
                // reachable-action products when navigation reaches it.
                continue
            }
            if case .string("purchase")? = step.action?["type"] {
                switch step.action?["placementId"] {
                case .string(let placementID):
                    placementIDs.insert(placementID)
                case .object(let wrapped):
                    if case .string(let placementID)? = wrapped["literal"] {
                        placementIDs.insert(placementID)
                    } else {
                        hasDynamicPurchase = true
                    }
                default:
                    hasDynamicPurchase = true
                }
            }
            if let outlets = step.outlets {
                pending.append(contentsOf: outlets.values)
            }
        }
        return (placementIDs, hasDynamicPurchase)
    }

    private func requiredProductIDs(
        for screenID: String,
        in release: AuthenticatedExperienceReleaseDefinition
    ) -> Set<String> {
        requiredProductIDs(
            for: screenID,
            in: productAuthority(release)
        )
    }

    private func requiredProductIDs(
        for screenID: String,
        in release: ProductReleaseAuthority
    ) -> Set<String> {
        Set(appleProductBindings(for: screenID, in: release).map {
            $0.product.store.productId
        })
    }

    private func requiredPlacementIDs(
        for screenID: String,
        in release: AuthenticatedExperienceReleaseDefinition
    ) -> Set<String> {
        requiredPlacementIDs(
            for: screenID,
            in: productAuthority(release)
        )
    }

    private func requiredPlacementIDs(
        for screenID: String,
        in release: ProductReleaseAuthority
    ) -> Set<String> {
        guard let screen = release.journey.screens.first(where: { $0.id == screenID }) else {
            return []
        }
        let values = release.journey.viewModelValues ?? []
        var referenced: Set<String> = []
        var pendingValueGroups: [[JourneyViewModelValue]] = []
        if let viewModelName = screen.defaultViewModelName {
            pendingValueGroups.append(values.filter {
                $0.viewModelName == viewModelName && isRootValue($0, for: screen)
            })
        }
        var visitedIdentities: Set<ProductViewModelIdentity> = []

        while let group = pendingValueGroups.popLast() {
            var linkedIdentities = linkedViewModelIdentities(in: group)
            for value in group {
                if value.path.split(separator: "/").last == "placementId",
                   let placementID = value.value.value as? String {
                    referenced.insert(placementID)
                }
                collectPlacementIDs(in: value.value.value, into: &referenced)
                collectLinkedViewModelIdentities(
                    in: value.value.value,
                    into: &linkedIdentities
                )
            }
            for identity in linkedIdentities where visitedIdentities.insert(identity).inserted {
                let linkedValues = values.filter { identity.matches($0) }
                if !linkedValues.isEmpty {
                    pendingValueGroups.append(linkedValues)
                }
            }
        }
        let devicePrograms: [JourneyAction] = release.definition.executionPlans.flatMap { plan -> [JourneyAction] in
            switch plan.route.host {
            case .journey:
                break
            case .screen(let routeScreenID) where routeScreenID == screenID:
                break
            case .screen:
                return []
            }
            guard let route = release.definition.routes[plan.route] else { return [] }
            return plan.deviceRegions.reduce(into: [JourneyAction]()) { actions, region in
                actions.append(contentsOf: (try? release.definition.compiledDeviceRegionProgram(
                    route,
                    plan: plan,
                    region: region
                )) ?? [])
            }
        }
        collectPurchasePlacementIDs(in: devicePrograms, into: &referenced)
        referenced.formUnion(release.additionalPlacementIDs)
        // A purchase may resolve its placement from Response.Field,
        // Event.Field, or another runtime value. There is no safe placement
        // identity to derive during release admission in that case, while
        // ExperienceViewController requires the StoreKit product to already
        // be present when the action fires. Preload every signed Apple
        // placement whenever the reachable program contains a dynamic
        // purchase; the signed release remains the authority and malformed
        // references still fail closed at checkout.
        if containsDynamicPurchase(in: devicePrograms)
            || release.hasDynamicPurchase {
            let appleProductIDs = Set(
                release.products
                    .filter { $0.store.platform == "apple_app_store" }
                    .map(\.id)
            )
            referenced.formUnion(
                release.placements
                    .filter { appleProductIDs.contains($0.productId) }
                    .map(\.id)
            )
        }
        // Keep undeclared references in the required set. The callers compare
        // this set with authenticated Placement bindings and fail closed when a
        // signed view model points at a Placement that the release did not
        // declare. Intersecting here would incorrectly turn that malformed
        // commercial screen into a product-free screen and reveal preview copy.
        return referenced
    }

    private func collectPurchasePlacementIDs(
        in actions: [JourneyAction],
        into result: inout Set<String>
    ) {
        for action in actions {
            switch action {
            case .purchase(let purchase):
                if let placementID = literalPlacementID(purchase.placementId.value) {
                    result.insert(placementID)
                }
                collectPurchasePlacementIDs(in: purchase.onCompleted ?? [], into: &result)
                collectPurchasePlacementIDs(in: purchase.onFailed ?? [], into: &result)
                collectPurchasePlacementIDs(in: purchase.onCancelled ?? [], into: &result)
            case .timeWindow(let window):
                collectPurchasePlacementIDs(in: window.onInside, into: &result)
            case .waitUntil(let wait):
                collectPurchasePlacementIDs(in: wait.onSatisfied, into: &result)
                collectPurchasePlacementIDs(in: wait.onTimeout, into: &result)
            case .condition(let condition):
                for branch in condition.branches {
                    collectPurchasePlacementIDs(in: branch.program, into: &result)
                }
                collectPurchasePlacementIDs(in: condition.defaultProgram, into: &result)
            case .experiment(let experiment):
                for variant in experiment.variants {
                    collectPurchasePlacementIDs(in: variant.program, into: &result)
                }
            case .restore(let restore):
                collectPurchasePlacementIDs(in: restore.onRestored ?? [], into: &result)
                collectPurchasePlacementIDs(in: restore.onNoPurchases ?? [], into: &result)
                collectPurchasePlacementIDs(in: restore.onFailed ?? [], into: &result)
            case .connectorAction(let connector):
                collectPurchasePlacementIDs(in: connector.onSucceeded ?? [], into: &result)
                collectPurchasePlacementIDs(in: connector.onFailed ?? [], into: &result)
                collectPurchasePlacementIDs(in: connector.onTimeout ?? [], into: &result)
            default:
                continue
            }
        }
    }

    private func containsDynamicPurchase(in actions: [JourneyAction]) -> Bool {
        for action in actions {
            switch action {
            case .purchase(let purchase):
                if literalPlacementID(purchase.placementId.value) == nil { return true }
                if containsDynamicPurchase(in: purchase.onCompleted ?? [])
                    || containsDynamicPurchase(in: purchase.onFailed ?? [])
                    || containsDynamicPurchase(in: purchase.onCancelled ?? []) {
                    return true
                }
            case .timeWindow(let window):
                if containsDynamicPurchase(in: window.onInside) { return true }
            case .waitUntil(let wait):
                if containsDynamicPurchase(in: wait.onSatisfied)
                    || containsDynamicPurchase(in: wait.onTimeout) { return true }
            case .condition(let condition):
                if condition.branches.contains(where: {
                    containsDynamicPurchase(in: $0.program)
                }) || containsDynamicPurchase(in: condition.defaultProgram) {
                    return true
                }
            case .experiment(let experiment):
                if experiment.variants.contains(where: {
                    containsDynamicPurchase(in: $0.program)
                }) { return true }
            case .restore(let restore):
                if containsDynamicPurchase(in: restore.onRestored ?? [])
                    || containsDynamicPurchase(in: restore.onNoPurchases ?? [])
                    || containsDynamicPurchase(in: restore.onFailed ?? []) { return true }
            case .connectorAction(let connector):
                if containsDynamicPurchase(in: connector.onSucceeded ?? [])
                    || containsDynamicPurchase(in: connector.onFailed ?? [])
                    || containsDynamicPurchase(in: connector.onTimeout ?? []) { return true }
            default:
                continue
            }
        }
        return false
    }

    private func literalPlacementID(_ value: Any) -> String? {
        if let value = value as? String { return value }
        if let fields = dictionary(from: value) {
            return fields["literal"] as? String
        }
        return nil
    }

    private struct ProductViewModelIdentity: Hashable {
        let viewModelName: String?
        let instanceID: String

        func matches(_ value: JourneyViewModelValue) -> Bool {
            value.instanceId == instanceID
                && (viewModelName == nil || value.viewModelName == viewModelName)
        }
    }

    private func linkedViewModelIdentities(
        in values: [JourneyViewModelValue]
    ) -> Set<ProductViewModelIdentity> {
        struct FlattenedIdentity {
            var viewModelName: String? = nil
            var instanceID: String? = nil
        }
        var flattened: [String: FlattenedIdentity] = [:]
        for value in values {
            let segments = value.path.split(separator: "/").map(String.init)
            guard segments.count >= 2, let field = segments.last else { continue }
            guard field == "viewModelId" || field == "vmInstanceId" || field == "instanceId" else {
                continue
            }
            let key = segments.dropLast().joined(separator: "/")
            var identity = flattened[key, default: .init()]
            if field == "viewModelId" {
                identity.viewModelName = value.value.value as? String
            } else {
                identity.instanceID = value.value.value as? String
            }
            flattened[key] = identity
        }
        return Set(flattened.values.compactMap { identity in
            guard let instanceID = identity.instanceID, !instanceID.isEmpty else { return nil }
            return ProductViewModelIdentity(
                viewModelName: identity.viewModelName,
                instanceID: instanceID
            )
        })
    }

    private func collectLinkedViewModelIdentities(
        in value: Any,
        into result: inout Set<ProductViewModelIdentity>
    ) {
        if let fields = dictionary(from: value) {
            let viewModelName = fields["viewModelId"] as? String
            let instanceID = (fields["vmInstanceId"] as? String)
                ?? (fields["instanceId"] as? String)
            if let instanceID, !instanceID.isEmpty {
                result.insert(.init(
                    viewModelName: viewModelName,
                    instanceID: instanceID
                ))
            }
            for nested in fields.values {
                collectLinkedViewModelIdentities(in: nested, into: &result)
            }
        } else if let values = array(from: value) {
            for nested in values {
                collectLinkedViewModelIdentities(in: nested, into: &result)
            }
        }
    }

    private func isRootValue(
        _ value: JourneyViewModelValue,
        for screen: JourneyScreen
    ) -> Bool {
        if let instanceID = value.instanceId {
            return instanceID == screen.defaultInstanceId
        }
        return value.instanceName == nil
    }

    private func collectPlacementIDs(in value: Any, into result: inout Set<String>) {
        if let fields = dictionary(from: value) {
            if let placementID = fields["placementId"] as? String {
                result.insert(placementID)
            }
            for nested in fields.values {
                collectPlacementIDs(in: nested, into: &result)
            }
        } else if let values = array(from: value) {
            for nested in values {
                collectPlacementIDs(in: nested, into: &result)
            }
        }
    }

    private func dictionary(from value: Any) -> [String: Any]? {
        if let value = value as? AnyCodable {
            return dictionary(from: value.value)
        }
        if let value = value as? [String: Any] { return value }
        if let value = value as? [String: AnyCodable] {
            return value.mapValues(\.value)
        }
        return nil
    }

    private func array(from value: Any) -> [Any]? {
        if let value = value as? AnyCodable {
            return array(from: value.value)
        }
        if let value = value as? [Any] { return value }
        if let value = value as? [AnyCodable] { return value.map(\.value) }
        return nil
    }

    private func appleProductBindings(
        for screenID: String,
        in release: AuthenticatedExperienceReleaseDefinition
    ) -> [(placement: ExperienceReleasePlacementDocument, product: ExperienceReleaseProductDocument)] {
        appleProductBindings(
            for: screenID,
            in: productAuthority(release)
        )
    }

    private func appleProductBindings(
        for screenID: String,
        in release: ProductReleaseAuthority
    ) -> [(placement: ExperienceReleasePlacementDocument, product: ExperienceReleaseProductDocument)] {
        let placementIDs = requiredPlacementIDs(for: screenID, in: release)
        let productsByID = Dictionary(uniqueKeysWithValues: release.products.map { ($0.id, $0) })
        return release.placements.compactMap { placement in
            guard placementIDs.contains(placement.id),
                  let product = productsByID[placement.productId],
                  product.store.platform == "apple_app_store" else { return nil }
            return (placement, product)
        }
    }

    private func productsForPresentation(
        key: ExperienceVersionKey,
        releaseID: AuthenticatedExperienceReleaseID,
        screenID: String,
        presentationTraceContext: ExperiencePresentationTraceContext?,
        introEligibilityAuthorization: IntroEligibilityAuthorizationContext?
    ) async throws -> [StoreProduct] {
        guard let release = releasesByVersion[key], release.releaseID == releaseID else {
            throw CancellationError()
        }
        let placementIDs = requiredPlacementIDs(for: screenID, in: release)
        guard !placementIDs.isEmpty else { return [] }
        let productIDs = requiredProductIDs(for: screenID, in: release)
        guard !productIDs.isEmpty else { throw ExperienceError.productsUnavailable }
        let span = presentationTraceContext?.begin(
            .storeKitProductLookup,
            attributes: [
                "product_count": String(productIDs.count),
                "screen_id": screenID,
            ]
        )
        do {
            await productService.invalidate(productIDs)
            let products = try await fetchProducts(
                for: screenID,
                in: release,
                introEligibilityAuthorization: introEligibilityAuthorization
            )
            guard Set(products.map(\.storeProductId)) == productIDs,
                  Set(products.map(\.placementId)) == placementIDs,
                  releasesByVersion[key]?.releaseID == releaseID else {
                throw ExperienceError.productsUnavailable
            }
            if let span { presentationTraceContext?.complete(span) }
            return products
        } catch {
            if let span { presentationTraceContext?.fail(span, error: error) }
            if error is CancellationError { throw error }
            throw ExperienceError.productsUnavailable
        }
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
            definition: release.definition,
            assetBaseURL: assetBaseURL,
            authenticatedReleaseID: release.releaseID
        )
    }

    func validatesPresentationCommit(_ commit: JourneyPendingPresentation) -> Bool {
        guard let releaseID = commit.releaseID else { return false }
        let key = ExperienceVersionKey(
            experienceId: commit.experienceId,
            versionId: commit.experienceVersionId
        )
        return releasesByVersion[key]?.releaseID == releaseID
    }

    func isPresentationMemoryWarm(_ commit: JourneyPendingPresentation) async -> Bool {
        guard let releaseID = commit.releaseID else { return false }
        let key = ExperienceVersionKey(
            experienceId: commit.experienceId,
            versionId: commit.experienceVersionId
        )
        return await isPresentationMemoryWarm(key: key, releaseID: releaseID)
    }

    func isPresentationMemoryWarm(for experience: Experience) async -> Bool {
        guard let releaseID = experience.authenticatedReleaseID else { return false }
        let key = ExperienceVersionKey(
            experienceId: experience.id,
            versionId: experience.versionId
        )
        return await isPresentationMemoryWarm(key: key, releaseID: releaseID)
    }

    func reserveMemoryWarmPresentation(
        for experience: Experience
    ) async -> ExperiencePresentationWarmReservation? {
        guard let releaseID = experience.authenticatedReleaseID else { return nil }
        let key = ExperienceVersionKey(
            experienceId: experience.id,
            versionId: experience.versionId
        )
        return await reserveMemoryWarmPresentation(key: key, releaseID: releaseID)
    }

    private func isPresentationMemoryWarm(
        key: ExperienceVersionKey,
        releaseID: AuthenticatedExperienceReleaseID
    ) async -> Bool {
        guard releasesByVersion[key]?.releaseID == releaseID,
              let prepared = preparedReleasesByVersion[key],
              prepared.releaseID == releaseID else {
            return false
        }
        return await prepared.runtime.interactivePreparation.status() == .prepared
    }

    private func reserveMemoryWarmPresentation(
        key: ExperienceVersionKey,
        releaseID: AuthenticatedExperienceReleaseID
    ) async -> ExperiencePresentationWarmReservation? {
        guard releasesByVersion[key]?.releaseID == releaseID,
              let prepared = preparedReleasesByVersion[key],
              prepared.releaseID == releaseID else {
            return nil
        }
        guard let reservation = await prepared.runtime.interactivePreparation
            .reserveIfPrepared() else {
            return nil
        }
        guard releasesByVersion[key]?.releaseID == releaseID,
              preparedReleasesByVersion[key]?.releaseID == releaseID else {
            reservation.release()
            return nil
        }
        return reservation
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
              experience.authenticatedReleaseID == release.releaseID else {
            throw CancellationError()
        }
        let selectedScreenID: String
        if let initialScreenID, release.screenIDs.contains(initialScreenID) {
            selectedScreenID = initialScreenID
        } else if initialScreenID == nil, release.screenIDs.count == 1,
                  let soleScreenID = release.screenIDs.first {
            selectedScreenID = soleScreenID
        } else {
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
                resourceMetricOwner: .presentation,
                intent: .presentation
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
        let requiredPlacementIDs = requiredPlacementIDs(
            for: selectedScreenID,
            in: release
        )
        let productsResolvedForScreenID =
            requiredPlacementIDs.isEmpty
            || Set(experience.products.map(\.placementId)) == requiredPlacementIDs
                ? selectedScreenID
                : nil
        return try runtime.acquired.presentationArtifact(
            identity: .init(
                experienceId: release.reference.experienceId,
                buildId: release.behavior.buildId
            ),
            initialScreenID: selectedScreenID,
            interactivePreparation: runtime.interactivePreparation,
            products: experience.products,
            productsResolvedForScreenID: productsResolvedForScreenID,
            resourceMetrics: acquisitionMetrics,
            productResolver: { [weak self] screenID in
                guard let self else { throw CancellationError() }
                return try await self.productsForPresentation(
                    key: key,
                    releaseID: release.releaseID,
                    screenID: screenID,
                    presentationTraceContext: presentationTraceContext,
                    introEligibilityAuthorization: experience.introEligibilityAuthorization
                )
            }
        )
    }

    private func preparedRelease(
        for key: ExperienceVersionKey,
        release: AuthenticatedExperienceReleaseDefinition,
        resourceMetricOwner: ExperienceReleaseResourceMetricOwner,
        intent: ExperienceReleasePreparationIntent
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
                intent: intent,
                task: Task { [releaseStore] in
                    let acquired = try await releaseStore.prepare(
                        definition: release,
                        intent: intent
                    )
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
        let prepared: PreparedRuntimeRelease
        do {
            prepared = try await load.task.value
        } catch {
            // Preserve useful in-flight preload work on ordinary networks. If
            // constrained speculative work fails, an active presentation gets
            // one fresh attempt with presentation network policy instead of
            // inheriting the preload failure.
            if !ownsLoad,
               intent == .presentation,
               load.intent == .preload,
               !Task.isCancelled,
               releasesByVersion[key]?.releaseID == release.releaseID {
                if pendingPreparations[release.releaseID]?.id == load.id {
                    pendingPreparations[release.releaseID] = nil
                }
                return try await preparedRelease(
                    for: key,
                    release: release,
                    resourceMetricOwner: resourceMetricOwner,
                    intent: .presentation
                )
            }
            throw error
        }
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

    private func cancelPendingPreparations() {
        for pending in pendingPreparations.values { pending.task.cancel() }
        pendingPreparations.removeAll()
    }

    private func cancelPendingPreloadPreparations() {
        let preloadIDs = pendingPreparations.compactMap { releaseID, pending in
            pending.intent == .preload ? releaseID : nil
        }
        for releaseID in preloadIDs {
            pendingPreparations.removeValue(forKey: releaseID)?.task.cancel()
        }
    }

    private func beginWarming(
        _ definitions: Dictionary<ExperienceVersionKey, AuthenticatedExperienceReleaseDefinition>.Values
    ) {
        guard !warmLoadsPermanentlySuspended,
              !warmLoadsPausedForBackground else { return }
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
                resourceMetricOwner: .preload,
                intent: .preload
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

    private func fetchProducts(
        for screenID: String,
        in release: AuthenticatedExperienceReleaseDefinition,
        introEligibilityAuthorization: IntroEligibilityAuthorizationContext? = nil
    ) async throws -> [StoreProduct] {
        try await fetchProducts(
            for: screenID,
            in: productAuthority(release),
            introEligibilityAuthorization: introEligibilityAuthorization
        )
    }

    private func fetchProducts(
        for screenID: String,
        in release: ProductReleaseAuthority,
        introEligibilityAuthorization: IntroEligibilityAuthorizationContext? = nil
    ) async throws -> [StoreProduct] {
        let bindings = appleProductBindings(for: screenID, in: release)
        guard !bindings.isEmpty else { return [] }
        let identifiers = Set(bindings.map { $0.product.store.productId })
        if testStoreEnabled {
            var testProducts: [StoreProduct] = []
            testProducts.reserveCapacity(bindings.count)
            for binding in bindings {
                guard let productType = StoreProductType(
                    rawValue: binding.product.store.productType
                ) else {
                    throw ExperienceError.productsUnavailable
                }
                let preview = binding.product.preview
                let period = ProductPeriod(rawValue: preview.period)
                let trialTerms = Self.testStoreTrialTerms(
                    label: preview.trialLabel,
                    fallbackPeriod: period
                )
                let introductoryTerms: StoreProduct.IntroductoryTerms? = preview.hasTrial
                    ? StoreProduct.IntroductoryTerms(
                        price: "TEST · FREE",
                        period: trialTerms.period,
                        periodCount: trialTerms.periodCount,
                        cycles: 1,
                        paymentMode: .freeTrial,
                        trialPeriodText: preview.trialLabel
                    )
                    : nil
                var testProduct = StoreProduct(
                    productId: binding.product.id,
                    storeProductId: binding.product.store.productId,
                    placementId: binding.placement.id,
                    name: "TEST · \(preview.name)",
                    description: "TEST STORE — no charge. \(preview.description)",
                    price: "TEST · \(preview.price)",
                    period: period,
                    periodCount: preview.periodCount > 0 ? preview.periodCount : nil,
                    periodLabel: preview.periodLabel,
                    renewalPrice: preview.renewalLabel,
                    renewalPeriod: "",
                    productType: productType,
                    introductoryTerms: introductoryTerms
                )
                testProduct.isTestStoreProduct = true
                testProduct.previewIntroOfferLabel = preview.introOfferLabel.isEmpty
                    ? nil
                    : preview.introOfferLabel
                testProduct.localEntitlementGrants = binding.product.entitlements.map {
                    StoreProduct.LocalEntitlementGrant(
                        featureId: $0.featureId ?? $0.id,
                        featureExternalId: $0.featureExternalId,
                        purchaseUsageFeatureIds: $0.purchaseUsageFeatureIds,
                        allowanceType: $0.allowanceType,
                        allowance: $0.allowance
                    )
                }
                testProduct.purchaseContext = PurchaseCommercialContext(
                    release: release.releaseID,
                    placementId: binding.placement.id,
                    productId: binding.product.id,
                    storeProductId: binding.product.store.productId,
                    displayPrice: testProduct.price,
                    price: nil
                )
                testProduct.providerFeatureAccess = binding.product.providerFeatureAccess?.provider
                testProducts.append(testProduct)
            }
            return testProducts
        }
        let resolved = try await productService.fetchProducts(for: identifiers)
        let productsByID = Dictionary(uniqueKeysWithValues: resolved.map { ($0.id, $0) })
        guard productsByID.count == identifiers.count else {
            throw ExperienceError.productsUnavailable
        }
        var storeProducts: [StoreProduct] = []
        storeProducts.reserveCapacity(bindings.count)
        for binding in bindings {
            guard let storeProduct = productsByID[binding.product.store.productId],
                  let productType = StoreProductType(
                    rawValue: binding.product.store.productType
                  ) else {
                throw ExperienceError.productsUnavailable
            }
            var resolvedProduct = try await storeProductResolver.resolve(
                experienceVersionId: release.releaseID.identity.experienceVersionId,
                authorization: introEligibilityAuthorization,
                productId: binding.product.id,
                placementId: binding.placement.id,
                productType: productType,
                appStoreProduct: storeProduct,
                options: binding.placement.appStoreOptions
            )
            resolvedProduct.localEntitlementGrants = binding.product.entitlements.map {
                StoreProduct.LocalEntitlementGrant(
                    featureId: $0.featureId ?? $0.id,
                    featureExternalId: $0.featureExternalId,
                    purchaseUsageFeatureIds: $0.purchaseUsageFeatureIds,
                    allowanceType: $0.allowanceType,
                    allowance: $0.allowance
                )
            }
            resolvedProduct.purchaseContext = PurchaseCommercialContext(
                release: release.releaseID,
                placementId: binding.placement.id,
                productId: binding.product.id,
                storeProductId: binding.product.store.productId,
                displayPrice: resolvedProduct.price,
                price: resolvedProduct.appStoreProduct.map {
                    NSDecimalNumber(decimal: $0.price).doubleValue
                }
            )
            resolvedProduct.providerFeatureAccess = binding.product.providerFeatureAccess?.provider
            storeProducts.append(resolvedProduct)
        }
        return storeProducts
    }

    private static func testStoreTrialTerms(
        label: String,
        fallbackPeriod: ProductPeriod?
    ) -> (period: ProductPeriod, periodCount: Int) {
        let parts = label
            .lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "-" })
        if let count = parts.first.flatMap({ Int($0) }), parts.count > 1 {
            let period: ProductPeriod?
            switch parts[1] {
            case "day", "days": period = .day
            case "week", "weeks": period = .week
            case "month", "months": period = .month
            case "year", "years": period = .year
            default: period = nil
            }
            if let period { return (period, max(count, 1)) }
        }
        return (fallbackPeriod ?? .day, 1)
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
