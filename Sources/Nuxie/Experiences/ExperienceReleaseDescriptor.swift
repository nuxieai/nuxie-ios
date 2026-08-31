import Foundation

enum ExperienceReleaseDescriptorLimits {
    static let mediaType = "application/vnd.nuxie.experience-release+json;version=1"
    static let schemaVersion = "nuxie.experience-release.v1"
    static let signatureDomain = "nuxie.experience-release-descriptor.v1\u{0}"
    static let descriptorBytes = 4 * 1_024 * 1_024
    static let envelopeBytes = 6 * 1_024 * 1_024
    static let profileEntryCount = 256
    static let profileEnvelopeAggregateBytes = 16 * 1_024 * 1_024
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

struct ExperienceReleaseDescriptorSignature: Codable, Equatable, Sendable {
    let version: Int
    let algorithm: String
    let keyId: String
    let signatureBase64: String
}

struct ExperienceReleaseDescriptorEnvelope: Codable, Equatable, Sendable {
    let mediaType: String
    let encoding: String
    let descriptorSha256: String
    let descriptorSizeBytes: Int
    var descriptorBytesBase64: String
    let signature: ExperienceReleaseDescriptorSignature

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

private struct ExperienceReleaseDynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func requireExactReleaseKeys(
    _ decoder: Decoder,
    _ expected: Set<String>
) throws {
    let container = try decoder.container(keyedBy: ExperienceReleaseDynamicCodingKey.self)
    let actual = Set(container.allKeys.map(\.stringValue))
    guard actual == expected else {
        throw DecodingError.dataCorrupted(.init(
            codingPath: decoder.codingPath,
            debugDescription: "unexpected experience release profile keys"
        ))
    }
}

struct ExperienceReleaseDelivery: Codable, Equatable, Sendable {
    let renderBaseUrl: String
    let assetBaseUrl: String

    init(renderBaseUrl: String, assetBaseUrl: String) {
        self.renderBaseUrl = renderBaseUrl
        self.assetBaseUrl = assetBaseUrl
    }

    init(from decoder: Decoder) throws {
        try requireExactReleaseKeys(decoder, ["renderBaseUrl", "assetBaseUrl"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        renderBaseUrl = try container.decode(String.self, forKey: .renderBaseUrl)
        assetBaseUrl = try container.decode(String.self, forKey: .assetBaseUrl)
    }

    private enum CodingKeys: String, CodingKey {
        case renderBaseUrl, assetBaseUrl
    }
}

struct ExperienceReleaseProfileEntry: Codable, Equatable, Sendable {
    let locator: ExperienceReleaseIdentity
    let descriptorSha256: String
    /// Canonical padded base64 of the exact compact envelope JSON bytes.
    let envelopeBytesBase64: String

    init(
        locator: ExperienceReleaseIdentity,
        descriptorSha256: String,
        envelopeBytesBase64: String
    ) {
        self.locator = locator
        self.descriptorSha256 = descriptorSha256
        self.envelopeBytesBase64 = envelopeBytesBase64
    }

    init(
        locator: ExperienceReleaseIdentity,
        descriptorSha256: String,
        envelopeBytes: Data
    ) {
        self.init(
            locator: locator,
            descriptorSha256: descriptorSha256,
            envelopeBytesBase64: envelopeBytes.base64EncodedString()
        )
    }

    init(from decoder: Decoder) throws {
        try requireExactReleaseKeys(
            decoder,
            ["locator", "descriptorSha256", "envelopeBytesBase64"]
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        locator = try container.decode(ExperienceReleaseIdentity.self, forKey: .locator)
        descriptorSha256 = try container.decode(String.self, forKey: .descriptorSha256)
        envelopeBytesBase64 = try container.decode(String.self, forKey: .envelopeBytesBase64)
        _ = try exactEnvelopeBytes()
    }

    func exactEnvelopeBytes() throws -> Data {
        guard let bytes = Data(base64Encoded: envelopeBytesBase64),
              bytes.base64EncodedString() == envelopeBytesBase64,
              bytes.count <= ExperienceReleaseDescriptorLimits.envelopeBytes else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [],
                debugDescription: "invalid canonical experience release envelope base64"
            ))
        }
        let envelope = try JSONDecoder().decode(
            ExperienceReleaseDescriptorEnvelope.self,
            from: bytes
        )
        guard let descriptorBytes = Data(base64Encoded: envelope.descriptorBytesBase64),
              descriptorBytes.base64EncodedString() == envelope.descriptorBytesBase64,
              envelope.descriptorSizeBytes > 0,
              envelope.descriptorSizeBytes <= ExperienceReleaseDescriptorLimits.descriptorBytes,
              descriptorBytes.count == envelope.descriptorSizeBytes,
              try envelope.canonicalBytes() == bytes,
              envelope.descriptorSha256 == descriptorSha256 else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [],
                debugDescription: "non-canonical experience release envelope JSON"
            ))
        }
        return bytes
    }

    private enum CodingKeys: String, CodingKey {
        case locator, descriptorSha256, envelopeBytesBase64
    }
}

