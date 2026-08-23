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
struct JourneyDocument: Codable, Sendable {
    static let journeyEventHostKey = "__journey__"

    let schemaVersion: Int
    let screens: [JourneyScreen]
    let viewModelValues: [JourneyViewModelValue]?
    /// Experience-scoped response schemas projected from the signed definition.
    let responseSchemas: [JourneyResponseSchema]?
    init(
        schemaVersion: Int = 1,
        screens: [JourneyScreen],
        viewModelValues: [JourneyViewModelValue]? = nil,
        responseSchemas: [JourneyResponseSchema]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.screens = screens
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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        screens = try container.decode([JourneyScreen].self, forKey: .screens)
        viewModelValues = try container.decodeIfPresent([JourneyViewModelValue].self, forKey: .viewModelValues)
        responseSchemas = try container.decodeIfPresent([JourneyResponseSchema].self, forKey: .responseSchemas)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(screens, forKey: .screens)
        try container.encodeIfPresent(viewModelValues, forKey: .viewModelValues)
        try container.encodeIfPresent(responseSchemas, forKey: .responseSchemas)
    }

}

struct JourneyViewModelValue: Codable, Sendable {
    let viewModelName: String
    let instanceId: String?
    let instanceName: String?
    let path: String
    let value: AnyCodable

    init(
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
struct JourneyScreen: Codable, Sendable {
    let id: String
    let defaultViewModelName: String?
    let defaultInstanceId: String?

    init(
        id: String,
        defaultViewModelName: String? = nil,
        defaultInstanceId: String? = nil
    ) {
        self.id = id
        self.defaultViewModelName = defaultViewModelName
        self.defaultInstanceId = defaultInstanceId
    }
}

// MARK: - View Model Path References

struct VmPathRef: Codable, Equatable, Sendable {
    let viewModelName: String?
    let path: String
    let isRelative: Bool?

    init(viewModelName: String? = nil, path: String, isRelative: Bool? = nil) {
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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _ = try container.decode(Kind.self, forKey: .kind)
        self.init(
            viewModelName: try? container.decode(String.self, forKey: .viewModelName),
            path: try container.decode(String.self, forKey: .path),
            isRelative: try? container.decode(Bool.self, forKey: .isRelative)
        )
    }

    func encode(to encoder: Encoder) throws {
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

    var normalizedPath: String {
        let prefix = isRelative == true ? "path:rel" : "path"
        return "\(prefix):\(viewModelName ?? ""):\(path)"
    }
}

// MARK: - View Model Models

struct ViewModel: Codable, Sendable {
    let id: String
    let name: String
    let viewModelPathId: Int?
    let properties: [String: ViewModelProperty]
}

enum ViewModelPropertyType: String, Codable, Sendable {
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

final class ViewModelProperty: Codable, Sendable {
    let type: ViewModelPropertyType
    let propertyId: Int?
    let defaultValue: AnyCodable?
    let allowUnset: Bool?
    let required: Bool?
    let enumValues: [String]?
    let itemType: ViewModelProperty?
    let schema: [String: ViewModelProperty]?
    let viewModelId: String?
    let validation: ViewModelValidation?

    init(
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

struct ViewModelValidation: Codable, Sendable {
    let min: Double?
    let max: Double?
    let minLength: Int?
    let maxLength: Int?
    let regex: String?
}

struct ViewModelInstance: Codable, Sendable {
    let viewModelId: String
    let instanceId: String
    let name: String?
    let values: [String: AnyCodable]
}
