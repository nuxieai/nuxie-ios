import Foundation

// MARK: - Journey Action Schema

/// The portable value vocabulary used by the signed Journey route contract.
///
/// This is deliberately distinct from `AnyCodable`: the tagged reference cases
/// (`Event.Field` and `Response.Field`) must survive decoding all the way to the
/// interpreter instead of being lowered into an untyped IR envelope.
enum JourneyValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JourneyValue])
    case object([String: JourneyValue])
    case eventField(String)
    case responseField(String)

    private enum CodingKeys: String, CodingKey {
        case type
        case value
        case items
        case fields
        case key
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "Null": self = .null
        case "Boolean": self = .bool(try container.decode(Bool.self, forKey: .value))
        case "Number": self = .number(try container.decode(Double.self, forKey: .value))
        case "String": self = .string(try container.decode(String.self, forKey: .value))
        case "Array": self = .array(try container.decode([JourneyValue].self, forKey: .items))
        case "Object": self = .object(try container.decode([String: JourneyValue].self, forKey: .fields))
        case "Event.Field": self = .eventField(try container.decode(String.self, forKey: .key))
        case "Response.Field": self = .responseField(try container.decode(String.self, forKey: .key))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "unknown JourneyValue type: \(type)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .null: try container.encode("Null", forKey: .type)
        case .bool(let value):
            try container.encode("Boolean", forKey: .type)
            try container.encode(value, forKey: .value)
        case .number(let value):
            try container.encode("Number", forKey: .type)
            try container.encode(value, forKey: .value)
        case .string(let value):
            try container.encode("String", forKey: .type)
            try container.encode(value, forKey: .value)
        case .array(let values):
            try container.encode("Array", forKey: .type)
            try container.encode(values, forKey: .items)
        case .object(let values):
            try container.encode("Object", forKey: .type)
            try container.encode(values, forKey: .fields)
        case .eventField(let key):
            try container.encode("Event.Field", forKey: .type)
            try container.encode(key, forKey: .key)
        case .responseField(let key):
            try container.encode("Response.Field", forKey: .type)
            try container.encode(key, forKey: .key)
        }
    }

    var foundationValue: Any {
        switch self {
        case .null: NSNull()
        case .bool(let value): value
        case .number(let value): value
        case .string(let value): value
        case .array(let values): values.map(\.foundationValue)
        case .object(let values): values.mapValues(\.foundationValue)
        case .eventField(let key): ["type": "Event.Field", "key": key]
        case .responseField(let key): ["type": "Response.Field", "key": key]
        }
    }

    static func fromFoundation(_ value: Any) -> JourneyValue {
        switch value {
        case is NSNull: return .null
        case let value as Bool: return .bool(value)
        case let value as NSNumber: return .number(value.doubleValue)
        case let value as String: return .string(value)
        case let value as [Any]: return .array(value.map(Self.fromFoundation))
        case let value as [String: Any]: return .object(value.mapValues(Self.fromFoundation))
        default: return .null
        }
    }
}

indirect enum JourneyCondition: Codable, Sendable, Equatable {
    case truthy(JourneyValue)
    case compare(op: String, left: JourneyValue, right: JourneyValue)
    case contains(collection: JourneyValue, value: JourneyValue)
    case all([JourneyCondition])
    case any([JourneyCondition])
    case not(JourneyCondition)

    private enum CodingKeys: String, CodingKey {
        case type
        case value
        case op
        case left
        case right
        case collection
        case conditions
        case condition
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "Truthy": self = .truthy(try c.decode(JourneyValue.self, forKey: .value))
        case "Compare":
            self = .compare(
                op: try c.decode(String.self, forKey: .op),
                left: try c.decode(JourneyValue.self, forKey: .left),
                right: try c.decode(JourneyValue.self, forKey: .right)
            )
        case "Contains":
            self = .contains(
                collection: try c.decode(JourneyValue.self, forKey: .collection),
                value: try c.decode(JourneyValue.self, forKey: .value)
            )
        case "All": self = .all(try c.decode([JourneyCondition].self, forKey: .conditions))
        case "Any": self = .any(try c.decode([JourneyCondition].self, forKey: .conditions))
        case "Not": self = .not(try c.decode(JourneyCondition.self, forKey: .condition))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: c,
                debugDescription: "unknown JourneyCondition type"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .truthy(let value):
            try c.encode("Truthy", forKey: .type)
            try c.encode(value, forKey: .value)
        case .compare(let op, let left, let right):
            try c.encode("Compare", forKey: .type)
            try c.encode(op, forKey: .op)
            try c.encode(left, forKey: .left)
            try c.encode(right, forKey: .right)
        case .contains(let collection, let value):
            try c.encode("Contains", forKey: .type)
            try c.encode(collection, forKey: .collection)
            try c.encode(value, forKey: .value)
        case .all(let conditions):
            try c.encode("All", forKey: .type)
            try c.encode(conditions, forKey: .conditions)
        case .any(let conditions):
            try c.encode("Any", forKey: .type)
            try c.encode(conditions, forKey: .conditions)
        case .not(let condition):
            try c.encode("Not", forKey: .type)
            try c.encode(condition, forKey: .condition)
        }
    }
}

enum JourneyWaitTrigger: Codable, Sendable, Equatable {
    case responseChange
    case event(eventName: String, payloadSchema: JourneyEventPayloadSchema?)
    case eventOrResponseChange(eventName: String, payloadSchema: JourneyEventPayloadSchema?)

