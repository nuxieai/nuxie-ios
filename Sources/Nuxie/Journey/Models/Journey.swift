import Foundation

enum JourneyPendingActionKind: String, Codable, Sendable {
    case delay
    case timeWindow
    case waitUntil
}

struct JourneyPendingAction: Codable, Sendable {
    public let handlerId: String
    public let screenId: String?
    public let componentId: String?
    public let actionIndex: Int
    public let kind: JourneyPendingActionKind
    public let resumeAt: Date?
    public let condition: IREnvelope?
    public let maxTimeMs: Int?
    public let startedAt: Date
    public let resumeActions: [JourneyAction]?
    let requiresTerminalTransfer: Bool?

    init(
        handlerId: String,
        screenId: String?,
        componentId: String?,
        actionIndex: Int,
        kind: JourneyPendingActionKind,
        resumeAt: Date?,
        condition: IREnvelope?,
        maxTimeMs: Int?,
        startedAt: Date,
        resumeActions: [JourneyAction]?,
        requiresTerminalTransfer: Bool? = nil
    ) {
        self.handlerId = handlerId
        self.screenId = screenId
        self.componentId = componentId
        self.actionIndex = actionIndex
        self.kind = kind
        self.resumeAt = resumeAt
        self.condition = condition
        self.maxTimeMs = maxTimeMs
        self.startedAt = startedAt
        self.resumeActions = resumeActions
        self.requiresTerminalTransfer = requiresTerminalTransfer
    }

    func withResumeActions(_ actions: [JourneyAction]) -> JourneyPendingAction {
        JourneyPendingAction(
            handlerId: handlerId,
            screenId: screenId,
            componentId: componentId,
            actionIndex: actionIndex,
            kind: kind,
            resumeAt: resumeAt,
            condition: condition,
            maxTimeMs: maxTimeMs,
            startedAt: startedAt,
            resumeActions: actions,
            requiresTerminalTransfer: requiresTerminalTransfer
        )
    }
}

/// Purchase/restore outcome-outlet chains, persisted so an app kill between
/// performPurchase and the outcome event doesn't silently drop the wired
/// onCompleted/onFailed actions. Runtime TriggerContext payload is not
/// persisted — only the addressing needed to rebuild a usable context.
struct PersistedOutcomeOutlets: Codable, Sendable {
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

/// Execution plane that produced a journey state checkpoint.
enum JourneyPlane: String, Codable, Sendable {
    /// State captured by the device SDK.
    case device
    /// State captured by server-side journey execution.
    case server
}

/// Human-visible checkpoint metadata retained after a takeover claim.
struct JourneyResumePoint: Codable, Equatable, Sendable {
    /// Stable compiler-authored node where the checkpoint resumes.
    public let nodeId: String?
    /// Time at which the source device captured the checkpoint.
    public let checkpointAt: Date?

    /// Creates metadata for describing a claimed checkpoint.
    ///
    /// - Parameters:
    ///   - nodeId: Stable compiler-authored node where execution resumes.
    ///   - checkpointAt: Time at which the source device captured the state.
    public init(nodeId: String?, checkpointAt: Date?) {
        self.nodeId = nodeId
        self.checkpointAt = checkpointAt
    }
}

struct JourneyExecutionState: Codable, Sendable {
    /// Execution plane that produced this state. Legacy persisted device state
    /// without the discriminator decodes as `.device`.
    public var plane: JourneyPlane
    /// Device-region address. Optional for legacy device-only journeys.
    public var regionId: String?
    /// Stable compiler-authored action address within the active region.
    public var currentNodeId: String?
    public var currentScreenId: String?
    public var navigationStack: [String]
    public var viewModelSnapshot: ExperienceViewModelSnapshot?
    public var pendingAction: JourneyPendingAction?
    /// Optional (decode-compatible with pre-existing persisted journeys)
    public var pendingPurchaseOutlets: PersistedOutcomeOutlets?
    public var pendingRestoreOutlets: PersistedOutcomeOutlets?

