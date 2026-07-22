import Foundation

/// Actor: the runner's mutable execution state (actionQueue, activeRequest,
/// isProcessing, isPaused, outlet slots…) was previously a plain class driven
/// from the reentrant JourneyService actor — while one dispatch was suspended
/// mid-processQueue, the service could start another on a different thread:
/// a data race by construction. Actor isolation makes every entry point
/// serialize at suspension points with memory safety; the isProcessing/
/// needsQueueDrain pair still coalesces logically-reentrant drains (actor
/// reentrancy interleaves at awaits — isolation is not mutual exclusion
/// across suspension points).
actor JourneyRunner {
    // @unchecked Sendable: all stored properties are immutable (`let`); the
    // [String: Any] payload is a write-once snapshot never mutated after init.
    struct TriggerContext: @unchecked Sendable {
        let screenId: String?
        let componentId: String?
        let handlerId: String?
        let instanceId: String?
        let payload: [String: Any]?
    }

    enum RunOutcome: Sendable {
        case paused(FlowPendingAction)
        case exited(JourneyExitReason)
    }

    private enum ActionResult {
        case `continue`
        case stopSequence
        case pause(FlowPendingAction)
        case exit(JourneyExitReason)
    }

    private struct ActionRequest {
        let actions: [JourneyAction]
        let context: TriggerContext
    }

    private struct ResumeContext {
        let pending: FlowPendingAction
        let reason: ResumeReason
        let event: NuxieEvent?
    }

    private let journey: Journey
    private let campaign: Campaign
    private let flow: Experience
    private let screens: RemoteFlow
    private let viewModelState: ExperienceViewModelStateCoordinator
    private let onGoalHit: (@Sendable (_ goalId: String, _ goalLabel: String?, _ screenId: String?, _ handlerId: String?) async -> Void)?

    // Constructor-injected collaborators (Phase 4c composition root).
    private let eventLog: EventLogProtocol
    private let identityService: IdentityServiceProtocol
    private let segmentService: SegmentServiceProtocol
    private let featureService: FeatureServiceProtocol
    private let profileService: ProfileServiceProtocol
    private let apiClient: NuxieApiProtocol
    private let dateProvider: DateProviderProtocol
    private let irRuntime: IRRuntime

    weak var viewController: ExperienceViewController?
    var onShowScreen: (@Sendable (String, AnyCodable?) async -> Void)?

    func setOnShowScreen(_ handler: @escaping @Sendable (String, AnyCodable?) async -> Void) {
        onShowScreen = handler
    }
    private(set) var isRuntimeReady = false

    private var handlersByHost: [String: [JourneyEventHandler]] = [:]
    private var eventDeclarationsByHost: [String: [EventDeclaration]] = [:]
    private var handlerActionsById: [String: [JourneyAction]] = [:]
    private let journeyEventHostKey = RemoteFlow.journeyEventHostKey
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
    private var activeRequest: ActionRequest?
    private var activeIndex: Int = 0
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
    init(
        journey: Journey,
        campaign: Campaign,
        flow: Experience,
        onGoalHit: (@Sendable (_ goalId: String, _ goalLabel: String?, _ screenId: String?, _ handlerId: String?) async -> Void)? = nil,
        viewController: ExperienceViewController? = nil,
        eventLog: EventLogProtocol,
        identity: IdentityServiceProtocol,
        segments: SegmentServiceProtocol,
        features: FeatureServiceProtocol,
        profile: ProfileServiceProtocol,
        apiClient: NuxieApiProtocol,
        dateProvider: DateProviderProtocol,
        irRuntime: IRRuntime
    ) {
        self.journey = journey
        self.campaign = campaign
        self.flow = flow
        self.eventLog = eventLog
        self.identityService = identity
        self.segmentService = segments
        self.featureService = features
        self.profileService = profile
        self.apiClient = apiClient
        self.dateProvider = dateProvider
        self.irRuntime = irRuntime

        // Rehydrate persisted purchase/restore outlet chains (armed before an
        // app kill; the outcome may arrive via Transaction.updates this
        // session). Runtime payload context is not persisted — rebuild
        // addressing-only contexts.
        if let persisted = journey.flowState.pendingPurchaseOutlets {
            self.pendingPurchaseOutlets = (
                onCompleted: persisted.first,
                onFailed: persisted.second,
                onCancelled: persisted.third,
                context: TriggerContext(
                    screenId: persisted.screenId,
                    componentId: nil,
                    handlerId: persisted.handlerId,
                    instanceId: nil,
                    payload: nil
                )
            )
        }
        if let persisted = journey.flowState.pendingRestoreOutlets {
            self.pendingRestoreOutlets = (
                onRestored: persisted.first,
                onNoPurchases: persisted.second,
                onFailed: persisted.third,
                context: TriggerContext(
                    screenId: persisted.screenId,
                    componentId: nil,
                    handlerId: persisted.handlerId,
                    instanceId: nil,
                    payload: nil
                )
            )
        }
        self.screens = flow.screens
        self.viewModelState = ExperienceViewModelStateCoordinator(screens: flow.screens)
        self.onGoalHit = onGoalHit
        self.viewController = viewController

        self.handlersByHost = flow.screens.handlers.mapValues(Self.sortedHandlers)
        self.eventDeclarationsByHost = flow.screens.events
        self.handlerActionsById = Self.indexHandlerActions(flow.screens.handlers)

        if let snapshot = journey.flowState.viewModelSnapshot {
            viewModelState.hydrate(snapshot)
        } else {
            journey.flowState.viewModelSnapshot = viewModelState.getSnapshot()
        }

        // Rehydrate pause state: a runner rebuilt for a restored journey that
        // persisted a pendingAction must behave like the same-session paused
        // runner (event-handler dispatch suppressed until resumePendingAction
        // clears the pause). Outcome outlets still run while paused, exactly
        // as in-session.
        self.isPaused = journey.flowState.pendingAction != nil
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

    func handleRuntimeReady() async -> RunOutcome? {
        isRuntimeReady = true
        applyInitialViewModelState()

        if let current = journey.flowState.currentScreenId {
            await sendShowScreen(current)
            return nil
        }

        if journey.flowState.pendingAction == nil {
            let outcome = await runEntryActionsIfNeeded()
            if let outcome {
                return outcome
            }

            if journey.flowState.currentScreenId == nil {
                let fallback = screens.screens.first?.id
                if let fallback {
                    await navigate(to: fallback, transition: nil)
                }
            }
        }

        return nil
    }

    func handleScreenChanged(_ screenId: String) async -> RunOutcome? {
        journey.flowState.currentScreenId = screenId
        let event = makeSystemEvent(
            name: SystemEventNames.screenShown,
            properties: ["screen_id": screenId]
        )
        return await dispatchEventTrigger(event)
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
        let outcome = await dispatchJourneyEvent(event)

        let didRevealScreen = reconcileDismissedScreenState(
            dismissedScreenId: screenId,
            revealingScreenId: revealingScreenId
        )
        if let outcome { return outcome }

        guard didRevealScreen, let revealingScreenId, !revealingScreenId.isEmpty else { return nil }

        let shownEvent = makeSystemEvent(
            name: SystemEventNames.screenShown,
            properties: ["screen_id": revealingScreenId]
        )
        return await dispatchJourneyEvent(shownEvent)
    }

    @discardableResult
    private func reconcileDismissedScreenState(
        dismissedScreenId: String,
        revealingScreenId: String?
    ) -> Bool {
        guard let revealingScreenId, !revealingScreenId.isEmpty else {
            if journey.flowState.currentScreenId == dismissedScreenId {
                journey.flowState.currentScreenId = nil
            }
            return false
        }

        guard journey.flowState.currentScreenId == dismissedScreenId ||
            journey.flowState.currentScreenId == nil else {
            return false
        }

        if journey.flowState.navigationStack.last == revealingScreenId {
            journey.flowState.navigationStack.removeLast()
        } else if let index = journey.flowState.navigationStack.lastIndex(of: revealingScreenId) {
            journey.flowState.navigationStack = Array(journey.flowState.navigationStack.prefix(index))
        }

        journey.flowState.currentScreenId = revealingScreenId
        return true
    }

    func handleDidSet(
        path: VmPathRef,
        value: Any,
        source: String?,
        screenId: String?,
        instanceId: String?,
        isTrigger: Bool = false
    ) async -> RunOutcome? {
        let resolvedScreenId = screenId ?? journey.flowState.currentScreenId
        _ = viewModelState.setValue(
            path: path,
            value: value,
            screenId: resolvedScreenId,
            instanceId: instanceId
        )
        journey.flowState.viewModelSnapshot = viewModelState.getSnapshot()

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
        let resolved = resolveValueRefs(
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
            "campaignId": journey.campaignId,
            "url": urlString
        ]
        if let target {
            userInfo["target"] = target
        }
        if let resolvedScreenId = screenId ?? journey.flowState.currentScreenId {
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

    func dispatchJourneyEvent(_ event: NuxieEvent) async -> RunOutcome? {
        projectPaywallStatus(from: event)
        switch await runOutcomeOutlets(for: event) {
        case .consumed(let outcome):
            return outcome
        case .notConsumed:
            break
        }
        return await dispatchEvent(
            hostId: journeyEventHostKey,
            event: event,
            screenId: journey.flowState.currentScreenId,
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
            journey.flowState.pendingPurchaseOutlets = nil
            let chain: [JourneyAction]?
            switch event.name {
            case SystemEventNames.purchaseCompleted: chain = pending.onCompleted
            case SystemEventNames.purchaseFailed: chain = pending.onFailed
            default: chain = pending.onCancelled
            }
            guard let chain, !chain.isEmpty else { return .consumed(nil) }
            let result = await runNestedActions(chain, context: pending.context)
            if case .exit(let reason) = result { return .consumed(.exited(reason)) }
            if case .pause(let pendingAction) = result {
                return .consumed(.paused(recordOutletPause(pendingAction)))
            }
            return .consumed(nil)
        case SystemEventNames.restoreCompleted,
             SystemEventNames.restoreFailed,
             SystemEventNames.restoreNoPurchases:
            guard let pending = pendingRestoreOutlets else { return .notConsumed }
            pendingRestoreOutlets = nil
            journey.flowState.pendingRestoreOutlets = nil
            let chain: [JourneyAction]?
            switch event.name {
            case SystemEventNames.restoreCompleted: chain = pending.onRestored
            case SystemEventNames.restoreNoPurchases: chain = pending.onNoPurchases
            default: chain = pending.onFailed
            }
            guard let chain, !chain.isEmpty else { return .consumed(nil) }
            let result = await runNestedActions(chain, context: pending.context)
            if case .exit(let reason) = result { return .consumed(.exited(reason)) }
            if case .pause(let pendingAction) = result {
                return .consumed(.paused(recordOutletPause(pendingAction)))
            }
            return .consumed(nil)
        default:
            return .notConsumed
        }
    }

    /// Outlet chains run outside `processQueue`, so a pause inside them must
    /// record the paused state the same way the queue's pause path does —
    /// otherwise a scheduled resume finds no pending action and the rest of
    /// the chain is silently dropped.
    private func recordOutletPause(_ pending: FlowPendingAction) -> FlowPendingAction {
        isPaused = true
        journey.flowState.pendingAction = pending
        return pending
    }

    func dispatchScreenEvent(
        _ event: NuxieEvent,
        screenId: String?,
        componentId: String?,
        instanceId: String?
    ) async -> RunOutcome? {
        guard let hostId = screenId ?? journey.flowState.currentScreenId,
              !hostId.isEmpty else { return nil }

        if event.name == SystemEventNames.responseSet {
            return await runResponseSetBuiltIn(
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
    /// set_response_field action against the flow-scoped response schema, so
    /// scripts never carry schema ids. Drops the event when the flow declares
    /// no response schema or the payload is malformed (Experience Logic 2026-07-04).
    private func runResponseSetBuiltIn(
        _ event: NuxieEvent,
        screenId: String,
        componentId: String?,
        instanceId: String?
    ) async -> RunOutcome? {
        if isPaused { return nil }
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
                payload: event.properties
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

        if hostId != journeyEventHostKey,
           journey.flowState.currentScreenId == nil,
           !hostId.isEmpty {
            journey.flowState.currentScreenId = hostId
        }

        guard canDispatchEvent(hostId: hostId, event: event) else { return nil }
        let handlers = (handlersByHost[hostId] ?? []).filter {
            $0.enabled != false && $0.eventName == event.name
        }
        if handlers.isEmpty { return nil }

        for handler in handlers {
            enqueueActions(
                handler.actions,
                context: TriggerContext(
                    screenId: screenId,
                    componentId: componentId,
                    handlerId: handler.id,
                    instanceId: instanceId,
                    payload: event.properties
                )
            )
        }

        return await processQueue(resumeContext: nil)
    }

    func resumePendingAction(reason: ResumeReason, event: NuxieEvent?) async -> RunOutcome? {
        guard let pending = journey.flowState.pendingAction else { return nil }

        isPaused = false
        journey.flowState.pendingAction = nil

        let context = TriggerContext(
            screenId: pending.screenId,
            componentId: pending.componentId,
            handlerId: pending.handlerId,
            instanceId: nil,
            payload: event?.properties
        )

        if let resumeActions = pending.resumeActions {
            activeRequest = ActionRequest(actions: resumeActions, context: context)
            activeIndex = 0
        } else {
            guard let actions = resolveActions(
                handlerId: pending.handlerId,
                screenId: pending.screenId,
                componentId: pending.componentId
            ) else {
                return nil
            }
            activeRequest = ActionRequest(actions: actions, context: context)
            if pending.kind == .delay {
                activeIndex = pending.actionIndex + 1
            } else {
                activeIndex = pending.actionIndex
            }
        }

        let resumeContext = ResumeContext(pending: pending, reason: reason, event: event)
        return await processQueue(resumeContext: resumeContext)
    }

    func hasPendingWork() -> Bool {
        if pendingNotificationPermissionRequests > 0 { return true }
        if pendingRequestPermissionRequests > 0 { return true }
        if pendingTrackingPermissionRequests > 0 { return true }
        if journey.flowState.pendingAction != nil { return true }
        if activeRequest != nil { return true }
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
            return hostId == journeyEventHostKey
        }
        guard let payloadSchema = declaration.payloadSchema else {
            return true
        }
        return EventPayloadSchemaMatcher.matches(event.properties, schema: payloadSchema)
    }

    private func runEntryActionsIfNeeded() async -> RunOutcome? {
        // Idempotency: entry actions run at most once per journey. A restore
        // before the first screen previously replayed the whole entry chain
        // (re-firing sendEvent/purchase side effects).
        if journey.getContext("_entry_actions_ran") as? Bool == true {
            return nil
        }

        let handlers = handlersByHost[journeyEventHostKey] ?? []
        let enabledHandlers = handlers.filter { $0.enabled != false }
        if enabledHandlers.isEmpty { return nil }

        let campaignEventName = campaignTriggerEventName()
        // No heuristic fallback: only the campaign's trigger event or the
        // conventional $app_opened entry handler runs at entry. "Whatever
        // handler happens to be first" ran e.g. $purchase_completed chains
        // with a synthesized empty event.
        let preferredEventName =
            campaignEventName.flatMap { eventName in
                enabledHandlers.contains { $0.eventName == eventName } ? eventName : nil
            } ??
            (enabledHandlers.contains { $0.eventName == SystemEventNames.appOpened } ? SystemEventNames.appOpened : nil)
        guard let preferredEventName else { return nil }

        let matchingHandlers = enabledHandlers.filter { $0.eventName == preferredEventName }
        if matchingHandlers.isEmpty { return nil }

        // Mark BEFORE executing: a crash mid-chain must not replay side
        // effects (sendEvent/purchase) on restore. The pendingAction resume
        // path continues an interrupted chain; the entry gate only prevents
        // a full re-run.
        journey.setContext("_entry_actions_ran", value: true, at: dateProvider.now())

        let event = makeSystemEvent(name: preferredEventName, properties: [:])
        for handler in matchingHandlers {
            enqueueActions(
                handler.actions,
                context: TriggerContext(
                    screenId: journey.flowState.currentScreenId,
                    componentId: nil,
                    handlerId: handler.id,
                    instanceId: nil,
                    payload: event.properties
                )
            )
        }

        return await processQueue(resumeContext: nil)
    }

    private func campaignTriggerEventName() -> String? {
        let trigger = journey.triggerSnapshot ?? campaign.trigger
        if case .event(let config) = trigger {
            return config.eventName
        }
        return nil
    }

    private func enqueueActions(_ actions: [JourneyAction], context: TriggerContext) {
        guard !actions.isEmpty else { return }
        actionQueue.append(ActionRequest(actions: actions, context: context))
    }

    private func processQueue(resumeContext: ResumeContext?) async -> RunOutcome? {
        if isProcessing {
            needsQueueDrain = true
            return nil
        }
        isProcessing = true
        needsQueueDrain = false
        defer { isProcessing = false }

        var resumeContext = resumeContext

        // Step budget: journeys are server-configured graphs; a handler cycle
        // (navigate → $screen_dismissed → handler → navigate...) would
        // otherwise busy-loop forever with the JourneyService actor blocked
        // behind it. 1000 steps is far beyond any legitimate flow.
        var executedSteps = 0
        let maxSteps = 1_000

        while !isPaused {
            executedSteps += 1
            if executedSteps > maxSteps {
                LogError("JourneyRunner: step budget exceeded (\(maxSteps)) — exiting journey \(journey.id) as error (likely a handler cycle)")
                actionQueue.removeAll()
                activeRequest = nil
                activeIndex = 0
                return .exited(.error)
            }
            if activeRequest == nil {
                if actionQueue.isEmpty {
                    if needsQueueDrain {
                        needsQueueDrain = false
                        await Task.yield()
                        continue
                    }
                    return nil
                }
                activeRequest = actionQueue.removeFirst()
                activeIndex = 0
            }

            guard let request = activeRequest else { return nil }

            while activeIndex < request.actions.count {
                let action = request.actions[activeIndex]
                let actionResult = await executeAction(
                    action,
                    context: request.context,
                    index: activeIndex,
                    resumeContext: resumeContext
                )

                resumeContext = nil

                switch actionResult {
                case .continue:
                    activeIndex += 1
                case .stopSequence:
                    activeRequest = nil
                    activeIndex = 0
                    break
                case .pause(let pending):
                    let resumablePending = attachResumeActions(
                        to: pending,
                        from: request.actions,
                        pausedIndex: activeIndex
                    )
                    isPaused = true
                    journey.flowState.pendingAction = resumablePending
                    return .paused(resumablePending)
                case .exit(let reason):
                    return .exited(reason)
                }

                if case .stopSequence = actionResult {
                    break
                }
            }

            if activeIndex >= request.actions.count {
                activeRequest = nil
                activeIndex = 0
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
        // Unknown action types execute nothing and are not tracked.
        if case .unknown = action { return .continue }
        do {
            let result = try await performAction(
                action,
                context: context,
                index: index,
                resumeContext: resumeContext
            )
            trackAction(action, context: context, error: nil)
            return result
        } catch {
            trackAction(action, context: context, error: error.localizedDescription)
            return .exit(.error)
        }
    }

    private func performAction(
        _ action: JourneyAction,
        context: TriggerContext,
        index: Int,
        resumeContext: ResumeContext?
    ) async throws -> ActionResult {
        switch action {
        case .navigate(let navigate):
            await navigateToAction(navigate, context: context)
            return .stopSequence
        case .back(let back):
            await handleBack(back)
            return .stopSequence
        case .delay(let delay):
            return handleDelay(delay, context: context, index: index, resumeContext: resumeContext)
        case .timeWindow(let timeWindow):
            return await handleTimeWindow(timeWindow, context: context, index: index, resumeContext: resumeContext)
        case .waitUntil(let waitUntil):
            return await handleWaitUntil(waitUntil, context: context, index: index, resumeContext: resumeContext)
        case .condition(let condition):
            return await handleCondition(condition, context: context)
        case .experiment(let experiment):
            return await handleExperiment(experiment, context: context)
        case .goal(let goal):
            return await handleGoal(goal, context: context)
        case .sendEvent(let sendEvent):
            await handleSendEvent(sendEvent, context: context)
            return .continue
        case .updateCustomer(let updateCustomer):
            handleUpdateCustomer(updateCustomer, context: context)
            return .continue
        case .setResponseField(let setResponseField):
            return try await handleSetResponseField(setResponseField, context: context)
        case .submitResponse(let submitResponse):
            return try await handleSubmitResponse(submitResponse, context: context)
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
            handleCallDelegate(callDelegate, context: context)
            return .continue
        case .remote(let remote):
            return await handleRemote(remote, context: context, index: index)
        case .setViewModel(let setViewModel):
            return await handleSetViewModel(setViewModel, context: context)
        case .fireTrigger(let fireTrigger):
            return await handleFireTrigger(fireTrigger, context: context)
        case .listInsert(let listInsert):
            var payload: [String: Any] = [
                "value": resolveValueRefs(listInsert.value.value, context: context)
            ]
            if let insertIndex = listInsert.index {
                payload["index"] = insertIndex
            }
            return performListOperation(.insert, path: listInsert.path, payload: payload, context: context)
        case .listRemove(let listRemove):
            return performListOperation(
                .remove,
                path: listRemove.path,
                payload: ["index": listRemove.index],
                context: context
            )
        case .listSwap(let listSwap):
            return performListOperation(
                .swap,
                path: listSwap.path,
                payload: ["from": listSwap.indexA, "to": listSwap.indexB],
                context: context
            )
        case .listMove(let listMove):
            return performListOperation(
                .move,
                path: listMove.path,
                payload: ["from": listMove.from, "to": listMove.to],
                context: context
            )
        case .listSet(let listSet):
            return performListOperation(
                .set,
                path: listSet.path,
                payload: [
                    "index": listSet.index,
                    "value": resolveValueRefs(listSet.value.value, context: context),
                ],
                context: context
            )
        case .listClear(let listClear):
            return performListOperation(.clear, path: listClear.path, payload: [:], context: context)
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
        if let current = journey.flowState.currentScreenId, current != screenId {
            let event = makeSystemEvent(
                name: SystemEventNames.screenDismissed,
                properties: ["screen_id": current, "method": "navigate"]
            )
            _ = await dispatchEventTrigger(event)
            journey.flowState.navigationStack.append(current)
        }
        await sendShowScreen(screenId, transition: transition)
    }

    private func handleBack(_ action: BackAction) async {
        let steps = max(1, action.steps ?? 1)
        guard !journey.flowState.navigationStack.isEmpty else { return }

        var stack = journey.flowState.navigationStack
        let targetIndex = max(0, stack.count - steps)
        let target = stack[targetIndex]
        stack = Array(stack.prefix(targetIndex))
        journey.flowState.navigationStack = stack
        await sendShowScreen(target, transition: action.transition)

        NotificationCenter.default.post(
            name: .nuxieBack,
            object: nil,
            userInfo: [
                "journeyId": journey.id,
                "campaignId": journey.campaignId,
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
    ) -> ActionResult {
        let durationMs = max(0, action.durationMs)
        if durationMs <= 0 { return .continue }
        let resumeAt = dateProvider.date(byAddingTimeInterval: TimeInterval(durationMs) / 1000, to: dateProvider.now())
        return .pause(makePendingAction(
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
            timezone: TimeWindowMath.resolveTimezone(action.timezone)
        )
        switch decision {
        case .malformed:
            return .continue
        case .inWindow:
            return await runNestedActions(action.successActions ?? [], context: context)
        case .pause(let until):
            return .pause(makePendingAction(
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
        let condition = action.condition ?? resumeContext?.pending.condition
        let event = resumeContext?.event

        let ok = await evalConditionIR(condition, event: event)
        if ok {
            return .continue
        }

        let maxTimeMs = action.maxTimeMs ?? resumeContext?.pending.maxTimeMs
        let startedAt = resumeContext?.pending.startedAt ?? now

        if let maxTimeMs {
            let deadline = startedAt.addingTimeInterval(TimeInterval(maxTimeMs) / 1000)
            if now >= deadline {
                return .continue
            }
            return .pause(makePendingAction(
                kind: .waitUntil,
                context: context,
                index: index,
                resumeAt: deadline,
                condition: condition,
                maxTimeMs: maxTimeMs,
                startedAt: startedAt
            ))
        }

        return .pause(makePendingAction(
            kind: .waitUntil,
            context: context,
            index: index,
            resumeAt: nil,
            condition: condition,
            maxTimeMs: nil,
            startedAt: startedAt
        ))
    }

    private func handleCondition(
        _ action: ConditionAction,
        context: TriggerContext
    ) async -> ActionResult {
        for branch in action.branches {
            let ok = await evalConditionIR(branch.condition, event: nil)
            if ok {
                let result = await runNestedActions(branch.actions, context: context)
                return result
            }
        }

        if let defaults = action.defaultActions {
            return await runNestedActions(defaults, context: context)
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

        let resolution = ExperimentResolver.resolve(
            variantIds: action.variants.map(\.id),
            assignment: assignment,
            frozenVariantKey: getFrozenExperimentVariantKey(experimentKey: experimentKey),
            hasEmittedExposure: hasEmittedExperimentExposure(experimentKey: experimentKey)
        )

        if let assignedKey = resolution.errorAssignedVariantKey {
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
            freezeExperimentVariantKey(experimentKey: experimentKey, variantKey: variant.id)
        }

        journey.setContext("_experiment_key", value: experimentKey, at: dateProvider.now())
        journey.setContext("_variant_key", value: variant.id, at: dateProvider.now())

        switch resolution.exposure {
        case .none:
            break
        case .real(let assignmentSource, let isHoldout):
            eventLog.track(
                JourneyEvents.experimentExposure,
                properties: JourneyEvents.experimentExposureProperties(
                    journey: journey,
                    experimentKey: experimentKey,
                    variantKey: variant.id,
                    flowId: journey.flowId,
                    isHoldout: isHoldout,
                    assignmentSource: assignmentSource
                ),
                userProperties: nil,
                userPropertiesSetOnce: nil
            )
            markExperimentExposureEmitted(experimentKey: experimentKey)
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
            markExperimentExposureEmitted(experimentKey: experimentKey)
        }

        return await runNestedActions(variant.actions, context: context)
    }

    private func handleSendEvent(
        _ action: SendEventAction,
        context: TriggerContext
    ) async {
        var properties: [String: Any] = [:]
        if let props = action.properties {
            for (key, value) in props { properties[key] = value.value }
        }
        // Attribution enrichment uses the SDK-wide snake_case key
        // convention (journey_id/campaign_id/screen_id), matching every
        // $-event and the scoped-event routing that reads `journey_id`.
        properties["journey_id"] = journey.id
        properties["campaign_id"] = journey.campaignId
        if let screenId = context.screenId ?? journey.flowState.currentScreenId {
            properties["screen_id"] = screenId
        }

        eventLog.track(
            action.eventName,
            properties: properties,
            userProperties: nil,
            userPropertiesSetOnce: nil
        )

        eventLog.track(
            JourneyEvents.eventSent,
            properties: JourneyEvents.eventSentProperties(
                journey: journey,
                screenId: context.screenId ?? journey.flowState.currentScreenId,
                eventName: action.eventName,
                eventProperties: properties
            ),
            userProperties: nil,
            userPropertiesSetOnce: nil
        )
    }

    private func handleGoal(
        _ action: GoalAction,
        context: TriggerContext
    ) async -> ActionResult {
        let goalId = action.goalId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goalId.isEmpty else { return .continue }
        let resolvedScreenId = context.screenId ?? journey.flowState.currentScreenId

        let trimmedLabel = action.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let goalLabel = trimmedLabel.isEmpty ? nil : trimmedLabel

        if let onGoalHit {
            await onGoalHit(goalId, goalLabel, resolvedScreenId, context.handlerId)
            return (journey.status.isLive && deferredDismissReason == nil) ? .continue : .stopSequence
        }

        eventLog.track(
            JourneyEvents.journeyGoalHit,
            properties: JourneyEvents.journeyGoalHitProperties(
                journey: journey,
                screenId: resolvedScreenId,
                handlerId: context.handlerId,
                goalId: goalId,
                goalLabel: goalLabel
            ),
            userProperties: nil,
            userPropertiesSetOnce: nil
        )
        return journey.status.isLive ? .continue : .stopSequence
    }
    private func handleUpdateCustomer(
        _ action: UpdateCustomerAction,
        context: TriggerContext
    ) {
        var attributes: [String: Any] = [:]
        for (key, value) in action.attributes {
            attributes[key] = value.value
        }

        identityService.setUserProperties(attributes)

        eventLog.track(
            JourneyEvents.customerUpdated,
            properties: JourneyEvents.customerUpdatedProperties(
                journey: journey,
                screenId: context.screenId ?? journey.flowState.currentScreenId,
                attributesUpdated: Array(attributes.keys)
            ),
            userProperties: nil,
            userPropertiesSetOnce: nil
        )
    }


    /// Resolved screen/instance addressing plus the response view-model
    /// header the renderer currently displays.
    private func responseRuntimeContext(
        _ context: TriggerContext
    ) -> (runtime: ResponseFormController.RuntimeContext, screenId: String?, instanceId: String?) {
        let screenId = context.screenId ?? journey.flowState.currentScreenId
        let instanceId = context.instanceId
        let runtime = ResponseFormController.readRuntimeContext { [viewModelState] path in
            viewModelState.getValue(path: path, screenId: screenId, instanceId: instanceId)
        }
        return (runtime, screenId, instanceId)
    }

    private func applyResponsePatches(
        _ patches: [ResponseFormController.Patch],
        screenId: String?,
        instanceId: String?
    ) {
        for patch in patches {
            _ = viewModelState.setValue(
                path: patch.path,
                value: patch.value,
                screenId: screenId,
                instanceId: instanceId
            )
            applyViewModelValue(
                path: patch.path,
                value: patch.value,
                screenId: screenId,
                instanceId: instanceId
            )
        }
    }

    private func updateJourneyResponseCache(_ response: ResponseRecordPayload) {
        let updated = ResponseFormController.updatedResponseCache(
            journey.getContext("responses") as? [String: Any],
            adding: response
        )
        journey.setContext("responses", value: updated, at: dateProvider.now())
    }

    private func applyResponseRecordToRuntime(
        _ response: ResponseRecordPayload,
        context: TriggerContext,
        touchedFieldKey: String? = nil
    ) {
        let (runtime, screenId, instanceId) = responseRuntimeContext(context)
        guard ResponseFormController.contextMatches(
            runtime,
            responseSchemaId: response.responseSchemaId,
            schemaVersion: response.schemaVersion
        ) else {
            return
        }

        applyResponsePatches(
            ResponseFormController.recordPatches(for: response, touchedFieldKey: touchedFieldKey),
            screenId: screenId,
            instanceId: instanceId
        )
        journey.flowState.viewModelSnapshot = viewModelState.getSnapshot()
    }

    private func handleSetResponseField(
        _ action: SetResponseFieldAction,
        context: TriggerContext
    ) async throws -> ActionResult {
        let resolvedValue = resolveValueRefs(action.value.value, context: context)
        let (runtime, screenId, instanceId) = responseRuntimeContext(context)
        if ResponseFormController.contextMatches(
            runtime,
            responseSchemaId: action.responseSchemaId,
            schemaVersion: action.schemaVersion
        ) {
            applyResponsePatches(
                ResponseFormController.draftPatches(key: action.key, resolvedValue: resolvedValue),
                screenId: screenId,
                instanceId: instanceId
            )
            journey.flowState.viewModelSnapshot = viewModelState.getSnapshot()
        }

        do {
            didAttemptResponseDraftWrite = true
            // Boxed to hand the write-once value across the API boundary.
            let resolvedValueBox = UncheckedSendable(resolvedValue)
            let result = try await apiClient.setResponseField(
                distinctId: journey.distinctId,
                journeySessionId: journey.id,
                responseSchemaId: action.responseSchemaId,
                schemaVersion: action.schemaVersion,
                key: action.key,
                value: resolvedValueBox.value
            )
            didFailSetResponseField = false
            if let response = result.response {
                updateJourneyResponseCache(response)
                applyResponseRecordToRuntime(
                    response,
                    context: context,
                    touchedFieldKey: action.key
                )
            }
        } catch {
            // Transient server failure must not kill the journey (executeAction
            // converts throws to .exit(.error)). The draft was already applied
            // locally; didFailSetResponseField keeps dismissal from abandoning
            // it, and the server reconciles on the next successful write.
            didFailSetResponseField = true
            LogWarning("JourneyRunner: set_response_field failed: \(error.localizedDescription)")
        }

        return .continue
    }

    private func handleSubmitResponse(
        _ action: SubmitResponseAction,
        context: TriggerContext
    ) async throws -> ActionResult {
        do {
            let result = try await apiClient.submitResponse(
                distinctId: journey.distinctId,
                journeySessionId: journey.id,
                responseSchemaId: action.responseSchemaId,
                schemaVersion: action.schemaVersion
            )
            didAttemptResponseDraftWrite = false
            didFailSubmitResponse = false
            if let response = result.response {
                updateJourneyResponseCache(response)
                applyResponseRecordToRuntime(response, context: context)
            }
        } catch {
            // Same policy as set_response_field: a failed submit keeps the
            // journey alive; the draft stays local (didFailSubmitResponse
            // blocks abandonment) so the response is not lost.
            didFailSubmitResponse = true
            LogWarning("JourneyRunner: submit_response failed: \(error.localizedDescription)")
        }

        return .continue
    }

    func shouldAbandonResponseDraftsAfterDismiss() -> Bool {
        !didFailSetResponseField && !didFailSubmitResponse
    }

    func abandonResponseDraftsIfNeeded() async {
        let hasDrafts = ResponseFormController.hasDraftResponses(
            journey.getContext("responses") as? [String: Any]
        )
        guard hasDrafts || didAttemptResponseDraftWrite else { return }

        do {
            let result = try await apiClient.abandonResponses(
                distinctId: journey.distinctId,
                journeySessionId: journey.id
            )
            didAttemptResponseDraftWrite = false
            for response in result.responses {
                updateJourneyResponseCache(response)
                applyResponseRecordToRuntime(
                    response,
                    context: TriggerContext(
                        screenId: journey.flowState.currentScreenId,
                        componentId: nil,
                        handlerId: nil,
                        instanceId: nil,
                        payload: nil
                    )
                )
            }
        } catch {
            LogWarning("JourneyRunner: abandon response drafts failed: \(error.localizedDescription)")
        }
    }

    private func handleCallDelegate(
        _ action: CallDelegateAction,
        context: TriggerContext
    ) {
        var userInfo: [String: Any] = [
            "message": action.message,
            "journeyId": journey.id,
            "campaignId": journey.campaignId,
        ]
        if let payload = action.payload?.value {
            userInfo["payload"] = payload
        }

        NotificationCenter.default.post(
            name: .nuxieCallDelegate,
            object: nil,
            userInfo: userInfo
        )

        eventLog.track(
            JourneyEvents.delegateCalled,
            properties: JourneyEvents.delegateCalledProperties(
                journey: journey,
                screenId: context.screenId ?? journey.flowState.currentScreenId,
                message: action.message,
                payload: action.payload?.value
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
        let resolvedProductId = resolveValueRefs(action.productId.value, context: context)
        let resolvedScreenId = context.screenId ?? journey.flowState.currentScreenId
        let productId = resolvedProductId as? String
        guard let productId, !productId.isEmpty else {
            return .continue
        }
        let placementIndex = resolveValueRefs(action.placementIndex.value, context: context)
        if action.onCompleted != nil || action.onFailed != nil || action.onCancelled != nil {
            pendingPurchaseOutlets = (
                onCompleted: action.onCompleted,
                onFailed: action.onFailed,
                onCancelled: action.onCancelled,
                context: context
            )
            // Persist the chains: an app kill between performPurchase and the
            // outcome event previously dropped them silently.
            journey.flowState.pendingPurchaseOutlets = PersistedOutcomeOutlets(
                first: action.onCompleted,
                second: action.onFailed,
                third: action.onCancelled,
                screenId: context.screenId,
                handlerId: context.handlerId
            )
        }
        beginPaywallPurchaseStatus(screenId: resolvedScreenId)
        // Boxed to hand the write-once value into the MainActor closure.
        let placementIndexBox = UncheckedSendable(placementIndex)
        await MainActor.run {
            controller.performPurchase(productId: productId, placementIndex: placementIndexBox.value)
        }

        var userInfo: [String: Any] = [
            "journeyId": journey.id,
            "campaignId": journey.campaignId,
            "productId": productId
        ]
        if let screenId = resolvedScreenId {
            userInfo["screenId"] = screenId
        }
        userInfo["placementIndex"] = placementIndex
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
            journey.flowState.pendingRestoreOutlets = PersistedOutcomeOutlets(
                first: action.onRestored,
                second: action.onNoPurchases,
                third: action.onFailed,
                screenId: context.screenId,
                handlerId: context.handlerId
            )
        }
        beginPaywallRestoreStatus(screenId: context.screenId ?? journey.flowState.currentScreenId)
        await MainActor.run {
            controller.performRestore()
        }
        var userInfo: [String: Any] = [
            "journeyId": journey.id,
            "campaignId": journey.campaignId
        ]
        if let screenId = context.screenId ?? journey.flowState.currentScreenId {
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
        let resolvedUrl = resolveValueRefs(action.url.value, context: context)
        guard let urlString = resolvedUrl as? String, !urlString.isEmpty else {
            return .continue
        }
        await MainActor.run {
            controller.performOpenLink(urlString: urlString, target: action.target)
        }
        var userInfo: [String: Any] = [
            "journeyId": journey.id,
            "campaignId": journey.campaignId,
            "url": urlString
        ]
        if let target = action.target {
            userInfo["target"] = target
        }
        if let screenId = context.screenId ?? journey.flowState.currentScreenId {
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
        guard let controller = viewController else { return .continue }
        await MainActor.run {
            controller.performDismiss(reason: .userDismissed)
        }
        return .stopSequence
    }

    private func handleRemote(
        _ action: RemoteAction,
        context: TriggerContext,
        index: Int
    ) async -> ActionResult {
        let nodeId = context.handlerId ?? context.screenId ?? journey.flowState.currentScreenId ?? "unknown"
        let screenId = context.screenId ?? journey.flowState.currentScreenId
        let payload: [String: Any] = [
            "session_id": journey.id,
            "node_id": nodeId,
            "screen_id": screenId as Any,
            "node_data": [
                "type": "remote",
                "data": [
                    "action": action.action,
                    "payload": action.payload.value as Any,
                    "async": action.async ?? false,
                ],
            ],
            "context": journey.context.mapValues { $0.value },
        ]

        if action.async == true {
            eventLog.track(
                JourneyEvents.journeyNodeExecuted,
                properties: payload,
                userProperties: nil,
                userPropertiesSetOnce: nil
            )
            return .continue
        }

        do {
            let response = try await eventLog.trackWithResponse(
                JourneyEvents.journeyNodeExecuted,
                properties: payload
            )

            if let execution = response.execution {
                if execution.success {
                    if let updates = execution.contextUpdates {
                        for (key, value) in updates {
                            journey.setContext(key, value: value.value, at: dateProvider.now())
                        }
                    }
                    return .continue
                }

                if let error = execution.error {
                    if error.retryable {
                        let retryAfter = TimeInterval(error.retryAfter ?? 5)
                        let resumeAt = dateProvider.date(byAddingTimeInterval: retryAfter, to: dateProvider.now())
                        return .pause(makePendingAction(
                            kind: .remoteRetry,
                            context: context,
                            index: index,
                            resumeAt: resumeAt,
                            condition: nil,
                            maxTimeMs: nil
                        ))
                    }
                    return .exit(.error)
                }
            }

            return .continue
        } catch {
            let resumeAt = dateProvider.date(byAddingTimeInterval: 5, to: dateProvider.now())
            return .pause(makePendingAction(
                kind: .remoteRetry,
                context: context,
                index: index,
                resumeAt: resumeAt,
                condition: nil,
                maxTimeMs: nil
            ))
        }
    }

    private func handleSetViewModel(
        _ action: SetViewModelAction,
        context: TriggerContext
    ) async -> ActionResult {
        let resolvedValue = resolveValueRefs(action.value.value, context: context)
        let screenId = context.screenId ?? journey.flowState.currentScreenId
        _ = viewModelState.setValue(
            path: action.path,
            value: resolvedValue,
            screenId: screenId,
            instanceId: context.instanceId
        )
        journey.flowState.viewModelSnapshot = viewModelState.getSnapshot()

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
        let screenId = context.screenId ?? journey.flowState.currentScreenId
        let timestamp = Int(dateProvider.now().timeIntervalSince1970 * 1000)
        _ = viewModelState.setValue(
            path: action.path,
            value: timestamp,
            screenId: screenId,
            instanceId: context.instanceId
        )
        journey.flowState.viewModelSnapshot = viewModelState.getSnapshot()

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
        _ operation: FlowViewModelListOperation,
        path: VmPathRef,
        payload: [String: Any],
        context: TriggerContext
    ) -> ActionResult {
        let screenId = context.screenId ?? journey.flowState.currentScreenId

        let ok = viewModelState.setListValue(
            path: path,
            operation: operation.rawValue,
            payload: payload,
            screenId: screenId,
            instanceId: context.instanceId
        )

        if ok {
            journey.flowState.viewModelSnapshot = viewModelState.getSnapshot()
            applyViewModelListOperation(operation, path: path, payload: payload, screenId: screenId, instanceId: context.instanceId)
        }

        return .continue
    }

    private func runNestedActions(
        _ actions: [JourneyAction],
        context: TriggerContext
    ) async -> ActionResult {
        guard !actions.isEmpty else { return .continue }

        for (index, action) in actions.enumerated() {
            let result = await executeAction(action, context: context, index: index, resumeContext: nil)
            switch result {
            case .continue:
                continue
            case .stopSequence, .exit:
                return result
            case .pause(let pending):
                return .pause(
                    attachResumeActions(
                        to: pending,
                        from: actions,
                        pausedIndex: index
                    )
                )
            }
        }

        return .continue
    }

    private func buildResumeActions(
        from actions: [JourneyAction],
        pausedIndex: Int,
        pendingKind: FlowPendingActionKind
    ) -> [JourneyAction] {
        let resumeIndex = pendingKind == .delay ? pausedIndex + 1 : pausedIndex
        guard resumeIndex > 0 else { return actions }
        guard resumeIndex < actions.count else { return [] }
        return Array(actions.dropFirst(resumeIndex))
    }

    private func attachResumeActions(
        to pending: FlowPendingAction,
        from actions: [JourneyAction],
        pausedIndex: Int
    ) -> FlowPendingAction {
        let trailingActions =
            pausedIndex + 1 >= actions.count
            ? []
            : Array(actions.dropFirst(pausedIndex + 1))
        let resumeActions =
            pending.resumeActions.map { existing in
                trailingActions.isEmpty ? existing : existing + trailingActions
            }
            ?? buildResumeActions(
                from: actions,
                pausedIndex: pausedIndex,
                pendingKind: pending.kind
            )
        return pending.withResumeActions(resumeActions)
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
    ) {
        _ = viewModelState.setValue(path: path, value: 0, screenId: screenId, instanceId: instanceId)
        journey.flowState.viewModelSnapshot = viewModelState.getSnapshot()
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
        kind: FlowPendingActionKind,
        context: TriggerContext,
        index: Int,
        resumeAt: Date?,
        condition: IREnvelope?,
        maxTimeMs: Int?,
        startedAt: Date? = nil
    ) -> FlowPendingAction {
        FlowPendingAction(
            handlerId: context.handlerId ?? "entry",
            screenId: context.screenId,
            componentId: context.componentId,
            actionIndex: index,
            kind: kind,
            resumeAt: resumeAt,
            condition: condition,
            maxTimeMs: maxTimeMs,
            startedAt: startedAt ?? dateProvider.now(),
            resumeActions: nil
        )
    }

    private func trackAction(_ action: JourneyAction, context: TriggerContext, error: String?) {
        eventLog.track(
            JourneyEvents.journeyAction,
            properties: JourneyEvents.journeyActionProperties(
                journey: journey,
                screenId: context.screenId ?? journey.flowState.currentScreenId,
                handlerId: context.handlerId,
                actionType: action.actionType,
                error: error
            ),
            userProperties: nil,
            userPropertiesSetOnce: nil
        )
    }

    private func applyInitialViewModelState() {
        guard let controller = viewController else { return }
        let snapshot = viewModelState.getSnapshot()
        let screenId = journey.flowState.currentScreenId

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

    private func beginPaywallPurchaseStatus(screenId: String?) {
        applyPaywallStatusWrites(paywallStatusProjector.beginPurchase(), screenId: screenId)
    }

    private func beginPaywallRestoreStatus(screenId: String?) {
        applyPaywallStatusWrites(paywallStatusProjector.beginRestore(), screenId: screenId)
    }

    private func projectPaywallStatus(from event: NuxieEvent) {
        applyPaywallStatusWrites(
            paywallStatusProjector.project(eventName: event.name, properties: event.properties),
            screenId: journey.flowState.currentScreenId
        )
    }

    private func applyPaywallStatusWrites(
        _ writes: [PaywallStatusProjector.Write],
        screenId: String?
    ) {
        for write in writes {
            updatePaywallCapabilityValue(path: write.path, value: write.value, screenId: screenId)
        }
    }

    private func updatePaywallCapabilityValue(
        path: String,
        value: Any,
        screenId: String?
    ) {
        let pathRef = VmPathRef(path: path)
        guard viewModelState.setValue(path: pathRef, value: value, screenId: screenId) else { return }
        journey.flowState.viewModelSnapshot = viewModelState.getSnapshot()
        applyViewModelValue(path: pathRef, value: value, screenId: screenId)
    }

    private func applyViewModelListOperation(
        _ operation: FlowViewModelListOperation,
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

    private func resolveValueRefs(_ value: Any, context: TriggerContext) -> Any {
        let screenId = context.screenId ?? journey.flowState.currentScreenId
        let resolver = ValueRefResolver(
            payload: context.payload,
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

        let config = irRuntime.standardConfig(event: event)

        return await irRuntime.eval(envelope, config)
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

    private func getFrozenExperimentVariantKey(experimentKey: String) -> String? {
        ExperimentResolver.frozenVariantKey(
            in: journey.getContext(ExperimentResolver.ContextKeys.frozenVariantsByExperiment),
            experimentKey: experimentKey
        )
    }

    private func freezeExperimentVariantKey(experimentKey: String, variantKey: String) {
        guard !experimentKey.isEmpty, !variantKey.isEmpty else { return }
        var dict =
            (journey.getContext(ExperimentResolver.ContextKeys.frozenVariantsByExperiment) as? [String: Any]) ?? [:]
        dict[experimentKey] = variantKey
        journey.setContext(ExperimentResolver.ContextKeys.frozenVariantsByExperiment, value: dict, at: dateProvider.now())
    }

    private func hasEmittedExperimentExposure(experimentKey: String) -> Bool {
        ExperimentResolver.exposureEmitted(
            in: journey.getContext(ExperimentResolver.ContextKeys.exposureEmittedByExperiment),
            experimentKey: experimentKey
        )
    }

    private func markExperimentExposureEmitted(experimentKey: String) {
        guard !experimentKey.isEmpty else { return }
        var dict =
            (journey.getContext(ExperimentResolver.ContextKeys.exposureEmittedByExperiment) as? [String: Any]) ?? [:]
        dict[experimentKey] = true
        journey.setContext(ExperimentResolver.ContextKeys.exposureEmittedByExperiment, value: dict, at: dateProvider.now())
    }
}
