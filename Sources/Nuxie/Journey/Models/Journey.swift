import Foundation

public enum FlowPendingActionKind: String, Codable, Sendable {
    case delay
    case timeWindow
    case waitUntil
    case remoteRetry
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
    public var currentScreenId: String?
    public var navigationStack: [String]
    public var viewModelSnapshot: FlowViewModelSnapshot?
    public var pendingAction: FlowPendingAction?
    /// Optional (decode-compatible with pre-existing persisted journeys)
    public var pendingPurchaseOutlets: PersistedOutcomeOutlets?
    public var pendingRestoreOutlets: PersistedOutcomeOutlets?

    public init(
        currentScreenId: String? = nil,
        navigationStack: [String] = [],
        viewModelSnapshot: FlowViewModelSnapshot? = nil,
        pendingAction: FlowPendingAction? = nil,
        pendingPurchaseOutlets: PersistedOutcomeOutlets? = nil,
        pendingRestoreOutlets: PersistedOutcomeOutlets? = nil
    ) {
        self.currentScreenId = currentScreenId
        self.navigationStack = navigationStack
        self.viewModelSnapshot = viewModelSnapshot
        self.pendingAction = pendingAction
        self.pendingPurchaseOutlets = pendingPurchaseOutlets
        self.pendingRestoreOutlets = pendingRestoreOutlets
    }
}

/// Represents a user's journey through a campaign flow
// @unchecked Sendable: mutable journey state is confined to the JourneyService
// actor (all mutations happen there); other contexts only read snapshots.
public class Journey: Codable, @unchecked Sendable {
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

    /// Allocate the next monotonic transition epoch without adding a migration-only field.
    public func nextTransitionEpoch() -> Int {
        let epoch = context["_transition_epoch"]?.value as? Int ?? 0
        context["_transition_epoch"] = AnyCodable(epoch + 1)
        updatedAt = Container.shared.dateProvider().now()
        return epoch
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
