import Foundation

/// Main entry point for the Nuxie SDK
// @unchecked Sendable: all lifecycle state is isolated by
// SerializedSDKLifecycle. The public delegate retains its existing weak
// callback-slot semantics, and referenced SDK services own their isolation.
public final class NuxieSDK: @unchecked Sendable {

  /// Shared singleton instance
  public static let shared = NuxieSDK()

  /// Private initializer to enforce singleton pattern
  private init() {
  }

  private let sdkLifecycle = SerializedSDKLifecycle<NuxieSDKRun>()

  /// Immutable configuration snapshot for the current run.
  var configuration: NuxieSetupConfiguration? {
    sdkLifecycle.snapshot()?.graph.configuration
  }

  /// Delegate for receiving SDK callbacks
  public weak var delegate: NuxieDelegate?

  /// Whether the SDK has been configured
  public var isSetup: Bool {
    let isRunning = sdkLifecycle.isRunning
    if !isRunning {
      LogWarning("SDK not configured. Call setup() first.")
    }
    return isRunning
  }

  // MARK: - Private Properties

private func runningOperation() -> SerializedSDKLifecycle<NuxieSDKRun>.Operation? {
    guard let operation = sdkLifecycle.beginOperation() else {
      LogWarning("SDK not configured. Call setup() first.")
      return nil
    }
    return operation
  }

  /// Composition root built by setup. Internal test hosts may inspect the
  /// currently running graph, but production operations hold a lifecycle
  /// lease for their whole call.
  var core: NuxieCore? {
    sdkLifecycle.snapshot()?.graph.core
  }

  // MARK: - Setup

  /// Setup the SDK (must be called before any other methods)
  /// - Parameter configuration: Configuration object
  /// - Throws: NuxieError if configuration is invalid
  public func setup(with configuration: NuxieConfiguration) throws {
    try setup(
      with: configuration,
      overrides: .init(presentationDiagnosticsEnabled: false)
    )
  }

