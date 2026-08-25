import Foundation
@testable import Nuxie

/// Mock implementation of EventLog for testing
// @unchecked Sendable: all mutable state is serialized through `lock`.
public final class MockEventLog: EventLogProtocol, @unchecked Sendable {
    private let lock = NSLock()

    /// Optional collaborators used to enrich mock events. When nil, static
    /// test defaults are used instead.
    private var _identity: IdentityServiceProtocol?
    private var _sessions: SessionServiceProtocol?
    public var identity: IdentityServiceProtocol? {
        get { lock.withLock { _identity } }
        set { lock.withLock { _identity = newValue } }
    }
    public var sessions: SessionServiceProtocol? {
        get { lock.withLock { _sessions } }
        set { lock.withLock { _sessions = newValue } }
    }

    private var _routedEvents: [NuxieEvent] = []
    private var _trackedEvents: [(name: String, properties: [String: Any]?)] = []
    private var _eventHandlers: [(String, (NuxieEvent) -> Void)] = []
    private var _getEventsForUserCallCount = 0
    private var _drainCallCount = 0
    private var _committedServerFacts: [(facts: [JourneyDownFact], distinctId: String)] = []
    private var _mailboxPendingHandler: (@Sendable () async -> Void)?
    private var _journeyOwnershipRejectedHandler:
        (@Sendable (_ journeyId: String, _ epoch: Int) async -> Void)?
    private var _journeyHandoffDeliveredHandler:
        (@Sendable (_ journeyId: String) async -> Void)?
    private var _preparedTriggerResponseTasks: [UUID: Task<EventResponse, Never>] = [:]
    private var _preparedTriggerResponseTail:
        (id: UUID, task: Task<EventResponse, Never>)?
    private var _preparedTriggerBeforeSend:
        (@Sendable (NuxieEvent) -> NuxieEvent?)?
    private var _prepareTriggerPropertiesHandler: (@Sendable () async -> Void)?
    private var _drainHandler: (@Sendable () async -> Void)?
    private var _trackWithResponseHandler: (@Sendable (String) async -> Void)?
    private var _capturedEventObserver: (@Sendable (NuxieEvent) -> Void)?
    private var _journeyOwnershipFences: [String: Int] = [:]
    private var _shouldFailJourneyOwnershipCheck = false
    private var _stableOwnedCaptures: [String: DurableTriggerCapture] = [:]
    private var _resetGeneration: UInt64 = 0

    public var preparedTriggerBeforeSend:
        (@Sendable (NuxieEvent) -> NuxieEvent?)? {
        get { lock.withLock { _preparedTriggerBeforeSend } }
        set { lock.withLock { _preparedTriggerBeforeSend = newValue } }
    }

    public var prepareTriggerPropertiesHandler: (@Sendable () async -> Void)? {
        get { lock.withLock { _prepareTriggerPropertiesHandler } }
        set { lock.withLock { _prepareTriggerPropertiesHandler = newValue } }
    }

    public var drainHandler: (@Sendable () async -> Void)? {
        get { lock.withLock { _drainHandler } }
        set { lock.withLock { _drainHandler = newValue } }
    }

    public var trackWithResponseHandler: (@Sendable (String) async -> Void)? {
        get { lock.withLock { _trackWithResponseHandler } }
        set { lock.withLock { _trackWithResponseHandler = newValue } }
    }

    public var capturedEventObserver: (@Sendable (NuxieEvent) -> Void)? {
        get { lock.withLock { _capturedEventObserver } }
        set { lock.withLock { _capturedEventObserver = newValue } }
    }
    public var shouldFailJourneyOwnershipCheck: Bool {
        get { lock.withLock { _shouldFailJourneyOwnershipCheck } }
        set { lock.withLock { _shouldFailJourneyOwnershipCheck = newValue } }
    }
    
