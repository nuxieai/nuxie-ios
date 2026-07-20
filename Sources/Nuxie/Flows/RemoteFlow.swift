import Foundation

// MARK: - Remote Flow

public struct RemoteFlow: Codable {
    public static let journeyEventHostKey = "__journey__"

    public let id: String
    public let flowArtifact: FlowArtifact
    public let screens: [RemoteFlowScreen]
    public let events: [String: [EventDeclaration]]
    public let handlers: [String: [JourneyEventHandler]]
    public let scripts: [String: ScreenScriptRef]
    public let viewModelValues: [RemoteFlowViewModelValue]?
    /// Flow-scoped response schemas (Flow Logic 2026-07-04). Optional for
    /// payload forward-compatibility; the $response_set Script Verb built-in
    /// resolves the flow schema from the first entry.
    public let responseSchemas: [RemoteFlowResponseSchema]?

    public init(
        id: String,
        flowArtifact: FlowArtifact,
        screens: [RemoteFlowScreen],
        events: [String: [EventDeclaration]] = [:],
        handlers: [String: [JourneyEventHandler]] = [:],
        scripts: [String: ScreenScriptRef] = [:],
        viewModelValues: [RemoteFlowViewModelValue]? = nil,
        responseSchemas: [RemoteFlowResponseSchema]? = nil
    ) {
        self.id = id
        self.flowArtifact = flowArtifact
        self.screens = screens
        self.events = events
        self.handlers = handlers
        self.scripts = scripts
        self.viewModelValues = viewModelValues
        self.responseSchemas = responseSchemas
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case flowArtifact
        case screens
        case events
        case handlers
        case scripts
        case responseSchemas
        case viewModelValues
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        flowArtifact = try container.decode(FlowArtifact.self, forKey: .flowArtifact)
        screens = try container.decode([RemoteFlowScreen].self, forKey: .screens)
        events = try container.decode([String: [EventDeclaration]].self, forKey: .events)
        handlers = try container.decode([String: [JourneyEventHandler]].self, forKey: .handlers)
        scripts = try container.decode([String: ScreenScriptRef].self, forKey: .scripts)
        viewModelValues = try container.decodeIfPresent([RemoteFlowViewModelValue].self, forKey: .viewModelValues)
        responseSchemas = try container.decodeIfPresent([RemoteFlowResponseSchema].self, forKey: .responseSchemas)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(flowArtifact, forKey: .flowArtifact)
        try container.encode(screens, forKey: .screens)
        try container.encode(events, forKey: .events)
        try container.encode(handlers, forKey: .handlers)
        try container.encode(scripts, forKey: .scripts)
        try container.encodeIfPresent(viewModelValues, forKey: .viewModelValues)
        try container.encodeIfPresent(responseSchemas, forKey: .responseSchemas)
    }

}

public struct RemoteFlowViewModelValue: Codable {
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

public struct FlowArtifact: Codable {
    public let url: String
    public let buildId: String
    public let manifest: BuildManifest
    public let status: String?

    public init(
        url: String,
        buildId: String,
        manifest: BuildManifest,
        status: String? = nil
    ) {
        self.url = url
        self.buildId = buildId
        self.manifest = manifest
        self.status = status
    }

    public init(
        url: String,
        manifest: BuildManifest,
        buildId: String = "unknown",
        status: String? = nil
    ) {
        self.url = url
        self.buildId = buildId
        self.manifest = manifest
        self.status = status
    }
}

public struct RemoteFlowScreen: Codable {
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

public typealias RemoteFlowEventMap = [String: [EventDeclaration]]
public typealias RemoteFlowHandlerMap = [String: [JourneyEventHandler]]

public enum EventPayloadFieldType: String, Codable {
    case string
    case number
    case boolean
    case object
    case array
}

public typealias EventPayloadSchema = [String: EventPayloadFieldType]

public struct EventDeclaration: Codable {
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

public struct JourneyEventHandler: Codable {
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

public struct ScreenScriptRef: Codable {
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

public struct VmPathRef: Codable, Equatable {
    public let viewModelName: String?
    public let path: String
    public let isRelative: Bool?

    public init(viewModelName: String? = nil, path: String, isRelative: Bool? = nil) {
        self.viewModelName = viewModelName
        self.path = path
        self.isRelative = isRelative
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case isRelative
        case viewModelName
        case path
    }

    private enum Kind: String, Codable {
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

public struct ViewModel: Codable {
    public let id: String
    public let name: String
    public let viewModelPathId: Int?
    public let properties: [String: ViewModelProperty]
}

public enum ViewModelPropertyType: String, Codable {
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

public final class ViewModelProperty: Codable {
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

public struct ViewModelValidation: Codable {
    public let min: Double?
    public let max: Double?
    public let minLength: Int?
    public let maxLength: Int?
    public let regex: String?
}

public struct ViewModelInstance: Codable {
    public let viewModelId: String
    public let instanceId: String
    public let name: String?
    public let values: [String: AnyCodable]
}