  /// Internal seam: tests inject mock services through `overrides`.
  internal func setup(
    with configuration: NuxieConfiguration,
    overrides: NuxieCoreOverrides,
    facadeTaskStartBarrier: (@Sendable () async -> Void)? = nil
  ) throws {
    // Validate configuration
    guard !configuration.apiKey.isEmpty else {
      throw NuxieError.invalidConfiguration("API key cannot be empty")
    }

    if configuration.testStoreEnabled {
#if !os(iOS)
      throw NuxieError.invalidConfiguration(
        "testStoreEnabled is supported only on iOS"
      )
#else
      guard configuration.environment == .development else {
        throw NuxieError.invalidConfiguration(
          "testStoreEnabled requires environment == .development"
        )
      }
      guard configuration.apiKey.hasPrefix("pk_test_") else {
        throw NuxieError.invalidConfiguration(
          "testStoreEnabled requires a pk_test_ API key"
        )
      }
#endif
    }

    let setupConfiguration = NuxieSetupConfiguration(configuration)
    try NuxieConfigurationValidator.validate(
      setupConfiguration.internalConfiguration
    )
    let runtimeSettings = NuxieRuntimeSettings(
      localeIdentifier: configuration.localeIdentifier,
      purchaseDelegate: configuration.purchaseDelegate,
      purchaseHandlingMode: configuration.purchaseHandlingMode
    )

    let installed = sdkLifecycle.install {
      // Configure logger only for the graph that wins installation.
      NuxieLogger.shared.configure(
        logLevel: setupConfiguration.logLevel,
        enableConsoleLogging: setupConfiguration.enableConsoleLogging,
        redactSensitiveData: setupConfiguration.redactSensitiveData
      )

      // Build the composition root: the whole object graph, in explicit
      // dependency order. The facade's stable FeatureInfo instance rides in
      // unless a test injected its own.
      var overrides = overrides
      if overrides.featureInfo == nil { overrides.featureInfo = featureInfoInstance }
      let core = NuxieCore(
        configuration: setupConfiguration,
        runtimeSettings: runtimeSettings,
        appActionHandler: { [weak self] action in
          self?.deliverAppAction(action)
        },
        overrides: overrides
      )

      // Start the lifecycle coordinator over the built graph. It always owns
      // automatic lifecycle events; customers can filter them with beforeSend.
      let lifecycleTracker = AppLifecycleTracker(eventSink: core.systemEvents)
      let lifecycleCoordinator = NuxieLifecycleCoordinator(
        lifecycleTracker: lifecycleTracker,
        journeys: core.journeys,
        eventLog: core.eventLog,
        profile: core.profile,
        experiences: core.experiences,
        experiencePresentation: core.experiencePresentation,
        features: core.features
      )
      lifecycleCoordinator.start()

      // Initialize event system. The journey router subscribes to committed
      // events BEFORE the log opens — capture commands buffer until configure
      // finishes, so the subscriber observes every committed event.
      LogDebug("Setting up event system...")
      let eventLog = core.eventLog
      let journeyService = core.journeys

      let eventSystemSetupTask = Task {
        guard !Task.isCancelled else { return }
        await eventLog.subscribeCommitted { [weak journeyService] event in
          await journeyService?.handleEvent(event)
        }
        await eventLog.subscribeForwarding(
          when: { [weak self] in self?.delegate != nil }
        ) { [weak self, weak journeyService] durable in
          await self?.deliverForwardedActivity(
            durable,
            journeyService: journeyService
          )
        }
        do {
          try await eventLog.configure(configuration: setupConfiguration)
          LogDebug("Event system setup complete")
        } catch {
          LogError("Event system setup failed: \(error)")
        }
      }

      let journeyInitializeTask = Task {
        guard !Task.isCancelled else { return }
        await journeyService.initialize()
      }

      var featureInfoDelegateTask: Task<Void, Never>?
      var profilePrefetchTask: Task<Void, Never>?
      var transactionObserverTask: Task<Void, Never>?
      var featureCommandRecoveryTask: Task<Void, Never>?

      if !setupConfiguration.internalConfiguration.suppressBackgroundWork {
        // Wire up FeatureInfo delegate callback
        featureInfoDelegateTask = Task { @MainActor in
          guard !Task.isCancelled else { return }
          let featureInfo = core.featureInfo
          featureInfo.onFeatureChange = { [weak self] featureId, oldValue, newValue in
            self?.delegate?.featureAccessDidChange(featureId, from: oldValue, to: newValue)
          }
        }

        // Fetch initial profile data and sync feature info
        profilePrefetchTask = Task {
          await Self.runProfilePrefetch(
            refetch: { _ = try await core.profile.refetchProfile() },
            recoverProfileDependentState: {
              await Self.recoverAfterProfilePrefetch(
                journeys: journeyService
              )
            },
            syncFeatures: { await core.features.syncFeatureInfo() }
          )
        }

        // Start transaction observer to sync StoreKit 2 purchases with backend
        transactionObserverTask = Task {
          guard !Task.isCancelled else { return }
          await core.transactionObserver.startListening()
        }
        let eventSetup = eventSystemSetupTask
        let profilePrefetch = profilePrefetchTask
        featureCommandRecoveryTask = Task {
          await eventSetup.value
          await profilePrefetch?.value
          guard !Task.isCancelled else { return }
          await core.featureUseCommands.recover()
        }
      }

      return NuxieSDKRun(
        configuration: setupConfiguration,
        core: core,
        lifecycleCoordinator: lifecycleCoordinator,
        eventSystemSetupTask: eventSystemSetupTask,
        journeyInitializeTask: journeyInitializeTask,
        featureInfoDelegateTask: featureInfoDelegateTask,
        profilePrefetchTask: profilePrefetchTask,
        transactionObserverTask: transactionObserverTask,
        featureCommandRecoveryTask: featureCommandRecoveryTask,
        facadeTaskStartBarrier: facadeTaskStartBarrier
      )
    }

    guard installed else {
      LogWarning("SDK already configured. Skipping setup.")
      return
    }

    LogInfo("Setup completed with API key: \(NuxieLogger.shared.logAPIKey(setupConfiguration.apiKey))")
  }

  @MainActor
  func deliverAppAction(_ action: AppAction) {
    delegate?.nuxie(self, didRequestAppAction: action)
  }

  private func deliverForwardedActivity(
    _ durable: DurableForwardingEvent,
    journeyService: JourneyServiceProtocol?
  ) async {
    // Keep curation and the public envelope unallocated when no observer is
    // attached. A delegate attached later receives only subsequent activity.
    guard delegate != nil else { return }
    var properties = durable.event.properties
    if durable.event.forwardingName == JourneyEvents.journeySuperseded,
       properties["experience_id"] == nil,
       let journeyId = properties["journey_id"] as? String,
       let ref = await journeyService?.forwardingExperienceRef(for: journeyId) {
      properties["experience_id"] = ref.experienceId
      if let version = ref.experienceVersion {
        properties["experience_version"] = version
      }
    }
    guard let activity = ActivityCuration.activity(
      internalName: durable.event.forwardingName,
      properties: properties
    ) else { return }
    let info = NuxieActivityInfo(
      id: durable.event.id,
      timestamp: durable.event.timestamp,
      receivedAt: durable.receivedAt,
      activity: activity
    )
    await MainActor.run { [weak self] in
      self?.delegate?.nuxieDidEmit(info)
    }
  }

