import Foundation

enum NuxPackageLimits {
    static let acquisitionContractVersion = 1
    static let packageBytes = 64 * 1_024 * 1_024
    static let manifestBytes = 4 * 1_024 * 1_024
    static let journeyBytes = 8 * 1_024 * 1_024
    static let signatureBytes = 64 * 1_024
    static let externalAssetBytes = 32 * 1_024 * 1_024
    static let externalAssetCount = 1_024
    static let externalAssetTotalBytes = 128 * 1_024 * 1_024
    static let assetUniqueNameBytes = 4 * 1_024
    static let assetSourceKeyBytes = 4 * 1_024 * 1_024
    static let memberCount = 4_096
}

struct NuxPackageManifestV1: Codable, Equatable, Sendable {
    struct Identity: Codable, Equatable, Sendable {
        let experienceId: String
        let buildId: String
        let appId: String
        let environment: String
    }

    struct Producer: Codable, Equatable, Sendable {
        struct Luau: Codable, Equatable, Sendable {
            let revision: String
            let bytecodeVersions: [Int]
        }

        let compilerCommit: String
        let compilerVersion: String
        let runtimeRevision: String
        let luau: Luau
        let minRuntime: String
    }

    struct SceneFormat: Codable, Equatable, Sendable {
        let major: Int
        let minor: Int
    }

    struct Member: Codable, Equatable, Sendable {
        let member: String
        let sha256: String
        let sizeBytes: Int
    }

    struct JourneyMember: Codable, Equatable, Sendable {
        let member: String
        let sha256: String
        let sizeBytes: Int
        let schemaVersion: Int
    }

    struct Entry: Codable, Equatable, Sendable {
        let screenId: String
    }

    struct Assets: Codable, Equatable, Sendable {
        let images: [NuxPackageImageAsset]
        let fonts: [NuxPackageFontAsset]
    }

    struct InventoryMember: Codable, Equatable, Sendable {
        let name: String
        let role: String
        let sha256: String
        let sizeBytes: Int
        let contentType: String
    }

    let version: Int
    let identity: Identity
    let producer: Producer
    let sceneFormat: SceneFormat
    let requiredCapabilities: [String]
    let scene: Member
    let journey: JourneyMember
    let entry: Entry
    let screens: [NuxPackageScreen]
    let transitions: [NuxPackageTransition]?
    let textInputs: [NuxPackageTextInput]
    let assets: Assets
    let members: [InventoryMember]

    var lifecycleTransitions: [NuxPackageTransition] {
        transitions ?? []
    }
}

struct NuxPackageScreen: Codable, Equatable, Sendable {
    let screenId: String
    let artboardId: String
    let artboardName: String
    let width: Double
    let height: Double
    let exit: NuxPackageScreenExit?
}

struct NuxPackageScreenExit: Codable, Equatable, Sendable {
    let completeEventName: String
    let durationMs: Int
}

struct NuxPackageTransition: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Equatable, Sendable {
        case choreographed
    }

    struct Endpoint: Codable, Equatable, Sendable {
        let completeEventName: String
    }

    struct Reverse: Codable, Equatable, Sendable {
        let durationMs: Int?
        let incomingOnTop: Bool?
        let source: Endpoint
        let destination: Endpoint
    }

    let id: String
    let kind: Kind
    let sourceScreenId: String
    let destinationScreenId: String
    let durationMs: Int
    let incomingOnTop: Bool
    let source: Endpoint
    let destination: Endpoint
    let reverse: Reverse?
}

enum NuxPackageAssetLocation: Codable, Equatable, Sendable {
    case external(key: String)
    case embedded(member: String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case key
        case member
    }

    private enum Kind: String, Codable {
        case external
        case embedded
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .external:
            self = .external(key: try container.decode(String.self, forKey: .key))
        case .embedded:
            self = .embedded(member: try container.decode(String.self, forKey: .member))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .external(let key):
            try container.encode(Kind.external, forKey: .kind)
            try container.encode(key, forKey: .key)
        case .embedded(let member):
            try container.encode(Kind.embedded, forKey: .kind)
            try container.encode(member, forKey: .member)
        }
    }

    var contentAddressedPath: String {
        switch self {
        case .external(let key): key
        case .embedded(let member): member
        }
    }
}

