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
}
