import Foundation
import CryptoKit

/// Actor: the runner's mutable execution state (actionQueue, sequenceStack,
/// isProcessing, isPaused, outlet slots…) was previously a plain class driven
/// from the reentrant JourneyService actor — while one dispatch was suspended
/// mid-processQueue, the service could start another on a different thread:
/// a data race by construction. Actor isolation makes every entry point
/// serialize at suspension points with memory safety; the isProcessing/
/// needsQueueDrain pair still coalesces logically-reentrant drains (actor
/// reentrancy interleaves at awaits — isolation is not mutual exclusion
/// across suspension points).
actor JourneyRunner {
    struct AuthoredEvent: Sendable {
        let name: String
        let properties: [String: AnyCodable]
        let hostId: String?
        let screenId: String?
        let handlerId: String?
    }

    // @unchecked Sendable: all stored properties are immutable (`let`); the
    // [String: Any] payload is a write-once snapshot never mutated after init.
    struct TriggerContext: @unchecked Sendable {
        let hostId: String?
        let screenId: String?
        let componentId: String?
        let handlerId: String?
        let instanceId: String?
        let payload: [String: Any]?
        let requiresTerminalTransfer: Bool

        init(
            hostId: String? = nil,
            screenId: String?,
            componentId: String?,
            handlerId: String?,
            instanceId: String?,
            payload: [String: Any]?,
            requiresTerminalTransfer: Bool = false
        ) {
            self.hostId = hostId
            self.screenId = screenId
            self.componentId = componentId
            self.handlerId = handlerId
            self.instanceId = instanceId
            self.payload = payload
            self.requiresTerminalTransfer = requiresTerminalTransfer
        }
    }

    enum RunOutcome: Sendable {
        case present(JourneyPendingPresentation)
        case paused(JourneyPendingAction)
        case transferred(HandoffAction)
        case exited(JourneyExitReason)
    }

    private enum ActionResult {
        case `continue`
        case present(screenId: String, transition: AnyCodable?)
        case stopSequence
        case pushSequence([JourneyAction], TriggerContext, SequenceIdentity)
        case pause(JourneyPendingAction)
        case transfer(HandoffAction)
        case exit(JourneyExitReason)
    }

    /// Response writes are route-branch boundaries. A failure carries the
    /// authored operation address so the interpreter can abort immediately
    /// and diagnostics can be correlated with the exact route instruction.
    private struct ResponseBranchAbort: Error, LocalizedError, Sendable {
        let operation: String
        let diagnostic: String
        let correlationId: String
        let underlying: String?

        var errorDescription: String? {
            var message = "response_branch_aborted operation=\(operation) diagnostic=\(diagnostic) correlation_id=\(correlationId)"
            if let underlying, !underlying.isEmpty {
                message += " underlying=\(underlying)"
            }
            return message
        }
    }

    private enum SequenceIdentity: Sendable {
        case queued(handlerId: String?)
        case nested(nodeId: String?)
        case resumed(handlerId: String?)
        case outlet(handlerId: String?)
    }

    private enum SequenceReturnContext {
        case root
        case action(
            parent: SequenceIdentity,
            instructionIndex: Int,
            action: JourneyAction,
            context: TriggerContext
        )
    }

    private struct ActionRequest {
        let rootId: String
        let isPriority: Bool
        let actions: [JourneyAction]
        let context: TriggerContext
        let identity: SequenceIdentity
        let startIndex: Int
        let resumeContext: ResumeContext?

        init(
            rootId: String = UUID.v7().uuidString,
            isPriority: Bool = false,
            actions: [JourneyAction],
            context: TriggerContext,
            identity: SequenceIdentity,
            startIndex: Int = 0,
            resumeContext: ResumeContext? = nil
        ) {
            self.rootId = rootId
            self.isPriority = isPriority
            self.actions = actions
            self.context = context
            self.identity = identity
            self.startIndex = startIndex
            self.resumeContext = resumeContext
        }
    }

    private struct SequenceFrame {
        let rootId: String
        let isPriority: Bool
        let identity: SequenceIdentity
        let actions: [JourneyAction]
        let context: TriggerContext
        var instructionIndex: Int
        var resumeContext: ResumeContext?
        var deferredResult: DeferredActionResult?
        let returnContext: SequenceReturnContext
    }

    private struct DeferredActionResult {
        let action: JourneyAction
        let instructionIndex: Int
        let result: ActionResult
    }

    private struct ContinuationItem {
        let rootId: String
        let operation: ContinuationOperation
    }

    private enum ContinuationOperation {
        case request(ActionRequest)
        case pending(JourneyPendingAction)
        case transfer(HandoffAction)
        case exit(JourneyExitReason)
    }

    private struct ResumeContext {
        let pending: JourneyPendingAction
        let reason: ResumeReason
        let event: NuxieEvent?
    }

    private let journey: Journey
    private let experience: Experience
    private let screens: JourneyDocument
    private let viewModelState: ExperienceViewModelStateCoordinator
    private let onMilestone: (@Sendable (_ milestoneId: String, _ label: String?, _ screenId: String?, _ handlerId: String?) async -> Void)?
    private let capturesSendEvents: Bool

    // Constructor-injected collaborators (Phase 4c composition root).
    private let eventLog: JourneyRunnerEventAccess
    private let identityService: IdentityServiceProtocol
    private let segmentService: SegmentServiceProtocol
    private let featureService: FeatureServiceProtocol
    private let profileService: ProfileServiceProtocol
    private let apiClient: ResponseWriting
    private let dateProvider: DateProviderProtocol
    private let irRuntime: IRRuntime
    /// The exact signed execution plan selected for this route and start
    /// plane. Plan selection is fail-closed; unsigned/legacy region tables are
    /// never consulted by the v2 runtime.
    private let executionPlan: JourneyExecutionPlanV2?
    private let executionRoute: JourneyRouteV2?
    /// Single response authority for this run. All response writes are routed
    /// through the schema-pinned module; the runner never owns a second cache.
    private let responseSessionModule: ResponseSessionModule?
    private let responseSessionRun: ResponseSessionRunAuthority?
    /// Persists response retry markers through JourneyService's ownership and
    /// checkpoint coordination. Runner-local fallback writes must not bypass
    /// that boundary or they can resurrect stale journey state.
    private let persistResponseRetryMarker: @Sendable (JourneySnapshot) async -> Bool
    /// Persists the runner-owned entry claim before any authored action can
    /// produce a side effect. Production injects JourneyService's store-owned
    /// adapter; runner-only tests may acknowledge the in-memory checkpoint.
    private let persistEntryActionClaim: @Sendable (JourneySnapshot) async -> Bool
    private let emitsTransitionEvents: Bool

    weak var viewController: ExperienceViewController?
    var onShowScreen: (@Sendable (String, AnyCodable?) async -> Void)?

    func setOnShowScreen(_ handler: @escaping @Sendable (String, AnyCodable?) async -> Void) {
        onShowScreen = handler
    }
    private(set) var isRuntimeReady = false
    private var isPrePresentationControlActive = false
    private var isCommittingRuntimeReady = false

    private var handlersByHost: [String: [JourneyEventHandler]] = [:]
    private var eventDeclarationsByHost: [String: [EventDeclaration]] = [:]
    private var handlerActionsById: [String: [JourneyAction]] = [:]
    private let journeyEventHostKey = JourneyDocument.journeyEventHostKey
    private var paywallStatusProjector = PaywallStatusProjector()
    /// Outcome outlets (Experience Logic 2026-07-04): chains captured from the
    /// initiating purchase/restore node, run when its async outcome event
    /// arrives. Keyed by the same single-active-invocation model as the
    /// paywall status projection above.
    private var pendingPurchaseOutlets:
        (onCompleted: [JourneyAction]?, onFailed: [JourneyAction]?, onCancelled: [JourneyAction]?, context: TriggerContext)?
    private var pendingRestoreOutlets:
        (onRestored: [JourneyAction]?, onNoPurchases: [JourneyAction]?, onFailed: [JourneyAction]?, context: TriggerContext)?

    private var actionQueue: [ActionRequest] = []
    private var priorityActionQueue: [ActionRequest] = []
    private var continuationQueue: [ContinuationItem] = []
    private var sequenceStack: [SequenceFrame] = []
    private var isProcessing = false
    private var needsQueueDrain = false
    private var isPaused = false
    private var pendingNotificationPermissionRequests = 0
    private var pendingRequestPermissionRequests = 0
    private var pendingTrackingPermissionRequests = 0
    private var deferredDismissReason: CloseReason?
    private var triggerResetTasks: [String: Task<Void, Never>] = [:]
    private let deferredTaskQueue = SerialTaskQueue()
    private var didAttemptResponseDraftWrite = false
    private var didFailSetResponseField = false
    private var didFailSubmitResponse = false
    private var authoredEvents: [AuthoredEvent] = []
    init(
        journey: Journey,
        initialState: JourneySnapshot? = nil,
        experience: Experience,
        onMilestone: (@Sendable (_ milestoneId: String, _ label: String?, _ screenId: String?, _ handlerId: String?) async -> Void)? = nil,
        capturesSendEvents: Bool = false,
        viewController: ExperienceViewController? = nil,
        eventLog: JourneyRunnerEventAccess,
        identity: IdentityServiceProtocol,
        segments: SegmentServiceProtocol,
        features: FeatureServiceProtocol,
        profile: ProfileServiceProtocol,
        apiClient: ResponseWriting,
        dateProvider: DateProviderProtocol,
        irRuntime: IRRuntime,
        responseSessionModule: ResponseSessionModule? = nil,
        persistResponseRetryMarker: @escaping @Sendable (JourneySnapshot) async -> Bool = { _ in true },
        persistEntryActionClaim: @escaping @Sendable (JourneySnapshot) async -> Bool,
        emitsTransitionEvents: Bool = true
    ) {
        let initialState = initialState ?? JourneySnapshot(
            id: journey.id,
            experience: experience,
            distinctId: journey.distinctId,
            now: journey.startedAt
        )
        self.journey = journey
        self.experience = experience
        self.eventLog = eventLog
        self.identityService = identity
        self.segmentService = segments
        self.featureService = features
        self.profileService = profile
        self.apiClient = apiClient
        self.dateProvider = dateProvider
        self.irRuntime = irRuntime
        let definition = experience.definitionV2
        let persistedPlanId = initialState.executionState.planId
        let persistedPlan = persistedPlanId.flatMap { definition?.executionPlan(id: $0) }
        let entryRoute = definition?.route(
            host: .journey,
            eventName: definition?.entryRouteEventName ?? ""
        )
        self.executionPlan = persistedPlan
            ?? entryRoute.flatMap { definition?.executionPlan(for: $0, startPlane: .device) }
        self.executionRoute = persistedPlan.flatMap { plan in
            definition?.route(host: plan.route.host, eventName: plan.route.eventName)
        } ?? entryRoute
        self.responseSessionModule = responseSessionModule
        self.persistResponseRetryMarker = persistResponseRetryMarker
        self.responseSessionRun = experience.definitionV2?.responseSchema.map {
            ResponseSessionRunAuthority(
                journeyId: initialState.id,
                executionOwnershipEpoch: UInt64(max(initialState.epoch, 0)),
                lifecycleGeneration: 1,
                schema: $0
            )
        }
        self.persistEntryActionClaim = persistEntryActionClaim
        self.emitsTransitionEvents = emitsTransitionEvents

        // Rehydrate persisted purchase/restore outlet chains (armed before an
        // app kill; the outcome may arrive via Transaction.updates this
        // session). Runtime payload context is not persisted — rebuild
        // addressing-only contexts.
        if let persisted = initialState.executionState.pendingPurchaseOutlets {
            self.pendingPurchaseOutlets = (
                onCompleted: persisted.first,
                onFailed: persisted.second,
                onCancelled: persisted.third,
                context: TriggerContext(
                    hostId: persisted.hostId,
                    screenId: persisted.screenId,
                    componentId: nil,
                    handlerId: persisted.handlerId,
                    instanceId: nil,
                    payload: nil
                )
            )
        }
        if let persisted = initialState.executionState.pendingRestoreOutlets {
            self.pendingRestoreOutlets = (
                onRestored: persisted.first,
                onNoPurchases: persisted.second,
                onFailed: persisted.third,
                context: TriggerContext(
                    hostId: persisted.hostId,
                    screenId: persisted.screenId,
                    componentId: nil,
                    handlerId: persisted.handlerId,
                    instanceId: nil,
                    payload: nil
                )
            )
        }
        self.screens = experience.screens
        self.viewModelState = ExperienceViewModelStateCoordinator(screens: experience.screens)
        self.onMilestone = onMilestone
        self.capturesSendEvents = capturesSendEvents
        self.viewController = viewController

        self.handlersByHost = experience.screens.handlers.mapValues(Self.sortedHandlers)
        self.eventDeclarationsByHost = experience.screens.events
        self.handlerActionsById = Self.indexHandlerActions(experience.screens.handlers)

        if let snapshot = initialState.executionState.viewModelSnapshot {
            viewModelState.hydrate(snapshot)
        }

        // Rehydrate pause state: a runner rebuilt for a restored journey that
        // persisted a pendingAction must behave like the same-session paused
        // runner (event-handler dispatch suppressed until resumePendingAction
        // clears the pause). Outcome outlets still run while paused, exactly
        // as in-session.
        self.isPaused = initialState.executionState.pendingAction != nil
    }

    /// Pins the response schema before the run can execute authored work.
    /// Restored runs therefore fail closed if their persisted snapshot no
    /// longer matches the signed experience definition.
    func pinResponseSession() async throws {
        guard let responseSessionModule, let responseSessionRun else { return }
        _ = try await responseSessionModule.pinRun(responseSessionRun)
        _ = try await responseSessionModule.subscribe(journeyId: journey.id) { [weak self] projection in
            Task { [weak self] in
                await self?.applyResponseProjection(projection)
            }
        }
    }

    private func applyResponseProjection(_ projection: ResponseSessionProjection) async {
        for (key, value) in projection.values {
            let path = ResponseFormController.valuePath(forKey: key)
            _ = viewModelState.setValue(
                path: path,
                value: value.foundationValue,
                screenId: (await journey.snapshot()).executionState.currentScreenId,
                instanceId: nil
            )
            applyViewModelValue(
                path: path,
                value: value.foundationValue,
                screenId: (await journey.snapshot()).executionState.currentScreenId,
                instanceId: nil
            )
        }
        if let state = projection.state {
            let path = ResponseFormController.statePath
            _ = viewModelState.setValue(
                path: path,
                value: state.rawValue,
                screenId: (await journey.snapshot()).executionState.currentScreenId,
                instanceId: nil
            )
            applyViewModelValue(
                path: path,
                value: state.rawValue,
                screenId: (await journey.snapshot()).executionState.currentScreenId,
                instanceId: nil
            )
        }
        let viewModelSnapshot = viewModelState.getSnapshot()
        await journey.update { $0.executionState.viewModelSnapshot = viewModelSnapshot }
    }

    func takeAuthoredEvents() -> [AuthoredEvent] {
        defer { authoredEvents.removeAll(keepingCapacity: true) }
        return authoredEvents
    }

    private static func indexHandlerActions(
        _ handlersByHost: [String: [JourneyEventHandler]]
    ) -> [String: [JourneyAction]] {
        handlersByHost.values.flatMap { $0 }.reduce(into: [:]) { result, handler in
            if result[handler.id] == nil {
                result[handler.id] = handler.actions
            }
        }
    }

    func attach(viewController: ExperienceViewController) {
        self.viewController = viewController
    }

    /// Persists renderer attachment before initial screen activation. The
    /// pending commit stays untouched unless the durable write succeeds.
    func commitRendererAttachment() async -> Bool {
        let versioned = await journey.versionedSnapshot()
        let state = versioned.snapshot
        guard let pending = state.executionState.pendingPresentation else {
            isPrePresentationControlActive = false
            isRuntimeReady = true
            return true
        }
        var committed = state
        committed.executionState.pendingPresentation = nil
        committed.executionState.currentPresentation = pending
        committed.executionState.currentScreenId = pending.screenId
        committed.executionState.postPresentationContinuation = pending.continuation
        committed.updatedAt = dateProvider.now()
        guard await persistEntryActionClaim(committed) else { return false }
        guard await journey.replace(
            committed,
            ifRevisionEquals: versioned.revision
        ) else {
            _ = await persistEntryActionClaim(await journey.snapshot())
            return false
        }
        isPrePresentationControlActive = false
        isRuntimeReady = true
        return true
    }

    func handleRuntimeReady() async -> RunOutcome? {
        guard !isCommittingRuntimeReady else { return nil }
        isCommittingRuntimeReady = true
        defer { isCommittingRuntimeReady = false }
        guard await commitRendererAttachment() else { return nil }
        await applyInitialViewModelState()
        var state = await journey.snapshot()
        if let outcome = await drainPostPresentationContinuation() { return outcome }
        state = await journey.snapshot()
        if state.executionState.viewModelSnapshot == nil {
            let viewModelSnapshot = viewModelState.getSnapshot()
            await journey.update { $0.executionState.viewModelSnapshot = viewModelSnapshot }
            state.executionState.viewModelSnapshot = viewModelSnapshot
        }

        if let current = state.executionState.currentScreenId {
            await sendShowScreen(current)
            return nil
        }

        if state.executionState.pendingAction == nil {
            let outcome = await runEntryActionsIfNeeded()
            if let outcome {
                return outcome
            }

            let afterEntry = await journey.snapshot()
            let entryProgramClaimed = afterEntry.context["_entry_actions_ran"]?.value as? Bool
                == true
            if !entryProgramClaimed,
               afterEntry.executionState.currentScreenId == nil {
                let fallback = screens.screens.first?.id
                if let fallback {
                    await navigate(to: fallback, transition: nil)
                }
            }
        }

        return nil
    }

    /// Runs authenticated journey control without declaring the renderer ready.
    func advanceUntilPresentation() async -> RunOutcome? {
        isPrePresentationControlActive = true
        let state = await journey.snapshot()
        if let pending = state.executionState.pendingPresentation {
            return .present(pending)
        }
        if let continuation = state.executionState.prePresentationContinuation {
            continuationQueue = materializePresentationContinuation(continuation)
            return await processQueue(resumeContext: nil)
        }
        guard state.executionState.pendingAction == nil else { return nil }
        if let outcome = await runEntryActionsIfNeeded() {
            return outcome
        }
        let afterEntry = await journey.snapshot()
        guard afterEntry.executionState.pendingAction == nil,
              afterEntry.executionState.pendingPresentation == nil,
              afterEntry.executionState.currentScreenId == nil,
              afterEntry.context["_entry_actions_ran"]?.value as? Bool != true,
              screens.screens.count == 1,
              let onlyScreen = screens.screens.first else { return nil }
        enqueueActions(
            [.navigate(.init(screenId: onlyScreen.id, transition: nil))],
            context: TriggerContext(
                screenId: nil,
                componentId: nil,
                handlerId: nil,
                instanceId: nil,
                payload: nil
            )
        )
        return await processQueue(resumeContext: nil)
    }

    func runDeviceRegion(_ region: JourneyDeviceRegion) async -> RunOutcome? {
        let currentScreenId = await journey.update { state in
            state.executionState.regionId = region.id
            state.executionState.currentNodeId = region.entryNodeId
            return state.executionState.currentScreenId
        }
        enqueueActions(
            region.actions,
            context: TriggerContext(
                hostId: journeyEventHostKey,
                screenId: currentScreenId,
                componentId: nil,
                handlerId: nil,
                instanceId: nil,
                payload: nil
            )
        )
        return await processQueue(resumeContext: nil)
    }

    /// Advances a newly claimed mailbox region before a renderer exists.
    /// Attached device-region dispatch keeps using `runDeviceRegion`.
    func advanceClaimedDeviceRegion(
        _ region: JourneyDeviceRegion
    ) async -> RunOutcome? {
        isPrePresentationControlActive = true
        let versioned = await journey.versionedSnapshot()
        var checkpoint = versioned.snapshot
        checkpoint.executionState.regionId = region.id
        checkpoint.executionState.currentNodeId = region.entryNodeId
        let request = ActionRequest(
            actions: region.actions,
            context: TriggerContext(
                hostId: journeyEventHostKey,
                screenId: checkpoint.executionState.currentScreenId,
                componentId: nil,
                handlerId: nil,
                instanceId: nil,
                payload: nil
            ),
            identity: .queued(handlerId: nil)
        )
        checkpoint.executionState.prePresentationContinuation = [
            checkpointStep(request)
        ]
        checkpoint.updatedAt = dateProvider.now()
        guard await persistEntryActionClaim(checkpoint) else { return nil }
        guard await journey.replace(
            checkpoint,
            ifRevisionEquals: versioned.revision
        ) else {
            _ = await persistEntryActionClaim(await journey.snapshot())
            return nil
        }
        continuationQueue = materializePresentationContinuation(
            checkpoint.executionState.prePresentationContinuation ?? []
        )
        return await processQueue(resumeContext: nil)
    }

    func handleScreenChanged(_ screenId: String) async -> RunOutcome? {
        return await dispatchScreenChanged(screenId)
    }

    private func dispatchScreenChanged(_ screenId: String) async -> RunOutcome? {
        await journey.update { $0.executionState.currentScreenId = screenId }
        let event = makeSystemEvent(
            name: SystemEventNames.screenShown,
            properties: ["screen_id": screenId]
        )
        let hasScreenDeclaration =
            (eventDeclarationsByHost[screenId] ?? []).contains {
                $0.eventName == event.name
            }
        let lifecycleSteps = await eventRequests(
            hostId: hasScreenDeclaration ? screenId : journeyEventHostKey,
            event: event,
            screenId: screenId,
            componentId: nil,
            instanceId: nil
        ).map(checkpointStep)
        let post = (await journey.snapshot()).executionState
            .postPresentationContinuation ?? []
        if !lifecycleSteps.isEmpty || !post.isEmpty {
            continuationQueue = materializePresentationContinuation(
                lifecycleSteps + post
            )
            let outcome = await processQueue(resumeContext: nil)
            await finishPostPresentationDrainIfPossible(outcome: outcome)
            return outcome
        }
        return await dispatchScreenLifecycleEvent(event, screenId: screenId)
    }

    func handleScreenDismissed(
        _ screenId: String,
        revealingScreenId: String?,
        method: String
    ) async -> RunOutcome? {
        let event = makeSystemEvent(
            name: SystemEventNames.screenDismissed,
            properties: ["screen_id": screenId, "method": method]
        )
        let outcome = await dispatchScreenLifecycleEvent(
            event,
            screenId: screenId
        )

        await reconcileDismissedScreenState(
            dismissedScreenId: screenId,
            revealingScreenId: revealingScreenId
        )
        return outcome
    }

    private func dispatchScreenLifecycleEvent(
        _ event: NuxieEvent,
        screenId: String
    ) async -> RunOutcome? {
        let hasScreenDeclaration =
            (eventDeclarationsByHost[screenId] ?? []).contains {
                $0.eventName == event.name
            }
        if hasScreenDeclaration {
            return await dispatchEvent(
                hostId: screenId,
                event: event,
                screenId: screenId,
                componentId: nil,
                instanceId: nil
            )
        }

        // Older published experiences stored lifecycle handlers on the journey
        // host. Keep them working while routing current screen contracts to
        // the same host used by the TypeScript runtime.
        return await dispatchJourneyEvent(event)
    }

    @discardableResult
    private func reconcileDismissedScreenState(
        dismissedScreenId: String,
        revealingScreenId: String?
    ) async -> Bool {
        await journey.update { state in
            guard let revealingScreenId, !revealingScreenId.isEmpty else {
                // Keep the terminal screen addressable until the journey's
                // dismissal notification and completion have consumed it.
                // Navigation and sheet dismissals provide their revealed
                // screen and continue to reconcile below.
                return false
            }

            guard state.executionState.currentScreenId == dismissedScreenId ||
                state.executionState.currentScreenId == nil else {
                return false
            }

            if state.executionState.navigationStack.last == revealingScreenId {
                state.executionState.navigationStack.removeLast()
            } else if let index = state.executionState.navigationStack.lastIndex(of: revealingScreenId) {
                state.executionState.navigationStack = Array(state.executionState.navigationStack.prefix(index))
            }

            state.executionState.currentScreenId = revealingScreenId
            return true
        }
    }

    func handleDidSet(
        path: VmPathRef,
        value: Any,
        source: String?,
        screenId: String?,
        instanceId: String?,
        isTrigger: Bool = false
    ) async -> RunOutcome? {
        let currentScreenId = (await journey.snapshot()).executionState.currentScreenId
        let resolvedScreenId = screenId ?? currentScreenId
        _ = viewModelState.setValue(
            path: path,
            value: value,
            screenId: resolvedScreenId,
            instanceId: instanceId
        )
        let viewModelSnapshot = viewModelState.getSnapshot()
        await journey.update { $0.executionState.viewModelSnapshot = viewModelSnapshot }

        scheduleTriggerReset(
            path: path,
            screenId: resolvedScreenId,
            instanceId: instanceId,
            notifyRenderer: source != "rive" && source != "runtime",
            force: isTrigger
        )
        return nil
    }



    func handleRuntimeOpenLink(
        url: Any,
        target: String?,
        screenId: String?,
        instanceId: String?
    ) async {
        guard let controller = viewController else { return }
        let resolved = await resolveValueRefs(
            url,
            context: TriggerContext(
                screenId: screenId,
                componentId: nil,
                handlerId: nil,
                instanceId: instanceId,
                payload: nil
            )
        )
        guard let urlString = resolved as? String, !urlString.isEmpty else { return }
        await MainActor.run {
            controller.performOpenLink(urlString: urlString, target: target)
        }
        var userInfo: [String: Any] = [
            "journeyId": journey.id,
            "experienceId": journey.experienceId,
            "url": urlString
        ]
        if let target {
            userInfo["target"] = target
        }
        let currentScreenId = (await journey.snapshot()).executionState.currentScreenId
        if let resolvedScreenId = screenId ?? currentScreenId {
            userInfo["screenId"] = resolvedScreenId
        }
        NotificationCenter.default.post(
            name: .nuxieOpenLink,
            object: nil,
            userInfo: userInfo
        )
    }

    func dispatchEventTrigger(_ event: NuxieEvent) async -> RunOutcome? {
        return await dispatchJourneyEvent(event)
    }

    /// Abandons the selected commercial presentation and runs the authored
    /// `$products_unavailable` journey branch before any renderer is attached.
    /// The abandoned presentation continuation is deliberately discarded: it
    /// may contain actions whose terms depended on the unavailable products.
    func handleProductsUnavailable() async -> RunOutcome? {
        let state = await journey.snapshot()
        guard state.executionState.pendingPresentation != nil else {
            return .exited(.error)
        }

        sequenceStack.removeAll()
        continuationQueue.removeAll()
        priorityActionQueue.removeAll()
        actionQueue.removeAll()
        await journey.update { current in
            current.executionState.pendingPresentation = nil
            current.executionState.currentPresentation = nil
            current.executionState.currentScreenId = nil
            current.executionState.prePresentationContinuation = nil
            current.executionState.postPresentationContinuation = nil
            current.executionState.navigationStack = []
            current.updatedAt = dateProvider.now()
        }
        isPrePresentationControlActive = true
        isRuntimeReady = false

        return await dispatchProductsUnavailableEvent()
    }

    /// Runs the same authored fallback when a later commercial screen cannot
    /// resolve its live products. Unlike the pre-reveal path above, the active
    /// presentation remains attached so the handler can navigate to a
    /// non-commercial fallback screen.
    func handleRuntimeProductsUnavailable() async -> RunOutcome? {
        let state = await journey.snapshot()
        guard state.executionState.currentPresentation != nil else {
            return .exited(.error)
        }
        // `navigate(to:)` records the visible screen before asking the native
        // host to mount the destination. Product resolution failed before that
        // mount committed, so remove exactly that provisional history entry
        // before the authored fallback runs.
        await journey.update { current in
            guard let visible = current.executionState.currentScreenId,
                  current.executionState.navigationStack.last == visible else {
                return
            }
            current.executionState.navigationStack.removeLast()
        }
        return await dispatchProductsUnavailableEvent()
    }

    private func dispatchProductsUnavailableEvent() async -> RunOutcome? {
        let event = NuxieEvent(
            name: SystemEventNames.productsUnavailable,
            distinctId: journey.distinctId,
            properties: [
                "experience_id": experience.id,
                "experience_version_id": experience.versionId,
            ],
            timestamp: dateProvider.now()
        )
        guard await acceptsEventTrigger(event) else {
            return .exited(.error)
        }
        return await dispatchJourneyEvent(event) ?? .exited(.error)
    }

    func acceptsEventTrigger(_ event: NuxieEvent) async -> Bool {
        switch event.name {
        case SystemEventNames.purchaseCompleted,
             SystemEventNames.purchaseFailed,
             SystemEventNames.purchaseCancelled:
            if pendingPurchaseOutlets != nil { return true }
        case SystemEventNames.restoreCompleted,
             SystemEventNames.restoreFailed,
             SystemEventNames.restoreNoPurchases:
            if pendingRestoreOutlets != nil { return true }
        default:
            break
        }

        if let pending = (await journey.snapshot()).executionState.pendingAction {
            if pending.kind == .waitUntil {
                if let maxTimeMs = pending.maxTimeMs,
                   dateProvider.now() >= pending.startedAt.addingTimeInterval(
                     TimeInterval(maxTimeMs) / 1_000
                   ) {
                    return true
                }
                if let trigger = pending.journeyWaitTrigger {
                    let currentResponseVersion = (await journey.snapshot()).responseSession?.version
                    switch trigger {
                    case .responseChange:
                        guard pending.responseVersion != currentResponseVersion else { return false }
                    case .event(let eventName, _):
                        guard event.name == eventName else { return false }
                    case .eventOrResponseChange(let eventName, _):
                        guard event.name == eventName || pending.responseVersion != currentResponseVersion else {
                            return false
                        }
                    }
                }
                if let condition = pending.journeyCondition {
                    return await evalJourneyCondition(condition, event: event)
                }
                return await evalConditionIR(pending.condition, event: event)
            }
            return false
        }

        guard canDispatchEvent(hostId: journeyEventHostKey, event: event) else {
            return false
        }
        return (handlersByHost[journeyEventHostKey] ?? []).contains {
            $0.enabled != false && $0.eventName == event.name
        }
    }

    func dispatchJourneyEvent(_ event: NuxieEvent) async -> RunOutcome? {
        await projectPaywallStatus(from: event)
        switch await runOutcomeOutlets(for: event) {
        case .consumed(let outcome):
            return outcome
        case .notConsumed:
            break
        }
        let currentScreenId = (await journey.snapshot()).executionState.currentScreenId
        return await dispatchEvent(
            hostId: journeyEventHostKey,
            event: event,
            screenId: currentScreenId,
            componentId: nil,
            instanceId: nil
        )
    }

    private enum OutletDispatch {
        /// An outlet chain ran (or was deliberately empty); global handlers
        /// do not also process the event. Outlets are canonical.
        case consumed(RunOutcome?)
        /// No pending outlet for this event; normal dispatch proceeds.
        case notConsumed
    }

    /// Runs the initiating node's outcome outlet chain for purchase/restore
    /// outcome events, correlating the async outcome back to the node that
    /// started it (Experience Logic 2026-07-04).
    private func runOutcomeOutlets(for event: NuxieEvent) async -> OutletDispatch {
        switch event.name {
        case SystemEventNames.purchaseCompleted,
             SystemEventNames.purchaseFailed,
             SystemEventNames.purchaseCancelled:
            guard let pending = pendingPurchaseOutlets else { return .notConsumed }
            pendingPurchaseOutlets = nil
            await journey.update { $0.executionState.pendingPurchaseOutlets = nil }
            let chain: [JourneyAction]?
            switch event.name {
            case SystemEventNames.purchaseCompleted: chain = pending.onCompleted
            case SystemEventNames.purchaseFailed: chain = pending.onFailed
            default: chain = pending.onCancelled
            }
            guard let chain, !chain.isEmpty else { return .consumed(nil) }
            return .consumed(await runOutletActions(chain, context: pending.context))
        case SystemEventNames.restoreCompleted,
             SystemEventNames.restoreFailed,
             SystemEventNames.restoreNoPurchases:
            guard let pending = pendingRestoreOutlets else { return .notConsumed }
            pendingRestoreOutlets = nil
            await journey.update { $0.executionState.pendingRestoreOutlets = nil }
            let chain: [JourneyAction]?
            switch event.name {
            case SystemEventNames.restoreCompleted: chain = pending.onRestored
            case SystemEventNames.restoreNoPurchases: chain = pending.onNoPurchases
            default: chain = pending.onFailed
            }
            guard let chain, !chain.isEmpty else { return .consumed(nil) }
            return .consumed(await runOutletActions(chain, context: pending.context))
        default:
            return .notConsumed
        }
    }

    private func runOutletActions(
        _ actions: [JourneyAction],
        context: TriggerContext
    ) async -> RunOutcome? {
        let outletContext = TriggerContext(
            hostId: context.hostId,
            screenId: context.screenId,
            componentId: context.componentId,
            handlerId: context.handlerId,
            instanceId: context.instanceId,
            payload: context.payload,
            requiresTerminalTransfer: true
        )
        let request = ActionRequest(
            isPriority: true,
            actions: actions,
            context: outletContext,
            identity: .outlet(handlerId: context.handlerId)
        )
        priorityActionQueue.append(request)
        if isProcessing {
            needsQueueDrain = true
            return nil
        }
        return await processQueue(
            resumeContext: nil,
            runWhilePaused: true,
            stopAfterFirstRequest: true
        )
    }

    func dispatchScreenEvent(
        _ event: NuxieEvent,
        screenId: String?,
        componentId: String?,
        instanceId: String?
    ) async -> RunOutcome? {
        let currentScreenId = (await journey.snapshot()).executionState.currentScreenId
        guard let hostId = screenId ?? currentScreenId,
              !hostId.isEmpty else { return nil }

        if event.name == SystemEventNames.responseSet {
            return await runResponseSetBuiltIn(
                event,
                screenId: hostId,
                componentId: componentId,
                instanceId: instanceId
            )
        }
        if event.name == "$response_unset" {
            return await runResponseUnsetBuiltIn(
                event,
                screenId: hostId,
                componentId: componentId,
                instanceId: instanceId
            )
        }

        return await dispatchEvent(
            hostId: hostId,
            event: event,
            screenId: hostId,
            componentId: componentId,
            instanceId: instanceId
        )
    }

    /// Built-in handling for the `$response_set` Script Verb event
    /// (`Nuxie.response.set(field, value)` in screen scripts). Synthesizes a
    /// set_response_field action against the experience-scoped response schema, so
    /// scripts never carry schema ids. Drops the event when the experience declares
    /// no response schema or the payload is malformed (Experience Logic 2026-07-04).
    private func runResponseSetBuiltIn(
        _ event: NuxieEvent,
        screenId: String,
        componentId: String?,
        instanceId: String?
    ) async -> RunOutcome? {
        if isPaused { return nil }
        if let schema = experience.definitionV2?.responseSchema,
           let field = event.properties["field"] as? String,
           schema.capturesByScreen[screenId]?.contains(field) != true {
            return nil
        }
        guard let action = ResponseFormController.synthesizedSetResponseField(
            schemaId: screens.responseSchemas?.first?.responseSchemaId,
            eventProperties: event.properties
        ) else { return nil }

        enqueueActions(
            [.setResponseField(action)],
            context: TriggerContext(
                screenId: screenId,
                componentId: componentId,
                handlerId: nil,
                instanceId: instanceId,
                payload: eventPayload(event)
            )
        )
        return await processQueue(resumeContext: nil)
    }

    private func runResponseUnsetBuiltIn(
        _ event: NuxieEvent,
        screenId: String,
        componentId: String?,
        instanceId: String?
    ) async -> RunOutcome? {
        if isPaused { return nil }
        guard let schema = experience.definitionV2?.responseSchema,
              let field = event.properties["field"] as? String,
              schema.capturesByScreen[screenId]?.contains(field) == true else {
            return nil
        }
        enqueueActions(
            [.setResponseField(SetResponseFieldAction(
                responseSchemaId: schema.key,
                schemaVersion: Int(schema.version),
                key: field,
                value: AnyCodable(NSNull())
            ))],
            context: TriggerContext(
                screenId: screenId,
                componentId: componentId,
                handlerId: nil,
                instanceId: instanceId,
                payload: eventPayload(event)
            )
        )
        return await processQueue(resumeContext: nil)
    }

    private func dispatchEvent(
        hostId: String,
        event: NuxieEvent,
        screenId: String?,
        componentId: String?,
        instanceId: String?
    ) async -> RunOutcome? {
        if isPaused { return nil }

        if hostId != journeyEventHostKey, !hostId.isEmpty {
            await journey.update { state in
                if state.executionState.currentScreenId == nil {
                    state.executionState.currentScreenId = hostId
                }
            }
        }

        let requests = await eventRequests(
            hostId: hostId,
            event: event,
            screenId: screenId,
            componentId: componentId,
            instanceId: instanceId
        )
        if requests.isEmpty { return nil }
        actionQueue.append(contentsOf: requests)

        return await processQueue(resumeContext: nil)
    }

    private func eventRequests(
        hostId: String,
        event: NuxieEvent,
        screenId: String?,
        componentId: String?,
        instanceId: String?
    ) async -> [ActionRequest] {
        if let definition = experience.definitionV2 {
            let routeHost: JourneyRouteHostV2 = hostId == journeyEventHostKey
                ? .journey
                : .screen(hostId)
            let state = await journey.snapshot()
            guard let route = definition.route(host: routeHost, eventName: event.name),
                  let plan = (executionPlan?.route == route.key
                    && executionPlan?.revisionSHA256 == route.revisionSHA256
                    ? executionPlan
                    : definition.executionPlan(for: route, startPlane: .device)),
                  let region = (state.executionState.planId == plan.id
                    ? state.executionState.regionId.flatMap(plan.region)
                    : nil) ?? plan.region(id: plan.entryRegionId),
                  region.plane == .device,
                  let actions = try? definition.compiledDeviceRegionProgram(
                      route,
                      plan: plan,
                      region: region
                  ) else {
                return []
            }
            if state.executionState.planId != plan.id
                || state.executionState.routeRevisionSHA256 != route.revisionSHA256 {
                await journey.update { state in
                    state.executionState.plane = .device
                    state.executionState.planId = plan.id
                    state.executionState.routeRevisionSHA256 = route.revisionSHA256
                    state.executionState.regionId = region.id
                    state.executionState.cursorProgramPath = region.entryCursor.programPath
                    state.executionState.cursorActionIndex = region.entryCursor.actionIndex
                    state.updatedAt = dateProvider.now()
                }
            }
            let routeIdentity = "route:\(route.revisionSHA256)"
            return [ActionRequest(
                actions: actions,
                context: TriggerContext(
                    hostId: hostId,
                    screenId: screenId,
                    componentId: componentId,
                    handlerId: routeIdentity,
                    instanceId: instanceId,
                    payload: eventPayload(event)
                ),
                identity: .queued(handlerId: routeIdentity)
            )]
        }
        guard canDispatchEvent(hostId: hostId, event: event) else { return [] }
        return Self.sortedHandlers((handlersByHost[hostId] ?? []).filter {
            $0.enabled != false && $0.eventName == event.name
        }).map { handler in
            ActionRequest(
                actions: handler.actions,
                context: TriggerContext(
                    hostId: hostId,
                    screenId: screenId,
                    componentId: componentId,
                    handlerId: handler.id,
                    instanceId: instanceId,
                    payload: eventPayload(event)
                ),
                identity: .queued(handlerId: handler.id)
            )
        }
    }

    private func eventPayload(_ event: NuxieEvent) -> [String: Any] {
        var payload = event.properties
        payload["__nuxie_emission_id"] = event.id
        return payload
    }

    private func drainPostPresentationContinuation() async -> RunOutcome? {
        let state = await journey.snapshot()
        guard let post = state.executionState.postPresentationContinuation else {
            return nil
        }
        continuationQueue = materializePresentationContinuation(post)
        let outcome = await processQueue(resumeContext: nil)
        await finishPostPresentationDrainIfPossible(outcome: outcome)
        return outcome
    }

    private func finishPostPresentationDrainIfPossible(
        outcome: RunOutcome?
    ) async {
        switch outcome {
        case .paused:
            // The pending action owns the remaining durable continuation.
            await journey.update {
                $0.executionState.postPresentationContinuation = nil
            }
        case .transferred, .exited:
            await journey.update {
                $0.executionState.postPresentationContinuation = nil
            }
        case .present:
            break
        case nil:
            guard continuationQueue.isEmpty,
                  priorityActionQueue.isEmpty,
                  actionQueue.isEmpty,
                  sequenceStack.isEmpty else { return }
            var versioned = await journey.versionedSnapshot()
            guard let original = versioned.snapshot.executionState
                .postPresentationContinuation,
                let originalBytes = encodedContinuation(original) else { return }

            // Persistence can suspend while another actor-owned event mutates
            // the journey. Consume only the exact tail we drained, merging the
            // cursor into the latest snapshot instead of overwriting it.
            for _ in 0..<4 {
                guard let current = versioned.snapshot.executionState
                    .postPresentationContinuation else { return }
                guard encodedContinuation(current) == originalBytes else {
                    _ = await persistEntryActionClaim(versioned.snapshot)
                    return
                }
                var consumed = versioned.snapshot
                consumed.executionState.postPresentationContinuation = nil
                consumed.updatedAt = dateProvider.now()
                guard await persistEntryActionClaim(consumed) else { return }
                if await journey.replace(
                    consumed,
                    ifRevisionEquals: versioned.revision
                ) {
                    return
                }
                versioned = await journey.versionedSnapshot()
            }
            _ = await persistEntryActionClaim(await journey.snapshot())
        }
    }

    private func encodedContinuation(
        _ continuation: [JourneyContinuationStep]
    ) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(continuation)
    }

    func resumePendingAction(reason: ResumeReason, event: NuxieEvent?) async -> RunOutcome? {
        let resumed = await journey.update { state -> (JourneyPendingAction?, UInt64?) in
            let pending = state.executionState.pendingAction
            state.executionState.pendingAction = nil
            return (pending, state.responseSession?.version)
        }
        let pending = resumed.0
        guard let pending else { return nil }

        if pending.hasResponseSnapshotConflict(currentVersion: resumed.1) {
            isPaused = false
            eventLog.track(
                JourneyEvents.journeyTransition,
                properties: [
                    "journey_id": journey.id,
                    "error": "response_snapshot_conflict",
                    "node_id": pending.handlerId,
                    "expected_response_version": pending.responseVersion.map(String.init) ?? "none",
                    "actual_response_version": resumed.1.map(String.init) ?? "none",
                ],
                userProperties: nil,
                userPropertiesSetOnce: nil
            )
            return nil
        }

        isPaused = false

        let context = TriggerContext(
            hostId: pending.hostId,
            screenId: pending.screenId,
            componentId: pending.componentId,
            handlerId: pending.handlerId,
            instanceId: nil,
            payload: event?.properties,
            requiresTerminalTransfer: pending.requiresTerminalTransfer == true
        )

        if let continuation = pending.continuation {
            let items = materializeContinuation(
                continuation,
                pending: pending,
                reason: reason,
                event: event
            )
            continuationQueue.insert(contentsOf: items, at: 0)
            if isProcessing {
                needsQueueDrain = true
                return nil
            }
            sequenceStack.removeAll()
            return await processQueue(resumeContext: nil)
        }

        let request: ActionRequest
        if let resumeActions = pending.resumeActions {
            request = ActionRequest(
                isPriority: isProcessing,
                actions: resumeActions,
                context: context,
                identity: .resumed(handlerId: pending.handlerId),
                resumeContext: ResumeContext(
                    pending: pending,
                    reason: reason,
                    event: event
                )
            )
        } else {
            guard let actions = resolveActions(
                handlerId: pending.handlerId,
                screenId: pending.screenId,
                componentId: pending.componentId
            ) else {
                return nil
            }
            request = ActionRequest(
                isPriority: isProcessing,
                actions: actions,
                context: context,
                identity: .resumed(handlerId: pending.handlerId),
                startIndex: pending.kind == .delay
                    ? pending.actionIndex + 1
                    : pending.actionIndex,
                resumeContext: ResumeContext(
                    pending: pending,
                    reason: reason,
                    event: event
                )
            )
        }

        if isProcessing {
            priorityActionQueue.append(request)
            needsQueueDrain = true
            return nil
        }
        sequenceStack.removeAll()
        actionQueue.insert(request, at: 0)
        return await processQueue(resumeContext: nil)
    }

    func hasPendingWork() async -> Bool {
        if pendingNotificationPermissionRequests > 0 { return true }
        if pendingRequestPermissionRequests > 0 { return true }
        if pendingTrackingPermissionRequests > 0 { return true }
        if (await journey.snapshot()).executionState.pendingAction != nil { return true }
        if !sequenceStack.isEmpty { return true }
        if !continuationQueue.isEmpty { return true }
        if !priorityActionQueue.isEmpty { return true }
        if !actionQueue.isEmpty { return true }
        return false
    }

    func hasPendingPermissionWork() -> Bool {
        if pendingNotificationPermissionRequests > 0 { return true }
        if pendingRequestPermissionRequests > 0 { return true }
        if pendingTrackingPermissionRequests > 0 { return true }
        return false
    }

    func beginNotificationPermissionRequest() {
        pendingNotificationPermissionRequests += 1
    }

    func beginTrackingPermissionRequest() {
        pendingTrackingPermissionRequests += 1
    }

    func beginRequestPermissionRequest() {
        pendingRequestPermissionRequests += 1
    }

    func endRequestPermissionRequest() {
        if pendingRequestPermissionRequests > 0 {
            pendingRequestPermissionRequests -= 1
        }
    }

    func endTrackingPermissionRequest() {
        if pendingTrackingPermissionRequests > 0 {
            pendingTrackingPermissionRequests -= 1
        }
    }

    func deferDismiss(reason: CloseReason) {
        deferredDismissReason = reason
    }

    func consumeDeferredDismissReasonIfReady() -> CloseReason? {
        guard !hasPendingPermissionWork() else { return nil }
        let reason = deferredDismissReason
        deferredDismissReason = nil
        return reason
    }

    func handleScopedSystemPermissionEvent(_ eventName: String) {
        if pendingNotificationPermissionRequests > 0 {
            if eventName == SystemEventNames.notificationsEnabled
                || eventName == SystemEventNames.notificationsDenied
            {
                pendingNotificationPermissionRequests -= 1
            }
        }

        if pendingRequestPermissionRequests > 0 {
            if eventName == SystemEventNames.permissionGranted
                || eventName == SystemEventNames.permissionDenied
            {
                endRequestPermissionRequest()
            }
        }

        if pendingTrackingPermissionRequests > 0 {
            if eventName == SystemEventNames.trackingAuthorized
                || eventName == SystemEventNames.trackingDenied
            {
                endTrackingPermissionRequest()
            }
        }
    }

    private func makeSystemEvent(name: String, properties: [String: Any]) -> NuxieEvent {
        return NuxieEvent(
            name: name,
            distinctId: journey.distinctId,
            properties: properties
        )
    }

    private static func sortedHandlers(_ handlers: [JourneyEventHandler]) -> [JourneyEventHandler] {
        handlers.enumerated().sorted { lhs, rhs in
            let leftOrder = lhs.element.order ?? lhs.offset
            let rightOrder = rhs.element.order ?? rhs.offset
            if leftOrder != rightOrder {
                return leftOrder < rightOrder
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private func canDispatchEvent(hostId: String, event: NuxieEvent) -> Bool {
        let declarations = eventDeclarationsByHost[hostId] ?? []
        guard let declaration = declarations.first(where: { $0.eventName == event.name }) else {
            return false
        }
        guard let payloadSchema = declaration.payloadSchema else {
            return true
        }
        return EventPayloadSchemaMatcher.matches(event.properties, schema: payloadSchema)
    }

    private func runEntryActionsIfNeeded() async -> RunOutcome? {
        if let definition = experience.definitionV2 {
            return await runV2EntryActionsIfNeeded(definition)
        }
        // Idempotency: entry actions run at most once per journey. A restore
        // before the first screen previously replayed the whole entry chain
        // (re-firing sendEvent/purchase side effects).
        let handlers = handlersByHost[journeyEventHostKey] ?? []
        let enabledHandlers = handlers.filter { $0.enabled != false }
        if enabledHandlers.isEmpty { return nil }

        let experienceEventName = await experienceTriggerEventName()
        // Signed release descriptors publish their entry program under the
        // canonical journey-started control event. It wins over the external
        // enrollment trigger and legacy app-opened compatibility handler.
        // "Whatever handler happens to be first" remains forbidden.
        let preferredEventName =
            (enabledHandlers.contains {
                $0.eventName == SystemEventNames.journeyStarted
            } ? SystemEventNames.journeyStarted : nil) ??
            experienceEventName.flatMap { eventName in
                enabledHandlers.contains { $0.eventName == eventName } ? eventName : nil
            } ??
            (enabledHandlers.contains { $0.eventName == SystemEventNames.appOpened } ? SystemEventNames.appOpened : nil)
        guard let preferredEventName else { return nil }

        let matchingHandlers = Self.sortedHandlers(
            enabledHandlers.filter { $0.eventName == preferredEventName }
        )
        if matchingHandlers.isEmpty { return nil }

        let currentScreenId = (await journey.snapshot()).executionState.currentScreenId
        let entryRequests = matchingHandlers.map { handler in
            ActionRequest(
                actions: handler.actions,
                context: TriggerContext(
                    hostId: journeyEventHostKey,
                    screenId: currentScreenId,
                    componentId: nil,
                    handlerId: handler.id,
                    instanceId: nil,
                    payload: [:]
                ),
                identity: .queued(handlerId: handler.id)
            )
        }
        let durableProgram = isPrePresentationControlActive
            ? entryRequests.map(checkpointStep)
            : nil

        let now = dateProvider.now()
        let claimedState = await journey.update { state -> JourneySnapshot? in
            if state.context["_entry_actions_ran"]?.value as? Bool == true {
                return nil
            }
            state.context["_entry_actions_ran"] = AnyCodable(true)
            state.executionState.prePresentationContinuation = durableProgram
            state.updatedAt = now
            return state
        }
        guard let claimedState else { return nil }

        // This await re-enters JourneyService through a narrow store-owned
        // adapter. It never calls back into JourneyRunner, so actor ownership
        // is preserved without a circular wait. Failure is fail-closed: the
        // in-memory claim remains set and no authored action is enqueued.
        guard await persistEntryActionClaim(claimedState) else {
            return nil
        }

        actionQueue.append(contentsOf: entryRequests)

        return await processQueue(resumeContext: nil)
    }

    private func runV2EntryActionsIfNeeded(
        _ definition: ExperienceDefinitionV2
    ) async -> RunOutcome? {
        guard let route = definition.route(
            host: .journey,
            eventName: definition.entryRouteEventName
        ), let plan = definition.executionPlan(for: route, startPlane: .device),
              plan.startPlane == .device,
              let region = plan.region(id: plan.entryRegionId),
              region.plane == .device,
              let actions = try? definition.compiledDeviceRegionProgram(
                  route,
                  plan: plan,
                  region: region
              ) else {
            return nil
        }
        let routeIdentity = "route:\(route.revisionSHA256)"
        let currentScreenId = (await journey.snapshot()).executionState.currentScreenId
        let request = ActionRequest(
            actions: actions,
            context: TriggerContext(
                hostId: journeyEventHostKey,
                screenId: currentScreenId,
                componentId: nil,
                handlerId: routeIdentity,
                instanceId: nil,
                payload: [:]
            ),
            identity: .queued(handlerId: routeIdentity)
        )
        let durableProgram = isPrePresentationControlActive
            ? [checkpointStep(request)]
            : nil
        let now = dateProvider.now()
        let claimedState = await journey.update { state -> JourneySnapshot? in
            if state.context["_entry_actions_ran"]?.value as? Bool == true {
                return nil
            }
            state.context["_entry_actions_ran"] = AnyCodable(true)
            state.executionState.plane = .device
            state.executionState.planId = plan.id
            state.executionState.routeRevisionSHA256 = route.revisionSHA256
            state.executionState.regionId = region.id
            state.executionState.cursorProgramPath = region.entryCursor.programPath
            state.executionState.cursorActionIndex = region.entryCursor.actionIndex
            state.executionState.prePresentationContinuation = durableProgram
            state.updatedAt = now
            return state
        }
        guard let claimedState else { return nil }
        guard await persistEntryActionClaim(claimedState) else {
            return nil
        }
        actionQueue.append(request)
        return await processQueue(resumeContext: nil)
    }

    /// Resolves a signed plan region's cursor to the exact route program
    /// suffix. This is the only device-region admission path for v2.
    func advanceClaimedExecutionPlanRegion(
        _ plan: JourneyExecutionPlanV2,
        region: JourneyExecutionRegionV2
    ) async -> RunOutcome? {
        guard region.plane == .device,
              let route = executionRoute,
              let definition = experience.definitionV2,
              let actions = try? definition.compiledDeviceRegionProgram(
                  route,
                  plan: plan,
                  region: region
              ) else {
            return .exited(.error)
        }
        // A claimed device region may be the suffix of a server-started plan.
        // Keep pre-presentation checkpointing active while its signed action
        // ownership allows effects before renderer attachment.
        isPrePresentationControlActive = true
        let cursor = region.entryCursor
        let versioned = await journey.versionedSnapshot()
        var checkpoint = versioned.snapshot
        checkpoint.executionState.plane = .device
        checkpoint.executionState.planId = plan.id
        checkpoint.executionState.routeRevisionSHA256 = route.revisionSHA256
        checkpoint.executionState.regionId = region.id
        checkpoint.executionState.cursorProgramPath = cursor.programPath
        checkpoint.executionState.cursorActionIndex = cursor.actionIndex
        checkpoint.executionState.currentNodeId = "\(cursor.programPath)/\(cursor.actionIndex)"
        let request = ActionRequest(
            actions: actions,
            context: TriggerContext(
                hostId: journeyEventHostKey,
                screenId: checkpoint.executionState.currentScreenId,
                componentId: nil,
                handlerId: "plan:\(plan.id)",
                instanceId: nil,
                payload: nil
            ),
            identity: .queued(handlerId: "plan:\(plan.id)")
        )
        checkpoint.executionState.prePresentationContinuation = [checkpointStep(request)]
        checkpoint.updatedAt = dateProvider.now()
        guard await persistEntryActionClaim(checkpoint) else {
            return nil
        }
        guard await journey.replace(checkpoint, ifRevisionEquals: versioned.revision) else {
            _ = await persistEntryActionClaim(await journey.snapshot())
            return nil
        }
        continuationQueue = materializePresentationContinuation(
            checkpoint.executionState.prePresentationContinuation ?? []
        )
        return await processQueue(resumeContext: nil)
    }

    private func experienceTriggerEventName() async -> String? {
        let triggerSnapshot = (await journey.snapshot()).triggerSnapshot
        guard let trigger = triggerSnapshot ?? experience.trigger else {
            return nil
        }
        if case .event(let config) = trigger {
            return config.eventName
        }
        return nil
    }

    private func enqueueActions(_ actions: [JourneyAction], context: TriggerContext) {
        guard !actions.isEmpty else { return }
        actionQueue.append(
            ActionRequest(
                actions: actions,
                context: context,
                identity: .queued(handlerId: context.handlerId)
            )
        )
    }

    private func processQueue(
        resumeContext _: ResumeContext?,
        runWhilePaused: Bool = false,
        stopAfterFirstRequest: Bool = false
    ) async -> RunOutcome? {
        if isProcessing {
            needsQueueDrain = true
            return nil
        }
        isProcessing = true
        needsQueueDrain = false
        defer { isProcessing = false }

        // Step budget: journeys are server-configured graphs; a handler cycle
        // (navigate → $screen_dismissed → handler → navigate...) would
        // otherwise busy-loop forever with the JourneyService actor blocked
        // behind it. 1000 steps is far beyond any legitimate experience.
        var executedSteps = 0
        let maxSteps = 1_000
        var startedRequest = false
        var shouldStopAfterFirstRequest = stopAfterFirstRequest
        var drainWhilePaused = runWhilePaused

        while !isPaused || drainWhilePaused {
            executedSteps += 1
            if executedSteps > maxSteps {
                LogError("JourneyRunner: step budget exceeded (\(maxSteps)) — exiting journey \(journey.id) as error (likely a handler cycle)")
                continuationQueue.removeAll()
                priorityActionQueue.removeAll()
                actionQueue.removeAll()
                sequenceStack.removeAll()
                return .exited(.error)
            }
            if sequenceStack.isEmpty {
                if shouldStopAfterFirstRequest, startedRequest, continuationQueue.isEmpty {
                    if priorityActionQueue.isEmpty {
                        if needsQueueDrain, !isPaused {
                            needsQueueDrain = false
                            shouldStopAfterFirstRequest = false
                        } else {
                            return nil
                        }
                    }
                }
                if continuationQueue.isEmpty,
                   priorityActionQueue.isEmpty,
                   actionQueue.isEmpty {
                    if needsQueueDrain {
                        needsQueueDrain = false
                        await Task.yield()
                        continue
                    }
                    return nil
                }
                let request: ActionRequest
                if shouldStartQueuedPriorityRequest {
                    request = priorityActionQueue.removeFirst()
                } else if !continuationQueue.isEmpty {
                    let item = continuationQueue.removeFirst()
                    switch item.operation {
                    case .request(let continuationRequest):
                        request = continuationRequest
                    case .pending(let pending):
                        let remaining = orderedContinuationSteps(
                            continuationQueue.map(checkpoint)
                                + priorityActionQueue.map(checkpointStep)
                                + actionQueue.map(checkpointStep)
                        )
                        let durablePending = remaining.isEmpty
                            ? pending
                            : pending.withContinuation(
                                (pending.continuation ?? []) + remaining
                            )
                        continuationQueue.removeAll()
                        priorityActionQueue.removeAll()
                        actionQueue.removeAll()
                        isPaused = true
                        await journey.update {
                            $0.executionState.prePresentationContinuation = nil
                            $0.executionState.pendingAction = durablePending
                        }
                        if !isPaused {
                            needsQueueDrain = false
                            continue
                        }
                        if needsQueueDrain || !priorityActionQueue.isEmpty {
                            continuationQueue.append(
                                ContinuationItem(
                                    rootId: item.rootId,
                                    operation: .pending(durablePending)
                                )
                            )
                            needsQueueDrain = false
                            drainWhilePaused = true
                            continue
                        }
                        return .paused(durablePending)
                    case .transfer(let handoff):
                        continuationQueue.removeAll()
                        priorityActionQueue.removeAll()
                        actionQueue.removeAll()
                        await journey.update { state in
                            Self.applyHandoffState(handoff, to: &state)
                        }
                        return .transferred(handoff)
                    case .exit(let reason):
                        continuationQueue.removeAll()
                        priorityActionQueue.removeAll()
                        actionQueue.removeAll()
                        return .exited(reason)
                    }
                } else if !priorityActionQueue.isEmpty {
                    request = priorityActionQueue.removeFirst()
                } else {
                    request = actionQueue.removeFirst()
                }
                startedRequest = true
                sequenceStack.append(
                    SequenceFrame(
                        rootId: request.rootId,
                        isPriority: request.isPriority,
                        identity: request.identity,
                        actions: request.actions,
                        context: request.context,
                        instructionIndex: request.startIndex,
                        resumeContext: request.resumeContext,
                        deferredResult: nil,
                        returnContext: .root
                    )
                )
            }

            guard let frame = sequenceStack.last else { continue }
            if frame.instructionIndex >= frame.actions.count {
                trackReturnAction(for: frame)
                sequenceStack.removeLast()
                continue
            }

            let frameIndex = sequenceStack.index(before: sequenceStack.endIndex)
            let action: JourneyAction
            let instructionIndex: Int
            let actionResult: ActionResult
            if let deferred = frame.deferredResult {
                action = deferred.action
                instructionIndex = deferred.instructionIndex
                actionResult = deferred.result
                sequenceStack[frameIndex].deferredResult = nil
            } else {
                instructionIndex = frame.instructionIndex
                action = frame.actions[instructionIndex]
                let actionResumeContext = frame.resumeContext
                sequenceStack[frameIndex].resumeContext = nil
                actionResult = await executeAction(
                    action,
                    context: frame.context,
                    index: instructionIndex,
                    resumeContext: actionResumeContext
                )
            }

            if !frame.isPriority, !priorityActionQueue.isEmpty {
                sequenceStack[frameIndex].deferredResult = DeferredActionResult(
                    action: action,
                    instructionIndex: instructionIndex,
                    result: actionResult
                )
                let request = priorityActionQueue.removeFirst()
                sequenceStack.append(
                    SequenceFrame(
                        rootId: request.rootId,
                        isPriority: request.isPriority,
                        identity: request.identity,
                        actions: request.actions,
                        context: request.context,
                        instructionIndex: request.startIndex,
                        resumeContext: request.resumeContext,
                        deferredResult: nil,
                        returnContext: .root
                    )
                )
                continue
            }

            switch actionResult {
            case .continue:
                sequenceStack[frameIndex].instructionIndex += 1
            case .present(let screenId, let transition):
                var continuation: [JourneyContinuationStep] = []
                appendRequest(
                    rootId: frame.rootId,
                    isPriority: frame.isPriority,
                    actions: frame.actions,
                    startIndex: instructionIndex + 1,
                    context: frame.context,
                    usesPendingResumeContext: false,
                    resumeContext: nil,
                    to: &continuation
                )
                appendFrameContinuations(below: frameIndex, to: &continuation)
                continuation.append(contentsOf: continuationQueue.map(checkpoint))
                continuation.append(contentsOf: priorityActionQueue.map(checkpointStep))
                continuation.append(contentsOf: actionQueue.map(checkpointStep))
                let pending = JourneyPendingPresentation(
                    experienceId: experience.id,
                    experienceVersionId: experience.versionId,
                    releaseID: experience.authenticatedReleaseID,
                    presentationStyle: experience.behaviorPresentationStyle ?? .fullScreen,
                    shell: experience.shellContract(screenId: screenId),
                    screenId: screenId,
                    transition: transition,
                    continuation: orderedContinuationSteps(continuation)
                )
                sequenceStack.removeAll()
                continuationQueue.removeAll()
                priorityActionQueue.removeAll()
                actionQueue.removeAll()
                await journey.update {
                    $0.executionState.prePresentationContinuation = nil
                    $0.executionState.pendingPresentation = pending
                }
                return .present(pending)
            case .pushSequence(let actions, let context, let identity):
                sequenceStack[frameIndex].instructionIndex += 1
                guard !actions.isEmpty else { continue }
                sequenceStack.append(
                    SequenceFrame(
                        rootId: frame.rootId,
                        isPriority: frame.isPriority,
                        identity: identity,
                        actions: actions,
                        context: context,
                        instructionIndex: 0,
                        resumeContext: nil,
                        deferredResult: nil,
                        returnContext: .action(
                            parent: frame.identity,
                            instructionIndex: instructionIndex,
                            action: action,
                            context: frame.context
                        )
                    )
                )
                if isPrePresentationControlActive,
                   !(await persistCurrentPrePresentationContinuation()) {
                    return .exited(.error)
                }
            case .stopSequence:
                trackAndDiscardCurrentRequestFrames()
            case .pause(let pending):
                let resumablePending = pending.withContinuation(
                    continuationAfterPause(
                        pending,
                        pausedFrameIndex: frameIndex,
                        pausedInstructionIndex: instructionIndex
                    )
                )
                isPaused = true
                trackPendingReturnActions()
                sequenceStack.removeAll()
                continuationQueue.removeAll()
                priorityActionQueue.removeAll()
                actionQueue.removeAll()
                await journey.update {
                    $0.executionState.prePresentationContinuation = nil
                    $0.executionState.pendingAction = resumablePending
                }
                if !isPaused {
                    needsQueueDrain = false
                    continue
                }
                if needsQueueDrain || !priorityActionQueue.isEmpty {
                    continuationQueue.append(
                        ContinuationItem(
                            rootId: frame.rootId,
                            operation: .pending(resumablePending)
                        )
                    )
                    needsQueueDrain = false
                    drainWhilePaused = true
                    continue
                }
                return .paused(resumablePending)
            case .transfer(let handoff):
                guard transferIsTerminal(
                    pausedFrameIndex: frameIndex,
                    instructionIndex: instructionIndex
                ) else {
                    LogError(
                        "JourneyRunner: handoff must terminate its outlet chain; rejecting trailing device work"
                    )
                    trackPendingReturnActions()
                    sequenceStack.removeAll()
                    continuationQueue.removeAll()
                    priorityActionQueue.removeAll()
                    actionQueue.removeAll()
                    return .exited(.error)
                }
                trackPendingReturnActions()
                sequenceStack.removeAll()
                continuationQueue.removeAll()
                priorityActionQueue.removeAll()
                actionQueue.removeAll()
                await journey.update { state in
                    Self.applyHandoffState(handoff, to: &state)
                }
                return .transferred(handoff)
            case .exit(let reason):
                trackPendingReturnActions()
                sequenceStack.removeAll()
                continuationQueue.removeAll()
                priorityActionQueue.removeAll()
                actionQueue.removeAll()
                return .exited(reason)
            }
        }

        return nil
    }

    private func executeAction(
        _ action: JourneyAction,
        context: TriggerContext,
        index: Int,
        resumeContext: ResumeContext?
    ) async -> ActionResult {
        if isPrePresentationControlActive,
           executionPlan == nil,
           !isAllowedBeforePresentation(action) {
            trackAction(
                action,
                context: context,
                error: "action is not valid before renderer attachment"
            )
            return .exit(.error)
        }
        guard await trackNodeTransitionIfNeeded(
            action,
            isResuming: resumeContext != nil
        ) else { return .exit(.error) }
        do {
            let result = try await performAction(
                action,
                context: context,
                index: index,
                resumeContext: resumeContext
            )
            if case .pushSequence = result {
                return result
            }
            trackAction(action, context: context, error: nil)
            return result
        } catch {
            trackAction(action, context: context, error: error.localizedDescription)
            return .exit(.error)
        }
    }

    private func isAllowedBeforePresentation(_ action: JourneyAction) -> Bool {
        switch action {
        case .navigate, .delay, .timeWindow, .waitUntil, .condition,
             .experiment, .deviceAvailable, .handoff, .exit:
            true
        default:
            false
        }
    }

    private func trackNodeTransitionIfNeeded(
        _ action: JourneyAction,
        isResuming: Bool
    ) async -> Bool {
        guard let nodeId = action.nodeId, !nodeId.isEmpty else { return true }
        let versioned = await journey.versionedSnapshot()
        let state = versioned.snapshot
        if state.executionState.currentNodeId == nodeId {
            return true
        }

        let previousNodeId = state.executionState.currentNodeId
        let eventState: JourneySnapshot
        if isPrePresentationControlActive {
            var checkpoint = state
            checkpoint.executionState.currentNodeId = nodeId
            checkpoint.executionState.prePresentationContinuation =
                currentInterpreterContinuation()
            checkpoint.updatedAt = dateProvider.now()
            guard await persistEntryActionClaim(checkpoint) else { return false }
            guard await journey.replace(
                checkpoint,
                ifRevisionEquals: versioned.revision
            ) else {
                _ = await persistEntryActionClaim(await journey.snapshot())
                return false
            }
            eventState = checkpoint
        } else {
            eventState = await journey.update { current in
                current.executionState.currentNodeId = nodeId
                current.updatedAt = dateProvider.now()
                return current
            }
        }
        guard emitsTransitionEvents, !eventState.isGhost else { return true }

        do {
            _ = try await eventLog.trackWithResponse(
                JourneyEvents.journeyTransition,
                properties: JourneyEvents.journeyTransitionProperties(
                    journey: eventState,
                    fromNode: previousNodeId,
                    toNode: nodeId,
                    region: eventState.executionState.regionId ?? "device-main"
                )
            )
        } catch {
            LogWarning(
                "JourneyRunner: Failed to persist transition to \(nodeId): \(error)"
            )
        }
        return true
    }

    /// Captures the exact already-selected interpreter suffix. Persisting it
    /// prevents a restored condition from selecting a different branch.
    private func currentInterpreterContinuation() -> [JourneyContinuationStep] {
        var continuation: [JourneyContinuationStep] = []
        if let frameIndex = sequenceStack.indices.last {
            let frame = sequenceStack[frameIndex]
            appendRequest(
                rootId: frame.rootId,
                isPriority: frame.isPriority,
                actions: frame.actions,
                startIndex: frame.instructionIndex,
                context: frame.context,
                usesPendingResumeContext: false,
                resumeContext: frame.resumeContext,
                to: &continuation
            )
            appendFrameContinuations(below: frameIndex, to: &continuation)
        }
        continuation.append(contentsOf: continuationQueue.map(checkpoint))
        continuation.append(contentsOf: priorityActionQueue.map(checkpointStep))
        continuation.append(contentsOf: actionQueue.map(checkpointStep))
        return orderedContinuationSteps(continuation)
    }

    private func persistCurrentPrePresentationContinuation() async -> Bool {
        let versioned = await journey.versionedSnapshot()
        var checkpoint = versioned.snapshot
        checkpoint.executionState.prePresentationContinuation =
            currentInterpreterContinuation()
        checkpoint.updatedAt = dateProvider.now()
        guard await persistEntryActionClaim(checkpoint) else { return false }
        guard await journey.replace(
            checkpoint,
            ifRevisionEquals: versioned.revision
        ) else {
            _ = await persistEntryActionClaim(await journey.snapshot())
            return false
        }
        return true
    }

    private func performAction(
        _ action: JourneyAction,
        context: TriggerContext,
        index: Int,
        resumeContext: ResumeContext?
    ) async throws -> ActionResult {
        switch action {
        case .navigate(let navigate):
            if isPrePresentationControlActive {
                guard !navigate.screenId.isEmpty else { return .exit(.error) }
                return .present(
                    screenId: navigate.screenId,
                    transition: navigate.transition
                )
            }
            await navigateToAction(navigate, context: context)
            return .stopSequence
        case .back(let back):
            await handleBack(back)
            return .stopSequence
        case .delay(let delay):
            return await handleDelay(delay, context: context, index: index, resumeContext: resumeContext)
        case .startAnimation:
            // The compiler lowers this command to a native Rive listener.
            // Recognize it here so transition tracking keeps its authored
            // node address without attempting duplicate playback.
            return .continue
        case .timeWindow(let timeWindow):
            return await handleTimeWindow(timeWindow, context: context, index: index, resumeContext: resumeContext)
        case .waitUntil(let waitUntil):
            return await handleWaitUntil(waitUntil, context: context, index: index, resumeContext: resumeContext)
        case .condition(let condition):
            return await handleCondition(condition, context: context)
        case .experiment(let experiment):
            return await handleExperiment(experiment, context: context)
        case .deviceAvailable(let deviceAvailable):
            // A device-owned signed plan has already crossed the compiler's
            // server-to-device availability edge, so the authored available
            // branch is authoritative even before renderer attachment. The
            // legacy host-presence fallback is retained only for non-v2 runs
            // and will be removed with the hard-cutover cleanup.
            return nestedSequence(
                executionPlan != nil
                    ? deviceAvailable.onAvailable
                    : (viewController == nil ? deviceAvailable.onUnavailable : deviceAvailable.onAvailable),
                context: context,
                nodeId: deviceAvailable.nodeId
            )
        case .milestone(let milestone):
            return await handleMilestone(milestone, context: context)
        case .sendEvent(let sendEvent):
            await handleSendEvent(sendEvent, context: context)
            return .continue
        case .updateCustomer(let updateCustomer):
            await handleUpdateCustomer(updateCustomer, context: context)
            return .continue
        case .setResponseField(let setResponseField):
            return try await handleSetResponseField(setResponseField, context: context, index: index)
        case .submitResponse(let submitResponse):
            return try await handleSubmitResponse(submitResponse, context: context, index: index)
        case .purchase(let purchase):
            return await handlePurchase(purchase, context: context)
        case .restore(let restore):
            return await handleRestore(restore, context: context)
        case .requestNotifications(let requestNotifications):
            return await handleRequestNotifications(requestNotifications, context: context)
        case .requestPermission(let requestPermission):
            return await handleRequestPermission(requestPermission, context: context)
        case .requestTracking(let requestTracking):
            return await handleRequestTracking(requestTracking, context: context)
        case .openLink(let openLink):
            return await handleOpenLink(openLink, context: context)
        case .dismiss(let dismiss):
            return await handleDismiss(dismiss, context: context)
        case .callDelegate(let callDelegate):
            await handleCallDelegate(callDelegate, context: context)
            return .continue
        case .connectorAction(let effect):
            return await handleConnectorEffect(
                effect,
                context: context,
                index: index,
                resumeContext: resumeContext
            )
        case .grantEntitlement(let effect):
            return await handleGrantEntitlementEffect(
                effect,
                context: context,
                index: index,
                resumeContext: resumeContext
            )
        case .setViewModel(let setViewModel):
            return await handleSetViewModel(setViewModel, context: context)
        case .fireTrigger(let fireTrigger):
            return await handleFireTrigger(fireTrigger, context: context)
        case .listInsert(let listInsert):
            var payload: [String: Any] = [
                "value": await resolveValueRefs(listInsert.value.value, context: context)
            ]
            if let insertIndex = listInsert.index {
                payload["index"] = insertIndex
            }
            return await performListOperation(.insert, path: listInsert.path, payload: payload, context: context)
        case .listRemove(let listRemove):
            return await performListOperation(
                .remove,
                path: listRemove.path,
                payload: ["index": listRemove.index],
                context: context
            )
        case .listSwap(let listSwap):
            return await performListOperation(
                .swap,
                path: listSwap.path,
                payload: ["from": listSwap.indexA, "to": listSwap.indexB],
                context: context
            )
        case .listMove(let listMove):
            return await performListOperation(
                .move,
                path: listMove.path,
                payload: ["from": listMove.from, "to": listMove.to],
                context: context
            )
        case .listSet(let listSet):
            return await performListOperation(
                .set,
                path: listSet.path,
                payload: [
                    "index": listSet.index,
                    "value": await resolveValueRefs(listSet.value.value, context: context),
                ],
                context: context
            )
        case .listClear(let listClear):
            return await performListOperation(.clear, path: listClear.path, payload: [:], context: context)
        case .handoff(let handoff):
            guard handoff.direction == "device_to_server" else {
                return .exit(.error)
            }
            return .transfer(handoff)
        case .exit(let exitAction):
            return .exit(JourneyExitReason.fromActionReason(exitAction.reason))
        case .unknown:
            return .continue
        }
    }

    private func navigateToAction(_ action: NavigateAction, context: TriggerContext) async {
        guard !action.screenId.isEmpty else { return }
        await navigate(to: action.screenId, transition: action.transition)
    }

    private func navigate(to screenId: String, transition: AnyCodable?) async {
        let state = await journey.snapshot()
        if let current = state.executionState.currentScreenId, current != screenId {
            await journey.update { $0.executionState.navigationStack.append(current) }
        }
        await sendShowScreen(screenId, transition: transition)
    }

    private func handleBack(_ action: BackAction) async {
        let steps = max(1, action.steps ?? 1)
        let currentStack = (await journey.snapshot()).executionState.navigationStack
        guard !currentStack.isEmpty else { return }

        var stack = currentStack
        let targetIndex = max(0, stack.count - steps)
        let target = stack[targetIndex]
        stack = Array(stack.prefix(targetIndex))
        let updatedStack = stack
        await journey.update { $0.executionState.navigationStack = updatedStack }
        await sendShowScreen(target, transition: action.transition)

        NotificationCenter.default.post(
            name: .nuxieBack,
            object: nil,
            userInfo: [
                "journeyId": journey.id,
                "experienceId": journey.experienceId,
                "steps": steps,
                "screenId": target
            ]
        )
    }

    private func handleDelay(
        _ action: DelayAction,
        context: TriggerContext,
        index: Int,
        resumeContext: ResumeContext?
    ) async -> ActionResult {
        let durationMs = max(0, action.durationMs)
        if durationMs <= 0 { return .continue }
        let resumeAt = dateProvider.date(byAddingTimeInterval: TimeInterval(durationMs) / 1000, to: dateProvider.now())
        return .pause(await makePendingAction(
            kind: .delay,
            context: context,
            index: index,
            resumeAt: resumeAt,
            condition: nil,
            maxTimeMs: nil
        ))
    }

    private func handleTimeWindow(
        _ action: TimeWindowAction,
        context: TriggerContext,
        index: Int,
        resumeContext: ResumeContext?
    ) async -> ActionResult {
        let decision = TimeWindowMath.evaluate(
            now: dateProvider.now(),
            startTime: action.startTime,
            endTime: action.endTime,
            daysOfWeek: action.daysOfWeek,
            timezone: TimeWindowMath.resolveTimezone(
                action.timezone,
                appDefault: experience.definitionV2?.appDefaultTimezone
            )
        )
        switch decision {
        case .malformed:
            return .continue
        case .inWindow:
            return nestedSequence(
                action.successActions ?? [],
                context: context,
                nodeId: action.nodeId
            )
        case .pause(let until):
            return .pause(await makePendingAction(
                kind: .timeWindow,
                context: context,
                index: index,
                resumeAt: until,
                condition: nil,
                maxTimeMs: nil
            ))
        }
    }

    private func handleWaitUntil(
        _ action: WaitUntilAction,
        context: TriggerContext,
        index: Int,
        resumeContext: ResumeContext?
    ) async -> ActionResult {
        let now = dateProvider.now()
        let canonicalCondition = action.condition ?? resumeContext?.pending.journeyCondition
        let legacyCondition = action.legacyCondition ?? resumeContext?.pending.condition
        let event = resumeContext?.event

        let ok: Bool
        if let condition = canonicalCondition {
            ok = await evalJourneyCondition(condition, event: event)
        } else {
            ok = await evalConditionIR(legacyCondition, event: event)
        }
        if ok {
            return nestedSequence(
                action.successActions ?? [],
                context: context,
                nodeId: action.nodeId
            )
        }

        let maxTimeMs = action.maxTimeMs > 0 ? action.maxTimeMs : resumeContext?.pending.maxTimeMs
        let startedAt = resumeContext?.pending.startedAt ?? now

        if let maxTimeMs {
            let deadline = startedAt.addingTimeInterval(TimeInterval(maxTimeMs) / 1000)
            if now >= deadline {
                return nestedSequence(
                    action.timeoutActions ?? [],
                    context: context,
                    nodeId: action.nodeId
                )
            }
            return .pause(await makePendingAction(
                kind: .waitUntil,
                context: context,
                index: index,
                resumeAt: deadline,
                condition: legacyCondition,
                journeyCondition: canonicalCondition,
                journeyWaitTrigger: canonicalCondition == nil ? nil : action.trigger,
                maxTimeMs: maxTimeMs,
                startedAt: startedAt,
                allowsResponseVersionRefresh: true
            ))
        }

        return .pause(await makePendingAction(
            kind: .waitUntil,
            context: context,
            index: index,
            resumeAt: nil,
            condition: legacyCondition,
            journeyCondition: canonicalCondition,
            journeyWaitTrigger: canonicalCondition == nil ? nil : action.trigger,
            maxTimeMs: nil,
            startedAt: startedAt,
            allowsResponseVersionRefresh: true
        ))
    }

    private func handleCondition(
        _ action: ConditionAction,
        context: TriggerContext
    ) async -> ActionResult {
        for branch in action.branches {
            let ok: Bool
            if let condition = branch.condition {
                ok = await evalJourneyCondition(condition, event: nil)
            } else {
                ok = await evalConditionIR(branch.legacyCondition, event: nil)
            }
            if ok {
                return nestedSequence(
                    branch.actions,
                    context: context,
                    nodeId: action.nodeId ?? branch.id
                )
            }
        }

        if let defaults = action.defaultActions {
            return nestedSequence(
                defaults,
                context: context,
                nodeId: action.nodeId
            )
        }

        return .continue
    }

    private func handleExperiment(
        _ action: ExperimentAction,
        context: TriggerContext
    ) async -> ActionResult {
        guard !action.variants.isEmpty else { return .continue }

        let experimentKey = action.experimentId
        let assignment = await getServerAssignment(experimentId: experimentKey)

        let initialState = await journey.snapshot()
        let resolution = ExperimentResolver.resolve(
            variantIds: action.variants.map(\.id),
            assignment: assignment,
            frozenVariantKey: getFrozenExperimentVariantKey(
                experimentKey: experimentKey,
                state: initialState
            ),
            hasEmittedExposure: hasEmittedExperimentExposure(
                experimentKey: experimentKey,
                state: initialState
            )
        )

        if let assignedKey = resolution.errorAssignedVariantKey, !initialState.isGhost {
            eventLog.track(
                JourneyEvents.experimentExposureError,
                properties: [
                    "experiment_key": experimentKey,
                    "variant_key": assignedKey,
                    "reason": "variant_not_found"
                ],
                userProperties: nil,
                userPropertiesSetOnce: nil
            )
            return .continue
        }

        guard let variantId = resolution.variantId,
              let variant = action.variants.first(where: { $0.id == variantId }) else {
            return .continue
        }

        if resolution.shouldFreezeVariant {
            await freezeExperimentVariantKey(experimentKey: experimentKey, variantKey: variant.id)
        }

        let now = dateProvider.now()
        let exposureState = await journey.update { state in
            state.setContext("_experiment_key", value: experimentKey, at: now)
            state.setContext("_variant_key", value: variant.id, at: now)
            return state
        }

        if !exposureState.isGhost {
            switch resolution.exposure {
            case .none:
                break
            case .real(let assignmentSource, let isHoldout):
                eventLog.track(
                    JourneyEvents.experimentExposure,
                    properties: JourneyEvents.experimentExposureProperties(
                        journey: exposureState,
                        experimentKey: experimentKey,
                        variantKey: variant.id,
                        experienceVersion: journey.experienceVersion,
                        isHoldout: isHoldout,
                        assignmentSource: assignmentSource
                    ),
                    userProperties: nil,
                    userPropertiesSetOnce: nil
                )
                await markExperimentExposureEmitted(experimentKey: experimentKey)
            case .fallback(let assignmentSource):
                eventLog.track(
                    JourneyEvents.experimentExposureFallback,
                    properties: [
                        "experiment_key": experimentKey,
                        "variant_key": variant.id,
                        "assignment_source": assignmentSource
                    ],
                    userProperties: nil,
                    userPropertiesSetOnce: nil
                )
                await markExperimentExposureEmitted(experimentKey: experimentKey)
            }
        }

        return nestedSequence(
            variant.actions,
            context: context,
            nodeId: action.nodeId ?? variant.id
        )
    }

    private func handleSendEvent(
        _ action: SendEventAction,
        context: TriggerContext
    ) async {
        let state = await journey.snapshot()
        guard !state.isGhost else { return }
        var properties: [String: Any] = [:]
        let resolvedPayload = await resolveJourneyRecord(action.payload ?? [:], payload: context.payload)
        for (key, value) in resolvedPayload {
            properties[key] = value
        }
        // Attribution enrichment uses the SDK-wide snake_case key
        // convention (journey_id/experience_id/screen_id), matching every
        // $-event and the scoped-event routing that reads `journey_id`.
        properties["journey_id"] = journey.id
        properties["experience_id"] = journey.experienceId
        if let screenId = context.screenId ?? state.executionState.currentScreenId {
            properties["screen_id"] = screenId
        }

        if capturesSendEvents {
            authoredEvents.append(AuthoredEvent(
                name: action.eventName,
                properties: resolvedPayload.mapValues(AnyCodable.init),
                hostId: context.hostId,
                screenId: context.screenId ?? state.executionState.currentScreenId,
                handlerId: context.handlerId
            ))
        } else {
            eventLog.track(
                action.eventName,
                properties: properties,
                userProperties: nil,
                userPropertiesSetOnce: nil
            )
        }

        if !capturesSendEvents {
            eventLog.track(
                JourneyEvents.eventSent,
                properties: JourneyEvents.eventSentProperties(
                    journey: state,
                    screenId: context.screenId ?? state.executionState.currentScreenId,
                    eventName: action.eventName,
                    eventProperties: properties
                ),
                userProperties: nil,
                userPropertiesSetOnce: nil
            )
        }
    }

    private func handleMilestone(
        _ action: MilestoneAction,
        context: TriggerContext
    ) async -> ActionResult {
        let state = await journey.snapshot()
        guard !state.isGhost else { return .continue }
        let milestoneId = action.milestoneId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !milestoneId.isEmpty else { return .continue }
        let resolvedScreenId = context.screenId ?? state.executionState.currentScreenId

        let trimmedLabel = action.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let label = trimmedLabel.isEmpty ? nil : trimmedLabel

        if let onMilestone {
            await onMilestone(milestoneId, label, resolvedScreenId, context.handlerId)
            return ((await journey.snapshot()).status.isLive && deferredDismissReason == nil) ? .continue : .stopSequence
        }

        do {
            _ = try await eventLog.trackWithResponse(
                JourneyEvents.journeyMilestone,
                properties: JourneyEvents.journeyMilestoneProperties(
                    journey: state,
                    milestoneId: milestoneId
                )
            )
        } catch {
            LogWarning("JourneyRunner: Failed to deliver journey milestone: \(error)")
        }
        return (await journey.snapshot()).status.isLive ? .continue : .stopSequence
    }
    private func handleUpdateCustomer(
        _ action: UpdateCustomerAction,
        context: TriggerContext
    ) async {
        let state = await journey.snapshot()
        guard !state.isGhost else { return }
        var attributes: [String: Any] = [:]
        for (key, value) in action.journeyAttributes {
            attributes[key] = await resolveJourneyValue(value, payload: context.payload)
        }

        identityService.setUserProperties(attributes)

        eventLog.track(
            JourneyEvents.customerUpdated,
            properties: JourneyEvents.customerUpdatedProperties(
                journey: state,
                screenId: context.screenId ?? state.executionState.currentScreenId,
                attributesUpdated: Array(attributes.keys)
            ),
            userProperties: nil,
            userPropertiesSetOnce: nil
        )
    }


    private static func screenEmissionValue(_ value: Any) -> ScreenEmissionValue {
        if value is NSNull { return .null }
        if let value = value as? Bool { return .bool(value) }
        if let value = value as? NSNumber { return .number(value.doubleValue) }
        if let value = value as? String { return .string(value) }
        if let value = value as? [Any] {
            return .array(value.map(screenEmissionValue))
        }
        if let value = value as? [String: Any] {
            return .object(value.mapValues(screenEmissionValue))
        }
        return .null
    }

    private func handleSetResponseField(
        _ action: SetResponseFieldAction,
        context: TriggerContext,
        index: Int
    ) async throws -> ActionResult {
        let resolvedValue = await resolveValueRefs(action.value.value, context: context)
        let responseWriteOperationId = responseOperationId(
            context: context,
            index: index,
            field: action.key,
            nodeId: action.nodeId
        )
        if let responseSessionModule, let responseSessionRun {
            let currentScreenId = (await journey.snapshot()).executionState.currentScreenId
            let responseScreenId = context.screenId ?? currentScreenId ?? ""
            let occurredAt = dateProvider.now().ISO8601Format()
            let result: ResponseSessionOperationResult
            do {
                if case .null = Self.screenEmissionValue(resolvedValue) {
                    result = try await responseSessionModule.unset(
                        run: responseSessionRun,
                        emissionId: responseWriteOperationId,
                        screenId: responseScreenId,
                        field: action.key,
                        occurredAt: occurredAt
                    )
                } else {
                    result = try await responseSessionModule.set(
                        run: responseSessionRun,
                        emissionId: responseWriteOperationId,
                        screenId: responseScreenId,
                        field: action.key,
                        value: Self.screenEmissionValue(resolvedValue),
                        occurredAt: occurredAt
                    )
                }
            } catch {
                didFailSetResponseField = true
                await markResponseRetryRequired(true)
                throw ResponseBranchAbort(
                    operation: "set_response_field",
                    diagnostic: "response_session_failed",
                    correlationId: responseWriteOperationId,
                    underlying: error.localizedDescription
                )
            }
            guard case .accepted = result else {
                didFailSetResponseField = true
                await markResponseRetryRequired(true)
                let diagnostic: String
                if case .rejected(let reason, _) = result {
                    diagnostic = reason.rawValue
                } else {
                    diagnostic = "response_session_rejected"
                }
                throw ResponseBranchAbort(
                    operation: "set_response_field",
                    diagnostic: diagnostic,
                    correlationId: responseWriteOperationId,
                    underlying: nil
                )
            }
        }
        do {
            didAttemptResponseDraftWrite = true
            // Boxed to hand the write-once value across the API boundary.
            let resolvedValueBox = UncheckedSendable(resolvedValue)
            let result = try await apiClient.setResponseField(
                distinctId: journey.distinctId,
                journeyId: journey.id,
                responseSchemaId: action.responseSchemaId,
                schemaVersion: action.schemaVersion,
                key: action.key,
                value: resolvedValueBox.value
            )
            didFailSetResponseField = false
            if let responseSessionModule, let responseSessionRun {
                do {
                    if let response = result.response {
                        let currentVersion = (try? await responseSessionModule.snapshot(journeyId: journey.id)?.version) ?? 0
                        if let snapshot = Self.responseSessionSnapshot(
                            from: response,
                            version: currentVersion + 1
                        ) {
                            _ = try await responseSessionModule.reconcile(
                                run: responseSessionRun,
                                operationId: "server:\(response.id):\(response.updatedAt.timeIntervalSince1970)",
                                snapshot: snapshot
                            )
                        }
                    } else {
                        _ = try await responseSessionModule.acknowledgeWrite(
                            run: responseSessionRun,
                            operationId: "server-write:\(responseWriteOperationId)"
                        )
                    }
                } catch {
                    didFailSetResponseField = true
                    await markResponseRetryRequired(true)
                    throw ResponseBranchAbort(
                        operation: "set_response_field",
                        diagnostic: "reconciliation_failed",
                        correlationId: responseWriteOperationId,
                        underlying: error.localizedDescription
                    )
                }
            }
            await markResponseRetryRequired(false)
        } catch let error as ResponseBranchAbort {
            throw error
        } catch {
            // Transient server failure must not kill the journey (executeAction
            // converts throws to .exit(.error)). The draft was already applied
            // locally; didFailSetResponseField keeps dismissal from abandoning
            // it, and the server reconciles on the next successful write.
            didFailSetResponseField = true
            await markResponseRetryRequired(true)
            throw ResponseBranchAbort(
                operation: "set_response_field",
                diagnostic: "server_write_failed",
                correlationId: responseWriteOperationId,
                underlying: error.localizedDescription
            )
        }

        return .continue
    }

    private func handleSubmitResponse(
        _ action: SubmitResponseAction,
        context: TriggerContext,
        index: Int
    ) async throws -> ActionResult {
        let responseSchema = experience.definitionV2?.responseSchema
        guard let responseSchemaId = action.responseSchemaId ?? responseSchema?.key else {
            throw NSError(
                domain: "Nuxie.JourneyRunner",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "submit_response requires the pinned response schema"]
            )
        }
        let schemaVersion = action.schemaVersion ?? responseSchema.flatMap { Int(exactly: $0.version) }
        let responseSubmitOperationId = responseOperationId(
            context: context,
            index: index,
            field: "submit",
            nodeId: action.nodeId
        )
        do {
            let result = try await apiClient.submitResponse(
                distinctId: journey.distinctId,
                journeyId: journey.id,
                responseSchemaId: responseSchemaId,
                schemaVersion: schemaVersion
            )
            if let responseSessionModule, let responseSessionRun {
                let expectedVersion = try await responseSessionModule.snapshot(journeyId: journey.id)?.version
                let sessionResult = try await responseSessionModule.submit(
                    run: responseSessionRun,
                    operationId: responseSubmitOperationId,
                    expectedVersion: expectedVersion,
                    occurredAt: dateProvider.now().ISO8601Format()
                )
                if case .rejected(let diagnostic, _) = sessionResult {
                    do {
                        if let response = result.response,
                           let snapshot = Self.responseSessionSnapshot(
                               from: response,
                               version: expectedVersion.map { $0 + 1 } ?? 1
                           ) {
                            _ = try await responseSessionModule.reconcile(
                                run: responseSessionRun,
                                operationId: "server:\(response.id):\(response.updatedAt.timeIntervalSince1970)",
                                snapshot: snapshot
                            )
                        } else {
                            _ = try await responseSessionModule.reconcileSubmission(
                                run: responseSessionRun,
                                operationId: responseOperationId(
                                    context: context,
                                    index: index,
                                    field: "submit-reconcile",
                                    nodeId: action.nodeId
                                ),
                                occurredAt: dateProvider.now().ISO8601Format()
                            )
                        }
                    } catch {
                        didFailSubmitResponse = true
                        await markResponseRetryRequired(true)
                        throw ResponseBranchAbort(
                            operation: "submit_response",
                            diagnostic: "\(diagnostic.rawValue):reconciliation_failed",
                            correlationId: responseSubmitOperationId,
                            underlying: error.localizedDescription
                        )
                    }
                    didFailSubmitResponse = true
                    await markResponseRetryRequired(true)
                    throw ResponseBranchAbort(
                        operation: "submit_response",
                        diagnostic: diagnostic.rawValue,
                        correlationId: responseSubmitOperationId,
                        underlying: nil
                    )
                }
            }
            didAttemptResponseDraftWrite = false
            didFailSubmitResponse = false
            await markResponseRetryRequired(false)
            _ = result.response
        } catch let error as ResponseBranchAbort {
            throw error
        } catch {
            // Same policy as set_response_field: a failed submit keeps the
            // journey alive; the draft stays local (didFailSubmitResponse
            // blocks abandonment) so the response is not lost.
            didFailSubmitResponse = true
            await markResponseRetryRequired(true)
            throw ResponseBranchAbort(
                operation: "submit_response",
                diagnostic: "server_submit_failed",
                correlationId: responseSubmitOperationId,
                underlying: error.localizedDescription
            )
        }

        return .continue
    }

    func shouldAbandonResponseDraftsAfterDismiss() async -> Bool {
        guard !didFailSetResponseField && !didFailSubmitResponse else { return false }
        if let responseSessionModule {
            if let snapshot = try? await responseSessionModule.snapshot(journeyId: journey.id) {
                return snapshot.state == .draft
            }
        }
        return false
    }

    func hasFailedResponseOperation() -> Bool {
        didFailSetResponseField || didFailSubmitResponse
    }

    private func markResponseRetryRequired(_ required: Bool) async {
        if let responseSessionModule {
            do {
                try await responseSessionModule.setRetryRequired(
                    journeyId: journey.id,
                    required: required
                )
            } catch {
                LogError("JourneyRunner: failed to persist response retry marker: \(error)")
                await journey.update { state in
                    state.responseSessionRetryRequired = required
                    state.updatedAt = dateProvider.now()
                }
                _ = await persistResponseRetryMarker(await journey.snapshot())
            }
        } else {
            await journey.update { state in
                state.responseSessionRetryRequired = required
                state.updatedAt = dateProvider.now()
            }
            _ = await persistResponseRetryMarker(await journey.snapshot())
        }
    }

    func abandonResponseDraftsIfNeeded(force: Bool = false) async {
        let hasDraft = if let responseSessionModule {
            if let snapshot = try? await responseSessionModule.snapshot(journeyId: journey.id) {
                snapshot.state == .draft
            } else {
                false
            }
        } else {
            false
        }
        guard force || hasDraft || didAttemptResponseDraftWrite else { return }

        do {
            let result = try await apiClient.abandonResponses(
                distinctId: journey.distinctId,
                journeyId: journey.id
            )
            didAttemptResponseDraftWrite = false
            for response in result.responses {
                _ = response
            }
        } catch {
            LogWarning("JourneyRunner: abandon response drafts failed: \(error.localizedDescription)")
        }
    }

    private func responseOperationId(
        context: TriggerContext,
        index: Int,
        field: String,
        nodeId: String?
    ) -> String {
        if let emissionId = context.payload?["__nuxie_emission_id"] as? String, !emissionId.isEmpty {
            return "\(emissionId):\(field):\(nodeId ?? ""):\(index)"
        }
        return "response:\(journey.id):\(context.handlerId ?? "entry"):\(context.screenId ?? ""):\(nodeId ?? field):\(index)"
    }

    private static func responseSessionSnapshot(
        from response: ResponseRecordPayload,
        version: UInt64
    ) -> ResponseSessionSnapshot? {
        guard let state = ResponseSessionState(rawValue: response.state) else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallback = ISO8601DateFormatter()
        let iso: (Date) -> String = { formatter.string(from: $0).isEmpty ? fallback.string(from: $0) : formatter.string(from: $0) }
        guard let responseId = try? deriveResponseSessionId(journeyId: response.journeyId) else { return nil }
        return ResponseSessionSnapshot(
            responseId: responseId,
            journeyId: response.journeyId,
            responseSchemaKey: response.responseSchemaId,
            responseSchemaVersionId: response.responseSchemaVersionId,
            schemaVersion: UInt64(response.schemaVersion),
            state: state,
            values: response.values.mapValues { Self.screenEmissionValue($0.value) },
            version: version,
            createdAt: iso(response.createdAt),
            updatedAt: iso(response.updatedAt),
            submittedAt: response.submittedAt.map(iso),
            abandonedAt: response.abandonedAt.map(iso)
        )
    }

    private func handleCallDelegate(
        _ action: CallDelegateAction,
        context: TriggerContext
    ) async {
        var userInfo: [String: Any] = [
            "message": action.message,
            "journeyId": journey.id,
            "experienceId": journey.experienceId,
        ]
        if let payload = action.journeyPayload {
            userInfo["payload"] = await resolveJourneyRecord(payload, payload: context.payload)
        }

        NotificationCenter.default.post(
            name: .nuxieCallDelegate,
            object: nil,
            userInfo: userInfo
        )

        let state = await journey.snapshot()
        guard !state.isGhost else { return }
        eventLog.track(
            JourneyEvents.delegateCalled,
            properties: JourneyEvents.delegateCalledProperties(
                journey: state,
                screenId: context.screenId ?? state.executionState.currentScreenId,
                message: action.message,
                payload: action.journeyPayload.map { $0.mapValues(\.foundationValue) }
            ),
            userProperties: nil,
            userPropertiesSetOnce: nil
        )
    }

    private func handlePurchase(
        _ action: PurchaseAction,
        context: TriggerContext
    ) async -> ActionResult {
        guard let controller = viewController else { return .continue }
        let resolvedPlacementId = await resolveJourneyValue(action.productId, payload: context.payload)
        let currentScreenId = (await journey.snapshot()).executionState.currentScreenId
        let resolvedScreenId = context.screenId ?? currentScreenId
        let placementId = resolvedPlacementId as? String
        guard let placementId, !placementId.isEmpty else {
            return .continue
        }
        if action.onCompleted != nil || action.onFailed != nil || action.onCancelled != nil {
            pendingPurchaseOutlets = (
                onCompleted: action.onCompleted,
                onFailed: action.onFailed,
                onCancelled: action.onCancelled,
                context: context
            )
            // Persist the chains: an app kill between performPurchase and the
            // outcome event previously dropped them silently.
            let persisted = PersistedOutcomeOutlets(
                first: action.onCompleted,
                second: action.onFailed,
                third: action.onCancelled,
                screenId: context.screenId,
                handlerId: context.handlerId,
                hostId: context.hostId
            )
            await journey.update { $0.executionState.pendingPurchaseOutlets = persisted }
        }
        await beginPaywallPurchaseStatus(screenId: resolvedScreenId)
        await MainActor.run {
            controller.performPurchase(placementId: placementId)
        }

        var userInfo: [String: Any] = [
            "journeyId": journey.id,
            "experienceId": journey.experienceId,
            "placementId": placementId
        ]
        if let screenId = resolvedScreenId {
            userInfo["screenId"] = screenId
        }
        NotificationCenter.default.post(
            name: .nuxiePurchase,
            object: nil,
            userInfo: userInfo
        )
        return .continue
    }

    private func handleRestore(
        _ action: RestoreAction,
        context: TriggerContext
    ) async -> ActionResult {
        guard let controller = viewController else { return .continue }
        if action.onRestored != nil || action.onNoPurchases != nil || action.onFailed != nil {
            pendingRestoreOutlets = (
                onRestored: action.onRestored,
                onNoPurchases: action.onNoPurchases,
                onFailed: action.onFailed,
                context: context
            )
            let persisted = PersistedOutcomeOutlets(
                first: action.onRestored,
                second: action.onNoPurchases,
                third: action.onFailed,
                screenId: context.screenId,
                handlerId: context.handlerId,
                hostId: context.hostId
            )
            await journey.update { $0.executionState.pendingRestoreOutlets = persisted }
        }
        let currentScreenId = (await journey.snapshot()).executionState.currentScreenId
        await beginPaywallRestoreStatus(screenId: context.screenId ?? currentScreenId)
        await MainActor.run {
            controller.performRestore()
        }
        var userInfo: [String: Any] = [
            "journeyId": journey.id,
            "experienceId": journey.experienceId
        ]
        if let screenId = context.screenId ?? currentScreenId {
            userInfo["screenId"] = screenId
        }
        NotificationCenter.default.post(
            name: .nuxieRestore,
            object: nil,
            userInfo: userInfo
        )
        return .continue
    }

    private func handleRequestNotifications(
        _ action: RequestNotificationsAction,
        context: TriggerContext
    ) async -> ActionResult {
        guard let controller = viewController else { return .continue }
        let journeyId = journey.id
        beginNotificationPermissionRequest()
        await MainActor.run {
            controller.performRequestNotifications(journeyId: journeyId)
        }
        return .continue
    }

    private func handleRequestPermission(
        _ action: RequestPermissionAction,
        context: TriggerContext
    ) async -> ActionResult {
        guard let controller = viewController else { return .continue }
        let journeyId = journey.id
        beginRequestPermissionRequest()
        await MainActor.run {
            controller.performRequestPermission(
                permissionType: action.permissionType,
                journeyId: journeyId
            )
        }
        return .continue
    }

    private func handleRequestTracking(
        _ action: RequestTrackingAction,
        context: TriggerContext
    ) async -> ActionResult {
        guard let controller = viewController else { return .continue }
        let journeyId = journey.id
        beginTrackingPermissionRequest()
        await MainActor.run {
            controller.performRequestTracking(journeyId: journeyId)
        }
        return .continue
    }

    private func handleOpenLink(
        _ action: OpenLinkAction,
        context: TriggerContext
    ) async -> ActionResult {
        guard let controller = viewController else { return .continue }
        let resolvedUrl = await resolveJourneyValue(action.journeyURL, payload: context.payload)
        guard let urlString = resolvedUrl as? String, !urlString.isEmpty else {
            return .continue
        }
        await MainActor.run {
            controller.performOpenLink(urlString: urlString, target: action.target)
        }
        var userInfo: [String: Any] = [
            "journeyId": journey.id,
            "experienceId": journey.experienceId,
            "url": urlString
        ]
        if let target = action.target {
            userInfo["target"] = target
        }
        let currentScreenId = (await journey.snapshot()).executionState.currentScreenId
        if let screenId = context.screenId ?? currentScreenId {
            userInfo["screenId"] = screenId
        }
        NotificationCenter.default.post(
            name: .nuxieOpenLink,
            object: nil,
            userInfo: userInfo
        )
        return .continue
    }

    private func handleDismiss(
        _ action: DismissAction,
        context: TriggerContext
    ) async -> ActionResult {
        guard let controller = viewController else {
            // A server-started plan can hand off a terminal device suffix
            // before a renderer is attached. Treat its signed dismiss as a
            // journey terminal action instead of silently leaving the run
            // active because there is no view controller to dismiss.
            return .exit(.dismissed)
        }
        await MainActor.run {
            controller.performDismiss(reason: .userDismissed)
        }
        return .stopSequence
    }

    private func handleConnectorEffect(
        _ action: ConnectorAction,
        context: TriggerContext,
        index: Int,
        resumeContext: ResumeContext?
    ) async -> ActionResult {
        let effect: [String: Any] = [
            "kind": "connector_tool",
            "account_ref": action.accountRef,
            "tool_key": action.toolKey,
        ]
        return await handleServerEffect(
            effect: effect,
            payload: await resolveJourneyRecord(action.journeyPayload, payload: context.payload),
            onSucceeded: action.onSucceeded,
            onFailed: action.onFailed,
            onTimeout: action.onTimeout,
            timeoutMs: action.timeoutMs ?? 120_000,
            authoredNodeId: action.nodeId,
            context: context,
            index: index,
            resumeContext: resumeContext
        )
    }

    private func handleGrantEntitlementEffect(
        _ action: GrantEntitlementAction,
        context: TriggerContext,
        index: Int,
        resumeContext: ResumeContext?
    ) async -> ActionResult {
        var effect: [String: Any] = [
            "kind": "grant_entitlement",
            "feature_id": action.featureId,
        ]
        if let balance = action.balance {
            effect["balance"] = balance
        }
        if let unlimited = action.unlimited {
            effect["unlimited"] = unlimited
        }
        return await handleServerEffect(
            effect: effect,
            payload: [:],
            onSucceeded: action.onSucceeded,
            onFailed: action.onFailed,
            onTimeout: action.onTimeout,
            timeoutMs: 120_000,
            authoredNodeId: action.nodeId,
            context: context,
            index: index,
            resumeContext: resumeContext
        )
    }

    private func handleServerEffect(
        effect: [String: Any],
        payload: Any,
        onSucceeded: [JourneyAction]?,
        onFailed: [JourneyAction]?,
        onTimeout: [JourneyAction]?,
        timeoutMs: Int,
        authoredNodeId: String?,
        context: TriggerContext,
        index: Int,
        resumeContext: ResumeContext?
    ) async -> ActionResult {
        let fallbackNodeId = await effectNodeId(context: context)
        let nodeId = authoredNodeId ?? fallbackNodeId
        let invocationId: String

        let initialState = await journey.snapshot()
        if initialState.isGhost {
            return nestedSequence(
                onFailed ?? [],
                context: context,
                nodeId: authoredNodeId
            )
        }

        if let resumeContext {
            invocationId = await activeEffectInvocationId(nodeId: nodeId)
            if case .event(let event) = resumeContext.reason,
               event.name == JourneyEvents.journeyEffectCompleted,
               event.properties["journey_id"] as? String == journey.id,
               event.properties["node_id"] as? String == nodeId,
               event.properties["invocation_id"] as? String == invocationId {
                await bindEffectResult(event.properties, nodeId: nodeId)
                let actions = event.properties["status"] as? String == "ok"
                    ? onSucceeded
                    : onFailed
                return nestedSequence(
                    actions ?? [],
                    context: context,
                    nodeId: authoredNodeId
                )
            }
            if case .timer = resumeContext.reason {
                return nestedSequence(
                    onTimeout ?? [],
                    context: context,
                    nodeId: authoredNodeId
                )
            }
        } else {
            let attempt = effectAttempt(nodeId: nodeId, state: initialState)
            invocationId = Self.effectInvocationId(
                journeyId: journey.id,
                nodeId: nodeId,
                attempt: attempt
            )
            eventLog.track(
                JourneyEvents.journeyEffectRequested,
                properties: [
                    "journey_id": journey.id,
                    "node_id": nodeId,
                    "invocation_id": invocationId,
                    "epoch": initialState.epoch,
                    "effect": effect,
                    "payload": payload,
                ],
                userProperties: nil,
                userPropertiesSetOnce: nil
            )
            // The event-log barrier acknowledges local row insertion before
            // JourneyService persists the paused checkpoint. A crash before
            // that checkpoint replays the same attempt/invocation and the
            // server ledger dedupes it.
            await eventLog.drain()
            await setEffectAttempt(attempt + 1, nodeId: nodeId)
        }

        let now = dateProvider.now()
        let startedAt = resumeContext?.pending.startedAt ?? now
        let boundedTimeoutMs = max(1, timeoutMs)
        let deadline = startedAt.addingTimeInterval(TimeInterval(boundedTimeoutMs) / 1000)
        if now >= deadline {
            return nestedSequence(
                onTimeout ?? [],
                context: context,
                nodeId: authoredNodeId
            )
        }
        return .pause(await makePendingAction(
            kind: .waitUntil,
            context: context,
            index: index,
            resumeAt: deadline,
            condition: effectCompletionCondition(
                nodeId: nodeId,
                invocationId: invocationId
            ),
            maxTimeMs: boundedTimeoutMs,
            startedAt: startedAt
        ))
    }

    private func effectNodeId(context: TriggerContext) async -> String {
        let currentScreenId = (await journey.snapshot()).executionState.currentScreenId
        return context.handlerId ?? context.screenId ?? currentScreenId ?? "unknown"
    }

    private func effectAttempt(nodeId: String, state: JourneySnapshot) -> Int {
        let attempts = state.context["_effect_attempts"]?.value as? [String: Any]
        if let value = attempts?[nodeId] as? Int {
            return max(0, value)
        }
        if let value = attempts?[nodeId] as? Double {
            return max(0, Int(value))
        }
        return 0
    }

    private func setEffectAttempt(_ attempt: Int, nodeId: String) async {
        let now = dateProvider.now()
        await journey.update { state in
            var attempts = state.context["_effect_attempts"]?.value as? [String: Any] ?? [:]
            attempts[nodeId] = max(0, attempt)
            state.setContext("_effect_attempts", value: attempts, at: now)
        }
    }

    private func activeEffectInvocationId(nodeId: String) async -> String {
        let state = await journey.snapshot()
        return Self.effectInvocationId(
            journeyId: journey.id,
            nodeId: nodeId,
            attempt: max(0, effectAttempt(nodeId: nodeId, state: state) - 1)
        )
    }

    nonisolated static func effectInvocationId(
        journeyId: String,
        nodeId: String,
        attempt: Int
    ) -> String {
        SHA256.hash(data: Data("\(journeyId):\(nodeId):\(attempt)".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func effectCompletionCondition(
        nodeId: String,
        invocationId: String
    ) -> IREnvelope {
        IREnvelope(
            ir_version: 1,
            engine_min: nil,
            compiled_at: nil,
            expr: .and([
                .event(op: "eq", key: "name", value: .string(JourneyEvents.journeyEffectCompleted)),
                .event(op: "eq", key: "properties.journey_id", value: .string(journey.id)),
                .event(op: "eq", key: "properties.node_id", value: .string(nodeId)),
                .event(
                    op: "eq",
                    key: "properties.invocation_id",
                    value: .string(invocationId)
                ),
            ])
        )
    }

    private func bindEffectResult(_ properties: [String: Any], nodeId: String) async {
        let propertiesBox = AnyCodable(properties)
        let now = dateProvider.now()
        await journey.update { state in
            var results = state.context["_effect_results"]?.value as? [String: Any] ?? [:]
            results[nodeId] = propertiesBox.value
            state.setContext("_effect_results", value: results, at: now)
        }
    }

    private func handleSetViewModel(
        _ action: SetViewModelAction,
        context: TriggerContext
    ) async -> ActionResult {
        let resolvedValue = await resolveValueRefs(action.value.value, context: context)
        let currentScreenId = (await journey.snapshot()).executionState.currentScreenId
        let screenId = context.screenId ?? currentScreenId
        _ = viewModelState.setValue(
            path: action.path,
            value: resolvedValue,
            screenId: screenId,
            instanceId: context.instanceId
        )
        let viewModelSnapshot = viewModelState.getSnapshot()
        await journey.update { $0.executionState.viewModelSnapshot = viewModelSnapshot }

        applyViewModelValue(
            path: action.path,
            value: resolvedValue,
            screenId: screenId,
            instanceId: context.instanceId
        )

        scheduleTriggerReset(
            path: action.path,
            screenId: screenId,
            instanceId: context.instanceId
        )

        return .continue
    }

    private func handleFireTrigger(
        _ action: FireTriggerAction,
        context: TriggerContext
    ) async -> ActionResult {
        let currentScreenId = (await journey.snapshot()).executionState.currentScreenId
        let screenId = context.screenId ?? currentScreenId
        let timestamp = Int(dateProvider.now().timeIntervalSince1970 * 1000)
        _ = viewModelState.setValue(
            path: action.path,
            value: timestamp,
            screenId: screenId,
            instanceId: context.instanceId
        )
        let viewModelSnapshot = viewModelState.getSnapshot()
        await journey.update { $0.executionState.viewModelSnapshot = viewModelSnapshot }

        fireViewModelTrigger(
            path: action.path,
            screenId: screenId,
            instanceId: context.instanceId
        )

        scheduleTriggerReset(
            path: action.path,
            screenId: screenId,
            instanceId: context.instanceId
        )

        return .continue
    }

    /// Shared execution for all list-mutation actions: apply to the state
    /// coordinator, and only on success snapshot + forward to the renderer.
    private func performListOperation(
        _ operation: ExperienceViewModelListOperation,
        path: VmPathRef,
        payload: [String: Any],
        context: TriggerContext
    ) async -> ActionResult {
        let currentScreenId = (await journey.snapshot()).executionState.currentScreenId
        let screenId = context.screenId ?? currentScreenId

        let ok = viewModelState.setListValue(
            path: path,
            operation: operation.rawValue,
            payload: payload,
            screenId: screenId,
            instanceId: context.instanceId
        )

        if ok {
            let viewModelSnapshot = viewModelState.getSnapshot()
            await journey.update { $0.executionState.viewModelSnapshot = viewModelSnapshot }
            applyViewModelListOperation(operation, path: path, payload: payload, screenId: screenId, instanceId: context.instanceId)
        }

        return .continue
    }

    private func nestedSequence(
        _ actions: [JourneyAction],
        context: TriggerContext,
        nodeId: String? = nil
    ) -> ActionResult {
        guard !actions.isEmpty else { return .continue }
        return .pushSequence(actions, context, .nested(nodeId: nodeId))
    }

    private func trackReturnAction(for frame: SequenceFrame) {
        guard case .action(_, _, let action, let context) = frame.returnContext else {
            return
        }
        trackAction(action, context: context, error: nil)
    }

    private func trackPendingReturnActions() {
        for frame in sequenceStack.reversed() {
            trackReturnAction(for: frame)
        }
    }

    /// Discards only the request currently at the top of the interpreter stack.
    /// Priority outlet and resume requests are represented by their own root frame,
    /// so stopping one must not erase an interrupted request below it.
    private func trackAndDiscardCurrentRequestFrames() {
        guard let rootId = sequenceStack.last?.rootId else { return }
        while sequenceStack.last?.rootId == rootId,
              let frame = sequenceStack.popLast() {
            trackReturnAction(for: frame)
        }
        while continuationQueue.first?.rootId == rootId {
            continuationQueue.removeFirst()
        }
    }

    private func continuationAfterPause(
        _ pending: JourneyPendingAction,
        pausedFrameIndex: Int,
        pausedInstructionIndex: Int,
        includeQueuedWork: Bool = true
    ) -> [JourneyContinuationStep] {
        let pausedFrame = sequenceStack[pausedFrameIndex]
        let resumeActions = pending.resumeActions ?? pausedFrame.actions
        let resumeIndex = pending.resumeActions == nil
            ? (pending.kind == .delay
                ? pausedInstructionIndex + 1
                : pausedInstructionIndex)
            : 0
        var steps: [JourneyContinuationStep] = []
        appendRequest(
            rootId: pausedFrame.rootId,
            isPriority: pausedFrame.isPriority,
            actions: resumeActions,
            startIndex: resumeIndex,
            context: pausedFrame.context,
            usesPendingResumeContext: true,
            resumeContext: nil,
            to: &steps
        )
        appendFrameContinuations(below: pausedFrameIndex, to: &steps)
        if includeQueuedWork {
            steps.append(contentsOf: continuationQueue.map(checkpoint))
            steps.append(contentsOf: priorityActionQueue.map(checkpointStep))
            steps.append(contentsOf: actionQueue.map(checkpointStep))
        }
        return orderedContinuationSteps(steps)
    }

    /// A selected priority root stays atomic, but a newly queued priority root
    /// must run before an interrupted normal continuation gets another action.
    private var shouldStartQueuedPriorityRequest: Bool {
        guard !priorityActionQueue.isEmpty else { return false }
        guard let first = continuationQueue.first else { return true }
        if case .request(let request) = first.operation {
            return !request.isPriority
        }
        return true
    }

    /// Checkpoints are grouped by root so priority roots keep FIFO order and
    /// remain atomic across persistence while moving ahead of normal roots.
    private func orderedContinuationSteps(
        _ steps: [JourneyContinuationStep]
    ) -> [JourneyContinuationStep] {
        guard !steps.isEmpty else { return [] }
        var groups: [[JourneyContinuationStep]] = []
        for step in steps {
            if groups.last?.last?.rootId == step.rootId {
                groups[groups.count - 1].append(step)
            } else {
                groups.append([step])
            }
        }
        let priorityGroups = groups.filter { group in
            group.contains { step in
                if case .request(let request) = step.operation {
                    return request.isPriority
                }
                return false
            }
        }
        let normalGroups = groups.filter { group in
            !group.contains { step in
                if case .request(let request) = step.operation {
                    return request.isPriority
                }
                return false
            }
        }
        return (priorityGroups + normalGroups).flatMap { $0 }
    }

    private func appendFrameContinuations(
        below frameIndex: Int,
        to steps: inout [JourneyContinuationStep]
    ) {
        var index = frameIndex - 1
        while index >= 0 {
            let frame = sequenceStack[index]
            guard let deferred = frame.deferredResult else {
                appendRequest(
                    rootId: frame.rootId,
                    isPriority: frame.isPriority,
                    actions: frame.actions,
                    startIndex: frame.instructionIndex,
                    context: frame.context,
                    usesPendingResumeContext: false,
                    resumeContext: frame.resumeContext,
                    to: &steps
                )
                index -= 1
                continue
            }

            switch deferred.result {
            case .continue:
                appendRequest(
                    rootId: frame.rootId,
                    isPriority: frame.isPriority,
                    actions: frame.actions,
                    startIndex: deferred.instructionIndex + 1,
                    context: frame.context,
                    usesPendingResumeContext: false,
                    resumeContext: nil,
                    to: &steps
                )
            case .present:
                appendRequest(
                    rootId: frame.rootId,
                    isPriority: frame.isPriority,
                    actions: frame.actions,
                    startIndex: deferred.instructionIndex,
                    context: frame.context,
                    usesPendingResumeContext: false,
                    resumeContext: nil,
                    to: &steps
                )
            case .pushSequence(let actions, let context, _):
                appendRequest(
                    rootId: frame.rootId,
                    isPriority: frame.isPriority,
                    actions: actions,
                    startIndex: 0,
                    context: context,
                    usesPendingResumeContext: false,
                    resumeContext: nil,
                    to: &steps
                )
                appendRequest(
                    rootId: frame.rootId,
                    isPriority: frame.isPriority,
                    actions: frame.actions,
                    startIndex: deferred.instructionIndex + 1,
                    context: frame.context,
                    usesPendingResumeContext: false,
                    resumeContext: nil,
                    to: &steps
                )
            case .stopSequence:
                index = nearestRootIndex(at: index) - 1
                continue
            case .pause(let pending):
                let preserved = pending.withContinuation(
                    continuationAfterPause(
                        pending,
                        pausedFrameIndex: index,
                        pausedInstructionIndex: deferred.instructionIndex,
                        includeQueuedWork: false
                    )
                )
                steps.append(
                    JourneyContinuationStep(
                        rootId: frame.rootId,
                        operation: .pending(preserved)
                    )
                )
                return
            case .transfer(let handoff):
                if transferIsTerminal(
                    pausedFrameIndex: index,
                    instructionIndex: deferred.instructionIndex
                ) {
                    steps.append(
                        JourneyContinuationStep(
                            rootId: frame.rootId,
                            operation: .transfer(handoff)
                        )
                    )
                } else {
                    steps.append(
                        JourneyContinuationStep(
                            rootId: frame.rootId,
                            operation: .exit(.error)
                        )
                    )
                }
                return
            case .exit(let reason):
                steps.append(
                    JourneyContinuationStep(
                        rootId: frame.rootId,
                        operation: .exit(reason)
                    )
                )
                return
            }
            index -= 1
        }
    }

    private func appendRequest(
        rootId: String,
        isPriority: Bool,
        actions: [JourneyAction],
        startIndex: Int,
        context: TriggerContext,
        usesPendingResumeContext: Bool,
        resumeContext: ResumeContext?,
        to steps: inout [JourneyContinuationStep]
    ) {
        guard startIndex < actions.count else { return }
        let request = ActionRequest(
            rootId: rootId,
            isPriority: isPriority,
            actions: actions,
            context: context,
            identity: .resumed(handlerId: context.handlerId),
            startIndex: max(0, startIndex),
            resumeContext: resumeContext
        )
        steps.append(
            JourneyContinuationStep(
                rootId: rootId,
                operation: .request(
                    checkpoint(
                        request,
                        usesPendingResumeContext: usesPendingResumeContext
                    )
                )
            )
        )
    }

    private func checkpoint(
        _ request: ActionRequest,
        usesPendingResumeContext: Bool
    ) -> JourneyContinuationRequest {
        JourneyContinuationRequest(
            rootId: request.rootId,
            isPriority: request.isPriority,
            actions: request.actions,
            hostId: request.context.hostId,
            screenId: request.context.screenId,
            componentId: request.context.componentId,
            handlerId: request.context.handlerId,
            instanceId: request.context.instanceId,
            payload: request.context.payload?.mapValues(AnyCodable.init),
            requiresTerminalTransfer: request.context.requiresTerminalTransfer,
            startIndex: request.startIndex,
            usesPendingResumeContext: usesPendingResumeContext,
            resume: request.resumeContext.map(checkpoint)
        )
    }

    private func checkpoint(_ item: ContinuationItem) -> JourneyContinuationStep {
        let operation: JourneyContinuationOperation
        switch item.operation {
        case .request(let request):
            operation = .request(checkpoint(request, usesPendingResumeContext: false))
        case .pending(let pending):
            operation = .pending(pending)
        case .transfer(let handoff):
            operation = .transfer(handoff)
        case .exit(let reason):
            operation = .exit(reason)
        }
        return JourneyContinuationStep(rootId: item.rootId, operation: operation)
    }

    private func checkpointStep(_ request: ActionRequest) -> JourneyContinuationStep {
        JourneyContinuationStep(
            rootId: request.rootId,
            operation: .request(
                checkpoint(request, usesPendingResumeContext: false)
            )
        )
    }

    private func checkpoint(_ resume: ResumeContext) -> JourneyContinuationResume {
        let reason: JourneyContinuationResumeReason
        switch resume.reason {
        case .start: reason = .start
        case .timer: reason = .timer
        case .event: reason = .event
        case .segmentChange: reason = .segmentChange
        }
        return JourneyContinuationResume(
            pending: resume.pending,
            reason: reason,
            event: resume.event.map { event in
                JourneyContinuationEvent(
                    id: event.id,
                    name: event.name,
                    distinctId: event.distinctId,
                    properties: event.properties.mapValues(AnyCodable.init),
                    timestamp: event.timestamp
                )
            }
        )
    }

    private func materializeContinuation(
        _ steps: [JourneyContinuationStep],
        pending: JourneyPendingAction,
        reason: ResumeReason,
        event: NuxieEvent?
    ) -> [ContinuationItem] {
        steps.map { step in
            let operation: ContinuationOperation
            switch step.operation {
            case .request(let request):
                let payload = request.usesPendingResumeContext
                    ? event?.properties
                    : request.payload?.mapValues(\.value)
                let context = TriggerContext(
                    hostId: request.hostId,
                    screenId: request.screenId,
                    componentId: request.componentId,
                    handlerId: request.handlerId,
                    instanceId: request.instanceId,
                    payload: payload,
                    requiresTerminalTransfer: request.requiresTerminalTransfer
                )
                let resumeContext: ResumeContext?
                if request.usesPendingResumeContext {
                    resumeContext = ResumeContext(
                        pending: pending,
                        reason: reason,
                        event: event
                    )
                } else {
                    resumeContext = request.resume.map(materialize)
                }
                operation = .request(
                    ActionRequest(
                        rootId: request.rootId,
                        isPriority: request.isPriority,
                        actions: request.actions,
                        context: context,
                        identity: .resumed(handlerId: request.handlerId),
                        startIndex: request.startIndex,
                        resumeContext: resumeContext
                    )
                )
            case .pending(let nestedPending):
                operation = .pending(nestedPending)
            case .transfer(let handoff):
                operation = .transfer(handoff)
            case .exit(let reason):
                operation = .exit(reason)
            }
            return ContinuationItem(rootId: step.rootId, operation: operation)
        }
    }

    private func materializePresentationContinuation(
        _ steps: [JourneyContinuationStep]
    ) -> [ContinuationItem] {
        steps.map { step in
            let operation: ContinuationOperation
            switch step.operation {
            case .request(let request):
                let context = TriggerContext(
                    hostId: request.hostId,
                    screenId: request.screenId,
                    componentId: request.componentId,
                    handlerId: request.handlerId,
                    instanceId: request.instanceId,
                    payload: request.payload?.mapValues(\.value),
                    requiresTerminalTransfer: request.requiresTerminalTransfer
                )
                operation = .request(
                    ActionRequest(
                        rootId: request.rootId,
                        isPriority: request.isPriority,
                        actions: request.actions,
                        context: context,
                        identity: .resumed(handlerId: request.handlerId),
                        startIndex: request.startIndex,
                        resumeContext: request.resume.map(materialize)
                    )
                )
            case .pending(let pending):
                operation = .pending(pending)
            case .transfer(let handoff):
                operation = .transfer(handoff)
            case .exit(let reason):
                operation = .exit(reason)
            }
            return ContinuationItem(rootId: step.rootId, operation: operation)
        }
    }

    private func materialize(_ resume: JourneyContinuationResume) -> ResumeContext {
        let event = resume.event.map {
            NuxieEvent(
                id: $0.id,
                name: $0.name,
                distinctId: $0.distinctId,
                properties: $0.properties.mapValues(\.value),
                timestamp: $0.timestamp
            )
        }
        let reason: ResumeReason
        switch resume.reason {
        case .start: reason = .start
        case .timer: reason = .timer
        case .event: reason = event.map(ResumeReason.event) ?? .segmentChange
        case .segmentChange: reason = .segmentChange
        }
        return ResumeContext(pending: resume.pending, reason: reason, event: event)
    }

    private func nearestRootIndex(at index: Int) -> Int {
        var rootIndex = index
        while rootIndex > 0 {
            if case .root = sequenceStack[rootIndex].returnContext { break }
            rootIndex -= 1
        }
        return rootIndex
    }

    private func transferIsTerminal(
        pausedFrameIndex: Int,
        instructionIndex: Int
    ) -> Bool {
        let rootIndex = nearestRootIndex(at: pausedFrameIndex)
        let rootId = sequenceStack[pausedFrameIndex].rootId
        var requiresTerminalTransfer = false
        for index in rootIndex...pausedFrameIndex {
            let frame = sequenceStack[index]
            guard frame.context.requiresTerminalTransfer else { continue }
            requiresTerminalTransfer = true
            let nextIndex = index == pausedFrameIndex
                ? instructionIndex + 1
                : frame.instructionIndex
            if nextIndex < frame.actions.count { return false }
        }
        if requiresTerminalTransfer,
           continuationQueue.contains(where: { $0.rootId == rootId }) {
            return false
        }
        return true
    }

    private nonisolated static func applyHandoffState(
        _ handoff: HandoffAction,
        to state: inout JourneySnapshot
    ) {
        state.executionState.regionId = handoff.toRegionId
        state.executionState.currentNodeId = handoff.toNodeId
        guard let separator = handoff.toNodeId.lastIndex(of: "/") else { return }
        let path = String(handoff.toNodeId[..<separator])
        let indexStart = handoff.toNodeId.index(after: separator)
        guard let index = Int(handoff.toNodeId[indexStart...]) else { return }
        state.executionState.cursorProgramPath = path
        state.executionState.cursorActionIndex = index
    }

    private func scheduleTriggerReset(
        path: VmPathRef,
        screenId: String?,
        instanceId: String?,
        notifyRenderer: Bool = true,
        force: Bool = false
    ) {
        guard force || viewModelState.isTriggerPath(path: path, screenId: screenId) else { return }
        let key = path.normalizedPath
        triggerResetTasks[key]?.cancel()
        triggerResetTasks[key] = Task { [weak self] in
            await Task.yield()
            guard let self else { return }
            await self.enqueueDeferredTriggerReset { [weak self] in
                // Hop into the actor: the queue's closure runs nonisolated —
                // mutating runner state here directly was one of the hidden
                // cross-context writes the actor conversion exists to stop.
                await self?.performTriggerReset(
                    path: path,
                    screenId: screenId,
                    instanceId: instanceId,
                    notifyRenderer: notifyRenderer
                )
            }
        }
    }

    /// Actor-isolated shim so trigger-reset tasks enqueue through the actor
    /// instead of touching deferredTaskQueue from a nonisolated Task body.
    private func enqueueDeferredTriggerReset(_ work: @escaping @Sendable () async -> Void) {
        deferredTaskQueue.enqueue(work)
    }

    private func performTriggerReset(
        path: VmPathRef,
        screenId: String?,
        instanceId: String?,
        notifyRenderer: Bool
    ) async {
        _ = viewModelState.setValue(path: path, value: 0, screenId: screenId, instanceId: instanceId)
        let viewModelSnapshot = viewModelState.getSnapshot()
        await journey.update { $0.executionState.viewModelSnapshot = viewModelSnapshot }
        if notifyRenderer {
            fireViewModelTrigger(path: path, screenId: screenId, instanceId: instanceId)
        }
    }

    private func resolveActions(
        handlerId: String,
        screenId: String?,
        componentId: String?
    ) -> [JourneyAction]? {
        handlerActionsById[handlerId]
    }
    private func makePendingAction(
        kind: JourneyPendingActionKind,
        context: TriggerContext,
        index: Int,
        resumeAt: Date?,
        condition: IREnvelope?,
        journeyCondition: JourneyCondition? = nil,
        journeyWaitTrigger: JourneyWaitTrigger? = nil,
        maxTimeMs: Int?,
        startedAt: Date? = nil,
        allowsResponseVersionRefresh: Bool = false
    ) async -> JourneyPendingAction {
        let responseVersion = (await journey.snapshot()).responseSession?.version
        return JourneyPendingAction(
            handlerId: context.handlerId ?? "entry",
            hostId: context.hostId,
            screenId: context.screenId,
            componentId: context.componentId,
            actionIndex: index,
            kind: kind,
            resumeAt: resumeAt,
            condition: condition,
            journeyCondition: journeyCondition,
            journeyWaitTrigger: journeyWaitTrigger,
            maxTimeMs: maxTimeMs,
            startedAt: startedAt ?? dateProvider.now(),
            responseVersion: responseVersion,
            allowsResponseVersionRefresh: allowsResponseVersionRefresh ? true : nil,
            resumeActions: nil,
            requiresTerminalTransfer: context.requiresTerminalTransfer ? true : nil
        )
    }

    private func trackAction(_ action: JourneyAction, context: TriggerContext, error: String?) {
        _ = action
        _ = context
        if let error {
            LogError("JourneyRunner: action failed: \(error)")
        }
    }

    private func applyInitialViewModelState() async {
        guard let controller = viewController else { return }
        let snapshot = viewModelState.getSnapshot()
        let screenId = (await journey.snapshot()).executionState.currentScreenId

        Task { @MainActor in
            controller.applyViewModelSnapshot(snapshot, screenId: screenId)
        }
    }

    private func applyViewModelValue(
        path: VmPathRef,
        value: Any,
        screenId: String?,
        instanceId: String? = nil
    ) {
        guard let controller = viewController else { return }
        // Boxed to hand the write-once value into the MainActor task.
        let valueBox = UncheckedSendable(value)
        Task { @MainActor in
            controller.applyViewModelValue(
                path: path,
                value: valueBox.value,
                screenId: screenId,
                instanceId: instanceId
            )
        }
    }

    private func beginPaywallPurchaseStatus(screenId: String?) async {
        await applyPaywallStatusWrites(paywallStatusProjector.beginPurchase(), screenId: screenId)
    }

    private func beginPaywallRestoreStatus(screenId: String?) async {
        await applyPaywallStatusWrites(paywallStatusProjector.beginRestore(), screenId: screenId)
    }

    private func projectPaywallStatus(from event: NuxieEvent) async {
        let screenId = (await journey.snapshot()).executionState.currentScreenId
        await applyPaywallStatusWrites(
            paywallStatusProjector.project(eventName: event.name, properties: event.properties),
            screenId: screenId
        )
    }

    private func applyPaywallStatusWrites(
        _ writes: [PaywallStatusProjector.Write],
        screenId: String?
    ) async {
        for write in writes {
            await updatePaywallCapabilityValue(path: write.path, value: write.value, screenId: screenId)
        }
    }

    private func updatePaywallCapabilityValue(
        path: String,
        value: Any,
        screenId: String?
    ) async {
        let pathRef = VmPathRef(path: path)
        guard viewModelState.setValue(path: pathRef, value: value, screenId: screenId) else { return }
        let viewModelSnapshot = viewModelState.getSnapshot()
        await journey.update { $0.executionState.viewModelSnapshot = viewModelSnapshot }
        applyViewModelValue(path: pathRef, value: value, screenId: screenId)
    }

    private func applyViewModelListOperation(
        _ operation: ExperienceViewModelListOperation,
        path: VmPathRef,
        payload: [String: Any],
        screenId: String?,
        instanceId: String? = nil
    ) {
        guard let controller = viewController else { return }
        // Boxed to hand the write-once payload into the MainActor task.
        let payloadBox = UncheckedSendable(payload)
        Task { @MainActor in
            controller.applyViewModelListOperation(
                operation,
                path: path,
                payload: payloadBox.value,
                screenId: screenId,
                instanceId: instanceId
            )
        }
    }

    private func fireViewModelTrigger(
        path: VmPathRef,
        screenId: String?,
        instanceId: String? = nil
    ) {
        guard let controller = viewController else { return }
        Task { @MainActor in
            controller.fireViewModelTrigger(
                path: path,
                screenId: screenId,
                instanceId: instanceId
            )
        }
    }

    private func sendShowScreen(_ screenId: String, transition: AnyCodable? = nil) async {
        if let onShowScreen {
            await onShowScreen(screenId, transition)
            return
        }
        guard let controller = viewController else { return }
        await MainActor.run {
            controller.navigate(to: screenId, transition: transition?.value)
        }
    }

    private func resolveValueRefs(_ value: Any, context: TriggerContext) async -> Any {
        let state = await journey.snapshot()
        let screenId = context.screenId ?? state.executionState.currentScreenId
        let resolver = ValueRefResolver(
            payload: context.payload,
            context: state.context.mapValues(\.value),
            lookup: { [viewModelState] path in
                viewModelState.getValue(
                    path: path,
                    screenId: screenId,
                    instanceId: context.instanceId
                )
            }
        )
        return resolver.resolve(value)
    }

    private func evalConditionIR(_ envelope: IREnvelope?, event: NuxieEvent?) async -> Bool {
        guard let envelope else { return true }

        let responseSession = (await journey.snapshot()).responseSession
        let config = irRuntime.standardConfig(
            event: event,
            responseSession: responseSession
        )

        return await irRuntime.eval(envelope, config)
    }

    private func evalJourneyCondition(_ condition: JourneyCondition, event: NuxieEvent?) async -> Bool {
        switch condition {
        case .truthy(let value):
            return Self.isTruthy(await resolveJourneyValue(value, event: event))
        case .compare(let op, let left, let right):
            let lhs = await resolveJourneyValue(left, event: event)
            let rhs = await resolveJourneyValue(right, event: event)
            switch op {
            case "==": return Self.jsonEqual(lhs, rhs)
            case "!=": return !Self.jsonEqual(lhs, rhs)
            case "<", "<=", ">", ">=":
                guard let comparison = Self.compareJSON(lhs, rhs) else { return false }
                switch op {
                case "<": return comparison < 0
                case "<=": return comparison <= 0
                case ">": return comparison > 0
                default: return comparison >= 0
                }
            default: return false
            }
        case .contains(let collection, let value):
            let haystack = await resolveJourneyValue(collection, event: event)
            let needle = await resolveJourneyValue(value, event: event)
            if let values = haystack as? [Any] {
                return values.contains { Self.jsonEqual($0, needle) }
            }
            if let string = haystack as? String, let needle = needle as? String {
                return string.contains(needle)
            }
            if let object = haystack as? [String: Any], let key = needle as? String {
                return object[key] != nil
            }
            return false
        case .all(let conditions):
            for condition in conditions where !(await evalJourneyCondition(condition, event: event)) {
                return false
            }
            return true
        case .any(let conditions):
            for condition in conditions where await evalJourneyCondition(condition, event: event) {
                return true
            }
            return false
        case .not(let condition):
            return !(await evalJourneyCondition(condition, event: event))
        }
    }

    private func resolveJourneyValue(_ value: JourneyValue, event: NuxieEvent?) async -> Any? {
        switch value {
        case .null: return nil
        case .bool(let value): return value
        case .number(let value): return value
        case .string(let value): return value
        case .array(let values):
            var result: [Any?] = []
            result.reserveCapacity(values.count)
            for value in values { result.append(await resolveJourneyValue(value, event: event)) }
            return result
        case .object(let values):
            var result: [String: Any] = [:]
            for (key, value) in values { result[key] = await resolveJourneyValue(value, event: event) }
            return result
        case .eventField(let key):
            return event?.properties[key]
        case .responseField(let key):
            if let responseSessionModule,
               let projection = try? await responseSessionModule.current(journeyId: journey.id),
               let value = projection.values[key] {
                return value.foundationValue
            }
            return nil
        }
    }

    private func resolveJourneyValue(_ value: JourneyValue, payload: [String: Any]?) async -> Any? {
        switch value {
        case .eventField(let key): return payload?[key]
        case .array(let values):
            var result: [Any?] = []
            result.reserveCapacity(values.count)
            for value in values {
                result.append(await resolveJourneyValue(value, payload: payload))
            }
            return result
        case .object(let values):
            var result: [String: Any] = [:]
            for (key, value) in values {
                result[key] = await resolveJourneyValue(value, payload: payload)
            }
            return result
        case .responseField:
            return await resolveJourneyValue(value, event: nil)
        case .null: return nil
        case .bool(let value): return value
        case .number(let value): return value
        case .string(let value): return value
        }
    }

    private func resolveJourneyRecord(
        _ values: [String: JourneyValue],
        payload: [String: Any]?
    ) async -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in values {
            result[key] = await resolveJourneyValue(value, payload: payload)
        }
        return result
    }

    private static func isTruthy(_ value: Any?) -> Bool {
        switch value {
        case nil: return false
        case let value as Bool: return value
        case let value as NSNumber: return value.doubleValue != 0
        case let value as String: return !value.isEmpty
        case let value as [Any]: return !value.isEmpty
        case let value as [String: Any]: return !value.isEmpty
        default: return true
        }
    }

    private static func jsonEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case (let lhs as NSNumber, let rhs as NSNumber): return lhs == rhs
        case (let lhs as String, let rhs as String): return lhs == rhs
        case (let lhs as Bool, let rhs as Bool): return lhs == rhs
        default:
            guard JSONSerialization.isValidJSONObject(["value": lhs as Any]),
                  JSONSerialization.isValidJSONObject(["value": rhs as Any]),
                  let left = try? JSONSerialization.data(withJSONObject: ["value": lhs as Any], options: [.sortedKeys]),
                  let right = try? JSONSerialization.data(withJSONObject: ["value": rhs as Any], options: [.sortedKeys]) else { return false }
            return left == right
        }
    }

    private static func compareJSON(_ lhs: Any?, _ rhs: Any?) -> Int? {
        if let lhs = lhs as? NSNumber, let rhs = rhs as? NSNumber {
            return lhs.doubleValue == rhs.doubleValue ? 0 : (lhs.doubleValue < rhs.doubleValue ? -1 : 1)
        }
        if let lhs = lhs as? String, let rhs = rhs as? String {
            return lhs == rhs ? 0 : (lhs < rhs ? -1 : 1)
        }
        return nil
    }

    private func getServerAssignment(experimentId: String) async -> ExperimentAssignment? {
        guard let profile = await profileService.getCachedProfile(distinctId: journey.distinctId) else {
            return nil
        }
        return profile.experiments?[experimentId]
    }

    // -------------------------------------------------------------------------
    // Experiment Exposure Dedupe + Freeze (journey-context persistence)
    // -------------------------------------------------------------------------

    private func getFrozenExperimentVariantKey(
        experimentKey: String,
        state: JourneySnapshot
    ) -> String? {
        ExperimentResolver.frozenVariantKey(
            in: state.getContext(ExperimentResolver.ContextKeys.frozenVariantsByExperiment),
            experimentKey: experimentKey
        )
    }

    private func freezeExperimentVariantKey(experimentKey: String, variantKey: String) async {
        guard !experimentKey.isEmpty, !variantKey.isEmpty else { return }
        let now = dateProvider.now()
        await journey.update { state in
            var dict = (state.getContext(ExperimentResolver.ContextKeys.frozenVariantsByExperiment) as? [String: Any]) ?? [:]
            dict[experimentKey] = variantKey
            state.setContext(ExperimentResolver.ContextKeys.frozenVariantsByExperiment, value: dict, at: now)
        }
    }

    private func hasEmittedExperimentExposure(
        experimentKey: String,
        state: JourneySnapshot
    ) -> Bool {
        ExperimentResolver.exposureEmitted(
            in: state.getContext(ExperimentResolver.ContextKeys.exposureEmittedByExperiment),
            experimentKey: experimentKey
        )
    }

    private func markExperimentExposureEmitted(experimentKey: String) async {
        guard !experimentKey.isEmpty else { return }
        let now = dateProvider.now()
        await journey.update { state in
            var dict = (state.getContext(ExperimentResolver.ContextKeys.exposureEmittedByExperiment) as? [String: Any]) ?? [:]
            dict[experimentKey] = true
            state.setContext(ExperimentResolver.ContextKeys.exposureEmittedByExperiment, value: dict, at: now)
        }
    }
}
