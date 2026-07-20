import Foundation
@testable import Nuxie

/// Mock implementation of EventStoreProtocol for testing
public class MockEventStore: EventStoreProtocol {
    
    // Storage
    public var storedEvents: [StoredEvent] = []
    public var isInitialized = false
    public var isClosed = false
    
    // Error simulation
    public var shouldFailInitialize = false
    public var shouldFailStore = false
    public var shouldFailQuery = false
    public var shouldFailCleanup = false
    
    // Call tracking
    public var initializeCallCount = 0
    public var storeEventCallCount = 0
    public var getRecentEventsCallCount = 0
    public var getEventsForUserCallCount = 0
    public var getEventCountCallCount = 0
    public var forceCleanupCallCount = 0
    public var closeCallCount = 0
    public var reassignEventsCallCount = 0
    
    // Session tracking
    private var currentSessionId = UUID.v7().uuidString
    
    public init() {}
    
    // MARK: - EventStoreProtocol Implementation
    
    public func initialize(path: URL?) async throws {
        initializeCallCount += 1
        
        if shouldFailInitialize {
            throw NSError(domain: "MockEventStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Mock initialization error"])
        }
        
        isInitialized = true
    }
    
    public func reset() async {
        storedEvents.removeAll()
        isInitialized = false
        isClosed = false
    }
        
    public func storeEvent(name: String, properties: [String: Any], distinctId: String) async throws {
        storeEventCallCount += 1
        
        if shouldFailStore {
            throw NSError(domain: "MockEventStore", code: 2, userInfo: [NSLocalizedDescriptionKey: "Mock store error"])
        }
        
        var enrichedProps = properties
        enrichedProps["$session_id"] = currentSessionId
        
        let event = try StoredEvent(
            id: UUID.v7().uuidString,
            name: name,
            properties: enrichedProps,
            timestamp: Date(),
            distinctId: distinctId
        )
        
        storedEvents.append(event)
    }

    public func storePreparedEvent(_ event: StoredEvent) async throws {
        storeEventCallCount += 1

        if shouldFailStore {
            throw NSError(domain: "MockEventStore", code: 2, userInfo: [NSLocalizedDescriptionKey: "Mock store error"])
        }

        storedEvents.append(event)
    }
    
    public func getRecentEvents(limit: Int) async throws -> [StoredEvent] {
        getRecentEventsCallCount += 1
        
        if shouldFailQuery {
            throw NSError(domain: "MockEventStore", code: 3, userInfo: [NSLocalizedDescriptionKey: "Mock query error"])
        }
        
        return Array(storedEvents.suffix(limit))
    }
    
    public func getEventsForUser(_ distinctId: String, limit: Int) async throws -> [StoredEvent] {
        getEventsForUserCallCount += 1
        
        if shouldFailQuery {
            throw NSError(domain: "MockEventStore", code: 3, userInfo: [NSLocalizedDescriptionKey: "Mock query error"])
        }
        
        let userEvents = storedEvents.filter { $0.distinctId == distinctId }
        return Array(userEvents.suffix(limit))
    }
    
    public func getEvents(for sessionId: String) async throws -> [StoredEvent] {
        if shouldFailQuery {
            throw NSError(domain: "MockEventStore", code: 3, userInfo: [NSLocalizedDescriptionKey: "Mock query error"])
        }
        
        return storedEvents.filter { $0.sessionId == sessionId }
    }
    
    public func getEventCount() async throws -> Int {
        getEventCountCallCount += 1
        
        if shouldFailQuery {
            throw NSError(domain: "MockEventStore", code: 3, userInfo: [NSLocalizedDescriptionKey: "Mock query error"])
        }
        
        return storedEvents.count
    }
    
    @discardableResult
    public func forceCleanup() async throws -> Int {
        forceCleanupCallCount += 1
        
        if shouldFailCleanup {
            throw NSError(domain: "MockEventStore", code: 4, userInfo: [NSLocalizedDescriptionKey: "Mock cleanup error"])
        }
        
        let countBefore = storedEvents.count
        // Remove events older than 30 days (mock behavior)
        let cutoffDate = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        storedEvents.removeAll { $0.timestamp < cutoffDate }
        
        return countBefore - storedEvents.count
    }
    
    public func close() async {
        closeCallCount += 1
        isClosed = true
    }
    
    // MARK: - Event Query Methods
    
    public func hasEvent(name: String, distinctId: String, since: Date?) async throws -> Bool {
        if shouldFailQuery {
            throw NSError(domain: "MockEventStore", code: 3, userInfo: [NSLocalizedDescriptionKey: "Mock query error"])
        }
        
        let userEvents = storedEvents.filter { $0.distinctId == distinctId && $0.name == name }
        
        if let since = since {
            return userEvents.contains { $0.timestamp >= since }
        }
        
        return !userEvents.isEmpty
    }
    
    public func countEvents(name: String, distinctId: String, since: Date?, until: Date?) async throws -> Int {
        if shouldFailQuery {
            throw NSError(domain: "MockEventStore", code: 3, userInfo: [NSLocalizedDescriptionKey: "Mock query error"])
        }
        
        var userEvents = storedEvents.filter { $0.distinctId == distinctId && $0.name == name }
        
        if let since = since {
            userEvents = userEvents.filter { $0.timestamp >= since }
        }
        if let until = until {
            userEvents = userEvents.filter { $0.timestamp <= until }
        }
        
        return userEvents.count
    }
    
    public func getLastEventTime(name: String, distinctId: String, since: Date?, until: Date?) async throws -> Date? {
        if shouldFailQuery {
            throw NSError(domain: "MockEventStore", code: 3, userInfo: [NSLocalizedDescriptionKey: "Mock query error"])
        }
        
        var userEvents = storedEvents.filter { $0.distinctId == distinctId && $0.name == name }
        
        if let since = since {
            userEvents = userEvents.filter { $0.timestamp >= since }
        }
        if let until = until {
            userEvents = userEvents.filter { $0.timestamp <= until }
        }
        
        // Return the most recent event within the bounds
        return userEvents.max(by: { $0.timestamp < $1.timestamp })?.timestamp
    }
    
    // MARK: - Durable delivery

    public private(set) var eventsStoredForDelivery: [NuxieEvent] = []
    public private(set) var deliveredIds: [String] = []
    public var pendingDeliveryToLoad: [NuxieEvent] = []

    public func storeEventForDelivery(_ event: NuxieEvent) async throws {
        eventsStoredForDelivery.append(event)
        // Mirror the real store: the canonical record joins local history too.
        let stored = try StoredEvent(
            id: event.id,
            name: event.name,
            properties: event.properties,
            timestamp: event.timestamp,
            distinctId: event.distinctId
        )
        try await storePreparedEvent(stored)
    }

    public func loadPendingDelivery(limit: Int) async -> [NuxieEvent] {
        Array(pendingDeliveryToLoad.prefix(limit))
    }

    public func markDelivered(ids: [String]) async {
        deliveredIds.append(contentsOf: ids)
    }

    public func reassignEvents(from fromUserId: String, to toUserId: String) async throws -> Int {
        reassignEventsCallCount += 1
        
        if shouldFailQuery {
            throw NSError(domain: "MockEventStore", code: 5, userInfo: [NSLocalizedDescriptionKey: "Mock reassign error"])
        }
        
        var reassignedCount = 0
        for i in 0..<storedEvents.count {
            if storedEvents[i].distinctId == fromUserId {
                // Create a new event with updated distinctId
                let oldEvent = storedEvents[i]
                storedEvents[i] = StoredEvent(
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
    
    // MARK: - Test Helpers
    
    public func resetMock() {
        storedEvents.removeAll()
        isInitialized = false
        isClosed = false
        shouldFailInitialize = false
        shouldFailStore = false
        shouldFailQuery = false
        shouldFailCleanup = false
        initializeCallCount = 0
        storeEventCallCount = 0
        getRecentEventsCallCount = 0
        getEventsForUserCallCount = 0
        getEventCountCallCount = 0
        forceCleanupCallCount = 0
        closeCallCount = 0
        currentSessionId = UUID.v7().uuidString
    }
    
    public func setSessionId(_ sessionId: String) {
        currentSessionId = sessionId
    }
    
    public func addTestEvent(name: String, distinctId: String = "test_user", properties: [String: Any] = [:], timestamp: Date = Date()) {
        var enrichedProps = properties
        enrichedProps["$session_id"] = currentSessionId
        
        let event = try! StoredEvent(
            id: UUID.v7().uuidString,
            name: name,
            properties: enrichedProps,
            timestamp: timestamp,
            distinctId: distinctId
        )
        storedEvents.append(event)
    }
}
