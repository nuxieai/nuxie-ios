import CryptoKit
import Foundation

private struct NuxPackageSwiftVerification {
    let signature: NuxPackageSignatureEnvelopeV1
    let signatureBytes: Data
    let manifestBytes: Data
    let manifest: NuxPackageManifestV1
    let sceneBytes: Data
    let journeyBytes: Data
}

enum NuxPackageSwiftVerifier {
    static func authenticate(
        member: (String) -> Data?,
        memberNames: Set<String>,
        authorizationKeys: [String: Data],
        expectedExperienceID: String,
        expectedBuildID: String,
        preparedExternalAssets: [String: URL],
        journeyDecoder: @Sendable (Data) throws -> JourneyDocument
    ) throws -> AuthenticatedRuntimePayload {
        let verified = try verify(member: member, memberNames: memberNames)
        let envelope = verified.signature
        guard let keyBytes = authorizationKeys[envelope.keyId] else {
            throw ExperiencePackageAuthenticationError.unknownKey(envelope.keyId)
        }
        let publicKey: Curve25519.Signing.PublicKey
        do {
            publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: keyBytes)
        } catch {
            throw ExperiencePackageAuthenticationError.invalidAuthorizationKeys
        }
        guard publicKey.isValidSignature(
            verified.signatureBytes,
            for: verified.manifestBytes
        ) else {
            throw ExperiencePackageAuthenticationError.invalidSignature
        }
        guard verified.manifest.identity.experienceId == expectedExperienceID,
              verified.manifest.identity.buildId == expectedBuildID else {
            throw ExperiencePackageAuthenticationError.identityMismatch
        }
        let assets = try authenticateAssets(
            verified.manifest,
            member: member,
            preparedExternalAssets: preparedExternalAssets
        )
        let journey: JourneyDocument
        do {
            journey = try journeyDecoder(verified.journeyBytes)
        } catch {
            throw ExperiencePackageAuthenticationError.invalidManifest
        }
        guard journey.schemaVersion == 1,
              journey.schemaVersion == verified.manifest.journey.schemaVersion else {
            throw ExperiencePackageAuthenticationError.invalidManifest
        }
        return AuthenticatedRuntimePayload(
            authenticatedKeyID: envelope.keyId,
            manifest: verified.manifest,
            journey: journey,
            sceneBytes: verified.sceneBytes,
            assets: assets
        )
    }

    private static func verify(
        member: (String) -> Data?,
        memberNames: Set<String>
    ) throws -> NuxPackageSwiftVerification {
        guard let manifestBytes = member("manifest"),
              let signatureEnvelopeBytes = member("signature"),
              let sceneBytes = member("scene"),
              let journeyBytes = member("journey") else {
            throw ExperiencePackageAuthenticationError.invalidInventory
        }

        try validateStrictJSON(manifestBytes, kind: .manifest)
        guard let manifest = try? JSONDecoder().decode(
            NuxPackageManifestV1.self,
            from: manifestBytes
        ) else {
            throw ExperiencePackageAuthenticationError.invalidManifest
        }
        try validateManifest(manifest)
        try validateMemberBytes(
            manifest,
            member: member,
            memberNames: memberNames,
            sceneBytes: sceneBytes,
            journeyBytes: journeyBytes
        )

        guard sceneBytes.starts(with: Data("RIVE".utf8)) else {
            throw ExperiencePackageAuthenticationError.invalidScene
        }
        try validateJourneyEnvelope(journeyBytes, manifest: manifest)

        try validateStrictJSON(signatureEnvelopeBytes, kind: .signature)
        guard let signature = try? JSONDecoder().decode(
            NuxPackageSignatureEnvelopeV1.self,
            from: signatureEnvelopeBytes
        ), signature.version == 1,
        signature.signs == "manifest",
        signature.algorithm == "ed25519",
        !signature.keyId.isEmpty,
        signature.keyId.utf8.count <= 256,
        let signatureBytes = Data(base64Encoded: signature.signatureBase64),
        signatureBytes.count == 64 else {
            throw ExperiencePackageAuthenticationError.malformedSignature
        }

        return NuxPackageSwiftVerification(
            signature: signature,
            signatureBytes: signatureBytes,
            manifestBytes: manifestBytes,
            manifest: manifest,
            sceneBytes: sceneBytes,
            journeyBytes: journeyBytes
        )
    }

    private enum DocumentKind { case manifest, signature }

    private static func validateStrictJSON(
        _ data: Data,
        kind: DocumentKind
    ) throws {
        do {
            try StrictJSONDuplicateKeyValidator.validate(data)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ExperiencePackageAuthenticationError.invalidManifest
            }
            switch kind {
            case .manifest:
                try NuxManifestUnknownFieldValidator.validate(object)
            case .signature:
                guard Set(object.keys) == [
                    "version", "signs", "algorithm", "keyId", "signatureBase64"
                ] else {
                    throw ExperiencePackageAuthenticationError.malformedSignature
                }
            }
        } catch let error as ExperiencePackageAuthenticationError {
            throw error
        } catch {
            throw kind == .signature
                ? ExperiencePackageAuthenticationError.malformedSignature
                : ExperiencePackageAuthenticationError.invalidManifest
        }
    }

    private static func validateManifest(_ manifest: NuxPackageManifestV1) throws {
        guard manifest.version == 1,
              !manifest.identity.experienceId.isEmpty,
              !manifest.identity.buildId.isEmpty,
              !manifest.identity.appId.isEmpty,
              !manifest.identity.environment.isEmpty,
              isUInt32(manifest.sceneFormat.major),
              isUInt32(manifest.sceneFormat.minor),
              manifest.producer.luau.bytecodeVersions.allSatisfy(isUInt32),
              manifest.requiredCapabilities.isEmpty,
              manifest.scene.member == "scene",
              manifest.journey.member == "journey",
              manifest.journey.schemaVersion == 1,
              manifest.scene.sizeBytes >= 0,
              manifest.journey.sizeBytes >= 0 else {
            throw ExperiencePackageAuthenticationError.invalidManifest
        }
        let screenIDs = manifest.screens.map(\.screenId)
        guard Set(screenIDs).count == screenIDs.count,
              screenIDs.contains(manifest.entry.screenId) else {
            throw ExperiencePackageAuthenticationError.invalidManifest
        }
        for input in manifest.textInputs {
            guard !input.inputId.isEmpty,
                  !input.screenId.isEmpty,
                  !input.artboardId.isEmpty,
                  !input.viewNodeId.isEmpty,
                  !input.renderedNodeId.isEmpty,
                  !input.riveTextObjectKey.isEmpty,
                  !input.riveTextRunObjectKey.isEmpty,
                  !input.riveTextName.isEmpty,
                  !input.riveTextRunName.isEmpty,
                  !input.style.fontFamily.isEmpty,
                  !input.style.fontWeight.isEmpty,
                  ["normal", "italic"].contains(input.style.fontStyle),
                  !input.style.fontAssetRiveUniqueName.isEmpty,
                  !input.geometry.xPath.isEmpty,
                  !input.geometry.yPath.isEmpty,
                  !input.geometry.widthPath.isEmpty,
                  !input.geometry.heightPath.isEmpty,
                  !input.geometry.rotationPath.isEmpty,
                  !input.geometry.scaleXPath.isEmpty,
                  !input.geometry.scaleYPath.isEmpty,
                  input.style.fontSize.isFinite && input.style.fontSize > 0,
                  input.style.lineHeight.isFinite && input.style.lineHeight > 0,
                  input.style.letterSpacing.isFinite,
                  input.maxLength.map({ $0 > 0 && isUInt32($0) }) ?? true else {
                throw ExperiencePackageAuthenticationError.invalidManifest
            }
        }
    }

    private static func validateMemberBytes(
        _ manifest: NuxPackageManifestV1,
        member: (String) -> Data?,
        memberNames: Set<String>,
        sceneBytes: Data,
        journeyBytes: Data
    ) throws {
        var inventory: [String: NuxPackageManifestV1.InventoryMember] = [:]
        for member in manifest.members {
            guard inventory.updateValue(member, forKey: member.name) == nil,
                  member.sizeBytes >= 0,
                  isSHA256(member.sha256) else {
                throw ExperiencePackageAuthenticationError.invalidInventory
            }
        }
        guard memberNames.subtracting(["signature"]) == Set(inventory.keys),
              let manifestRecord = inventory["manifest"],
              manifestRecord.role == "manifest",
              manifestRecord.sha256 == String(repeating: "0", count: 64),
              manifestRecord.sizeBytes == 0 else {
            throw ExperiencePackageAuthenticationError.invalidInventory
        }
        for (name, record) in inventory where name != "manifest" {
            guard let bytes = member(name),
                  bytes.count == record.sizeBytes,
                  SHA256Provider.hexDigest(bytes) == record.sha256,
                  ["scene", "journey", "asset"].contains(record.role) else {
                throw ExperiencePackageAuthenticationError.invalidInventory
            }
        }
        guard let sceneRecord = inventory["scene"], sceneRecord.role == "scene",
              sceneRecord.sha256 == manifest.scene.sha256,
              sceneRecord.sizeBytes == manifest.scene.sizeBytes,
              sceneBytes.count == manifest.scene.sizeBytes,
              let journeyRecord = inventory["journey"], journeyRecord.role == "journey",
              journeyRecord.sha256 == manifest.journey.sha256,
              journeyRecord.sizeBytes == manifest.journey.sizeBytes,
              journeyBytes.count == manifest.journey.sizeBytes else {
            throw ExperiencePackageAuthenticationError.invalidInventory
        }
    }

    private static func validateJourneyEnvelope(
        _ bytes: Data,
        manifest: NuxPackageManifestV1
    ) throws {
        guard let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let version = object["schemaVersion"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: version.objCType)),
              version.int64Value >= 0,
              version.uint64Value == UInt64(manifest.journey.schemaVersion) else {
            throw ExperiencePackageAuthenticationError.invalidManifest
        }
    }

    private static func authenticateAssets(
        _ manifest: NuxPackageManifestV1,
        member readMember: (String) -> Data?,
        preparedExternalAssets: [String: URL]
    ) throws -> [AuthenticatedRuntimeAsset] {
        var result: [AuthenticatedRuntimeAsset] = []
        var ids = Set<UInt32>()
        var names = Set<String>()
        var externalAssetCount = 0
        var externalTotalBytes = 0

        func append(
            kind: AuthenticatedRuntimeAsset.Kind,
            id: UInt64,
            name: String,
            location: NuxPackageAssetLocation,
            hash: String,
            size: Int,
            contentType: String,
            required: Bool
        ) throws {
            guard let assetID = UInt32(exactly: id),
                  ids.insert(assetID).inserted,
                  !name.isEmpty,
                  name.utf8.count <= NuxPackageLimits.assetUniqueNameBytes,
                  names.insert(name).inserted,
                  size >= 0,
                  isSHA256(hash),
                  !contentType.isEmpty else {
                throw ExperiencePackageAuthenticationError.invalidAsset(name)
            }
            let sourceKey: String
            let bytes: Data?
            switch location {
            case .embedded(let member):
                sourceKey = member
                guard member.utf8.count <= NuxPackageLimits.assetSourceKeyBytes,
                      isContentAddressed(member, sha256: hash),
                      manifest.members.contains(where: {
                          $0.name == member && $0.role == "asset" &&
                              $0.sha256 == hash && $0.sizeBytes == size
                      }),
                      let owned = readMember(member),
                      owned.count == size,
                      SHA256Provider.hexDigest(owned) == hash else {
                    throw ExperiencePackageAuthenticationError.invalidAsset(name)
                }
                bytes = owned
            case .external(let key):
                sourceKey = key
                guard size <= NuxPackageLimits.externalAssetBytes,
                      key.utf8.count <= NuxPackageLimits.assetSourceKeyBytes,
                      isContentAddressed(key, sha256: hash) else {
                    throw ExperiencePackageAuthenticationError.invalidAsset(name)
                }
                if let url = preparedExternalAssets[name] {
                    let read = try BoundedFileIO.read(
                        at: url,
                        maximumBytes: NuxPackageLimits.externalAssetBytes
                    )
                    guard read.digest.byteCount == size,
                          read.digest.sha256 == hash else {
                        throw ExperiencePackageAuthenticationError.invalidAsset(name)
                    }
                    bytes = read.data
                } else if required {
                    throw ExperiencePackageAuthenticationError.invalidAsset(name)
                } else {
                    bytes = nil
                }
                let (next, overflow) = externalTotalBytes.addingReportingOverflow(size)
                guard !overflow, next <= NuxPackageLimits.externalAssetTotalBytes else {
                    throw ExperiencePackageAuthenticationError.invalidAsset(name)
                }
                externalTotalBytes = next
                externalAssetCount += 1
                guard externalAssetCount <= NuxPackageLimits.externalAssetCount else {
                    throw ExperiencePackageAuthenticationError.invalidAsset("asset count")
                }
            }
            result.append(AuthenticatedRuntimeAsset(
                kind: kind,
                riveAssetID: assetID,
                riveUniqueName: name,
                sourceKey: sourceKey,
                contentType: contentType,
                sha256: hash,
                required: required,
                bytes: bytes
            ))
        }

        for asset in manifest.assets.images {
            guard ["image/png", "image/jpeg", "image/webp"]
                .contains(asset.contentType) else {
                throw ExperiencePackageAuthenticationError.invalidAsset(asset.riveUniqueName)
            }
            try append(kind: .image, id: asset.riveAssetId,
                       name: asset.riveUniqueName, location: asset.location,
                       hash: asset.sha256, size: asset.sizeBytes,
                       contentType: asset.contentType, required: asset.required)
        }
        for asset in manifest.assets.fonts {
            guard ["normal", "italic"].contains(asset.style),
                  ["ttf", "otf"].contains(asset.format),
                  ["font/ttf", "font/otf", "application/octet-stream"]
                    .contains(asset.contentType) else {
                throw ExperiencePackageAuthenticationError.invalidAsset(asset.riveUniqueName)
            }
            try append(kind: .font, id: asset.riveAssetId,
                       name: asset.riveUniqueName, location: asset.location,
                       hash: asset.sha256, size: asset.sizeBytes,
                       contentType: asset.contentType, required: asset.required)
        }
        return result
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private static func isUInt32(_ value: Int) -> Bool {
        value >= 0 && UInt64(value) <= UInt64(UInt32.max)
    }

    private static func isContentAddressed(_ path: String, sha256: String) -> Bool {
        guard isSHA256(sha256), !path.contains("\\"), !path.contains("..") else {
            return false
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "assets", parts[1] == "sha256" else {
            return false
        }
        let file = String(parts[2])
        guard let separator = file.lastIndex(of: "."),
              String(file[..<separator]) == sha256 else { return false }
        return ["png", "jpg", "jpeg", "webp", "ttf", "otf"]
            .contains(String(file[file.index(after: separator)...]))
    }
}

private enum StrictJSONDuplicateKeyValidator {
    static func validate(_ data: Data) throws {
        var parser = Parser(bytes: Array(data))
        try parser.parseDocument()
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        mutating func parseDocument() throws {
            skipWhitespace()
            try parseValue()
            skipWhitespace()
            guard index == bytes.count else { throw Failure.invalid }
        }

        mutating func parseValue() throws {
            guard index < bytes.count else { throw Failure.invalid }
            switch bytes[index] {
            case 0x7b: try parseObject()
            case 0x5b: try parseArray()
            case 0x22: _ = try parseString()
            case 0x74: try consume("true")
            case 0x66: try consume("false")
            case 0x6e: try consume("null")
            default: try parseNumber()
            }
        }

        mutating func parseObject() throws {
            index += 1
            skipWhitespace()
            var keys = Set<String>()
            if consumeIf(0x7d) { return }
            while true {
                let key = try parseString()
                guard keys.insert(key).inserted else { throw Failure.duplicate }
                skipWhitespace()
                guard consumeIf(0x3a) else { throw Failure.invalid }
                skipWhitespace()
                try parseValue()
                skipWhitespace()
                if consumeIf(0x7d) { return }
                guard consumeIf(0x2c) else { throw Failure.invalid }
                skipWhitespace()
            }
        }

        mutating func parseArray() throws {
            index += 1
            skipWhitespace()
            if consumeIf(0x5d) { return }
            while true {
                try parseValue()
                skipWhitespace()
                if consumeIf(0x5d) { return }
                guard consumeIf(0x2c) else { throw Failure.invalid }
                skipWhitespace()
            }
        }

        mutating func parseString() throws -> String {
            guard consumeIf(0x22) else { throw Failure.invalid }
            let start = index - 1
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                if byte == 0x22 {
                    let token = Data(bytes[start..<index])
                    guard let value = try? JSONDecoder().decode(String.self, from: token) else {
                        throw Failure.invalid
                    }
                    return value
                }
                guard byte >= 0x20 else { throw Failure.invalid }
                if byte == 0x5c {
                    guard index < bytes.count else { throw Failure.invalid }
                    let escaped = bytes[index]
                    index += 1
                    if escaped == 0x75 {
                        guard index + 4 <= bytes.count,
                              bytes[index..<index + 4].allSatisfy({
                                  (48...57).contains($0) || (65...70).contains($0) ||
                                      (97...102).contains($0)
                              }) else { throw Failure.invalid }
                        index += 4
                    } else if ![0x22, 0x5c, 0x2f, 0x62, 0x66, 0x6e, 0x72, 0x74]
                        .contains(escaped) {
                        throw Failure.invalid
                    }
                }
            }
            throw Failure.invalid
        }

        mutating func parseNumber() throws {
            let start = index
            while index < bytes.count,
                  [0x2d, 0x2b, 0x2e, 0x45, 0x65].contains(bytes[index]) ||
                    (48...57).contains(bytes[index]) {
                index += 1
            }
            guard index > start,
                  let text = String(bytes: bytes[start..<index], encoding: .utf8),
                  Double(text) != nil else { throw Failure.invalid }
        }

        mutating func consume(_ text: StaticString) throws {
            let expected = Array(String(describing: text).utf8)
            guard index + expected.count <= bytes.count,
                  Array(bytes[index..<index + expected.count]) == expected else {
                throw Failure.invalid
            }
            index += expected.count
        }

        mutating func consumeIf(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0a, 0x0d].contains(bytes[index]) {
                index += 1
            }
        }
    }

    private enum Failure: Error { case invalid, duplicate }
}

