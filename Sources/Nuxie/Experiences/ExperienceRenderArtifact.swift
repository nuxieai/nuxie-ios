import Foundation

struct AuthenticatedRuntimeAsset: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case image, font }

    let kind: Kind
    let riveAssetID: UInt32
    let riveUniqueName: String
    let sourceKey: String
    let contentType: String
    let sha256: String
    let required: Bool
    let bytes: Data?
}

/// The sole renderer input produced by descriptor authentication and acquisition.
struct AuthenticatedRuntimePayload: Sendable {
    let authenticatedKeyID: String
    let renderPlan: NativeExperienceRenderPlan
    let journey: JourneyDocument
    let sceneBytes: Data
    let assets: [AuthenticatedRuntimeAsset]
}

enum ExperienceArtifactSource: String, Sendable {
    case cache = "cached_artifact"
    case download = "downloaded_artifact"
    case unavailable
    case unknown
}

enum ExperienceReleaseResourceMetricOwner: Equatable, Sendable {
    case presentation
    case preload
}

/// Exact byte work performed while admitting and preparing one authenticated
/// release. Qualification consumes this internal value; it is not customer
/// telemetry or part of the wire contract.
struct ExperienceReleaseResourceMetrics: Equatable, Sendable {
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

struct ExperienceReleaseResourceFailure: Error {
    let underlying: Error
    let resourceMetrics: ExperienceReleaseResourceMetrics
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
    let assetURLsByRiveUniqueName: [String: URL]
    let source: ExperienceArtifactSource
    let payload: AuthenticatedRuntimePayload
    let interactivePreparation: ExperienceInteractivePreparationHandle
    let products: [ExperienceProduct]
    let productsResolvedForScreenID: String?
    let resourceMetrics: ExperienceReleaseResourceMetrics
    let productResolver: (@Sendable (String) async throws -> [ExperienceProduct])?

    init(
        identity: Identity,
        sceneURL: URL,
        sceneBytes: Data,
        assetURLsByRiveUniqueName: [String: URL],
        source: ExperienceArtifactSource,
        payload: AuthenticatedRuntimePayload,
        interactivePreparation: ExperienceInteractivePreparationHandle,
        products: [ExperienceProduct],
        productsResolvedForScreenID: String? = nil,
        resourceMetrics: ExperienceReleaseResourceMetrics,
        productResolver: (@Sendable (String) async throws -> [ExperienceProduct])? = nil
    ) {
        self.identity = identity
        self.sceneURL = sceneURL
        self.sceneBytes = sceneBytes
        self.assetURLsByRiveUniqueName = assetURLsByRiveUniqueName
        self.source = source
        self.payload = payload
        self.interactivePreparation = interactivePreparation
        self.products = products
        self.productsResolvedForScreenID = productsResolvedForScreenID
        self.resourceMetrics = resourceMetrics
        self.productResolver = productResolver
    }

    func localAssetURL(forRiveUniqueName uniqueName: String) -> URL? {
        assetURLsByRiveUniqueName[uniqueName]
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
    var assetURLsByRiveUniqueName: [String: URL] {
        acquired.assetURLsByRiveUniqueName
    }
    var source: ExperienceArtifactSource { acquired.source }

    func localAssetURL(forRiveUniqueName uniqueName: String) -> URL? {
        acquired.localAssetURL(forRiveUniqueName: uniqueName)
    }

    func resolvingProducts(for screenID: String) async throws -> LoadedExperienceArtifact {
        guard acquired.productsResolvedForScreenID != screenID else { return self }
        guard let productResolver = acquired.productResolver else { return self }
        let resolvedProducts = try await productResolver(screenID)
        let products = mergingExperienceProducts(
            acquired.products,
            with: resolvedProducts
        )
        return LoadedExperienceArtifact(acquired: AcquiredExperienceArtifact(
            identity: acquired.identity,
            sceneURL: acquired.sceneURL,
            sceneBytes: acquired.sceneBytes,
            assetURLsByRiveUniqueName: acquired.assetURLsByRiveUniqueName,
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

func mergingExperienceProducts(
    _ existing: [ExperienceProduct],
    with resolved: [ExperienceProduct]
) -> [ExperienceProduct] {
    var productsByPlacement = Dictionary(
        uniqueKeysWithValues: existing.map { ($0.placementId, $0) }
    )
    for product in resolved {
        productsByPlacement[product.placementId] = product
    }
    return productsByPlacement.values.sorted { $0.placementId < $1.placementId }
}
