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
  case durable(CommittedCapture, handlers: [DurableCommitHandler])
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

/// A newly persisted capture as observed by host-side analytics forwarding.
/// The canonical name is retained before `beforeSend` so a host rename cannot
/// change which typed activity the SDK reports.
struct CommittedCapture: Sendable {
  let canonicalName: String
  let event: NuxieEvent
  let occurredAt: Date
  let receivedAt: Date
}

typealias DurableCommitHandler = @Sendable (CommittedCapture) async -> Void

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

struct DurableTriggerCapture: Sendable {
  let event: NuxieEvent
  /// Terminal beforeSend drops acknowledge recovery without entering Journey
  /// routing or network delivery.
  let routesLocally: Bool

  init(event: NuxieEvent, routesLocally: Bool = true) {
    self.event = event
    self.routesLocally = routesLocally
  }
}

/// Result of committing a journey-authored stable event whose ownership can
/// be revoked by an authoritative event response while capture is suspended.
enum DurableOwnedTriggerCaptureResult: Sendable {
  case captured(DurableTriggerCapture)
  case ownershipLost
  case failed
}

/// Durable ownership lookup result. `unavailable` is intentionally distinct
/// from confirmed loss: callers must fail closed without deleting the only
/// retry record when storage is transiently unreadable.
enum JourneyEventOwnershipState: Equatable, Sendable {
  case owned
  case ownershipLost
  case unavailable
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
  func captureSystemEvent(
    _ event: String,
    properties: sending [String: Any]?,
    eventId: String,
    distinctId: String
  ) async -> DurableTriggerCapture?
  func captureOwnedJourneySystemEvent(
    _ event: String,
    properties: sending [String: Any]?,
    eventId: String,
    distinctId: String,
    ownership: JourneyEventOwnership
  ) async -> DurableOwnedTriggerCaptureResult
  func journeyEventOwnershipState(
    _ ownership: JourneyEventOwnership
  ) async -> JourneyEventOwnershipState
  /// Persist a server-accepted system event for history/forwarding without
  /// uploading it again.
  func captureAcceptedSystemEvent(
    _ event: String,
    properties: sending [String: Any]?,
    eventId: String,
    distinctId: String
  ) async -> Bool
  func prepareTriggerProperties(
    _ properties: sending [String: Any]?
  ) async -> sending [String: Any]
  func applyBeforeSend(to event: NuxieEvent) async -> NuxieEvent?
  func storePreparedEventInHistory(_ event: NuxieEvent) async
  func commitPreparedTriggerEvent(_ event: NuxieEvent) async -> PreparedTriggerCommit
  func trackForTrigger(
    _ event: String,
    properties: sending [String: Any]?,
    persistToHistory: Bool,
    distinctIdOverride: String?,
    applyBeforeSend: Bool
  ) async throws -> (NuxieEvent, EventResponse)
  func trackForTrigger(
    _ event: String,
    properties: sending [String: Any]?
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
  func trackWithResponse(
    _ event: String,
    properties: sending [String: Any]?,
    flushStrategy: EventFlushStrategy,
    distinctIdOverride: String?
  ) async throws -> EventResponse
}

extension EventTriggerTracking {
  /// Convenience admission check. Durable recovery code should inspect the
  /// tri-state result directly so unavailability is not mistaken for loss.
  func canAuthorJourneyEvents(
    _ ownership: JourneyEventOwnership
  ) async -> Bool {
    if case .owned = await journeyEventOwnershipState(ownership) {
      return true
    }
    return false
  }

  func captureSystemEvent(
    _ event: String,
    properties: sending [String: Any]?,
    eventId: String,
    distinctId: String
  ) async -> DurableTriggerCapture? {
    guard let tracked = try? await trackForTrigger(
      event,
      properties: properties,
      persistToHistory: true,
      distinctIdOverride: distinctId,
      applyBeforeSend: false
    ) else { return nil }
    return DurableTriggerCapture(event: tracked.0)
  }

  /// Test adapters that do not own durable event storage retain their existing
  /// capture behavior. EventLog overrides this with the ownership-fenced path.
  func captureOwnedJourneySystemEvent(
    _ event: String,
    properties: sending [String: Any]?,
    eventId: String,
    distinctId: String,
    ownership: JourneyEventOwnership
  ) async -> DurableOwnedTriggerCaptureResult {
    guard let capture = await captureSystemEvent(
      event,
      properties: properties,
      eventId: eventId,
      distinctId: distinctId
    ) else { return .failed }
    return .captured(capture)
  }

