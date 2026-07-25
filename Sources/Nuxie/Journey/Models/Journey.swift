import Foundation

public enum FlowPendingActionKind: String, Codable, Sendable {
    case delay
    case timeWindow
    case waitUntil
}

public struct FlowPendingAction: Codable, Sendable {
    public let handlerId: String
    public let screenId: String?
    public let componentId: String?
    public let actionIndex: Int
    public let kind: FlowPendingActionKind
    public let resumeAt: Date?
    public let condition: IREnvelope?
    public let maxTimeMs: Int?
    public let startedAt: Date
    public let resumeActions: [JourneyAction]?

    func withResumeActions(_ actions: [JourneyAction]) -> FlowPendingAction {
        FlowPendingAction(
            handlerId: handlerId,
            screenId: screenId,
            componentId: componentId,
            actionIndex: actionIndex,
            kind: kind,
            resumeAt: resumeAt,
            condition: condition,
            maxTimeMs: maxTimeMs,
            startedAt: startedAt,
            resumeActions: actions
        )
    }
}

/// Purchase/restore outcome-outlet chains, persisted so an app kill between
/// performPurchase and the outcome event doesn't silently drop the wired
/// onCompleted/onFailed actions. Runtime TriggerContext payload is not
/// persisted — only the addressing needed to rebuild a usable context.
public struct PersistedOutcomeOutlets: Codable, Sendable {
    public var first: [JourneyAction]?
    public var second: [JourneyAction]?
    public var third: [JourneyAction]?
    public var screenId: String?
    public var handlerId: String?

    public init(
        first: [JourneyAction]?,
        second: [JourneyAction]?,
        third: [JourneyAction]?,
        screenId: String?,
        handlerId: String?
    ) {
        self.first = first
        self.second = second
        self.third = third
        self.screenId = screenId
        self.handlerId = handlerId
    }
}

public struct FlowJourneyState: Codable, Sendable {
    /// E3 device-region address. Optional for pre-E3 device-only journeys.
    public var regionId: String?
    /// Stable compiler-authored action address within the active region.
    public var currentNodeId: String?
    public var currentScreenId: String?
    public var navigationStack: [String]
    public var viewModelSnapshot: FlowViewModelSnapshot?
    public var pendingAction: FlowPendingAction?
    /// Optional (decode-compatible with pre-existing persisted journeys)
    public var pendingPurchaseOutlets: PersistedOutcomeOutlets?
    public var pendingRestoreOutlets: PersistedOutcomeOutlets?

    public init(
        regionId: String? = nil,
        currentNodeId: String? = nil,
        currentScreenId: String? = nil,
        navigationStack: [String] = [],
        viewModelSnapshot: FlowViewModelSnapshot? = nil,
        pendingAction: FlowPendingAction? = nil,
        pendingPurchaseOutlets: PersistedOutcomeOutlets? = nil,
        pendingRestoreOutlets: PersistedOutcomeOutlets? = nil
    ) {
        self.regionId = regionId
        self.currentNodeId = currentNodeId
        self.currentScreenId = currentScreenId
        self.navigationStack = navigationStack
        self.viewModelSnapshot = viewModelSnapshot
        self.pendingAction = pendingAction
        self.pendingPurchaseOutlets = pendingPurchaseOutlets
        self.pendingRestoreOutlets = pendingRestoreOutlets
    }

    private enum CodingKeys: String, CodingKey {
        case regionId
        case currentNodeId
        case currentScreenId
        case navigationStack
        case viewModelSnapshot
        case pendingAction
        case pendingPurchaseOutlets
        case pendingRestoreOutlets
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        regionId = try container.decodeIfPresent(String.self, forKey: .regionId)
        currentNodeId = try container.decodeIfPresent(String.self, forKey: .currentNodeId)
        currentScreenId = try container.decodeIfPresent(String.self, forKey: .currentScreenId)
        navigationStack = try container.decodeIfPresent([String].self, forKey: .navigationStack) ?? []
        viewModelSnapshot = try container.decodeIfPresent(
            FlowViewModelSnapshot.self,
            forKey: .viewModelSnapshot
        )
        pendingAction = try container.decodeIfPresent(FlowPendingAction.self, forKey: .pendingAction)
        pendingPurchaseOutlets = try container.decodeIfPresent(
            PersistedOutcomeOutlets.self,
            forKey: .pendingPurchaseOutlets
        )
        pendingRestoreOutlets = try container.decodeIfPresent(
            PersistedOutcomeOutlets.self,
            forKey: .pendingRestoreOutlets
        )
    }
}