    private enum CodingKeys: String, CodingKey { case kind, eventName, payloadSchema }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "response_change": self = .responseChange
        case "event":
            self = .event(
                eventName: try c.decode(String.self, forKey: .eventName),
                payloadSchema: try c.decodeIfPresent(JourneyEventPayloadSchema.self, forKey: .payloadSchema)
            )
        case "event_or_response_change":
            self = .eventOrResponseChange(
                eventName: try c.decode(String.self, forKey: .eventName),
                payloadSchema: try c.decodeIfPresent(JourneyEventPayloadSchema.self, forKey: .payloadSchema)
            )
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown wait trigger")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .responseChange: try c.encode("response_change", forKey: .kind)
        case .event(let eventName, let payloadSchema):
            try c.encode("event", forKey: .kind)
            try c.encode(eventName, forKey: .eventName)
            try c.encodeIfPresent(payloadSchema, forKey: .payloadSchema)
        case .eventOrResponseChange(let eventName, let payloadSchema):
            try c.encode("event_or_response_change", forKey: .kind)
            try c.encode(eventName, forKey: .eventName)
            try c.encodeIfPresent(payloadSchema, forKey: .payloadSchema)
        }
    }
}

enum JourneyTimezone: Codable, Sendable, Equatable {
    case device
    case appDefault
    case iana(String)

    private enum CodingKeys: String, CodingKey { case kind, identifier }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "device": self = .device
        case "app_default": self = .appDefault
        case "iana": self = .iana(try c.decode(String.self, forKey: .identifier))
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown Journey timezone")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .device: try c.encode("device", forKey: .kind)
        case .appDefault: try c.encode("app_default", forKey: .kind)
        case .iana(let identifier):
            try c.encode("iana", forKey: .kind)
            try c.encode(identifier, forKey: .identifier)
        }
    }

}

struct EventPayloadFieldSchema: Codable, Sendable, Equatable {
    let key: String
    let required: Bool
    let type: String
    let enumValues: [String]?
    let min: Double?
    let max: Double?

    private enum CodingKeys: String, CodingKey { case key, required, type, `enum`, min, max }

    init(key: String, required: Bool, type: String, enumValues: [String]? = nil, min: Double? = nil, max: Double? = nil) {
        self.key = key
        self.required = required
        self.type = type
        self.enumValues = enumValues
        self.min = min
        self.max = max
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        required = try c.decode(Bool.self, forKey: .required)
        type = try c.decode(String.self, forKey: .type)
        enumValues = try c.decodeIfPresent([String].self, forKey: .enum)
        min = try c.decodeIfPresent(Double.self, forKey: .min)
        max = try c.decodeIfPresent(Double.self, forKey: .max)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(key, forKey: .key)
        try c.encode(required, forKey: .required)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(enumValues, forKey: .enum)
        try c.encodeIfPresent(min, forKey: .min)
        try c.encodeIfPresent(max, forKey: .max)
    }
}

struct JourneyEventPayloadSchema: Codable, Sendable, Equatable {
    let type: String
    let fields: [EventPayloadFieldSchema]
    let additionalProperties: Bool

    init(type: String = "object", fields: [EventPayloadFieldSchema], additionalProperties: Bool) {
        self.type = type
        self.fields = fields
        self.additionalProperties = additionalProperties
    }
}

enum JourneyAction: Codable, Sendable {
    case navigate(NavigateAction)
    case back(BackAction)
    case delay(DelayAction)
    case startAnimation(StartAnimationAction)
    case timeWindow(TimeWindowAction)
    case waitUntil(WaitUntilAction)
    case condition(ConditionAction)
    case experiment(ExperimentAction)
    case deviceAvailable(DeviceAvailableAction)
    case sendEvent(SendEventAction)
    case milestone(MilestoneAction)
    case updateCustomer(UpdateCustomerAction)
    case submitResponse(SubmitResponseAction)
    case purchase(PurchaseAction)
    case restore(RestoreAction)
    case requestNotifications(RequestNotificationsAction)
    case requestPermission(RequestPermissionAction)
    case requestTracking(RequestTrackingAction)
    case openLink(OpenLinkAction)
    case dismiss(DismissAction)
    case callDelegate(CallDelegateAction)
    case connectorAction(ConnectorAction)
    case grantEntitlement(GrantEntitlementAction)
    case setViewModel(SetViewModelAction)
    case fireTrigger(FireTriggerAction)
    case listInsert(ListInsertAction)
    case listRemove(ListRemoveAction)
    case listSwap(ListSwapAction)
    case listMove(ListMoveAction)
    case listSet(ListSetAction)
    case listClear(ListClearAction)
    case handoff(HandoffAction)
    case exit(ExitAction)

    private enum CodingKeys: String, CodingKey, Sendable {
        case type
    }

