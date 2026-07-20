import Foundation
import FactoryKit

/// Main entry point for the Nuxie SDK
public final class NuxieSDK {

  /// Shared singleton instance
  public static let shared = NuxieSDK()

  /// Private initializer to enforce singleton pattern
  private init() {
  }

  /// Current configuration (nil if not configured)
  private(set) public var configuration: NuxieConfiguration?

  /// Delegate for receiving SDK callbacks
  public weak var delegate: NuxieDelegate?

  /// Whether the SDK has been configured
  public var isSetup: Bool {
    if configuration == nil {
      LogWarning("SDK not configured. Call setup() first.")
    }
    return configuration != nil
  }

  // MARK: - Private Properties

  private let container = Container.shared

  private var lifecycleCoordinator: NuxieLifecycleCoordinator?

  private var eventSystemSetupTask: Task<Void, Never>?
  private var journeyInitializeTask: Task<Void, Never>?
  private var featureInfoDelegateTask: Task<Void, Never>?
  private var profilePrefetchTask: Task<Void, Never>?
  private var transactionObserverTask: Task<Void, Never>?
  private var identifyUserChangeTask: Task<Void, Never>?
  private var eventReassignTask: Task<Void, Never>?
  private var resetUserCleanupTask: Task<Void, Never>?
  private var resetFlowCleanupTask: Task<Void, Never>?

  // MARK: - Setup

  /// Setup the SDK (must be called before any other methods)
  /// - Parameter configuration: Configuration object
  /// - Throws: NuxieError if configuration is invalid
  public func setup(with configuration: NuxieConfiguration) throws {
    // Validate configuration
    guard !configuration.apiKey.isEmpty else {
      throw NuxieError.invalidConfiguration("API key cannot be empty")
    }

    guard configuration.environment != .custom || configuration.hasExplicitApiEndpoint else {
      throw NuxieError.invalidConfiguration(
        "environment == .custom requires setting configuration.apiEndpoint")
    }

    // Prevent reconfiguration
    guard self.configuration == nil else {
      LogWarning("SDK already configured. Skipping setup.")
      return
    }

    // Store configuration and register it FIRST before any service creation
    self.configuration = configuration
    container.sdkConfiguration.register { configuration }

    // Configure logger
    NuxieLogger.shared.configure(
      logLevel: configuration.logLevel,
      enableConsoleLogging: configuration.enableConsoleLogging,
      redactSensitiveData: configuration.redactSensitiveData
    )

    // Start lifecycle coordinator after configuration is registered.
    // The coordinator owns automatic lifecycle events ($app_installed etc.)
    // when enabled — the former plugin system's only real job.
    let lifecycleTracker = configuration.trackApplicationLifecycleEvents
      ? AppLifecycleTracker()
      : nil
    lifecycleCoordinator = NuxieLifecycleCoordinator(lifecycleTracker: lifecycleTracker)
    lifecycleCoordinator?.start()

    // Initialize event system
    LogDebug("Setting up event system...")
    let identityService = Container.shared.identityService()
    let contextBuilder = NuxieContextBuilder(
      identityService: identityService,
      configuration: configuration
    )

    let networkQueue = NuxieNetworkQueue(
      flushAt: configuration.flushAt,
      flushIntervalSeconds: configuration.flushInterval,
      maxQueueSize: configuration.maxQueueSize,
      maxBatchSize: configuration.eventBatchSize,
      maxRetries: configuration.retryCount,
      baseRetryDelay: configuration.retryDelay,
      apiClient: Container.shared.nuxieApi()
    )

    let eventService = Container.shared.eventService()
    let journeyService = Container.shared.journeyService()

    eventSystemSetupTask = Task {
      guard !Task.isCancelled else { return }
      do {
        try await eventService.configure(
          networkQueue: networkQueue,
          journeyService: journeyService,
          contextBuilder: contextBuilder,
          configuration: configuration
        )
        LogDebug("Event system setup complete")
      } catch {
        LogError("Event system setup failed: \(error)")
      }
    }

    journeyInitializeTask = Task {
      guard !Task.isCancelled else { return }
      await journeyService.initialize()
    }

    let isTestEnvironment = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    if !isTestEnvironment {
      // Wire up FeatureInfo delegate callback
      featureInfoDelegateTask = Task { @MainActor in
        guard !Task.isCancelled else { return }
        let featureInfo = container.featureInfo()
        featureInfo.onFeatureChange = { [weak self] featureId, oldValue, newValue in
          self?.delegate?.featureAccessDidChange(featureId, from: oldValue, to: newValue)
        }
      }

      // Fetch initial profile data and sync feature info
      profilePrefetchTask = Task {
        guard !Task.isCancelled else { return }
        do {
          _ = try await Container.shared.profileService().refetchProfile()
          guard !Task.isCancelled else { return }
          await Container.shared.featureService().syncFeatureInfo()
        }
        catch { LogWarning("Profile fetch failed: \(error)") }
      }

      // Start transaction observer to sync StoreKit 2 purchases with backend
      transactionObserverTask = Task {
        guard !Task.isCancelled else { return }
        await container.transactionObserver().startListening()
      }
    }

    LogInfo("Setup completed with API key: \(NuxieLogger.shared.logAPIKey(configuration.apiKey))")
  }