  /// Manually shut down the SDK and clean up resources
  /// This is typically not needed as the singleton will clean up automatically
  public func shutdown() async {
    await sdkLifecycle.shutdown(beforeDraining: { run in
      let core = run.core

      // Close NotificationCenter intake before any service teardown and join
      // the one FIFO lifecycle worker so it cannot fan out into a closed graph.
      await run.lifecycleCoordinator.stop()

      let facadeTasks = run.stopAcceptingFacadeTasksAndCancel()
      // Stop recovery admission now, but join it only after admitted public
      // feature operations drain and queue closure can settle its in-flight wait.
      run.featureCommandRecoveryTask?.cancel()

      // Cancel startup callers first, then stop the observer before joining
      // those callers. A profile-prefetch caller may already be awaiting
      // purchase recovery, which only observer shutdown can cancel and settle.
      await Self.stopPurchasesAndAwaitStartupTasks(
        run.preDrainStartupTasks + facadeTasks,
        stopPurchases: { await core.transactionObserver.stopListening() }
      )
    }) { run in
      let core = run.core
      // Run queued identity transitions to completion before tearing down the
      // services they fan out to (the coordinator chain is deliberately
      // uncancellable — dropping transitions was the bug it exists to fix).
      await core.userTransitions.drain()

      // Public feature operations are lifecycle leases and have now drained.
      // Closing earlier would turn a suspended admitted call into an escaping
      // CancellationError instead of letting it finish against this graph.
      await core.featureUseCommands.close()
      await run.featureCommandRecoveryTask?.value
      await core.journeys.shutdown()
      await core.eventLog.close()
      await core.profile.cleanupExpired()

      LogInfo("SDK shutdown completed")
    }
  }

  // MARK: - Startup tasks

  /// Retry Journey state after the startup profile attempt. Product authority
  /// admission independently wakes StoreKit recovery when its authenticated
  /// ownership catalog materially changes, including later refresh, locale,
  /// foreground, and mailbox paths.
  static func recoverAfterProfilePrefetch(
    journeys: JourneyServiceProtocol
  ) async {
    guard !Task.isCancelled else { return }
    await journeys.retryRestoredPresentations()
  }

  static func runProfilePrefetch(
    refetch: @escaping @Sendable () async throws -> Void,
    recoverProfileDependentState: @escaping @Sendable () async -> Void,
    syncFeatures: @escaping @Sendable () async -> Void
  ) async {
    guard !Task.isCancelled else { return }
    do {
      try await refetch()
      guard !Task.isCancelled else { return }
      await recoverProfileDependentState()
      guard !Task.isCancelled else { return }
      await syncFeatures()
    } catch is CancellationError {
      return
    } catch {
      guard !Task.isCancelled else { return }
      LogWarning("Profile fetch failed: \(error)")
      await recoverProfileDependentState()
    }
  }

  static func stopPurchasesAndAwaitStartupTasks(
    _ tasks: [Task<Void, Never>],
    stopPurchases: @escaping @Sendable () async -> Void
  ) async {
    tasks.forEach { $0.cancel() }
    await stopPurchases()
    for task in tasks { await task.value }
  }

  /// Waits for the SDK-owned event and journey startup tasks. Internal test
  /// hosts use this instead of invoking service initialization a second time,
  /// which would create competing restored Journey objects for one durable ID.
  func waitForStartupTasks() async {
    guard let operation = runningOperation() else { return }
    defer { operation.finish() }
    let run = operation.graph
    await run.eventSystemSetupTask.value
    await run.journeyInitializeTask.value
  }

  // MARK: - Trigger (Event) API

  /// Trigger an event: tracks it, evaluates matching experiences, and may
  /// present an experience. Fire-and-forget; pass `handler` to observe progressive
  /// updates (routing decisions and journey lifecycle) for this trigger.
  public func trigger(
    _ event: String,
    properties: [String: Any]? = nil,
    handler: (@Sendable (TriggerUpdate) -> Void)? = nil
  ) {
    guard let operation = runningOperation() else { return }
    let run = operation.graph
    let core = run.core

    let presentationAttempt = beginPresentationAttemptIfEnabled(
      triggerEvent: event,
      core: core
    )
    let triggerService = core.triggers
    // Boxed: property payloads are write-once snapshots handed to the SDK.
    let propertiesBox = UncheckedSendable(properties)
    let launched = run.launchFacadeTask { @MainActor [operation] in
      defer { operation.finish() }
      if let presentationAttempt,
         let tracedTriggerService = triggerService as? any PresentationAttemptTriggerServiceProtocol {
        await tracedTriggerService.trigger(
          event,
          properties: propertiesBox.value,
          presentationAttempt: presentationAttempt
        ) { update in
          handler?(update)
        }
      } else {
        await triggerService.trigger(
          event,
          properties: propertiesBox.value
        ) { update in
          handler?(update)
        }
      }
    }
    if !launched {
      operation.finish()
    }
  }

