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
  let routeToSubscribers: Bool
  /// Subscriber-specific authority captured synchronously at `track`.
  let subscriberAdmissions: [UInt64: UInt64]
}

private enum CaptureCommand: Sendable {
  case track(TrackPayload)
  case flush(CheckedContinuation<Bool, Never>)
  case barrier(CheckedContinuation<Void, Never>)  // test-only: "drain until here"
  case shutdown
}

private enum RouteResolution: Sendable {
  case event(RoutedCommittedEvent)
  case skipped
}

private enum RouteCommand: Sendable {
  case resolved(sequence: UInt64, RouteResolution)
  /// Storage failures have no durable commit sequence to order against.
  case undurable(RoutedCommittedEvent)
  case barrier(CheckedContinuation<Void, Never>)
  case shutdown
}

private enum ForwardingResolution: Sendable {
  case event(DurableForwardingEvent)
  case skipped
}

private enum ForwardingCommand: Sendable {
  case resolved(sequence: UInt64, ForwardingResolution)
  case barrier(CheckedContinuation<Void, Never>)
  case shutdown
}

private struct ForwardingAdmission: Sendable {
  let receivedAt: Date
}

struct DurableForwardingEvent: Sendable {
  let event: NuxieEvent
  let receivedAt: Date
}

enum EventFlushStrategy: Equatable, Sendable {
  case none
  case eventLog
  case networkQueue
}

/// A committed-event subscriber callback. Invoked in commit order, after the
/// event is persisted (pending delivery) and staged for the network.
typealias CommittedEventHandler = @Sendable (NuxieEvent) async -> Void
typealias CommittedEventAdmissionProvider = @Sendable () -> UInt64?
typealias AdmittedCommittedEventHandler =
  @Sendable (NuxieEvent, UInt64?) async -> Void
typealias ForwardingEventHandler = @Sendable (DurableForwardingEvent) async -> Void

/// Reserves a committed subscriber's stable identifier before asynchronous
/// actor registration. This lets synchronous capture preserve the subscriber's
/// authority even when the event is tracked immediately after SDK setup.
struct CommittedEventAdmissionReservation: Hashable, Sendable {
  let subscriberIdentifier: UInt64
}

private struct RoutedCommittedEvent: Sendable {
  let event: NuxieEvent
  let subscriberAdmissions: [UInt64: UInt64]
}

/// Admission providers must be callable from EventLog's synchronous,
/// nonisolated track entry point. Subscriber handlers remain actor-owned; this
/// registry stores only their stable identifiers and thread-safe providers.
private final class CommittedEventAdmissionRegistry: @unchecked Sendable {
  private let lock = NSLock()
  private var nextIdentifier: UInt64 = 0
  private var providers: [UInt64: CommittedEventAdmissionProvider] = [:]

  func register(
    provider: CommittedEventAdmissionProvider?
  ) -> UInt64 {
    lock.withLock {
      let identifier = nextIdentifier
      nextIdentifier &+= 1
      if let provider {
        providers[identifier] = provider
      }
      return identifier
    }
  }

  func capture() -> [UInt64: UInt64] {
    let snapshot = lock.withLock { providers }
    var admissions: [UInt64: UInt64] = [:]
    admissions.reserveCapacity(snapshot.count)
    for (identifier, provider) in snapshot {
      if let admission = provider() {
        admissions[identifier] = admission
      }
    }
    return admissions
  }
}

private struct ForwardingSubscriber: Sendable {
  let isEnabled: @Sendable () -> Bool
  let handler: ForwardingEventHandler
}

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
  /// Routing policy and whether this call established the canonical event row.
  let routesLocally: Bool
  let isNewlyCommitted: Bool
  init(event: NuxieEvent, routesLocally: Bool = true, isNewlyCommitted: Bool = true) {
    self.event = event
    self.routesLocally = routesLocally
    self.isNewlyCommitted = isNewlyCommitted
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

  /// Capture and deliver an internal mirrored event without feeding it back
  /// through the ordinary journey-routing subscriber.
  func trackWithoutRouting(
    _ event: String,
    properties: [String: Any]?,
    distinctIdOverride: String
  )
  func track(
    _ event: String,
    properties: [String: Any]?,
    userProperties: [String: Any]?,
    userPropertiesSetOnce: [String: Any]?,
    distinctIdOverride: String
  )
}

protocol StableSystemEventCapturing: AnyObject, Sendable {
  func captureSystemEvent(
    _ event: String,
    properties: sending [String: Any]?,
    eventId: String,
    distinctId: String
  ) async -> DurableTriggerCapture?
}

protocol EventTriggerTracking: StableSystemEventCapturing {
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
  func prepareTriggerProperties(
    _ properties: sending [String: Any]?
  ) async -> sending [String: Any]
  func applyBeforeSend(to event: NuxieEvent) async -> NuxieEvent?
  @discardableResult
  func storePreparedEventInHistory(_ event: NuxieEvent) async -> Bool
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
  func drain() async
}

