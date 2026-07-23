import Foundation
import Nimble
import Quick

@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

final class TrackWithResponseTests: AsyncSpec {

    override class func spec() {
        var eventLog: EventLog!
        var mockEventStore: MockEventStore!
        var mockIdentityService: MockIdentityService!
        var mockNuxieApi: MockNuxieApi!
        var mockSessionService: TrackWithResponseMockSessionService!
        var testConfig: NuxieConfiguration!

        beforeEach {

            testConfig = NuxieConfiguration(apiKey: "test-api-key")
            testConfig.flushAt = 5

            // Create mock services
            mockEventStore = MockEventStore()
            mockIdentityService = MockIdentityService()
            mockNuxieApi = MockNuxieApi()
            mockSessionService = TrackWithResponseMockSessionService()

            // Create event log with mock event store
            eventLog = EventLog(
                identity: mockIdentityService,
                sessions: mockSessionService,
                dateProvider: MockDateProvider(),
                apiClient: mockNuxieApi,
                store: mockEventStore
            )
        }

        afterEach {
            await eventLog?.close()
            await mockNuxieApi?.reset()
            mockEventStore.resetMock()
            mockIdentityService.reset()
        }

        describe("trackWithResponse") {

            beforeEach {
                // Configure event log before each test
                try await eventLog.configure(configuration: testConfig)
            }

            // MARK: - Basic Functionality

            context("basic functionality") {
                it("returns server response on success") {
                    // Given
                    let expectedResponse = EventResponse.withExecution(success: true)
                    await mockNuxieApi.setTrackEventResponse(expectedResponse)

                    // When
                    let response = try await eventLog.trackWithResponse(
                        "$journey_transition",
                        properties: ["session_id": "test-session"]
                    )

                    // Then
                    expect(response.status).to(equal("ok"))
                    expect(response.execution?.success).to(beTrue())
                }

                it("stores event locally for history") {
                    // Given
                    await mockNuxieApi.setTrackEventResponse(.success())

                    // When
                    _ = try await eventLog.trackWithResponse(
                        "$journey_transition",
                        properties: ["node_id": "node-1"]
                    )

                    // Then
                    expect(mockEventStore.storedEvents).to(haveCount(1))
                    expect(mockEventStore.storedEvents.first?.name).to(equal("$journey_transition"))
                }

                it("sends correct event name and properties to API") {
                    // Given
                    await mockNuxieApi.setTrackEventResponse(.success())

                    // When
                    _ = try await eventLog.trackWithResponse(
                        "$journey_exited",
                        properties: [
                            "session_id": "session-123",
                            "exit_reason": "completed"
                        ]
                    )

                    // Then
                    let callCount = await mockNuxieApi.trackEventCallCount
                    expect(callCount).to(equal(1))
                    let lastCall = await mockNuxieApi.lastTrackEventCall
                    expect(lastCall?.event).to(equal("$journey_exited"))
                    expect(lastCall?.properties?["session_id"] as? String).to(equal("session-123"))
                    expect(lastCall?.properties?["exit_reason"] as? String).to(equal("completed"))
                }
            }

            // MARK: - Queue Flush Behavior

            context("queue flush behavior") {
                it("flushes pending events before sending") {
                    // Given - queue some events first
                    eventLog.track("event_1", properties: nil, userProperties: nil, userPropertiesSetOnce: nil)
                    eventLog.track("event_2", properties: nil, userProperties: nil, userPropertiesSetOnce: nil)
                    await eventLog.drain() // Wait for them to be queued

                    await mockNuxieApi.setTrackEventResponse(.success())

                    // When
                    _ = try await eventLog.trackWithResponse(
                        "$journey_transition",
                        properties: nil
                    )

                    // Then - flush should have been called (network queue processes pending)
                    // The trackWithResponse event should be the last one sent to API
                    let lastCall = await mockNuxieApi.lastTrackEventCall
                    expect(lastCall?.event).to(equal("$journey_transition"))
                }

                it("flushes a routed triggering event before sending its journey start") {
                    let batchConfig = NuxieConfiguration(apiKey: "test-api-key")
                    batchConfig.flushAt = 100
                    batchConfig.eventBatchSize = 2
                    let batchedEventLog = EventLog(
                        identity: mockIdentityService,
                        sessions: mockSessionService,
                        dateProvider: MockDateProvider(),
                        apiClient: mockNuxieApi,
                        store: mockEventStore
                    )
                    let routingJourneyService = RoutingJourneyStartService(eventLog: batchedEventLog)
                    await batchedEventLog.subscribeCommitted { event in
                        await routingJourneyService.handleEvent(event)
                    }
                    try await batchedEventLog.configure(configuration: batchConfig)
                    let eventLog = batchedEventLog

                    for index in 0..<5 {
                        eventLog.track("backlog_\(index)", properties: nil, userProperties: nil, userPropertiesSetOnce: nil)
                    }
                    await eventLog.drain()

                    await mockNuxieApi.setTrackEventResponse(.success())

                    eventLog.track("paywall_trigger", properties: nil, userProperties: nil, userPropertiesSetOnce: nil)
                    await eventLog.drain()

                    let sentEventNames = await mockNuxieApi.sentEvents.map(\.name)
                    expect(sentEventNames).to(equal([
                        "backlog_0",
                        "backlog_1",
                        "backlog_2",
                        "backlog_3",
                        "backlog_4",
                        "paywall_trigger",
                        "$journey_enrolled"
                    ]))

                    await batchedEventLog.close()
                }

                it("flushes queued identify before a routed journey start") {
                    let batchConfig = NuxieConfiguration(apiKey: "test-api-key")
                    batchConfig.flushAt = 100
                    batchConfig.eventBatchSize = 10
                    let routedEventLog = EventLog(
                        identity: mockIdentityService,
                        sessions: mockSessionService,
                        dateProvider: MockDateProvider(),
                        apiClient: mockNuxieApi,
                        store: mockEventStore
                    )
                    let routingJourneyService = RoutingJourneyStartService(
                        eventLog: routedEventLog,
                        delayBeforeJourneyStartNanoseconds: 20_000_000
                    )
                    await routedEventLog.subscribeCommitted { event in
                        await routingJourneyService.handleEvent(event)
                    }
                    try await routedEventLog.configure(configuration: batchConfig)
                    let eventLog = routedEventLog
                    await mockNuxieApi.setTrackEventResponse(.success())

                    mockIdentityService.reset(keepAnonymousId: false)
                    mockIdentityService.setAnonymousId("anon-1")

                    eventLog.track("paywall_trigger", properties: nil, userProperties: nil, userPropertiesSetOnce: nil)

                    mockIdentityService.setDistinctId("user-1")
                    eventLog.track(
                        "$identify",
                        properties: [
                            "distinct_id": "user-1",
                            "$anon_distinct_id": "anon-1"
                        ],
                        userProperties: nil,
                        userPropertiesSetOnce: nil
                    )
                    await eventLog.drain()

                    let sentEvents = await mockNuxieApi.sentEvents
                    expect(sentEvents.map(\.name)).to(equal([
                        "paywall_trigger",
                        "$identify",
                        "$journey_enrolled"
                    ]))
                    expect(sentEvents.map(\.distinctId)).to(equal([
                        "anon-1",
                        "user-1",
                        "user-1"
                    ]))

                    await routedEventLog.close()
                }

                it("preserves buffered tracks from before configure before a routed journey start") {
                    let batchConfig = NuxieConfiguration(apiKey: "test-api-key")
                    batchConfig.flushAt = 100
                    batchConfig.eventBatchSize = 10
                    let bufferedEventLog = EventLog(
                        identity: mockIdentityService,
                        sessions: mockSessionService,
                        dateProvider: MockDateProvider(),
                        apiClient: mockNuxieApi,
                        store: mockEventStore
                    )
                    let routingJourneyService = RoutingJourneyStartService(eventLog: bufferedEventLog)
                    await mockNuxieApi.setTrackEventResponse(.success())

                    bufferedEventLog.track("startup_event", properties: nil, userProperties: nil, userPropertiesSetOnce: nil)
                    await bufferedEventLog.subscribeCommitted { event in
                        await routingJourneyService.handleEvent(event)
                    }
                    try await bufferedEventLog.configure(configuration: batchConfig)

                    bufferedEventLog.track("paywall_trigger", properties: nil, userProperties: nil, userPropertiesSetOnce: nil)
                    await bufferedEventLog.drain()

                    let sentEventNames = await mockNuxieApi.sentEvents.map(\.name)
                    expect(sentEventNames).to(equal([
                        "startup_event",
                        "paywall_trigger",
                        "$journey_enrolled"
                    ]))

                    await bufferedEventLog.close()
                }
            }

            // MARK: - Error Handling

            context("error handling") {
                it("throws error on network failure") {
                    // Given
                    await mockNuxieApi.configureTrackEventFailure(error: URLError(.notConnectedToInternet))

                    // When/Then
                    await expect {
                        try await eventLog.trackWithResponse(
                            "$journey_transition",
                            properties: nil
                        )
                    }.to(throwError())
                }

                it("throws error for empty event name") {
                    // When/Then
                    await expect {
                        try await eventLog.trackWithResponse(
                            "",
                            properties: nil
                        )
                    }.to(throwError(NuxieError.invalidConfiguration("Event name cannot be empty")))
                }

                it("continues even if local storage fails") {
                    // Given
                    mockEventStore.shouldFailStore = true
                    await mockNuxieApi.setTrackEventResponse(.success())

                    // When - should not throw even though storage fails
                    let response = try await eventLog.trackWithResponse(
                        "$journey_transition",
                        properties: nil
                    )

                    // Then - API call should still succeed
                    expect(response.status).to(equal("ok"))
                }
            }

            // MARK: - Response Parsing

            context("response parsing") {
                it("parses execution result from response") {
                    // Given
                    let response = EventResponse.withExecution(
                        success: true,
                        statusCode: 200,
                        contextUpdates: ["key": AnyCodable("value")]
                    )
                    await mockNuxieApi.setTrackEventResponse(response)

                    // When
                    let result = try await eventLog.trackWithResponse(
                        "$journey_transition",
                        properties: nil
                    )

                    // Then
                    expect(result.execution?.success).to(beTrue())
                    expect(result.execution?.statusCode).to(equal(200))
                    expect(result.execution?.contextUpdates?["key"]?.value as? String).to(equal("value"))
                }

                it("parses retryable error from response") {
                    // Given
                    let response = EventResponse.withRetryableError(
                        message: "Rate limited",
                        retryAfter: 30
                    )
                    await mockNuxieApi.setTrackEventResponse(response)

                    // When
                    let result = try await eventLog.trackWithResponse(
                        "$journey_transition",
                        properties: nil
                    )

                    // Then
                    expect(result.execution?.success).to(beFalse())
                    expect(result.execution?.error?.retryable).to(beTrue())
                    expect(result.execution?.error?.retryAfter).to(equal(30))
                }

                it("parses journey info from response") {
                    // Given
                    let response = EventResponse.withJourney(
                        sessionId: "session-abc",
                        currentNodeId: "node-2",
                        status: "active"
                    )
                    await mockNuxieApi.setTrackEventResponse(response)

                    // When
                    let result = try await eventLog.trackWithResponse(
                        "$journey_enrolled",
                        properties: nil
                    )

                    // Then
                    expect(result.journey?.sessionId).to(equal("session-abc"))
                    expect(result.journey?.currentNodeId).to(equal("node-2"))
                    expect(result.journey?.status).to(equal("active"))
                }
            }

            // MARK: - Session and Identity

            context("session and identity") {
                it("includes session ID in properties") {
                    // Given
                    mockSessionService.mockSessionId = "test-session-id"
                    await mockNuxieApi.setTrackEventResponse(.success())

                    // When
                    _ = try await eventLog.trackWithResponse(
                        "$journey_transition",
                        properties: ["node_id": "node-1"]
                    )

                    // Then
                    let lastCall = await mockNuxieApi.lastTrackEventCall
                    expect(lastCall?.properties?["$session_id"] as? String).to(equal("test-session-id"))
                }

                it("uses current distinct ID") {
                    // Given
                    mockIdentityService.setDistinctId("user-123")
                    await mockNuxieApi.setTrackEventResponse(.success())

                    // When
                    _ = try await eventLog.trackWithResponse(
                        "$journey_transition",
                        properties: nil
                    )

                    // Then
                    let lastCall = await mockNuxieApi.lastTrackEventCall
                    expect(lastCall?.distinctId).to(equal("user-123"))
                }
            }
        }

        // MARK: - trackForTrigger (local-first synchronous trigger path)

        describe("trackForTrigger") {

            beforeEach {
                try await eventLog.configure(configuration: testConfig)
            }

            context("online") {
                it("persists the event pending and acks it after the direct round trip succeeds") {
                    await mockNuxieApi.setTrackEventResponse(.success())

                    let (event, response) = try await eventLog.trackForTrigger(
                        "trigger_event",
                        properties: ["screen": "home"]
                    )

                    expect(response.status).to(equal("ok"))

                    // One durable row, acked by the direct delivery so the
                    // batch path never re-sends it.
                    let rows = mockEventStore.storedEvents.filter { $0.name == "trigger_event" }
                    expect(rows).to(haveCount(1))
                    expect(rows.first?.id).to(equal(event.id))
                    expect(mockEventStore.pendingIds).toNot(contain(event.id))
                    expect(mockEventStore.deliveredIds).to(contain(event.id))
                    await expect { await eventLog.getQueuedEventCount() }.to(equal(0))
                }
            }

            context("offline (transport failure)") {
                it("degrades to a local result instead of throwing") {
                    await mockNuxieApi.configureTrackEventFailure(
                        error: URLError(.notConnectedToInternet)
                    )

                    let (event, response) = try await eventLog.trackForTrigger(
                        "trigger_event",
                        properties: ["screen": "home"]
                    )

                    // The degraded response carries no gate plan: callers
                    // evaluate journeys/segments from the local event.
                    expect(response.status).to(equal("offline"))
                    expect(response.gatePlan()).to(beNil())
                    expect(response.eventId).to(equal(event.id))
                    expect(event.name).to(equal("trigger_event"))
                    expect(event.properties["screen"] as? String).to(equal("home"))
                }

                it("keeps the event pending and staged for durable batch delivery") {
                    await mockNuxieApi.configureTrackEventFailure(
                        error: URLError(.notConnectedToInternet)
                    )

                    let (event, _) = try await eventLog.trackForTrigger(
                        "trigger_event",
                        properties: nil
                    )

                    // Persisted pending (never falsely acked) and queued for
                    // redelivery.
                    expect(mockEventStore.pendingIds).to(contain(event.id))
                    expect(mockEventStore.deliveredIds).toNot(contain(event.id))
                    await expect { await eventLog.getQueuedEventCount() }.to(equal(1))
                }

                it("redelivers the event over the batch path and acks it when the transport returns") {
                    await mockNuxieApi.configureTrackEventFailure(
                        error: URLError(.notConnectedToInternet)
                    )
                    let (event, _) = try await eventLog.trackForTrigger(
                        "trigger_event",
                        properties: nil
                    )

                    await mockNuxieApi.reset()
                    let flushed = await eventLog.flushEvents()

                    expect(flushed).to(beTrue())
                    await expect { await mockNuxieApi.sentEvents.map(\.name) }
                        .to(contain("trigger_event"))
                    expect(mockEventStore.deliveredIds).to(contain(event.id))
                    expect(mockEventStore.pendingIds).toNot(contain(event.id))
                    await expect { await eventLog.getQueuedEventCount() }.to(equal(0))
                }

                it("does not persist or stage anything when persistToHistory is false") {
                    await mockNuxieApi.configureTrackEventFailure(
                        error: URLError(.notConnectedToInternet)
                    )

                    let (event, response) = try await eventLog.trackForTrigger(
                        "scoped_event",
                        properties: nil,
                        userProperties: nil,
                        userPropertiesSetOnce: nil,
                        persistToHistory: false,
                        distinctIdOverride: nil
                    )

                    expect(response.status).to(equal("offline"))
                    expect(mockEventStore.storedEvents.map(\.name)).toNot(contain("scoped_event"))
                    expect(mockEventStore.pendingIds).toNot(contain(event.id))
                    await expect { await eventLog.getQueuedEventCount() }.to(equal(0))
                }
            }
        }
    }
}