    private enum ActionType: String, Codable, Sendable {
        case navigate
        case back
        case delay
        case startAnimation = "start_animation"
        case timeWindow = "time_window"
        case waitUntil = "wait_until"
        case condition
        case experiment
        case deviceAvailable = "device_available"
        case sendEvent = "send_event"
        case milestone
        case updateCustomer = "update_customer"
        case submitResponse = "submit_response"
        case purchase
        case restore
        case requestNotifications = "request_notifications"
        case requestPermission = "request_permission"
        case requestTracking = "request_tracking"
        case openLink = "open_link"
        case dismiss
        case callDelegate = "call_delegate"
        case connectorAction = "connector_action"
        case grantEntitlement = "grant_entitlement"
        case setViewModel = "set_view_model"
        case fireTrigger = "fire_trigger"
        case listInsert = "list_insert"
        case listRemove = "list_remove"
        case listSwap = "list_swap"
        case listMove = "list_move"
        case listSet = "list_set"
        case listClear = "list_clear"
        case handoff
        case exit
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let typeValue = (try? container.decode(ActionType.self, forKey: .type))
        switch typeValue {
        case .navigate:
            self = .navigate(try NavigateAction(from: decoder))
        case .back:
            self = .back(try BackAction(from: decoder))
        case .delay:
            self = .delay(try DelayAction(from: decoder))
        case .startAnimation:
            self = .startAnimation(try StartAnimationAction(from: decoder))
        case .timeWindow:
            self = .timeWindow(try TimeWindowAction(from: decoder))
        case .waitUntil:
            self = .waitUntil(try WaitUntilAction(from: decoder))
        case .condition:
            self = .condition(try ConditionAction(from: decoder))
        case .experiment:
            self = .experiment(try ExperimentAction(from: decoder))
        case .deviceAvailable:
            self = .deviceAvailable(try DeviceAvailableAction(from: decoder))
        case .sendEvent:
            self = .sendEvent(try SendEventAction(from: decoder))
        case .milestone:
            self = .milestone(try MilestoneAction(from: decoder))
        case .updateCustomer:
            self = .updateCustomer(try UpdateCustomerAction(from: decoder))
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
        case .connectorAction:
            self = .connectorAction(try ConnectorAction(from: decoder))
        case .grantEntitlement:
            self = .grantEntitlement(try GrantEntitlementAction(from: decoder))
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
        case .handoff:
            self = .handoff(try HandoffAction(from: decoder))
        case .exit:
            self = .exit(try ExitAction(from: decoder))
        case .none:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "unknown journey action"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .navigate(let action):
            try action.encode(to: encoder)
        case .back(let action):
            try action.encode(to: encoder)
        case .delay(let action):
            try action.encode(to: encoder)
        case .startAnimation(let action):
            try action.encode(to: encoder)
        case .timeWindow(let action):
            try action.encode(to: encoder)
        case .waitUntil(let action):
            try action.encode(to: encoder)
        case .condition(let action):
            try action.encode(to: encoder)
        case .experiment(let action):
            try action.encode(to: encoder)
        case .deviceAvailable(let action):
            try action.encode(to: encoder)
        case .sendEvent(let action):
            try action.encode(to: encoder)
        case .milestone(let action):
            try action.encode(to: encoder)
        case .updateCustomer(let action):
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
        case .connectorAction(let action):
            try action.encode(to: encoder)
        case .grantEntitlement(let action):
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
        case .handoff(let action):
            try action.encode(to: encoder)
        case .exit(let action):
            try action.encode(to: encoder)
        }
    }
}

extension JourneyAction {
    /// Stable compiler-authored identity used by cross-plane transition facts.
    var nodeId: String? {
        switch self {
        case .navigate(let action):
            return action.nodeId
        case .back(let action):
            return action.nodeId
        case .delay(let action):
            return action.nodeId
        case .startAnimation(let action):
            return action.nodeId
        case .timeWindow(let action):
            return action.nodeId
        case .waitUntil(let action):
            return action.nodeId
        case .condition(let action):
            return action.nodeId
        case .experiment(let action):
            return action.nodeId
        case .deviceAvailable(let action):
            return action.nodeId
        case .sendEvent(let action):
            return action.nodeId
        case .milestone(let action):
            return action.nodeId
        case .updateCustomer(let action):
            return action.nodeId
        case .submitResponse(let action):
            return action.nodeId
        case .purchase(let action):
            return action.nodeId
        case .restore(let action):
            return action.nodeId
        case .requestNotifications(let action):
            return action.nodeId
        case .requestPermission(let action):
            return action.nodeId
        case .requestTracking(let action):
            return action.nodeId
        case .openLink(let action):
            return action.nodeId
        case .dismiss(let action):
            return action.nodeId
        case .callDelegate(let action):
            return action.nodeId
        case .connectorAction(let action):
            return action.nodeId
        case .grantEntitlement(let action):
            return action.nodeId
        case .setViewModel(let action):
            return action.nodeId
        case .fireTrigger(let action):
            return action.nodeId
        case .listInsert(let action):
            return action.nodeId
        case .listRemove(let action):
            return action.nodeId
        case .listSwap(let action):
            return action.nodeId
        case .listMove(let action):
            return action.nodeId
        case .listSet(let action):
            return action.nodeId
        case .listClear(let action):
            return action.nodeId
        case .handoff(let action):
            return action.nodeId
        case .exit(let action):
            return action.nodeId
        }
    }
}

struct NavigateAction: Codable, Sendable {
    let type: String
    /// Stable compiler-authored identity used by transition facts.
    let nodeId: String?
    let screenId: String
    let transition: AnyCodable?

    init(
        type: String = "navigate",
        nodeId: String? = nil,
        screenId: String,
        transition: AnyCodable? = nil
    ) {
        self.type = type
        self.nodeId = nodeId
        self.screenId = screenId
        self.transition = transition
    }
}

struct BackAction: Codable, Sendable {
    let type: String
    /// Stable compiler-authored identity used by transition facts.
    let nodeId: String?
    let steps: Int?
    let transition: AnyCodable?

    init(
        type: String = "back",
        nodeId: String? = nil,
        steps: Int? = nil,
        transition: AnyCodable? = nil
    ) {
        self.type = type
        self.nodeId = nodeId
        self.steps = steps
        self.transition = transition
    }
}

struct DelayAction: Codable, Sendable {
    let type: String
    /// Stable compiler-authored identity used by transition facts.
    let nodeId: String?
    let durationMs: Int

    init(type: String = "delay", nodeId: String? = nil, durationMs: Int) {
        self.type = type
        self.nodeId = nodeId
        self.durationMs = durationMs
    }
}

/// A compiler-authored animation command lowered to the native Rive listener path.
struct StartAnimationAction: Codable, Sendable {
    /// The action discriminator. Defaults to `start_animation`.
    let type: String
    /// Stable compiler-authored identity used by transition facts.
    let nodeId: String?
    /// Stable identifier for the authored animation.
    let animationId: String
    /// Playback direction (`forward` or `reverse`).
    let direction: String?
    /// Whether playback restarts when the action fires.
    let restart: Bool?

