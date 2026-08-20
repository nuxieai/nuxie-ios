import Foundation

enum JourneyPendingActionKind: String, Codable, Sendable {
    case delay
    case timeWindow
    case waitUntil
}

/// A context-preserving request stored behind a pending action. Keeping
/// requests separate avoids flattening actions from different handlers or
/// outlet roots into one context when actor reentrancy interrupts execution.
struct JourneyContinuationRequest: Codable, Sendable {
    let rootId: String
    let isPriority: Bool
    let actions: [JourneyAction]
    /// SDK-owned RFC 6901 paths into the admitted signed route revision.
    /// Kept parallel to `actions` so flattening a durable continuation cannot
    /// change consequential-action identity.
    let actionPaths: [String]?
    let hostId: String?
    let screenId: String?
    let componentId: String?
    let handlerId: String?
    let instanceId: String?
    let payload: [String: AnyCodable]?
    let requiresTerminalTransfer: Bool
    let startIndex: Int
    let usesPendingResumeContext: Bool
    let resume: JourneyContinuationResume?
    let screenRouteAdmissionId: String?

    init(
        rootId: String,
        isPriority: Bool,
        actions: [JourneyAction],
        actionPaths: [String]? = nil,
        hostId: String?,
        screenId: String?,
        componentId: String?,
        handlerId: String?,
        instanceId: String?,
        payload: [String: AnyCodable]?,
        requiresTerminalTransfer: Bool,
        startIndex: Int,
        usesPendingResumeContext: Bool,
        resume: JourneyContinuationResume?,
        screenRouteAdmissionId: String? = nil
    ) {
        self.rootId = rootId
        self.isPriority = isPriority
        self.actions = actions
        self.actionPaths = actionPaths
        self.hostId = hostId
        self.screenId = screenId
        self.componentId = componentId
        self.handlerId = handlerId
        self.instanceId = instanceId
        self.payload = payload
        self.requiresTerminalTransfer = requiresTerminalTransfer
        self.startIndex = startIndex
        self.usesPendingResumeContext = usesPendingResumeContext
        self.resume = resume
        self.screenRouteAdmissionId = screenRouteAdmissionId
    }
}

struct JourneyContinuationEvent: Codable, Sendable {
    let id: String
    let name: String
    let distinctId: String
    let properties: [String: AnyCodable]
    let timestamp: Date
}

enum JourneyContinuationResumeReason: String, Codable, Sendable {
    case start
    case timer
    case event
    case segmentChange
}

struct JourneyContinuationResume: Codable, Sendable {
    let pending: JourneyPendingAction
    let reason: JourneyContinuationResumeReason
    let event: JourneyContinuationEvent?
}

/// Durable interpreter work that follows a pending action. The indirect
/// representation permits one pause to preserve an already-produced pause
/// below it without replaying the side-effecting action that created it.
struct JourneyContinuationStep: Codable, Sendable {
    let rootId: String
    let operation: JourneyContinuationOperation
}

indirect enum JourneyContinuationOperation: Codable, Sendable {
    case request(JourneyContinuationRequest)
    case pending(JourneyPendingAction)
    case transfer(HandoffAction)
    case exit(JourneyExitReason)
}

struct JourneyPendingAction: Codable, Sendable {
    public let handlerId: String
    let hostId: String?
    public let screenId: String?
    public let componentId: String?
    public let actionIndex: Int
    public let kind: JourneyPendingActionKind
    public let resumeAt: Date?
    public let condition: IREnvelope?
    public let journeyCondition: JourneyCondition?
    public let journeyWaitTrigger: JourneyWaitTrigger?
    public let maxTimeMs: Int?
    public let startedAt: Date
    public let responseVersion: UInt64?
    let allowsResponseVersionRefresh: Bool?
    public let resumeActions: [JourneyAction]?
    let requiresTerminalTransfer: Bool?
    let continuation: [JourneyContinuationStep]?

