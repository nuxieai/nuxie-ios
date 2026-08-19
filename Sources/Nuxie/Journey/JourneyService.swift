import Foundation

/// Reason for resuming a journey
enum ResumeReason: Sendable {
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

enum JourneyTransitionAnalytics {
  static func shouldTrack(from previousScreenId: String?, to screenId: String) -> Bool {
    previousScreenId != screenId
  }
}

/// Protocol for journey management
protocol JourneyServiceProtocol: AnyObject, Sendable {
  @discardableResult
  func startJourney(for experience: Experience, distinctId: String, originEventId: String?) async -> Journey?

  func resumeJourney(_ journey: Journey) async


  func handleEvent(_ event: NuxieEvent) async

  func handleEventForTrigger(_ event: NuxieEvent) async -> [JourneyTriggerResult]

  func getActiveJourneys(for distinctId: String) async -> [Journey]

  func checkExpiredTimers() async

  func initialize() async

  func retryRestoredPresentations() async

  func onAppWillEnterForeground() async

  func onAppBecameActive() async

  func onAppDidEnterBackground() async

  func shutdown() async

  func handleUserChange(from oldDistinctId: String, to newDistinctId: String) async
}

protocol PresentationAttemptJourneyRouting: JourneyServiceProtocol {
  func handleEventForTrigger(
    _ event: NuxieEvent,
    presentationAttempt: ExperiencePresentationAttempt?
  ) async -> [JourneyTriggerResult]
}

extension JourneyServiceProtocol {
  func retryRestoredPresentations() async {}

  func handleEventForTrigger(
    _ event: NuxieEvent,
    presentationAttempt: ExperiencePresentationAttempt?
  ) async -> [JourneyTriggerResult] {
    guard let router = self as? any PresentationAttemptJourneyRouting else {
      return await handleEventForTrigger(event)
    }
    return await router.handleEventForTrigger(
      event,
      presentationAttempt: presentationAttempt
    )
  }
}

private enum JourneyPresentationTraceMilestone: Hashable {
  case runtimeReady
  case shellPresented
  case revealed
  case firstPresentedDrawable(screenId: String)
  case firstAcceptedInput
  case cleanupCompleted

  init?(stage: ExperiencePresentationTraceStage) {
    switch stage {
    case .runtimeReady:
      self = .runtimeReady
    case .shellPresented:
      self = .shellPresented
    case .revealed:
      self = .revealed
    case .firstPresentedDrawable(let screenId, _, _, _, _):
      self = .firstPresentedDrawable(screenId: screenId)
    case .firstAcceptedInput:
      self = .firstAcceptedInput
    case .presentationCleanupCompleted:
      self = .cleanupCompleted
    case .triggerAccepted,
         .eventTracked,
         .journeyMatched,
         .presentationRequested,
         .workStarted,
         .workCompleted,
         .workFailed,
         .presentationFailed,
         .presentationAbandoned:
      return nil
    }
  }
}

private struct JourneyPresentationTraceState {
  let presentationToken: UUID
  var attempt: ExperiencePresentationAttempt
  var recordedMilestones: Set<JourneyPresentationTraceMilestone> = []
}

actor JourneyService: JourneyServiceProtocol {

  private struct AdmissionKey: Hashable {
    let distinctId: String
    let experienceId: String
  }

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
  private let presentationTrace: ExperiencePresentationTraceRecording
  private let restoredPresentationAttempt: ExperiencePresentationAttempt?

  // MARK: - State

  private var inMemoryJourneysById: [String: Journey] = [:]
  private var experienceRunners: [String: JourneyRunner] = [:]
  private var runtimeDelegates: [String: JourneyRendererBridge] = [:]
  private var presentationTraceStates: [String: JourneyPresentationTraceState] = [:]
  private let timerScheduler: JourneyTimerScheduler
  private var completingJourneyIds: Set<String> = []
  private var claimingJourneyIds: Set<String> = []
  private var admissionsInProgress: Set<AdmissionKey> = []
  private var restoredPresentationRetriesInProgress: Set<String> = []
  private var scopedAuthoredResponseTasks: [UUID: Task<Void, Never>] = [:]
  private var scopedAuthoredResponseTail: (id: UUID, task: Task<Void, Never>)?
  private var scopedAuthoredOutcomeDepth = 0
  private var nextScopedAuthoredResponseToSchedule: UInt64 = 0
  private var pendingScopedAuthoredResponses: [UInt64: PendingScopedAuthoredResponse] = [:]

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
    api: ResponseWriting,
    presentationTrace: ExperiencePresentationTraceRecording = DisabledExperiencePresentationTrace(),
    restoredPresentationAttempt: ExperiencePresentationAttempt? = nil
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
    self.presentationTrace = presentationTrace
    self.restoredPresentationAttempt = restoredPresentationAttempt
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

    for persistedSnapshot in persisted where persistedSnapshot.status.isLive {
      var snapshot = persistedSnapshot
      if let restoredPresentationAttempt,
         snapshot.distinctId == identityService.getDistinctId(),
         ExperiencePresentationAttemptJourneyContext.load(from: snapshot)?.id
           != restoredPresentationAttempt.id {
        ExperiencePresentationAttemptJourneyContext.store(
          restoredPresentationAttempt,
          in: &snapshot,
          at: dateProvider.now()
        )
        do {
          try journeyStore.saveJourney(snapshot)
          presentationTrace.record(
            attempt: restoredPresentationAttempt,
            stage: .journeyMatched(journeyId: snapshot.id),
            at: dateProvider.now()
          )
        } catch {
          LogWarning(
            "JourneyService: failed to bind restored presentation trace for \(snapshot.id): \(error)"
          )
          snapshot = persistedSnapshot
        }
      }
      restorePersistedJourney(Journey(snapshot: snapshot), state: snapshot)
    }

    if let profile = await profileService.getCachedProfile(
      distinctId: identityService.getDistinctId()
    ), let mailbox = profile.mailbox {
      await handleMailbox(mailbox, distinctId: identityService.getDistinctId())
    }

    await checkExpiredTimers()
    await retryRestoredPresentations()
  }

  /// Rebuilds presentation runners for live journeys whose durable screen
  /// commit survived a process death. Startup profile admission and journey
  /// restoration run concurrently, so both sides call this convergent retry:
  /// whichever finishes second finds both authorities ready and resumes the
  /// exact signed release/screen without requiring another customer event.
  func retryRestoredPresentations() async {
    let activeDistinctId = identityService.getDistinctId()
    var hasPresentationToRestore = false
    for journey in inMemoryJourneysById.values {
      let state = await journey.snapshot()
      if journey.distinctId == activeDistinctId,
         state.status.isLive,
         state.executionState.pendingPresentation != nil ||
           state.executionState.currentScreenId != nil {
        hasPresentationToRestore = true
        break
      }
    }
    guard hasPresentationToRestore else { return }
    guard let experiences = await getAllExperiences(
      for: activeDistinctId
    ) else {
      return
    }
    guard identityService.getDistinctId() == activeDistinctId else { return }
    await retryRestoredPresentations(using: experiences, distinctId: activeDistinctId)
  }

  private func retryRestoredPresentations(
    using experiences: [Experience],
    distinctId: String
  ) async {
    let journeys = Array(inMemoryJourneysById.values)
    for journey in journeys {
      let state = await journey.snapshot()
      guard identityService.getDistinctId() == distinctId,
            journey.distinctId == distinctId,
            state.status.isLive,
            state.executionState.pendingPresentation != nil ||
              state.executionState.currentScreenId != nil,
            restoredPresentationRetriesInProgress.insert(journey.id).inserted else {
        continue
      }
      defer { restoredPresentationRetriesInProgress.remove(journey.id) }

      guard let experience = experiences.first(where: {
        $0.id == journey.experienceId &&
          $0.versionId == journey.experienceVersion
      }) else {
        continue
      }
      if experienceRunners[journey.id] != nil,
         let pending = state.executionState.pendingPresentation {
        guard await experiencePresentationService.presentedJourneyId != journey.id else {
          continue
        }
        await handleOutcome(.present(pending), journey: journey)
        continue
      }
      _ = await ensureRunner(
        for: journey,
        experience: experience,
        stimulus: .restoration
      )
    }
  }

