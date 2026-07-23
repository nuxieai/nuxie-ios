import Foundation
@testable import Nuxie

/// Mock implementation of EventStoreProtocol for testing.
///
/// Thread safety: EventLog awaits these nonisolated-async methods from
/// several tasks (capture worker, delivery flushes, queries), so they run
/// concurrently on the cooperative pool. Every state access goes through
/// one lock — an unsynchronized mock segfaults under real load.
public final class MockEventStore: EventStoreProtocol, @unchecked Sendable {

    private let lock = NSLock()

    // Storage (lock-guarded)
    private var _storedEvents: [StoredEvent] = []
    private var _pendingIds: Set<String> = []
    private var _deliveredIds: [String] = []
    private var _isInitialized = false
    private var _isClosed = false

    public var storedEvents: [StoredEvent] {
        get { lock.withLock { _storedEvents } }
        set { lock.withLock { _storedEvents = newValue } }
    }
    /// Ids currently marked pending delivery (insertPending minus markDelivered)
    public var pendingIds: Set<String> {
        get { lock.withLock { _pendingIds } }
        set { lock.withLock { _pendingIds = newValue } }
    }
    public var deliveredIds: [String] {
        lock.withLock { _deliveredIds }
    }
    public var isInitialized: Bool {
        get { lock.withLock { _isInitialized } }
        set { lock.withLock { _isInitialized = newValue } }
    }
    public var isClosed: Bool {
        get { lock.withLock { _isClosed } }
        set { lock.withLock { _isClosed = newValue } }
    }

    // Error simulation (lock-guarded)
    private var _shouldFailInitialize = false
    private var _shouldFailStore = false
    private var _shouldFailQuery = false

    public var shouldFailInitialize: Bool {
        get { lock.withLock { _shouldFailInitialize } }
        set { lock.withLock { _shouldFailInitialize = newValue } }
    }
    public var shouldFailStore: Bool {
        get { lock.withLock { _shouldFailStore } }
        set { lock.withLock { _shouldFailStore = newValue } }
    }
    public var shouldFailQuery: Bool {
        get { lock.withLock { _shouldFailQuery } }
        set { lock.withLock { _shouldFailQuery = newValue } }
    }

    // Call tracking (lock-guarded)
    private var _initializeCallCount = 0
    private var _storeEventCallCount = 0
    private var _getRecentEventsCallCount = 0
    private var _getEventsForUserCallCount = 0
    private var _getEventCountCallCount = 0
    private var _closeCallCount = 0
    private var _reassignEventsCallCount = 0

    public var initializeCallCount: Int { lock.withLock { _initializeCallCount } }
    public var storeEventCallCount: Int { lock.withLock { _storeEventCallCount } }
    public var getRecentEventsCallCount: Int { lock.withLock { _getRecentEventsCallCount } }
    public var getEventsForUserCallCount: Int { lock.withLock { _getEventsForUserCallCount } }
    public var getEventCountCallCount: Int { lock.withLock { _getEventCountCallCount } }
    public var closeCallCount: Int { lock.withLock { _closeCallCount } }
    public var reassignEventsCallCount: Int { lock.withLock { _reassignEventsCallCount } }

    // Session tracking
    private var _currentSessionId = UUID.v7().uuidString

    public init() {}

    private func mockError(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "MockEventStore", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }

    // MARK: - EventStoreProtocol Implementation

    public func initialize(path: URL?) async throws {
        try lock.withLock {
            _initializeCallCount += 1
            if _shouldFailInitialize {
                throw mockError(1, "Mock initialization error")
            }
            _isInitialized = true
        }
    }

    public func reset() async {
        lock.withLock {
            _storedEvents.removeAll()
            _pendingIds.removeAll()
            _isInitialized = false
            _isClosed = false
        }
    }

    public func insertHistory(_ event: StoredEvent) async throws {
        try lock.withLock {
            _storeEventCallCount += 1
            if _shouldFailStore {
                throw mockError(2, "Mock store error")
            }
            _storedEvents.append(event)
        }
    }