  /// Manually shut down the SDK and clean up resources
  /// This is typically not needed as the singleton will clean up automatically
  public func shutdown() async {
    guard isSetup else { return }

    // Stop background setup work to prevent it from touching disk during teardown.
    cleanupStartupTasks()

    // Stop transaction observer
    await container.transactionObserver().stopListening()

    await container.journeyService().shutdown()
    await container.eventService().close()
    await container.profileService().cleanupExpired()

    // Drop all cached instances in the SDK scope (they’ll be recreated on next setup)
    Container.shared.manager.reset(scope: .sdk)

    // API is managed by Factory container
    configuration = nil

    lifecycleCoordinator?.stop()
    lifecycleCoordinator = nil

    LogInfo("SDK shutdown completed")
  }

  // MARK: - Startup tasks

  private func cleanupStartupTasks() {
    eventSystemSetupTask?.cancel()
    journeyInitializeTask?.cancel()
    featureInfoDelegateTask?.cancel()
    profilePrefetchTask?.cancel()
    transactionObserverTask?.cancel()
    identifyUserChangeTask?.cancel()
    eventReassignTask?.cancel()
    resetUserCleanupTask?.cancel()
    resetFlowCleanupTask?.cancel()

    eventSystemSetupTask = nil
    journeyInitializeTask = nil
    featureInfoDelegateTask = nil
    profilePrefetchTask = nil
    transactionObserverTask = nil
    identifyUserChangeTask = nil
    eventReassignTask = nil
    resetUserCleanupTask = nil
    resetFlowCleanupTask = nil
  }

  // MARK: - Trigger (Event) API

  /// Trigger an event: tracks it, evaluates matching experiences, and may
  /// present a flow. Fire-and-forget; pass `handler` to observe progressive
  /// updates (gate decisions, journey lifecycle) for this specific trigger.
  public func trigger(
    _ event: String,
    properties: [String: Any]? = nil,
    userProperties: [String: Any]? = nil,
    userPropertiesSetOnce: [String: Any]? = nil,
    handler: ((TriggerUpdate) -> Void)? = nil
  ) {
    guard isSetup else { return }

    let triggerService = container.triggerService()
    Task { @MainActor in
      await triggerService.trigger(
        event,
        properties: properties,
        userProperties: userProperties,
        userPropertiesSetOnce: userPropertiesSetOnce
      ) { update in
        handler?(update)
      }
    }
  }