    init(
        handlerId: String,
        hostId: String? = nil,
        screenId: String?,
        componentId: String?,
        actionIndex: Int,
        kind: JourneyPendingActionKind,
        resumeAt: Date?,
        condition: IREnvelope?,
        journeyCondition: JourneyCondition? = nil,
        journeyWaitTrigger: JourneyWaitTrigger? = nil,
        maxTimeMs: Int?,
        startedAt: Date,
        responseVersion: UInt64? = nil,
        allowsResponseVersionRefresh: Bool? = nil,
        resumeActions: [JourneyAction]?,
        requiresTerminalTransfer: Bool? = nil,
        continuation: [JourneyContinuationStep]? = nil
    ) {
        self.handlerId = handlerId
        self.hostId = hostId
        self.screenId = screenId
        self.componentId = componentId
        self.actionIndex = actionIndex
        self.kind = kind
        self.resumeAt = resumeAt
        self.condition = condition
        self.journeyCondition = journeyCondition
        self.journeyWaitTrigger = journeyWaitTrigger
        self.maxTimeMs = maxTimeMs
        self.startedAt = startedAt
        self.responseVersion = responseVersion
        self.allowsResponseVersionRefresh = allowsResponseVersionRefresh
        self.resumeActions = resumeActions
        self.requiresTerminalTransfer = requiresTerminalTransfer
        self.continuation = continuation
    }

    func withResumeActions(_ actions: [JourneyAction]) -> JourneyPendingAction {
        JourneyPendingAction(
            handlerId: handlerId,
            hostId: hostId,
            screenId: screenId,
            componentId: componentId,
            actionIndex: actionIndex,
            kind: kind,
            resumeAt: resumeAt,
            condition: condition,
            journeyCondition: journeyCondition,
            journeyWaitTrigger: journeyWaitTrigger,
            maxTimeMs: maxTimeMs,
            startedAt: startedAt,
            responseVersion: responseVersion,
            allowsResponseVersionRefresh: allowsResponseVersionRefresh,
            resumeActions: actions,
            requiresTerminalTransfer: requiresTerminalTransfer,
            continuation: continuation
        )
    }

    func withContinuation(_ continuation: [JourneyContinuationStep]) -> JourneyPendingAction {
        JourneyPendingAction(
            handlerId: handlerId,
            hostId: hostId,
            screenId: screenId,
            componentId: componentId,
            actionIndex: actionIndex,
            kind: kind,
            resumeAt: resumeAt,
            condition: condition,
            journeyCondition: journeyCondition,
            journeyWaitTrigger: journeyWaitTrigger,
            maxTimeMs: maxTimeMs,
            startedAt: startedAt,
            responseVersion: responseVersion,
            allowsResponseVersionRefresh: allowsResponseVersionRefresh,
            resumeActions: resumeActions,
            requiresTerminalTransfer: requiresTerminalTransfer,
            continuation: continuation
        )
    }

    func hasResponseSnapshotConflict(currentVersion: UInt64?) -> Bool {
        allowsResponseVersionRefresh != true && responseVersion != currentVersion
    }
}

/// Exact renderer commit selected and persisted before artifact or window work.
struct JourneyPendingPresentation: Codable, Sendable {
    let experienceId: String
    let experienceVersionId: String
    let releaseID: AuthenticatedExperienceReleaseID?
    let presentationStyle: ExperienceBehaviorPresentationStyle
    let shell: ExperienceShellContract?
    let screenId: String
    let transition: AnyCodable?
    let continuation: [JourneyContinuationStep]

