import Foundation
import Quick
import Nimble
import FactoryKit
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

/// Comprehensive integration tests for backgrounding behavior
/// Tests how services behave when the app enters background and returns to foreground
final class BackgroundingIntegrationTests: AsyncSpec {
    override class func spec() {
        describe("Backgrounding Integration") {

            // MARK: - SessionService Backgrounding

            describe("SessionService backgrounding behavior") {
                var sessionService: SessionService!

                beforeEach {
                    sessionService = SessionService()
                }

                afterEach {
                    sessionService = nil
                }

                it("should mark app as in background on onAppDidEnterBackground") {
                    // Create initial session
                    _ = sessionService.getSessionId(at: Date(), readOnly: false)

                    // Enter background
                    sessionService.onAppDidEnterBackground()

                    // Session should still exist (not cleared immediately)
                    let sessionId = sessionService.getSessionId(at: Date(), readOnly: true)
                    expect(sessionId).toNot(beNil())
                }

                it("should handle session expiration during background") {
                    let now = Date()

                    // Create session
                    let originalSessionId = sessionService.getSessionId(at: now, readOnly: false)
                    expect(originalSessionId).toNot(beNil())

                    // Enter background
                    sessionService.onAppDidEnterBackground()

                    // Simulate 31 minutes passing while backgrounded
                    let afterTimeout = now.addingTimeInterval(31 * 60)

                    // Return to foreground
                    sessionService.onAppBecameActive()

                    // Try to get session at the later time - should create new session
                    let newSessionId = sessionService.getSessionId(at: afterTimeout, readOnly: false)
                    expect(newSessionId).toNot(beNil())
                    expect(newSessionId).toNot(equal(originalSessionId))
                }

                it("should preserve session when returning quickly from background") {
                    let now = Date()

                    // Create session
                    let originalSessionId = sessionService.getSessionId(at: now, readOnly: false)

                    // Background and immediately foreground
                    sessionService.onAppDidEnterBackground()
                    sessionService.onAppBecameActive()

                    // Session should be preserved
                    let afterSessionId = sessionService.getSessionId(at: now.addingTimeInterval(1), readOnly: true)
                    expect(afterSessionId).to(equal(originalSessionId))
                }

                it("should handle multiple background/foreground cycles") {
                    let now = Date()
                    var currentTime = now

                    // Create initial session
                    let originalSessionId = sessionService.getSessionId(at: currentTime, readOnly: false)

                    // Perform multiple cycles within timeout
                    for i in 0..<5 {
                        sessionService.onAppDidEnterBackground()
                        currentTime = currentTime.addingTimeInterval(60) // 1 minute each
                        sessionService.onAppBecameActive()
                        let sessionId = sessionService.getSessionId(at: currentTime, readOnly: false)

                        // Session should be preserved (total time < 30 min)
                        expect(sessionId).to(equal(originalSessionId))
                    }
                }

                it("should track session state across background/foreground") {
                    var changeReasons: [SessionIDChangeReason] = []

                    sessionService.onSessionIdChanged = { reason in
                        changeReasons.append(reason)
                    }

                    let now = Date()

                    // Create session
                    _ = sessionService.getSessionId(at: now, readOnly: false)

                    // Background
                    sessionService.onAppDidEnterBackground()

                    // Simulate timeout
                    let afterTimeout = now.addingTimeInterval(31 * 60)

                    // Foreground - should trigger new session
                    sessionService.onAppBecameActive()
                    _ = sessionService.getSessionId(at: afterTimeout, readOnly: false)

                    // Should have timeout reason
                    expect(changeReasons).to(contain(.sessionTimeout))
                }
            }

            // MARK: - Full SDK Backgrounding Integration

            describe("SDK backgrounding integration") {
                var harness: SDKTestHarness!

                beforeEach {
                    harness = try SDKTestHarness.make(prefix: "test_bg", trackLifecycleEvents: true)
                    try harness.setupSDK()
                }

                afterEach {
                    harness?.cleanup()
                    harness = nil
                }

                it("should preserve identity across background/foreground cycle") {
                    NuxieSDK.shared.identify("bg-test-user")

                    let identityBefore = NuxieSDK.shared.getDistinctId()
                    let anonymousIdBefore = NuxieSDK.shared.getAnonymousId()

                    // Simulate background/foreground (via SessionService)
                    let sessionService = Container.shared.sessionService()
                    sessionService.onAppDidEnterBackground()
                    sessionService.onAppBecameActive()

                    // Identity should be preserved
                    expect(NuxieSDK.shared.getDistinctId()).to(equal(identityBefore))
                    expect(NuxieSDK.shared.getAnonymousId()).to(equal(anonymousIdBefore))
                    expect(NuxieSDK.shared.isIdentified).to(beTrue())
                }

                it("should continue tracking events after returning from background") {
                    let eventService = Container.shared.eventService()

                    // Track initial event
                    NuxieSDK.shared.trigger("before_background")

                    await expect {
                        let events = await eventService.getRecentEvents(limit: 20)
                        return events.contains { $0.name == "before_background" }
                    }.toEventually(beTrue(), timeout: .seconds(2))

                    // Background
                    let sessionService = Container.shared.sessionService()
                    sessionService.onAppDidEnterBackground()
                    // Foreground
                    sessionService.onAppBecameActive()

                    // Track event after returning
                    NuxieSDK.shared.trigger("after_background")

                    // Both events should be tracked
                    await expect {
                        let events = await eventService.getRecentEvents(limit: 20)
                        return events.contains { $0.name == "after_background" }
                    }.toEventually(beTrue(), timeout: .seconds(2))
                }

                it("should handle rapid background/foreground cycles") {
                    let eventService = Container.shared.eventService()
                    let sessionService = Container.shared.sessionService()

                    // Rapid cycles
                    for i in 0..<10 {
                        sessionService.onAppDidEnterBackground()
                        NuxieSDK.shared.trigger("cycle_event_\(i)")
                        sessionService.onAppBecameActive()
                    }

                    // All events should be tracked
                    await expect {
                        let events = await eventService.getRecentEvents(limit: 50)
                        let cycleEvents = events.filter { $0.name.starts(with: "cycle_event_") }
                        return cycleEvents.count
                    }.toEventually(equal(10), timeout: .seconds(3))
                }
            }

            // MARK: - Event Queue Backgrounding

            describe("event queue backgrounding behavior") {
                var harness: SDKTestHarness!

                beforeEach {
                    harness = try SDKTestHarness.make(prefix: "test_queue", trackLifecycleEvents: false)
                    try harness.setupSDK()
                }

                afterEach {
                    harness?.cleanup()
                    harness = nil
                }

                it("should pause event queue on background") {
                    let eventService = Container.shared.eventService()

                    // Track some events
                    NuxieSDK.shared.trigger("event_1")
                    NuxieSDK.shared.trigger("event_2")

                    // Enter background
                    await eventService.onAppDidEnterBackground()

                    // Events should be stored locally even when paused
                    await expect {
                        let events = await eventService.getRecentEvents(limit: 10)
                        return events.count
                    }.toEventually(beGreaterThanOrEqualTo(2), timeout: .seconds(2))
                }

                it("should resume event queue on foreground") {
                    let eventService = Container.shared.eventService()

                    // Background
                    await eventService.onAppDidEnterBackground()

                    // Track event while backgrounded
                    NuxieSDK.shared.trigger("backgrounded_event")

                    // Foreground
                    await eventService.onAppBecameActive()
                    await eventService.drain()

                    // Event should eventually be processed
                    await expect {
                        let events = await eventService.getRecentEvents(limit: 10)
                        return events.contains { $0.name == "backgrounded_event" }
                    }.toEventually(beTrue(), timeout: .seconds(2))
                }
            }

            // MARK: - Thread Safety During Backgrounding

            describe("thread safety during backgrounding") {
                var sessionService: SessionService!

                beforeEach {
                    sessionService = SessionService()
                }

                afterEach {
                    sessionService = nil
                }

                it("should handle concurrent background/foreground calls") {
                    let group = DispatchGroup()
                    let iterations = 50

                    // Create initial session
                    _ = sessionService.getSessionId(at: Date(), readOnly: false)

                    for _ in 0..<iterations {
                        group.enter()
                        DispatchQueue.global().async {
                            sessionService.onAppDidEnterBackground()
                            sessionService.onAppBecameActive()
                            group.leave()
                        }
                    }

                    group.wait()

                    // Should not crash and session should still be valid
                    let sessionId = sessionService.getSessionId(at: Date(), readOnly: true)
                    expect(sessionId).toNot(beNil())
                }

                it("should handle concurrent getSessionId during backgrounding") {
                    let group = DispatchGroup()
                    var sessionIds: [String?] = []
                    let lock = NSLock()

                    // Create initial session
                    _ = sessionService.getSessionId(at: Date(), readOnly: false)

                    // Background
                    sessionService.onAppDidEnterBackground()

                    // Concurrent session accesses
                    for _ in 0..<50 {
                        group.enter()
                        DispatchQueue.global().async {
                            let id = sessionService.getSessionId(at: Date(), readOnly: true)
                            lock.lock()
                            sessionIds.append(id)
                            lock.unlock()
                            group.leave()
                        }
                    }

                    group.wait()

                    // All IDs should be the same (or all nil)
                    let uniqueIds = Set(sessionIds.compactMap { $0 })
                    expect(uniqueIds.count).to(beLessThanOrEqualTo(1))
                }
            }

            // MARK: - State Consistency

            describe("state consistency after backgrounding") {
                var harness: SDKTestHarness!

                beforeEach {
                    harness = try SDKTestHarness.make(prefix: "test_state", trackLifecycleEvents: false)
                    try harness.setupSDK()
                }

                afterEach {
                    harness?.cleanup()
                    harness = nil
                }

                it("should maintain SDK isSetup state after backgrounding") {
                    let sessionService = Container.shared.sessionService()

                    expect(NuxieSDK.shared.isSetup).to(beTrue())

                    sessionService.onAppDidEnterBackground()
                    sessionService.onAppBecameActive()

                    expect(NuxieSDK.shared.isSetup).to(beTrue())
                }

                it("should maintain identified state after backgrounding") {
                    NuxieSDK.shared.identify("state-test-user")

                    let sessionService = Container.shared.sessionService()
                    sessionService.onAppDidEnterBackground()
                    sessionService.onAppBecameActive()

                    expect(NuxieSDK.shared.isIdentified).to(beTrue())
                    expect(NuxieSDK.shared.getDistinctId()).to(equal("state-test-user"))
                }

                it("should preserve events stored during background") {
                    let eventService = Container.shared.eventService()
                    let sessionService = Container.shared.sessionService()

                    // Background
                    sessionService.onAppDidEnterBackground()
                    await eventService.onAppDidEnterBackground()

                    // Track event while backgrounded
                    NuxieSDK.shared.trigger("stored_during_bg", properties: ["test": true])

                    await eventService.drain()

                    // Foreground
                    sessionService.onAppBecameActive()
                    await eventService.onAppBecameActive()

                    // Event should be stored
                    await expect {
                        let events = await eventService.getRecentEvents(limit: 20)
                        return events.contains { $0.name == "stored_during_bg" }
                    }.toEventually(beTrue(), timeout: .seconds(2))
                }
            }
        }
    }
}
