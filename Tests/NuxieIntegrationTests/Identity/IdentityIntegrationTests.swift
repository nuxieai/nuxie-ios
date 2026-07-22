import Foundation
import Quick
import Nimble
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

/// Comprehensive integration tests for the identity system
/// Tests the full flow of identify(), reset(), and identity state management across services
final class IdentityIntegrationTests: AsyncSpec {
    override class func spec() {
        describe("Identity Integration") {
            var harness: SDKTestHarness!

            beforeEach {
                harness = try SDKTestHarness.make(prefix: "test_identity", trackLifecycleEvents: false)
                try harness.setupSDK()
            }

            afterEach {
                harness?.cleanup()
                harness = nil
            }

            // MARK: - Basic Identity Experience

            describe("basic identity flow") {
                it("should start with anonymous identity") {
                    expect(NuxieSDK.shared.isIdentified).to(beFalse())

                    let anonymousId = NuxieSDK.shared.getAnonymousId()
                    let distinctId = NuxieSDK.shared.getDistinctId()

                    expect(anonymousId).toNot(beEmpty())
                    expect(distinctId).to(equal(anonymousId))
                }

                it("should identify user correctly") {
                    let userId = "user-123"
                    NuxieSDK.shared.identify(userId)

                    expect(NuxieSDK.shared.isIdentified).to(beTrue())
                    expect(NuxieSDK.shared.getDistinctId()).to(equal(userId))

                    // Anonymous ID should be preserved
                    let anonymousId = NuxieSDK.shared.getAnonymousId()
                    expect(anonymousId).toNot(beEmpty())
                    expect(anonymousId).toNot(equal(userId))
                }

                it("rotates the anonymous ID on reset by default") {
                    // Fresh anon id on logout so the NEXT user's pre-identify
                    // events never chain to the previous person
                    let originalAnonymousId = NuxieSDK.shared.getAnonymousId()

                    NuxieSDK.shared.identify("user-123")
                    expect(NuxieSDK.shared.isIdentified).to(beTrue())

                    NuxieSDK.shared.reset()

                    expect(NuxieSDK.shared.isIdentified).to(beFalse())
                    expect(NuxieSDK.shared.getAnonymousId()).toNot(equal(originalAnonymousId))
                    expect(NuxieSDK.shared.getDistinctId()).to(equal(NuxieSDK.shared.getAnonymousId()))
                }

                it("keeps the anonymous ID when explicitly requested") {
                    let originalAnonymousId = NuxieSDK.shared.getAnonymousId()

                    NuxieSDK.shared.identify("user-123")
                    NuxieSDK.shared.reset(keepAnonymousId: true)

                    expect(NuxieSDK.shared.isIdentified).to(beFalse())
                    expect(NuxieSDK.shared.getAnonymousId()).to(equal(originalAnonymousId))
                }
            }

            // MARK: - User Properties

            describe("user properties with identify") {
                it("should set user properties during identify") {
                    let userId = "user-with-props"
                    let properties = ["name": "John", "age": 30] as [String: Any]
                    let eventLog = NuxieSDK.shared.core!.eventLog

                    NuxieSDK.shared.identify(userId, userProperties: properties)

                    await expect {
                        let events = await eventLog.getEventsForUser(userId, limit: 10)
                        return events.first { $0.name == "$identify" }
                    }.toEventuallyNot(beNil(), timeout: .seconds(2))

                    expect(NuxieSDK.shared.isIdentified).to(beTrue())
                    expect(NuxieSDK.shared.getDistinctId()).to(equal(userId))

                    let events = await eventLog.getEventsForUser(userId, limit: 10)
                    let identifyEvent = events.first { $0.name == "$identify" }
                    let props = try? identifyEvent?.getProperties()
                    let setProps = props?["$set"]?.value as? [String: Any]
                    expect(setProps?["name"] as? String).to(equal("John"))
                    expect(setProps?["age"] as? Int).to(equal(30))
                }

                it("should include $set_once properties during identify") {
                    let userId = "user-setonce"
                    let eventLog = NuxieSDK.shared.core!.eventLog

                    // First identify with properties
                    NuxieSDK.shared.identify(userId, userPropertiesSetOnce: ["first_seen": "2024-01-01"])

                    await expect {
                        let events = await eventLog.getEventsForUser(userId, limit: 10)
                        return events.first { $0.name == "$identify" }
                    }.toEventuallyNot(beNil(), timeout: .seconds(2))
                    await eventLog.drain()

                    let firstEvents = await eventLog.getEventsForUser(userId, limit: 10)
                    let firstIdentify = firstEvents.first { $0.name == "$identify" }
                    let firstProps = try? firstIdentify?.getProperties()
                    let firstSetOnce = firstProps?["$set_once"]?.value as? [String: Any]
                    expect(firstSetOnce?["first_seen"] as? String).to(equal("2024-01-01"))

                    // Second identify with different setOnce properties
                    NuxieSDK.shared.identify(userId, userPropertiesSetOnce: ["first_seen": "2024-12-01"])
                    try? await Task.sleep(nanoseconds: 50_000_000)

                    expect(NuxieSDK.shared.isIdentified).to(beTrue())

                    await expect {
                        let events = await eventLog.getEventsForUser(userId, limit: 20)
                        return events.first { $0.name == "$identify" }
                    }.toEventuallyNot(beNil(), timeout: .seconds(2))
                    await eventLog.drain()

                    let latestEvents = await eventLog.getEventsForUser(userId, limit: 20)
                    let latestIdentify = latestEvents.first { $0.name == "$identify" }
                    let latestProps = try? latestIdentify?.getProperties()
                    let latestSetOnce = latestProps?["$set_once"]?.value as? [String: Any]
                    expect(latestSetOnce?["first_seen"] as? String).to(equal("2024-12-01"))
                }
            }

            // MARK: - $identify Event Tracking

            describe("$identify event tracking") {
                it("should track $identify event when identifying") {
                    let eventLog = NuxieSDK.shared.core!.eventLog
                    let userId = "identify-event-user"

                    NuxieSDK.shared.identify(userId)

                    // Give time for event to be processed
                    await expect {
                        let events = await eventLog.getEventsForUser(userId, limit: 10)
                        return events.contains { $0.name == "$identify" }
                    }.toEventually(beTrue(), timeout: .seconds(2))
                }

                it("should include distinct_id in $identify event properties") {
                    let eventLog = NuxieSDK.shared.core!.eventLog
                    let userId = "identify-props-user"

                    NuxieSDK.shared.identify(userId)

                    await expect {
                        let events = await eventLog.getEventsForUser(userId, limit: 10)
                        return events.first { $0.name == "$identify" }
                    }.toEventuallyNot(beNil(), timeout: .seconds(2))

                    let events = await eventLog.getEventsForUser(userId, limit: 10)
                    let identifyEvent = events.first { $0.name == "$identify" }

                    expect(identifyEvent).toNot(beNil())
                    if let props = try? identifyEvent?.getProperties() {
                        expect(props["distinct_id"]?.value as? String).to(equal(userId))
                    }
                }
            }

            // MARK: - Session Handling

            describe("session handling on identify") {
                it("should start new session when identifying") {
                    let sessionService = NuxieSDK.shared.core!.sessions

                    // Create initial session
                    let firstSessionId = sessionService.getSessionId(at: Date(), readOnly: false)
                    expect(firstSessionId).toNot(beNil())

                    // Identify should create new session
                    NuxieSDK.shared.identify("session-user")

                    let secondSessionId = sessionService.getSessionId(at: Date(), readOnly: true)
                    expect(secondSessionId).toNot(beNil())
                    expect(secondSessionId).toNot(equal(firstSessionId))
                }

                it("should reset session on reset()") {
                    let sessionService = NuxieSDK.shared.core!.sessions

                    NuxieSDK.shared.identify("reset-session-user")
                    let identifiedSessionId = sessionService.getSessionId(at: Date(), readOnly: false)

                    NuxieSDK.shared.reset()

                    // Session should be cleared or new
                    let afterResetSessionId = sessionService.getSessionId(at: Date(), readOnly: false)
                    expect(afterResetSessionId).toNot(equal(identifiedSessionId))
                }
            }

            // MARK: - Multiple Identity Transitions

            describe("multiple identity transitions") {
                it("should handle identify -> reset -> identify cycle correctly") {
                    let user1 = "user-1"
                    let user2 = "user-2"
                    let anonymousId = NuxieSDK.shared.getAnonymousId()

                    // Identify first user
                    NuxieSDK.shared.identify(user1)
                    expect(NuxieSDK.shared.getDistinctId()).to(equal(user1))
                    expect(NuxieSDK.shared.isIdentified).to(beTrue())

                    // Reset to anonymous — the anon id ROTATES by default so
                    // user-2's pre-identify events can't chain to user-1
                    NuxieSDK.shared.reset()
                    expect(NuxieSDK.shared.getDistinctId()).toNot(equal(anonymousId))
                    expect(NuxieSDK.shared.getDistinctId()).to(equal(NuxieSDK.shared.getAnonymousId()))
                    expect(NuxieSDK.shared.isIdentified).to(beFalse())

                    // Identify second user
                    NuxieSDK.shared.identify(user2)
                    expect(NuxieSDK.shared.getDistinctId()).to(equal(user2))
                    expect(NuxieSDK.shared.isIdentified).to(beTrue())
                }

                it("should handle direct user-to-user transition") {
                    let user1 = "direct-user-1"
                    let user2 = "direct-user-2"

                    NuxieSDK.shared.identify(user1)
                    expect(NuxieSDK.shared.getDistinctId()).to(equal(user1))

                    // Identify different user without reset
                    NuxieSDK.shared.identify(user2)
                    expect(NuxieSDK.shared.getDistinctId()).to(equal(user2))
                    expect(NuxieSDK.shared.isIdentified).to(beTrue())
                }

                it("should handle re-identifying with same user ID") {
                    let userId = "same-user"

                    NuxieSDK.shared.identify(userId)
                    let sessionAfterFirst = NuxieSDK.shared.core!.sessions.getSessionId(at: Date(), readOnly: true)

                    // Re-identify with same ID
                    NuxieSDK.shared.identify(userId, userProperties: ["updated": true])

                    // Should still be identified as same user
                    expect(NuxieSDK.shared.getDistinctId()).to(equal(userId))
                    expect(NuxieSDK.shared.isIdentified).to(beTrue())

                    // Re-identifying with the same id must NOT rotate the session:
                    // apps call identify() on every launch and session analytics
                    // would fragment otherwise.
                    let sessionAfterSecond = NuxieSDK.shared.core!.sessions.getSessionId(at: Date(), readOnly: true)
                    expect(sessionAfterSecond).to(equal(sessionAfterFirst))
                }
            }

            // MARK: - Rapid Transitions

            describe("rapid identity transitions") {
                it("should handle rapid identify/reset cycles without crashes") {
                    for i in 0..<10 {
                        NuxieSDK.shared.identify("rapid-user-\(i)")
                        NuxieSDK.shared.reset()
                    }

                    // Should end in anonymous state
                    expect(NuxieSDK.shared.isIdentified).to(beFalse())

                    // Final identify should work
                    NuxieSDK.shared.identify("final-user")
                    expect(NuxieSDK.shared.isIdentified).to(beTrue())
                    expect(NuxieSDK.shared.getDistinctId()).to(equal("final-user"))
                }

                it("should handle rapid identify with different users") {
                    for i in 0..<10 {
                        NuxieSDK.shared.identify("user-\(i)")
                    }

                    // Should end up as the last user
                    expect(NuxieSDK.shared.getDistinctId()).to(equal("user-9"))
                    expect(NuxieSDK.shared.isIdentified).to(beTrue())
                }

                it("runs every queued transition to completion, in order") {
                    // The old cancellable task chains dropped transitions
                    // mid-fan-out when a new identify arrived; the coordinator
                    // must run all of them, FIFO, to completion.
                    for i in 0..<5 {
                        NuxieSDK.shared.identify("serial-user-\(i)")
                    }
                    NuxieSDK.shared.reset()
                    NuxieSDK.shared.identify("serial-final")

                    let coordinator = NuxieSDK.shared.core!.userTransitions
                    await coordinator.drain()

                    expect(NuxieSDK.shared.getDistinctId()).to(equal("serial-final"))
                    expect(NuxieSDK.shared.isIdentified).to(beTrue())
                }
            }

            // MARK: - Concurrent Access

            describe("concurrent identity access") {
                it("should handle concurrent getDistinctId calls safely") {
                    let iterations = 50

                    NuxieSDK.shared.identify("concurrent-user")

                    let distinctIds: [String] = await withTaskGroup(of: String.self) { group in
                        for _ in 0..<iterations {
                            group.addTask {
                                NuxieSDK.shared.getDistinctId()
                            }
                        }
                        var results: [String] = []
                        for await id in group {
                            results.append(id)
                        }
                        return results
                    }

                    // All calls should return the same user ID
                    let uniqueIds = Set(distinctIds)
                    expect(uniqueIds.count).to(equal(1))
                    expect(uniqueIds.first).to(equal("concurrent-user"))
                }

                it("should handle concurrent identify and getDistinctId calls") {
                    await withTaskGroup(of: Void.self) { group in
                        for i in 0..<20 {
                            group.addTask {
                                if i % 2 == 0 {
                                    NuxieSDK.shared.identify("concurrent-\(i)")
                                } else {
                                    _ = NuxieSDK.shared.getDistinctId()
                                }
                            }
                        }
                    }

                    // Should not crash and should have valid state
                    expect(NuxieSDK.shared.getDistinctId()).toNot(beEmpty())
                }
            }

            // MARK: - Edge Cases

            describe("edge cases") {
                it("should handle empty string user ID") {
                    // Empty user ID should be handled gracefully
                    NuxieSDK.shared.identify("")

                    expect(NuxieSDK.shared.getDistinctId()).to(equal(""))
                    expect(NuxieSDK.shared.isIdentified).to(beTrue())
                }

                it("should handle whitespace-only user ID") {
                    NuxieSDK.shared.identify("   ")

                    expect(NuxieSDK.shared.getDistinctId()).to(equal("   "))
                    expect(NuxieSDK.shared.isIdentified).to(beTrue())
                }

                it("should handle special characters in user ID") {
                    let specialUserId = "user@example.com/test+id#123"

                    NuxieSDK.shared.identify(specialUserId)

                    expect(NuxieSDK.shared.getDistinctId()).to(equal(specialUserId))
                    expect(NuxieSDK.shared.isIdentified).to(beTrue())
                }

                it("should handle unicode in user ID") {
                    let unicodeUserId = "用户-🎉-test"

                    NuxieSDK.shared.identify(unicodeUserId)

                    expect(NuxieSDK.shared.getDistinctId()).to(equal(unicodeUserId))
                    expect(NuxieSDK.shared.isIdentified).to(beTrue())
                }

                it("should handle very long user ID") {
                    let longUserId = String(repeating: "a", count: 1000)

                    NuxieSDK.shared.identify(longUserId)

                    expect(NuxieSDK.shared.getDistinctId()).to(equal(longUserId))
                    expect(NuxieSDK.shared.isIdentified).to(beTrue())
                }
            }

            // MARK: - Anonymous ID Persistence

            describe("anonymous ID persistence") {
                it("preserves the anonymous ID across identify calls, rotates on reset") {
                    let originalAnonymousId = NuxieSDK.shared.getAnonymousId()

                    NuxieSDK.shared.identify("user-1")
                    expect(NuxieSDK.shared.getAnonymousId()).to(equal(originalAnonymousId))

                    NuxieSDK.shared.identify("user-2")
                    expect(NuxieSDK.shared.getAnonymousId()).to(equal(originalAnonymousId))

                    NuxieSDK.shared.reset()
                    expect(NuxieSDK.shared.getAnonymousId()).toNot(equal(originalAnonymousId))
                }
            }
        }
    }
}