    public func insertHistoryIfAbsent(_ event: StoredEvent) async throws -> Bool {
        try lock.withLock {
            _storeEventCallCount += 1
            if _shouldFailStore {
                throw mockError(2, "Mock store error")
            }
            guard !_storedEvents.contains(where: { $0.id == event.id }) else {
                return false
            }
            _storedEvents.append(event)
            return true
        }
    }

    public func insertPending(_ event: StoredEvent) async throws {
        try lock.withLock {
            _storeEventCallCount += 1
            if _shouldFailStore {
                throw mockError(2, "Mock store error")
            }
            _storedEvents.append(event)
            _pendingIds.insert(event.id)
        }
    }

    public func queryRecentEvents(limit: Int) async throws -> [StoredEvent] {
        try lock.withLock {
            _getRecentEventsCallCount += 1
            if _shouldFailQuery {
                throw mockError(3, "Mock query error")
            }
            return Array(_storedEvents.suffix(limit))
        }
    }

    public func queryEventsForUser(_ distinctId: String, limit: Int) async throws -> [StoredEvent] {
        try lock.withLock {
            _getEventsForUserCallCount += 1
            if _shouldFailQuery {
                throw mockError(3, "Mock query error")
            }
            let userEvents = _storedEvents.filter { $0.distinctId == distinctId }
            return Array(userEvents.suffix(limit))
        }
    }

    public func querySessionEvents(_ sessionId: String) async throws -> [StoredEvent] {
        try lock.withLock {
            if _shouldFailQuery {
                throw mockError(3, "Mock query error")
            }
            return _storedEvents.filter { $0.sessionId == sessionId }
        }
    }

    public func getEventCount() async throws -> Int {
        try lock.withLock {
            _getEventCountCallCount += 1
            if _shouldFailQuery {
                throw mockError(3, "Mock query error")
            }
            return _storedEvents.count
        }
    }

    public func close() async {
        lock.withLock {
            _closeCallCount += 1
            _isClosed = true
        }
    }

    // MARK: - Event Query Methods

    public func hasEvent(name: String, distinctId: String, since: Date?) async throws -> Bool {
        try lock.withLock {
            if _shouldFailQuery {
                throw mockError(3, "Mock query error")
            }
            let userEvents = _storedEvents.filter { $0.distinctId == distinctId && $0.name == name }
            if let since = since {
                return userEvents.contains { $0.timestamp >= since }
            }
            return !userEvents.isEmpty
        }
    }

    public func countEvents(name: String, distinctId: String, since: Date?, until: Date?) async throws -> Int {
        try lock.withLock {
            if _shouldFailQuery {
                throw mockError(3, "Mock query error")
            }
            var userEvents = _storedEvents.filter { $0.distinctId == distinctId && $0.name == name }
            if let since = since {
                userEvents = userEvents.filter { $0.timestamp >= since }
            }
            if let until = until {
                userEvents = userEvents.filter { $0.timestamp <= until }
            }
            return userEvents.count
        }
    }

    public func getLastEventTime(name: String, distinctId: String, since: Date?, until: Date?) async throws -> Date? {
        try lock.withLock {
            if _shouldFailQuery {
                throw mockError(3, "Mock query error")
            }
            var userEvents = _storedEvents.filter { $0.distinctId == distinctId && $0.name == name }
            if let since = since {
                userEvents = userEvents.filter { $0.timestamp >= since }
            }
            if let until = until {
                userEvents = userEvents.filter { $0.timestamp <= until }
            }
            return userEvents.max(by: { $0.timestamp < $1.timestamp })?.timestamp
        }
    }

    public func queryEventsForUser(
        _ distinctId: String, name: String, since: Date?, until: Date?,
        ascending: Bool, limit: Int
    ) async throws -> [StoredEvent] {
        lock.withLock {
            var filtered = _storedEvents.filter { $0.distinctId == distinctId && $0.name == name }
            if let since { filtered = filtered.filter { $0.timestamp >= since } }
            if let until { filtered = filtered.filter { $0.timestamp <= until } }
            filtered.sort { ascending ? $0.timestamp < $1.timestamp : $0.timestamp > $1.timestamp }
            return Array(filtered.prefix(limit))
        }
    }

