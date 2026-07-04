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

public enum JourneyAction: Codable {
    case navigate(NavigateAction)
    case back(BackAction)
    case delay(DelayAction)
    case timeWindow(TimeWindowAction)
    case waitUntil(WaitUntilAction)
    case condition(ConditionAction)
    case experiment(ExperimentAction)
    case sendEvent(SendEventAction)
    case goal(GoalAction)
    case updateCustomer(UpdateCustomerAction)
    case setResponseField(SetResponseFieldAction)
    case submitResponse(SubmitResponseAction)
    case purchase(PurchaseAction)
    case restore(RestoreAction)
    case requestNotifications(RequestNotificationsAction)
    case requestPermission(RequestPermissionAction)
    case requestTracking(RequestTrackingAction)
    case openLink(OpenLinkAction)
    case dismiss(DismissAction)
    case callDelegate(CallDelegateAction)
    case remote(RemoteAction)
    case setViewModel(SetViewModelAction)
    case fireTrigger(FireTriggerAction)
    case listInsert(ListInsertAction)
    case listRemove(ListRemoveAction)
    case listSwap(ListSwapAction)
    case listMove(ListMoveAction)
    case listSet(ListSetAction)
    case listClear(ListClearAction)
    case exit(ExitAction)
    case unknown(type: String, payload: [String: AnyCodable])

    private enum CodingKeys: String, CodingKey {
        case type
    }

    private enum ActionType: String, Codable {
        case navigate
        case back
        case delay
        case timeWindow = "time_window"
        case waitUntil = "wait_until"
        case condition
        case experiment
        case sendEvent = "send_event"
        case goal
        case updateCustomer = "update_customer"
        case setResponseField = "set_response_field"
        case submitResponse = "submit_response"
        case purchase
        case restore
        case requestNotifications = "request_notifications"
        case requestPermission = "request_permission"
        case requestTracking = "request_tracking"
        case openLink = "open_link"
        case dismiss
        case callDelegate = "call_delegate"
        case remote
        case setViewModel = "set_view_model"
        case fireTrigger = "fire_trigger"
        case listInsert = "list_insert"
        case listRemove = "list_remove"
        case listSwap = "list_swap"
        case listMove = "list_move"
        case listSet = "list_set"
        case listClear = "list_clear"
        case exit
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let typeValue = (try? container.decode(ActionType.self, forKey: .type))
        switch typeValue {
        case .navigate:
            self = .navigate(try NavigateAction(from: decoder))
        case .back:
            self = .back(try BackAction(from: decoder))
        case .delay:
            self = .delay(try DelayAction(from: decoder))
        case .timeWindow:
            self = .timeWindow(try TimeWindowAction(from: decoder))
        case .waitUntil:
            self = .waitUntil(try WaitUntilAction(from: decoder))
        case .condition:
            self = .condition(try ConditionAction(from: decoder))
        case .experiment:
            self = .experiment(try ExperimentAction(from: decoder))
        case .sendEvent:
            self = .sendEvent(try SendEventAction(from: decoder))
        case .goal:
            self = .goal(try GoalAction(from: decoder))
        case .updateCustomer:
            self = .updateCustomer(try UpdateCustomerAction(from: decoder))
        case .setResponseField:
            self = .setResponseField(try SetResponseFieldAction(from: decoder))
        case .submitResponse:
            self = .submitResponse(try SubmitResponseAction(from: decoder))
        case .purchase:
            self = .purchase(try PurchaseAction(from: decoder))
        case .restore:
            self = .restore(try RestoreAction(from: decoder))
        case .requestNotifications:
            self = .requestNotifications(try RequestNotificationsAction(from: decoder))
        case .requestPermission:
            self = .requestPermission(try RequestPermissionAction(from: decoder))
        case .requestTracking:
            self = .requestTracking(try RequestTrackingAction(from: decoder))
        case .openLink:
            self = .openLink(try OpenLinkAction(from: decoder))
        case .dismiss:
            self = .dismiss(try DismissAction(from: decoder))
        case .callDelegate:
            self = .callDelegate(try CallDelegateAction(from: decoder))
        case .remote:
            self = .remote(try RemoteAction(from: decoder))
        case .setViewModel:
            self = .setViewModel(try SetViewModelAction(from: decoder))
        case .fireTrigger:
            self = .fireTrigger(try FireTriggerAction(from: decoder))
        case .listInsert:
            self = .listInsert(try ListInsertAction(from: decoder))
        case .listRemove:
            self = .listRemove(try ListRemoveAction(from: decoder))
        case .listSwap:
            self = .listSwap(try ListSwapAction(from: decoder))
        case .listMove:
            self = .listMove(try ListMoveAction(from: decoder))
        case .listSet:
            self = .listSet(try ListSetAction(from: decoder))
        case .listClear:
            self = .listClear(try ListClearAction(from: decoder))
        case .exit:
            self = .exit(try ExitAction(from: decoder))
        case .none:
            let rawType = (try? container.decode(String.self, forKey: .type)) ?? "unknown"
            let dynamic = try decoder.container(keyedBy: DynamicCodingKey.self)
            var payload: [String: AnyCodable] = [:]
            for key in dynamic.allKeys where key.stringValue != "type" {
                payload[key.stringValue] = (try? dynamic.decode(AnyCodable.self, forKey: key)) ?? AnyCodable(NSNull())
            }
            self = .unknown(type: rawType, payload: payload)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .navigate(let action):
            try action.encode(to: encoder)
        case .back(let action):
            try action.encode(to: encoder)
        case .delay(let action):
            try action.encode(to: encoder)
        case .timeWindow(let action):
            try action.encode(to: encoder)
        case .waitUntil(let action):
            try action.encode(to: encoder)
        case .condition(let action):
            try action.encode(to: encoder)
        case .experiment(let action):
            try action.encode(to: encoder)
        case .sendEvent(let action):
            try action.encode(to: encoder)
        case .goal(let action):
            try action.encode(to: encoder)
        case .updateCustomer(let action):
            try action.encode(to: encoder)
        case .setResponseField(let action):
            try action.encode(to: encoder)
        case .submitResponse(let action):
            try action.encode(to: encoder)
        case .purchase(let action):
            try action.encode(to: encoder)
        case .restore(let action):
            try action.encode(to: encoder)
        case .requestNotifications(let action):
            try action.encode(to: encoder)
        case .requestPermission(let action):
            try action.encode(to: encoder)
        case .requestTracking(let action):
            try action.encode(to: encoder)
        case .openLink(let action):
            try action.encode(to: encoder)
        case .dismiss(let action):
            try action.encode(to: encoder)
        case .callDelegate(let action):
            try action.encode(to: encoder)
        case .remote(let action):
            try action.encode(to: encoder)
        case .setViewModel(let action):
            try action.encode(to: encoder)
        case .fireTrigger(let action):
            try action.encode(to: encoder)
        case .listInsert(let action):
            try action.encode(to: encoder)
        case .listRemove(let action):
            try action.encode(to: encoder)
        case .listSwap(let action):
            try action.encode(to: encoder)
        case .listMove(let action):
            try action.encode(to: encoder)
        case .listSet(let action):
            try action.encode(to: encoder)
        case .listClear(let action):
            try action.encode(to: encoder)
        case .exit(let action):
            try action.encode(to: encoder)
        case .unknown(let type, let payload):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(type, forKey: .type)
            if !payload.isEmpty {
                var extra = encoder.container(keyedBy: DynamicCodingKey.self)
                for (key, value) in payload {
                    if let codingKey = DynamicCodingKey(stringValue: key) {
                        try extra.encode(value, forKey: codingKey)
                    }
                }
            }
        }
    }
}