    /// Creates a start-animation action.
    init(
        type: String = "start_animation",
        nodeId: String? = nil,
        animationId: String,
        direction: String? = nil,
        restart: Bool? = nil
    ) {
        self.type = type
        self.nodeId = nodeId
        self.animationId = animationId
        self.direction = direction
        self.restart = restart
    }
}

struct TimeWindowAction: Codable, Sendable {
    let type: String
    /// Internal execution identity. It is not part of the signed wire shape.
    let nodeId: String?
    let startTime: String
    let endTime: String
    let timezone: JourneyTimezone
    let daysOfWeek: [Int]
    let onInside: [JourneyAction]

    init(
        type: String = "time_window",
        nodeId: String? = nil,
        startTime: String,
        endTime: String,
        timezone: JourneyTimezone,
        daysOfWeek: [Int],
        onInside: [JourneyAction]
    ) {
        self.type = type
        self.nodeId = nodeId
        self.startTime = startTime
        self.endTime = endTime
        self.timezone = timezone
        self.daysOfWeek = daysOfWeek
        self.onInside = onInside
    }

    private enum CodingKeys: String, CodingKey { case type, startTime, endTime, timezone, daysOfWeek, onInside }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        guard type == "time_window" else { throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "invalid time_window action") }
        nodeId = nil
        startTime = try c.decode(String.self, forKey: .startTime)
        endTime = try c.decode(String.self, forKey: .endTime)
        timezone = try c.decode(JourneyTimezone.self, forKey: .timezone)
        daysOfWeek = try c.decode([Int].self, forKey: .daysOfWeek)
        onInside = try c.decode([JourneyAction].self, forKey: .onInside)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(startTime, forKey: .startTime)
        try c.encode(endTime, forKey: .endTime)
        try c.encode(timezone, forKey: .timezone)
        try c.encode(daysOfWeek, forKey: .daysOfWeek)
        try c.encode(onInside, forKey: .onInside)
    }
}

struct WaitUntilAction: Codable, Sendable {
    let type: String
    let nodeId: String?
    let trigger: JourneyWaitTrigger
    let condition: JourneyCondition
    let maxTimeMs: Int
    let onSatisfied: [JourneyAction]
    let onTimeout: [JourneyAction]

    init(
        type: String = "wait_until",
        nodeId: String? = nil,
        trigger: JourneyWaitTrigger,
        condition: JourneyCondition,
        maxTimeMs: Int,
        onSatisfied: [JourneyAction],
        onTimeout: [JourneyAction]
    ) {
        self.type = type
        self.nodeId = nodeId
        self.trigger = trigger
        self.condition = condition
        self.maxTimeMs = maxTimeMs
        self.onSatisfied = onSatisfied
        self.onTimeout = onTimeout
    }

    private enum CodingKeys: String, CodingKey { case type, trigger, condition, maxTimeMs, onSatisfied, onTimeout }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        guard type == "wait_until" else { throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "invalid wait_until action") }
        nodeId = nil
        trigger = try c.decode(JourneyWaitTrigger.self, forKey: .trigger)
        condition = try c.decode(JourneyCondition.self, forKey: .condition)
        maxTimeMs = try c.decode(Int.self, forKey: .maxTimeMs)
        onSatisfied = try c.decode([JourneyAction].self, forKey: .onSatisfied)
        onTimeout = try c.decode([JourneyAction].self, forKey: .onTimeout)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(trigger, forKey: .trigger)
        try c.encode(condition, forKey: .condition)
        try c.encode(maxTimeMs, forKey: .maxTimeMs)
        try c.encode(onSatisfied, forKey: .onSatisfied)
        try c.encode(onTimeout, forKey: .onTimeout)
    }
}

struct ConditionAction: Codable, Sendable {
    let type: String
    let nodeId: String?
    let branches: [ConditionBranch]
    let defaultProgram: [JourneyAction]

    init(
        type: String = "condition",
        nodeId: String? = nil,
        branches: [ConditionBranch],
        defaultProgram: [JourneyAction]
    ) {
        self.type = type
        self.nodeId = nodeId
        self.branches = branches
        self.defaultProgram = defaultProgram
    }

    private enum CodingKeys: String, CodingKey { case type, branches, defaultProgram }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        guard type == "condition" else { throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "invalid condition action") }
        nodeId = nil
        branches = try c.decode([ConditionBranch].self, forKey: .branches)
        defaultProgram = try c.decode([JourneyAction].self, forKey: .defaultProgram)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(branches, forKey: .branches)
        try c.encode(defaultProgram, forKey: .defaultProgram)
    }
}

struct ConditionBranch: Codable, Sendable {
    let id: String
    let condition: JourneyCondition
    let program: [JourneyAction]

    init(id: String, condition: JourneyCondition, program: [JourneyAction]) {
        self.id = id
        self.condition = condition
        self.program = program
    }

    private enum CodingKeys: String, CodingKey { case id, condition, program }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        condition = try c.decode(JourneyCondition.self, forKey: .condition)
        program = try c.decode([JourneyAction].self, forKey: .program)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(condition, forKey: .condition)
        try c.encode(program, forKey: .program)
    }
}

struct ExperimentAction: Codable, Sendable {
    let type: String
    let nodeId: String?
    let experimentId: String
    let name: String?
    let description: String?
    let hypothesis: String?
    let variants: [ExperimentVariant]

    init(
        type: String = "experiment",
        nodeId: String? = nil,
        experimentId: String,
        variants: [ExperimentVariant]
    ) {
        self.type = type
        self.nodeId = nodeId
        self.experimentId = experimentId
        self.name = nil
        self.description = nil
        self.hypothesis = nil
        self.variants = variants
    }

    init(
        type: String = "experiment",
        nodeId: String? = nil,
        experimentId: String,
        name: String,
        description: String? = nil,
        hypothesis: String? = nil,
        variants: [ExperimentVariant]
    ) {
        self.type = type
        self.nodeId = nodeId
        self.experimentId = experimentId
        self.name = name
        self.description = description
        self.hypothesis = hypothesis
        self.variants = variants
    }

