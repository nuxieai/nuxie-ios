import Foundation

func decodeJourneyDocuments<Document: Decodable>(
    _ type: Document.Type,
    from values: [JourneyReleaseJSONValue]
) throws -> [Document] {
    try ExactJSONCodec.decode(
        [Document].self,
        from: ExactJSONCodec.encode(values)
    )
}

enum ActiveProductEvidenceAuthorityResolution: Equatable, Sendable {
    case unavailable
    case readyNoMatch
    case nativeStoreKit
    case providerConnector
    case ambiguous

    var resolvedAuthority: PurchaseEvidenceAuthority? {
        switch self {
        case .unavailable:
            nil
        case .readyNoMatch, .nativeStoreKit:
            .nativeStoreKit
        case .providerConnector:
            .providerConnector
        case .ambiguous:
            .ambiguous
        }
    }
}

func activeProductEvidenceAuthority(
    products: [JourneyReleaseProductDocument],
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

struct PreparedJourneyProfileArtifacts: Sendable {
    let snapshot: JourneyProfileCatalog.Snapshot?
    let artifacts: PreparedJourneyArtifacts?
    fileprivate let productReleases: [JourneyProductCatalogRelease]

    init(
        snapshot: JourneyProfileCatalog.Snapshot?,
        artifacts: PreparedJourneyArtifacts? = nil
    ) {
        self.snapshot = snapshot
        self.artifacts = artifacts
        productReleases = []
    }

    fileprivate init(
        snapshot: JourneyProfileCatalog.Snapshot?,
        artifacts: PreparedJourneyArtifacts?,
        productReleases: [JourneyProductCatalogRelease]
    ) {
        self.snapshot = snapshot
        self.artifacts = artifacts
        self.productReleases = productReleases
    }
}

private struct JourneyProductCatalogRelease: Equatable, Sendable {
    let releaseID: AuthenticatedJourneyReleaseID
    let isActive: Bool
    let products: [JourneyReleaseProductDocument]
}

/// Owns the renderer artifacts and commercial authority admitted by the
/// canonical Journey profile. There is no second whole-experience catalog.
actor JourneyReleaseCatalog {
    private struct ProductReleaseAuthority {
        let releaseID: AuthenticatedJourneyReleaseID
        let leg: Journey
        let renderShell: JourneyDocument
        let products: [JourneyReleaseProductDocument]
        let placements: [JourneyReleasePlacementDocument]
    }

    private struct OptimisticAllowanceCatalogKey: Hashable {
        let releaseID: AuthenticatedJourneyReleaseID
        let isActive: Bool
        let productID: String
        let platform: String
        let storeProductID: String
    }

    private struct ProductViewModelIdentity: Hashable {
        let viewModelName: String?
        let instanceID: String

        func matches(_ value: JourneyViewModelValue) -> Bool {
            value.instanceId == instanceID
                && (viewModelName == nil || value.viewModelName == viewModelName)
        }
    }

    private struct PurchaseRequirements {
        var placementIDs: Set<String> = []
        var hasDynamicPlacement = false
    }

    private let productService: ProductService
    private let storeProductResolver: StoreProductResolver
    private let releaseStore: any JourneyReleaseAcquiring
    private let testStoreEnabled: Bool

    private var latestProfileGeneration: UInt64 = 0
    private var activeArtifacts: PreparedJourneyArtifacts?
    private var productReleases: [JourneyProductCatalogRelease] = []
    private var productMappingsByReleaseAndID:
        [String: JourneyReleaseProductDocument] = [:]
    private var productAuthorityCatalog:
        [String: ActiveProductEvidenceAuthorityResolution]?
    private var optimisticAllowanceCatalog:
        [OptimisticAllowanceCatalogKey: [OptimisticEntitlementAllowance]]?
    private var productAuthorityChangeHandler: (@Sendable () async -> Void)?
    private var pendingProductAuthorityChangeNotification = false

    init(
        productService: ProductService,
        introEligibilityTokenProvider: any IntroEligibilityTokenProviding =
            UnavailableIntroEligibilityTokenProvider(),
        introEligibilityOverrideHealth: IntroEligibilityOverrideHealth =
            IntroEligibilityOverrideHealth(),
        releaseStore: any JourneyReleaseAcquiring,
        testStoreEnabled: Bool = false
    ) {
        self.productService = productService
        storeProductResolver = StoreProductResolver(
            tokenProvider: introEligibilityTokenProvider,
            overrideHealth: introEligibilityOverrideHealth
        )
        self.releaseStore = releaseStore
        self.testStoreEnabled = testStoreEnabled
    }

    func prepareJourneyProfile(
        _ snapshot: JourneyProfileCatalog.Snapshot?
    ) async throws -> PreparedJourneyProfileArtifacts {
        guard let snapshot else {
            return PreparedJourneyProfileArtifacts(
                snapshot: nil,
                artifacts: nil,
                productReleases: []
            )
        }
        let artifacts = try await releaseStore.prepareJourneyArtifacts(
            for: snapshot
        )
        guard artifacts.releaseDescriptorSHA256s
                == Set(snapshot.releasesByDigest.keys) else {
            throw JourneyReleaseAcquisitionError.invalidProfileEntry
        }
        return PreparedJourneyProfileArtifacts(
            snapshot: snapshot,
            artifacts: artifacts,
            productReleases: try Self.productCatalogReleases(snapshot)
        )
    }

    @discardableResult
    func commitJourneyProfile(
        _ prepared: PreparedJourneyProfileArtifacts,
        generation: UInt64,
        admission: ProfileSideEffectAdmission? = nil
    ) async -> Bool {
        guard generation >= latestProfileGeneration,
              admission?() ?? true else {
            return false
        }
        if let snapshot = prepared.snapshot {
            guard prepared.artifacts?.releaseDescriptorSHA256s
                    == Set(snapshot.releasesByDigest.keys) else {
                return false
            }
        } else {
            guard prepared.artifacts == nil,
                  prepared.productReleases.isEmpty else {
                return false
            }
        }
        guard admission?() ?? true else { return false }

        latestProfileGeneration = generation
        activeArtifacts = prepared.artifacts
        productReleases = prepared.productReleases
        productMappingsByReleaseAndID = Self.productMappingCache(
            prepared.productReleases
        )

        let nextAuthorities = prepared.snapshot.map { _ in
            Self.productAuthorityCatalog(prepared.productReleases)
        }
        let nextAllowances = prepared.snapshot.map { _ in
            Self.optimisticAllowanceCatalog(prepared.productReleases)
        }
        let authorityChanged = productAuthorityCatalog != nextAuthorities
        let allowancesChanged = optimisticAllowanceCatalog != nextAllowances
        productAuthorityCatalog = nextAuthorities
        optimisticAllowanceCatalog = nextAllowances
        if authorityChanged || allowancesChanged {
            await notifyProductAuthorityChanged()
        }
        return true
    }

    func setProductAuthorityChangeHandler(
        _ handler: @escaping @Sendable () async -> Void
    ) async {
        productAuthorityChangeHandler = handler
        guard productAuthorityCatalog != nil,
              pendingProductAuthorityChangeNotification else {
            return
        }
        pendingProductAuthorityChangeNotification = false
        await handler()
    }

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
    ) -> [OptimisticEntitlementAllowance]? {
        let product: JourneyReleaseProductDocument?
        if let releaseDescriptorSHA256, let productId {
            product = productMappingsByReleaseAndID[
                Self.productMappingKey(
                    descriptorSHA256: releaseDescriptorSHA256,
                    productID: productId
                )
            ]
        } else {
            let matches = productReleases
                .filter(\.isActive)
                .flatMap(\.products)
                .filter {
                    $0.store.platform == "apple_app_store"
                        && $0.store.productId == storeProductId
                }
            guard let first = matches.first,
                  matches.dropFirst().allSatisfy({
                      $0.entitlements == first.entitlements
                  }) else {
                return nil
            }
            product = first
        }
        return product?.entitlements.map {
            OptimisticEntitlementAllowance(
                featureId: $0.featureId ?? $0.id,
                featureExternalId: $0.featureExternalId,
                allowanceType: $0.allowanceType,
                allowance: $0.allowance
            )
        }
    }

    func clearCache() async {
        let authorityChanged = productAuthorityCatalog != nil
            || optimisticAllowanceCatalog != nil
        activeArtifacts = nil
        productReleases.removeAll()
        productMappingsByReleaseAndID.removeAll()
        productAuthorityCatalog = nil
        optimisticAllowanceCatalog = nil
        if authorityChanged {
            await notifyProductAuthorityChanged()
        }
    }

    func productsForJourneyPresentation(
        release: AuthenticatedJourneyRelease,
        screenID: String,
        introEligibilityAuthorization: IntroEligibilityAuthorizationContext? = nil
    ) async throws -> [StoreProduct] {
        let authority: ProductReleaseAuthority
        do {
            authority = try Self.productAuthority(
                release,
                screenID: screenID
            )
        } catch {
            throw ExperienceError.productsUnavailable
        }
        let placementIDs = requiredPlacementIDs(
            for: screenID,
            in: authority
        )
        guard !placementIDs.isEmpty else { return [] }
        let bindings = appleProductBindings(
            placementIDs: placementIDs,
            in: authority
        )
        guard Set(bindings.map(\.placement.id)) == placementIDs else {
            throw ExperienceError.productsUnavailable
        }
        let productIDs = Set(bindings.map { $0.product.store.productId })
        guard !productIDs.isEmpty else {
            throw ExperienceError.productsUnavailable
        }

        do {
            await productService.invalidate(productIDs)
            let products = try await fetchProducts(
                bindings: bindings,
                releaseID: authority.releaseID,
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

    private func notifyProductAuthorityChanged() async {
        guard let productAuthorityChangeHandler else {
            pendingProductAuthorityChangeNotification = true
            return
        }
        await productAuthorityChangeHandler()
    }

    private static func productCatalogReleases(
        _ snapshot: JourneyProfileCatalog.Snapshot
    ) throws -> [JourneyProductCatalogRelease] {
        let activeDigests = Set(snapshot.profile.armedLegs.compactMap {
            $0.binding.type == .new ? $0.reference.descriptorSha256 : nil
        })
        return try snapshot.releasesByDigest.values.map { release in
            JourneyProductCatalogRelease(
                releaseID: .init(
                    identity: release.descriptor.identity,
                    descriptorSHA256: release.descriptorSHA256
                ),
                isActive: activeDigests.contains(release.descriptorSHA256),
                products: try decodeJourneyDocuments(
                    JourneyReleaseProductDocument.self,
                    from: release.descriptor.products
                )
            )
        }.sorted {
            $0.releaseID.descriptorSHA256 < $1.releaseID.descriptorSHA256
        }
    }

    private static func productMappingCache(
        _ releases: [JourneyProductCatalogRelease]
    ) -> [String: JourneyReleaseProductDocument] {
        var result: [String: JourneyReleaseProductDocument] = [:]
        for release in releases {
            for product in release.products {
                result[productMappingKey(
                    descriptorSHA256: release.releaseID.descriptorSHA256,
                    productID: product.id
                )] = product
            }
        }
        return result
    }

    private static func productMappingKey(
        descriptorSHA256: String,
        productID: String
    ) -> String {
        "\(descriptorSHA256)\u{0}\(productID)"
    }

    private static func productAuthorityCatalog(
        _ releases: [JourneyProductCatalogRelease]
    ) -> [String: ActiveProductEvidenceAuthorityResolution] {
        let products = releases.filter(\.isActive).flatMap(\.products)
        let storeProductIDs = Set(products.compactMap { product in
            product.store.platform == "apple_app_store"
                ? product.store.productId
                : nil
        })
        return Dictionary(uniqueKeysWithValues: storeProductIDs.map {
            storeProductID in
            (
                storeProductID,
                activeProductEvidenceAuthority(
                    products: products,
                    storeProductId: storeProductID
                )
            )
        })
    }

    private static func optimisticAllowanceCatalog(
        _ releases: [JourneyProductCatalogRelease]
    ) -> [OptimisticAllowanceCatalogKey: [OptimisticEntitlementAllowance]] {
        var result:
            [OptimisticAllowanceCatalogKey: [OptimisticEntitlementAllowance]] = [:]
        for release in releases {
            for product in release.products {
                let key = OptimisticAllowanceCatalogKey(
                    releaseID: release.releaseID,
                    isActive: release.isActive,
                    productID: product.id,
                    platform: product.store.platform,
                    storeProductID: product.store.productId
                )
                result[key] = product.entitlements.map {
                    OptimisticEntitlementAllowance(
                        featureId: $0.featureId ?? $0.id,
                        featureExternalId: $0.featureExternalId,
                        allowanceType: $0.allowanceType,
                        allowance: $0.allowance
                    )
                }
            }
        }
        return result
    }

    private static func productAuthority(
        _ release: AuthenticatedJourneyRelease,
        screenID: String
    ) throws -> ProductReleaseAuthority {
        let definition = try ExperienceDefinition(
            journeyDescriptor: release.descriptor
        )
        guard definition.screens.contains(where: { $0.id == screenID }) else {
            throw JourneyReleaseAcquisitionError.selectedScreenNotDeclared(
                screenID
            )
        }
        return ProductReleaseAuthority(
            releaseID: .init(
                identity: release.descriptor.identity,
                descriptorSHA256: release.descriptorSHA256
            ),
            leg: release.descriptor.leg,
            renderShell: definition.renderShell,
            products: try decodeJourneyDocuments(
                JourneyReleaseProductDocument.self,
                from: release.descriptor.products
            ),
            placements: try decodeJourneyDocuments(
                JourneyReleasePlacementDocument.self,
                from: release.descriptor.placements
            )
        )
    }

    private func requiredPlacementIDs(
        for screenID: String,
        in release: ProductReleaseAuthority
    ) -> Set<String> {
        guard let screen = release.renderShell.screens.first(where: {
            $0.id == screenID
        }) else {
            return []
        }
        let values = release.renderShell.viewModelValues ?? []
        var referenced: Set<String> = []
        var pendingValueGroups: [[JourneyViewModelValue]] = []
        if let viewModelName = screen.defaultViewModelName {
            pendingValueGroups.append(values.filter {
                $0.viewModelName == viewModelName
                    && isRootValue($0, for: screen)
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
                collectPlacementIDs(
                    in: value.value.value,
                    into: &referenced
                )
                collectLinkedViewModelIdentities(
                    in: value.value.value,
                    into: &linkedIdentities
                )
            }
            for identity in linkedIdentities
            where visitedIdentities.insert(identity).inserted {
                let linkedValues = values.filter(identity.matches)
                if !linkedValues.isEmpty {
                    pendingValueGroups.append(linkedValues)
                }
            }
        }

        let actionRequirements = purchaseRequirements(
            for: screenID,
            in: release.leg
        )
        referenced.formUnion(actionRequirements.placementIDs)
        if actionRequirements.hasDynamicPlacement {
            let appleProductIDs = Set(release.products
                .filter { $0.store.platform == "apple_app_store" }
                .map(\.id))
            referenced.formUnion(release.placements
                .filter { appleProductIDs.contains($0.productId) }
                .map(\.id))
        }
        return referenced
    }

    private func purchaseRequirements(
        for screenID: String,
        in journey: Journey
    ) -> PurchaseRequirements {
        let stepsByID = Dictionary(
            uniqueKeysWithValues: journey.steps.map { ($0.id, $0) }
        )
        var pending = journey.routes.compactMap { route -> String? in
            switch route.host.kind {
            case .journey:
                route.entryStepId
            case .screen where route.host.screenId == screenID:
                route.entryStepId
            case .screen:
                nil
            }
        }
        var visited: Set<String> = []
        var result = PurchaseRequirements()
        while let stepID = pending.popLast() {
            guard visited.insert(stepID).inserted,
                  let step = stepsByID[stepID] else {
                continue
            }
            if let action = step.action {
                collectPurchaseRequirements(
                    in: .object(ExactJSONObject(action)),
                    into: &result
                )
                if case .string("navigate") = action["type"] {
                    continue
                }
            }
            pending.append(
                contentsOf: step.outlets.map { Array($0.values) } ?? []
            )
        }
        return result
    }

    private func collectPurchaseRequirements(
        in value: JourneyReleaseJSONValue,
        into result: inout PurchaseRequirements
    ) {
        switch value {
        case .object(let object):
            if case .string("purchase") = object["type"] {
                if let placementID = literalPlacementID(object["placementId"]) {
                    result.placementIDs.insert(placementID)
                } else {
                    result.hasDynamicPlacement = true
                }
            }
            for nested in object.values {
                collectPurchaseRequirements(in: nested, into: &result)
            }
        case .array(let values):
            for nested in values {
                collectPurchaseRequirements(in: nested, into: &result)
            }
        default:
            break
        }
    }

    private func literalPlacementID(
        _ value: JourneyReleaseJSONValue?
    ) -> String? {
        switch value {
        case .string(let placementID):
            placementID
        case .object(let wrapper):
            wrapper["literal"]?.stringValue
        default:
            nil
        }
    }

    private func linkedViewModelIdentities(
        in values: [JourneyViewModelValue]
    ) -> Set<ProductViewModelIdentity> {
        struct FlattenedIdentity {
            var viewModelName: String?
            var instanceID: String?
        }
        var flattened: [String: FlattenedIdentity] = [:]
        for value in values {
            let segments = value.path.split(separator: "/").map(String.init)
            guard segments.count >= 2, let field = segments.last,
                  field == "viewModelId" || field == "vmInstanceId"
                    || field == "instanceId" else {
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
            guard let instanceID = identity.instanceID,
                  !instanceID.isEmpty else {
                return nil
            }
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
                collectLinkedViewModelIdentities(
                    in: nested,
                    into: &result
                )
            }
        } else if let values = array(from: value) {
            for nested in values {
                collectLinkedViewModelIdentities(
                    in: nested,
                    into: &result
                )
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

    private func collectPlacementIDs(
        in value: Any,
        into result: inout Set<String>
    ) {
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
        if let value = value as? [AnyCodable] {
            return value.map(\.value)
        }
        return nil
    }

    private func appleProductBindings(
        placementIDs: Set<String>,
        in release: ProductReleaseAuthority
    ) -> [(
        placement: JourneyReleasePlacementDocument,
        product: JourneyReleaseProductDocument
    )] {
        let productsByID = Dictionary(
            uniqueKeysWithValues: release.products.map { ($0.id, $0) }
        )
        return release.placements.compactMap { placement in
            guard placementIDs.contains(placement.id),
                  let product = productsByID[placement.productId],
                  product.store.platform == "apple_app_store" else {
                return nil
            }
            return (placement, product)
        }
    }

    private func fetchProducts(
        bindings: [(
            placement: JourneyReleasePlacementDocument,
            product: JourneyReleaseProductDocument
        )],
        releaseID: AuthenticatedJourneyReleaseID,
        introEligibilityAuthorization: IntroEligibilityAuthorizationContext?
    ) async throws -> [StoreProduct] {
        let identifiers = Set(bindings.map { $0.product.store.productId })
        if testStoreEnabled {
            return try bindings.map { binding in
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
                var product = StoreProduct(
                    productId: binding.product.id,
                    storeProductId: binding.product.store.productId,
                    placementId: binding.placement.id,
                    name: "TEST · \(preview.name)",
                    description: "TEST STORE — no charge. \(preview.description)",
                    price: "TEST · \(preview.price)",
                    period: period,
                    periodCount: preview.periodCount > 0
                        ? preview.periodCount
                        : nil,
                    periodLabel: preview.periodLabel,
                    renewalPrice: preview.renewalLabel,
                    renewalPeriod: "",
                    productType: productType,
                    introductoryTerms: preview.hasTrial
                        ? .init(
                            price: "TEST · FREE",
                            period: trialTerms.period,
                            periodCount: trialTerms.periodCount,
                            cycles: 1,
                            paymentMode: .freeTrial,
                            trialPeriodText: preview.trialLabel
                        )
                        : nil
                )
                product.isTestStoreProduct = true
                product.previewIntroOfferLabel = preview.introOfferLabel.isEmpty
                    ? nil
                    : preview.introOfferLabel
                Self.attachCommercialAuthority(
                    to: &product,
                    binding: binding,
                    releaseID: releaseID,
                    price: nil
                )
                return product
            }
        }

        let resolved = try await productService.fetchProducts(for: identifiers)
        let productsByID = Dictionary(
            uniqueKeysWithValues: resolved.map { ($0.id, $0) }
        )
        guard productsByID.count == identifiers.count else {
            throw ExperienceError.productsUnavailable
        }
        var products: [StoreProduct] = []
        products.reserveCapacity(bindings.count)
        for binding in bindings {
            guard let storeProduct = productsByID[
                binding.product.store.productId
            ], let productType = StoreProductType(
                rawValue: binding.product.store.productType
            ) else {
                throw ExperienceError.productsUnavailable
            }
            var product = try await storeProductResolver.resolve(
                experienceVersionId: releaseID.identity.experienceVersionId,
                authorization: introEligibilityAuthorization,
                productId: binding.product.id,
                placementId: binding.placement.id,
                productType: productType,
                appStoreProduct: storeProduct,
                options: binding.placement.appStoreOptions
            )
            Self.attachCommercialAuthority(
                to: &product,
                binding: binding,
                releaseID: releaseID,
                price: NSDecimalNumber(decimal: storeProduct.price).doubleValue
            )
            products.append(product)
        }
        return products
    }

    private static func attachCommercialAuthority(
        to product: inout StoreProduct,
        binding: (
            placement: JourneyReleasePlacementDocument,
            product: JourneyReleaseProductDocument
        ),
        releaseID: AuthenticatedJourneyReleaseID,
        price: Double?
    ) {
        product.localEntitlementGrants = binding.product.entitlements.map {
            StoreProduct.LocalEntitlementGrant(
                featureId: $0.featureId ?? $0.id,
                featureExternalId: $0.featureExternalId,
                purchaseUsageFeatureIds: $0.purchaseUsageFeatureIds,
                allowanceType: $0.allowanceType,
                allowance: $0.allowance
            )
        }
        product.purchaseContext = PurchaseCommercialContext(
            release: releaseID,
            placementId: binding.placement.id,
            productId: binding.product.id,
            storeProductId: binding.product.store.productId,
            displayPrice: product.price,
            price: price
        )
        product.providerFeatureAccess =
            binding.product.providerFeatureAccess?.provider
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

private extension JourneyReleaseJSONValue {
    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }
}