  func captureAcceptedSystemEvent(
    _ event: String,
    properties: sending [String: Any]?,
    eventId: String,
    distinctId: String
  ) async -> Bool {
    let enriched = await prepareTriggerProperties(properties)
    let exact = NuxieEvent(
      id: eventId,
      name: event,
      distinctId: distinctId,
      properties: enriched
    )
    guard let prepared = await applyBeforeSend(to: exact) else { return true }
    await storePreparedEventInHistory(prepared)
    return true
  }
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

/// Lossless storage seam used by IR. Unlike the application-facing history
/// reads above, errors must remain observable so authorization can fail closed.
protocol IREventHistoryReading: AnyObject, Sendable {
  func queryEventsForIR(
    _ distinctId: String,
    name: String,
    since: Date?,
    until: Date?,
    ascending: Bool,
    limit: Int
  ) async throws -> [StoredEvent]
}

protocol EventQuerySource: EventHistoryReading, IREventHistoryReading, IREventQueries {}

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
  func drainCapturedEvents() async
  func drain() async
}

extension JourneyRunnerEventAccess {
  func drainCapturedEvents() async {
    await drain()
  }
}

protocol JourneyEventAccess:
  JourneyRunnerEventAccess,
  EventHistoryReading
{
  /// Transient forwarding announce; see EventLogProtocol.
  func announceTransientActivity(canonicalName: String, event: NuxieEvent) async
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
  /// Configure the log from the immutable setup snapshot. Builds enrichment
  /// and delivery settings and opens storage.
  func configure(configuration: NuxieSetupConfiguration?) async throws

  /// Subscribe to committed events. Handlers run serially, in subscription
  /// order, after each event is persisted and staged for delivery. The
  /// filter runs before the handler; pass nil to receive every event.
  /// Subscribers registered before `configure` are guaranteed to observe
  /// every committed event.
  func subscribeCommitted(
    where filter: (@Sendable (NuxieEvent) -> Bool)?,
    handler: @escaping CommittedEventHandler
  ) async

  /// Announce a transient (non-persisted) system outcome to the forwarding
  /// pipeline. Scoped permission resolutions ride the transient lane, so this
  /// is their only path to `nuxieDidEmit`.
  func announceTransientActivity(canonicalName: String, event: NuxieEvent) async

  /// Subscribe to newly durable captures on the committed-events seam.
  /// Eligibility is snapshotted at commit time so late observers do not
  /// receive an earlier capture that was waiting behind route work.
  func subscribeCommitted(
    when isEnabled: @escaping @Sendable () -> Bool,
    handler: @escaping DurableCommitHandler
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
    _ properties: sending [String: Any]?
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
    persistToHistory: Bool,
    distinctIdOverride: String?,
    applyBeforeSend: Bool
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

}

extension EventLogProtocol {
  func announceTransientActivity(canonicalName: String, event: NuxieEvent) async {}

  func subscribeCommitted(handler: @escaping CommittedEventHandler) async {
    await subscribeCommitted(where: nil, handler: handler)
  }

  func subscribeCommitted(
    when isEnabled: @escaping @Sendable () -> Bool,
    handler: @escaping DurableCommitHandler
  ) async {}

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
    _ properties: sending [String: Any]? = nil
  ) async -> sending [String: Any] {
    properties ?? [:]
  }

  func applyBeforeSend(to event: NuxieEvent) async -> NuxieEvent? {
    event
  }

  func trackForTrigger(
    _ event: String,
    properties: sending [String: Any]? = nil
  ) async throws -> (NuxieEvent, EventResponse) {
    try await trackForTrigger(
      event,
      properties: properties,
      persistToHistory: true,
      distinctIdOverride: nil,
      applyBeforeSend: true
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

  func trackWithResponse(
    _ event: String,
    properties: sending [String: Any]?,
    flushStrategy: EventFlushStrategy
  ) async throws -> EventResponse {
    try await trackWithResponse(
      event,
      properties: properties,
      flushStrategy: flushStrategy,
      distinctIdOverride: nil
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
  /// Process-local backstop for a gap whose durable fence write also failed.
  /// The durable store is authoritative across relaunches; this value prevents
  /// unsafe answers for the remainder of the current process either way.
  private var volatileHistoryCoverageStart: Date?
  private static let irQueryLimit = 10_000
  private static let stableDropRetention: TimeInterval = 90 * 24 * 60 * 60
  private var mailboxPendingHandler: (@Sendable () async -> Void)?
  private var journeyOwnershipRejectedHandler:
    (@Sendable (_ journeyId: String, _ epoch: Int) async -> Void)?
  private var journeyHandoffDeliveredHandler:
    (@Sendable (_ journeyId: String) async -> Void)?
  /// Immediate process-local fence. The SQLite fence is authoritative across
  /// relaunch; this mirror also blocks capture when persisting the response
  /// fence itself fails or is still suspended.
  private var journeyOwnershipFences: [String: Int] = [:]
  /// Response-scoped ownership losses that have not yet reached the durable
  /// fence. Keeping their source association prevents a retry response that
  /// omits an already-returned signal from acknowledging or poison-dropping
  /// that source while this process remains alive.
  private var unresolvedJourneyOwnershipBySource:
    [String: [JourneyEventOwnership]] = [:]

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
  private struct DurableCommitSubscriber {
    let isEnabled: @Sendable () -> Bool
    let handler: DurableCommitHandler
  }
  private var subscribers: [Subscriber] = []
  private var durableCommitSubscribers: [DurableCommitSubscriber] = []
  /// Canonical names retained across the public prepare/apply/commit seam.
  private var preparedCanonicalNamesById: [String: String] = [:]

  // MARK: - Delivery (durable queue + bounded in-memory window)

  private struct DeliveryConfig {
    var flushAt: Int = 20
    var flushIntervalSeconds: TimeInterval = 30
    var maxQueueSize: Int = 1000
    var maxBatchSize: Int = 50
    var maxRetries: Int = 3
    var baseRetryDelay: TimeInterval = 5
  }

  private struct PreparedDeliveryResult: Sendable {
    let response: EventResponse
    let shouldHandleResponseSignals: Bool
  }

  private enum OwnershipFenceCommitResult {
    case durable
    case retryable
    case unavailable
  }

  /// Fence persistence is retried locally before exposing the durable source
  /// to ordinary recovery. This is deliberately short: the pending source is
  /// the durable retry record once these attempts are exhausted.
  private static let ownershipFenceRetryAttempts = 3
  private static let ownershipFenceRetryBaseDelayNanoseconds: UInt64 = 50_000_000

  private var deliveryConfig = DeliveryConfig()
  private var deliveryQueue: [NuxieEvent] = []
  private var isCurrentlyFlushing = false
  private var flushWaiters: [CheckedContinuation<Void, Never>] = []
  private var retryCount = 0
  private var nextRetryDate: Date?
  private var isPaused = false
  private var flushTimerTask: Task<Void, Never>?
  private var activeDirectDeliveryIds: Set<String> = []
  /// A persisted direct source remains reserved while an ownership fence is
  /// temporarily unavailable. These tasks are cancelled and joined by close
  /// before the shared store is closed.
  private var ownershipFenceRetryTasks: [String: Task<Void, Never>] = [:]
  /// Direct sources whose transport attempt failed terminally but whose
  /// history-row acknowledgement has not yet succeeded. They remain reserved
  /// from delivery-window refill so an ack failure cannot turn a synchronous
  /// enrollment failure into a delayed journey decision in this process.
  private var terminalDirectDeliveryIds: Set<String> = []
  private var isTriggerDeliveryHeld = false
  private var triggerDeliveryWaiters: [CheckedContinuation<Void, Never>] = []
  private var isDurableCommitLaneHeld = false
  private var durableCommitLaneWaiters: [CheckedContinuation<Void, Never>] = []
  private var activeDurableCommitCount = 0
  private var durableCommitDrainWaiters: [CheckedContinuation<Void, Never>] = []
  private var preparedDeliveryTasks: [UUID: Task<EventResponse, Never>] = [:]
  private var preparedDeliveryBoundaryTasks:
    [UUID: Task<PreparedDeliveryResult, Never>] = [:]
  private var preparedDeliveryBoundaryTail:
    (id: UUID, task: Task<PreparedDeliveryResult, Never>)?
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
    ownershipFenceRetryTasks.values.forEach { $0.cancel() }
    terminalRetirementRetryTasks.values.forEach { $0.cancel() }
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
      let internalConfiguration = configuration.internalConfiguration
      deliveryConfig = DeliveryConfig(
        flushAt: internalConfiguration.flushAt,
        flushIntervalSeconds: internalConfiguration.flushInterval,
        maxQueueSize: internalConfiguration.maxQueueSize,
        maxBatchSize: internalConfiguration.eventBatchSize,
        maxRetries: internalConfiguration.retryCount,
        baseRetryDelay: internalConfiguration.retryDelay
      )
    }

    do {
      try await store.initialize(
        path: snapshot?.internalConfiguration.customStoragePath
      )
      _ = try await store.readOrInitializeHistoryCoverage(
        startingAt: dateProvider.now()
      )
    } catch let error as EventStorageError {
      if case .invalidSchema = error {
        throw error
      }
      // Transient storage failures retain the existing best-effort behavior.
      LogWarning("EventLog storage initialization failed: \(error)")
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

  nonisolated func configure(configuration: NuxieSetupConfiguration?) async throws {
    try await configure(snapshot: configuration)
  }

  /// Convenience for direct EventLog tests. Production setup passes the
  /// immutable NuxieSetupConfiguration through EventLogProtocol.
  nonisolated func configure(configuration: NuxieConfiguration?) async throws {
    try await configure(snapshot: configuration.map(NuxieSetupConfiguration.init))
  }

  public func subscribeCommitted(
    where filter: (@Sendable (NuxieEvent) -> Bool)?,
    handler: @escaping CommittedEventHandler
  ) {
    subscribers.append(Subscriber(filter: filter, handler: handler))
  }

  public func subscribeCommitted(
    when isEnabled: @escaping @Sendable () -> Bool,
    handler: @escaping DurableCommitHandler
  ) async {
    durableCommitSubscribers.append(DurableCommitSubscriber(
      isEnabled: isEnabled,
      handler: handler
    ))
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
    try await trackWithResponse(
      event,
      properties: properties,
      flushStrategy: flushStrategy,
      distinctIdOverride: nil
    )
  }

  func trackWithResponse(
    _ event: String,
    properties: sending [String: Any]? = nil,
    flushStrategy: EventFlushStrategy,
    distinctIdOverride: String?
  ) async throws -> EventResponse {
    guard !event.isEmpty else {
      throw NuxieError.invalidConfiguration("Event name cannot be empty")
    }

    // Wait for initialization
    await ready.wait()
    guard !closeFlag.isClosed else { throw CancellationError() }
    await drainCaptureWorker()
    guard !closeFlag.isClosed else { throw CancellationError() }

    switch flushStrategy {
    case .none:
      break
    case .eventLog:
      // Flush pending capture commands first to ensure ordering.
      _ = await flushEvents()
    case .networkQueue:
      let drained = await deliveryFlushAll()
      guard drained else {
        throw EventRoutingError.eventRoutingFailed
      }
    }

    // Get current distinct ID
    let distinctId = distinctIdOverride ?? identityService.getDistinctId()

    // Boxed so the same snapshot can cross into the API client while
    // remaining readable here (each load is a fresh disconnected region).
    var scopedProperties = await buildTriggerProperties(
      properties
    )
    scopedProperties["sdk_version"] = SDKVersion.current
    scopedProperties["platform"] = currentPlatform()
    if scopedProperties["device_model"] == nil {
      scopedProperties["device_model"] = deviceModelIdentifier()
    }
    if scopedProperties["os_version"] == nil {
      scopedProperties["os_version"] = osVersionString()
    }
    scopedProperties["$distinct_id"] = distinctId
    let finalProperties = UncheckedSendable(scopedProperties)

    let historyTimestamp = dateProvider.now()
    // The direct request and every recovery attempt share one stable identity.
    // Reserve it before the store await so refill cannot put the same row on
    // the delivery lane while this request owns its first send.
    let localEvent = NuxieEvent(
      name: event,
      distinctId: distinctId,
      properties: finalProperties.value,
      timestamp: historyTimestamp
    )
    activeDirectDeliveryIds.insert(localEvent.id)
    var wasPersisted = false
    do {
      // Deliberately outside the durable-commit lane: an authoritative
      // ownership response must be able to fence a stable capture that is
      // suspended in its own store commit, so this insert cannot queue
      // behind it. Forwarding order across concurrent lanes therefore
      // follows commit completion, which is the order the store made each
      // capture durable.
      try await store.insertPending(makeStoredEvent(from: localEvent))
      wasPersisted = true
      announceDurable(
        canonicalName: event,
        event: localEvent,
        applyBeforeSendForwardGate: true
      )
      try await performCleanupIfNeeded()
    } catch {
      LogWarning("Failed to store event locally: \(error)")
      await recordHistoryGap(at: historyTimestamp)
      // Continue - server tracking is more important for journey events
    }

    let response: EventResponse
    do {
      response = try await apiClient.trackEvent(localEvent)
    } catch {
      // Preserve the synchronous trackWithResponse contract: a transport
      // failure is terminal for this attempt and must not create a delayed
      // journey decision after its caller has handled the failure locally.
      if wasPersisted {
        await completeTerminalDirectDelivery(ids: [localEvent.id])
      } else {
        activeDirectDeliveryIds.remove(localEvent.id)
      }
      throw error
    }

    // If the response cannot be made durable, its pending source remains the
    // retry record and the decision lane replays it directly with the same
    // idempotency key.
    installVolatileJourneyOwnershipLosses(in: response)
    let ownershipFenceCommit = await persistJourneyOwnershipLosses(
      in: response,
      sourceEventId: localEvent.id
    )
    await commitServerFacts(response.facts ?? [], distinctId: distinctId)

    await acquireTriggerDelivery()
    await handleJourneyOwnershipResponseSignals(response)
    switch ownershipFenceCommit {
    case .durable:
      if wasPersisted {
        await completeDirectDelivery(ids: [localEvent.id])
      } else {
        activeDirectDeliveryIds.remove(localEvent.id)
      }
    case .retryable:
      activeDirectDeliveryIds.remove(localEvent.id)
      if wasPersisted {
        await enqueueForDelivery(localEvent, isPersisted: true)
      }
    case .unavailable:
      if wasPersisted {
        scheduleOwnershipFenceRetry(response: response, source: localEvent)
      } else {
        activeDirectDeliveryIds.remove(localEvent.id)
      }
    }
    releaseTriggerDelivery()

    await handleMailboxResponseSignal(response)
    guard case .durable = ownershipFenceCommit else {
      throw EventRoutingError.eventRoutingFailed
    }
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
    persistToHistory: Bool = true,
    distinctIdOverride: String? = nil,
    applyBeforeSend: Bool = false
  ) async throws -> (NuxieEvent, EventResponse) {
    guard !event.isEmpty else {
      throw NuxieError.invalidConfiguration("Event name cannot be empty")
    }

    await acquireTriggerDelivery()
    var ownsTriggerDelivery = true
    var ownsDurableCommit = false
    defer {
      if ownsTriggerDelivery {
        releaseTriggerDelivery()
      }
      if ownsDurableCommit {
        endDurableCommit()
      }
    }

    await ready.wait()
    guard !closeFlag.isClosed else { throw CancellationError() }
    await waitForPreparedTriggerDeliveries()

    // An ordinary user trigger must not overtake accepted events or identity
    // changes captured before this call. When a predecessor exists, keep that
    // durable trigger on the same batch lane and route locally instead of
    // issuing the old /batch + /event pair. Internal control events and
    // non-persistent scoped events still require the direct-response path.
    await drainCaptureWorker()
    guard !closeFlag.isClosed else { throw CancellationError() }
    if persistToHistory {
      guard await beginDurableCommit() else { throw CancellationError() }
      ownsDurableCommit = true
    }
    var hasPredecessors = true
    do {
      hasPredecessors = try await store.getPendingDeliveryCount()
        + nonDurableDeliveryIds.count
        > 0
    } catch {
      LogWarning("Failed to establish the trigger predecessor boundary: \(error)")
    }

    let distinctId = distinctIdOverride ?? identityService.getDistinctId()

    // Boxed so the same snapshot can cross into the API client while
    // remaining readable here (each load is a fresh disconnected region).
    var scopedProperties = await buildTriggerProperties(
      properties
    )
    scopedProperties["$distinct_id"] = distinctId
    let finalProperties = UncheckedSendable(scopedProperties)

    // The canonical local event exists before anything else observes it. Its
    // UUIDv7 id is the durable-delivery idempotency key if the row later
    // rides the batch queue.
    let originalEvent = NuxieEvent(
      name: event,
      distinctId: distinctId,
      properties: finalProperties.value
    )
    let localEvent: NuxieEvent
    if applyBeforeSend, let beforeSend = configuration?.beforeSend {
      guard let transformed = beforeSend(originalEvent) else {
        LogDebug("Event '\(event)' terminally dropped by beforeSend hook")
        throw EventBeforeSendDropError()
      }
      // The log owns identity. Hosts may redact properties or rename the
      // event, but the scoped identity, the durable idempotency key, and the
      // capture timestamp must survive the transform so the trigger response
      // and local journey evaluation stay attributed to the scoped user.
      var transformedProperties = transformed.properties
      transformedProperties["$distinct_id"] = distinctId
      localEvent = NuxieEvent(
        id: originalEvent.id,
        name: transformed.name,
        distinctId: distinctId,
        properties: transformedProperties,
        timestamp: originalEvent.timestamp
      )
    } else {
      localEvent = originalEvent
    }

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
        announceDurable(
          canonicalName: event,
          event: localEvent,
          applyBeforeSendForwardGate: !applyBeforeSend
        )
        try await performCleanupIfNeeded()
      } catch {
        LogWarning("Failed to store event locally: \(error)")
        await recordHistoryGap(at: localEvent.timestamp)
      }
      ownsDurableCommit = false
      endDurableCommit()
    }

    if hasPredecessors, persistToHistory, !localEvent.name.hasPrefix("$") {
      activeDirectDeliveryIds.remove(localEvent.id)
      await enqueueForDelivery(localEvent, isPersisted: wasPersisted)
      let stagedForRetry = wasPersisted
        || deliveryQueue.contains { $0.id == localEvent.id }
        || nonDurableDeliveryIds.contains(localEvent.id)
      guard stagedForRetry else {
        throw EventRoutingError.eventRoutingFailed
      }
      return (
        localEvent,
        EventResponse(status: "offline", eventId: localEvent.id)
      )
    }

    do {
      let response = try await apiClient.trackEvent(localEvent)
      installVolatileJourneyOwnershipLosses(in: response)
      let ownershipFenceCommit = await persistJourneyOwnershipLosses(
        in: response,
        sourceEventId: localEvent.id
      )
      await commitServerFacts(response.facts ?? [], distinctId: distinctId)
      await handleJourneyOwnershipResponseSignals(response)

      if persistToHistory {
        switch ownershipFenceCommit {
        case .durable:
          // Never acknowledge an ownership-changing response before its fence
          // is durable. Otherwise a relaunch could recover a stale host exit
          // after the source decision row was already retired.
          await completeDirectDelivery(ids: [localEvent.id])
        case .retryable:
          activeDirectDeliveryIds.remove(localEvent.id)
          await enqueueForDelivery(localEvent, isPersisted: wasPersisted)
        case .unavailable:
          if wasPersisted {
            scheduleOwnershipFenceRetry(response: response, source: localEvent)
          } else {
            activeDirectDeliveryIds.remove(localEvent.id)
          }
        }
      }

      // Mailbox refresh may synchronously track a claim, so release only after
      // authoritative ownership callbacks have finished.
      ownsTriggerDelivery = false
      releaseTriggerDelivery()
      await handleMailboxResponseSignal(response)

      let enrichedEvent = NuxieEvent(
        id: response.eventId ?? localEvent.id,
        name: localEvent.name,
        distinctId: localEvent.distinctId,
        properties: localEvent.properties,
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

  /// Durably capture an SDK-authored system event under a stable identity.
  /// Replays acknowledge the existing row and return the same event identity
  /// so local routing can resume after a process death without duplicating the
  /// network event.
  func captureSystemEvent(
    _ event: String,
    properties: sending [String: Any]?,
    eventId: String,
    distinctId: String
  ) async -> DurableTriggerCapture? {
    switch await captureStableSystemEvent(
      event,
      properties: properties,
      eventId: eventId,
      distinctId: distinctId,
      ownership: nil
    ) {
    case .captured(let capture):
      return capture
    case .ownershipLost, .failed:
      return nil
    }
  }

  func captureOwnedJourneySystemEvent(
    _ event: String,
    properties: sending [String: Any]?,
    eventId: String,
    distinctId: String,
    ownership: JourneyEventOwnership
  ) async -> DurableOwnedTriggerCaptureResult {
    await captureStableSystemEvent(
      event,
      properties: properties,
      eventId: eventId,
      distinctId: distinctId,
      ownership: ownership
    )
  }

  func journeyEventOwnershipState(
    _ ownership: JourneyEventOwnership
  ) async -> JourneyEventOwnershipState {
    guard !closeFlag.isClosed else { return .unavailable }
    await ready.wait()
    guard !closeFlag.isClosed else { return .unavailable }
    guard !hasVolatileJourneyOwnershipLoss(ownership) else {
      return .ownershipLost
    }
    do {
      let persistentlyLost = try await store.hasJourneyOwnershipLoss(ownership)
      if persistentlyLost || hasVolatileJourneyOwnershipLoss(ownership) {
        return .ownershipLost
      }
      let unresolved = try await store.hasUnresolvedJourneyOwnershipResponse(
        ownership
      )
      if hasVolatileJourneyOwnershipLoss(ownership) {
        return .ownershipLost
      }
      if unresolved {
        return .unavailable
      }
      return .owned
    } catch {
      LogError(
        "EventLog: failed to verify ownership for journey \(ownership.journeyId); refusing restoration"
      )
      return .unavailable
    }
  }

  private func captureStableSystemEvent(
    _ event: String,
    properties: sending [String: Any]?,
    eventId: String,
    distinctId: String,
    ownership: JourneyEventOwnership?
  ) async -> DurableOwnedTriggerCaptureResult {
    guard !event.isEmpty else { return .failed }
    guard !closeFlag.isClosed else { return .failed }
    await acquireTriggerDelivery()
    defer { releaseTriggerDelivery() }

    await ready.wait()
    guard !closeFlag.isClosed else { return .failed }
    // A stable system capture is an immediate API, but it still follows all
    // earlier fire-and-forget captures. It must also hold the shared commit
    // lane while storage suspends so a later capture cannot announce first.
    await drainCaptureWorker()
    guard await beginDurableCommit() else { return .failed }
    defer { endDurableCommit() }
    let attemptedTimestamp = dateProvider.now()
    do {
      if let ownership {
        switch await journeyEventOwnershipState(ownership) {
        case .owned:
          break
        case .ownershipLost:
          return .ownershipLost
        case .unavailable:
          return .failed
        }
      }
      // Stable identity is policy-terminal. Replays return the canonical
      // captured/drop outcome before enrichment or invoking a changed hook,
      // but only while this epoch is still owned.
      if let existing = try await store.queryStableCapture(id: eventId) {
        guard let capture = durableCapture(
          from: existing,
          fallbackEvent: event,
          eventId: eventId,
          distinctId: distinctId
        ) else { return .ownershipLost }
        return .captured(capture)
      }
      if let ownership {
        if hasVolatileJourneyOwnershipLoss(ownership) {
          return .ownershipLost
        }
        // An unresolved response is not proof of ownership loss, so preserve
        // the recovery record and fail closed instead of terminally dropping
        // it. A storage error is equally non-authoritative.
        let hasUnresolvedResponse =
          try await store.hasUnresolvedJourneyOwnershipResponse(ownership)
        guard !hasUnresolvedResponse else { return .failed }
        if hasVolatileJourneyOwnershipLoss(ownership) {
          return .ownershipLost
        }
      }

      var scopedProperties = await buildTriggerProperties(
        properties
      )
      scopedProperties["$distinct_id"] = distinctId
      let finalProperties = UncheckedSendable(scopedProperties)
      let originalEvent = NuxieEvent(
        id: eventId,
        name: event,
        distinctId: distinctId,
        properties: finalProperties.value,
        timestamp: attemptedTimestamp
      )
      let transformedEvent: NuxieEvent?
      if let beforeSend = configuration?.beforeSend {
        transformedEvent = beforeSend(originalEvent).map { transformed in
          // Recovery owns identity. Hosts may redact properties or rename the
          // event without changing its scoped replay key or attribution.
          var transformedProperties = transformed.properties
          transformedProperties["$distinct_id"] = distinctId
          return NuxieEvent(
            id: eventId,
            name: transformed.name,
            distinctId: distinctId,
            properties: transformedProperties,
            timestamp: originalEvent.timestamp
          )
        }
      } else {
        transformedEvent = originalEvent
      }
      guard !closeFlag.isClosed else { return .failed }
      if let ownership,
         hasVolatileJourneyOwnershipLoss(ownership) {
        return .ownershipLost
      }
      let outcome = try await store.commitStableCapture(
        eventId: eventId,
        event: transformedEvent.map(makeStoredEvent(from:)),
        recordedAt: attemptedTimestamp,
        ownership: ownership
      )
      if case .ownershipLost = outcome { return .ownershipLost }
      if transformedEvent == nil {
        LogDebug("Event '\(event)' terminally dropped by beforeSend hook")
      }
      guard let capture = durableCapture(
        from: outcome,
        fallbackEvent: event,
        eventId: eventId,
        distinctId: distinctId
      ) else { return .ownershipLost }
      if case .captured(_, isNew: true) = outcome {
        await enqueueForDelivery(capture.event, isPersisted: true)
        announceDurable(canonicalName: event, event: capture.event)
      }
      do {
        try await performCleanupIfNeeded()
      } catch {
        // The stable outcome is already durable. Retention maintenance must
        // not turn a committed capture/drop back into a retryable failure.
        LogWarning("EventLog: stable capture retention cleanup failed")
      }
      return .captured(capture)
    } catch {
      LogError("EventLog: failed to durably capture system event")
      await recordHistoryGap(at: attemptedTimestamp)
      return .failed
    }
  }


  func captureAcceptedSystemEvent(
    _ event: String,
    properties: sending [String: Any]?,
    eventId: String,
    distinctId: String
  ) async -> Bool {
    guard !event.isEmpty, !closeFlag.isClosed else { return false }
    await ready.wait()
    guard !closeFlag.isClosed else { return false }
    await drainCaptureWorker()
    guard await beginDurableCommit() else { return false }
    defer { endDurableCommit() }

    let enriched = await buildTriggerProperties(properties)
    let original = NuxieEvent(
      id: eventId,
      name: event,
      distinctId: distinctId,
      properties: enriched
    )
    let prepared: NuxieEvent
    if let beforeSend = configuration?.beforeSend {
      guard let transformed = beforeSend(original) else {
        LogDebug("Event '\(event)' dropped by beforeSend hook")
        return true
      }
      prepared = NuxieEvent(
        id: eventId,
        name: transformed.name,
        distinctId: distinctId,
        properties: transformed.properties,
        timestamp: original.timestamp
      )
    } else {
      prepared = original
    }

    do {
      let inserted = try await store.insertHistoryIfAbsent(makeStoredEvent(from: prepared))
      if inserted {
        announceDurable(canonicalName: event, event: prepared)
        try await performCleanupIfNeeded()
      }
      return true
    } catch {
      LogWarning("Failed to commit accepted system event '\(event)': \(error)")
      return false
    }
  }

  private func durableCapture(
    from outcome: StableEventCaptureOutcome,
    fallbackEvent: String,
    eventId: String,
    distinctId: String
  ) -> DurableTriggerCapture? {
    switch outcome {
    case .captured(let storedEvent, _):
      return DurableTriggerCapture(event: NuxieEvent(
        id: storedEvent.id,
        name: storedEvent.name,
        distinctId: storedEvent.distinctId,
        properties: storedEvent.getPropertiesDict(),
        timestamp: storedEvent.timestamp
      ))
    case .dropped:
      return DurableTriggerCapture(
        event: NuxieEvent(
          id: eventId,
          name: fallbackEvent,
          distinctId: distinctId
        ),
        routesLocally: false
      )
    case .ownershipLost:
      return nil
    }
  }

  /// Persist an already-enriched trigger event under its existing id, then
  /// start its direct server round trip independently of the caller's local
  /// journey dispatch. This is the authored-runtime path: the exact persisted
  /// id is also the conversion source fact and delivery idempotency key.
  public func commitPreparedTriggerEvent(
    _ event: NuxieEvent
  ) async -> PreparedTriggerCommit {
    await acquireTriggerDelivery()
    defer { releaseTriggerDelivery() }

    await ready.wait()
    guard !closeFlag.isClosed else { return offlinePreparedCommit(for: event) }

    // Preserve capture order without coupling local authored-event routing to
    // network latency. Reaching this barrier means every earlier fire-and-
    // forget capture is durably committed and available to journey queries.
    await drainCaptureWorker()
    guard !closeFlag.isClosed else { return offlinePreparedCommit(for: event) }

    // Teardown waits for this whole durable-commit phase. The shared lane also
    // prevents a later direct or stable capture from overtaking this insert.
    guard await beginDurableCommit() else { return offlinePreparedCommit(for: event) }
    defer { endDurableCommit() }

    extractUserProperties(from: event)
    activeDirectDeliveryIds.insert(event.id)
    var wasPersisted = false
    var wasInserted = false
    do {
      wasInserted = try await store.insertPendingIfAbsent(makeStoredEvent(from: event))
      wasPersisted = true
      try await performCleanupIfNeeded()
    } catch {
      LogWarning("Failed to store prepared trigger event locally: \(error)")
      await recordHistoryGap(at: event.timestamp)
    }
    guard !closeFlag.isClosed else {
      activeDirectDeliveryIds.remove(event.id)
      return offlinePreparedCommit(for: event)
    }
    let canonicalName = preparedCanonicalNamesById.removeValue(forKey: event.id)
      ?? event.name
    // Bounded safety valve: dual registration can leave an alias behind when
    // a transform does not preserve ids; cap the map so it can never grow
    // unbounded under storage failure or alias buildup.
    if preparedCanonicalNamesById.count > 256 {
      preparedCanonicalNamesById.removeAll()
    }
    if wasInserted {
      announceDurable(canonicalName: canonicalName, event: event)
    }

    let taskID = UUID()
    let sequence = nextPreparedDeliverySequence
    nextPreparedDeliverySequence += 1
    let previousDelivery = preparedDeliveryBoundaryTail?.task
    let delivery = Task { [weak self] in
      _ = await previousDelivery?.value
      guard let self else {
        return PreparedDeliveryResult(
          response: EventResponse(status: "offline", eventId: event.id),
          shouldHandleResponseSignals: false
        )
      }
      let result: PreparedDeliveryResult
      if Task.isCancelled {
        result = PreparedDeliveryResult(
          response: EventResponse(status: "offline", eventId: event.id),
          shouldHandleResponseSignals: false
        )
      } else {
        result = await self.deliverPreparedTriggerEvent(
          event,
          wasPersisted: wasPersisted
        )
      }
      await self.preparedDeliveryBoundaryDidFinish(taskID)
      return result
    }
    let response = Task { [weak self] in
      let result = await delivery.value
      if result.shouldHandleResponseSignals {
        // The delivery boundary has already been retired. Mailbox refresh may
        // reenter trackForTrigger, so it must run after waiters on that older
        // prepared delivery are free to advance.
        await self?.handleMailboxResponseSignal(result.response)
      }
      await self?.preparedDeliveryDidFinish(taskID)
      return result.response
    }
    preparedDeliveryBoundaryTasks[taskID] = delivery
    preparedDeliveryBoundaryTail = (taskID, delivery)
    preparedDeliveryTasks[taskID] = response
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

  private func durableCommitDidFinish() {
    activeDurableCommitCount -= 1
    guard activeDurableCommitCount == 0 else { return }
    let waiters = durableCommitDrainWaiters
    durableCommitDrainWaiters.removeAll()
    waiters.forEach { $0.resume() }
  }

  /// Serializes every store mutation that can become a forwarded activity.
  /// Actor reentrancy alone is insufficient because distinct capture paths
  /// suspend in storage and could otherwise announce out of capture order.
  private func beginDurableCommit(allowDuringClose: Bool = false) async -> Bool {
    guard allowDuringClose || !closeFlag.isClosed else { return false }
    activeDurableCommitCount += 1
    if isDurableCommitLaneHeld {
      await withCheckedContinuation { durableCommitLaneWaiters.append($0) }
    } else {
      isDurableCommitLaneHeld = true
    }
    return true
  }

  private func endDurableCommit() {
    if durableCommitLaneWaiters.isEmpty {
      isDurableCommitLaneHeld = false
    } else {
      durableCommitLaneWaiters.removeFirst().resume()
    }
    durableCommitDidFinish()
  }

  private func waitForDurableCommitsToFinish() async {
    guard activeDurableCommitCount > 0 else { return }
    await withCheckedContinuation { durableCommitDrainWaiters.append($0) }
  }

  private func preparedDeliveryBoundaryDidFinish(_ taskID: UUID) {
    _ = preparedDeliveryBoundaryTasks.removeValue(forKey: taskID)
    if preparedDeliveryBoundaryTail?.id == taskID {
      preparedDeliveryBoundaryTail = nil
    }
  }

  private func preparedDeliveryDidFinish(_ taskID: UUID) {
    _ = preparedDeliveryTasks.removeValue(forKey: taskID)
  }

  private func waitForPreparedTriggerDeliveries() async {
    guard let pending = preparedDeliveryBoundaryTail?.task else { return }
    _ = await pending.value
  }

  private func deliverPreparedTriggerEvent(
    _ event: NuxieEvent,
    wasPersisted: Bool
  ) async -> PreparedDeliveryResult {
    let olderEventsDrained = await deliveryFlushAll()
    guard olderEventsDrained else {
      activeDirectDeliveryIds.remove(event.id)
      await enqueueForDelivery(event, isPersisted: wasPersisted)
      LogWarning(
        "Deferred prepared trigger '\(event.name)' because older pending delivery did not drain"
      )
      return PreparedDeliveryResult(
        response: EventResponse(status: "offline", eventId: event.id),
        shouldHandleResponseSignals: false
      )
    }
    guard !Task.isCancelled else {
      activeDirectDeliveryIds.remove(event.id)
      return PreparedDeliveryResult(
        response: EventResponse(status: "offline", eventId: event.id),
        shouldHandleResponseSignals: false
      )
    }
    do {
      let response = try await apiClient.trackEvent(event)
      installVolatileJourneyOwnershipLosses(in: response)
      let ownershipFenceCommit = await persistJourneyOwnershipLosses(
        in: response,
        sourceEventId: event.id
      )
      await commitServerFacts(response.facts ?? [], distinctId: event.distinctId)

      // Keep the authoritative callback on the prepared-delivery boundary,
      // before acknowledgement and before waiters on that boundary resume.
      // The volatile + durable fences already make any concurrently queued
      // owned capture ineligible; acquiring the trigger lane here would form
      // a cycle with trackForTrigger, which holds that lane while awaiting
      // older prepared deliveries.
      await handleJourneyOwnershipResponseSignals(response)
      switch ownershipFenceCommit {
      case .durable:
        await completeDirectDelivery(ids: [event.id])
      case .retryable:
        activeDirectDeliveryIds.remove(event.id)
        await enqueueForDelivery(event, isPersisted: wasPersisted)
      case .unavailable:
        if wasPersisted {
          scheduleOwnershipFenceRetry(response: response, source: event)
        } else {
          activeDirectDeliveryIds.remove(event.id)
        }
      }
      return PreparedDeliveryResult(
        response: response,
        shouldHandleResponseSignals: true
      )
    } catch {
      activeDirectDeliveryIds.remove(event.id)
      guard !Task.isCancelled else {
        return PreparedDeliveryResult(
          response: EventResponse(status: "offline", eventId: event.id),
          shouldHandleResponseSignals: false
        )
      }
      await enqueueForDelivery(event, isPersisted: wasPersisted)
      LogWarning(
        "Prepared trigger round trip failed for '\(event.name)'; continuing local-first: \(error)"
      )
      return PreparedDeliveryResult(
        response: EventResponse(status: "offline", eventId: event.id),
        shouldHandleResponseSignals: false
      )
    }
  }

  /// Retries a response-scoped ownership fence without replaying the source
  /// over the network. The source stays reserved until the fence is durable
  /// or the bounded local retry budget hands it back to durable delivery.
  private func scheduleOwnershipFenceRetry(
    response: EventResponse,
    source: NuxieEvent
  ) {
    guard !closeFlag.isClosed,
          ownershipFenceRetryTasks[source.id] == nil
    else { return }

    let sourceId = source.id
    ownershipFenceRetryTasks[sourceId] = Task { [weak self] in
      for attempt in 0..<Self.ownershipFenceRetryAttempts {
        let delay = Self.ownershipFenceRetryBaseDelayNanoseconds << UInt64(attempt)
        do {
          try await Task.sleep(nanoseconds: delay)
        } catch {
          break
        }
        guard !Task.isCancelled, let self else { break }
        if await self.retryOwnershipFencePersistence(response: response, source: source) {
          await self.ownershipFenceRetryDidFinish(sourceId)
          return
        }
      }

      guard !Task.isCancelled, let self else { return }
      await self.exhaustOwnershipFenceRetry(source)
      await self.ownershipFenceRetryDidFinish(sourceId)
    }
  }

  /// Returns whether the source reached a terminal retry transition.
  private func retryOwnershipFencePersistence(
    response: EventResponse,
    source: NuxieEvent
  ) async -> Bool {
    guard !closeFlag.isClosed, !Task.isCancelled else { return true }

    switch await persistJourneyOwnershipLosses(in: response, sourceEventId: source.id) {
    case .durable:
      guard !closeFlag.isClosed, !Task.isCancelled else { return true }
      await completeDirectDelivery(ids: [source.id])
      return true
    case .retryable:
      guard !closeFlag.isClosed, !Task.isCancelled else { return true }
      activeDirectDeliveryIds.remove(source.id)
      await enqueueForDelivery(source, isPersisted: true)
      return true
    case .unavailable:
      return false
    }
  }

  private func exhaustOwnershipFenceRetry(_ source: NuxieEvent) async {
    guard !closeFlag.isClosed, !Task.isCancelled else { return }
    activeDirectDeliveryIds.remove(source.id)
    await enqueueForDelivery(source, isPersisted: true)
    LogWarning(
      "Ownership fence remained unavailable for direct source \(source.id); returning it to durable delivery"
    )
  }

  private func ownershipFenceRetryDidFinish(_ sourceId: String) {
    _ = ownershipFenceRetryTasks.removeValue(forKey: sourceId)
  }

  public func prepareTriggerProperties(
    _ properties: sending [String: Any]?
  ) async -> sending [String: Any] {
    await ready.wait()
    return await buildTriggerProperties(properties)
  }

  public func applyBeforeSend(to event: NuxieEvent) async -> NuxieEvent? {
    guard let beforeSend = configuration?.beforeSend else { return event }
    guard let transformed = beforeSend(event) else { return nil }
    // Every caller pins the original event id across the transform (the log
    // owns identity); registering under both ids keeps the classification
    // correct even for a hypothetical caller that stores the transformed id,
    // and the hoisted removal in storePreparedEventInHistory consumes
    // whichever key the stored event carries.
    preparedCanonicalNamesById[event.id] = event.name
    if transformed.id != event.id {
      preparedCanonicalNamesById[transformed.id] = event.name
    }
    return transformed
  }

  public func storePreparedEventInHistory(_ event: NuxieEvent) async {
    await ready.wait()
    guard !closeFlag.isClosed else { return }
    await drainCaptureWorker()
    guard await beginDurableCommit() else { return }
    defer { endDurableCommit() }

    // Consume the canonical-name registration before the insert attempt so a
    // storage failure can never strand entries in the map.
    let canonicalName = preparedCanonicalNamesById.removeValue(forKey: event.id)
      ?? event.name
    // Same bounded safety valve as the trigger commit lane: a transform that
    // did not preserve ids can leave one alias behind per capture.
    if preparedCanonicalNamesById.count > 256 {
      preparedCanonicalNamesById.removeAll()
    }
    do {
      let inserted = try await store.insertHistoryIfAbsent(makeStoredEvent(from: event))
      if inserted {
        announceDurable(canonicalName: canonicalName, event: event)
      }
      try await performCleanupIfNeeded()
    } catch {
      LogWarning("Failed to store prepared event locally: \(error)")
      await recordHistoryGap(at: event.timestamp)
    }
  }

  public func commitServerFacts(_ facts: [JourneyDownFact], distinctId: String) async {
    guard !facts.isEmpty else { return }
    await ready.wait()
    guard !closeFlag.isClosed else { return }
    await drainCaptureWorker()
    guard await beginDurableCommit() else { return }
    defer { endDurableCommit() }

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

    for fact in facts {
      let receivedAt = dateProvider.now()
      var properties: [String: Any]
      let occurredAt: Date
      var forwardingDeduplicationKey: String?
      switch fact.properties {
      case .converted(let converted):
        forwardingDeduplicationKey = conversionDeduplicationKey(converted: converted)
        occurredAt = converted.at
        properties = [
          "journey_id": converted.journeyId,
          "at": formatter.string(from: converted.at),
          "source_fact_ref": converted.sourceFactRef,
        ]
        properties.merge(
          await committedJourneyExperienceProperties(
            journeyId: converted.journeyId,
            distinctId: distinctId
          )
        ) { current, _ in current }
      case .effectCompleted(let completed):
        occurredAt = fact.timestamp
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
        occurredAt = fact.timestamp
        properties = [
          "journey_id": superseded.journeyId,
        ]
        if let winnerJourneyId = superseded.winnerJourneyId {
          properties["winner_journey_id"] = winnerJourneyId
        }
      }
      properties["$server_fact_id"] = fact.id
      properties[StoredEvent.originProperty] = StoredEventOrigin.server.rawValue
      let sourceEvent = NuxieEvent(
        id: fact.id,
        name: fact.event.rawValue,
        distinctId: distinctId,
        properties: properties,
        timestamp: fact.timestamp
      )
      let event = sourceEvent

      do {
        let stored = makeStoredEvent(from: event)
        let inserted = if let forwardingDeduplicationKey {
          try await store.insertHistoryIfAbsent(
            stored,
            forwardingDeduplicationKey: forwardingDeduplicationKey
          )
        } else {
          try await store.insertHistoryIfAbsent(stored)
        }
        if inserted {
          announceDurable(
            canonicalName: fact.event.rawValue,
            event: event,
            occurredAt: occurredAt,
            receivedAt: receivedAt,
            applyBeforeSendForwardGate: true
          )
          routeContinuation.yield(.event(event))
          try await performCleanupIfNeeded()
        }
      } catch {
        LogWarning("Failed to commit server fact \(fact.id): \(error)")
        await recordHistoryGap(at: event.timestamp)
      }
    }
  }

  private func conversionDeduplicationKey(
    converted: JourneyConvertedProperties
  ) -> String {
    let goalKey: String
    if let value = converted.goal?.value,
       JSONSerialization.isValidJSONObject(["goal": value]),
       let data = try? JSONSerialization.data(
        withJSONObject: ["goal": value],
        options: [.sortedKeys, .withoutEscapingSlashes]
       ) {
      goalKey = String(decoding: data, as: UTF8.self)
    } else {
      // Older down-facts omit the immutable goal snapshot. Such journeys
      // have one goal, so this sentinel is the portable identity for it.
      goalKey = "<unspecified>"
    }
    let components = [converted.journeyId, goalKey].map {
      Data($0.utf8).base64EncodedString()
    }
    return (["journey-conversion"] + components).joined(separator: ".")
  }

  private func committedJourneyExperienceProperties(
    journeyId: String,
    distinctId: String
  ) async -> [String: Any] {
    do {
      let events = try await store.queryEventsForUser(distinctId, limit: .max)
      for event in events.reversed() {
        let properties = event.getPropertiesDict()
        guard properties["journey_id"] as? String == journeyId,
              let experienceId = properties["experience_id"] as? String else {
          continue
        }
        var result: [String: Any] = ["experience_id": experienceId]
        if let version = properties["experience_version"] as? String {
          result["experience_version"] = version
        }
        return result
      }
    } catch {
      LogWarning("Failed to resolve journey experience context: \(error)")
    }
    return [:]
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

  private func journeyOwnershipLosses(
    in response: EventResponse
  ) -> [JourneyEventOwnership] {
    var highestEpochByJourneyId: [String: Int] = [:]
    if let ownership = response.journeyClaim,
       !ownership.accepted {
      highestEpochByJourneyId[ownership.journeyId] = ownership.epoch
    }
    if let ownership = response.journeyOwnership {
      highestEpochByJourneyId[ownership.journeyId] = max(
        highestEpochByJourneyId[ownership.journeyId] ?? Int.min,
        ownership.epoch
      )
    }
    return highestEpochByJourneyId.map {
      JourneyEventOwnership(journeyId: $0.key, epoch: $0.value)
    }
  }

  /// Install the process-local half of the fence synchronously at the
  /// transport response boundary. No actor reentrancy is possible between
  /// observing the server response and making stale capture ineligible.
  private func installVolatileJourneyOwnershipLosses(
    in response: EventResponse
  ) {
    installVolatileJourneyOwnershipLosses(
      journeyOwnershipLosses(in: response)
    )
  }

  private func installVolatileJourneyOwnershipLosses(
    _ ownerships: [JourneyEventOwnership]
  ) {
    for ownership in ownerships {
      journeyOwnershipFences[ownership.journeyId] = max(
        journeyOwnershipFences[ownership.journeyId] ?? Int.min,
        ownership.epoch
      )
    }
  }

  /// Make the response fence durable before its source is acknowledged.
  /// Capture checks the already-installed process-local copy too, so a
  /// transient SQLite failure cannot reopen the same-process race.
  @discardableResult
  private func persistJourneyOwnershipLosses(
    in response: EventResponse,
    sourceEventId: String
  ) async -> OwnershipFenceCommitResult {
    let responseLosses = journeyOwnershipLosses(in: response)
    let processUnresolvedLosses =
      unresolvedJourneyOwnershipBySource[sourceEventId] ?? []

    let durableUnresolvedLosses: [JourneyEventOwnership]
    do {
      durableUnresolvedLosses =
        try await store.queryUnresolvedJourneyOwnershipResponse(
          sourceEventId: sourceEventId
        )
    } catch {
      var highestEpochByJourneyId: [String: Int] = [:]
      for ownership in responseLosses + processUnresolvedLosses {
        highestEpochByJourneyId[ownership.journeyId] = max(
          highestEpochByJourneyId[ownership.journeyId] ?? Int.min,
          ownership.epoch
        )
      }
      let unresolvedLosses = highestEpochByJourneyId.map {
        JourneyEventOwnership(journeyId: $0.key, epoch: $0.value)
      }
      if !unresolvedLosses.isEmpty {
        unresolvedJourneyOwnershipBySource[sourceEventId] = unresolvedLosses
        installVolatileJourneyOwnershipLosses(unresolvedLosses)
      }
      LogError(
        "EventLog: failed to query unresolved ownership response \(sourceEventId)"
      )
      return .unavailable
    }

    var highestEpochByJourneyId: [String: Int] = [:]
    for ownership in responseLosses
      + durableUnresolvedLosses
      + processUnresolvedLosses
    {
      highestEpochByJourneyId[ownership.journeyId] = max(
        highestEpochByJourneyId[ownership.journeyId] ?? Int.min,
        ownership.epoch
      )
    }
    let losses = highestEpochByJourneyId.map {
      JourneyEventOwnership(journeyId: $0.key, epoch: $0.value)
    }
    guard !losses.isEmpty else { return .durable }
    unresolvedJourneyOwnershipBySource[sourceEventId] = losses
    installVolatileJourneyOwnershipLosses(losses)
    let recordedAt = dateProvider.now()

    // Crash-safe ordering: every loss is durably recorded as an unresolved
    // marker BEFORE any fence is written. A crash at any point leaves either
    // the full marker set or the fences (both idempotent upserts), so no loss
    // can exist with neither a fence nor a marker; recovery replays markers
    // into fences at startup, and the pending source remains the retry record
    // of last resort.
    for ownership in losses {
      do {
        try await store.recordUnresolvedJourneyOwnershipResponse(
          sourceEventId: sourceEventId,
          ownership: ownership,
          recordedAt: recordedAt
        )
      } catch {
        LogError(
          "EventLog: failed to persist unresolved ownership response for journey \(ownership.journeyId)"
        )
        return .unavailable
      }
    }

    var fencesFullyPersisted = true
    for ownership in losses {
      do {
        try await store.recordJourneyOwnershipLoss(
          ownership,
          recordedAt: recordedAt
        )
      } catch {
        fencesFullyPersisted = false
        LogError(
          "EventLog: failed to persist ownership fence for journey \(ownership.journeyId)"
        )
      }
    }
    guard fencesFullyPersisted else {
      // Markers are durable, so the losses are recoverable; the bounded
      // in-process retry (or startup recovery) re-runs this idempotently.
      return .retryable
    }

    do {
      try await store.clearUnresolvedJourneyOwnershipResponse(
        sourceEventId: sourceEventId
      )
    } catch {
      // The durable fence is authoritative; a stale unresolved marker is
      // conservative and can be cleaned by another idempotent replay.
      LogWarning(
        "EventLog: ownership fence persisted but unresolved source marker could not be cleared"
      )
    }
    unresolvedJourneyOwnershipBySource.removeValue(forKey: sourceEventId)
    return .durable
  }

  /// A decision source may be retired without another response only when it
  /// is not carrying an ownership signal whose fence remains unresolved.
  /// Query failures fail closed and leave the source pending.
  private func canRetireJourneyDecisionWithoutDelivery(
    sourceEventId: String
  ) async -> Bool {
    guard unresolvedJourneyOwnershipBySource[sourceEventId] == nil else {
      return false
    }
    do {
      return try await store.queryUnresolvedJourneyOwnershipResponse(
        sourceEventId: sourceEventId
      ).isEmpty
    } catch {
      LogError(
        "EventLog: failed to verify ownership response before retiring \(sourceEventId)"
      )
      return false
    }
  }

  private func hasVolatileJourneyOwnershipLoss(
    _ ownership: JourneyEventOwnership
  ) -> Bool {
    (journeyOwnershipFences[ownership.journeyId] ?? Int.min)
      >= ownership.epoch
  }

  private func handleJourneyOwnershipResponseSignals(
    _ response: EventResponse
  ) async {
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

  private func handleMailboxResponseSignal(_ response: EventResponse) async {
    if response.mailboxPending == true, let mailboxPendingHandler {
      await mailboxPendingHandler()
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

    // A stable system capture or prepared event may already own an in-flight
    // store operation. Settle every durable phase before collecting delivery
    // tasks and closing their shared store.
    await waitForDurableCommitsToFinish()

    // A prepared authored event owns an independent direct request. Cancel
    // and settle every such request while its durable store is still open;
    // no response callback or fallback queue mutation may outlive teardown.
    let preparedDeliveryBoundaries = Array(preparedDeliveryBoundaryTasks.values)
    let preparedDeliveries = Array(preparedDeliveryTasks.values)
    preparedDeliveryBoundaries.forEach { $0.cancel() }
    preparedDeliveries.forEach { $0.cancel() }
    for delivery in preparedDeliveries {
      _ = await delivery.value
    }
    preparedDeliveryBoundaryTasks.removeAll()
    preparedDeliveryTasks.removeAll()
    preparedDeliveryBoundaryTail = nil

    // Ownership-fence retries are the only direct-delivery work that remains
    // after the response boundary. Cancel and settle them while the store is
    // open so they cannot write after shutdown.
    let ownershipFenceRetries = Array(ownershipFenceRetryTasks.values)
    ownershipFenceRetries.forEach { $0.cancel() }
    for retry in ownershipFenceRetries {
      _ = await retry.value
    }
    ownershipFenceRetryTasks.removeAll()

    // Stop accepting new captures, then let the capture worker finish every
    // accepted command while routing is still available. A drained capture
    // may persist and announce an event, so the route worker must outlive it.
    captureContinuation.yield(.shutdown)
    captureContinuation.finish()

    flushTimerTask?.cancel()
    flushTimerTask = nil

    // Deterministic teardown: finish capture first so its final durable
    // announcements remain ordered ahead of route shutdown.
    await captureWorker?.value

    routeContinuation.yield(.shutdown)
    routeContinuation.finish()
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
      guard let capture = await buildEvent(from: payload) else { return }
      await commit(capture.event, canonicalName: capture.canonicalName)

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

    case .durable(let capture, let handlers):
      for handler in handlers {
        await handler(capture)
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
  private func commit(_ event: NuxieEvent, canonicalName: String) async {
    // The nonisolated capture entry point rejects new work after close begins.
    // Commands already accepted into the capture stream must still cross the
    // durable lane while close drains that stream.
    guard await beginDurableCommit(allowDuringClose: true) else { return }
    defer { endDurableCommit() }
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
      await recordHistoryGap(at: event.timestamp)
      // Continue routing to other services even if storage fails
    }

    // Network ordering: enqueue before subscriber routing so lifecycle calls
    // can flush this hit.
    await enqueueForDelivery(event, isPersisted: wasPersisted)

    if wasPersisted {
      announceDurable(canonicalName: canonicalName, event: event)
    }

    routeContinuation.yield(.event(event))
  }

  public func announceTransientActivity(canonicalName: String, event: NuxieEvent) async {
    announceDurable(
      canonicalName: canonicalName,
      event: event,
      applyBeforeSendForwardGate: true
    )
  }

  private func announceDurable(
    canonicalName: String,
    event: NuxieEvent,
    occurredAt: Date? = nil,
    receivedAt: Date? = nil,
    applyBeforeSendForwardGate: Bool = false
  ) {
    // Direct journey facts bypass capture-side beforeSend so their wire
    // command, durable capture, and journey routing remain authoritative.
    // Consult the hook here only as a forwarding gate: nil suppresses this
    // announcement without changing any of those paths.
    if applyBeforeSendForwardGate,
       let beforeSend = configuration?.beforeSend,
       beforeSend(event) == nil {
      return
    }
    let handlers = durableCommitSubscribers.compactMap { subscriber in
      subscriber.isEnabled() ? subscriber.handler : nil
    }
    guard !handlers.isEmpty else { return }
    routeContinuation.yield(.durable(CommittedCapture(
      canonicalName: canonicalName,
      event: event,
      occurredAt: occurredAt ?? event.timestamp,
      receivedAt: receivedAt ?? event.timestamp
    ), handlers: handlers))
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

  private func buildEvent(
    from p: TrackPayload
  ) async -> (canonicalName: String, event: NuxieEvent)? {
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

    var finalProperties = await enrich(propertiesWithSession)
    finalProperties["$distinct_id"] = p.forcedDistinctId

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
      var transformedProperties = transformedEvent.properties
      transformedProperties["$distinct_id"] = p.forcedDistinctId
      return (
        p.name,
        NuxieEvent(
          id: transformedEvent.id,
          name: transformedEvent.name,
          distinctId: p.forcedDistinctId,
          properties: transformedProperties,
          timestamp: transformedEvent.timestamp
        )
      )
    }

    return (p.name, nuxieEvent)
  }

  private func buildTriggerProperties(
    _ properties: sending [String: Any]?
  ) async -> sending [String: Any] {
    var finalProperties = properties ?? [:]

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

  /// Build a direct-delivery history row with legacy device metadata while
  /// preserving the exact event identity and timestamp used on the wire.
  private func makeHistoryStoredEvent(from event: NuxieEvent) throws -> StoredEvent {
    var enrichedProperties = event.properties
    enrichedProperties["sdk_version"] = SDKVersion.current
    enrichedProperties["platform"] = currentPlatform()
    if enrichedProperties["device_model"] == nil {
      enrichedProperties["device_model"] = deviceModelIdentifier()
    }
    if enrichedProperties["os_version"] == nil {
      enrichedProperties["os_version"] = osVersionString()
    }

    return try StoredEvent(
      id: event.id,
      name: event.name,
      properties: enrichedProperties,
      timestamp: event.timestamp,
      distinctId: event.distinctId
    )
  }

  /// Cleanup runs at most once per `cleanupCheckInterval` inserts — a
  /// per-insert COUNT(*) would be a wasted query on every event.
  private func performCleanupIfNeeded(force: Bool = false) async throws {
    if !force {
      insertsSinceCleanupCheck += 1
      guard insertsSinceCleanupCheck >= cleanupCheckInterval else { return }
    }
    insertsSinceCleanupCheck = 0

    // Enforce the cap by COUNT (an age-only delete lets active users grow
    // unboundedly within the retention window), then apply the age policy on
    // top. Neither reaps rows still awaiting delivery.
    let eventCount = try await store.getEventCount()
    let cutoffDate =
      Calendar.current.date(
        byAdding: .day,
        value: -cleanupThresholdDays,
        to: dateProvider.now()
      ) ?? dateProvider.now()
    let prune = try await store.pruneHistory(
      keeping: maxEventsStored,
      olderThan: cutoffDate
    )
    let stableOutcomeCutoff = dateProvider.now().addingTimeInterval(
      -Self.stableDropRetention
    )
    let droppedDeletes = try await store.deleteStableDropsOlderThan(
      stableOutcomeCutoff
    )
    LogInfo(
      "Retention cleanup: removed \(prune.countDeleted) over-cap + \(prune.ageDeleted) aged events + \(droppedDeletes) stable drops (had \(eventCount)); coverage starts \(prune.coverageStartingAt)"
    )
  }

  /// Fence exact history one persisted timestamp tick after a fact that was
  /// known to the SDK but could not be committed. The in-memory fence moves
  /// first; a simultaneous event+metadata disk failure therefore remains safe
  /// for this process even though persistence cannot be guaranteed on relaunch.
  private func recordHistoryGap(at timestamp: Date) async {
    let boundary = Self.firstStoredTimestamp(after: timestamp)
    volatileHistoryCoverageStart = max(
      volatileHistoryCoverageStart ?? boundary,
      boundary
    )
    do {
      let durable = try await store.advanceHistoryCoverage(to: boundary)
      volatileHistoryCoverageStart = max(
        volatileHistoryCoverageStart ?? durable,
        durable
      )
    } catch {
      LogError("Failed to persist event-history coverage fence: \(error)")
    }
  }

  private static func firstStoredTimestamp(after timestamp: Date) -> Date {
    let milliseconds = floor(timestamp.timeIntervalSince1970 * 1_000) + 1
    return Date(timeIntervalSince1970: milliseconds / 1_000)
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
      do {
        // A very old pending row becomes retention-eligible only after its
        // ack. Re-check immediately so a later cleanup cannot delete it while
        // leaving the durable completeness horizon behind.
        try await performCleanupIfNeeded(force: true)
      } catch {
        LogWarning("Failed to enforce retention after delivery ack: \(error)")
      }
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

  private func completeTerminalDirectDelivery(ids: [String]) async {
    if await markDelivered(ids: ids) {
      activeDirectDeliveryIds.subtract(ids)
      terminalDirectDeliveryIds.subtract(ids)
      await refillDeliveryWindow()
    } else {
      terminalDirectDeliveryIds.formUnion(ids)
      LogError(
        "EventLog: retaining \(ids.count) terminal direct source reservation after acknowledgement failure"
      )
      // The in-memory reservation dies with the process, after which the
      // still-pending rows would replay a terminally failed send on
      // relaunch. Retry the durable retirement with the same bounded
      // policy as ownership fences so the acknowledgement outlives this
      // call whenever the store recovers.
      scheduleTerminalRetirementRetry(ids: ids)
    }
  }

  private var terminalRetirementRetryTasks: [String: Task<Void, Never>] = [:]

  private func scheduleTerminalRetirementRetry(ids: [String]) {
    let key = ids.sorted().joined(separator: "\u{1f}")
    guard !closeFlag.isClosed,
          terminalRetirementRetryTasks[key] == nil
    else { return }
    terminalRetirementRetryTasks[key] = Task { [weak self] in
      for attempt in 0..<Self.ownershipFenceRetryAttempts {
        let delay = Self.ownershipFenceRetryBaseDelayNanoseconds << UInt64(attempt)
        do {
          try await Task.sleep(nanoseconds: delay)
        } catch {
          break
        }
        guard !Task.isCancelled, let self else { break }
        if await self.retryTerminalRetirement(ids: ids) {
          break
        }
      }
      guard let self else { return }
      await self.terminalRetirementRetryDidFinish(key)
    }
  }

  private func retryTerminalRetirement(ids: [String]) async -> Bool {
    guard !closeFlag.isClosed else { return true }
    guard await markDelivered(ids: ids) else { return false }
    activeDirectDeliveryIds.subtract(ids)
    terminalDirectDeliveryIds.subtract(ids)
    await refillDeliveryWindow()
    return true
  }

  private func terminalRetirementRetryDidFinish(_ key: String) {
    terminalRetirementRetryTasks.removeValue(forKey: key)
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

    if !terminalDirectDeliveryIds.isEmpty {
      let terminalIds = Array(terminalDirectDeliveryIds)
      if await markDelivered(ids: terminalIds) {
        terminalDirectDeliveryIds.subtract(terminalIds)
        activeDirectDeliveryIds.subtract(terminalIds)
      }
    }

    let capacity = max(1, deliveryConfig.maxQueueSize)
    repeat {
      deliveryWindowRefillRequested = false
      guard deliveryQueue.count < capacity else { return }

      let pending = await loadPendingDelivery(
        limit: Self.pendingDeliveryQueryLimit(
          queueCapacity: capacity,
          activeDirectDeliveryCount: activeDirectDeliveryIds.count
        )
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

  /// Direct deliveries are present in durable pending state but excluded from
  /// the delivery window. Ask storage for enough rows to fill around them
  /// without allowing adversarial counts to overflow `Int`.
  static func pendingDeliveryQueryLimit(
    queueCapacity: Int,
    activeDirectDeliveryCount: Int
  ) -> Int {
    let (limit, overflow) = queueCapacity.addingReportingOverflow(
      activeDirectDeliveryCount
    )
    return overflow ? Int.max : limit
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

  /// Internal synchronization diagnostic used by deterministic ordering
  /// regressions. This is not part of EventLogProtocol or the SDK surface.
  func triggerDeliveryIsHeld() -> Bool {
    isTriggerDeliveryHeld
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
      if decision.name == JourneyEvents.journeyClaimed,
         await canRetireJourneyDecisionWithoutDelivery(
           sourceEventId: decision.id
         ) {
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
      installVolatileJourneyOwnershipLosses(in: response)
      let ownershipFenceCommit = await persistJourneyOwnershipLosses(
        in: response,
        sourceEventId: event.id
      )
      await commitServerFacts(response.facts ?? [], distinctId: event.distinctId)

      // The callback must precede acknowledgement, but must not reacquire the
      // trigger lane. A prepared delivery can be flushing this decision while
      // a later trackForTrigger owns that lane and waits for the prepared
      // boundary; reacquiring here would make those two tasks wait forever.
      // The response fence above already prevents concurrent journey-authored
      // capture for the relinquished epoch.
      await handleJourneyOwnershipResponseSignals(response)
      let removed: Bool
      if case .durable = ownershipFenceCommit {
        removed = await retireDelivered(ids: [event.id])
      } else {
        removed = false
      }
      await handleMailboxResponseSignal(response)
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
      if isPermanentBatchFailure(error),
         await canRetireJourneyDecisionWithoutDelivery(
           sourceEventId: event.id
         ) {
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

  private func acquireTriggerDelivery() async {
    guard isTriggerDeliveryHeld else {
      isTriggerDeliveryHeld = true
      return
    }
    await withCheckedContinuation { continuation in
      triggerDeliveryWaiters.append(continuation)
    }
  }

  private func releaseTriggerDelivery() {
    guard !triggerDeliveryWaiters.isEmpty else {
      isTriggerDeliveryHeld = false
      return
    }
    triggerDeliveryWaiters.removeFirst().resume()
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
      let cappedExponent = min(
        retryCount - 1,
        max(deliveryConfig.maxRetries - 1, 0)
      )
      let backoffDelay = deliveryConfig.baseRetryDelay * pow(2, Double(cappedExponent))
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

  /// Internal retry diagnostics used to verify that every failure path obeys
  /// the configured backoff ceiling.
  func retryBackoffState(relativeTo date: Date = Date()) -> (
    attempts: Int,
    remainingDelay: TimeInterval?
  ) {
    (retryCount, nextRetryDate?.timeIntervalSince(date))
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

  public func drainCapturedEvents() async {
    guard !closeFlag.isClosed else { return }
    await drainCaptureWorker()
  }

  private func drainCaptureWorker() async {
    await withCheckedContinuation { cont in
      // A finished stream drops the yielded barrier; resume immediately so a
      // late caller (for example a startup lifecycle trigger racing close)
      // can never suspend forever on a closed log.
      if case .terminated = captureContinuation.yield(.barrier(cont)) {
        cont.resume()
      }
    }
  }

  private func drainRouteWorker() async {
    await withCheckedContinuation { cont in
      if case .terminated = routeContinuation.yield(.barrier(cont)) {
        cont.resume()
      }
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

  func queryEventsForIR(
    _ distinctId: String,
    name: String,
    since: Date?,
    until: Date?,
    ascending: Bool,
    limit: Int
  ) async throws -> [StoredEvent] {
    await ready.wait()
    return try await store.queryEventsForUser(
      distinctId,
      name: name,
      since: since,
      until: until,
      ascending: ascending,
      limit: limit
    )
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

  func historyCoverage() async throws -> EventHistoryCoverage {
    await ready.wait()
    let durable = try await store.historyCoverageStartingAt()
    return .retainedWindow(
      startingAt: max(durable, volatileHistoryCoverageStart ?? durable)
    )
  }

  public func exists(name: String, since: Date?, until: Date?, where predicate: IRPredicate?) async
    throws -> Bool
  {
    return try await count(name: name, since: since, until: until, where: predicate) > 0
  }

  public func count(name: String, since: Date?, until: Date?, where predicate: IRPredicate?) async
    throws -> Int
  {
    let distinctId = identityService.getDistinctId()
    await ready.wait()

    // Predicate-free counts go straight to SQL — counting within the last N
    // events of ALL names undercounts for active users.
    if predicate == nil {
      return try await store.countEvents(
        name: name, distinctId: distinctId, since: since, until: until)
    }

    let events = try await irEvents(
      named: name, distinctId: distinctId, since: since, until: until, ascending: false)
    var matchingCount = 0
    for event in events {
      let props = try event.getPropertiesDictForIR()
      if PredicateEval.eval(predicate!, props: props) { matchingCount += 1 }
    }
    return matchingCount
  }

  /// Name-filtered fetch for IR predicate queries — SQL narrows by
  /// user+name+time (indexed) so other events can't evict the queried
  /// event's history.
  private func irEvents(
    named name: String, distinctId: String, since: Date?, until: Date?, ascending: Bool
  ) async throws -> [StoredEvent] {
    let events = try await store.queryEventsForUser(
      distinctId, name: name, since: since, until: until,
      ascending: ascending, limit: Self.irQueryLimit + 1)
    guard events.count <= Self.irQueryLimit else {
      throw EventHistoryQueryError.truncated(limit: Self.irQueryLimit)
    }
    return events
  }

  public func firstTime(name: String, where predicate: IRPredicate?) async throws -> Date? {
    let distinctId = identityService.getDistinctId()
    await ready.wait()

    // Predicate-free → SQL MIN. Taking the earliest of the most RECENT N
    // events is wrong precisely for long-tenured users.
    if predicate == nil {
      return try await store.getFirstEventTime(
        name: name, distinctId: distinctId, since: nil, until: nil)
    }

    let events = try await irEvents(
      named: name, distinctId: distinctId, since: nil, until: nil, ascending: true)
    for event in events {
      if PredicateEval.eval(
        predicate!,
        props: try event.getPropertiesDictForIR()
      ) {
        return event.timestamp
      }
    }
    return nil
  }

  public func lastTime(name: String, where predicate: IRPredicate?) async throws -> Date? {
    let distinctId = identityService.getDistinctId()
    await ready.wait()

    if predicate == nil {
      return try await store.getLastEventTime(
        name: name, distinctId: distinctId, since: nil, until: nil)
    }

    let events = try await irEvents(
      named: name, distinctId: distinctId, since: nil, until: nil, ascending: false)
    for event in events {
      if PredicateEval.eval(
        predicate!,
        props: try event.getPropertiesDictForIR()
      ) {
        return event.timestamp
      }
    }
    return nil
  }

  public func aggregate(
    _ agg: Aggregate, name: String, prop: String, since: Date?, until: Date?,
    where predicate: IRPredicate?
  ) async throws -> Double? {
    let distinctId = identityService.getDistinctId()
    await ready.wait()
    let events = try await irEvents(
      named: name, distinctId: distinctId, since: since, until: until, ascending: false)

    let values: [Double] =
      try events
      .compactMap { event -> Double? in
        let props = try event.getPropertiesDictForIR()
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
  ) async throws -> Bool {
    let distinctId = identityService.getDistinctId()
    await ready.wait()
    // Per-step name-filtered fetches, merged chronologically — a heavy
    // unrelated event stream can no longer evict the sequence's events.
    var merged: [StoredEvent] = []
    for stepName in Set(steps.map(\.name)) {
      merged += try await irEvents(
        named: stepName, distinctId: distinctId, since: since, until: until, ascending: true)
    }
    let events = merged.sorted {
      if $0.timestamp == $1.timestamp { return $0.id < $1.id }
      return $0.timestamp < $1.timestamp
    }
    return try IREventSequenceMatcher.matches(
      events: events,
      steps: steps,
      overallWithin: overallWithin,
      perStepWithin: perStepWithin
    )
  }

  public func activePeriods(
    name: String, period: Period, total: Int, min: Int, where predicate: IRPredicate?
  ) async throws -> Bool {
    let distinctId = identityService.getDistinctId()
    await ready.wait()
    guard total > 0 && min > 0 && min <= total else { return false }

    // Calendar-bucket by UTC
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = dateProvider.now()

    guard let windowStart = period.activePeriodsWindowStart(
      total: total,
      now: now
    ) else { return false }

    // Name+window-filtered at the SQL layer
    let events = try await irEvents(
      named: name, distinctId: distinctId, since: windowStart, until: nil, ascending: false)

    // Count unique periods with activity within the time window
    var bucketsInWindow = Set<DateComponents>()

    for event in events {
      let props = try event.getPropertiesDictForIR()
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
    throws -> Bool
  {
    guard let last = try await lastTime(name: name, where: predicate) else { return false }
    return Date().timeIntervalSince(last) >= inactiveFor
  }

  public func restarted(
    name: String, inactiveFor: TimeInterval, within: TimeInterval, where predicate: IRPredicate?
  ) async throws -> Bool {
    let distinctId = identityService.getDistinctId()
    let now = Date()
    await ready.wait()
    let events = try await irEvents(
      named: name, distinctId: distinctId, since: nil, until: nil, ascending: true)

    // Find any gap
    var prev: Date? = nil
    var hadGap = false

    for event in events {
      if let p = predicate {
        let props = try event.getPropertiesDictForIR()
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


extension JourneyEventAccess {
  func announceTransientActivity(canonicalName: String, event: NuxieEvent) async {}
}
