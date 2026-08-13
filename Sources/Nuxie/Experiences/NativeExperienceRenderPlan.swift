import Foundation

struct NativeExperienceRenderPlan: Equatable, Sendable {
    struct Identity: Equatable, Sendable {
        let experienceId: String
        let buildId: String
        let appId: String
        let environment: String
    }

    struct Scene: Equatable, Sendable {
        let key: String
        let sha256: String
        let sizeBytes: Int
    }

    struct Entry: Equatable, Sendable { let screenId: String }

    let identity: Identity
    let scene: Scene
    let entry: Entry
    let screens: [NativeExperienceScreen]
    let transitions: [NativeExperienceTransition]
    let textInputs: [NativeExperienceTextInput]
    let images: [NativeExperienceImageAsset]
    let fonts: [NativeExperienceFontAsset]
}

struct NativeExperienceScreen: Equatable, Sendable {
    let screenId: String
    let artboardId: String
    let artboardName: String
    let width: Double
    let height: Double
    let exit: NativeExperienceScreenExit?
}

struct NativeExperienceScreenExit: Equatable, Sendable {
    let completeEventName: String
    let durationMs: Int
}

struct NativeExperienceTransition: Equatable, Sendable {
    struct Endpoint: Equatable, Sendable { let completeEventName: String }
    struct Reverse: Equatable, Sendable {
        let durationMs: Int?
        let incomingOnTop: Bool?
        let source: Endpoint
        let destination: Endpoint
    }
    let id: String
    let sourceScreenId: String
    let destinationScreenId: String
    let durationMs: Int
    let incomingOnTop: Bool
    let source: Endpoint
    let destination: Endpoint
    let reverse: Reverse?
}

enum NativeExperienceAssetLocation: Equatable, Sendable {
    case external(key: String)
    case embedded(member: String)

    var contentAddressedPath: String {
        switch self {
        case .external(let key): key
        case .embedded(let member): member
        }
    }
}

struct NativeExperienceImageAsset: Equatable, Sendable {
    let location: NativeExperienceAssetLocation
    let riveAssetId: UInt64
    let riveUniqueName: String
    let sha256: String
    let sizeBytes: Int
    let contentType: String
    let required: Bool
}

struct NativeExperienceFontAsset: Equatable, Sendable {
    let location: NativeExperienceAssetLocation
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

struct NativeExperienceTextInput: Equatable, Sendable {
    struct Geometry: Equatable, Sendable {
        let xPath: String
        let yPath: String
        let widthPath: String
        let heightPath: String
        let rotationPath: String
        let scaleXPath: String
        let scaleYPath: String
    }
    struct Style: Equatable, Sendable {
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
    let geometry: Geometry
    let style: Style
    let keyboardType: String?
    let secureTextEntry: Bool?
    let multiline: Bool?
    let maxLength: Int?
    let responseFieldKey: String?
}
