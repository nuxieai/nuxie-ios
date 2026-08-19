import Foundation

struct ExperienceReference: Equatable, Hashable, Sendable {
    let experienceId: String
    let versionId: String
}

enum ExperienceBehaviorPresentationStyle: String, Codable, Sendable {
    case fullScreen = "full_screen"
    case sheet
    case drawer
}

enum ExperienceBehaviorPresentationOrientation: String, Codable, Sendable {
    case portrait
    case landscape
    case any
}

/// The descriptor-authenticated native presentation contract. It is carried
/// as one value so admission, journey persistence, and window shape cannot
/// silently select different presentation semantics.
///
/// The loading treatment is deliberately not part of this contract. Every
/// presentation shimmers over `backgroundColor` while it acquires; making that
/// authorable only ever produced one value from the publisher and gave authors
/// a choice with no product meaning.
struct ExperienceBehaviorPresentation: Codable, Equatable, Sendable {
    struct Sheet: Codable, Equatable, Sendable {
        enum Detent: String, Codable, Sendable {
            case medium
            case large
        }

        let detent: Detent
        let dismissible: Bool
    }

    struct Drawer: Codable, Equatable, Sendable {
        enum Edge: String, Codable, Sendable {
            case bottom
            case top
            case leading
            case trailing
        }

        let edge: Edge
        let extentRatio: Double
        let cornerRadius: Double
        let dismissible: Bool
    }

    let style: ExperienceBehaviorPresentationStyle
    let orientation: ExperienceBehaviorPresentationOrientation
    let backgroundColor: String
    let sheet: Sheet?
    let drawer: Drawer?

    static let fullScreenDefault = Self(
        style: .fullScreen,
        orientation: .any,
        backgroundColor: "#FFFFFFFF",
        sheet: nil,
        drawer: nil
    )
}

struct ExperienceBehaviorScreenGeometry: Codable, Equatable, Sendable {
    let width: Double
    let height: Double
}

/// Exact native shell inputs for the selected signed screen.
struct ExperienceShellContract: Codable, Equatable, Sendable {
    let presentation: ExperienceBehaviorPresentation
    let screen: ExperienceBehaviorScreenGeometry
}

struct ExperienceBehaviorDefinition: Sendable {
    let reference: ExperienceReference
    let buildId: String
    /// Signed RIV digest, available before object acquisition for telemetry.
    let artifactContentHash: String
    let name: String
    let reentry: ExperienceReentry
    let publishedAt: String
    let trigger: ExperienceTrigger?
    let goal: GoalConfig?
    let exitPolicy: ExitPolicy?
    let conversionAnchor: String?
    let timeLimitSeconds: Int?
    let experienceType: String?
    let presentation: ExperienceBehaviorPresentation
    let presentationScreens: [String: ExperienceBehaviorScreenGeometry]

    var presentationStyle: ExperienceBehaviorPresentationStyle {
        presentation.style
    }

    init(
        reference: ExperienceReference,
        buildId: String,
        artifactContentHash: String,
        name: String,
        reentry: ExperienceReentry,
        publishedAt: String,
        trigger: ExperienceTrigger?,
        goal: GoalConfig?,
        exitPolicy: ExitPolicy?,
        conversionAnchor: String?,
        timeLimitSeconds: Int?,
        experienceType: String?,
        presentation: ExperienceBehaviorPresentation,
        presentationScreens: [String: ExperienceBehaviorScreenGeometry]
    ) {
        self.reference = reference
        self.buildId = buildId
        self.artifactContentHash = artifactContentHash
        self.name = name
        self.reentry = reentry
        self.publishedAt = publishedAt
        self.trigger = trigger
        self.goal = goal
        self.exitPolicy = exitPolicy
        self.conversionAnchor = conversionAnchor
        self.timeLimitSeconds = timeLimitSeconds
        self.experienceType = experienceType
        self.presentation = presentation
        self.presentationScreens = presentationScreens
    }