    init(
        experienceId: String,
        experienceVersionId: String,
        releaseID: AuthenticatedExperienceReleaseID?,
        presentationStyle: ExperienceBehaviorPresentationStyle,
        shell: ExperienceShellContract? = nil,
        screenId: String,
        transition: AnyCodable?,
        continuation: [JourneyContinuationStep]
    ) {
        self.experienceId = experienceId
        self.experienceVersionId = experienceVersionId
        self.releaseID = releaseID
        self.presentationStyle = presentationStyle
        self.shell = shell
        self.screenId = screenId
        self.transition = transition
        self.continuation = continuation
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
    var hostId: String?
    var firstProgramPath: String?
    var secondProgramPath: String?
    var thirdProgramPath: String?
    var screenRouteAdmissionId: String?

    public init(
        first: [JourneyAction]?,
        second: [JourneyAction]?,
        third: [JourneyAction]?,
        screenId: String?,
        handlerId: String?,
        hostId: String? = nil,
        firstProgramPath: String? = nil,
        secondProgramPath: String? = nil,
        thirdProgramPath: String? = nil,
        screenRouteAdmissionId: String? = nil
    ) {
        self.first = first
        self.second = second
        self.third = third
        self.screenId = screenId
        self.handlerId = handlerId
        self.hostId = hostId
        self.firstProgramPath = firstProgramPath
        self.secondProgramPath = secondProgramPath
        self.thirdProgramPath = thirdProgramPath
        self.screenRouteAdmissionId = screenRouteAdmissionId
    }
}

enum JourneyScreenEventPhase: String, Codable, Sendable {
    case admitted
    case routeExecuting
    case routeProcessed
    case finished
    case dropped
}

enum JourneyScreenAuthoredEventPhase: String, Codable, Sendable {
    case intent
    case prepared
    case routingClaimed
    case routed
    case dropped
}

struct JourneyScreenAuthoredEvent: Codable, Sendable {
    let id: String
    let name: String
    let properties: [String: AnyCodable]
    let occurredAt: Date
    let hostId: String?
    let screenId: String?
    let handlerId: String?
    var phase: JourneyScreenAuthoredEventPhase = .intent
    var preparedId: String?
    var preparedName: String?
    var preparedDistinctId: String?
    var preparedProperties: [String: AnyCodable]?
    var preparedOccurredAt: Date?
}

struct JourneyScreenEventRecord: Codable, Sendable {
    let sourceEvent: ScreenCustomerEvent
    let preparedId: String?
    let preparedName: String?
    let preparedDistinctId: String?
    let preparedProperties: [String: AnyCodable]?
    let preparedOccurredAt: Date?
    let localRoute: ScreenLocalRouteDisposition
    let excludedExperienceId: String?
    var phase: JourneyScreenEventPhase
    var routeContinuation: [JourneyContinuationStep]?
    var routeContinuationAuthoredEventId: String?
    var claimedEffectPaths: [String]
    var pendingAuthoredEvents: [JourneyScreenAuthoredEvent]

    private enum CodingKeys: String, CodingKey {
        case sourceEvent, preparedId, preparedName, preparedDistinctId
        case preparedProperties, preparedOccurredAt, localRoute
        case excludedExperienceId, phase, routeContinuation
        case routeContinuationAuthoredEventId
        case claimedEffectPaths, pendingAuthoredEvents
    }

    init(
        sourceEvent: ScreenCustomerEvent,
        preparedId: String?,
        preparedName: String?,
        preparedDistinctId: String?,
        preparedProperties: [String: AnyCodable]?,
        preparedOccurredAt: Date?,
        localRoute: ScreenLocalRouteDisposition,
        excludedExperienceId: String?,
        phase: JourneyScreenEventPhase,
        routeContinuation: [JourneyContinuationStep]?,
        claimedEffectPaths: [String],
        pendingAuthoredEvents: [JourneyScreenAuthoredEvent],
        routeContinuationAuthoredEventId: String? = nil
    ) {
        self.sourceEvent = sourceEvent
        self.preparedId = preparedId
        self.preparedName = preparedName
        self.preparedDistinctId = preparedDistinctId
        self.preparedProperties = preparedProperties
        self.preparedOccurredAt = preparedOccurredAt
        self.localRoute = localRoute
        self.excludedExperienceId = excludedExperienceId
        self.phase = phase
        self.routeContinuation = routeContinuation
        self.routeContinuationAuthoredEventId = routeContinuationAuthoredEventId
        self.claimedEffectPaths = claimedEffectPaths
        self.pendingAuthoredEvents = pendingAuthoredEvents
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceEvent = try container.decode(ScreenCustomerEvent.self, forKey: .sourceEvent)
        preparedId = try container.decodeIfPresent(String.self, forKey: .preparedId)
        preparedName = try container.decodeIfPresent(String.self, forKey: .preparedName)
        preparedDistinctId = try container.decodeIfPresent(String.self, forKey: .preparedDistinctId)
        preparedProperties = try container.decodeIfPresent(
            [String: AnyCodable].self,
            forKey: .preparedProperties
        )
        preparedOccurredAt = try container.decodeIfPresent(Date.self, forKey: .preparedOccurredAt)
        localRoute = try container.decode(ScreenLocalRouteDisposition.self, forKey: .localRoute)
        excludedExperienceId = try container.decodeIfPresent(String.self, forKey: .excludedExperienceId)
        phase = try container.decode(JourneyScreenEventPhase.self, forKey: .phase)
        routeContinuation = try container.decodeIfPresent(
            [JourneyContinuationStep].self,
            forKey: .routeContinuation
        )
        routeContinuationAuthoredEventId = try container.decodeIfPresent(
            String.self,
            forKey: .routeContinuationAuthoredEventId
        )
        claimedEffectPaths = try container.decodeIfPresent(
            [String].self,
            forKey: .claimedEffectPaths
        ) ?? []
        pendingAuthoredEvents = try container.decodeIfPresent(
            [JourneyScreenAuthoredEvent].self,
            forKey: .pendingAuthoredEvents
        ) ?? []
    }
}

struct JourneyScreenBatchReceipt: Codable, Sendable {
    let invocationId: String
    let result: ScreenEventRouterDrainResult
}

struct JourneyScreenRoutingState: Codable, Sendable {
    var nextBatchSequence: UInt64 = 0
    var nextEmissionSequence: UInt64 = 0
    var lastProcessedBatchSequence: UInt64?
    var pendingBatches: [String: ScreenEmissionBatch] = [:]
    var batchReceipts: [String: JourneyScreenBatchReceipt] = [:]
    var eventRecords: [String: JourneyScreenEventRecord] = [:]
    var recentEventIds: [String] = []

