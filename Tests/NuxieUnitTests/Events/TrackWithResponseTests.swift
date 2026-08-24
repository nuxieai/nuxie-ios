import Foundation
import Nimble
import Quick

@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

private final class BeforeSendCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

private final class CapturedEventTimestamp: @unchecked Sendable {
    private let lock = NSLock()
    private var timestamp: Date?

    func record(_ timestamp: Date) { lock.withLock { self.timestamp = timestamp } }
    var value: Date? { lock.withLock { timestamp } }
}

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
                    let expectedResponse = EventResponse.success()
                    await mockNuxieApi.setTrackEventResponse(expectedResponse)

                    // When
                    let response = try await eventLog.trackWithResponse(
                        "$journey_transition",
                        properties: ["session_id": "test-session"]
                    )

                    // Then
                    expect(response.status).to(equal("ok"))
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

                it("uses the journey identity for both the event and enriched identity property") {
                    mockIdentityService.setDistinctId("replacement-user")
                    await mockNuxieApi.setTrackEventResponse(.success())

                    _ = try await eventLog.trackWithResponse(
                        JourneyEvents.journeyTransition,
                        properties: ["journey_id": "journey-identity"],
                        flushStrategy: .none,
                        distinctIdOverride: "journey-user"
                    )

                    let sent = await mockNuxieApi.sentEvents.last
                    expect(sent?.distinctId).to(equal("journey-user"))
                    expect(sent?.properties["$distinct_id"] as? String)
                        .to(equal("journey-user"))
                    expect(mockEventStore.storedEvents.last?.distinctId)
                        .to(equal("journey-user"))
                    expect(
                        mockEventStore.storedEvents.last?
                            .getPropertiesDict()["$distinct_id"] as? String
                    ).to(equal("journey-user"))
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
                it("does not replay a failed synchronous enrollment later") {
                    // Given
                    await mockNuxieApi.configureTrackEventFailure(error: URLError(.notConnectedToInternet))

                    // When/Then
                    await expect {
                        try await eventLog.trackWithResponse(
                            JourneyEvents.journeyEnrolled,
                            properties: nil
                        )
                    }.to(throwError())

                    guard let source = mockEventStore.storedEvents.first else {
                        return fail("expected the failed enrollment in local history")
                    }
                    expect(mockEventStore.pendingIds).toNot(contain(source.id))
                    expect(mockEventStore.deliveredIds).to(contain(source.id))

                    await mockNuxieApi.reset()
                    _ = await eventLog.flushEvents()
                    let replayedEvents = await mockNuxieApi.sentEvents
                    expect(replayedEvents).to(beEmpty())
                    await expect { await eventLog.getQueuedEventCount() }.to(equal(0))
                }

                it("keeps a failed synchronous enrollment reserved when its terminal ack fails") {
                    mockEventStore.shouldFailMarkDelivered = true
                    await mockNuxieApi.configureTrackEventFailure(
                        error: URLError(.notConnectedToInternet)
                    )

                    await expect {
                        try await eventLog.trackWithResponse(
                            JourneyEvents.journeyEnrolled,
                            properties: nil
                        )
                    }.to(throwError())

                    guard let source = mockEventStore.storedEvents.first else {
                        return fail("expected the enrollment history source")
                    }
                    expect(mockEventStore.pendingIds).to(contain(source.id))
                    expect(mockEventStore.deliveredIds).toNot(contain(source.id))

                    await mockNuxieApi.reset()
                    _ = await eventLog.performFlush(forceSend: true)
                    await expect { await mockNuxieApi.sentEvents }.to(beEmpty())

                    mockEventStore.shouldFailMarkDelivered = false
                    _ = await eventLog.performFlush(forceSend: true)
                    expect(mockEventStore.pendingIds).toNot(contain(source.id))
                    expect(mockEventStore.deliveredIds).to(contain(source.id))
                    await expect { await mockNuxieApi.sentEvents }.to(beEmpty())
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

                it("blocks relaunch restore until the exact response source makes its ownership fence durable") {
                    let journeyId = "journey-fence-retry"
                    let epoch = 4
                    await mockNuxieApi.setTrackEventResponse(
                        EventResponse(
                            status: "ok",
                            journeyClaim: .init(
                                journeyId: journeyId,
                                accepted: false,
                                epoch: epoch,
                                reason: "epoch_mismatch"
                            )
                        )
                    )
                    mockEventStore.shouldFailOwnershipFenceRecord = true

                    await expect {
                        try await eventLog.trackWithResponse(
                            JourneyEvents.journeyTransition,
                            properties: [
                                "journey_id": journeyId,
                                "epoch": epoch,
                            ],
                            flushStrategy: .none
                        )
                    }.to(throwError(NuxieError.eventRoutingFailed))

                    let firstSends = await mockNuxieApi.sentEvents
                    guard let source = mockEventStore.storedEvents.first,
                          let firstSend = firstSends.first else {
                        return fail("expected the durable source and its first direct send")
                    }
                    expect(firstSend.id).to(equal(source.id))
                    expect(mockEventStore.pendingIds).to(contain(source.id))
                    expect(mockEventStore.deliveredIds).toNot(contain(source.id))
                    expect(mockEventStore.journeyOwnershipFences[journeyId]).to(beNil())
                    expect(
                        mockEventStore.unresolvedJourneyOwnershipResponses[source.id]
                    ).to(contain(JourneyEventOwnership(
                        journeyId: journeyId,
                        epoch: epoch
                    )))

                    // A fresh EventLog has no process-local fence. The durable
                    // unresolved marker must still fail closed until replay.
                    await eventLog.close()
                    eventLog = EventLog(
                        identity: mockIdentityService,
                        sessions: mockSessionService,
                        dateProvider: MockDateProvider(),
                        apiClient: mockNuxieApi,
                        store: mockEventStore
                    )
                    try await eventLog.configure(configuration: testConfig)
                    let unresolvedState = await eventLog.journeyEventOwnershipState(
                        JourneyEventOwnership(journeyId: journeyId, epoch: epoch)
                    )
                    expect(unresolvedState).to(equal(.unavailable))

                    let staleExitId = "journey-exited:\(journeyId):\(epoch)"
                    let staleExit = await eventLog.captureOwnedJourneySystemEvent(
                        JourneyEvents.journeyExited,
                        properties: ["journey_id": journeyId, "epoch": epoch],
                        eventId: staleExitId,
                        distinctId: source.distinctId,
                        ownership: JourneyEventOwnership(
                            journeyId: journeyId,
                            epoch: epoch
                        )
                    )
                    guard case .failed = staleExit else {
                        return fail(
                            "an unresolved response must keep the host exit retryable"
                        )
                    }
                    expect(mockEventStore.storedEvents.map(\.id))
                        .toNot(contain(staleExitId))
                    expect(mockEventStore.stableDroppedIds)
                        .toNot(contain(staleExitId))

                    // A poison response must not retire a source carrying an
                    // unresolved ownership fence.
                    await mockNuxieApi.reset()
                    await mockNuxieApi.configureTrackEventFailure(
                        error: NuxieNetworkError.httpError(
                            statusCode: 422,
                            message: "invalid"
                        )
                    )
                    let poisonDropped = await eventLog.flushEvents()
                    expect(poisonDropped).to(beFalse())
                    expect(mockEventStore.pendingIds).to(contain(source.id))
                    expect(mockEventStore.deliveredIds).toNot(contain(source.id))
                    expect(
                        mockEventStore.unresolvedJourneyOwnershipResponses[source.id]
                    ).toNot(beNil())

                    // The successful retry deliberately omits the original
                    // ownership signal. The durable source marker must replay
                    // that signal into the fence before the source is acked.
                    await mockNuxieApi.reset()
                    await mockNuxieApi.setTrackEventResponse(.success())
                    mockEventStore.shouldFailOwnershipFenceRecord = false
                    let replayed = await eventLog.flushEvents()

                    expect(replayed).to(beTrue())
                    let sends = await mockNuxieApi.sentEvents
                    expect(sends.map(\.id)).to(equal([source.id]))
                    expect(sends.map { $0.properties["journey_id"] as? String })
                        .to(equal([journeyId]))
                    expect(sends.map(\.timestamp))
                        .to(equal([source.timestamp]))
                    expect(mockEventStore.journeyOwnershipFences[journeyId]).to(equal(epoch))
                    expect(
                        mockEventStore.unresolvedJourneyOwnershipResponses[source.id]
                    ).to(beNil())
                    expect(mockEventStore.pendingIds).toNot(contain(source.id))
                    expect(mockEventStore.deliveredIds).to(contain(source.id))

                    let staleEpochCanAuthor = await eventLog.canAuthorJourneyEvents(
                        JourneyEventOwnership(journeyId: journeyId, epoch: epoch)
                    )
                    let newerEpochCanAuthor = await eventLog.canAuthorJourneyEvents(
                        JourneyEventOwnership(journeyId: journeyId, epoch: epoch + 1)
                    )
                    expect(staleEpochCanAuthor).to(beFalse())
                    expect(newerEpochCanAuthor).to(beTrue())
                }

                it("retries an unavailable ownership fence and completes the original direct source") {
                    let journeyId = "journey-fence-in-process-retry"
                    let epoch = 7
                    await mockNuxieApi.setTrackEventResponse(
                        EventResponse(
                            status: "ok",
                            journeyClaim: .init(
                                journeyId: journeyId,
                                accepted: false,
                                epoch: epoch,
                                reason: "epoch_mismatch"
                            )
                        )
                    )
                    mockEventStore.shouldFailOwnershipFenceRecord = true
                    mockEventStore.shouldFailUnresolvedJourneyOwnershipResponseRecord = true

                    await expect {
                        try await eventLog.trackWithResponse(
                            JourneyEvents.journeyTransition,
                            properties: ["journey_id": journeyId, "epoch": epoch],
                            flushStrategy: .none
                        )
                    }.to(throwError(NuxieError.eventRoutingFailed))

                    guard let source = mockEventStore.storedEvents.first else {
                        return fail("expected the persisted direct source")
                    }
                    mockEventStore.shouldFailOwnershipFenceRecord = false
                    mockEventStore.shouldFailUnresolvedJourneyOwnershipResponseRecord = false

                    await expect { mockEventStore.deliveredIds }
                        .toEventually(contain(source.id), timeout: .seconds(2))

                    expect(mockEventStore.pendingIds).toNot(contain(source.id))
                    expect(mockEventStore.journeyOwnershipFences[journeyId]).to(equal(epoch))
                    expect(mockEventStore.journeyOwnershipFenceWriteCount).to(equal(1))
                    expect(mockEventStore.unresolvedJourneyOwnershipResponses[source.id]).to(beNil())
                    await expect { await mockNuxieApi.trackEventCallCount }.to(equal(1))
                    await expect { await mockNuxieApi.sendBatchCallCount }.to(equal(0))
                }

                it("returns a persistently unavailable ownership-fence source to durable delivery") {
                    let journeyId = "journey-fence-retry-exhausted"
                    let epoch = 8
                    await mockNuxieApi.setTrackEventResponse(
                        EventResponse(
                            status: "ok",
                            journeyClaim: .init(
                                journeyId: journeyId,
                                accepted: false,
                                epoch: epoch,
                                reason: "epoch_mismatch"
                            )
                        )
                    )
                    mockEventStore.shouldFailOwnershipFenceRecord = true
                    mockEventStore.shouldFailUnresolvedJourneyOwnershipResponseRecord = true

                    await expect {
                        try await eventLog.trackWithResponse(
                            JourneyEvents.journeyTransition,
                            properties: ["journey_id": journeyId, "epoch": epoch],
                            flushStrategy: .none
                        )
                    }.to(throwError(NuxieError.eventRoutingFailed))

                    guard let source = mockEventStore.storedEvents.first else {
                        return fail("expected the persisted direct source")
                    }
                    // Marker-first ordering: the unresolved marker is attempted on the
                    // initial pass and on each bounded retry; the fence is never
                    // attempted while the marker cannot be written.
                    await expect { mockEventStore.unresolvedJourneyOwnershipResponseRecordCallCount }
                        .toEventually(equal(4), timeout: .seconds(2))
                    await expect { await eventLog.getQueuedEventCount() }
                        .toEventually(equal(1), timeout: .seconds(2))

                    expect(mockEventStore.journeyOwnershipFenceRecordCallCount).to(equal(0))
                    expect(mockEventStore.pendingIds).to(contain(source.id))
                    expect(mockEventStore.deliveredIds).toNot(contain(source.id))
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    expect(mockEventStore.unresolvedJourneyOwnershipResponseRecordCallCount).to(equal(4))
                }

                it("durably retires a terminal direct send once the store recovers") {
                    mockEventStore.shouldFailMarkDelivered = true
                    await mockNuxieApi.configureTrackEventFailure(
                        error: URLError(.notConnectedToInternet)
                    )

                    await expect {
                        try await eventLog.trackWithResponse(
                            JourneyEvents.journeyEnrolled,
                            properties: nil
                        )
                    }.to(throwError())
                    guard let source = mockEventStore.storedEvents.first else {
                        return fail("expected the persisted direct source")
                    }
                    expect(mockEventStore.deliveredIds).toNot(contain(source.id))

                    // Store recovers; the bounded retirement retry must mark
                    // the terminal source delivered without any flush or
                    // relaunch (the acknowledgement outlives the caller).
                    mockEventStore.shouldFailMarkDelivered = false
                    await expect { mockEventStore.deliveredIds }
                        .toEventually(contain(source.id), timeout: .seconds(2))
                    expect(mockEventStore.pendingIds).toNot(contain(source.id))
                }

                it("cancels pending ownership-fence retries before closing the store") {
                    let journeyId = "journey-fence-retry-close"
                    let epoch = 9
                    await mockNuxieApi.setTrackEventResponse(
                        EventResponse(
                            status: "ok",
                            journeyClaim: .init(
                                journeyId: journeyId,
                                accepted: false,
                                epoch: epoch,
                                reason: "epoch_mismatch"
                            )
                        )
                    )
                    mockEventStore.shouldFailOwnershipFenceRecord = true
                    mockEventStore.shouldFailUnresolvedJourneyOwnershipResponseRecord = true

                    await expect {
                        try await eventLog.trackWithResponse(
                            JourneyEvents.journeyTransition,
                            properties: ["journey_id": journeyId, "epoch": epoch],
                            flushStrategy: .none
                        )
                    }.to(throwError(NuxieError.eventRoutingFailed))

                    let writesBeforeClose = mockEventStore.journeyOwnershipFenceRecordCallCount
                    await eventLog.close()
                    try? await Task.sleep(nanoseconds: 500_000_000)

                    expect(mockEventStore.isClosed).to(beTrue())
                    expect(mockEventStore.journeyOwnershipFenceRecordCallCount)
                        .to(equal(writesBeforeClose))
                }

                it("fails closed when restored journey ownership cannot be read") {
                    mockEventStore.shouldFailQuery = true

                    let canAuthor = await eventLog.canAuthorJourneyEvents(
                        JourneyEventOwnership(
                            journeyId: "journey-ownership-query-failure",
                            epoch: 1
                        )
                    )

                    expect(canAuthor).to(beFalse())
                }
            }

            // MARK: - Response Parsing

            context("response parsing") {
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

            context("durable system capture") {
                it("fences a failed capture at the event timestamp despite clock rollback") {
                    await eventLog.close()
                    let initialOpen = Date(timeIntervalSince1970: 1_000)
                    let attemptedAt = Date(timeIntervalSince1970: 2_000)
                    let rolledBack = Date(timeIntervalSince1970: 1_500)
                    let dateProvider = MockDateProvider(initialDate: initialOpen)
                    let capturedTimestamp = CapturedEventTimestamp()
                    eventLog = EventLog(
                        identity: mockIdentityService,
                        sessions: mockSessionService,
                        dateProvider: dateProvider,
                        apiClient: mockNuxieApi,
                        store: mockEventStore
                    )
                    testConfig.beforeSend = { event in
                        capturedTimestamp.record(event.timestamp)
                        dateProvider.setCurrentDate(rolledBack)
                        return event
                    }
                    try await eventLog.configure(configuration: testConfig)
                    dateProvider.setCurrentDate(attemptedAt)
                    mockEventStore.shouldFailStore = true

                    let failed = await eventLog.captureSystemEvent(
                        "$purchase_completed",
                        properties: nil,
                        eventId: "purchase-completed:clock-rollback",
                        distinctId: "customer-a"
                    )

                    expect(failed).to(beNil())
                    expect(capturedTimestamp.value) == attemptedAt
                    guard case .retainedWindow(let coveredFrom) =
                        try await eventLog.historyCoverage()
                    else {
                        return fail("Expected retained-window history coverage")
                    }
                    expect(coveredFrom).to(beGreaterThan(attemptedAt))
                }

                it("acknowledges only after the stable event is persisted") {
                    mockEventStore.shouldFailStore = true

                    let failed = await eventLog.captureSystemEvent(
                        "$purchase_completed",
                        properties: ["placement_id": "placement-1"],
                        eventId: "purchase-completed:transaction-1",
                        distinctId: "customer-a"
                    )

                    expect(failed).to(beNil())
                    expect(mockEventStore.storedEvents).to(beEmpty())

                    mockEventStore.shouldFailStore = false
                    let captured = await eventLog.captureSystemEvent(
                        "$purchase_completed",
                        properties: [
                            "placement_id": "placement-1",
                            "snapshot": "first",
                        ],
                        eventId: "purchase-completed:transaction-1",
                        distinctId: "customer-a"
                    )
                    mockSessionService.mockSessionId = "replacement-session"
                    let replay = await eventLog.captureSystemEvent(
                        "$purchase_completed",
                        properties: [
                            "placement_id": "placement-2",
                            "snapshot": "replacement",
                        ],
                        eventId: "purchase-completed:transaction-1",
                        distinctId: "customer-b"
                    )

                    expect(captured?.event.id)
                        == "purchase-completed:transaction-1"
                    expect(replay?.event.id)
                        == "purchase-completed:transaction-1"
                    expect(replay?.event.name) == captured?.event.name
                    expect(replay?.event.distinctId) == captured?.event.distinctId
                    expect(replay?.event.timestamp) == captured?.event.timestamp
                    expect(replay?.event.properties["placement_id"] as? String)
                        == "placement-1"
                    expect(replay?.event.properties["snapshot"] as? String)
                        == "first"
                    expect(replay?.event.properties["$session_id"] as? String)
                        == captured?.event.properties["$session_id"] as? String
                    expect(mockEventStore.storedEvents).to(haveCount(1))
                    expect(mockEventStore.pendingIds)
                        .to(contain("purchase-completed:transaction-1"))
                }

                it("lets an authoritative ownership response fence a suspended exit capture") {
                    mockEventStore.stableCaptureDelayNanoseconds = 300_000_000
                    await mockNuxieApi.setTrackEventResponse(
                        EventResponse(
                            status: "ok",
                            journeyOwnership: .init(
                                journeyId: "journey-1",
                                accepted: true,
                                epoch: 4
                            )
                        )
                    )

                    let capture = Task {
                        await eventLog.captureOwnedJourneySystemEvent(
                            JourneyEvents.journeyExited,
                            properties: ["journey_id": "journey-1"],
                            eventId: "journey-exited:suspended-stale-owner",
                            distinctId: "customer-a",
                            ownership: JourneyEventOwnership(
                                journeyId: "journey-1",
                                epoch: 4
                            )
                        )
                    }
                    await expect { mockEventStore.stableCaptureCommitCallCount }
                        .toEventually(equal(1))

                    let response = Task {
                        try await eventLog.trackWithResponse(
                            JourneyEvents.journeyHandoff,
                            properties: ["journey_id": "journey-1"],
                            flushStrategy: .none
                        )
                    }

                    guard case .ownershipLost = await capture.value else {
                        _ = try await response.value
                        return fail("the response fence must win before stable capture commits")
                    }
                    _ = try await response.value

                    expect(mockEventStore.journeyOwnershipFences["journey-1"])
                        == 4
                    expect(mockEventStore.storedEvents.map(\.id))
                        .toNot(contain("journey-exited:suspended-stale-owner"))
                    expect(mockEventStore.pendingIds)
                        .toNot(contain("journey-exited:suspended-stale-owner"))
                }

                it("applies beforeSend while preserving stable capture identity") {
                    testConfig.beforeSend = { event in
                        NuxieEvent(
                            id: "host-rewritten-id",
                            name: "$purchase_completed_redacted",
                            distinctId: "host-rewritten-customer",
                            properties: ["placement_id": "placement-1"],
                            timestamp: Date(timeIntervalSince1970: 1)
                        )
                    }
                    try await eventLog.configure(configuration: testConfig)

                    let captured = await eventLog.captureSystemEvent(
                        "$purchase_completed",
                        properties: [
                            "placement_id": "placement-1",
                            "secret": "must-not-persist",
                        ],
                        eventId: "purchase-completed:scoped:transaction-1",
                        distinctId: "customer-a"
                    )

                    expect(captured?.event.id)
                        == "purchase-completed:scoped:transaction-1"
                    expect(captured?.event.distinctId) == "customer-a"
                    expect(captured?.event.name) == "$purchase_completed_redacted"
                    expect(captured?.event.properties["placement_id"] as? String)
                        == "placement-1"
                    expect(captured?.event.properties["secret"]).to(beNil())
                    expect(mockEventStore.storedEvents).to(haveCount(1))
                }

                it("persists a terminal drop that survives policy changes and relaunch") {
                    let hookCalls = BeforeSendCallCounter()
                    testConfig.beforeSend = { _ in
                        hookCalls.increment()
                        return nil
                    }
                    try await eventLog.configure(configuration: testConfig)
                    let eventId = "purchase-completed:scoped:dropped"

                    let captured = await eventLog.captureSystemEvent(
                        "$purchase_completed",
                        properties: ["secret": "must-not-persist"],
                        eventId: eventId,
                        distinctId: "customer-a"
                    )

                    expect(captured?.routesLocally) == false
                    expect(mockEventStore.storedEvents).to(beEmpty())
                    expect(mockEventStore.stableDroppedIds).to(contain(eventId))

                    testConfig.beforeSend = { event in
                        hookCalls.increment()
                        return event
                    }
                    try await eventLog.configure(configuration: testConfig)
                    let sameProcessReplay = await eventLog.captureSystemEvent(
                        "$purchase_completed",
                        properties: ["replacement": true],
                        eventId: eventId,
                        distinctId: "customer-a"
                    )
                    expect(sameProcessReplay?.routesLocally) == false

                    await eventLog.close()
                    eventLog = EventLog(
                        identity: mockIdentityService,
                        sessions: mockSessionService,
                        dateProvider: MockDateProvider(),
                        apiClient: mockNuxieApi,
                        store: mockEventStore
                    )
                    try await eventLog.configure(configuration: testConfig)
                    let relaunchedReplay = await eventLog.captureSystemEvent(
                        "$purchase_completed",
                        properties: ["replacement": true],
                        eventId: eventId,
                        distinctId: "customer-a"
                    )

                    expect(relaunchedReplay?.routesLocally) == false
                    expect(hookCalls.value) == 1
                    expect(mockEventStore.storedEvents).to(beEmpty())
                }

                it("retries a beforeSend drop when its terminal outcome cannot persist") {
                    testConfig.beforeSend = { _ in nil }
                    try await eventLog.configure(configuration: testConfig)
                    let eventId = "purchase-completed:drop-storage-retry"
                    mockEventStore.shouldFailStore = true

                    let failed = await eventLog.captureSystemEvent(
                        "$purchase_completed",
                        properties: nil,
                        eventId: eventId,
                        distinctId: "customer-a"
                    )
                    expect(failed).to(beNil())
                    expect(mockEventStore.stableDroppedIds).to(beEmpty())

                    mockEventStore.shouldFailStore = false
                    let retried = await eventLog.captureSystemEvent(
                        "$purchase_completed",
                        properties: nil,
                        eventId: eventId,
                        distinctId: "customer-a"
                    )
                    expect(retried?.routesLocally) == false
                    expect(mockEventStore.stableDroppedIds) == Set([eventId])
                }

                it("bounds stable drop tombstones to the purchase evidence window") {
                    await eventLog.close()
                    let date = MockDateProvider()
                    eventLog = EventLog(
                        identity: mockIdentityService,
                        sessions: mockSessionService,
                        dateProvider: date,
                        apiClient: mockNuxieApi,
                        store: mockEventStore,
                        cleanupCheckInterval: 1
                    )
                    testConfig.beforeSend = { _ in nil }
                    try await eventLog.configure(configuration: testConfig)
                    let oldEventId = "purchase-completed:old-drop"
                    let recentEventId = "purchase-completed:recent-drop"

                    _ = await eventLog.captureSystemEvent(
                        "$purchase_completed",
                        properties: nil,
                        eventId: oldEventId,
                        distinctId: "customer-a"
                    )
                    date.advance(by: 91 * 24 * 60 * 60)
                    _ = await eventLog.captureSystemEvent(
                        "$purchase_completed",
                        properties: nil,
                        eventId: recentEventId,
                        distinctId: "customer-a"
                    )

                    expect(mockEventStore.stableDroppedIds) == Set([recentEventId])
                }

                it("returns an existing canonical capture before invoking a new hook") {
                    let hookCalls = BeforeSendCallCounter()
                    testConfig.beforeSend = { event in
                        hookCalls.increment()
                        return event
                    }
                    try await eventLog.configure(configuration: testConfig)
                    let eventId = "purchase-completed:canonical-before-hook"
                    let first = await eventLog.captureSystemEvent(
                        "$purchase_completed",
                        properties: ["snapshot": "first"],
                        eventId: eventId,
                        distinctId: "customer-a"
                    )

                    testConfig.beforeSend = { _ in
                        hookCalls.increment()
                        return nil
                    }
                    try await eventLog.configure(configuration: testConfig)
                    let replay = await eventLog.captureSystemEvent(
                        "$purchase_completed",
                        properties: ["snapshot": "replacement"],
                        eventId: eventId,
                        distinctId: "customer-a"
                    )

                    expect(first?.routesLocally) == true
                    expect(replay?.routesLocally) == true
                    expect(replay?.event.properties["snapshot"] as? String) == "first"
                    expect(hookCalls.value) == 1
                }

                it("does not replay an existing owned capture after a durable ownership fence") {
                    let ownership = JourneyEventOwnership(
                        journeyId: "fenced-canonical-capture",
                        epoch: 3
                    )
                    let eventId = "journey-exited:fenced-canonical-capture:3"
                    let initial = await eventLog.captureOwnedJourneySystemEvent(
                        JourneyEvents.journeyExited,
                        properties: ["journey_id": ownership.journeyId],
                        eventId: eventId,
                        distinctId: "customer-a",
                        ownership: ownership
                    )
                    guard case .captured = initial else {
                        return fail("expected the initial host exit capture")
                    }

                    try! await mockEventStore.recordJourneyOwnershipLoss(
                        ownership,
                        recordedAt: Date()
                    )
                    let replay = await eventLog.captureOwnedJourneySystemEvent(
                        JourneyEvents.journeyExited,
                        properties: ["journey_id": ownership.journeyId],
                        eventId: eventId,
                        distinctId: "customer-a",
                        ownership: ownership
                    )

                    guard case .ownershipLost = replay else {
                        return fail("a durable ownership fence must win over a stable replay")
                    }
                    expect(mockEventStore.storedEvents.map(\.id)).to(equal([eventId]))
                }

                it("refuses stable system capture after close") {
                    await eventLog.close()

                    let captured = await eventLog.captureSystemEvent(
                        "$purchase_completed",
                        properties: ["placement_id": "placement-1"],
                        eventId: "purchase-completed:scoped:closed",
                        distinctId: "customer-a"
                    )

                    expect(captured).to(beNil())
                    expect(mockEventStore.storedEvents).to(beEmpty())
                }
            }

            context("online") {
                it("queues behind accepted predecessors and delivers both in one batch") {
                    eventLog.track(
                        "queued_event",
                        properties: nil,
                        userProperties: nil,
                        userPropertiesSetOnce: nil
                    )
                    await eventLog.drain()
                    await expect { await eventLog.getQueuedEventCount() }.to(equal(1))
                    let (trigger, response) = try await eventLog.trackForTrigger(
                        "trigger_event",
                        properties: ["screen": "home"]
                    )

                    expect(response.status).to(equal("offline"))
                    await expect { await mockNuxieApi.trackEventCallCount }.to(equal(0))
                    await expect { await mockNuxieApi.sendBatchCallCount }.to(equal(0))
                    await expect { await eventLog.getQueuedEventCount() }.to(equal(2))

                    let flushed = await eventLog.flushEvents()
                    expect(flushed).to(beTrue())

                    await expect { await mockNuxieApi.sendBatchCallCount }.to(equal(1))
                    await expect { await mockNuxieApi.sentEvents.map(\.name) }
                        .to(equal(["queued_event", "trigger_event"]))
                    await expect { await eventLog.getQueuedEventCount() }.to(equal(0))
                    expect(mockEventStore.deliveredIds).to(contain(trigger.id))
                }

                it("retains the ordered pair when their later batch fails") {
                    eventLog.track(
                        "queued_event",
                        properties: nil,
                        userProperties: nil,
                        userPropertiesSetOnce: nil
                    )
                    await eventLog.drain()
                    let (trigger, response) = try await eventLog.trackForTrigger(
                        "trigger_event",
                        properties: ["screen": "home"]
                    )
                    await mockNuxieApi.setShouldFailBatch(true)
                    let flushed = await eventLog.flushEvents()

                    expect(response.status).to(equal("offline"))
                    expect(flushed).to(beFalse())
                    await expect { await mockNuxieApi.trackEventCallCount }.to(equal(0))
                    await expect { await mockNuxieApi.sendBatchCallCount }.to(equal(1))
                    expect(mockEventStore.pendingIds).to(contain(trigger.id))
                    await expect { await eventLog.getQueuedEventCount() }.to(equal(2))
                }

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

    func startJourney(for experience: Experience, distinctId: String, originEventId: String?) async -> Journey? {
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