    private enum CodingKeys: String, CodingKey { case type, experimentId, name, description, hypothesis, variants }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        nodeId = nil
        experimentId = try c.decode(String.self, forKey: .experimentId)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        hypothesis = try c.decodeIfPresent(String.self, forKey: .hypothesis)
        variants = try c.decode([ExperimentVariant].self, forKey: .variants)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(experimentId, forKey: .experimentId)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(hypothesis, forKey: .hypothesis)
        try c.encode(variants, forKey: .variants)
    }
}

struct ExperimentVariant: Codable, Sendable {
    let id: String
    let name: String?
    let percentage: Double
    let isHoldout: Bool
    let program: [JourneyAction]

    init(
        id: String,
        name: String? = nil,
        percentage: Double,
        isHoldout: Bool = false,
        program: [JourneyAction]
    ) {
        self.id = id
        self.name = name
        self.percentage = percentage
        self.isHoldout = isHoldout
        self.program = program
    }

    private enum CodingKeys: String, CodingKey { case id, name, percentage, isHoldout, program }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        percentage = try c.decode(Double.self, forKey: .percentage)
        isHoldout = try c.decode(Bool.self, forKey: .isHoldout)
        program = try c.decode([JourneyAction].self, forKey: .program)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encode(percentage, forKey: .percentage)
        try c.encode(isHoldout, forKey: .isHoldout)
        try c.encode(program, forKey: .program)
    }
}

struct DeviceAvailableAction: Codable, Sendable {
    let type: String
    let nodeId: String?
    let claimWithinMs: Int
    let onAvailable: [JourneyAction]
    let onUnavailable: [JourneyAction]

    init(
        type: String = "device_available",
        nodeId: String? = nil,
        claimWithinMs: Int,
        onAvailable: [JourneyAction],
        onUnavailable: [JourneyAction]
    ) {
        self.type = type
        self.nodeId = nodeId
        self.claimWithinMs = claimWithinMs
        self.onAvailable = onAvailable
        self.onUnavailable = onUnavailable
    }

    private enum CodingKeys: String, CodingKey { case type, claimWithinMs, onAvailable, onUnavailable }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        guard type == "device_available" else {
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "invalid device_available action")
        }
        nodeId = nil
        claimWithinMs = try c.decode(Int.self, forKey: .claimWithinMs)
        onAvailable = try c.decode([JourneyAction].self, forKey: .onAvailable)
        onUnavailable = try c.decode([JourneyAction].self, forKey: .onUnavailable)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(claimWithinMs, forKey: .claimWithinMs)
        try c.encode(onAvailable, forKey: .onAvailable)
        try c.encode(onUnavailable, forKey: .onUnavailable)
    }
}

struct SendEventAction: Codable, Sendable {
    let type: String
    /// Stable compiler-authored identity used by transition facts.
    let nodeId: String?
    let eventName: String
    let payload: [String: JourneyValue]?
    let properties: [String: AnyCodable]?

    init(
        type: String = "send_event",
        nodeId: String? = nil,
        eventName: String,
        properties: [String: AnyCodable]? = nil
    ) {
        self.type = type
        self.nodeId = nodeId
        self.eventName = eventName
        self.payload = properties?.mapValues { value in
            JourneyValue.fromFoundation(value.value)
        }
        self.properties = properties
    }

    init(
        type: String = "send_event",
        nodeId: String? = nil,
        eventName: String,
        payload: [String: JourneyValue]?
    ) {
        self.type = type
        self.nodeId = nodeId
        self.eventName = eventName
        self.payload = payload
        self.properties = payload?.mapValues { AnyCodable($0.foundationValue) }
    }

    private enum CodingKeys: String, CodingKey { case type, eventName, payload }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        nodeId = nil
        eventName = try c.decode(String.self, forKey: .eventName)
        payload = try c.decodeIfPresent([String: JourneyValue].self, forKey: .payload)
        properties = payload?.mapValues { AnyCodable($0.foundationValue) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(eventName, forKey: .eventName)
        try c.encodeIfPresent(payload, forKey: .payload)
    }
}

/// A experience action that emits a named journey milestone.
struct MilestoneAction: Codable, Sendable {
    /// The action discriminator. Defaults to `milestone`.
    let type: String
    /// Stable compiler-authored identity used by transition facts.
    let nodeId: String?
    /// Stable identifier used by journey goals and server folding.
    let milestoneId: String
    /// Optional author-facing label.
    let label: String?

    /// Creates a milestone action.
    /// - Parameters:
    ///   - type: Action discriminator. Normally `milestone`.
    ///   - milestoneId: Non-empty stable milestone identifier.
    ///   - label: Optional author-facing label.
    init(
        type: String = "milestone",
        nodeId: String? = nil,
        milestoneId: String,
        label: String? = nil
    ) {
        self.type = type
        self.nodeId = nodeId
        self.milestoneId = milestoneId
        self.label = label
    }

    private enum CodingKeys: String, CodingKey, Sendable {
        case type
        case nodeId
        case milestoneId
        case label
    }

    /// Decodes a milestone action and rejects a missing or blank milestone identifier.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? "milestone"
        nodeId = try container.decodeIfPresent(String.self, forKey: .nodeId)
        let decodedMilestoneId = try container.decode(String.self, forKey: .milestoneId)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !decodedMilestoneId.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .milestoneId,
                in: container,
                debugDescription: "milestone actions require a non-empty milestoneId"
            )
        }
        milestoneId = decodedMilestoneId
        label = try container.decodeIfPresent(String.self, forKey: .label)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(nodeId, forKey: .nodeId)
        try container.encode(milestoneId, forKey: .milestoneId)
        try container.encodeIfPresent(label, forKey: .label)
    }
}

