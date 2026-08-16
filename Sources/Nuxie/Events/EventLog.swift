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

// @unchecked Sendable: immutable snapshot; the [String: Any] payload is
// write-once at the call site and never mutated afterwards.
private struct TrackPayload: @unchecked Sendable {
  let name: String
  let properties: [String: Any]
  let forcedDistinctId: String  // snapshot at call site
}

private enum CaptureCommand: Sendable {
  case track(TrackPayload)
  case flush(CheckedContinuation<Bool, Never>)
  case barrier(CheckedContinuation<Void, Never>)  // test-only: "drain until here"
  case shutdown
}

private enum RouteCommand: Sendable {
  case event(NuxieEvent)
  case barrier(CheckedContinuation<Void, Never>)
  case shutdown
}

enum EventFlushStrategy: Equatable, Sendable {
  case none
  case eventLog
  case networkQueue
}

/// A committed-event subscriber callback. Invoked in commit order, after the
/// event is persisted (pending delivery) and staged for the network.
typealias CommittedEventHandler = @Sendable (NuxieEvent) async -> Void

/// An exact, durably committed trigger event plus its independently running
/// server round trip. Callers can route the committed event locally without
/// waiting for transport, then reconcile the eventual response (for example,
/// a gate plan) afterward.
struct PreparedTriggerCommit: Sendable {
  let event: NuxieEvent
  let response: Task<EventResponse, Never>
  /// Monotonic order assigned where the direct-delivery tail is linked.
  let sequence: UInt64
}

protocol EventCapturing: AnyObject, Sendable {
  func track(
    _ event: String,
    properties: [String: Any]?,
    userProperties: [String: Any]?,
    userPropertiesSetOnce: [String: Any]?
  )
  func track(
    _ event: String,
    properties: [String: Any]?,
    userProperties: [String: Any]?,
    userPropertiesSetOnce: [String: Any]?,
    distinctIdOverride: String
  )
}

protocol EventTriggerTracking: AnyObject, Sendable {
  func prepareTriggerProperties(
    _ properties: sending [String: Any]?,
    userProperties: sending [String: Any]?,
    userPropertiesSetOnce: sending [String: Any]?
  ) async -> sending [String: Any]
  func applyBeforeSend(to event: NuxieEvent) async -> NuxieEvent?
  func storePreparedEventInHistory(_ event: NuxieEvent) async
  func commitPreparedTriggerEvent(_ event: NuxieEvent) async -> PreparedTriggerCommit
  func trackForTrigger(
    _ event: String,
    properties: sending [String: Any]?,
    userProperties: sending [String: Any]?,
    userPropertiesSetOnce: sending [String: Any]?,
    persistToHistory: Bool,
    distinctIdOverride: String?
  ) async throws -> (NuxieEvent, EventResponse)
  func trackForTrigger(
    _ event: String,
    properties: sending [String: Any]?,
    userProperties: sending [String: Any]?,
    userPropertiesSetOnce: sending [String: Any]?
  ) async throws -> (NuxieEvent, EventResponse)
  func trackWithResponse(
    _ event: String,
    properties: sending [String: Any]?
  ) async throws -> EventResponse
  func trackWithResponse(
    _ event: String,
    properties: sending [String: Any]?,
    flushStrategy: EventFlushStrategy
  ) async throws -> EventResponse
}

protocol EventHistoryReading: AnyObject, Sendable {
  func getRecentEvents(limit: Int) async -> [StoredEvent]
  func getEventsForUser(_ distinctId: String, limit: Int) async -> [StoredEvent]
  func getEventsForUser(
    _ distinctId: String,
    name: String,
    since: Date?,
    until: Date?,
    ascending: Bool,
    limit: Int
  ) async -> [StoredEvent]
  func getEvents(for sessionId: String) async -> [StoredEvent]
}

protocol EventQuerySource: EventHistoryReading, IREventQueries {}

protocol EventQueueLifecycle: AnyObject, Sendable {
  func onAppDidEnterBackground() async
  func onAppBecameActive() async
}

protocol EventIdentityMigrating: AnyObject, Sendable {
  func reassignEvents(from fromUserId: String, to toUserId: String) async throws -> Int
}

protocol ProfileEventSink: AnyObject, Sendable {
  func commitServerFacts(_ facts: [JourneyDownFact], distinctId: String) async
  func setMailboxPendingHandler(_ handler: (@Sendable () async -> Void)?) async
}

protocol JourneyRunnerEventAccess: EventCapturing, EventTriggerTracking {
  func drain() async
}

protocol JourneyEventAccess:
  JourneyRunnerEventAccess,
  EventHistoryReading
{
  func setJourneyOwnershipRejectedHandler(
    _ handler: (@Sendable (_ journeyId: String, _ epoch: Int) async -> Void)?
  ) async
  func setJourneyHandoffDeliveredHandler(
    _ handler: (@Sendable (_ journeyId: String) async -> Void)?
  ) async
}

