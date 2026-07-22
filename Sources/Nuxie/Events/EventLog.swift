import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - StoreReadySignal (fileprivate)

/// Emits once when the event store has finished initializing; callers wait() before touching storage.
fileprivate actor StoreReadySignal {
  private var opened = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func isOpen() -> Bool { opened }

  func open() {
    guard !opened else { return }
    opened = true
    let toResume = waiters
    waiters.removeAll()
    toResume.forEach { $0.resume() }
  }

  func wait() async {
    if opened { return }
    await withCheckedContinuation { cont in
      waiters.append(cont)
    }
  }
}

/// Close state readable from nonisolated (synchronous) entry points.
private final class CloseFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var closed = false

  var isClosed: Bool {
    lock.lock()
    defer { lock.unlock() }
    return closed
  }

  /// Returns true when this call performed the open → closed transition.
  func close() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if closed { return false }
    closed = true
    return true
  }
}

// MARK: - Commands processed by the capture worker

private struct TrackPayload {
  let name: String
  let properties: [String: Any]
  let forcedDistinctId: String  // snapshot at call site
}

private enum CaptureCommand {
  case track(TrackPayload)
  case flush(CheckedContinuation<Bool, Never>)
  case barrier(CheckedContinuation<Void, Never>)  // test-only: "drain until here"
  case shutdown
}

private enum RouteCommand {
  case event(NuxieEvent)
  case barrier(CheckedContinuation<Void, Never>)
  case shutdown
}

public enum EventFlushStrategy: Equatable {
  case none
  case eventLog
  case networkQueue
}

/// A committed-event subscriber callback. Invoked in commit order, after the
/// event is persisted (pending delivery) and staged for the network.
public typealias CommittedEventHandler = @Sendable (NuxieEvent) async -> Void

/// Protocol for the unified event log: capture → enrich → persist → deliver → query.
public protocol EventLogProtocol: AnyObject {
  /// Configure the log with the SDK configuration. Builds enrichment and
  /// delivery from the configuration and opens storage.
  func configure(configuration: NuxieConfiguration?) async throws

  /// Subscribe to committed events. Handlers run serially, in subscription
  /// order, after each event is persisted and staged for delivery. The
  /// filter runs before the handler; pass nil to receive every event.
  /// Subscribers registered before `configure` are guaranteed to observe
  /// every committed event.
  func subscribeCommitted(
    where filter: (@Sendable (NuxieEvent) -> Bool)?,
    handler: @escaping CommittedEventHandler
  ) async

  func onAppDidEnterBackground() async
  func onAppBecameActive() async

  /// Track an event with optional user properties (main async entry point)
  func track(
    _ event: String,
    properties: [String: Any]?,
    userProperties: [String: Any]?,
    userPropertiesSetOnce: [String: Any]?
  )

  /// Build the enriched trigger properties that local journey evaluation should use before the
  /// synchronous trigger tracking round trip completes.
  func prepareTriggerProperties(
    _ properties: [String: Any]?,
    userProperties: [String: Any]?,
    userPropertiesSetOnce: [String: Any]?
  ) async -> [String: Any]

  /// Persist a fully prepared trigger event into local history without re-enqueuing it.
  func storePreparedEventInHistory(_ event: NuxieEvent) async

  /// Track an event and return both the enriched event and server response
  func trackForTrigger(
    _ event: String,
    properties: [String: Any]?,
    userProperties: [String: Any]?,
    userPropertiesSetOnce: [String: Any]?,
    persistToHistory: Bool,
    distinctIdOverride: String?
  ) async throws -> (NuxieEvent, EventResponse)

  /// Track an event synchronously and wait for server response
  func trackWithResponse(
    _ event: String,
    properties: [String: Any]?
  ) async throws -> EventResponse

  /// Track an event synchronously, optionally flushing queued events before the round trip.
  func trackWithResponse(
    _ event: String,
    properties: [String: Any]?,
    flushPendingEvents: Bool
  ) async throws -> EventResponse

  /// Track an event synchronously, using an explicit pending-event flush strategy.
  func trackWithResponse(
    _ event: String,
    properties: [String: Any]?,
    flushStrategy: EventFlushStrategy
  ) async throws -> EventResponse

  /// Reassign events from one user to another (for anonymous → identified transitions)
  func reassignEvents(from fromUserId: String, to toUserId: String) async throws -> Int

  // MARK: - Delivery Management

  @discardableResult
  func flushEvents() async -> Bool
  func getQueuedEventCount() async -> Int
  func pauseEventQueue() async
  func resumeEventQueue() async

  /// Close the event log and its underlying storage
  func close() async

  /// Wait until all previously enqueued commands (capture + committed routing)
  /// are processed. Useful in tests for determinism.
  func drain() async

  // MARK: - Event History Access

  func getRecentEvents(limit: Int) async -> [StoredEvent]
  func getEventsForUser(_ distinctId: String, limit: Int) async -> [StoredEvent]
  func getEvents(for sessionId: String) async -> [StoredEvent]

  // MARK: - Event Query Methods

  func hasEvent(name: String, distinctId: String, since: Date?) async -> Bool
  func countEvents(name: String, distinctId: String, since: Date?, until: Date?) async -> Int
  func getLastEventTime(name: String, distinctId: String, since: Date?, until: Date?) async -> Date?

  // MARK: - IR Evaluation Support

  func exists(name: String, since: Date?, until: Date?, where predicate: IRPredicate?) async -> Bool
  func count(name: String, since: Date?, until: Date?, where predicate: IRPredicate?) async -> Int
  func firstTime(name: String, where predicate: IRPredicate?) async -> Date?
  func lastTime(name: String, where predicate: IRPredicate?) async -> Date?
  func aggregate(
    _ agg: Aggregate, name: String, prop: String, since: Date?, until: Date?,
    where predicate: IRPredicate?
  ) async -> Double?
  func inOrder(
    steps: [StepQuery], overallWithin: TimeInterval?, perStepWithin: TimeInterval?, since: Date?,
    until: Date?
  ) async -> Bool
  func activePeriods(
    name: String, period: Period, total: Int, min: Int, where predicate: IRPredicate?
  ) async -> Bool
  func stopped(name: String, inactiveFor: TimeInterval, where predicate: IRPredicate?) async -> Bool
  func restarted(
    name: String, inactiveFor: TimeInterval, within: TimeInterval, where predicate: IRPredicate?
  ) async -> Bool
}

