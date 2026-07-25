import Foundation

// MARK: - Journey Action Schema
//
// The wire schema for journey actions (the behavioral half of an experience).
// Moved out of RemoteFlow.swift (cleanup Phase 2): these types belong to the
// Journey domain, not the flow/screens wire model.

struct DynamicCodingKey: CodingKey, Sendable {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

public enum JourneyAction: Codable, Sendable {
    case navigate(NavigateAction)
    case back(BackAction)
    case delay(DelayAction)
    case timeWindow(TimeWindowAction)
    case waitUntil(WaitUntilAction)
    case condition(ConditionAction)
    case experiment(ExperimentAction)
    case sendEvent(SendEventAction)
    case milestone(MilestoneAction)
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
    case unknown(type: String, payload: [String: AnyCodable])

    private enum CodingKeys: String, CodingKey, Sendable {
        case type
    }

    private enum ActionType: String, Codable, Sendable {
        case navigate
        case back
        case delay
        case timeWindow = "time_window"
        case waitUntil = "wait_until"
        case condition
        case experiment
        case sendEvent = "send_event"
        case milestone
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
        case .milestone:
            self = .milestone(try MilestoneAction(from: decoder))
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
        case .milestone(let action):
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
        case .timeWindow(let action):
            return action.nodeId
        case .waitUntil(let action):
            return action.nodeId
        case .condition(let action):
            return action.nodeId
        case .experiment(let action):
            return action.nodeId
        case .sendEvent(let action):
            return action.nodeId
        case .milestone(let action):
            return action.nodeId
        case .updateCustomer(let action):
            return action.nodeId
        case .setResponseField(let action):
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
        case .unknown(_, let payload):
            return payload["nodeId"]?.value as? String
        }
    }
}

public struct NavigateAction: Codable, Sendable {
    public let type: String
    /// Stable compiler-authored identity used by transition facts.
    public let nodeId: String?
    public let screenId: String
    public let transition: AnyCodable?