/// Canonical state transported by mailbox offers, handoff facts, and disk
/// persistence. Version 1 intentionally keeps snapshots open so a server can
/// transfer only the values it owns while the SDK fills campaign defaults.
public struct JourneyStateEnvelope: Codable, Sendable {
    /// Latest state-envelope schema version understood by this SDK.
    public static let currentVersion = 1

    /// Schema version for compatibility checks before applying the envelope.
    public let stateVersion: Int
    /// Interpreter variables transferred between owners.
    public var context: [String: AnyCodable]
    /// Device flow and execution cursor state.
    public var flowState: FlowJourneyState
    /// Immutable campaign settings captured when the journey enrolled.
    public var snapshots: [String: AnyCodable]

    /// Creates a versioned ownership-transfer envelope.
    public init(
        stateVersion: Int = JourneyStateEnvelope.currentVersion,
        context: [String: AnyCodable],
        flowState: FlowJourneyState,
        snapshots: [String: AnyCodable]
    ) {
        self.stateVersion = stateVersion
        self.context = context
        self.flowState = flowState
        self.snapshots = snapshots
    }

    /// Whether this SDK can safely apply the envelope.
    public var isSupported: Bool {
        stateVersion == Self.currentVersion
    }
}

/// Represents a user's journey through a campaign flow
// @unchecked Sendable: mutable journey state is confined to the JourneyService
// actor (all mutations happen there); other contexts only read snapshots.
public class Journey: Codable, @unchecked Sendable {
    /// Version of the canonical state envelope used for this run.
    public var stateVersion: Int

    /// Ownership epoch. It changes only when ownership transfers.
    public var epoch: Int

    /// A superseded local run remains visible but emits no accounting facts.
    public var isGhost: Bool
    /// Unique journey identifier
    public let id: String

    /// Campaign this journey belongs to
    public let campaignId: String
    public let flowId: String

    /// User on this journey
    public let distinctId: String

    /// Current journey status
    public var status: JourneyStatus

    /// Journey-specific context variables (synced to server)
    public var context: [String: AnyCodable]

    /// Experience execution state for local resume
    public var flowState: FlowJourneyState

    /// Timestamps
    public let startedAt: Date
    public var updatedAt: Date
    public var completedAt: Date?

    /// Exit reason if journey ended
    public var exitReason: JourneyExitReason?

    /// For async waits, when to resume

    /// Journey expiration (optional)

    // MARK: - Goal and Conversion Tracking

    /// Snapshot of campaign goal at journey start
    public var goalSnapshot: GoalConfig?

    /// Snapshot of exit policy at journey start
    public var exitPolicySnapshot: ExitPolicy?

    /// Snapshot of campaign trigger at journey start
    public var triggerSnapshot: CampaignTrigger?

    /// Conversion window in seconds
    public var conversionWindow: TimeInterval

    /// Conversion anchor type
    public var conversionAnchor: ConversionAnchor

    /// Timestamp when conversion window starts
    public var conversionAnchorAt: Date

    /// Timestamp when goal was achieved (if applicable)
    public var convertedAt: Date?

    /// Initialize a new journey
    /// - Parameters:
    ///   - id: Optional journey ID (for cross-device resume). If nil, generates a new UUID v7.
    ///   - campaign: The campaign this journey belongs to
    ///   - distinctId: The user identifier
    public init(
        id: String? = nil,
        campaign: Campaign,
        distinctId: String,
        now: Date
    ) {
        self.id = id ?? UUID.v7().uuidString
        self.stateVersion = JourneyStateEnvelope.currentVersion
        self.epoch = 0
        self.isGhost = false
        self.campaignId = campaign.id
        self.flowId = campaign.flowId
        self.distinctId = distinctId
        self.status = .active
        self.context = [:]
        self.flowState = FlowJourneyState()

        self.startedAt = now
        self.updatedAt = now

        // Snapshot goal and exit policy
        self.triggerSnapshot = campaign.trigger
        self.goalSnapshot = campaign.goal
        self.exitPolicySnapshot = campaign.exitPolicy

        // Set conversion window (use default if not specified)
        if let window = campaign.goal?.window {
            self.conversionWindow = window
        } else {
            self.conversionWindow = ConversionWindowDefaults.defaultWindow(for: campaign.campaignType)
        }

        // Set conversion anchor (default to last flow shown)
        self.conversionAnchor = ConversionAnchor(rawValue: campaign.conversionAnchor ?? "") ?? .lastFlowShown
        self.conversionAnchorAt = now
    }

