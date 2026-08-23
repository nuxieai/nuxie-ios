import Foundation
import Quick
import Nimble
@_spi(Testing) @testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

final class EventStorageTests: AsyncSpec {
    
    override class func spec() {
        var internalEventStore: SQLiteEventStore!
        var tempDbPath: String!

        // Wrapper-equivalent helper: store a history event through the slim
        // persistence surface (enrichment now lives in EventLog).
        func storeHistory(
            name: String, properties: [String: Any] = [:], distinctId: String
        ) async throws {
            let event = try StoredEvent(
                name: name,
                properties: properties,
                distinctId: distinctId
            )
            try await internalEventStore.insertHistory(event)
        }
        
        beforeEach {
            // Create temporary database path for testing
            let tempDir = NSTemporaryDirectory()
            tempDbPath = "\(tempDir)/test_events_\(UUID.v7().uuidString).db"
            
            // Clean up any existing database first
            if FileManager.default.fileExists(atPath: tempDbPath) {
                try? FileManager.default.removeItem(atPath: tempDbPath)
            }
            
            // Initialize with test database path
            internalEventStore = SQLiteEventStore()
            
            // Initialize the store
            do {
                try await internalEventStore.initialize(path: URL(fileURLWithPath: tempDbPath))
            } catch {
                fail("Failed to initialize stores: \(error)")
            }
        }
        
        afterEach {
            // Clean up test database
            await internalEventStore?.close()
            
            if let path = tempDbPath, FileManager.default.fileExists(atPath: path) {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
        
        describe("StoredEvent") {
            it("should create event with valid properties") {
                let properties = ["key": "value", "number": 42, "$session_id": "test-session"] as [String: Any]
                guard let event = try? StoredEvent(
                    name: "test_event",
                    properties: properties,
                    distinctId: "test_user"
                ) else {
                    fail("Failed to create StoredEvent")
                    return
                }
                
                expect(event.name) == "test_event"
                expect(event.distinctId) == "test_user"
                expect(event.sessionId) == "test-session"
                
                // Test property serialization/deserialization
                let retrievedProperties = try? event.getProperties()
                expect(retrievedProperties?["key"]?.value as? String) == "value"
                expect(retrievedProperties?["number"]?.value as? Int) == 42
            }
            
            it("should handle empty properties correctly") {
                guard let event = try? StoredEvent(
                    name: "test_event",
                    properties: [:],
                    distinctId: "test_user"
                ) else {
                    fail("Failed to create StoredEvent")
                    return
                }
                
                expect(event.name) == "test_event"
                expect(event.distinctId) == "test_user"
                let props = try? event.getProperties()
                expect(props?.isEmpty) == true
            }
        }
        
        describe("history persistence") {
            it("should insert and query events correctly") {
                let properties = ["feature": "premium", "value": 100] as [String: Any]
                guard let event = try? StoredEvent(
                    id: "test_event_1",
                    name: "feature_accessed",
                    properties: properties,
                    distinctId: "user123"
                ) else {
                    fail("Failed to create StoredEvent")
                    return
                }
                
                // Insert event
                do {
                    try await internalEventStore.insertEvent(event)
                } catch {
                    fail("Failed to insert event: \(error)")
                }
                
                // Verify event count
                do {
                    let count = try await internalEventStore.getEventCount()
                    expect(count) == 1
                } catch {
                    fail("Failed to get event count: \(error)")
                }
                
                // Query recent events
                do {
                    let events = try await internalEventStore.queryRecentEvents(limit: 10)
                    expect(events.count) == 1
                    
                    let retrievedEvent = events[0]
                    expect(retrievedEvent.name) == "feature_accessed"
                    expect(retrievedEvent.distinctId) == "user123"
                    let retrievedProps = try? retrievedEvent.getProperties()
                    expect(retrievedProps?["feature"]?.value as? String) == "premium"
                    expect(retrievedProps?["value"]?.value as? Int) == 100
                } catch {
                    fail("Failed to get recent events: \(error)")
                }
            }
            
            it("should handle multiple events with correct ordering") {
                // Insert multiple events
                for i in 1...5 {
                    guard let event = try? StoredEvent(
                        id: "test_event_multi_\(i)",
                        name: "event_\(i)",
                        properties: ["index": i],
                        distinctId: "user123"
                    ) else {
                        fail("Failed to create StoredEvent for index \(i)")
                        return
                    }
                    do {
                        try await internalEventStore.insertEvent(event)
                    } catch {
                        fail("Failed to insert event: \(error)")
                    }
                }
                
                // Verify count
                do {
                    let count = try await internalEventStore.getEventCount()
                    expect(count) == 5
                } catch {
                    fail("Failed to get event count: \(error)")
                }
                
                // Query with limit
                do {
                    let events = try await internalEventStore.queryRecentEvents(limit: 3)
                    expect(events.count) == 3
                    
                    // Events should be ordered by timestamp (most recent first)
                    expect(events[0].name) == "event_5"
                    expect(events[1].name) == "event_4"
                    expect(events[2].name) == "event_3"
                } catch {
                    fail("Failed to get recent events: \(error)")
                }
            }
            
            it("should cleanup old events correctly") {
                // Insert an old event
                let oldDate = Date(timeIntervalSinceNow: -60 * 60 * 24 * 2) // 2 days ago
                guard let oldEvent = try? StoredEvent(
                    id: "test_event_old",
                    name: "old_event",
                    properties: [:],
                    timestamp: oldDate,
                    distinctId: "user123"
                ) else {
                    fail("Failed to create old StoredEvent")
                    return
                }
                do {
                    try await internalEventStore.insertEvent(oldEvent)
                } catch {
                    fail("Failed to insert old event: \(error)")
                }
                
                // Insert a recent event
                guard let recentEvent = try? StoredEvent(
                    id: "test_event_recent",
                    name: "recent_event",
                    properties: [:],
                    distinctId: "user123"
                ) else {
                    fail("Failed to create recent StoredEvent")
                    return
                }
                do {
                    try await internalEventStore.insertEvent(recentEvent)
                } catch {
                    fail("Failed to insert recent event: \(error)")
                }
                
                // Verify both events are there
                do {
                    let count = try await internalEventStore.getEventCount()
                    expect(count) == 2
                } catch {
                    fail("Failed to get event count: \(error)")
                }
                
                // Delete events older than 1 day
                let cutoffDate = Date(timeIntervalSinceNow: -60 * 60 * 24) // 1 day ago
                guard let deletedCount = try? await internalEventStore.deleteEventsOlderThan(cutoffDate) else {
                    fail("Failed to delete old events")
                    return
                }
                
                // Should have deleted the old event
                expect(deletedCount) == 1
                do {
                    let count = try await internalEventStore.getEventCount()
                    expect(count) == 1
                } catch {
                    fail("Failed to get event count: \(error)")
                }
                
                // Remaining event should be the recent one
                do {
                    let remainingEvents = try await internalEventStore.queryRecentEvents(limit: 10)
                    expect(remainingEvents.count) == 1
                    expect(remainingEvents[0].name) == "recent_event"
                } catch {
                    fail("Failed to get remaining events: \(error)")
                }
            }
        }

        describe("durable delivery") {
            it("accepts a pending query limit wider than Int32") {
                let pending = try await internalEventStore.queryPendingDelivery(
                    limit: Int(Int32.max) + 1
                )
                expect(pending).to(beEmpty())
            }

            it("persists a terminal stable drop across replay and store relaunch") {
                let eventId = "purchase-completed:terminal-drop"
                let dropped = try await internalEventStore.commitStableCapture(
                    eventId: eventId,
                    event: nil,
                    recordedAt: Date(timeIntervalSince1970: 1_000)
                )
                guard case .dropped = dropped else {
                    return fail("expected the first stable outcome to be dropped")
                }

                let replacement = try StoredEvent(
                    id: eventId,
                    name: "$purchase_completed",
                    distinctId: "customer-a"
                )
                let replay = try await internalEventStore.commitStableCapture(
                    eventId: eventId,
                    event: replacement,
                    recordedAt: Date(timeIntervalSince1970: 2_000)
                )
                guard case .dropped = replay else {
                    return fail("a later policy must not replace a stable drop")
                }
                let storedEvent = try await internalEventStore.queryEvent(id: eventId)
                let pending = try await internalEventStore.queryPendingDelivery(limit: 10)
                expect(storedEvent).to(beNil())
                expect(pending).to(beEmpty())

                await internalEventStore.close()
                let reopened = SQLiteEventStore()
                try await reopened.initialize(path: URL(fileURLWithPath: tempDbPath))
                let relaunched = try await reopened.queryStableCapture(id: eventId)
                guard case .dropped? = relaunched else {
                    await reopened.close()
                    return fail("stable drop must survive a new store instance")
                }
                let pruned = try await reopened.deleteStableDropsOlderThan(
                    Date(timeIntervalSince1970: 1_001)
                )
                let prunedOutcome = try await reopened.queryStableCapture(id: eventId)
                expect(pruned) == 1
                expect(prunedOutcome).to(beNil())
                await reopened.close()
            }

            it("inserts a stable pending event exactly once") {
                let event = try StoredEvent(
                    id: "purchase-completed:transaction-1",
                    name: "$purchase_completed",
                    distinctId: "customer-a"
                )

                let inserted = try await internalEventStore
                    .insertPendingIfAbsent(event)
                let replayInserted = try await internalEventStore
                    .insertPendingIfAbsent(event)

                expect(inserted) == true
                expect(replayInserted) == false
                let canonical = try await internalEventStore.queryEvent(id: event.id)
                expect(canonical?.id) == event.id
                expect(canonical?.name) == event.name
                expect(canonical?.distinctId) == event.distinctId
                let pending = try await internalEventStore
                    .queryPendingDelivery(limit: 10)
                expect(pending.map(\.id)) == [event.id]
            }

            it("counts only pending rows and queries them in stable oldest-first order") {
                let timestamp = Date(timeIntervalSince1970: 1_000)
                let pendingB = try StoredEvent(
                    id: "pending-b",
                    name: "second",
                    timestamp: timestamp,
                    distinctId: "user123"
                )
                let pendingA = try StoredEvent(
                    id: "pending-a",
                    name: "first",
                    timestamp: timestamp,
                    distinctId: "user123"
                )
                let delivered = try StoredEvent(
                    id: "delivered",
                    name: "history-only",
                    timestamp: timestamp.addingTimeInterval(-1),
                    distinctId: "user123"
                )

                try await internalEventStore.insertPending(pendingB)
                try await internalEventStore.insertHistory(delivered)
                try await internalEventStore.insertPending(pendingA)

                let initialCount = try await internalEventStore.getPendingDeliveryCount()
                let initialIds = try await internalEventStore.queryPendingDelivery(limit: 10).map(\.id)
                expect(initialCount) == 2
                expect(initialIds) == ["pending-a", "pending-b"]

                let insertedDuplicate = try await internalEventStore.insertPendingIfAbsent(
                    pendingA
                )
                let countAfterDuplicate = try await internalEventStore.getPendingDeliveryCount()
                expect(insertedDuplicate) == false
                expect(countAfterDuplicate) == 2

                try await internalEventStore.markDelivered(ids: ["pending-a"])

                let remainingCount = try await internalEventStore.getPendingDeliveryCount()
                let remainingIds = try await internalEventStore.queryPendingDelivery(limit: 10).map(\.id)
                expect(remainingCount) == 1
                expect(remainingIds) == ["pending-b"]
            }
        }
        
        describe("history persistence") {
            // Session management tests moved to SessionServiceTests.swift
            
            it("should filter events by user correctly") {
                // Store events for different users
                do {
                    try await storeHistory(name: "user_event1", distinctId: "user1")
                    try await storeHistory(name: "user_event2", distinctId: "user2")
                    try await storeHistory(name: "user_event3", distinctId: "user1")
                } catch {
                    fail("Failed to store user events: \(error)")
                }
                
                // Get events for user1
                do {
                    let user1Events = try await internalEventStore.queryEventsForUser("user1", limit: 10)
                    expect(user1Events.count) == 2
                    expect(user1Events.allSatisfy { $0.distinctId == "user1" }) == true
                } catch {
                    fail("Failed to get user1 events: \(error)")
                }
                
                // Get events for user2
                do {
                    let user2Events = try await internalEventStore.queryEventsForUser("user2", limit: 10)
                    expect(user2Events.count) == 1
                    expect(user2Events[0].distinctId) == "user2"
                } catch {
                    fail("Failed to get user2 events: \(error)")
                }
            }
            
        }
    }
}