// MARK: - Mock Session Service

final class TrackWithResponseMockSessionService: SessionServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _mockSessionId: String? = "mock-session"
    private var _touchCallCount = 0

    var mockSessionId: String? {
        get { lock.withLock { _mockSessionId } }
        set { lock.withLock { _mockSessionId = newValue } }
    }
    var touchCallCount: Int {
        lock.withLock { _touchCallCount }
    }

    func getSessionId(at date: Date, readOnly: Bool) -> String? {
        return mockSessionId
    }


    func setSessionId(_ sessionId: String) {
        mockSessionId = sessionId
    }

    func startSession() {
        mockSessionId = "new-session"
    }

    func touchSession() {
        lock.withLock { _touchCallCount += 1 }
    }

    func resetSession() {
        lock.withLock {
            _mockSessionId = "mock-session"
            _touchCallCount = 0
        }
    }

    func reset() {
        lock.withLock {
            _mockSessionId = "mock-session"
            _touchCallCount = 0
        }
    }

    func endSession() {
        mockSessionId = nil
    }

    func onAppDidEnterBackground() {
        // No-op for tests
    }

    func onAppBecameActive() {
        // No-op for tests
    }
}

private final class RoutingJourneyStartService: JourneyServiceProtocol {
    private let eventLog: EventLogProtocol
    private let delayBeforeJourneyStartNanoseconds: UInt64