  /// Trigger an event and await its terminal outcome — the register pattern:
  ///
  /// ```swift
  /// let result = await NuxieSDK.shared.triggerAndWait("export_tapped")
  /// ```
  /// An active journey that is still awaiting a terminal update when SDK
  /// shutdown begins resolves as an error whose code is `trigger_failed`.
  public func triggerAndWait(
    _ event: String,
    properties: [String: Any]? = nil,
    progress: (@Sendable (TriggerUpdate) -> Void)? = nil
  ) async -> TriggerResult {
    guard let operation = runningOperation() else {
      return .error(TriggerError(code: .notConfigured, message: "SDK not configured"))
    }
    let run = operation.graph
    let core = run.core

    let presentationAttempt = beginPresentationAttemptIfEnabled(
      triggerEvent: event,
      core: core
    )
    let triggerService = core.triggers
    // Boxed: property payloads are write-once snapshots handed to the SDK.
    let propertiesBox = UncheckedSendable(properties)
    return await withCheckedContinuation { (continuation: CheckedContinuation<TriggerResult, Never>) in
      let state = TriggerCompletionState()
      let launched = run.launchFacadeTask { @MainActor [operation] in
        defer { operation.finish() }
        let handleUpdate: @Sendable (TriggerUpdate) -> Void = { update in
          progress?(update)
          if let result = NuxieSDK.terminalResult(for: update), state.claim() {
            continuation.resume(returning: result)
          } else if NuxieSDK.opensJourneyCompletion(update) {
            state.expectJourneyCompletion()
          }
        }
        if let presentationAttempt,
           let tracedTriggerService = triggerService as? any PresentationAttemptTriggerServiceProtocol {
          await tracedTriggerService.trigger(
            event,
            properties: propertiesBox.value,
            presentationAttempt: presentationAttempt,
            handler: handleUpdate
          )
        } else {
          await triggerService.trigger(
            event,
            properties: propertiesBox.value,
            handler: handleUpdate
          )
        }
        // If the update sequence ended without a terminal update and no
        // journey is pending, resolve as tracked-with-no-match. A journey's
        // terminal update may arrive after TriggerService returns, so keep
        // this SDK-owned worker registered until that update or shutdown.
        if state.isWaitingForJourneyCompletion {
          await state.waitForCompletion {
            if state.claim() {
              continuation.resume(returning: .error(TriggerError(
                code: .triggerFailed,
                message: "SDK shutdown began before the journey completed"
              )))
            }
          }
        } else if state.claim() {
          continuation.resume(returning: .noMatch)
        }
      }
      if !launched {
        continuation.resume(returning: .error(TriggerError(
          code: .notConfigured,
          message: "SDK shutdown began before trigger work started"
        )))
      }
    }
  }

  private func beginPresentationAttemptIfEnabled(
    triggerEvent: String,
    core: NuxieCore
  ) -> ExperiencePresentationAttempt? {
    guard core.presentationTrace.isEnabled else { return nil }
    let startedAt = core.dateProvider.now()
    let timestamp = ExperiencePresentationTimestamp.now(wallClock: startedAt)
    let attempt = ExperiencePresentationAttempt.make(
      triggerEvent: triggerEvent,
      startedAt: startedAt,
      startedAtMonotonicTime: timestamp.monotonicTime
    )
    ExperiencePresentationTraceContext(
      attempt: attempt,
      recorder: core.presentationTrace
    ).recordTriggerAcceptedAndBeginRouting(at: timestamp)
    return attempt
  }

  /// Terminal-state classification for triggerAndWait. Runs on the MainActor
  /// callback path only (TriggerCompletionState guards double-resume).
  private static func terminalResult(for update: TriggerUpdate) -> TriggerResult? {
    switch update {
    case .error(let error):
      return .error(error)
    case .decision(let decision):
      switch decision {
      case .noMatch: return .noMatch
      default: return nil
      }
    case .journey(let update):
      return .journeyCompleted(update)
    }
  }

  private static func opensJourneyCompletion(_ update: TriggerUpdate) -> Bool {
    guard case .decision(let decision) = update else { return false }
    switch decision {
    case .journeyStarted:
      return true
    default:
      return false
    }
  }

  /// Lock-based completion bookkeeping for triggerAndWait. The update
  /// callback runs on the TriggerService actor's executor, not the main
  /// actor, so this must be executor-agnostic (the old stream plumbing
  /// mutated captured locals across executors — a data race).
  private final class TriggerCompletionState: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var waitingForJourney = false
    private var completionWaiters: [CheckedContinuation<Void, Never>] = []

