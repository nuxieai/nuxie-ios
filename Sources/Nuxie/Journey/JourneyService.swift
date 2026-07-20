import FactoryKit
import Foundation

/// Reason for resuming a journey
public enum ResumeReason {
  case start
  case timer
  case event(NuxieEvent)
  case segmentChange

  var isReactive: Bool {
    switch self {
    case .event, .segmentChange:
      return true
    case .start, .timer:
      return false
    }
  }
}

/// Protocol for journey management
public protocol JourneyServiceProtocol: AnyObject {
  @discardableResult
  func startJourney(for campaign: Campaign, distinctId: String, originEventId: String?) async -> Journey?

  func resumeJourney(_ journey: Journey) async


  func handleEvent(_ event: NuxieEvent) async

  func handleEventForTrigger(_ event: NuxieEvent) async -> [JourneyTriggerResult]

  func handleSegmentChange(distinctId: String, segments: Set<String>) async

  func getActiveJourneys(for distinctId: String) async -> [Journey]

  func checkExpiredTimers() async

  func initialize() async

  func onAppWillEnterForeground() async

  func onAppBecameActive() async

  func onAppDidEnterBackground() async

  func shutdown() async

  func handleUserChange(from oldDistinctId: String, to newDistinctId: String) async
}

public actor JourneyService: JourneyServiceProtocol {

  // MARK: - Dependencies

  private let journeyStore: JourneyStoreProtocol

  @Injected(\.flowService) private var flowService: FlowServiceProtocol
  @Injected(\.flowPresentationService) private var flowPresentationService: FlowPresentationServiceProtocol
  @Injected(\.profileService) private var profileService: ProfileServiceProtocol
  @Injected(\.identityService) private var identityService: IdentityServiceProtocol
  @Injected(\.segmentService) private var segmentService: SegmentServiceProtocol
  @Injected(\.featureService) private var featureService: FeatureServiceProtocol
  @Injected(\.featureInfo) private var featureInfo: FeatureInfo
  @Injected(\.eventService) private var eventService: EventServiceProtocol
  @Injected(\.triggerBroker) private var triggerBroker: TriggerBrokerProtocol
  @Injected(\.dateProvider) private var dateProvider: DateProviderProtocol
  @Injected(\.sleepProvider) private var sleepProvider: SleepProviderProtocol
  @Injected(\.goalEvaluator) private var goalEvaluator: GoalEvaluatorProtocol
  @Injected(\.irRuntime) private var irRuntime: IRRuntime

  // MARK: - State

  private var inMemoryJourneysById: [String: Journey] = [:]
  private var flowRunners: [String: FlowJourneyRunner] = [:]
  private var runtimeDelegates: [String: FlowRuntimeDelegateAdapter] = [:]
  private var activeTasks: [String: Task<Void, Never>] = [:]
  private var segmentMonitoringTask: Task<Void, Never>?

  // MARK: - Initialization

  internal init(
    journeyStore: JourneyStoreProtocol? = nil,
    customStoragePath: URL? = nil
  ) {
    self.journeyStore = journeyStore ?? JourneyStore(customStoragePath: customStoragePath)
    LogInfo("JourneyService initialized")
  }

  deinit {
    segmentMonitoringTask?.cancel()
  }

  // MARK: - Lifecycle

  public func initialize() async {
    LogInfo("Initializing JourneyService...")

    let persisted = journeyStore.loadActiveJourneys()
    LogInfo("Restored \(persisted.count) active journeys")

    for journey in persisted where journey.status.isLive {
      inMemoryJourneysById[journey.id] = journey

      if let pending = journey.flowState.pendingAction, let resumeAt = pending.resumeAt {
        scheduleResume(journeyId: journey.id, at: resumeAt)
      }
    }

    await checkExpiredTimers()
    registerForSegmentChanges()
  }

  public func onAppWillEnterForeground() async {
    await checkExpiredTimers()

    let now = dateProvider.now()
    for journey in inMemoryJourneysById.values where journey.status.isLive {
      if let pending = journey.flowState.pendingAction,
         let resumeAt = pending.resumeAt,
         resumeAt > now {
        scheduleResume(journeyId: journey.id, at: resumeAt)
      }
    }
  }

  public func onAppBecameActive() async {
    await flowPresentationService.onAppBecameActive()
  }

  public func onAppDidEnterBackground() async {
    cancelAllTasks()
    await flowPresentationService.onAppDidEnterBackground()

    for journey in inMemoryJourneysById.values where journey.status.isLive {
      persistJourney(journey)
    }

    LogInfo("JourneyService background snapshot complete")
  }

  public func shutdown() async {
    segmentMonitoringTask?.cancel()
    segmentMonitoringTask = nil
    cancelAllTasks()
  }

  public func handleUserChange(from oldDistinctId: String, to newDistinctId: String) async {
    LogInfo("JourneyService handling user change from \(NuxieLogger.shared.logDistinctID(oldDistinctId)) to \(NuxieLogger.shared.logDistinctID(newDistinctId))")

    let oldJourneys = await getActiveJourneys(for: oldDistinctId)
    for journey in oldJourneys {
      cancelJourney(journey)
    }

    inMemoryJourneysById = inMemoryJourneysById.filter { $0.value.distinctId != oldDistinctId }

    let persisted = journeyStore.loadActiveJourneys()
      .filter { $0.distinctId == newDistinctId && $0.status.isLive }

    for journey in persisted {
      inMemoryJourneysById[journey.id] = journey
      if let pending = journey.flowState.pendingAction, let resumeAt = pending.resumeAt {
        scheduleResume(journeyId: journey.id, at: resumeAt)
      }
    }

    await checkExpiredTimers()
  }

  // MARK: - Public API

  public func startJourney(
    for campaign: Campaign,
    distinctId: String,
    originEventId: String? = nil
  ) async -> Journey? {
    guard suppressionReason(campaign: campaign, distinctId: distinctId) == nil else {
      LogDebug("User \(distinctId) cannot start journey for campaign \(campaign.id)")
      return nil
    }

    return await startJourneyInternal(
      for: campaign,
      distinctId: distinctId,
      originEventId: originEventId,
    )
  }

  private func startJourneyInternal(
    for campaign: Campaign,
    distinctId: String,
    originEventId: String? = nil
  ) async -> Journey? {
    let flowId = campaign.flowId

    let journey = Journey(campaign: campaign, distinctId: distinctId)
    journey.status = .active
    if let originEventId {
      journey.setContext("_origin_event_id", value: originEventId)
    }

    inMemoryJourneysById[journey.id] = journey

    let flow = try? await flowService.fetchFlow(id: flowId)
    let entryScreenId = flow?.remoteFlow.screens.first?.id

    do {
      _ = try await eventService.trackWithResponse(
        "$journey_start",
        properties: [
          "session_id": journey.id,
          "campaign_id": campaign.id,
          "flow_id": campaign.flowId,
          "entry_node_id": entryScreenId as Any,
        ],
        flushStrategy: .eventService
      )
    } catch {
      LogWarning("JourneyService: Failed to persist journey start: \(error)")
      journey.cancel()
      inMemoryJourneysById.removeValue(forKey: journey.id)
      return nil
    }

    eventService.track(
      JourneyEvents.journeyStarted,
      properties: JourneyEvents.journeyStartedProperties(
        journey: journey,
        campaign: campaign,
        triggerEvent: nil,
        entryScreenId: entryScreenId
      ),
      userProperties: nil,
      userPropertiesSetOnce: nil
    )

    guard await ensureRunner(for: journey, campaign: campaign) != nil else {
      completeJourney(journey, reason: .error)
      return journey
    }

    // Persist at start: a crash (not a backgrounding) previously lost the
    // journey locally while the server had already recorded $journey_start.
    persistJourney(journey)

    return journey
  }

  public func resumeJourney(_ journey: Journey) async {
    guard journey.status == .paused || journey.status == .active else { return }

    guard let campaign = await getCampaign(id: journey.campaignId, for: journey.distinctId) else {
      cancelJourney(journey)
      return
    }

    guard let runner = await ensureRunner(for: journey, campaign: campaign) else {
      completeJourney(journey, reason: .error)
      return
    }

    journey.resume()
    inMemoryJourneysById[journey.id] = journey

    let outcome = await runner.resumePendingAction(reason: .timer, event: nil)
    handleOutcome(outcome, journey: journey)

    eventService.track(
      JourneyEvents.journeyResumed,
      properties: JourneyEvents.journeyResumedProperties(
        journey: journey,
        screenId: journey.flowState.currentScreenId,
        resumeReason: "timer"
      ),
      userProperties: nil,
      userPropertiesSetOnce: nil
    )
  }

  public func handleEvent(_ event: NuxieEvent) async {
    _ = await routeEvent(event)
  }

  public func handleEventForTrigger(_ event: NuxieEvent) async -> [JourneyTriggerResult] {
    return await routeEvent(event)
  }

  private func routeEvent(
    _ event: NuxieEvent
  ) async -> [JourneyTriggerResult] {
    guard let campaigns = await getAllCampaigns(for: event.distinctId) else { return [] }
    let results = await startJourneysMatchingEvent(
      event,
      campaigns: campaigns
    )
    await processActiveJourneys(
      for: event,
      campaigns: campaigns,
      transientEventsByJourneyId: [:],
      restrictedToJourneyIds: nil
    )
    return results
  }

  public func handleSegmentChange(distinctId: String, segments: Set<String>) async {
    guard let campaigns = await getAllCampaigns(for: distinctId) else { return }

    for campaign in campaigns {
      guard case .segment(let config) = campaign.trigger else { continue }
      let matches = await evalConditionIR(config.condition)
      if matches {
        _ = await startJourney(for: campaign, distinctId: distinctId, originEventId: nil)
      }
    }

    let journeys = await getActiveJourneys(for: distinctId)
    for journey in journeys {
      guard let campaign = campaigns.first(where: { $0.id == journey.campaignId }) else { continue }
      await evaluateGoalIfNeeded(journey, campaign: campaign)
      if !(await shouldDeferExitDecision(for: journey)) {
        if let reason = await exitDecision(journey, campaign) {
          completeJourney(journey, reason: reason)
        }
      }
    }
  }

  public func getActiveJourneys(for distinctId: String) async -> [Journey] {
    return inMemoryJourneysById.values.filter { $0.distinctId == distinctId && $0.status.isLive }
  }

  public func checkExpiredTimers() async {
    let now = dateProvider.now()

    for journey in inMemoryJourneysById.values where journey.status.isLive {
      if let pending = journey.flowState.pendingAction, let resumeAt = pending.resumeAt, resumeAt <= now {
        await resumeJourney(journey)
        continue
      }
    }
  }

  // MARK: - Renderer Events

  fileprivate func handleRuntimeReady(
    journeyId: String,
    controller: FlowViewController
  ) async {
    guard let journey = inMemoryJourneysById[journeyId],
          let runner = flowRunners[journeyId] else { return }

    let outcome = await runner.handleRuntimeReady()
    handleOutcome(outcome, journey: journey)
  }

  fileprivate func handleRendererScreenChanged(
    journeyId: String,
    screenId: String
  ) async {
    guard let journey = inMemoryJourneysById[journeyId],
          let runner = flowRunners[journeyId] else { return }

    let outcome = await runner.handleScreenChanged(screenId)
    handleOutcome(outcome, journey: journey)
    persistJourney(journey)

    eventService.track(
      "$journey_node_executed",
      properties: [
        "session_id": journey.id,
        "node_id": screenId,
        "async": true,
        "context": journey.context.mapValues { $0.value },
      ],
      userProperties: nil,
      userPropertiesSetOnce: nil
    )
  }

  fileprivate func handleRendererScreenDismissed(
    journeyId: String,
    screenId: String,
    revealingScreenId: String?
  ) async {
    guard let journey = inMemoryJourneysById[journeyId],
          let runner = flowRunners[journeyId] else { return }

    let outcome = await runner.handleScreenDismissed(
      screenId,
      revealingScreenId: revealingScreenId,
      method: "native_sheet"
    )
    handleOutcome(outcome, journey: journey)
    persistJourney(journey)

    if let revealingScreenId {
      eventService.track(
        "$journey_node_executed",
        properties: [
          "session_id": journey.id,
          "node_id": revealingScreenId,
          "async": true,
          "context": journey.context.mapValues { $0.value },
        ],
        userProperties: nil,
        userPropertiesSetOnce: nil
      )
    }
  }

  fileprivate func handleRendererViewModelChange(
    journeyId: String,
    change: FlowRendererViewModelChange
  ) async {
    guard let journey = inMemoryJourneysById[journeyId],
          let runner = flowRunners[journeyId] else { return }

    let outcome = await runner.handleDidSet(
      path: change.path,
      value: change.value,
      source: change.source,
      screenId: change.screenId ?? journey.flowState.currentScreenId,
      instanceId: change.instanceId,
      isTrigger: change.isTrigger
    )
    handleOutcome(outcome, journey: journey)
    persistJourney(journey)
  }

  fileprivate func handleRendererEvent(
    journeyId: String,
    event rendererEvent: FlowRendererEvent
  ) async {
    guard !rendererEvent.name.isEmpty else { return }
    guard let journey = inMemoryJourneysById[journeyId],
          let runner = flowRunners[journeyId] else { return }

    let eventProperties = await eventService.prepareTriggerProperties(
      rendererEvent.properties,
      userProperties: nil,
      userPropertiesSetOnce: nil
    )
    let event = NuxieEvent(
      name: rendererEvent.name,
      distinctId: journey.distinctId,
      properties: eventProperties
    )
    let outcome = await runner.dispatchScreenEvent(
      event,
      screenId: rendererEvent.screenId ?? journey.flowState.currentScreenId,
      componentId: rendererEvent.componentId,
      instanceId: rendererEvent.instanceId
    )
    handleOutcome(outcome, journey: journey)
    persistJourney(journey)

    let routedEvent: NuxieEvent
    let response: EventResponse?
    do {
      let tracked = try await eventService.trackForTrigger(
        rendererEvent.name,
        properties: rendererEvent.properties,
        userProperties: nil,
        userPropertiesSetOnce: nil,
        persistToHistory: true,
        distinctIdOverride: journey.distinctId
      )
      routedEvent = tracked.0
      response = tracked.1
    } catch {
      LogWarning("JourneyService: Failed to track renderer event \(rendererEvent.name): \(error)")
      routedEvent = event
      response = nil
    }

    let campaigns = await getAllCampaigns(for: routedEvent.distinctId) ?? []
    let sourceCampaign = sourceScopedGoalCampaign(for: journey, campaigns: campaigns)
    let transientEvent = makeStoredEvent(from: routedEvent)
    await processActiveJourneys(
      for: routedEvent,
      campaigns: campaigns,
      transientEventsByJourneyId: [journeyId: [transientEvent]],
      restrictedToJourneyIds: [journeyId],
      skipEventTriggerForJourneyIds: [journeyId],
      allowSnapshotFallback: true
    )

    await routeRendererEventOutsideSourceJourney(
      routedEvent,
      sourceJourneyId: journeyId,
      campaigns: campaigns
    )
    await handleScopedGatePlan(
      response?.gatePlan(),
      sourceJourney: journey,
      sourceCampaign: sourceCampaign
    )
  }

  private func routeRendererEventOutsideSourceJourney(
    _ event: NuxieEvent,
    sourceJourneyId: String,
    campaigns: [Campaign]
  ) async {
    let transientEvent = makeStoredEvent(from: event)
    let otherActiveJourneyIds = Set(
      await getActiveJourneys(for: event.distinctId)
        .map(\.id)
        .filter { $0 != sourceJourneyId }
    )

    if !otherActiveJourneyIds.isEmpty {
      let transientEventsByJourneyId = Dictionary(
        uniqueKeysWithValues: otherActiveJourneyIds.map { ($0, [transientEvent]) }
      )
      await processActiveJourneys(
        for: event,
        campaigns: campaigns,
        transientEventsByJourneyId: transientEventsByJourneyId,
        restrictedToJourneyIds: otherActiveJourneyIds
      )
    }

    let results = await startJourneysMatchingEvent(
      event,
      campaigns: campaigns,
    )
    let startedJourneyIds = Set(results.compactMap { result -> String? in
      guard case .started(let journey) = result else { return nil }
      return journey.id
    })
    guard !startedJourneyIds.isEmpty else { return }

    let transientEventsByJourneyId = Dictionary(
      uniqueKeysWithValues: startedJourneyIds.map { ($0, [transientEvent]) }
    )
    await processActiveJourneys(
      for: event,
      campaigns: campaigns,
      transientEventsByJourneyId: transientEventsByJourneyId,
      restrictedToJourneyIds: startedJourneyIds
    )
  }

  fileprivate func handleRendererOpenLink(
    journeyId: String,
    request: FlowRendererOpenLinkRequest
  ) async {
    guard let runner = flowRunners[journeyId] else { return }
    await runner.handleRuntimeOpenLink(
      url: request.urlString,
      target: request.target,
      screenId: request.screenId,
      instanceId: request.instanceId
    )
  }

  fileprivate func handleRuntimeDismiss(
    journeyId: String,
    reason: CloseReason,
    controller: FlowViewController
  ) async {
    guard let journey = inMemoryJourneysById[journeyId],
          let runner = flowRunners[journeyId] else { return }

    var userInfo: [String: Any] = [
      "journeyId": journey.id,
      "campaignId": journey.campaignId
    ]
    if let screenId = journey.flowState.currentScreenId {
      userInfo["screenId"] = screenId
    }
    switch reason {
    case .userDismissed:
      userInfo["reason"] = "user_dismissed"
    case .goalMet:
      userInfo["reason"] = "goal_met"
    case .purchaseCompleted:
      userInfo["reason"] = "purchase_completed"
    case .timeout:
      userInfo["reason"] = "timeout"
    case .error(let error):
      userInfo["reason"] = "error"
      userInfo["error"] = error.localizedDescription
    }
    NotificationCenter.default.post(
      name: .nuxieDismiss,
      object: nil,
      userInfo: userInfo
    )

    var properties: [String: Any] = [:]
    if let screenId = journey.flowState.currentScreenId {
      properties["screen_id"] = screenId
    }
    let method: String
    switch reason {
    case .userDismissed:
      method = "user"
    case .goalMet:
      method = "goal_met"
    case .purchaseCompleted:
      method = "purchase_completed"
    case .timeout:
      method = "timeout"
    case .error:
      method = "error"
    }
    properties["method"] = method
    let event = NuxieEvent(
      name: SystemEventNames.screenDismissed,
      distinctId: journey.distinctId,
      properties: properties
    )
    let outcome = await runner.dispatchEventTrigger(event)
    handleOutcome(outcome, journey: journey)
    if await runner.shouldAbandonResponseDraftsAfterDismiss() {
      await runner.abandonResponseDraftsIfNeeded()
    }

    if journey.status.isLive,
       let campaign = await getCampaign(id: journey.campaignId, for: journey.distinctId) {
      await evaluateGoalIfNeeded(journey, campaign: campaign)
      if let reason = await exitDecision(journey, campaign) {
        completeJourney(journey, reason: reason)
        return
      }
    }

    if journey.status.isLive, await runner.hasPendingPermissionWork() {
      await runner.deferDismiss(reason: reason)
      return
    }

    if journey.status.isLive {
      completeJourney(journey, reason: dismissalExitReason(for: reason))
    }
  }

  fileprivate func handleScopedPermissionEvent(
    journeyId: String,
    eventName: String,
    properties: [String: Any],
    distinctId: String
  ) async {
    let journey = inMemoryJourneysById[journeyId]
    let scopedDistinctId = journey?.distinctId ?? distinctId

    let enrichedProperties = await eventService.prepareTriggerProperties(
      properties,
      userProperties: nil,
      userPropertiesSetOnce: nil
    )

    let localScopedEvent = NuxieEvent(
      name: eventName,
      distinctId: scopedDistinctId,
      properties: enrichedProperties,
      timestamp: dateProvider.now()
    )

    let cachedCampaigns: [Campaign]? = if journey != nil {
      await getAllCampaigns(for: scopedDistinctId)
    } else {
      nil
    }
    let transientEvent = makeStoredEvent(from: localScopedEvent)
    if let cachedCampaigns {
      let activeJourneyIds = await getActiveJourneys(for: localScopedEvent.distinctId).map(\.id)
      let transientEventsByJourneyId: [String: [StoredEvent]] = Dictionary(
        uniqueKeysWithValues: activeJourneyIds.map { ($0, [transientEvent]) }
      )
      await processActiveJourneys(
        for: localScopedEvent,
        campaigns: cachedCampaigns,
        transientEventsByJourneyId: transientEventsByJourneyId,
        restrictedToJourneyIds: nil
      )
    }

    await completeDeferredDismissIfReady(journeyId: journeyId)

    let trackedEvent: NuxieEvent
    let response: EventResponse?
    do {
      let tracked = try await eventService.trackForTrigger(
        eventName,
        properties: properties,
        userProperties: nil,
        userPropertiesSetOnce: nil,
        persistToHistory: false,
        distinctIdOverride: scopedDistinctId
      )
      trackedEvent = tracked.0
      response = tracked.1
    } catch {
      LogWarning("JourneyService: Failed to track scoped permission event: \(error)")
      trackedEvent = NuxieEvent(
        name: eventName,
        distinctId: scopedDistinctId,
        properties: enrichedProperties
      )
      response = nil
    }

    guard journey != nil else {
      return
    }

    let scopedEvent = NuxieEvent(
      id: trackedEvent.id,
      name: trackedEvent.name,
      distinctId: scopedDistinctId,
      properties: trackedEvent.properties,
      timestamp: trackedEvent.timestamp
    )
    let trackedTransientEvent = makeStoredEvent(from: scopedEvent)

    let campaigns = if let cachedCampaigns {
      cachedCampaigns
    } else {
      await getAllCampaigns(for: scopedEvent.distinctId)
    }
    if let campaigns {
      let results = await startJourneysMatchingEvent(
        scopedEvent,
        campaigns: campaigns,
        )
      let startedJourneyIds = Set(results.compactMap { result -> String? in
        guard case .started(let startedJourney) = result else { return nil }
        return startedJourney.id
      })
      if !startedJourneyIds.isEmpty {
        let transientEventsByJourneyId: [String: [StoredEvent]] = Dictionary(
          uniqueKeysWithValues: startedJourneyIds.map { ($0, [trackedTransientEvent]) }
        )
        await processActiveJourneys(
          for: scopedEvent,
          campaigns: campaigns,
          transientEventsByJourneyId: transientEventsByJourneyId,
          restrictedToJourneyIds: startedJourneyIds
        )
      }
    }
    await handleScopedGatePlan(response?.gatePlan())
  }

  func handleScopedGoalEvent(
    journeyId: String,
    goalId: String,
    goalLabel: String?,
    screenId: String?,
    handlerId: String? = nil
  ) async {
    guard let journey = inMemoryJourneysById[journeyId] else {
      return
    }

    let scopedDistinctId = journey.distinctId
    let properties = JourneyEvents.journeyGoalHitProperties(
      journey: journey,
      screenId: screenId,
      handlerId: handlerId,
      goalId: goalId,
      goalLabel: goalLabel
    )
    let enrichedProperties = await eventService.prepareTriggerProperties(
      properties,
      userProperties: nil,
      userPropertiesSetOnce: nil
    )
    let localScopedEvent = NuxieEvent(
      name: JourneyEvents.journeyGoalHit,
      distinctId: scopedDistinctId,
      properties: enrichedProperties,
      timestamp: dateProvider.now()
    )
    let cachedCampaigns: [Campaign]? = await getAllCampaigns(for: scopedDistinctId)
    let transientEvent = makeStoredEvent(from: localScopedEvent)
    let sourceCampaign = sourceScopedGoalCampaign(
      for: journey,
      campaigns: cachedCampaigns
    )
    let sourceJourneyCompleted = await processSourceScopedGoalJourneyEvent(
      journey,
      campaign: sourceCampaign,
      event: localScopedEvent,
      transientEvent: transientEvent,
      shouldDispatchToRunner: false
    )
    let otherActiveJourneyIds = Set(
      await getActiveJourneys(for: localScopedEvent.distinctId)
        .map(\.id)
        .filter { $0 != journey.id }
    )
    if !otherActiveJourneyIds.isEmpty {
      let transientEventsByJourneyId: [String: [StoredEvent]] = Dictionary(
        uniqueKeysWithValues: otherActiveJourneyIds.map { ($0, [transientEvent]) }
      )
      await processActiveJourneys(
        for: localScopedEvent,
        campaigns: cachedCampaigns ?? [],
        transientEventsByJourneyId: transientEventsByJourneyId,
        restrictedToJourneyIds: otherActiveJourneyIds,
        allowSnapshotFallback: true
      )
    }

    let trackedEvent: NuxieEvent
    let response: EventResponse?
    do {
      let tracked = try await eventService.trackForTrigger(
        JourneyEvents.journeyGoalHit,
        properties: properties,
        userProperties: nil,
        userPropertiesSetOnce: nil,
        persistToHistory: false,
        distinctIdOverride: scopedDistinctId
      )
      trackedEvent = tracked.0
      response = tracked.1
    } catch {
      LogWarning("JourneyService: Failed to track scoped goal event: \(error)")
      trackedEvent = NuxieEvent(
        name: JourneyEvents.journeyGoalHit,
        distinctId: scopedDistinctId,
        properties: enrichedProperties
      )
      response = nil
    }

    let scopedEvent = NuxieEvent(
      id: trackedEvent.id,
      name: trackedEvent.name,
      distinctId: scopedDistinctId,
      properties: trackedEvent.properties,
      timestamp: trackedEvent.timestamp
    )
    await eventService.storePreparedEventInHistory(localScopedEvent)

    let campaigns = if let cachedCampaigns {
      cachedCampaigns
    } else {
      await getAllCampaigns(for: scopedEvent.distinctId)
    }
    let resolvedSourceCampaign = sourceScopedGoalCampaign(
      for: journey,
      campaigns: campaigns ?? cachedCampaigns
    )
    var sourceJourneyStillCompleted = sourceJourneyCompleted
    if !sourceJourneyStillCompleted {
      sourceJourneyStillCompleted = await processSourceScopedGoalJourneyEvent(
        journey,
        campaign: resolvedSourceCampaign,
        event: scopedEvent,
        transientEvent: transientEvent,
        shouldDispatchToRunner: true
      )
    }
    if let campaigns {
      let results = await startJourneysMatchingEvent(
        scopedEvent,
        campaigns: campaigns,
        )
      let startedJourneyIds = Set(results.compactMap { result -> String? in
        guard case .started(let startedJourney) = result else { return nil }
        return startedJourney.id
      })
      if !startedJourneyIds.isEmpty {
        let transientEventsByJourneyId: [String: [StoredEvent]] = Dictionary(
          uniqueKeysWithValues: startedJourneyIds.map { ($0, [transientEvent]) }
        )
        await processActiveJourneys(
          for: scopedEvent,
          campaigns: campaigns,
          transientEventsByJourneyId: transientEventsByJourneyId,
          restrictedToJourneyIds: startedJourneyIds
        )
      }
    }
    await handleScopedGatePlan(
      response?.gatePlan(),
      sourceJourney: journey,
      sourceCampaign: resolvedSourceCampaign
    )
  }

  fileprivate func handleUnsupportedScopedRequestPermission(
    journeyId: String,
    permissionType: String,
    distinctId: String
  ) async {
    let enrichedProperties = await eventService.prepareTriggerProperties(
      ["journey_id": journeyId, "type": permissionType],
      userProperties: nil,
      userPropertiesSetOnce: nil
    )
    let localScopedEvent = NuxieEvent(
      name: SystemEventNames.permissionDenied,
      distinctId: distinctId,
      properties: enrichedProperties,
      timestamp: dateProvider.now()
    )
    let transientEvent = makeStoredEvent(from: localScopedEvent)
    if let campaigns = await getAllCampaigns(for: distinctId) {
      await processActiveJourneys(
        for: localScopedEvent,
        campaigns: campaigns,
        transientEventsByJourneyId: [journeyId: [transientEvent]],
        restrictedToJourneyIds: [journeyId]
      )
    }

    await completeDeferredDismissIfReady(journeyId: journeyId)

    let response: EventResponse?
    do {
      let tracked = try await eventService.trackForTrigger(
        SystemEventNames.permissionDenied,
        properties: enrichedProperties,
        userProperties: nil,
        userPropertiesSetOnce: nil,
        persistToHistory: false,
        distinctIdOverride: distinctId
      )
      response = tracked.1
    } catch {
      response = nil
      LogWarning("JourneyService: Failed to track unsupported scoped permission event: \(error)")
    }

    await handleScopedGatePlan(response?.gatePlan())
  }

  // MARK: - Helpers

  private func dismissalExitReason(for reason: CloseReason) -> JourneyExitReason {
    switch reason {
    case .userDismissed:
      return .dismissed
    case .goalMet:
      return .goalMet
    case .error:
      return .error
    case .purchaseCompleted, .timeout:
      return .completed
    }
  }

  private func completeDeferredDismissIfReady(journeyId: String) async {
    guard let journey = inMemoryJourneysById[journeyId],
          let runner = flowRunners[journeyId],
          journey.status.isLive,
          let reason = await runner.consumeDeferredDismissReasonIfReady() else { return }
    completeJourney(journey, reason: dismissalExitReason(for: reason))
  }

  private func processSourceScopedGoalJourneyEvent(
    _ journey: Journey,
    campaign: Campaign?,
    event: NuxieEvent,
    transientEvent: StoredEvent,
    shouldDispatchToRunner: Bool
  ) async -> Bool {
    if let campaign {
      await evaluateGoalIfNeeded(
        journey,
        campaign: campaign,
        transientEvents: [transientEvent]
      )
      if !(await shouldDeferExitDecision(for: journey)) {
        if let reason = await exitDecision(journey, campaign) {
          completeJourney(journey, reason: reason)
          return true
        }
      }
      if await shouldCompletePresentedScopedGoalJourney(journey, campaign: campaign) {
        if let controller = await flowRunners[journey.id]?.viewController {
          await handleRuntimeDismiss(
            journeyId: journey.id,
            reason: .goalMet,
            controller: controller
          )
          await flowPresentationService.dismissCurrentFlow(reason: .goalMet)
        } else {
          await flowPresentationService.dismissCurrentFlow()
          completeJourney(journey, reason: .goalMet)
        }
        return true
      }
    }
    guard shouldDispatchToRunner else {
      return !journey.status.isLive
    }
    guard journey.status.isLive else {
      return true
    }

    if let pending = journey.flowState.pendingAction, pending.kind == .waitUntil {
      if let runner = flowRunners[journey.id] {
        let outcome = await runner.resumePendingAction(reason: .event(event), event: event)
        handleOutcome(outcome, journey: journey)
      }
      return !journey.status.isLive
    }

    if let runner = flowRunners[journey.id] {
      let outcome = await runner.dispatchEventTrigger(event)
      handleOutcome(outcome, journey: journey)
    }
    return !journey.status.isLive
  }

  private func sourceScopedGoalCampaign(
    for journey: Journey,
    campaigns: [Campaign]?
  ) -> Campaign? {
    if let campaign = campaigns?.first(where: { $0.id == journey.campaignId }) {
      return campaign
    }
    guard journey.goalSnapshot != nil || journey.exitPolicySnapshot != nil else {
      return nil
    }

    // Use the journey snapshots so scoped goal completion still works after
    // the profile cache ages out for a long-lived presented flow.
    return Campaign(
      id: journey.campaignId,
      name: "Journey Snapshot",
      flowId: journey.flowId,
      flowNumber: 0,
      flowName: nil,
      reentry: .everyTime,
      publishedAt: journey.startedAt.ISO8601Format(),
      trigger: journey.triggerSnapshot ?? .event(
        EventTriggerConfig(
          eventName: JourneyEvents.journeyGoalHit,
          condition: nil
        )
      ),
      goal: journey.goalSnapshot,
      exitPolicy: journey.exitPolicySnapshot,
      conversionAnchor: journey.conversionAnchor.rawValue,
      campaignType: nil
    )
  }

  private func ensureRunner(for journey: Journey, campaign: Campaign) async -> FlowJourneyRunner? {
    if let existing = flowRunners[journey.id] {
      return existing
    }

    let flowId = campaign.flowId

    do {
      let flow = try await flowService.fetchFlow(id: flowId)
      let runner = FlowJourneyRunner(
        journey: journey,
        campaign: campaign,
        flow: flow,
        onGoalHit: { [weak self, journeyId = journey.id] goalId, goalLabel, screenId, handlerId in
          await self?.handleScopedGoalEvent(
            journeyId: journeyId,
            goalId: goalId,
            goalLabel: goalLabel,
            screenId: screenId,
            handlerId: handlerId
          )
        }
      )

      await runner.setOnShowScreen { [weak self, weak runner] (screenId: String, transition: AnyCodable?) async in
        guard let self else { return }
        let controller = try? await self.presentFlowIfNeeded(flowId: flowId, journey: journey)
        if let controller {
          await runner?.attach(viewController: controller)
          await MainActor.run {
            controller.navigate(to: screenId, transition: transition?.value)
          }
        }
      }
      flowRunners[journey.id] = runner

      // FlowPresentationService tracks $flow_shown on successful presentation;
      // tracking here as well double-counted every journey-driven flow (and
      // counted failed presentations).
      _ = try? await presentFlowIfNeeded(flowId: flowId, journey: journey)

      return runner
    } catch {
      LogError("Failed to load flow \(campaign.flowId) for journey \(journey.id): \(error)")
      return nil
    }
  }

  private func presentFlowIfNeeded(flowId: String, journey: Journey) async throws -> FlowViewController {
    if let runner = flowRunners[journey.id],
       let controller = await runner.viewController,
       await flowPresentationService.isFlowPresented {
      return controller
    }
    if let delegate = runtimeDelegates[journey.id] {
      let controller = try await flowPresentationService.presentFlow(flowId, from: journey, runtimeDelegate: delegate)
      if let runner = flowRunners[journey.id] {
        await runner.attach(viewController: controller)
      }
      return controller
    }

    let delegate = FlowRuntimeDelegateAdapter(
      journeyId: journey.id,
      distinctId: journey.distinctId,
      journeyService: self
    )
    runtimeDelegates[journey.id] = delegate
    let controller = try await flowPresentationService.presentFlow(flowId, from: journey, runtimeDelegate: delegate)
    if let runner = flowRunners[journey.id] {
      await runner.attach(viewController: controller)
    }
    return controller
  }

  private func handleOutcome(_ outcome: FlowJourneyRunner.RunOutcome?, journey: Journey) {
    guard let outcome else { return }
    switch outcome {
    case .paused(let pending):
      journey.pause()
      persistJourney(journey)
      if let resumeAt = pending.resumeAt {
        scheduleResume(journeyId: journey.id, at: resumeAt)
      }
      eventService.track(
        JourneyEvents.journeyPaused,
        properties: JourneyEvents.journeyPausedProperties(
          journey: journey,
          screenId: journey.flowState.currentScreenId,
          resumeAt: pending.resumeAt
        ),
        userProperties: nil,
        userPropertiesSetOnce: nil
      )
    case .exited(let reason):
      completeJourney(journey, reason: reason)
    }
  }

  private func scheduleResume(journeyId: String, at date: Date) {
    let key = taskKey(journeyId: journeyId, kind: "resume", id: nil)
    scheduleTask(key: key, at: date) { [weak self] in
      await self?.resumeJourneyIfCached(journeyId: journeyId)
    }
  }

  private func scheduleTask(key: String, at date: Date, work: @escaping () async -> Void) {
    activeTasks[key]?.cancel()

    let delay = max(0, date.timeIntervalSince(dateProvider.now()))
    let task = Task { [weak self] in
      guard let self else { return }
      await self.runScheduledTask(key: key, delay: delay, work: work)
    }

    activeTasks[key] = task
  }

  private func runScheduledTask(key: String, delay: TimeInterval, work: @escaping () async -> Void) async {
    do {
      try await sleepProvider.sleep(for: delay)
      guard !Task.isCancelled else { return }
      await work()
    } catch {
      LogDebug("Journey task \(key) cancelled/failed: \(error)")
    }
    clearTask(key)
  }

  private func resumeJourneyIfCached(journeyId: String) async {
    guard let journey = inMemoryJourneysById[journeyId] else { return }
    await resumeJourney(journey)
  }

  private func taskKey(journeyId: String, kind: String, id: String?) -> String {
    var key = "\(journeyId):\(kind)"
    if let id {
      key += ":\(id)"
    }
    return key
  }

  private func clearTask(_ key: String) {
    activeTasks.removeValue(forKey: key)
  }

  private func cancelAllTasks() {
    for (_, task) in activeTasks {
      task.cancel()
    }
    activeTasks.removeAll()
  }

  private func persistJourney(_ journey: Journey) {
    do {
      try journeyStore.saveJourney(journey)
    } catch {
      LogError("Failed to persist journey \(journey.id): \(error)")
    }
  }

  private func completeJourney(_ journey: Journey, reason: JourneyExitReason) {
    // Idempotency guard: callers check liveness and then suspend (goal eval,
    // exit decisions), so a reentrant actor call can reach here twice for the
    // same journey. A second completion must not re-emit exit events or
    // re-record completion.
    guard journey.status.isLive else { return }

    if reason == .cancelled {
      journey.cancel()
    } else {
      journey.complete(reason: reason)
    }

    let duration = journey.completedAt?.timeIntervalSince(journey.startedAt)
      ?? dateProvider.now().timeIntervalSince(journey.startedAt)

    eventService.track(
      "$journey_completed",
      properties: [
        "session_id": journey.id,
        "exit_reason": reason.rawValue,
        "goal_met": journey.convertedAt != nil,
        "goal_met_at": journey.convertedAt?.timeIntervalSince1970 as Any,
        "duration_seconds": duration,
      ],
      userProperties: nil,
      userPropertiesSetOnce: nil
    )

    eventService.track(
      JourneyEvents.journeyExited,
      properties: JourneyEvents.journeyExitedProperties(
        journey: journey,
        reason: reason,
        screenId: journey.flowState.currentScreenId
      ),
      userProperties: nil,
      userPropertiesSetOnce: nil
    )

    if reason == .error {
      eventService.track(
        JourneyEvents.journeyErrored,
        properties: JourneyEvents.journeyErroredProperties(
          journey: journey,
          screenId: journey.flowState.currentScreenId,
          errorMessage: "journey_exited_with_error"
        ),
        userProperties: nil,
        userPropertiesSetOnce: nil
      )
    }

    if let originEventId = journey.getContext("_origin_event_id") as? String {
      let update = JourneyUpdate(
        journeyId: journey.id,
        campaignId: journey.campaignId,
        flowId: journey.flowId,
        exitReason: reason,
        goalMet: journey.convertedAt != nil
      )
      Task { await triggerBroker.emit(eventId: originEventId, update: .journey(update)) }
    }

    cancelTasks(for: journey.id)
    flowRunners.removeValue(forKey: journey.id)
    runtimeDelegates.removeValue(forKey: journey.id)
    inMemoryJourneysById.removeValue(forKey: journey.id)

    journeyStore.deleteJourney(id: journey.id)

    // Reentry accounting: only genuine completions (natural exit, goal met,
    // user dismissal) count against oneTime/oncePerWindow policies. A journey
    // killed by logout (.cancelled) or a load failure (.error) must not
    // permanently burn a one-time campaign.
    switch reason {
    case .cancelled, .error:
      break
    default:
      let record = JourneyCompletionRecord(journey: journey)
      do {
        try journeyStore.recordCompletion(record)
      } catch {
        // A missed record loosens reentry (may re-show) rather than
        // permanently blocking — log loudly instead of silently swallowing.
        LogError("Failed to record journey completion for reentry accounting: \(error)")
      }
    }
  }

  private func cancelTasks(for journeyId: String) {
    let keys = activeTasks.keys.filter { $0.hasPrefix("\(journeyId):") }
    for key in keys {
      activeTasks[key]?.cancel()
      activeTasks.removeValue(forKey: key)
    }
  }

  private func cancelJourney(_ journey: Journey) {
    completeJourney(journey, reason: .cancelled)
  }

  private func startJourneysMatchingEvent(
    _ event: NuxieEvent,
    campaigns: [Campaign]
  ) async -> [JourneyTriggerResult] {
    var results: [JourneyTriggerResult] = []

    for campaign in campaigns {
      guard await shouldTriggerFromEvent(campaign: campaign, event: event) else { continue }

      if let reason = suppressionReason(campaign: campaign, distinctId: event.distinctId) {
        results.append(.suppressed(reason))
        continue
      }

      if let journey = await startJourneyInternal(
        for: campaign,
        distinctId: event.distinctId,
        originEventId: event.id
      ) {
        results.append(.started(journey))
      } else {
        results.append(.suppressed(.unknown("start_failed")))
      }
    }

    return results
  }

  private func processActiveJourneys(
    for event: NuxieEvent,
    campaigns: [Campaign],
    transientEventsByJourneyId: [String: [StoredEvent]],
    restrictedToJourneyIds: Set<String>? = nil,
    skipEventTriggerForJourneyIds: Set<String> = [],
    allowSnapshotFallback: Bool = false
  ) async {
    let journeys = await getActiveJourneys(for: event.distinctId)
    let eventJourneyId = event.properties["journey_id"] as? String

    for journey in journeys {
      if let restrictedToJourneyIds, !restrictedToJourneyIds.contains(journey.id) {
        continue
      }
      let campaign = campaigns.first(where: { $0.id == journey.campaignId }) ??
        (allowSnapshotFallback ? sourceScopedGoalCampaign(for: journey, campaigns: campaigns) : nil)

      if eventJourneyId == journey.id, let runner = flowRunners[journey.id] {
        await runner.handleScopedSystemPermissionEvent(event.name)
      }

      if let campaign {
        await evaluateGoalIfNeeded(
          journey,
          campaign: campaign,
          transientEvents: transientEventsByJourneyId[journey.id] ?? []
        )
        if !(await shouldDeferExitDecision(for: journey)) {
          if let reason = await exitDecision(journey, campaign) {
            completeJourney(journey, reason: reason)
            continue
          }
        }
      }

      if let pending = journey.flowState.pendingAction, pending.kind == .waitUntil {
        if let runner = flowRunners[journey.id] {
          let outcome = await runner.resumePendingAction(reason: .event(event), event: event)
          handleOutcome(outcome, journey: journey)
        }
        continue
      }

      if skipEventTriggerForJourneyIds.contains(journey.id) {
        continue
      }

      if let runner = flowRunners[journey.id] {
        let outcome = await runner.dispatchEventTrigger(event)
        handleOutcome(outcome, journey: journey)
      }
    }
  }

  private func closeSourceJourneyBeforeScopedGateFlowIfNeeded(
    journey: Journey?,
    campaign: Campaign?
  ) async {
    guard let journey, journey.status.isLive else { return }
    guard await flowPresentationService.presentedJourneyId == journey.id else { return }

    let closeReason: CloseReason = journey.convertedAt != nil ? .goalMet : .userDismissed
    if let controller = await flowRunners[journey.id]?.viewController {
      await handleRuntimeDismiss(
        journeyId: journey.id,
        reason: closeReason,
        controller: controller
      )
      await flowPresentationService.dismissCurrentFlow(reason: closeReason)
      return
    }

    await flowPresentationService.dismissCurrentFlow(reason: closeReason)
    completeJourney(journey, reason: dismissalExitReason(for: closeReason))
  }

  private func handleScopedGatePlan(
    _ plan: GatePlan?,
    sourceJourney: Journey? = nil,
    sourceCampaign: Campaign? = nil
  ) async {
    guard let plan else { return }

    switch plan.decision {
    case .allow, .deny:
      return

    case .showFlow:
      guard let flowId = plan.flowId else { return }
      await closeSourceJourneyBeforeScopedGateFlowIfNeeded(
        journey: sourceJourney,
        campaign: sourceCampaign
      )
      _ = try? await flowPresentationService.presentFlow(flowId, from: nil, runtimeDelegate: nil)

    case .requireFeature:
      guard let featureId = plan.featureId else { return }

      if plan.policy == .cacheOnly {
        let cached = await currentFeatureAccess(featureId: featureId)
        if hasAccess(cached, requiredBalance: plan.requiredBalance) {
          return
        }
        return
      } else {
        if let cached = await currentFeatureAccess(featureId: featureId),
           hasAccess(cached, requiredBalance: plan.requiredBalance) {
          return
        }

        if let access = try? await featureService.checkWithCache(
          featureId: featureId,
          requiredBalance: plan.requiredBalance,
          entityId: plan.entityId,
          forceRefresh: false
        ), hasAccess(access, requiredBalance: plan.requiredBalance) {
          return
        }
      }

      guard let flowId = plan.flowId else { return }
      await closeSourceJourneyBeforeScopedGateFlowIfNeeded(
        journey: sourceJourney,
        campaign: sourceCampaign
      )
      _ = try? await flowPresentationService.presentFlow(flowId, from: nil, runtimeDelegate: nil)
    }
  }

  private func currentFeatureAccess(featureId: String) async -> FeatureAccess? {
    let featureInfo = self.featureInfo
    return await MainActor.run {
      featureInfo.feature(featureId)
    }
  }

  private func hasAccess(_ access: FeatureAccess?, requiredBalance: Int?) -> Bool {
    guard let access else { return false }
    if access.type == .boolean {
      return access.allowed
    }
    if access.unlimited {
      return true
    }
    return (access.balance ?? 0) >= (requiredBalance ?? 1)
  }

  // MARK: - Goals + Exit Policy

  private func evaluateGoalIfNeeded(
    _ journey: Journey,
    campaign: Campaign,
    transientEvents: [StoredEvent] = []
  ) async {
    guard journey.convertedAt == nil else { return }
    guard journey.goalSnapshot != nil else { return }

    let result = await goalEvaluator.isGoalMet(
      journey: journey,
      campaign: campaign,
      transientEvents: transientEvents
    )
    // A met goal latches even when the evaluator couldn't recover a precise
    // timestamp (e.g. zero-arg .and) — requiring `at` made such goals
    // re-evaluate forever without ever converting.
    if result.met {
      let at = result.at ?? dateProvider.now()
      journey.convertedAt = at
      journey.updatedAt = dateProvider.now()
      persistJourney(journey)

      eventService.track(
        JourneyEvents.journeyGoalMet,
        properties: [
          "journey_id": journey.id,
          "campaign_id": journey.campaignId,
          "goal_kind": journey.goalSnapshot?.kind.rawValue ?? "",
          "met_at": at.timeIntervalSince1970,
          "window_seconds": journey.conversionWindow,
        ],
        userProperties: nil,
        userPropertiesSetOnce: nil
      )
    }
  }

  private func makeStoredEvent(from event: NuxieEvent) -> StoredEvent {
    (try? StoredEvent(
      id: event.id,
      name: event.name,
      properties: event.properties,
      timestamp: event.timestamp,
      distinctId: event.distinctId
    )) ?? StoredEvent(
      id: event.id,
      name: event.name,
      properties: Data(),
      timestamp: event.timestamp,
      distinctId: event.distinctId,
      sessionId: event.properties["$session_id"] as? String
    )
  }

  private func exitDecision(_ journey: Journey, _ campaign: Campaign) async -> JourneyExitReason? {

    let mode = journey.exitPolicySnapshot?.mode ?? .never

    if (mode == .onGoal || mode == .onGoalOrStop), journey.convertedAt != nil {
      return .goalMet
    }

    if mode == .onStopMatching || mode == .onGoalOrStop {
      if case .segment(let config) = campaign.trigger {
        let stillMatches = await evalConditionIR(config.condition)
        if !stillMatches {
          return .triggerUnmatched
        }
      }
    }

    return nil
  }

  private func shouldDeferExitDecision(for journey: Journey) async -> Bool {
    guard await flowPresentationService.isFlowPresented else {
      return false
    }
    return await flowPresentationService.presentedJourneyId == journey.id
  }

  private func shouldCompletePresentedScopedGoalJourney(
    _ journey: Journey,
    campaign: Campaign
  ) async -> Bool {
    guard journey.status.isLive, journey.convertedAt != nil else {
      return false
    }
    guard await shouldDeferExitDecision(for: journey) else {
      return false
    }
    return await exitDecision(journey, campaign) == .goalMet
  }

  // MARK: - Reentry Policy

  private func suppressionReason(campaign: Campaign, distinctId: String) -> SuppressReason? {
    let live = inMemoryJourneysById.values.filter {
      $0.distinctId == distinctId && $0.campaignId == campaign.id && $0.status.isLive
    }
    if !live.isEmpty { return .alreadyActive }

    switch campaign.reentry {
    case .everyTime:
      return nil
    case .oneTime:
      let completed = journeyStore.hasCompletedCampaign(distinctId: distinctId, campaignId: campaign.id)
      return completed ? .reentryLimited : nil
    case .oncePerWindow(let window):
      guard let lastCompletion = journeyStore.lastCompletionTime(distinctId: distinctId, campaignId: campaign.id) else {
        return nil
      }
      let interval = windowInterval(window)
      let allowed = dateProvider.timeIntervalSince(lastCompletion) >= interval
      return allowed ? nil : .reentryLimited
    }
  }

  private func windowInterval(_ window: Window) -> TimeInterval {
    switch window.unit {
    case .minute: return TimeInterval(window.amount * 60)
    case .hour: return TimeInterval(window.amount * 3600)
    case .day: return TimeInterval(window.amount * 86400)
    case .week: return TimeInterval(window.amount * 604800)
    }
  }

  // MARK: - Campaign Lookup

  private func getCampaign(id: String) async -> Campaign? {
    guard let profile = await profileService.getCachedProfile(distinctId: identityService.getDistinctId()) else {
      return nil
    }
    return profile.campaigns.first { $0.id == id }
  }

  private func getCampaign(id: String, for distinctId: String) async -> Campaign? {
    guard let profile = await profileService.getCachedProfile(distinctId: distinctId) else {
      return nil
    }
    return profile.campaigns.first { $0.id == id }
  }

  private func getAllCampaigns() async -> [Campaign]? {
    guard let profile = await profileService.getCachedProfile(distinctId: identityService.getDistinctId()) else {
      return nil
    }
    return profile.campaigns
  }

  private func getAllCampaigns(for distinctId: String) async -> [Campaign]? {
    guard let profile = await profileService.getCachedProfile(distinctId: distinctId) else {
      return nil
    }
    return profile.campaigns
  }

  // MARK: - Trigger Evaluation

  private func shouldTriggerFromEvent(campaign: Campaign, event: NuxieEvent) async -> Bool {
    switch campaign.trigger {
    case .event(let config):
      guard config.eventName == event.name else { return false }
      if let condition = config.condition {
        return await evalConditionIR(condition, event: event)
      }
      return true
    case .segment:
      return false
    }
  }

  private func evalConditionIR(_ envelope: IREnvelope?, event: NuxieEvent? = nil) async -> Bool {
    guard let envelope else { return true }

    // engine_min gate: an envelope compiled for a newer engine is skipped
    // (fail-closed) rather than misevaluated.
    guard envelope.isSupportedByThisEngine else {
      LogWarning("IR: condition requires engine >= \(envelope.engine_min ?? "?") (have \(IREnvelope.engineVersion)) — skipping")
      return false
    }

    let userAdapter = IRUserPropsAdapter(identityService: identityService)
    let eventsAdapter = IREventQueriesAdapter(eventService: eventService)
    let segmentsAdapter = IRSegmentQueriesAdapter(segmentService: segmentService)
    let featuresAdapter = IRFeatureQueriesAdapter(featureService: featureService)

    let config = IRRuntime.Config(
      event: event,
      user: userAdapter,
      events: eventsAdapter,
      segments: segmentsAdapter,
      features: featuresAdapter
    )

    return await irRuntime.eval(envelope, config)
  }

  // MARK: - Segment Integration

  private func registerForSegmentChanges() {
    segmentMonitoringTask?.cancel()

    segmentMonitoringTask = Task { [weak self] in
      guard let self else { return }
      for await result in await self.segmentService.segmentChanges {
        guard !Task.isCancelled else { break }

        let currentDistinctId = await self.identityService.getDistinctId()
        guard result.distinctId == currentDistinctId else { continue }

        let currentSegments = Set(result.entered.map { $0.id } + result.remained.map { $0.id })
        await self.handleSegmentChange(distinctId: result.distinctId, segments: currentSegments)
      }
    }
  }

}