public extension EventLogProtocol {
  func subscribeCommitted(handler: @escaping CommittedEventHandler) async {
    await subscribeCommitted(where: nil, handler: handler)
  }

  func prepareTriggerProperties(
    _ properties: [String: Any]? = nil,
    userProperties: [String: Any]? = nil,
    userPropertiesSetOnce: [String: Any]? = nil
  ) async -> [String: Any] {
    var finalProperties = properties ?? [:]
    if let userProperties { finalProperties["$set"] = userProperties }
    if let userPropertiesSetOnce { finalProperties["$set_once"] = userPropertiesSetOnce }
    return finalProperties
  }

  func trackForTrigger(
    _ event: String,
    properties: [String: Any]? = nil,
    userProperties: [String: Any]? = nil,
    userPropertiesSetOnce: [String: Any]? = nil
  ) async throws -> (NuxieEvent, EventResponse) {
    try await trackForTrigger(
      event,
      properties: properties,
      userProperties: userProperties,
      userPropertiesSetOnce: userPropertiesSetOnce,
      persistToHistory: true,
      distinctIdOverride: nil
    )
  }

  func trackWithResponse(
    _ event: String,
    properties: [String: Any]?,
    flushPendingEvents: Bool
  ) async throws -> EventResponse {
    try await trackWithResponse(
      event,
      properties: properties,
      flushStrategy: flushPendingEvents ? .eventLog : .none
    )
  }
}