  /// Trigger an event and await its terminal outcome — the register pattern:
  ///
  /// ```swift
  /// switch await Nuxie.shared.triggerAndWait("export_tapped") {
  /// case .allowed: performExport()
  /// default: break
  /// }
  /// ```
  public func triggerAndWait(
    _ event: String,
    properties: [String: Any]? = nil,
    userProperties: [String: Any]? = nil,
    userPropertiesSetOnce: [String: Any]? = nil,
    progress: ((TriggerUpdate) -> Void)? = nil
  ) async -> TriggerResult {
    guard isSetup else { return .error(TriggerError(code: "not_configured", message: "SDK not configured")) }

    let triggerService = container.triggerService()
    return await withCheckedContinuation { (continuation: CheckedContinuation<TriggerResult, Never>) in
      let state = TriggerCompletionState()
      Task { @MainActor in
        await triggerService.trigger(
          event,
          properties: properties,
          userProperties: userProperties,
          userPropertiesSetOnce: userPropertiesSetOnce
        ) { update in
          progress?(update)
          if let result = NuxieSDK.terminalResult(for: update), state.claim() {
            continuation.resume(returning: result)
          } else if NuxieSDK.opensJourneyCompletion(update) {
            state.expectJourneyCompletion()
          }
        }
        // If the update sequence ended without a terminal update and no
        // journey is pending, resolve as tracked-with-no-match.
        if !state.isWaitingForJourneyCompletion, state.claim() {
          continuation.resume(returning: .noMatch)
        }
      }
    }
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

    /// Returns true exactly once — the caller that wins resumes the
    /// continuation.
    func claim() -> Bool {
      lock.lock()
      defer { lock.unlock() }
      guard !completed else { return false }
      completed = true
      return true
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
    guard isSetup else { return }
    
    let identityService = container.identityService()
    let eventService = container.eventService()
    
    let oldDistinctId = identityService.getDistinctId()
    let wasIdentified = identityService.isIdentified
    let hasDifferentDistinctId = distinctId != oldDistinctId
    
    // Set distinct ID for identified user
    identityService.setDistinctId(distinctId)
    
    let currentDistinctId = identityService.getDistinctId()
    LogInfo("Identifying user: \(NuxieLogger.shared.logDistinctID(currentDistinctId))")
    
    // Handle user change across all services if user changed
    if hasDifferentDistinctId {
      identifyUserChangeTask?.cancel()
      identifyUserChangeTask = Task {
        guard !Task.isCancelled else { return }
        // ProfileService handles its own cache transition
        let profileService = container.profileService()
        await profileService.handleUserChange(from: oldDistinctId, to: currentDistinctId)
        guard !Task.isCancelled else { return }

        // SegmentService needs to handle identity transition
        let segmentService = container.segmentService()
        await segmentService.handleUserChange(from: oldDistinctId, to: currentDistinctId)
        guard !Task.isCancelled else { return }

        // JourneyService needs to cancel old journeys and load new ones
        let journeyService = container.journeyService()
        await journeyService.handleUserChange(from: oldDistinctId, to: currentDistinctId)
        guard !Task.isCancelled else { return }

        // FeatureService needs to clear cache for new user
        let featureService = container.featureService()
        await featureService.handleUserChange(from: oldDistinctId, to: currentDistinctId)
      }
    }
    
    // Reassign anonymous events to identified user if transitioning from
    // anonymous (server handles in-flight events via $identify). Always on —
    // the industry-standard behavior; the old opt-out had no consumers.
    if !wasIdentified && hasDifferentDistinctId {
      eventReassignTask?.cancel()
      eventReassignTask = Task {
        guard !Task.isCancelled else { return }
        do {
          let reassignedCount = try await eventService.reassignEvents(from: oldDistinctId, to: currentDistinctId)
          guard !Task.isCancelled else { return }
          if reassignedCount > 0 {
            LogInfo("Migrated \(reassignedCount) anonymous events to identified user: \(NuxieLogger.shared.logDistinctID(currentDistinctId))")
          }
        } catch {
          // Non-blocking: log warning but continue with identify process
          LogWarning("Failed to reassign anonymous events: \(error)")
        }
      }
    }
    
    // Start a new session only when the user actually changed. Apps commonly
    // call identify() with the same id on every launch; rotating the session
    // each time fragments session analytics.
    if hasDifferentDistinctId {
      container.sessionService().startSession()
    }

    // Track $identify only when the user changed or there are user properties
    // to apply; a bare same-id re-identify is a no-op.
    let hasUserProperties = userProperties != nil || userPropertiesSetOnce != nil
    if hasDifferentDistinctId || hasUserProperties {
      var props: [String: Any] = ["distinct_id": currentDistinctId]
      if !wasIdentified, hasDifferentDistinctId {
        props["$anon_distinct_id"] = oldDistinctId
      }
      eventService.track(
        "$identify",
        properties: props,
        userProperties: userProperties,
        userPropertiesSetOnce: userPropertiesSetOnce
      )
    }
  }

  /// Reset user identity (logout)
  /// - Parameter keepAnonymousId: Whether to keep the anonymous ID (default: true)
  public func reset(keepAnonymousId: Bool = true) {
    guard isSetup else { return }
    
    let identityService = container.identityService()
    let previousDistinctId = identityService.getDistinctId()

    // Reset identity
    identityService.reset(keepAnonymousId: keepAnonymousId)

    // Clear data for previous user and handle transition to anonymous
    resetUserCleanupTask?.cancel()
    resetUserCleanupTask = Task {
      guard !Task.isCancelled else { return }
      let profileService = container.profileService()
      await profileService.clearCache(distinctId: previousDistinctId)
      guard !Task.isCancelled else { return }

      // Get the new distinct ID (will be anonymous ID after reset)
      let newDistinctId = identityService.getDistinctId()

      // Clear segment data for the previous user and handle user change
      let segmentService = container.segmentService()
      await segmentService.clearSegments(for: previousDistinctId)
      guard !Task.isCancelled else { return }
      await segmentService.handleUserChange(from: previousDistinctId, to: newDistinctId)
      guard !Task.isCancelled else { return }

      // Handle user change in JourneyService (cancel old journeys, load new)
      let journeyService = container.journeyService()
      await journeyService.handleUserChange(from: previousDistinctId, to: newDistinctId)
      guard !Task.isCancelled else { return }

      // Clear feature cache for the previous user
      let featureService = container.featureService()
      await featureService.clearCache()
    }

    // Start new session on reset
    container.sessionService().resetSession()
    
    // Clear flow cache
    resetFlowCleanupTask?.cancel()
    resetFlowCleanupTask = Task {
      guard !Task.isCancelled else { return }
      let flowService = container.flowService()
      await flowService.clearCache()
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
  @MainActor
  public var features: FeatureInfo {
    container.featureInfo()
  }


  // MARK: - Event History (Internal use for journey evaluation)

  /// Get recent events for journey evaluation
  /// - Parameter limit: Maximum events to return (default: 100)
  /// - Returns: Array of recent events or empty array if storage unavailable
  internal func getRecentEvents(limit: Int = 100) async -> [StoredEvent] {
    let eventService = container.eventService()
    return await eventService.getRecentEvents(limit: limit)
  }

  /// Get events for the current user
  /// - Parameter limit: Maximum events to return (default: 100)
  /// - Returns: Array of user events or empty array if storage unavailable
  internal func getCurrentUserEvents(limit: Int = 100) async -> [StoredEvent] {
    let identityService = container.identityService()
    let eventService = container.eventService()

    let distinctId = identityService.getDistinctId()
    return await eventService.getEventsForUser(distinctId, limit: limit)
  }

  /// Get events from the current session
  /// - Returns: Array of session events or empty array if storage unavailable
  internal func getCurrentSessionEvents() async -> [StoredEvent] {
    // Get current session ID
    guard let sessionId = container.sessionService().getSessionId(at: Date(), readOnly: true) else {
      return []
    }
    
    let eventService = container.eventService()
    return await eventService.getEvents(for: sessionId)
  }

  // MARK: - Session Management
  
  /// Get the current session ID
  /// - Returns: Current session ID or nil if no session exists
  ///
  /// Sessions are automatic (created on first event, rotated after 30 min
  /// idle / 24 h max). There is deliberately no manual session API.
  public func getCurrentSessionId() -> String? {
    guard isSetup else { return nil }
    return container.sessionService().getSessionId(at: Date(), readOnly: true)
  }

  // MARK: - Private Methods



  /// Get current distinct ID (always returns a value - anonymous ID if not identified)
  /// - Returns: Distinct ID if identified, anonymous ID otherwise
  public func getDistinctId() -> String {
    guard isSetup else { return "" }
    // IdentityService's getDistinctId() already returns anonymous ID as fallback
    let identityService = container.identityService()
    return identityService.getDistinctId()
  }

  /// Get anonymous ID
  /// - Returns: Anonymous ID (always available)
  public func getAnonymousId() -> String {
    guard isSetup else { return "" }
    let identityService = container.identityService()
    return identityService.getAnonymousId()
  }

  /// Check if user is currently identified
  /// - Returns: True if user has a distinct ID, false if anonymous
  public var isIdentified: Bool {
    guard isSetup else { return false }
    let identityService = container.identityService()
    return identityService.isIdentified
  }

  // MARK: - Experience Presentation

  /// Get a view controller for embedding an experience's screens yourself.
  /// - Parameter experienceId: The experience to present
  @MainActor
  public func experienceViewController(
    for experienceId: String,
    colorSchemeMode: FlowColorSchemeMode = .light
  ) async throws -> FlowViewController {
    guard isSetup else {
      throw NuxieError.notConfigured
    }

    let flowService = container.flowService()
    return try await flowService.viewController(
      for: experienceId,
      colorSchemeMode: colorSchemeMode
    )
  }

  /// Present an experience by ID in a dedicated window.
  @MainActor
  public func showExperience(
    _ experienceId: String,
    colorSchemeMode: FlowColorSchemeMode = .light
  ) async throws {
    guard isSetup else {
      throw NuxieError.notConfigured
    }

    let flowPresentationService = container.flowPresentationService()
    try await flowPresentationService.presentFlow(
      experienceId,
      from: nil,
      runtimeDelegate: nil,
      colorSchemeMode: colorSchemeMode
    )
  }

  // MARK: - Profile Management

  /// Refresh the user profile from the server
  /// Call this after changing `configuration.localeIdentifier` to fetch locale-specific content
  /// - Returns: The refreshed profile response
  /// - Throws: NuxieError if SDK not configured or network request fails
  @discardableResult
  public func refreshProfile() async throws -> ProfileResponse {
    guard isSetup else {
      throw NuxieError.notConfigured
    }

    let profileService = container.profileService()
    return try await profileService.refetchProfile()
  }

  // MARK: - Event System Public API

  /// Manually flush the network queue
  /// - Returns: True if flush was initiated
  @discardableResult
  public func flushEvents() async -> Bool {
    guard isSetup else { return false }
    let eventService = container.eventService()
    return await eventService.flushEvents()
  }

  /// Get current network queue size
  /// - Returns: Number of events queued for network delivery
  public func getQueuedEventCount() async -> Int {
    guard isSetup else { return 0 }
    let eventService = container.eventService()
    return await eventService.getQueuedEventCount()
  }

  /// Pause event queue (stops network delivery)
  public func pauseEventQueue() async {
    guard isSetup else { return }
    let eventService = container.eventService()
    await eventService.pauseEventQueue()
  }

  /// Resume event queue (enables network delivery)
  public func resumeEventQueue() async {
    guard isSetup else { return }
    let eventService = container.eventService()
    await eventService.resumeEventQueue()
  }

  // MARK: - Feature Access

  /// How a feature check resolves.
  public enum FeatureCheckPolicy {
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
    requiredBalance: Int = 1,
    entityId: String? = nil,
    policy: FeatureCheckPolicy = .cacheFirst
  ) async throws -> FeatureAccess {
    guard isSetup else {
      throw NuxieError.notConfigured
    }

    let featureService = container.featureService()
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
  /// Nuxie.shared.useFeature("ai_generations")
  ///
  /// // Consume 5 credits for a premium export
  /// Nuxie.shared.useFeature("export_credits", amount: 5)
  ///
  /// // Track per-project usage
  /// Nuxie.shared.useFeature("api_calls", amount: 1, entityId: "project-123")
  /// ```
  public func useFeature(
    _ featureId: String,
    amount: Double = 1,
    entityId: String? = nil,
    metadata: [String: Any]? = nil
  ) {
    guard isSetup else {
      LogWarning("useFeature called before SDK setup")
      return
    }

    Task {
      do {
        _ = try await useFeatureAndWait(
          featureId,
          amount: amount,
          entityId: entityId,
          metadata: metadata
        )
      } catch {
        LogWarning("useFeature failed: \(error)")
      }
    }
  }

  /// Report usage of a metered feature and wait for server confirmation.
  ///
  /// This method sends the usage directly to the server (blocking) and returns the result,
  /// including updated balance information. Use this when you need confirmation that the
  /// usage was recorded, such as for critical or irreversible operations.
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
  /// let result = try await Nuxie.shared.useFeatureAndWait("ai_generations")
  /// if result.success {
  ///     print("Remaining: \(result.usage?.remaining ?? 0)")
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
    guard isSetup else {
      throw NuxieError.notConfigured
    }

    let identityService = container.identityService()
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

    // Send directly to /i/event endpoint for immediate confirmation
    let api = container.nuxieApi()
    let response = try await api.trackEvent(
      event: "$feature_used",
      distinctId: distinctId,
      properties: properties,
      value: amount,
      entityId: entityId
    )

    // Update local balance from server response
    if let usage = response.usage, let remaining = usage.remaining {
      await MainActor.run {
        features.setBalance(featureId, balance: Int(remaining))
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