private enum NuxManifestUnknownFieldValidator {
    static func validate(_ root: [String: Any]) throws {
        try exact(root, ["version", "identity", "producer", "sceneFormat",
                         "requiredCapabilities", "scene", "journey", "entry",
                         "screens", "textInputs", "assets", "members"])
        try exact(dict(root, "identity"), ["experienceId", "buildId", "appId", "environment"])
        let producer = try dict(root, "producer")
        try exact(producer, ["compilerCommit", "compilerVersion", "runtimeRevision",
                             "luau", "minRuntime"])
        try exact(dict(producer, "luau"), ["revision", "bytecodeVersions"])
        try exact(dict(root, "sceneFormat"), ["major", "minor"])
        try exact(dict(root, "scene"), ["member", "sha256", "sizeBytes"])
        try exact(dict(root, "journey"), ["member", "sha256", "sizeBytes", "schemaVersion"])
        try exact(dict(root, "entry"), ["screenId"])
        for screen in try dictionaries(root, "screens") {
            try exact(screen, ["screenId", "artboardId", "artboardName", "width", "height"])
        }
        for input in try dictionaries(root, "textInputs") {
            try exact(input, ["inputId", "screenId", "artboardId", "viewNodeId",
                              "renderedNodeId", "riveTextObjectKey", "riveTextRunObjectKey",
                              "riveTextName", "riveTextRunName", "value", "editable", "geometry",
                              "style"], optional: ["placeholder", "keyboardType", "secureTextEntry",
                                                   "multiline", "maxLength", "responseFieldKey"])
            try exact(dict(input, "geometry"), ["xPath", "yPath", "widthPath", "heightPath",
                                                 "rotationPath", "scaleXPath", "scaleYPath"])
            try exact(dict(input, "style"), ["fontFamily", "fontWeight", "fontStyle", "fontSize",
                                              "lineHeight", "letterSpacing", "color",
                                              "fontAssetRiveUniqueName"], optional: ["textAlign"])
        }
        let assets = try dict(root, "assets")
        try exact(assets, ["images", "fonts"])
        for image in try dictionaries(assets, "images") {
            try exact(image, ["location", "riveAssetId", "riveUniqueName", "sha256",
                              "sizeBytes", "contentType", "required"])
            try validateLocation(dict(image, "location"))
        }
        for font in try dictionaries(assets, "fonts") {
            try exact(font, ["location", "riveAssetId", "riveUniqueName", "family", "weight",
                             "style", "sha256", "sizeBytes", "contentType", "format", "required"])
            try validateLocation(dict(font, "location"))
        }
        for member in try dictionaries(root, "members") {
            try exact(member, ["name", "role", "sha256", "sizeBytes", "contentType"])
        }
    }

    private static func validateLocation(_ value: [String: Any]) throws {
        guard let kind = value["kind"] as? String else { throw Failure.invalid }
        switch kind {
        case "external": try exact(value, ["kind", "key"])
        case "embedded": try exact(value, ["kind", "member"])
        default: throw Failure.invalid
        }
    }

    private static func exact(
        _ object: [String: Any],
        _ required: Set<String>,
        optional: Set<String> = []
    ) throws {
        let keys = Set(object.keys)
        guard required.isSubset(of: keys), keys.isSubset(of: required.union(optional)) else {
            throw Failure.invalid
        }
    }

    private static func dict(_ object: [String: Any], _ key: String) throws -> [String: Any] {
        guard let value = object[key] as? [String: Any] else { throw Failure.invalid }
        return value
    }

    private static func dictionaries(
        _ object: [String: Any],
        _ key: String
    ) throws -> [[String: Any]] {
        guard let value = object[key] as? [[String: Any]] else { throw Failure.invalid }
        return value
    }

    private enum Failure: Error { case invalid }
}
