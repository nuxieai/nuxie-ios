import Foundation

enum ExperiencePackageAuthenticationError: LocalizedError, Equatable, Sendable {
    case unsupportedPlatform
    case invalidAuthorizationKeys
    case missingSignature
    case malformedSignature
    case unknownKey(String)
    case invalidSignature
    case identityMismatch
    case invalidScene
    case invalidManifest
    case invalidInventory
    case invalidAsset(String)

    var contractCode: String {
        switch self {
        case .unsupportedPlatform: "package.authentication.unsupported_platform"
        case .invalidAuthorizationKeys: "package.authorization.invalid_keys"
        case .missingSignature: "package.signature.missing"
        case .malformedSignature: "package.signature.malformed"
        case .unknownKey: "package.signature.unknown_key"
        case .invalidSignature: "package.signature.bad_signature"
        case .identityMismatch: "package.identity.mismatch"
        case .invalidScene: "package.scene.invalid"
        case .invalidManifest: "package.manifest.invalid"
        case .invalidInventory: "package.inventory.invalid"
        case .invalidAsset: "package.asset.invalid"
        }
    }

    var errorDescription: String? {
        switch self {
        case .unsupportedPlatform:
            "Signed experience packages cannot be authenticated on this platform"
        case .invalidAuthorizationKeys:
            "Package authorization keys are missing, duplicated, malformed, or exceed limits"
        case .missingSignature:
            "Package signature evidence is missing"
        case .malformedSignature:
            "Package signature evidence is malformed"
        case .unknownKey(let keyID):
            "Package signature names an unknown key: \(keyID)"
        case .invalidSignature:
            "Package manifest signature is invalid"
        case .identityMismatch:
            "Authenticated package identity does not match its delivery pointer"
        case .invalidScene:
            "Authenticated package scene is not a Rive file"
        case .invalidManifest:
            "Authenticated package manifest is malformed or violates the v1 contract"
        case .invalidInventory:
            "Authenticated package inventory does not match its exact members"
        case .invalidAsset(let name):
            "Authenticated package asset is missing or invalid: \(name)"
        }
    }
}

struct AuthenticatedRuntimeAsset: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case image
        case font
    }

    let kind: Kind
    let riveAssetID: UInt32
    let riveUniqueName: String
    let sourceKey: String
    let contentType: String
    let sha256: String
    let required: Bool
    let bytes: Data?
}

/// The only output of the Swift authentication seam. Every byte view is copied
/// into Swift ownership and is safe to pass to the runtime-native wrappers.
struct AuthenticatedRuntimePayload: Sendable {
    let authenticatedKeyID: String
    let renderPlan: NativeExperienceRenderPlan
    let journey: JourneyDocument
    let sceneBytes: Data
    /// External image/font bytes referenced by the scene. Listener bytecode
    /// is intentionally absent: the publisher embeds it in authenticated RIV
    /// ScriptAssets, while standalone `.bin` objects are integrity evidence.
    let assets: [AuthenticatedRuntimeAsset]
}

struct NuxPackageSignatureEnvelopeV1: Decodable, Sendable {
    let version: Int
    let signs: String
    let algorithm: String
    let keyId: String
    let signatureBase64: String
}

protocol ExperiencePackageAuthenticating: Sendable {
    func authenticate(_ package: AcquiredExperiencePackage) async throws
        -> AuthenticatedRuntimePayload
}

/// Authenticates the product package entirely in Swift. It has no dependency
/// on native package or product-shaped runtime interfaces.
struct SwiftExperiencePackageAuthenticator: ExperiencePackageAuthenticating, Sendable {
    private static let maximumCandidateKeys = 256
    private static let maximumKeyIDBytes = 256
    private static let maximumSelectorBytes = 4 * 1_024
    private let journeyDecoder: @Sendable (Data) throws -> JourneyDocument

    init(
        journeyDecoder: @escaping @Sendable (Data) throws -> JourneyDocument = {
            try JSONDecoder().decode(JourneyDocument.self, from: $0)
        }
    ) {
        self.journeyDecoder = journeyDecoder
    }

    func authenticate(_ package: AcquiredExperiencePackage) async throws
        -> AuthenticatedRuntimePayload
    {
        if let payload = package.authenticatedPayload {
            return payload
        }
        let keys = try validate(package.authorizationKeys)
        guard !package.identity.experienceId.isEmpty,
              package.identity.experienceId.utf8.count <= Self.maximumSelectorBytes,
              !package.identity.buildId.isEmpty,
              package.identity.buildId.utf8.count <= Self.maximumSelectorBytes else {
            throw ExperiencePackageAuthenticationError.identityMismatch
        }
        return try NuxPackageReader.authenticate(
            exactPackageBytes: package.packageBytes,
            authorizationKeys: keys,
            expectedExperienceID: package.identity.experienceId,
            expectedBuildID: package.identity.buildId,
            preparedExternalAssets: package.assetURLsByRiveUniqueName,
            journeyDecoder: journeyDecoder
        )
    }

    private func validate(
        _ keys: [ExperiencePackageAuthorizationKey]
    ) throws -> [String: Data] {
        guard !keys.isEmpty, keys.count <= Self.maximumCandidateKeys else {
            throw ExperiencePackageAuthenticationError.invalidAuthorizationKeys
        }
        var result: [String: Data] = [:]
        for key in keys {
            guard !key.keyID.isEmpty,
                  key.keyID.utf8.count <= Self.maximumKeyIDBytes,
                  key.ed25519PublicKeyBytes.count == 32,
                  result.updateValue(
                    key.ed25519PublicKeyBytes,
                    forKey: key.keyID
                  ) == nil else {
                throw ExperiencePackageAuthenticationError.invalidAuthorizationKeys
            }
        }
        return result
    }
}
