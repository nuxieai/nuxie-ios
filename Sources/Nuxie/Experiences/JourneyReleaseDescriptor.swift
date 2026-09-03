import Foundation

enum JourneyReleaseLimits {
    static let descriptorBytes = 4 * 1_024 * 1_024
    static let envelopeBytes = 6 * 1_024 * 1_024
    static let profileBytes = 24 * 1_024 * 1_024
    static let genericStringBytes = 4 * 1_024
    static let keyIDBytes = 256
    static let requiredCapabilityCount = 256
    static let screenCount = 256
    static let productCount = 256
    static let placementCount = 256
    static let assetCount = 1_024
    static let transitionCount = 1_024
    static let textInputCount = 1_024
    static let rivArtifactBytes = 64 * 1_024 * 1_024
    static let externalAssetBytes = 32 * 1_024 * 1_024
    static let artifactAggregateBytes = 128 * 1_024 * 1_024
}

struct JourneyReleaseSignature: Codable, Equatable, Sendable {
    let version: Int
    let algorithm: String
    let keyId: String
    let signatureBase64: String
}

struct JourneyReleaseEnvelope: Codable, Equatable, Sendable {
    let mediaType: String
    let encoding: String
    let descriptorSha256: String
    let descriptorSizeBytes: Int
    var descriptorBytesBase64: String
    let signature: JourneyReleaseSignature

    func canonicalBytes() throws -> Data {
        func string(_ value: String) -> String {
            var encoded = "\""
            for scalar in value.unicodeScalars {
                switch scalar.value {
                case 0x08: encoded += "\\b"
                case 0x09: encoded += "\\t"
                case 0x0A: encoded += "\\n"
                case 0x0C: encoded += "\\f"
                case 0x0D: encoded += "\\r"
                case 0x22: encoded += "\\\""
                case 0x5C: encoded += "\\\\"
                case 0x00...0x1F:
                    encoded += String(format: "\\u%04x", scalar.value)
                default:
                    encoded.unicodeScalars.append(scalar)
                }
            }
            encoded += "\""
            return encoded
        }
        let json = "{" + [
            "\"descriptorBytesBase64\":\(string(descriptorBytesBase64))",
            "\"descriptorSha256\":\(string(descriptorSha256))",
            "\"descriptorSizeBytes\":\(descriptorSizeBytes)",
            "\"encoding\":\(string(encoding))",
            "\"mediaType\":\(string(mediaType))",
            "\"signature\":{" + [
                "\"algorithm\":\(string(signature.algorithm))",
                "\"keyId\":\(string(signature.keyId))",
                "\"signatureBase64\":\(string(signature.signatureBase64))",
                "\"version\":\(signature.version)",
            ].joined(separator: ",") + "}",
        ].joined(separator: ",") + "}"
        return Data(json.utf8)
    }
}

private struct JourneyReleaseCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func requireExactJourneyReleaseKeys(
    _ decoder: Decoder,
    _ expected: Set<String>
) throws {
    let container = try decoder.container(keyedBy: JourneyReleaseCodingKey.self)
    let actual = Set(container.allKeys.map(\.stringValue))
    guard actual == expected else {
        throw DecodingError.dataCorrupted(.init(
            codingPath: decoder.codingPath,
            debugDescription: "unexpected Journey release keys"
        ))
    }
}

struct JourneyReleaseDelivery: Codable, Equatable, Sendable {
    let renderBaseUrl: String
    let assetBaseUrl: String

    init(renderBaseUrl: String, assetBaseUrl: String) {
        self.renderBaseUrl = renderBaseUrl
        self.assetBaseUrl = assetBaseUrl
    }

