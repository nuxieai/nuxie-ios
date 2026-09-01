import CryptoKit
import Foundation

private struct SemanticVersion: Comparable {
    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: [String]

    init?(_ value: String) {
        guard value.utf16.count <= 64 else { return nil }
        let pieces = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = pieces[0].split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3,
              let major = Int(core[0]), let minor = Int(core[1]), let patch = Int(core[2]),
              major >= 0, minor >= 0, patch >= 0,
              major <= 2_147_483_647,
              minor <= 2_147_483_647,
              patch <= 2_147_483_647,
              String(major) == core[0], String(minor) == core[1], String(patch) == core[2]
        else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
        prerelease = pieces.count == 2
            ? pieces[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            : []
        guard prerelease.allSatisfy({ part in
            !part.isEmpty && part.utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0)
                    || (97...122).contains($0) || $0 == 45
            }) && !(part.count > 1 && part.first == "0" && part.allSatisfy(\.isNumber))
        }) else { return nil }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        for (left, right) in zip(
            [lhs.major, lhs.minor, lhs.patch],
            [rhs.major, rhs.minor, rhs.patch]
        ) where left != right {
            return left < right
        }
        if lhs.prerelease.isEmpty != rhs.prerelease.isEmpty {
            return !rhs.prerelease.isEmpty
        }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            let leftNumeric = left.allSatisfy(\.isNumber)
            let rightNumeric = right.allSatisfy(\.isNumber)
            if leftNumeric && rightNumeric {
                let normalizedLeft = String(left.drop { $0 == "0" })
                let normalizedRight = String(right.drop { $0 == "0" })
                if normalizedLeft.count != normalizedRight.count {
                    return normalizedLeft.count < normalizedRight.count
                }
                if normalizedLeft != normalizedRight {
                    return normalizedLeft < normalizedRight
                }
                continue
            }
            if leftNumeric { return true }
            if rightNumeric { return false }
            return left < right
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

struct ExperienceReleaseDescriptorVerifier: Sendable {
    func authenticate(
        envelopeBytes: Data,
        authorizationKeys: [ExperiencePackageAuthorizationKey],
        expectedIdentity: ExperienceReleaseIdentityExpectation,
        supportedRuntime: ExperienceReleaseSupportedRuntime,
        replayPolicy: ExperienceReleaseReplayPolicy
    ) throws -> AuthenticatedExperienceReleaseDescriptor {
        let (envelope, descriptorBytes) = try authenticateEnvelope(
            envelopeBytes, authorizationKeys: authorizationKeys,
            mediaType: ExperienceReleaseDescriptorLimits.mediaType,
            signatureDomain: ExperienceReleaseDescriptorLimits.signatureDomain
        )

        // No descriptor byte is interpreted until the exact, domain-separated
        // signature has authenticated it.
        let descriptor = try decodeAndValidateDescriptor(descriptorBytes)
        guard descriptor.identity == expectedIdentity.identity else {
            throw ExperienceReleaseDescriptorAuthenticationError.identityMismatch
        }
        try validateRuntimeRequirements(
            descriptor.requirements,
            supported: supportedRuntime
        )
        try validateRuntimeBindings(descriptor.screenBehaviors)
        let releaseSequenceToPromote = try validateReplayPolicy(
            replayPolicy,
            identity: descriptor.identity,
            descriptorSHA256: envelope.descriptorSha256
        )
        return AuthenticatedExperienceReleaseDescriptor(
            authenticatedKeyID: envelope.signature.keyId,
            exactDescriptorBytes: descriptorBytes,
            descriptorSHA256: envelope.descriptorSha256,
            descriptor: descriptor,
            releaseSequenceToPromote: releaseSequenceToPromote
        )
    }

    func validateIdentity(_ identity: ExperienceReleaseIdentity) throws {
        guard identity.versionNumber > 0,
                  identity.versionNumber <= 9_007_199_254_740_991,
                  identity.releaseSequence >= 0,
                  identity.releaseSequence <= 9_007_199_254_740_991,
                  isZodOffsetDateTime(identity.releaseCreatedAt),
                  ["test", "live"].contains(identity.environment),
                  [
                    identity.appId,
                    identity.experienceId,
                    identity.experienceVersionId,
                    identity.buildId,
                  ].allSatisfy({
                    !$0.isEmpty && !$0.contains("\u{0}") && $0.utf16.count <= 128
                  }) else {
            throw ExperienceReleaseDescriptorAuthenticationError.invalidDescriptor
        }
    }

