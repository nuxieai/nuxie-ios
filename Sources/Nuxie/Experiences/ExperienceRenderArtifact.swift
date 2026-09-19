import Foundation

struct AuthenticatedRuntimeAsset: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case image, font, video }

    let kind: Kind
    let authoredAssetID: UInt32
    let assetUniqueName: String
    let sourceKey: String
    let contentType: String
    let sha256: String
    let required: Bool
    let bytes: Data?
    var fileURL: URL? = nil
}

/// The sole renderer input produced by descriptor authentication and acquisition.
struct AuthenticatedRuntimePayload: Sendable {
    let authenticatedKeyID: String
    let requiredCapabilities: Set<String>
    let renderPlan: NativeExperienceRenderPlan
    let journey: JourneyDocument
    let definition: ExperienceDefinition?
    let sceneBytes: Data
    let assets: [AuthenticatedRuntimeAsset]
    let videoFileLease: JourneyReleaseVideoFileLease?

    init(
        authenticatedKeyID: String,
        requiredCapabilities: Set<String> = [],
        renderPlan: NativeExperienceRenderPlan,
        journey: JourneyDocument,
        definition: ExperienceDefinition? = nil,
        sceneBytes: Data,
        assets: [AuthenticatedRuntimeAsset],
        videoFileLease: JourneyReleaseVideoFileLease? = nil
    ) {
        self.authenticatedKeyID = authenticatedKeyID
        self.requiredCapabilities = requiredCapabilities
        self.renderPlan = renderPlan
        self.journey = journey
        self.definition = definition
        self.sceneBytes = sceneBytes
        self.assets = assets
        self.videoFileLease = videoFileLease
    }
}

enum ExperienceArtifactSource: String, Sendable {
    case cache = "cached_artifact"
    case download = "downloaded_artifact"
    case unavailable
    case unknown
}

enum JourneyReleaseResourceMetricOwner: Equatable, Sendable {
    case presentation
    case preload
}

/// Exact byte work performed while admitting and preparing one authenticated
/// release. Qualification consumes this internal value; it is not customer
/// telemetry or part of the wire contract.
struct JourneyReleaseResourceMetrics: Equatable, Sendable {
    let readBytes: Int
    let hashedBytes: Int
    let parsedBytes: Int
    let duplicateReadBytes: Int
    let duplicateHashBytes: Int
    let duplicateParseBytes: Int
    let preloadBytes: Int
    let unusedPreloadBytes: Int

    static let zero = Self(
        readBytes: 0,
        hashedBytes: 0,
        parsedBytes: 0,
        duplicateReadBytes: 0,
        duplicateHashBytes: 0,
        duplicateParseBytes: 0,
        preloadBytes: 0,
        unusedPreloadBytes: 0
    )

    func adding(_ other: Self) -> Self {
        Self(
            readBytes: readBytes + other.readBytes,
            hashedBytes: hashedBytes + other.hashedBytes,
            parsedBytes: parsedBytes + other.parsedBytes,
            duplicateReadBytes: duplicateReadBytes + other.duplicateReadBytes,
            duplicateHashBytes: duplicateHashBytes + other.duplicateHashBytes,
            duplicateParseBytes: duplicateParseBytes + other.duplicateParseBytes,
            preloadBytes: preloadBytes + other.preloadBytes,
            unusedPreloadBytes: unusedPreloadBytes + other.unusedPreloadBytes
        )
    }

    func subtracting(_ earlier: Self) -> Self {
        Self(
            readBytes: max(0, readBytes - earlier.readBytes),
            hashedBytes: max(0, hashedBytes - earlier.hashedBytes),
            parsedBytes: max(0, parsedBytes - earlier.parsedBytes),
            duplicateReadBytes: max(0, duplicateReadBytes - earlier.duplicateReadBytes),
            duplicateHashBytes: max(0, duplicateHashBytes - earlier.duplicateHashBytes),
            duplicateParseBytes: max(0, duplicateParseBytes - earlier.duplicateParseBytes),
            preloadBytes: max(0, preloadBytes - earlier.preloadBytes),
            unusedPreloadBytes: max(0, unusedPreloadBytes - earlier.unusedPreloadBytes)
        )
    }

    var preloadFootprintBytes: Int {
        max(
            max(0, readBytes - duplicateReadBytes),
            max(0, parsedBytes - duplicateParseBytes)
        )
    }

    func attributedToPreload(unused: Bool) -> Self {
        Self(
            readBytes: readBytes,
            hashedBytes: hashedBytes,
            parsedBytes: parsedBytes,
            duplicateReadBytes: duplicateReadBytes,
            duplicateHashBytes: duplicateHashBytes,
            duplicateParseBytes: duplicateParseBytes,
            preloadBytes: preloadFootprintBytes,
            unusedPreloadBytes: unused ? preloadFootprintBytes : 0
        )
    }