    /// Returns true exactly once — the caller that wins resumes the
    /// continuation.
    func claim() -> Bool {
      let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>]? in
        guard !completed else { return nil }
        completed = true
        let waiters = completionWaiters
        completionWaiters.removeAll()
        return waiters
      }
      waiters?.forEach { $0.resume() }
      return waiters != nil
    }

    func expectJourneyCompletion() {
      lock.lock()
      waitingForJourney = true
      lock.unlock()
    }

    var isWaitingForJourneyCompletion: Bool {
      lock.lock()
      defer { lock.unlock() }
      return waitingForJourney
    }

    /// Keeps the facade worker owned until the journey callback reaches a
    /// terminal result. Cancelling that worker is SDK shutdown's signal to
    /// settle the public continuation and release its lifecycle operation.
    func waitForCompletion(
      onCancel: @escaping @Sendable () -> Void
    ) async {
      await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
          let alreadyCompleted = lock.withLock { () -> Bool in
            guard !completed else { return true }
            completionWaiters.append(continuation)
            return false
          }
          if alreadyCompleted {
            continuation.resume()
          }
        }
      } onCancel: {
        onCancel()
      }
    }
  }

  // MARK: - User Management
  
  /// Identify the current user with optional properties
  /// - Parameters:
  ///   - distinctId: Unique user identifier
  ///   - userProperties: Properties to set on the user profile (mapped to $set)
  ///   - userPropertiesSetOnce: Properties to set once on the user profile (mapped to $set_once)
  public func identify(
    _ distinctId: String,
    userProperties: [String: Any]? = nil,
    userPropertiesSetOnce: [String: Any]? = nil
  ) {
    guard let operation = runningOperation() else { return }
    let run = operation.graph
    let core = run.core
    
    let identityService = core.identity
    let eventLog = core.eventLog

    let hasUserProperties = userProperties != nil || userPropertiesSetOnce != nil
    let userPropertiesBox = UncheckedSendable(userProperties)
    let userPropertiesSetOnceBox = UncheckedSendable(userPropertiesSetOnce)
    let admission = IdentityPublicationAdmission()

    // Enqueue and capture are synchronous, callback-free admission steps. They
    // must precede the projection publication (the only reentrant step), so a
    // nested identify/reset cannot supersede either transition's durable work.
    let publication = UncheckedSendable<@MainActor (IdentityTransition) -> Void>(
      { transition in
        let oldDistinctId = transition.previous.distinctId
        let wasIdentified = transition.previous.isIdentified
        let currentDistinctId = transition.current.distinctId
        let hasDifferentDistinctId = currentDistinctId != oldDistinctId

        // Serialized, uncancellable transition across all per-user state
        // (anonymous-event migration included). A rapid second identify() or
        // reset() queues behind this one instead of cancelling it mid-fan-out.
        if hasDifferentDistinctId {
          core.userTransitions.enqueue(
            UserTransitionCoordinator.Transition(
              kind: .identify,
              from: oldDistinctId,
              to: currentDistinctId,
              migrateEvents: !wasIdentified
            ))
          admission.shouldLaunchTransitionDrain = true
        }

        // Track $identify only when the user changed or there are user properties
        // to apply; a bare same-id re-identify is a no-op.
        if hasDifferentDistinctId || hasUserProperties {
          var props: [String: Any] = ["distinct_id": currentDistinctId]
          if !wasIdentified, hasDifferentDistinctId {
            props["$anon_distinct_id"] = oldDistinctId
          }
          eventLog.track(
            SystemEventNames.identify,
            properties: props,
            userProperties: userPropertiesBox.value,
            userPropertiesSetOnce: userPropertiesSetOnceBox.value
          )
          admission.shouldLaunchTransitionDrain = true
        }

        // Publication is deliberately last: synchronous observers may identify
        // or reset reentrantly and supersede only this transition's currency.
        core.featureInfo.setProjectionDistinctId(currentDistinctId)
      }
    )
    let transition = mutateIdentityPublishing(
      identityService,
      .identify(distinctId),
      publication: publication
    )

    if let transition {
      LogInfo(
        "Identifying user: \(NuxieLogger.shared.logDistinctID(transition.current.distinctId))"
      )
    }

    if admission.shouldLaunchTransitionDrain {
      let launched = run.launchFacadeTask { [operation] in
        defer { operation.finish() }
        await run.core.userTransitions.drain()
        await run.core.transactionObserver.retryStoredEvidence()
      }
      if !launched {
        operation.finish()
      }
    } else {
      operation.finish()
    }
  }

  /// Reset user identity (logout).
  /// - Parameter keepAnonymousId: Keep the device's anonymous ID (default:
  ///   false — a fresh anonymous id is generated so the next user's
  ///   pre-identify events never chain to the previous person, matching
  ///   PostHog/Amplitude semantics)
  public func reset(keepAnonymousId: Bool = false) {
    guard let operation = runningOperation() else { return }
    let run = operation.graph
    let core = run.core
    
    let identityService = core.identity

    // Reset has no event capture, but its transition admission is equally
    // durable and therefore precedes the reentrant projection publication.
    let publication = UncheckedSendable<@MainActor (IdentityTransition) -> Void>(
      { transition in
        core.userTransitions.enqueue(
          UserTransitionCoordinator.Transition(
            kind: .reset,
            from: transition.previous.distinctId,
            to: transition.current.distinctId,
            migrateEvents: false
          ))

        // Publication is deliberately last; supersession does not retract the
        // transition that was already admitted above.
        core.featureInfo.setProjectionDistinctId(transition.current.distinctId)
      }
    )
    _ = mutateIdentityPublishing(
      identityService,
      .reset(keepAnonymousId: keepAnonymousId),
      publication: publication
    )

    let launched = run.launchFacadeTask { [operation] in
      defer { operation.finish() }
      await run.core.userTransitions.drain()
      await run.core.transactionObserver.retryStoredEvidence()
    }
    if !launched {
      operation.finish()
    }
  }


  // MARK: - Utility

  /// Get current SDK version
  public var version: String {
    SDKVersion.current
  }

  /// Observable feature info for SwiftUI
  ///
  /// Use this in SwiftUI views for reactive updates when features change:
  /// ```swift
  /// struct MyView: View {
  ///     @ObservedObject var features = NuxieSDK.shared.features
  ///
  ///     var body: some View {
  ///         if features.isAllowed("premium_feature") {
  ///             PremiumContent()
  ///         }
  ///     }
  /// }
  /// ```
  /// One stable instance across the SDK's lifetime so SwiftUI views that
  /// captured it before setup keep observing the live object afterwards
  /// (setup passes it into the composition root).
  private let featureInfoInstance = FeatureInfo()

  @MainActor
  public var features: FeatureInfo {
    sdkLifecycle.snapshot()?.graph.core.featureInfo ?? featureInfoInstance
  }


  // MARK: - Event History (Internal use for journey evaluation)

  /// Get recent events for journey evaluation
  /// - Parameter limit: Maximum events to return (default: 100)
  /// - Returns: Array of recent events or empty array if storage unavailable
  internal func getRecentEvents(limit: Int = 100) async -> [StoredEvent] {
    guard let operation = runningOperation() else { return [] }
    defer { operation.finish() }
    return await operation.graph.core.eventLog.getRecentEvents(limit: limit)
  }

  /// Get events for the current user
  /// - Parameter limit: Maximum events to return (default: 100)
  /// - Returns: Array of user events or empty array if storage unavailable
  internal func getCurrentUserEvents(limit: Int = 100) async -> [StoredEvent] {
    guard let operation = runningOperation() else { return [] }
    defer { operation.finish() }
    let run = operation.graph
    let identityService = run.core.identity
    let eventLog = run.core.eventLog

    let distinctId = identityService.getDistinctId()
    return await eventLog.getEventsForUser(distinctId, limit: limit)
  }

  // MARK: - Private Methods



  /// Get current distinct ID (always returns a value - anonymous ID if not identified)
  /// - Returns: Distinct ID if identified, anonymous ID otherwise
  public func getDistinctId() -> String {
    guard let operation = runningOperation() else { return "" }
    defer { operation.finish() }
    // IdentityService's getDistinctId() already returns anonymous ID as fallback
    let identityService = operation.graph.core.identity
    return identityService.getDistinctId()
  }

  /// Get anonymous ID
  /// - Returns: Anonymous ID (always available)
  public func getAnonymousId() -> String {
    guard let operation = runningOperation() else { return "" }
    defer { operation.finish() }
    let identityService = operation.graph.core.identity
    return identityService.getAnonymousId()
  }

  /// Check if user is currently identified
  /// - Returns: True if user has a distinct ID, false if anonymous
  public var isIdentified: Bool {
    guard let operation = runningOperation() else { return false }
    defer { operation.finish() }
    let identityService = operation.graph.core.identity
    return identityService.isIdentified
  }

  // MARK: - Experience Presentation

  /// Dismiss the currently presented Nuxie experience, if any.
  @MainActor
  public func dismiss() async {
    guard let operation = runningOperation() else { return }
    defer { operation.finish() }
    await operation.graph.core.experiencePresentation
      .dismissCurrentExperienceFromHost()
  }

  /// Present a profile-delivered experience version for the E2E harness.
  /// - Parameter versionId: The profile-delivered experience version to present.
  @_spi(Testing)
  @MainActor
  public func presentExperienceVersionForTesting(_ versionId: String) async throws {
    guard let operation = runningOperation() else {
      throw NuxieError.notConfigured
    }
    defer { operation.finish() }
    _ = try await operation.graph.core.experiencePresentation.presentExperience(
      versionId,
      from: nil,
      runtimeDelegate: nil,
      colorSchemeMode: .system
    )
  }

  // MARK: - Profile Management

  /// Change the locale used for subsequent profile requests and immediately
  /// refresh locale-specific content. Pass nil to follow the device locale.
  public func setLocaleIdentifier(_ localeIdentifier: String?) async throws {
    guard let operation = runningOperation() else { throw NuxieError.notConfigured }
    defer { operation.finish() }
    let core = operation.graph.core
    core.runtimeSettings.setLocaleIdentifier(localeIdentifier)
    _ = try await core.profile.refetchProfile()
    await core.features.syncFeatureInfo()
  }

  /// Replace the purchase delegate used by future purchase and restore calls.
  public func setPurchaseDelegate(_ purchaseDelegate: NuxiePurchaseDelegate?) throws {
    guard let operation = runningOperation() else { throw NuxieError.notConfigured }
    defer { operation.finish() }
    let core = operation.graph.core
    core.runtimeSettings.setPurchaseDelegate(purchaseDelegate)
  }

  /// Change ownership of future observed StoreKit transaction finishing.
  public func setPurchaseHandlingMode(
    _ purchaseHandlingMode: NuxieConfiguration.PurchaseHandlingMode
  ) throws {
    guard let operation = runningOperation() else { throw NuxieError.notConfigured }
    defer { operation.finish() }
    let core = operation.graph.core
    core.runtimeSettings.setPurchaseHandlingMode(purchaseHandlingMode)
  }

  // MARK: - Internal Event Queue Controls

  /// Manually flush the network queue
  /// - Returns: True if flush was initiated
  @discardableResult
  internal func flushEvents() async -> Bool {
    guard let operation = runningOperation() else { return false }
    defer { operation.finish() }
    let eventLog = operation.graph.core.eventLog
    return await eventLog.flushEvents()
  }

  /// Get current network queue size
  /// - Returns: Number of events queued for network delivery
  internal func getQueuedEventCount() async -> Int {
    guard let operation = runningOperation() else { return 0 }
    defer { operation.finish() }
    let eventLog = operation.graph.core.eventLog
    return await eventLog.getQueuedEventCount()
  }

  /// Pause event queue (stops network delivery)
  internal func pauseEventQueue() async {
    guard let operation = runningOperation() else { return }
    defer { operation.finish() }
    let eventLog = operation.graph.core.eventLog
    await eventLog.pauseEventQueue()
  }

  /// Resume event queue (enables network delivery)
  internal func resumeEventQueue() async {
    guard let operation = runningOperation() else { return }
    defer { operation.finish() }
    let eventLog = operation.graph.core.eventLog
    await eventLog.resumeEventQueue()
  }

  // MARK: - Feature Access

  /// How a feature check resolves.
  public enum FeatureCheckPolicy: Sendable {
    /// Serve from cache when fresh; hit the server otherwise (default).
    case cacheFirst
    /// Always ask the server (authoritative; use for critical operations).
    case remote

    /// Canonical wrapper encoding pinned by
    /// `fixtures/encodings/feature-usage.json`.
    @_spi(Testing)
    public var wireValue: String {
      switch self {
      case .cacheFirst: "cacheFirst"
      case .remote: "remote"
      }
    }
  }

  /// Check whether the user has access to a feature.
  /// For metered features, checks the balance against `requiredBalance`.
  /// For instant cache-only reads (e.g. SwiftUI), use `features` instead.
  public func hasFeature(
    _ featureId: String,
    requiredBalance: Double = 1,
    entityId: String? = nil,
    policy: FeatureCheckPolicy = .cacheFirst
  ) async throws -> FeatureAccess {
    guard let operation = runningOperation() else {
      throw NuxieError.notConfigured
    }
    defer { operation.finish() }

    let featureService = operation.graph.core.features
    switch policy {
    case .cacheFirst:
      return try await featureService.checkWithCache(
        featureId: featureId,
        requiredBalance: requiredBalance,
        entityId: entityId,
        forceRefresh: false
      )
    case .remote:
      let result = try await featureService.check(
        featureId: featureId,
        requiredBalance: requiredBalance,
        entityId: entityId
      )
      return FeatureAccess(from: result)
    }
  }

  // MARK: - Feature Usage

  /// Report usage of a metered feature in the background.
  ///
  /// Feature usage is an authoritative command, so it is never sent through the background
  /// batch queue. Prefer `useFeatureAndWait` when the caller needs the confirmed result.
  ///
  /// This convenience method sends the confirmed usage request on a background task and logs
  /// failures. Local balance is reconciled only from the server response.
  ///
  /// - Parameters:
  ///   - featureId: The feature identifier (external ID configured in Nuxie dashboard)
  ///   - amount: The amount to consume (default: 1)
  ///   - entityId: Optional entity ID for entity-based limits (e.g., per-project usage)
  ///   - metadata: Optional additional metadata to record with the usage event
  ///
  /// - Example:
  /// ```swift
  /// // Consume 1 unit of "ai_generations" feature
  /// NuxieSDK.shared.useFeature("ai_generations")
  ///
  /// // Consume 5 credits for a premium export
  /// NuxieSDK.shared.useFeature("export_credits", amount: 5)
  ///
  /// // Track per-project usage
  /// NuxieSDK.shared.useFeature("api_calls", amount: 1, entityId: "project-123")
  /// ```
  public func useFeature(
    _ featureId: String,
    amount: Double = 1,
    entityId: String? = nil,
    metadata: [String: Any]? = nil
  ) {
    guard let operation = runningOperation() else {
      LogWarning("useFeature called before SDK setup")
      return
    }
    let run = operation.graph

    // Boxed: metadata is a write-once snapshot handed to the SDK.
    let metadataBox = UncheckedSendable(metadata)
    let launched = run.launchFacadeTask { [operation] in
      defer { operation.finish() }
      do {
        _ = try await self.useFeatureAndWait(
          featureId,
          amount: amount,
          entityId: entityId,
          metadata: metadataBox.value,
          run: run
        )
      } catch {
        LogWarning("useFeature failed: \(error)")
      }
    }
    if !launched {
      operation.finish()
    }
  }

  /// Report usage of a metered feature and wait for server confirmation.
  ///
  /// This method sends the usage directly to the server (blocking) and returns the result,
  /// including updated balance information. Use this when you need confirmation that the
  /// usage was recorded, such as for critical or irreversible operations.
  /// When one unsynchronized native App Store purchase matches the Feature, the SDK
  /// verifies that purchase and consumes this usage atomically. The returned
  /// `authoritativeAccess` then contains the resulting server-authoritative balance.
  ///
  /// - Parameters:
  ///   - featureId: The feature identifier (external ID configured in Nuxie dashboard)
  ///   - amount: The amount to consume (default: 1)
  ///   - entityId: Optional entity ID for entity-based limits (e.g., per-project usage)
  ///   - setUsage: If true, sets the usage to the specified amount instead of decrementing (default: false)
  ///   - metadata: Optional additional metadata to record with the usage event
  /// - Returns: FeatureUsageResult with usage confirmation and updated balance
  /// - Throws: `CancellationError` if the active identity changes before the
  ///   usage command is durably admitted, or `NuxieError` if the SDK is not
  ///   configured or the request fails.
  ///
  /// - Example:
  /// ```swift
  /// // Consume and confirm usage
  /// let result = try await NuxieSDK.shared.useFeatureAndWait("ai_generations")
  /// if result.success {
  ///     let remaining = result.authoritativeAccess?.balance
  ///         ?? result.usage?.remaining
  ///     print("Remaining: \(remaining ?? 0)")
  /// }
  /// ```
  @discardableResult
  public func useFeatureAndWait(
    _ featureId: String,
    amount: Double = 1,
    entityId: String? = nil,
    setUsage: Bool = false,
    metadata: [String: Any]? = nil
  ) async throws -> FeatureUsageResult {
    guard let operation = runningOperation() else {
      throw NuxieError.notConfigured
    }
    defer { operation.finish() }

    return try await useFeatureAndWait(
      featureId,
      amount: amount,
      entityId: entityId,
      setUsage: setUsage,
      metadata: metadata,
      run: operation.graph
    )
  }

  private func useFeatureAndWait(
    _ featureId: String,
    amount: Double,
    entityId: String?,
    setUsage: Bool = false,
    metadata: [String: Any]?,
    run: NuxieSDKRun
  ) async throws -> FeatureUsageResult {
    let core = run.core

    let identityService = core.identity
    let distinctId = identityService.getDistinctId()

    if !setUsage,
       let purchaseBackedResult = try await core.transactionObserver
        .useFeatureWithPendingPurchase(
          distinctId: distinctId,
          featureId: featureId,
          amount: amount,
          entityId: entityId,
          metadata: metadata?.mapValues(AnyCodable.init)
        ) {
      if purchaseBackedResult.success {
        await captureAcceptedFeatureUse(
          featureId: featureId,
          amount: amount,
          entityId: entityId,
          metadata: metadata,
          eventId: nil,
          distinctId: distinctId,
          eventLog: core.eventLog
        )
      }
      return purchaseBackedResult
    }

    guard identityService.getDistinctId() == distinctId else {
      throw CancellationError()
    }

    let metadataBox = UncheckedSendable(metadata)
    return try await core.featureUseCommands.use(
      distinctId: distinctId,
      featureId: featureId,
      amount: amount,
      entityId: entityId,
      setUsage: setUsage,
      metadata: metadataBox.value
    )
  }

  /// Runs the identity mutation and its synchronous publication on MainActor.
  /// The caller owns publication ordering; projection switching must be its
  /// final step because it can synchronously reenter identify/reset.
  private final class IdentityPublicationAdmission: @unchecked Sendable {
    // Written by the synchronous MainActor publication and read only after the
    // same-thread call or DispatchQueue.main.sync returns.
    var shouldLaunchTransitionDrain = false
  }

  private func mutateIdentityPublishing(
    _ identityService: IdentityServiceProtocol,
    _ mutation: IdentityMutation,
    publication: UncheckedSendable<@MainActor (IdentityTransition) -> Void>
  ) -> IdentityTransition? {
    if Thread.isMainThread {
      return MainActor.assumeIsolated {
        identityService.mutateIdentity(mutation, publishing: publication.value)
      }
    } else {
      return DispatchQueue.main.sync {
        MainActor.assumeIsolated {
          identityService.mutateIdentity(mutation, publishing: publication.value)
        }
      }
    }
  }

  private func captureAcceptedFeatureUse(
    featureId: String,
    amount: Double,
    entityId: String?,
    metadata: [String: Any]?,
    eventId: String?,
    distinctId: String,
    eventLog: EventLogProtocol
  ) async {
    var captureProperties: [String: Any] = [
      "feature_id": featureId,
      "amount": amount,
    ]
    if let entityId { captureProperties["entity_id"] = entityId }
    if let metadata { captureProperties["metadata"] = metadata }
    let capturePropertiesBox = UncheckedSendable(captureProperties)
    let enriched = await eventLog.prepareTriggerProperties(capturePropertiesBox.value)
    let exactEvent = NuxieEvent(
      id: eventId ?? UUID.v7().uuidString,
      name: SystemEventNames.featureUsed,
      distinctId: distinctId,
      properties: enriched
    )
    if let prepared = await eventLog.applyBeforeSend(to: exactEvent) {
      await eventLog.storePreparedEventInHistory(prepared)
    }
  }

}