struct UpdateCustomerAction: Codable, Sendable {
    let type: String
    /// Stable compiler-authored identity used by transition facts.
    let nodeId: String?
    let attributes: [String: AnyCodable]
    let journeyAttributes: [String: JourneyValue]

    init(
        type: String = "update_customer",
        nodeId: String? = nil,
        attributes: [String: AnyCodable]
    ) {
        self.type = type
        self.nodeId = nodeId
        self.attributes = attributes
        self.journeyAttributes = attributes.mapValues { JourneyValue.fromFoundation($0.value) }
    }

    private enum CodingKeys: String, CodingKey { case type, attributes }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        guard type == "update_customer" else {
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "invalid update_customer action")
        }
        nodeId = nil
        journeyAttributes = try c.decode([String: JourneyValue].self, forKey: .attributes)
        attributes = journeyAttributes.mapValues { AnyCodable($0.foundationValue) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(journeyAttributes, forKey: .attributes)
    }
}

struct SubmitResponseAction: Codable, Sendable {
    let type: String
    /// Stable compiler-authored identity used by transition facts.
    let nodeId: String?
    init(type: String = "submit_response") {
        self.type = type
        self.nodeId = nil
    }

    private enum CodingKeys: String, CodingKey { case type }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        guard type == "submit_response" else {
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "invalid submit_response action")
        }
        nodeId = nil
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
    }
}

struct JourneyResponseSchema: Codable, Sendable {
    let responseSchemaId: String
    let responseSchemaVersionId: String?

    init(responseSchemaId: String, responseSchemaVersionId: String? = nil) {
        self.responseSchemaId = responseSchemaId
        self.responseSchemaVersionId = responseSchemaVersionId
    }
}

struct PurchaseAction: Codable, Sendable {
    let type: String
    /// Stable compiler-authored identity used by transition facts.
    let nodeId: String?
    /// Compiler-authored identity for the Product placement the customer saw.
    /// The runtime resolves this value to the exact signed placement and its
    /// already-fetched StoreKit product before checkout.
    let placementId: AnyCodable
    /// Outcome outlets (Experience Logic 2026-07-04): outcome routing lives at the
    /// purchase site as wired chains. When present, the runner correlates the
    /// async purchase outcome back to this node and runs the matching chain.
    /// Global $purchase_* events still fire for cross-cutting listeners.
    /// Actions interpreted after a completed purchase.
    let onCompleted: [JourneyAction]?
    /// Actions interpreted after a failed purchase.
    let onFailed: [JourneyAction]?
    /// Actions interpreted after a cancelled purchase.
    let onCancelled: [JourneyAction]?

    /// Creates a purchase action for an exact signed product placement.
    ///
    /// - Parameters:
    ///   - type: The serialized action type. Defaults to `purchase`.
    ///   - nodeId: The compiler-authored journey node identity.
    ///   - placementId: The signed placement identity shown to the customer.
    ///   - onCompleted: Actions to run after a completed purchase.
    ///   - onFailed: Actions to run after a failed purchase.
    ///   - onCancelled: Actions to run after a cancelled purchase.
    init(
        type: String = "purchase",
        nodeId: String? = nil,
        placementId: AnyCodable,
        onCompleted: [JourneyAction]? = nil,
        onFailed: [JourneyAction]? = nil,
        onCancelled: [JourneyAction]? = nil
    ) {
        self.type = type
        self.nodeId = nodeId
        self.placementId = placementId
        self.onCompleted = onCompleted
        self.onFailed = onFailed
        self.onCancelled = onCancelled
    }

    private enum CodingKeys: String, CodingKey {
        case type, placementId, productId, placementIndex, onCompleted, onFailed, onCancelled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        guard type == "purchase" else {
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "invalid purchase action")
        }
        guard !c.contains(.productId), !c.contains(.placementIndex) else {
            throw DecodingError.dataCorruptedError(
                forKey: c.contains(.productId) ? .productId : .placementIndex,
                in: c,
                debugDescription: "purchase actions require placementId; productId and placementIndex are unsupported"
            )
        }
        nodeId = nil
        placementId = try c.decode(AnyCodable.self, forKey: .placementId)
        onCompleted = try c.decodeIfPresent([JourneyAction].self, forKey: .onCompleted)
        onFailed = try c.decodeIfPresent([JourneyAction].self, forKey: .onFailed)
        onCancelled = try c.decodeIfPresent([JourneyAction].self, forKey: .onCancelled)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(placementId, forKey: .placementId)
        try c.encodeIfPresent(onCompleted, forKey: .onCompleted)
        try c.encodeIfPresent(onFailed, forKey: .onFailed)
        try c.encodeIfPresent(onCancelled, forKey: .onCancelled)
    }
}

struct RestoreAction: Codable, Sendable {
    let type: String
    /// Stable compiler-authored identity used by transition facts.
    let nodeId: String?
    /// Actions interpreted when purchases are restored.
    let onRestored: [JourneyAction]?
    /// Actions interpreted when no restorable purchases exist.
    let onNoPurchases: [JourneyAction]?
    /// Actions interpreted after a restore failure.
    let onFailed: [JourneyAction]?

    init(
        type: String = "restore",
        nodeId: String? = nil,
        onRestored: [JourneyAction]? = nil,
        onNoPurchases: [JourneyAction]? = nil,
        onFailed: [JourneyAction]? = nil
    ) {
        self.type = type
        self.nodeId = nodeId
        self.onRestored = onRestored
        self.onNoPurchases = onNoPurchases
        self.onFailed = onFailed
    }
}

struct RequestNotificationsAction: Codable, Sendable {
    let type: String
    /// Stable compiler-authored identity used by transition facts.
    let nodeId: String?

