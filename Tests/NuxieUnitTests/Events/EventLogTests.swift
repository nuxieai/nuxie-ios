import Foundation
import Quick
import Nimble
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

/// EventLog behavior that did not exist before the Phase 4b merge:
/// the committed-events subscription stream, pre-configure enrichment,
/// and retention cadence (formerly EventStoreService's job).
final class EventLogTests: AsyncSpec {
    override class func spec() {
        describe("EventLog") {
            var log: EventLog!
            var mockStore: MockEventStore!
            var mockApi: MockNuxieApi!
            var testConfig: NuxieConfiguration!

            beforeEach {
                testConfig = NuxieConfiguration(apiKey: "test-api-key")
                testConfig.flushAt = 100  // manual flush only

                mockStore = MockEventStore()
                mockApi = MockNuxieApi()

                log = EventLog(
                    identity: MockIdentityService(),
                    sessions: MockSessionService(),
                    dateProvider: MockDateProvider(),
                    apiClient: mockApi,
                    store: mockStore
                )
            }

            afterEach {
                await log?.close()
                log = nil
            }

            // MARK: - Committed-events subscription stream

            describe("committed-events subscriptions") {
                it("delivers committed events to a subscriber in capture order") {
                    let received = ReceivedEvents()
                    await log.subscribeCommitted { event in
                        await received.append(event.name)
                    }
                    try await log.configure(configuration: testConfig)

                    log.track("first", properties: nil, userProperties: nil, userPropertiesSetOnce: nil)
                    log.track("second", properties: nil, userProperties: nil, userPropertiesSetOnce: nil)
                    log.track("third", properties: nil, userProperties: nil, userPropertiesSetOnce: nil)
                    await log.drain()

                    await expect { await received.names }.to(equal(["first", "second", "third"]))
                }

                it("only announces events after they are persisted pending delivery") {
                    let persistedAtAnnounce = PersistenceProbe()
                    let store = mockStore!
                    await log.subscribeCommitted { event in
                        let persisted = store.storedEvents.contains { $0.id == event.id }
                        let pending = store.pendingIds.contains(event.id)
                        await persistedAtAnnounce.record(persisted: persisted, pending: pending)
                    }
                    try await log.configure(configuration: testConfig)

                    log.track("durable_event", properties: nil, userProperties: nil, userPropertiesSetOnce: nil)
                    await log.drain()

                    await expect { await persistedAtAnnounce.allPersisted }.to(beTrue())
                    await expect { await persistedAtAnnounce.allPending }.to(beTrue())
                }

                it("applies the subscription filter before invoking the handler") {
                    let received = ReceivedEvents()
                    await log.subscribeCommitted(
                        where: { !$0.name.hasPrefix("$") }
                    ) { event in
                        await received.append(event.name)
                    }
                    try await log.configure(configuration: testConfig)

                    log.track("$internal_event", properties: nil, userProperties: nil, userPropertiesSetOnce: nil)
                    log.track("user_event", properties: nil, userProperties: nil, userPropertiesSetOnce: nil)
                    await log.drain()

                    await expect { await received.names }.to(equal(["user_event"]))
                }

                it("fans committed events out to every subscriber") {
                    let first = ReceivedEvents()
                    let second = ReceivedEvents()
                    await log.subscribeCommitted { event in
                        await first.append(event.name)
                    }
                    await log.subscribeCommitted { event in
                        await second.append(event.name)
                    }
                    try await log.configure(configuration: testConfig)

                    log.track("shared_event", properties: nil, userProperties: nil, userPropertiesSetOnce: nil)
                    await log.drain()

                    await expect { await first.names }.to(equal(["shared_event"]))
                    await expect { await second.names }.to(equal(["shared_event"]))
                }

                it("observes events tracked before configure when subscribed before configure") {
                    let received = ReceivedEvents()
                    // Track BEFORE configure: the capture worker must buffer
                    // until the log opens, so a pre-configure subscriber
                    // misses nothing.
                    log.track("early_event", properties: nil, userProperties: nil, userPropertiesSetOnce: nil)
                    await log.subscribeCommitted { event in
                        await received.append(event.name)
                    }
                    try await log.configure(configuration: testConfig)
                    await log.drain()

                    await expect { await received.names }.to(equal(["early_event"]))
                }
            }

            // MARK: - Enrichment

            describe("enrichment") {
                it("context-enriches events tracked before configure") {
                    // Regression guard: the old EventService built events the
                    // moment the worker saw them, so pre-configure captures
                    // (e.g. $app_installed from the lifecycle tracker) silently
                    // skipped context enrichment and the beforeSend hook.
                    log.track("early_event", properties: ["custom": "value"], userProperties: nil, userPropertiesSetOnce: nil)
                    try await log.configure(configuration: testConfig)
                    await log.drain()

                    let stored = mockStore.storedEvents.first { $0.name == "early_event" }
                    expect(stored).toNot(beNil())
                    let props = stored?.getPropertiesDict() ?? [:]
                    expect(props["custom"] as? String).to(equal("value"))
                    expect(props["$lib"] as? String).to(equal("nuxie-ios"))
                    expect(props["$lib_version"] as? String).to(equal(SDKVersion.current))
                }

                it("applies the beforeSend hook to pre-configure captures") {
                    testConfig.beforeSend = { event in
                        event.name == "dropped_event" ? nil : event
                    }
                    log.track("dropped_event", properties: nil, userProperties: nil, userPropertiesSetOnce: nil)
                    log.track("kept_event", properties: nil, userProperties: nil, userPropertiesSetOnce: nil)
                    try await log.configure(configuration: testConfig)
                    await log.drain()

                    let names = mockStore.storedEvents.map(\.name)
                    expect(names).toNot(contain("dropped_event"))
                    expect(names).to(contain("kept_event"))
                }

                it("stores direct-delivery history rows with device metadata") {
                    await mockApi.setTrackEventResponse(.success())
                    try await log.configure(configuration: testConfig)

                    _ = try await log.trackWithResponse(
                        "app_launched",
                        properties: ["version": "1.0.0"]
                    )

                    let stored = mockStore.storedEvents.first { $0.name == "app_launched" }
                    expect(stored).toNot(beNil())
                    let props = stored?.getPropertiesDict() ?? [:]
                    expect(props["version"] as? String).to(equal("1.0.0"))
                    expect(props["sdk_version"] as? String).to(equal(SDKVersion.current))
                    #if os(macOS)
                    expect(props["platform"] as? String).to(equal("macos"))
                    #else
                    expect(props["platform"] as? String).to(equal("ios"))
                    #endif
                    expect(props["device_model"]).toNot(beNil())
                    expect(props["os_version"]).toNot(beNil())
                }
            }

            // MARK: - Retention

            describe("retention") {
                it("caps stored history at maxEventsStored") {
                    let cappedLog = EventLog(
                        identity: MockIdentityService(),
                        sessions: MockSessionService(),
                        dateProvider: MockDateProvider(),
                        apiClient: mockApi,
                        store: mockStore,
                        maxEventsStored: 3,
                        cleanupThresholdDays: 30,
                        cleanupCheckInterval: 1
                    )
                    try await cappedLog.configure(configuration: testConfig)

                    for i in 1...5 {
                        await cappedLog.storePreparedEventInHistory(
                            NuxieEvent(name: "cleanup_event_\(i)", distinctId: "user1")
                        )
                    }

                    // Every insert checks the cap (interval 1); delivered rows
                    // over the cap are reaped oldest-first.
                    expect(mockStore.storedEvents.count).to(equal(3))

                    await cappedLog.close()
                }

                it("never reaps rows still pending delivery") {
                    let cappedLog = EventLog(
                        identity: MockIdentityService(),
                        sessions: MockSessionService(),
                        dateProvider: MockDateProvider(),
                        apiClient: mockApi,
                        store: mockStore,
                        maxEventsStored: 2,
                        cleanupThresholdDays: 30,
                        cleanupCheckInterval: 1
                    )
                    try await cappedLog.configure(configuration: testConfig)

                    // Committed events persist as pending (undelivered).
                    cappedLog.track("pending_1", properties: nil, userProperties: nil, userPropertiesSetOnce: nil)
                    cappedLog.track("pending_2", properties: nil, userProperties: nil, userPropertiesSetOnce: nil)
                    cappedLog.track("pending_3", properties: nil, userProperties: nil, userPropertiesSetOnce: nil)
                    await cappedLog.drain()

                    let names = mockStore.storedEvents.map(\.name)
                    expect(names).to(contain("pending_1", "pending_2", "pending_3"))

                    await cappedLog.close()
                }
            }
        }
    }
}

// MARK: - Test helpers

private actor ReceivedEvents {
    private(set) var names: [String] = []
    func append(_ name: String) {
        names.append(name)
    }
}

private actor PersistenceProbe {
    private var persistedFlags: [Bool] = []
    private var pendingFlags: [Bool] = []

    func record(persisted: Bool, pending: Bool) {
        persistedFlags.append(persisted)
        pendingFlags.append(pending)
    }

    var allPersisted: Bool { !persistedFlags.isEmpty && persistedFlags.allSatisfy { $0 } }
    var allPending: Bool { !pendingFlags.isEmpty && pendingFlags.allSatisfy { $0 } }
}
