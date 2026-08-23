import Foundation

/// Main entry point for the Nuxie SDK
// @unchecked Sendable: the singleton facade's graph state is isolated by
// SerializedSDKLifecycle. Delegate access retains its existing weak-reference
// semantics and SDK services provide their own concurrency isolation.
public final class NuxieSDK: @unchecked Sendable {

  /// Shared singleton instance
  public static let shared = NuxieSDK()

  /// Private initializer to enforce singleton pattern
  private init() {
  }

  private let sdkLifecycle = SerializedSDKLifecycle<NuxieSDKRun>()

  /// Configuration builder supplied to the current run (nil if unavailable).
  /// Its values are snapshotted during setup; mutating it later does not
  /// reconfigure the SDK. Use the explicit runtime controls below.
  var configuration: NuxieConfiguration? {
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
    try setup(with: configuration, overrides: .init())
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

    guard configuration.environment != .custom || configuration.hasExplicitApiEndpoint else {
      throw NuxieError.invalidConfiguration(
        "environment == .custom requires setting configuration.apiEndpoint")
    }

    try NuxieConfigurationValidator.validate(configuration)

    let setupConfiguration = NuxieSetupConfiguration(configuration)
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
        overrides: overrides
      )

      // Start the lifecycle coordinator over the built graph. It owns
      // automatic lifecycle events ($app_installed etc.) when enabled — the
      // former plugin system's only real job.
      let lifecycleTracker = setupConfiguration.trackApplicationLifecycleEvents
        ? AppLifecycleTracker(eventSink: core.systemEvents)
        : nil
      let lifecycleCoordinator = NuxieLifecycleCoordinator(
        lifecycleTracker: lifecycleTracker,
        sessions: core.sessions,
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
        do {
          try await eventLog.configure(
            configuration: setupConfiguration.eventLogConfiguration()
          )
          LogDebug("Event system setup complete")
        } catch {
          LogError("Event system setup failed: \(error)")
        }
      }

      let journeyInitializeTask = Task {
        guard !Task.isCancelled else { return }
        await journeyService.initialize()
      }

      let isTestEnvironment =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
      var featureInfoDelegateTask: Task<Void, Never>?
      var profilePrefetchTask: Task<Void, Never>?
      var transactionObserverTask: Task<Void, Never>?

      if !isTestEnvironment {
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
      }

