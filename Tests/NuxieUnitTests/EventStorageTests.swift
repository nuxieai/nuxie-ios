import Foundation
import Quick
import Nimble
import SQLite3
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
            _ = try await internalEventStore.insert(event, deliveryState: .delivered)
        }

        func executeSQLite(_ sql: String, at path: String) throws {
            var database: OpaquePointer?
            guard sqlite3_open(path, &database) == SQLITE_OK else {
                defer { sqlite3_close(database) }
                throw NSError(domain: "EventStorageTests", code: 1)
            }
            defer { sqlite3_close(database) }
            var message: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(database, sql, nil, nil, &message) == SQLITE_OK else {
                let description = message.map { String(cString: $0) } ?? "SQLite command failed"
                sqlite3_free(message)
                throw NSError(
                    domain: "EventStorageTests",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: description]
                )
            }
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
                let properties = ["key": "value", "number": 42] as [String: Any]
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
            it("reports newly durable only for the first byte-equivalent insert") {
                let timestamp = Date(timeIntervalSince1970: 1_000)
                let original = try StoredEvent(
                    id: "stable-id",
                    name: "$app_opened",
                    properties: ["source": "app_lifecycle"],
                    timestamp: timestamp,
                    distinctId: "customer-a"
                )
                let collision = try StoredEvent(
                    id: original.id,
                    name: "$app_backgrounded",
                    properties: ["source": "app_lifecycle"],
                    timestamp: timestamp,
                    distinctId: "customer-a"
                )

                let newlyDurable = try await internalEventStore.insert(
                    original,
                    deliveryState: .pending
                )
                let replayNewlyDurable = try await internalEventStore.insert(
                    original,
                    deliveryState: .pending
                )
                let collisionNewlyDurable = try await internalEventStore.insert(
                    collision,
                    deliveryState: .pending
                )

                expect(newlyDurable) == true
                expect(replayNewlyDurable) == false
                expect(collisionNewlyDurable) == false
                let canonical = try await internalEventStore.queryEvent(id: original.id)
                expect(canonical?.name) == original.name
                expect(canonical?.properties) == original.properties
                expect(canonical?.timestamp) == original.timestamp
                expect(canonical?.distinctId) == original.distinctId
            }

            it("treats reordered JSON object keys as the same stable event") {
                let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
                let first = StoredEvent(
                    id: "canonical-json-id",
                    name: SystemEventNames.appOpened,
                    properties: Data(#"{"alpha":1,"beta":{"x":true,"y":2}}"#.utf8),
                    timestamp: timestamp,
                    distinctId: "customer-a"
                )
                let reordered = StoredEvent(
                    id: first.id,
                    name: first.name,
                    properties: Data(#"{"beta":{"y":2,"x":true},"alpha":1}"#.utf8),
                    timestamp: timestamp,
                    distinctId: first.distinctId
                )

                expect(first.isByteEquivalent(to: reordered)).to(beTrue())
                let firstInserted = try await internalEventStore.insert(
                    first,
                    deliveryState: .delivered
                )
                let reorderedInserted = try await internalEventStore.insert(
                    reordered,
                    deliveryState: .delivered
                )
                expect(firstInserted).to(beTrue())
                expect(reorderedInserted).to(beFalse())
            }

            it("retains server-origin ids beyond the ordinary pruning horizon") {
                let oldTimestamp = Date(timeIntervalSince1970: 100)
                let serverFact = try StoredEvent(
                    id: "server-fact-id",
                    name: JourneyEvents.journeyConverted,
                    properties: [StoredEvent.originProperty: StoredEventOrigin.server.rawValue],
                    timestamp: oldTimestamp,
                    distinctId: "customer-a"
                )
                let deviceEvent = try StoredEvent(
                    id: "device-event-id",
                    name: SystemEventNames.appOpened,
                    timestamp: oldTimestamp,
                    distinctId: "customer-a"
                )
                _ = try await internalEventStore.insert(
                    serverFact,
                    deliveryState: .delivered,
                    origin: .server
                )
                _ = try await internalEventStore.insert(deviceEvent, deliveryState: .delivered)
                _ = try await internalEventStore.readOrInitializeHistoryCoverage(
                    startingAt: .distantPast
                )

                let result = try await internalEventStore.pruneHistory(
                    keeping: 1,
                    olderThan: Date(timeIntervalSince1970: 1_000)
                )

                expect(result.ageDeleted) == 1
                let retainedServerFact = try await internalEventStore.queryEvent(id: serverFact.id)
                let prunedDeviceEvent = try await internalEventStore.queryEvent(id: deviceEvent.id)
                let redeliveryWasNew = try await internalEventStore.insert(
                    serverFact,
                    deliveryState: .delivered
                )
                expect(retainedServerFact).notTo(beNil())
                expect(prunedDeviceEvent).to(beNil())
                expect(redeliveryWasNew) == false
            }

            it("prunes malformed device properties and advances coverage") {
                let oldTimestamp = Date(timeIntervalSince1970: 100)
                let corrupt = try StoredEvent(
                    id: "corrupt-device-row",
                    name: "corrupt",
                    timestamp: oldTimestamp,
                    distinctId: "customer-a"
                )
                _ = try await internalEventStore.insert(corrupt, deliveryState: .delivered)
                _ = try await internalEventStore.readOrInitializeHistoryCoverage(
                    startingAt: .distantPast
                )
                let databasePath = await internalEventStore.dbPath!
                try executeSQLite(
                    "UPDATE events SET properties = X'FF' WHERE id = 'corrupt-device-row';",
                    at: databasePath
                )

                let result = try await internalEventStore.pruneHistory(
                    keeping: 10,
                    olderThan: Date(timeIntervalSince1970: 200)
                )

                expect(result.ageDeleted).to(equal(1))
                expect(result.coverageStartingAt).to(equal(Date(timeIntervalSince1970: 200)))
                let corruptRow = try await internalEventStore.queryEvent(id: corrupt.id)
                expect(corruptRow).to(beNil())
            }

            it("prunes a device event that claims server origin in its properties") {
                let spoofed = try StoredEvent(
                    id: "spoofed-server-origin",
                    name: SystemEventNames.appOpened,
                    properties: [
                        StoredEvent.originProperty: StoredEventOrigin.server.rawValue,
                    ],
                    timestamp: Date(timeIntervalSince1970: 100),
                    distinctId: "customer-a"
                )
                _ = try await internalEventStore.insert(spoofed, deliveryState: .delivered)
                _ = try await internalEventStore.readOrInitializeHistoryCoverage(
                    startingAt: .distantPast
                )

                let result = try await internalEventStore.pruneHistory(
                    keeping: 10,
                    olderThan: Date(timeIntervalSince1970: 200)
                )

                expect(result.ageDeleted).to(equal(1))
                let spoofedRow = try await internalEventStore.queryEvent(id: spoofed.id)
                expect(spoofedRow).to(beNil())
            }

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
                    _ = try await internalEventStore.insert(event, deliveryState: .delivered)
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
                        _ = try await internalEventStore.insert(event, deliveryState: .delivered)
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
                    _ = try await internalEventStore.insert(oldEvent, deliveryState: .delivered)
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
                    _ = try await internalEventStore.insert(recentEvent, deliveryState: .delivered)
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
                
                // Atomically prune events older than 1 day and advance the
                // durable completeness boundary with the deletion.
                let cutoffDate = Date(timeIntervalSinceNow: -60 * 60 * 24) // 1 day ago
                _ = try await internalEventStore.readOrInitializeHistoryCoverage(
                    startingAt: .distantPast
                )
                guard let prune = try? await internalEventStore.pruneHistory(
                    keeping: 10,
                    olderThan: cutoffDate
                ) else {
                    fail("Failed to delete old events")
                    return
                }
                
                // Should have deleted the old event
                expect(prune.ageDeleted) == 1
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

            it("does not make pending history prunable until it is acknowledged") {
                let pending = try StoredEvent(
                    id: "old-pending",
                    name: "pending",
                    timestamp: Date(timeIntervalSince1970: 100),
                    distinctId: "user"
                )
                let delivered = try StoredEvent(
                    id: "newer-delivered",
                    name: "delivered",
                    timestamp: Date(timeIntervalSince1970: 200),
                    distinctId: "user"
                )
                _ = try await internalEventStore.insert(pending, deliveryState: .pending)
                _ = try await internalEventStore.insert(delivered, deliveryState: .delivered)
                _ = try await internalEventStore.readOrInitializeHistoryCoverage(
                    startingAt: Date(timeIntervalSince1970: 50)
                )

                let beforeDelivery = try await internalEventStore.pruneHistory(
                    keeping: 10,
                    olderThan: Date(timeIntervalSince1970: 150)
                )
                expect(beforeDelivery.ageDeleted).to(equal(0))
                let pendingEventCount = try await internalEventStore.getEventCount()
                expect(pendingEventCount).to(equal(2))

                try await internalEventStore.markDelivered(ids: [pending.id])
                let afterDelivery = try await internalEventStore.pruneHistory(
                    keeping: 10,
                    olderThan: Date(timeIntervalSince1970: 150)
                )
                expect(afterDelivery.ageDeleted).to(equal(1))
                expect(afterDelivery.coverageStartingAt).to(equal(
                    Date(timeIntervalSince1970: 150)
                ))
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

            it("persists a stable local-route receipt until subscriber delivery is acknowledged") {
                let event = try StoredEvent(
                    id: "stable-route-across-relaunch",
                    name: "$purchase_completed",
                    properties: ["source": "device_journey"],
                    timestamp: Date(timeIntervalSince1970: 1_000),
                    distinctId: "customer-a"
                )
                let committed = try await internalEventStore
                    .commitStableCaptureAndStageRoute(
                        eventId: event.id,
                        event: event,
                        recordedAt: event.timestamp,
                        ownership: nil,
                        assigningCommitSequence: true,
                        admission: nil
                    )
                guard case .captured(_, isNew: true) = committed.outcome else {
                    return fail("expected a newly captured stable event")
                }
                expect(committed.localRoutePending).to(beTrue())
                let initiallyPending = try await internalEventStore.queryPendingStableRoutes(
                    distinctId: "customer-a"
                )
                expect(initiallyPending.map(\.id)).to(equal([event.id]))

                await internalEventStore.close()
                internalEventStore = SQLiteEventStore()
                try await internalEventStore.initialize(
                    path: URL(fileURLWithPath: tempDbPath)
                )

                let reopenedPending = try await internalEventStore.queryPendingStableRoutes(
                    distinctId: "customer-a"
                )
                expect(reopenedPending.map(\.id)).to(equal([event.id]))
                let replay = try await internalEventStore
                    .commitStableCaptureAndStageRoute(
                        eventId: event.id,
                        event: nil,
                        recordedAt: Date(timeIntervalSince1970: 2_000),
                        ownership: nil,
                        assigningCommitSequence: true,
                        admission: nil
                    )
                guard case .captured(let canonical, isNew: false) = replay.outcome else {
                    return fail("expected the canonical captured event on replay")
                }
                expect(canonical.id).to(equal(event.id))
                expect(replay.localRoutePending).to(beTrue())

                try await internalEventStore.markStableRouteDelivered(
                    eventId: event.id
                )
                let deliveredPending = try await internalEventStore.queryPendingStableRoutes(
                    distinctId: "customer-a"
                )
                expect(deliveredPending).to(beEmpty())
                let acknowledgedReplay = try await internalEventStore
                    .commitStableCaptureAndStageRoute(
                        eventId: event.id,
                        event: nil,
                        recordedAt: Date(timeIntervalSince1970: 3_000),
                        ownership: nil,
                        assigningCommitSequence: true,
                        admission: nil
                    )
                expect(acknowledgedReplay.localRoutePending).to(beFalse())
            }

            it("prevents stale-epoch stable capture after ownership loss across relaunch") {
                let journeyId = "journey-owned-on-another-device"
                try await internalEventStore.recordJourneyOwnershipLoss(
                    JourneyEventOwnership(journeyId: journeyId, epoch: 7),
                    recordedAt: Date(timeIntervalSince1970: 1_000)
                )

                await internalEventStore.close()
                internalEventStore = SQLiteEventStore()
                try await internalEventStore.initialize(
                    path: URL(fileURLWithPath: tempDbPath)
                )

                let staleOwnershipPersisted = try await internalEventStore
                    .hasJourneyOwnershipLoss(
                        JourneyEventOwnership(journeyId: journeyId, epoch: 7)
                    )
                let newerOwnershipPersisted = try await internalEventStore
                    .hasJourneyOwnershipLoss(
                        JourneyEventOwnership(journeyId: journeyId, epoch: 8)
                    )
                expect(staleOwnershipPersisted).to(beTrue())
                expect(newerOwnershipPersisted).to(beFalse())

                let staleEvent = try StoredEvent(
                    id: "journey-exited:stale-epoch",
                    name: JourneyEvents.journeyExited,
                    distinctId: "customer-a"
                )
                let stale = try await internalEventStore.commitStableCapture(
                    eventId: staleEvent.id,
                    event: staleEvent,
                    recordedAt: Date(timeIntervalSince1970: 2_000),
                    ownership: JourneyEventOwnership(
                        journeyId: journeyId,
                        epoch: 7
                    )
                )
                guard case .ownershipLost = stale else {
                    return fail("authoritative ownership loss must reject the stale exit")
                }
                let storedStale = try await internalEventStore.queryEvent(
                    id: staleEvent.id
                )
                let stableStale = try await internalEventStore.queryStableCapture(
                    id: staleEvent.id
                )
                expect(storedStale).to(beNil())
                expect(stableStale).to(beNil())

                let newerEvent = try StoredEvent(
                    id: "journey-exited:newer-epoch",
                    name: JourneyEvents.journeyExited,
                    distinctId: "customer-a"
                )
                let newer = try await internalEventStore.commitStableCapture(
                    eventId: newerEvent.id,
                    event: newerEvent,
                    recordedAt: Date(timeIntervalSince1970: 3_000),
                    ownership: JourneyEventOwnership(
                        journeyId: journeyId,
                        epoch: 8
                    )
                )
                guard case .captured(let canonical, isNew: true) = newer else {
                    return fail("a newly owned epoch must remain eligible")
                }
                expect(canonical.id) == newerEvent.id
            }

            it("retains unresolved ownership response sources across relaunch") {
                let sourceEventId = "ownership-response-source"
                let ownership = JourneyEventOwnership(
                    journeyId: "journey-awaiting-fence",
                    epoch: 5
                )
                try await internalEventStore.recordUnresolvedJourneyOwnershipResponse(
                    sourceEventId: sourceEventId,
                    ownership: ownership,
                    recordedAt: Date(timeIntervalSince1970: 1_000)
                )

                await internalEventStore.close()
                internalEventStore = SQLiteEventStore()
                try await internalEventStore.initialize(
                    path: URL(fileURLWithPath: tempDbPath)
                )

                let matching = try await internalEventStore
                    .hasUnresolvedJourneyOwnershipResponse(ownership)
                let sourceOwnerships = try await internalEventStore
                    .queryUnresolvedJourneyOwnershipResponse(
                        sourceEventId: sourceEventId
                    )
                let newer = try await internalEventStore
                    .hasUnresolvedJourneyOwnershipResponse(
                        JourneyEventOwnership(
                            journeyId: ownership.journeyId,
                            epoch: ownership.epoch + 1
                        )
                    )
                expect(matching).to(beTrue())
                expect(sourceOwnerships).to(contain(ownership))
                expect(newer).to(beFalse())

                let blockedEvent = try StoredEvent(
                    id: "journey-exited:unresolved-response",
                    name: JourneyEvents.journeyExited,
                    distinctId: "customer-a"
                )
                do {
                    _ = try await internalEventStore.commitStableCapture(
                        eventId: blockedEvent.id,
                        event: blockedEvent,
                        recordedAt: Date(timeIntervalSince1970: 2_000),
                        ownership: ownership
                    )
                    return fail(
                        "an unresolved response must block atomic stable capture"
                    )
                } catch {
                    // Retryable storage refusal is the expected outcome.
                }
                let blockedOutcome = try await internalEventStore
                    .queryStableCapture(id: blockedEvent.id)
                expect(blockedOutcome).to(beNil())

                try await internalEventStore.clearUnresolvedJourneyOwnershipResponse(
                    sourceEventId: sourceEventId
                )
                let cleared = try await internalEventStore
                    .hasUnresolvedJourneyOwnershipResponse(ownership)
                expect(cleared).to(beFalse())
            }

            it("rolls back every stable capture when a later batch item fails") {
                let ownership = JourneyEventOwnership(
                    journeyId: "journey-with-unresolved-ownership",
                    epoch: 4
                )
                try await internalEventStore.recordUnresolvedJourneyOwnershipResponse(
                    sourceEventId: "unresolved-source",
                    ownership: ownership,
                    recordedAt: Date(timeIntervalSince1970: 1_000)
                )
                let first = try StoredEvent(
                    id: "screen-batch:first",
                    name: "first",
                    distinctId: "customer-a"
                )
                let blocked = try StoredEvent(
                    id: "screen-batch:blocked",
                    name: "blocked",
                    distinctId: "customer-a"
                )

                await expect {
                    try await internalEventStore.commitStableCaptureBatch(
                        [
                            StableEventCaptureRecord(
                                eventId: first.id,
                                event: first,
                                recordedAt: Date(timeIntervalSince1970: 2_000),
                                ownership: nil
                            ),
                            StableEventCaptureRecord(
                                eventId: blocked.id,
                                event: blocked,
                                recordedAt: Date(timeIntervalSince1970: 2_001),
                                ownership: ownership
                            ),
                        ],
                        assigningCommitSequence: true,
                        admission: nil
                    )
                }.to(throwError())

                let firstOutcome = try await internalEventStore.queryStableCapture(
                    id: first.id
                )
                let blockedOutcome = try await internalEventStore.queryStableCapture(
                    id: blocked.id
                )
                let pending = try await internalEventStore.queryPendingDelivery(limit: 10)
                expect(firstOutcome).to(beNil())
                expect(blockedOutcome).to(beNil())
                expect(pending).to(beEmpty())
            }

            it("inserts a stable pending event exactly once") {
                let event = try StoredEvent(
                    id: "purchase-completed:transaction-1",
                    name: "$purchase_completed",
                    distinctId: "customer-a"
                )

                let inserted = try await internalEventStore.insert(event, deliveryState: .pending)
                let replayInserted = try await internalEventStore.insert(event, deliveryState: .pending)

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

                _ = try await internalEventStore.insert(pendingB, deliveryState: .pending)
                _ = try await internalEventStore.insert(delivered, deliveryState: .delivered)
                _ = try await internalEventStore.insert(pendingA, deliveryState: .pending)

                let initialCount = try await internalEventStore.getPendingDeliveryCount()
                let initialIds = try await internalEventStore.queryPendingDelivery(limit: 10).map(\.id)
                expect(initialCount) == 2
                expect(initialIds) == ["pending-a", "pending-b"]

                let insertedDuplicate = try await internalEventStore.insert(
                    pendingA,
                    deliveryState: .pending
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

        describe("durable event-history coverage") {
            it("initializes conservatively and persists the boundary across relaunch until reset") {
                let firstOpen = Date(timeIntervalSince1970: 1_000)
                let laterOpen = Date(timeIntervalSince1970: 2_000)
                let initial = try await internalEventStore.readOrInitializeHistoryCoverage(
                    startingAt: firstOpen
                )
                expect(initial).to(equal(firstOpen))

                await internalEventStore.close()
                let reopened = SQLiteEventStore()
                try await reopened.initialize(path: URL(fileURLWithPath: tempDbPath))
                let relaunched = try await reopened.readOrInitializeHistoryCoverage(
                    startingAt: laterOpen
                )
                expect(relaunched).to(equal(firstOpen))

                await reopened.reset()
                try await reopened.initialize(path: URL(fileURLWithPath: tempDbPath))
                let reset = try await reopened.readOrInitializeHistoryCoverage(
                    startingAt: laterOpen
                )
                expect(reset).to(equal(laterOpen))
                await reopened.close()
            }

            it("rejects a v1 database without coverage metadata without mutating its events") {
                let existing = try StoredEvent(
                    id: "existing-row",
                    name: "existing",
                    timestamp: Date(timeIntervalSince1970: 100),
                    distinctId: "user"
                )
                _ = try await internalEventStore.insert(existing, deliveryState: .delivered)
                let databasePath = await internalEventStore.dbPath!
                await internalEventStore.close()
                try executeSQLite("DROP TABLE event_history_metadata;", at: databasePath)

                let rejected = SQLiteEventStore()
                await expect {
                    try await rejected.initialize(path: URL(fileURLWithPath: tempDbPath))
                }.to(throwError { error in
                    guard case EventStorageError.invalidSchema = error else {
                        return fail("Expected invalidSchema, got \(error)")
                    }
                })

                var database: OpaquePointer?
                expect(sqlite3_open(databasePath, &database)).to(equal(SQLITE_OK))
                defer { sqlite3_close(database) }
                var statement: OpaquePointer?
                expect(sqlite3_prepare_v2(
                    database,
                    "SELECT COUNT(*) FROM events WHERE id = 'existing-row';",
                    -1,
                    &statement,
                    nil
                )).to(equal(SQLITE_OK))
                defer { sqlite3_finalize(statement) }
                expect(sqlite3_step(statement)).to(equal(SQLITE_ROW))
                expect(sqlite3_column_int(statement, 0)).to(equal(1))
            }

            it("advances monotonically for count and age pruning, including a later pending ack") {
                let initial = Date(timeIntervalSince1970: 100)
                _ = try await internalEventStore.readOrInitializeHistoryCoverage(startingAt: initial)
                for second in [101, 102, 103] {
                    _ = try await internalEventStore.insert(try StoredEvent(
                        id: "delivered-\(second)",
                        name: "event",
                        timestamp: Date(timeIntervalSince1970: TimeInterval(second)),
                        distinctId: "user"
                    ), deliveryState: .delivered)
                }
                let oldPending = try StoredEvent(
                    id: "old-pending",
                    name: "event",
                    timestamp: Date(timeIntervalSince1970: 90),
                    distinctId: "user"
                )
                _ = try await internalEventStore.insert(oldPending, deliveryState: .pending)

                let countPrune = try await internalEventStore.pruneHistory(
                    keeping: 3,
                    olderThan: .distantPast
                )
                expect(countPrune.countDeleted).to(equal(1))
                expect(countPrune.coverageStartingAt).to(equal(
                    Date(timeIntervalSince1970: 101.001)
                ))

                try await internalEventStore.markDelivered(ids: [oldPending.id])
                let acknowledgedPrune = try await internalEventStore.pruneHistory(
                    keeping: 2,
                    olderThan: .distantPast
                )
                expect(acknowledgedPrune.countDeleted).to(equal(1))
                expect(acknowledgedPrune.coverageStartingAt).to(equal(
                    countPrune.coverageStartingAt
                ))

                _ = try await internalEventStore.insert(try StoredEvent(
                    id: "aged",
                    name: "event",
                    timestamp: Date(timeIntervalSince1970: 150),
                    distinctId: "user"
                ), deliveryState: .delivered)
                let agePrune = try await internalEventStore.pruneHistory(
                    keeping: 10,
                    olderThan: Date(timeIntervalSince1970: 200)
                )
                expect(agePrune.ageDeleted).to(beGreaterThan(0))
                expect(agePrune.coverageStartingAt).to(equal(
                    Date(timeIntervalSince1970: 200)
                ))

                let clockRollback = try await internalEventStore.pruneHistory(
                    keeping: 10,
                    olderThan: Date(timeIntervalSince1970: 120)
                )
                expect(clockRollback.coverageStartingAt).to(equal(
                    agePrune.coverageStartingAt
                ))
            }

            it("rolls event deletion back when the atomic coverage update fails") {
                let initial = Date(timeIntervalSince1970: 10)
                _ = try await internalEventStore.readOrInitializeHistoryCoverage(startingAt: initial)
                _ = try await internalEventStore.insert(try StoredEvent(
                    id: "must-survive",
                    name: "event",
                    timestamp: Date(timeIntervalSince1970: 50),
                    distinctId: "user"
                ), deliveryState: .delivered)
                let databasePath = await internalEventStore.dbPath!
                try executeSQLite(
                    """
                    CREATE TRIGGER fail_history_coverage_update
                    BEFORE UPDATE ON event_history_metadata
                    BEGIN
                      SELECT RAISE(ABORT, 'injected coverage failure');
                    END;
                    """,
                    at: databasePath
                )

                await expect {
                    try await internalEventStore.pruneHistory(
                        keeping: 10,
                        olderThan: Date(timeIntervalSince1970: 75)
                    )
                }.to(throwError())
                let retainedEventCount = try await internalEventStore.getEventCount()
                let retainedCoverage = try await internalEventStore.historyCoverageStartingAt()
                expect(retainedEventCount).to(equal(1))
                expect(retainedCoverage).to(equal(initial))
            }
        }
        
        describe("history persistence") {
            
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