    public init(
        plane: JourneyPlane = .device,
        regionId: String? = nil,
        currentNodeId: String? = nil,
        currentScreenId: String? = nil,
        navigationStack: [String] = [],
        viewModelSnapshot: ExperienceViewModelSnapshot? = nil,
        pendingAction: JourneyPendingAction? = nil,
        pendingPurchaseOutlets: PersistedOutcomeOutlets? = nil,
        pendingRestoreOutlets: PersistedOutcomeOutlets? = nil
    ) {
        self.plane = plane
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
        case plane
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
        plane = try container.decodeIfPresent(JourneyPlane.self, forKey: .plane)
            ?? .device
        regionId = try container.decodeIfPresent(String.self, forKey: .regionId)
        currentNodeId = try container.decodeIfPresent(String.self, forKey: .currentNodeId)
        currentScreenId = try container.decodeIfPresent(String.self, forKey: .currentScreenId)
        navigationStack = try container.decodeIfPresent([String].self, forKey: .navigationStack) ?? []
        viewModelSnapshot = try container.decodeIfPresent(
            ExperienceViewModelSnapshot.self,
            forKey: .viewModelSnapshot
        )
        pendingAction = try container.decodeIfPresent(JourneyPendingAction.self, forKey: .pendingAction)
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
/// transfer only the values it owns while the SDK fills experience defaults.
struct JourneyStateEnvelope: Codable, Sendable {
    /// Latest state-envelope schema version understood by this SDK.
    public static let currentVersion = 1

    /// Schema version for compatibility checks before applying the envelope.
    public let stateVersion: Int
    /// Interpreter variables transferred between owners.
    public var context: [String: AnyCodable]
    /// Device experience and execution cursor state.
    public var executionState: JourneyExecutionState
    /// Immutable experience settings captured when the journey enrolled.
    public var snapshots: [String: AnyCodable]

    /// Creates a versioned ownership-transfer envelope.
    public init(
        stateVersion: Int = JourneyStateEnvelope.currentVersion,
        context: [String: AnyCodable],
        executionState: JourneyExecutionState,
        snapshots: [String: AnyCodable]
    ) {
        self.stateVersion = stateVersion
        self.context = context
        self.executionState = executionState
        self.snapshots = snapshots
    }

    /// Whether this SDK can safely apply the envelope.
    public var isSupported: Bool {
        stateVersion == Self.currentVersion
    }

    private enum CodingKeys: String, CodingKey {
        case stateVersion
        case context
        case executionState
        case legacyExecutionState = "flowState"
        case snapshots
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stateVersion = try container.decode(Int.self, forKey: .stateVersion)
        context = try container.decode(
            [String: AnyCodable].self,
            forKey: .context
        )
        executionState = if let canonical = try container.decodeIfPresent(
            JourneyExecutionState.self,
            forKey: .executionState
        ) {
            canonical
        } else {
            try container.decode(
                JourneyExecutionState.self,
                forKey: .legacyExecutionState
            )
        }
        snapshots = try container.decode(
            [String: AnyCodable].self,
            forKey: .snapshots
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(stateVersion, forKey: .stateVersion)
        try container.encode(context, forKey: .context)
        try container.encode(executionState, forKey: .executionState)
        try container.encode(snapshots, forKey: .snapshots)
    }
}

/// A coherent, immutable-in-transit view of one journey state version.
///
/// Codable persistence, goal evaluation, event payload construction, and
/// cross-actor communication all use this value. Mutable state lives only in
/// `JourneyStateOwner` below.
struct JourneySnapshot: Codable, Sendable {
    /// Version of the canonical state envelope used for this run.
    public var stateVersion: Int

    /// Ownership epoch. It changes only when ownership transfers.
    public var epoch: Int

    /// A superseded local run remains visible but emits no accounting facts.
    public var isGhost: Bool
    /// Unique journey identifier
    public let id: String

    /// Stable experience definition identifier.
    public let experienceId: String
    /// Exact published experience version pinned for this journey.
    public let experienceVersion: String

    /// User on this journey
    public let distinctId: String

    /// Current journey status
    public var status: JourneyStatus

    /// Journey-specific context variables (synced to server)
    public var context: [String: AnyCodable]

    /// Experience execution state for local resume
    public var executionState: JourneyExecutionState
    /// Optional human-visible cursor and checkpoint age for a takeover.
    public var resumePoint: JourneyResumePoint?

    /// Timestamps
    public let startedAt: Date
    public var updatedAt: Date
    public var completedAt: Date?

    /// Exit reason if journey ended
    public var exitReason: JourneyExitReason?

    /// For async waits, when to resume

    /// Journey expiration (optional)

    // MARK: - Goal and Conversion Tracking

    /// Snapshot of experience goal at journey start
    public var goalSnapshot: GoalConfig?

    /// Snapshot of exit policy at journey start
    public var exitPolicySnapshot: ExitPolicy?

    /// Snapshot of experience trigger at journey start
    public var triggerSnapshot: ExperienceTrigger?

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
    ///   - experience: The experience this journey belongs to
    ///   - distinctId: The user identifier
    public init(
        id: String? = nil,
        experience: Experience,
        distinctId: String,
        now: Date
    ) {
        self.id = id ?? UUID.v7().uuidString
        self.stateVersion = JourneyStateEnvelope.currentVersion
        self.epoch = 0
        self.isGhost = false
        self.experienceId = experience.id
        self.experienceVersion = experience.versionId
        self.distinctId = distinctId
        self.status = .active
        self.context = [:]
        self.executionState = JourneyExecutionState()
        self.resumePoint = nil

        self.startedAt = now
        self.updatedAt = now

        // Snapshot goal and exit policy
        self.triggerSnapshot = experience.trigger
        self.goalSnapshot = experience.goal
        self.exitPolicySnapshot = experience.exitPolicy

        // Set conversion window (use default if not specified)
        if let window = experience.goal?.window {
            self.conversionWindow = window
        } else {
            self.conversionWindow = ConversionWindowDefaults.defaultWindow(for: experience.experienceType)
        }

        // Set conversion anchor (default to last experience shown)
        self.conversionAnchor = ConversionAnchor(rawValue: experience.conversionAnchor ?? "") ?? .lastExperienceShown
        self.conversionAnchorAt = now
    }

    private enum CodingKeys: String, CodingKey {
        case stateVersion
        case epoch
        case isGhost
        case id
        case experienceId
        case experienceVersion
        case distinctId
        case status
        case context
        case executionState
        case resumePoint
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

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stateVersion = try container.decodeIfPresent(Int.self, forKey: .stateVersion)
            ?? JourneyStateEnvelope.currentVersion
        epoch = try container.decodeIfPresent(Int.self, forKey: .epoch) ?? 0
        isGhost = try container.decodeIfPresent(Bool.self, forKey: .isGhost) ?? false
        id = try container.decode(String.self, forKey: .id)
        experienceId = try container.decode(String.self, forKey: .experienceId)
        experienceVersion = try container.decode(String.self, forKey: .experienceVersion)
        distinctId = try container.decode(String.self, forKey: .distinctId)
        status = try container.decode(JourneyStatus.self, forKey: .status)
        context = try container.decode([String: AnyCodable].self, forKey: .context)
        executionState = try container.decode(JourneyExecutionState.self, forKey: .executionState)
        resumePoint = try container.decodeIfPresent(
            JourneyResumePoint.self,
            forKey: .resumePoint
        )
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        exitReason = try container.decodeIfPresent(JourneyExitReason.self, forKey: .exitReason)
        goalSnapshot = try container.decodeIfPresent(GoalConfig.self, forKey: .goalSnapshot)
        exitPolicySnapshot = try container.decodeIfPresent(ExitPolicy.self, forKey: .exitPolicySnapshot)
        triggerSnapshot = try container.decodeIfPresent(ExperienceTrigger.self, forKey: .triggerSnapshot)
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
        try container.encode(experienceId, forKey: .experienceId)
        try container.encode(experienceVersion, forKey: .experienceVersion)
        try container.encode(distinctId, forKey: .distinctId)
        try container.encode(status, forKey: .status)
        try container.encode(context, forKey: .context)
        try container.encode(executionState, forKey: .executionState)
        try container.encodeIfPresent(resumePoint, forKey: .resumePoint)
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
            executionState: executionState,
            snapshots: snapshots
        )
    }

    /// Applies claimed state and advances the local ownership epoch.
    public mutating func applyStateEnvelope(_ envelope: JourneyStateEnvelope, epoch: Int) {
        stateVersion = envelope.stateVersion
        self.epoch = epoch
        context = envelope.context
        executionState = envelope.executionState
        if let trigger: ExperienceTrigger = Self.decodeSnapshot(
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
    public mutating func complete(reason: JourneyExitReason, at now: Date) {
        self.status = .completed
        self.exitReason = reason
        self.completedAt = now
        self.updatedAt = now
    }

    /// Pause journey for async operation (resume time lives on
    /// executionState.pendingAction — the single source of truth)
    public mutating func pause(at now: Date) {
        self.status = .paused
        self.updatedAt = now
    }

    /// Resume journey from pause
    public mutating func resume(at now: Date) {
        self.status = .active
        self.updatedAt = now
    }

    /// Cancel journey
    public mutating func cancel(at now: Date) {
        self.status = .cancelled
        self.exitReason = .cancelled
        self.completedAt = now
        self.updatedAt = now
    }

    public mutating func markExperienceShown(at date: Date) {
        guard conversionAnchor == .lastExperienceShown else { return }
        conversionAnchorAt = date
        updatedAt = date
    }

    /// Update context value
    public mutating func setContext(_ key: String, value: Any, at now: Date) {
        self.context[key] = AnyCodable(value)
        self.updatedAt = now
    }

    /// Get context value
    public func getContext(_ key: String) -> Any? {
        return context[key]?.value
    }
}

/// Sendable journey identity plus the only handle to its mutable state owner.
final class Journey: Sendable {
    public let id: String
    public let experienceId: String
    public let experienceVersion: String
    public let distinctId: String
    public let startedAt: Date

    private let stateOwner: JourneyStateOwner

    public init(
        id: String? = nil,
        experience: Experience,
        distinctId: String,
        now: Date
    ) {
        let initial = JourneySnapshot(
            id: id,
            experience: experience,
            distinctId: distinctId,
            now: now
        )
        self.id = initial.id
        self.experienceId = initial.experienceId
        self.experienceVersion = initial.experienceVersion
        self.distinctId = initial.distinctId
        self.startedAt = initial.startedAt
        stateOwner = JourneyStateOwner(initial)
    }

    public init(snapshot: JourneySnapshot) {
        id = snapshot.id
        experienceId = snapshot.experienceId
        experienceVersion = snapshot.experienceVersion
        distinctId = snapshot.distinctId
        startedAt = snapshot.startedAt
        stateOwner = JourneyStateOwner(snapshot)
    }

    public func snapshot() async -> JourneySnapshot {
        await stateOwner.snapshot()
    }

    @discardableResult
    func update<T: Sendable>(
        _ body: @Sendable (inout JourneySnapshot) -> T
    ) async -> T {
        await stateOwner.update(body)
    }

    public func stateEnvelope() async -> JourneyStateEnvelope {
        await snapshot().stateEnvelope()
    }

    public func applyStateEnvelope(_ envelope: JourneyStateEnvelope, epoch: Int) async {
        await update { state in
            state.applyStateEnvelope(envelope, epoch: epoch)
        }
    }

    public func complete(reason: JourneyExitReason, at now: Date) async {
        await update { $0.complete(reason: reason, at: now) }
    }

    public func pause(at now: Date) async {
        await update { $0.pause(at: now) }
    }

    public func resume(at now: Date) async {
        await update { $0.resume(at: now) }
    }

    public func cancel(at now: Date) async {
        await update { $0.cancel(at: now) }
    }

    public func markExperienceShown(at date: Date) async {
        await update { $0.markExperienceShown(at: date) }
    }

    public func setContext(_ key: String, value: AnyCodable, at now: Date) async {
        await update { state in
            state.context[key] = value
            state.updatedAt = now
        }
    }

    public func getContext(_ key: String) async -> AnyCodable? {
        await snapshot().context[key]
    }
}

private actor JourneyStateOwner {
    private var value: JourneySnapshot

    init(_ value: JourneySnapshot) {
        self.value = value
    }

    func snapshot() -> JourneySnapshot {
        value
    }

    func update<T: Sendable>(
        _ body: @Sendable (inout JourneySnapshot) -> T
    ) -> T {
        body(&value)
    }
}

// MARK: - Journey Completion Record

/// Record of a completed journey (for frequency tracking)
struct JourneyCompletionRecord: Codable, Sendable {
    /// Stable experience definition identifier used for frequency tracking.
    public let experienceId: String
    public let distinctId: String
    public let journeyId: String
    public let completedAt: Date
    public let exitReason: JourneyExitReason

    public init(journey: JourneySnapshot, now: Date) {
        self.experienceId = journey.experienceId
        self.distinctId = journey.distinctId
        self.journeyId = journey.id
        self.completedAt = journey.completedAt ?? now
        self.exitReason = journey.exitReason ?? .completed
    }

    /// Creates a completion record with explicit values.
    ///
    /// - Parameters:
    ///   - experienceId: Stable experience definition identifier.
    ///   - distinctId: User identifier.
    ///   - journeyId: Stable journey identifier.
    ///   - completedAt: Completion timestamp.
    ///   - exitReason: Reason execution ended.
    public init(
        experienceId: String,
        distinctId: String,
        journeyId: String,
        completedAt: Date,
        exitReason: JourneyExitReason
    ) {
        self.experienceId = experienceId
        self.distinctId = distinctId
        self.journeyId = journeyId
        self.completedAt = completedAt
        self.exitReason = exitReason
    }
}