  public func onAppWillEnterForeground() async {
    await checkExpiredTimers()

    let now = dateProvider.now()
    for journey in inMemoryJourneysById.values {
      let state = await journey.snapshot()
      guard state.status.isLive else { continue }
      if let pending = state.executionState.pendingAction,
         let resumeAt = pending.resumeAt,
         resumeAt > now {
        scheduleResume(journeyId: journey.id, at: resumeAt)
      }
    }
  }

  public func onAppBecameActive() async {
    await experiencePresentationService.onAppBecameActive()
    await retryRestoredPresentations()
  }

  public func onAppDidEnterBackground() async {
    timerScheduler.cancelAll()
    await experiencePresentationService.onAppDidEnterBackground()

    for journey in inMemoryJourneysById.values {
      let state = await journey.snapshot()
      guard state.status.isLive else { continue }
      persistJourney(state)
      enqueueParking(state, reason: .background)
    }

    LogInfo("JourneyService background snapshot complete")
  }

  public func shutdown() async {
    timerScheduler.cancelAll()
    for task in scopedAuthoredResponseTasks.values {
      task.cancel()
    }
    scopedAuthoredResponseTasks.removeAll()
    scopedAuthoredResponseTail = nil
    pendingScopedAuthoredResponses.removeAll()
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

    for snapshot in persisted {
      let journey = Journey(snapshot: snapshot)
      inMemoryJourneysById[journey.id] = journey
      if let pending = snapshot.executionState.pendingAction, let resumeAt = pending.resumeAt {
        scheduleResume(journeyId: snapshot.id, at: resumeAt)
      }
    }

    await checkExpiredTimers()
    await retryRestoredPresentations()
  }

  // MARK: - Public API

  public func startJourney(
    for experience: Experience,
    distinctId: String,
    originEventId: String? = nil
  ) async -> Journey? {
    let admissionKey = AdmissionKey(
      distinctId: distinctId,
      experienceId: experience.id
    )
    guard admissionsInProgress.insert(admissionKey).inserted else {
      LogDebug("Journey admission already in progress for experience \(experience.id)")
      return nil
    }
    defer { admissionsInProgress.remove(admissionKey) }

    guard await suppressionReason(experience: experience, distinctId: distinctId) == nil else {
      LogDebug("User \(distinctId) cannot start journey for experience \(experience.id)")
      return nil
    }

    return await startJourneyInternal(
      for: experience,
      distinctId: distinctId,
      originEventId: originEventId,
      presentationAttempt: nil
    )
  }

  private func startJourneyInternal(
    for experience: Experience,
    distinctId: String,
    originEventId: String? = nil,
    presentationAttempt: ExperiencePresentationAttempt?
  ) async -> Journey? {
    let journey = Journey(experience: experience, distinctId: distinctId, now: dateProvider.now())
    if let originEventId {
      await journey.setContext("_origin_event_id", value: AnyCodable(originEventId), at: dateProvider.now())
    }
    if let presentationAttempt {
      await ExperiencePresentationAttemptJourneyContext.store(
        presentationAttempt,
        in: journey,
        at: dateProvider.now()
      )
    }

    inMemoryJourneysById[journey.id] = journey

    let enrollmentState = await journey.snapshot()
    do {
      _ = try await eventLog.trackWithResponse(
        JourneyEvents.journeyEnrolled,
        properties: JourneyEvents.journeyEnrolledProperties(
          journey: enrollmentState,
          experience: experience,
          triggerRef: originEventId ?? "device:\(journey.id)"
        )
      )
    } catch {
      LogWarning("JourneyService: Failed to persist journey enrollment: \(error)")
      await journey.cancel(at: dateProvider.now())
      inMemoryJourneysById.removeValue(forKey: journey.id)
      return nil
    }
    guard inMemoryJourneysById[journey.id] === journey else {
      return nil
    }

    if let presentationAttempt {
      presentationTrace.record(
        attempt: presentationAttempt,
        stage: .journeyMatched(journeyId: journey.id),
        at: dateProvider.now()
      )
    }

    guard await ensureRunner(
      for: journey,
      experience: experience,
      stimulus: .initialEnrollment
    ) != nil else {
      await completeJourney(journey, reason: .error)
      return journey
    }

    // Persist after the synchronous enrollment fact so a crash cannot leave
    // server admission without the corresponding local run snapshot.
    persistJourney(await journey.snapshot())

    return journey
  }

  public func resumeJourney(_ journey: Journey) async {
    let state = await journey.snapshot()
    guard state.status == .paused || state.status == .active else { return }

    guard let experience = await getExperience(
      id: journey.experienceId,
      versionId: journey.experienceVersion,
      for: journey.distinctId
    ) else {
      await cancelJourney(journey)
      return
    }

    guard let runner = await ensureRunner(
      for: journey,
      experience: experience,
      stimulus: .restoration
    ) else {
      await completeJourney(journey, reason: .error)
      return
    }

    await journey.resume(at: dateProvider.now())
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
    let wasPaused = (await journey.snapshot()).status == .paused
    if wasPaused {
      await journey.resume(at: dateProvider.now())
    }

    let outcome = await runner.resumePendingAction(reason: .event(event), event: event)
    await handleOutcome(outcome, journey: journey)

    guard wasPaused else { return }

    // Same wait re-armed means the journey is still waiting — nothing
    // resumed. Identity is handler + original startedAt: a re-pause of
    // the same wait preserves both (resume-chain indexes are rebased to
    // 0, so actionIndex is NOT stable), while a later wait in the same
    // chain gets a fresh startedAt.
    if let reArmed = (await journey.snapshot()).executionState.pendingAction,
       reArmed.kind == .waitUntil,
       reArmed.handlerId == pending.handlerId,
       reArmed.startedAt == pending.startedAt {
      return
    }

  }

  public func handleEvent(_ event: NuxieEvent) async {
    _ = await routeEvent(event, presentationAttempt: nil)
  }

  public func handleEventForTrigger(_ event: NuxieEvent) async -> [JourneyTriggerResult] {
    return await routeEvent(event, presentationAttempt: nil)
  }

  private func routeEvent(
    _ event: NuxieEvent,
    presentationAttempt: ExperiencePresentationAttempt?
  ) async -> [JourneyTriggerResult] {
    await applySupersededDownFactIfNeeded(event)
    await applyConvertedDownFactIfNeeded(event)
    let traceContext = presentationAttempt.map {
      ExperiencePresentationTraceContext(
        attempt: $0,
        recorder: presentationTrace
      )
    }
    guard let experiences = await getAllExperiences(
      for: event.distinctId,
      presentationTraceContext: traceContext
    ) else { return [] }
    let results = await startJourneysMatchingEvent(
      event,
      experiences: experiences,
      presentationAttempt: presentationAttempt
    )
    await processActiveJourneys(
      for: event,
      experiences: experiences,
      transientEventsByJourneyId: [:],
      restrictedToJourneyIds: nil,
      presentationAttempt: presentationAttempt
    )
    return results
  }

  private func applySupersededDownFactIfNeeded(_ event: NuxieEvent) async {
    guard event.name == JourneyEvents.journeySuperseded,
          event.properties[StoredEvent.originProperty] as? String
            == StoredEventOrigin.server.rawValue,
          let journeyId = event.properties["journey_id"] as? String,
          let journey = inMemoryJourneysById[journeyId] else {
      return
    }
    let state = await journey.update { state in
      guard state.status.isLive else { return state }
      state.isGhost = true
      state.updatedAt = dateProvider.now()
      return state
    }
    guard state.isGhost else { return }
    persistJourney(state)
    LogInfo("Journey \(journey.id) entered ghost play-out after server supersede")
  }

  private func discardEpochRejectedJourney(
    journeyId: String,
    authoritativeEpoch: Int
  ) async {
    guard let journey = inMemoryJourneysById[journeyId] else {
      return
    }
    let state = await journey.snapshot()
    guard authoritativeEpoch >= state.epoch else { return }
    let warning =
      "JourneyService: discarding epoch-rejected journey \(journeyId); " +
      "device=\(state.epoch), authoritative=\(authoritativeEpoch)"
    LogWarning(warning)
    await discardLocalJourney(journey, terminalStatus: .superseded)
  }