    var qualificationTraceAttributes: [String: String] {
        [
            "read_bytes": String(readBytes),
            "hashed_bytes": String(hashedBytes),
            "parsed_bytes": String(parsedBytes),
            "duplicate_read_bytes": String(duplicateReadBytes),
            "duplicate_hash_bytes": String(duplicateHashBytes),
            "duplicate_parse_bytes": String(duplicateParseBytes),
            "preload_bytes": String(preloadBytes),
            "unused_preload_bytes": String(unusedPreloadBytes),
        ]
    }
}

struct JourneyReleaseResourceFailure: Error {
    let underlying: Error
    let resourceMetrics: JourneyReleaseResourceMetrics
}

/// Descriptor-authenticated RIV bytes and content-addressed external assets.
struct AcquiredExperienceArtifact: Sendable {
    struct Identity: Sendable {
        let experienceId: String
        let buildId: String
    }

    let identity: Identity
    let sceneURL: URL
    let sceneBytes: Data
    let assetURLsByUniqueName: [String: URL]
    let source: ExperienceArtifactSource
    let payload: AuthenticatedRuntimePayload
    let interactivePreparation: ExperienceInteractivePreparationHandle
    let products: [StoreProduct]
    let productsResolvedForScreenID: String?
    let resourceMetrics: JourneyReleaseResourceMetrics
    let productResolver: (@Sendable (String) async throws -> [StoreProduct])?

    init(
        identity: Identity,
        sceneURL: URL,
        sceneBytes: Data,
        assetURLsByUniqueName: [String: URL],
        source: ExperienceArtifactSource,
        payload: AuthenticatedRuntimePayload,
        interactivePreparation: ExperienceInteractivePreparationHandle,
        products: [StoreProduct],
        productsResolvedForScreenID: String? = nil,
        resourceMetrics: JourneyReleaseResourceMetrics,
        productResolver: (@Sendable (String) async throws -> [StoreProduct])? = nil
    ) {
        self.identity = identity
        self.sceneURL = sceneURL
        self.sceneBytes = sceneBytes
        self.assetURLsByUniqueName = assetURLsByUniqueName
        self.source = source
        self.payload = payload
        self.interactivePreparation = interactivePreparation
        self.products = products
        self.productsResolvedForScreenID = productsResolvedForScreenID
        self.resourceMetrics = resourceMetrics
        self.productResolver = productResolver
    }

    func localAssetURL(forUniqueName uniqueName: String) -> URL? {
        assetURLsByUniqueName[uniqueName]
    }
}

/// Renderer-ready artifact with authenticated behavior and render plan.
struct LoadedExperienceArtifact: Sendable {
    let acquired: AcquiredExperienceArtifact

    var payload: AuthenticatedRuntimePayload { acquired.payload }
    var renderPlan: NativeExperienceRenderPlan { payload.renderPlan }
    var journey: JourneyDocument { payload.journey }
    var sceneURL: URL { acquired.sceneURL }
    var sceneBytes: Data { acquired.sceneBytes }
    var assetURLsByUniqueName: [String: URL] {
        acquired.assetURLsByUniqueName
    }
    var source: ExperienceArtifactSource { acquired.source }

    func localAssetURL(forUniqueName uniqueName: String) -> URL? {
        acquired.localAssetURL(forUniqueName: uniqueName)
    }

    func resolvingProducts(for screenID: String) async throws -> LoadedExperienceArtifact {
        guard acquired.productsResolvedForScreenID != screenID else { return self }
        guard let productResolver = acquired.productResolver else { return self }
        let resolvedProducts = try await productResolver(screenID)
        let products = mergingStoreProducts(
            acquired.products,
            with: resolvedProducts
        )
        return LoadedExperienceArtifact(acquired: AcquiredExperienceArtifact(
            identity: acquired.identity,
            sceneURL: acquired.sceneURL,
            sceneBytes: acquired.sceneBytes,
            assetURLsByUniqueName: acquired.assetURLsByUniqueName,
            source: acquired.source,
            payload: acquired.payload,
            interactivePreparation: acquired.interactivePreparation,
            products: products,
            productsResolvedForScreenID: screenID,
            resourceMetrics: acquired.resourceMetrics,
            productResolver: productResolver
        ))
    }
}

func mergingStoreProducts(
    _ existing: [StoreProduct],
    with resolved: [StoreProduct]
) -> [StoreProduct] {
    var productsByPlacement = Dictionary(
        uniqueKeysWithValues: existing.map { ($0.placementId, $0) }
    )
    for product in resolved {
        productsByPlacement[product.placementId] = product
    }
    return productsByPlacement.values.sorted { $0.placementId < $1.placementId }
}
