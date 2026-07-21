import Foundation
import FactoryKit

private final class SerialTaskQueue {
    private let lock = NSLock()
    private var tail: Task<Void, Never>?
    private var tailGeneration: UInt64 = 0

    func enqueue(_ operation: @escaping () async -> Void) {
        lock.lock()
        let previous = tail
        tailGeneration += 1
        let generation = tailGeneration
        let next = Task { [weak self] in
            _ = await previous?.value
            await operation()
            self?.finish(generation: generation)
        }
        tail = next
        lock.unlock()
    }

    private func finish(generation: UInt64) {
        lock.lock()
        if tailGeneration == generation {
            tail = nil
        }
        lock.unlock()
    }
}

/// Actor: the runner's mutable execution state (actionQueue, activeRequest,
/// isProcessing, isPaused, outlet slots…) was previously a plain class driven
/// from the reentrant JourneyService actor — while one dispatch was suspended
/// mid-processQueue, the service could start another on a different thread:
/// a data race by construction. Actor isolation makes every entry point
/// serialize at suspension points with memory safety; the isProcessing/
/// needsQueueDrain pair still coalesces logically-reentrant drains (actor
/// reentrancy interleaves at awaits — isolation is not mutual exclusion
/// across suspension points).
actor FlowJourneyRunner {
    private static let currentDeviceTimezoneToken = "__current_device__"
    private static let responseRootViewModelName = "vm"
    private static let responseRootPropertyName = "response"
    private static let responseValuesPropertyName = "values"

    struct TriggerContext {
        let screenId: String?
        let componentId: String?
        let handlerId: String?
        let instanceId: String?
        let payload: [String: Any]?
    }

    private struct ResponseRuntimeContext {
        let screenId: String?
        let instanceId: String?
        let schemaId: String?
        let schemaVersion: Int?
        let state: String?
        let schemaIdPath: VmPathRef
        let schemaVersionPath: VmPathRef
        let statePath: VmPathRef
    }

    enum RunOutcome {
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
    private let flow: Flow
    private let remoteFlow: RemoteFlow
    private let viewModelState: FlowViewModelStateCoordinator
    private let onGoalHit: ((_ goalId: String, _ goalLabel: String?, _ screenId: String?, _ handlerId: String?) async -> Void)?

    @Injected(\.eventLog) private var eventLog: EventLogProtocol
    @Injected(\.identityService) private var identityService: IdentityServiceProtocol
    @Injected(\.segmentService) private var segmentService: SegmentServiceProtocol
    @Injected(\.featureService) private var featureService: FeatureServiceProtocol
    @Injected(\.profileService) private var profileService: ProfileServiceProtocol
    @Injected(\.nuxieApi) private var apiClient: NuxieApiProtocol
    @Injected(\.dateProvider) private var dateProvider: DateProviderProtocol
    @Injected(\.irRuntime) private var irRuntime: IRRuntime

    weak var viewController: FlowViewController?
    var onShowScreen: ((String, AnyCodable?) async -> Void)?

    func setOnShowScreen(_ handler: @escaping (String, AnyCodable?) async -> Void) {
        onShowScreen = handler
    }
    private(set) var isRuntimeReady = false

    private var handlersByHost: [String: [JourneyEventHandler]] = [:]
    private var eventDeclarationsByHost: [String: [EventDeclaration]] = [:]
    private var handlerActionsById: [String: [JourneyAction]] = [:]
    private let journeyEventHostKey = RemoteFlow.journeyEventHostKey
    private var activePaywallPurchaseInvocationId: String?
    /// Outcome outlets (Flow Logic 2026-07-04): chains captured from the
    /// initiating purchase/restore node, run when its async outcome event
    /// arrives. Keyed by the same single-active-invocation model as the
    /// paywall status projection above.
    private var pendingPurchaseOutlets:
        (onCompleted: [JourneyAction]?, onFailed: [JourneyAction]?, onCancelled: [JourneyAction]?, context: TriggerContext)?
    private var pendingRestoreOutlets:
        (onRestored: [JourneyAction]?, onNoPurchases: [JourneyAction]?, onFailed: [JourneyAction]?, context: TriggerContext)?
    private var activePaywallRestoreInvocationId: String?

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
        flow: Flow,
        onGoalHit: ((_ goalId: String, _ goalLabel: String?, _ screenId: String?, _ handlerId: String?) async -> Void)? = nil,
        viewController: FlowViewController? = nil
    ) {
        self.journey = journey
        self.campaign = campaign
        self.flow = flow

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
        self.remoteFlow = flow.remoteFlow
        self.viewModelState = FlowViewModelStateCoordinator(remoteFlow: flow.remoteFlow)
        self.onGoalHit = onGoalHit
        self.viewController = viewController

        self.handlersByHost = flow.remoteFlow.handlers.mapValues(Self.sortedHandlers)
        self.eventDeclarationsByHost = flow.remoteFlow.events
        self.handlerActionsById = Self.indexHandlerActions(flow.remoteFlow.handlers)

        if let snapshot = journey.flowState.viewModelSnapshot {
            viewModelState.hydrate(snapshot)
        } else {
            journey.flowState.viewModelSnapshot = viewModelState.getSnapshot()
        }
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

    func attach(viewController: FlowViewController) {
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
                let fallback = remoteFlow.screens.first?.id
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
    /// started it (Flow Logic 2026-07-04).
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
    /// no response schema or the payload is malformed (Flow Logic 2026-07-04).
    private func runResponseSetBuiltIn(
        _ event: NuxieEvent,
        screenId: String,
        componentId: String?,
        instanceId: String?
    ) async -> RunOutcome? {
        if isPaused { return nil }
        guard let schemaId = remoteFlow.responseSchemas?.first?.responseSchemaId,
              !schemaId.isEmpty,
              let field = event.properties["field"] as? String,
              !field.isEmpty,
              let value = event.properties["value"]
        else { return nil }

        let action = SetResponseFieldAction(
            responseSchemaId: schemaId,
            key: field,
            value: AnyCodable(value)
        )
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
        return payloadMatchesSchema(event.properties, schema: payloadSchema)
    }

    private func payloadMatchesSchema(_ payload: [String: Any], schema: EventPayloadSchema) -> Bool {
        for (field, expectedType) in schema {
            guard let value = resolvePayloadPath(field, in: payload) else {
                return false
            }
            if !payloadValue(value, matches: expectedType) {
                return false
            }
        }
        return true
    }

    private func payloadValue(_ value: Any, matches expectedType: EventPayloadFieldType) -> Bool {
        let unwrapped = unwrapRuntimeValue(value)
        switch expectedType {
        case .string:
            return unwrapped is String
        case .number:
            return unwrapped is Int || unwrapped is Double || unwrapped is Float || unwrapped is NSNumber
        case .boolean:
            return unwrapped is Bool
        case .object:
            return unwrapped is [String: Any] || unwrapped is [String: AnyCodable]
        case .array:
            return unwrapped is [Any] || unwrapped is [AnyCodable]
        }
    }

    private func resolvePayloadPath(_ path: String, in payload: [String: Any]?) -> Any? {
        guard let payload else { return nil }
        var current: Any? = payload
        for segment in path.split(separator: ".").map(String.init) {
            if let dict = current as? [String: Any] {
                current = dict[segment]
            } else if let dict = current as? [String: AnyCodable] {
                current = dict[segment]?.value
            } else {
                return nil
            }
        }
        return current
    }

    private func unwrapRuntimeValue(_ value: Any) -> Any {
        if let anyCodable = value as? AnyCodable {
            return unwrapRuntimeValue(anyCodable.value)
        }
        return value
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
            (enabledHandlers.contains { $0.eventName == "$app_opened" } ? "$app_opened" : nil)
        guard let preferredEventName else { return nil }

        let matchingHandlers = enabledHandlers.filter { $0.eventName == preferredEventName }
        if matchingHandlers.isEmpty { return nil }

        // Mark BEFORE executing: a crash mid-chain must not replay side
        // effects (sendEvent/purchase) on restore. The pendingAction resume
        // path continues an interrupted chain; the entry gate only prevents
        // a full re-run.
        journey.setContext("_entry_actions_ran", value: true)

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
                LogError("FlowJourneyRunner: step budget exceeded (\(maxSteps)) — exiting journey \(journey.id) as error (likely a handler cycle)")
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
        do {
            switch action {
            case .navigate(let navigate):
                await navigateToAction(navigate, context: context)
                trackAction(action, context: context, error: nil)
                return .stopSequence
            case .back(let back):
                await handleBack(back)
                trackAction(action, context: context, error: nil)
                return .stopSequence
            case .delay(let delay):
                let result = handleDelay(delay, context: context, index: index, resumeContext: resumeContext)
                trackAction(action, context: context, error: nil)
                return result
            case .timeWindow(let timeWindow):
                let result = await handleTimeWindow(timeWindow, context: context, index: index, resumeContext: resumeContext)
                trackAction(action, context: context, error: nil)
                return result
            case .waitUntil(let waitUntil):
                let result = await handleWaitUntil(waitUntil, context: context, index: index, resumeContext: resumeContext)
                trackAction(action, context: context, error: nil)
                return result
            case .condition(let condition):
                let result = await handleCondition(condition, context: context)
                trackAction(action, context: context, error: nil)
                return result
            case .experiment(let experiment):
                let result = await handleExperiment(experiment, context: context)
                trackAction(action, context: context, error: nil)
                return result
            case .goal(let goal):
                let result = await handleGoal(goal, context: context)
                trackAction(action, context: context, error: nil)
                return result
            case .sendEvent(let sendEvent):
                await handleSendEvent(sendEvent, context: context)
                trackAction(action, context: context, error: nil)
                return .continue
            case .updateCustomer(let updateCustomer):
                handleUpdateCustomer(updateCustomer, context: context)
                trackAction(action, context: context, error: nil)
                return .continue
            case .setResponseField(let setResponseField):
                let result = try await handleSetResponseField(setResponseField, context: context)
                trackAction(action, context: context, error: nil)
                return result
            case .submitResponse(let submitResponse):
                let result = try await handleSubmitResponse(submitResponse, context: context)
                trackAction(action, context: context, error: nil)
                return result
            case .purchase(let purchase):
                let result = await handlePurchase(purchase, context: context)
                trackAction(action, context: context, error: nil)
                return result
            case .restore(let restore):
                let result = await handleRestore(restore, context: context)
                trackAction(action, context: context, error: nil)
                return result
            case .requestNotifications(let requestNotifications):
                let result = await handleRequestNotifications(requestNotifications, context: context)
                trackAction(action, context: context, error: nil)
                return result
            case .requestPermission(let requestPermission):
                let result = await handleRequestPermission(requestPermission, context: context)
                trackAction(action, context: context, error: nil)
                return result
            case .requestTracking(let requestTracking):
                let result = await handleRequestTracking(requestTracking, context: context)
                trackAction(action, context: context, error: nil)
                return result
            case .openLink(let openLink):
                let result = await handleOpenLink(openLink, context: context)
                trackAction(action, context: context, error: nil)
                return result
            case .dismiss(let dismiss):
                let result = await handleDismiss(dismiss, context: context)
                trackAction(action, context: context, error: nil)
                return result
            case .callDelegate(let callDelegate):
                handleCallDelegate(callDelegate, context: context)
                trackAction(action, context: context, error: nil)
                return .continue
            case .remote(let remote):
                let result = await handleRemote(remote, context: context, index: index)
                trackAction(action, context: context, error: nil)
                return result
            case .setViewModel(let setViewModel):
                let result = await handleSetViewModel(setViewModel, context: context)
                trackAction(action, context: context, error: nil)
                return result
            case .fireTrigger(let fireTrigger):
                let result = await handleFireTrigger(fireTrigger, context: context)
                trackAction(action, context: context, error: nil)
                return result
            case .listInsert(let listInsert):
                let result = await handleListInsert(listInsert, context: context)
                trackAction(action, context: context, error: nil)
                return result
            case .listRemove(let listRemove):
                let result = await handleListRemove(listRemove, context: context)
                trackAction(action, context: context, error: nil)
                return result
            case .listSwap(let listSwap):
                let result = await handleListSwap(listSwap, context: context)
                trackAction(action, context: context, error: nil)
                return result
            case .listMove(let listMove):
                let result = await handleListMove(listMove, context: context)
                trackAction(action, context: context, error: nil)
                return result
            case .listSet(let listSet):
                let result = await handleListSet(listSet, context: context)
                trackAction(action, context: context, error: nil)
                return result
            case .listClear(let listClear):
                let result = await handleListClear(listClear, context: context)
                trackAction(action, context: context, error: nil)
                return result
            case .exit(let exitAction):
                trackAction(action, context: context, error: nil)
                return .exit(mapExitReason(exitAction.reason))
            case .unknown:
                return .continue
            }
        } catch {
            trackAction(action, context: context, error: error.localizedDescription)
            return .exit(.error)
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
        let now = dateProvider.now()
        let tz = resolveTimeWindowTimezone(action.timezone)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz

        guard let startHM = parseTime(action.startTime),
              let endHM = parseTime(action.endTime),
              let sh = startHM.hour, let sm = startHM.minute,
              let eh = endHM.hour, let em = endHM.minute
        else {
            return .continue
        }

        let weekday = cal.component(.weekday, from: now)
        if let days = action.daysOfWeek, !days.isEmpty, !days.contains(weekday) {
            let nextValid = calculateNextValidDay(from: now, validDays: days, timezone: tz)
            return .pause(makePendingAction(
                kind: .timeWindow,
                context: context,
                index: index,
                resumeAt: nextValid,
                condition: nil,
                maxTimeMs: nil
            ))
        }

        let currentHM = cal.dateComponents([.hour, .minute], from: now)
        let curMin = (currentHM.hour ?? 0) * 60 + (currentHM.minute ?? 0)
        let startMin = sh * 60 + sm
        let endMin = eh * 60 + em

        if startMin == endMin {
            return await runNestedActions(action.successActions ?? [], context: context)
        }

        let inWindow =
            (startMin <= endMin)
            ? (curMin >= startMin && curMin < endMin)
            : (curMin >= startMin || curMin < endMin)

        if inWindow {
            return await runNestedActions(action.successActions ?? [], context: context)
        }

        let nextOpen = calculateNextWindowOpen(
            from: now,
            startTime: action.startTime,
            timezone: tz,
            validDays: action.daysOfWeek
        )

        return .pause(makePendingAction(
            kind: .timeWindow,
            context: context,
            index: index,
            resumeAt: nextOpen,
            condition: nil,
            maxTimeMs: nil
        ))
    }

    private func resolveTimeWindowTimezone(_ rawTimezone: String) -> TimeZone {
        if rawTimezone == Self.currentDeviceTimezoneToken {
            return .current
        }
        return TimeZone(identifier: rawTimezone) ?? .current
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

        let frozenVariantKey = getFrozenExperimentVariantKey(experimentKey: experimentKey)
        let frozenVariant =
            frozenVariantKey.flatMap { key in
                action.variants.first(where: { $0.id == key })
            }

        // INVARIANT (experimentation trust): no variant's actions execute
        // without a classifiable exposure record — a real $experiment_exposure,
        // a tagged fallback, or an error that SKIPS execution. Silent
        // variant[0] runs corrupted experiment analysis.

        let status = assignment?.status

        // Error path: a running experiment whose assigned variant does not
        // exist in this action executes NOTHING (exposed-but-invisible users
        // are worse than a skipped node).
        if frozenVariant == nil,
           status == "running",
           let assignedKey = assignment?.variantKey,
           action.variants.first(where: { $0.id == assignedKey }) == nil {
            eventLog.track(
                "$experiment_exposure_error",
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

        let resolution = frozenVariant != nil
            ? (variant: frozenVariant, matchedAssignment: assignment?.variantKey == frozenVariantKey)
            : resolveExperimentVariant(action, assignment: assignment)

        guard let variant = resolution.variant else {
            return .continue
        }

        if status == "running",
           resolution.matchedAssignment,
           (frozenVariantKey == nil || frozenVariant == nil)
        {
            freezeExperimentVariantKey(experimentKey: experimentKey, variantKey: variant.id)
        }

        journey.setContext("_experiment_key", value: experimentKey)
        journey.setContext("_variant_key", value: variant.id)

        if !hasEmittedExperimentExposure(experimentKey: experimentKey) {
            if status == "running", resolution.matchedAssignment {
                let assignmentSource = frozenVariant != nil ? "journey_context" : "profile"
                eventLog.track(
                    JourneyEvents.experimentExposure,
                    properties: JourneyEvents.experimentExposureProperties(
                        journey: journey,
                        experimentKey: experimentKey,
                        variantKey: variant.id,
                        flowId: journey.flowId,
                        isHoldout: assignment?.isHoldout ?? false,
                        assignmentSource: assignmentSource
                    ),
                    userProperties: nil,
                    userPropertiesSetOnce: nil
                )
                markExperimentExposureEmitted(experimentKey: experimentKey)
            } else {
                // Default-branch fallback (no assignment, or experiment not
                // running): the variant still runs — journeys must work
                // offline — but the exposure is TAGGED so analysis can
                // exclude or segment these users. Never silent.
                eventLog.track(
                    "$experiment_exposure_fallback",
                    properties: [
                        "experiment_key": experimentKey,
                        "variant_key": variant.id,
                        "assignment_source": assignment == nil
                            ? "no_assignment"
                            : "status_\(status ?? "unknown")"
                    ],
                    userProperties: nil,
                    userPropertiesSetOnce: nil
                )
                markExperimentExposureEmitted(experimentKey: experimentKey)
            }
        }

        let result = await runNestedActions(variant.actions, context: context)
        return result
    }

    private func handleSendEvent(
        _ action: SendEventAction,
        context: TriggerContext
    ) async {
        var properties: [String: Any] = [:]
        if let props = action.properties {
            for (key, value) in props { properties[key] = value.value }
        }
        properties["journeyId"] = journey.id
        properties["campaignId"] = journey.campaignId
        if let screenId = context.screenId ?? journey.flowState.currentScreenId {
            properties["screenId"] = screenId
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


    private func responsePath(_ segments: [String]) -> VmPathRef {
        VmPathRef(
            viewModelName: Self.responseRootViewModelName,
            path: segments.joined(separator: "/")
        )
    }

    private func responseValueAsInt(_ value: Any?) -> Int? {
        if let int = value as? Int {
            return int
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        return nil
    }

    private func makeResponseRuntimeContext(
        _ context: TriggerContext
    ) -> ResponseRuntimeContext {
        let screenId = context.screenId ?? journey.flowState.currentScreenId
        let instanceId = context.instanceId
        let schemaIdPath = responsePath([
            Self.responseRootPropertyName,
            "schemaId",
        ])
        let schemaVersionPath = responsePath([
            Self.responseRootPropertyName,
            "schemaVersion",
        ])
        let statePath = responsePath([
            Self.responseRootPropertyName,
            "state",
        ])

        return ResponseRuntimeContext(
            screenId: screenId,
            instanceId: instanceId,
            schemaId: viewModelState.getValue(
                path: schemaIdPath,
                screenId: screenId,
                instanceId: instanceId
            ) as? String,
            schemaVersion: responseValueAsInt(
                viewModelState.getValue(
                    path: schemaVersionPath,
                    screenId: screenId,
                    instanceId: instanceId
                )
            ),
            state: viewModelState.getValue(
                path: statePath,
                screenId: screenId,
                instanceId: instanceId
            ) as? String,
            schemaIdPath: schemaIdPath,
            schemaVersionPath: schemaVersionPath,
            statePath: statePath
        )
    }

    private func responseContextMatches(
        _ runtimeContext: ResponseRuntimeContext,
        responseSchemaId: String,
        schemaVersion: Int?
    ) -> Bool {
        guard runtimeContext.schemaId == responseSchemaId else { return false }
        if let schemaVersion,
           let runtimeSchemaVersion = runtimeContext.schemaVersion,
           runtimeSchemaVersion != schemaVersion {
            return false
        }
        return true
    }

    private func responseCacheKey(
        responseSchemaId: String,
        schemaVersion: Int
    ) -> String {
        "\(responseSchemaId):\(schemaVersion)"
    }

    private func updateJourneyResponseCache(_ response: ResponseRecordPayload) {
        var existing = (journey.getContext("responses") as? [String: Any]) ?? [:]
        existing[
            responseCacheKey(
                responseSchemaId: response.responseSchemaId,
                schemaVersion: response.schemaVersion
            )
        ] = [
            "responseId": response.id,
            "responseSchemaId": response.responseSchemaId,
            "schemaVersion": response.schemaVersion,
            "state": response.state,
            "values": response.values.mapValues(\.value),
        ]
        journey.setContext("responses", value: existing)
    }

    private func applyResponseRuntimeValuePatch(
        path: VmPathRef,
        value: Any,
        context: ResponseRuntimeContext
    ) {
        _ = viewModelState.setValue(
            path: path,
            value: value,
            screenId: context.screenId,
            instanceId: context.instanceId
        )
        applyViewModelValue(
            path: path,
            value: value,
            screenId: context.screenId,
            instanceId: context.instanceId
        )
    }

    private func applyResponseRecordToRuntime(
        _ response: ResponseRecordPayload,
        context: TriggerContext,
        touchedFieldKey: String? = nil
    ) {
        let runtimeContext = makeResponseRuntimeContext(context)
        guard responseContextMatches(
            runtimeContext,
            responseSchemaId: response.responseSchemaId,
            schemaVersion: response.schemaVersion
        ) else {
            return
        }

        applyResponseRuntimeValuePatch(
            path: runtimeContext.statePath,
            value: response.state,
            context: runtimeContext
        )
        applyResponseRuntimeValuePatch(
            path: runtimeContext.schemaVersionPath,
            value: response.schemaVersion,
            context: runtimeContext
        )
        if let touchedFieldKey,
           let value = response.values[touchedFieldKey]?.value {
            applyResponseRuntimeValuePatch(
                path: responsePath([
                    Self.responseRootPropertyName,
                    Self.responseValuesPropertyName,
                    touchedFieldKey,
                ]),
                value: value,
                context: runtimeContext
            )
        }
        journey.flowState.viewModelSnapshot = viewModelState.getSnapshot()
    }

    private func handleSetResponseField(
        _ action: SetResponseFieldAction,
        context: TriggerContext
    ) async throws -> ActionResult {
        let resolvedValue = resolveValueRefs(action.value.value, context: context)
        let runtimeContext = makeResponseRuntimeContext(context)
        if responseContextMatches(
            runtimeContext,
            responseSchemaId: action.responseSchemaId,
            schemaVersion: action.schemaVersion
        ) {
            let valuePath = responsePath([
                Self.responseRootPropertyName,
                Self.responseValuesPropertyName,
                action.key,
            ])
            applyResponseRuntimeValuePatch(
                path: valuePath,
                value: resolvedValue,
                context: runtimeContext
            )
            applyResponseRuntimeValuePatch(
                path: runtimeContext.statePath,
                value: "draft",
                context: runtimeContext
            )
            journey.flowState.viewModelSnapshot = viewModelState.getSnapshot()
        }

        do {
            didAttemptResponseDraftWrite = true
            let result = try await apiClient.setResponseField(
                distinctId: journey.distinctId,
                journeySessionId: journey.id,
                responseSchemaId: action.responseSchemaId,
                schemaVersion: action.schemaVersion,
                key: action.key,
                value: resolvedValue
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
            LogWarning("FlowJourneyRunner: set_response_field failed: \(error.localizedDescription)")
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
            LogWarning("FlowJourneyRunner: submit_response failed: \(error.localizedDescription)")
        }

        return .continue
    }

    func shouldAbandonResponseDraftsAfterDismiss() -> Bool {
        !didFailSetResponseField && !didFailSubmitResponse
    }

    func abandonResponseDraftsIfNeeded() async {
        let responses = journey.getContext("responses") as? [String: Any]
        let hasDrafts = responses?.values.contains { value in
            guard let response = value as? [String: Any] else { return false }
            guard let state = response["state"] as? String, state == "draft" else {
                return false
            }
            guard let values = response["values"] as? [String: Any] else {
                return false
            }
            return !values.isEmpty
        } ?? false
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
            LogWarning("FlowJourneyRunner: abandon response drafts failed: \(error.localizedDescription)")
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
        await MainActor.run {
            controller.performPurchase(productId: productId, placementIndex: placementIndex)
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
                "$journey_node_executed",
                properties: payload,
                userProperties: nil,
                userPropertiesSetOnce: nil
            )
            return .continue
        }

        do {
            let response = try await eventLog.trackWithResponse(
                "$journey_node_executed",
                properties: payload
            )

            if let execution = response.execution {
                if execution.success {
                    if let updates = execution.contextUpdates {
                        for (key, value) in updates {
                            journey.setContext(key, value: value.value)
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

    private func handleListInsert(
        _ action: ListInsertAction,
        context: TriggerContext
    ) async -> ActionResult {
        let screenId = context.screenId ?? journey.flowState.currentScreenId
        let resolvedValue = resolveValueRefs(action.value.value, context: context)
        var payload: [String: Any] = ["value": resolvedValue]
        if let index = action.index {
            payload["index"] = index
        }

        let ok = viewModelState.setListValue(
            path: action.path,
            operation: "insert",
            payload: payload,
            screenId: screenId,
            instanceId: context.instanceId
        )

        if ok {
            journey.flowState.viewModelSnapshot = viewModelState.getSnapshot()
            applyViewModelListOperation(.insert, path: action.path, payload: payload, screenId: screenId, instanceId: context.instanceId)
        }

        return .continue
    }

    private func handleListRemove(
        _ action: ListRemoveAction,
        context: TriggerContext
    ) async -> ActionResult {
        let screenId = context.screenId ?? journey.flowState.currentScreenId
        let payload: [String: Any] = ["index": action.index]

        let ok = viewModelState.setListValue(
            path: action.path,
            operation: "remove",
            payload: payload,
            screenId: screenId,
            instanceId: context.instanceId
        )

        if ok {
            journey.flowState.viewModelSnapshot = viewModelState.getSnapshot()
            applyViewModelListOperation(.remove, path: action.path, payload: payload, screenId: screenId, instanceId: context.instanceId)
        }

        return .continue
    }

    private func handleListSwap(
        _ action: ListSwapAction,
        context: TriggerContext
    ) async -> ActionResult {
        let screenId = context.screenId ?? journey.flowState.currentScreenId
        let payload: [String: Any] = [
            "from": action.indexA,
            "to": action.indexB
        ]

        let ok = viewModelState.setListValue(
            path: action.path,
            operation: "swap",
            payload: payload,
            screenId: screenId,
            instanceId: context.instanceId
        )

        if ok {
            journey.flowState.viewModelSnapshot = viewModelState.getSnapshot()
            applyViewModelListOperation(.swap, path: action.path, payload: payload, screenId: screenId, instanceId: context.instanceId)
        }

        return .continue
    }

    private func handleListMove(
        _ action: ListMoveAction,
        context: TriggerContext
    ) async -> ActionResult {
        let screenId = context.screenId ?? journey.flowState.currentScreenId
        let payload: [String: Any] = [
            "from": action.from,
            "to": action.to
        ]

        let ok = viewModelState.setListValue(
            path: action.path,
            operation: "move",
            payload: payload,
            screenId: screenId,
            instanceId: context.instanceId
        )

        if ok {
            journey.flowState.viewModelSnapshot = viewModelState.getSnapshot()
            applyViewModelListOperation(.move, path: action.path, payload: payload, screenId: screenId, instanceId: context.instanceId)
        }

        return .continue
    }

    private func handleListSet(
        _ action: ListSetAction,
        context: TriggerContext
    ) async -> ActionResult {
        let screenId = context.screenId ?? journey.flowState.currentScreenId
        let resolvedValue = resolveValueRefs(action.value.value, context: context)
        let payload: [String: Any] = [
            "index": action.index,
            "value": resolvedValue
        ]

        let ok = viewModelState.setListValue(
            path: action.path,
            operation: "set",
            payload: payload,
            screenId: screenId,
            instanceId: context.instanceId
        )

        if ok {
            journey.flowState.viewModelSnapshot = viewModelState.getSnapshot()
            applyViewModelListOperation(.set, path: action.path, payload: payload, screenId: screenId, instanceId: context.instanceId)
        }

        return .continue
    }

    private func handleListClear(
        _ action: ListClearAction,
        context: TriggerContext
    ) async -> ActionResult {
        let screenId = context.screenId ?? journey.flowState.currentScreenId
        let payload: [String: Any] = [:]

        let ok = viewModelState.setListValue(
            path: action.path,
            operation: "clear",
            payload: payload,
            screenId: screenId,
            instanceId: context.instanceId
        )

        if ok {
            journey.flowState.viewModelSnapshot = viewModelState.getSnapshot()
            applyViewModelListOperation(.clear, path: action.path, payload: payload, screenId: screenId, instanceId: context.instanceId)
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
            self.deferredTaskQueue.enqueue { [weak self] in
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

    private func mapExitReason(_ reason: String?) -> JourneyExitReason {
        switch reason {
        case "dismissed":
            return .dismissed
        case "goal_met":
            return .goalMet
        case "trigger_unmatched":
            return .triggerUnmatched
        case "expired":
            return .expired
        case "error":
            return .error
        case "cancelled":
            return .cancelled
        default:
            return .completed
        }
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
        Task { @MainActor in
            controller.applyViewModelValue(
                path: path,
                value: value,
                screenId: screenId,
                instanceId: instanceId
            )
        }
    }

    private func beginPaywallPurchaseStatus(screenId: String?) {
        let invocationId = UUID().uuidString
        activePaywallPurchaseInvocationId = invocationId
        updatePaywallPurchaseStatus(
            status: "running",
            errorCode: "",
            invocationId: invocationId,
            screenId: screenId
        )
    }

    private func beginPaywallRestoreStatus(screenId: String?) {
        let invocationId = UUID().uuidString
        activePaywallRestoreInvocationId = invocationId
        updatePaywallRestoreStatus(
            status: "running",
            errorCode: "",
            invocationId: invocationId,
            screenId: screenId
        )
    }

    private func projectPaywallStatus(from event: NuxieEvent) {
        let screenId = journey.flowState.currentScreenId
        switch event.name {
        case SystemEventNames.purchaseCompleted:
            updatePaywallPurchaseStatus(
                status: "success",
                errorCode: "",
                invocationId: activePaywallPurchaseInvocationId ?? UUID().uuidString,
                screenId: screenId
            )
            activePaywallPurchaseInvocationId = nil
        case SystemEventNames.purchaseFailed:
            updatePaywallPurchaseStatus(
                status: "error",
                errorCode: errorCode(from: event),
                invocationId: activePaywallPurchaseInvocationId ?? UUID().uuidString,
                screenId: screenId
            )
            activePaywallPurchaseInvocationId = nil
        case SystemEventNames.purchaseCancelled:
            updatePaywallPurchaseStatus(
                status: "cancelled",
                errorCode: "",
                invocationId: activePaywallPurchaseInvocationId ?? UUID().uuidString,
                screenId: screenId
            )
            activePaywallPurchaseInvocationId = nil
        case SystemEventNames.purchasePending:
            // Ask-to-Buy / SCA: reflect the deferred state instead of leaving
            // the paywall stuck on "running". The invocation stays active so
            // the eventual outcome still resolves it.
            updatePaywallPurchaseStatus(
                status: "pending",
                errorCode: "",
                invocationId: activePaywallPurchaseInvocationId ?? UUID().uuidString,
                screenId: screenId
            )
        case SystemEventNames.restoreCompleted:
            updatePaywallRestoreStatus(
                status: "success",
                errorCode: "",
                invocationId: activePaywallRestoreInvocationId ?? UUID().uuidString,
                screenId: screenId
            )
            activePaywallRestoreInvocationId = nil
        case SystemEventNames.restoreFailed:
            updatePaywallRestoreStatus(
                status: "error",
                errorCode: errorCode(from: event),
                invocationId: activePaywallRestoreInvocationId ?? UUID().uuidString,
                screenId: screenId
            )
            activePaywallRestoreInvocationId = nil
        case SystemEventNames.restoreNoPurchases:
            updatePaywallRestoreStatus(
                status: "not_found",
                errorCode: "",
                invocationId: activePaywallRestoreInvocationId ?? UUID().uuidString,
                screenId: screenId
            )
            activePaywallRestoreInvocationId = nil
        default:
            return
        }
    }

    private func updatePaywallPurchaseStatus(
        status: String,
        errorCode: String,
        invocationId: String,
        screenId: String?
    ) {
        updatePaywallCapabilityValue(path: "paywall/purchase/status", value: status, screenId: screenId)
        updatePaywallCapabilityValue(path: "paywall/purchase/errorCode", value: errorCode, screenId: screenId)
        updatePaywallCapabilityValue(path: "paywall/purchase/invocationId", value: invocationId, screenId: screenId)
    }

    private func updatePaywallRestoreStatus(
        status: String,
        errorCode: String,
        invocationId: String,
        screenId: String?
    ) {
        updatePaywallCapabilityValue(path: "paywall/restore/status", value: status, screenId: screenId)
        updatePaywallCapabilityValue(path: "paywall/restore/errorCode", value: errorCode, screenId: screenId)
        updatePaywallCapabilityValue(path: "paywall/restore/invocationId", value: invocationId, screenId: screenId)
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

    private func errorCode(from event: NuxieEvent) -> String {
        for key in ["error_code", "errorCode", "code", "error"] {
            if let value = event.properties[key] as? String, !value.isEmpty {
                return value
            }
        }
        return ""
    }

    private func applyViewModelListOperation(
        _ operation: FlowViewModelListOperation,
        path: VmPathRef,
        payload: [String: Any],
        screenId: String?,
        instanceId: String? = nil
    ) {
        guard let controller = viewController else { return }
        Task { @MainActor in
            controller.applyViewModelListOperation(
                operation,
                path: path,
                payload: payload,
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
        if let list = value as? [Any] {
            return list.map { resolveValueRefs($0, context: context) }
        }
        if let list = value as? [AnyCodable] {
            return list.map { resolveValueRefs($0.value, context: context) }
        }
        if let dict = value as? [String: Any] {
            if dict.count == 1, let literal = dict["literal"] {
                return literal
            }
            if dict.count == 1, let refValue = dict["ref"], let ref = parseRefPath(refValue) {
                return viewModelState.getValue(
                    path: ref,
                    screenId: context.screenId ?? journey.flowState.currentScreenId,
                    instanceId: context.instanceId
                ) as Any
            }
            if dict.count == 1, let refValue = dict["ref"], let payloadPath = parsePayloadRefPath(refValue) {
                return resolvePayloadPath(payloadPath, in: context.payload) as Any
            }
            var resolved: [String: Any] = [:]
            for (key, entry) in dict {
                resolved[key] = resolveValueRefs(entry, context: context)
            }
            return resolved
        }
        if let dict = value as? [String: AnyCodable] {
            if dict.count == 1, let literal = dict["literal"]?.value {
                return literal
            }
            if dict.count == 1, let refValue = dict["ref"]?.value, let ref = parseRefPath(refValue) {
                return viewModelState.getValue(
                    path: ref,
                    screenId: context.screenId ?? journey.flowState.currentScreenId,
                    instanceId: context.instanceId
                ) as Any
            }
            if dict.count == 1, let refValue = dict["ref"]?.value, let payloadPath = parsePayloadRefPath(refValue) {
                return resolvePayloadPath(payloadPath, in: context.payload) as Any
            }
            var resolved: [String: Any] = [:]
            for (key, entry) in dict {
                resolved[key] = resolveValueRefs(entry.value, context: context)
            }
            return resolved
        }
        return value
    }

    private func parseRefPath(_ value: Any) -> VmPathRef? {
        if let ref = value as? VmPathRef { return ref }
        if let dict = value as? [String: Any] {
            if dict["kind"] as? String == "path", let path = dict["path"] as? String {
                return VmPathRef(
                    viewModelName: dict["viewModelName"] as? String,
                    path: path,
                    isRelative: dict["isRelative"] as? Bool
                )
            }
        }
        if let dict = value as? [String: AnyCodable] {
            if dict["kind"]?.value as? String == "path", let path = dict["path"]?.value as? String {
                return VmPathRef(
                    viewModelName: dict["viewModelName"]?.value as? String,
                    path: path,
                    isRelative: dict["isRelative"]?.value as? Bool
                )
            }
        }
        return nil
    }

    private func parsePayloadRefPath(_ value: Any) -> String? {
        if let dict = value as? [String: Any],
           dict["kind"] as? String == "payload",
           let path = dict["path"] as? String,
           !path.isEmpty {
            return path
        }
        if let dict = value as? [String: AnyCodable],
           dict["kind"]?.value as? String == "payload",
           let path = dict["path"]?.value as? String,
           !path.isEmpty {
            return path
        }
        return nil
    }

    private func evalConditionIR(_ envelope: IREnvelope?, event: NuxieEvent?) async -> Bool {
        guard let envelope else { return true }

        let config = IRRuntime.Config.standard(event: event)

        return await irRuntime.eval(envelope, config)
    }

    private func resolveExperimentVariant(
        _ action: ExperimentAction,
        assignment: ExperimentAssignment?
    ) -> (variant: ExperimentVariant?, matchedAssignment: Bool) {
        guard let assignment else {
            return (action.variants.first, false)
        }

        switch assignment.status {
        case "running", "concluded":
            if let variantKey = assignment.variantKey,
               let variant = action.variants.first(where: { $0.id == variantKey }) {
                return (variant, true)
            }
            return (action.variants.first, false)
        default:
            return (action.variants.first, false)
        }
    }

    private func getServerAssignment(experimentId: String) async -> ExperimentAssignment? {
        guard let profile = await profileService.getCachedProfile(distinctId: journey.distinctId) else {
            return nil
        }
        return profile.experiments?[experimentId]
    }

    // -------------------------------------------------------------------------
    // Experiment Exposure Dedupe + Freeze
    // -------------------------------------------------------------------------

    private enum ExperimentContextKeys {
        static let frozenVariantsByExperiment = "_experiment_variants"
        static let exposureEmittedByExperiment = "_experiment_exposure_emitted"
    }

    private func getFrozenExperimentVariantKey(experimentKey: String) -> String? {
        guard let dict = journey.getContext(ExperimentContextKeys.frozenVariantsByExperiment) as? [String: Any] else {
            return nil
        }
        return dict[experimentKey] as? String
    }

    private func freezeExperimentVariantKey(experimentKey: String, variantKey: String) {
        guard !experimentKey.isEmpty, !variantKey.isEmpty else { return }
        var dict =
            (journey.getContext(ExperimentContextKeys.frozenVariantsByExperiment) as? [String: Any]) ?? [:]
        dict[experimentKey] = variantKey
        journey.setContext(ExperimentContextKeys.frozenVariantsByExperiment, value: dict)
    }

    private func hasEmittedExperimentExposure(experimentKey: String) -> Bool {
        guard let dict = journey.getContext(ExperimentContextKeys.exposureEmittedByExperiment) as? [String: Any] else {
            return false
        }
        if let emitted = dict[experimentKey] as? Bool {
            return emitted
        }
        if let emitted = dict[experimentKey] as? Int {
            return emitted != 0
        }
        if let emitted = dict[experimentKey] as? String {
            return emitted == "true" || emitted == "1"
        }
        return false
    }

    private func markExperimentExposureEmitted(experimentKey: String) {
        guard !experimentKey.isEmpty else { return }
        var dict =
            (journey.getContext(ExperimentContextKeys.exposureEmittedByExperiment) as? [String: Any]) ?? [:]
        dict[experimentKey] = true
        journey.setContext(ExperimentContextKeys.exposureEmittedByExperiment, value: dict)
    }

    private func parseTime(_ timeString: String) -> DateComponents? {
        let parts = timeString.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1])
        else { return nil }

        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        return components
    }

    private func calculateNextValidDay(from date: Date, validDays: [Int], timezone: TimeZone) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timezone

        for i in 1...7 {
            guard let nextDate = cal.date(byAdding: .day, value: i, to: date) else { continue }
            let weekday = cal.component(.weekday, from: nextDate)
            if validDays.contains(weekday) {
                var comps = cal.dateComponents([.year, .month, .day], from: nextDate)
                comps.hour = 0
                comps.minute = 0
                comps.second = 0
                comps.timeZone = timezone
                return cal.date(from: comps) ?? nextDate
            }
        }

        return date
    }

    private func calculateNextWindowOpen(
        from date: Date,
        startTime: String,
        timezone: TimeZone,
        validDays: [Int]?
    ) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timezone

        guard let startHM = parseTime(startTime),
              let sh = startHM.hour, let sm = startHM.minute
        else { return date }

        var today = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        today.hour = sh
        today.minute = sm
        today.second = 0
        today.timeZone = timezone

        var nextOpen = cal.date(from: today) ?? date

        if nextOpen <= date {
            nextOpen = cal.date(byAdding: .day, value: 1, to: nextOpen) ?? nextOpen
        }

        if let days = validDays, !days.isEmpty {
            while true {
                let wd = cal.component(.weekday, from: nextOpen)
                if days.contains(wd) { break }
                nextOpen = cal.date(byAdding: .day, value: 1, to: nextOpen) ?? nextOpen
            }
        }

        return nextOpen
    }
}

private extension JourneyAction {
    var actionType: String {
        switch self {
        case .navigate: return "navigate"
        case .back: return "back"
        case .delay: return "delay"
        case .timeWindow: return "time_window"
        case .waitUntil: return "wait_until"
        case .condition: return "condition"
        case .experiment: return "experiment"
        case .sendEvent: return "send_event"
        case .goal: return "goal"
        case .updateCustomer: return "update_customer"
        case .setResponseField: return "set_response_field"
        case .submitResponse: return "submit_response"
        case .purchase: return "purchase"
        case .restore: return "restore"
        case .requestNotifications: return "request_notifications"
        case .requestPermission: return "request_permission"
        case .requestTracking: return "request_tracking"
        case .openLink: return "open_link"
        case .dismiss: return "dismiss"
        case .callDelegate: return "call_delegate"
        case .remote: return "remote"
        case .setViewModel: return "set_view_model"
        case .fireTrigger: return "fire_trigger"
        case .listInsert: return "list_insert"
        case .listRemove: return "list_remove"
        case .listSwap: return "list_swap"
        case .listMove: return "list_move"
        case .listSet: return "list_set"
        case .listClear: return "list_clear"
        case .exit: return "exit"
        case .unknown(let type, _): return type
        }
    }
}
