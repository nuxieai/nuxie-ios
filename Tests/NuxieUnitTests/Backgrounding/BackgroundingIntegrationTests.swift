import Foundation
import Quick
import Nimble
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

/// Comprehensive integration tests for backgrounding behavior
/// Tests how services behave when the app enters background and returns to foreground
final class BackgroundingIntegrationTests: AsyncSpec {
    override class func spec() {
        describe("Backgrounding Integration") {

            // MARK: - Full SDK Backgrounding Integration

            describe("SDK backgrounding integration") {
                var harness: SDKTestHarness!

                beforeEach {
                    let mocks = MockFactory.shared
                    await mocks.resetAll()
                    var configured = try SDKTestHarness.make(
                        prefix: "test_bg",
                        trackLifecycleEvents: true
                    )
                    configured.overrides.experiences = mocks.experienceService
                    configured.overrides.profile = mocks.profileService
                    harness = configured
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

                    NotificationCenter.default.post(
                        name: NuxieSystemNotifications.appDidEnterBackground,
                        object: nil
                    )
                    NotificationCenter.default.post(
                        name: NuxieSystemNotifications.appDidBecomeActive,
                        object: nil
                    )

                    // Identity should be preserved
                    expect(NuxieSDK.shared.getDistinctId()).to(equal(identityBefore))
                    expect(NuxieSDK.shared.getAnonymousId()).to(equal(anonymousIdBefore))
                    expect(NuxieSDK.shared.isIdentified).to(beTrue())
                }

                it("should continue tracking events after returning from background") {
                    let eventLog = NuxieSDK.shared.core!.eventLog

                    // Track initial event
                    NuxieSDK.shared.trigger("before_background")

                    await expect {
                        let events = await eventLog.getRecentEvents(limit: 20)
                        return events.contains { $0.name == "before_background" }
                    }.toEventually(beTrue(), timeout: .seconds(2))

                    NotificationCenter.default.post(
                        name: NuxieSystemNotifications.appDidEnterBackground,
                        object: nil
                    )
                    NotificationCenter.default.post(
                        name: NuxieSystemNotifications.appDidBecomeActive,
                        object: nil
                    )

                    // Track event after returning
                    NuxieSDK.shared.trigger("after_background")

                    // Both events should be tracked
                    await expect {
                        let events = await eventLog.getRecentEvents(limit: 20)
                        return events.contains { $0.name == "after_background" }
                    }.toEventually(beTrue(), timeout: .seconds(2))
                }

                it("should handle rapid background/foreground cycles") {
                    let eventLog = NuxieSDK.shared.core!.eventLog
                    // Rapid cycles
                    for i in 0..<10 {
                        NotificationCenter.default.post(
                            name: NuxieSystemNotifications.appDidEnterBackground,
                            object: nil
                        )
                        NuxieSDK.shared.trigger("cycle_event_\(i)")
                        NotificationCenter.default.post(
                            name: NuxieSystemNotifications.appDidBecomeActive,
                            object: nil
                        )
                    }

                    // All events should be tracked
                    await expect {
                        let events = await eventLog.getRecentEvents(limit: 50)
                        let cycleEvents = events.filter { $0.name.starts(with: "cycle_event_") }
                        return cycleEvents.count
                    }.toEventually(equal(10), timeout: .seconds(3))
                }

                it("cancels speculative Experience warming on background") {
                    NotificationCenter.default.post(
                        name: NuxieSystemNotifications.appDidEnterBackground,
                        object: nil
                    )

                    await expect {
                        MockFactory.shared.experienceService
                            .backgroundPreparationPauseCallCount
                    }.toEventually(equal(1), timeout: .seconds(2))

                    NotificationCenter.default.post(
                        name: NuxieSystemNotifications.appDidBecomeActive,
                        object: nil
                    )
                    await expect {
                        MockFactory.shared.experienceService
                            .foregroundPreparationResumeCallCount
                    }.toEventually(equal(1), timeout: .seconds(2))
                }

                it("expires resident profile authority before rearming speculative warming") {
                    let recorder = LifecycleServiceOrderRecorder()
                    MockFactory.shared.profileService.onAppBecameActiveHandler = {
                        await recorder.append("profile")
                    }
                    MockFactory.shared.experienceService.onAppBecameActiveHandler = {
                        await recorder.append("experience")
                    }

                    NotificationCenter.default.post(
                        name: NuxieSystemNotifications.appDidBecomeActive,
                        object: nil
                    )

                    await expect {
                        await recorder.values
                    }.toEventually(
                        equal(["profile", "experience"]),
                        timeout: .seconds(2)
                    )
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
                    let eventLog = NuxieSDK.shared.core!.eventLog

                    // Track some events
                    NuxieSDK.shared.trigger("event_1")
                    NuxieSDK.shared.trigger("event_2")

                    // Enter background
                    await eventLog.onAppDidEnterBackground()

                    // Events should be stored locally even when paused
                    await expect {
                        let events = await eventLog.getRecentEvents(limit: 10)
                        return events.count
                    }.toEventually(beGreaterThanOrEqualTo(2), timeout: .seconds(2))
                }

                it("should resume event queue on foreground") {
                    let eventLog = NuxieSDK.shared.core!.eventLog

                    // Background
                    await eventLog.onAppDidEnterBackground()

                    // Track event while backgrounded
                    NuxieSDK.shared.trigger("backgrounded_event")

                    // Foreground
                    await eventLog.onAppBecameActive()
                    await eventLog.drain()

                    // Event should eventually be processed
                    await expect {
                        let events = await eventLog.getRecentEvents(limit: 10)
                        return events.contains { $0.name == "backgrounded_event" }
                    }.toEventually(beTrue(), timeout: .seconds(2))
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
                    expect(NuxieSDK.shared.isSetup).to(beTrue())

                    NotificationCenter.default.post(
                        name: NuxieSystemNotifications.appDidEnterBackground,
                        object: nil
                    )
                    NotificationCenter.default.post(
                        name: NuxieSystemNotifications.appDidBecomeActive,
                        object: nil
                    )

                    expect(NuxieSDK.shared.isSetup).to(beTrue())
                }

                it("should maintain identified state after backgrounding") {
                    NuxieSDK.shared.identify("state-test-user")

                    NotificationCenter.default.post(
                        name: NuxieSystemNotifications.appDidEnterBackground,
                        object: nil
                    )
                    NotificationCenter.default.post(
                        name: NuxieSystemNotifications.appDidBecomeActive,
                        object: nil
                    )

                    expect(NuxieSDK.shared.isIdentified).to(beTrue())
                    expect(NuxieSDK.shared.getDistinctId()).to(equal("state-test-user"))
                }

                it("should preserve events stored during background") {
                    let eventLog = NuxieSDK.shared.core!.eventLog

                    // Background
                    await eventLog.onAppDidEnterBackground()

                    // Track event while backgrounded
                    NuxieSDK.shared.trigger("stored_during_bg", properties: ["test": true])

                    await eventLog.drain()

                    // Foreground
                    await eventLog.onAppBecameActive()

                    // Event should be stored
                    await expect {
                        let events = await eventLog.getRecentEvents(limit: 20)
                        return events.contains { $0.name == "stored_during_bg" }
                    }.toEventually(beTrue(), timeout: .seconds(2))
                }
            }
        }
    }
}

private actor LifecycleServiceOrderRecorder {
    private var recordedValues: [String] = []

    var values: [String] { recordedValues }

    func append(_ value: String) {
        recordedValues.append(value)
    }
}