/// The unified event log actor. Owns capture → enrich (session stamp, context,
/// sanitize, beforeSend) → persist (SQLite, pending) → durable network
/// delivery (batching, retry/backoff, ack) → query, plus the committed-events
/// subscription stream that decouples downstream consumers (journeys,
/// segments) from the log itself.
public actor EventLog: EventLogProtocol {

  // MARK: - Storage

  private let store: EventStoreProtocol
  private let ready = StoreReadySignal()
  private let closeFlag = CloseFlag()

  /// Retention: keep at most this many events; delete delivered rows older
  /// than the threshold. Checked every `cleanupCheckInterval` inserts.
  private let maxEventsStored: Int
  private let cleanupThresholdDays: Int
  private var insertsSinceCleanupCheck = 0
  private let cleanupCheckInterval: Int

  // MARK: - Capture pipeline

  private nonisolated let captureContinuation: AsyncStream<CaptureCommand>.Continuation
  private var captureWorker: Task<Void, Never>?
  private nonisolated let routeContinuation: AsyncStream<RouteCommand>.Continuation
  private var routeWorker: Task<Void, Never>?

  // MARK: - Dependencies

  /// Constructor-injected collaborators (Phase 4c composition root). The
  /// composition root builds identity/session/date/api before the log, so
  /// there is no lazy resolution and no hidden ordering.
  private nonisolated let identityService: IdentityServiceProtocol
  private nonisolated let sessionService: SessionServiceProtocol
  private nonisolated let dateProvider: DateProviderProtocol
  private let apiClient: NuxieApiProtocol

  private var contextBuilder: NuxieContextBuilder?
  private var configuration: NuxieConfiguration?

  // MARK: - Committed-event subscribers

  private struct Subscriber {
    let filter: (@Sendable (NuxieEvent) -> Bool)?
    let handler: CommittedEventHandler
  }
  private var subscribers: [Subscriber] = []

  // MARK: - Delivery (folded network queue)

  private struct DeliveryConfig {
    var flushAt: Int = 20
    var flushIntervalSeconds: TimeInterval = 30
    var maxQueueSize: Int = 1000
    var maxBatchSize: Int = 50
    var maxRetries: Int = 3
    var baseRetryDelay: TimeInterval = 5
  }

  private var deliveryConfig = DeliveryConfig()
  private var deliveryQueue: [NuxieEvent] = []
  private var isCurrentlyFlushing = false
  private var flushWaiters: [CheckedContinuation<Void, Never>] = []
  private var retryCount = 0
  private var nextRetryDate: Date?
  private var isPaused = false
  private var flushTimerTask: Task<Void, Never>?

  // MARK: - Initialization

  public init(
    identity: IdentityServiceProtocol,
    sessions: SessionServiceProtocol,
    dateProvider: DateProviderProtocol,
    apiClient: NuxieApiProtocol,
    store: EventStoreProtocol? = nil,
    maxEventsStored: Int = 10_000,
    cleanupThresholdDays: Int = 30,
    cleanupCheckInterval: Int = 100
  ) {
    self.identityService = identity
    self.sessionService = sessions
    self.dateProvider = dateProvider
    self.apiClient = apiClient
    self.store = store ?? SQLiteEventStore()
    self.maxEventsStored = maxEventsStored
    self.cleanupThresholdDays = cleanupThresholdDays
    self.cleanupCheckInterval = cleanupCheckInterval

    var captureCont: AsyncStream<CaptureCommand>.Continuation!
    let captureStream = AsyncStream<CaptureCommand> { captureCont = $0 }
    self.captureContinuation = captureCont

    var routeCont: AsyncStream<RouteCommand>.Continuation!
    let routeStream = AsyncStream<RouteCommand> { routeCont = $0 }
    self.routeContinuation = routeCont

    Task { await self.startWorkers(captureStream: captureStream, routeStream: routeStream) }
  }

  deinit {
    captureContinuation.finish()
    routeContinuation.finish()
    captureWorker?.cancel()
    routeWorker?.cancel()
    flushTimerTask?.cancel()
  }

  private func startWorkers(
    captureStream: AsyncStream<CaptureCommand>,
    routeStream: AsyncStream<RouteCommand>
  ) {
    captureWorker = Task { [weak self] in
      for await cmd in captureStream {
        guard let self else { return }
        await self.processCapture(cmd)
        if case .shutdown = cmd { return }
      }
    }
    routeWorker = Task { [weak self] in
      for await cmd in routeStream {
        guard let self else { return }
        await self.processRoute(cmd)
        if case .shutdown = cmd { return }
      }
    }
  }

  // MARK: - Configuration

  public func configure(configuration: NuxieConfiguration?) async throws {
    guard !closeFlag.isClosed else {
      LogWarning("EventLog.configure called after close; ignoring")
      return
    }

    self.configuration = configuration
    self.contextBuilder = NuxieContextBuilder(
      identityService: identityService,
      configuration: configuration
    )

    if let configuration {
      deliveryConfig = DeliveryConfig(
        flushAt: configuration.flushAt,
        flushIntervalSeconds: configuration.flushInterval,
        maxQueueSize: configuration.maxQueueSize,
        maxBatchSize: configuration.eventBatchSize,
        maxRetries: configuration.retryCount,
        baseRetryDelay: configuration.retryDelay
      )
    }

    do {
      try await store.initialize(path: configuration?.customStoragePath)
    } catch {
      // Storage should never wedge the SDK (or tests). If storage init fails, we still allow
      // network delivery and local evaluation to proceed with a best-effort store.
      LogWarning("EventLog storage initialization failed: \(error)")
    }

    // Durable delivery: rehydrate events a previous session persisted but
    // never delivered. They go to the queue front (older than anything
    // enqueued this session); the store acks them after delivery.
    let pending = await loadPendingDelivery(limit: 1000)
    if !pending.isEmpty {
      seedDelivery(pending)
    }

    // Only start the periodic flush timer outside tests.
    if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
      startFlushTimer()
    }

    LogInfo("EventLog configured (subscribers: \(subscribers.count))")
    // Signal that storage is initialized and safe to use
    await ready.open()
  }

  public func subscribeCommitted(
    where filter: (@Sendable (NuxieEvent) -> Bool)?,
    handler: @escaping CommittedEventHandler
  ) {
    subscribers.append(Subscriber(filter: filter, handler: handler))
  }

  // MARK: - Lifecycle

  public func onAppDidEnterBackground() async {
    // Flush before pausing so short sessions actually deliver; the background
    // task keeps iOS from suspending us mid-flush.
    #if canImport(UIKit) && !os(watchOS)
    let taskId = await MainActor.run {
      UIApplication.shared.beginBackgroundTask(withName: "NuxieEventFlush")
    }
    _ = await flushEvents()
    pauseEventQueue()
    if taskId != .invalid {
      await MainActor.run { UIApplication.shared.endBackgroundTask(taskId) }
    }
    #else
    _ = await flushEvents()
    pauseEventQueue()
    #endif
  }

  public func onAppBecameActive() async {
    await resumeEventQueue()
    _ = await flushEvents()  // optional; may jitter
  }

  // MARK: - Capture

  public nonisolated func track(
    _ event: String,
    properties: [String: Any]? = nil,
    userProperties: [String: Any]? = nil,
    userPropertiesSetOnce: [String: Any]? = nil
  ) {
    guard !closeFlag.isClosed else { return }

    guard !event.isEmpty else {
      LogWarning("Event name cannot be empty")
      return
    }

    // Build lightweight custom payload. Full enrichment happens in the worker.
    var custom = properties ?? [:]
    if let userProperties { custom["$set"] = userProperties }
    if let userPropertiesSetOnce { custom["$set_once"] = userPropertiesSetOnce }

    // Snapshot id NOW to preserve pre/post identify semantics.
    let idSnapshot = identityService.getDistinctId()
    let payload = TrackPayload(
      name: event,
      properties: custom,
      forcedDistinctId: idSnapshot
    )

    captureContinuation.yield(.track(payload))
  }

  public func trackWithResponse(
    _ event: String,
    properties: [String: Any]? = nil
  ) async throws -> EventResponse {
    try await trackWithResponse(
      event,
      properties: properties,
      flushPendingEvents: true
    )
  }

  public func trackWithResponse(
    _ event: String,
    properties: [String: Any]? = nil,
    flushStrategy: EventFlushStrategy
  ) async throws -> EventResponse {
    guard !event.isEmpty else {
      throw NuxieError.invalidConfiguration("Event name cannot be empty")
    }

    // Wait for initialization
    await ready.wait()

    switch flushStrategy {
    case .none:
      break
    case .eventLog:
      // Flush pending capture commands first to ensure ordering.
      _ = await flushEvents()
    case .networkQueue:
      let drained = await deliveryFlushAll()
      guard drained else {
        throw NuxieError.eventRoutingFailed
      }
    }

    // Get current distinct ID
    let distinctId = identityService.getDistinctId()

    let finalProperties = await buildTriggerProperties(
      properties,
      userProperties: nil,
      userPropertiesSetOnce: nil
    )

    // Store event locally (for history)
    do {
      try await storeHistoryEvent(name: event, properties: finalProperties, distinctId: distinctId)
    } catch {
      LogWarning("Failed to store event locally: \(error)")
      // Continue - server tracking is more important for journey events
    }

    // Send directly to API and return response
    return try await apiClient.trackEvent(
      event: event,
      distinctId: distinctId,
      properties: finalProperties,
      value: finalProperties["value"] as? Double,
      entityId: finalProperties["entityId"] as? String
    )
  }

  /// Track an event and return the enriched event plus server response.
  ///
  /// Local-first: when `persistToHistory` is true the event is persisted
  /// PENDING in SQLite before the network round trip, so it is durable and
  /// redeliverable no matter what the transport does. A successful `/i/event`
  /// round trip acks the row; a failed round trip leaves it pending, stages
  /// it on the delivery queue, and returns a degraded offline response
  /// (`gatePlan() == nil`) so callers route journeys/segments from the local
  /// event and cached config — network failure degrades freshness, never
  /// function.
  public func trackForTrigger(
    _ event: String,
    properties: [String: Any]? = nil,
    userProperties: [String: Any]? = nil,
    userPropertiesSetOnce: [String: Any]? = nil,
    persistToHistory: Bool = true,
    distinctIdOverride: String? = nil
  ) async throws -> (NuxieEvent, EventResponse) {
    guard !event.isEmpty else {
      throw NuxieError.invalidConfiguration("Event name cannot be empty")
    }

    await ready.wait()

    _ = await flushEvents()

    let distinctId = distinctIdOverride ?? identityService.getDistinctId()

    let finalProperties = await buildTriggerProperties(
      properties,
      userProperties: userProperties,
      userPropertiesSetOnce: userPropertiesSetOnce
    )

    // The canonical local event exists before anything else observes it. Its
    // UUIDv7 id is the durable-delivery idempotency key if the row later
    // rides the batch queue.
    let localEvent = NuxieEvent(
      name: event,
      distinctId: distinctId,
      properties: finalProperties
    )

    if persistToHistory {
      do {
        let stored = try StoredEvent(
          id: localEvent.id,
          name: localEvent.name,
          properties: localEvent.properties,
          timestamp: localEvent.timestamp,
          distinctId: localEvent.distinctId
        )
        try await store.insertPending(stored)
        try await performCleanupIfNeeded()
      } catch {
        LogWarning("Failed to store event locally: \(error)")
      }
    }

    do {
      let response = try await apiClient.trackEvent(
        event: event,
        distinctId: distinctId,
        properties: finalProperties,
        value: finalProperties["value"] as? Double,
        entityId: finalProperties["entityId"] as? String
      )

      if persistToHistory {
        // The direct round trip delivered this event — ack the pending row
        // so the batch path never re-sends it.
        await markDelivered(ids: [localEvent.id])
      }

      let enrichedEvent = NuxieEvent(
        id: response.eventId ?? localEvent.id,
        name: event,
        distinctId: distinctId,
        properties: finalProperties,
        timestamp: localEvent.timestamp
      )
      return (enrichedEvent, response)
    } catch {
      // Transport failure: keep the row pending and stage it for durable
      // batch delivery (next flush/timer/launch; the server dedupes on the
      // event-id idempotency key). Degrade to local evaluation instead of
      // failing the trigger.
      if persistToHistory {
        enqueueForDelivery(localEvent)
      }
      LogWarning(
        "trackForTrigger round trip failed for '\(event)'; continuing local-first: \(error)")
      let offlineResponse = EventResponse(status: "offline", eventId: localEvent.id)
      return (localEvent, offlineResponse)
    }
  }

  public func prepareTriggerProperties(
    _ properties: [String: Any]?,
    userProperties: [String: Any]?,
    userPropertiesSetOnce: [String: Any]?
  ) async -> [String: Any] {
    await ready.wait()
    return await buildTriggerProperties(
      properties,
      userProperties: userProperties,
      userPropertiesSetOnce: userPropertiesSetOnce
    )
  }

  public func storePreparedEventInHistory(_ event: NuxieEvent) async {
    await ready.wait()

    do {
      try await store.insertHistory(makeStoredEvent(from: event))
      try await performCleanupIfNeeded()
    } catch {
      LogWarning("Failed to store prepared event locally: \(error)")
    }
  }

  public func reassignEvents(from fromUserId: String, to toUserId: String) async throws -> Int {
    await ready.wait()
    let reassignedCount = try await store.reassignEvents(from: fromUserId, to: toUserId)
    if reassignedCount > 0 {
      LogInfo(
        "Reassigned \(reassignedCount) events from \(NuxieLogger.shared.logDistinctID(fromUserId)) to \(NuxieLogger.shared.logDistinctID(toUserId))"
      )
    }
    return reassignedCount
  }

  // MARK: - Close

  public func close() async {
    guard closeFlag.close() else { return }

    // Unblock any in-flight work waiting on storage init (e.g. tests that never called setup()).
    await ready.open()

    // Stop accepting new commands and ask the workers to stop.
    captureContinuation.yield(.shutdown)
    captureContinuation.finish()
    routeContinuation.yield(.shutdown)
    routeContinuation.finish()

    flushTimerTask?.cancel()
    flushTimerTask = nil

    // Deterministic teardown: wait for both workers to finish their queued
    // commands and exit. Without this, a test (or re-setup) can tear down
    // shared collaborators while a worker is still mid-command.
    await captureWorker?.value
    await routeWorker?.value

    await store.close()
    LogInfo("EventLog closed")
  }

  // MARK: - Workers

  private func processCapture(_ cmd: CaptureCommand) async {
    switch cmd {
    case .track(let payload):
      // Wait for configuration before building: enrichment (context,
      // beforeSend) must apply to pre-configure captures too — commands
      // buffer in the stream until the store opens.
      await ready.wait()
      guard let finalEvent = await buildEvent(from: payload) else { return }
      await commit(finalEvent)

    case .flush(let cont):
      guard await ready.isOpen() else {
        cont.resume(returning: false)
        return
      }
      let hadEvents = !deliveryQueue.isEmpty
      let ok = await deliveryFlushAll()
      cont.resume(returning: hadEvents && ok)

    case .barrier(let cont):
      // All prior commands are processed when we reach here
      cont.resume()

    case .shutdown:
      LogDebug("[EventLog.capture] shutdown received")
    }
  }

  private func processRoute(_ cmd: RouteCommand) async {
    switch cmd {
    case .event(let event):
      for subscriber in subscribers {
        if let filter = subscriber.filter, !filter(event) { continue }
        await subscriber.handler(event)
      }

    case .barrier(let cont):
      cont.resume()

    case .shutdown:
      LogDebug("[EventLog.route] shutdown received")
    }
  }

  /// Persist the canonical captured record (stored row == wire payload,
  /// marked pending), stage it for network delivery, then announce it to
  /// committed-event subscribers in order.
  private func commit(_ event: NuxieEvent) async {
    extractUserProperties(from: event)
    do {
      let stored = try StoredEvent(
        id: event.id,
        name: event.name,
        properties: event.properties,
        timestamp: event.timestamp,
        distinctId: event.distinctId
      )
      try await store.insertPending(stored)
      try await performCleanupIfNeeded()
    } catch {
      LogError("Failed to store event locally: \(error)")
      // Continue routing to other services even if storage fails
    }

    // Network ordering: enqueue before subscriber routing so lifecycle calls
    // can flush this hit.
    enqueueForDelivery(event)

    routeContinuation.yield(.event(event))
  }

  /// Extract and update user properties from event
  private func extractUserProperties(from event: NuxieEvent) {
    // Apply $set/$set_once to the identity the event was captured under.
    // Events queued pre-identify must not land their props on the
    // post-identify user (the id was snapshotted at enqueue for this reason).
    guard event.distinctId == identityService.getDistinctId() else {
      LogDebug("Skipping user-property extraction for event captured under a previous identity")
      return
    }

    // Check for $set properties (overwrites existing)
    if let setProperties = event.properties["$set"] as? [String: Any] {
      identityService.setUserProperties(setProperties)
      LogDebug("Updated \(setProperties.count) user properties from $set")
    }

    // Check for $set_once properties (only sets if not present)
    if let setOnceProperties = event.properties["$set_once"] as? [String: Any] {
      identityService.setOnceUserProperties(setOnceProperties)
      LogDebug("Updated user properties from $set_once")
    }
  }

  // MARK: - Enrichment

  private func buildEvent(from p: TrackPayload) async -> NuxieEvent? {
    // Stage 1: Add session ID if not already present
    var propertiesWithSession = p.properties
    if propertiesWithSession["$session_id"] == nil {
      // Get or create session ID and add to properties
      if let sessionId = sessionService.getSessionId(at: Date(), readOnly: false) {
        propertiesWithSession["$session_id"] = sessionId
        // Touch session to update activity
        sessionService.touchSession()
      }
    }

    let finalProperties = await enrich(propertiesWithSession)

    let nuxieEvent = NuxieEvent(
      name: p.name,
      distinctId: p.forcedDistinctId,
      properties: finalProperties
    )

    // Stage 2: Apply beforeSend hook if configured
    if let beforeSend = configuration?.beforeSend {
      guard let transformedEvent = beforeSend(nuxieEvent) else {
        LogDebug("Event '\(nuxieEvent.name)' dropped by beforeSend hook")
        return nil
      }
      return transformedEvent
    }

    return nuxieEvent
  }

  private func buildTriggerProperties(
    _ properties: [String: Any]?,
    userProperties: [String: Any]?,
    userPropertiesSetOnce: [String: Any]?
  ) async -> [String: Any] {
    var finalProperties = properties ?? [:]
    if let userProperties { finalProperties["$set"] = userProperties }
    if let userPropertiesSetOnce { finalProperties["$set_once"] = userPropertiesSetOnce }

    if finalProperties["$session_id"] == nil {
      if let sessionId = sessionService.getSessionId(at: Date(), readOnly: false) {
        finalProperties["$session_id"] = sessionId
        sessionService.touchSession()
      }
    }

    return await enrich(finalProperties)
  }

  private func enrich(_ custom: [String: Any]) async -> [String: Any] {
    let sanitized = EventSanitizer.sanitizeDataTypes(custom)
    let withContext: [String: Any]
    if let contextBuilder {
      withContext = await contextBuilder.buildEnrichedProperties(customProperties: sanitized)
    } else {
      withContext = sanitized
    }
    return withContext
  }

  // MARK: - History persistence

  /// Store a direct-delivery history row (delivered — these paths send the
  /// event themselves) with legacy device metadata.
  private func storeHistoryEvent(
    name: String, properties: [String: Any], distinctId: String
  ) async throws {
    var enrichedProperties = properties
    enrichedProperties["sdk_version"] = SDKVersion.current
    enrichedProperties["platform"] = currentPlatform()
    if enrichedProperties["device_model"] == nil {
      enrichedProperties["device_model"] = deviceModelIdentifier()
    }
    if enrichedProperties["os_version"] == nil {
      enrichedProperties["os_version"] = osVersionString()
    }

    let event = try StoredEvent(
      name: name,
      properties: enrichedProperties,
      distinctId: distinctId
    )
    try await store.insertHistory(event)
    try await performCleanupIfNeeded()
  }

  /// Cleanup runs at most once per `cleanupCheckInterval` inserts — a
  /// per-insert COUNT(*) would be a wasted query on every event.
  private func performCleanupIfNeeded() async throws {
    insertsSinceCleanupCheck += 1
    guard insertsSinceCleanupCheck >= cleanupCheckInterval else { return }
    insertsSinceCleanupCheck = 0

    let eventCount = try await store.getEventCount()
    guard eventCount > maxEventsStored else { return }

    // Enforce the cap by COUNT (an age-only delete lets active users grow
    // unboundedly within the retention window), then apply the age policy on
    // top. Neither reaps rows still awaiting delivery.
    let cappedDeletes = try await store.deleteOldestDeliveredEvents(keeping: maxEventsStored)
    let cutoffDate =
      Calendar.current.date(byAdding: .day, value: -cleanupThresholdDays, to: Date()) ?? Date()
    let agedDeletes = try await store.deleteEventsOlderThan(cutoffDate)
    LogInfo(
      "Retention cleanup: removed \(cappedDeletes) over-cap + \(agedDeletes) aged events (had \(eventCount))"
    )
  }

  private func loadPendingDelivery(limit: Int) async -> [NuxieEvent] {
    do {
      let stored = try await store.queryPendingDelivery(limit: limit)
      return stored.map { row in
        NuxieEvent(
          id: row.id,
          name: row.name,
          distinctId: row.distinctId,
          properties: row.getPropertiesDict(),
          timestamp: row.timestamp
        )
      }
    } catch {
      LogWarning("Failed to load pending-delivery events: \(error)")
      return []
    }
  }

  private func markDelivered(ids: [String]) async {
    do {
      try await store.markDelivered(ids: ids)
    } catch {
      // Worst case these rows re-send after relaunch; the server dedupes
      // on the event-id idempotency key.
      LogWarning("Failed to mark \(ids.count) events delivered: \(error)")
    }
  }

  // MARK: - Delivery queue (folded network queue)

  /// Seed the delivery queue with rehydrated pending events from a previous
  /// session. They go to the front (they are older than anything enqueued
  /// this session); duplicates by id are ignored.
  private func seedDelivery(_ events: [NuxieEvent]) {
    let existing = Set(deliveryQueue.map(\.id))
    let fresh = events.filter { !existing.contains($0.id) }
    guard !fresh.isEmpty else { return }
    deliveryQueue.insert(contentsOf: fresh, at: 0)
    LogInfo("Rehydrated \(fresh.count) pending events from a previous session")
  }

  /// Internal for delivery-state-machine tests.
  func enqueueForDelivery(_ event: NuxieEvent) {
    // Check if queue is full
    if deliveryQueue.count >= deliveryConfig.maxQueueSize {
      // Drop oldest event (FIFO)
      let dropped = deliveryQueue.removeFirst()
      LogWarning("Delivery queue full, dropped oldest event: \(dropped.name)")
    }

    deliveryQueue.append(event)
    LogDebug("Enqueued event: \(event.name) (queue size: \(deliveryQueue.count))")

    Task { await self.flushIfOverThreshold() }
  }

  @discardableResult
  public func flushEvents() async -> Bool {
    guard !closeFlag.isClosed else { return false }

    return await withCheckedContinuation { cont in
      captureContinuation.yield(.flush(cont))
    }
  }

  public func getQueuedEventCount() async -> Int {
    deliveryQueue.count
  }

  public func pauseEventQueue() {
    isPaused = true
    LogInfo("Delivery queue paused")
  }

  public func resumeEventQueue() async {
    isPaused = false
    retryCount = 0
    nextRetryDate = nil
    LogInfo("Delivery queue resumed")

    // Trigger flush if we have events
    await flushIfOverThreshold()
  }

  private func flushIfOverThreshold() async {
    guard !isPaused, !isCurrentlyFlushing else { return }

    // Check retry backoff
    if let nextRetry = nextRetryDate, Date() < nextRetry {
      return  // Still in backoff period
    }

    if deliveryQueue.count >= deliveryConfig.flushAt {
      LogDebug(
        "Delivery threshold reached (\(deliveryQueue.count) >= \(deliveryConfig.flushAt)), triggering flush"
      )
      _ = await performFlush()
    }
  }

  /// Flush until the delivery queue is empty, waiting for any in-flight flush
  /// to finish first. Returns false if the queue could not be drained — a
  /// flush cycle that delivers nothing (transport down, no-progress partial)
  /// ends the loop with the batch retained pending; the next flush, timer
  /// tick, or launch retries it. One manual flush must never burn the whole
  /// retry budget back-to-back against a dead network.
  @discardableResult
  func deliveryFlushAll() async -> Bool {
    while true {
      if isCurrentlyFlushing {
        await waitForCurrentFlush()
        continue
      }

      guard !deliveryQueue.isEmpty else {
        return true
      }

      let pendingBefore = Set(deliveryQueue.map(\.id))
      let didFlush = await performFlush(forceSend: true)
      if !didFlush {
        return deliveryQueue.isEmpty
      }
      // Concurrent enqueues only add ids, so "every pre-flush event is still
      // queued" means the attempt removed nothing: stop this cycle.
      if pendingBefore.isSubset(of: Set(deliveryQueue.map(\.id))) {
        return false
      }
    }
  }

  /// Perform the actual flush operation
  /// - Parameter forceSend: If true, bypass pause state and retry backoff
  ///   (for manual flush) — ignoring backoff silently reordered trigger
  ///   events ahead of the queue.
  func performFlush(forceSend: Bool = false) async -> Bool {
    // A stray threshold-check task must not deliver after close (tests tear
    // down shared collaborators once close() returns).
    guard !closeFlag.isClosed else { return false }
    let shouldCheckPause = !forceSend
    guard (!shouldCheckPause || !isPaused), !isCurrentlyFlushing, !deliveryQueue.isEmpty else {
      return false
    }

    if !forceSend, let nextRetry = nextRetryDate, Date() < nextRetry {
      LogDebug("Still in retry backoff, skipping flush")
      return false
    }

    isCurrentlyFlushing = true

    // Get batch to send (up to maxBatchSize events)
    let batchSize = min(deliveryQueue.count, deliveryConfig.maxBatchSize)
    let batch = Array(deliveryQueue.prefix(batchSize))

    LogInfo("[EventLog] Flushing \(batch.count) events to server")

    // Canonical conversion — semantics pinned by
    // fixtures/events/batch-item-encoding.json
    let batchItems = batch.map(BatchEventItem.init(event:))

    do {
      let response = try await apiClient.sendBatch(events: batchItems)
      LogDebug("Batch response: processed=\(response.processed), failed=\(response.failed)")
      if response.failed == 0 {
        await handleBatchSuccess(batch)
      } else {
        await handleBatchPartialSuccess(batch, response: response)
      }
    } catch {
      await handleBatchFailure(batch, error: error)
    }

    return true
  }

  private func waitForCurrentFlush() async {
    guard isCurrentlyFlushing else { return }

    await withCheckedContinuation { continuation in
      flushWaiters.append(continuation)
    }
  }

  private func finishCurrentFlush() {
    isCurrentlyFlushing = false
    let waiters = flushWaiters
    flushWaiters.removeAll()
    waiters.forEach { $0.resume() }
  }

  private func handleBatchSuccess(_ batch: [NuxieEvent]) async {
    // Remove delivered events from queue and ack them in the store
    let batchIds = Set(batch.map { $0.id })
    deliveryQueue.removeAll { batchIds.contains($0.id) }
    await markDelivered(ids: batch.map { $0.id })

    retryCount = 0
    nextRetryDate = nil

    finishCurrentFlush()

    LogInfo("Successfully delivered \(batch.count) events (queue size: \(deliveryQueue.count))")

    await flushIfOverThreshold()
  }

  private func handleBatchPartialSuccess(_ batch: [NuxieEvent], response: BatchResponse) async {
    let failedIndices = Set((response.errors ?? []).map(\.index))
    let canIdentifyFailedEvents = !failedIndices.isEmpty
    var removedAnyEvents = false

    if canIdentifyFailedEvents {
      let successfulIds = Set(
        batch.enumerated().compactMap { index, event in
          failedIndices.contains(index) ? nil : event.id
        }
      )
      removedAnyEvents = !successfulIds.isEmpty
      deliveryQueue.removeAll { successfulIds.contains($0.id) }
      await markDelivered(ids: Array(successfulIds))
    } else {
      LogWarning(
        "Partial batch response did not include per-event error indexes; retaining entire batch for retry"
      )
    }

    if removedAnyEvents {
      // Partial delivery made progress, so clear any existing backoff.
      retryCount = 0
      nextRetryDate = nil
    } else {
      retryCount += 1
      let backoffDelay = deliveryConfig.baseRetryDelay * pow(2, Double(max(retryCount - 1, 0)))
      nextRetryDate = Date().addingTimeInterval(backoffDelay)
      LogWarning("Partial batch made no progress, retrying in \(backoffDelay)s")
    }

    finishCurrentFlush()

    LogWarning(
      "Partially delivered batch: \(response.processed) processed, \(response.failed) failed")

    if let errors = response.errors {
      for error in errors {
        LogDebug("Event error at index \(error.index): \(error.event) - \(error.error)")
      }
    }

    await flushIfOverThreshold()
  }

  private func handleBatchFailure(_ batch: [NuxieEvent], error: Error) async {
    // Permanent rejection (4xx): the server will never accept these events.
    // Deliberate poison drop: mark delivered so they never resurrect.
    if isPermanentBatchFailure(error) {
      let batchIds = Set(batch.map { $0.id })
      deliveryQueue.removeAll { batchIds.contains($0.id) }
      await markDelivered(ids: batch.map { $0.id })
      retryCount = 0
      nextRetryDate = nil
      LogWarning("Permanent failure (4xx), dropped \(batch.count) events: \(error)")
      finishCurrentFlush()
      return
    }

    // Transport-level failure (offline, 5xx, timeout): the batch stays in
    // the queue and its rows stay pending in the store — a failed batch is
    // NEVER acked for retry-exhaustion reasons. Retry exhaustion only ends
    // the current flush cycle (deliveryFlushAll stops on no progress); the
    // next flush, timer tick, or launch retries the same rows, and the
    // server dedupes any overlap on the event-id idempotency key. The
    // backoff exponent is capped so a long outage cannot push the next
    // retry date to infinity.
    retryCount += 1
    let cappedExponent = min(retryCount - 1, max(deliveryConfig.maxRetries - 1, 0))
    let backoffDelay = deliveryConfig.baseRetryDelay * pow(2, Double(cappedExponent))
    nextRetryDate = Date().addingTimeInterval(backoffDelay)

    LogWarning(
      "Batch delivery failed (attempt \(retryCount)), keeping \(batch.count) events pending; next retry in \(backoffDelay)s: \(error)"
    )

    finishCurrentFlush()
  }

  private func isPermanentBatchFailure(_ error: Error) -> Bool {
    if let networkError = error as? NuxieNetworkError,
      case .httpError(let statusCode, _) = networkError
    {
      return (400..<500).contains(statusCode)
    }

    // (URLError rawValues are negative CFNetwork codes — never 4xx; only
    // NuxieNetworkError.httpError carries an HTTP status.)
    return false
  }

  private func startFlushTimer() {
    flushTimerTask?.cancel()
    let interval = deliveryConfig.flushIntervalSeconds

    flushTimerTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        if Task.isCancelled { break }
        await self?.handleTimerFlush()
      }
    }
  }

  /// Internal for tests.
  func clearDeliveryQueue() {
    let count = deliveryQueue.count
    deliveryQueue.removeAll()
    LogInfo("Cleared \(count) events from delivery queue")
  }

  private func handleTimerFlush() async {
    if !deliveryQueue.isEmpty {
      LogDebug("Timer flush triggered (\(deliveryQueue.count) events)")
      _ = await performFlush()
    }
  }

  // MARK: - Drain (test determinism)

  public func drain() async {
    guard !closeFlag.isClosed else { return }

    await drainCaptureWorker()
    await drainRouteWorker()
    await drainCaptureWorker()
  }

  private func drainCaptureWorker() async {
    await withCheckedContinuation { cont in
      captureContinuation.yield(.barrier(cont))
    }
  }

  private func drainRouteWorker() async {
    await withCheckedContinuation { cont in
      routeContinuation.yield(.barrier(cont))
    }
  }

  // MARK: - Event History Access

  public func getRecentEvents(limit: Int = 100) async -> [StoredEvent] {
    await ready.wait()
    do {
      return try await store.queryRecentEvents(limit: limit)
    } catch {
      LogError("Failed to get recent events: \(error)")
      return []
    }
  }

  public func getEventsForUser(_ distinctId: String, limit: Int = 100) async -> [StoredEvent] {
    await ready.wait()
    do {
      return try await store.queryEventsForUser(distinctId, limit: limit)
    } catch {
      LogError("Failed to get events for user \(distinctId): \(error)")
      return []
    }
  }

  public func getEvents(for sessionId: String) async -> [StoredEvent] {
    await ready.wait()
    do {
      return try await store.querySessionEvents(sessionId)
    } catch {
      LogError("Failed to get session events: \(error)")
      return []
    }
  }

  // MARK: - Event Query Methods

  public func hasEvent(name: String, distinctId: String, since: Date? = nil) async -> Bool {
    await ready.wait()
    do {
      return try await store.hasEvent(name: name, distinctId: distinctId, since: since)
    } catch {
      LogError("Failed to check event existence: \(error)")
      return false
    }
  }

  public func countEvents(name: String, distinctId: String, since: Date? = nil, until: Date? = nil)
    async -> Int
  {
    await ready.wait()
    do {
      return try await store.countEvents(
        name: name, distinctId: distinctId, since: since, until: until)
    } catch {
      LogError("Failed to count events: \(error)")
      return 0
    }
  }

  public func getLastEventTime(
    name: String, distinctId: String, since: Date? = nil, until: Date? = nil
  ) async -> Date? {
    await ready.wait()
    do {
      return try await store.getLastEventTime(
        name: name, distinctId: distinctId, since: since, until: until)
    } catch {
      LogError("Failed to get last event time: \(error)")
      return nil
    }
  }

  // MARK: - IREvents Protocol Implementation

  public func exists(name: String, since: Date?, until: Date?, where predicate: IRPredicate?) async
    -> Bool
  {
    return await count(name: name, since: since, until: until, where: predicate) > 0
  }

  public func count(name: String, since: Date?, until: Date?, where predicate: IRPredicate?) async
    -> Int
  {
    let distinctId = identityService.getDistinctId()
    await ready.wait()

    // Predicate-free counts go straight to SQL — counting within the last N
    // events of ALL names undercounts for active users.
    if predicate == nil {
      return (try? await store.countEvents(
        name: name, distinctId: distinctId, since: since, until: until)) ?? 0
    }

    let events = await irEvents(
      named: name, distinctId: distinctId, since: since, until: until, ascending: false)
    return events.lazy
      .filter { event in
        let props = event.getPropertiesDict()
        return PredicateEval.eval(predicate!, props: props)
      }
      .count
  }

  /// Name-filtered fetch for IR predicate queries — SQL narrows by
  /// user+name+time (indexed) so other events can't evict the queried
  /// event's history.
  private func irEvents(
    named name: String, distinctId: String, since: Date?, until: Date?, ascending: Bool
  ) async -> [StoredEvent] {
    (try? await store.queryEventsForUser(
      distinctId, name: name, since: since, until: until,
      ascending: ascending, limit: 10_000)) ?? []
  }

  public func firstTime(name: String, where predicate: IRPredicate?) async -> Date? {
    let distinctId = identityService.getDistinctId()
    await ready.wait()

    // Predicate-free → SQL MIN. Taking the earliest of the most RECENT N
    // events is wrong precisely for long-tenured users.
    if predicate == nil {
      return (try? await store.getFirstEventTime(
        name: name, distinctId: distinctId, since: nil, until: nil)) ?? nil
    }

    let events = await irEvents(
      named: name, distinctId: distinctId, since: nil, until: nil, ascending: true)
    return events.first { event in
      PredicateEval.eval(predicate!, props: event.getPropertiesDict())
    }?.timestamp
  }

  public func lastTime(name: String, where predicate: IRPredicate?) async -> Date? {
    let distinctId = identityService.getDistinctId()
    await ready.wait()

    if predicate == nil {
      return (try? await store.getLastEventTime(
        name: name, distinctId: distinctId, since: nil, until: nil)) ?? nil
    }

    let events = await irEvents(
      named: name, distinctId: distinctId, since: nil, until: nil, ascending: false)
    return events.first { event in
      PredicateEval.eval(predicate!, props: event.getPropertiesDict())
    }?.timestamp
  }

  public func aggregate(
    _ agg: Aggregate, name: String, prop: String, since: Date?, until: Date?,
    where predicate: IRPredicate?
  ) async -> Double? {
    let distinctId = identityService.getDistinctId()
    await ready.wait()
    let events = await irEvents(
      named: name, distinctId: distinctId, since: since, until: until, ascending: false)

    let values: [Double] =
      events
      .compactMap { event -> Double? in
        let props = event.getPropertiesDict()
        guard predicate.map({ PredicateEval.eval($0, props: props) }) ?? true else { return nil }
        return Coercion.asNumber(props[prop])
      }

    guard !values.isEmpty else { return nil }

    switch agg {
    case .sum:
      return values.reduce(0, +)
    case .avg:
      return values.reduce(0, +) / Double(values.count)
    case .min:
      return values.min()
    case .max:
      return values.max()
    case .unique:
      return Double(Set(values).count)
    }
  }

  public func inOrder(
    steps: [StepQuery], overallWithin: TimeInterval?, perStepWithin: TimeInterval?, since: Date?,
    until: Date?
  ) async -> Bool {
    let distinctId = identityService.getDistinctId()
    await ready.wait()
    // Per-step name-filtered fetches, merged chronologically — a heavy
    // unrelated event stream can no longer evict the sequence's events.
    var merged: [StoredEvent] = []
    for stepName in Set(steps.map(\.name)) {
      merged += await irEvents(
        named: stepName, distinctId: distinctId, since: since, until: until, ascending: true)
    }
    let events = merged.sorted(by: { $0.timestamp < $1.timestamp })

    var lastTime: Date? = nil
    let startRef = events.first?.timestamp

    for step in steps {
      guard
        let match = events.first(where: { event in
          guard event.timestamp >= (lastTime ?? since ?? Date.distantPast) else { return false }
          if event.name != step.name { return false }
          if let p = step.predicate {
            let props = event.getPropertiesDict()
            if !PredicateEval.eval(p, props: props) { return false }
          }
          if let per = perStepWithin, let lt = lastTime {
            if event.timestamp.timeIntervalSince(lt) > per { return false }
          }
          if let ov = overallWithin, let start = startRef {
            if event.timestamp.timeIntervalSince(start) > ov { return false }
          }
          return true
        })
      else {
        return false
      }
      lastTime = match.timestamp
    }

    return true
  }

  public func activePeriods(
    name: String, period: Period, total: Int, min: Int, where predicate: IRPredicate?
  ) async -> Bool {
    let distinctId = identityService.getDistinctId()
    await ready.wait()
    guard total > 0 && min > 0 else { return false }

    // Calendar-bucket by UTC
    let cal = Calendar(identifier: .gregorian)
    let now = dateProvider.now()

    // Calculate the time window - the last 'total' periods from now
    let windowStart: Date
    switch period {
    case .day:
      windowStart = cal.date(byAdding: .day, value: -total, to: now) ?? now
    case .week:
      windowStart = cal.date(byAdding: .weekOfYear, value: -total, to: now) ?? now
    case .month:
      windowStart = cal.date(byAdding: .month, value: -total, to: now) ?? now
    case .year:
      windowStart = cal.date(byAdding: .year, value: -total, to: now) ?? now
    }

    // Name+window-filtered at the SQL layer
    let events = await irEvents(
      named: name, distinctId: distinctId, since: windowStart, until: nil, ascending: false)

    // Count unique periods with activity within the time window
    var bucketsInWindow = Set<DateComponents>()

    for event in events {
      let props = event.getPropertiesDict()
      if let p = predicate, !PredicateEval.eval(p, props: props) { continue }

      let comps: DateComponents
      switch period {
      case .day:
        comps = cal.dateComponents([.year, .month, .day], from: event.timestamp)
      case .week:
        comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: event.timestamp)
      case .month:
        comps = cal.dateComponents([.year, .month], from: event.timestamp)
      case .year:
        comps = cal.dateComponents([.year], from: event.timestamp)
      }
      bucketsInWindow.insert(comps)
    }

    // Return true if user was active in at least 'min' periods out of the last 'total' periods
    return bucketsInWindow.count >= min
  }

  public func stopped(name: String, inactiveFor: TimeInterval, where predicate: IRPredicate?) async
    -> Bool
  {
    guard let last = await lastTime(name: name, where: predicate) else { return false }
    return Date().timeIntervalSince(last) >= inactiveFor
  }

  public func restarted(
    name: String, inactiveFor: TimeInterval, within: TimeInterval, where predicate: IRPredicate?
  ) async -> Bool {
    let distinctId = identityService.getDistinctId()
    let now = Date()
    await ready.wait()
    let events = await irEvents(
      named: name, distinctId: distinctId, since: nil, until: nil, ascending: true)

    // Find any gap
    var prev: Date? = nil
    var hadGap = false

    for event in events {
      if let p = predicate {
        let props = event.getPropertiesDict()
        if !PredicateEval.eval(p, props: props) { continue }
      }
      if let pv = prev, event.timestamp.timeIntervalSince(pv) >= inactiveFor {
        hadGap = true
      }
      prev = event.timestamp
    }

    guard hadGap else { return false }

    // Check for recent activity
    return events.contains { event in
      now.timeIntervalSince(event.timestamp) <= within
    }
  }

  // MARK: - Helpers

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

  private func deviceModelIdentifier() -> String {
    var systemInfo = utsname()
    uname(&systemInfo)
    let machineMirror = Mirror(reflecting: systemInfo.machine)
    return machineMirror.children.reduce("") { identifier, element in
      guard let value = element.value as? Int8, value != 0 else { return identifier }
      return identifier + String(UnicodeScalar(UInt8(value)))
    }
  }

  private func osVersionString() -> String {
    let version = ProcessInfo.processInfo.operatingSystemVersion
    return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
  }

  private func currentPlatform() -> String {
    #if os(iOS)
    return "ios"
    #elseif os(macOS)
    return "macos"
    #elseif os(tvOS)
    return "tvos"
    #elseif os(watchOS)
    return "watchos"
    #else
    return "unknown"
    #endif
  }
}
