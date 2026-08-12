import Foundation

/// Reason for resuming a journey
public enum ResumeReason: Sendable {
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
public protocol JourneyServiceProtocol: AnyObject, Sendable {
  @discardableResult
  func startJourney(for experience: Experience, distinctId: String, originEventId: String?) async -> Journey?

  func resumeJourney(_ journey: Journey) async


  func handleEvent(_ event: NuxieEvent) async

  func handleEventForTrigger(_ event: NuxieEvent) async -> [JourneyTriggerResult]

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
  // MainActor-isolated collaborators (experiencePresentationService, featureInfo)
  private let experienceService: ExperienceServiceProtocol
  private let experiencePresentationService: ExperiencePresentationServiceProtocol
  private let profileService: ProfileServiceProtocol
  private let identityService: IdentityServiceProtocol
  private let segmentService: SegmentServiceProtocol
  private let featureService: FeatureServiceProtocol
  private let featureInfo: FeatureInfo
  private let eventLog: JourneyEventAccess
  private let triggerBroker: TriggerBrokerProtocol
  private let dateProvider: DateProviderProtocol
  private let sleepProvider: SleepProviderProtocol
  private let goalEvaluator: GoalEvaluatorProtocol
  private let irRuntime: IRRuntime
  private let api: ResponseWriting

  // MARK: - State

  private var inMemoryJourneysById: [String: Journey] = [:]
  private var experienceRunners: [String: JourneyRunner] = [:]
  private var runtimeDelegates: [String: JourneyRendererBridge] = [:]
  private let timerScheduler: JourneyTimerScheduler
  private var completingJourneyIds: Set<String> = []
  private var claimingJourneyIds: Set<String> = []

  // MARK: - Initialization