    init(type: String = "request_notifications", nodeId: String? = nil) {
        self.type = type
        self.nodeId = nodeId
    }
}

struct RequestPermissionAction: Codable, Sendable {
    let type: String
    /// Stable compiler-authored identity used by transition facts.
    let nodeId: String?
    let permissionType: String

    init(
        type: String = "request_permission",
        nodeId: String? = nil,
        permissionType: String
    ) {
        self.type = type
        self.nodeId = nodeId
        self.permissionType = permissionType
    }
}

struct RequestTrackingAction: Codable, Sendable {
    let type: String
    /// Stable compiler-authored identity used by transition facts.
    let nodeId: String?

    init(type: String = "request_tracking", nodeId: String? = nil) {
        self.type = type
        self.nodeId = nodeId
    }
}

struct OpenLinkAction: Codable, Sendable {
    let type: String
    /// Stable compiler-authored identity used by transition facts.
    let nodeId: String?
    let url: AnyCodable
    let journeyURL: JourneyValue
    let target: String?

    init(
        type: String = "open_link",
        nodeId: String? = nil,
        url: AnyCodable,
        target: String? = nil
    ) {
        self.type = type
        self.nodeId = nodeId
        self.url = url
        self.journeyURL = JourneyValue.fromFoundation(url.value)
        self.target = target
    }

    private enum CodingKeys: String, CodingKey { case type, url, target }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        guard type == "open_link" else {
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "invalid open_link action")
        }
        nodeId = nil
        journeyURL = try c.decode(JourneyValue.self, forKey: .url)
        url = AnyCodable(journeyURL.foundationValue)
        target = try c.decode(String.self, forKey: .target)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(journeyURL, forKey: .url)
        try c.encode(target ?? "external", forKey: .target)
    }
}

struct DismissAction: Codable, Sendable {
    let type: String
    /// Stable compiler-authored identity used by transition facts.
    let nodeId: String?
    let reason: String?

    init(
        type: String = "dismiss",
        nodeId: String? = nil,
        reason: String? = nil
    ) {
        self.type = type
        self.nodeId = nodeId
        self.reason = reason
    }
}

struct CallDelegateAction: Codable, Sendable {
    let type: String
    /// Stable compiler-authored identity used by transition facts.
    let nodeId: String?
    let message: String
    let payload: AnyCodable?
    let journeyPayload: [String: JourneyValue]?

    init(
        type: String = "call_delegate",
        nodeId: String? = nil,
        message: String,
        payload: AnyCodable? = nil
    ) {
        self.type = type
        self.nodeId = nodeId
        self.message = message
        self.payload = payload
        if let payload, let values = payload.value as? [String: Any] {
            self.journeyPayload = values.mapValues(JourneyValue.fromFoundation)
        } else {
            self.journeyPayload = nil
        }
    }

    private enum CodingKeys: String, CodingKey { case type, message, payload }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        guard type == "call_delegate" else {
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "invalid call_delegate action")
        }
        nodeId = nil
        message = try c.decode(String.self, forKey: .message)
        journeyPayload = try c.decodeIfPresent([String: JourneyValue].self, forKey: .payload)
        payload = journeyPayload.map { AnyCodable($0.mapValues(\.foundationValue)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(message, forKey: .message)
        try c.encodeIfPresent(journeyPayload, forKey: .payload)
    }
}

struct ConnectorAction: Codable, Sendable {
    let type: String
    /// Stable compiler-authored identity used by transition facts.
    let nodeId: String?
    let accountRef: String
    let toolKey: String
    let payload: AnyCodable
    let journeyPayload: [String: JourneyValue]
    let onSucceeded: [JourneyAction]?
    let onFailed: [JourneyAction]?
    let onTimeout: [JourneyAction]?
    let timeoutMs: Int?

    init(
        type: String = "connector_action",
        nodeId: String? = nil,
        accountRef: String,
        toolKey: String,
        payload: AnyCodable,
        onSucceeded: [JourneyAction]? = nil,
        onFailed: [JourneyAction]? = nil,
        onTimeout: [JourneyAction]? = nil,
        timeoutMs: Int? = nil
    ) {
        self.type = type
        self.nodeId = nodeId
        self.accountRef = accountRef
        self.toolKey = toolKey
        self.payload = payload
        if let values = payload.value as? [String: Any] {
            self.journeyPayload = values.mapValues(JourneyValue.fromFoundation)
        } else {
            self.journeyPayload = [:]
        }
        self.onSucceeded = onSucceeded
        self.onFailed = onFailed
        self.onTimeout = onTimeout
        self.timeoutMs = timeoutMs
    }

    private enum CodingKeys: String, CodingKey {
        case type, accountRef, toolKey, payload, timeoutMs, onSucceeded, onFailed, onTimeout
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        guard type == "connector_action" else {
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "invalid connector_action action")
        }
        nodeId = nil
        accountRef = try c.decode(String.self, forKey: .accountRef)
        toolKey = try c.decode(String.self, forKey: .toolKey)
        journeyPayload = try c.decode([String: JourneyValue].self, forKey: .payload)
        payload = AnyCodable(journeyPayload.mapValues(\.foundationValue))
        timeoutMs = try c.decode(Int.self, forKey: .timeoutMs)
        onSucceeded = try c.decode([JourneyAction].self, forKey: .onSucceeded)
        onFailed = try c.decode([JourneyAction].self, forKey: .onFailed)
        onTimeout = try c.decode([JourneyAction].self, forKey: .onTimeout)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(accountRef, forKey: .accountRef)
        try c.encode(toolKey, forKey: .toolKey)
        try c.encode(journeyPayload, forKey: .payload)
        try c.encode(timeoutMs ?? 120_000, forKey: .timeoutMs)
        try c.encode(onSucceeded ?? [], forKey: .onSucceeded)
        try c.encode(onFailed ?? [], forKey: .onFailed)
        try c.encode(onTimeout ?? [], forKey: .onTimeout)
    }
}