struct NuxPackageImageAsset: Codable, Equatable, Sendable {
    let location: NuxPackageAssetLocation
    let riveAssetId: UInt64
    let riveUniqueName: String
    let sha256: String
    let sizeBytes: Int
    let contentType: String
    let required: Bool
}

struct NuxPackageFontAsset: Codable, Equatable, Sendable {
    let location: NuxPackageAssetLocation
    let riveAssetId: UInt64
    let riveUniqueName: String
    let family: String
    let weight: String
    let style: String
    let sha256: String
    let sizeBytes: Int
    let contentType: String
    let format: String
    let required: Bool
}

struct NuxPackageTextInput: Codable, Equatable, Sendable {
    let inputId: String
    let screenId: String
    let artboardId: String
    let viewNodeId: String
    let renderedNodeId: String
    let riveTextObjectKey: String
    let riveTextRunObjectKey: String
    let riveTextName: String
    let riveTextRunName: String
    let value: String
    let placeholder: String?
    let editable: Bool
    let geometry: NuxPackageTextInputGeometry
    let style: NuxPackageTextInputStyle
    let keyboardType: String?
    let secureTextEntry: Bool?
    let multiline: Bool?
    let maxLength: Int?
    let responseFieldKey: String?
}

struct NuxPackageTextInputGeometry: Codable, Equatable, Sendable {
    let xPath: String
    let yPath: String
    let widthPath: String
    let heightPath: String
    let rotationPath: String
    let scaleXPath: String
    let scaleYPath: String
}

struct NuxPackageTextInputStyle: Codable, Equatable, Sendable {
    let fontFamily: String
    let fontWeight: String
    let fontStyle: String
    let fontSize: Double
    let lineHeight: Double
    let letterSpacing: Double
    let color: UInt32
    let fontAssetRiveUniqueName: String
    let textAlign: String?
}

enum NuxPackageAcquisitionAssetKind: String, Codable, Equatable, Sendable {
    case image
    case font
}

struct NuxPackageAcquisitionIdentity: Equatable, Sendable {
    let experienceId: String
    let buildId: String
}

struct NuxPackageAcquisitionExternalAsset: Equatable, Sendable {
    let kind: NuxPackageAcquisitionAssetKind
    let riveAssetId: UInt32
    let riveUniqueName: String
    let key: String
    let sha256: String
    let sizeBytes: Int
    let required: Bool
}

/// The complete set of untrusted manifest fields the SDK may act on before
/// Swift authentication. It is intentionally incapable of representing
/// journey, product, script, screen, or side-effect metadata.
struct NuxPackageAcquisitionMetadataV1: Equatable, Sendable {
    let contractVersion: Int
    let packageVersion: Int
    let identity: NuxPackageAcquisitionIdentity
    let externalAssets: [NuxPackageAcquisitionExternalAsset]
}

struct NuxPackageAcquisition: Sendable {
    fileprivate let bytes: Data
    fileprivate let members: [String: Range<Int>]
    let metadata: NuxPackageAcquisitionMetadataV1

    init(bytes: Data, metadata: NuxPackageAcquisitionMetadataV1) {
        self.bytes = bytes
        members = [:]
        self.metadata = metadata
    }

    fileprivate init(
        bytes: Data,
        members: [String: Range<Int>],
        metadata: NuxPackageAcquisitionMetadataV1
    ) {
        self.bytes = bytes
        self.members = members
        self.metadata = metadata
    }

    fileprivate func member(named name: String) -> Data? {
        guard let range = members[name] else { return nil }
        return bytes.subdata(in: range)
    }

    fileprivate var memberNames: Set<String> {
        Set(members.keys)
    }
}

struct NuxPackageAuthenticatedContents: Sendable {
    let manifest: NuxPackageManifestV1
    let journey: JourneyDocument
}

private struct NuxPackageAcquisitionManifestV1: Decodable {
    struct Identity: Decodable {
        let experienceId: String
        let buildId: String
    }

