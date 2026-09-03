import Foundation
@testable import Nuxie

/// Mock implementation of EventLog for testing
// @unchecked Sendable: all mutable state is serialized through `lock`.
public final class MockEventLog: EventLogProtocol, @unchecked Sendable {
    private struct CommittedSubscriber {
        let identifier: UInt64
        let filter: (@Sendable (NuxieEvent) -> Bool)?
        let handler: AdmittedCommittedEventHandler
    }

    private let lock = NSLock()

    /// Optional collaborators used to enrich mock events. When nil, static
    /// test defaults are used instead.
    private var _identity: IdentityServiceProtocol?
    public var identity: IdentityServiceProtocol? {
        get { lock.withLock { _identity } }
        set { lock.withLock { _identity = newValue } }
    }
    private var _routedEvents: [NuxieEvent] = []
    private var _trackedEvents: [(name: String, properties: [String: Any]?)] = []
    private var _eventHandlers: [(String, (NuxieEvent) -> Void)] = []
    private var _getEventsForUserCallCount = 0
    private var _drainCallCount = 0
    private var _committedRoutingDrainCallCount = 0
    private var _preparedTriggerBeforeSend:
        (@Sendable (NuxieEvent) -> NuxieEvent?)?
    private var _prepareEventPropertiesHandler: (@Sendable () async -> Void)?
    private var _routedCaptureHandler:
        (@Sendable (_ event: String, _ eventId: String) async -> Void)?
    private var _drainHandler: (@Sendable () async -> Void)?
    private var _capturedEventObserver: (@Sendable (NuxieEvent) -> Void)?
    private var _stableCaptures: [String: DurableTriggerCapture] = [:]
    private var _stableCaptureBatchFailureIndex: Int?
    private var _routedCaptureFailuresRemaining = 0

    public var preparedTriggerBeforeSend:
        (@Sendable (NuxieEvent) -> NuxieEvent?)? {
        get { lock.withLock { _preparedTriggerBeforeSend } }
        set { lock.withLock { _preparedTriggerBeforeSend = newValue } }
    }

    public var prepareEventPropertiesHandler: (@Sendable () async -> Void)? {
        get { lock.withLock { _prepareEventPropertiesHandler } }
        set { lock.withLock { _prepareEventPropertiesHandler = newValue } }
    }

    public var routedCaptureHandler:
        (@Sendable (_ event: String, _ eventId: String) async -> Void)? {
        get { lock.withLock { _routedCaptureHandler } }
        set { lock.withLock { _routedCaptureHandler = newValue } }
    }

    public var drainHandler: (@Sendable () async -> Void)? {
        get { lock.withLock { _drainHandler } }
        set { lock.withLock { _drainHandler = newValue } }
    }