protocol JourneyEventAccess:
  JourneyRunnerEventAccess,
  EventHistoryReading
{
  /// Cancel in-flight prepared response deliveries so shutdown can join
  /// response wrappers that await their values.
  func cancelPreparedResponseDeliveries(for distinctId: String?) async

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
  JourneyRunnerEventAccess, RoutedStableSystemEventCapturing
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

  /// Capture subscriber-specific execution authority at the synchronous event
  /// boundary, then deliver it alongside the committed event. A missing value
  /// means the subscriber was not authorized when capture began.
  func reserveCommittedAdmission(
    admission: @escaping CommittedEventAdmissionProvider
  ) -> CommittedEventAdmissionReservation

  /// Attach the actor-owned handler for a synchronously reserved admission.
  /// Callers must install the handler before configuring the event log.
  func subscribeCommitted(
    where filter: (@Sendable (NuxieEvent) -> Bool)?,
    reservation: CommittedEventAdmissionReservation,
    handler: @escaping AdmittedCommittedEventHandler
  ) async

  func subscribeCommitted(
    where filter: (@Sendable (NuxieEvent) -> Bool)?,
    admission: @escaping CommittedEventAdmissionProvider,
    handler: @escaping AdmittedCommittedEventHandler
  ) async

  /// Subscribe only to rows made newly durable by this process. This stream
  /// does not replay retained history and is independent from journey routing.
  func subscribeForwarding(
    when isEnabled: @escaping @Sendable () -> Bool,
    handler: @escaping ForwardingEventHandler
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
  @discardableResult
  func storePreparedEventInHistory(_ event: NuxieEvent) async -> Bool

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

  /// Cancel in-flight prepared response deliveries without closing the log,
  /// so shutdown can join response wrappers that await their values.
  func cancelPreparedResponseDeliveries(for distinctId: String?) async

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

  // MARK: - Event Query Methods

  func hasEvent(name: String, distinctId: String, since: Date?) async -> Bool
  func countEvents(name: String, distinctId: String, since: Date?, until: Date?) async -> Int
  func getLastEventTime(name: String, distinctId: String, since: Date?, until: Date?) async -> Date?

}

extension EventLogProtocol {
  func subscribeCommitted(handler: @escaping CommittedEventHandler) async {
    await subscribeCommitted(where: nil, handler: handler)
  }

  func subscribeCommitted(
    reservation: CommittedEventAdmissionReservation,
    handler: @escaping AdmittedCommittedEventHandler
  ) async {
    await subscribeCommitted(
      where: nil,
      reservation: reservation,
      handler: handler
    )
  }

  func subscribeCommitted(
    admission: @escaping CommittedEventAdmissionProvider,
    handler: @escaping AdmittedCommittedEventHandler
  ) async {
    await subscribeCommitted(
      where: nil,
      admission: admission,
      handler: handler
    )
  }

  func subscribeForwarding(handler: @escaping ForwardingEventHandler) async {
    await subscribeForwarding(when: { true }, handler: handler)
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
  private nonisolated let committedAdmissionRegistry =
    CommittedEventAdmissionRegistry()
  private var routeWorker: Task<Void, Never>?
  private var nextRouteSequenceToDeliver: UInt64 = 0
  private var pendingRouteResolutions: [UInt64: RouteResolution] = [:]
  private nonisolated let forwardingContinuation:
    AsyncStream<ForwardingCommand>.Continuation
  private var forwardingWorker: Task<Void, Never>?
  private var nextForwardingSequenceToDeliver: UInt64 = 0
  private var pendingForwardingResolutions: [UInt64: ForwardingResolution] = [:]

  // MARK: - Dependencies

  /// Constructor-injected collaborators (Phase 4c composition root). The
  /// composition root builds identity/date/api before the log, so
  /// there is no lazy resolution and no hidden ordering.
  private nonisolated let identityService: IdentityServiceProtocol
  private nonisolated let dateProvider: DateProviderProtocol
  private let apiClient: EventTransport

  private var contextBuilder: NuxieContextBuilder?
  private var configuration: NuxieSetupConfiguration?

  // MARK: - Committed-event subscribers

  private struct Subscriber {
    let identifier: UInt64
    let filter: (@Sendable (NuxieEvent) -> Bool)?
    let handler: AdmittedCommittedEventHandler
  }
  private var subscribers: [Subscriber] = []
  private var forwardingSubscribers: [ForwardingSubscriber] = []

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
  private var deliveryState = DeliveryState()
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
  private var activeDurableCommitCount = 0
  private var durableCommitDrainWaiters: [CheckedContinuation<Void, Never>] = []
  private var preparedDeliveryTasks: [UUID: Task<EventResponse, Never>] = [:]
  private var preparedDeliveryEvents: [UUID: NuxieEvent] = [:]
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
    dateProvider: DateProviderProtocol,
    apiClient: EventTransport,
    store: EventStoreProtocol? = nil,
    maxEventsStored: Int = 10_000,
    cleanupThresholdDays: Int = 30,
    cleanupCheckInterval: Int = 100
  ) {
    self.identityService = identity
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

    var forwardingCont: AsyncStream<ForwardingCommand>.Continuation!
    let forwardingStream = AsyncStream<ForwardingCommand> { forwardingCont = $0 }
    self.forwardingContinuation = forwardingCont

    Task {
      await self.startWorkers(
        captureStream: captureStream,
        routeStream: routeStream,
        forwardingStream: forwardingStream
      )
    }
  }

  deinit {
    captureContinuation.finish()
    routeContinuation.finish()
    forwardingContinuation.finish()
    captureWorker?.cancel()
    routeWorker?.cancel()
    forwardingWorker?.cancel()
    flushTimerTask?.cancel()
    ownershipFenceRetryTasks.values.forEach { $0.cancel() }
    terminalRetirementRetryTasks.values.forEach { $0.cancel() }
  }

  private func startWorkers(
    captureStream: AsyncStream<CaptureCommand>,
    routeStream: AsyncStream<RouteCommand>,
    forwardingStream: AsyncStream<ForwardingCommand>
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
    forwardingWorker = Task { [weak self] in
      for await command in forwardingStream {
        guard let self else { return }
        await self.processForwarding(command)
        if case .shutdown = command { return }
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

    // Tests opt out explicitly; attaching XCTest never changes this default.
    if snapshot?.internalConfiguration.suppressBackgroundWork != true {
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
    let identifier = committedAdmissionRegistry.register(provider: nil)
    subscribers.append(Subscriber(
      identifier: identifier,
      filter: filter,
      handler: { event, _ in await handler(event) }
    ))
  }

  nonisolated func reserveCommittedAdmission(
    admission: @escaping CommittedEventAdmissionProvider
  ) -> CommittedEventAdmissionReservation {
    CommittedEventAdmissionReservation(
      subscriberIdentifier: committedAdmissionRegistry.register(
        provider: admission
      )
    )
  }

  public func subscribeCommitted(
    where filter: (@Sendable (NuxieEvent) -> Bool)?,
    reservation: CommittedEventAdmissionReservation,
    handler: @escaping AdmittedCommittedEventHandler
  ) {
    subscribers.append(Subscriber(
      identifier: reservation.subscriberIdentifier,
      filter: filter,
      handler: handler
    ))
  }

  public func subscribeCommitted(
    where filter: (@Sendable (NuxieEvent) -> Bool)?,
    admission: @escaping CommittedEventAdmissionProvider,
    handler: @escaping AdmittedCommittedEventHandler
  ) {
    subscribeCommitted(
      where: filter,
      reservation: reserveCommittedAdmission(admission: admission),
      handler: handler
    )
  }

  public func subscribeForwarding(
    when isEnabled: @escaping @Sendable () -> Bool,
    handler: @escaping ForwardingEventHandler
  ) {
    forwardingSubscribers.append(ForwardingSubscriber(
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
      forcedDistinctId: distinctIdOverride,
      routeToSubscribers: true,
      subscriberAdmissions: committedAdmissionRegistry.capture()
    )

    captureContinuation.yield(.track(payload))
  }

  public nonisolated func trackWithoutRouting(
    _ event: String,
    properties: [String: Any]?,
    distinctIdOverride: String
  ) {
    guard !closeFlag.isClosed, !event.isEmpty else { return }
    captureContinuation.yield(.track(TrackPayload(
      name: event,
      properties: properties ?? [:],
      forcedDistinctId: distinctIdOverride,
      routeToSubscribers: false,
      subscriberAdmissions: [:]
    )))
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
    assert(
      event.hasPrefix("$"),
      "trackWithResponse is reserved for platform-authored journey facts"
    )

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
      _ = try await persist(
        localEvent,
        deliveryState: .pending,
        receivedAt: localEvent.timestamp
      )
      wasPersisted = true
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
      switch deliveryDisposition(for: error) {
      case .split, .terminalPoison:
        if wasPersisted {
          await completeTerminalDirectDelivery(ids: [localEvent.id])
        } else {
          activeDirectDeliveryIds.remove(localEvent.id)
        }
      case .unhealthyAuthentication:
        _ = scheduleAuthenticationRetry()
        await retainFailedDirectDelivery(
          localEvent,
          wasPersisted: wasPersisted,
          retainNonDurable: true
        )
      case .retry(let retryAfter):
        _ = scheduleRetry(retryAfter: retryAfter)
        await retainFailedDirectDelivery(
          localEvent,
          wasPersisted: wasPersisted,
          retainNonDurable: true
        )
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

    // A successful direct delivery proves transport and auth are working;
    // restore health exactly like the prepared, decision, and batch paths.
    deliveryState.health = .healthy

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
  /// with no server decision fields so callers route journeys/segments from
  /// the local event and cached config — network failure degrades freshness,
  /// never function.
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
    defer {
      if ownsTriggerDelivery {
        releaseTriggerDelivery()
      }
    }

    await ready.wait()
    await waitForPreparedTriggerDeliveries()

    // An ordinary user trigger must not overtake accepted events or identity
    // changes captured before this call. When a predecessor exists, keep that
    // durable trigger on the same batch lane and route locally instead of
    // issuing the old /batch + /event pair. Internal control events and
    // non-persistent scoped events still require the direct-response path.
    await drainCaptureWorker()
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
        forwardingName: originalEvent.forwardingName,
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
        _ = try await persist(
          localEvent,
          deliveryState: .pending,
          receivedAt: localEvent.timestamp
        )
        wasPersisted = true
        try await performCleanupIfNeeded()
      } catch {
        LogWarning("Failed to store event locally: \(error)")
        await recordHistoryGap(at: localEvent.timestamp)
      }
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
      ownership: nil,
      routeToSubscribers: false
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
      ownership: ownership,
      routeToSubscribers: false
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
    ownership: JourneyEventOwnership?,
    routeToSubscribers: Bool,
    admission: (any StableEventCaptureCommitAdmission)? = nil
  ) async -> DurableOwnedTriggerCaptureResult {
    guard !event.isEmpty else { return .failed }
    guard !closeFlag.isClosed else { return .failed }
    let subscriberAdmissions = routeToSubscribers
      ? committedAdmissionRegistry.capture()
      : [:]
    await acquireTriggerDelivery()
    defer { releaseTriggerDelivery() }

    await ready.wait()
    guard !closeFlag.isClosed else { return .failed }
    activeDurableCommitCount += 1
    defer { durableCommitDidFinish() }
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

      // Declared leg outputs are already JSON, not arbitrary analytics
      // values. Preserve their exact values through generic sanitization;
      // the host's beforeSend privacy hook still runs below.
      let legOutputs = event == JourneyEvents.journeyLegCompleted
        ? try properties?["outputs"].map { try JSONSerialization.data(withJSONObject: $0) }
        : nil
      var scopedProperties = await buildTriggerProperties(properties)
      if let legOutputs {
        scopedProperties["outputs"] = try JSONSerialization.jsonObject(with: legOutputs)
      }
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
            forwardingName: originalEvent.forwardingName,
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
      let forwardingAdmission = forwardingAdmission(receivedAt: attemptedTimestamp)
      let commit = try await store.commitStableCapture(
        eventId: eventId,
        event: transformedEvent.map(makeStoredEvent(from:)),
        recordedAt: attemptedTimestamp,
        ownership: ownership,
        assigningCommitSequence: true,
        admission: admission
      )
      let outcome = commit.outcome
      guard let commitSequence = commit.commitSequence else {
        throw EventStorageError.insertFailed(NSError(
          domain: "Nuxie.EventLog",
          code: 49,
          userInfo: [NSLocalizedDescriptionKey: "Stable event commit omitted its sequence"]
        ))
      }
      if case .ownershipLost = outcome {
        resolveForwarding(commitSequence, admission: forwardingAdmission, event: nil)
        resolveRoute(commitSequence, event: nil)
        return .ownershipLost
      }
      if transformedEvent == nil {
        LogDebug("Event '\(event)' terminally dropped by beforeSend hook")
      }
      let newlyDurableEvent: NuxieEvent?
      if case .captured(let stored, isNew: true) = outcome {
        newlyDurableEvent = NuxieEvent(
            id: stored.id,
            name: stored.name,
            forwardingName: event,
            distinctId: stored.distinctId,
            properties: stored.getPropertiesDict(),
            timestamp: stored.timestamp
        )
      } else {
        newlyDurableEvent = nil
      }
      resolveForwarding(
        commitSequence,
        admission: forwardingAdmission,
        event: newlyDurableEvent
      )
      guard let capture = durableCapture(
        from: outcome,
        fallbackEvent: event,
        eventId: eventId,
        distinctId: distinctId
      ) else { return .ownershipLost }
      if newlyDurableEvent != nil {
        stagePersistedForDelivery(capture.event)
      }
      resolveRoute(
        commitSequence,
        event: routeToSubscribers && newlyDurableEvent != nil
          && capture.routesLocally ? capture.event : nil,
        subscriberAdmissions: subscriberAdmissions
      )
      do {
        try await performCleanupIfNeeded()
      } catch {
        // The stable outcome is already durable. Retention maintenance must
        // not turn a committed capture/drop back into a retryable failure.
        LogWarning("EventLog: stable capture retention cleanup failed")
      }
      return .captured(capture)
    } catch StableEventCaptureCommitAdmissionError.rejected {
      // Revocation is an expected fail-closed outcome. No history mutation
      // was attempted, so coverage remains exactly as authoritative as it was
      // before this capture began.
      return .failed
    } catch {
      LogError("EventLog: failed to durably capture system event")
      await recordHistoryGap(at: attemptedTimestamp)
      return .failed
    }
  }

  private func durableCapture(
    from outcome: StableEventCaptureOutcome,
    fallbackEvent: String,
    eventId: String,
    distinctId: String
  ) -> DurableTriggerCapture? {
    switch outcome {
    case .captured(let storedEvent, let isNew):
      return DurableTriggerCapture(event: NuxieEvent(
        id: storedEvent.id,
        name: storedEvent.name,
        distinctId: storedEvent.distinctId,
        properties: storedEvent.getPropertiesDict(),
        timestamp: storedEvent.timestamp
      ), isNewlyCommitted: isNew)
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

    // Teardown waits for this whole durable-commit phase. Register before the
    // first store await so close cannot snapshot an empty delivery-task set,
    // close storage, and strand a commit that has not created its task yet.
    activeDurableCommitCount += 1
    defer { durableCommitDidFinish() }

    extractUserProperties(from: event)
    activeDirectDeliveryIds.insert(event.id)
    var wasPersisted = false
    do {
      _ = try await persist(
        event,
        deliveryState: .pending,
        receivedAt: event.timestamp
      )
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
        await self.retainCancelledPreparedDelivery(
          event,
          wasPersisted: wasPersisted
        )
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
      if result.shouldHandleResponseSignals, !Task.isCancelled {
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
    preparedDeliveryEvents[taskID] = event
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
    _ = preparedDeliveryEvents.removeValue(forKey: taskID)
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
      await retainCancelledPreparedDelivery(event, wasPersisted: wasPersisted)
      return PreparedDeliveryResult(
        response: EventResponse(status: "offline", eventId: event.id),
        shouldHandleResponseSignals: false
      )
    }
    do {
      let response = try await apiClient.trackEvent(event)
      deliveryState.health = .healthy
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
      guard !Task.isCancelled else {
        await retainCancelledPreparedDelivery(event, wasPersisted: wasPersisted)
        return PreparedDeliveryResult(
          response: EventResponse(status: "offline", eventId: event.id),
          shouldHandleResponseSignals: false
        )
      }
      switch deliveryDisposition(for: error) {
      case .split, .terminalPoison:
        if wasPersisted {
          await completeTerminalDirectDelivery(ids: [event.id])
        } else {
          activeDirectDeliveryIds.remove(event.id)
        }
        LogError("Terminal prepared journey fact dropped: \(error)")
      case .unhealthyAuthentication:
        _ = scheduleAuthenticationRetry()
        await retainFailedDirectDelivery(
          event,
          wasPersisted: wasPersisted,
          retainNonDurable: true
        )
      case .retry(let retryAfter):
        _ = scheduleRetry(retryAfter: retryAfter)
        await retainFailedDirectDelivery(
          event,
          wasPersisted: wasPersisted,
          retainNonDurable: true
        )
      }
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
    return NuxieEvent(
      id: transformed.id,
      name: transformed.name,
      forwardingName: event.forwardingName,
      distinctId: transformed.distinctId,
      properties: transformed.properties,
      timestamp: transformed.timestamp
    )
  }

  @discardableResult
  public func storePreparedEventInHistory(_ event: NuxieEvent) async -> Bool {
    await ready.wait()

    do {
      _ = try await persist(
        event,
        deliveryState: .delivered,
        receivedAt: event.timestamp
      )
      try await performCleanupIfNeeded()
      return true
    } catch {
      LogWarning("Failed to store prepared event locally: \(error)")
      await recordHistoryGap(at: event.timestamp)
      return false
    }
  }

  public func commitServerFacts(_ facts: [JourneyDownFact], distinctId: String) async {
    guard !facts.isEmpty else { return }
    let subscriberAdmissions = committedAdmissionRegistry.capture()
    await ready.wait()

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let receivedAt = dateProvider.now()

    for fact in facts {
      var properties: [String: Any]
      let eventTimestamp: Date
      switch fact.properties {
      case .converted(let converted):
        eventTimestamp = converted.at
        properties = [
          "journey_id": converted.journeyId,
          "experience_id": converted.experienceId,
          "experience_version": converted.experienceVersion,
          "at": formatter.string(from: converted.at),
          "source_fact_ref": converted.sourceFactRef,
        ]
      case .effectCompleted(let completed):
        eventTimestamp = fact.timestamp
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
        eventTimestamp = fact.timestamp
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
        timestamp: eventTimestamp
      )

      do {
        let inserted = try await persist(
          event,
          deliveryState: .delivered,
          receivedAt: receivedAt,
          origin: .server,
          routeToSubscribers: true,
          subscriberAdmissions: subscriberAdmissions
        )
        if inserted {
          try await performCleanupIfNeeded()
        }
      } catch {
        LogWarning("Failed to commit server fact \(fact.id): \(error)")
        await recordHistoryGap(at: event.timestamp)
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

  public func cancelPreparedResponseDeliveries(for distinctId: String?) async {
    let taskIDs = Set(preparedDeliveryEvents.compactMap { taskID, event in
      distinctId == nil || event.distinctId == distinctId ? taskID : nil
    })
    let boundaries = preparedDeliveryBoundaryTasks.compactMap {
      taskIDs.contains($0.key) ? $0.value : nil
    }
    let deliveries = preparedDeliveryTasks.compactMap {
      taskIDs.contains($0.key) ? $0.value : nil
    }
    boundaries.forEach { $0.cancel() }
    deliveries.forEach { $0.cancel() }
  }

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

    // Stop accepting new commands and ask the workers to stop.
    captureContinuation.yield(.shutdown)
    captureContinuation.finish()
    routeContinuation.yield(.shutdown)
    routeContinuation.finish()
    forwardingContinuation.yield(.shutdown)
    forwardingContinuation.finish()

    // Join the periodic worker before closing its dependencies.
    await stopFlushTimer()

    // Deterministic teardown: wait for both workers to finish their queued
    // commands and exit. Without this, a test (or re-setup) can tear down
    // shared collaborators while a worker is still mid-command.
    await captureWorker?.value
    await routeWorker?.value
    await forwardingWorker?.value

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
      await commit(
        finalEvent,
        routeToSubscribers: payload.routeToSubscribers,
        subscriberAdmissions: payload.subscriberAdmissions
      )

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
    case .resolved(let sequence, let resolution):
      pendingRouteResolutions[sequence] = resolution
      while let next = pendingRouteResolutions.removeValue(
        forKey: nextRouteSequenceToDeliver
      ) {
        nextRouteSequenceToDeliver &+= 1
        guard case .event(let routed) = next else { continue }
        await routeToCommittedSubscribers(routed)
      }

    case .undurable(let routed):
      await routeToCommittedSubscribers(routed)

    case .barrier(let cont):
      cont.resume()

    case .shutdown:
      LogDebug("[EventLog.route] shutdown received")
    }
  }

  private func routeToCommittedSubscribers(
    _ routed: RoutedCommittedEvent
  ) async {
    for subscriber in subscribers {
      if let filter = subscriber.filter, !filter(routed.event) { continue }
      await subscriber.handler(
        routed.event,
        routed.subscriberAdmissions[subscriber.identifier]
      )
    }
  }

  private func processForwarding(_ command: ForwardingCommand) async {
    switch command {
    case .resolved(let sequence, let resolution):
      pendingForwardingResolutions[sequence] = resolution
      while let next = pendingForwardingResolutions.removeValue(
        forKey: nextForwardingSequenceToDeliver
      ) {
        nextForwardingSequenceToDeliver &+= 1
        guard case .event(let event) = next else { continue }
        for subscriber in forwardingSubscribers where subscriber.isEnabled() {
          await subscriber.handler(event)
        }
      }
    case .barrier(let continuation):
      continuation.resume()
    case .shutdown:
      LogDebug("[EventLog.forwarding] shutdown received")
    }
  }

  /// The single ordinary persistence choke point. Every successful first
  /// insert is announced to the forwarding-only stream from this method.
  @discardableResult
  private func persist(
    _ event: NuxieEvent,
    deliveryState: EventDeliveryState,
    receivedAt: Date,
    origin: StoredEventOrigin = .device,
    stageForDelivery: Bool = false,
    routeToSubscribers: Bool = false,
    subscriberAdmissions: [UInt64: UInt64] = [:]
  ) async throws -> Bool {
    let admission = forwardingAdmission(receivedAt: receivedAt)
    let commit = try await store.insert(
      makeStoredEvent(from: event),
      deliveryState: deliveryState,
      origin: origin,
      assigningCommitSequence: true
    )
    guard let commitSequence = commit.commitSequence else {
      throw EventStorageError.insertFailed(NSError(
        domain: "Nuxie.EventLog",
        code: 50,
        userInfo: [NSLocalizedDescriptionKey: "Event commit omitted its sequence"]
      ))
    }
    resolveForwarding(
      commitSequence,
      admission: admission,
      event: commit.newlyDurable ? event : nil
    )
    if commit.newlyDurable, stageForDelivery {
      stagePersistedForDelivery(event)
    }
    resolveRoute(
      commitSequence,
      event: commit.newlyDurable && routeToSubscribers ? event : nil,
      subscriberAdmissions: subscriberAdmissions
    )
    return commit.newlyDurable
  }

  private func forwardingAdmission(receivedAt: Date) -> ForwardingAdmission? {
    guard forwardingSubscribers.contains(where: { $0.isEnabled() }) else {
      return nil
    }
    return ForwardingAdmission(receivedAt: receivedAt)
  }

  private func resolveForwarding(
    _ commitSequence: UInt64,
    admission: ForwardingAdmission?,
    event: NuxieEvent?
  ) {
    let resolution = admission.flatMap { admission in
      event.map {
        ForwardingResolution.event(DurableForwardingEvent(
          event: $0,
          receivedAt: admission.receivedAt
        ))
      }
    } ?? .skipped
    forwardingContinuation.yield(.resolved(
      sequence: commitSequence,
      resolution
    ))
  }

  private func resolveRoute(
    _ commitSequence: UInt64,
    event: NuxieEvent?,
    subscriberAdmissions: [UInt64: UInt64] = [:]
  ) {
    routeContinuation.yield(.resolved(
      sequence: commitSequence,
      event.map {
        .event(RoutedCommittedEvent(
          event: $0,
          subscriberAdmissions: subscriberAdmissions
        ))
      } ?? .skipped
    ))
  }

  /// Persist the canonical captured record (stored row == wire payload,
  /// marked pending), stage it for network delivery, then announce it to
  /// committed-event subscribers in order.
  private func commit(
    _ event: NuxieEvent,
    routeToSubscribers: Bool,
    subscriberAdmissions: [UInt64: UInt64]
  ) async {
    extractUserProperties(from: event)
    var wasPersisted = false
    do {
      _ = try await persist(
        event,
        deliveryState: .pending,
        receivedAt: event.timestamp,
        stageForDelivery: true,
        routeToSubscribers: routeToSubscribers,
        subscriberAdmissions: subscriberAdmissions
      )
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

    if routeToSubscribers, !wasPersisted {
      routeContinuation.yield(.undurable(RoutedCommittedEvent(
        event: event,
        subscriberAdmissions: subscriberAdmissions
      )))
    }
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
    var finalProperties = await enrich(p.properties)
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
      return NuxieEvent(
        id: transformedEvent.id,
        name: transformedEvent.name,
        forwardingName: nuxieEvent.forwardingName,
        distinctId: p.forcedDistinctId,
        properties: transformedProperties,
        timestamp: transformedEvent.timestamp
      )
    }

    return nuxieEvent
  }

  private func buildTriggerProperties(
    _ properties: sending [String: Any]?
  ) async -> sending [String: Any] {
    await enrich(properties ?? [:])
  }

  private func enrich(_ custom: sending [String: Any]) async -> sending [String: Any] {
    // Boxed to hand the write-once snapshot across the context builder.
    let sanitized = UncheckedSendable(EventSanitizer.sanitizeDataTypes(custom))
    guard let contextBuilder else {
      return sanitized.value
    }
    return await contextBuilder.buildEnrichedProperties(customProperties: sanitized.value)
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

  private func retainFailedDirectDelivery(
    _ event: NuxieEvent,
    wasPersisted: Bool,
    retainNonDurable: Bool = false
  ) async {
    activeDirectDeliveryIds.remove(event.id)
    guard wasPersisted || retainNonDurable else { return }
    await enqueueForDelivery(event, isPersisted: wasPersisted)
  }

  private func retainCancelledPreparedDelivery(
    _ event: NuxieEvent,
    wasPersisted: Bool
  ) async {
    activeDirectDeliveryIds.remove(event.id)
    guard !closeFlag.isClosed else { return }
    _ = scheduleRetry()
    await enqueueForDelivery(event, isPersisted: wasPersisted)
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
    if deliveryQueue.isEmpty {
      deliveryState.adaptiveBatchSize = nil
    }
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
    if isPersisted {
      stagePersistedForDelivery(event)
      return
    }
    guard !deliveryQueue.contains(where: { $0.id == event.id }) else { return }

    let capacity = max(1, deliveryConfig.maxQueueSize)
    guard deliveryQueue.count < capacity else {
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
      Task { await self.flushIfOverThreshold() }
      return
    }

    deliveryQueue.append(event)
    nonDurableDeliveryIds.insert(event.id)
    LogDebug("Staged event: \(event.name) (delivery window: \(deliveryQueue.count))")

    Task { await self.flushIfOverThreshold() }
  }

  private func stagePersistedForDelivery(_ event: NuxieEvent) {
    guard !deliveryQueue.contains(where: { $0.id == event.id }) else { return }
    if isRefillingDeliveryWindow {
      // The in-flight refill owns the exposed capacity. Ask it to query again
      // rather than letting this newer event overtake older durable rows.
      deliveryWindowRefillRequested = true
      Task { await self.flushIfOverThreshold() }
      return
    }
    let capacity = max(1, deliveryConfig.maxQueueSize)
    guard deliveryQueue.count < capacity else {
      LogDebug(
        "Delivery window full; event \(event.id) remains pending in durable storage"
      )
      Task { await self.flushIfOverThreshold() }
      return
    }
    deliveryQueue.append(event)
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
        if deliveryState.didRepartitionLastFlush {
          continue
        }
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
    deliveryState.didRepartitionLastFlush = false

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
        .prefix(deliveryState.adaptiveBatchSize ?? deliveryConfig.maxBatchSize)
        .prefix { !isJourneyDecisionEvent($0.name) }
    )

    LogInfo("[EventLog] Flushing \(batch.count) events to server")

    // Canonical conversion — semantics pinned by
    // fixtures/events/batch-item-encoding.json
    let batchItems = batch.map(BatchEventItem.init(event:))

    do {
      let response = try await apiClient.sendBatch(events: batchItems)
      LogDebug("Batch response: processed=\(response.processed), failed=\(response.failed)")
      guard validate(response: response, for: batch) else {
        scheduleRetry()
        LogError(
          "Invalid batch acknowledgement metadata; retaining \(batch.count) events pending"
        )
        finishCurrentFlush()
        return true
      }
      deliveryState.health = .healthy
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
      deliveryState.health = .healthy
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
      if [.terminalPoison, .split].contains(deliveryDisposition(for: error)),
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

      let disposition = deliveryDisposition(for: error)
      let backoffDelay: TimeInterval
      if disposition == .unhealthyAuthentication {
        backoffDelay = scheduleAuthenticationRetry()
      } else {
        let retryAfter: TimeInterval? = if case .retry(let retryAfter) = disposition {
          retryAfter
        } else {
          nil
        }
        backoffDelay = scheduleRetry(retryAfter: retryAfter)
      }
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
      let backoffDelay = scheduleRetry()
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
    switch deliveryDisposition(for: error) {
    case .split, .terminalPoison:
      if batch.count > 1 {
        let splitSize = max(1, batch.count / 2)
        deliveryState.adaptiveBatchSize = splitSize
        deliveryState.didRepartitionLastFlush = true
        retryCount = 0
        nextRetryDate = nil
        LogWarning(
          "Batch rejected; splitting \(batch.count) events into batches of \(splitSize) for isolation"
        )
        finishCurrentFlush()
        return
      }

      let batchIds = batch.map { $0.id }
      let removed = await retireDelivered(ids: batchIds)
      if removed {
        retryCount = 0
        nextRetryDate = nil
      }
      LogError("Terminal poison event dropped after isolation: \(error)")
      finishCurrentFlush()
      return

    case .unhealthyAuthentication:
      let retryDelay = scheduleAuthenticationRetry()
      LogError(
        "SDK event delivery is unhealthy: authentication rejected; keeping \(batch.count) events pending for foreground/periodic retry in \(retryDelay)s"
      )
      finishCurrentFlush()
      return

    case .retry(let retryAfter):
      let backoffDelay = scheduleRetry(retryAfter: retryAfter)

      LogWarning(
        "Batch delivery failed (attempt \(retryCount)), keeping \(batch.count) events pending; next retry in \(backoffDelay)s: \(error)"
      )

      finishCurrentFlush()
    }
  }

  private func deliveryDisposition(for error: Error) -> DeliveryDisposition {
    EventDeliveryPolicy.disposition(for: error)
  }

  private func validate(response: BatchResponse, for batch: [NuxieEvent]) -> Bool {
    guard response.total == batch.count,
          response.processed >= 0,
          response.failed >= 0,
          response.processed + response.failed == response.total else {
      return false
    }

    let errors = response.errors ?? []
    guard errors.count == response.failed else { return false }
    let indexes = errors.map(\.index)
    guard Set(indexes).count == indexes.count else { return false }
    return indexes.allSatisfy(batch.indices.contains)
  }

  @discardableResult
  private func scheduleRetry(retryAfter: TimeInterval? = nil) -> TimeInterval {
    retryCount += 1
    let maximumExponent = max(deliveryConfig.maxRetries - 1, 0)
    let cappedExponent = min(retryCount - 1, maximumExponent)
    let ordinaryDelay = deliveryConfig.baseRetryDelay * pow(2, Double(cappedExponent))
    let maximumDelay = deliveryConfig.baseRetryDelay * pow(2, Double(maximumExponent))
    let delay = retryAfter.map { min(max($0, ordinaryDelay), maximumDelay) }
      ?? ordinaryDelay
    nextRetryDate = Date().addingTimeInterval(delay)
    return delay
  }

  @discardableResult
  private func scheduleAuthenticationRetry() -> TimeInterval {
    retryCount += 1
    deliveryState.health = .unhealthyAuthentication
    let delay = deliveryConfig.flushIntervalSeconds
    nextRetryDate = Date().addingTimeInterval(delay)
    return delay
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

  private func stopFlushTimer() async {
    let task = flushTimerTask
    flushTimerTask = nil
    task?.cancel()
    await task?.value
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

  func deliveryHealthState() -> String {
    deliveryState.health.rawValue
  }

  private func handleTimerFlush() async {
    await refillDeliveryWindow()
    if !deliveryQueue.isEmpty {
      LogDebug("Timer flush triggered (\(deliveryQueue.count) events)")
      _ = await performFlush()
    }
  }

  private typealias DeliveryDisposition = EventDeliveryDisposition

  private enum SDKDeliveryHealth: String {
    case healthy
    case unhealthyAuthentication = "unhealthy_authentication"
  }

  private struct DeliveryState {
    var adaptiveBatchSize: Int?
    var health: SDKDeliveryHealth = .healthy
    var didRepartitionLastFlush = false
  }

  // MARK: - Drain (test determinism)

  public func drain() async {
    guard !closeFlag.isClosed else { return }

    await drainCaptureWorker()
    await drainRouteWorker()
    await drainForwardingWorker()
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

  private func drainForwardingWorker() async {
    await withCheckedContinuation { continuation in
      if case .terminated = forwardingContinuation.yield(.barrier(continuation)) {
        continuation.resume()
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
      distinctId: event.distinctId
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

/// Stable captures that feed local trigger processing commit and enqueue their
/// ordered route resolution before returning to the caller. Recovery-only
/// captures continue to use `captureSystemEvent` and never enter this lane.
protocol RoutedStableSystemEventCapturing: StableSystemEventCapturing {
  func captureAndRouteSystemEvent(
    _ event: String,
    properties: sending [String: Any]?,
    eventId: String,
    distinctId: String
  ) async -> DurableTriggerCapture?
  func captureAndRouteSystemEvent(
    _ event: String,
    properties: sending [String: Any]?,
    eventId: String,
    distinctId: String,
    admission: any StableEventCaptureCommitAdmission
  ) async -> DurableTriggerCapture?
}

extension EventLog {
  func captureAndRouteSystemEvent(
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
      ownership: nil,
      routeToSubscribers: true
    ) {
    case .captured(let capture):
      return capture
    case .ownershipLost, .failed:
      return nil
    }
  }

  func captureAndRouteSystemEvent(
    _ event: String,
    properties: sending [String: Any]?,
    eventId: String,
    distinctId: String,
    admission: any StableEventCaptureCommitAdmission
  ) async -> DurableTriggerCapture? {
    switch await captureStableSystemEvent(
      event,
      properties: properties,
      eventId: eventId,
      distinctId: distinctId,
      ownership: nil,
      routeToSubscribers: true,
      admission: admission
    ) {
    case .captured(let capture):
      return capture
    case .ownershipLost, .failed:
      return nil
    }
  }
}