public struct NavigateAction: Codable {
    public let type: String
    public let screenId: String
    public let transition: AnyCodable?

    public init(type: String = "navigate", screenId: String, transition: AnyCodable? = nil) {
        self.type = type
        self.screenId = screenId
        self.transition = transition
    }
}

public struct BackAction: Codable {
    public let type: String
    public let steps: Int?
    public let transition: AnyCodable?

    public init(type: String = "back", steps: Int? = nil, transition: AnyCodable? = nil) {
        self.type = type
        self.steps = steps
        self.transition = transition
    }
}

public struct DelayAction: Codable {
    public let type: String
    public let durationMs: Int

    public init(type: String = "delay", durationMs: Int) {
        self.type = type
        self.durationMs = durationMs
    }
}

public struct TimeWindowAction: Codable {
    public let type: String
    public let startTime: String
    public let endTime: String
    public let timezone: String
    public let daysOfWeek: [Int]?
    public let successActions: [JourneyAction]?

    public init(
        type: String = "time_window",
        startTime: String,
        endTime: String,
        timezone: String,
        daysOfWeek: [Int]? = nil,
        successActions: [JourneyAction]? = nil
    ) {
        self.type = type
        self.startTime = startTime
        self.endTime = endTime
        self.timezone = timezone
        self.daysOfWeek = daysOfWeek
        self.successActions = successActions
    }
}

public struct WaitUntilAction: Codable {
    public let type: String
    public let condition: IREnvelope?
    public let maxTimeMs: Int?