    func validateDeviceLegEnvelope(_ bytes: Data) throws {
        let envelope = try decodeEnvelope(bytes, mediaType: DeviceLegReleaseDescriptor.mediaType)
        _ = try decodeDescriptorBytes(envelope)
        guard let signature = canonicalBase64(envelope.signature.signatureBase64, maximumDecodedBytes: 64),
              signature.count == 64 else { throw ExperienceReleaseDescriptorAuthenticationError.invalidEnvelope }
    }

    private func authenticateEnvelope(
        _ envelopeBytes: Data, authorizationKeys: [ExperiencePackageAuthorizationKey],
        mediaType: String, signatureDomain: String
    ) throws -> (ExperienceReleaseDescriptorEnvelope, Data) {
        let envelope = try decodeEnvelope(envelopeBytes, mediaType: mediaType)
        let descriptorBytes = try decodeDescriptorBytes(envelope)
        let keys = try validateKeys(authorizationKeys)
        guard let keyBytes = keys[envelope.signature.keyId] else {
            throw ExperienceReleaseDescriptorAuthenticationError.unknownKey(
                envelope.signature.keyId
            )
        }
        let publicKey: Curve25519.Signing.PublicKey
        do {
            publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: keyBytes)
        } catch {
            throw ExperienceReleaseDescriptorAuthenticationError.invalidAuthorizationKeys
        }
        guard let signatureBytes = canonicalBase64(
            envelope.signature.signatureBase64,
            maximumDecodedBytes: 64
        ), signatureBytes.count == 64 else {
            throw ExperienceReleaseDescriptorAuthenticationError.invalidEnvelope
        }
        let signedBytes = Data(signatureDomain.utf8)
            + descriptorBytes
        guard publicKey.isValidSignature(signatureBytes, for: signedBytes) else {
            throw ExperienceReleaseDescriptorAuthenticationError.invalidSignature
        }

