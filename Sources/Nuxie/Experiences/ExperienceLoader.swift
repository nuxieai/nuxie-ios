import Foundation

/// Authenticates release profiles and resolves descriptor-native experiences.
actor ExperienceLoader {
    private struct ExperienceVersionKey: Hashable {
        let experienceId: String
        let versionId: String
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
        self.warmLoadsPermanentlySuspended = warmLoadsInitiallySuspended
        self.interactivePreparationCache = interactivePreparationCache
    }

    func replaceReleaseProfile(
        _ profile: ExperienceReleaseProfileV2?
    ) async throws -> [ExperienceReference]? {
        guard let profile else {
            cancelWarmTasks()
            finishPreloadAccounting(cancelled: true)
            cancelPendingPreparations()
            experiencesByVersion.removeAll()
            releasesByVersion.removeAll()
            productMappingsByReleaseAndID.removeAll()
            productMappingsByReleaseAndStoreID.removeAll()
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
        let productMappings = makeProductMappingCache(installed.values)

        if hasSameReleaseAuthority(as: installed) {
            // Disk admission and a concurrent network refresh can authenticate
            // the same profile while a restored presentation is acquiring its
            // artifacts. Preserve that exact in-flight work; cancellation is
            // reserved for a real identity, delivery-origin, or mode change.
            releasesByVersion = installed
            productMappingsByReleaseAndID.merge(productMappings.byID) { current, _ in current }
            productMappingsByReleaseAndStoreID.merge(productMappings.byStoreID) {
                current, _ in current
            }
            return catalog.references
        }

        cancelWarmTasks()
        finishPreloadAccounting(cancelled: true)
        cancelPendingPreparations()
        experiencesByVersion.removeAll()
        releasesByVersion = installed
        productMappingsByReleaseAndID.merge(productMappings.byID) { current, _ in current }
        productMappingsByReleaseAndStoreID.merge(productMappings.byStoreID) {
            current, _ in current
        }
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

    private func makeProductMappingCache(
        _ definitions: Dictionary<ExperienceVersionKey,
            AuthenticatedExperienceReleaseDefinition>.Values
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

    /// Returns authenticated Product authority without requiring an Experience
    /// or paywall to be loaded. Restore and local Feature Access use this seam.
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
            definitionV2: release.definitionV2,
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
        presentationTraceContext: ExperiencePresentationTraceContext? = nil
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
        guard !placementIDs.isEmpty else { return base }
        let productIDs = requiredProductIDs(for: initialScreenID, in: release)
        guard !productIDs.isEmpty else { throw ExperienceError.productsUnavailable }
        if Set(base.products.map(\.placementId)) == placementIDs {
            return base
        }

        let productSpan = presentationTraceContext?.begin(
            .storeKitProductLookup,
            attributes: [
                "product_count": String(productIDs.count),
                "screen_id": initialScreenID,
            ]
        )
        let products: [StoreProduct]
        do {
            products = try await fetchProducts(for: initialScreenID, in: release)
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
        guard releasesByVersion[key]?.releaseID == release.releaseID,
              let assetBaseURL = URL(string: release.delivery.assetBaseUrl) else {
            throw CancellationError()
        }
        let resolved = Experience(
            behavior: release.behavior,
            journey: release.journey,
            definitionV2: release.definitionV2,
            assetBaseURL: assetBaseURL,
            authenticatedReleaseID: release.releaseID,
            products: products
        )
        experiencesByVersion[key] = resolved
        return resolved
    }

    func experienceForPresentation(
        versionId: String,
        initialScreenID: String,
        presentationTraceContext: ExperiencePresentationTraceContext? = nil
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
            presentationTraceContext: presentationTraceContext
        )
    }

    private func requiredProductIDs(
        for screenID: String,
        in release: AuthenticatedExperienceReleaseDefinition
    ) -> Set<String> {
        Set(appleProductBindings(for: screenID, in: release).map {
            $0.product.store.productId
        })
    }

    private func requiredPlacementIDs(
        for screenID: String,
        in release: AuthenticatedExperienceReleaseDefinition
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
        let relevantHandlers = (release.journey.handlers[screenID] ?? [])
            + (release.journey.handlers[JourneyDocument.journeyEventHostKey] ?? [])
        for handler in relevantHandlers {
            collectPurchasePlacementIDs(in: handler.actions, into: &referenced)
        }
        for region in release.journey.deviceRegions ?? [] {
            collectPurchasePlacementIDs(in: region.actions, into: &referenced)
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
                collectPurchasePlacementIDs(in: window.successActions ?? [], into: &result)
            case .waitUntil(let wait):
                collectPurchasePlacementIDs(in: wait.successActions ?? [], into: &result)
                collectPurchasePlacementIDs(in: wait.timeoutActions ?? [], into: &result)
            case .condition(let condition):
                for branch in condition.branches {
                    collectPurchasePlacementIDs(in: branch.actions, into: &result)
                }
                collectPurchasePlacementIDs(in: condition.defaultActions ?? [], into: &result)
            case .experiment(let experiment):
                for variant in experiment.variants {
                    collectPurchasePlacementIDs(in: variant.actions, into: &result)
                }
            case .restore(let restore):
                collectPurchasePlacementIDs(in: restore.onRestored ?? [], into: &result)
                collectPurchasePlacementIDs(in: restore.onNoPurchases ?? [], into: &result)
                collectPurchasePlacementIDs(in: restore.onFailed ?? [], into: &result)
            case .connectorAction(let connector):
                collectPurchasePlacementIDs(in: connector.onSucceeded ?? [], into: &result)
                collectPurchasePlacementIDs(in: connector.onFailed ?? [], into: &result)
                collectPurchasePlacementIDs(in: connector.onTimeout ?? [], into: &result)
            case .grantEntitlement(let grant):
                collectPurchasePlacementIDs(in: grant.onSucceeded ?? [], into: &result)
                collectPurchasePlacementIDs(in: grant.onFailed ?? [], into: &result)
                collectPurchasePlacementIDs(in: grant.onTimeout ?? [], into: &result)
            default:
                continue
            }
        }
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
        presentationTraceContext: ExperiencePresentationTraceContext?
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
            let products = try await fetchProducts(for: screenID, in: release)
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
            definitionV2: release.definitionV2,
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
                    presentationTraceContext: presentationTraceContext
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
        in release: AuthenticatedExperienceReleaseDefinition
    ) async throws -> [StoreProduct] {
        let bindings = appleProductBindings(for: screenID, in: release)
        guard !bindings.isEmpty else { return [] }
        let identifiers = Set(bindings.map { $0.product.store.productId })
        let resolved = try await productService.fetchProducts(for: identifiers)
        let productsByID = Dictionary(uniqueKeysWithValues: resolved.map { ($0.id, $0) })
        guard productsByID.count == identifiers.count else {
            throw ExperienceError.productsUnavailable
        }
        return try bindings.map { binding in
            guard let storeProduct = productsByID[binding.product.store.productId],
                  storeProduct.productType.rawValue == binding.product.store.productType else {
                throw ExperienceError.productsUnavailable
            }
            let period = mapSubscriptionPeriod(storeProduct.subscriptionPeriod)
            let periodLabel = subscriptionPeriodLabel(
                storeProduct.subscriptionPeriod,
                locale: storeProduct.priceLocale
            )
            let hasRenewal = storeProduct.productType == .autoRenewable
            return StoreProduct(
                productId: binding.product.id,
                storeProductId: storeProduct.id,
                placementId: binding.placement.id,
                name: storeProduct.displayName,
                description: storeProduct.description,
                price: storeProduct.displayPrice,
                period: period,
                periodCount: storeProduct.subscriptionPeriod?.value,
                periodLabel: periodLabel,
                renewalPrice: hasRenewal ? storeProduct.displayPrice : "",
                renewalPeriod: hasRenewal ? periodLabel : "",
                productType: storeProduct.productType,
                appStoreProduct: storeProduct
            )
        }
    }

    private func mapSubscriptionPeriod(
        _ subscriptionPeriod: SubscriptionPeriod?
    ) -> ProductPeriod? {
        guard let period = subscriptionPeriod else { return nil }
        switch period.unit {
        case .day: return .day
        case .week: return .week
        case .month: return .month
        case .year: return .year
        }
    }

    private func subscriptionPeriodLabel(
        _ period: SubscriptionPeriod?,
        locale: Locale
    ) -> String {
        guard let period else { return "" }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 1
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        formatter.calendar = calendar
        let components: DateComponents
        switch period.unit {
        case .day:
            formatter.allowedUnits = [.day]
            components = DateComponents(day: period.value)
        case .week:
            formatter.allowedUnits = [.weekOfMonth]
            components = DateComponents(weekOfMonth: period.value)
        case .month:
            formatter.allowedUnits = [.month]
            components = DateComponents(month: period.value)
        case .year:
            formatter.allowedUnits = [.year]
            components = DateComponents(year: period.value)
        }
        return formatter.string(from: components) ?? ""
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