    public var capturedEventObserver: (@Sendable (NuxieEvent) -> Void)? {
        get { lock.withLock { _capturedEventObserver } }
        set { lock.withLock { _capturedEventObserver = newValue } }
    }
    public var stableCaptureBatchFailureIndex: Int? {
        get { lock.withLock { _stableCaptureBatchFailureIndex } }
        set { lock.withLock { _stableCaptureBatchFailureIndex = newValue } }
    }
    public var routedCaptureFailuresRemaining: Int {
        get { lock.withLock { _routedCaptureFailuresRemaining } }
        set { lock.withLock { _routedCaptureFailuresRemaining = max(newValue, 0) } }
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
    public var committedRoutingDrainCallCount: Int {
        lock.withLock { _committedRoutingDrainCallCount }
    }
    // Test helper: track last event times
    private var lastEventTimes: [String: Date] = [:]

    /// Canned mock results represent the complete test fixture history.
    private var _historyCoverageResult: EventHistoryCoverage = .complete
    public var historyCoverageResult: EventHistoryCoverage {
        get { lock.withLock { _historyCoverageResult } }
        set { lock.withLock { _historyCoverageResult = newValue } }
    }
    public func historyCoverage() async -> EventHistoryCoverage { historyCoverageResult }
    
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
        let admissions = captureCommittedAdmissions()

        Task {
            handlers.forEach { pattern, handler in
                if pattern == nuxieEvent.name || pattern == "*" {
                    handler(nuxieEvent)
                }
            }
            let subscribers = lock.withLock { _committedSubscribers }
            for subscriber in subscribers {
                if let filter = subscriber.filter, !filter(nuxieEvent) { continue }
                await subscriber.handler(
                    nuxieEvent,
                    admissions[subscriber.identifier]
                )
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
        await route(
            event,
            subscriberAdmissions: captureCommittedAdmissions()
        )
    }

    @discardableResult
    private func route(
        _ event: NuxieEvent,
        subscriberAdmissions: [UInt64: UInt64]
    ) async -> NuxieEvent? {
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
            await subscriber.handler(
                event,
                subscriberAdmissions[subscriber.identifier]
            )
        }

        return event
    }

    public func captureAndRouteSystemEvent(
        _ request: StableSystemEventCaptureRequest
    ) async -> DurableTriggerCapture? {
        await captureAndRoute(request) {
            await self.captureSystemEvent(
                request.name,
                properties: request.properties,
                eventId: request.eventId,
                distinctId: request.distinctId
            )
        }
    }

    public func captureAndRouteSystemEvent(
        _ request: StableSystemEventCaptureRequest,
        admission: any StableEventCaptureCommitAdmission
    ) async -> DurableTriggerCapture? {
        await captureAndRoute(request) {
            await self.captureSystemEvent(
                request.name,
                properties: request.properties,
                eventId: request.eventId,
                distinctId: request.distinctId,
                admission: admission
            )
        }
    }

    public func captureAndRouteSystemEvent(
        _ request: StableSystemEventCaptureRequest,
        occurredAt: Date,
        admission: any StableEventCaptureCommitAdmission
    ) async -> DurableTriggerCapture? {
        await captureAndRoute(request) {
            await self.captureSystemEvent(
                request.name,
                properties: request.properties,
                eventId: request.eventId,
                distinctId: request.distinctId,
                occurredAt: occurredAt,
                admission: admission
            )
        }
    }

    private func captureAndRoute(
        _ request: StableSystemEventCaptureRequest,
        capture: () async -> DurableTriggerCapture?
    ) async -> DurableTriggerCapture? {
        let captureHandler = lock.withLock { _routedCaptureHandler }
        await captureHandler?(request.name, request.eventId)
        let shouldFail = lock.withLock { () -> Bool in
            guard _routedCaptureFailuresRemaining > 0 else { return false }
            _routedCaptureFailuresRemaining -= 1
            return true
        }
        guard !shouldFail else { return nil }
        let subscriberAdmissions = captureCommittedAdmissions()
        guard let result = await capture() else { return nil }
        guard result.routesLocally, result.isNewlyCommitted else {
            return result
        }
        _ = await route(
            result.event,
            subscriberAdmissions: subscriberAdmissions
        )
        return result
    }

    public func captureAndRouteSystemEventBatch(
        _ items: [RoutedStableSystemEventBatchItem],
        admission: any StableEventCaptureBatchCommitAdmission
    ) async -> [String: DurableTriggerCapture]? {
        guard !items.contains(where: { $0.request.name.isEmpty }),
              Set(items.map(\.request.eventId)).count == items.count else {
            return nil
        }
        guard !items.isEmpty else { return [:] }
        let subscriberAdmissions = captureCommittedAdmissions()
        var capturesByEventId = lock.withLock {
            Dictionary(uniqueKeysWithValues: items.compactMap { item in
                _stableCaptures[item.request.eventId].map { existing in
                    (
                        item.request.eventId,
                        DurableTriggerCapture(
                            event: existing.event,
                            routesLocally: existing.routesLocally,
                            isNewlyCommitted: false
                        )
                    )
                }
            })
        }
        let pendingItems = items.filter {
            capturesByEventId[$0.request.eventId] == nil
        }
        guard !pendingItems.isEmpty else { return capturesByEventId }
        var candidates: [(
            item: RoutedStableSystemEventBatchItem,
            capture: DurableTriggerCapture
        )] = []
        candidates.reserveCapacity(pendingItems.count)

        for item in pendingItems {
            let original: NuxieEvent
            let transformed: NuxieEvent?
            switch item.preparation {
            case .prepared(let event):
                original = NuxieEvent(
                    id: item.request.eventId,
                    name: item.request.name,
                    distinctId: item.request.distinctId,
                    properties: item.request.properties ?? [:],
                    timestamp: item.occurredAt
                )
                transformed = event
            case .unprepared:
                let enriched = await prepareEventProperties(
                    item.request.properties
                )
                original = NuxieEvent(
                    id: item.request.eventId,
                    name: item.request.name,
                    distinctId: item.request.distinctId,
                    properties: enriched,
                    timestamp: item.occurredAt
                )
                transformed = await applyBeforeSend(to: original).map {
                    var properties = $0.properties
                    properties["$distinct_id"] = item.request.distinctId
                    return NuxieEvent(
                        id: item.request.eventId,
                        name: $0.name,
                        forwardingName: original.forwardingName,
                        distinctId: item.request.distinctId,
                        properties: properties,
                        timestamp: item.occurredAt
                    )
                }
            }
            candidates.append((
                item: item,
                capture: transformed.map { DurableTriggerCapture(event: $0) }
                    ?? DurableTriggerCapture(
                        event: original,
                        routesLocally: false
                    )
            ))
        }

        var committedCaptures: [(capture: DurableTriggerCapture, isNew: Bool)] = []
        do {
            guard let _ = try admission.commitBatchIfCurrent({ [self] in
                try lock.withLock {
                    var captures = _stableCaptures
                    var results: [(capture: DurableTriggerCapture, isNew: Bool)] = []
                    results.reserveCapacity(candidates.count)
                    for (index, candidate) in candidates.enumerated() {
                        if _stableCaptureBatchFailureIndex == index {
                            throw NSError(
                                domain: "MockEventLog",
                                code: 1,
                                userInfo: [
                                    NSLocalizedDescriptionKey:
                                        "Injected stable capture batch failure"
                                ]
                            )
                        }
                        let request = candidate.item.request
                        if let existing = captures[request.eventId] {
                            results.append((
                                capture: DurableTriggerCapture(
                                    event: existing.event,
                                    routesLocally: existing.routesLocally,
                                    isNewlyCommitted: false
                                ),
                                isNew: false
                            ))
                        } else {
                            captures[request.eventId] = candidate.capture
                            results.append((capture: candidate.capture, isNew: true))
                        }
                    }
                    _stableCaptures = captures
                    committedCaptures = results
                    return results.map { _ in
                        StableEventCaptureCommit(
                            outcome: .dropped,
                            commitSequence: nil
                        )
                    }
                }
            }) else {
                return nil
            }
        } catch {
            return nil
        }

        for committed in committedCaptures
            where committed.isNew && committed.capture.routesLocally {
            _ = await route(
                committed.capture.event,
                subscriberAdmissions: subscriberAdmissions
            )
        }
        for (candidate, committed) in zip(candidates, committedCaptures) {
            capturesByEventId[candidate.item.request.eventId] = committed.capture
        }
        return capturesByEventId
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

    private var _committedSubscribers: [CommittedSubscriber] = []
    private var _nextCommittedSubscriberIdentifier: UInt64 = 0
    private var _committedAdmissionProviders:
        [UInt64: CommittedEventAdmissionProvider] = [:]
    private var _forwardingSubscribers:
        [(isEnabled: @Sendable () -> Bool, handler: ForwardingEventHandler)] = []

    public func subscribeCommitted(
        where filter: (@Sendable (NuxieEvent) -> Bool)?,
        handler: @escaping CommittedEventHandler
    ) async {
        lock.withLock {
            let identifier = _nextCommittedSubscriberIdentifier
            _nextCommittedSubscriberIdentifier &+= 1
            _committedSubscribers.append(.init(
                identifier: identifier,
                filter: filter,
                handler: { event, _ in await handler(event) }
            ))
        }
    }

    public func reserveCommittedAdmission(
        admission: @escaping CommittedEventAdmissionProvider
    ) -> CommittedEventAdmissionReservation {
        lock.withLock {
            let identifier = _nextCommittedSubscriberIdentifier
            _nextCommittedSubscriberIdentifier &+= 1
            _committedAdmissionProviders[identifier] = admission
            return .init(subscriberIdentifier: identifier)
        }
    }

    public func subscribeCommitted(
        where filter: (@Sendable (NuxieEvent) -> Bool)?,
        reservation: CommittedEventAdmissionReservation,
        handler: @escaping AdmittedCommittedEventHandler
    ) async {
        lock.withLock {
            _committedSubscribers.append(.init(
                identifier: reservation.subscriberIdentifier,
                filter: filter,
                handler: handler
            ))
        }
    }

    public func subscribeCommitted(
        where filter: (@Sendable (NuxieEvent) -> Bool)?,
        admission: @escaping CommittedEventAdmissionProvider,
        handler: @escaping AdmittedCommittedEventHandler
    ) async {
        let reservation = reserveCommittedAdmission(admission: admission)
        await subscribeCommitted(
            where: filter,
            reservation: reservation,
            handler: handler
        )
    }

    private func captureCommittedAdmissions() -> [UInt64: UInt64] {
        let providers = lock.withLock { _committedAdmissionProviders }
        var admissions: [UInt64: UInt64] = [:]
        for (identifier, provider) in providers {
            if let admission = provider() {
                admissions[identifier] = admission
            }
        }
        return admissions
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

    @discardableResult
    public func storePreparedEventInHistory(_ event: NuxieEvent) async -> Bool {
        lock.withLock {
            _routedEvents.append(event)
        }
        return true
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
            // `identity` is wired once by MockFactory and survives resets.
            _routedEvents.removeAll()
            _trackedEvents.removeAll()
            _eventHandlers.removeAll()
            _preparedTriggerBeforeSend = nil
            _prepareEventPropertiesHandler = nil
            _drainHandler = nil
            _committedRoutingDrainCallCount = 0
            _capturedEventObserver = nil
            _stableCaptures.removeAll()
            _stableCaptureBatchFailureIndex = nil
            _routedCaptureFailuresRemaining = 0
            lastEventTimes.removeAll()
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
    
    // MARK: - Stable system event capture

    public func captureSystemEvent(
        _ event: String,
        properties: sending [String: Any]?,
        eventId: String,
        distinctId: String
    ) async -> DurableTriggerCapture? {
        await captureSystemEvent(
            event,
            properties: properties,
            eventId: eventId,
            distinctId: distinctId,
            occurredAt: Date(),
            admission: nil
        )
    }

    private func captureSystemEvent(
        _ event: String,
        properties: sending [String: Any]?,
        eventId: String,
        distinctId: String,
        occurredAt: Date = Date(),
        admission: (any StableEventCaptureCommitAdmission)?
    ) async -> DurableTriggerCapture? {
        if let existing = lock.withLock({ _stableCaptures[eventId] }) {
            return DurableTriggerCapture(
                event: existing.event,
                routesLocally: existing.routesLocally,
                isNewlyCommitted: false
            )
        }

        let enriched = await prepareEventProperties(properties)
        let original = NuxieEvent(
            id: eventId,
            name: event,
            distinctId: distinctId,
            properties: enriched,
            timestamp: occurredAt
        )
        let transformed = await applyBeforeSend(to: original).map {
            NuxieEvent(
                id: eventId,
                name: $0.name,
                forwardingName: original.forwardingName,
                distinctId: distinctId,
                properties: $0.properties,
                timestamp: occurredAt
            )
        }
        let candidate = transformed.map {
            DurableTriggerCapture(event: $0)
        } ?? DurableTriggerCapture(event: original, routesLocally: false)

        let commit = { [self] in
            lock.withLock {
                if let existing = _stableCaptures[eventId] {
                    return DurableTriggerCapture(
                        event: existing.event,
                        routesLocally: existing.routesLocally,
                        isNewlyCommitted: false
                    )
                }
                _stableCaptures[eventId] = candidate
                return candidate
            }
        }

        guard let admission else { return commit() }
        var committedCapture: DurableTriggerCapture?
        let admitted = admission.commitIfCurrent {
            committedCapture = commit()
            return StableEventCaptureCommit(
                outcome: .dropped,
                commitSequence: nil
            )
        }
        guard admitted != nil else { return nil }
        return committedCapture
    }

    public func prepareEventProperties(
        _ properties: sending [String: Any]?
    ) async -> sending [String: Any] {
        let handler = lock.withLock { _prepareEventPropertiesHandler }
        await handler?()
        return properties ?? [:]
    }

    public func applyBeforeSend(to event: NuxieEvent) async -> NuxieEvent? {
        let beforeSend = lock.withLock { _preparedTriggerBeforeSend }
        guard let beforeSend else { return event }
        return beforeSend(event)
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

    public func drainCommittedRouting() async -> Bool {
        lock.withLock {
            _committedRoutingDrainCallCount += 1
        }
        return true
    }

    // MARK: - Lifecycle Events
    
    public func onAppDidEnterBackground() async {
        // Mock implementation - no-op for tests
    }
    
    public func onAppBecameActive() async {
        // Mock implementation - no-op for tests
    }
}