private final class FlowRuntimeDelegateAdapter:
  FlowRuntimeDelegate,
  NotificationPermissionEventReceiver,
  RequestPermissionEventReceiver,
  TrackingPermissionEventReceiver
{
  private weak var journeyService: JourneyService?
  private let journeyId: String
  private let distinctId: String

  init(journeyId: String, distinctId: String, journeyService: JourneyService) {
    self.journeyId = journeyId
    self.distinctId = distinctId
    self.journeyService = journeyService
  }

  func flowViewControllerDidBecomeReady(_ controller: FlowViewController) {
    Task { [weak journeyService] in
      await journeyService?.handleRuntimeReady(
        journeyId: journeyId,
        controller: controller
      )
    }
  }

  func flowViewController(
    _ controller: FlowViewController,
    didChangeScreen screenId: String
  ) {
    Task { [weak journeyService] in
      await journeyService?.handleRendererScreenChanged(
        journeyId: journeyId,
        screenId: screenId
      )
    }
  }

  func flowViewController(
    _ controller: FlowViewController,
    didDismissScreen screenId: String,
    revealingScreenId: String?
  ) {
    Task { [weak journeyService] in
      await journeyService?.handleRendererScreenDismissed(
        journeyId: journeyId,
        screenId: screenId,
        revealingScreenId: revealingScreenId
      )
    }
  }

  func flowViewController(
    _ controller: FlowViewController,
    didEmitEvent event: FlowRendererEvent
  ) {
    Task { [weak journeyService] in
      await journeyService?.handleRendererEvent(
        journeyId: journeyId,
        event: event
      )
    }
  }

  func flowViewController(
    _ controller: FlowViewController,
    didEmitViewModelChange change: FlowRendererViewModelChange
  ) {
    Task { [weak journeyService] in
      await journeyService?.handleRendererViewModelChange(
        journeyId: journeyId,
        change: change
      )
    }
  }

  func flowViewController(
    _ controller: FlowViewController,
    didRequestOpenLink request: FlowRendererOpenLinkRequest
  ) {
    Task { [weak journeyService] in
      await journeyService?.handleRendererOpenLink(
        journeyId: journeyId,
        request: request
      )
    }
  }

  func flowViewControllerDidRequestDismiss(_ controller: FlowViewController, reason: CloseReason) {
    Task { [weak journeyService] in
      await journeyService?.handleRuntimeDismiss(
        journeyId: journeyId,
        reason: reason,
        controller: controller
      )
    }
  }

  func flowViewController(
    _ controller: FlowViewController,
    didResolveNotificationPermissionEvent eventName: String,
    properties: [String : Any],
    journeyId: String
  ) {
    Task { [weak journeyService] in
      await journeyService?.handleScopedPermissionEvent(
        journeyId: journeyId,
        eventName: eventName,
        properties: properties,
        distinctId: distinctId
      )
    }
  }

  func flowViewController(
    _ controller: FlowViewController,
    didResolveRequestPermissionEvent eventName: String,
    properties: [String : Any],
    journeyId: String
  ) {
    Task { [weak journeyService] in
      await journeyService?.handleScopedPermissionEvent(
        journeyId: journeyId,
        eventName: eventName,
        properties: properties,
        distinctId: distinctId
      )
    }
  }

  func flowViewController(
    _ controller: FlowViewController,
    didIgnoreUnsupportedRequestPermissionType permissionType: String,
    journeyId: String
  ) {
    Task { [weak journeyService] in
      await journeyService?.handleUnsupportedScopedRequestPermission(
        journeyId: journeyId,
        permissionType: permissionType,
        distinctId: distinctId
      )
    }
  }

  func flowViewController(
    _ controller: FlowViewController,
    didResolveTrackingPermissionEvent eventName: String,
    properties: [String : Any],
    journeyId: String
  ) {
    Task { [weak journeyService] in
      await journeyService?.handleScopedPermissionEvent(
        journeyId: journeyId,
        eventName: eventName,
        properties: properties,
        distinctId: distinctId
      )
    }
  }
}