  private func handleJourneyHandoffDelivered(journeyId: String) async {
    guard let journey = inMemoryJourneysById[journeyId] else { return }
    await discardLocalJourney(journey, terminalStatus: .transferred)
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
      await claimed.applyStateEnvelope(
        entry.envelope,
        epoch: acknowledgement.epoch
      )
      let claimedState = await claimed.update { state in
        state.resumePoint = entry.resumePoint
        state.status = state.executionState.pendingAction == nil ? .active : .paused
        return state
      }

      do {
        try journeyStore.saveJourney(claimedState)
      } catch {
        LogError("JourneyService: failed to persist claimed journey \(entry.journeyId): \(error)")
        continue
      }

      // Deliberately reload before admission: claimed and launch-restored
      // journeys share one decoding/resume implementation.
      guard let restoredSnapshot = journeyStore.loadJourney(id: entry.journeyId) else {
        LogError("JourneyService: failed to reload claimed journey \(entry.journeyId)")
        continue
      }
      let restored = Journey(snapshot: restoredSnapshot)
      restorePersistedJourney(restored, state: restoredSnapshot)
      if entry.kind == .pending {
        await beginClaimedDeviceRegion(restored, experience: experience)
      } else {
        _ = await ensureRunner(
          for: restored,
          experience: experience,
          stimulus: .restoration
        )
      }
    }
  }

  private func restorePersistedJourney(_ journey: Journey, state: JourneySnapshot) {
    inMemoryJourneysById[journey.id] = journey
    if let pending = state.executionState.pendingAction,
       let resumeAt = pending.resumeAt {
      scheduleResume(journeyId: journey.id, at: resumeAt)
    }
  }

  private func beginClaimedDeviceRegion(
    _ journey: Journey,
    experience: Experience
  ) async {
    let state = await journey.snapshot()
    guard state.executionState.pendingAction == nil,
          let runner = await ensureRunner(
            for: journey,
            experience: experience,
            stimulus: .claimedDeviceRegion
          ) else {
      return
    }
    guard let regionId = state.executionState.regionId,
          let region = experience.screens.deviceRegions?.first(where: {
            $0.id == regionId
          }) else {
      LogWarning(
        "JourneyService: claimed journey \(journey.id) has no matching device region"
      )
      return
    }
    let outcome = await runner.advanceClaimedDeviceRegion(region)
    await handleOutcome(outcome, journey: journey)
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

    let now = dateProvider.now()
    let state = await journey.update { state in
      if state.convertedAt == nil || at < state.convertedAt! {
        state.convertedAt = at
        state.setContext("_conversion_source_fact_ref", value: sourceFactRef, at: now)
      }
      return state
    }
    persistJourney(state)

    switch state.exitPolicySnapshot?.mode {
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
    var result: [Journey] = []
    for journey in inMemoryJourneysById.values where journey.distinctId == distinctId {
      if (await journey.snapshot()).status.isLive { result.append(journey) }
    }
    return result
  }

  public func checkExpiredTimers() async {
    let now = dateProvider.now()

    for journey in inMemoryJourneysById.values {
      let state = await journey.snapshot()
      guard state.status.isLive else { continue }
      if let pending = state.executionState.pendingAction, let resumeAt = pending.resumeAt, resumeAt <= now {
        await resumeJourney(journey)
        continue
      }
    }
  }

  // MARK: - Renderer Events

  func handleWillActivateInitialScreen(
    journeyId: String,
    controller: ExperienceViewController
  ) async -> Bool {
    guard let journey = inMemoryJourneysById[journeyId],
          let runner = experienceRunners[journeyId] else { return false }
    let attachedController = await runner.viewController
    if let attachedController {
      guard attachedController === controller else { return false }
    } else {
      await runner.attach(viewController: controller)
    }
    let state = await journey.snapshot()
    if let pending = state.executionState.pendingPresentation,
       !(await experienceService.validatesPresentationCommit(pending)) {
      await retireStalePresentation(journey: journey, commit: pending)
      return false
    }
    let committed = await runner.commitRendererAttachment()
    let stillAuthoritative: Bool
    if let pending = state.executionState.pendingPresentation {
      stillAuthoritative = await experienceService.validatesPresentationCommit(pending)
    } else {
      stillAuthoritative = true
    }
    if !committed || !stillAuthoritative {
      if !stillAuthoritative,
         let pending = state.executionState.pendingPresentation {
        await retireStalePresentation(journey: journey, commit: pending)
      }
      return false
    }
    return true
  }

  func handleRuntimeReady(
    journeyId: String,
    controller: ExperienceViewController
  ) async {
    guard let journey = inMemoryJourneysById[journeyId],
          let runner = experienceRunners[journeyId] else { return }

    let outcome = await runner.handleRuntimeReady()
    await handleOutcome(outcome, journey: journey)
  }

  func handleRuntimeProductsUnavailable(
    journeyId: String,
    screenId: String
  ) async {
    guard let journey = inMemoryJourneysById[journeyId],
          let runner = experienceRunners[journeyId] else { return }

    LogWarning(
      "JourneyService: live products unavailable for screen \(screenId) in journey \(journeyId)"
    )
    await handleOutcome(
      await runner.handleRuntimeProductsUnavailable(),
      journey: journey
    )
  }

  func handlePresentationTraceStage(
    journeyId: String,
    presentationToken: UUID,
    stage: ExperiencePresentationTraceStage,
    timestamp: ExperiencePresentationTimestamp
  ) {
    guard var state = presentationTraceStates[journeyId],
          state.presentationToken == presentationToken,
          let milestone = JourneyPresentationTraceMilestone(stage: stage),
          state.recordedMilestones.insert(milestone).inserted else {
      return
    }

    presentationTrace.record(
      attempt: state.attempt,
      stage: stage,
      timestamp: timestamp
    )

    if milestone == .cleanupCompleted {
      presentationTraceStates.removeValue(forKey: journeyId)
      runtimeDelegates.removeValue(forKey: journeyId)
    } else {
      presentationTraceStates[journeyId] = state
    }
  }

  func handleRendererScreenChanged(
    journeyId: String,
    screenId: String
  ) async {
    guard let journey = inMemoryJourneysById[journeyId],
          let runner = experienceRunners[journeyId] else { return }

    let previousState = await journey.snapshot()
    let previousScreenId = previousState.executionState.currentScreenId
    let outcome = await runner.handleScreenChanged(screenId)
    await handleOutcome(outcome, journey: journey)
    var state = await journey.snapshot()
    persistJourney(state)

    if !state.isGhost,
       JourneyTransitionAnalytics.shouldTrack(from: previousScreenId, to: screenId) {
      do {
        _ = try await eventLog.trackWithResponse(
          JourneyEvents.journeyTransition,
          properties: JourneyEvents.journeyTransitionProperties(
            journey: state,
            fromNode: previousScreenId,
            toNode: screenId
          )
        )
      } catch {
        LogWarning("JourneyService: Failed to persist transition to \(screenId): \(error)")
      }
    }
    state = await journey.snapshot()
    persistJourney(state)
  }

  func handleRendererScreenDismissed(
    journeyId: String,
    screenId: String,
    revealingScreenId: String?,
    method: String
  ) async {
    guard let journey = inMemoryJourneysById[journeyId],
          let runner = experienceRunners[journeyId] else { return }

    let outcome = await runner.handleScreenDismissed(
      screenId,
      revealingScreenId: revealingScreenId,
      method: method
    )
    await handleOutcome(outcome, journey: journey)
    var state = await journey.snapshot()
    persistJourney(state)

    if let revealingScreenId, !state.isGhost {
      do {
        _ = try await eventLog.trackWithResponse(
          JourneyEvents.journeyTransition,
          properties: JourneyEvents.journeyTransitionProperties(
            journey: state,
            fromNode: screenId,
            toNode: revealingScreenId
          )
        )
      } catch {
        LogWarning("JourneyService: Failed to persist transition to \(revealingScreenId): \(error)")
      }
      state = await journey.snapshot()
      persistJourney(state)
    }
  }

  func handleRendererViewModelChange(
    journeyId: String,
    change: ExperienceRendererViewModelChange
  ) async {
    guard let journey = inMemoryJourneysById[journeyId],
          let runner = experienceRunners[journeyId] else { return }

    let state = await journey.snapshot()
    let outcome = await runner.handleDidSet(
      path: change.path,
      value: change.value,
      source: change.source,
      screenId: change.screenId ?? state.executionState.currentScreenId,
      instanceId: change.instanceId,
      isTrigger: change.isTrigger
    )
    await handleOutcome(outcome, journey: journey)
    persistJourney(await journey.snapshot())
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
    let state = await journey.snapshot()
    let outcome = await runner.dispatchScreenEvent(
      event,
      screenId: rendererEvent.screenId ?? state.executionState.currentScreenId,
      componentId: rendererEvent.componentId,
      instanceId: rendererEvent.instanceId
    )
    await handleOutcome(outcome, journey: journey)
    persistJourney(await journey.snapshot())

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
      presentationAttempt: nil
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

    if reason == .userDismissed,
       let traceState = presentationTraceStates[journeyId],
       !traceState.recordedMilestones.contains(.revealed) {
      presentationTrace.record(
        attempt: traceState.attempt,
        stage: .presentationAbandoned(
          route: .journey,
          reason: "user_dismissed"
        ),
        at: dateProvider.now()
      )
    }

    var userInfo: [String: Any] = [
      "journeyId": journey.id,
      "experienceId": journey.experienceId
    ]
    var state = await journey.snapshot()
    if let screenId = state.executionState.currentScreenId {
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

    // A failed response operation deliberately keeps the draft and the live
    // journey available for an explicit retry. Do not turn that recovery path
    // into an abandonment merely because the renderer was dismissed.
    if state.responseSessionRetryRequired || await runner.hasFailedResponseOperation() {
      return
    }

    state = await journey.snapshot()
    if state.status.isLive {
      await evaluateGoalIfNeeded(journey)
      if let reason = await exitDecision(journey) {
        await completeJourney(journey, reason: reason)
        return
      }
    }

    state = await journey.snapshot()
    if state.status.isLive, await runner.hasPendingPermissionWork() {
      await runner.deferDismiss(reason: reason)
      return
    }

    if (await journey.snapshot()).status.isLive {
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
    guard let journey = inMemoryJourneysById[journeyId] else {
      return
    }
    let sourceState = await journey.snapshot()
    guard !sourceState.isGhost else { return }

    let scopedDistinctId = journey.distinctId
    let properties = JourneyEvents.journeyMilestoneProperties(
      journey: sourceState,
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

  private struct CommittedScopedAuthoredEvent {
    let authored: JourneyRunner.AuthoredEvent
    let commit: PreparedTriggerCommit
    let eventSentProperties: [String: Any]
  }

  private struct RoutedScopedAuthoredEvent {
    let commit: PreparedTriggerCommit
    let sourceCompleted: Bool
    let experiences: [Experience]?
  }

  private struct PendingScopedAuthoredResponse {
    let routed: RoutedScopedAuthoredEvent
    let sourceJourney: Journey
  }

  private func commitScopedAuthoredEvent(
    sourceJourney journey: Journey,
    event: JourneyRunner.AuthoredEvent
  ) async -> CommittedScopedAuthoredEvent? {
    let sourceState = await journey.snapshot()
    guard !sourceState.isGhost else { return nil }

    var properties = event.properties.mapValues(\.value)
    properties["journey_id"] = journey.id
    properties["experience_id"] = journey.experienceId
    if let screenId = event.screenId {
      properties["screen_id"] = screenId
    }
    let eventSentProperties = JourneyEvents.eventSentProperties(
      journey: sourceState,
      screenId: event.screenId,
      eventName: event.name,
      eventProperties: properties
    )
    if let handlerId = event.handlerId {
      properties["handler_id"] = handlerId
    }

    let propertiesBox = UncheckedSendable(properties)
    let stage = await stageScopedEvent(
      name: event.name,
      properties: propertiesBox.value,
      distinctId: journey.distinctId
    )
    guard let preparedEvent = await eventLog.applyBeforeSend(
      to: stage.localEvent
    ) else {
      eventLog.track(
        JourneyEvents.eventSent,
        properties: eventSentProperties,
        userProperties: nil,
        userPropertiesSetOnce: nil,
        distinctIdOverride: journey.distinctId
      )
      return nil
    }
    let commit = await eventLog.commitPreparedTriggerEvent(preparedEvent)
    return CommittedScopedAuthoredEvent(
      authored: event,
      commit: commit,
      eventSentProperties: eventSentProperties
    )
  }

  private func routeCommittedScopedAuthoredEvent(
    _ committedAuthoredEvent: CommittedScopedAuthoredEvent,
    sourceJourney journey: Journey
  ) async -> RoutedScopedAuthoredEvent {
    let journeyId = journey.id
    let authored = committedAuthoredEvent.authored
    let committed = committedAuthoredEvent.commit
    let confirmedEvent = committed.event
    let transientEvent = makeStoredEvent(from: confirmedEvent)
    let belongsToSourceIdentity = confirmedEvent.distinctId == journey.distinctId
    let cachedExperiences = await getAllExperiences(
      for: confirmedEvent.distinctId
    )
    let sourceCompleted = if belongsToSourceIdentity {
      await processSourceScopedGoalJourneyEvent(
        journey,
        event: confirmedEvent,
        transientEvent: transientEvent,
        shouldDispatchToRunner: false
      )
    } else {
      false
    }
    if belongsToSourceIdentity,
       !sourceCompleted,
       let runner = experienceRunners[journeyId],
       (await journey.snapshot()).status.isLive {
      let outcome: JourneyRunner.RunOutcome?
      if authored.hostId == JourneyDocument.journeyEventHostKey {
        outcome = await runner.dispatchEventTrigger(confirmedEvent)
      } else if let hostId = authored.hostId, !hostId.isEmpty {
        outcome = await runner.dispatchScreenEvent(
          confirmedEvent,
          screenId: hostId,
          componentId: nil,
          instanceId: nil
        )
      } else if let screenId = authored.screenId {
        outcome = await runner.dispatchScreenEvent(
          confirmedEvent,
          screenId: screenId,
          componentId: nil,
          instanceId: nil
        )
      } else {
        outcome = await runner.dispatchEventTrigger(confirmedEvent)
      }
      await handleOutcome(outcome, journey: journey)
    }

    let otherJourneyIds = Set(
      await getActiveJourneys(for: confirmedEvent.distinctId).map(\.id)
        .filter { $0 != journey.id }
    )
    if !otherJourneyIds.isEmpty {
      await processActiveJourneys(
        for: confirmedEvent,
        experiences: cachedExperiences ?? [],
        transientEventsByJourneyId: Dictionary(
          uniqueKeysWithValues: otherJourneyIds.map { ($0, [transientEvent]) }
        ),
        restrictedToJourneyIds: otherJourneyIds
      )
    }

    let experiences = if let cachedExperiences {
      cachedExperiences
    } else {
      await getAllExperiences(for: confirmedEvent.distinctId)
    }
    if let experiences {
      await startAndProcessMatchingJourneys(
        for: confirmedEvent,
        transientEvent: transientEvent,
        experiences: experiences
      )
    }
    return RoutedScopedAuthoredEvent(
      commit: committed,
      sourceCompleted: !belongsToSourceIdentity || sourceCompleted,
      experiences: experiences
    )
  }

  private func handleScopedAuthoredResponse(
    _ routed: RoutedScopedAuthoredEvent,
    sourceJourney journey: Journey
  ) async {
    let response = await routed.commit.response.value
    guard !Task.isCancelled else { return }
    await handleScopedGatePlan(
      response.gatePlan(),
      sourceJourney: routed.sourceCompleted || inMemoryJourneysById[journey.id] !== journey
        ? nil
        : journey,
      sourceExperience: sourceScopedGoalExperience(
        for: journey,
        experiences: routed.experiences
      )
    )
  }

  private func stageScopedAuthoredResponse(
    _ routed: RoutedScopedAuthoredEvent,
    sequence: UInt64,
    sourceJourney journey: Journey
  ) {
    pendingScopedAuthoredResponses[sequence] = PendingScopedAuthoredResponse(
      routed: routed,
      sourceJourney: journey
    )
  }

  private func scheduleReadyScopedAuthoredResponses() {
    guard scopedAuthoredOutcomeDepth == 0 else { return }
    while let pending = pendingScopedAuthoredResponses.removeValue(
      forKey: nextScopedAuthoredResponseToSchedule
    ) {
      nextScopedAuthoredResponseToSchedule += 1
      scheduleScopedAuthoredResponse(pending)
    }
  }

  private func scheduleScopedAuthoredResponse(
    _ pending: PendingScopedAuthoredResponse
  ) {
    let previousTask = scopedAuthoredResponseTail?.task
    let taskId = UUID()
    let task = Task { [weak self] in
      await previousTask?.value
      guard let self else { return }
      if !Task.isCancelled {
        await self.handleScopedAuthoredResponse(
          pending.routed,
          sourceJourney: pending.sourceJourney
        )
      }
      await self.finishScopedAuthoredResponseTask(id: taskId)
    }
    scopedAuthoredResponseTasks[taskId] = task
    scopedAuthoredResponseTail = (taskId, task)
  }

  private func finishScopedAuthoredResponseTask(id: UUID) {
    scopedAuthoredResponseTasks.removeValue(forKey: id)
    guard scopedAuthoredResponseTail?.id == id else { return }
    scopedAuthoredResponseTail = nil
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
          (await journey.snapshot()).status.isLive,
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
        await controller.prepareForDismissal(reason: .goalMet)
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
    var state = await journey.snapshot()
    guard shouldDispatchToRunner else {
      return !state.status.isLive
    }
    guard state.status.isLive else {
      return true
    }

    if let pending = state.executionState.pendingAction, pending.kind == .waitUntil {
      if let runner = experienceRunners[journey.id] {
        await resumePendingWaitForEvent(journey, runner: runner, pending: pending, event: event)
      }
      return !(await journey.snapshot()).status.isLive
    }

    if let runner = experienceRunners[journey.id] {
      let outcome = await runner.dispatchEventTrigger(event)
      await handleOutcome(outcome, journey: journey)
    }
    state = await journey.snapshot()
    return !state.status.isLive
  }

  private func sourceScopedGoalExperience(
    for journey: Journey,
    experiences: [Experience]?
  ) -> Experience? {
    experiences?.first(where: {
      $0.id == journey.experienceId && $0.versionId == journey.experienceVersion
    })
  }

  private enum RunnerStimulus {
    case initialEnrollment
    case restoration
    case claimedDeviceRegion
  }

  private func ensureRunner(
    for journey: Journey,
    experience: Experience,
    stimulus: RunnerStimulus
  ) async -> JourneyRunner? {
    if let existing = experienceRunners[journey.id] {
      return existing
    }

    let versionId = experience.versionId
    let controlExperience: Experience
    if experience.authenticatedReleaseID != nil || !experience.screens.screens.isEmpty {
      controlExperience = experience
    } else {
      guard let hydrated = try? await experienceService.fetchExperience(
        experienceId: experience.id,
        versionId: versionId
      ) else { return nil }
      controlExperience = hydrated
    }

    let initialState = await journey.snapshot()
    let runner = JourneyRunner(
        journey: journey,
        initialState: initialState,
        experience: controlExperience,
        onMilestone: { [weak self, journeyId = journey.id] milestoneId, label, screenId, handlerId in
          await self?.handleScopedMilestoneEvent(
            journeyId: journeyId,
            milestoneId: milestoneId,
            milestoneLabel: label,
            screenId: screenId,
            handlerId: handlerId
          )
        },
        capturesSendEvents: controlExperience.authenticatedReleaseID != nil,
        eventLog: eventLog,
        identity: identityService,
        segments: segmentService,
        features: featureService,
        profile: profileService,
        apiClient: api,
        dateProvider: dateProvider,
        irRuntime: irRuntime,
        responseSessionModule: controlExperience.definitionV2?.responseSchema.map { _ in
          ResponseSessionModule(
            store: JourneyResponseSessionStore(
              journey: journey,
              journeyStore: journeyStore
            )
          )
        },
        persistEntryActionClaim: { [weak self, weak journey] state in
          guard let self, let journey else { return false }
          return await self.persistEntryActionClaim(state, for: journey)
        }
    )

    do {
      try await runner.pinResponseSession()
    } catch {
      LogWarning("JourneyService: response session admission failed for \(journey.id): \(error)")
      return nil
    }

    await runner.setOnShowScreen { [weak self, weak runner] (screenId: String, transition: AnyCodable?) async in
      guard let self else { return }
      let controller = try? await self.presentExperienceIfNeeded(
        experienceVersionId: versionId,
        journey: journey,
        commit: nil
      )
      if let controller {
        await runner?.attach(viewController: controller)
        await MainActor.run {
          controller.navigate(to: screenId, transition: transition?.value)
        }
      }
    }
    experienceRunners[journey.id] = runner

    switch stimulus {
    case .claimedDeviceRegion:
      break
    case .initialEnrollment:
      if experience.authenticatedReleaseID != nil {
        await handleOutcome(
          await runner.advanceUntilPresentation(),
          journey: journey
        )
      } else {
        _ = try? await presentExperienceIfNeeded(
          experienceVersionId: versionId,
          journey: journey,
          commit: nil
        )
      }
    case .restoration:
      let state = await journey.snapshot()
      if state.executionState.pendingPresentation != nil {
        await handleOutcome(
          await runner.advanceUntilPresentation(),
          journey: journey
        )
      } else if let screenId = state.executionState.currentScreenId {
        let pending = JourneyPendingPresentation(
          experienceId: experience.id,
          experienceVersionId: experience.versionId,
          releaseID: experience.authenticatedReleaseID,
          presentationStyle: experience.behaviorPresentationStyle ?? .fullScreen,
          shell: experience.shellContract(screenId: screenId),
          screenId: screenId,
          transition: nil,
          continuation: state.executionState.postPresentationContinuation ?? []
        )
        let remount: JourneySnapshot = {
          var snapshot = state
          snapshot.executionState.pendingPresentation = pending
          snapshot.updatedAt = dateProvider.now()
          return snapshot
        }()
        if persistPresentationCommit(remount, for: journey) {
          await journey.update { $0 = remount }
          await handleOutcome(.present(pending), journey: journey)
        }
      } else {
        if experience.authenticatedReleaseID != nil {
          await handleOutcome(
            await runner.advanceUntilPresentation(),
            journey: journey
          )
        } else {
          _ = try? await presentExperienceIfNeeded(
            experienceVersionId: versionId,
            journey: journey,
            commit: nil
          )
        }
      }
    }

    return runner
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
    guard (await journey.snapshot()).status.isLive else { return nil }

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

    guard let runner = await ensureRunner(
      for: journey,
      experience: resolvedExperience,
      stimulus: .restoration
    ) else {
      LogWarning("Failed to rebuild runner for restored journey \(journey.id); skipping dispatch")
      return nil
    }
    return runner
  }

  private func presentExperienceIfNeeded(
    experienceVersionId: String,
    journey: Journey,
    commit: JourneyPendingPresentation?
  ) async throws -> ExperienceViewController {
    if let runner = experienceRunners[journey.id],
       let controller = await runner.viewController,
       await experiencePresentationService.isExperiencePresented {
      return controller
    }
    if let delegate = runtimeDelegates[journey.id] {
      let presentationState = await beginPresentationTrace(
        experienceVersionId: experienceVersionId,
        journey: journey,
        delegate: delegate
      )
      let controller: ExperienceViewController
      do {
        if let commit {
          controller = try await experiencePresentationService.presentExperience(
            experienceVersionId,
            from: journey,
            runtimeDelegate: delegate,
            colorSchemeMode: .light,
            commit: commit
          )
        } else {
          controller = try await experiencePresentationService.presentExperience(
            experienceVersionId,
            from: journey,
            runtimeDelegate: delegate,
            colorSchemeMode: .light
          )
        }
      } catch {
        await recordPresentationFailure(
          error,
          journeyId: journey.id,
          presentationState: presentationState,
          delegate: delegate
        )
        throw error
      }
      if let runner = experienceRunners[journey.id] {
        await runner.attach(viewController: controller)
      }
      return controller
    }

    let delegate = JourneyRendererBridge(
      journeyId: journey.id,
      distinctId: journey.distinctId,
      journeyService: self,
      dateProvider: dateProvider
    )
    runtimeDelegates[journey.id] = delegate
    let presentationState = await beginPresentationTrace(
      experienceVersionId: experienceVersionId,
      journey: journey,
      delegate: delegate
    )
    let controller: ExperienceViewController
    do {
      if let commit {
        controller = try await experiencePresentationService.presentExperience(
          experienceVersionId,
          from: journey,
          runtimeDelegate: delegate,
          colorSchemeMode: .light,
          commit: commit
        )
      } else {
        controller = try await experiencePresentationService.presentExperience(
          experienceVersionId,
          from: journey,
          runtimeDelegate: delegate,
          colorSchemeMode: .light
        )
      }
    } catch {
      await recordPresentationFailure(
        error,
        journeyId: journey.id,
        presentationState: presentationState,
        delegate: delegate
      )
      throw error
    }
    if let runner = experienceRunners[journey.id] {
      await runner.attach(viewController: controller)
    }
    return controller
  }

  private func beginPresentationTrace(
    experienceVersionId: String,
    journey: Journey,
    delegate: JourneyRendererBridge
  ) async -> JourneyPresentationTraceState? {
    guard let attempt = await ExperiencePresentationAttemptJourneyContext.load(from: journey) else {
      presentationTraceStates.removeValue(forKey: journey.id)
      await delegate.beginPresentationTrace(
        presentationToken: nil,
        context: nil
      )
      return nil
    }
    let presentationToken = UUID()
    let state = JourneyPresentationTraceState(
      presentationToken: presentationToken,
      attempt: attempt
    )
    presentationTraceStates[journey.id] = state
    let requestedAt = ExperiencePresentationTimestamp.now(
      wallClock: dateProvider.now()
    )
    ExperiencePresentationTraceContext(
      attempt: attempt,
      recorder: presentationTrace
    ).recordPresentationRequested(
      experienceVersionId: experienceVersionId,
      route: .journey,
      at: requestedAt
    )
    await delegate.beginPresentationTrace(
      presentationToken: presentationToken,
      context: ExperiencePresentationTraceContext(
        attempt: attempt,
        recorder: presentationTrace
      )
    )
    return state
  }

  private func recordPresentationFailure(
    _ error: Error,
    journeyId: String,
    presentationState: JourneyPresentationTraceState?,
    delegate: JourneyRendererBridge
  ) async {
    guard let presentationState else { return }
    presentationTrace.record(
      attempt: presentationState.attempt,
      stage: .presentationFailed(
        route: .journey,
        errorCode: ExperiencePresentationTraceContext.errorCode(for: error)
      ),
      at: dateProvider.now()
    )
    if presentationTraceStates[journeyId]?.presentationToken
      == presentationState.presentationToken {
      presentationTraceStates.removeValue(forKey: journeyId)
    }
    await delegate.clearPresentationTrace(
      ifMatching: presentationState.presentationToken
    )
    if inMemoryJourneysById[journeyId] == nil {
      runtimeDelegates.removeValue(forKey: journeyId)
    }
  }

  private func recordJourneyMatch(
    _ attempt: ExperiencePresentationAttempt,
    journey: Journey,
    persist: Bool
  ) async {
    guard await ExperiencePresentationAttemptJourneyContext.load(from: journey)?.id
      != attempt.id else {
      return
    }
    await ExperiencePresentationAttemptJourneyContext.store(
      attempt,
      in: journey,
      at: dateProvider.now()
    )
    presentationTrace.record(
      attempt: attempt,
      stage: .journeyMatched(journeyId: journey.id),
      at: dateProvider.now()
    )
    if persist {
      persistJourney(await journey.snapshot())
    }
  }

  private func handleOutcome(_ outcome: JourneyRunner.RunOutcome?, journey: Journey) async {
    var holdsScopedAuthoredResponseScheduling = false
    if let runner = experienceRunners[journey.id] {
      for authoredEvent in await runner.takeAuthoredEvents() {
        guard let event = await commitScopedAuthoredEvent(
          sourceJourney: journey,
          event: authoredEvent
        ) else { continue }
        if !holdsScopedAuthoredResponseScheduling {
          scopedAuthoredOutcomeDepth += 1
          holdsScopedAuthoredResponseScheduling = true
        }
        let routed = await routeCommittedScopedAuthoredEvent(
          event,
          sourceJourney: journey
        )
        stageScopedAuthoredResponse(
          routed,
          sequence: event.commit.sequence,
          sourceJourney: journey
        )
        // Expose the rider only after the authored event has completed local
        // routing. Production EventLog subscribers may run as soon as capture
        // commits, so queueing it during the commit phase can invert the
        // journey-visible order even when durable history is ordered.
        eventLog.track(
          JourneyEvents.eventSent,
          properties: event.eventSentProperties,
          userProperties: nil,
          userPropertiesSetOnce: nil,
          distinctIdOverride: journey.distinctId
        )
      }
    }

    await applyRunOutcome(outcome, journey: journey)
    if holdsScopedAuthoredResponseScheduling {
      scopedAuthoredOutcomeDepth -= 1
    }
    scheduleReadyScopedAuthoredResponses()
  }

  private func applyRunOutcome(_ outcome: JourneyRunner.RunOutcome?, journey: Journey) async {
    guard inMemoryJourneysById[journey.id] === journey else { return }
    guard let outcome else { return }
    switch outcome {
    case .present:
      let state = await journey.snapshot()
      guard persistPresentationCommit(state, for: journey) else { return }
      guard let pending = state.executionState.pendingPresentation else { return }
      guard pending.experienceId == state.experienceId,
            pending.experienceVersionId == state.experienceVersion,
            await experienceService.validatesPresentationCommit(pending) else {
        await completeJourney(journey, reason: .error)
        return
      }
      do {
        let controller = try await presentExperienceIfNeeded(
          experienceVersionId: state.experienceVersion,
          journey: journey,
          commit: pending
        )
        guard inMemoryJourneysById[journey.id] === journey else { return }
        let afterPresentation = await journey.snapshot()
        guard presentationCommit(
                afterPresentation.executionState.pendingPresentation,
                matches: pending
              ) || presentationCommit(
                afterPresentation.executionState.currentPresentation,
                matches: pending
              ),
              await experienceService.validatesPresentationCommit(pending) else {
          await retireStalePresentation(journey: journey, commit: pending)
          return
        }
        _ = controller
      } catch {
        LogError("Failed to present selected screen \(pending.screenId): \(error)")
        if case ExperienceError.productsUnavailable = error,
           let runner = experienceRunners[journey.id] {
          await handleOutcome(
            await runner.handleProductsUnavailable(),
            journey: journey
          )
          return
        }
        if !(await experienceService.validatesPresentationCommit(pending)) {
          await retireStalePresentation(journey: journey, commit: pending)
        }
      }
    case .paused(let pending):
      await journey.pause(at: dateProvider.now())
      let state = await journey.snapshot()
      guard persistPauseCheckpoint(state, for: journey) else { return }
      enqueueParking(
        state,
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

  private func presentationCommit(
    _ candidate: JourneyPendingPresentation?,
    matches expected: JourneyPendingPresentation
  ) -> Bool {
    guard let candidate else { return false }
    return candidate.experienceId == expected.experienceId
      && candidate.experienceVersionId == expected.experienceVersionId
      && candidate.releaseID == expected.releaseID
      && candidate.presentationStyle == expected.presentationStyle
      && candidate.screenId == expected.screenId
  }

  /// Removes only the journey that owns the exact stale authenticated commit.
  /// A replacement journey/window with the same route is left untouched.
  private func retireStalePresentation(
    journey: Journey,
    commit: JourneyPendingPresentation
  ) async {
    guard inMemoryJourneysById[journey.id] === journey else { return }
    let state = await journey.snapshot()
    guard presentationCommit(
            state.executionState.pendingPresentation,
            matches: commit
          ) || presentationCommit(
            state.executionState.currentPresentation,
            matches: commit
          ) else { return }

    let ownsPresentedWindow =
      await experiencePresentationService.presentedJourneyId == journey.id
    await journey.update { current in
      current.executionState.pendingPresentation = nil
      current.executionState.currentPresentation = nil
      current.executionState.currentScreenId = nil
      current.executionState.prePresentationContinuation = nil
      current.executionState.postPresentationContinuation = nil
      current.executionState.pendingAction = nil
      current.executionState.viewModelSnapshot = nil
      current.executionState.navigationStack = []
      current.updatedAt = dateProvider.now()
    }
    await discardLocalJourney(journey, terminalStatus: .superseded)
    if ownsPresentedWindow {
      await experiencePresentationService.dismissCurrentExperience(
        reason: .error(ExperiencePresentationError.presentationSuperseded)
      )
    }
  }

  private func transferJourneyToServer(_ journey: Journey) async {
    var state = await journey.snapshot()
    guard state.status.isLive else { return }
    if state.isGhost {
      await discardLocalJourney(journey, terminalStatus: .superseded)
      return
    }
    do {
      let (_, response) = try await eventLog.trackForTrigger(
        JourneyEvents.journeyHandoff,
        properties: JourneyEvents.journeyHandoffProperties(
          journey: state,
          envelope: state.stateEnvelope()
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
        state = await journey.snapshot()
        persistJourney(state)
        return
      }
      await discardLocalJourney(journey, terminalStatus: .transferred)
    } catch {
      LogWarning("JourneyService: failed to hand off journey \(journey.id): \(error)")
      persistJourney(await journey.snapshot())
    }
  }

  private func discardLocalJourney(
    _ journey: Journey,
    terminalStatus: JourneyStatus
  ) async {
    let now = dateProvider.now()
    await journey.update { state in
      state.status = terminalStatus
      state.updatedAt = now
    }
    timerScheduler.cancelTasks(journeyId: journey.id)
    experienceRunners.removeValue(forKey: journey.id)
    if presentationTraceStates[journey.id] == nil {
      runtimeDelegates.removeValue(forKey: journey.id)
    }
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

  private func persistJourney(_ state: JourneySnapshot) {
    guard inMemoryJourneysById[state.id] != nil else { return }
    do {
      try journeyStore.saveJourney(state)
    } catch {
      LogError("Failed to persist journey \(state.id): \(error)")
    }
  }

  private func persistPresentationCommit(
    _ state: JourneySnapshot,
    for journey: Journey
  ) -> Bool {
    guard inMemoryJourneysById[state.id] === journey,
          state.executionState.pendingPresentation != nil else { return false }
    do {
      try journeyStore.saveJourney(state)
      return true
    } catch {
      LogError("Failed to persist presentation commit for journey \(state.id): \(error)")
      return false
    }
  }

  private func persistPauseCheckpoint(
    _ state: JourneySnapshot,
    for journey: Journey
  ) -> Bool {
    guard inMemoryJourneysById[state.id] === journey,
          state.executionState.pendingAction != nil else { return false }
    do {
      try journeyStore.saveJourney(state)
      return true
    } catch {
      LogError("Failed to persist pause checkpoint for journey \(state.id): \(error)")
      return false
    }
  }

  /// Commits the runner's at-most-once entry claim before the runner may
  /// execute authored actions. Keeping the store write on JourneyService's
  /// actor preserves its ownership of the journey/store pair; the exact
  /// object check rejects a late runner after replacement or teardown.
  private func persistEntryActionClaim(
    _ state: JourneySnapshot,
    for journey: Journey
  ) -> Bool {
    guard inMemoryJourneysById[state.id] === journey else { return false }
    do {
      try journeyStore.saveJourney(state)
      return true
    } catch {
      LogError("Failed to persist entry-action claim for journey \(state.id): \(error)")
      return false
    }
  }

  private func enqueueParking(
    _ journey: JourneySnapshot,
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
    var state = await journey.snapshot()
    guard state.status.isLive,
          inMemoryJourneysById[journey.id] === journey else {
      return
    }

    if state.isGhost {
      await discardLocalJourney(journey, terminalStatus: .superseded)
      return
    }

    guard let terminalState = await commitTerminalTransition(journey, reason: reason) else {
      return
    }
    state = terminalState
    let terminalTransitionId = "terminal:\(journey.id):\(state.epoch)"
    let committedResponseAbandonment: Bool = if let receipt = state.responseSessionReceipts[terminalTransitionId] {
      if case .accepted(let status, _) = receipt {
        status == .abandoned
      } else {
        false
      }
    } else {
      false
    }

    // The local terminal transition is already durable. Network abandonment
    // is deliberately attempted only after that commit, so a crash or retry
    // can never leave an active run with a locally abandoned response.
    if let runner = experienceRunners[journey.id] {
      await runner.abandonResponseDraftsIfNeeded(force: committedResponseAbandonment)
    }

    do {
      _ = try await eventLog.trackWithResponse(
        JourneyEvents.journeyExited,
        properties: JourneyEvents.journeyExitedProperties(
          journey: state,
          reason: reason,
          at: state.completedAt ?? dateProvider.now()
        )
      )
    } catch {
      LogWarning("JourneyService: Failed to deliver journey exit: \(error)")
    }

    if let originEventId = state.getContext("_origin_event_id") as? String {
      let update = JourneyUpdate(
        journeyId: journey.id,
        experienceId: journey.experienceId,
        experienceVersion: journey.experienceVersion,
        exitReason: reason,
        goalMet: state.convertedAt != nil
      )
      Task { await triggerBroker.emit(eventId: originEventId, update: .journey(update)) }
    }

    timerScheduler.cancelTasks(journeyId: journey.id)
    experienceRunners.removeValue(forKey: journey.id)
    if presentationTraceStates[journey.id] == nil {
      runtimeDelegates.removeValue(forKey: journey.id)
    }
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
      let record = JourneyCompletionRecord(journey: state, now: dateProvider.now())
      do {
        try journeyStore.recordCompletion(record)
      } catch {
        // A missed record loosens reentry (may re-show) rather than
        // permanently blocking — log loudly instead of silently swallowing.
        LogError("Failed to record journey completion for reentry accounting: \(error)")
      }
    }
  }

  /// Atomically commits terminal journey state and response abandonment in one
  /// snapshot CAS + persistence operation. Replays use the deterministic
  /// terminal transition receipt and therefore cannot advance the response
  /// version twice.
  private func commitTerminalTransition(
    _ journey: Journey,
    reason: JourneyExitReason
  ) async -> JourneySnapshot? {
    for _ in 0..<3 {
      let versioned = await journey.versionedSnapshot()
      let state = versioned.snapshot
      guard state.status.isLive,
            inMemoryJourneysById[journey.id] === journey else {
        return nil
      }

      var terminal = state
      let now = dateProvider.now()
      if reason == .cancelled {
        terminal.cancel(at: now)
      } else {
        terminal.complete(reason: reason, at: now)
      }

      let terminalTransitionId = "terminal:\(journey.id):\(state.epoch)"
      if let response = state.responseSession,
         response.state == .draft,
         terminal.responseSessionReceipts[terminalTransitionId] == nil {
        let abandoned = ResponseSessionSnapshot(
          responseId: response.responseId,
          journeyId: response.journeyId,
          responseSchemaKey: response.responseSchemaKey,
          responseSchemaVersionId: response.responseSchemaVersionId,
          schemaVersion: response.schemaVersion,
          state: .abandoned,
          values: response.values,
          version: response.version + 1,
          createdAt: response.createdAt,
          updatedAt: now.ISO8601Format(),
          submittedAt: response.submittedAt,
          abandonedAt: now.ISO8601Format()
        )
        terminal.responseSession = abandoned
        terminal.responseSessionReceipts[terminalTransitionId] = .accepted(
          status: .abandoned,
          snapshot: abandoned
        )
      }

      guard await journey.replace(
        terminal,
        ifRevisionEquals: versioned.revision
      ) else {
        continue
      }

      do {
        try journeyStore.saveJourney(terminal)
        return terminal
      } catch {
        // A file write can fail after the atomic replace. If the durable store
        // contains the terminal receipt, keep the in-memory terminal state;
        // otherwise restore only this transition's fields without overwriting
        // unrelated concurrent journey updates.
        let persisted = journeyStore.loadJourney(id: journey.id)
        if persisted?.status == terminal.status,
           persisted?.completedAt == terminal.completedAt {
          return terminal
        }
        let terminalStatus = terminal.status
        let terminalCompletedAt = terminal.completedAt
        _ = await journey.update { current in
          guard current.status == terminalStatus,
                current.completedAt == terminalCompletedAt else { return }
          current.status = state.status
          current.exitReason = state.exitReason
          current.completedAt = state.completedAt
          current.updatedAt = state.updatedAt
          current.responseSession = state.responseSession
          current.responseSessionReceipts = state.responseSessionReceipts
        }
        LogError("JourneyService: terminal transition persistence failed for \(journey.id): \(error)")
        return nil
      }
    }
    LogError("JourneyService: terminal transition conflicted repeatedly for \(journey.id)")
    return nil
  }

  private func cancelJourney(_ journey: Journey) async {
    await completeJourney(journey, reason: .cancelled)
  }

  private func startJourneysMatchingEvent(
    _ event: NuxieEvent,
    experiences: [Experience],
    presentationAttempt: ExperiencePresentationAttempt?
  ) async -> [JourneyTriggerResult] {
    var results: [JourneyTriggerResult] = []
    let activeReferences = Set(
      await profileService.getActiveExperienceReferences(
        distinctId: event.distinctId
      ) ?? []
    )

    for experience in experiences {
      guard activeReferences.contains(ExperienceReference(
        experienceId: experience.id,
        versionId: experience.versionId
      )) else { continue }
      guard await shouldTriggerFromEvent(experience: experience, event: event) else { continue }

      let admissionKey = AdmissionKey(
        distinctId: event.distinctId,
        experienceId: experience.id
      )
      guard admissionsInProgress.insert(admissionKey).inserted else {
        results.append(.suppressed(.alreadyActive))
        continue
      }
      defer { admissionsInProgress.remove(admissionKey) }

      if let reason = await suppressionReason(experience: experience, distinctId: event.distinctId) {
        results.append(.suppressed(reason))
        continue
      }

      if let journey = await startJourneyInternal(
        for: experience,
        distinctId: event.distinctId,
        originEventId: event.id,
        presentationAttempt: presentationAttempt
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
    skipEventTriggerForJourneyIds: Set<String> = [],
    presentationAttempt: ExperiencePresentationAttempt? = nil
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

      let state = await journey.snapshot()
      if let pending = state.executionState.pendingAction, pending.kind == .waitUntil {
        if let runner = await runnerForDispatch(journey: journey, experience: experience) {
          if let presentationAttempt,
             await runner.acceptsEventTrigger(event) {
            await recordJourneyMatch(
              presentationAttempt,
              journey: journey,
              persist: true
            )
          }
          await resumePendingWaitForEvent(journey, runner: runner, pending: pending, event: event)
        }
        continue
      }

      if skipEventTriggerForJourneyIds.contains(journey.id) {
        continue
      }

      if let runner = await runnerForDispatch(journey: journey, experience: experience) {
        if let presentationAttempt,
           await runner.acceptsEventTrigger(event) {
          await recordJourneyMatch(
            presentationAttempt,
            journey: journey,
            persist: true
          )
        }
        let outcome = await runner.dispatchEventTrigger(event)
        await handleOutcome(outcome, journey: journey)
      }
    }
  }

  private func closeSourceJourneyBeforeScopedGateExperienceIfNeeded(
    journey: Journey?,
    experience: Experience?
  ) async {
    guard let journey else { return }
    let state = await journey.snapshot()
    guard state.status.isLive else { return }
    guard await experiencePresentationService.presentedJourneyId == journey.id else { return }

    let closeReason: CloseReason = state.convertedAt != nil ? .goalMet : .userDismissed
    if let controller = await experienceRunners[journey.id]?.viewController {
      await controller.prepareForDismissal(reason: closeReason)
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
    let initialState = await journey.snapshot()
    guard !initialState.isGhost else { return }
    guard initialState.convertedAt == nil else { return }
    guard initialState.goalSnapshot != nil else { return }

    let result = await goalEvaluator.isGoalMet(
      journey: initialState,
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
      let now = dateProvider.now()
      let convertedState = await journey.update { state in
        state.convertedAt = at
        state.setContext("_conversion_source_fact_ref", value: sourceFactRef, at: now)
        state.updatedAt = now
        return state
      }
      persistJourney(convertedState)

      do {
        _ = try await eventLog.trackWithResponse(
          JourneyEvents.journeyConverted,
          properties: JourneyEvents.journeyConvertedProperties(
            journey: convertedState,
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
    properties: sending [String: Any],
    persistToHistory: Bool = false
  ) async -> (tracked: NuxieEvent, response: EventResponse?) {
    do {
      let tracked = try await eventLog.trackForTrigger(
        stage.localEvent.name,
        properties: properties,
        userProperties: nil,
        userPropertiesSetOnce: nil,
        persistToHistory: persistToHistory,
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
      presentationAttempt: nil
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
    let state = await journey.snapshot()
    let mode = state.exitPolicySnapshot?.mode ?? .never

    if (mode == .onGoal || mode == .onGoalOrStop), state.convertedAt != nil {
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
    let state = await journey.snapshot()
    guard state.status.isLive, state.convertedAt != nil else {
      return false
    }
    guard await shouldDeferExitDecision(for: journey) else {
      return false
    }
    return await exitDecision(journey) == .goalMet
  }

  // MARK: - Reentry Policy

  private func suppressionReason(experience: Experience, distinctId: String) async -> SuppressReason? {
    var hasLiveJourney = false
    for journey in inMemoryJourneysById.values
      where journey.distinctId == distinctId && journey.experienceId == experience.id {
      if (await journey.snapshot()).status.isLive {
        hasLiveJourney = true
        break
      }
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
    let references = await profileService.getEffectiveExperienceReferences(
      distinctId: identityService.getDistinctId()
    ) ?? []
    return await loadAuthenticatedExperience(
      references.first { $0.experienceId == id }
    )
  }

  private func getExperience(id: String, for distinctId: String) async -> Experience? {
    let references = await profileService.getEffectiveExperienceReferences(
      distinctId: distinctId
    ) ?? []
    return await loadAuthenticatedExperience(
      references.first { $0.experienceId == id }
    )
  }

  private func getExperience(
    id: String,
    versionId: String,
    for distinctId: String
  ) async -> Experience? {
    let references = await profileService.getEffectiveExperienceReferences(
      distinctId: distinctId
    ) ?? []
    return await loadAuthenticatedExperience(
      references.first { $0.experienceId == id && $0.versionId == versionId }
    )
  }

  private func getAllExperiences() async -> [Experience]? {
    guard let references = await profileService.getEffectiveExperienceReferences(
      distinctId: identityService.getDistinctId()
    ) else { return nil }
    var experiences: [Experience] = []
    for reference in references {
      if let experience = await loadAuthenticatedExperience(reference) {
        experiences.append(experience)
      }
    }
    return experiences
  }

  private func getAllExperiences(
    for distinctId: String,
    presentationTraceContext: ExperiencePresentationTraceContext? = nil
  ) async -> [Experience]? {
    guard let references = await profileService.getEffectiveExperienceReferences(
      distinctId: distinctId
    ) else { return nil }
    var experiences: [Experience] = []
    for reference in references {
      if let experience = await loadAuthenticatedExperience(
        reference,
        presentationTraceContext: presentationTraceContext
      ) {
        experiences.append(experience)
      }
    }
    return experiences
  }

  private func loadAuthenticatedExperience(
    _ reference: ExperienceReference?,
    presentationTraceContext: ExperiencePresentationTraceContext? = nil
  ) async -> Experience? {
    guard let reference else { return nil }
    do {
      return try await experienceService.experienceForJourneyControl(
        experienceId: reference.experienceId,
        versionId: reference.versionId
      )
    } catch {
      LogWarning(
        "JourneyService: refusing experience \(reference.versionId) because its package failed to load: \(error)"
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

extension JourneyService: PresentationAttemptJourneyRouting {
  func handleEventForTrigger(
    _ event: NuxieEvent,
    presentationAttempt: ExperiencePresentationAttempt?
  ) async -> [JourneyTriggerResult] {
    await routeEvent(event, presentationAttempt: presentationAttempt)
  }
}