    public func getFirstEventTime(name: String, distinctId: String, since: Date?, until: Date?) async throws -> Date? {
        try await queryEventsForUser(distinctId, name: name, since: since, until: until, ascending: true, limit: 1).first?.timestamp
    }

    // MARK: - Durable delivery

    public func queryPendingDelivery(limit: Int) async throws -> [StoredEvent] {
        lock.withLock {
            let pending = _storedEvents
                .filter { _pendingIds.contains($0.id) }
                .sorted { $0.timestamp < $1.timestamp }
            return Array(pending.prefix(limit))
        }
    }

    public func markDelivered(ids: [String]) async throws {
        lock.withLock {
            _deliveredIds.append(contentsOf: ids)
            for id in ids { _pendingIds.remove(id) }
        }
    }

    @discardableResult
    public func deleteEventsOlderThan(_ olderThan: Date) async throws -> Int {
        lock.withLock {
            let countBefore = _storedEvents.count
            _storedEvents.removeAll { $0.timestamp < olderThan && !_pendingIds.contains($0.id) }
            return countBefore - _storedEvents.count
        }
    }

    @discardableResult
    public func deleteOldestDeliveredEvents(keeping: Int) async throws -> Int {
        lock.withLock {
            let overCap = _storedEvents.count - keeping
            guard overCap > 0 else { return 0 }
            let deletable = _storedEvents
                .filter { !_pendingIds.contains($0.id) }
                .sorted { $0.timestamp < $1.timestamp }
                .prefix(overCap)
            let ids = Set(deletable.map(\.id))
            _storedEvents.removeAll { ids.contains($0.id) }
            return ids.count
        }
    }

    public func reassignEvents(from fromUserId: String, to toUserId: String) async throws -> Int {
        try lock.withLock {
            _reassignEventsCallCount += 1
            if _shouldFailQuery {
                throw mockError(5, "Mock reassign error")
            }
            var reassignedCount = 0
            for i in 0..<_storedEvents.count {
                if _storedEvents[i].distinctId == fromUserId {
                    let oldEvent = _storedEvents[i]
                    _storedEvents[i] = StoredEvent(
                        id: oldEvent.id,
                        name: oldEvent.name,
                        properties: oldEvent.properties,
                        timestamp: oldEvent.timestamp,
                        distinctId: toUserId,
                        sessionId: oldEvent.sessionId
                    )
                    reassignedCount += 1
                }
            }
            return reassignedCount
        }
    }

    // MARK: - Test Helpers

    public func resetMock() {
        lock.withLock {
            _storedEvents.removeAll()
            _pendingIds.removeAll()
            _deliveredIds.removeAll()
            _isInitialized = false
            _isClosed = false
            _shouldFailInitialize = false
            _shouldFailStore = false
            _shouldFailQuery = false
            _initializeCallCount = 0
            _storeEventCallCount = 0
            _getRecentEventsCallCount = 0
            _getEventsForUserCallCount = 0
            _getEventCountCallCount = 0
            _closeCallCount = 0
            _currentSessionId = UUID.v7().uuidString
        }
    }

    public func setSessionId(_ sessionId: String) {
        lock.withLock {
            _currentSessionId = sessionId
        }
    }

    public func addTestEvent(name: String, distinctId: String = "test_user", properties: [String: Any] = [:], timestamp: Date = Date()) {
        lock.withLock {
            var enrichedProps = properties
            enrichedProps["$session_id"] = _currentSessionId

            let event = try! StoredEvent(
                id: UUID.v7().uuidString,
                name: name,
                properties: enrichedProps,
                timestamp: timestamp,
                distinctId: distinctId
            )
            _storedEvents.append(event)
        }
    }
}
