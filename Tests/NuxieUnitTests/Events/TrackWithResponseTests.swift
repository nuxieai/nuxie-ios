import FactoryKit
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

            // Register test configuration (required for any services that depend on sdkConfiguration)
            testConfig = NuxieConfiguration(apiKey: "test-api-key")
            testConfig.flushAt = 5
            Container.shared.sdkConfiguration.register { testConfig }

            // Create mock services
            mockEventStore = MockEventStore()
            mockIdentityService = MockIdentityService()
            mockNuxieApi = MockNuxieApi()
            mockSessionService = TrackWithResponseMockSessionService()

            // Register mocks with DI container
            Container.shared.identityService.register { mockIdentityService }
            Container.shared.nuxieApi.register { mockNuxieApi }
            Container.shared.sessionService.register { mockSessionService }
            Container.shared.dateProvider.register { MockDateProvider() }

            // Create event log with mock event store
            eventLog = EventLog(store: mockEventStore)
        }

        afterEach {
            await eventLog?.close()
            await mockNuxieApi?.reset()
            mockEventStore.resetMock()
            mockIdentityService.reset()
            // Don't reset container here - let beforeEach handle it
            // to avoid race conditions with background tasks accessing services
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
                        "$journey_node_executed",
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
                        "$journey_node_executed",
                        properties: ["node_id": "node-1"]
                    )

                    // Then
                    expect(mockEventStore.storedEvents).to(haveCount(1))
                    expect(mockEventStore.storedEvents.first?.name).to(equal("$journey_node_executed"))
                }

                it("sends correct event name and properties to API") {
                    // Given
                    await mockNuxieApi.setTrackEventResponse(.success())

                    // When
                    _ = try await eventLog.trackWithResponse(
                        "$journey_completed",
                        properties: [
                            "session_id": "session-123",
                            "exit_reason": "completed"
                        ]
                    )

                    // Then
                    let callCount = await mockNuxieApi.trackEventCallCount
                    expect(callCount).to(equal(1))
                    let lastCall = await mockNuxieApi.lastTrackEventCall
                    expect(lastCall?.event).to(equal("$journey_completed"))
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
                        "$journey_node_executed",
                        properties: nil
                    )

                    // Then - flush should have been called (network queue processes pending)
                    // The trackWithResponse event should be the last one sent to API
                    let lastCall = await mockNuxieApi.lastTrackEventCall
                    expect(lastCall?.event).to(equal("$journey_node_executed"))
                }

                it("flushes a routed triggering event before sending its journey start") {
                    let batchConfig = NuxieConfiguration(apiKey: "test-api-key")
                    batchConfig.flushAt = 100
                    batchConfig.eventBatchSize = 2
                    let batchedEventLog = EventLog(store: mockEventStore)
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
                        "$journey_start"
                    ]))
                }

                it("flushes queued identify before a routed journey start") {
                    let batchConfig = NuxieConfiguration(apiKey: "test-api-key")
                    batchConfig.flushAt = 100
                    batchConfig.eventBatchSize = 10
                    let routedEventLog = EventLog(store: mockEventStore)
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
                        "$journey_start"
                    ]))
                    expect(sentEvents.map(\.distinctId)).to(equal([
                        "anon-1",
                        "user-1",
                        "user-1"
                    ]))
                }

                it("preserves buffered tracks from before configure before a routed journey start") {
                    let batchConfig = NuxieConfiguration(apiKey: "test-api-key")
                    batchConfig.flushAt = 100
                    batchConfig.eventBatchSize = 10
                    let bufferedEventLog = EventLog(store: mockEventStore)
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
                        "$journey_start"
                    ]))
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
                            "$journey_node_executed",
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
                        "$journey_node_executed",
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
                        "$journey_node_executed",
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
                        "$journey_node_executed",
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
                        "$journey_start",
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
                        "$journey_node_executed",
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
                        "$journey_node_executed",
                        properties: nil
                    )

                    // Then
                    let lastCall = await mockNuxieApi.lastTrackEventCall
                    expect(lastCall?.distinctId).to(equal("user-123"))
                }
            }
        }
    }
}

// MARK: - Mock Session Service

class TrackWithResponseMockSessionService: SessionServiceProtocol {
    var mockSessionId: String? = "mock-session"
    var touchCallCount = 0

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
        touchCallCount += 1
    }

    func resetSession() {
        mockSessionId = "mock-session"
        touchCallCount = 0
    }

    func reset() {
        mockSessionId = "mock-session"
        touchCallCount = 0
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
            "$journey_start",
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