    init(eventLog: EventLogProtocol, delayBeforeJourneyStartNanoseconds: UInt64 = 0) {
        self.eventLog = eventLog
        self.delayBeforeJourneyStartNanoseconds = delayBeforeJourneyStartNanoseconds
    }

    func startJourney(for campaign: Campaign, distinctId: String, originEventId: String?) async -> Journey? {
        nil
    }

    func resumeJourney(_ journey: Journey) async {}


    func handleEvent(_ event: NuxieEvent) async {
        guard event.name == "paywall_trigger" else { return }

        if delayBeforeJourneyStartNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayBeforeJourneyStartNanoseconds)
        }
        _ = try? await eventLog.trackWithResponse(
            "$journey_enrolled",
            properties: ["origin_event_id": event.id],
            flushStrategy: .eventLog
        )
    }

    func handleEventForTrigger(_ event: NuxieEvent) async -> [JourneyTriggerResult] {
        []
    }

    func handleSegmentChange(distinctId: String, segments: Set<String>) async {}

    func getActiveJourneys(for distinctId: String) async -> [Journey] {
        []
    }

    func checkExpiredTimers() async {}

    func initialize() async {}

    func onAppWillEnterForeground() async {}

    func onAppBecameActive() async {}

    func onAppDidEnterBackground() async {}

    func shutdown() async {}

    func handleUserChange(from oldDistinctId: String, to newDistinctId: String) async {}
}
