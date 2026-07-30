import Foundation

enum NuxPackageLimits {
    static let packageBytes = 64 * 1_024 * 1_024
    static let manifestBytes = 4 * 1_024 * 1_024
    static let journeyBytes = 8 * 1_024 * 1_024
    static let signatureBytes = 64 * 1_024
    static let externalAssetBytes = 32 * 1_024 * 1_024
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
    let textInputs: [NuxPackageTextInput]
    let assets: Assets
    let members: [InventoryMember]
}

struct NuxPackageScreen: Codable, Equatable, Sendable {
    let screenId: String
    let artboardId: String
    let artboardName: String
    let width: Double
    let height: Double
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

struct NuxPackageContents: Sendable {
    let bytes: Data
    let members: [String: Range<Int>]
    let manifestBytes: Data
    let journeyBytes: Data
    let manifest: NuxPackageManifestV1
    let journey: JourneyDocument

    func member(named name: String) -> Data? {
        guard let range = members[name] else { return nil }
        return bytes.subdata(in: range)
    }
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
    case invalidJourney
    case unsupportedJourneyVersion(Int)
    case journeyVersionMismatch

    var errorDescription: String? {
        "Invalid .nux package: \(String(describing: self))"
    }
}

/// Thin container reader. It understands only the v1 header/ToC and JSON
/// orchestration members; scene bytes remain opaque and are never parsed here.
enum NuxPackageReader {
    private static let magic = Data([0x89, 0x4e, 0x55, 0x58, 0x0d, 0x0a, 0x1a, 0x0a])
    private static let alignment = 16

    static func read(_ data: Data) throws -> NuxPackageContents {
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
        guard !signatureBytes.isEmpty,
              manifestBytes.count <= NuxPackageLimits.manifestBytes,
              journeyBytes.count <= NuxPackageLimits.journeyBytes,
              signatureBytes.count <= NuxPackageLimits.signatureBytes else {
            throw NuxPackageReaderError.memberTooLarge("required member")
        }
        guard members["scene"] != nil else {
            throw NuxPackageReaderError.missingMember("scene")
        }

        let decoder = JSONDecoder()
        guard let manifest = try? decoder.decode(NuxPackageManifestV1.self, from: manifestBytes),
              manifest.version == 1,
              manifest.scene.member == "scene",
              manifest.journey.member == "journey",
              manifest.requiredCapabilities.isEmpty else {
            throw NuxPackageReaderError.invalidManifest
        }
        guard let journey = try? decoder.decode(JourneyDocument.self, from: journeyBytes) else {
            throw NuxPackageReaderError.invalidJourney
        }
        guard journey.schemaVersion == 1 else {
            throw NuxPackageReaderError.unsupportedJourneyVersion(journey.schemaVersion)
        }
        guard journey.schemaVersion == manifest.journey.schemaVersion else {
            throw NuxPackageReaderError.journeyVersionMismatch
        }
        return NuxPackageContents(
            bytes: data,
            members: members,
            manifestBytes: manifestBytes,
            journeyBytes: journeyBytes,
            manifest: manifest,
            journey: journey
        )
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