struct GrantEntitlementAction: Codable, Sendable {
    let type: String
    /// Stable compiler-authored identity used by transition facts.
    let nodeId: String?
    let featureId: String
    let balance: Double?
    let unlimited: Bool?
    let onSucceeded: [JourneyAction]?
    let onFailed: [JourneyAction]?
    let onTimeout: [JourneyAction]?

    init(
        type: String = "grant_entitlement",
        nodeId: String? = nil,
        featureId: String,
        balance: Double? = nil,
        unlimited: Bool? = nil,
        onSucceeded: [JourneyAction]? = nil,
        onFailed: [JourneyAction]? = nil,
        onTimeout: [JourneyAction]? = nil
    ) {
        self.type = type
        self.nodeId = nodeId
        self.featureId = featureId
        self.balance = balance
        self.unlimited = unlimited
        self.onSucceeded = onSucceeded
        self.onFailed = onFailed
        self.onTimeout = onTimeout
    }
}

struct SetViewModelAction: Codable, Sendable {
    let type: String
    /// Stable compiler-authored identity used by transition facts.
    let nodeId: String?
    let path: VmPathRef
    let value: AnyCodable

    init(
        type: String = "set_view_model",
        nodeId: String? = nil,
        path: VmPathRef,
        value: AnyCodable
    ) {
        self.type = type
        self.nodeId = nodeId
        self.path = path
        self.value = value
    }
}

struct FireTriggerAction: Codable, Sendable {
    let type: String
    /// Stable compiler-authored identity used by transition facts.
    let nodeId: String?
    let path: VmPathRef

    init(
        type: String = "fire_trigger",
        nodeId: String? = nil,
        path: VmPathRef
    ) {
        self.type = type
        self.nodeId = nodeId
        self.path = path
    }
}

struct ListInsertAction: Codable, Sendable {
    let type: String
    /// Stable compiler-authored identity used by transition facts.
    let nodeId: String?
    let path: VmPathRef
    let index: Int?
    let value: AnyCodable

    init(
        type: String = "list_insert",
        nodeId: String? = nil,
        path: VmPathRef,
        index: Int? = nil,
        value: AnyCodable
    ) {
        self.type = type
        self.nodeId = nodeId
        self.path = path
        self.index = index
        self.value = value
    }
}

struct ListRemoveAction: Codable, Sendable {
    let type: String
    /// Stable compiler-authored identity used by transition facts.
    let nodeId: String?
    let path: VmPathRef
    let index: Int

    init(
        type: String = "list_remove",
        nodeId: String? = nil,
        path: VmPathRef,
        index: Int
    ) {
        self.type = type
        self.nodeId = nodeId
        self.path = path
        self.index = index
    }
}

struct ListSwapAction: Codable, Sendable {
    let type: String
    /// Stable compiler-authored identity used by transition facts.
    let nodeId: String?
    let path: VmPathRef
    let indexA: Int
    let indexB: Int

    init(
        type: String = "list_swap",
        nodeId: String? = nil,
        path: VmPathRef,
        indexA: Int,
        indexB: Int
    ) {
        self.type = type
        self.nodeId = nodeId
        self.path = path
        self.indexA = indexA
        self.indexB = indexB
    }
}

struct ListMoveAction: Codable, Sendable {
    let type: String
    /// Stable compiler-authored identity used by transition facts.
    let nodeId: String?
    let path: VmPathRef
    let from: Int
    let to: Int

    init(
        type: String = "list_move",
        nodeId: String? = nil,
        path: VmPathRef,
        from: Int,
        to: Int
    ) {
        self.type = type
        self.nodeId = nodeId
        self.path = path
        self.from = from
        self.to = to
    }
}

struct ListSetAction: Codable, Sendable {
    let type: String
    /// Stable compiler-authored identity used by transition facts.
    let nodeId: String?
    let path: VmPathRef
    let index: Int
    let value: AnyCodable

    init(
        type: String = "list_set",
        nodeId: String? = nil,
        path: VmPathRef,
        index: Int,
        value: AnyCodable
    ) {
        self.type = type
        self.nodeId = nodeId
        self.path = path
        self.index = index
        self.value = value
    }
}

struct ListClearAction: Codable, Sendable {
    let type: String
    /// Stable compiler-authored identity used by transition facts.
    let nodeId: String?
    let path: VmPathRef

    init(
        type: String = "list_clear",
        nodeId: String? = nil,
        path: VmPathRef
    ) {
        self.type = type
        self.nodeId = nodeId
        self.path = path
    }
}

/// Transfers journey ownership to another compiler-partitioned region.
struct HandoffAction: Codable, Sendable {
    /// The action discriminator. Defaults to `handoff`.
    let type: String
    /// Stable compiler-authored identity used by transition facts.
    let nodeId: String
    /// Stable graph edge crossed by this transfer.
    let edgeId: String
    /// Transfer direction, such as `device_to_server`.
    let direction: String
    /// Destination execution region.
    let toRegionId: String
    /// First compiler-authored node in the destination region.
    let toNodeId: String

    /// Creates an ownership-transfer action.
    init(
        type: String = "handoff",
        nodeId: String,
        edgeId: String,
        direction: String,
        toRegionId: String,
        toNodeId: String
    ) {
        self.type = type
        self.nodeId = nodeId
        self.edgeId = edgeId
        self.direction = direction
        self.toRegionId = toRegionId
        self.toNodeId = toNodeId
    }
}

struct ExitAction: Codable, Sendable {
    let type: String
    /// Stable compiler-authored identity used by transition facts.
    let nodeId: String?
    let reason: String?

    init(type: String = "exit", nodeId: String? = nil, reason: String? = nil) {
        self.type = type
        self.nodeId = nodeId
        self.reason = reason
    }
}
