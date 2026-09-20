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
    var videos: [NativeExperienceVideoAsset] = []
    var videoElements: [NativeExperienceVideoElement] = []
    // Device requirements have no artifact metadata or downloaded object.
    let systemFonts: [NativeExperienceSystemFontRequirement]

    init(
        identity: Identity, scene: Scene, entry: Entry,
        screens: [NativeExperienceScreen], transitions: [NativeExperienceTransition],
        textInputs: [NativeExperienceTextInput], images: [NativeExperienceImageAsset],
        fonts: [NativeExperienceFontAsset], videos: [NativeExperienceVideoAsset] = [], videoElements: [NativeExperienceVideoElement] = [], systemFonts: [NativeExperienceSystemFontRequirement] = []
    ) {
        self.identity = identity
        self.scene = scene
        self.entry = entry
        self.screens = screens
        self.transitions = transitions
        self.textInputs = textInputs
        self.images = images
        self.fonts = fonts
        self.videos = videos
        self.videoElements = videoElements
        self.systemFonts = systemFonts
    }
}

struct NativeExperienceSystemFontRequirement: Equatable, Sendable {
    let authoredAssetId: UInt64
    let assetUniqueName: String
    let weight: String
    let style: String
}

/// Authored targets resolved to local component slots in this exact signed scene.
struct NativeExperienceVideoElement: Decodable, Equatable, Sendable {
    let sourceArtboardIndex: UInt32
    let artboardId: String
    let viewNodeId: String
    let renderedNodeId: String
    let componentId: UInt32
    let readinessTimeoutSeconds: Double
    let optional: Bool
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
    let authoredAssetId: UInt64
    let assetUniqueName: String
    let sha256: String
    let sizeBytes: Int
    let contentType: String
    let required: Bool
}

struct NativeExperienceFontAsset: Equatable, Sendable {
    let location: NativeExperienceAssetLocation
    let authoredAssetId: UInt64
    let assetUniqueName: String
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
    enum ResponseCapture: String, Decodable, Sendable {
        case text
        case binding
    }
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
        let fontAssetUniqueName: String
        let textAlign: String?
    }
    let inputId: String
    let screenId: String
    let artboardId: String
    let viewNodeId: String
    let renderedNodeId: String
    let textObjectKey: String
    let textRunObjectKey: String
    let textName: String
    let textRunName: String
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
    var responseCapture: ResponseCapture? = nil
    var actionEvent: ExperienceTextInputEventKind? = nil
    var declarativeActionId: String? = nil
    // Native endpoint discovery remains gated by signed-manifest admission.
    var editableValueName: String? = nil

    func declarativeInvocation(for event: ExperienceTextInputEvent) -> ScreenActionInvocation? {
        guard event.kind == (actionEvent ?? .editingEnded), let declarativeActionId else { return nil }
        return .init(actionId: declarativeActionId, value: .string(event.text), componentId: viewNodeId)
    }
}

struct NativeExperienceVideoAsset: Equatable, Sendable {
    struct CaptionTrack: Decodable, Equatable, Sendable {
        let streamIndex: Int
        let codec: String
        let language: String?
        let title: String?
    }

    let location: NativeExperienceAssetLocation
    let sourceAssetKey: String
    let authoredAssetId: UInt64
    let assetUniqueName: String
    let sha256: String
    let sizeBytes: Int
    let width: Int
    let height: Int
    let durationMs: Int
    let videoCodec: String
    let audioCodec: String?
    let captionTracks: [CaptionTrack]
    let required: Bool
}
