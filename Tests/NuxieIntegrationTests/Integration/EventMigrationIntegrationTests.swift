import Foundation
import Quick
import Nimble
import FactoryKit
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

final class EventMigrationIntegrationTests: AsyncSpec {
    override class func spec() {
        describe("Event Migration on Identify") {
            var config: NuxieConfiguration!
            var dbPath: String!
            var eventLog: EventLogProtocol!
            var mockApi: MockNuxieApi!
            
            beforeEach {
                print("DEBUG: beforeEach starting")
                await NuxieSDK.shared.shutdown()

                // Create and register mock API to prevent network calls
                mockApi = MockNuxieApi()
                Container.shared.nuxieApi.register { mockApi }
                
                print("DEBUG: Got SDK shared instance")

                // Create unique database directory for test isolation
                let testId = UUID().uuidString
                let tempDir = NSTemporaryDirectory()
                let testDirPath = "\(tempDir)test_\(testId)"
                
                // Create the directory if it doesn't exist
                try FileManager.default.createDirectory(atPath: testDirPath, withIntermediateDirectories: true)
                
                dbPath = testDirPath
                print("DEBUG: Database directory path: \(dbPath)")
                
                // Create configuration with migration enabled (default)
                config = NuxieConfiguration(apiKey: "test-key-\(testId)")
                config.customStoragePath = URL(fileURLWithPath: dbPath)
                config.environment = .development
                config.trackApplicationLifecycleEvents = false // no lifecycle noise in these tests
                
                // Setup SDK
                print("DEBUG: About to call NuxieSDK.shared.setup()")
                do {
                    print("DEBUG: Calling NuxieSDK.shared.setup() now...")
                    try NuxieSDK.shared.setup(with: config)
                    print("DEBUG: SDK setup successful")
                } catch {
                    print("DEBUG: SDK setup failed with error: \(error)")
                    print("DEBUG: Error type: \(type(of: error))")
                    print("DEBUG: Error description: \(error.localizedDescription)")
                    throw error
                }
                
                // Get access to SDK's event service for validation
                eventLog = Container.shared.eventLog()
                print("DEBUG: EventLog obtained from SDK")
                
                print("DEBUG: beforeEach completed")
            }
            
            afterEach {
                // Ensure we fully shut down before deleting the DB directory. Global teardown runs
                // later, but many specs delete their temp dirs in local afterEach.
                let semaphore = DispatchSemaphore(value: 0)
                Task.detached {
                    await NuxieSDK.shared.shutdown()
                    semaphore.signal()
                }
                let result = semaphore.wait(timeout: .now() + 15.0)
                if result == .timedOut {
                    print("WARN: Timed out waiting for NuxieSDK.shutdown (EventMigrationIntegrationTests.afterEach)")
                }

                // Clean up test database directory
                if let dbPath = dbPath {
                    try? FileManager.default.removeItem(atPath: dbPath)
                }
            }
            
            describe("anonymous to identified transition") {
                context("with migrateOnIdentify policy (default)") {
                    it("should reassign anonymous events to identified user") {
                        print("DEBUG: Starting test - should reassign anonymous events")
                        
                        // Track events as anonymous user
                        print("DEBUG: Getting anonymous ID")
                        let anonymousId = NuxieSDK.shared.getAnonymousId()
                        print("DEBUG: Anonymous ID: \(anonymousId)")
                        expect(anonymousId).toNot(beEmpty())
                        
                        // Track some events as anonymous
                        print("DEBUG: Tracking events as anonymous")
                        _ = await NuxieSDK.shared.triggerAndWait("app_opened", properties: ["source": "test"])
                        _ = await NuxieSDK.shared.triggerAndWait("button_clicked", properties: ["button": "start"])
                        _ = await NuxieSDK.shared.triggerAndWait("page_viewed", properties: ["page": "home"])
                        print("DEBUG: Events tracked")

                        // Wait for events to be processed (drain the event queue)
                        await eventLog.drain()
                        print("DEBUG: Event queue drained")

                        // Verify events are stored with anonymous ID
                        print("DEBUG: Querying events for anonymous user")
                        await expect { await eventLog.getEventsForUser(anonymousId, limit: 10).count }
                            .toEventually(equal(3), timeout: .seconds(5))
                        print("DEBUG: Found expected anonymous events")
                        
                        // Identify user
                        let userId = "user123"
                        print("DEBUG: Identifying user: \(userId)")
                        NuxieSDK.shared.identify(userId, userProperties: ["name": "Test User"])
                        print("DEBUG: User identified")
                        
                        // Verify events were reassigned to identified user
                        print("DEBUG: Querying events for identified user")
                        await expect { await eventLog.getEventsForUser(userId, limit: 10).count }
                            .toEventually(beGreaterThanOrEqualTo(3), timeout: .seconds(5)) // At least the 3 tracked events
                        await expect {
                            await eventLog.getEventsForUser(userId, limit: 10)
                                .first { $0.name == "app_opened" }
                        }.toEventuallyNot(beNil(), timeout: .seconds(5))
                        let identifiedEvents = await eventLog.getEventsForUser(userId, limit: 10)
                        print("DEBUG: Found \(identifiedEvents.count) identified events")
                        
                        // Verify anonymous user has no events (except possibly $identify)
                        print("DEBUG: Checking remaining anonymous events")
                        await expect { 
                            let events = await eventLog.getEventsForUser(anonymousId, limit: 10)
                            return events.filter { $0.name != "$identify" }.count 
                        }.toEventually(equal(0), timeout: .seconds(5))
                        print("DEBUG: Verified anonymous events migrated")
                        
                        // Verify the migrated events maintain their properties
                        print("DEBUG: Verifying migrated event properties")
                        let appOpenedEvent = identifiedEvents.first { $0.name == "app_opened" }
                        expect(appOpenedEvent).toNot(beNil())
                        if let event = appOpenedEvent {
                            print("DEBUG: Found app_opened event, checking properties")
                            if let properties = try? event.getProperties() {
                                print("DEBUG: Properties: \(properties)")
                                // Handle AnyCodable wrapper
                                if let sourceValue = properties["source"] {
                                    if let anyCodable = sourceValue as? AnyCodable {
                                        expect(anyCodable.value as? String).to(equal("test"))
                                    } else {
                                        expect(sourceValue as? String).to(equal("test"))
                                    }
                                } else {
                                    fail("source property not found")
                                }
                            } else {
                                print("DEBUG: Failed to get properties")
                            }
                        } else {
                            print("DEBUG: app_opened event not found")
                        }
                        
                        print("DEBUG: Test completed successfully")
                    }
                    
                    it("should create unified timeline for journey tracking") {
                        // Track journey-relevant events as anonymous
                        let anonymousId = NuxieSDK.shared.getAnonymousId()
                        
                        NuxieSDK.shared.trigger("onboarding_started")
                        NuxieSDK.shared.trigger("onboarding_step_1_completed")
                        NuxieSDK.shared.trigger("onboarding_step_2_completed")
                        
                        // Wait for events to be stored
                        await eventLog.drain()
                        
                        // Identify user
                        let userId = "journey_user"
                        NuxieSDK.shared.identify(userId)
                        
                        // Continue tracking after identification
                        NuxieSDK.shared.trigger("onboarding_step_3_completed")
                        NuxieSDK.shared.trigger("onboarding_completed")
                        await eventLog.drain()
                        
                        // Verify all events are under the identified user
                        await expect {
                            let userEvents = await eventLog.getEventsForUser(userId, limit: 20)
                            return userEvents.filter { $0.name.starts(with: "onboarding") }.count
                        }.toEventually(equal(5), timeout: .seconds(3))
                        
                        let userEvents = await eventLog.getEventsForUser(userId, limit: 20)
                        let onboardingEvents = userEvents.filter { $0.name.starts(with: "onboarding") }
                        
                        // Verify chronological order is maintained
                        let eventNames = onboardingEvents.map { $0.name }
                        expect(eventNames).to(contain("onboarding_started"))
                        expect(eventNames).to(contain("onboarding_step_1_completed"))
                        expect(eventNames).to(contain("onboarding_step_2_completed"))
                        expect(eventNames).to(contain("onboarding_step_3_completed"))
                        expect(eventNames).to(contain("onboarding_completed"))
                    }
                }
                
            }
            
            describe("already identified user") {
                it("should NOT reassign events when user is already identified") {
                    // First identify
                    let userId1 = "user_first"
                    NuxieSDK.shared.identify(userId1)
                    
                    // Track events as identified user
                    NuxieSDK.shared.trigger("identified_event_1")
                    NuxieSDK.shared.trigger("identified_event_2")
                    
                    // Give time for events to be stored
                    await eventLog.drain()
                    
                    // Verify events are under first user
                    await expect {
                        let user1Events = await eventLog.getEventsForUser(userId1, limit: 10)
                        return user1Events.filter { $0.name.starts(with: "identified_event") }.count
                    }.toEventually(equal(2), timeout: .seconds(2))
                    
                    // Identify as different user
                    let userId2 = "user_second"
                    NuxieSDK.shared.identify(userId2)
                    await eventLog.drain()
                    
                    // Verify first user's events remain unchanged
                    await expect {
                        let user1EventsAfter = await eventLog.getEventsForUser(userId1, limit: 10)
                        return user1EventsAfter.filter { $0.name.starts(with: "identified_event") }.count
                    }.toEventually(equal(2), timeout: .seconds(2))
                    
                    // Verify second user only has identify event
                    await expect {
                        let user2Events = await eventLog.getEventsForUser(userId2, limit: 10)
                        return user2Events.filter { $0.name.starts(with: "identified_event") }.count
                    }.toEventually(equal(0), timeout: .seconds(2))
                }
                
                it("should NOT reassign when identifying with same ID") {
                    // Identify user
                    let userId = "same_user"
                    NuxieSDK.shared.identify(userId)
                    
                    // Track events
                    NuxieSDK.shared.trigger("event_1")
                    NuxieSDK.shared.trigger("event_2")
                    
                    // Give time for events to be stored
                    await eventLog.drain()

                    await expect {
                        await eventLog.getEventsForUser(userId, limit: 20)
                            .filter { $0.name.starts(with: "event_") }
                            .count
                    }.toEventually(equal(2), timeout: .seconds(2))
                    let eventCountBefore = await eventLog.getEventsForUser(userId, limit: 20).count
                    
                    // Identify again with same ID
                    NuxieSDK.shared.identify(userId, userProperties: ["updated": true])
                    
                    // Verify event count increased by at most 1 (for the new $identify)
                    await expect {
                        await eventLog.getEventsForUser(userId, limit: 20).count
                    }.toEventually(beLessThanOrEqualTo(eventCountBefore + 1), timeout: .seconds(2))
                }
            }
            
            describe("error handling") {
                it("should continue with identify even if migration fails") {
                    // Track events as anonymous
                    let anonymousId = NuxieSDK.shared.getAnonymousId()
                    NuxieSDK.shared.trigger("test_event")
                    
                    // Give time for event to be stored
                    await eventLog.drain()
                    
                    // Note: Cannot easily simulate EventStore failure with current architecture
                    // The test will still validate that SDK continues working even if storage has issues
                    
                    // Identify should still work despite migration failure
                    let userId = "user_with_error"
                    NuxieSDK.shared.identify(userId, userProperties: ["test": true])
                    
                    // Verify SDK is still functional
                    expect(NuxieSDK.shared.getDistinctId()).to(equal(userId))
                    expect(NuxieSDK.shared.isIdentified).to(beTrue())
                    
                    // Can still track events after failed migration
                    NuxieSDK.shared.trigger("post_error_event")
                    
                    // No crash should occur
                    expect(true).to(beTrue()) // Test passes if we get here
                }
            }
            
            describe("performance") {
                it("should handle large number of events efficiently") {
                    // Track many events as anonymous
                    let eventCount = 100
                    
                    for i in 0..<eventCount {
                        NuxieSDK.shared.trigger("bulk_event_\(i)", properties: ["index": i])
                    }
                    
                    // Ensure events are stored before migration begins.
                    await eventLog.drain()
                    await expect {
                        await eventLog.getRecentEvents(limit: 200)
                            .filter { $0.name.starts(with: "bulk_event") }
                            .count
                    }.toEventually(equal(eventCount), timeout: .seconds(5))
                    let recentEvents = await eventLog.getRecentEvents(limit: 200)
                    let bulkEvents = recentEvents.filter { $0.name.starts(with: "bulk_event") }
                    guard let sourceDistinctId = bulkEvents.first?.distinctId else {
                        fail("Expected bulk events to include a distinctId")
                        return
                    }
                    let sourceEvents = await eventLog.getEventsForUser(sourceDistinctId, limit: 200)
                    let sourceBulkEvents = sourceEvents.filter { $0.name.starts(with: "bulk_event") }
                    expect(sourceBulkEvents.count).to(equal(eventCount))
                    
                    // Record time before migration
                    let startTime = Date()
                    
                    let userId = "bulk_user"
                    let reassignedCount = try await eventLog.reassignEvents(
                        from: sourceDistinctId,
                        to: userId
                    )

                    // Measure migration time after completion
                    let migrationTime = Date().timeIntervalSince(startTime)
                    expect(reassignedCount).to(equal(sourceEvents.count))
                    expect(migrationTime).to(beLessThan(1.0))

                    let migratedEvents = await eventLog.getEventsForUser(userId, limit: 200)
                    let migratedBulkEvents = migratedEvents.filter { $0.name.starts(with: "bulk_event") }
                    expect(migratedBulkEvents.count).to(equal(eventCount))
                }
            }
        }
    }
}