struct ExperienceReleaseProfile: Codable, Equatable, Sendable {
    let delivery: ExperienceReleaseDelivery
    let active: [ExperienceReleaseProfileEntry]
    let pinned: [ExperienceReleaseProfileEntry]

    init(
        delivery: ExperienceReleaseDelivery,
        active: [ExperienceReleaseProfileEntry],
        pinned: [ExperienceReleaseProfileEntry]
    ) {
        self.delivery = delivery
        self.active = active
        self.pinned = pinned
    }

    init(from decoder: Decoder) throws {
        try requireExactReleaseKeys(decoder, ["delivery", "active", "pinned"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        delivery = try container.decode(ExperienceReleaseDelivery.self, forKey: .delivery)
        active = try container.decode([ExperienceReleaseProfileEntry].self, forKey: .active)
        pinned = try container.decode([ExperienceReleaseProfileEntry].self, forKey: .pinned)
        guard active.count <= ExperienceReleaseDescriptorLimits.profileEntryCount,
              pinned.count <= ExperienceReleaseDescriptorLimits.profileEntryCount else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "experience release profile entry limit exceeded"
            ))
        }
        var descriptorSizeByDigest: [String: Int] = [:]
        for entry in active + pinned {
            let bytes = try entry.exactEnvelopeBytes()
            let envelope = try JSONDecoder().decode(
                ExperienceReleaseDescriptorEnvelope.self,
                from: bytes
            )
            if let existing = descriptorSizeByDigest[envelope.descriptorSha256],
               existing != envelope.descriptorSizeBytes {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "conflicting descriptor sizes for digest"
                ))
            }
            descriptorSizeByDigest[envelope.descriptorSha256] = envelope.descriptorSizeBytes
        }
        let aggregate = descriptorSizeByDigest.values.reduce(into: 0) { total, size in
            let (next, overflow) = total.addingReportingOverflow(size)
            total = overflow ? Int.max : next
        }
        guard aggregate <= ExperienceReleaseDescriptorLimits.profileEnvelopeAggregateBytes else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "experience release profile envelope budget exceeded"
            ))
        }
    }

    private enum CodingKeys: String, CodingKey {
        case delivery, active, pinned
    }
}

enum ExperienceReleaseJSONValue: Codable, Sendable {
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

struct ExperienceReleaseIdentity: Codable, Equatable, Hashable, Sendable {
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
        try requireExactReleaseKeys(decoder, [
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

struct ExperienceReleaseIdentityExpectation: Equatable, Sendable {
    let appId: String
    let environment: String
    let experienceId: String
    let experienceVersionId: String
    let buildId: String
    let versionNumber: Int
    let publishedAt: String
    let publishedAtSeq: Int

    var identity: ExperienceReleaseIdentity {
        ExperienceReleaseIdentity(
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

struct ExperienceReleaseSupportedRuntime: Equatable, Sendable {
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

/// Swift-owned representation of the signed device control plane. The exact
/// signed bytes remain the wire authority while behavior numbers retain the
/// same IEEE-754 semantics as JavaScript JSON numbers.
struct ExperienceReleaseDescriptor: Codable, Sendable {
    let schemaVersion: String
    let identity: ExperienceReleaseIdentity
    let metadata: [String: ExperienceReleaseJSONValue]
    let enrollment: [String: ExperienceReleaseJSONValue]
    let lifecycle: [String: ExperienceReleaseJSONValue]
    let presentation: [String: ExperienceReleaseJSONValue]
    let products: [ExperienceReleaseJSONValue]
    let placements: [ExperienceReleaseJSONValue]
    let journey: [String: ExperienceReleaseJSONValue]
    let responseSchema: [String: ExperienceReleaseJSONValue]?
    let responseCaptures: [[String: ExperienceReleaseJSONValue]]
    let screenBehaviors: [[String: ExperienceReleaseJSONValue]]
    let render: [String: ExperienceReleaseJSONValue]
    let requirements: [String: ExperienceReleaseJSONValue]
    let provenance: [String: ExperienceReleaseJSONValue]
}

struct AuthenticatedExperienceReleaseDescriptor: Sendable {
    let authenticatedKeyID: String
    let exactDescriptorBytes: Data
    let descriptorSHA256: String
    let descriptor: ExperienceReleaseDescriptor
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
    case unsupportedRuntime(String)

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
        case .unsupportedRuntime: "experience_release.runtime.unsupported"
        }
    }

    var errorDescription: String? { contractCode }
}
