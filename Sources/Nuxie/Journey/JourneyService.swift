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

  /// Route a previously captured stable event exactly once locally. Ordinary
  /// trigger events remain transient and do not need a durable receipt.
  /// Returns nil when routing cannot run yet (for example, before the profile
  /// catalog is available). Callers must retain their durable recovery source
  /// and retry rather than acknowledging local completion.
  func handleCapturedEventForTrigger(_ event: NuxieEvent) async -> [JourneyTriggerResult]?

  /// Record the customer that owns a detached (journey-less) presentation so
  /// identity changes can tear it down; every detached presentation caller
  /// must register before presenting.
  func registerDetachedPresentationOwner(distinctId: String) async

  func getActiveJourneys(for distinctId: String) async -> [Journey]

  /// Resolve identity already held by a live or ghost journey for forwarding
  /// a server fact whose wire payload carries only the journey id.
  func forwardingExperienceRef(for journeyId: String) async -> ExperienceRef?

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

  func forwardingExperienceRef(for journeyId: String) async -> ExperienceRef? { nil }

  func handleCapturedEventForTrigger(
    _ event: NuxieEvent
  ) async -> [JourneyTriggerResult]? {
    await handleEventForTrigger(event)
  }

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

  private struct ScreenControlRuntime: Sendable {
    let definition: ExperienceDefinition
    let dispatcher: ScreenEmissionDispatcher
    let router: ScreenEmissionRouter
    let operationGate: ExperienceInteractiveOperationGate
  }

  private struct PendingScreenEvent: Sendable {
    let journeyId: String
    let event: NuxieEvent
    let commit: PreparedTriggerCommit
    let excludedExperienceId: String?
  }

  private enum ScreenAuthoredEventRoutingClaim: Equatable {
    case claimed
    case notClaimable
    case persistenceFailed
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
  private let appActionHandler: @MainActor @Sendable (AppAction) -> Void
  private let presentationTrace: ExperiencePresentationTraceRecording
  private let restoredPresentationAttempt: ExperiencePresentationAttempt?

  // MARK: - State

  private var inMemoryJourneysById: [String: Journey] = [:]
  private var experienceRunners: [String: JourneyRunner] = [:]
  private var screenControlRuntimes: [String: ScreenControlRuntime] = [:]
  private var pendingScreenEvents: [String: PendingScreenEvent] = [:]
  private var runtimeDelegates: [String: JourneyRendererBridge] = [:]
  private var presentationTraceStates: [String: JourneyPresentationTraceState] = [:]
  private var detachedPresentationOwnerDistinctId: String?
  private let timerScheduler: JourneyTimerScheduler
  private var completingJourneyIds: Set<String> = []
  private var journeyCompletionWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
  /// A failed terminal write may leave an already-admitted host dismissal
  /// retryable after identity has changed. Authorization is bound to the exact
  /// retained Journey object so a replacement run can never inherit it.
  private var hostDismissalRetryAuthorizations: [String: Journey] = [:]
  private var claimingJourneyIds: Set<String> = []
  private var admissionsInProgress: Set<AdmissionKey> = []
  private var restoredPresentationRetriesInProgress: Set<String> = []
  private var scopedAuthoredResponseTasks: [UUID: Task<Void, Never>] = [:]
  private var scopedAuthoredResponseOwners: [UUID: String] = [:]
  private var retiringResponseDistinctIds: Set<String> = []
  private var scopedAuthoredResponseTail: (id: UUID, task: Task<Void, Never>)?
  private var scopedAuthoredOutcomeDepth = 0
  private var nextScopedAuthoredResponseToSchedule: UInt64 = 0
  private var pendingScopedAuthoredResponses: [UInt64: PendingScopedAuthoredResponse] = [:]
  private var directlyHandledPreparedResponseSequences: Set<UInt64> = []
  /// Events whose Journey effects were routed but whose exactly-once receipt
  /// could not be persisted. A retry commits only the missing receipt, then
  /// releases the original decisions without replaying Journey effects.
  private var capturedResultsAwaitingReceipt: [String: [JourneyTriggerResult]] = [:]
  private var isShutDown = false
  private var shutdownCompleted = false
  private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []

  var activeRunnerCount: Int { experienceRunners.count }

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
    appActionHandler: @escaping @MainActor @Sendable (AppAction) -> Void = { _ in },
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
    self.appActionHandler = appActionHandler
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
    guard !isShutDown else { return }
    LogInfo("Initializing JourneyService...")

    await profileService.setJourneyMailboxHandler { [weak self] mailbox, distinctId in
      await self?.handleMailbox(mailbox, distinctId: distinctId)
    }
    guard !isShutDown else { return }
    await eventLog.setJourneyOwnershipRejectedHandler {
      [weak self] journeyId, epoch in
      await self?.discardEpochRejectedJourney(
        journeyId: journeyId,
        authoritativeEpoch: epoch
      )
    }
    guard !isShutDown else { return }
    await eventLog.setJourneyHandoffDeliveredHandler {
      [weak self] journeyId in
      await self?.handleJourneyHandoffDelivered(journeyId: journeyId)
    }
    guard !isShutDown else { return }

    let persisted = journeyStore.loadActiveJourneys()
    let livePersisted = persisted.filter {
      $0.status.isLive && !$0.pendingHostExitCapture
    }

    var restoredJourneyCount = 0
    for persistedSnapshot in livePersisted {
      guard await canUsePersistedJourney(persistedSnapshot) else { continue }
      guard !isShutDown else { return }
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
      restoredJourneyCount += 1
    }
    LogInfo("Restored \(restoredJourneyCount) active journeys")

    // Publish live snapshots before terminal recovery yields into EventLog.
    // An identify/reset racing a blocked recovery can then see and quarantine
    // every old-user journey instead of having initialize resurrect it later.
    await retryPendingHostExitCaptures(in: persisted)
    guard !isShutDown else { return }

    if let profile = await profileService.getCachedProfile(
      distinctId: identityService.getDistinctId()
    ), let mailbox = profile.mailbox {
      await handleMailbox(mailbox, distinctId: identityService.getDistinctId())
    }

    guard !isShutDown else { return }
    await checkExpiredTimers()
    guard !isShutDown else { return }
    await retryRestoredPresentations()
  }

  /// Rebuilds presentation runners for live journeys whose durable screen
  /// commit survived a process death. Startup profile admission and journey
  /// restoration run concurrently, so both sides call this convergent retry:
  /// whichever finishes second finds both authorities ready and resumes the
  /// exact signed release/screen without requiring another customer event.
  func retryRestoredPresentations() async {
    guard !isShutDown else { return }
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
    guard !isShutDown,
          identityService.getDistinctId() == activeDistinctId else { return }
    await retryRestoredPresentations(using: experiences, distinctId: activeDistinctId)
  }

  private func retryRestoredPresentations(
    using experiences: [Experience],
    distinctId: String
  ) async {
    let journeys = Array(inMemoryJourneysById.values)
    for journey in journeys {
      let state = await journey.snapshot()
      guard !isShutDown,
            identityService.getDistinctId() == distinctId,
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
        guard !isShutDown else { return }
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
    guard !isShutDown else { return }
    await retryPendingHostExitCaptures()
    guard !isShutDown else { return }
    await checkExpiredTimers()
    guard !isShutDown else { return }

    let now = dateProvider.now()
    for journey in inMemoryJourneysById.values {
      let state = await journey.snapshot()
      guard !isShutDown else { return }
      guard state.status.isLive else { continue }
      if let pending = state.executionState.pendingAction,
         let resumeAt = pending.resumeAt,
         resumeAt > now {
        scheduleResume(journeyId: journey.id, at: resumeAt)
      }
    }
  }

  public func onAppBecameActive() async {
    guard !isShutDown else { return }
    await retryPendingHostExitCaptures()
    guard !isShutDown else { return }
    await experiencePresentationService.onAppBecameActive()
    guard !isShutDown else { return }
    await retryRestoredPresentations()
  }

  public func onAppDidEnterBackground() async {
    guard !isShutDown else { return }
    await timerScheduler.cancelAll()
    guard !isShutDown else { return }
    await experiencePresentationService.onAppDidEnterBackground()
    guard !isShutDown else { return }

    for journey in inMemoryJourneysById.values {
      guard await ownsExecutableJourney(journey) else { continue }
      let state = await journey.snapshot()
      guard await ownsExecutableJourney(journey),
            state.status.isLive,
            persistJourney(state) else { continue }
      enqueueParking(state, reason: .background)
    }

    LogInfo("JourneyService background snapshot complete")
  }

  public func shutdown() async {
    if isShutDown {
      guard !shutdownCompleted else { return }
      await withCheckedContinuation { shutdownWaiters.append($0) }
      return
    }
    isShutDown = true
    admissionsInProgress.removeAll()

    // Stop mailbox admissions before any teardown phase yields. This also
    // disconnects EventLog's mailbox-pending refresh path in ProfileService.
    await profileService.setJourneyMailboxHandler(nil)

    // Cancel deliveries before presentation or runner teardown. Joining a
    // scoped response wrapper can block on its EventLog delivery future, so
    // release those futures before waiting for the wrappers.
    await eventLog.cancelPreparedResponseDeliveries(for: nil)
    let responseTasks = Array(scopedAuthoredResponseTasks.values)
    responseTasks.forEach { $0.cancel() }
    for task in responseTasks { await task.value }

    await shutdownPresentedExperience()

    let runners = Array(experienceRunners.values)
    experienceRunners.removeAll()
    for runner in runners { await runner.retire() }

    await timerScheduler.cancelAll()
    let completionWaiters = journeyCompletionWaiters.values.flatMap { $0 }
    journeyCompletionWaiters.removeAll()
    completionWaiters.forEach { $0.resume() }
    scopedAuthoredResponseTasks.removeAll()
    scopedAuthoredResponseOwners.removeAll()
    retiringResponseDistinctIds.removeAll()
    scopedAuthoredResponseTail = nil
    pendingScopedAuthoredResponses.removeAll()
    directlyHandledPreparedResponseSequences.removeAll()
    hostDismissalRetryAuthorizations.removeAll()
    screenControlRuntimes.removeAll()
    pendingScreenEvents.removeAll()
    runtimeDelegates.removeAll()
    presentationTraceStates.removeAll()
    completingJourneyIds.removeAll()
    claimingJourneyIds.removeAll()
    restoredPresentationRetriesInProgress.removeAll()
    capturedResultsAwaitingReceipt.removeAll()
    inMemoryJourneysById.removeAll()
    shutdownCompleted = true
    let waiters = shutdownWaiters
    shutdownWaiters.removeAll()
    waiters.forEach { $0.resume() }
  }

  public func handleUserChange(from oldDistinctId: String, to newDistinctId: String) async {
    guard !isShutDown else { return }
    LogInfo("JourneyService handling user change from \(NuxieLogger.shared.logDistinctID(oldDistinctId)) to \(NuxieLogger.shared.logDistinctID(newDistinctId))")
    retiringResponseDistinctIds.insert(oldDistinctId)
    defer { retiringResponseDistinctIds.remove(oldDistinctId) }

    await cancelOldCustomerResponseWork(oldDistinctId: oldDistinctId)
    guard !isShutDown else { return }

    let oldCustomerJourneyIds = Set(
      inMemoryJourneysById.values
        .filter { $0.distinctId == oldDistinctId }
        .map(\.id)
    )
    let oldJourneys = await getActiveJourneys(for: oldDistinctId)
    guard !isShutDown else { return }
    // Presentation owns MainActor cleanup that must settle before the old
    // customer's runners can be retired and terminal facts can be emitted.
    await shutdownPresentedExperience(
      ownedBy: oldCustomerJourneyIds,
      detachedOwnerDistinctId: oldDistinctId
    )
    guard !isShutDown else { return }

    for journey in oldJourneys {
      await teardownOldCustomerJourney(journey)
      guard !isShutDown else { return }
    }

    // Only admit persisted work after every old-customer presentation,
    // runner, timer, and terminal fact has settled.

    let persisted = journeyStore.loadActiveJourneys()
      .filter { $0.distinctId == newDistinctId && $0.status.isLive }

    for snapshot in persisted {
      guard await canUsePersistedJourney(snapshot) else { continue }
      guard !isShutDown else { return }

      // A failed host terminalization deliberately retains the exact journey
      // and runner while the user is away. Reuse that object when the same
      // identity returns; replacing only the journey dictionary entry would
      // split mutations between the new object and the runner's old object.
      if let retained = inMemoryJourneysById[snapshot.id] {
        let retainedState = await retained.snapshot()
        guard !isShutDown,
              inMemoryJourneysById[snapshot.id] === retained,
              retained.distinctId == newDistinctId,
              retainedState.status.isLive else {
          LogWarning(
            "JourneyService: refused to replace retained journey \(snapshot.id) during identity restore"
          )
          continue
        }
        if let pending = retainedState.executionState.pendingAction,
           let resumeAt = pending.resumeAt {
          scheduleResume(journeyId: retained.id, at: resumeAt)
        }
        continue
      }

      restorePersistedJourney(Journey(snapshot: snapshot), state: snapshot)
    }

    guard !isShutDown else { return }
    await checkExpiredTimers()
    guard !isShutDown else { return }
    await retryRestoredPresentations()
  }

  // MARK: - Public API

  public func startJourney(
    for experience: Experience,
    distinctId: String,
    originEventId: String? = nil
  ) async -> Journey? {
    guard !isShutDown else { return nil }
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
    guard !isShutDown else { return nil }
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

    guard !isShutDown else { return nil }
    inMemoryJourneysById[journey.id] = journey

    let enrollmentState = await journey.snapshot()
    do {
      _ = try await eventLog.trackWithResponse(
        JourneyEvents.journeyEnrolled,
        properties: JourneyEvents.journeyEnrolledProperties(
          journey: enrollmentState,
          experience: experience,
          triggerRef: originEventId ?? "device:\(journey.id)"
        ),
        flushStrategy: .eventLog,
        distinctIdOverride: enrollmentState.distinctId
      )
    } catch {
      LogWarning("JourneyService: Failed to persist journey enrollment: \(error)")
      guard !isShutDown else { return nil }
      await journey.cancel(at: dateProvider.now())
      guard !isShutDown,
            inMemoryJourneysById[journey.id] === journey else { return nil }
      inMemoryJourneysById.removeValue(forKey: journey.id)
      return nil
    }
    guard !isShutDown,
          inMemoryJourneysById[journey.id] === journey else {
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
    let admittedState = await journey.snapshot()
    guard await ownsExecutableJourney(journey) else { return nil }
    persistJourney(admittedState)

    return journey
  }

  public func resumeJourney(_ journey: Journey) async {
    guard !isShutDown else { return }
    let state = await journey.snapshot()
    guard inMemoryJourneysById[journey.id] === journey,
          journey.distinctId == identityService.getDistinctId(),
          state.status == .paused || state.status == .active else { return }

    guard let experience = await getExperience(
      id: journey.experienceId,
      versionId: journey.experienceVersion,
      for: journey.distinctId
    ) else {
      await cancelJourney(journey)
      return
    }

    guard await ownsExecutableJourney(journey) else { return }

    guard let runner = await ensureRunner(
      for: journey,
      experience: experience,
      stimulus: .restoration
    ) else {
      await completeJourney(journey, reason: .error)
      return
    }

    guard await ownsExecutableJourney(journey),
          experienceRunners[journey.id] === runner else { return }
    await journey.resume(at: dateProvider.now())
    guard await ownsExecutableJourney(journey, runner: runner) else { return }

    let outcome = await runner.resumePendingAction(reason: .timer, event: nil)
    guard await ownsExecutableJourney(journey, runner: runner) else { return }
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
    return await routeEvent(event, presentationAttempt: nil) ?? []
  }

  public func handleCapturedEventForTrigger(
    _ event: NuxieEvent
  ) async -> [JourneyTriggerResult]? {
    await routeEvent(
      event,
      presentationAttempt: nil,
      requiresDurableReceipt: true
    )
  }

  private func routeEvent(
    _ event: NuxieEvent,
    presentationAttempt: ExperiencePresentationAttempt?,
    requiresDurableReceipt: Bool = false
  ) async -> [JourneyTriggerResult]? {
    guard !isShutDown else { return [] }
    if requiresDurableReceipt,
       let routedResults = capturedResultsAwaitingReceipt[event.id] {
      do {
        try journeyStore.recordHandledEvent(
          id: event.id,
          handledAt: dateProvider.now()
        )
        capturedResultsAwaitingReceipt.removeValue(forKey: event.id)
        return routedResults
      } catch {
        LogError("JourneyService: failed to retry handled event receipt \(event.id): \(error)")
        return nil
      }
    }
    guard !requiresDurableReceipt || !journeyStore.hasHandledEvent(id: event.id) else {
      LogDebug("JourneyService: skipping already handled event \(event.id)")
      return []
    }
    await applySupersededDownFactIfNeeded(event)
    guard !isShutDown else { return [] }
    await applyConvertedDownFactIfNeeded(event)
    guard !isShutDown else { return [] }
    let traceContext = presentationAttempt.map {
      ExperiencePresentationTraceContext(
        attempt: $0,
        recorder: presentationTrace
      )
    }
    guard let experiences = await getAllExperiences(
      for: event.distinctId,
      presentationTraceContext: traceContext,
      requireCompleteCatalog: requiresDurableReceipt
    ) else { return requiresDurableReceipt ? nil : [] }
    guard !isShutDown else { return [] }
    let results = await startJourneysMatchingEvent(
      event,
      experiences: experiences,
      presentationAttempt: presentationAttempt
    )
    guard !isShutDown else { return [] }
    let startedJourneyIDs = Set(results.compactMap { result -> String? in
      guard case .started(let journey) = result else { return nil }
      return journey.id
    })
    await processActiveJourneys(
      for: event,
      experiences: experiences,
      transientEventsByJourneyId: [:],
      restrictedToJourneyIds: nil,
      skipEventTriggerForJourneyIds: startedJourneyIDs,
      presentationAttempt: presentationAttempt
    )
    guard !isShutDown else { return [] }
    if requiresDurableReceipt {
      do {
        try journeyStore.recordHandledEvent(
          id: event.id,
          handledAt: dateProvider.now()
        )
      } catch {
        LogError("JourneyService: failed to persist handled event \(event.id): \(error)")
        capturedResultsAwaitingReceipt[event.id] = results
        return nil
      }
    }
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
    guard !isShutDown,
          inMemoryJourneysById[journey.id] === journey,
          state.isGhost else { return }
    persistJourney(state)
    LogInfo("Journey \(journey.id) entered ghost play-out after server supersede")
  }

  private func discardEpochRejectedJourney(
    journeyId: String,
    authoritativeEpoch: Int
  ) async {
    guard !isShutDown,
          let journey = inMemoryJourneysById[journeyId] else {
      return
    }
    let state = await journey.snapshot()
    guard !isShutDown,
          inMemoryJourneysById[journeyId] === journey,
          authoritativeEpoch >= state.epoch else { return }
    let warning =
      "JourneyService: discarding epoch-rejected journey \(journeyId); " +
      "device=\(state.epoch), authoritative=\(authoritativeEpoch)"
    LogWarning(.sensitive(warning))
    await discardLocalJourney(
      journey,
      terminalStatus: .superseded,
      authority: .authoritativeOwnershipLoss
    )
  }

  private func handleJourneyHandoffDelivered(journeyId: String) async {
    guard !isShutDown,
          let journey = inMemoryJourneysById[journeyId] else { return }
    await discardLocalJourney(
      journey,
      terminalStatus: .transferred,
      authority: .authoritativeOwnershipLoss
    )
  }

  private func handleMailbox(
    _ mailbox: [JourneyMailboxEntry],
    distinctId: String
  ) async {
    guard !isShutDown else { return }
    let now = dateProvider.now()
    for entry in mailbox {
      guard !isShutDown else { return }
      guard entry.expiresAt > now else { continue }
      guard entry.hasSupportedStateVersion else {
        let error =
          "JourneyService: refusing mailbox claim \(entry.journeyId) " +
          "with unsupported state version \(entry.stateVersion)"
        LogError(.sensitive(error))
        continue
      }
      guard inMemoryJourneysById[entry.journeyId] == nil,
            journeyStore.loadJourney(id: entry.journeyId) == nil,
            claimingJourneyIds.insert(entry.journeyId).inserted else {
        continue
      }
      defer { claimingJourneyIds.remove(entry.journeyId) }
      guard !isShutDown else { return }
      let resolvedExperience = await getExperience(
        id: entry.experienceId,
        versionId: entry.experienceVersion,
        for: distinctId
      )
      guard !isShutDown else { return }
      guard let experience = resolvedExperience else {
        LogWarning(
          "JourneyService: refusing mailbox claim \(entry.journeyId) because pinned experience version is unavailable"
        )
        continue
      }

      let response: EventResponse
      do {
        guard !isShutDown else { return }
        (_, response) = try await eventLog.trackForTrigger(
          JourneyEvents.journeyClaimed,
          properties: JourneyEvents.journeyClaimedProperties(
            journeyId: entry.journeyId,
            epoch: entry.epoch,
            claimant: identityService.getAnonymousId()
          ),
          persistToHistory: true,
          distinctIdOverride: distinctId,
          applyBeforeSend: false
        )
      } catch {
        guard !isShutDown else { return }
        LogWarning("JourneyService: mailbox claim failed for \(entry.journeyId): \(error)")
        continue
      }
      guard !isShutDown else { return }

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
      guard !isShutDown else { return }
      await claimed.applyStateEnvelope(
        entry.envelope,
        epoch: acknowledgement.epoch
      )
      guard !isShutDown else { return }
      let claimedState = await claimed.update { state in
        state.resumePoint = entry.resumePoint
        state.status = state.executionState.pendingAction == nil ? .active : .paused
        return state
      }
      guard !isShutDown else { return }

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
        guard !isShutDown else { return }
        await beginClaimedDeviceRegion(restored, experience: experience)
        guard !isShutDown else { return }
      } else {
        guard !isShutDown else { return }
        _ = await ensureRunner(
          for: restored,
          experience: experience,
          stimulus: .restoration
        )
        guard !isShutDown else { return }
      }
    }
  }

  private func restorePersistedJourney(_ journey: Journey, state: JourneySnapshot) {
    guard !isShutDown else { return }
    inMemoryJourneysById[journey.id] = journey
    if let pending = state.executionState.pendingAction,
       let resumeAt = pending.resumeAt {
      scheduleResume(journeyId: journey.id, at: resumeAt)
    }
  }

  /// A response-side ownership fence is authoritative across process death.
  /// Persisted state is therefore admissible only after EventLog verifies the
  /// exact journey epoch. An unavailable store fails closed for this attempt
  /// but retains the only recovery snapshot; only confirmed ownership loss
  /// authorizes deletion.
  private func canUsePersistedJourney(_ snapshot: JourneySnapshot) async -> Bool {
    let ownership = JourneyEventOwnership(
      journeyId: snapshot.id,
      epoch: snapshot.epoch
    )
    let ownershipState = await eventLog.journeyEventOwnershipState(ownership)
    guard !isShutDown else { return false }
    switch ownershipState {
    case .owned:
      return true
    case .unavailable:
      LogWarning(
        "JourneyService: ownership unavailable for persisted journey \(snapshot.id); retaining it for recovery"
      )
      return false
    case .ownershipLost:
      LogWarning(
        "JourneyService: refusing persisted journey \(snapshot.id) at fenced epoch \(snapshot.epoch)"
      )
      if let retained = inMemoryJourneysById[snapshot.id] {
        if await discardLocalJourney(
          retained,
          terminalStatus: .superseded,
          authority: .authoritativeOwnershipLoss
        ) {
          return false
        }
      }
      guard !isShutDown else { return false }
      if !journeyStore.deleteJourney(id: snapshot.id) {
        LogError(
          "JourneyService: failed to delete quarantined persisted journey \(snapshot.id)"
        )
      }
      return false
    }
  }

  private func beginClaimedDeviceRegion(
    _ journey: Journey,
    experience: Experience
  ) async {
    guard await ownsExecutableJourney(journey) else { return }
    let state = await journey.snapshot()
    guard await ownsExecutableJourney(journey),
          state.executionState.pendingAction == nil,
          let runner = await ensureRunner(
            for: journey,
            experience: experience,
            stimulus: .claimedDeviceRegion
          ) else {
      return
    }
    guard await ownsExecutableJourney(journey, runner: runner) else { return }
    guard let definition = experience.definition,
          let planId = state.executionState.planId,
          let plan = definition.executionPlan(id: planId),
          state.executionState.routeRevisionSHA256 == plan.revisionSHA256,
          let regionId = state.executionState.regionId,
          let region = plan.deviceRegions.first(where: { $0.id == regionId }) else {
      LogWarning(
        "JourneyService: claimed journey \(journey.id) has no matching signed device region"
      )
      return
    }
    let outcome = await runner.advanceClaimedExecutionPlanRegion(plan, region: region)
    guard await ownsExecutableJourney(journey, runner: runner) else { return }
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
    guard await ownsExecutableJourney(journey),
          !(await hasHostDismissalPriority(journey)) else {
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
    guard !isShutDown,
          inMemoryJourneysById[journey.id] === journey else { return }
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
    guard !isShutDown else { return [] }
    var result: [Journey] = []
    for journey in inMemoryJourneysById.values where journey.distinctId == distinctId {
      let state = await journey.snapshot()
      guard !isShutDown else { return [] }
      if state.status.isLive { result.append(journey) }
    }
    return result
  }

  func forwardingExperienceRef(for journeyId: String) async -> ExperienceRef? {
    let state: JourneySnapshot
    if let journey = inMemoryJourneysById[journeyId] {
      state = await journey.snapshot()
    } else if let stored = journeyStore.loadJourney(id: journeyId) {
      state = stored
    } else {
      return nil
    }
    return ExperienceRef(
      experienceId: state.experienceId,
      experienceVersion: state.experienceVersion,
      journeyId: state.id
    )
  }

  public func checkExpiredTimers() async {
    guard !isShutDown else { return }
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
          let runner = experienceRunners[journeyId],
          await ownsExecutableJourney(journey, runner: runner) else { return false }
    let attachedController = await runner.viewController
    guard await ownsExecutableJourney(journey, runner: runner) else { return false }
    if let attachedController {
      guard attachedController === controller else { return false }
    } else {
      await runner.attach(viewController: controller)
      guard await ownsExecutableJourney(journey, runner: runner) else { return false }
    }
    let state = await journey.snapshot()
    guard await ownsExecutableJourney(journey, runner: runner) else { return false }
    if let pending = state.executionState.pendingPresentation,
       !(await experienceService.validatesPresentationCommit(pending)) {
      guard await ownsExecutableJourney(journey, runner: runner) else { return false }
      await retireStalePresentation(journey: journey, commit: pending)
      return false
    }
    guard await ownsExecutableJourney(journey, runner: runner) else { return false }
    let committed = await runner.commitRendererAttachment()
    guard await ownsExecutableJourney(journey, runner: runner) else { return false }
    let stillAuthoritative: Bool
    if let pending = state.executionState.pendingPresentation {
      stillAuthoritative = await experienceService.validatesPresentationCommit(pending)
    } else {
      stillAuthoritative = true
    }
    guard await ownsExecutableJourney(journey, runner: runner) else { return false }
    if !committed || !stillAuthoritative {
      if !stillAuthoritative,
         let pending = state.executionState.pendingPresentation {
        await retireStalePresentation(journey: journey, commit: pending)
      }
      return false
    }
    return true
  }

  func handleWillDispatchInitialScreenLifecycle(
    journeyId: String,
    controller: ExperienceViewController,
    screenId: String
  ) async -> Bool {
    guard let journey = inMemoryJourneysById[journeyId],
          let runner = experienceRunners[journeyId],
          await ownsExecutableJourney(journey, runner: runner) else { return false }
    guard await runner.viewController === controller,
          await ownsExecutableJourney(journey, runner: runner),
          await runner.isRuntimeReady,
          await ownsExecutableJourney(journey, runner: runner) else { return false }
    let state = await journey.snapshot()
    guard await ownsExecutableJourney(journey, runner: runner),
          state.status.isLive,
          state.executionState.currentScreenId == screenId else { return false }

    await resumePendingScreenEvents(journeyId: journeyId)
    guard await ownsExecutableJourney(journey, runner: runner) else { return false }
    await resumePendingScreenBatches(journeyId: journeyId)

    guard await ownsExecutableJourney(journey, runner: runner),
          await runner.viewController === controller,
          await ownsExecutableJourney(journey, runner: runner),
          await runner.isRuntimeReady,
          await ownsExecutableJourney(journey, runner: runner) else { return false }
    return true
  }

  func handleRuntimeReady(
    journeyId: String,
    controller: ExperienceViewController
  ) async {
    guard let journey = inMemoryJourneysById[journeyId],
          let runner = experienceRunners[journeyId],
          await ownsExecutableJourney(journey, runner: runner) else { return }
    guard await runner.viewController === controller,
          await ownsExecutableJourney(journey, runner: runner) else { return }

    let outcome = await runner.handleRuntimeReady()
    guard await ownsExecutableJourney(journey, runner: runner) else { return }
    await handleOutcome(outcome, journey: journey)
  }

  func handleRuntimeProductsUnavailable(
    journeyId: String,
    screenId: String
  ) async {
    guard let journey = inMemoryJourneysById[journeyId],
          let runner = experienceRunners[journeyId],
          await ownsExecutableJourney(journey, runner: runner) else { return }

    LogWarning(
      "JourneyService: live products unavailable for screen \(screenId) in journey \(journeyId)"
    )
    let outcome = await runner.handleRuntimeProductsUnavailable()
    guard await ownsExecutableJourney(journey, runner: runner) else { return }
    await handleOutcome(outcome, journey: journey)
  }

  func handlePresentationTraceStage(
    journeyId: String,
    presentationToken: UUID,
    stage: ExperiencePresentationTraceStage,
    timestamp: ExperiencePresentationTimestamp
  ) {
    guard !isShutDown,
          var state = presentationTraceStates[journeyId],
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
  ) async -> Bool {
    guard let journey = inMemoryJourneysById[journeyId],
          let runner = experienceRunners[journeyId],
          await ownsExecutableJourney(journey, runner: runner) else { return false }

    let previousState = await journey.snapshot()
    guard await ownsExecutableJourney(journey, runner: runner) else { return false }
    let previousScreenId = previousState.executionState.currentScreenId
    let outcome = await runner.handleScreenChanged(screenId)
    guard await ownsExecutableJourney(journey, runner: runner) else { return false }
    await handleOutcome(outcome, journey: journey)
    guard await ownsExecutableJourney(journey, runner: runner) else { return false }
    var state = await journey.snapshot()
    guard await ownsExecutableJourney(journey, runner: runner) else { return false }
    let persistedTransition = persistJourney(state)

    if !state.isGhost,
       JourneyTransitionAnalytics.shouldTrack(from: previousScreenId, to: screenId) {
      do {
        _ = try await eventLog.trackWithResponse(
          JourneyEvents.journeyTransition,
          properties: JourneyEvents.journeyTransitionProperties(
            journey: state,
            fromNode: previousScreenId,
            toNode: screenId
          ),
          flushStrategy: .eventLog,
          distinctIdOverride: state.distinctId
        )
      } catch {
        LogWarning("JourneyService: Failed to persist transition to \(screenId): \(error)")
      }
      guard await ownsExecutableJourney(journey, runner: runner) else { return false }
    }
    state = await journey.snapshot()
    guard await ownsExecutableJourney(journey, runner: runner) else { return false }
    return persistedTransition && persistJourney(state)
  }

  func handleRendererScreenDismissed(
    journeyId: String,
    screenId: String,
    revealingScreenId: String?,
    method: String
  ) async -> Bool {
    guard let journey = inMemoryJourneysById[journeyId] else { return false }

    if method == ExperienceScreenDismissalMethod.host {
      // Host intent was reserved before screen teardown began. Keep this
      // callback lifecycle-only so the reservation spans through the final
      // runtime host-dismiss callback, which owns terminalization.
      return true
    }

    guard let runner = experienceRunners[journeyId],
          await ownsExecutableJourney(journey, runner: runner) else { return false }

    let outcome = await runner.handleScreenDismissed(
      screenId,
      revealingScreenId: revealingScreenId,
      method: method
    )
    guard await ownsExecutableJourney(journey, runner: runner) else { return false }
    await handleOutcome(outcome, journey: journey)
    guard await ownsExecutableJourney(journey, runner: runner) else { return false }
    var state = await journey.snapshot()
    guard await ownsExecutableJourney(journey, runner: runner) else { return false }
    let persistedTransition = persistJourney(state)

    if let revealingScreenId, !state.isGhost {
      do {
        _ = try await eventLog.trackWithResponse(
          JourneyEvents.journeyTransition,
          properties: JourneyEvents.journeyTransitionProperties(
            journey: state,
            fromNode: screenId,
            toNode: revealingScreenId
          ),
          flushStrategy: .eventLog,
          distinctIdOverride: state.distinctId
        )
      } catch {
        LogWarning("JourneyService: Failed to persist transition to \(revealingScreenId): \(error)")
      }
      guard await ownsExecutableJourney(journey, runner: runner) else { return false }
      state = await journey.snapshot()
      guard await ownsExecutableJourney(journey, runner: runner) else { return false }
      return persistedTransition && persistJourney(state)
    }
    return persistedTransition
  }

  func handleRendererViewModelChange(
    journeyId: String,
    change: ExperienceRendererViewModelChange
  ) async {
    guard let journey = inMemoryJourneysById[journeyId],
          let runner = experienceRunners[journeyId],
          await ownsExecutableJourney(journey, runner: runner) else { return }

    let state = await journey.snapshot()
    guard await ownsExecutableJourney(journey, runner: runner) else { return }
    let outcome = await runner.handleDidSet(
      path: change.path,
      value: change.value,
      source: change.source,
      screenId: change.screenId ?? state.executionState.currentScreenId,
      instanceId: change.instanceId,
      isTrigger: change.isTrigger
    )
    guard await ownsExecutableJourney(journey, runner: runner) else { return }
    await handleOutcome(outcome, journey: journey)
    guard await ownsExecutableJourney(journey, runner: runner) else { return }
    let updatedState = await journey.snapshot()
    guard await ownsExecutableJourney(journey, runner: runner) else { return }
    persistJourney(updatedState)
  }

  func handleRendererEvent(
    journeyId: String,
    event rendererEvent: ExperienceRendererEvent
  ) async {
    guard !rendererEvent.name.isEmpty else { return }
    guard let journey = inMemoryJourneysById[journeyId],
          let runner = experienceRunners[journeyId],
          await ownsExecutableJourney(journey, runner: runner) else { return }

    let eventProperties = await eventLog.prepareTriggerProperties(
      rendererEvent.properties
    )
    guard await ownsExecutableJourney(journey, runner: runner) else { return }
    let event = NuxieEvent(
      name: rendererEvent.name,
      distinctId: journey.distinctId,
      properties: eventProperties
    )
    let state = await journey.snapshot()
    guard await ownsExecutableJourney(journey, runner: runner) else { return }
    let outcome = await runner.dispatchScreenEvent(
      event,
      screenId: rendererEvent.screenId ?? state.executionState.currentScreenId,
      componentId: rendererEvent.componentId,
      instanceId: rendererEvent.instanceId
    )
    guard await ownsExecutableJourney(journey, runner: runner) else { return }
    await handleOutcome(outcome, journey: journey)
    guard await ownsExecutableJourney(journey, runner: runner) else { return }
    let updatedState = await journey.snapshot()
    guard await ownsExecutableJourney(journey, runner: runner) else { return }
    persistJourney(updatedState)

    let routedEvent: NuxieEvent
    let response: EventResponse?
    do {
      let tracked = try await eventLog.trackForTrigger(
        rendererEvent.name,
        properties: rendererEvent.properties,
        persistToHistory: true,
        distinctIdOverride: journey.distinctId,
        applyBeforeSend: false
      )
      routedEvent = tracked.0
      response = tracked.1
    } catch {
      LogWarning("JourneyService: Failed to track renderer event \(rendererEvent.name): \(error)")
      routedEvent = event
      response = nil
    }

    guard await ownsExecutableJourney(journey, runner: runner) else { return }

    let experiences = await getAllExperiences(for: routedEvent.distinctId) ?? []
    guard await ownsExecutableJourney(journey, runner: runner) else { return }
    let sourceExperience = sourceScopedGoalExperience(for: journey, experiences: experiences)
    let transientEvent = makeStoredEvent(from: routedEvent)
    await processActiveJourneys(
      for: routedEvent,
      experiences: experiences,
      transientEventsByJourneyId: [journeyId: [transientEvent]],
      restrictedToJourneyIds: [journeyId],
      skipEventTriggerForJourneyIds: [journeyId]
    )
    guard await ownsExecutableJourney(journey, runner: runner) else { return }

    await routeRendererEventOutsideSourceJourney(
      routedEvent,
      sourceJourneyId: journeyId,
      excludedExperienceId: journey.experienceId,
      experiences: experiences
    )
    guard await ownsExecutableJourney(journey, runner: runner) else { return }
    await handleScopedGatePlan(
      response?.gatePlan(),
      sourceJourney: journey,
      sourceExperience: sourceExperience,
      sourceDistinctId: routedEvent.distinctId
    )
  }

  func handleRendererControlAction(
    journeyId: String,
    screenId: String?,
    invocation: ScreenActionInvocation
  ) async {
    guard let scope = await screenControlRunScope(journeyId: journeyId),
          screenId == scope.screenId else { return }
    await handleRendererControlAction(
      journeyId: journeyId,
      scope: scope,
      invocation: invocation
    )
  }

  func handleRendererControlAction(
    journeyId: String,
    scope: ScreenControlRunScope?,
    invocation: ScreenActionInvocation
  ) async {
    guard let runtime = screenControlRuntimes[journeyId] else {
      LogWarning(
        "JourneyService: rejected screen action \(invocation.actionId); no signed Journey canonical runtime for \(journeyId)"
      )
      return
    }
    await runtime.operationGate.withLock { [self] in
      await dispatchRendererControlAction(
        journeyId: journeyId,
        scope: scope,
        invocation: invocation,
        runtime: runtime
      )
    }
  }

  private func dispatchRendererControlAction(
    journeyId: String,
    scope: ScreenControlRunScope?,
    invocation: ScreenActionInvocation,
    runtime: ScreenControlRuntime
  ) async {
    guard let journey = inMemoryJourneysById[journeyId],
          let runner = experienceRunners[journeyId],
          await ownsExecutableJourney(journey, runner: runner) else { return }
    let state = await journey.snapshot()
    guard await ownsExecutableJourney(journey, runner: runner),
          let scope,
          state.status.isLive, !state.isGhost,
          let activeScreenId = state.executionState.currentScreenId,
          !activeScreenId.isEmpty,
          scope.screenId == activeScreenId,
          scope.executionOwnershipEpoch == UInt64(max(state.epoch, 0)),
          scope.lifecycleGeneration == state.executionState.lifecycleGeneration,
          scope.presentationEpoch == state.executionState.presentationEpoch else {
      LogWarning(
        "JourneyService: rejected screen action \(invocation.actionId) from an inactive screen"
      )
      return
    }
    let resolvedScreenId = activeScreenId
    guard let action = runtime.definition.control(
      screenId: resolvedScreenId,
      actionId: invocation.actionId
    ) else {
      LogWarning(
        "JourneyService: rejected unknown screen action \(invocation.actionId) on \(resolvedScreenId)"
      )
      return
    }

    let result = await runtime.dispatcher.dispatch(
      run: ScreenEmissionRun(
        journeyId: journeyId,
        executionOwnershipEpoch: scope.executionOwnershipEpoch,
        lifecycleGeneration: scope.lifecycleGeneration,
        presentationEpoch: scope.presentationEpoch
      ),
      screenId: resolvedScreenId,
      definition: action,
      invocation: invocation
    )
    guard await ownsExecutableJourney(journey, runner: runner) else { return }
    switch result {
    case .failure(let error):
      LogWarning(
        "JourneyService: screen action \(invocation.actionId) failed on \(resolvedScreenId): \(error)"
      )
    case .success(let batch):
      guard await persistPendingScreenBatch(batch, for: journey) else {
        let rolledBack = await runtime.dispatcher.rollbackUnpublishedBatch(batch)
        LogWarning(
          """
          JourneyService: failed to persist screen action batch \(batch.invocationId); \
          dispatcher rollback=\(rolledBack)
          """
        )
        return
      }
      guard await ownsExecutableJourney(journey, runner: runner) else { return }
      let drain = await runtime.router.drain(batch)
      guard await ownsExecutableJourney(journey, runner: runner) else { return }
      if drain.status != .drained {
        LogWarning(
          "JourneyService: screen action \(invocation.actionId) drain ended with \(drain.status)"
        )
      }
    }
  }

  private func makeScreenEmissionRouter() -> ScreenEmissionRouter {
    ScreenEmissionRouter(ports: ScreenEmissionRouterPorts(
      createCausalityId: { UUID.v7().uuidString },
      readRun: { [weak self] journeyId in
        await self?.screenEventRouterRun(journeyId: journeyId)
      },
      applyResponse: { [weak self] run, source, emission in
        guard let self else { return .rejected(message: "journey service unavailable") }
        return await self.applyScreenResponse(run: run, source: source, emission: emission)
      },
      acceptCustomerEvent: { [weak self] acceptance in
        guard let self else { throw EventRoutingError.eventRoutingFailed }
        return try await self.acceptScreenCustomerEvent(acceptance)
      },
      recoverBatch: { [weak self] batch in
        await self?.recoverScreenBatch(batch) ?? ScreenBatchRecovery(
          lastProcessedSequence: nil,
          result: nil
        )
      },
      recordBatchResult: { [weak self] journeyId, sequence, invocationId, result in
        await self?.recordScreenBatch(
          journeyId: journeyId,
          sequence: sequence,
          invocationId: invocationId,
          result: result
        )
      },
      resolveEffectOutcomeParent: { _, _, _ in nil },
      runRouteToStableBoundary: { [weak self] route, event, _ in
        await self?.runScreenLocalRoute(route, event: event)
      },
      finishSourceEvent: { [weak self] event, _ in
        await self?.finishScreenSourceEvent(event)
      },
      recordDiagnostic: { diagnostic in
        LogWarning(
          "JourneyService: screen emission \(diagnostic.emissionId) rejected: \(diagnostic.message)"
        )
      },
      recordSkippedTail: { tail in
        LogWarning(
          "JourneyService: skipped \(tail.emissionIds.count) screen emissions for \(tail.journeyId): \(tail.reason)"
        )
      }
    ))
  }

  private func screenEventRouterRun(journeyId: String) async -> ScreenEventRouterRun? {
    guard let journey = inMemoryJourneysById[journeyId],
          let runner = experienceRunners[journeyId],
          await ownsExecutableJourney(journey, runner: runner) else { return nil }
    let state = await journey.snapshot()
    guard await ownsExecutableJourney(journey, runner: runner) else { return nil }
    return ScreenEventRouterRun(
      journeyId: journeyId,
      experienceId: journey.experienceId,
      customerId: journey.distinctId,
      executionOwnershipEpoch: UInt64(max(state.epoch, 0)),
      lifecycleGeneration: state.executionState.lifecycleGeneration,
      presentationEpoch: state.executionState.presentationEpoch,
      terminal: !state.status.isLive || state.isGhost,
      causality: ExperienceEventCausality(
        chainId: journeyId,
        parentEventId: nil,
        visitedExperienceIds: [journey.experienceId],
        hopCount: 0
      )
    )
  }

  func screenControlRunScope(journeyId: String) async -> ScreenControlRunScope? {
    guard let journey = inMemoryJourneysById[journeyId],
          let runner = experienceRunners[journeyId],
          await ownsExecutableJourney(journey, runner: runner) else { return nil }
    let state = await journey.snapshot()
    guard await ownsExecutableJourney(journey, runner: runner),
          state.status.isLive, !state.isGhost,
          let screenId = state.executionState.currentScreenId,
          !screenId.isEmpty else { return nil }
    return ScreenControlRunScope(
      screenId: screenId,
      executionOwnershipEpoch: UInt64(max(state.epoch, 0)),
      lifecycleGeneration: state.executionState.lifecycleGeneration,
      presentationEpoch: state.executionState.presentationEpoch
    )
  }

  private func applyScreenResponse(
    run: ScreenEventRouterRun,
    source: ScreenEmissionSource,
    emission: ScreenEmission
  ) async -> ScreenResponseEmissionResult {
    guard let journey = inMemoryJourneysById[run.journeyId],
          let runner = experienceRunners[run.journeyId],
          await ownsExecutableJourney(journey, runner: runner),
          let definition = screenControlRuntimes[run.journeyId]?.definition,
          let schema = definition.responseSchema,
          let field = emission.payload["field"]?.foundationValue as? String,
          !field.isEmpty,
          schema.capturesByScreen[source.screenId]?.contains(field) == true else {
      return .rejected(message: "response field is not captured by the active signed screen")
    }
    if emission.name == SystemEventNames.responseSet,
       emission.payload["value"] == nil {
      return .rejected(message: "response set emission has no value")
    }
    let before = await journey.snapshot()
    guard await ownsExecutableJourney(journey, runner: runner),
          before.status.isLive, !before.isGhost,
          before.executionState.pendingAction == nil else {
      return .rejected(message: "journey cannot accept a response mutation")
    }
    let result = await runner.applyScreenResponseEmission(
      emission,
      screenId: source.screenId,
      field: field
    )
    guard await ownsExecutableJourney(journey, runner: runner) else {
      return .rejected(message: "journey no longer owns renderer execution")
    }
    let updatedState = await journey.snapshot()
    guard await ownsExecutableJourney(journey, runner: runner) else {
      return .rejected(message: "journey no longer owns renderer execution")
    }
    persistJourney(updatedState)
    await completeDeferredDismissIfReady(journeyId: journey.id)
    return result
  }

  private func acceptScreenCustomerEvent(
    _ acceptance: ScreenCustomerEventAcceptance
  ) async throws -> ScreenCustomerEventAdmission {
    guard case .screen(let sourceExperienceId, let sourceJourneyId, _) = acceptance.event.source,
          let journey = inMemoryJourneysById[sourceJourneyId],
          let runner = experienceRunners[sourceJourneyId],
          sourceExperienceId == journey.experienceId,
          acceptance.event.customerId == journey.distinctId,
          await ownsExecutableJourney(journey, runner: runner) else {
      throw EventRoutingError.eventRoutingFailed
    }
    let initial = await journey.snapshot()
    guard await ownsExecutableJourney(journey, runner: runner) else {
      throw EventRoutingError.eventRoutingFailed
    }
    if let record = initial.executionState.screenRouting
      .eventRecords[acceptance.event.id] {
      if (record.phase == .admitted || record.phase == .routeExecuting),
         pendingScreenEvents[acceptance.event.id] == nil,
         let event = restoredScreenEvent(from: record) {
        let commit = await eventLog.commitPreparedTriggerEvent(event)
        guard await ownsExecutableJourney(journey, runner: runner) else {
          throw EventRoutingError.eventRoutingFailed
        }
        pendingScreenEvents[acceptance.event.id] = PendingScreenEvent(
          journeyId: sourceJourneyId,
          event: event,
          commit: commit,
          excludedExperienceId: record.excludedExperienceId
        )
      }
      return ScreenCustomerEventAdmission(
        disposition: .duplicate,
        localRoute: record.phase == .admitted ? record.localRoute : .alreadyProcessed
      )
    }
    if initial.executionState.screenRouting.recentEventIds
      .contains(acceptance.event.id) {
      return ScreenCustomerEventAdmission(
        disposition: .duplicate,
        localRoute: .alreadyProcessed
      )
    }
    let properties = await eventLog.prepareTriggerProperties(
      acceptance.event.payload.mapValues(\.foundationValue)
    )
    guard await ownsExecutableJourney(journey, runner: runner) else {
      throw EventRoutingError.eventRoutingFailed
    }
    let exactEvent = NuxieEvent(
      id: acceptance.event.id,
      name: acceptance.event.name,
      distinctId: acceptance.event.customerId,
      properties: properties,
      timestamp: parseExecutionDate(acceptance.event.occurredAt) ?? dateProvider.now()
    )
    guard let prepared = await eventLog.applyBeforeSend(to: exactEvent) else {
      guard await ownsExecutableJourney(journey, runner: runner) else {
        throw EventRoutingError.eventRoutingFailed
      }
      let persisted = await persistScreenEventRecord(
        JourneyScreenEventRecord(
          sourceEvent: acceptance.event,
          preparedId: nil,
          preparedName: nil,
          preparedDistinctId: nil,
          preparedProperties: nil,
          preparedOccurredAt: nil,
          localRoute: .none,
          excludedExperienceId: acceptance.excludeExperienceId,
          phase: .dropped,
          routeContinuation: nil,
          claimedEffectPaths: [],
          pendingAuthoredEvents: []
        ),
        journey: journey
      )
      guard persisted,
            await ownsExecutableJourney(journey, runner: runner) else {
        throw EventRoutingError.eventRoutingFailed
      }
      return ScreenCustomerEventAdmission(
        disposition: .accepted,
        localRoute: .none
      )
    }
    guard await ownsExecutableJourney(journey, runner: runner) else {
      throw EventRoutingError.eventRoutingFailed
    }

    let localRoute: ScreenLocalRouteDisposition
    if prepared.distinctId == acceptance.event.customerId,
       case .screen(let screenId, _)? = acceptance.localRoute,
       let definition = screenControlRuntimes[sourceJourneyId]?.definition,
       let route = definition.route(host: .screen(screenId), eventName: prepared.name),
       definition.executionPlan(for: route, startPlane: .device) != nil {
      localRoute = .ready(AcceptedScreenLocalRoute(
        admissionId: acceptance.event.id,
        key: .screen(screenId: screenId, eventName: prepared.name),
        routeRevision: route.revisionSHA256
      ))
    } else {
      localRoute = .none
    }
    let record = JourneyScreenEventRecord(
      sourceEvent: acceptance.event,
      preparedId: prepared.id,
      preparedName: prepared.name,
      preparedDistinctId: prepared.distinctId,
      preparedProperties: prepared.properties.mapValues(AnyCodable.init),
      preparedOccurredAt: prepared.timestamp,
      localRoute: localRoute,
      excludedExperienceId: acceptance.excludeExperienceId,
      phase: .admitted,
      routeContinuation: nil,
      claimedEffectPaths: [],
      pendingAuthoredEvents: []
    )
    guard await persistScreenEventRecord(record, journey: journey) else {
      throw EventRoutingError.eventRoutingFailed
    }
    guard await ownsExecutableJourney(journey, runner: runner) else {
      throw EventRoutingError.eventRoutingFailed
    }
    let commit = await eventLog.commitPreparedTriggerEvent(prepared)
    guard await ownsExecutableJourney(journey, runner: runner) else {
      throw EventRoutingError.eventRoutingFailed
    }
    pendingScreenEvents[acceptance.event.id] = PendingScreenEvent(
      journeyId: sourceJourneyId,
      event: prepared,
      commit: commit,
      excludedExperienceId: acceptance.excludeExperienceId
    )
    return ScreenCustomerEventAdmission(
      disposition: .accepted,
      localRoute: localRoute
    )
  }

  private func runScreenLocalRoute(
    _ route: AcceptedScreenLocalRoute,
    event: ScreenCustomerEvent
  ) async {
    guard case .screen(let screenId, _) = route.key,
          case .screen(_, let journeyId, let source) = event.source,
          let pending = pendingScreenEvents[event.id],
          let journey = inMemoryJourneysById[journeyId],
          let runner = experienceRunners[journeyId],
          await ownsExecutableJourney(journey, runner: runner) else { return }
    let outcome = await runner.dispatchAdmittedScreenEvent(
      pending.event,
      screenId: screenId,
      componentId: source.componentId,
      instanceId: source.instanceId,
      admission: route
    )
    guard await ownsExecutableJourney(journey, runner: runner) else { return }
    await handleOutcome(outcome, journey: journey)
    guard await ownsExecutableJourney(journey, runner: runner) else { return }
    let state = await journey.snapshot()
    guard await ownsExecutableJourney(journey, runner: runner),
          state.status.isLive else { return }
    guard persistJourney(state) else { return }
    _ = await updateScreenEventPhase(
      event.id,
      phase: .routeProcessed,
      journey: journey
    )
  }

  private func finishScreenSourceEvent(_ event: ScreenCustomerEvent) async {
    guard case .screen(_, let journeyId, _) = event.source,
          let pending = pendingScreenEvents.removeValue(forKey: event.id) else { return }
    guard pending.journeyId == journeyId,
          pending.event.id == event.id,
          pending.event.distinctId == event.customerId,
          let journey = inMemoryJourneysById[journeyId],
          let runner = experienceRunners[journeyId],
          event.customerId == journey.distinctId,
          await ownsExecutableJourney(journey, runner: runner) else { return }
    let exactEvent = pending.event
    let experiences = await getAllExperiences(for: exactEvent.distinctId) ?? []
    guard await ownsExecutableJourney(journey, runner: runner) else { return }
    let transientEvent = makeStoredEvent(from: exactEvent)
    await processActiveJourneys(
      for: exactEvent,
      experiences: experiences,
      transientEventsByJourneyId: [journeyId: [transientEvent]],
      restrictedToJourneyIds: [journeyId],
      skipEventTriggerForJourneyIds: [journeyId]
    )
    let sourceCompleted = (await journey.snapshot()).status == .completed
    guard await ownsScopedCallbackContinuation(
      journey,
      runner: runner,
      sourceCompleted: sourceCompleted
    ) else { return }
    await routeRendererEventOutsideSourceJourney(
      exactEvent,
      sourceJourneyId: journeyId,
      excludedExperienceId: pending.excludedExperienceId,
      experiences: experiences
    )
    guard await ownsScopedCallbackContinuation(
      journey,
      runner: runner,
      sourceCompleted: sourceCompleted
    ) else { return }
    let response = await pending.commit.response.value
    guard await ownsScopedCallbackContinuation(
      journey,
      runner: runner,
      sourceCompleted: sourceCompleted
    ) else { return }
    await handleScopedGatePlan(
      response.gatePlan(),
      sourceJourney: sourceCompleted ? nil : journey,
      sourceExperience: sourceCompleted
        ? nil
        : sourceScopedGoalExperience(for: journey, experiences: experiences),
      sourceDistinctId: exactEvent.distinctId
    )
    markPreparedResponseSequenceHandledDirectly(pending.commit.sequence)
    _ = await updateScreenEventPhase(
      event.id,
      phase: .finished,
      journey: journey
    )
  }

  private func recoverScreenBatch(_ batch: ScreenEmissionBatch) async -> ScreenBatchRecovery {
    guard let journey = inMemoryJourneysById[batch.journeyId] else {
      return ScreenBatchRecovery(lastProcessedSequence: nil, result: nil)
    }
    let routing = (await journey.snapshot()).executionState.screenRouting
    let result = routing.batchReceipts[String(batch.batchSequence)].flatMap { receipt in
      receipt.invocationId == batch.invocationId ? receipt.result : nil
    }
    return ScreenBatchRecovery(
      lastProcessedSequence: routing.lastProcessedBatchSequence,
      result: result
    )
  }

  private func recordScreenBatch(
    journeyId: String,
    sequence: UInt64,
    invocationId: String,
    result: ScreenEventRouterDrainResult
  ) async {
    guard let journey = inMemoryJourneysById[journeyId] else { return }
    let state = await journey.snapshot()
    let retainedAdmissionIds = retainedScreenRouteAdmissionIds(in: state)
    let key = String(sequence)
    _ = await updateDurableScreenRouting(journey: journey) { routing in
      routing.lastProcessedBatchSequence = max(
        routing.lastProcessedBatchSequence ?? sequence,
        sequence
      )
      routing.batchReceipts[key] = JourneyScreenBatchReceipt(
        invocationId: invocationId,
        result: result
      )
      routing.pendingBatches.removeValue(forKey: key)
      for eventId in result.acceptedEmissionIds {
        if !retainedAdmissionIds.contains(eventId),
           let record = routing.eventRecords[eventId],
           (record.phase == .finished || record.phase == .dropped),
           record.pendingAuthoredEvents.isEmpty,
           record.routeContinuation?.isEmpty != false {
          routing.eventRecords.removeValue(forKey: eventId)
          if !routing.recentEventIds.contains(eventId) {
            routing.recentEventIds.append(eventId)
          }
        }
      }
      if routing.recentEventIds.count > 256 {
        routing.recentEventIds.removeFirst(routing.recentEventIds.count - 256)
      }
      let retainedReceiptKeys = Set(routing.batchReceipts.keys
        .compactMap(UInt64.init)
        .sorted()
        .suffix(64)
        .map(String.init))
      routing.batchReceipts = routing.batchReceipts.filter {
        retainedReceiptKeys.contains($0.key)
      }
    }
  }

  private func removeScreenControlRuntime(journeyId: String) {
    screenControlRuntimes.removeValue(forKey: journeyId)
  }

  private func restoredScreenEvent(from record: JourneyScreenEventRecord) -> NuxieEvent? {
    guard let name = record.preparedName,
          let distinctId = record.preparedDistinctId,
          let properties = record.preparedProperties,
          let occurredAt = record.preparedOccurredAt else { return nil }
    guard let preparedId = record.preparedId else { return nil }
    return NuxieEvent(
      id: preparedId,
      name: name,
      distinctId: distinctId,
      properties: properties.mapValues(\.value),
      timestamp: occurredAt
    )
  }

  private func persistScreenEventRecord(
    _ record: JourneyScreenEventRecord,
    journey: Journey
  ) async -> Bool {
    await updateDurableScreenRouting(journey: journey) { routing in
      routing.eventRecords[record.sourceEvent.id] = record
    }
  }

  private func updateScreenEventPhase(
    _ eventId: String,
    phase: JourneyScreenEventPhase,
    journey: Journey?
  ) async -> Bool {
    guard let journey else { return false }
    return await updateDurableScreenRouting(journey: journey) { routing in
      guard var record = routing.eventRecords[eventId] else { return }
      record.phase = phase
      routing.eventRecords[eventId] = record
    }
  }

  private func persistPendingScreenBatch(
    _ batch: ScreenEmissionBatch,
    for journey: Journey
  ) async -> Bool {
    await updateDurableScreenRouting(journey: journey) { routing in
      routing.pendingBatches[String(batch.batchSequence)] = batch
      routing.nextBatchSequence = max(
        routing.nextBatchSequence,
        batch.batchSequence + 1
      )
      if let last = batch.emissions.last {
        routing.nextEmissionSequence = max(
          routing.nextEmissionSequence,
          last.sequence + 1
        )
      }
    }
  }

  private func updateDurableScreenRouting(
    journey: Journey,
    _ update: (inout JourneyScreenRoutingState) -> Void
  ) async -> Bool {
    guard let runner = experienceRunners[journey.id],
          await ownsExecutableJourney(journey, runner: runner) else { return false }
    for _ in 0..<4 {
      guard await ownsExecutableJourney(journey, runner: runner) else { return false }
      let versioned = await journey.versionedSnapshot()
      guard await ownsExecutableJourney(journey, runner: runner) else { return false }
      var candidate = versioned.snapshot
      update(&candidate.executionState.screenRouting)
      candidate.updatedAt = dateProvider.now()
      guard await journey.replace(candidate, ifRevisionEquals: versioned.revision) else {
        guard await ownsExecutableJourney(journey, runner: runner) else { return false }
        continue
      }
      guard await ownsExecutableJourney(journey, runner: runner) else { return false }
      do {
        try journeyStore.saveJourney(candidate)
      } catch {
        guard await ownsExecutableJourney(journey, runner: runner) else { return false }
        await journey.update { current in
          current.executionState.screenRouting = versioned.snapshot.executionState.screenRouting
        }
        guard await ownsExecutableJourney(journey, runner: runner) else { return false }
        LogWarning(
          "JourneyService: failed to persist screen routing for \(journey.id): \(error)"
        )
        return false
      }
      return true
    }
    LogWarning("JourneyService: screen routing CAS exhausted for \(journey.id)")
    return false
  }

  private func resumePendingScreenBatches(journeyId: String) async {
    guard let journey = inMemoryJourneysById[journeyId],
          let runtime = screenControlRuntimes[journeyId] else { return }
    let routing = (await journey.snapshot()).executionState.screenRouting
    await runtime.dispatcher.restoreProgress(
      journeyId: journeyId,
      nextBatchSequence: routing.nextBatchSequence,
      nextEmissionSequence: routing.nextEmissionSequence
    )
    let batches = routing.pendingBatches.values.sorted {
      $0.batchSequence < $1.batchSequence
    }
    for batch in batches {
      _ = await runtime.router.drain(batch)
    }
  }

  private func resumePendingScreenEvents(journeyId: String) async {
    guard let journey = inMemoryJourneysById[journeyId],
          let runner = experienceRunners[journeyId],
          await ownsExecutableJourney(journey, runner: runner) else { return }
    let records = (await journey.snapshot()).executionState.screenRouting.eventRecords.values
      .filter {
        $0.phase == .admitted || $0.phase == .routeExecuting
          || $0.phase == .routeProcessed || !$0.pendingAuthoredEvents.isEmpty
      }
      .sorted { lhs, rhs in
        let left = lhs.preparedOccurredAt ?? .distantPast
        let right = rhs.preparedOccurredAt ?? .distantPast
        if left != right { return left < right }
        return lhs.sourceEvent.id < rhs.sourceEvent.id
      }
    guard await ownsExecutableJourney(journey, runner: runner) else { return }
    for record in records {
      guard await ownsExecutableJourney(journey, runner: runner) else { return }
      if record.phase == .finished {
        await resumeDurableScreenAuthoredEvents(record, journey: journey)
        guard await ownsExecutableJourney(journey, runner: runner) else { return }
        await cleanupFinishedScreenRouteAdmissions(journey)
        continue
      }
      guard let event = restoredScreenEvent(from: record) else { continue }
      let commit = await eventLog.commitPreparedTriggerEvent(event)
      guard await ownsExecutableJourney(journey, runner: runner) else { return }
      pendingScreenEvents[record.sourceEvent.id] = PendingScreenEvent(
        journeyId: journeyId,
        event: event,
        commit: commit,
        excludedExperienceId: record.excludedExperienceId
      )
      if (record.phase == .admitted || record.phase == .routeExecuting),
         case .ready(let route) = record.localRoute {
        await runScreenLocalRoute(route, event: record.sourceEvent)
        guard await ownsExecutableJourney(journey, runner: runner) else { return }
      }
      let refreshedState = await journey.snapshot()
      guard await ownsExecutableJourney(journey, runner: runner) else { return }
      if let refreshed = refreshedState.executionState.screenRouting
        .eventRecords[record.sourceEvent.id],
        !refreshed.pendingAuthoredEvents.isEmpty {
        await resumeDurableScreenAuthoredEvents(refreshed, journey: journey)
        guard await ownsExecutableJourney(journey, runner: runner) else { return }
      }
      await finishScreenSourceEvent(record.sourceEvent)
    }
  }

  private func routeRendererEventOutsideSourceJourney(
    _ event: NuxieEvent,
    sourceJourneyId: String,
    excludedExperienceId: String?,
    experiences: [Experience]
  ) async {
    let eligibleExperiences = experiences.filter { $0.id != excludedExperienceId }
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
        experiences: eligibleExperiences,
        transientEventsByJourneyId: transientEventsByJourneyId,
        restrictedToJourneyIds: otherActiveJourneyIds
      )
    }

    let results = await startJourneysMatchingEvent(
      event,
      experiences: eligibleExperiences,
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
    guard let journey = inMemoryJourneysById[journeyId],
          let runner = experienceRunners[journeyId],
          await ownsExecutableJourney(journey, runner: runner) else { return }
    await runner.handleRuntimeOpenLink(
      url: request.urlString,
      target: request.target,
      screenId: request.screenId,
      instanceId: request.instanceId
    )
    guard await ownsExecutableJourney(journey, runner: runner) else { return }
  }

  func reserveHostDismissal(journeyId: String) async {
    guard let journey = inMemoryJourneysById[journeyId] else { return }
    let isAuthorizedRetry = hostDismissalRetryAuthorizations[journeyId] === journey
    let isCurrentlyExecutable = isAuthorizedRetry
      ? true
      : await ownsExecutableJourney(journey)
    guard isCurrentlyExecutable,
          await journey.reserveHostDismissal() else { return }

    let reservationRemainsAdmitted: Bool
    if isAuthorizedRetry {
      let state = await journey.snapshot()
      reservationRemainsAdmitted = inMemoryJourneysById[journeyId] === journey
        && state.status.isLive
    } else {
      reservationRemainsAdmitted = await ownsExecutableJourney(journey)
    }
    guard reservationRemainsAdmitted else {
      await journey.releaseHostDismissalReservation()
      return
    }
    hostDismissalRetryAuthorizations.removeValue(forKey: journeyId)
  }

  func handleRuntimeDismiss(
    journeyId: String,
    reason: CloseReason,
    controller: ExperienceViewController
  ) async {
    guard let journey = inMemoryJourneysById[journeyId] else { return }

    if reason == .hostDismissed {
      _ = await handleRuntimeHostDismiss(
        journeyId: journeyId,
        controller: controller
      )
      return
    }

    guard let runner = experienceRunners[journeyId],
          await ownsExecutableJourney(journey, runner: runner),
          await runner.viewController === controller,
          await ownsExecutableJourney(journey, runner: runner) else { return }

    if await journey.hasHostDismissalReservation() {
      return
    }
    guard await ownsExecutableJourney(journey, runner: runner) else { return }

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

    await postDismissNotification(for: journey, reason: reason)
    guard await ownsExecutableJourney(journey, runner: runner) else { return }

    var state = await journey.snapshot()
    guard await ownsExecutableJourney(journey, runner: runner) else { return }

    // A failed response operation deliberately keeps the draft and the live
    // journey available for an explicit retry. Do not turn that recovery path
    // into an abandonment merely because the renderer was dismissed.
    let runnerHasFailedResponseOperation = await runner.hasFailedResponseOperation()
    guard await ownsExecutableJourney(journey, runner: runner) else { return }
    if state.responseSessionRetryRequired || runnerHasFailedResponseOperation {
      if await runner.isSynchronizingResponseFields() {
        guard await ownsExecutableJourney(journey, runner: runner) else { return }
        await runner.deferDismiss(reason: reason)
      }
      return
    }

    state = await journey.snapshot()
    guard await ownsExecutableJourney(journey, runner: runner) else { return }
    if state.status.isLive {
      await evaluateGoalIfNeeded(journey)
      guard await ownsExecutableJourney(journey, runner: runner) else { return }
      if let reason = await exitDecision(journey) {
        guard await ownsExecutableJourney(journey, runner: runner) else { return }
        await completeJourney(journey, reason: reason)
        return
      }
    }

    state = await journey.snapshot()
    guard await ownsExecutableJourney(journey, runner: runner) else { return }
    if state.status.isLive, await runner.hasPendingPermissionWork() {
      guard await ownsExecutableJourney(journey, runner: runner) else { return }
      await runner.deferDismiss(reason: reason)
      return
    }

    guard await ownsExecutableJourney(journey, runner: runner) else { return }
    if (await journey.snapshot()).status.isLive,
       await ownsExecutableJourney(journey, runner: runner) {
      await completeJourney(
        journey,
        reason: dismissalExitReason(for: reason),
        dismissedBy: dismissalSource(for: reason)
      )
    }
  }

  @discardableResult
  func handleRuntimeHostDismiss(
    journeyId: String,
    controller: ExperienceViewController
  ) async -> Bool {
    guard !isShutDown else { return true }
    guard let journey = inMemoryJourneysById[journeyId] else {
      return true
    }
    guard await journey.hasHostDismissalReservation(),
          inMemoryJourneysById[journeyId] === journey else {
      return false
    }
    await completeJourney(
      journey,
      reason: .dismissed,
      dismissedBy: .host
    )
    guard !isShutDown else { return true }
    let terminalized = !(await journey.snapshot()).status.isLive
    guard !isShutDown else { return true }
    if terminalized {
      hostDismissalRetryAuthorizations.removeValue(forKey: journeyId)
    } else if inMemoryJourneysById[journeyId] === journey {
      hostDismissalRetryAuthorizations[journeyId] = journey
    }
    return terminalized
  }

  private func postDismissNotification(
    for journey: Journey,
    reason: CloseReason
  ) async {
    guard inMemoryJourneysById[journey.id] === journey else { return }
    var userInfo: [String: Any] = [
      "journeyId": journey.id,
      "experienceId": journey.experienceId
    ]
    let state = await journey.snapshot()
    guard inMemoryJourneysById[journey.id] === journey else { return }
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
  }

  /// Host dismissal may legitimately finish under the journey's old identity,
  /// so its post-capture checks use exact object ownership rather than the
  /// current-identity execution predicate.
  private func ownsHostCompletion(
    _ journey: Journey,
    runner: JourneyRunner?
  ) -> Bool {
    guard inMemoryJourneysById[journey.id] === journey else { return false }
    if let runner {
      return experienceRunners[journey.id] === runner
    }
    return experienceRunners[journey.id] == nil
  }

  /// Host dismissal owns terminalization from reservation until either a
  /// durable host exit commits or that exact admitted retry is revoked. Check
  /// the service-side retry authorization on both sides of the Journey actor
  /// hop so actor reentrancy cannot briefly expose an ordinary mutation path.
  private func hasHostDismissalPriority(_ journey: Journey) async -> Bool {
    if hostDismissalRetryAuthorizations[journey.id] === journey {
      return true
    }
    let isReserved = await journey.hasHostDismissalReservation()
    return isReserved || hostDismissalRetryAuthorizations[journey.id] === journey
  }

  func handleScopedPermissionEvent(
    journeyId: String,
    eventName: String,
    properties: sending [String: Any],
    distinctId: String
  ) async {
    guard let journey = inMemoryJourneysById[journeyId],
          let runner = experienceRunners[journeyId],
          journey.distinctId == distinctId,
          await ownsExecutableJourney(journey, runner: runner) else { return }
    let scopedDistinctId = journey.distinctId
    let sourceState = await journey.snapshot()
    var scopedProperties = properties
    scopedProperties["journey_id"] = sourceState.id
    scopedProperties["experience_id"] = sourceState.experienceId
    scopedProperties["experience_version"] = sourceState.experienceVersion

    // Boxed to hand the write-once payload through the staging pipeline.
    let propertiesBox = UncheckedSendable(scopedProperties)
    let stage = await stageScopedEvent(
      name: eventName,
      properties: propertiesBox.value,
      distinctId: scopedDistinctId
    )
    guard await ownsExecutableJourney(journey, runner: runner) else { return }
    let localScopedEvent = stage.localEvent

    let cachedExperiences = await getAllExperiences(for: scopedDistinctId)
    guard await ownsExecutableJourney(journey, runner: runner) else { return }
    let transientEvent = stage.transientEvent
    if let cachedExperiences {
      let activeJourneyIds = await getActiveJourneys(for: localScopedEvent.distinctId).map(\.id)
      guard await ownsExecutableJourney(journey, runner: runner) else { return }
      let transientEventsByJourneyId: [String: [StoredEvent]] = Dictionary(
        uniqueKeysWithValues: activeJourneyIds.map { ($0, [transientEvent]) }
      )
      await processActiveJourneys(
        for: localScopedEvent,
        experiences: cachedExperiences,
        transientEventsByJourneyId: transientEventsByJourneyId,
        restrictedToJourneyIds: nil
      )
      guard await ownsExecutableJourney(journey, runner: runner) else { return }
    }

    await completeDeferredDismissIfReady(journeyId: journeyId)
    guard await ownsExecutableJourney(journey, runner: runner) else { return }

    let (trackedEvent, response) = await trackScopedEvent(
      stage,
      properties: scopedProperties,
      persistToHistory: true,
      applyBeforeSend: true
    )
    guard await ownsExecutableJourney(journey, runner: runner) else { return }

    let scopedEvent = confirmedScopedEvent(from: trackedEvent, distinctId: scopedDistinctId)
    let trackedTransientEvent = makeStoredEvent(from: scopedEvent)

    let experiences = if let cachedExperiences {
      cachedExperiences
    } else {
      await getAllExperiences(for: scopedEvent.distinctId)
    }
    guard await ownsExecutableJourney(journey, runner: runner) else { return }
    if let experiences {
      await startAndProcessMatchingJourneys(
        for: scopedEvent,
        transientEvent: trackedTransientEvent,
        experiences: experiences
      )
      guard await ownsExecutableJourney(journey, runner: runner) else { return }
    }
    await handleScopedGatePlan(
      response?.gatePlan(),
      sourceJourney: journey,
      sourceExperience: sourceScopedGoalExperience(
        for: journey,
        experiences: experiences ?? cachedExperiences
      ),
      sourceDistinctId: scopedEvent.distinctId
    )
  }

  func handleScopedMilestoneEvent(
    journeyId: String,
    milestoneId: String,
    milestoneLabel: String?,
    screenId: String?,
    handlerId: String? = nil
  ) async {
    guard let journey = inMemoryJourneysById[journeyId],
          let runner = experienceRunners[journeyId],
          await ownsExecutableJourney(journey, runner: runner) else { return }
    let sourceState = await journey.snapshot()
    guard await ownsExecutableJourney(journey, runner: runner),
          !sourceState.isGhost else { return }

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
    guard await ownsExecutableJourney(journey, runner: runner) else { return }
    let localScopedEvent = stage.localEvent
    let cachedExperiences: [Experience]? = await getAllExperiences(for: scopedDistinctId)
    guard await ownsExecutableJourney(journey, runner: runner) else { return }
    let transientEvent = stage.transientEvent
    let sourceJourneyCompleted = await processSourceScopedGoalJourneyEvent(
      journey,
      runner: runner,
      event: localScopedEvent,
      transientEvent: transientEvent,
      shouldDispatchToRunner: false
    )
    guard await ownsScopedCallbackContinuation(
      journey,
      runner: runner,
      sourceCompleted: sourceJourneyCompleted
    ) else { return }
    let otherActiveJourneyIds = Set(
      await getActiveJourneys(for: localScopedEvent.distinctId)
        .map(\.id)
        .filter { $0 != journey.id }
    )
    guard await ownsScopedCallbackContinuation(
      journey,
      runner: runner,
      sourceCompleted: sourceJourneyCompleted
    ) else { return }
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
      guard await ownsScopedCallbackContinuation(
        journey,
        runner: runner,
        sourceCompleted: sourceJourneyCompleted
      ) else { return }
    }

    let (trackedEvent, response) = await trackScopedEvent(stage, properties: properties)
    guard await ownsScopedCallbackContinuation(
      journey,
      runner: runner,
      sourceCompleted: sourceJourneyCompleted
    ) else { return }

    let scopedEvent = confirmedScopedEvent(from: trackedEvent, distinctId: scopedDistinctId)
    await eventLog.storePreparedEventInHistory(localScopedEvent)
    guard await ownsScopedCallbackContinuation(
      journey,
      runner: runner,
      sourceCompleted: sourceJourneyCompleted
    ) else { return }

    let experiences = if let cachedExperiences {
      cachedExperiences
    } else {
      await getAllExperiences(for: scopedEvent.distinctId)
    }
    guard await ownsScopedCallbackContinuation(
      journey,
      runner: runner,
      sourceCompleted: sourceJourneyCompleted
    ) else { return }
    let resolvedSourceExperience = sourceScopedGoalExperience(
      for: journey,
      experiences: experiences ?? cachedExperiences
    )
    var sourceJourneyStillCompleted = sourceJourneyCompleted
    if !sourceJourneyStillCompleted {
      sourceJourneyStillCompleted = await processSourceScopedGoalJourneyEvent(
        journey,
        runner: runner,
        event: scopedEvent,
        transientEvent: transientEvent,
        shouldDispatchToRunner: true
      )
      guard await ownsScopedCallbackContinuation(
        journey,
        runner: runner,
        sourceCompleted: sourceJourneyStillCompleted
      ) else { return }
    }
    if let experiences {
      await startAndProcessMatchingJourneys(
        for: scopedEvent,
        transientEvent: transientEvent,
        experiences: experiences
      )
      guard await ownsScopedCallbackContinuation(
        journey,
        runner: runner,
        sourceCompleted: sourceJourneyStillCompleted
      ) else { return }
    }
    await handleScopedGatePlan(
      response?.gatePlan(),
      sourceJourney: sourceJourneyStillCompleted ? nil : journey,
      sourceExperience: resolvedSourceExperience,
      sourceDistinctId: scopedEvent.distinctId
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
    runner: JourneyRunner,
    event: JourneyRunner.AuthoredEvent
  ) async -> CommittedScopedAuthoredEvent? {
    guard await ownsExecutableJourney(journey, runner: runner) else { return nil }
    let sourceState = await journey.snapshot()
    guard await ownsExecutableJourney(journey, runner: runner),
          !sourceState.isGhost else { return nil }
    let isScreenRouteEvent = event.screenRouteAdmissionId != nil
    if isScreenRouteEvent {
      let isDropped = await isDurablyDroppedScreenAuthoredEvent(event.id, journey: journey)
      guard await ownsExecutableJourney(journey, runner: runner) else { return nil }
      if isDropped {
        await removeDurableScreenAuthoredEvent(event.id, journey: journey)
        return nil
      }
    }

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

    let preparedEvent: NuxieEvent
    let restored = isScreenRouteEvent
      ? await durablePreparedAuthoredEvent(event.id, journey: journey)
      : nil
    guard await ownsExecutableJourney(journey, runner: runner) else { return nil }
    if let restored {
      preparedEvent = restored
    } else {
      let propertiesBox = UncheckedSendable(properties)
      let stage = await stageScopedEvent(
        name: event.name,
        properties: propertiesBox.value,
        distinctId: journey.distinctId,
        eventId: event.id,
        occurredAt: event.occurredAt
      )
      guard await ownsExecutableJourney(journey, runner: runner) else { return nil }
      guard let prepared = await eventLog.applyBeforeSend(to: stage.localEvent) else {
        guard await ownsExecutableJourney(journey, runner: runner) else { return nil }
        if isScreenRouteEvent,
           !(await markScreenAuthoredEventDropped(event.id, journey: journey)) {
          return nil
        }
        guard await ownsExecutableJourney(journey, runner: runner) else { return nil }
        eventLog.track(
          JourneyEvents.eventSent,
          properties: eventSentProperties,
          userProperties: nil,
          userPropertiesSetOnce: nil,
          distinctIdOverride: journey.distinctId
        )
        if isScreenRouteEvent {
          await removeDurableScreenAuthoredEvent(event.id, journey: journey)
        }
        return nil
      }
      if isScreenRouteEvent {
        guard await persistPreparedScreenAuthoredEvent(
          event.id,
          prepared: prepared,
          journey: journey
        ) else { return nil }
        guard await ownsExecutableJourney(journey, runner: runner) else { return nil }
      }
      preparedEvent = prepared
    }
    guard await ownsExecutableJourney(journey, runner: runner) else { return nil }
    let commit = await eventLog.commitPreparedTriggerEvent(preparedEvent)
    guard await ownsExecutableJourney(journey, runner: runner) else {
      markPreparedResponseSequenceHandledDirectly(commit.sequence)
      return nil
    }
    return CommittedScopedAuthoredEvent(
      authored: event,
      commit: commit,
      eventSentProperties: eventSentProperties
    )
  }

  private func routeCommittedScopedAuthoredEvent(
    _ committedAuthoredEvent: CommittedScopedAuthoredEvent,
    sourceJourney journey: Journey,
    runner: JourneyRunner
  ) async -> RoutedScopedAuthoredEvent {
    let aborted = RoutedScopedAuthoredEvent(
      commit: committedAuthoredEvent.commit,
      sourceCompleted: true,
      experiences: nil
    )
    guard await ownsExecutableJourney(journey, runner: runner) else { return aborted }
    let journeyId = journey.id
    let authored = committedAuthoredEvent.authored
    let committed = committedAuthoredEvent.commit
    let confirmedEvent = committed.event
    let transientEvent = makeStoredEvent(from: confirmedEvent)
    let belongsToSourceIdentity = confirmedEvent.distinctId == journey.distinctId
    let cachedExperiences = await getAllExperiences(
      for: confirmedEvent.distinctId
    )
    guard await ownsExecutableJourney(journey, runner: runner) else { return aborted }
    let sourceCompleted = if belongsToSourceIdentity {
      await processSourceScopedGoalJourneyEvent(
        journey,
        runner: runner,
        event: confirmedEvent,
        transientEvent: transientEvent,
        shouldDispatchToRunner: false
      )
    } else {
      false
    }
    guard await ownsExecutableJourney(journey, runner: runner) else { return aborted }
    let sourceState = await journey.snapshot()
    guard await ownsExecutableJourney(journey, runner: runner) else { return aborted }
    if belongsToSourceIdentity,
       !sourceCompleted,
       sourceState.status.isLive {
      let outcome: JourneyRunner.RunOutcome?
      let authoredHostId = authored.hostId ?? authored.screenId
      if let admissionId = authored.screenRouteAdmissionId,
         let hostId = authoredHostId,
         let definition = screenControlRuntimes[journeyId]?.definition {
        let routeHost: JourneyRouteHost = hostId == JourneyDocument.journeyEventHostKey
          ? .journey
          : .screen(hostId)
        if let route = definition.route(host: routeHost, eventName: confirmedEvent.name) {
          let key: ScreenLocalRouteRequest = switch routeHost {
          case .journey:
            .journey(eventName: confirmedEvent.name)
          case .screen(let screenId):
            .screen(screenId: screenId, eventName: confirmedEvent.name)
          }
          outcome = await runner.dispatchAdmittedEvent(
            confirmedEvent,
            hostId: hostId,
            screenId: authored.screenId,
            componentId: nil,
            instanceId: nil,
            admission: AcceptedScreenLocalRoute(
              admissionId: admissionId,
              key: key,
              routeRevision: route.revisionSHA256
            ),
            completionAuthoredEventId: authored.id
          )
        } else if hostId == JourneyDocument.journeyEventHostKey {
          outcome = await runner.dispatchEventTrigger(confirmedEvent)
        } else {
          outcome = await runner.dispatchScreenEvent(
            confirmedEvent,
            screenId: hostId,
            componentId: nil,
            instanceId: nil
          )
        }
      } else if authored.hostId == JourneyDocument.journeyEventHostKey {
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
      guard await ownsExecutableJourney(journey, runner: runner) else { return aborted }
      await handleOutcome(outcome, journey: journey, runner: runner)
      guard await ownsExecutableJourney(journey, runner: runner) else { return aborted }
    }

    let otherJourneyIds = Set(
      await getActiveJourneys(for: confirmedEvent.distinctId).map(\.id)
        .filter { $0 != journey.id }
    )
    guard await ownsExecutableJourney(journey, runner: runner) else { return aborted }
    if !otherJourneyIds.isEmpty {
      await processActiveJourneys(
        for: confirmedEvent,
        experiences: cachedExperiences ?? [],
        transientEventsByJourneyId: Dictionary(
          uniqueKeysWithValues: otherJourneyIds.map { ($0, [transientEvent]) }
        ),
        restrictedToJourneyIds: otherJourneyIds
      )
      guard await ownsExecutableJourney(journey, runner: runner) else { return aborted }
    }

    let experiences = if let cachedExperiences {
      cachedExperiences
    } else {
      await getAllExperiences(for: confirmedEvent.distinctId)
    }
    guard await ownsExecutableJourney(journey, runner: runner) else { return aborted }
    if let experiences {
      await startAndProcessMatchingJourneys(
        for: confirmedEvent,
        transientEvent: transientEvent,
        experiences: experiences
      )
      guard await ownsExecutableJourney(journey, runner: runner) else { return aborted }
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
    guard !Task.isCancelled, !isShutDown else { return }
    await handleScopedGatePlan(
      response.gatePlan(),
      sourceJourney: routed.sourceCompleted || inMemoryJourneysById[journey.id] !== journey
        ? nil
        : journey,
      sourceExperience: sourceScopedGoalExperience(
        for: journey,
        experiences: routed.experiences
      ),
      sourceDistinctId: journey.distinctId
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
    guard !isShutDown, scopedAuthoredOutcomeDepth == 0 else { return }
    while true {
      if let pending = pendingScopedAuthoredResponses.removeValue(
        forKey: nextScopedAuthoredResponseToSchedule
      ) {
        nextScopedAuthoredResponseToSchedule += 1
        scheduleScopedAuthoredResponse(pending)
        continue
      }
      if directlyHandledPreparedResponseSequences.remove(
        nextScopedAuthoredResponseToSchedule
      ) != nil {
        nextScopedAuthoredResponseToSchedule += 1
        continue
      }
      return
    }
  }

  private func markPreparedResponseSequenceHandledDirectly(_ sequence: UInt64) {
    guard !isShutDown else { return }
    directlyHandledPreparedResponseSequences.insert(sequence)
    scheduleReadyScopedAuthoredResponses()
  }

  private func scheduleScopedAuthoredResponse(
    _ pending: PendingScopedAuthoredResponse
  ) {
    guard !isShutDown,
          !retiringResponseDistinctIds.contains(
            pending.sourceJourney.distinctId
          ) else { return }
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
    scopedAuthoredResponseOwners[taskId] = pending.sourceJourney.distinctId
    scopedAuthoredResponseTail = (taskId, task)
  }

  private func finishScopedAuthoredResponseTask(id: UUID) {
    scopedAuthoredResponseTasks.removeValue(forKey: id)
    scopedAuthoredResponseOwners.removeValue(forKey: id)
    guard scopedAuthoredResponseTail?.id == id else { return }
    scopedAuthoredResponseTail = nil
  }

  func handleUnsupportedScopedRequestPermission(
    journeyId: String,
    permissionType: String,
    distinctId: String
  ) async {
    guard let journey = inMemoryJourneysById[journeyId],
          let runner = experienceRunners[journeyId],
          journey.distinctId == distinctId,
          await ownsExecutableJourney(journey, runner: runner) else { return }
    let sourceState = await journey.snapshot()
    let unsupportedProperties: [String: Any] = [
      "journey_id": journeyId,
      "experience_id": sourceState.experienceId,
      "experience_version": sourceState.experienceVersion,
      "type": permissionType,
    ]
    let stagePropertiesBox = UncheckedSendable(unsupportedProperties)
    let stage = await stageScopedEvent(
      name: SystemEventNames.permissionDenied,
      properties: stagePropertiesBox.value,
      distinctId: distinctId
    )
    guard await ownsExecutableJourney(journey, runner: runner) else { return }
    let localScopedEvent = stage.localEvent
    let transientEvent = stage.transientEvent
    if let experiences = await getAllExperiences(for: distinctId) {
      guard await ownsExecutableJourney(journey, runner: runner) else { return }
      await processActiveJourneys(
        for: localScopedEvent,
        experiences: experiences,
        transientEventsByJourneyId: [journeyId: [transientEvent]],
        restrictedToJourneyIds: [journeyId]
      )
      guard await ownsExecutableJourney(journey, runner: runner) else { return }
    }

    await completeDeferredDismissIfReady(journeyId: journeyId)
    guard await ownsExecutableJourney(journey, runner: runner) else { return }

    let trackingPropertiesBox = UncheckedSendable(unsupportedProperties)
    let (_, response) = await trackScopedEvent(
      stage,
      properties: trackingPropertiesBox.value,
      persistToHistory: true,
      applyBeforeSend: true
    )
    guard await ownsExecutableJourney(journey, runner: runner) else { return }

    await handleScopedGatePlan(
      response?.gatePlan(),
      sourceJourney: journey,
      sourceExperience: nil,
      sourceDistinctId: distinctId
    )
  }

  // MARK: - Helpers

  private func dismissalExitReason(for reason: CloseReason) -> JourneyExitReason {
    JourneyDismissalMapping.exitReason(for: reason)
  }

  private func dismissalSource(for reason: CloseReason) -> JourneyDismissalSource? {
    reason == .userDismissed ? .user : nil
  }

  private func completeDeferredDismissIfReady(journeyId: String) async {
    guard let journey = inMemoryJourneysById[journeyId],
          let runner = experienceRunners[journeyId],
          await ownsExecutableJourney(journey, runner: runner),
          let reason = await runner.consumeDeferredDismissReasonIfReady(),
          await ownsExecutableJourney(journey, runner: runner) else { return }
    await completeJourney(
      journey,
      reason: dismissalExitReason(for: reason),
      dismissedBy: dismissalSource(for: reason)
    )
  }

  private func processSourceScopedGoalJourneyEvent(
    _ journey: Journey,
    runner: JourneyRunner,
    event: NuxieEvent,
    transientEvent: StoredEvent,
    shouldDispatchToRunner: Bool
  ) async -> Bool {
    guard await ownsExecutableJourney(journey, runner: runner) else { return true }
    await evaluateGoalIfNeeded(
      journey,
      transientEvents: [transientEvent]
    )
    guard await ownsExecutableJourney(journey, runner: runner) else { return true }
    let shouldDefer = await shouldDeferExitDecision(for: journey)
    guard await ownsExecutableJourney(journey, runner: runner) else { return true }
    if !shouldDefer {
      let reason = await exitDecision(journey)
      guard await ownsExecutableJourney(journey, runner: runner) else { return true }
      if let reason {
        await completeJourney(journey, reason: reason)
        return true
      }
    }
    let shouldCompletePresented = await shouldCompletePresentedScopedGoalJourney(journey)
    guard await ownsExecutableJourney(journey, runner: runner) else { return true }
    if shouldCompletePresented {
      let controller = await runner.viewController
      guard await ownsExecutableJourney(journey, runner: runner) else { return true }
      if let controller {
        await controller.prepareForDismissal(reason: .goalMet)
        guard await ownsExecutableJourney(journey, runner: runner) else { return true }
        await handleRuntimeDismiss(
          journeyId: journey.id,
          reason: .goalMet,
          controller: controller
        )
        guard await ownsScopedCallbackContinuation(
          journey,
          runner: runner,
          sourceCompleted: true
        ) else { return true }
        await experiencePresentationService.dismissCurrentExperience(reason: .goalMet)
      } else {
        await experiencePresentationService.dismissCurrentExperience()
        guard await ownsExecutableJourney(journey, runner: runner) else { return true }
        await completeJourney(journey, reason: .goalMet)
      }
      return true
    }
    var state = await journey.snapshot()
    guard await ownsExecutableJourney(journey, runner: runner) else { return true }
    guard shouldDispatchToRunner else {
      return !state.status.isLive
    }
    guard state.status.isLive else {
      return true
    }

    if let pending = state.executionState.pendingAction, pending.kind == .waitUntil {
      await resumePendingWaitForEvent(journey, runner: runner, pending: pending, event: event)
      return !(await journey.snapshot()).status.isLive
    }

    let outcome = await runner.dispatchEventTrigger(event)
    guard await ownsExecutableJourney(journey, runner: runner) else { return true }
    await handleOutcome(outcome, journey: journey, runner: runner)
    guard await ownsExecutableJourney(journey, runner: runner) else { return true }
    state = await journey.snapshot()
    guard await ownsExecutableJourney(journey, runner: runner) else { return true }
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
    guard !isShutDown else { return nil }
    if let existing = experienceRunners[journey.id] {
      return existing
    }
    guard await ownsExecutableJourney(journey) else { return nil }

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

    guard await ownsExecutableJourney(journey) else { return nil }

    let initialState = await journey.snapshot()
    guard await ownsExecutableJourney(journey) else { return nil }
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
        appActionHandler: appActionHandler,
        responseSessionModule: controlExperience.definition?.responseSchema.map { _ in
          ResponseSessionModule(
            store: JourneyResponseSessionStore(
              journey: journey,
              journeyStore: journeyStore
            )
          )
        },
        persistResponseRetryMarker: { [weak self, weak journey] state in
          guard let self, let journey else { return false }
          return await self.persistResponseRetryMarker(state, for: journey)
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

    guard await ownsExecutableJourney(journey) else { return nil }

    await runner.setOnShowScreen { [weak self, weak runner] (screenId: String, transition: AnyCodable?) async -> Bool in
      guard let self else { return false }
      let controller = try? await self.presentExperienceIfNeeded(
        experienceVersionId: versionId,
        journey: journey,
        commit: nil
      )
      if let controller {
        await runner?.attach(viewController: controller)
        return await controller.navigateAndWait(
          to: screenId,
          transition: transition?.value
        )
      }
      return false
    }
    guard await ownsExecutableJourney(journey) else { return nil }
    experienceRunners[journey.id] = runner
    if let definition = controlExperience.definition {
      let dateProvider = self.dateProvider
      let router = makeScreenEmissionRouter()
      let dispatcher = ScreenEmissionDispatcher(
        createId: { UUID.v7().uuidString },
        now: { dateProvider.now().ISO8601Format() },
        executeScriptAction: { input in
          throw ScreenEmissionDispatchError.scriptActionMissing(
            actionId: input.actionId
          )
        }
      )
      screenControlRuntimes[journey.id] = ScreenControlRuntime(
        definition: definition,
        dispatcher: dispatcher,
        router: router,
        operationGate: ExperienceInteractiveOperationGate()
      )
      let routing = (await journey.snapshot()).executionState.screenRouting
      guard await ownsExecutableJourney(journey, runner: runner) else { return nil }
      await dispatcher.restoreProgress(
        journeyId: journey.id,
        nextBatchSequence: routing.nextBatchSequence,
        nextEmissionSequence: routing.nextEmissionSequence
      )
      guard await ownsExecutableJourney(journey, runner: runner) else { return nil }
    }

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
          presentationStyle: experience.behaviorPresentationStyle,
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

    guard await ownsExecutableJourney(journey, runner: runner) else { return nil }
    return runner
  }

  /// Revalidates a runner-building/resume operation after each suspension.
  /// Exact object identity prevents a late task from reinstalling a journey
  /// that identity quarantine or authoritative ownership already removed.
  private func ownsExecutableJourney(_ journey: Journey) async -> Bool {
    guard !isShutDown,
          inMemoryJourneysById[journey.id] === journey,
          journey.distinctId == identityService.getDistinctId() else {
      return false
    }
    let state = await journey.snapshot()
    return !isShutDown
      && inMemoryJourneysById[journey.id] === journey
      && journey.distinctId == identityService.getDistinctId()
      && state.status.isLive
  }

  /// Revalidates a renderer callback against the exact runner that admitted
  /// it. Identity transitions and ownership loss can remove or replace both
  /// objects while the callback is suspended on the runner actor.
  private func ownsExecutableJourney(
    _ journey: Journey,
    runner: JourneyRunner
  ) async -> Bool {
    guard !isShutDown,
          inMemoryJourneysById[journey.id] === journey,
          experienceRunners[journey.id] === runner,
          journey.distinctId == identityService.getDistinctId(),
          (await journey.snapshot()).status.isLive else {
      return false
    }
    return !isShutDown
      && inMemoryJourneysById[journey.id] === journey
      && experienceRunners[journey.id] === runner
      && journey.distinctId == identityService.getDistinctId()
  }

  /// A scoped event may deliberately complete its own source journey while
  /// preserving the rest of that event's delivery. Only that exact completed
  /// object, with no replacement installed and the same current identity, may
  /// continue after terminalization.
  private func ownsScopedCallbackContinuation(
    _ journey: Journey,
    runner: JourneyRunner,
    sourceCompleted: Bool
  ) async -> Bool {
    guard !isShutDown else { return false }
    if !sourceCompleted {
      return await ownsExecutableJourney(journey, runner: runner)
    }
    guard identityService.getDistinctId() == journey.distinctId,
          inMemoryJourneysById[journey.id] == nil,
          experienceRunners[journey.id] == nil else { return false }
    let state = await journey.snapshot()
    return !isShutDown
      && identityService.getDistinctId() == journey.distinctId
      && inMemoryJourneysById[journey.id] == nil
      && experienceRunners[journey.id] == nil
      && state.status == .completed
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
    guard await ownsExecutableJourney(journey) else { throw CancellationError() }
    if let runner = experienceRunners[journey.id] {
      let controller = await runner.viewController
      guard await ownsExecutableJourney(journey, runner: runner) else {
        throw CancellationError()
      }
      let isPresented = await experiencePresentationService.isExperiencePresented
      guard await ownsExecutableJourney(journey, runner: runner) else {
        throw CancellationError()
      }
      if let controller, isPresented {
        return controller
      }
    }
    if let delegate = runtimeDelegates[journey.id] {
      let presentationState = await beginPresentationTrace(
        experienceVersionId: experienceVersionId,
        journey: journey,
        delegate: delegate
      )
      guard await ownsExecutableJourney(journey) else { throw CancellationError() }
      let controller: ExperienceViewController
      do {
        if let commit {
          controller = try await experiencePresentationService.presentExperience(
            experienceVersionId,
            from: journey,
            runtimeDelegate: delegate,
            colorSchemeMode: .system,
            commit: commit
          )
        } else {
          controller = try await experiencePresentationService.presentExperience(
            experienceVersionId,
            from: journey,
            runtimeDelegate: delegate,
            colorSchemeMode: .system
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
      guard await ownsExecutableJourney(journey) else { throw CancellationError() }
      if let runner = experienceRunners[journey.id] {
        await runner.attach(viewController: controller)
        guard await ownsExecutableJourney(journey, runner: runner) else {
          throw CancellationError()
        }
      }
      return controller
    }

    let delegate = JourneyRendererBridge(
      journeyId: journey.id,
      distinctId: journey.distinctId,
      journeyService: self,
      dateProvider: dateProvider
    )
    guard await ownsExecutableJourney(journey) else { throw CancellationError() }
    runtimeDelegates[journey.id] = delegate
    let presentationState = await beginPresentationTrace(
      experienceVersionId: experienceVersionId,
      journey: journey,
      delegate: delegate
    )
    guard await ownsExecutableJourney(journey) else { throw CancellationError() }
    let controller: ExperienceViewController
    do {
      if let commit {
        controller = try await experiencePresentationService.presentExperience(
          experienceVersionId,
          from: journey,
          runtimeDelegate: delegate,
          colorSchemeMode: .system,
          commit: commit
        )
      } else {
        controller = try await experiencePresentationService.presentExperience(
          experienceVersionId,
          from: journey,
          runtimeDelegate: delegate,
          colorSchemeMode: .system
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
    guard await ownsExecutableJourney(journey) else { throw CancellationError() }
    if let runner = experienceRunners[journey.id] {
      await runner.attach(viewController: controller)
      guard await ownsExecutableJourney(journey, runner: runner) else {
        throw CancellationError()
      }
    }
    return controller
  }

  private func beginPresentationTrace(
    experienceVersionId: String,
    journey: Journey,
    delegate: JourneyRendererBridge
  ) async -> JourneyPresentationTraceState? {
    guard await ownsExecutableJourney(journey) else { return nil }
    guard let attempt = await ExperiencePresentationAttemptJourneyContext.load(from: journey) else {
      guard await ownsExecutableJourney(journey) else { return nil }
      presentationTraceStates.removeValue(forKey: journey.id)
      await delegate.beginPresentationTrace(
        presentationToken: nil,
        context: nil
      )
      return nil
    }
    guard await ownsExecutableJourney(journey) else { return nil }
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
    guard !isShutDown, let presentationState else { return }
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
    guard !isShutDown else { return }
    if inMemoryJourneysById[journeyId] == nil {
      runtimeDelegates.removeValue(forKey: journeyId)
    }
  }

  private func recordJourneyMatch(
    _ attempt: ExperiencePresentationAttempt,
    journey: Journey,
    persist: Bool
  ) async {
    guard await ownsExecutableJourney(journey) else { return }
    guard await ExperiencePresentationAttemptJourneyContext.load(from: journey)?.id
      != attempt.id else {
      return
    }
    guard await ownsExecutableJourney(journey) else { return }
    await ExperiencePresentationAttemptJourneyContext.store(
      attempt,
      in: journey,
      at: dateProvider.now()
    )
    guard await ownsExecutableJourney(journey) else { return }
    presentationTrace.record(
      attempt: attempt,
      stage: .journeyMatched(journeyId: journey.id),
      at: dateProvider.now()
    )
    if persist {
      let state = await journey.snapshot()
      guard await ownsExecutableJourney(journey) else { return }
      persistJourney(state)
    }
  }

  private func handleOutcome(
    _ outcome: JourneyRunner.RunOutcome?,
    journey: Journey,
    runner expectedRunner: JourneyRunner? = nil
  ) async {
    guard let runner = expectedRunner ?? experienceRunners[journey.id],
          await ownsExecutableJourney(journey, runner: runner) else { return }
    var holdsScopedAuthoredResponseScheduling = false
    defer {
      if holdsScopedAuthoredResponseScheduling {
        scopedAuthoredOutcomeDepth -= 1
      }
      scheduleReadyScopedAuthoredResponses()
    }
    let authoredEvents = await runner.takeAuthoredEvents()
    guard await ownsExecutableJourney(journey, runner: runner) else { return }
    for authoredEvent in authoredEvents {
      guard await ownsExecutableJourney(journey, runner: runner) else { return }
      guard let event = await commitScopedAuthoredEvent(
        sourceJourney: journey,
        runner: runner,
        event: authoredEvent
      ) else {
        guard await ownsExecutableJourney(journey, runner: runner) else { return }
        continue
      }
      guard await ownsExecutableJourney(journey, runner: runner) else {
        markPreparedResponseSequenceHandledDirectly(event.commit.sequence)
        return
      }
        if !holdsScopedAuthoredResponseScheduling {
          scopedAuthoredOutcomeDepth += 1
          holdsScopedAuthoredResponseScheduling = true
        }
        if event.authored.screenRouteAdmissionId != nil {
          let claim = await claimScreenAuthoredEventRouting(
            event.authored.id,
            journey: journey
          )
          guard claim == .claimed else {
            // Every committed event allocates a prepared-response sequence. A
            // failed/no-op durable claim leaves recovery as the routing owner,
            // so retire this attempt's sequence rather than blocking its tail.
            markPreparedResponseSequenceHandledDirectly(event.commit.sequence)
            continue
          }
          guard await ownsExecutableJourney(journey, runner: runner) else {
            markPreparedResponseSequenceHandledDirectly(event.commit.sequence)
            return
          }
        }
        let routed = await routeCommittedScopedAuthoredEvent(
          event,
          sourceJourney: journey,
          runner: runner
        )
        guard await ownsExecutableJourney(journey, runner: runner) else {
          markPreparedResponseSequenceHandledDirectly(event.commit.sequence)
          return
        }
        stageScopedAuthoredResponse(
          routed,
          sequence: event.commit.sequence,
          sourceJourney: journey
        )
        if event.authored.screenRouteAdmissionId != nil {
          await markScreenAuthoredEventRouted(event.authored.id, journey: journey)
          guard await ownsExecutableJourney(journey, runner: runner) else { return }
        }
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
        if event.authored.screenRouteAdmissionId != nil {
          await removeDurableScreenAuthoredEvent(event.authored.id, journey: journey)
          guard await ownsExecutableJourney(journey, runner: runner) else { return }
        }
    }

    guard await ownsExecutableJourney(journey, runner: runner) else { return }
    await applyRunOutcome(outcome, journey: journey, runner: runner)
    guard await ownsExecutableJourney(journey, runner: runner) else { return }
    await cleanupFinishedScreenRouteAdmissions(journey)
  }

  private func cleanupFinishedScreenRouteAdmissions(_ journey: Journey) async {
    let state = await journey.snapshot()
    let retainedAdmissionIds = retainedScreenRouteAdmissionIds(in: state)
    let removable = state.executionState.screenRouting.eventRecords.compactMap {
      element -> String? in
      let (id, record) = element
      guard record.phase == .finished,
            record.pendingAuthoredEvents.isEmpty,
            record.routeContinuation?.isEmpty != false,
            !retainedAdmissionIds.contains(id) else { return nil }
      return id
    }
    guard !removable.isEmpty else { return }
    _ = await updateDurableScreenRouting(journey: journey) { routing in
      for eventId in removable {
        routing.eventRecords.removeValue(forKey: eventId)
        if !routing.recentEventIds.contains(eventId) {
          routing.recentEventIds.append(eventId)
        }
      }
      if routing.recentEventIds.count > 256 {
        routing.recentEventIds.removeFirst(routing.recentEventIds.count - 256)
      }
    }
  }

  private func retainedScreenRouteAdmissionIds(
    in state: JourneySnapshot
  ) -> Set<String> {
    var admissionIds = Set([
      state.executionState.pendingPurchaseOutlets?.screenRouteAdmissionId,
      state.executionState.pendingRestoreOutlets?.screenRouteAdmissionId,
    ].compactMap { $0 })

    func collect(_ pending: JourneyPendingAction?) {
      guard let pending else { return }
      collect(pending.continuation)
    }

    func collect(_ steps: [JourneyContinuationStep]?) {
      guard let steps else { return }
      for step in steps {
        switch step.operation {
        case .request(let request):
          if let admissionId = request.screenRouteAdmissionId {
            admissionIds.insert(admissionId)
          }
          collect(request.resume?.pending)
        case .pending(let pending):
          collect(pending)
        case .transfer, .exit:
          break
        }
      }
    }

    collect(state.executionState.pendingAction)
    collect(state.executionState.prePresentationContinuation)
    collect(state.executionState.pendingPresentation?.continuation)
    collect(state.executionState.postPresentationContinuation)
    return admissionIds
  }

  private func resumeDurableScreenAuthoredEvents(
    _ record: JourneyScreenEventRecord,
    journey: Journey
  ) async {
    guard let runner = experienceRunners[journey.id],
          await ownsExecutableJourney(journey, runner: runner) else { return }
    for stored in record.pendingAuthoredEvents {
      guard await ownsExecutableJourney(journey, runner: runner) else { return }
      let authored = JourneyRunner.AuthoredEvent(
        id: stored.id,
        name: stored.name,
        properties: stored.properties,
        occurredAt: stored.occurredAt,
        hostId: stored.hostId,
        screenId: stored.screenId,
        handlerId: stored.handlerId,
        screenRouteAdmissionId: record.sourceEvent.id
      )
      guard let committed = await commitScopedAuthoredEvent(
        sourceJourney: journey,
        runner: runner,
        event: authored
      ) else {
        guard await ownsExecutableJourney(journey, runner: runner) else { return }
        await removeDurableScreenAuthoredEvent(stored.id, journey: journey)
        continue
      }
      guard await ownsExecutableJourney(journey, runner: runner) else {
        markPreparedResponseSequenceHandledDirectly(committed.commit.sequence)
        return
      }
      let shouldRoute: Bool
      switch stored.phase {
      case .intent, .prepared:
        let claim = await claimScreenAuthoredEventRouting(
          stored.id,
          journey: journey
        )
        guard claim == .claimed else {
          // Keep the durable authored event for a later recovery pass. The
          // idempotent EventLog commit can be retried, but this attempt's
          // response sequence must not stall unrelated prepared responses.
          markPreparedResponseSequenceHandledDirectly(committed.commit.sequence)
          continue
        }
        guard await ownsExecutableJourney(journey, runner: runner) else {
          markPreparedResponseSequenceHandledDirectly(committed.commit.sequence)
          return
        }
        shouldRoute = true
      case .routingClaimed:
        shouldRoute = true
      case .routed, .dropped:
        shouldRoute = false
      }
      let routed: RoutedScopedAuthoredEvent
      if shouldRoute {
        routed = await routeCommittedScopedAuthoredEvent(
          committed,
          sourceJourney: journey,
          runner: runner
        )
        guard await ownsExecutableJourney(journey, runner: runner) else {
          markPreparedResponseSequenceHandledDirectly(committed.commit.sequence)
          return
        }
        await markScreenAuthoredEventRouted(stored.id, journey: journey)
        guard await ownsExecutableJourney(journey, runner: runner) else { return }
      } else {
        routed = RoutedScopedAuthoredEvent(
          commit: committed.commit,
          sourceCompleted: false,
          experiences: nil
        )
      }
      eventLog.track(
        JourneyEvents.eventSent,
        properties: committed.eventSentProperties,
        userProperties: nil,
        userPropertiesSetOnce: nil,
        distinctIdOverride: journey.distinctId
      )
      await handleScopedAuthoredResponse(routed, sourceJourney: journey)
      guard await ownsExecutableJourney(journey, runner: runner) else { return }
      markPreparedResponseSequenceHandledDirectly(committed.commit.sequence)
      await removeDurableScreenAuthoredEvent(stored.id, journey: journey)
    }
  }

  private func removeDurableScreenAuthoredEvent(
    _ eventId: String,
    journey: Journey
  ) async {
    let hasDurableIntent = (await journey.snapshot()).executionState.screenRouting
      .eventRecords.values.contains { record in
        record.pendingAuthoredEvents.contains { $0.id == eventId }
      }
    guard hasDurableIntent else { return }
    _ = await updateDurableScreenRouting(journey: journey) { routing in
      for key in Array(routing.eventRecords.keys) {
        guard var record = routing.eventRecords[key] else { continue }
        let originalCount = record.pendingAuthoredEvents.count
        record.pendingAuthoredEvents.removeAll { $0.id == eventId }
        if record.pendingAuthoredEvents.count != originalCount {
          routing.eventRecords[key] = record
        }
      }
    }
  }

  private func durablePreparedAuthoredEvent(
    _ eventId: String,
    journey: Journey
  ) async -> NuxieEvent? {
    let snapshot = await journey.snapshot()
    guard let stored = snapshot.executionState.screenRouting.eventRecords.values
      .lazy.compactMap({ $0.pendingAuthoredEvents.first { $0.id == eventId } }).first,
          stored.phase != .intent,
          let preparedId = stored.preparedId,
          let name = stored.preparedName,
          let distinctId = stored.preparedDistinctId,
          let properties = stored.preparedProperties,
          let occurredAt = stored.preparedOccurredAt else { return nil }
    return NuxieEvent(
      id: preparedId,
      name: name,
      distinctId: distinctId,
      properties: properties.mapValues(\.value),
      timestamp: occurredAt
    )
  }

  private func isDurablyDroppedScreenAuthoredEvent(
    _ eventId: String,
    journey: Journey
  ) async -> Bool {
    let snapshot = await journey.snapshot()
    return snapshot.executionState.screenRouting.eventRecords.values.contains { record in
      record.pendingAuthoredEvents.contains { event in
        event.id == eventId && event.phase == .dropped
      }
    }
  }

  private func updateScreenAuthoredEvent(
    _ eventId: String,
    journey: Journey,
    update: (inout JourneyScreenAuthoredEvent) -> Bool
  ) async -> Bool {
    var didUpdate = false
    let didPersist = await updateDurableScreenRouting(journey: journey) { routing in
      didUpdate = false
      for key in Array(routing.eventRecords.keys) {
        guard var record = routing.eventRecords[key],
              let index = record.pendingAuthoredEvents.firstIndex(where: { $0.id == eventId })
        else { continue }
        guard update(&record.pendingAuthoredEvents[index]) else { return }
        routing.eventRecords[key] = record
        didUpdate = true
        return
      }
    }
    return didPersist && didUpdate
  }

  private func persistPreparedScreenAuthoredEvent(
    _ eventId: String,
    prepared: NuxieEvent,
    journey: Journey
  ) async -> Bool {
    await updateScreenAuthoredEvent(eventId, journey: journey) { stored in
      stored.phase = .prepared
      stored.preparedId = prepared.id
      stored.preparedName = prepared.name
      stored.preparedDistinctId = prepared.distinctId
      stored.preparedProperties = prepared.properties.mapValues(AnyCodable.init)
      stored.preparedOccurredAt = prepared.timestamp
      return true
    }
  }

  private func claimScreenAuthoredEventRouting(
    _ eventId: String,
    journey: Journey
  ) async -> ScreenAuthoredEventRoutingClaim {
    var didClaim = false
    let didPersist = await updateDurableScreenRouting(journey: journey) { routing in
      for key in Array(routing.eventRecords.keys) {
        guard var record = routing.eventRecords[key],
              let index = record.pendingAuthoredEvents.firstIndex(where: { $0.id == eventId })
        else { continue }
        guard record.pendingAuthoredEvents[index].phase == .prepared
                || record.pendingAuthoredEvents[index].phase == .intent else { return }
        record.pendingAuthoredEvents[index].phase = .routingClaimed
        routing.eventRecords[key] = record
        didClaim = true
        return
      }
    }
    guard didPersist else { return .persistenceFailed }
    return didClaim ? .claimed : .notClaimable
  }

  private func markScreenAuthoredEventRouted(
    _ eventId: String,
    journey: Journey
  ) async {
    _ = await updateScreenAuthoredEvent(eventId, journey: journey) { stored in
      stored.phase = .routed
      return true
    }
  }

  private func markScreenAuthoredEventDropped(
    _ eventId: String,
    journey: Journey
  ) async -> Bool {
    await updateScreenAuthoredEvent(eventId, journey: journey) { stored in
      guard stored.phase == .intent else { return false }
      stored.phase = .dropped
      return true
    }
  }

  private func applyRunOutcome(
    _ outcome: JourneyRunner.RunOutcome?,
    journey: Journey,
    runner: JourneyRunner
  ) async {
    guard await ownsExecutableJourney(journey, runner: runner) else { return }
    guard let outcome else { return }
    switch outcome {
    case .present:
      let state = await journey.snapshot()
      guard await ownsExecutableJourney(journey, runner: runner) else { return }
      guard persistPresentationCommit(state, for: journey) else { return }
      guard let pending = state.executionState.pendingPresentation else { return }
      let matchesJourney = pending.experienceId == state.experienceId
        && pending.experienceVersionId == state.experienceVersion
      let validatesPending = matchesJourney
        ? await experienceService.validatesPresentationCommit(pending)
        : false
      guard await ownsExecutableJourney(journey, runner: runner) else { return }
      guard validatesPending else {
        await completeJourney(journey, reason: .error)
        return
      }
      do {
        let controller = try await presentExperienceIfNeeded(
          experienceVersionId: state.experienceVersion,
          journey: journey,
          commit: pending
        )
        guard await ownsExecutableJourney(journey, runner: runner) else { return }
        let afterPresentation = await journey.snapshot()
        guard await ownsExecutableJourney(journey, runner: runner) else { return }
        let stillValid = await experienceService.validatesPresentationCommit(pending)
        guard await ownsExecutableJourney(journey, runner: runner) else { return }
        guard (presentationCommit(
          afterPresentation.executionState.pendingPresentation,
          matches: pending
        ) || presentationCommit(
          afterPresentation.executionState.currentPresentation,
          matches: pending
        )), stillValid else {
          await retireStalePresentation(journey: journey, commit: pending)
          return
        }
        _ = controller
      } catch {
        LogError("Failed to present selected screen \(pending.screenId): \(error)")
        guard await ownsExecutableJourney(journey, runner: runner) else { return }
        if case ExperienceError.productsUnavailable = error,
           experienceRunners[journey.id] === runner {
          await handleOutcome(
            await runner.handleProductsUnavailable(),
            journey: journey,
            runner: runner
          )
          return
        }
        let stillValid = await experienceService.validatesPresentationCommit(pending)
        guard await ownsExecutableJourney(journey, runner: runner) else { return }
        if !stillValid {
          await retireStalePresentation(journey: journey, commit: pending)
        }
      }
    case .paused(let pending):
      await journey.pause(at: dateProvider.now())
      guard await ownsExecutableJourney(journey, runner: runner) else { return }
      let state = await journey.snapshot()
      guard await ownsExecutableJourney(journey, runner: runner) else { return }
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
      guard await ownsExecutableJourney(journey, runner: runner) else { return }
      await transferJourneyToServer(journey)
    case .exited(let reason):
      guard await ownsExecutableJourney(journey, runner: runner) else { return }
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
    guard await ownsExecutableJourney(journey) else { return }
    let state = await journey.snapshot()
    guard await ownsExecutableJourney(journey),
          presentationCommit(
            state.executionState.pendingPresentation,
            matches: commit
          ) || presentationCommit(
            state.executionState.currentPresentation,
            matches: commit
          ) else { return }

    let ownsPresentedWindow =
      await experiencePresentationService.presentedJourneyId == journey.id
    guard await ownsExecutableJourney(journey) else { return }
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
    guard !isShutDown else { return }
    await discardLocalJourney(journey, terminalStatus: .superseded)
    guard !isShutDown else { return }
    if ownsPresentedWindow {
      await experiencePresentationService.dismissCurrentExperience(
        reason: .error(ExperiencePresentationError.presentationSuperseded)
      )
    }
  }

  private func transferJourneyToServer(_ journey: Journey) async {
    guard await ownsExecutableJourney(journey) else { return }
    var state = await journey.snapshot()
    guard await ownsExecutableJourney(journey), state.status.isLive else { return }
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
        persistToHistory: true,
        distinctIdOverride: journey.distinctId,
        applyBeforeSend: false
      )
      guard await ownsExecutableJourney(journey) else { return }
      guard let ownership = response.journeyOwnership,
            ownership.journeyId == journey.id,
            ownership.accepted else {
        LogWarning(
          "JourneyService: handoff for \(journey.id) was not accepted; retaining local ownership"
        )
        state = await journey.snapshot()
        guard await ownsExecutableJourney(journey) else { return }
        persistJourney(state)
        return
      }
      await discardLocalJourney(
        journey,
        terminalStatus: .transferred,
        authority: .authoritativeOwnershipLoss
      )
    } catch {
      LogWarning("JourneyService: failed to hand off journey \(journey.id): \(error)")
      let latest = await journey.snapshot()
      guard await ownsExecutableJourney(journey) else { return }
      persistJourney(latest)
    }
  }

  @discardableResult
  private func discardLocalJourney(
    _ journey: Journey,
    terminalStatus: JourneyStatus,
    authority: JourneyTerminalTransitionAuthority = .ordinary
  ) async -> Bool {
    guard !isShutDown else { return false }
    if authority == .ordinary,
       await hasHostDismissalPriority(journey) {
      return false
    }
    guard inMemoryJourneysById[journey.id] === journey,
          let commit = await journey.discardLocally(
            terminalStatus: terminalStatus,
            at: dateProvider.now(),
            authority: authority
          ),
          !isShutDown,
          inMemoryJourneysById[journey.id] === journey else { return false }

    // Establish a durable terminal quarantine before unlinking the live
    // object. If deletion then fails, a relaunch sees this non-live snapshot
    // instead of resurrecting the stale live epoch.
    let terminal = await journey.snapshot()
    guard !isShutDown,
          inMemoryJourneysById[journey.id] === journey else { return false }
    var terminalPersisted = false
    do {
      try journeyStore.saveJourney(terminal)
      terminalPersisted = true
    } catch {
      LogError(
        "JourneyService: failed to persist terminal quarantine for \(journey.id): \(error)"
      )
    }

    timerScheduler.cancelTasks(journeyId: journey.id)
    if let runner = experienceRunners[journey.id] {
      await runner.retire()
      guard !isShutDown else { return false }
    }
    experienceRunners.removeValue(forKey: journey.id)
    removeScreenControlRuntime(journeyId: journey.id)
    pendingScreenEvents = pendingScreenEvents.filter {
      $0.value.journeyId != journey.id
    }
    if presentationTraceStates[journey.id] == nil {
      runtimeDelegates.removeValue(forKey: journey.id)
    }
    hostDismissalRetryAuthorizations.removeValue(forKey: journey.id)
    inMemoryJourneysById.removeValue(forKey: journey.id)
    let deleted = journeyStore.deleteJourney(id: journey.id)
    if !deleted && !terminalPersisted {
      LogError(
        "JourneyService: could not durably quarantine discarded journey \(journey.id)"
      )
    }
    if commit.revokedHostDismissalReservation,
       let originEventId = commit.previous.getContext("_origin_event_id") as? String {
      let state = commit.previous
      // The server owns the epoch, so no device exit/completion fact is
      // emitted. The host API contract is local, however: a dismissal already
      // requested by the host must still resolve its pending trigger waiter.
      await triggerBroker.emit(
        eventId: originEventId,
        update: .journey(JourneyUpdate(
          journeyId: journey.id,
          experienceId: journey.experienceId,
          experienceVersion: journey.experienceVersion,
          exitReason: .dismissed,
          goalMet: state.convertedAt != nil
        ))
      )
      guard !isShutDown else { return false }
    }
    return true
  }

  private func scheduleResume(journeyId: String, at date: Date) {
    guard !isShutDown else { return }
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

  @discardableResult
  private func persistJourney(_ state: JourneySnapshot) -> Bool {
    guard !isShutDown,
          inMemoryJourneysById[state.id] != nil else { return false }
    do {
      try journeyStore.saveJourney(state)
      return true
    } catch {
      LogError("Failed to persist journey \(state.id): \(error)")
      return false
    }
  }

  private func persistPresentationCommit(
    _ state: JourneySnapshot,
    for journey: Journey
  ) -> Bool {
    guard !isShutDown,
          inMemoryJourneysById[state.id] === journey,
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
    guard !isShutDown,
          inMemoryJourneysById[state.id] === journey,
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
    guard !isShutDown,
          inMemoryJourneysById[state.id] === journey,
          state.status.isLive,
          state.distinctId == journey.distinctId,
          journey.distinctId == identityService.getDistinctId() else { return false }
    do {
      try journeyStore.saveJourney(state)
      return true
    } catch {
      LogError("Failed to persist entry-action claim for journey \(state.id): \(error)")
      return false
    }
  }

  /// Persists runner fallback markers only while the service still owns the
  /// journey. This keeps retry recovery on the same checkpoint boundary as
  /// lifecycle updates and prevents stale runner snapshots from resurrecting
  /// a deleted journey.
  private func persistResponseRetryMarker(
    _ state: JourneySnapshot,
    for journey: Journey
  ) -> Bool {
    guard !isShutDown,
          inMemoryJourneysById[state.id] === journey,
          state.status.isLive,
          state.distinctId == journey.distinctId,
          journey.distinctId == identityService.getDistinctId() else { return false }
    do {
      try journeyStore.saveJourney(state)
      return true
    } catch {
      LogError("Failed to persist response retry marker for journey \(state.id): \(error)")
      return false
    }
  }

  private func enqueueParking(
    _ journey: JourneySnapshot,
    reason: JourneyParkingReason,
    pendingDeadlineAt: Date? = nil
  ) {
    guard !isShutDown,
          journey.status.isLive,
          !journey.isGhost else { return }
    eventLog.track(
      JourneyEvents.journeyParked,
      properties: JourneyEvents.journeyParkedProperties(
        journey: journey,
        reason: reason,
        pendingDeadlineAt: pendingDeadlineAt
      ),
      userProperties: nil,
      userPropertiesSetOnce: nil,
      distinctIdOverride: journey.distinctId
    )
  }

  private func completeJourney(
    _ journey: Journey,
    reason: JourneyExitReason,
    dismissedBy: JourneyDismissalSource? = nil
  ) async {
    guard !isShutDown else { return }
    guard completingJourneyIds.insert(journey.id).inserted else {
      if dismissedBy == .host {
        await waitForJourneyCompletionAttempt(journeyId: journey.id)
        await completeJourney(journey, reason: reason, dismissedBy: dismissedBy)
      }
      return
    }
    defer { finishJourneyCompletionAttempt(journeyId: journey.id) }

    let terminalAuthority: JourneyTerminalTransitionAuthority = dismissedBy == .host
      ? .host
      : .ordinary
    if terminalAuthority == .ordinary,
       await hasHostDismissalPriority(journey) {
      return
    }
    guard !isShutDown else { return }
    var state = await journey.snapshot()
    guard !isShutDown,
          state.status.isLive,
          inMemoryJourneysById[journey.id] === journey else {
      if dismissedBy == .host {
        await journey.releaseHostDismissalReservation()
      }
      return
    }

    if state.isGhost, terminalAuthority != .host {
      await discardLocalJourney(journey, terminalStatus: .superseded)
      return
    }

    guard let terminalState = await commitTerminalTransition(
      journey,
      reason: reason,
      authority: terminalAuthority
    ) else {
      guard !isShutDown else { return }
      if dismissedBy == .host {
        // Authorize the exact admitted attempt before yielding to release its
        // reservation. An identity change may interleave on that await; it
        // must retain this retryable journey, while unrelated old journeys
        // remain quarantined.
        if inMemoryJourneysById[journey.id] === journey {
          hostDismissalRetryAuthorizations[journey.id] = journey
        }
        await journey.releaseHostDismissalReservation()
        let retryState = await journey.snapshot()
        if inMemoryJourneysById[journey.id] !== journey || !retryState.status.isLive {
          if hostDismissalRetryAuthorizations[journey.id] === journey {
            hostDismissalRetryAuthorizations.removeValue(forKey: journey.id)
          }
        }
      }
      return
    }
    guard !isShutDown else { return }
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

    var hostExitCaptured = true
    if dismissedBy == .host {
      switch await capturePendingHostExit(state) {
      case .captured:
        hostExitCaptured = true
      case .failed:
        hostExitCaptured = false
        LogWarning("JourneyService: Failed to durably capture host journey exit")
      case .ownershipLost:
        guard !isShutDown else { return }
        // The server's ownership decision linearized before the stable exit
        // commit. Its callback normally performs this teardown while capture
        // is suspended; the fallback also covers restored tombstones whose
        // durable fence outlived the originating process.
        if inMemoryJourneysById[journey.id] === journey {
          _ = await discardLocalJourney(
            journey,
            terminalStatus: .superseded,
            authority: .authoritativeOwnershipLoss
          )
          guard !isShutDown else { return }
        } else {
          journeyStore.deleteJourney(id: journey.id)
        }
        return
      }
      guard !isShutDown else { return }
      // An authoritative ownership response may revoke the terminal host
      // tombstone while capture is suspended. Its teardown and trigger update
      // own the result; never continue completion accounting or emit twice.
      guard inMemoryJourneysById[journey.id] === journey else { return }
      await postDismissNotification(for: journey, reason: .hostDismissed)
      guard inMemoryJourneysById[journey.id] === journey else { return }
    }

    // The local terminal transition is already durable. Network abandonment
    // is deliberately attempted only after that commit, so a crash or retry
    // can never leave an active run with a locally abandoned response.
    let completingRunner = experienceRunners[journey.id]
    if let runner = completingRunner {
      await runner.abandonResponseDraftsIfNeeded(force: committedResponseAbandonment)
      guard !isShutDown else { return }
      if dismissedBy == .host {
        guard ownsHostCompletion(journey, runner: runner) else { return }
      }
    }

    if dismissedBy != .host {
      let exitedProperties = JourneyEvents.journeyExitedProperties(
        journey: state,
        reason: reason,
        at: state.completedAt ?? dateProvider.now(),
        dismissedBy: dismissedBy
      )
      do {
        _ = try await eventLog.trackWithResponse(
          JourneyEvents.journeyExited,
          properties: exitedProperties,
          flushStrategy: .eventLog,
          distinctIdOverride: state.distinctId
        )
      } catch {
        LogWarning("JourneyService: Failed to deliver journey exit: \(error)")
      }
      guard !isShutDown else { return }
    }

    let triggerCompletion: (eventId: String, update: TriggerUpdate)?
    if let originEventId = state.getContext("_origin_event_id") as? String {
      let update = JourneyUpdate(
        journeyId: journey.id,
        experienceId: journey.experienceId,
        experienceVersion: journey.experienceVersion,
        exitReason: reason,
        goalMet: state.convertedAt != nil
      )
      triggerCompletion = (originEventId, .journey(update))
    } else {
      triggerCompletion = nil
    }
    if let triggerCompletion, dismissedBy != .host {
      Task {
        await triggerBroker.emit(
          eventId: triggerCompletion.eventId,
          update: triggerCompletion.update
        )
      }
    }

    if dismissedBy == .host {
      guard ownsHostCompletion(journey, runner: completingRunner) else { return }
    }
    timerScheduler.cancelTasks(journeyId: journey.id)
    await completingRunner?.retire()
    guard !isShutDown else { return }
    if dismissedBy == .host {
      guard ownsHostCompletion(journey, runner: completingRunner) else { return }
    }
    experienceRunners.removeValue(forKey: journey.id)
    removeScreenControlRuntime(journeyId: journey.id)
    pendingScreenEvents = pendingScreenEvents.filter {
      $0.value.journeyId != journey.id
    }
    if presentationTraceStates[journey.id] == nil {
      runtimeDelegates.removeValue(forKey: journey.id)
    }
    hostDismissalRetryAuthorizations.removeValue(forKey: journey.id)
    inMemoryJourneysById.removeValue(forKey: journey.id)

    // Reentry accounting follows the durable terminal transition, not EventLog
    // availability. Keep the host tombstone until both obligations succeed,
    // but never reopen a one-time/once-per-window journey while capture waits
    // for recovery.
    let completionRecorded = recordCompletionIfNeeded(for: state)
    if dismissedBy != .host || hostExitCaptured && completionRecorded {
      journeyStore.deleteJourney(id: journey.id)
    }

    if let triggerCompletion, dismissedBy == .host {
      await triggerBroker.emit(
        eventId: triggerCompletion.eventId,
        update: triggerCompletion.update
      )
      guard !isShutDown else { return }
    }

    if dismissedBy == .host {
      await journey.releaseHostDismissalReservation()
    }
  }

  private func waitForJourneyCompletionAttempt(journeyId: String) async {
    guard completingJourneyIds.contains(journeyId) else { return }
    await withCheckedContinuation { continuation in
      journeyCompletionWaiters[journeyId, default: []].append(continuation)
    }
  }

  private func finishJourneyCompletionAttempt(journeyId: String) {
    completingJourneyIds.remove(journeyId)
    let waiters = journeyCompletionWaiters.removeValue(forKey: journeyId) ?? []
    waiters.forEach { $0.resume() }
  }

  private func retryPendingHostExitCaptures(
    in snapshots: [JourneySnapshot]? = nil
  ) async {
    guard !isShutDown else { return }
    let candidates = snapshots ?? journeyStore.loadActiveJourneys()
    for snapshot in candidates where snapshot.pendingHostExitCapture {
      guard !completingJourneyIds.contains(snapshot.id) else { continue }
      guard isRecoverablePendingHostExit(snapshot) else {
        LogError(
          "JourneyService: retaining malformed pending host exit \(snapshot.id)"
        )
        continue
      }
      switch await capturePendingHostExit(snapshot) {
      case .failed:
        guard !isShutDown else { return }
        continue
      case .ownershipLost:
        guard !isShutDown else { return }
        journeyStore.deleteJourney(id: snapshot.id)
        continue
      case .captured:
        break
      }
      guard !isShutDown else { return }
      let completionRecorded = recordCompletionIfNeeded(for: snapshot)
      if completionRecorded {
        journeyStore.deleteJourney(id: snapshot.id)
      }
    }
  }

  /// Completion accounting and the stable host exit form one recoverable
  /// terminal checkpoint. The store is idempotent by journey id, so a replay
  /// after either write is safe.
  private func recordCompletionIfNeeded(for state: JourneySnapshot) -> Bool {
    // Reentry accounting: only genuine completions (natural exit, goal met,
    // user dismissal) count against oneTime/oncePerWindow policies. A journey
    // killed by logout (.cancelled) or a load failure (.error) must not
    // permanently burn a one-time experience.
    switch state.exitReason {
    case .cancelled, .error:
      return true
    default:
      let record = JourneyCompletionRecord(journey: state, now: dateProvider.now())
      do {
        try journeyStore.recordCompletion(record)
        return true
      } catch {
        // A missed record loosens reentry (may re-show) rather than
        // permanently blocking — retain host tombstones for retry and log
        // other exits loudly instead of silently swallowing the failure.
        LogError("Failed to record journey completion for reentry accounting: \(error)")
        return false
      }
    }
  }

  private func isRecoverablePendingHostExit(_ state: JourneySnapshot) -> Bool {
    state.pendingHostExitCapture
      && state.status == .completed
      && state.exitReason == .dismissed
      && state.completedAt != nil
  }

  private func capturePendingHostExit(
    _ state: JourneySnapshot
  ) async -> DurableOwnedTriggerCaptureResult {
    guard isRecoverablePendingHostExit(state),
          let completedAt = state.completedAt else {
      LogError(
        "JourneyService: retaining malformed pending host exit \(state.id)"
      )
      return .failed
    }
    let exitedProperties = JourneyEvents.journeyExitedProperties(
      journey: state,
      reason: .dismissed,
      at: completedAt,
      dismissedBy: .host
    )
    let eventId = "journey-exited:\(state.id):\(state.epoch)"
    return await eventLog.captureOwnedJourneySystemEvent(
      JourneyEvents.journeyExited,
      properties: exitedProperties,
      eventId: eventId,
      distinctId: state.distinctId,
      ownership: JourneyEventOwnership(
        journeyId: state.id,
        epoch: state.epoch
      )
    )
  }

  /// Atomically commits terminal journey state and response abandonment in one
  /// snapshot CAS + persistence operation. Replays use the deterministic
  /// terminal transition receipt and therefore cannot advance the response
  /// version twice.
  private func commitTerminalTransition(
    _ journey: Journey,
    reason: JourneyExitReason,
    authority: JourneyTerminalTransitionAuthority
  ) async -> JourneySnapshot? {
    guard !isShutDown else { return nil }
    for _ in 0..<3 {
      if authority == .ordinary,
         await hasHostDismissalPriority(journey) {
        return nil
      }
      guard !isShutDown else { return nil }
      let versioned = await journey.versionedSnapshot()
      let state = versioned.snapshot
      guard !isShutDown,
            state.status.isLive,
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
      terminal.pendingHostExitCapture = authority == .host
      terminal.executionState.lifecycleGeneration &+= 1

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

      guard await journey.replaceForTerminalTransition(
        terminal,
        ifRevisionEquals: versioned.revision,
        authority: authority
      ) else {
        if authority == .ordinary,
           await hasHostDismissalPriority(journey) {
          return nil
        }
        continue
      }
      guard !isShutDown,
            inMemoryJourneysById[journey.id] === journey else { return nil }

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
           persisted?.completedAt == terminal.completedAt,
           persisted?.pendingHostExitCapture == terminal.pendingHostExitCapture {
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
          current.pendingHostExitCapture = state.pendingHostExitCapture
          current.executionState.lifecycleGeneration = state.executionState.lifecycleGeneration
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
    guard !isShutDown else { return [] }

    for experience in experiences {
      guard activeReferences.contains(ExperienceReference(
        experienceId: experience.id,
        versionId: experience.versionId
      )) else { continue }
      guard await shouldTriggerFromEvent(experience: experience, event: event) else { continue }
      guard !isShutDown else { return results }

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
        guard !isShutDown else { return results }
        results.append(.suppressed(reason))
        continue
      }
      guard !isShutDown else { return results }

      if let journey = await startJourneyInternal(
        for: experience,
        distinctId: event.distinctId,
        originEventId: event.id,
        presentationAttempt: presentationAttempt
      ) {
        results.append(.started(journey))
      } else {
        results.append(.error(TriggerError(
          code: .triggerFailed,
          message: "Failed to start journey for experience \(experience.id)"
        )))
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
    runner: JourneyRunner?,
    experience _: Experience?
  ) async -> Bool? {
    guard let journey else { return false }
    guard let runner,
          await ownsExecutableJourney(journey, runner: runner) else { return nil }
    let state = await journey.snapshot()
    guard await ownsExecutableJourney(journey, runner: runner),
          state.status.isLive else { return nil }
    let presentedJourneyId = await experiencePresentationService.presentedJourneyId
    guard await ownsExecutableJourney(journey, runner: runner) else { return nil }
    guard presentedJourneyId == journey.id else { return false }

    let closeReason: CloseReason = state.convertedAt != nil ? .goalMet : .userDismissed
    let controller = await runner.viewController
    guard await ownsExecutableJourney(journey, runner: runner) else { return nil }
    if let controller {
      await controller.prepareForDismissal(reason: closeReason)
      guard await ownsExecutableJourney(journey, runner: runner) else { return nil }
      await handleRuntimeDismiss(
        journeyId: journey.id,
        reason: closeReason,
        controller: controller
      )
      guard await ownsScopedCallbackContinuation(
        journey,
        runner: runner,
        sourceCompleted: true
      ) else { return nil }
      await experiencePresentationService.dismissCurrentExperience(reason: closeReason)
      guard await ownsScopedCallbackContinuation(
        journey,
        runner: runner,
        sourceCompleted: true
      ) else { return nil }
      return true
    }

    await experiencePresentationService.dismissCurrentExperience(reason: closeReason)
    guard await ownsExecutableJourney(journey, runner: runner) else { return nil }
    await completeJourney(
      journey,
      reason: dismissalExitReason(for: closeReason),
      dismissedBy: dismissalSource(for: closeReason)
    )
    guard await ownsScopedCallbackContinuation(
      journey,
      runner: runner,
      sourceCompleted: true
    ) else { return nil }
    return true
  }

  private func handleScopedGatePlan(
    _ plan: GatePlan?,
    sourceJourney: Journey? = nil,
    sourceExperience: Experience? = nil,
    sourceDistinctId: String
  ) async {
    guard !isShutDown, let plan else { return }
    let sourceRunner: JourneyRunner?
    if let sourceJourney {
      guard let runner = experienceRunners[sourceJourney.id],
            await ownsExecutableJourney(sourceJourney, runner: runner) else { return }
      sourceRunner = runner
    } else {
      sourceRunner = nil
    }

    func sourceRemainsAuthorized(completed: Bool = false) async -> Bool {
      guard !isShutDown else { return false }
      guard let sourceJourney else { return true }
      guard let sourceRunner else { return false }
      return await ownsScopedCallbackContinuation(
        sourceJourney,
        runner: sourceRunner,
        sourceCompleted: completed
      )
    }

    func closeSource() async -> Bool? {
      await closeSourceJourneyBeforeScopedGateExperienceIfNeeded(
        journey: sourceJourney,
        runner: sourceRunner,
        experience: sourceExperience
      )
    }

    switch plan.decision {
    case .allow, .deny:
      return

    case .showFlow:
      guard let experienceVersionId = plan.flowId else { return }
      guard let sourceCompleted = await closeSource(),
            await sourceRemainsAuthorized(completed: sourceCompleted) else { return }
      guard !isShutDown else { return }
      await presentDetachedExperience(
        experienceVersionId,
        ownerDistinctId: sourceDistinctId
      )

    case .requireFeature:
      guard let featureId = plan.featureId else { return }

      if plan.policy == .cacheOnly {
        let cached = await GatePlanEvaluation.cachedFeatureAccess(featureInfo, featureId: featureId)
        guard await sourceRemainsAuthorized() else { return }
        if GatePlanEvaluation.hasAccess(cached, requiredBalance: plan.requiredBalance) {
          return
        }
        return
      } else {
        let cached = await GatePlanEvaluation.cachedFeatureAccess(featureInfo, featureId: featureId)
        guard await sourceRemainsAuthorized() else { return }
        if let cached,
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
        guard await sourceRemainsAuthorized() else { return }
      }

      guard let experienceVersionId = plan.flowId else { return }
      guard let sourceCompleted = await closeSource(),
            await sourceRemainsAuthorized(completed: sourceCompleted) else { return }
      guard !isShutDown else { return }
      await presentDetachedExperience(
        experienceVersionId,
        ownerDistinctId: sourceDistinctId
      )
    }
  }

  // MARK: - Goals + Exit Policy

  private func evaluateGoalIfNeeded(
    _ journey: Journey,
    transientEvents: [StoredEvent] = []
  ) async {
    guard await ownsExecutableJourney(journey) else { return }
    let initialState = await journey.snapshot()
    guard await ownsExecutableJourney(journey) else { return }
    guard !initialState.isGhost else { return }
    guard initialState.convertedAt == nil else { return }
    guard initialState.goalSnapshot != nil else { return }

    let result = await goalEvaluator.isGoalMet(
      journey: initialState,
      transientEvents: transientEvents
    )
    guard await ownsExecutableJourney(journey) else { return }
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
      guard await ownsExecutableJourney(journey) else { return }
      let now = dateProvider.now()
      let convertedState = await journey.update { state in
        state.convertedAt = at
        state.setContext("_conversion_source_fact_ref", value: sourceFactRef, at: now)
        state.updatedAt = now
        return state
      }
      guard await ownsExecutableJourney(journey) else { return }
      persistJourney(convertedState)

      do {
        _ = try await eventLog.trackWithResponse(
          JourneyEvents.journeyConverted,
          properties: JourneyEvents.journeyConvertedProperties(
            journey: convertedState,
            at: at,
            sourceFactRef: sourceFactRef
          ),
          flushStrategy: .eventLog,
          distinctIdOverride: convertedState.distinctId
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
    distinctId: String,
    eventId: String? = nil,
    occurredAt: Date? = nil
  ) async -> ScopedEventStage {
    let enriched = await eventLog.prepareTriggerProperties(properties)
    let localEvent = NuxieEvent(
      id: eventId ?? UUID.v7().uuidString,
      name: name,
      distinctId: distinctId,
      properties: enriched,
      timestamp: occurredAt ?? dateProvider.now()
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
    persistToHistory: Bool = false,
    applyBeforeSend: Bool = false
  ) async -> (tracked: NuxieEvent, response: EventResponse?) {
    do {
      let tracked = try await eventLog.trackForTrigger(
        stage.localEvent.name,
        properties: properties,
        persistToHistory: persistToHistory,
        distinctIdOverride: stage.localEvent.distinctId,
        applyBeforeSend: applyBeforeSend
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
    let pendingHostCompletionAt: Date?
    switch experience.reentry {
    case .everyTime:
      pendingHostCompletionAt = nil
    case .oneTime, .oncePerWindow:
      let candidates = journeyStore.loadActiveJourneys().filter {
        $0.distinctId == distinctId
          && $0.experienceId == experience.id
          && isRecoverablePendingHostExit($0)
      }
      var ownedCompletionDates: [Date] = []
      for snapshot in candidates {
        // A retained host tombstone suppresses reentry only while this device
        // still might author its exit. EventLog unavailability retains that
        // conservative suppression; only confirmed ownership loss may reopen
        // enrollment and quarantine the stale snapshot.
        let ownership = JourneyEventOwnership(
          journeyId: snapshot.id,
          epoch: snapshot.epoch
        )
        switch await eventLog.journeyEventOwnershipState(ownership) {
        case .owned, .unavailable:
          guard !isShutDown else { return nil }
          if let completedAt = snapshot.completedAt {
            ownedCompletionDates.append(completedAt)
          }
        case .ownershipLost:
          guard !isShutDown else { return nil }
          if let retained = inMemoryJourneysById[snapshot.id],
             await discardLocalJourney(
               retained,
               terminalStatus: .superseded,
               authority: .authoritativeOwnershipLoss
             ) {
            continue
          }
          guard !isShutDown else { return nil }
          if !journeyStore.deleteJourney(id: snapshot.id) {
            LogError(
              "JourneyService: failed to delete quarantined persisted journey \(snapshot.id)"
            )
          }
        }
      }
      pendingHostCompletionAt = ownedCompletionDates.max()
    }
    return EnrollmentPolicy.suppressionReason(
      reentry: experience.reentry,
      hasLiveJourney: hasLiveJourney,
      hasCompleted: {
        pendingHostCompletionAt != nil
          || journeyStore.hasCompletedExperience(distinctId: distinctId, experienceId: experience.id)
      },
      lastCompletionAt: {
        let recorded = journeyStore.lastCompletionTime(
          distinctId: distinctId,
          experienceId: experience.id
        )
        return [recorded, pendingHostCompletionAt].compactMap { $0 }.max()
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
    presentationTraceContext: ExperiencePresentationTraceContext? = nil,
    requireCompleteCatalog: Bool = false
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
      } else if requireCompleteCatalog {
        // A durable commercial event cannot be acknowledged against a
        // partially loaded catalog: the missing package may contain the
        // Journey that should receive it. An authenticated empty reference
        // list remains an authoritative empty catalog.
        return nil
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

  /// Joins the full presentation teardown introduced for SDK shutdown, while
  /// optionally restricting it to a known set of customer-owned journeys.
  private func shutdownPresentedExperience(
    ownedBy journeyIds: Set<String>? = nil,
    detachedOwnerDistinctId: String? = nil
  ) async {
    guard let journeyIds else {
      await experiencePresentationService.shutdownCurrentExperience()
      detachedPresentationOwnerDistinctId = nil
      return
    }
    if await experiencePresentationService.isExperiencePresented {
      if let presentedJourneyId = await experiencePresentationService.presentedJourneyId {
        guard journeyIds.contains(presentedJourneyId) else { return }
      } else {
        guard self.detachedPresentationOwnerDistinctId == detachedOwnerDistinctId else {
          return
        }
      }
    }
    let detachedOwnerAtShutdown = self.detachedPresentationOwnerDistinctId
    await experiencePresentationService.shutdownCurrentExperience()
    if self.detachedPresentationOwnerDistinctId == detachedOwnerAtShutdown {
      self.detachedPresentationOwnerDistinctId = nil
    }
  }

  public func registerDetachedPresentationOwner(distinctId: String) async {
    detachedPresentationOwnerDistinctId = distinctId
  }

  private func presentDetachedExperience(
    _ experienceVersionId: String,
    ownerDistinctId: String
  ) async {
    detachedPresentationOwnerDistinctId = ownerDistinctId
    do {
      _ = try await experiencePresentationService.presentExperience(
        experienceVersionId,
        from: nil,
        runtimeDelegate: nil
      )
    } catch {
      if detachedPresentationOwnerDistinctId == ownerDistinctId {
        detachedPresentationOwnerDistinctId = nil
      }
    }
  }

  private func cancelOldCustomerResponseWork(oldDistinctId: String) async {
    let retiredSequences = pendingScopedAuthoredResponses.compactMap {
      $0.value.sourceJourney.distinctId == oldDistinctId ? $0.key : nil
    }
    retiredSequences.forEach { pendingScopedAuthoredResponses.removeValue(forKey: $0) }
    directlyHandledPreparedResponseSequences.formUnion(retiredSequences)
    scheduleReadyScopedAuthoredResponses()
    await eventLog.cancelPreparedResponseDeliveries(for: oldDistinctId)
    let oldTaskIds = Set(scopedAuthoredResponseOwners.compactMap {
      $0.value == oldDistinctId ? $0.key : nil
    })
    let responseTasks = scopedAuthoredResponseTasks.compactMap {
      oldTaskIds.contains($0.key) ? $0.value : nil
    }
    responseTasks.forEach { $0.cancel() }
    for task in responseTasks { await task.value }
  }

  private func teardownOldCustomerJourney(_ journey: Journey) async {
    timerScheduler.cancelTasks(journeyId: journey.id)
    hostDismissalRetryAuthorizations.removeValue(forKey: journey.id)
    await journey.releaseHostDismissalReservation()
    let preCancellationState = await journey.snapshot()
    await cancelJourney(journey)
    guard inMemoryJourneysById[journey.id] === journey,
          (await journey.snapshot()).status.isLive else { return }
    let exitedProperties = JourneyEvents.journeyExitedProperties(
      journey: preCancellationState,
      reason: .cancelled,
      at: dateProvider.now()
    )
    do {
      _ = try await eventLog.trackWithResponse(
        JourneyEvents.journeyExited,
        properties: exitedProperties,
        flushStrategy: .eventLog,
        distinctIdOverride: preCancellationState.distinctId
      )
    } catch {
      LogWarning(
        "JourneyService: failed to deliver identity-change exit for \(journey.id): \(error)"
      )
    }
    await discardLocalJourney(journey, terminalStatus: .cancelled)
  }

}

extension JourneyService: PresentationAttemptJourneyRouting {
  func handleEventForTrigger(
    _ event: NuxieEvent,
    presentationAttempt: ExperiencePresentationAttempt?
  ) async -> [JourneyTriggerResult] {
    await routeEvent(event, presentationAttempt: presentationAttempt) ?? []
  }
}