  internal init(
    journeyStore: JourneyStoreProtocol,
    experiences: ExperienceServiceProtocol,
    profile: ProfileServiceProtocol,
    identity: IdentityServiceProtocol,
    segments: SegmentServiceProtocol,
    features: FeatureServiceProtocol,
    experiencePresentation: ExperiencePresentationServiceProtocol,
    featureInfo: FeatureInfo,
    eventLog: JourneyEventAccess,
    triggerBroker: TriggerBrokerProtocol,
    dateProvider: DateProviderProtocol,
    sleepProvider: SleepProviderProtocol,
    goalEvaluator: GoalEvaluatorProtocol,
    irRuntime: IRRuntime,
    api: ResponseWriting
  ) {
    self.journeyStore = journeyStore
    self.experienceService = experiences
    self.experiencePresentationService = experiencePresentation
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

  // MARK: - Lifecycle

  public func initialize() async {
    LogInfo("Initializing JourneyService...")

    await profileService.setJourneyMailboxHandler { [weak self] mailbox, distinctId in
      await self?.handleMailbox(mailbox, distinctId: distinctId)
    }
    await eventLog.setJourneyOwnershipRejectedHandler {
      [weak self] journeyId, epoch in
      await self?.discardEpochRejectedJourney(
        journeyId: journeyId,
        authoritativeEpoch: epoch
      )
    }
    await eventLog.setJourneyHandoffDeliveredHandler {
      [weak self] journeyId in
      await self?.handleJourneyHandoffDelivered(journeyId: journeyId)
    }

    let persisted = journeyStore.loadActiveJourneys()
    LogInfo("Restored \(persisted.count) active journeys")

    for journey in persisted where journey.status.isLive {
      restorePersistedJourney(journey)
    }

    if let profile = await profileService.getCachedProfile(
      distinctId: identityService.getDistinctId()
    ), let mailbox = profile.mailbox {
      await handleMailbox(mailbox, distinctId: identityService.getDistinctId())
    }

    await checkExpiredTimers()
  }

  public func onAppWillEnterForeground() async {
    await checkExpiredTimers()

    let now = dateProvider.now()
    for journey in inMemoryJourneysById.values where journey.status.isLive {
      if let pending = journey.executionState.pendingAction,
         let resumeAt = pending.resumeAt,
         resumeAt > now {
        scheduleResume(journeyId: journey.id, at: resumeAt)
      }
    }
  }

  public func onAppBecameActive() async {
    await experiencePresentationService.onAppBecameActive()
  }

  public func onAppDidEnterBackground() async {
    timerScheduler.cancelAll()
    await experiencePresentationService.onAppDidEnterBackground()

    for journey in inMemoryJourneysById.values where journey.status.isLive {
      persistJourney(journey)
      enqueueParking(journey, reason: .background)
    }

    LogInfo("JourneyService background snapshot complete")
  }

  public func shutdown() async {
    timerScheduler.cancelAll()
  }

  public func handleUserChange(from oldDistinctId: String, to newDistinctId: String) async {
    LogInfo("JourneyService handling user change from \(NuxieLogger.shared.logDistinctID(oldDistinctId)) to \(NuxieLogger.shared.logDistinctID(newDistinctId))")

    let oldJourneys = await getActiveJourneys(for: oldDistinctId)
    for journey in oldJourneys {
      await cancelJourney(journey)
    }

    inMemoryJourneysById = inMemoryJourneysById.filter { $0.value.distinctId != oldDistinctId }

    let persisted = journeyStore.loadActiveJourneys()
      .filter { $0.distinctId == newDistinctId && $0.status.isLive }

    for journey in persisted {
      inMemoryJourneysById[journey.id] = journey
      if let pending = journey.executionState.pendingAction, let resumeAt = pending.resumeAt {
        scheduleResume(journeyId: journey.id, at: resumeAt)
      }
    }

    await checkExpiredTimers()
  }

  // MARK: - Public API

  public func startJourney(
    for experience: Experience,
    distinctId: String,
    originEventId: String? = nil
  ) async -> Journey? {
    guard suppressionReason(experience: experience, distinctId: distinctId) == nil else {
      LogDebug("User \(distinctId) cannot start journey for experience \(experience.id)")
      return nil
    }

    return await startJourneyInternal(
      for: experience,
      distinctId: distinctId,
      originEventId: originEventId,
    )
  }

  private func startJourneyInternal(
    for experience: Experience,
    distinctId: String,
    originEventId: String? = nil
  ) async -> Journey? {
    let journey = Journey(experience: experience, distinctId: distinctId, now: dateProvider.now())
    journey.status = .active
    if let originEventId {
      journey.setContext("_origin_event_id", value: originEventId, at: dateProvider.now())
    }

    inMemoryJourneysById[journey.id] = journey

    do {
      _ = try await eventLog.trackWithResponse(
        JourneyEvents.journeyEnrolled,
        properties: JourneyEvents.journeyEnrolledProperties(
          journey: journey,
          experience: experience,
          triggerRef: originEventId ?? "device:\(journey.id)"
        )
      )
    } catch {
      LogWarning("JourneyService: Failed to persist journey enrollment: \(error)")
      journey.cancel(at: dateProvider.now())
      inMemoryJourneysById.removeValue(forKey: journey.id)
      return nil
    }
    guard inMemoryJourneysById[journey.id] === journey else {
      return nil
    }

    guard await ensureRunner(for: journey, experience: experience) != nil else {
      await completeJourney(journey, reason: .error)
      return journey
    }

    // Persist after the synchronous enrollment fact so a crash cannot leave
    // server admission without the corresponding local run snapshot.
    persistJourney(journey)

    return journey
  }

  public func resumeJourney(_ journey: Journey) async {
    guard journey.status == .paused || journey.status == .active else { return }

    guard let experience = await getExperience(
      id: journey.experienceId,
      versionId: journey.experienceVersion,
      for: journey.distinctId
    ) else {
      await cancelJourney(journey)
      return
    }

    guard let runner = await ensureRunner(for: journey, experience: experience) else {
      await completeJourney(journey, reason: .error)
      return
    }

    journey.resume(at: dateProvider.now())
    inMemoryJourneysById[journey.id] = journey

    let outcome = await runner.resumePendingAction(reason: .timer, event: nil)
    await handleOutcome(outcome, journey: journey)
  }

  /// Resume a paused `wait_until` pending action because an event arrived.
  /// `resumePendingAction` re-evaluates the wait condition and re-pauses the
  /// same wait when the event does not satisfy it.
  private func resumePendingWaitForEvent(
    _ journey: Journey,
    runner: JourneyRunner,
    pending: JourneyPendingAction,
    event: NuxieEvent
  ) async {
    let wasPaused = journey.status == .paused
    if wasPaused {
      journey.resume(at: dateProvider.now())
    }

    let outcome = await runner.resumePendingAction(reason: .event(event), event: event)
    await handleOutcome(outcome, journey: journey)

    guard wasPaused else { return }

    // Same wait re-armed means the journey is still waiting — nothing
    // resumed. Identity is handler + original startedAt: a re-pause of
    // the same wait preserves both (resume-chain indexes are rebased to
    // 0, so actionIndex is NOT stable), while a later wait in the same
    // chain gets a fresh startedAt.
    if let reArmed = journey.executionState.pendingAction,
       reArmed.kind == .waitUntil,
       reArmed.handlerId == pending.handlerId,
       reArmed.startedAt == pending.startedAt {
      return
    }

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
    await applySupersededDownFactIfNeeded(event)
    await applyConvertedDownFactIfNeeded(event)
    guard let experiences = await getAllExperiences(for: event.distinctId) else { return [] }
    let results = await startJourneysMatchingEvent(
      event,
      experiences: experiences
    )
    await processActiveJourneys(
      for: event,
      experiences: experiences,
      transientEventsByJourneyId: [:],
      restrictedToJourneyIds: nil
    )
    return results
  }

  private func applySupersededDownFactIfNeeded(_ event: NuxieEvent) async {
    guard event.name == JourneyEvents.journeySuperseded,
          event.properties[StoredEvent.originProperty] as? String
            == StoredEventOrigin.server.rawValue,
          let journeyId = event.properties["journey_id"] as? String,
          let journey = inMemoryJourneysById[journeyId],
          journey.status.isLive else {
      return
    }
    journey.isGhost = true
    journey.updatedAt = dateProvider.now()
    persistJourney(journey)
    LogInfo("Journey \(journey.id) entered ghost play-out after server supersede")
  }

  private func discardEpochRejectedJourney(
    journeyId: String,
    authoritativeEpoch: Int
  ) {
    guard let journey = inMemoryJourneysById[journeyId],
          authoritativeEpoch >= journey.epoch else {
      return
    }
    let warning =
      "JourneyService: discarding epoch-rejected journey \(journeyId); " +
      "device=\(journey.epoch), authoritative=\(authoritativeEpoch)"
    LogWarning(warning)
    discardLocalJourney(journey, terminalStatus: .superseded)
  }

  private func handleJourneyHandoffDelivered(journeyId: String) {
    guard let journey = inMemoryJourneysById[journeyId] else { return }
    discardLocalJourney(journey, terminalStatus: .transferred)
  }

  private func handleMailbox(
    _ mailbox: [JourneyMailboxEntry],
    distinctId: String
  ) async {
    let now = dateProvider.now()
    for entry in mailbox {
      guard entry.expiresAt > now else { continue }
      guard entry.hasSupportedStateVersion else {
        let error =
          "JourneyService: refusing mailbox claim \(entry.journeyId) " +
          "with unsupported state version \(entry.stateVersion)"
        LogError(error)
        continue
      }
      guard inMemoryJourneysById[entry.journeyId] == nil,
            journeyStore.loadJourney(id: entry.journeyId) == nil,
            claimingJourneyIds.insert(entry.journeyId).inserted else {
        continue
      }
      defer { claimingJourneyIds.remove(entry.journeyId) }
      guard let experience = await getExperience(
        id: entry.experienceId,
        versionId: entry.experienceVersion,
        for: distinctId
      ) else {
        LogWarning(
          "JourneyService: refusing mailbox claim \(entry.journeyId) because pinned experience version is unavailable"
        )
        continue
      }

      let response: EventResponse
      do {
        (_, response) = try await eventLog.trackForTrigger(
          JourneyEvents.journeyClaimed,
          properties: JourneyEvents.journeyClaimedProperties(
            journeyId: entry.journeyId,
            epoch: entry.epoch,
            claimant: identityService.getAnonymousId()
          ),
          userProperties: nil,
          userPropertiesSetOnce: nil,
          persistToHistory: true,
          distinctIdOverride: distinctId
        )
      } catch {
        LogWarning("JourneyService: mailbox claim failed for \(entry.journeyId): \(error)")
        continue
      }

      guard let acknowledgement = response.journeyClaim,
            acknowledgement.journeyId == entry.journeyId,
            acknowledgement.accepted,
            acknowledgement.epoch == entry.epoch + 1 else {
        LogInfo("JourneyService: mailbox claim rejected for \(entry.journeyId)")
        continue
      }

      let claimed = Journey(
        id: entry.journeyId,
        experience: experience,
        distinctId: distinctId,
        now: now
      )
      claimed.applyStateEnvelope(
        entry.envelope,
        epoch: acknowledgement.epoch
      )
      claimed.resumePoint = entry.resumePoint
      claimed.status = claimed.executionState.pendingAction == nil ? .active : .paused

      do {
        try journeyStore.saveJourney(claimed)
      } catch {
        LogError("JourneyService: failed to persist claimed journey \(entry.journeyId): \(error)")
        continue
      }

      // Deliberately reload before admission: claimed and launch-restored
      // journeys share one decoding/resume implementation.
      guard let restored = journeyStore.loadJourney(id: entry.journeyId) else {
        LogError("JourneyService: failed to reload claimed journey \(entry.journeyId)")
        continue
      }
      restorePersistedJourney(restored)
      if entry.kind == .pending {
        await beginClaimedDeviceRegion(restored, experience: experience)
      }
    }
  }

  private func restorePersistedJourney(_ journey: Journey) {
    inMemoryJourneysById[journey.id] = journey
    if let pending = journey.executionState.pendingAction,
       let resumeAt = pending.resumeAt {
      scheduleResume(journeyId: journey.id, at: resumeAt)
    }
  }

  private func beginClaimedDeviceRegion(
    _ journey: Journey,
    experience: Experience
  ) async {
    guard journey.executionState.pendingAction == nil,
          let runner = await ensureRunner(for: journey, experience: experience) else {
      return
    }
    do {
      let experience = try await experienceService.fetchExperience(id: journey.experienceVersion)
      guard let regionId = journey.executionState.regionId,
            let region = experience.screens.deviceRegions?.first(where: {
              $0.id == regionId
            }) else {
        LogWarning(
          "JourneyService: claimed journey \(journey.id) has no matching device region"
        )
        return
      }
      let outcome = await runner.runDeviceRegion(region)
      await handleOutcome(outcome, journey: journey)
    } catch {
      LogWarning("JourneyService: failed to start claimed region for \(journey.id): \(error)")
    }
  }

  private func applyConvertedDownFactIfNeeded(_ event: NuxieEvent) async {
    guard event.name == JourneyEvents.journeyConverted,
          event.properties[StoredEvent.originProperty] as? String == StoredEventOrigin.server.rawValue,
          let journeyId = event.properties["journey_id"] as? String,
          let journey = inMemoryJourneysById[journeyId],
          let atValue = event.properties["at"] as? String,
          let at = parseExecutionDate(atValue),
          let sourceFactRef = event.properties["source_fact_ref"] as? String else {
      return
    }

    if journey.convertedAt == nil || at < journey.convertedAt! {
      journey.convertedAt = at
      journey.setContext("_conversion_source_fact_ref", value: sourceFactRef, at: dateProvider.now())
      persistJourney(journey)
    }

    switch journey.exitPolicySnapshot?.mode {
    case .onGoal, .onGoalOrStop:
      await completeJourney(journey, reason: .goalMet)
    case .onStopMatching, .never, nil:
      break
    }
  }

  private func parseExecutionDate(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
  }

  public func getActiveJourneys(for distinctId: String) async -> [Journey] {
    return inMemoryJourneysById.values.filter { $0.distinctId == distinctId && $0.status.isLive }
  }

  public func checkExpiredTimers() async {
    let now = dateProvider.now()

    for journey in inMemoryJourneysById.values where journey.status.isLive {
      if let pending = journey.executionState.pendingAction, let resumeAt = pending.resumeAt, resumeAt <= now {
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
          let runner = experienceRunners[journeyId] else { return }

    let outcome = await runner.handleRuntimeReady()
    await handleOutcome(outcome, journey: journey)
  }

  func handleRendererScreenChanged(
    journeyId: String,
    screenId: String
  ) async {
    guard let journey = inMemoryJourneysById[journeyId],
          let runner = experienceRunners[journeyId] else { return }

    let previousScreenId = journey.executionState.currentScreenId
    let outcome = await runner.handleScreenChanged(screenId)
    await handleOutcome(outcome, journey: journey)
    persistJourney(journey)

    if !journey.isGhost {
      do {
        _ = try await eventLog.trackWithResponse(
          JourneyEvents.journeyTransition,
          properties: JourneyEvents.journeyTransitionProperties(
            journey: journey,
            fromNode: previousScreenId,
            toNode: screenId
          )
        )
      } catch {
        LogWarning("JourneyService: Failed to persist transition to \(screenId): \(error)")
      }
    }
    persistJourney(journey)
  }

  func handleRendererScreenDismissed(
    journeyId: String,
    screenId: String,
    revealingScreenId: String?
  ) async {
    guard let journey = inMemoryJourneysById[journeyId],
          let runner = experienceRunners[journeyId] else { return }

    let outcome = await runner.handleScreenDismissed(
      screenId,
      revealingScreenId: revealingScreenId,
      method: "native_sheet"
    )
    await handleOutcome(outcome, journey: journey)
    persistJourney(journey)

    if let revealingScreenId, !journey.isGhost {
      do {
        _ = try await eventLog.trackWithResponse(
          JourneyEvents.journeyTransition,
          properties: JourneyEvents.journeyTransitionProperties(
            journey: journey,
            fromNode: screenId,
            toNode: revealingScreenId
          )
        )
      } catch {
        LogWarning("JourneyService: Failed to persist transition to \(revealingScreenId): \(error)")
      }
      persistJourney(journey)
    }
  }

  func handleRendererViewModelChange(
    journeyId: String,
    change: ExperienceRendererViewModelChange
  ) async {
    guard let journey = inMemoryJourneysById[journeyId],
          let runner = experienceRunners[journeyId] else { return }

    let outcome = await runner.handleDidSet(
      path: change.path,
      value: change.value,
      source: change.source,
      screenId: change.screenId ?? journey.executionState.currentScreenId,
      instanceId: change.instanceId,
      isTrigger: change.isTrigger
    )
    await handleOutcome(outcome, journey: journey)
    persistJourney(journey)
  }

  func handleRendererEvent(
    journeyId: String,
    event rendererEvent: ExperienceRendererEvent
  ) async {
    guard !rendererEvent.name.isEmpty else { return }
    guard let journey = inMemoryJourneysById[journeyId],
          let runner = experienceRunners[journeyId] else { return }

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
      screenId: rendererEvent.screenId ?? journey.executionState.currentScreenId,
      componentId: rendererEvent.componentId,
      instanceId: rendererEvent.instanceId
    )
    await handleOutcome(outcome, journey: journey)
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

    let experiences = await getAllExperiences(for: routedEvent.distinctId) ?? []
    let sourceExperience = sourceScopedGoalExperience(for: journey, experiences: experiences)
    let transientEvent = makeStoredEvent(from: routedEvent)
    await processActiveJourneys(
      for: routedEvent,
      experiences: experiences,
      transientEventsByJourneyId: [journeyId: [transientEvent]],
      restrictedToJourneyIds: [journeyId],
      skipEventTriggerForJourneyIds: [journeyId]
    )

    await routeRendererEventOutsideSourceJourney(
      routedEvent,
      sourceJourneyId: journeyId,
      experiences: experiences
    )
    await handleScopedGatePlan(
      response?.gatePlan(),
      sourceJourney: journey,
      sourceExperience: sourceExperience
    )
  }

  private func routeRendererEventOutsideSourceJourney(
    _ event: NuxieEvent,
    sourceJourneyId: String,
    experiences: [Experience]
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
        experiences: experiences,
        transientEventsByJourneyId: transientEventsByJourneyId,
        restrictedToJourneyIds: otherActiveJourneyIds
      )
    }

    let results = await startJourneysMatchingEvent(
      event,
      experiences: experiences,
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
      experiences: experiences,
      transientEventsByJourneyId: transientEventsByJourneyId,
      restrictedToJourneyIds: startedJourneyIds
    )
  }