    private enum CodingKeys: String, CodingKey {
        case stateVersion
        case epoch
        case isGhost
        case id
        case campaignId
        case flowId
        case distinctId
        case status
        case context
        case flowState
        case startedAt
        case updatedAt
        case completedAt
        case exitReason
        case goalSnapshot
        case exitPolicySnapshot
        case triggerSnapshot
        case conversionWindow
        case conversionAnchor
        case conversionAnchorAt
        case convertedAt
    }

    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stateVersion = try container.decodeIfPresent(Int.self, forKey: .stateVersion)
            ?? JourneyStateEnvelope.currentVersion
        epoch = try container.decodeIfPresent(Int.self, forKey: .epoch) ?? 0
        isGhost = try container.decodeIfPresent(Bool.self, forKey: .isGhost) ?? false
        id = try container.decode(String.self, forKey: .id)
        campaignId = try container.decode(String.self, forKey: .campaignId)
        flowId = try container.decode(String.self, forKey: .flowId)
        distinctId = try container.decode(String.self, forKey: .distinctId)
        status = try container.decode(JourneyStatus.self, forKey: .status)
        context = try container.decode([String: AnyCodable].self, forKey: .context)
        flowState = try container.decode(FlowJourneyState.self, forKey: .flowState)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        exitReason = try container.decodeIfPresent(JourneyExitReason.self, forKey: .exitReason)
        goalSnapshot = try container.decodeIfPresent(GoalConfig.self, forKey: .goalSnapshot)
        exitPolicySnapshot = try container.decodeIfPresent(ExitPolicy.self, forKey: .exitPolicySnapshot)
        triggerSnapshot = try container.decodeIfPresent(CampaignTrigger.self, forKey: .triggerSnapshot)
        conversionWindow = try container.decode(TimeInterval.self, forKey: .conversionWindow)
        conversionAnchor = try container.decode(ConversionAnchor.self, forKey: .conversionAnchor)
        conversionAnchorAt = try container.decode(Date.self, forKey: .conversionAnchorAt)
        convertedAt = try container.decodeIfPresent(Date.self, forKey: .convertedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(stateVersion, forKey: .stateVersion)
        try container.encode(epoch, forKey: .epoch)
        try container.encode(isGhost, forKey: .isGhost)
        try container.encode(id, forKey: .id)
        try container.encode(campaignId, forKey: .campaignId)
        try container.encode(flowId, forKey: .flowId)
        try container.encode(distinctId, forKey: .distinctId)
        try container.encode(status, forKey: .status)
        try container.encode(context, forKey: .context)
        try container.encode(flowState, forKey: .flowState)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(completedAt, forKey: .completedAt)
        try container.encodeIfPresent(exitReason, forKey: .exitReason)
        try container.encodeIfPresent(goalSnapshot, forKey: .goalSnapshot)
        try container.encodeIfPresent(exitPolicySnapshot, forKey: .exitPolicySnapshot)
        try container.encodeIfPresent(triggerSnapshot, forKey: .triggerSnapshot)
        try container.encode(conversionWindow, forKey: .conversionWindow)
        try container.encode(conversionAnchor, forKey: .conversionAnchor)
        try container.encode(conversionAnchorAt, forKey: .conversionAnchorAt)
        try container.encodeIfPresent(convertedAt, forKey: .convertedAt)
    }

    /// Captures the canonical state required to transfer this journey.
    public func stateEnvelope() -> JourneyStateEnvelope {
        var snapshots: [String: AnyCodable] = [
            "conversionWindow": AnyCodable(conversionWindow),
            "conversionAnchor": AnyCodable(conversionAnchor.rawValue),
            "conversionAnchorAt": AnyCodable(conversionAnchorAt.ISO8601Format()),
        ]
        if let triggerSnapshot, let value = Self.snapshotValue(triggerSnapshot) {
            snapshots["trigger"] = value
        }
        if let goalSnapshot, let value = Self.snapshotValue(goalSnapshot) {
            snapshots["goal"] = value
        }
        if let exitPolicySnapshot, let value = Self.snapshotValue(exitPolicySnapshot) {
            snapshots["exitPolicy"] = value
        }
        return JourneyStateEnvelope(
            stateVersion: stateVersion,
            context: context,
            flowState: flowState,
            snapshots: snapshots
        )
    }