    public init(
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

public struct BackAction: Codable, Sendable {
    public let type: String
    /// Stable compiler-authored identity used by transition facts.
    public let nodeId: String?
    public let steps: Int?
    public let transition: AnyCodable?

    public init(
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

public struct DelayAction: Codable, Sendable {
    public let type: String
    /// Stable compiler-authored identity used by transition facts.
    public let nodeId: String?
    public let durationMs: Int

    public init(type: String = "delay", nodeId: String? = nil, durationMs: Int) {
        self.type = type
        self.nodeId = nodeId
        self.durationMs = durationMs
    }
}

public struct TimeWindowAction: Codable, Sendable {
    public let type: String
    /// Stable compiler-authored identity used by transition facts.
    public let nodeId: String?
    public let startTime: String
    public let endTime: String
    public let timezone: String
    public let daysOfWeek: [Int]?
    public let successActions: [JourneyAction]?

    public init(
        type: String = "time_window",
        nodeId: String? = nil,
        startTime: String,
        endTime: String,
        timezone: String,
        daysOfWeek: [Int]? = nil,
        successActions: [JourneyAction]? = nil
    ) {
        self.type = type
        self.nodeId = nodeId
        self.startTime = startTime
        self.endTime = endTime
        self.timezone = timezone
        self.daysOfWeek = daysOfWeek
        self.successActions = successActions
    }
}

public struct WaitUntilAction: Codable, Sendable {
    public let type: String
    /// Stable compiler-authored identity used by transition facts.
    public let nodeId: String?
    public let condition: IREnvelope?
    public let maxTimeMs: Int?
    public let bindResultTo: String?
    /// Actions interpreted when the wait condition succeeds.
    public let successActions: [JourneyAction]?
    /// Actions interpreted when the wait reaches its deadline.
    public let timeoutActions: [JourneyAction]?

    public init(
        type: String = "wait_until",
        nodeId: String? = nil,
        condition: IREnvelope?,
        maxTimeMs: Int? = nil,
        bindResultTo: String? = nil,
        successActions: [JourneyAction]? = nil,
        timeoutActions: [JourneyAction]? = nil
    ) {
        self.type = type
        self.nodeId = nodeId
        self.condition = condition
        self.maxTimeMs = maxTimeMs
        self.bindResultTo = bindResultTo
        self.successActions = successActions
        self.timeoutActions = timeoutActions
    }
}

public struct ConditionAction: Codable, Sendable {
    public let type: String
    /// Stable compiler-authored identity used by transition facts.
    public let nodeId: String?
    public let branches: [ConditionBranch]
    public let defaultActions: [JourneyAction]?

    public init(
        type: String = "condition",
        nodeId: String? = nil,
        branches: [ConditionBranch],
        defaultActions: [JourneyAction]? = nil
    ) {
        self.type = type
        self.nodeId = nodeId
        self.branches = branches
        self.defaultActions = defaultActions
    }
}

public struct ConditionBranch: Codable, Sendable {
    public let id: String
    public let label: String?
    public let condition: IREnvelope?
    public let actions: [JourneyAction]
}

public struct ExperimentAction: Codable, Sendable {
    public let type: String
    /// Stable compiler-authored identity used by transition facts.
    public let nodeId: String?
    public let experimentId: String
    public let variants: [ExperimentVariant]

    public init(
        type: String = "experiment",
        nodeId: String? = nil,
        experimentId: String,
        variants: [ExperimentVariant]
    ) {
        self.type = type
        self.nodeId = nodeId
        self.experimentId = experimentId
        self.variants = variants
    }
}

public struct ExperimentVariant: Codable, Sendable {
    public let id: String
    public let name: String?
    public let percentage: Double
    public let actions: [JourneyAction]
}

public struct SendEventAction: Codable, Sendable {
    public let type: String
    /// Stable compiler-authored identity used by transition facts.
    public let nodeId: String?
    public let eventName: String
    public let properties: [String: AnyCodable]?

    public init(
        type: String = "send_event",
        nodeId: String? = nil,
        eventName: String,
        properties: [String: AnyCodable]? = nil
    ) {
        self.type = type
        self.nodeId = nodeId
        self.eventName = eventName
        self.properties = properties
    }
}

/// A flow action that emits a named journey milestone.
public struct MilestoneAction: Codable, Sendable {
    /// The action discriminator. Defaults to `milestone`.
    public let type: String
    /// Stable compiler-authored identity used by transition facts.
    public let nodeId: String?
    /// Stable identifier used by journey goals and server folding.
    public let milestoneId: String
    /// Optional author-facing label.
    public let label: String?

    /// Creates a milestone action.
    /// - Parameters:
    ///   - type: Action discriminator. Normally `milestone`.
    ///   - milestoneId: Non-empty stable milestone identifier.
    ///   - label: Optional author-facing label.
    public init(
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
    public init(from decoder: Decoder) throws {
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

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(nodeId, forKey: .nodeId)
        try container.encode(milestoneId, forKey: .milestoneId)
        try container.encodeIfPresent(label, forKey: .label)
    }
}

public struct UpdateCustomerAction: Codable, Sendable {
    public let type: String
    /// Stable compiler-authored identity used by transition facts.
    public let nodeId: String?
    public let attributes: [String: AnyCodable]

    public init(
        type: String = "update_customer",
        nodeId: String? = nil,
        attributes: [String: AnyCodable]
    ) {
        self.type = type
        self.nodeId = nodeId
        self.attributes = attributes
    }
}

public struct SetResponseFieldAction: Codable, Sendable {
    public let type: String
    /// Stable compiler-authored identity used by transition facts.
    public let nodeId: String?
    public let responseSchemaId: String
    public let schemaVersion: Int?
    public let key: String
    public let value: AnyCodable

    public init(
        type: String = "set_response_field",
        nodeId: String? = nil,
        responseSchemaId: String,
        schemaVersion: Int? = nil,
        key: String,
        value: AnyCodable
    ) {
        self.type = type
        self.nodeId = nodeId
        self.responseSchemaId = responseSchemaId
        self.schemaVersion = schemaVersion
        self.key = key
        self.value = value
    }
}

public struct SubmitResponseAction: Codable, Sendable {
    public let type: String
    /// Stable compiler-authored identity used by transition facts.
    public let nodeId: String?
    public let responseSchemaId: String
    public let schemaVersion: Int?

    public init(
        type: String = "submit_response",
        nodeId: String? = nil,
        responseSchemaId: String,
        schemaVersion: Int? = nil
    ) {
        self.type = type
        self.nodeId = nodeId
        self.responseSchemaId = responseSchemaId
        self.schemaVersion = schemaVersion
    }
}

public struct RemoteFlowResponseSchema: Codable, Sendable {
    public let responseSchemaId: String
    public let responseSchemaVersionId: String?

    public init(responseSchemaId: String, responseSchemaVersionId: String? = nil) {
        self.responseSchemaId = responseSchemaId
        self.responseSchemaVersionId = responseSchemaVersionId
    }
}

public struct PurchaseAction: Codable, Sendable {
    public let type: String
    /// Stable compiler-authored identity used by transition facts.
    public let nodeId: String?
    public let placementIndex: AnyCodable
    public let productId: AnyCodable
    /// Outcome outlets (Experience Logic 2026-07-04): outcome routing lives at the
    /// purchase site as wired chains. When present, the runner correlates the
    /// async purchase outcome back to this node and runs the matching chain.
    /// Global $purchase_* events still fire for cross-cutting listeners.
    /// Actions interpreted after a completed purchase.
    public let onCompleted: [JourneyAction]?
    /// Actions interpreted after a failed purchase.
    public let onFailed: [JourneyAction]?
    /// Actions interpreted after a cancelled purchase.
    public let onCancelled: [JourneyAction]?

    public init(
        type: String = "purchase",
        nodeId: String? = nil,
        placementIndex: AnyCodable,
        productId: AnyCodable,
        onCompleted: [JourneyAction]? = nil,
        onFailed: [JourneyAction]? = nil,
        onCancelled: [JourneyAction]? = nil
    ) {
        self.type = type
        self.nodeId = nodeId
        self.placementIndex = placementIndex
        self.productId = productId
        self.onCompleted = onCompleted
        self.onFailed = onFailed
        self.onCancelled = onCancelled
    }
}

public struct RestoreAction: Codable, Sendable {
    public let type: String
    /// Stable compiler-authored identity used by transition facts.
    public let nodeId: String?
    /// Actions interpreted when purchases are restored.
    public let onRestored: [JourneyAction]?
    /// Actions interpreted when no restorable purchases exist.
    public let onNoPurchases: [JourneyAction]?
    /// Actions interpreted after a restore failure.
    public let onFailed: [JourneyAction]?

    public init(
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

public struct RequestNotificationsAction: Codable, Sendable {
    public let type: String
    /// Stable compiler-authored identity used by transition facts.
    public let nodeId: String?

    public init(type: String = "request_notifications", nodeId: String? = nil) {
        self.type = type
        self.nodeId = nodeId
    }
}

public struct RequestPermissionAction: Codable, Sendable {
    public let type: String
    /// Stable compiler-authored identity used by transition facts.
    public let nodeId: String?
    public let permissionType: String

    public init(
        type: String = "request_permission",
        nodeId: String? = nil,
        permissionType: String
    ) {
        self.type = type
        self.nodeId = nodeId
        self.permissionType = permissionType
    }
}

public struct RequestTrackingAction: Codable, Sendable {
    public let type: String
    /// Stable compiler-authored identity used by transition facts.
    public let nodeId: String?

    public init(type: String = "request_tracking", nodeId: String? = nil) {
        self.type = type
        self.nodeId = nodeId
    }
}

public struct OpenLinkAction: Codable, Sendable {
    public let type: String
    /// Stable compiler-authored identity used by transition facts.
    public let nodeId: String?
    public let url: AnyCodable
    public let target: String?

    public init(
        type: String = "open_link",
        nodeId: String? = nil,
        url: AnyCodable,
        target: String? = nil
    ) {
        self.type = type
        self.nodeId = nodeId
        self.url = url
        self.target = target
    }
}

public struct DismissAction: Codable, Sendable {
    public let type: String
    /// Stable compiler-authored identity used by transition facts.
    public let nodeId: String?
    public let reason: String?

    public init(
        type: String = "dismiss",
        nodeId: String? = nil,
        reason: String? = nil
    ) {
        self.type = type
        self.nodeId = nodeId
        self.reason = reason
    }
}

public struct CallDelegateAction: Codable, Sendable {
    public let type: String
    /// Stable compiler-authored identity used by transition facts.
    public let nodeId: String?
    public let message: String
    public let payload: AnyCodable?

    public init(
        type: String = "call_delegate",
        nodeId: String? = nil,
        message: String,
        payload: AnyCodable? = nil
    ) {
        self.type = type
        self.nodeId = nodeId
        self.message = message
        self.payload = payload
    }
}

public struct ConnectorAction: Codable, Sendable {
    public let type: String
    /// Stable compiler-authored identity used by transition facts.
    public let nodeId: String?
    public let accountRef: String
    public let toolKey: String
    public let payload: AnyCodable
    public let onSucceeded: [JourneyAction]?
    public let onFailed: [JourneyAction]?
    public let onTimeout: [JourneyAction]?
    public let timeoutMs: Int?

    public init(
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
        self.onSucceeded = onSucceeded
        self.onFailed = onFailed
        self.onTimeout = onTimeout
        self.timeoutMs = timeoutMs
    }
}

public struct GrantEntitlementAction: Codable, Sendable {
    public let type: String
    /// Stable compiler-authored identity used by transition facts.
    public let nodeId: String?
    public let featureId: String
    public let balance: Double?
    public let unlimited: Bool?
    public let onSucceeded: [JourneyAction]?
    public let onFailed: [JourneyAction]?
    public let onTimeout: [JourneyAction]?

    public init(
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

public struct SetViewModelAction: Codable, Sendable {
    public let type: String
    /// Stable compiler-authored identity used by transition facts.
    public let nodeId: String?
    public let path: VmPathRef
    public let value: AnyCodable

    public init(
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

public struct FireTriggerAction: Codable, Sendable {
    public let type: String
    /// Stable compiler-authored identity used by transition facts.
    public let nodeId: String?
    public let path: VmPathRef

    public init(
        type: String = "fire_trigger",
        nodeId: String? = nil,
        path: VmPathRef
    ) {
        self.type = type
        self.nodeId = nodeId
        self.path = path
    }
}

public struct ListInsertAction: Codable, Sendable {
    public let type: String
    /// Stable compiler-authored identity used by transition facts.
    public let nodeId: String?
    public let path: VmPathRef
    public let index: Int?
    public let value: AnyCodable

    public init(
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

public struct ListRemoveAction: Codable, Sendable {
    public let type: String
    /// Stable compiler-authored identity used by transition facts.
    public let nodeId: String?
    public let path: VmPathRef
    public let index: Int

    public init(
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

public struct ListSwapAction: Codable, Sendable {
    public let type: String
    /// Stable compiler-authored identity used by transition facts.
    public let nodeId: String?
    public let path: VmPathRef
    public let indexA: Int
    public let indexB: Int

    public init(
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

public struct ListMoveAction: Codable, Sendable {
    public let type: String
    /// Stable compiler-authored identity used by transition facts.
    public let nodeId: String?
    public let path: VmPathRef
    public let from: Int
    public let to: Int

    public init(
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

public struct ListSetAction: Codable, Sendable {
    public let type: String
    /// Stable compiler-authored identity used by transition facts.
    public let nodeId: String?
    public let path: VmPathRef
    public let index: Int
    public let value: AnyCodable

    public init(
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

public struct ListClearAction: Codable, Sendable {
    public let type: String
    /// Stable compiler-authored identity used by transition facts.
    public let nodeId: String?
    public let path: VmPathRef

    public init(
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
public struct HandoffAction: Codable, Sendable {
    /// The action discriminator. Defaults to `handoff`.
    public let type: String
    /// Stable compiler-authored identity used by transition facts.
    public let nodeId: String
    /// Stable graph edge crossed by this transfer.
    public let edgeId: String
    /// Transfer direction, such as `device_to_server`.
    public let direction: String
    /// Destination execution region.
    public let toRegionId: String
    /// First compiler-authored node in the destination region.
    public let toNodeId: String

    /// Creates an ownership-transfer action.
    public init(
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

public struct ExitAction: Codable, Sendable {
    public let type: String
    /// Stable compiler-authored identity used by transition facts.
    public let nodeId: String?
    public let reason: String?

    public init(type: String = "exit", nodeId: String? = nil, reason: String? = nil) {
        self.type = type
        self.nodeId = nodeId
        self.reason = reason
    }
}