  func handleRendererOpenLink(
    journeyId: String,
    request: ExperienceRendererOpenLinkRequest
  ) async {
    guard let runner = experienceRunners[journeyId] else { return }
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
          let runner = experienceRunners[journeyId] else { return }

    var userInfo: [String: Any] = [
      "journeyId": journey.id,
      "experienceId": journey.experienceId
    ]
    if let screenId = journey.executionState.currentScreenId {
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
    if let screenId = journey.executionState.currentScreenId {
      properties["screen_id"] = screenId
    }
    properties["method"] = JourneyDismissalMapping.dismissMethod(for: reason)
    let event = NuxieEvent(
      name: SystemEventNames.screenDismissed,
      distinctId: journey.distinctId,
      properties: properties
    )
    let outcome = await runner.dispatchEventTrigger(event)
    await handleOutcome(outcome, journey: journey)
    if await runner.shouldAbandonResponseDraftsAfterDismiss() {
      await runner.abandonResponseDraftsIfNeeded()
    }

    if journey.status.isLive {
      await evaluateGoalIfNeeded(journey)
      if let reason = await exitDecision(journey) {
        await completeJourney(journey, reason: reason)
        return
      }
    }

    if journey.status.isLive, await runner.hasPendingPermissionWork() {
      await runner.deferDismiss(reason: reason)
      return
    }

    if journey.status.isLive {
      await completeJourney(journey, reason: dismissalExitReason(for: reason))
    }
  }

  func handleScopedPermissionEvent(
    journeyId: String,
    eventName: String,
    properties: sending [String: Any],
    distinctId: String
  ) async {
    let journey = inMemoryJourneysById[journeyId]
    let scopedDistinctId = journey?.distinctId ?? distinctId

    // Boxed to hand the write-once payload through the staging pipeline.
    let propertiesBox = UncheckedSendable(properties)
    let stage = await stageScopedEvent(
      name: eventName,
      properties: propertiesBox.value,
      distinctId: scopedDistinctId
    )
    let localScopedEvent = stage.localEvent

    let cachedExperiences: [Experience]? = if journey != nil {
      await getAllExperiences(for: scopedDistinctId)
    } else {
      nil
    }
    let transientEvent = stage.transientEvent
    if let cachedExperiences {
      let activeJourneyIds = await getActiveJourneys(for: localScopedEvent.distinctId).map(\.id)
      let transientEventsByJourneyId: [String: [StoredEvent]] = Dictionary(
        uniqueKeysWithValues: activeJourneyIds.map { ($0, [transientEvent]) }
      )
      await processActiveJourneys(
        for: localScopedEvent,
        experiences: cachedExperiences,
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

    let experiences = if let cachedExperiences {
      cachedExperiences
    } else {
      await getAllExperiences(for: scopedEvent.distinctId)
    }
    if let experiences {
      await startAndProcessMatchingJourneys(
        for: scopedEvent,
        transientEvent: trackedTransientEvent,
        experiences: experiences
      )
    }
    await handleScopedGatePlan(response?.gatePlan())
  }

  func handleScopedMilestoneEvent(
    journeyId: String,
    milestoneId: String,
    milestoneLabel: String?,
    screenId: String?,
    handlerId: String? = nil
  ) async {
    guard let journey = inMemoryJourneysById[journeyId],
          !journey.isGhost else {
      return
    }

    let scopedDistinctId = journey.distinctId
    let properties = JourneyEvents.journeyMilestoneProperties(
      journey: journey,
      milestoneId: milestoneId
    )
    // Boxed to hand the write-once payload through the staging pipeline.
    let goalPropertiesBox = UncheckedSendable(properties)
    let stage = await stageScopedEvent(
      name: JourneyEvents.journeyMilestone,
      properties: goalPropertiesBox.value,
      distinctId: scopedDistinctId
    )
    let localScopedEvent = stage.localEvent
    let cachedExperiences: [Experience]? = await getAllExperiences(for: scopedDistinctId)
    let transientEvent = stage.transientEvent
    let sourceJourneyCompleted = await processSourceScopedGoalJourneyEvent(
      journey,
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
        experiences: cachedExperiences ?? [],
        transientEventsByJourneyId: transientEventsByJourneyId,
        restrictedToJourneyIds: otherActiveJourneyIds
      )
    }

    let (trackedEvent, response) = await trackScopedEvent(stage, properties: properties)

    let scopedEvent = confirmedScopedEvent(from: trackedEvent, distinctId: scopedDistinctId)
    await eventLog.storePreparedEventInHistory(localScopedEvent)

    let experiences = if let cachedExperiences {
      cachedExperiences
    } else {
      await getAllExperiences(for: scopedEvent.distinctId)
    }
    let resolvedSourceExperience = sourceScopedGoalExperience(
      for: journey,
      experiences: experiences ?? cachedExperiences
    )
    var sourceJourneyStillCompleted = sourceJourneyCompleted
    if !sourceJourneyStillCompleted {
      sourceJourneyStillCompleted = await processSourceScopedGoalJourneyEvent(
        journey,
        event: scopedEvent,
        transientEvent: transientEvent,
        shouldDispatchToRunner: true
      )
    }
    if let experiences {
      await startAndProcessMatchingJourneys(
        for: scopedEvent,
        transientEvent: transientEvent,
        experiences: experiences
      )
    }
    await handleScopedGatePlan(
      response?.gatePlan(),
      sourceJourney: journey,
      sourceExperience: resolvedSourceExperience
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
    if let experiences = await getAllExperiences(for: distinctId) {
      await processActiveJourneys(
        for: localScopedEvent,
        experiences: experiences,
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
          let runner = experienceRunners[journeyId],
          journey.status.isLive,
          let reason = await runner.consumeDeferredDismissReasonIfReady() else { return }
    await completeJourney(journey, reason: dismissalExitReason(for: reason))
  }

  private func processSourceScopedGoalJourneyEvent(
    _ journey: Journey,
    event: NuxieEvent,
    transientEvent: StoredEvent,
    shouldDispatchToRunner: Bool
  ) async -> Bool {
    await evaluateGoalIfNeeded(
      journey,
      transientEvents: [transientEvent]
    )
    if !(await shouldDeferExitDecision(for: journey)) {
      if let reason = await exitDecision(journey) {
        await completeJourney(journey, reason: reason)
        return true
      }
    }
    if await shouldCompletePresentedScopedGoalJourney(journey) {
      if let controller = await experienceRunners[journey.id]?.viewController {
        await handleRuntimeDismiss(
          journeyId: journey.id,
          reason: .goalMet,
          controller: controller
        )
        await experiencePresentationService.dismissCurrentExperience(reason: .goalMet)
      } else {
        await experiencePresentationService.dismissCurrentExperience()
        await completeJourney(journey, reason: .goalMet)
      }
      return true
    }
    guard shouldDispatchToRunner else {
      return !journey.status.isLive
    }
    guard journey.status.isLive else {
      return true
    }

    if let pending = journey.executionState.pendingAction, pending.kind == .waitUntil {
      if let runner = experienceRunners[journey.id] {
        await resumePendingWaitForEvent(journey, runner: runner, pending: pending, event: event)
      }
      return !journey.status.isLive
    }

    if let runner = experienceRunners[journey.id] {
      let outcome = await runner.dispatchEventTrigger(event)
      await handleOutcome(outcome, journey: journey)
    }
    return !journey.status.isLive
  }

  private func sourceScopedGoalExperience(
    for journey: Journey,
    experiences: [Experience]?
  ) -> Experience? {
    experiences?.first(where: {
      $0.id == journey.experienceId && $0.versionId == journey.experienceVersion
    })
  }

  private func ensureRunner(for journey: Journey, experience: Experience) async -> JourneyRunner? {
    if let existing = experienceRunners[journey.id] {
      return existing
    }

    let versionId = experience.versionId

    do {
      let experience = try await experienceService.fetchExperience(
        experienceId: experience.id,
        versionId: versionId
      )
      let runner = JourneyRunner(
        journey: journey,
        experience: experience,
        onMilestone: { [weak self, journeyId = journey.id] milestoneId, label, screenId, handlerId in
          await self?.handleScopedMilestoneEvent(
            journeyId: journeyId,
            milestoneId: milestoneId,
            milestoneLabel: label,
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
        let controller = try? await self.presentExperienceIfNeeded(experienceVersionId: versionId, journey: journey)
        if let controller {
          await runner?.attach(viewController: controller)
          await MainActor.run {
            controller.navigate(to: screenId, transition: transition?.value)
          }
        }
      }
      experienceRunners[journey.id] = runner

      // ExperiencePresentationService tracks $experience_shown on successful presentation;
      // tracking here as well double-counted every journey-driven experience (and
      // counted failed presentations).
      _ = try? await presentExperienceIfNeeded(experienceVersionId: versionId, journey: journey)

      return runner
    } catch {
      LogError("Failed to load experience \(experience.versionId) for journey \(journey.id): \(error)")
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
  /// runner's init rehydrates persisted experience state (view-model snapshot,
  /// navigation state, pending purchase/restore outlet chains).
  ///
  /// A rebuild failure (no cached experience, or the experience bundle is not
  /// available offline) returns nil WITHOUT completing the journey: dispatch
  /// skips this event — matching the previous behavior for runner-less
  /// journeys — and a later event retries. Cancel semantics for a missing
  /// experience remain owned by `resumeJourney`.
  private func runnerForDispatch(journey: Journey, experience: Experience?) async -> JourneyRunner? {
    if let existing = experienceRunners[journey.id] {
      return existing
    }
    guard journey.status.isLive else { return nil }

    var resolvedExperience = experience
    if resolvedExperience == nil {
      resolvedExperience = await getExperience(
        id: journey.experienceId,
        versionId: journey.experienceVersion,
        for: journey.distinctId
      )
    }
    guard let resolvedExperience else {
      LogDebug("No cached experience \(journey.experienceId) to rebuild runner for restored journey \(journey.id)")
      return nil
    }

    guard let runner = await ensureRunner(for: journey, experience: resolvedExperience) else {
      LogWarning("Failed to rebuild runner for restored journey \(journey.id); skipping dispatch")
      return nil
    }
    return runner
  }

  private func presentExperienceIfNeeded(experienceVersionId: String, journey: Journey) async throws -> ExperienceViewController {
    if let runner = experienceRunners[journey.id],
       let controller = await runner.viewController,
       await experiencePresentationService.isExperiencePresented {
      return controller
    }
    if let delegate = runtimeDelegates[journey.id] {
      let controller = try await experiencePresentationService.presentExperience(experienceVersionId, from: journey, runtimeDelegate: delegate)
      if let runner = experienceRunners[journey.id] {
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
    let controller = try await experiencePresentationService.presentExperience(experienceVersionId, from: journey, runtimeDelegate: delegate)
    if let runner = experienceRunners[journey.id] {
      await runner.attach(viewController: controller)
    }
    return controller
  }

  private func handleOutcome(_ outcome: JourneyRunner.RunOutcome?, journey: Journey) async {
    guard inMemoryJourneysById[journey.id] === journey else { return }
    guard let outcome else { return }
    switch outcome {
    case .paused(let pending):
      journey.pause(at: dateProvider.now())
      persistJourney(journey)
      enqueueParking(
        journey,
        reason: .wait,
        pendingDeadlineAt: pending.resumeAt
      )
      if let resumeAt = pending.resumeAt {
        scheduleResume(journeyId: journey.id, at: resumeAt)
      }
    case .transferred:
      await transferJourneyToServer(journey)
    case .exited(let reason):
      await completeJourney(journey, reason: reason)
    }
  }

  private func transferJourneyToServer(_ journey: Journey) async {
    guard journey.status.isLive else { return }
    if journey.isGhost {
      discardLocalJourney(journey, terminalStatus: .superseded)
      return
    }
    do {
      let (_, response) = try await eventLog.trackForTrigger(
        JourneyEvents.journeyHandoff,
        properties: JourneyEvents.journeyHandoffProperties(
          journey: journey,
          envelope: journey.stateEnvelope()
        ),
        userProperties: nil,
        userPropertiesSetOnce: nil,
        persistToHistory: true,
        distinctIdOverride: journey.distinctId
      )
      guard inMemoryJourneysById[journey.id] === journey else { return }
      guard let ownership = response.journeyOwnership,
            ownership.journeyId == journey.id,
            ownership.accepted else {
        LogWarning(
          "JourneyService: handoff for \(journey.id) was not accepted; retaining local ownership"
        )
        persistJourney(journey)
        return
      }
      discardLocalJourney(journey, terminalStatus: .transferred)
    } catch {
      LogWarning("JourneyService: failed to hand off journey \(journey.id): \(error)")
      persistJourney(journey)
    }
  }

  private func discardLocalJourney(
    _ journey: Journey,
    terminalStatus: JourneyStatus
  ) {
    journey.status = terminalStatus
    journey.updatedAt = dateProvider.now()
    timerScheduler.cancelTasks(journeyId: journey.id)
    experienceRunners.removeValue(forKey: journey.id)
    runtimeDelegates.removeValue(forKey: journey.id)
    inMemoryJourneysById.removeValue(forKey: journey.id)
    journeyStore.deleteJourney(id: journey.id)
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
    guard inMemoryJourneysById[journey.id] === journey else { return }
    do {
      try journeyStore.saveJourney(journey)
    } catch {
      LogError("Failed to persist journey \(journey.id): \(error)")
    }
  }

  private func enqueueParking(
    _ journey: Journey,
    reason: JourneyParkingReason,
    pendingDeadlineAt: Date? = nil
  ) {
    guard journey.status.isLive, !journey.isGhost else { return }
    eventLog.track(
      JourneyEvents.journeyParked,
      properties: JourneyEvents.journeyParkedProperties(
        journey: journey,
        reason: reason,
        pendingDeadlineAt: pendingDeadlineAt
      ),
      userProperties: nil,
      userPropertiesSetOnce: nil
    )
  }

  private func completeJourney(_ journey: Journey, reason: JourneyExitReason) async {
    guard completingJourneyIds.insert(journey.id).inserted else { return }
    defer { completingJourneyIds.remove(journey.id) }
    guard journey.status.isLive,
          inMemoryJourneysById[journey.id] === journey else {
      return
    }

    if journey.isGhost {
      discardLocalJourney(journey, terminalStatus: .superseded)
      return
    }

    if reason == .cancelled {
      journey.cancel(at: dateProvider.now())
    } else {
      journey.complete(reason: reason, at: dateProvider.now())
    }

    do {
      _ = try await eventLog.trackWithResponse(
        JourneyEvents.journeyExited,
        properties: JourneyEvents.journeyExitedProperties(
          journey: journey,
          reason: reason,
          at: journey.completedAt ?? dateProvider.now()
        )
      )
    } catch {
      LogWarning("JourneyService: Failed to deliver journey exit: \(error)")
    }

    if let originEventId = journey.getContext("_origin_event_id") as? String {
      let update = JourneyUpdate(
        journeyId: journey.id,
        experienceId: journey.experienceId,
        experienceVersion: journey.experienceVersion,
        exitReason: reason,
        goalMet: journey.convertedAt != nil
      )
      Task { await triggerBroker.emit(eventId: originEventId, update: .journey(update)) }
    }

    timerScheduler.cancelTasks(journeyId: journey.id)
    experienceRunners.removeValue(forKey: journey.id)
    runtimeDelegates.removeValue(forKey: journey.id)
    inMemoryJourneysById.removeValue(forKey: journey.id)

    journeyStore.deleteJourney(id: journey.id)

    // Reentry accounting: only genuine completions (natural exit, goal met,
    // user dismissal) count against oneTime/oncePerWindow policies. A journey
    // killed by logout (.cancelled) or a load failure (.error) must not
    // permanently burn a one-time experience.
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

  private func cancelJourney(_ journey: Journey) async {
    await completeJourney(journey, reason: .cancelled)
  }

  private func startJourneysMatchingEvent(
    _ event: NuxieEvent,
    experiences: [Experience]
  ) async -> [JourneyTriggerResult] {
    var results: [JourneyTriggerResult] = []

    for experience in experiences {
      guard await shouldTriggerFromEvent(experience: experience, event: event) else { continue }

      if let reason = suppressionReason(experience: experience, distinctId: event.distinctId) {
        results.append(.suppressed(reason))
        continue
      }

      if let journey = await startJourneyInternal(
        for: experience,
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
    experiences: [Experience],
    transientEventsByJourneyId: [String: [StoredEvent]],
    restrictedToJourneyIds: Set<String>? = nil,
    skipEventTriggerForJourneyIds: Set<String> = []
  ) async {
    let journeys = await getActiveJourneys(for: event.distinctId)
    let eventJourneyId = event.properties["journey_id"] as? String

    for journey in journeys {
      if let restrictedToJourneyIds, !restrictedToJourneyIds.contains(journey.id) {
        continue
      }
      var experience = experiences.first(where: {
        $0.id == journey.experienceId && $0.versionId == journey.experienceVersion
      })
      if experience == nil {
        experience = await getExperience(
          id: journey.experienceId,
          versionId: journey.experienceVersion,
          for: journey.distinctId
        )
      }
      if eventJourneyId == journey.id,
         let runner = await runnerForDispatch(journey: journey, experience: experience) {
        await runner.handleScopedSystemPermissionEvent(event.name)
      }

      await evaluateGoalIfNeeded(
        journey,
        transientEvents: transientEventsByJourneyId[journey.id] ?? []
      )
      if !(await shouldDeferExitDecision(for: journey)) {
        if let reason = await exitDecision(journey) {
          await completeJourney(journey, reason: reason)
          continue
        }
      }

      if let pending = journey.executionState.pendingAction, pending.kind == .waitUntil {
        if let runner = await runnerForDispatch(journey: journey, experience: experience) {
          await resumePendingWaitForEvent(journey, runner: runner, pending: pending, event: event)
        }
        continue
      }

      if skipEventTriggerForJourneyIds.contains(journey.id) {
        continue
      }

      if let runner = await runnerForDispatch(journey: journey, experience: experience) {
        let outcome = await runner.dispatchEventTrigger(event)
        await handleOutcome(outcome, journey: journey)
      }
    }
  }

  private func closeSourceJourneyBeforeScopedGateExperienceIfNeeded(
    journey: Journey?,
    experience: Experience?
  ) async {
    guard let journey, journey.status.isLive else { return }
    guard await experiencePresentationService.presentedJourneyId == journey.id else { return }

    let closeReason: CloseReason = journey.convertedAt != nil ? .goalMet : .userDismissed
    if let controller = await experienceRunners[journey.id]?.viewController {
      await handleRuntimeDismiss(
        journeyId: journey.id,
        reason: closeReason,
        controller: controller
      )
      await experiencePresentationService.dismissCurrentExperience(reason: closeReason)
      return
    }

    await experiencePresentationService.dismissCurrentExperience(reason: closeReason)
    await completeJourney(journey, reason: dismissalExitReason(for: closeReason))
  }

  private func handleScopedGatePlan(
    _ plan: GatePlan?,
    sourceJourney: Journey? = nil,
    sourceExperience: Experience? = nil
  ) async {
    guard let plan else { return }

    switch plan.decision {
    case .allow, .deny:
      return

    case .showFlow:
      guard let experienceVersionId = plan.flowId else { return }
      await closeSourceJourneyBeforeScopedGateExperienceIfNeeded(
        journey: sourceJourney,
        experience: sourceExperience
      )
      _ = try? await experiencePresentationService.presentExperience(experienceVersionId, from: nil, runtimeDelegate: nil)

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

      guard let experienceVersionId = plan.flowId else { return }
      await closeSourceJourneyBeforeScopedGateExperienceIfNeeded(
        journey: sourceJourney,
        experience: sourceExperience
      )
      _ = try? await experiencePresentationService.presentExperience(experienceVersionId, from: nil, runtimeDelegate: nil)
    }
  }

  // MARK: - Goals + Exit Policy

  private func evaluateGoalIfNeeded(
    _ journey: Journey,
    transientEvents: [StoredEvent] = []
  ) async {
    guard inMemoryJourneysById[journey.id] === journey else { return }
    guard !journey.isGhost else { return }
    guard journey.convertedAt == nil else { return }
    guard journey.goalSnapshot != nil else { return }

    let result = await goalEvaluator.isGoalMet(
      journey: journey,
      transientEvents: transientEvents
    )
    if result.met, let at = result.at {
      let sourceFactRef = if let evaluatedRef = result.sourceFactRef {
        evaluatedRef
      } else {
        await qualifyingFactRef(
          at: at,
          journey: journey,
          transientEvents: transientEvents
        )
      }
      guard let sourceFactRef else {
        LogWarning("JourneyService: Goal met without a qualifying fact ref for \(journey.id)")
        return
      }
      journey.convertedAt = at
      journey.setContext(
        "_conversion_source_fact_ref",
        value: sourceFactRef,
        at: dateProvider.now()
      )
      journey.updatedAt = dateProvider.now()
      persistJourney(journey)

      do {
        _ = try await eventLog.trackWithResponse(
          JourneyEvents.journeyConverted,
          properties: JourneyEvents.journeyConvertedProperties(
            journey: journey,
            at: at,
            sourceFactRef: sourceFactRef
          )
        )
      } catch {
        LogWarning("JourneyService: Failed to deliver journey conversion: \(error)")
      }
    }
  }

  private func qualifyingFactRef(
    at: Date,
    journey: Journey,
    transientEvents: [StoredEvent]
  ) async -> String? {
    let persisted = await eventLog.getEventsForUser(journey.distinctId, limit: 1000)
    var candidatesById: [String: StoredEvent] = [:]
    for event in persisted + transientEvents {
      candidatesById[event.id] = event
    }
    let exact = candidatesById.values
      .filter { abs($0.timestamp.timeIntervalSince(at)) < 0.001 }
      .sorted { $0.id < $1.id }
    if let fact = exact.first {
      return fact.id
    }
    if let transient = transientEvents
      .sorted(by: { lhs, rhs in
        let lhsDistance = abs(lhs.timestamp.timeIntervalSince(at))
        let rhsDistance = abs(rhs.timestamp.timeIntervalSince(at))
        if lhsDistance == rhsDistance { return lhs.id < rhs.id }
        return lhsDistance < rhsDistance
      })
      .first {
      return transient.id
    }
    return candidatesById.values
      .sorted(by: { lhs, rhs in
        let lhsDistance = abs(lhs.timestamp.timeIntervalSince(at))
        let rhsDistance = abs(rhs.timestamp.timeIntervalSince(at))
        if lhsDistance == rhsDistance { return lhs.id < rhs.id }
        return lhsDistance < rhsDistance
      })
      .first?.id
  }

  // MARK: - Scoped-event pipeline (shared)

  /// A journey-scoped event staged for local-first dispatch: enriched
  /// properties, the local event, and its transient StoredEvent for IR
  /// queries before the server round trip completes.
  // @unchecked Sendable: immutable snapshot; the enriched payload is
  // write-once and never mutated after staging.
  private struct ScopedEventStage: @unchecked Sendable {
    let enrichedProperties: [String: Any]
    let localEvent: NuxieEvent
    let transientEvent: StoredEvent
  }

  /// Enrich and stage a scoped event. All three scoped pipelines
  /// (permission, unsupported-permission, goal) build events this way; the
  /// paths differ only in how they dispatch, which stays at each call site.
  private func stageScopedEvent(
    name: String,
    properties: sending [String: Any],
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
    properties: sending [String: Any]
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
    experiences: [Experience]
  ) async {
    let results = await startJourneysMatchingEvent(
      event,
      experiences: experiences,
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
      experiences: experiences,
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

  private func exitDecision(_ journey: Journey) async -> JourneyExitReason? {

    let mode = journey.exitPolicySnapshot?.mode ?? .never

    if (mode == .onGoal || mode == .onGoalOrStop), journey.convertedAt != nil {
      return .goalMet
    }

    return nil
  }

  private func shouldDeferExitDecision(for journey: Journey) async -> Bool {
    guard await experiencePresentationService.isExperiencePresented else {
      return false
    }
    return await experiencePresentationService.presentedJourneyId == journey.id
  }

  private func shouldCompletePresentedScopedGoalJourney(
    _ journey: Journey
  ) async -> Bool {
    guard journey.status.isLive, journey.convertedAt != nil else {
      return false
    }
    guard await shouldDeferExitDecision(for: journey) else {
      return false
    }
    return await exitDecision(journey) == .goalMet
  }

  // MARK: - Reentry Policy

  private func suppressionReason(experience: Experience, distinctId: String) -> SuppressReason? {
    let hasLiveJourney = inMemoryJourneysById.values.contains {
      $0.distinctId == distinctId && $0.experienceId == experience.id && $0.status.isLive
    }
    return EnrollmentPolicy.suppressionReason(
      reentry: experience.reentry,
      hasLiveJourney: hasLiveJourney,
      hasCompleted: {
        journeyStore.hasCompletedExperience(distinctId: distinctId, experienceId: experience.id)
      },
      lastCompletionAt: {
        journeyStore.lastCompletionTime(distinctId: distinctId, experienceId: experience.id)
      },
      timeIntervalSinceLastCompletion: {
        dateProvider.timeIntervalSince($0)
      }
    )
  }

  // MARK: - Experience Lookup

  private func getExperience(id: String) async -> Experience? {
    guard let profile = await profileService.getCachedProfile(distinctId: identityService.getDistinctId()) else {
      return nil
    }
    return await loadAuthenticatedExperience(
      profile.experiences.first { $0.experienceId == id }
    )
  }

  private func getExperience(id: String, for distinctId: String) async -> Experience? {
    guard let profile = await profileService.getCachedProfile(distinctId: distinctId) else {
      return nil
    }
    return await loadAuthenticatedExperience(
      profile.experiences.first { $0.experienceId == id }
    )
  }

  private func getExperience(
    id: String,
    versionId: String,
    for distinctId: String
  ) async -> Experience? {
    guard let profile = await profileService.getCachedProfile(distinctId: distinctId) else {
      return nil
    }
    return await loadAuthenticatedExperience(
      profile.experience(id: id, versionId: versionId)
    )
  }

  private func getAllExperiences() async -> [Experience]? {
    guard let profile = await profileService.getCachedProfile(distinctId: identityService.getDistinctId()) else {
      return nil
    }
    var experiences: [Experience] = []
    for remote in profile.experiences {
      if let experience = await loadAuthenticatedExperience(remote) {
        experiences.append(experience)
      }
    }
    return experiences
  }

  private func getAllExperiences(for distinctId: String) async -> [Experience]? {
    guard let profile = await profileService.getCachedProfile(distinctId: distinctId) else {
      return nil
    }
    var experiences: [Experience] = []
    for remote in profile.experiences {
      if let experience = await loadAuthenticatedExperience(remote) {
        experiences.append(experience)
      }
    }
    return experiences
  }

  private func loadAuthenticatedExperience(
    _ remote: RemoteExperience?
  ) async -> Experience? {
    guard let remote else { return nil }
    do {
      return try await experienceService.fetchExperience(
        experienceId: remote.experienceId,
        versionId: remote.versionId
      )
    } catch {
      LogWarning(
        "JourneyService: refusing experience \(remote.versionId) because its package failed to load: \(error)"
      )
      return nil
    }
  }

  // MARK: - Trigger Evaluation

  private func shouldTriggerFromEvent(experience: Experience, event: NuxieEvent) async -> Bool {
    guard let trigger = experience.trigger else {
      return false
    }
    switch trigger {
    case .event(let config):
      guard config.eventName == event.name else { return false }
      if let condition = config.condition {
        return await evalConditionIR(condition, event: event)
      }
      return true
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

}