    struct Assets: Decodable {
        let images: [Asset]
        let fonts: [Asset]
    }

    struct Asset: Decodable {
        let location: NuxPackageAssetLocation
        let riveAssetId: UInt64
        let riveUniqueName: String
        let sha256: String
        let sizeBytes: UInt64
        let required: Bool
    }

    let version: Int
    let identity: Identity
    let assets: Assets
}

enum NuxPackageReaderError: LocalizedError, Equatable {
    case badMagic
    case unsupportedVersion(UInt32)
    case tooManyMembers(Int)
    case truncated(String)
    case invalidMemberName
    case duplicateMember(String)
    case unalignedMember(String)
    case memberBeforePayload(String)
    case memberOutOfBounds(String)
    case overlappingMembers(String, String)
    case nonZeroPadding
    case missingMember(String)
    case memberTooLarge(String)
    case invalidManifest
    case invalidExternalAsset(String)

    var contractCode: String {
        switch self {
        case .memberTooLarge, .tooManyMembers:
            "acquisition.limit_exceeded"
        case .unsupportedVersion:
            "acquisition.unsupported_version"
        case .missingMember:
            "acquisition.missing_member"
        case .invalidManifest:
            "acquisition.invalid_manifest"
        case .invalidExternalAsset:
            "acquisition.invalid_external_asset"
        default:
            "acquisition.invalid_container"
        }
    }

    var errorDescription: String? {
        "Invalid .nux package: \(String(describing: self))"
    }
}

/// Thin pre-authentication reader. It understands only the v1 header/ToC and
/// the exact untrusted metadata needed for external-asset acquisition. It does
/// not decode journey or other execution metadata.
enum NuxPackageReader {
    private static let magic = Data([0x89, 0x4e, 0x55, 0x58, 0x0d, 0x0a, 0x1a, 0x0a])
    private static let alignment = 16

    static func read(_ data: Data) throws -> NuxPackageAcquisition {
        guard data.count <= NuxPackageLimits.packageBytes else {
            throw NuxPackageReaderError.memberTooLarge("package")
        }
        guard data.count >= 16 else {
            throw NuxPackageReaderError.truncated("header")
        }
        guard data.prefix(8) == magic else {
            throw NuxPackageReaderError.badMagic
        }
        let version = try uint32(data, at: 8)
        guard version == 1 else {
            throw NuxPackageReaderError.unsupportedVersion(version)
        }
        let memberCount = Int(try uint32(data, at: 12))
        guard memberCount <= NuxPackageLimits.memberCount else {
            throw NuxPackageReaderError.tooManyMembers(memberCount)
        }

        var cursor = 16
        var members: [String: Range<Int>] = [:]
        for _ in 0..<memberCount {
            let nameLength = Int(try uint16(data, at: cursor))
            cursor = try adding(cursor, 2, field: "member name length")
            let nameEnd = try adding(cursor, nameLength, field: "member name")
            guard nameEnd <= data.count else {
                throw NuxPackageReaderError.truncated("member name")
            }
            guard let name = String(data: data[cursor..<nameEnd], encoding: .utf8) else {
                throw NuxPackageReaderError.invalidMemberName
            }
            cursor = nameEnd
            let offset = try integer(try uint64(data, at: cursor), field: "member offset")
            cursor = try adding(cursor, 8, field: "member offset")
            let length = try integer(try uint64(data, at: cursor), field: "member length")
            cursor = try adding(cursor, 8, field: "member length")
            guard members[name] == nil else {
                throw NuxPackageReaderError.duplicateMember(name)
            }
            guard offset.isMultiple(of: alignment) else {
                throw NuxPackageReaderError.unalignedMember(name)
            }
            let end = try adding(offset, length, field: "member range")
            guard offset >= cursor, end <= data.count else {
                throw offset < cursor
                    ? NuxPackageReaderError.memberBeforePayload(name)
                    : NuxPackageReaderError.memberOutOfBounds(name)
            }
            members[name] = offset..<end
        }

        let ordered = members.sorted { $0.value.lowerBound < $1.value.lowerBound }
        var previousEnd = cursor
        var previousName = "table of contents"
        for (name, range) in ordered {
            guard range.lowerBound >= cursor else {
                throw NuxPackageReaderError.memberBeforePayload(name)
            }
            guard range.lowerBound >= previousEnd else {
                throw NuxPackageReaderError.overlappingMembers(previousName, name)
            }
            try requireZeroPadding(data[previousEnd..<range.lowerBound])
            previousEnd = range.upperBound
            previousName = name
        }
        try requireZeroPadding(data[previousEnd..<data.endIndex])

        let manifestBytes = try required("manifest", from: data, members: members)
        let signatureBytes = try required("signature", from: data, members: members)
        let journeyBytes = try required("journey", from: data, members: members)
        guard !signatureBytes.isEmpty else {
            throw NuxPackageReaderError.missingMember("signature")
        }
        guard manifestBytes.count <= NuxPackageLimits.manifestBytes,
              journeyBytes.count <= NuxPackageLimits.journeyBytes,
              signatureBytes.count <= NuxPackageLimits.signatureBytes else {
            throw NuxPackageReaderError.memberTooLarge("required member")
        }
        guard members["scene"] != nil else {
            throw NuxPackageReaderError.missingMember("scene")
        }

        let decoder = JSONDecoder()
        guard let manifest = try? decoder.decode(
            NuxPackageAcquisitionManifestV1.self,
            from: manifestBytes
        ), manifest.version == 1,
        !manifest.identity.experienceId.isEmpty,
        !manifest.identity.buildId.isEmpty else {
            throw NuxPackageReaderError.invalidManifest
        }
        let externalAssets = try acquisitionAssets(from: manifest)
        return NuxPackageAcquisition(
            bytes: data,
            members: members,
            metadata: NuxPackageAcquisitionMetadataV1(
                contractVersion: NuxPackageLimits.acquisitionContractVersion,
                packageVersion: manifest.version,
                identity: NuxPackageAcquisitionIdentity(
                    experienceId: manifest.identity.experienceId,
                    buildId: manifest.identity.buildId
                ),
                externalAssets: externalAssets
            )
        )
    }