        return (envelope, descriptorBytes)
    }

    func authenticateDeviceLeg(
        envelopeBytes: Data,
        authorizationKeys: [ExperiencePackageAuthorizationKey],
        expectedIdentity: ExperienceReleaseIdentity,
        expectedLegId: String,
        supportedRuntime: ExperienceReleaseSupportedRuntime,
        replayPolicy: ExperienceReleaseReplayPolicy
    ) throws -> AuthenticatedDeviceLegRelease {
        let (envelope, bytes) = try authenticateEnvelope(
            envelopeBytes, authorizationKeys: authorizationKeys,
            mediaType: DeviceLegReleaseDescriptor.mediaType,
            signatureDomain: DeviceLegReleaseDescriptor.signatureDomain
        )
        // Authentication precedes interpretation, including cursor validation.
        let descriptor: DeviceLegReleaseDescriptor
        do {
            try StrictJSONDuplicateKeyValidator.validate(bytes, ordinalKeys: true)
            guard let root = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
                throw ExperienceReleaseDescriptorAuthenticationError.invalidDescriptor
            }
            try DeviceLegSchemaValidator.validate(root)
            try validateJSONValue(root, field: nil)
            try validateRenderValue(root["render"], field: "render")
            try validateArtifactReferences(root)
            descriptor = try ExactJSONCodec.decode(DeviceLegReleaseDescriptor.self, from: bytes)
            try validateIdentity(descriptor.identity)
        } catch let error as ExperienceReleaseDescriptorAuthenticationError { throw error }
        catch { throw ExperienceReleaseDescriptorAuthenticationError.invalidDescriptor }
        guard descriptor.identity == expectedIdentity, descriptor.leg.id == expectedLegId else {
            throw ExperienceReleaseDescriptorAuthenticationError.identityMismatch
        }
        if let requirements = descriptor.requirements {
            try validateRuntimeRequirements(requirements, supported: supportedRuntime)
        }
        try validateRuntimeBindings(descriptor.screenBehaviors)
        return AuthenticatedDeviceLegRelease(
            authenticatedKeyID: envelope.signature.keyId, exactDescriptorBytes: bytes,
            descriptorSHA256: envelope.descriptorSha256, descriptor: descriptor,
            releaseSequenceToPromote: try validateReplayPolicy(replayPolicy, identity: descriptor.identity,
                descriptorSHA256: envelope.descriptorSha256)
        )
    }

    private func validateReplayPolicy(
        _ policy: ExperienceReleaseReplayPolicy,
        identity: ExperienceReleaseIdentity,
        descriptorSHA256: String
    ) throws -> Int? {
        switch policy {
        case .active(let minimumReleaseSequence):
            guard minimumReleaseSequence >= 0,
                  identity.releaseSequence >= minimumReleaseSequence else {
                throw ExperienceReleaseDescriptorAuthenticationError.replayRejected
            }
            return identity.releaseSequence
        case .pinned(let experienceVersionId, let buildId, let expectedDigest):
            guard identity.experienceVersionId == experienceVersionId,
                  identity.buildId == buildId,
                  descriptorSHA256 == expectedDigest else {
                throw ExperienceReleaseDescriptorAuthenticationError.replayRejected
            }
            return nil
        }
    }

    private func decodeEnvelope(_ bytes: Data, mediaType: String) throws
        -> ExperienceReleaseDescriptorEnvelope
    {
        guard bytes.count <= ExperienceReleaseDescriptorLimits.envelopeBytes else {
            throw ExperienceReleaseDescriptorAuthenticationError.descriptorLimitExceeded
        }
        do {
            try StrictJSONDuplicateKeyValidator.validate(bytes)
            guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  Set(object.keys) == [
                    "mediaType", "encoding", "descriptorSha256",
                    "descriptorSizeBytes", "descriptorBytesBase64", "signature",
                  ],
                  let signature = object["signature"] as? [String: Any],
                  Set(signature.keys) == [
                    "version", "algorithm", "keyId", "signatureBase64",
                  ] else {
                throw ExperienceReleaseDescriptorAuthenticationError.invalidEnvelope
            }
            let envelope = try JSONDecoder().decode(
                ExperienceReleaseDescriptorEnvelope.self,
                from: bytes
            )
            guard envelope.mediaType == mediaType,
                  envelope.encoding == "base64",
                  envelope.signature.version == 1,
                  envelope.signature.algorithm == "ed25519",
                  !envelope.signature.keyId.isEmpty,
                  envelope.signature.keyId.utf8.count
                    <= ExperienceReleaseDescriptorLimits.keyIDBytes,
                  isLowercaseSHA256(envelope.descriptorSha256),
                  envelope.descriptorSizeBytes >= 0,
                  envelope.descriptorSizeBytes
                    <= ExperienceReleaseDescriptorLimits.descriptorBytes else {
                throw ExperienceReleaseDescriptorAuthenticationError.invalidEnvelope
            }
            return envelope
        } catch let error as ExperienceReleaseDescriptorAuthenticationError {
            throw error
        } catch {
            throw ExperienceReleaseDescriptorAuthenticationError.invalidEnvelope
        }
    }

    private func decodeDescriptorBytes(
        _ envelope: ExperienceReleaseDescriptorEnvelope
    ) throws -> Data {
        guard let bytes = canonicalBase64(
            envelope.descriptorBytesBase64,
            maximumDecodedBytes: ExperienceReleaseDescriptorLimits.descriptorBytes
        ) else {
            throw ExperienceReleaseDescriptorAuthenticationError.invalidEnvelope
        }
        guard bytes.count == envelope.descriptorSizeBytes else {
            throw ExperienceReleaseDescriptorAuthenticationError.invalidEnvelope
        }
        guard SHA256Provider.hexDigest(bytes) == envelope.descriptorSha256 else {
            throw ExperienceReleaseDescriptorAuthenticationError.digestMismatch
        }
        return bytes
    }

    private func decodeAndValidateDescriptor(_ bytes: Data) throws
        -> ExperienceReleaseDescriptor
    {
        do {
            try StrictJSONDuplicateKeyValidator.validate(bytes)
            guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
            else {
                throw ExperienceReleaseDescriptorAuthenticationError.invalidDescriptor
            }
            try validateShapeAndBounds(object)
            let descriptor = try JSONDecoder().decode(
                ExperienceReleaseDescriptor.self,
                from: bytes
            )
            guard descriptor.schemaVersion == ExperienceReleaseDescriptorLimits.schemaVersion else {
                throw ExperienceReleaseDescriptorAuthenticationError.invalidDescriptor
            }
            try validateIdentity(descriptor.identity)
            return descriptor
        } catch let error as ExperienceReleaseDescriptorAuthenticationError {
            throw error
        } catch {
            throw ExperienceReleaseDescriptorAuthenticationError.invalidDescriptor
        }
    }

    private func validateShapeAndBounds(_ root: [String: Any]) throws {
        try ExperienceReleaseDescriptorSchemaValidator.validate(root)
        try validateJSONValue(root, field: nil)
        try validateRenderValue(root["render"], field: "render")
        try validateArtifactReferences(root)
    }

    private func validateJSONValue(_ value: Any, field: String?) throws {
        if value is String { return }
        if let values = value as? [Any] {
            let maximum: Int?
            switch field {
            case "screens": maximum = ExperienceReleaseDescriptorLimits.screenCount
            case "products": maximum = ExperienceReleaseDescriptorLimits.productCount
            case "placements": maximum = ExperienceReleaseDescriptorLimits.placementCount
            case "assets", "images", "fonts": maximum = ExperienceReleaseDescriptorLimits.assetCount
            case "transitions": maximum = ExperienceReleaseDescriptorLimits.transitionCount
            case "textInputs": maximum = ExperienceReleaseDescriptorLimits.textInputCount
            case "requiredCapabilities":
                maximum = ExperienceReleaseDescriptorLimits.requiredCapabilityCount
            default: maximum = nil
            }
            if let maximum, values.count > maximum {
                throw ExperienceReleaseDescriptorAuthenticationError.malformedBounds(
                    field ?? "array"
                )
            }
            for item in values {
                try validateJSONValue(item, field: field)
            }
            return
        }
        if let object = value as? [String: Any] {
            for (key, item) in object {
                if key == "sizeBytes", let number = item as? NSNumber {
                    guard CFGetTypeID(number) != CFBooleanGetTypeID(),
                          number.doubleValue.rounded() == number.doubleValue,
                          number.doubleValue >= 0,
                          number.doubleValue
                            <= Double(ExperienceReleaseDescriptorLimits.artifactAggregateBytes)
                    else {
                        throw ExperienceReleaseDescriptorAuthenticationError.malformedBounds(
                            "sizeBytes"
                        )
                    }
                }
                try validateJSONValue(item, field: key)
            }
        }
    }

    private func validateRenderValue(_ value: Any?, field: String) throws {
        if let object = value as? [String: Any] {
            for (key, item) in object {
                if ["path", "key", "sourceKey", "member"].contains(key),
                   let path = item as? String {
                    guard isSafeRelativeArtifactPath(path) else {
                        throw ExperienceReleaseDescriptorAuthenticationError.unsafeArtifactKey(
                            path
                        )
                    }
                    if let sha256 = object["sha256"] as? String,
                       isLowercaseSHA256(sha256),
                       !path.contains(sha256) {
                        throw ExperienceReleaseDescriptorAuthenticationError.unsafeArtifactKey(
                            path
                        )
                    }
                }
                try validateRenderValue(item, field: key)
            }
        } else if let values = value as? [Any] {
            for item in values {
                try validateRenderValue(item, field: field)
            }
        } else if let string = value as? String, string.contains("://") {
            throw ExperienceReleaseDescriptorAuthenticationError.unsafeArtifactKey(string)
        }
    }

    private func requiredCapabilities(
        in requirements: [String: ExperienceReleaseJSONValue]
    ) throws -> [String] {
        guard let value = requirements["requiredCapabilities"] else { return [] }
        guard case .array(let values) = value,
              values.count <= ExperienceReleaseDescriptorLimits.requiredCapabilityCount else {
            throw ExperienceReleaseDescriptorAuthenticationError.malformedBounds(
                "requiredCapabilities"
            )
        }
        let capabilities = try values.map { value in
            guard case .string(let capability) = value,
                  !capability.isEmpty,
                  capability.utf8.count <= ExperienceReleaseDescriptorLimits.keyIDBytes else {
                throw ExperienceReleaseDescriptorAuthenticationError.malformedBounds(
                    "requiredCapabilities"
                )
            }
            return capability
        }
        guard zip(capabilities, capabilities.dropFirst()).allSatisfy({ lhs, rhs in
            lhs.utf16.lexicographicallyPrecedes(rhs.utf16)
        }) else {
            throw ExperienceReleaseDescriptorAuthenticationError.malformedBounds(
                "requiredCapabilities"
            )
        }
        return capabilities
    }

    private func validateRuntimeRequirements(
        _ requirements: [String: ExperienceReleaseJSONValue],
        supported: ExperienceReleaseSupportedRuntime
    ) throws {
        guard case .string(let minimumSdkVersion) = requirements["minimumSdkVersion"],
              case .string(let runtimeRevision) = requirements["runtimeRevision"],
              case .object(let luau) = requirements["luau"],
              case .string(let luauRevision) = luau["revision"],
              case .array(let bytecodeValues) = luau["bytecodeVersions"],
              case .object(let sceneFormat) = requirements["sceneFormat"],
              case .number(let sceneMajorNumber) = sceneFormat["major"],
              case .number(let sceneMinorNumber) = sceneFormat["minor"],
              let currentSdk = SemanticVersion(supported.currentSdkVersion),
              let minimumSdk = SemanticVersion(minimumSdkVersion),
              currentSdk >= minimumSdk,
              supported.supportedRuntimeRevisions.contains(runtimeRevision),
              let supportedBytecodeVersions = supported
                .supportedLuauRevisions[luauRevision],
              sceneMajorNumber.rounded() == sceneMajorNumber,
              sceneMinorNumber.rounded() == sceneMinorNumber,
              sceneMajorNumber == Double(supported.sceneFormat.major),
              sceneMinorNumber <= Double(supported.sceneFormat.minor),
              case .object(let timezoneData) = requirements["timezoneData"],
              case .string("iana-tzdb") = timezoneData["format"],
              case .string(let timezoneRevision) = timezoneData["revision"],
              case .string(let timezoneSHA256) = timezoneData["sha256"],
              timezoneRevision == supported.timezoneDataRevision,
              timezoneSHA256 == supported.timezoneDataSHA256,
              SignedTimezoneBundle.installed != nil else {
            throw ExperienceReleaseDescriptorAuthenticationError.unsupportedRuntime(
                "runtime"
            )
        }
        let declaredBytecodeVersions = try bytecodeValues.map { value -> Int in
            guard case .number(let number) = value,
                  number.rounded() == number,
                  (0...65_535).contains(number) else {
                throw ExperienceReleaseDescriptorAuthenticationError.invalidDescriptor
            }
            return Int(number)
        }
        guard Set(declaredBytecodeVersions).isSubset(of: supportedBytecodeVersions) else {
            throw ExperienceReleaseDescriptorAuthenticationError.unsupportedRuntime(
                "luau_bytecode"
            )
        }
        let required = try requiredCapabilities(in: requirements)
        let unsupported = required.filter {
            !supported.supportedCapabilities.contains($0)
        }.sorted()
        guard unsupported.isEmpty else {
            throw ExperienceReleaseDescriptorAuthenticationError.unsupportedCapabilities(
                unsupported
            )
        }
    }

    private func validateArtifactReferences(_ root: [String: Any]) throws {
        var uniqueSizesByDigest: [String: Int] = [:]
        try collectArtifactReferences(root, into: &uniqueSizesByDigest)
        let aggregate = try uniqueSizesByDigest.values.reduce(0) { total, size in
            let (sum, overflow) = total.addingReportingOverflow(size)
            guard !overflow,
                  sum <= ExperienceReleaseDescriptorLimits.artifactAggregateBytes else {
                throw ExperienceReleaseDescriptorAuthenticationError.malformedBounds(
                    "artifactAggregateBytes"
                )
            }
            return sum
        }
        guard aggregate <= ExperienceReleaseDescriptorLimits.artifactAggregateBytes else {
            throw ExperienceReleaseDescriptorAuthenticationError.malformedBounds(
                "artifactAggregateBytes"
            )
        }
    }

    private func validateRuntimeBindings(
        _ screenBehaviors: [[String: ExperienceReleaseJSONValue]]
    ) throws {
        for screen in screenBehaviors {
            guard case .array(let controls) = screen["controls"] else { continue }
            for value in controls {
                guard case .object(let control) = value,
                      case .object(let behavior) = control["behavior"],
                      case .string("script") = behavior["kind"] else { continue }
                throw ExperienceReleaseDescriptorAuthenticationError.unsupportedRuntime(
                    "screen_actions"
                )
            }
        }
    }

    private func collectArtifactReferences(
        _ value: Any,
        into uniqueSizesByDigest: inout [String: Int]
    ) throws {
        if let object = value as? [String: Any] {
            // Bare sha256 and key fields also occur in timezone pins and response
            // schemas. Artifact references are the only objects with sizeBytes;
            // the schema then requires their storage key and digest as a set.
            if object["sizeBytes"] != nil {
                guard let key = object["key"] as? String,
                      let digest = object["sha256"] as? String,
                      let sizeNumber = object["sizeBytes"] as? NSNumber,
                      CFGetTypeID(sizeNumber) != CFBooleanGetTypeID(),
                      sizeNumber.doubleValue.rounded() == sizeNumber.doubleValue,
                      sizeNumber.doubleValue >= 0,
                      sizeNumber.doubleValue <= Double(Int.max),
                      isLowercaseSHA256(digest) else {
                    throw ExperienceReleaseDescriptorAuthenticationError.malformedBounds(
                        "artifact"
                    )
                }
                let size = Int(sizeNumber.doubleValue)
                let maximum: Int
                if key == "renders/sha256/\(digest).riv" {
                    maximum = ExperienceReleaseDescriptorLimits.rivArtifactBytes
                } else if key == "screen-behavior/sha256/\(digest).bin" {
                    maximum = 4 * 1_024 * 1_024
                } else if key.hasPrefix("assets/sha256/\(digest)."),
                          let fileExtension = key.split(separator: ".").last,
                          ["png", "jpg", "webp", "ttf", "otf", "bin"]
                            .contains(String(fileExtension)) {
                    maximum = ExperienceReleaseDescriptorLimits.externalAssetBytes
                } else {
                    throw ExperienceReleaseDescriptorAuthenticationError.unsafeArtifactKey(key)
                }
                guard size <= maximum else {
                    throw ExperienceReleaseDescriptorAuthenticationError.malformedBounds(
                        "sizeBytes"
                    )
                }
                if let previous = uniqueSizesByDigest[digest], previous != size {
                    throw ExperienceReleaseDescriptorAuthenticationError.malformedBounds(
                        "artifactDigest"
                    )
                }
                uniqueSizesByDigest[digest] = size
            }
            for item in object.values {
                try collectArtifactReferences(item, into: &uniqueSizesByDigest)
            }
        } else if let values = value as? [Any] {
            for item in values {
                try collectArtifactReferences(item, into: &uniqueSizesByDigest)
            }
        }
    }

    private func validateKeys(
        _ keys: [ExperiencePackageAuthorizationKey]
    ) throws -> [String: Data] {
        guard !keys.isEmpty, keys.count <= 256 else {
            throw ExperienceReleaseDescriptorAuthenticationError.invalidAuthorizationKeys
        }
        var result: [String: Data] = [:]
        for key in keys {
            guard !key.keyID.isEmpty,
                  key.keyID.utf8.count <= ExperienceReleaseDescriptorLimits.keyIDBytes,
                  key.ed25519PublicKeyBytes.count == 32,
                  result.updateValue(
                    key.ed25519PublicKeyBytes,
                    forKey: key.keyID
                  ) == nil else {
                throw ExperienceReleaseDescriptorAuthenticationError.invalidAuthorizationKeys
            }
        }
        return result
    }

    private func canonicalBase64(_ value: String, maximumDecodedBytes: Int) -> Data? {
        let maximumEncodedBytes = 4 * ((maximumDecodedBytes + 2) / 3)
        guard !value.isEmpty,
              value.utf8.count <= maximumEncodedBytes,
              value.utf8.count.isMultiple(of: 4),
              value.utf8.allSatisfy({
                (65...90).contains($0) || (97...122).contains($0)
                    || (48...57).contains($0) || $0 == 0x2b || $0 == 0x2f || $0 == 0x3d
              }),
              let decoded = Data(base64Encoded: value),
              decoded.count <= maximumDecodedBytes,
              decoded.base64EncodedString() == value else {
            return nil
        }
        return decoded
    }

    private func isLowercaseSHA256(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private func isZodOffsetDateTime(_ value: String) -> Bool {
        // Mirrors z.iso.datetime({ offset: true }): calendar-valid YYYY-MM-DD,
        // minute precision or finer, and either Z or a colon-delimited offset.
        let pattern = #"^(?:(?:[0-9][0-9][2468][048]|[0-9][0-9][13579][26]|[0-9][0-9]0[48]|[02468][048]00|[13579][26]00)-02-29|[0-9]{4}-(?:(?:0[13578]|1[02])-(?:0[1-9]|[12][0-9]|3[01])|(?:0[469]|11)-(?:0[1-9]|[12][0-9]|30)|(?:02)-(?:0[1-9]|1[0-9]|2[0-8])))T(?:[01][0-9]|2[0-3]):[0-5][0-9](?::[0-5][0-9](?:\.[0-9]+)?)?(?:Z|[+-](?:[01][0-9]|2[0-3]):[0-5][0-9])$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }

    private func isSafeRelativeArtifactPath(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= ExperienceReleaseDescriptorLimits.genericStringBytes,
              !value.hasPrefix("/"), !value.contains("\\"), !value.contains("://") else {
            return false
        }
        return value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }
}