      return NuxieSDKRun(
        configuration: configuration,
        core: core,
        lifecycleCoordinator: lifecycleCoordinator,
        eventSystemSetupTask: eventSystemSetupTask,
        journeyInitializeTask: journeyInitializeTask,
        featureInfoDelegateTask: featureInfoDelegateTask,
        profilePrefetchTask: profilePrefetchTask,
        transactionObserverTask: transactionObserverTask,
        facadeTaskStartBarrier: facadeTaskStartBarrier
      )
    }

    guard installed else {
      LogWarning("SDK already configured. Skipping setup.")
      return
    }

    LogInfo("Setup completed with API key: \(NuxieLogger.shared.logAPIKey(setupConfiguration.apiKey))")
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

      // Cancel startup callers first, then stop the observer before joining
      // those callers. A profile-prefetch caller may already be awaiting
      // purchase recovery, which only observer shutdown can cancel and settle.
      await Self.stopPurchasesAndAwaitStartupTasks(
        run.startupTasks + facadeTasks,
        stopPurchases: { await core.transactionObserver.stopListening() }
      )
    }) { run in
      let core = run.core
      // Run queued identity transitions to completion before tearing down the
      // services they fan out to (the coordinator chain is deliberately
      // uncancellable — dropping transitions was the bug it exists to fix).
      await core.userTransitions.drain()

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
  /// updates (gate decisions, journey lifecycle) for this specific trigger.
  public func trigger(
    _ event: String,
    properties: [String: Any]? = nil,
    userProperties: [String: Any]? = nil,
    userPropertiesSetOnce: [String: Any]? = nil,
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
    let userPropertiesBox = UncheckedSendable(userProperties)
    let userPropertiesSetOnceBox = UncheckedSendable(userPropertiesSetOnce)
    let launched = run.launchFacadeTask { @MainActor [operation] in
      defer { operation.finish() }
      if let presentationAttempt,
         let tracedTriggerService = triggerService as? any PresentationAttemptTriggerServiceProtocol {
        await tracedTriggerService.trigger(
          event,
          properties: propertiesBox.value,
          userProperties: userPropertiesBox.value,
          userPropertiesSetOnce: userPropertiesSetOnceBox.value,
          presentationAttempt: presentationAttempt
        ) { update in
          handler?(update)
        }
      } else {
        await triggerService.trigger(
          event,
          properties: propertiesBox.value,
          userProperties: userPropertiesBox.value,
          userPropertiesSetOnce: userPropertiesSetOnceBox.value
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
  /// switch await NuxieSDK.shared.triggerAndWait("export_tapped") {
  /// case .allowed: performExport()
  /// default: break
  /// }
  /// ```
  /// An active journey that is still awaiting a terminal update when SDK
  /// shutdown begins resolves as an error whose code is `sdk_shutdown`.
  public func triggerAndWait(
    _ event: String,
    properties: [String: Any]? = nil,
    userProperties: [String: Any]? = nil,
    userPropertiesSetOnce: [String: Any]? = nil,
    progress: (@Sendable (TriggerUpdate) -> Void)? = nil
  ) async -> TriggerResult {
    guard let operation = runningOperation() else {
      return .error(TriggerError(code: "not_configured", message: "SDK not configured"))
    }
    defer { operation.finish() }
    let run = operation.graph
    let core = run.core

    let presentationAttempt = beginPresentationAttemptIfEnabled(
      triggerEvent: event,
      core: core
    )
    let triggerService = core.triggers
    // Boxed: property payloads are write-once snapshots handed to the SDK.
    let propertiesBox = UncheckedSendable(properties)
    let userPropertiesBox = UncheckedSendable(userProperties)
    let userPropertiesSetOnceBox = UncheckedSendable(userPropertiesSetOnce)
    return await withCheckedContinuation { (continuation: CheckedContinuation<TriggerResult, Never>) in
      let state = TriggerCompletionState()
      let launched = run.launchFacadeTask { @MainActor in
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
            userProperties: userPropertiesBox.value,
            userPropertiesSetOnce: userPropertiesSetOnceBox.value,
            presentationAttempt: presentationAttempt,
            handler: handleUpdate
          )
        } else {
          await triggerService.trigger(
            event,
            properties: propertiesBox.value,
            userProperties: userPropertiesBox.value,
            userPropertiesSetOnce: userPropertiesSetOnceBox.value,
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
                code: "sdk_shutdown",
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
          code: "not_configured",
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
      case .allowedImmediate: return .allowed(source: nil)
      case .deniedImmediate: return .denied
      case .noMatch: return .noMatch
      default: return nil
      }
    case .entitlement(let entitlement):
      switch entitlement {
      case .allowed(let source): return .allowed(source: source)
      case .denied: return .denied
      case .pending: return nil
      }
    case .journey(let update):
      return .journeyCompleted(update)
    }
  }

  private static func opensJourneyCompletion(_ update: TriggerUpdate) -> Bool {
    guard case .decision(let decision) = update else { return false }
    switch decision {
    case .journeyStarted, .journeyResumed:
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
    
    let oldDistinctId = identityService.getDistinctId()
    let wasIdentified = identityService.isIdentified
    let hasDifferentDistinctId = distinctId != oldDistinctId
    
    // Set distinct ID for identified user
    identityService.setDistinctId(distinctId)
    
    let currentDistinctId = identityService.getDistinctId()
    LogInfo("Identifying user: \(NuxieLogger.shared.logDistinctID(currentDistinctId))")
    
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
    }
    
    // Start a new session only when the user actually changed. Apps commonly
    // call identify() with the same id on every launch; rotating the session
    // each time fragments session analytics.
    if hasDifferentDistinctId {
      core.sessions.startSession()
    }

    // Track $identify only when the user changed or there are user properties
    // to apply; a bare same-id re-identify is a no-op.
    let hasUserProperties = userProperties != nil || userPropertiesSetOnce != nil
    if hasDifferentDistinctId || hasUserProperties {
      var props: [String: Any] = ["distinct_id": currentDistinctId]
      if !wasIdentified, hasDifferentDistinctId {
        props["$anon_distinct_id"] = oldDistinctId
      }
      eventLog.track(
        SystemEventNames.identify,
        properties: props,
        userProperties: userProperties,
        userPropertiesSetOnce: userPropertiesSetOnce
      )
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
    let previousDistinctId = identityService.getDistinctId()

    // Reset identity
    identityService.reset(keepAnonymousId: keepAnonymousId)

    // Serialized, uncancellable transition (interleaves FIFO with identify).
    let newDistinctId = identityService.getDistinctId()
    core.userTransitions.enqueue(
      UserTransitionCoordinator.Transition(
        kind: .reset,
        from: previousDistinctId,
        to: newDistinctId,
        migrateEvents: false
      ))

    // Start new session on reset before transferring the operation lease to
    // the asynchronous transition drain.
    core.sessions.resetSession()

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

  /// Get events from the current session
  /// - Returns: Array of session events or empty array if storage unavailable
  internal func getCurrentSessionEvents() async -> [StoredEvent] {
    guard let operation = runningOperation() else { return [] }
    defer { operation.finish() }
    let run = operation.graph
    let core = run.core
    // Get current session ID
    guard let sessionId = core.sessions.getSessionId(at: Date(), readOnly: true) else {
      return []
    }
    
    return await core.eventLog.getEvents(for: sessionId)
  }

  // MARK: - Session Management
  
  /// Get the current session ID
  /// - Returns: Current session ID or nil if no session exists
  ///
  /// Sessions are automatic (created on first event, rotated after 30 min
  /// idle / 24 h max). There is deliberately no manual session API.
  public func getCurrentSessionId() -> String? {
    guard let operation = runningOperation() else { return nil }
    defer { operation.finish() }
    return operation.graph.core.sessions.getSessionId(at: Date(), readOnly: true)
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

  /// Refresh the user profile from the server
  /// Uses the locale selected during setup or by `setLocaleIdentifier`.
  /// - Throws: NuxieError if SDK not configured or network request fails
  public func refreshProfile() async throws {
    guard let operation = runningOperation() else {
      throw NuxieError.notConfigured
    }
    defer { operation.finish() }

    let profileService = operation.graph.core.profile
    _ = try await profileService.refetchProfile()
  }

  // MARK: - Event System Public API

  /// Manually flush the network queue
  /// - Returns: True if flush was initiated
  @discardableResult
  public func flushEvents() async -> Bool {
    guard let operation = runningOperation() else { return false }
    defer { operation.finish() }
    let eventLog = operation.graph.core.eventLog
    return await eventLog.flushEvents()
  }

  /// Get current network queue size
  /// - Returns: Number of events queued for network delivery
  public func getQueuedEventCount() async -> Int {
    guard let operation = runningOperation() else { return 0 }
    defer { operation.finish() }
    let eventLog = operation.graph.core.eventLog
    return await eventLog.getQueuedEventCount()
  }

  /// Pause event queue (stops network delivery)
  public func pauseEventQueue() async {
    guard let operation = runningOperation() else { return }
    defer { operation.finish() }
    let eventLog = operation.graph.core.eventLog
    await eventLog.pauseEventQueue()
  }

  /// Resume event queue (enables network delivery)
  public func resumeEventQueue() async {
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
  /// - Throws: NuxieError if SDK not configured or request fails
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

    // Build properties for $feature_used event
    var properties: [String: Any] = [
      "feature_extId": featureId
    ]

    if setUsage {
      properties["setUsage"] = true
    }

    if let metadata = metadata {
      properties["metadata"] = metadata
    }

    if !setUsage,
       let purchaseBackedResult = try await core.transactionObserver
        .useFeatureWithPendingPurchase(
          distinctId: distinctId,
          featureId: featureId,
          amount: amount,
          entityId: entityId,
          metadata: metadata?.mapValues(AnyCodable.init)
        ) {
      return purchaseBackedResult
    }

    guard identityService.getDistinctId() == distinctId else {
      throw CancellationError()
    }

    // Send directly to /i/event endpoint for immediate confirmation
    let api = core.api
    // Boxed to hand the write-once payload across the API boundary.
    let propertiesBox = UncheckedSendable(properties)
    let response = try await api.trackEvent(
      event: SystemEventNames.featureUsed,
      distinctId: distinctId,
      properties: propertiesBox.value,
      value: amount,
      entityId: entityId
    )

    guard identityService.getDistinctId() == distinctId else {
      throw CancellationError()
    }

    // Update local balance from server response
    if let usage = response.usage, let remaining = usage.remaining {
      await MainActor.run {
        core.featureInfo.setBalance(featureId, balance: remaining)
      }
    }

    // Build result from response
    return FeatureUsageResult(
      success: response.status == "ok" || response.status == "success",
      featureId: featureId,
      amountUsed: amount,
      message: response.message,
      usage: response.usage.map { usage in
        FeatureUsageResult.UsageInfo(
          current: usage.current,
          limit: usage.limit,
          remaining: usage.remaining
        )
      }
    )
  }

}