    /// The single operation allowed to open raw package members for the new
    /// product path. Its only output is the fully authenticated, Swift-owned
    /// runtime payload; pre-signature member evidence never escapes this seam.
    static func authenticate(
        exactPackageBytes: Data,
        authorizationKeys: [String: Data],
        expectedExperienceID: String,
        expectedBuildID: String,
        preparedExternalAssets: [String: URL],
        journeyDecoder: @Sendable (Data) throws -> JourneyDocument
    ) throws -> AuthenticatedRuntimePayload {
        let package: NuxPackageAcquisition
        do {
            package = try read(exactPackageBytes)
        } catch NuxPackageReaderError.missingMember(let name) where name == "signature" {
            throw ExperiencePackageAuthenticationError.missingSignature
        } catch NuxPackageReaderError.invalidManifest {
            throw ExperiencePackageAuthenticationError.invalidManifest
        }
        return try NuxPackageSwiftVerifier.authenticate(
            member: { package.member(named: $0) },
            memberNames: package.memberNames,
            authorizationKeys: authorizationKeys,
            expectedExperienceID: expectedExperienceID,
            expectedBuildID: expectedBuildID,
            preparedExternalAssets: preparedExternalAssets,
            journeyDecoder: journeyDecoder
        )
    }

    private static func acquisitionAssets(
        from manifest: NuxPackageAcquisitionManifestV1
    ) throws -> [NuxPackageAcquisitionExternalAsset] {
        var result: [NuxPackageAcquisitionExternalAsset] = []
        var ids = Set<UInt32>()
        var names = Set<String>()
        var totalBytes = 0

        func append(
            _ asset: NuxPackageAcquisitionManifestV1.Asset,
            kind: NuxPackageAcquisitionAssetKind
        ) throws {
            guard case .external(let key) = asset.location else { return }
            guard let assetID = UInt32(exactly: asset.riveAssetId),
                  ids.insert(assetID).inserted,
                  !asset.riveUniqueName.isEmpty,
                  asset.riveUniqueName.utf8.count <= NuxPackageLimits.assetUniqueNameBytes,
                  names.insert(asset.riveUniqueName).inserted,
                  key.utf8.count <= NuxPackageLimits.assetSourceKeyBytes,
                  isContentAddressed(key: key, sha256: asset.sha256) else {
                throw NuxPackageReaderError.invalidExternalAsset(asset.riveUniqueName)
            }
            guard asset.sizeBytes <= UInt64(NuxPackageLimits.externalAssetBytes),
                  let sizeBytes = Int(exactly: asset.sizeBytes) else {
                throw NuxPackageReaderError.memberTooLarge(asset.riveUniqueName)
            }
            let (nextTotal, overflowed) = totalBytes.addingReportingOverflow(sizeBytes)
            guard !overflowed, nextTotal <= NuxPackageLimits.externalAssetTotalBytes else {
                throw NuxPackageReaderError.memberTooLarge("aggregate external assets")
            }
            totalBytes = nextTotal
            result.append(
                NuxPackageAcquisitionExternalAsset(
                    kind: kind,
                    riveAssetId: assetID,
                    riveUniqueName: asset.riveUniqueName,
                    key: key,
                    sha256: asset.sha256,
                    sizeBytes: sizeBytes,
                    required: asset.required
                )
            )
            guard result.count <= NuxPackageLimits.externalAssetCount else {
                throw NuxPackageReaderError.memberTooLarge("external asset count")
            }
        }

        for asset in manifest.assets.images {
            try append(asset, kind: .image)
        }
        for asset in manifest.assets.fonts {
            try append(asset, kind: .font)
        }
        return result
    }