    init(
        reference: ExperienceReference,
        buildId: String,
        artifactContentHash: String,
        name: String,
        reentry: ExperienceReentry,
        publishedAt: String,
        trigger: ExperienceTrigger?,
        goal: GoalConfig?,
        exitPolicy: ExitPolicy?,
        conversionAnchor: String?,
        timeLimitSeconds: Int?,
        experienceType: String?,
        presentationStyle: ExperienceBehaviorPresentationStyle,
        presentationScreens: [String: ExperienceBehaviorScreenGeometry] = [:]
    ) {
        self.init(
            reference: reference,
            buildId: buildId,
            artifactContentHash: artifactContentHash,
            name: name,
            reentry: reentry,
            publishedAt: publishedAt,
            trigger: trigger,
            goal: goal,
            exitPolicy: exitPolicy,
            conversionAnchor: conversionAnchor,
            timeLimitSeconds: timeLimitSeconds,
            experienceType: experienceType,
            presentation: .init(
                style: presentationStyle,
                orientation: .any,
                backgroundColor: "#FFFFFFFF",
                sheet: nil,
                drawer: nil
            ),
            presentationScreens: presentationScreens
        )
    }
}

// MARK: - Signed journey member

/// Device execution content decoded only from the signed release descriptor.
public struct JourneyDocument: Codable, Sendable {
    public static let journeyEventHostKey = "__journey__"

    public let schemaVersion: Int
    public let screens: [JourneyScreen]
    /// Test-fixture-only remnants. Authenticated v2 decoding and runtime
    /// execution never read or write these legacy behavior collections.
    let events: [String: [EventDeclaration]]
    let handlers: [String: [JourneyEventHandler]]
    let scripts: [String: [ScreenScriptRef]]
    public let viewModelValues: [JourneyViewModelValue]?
    /// Experience-scoped response schemas (Experience Logic 2026-07-04). Optional for
    /// payload forward-compatibility; the $response_set Script Verb built-in
    /// resolves the experience schema from the first entry.
    public let responseSchemas: [JourneyResponseSchema]?
    public init(
        schemaVersion: Int = 1,
        screens: [JourneyScreen],
        events: [String: [EventDeclaration]] = [:],
        handlers: [String: [JourneyEventHandler]] = [:],
        scripts: [String: [ScreenScriptRef]] = [:],
        viewModelValues: [JourneyViewModelValue]? = nil,
        responseSchemas: [JourneyResponseSchema]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.screens = screens
        self.events = events
        self.handlers = handlers
        self.scripts = scripts
        self.viewModelValues = viewModelValues
        self.responseSchemas = responseSchemas
    }

    static let empty = JourneyDocument(screens: [])

    private enum CodingKeys: String, CodingKey, Sendable {
        case schemaVersion
        case screens
        case responseSchemas
        case viewModelValues
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        screens = try container.decode([JourneyScreen].self, forKey: .screens)
        events = [:]
        handlers = [:]
        scripts = [:]
        viewModelValues = try container.decodeIfPresent([JourneyViewModelValue].self, forKey: .viewModelValues)
        responseSchemas = try container.decodeIfPresent([JourneyResponseSchema].self, forKey: .responseSchemas)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(screens, forKey: .screens)
        try container.encodeIfPresent(viewModelValues, forKey: .viewModelValues)
        try container.encodeIfPresent(responseSchemas, forKey: .responseSchemas)
    }

}

public struct JourneyViewModelValue: Codable, Sendable {
    public let viewModelName: String
    public let instanceId: String?
    public let instanceName: String?
    public let path: String
    public let value: AnyCodable

    public init(
        viewModelName: String,
        instanceId: String? = nil,
        instanceName: String? = nil,
        path: String,
        value: AnyCodable
    ) {
        self.viewModelName = viewModelName
        self.instanceId = instanceId
        self.instanceName = instanceName
        self.path = path
        self.value = value
    }
}
public struct JourneyScreen: Codable, Sendable {
    public let id: String
    public let defaultViewModelName: String?
    public let defaultInstanceId: String?

    public init(
        id: String,
        defaultViewModelName: String? = nil,
        defaultInstanceId: String? = nil
    ) {
        self.id = id
        self.defaultViewModelName = defaultViewModelName
        self.defaultInstanceId = defaultInstanceId
    }
}

public typealias JourneyEventMap = [String: [EventDeclaration]]
public typealias JourneyHandlerMap = [String: [JourneyEventHandler]]

public enum EventPayloadFieldType: String, Codable, Sendable {
    case string
    case number
    case boolean
    case object
    case array
}

public typealias EventPayloadSchema = [String: EventPayloadFieldType]

public struct EventDeclaration: Codable, Sendable {
    public let id: String
    public let eventName: String
    public let payloadSchema: EventPayloadSchema?

    public init(
        id: String,
        eventName: String,
        payloadSchema: EventPayloadSchema? = nil
    ) {
        self.id = id
        self.eventName = eventName
        self.payloadSchema = payloadSchema
    }
}