    public private(set) var routedEvents: [NuxieEvent] {
        get { lock.withLock { _routedEvents } }
        set { lock.withLock { _routedEvents = newValue } }
    }
    public private(set) var trackedEvents: [(name: String, properties: [String: Any]?)] {
        get { lock.withLock { _trackedEvents } }
        set { lock.withLock { _trackedEvents = newValue } }
    }
    public private(set) var eventHandlers: [(String, (NuxieEvent) -> Void)] {
        get { lock.withLock { _eventHandlers } }
        set { lock.withLock { _eventHandlers = newValue } }
    }
    public var getEventsForUserCallCount: Int {
        lock.withLock { _getEventsForUserCallCount }
    }
    public var drainCallCount: Int {
        lock.withLock { _drainCallCount }
    }
    public var committedServerFacts: [(facts: [JourneyDownFact], distinctId: String)] {
        lock.withLock { _committedServerFacts }
    }
    
    // Test helper: track last event times
    private var lastEventTimes: [String: Date] = [:]

    /// Canned mock results represent the complete test fixture history.
    public func historyCoverage() async -> EventHistoryCoverage { .complete }
    
    // Primary protocol method - matches EventLogProtocol
    public func track(
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
            distinctIdOverride: identity?.getDistinctId() ?? "test-distinct-id"
        )
    }

    public func track(
        _ event: String,
        properties: [String: Any]? = nil,
        userProperties: [String: Any]? = nil,
        userPropertiesSetOnce: [String: Any]? = nil,
        distinctIdOverride: String
    ) {
        // Create a simple NuxieEvent for mock purposes (without enrichment)
        let nuxieEvent = TestEventBuilder(name: event)
            .withDistinctId(distinctIdOverride)
            .withProperties(properties ?? [:])
            .build()

        // Production capture persists history before routing. Mirror that
        // ordering synchronously so immediate goal evaluation can attribute a
        // state change to this stable fact id.
        let (handlers, observer): (
            [(String, (NuxieEvent) -> Void)],
            (@Sendable (NuxieEvent) -> Void)?
        ) = lock.withLock {
            _trackedEvents.append((name: event, properties: properties))
            _routedEvents.append(nuxieEvent)
            return (_eventHandlers, _capturedEventObserver)
        }
        observer?(nuxieEvent)

        Task {
            handlers.forEach { pattern, handler in
                if pattern == nuxieEvent.name || pattern == "*" {
                    handler(nuxieEvent)
                }
            }
            let subscribers = lock.withLock { _committedSubscribers }
            for subscriber in subscribers {
                if let filter = subscriber.filter, !filter(nuxieEvent) { continue }
                await subscriber.handler(nuxieEvent)
            }
        }
    }

    public func trackWithoutRouting(
        _ event: String,
        properties: [String: Any]?,
        distinctIdOverride: String
    ) {
        let nuxieEvent = TestEventBuilder(name: event)
            .withDistinctId(distinctIdOverride)
            .withProperties(properties ?? [:])
            .build()
        let (observer, subscribers) = lock.withLock {
            _trackedEvents.append((name: event, properties: properties))
            return (_capturedEventObserver, _forwardingSubscribers)
        }
        observer?(nuxieEvent)
        Task {
            for subscriber in subscribers where subscriber.isEnabled() {
                await subscriber.handler(DurableForwardingEvent(
                    event: nuxieEvent,
                    receivedAt: nuxieEvent.timestamp
                ))
            }
        }
    }
    
    @discardableResult
    public func route(_ event: NuxieEvent) async -> NuxieEvent? {
        let handlers: [(String, (NuxieEvent) -> Void)] = lock.withLock {
            _routedEvents.append(event)
            return _eventHandlers
        }
        
        // Notify handlers outside lock
        handlers.forEach { (pattern, handler) in
            if pattern == event.name || pattern == "*" {
                handler(event)
            }
        }

        let subscribers = lock.withLock { _committedSubscribers }
        for subscriber in subscribers {
            if let filter = subscriber.filter, !filter(event) { continue }
            await subscriber.handler(event)
        }

        return event
    }
    
    public func routeBatch(_ events: [NuxieEvent]) async -> [NuxieEvent] {
        var routed: [NuxieEvent] = []
        for event in events {
            if let e = await route(event) {
                routed.append(e)
            }
        }
        return routed
    }
    
    public func configure(configuration: NuxieSetupConfiguration?) async throws {
        // Mock implementation - no-op
    }

    private var _committedSubscribers:
        [(filter: (@Sendable (NuxieEvent) -> Bool)?, handler: CommittedEventHandler)] = []
    private var _forwardingSubscribers:
        [(isEnabled: @Sendable () -> Bool, handler: ForwardingEventHandler)] = []

    public func subscribeCommitted(
        where filter: (@Sendable (NuxieEvent) -> Bool)?,
        handler: @escaping CommittedEventHandler
    ) async {
        lock.withLock {
            _committedSubscribers.append((filter: filter, handler: handler))
        }
    }

    public func subscribeForwarding(
        when isEnabled: @escaping @Sendable () -> Bool,
        handler: @escaping ForwardingEventHandler
    ) async {
        lock.withLock {
            _forwardingSubscribers.append((isEnabled: isEnabled, handler: handler))
        }
    }
    
    public func getRecentEvents(limit: Int) async -> [StoredEvent] {
        // Convert NuxieEvents to StoredEvents for mock
        let events = lock.withLock { _routedEvents }
        return events.suffix(limit).compactMap { event in
            try? StoredEvent(
                id: event.id,
                name: event.name,
                properties: event.properties,
                timestamp: event.timestamp,
                distinctId: event.distinctId
            )
        }
    }
    
    public func getEventsForUser(_ distinctId: String, limit: Int) async -> [StoredEvent] {
        let events = lock.withLock {
            _getEventsForUserCallCount += 1
            return _routedEvents
        }
        let userEvents = events.filter { $0.distinctId == distinctId }
        return userEvents.suffix(limit).compactMap { event in
            try? StoredEvent(
                id: event.id,
                name: event.name,
                properties: event.properties,
                timestamp: event.timestamp,
                distinctId: event.distinctId
            )
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
        let events = lock.withLock {
            _getEventsForUserCallCount += 1
            return _routedEvents
        }
        let filtered = events
            .filter { $0.distinctId == distinctId && $0.name == name }
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
        return Array(filtered.prefix(limit)).compactMap { event in
            try? StoredEvent(
                id: event.id,
                name: event.name,
                properties: event.properties,
                timestamp: event.timestamp,
                distinctId: event.distinctId
            )
        }
    }

    public func queryEventsForIR(
        _ distinctId: String,
        name: String,
        since: Date?,
        until: Date?,
        ascending: Bool,
        limit: Int
    ) async throws -> [StoredEvent] {
        await getEventsForUser(
            distinctId,
            name: name,
            since: since,
            until: until,
            ascending: ascending,
            limit: limit
        )
    }

    public func storePreparedEventInHistory(_ event: NuxieEvent) async {
        lock.withLock {
            _routedEvents.append(event)
        }
    }

    public func commitServerFacts(_ facts: [JourneyDownFact], distinctId: String) async {
        lock.withLock {
            _committedServerFacts.append((facts: facts, distinctId: distinctId))
        }
    }

    public func setMailboxPendingHandler(
        _ handler: (@Sendable () async -> Void)?
    ) async {
        lock.withLock { _mailboxPendingHandler = handler }
    }

    public func setJourneyOwnershipRejectedHandler(
        _ handler: (@Sendable (_ journeyId: String, _ epoch: Int) async -> Void)?
    ) async {
        lock.withLock { _journeyOwnershipRejectedHandler = handler }
    }

    public func setJourneyHandoffDeliveredHandler(
        _ handler: (@Sendable (_ journeyId: String) async -> Void)?
    ) async {
        lock.withLock { _journeyHandoffDeliveredHandler = handler }
    }
    
    public func getEvents(for sessionId: String) async -> [StoredEvent] {
        // Return all events for specified session (mock)
        return await getRecentEvents(limit: routedEvents.count)
    }
    
    public func hasEvent(name: String, distinctId: String, since: Date?) async -> Bool {
        let events = lock.withLock { _routedEvents }
        let userEvents = events.filter { $0.distinctId == distinctId && $0.name == name }
        if let since = since {
            return userEvents.contains { $0.timestamp >= since }
        }
        return !userEvents.isEmpty
    }
    
    public func countEvents(name: String, distinctId: String, since: Date?, until: Date?) async -> Int {
        let events = lock.withLock { _routedEvents }
        var userEvents = events.filter { $0.distinctId == distinctId && $0.name == name }
        if let since = since {
            userEvents = userEvents.filter { $0.timestamp >= since }
        }
        if let until = until {
            userEvents = userEvents.filter { $0.timestamp <= until }
        }
        return userEvents.count
    }
    
    public func getLastEventTime(name: String, distinctId: String, since: Date?, until: Date?) async -> Date? {
        let key = "\(distinctId):\(name)"
        let cachedTimes: [String: Date] = lock.withLock { lastEventTimes }
        LogDebug("[MockEventLog] getLastEventTime called for event '\(name)', user '\(distinctId)'")
        LogDebug("[MockEventLog] Current lastEventTimes dictionary: \(cachedTimes)")
        LogDebug("[MockEventLog] Bounds: since=\(String(describing: since)), until=\(String(describing: until))")
        
        // Check test helper dictionary first
        if let time = cachedTimes[key] {
            LogDebug("[MockEventLog] Found cached time for key '\(key)': \(time)")
            // Apply bounds to the cached time
            if let since = since, time < since {
                LogDebug("[MockEventLog] Cached time is before 'since' bound, skipping")
            } else if let until = until, time > until {
                LogDebug("[MockEventLog] Cached time is after 'until' bound, skipping")
            } else {
                LogDebug("[MockEventLog] Cached time is within bounds, returning \(time)")
                return time
            }
        }
        
        // Fall back to routed events
        let events = lock.withLock { _routedEvents }
        var userEvents = events.filter { $0.distinctId == distinctId && $0.name == name }
        if let since = since {
            userEvents = userEvents.filter { $0.timestamp >= since }
        }
        if let until = until {
            userEvents = userEvents.filter { $0.timestamp <= until }
        }
        
        LogDebug("[MockEventLog] Checking \(events.count) routed events, found \(userEvents.count) matching events")
        
        // Return the most recent event within the bounds
        let result = userEvents.max(by: { $0.timestamp < $1.timestamp })?.timestamp
        LogDebug("[MockEventLog] Returning: \(String(describing: result))")
        return result
    }
    
    // Test helper method to set last event time
    public func setLastEventTime(name: String, distinctId: String, time: Date) {
        let key = "\(distinctId):\(name)"
        lock.withLock {
            lastEventTimes[key] = time
        }
    }
    
    // MARK: - Network Queue Management (Mock implementations)
    
    @discardableResult
    public func flushEvents() async -> Bool {
        // Mock implementation - return true
        return true
    }
    
    public func getQueuedEventCount() async -> Int {
        // Mock implementation - return count of routed events
        return lock.withLock { _routedEvents.count }
    }
    
    public func pauseEventQueue() async {
        // Mock implementation - no-op
    }
    
    public func resumeEventQueue() async {
        // Mock implementation - no-op
    }
    
    // MARK: - IR Evaluation Support
    
    public func exists(name: String, since: Date?, until: Date?, where predicate: IRPredicate?) async -> Bool {
        return await count(name: name, since: since, until: until, where: predicate) > 0
    }
    
    public func count(name: String, since: Date?, until: Date?, where predicate: IRPredicate?) async -> Int {
        let events = lock.withLock { _routedEvents }.filter { $0.name == name }
            .filter { event in
                if let s = since, event.timestamp < s { return false }
                if let u = until, event.timestamp > u { return false }
                return true
            }
        return events.count
    }
    
    public func firstTime(name: String, where predicate: IRPredicate?) async -> Date? {
        let events = lock.withLock { _routedEvents }.filter { $0.name == name }
            .sorted(by: { $0.timestamp < $1.timestamp })
        return events.first?.timestamp
    }
    
    public func lastTime(name: String, where predicate: IRPredicate?) async -> Date? {
        let events = lock.withLock { _routedEvents }.filter { $0.name == name }
            .sorted(by: { $0.timestamp > $1.timestamp })
        return events.first?.timestamp
    }
    
    public func aggregate(_ agg: Aggregate, name: String, prop: String, since: Date?, until: Date?, where predicate: IRPredicate?) async -> Double? {
        return nil // Mock implementation
    }
    
    public func inOrder(steps: [StepQuery], overallWithin: TimeInterval?, perStepWithin: TimeInterval?, since: Date?, until: Date?) async -> Bool {
        return false // Mock implementation
    }
    
    public func activePeriods(name: String, period: Period, total: Int, min: Int, where predicate: IRPredicate?) async -> Bool {
        return false // Mock implementation
    }
    
    public func stopped(name: String, inactiveFor: TimeInterval, where predicate: IRPredicate?) async -> Bool {
        return false // Mock implementation
    }
    
    public func restarted(name: String, inactiveFor: TimeInterval, within: TimeInterval, where predicate: IRPredicate?) async -> Bool {
        return false // Mock implementation
    }
    
    // Test helpers
    public func reset() {
        let preparedTasks = lock.withLock {
            _resetGeneration &+= 1
            let tasks = Array(_preparedTriggerResponseTasks.values)
            _preparedTriggerResponseTasks.removeAll()
            _preparedTriggerResponseTail = nil
            _nextPreparedTriggerSequence = 0
            // `identity` is wired once by MockFactory and survives resets;
            // `sessions` is per-test opt-in, so restore the nil default.
            _sessions = nil
            _routedEvents.removeAll()
            _trackedEvents.removeAll()
            _eventHandlers.removeAll()
            _committedServerFacts.removeAll()
            _mailboxPendingHandler = nil
            _journeyOwnershipRejectedHandler = nil
            _journeyHandoffDeliveredHandler = nil
            _preparedTriggerBeforeSend = nil
            _prepareTriggerPropertiesHandler = nil
            _drainHandler = nil
            _trackWithResponseHandler = nil
            _capturedEventObserver = nil
            _journeyOwnershipFences.removeAll()
            _shouldFailJourneyOwnershipCheck = false
            _stableOwnedCaptures.removeAll()
            lastEventTimes.removeAll()
            _trackWithResponseCalls.removeAll()
            _trackForTriggerCalls.removeAll()
            _trackWithResponseResult = nil
            _trackWithResponseResultsByEvent.removeAll()
            _trackWithResponseError = nil
            _trackForTriggerDelayNanoseconds = 0
            return tasks
        }
        preparedTasks.forEach { $0.cancel() }
    }
    
    public func addEventHandler(pattern: String, handler: @escaping (NuxieEvent) -> Void) {
        lock.withLock {
            _eventHandlers.append((pattern, handler))
        }
    }
    
    // MARK: - User Identity Management
    
    public func reassignEvents(from fromUserId: String, to toUserId: String) async throws -> Int {
        // Mock implementation: Update distinctId in routed events
        return lock.withLock {
            var reassignedCount = 0
            for i in 0..<_routedEvents.count {
                if _routedEvents[i].distinctId == fromUserId {
                    // Create new event with updated distinctId
                    let oldEvent = _routedEvents[i]
                    _routedEvents[i] = NuxieEvent(
                        id: oldEvent.id,
                        name: oldEvent.name,
                        distinctId: toUserId,
                        properties: oldEvent.properties,
                        timestamp: oldEvent.timestamp
                    )
                    reassignedCount += 1
                }
            }
            return reassignedCount
        }
    }
    
    // MARK: - Synchronous Tracking with Response

    private var _trackWithResponseResult: EventResponse?
    private var _trackWithResponseResultsByEvent: [String: EventResponse] = [:]
    private var _trackWithResponseError: Error?
    private var _trackWithResponseCalls: [
        (event: String, properties: [String: Any]?, flushPendingEvents: Bool, flushStrategy: EventFlushStrategy, distinctIdOverride: String?)
    ] = []
    private var _trackForTriggerCalls: [
        (event: String, properties: [String: Any]?, persistToHistory: Bool, distinctIdOverride: String?)
    ] = []
    private var _trackForTriggerDelayNanoseconds: UInt64 = 0
    private var _nextPreparedTriggerSequence: UInt64 = 0
    
    public var trackWithResponseResult: EventResponse? {
        get { lock.withLock { _trackWithResponseResult } }
        set { lock.withLock { _trackWithResponseResult = newValue } }
    }

    public func setTrackWithResponseResult(
        _ result: EventResponse?,
        for event: String
    ) {
        lock.withLock {
            _trackWithResponseResultsByEvent[event] = result
        }
    }
    
    public var trackWithResponseError: Error? {
        get { lock.withLock { _trackWithResponseError } }
        set { lock.withLock { _trackWithResponseError = newValue } }
    }
    
    public private(set) var trackWithResponseCalls: [
        (event: String, properties: [String: Any]?, flushPendingEvents: Bool, flushStrategy: EventFlushStrategy, distinctIdOverride: String?)
    ] {
        get { lock.withLock { _trackWithResponseCalls } }
        set { lock.withLock { _trackWithResponseCalls = newValue } }
    }

    public private(set) var trackForTriggerCalls: [
        (event: String, properties: [String: Any]?, persistToHistory: Bool, distinctIdOverride: String?)
    ] {
        get { lock.withLock { _trackForTriggerCalls } }
        set { lock.withLock { _trackForTriggerCalls = newValue } }
    }

    public var trackForTriggerDelayNanoseconds: UInt64 {
        get { lock.withLock { _trackForTriggerDelayNanoseconds } }
        set { lock.withLock { _trackForTriggerDelayNanoseconds = newValue } }
    }

    public func trackForTrigger(
        _ event: String,
        properties: sending [String: Any]?,
        persistToHistory: Bool,
        distinctIdOverride: String?,
        applyBeforeSend _: Bool
    ) async throws -> (NuxieEvent, EventResponse) {
        // Boxed so the write-once payload can be recorded and re-sent.
        let propertiesBox = UncheckedSendable(properties)
        lock.withLock {
            _trackForTriggerCalls.append((
                event: event,
                properties: propertiesBox.value,
                persistToHistory: persistToHistory,
                distinctIdOverride: distinctIdOverride
            ))
        }

        let delayNanoseconds = lock.withLock { _trackForTriggerDelayNanoseconds }
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }

        let (result, error): (EventResponse?, Error?) = lock.withLock {
            (
                _trackWithResponseResultsByEvent[event] ?? _trackWithResponseResult,
                _trackWithResponseError
            )
        }
        if let error = error {
            throw error
        }

        let enrichedProperties = await prepareTriggerProperties(propertiesBox.value)

        let nuxieEvent = TestEventBuilder(name: event)
            .withDistinctId(
                distinctIdOverride ?? identity?.getDistinctId() ?? "test-distinct-id"
            )
            .withProperties(enrichedProperties)
            .build()

        if persistToHistory {
            await route(nuxieEvent)
        }

        let response = result ?? EventResponse(
            status: "ok",
            payload: nil,
            customer: nil,
            eventId: nil,
            message: nil,
            featuresMatched: nil,
            usage: nil,
            journey: nil,
        )

        await applyEventResponseSignals(response)
        return (nuxieEvent, response)
    }

    public func captureOwnedJourneySystemEvent(
        _ event: String,
        properties: sending [String: Any]?,
        eventId: String,
        distinctId: String,
        ownership: JourneyEventOwnership
    ) async -> DurableOwnedTriggerCaptureResult {
        let propertiesBox = UncheckedSendable(properties)
        lock.withLock {
            _trackForTriggerCalls.append((
                event: event,
                properties: propertiesBox.value,
                persistToHistory: true,
                distinctIdOverride: distinctId
            ))
        }

        let enriched = await prepareTriggerProperties(propertiesBox.value)
        let original = NuxieEvent(
            id: eventId,
            name: event,
            distinctId: distinctId,
            properties: enriched
        )
        let transformed = await applyBeforeSend(to: original).map {
            NuxieEvent(
                id: eventId,
                name: $0.name,
                distinctId: distinctId,
                properties: $0.properties,
                timestamp: original.timestamp
            )
        }
        let fallback = DurableTriggerCapture(
            event: original,
            routesLocally: false
        )
        let committed: (capture: DurableTriggerCapture?, isNew: Bool) = lock.withLock {
            if (_journeyOwnershipFences[ownership.journeyId] ?? Int.min)
                >= ownership.epoch {
                return (nil, false)
            }
            if let existing = _stableOwnedCaptures[eventId] {
                return (existing, false)
            }
            let capture = transformed.map { DurableTriggerCapture(event: $0) } ?? fallback
            _stableOwnedCaptures[eventId] = capture
            return (capture, true)
        }
        guard let capture = committed.capture else { return .ownershipLost }
        if committed.isNew, capture.routesLocally {
            _ = await route(capture.event)
        }
        return .captured(capture)
    }

    public func journeyEventOwnershipState(
        _ ownership: JourneyEventOwnership
    ) async -> JourneyEventOwnershipState {
        lock.withLock {
            guard !_shouldFailJourneyOwnershipCheck else { return .unavailable }
            return (_journeyOwnershipFences[ownership.journeyId] ?? Int.min)
                >= ownership.epoch
                ? .ownershipLost
                : .owned
        }
    }

    public func commitPreparedTriggerEvent(
        _ event: NuxieEvent
    ) async -> PreparedTriggerCommit {
        let (delayNanoseconds, generation) = lock.withLock {
            _trackForTriggerCalls.append((
                event: event.name,
                properties: event.properties,
                persistToHistory: true,
                distinctIdOverride: event.distinctId
            ))
            return (_trackForTriggerDelayNanoseconds, _resetGeneration)
        }
        await route(event)

        let taskID = UUID()
        let (sequence, response, belongsToCurrentGeneration) = lock.withLock {
            let belongsToCurrentGeneration = _resetGeneration == generation
            let sequence = _nextPreparedTriggerSequence
            let previousResponse = belongsToCurrentGeneration
                ? _preparedTriggerResponseTail?.task
                : nil
            let response = Task { [weak self] in
                defer {
                    if let self {
                        self.lock.withLock {
                            self._preparedTriggerResponseTasks.removeValue(forKey: taskID)
                            if self._preparedTriggerResponseTail?.id == taskID {
                                self._preparedTriggerResponseTail = nil
                            }
                        }
                    }
                }
                _ = await previousResponse?.value
                if delayNanoseconds > 0 {
                    do {
                        try await Task.sleep(nanoseconds: delayNanoseconds)
                    } catch {
                        return EventResponse(status: "offline", eventId: event.id)
                    }
                }
                guard !Task.isCancelled, let self else {
                    return EventResponse(status: "offline", eventId: event.id)
                }
                let result = self.lock.withLock { () -> EventResponse? in
                    guard self._resetGeneration == generation else { return nil }
                    return self._trackWithResponseResultsByEvent[event.name]
                        ?? self._trackWithResponseResult
                }
                let resolved = result ?? EventResponse(
                    status: "ok",
                    eventId: event.id
                )
                guard self.lock.withLock({ self._resetGeneration == generation }) else {
                    return EventResponse(status: "offline", eventId: event.id)
                }
                await self.applyEventResponseSignals(
                    resolved,
                    expectedGeneration: generation
                )
                return resolved
            }
            if belongsToCurrentGeneration {
                _nextPreparedTriggerSequence += 1
                _preparedTriggerResponseTasks[taskID] = response
                _preparedTriggerResponseTail = (taskID, response)
            }
            return (sequence, response, belongsToCurrentGeneration)
        }
        if !belongsToCurrentGeneration { response.cancel() }
        return PreparedTriggerCommit(
            event: event,
            response: response,
            sequence: sequence
        )
    }

    public func prepareTriggerProperties(
        _ properties: sending [String: Any]?
    ) async -> sending [String: Any] {
        let handler = lock.withLock { _prepareTriggerPropertiesHandler }
        await handler?()
        var finalProperties = properties ?? [:]

        if finalProperties["$session_id"] == nil,
           let sessions,
           let sessionId = sessions.getSessionId(at: Date(), readOnly: false) {
            finalProperties["$session_id"] = sessionId
            sessions.touchSession()
        }

        return finalProperties
    }

    public func applyBeforeSend(to event: NuxieEvent) async -> NuxieEvent? {
        let beforeSend = lock.withLock { _preparedTriggerBeforeSend }
        guard let beforeSend else { return event }
        return beforeSend(event)
    }

    public func trackWithResponse(
        _ event: String,
        properties: [String: Any]?
    ) async throws -> EventResponse {
        try await trackWithResponse(
            event,
            properties: properties,
            flushPendingEvents: true
        )
    }

    public func trackWithResponse(
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

    public func trackWithResponse(
        _ event: String,
        properties: [String: Any]?,
        flushStrategy: EventFlushStrategy
    ) async throws -> EventResponse {
        try await trackWithResponse(
            event,
            properties: properties,
            flushStrategy: flushStrategy,
            distinctIdOverride: nil
        )
    }

    public func trackWithResponse(
        _ event: String,
        properties: [String: Any]?,
        flushStrategy: EventFlushStrategy,
        distinctIdOverride: String?
    ) async throws -> EventResponse {
        let handler = lock.withLock { _trackWithResponseHandler }
        await handler?(event)
        lock.withLock {
            _trackWithResponseCalls.append((
                event: event,
                properties: properties,
                flushPendingEvents: flushStrategy != .none,
                flushStrategy: flushStrategy,
                distinctIdOverride: distinctIdOverride
            ))
        }
        let (result, error): (EventResponse?, Error?) = lock.withLock {
            (
                _trackWithResponseResultsByEvent[event] ?? _trackWithResponseResult,
                _trackWithResponseError
            )
        }
        if let error = error {
            throw error
        }

        let response = result ?? EventResponse(
            status: "ok",
            payload: nil,
            customer: nil,
            eventId: nil,
            message: nil,
            featuresMatched: nil,
            usage: nil,
            journey: nil,
        )
        await applyEventResponseSignals(response)
        return response
    }

    private func applyEventResponseSignals(
        _ response: EventResponse,
        expectedGeneration: UInt64? = nil
    ) async {
        func current<T>(_ read: () -> T?) -> T? {
            lock.withLock {
                guard !Task.isCancelled,
                      expectedGeneration == nil || _resetGeneration == expectedGeneration else {
                    return nil
                }
                return read()
            }
        }
        lock.withLock {
            guard !Task.isCancelled,
                  expectedGeneration == nil || _resetGeneration == expectedGeneration else {
                return
            }
            if let ownership = response.journeyClaim, !ownership.accepted {
                _journeyOwnershipFences[ownership.journeyId] = max(
                    _journeyOwnershipFences[ownership.journeyId] ?? Int.min,
                    ownership.epoch
                )
            }
            if let ownership = response.journeyOwnership {
                _journeyOwnershipFences[ownership.journeyId] = max(
                    _journeyOwnershipFences[ownership.journeyId] ?? Int.min,
                    ownership.epoch
                )
            }
        }
        if response.mailboxPending == true {
            let handler = current { _mailboxPendingHandler }
            await handler?()
        }
        if let ownership = response.journeyClaim, !ownership.accepted {
            let handler = current { _journeyOwnershipRejectedHandler }
            await handler?(ownership.journeyId, ownership.epoch)
        }
        if let ownership = response.journeyOwnership {
            if ownership.accepted {
                let handler = current { _journeyHandoffDeliveredHandler }
                await handler?(ownership.journeyId)
            } else {
                let handler = current { _journeyOwnershipRejectedHandler }
                await handler?(ownership.journeyId, ownership.epoch)
            }
        }
    }

    /// Delivers only the response-side ownership/mailbox signals. Tests use
    /// this to place an authoritative response at an exact suspension point
    /// without introducing an unrelated trigger capture.
    public func deliverEventResponseSignals(_ response: EventResponse) async {
        await applyEventResponseSignals(response)
    }

    // MARK: - Cleanup

    public func close() async {
        // Mock implementation: just reset state
        reset()
    }

    // MARK: - Drain

    public func drain() async {
        lock.withLock {
            _drainCallCount += 1
        }
        let handler = lock.withLock { _drainHandler }
        await handler?()
    }

    // MARK: - Lifecycle Events
    
    public func onAppDidEnterBackground() async {
        // Mock implementation - no-op for tests
    }
    
    public func onAppBecameActive() async {
        // Mock implementation - no-op for tests
    }
}
