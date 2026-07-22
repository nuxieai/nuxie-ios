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
    
    // Test helper: track last event times
    private var lastEventTimes: [String: Date] = [:]
    
    // Primary protocol method - matches EventLogProtocol
    public func track(
        _ event: String,
        properties: [String: Any]? = nil,
        userProperties: [String: Any]? = nil,
        userPropertiesSetOnce: [String: Any]? = nil
    ) {
        // Track the event for test verification
        lock.withLock {
            _trackedEvents.append((name: event, properties: properties))
        }
        
        // Create a simple NuxieEvent for mock purposes (without enrichment)
        let nuxieEvent = TestEventBuilder(name: event)
            .withDistinctId(identity?.getDistinctId() ?? "test-distinct-id")
            .withProperties(properties ?? [:])
            .build()
        
        Task { await route(nuxieEvent) }
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
    
    public func configure(configuration: NuxieConfiguration?) async throws {
        // Mock implementation - no-op
    }

    private var _committedSubscribers:
        [(filter: (@Sendable (NuxieEvent) -> Bool)?, handler: CommittedEventHandler)] = []

    public func subscribeCommitted(
        where filter: (@Sendable (NuxieEvent) -> Bool)?,
        handler: @escaping CommittedEventHandler
    ) async {
        lock.withLock {
            _committedSubscribers.append((filter: filter, handler: handler))
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

    public func storePreparedEventInHistory(_ event: NuxieEvent) async {
        lock.withLock {
            _routedEvents.append(event)
        }
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
        lock.withLock {
            // `identity` is wired once by MockFactory and survives resets;
            // `sessions` is per-test opt-in, so restore the nil default.
            _sessions = nil
            _routedEvents.removeAll()
            _trackedEvents.removeAll()
            _eventHandlers.removeAll()
            lastEventTimes.removeAll()
            _trackWithResponseCalls.removeAll()
            _trackForTriggerCalls.removeAll()
            _trackWithResponseResult = nil
            _trackWithResponseError = nil
            _trackForTriggerDelayNanoseconds = 0
        }
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
    private var _trackWithResponseError: Error?
    private var _trackWithResponseCalls: [
        (event: String, properties: [String: Any]?, flushPendingEvents: Bool, flushStrategy: EventFlushStrategy)
    ] = []
    private var _trackForTriggerCalls: [(event: String, properties: [String: Any]?, distinctIdOverride: String?)] = []
    private var _trackForTriggerDelayNanoseconds: UInt64 = 0
    
    public var trackWithResponseResult: EventResponse? {
        get { lock.withLock { _trackWithResponseResult } }
        set { lock.withLock { _trackWithResponseResult = newValue } }
    }
    
    public var trackWithResponseError: Error? {
        get { lock.withLock { _trackWithResponseError } }
        set { lock.withLock { _trackWithResponseError = newValue } }
    }
    
    public private(set) var trackWithResponseCalls: [
        (event: String, properties: [String: Any]?, flushPendingEvents: Bool, flushStrategy: EventFlushStrategy)
    ] {
        get { lock.withLock { _trackWithResponseCalls } }
        set { lock.withLock { _trackWithResponseCalls = newValue } }
    }

    public private(set) var trackForTriggerCalls: [(event: String, properties: [String: Any]?, distinctIdOverride: String?)] {
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
        userProperties: sending [String: Any]?,
        userPropertiesSetOnce: sending [String: Any]?,
        persistToHistory: Bool,
        distinctIdOverride: String?
    ) async throws -> (NuxieEvent, EventResponse) {
        // Boxed so the write-once payloads can be recorded and re-sent.
        let propertiesBox = UncheckedSendable(properties)
        let userPropertiesBox = UncheckedSendable(userProperties)
        let userPropertiesSetOnceBox = UncheckedSendable(userPropertiesSetOnce)
        lock.withLock {
            _trackForTriggerCalls.append((event: event, properties: propertiesBox.value, distinctIdOverride: distinctIdOverride))
        }

        let delayNanoseconds = lock.withLock { _trackForTriggerDelayNanoseconds }
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }

        let (result, error): (EventResponse?, Error?) = lock.withLock {
            (_trackWithResponseResult, _trackWithResponseError)
        }
        if let error = error {
            throw error
        }

        let enrichedProperties = await prepareTriggerProperties(
            propertiesBox.value,
            userProperties: userPropertiesBox.value,
            userPropertiesSetOnce: userPropertiesSetOnceBox.value
        )

        let nuxieEvent = TestEventBuilder(name: event)
            .withDistinctId(distinctIdOverride ?? "test-distinct-id")
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
            execution: nil
        )

        return (nuxieEvent, response)
    }

    public func prepareTriggerProperties(
        _ properties: sending [String: Any]?,
        userProperties: sending [String: Any]?,
        userPropertiesSetOnce: sending [String: Any]?
    ) async -> sending [String: Any] {
        var finalProperties = properties ?? [:]
        if let userProperties { finalProperties["$set"] = userProperties }
        if let userPropertiesSetOnce { finalProperties["$set_once"] = userPropertiesSetOnce }

        if finalProperties["$session_id"] == nil,
           let sessions,
           let sessionId = sessions.getSessionId(at: Date(), readOnly: false) {
            finalProperties["$session_id"] = sessionId
            sessions.touchSession()
        }

        return finalProperties
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
        lock.withLock {
            _trackWithResponseCalls.append((
                event: event,
                properties: properties,
                flushPendingEvents: flushStrategy != .none,
                flushStrategy: flushStrategy
            ))
        }

        let (result, error): (EventResponse?, Error?) = lock.withLock {
            (_trackWithResponseResult, _trackWithResponseError)
        }
        if let error = error {
            throw error
        }

        return result ?? EventResponse(
            status: "ok",
            payload: nil,
            customer: nil,
            eventId: nil,
            message: nil,
            featuresMatched: nil,
            usage: nil,
            journey: nil,
            execution: nil
        )
    }

    // MARK: - Cleanup

    public func close() async {
        // Mock implementation: just reset state
        reset()
    }

    // MARK: - Drain

    public func drain() async {
        // Mock implementation: no-op since mock events are stored synchronously
    }

    // MARK: - Lifecycle Events
    
    public func onAppDidEnterBackground() async {
        // Mock implementation - no-op for tests
    }
    
    public func onAppBecameActive() async {
        // Mock implementation - no-op for tests
    }
}