    /// Applies claimed state and advances the local ownership epoch.
    public func applyStateEnvelope(_ envelope: JourneyStateEnvelope, epoch: Int) {
        stateVersion = envelope.stateVersion
        self.epoch = epoch
        context = envelope.context
        flowState = envelope.flowState
        if let trigger: CampaignTrigger = Self.decodeSnapshot(
            envelope.snapshots["trigger"]
        ) {
            triggerSnapshot = trigger
        }
        if let goal: GoalConfig = Self.decodeSnapshot(envelope.snapshots["goal"]) {
            goalSnapshot = goal
        }
        if let exitPolicy: ExitPolicy = Self.decodeSnapshot(
            envelope.snapshots["exitPolicy"]
        ) {
            exitPolicySnapshot = exitPolicy
        }
        if let value = envelope.snapshots["conversionWindow"]?.value as? Double {
            conversionWindow = value
        }
        if let value = envelope.snapshots["conversionAnchor"]?.value as? String,
           let anchor = ConversionAnchor(rawValue: value) {
            conversionAnchor = anchor
        }
        if let value = envelope.snapshots["conversionAnchorAt"]?.value as? String,
           let date = Self.executionDate(value) {
            conversionAnchorAt = date
        }
    }

    private static func snapshotValue<T: Encodable>(_ value: T) -> AnyCodable? {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        return AnyCodable(object)
    }

    private static func decodeSnapshot<T: Decodable>(
        _ value: AnyCodable?
    ) -> T? {
        guard let value,
              JSONSerialization.isValidJSONObject(value.value),
              let data = try? JSONSerialization.data(withJSONObject: value.value) else {
            return nil
        }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func executionDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        return fractional.date(from: value)
            ?? ISO8601DateFormatter().date(from: value)
    }


    /// Mark journey as complete
    public func complete(reason: JourneyExitReason, at now: Date) {
        self.status = .completed
        self.exitReason = reason
        self.completedAt = now
        self.updatedAt = now
    }

    /// Pause journey for async operation (resume time lives on
    /// flowState.pendingAction — the single source of truth)
    public func pause(at now: Date) {
        self.status = .paused
        self.updatedAt = now
    }

    /// Resume journey from pause
    public func resume(at now: Date) {
        self.status = .active
        self.updatedAt = now
    }

    /// Cancel journey
    public func cancel(at now: Date) {
        self.status = .cancelled
        self.exitReason = .cancelled
        self.completedAt = now
        self.updatedAt = now
    }

    public func markFlowShown(at date: Date) {
        guard conversionAnchor == .lastFlowShown else { return }
        conversionAnchorAt = date
        updatedAt = date
    }

    /// Update context value
    public func setContext(_ key: String, value: Any, at now: Date) {
        self.context[key] = AnyCodable(value)
        self.updatedAt = now
    }

    /// Get context value
    public func getContext(_ key: String) -> Any? {
        return context[key]?.value
    }
}

// MARK: - Journey Completion Record

/// Record of a completed journey (for frequency tracking)
public struct JourneyCompletionRecord: Codable, Sendable {
    public let campaignId: String
    public let distinctId: String
    public let journeyId: String
    public let completedAt: Date
    public let exitReason: JourneyExitReason

    public init(journey: Journey, now: Date) {
        self.campaignId = journey.campaignId
        self.distinctId = journey.distinctId
        self.journeyId = journey.id
        self.completedAt = journey.completedAt ?? now
        self.exitReason = journey.exitReason ?? .completed
    }

    /// Test-specific initializer for creating records with custom dates
    public init(campaignId: String, distinctId: String, journeyId: String, completedAt: Date, exitReason: JourneyExitReason) {
        self.campaignId = campaignId
        self.distinctId = distinctId
        self.journeyId = journeyId
        self.completedAt = completedAt
        self.exitReason = exitReason
    }
}
