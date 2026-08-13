import Foundation

// MARK: - Remote delivery pointer

/// Signed package pointer delivered by `/profile` and version-addressed fetches.
public struct RemoteExperienceArtifact: Codable, Equatable, Sendable {
    /// Absolute URL of the `.nux` package.
    public let url: String
    /// Lowercase SHA-256 digest of the complete package.
    public let sha256: String
    /// Expected package byte count.
    public let sizeBytes: Int
    /// Package container format version.
    public let packageVersion: Int

    /// Creates a content-addressed package pointer.
    public init(
        url: String,
        sha256: String,
        sizeBytes: Int,
        packageVersion: Int = 1
    ) {
        self.url = url
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
        self.packageVersion = packageVersion
    }
}

/// Flat, metadata-only wire representation of a delivered experience.
public struct RemoteExperience: Codable, Sendable {
    /// Stable experience definition identifier.
    public let experienceId: String
    /// Published experience version identifier.
    public let versionId: String
    /// Immutable package build identity.
    public let buildId: String
    /// Signed legacy `.nux` package delivery pointer.
    public let artifact: RemoteExperienceArtifact
    /// Customer-authored display name.
    public let name: String
    /// Re-enrollment policy.
    public let reentry: ExperienceReentry
    /// ISO-8601 publication timestamp.
    public let publishedAt: String
    /// Optional event enrollment trigger.
    public let trigger: ExperienceTrigger?
    /// Optional conversion goal.
    public let goal: GoalConfig?
    /// Optional early-exit policy.
    public let exitPolicy: ExitPolicy?
    /// Optional conversion-anchor wire token.
    public let conversionAnchor: String?
    /// Optional maximum journey duration.
    public let timeLimitSeconds: Int?
    /// Optional server-defined category.
    public let experienceType: String?

    /// Creates a flat metadata-only delivery record.
    public init(
        experienceId: String,
        versionId: String,
        buildId: String,
        artifact: RemoteExperienceArtifact,
        name: String,
        reentry: ExperienceReentry,
        publishedAt: String,
        trigger: ExperienceTrigger? = nil,
        goal: GoalConfig? = nil,
        exitPolicy: ExitPolicy? = nil,
        conversionAnchor: String? = nil,
        timeLimitSeconds: Int? = nil,
        experienceType: String? = nil
    ) {
        self.experienceId = experienceId
        self.versionId = versionId
        self.buildId = buildId
        self.artifact = artifact
        self.name = name
        self.reentry = reentry
        self.publishedAt = publishedAt
        self.trigger = trigger
        self.goal = goal
        self.exitPolicy = exitPolicy
        self.conversionAnchor = conversionAnchor
        self.timeLimitSeconds = timeLimitSeconds
        self.experienceType = experienceType
    }
}

struct ExperienceReference: Equatable, Hashable, Sendable {
    let experienceId: String
    let versionId: String
}

enum ExperienceBehaviorPresentationStyle: Sendable {
    case legacyPackage
    case fullScreen
}

struct ExperienceBehaviorDefinition: Sendable {
    let reference: ExperienceReference
    let buildId: String
    /// Signed RIV digest for descriptor delivery, or signed `.nux` digest for
    /// legacy delivery. Available before object acquisition for failure telemetry.
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
    let presentationStyle: ExperienceBehaviorPresentationStyle

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
        presentationStyle: ExperienceBehaviorPresentationStyle
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
        self.presentationStyle = presentationStyle
    }

    init(remote: RemoteExperience) {
        self.init(
            reference: remote.reference,
            buildId: remote.buildId,
            artifactContentHash: remote.artifact.sha256,
            name: remote.name,
            reentry: remote.reentry,
            publishedAt: remote.publishedAt,
            trigger: remote.trigger,
            goal: remote.goal,
            exitPolicy: remote.exitPolicy,
            conversionAnchor: remote.conversionAnchor,
            timeLimitSeconds: remote.timeLimitSeconds,
            experienceType: remote.experienceType,
            presentationStyle: .legacyPackage
        )
    }
}

extension RemoteExperience {
    var reference: ExperienceReference {
        ExperienceReference(experienceId: experienceId, versionId: versionId)
    }
}

// MARK: - Signed journey member

/// Device execution content decoded only from a package's signed `journey` member.
public struct JourneyDocument: Codable, Sendable {
    public static let journeyEventHostKey = "__journey__"

    public let schemaVersion: Int
    public let screens: [JourneyScreen]
    public let events: [String: [EventDeclaration]]
    public let handlers: [String: [JourneyEventHandler]]
    public let scripts: [String: [ScreenScriptRef]]
    public let viewModelValues: [JourneyViewModelValue]?
    /// Experience-scoped response schemas (Experience Logic 2026-07-04). Optional for
    /// payload forward-compatibility; the $response_set Script Verb built-in
    /// resolves the experience schema from the first entry.
    public let responseSchemas: [JourneyResponseSchema]?
    /// Device-owned regions. Absent for byte-compatible device-only experiences.
    public let deviceRegions: [JourneyDeviceRegion]?

    public init(
        schemaVersion: Int = 1,
        screens: [JourneyScreen],
        events: [String: [EventDeclaration]] = [:],
        handlers: [String: [JourneyEventHandler]] = [:],
        scripts: [String: [ScreenScriptRef]] = [:],
        viewModelValues: [JourneyViewModelValue]? = nil,
        responseSchemas: [JourneyResponseSchema]? = nil,
        deviceRegions: [JourneyDeviceRegion]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.screens = screens
        self.events = events
        self.handlers = handlers
        self.scripts = scripts
        self.viewModelValues = viewModelValues
        self.responseSchemas = responseSchemas
        self.deviceRegions = deviceRegions
    }

    static let empty = JourneyDocument(screens: [])

    private enum CodingKeys: String, CodingKey, Sendable {
        case schemaVersion
        case screens
        case events
        case handlers
        case scripts
        case responseSchemas
        case viewModelValues
        case deviceRegions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        screens = try container.decode([JourneyScreen].self, forKey: .screens)
        events = try container.decode([String: [EventDeclaration]].self, forKey: .events)
        handlers = try container.decode([String: [JourneyEventHandler]].self, forKey: .handlers)
        scripts = try container.decode([String: [ScreenScriptRef]].self, forKey: .scripts)
        viewModelValues = try container.decodeIfPresent([JourneyViewModelValue].self, forKey: .viewModelValues)
        responseSchemas = try container.decodeIfPresent([JourneyResponseSchema].self, forKey: .responseSchemas)
        deviceRegions = try container.decodeIfPresent(
            [JourneyDeviceRegion].self,
            forKey: .deviceRegions
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(screens, forKey: .screens)
        try container.encode(events, forKey: .events)
        try container.encode(handlers, forKey: .handlers)
        try container.encode(scripts, forKey: .scripts)
        try container.encodeIfPresent(viewModelValues, forKey: .viewModelValues)
        try container.encodeIfPresent(responseSchemas, forKey: .responseSchemas)
        try container.encodeIfPresent(deviceRegions, forKey: .deviceRegions)
    }

}

/// A compiler-partitioned region whose action program executes on the device.
public struct JourneyDeviceRegion: Codable, Sendable {
    /// Stable region identity shared with server handoff envelopes.
    public let id: String
    /// First compiler-authored action node in this region.
    public let entryNodeId: String
    /// Ordered action program interpreted by `JourneyRunner`.
    public let actions: [JourneyAction]

    /// Creates a device-owned execution region.
    public init(id: String, entryNodeId: String, actions: [JourneyAction]) {
        self.id = id
        self.entryNodeId = entryNodeId
        self.actions = actions
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