    private enum CodingKeys: String, CodingKey {
        case nextBatchSequence, nextEmissionSequence, lastProcessedBatchSequence
        case pendingBatches, batchReceipts, eventRecords, recentEventIds
    }

    init(
        nextBatchSequence: UInt64 = 0,
        nextEmissionSequence: UInt64 = 0,
        lastProcessedBatchSequence: UInt64? = nil,
        pendingBatches: [String: ScreenEmissionBatch] = [:],
        batchReceipts: [String: JourneyScreenBatchReceipt] = [:],
        eventRecords: [String: JourneyScreenEventRecord] = [:],
        recentEventIds: [String] = []
    ) {
        self.nextBatchSequence = nextBatchSequence
        self.nextEmissionSequence = nextEmissionSequence
        self.lastProcessedBatchSequence = lastProcessedBatchSequence
        self.pendingBatches = pendingBatches
        self.batchReceipts = batchReceipts
        self.eventRecords = eventRecords
        self.recentEventIds = recentEventIds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nextBatchSequence = try container.decodeIfPresent(
            UInt64.self,
            forKey: .nextBatchSequence
        ) ?? 0
        nextEmissionSequence = try container.decodeIfPresent(
            UInt64.self,
            forKey: .nextEmissionSequence
        ) ?? 0
        lastProcessedBatchSequence = try container.decodeIfPresent(
            UInt64.self,
            forKey: .lastProcessedBatchSequence
        )
        pendingBatches = try container.decodeIfPresent(
            [String: ScreenEmissionBatch].self,
            forKey: .pendingBatches
        ) ?? [:]
        batchReceipts = try container.decodeIfPresent(
            [String: JourneyScreenBatchReceipt].self,
            forKey: .batchReceipts
        ) ?? [:]
        eventRecords = try container.decodeIfPresent(
            [String: JourneyScreenEventRecord].self,
            forKey: .eventRecords
        ) ?? [:]
        recentEventIds = try container.decodeIfPresent(
            [String].self,
            forKey: .recentEventIds
        ) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(nextBatchSequence, forKey: .nextBatchSequence)
        try container.encode(nextEmissionSequence, forKey: .nextEmissionSequence)
        try container.encodeIfPresent(
            lastProcessedBatchSequence,
            forKey: .lastProcessedBatchSequence
        )
        try container.encode(pendingBatches, forKey: .pendingBatches)
        try container.encode(batchReceipts, forKey: .batchReceipts)
        try container.encode(eventRecords, forKey: .eventRecords)
        if !recentEventIds.isEmpty {
            try container.encode(recentEventIds, forKey: .recentEventIds)
        }
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
    /// Execution plane that produced this state.
    public var plane: JourneyPlane
    /// Signed execution-plan identity and route revision selected for this run.
    public var planId: String?
    public var routeRevisionSHA256: String?
    /// Device-region address when execution is inside a compiled region.
    public var regionId: String?
    /// Stable compiler-authored action address within the active region.
    public var currentNodeId: String?
    /// RFC 6901 route cursor persisted across ownership handoff and restart.
    public var cursorProgramPath: String?
    public var cursorActionIndex: Int?
    public var currentScreenId: String?
    /// Durable run authority used to reject work from a terminated lifecycle.
    var lifecycleGeneration: UInt64
    /// Advances at each accepted presentation transition.
    var presentationEpoch: UInt64
    /// Durable screen-emission admission, recovery, and deduplication state.
    var screenRouting: JourneyScreenRoutingState
    public var navigationStack: [String]
    public var viewModelSnapshot: ExperienceViewModelSnapshot?
    public var pendingAction: JourneyPendingAction?
    var prePresentationContinuation: [JourneyContinuationStep]?
    public var pendingPresentation: JourneyPendingPresentation?
    /// Exact authenticated presentation currently owned by the renderer.
    var currentPresentation: JourneyPendingPresentation?
    var postPresentationContinuation: [JourneyContinuationStep]?
    public var pendingPurchaseOutlets: PersistedOutcomeOutlets?
    public var pendingRestoreOutlets: PersistedOutcomeOutlets?

    public init(
        plane: JourneyPlane = .device,
        planId: String? = nil,
        routeRevisionSHA256: String? = nil,
        regionId: String? = nil,
        currentNodeId: String? = nil,
        cursorProgramPath: String? = nil,
        cursorActionIndex: Int? = nil,
        currentScreenId: String? = nil,
        lifecycleGeneration: UInt64 = 1,
        presentationEpoch: UInt64 = 0,
        screenRouting: JourneyScreenRoutingState = JourneyScreenRoutingState(),
        navigationStack: [String] = [],
        viewModelSnapshot: ExperienceViewModelSnapshot? = nil,
        pendingAction: JourneyPendingAction? = nil,
        prePresentationContinuation: [JourneyContinuationStep]? = nil,
        pendingPresentation: JourneyPendingPresentation? = nil,
        currentPresentation: JourneyPendingPresentation? = nil,
        postPresentationContinuation: [JourneyContinuationStep]? = nil,
        pendingPurchaseOutlets: PersistedOutcomeOutlets? = nil,
        pendingRestoreOutlets: PersistedOutcomeOutlets? = nil
    ) {
        self.plane = plane
        self.planId = planId
        self.routeRevisionSHA256 = routeRevisionSHA256
        self.regionId = regionId
        self.currentNodeId = currentNodeId
        self.cursorProgramPath = cursorProgramPath
        self.cursorActionIndex = cursorActionIndex
        self.currentScreenId = currentScreenId
        self.lifecycleGeneration = lifecycleGeneration
        self.presentationEpoch = presentationEpoch
        self.screenRouting = screenRouting
        self.navigationStack = navigationStack
        self.viewModelSnapshot = viewModelSnapshot
        self.pendingAction = pendingAction
        self.prePresentationContinuation = prePresentationContinuation
        self.pendingPresentation = pendingPresentation
        self.currentPresentation = currentPresentation
        self.postPresentationContinuation = postPresentationContinuation
        self.pendingPurchaseOutlets = pendingPurchaseOutlets
        self.pendingRestoreOutlets = pendingRestoreOutlets
    }

    private enum CodingKeys: String, CodingKey {
        case plane
        case planId
        case routeRevisionSHA256
        case regionId
        case currentNodeId
        case cursorProgramPath
        case cursorActionIndex
        case currentScreenId
        case lifecycleGeneration
        case presentationEpoch
        case screenRouting
        case navigationStack
        case viewModelSnapshot
        case pendingAction
        case prePresentationContinuation
        case pendingPresentation
        case currentPresentation
        case postPresentationContinuation
        case pendingPurchaseOutlets
        case pendingRestoreOutlets
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        plane = try container.decode(JourneyPlane.self, forKey: .plane)
        planId = try container.decodeIfPresent(String.self, forKey: .planId)
        routeRevisionSHA256 = try container.decodeIfPresent(String.self, forKey: .routeRevisionSHA256)
        regionId = try container.decodeIfPresent(String.self, forKey: .regionId)
        currentNodeId = try container.decodeIfPresent(String.self, forKey: .currentNodeId)
        cursorProgramPath = try container.decodeIfPresent(String.self, forKey: .cursorProgramPath)
        cursorActionIndex = try container.decodeIfPresent(Int.self, forKey: .cursorActionIndex)
        currentScreenId = try container.decodeIfPresent(String.self, forKey: .currentScreenId)
        lifecycleGeneration = try container.decode(
            UInt64.self,
            forKey: .lifecycleGeneration
        )
        presentationEpoch = try container.decode(
            UInt64.self,
            forKey: .presentationEpoch
        )
        screenRouting = try container.decode(
            JourneyScreenRoutingState.self,
            forKey: .screenRouting
        )
        navigationStack = try container.decode([String].self, forKey: .navigationStack)
        viewModelSnapshot = try container.decodeIfPresent(
            ExperienceViewModelSnapshot.self,
            forKey: .viewModelSnapshot
        )
        pendingAction = try container.decodeIfPresent(JourneyPendingAction.self, forKey: .pendingAction)
        prePresentationContinuation = try container.decodeIfPresent(
            [JourneyContinuationStep].self,
            forKey: .prePresentationContinuation
        )
        pendingPresentation = try container.decodeIfPresent(
            JourneyPendingPresentation.self,
            forKey: .pendingPresentation
        )
        currentPresentation = try container.decodeIfPresent(
            JourneyPendingPresentation.self,
            forKey: .currentPresentation
        )
        postPresentationContinuation = try container.decodeIfPresent(
            [JourneyContinuationStep].self,
            forKey: .postPresentationContinuation
        )
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
/// persistence.
struct JourneyStateEnvelope: Codable, Sendable {
    /// Latest state-envelope schema version understood by this SDK.
    public static let currentVersion = 3

    /// Schema version checked before applying the envelope.
    public let stateVersion: Int
    /// Interpreter variables transferred between owners.
    public var context: [String: AnyCodable]
    /// Device experience and execution cursor state.
    public var executionState: JourneyExecutionState
    /// Immutable experience settings captured when the journey enrolled.
    public var snapshots: [String: AnyCodable]
    /// Exact versioned response state used by every execution plane.
    public var responseSession: ResponseSessionSnapshot?

    /// Creates a versioned ownership-transfer envelope.
    public init(
        stateVersion: Int = JourneyStateEnvelope.currentVersion,
        context: [String: AnyCodable],
        executionState: JourneyExecutionState,
        snapshots: [String: AnyCodable],
        responseSession: ResponseSessionSnapshot?
    ) {
        self.stateVersion = stateVersion
        self.context = context
        self.executionState = executionState
        self.snapshots = snapshots
        self.responseSession = responseSession
    }

    /// Whether this SDK can safely apply the envelope.
    public var isSupported: Bool {
        stateVersion == Self.currentVersion
    }

    private enum CodingKeys: String, CodingKey {
        case stateVersion
        case context
        case executionState
        case snapshots
        case responseSession
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stateVersion = try container.decode(Int.self, forKey: .stateVersion)
        context = try container.decode(
            [String: AnyCodable].self,
            forKey: .context
        )
        executionState = try container.decode(
            JourneyExecutionState.self,
            forKey: .executionState
        )
        snapshots = try container.decode(
            [String: AnyCodable].self,
            forKey: .snapshots
        )
        responseSession = try container.decode(
            ResponseSessionSnapshot?.self,
            forKey: .responseSession
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(stateVersion, forKey: .stateVersion)
        try container.encode(context, forKey: .context)
        try container.encode(executionState, forKey: .executionState)
        try container.encode(snapshots, forKey: .snapshots)
        try container.encode(responseSession, forKey: .responseSession)
    }
}

/// A response-field mutation that has been accepted locally but has not yet
/// been acknowledged by the response service. The intent is checkpointed
/// before the local projection changes so a relaunch can safely replay the
/// idempotent field upsert without losing an earlier failed write.
struct PendingResponseFieldWrite: Codable, Equatable, Sendable {
    enum Mutation: String, Codable, Sendable {
        case set
        case unset
    }

    let operationId: String
    let screenId: String
    let field: String
    let mutation: Mutation
    let value: ScreenEmissionValue
    let occurredAt: String
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
    /// Run-owned response state carried through persistence and handoff.
    public var responseSession: ResponseSessionSnapshot?
    /// Durable idempotency receipts for response-session mutations.
    public var responseSessionReceipts: [String: ResponseSessionOperationResult]
    /// Locally accepted field writes awaiting server acknowledgement, keyed
    /// by the stable screen-emission operation identifier.
    public var pendingResponseFieldWrites: [String: PendingResponseFieldWrite]
    /// A failed response operation keeps the draft retryable across runner
    /// reconstruction and app restart.
    public var responseSessionRetryRequired: Bool

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
        self.responseSession = nil
        self.responseSessionReceipts = [:]
        self.pendingResponseFieldWrites = [:]
        self.responseSessionRetryRequired = false

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
        case responseSession
        case responseSessionReceipts
        case pendingResponseFieldWrites
        case responseSessionRetryRequired
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
        stateVersion = try container.decode(Int.self, forKey: .stateVersion)
        epoch = try container.decode(Int.self, forKey: .epoch)
        isGhost = try container.decode(Bool.self, forKey: .isGhost)
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
        responseSession = try container.decode(
            ResponseSessionSnapshot?.self,
            forKey: .responseSession
        )
        responseSessionReceipts = try container.decode(
            [String: ResponseSessionOperationResult].self,
            forKey: .responseSessionReceipts
        )
        pendingResponseFieldWrites = try container.decode(
            [String: PendingResponseFieldWrite].self,
            forKey: .pendingResponseFieldWrites
        )
        responseSessionRetryRequired = try container.decode(
            Bool.self,
            forKey: .responseSessionRetryRequired
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
        try container.encode(responseSession, forKey: .responseSession)
        try container.encode(responseSessionReceipts, forKey: .responseSessionReceipts)
        try container.encode(pendingResponseFieldWrites, forKey: .pendingResponseFieldWrites)
        try container.encode(responseSessionRetryRequired, forKey: .responseSessionRetryRequired)
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
            snapshots: snapshots,
            responseSession: responseSession
        )
    }

    /// Applies claimed state and advances the local ownership epoch.
    public mutating func applyStateEnvelope(_ envelope: JourneyStateEnvelope, epoch: Int) {
        stateVersion = envelope.stateVersion
        self.epoch = epoch
        context = envelope.context
        executionState = envelope.executionState
        responseSession = envelope.responseSession
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

    func versionedSnapshot() async -> JourneyVersionedSnapshot {
        await stateOwner.versionedSnapshot()
    }

    @discardableResult
    func replace(
        _ snapshot: JourneySnapshot,
        ifRevisionEquals revision: UInt64
    ) async -> Bool {
        await stateOwner.replace(snapshot, ifRevisionEquals: revision)
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

struct JourneyVersionedSnapshot: Sendable {
    let snapshot: JourneySnapshot
    let revision: UInt64
}

private actor JourneyStateOwner {
    private var value: JourneySnapshot
    private var revision: UInt64 = 0

    init(_ value: JourneySnapshot) {
        self.value = value
    }

    func snapshot() -> JourneySnapshot {
        value
    }

    func versionedSnapshot() -> JourneyVersionedSnapshot {
        JourneyVersionedSnapshot(snapshot: value, revision: revision)
    }

    func replace(
        _ snapshot: JourneySnapshot,
        ifRevisionEquals expectedRevision: UInt64
    ) -> Bool {
        guard revision == expectedRevision else { return false }
        value = snapshot
        revision &+= 1
        return true
    }

    func update<T: Sendable>(
        _ body: @Sendable (inout JourneySnapshot) -> T
    ) -> T {
        defer { revision &+= 1 }
        return body(&value)
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
