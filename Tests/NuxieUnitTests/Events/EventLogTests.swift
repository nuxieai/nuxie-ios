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
            var mockIdentity: MockIdentityService!
            var testConfig: NuxieConfiguration!

            beforeEach {
                testConfig = NuxieConfiguration(apiKey: "test-api-key")
                testConfig.flushAt = 100  // manual flush only

                mockStore = MockEventStore()
                mockApi = MockNuxieApi()
                mockIdentity = MockIdentityService()

                log = EventLog(
                    identity: mockIdentity,
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

            describe("mock prepared-trigger isolation") {
                it("cancels delayed response signals when the mock resets") {
                    let mock = MockEventLog()
                    let priorSignals = SignalCount()
                    let nextSignals = SignalCount()
                    await mock.setMailboxPendingHandler {
                        await priorSignals.increment()
                    }
                    mock.trackForTriggerDelayNanoseconds = 2_000_000_000
                    mock.trackWithResponseResult = EventResponse(
                        status: "ok",
                        mailboxPending: true
                    )

                    let committed = await mock.commitPreparedTriggerEvent(
                        NuxieEvent(
                            id: "prepared-before-reset",
                            name: "prepared_before_reset",
                            distinctId: "user-before-reset"
                        )
                    )
                    mock.reset()
                    await mock.setMailboxPendingHandler {
                        await nextSignals.increment()
                    }

                    _ = await committed.response.value
                    await expect { await priorSignals.value }.to(equal(0))
                    await expect { await nextSignals.value }.to(equal(0))
                }

                it("keeps a commit suspended across reset in the old generation") {
                    let mock = MockEventLog()
                    let routeGate = AsyncTestGate()
                    let nextSignals = SignalCount()
                    await mock.subscribeCommitted { _ in
                        await routeGate.suspendUntilReleased()
                    }
                    mock.trackWithResponseResult = EventResponse(
                        status: "ok",
                        mailboxPending: true
                    )

                    let commitTask = Task {
                        await mock.commitPreparedTriggerEvent(
                            NuxieEvent(
                                id: "prepared-suspended-before-reset",
                                name: "prepared_suspended_before_reset",
                                distinctId: "user-before-reset"
                            )
                        )
                    }
                    await routeGate.waitUntilSuspended()
                    mock.reset()
                    await mock.setMailboxPendingHandler {
                        await nextSignals.increment()
                    }
                    await routeGate.release()

                    let committed = await commitTask.value
                    _ = await committed.response.value
                    await expect { await nextSignals.value }.to(equal(0))
                }
            }

            describe("prepared trigger delivery") {
                it("applies beforeSend before an authored event is committed") {
                    testConfig.beforeSend = { event in
                        guard event.name != "dropped_authored" else { return nil }
                        return NuxieEvent(
                            id: event.id,
                            name: event.name,
                            distinctId: event.distinctId,
                            properties: ["redacted": true],
                            timestamp: event.timestamp
                        )
                    }
                    try await log.configure(configuration: testConfig)

                    let dropped = await log.applyBeforeSend(
                        to: NuxieEvent(
                            id: "dropped-authored-id",
                            name: "dropped_authored",
                            distinctId: mockIdentity.getDistinctId(),
                            properties: ["secret": "must-not-persist"]
                        )
                    )
                    expect(dropped).to(beNil())

                    let transformed = await log.applyBeforeSend(
                        to: NuxieEvent(
                            id: "kept-authored-id",
                            name: "kept_authored",
                            distinctId: mockIdentity.getDistinctId(),
                            properties: ["secret": "must-be-redacted"]
                        )
                    )
                    guard let transformed else {
                        fail("expected beforeSend to retain the authored event")
                        return
                    }
                    let committed = await log.commitPreparedTriggerEvent(
                        transformed
                    )

                    let stored = mockStore.storedEvents.first {
                        $0.id == "kept-authored-id"
                    }
                    expect(stored?.getPropertiesDict()["redacted"] as? Bool)
                        .to(beTrue())
                    expect(stored?.getPropertiesDict()["secret"]).to(beNil())
                    _ = await committed.response.value
                }

                it("applies authored user-property directives to local identity") {
                    try await log.configure(configuration: testConfig)
                    mockIdentity.setUserProperty("plan", value: "free")

                    let committed = await log.commitPreparedTriggerEvent(
                        NuxieEvent(
                            id: "authored-user-properties",
                            name: "authored_user_properties",
                            distinctId: mockIdentity.getDistinctId(),
                            properties: [
                                "$set": ["plan": "pro"],
                                "$set_once": ["cohort": "early"],
                            ]
                        )
                    )

                    let properties = mockIdentity.getUserProperties()
                    expect(properties["plan"] as? String).to(equal("pro"))
                    expect(properties["cohort"] as? String).to(equal("early"))
                    _ = await committed.response.value
                }

                it("commits every earlier capture before the authored event") {
                    try await log.configure(configuration: testConfig)

                    log.track(
                        "captured_first",
                        properties: nil,
                        userProperties: nil,
                        userPropertiesSetOnce: nil
                    )
                    let committed = await log.commitPreparedTriggerEvent(
                        NuxieEvent(
                            id: "authored-second",
                            name: "authored_second",
                            distinctId: "test-distinct-id"
                        )
                    )

                    expect(mockStore.storedEvents.map(\.name).prefix(2))
                        .to(equal(["captured_first", "authored_second"]))
                    _ = await committed.response.value
                }

                it("delivers prepared authored events to the server in commit order") {
                    let transport = OrderedPreparedEventTransport()
                    let orderedLog = EventLog(
                        identity: MockIdentityService(),
                        sessions: MockSessionService(),
                        dateProvider: MockDateProvider(),
                        apiClient: transport,
                        store: mockStore
                    )
                    log = orderedLog
                    try await orderedLog.configure(configuration: testConfig)

                    let first = await orderedLog.commitPreparedTriggerEvent(
                        NuxieEvent(
                            id: "prepared-first-id",
                            name: "prepared_first",
                            distinctId: "test-distinct-id"
                        )
                    )
                    await transport.waitUntilFirstStarted()
                    let second = await orderedLog.commitPreparedTriggerEvent(
                        NuxieEvent(
                            id: "prepared-second-id",
                            name: "prepared_second",
                            distinctId: "test-distinct-id"
                        )
                    )

                    try await Task.sleep(nanoseconds: 100_000_000)
                    await expect { await transport.startedNames }
                        .to(equal(["prepared_first"]))

                    await transport.releaseFirst()
                    _ = await first.response.value
                    _ = await second.response.value
                    await expect { await transport.startedNames }
                        .to(equal(["prepared_first", "prepared_second"]))
                }

                it("keeps a direct trigger behind an in-flight authored delivery") {
                    let transport = OrderedPreparedEventTransport()
                    let orderedLog = EventLog(
                        identity: MockIdentityService(),
                        sessions: MockSessionService(),
                        dateProvider: MockDateProvider(),
                        apiClient: transport,
                        store: mockStore
                    )
                    log = orderedLog
                    try await orderedLog.configure(configuration: testConfig)

                    let first = await orderedLog.commitPreparedTriggerEvent(
                        NuxieEvent(
                            id: "prepared-first-id",
                            name: "prepared_first",
                            distinctId: "test-distinct-id"
                        )
                    )
                    await transport.waitUntilFirstStarted()
                    let second = Task {
                        try await orderedLog.trackForTrigger("direct_second")
                    }

                    try await Task.sleep(nanoseconds: 100_000_000)
                    await expect { await transport.startedNames }
                        .to(equal(["prepared_first"]))

                    await transport.releaseFirst()
                    _ = await first.response.value
                    let (_, response) = try await second.value
                    expect(response.status).to(equal("ok"))
                    await expect { await transport.startedNames }
                        .to(equal(["prepared_first", "direct_second"]))
                }

                it("keeps a trigger behind an in-flight durable system capture") {
                    mockStore.stableCaptureDelayNanoseconds = 300_000_000
                    try await log.configure(configuration: testConfig)

                    let capture = Task {
                        await log.captureSystemEvent(
                            "$purchase_completed",
                            properties: nil,
                            eventId: "durable-system-first",
                            distinctId: "test-distinct-id"
                        )
                    }
                    await expect { mockStore.stableCaptureCommitCallCount }
                        .toEventually(equal(1))
                    let trigger = Task {
                        try await log.trackForTrigger("direct_second")
                    }

                    try await Task.sleep(nanoseconds: 100_000_000)
                    await expect { await mockApi.trackEventCallCount }.to(equal(0))

                    _ = await capture.value
                    let (_, response) = try await trigger.value
                    expect(response.status).to(equal("offline"))
                    await expect { await mockApi.trackEventCallCount }.to(equal(0))
                    await expect { await log.getQueuedEventCount() }.to(equal(2))
                }

                it("keeps a later durable system capture behind a direct trigger") {
                    let transport = OrderedPreparedEventTransport()
                    let orderedLog = EventLog(
                        identity: MockIdentityService(),
                        sessions: MockSessionService(),
                        dateProvider: MockDateProvider(),
                        apiClient: transport,
                        store: mockStore
                    )
                    log = orderedLog
                    try await orderedLog.configure(configuration: testConfig)

                    let trigger = Task {
                        try await orderedLog.trackForTrigger("prepared_first")
                    }
                    await transport.waitUntilFirstStarted()
                    let capture = Task {
                        await orderedLog.captureSystemEvent(
                            "$purchase_completed",
                            properties: nil,
                            eventId: "durable-system-second",
                            distinctId: "test-distinct-id"
                        )
                    }

                    try await Task.sleep(nanoseconds: 100_000_000)
                    expect(mockStore.stableCaptureCommitCallCount).to(equal(0))

                    await transport.releaseFirst()
                    _ = try await trigger.value
                    _ = await capture.value
                    expect(mockStore.stableCaptureCommitCallCount).to(equal(1))
                    await expect { await transport.startedNames }
                        .to(equal(["prepared_first"]))
                }

                it("allows a response callback to track a control event") {
                    try await log.configure(configuration: testConfig)
                    await mockApi.setTrackEventResponse(
                        EventResponse(status: "ok", mailboxPending: true)
                    )
                    let reentrantLog = log!
                    let reentrantApi = mockApi!
                    await reentrantLog.setMailboxPendingHandler {
                        await reentrantApi.setTrackEventResponse(.success())
                        _ = try? await reentrantLog.trackForTrigger(
                            "$journey_claimed",
                            properties: nil,
                            userProperties: nil,
                            userPropertiesSetOnce: nil,
                            persistToHistory: true,
                            distinctIdOverride: "test-distinct-id"
                        )
                    }

                    let (_, response) = try await reentrantLog.trackForTrigger("direct_first")

                    expect(response.status).to(equal("ok"))
                    await expect { await mockApi.trackEventCallCount }.to(equal(2))
                    await expect { await log.getQueuedEventCount() }.to(equal(0))
                }

                it("does not deadlock a prepared callback behind a waiting trigger") {
                    let transport = OrderedPreparedEventTransport(
                        mailboxPendingForFirst: true
                    )
                    let orderedLog = EventLog(
                        identity: MockIdentityService(),
                        sessions: MockSessionService(),
                        dateProvider: MockDateProvider(),
                        apiClient: transport,
                        store: mockStore
                    )
                    log = orderedLog
                    try await orderedLog.configure(configuration: testConfig)
                    await orderedLog.setMailboxPendingHandler {
                        _ = try? await orderedLog.trackForTrigger(
                            "$journey_claimed",
                            properties: nil,
                            userProperties: nil,
                            userPropertiesSetOnce: nil,
                            persistToHistory: true,
                            distinctIdOverride: "test-distinct-id"
                        )
                    }

                    let first = await orderedLog.commitPreparedTriggerEvent(
                        NuxieEvent(
                            id: "prepared-first-id",
                            name: "prepared_first",
                            distinctId: "test-distinct-id"
                        )
                    )
                    await transport.waitUntilFirstStarted()
                    let second = Task {
                        try await orderedLog.trackForTrigger("direct_second")
                    }

                    await transport.releaseFirst()
                    _ = try await second.value
                    _ = await first.response.value
                    await expect { await transport.startedNames }
                        .to(equal(["prepared_first", "direct_second", "$journey_claimed"]))
                }

                it("keeps later prepared events behind an older failed delivery") {
                    let transport = FailedPredecessorPreparedEventTransport()
                    let orderedLog = EventLog(
                        identity: MockIdentityService(),
                        sessions: MockSessionService(),
                        dateProvider: MockDateProvider(),
                        apiClient: transport,
                        store: mockStore
                    )
                    log = orderedLog
                    try await orderedLog.configure(configuration: testConfig)

                    let first = await orderedLog.commitPreparedTriggerEvent(
                        NuxieEvent(
                            id: "failed-prepared-first-id",
                            name: "failed_prepared_first",
                            distinctId: "test-distinct-id"
                        )
                    )
                    let second = await orderedLog.commitPreparedTriggerEvent(
                        NuxieEvent(
                            id: "deferred-prepared-second-id",
                            name: "deferred_prepared_second",
                            distinctId: "test-distinct-id"
                        )
                    )

                    let firstResponse = await first.response.value
                    let secondResponse = await second.response.value
                    expect(firstResponse.status).to(equal("offline"))
                    expect(secondResponse.status).to(equal("offline"))
                    await expect { await transport.directNames }
                        .to(equal(["failed_prepared_first"]))
                    await expect { await transport.batchNames }
                        .to(equal([["failed_prepared_first"]]))
                    expect(mockStore.pendingIds)
                        .to(contain("failed-prepared-first-id", "deferred-prepared-second-id"))
                }

                it("settles an in-flight authored delivery before closing its store") {
                    let transport = CancellableEventTransport()
                    let closingStore = MockEventStore()
                    let closingLog = EventLog(
                        identity: MockIdentityService(),
                        sessions: MockSessionService(),
                        dateProvider: MockDateProvider(),
                        apiClient: transport,
                        store: closingStore
                    )
                    try await closingLog.configure(configuration: testConfig)
                    let committed = await closingLog.commitPreparedTriggerEvent(
                        NuxieEvent(
                            id: "authored-during-close",
                            name: "authored_during_close",
                            distinctId: "test-distinct-id"
                        )
                    )
                    await transport.waitUntilTrackStarted()

                    await closingLog.close()

                    expect(closingStore.isClosed).to(beTrue())
                    await expect { await transport.wasCancelled }.to(beTrue())
                    let response = await committed.response.value
                    expect(response.status).to(equal("offline"))
                }

                it("keeps storage open while an authored commit is registering") {
                    let closingStore = MockEventStore()
                    closingStore.pendingInsertDelayNanoseconds = 300_000_000
                    let closingLog = EventLog(
                        identity: MockIdentityService(),
                        sessions: MockSessionService(),
                        dateProvider: MockDateProvider(),
                        apiClient: MockNuxieApi(),
                        store: closingStore
                    )
                    try await closingLog.configure(configuration: testConfig)
                    let commitTask = Task {
                        await closingLog.commitPreparedTriggerEvent(
                            NuxieEvent(
                                id: "authored-registering-during-close",
                                name: "authored_registering_during_close",
                                distinctId: "test-distinct-id"
                            )
                        )
                    }
                    await expect { closingStore.storeEventCallCount }
                        .toEventually(equal(1), timeout: .seconds(1))

                    let closeTask = Task { await closingLog.close() }
                    try await Task.sleep(nanoseconds: 50_000_000)
                    expect(closingStore.isClosed).to(beFalse())

                    let committed = await commitTask.value
                    await closeTask.value
                    expect(closingStore.isClosed).to(beTrue())
                    let response = await committed.response.value
                    expect(response.status).to(equal("offline"))
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

private actor SignalCount {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private actor AsyncTestGate {
    private var suspended = false
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func suspendUntilReleased() async {
        suspended = true
        suspensionWaiters.forEach { $0.resume() }
        suspensionWaiters.removeAll()
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilSuspended() async {
        guard !suspended else { return }
        await withCheckedContinuation { suspensionWaiters.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor CancellableEventTransport: EventTransport {
    private var trackStarted = false
    private var trackStartWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var wasCancelled = false

    func waitUntilTrackStarted() async {
        guard !trackStarted else { return }
        await withCheckedContinuation { trackStartWaiters.append($0) }
    }

    func sendBatch(events: [BatchEventItem]) async throws -> BatchResponse {
        BatchResponse(
            status: "success",
            processed: events.count,
            failed: 0,
            total: events.count,
            errors: nil
        )
    }

    func trackEvent(
        event: String,
        distinctId: String,
        properties: sending [String: Any]?,
        value: Double?,
        entityId: String?
    ) async throws -> EventResponse {
        try await suspendTrack(eventID: event)
    }

    func trackEvent(_ event: NuxieEvent) async throws -> EventResponse {
        try await suspendTrack(eventID: event.id)
    }

    private func suspendTrack(eventID: String) async throws -> EventResponse {
        trackStarted = true
        trackStartWaiters.forEach { $0.resume() }
        trackStartWaiters.removeAll()
        do {
            try await Task.sleep(nanoseconds: 30_000_000_000)
            return EventResponse(status: "ok", eventId: eventID)
        } catch {
            wasCancelled = true
            throw error
        }
    }
}

private actor OrderedPreparedEventTransport: EventTransport {
    private let mailboxPendingForFirst: Bool
    private var started: [String] = []
    private var firstStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstRelease: CheckedContinuation<Void, Never>?
    private var firstReleased = false

    init(mailboxPendingForFirst: Bool = false) {
        self.mailboxPendingForFirst = mailboxPendingForFirst
    }

    var startedNames: [String] { started }

    func waitUntilFirstStarted() async {
        guard started.contains("prepared_first") else {
            await withCheckedContinuation { firstStartWaiters.append($0) }
            return
        }
    }

    func releaseFirst() {
        firstReleased = true
        firstRelease?.resume()
        firstRelease = nil
    }

    func sendBatch(events: [BatchEventItem]) async throws -> BatchResponse {
        BatchResponse(
            status: "success",
            processed: events.count,
            failed: 0,
            total: events.count,
            errors: nil
        )
    }

    func trackEvent(
        event: String,
        distinctId: String,
        properties: sending [String: Any]?,
        value: Double?,
        entityId: String?
    ) async throws -> EventResponse {
        await track(name: event, id: event)
    }

    func trackEvent(_ event: NuxieEvent) async throws -> EventResponse {
        await track(name: event.name, id: event.id)
    }

    private func track(name: String, id: String) async -> EventResponse {
        started.append(name)
        if name == "prepared_first" {
            firstStartWaiters.forEach { $0.resume() }
            firstStartWaiters.removeAll()
            if !firstReleased {
                await withCheckedContinuation { firstRelease = $0 }
            }
        }
        return EventResponse(
            status: "ok",
            eventId: id,
            mailboxPending: name == "prepared_first" && mailboxPendingForFirst
        )
    }
}

private actor FailedPredecessorPreparedEventTransport: EventTransport {
    private(set) var directNames: [String] = []
    private(set) var batchNames: [[String]] = []

    func sendBatch(events: [BatchEventItem]) async throws -> BatchResponse {
        batchNames.append(events.map(\.event))
        throw URLError(.notConnectedToInternet)
    }

    func trackEvent(
        event: String,
        distinctId: String,
        properties: sending [String: Any]?,
        value: Double?,
        entityId: String?
    ) async throws -> EventResponse {
        directNames.append(event)
        throw URLError(.notConnectedToInternet)
    }

    func trackEvent(_ event: NuxieEvent) async throws -> EventResponse {
        directNames.append(event.name)
        throw URLError(.notConnectedToInternet)
    }
}