    public init(type: String = "wait_until", condition: IREnvelope?, maxTimeMs: Int? = nil) {
        self.type = type
        self.condition = condition
        self.maxTimeMs = maxTimeMs
    }
}

public struct ConditionAction: Codable {
    public let type: String
    public let branches: [ConditionBranch]
    public let defaultActions: [JourneyAction]?

    public init(type: String = "condition", branches: [ConditionBranch], defaultActions: [JourneyAction]? = nil) {
        self.type = type
        self.branches = branches
        self.defaultActions = defaultActions
    }
}

public struct ConditionBranch: Codable {
    public let id: String
    public let label: String?
    public let condition: IREnvelope?
    public let actions: [JourneyAction]
}

public struct ExperimentAction: Codable {
    public let type: String
    public let experimentId: String
    public let variants: [ExperimentVariant]

    public init(type: String = "experiment", experimentId: String, variants: [ExperimentVariant]) {
        self.type = type
        self.experimentId = experimentId
        self.variants = variants
    }
}

public struct ExperimentVariant: Codable {
    public let id: String
    public let name: String?
    public let percentage: Double
    public let actions: [JourneyAction]
}

public struct SendEventAction: Codable {
    public let type: String
    public let eventName: String
    public let properties: [String: AnyCodable]?

    public init(type: String = "send_event", eventName: String, properties: [String: AnyCodable]? = nil) {
        self.type = type
        self.eventName = eventName
        self.properties = properties
    }
}

public struct GoalAction: Codable {
    public let type: String
    public let goalId: String
    public let label: String?

    public init(type: String = "goal", goalId: String, label: String? = nil) {
        self.type = type
        self.goalId = goalId
        self.label = label
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case goalId
        case label
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? "goal"
        let decodedGoalId = try container.decode(String.self, forKey: .goalId)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !decodedGoalId.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .goalId,
                in: container,
                debugDescription: "goal actions require a non-empty goalId"
            )
        }
        goalId = decodedGoalId
        label = try container.decodeIfPresent(String.self, forKey: .label)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(goalId, forKey: .goalId)
        try container.encodeIfPresent(label, forKey: .label)
    }
}

public struct UpdateCustomerAction: Codable {
    public let type: String
    public let attributes: [String: AnyCodable]

    public init(type: String = "update_customer", attributes: [String: AnyCodable]) {
        self.type = type
        self.attributes = attributes
    }
}

public struct SetResponseFieldAction: Codable {
    public let type: String
    public let responseSchemaId: String
    public let schemaVersion: Int?
    public let key: String
    public let value: AnyCodable

    public init(
        type: String = "set_response_field",
        responseSchemaId: String,
        schemaVersion: Int? = nil,
        key: String,
        value: AnyCodable
    ) {
        self.type = type
        self.responseSchemaId = responseSchemaId
        self.schemaVersion = schemaVersion
        self.key = key
        self.value = value
    }
}

public struct SubmitResponseAction: Codable {
    public let type: String
    public let responseSchemaId: String
    public let schemaVersion: Int?

    public init(
        type: String = "submit_response",
        responseSchemaId: String,
        schemaVersion: Int? = nil
    ) {
        self.type = type
        self.responseSchemaId = responseSchemaId
        self.schemaVersion = schemaVersion
    }
}

public struct RemoteFlowResponseSchema: Codable {
    public let responseSchemaId: String
    public let responseSchemaVersionId: String?

    public init(responseSchemaId: String, responseSchemaVersionId: String? = nil) {
        self.responseSchemaId = responseSchemaId
        self.responseSchemaVersionId = responseSchemaVersionId
    }
}

public struct PurchaseAction: Codable {
    public let type: String
    public let placementIndex: AnyCodable
    public let productId: AnyCodable
    /// Outcome outlets (Flow Logic 2026-07-04): outcome routing lives at the
    /// purchase site as wired chains. When present, the runner correlates the
    /// async purchase outcome back to this node and runs the matching chain.
    /// Global $purchase_* events still fire for cross-cutting listeners.
    public let onCompleted: [JourneyAction]?
    public let onFailed: [JourneyAction]?
    public let onCancelled: [JourneyAction]?

    public init(
        type: String = "purchase",
        placementIndex: AnyCodable,
        productId: AnyCodable,
        onCompleted: [JourneyAction]? = nil,
        onFailed: [JourneyAction]? = nil,
        onCancelled: [JourneyAction]? = nil
    ) {
        self.type = type
        self.placementIndex = placementIndex
        self.productId = productId
        self.onCompleted = onCompleted
        self.onFailed = onFailed
        self.onCancelled = onCancelled
    }
}