public struct JourneyEventHandler: Codable, Sendable {
    public let id: String
    public let eventName: String
    public let enabled: Bool?
    public let order: Int?
    public let actions: [JourneyAction]

    public init(
        id: String,
        eventName: String,
        enabled: Bool? = nil,
        order: Int? = nil,
        actions: [JourneyAction]
    ) {
        self.id = id
        self.eventName = eventName
        self.enabled = enabled
        self.order = order
        self.actions = actions
    }
}

public struct ScreenScriptRef: Codable, Sendable {
    public let id: String
    public let scriptId: String
    public let assetId: String
    public let `protocol`: String
    public let name: String?
    public let enabled: Bool?
    public let eventNames: [String]?

    public init(
        id: String,
        scriptId: String,
        assetId: String,
        `protocol`: String = "listenerAction",
        name: String? = nil,
        enabled: Bool? = nil,
        eventNames: [String]? = nil
    ) {
        self.id = id
        self.scriptId = scriptId
        self.assetId = assetId
        self.`protocol` = `protocol`
        self.name = name
        self.enabled = enabled
        self.eventNames = eventNames
    }
}

// MARK: - View Model Path References

public struct VmPathRef: Codable, Equatable, Sendable {
    public let viewModelName: String?
    public let path: String
    public let isRelative: Bool?

    public init(viewModelName: String? = nil, path: String, isRelative: Bool? = nil) {
        self.viewModelName = viewModelName
        self.path = path
        self.isRelative = isRelative
    }

    private enum CodingKeys: String, CodingKey, Sendable {
        case kind
        case isRelative
        case viewModelName
        case path
    }

    private enum Kind: String, Codable, Sendable {
        case path
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _ = try container.decode(Kind.self, forKey: .kind)
        self.init(
            viewModelName: try? container.decode(String.self, forKey: .viewModelName),
            path: try container.decode(String.self, forKey: .path),
            isRelative: try? container.decode(Bool.self, forKey: .isRelative)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Kind.path, forKey: .kind)
        try container.encode(path, forKey: .path)
        if let viewModelName {
            try container.encode(viewModelName, forKey: .viewModelName)
        }
        if isRelative == true {
            try container.encode(true, forKey: .isRelative)
        }
    }

    public var normalizedPath: String {
        let prefix = isRelative == true ? "path:rel" : "path"
        return "\(prefix):\(viewModelName ?? ""):\(path)"
    }
}

// MARK: - View Model Models

public struct ViewModel: Codable, Sendable {
    public let id: String
    public let name: String
    public let viewModelPathId: Int?
    public let properties: [String: ViewModelProperty]
}

public enum ViewModelPropertyType: String, Codable, Sendable {
    case string
    case number
    case boolean
    case color
    case `enum`
    case list
    case list_index
    case object
    case image
    case trigger
    case viewModel = "viewModel"
}

public final class ViewModelProperty: Codable, Sendable {
    public let type: ViewModelPropertyType
    public let propertyId: Int?
    public let defaultValue: AnyCodable?
    public let allowUnset: Bool?
    public let required: Bool?
    public let enumValues: [String]?
    public let itemType: ViewModelProperty?
    public let schema: [String: ViewModelProperty]?
    public let viewModelId: String?
    public let validation: ViewModelValidation?

    public init(
        type: ViewModelPropertyType,
        propertyId: Int? = nil,
        defaultValue: AnyCodable? = nil,
        allowUnset: Bool? = nil,
        required: Bool? = nil,
        enumValues: [String]? = nil,
        itemType: ViewModelProperty? = nil,
        schema: [String: ViewModelProperty]? = nil,
        viewModelId: String? = nil,
        validation: ViewModelValidation? = nil
    ) {
        self.type = type
        self.propertyId = propertyId
        self.defaultValue = defaultValue
        self.allowUnset = allowUnset
        self.required = required
        self.enumValues = enumValues
        self.itemType = itemType
        self.schema = schema
        self.viewModelId = viewModelId
        self.validation = validation
    }
}

public struct ViewModelValidation: Codable, Sendable {
    public let min: Double?
    public let max: Double?
    public let minLength: Int?
    public let maxLength: Int?
    public let regex: String?
}

public struct ViewModelInstance: Codable, Sendable {
    public let viewModelId: String
    public let instanceId: String
    public let name: String?
    public let values: [String: AnyCodable]
}
