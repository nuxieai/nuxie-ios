import Foundation

enum ExperienceReleaseDescriptorLimits {
    static let mediaType = "application/vnd.nuxie.experience-release+json;version=1"
    static let schemaVersion = "nuxie.experience-release.v1"
    static let signatureDomain = "nuxie.experience-release-descriptor.v1\u{0}"
    static let descriptorBytes = 128 * 1_024
    static let envelopeBytes = 192 * 1_024
    static let genericStringBytes = 4 * 1_024
    static let keyIDBytes = 256
    static let requiredCapabilityCount = 256
    static let screenCount = 256
    static let productCount = 256
    static let assetCount = 1_024
    static let transitionCount = 1_024
    static let textInputCount = 1_024
    static let rivArtifactBytes = 64 * 1_024 * 1_024
    static let externalAssetBytes = 32 * 1_024 * 1_024
    static let artifactAggregateBytes = 128 * 1_024 * 1_024
}

struct ExperienceReleaseDescriptorSignatureV1: Codable, Equatable, Sendable {
    let version: Int
    let algorithm: String
    let keyId: String
    let signatureBase64: String
}

struct ExperienceReleaseDescriptorEnvelopeV1: Codable, Equatable, Sendable {
    let mediaType: String
    let encoding: String
    let descriptorSha256: String
    let descriptorSizeBytes: Int
    var descriptorBytesBase64: String
    let signature: ExperienceReleaseDescriptorSignatureV1
}

enum ExperienceReleaseJSONValue: Codable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([Self])
    case object([String: Self])

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() {
            self = .null
        } else if let decoded = try? value.decode(Bool.self) {
            self = .bool(decoded)
        } else if let decoded = try? value.decode(Double.self) {
            self = .number(decoded)
        } else if let decoded = try? value.decode(String.self) {
            self = .string(decoded)
        } else if let decoded = try? value.decode([Self].self) {
            self = .array(decoded)
        } else {
            self = .object(try value.decode([String: Self].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .bool(let decoded): try value.encode(decoded)
        case .number(let decoded): try value.encode(decoded)
        case .string(let decoded): try value.encode(decoded)
        case .array(let decoded): try value.encode(decoded)
        case .object(let decoded): try value.encode(decoded)
        }
    }
}

struct ExperienceReleaseIdentityV1: Codable, Equatable, Sendable {
    let appId: String
    let environment: String
    let experienceId: String
    let experienceVersionId: String
    let buildId: String
    let versionNumber: Int
    let publishedAt: String
    let publishedAtSeq: Int
}

struct ExperienceReleaseIdentityExpectation: Equatable, Sendable {
    let appId: String
    let environment: String
    let experienceId: String
    let experienceVersionId: String
    let buildId: String
    let versionNumber: Int
    let publishedAt: String
    let publishedAtSeq: Int

    var identity: ExperienceReleaseIdentityV1 {
        ExperienceReleaseIdentityV1(
            appId: appId,
            environment: environment,
            experienceId: experienceId,
            experienceVersionId: experienceVersionId,
            buildId: buildId,
            versionNumber: versionNumber,
            publishedAt: publishedAt,
            publishedAtSeq: publishedAtSeq
        )
    }
}

enum ExperienceReleaseReplayPolicy: Equatable, Sendable {
    case active(minimumPublishedAtSeq: Int)
    case pinned(
        experienceVersionId: String,
        buildId: String,
        descriptorSHA256: String
    )
}

struct ExperienceReleaseSupportedCompatibility: Equatable, Sendable {
    let currentSdkVersion: String
    let supportedRuntimeRevisions: Set<String>
    let supportedLuauRevisions: [String: Set<Int>]
    let sceneFormat: SceneFormat
    let supportedCapabilities: Set<String>

    struct SceneFormat: Equatable, Sendable {
        let major: Int
        let minor: Int
    }
}

/// Swift-owned representation of the signed device control plane. The exact
/// signed bytes remain the wire authority while behavior numbers retain the
/// same IEEE-754 semantics as JavaScript JSON numbers.
struct ExperienceReleaseDescriptorV1: Codable, Sendable {
    let schemaVersion: String
    let identity: ExperienceReleaseIdentityV1
    let metadata: [String: ExperienceReleaseJSONValue]
    let enrollment: [String: ExperienceReleaseJSONValue]
    let lifecycle: [String: ExperienceReleaseJSONValue]
    let presentation: [String: ExperienceReleaseJSONValue]
    let products: [ExperienceReleaseJSONValue]
    let journey: [String: ExperienceReleaseJSONValue]
    let render: [String: ExperienceReleaseJSONValue]
    let compatibility: [String: ExperienceReleaseJSONValue]
    let provenance: [String: ExperienceReleaseJSONValue]
}

struct AuthenticatedExperienceReleaseDescriptor: Sendable {
    let authenticatedKeyID: String
    let exactDescriptorBytes: Data
    let descriptorSHA256: String
    let descriptor: ExperienceReleaseDescriptorV1
    /// Active releases return the authenticated sequence for monotonic
    /// high-water promotion. Pinned rollback releases deliberately return nil.
    let publishedAtSeqToPromote: Int?
}

enum ExperienceReleaseDescriptorAuthenticationError: LocalizedError, Equatable, Sendable {
    case invalidEnvelope
    case descriptorLimitExceeded
    case digestMismatch
    case invalidAuthorizationKeys
    case unknownKey(String)
    case invalidSignature
    case invalidDescriptor
    case identityMismatch
    case unsupportedCapabilities([String])
    case malformedBounds(String)
    case unsafeArtifactKey(String)
    case replayRejected
    case unsupportedCompatibility(String)

    var contractCode: String {
        switch self {
        case .invalidEnvelope: "experience_release.envelope.invalid"
        case .descriptorLimitExceeded: "experience_release.descriptor.limit_exceeded"
        case .digestMismatch: "experience_release.descriptor.digest_mismatch"
        case .invalidAuthorizationKeys: "experience_release.authorization.invalid_keys"
        case .unknownKey: "experience_release.signature.unknown_key"
        case .invalidSignature: "experience_release.signature.bad_signature"
        case .invalidDescriptor: "experience_release.descriptor.invalid"
        case .identityMismatch: "experience_release.identity.mismatch"
        case .unsupportedCapabilities: "experience_release.capability.unsupported"
        case .malformedBounds: "experience_release.descriptor.malformed_bounds"
        case .unsafeArtifactKey: "experience_release.artifact.unsafe_key"
        case .replayRejected: "experience_release.replay.rejected"
        case .unsupportedCompatibility: "experience_release.compatibility.unsupported"
        }
    }

    var errorDescription: String? { contractCode }
}