public struct RestoreAction: Codable {
    public let type: String
    public let onRestored: [JourneyAction]?
    public let onNoPurchases: [JourneyAction]?
    public let onFailed: [JourneyAction]?

    public init(
        type: String = "restore",
        onRestored: [JourneyAction]? = nil,
        onNoPurchases: [JourneyAction]? = nil,
        onFailed: [JourneyAction]? = nil
    ) {
        self.type = type
        self.onRestored = onRestored
        self.onNoPurchases = onNoPurchases
        self.onFailed = onFailed
    }
}

public struct RequestNotificationsAction: Codable {
    public let type: String

    public init(type: String = "request_notifications") {
        self.type = type
    }
}

public struct RequestPermissionAction: Codable {
    public let type: String
    public let permissionType: String

    public init(type: String = "request_permission", permissionType: String) {
        self.type = type
        self.permissionType = permissionType
    }
}

public struct RequestTrackingAction: Codable {
    public let type: String

    public init(type: String = "request_tracking") {
        self.type = type
    }
}

public struct OpenLinkAction: Codable {
    public let type: String
    public let url: AnyCodable
    public let target: String?

    public init(type: String = "open_link", url: AnyCodable, target: String? = nil) {
        self.type = type
        self.url = url
        self.target = target
    }
}

public struct DismissAction: Codable {
    public let type: String
    public let reason: String?

    public init(type: String = "dismiss", reason: String? = nil) {
        self.type = type
        self.reason = reason
    }
}

public struct CallDelegateAction: Codable {
    public let type: String
    public let message: String
    public let payload: AnyCodable?

    public init(type: String = "call_delegate", message: String, payload: AnyCodable? = nil) {
        self.type = type
        self.message = message
        self.payload = payload
    }
}

public struct RemoteAction: Codable {
    public let type: String
    public let action: String
    public let payload: AnyCodable
    public let async: Bool?

    public init(type: String = "remote", action: String, payload: AnyCodable, async: Bool? = nil) {
        self.type = type
        self.action = action
        self.payload = payload
        self.async = async
    }
}

public struct SetViewModelAction: Codable {
    public let type: String
    public let path: VmPathRef
    public let value: AnyCodable

    public init(type: String = "set_view_model", path: VmPathRef, value: AnyCodable) {
        self.type = type
        self.path = path
        self.value = value
    }
}

public struct FireTriggerAction: Codable {
    public let type: String
    public let path: VmPathRef

    public init(type: String = "fire_trigger", path: VmPathRef) {
        self.type = type
        self.path = path
    }
}

public struct ListInsertAction: Codable {
    public let type: String
    public let path: VmPathRef
    public let index: Int?
    public let value: AnyCodable

    public init(type: String = "list_insert", path: VmPathRef, index: Int? = nil, value: AnyCodable) {
        self.type = type
        self.path = path
        self.index = index
        self.value = value
    }
}

public struct ListRemoveAction: Codable {
    public let type: String
    public let path: VmPathRef
    public let index: Int

    public init(type: String = "list_remove", path: VmPathRef, index: Int) {
        self.type = type
        self.path = path
        self.index = index
    }
}

public struct ListSwapAction: Codable {
    public let type: String
    public let path: VmPathRef
    public let indexA: Int
    public let indexB: Int

    public init(type: String = "list_swap", path: VmPathRef, indexA: Int, indexB: Int) {
        self.type = type
        self.path = path
        self.indexA = indexA
        self.indexB = indexB
    }
}

public struct ListMoveAction: Codable {
    public let type: String
    public let path: VmPathRef
    public let from: Int
    public let to: Int

    public init(type: String = "list_move", path: VmPathRef, from: Int, to: Int) {
        self.type = type
        self.path = path
        self.from = from
        self.to = to
    }
}

public struct ListSetAction: Codable {
    public let type: String
    public let path: VmPathRef
    public let index: Int
    public let value: AnyCodable

    public init(type: String = "list_set", path: VmPathRef, index: Int, value: AnyCodable) {
        self.type = type
        self.path = path
        self.index = index
        self.value = value
    }
}

public struct ListClearAction: Codable {
    public let type: String
    public let path: VmPathRef

    public init(type: String = "list_clear", path: VmPathRef) {
        self.type = type
        self.path = path
    }
}

public struct ExitAction: Codable {
    public let type: String
    public let reason: String?

    public init(type: String = "exit", reason: String? = nil) {
        self.type = type
        self.reason = reason
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

// MARK: - Dynamic Coding Key

private struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