    private static func isContentAddressed(key: String, sha256: String) -> Bool {
        guard sha256.count == 64,
              sha256.utf8.allSatisfy({
                  (48...57).contains($0) || (97...102).contains($0)
              }),
              !key.contains("\\"),
              !key.contains("..") else {
            return false
        }
        let components = key.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 3,
              components[0] == "assets",
              components[1] == "sha256" else {
            return false
        }
        let file = String(components[2])
        guard let separator = file.lastIndex(of: "."),
              String(file[..<separator]) == sha256 else {
            return false
        }
        let allowed = Set(["png", "jpg", "jpeg", "webp", "ttf", "otf"])
        return allowed.contains(URL(fileURLWithPath: file).pathExtension)
    }

    private static func required(
        _ name: String,
        from data: Data,
        members: [String: Range<Int>]
    ) throws -> Data {
        guard let range = members[name] else {
            throw NuxPackageReaderError.missingMember(name)
        }
        return data.subdata(in: range)
    }

    private static func requireZeroPadding(_ bytes: Data.SubSequence) throws {
        guard bytes.allSatisfy({ $0 == 0 }) else {
            throw NuxPackageReaderError.nonZeroPadding
        }
    }

    private static func uint16(_ data: Data, at offset: Int) throws -> UInt16 {
        UInt16(try unsigned(data, at: offset, count: 2))
    }

    private static func uint32(_ data: Data, at offset: Int) throws -> UInt32 {
        UInt32(try unsigned(data, at: offset, count: 4))
    }

    private static func uint64(_ data: Data, at offset: Int) throws -> UInt64 {
        try unsigned(data, at: offset, count: 8)
    }

    private static func unsigned(_ data: Data, at offset: Int, count: Int) throws -> UInt64 {
        let end = try adding(offset, count, field: "integer")
        guard offset >= 0, end <= data.count else {
            throw NuxPackageReaderError.truncated("integer")
        }
        var value: UInt64 = 0
        for (index, byte) in data[offset..<end].enumerated() {
            value |= UInt64(byte) << UInt64(index * 8)
        }
        return value
    }

    private static func integer(_ value: UInt64, field: String) throws -> Int {
        guard value <= UInt64(Int.max) else {
            throw NuxPackageReaderError.truncated(field)
        }
        return Int(value)
    }

    private static func adding(_ left: Int, _ right: Int, field: String) throws -> Int {
        let (value, overflow) = left.addingReportingOverflow(right)
        guard !overflow, value >= 0 else {
            throw NuxPackageReaderError.truncated(field)
        }
        return value
    }
}
