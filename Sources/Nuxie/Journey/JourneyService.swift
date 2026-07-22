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

  // Constructor-injected collaborators (Phase 4c composition root). The two
  // MainActor-isolated collaborators (flowPresentationService, featureInfo)
  private let flowService: ExperienceServiceProtocol
  private let flowPresentationService: ExperiencePresentationServiceProtocol
  private let profileService: ProfileServiceProtocol
  private let identityService: IdentityServiceProtocol
  private let segmentService: SegmentServiceProtocol
  private let featureService: FeatureServiceProtocol
  private let featureInfo: FeatureInfo
  private let eventLog: EventLogProtocol
  private let triggerBroker: TriggerBrokerProtocol
  private let dateProvider: DateProviderProtocol
  private let sleepProvider: SleepProviderProtocol
  private let goalEvaluator: GoalEvaluatorProtocol
  private let irRuntime: IRRuntime
  private let api: NuxieApiProtocol

  // MARK: - State

  private var inMemoryJourneysById: [String: Journey] = [:]
  private var flowRunners: [String: JourneyRunner] = [:]
  private var runtimeDelegates: [String: JourneyRendererBridge] = [:]
  private let timerScheduler: JourneyTimerScheduler
  private var segmentMonitoringTask: Task<Void, Never>?

  // MARK: - Initialization

  internal init(
    journeyStore: JourneyStoreProtocol,
    flows: ExperienceServiceProtocol,
    profile: ProfileServiceProtocol,
    identity: IdentityServiceProtocol,
    segments: SegmentServiceProtocol,
    features: FeatureServiceProtocol,
    flowPresentation: ExperiencePresentationServiceProtocol,
    featureInfo: FeatureInfo,
    eventLog: EventLogProtocol,
    triggerBroker: TriggerBrokerProtocol,
    dateProvider: DateProviderProtocol,
    sleepProvider: SleepProviderProtocol,
    goalEvaluator: GoalEvaluatorProtocol,
    irRuntime: IRRuntime,
    api: NuxieApiProtocol
  ) {
    self.journeyStore = journeyStore
    self.flowService = flows
    self.flowPresentationService = flowPresentation
    self.featureInfo = featureInfo
    self.profileService = profile
    self.identityService = identity
    self.segmentService = segments
    self.featureService = features
    self.eventLog = eventLog
    self.triggerBroker = triggerBroker
    self.dateProvider = dateProvider
    self.sleepProvider = sleepProvider
    self.goalEvaluator = goalEvaluator
    self.irRuntime = irRuntime
    self.api = api
    self.timerScheduler = JourneyTimerScheduler(
      dateProvider: dateProvider,
      sleepProvider: sleepProvider
    )
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
    timerScheduler.cancelAll()
    await flowPresentationService.onAppDidEnterBackground()

    for journey in inMemoryJourneysById.values where journey.status.isLive {
      persistJourney(journey)
    }

    LogInfo("JourneyService background snapshot complete")
  }

  public func shutdown() async {
    segmentMonitoringTask?.cancel()
    segmentMonitoringTask = nil
    timerScheduler.cancelAll()
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

    let journey = Journey(campaign: campaign, distinctId: distinctId, now: dateProvider.now())
    journey.status = .active
    if let originEventId {
      journey.setContext("_origin_event_id", value: originEventId, at: dateProvider.now())
    }

    inMemoryJourneysById[journey.id] = journey

    let flow = try? await flowService.fetchExperience(id: flowId)
    let entryScreenId = flow?.screens.screens.first?.id

    // Local-first enrollment: the journey starts NOW from cached config —
    // the server-RTT gate here meant offline/flaky-network users got no
    // journeys at all, defeating the entire client-side execution design
    // (and one serial RTT per matching campaign stalled the journey route
    // worker). $journey_start rides the durable queue instead: delivered
    // at-least-once with the event-id idempotency key; the server's journey
    // mirror tolerates late arrival.
    eventLog.track(
      "$journey_start",
      properties: [
        "session_id": journey.id,
        "campaign_id": campaign.id,
        "flow_id": campaign.flowId,
        "entry_node_id": entryScreenId as Any,
      ],
      userProperties: nil,
      userPropertiesSetOnce: nil
    )

    eventLog.track(
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

    journey.resume(at: dateProvider.now())
    inMemoryJourneysById[journey.id] = journey

    let outcome = await runner.resumePendingAction(reason: .timer, event: nil)
    handleOutcome(outcome, journey: journey)

    eventLog.track(
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

  func handleRuntimeReady(
    journeyId: String,
    controller: ExperienceViewController
  ) async {
    guard let journey = inMemoryJourneysById[journeyId],
          let runner = flowRunners[journeyId] else { return }

    let outcome = await runner.handleRuntimeReady()
    handleOutcome(outcome, journey: journey)
  }

  func handleRendererScreenChanged(
    journeyId: String,
    screenId: String
  ) async {
    guard let journey = inMemoryJourneysById[journeyId],
          let runner = flowRunners[journeyId] else { return }

    let outcome = await runner.handleScreenChanged(screenId)
    handleOutcome(outcome, journey: journey)
    persistJourney(journey)

    eventLog.track(
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

  func handleRendererScreenDismissed(
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
      eventLog.track(
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

  func handleRendererViewModelChange(
    journeyId: String,
    change: ExperienceRendererViewModelChange
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

  func handleRendererEvent(
    journeyId: String,
    event rendererEvent: ExperienceRendererEvent
  ) async {
    guard !rendererEvent.name.isEmpty else { return }
    guard let journey = inMemoryJourneysById[journeyId],
          let runner = flowRunners[journeyId] else { return }

    let eventProperties = await eventLog.prepareTriggerProperties(
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
      let tracked = try await eventLog.trackForTrigger(
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

  func handleRendererOpenLink(
    journeyId: String,
    request: ExperienceRendererOpenLinkRequest
  ) async {
    guard let runner = flowRunners[journeyId] else { return }
    await runner.handleRuntimeOpenLink(
      url: request.urlString,
      target: request.target,
      screenId: request.screenId,
      instanceId: request.instanceId
    )
  }

  func handleRuntimeDismiss(
    journeyId: String,
    reason: CloseReason,
    controller: ExperienceViewController
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
    let mapped = JourneyDismissalMapping.notificationReason(for: reason)
    userInfo["reason"] = mapped.reason
    if let errorDescription = mapped.errorDescription {
      userInfo["error"] = errorDescription
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
    properties["method"] = JourneyDismissalMapping.dismissMethod(for: reason)
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

  func handleScopedPermissionEvent(
    journeyId: String,
    eventName: String,
    properties: [String: Any],
    distinctId: String
  ) async {
    let journey = inMemoryJourneysById[journeyId]
    let scopedDistinctId = journey?.distinctId ?? distinctId

    let stage = await stageScopedEvent(
      name: eventName,
      properties: properties,
      distinctId: scopedDistinctId
    )
    let localScopedEvent = stage.localEvent

    let cachedCampaigns: [Campaign]? = if journey != nil {
      await getAllCampaigns(for: scopedDistinctId)
    } else {
      nil
    }
    let transientEvent = stage.transientEvent
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

    let (trackedEvent, response) = await trackScopedEvent(stage, properties: properties)

    guard journey != nil else {
      return
    }

    let scopedEvent = confirmedScopedEvent(from: trackedEvent, distinctId: scopedDistinctId)
    let trackedTransientEvent = makeStoredEvent(from: scopedEvent)

    let campaigns = if let cachedCampaigns {
      cachedCampaigns
    } else {
      await getAllCampaigns(for: scopedEvent.distinctId)
    }
    if let campaigns {
      await startAndProcessMatchingJourneys(
        for: scopedEvent,
        transientEvent: trackedTransientEvent,
        campaigns: campaigns
      )
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
    let stage = await stageScopedEvent(
      name: JourneyEvents.journeyGoalHit,
      properties: properties,
      distinctId: scopedDistinctId
    )
    let localScopedEvent = stage.localEvent
    let cachedCampaigns: [Campaign]? = await getAllCampaigns(for: scopedDistinctId)
    let transientEvent = stage.transientEvent
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

    let (trackedEvent, response) = await trackScopedEvent(stage, properties: properties)

    let scopedEvent = confirmedScopedEvent(from: trackedEvent, distinctId: scopedDistinctId)
    await eventLog.storePreparedEventInHistory(localScopedEvent)

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
      await startAndProcessMatchingJourneys(
        for: scopedEvent,
        transientEvent: transientEvent,
        campaigns: campaigns
      )
    }
    await handleScopedGatePlan(
      response?.gatePlan(),
      sourceJourney: journey,
      sourceCampaign: resolvedSourceCampaign
    )
  }

  func handleUnsupportedScopedRequestPermission(
    journeyId: String,
    permissionType: String,
    distinctId: String
  ) async {
    let stage = await stageScopedEvent(
      name: SystemEventNames.permissionDenied,
      properties: ["journey_id": journeyId, "type": permissionType],
      distinctId: distinctId
    )
    let localScopedEvent = stage.localEvent
    let transientEvent = stage.transientEvent
    if let campaigns = await getAllCampaigns(for: distinctId) {
      await processActiveJourneys(
        for: localScopedEvent,
        campaigns: campaigns,
        transientEventsByJourneyId: [journeyId: [transientEvent]],
        restrictedToJourneyIds: [journeyId]
      )
    }

    await completeDeferredDismissIfReady(journeyId: journeyId)

    let (_, response) = await trackScopedEvent(stage, properties: stage.enrichedProperties)

    await handleScopedGatePlan(response?.gatePlan())
  }

  // MARK: - Helpers

  private func dismissalExitReason(for reason: CloseReason) -> JourneyExitReason {
    JourneyDismissalMapping.exitReason(for: reason)
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

  private func ensureRunner(for journey: Journey, campaign: Campaign) async -> JourneyRunner? {
    if let existing = flowRunners[journey.id] {
      return existing
    }

    let flowId = campaign.flowId

    do {
      let flow = try await flowService.fetchExperience(id: flowId)
      let runner = JourneyRunner(
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
        },
        eventLog: eventLog,
        identity: identityService,
        segments: segmentService,
        features: featureService,
        profile: profileService,
        apiClient: api,
        dateProvider: dateProvider,
        irRuntime: irRuntime
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

      // ExperiencePresentationService tracks $flow_shown on successful presentation;
      // tracking here as well double-counted every journey-driven flow (and
      // counted failed presentations).
      _ = try? await presentFlowIfNeeded(flowId: flowId, journey: journey)

      return runner
    } catch {
      LogError("Failed to load flow \(campaign.flowId) for journey \(journey.id): \(error)")
      return nil
    }
  }

  /// The runner for `journey`, rebuilding it on demand for a restored
  /// journey. After a relaunch, `initialize()` restores persisted journeys
  /// WITHOUT runners; only the timer-resume path (`resumeJourney`) rebuilt
  /// one, so an active restored journey was deaf to events — persisted outlet
  /// chains (e.g. a purchase node's onCompleted) never executed and the
  /// journey could stay active forever. Event/goal dispatch now rebuilds
  /// lazily through the same `ensureRunner` path timer resume uses; the
  /// runner's init rehydrates persisted flow state (view-model snapshot,
  /// navigation state, pending purchase/restore outlet chains).
  ///
  /// A rebuild failure (no cached campaign, or the flow bundle is not
  /// available offline) returns nil WITHOUT completing the journey: dispatch
  /// skips this event — matching the previous behavior for runner-less
  /// journeys — and a later event retries. Cancel semantics for a missing
  /// campaign remain owned by `resumeJourney`.
  private func runnerForDispatch(journey: Journey, campaign: Campaign?) async -> JourneyRunner? {
    if let existing = flowRunners[journey.id] {
      return existing
    }
    guard journey.status.isLive else { return nil }

    var resolvedCampaign = campaign
    if resolvedCampaign == nil {
      resolvedCampaign = await getCampaign(id: journey.campaignId, for: journey.distinctId)
    }
    guard let resolvedCampaign else {
      LogDebug("No cached campaign \(journey.campaignId) to rebuild runner for restored journey \(journey.id)")
      return nil
    }

    guard let runner = await ensureRunner(for: journey, campaign: resolvedCampaign) else {
      LogWarning("Failed to rebuild runner for restored journey \(journey.id); skipping dispatch")
      return nil
    }
    return runner
  }

  private func presentFlowIfNeeded(flowId: String, journey: Journey) async throws -> ExperienceViewController {
    if let runner = flowRunners[journey.id],
       let controller = await runner.viewController,
       await flowPresentationService.isFlowPresented {
      return controller
    }
    if let delegate = runtimeDelegates[journey.id] {
      let controller = try await flowPresentationService.presentExperience(flowId, from: journey, runtimeDelegate: delegate)
      if let runner = flowRunners[journey.id] {
        await runner.attach(viewController: controller)
      }
      return controller
    }

    let delegate = JourneyRendererBridge(
      journeyId: journey.id,
      distinctId: journey.distinctId,
      journeyService: self
    )
    runtimeDelegates[journey.id] = delegate
    let controller = try await flowPresentationService.presentExperience(flowId, from: journey, runtimeDelegate: delegate)
    if let runner = flowRunners[journey.id] {
      await runner.attach(viewController: controller)
    }
    return controller
  }

  private func handleOutcome(_ outcome: JourneyRunner.RunOutcome?, journey: Journey) {
    guard let outcome else { return }
    switch outcome {
    case .paused(let pending):
      journey.pause(at: dateProvider.now())
      persistJourney(journey)
      if let resumeAt = pending.resumeAt {
        scheduleResume(journeyId: journey.id, at: resumeAt)
      }
      eventLog.track(
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
    timerScheduler.schedule(
      key: JourneyTimerScheduler.taskKey(journeyId: journeyId, kind: "resume"),
      at: date
    ) { [weak self] in
      await self?.resumeJourneyIfCached(journeyId: journeyId)
    }
  }

  private func resumeJourneyIfCached(journeyId: String) async {
    guard let journey = inMemoryJourneysById[journeyId] else { return }
    await resumeJourney(journey)
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
      journey.cancel(at: dateProvider.now())
    } else {
      journey.complete(reason: reason, at: dateProvider.now())
    }

    let duration = journey.completedAt?.timeIntervalSince(journey.startedAt)
      ?? dateProvider.now().timeIntervalSince(journey.startedAt)

    eventLog.track(
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

    eventLog.track(
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
      eventLog.track(
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

    timerScheduler.cancelTasks(journeyId: journey.id)
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
      let record = JourneyCompletionRecord(journey: journey, now: dateProvider.now())
      do {
        try journeyStore.recordCompletion(record)
      } catch {
        // A missed record loosens reentry (may re-show) rather than
        // permanently blocking — log loudly instead of silently swallowing.
        LogError("Failed to record journey completion for reentry accounting: \(error)")
      }
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

      if eventJourneyId == journey.id,
         let runner = await runnerForDispatch(journey: journey, campaign: campaign) {
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
        if let runner = await runnerForDispatch(journey: journey, campaign: campaign) {
          let outcome = await runner.resumePendingAction(reason: .event(event), event: event)
          handleOutcome(outcome, journey: journey)
        }
        continue
      }

      if skipEventTriggerForJourneyIds.contains(journey.id) {
        continue
      }

      if let runner = await runnerForDispatch(journey: journey, campaign: campaign) {
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
      _ = try? await flowPresentationService.presentExperience(flowId, from: nil, runtimeDelegate: nil)

    case .requireFeature:
      guard let featureId = plan.featureId else { return }

      if plan.policy == .cacheOnly {
        let cached = await GatePlanEvaluation.cachedFeatureAccess(featureInfo, featureId: featureId)
        if GatePlanEvaluation.hasAccess(cached, requiredBalance: plan.requiredBalance) {
          return
        }
        return
      } else {
        if let cached = await GatePlanEvaluation.cachedFeatureAccess(featureInfo, featureId: featureId),
           GatePlanEvaluation.hasAccess(cached, requiredBalance: plan.requiredBalance) {
          return
        }

        if let access = try? await featureService.checkWithCache(
          featureId: featureId,
          requiredBalance: plan.requiredBalance,
          entityId: plan.entityId,
          forceRefresh: false
        ), GatePlanEvaluation.hasAccess(access, requiredBalance: plan.requiredBalance) {
          return
        }
      }

      guard let flowId = plan.flowId else { return }
      await closeSourceJourneyBeforeScopedGateFlowIfNeeded(
        journey: sourceJourney,
        campaign: sourceCampaign
      )
      _ = try? await flowPresentationService.presentExperience(flowId, from: nil, runtimeDelegate: nil)
    }
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

      eventLog.track(
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

  // MARK: - Scoped-event pipeline (shared)

  /// A journey-scoped event staged for local-first dispatch: enriched
  /// properties, the local event, and its transient StoredEvent for IR
  /// queries before the server round trip completes.
  private struct ScopedEventStage {
    let enrichedProperties: [String: Any]
    let localEvent: NuxieEvent
    let transientEvent: StoredEvent
  }

  /// Enrich and stage a scoped event. All three scoped pipelines
  /// (permission, unsupported-permission, goal) build events this way; the
  /// paths differ only in how they dispatch, which stays at each call site.
  private func stageScopedEvent(
    name: String,
    properties: [String: Any],
    distinctId: String
  ) async -> ScopedEventStage {
    let enriched = await eventLog.prepareTriggerProperties(
      properties,
      userProperties: nil,
      userPropertiesSetOnce: nil
    )
    let localEvent = NuxieEvent(
      name: name,
      distinctId: distinctId,
      properties: enriched,
      timestamp: dateProvider.now()
    )
    return ScopedEventStage(
      enrichedProperties: enriched,
      localEvent: localEvent,
      transientEvent: makeStoredEvent(from: localEvent)
    )
  }

  /// Server round trip for a scoped event. Local dispatch has already
  /// happened; a failure degrades to the locally staged event with no gate
  /// plan (local-first: the network can only enhance).
  private func trackScopedEvent(
    _ stage: ScopedEventStage,
    properties: [String: Any]
  ) async -> (tracked: NuxieEvent, response: EventResponse?) {
    do {
      let tracked = try await eventLog.trackForTrigger(
        stage.localEvent.name,
        properties: properties,
        userProperties: nil,
        userPropertiesSetOnce: nil,
        persistToHistory: false,
        distinctIdOverride: stage.localEvent.distinctId
      )
      return (tracked.0, tracked.1)
    } catch {
      LogWarning("JourneyService: Failed to track scoped event \(stage.localEvent.name): \(error)")
      return (
        NuxieEvent(
          name: stage.localEvent.name,
          distinctId: stage.localEvent.distinctId,
          properties: stage.enrichedProperties
        ),
        nil
      )
    }
  }

  /// The server-confirmed scoped event: tracked id/properties under the
  /// journey's identity.
  private func confirmedScopedEvent(
    from tracked: NuxieEvent, distinctId: String
  ) -> NuxieEvent {
    NuxieEvent(
      id: tracked.id,
      name: tracked.name,
      distinctId: distinctId,
      properties: tracked.properties,
      timestamp: tracked.timestamp
    )
  }

  /// Start journeys the confirmed event triggers and give each new journey
  /// the transient event for its first evaluation pass.
  private func startAndProcessMatchingJourneys(
    for event: NuxieEvent,
    transientEvent: StoredEvent,
    campaigns: [Campaign]
  ) async {
    let results = await startJourneysMatchingEvent(
      event,
      campaigns: campaigns,
      )
    let startedJourneyIds = Set(results.compactMap { result -> String? in
      guard case .started(let startedJourney) = result else { return nil }
      return startedJourney.id
    })
    guard !startedJourneyIds.isEmpty else { return }
    let transientEventsByJourneyId: [String: [StoredEvent]] = Dictionary(
      uniqueKeysWithValues: startedJourneyIds.map { ($0, [transientEvent]) }
    )
    await processActiveJourneys(
      for: event,
      campaigns: campaigns,
      transientEventsByJourneyId: transientEventsByJourneyId,
      restrictedToJourneyIds: startedJourneyIds
    )
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
    let hasLiveJourney = inMemoryJourneysById.values.contains {
      $0.distinctId == distinctId && $0.campaignId == campaign.id && $0.status.isLive
    }
    return EnrollmentPolicy.suppressionReason(
      reentry: campaign.reentry,
      hasLiveJourney: hasLiveJourney,
      hasCompleted: {
        journeyStore.hasCompletedCampaign(distinctId: distinctId, campaignId: campaign.id)
      },
      lastCompletionAt: {
        journeyStore.lastCompletionTime(distinctId: distinctId, campaignId: campaign.id)
      },
      timeIntervalSinceLastCompletion: {
        dateProvider.timeIntervalSince($0)
      }
    )
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

    let config = irRuntime.standardConfig(event: event)

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