/// Protocol for the unified event log: capture → enrich → persist → deliver → query.
protocol EventLogProtocol:
  EventQuerySource,
  EventQueueLifecycle,
  EventIdentityMigrating,
  ProfileEventSink,
  JourneyEventAccess,
  JourneyRunnerEventAccess
{
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
    _ properties: sending [String: Any]?,
    userProperties: sending [String: Any]?,
    userPropertiesSetOnce: sending [String: Any]?
  ) async -> sending [String: Any]

  /// Persist a fully prepared trigger event into local history without re-enqueuing it.
  func storePreparedEventInHistory(_ event: NuxieEvent) async

  /// Commit server-born facts into local history without uploading them.
  /// Newly committed facts are routed through the committed-event subscriber lane.
  func commitServerFacts(_ facts: [JourneyDownFact], distinctId: String) async

  /// Register the profile-refresh hook used by event-response mailbox hints.
  func setMailboxPendingHandler(
    _ handler: (@Sendable () async -> Void)?
  ) async

  /// Register the owner that discards a local run after an epoch CAS reject.
  func setJourneyOwnershipRejectedHandler(
    _ handler: (@Sendable (_ journeyId: String, _ epoch: Int) async -> Void)?
  ) async

  /// Register the owner that terminates a local run after a handoff is accepted.
  func setJourneyHandoffDeliveredHandler(
    _ handler: (@Sendable (_ journeyId: String) async -> Void)?
  ) async

  /// Track an event and return both the enriched event and server response
  func trackForTrigger(
    _ event: String,
    properties: sending [String: Any]?,
    userProperties: sending [String: Any]?,
    userPropertiesSetOnce: sending [String: Any]?,
    persistToHistory: Bool,
    distinctIdOverride: String?
  ) async throws -> (NuxieEvent, EventResponse)

  /// Track an event synchronously and wait for server response
  func trackWithResponse(
    _ event: String,
    properties: sending [String: Any]?
  ) async throws -> EventResponse

  /// Track an event synchronously, optionally flushing queued events before the round trip.
  func trackWithResponse(
    _ event: String,
    properties: sending [String: Any]?,
    flushPendingEvents: Bool
  ) async throws -> EventResponse

  /// Track an event synchronously, using an explicit pending-event flush strategy.
  func trackWithResponse(
    _ event: String,
    properties: sending [String: Any]?,
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
  func getEventsForUser(
    _ distinctId: String,
    name: String,
    since: Date?,
    until: Date?,
    ascending: Bool,
    limit: Int
  ) async -> [StoredEvent]
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

extension EventLogProtocol {
  func subscribeCommitted(handler: @escaping CommittedEventHandler) async {
    await subscribeCommitted(where: nil, handler: handler)
  }

  func getEventsForUser(
    _ distinctId: String,
    name: String,
    since: Date?,
    until: Date?,
    ascending: Bool,
    limit: Int
  ) async -> [StoredEvent] {
    let events = await getEventsForUser(distinctId, limit: .max)
      .filter { $0.name == name }
      .filter { event in
        if let since, event.timestamp < since { return false }
        if let until, event.timestamp > until { return false }
        return true
      }
      .sorted {
        if $0.timestamp == $1.timestamp {
          return ascending ? $0.id < $1.id : $0.id > $1.id
        }
        return ascending ? $0.timestamp < $1.timestamp : $0.timestamp > $1.timestamp
      }
    return Array(events.prefix(limit))
  }

  func prepareTriggerProperties(
    _ properties: sending [String: Any]? = nil,
    userProperties: sending [String: Any]? = nil,
    userPropertiesSetOnce: sending [String: Any]? = nil
  ) async -> sending [String: Any] {
    var finalProperties = properties ?? [:]
    if let userProperties { finalProperties["$set"] = userProperties }
    if let userPropertiesSetOnce { finalProperties["$set_once"] = userPropertiesSetOnce }
    return finalProperties
  }

  func applyBeforeSend(to event: NuxieEvent) async -> NuxieEvent? {
    event
  }

  func trackForTrigger(
    _ event: String,
    properties: sending [String: Any]? = nil,
    userProperties: sending [String: Any]? = nil,
    userPropertiesSetOnce: sending [String: Any]? = nil
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
    properties: sending [String: Any]?,
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
actor EventLog: EventLogProtocol {

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
  private var mailboxPendingHandler: (@Sendable () async -> Void)?
  private var journeyOwnershipRejectedHandler:
    (@Sendable (_ journeyId: String, _ epoch: Int) async -> Void)?
  private var journeyHandoffDeliveredHandler:
    (@Sendable (_ journeyId: String) async -> Void)?

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
  private let apiClient: EventTransport

  private var contextBuilder: NuxieContextBuilder?
  private var configuration: NuxieSetupConfiguration?

  // MARK: - Committed-event subscribers

  private struct Subscriber {
    let filter: (@Sendable (NuxieEvent) -> Bool)?
    let handler: CommittedEventHandler
  }
  private var subscribers: [Subscriber] = []

  // MARK: - Delivery (durable queue + bounded in-memory window)

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
  private var activeDirectDeliveryIds: Set<String> = []
  private var preparedCommitCount = 0
  private var preparedCommitDrainWaiters: [CheckedContinuation<Void, Never>] = []
  private var preparedDeliveryTasks: [UUID: Task<EventResponse, Never>] = [:]
  private var preparedDeliveryTail: (id: UUID, task: Task<EventResponse, Never>)?
  private var nextPreparedDeliverySequence: UInt64 = 0
  private var nonDurableDeliveryIds: Set<String> = []
  private var isRefillingDeliveryWindow = false
  private var deliveryWindowRefillRequested = false

  // MARK: - Initialization

  public init(
    identity: IdentityServiceProtocol,
    sessions: SessionServiceProtocol,
    dateProvider: DateProviderProtocol,
    apiClient: EventTransport,
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

  private func configure(snapshot: NuxieSetupConfiguration?) async throws {
    guard !closeFlag.isClosed else {
      LogWarning("EventLog.configure called after close; ignoring")
      return
    }

    self.configuration = snapshot
    self.contextBuilder = NuxieContextBuilder(
      identityService: identityService,
      configuration: snapshot
    )

    if let configuration = snapshot {
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
      try await store.initialize(path: snapshot?.customStoragePath)
    } catch {
      // Storage should never wedge the SDK (or tests). If storage init fails, we still allow
      // network delivery and local evaluation to proceed with a best-effort store.
      LogWarning("EventLog storage initialization failed: \(error)")
    }

    // Durable delivery: rehydrate the oldest events a previous session
    // persisted but never delivered. The store acks them after delivery.
    await refillDeliveryWindow()

    // Only start the periodic flush timer outside tests.
    if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
      startFlushTimer()
    }

    LogInfo("EventLog configured (subscribers: \(subscribers.count))")
    // Signal that storage is initialized and safe to use
    await ready.open()
  }

  nonisolated public func configure(configuration: NuxieConfiguration?) async throws {
    try await configure(snapshot: configuration.map(NuxieSetupConfiguration.init))
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
    track(
      event,
      properties: properties,
      userProperties: userProperties,
      userPropertiesSetOnce: userPropertiesSetOnce,
      distinctIdOverride: identityService.getDistinctId()
    )
  }

  public nonisolated func track(
    _ event: String,
    properties: [String: Any]? = nil,
    userProperties: [String: Any]? = nil,
    userPropertiesSetOnce: [String: Any]? = nil,
    distinctIdOverride: String
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

    let payload = TrackPayload(
      name: event,
      properties: custom,
      forcedDistinctId: distinctIdOverride
    )

    captureContinuation.yield(.track(payload))
  }

  public func trackWithResponse(
    _ event: String,
    properties: sending [String: Any]? = nil
  ) async throws -> EventResponse {
    try await trackWithResponse(
      event,
      properties: properties,
      flushPendingEvents: true
    )
  }

  public func trackWithResponse(
    _ event: String,
    properties: sending [String: Any]? = nil,
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

    // Boxed so the same snapshot can cross into the API client while
    // remaining readable here (each load is a fresh disconnected region).
    let finalProperties = UncheckedSendable(
      await buildTriggerProperties(
        properties,
        userProperties: nil,
        userPropertiesSetOnce: nil
      ))

    // Store event locally (for history)
    do {
      try await storeHistoryEvent(
        name: event, properties: finalProperties.value, distinctId: distinctId)
    } catch {
      LogWarning("Failed to store event locally: \(error)")
      // Continue - server tracking is more important for journey events
    }

    // Send directly to API, then commit any server-born facts without re-uploading them.
    let response = try await apiClient.trackEvent(
      event: event,
      distinctId: distinctId,
      properties: finalProperties.value,
      value: finalProperties.value["value"] as? Double,
      entityId: finalProperties.value["entityId"] as? String
    )
    await commitServerFacts(response.facts ?? [], distinctId: distinctId)
    await handleEventResponseSignals(response)
    return response
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
    properties: sending [String: Any]? = nil,
    userProperties: sending [String: Any]? = nil,
    userPropertiesSetOnce: sending [String: Any]? = nil,
    persistToHistory: Bool = true,
    distinctIdOverride: String? = nil
  ) async throws -> (NuxieEvent, EventResponse) {
    guard !event.isEmpty else {
      throw NuxieError.invalidConfiguration("Event name cannot be empty")
    }

    await ready.wait()

    _ = await flushEvents()

    let distinctId = distinctIdOverride ?? identityService.getDistinctId()

    // Boxed so the same snapshot can cross into the API client while
    // remaining readable here (each load is a fresh disconnected region).
    let finalProperties = UncheckedSendable(
      await buildTriggerProperties(
        properties,
        userProperties: userProperties,
        userPropertiesSetOnce: userPropertiesSetOnce
      ))

    // The canonical local event exists before anything else observes it. Its
    // UUIDv7 id is the durable-delivery idempotency key if the row later
    // rides the batch queue.
    let localEvent = NuxieEvent(
      name: event,
      distinctId: distinctId,
      properties: finalProperties.value
    )

    var wasPersisted = false
    if persistToHistory {
      // Reserve the id before the store await. EventLog is reentrant while
      // SQLite runs, so refill must already know this row belongs to the
      // direct request rather than the batch lane.
      activeDirectDeliveryIds.insert(localEvent.id)
      do {
        let stored = try StoredEvent(
          id: localEvent.id,
          name: localEvent.name,
          properties: localEvent.properties,
          timestamp: localEvent.timestamp,
          distinctId: localEvent.distinctId
        )
        try await store.insertPending(stored)
        wasPersisted = true
        try await performCleanupIfNeeded()
      } catch {
        LogWarning("Failed to store event locally: \(error)")
      }
    }

    do {
      let response = try await apiClient.trackEvent(localEvent)
      await commitServerFacts(response.facts ?? [], distinctId: distinctId)
      await handleEventResponseSignals(response)

      if persistToHistory {
        // The direct round trip delivered this event — ack the pending row
        // so the batch path never re-sends it.
        await completeDirectDelivery(ids: [localEvent.id])
      }

      let enrichedEvent = NuxieEvent(
        id: response.eventId ?? localEvent.id,
        name: event,
        distinctId: distinctId,
        properties: finalProperties.value,
        timestamp: localEvent.timestamp
      )
      return (enrichedEvent, response)
    } catch {
      // Transport failure: keep the row pending and stage it for durable
      // batch delivery (next flush/timer/launch; the server dedupes on the
      // event-id idempotency key). Degrade to local evaluation instead of
      // failing the trigger.
      if event == JourneyEvents.journeyClaimed {
        if persistToHistory {
          await completeDirectDelivery(ids: [localEvent.id])
        }
        throw error
      }
      if persistToHistory {
        activeDirectDeliveryIds.remove(localEvent.id)
        await enqueueForDelivery(localEvent, isPersisted: wasPersisted)
      }
      if event == JourneyEvents.journeyHandoff {
        throw error
      }
      LogWarning(
        "trackForTrigger round trip failed for '\(event)'; continuing local-first: \(error)")
      let offlineResponse = EventResponse(status: "offline", eventId: localEvent.id)
      return (localEvent, offlineResponse)
    }
  }

  /// Persist an already-enriched trigger event under its existing id, then
  /// start its direct server round trip independently of the caller's local
  /// journey dispatch. This is the authored-runtime path: the exact persisted
  /// id is also the conversion source fact and delivery idempotency key.
  public func commitPreparedTriggerEvent(
    _ event: NuxieEvent
  ) async -> PreparedTriggerCommit {
    await ready.wait()
    guard !closeFlag.isClosed else { return offlinePreparedCommit(for: event) }

    // Preserve capture order without coupling local authored-event routing to
    // network latency. Reaching this barrier means every earlier fire-and-
    // forget capture is durably committed and available to journey queries.
    await drainCaptureWorker()
    guard !closeFlag.isClosed else { return offlinePreparedCommit(for: event) }

    // Teardown waits for this whole durable-commit phase. Register before the
    // first store await so close cannot snapshot an empty delivery-task set,
    // close storage, and strand a commit that has not created its task yet.
    preparedCommitCount += 1
    defer { preparedCommitDidFinish() }

    extractUserProperties(from: event)
    activeDirectDeliveryIds.insert(event.id)
    var wasPersisted = false
    do {
      try await store.insertPending(makeStoredEvent(from: event))
      wasPersisted = true
      try await performCleanupIfNeeded()
    } catch {
      LogWarning("Failed to store prepared trigger event locally: \(error)")
    }
    guard !closeFlag.isClosed else {
      activeDirectDeliveryIds.remove(event.id)
      return offlinePreparedCommit(for: event)
    }

    let taskID = UUID()
    let sequence = nextPreparedDeliverySequence
    nextPreparedDeliverySequence += 1
    let previousDelivery = preparedDeliveryTail?.task
    let response = Task { [weak self] in
      _ = await previousDelivery?.value
      guard let self else {
        return EventResponse(status: "offline", eventId: event.id)
      }
      let response: EventResponse
      if Task.isCancelled {
        response = EventResponse(status: "offline", eventId: event.id)
      } else {
        response = await self.deliverPreparedTriggerEvent(
          event,
          wasPersisted: wasPersisted
        )
      }
      await self.preparedDeliveryDidFinish(taskID)
      return response
    }
    preparedDeliveryTasks[taskID] = response
    preparedDeliveryTail = (taskID, response)
    return PreparedTriggerCommit(event: event, response: response, sequence: sequence)
  }

  private func offlinePreparedCommit(for event: NuxieEvent) -> PreparedTriggerCommit {
    let sequence = nextPreparedDeliverySequence
    nextPreparedDeliverySequence += 1
    return PreparedTriggerCommit(
      event: event,
      response: Task { EventResponse(status: "offline", eventId: event.id) },
      sequence: sequence
    )
  }

  private func preparedCommitDidFinish() {
    preparedCommitCount -= 1
    guard preparedCommitCount == 0 else { return }
    let waiters = preparedCommitDrainWaiters
    preparedCommitDrainWaiters.removeAll()
    waiters.forEach { $0.resume() }
  }

  private func waitForPreparedCommitsToFinish() async {
    guard preparedCommitCount > 0 else { return }
    await withCheckedContinuation { preparedCommitDrainWaiters.append($0) }
  }

  private func preparedDeliveryDidFinish(_ taskID: UUID) {
    _ = preparedDeliveryTasks.removeValue(forKey: taskID)
    if preparedDeliveryTail?.id == taskID {
      preparedDeliveryTail = nil
    }
  }

  private func deliverPreparedTriggerEvent(
    _ event: NuxieEvent,
    wasPersisted: Bool
  ) async -> EventResponse {
    let olderEventsDrained = await deliveryFlushAll()
    guard olderEventsDrained else {
      activeDirectDeliveryIds.remove(event.id)
      await enqueueForDelivery(event, isPersisted: wasPersisted)
      LogWarning(
        "Deferred prepared trigger '\(event.name)' because older pending delivery did not drain"
      )
      return EventResponse(status: "offline", eventId: event.id)
    }
    guard !Task.isCancelled else {
      activeDirectDeliveryIds.remove(event.id)
      return EventResponse(status: "offline", eventId: event.id)
    }
    do {
      let response = try await apiClient.trackEvent(event)
      try Task.checkCancellation()
      await commitServerFacts(response.facts ?? [], distinctId: event.distinctId)
      await handleEventResponseSignals(response)
      await completeDirectDelivery(ids: [event.id])
      return response
    } catch {
      activeDirectDeliveryIds.remove(event.id)
      guard !Task.isCancelled else {
        return EventResponse(status: "offline", eventId: event.id)
      }
      await enqueueForDelivery(event, isPersisted: wasPersisted)
      LogWarning(
        "Prepared trigger round trip failed for '\(event.name)'; continuing local-first: \(error)"
      )
      return EventResponse(status: "offline", eventId: event.id)
    }
  }

  public func prepareTriggerProperties(
    _ properties: sending [String: Any]?,
    userProperties: sending [String: Any]?,
    userPropertiesSetOnce: sending [String: Any]?
  ) async -> sending [String: Any] {
    await ready.wait()
    return await buildTriggerProperties(
      properties,
      userProperties: userProperties,
      userPropertiesSetOnce: userPropertiesSetOnce
    )
  }

  public func applyBeforeSend(to event: NuxieEvent) async -> NuxieEvent? {
    guard let beforeSend = configuration?.beforeSend else { return event }
    return beforeSend(event)
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

  public func commitServerFacts(_ facts: [JourneyDownFact], distinctId: String) async {
    guard !facts.isEmpty else { return }
    await ready.wait()

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

    for fact in facts {
      var properties: [String: Any]
      switch fact.properties {
      case .converted(let converted):
        properties = [
          "journey_id": converted.journeyId,
          "at": formatter.string(from: converted.at),
          "source_fact_ref": converted.sourceFactRef,
        ]
      case .effectCompleted(let completed):
        properties = [
          "journey_id": completed.journeyId,
          "node_id": completed.nodeId,
          "invocation_id": completed.invocationId,
          "status": completed.status,
        ]
        if let result = completed.result {
          properties["result"] = result.value
        }
        if let error = completed.error {
          properties["error"] = error.value
        }
      case .superseded(let superseded):
        properties = [
          "journey_id": superseded.journeyId,
        ]
        if let winnerJourneyId = superseded.winnerJourneyId {
          properties["winner_journey_id"] = winnerJourneyId
        }
      }
      properties["$server_fact_id"] = fact.id
      properties[StoredEvent.originProperty] = StoredEventOrigin.server.rawValue
      let event = NuxieEvent(
        id: fact.id,
        name: fact.event.rawValue,
        distinctId: distinctId,
        properties: properties,
        timestamp: fact.timestamp
      )

      do {
        let inserted = try await store.insertHistoryIfAbsent(makeStoredEvent(from: event))
        if inserted {
          try await performCleanupIfNeeded()
          routeContinuation.yield(.event(event))
        }
      } catch {
        LogWarning("Failed to commit server fact \(fact.id): \(error)")
      }
    }
  }

  public func setMailboxPendingHandler(
    _ handler: (@Sendable () async -> Void)?
  ) async {
    mailboxPendingHandler = handler
  }

  public func setJourneyOwnershipRejectedHandler(
    _ handler: (@Sendable (_ journeyId: String, _ epoch: Int) async -> Void)?
  ) async {
    journeyOwnershipRejectedHandler = handler
  }

  public func setJourneyHandoffDeliveredHandler(
    _ handler: (@Sendable (_ journeyId: String) async -> Void)?
  ) async {
    journeyHandoffDeliveredHandler = handler
  }

  private func handleEventResponseSignals(_ response: EventResponse) async {
    if response.mailboxPending == true, let mailboxPendingHandler {
      await mailboxPendingHandler()
    }
    if let ownership = response.journeyClaim,
       !ownership.accepted,
       let journeyOwnershipRejectedHandler {
      await journeyOwnershipRejectedHandler(
        ownership.journeyId,
        ownership.epoch
      )
    }
    if let ownership = response.journeyOwnership {
      if ownership.accepted {
        await journeyHandoffDeliveredHandler?(ownership.journeyId)
      } else {
        await journeyOwnershipRejectedHandler?(
          ownership.journeyId,
          ownership.epoch
        )
      }
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

    // A commit may already be between its capture barrier and delivery-task
    // registration. Let that durable phase observe closure and settle before
    // collecting the independently running request tasks below.
    await waitForPreparedCommitsToFinish()

    // A prepared authored event owns an independent direct request. Cancel
    // and settle every such request while its durable store is still open;
    // no response callback or fallback queue mutation may outlive teardown.
    let preparedDeliveries = Array(preparedDeliveryTasks.values)
    preparedDeliveries.forEach { $0.cancel() }
    for delivery in preparedDeliveries {
      _ = await delivery.value
    }
    preparedDeliveryTasks.removeAll()
    preparedDeliveryTail = nil

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
      // A pending row owned by an active direct request is not batch work.
      // Refill first so the return value describes work this flush can
      // actually initiate, rather than merely observing the direct row.
      await refillDeliveryWindow()
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
    var wasPersisted = false
    do {
      let stored = try StoredEvent(
        id: event.id,
        name: event.name,
        properties: event.properties,
        timestamp: event.timestamp,
        distinctId: event.distinctId
      )
      try await store.insertPending(stored)
      wasPersisted = true
      try await performCleanupIfNeeded()
    } catch {
      LogError("Failed to store event locally: \(error)")
      // Continue routing to other services even if storage fails
    }

    // Network ordering: enqueue before subscriber routing so lifecycle calls
    // can flush this hit.
    await enqueueForDelivery(event, isPersisted: wasPersisted)

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
    _ properties: sending [String: Any]?,
    userProperties: sending [String: Any]?,
    userPropertiesSetOnce: sending [String: Any]?
  ) async -> sending [String: Any] {
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

  private func enrich(_ custom: sending [String: Any]) async -> sending [String: Any] {
    // Boxed to hand the write-once snapshot across the context builder.
    let sanitized = UncheckedSendable(EventSanitizer.sanitizeDataTypes(custom))
    guard let contextBuilder else {
      return sanitized.value
    }
    return await contextBuilder.buildEnrichedProperties(customProperties: sanitized.value)
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

  @discardableResult
  private func markDelivered(ids: [String]) async -> Bool {
    do {
      try await store.markDelivered(ids: ids)
      return true
    } catch {
      // Worst case these rows re-send after relaunch; the server dedupes
      // on the event-id idempotency key.
      LogWarning("Failed to mark \(ids.count) events delivered: \(error)")
      return false
    }
  }

  /// Direct-send events are not already in the working set. If their store
  /// ack fails, stage them from pending state immediately instead of waiting
  /// for a relaunch to recover them.
  private func completeDirectDelivery(ids: [String]) async {
    _ = await markDelivered(ids: ids)
    activeDirectDeliveryIds.subtract(ids)
    await refillDeliveryWindow()
  }

  /// Remove rows from the working set only after the store ack attempt. This
  /// keeps the window full while the actor is reentrant, so a newly captured
  /// event cannot jump ahead of older durable rows. If the ack fails, refill
  /// stages the same ids again from the authoritative pending state.
  private func removeFromDeliveryWindow(ids: [String]) async {
    let idSet = Set(ids)
    deliveryQueue.removeAll { idSet.contains($0.id) }
    nonDurableDeliveryIds.subtract(idSet)
    await refillDeliveryWindow()
  }

  // MARK: - Delivery queue

  /// Fill the bounded working set from the oldest durable pending rows.
  /// Persisted state, not this array, decides whether an event needs delivery.
  private func refillDeliveryWindow() async {
    guard !isRefillingDeliveryWindow else {
      deliveryWindowRefillRequested = true
      return
    }

    isRefillingDeliveryWindow = true
    defer { isRefillingDeliveryWindow = false }

    let capacity = max(1, deliveryConfig.maxQueueSize)
    repeat {
      deliveryWindowRefillRequested = false
      guard deliveryQueue.count < capacity else { return }

      let pending = await loadPendingDelivery(
        limit: capacity + activeDirectDeliveryIds.count
      )
      guard !closeFlag.isClosed else { return }

      let existing = Set(deliveryQueue.map(\.id))
      let fresh = pending
        .filter {
          !existing.contains($0.id) && !activeDirectDeliveryIds.contains($0.id)
        }
        .prefix(capacity - deliveryQueue.count)
      if !fresh.isEmpty {
        deliveryQueue.append(contentsOf: fresh)
        LogDebug(
          "Filled delivery window with \(fresh.count) durable events (window: \(deliveryQueue.count)/\(capacity))"
        )
      }
    } while deliveryWindowRefillRequested && deliveryQueue.count < capacity
  }

  /// Stage a newly captured event in the bounded working set. Production
  /// callers persist first, so a full window only defers staging; it never
  /// drops durable delivery state. `isPersisted` is explicit because tests
  /// can also exercise the storage-failure path with memory-only fixtures.
  func enqueueForDelivery(_ event: NuxieEvent, isPersisted: Bool = true) async {
    guard !deliveryQueue.contains(where: { $0.id == event.id }) else { return }

    if isPersisted && isRefillingDeliveryWindow {
      // The in-flight refill owns the exposed capacity. Ask it to query again
      // rather than letting this newer event overtake older durable rows.
      deliveryWindowRefillRequested = true
      Task { await self.flushIfOverThreshold() }
      return
    }

    let capacity = max(1, deliveryConfig.maxQueueSize)
    guard deliveryQueue.count < capacity else {
      if isPersisted {
        LogDebug(
          "Delivery window full; event \(event.id) remains pending in durable storage"
        )
      } else {
        // Persistence failed, so there is no durable row to refill later.
        // Make one best-effort attempt to free capacity before admitting loss.
        let drained = await deliveryFlushAll()
        guard drained, deliveryQueue.count < capacity else {
          LogError(
            "Unable to stage non-durable event \(event.id): persistence failed and the delivery window could not be drained"
          )
          return
        }
        deliveryQueue.append(event)
        nonDurableDeliveryIds.insert(event.id)
        LogWarning(
          "Staged non-durable event \(event.id) after persistence failure; delivery must complete in this process"
        )
      }
      Task { await self.flushIfOverThreshold() }
      return
    }

    deliveryQueue.append(event)
    if !isPersisted {
      nonDurableDeliveryIds.insert(event.id)
    }
    LogDebug("Staged event: \(event.name) (delivery window: \(deliveryQueue.count))")

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
    do {
      // Memory-only delivery fixtures are intentionally supported by the
      // internal enqueue entry point; production events are always counted
      // by the durable store.
      return max(try await store.getPendingDeliveryCount(), deliveryQueue.count)
    } catch {
      LogWarning("Failed to count pending-delivery events: \(error)")
      return deliveryQueue.count
    }
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

    await refillDeliveryWindow()
    // Trigger flush if we have events
    await flushIfOverThreshold()
  }

  private func flushIfOverThreshold() async {
    guard !isPaused, !isCurrentlyFlushing else { return }

    // Check retry backoff
    if let nextRetry = nextRetryDate, Date() < nextRetry {
      return  // Still in backoff period
    }

    let pendingCount = await getQueuedEventCount()
    if pendingCount >= deliveryConfig.flushAt {
      LogDebug(
        "Delivery threshold reached (\(pendingCount) >= \(deliveryConfig.flushAt)), triggering flush"
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

      await refillDeliveryWindow()
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
    await refillDeliveryWindow()
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

    if let decision = deliveryQueue.first,
      isJourneyDecisionEvent(decision.name) {
      if decision.name == JourneyEvents.journeyClaimed {
        let removed = await retireDelivered(ids: [decision.id])
        if removed {
          retryCount = 0
          nextRetryDate = nil
        }
        finishCurrentFlush()
        LogWarning(
          "Dropped pending journey claim \(decision.id); mailbox refresh must retry claims with their offer"
        )
        if removed {
          await flushIfOverThreshold()
        }
        return true
      }
      await deliverJourneyDecision(decision)
      return true
    }

    // Never let a decision-lane event leak into a batch behind accepted events.
    let batch = Array(
      deliveryQueue
        .prefix(deliveryConfig.maxBatchSize)
        .prefix { !isJourneyDecisionEvent($0.name) }
    )

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

  private func isJourneyDecisionEvent(_ name: String) -> Bool {
    switch name {
    case JourneyEvents.journeyEnrolled,
      JourneyEvents.journeyTransition,
      JourneyEvents.journeyMilestone,
      JourneyEvents.journeyConverted,
      JourneyEvents.journeyExited,
      JourneyEvents.journeyEffectRequested,
      JourneyEvents.journeyClaimed,
      JourneyEvents.journeyHandoff,
      JourneyEvents.journeyParked:
      return true
    default:
      return false
    }
  }

  private func deliverJourneyDecision(_ event: NuxieEvent) async {
    do {
      let response = try await apiClient.trackEvent(event)
      await commitServerFacts(response.facts ?? [], distinctId: event.distinctId)
      await handleEventResponseSignals(response)
      let removed = await retireDelivered(ids: [event.id])
      if removed {
        retryCount = 0
        nextRetryDate = nil
      }
      finishCurrentFlush()
      LogInfo(
        "Successfully delivered journey decision \(event.name) (queue size: \(deliveryQueue.count))"
      )
      if removed {
        await flushIfOverThreshold()
      }
    } catch {
      if isPermanentBatchFailure(error) {
        let removed = await retireDelivered(ids: [event.id])
        if removed {
          retryCount = 0
          nextRetryDate = nil
        }
        LogWarning(
          "Permanent journey decision failure; dropped \(event.id): \(error)"
        )
        finishCurrentFlush()
        return
      }

      retryCount += 1
      let cappedExponent = min(
        retryCount - 1,
        max(deliveryConfig.maxRetries - 1, 0)
      )
      let backoffDelay =
        deliveryConfig.baseRetryDelay * pow(2, Double(cappedExponent))
      nextRetryDate = Date().addingTimeInterval(backoffDelay)
      LogWarning(
        "Journey decision delivery failed; keeping \(event.id) pending for direct retry in \(backoffDelay)s: \(error)"
      )
      finishCurrentFlush()
    }
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
    let batchIds = batch.map { $0.id }
    let removed = await retireDelivered(ids: batchIds)

    if removed {
      retryCount = 0
      nextRetryDate = nil
    }

    finishCurrentFlush()

    LogInfo("Successfully delivered \(batch.count) events (queue size: \(deliveryQueue.count))")

    if removed {
      await flushIfOverThreshold()
    }
  }

  /// Retires transported events while preserving the store as authority for
  /// durable rows. Memory-only events have no row to acknowledge and must be
  /// removed independently, even when the store is still unavailable.
  @discardableResult
  private func retireDelivered(ids: [String]) async -> Bool {
    let nonDurableIds = ids.filter { nonDurableDeliveryIds.contains($0) }
    let durableIds = ids.filter { !nonDurableDeliveryIds.contains($0) }
    let durableAcknowledged = durableIds.isEmpty
      ? true
      : await markDelivered(ids: durableIds)

    var removableIds = nonDurableIds
    if durableAcknowledged {
      removableIds.append(contentsOf: durableIds)
    }
    guard !removableIds.isEmpty else { return false }
    await removeFromDeliveryWindow(ids: removableIds)
    return true
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
      if !successfulIds.isEmpty,
         await retireDelivered(ids: Array(successfulIds)) {
        removedAnyEvents = true
      }
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
      let batchIds = batch.map { $0.id }
      let removed = await retireDelivered(ids: batchIds)
      if removed {
        retryCount = 0
        nextRetryDate = nil
      }
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
    nonDurableDeliveryIds.removeAll()
    LogInfo("Cleared \(count) events from delivery queue")
  }

  private func handleTimerFlush() async {
    await refillDeliveryWindow()
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

  public func getEventsForUser(
    _ distinctId: String,
    name: String,
    since: Date?,
    until: Date?,
    ascending: Bool,
    limit: Int
  ) async -> [StoredEvent] {
    await ready.wait()
    do {
      return try await store.queryEventsForUser(
        distinctId,
        name: name,
        since: since,
        until: until,
        ascending: ascending,
        limit: limit
      )
    } catch {
      LogError("Failed to get '\(name)' events for user \(distinctId): \(error)")
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
    let events = merged.sorted {
      if $0.timestamp == $1.timestamp { return $0.id < $1.id }
      return $0.timestamp < $1.timestamp
    }
    return IREventSequenceMatcher.matches(
      events: events,
      steps: steps,
      overallWithin: overallWithin,
      perStepWithin: perStepWithin
    )
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