    init(from decoder: Decoder) throws {
        try requireExactJourneyReleaseKeys(decoder, ["renderBaseUrl", "assetBaseUrl"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        renderBaseUrl = try container.decode(String.self, forKey: .renderBaseUrl)
        assetBaseUrl = try container.decode(String.self, forKey: .assetBaseUrl)
    }

    private enum CodingKeys: String, CodingKey {
        case renderBaseUrl, assetBaseUrl
    }
}

enum JourneyReleaseJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([Self])
    case object(ExactJSONObject<Self>)

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
            self = .object(try value.decode(ExactJSONObject<Self>.self))
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

struct JourneyReleaseIdentity: Codable, Equatable, Hashable, Sendable {
    let appId: String
    let environment: String
    let experienceId: String
    let experienceVersionId: String
    let buildId: String
    let versionNumber: Int
    let publishedAt: String
    let publishedAtSeq: Int

    init(
        appId: String,
        environment: String,
        experienceId: String,
        experienceVersionId: String,
        buildId: String,
        versionNumber: Int,
        publishedAt: String,
        publishedAtSeq: Int
    ) {
        self.appId = appId
        self.environment = environment
        self.experienceId = experienceId
        self.experienceVersionId = experienceVersionId
        self.buildId = buildId
        self.versionNumber = versionNumber
        self.publishedAt = publishedAt
        self.publishedAtSeq = publishedAtSeq
    }

    init(from decoder: Decoder) throws {
        try requireExactJourneyReleaseKeys(decoder, [
            "appId", "environment", "experienceId", "experienceVersionId",
            "buildId", "versionNumber", "publishedAt", "publishedAtSeq",
        ])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appId = try container.decode(String.self, forKey: .appId)
        environment = try container.decode(String.self, forKey: .environment)
        experienceId = try container.decode(String.self, forKey: .experienceId)
        experienceVersionId = try container.decode(String.self, forKey: .experienceVersionId)
        buildId = try container.decode(String.self, forKey: .buildId)
        versionNumber = try container.decode(Int.self, forKey: .versionNumber)
        publishedAt = try container.decode(String.self, forKey: .publishedAt)
        publishedAtSeq = try container.decode(Int.self, forKey: .publishedAtSeq)
    }

    private enum CodingKeys: String, CodingKey {
        case appId, environment, experienceId, experienceVersionId, buildId
        case versionNumber, publishedAt, publishedAtSeq
    }
}

enum JourneyReleaseReplayPolicy: Equatable, Sendable {
    case active(minimumPublishedAtSeq: Int)
    case pinned(
        experienceVersionId: String,
        buildId: String,
        descriptorSHA256: String
    )
}

struct JourneyReleaseSupportedRuntime: Equatable, Sendable {
    let currentSdkVersion: String
    let supportedRuntimeRevisions: Set<String>
    let supportedLuauRevisions: [String: Set<Int>]
    let sceneFormat: SceneFormat
    let timezoneDataRevision: String
    let timezoneDataSHA256: String
    let supportedCapabilities: Set<String>

    struct SceneFormat: Equatable, Sendable {
        let major: Int
        let minor: Int
    }
}

enum JourneyReleaseAuthenticationError: LocalizedError, Equatable, Sendable {
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
    case unsupportedRuntime(String)

    var contractCode: String {
        switch self {
        case .invalidEnvelope: "journey_release.envelope.invalid"
        case .descriptorLimitExceeded: "journey_release.descriptor.limit_exceeded"
        case .digestMismatch: "journey_release.descriptor.digest_mismatch"
        case .invalidAuthorizationKeys: "journey_release.authorization.invalid_keys"
        case .unknownKey: "journey_release.signature.unknown_key"
        case .invalidSignature: "journey_release.signature.bad_signature"
        case .invalidDescriptor: "journey_release.descriptor.invalid"
        case .identityMismatch: "journey_release.identity.mismatch"
        case .unsupportedCapabilities: "journey_release.capability.unsupported"
        case .malformedBounds: "journey_release.descriptor.malformed_bounds"
        case .unsafeArtifactKey: "journey_release.artifact.unsafe_key"
        case .replayRejected: "journey_release.replay.rejected"
        case .unsupportedRuntime: "journey_release.runtime.unsupported"
        }
    }

    var errorDescription: String? { contractCode }
}
