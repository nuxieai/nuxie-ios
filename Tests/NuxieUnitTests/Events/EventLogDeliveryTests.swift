import Foundation
import Quick
import Nimble
@_spi(Testing) @testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

// MARK: - Mock API Client

actor MockNuxieApiForQueue: NuxieApiProtocol {

    // Tracking properties
    private(set) var sendBatchCalled = false
    private(set) var sendBatchCallCount = 0
    private(set) var lastBatchSent: [BatchEventItem]?
    private(set) var allBatchesSent: [[BatchEventItem]] = []
    private(set) var directEvents: [NuxieEvent] = []
    private(set) var completedDirectEventCount = 0

    // Response configuration
    var shouldFailSendBatch = false
    var sendBatchError: Error?
    var shouldFailTrackEvent = false
    var trackEventError: Error?
    var trackEventResponse: EventResponse?
    var sendBatchResponse: BatchResponse = BatchResponse(
        status: "success",
        processed: 0,
        failed: 0,
        total: 0,
        errors: nil
    )

    // Delay configuration for testing timing
    var sendBatchDelay: TimeInterval = 0
    var trackEventDelay: TimeInterval = 0
    var maximumAcceptedBatchSize: Int?
    var poisonEventName: String?

    func sendBatch(events: [BatchEventItem]) async throws -> BatchResponse {
        sendBatchCalled = true
        sendBatchCallCount += 1
        lastBatchSent = events
        allBatchesSent.append(events)

        // Simulate network delay if configured
        if sendBatchDelay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(sendBatchDelay * 1_000_000_000))
        }

        // Return error if configured
        if shouldFailSendBatch {
            throw sendBatchError ?? URLError(.badServerResponse)
        }
        if let maximumAcceptedBatchSize, events.count > maximumAcceptedBatchSize {
            throw NuxieNetworkError.httpError(
                statusCode: 413,
                message: "Payload Too Large"
            )
        }
        if let poisonEventName, events.contains(where: { $0.event == poisonEventName }) {
            throw NuxieNetworkError.httpError(
                statusCode: 422,
                message: "Poison event"
            )
        }

        let hasCustomResponse =
            sendBatchResponse.processed != 0 ||
            sendBatchResponse.failed != 0 ||
            sendBatchResponse.total != 0 ||
            sendBatchResponse.errors != nil ||
            sendBatchResponse.status != "success"

        if hasCustomResponse {
            return sendBatchResponse
        }

        return BatchResponse(
            status: "success",
            processed: events.count,
            failed: 0,
            total: events.count,
            errors: nil
        )
    }

    func fetchProfile(for distinctId: String, locale: String?) async throws -> ProfileResponse {
        return ProfileResponse(
            segments: [],
            userProperties: nil,
            experiments: nil,
            features: nil
        )
    }

    func fetchProfileWithTimeout(for distinctId: String, locale: String?, timeout: TimeInterval) async throws -> ProfileResponse {
        return ProfileResponse(
            segments: [],
            userProperties: nil,
            experiments: nil,
            features: nil
        )
    }

    func trackEvent(event: String, distinctId: String, properties: [String: Any]?, value: Double?, entityId: String?) async throws -> EventResponse {
        return EventResponse(
            status: "success",
            payload: nil,
            customer: nil,
            eventId: nil,
            message: nil,
            featuresMatched: nil,
            usage: nil,
            journey: nil,
        )
    }

    func trackEvent(_ event: NuxieEvent) async throws -> EventResponse {
        directEvents.append(event)
        if trackEventDelay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(trackEventDelay * 1_000_000_000))
        }
        if shouldFailTrackEvent {
            throw trackEventError ?? URLError(.notConnectedToInternet)
        }
        completedDirectEventCount += 1
        return trackEventResponse
            ?? EventResponse(status: "success", eventId: event.id)
    }

    func checkFeature(customerId: String, featureId: String, requiredBalance: Double?, entityId: String?) async throws -> FeatureCheckResult {
        return FeatureCheckResult(
            customerId: customerId,
            featureId: featureId,
            requiredBalance: requiredBalance ?? 1,
            code: "allowed",
            allowed: true,
            unlimited: false,
            balance: 100,
            type: .boolean,
            preview: nil
        )
    }

    func syncTransaction(transactionJwt: String, distinctId: String) async throws -> PurchaseResponse {
        return PurchaseResponse(success: true, customerId: distinctId, features: nil, error: nil)
    }

    func setResponseField(
        distinctId: String,
        journeyId: String,
        responseSchemaId: String,
        schemaVersion: Int?,
        key: String,
        value: Any
    ) async throws -> ResponseWriteResponse {
        return ResponseWriteResponse(status: "ok", response: nil, version: nil)
    }

    func submitResponse(
        distinctId: String,
        journeyId: String,
        responseSchemaId: String,
        schemaVersion: Int?
    ) async throws -> ResponseSubmitResponse {
        return ResponseSubmitResponse(status: "ok", response: nil)
    }

    func abandonResponses(
        distinctId: String,
        journeyId: String
    ) async throws -> ResponseAbandonResponse {
        return ResponseAbandonResponse(status: "ok", responses: [])
    }
    func reset() {
        sendBatchCalled = false
        sendBatchCallCount = 0
        lastBatchSent = nil
        allBatchesSent.removeAll()
        directEvents.removeAll()
        completedDirectEventCount = 0
        shouldFailSendBatch = false
        sendBatchError = nil
        shouldFailTrackEvent = false
        trackEventError = nil
        trackEventResponse = nil
        sendBatchDelay = 0
        trackEventDelay = 0
        maximumAcceptedBatchSize = nil
        poisonEventName = nil
    }

    // Helper functions for setting mock state
    func setSendBatchDelay(_ delay: TimeInterval) {
        sendBatchDelay = delay
    }

    func setMaximumAcceptedBatchSize(_ size: Int?) {
        maximumAcceptedBatchSize = size
    }

    func setPoisonEventName(_ name: String?) {
        poisonEventName = name
    }

    func setFailure(_ shouldFail: Bool, error: Error? = nil) {
        shouldFailSendBatch = shouldFail
        sendBatchError = error
    }

    func setTrackEventFailure(_ shouldFail: Bool, error: Error? = nil) {
        shouldFailTrackEvent = shouldFail
        trackEventError = error
    }

    func setTrackEventDelay(_ delay: TimeInterval) {
        trackEventDelay = delay
    }

    func setTrackEventResponse(_ response: EventResponse?) {
        trackEventResponse = response
    }

    func setBatchResponse(_ response: BatchResponse) {
        sendBatchResponse = response
    }
}

private actor StringCallRecorder {
    private var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }

    func snapshot() -> [String] {
        values
    }
}

// MARK: - Test Spec

/// Delivery state-machine tests for EventLog's folded network queue —
/// batching, retry/backoff, partial success, permanent drops, pause/resume,
/// and durable-delivery acks. Ported from the former NuxieNetworkQueue tests;
/// the internal delivery entry points keep the same granularity.
final class EventLogDeliveryTests: AsyncSpec {
    override class func spec() {
        describe("EventLog delivery") {
            var log: EventLog!
            var mockApi: MockNuxieApiForQueue!
            var mockStore: MockEventStore!

            func makeLog(
                flushAt: Int = 20,
                maxQueueSize: Int = 1000,
                maxBatchSize: Int = 50,
                maxRetries: Int = 3,
                baseRetryDelay: TimeInterval = 5,
                flushInterval: TimeInterval = 30,
                suppressBackgroundWork: Bool = true
            ) async throws -> EventLog {
                let config = NuxieConfiguration(apiKey: "test-api-key")
                config.testingOverrides.flushAt = flushAt
                config.testingOverrides.maxQueueSize = maxQueueSize
                config.testingOverrides.eventBatchSize = maxBatchSize
                config.testingOverrides.retryCount = maxRetries
                config.testingOverrides.retryDelay = baseRetryDelay
                config.testingOverrides.flushInterval = flushInterval
                config.testingOverrides.suppressBackgroundWork = suppressBackgroundWork
                let newLog = EventLog(
                    identity: MockIdentityService(),
                    dateProvider: MockDateProvider(),
                    apiClient: mockApi,
                    store: mockStore
                )
                try await newLog.configure(configuration: config)
                return newLog
            }

            beforeEach {
                mockApi = MockNuxieApiForQueue()
                mockStore = MockEventStore()
            }

            afterEach {
                await log?.close()
                log = nil
                await mockApi?.reset()
            }

            // MARK: - Initialization Tests

            describe("initialization") {
                it("should initialize with default configuration") {
                    log = try await makeLog()
                    await expect { await log.getQueuedEventCount() }.to(equal(0))
                }

                it("should initialize with custom configuration") {
                    log = try await makeLog(
                        flushAt: 10,
                        maxQueueSize: 500,
                        maxBatchSize: 25,
                        maxRetries: 5,
                        baseRetryDelay: 10
                    )
                    await expect { await log.getQueuedEventCount() }.to(equal(0))
                }

                it("starts periodic flushing by default when XCTest is attached") {
                    log = try await makeLog(
                        flushAt: 100,
                        flushInterval: 0.01,
                        suppressBackgroundWork: false
                    )
                    log.track("periodic-flush-under-xctest")

                    await expect { await mockApi.sendBatchCallCount }
                        .toEventually(equal(1))
                }

                it("suppresses periodic flushing only through the explicit override") {
                    log = try await makeLog(
                        flushAt: 100,
                        flushInterval: 0.01,
                        suppressBackgroundWork: true
                    )
                    log.track("explicitly-suppressed-periodic-flush")

                    try? await Task.sleep(nanoseconds: 50_000_000)
                    let sendCount = await mockApi.sendBatchCallCount
                    expect(sendCount) == 0
                }

                it("drains more than 1,000 durable pending events through a bounded delivery window") {
                    let expectedIds = (0..<1_005).map { "pending_\($0)" }
                    for (index, id) in expectedIds.enumerated() {
                        _ = try await mockStore.insert(
                            StoredEvent(
                                id: id,
                                name: "pending_event_\(index)",
                                timestamp: Date(timeIntervalSince1970: TimeInterval(index)),
                                distinctId: "user123"
                            ),
                            deliveryState: .pending
                        )
                    }

                    log = try await makeLog(
                        flushAt: 2_000,
                        maxQueueSize: 10,
                        maxBatchSize: 10
                    )

                    await expect { await log.getQueuedEventCount() }.to(equal(1_005))

                    let drained = await log.flushEvents()
                    let deliveredIds = await mockApi.allBatchesSent
                        .flatMap { $0.compactMap(\.idempotencyKey) }

                    expect(drained).to(beTrue())
                    expect(deliveredIds).to(equal(expectedIds))
                    expect(Set(deliveredIds).count).to(equal(expectedIds.count))
                    await expect { await log.getQueuedEventCount() }.to(equal(0))
                    expect(mockStore.pendingIds).to(beEmpty())
                }

                it("keeps newer captures behind older durable rows while a refill is suspended") {
                    let oldest = try StoredEvent(
                        id: "oldest",
                        name: "oldest",
                        timestamp: Date(timeIntervalSince1970: 1),
                        distinctId: "user123"
                    )
                    let older = try StoredEvent(
                        id: "older",
                        name: "older",
                        timestamp: Date(timeIntervalSince1970: 2),
                        distinctId: "user123"
                    )
                    _ = try await mockStore.insert(oldest, deliveryState: .pending)
                    _ = try await mockStore.insert(older, deliveryState: .pending)

                    log = try await makeLog(
                        flushAt: 100,
                        maxQueueSize: 1,
                        maxBatchSize: 1
                    )
                    mockStore.pendingDeliveryQueryDelay = 0.1

                    let flushTask = Task { await log.deliveryFlushAll() }
                    await expect { await mockApi.sendBatchCallCount }
                        .toEventually(equal(1), timeout: .seconds(1))

                    log.track(
                        "newest",
                        properties: nil,
                        userProperties: nil,
                        userPropertiesSetOnce: nil
                    )
                    await log.drain()

                    let drained = await flushTask.value
                    expect(drained).to(beTrue())
                    let deliveredNames = await mockApi.allBatchesSent
                        .flatMap { $0.map(\.event) }
                    expect(deliveredNames).to(equal(["oldest", "older", "newest"]))
                }
            }

            // MARK: - Enqueue Tests

            describe("enqueue") {
                beforeEach {
                    log = try await makeLog(
                        flushAt: 20,  // Increase to prevent auto-flush during testing
                        maxQueueSize: 10
                    )
                }

                it("should enqueue events") {
                    let event = TestEventBuilder(name: "test_event")
                        .withDistinctId("user123")
                        .build()

                    await log.enqueueForDelivery(event)

                    await expect { await log.getQueuedEventCount() }.to(equal(1))
                }

                it("should handle multiple enqueues") {
                    let events = (0..<3).map { i in
                        TestEventBuilder(name: "event_\(i)")
                            .withDistinctId("user123")
                            .build()
                    }

                    for event in events {
                        await log.enqueueForDelivery(event)
                    }

                    await expect { await log.getQueuedEventCount() }.to(equal(3))
                }

                it("keeps durable overflow pending and refills the delivery window after acknowledgements") {
                    await log.close()
                    log = try await makeLog(
                        flushAt: 100,
                        maxQueueSize: 10,
                        maxBatchSize: 5
                    )

                    for index in 0..<25 {
                        log.track(
                            "event_\(index)",
                            properties: ["index": index],
                            userProperties: nil,
                            userPropertiesSetOnce: nil
                        )
                    }
                    await log.drain()

                    await expect { await log.getQueuedEventCount() }.to(equal(25))

                    let drained = await log.flushEvents()
                    let delivered = await mockApi.allBatchesSent.flatMap { $0 }

                    expect(drained).to(beTrue())
                    expect(delivered.map(\.event)).to(equal((0..<25).map { "event_\($0)" }))
                    expect(Set(delivered.compactMap(\.idempotencyKey)).count).to(equal(25))
                    await expect { await log.getQueuedEventCount() }.to(equal(0))
                    expect(mockStore.pendingIds).to(beEmpty())
                }

                it("should trigger flush when threshold is reached") {
                    // Create a log with lower threshold for this test
                    let testLog = try await makeLog(
                        flushAt: 5,
                        maxQueueSize: 100
                    )

                    let events = (0..<5).map { i in
                        TestEventBuilder(name: "event_\(i)")
                            .withDistinctId("user123")
                            .build()
                    }

                    for event in events {
                        await testLog.enqueueForDelivery(event)
                    }

                    await expect { await mockApi.sendBatchCalled }
                        .toEventually(beTrue(), timeout: .seconds(2))
                    await expect { await mockApi.lastBatchSent?.count }
                        .toEventually(equal(5), timeout: .seconds(2))

                    await testLog.close()
                }
            }

            // MARK: - Flush Tests

            describe("flush") {
                beforeEach {
                    log = try await makeLog(
                        flushAt: 20,
                        maxBatchSize: 10
                    )
                }

                it("uses the event id as the batch idempotency key") {
                    let event = TestEventBuilder(name: "keyed_event")
                        .withDistinctId("user123")
                        .build()

                    await log.enqueueForDelivery(event)
                    let result = await log.performFlush(forceSend: true)

                    expect(result).to(beTrue())
                    await expect { await mockApi.lastBatchSent?.first?.idempotencyKey }
                        .to(equal(event.id))
                }

                it("does not batch a pending row while its direct send is active") {
                    await mockApi.setTrackEventDelay(0.1)

                    let directTask = Task {
                        try await log.trackForTrigger(
                            "direct_only",
                            properties: nil
                        )
                    }
                    await expect { await mockApi.directEvents.count }
                        .toEventually(equal(1), timeout: .seconds(1))

                    let batchStarted = await log.performFlush(forceSend: true)
                    _ = try await directTask.value

                    expect(batchStarted).to(beFalse())
                    await expect { await mockApi.sendBatchCallCount }.to(equal(0))
                    await expect { await mockApi.directEvents.count }.to(equal(1))
                    await expect { await log.getQueuedEventCount() }.to(equal(0))
                }

                it("does not report an active direct send as an initiated queue flush") {
                    await mockApi.setTrackEventDelay(0.5)

                    let directTask = Task {
                        try await log.trackForTrigger(
                            "direct_in_flight",
                            properties: nil
                        )
                    }
                    await expect { await mockApi.directEvents.count }
                        .toEventually(equal(1), timeout: .seconds(1))

                    let flushed = await log.flushEvents()

                    expect(flushed).to(beFalse())
                    await expect { await mockApi.completedDirectEventCount }.to(equal(0))
                    _ = try await directTask.value
                    await expect { await log.getQueuedEventCount() }.to(equal(0))
                }

                it("retries journey handoffs on the decision endpoint with the original event id") {
                    let handoff = NuxieEvent(
                        id: "handoff-idempotency-key",
                        name: JourneyEvents.journeyHandoff,
                        distinctId: "user123",
                        properties: [
                            "journey_id": "journey-1",
                            "epoch": 0,
                        ]
                    )

                    await log.enqueueForDelivery(handoff)
                    let result = await log.performFlush(forceSend: true)

                    expect(result).to(beTrue())
                    await expect { await mockApi.directEvents.map(\.id) }
                        .to(equal([handoff.id]))
                    await expect { await mockApi.sendBatchCallCount }.to(equal(0))
                    await expect { await log.getQueuedEventCount() }.to(equal(0))
                    expect(mockStore.deliveredIds).to(contain(handoff.id))
                }

                it("delivers queued parking on the decision endpoint without throwing") {
                    let parked = NuxieEvent(
                        id: "park-idempotency-key",
                        name: JourneyEvents.journeyParked,
                        distinctId: "user123",
                        properties: [
                            "journey_id": "journey-1",
                            "epoch": 3,
                            "reason": "background",
                        ]
                    )

                    await log.enqueueForDelivery(parked)
                    let result = await log.performFlush(forceSend: true)

                    expect(result).to(beTrue())
                    await expect { await mockApi.directEvents.map(\.id) }
                        .to(equal([parked.id]))
                    await expect { await mockApi.sendBatchCallCount }.to(equal(0))
                    await expect { await log.getQueuedEventCount() }.to(equal(0))
                    expect(mockStore.deliveredIds).to(contain(parked.id))
                }

                it("keeps failed journey handoff retries pending without sending them to batch") {
                    let handoff = NuxieEvent(
                        id: "handoff-retry-id",
                        name: JourneyEvents.journeyHandoff,
                        distinctId: "user123",
                        properties: [
                            "journey_id": "journey-1",
                            "epoch": 0,
                        ]
                    )
                    await mockApi.setTrackEventFailure(true)
                    await log.enqueueForDelivery(handoff)

                    let result = await log.performFlush(forceSend: true)

                    expect(result).to(beTrue())
                    await expect { await mockApi.directEvents.map(\.id) }
                        .to(equal([handoff.id]))
                    await expect { await mockApi.sendBatchCallCount }.to(equal(0))
                    await expect { await log.getQueuedEventCount() }.to(equal(1))
                    expect(mockStore.deliveredIds).notTo(contain(handoff.id))
                }

                it("preserves queue order across accepted and decision lanes") {
                    let before = TestEventBuilder(name: "accepted-before")
                        .withDistinctId("user123")
                        .build()
                    let handoff = NuxieEvent(
                        id: "ordered-handoff",
                        name: JourneyEvents.journeyHandoff,
                        distinctId: "user123",
                        properties: [
                            "journey_id": "journey-1",
                            "epoch": 0,
                        ]
                    )
                    let after = TestEventBuilder(name: "accepted-after")
                        .withDistinctId("user123")
                        .build()
                    for event in [before, handoff, after] {
                        await log.enqueueForDelivery(event)
                    }

                    _ = await log.performFlush(forceSend: true)
                    await expect { await mockApi.lastBatchSent?.map(\.idempotencyKey) }
                        .to(equal([before.id]))
                    await expect { await mockApi.directEvents }.to(beEmpty())
                    await expect { await log.getQueuedEventCount() }.to(equal(2))

                    _ = await log.performFlush(forceSend: true)
                    await expect { await mockApi.directEvents.map(\.id) }
                        .to(equal([handoff.id]))
                    await expect { await log.getQueuedEventCount() }.to(equal(1))

                    _ = await log.performFlush(forceSend: true)
                    await expect { await mockApi.lastBatchSent?.map(\.idempotencyKey) }
                        .to(equal([after.id]))
                    await expect { await log.getQueuedEventCount() }.to(equal(0))
                }

                it("never retries a claim through the barred batch endpoint") {
                    let claim = NuxieEvent(
                        id: "claim-id",
                        name: JourneyEvents.journeyClaimed,
                        distinctId: "user123",
                        properties: [
                            "journey_id": "journey-1",
                            "epoch": 0,
                        ]
                    )
                    await log.enqueueForDelivery(claim)

                    let result = await log.performFlush(forceSend: true)

                    expect(result).to(beTrue())
                    await expect { await mockApi.directEvents }.to(beEmpty())
                    await expect { await mockApi.sendBatchCallCount }.to(equal(0))
                    await expect { await log.getQueuedEventCount() }.to(equal(0))
                    expect(mockStore.deliveredIds).to(contain(claim.id))
                }

                it("replays a claim directly when its ownership response marker is unresolved") {
                    let ownership = JourneyEventOwnership(
                        journeyId: "journey-marked-claim",
                        epoch: 3
                    )
                    let claim = NuxieEvent(
                        id: "marked-claim-id",
                        name: JourneyEvents.journeyClaimed,
                        distinctId: "user123",
                        properties: [
                            "journey_id": ownership.journeyId,
                            "epoch": ownership.epoch,
                        ]
                    )
                    try await mockStore.recordUnresolvedJourneyOwnershipResponse(
                        sourceEventId: claim.id,
                        ownership: ownership,
                        recordedAt: Date(timeIntervalSince1970: 1)
                    )
                    // A replay may omit an ownership signal already returned
                    // for this idempotency key; the source marker carries it.
                    await mockApi.setTrackEventResponse(.success())
                    await log.enqueueForDelivery(claim)

                    let result = await log.performFlush(forceSend: true)

                    expect(result).to(beTrue())
                    await expect { await mockApi.directEvents.map(\.id) }
                        .to(equal([claim.id]))
                    await expect { await mockApi.sendBatchCallCount }.to(equal(0))
                    expect(mockStore.journeyOwnershipFences[ownership.journeyId])
                        .to(equal(ownership.epoch))
                    expect(
                        mockStore.unresolvedJourneyOwnershipResponses[claim.id]
                    ).to(beNil())
                    expect(mockStore.deliveredIds).to(contain(claim.id))
                    await expect { await log.getQueuedEventCount() }.to(equal(0))
                }

                it("preserves one idempotency key from a failed direct handoff through retry") {
                    await mockApi.setTrackEventFailure(true)

                    await expect {
                        try await log.trackForTrigger(
                            JourneyEvents.journeyHandoff,
                            properties: [
                                "journey_id": "journey-1",
                                "epoch": 0,
                            ],
                            persistToHistory: true,
                            distinctIdOverride: "user123"
                        )
                    }.to(throwError())
                    let firstId = await mockApi.directEvents.first?.id
                    await expect { await log.getQueuedEventCount() }.to(equal(1))

                    await mockApi.setTrackEventFailure(false)
                    _ = await log.performFlush(forceSend: true)

                    await expect { await mockApi.directEvents.map(\.id) }
                        .to(equal([firstId, firstId].compactMap { $0 }))
                    await expect { await log.getQueuedEventCount() }.to(equal(0))
                }

                it("does not queue a failed claim without the mailbox offer needed to consume a late ack") {
                    await mockApi.setTrackEventFailure(true)

                    await expect {
                        try await log.trackForTrigger(
                            JourneyEvents.journeyClaimed,
                            properties: [
                                "journey_id": "journey-1",
                                "epoch": 0,
                            ],
                            persistToHistory: true,
                            distinctIdOverride: "user123"
                        )
                    }.to(throwError())

                    await expect { await log.getQueuedEventCount() }.to(equal(0))
                    expect(mockStore.deliveredIds).to(haveCount(1))
                }

                it("forwards accepted handoff ownership responses to the journey owner") {
                    let recorder = StringCallRecorder()
                    await log.setJourneyHandoffDeliveredHandler { journeyId in
                        await recorder.append(journeyId)
                    }
                    await mockApi.setTrackEventResponse(
                        EventResponse(
                            status: "ok",
                            journeyOwnership: .init(
                                journeyId: "journey-1",
                                accepted: true,
                                epoch: 1
                            )
                        )
                    )
                    await log.enqueueForDelivery(
                        NuxieEvent(
                            id: "handoff-ownership-id",
                            name: JourneyEvents.journeyHandoff,
                            distinctId: "user123",
                            properties: [
                                "journey_id": "journey-1",
                                "epoch": 0,
                            ]
                        )
                    )

                    _ = await log.performFlush(forceSend: true)

                    await expect { await recorder.snapshot() }
                        .to(equal(["journey-1"]))
                }

                it("should flush events manually") {
                    let events = (0..<3).map { i in
                        TestEventBuilder(name: "event_\(i)")
                            .withDistinctId("user123")
                            .build()
                    }

                    for event in events {
                        await log.enqueueForDelivery(event)
                    }

                    let result = await log.performFlush(forceSend: true)

                    expect(result).to(beTrue())
                    await expect { await mockApi.sendBatchCalled }.to(beTrue())
                    await expect { await mockApi.lastBatchSent?.count }.to(equal(3))
                    await expect { await log.getQueuedEventCount() }.to(equal(0))
                }

                it("acks delivered event ids in the store") {
                    let events = (0..<2).map { i in
                        TestEventBuilder(name: "event_\(i)")
                            .withDistinctId("user123")
                            .build()
                    }

                    for event in events {
                        await log.enqueueForDelivery(event)
                    }

                    _ = await log.performFlush(forceSend: true)

                    expect(Set(mockStore.deliveredIds)).to(equal(Set(events.map(\.id))))
                }

                it("should handle empty queue flush") {
                    let result = await log.performFlush(forceSend: true)

                    expect(result).to(beFalse())
                    await expect { await mockApi.sendBatchCalled }.to(beFalse())
                }

                it("should respect max batch size") {
                    let events = (0..<15).map { i in
                        TestEventBuilder(name: "event_\(i)")
                            .withDistinctId("user123")
                            .build()
                    }

                    for event in events {
                        await log.enqueueForDelivery(event)
                    }

                    let result = await log.performFlush(forceSend: true)

                    expect(result).to(beTrue())
                    await expect { await mockApi.lastBatchSent?.count }.to(equal(10)) // maxBatchSize
                    await expect { await log.getQueuedEventCount() }.to(equal(5)) // Remaining events
                }

                it("should flush all events across multiple batches") {
                    let batchLog = try await makeLog(
                        flushAt: 20,
                        maxBatchSize: 2
                    )

                    let events = (0..<5).map { i in
                        TestEventBuilder(name: "event_\(i)")
                            .withDistinctId("user123")
                            .build()
                    }

                    for event in events {
                        await batchLog.enqueueForDelivery(event)
                    }

                    let result = await batchLog.deliveryFlushAll()

                    expect(result).to(beTrue())
                    await expect { await mockApi.sendBatchCallCount }.to(equal(3))
                    await expect { await batchLog.getQueuedEventCount() }.to(equal(0))

                    await batchLog.close()
                }

                it("should wait for an in-flight flush and drain the remaining tail") {
                    let tailLog = try await makeLog(
                        flushAt: 2,
                        maxBatchSize: 1
                    )
                    await mockApi.setSendBatchDelay(0.1)

                    await tailLog.enqueueForDelivery(TestEventBuilder(name: "event_1").withDistinctId("user123").build())
                    await tailLog.enqueueForDelivery(TestEventBuilder(name: "event_2").withDistinctId("user123").build())

                    await expect { await mockApi.sendBatchCallCount }
                        .toEventually(equal(1), timeout: .seconds(2))

                    let result = await tailLog.deliveryFlushAll()

                    expect(result).to(beTrue())
                    await expect { await mockApi.sendBatchCallCount }.to(equal(2))
                    await expect { await tailLog.getQueuedEventCount() }.to(equal(0))

                    await tailLog.close()
                }

                it("should handle concurrent flush attempts") {
                    let events = (0..<5).map { i in
                        TestEventBuilder(name: "event_\(i)")
                            .withDistinctId("user123")
                            .build()
                    }

                    for event in events {
                        await log.enqueueForDelivery(event)
                    }

                    // Add delay to simulate slow network
                    await mockApi.setSendBatchDelay(0.5)

                    // Start two concurrent flushes
                    let flushLog = log!
                    async let flush1 = flushLog.performFlush(forceSend: true)
                    async let flush2 = flushLog.performFlush(forceSend: true)

                    let results = await (flush1, flush2)

                    // Only one should succeed
                    expect(results.0 || results.1).to(beTrue())
                    expect(results.0 && results.1).to(beFalse())
                    await expect { await mockApi.sendBatchCallCount }.to(equal(1))
                }
            }

            // MARK: - Error Handling Tests

            describe("error handling") {
                beforeEach {
                    log = try await makeLog(
                        flushAt: 20,
                        maxRetries: 3,
                        baseRetryDelay: 0.1
                    )
                }

                it("should handle temporary network errors with retry") {
                    let events = (0..<2).map { i in
                        TestEventBuilder(name: "event_\(i)")
                            .withDistinctId("user123")
                            .build()
                    }

                    for event in events {
                        await log.enqueueForDelivery(event)
                    }

                    // Configure temporary error
                    await mockApi.setFailure(true, error: URLError(.notConnectedToInternet))

                    let result = await log.performFlush(forceSend: true)

                    expect(result).to(beTrue())
                    await expect { await mockApi.sendBatchCalled }.to(beTrue())
                    // Events should still be in queue for retry
                    await expect { await log.getQueuedEventCount() }.to(equal(2))
                }

                it("retains a batch rejected with request timeout for retry") {
                    let event = TestEventBuilder(name: "request_timeout")
                        .withDistinctId("user123")
                        .build()
                    await log.enqueueForDelivery(event)
                    await mockApi.setFailure(
                        true,
                        error: NuxieNetworkError.httpError(
                            statusCode: 408,
                            message: "Request Timeout"
                        )
                    )

                    _ = await log.performFlush(forceSend: true)

                    await expect { await log.getQueuedEventCount() }.to(equal(1))
                    expect(mockStore.deliveredIds).to(beEmpty())
                }

                it("honors Retry-After seconds within the configured backoff ceiling") {
                    await log.close()
                    log = try await makeLog(
                        maxRetries: 3,
                        baseRetryDelay: 5
                    )
                    await log.enqueueForDelivery(
                        TestEventBuilder(name: "rate_limited")
                            .withDistinctId("user123")
                            .build()
                    )
                    await mockApi.setFailure(
                        true,
                        error: NuxieNetworkError.httpError(
                            statusCode: 429,
                            message: "Too Many Requests",
                            retryAfter: "60"
                        )
                    )

                    _ = await log.performFlush(forceSend: true)

                    let retry = await log.retryBackoffState()
                    expect(retry.attempts).to(equal(1))
                    expect(retry.remainingDelay).toNot(beNil())
                    let remainingDelay = retry.remainingDelay!
                    expect(remainingDelay).to(beGreaterThan(19))
                    expect(remainingDelay).to(beLessThanOrEqualTo(20))
                    await expect { await log.getQueuedEventCount() }.to(equal(1))
                }

                it("honors Retry-After HTTP dates within the configured backoff ceiling") {
                    await log.close()
                    log = try await makeLog(
                        maxRetries: 3,
                        baseRetryDelay: 5
                    )
                    await log.enqueueForDelivery(
                        TestEventBuilder(name: "date_rate_limited")
                            .withDistinctId("user123")
                            .build()
                    )
                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: "en_US_POSIX")
                    formatter.timeZone = TimeZone(secondsFromGMT: 0)
                    formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
                    await mockApi.setFailure(
                        true,
                        error: NuxieNetworkError.httpError(
                            statusCode: 429,
                            message: "Too Many Requests",
                            retryAfter: formatter.string(
                                from: Date().addingTimeInterval(60)
                            )
                        )
                    )

                    _ = await log.performFlush(forceSend: true)

                    let retry = await log.retryBackoffState()
                    expect(retry.remainingDelay).toNot(beNil())
                    let remainingDelay = retry.remainingDelay!
                    expect(remainingDelay).to(beGreaterThan(19))
                    expect(remainingDelay).to(beLessThanOrEqualTo(20))
                }

                it("marks authentication rejection unhealthy without acknowledging events") {
                    await log.enqueueForDelivery(
                        TestEventBuilder(name: "auth_failure")
                            .withDistinctId("user123")
                            .build()
                    )
                    await mockApi.setFailure(
                        true,
                        error: NuxieNetworkError.httpError(
                            statusCode: 401,
                            message: "Unauthorized"
                        )
                    )

                    _ = await log.performFlush(forceSend: true)

                    await expect { await log.getQueuedEventCount() }.to(equal(1))
                    expect(mockStore.deliveredIds).to(beEmpty())
                    await expect { await log.deliveryHealthState() }
                        .to(equal("unhealthy_authentication"))
                    let retry = await log.retryBackoffState()
                    expect(retry.remainingDelay).toNot(beNil())
                    let remainingDelay = retry.remainingDelay!
                    expect(remainingDelay).to(beGreaterThan(29))
                    expect(remainingDelay).to(beLessThanOrEqualTo(30))
                }

                it("splits an oversized batch until the server accepts it") {
                    let events = (0..<4).map {
                        TestEventBuilder(name: "oversized_\($0)")
                            .withDistinctId("user123")
                            .build()
                    }
                    for event in events {
                        await log.enqueueForDelivery(event)
                    }
                    await mockApi.setMaximumAcceptedBatchSize(2)

                    let drained = await log.deliveryFlushAll()

                    expect(drained).to(beTrue())
                    await expect { await mockApi.allBatchesSent.map(\.count) }
                        .to(equal([4, 2, 2]))
                    await expect { await log.getQueuedEventCount() }.to(equal(0))

                    for index in 0..<4 {
                        await log.enqueueForDelivery(
                            TestEventBuilder(name: "post_split_\(index)")
                                .withDistinctId("user123")
                                .build()
                        )
                    }
                    _ = await log.deliveryFlushAll()
                    await expect { await mockApi.allBatchesSent.map(\.count) }
                        .to(equal([4, 2, 2, 4, 2, 2]))
                }

                it("terminally retires a single oversized event") {
                    let event = TestEventBuilder(name: "single_oversized")
                        .withDistinctId("user123")
                        .build()
                    await log.enqueueForDelivery(event)
                    await mockApi.setMaximumAcceptedBatchSize(0)

                    _ = await log.performFlush(forceSend: true)

                    await expect { await log.getQueuedEventCount() }.to(equal(0))
                    expect(mockStore.deliveredIds).to(equal([event.id]))
                    await expect { await mockApi.sendBatchCallCount }.to(equal(1))
                }

                it("isolates and drops explicit poison responses") {
                    let events = (0..<2).map { i in
                        TestEventBuilder(name: "event_\(i)")
                            .withDistinctId("user123")
                            .build()
                    }

                    for event in events {
                        await log.enqueueForDelivery(event)
                    }

                    // Configure the same HTTP 400 error shape that NuxieApi throws
                    await mockApi.setFailure(true, error: NuxieNetworkError.httpError(statusCode: 400, message: "Bad Request"))

                    let result = await log.deliveryFlushAll()

                    expect(result).to(beTrue())
                    await expect { await mockApi.sendBatchCalled }.to(beTrue())
                    // Events should be dropped
                    await expect { await log.getQueuedEventCount() }.to(equal(0))
                }

                it("marks permanently dropped events delivered so they never resurrect") {
                    let event = TestEventBuilder(name: "poison_event")
                        .withDistinctId("user123")
                        .build()

                    await log.enqueueForDelivery(event)
                    await mockApi.setFailure(true, error: NuxieNetworkError.httpError(statusCode: 422, message: "Unprocessable"))
                    _ = await log.performFlush(forceSend: true)

                    expect(mockStore.deliveredIds).to(equal([event.id]))
                }

                it("ends the flush cycle without resending when the durable acknowledgement fails") {
                    let event = try StoredEvent(
                        id: "ack-failure",
                        name: "ack_failure",
                        timestamp: Date(timeIntervalSince1970: 1),
                        distinctId: "user123"
                    )
                    _ = try await mockStore.insert(event, deliveryState: .pending)
                    mockStore.shouldFailMarkDelivered = true

                    log = try await makeLog(
                        flushAt: 1,
                        maxQueueSize: 10,
                        maxBatchSize: 10
                    )

                    let firstResult = await log.deliveryFlushAll()

                    expect(firstResult).to(beFalse())
                    await expect { await mockApi.sendBatchCallCount }.to(equal(1))
                    await expect { await log.getQueuedEventCount() }.to(equal(1))
                    expect(mockStore.deliveredIds).to(beEmpty())

                    mockStore.shouldFailMarkDelivered = false
                    let recovered = await log.deliveryFlushAll()

                    expect(recovered).to(beTrue())
                    await expect { await mockApi.sendBatchCallCount }.to(equal(2))
                    await expect { await log.getQueuedEventCount() }.to(equal(0))
                    expect(mockStore.deliveredIds).to(equal([event.id]))
                }

                it("removes a successfully sent non-durable event when storage acknowledgements are unavailable") {
                    mockStore.shouldFailStore = true
                    mockStore.shouldFailMarkDelivered = true

                    log.track(
                        "non_durable",
                        properties: nil,
                        userProperties: nil,
                        userPropertiesSetOnce: nil
                    )
                    await log.drain()

                    let firstResult = await log.performFlush(forceSend: true)
                    let secondResult = await log.performFlush(forceSend: true)

                    expect(firstResult).to(beTrue())
                    expect(secondResult).to(beFalse())
                    await expect { await mockApi.sendBatchCallCount }.to(equal(1))
                    await expect { await log.getQueuedEventCount() }.to(equal(0))
                    expect(mockStore.deliveredIds).to(beEmpty())
                }

                it("removes a successful non-durable journey decision without a store acknowledgement") {
                    mockStore.shouldFailStore = true
                    mockStore.shouldFailMarkDelivered = true
                    log.track(
                        JourneyEvents.journeyTransition,
                        properties: nil,
                        userProperties: nil,
                        userPropertiesSetOnce: nil
                    )
                    await log.drain()

                    _ = await log.performFlush(forceSend: true)
                    let repeated = await log.performFlush(forceSend: true)

                    expect(repeated).to(beFalse())
                    await expect { await mockApi.completedDirectEventCount }.to(equal(1))
                    await expect { await log.getQueuedEventCount() }.to(equal(0))
                }

                it("removes a non-durable pending journey claim without a store acknowledgement") {
                    mockStore.shouldFailStore = true
                    mockStore.shouldFailMarkDelivered = true
                    log.track(
                        JourneyEvents.journeyClaimed,
                        properties: nil,
                        userProperties: nil,
                        userPropertiesSetOnce: nil
                    )
                    await log.drain()

                    _ = await log.performFlush(forceSend: true)
                    let repeated = await log.performFlush(forceSend: true)

                    expect(repeated).to(beFalse())
                    await expect { await mockApi.completedDirectEventCount }.to(equal(0))
                    await expect { await log.getQueuedEventCount() }.to(equal(0))
                }

                it("removes successful non-durable events from a partial batch") {
                    mockStore.shouldFailStore = true
                    mockStore.shouldFailMarkDelivered = true
                    for name in ["volatile_success", "volatile_failure"] {
                        log.track(name, properties: nil, userProperties: nil, userPropertiesSetOnce: nil)
                    }
                    await log.drain()
                    await mockApi.setBatchResponse(BatchResponse(
                        status: "partial",
                        processed: 1,
                        failed: 1,
                        total: 2,
                        errors: [BatchError(index: 1, event: "volatile_failure", error: "invalid")]
                    ))

                    _ = await log.performFlush(forceSend: true)

                    await expect { await log.getQueuedEventCount() }.to(equal(1))
                }

                it("drops non-durable events after a permanent batch rejection") {
                    mockStore.shouldFailStore = true
                    mockStore.shouldFailMarkDelivered = true
                    log.track(
                        "volatile_poison",
                        properties: nil,
                        userProperties: nil,
                        userPropertiesSetOnce: nil
                    )
                    await log.drain()
                    await mockApi.setFailure(
                        true,
                        error: NuxieNetworkError.httpError(statusCode: 422, message: "invalid")
                    )

                    _ = await log.performFlush(forceSend: true)
                    let repeated = await log.performFlush(forceSend: true)

                    expect(repeated).to(beFalse())
                    await expect { await mockApi.sendBatchCallCount }.to(equal(1))
                    await expect { await log.getQueuedEventCount() }.to(equal(0))
                }

                it("drains durable work before staging an event whose persistence failed") {
                    await log.close()
                    log = try await makeLog(
                        flushAt: 100,
                        maxQueueSize: 1,
                        maxBatchSize: 1
                    )

                    log.track(
                        "durable_first",
                        properties: nil,
                        userProperties: nil,
                        userPropertiesSetOnce: nil
                    )
                    await log.drain()

                    mockStore.shouldFailStore = true
                    log.track(
                        "volatile_second",
                        properties: nil,
                        userProperties: nil,
                        userPropertiesSetOnce: nil
                    )
                    await log.drain()

                    await expect { await log.getQueuedEventCount() }.to(equal(1))
                    _ = await log.flushEvents()

                    let deliveredNames = await mockApi.allBatchesSent
                        .flatMap { $0.map(\.event) }
                    expect(deliveredNames).to(equal(["durable_first", "volatile_second"]))
                    await expect { await log.getQueuedEventCount() }.to(equal(0))
                }

                it("does not start transport when close wins a suspended refill") {
                    let event = try StoredEvent(
                        id: "close-race",
                        name: "close_race",
                        timestamp: Date(timeIntervalSince1970: 1),
                        distinctId: "user123"
                    )
                    _ = try await mockStore.insert(event, deliveryState: .pending)
                    mockStore.pendingDeliveryQueryDelay = 0.1

                    let flushTask = Task { await log.performFlush(forceSend: true) }
                    try? await Task.sleep(nanoseconds: 20_000_000)
                    await log.close()

                    let flushed = await flushTask.value
                    expect(flushed).to(beFalse())
                    await expect { await mockApi.sendBatchCallCount }.to(equal(0))
                }

                it("should reset retry state after dropping a permanent error") {
                    let retryLog = try await makeLog(
                        flushAt: 20,
                        maxRetries: 1,
                        baseRetryDelay: 0
                    )

                    let firstEvent = TestEventBuilder(name: "temp_then_permanent")
                        .withDistinctId("user123")
                        .build()

                    await retryLog.enqueueForDelivery(firstEvent)
                    await mockApi.setFailure(true, error: URLError(.notConnectedToInternet))
                    _ = await retryLog.performFlush(forceSend: true)
                    await expect { await retryLog.getQueuedEventCount() }.to(equal(1))

                    await mockApi.setFailure(true, error: NuxieNetworkError.httpError(statusCode: 400, message: "Bad Request"))
                    _ = await retryLog.performFlush(forceSend: true)
                    await expect { await retryLog.getQueuedEventCount() }.to(equal(0))

                    let secondEvent = TestEventBuilder(name: "fresh_retry_budget")
                        .withDistinctId("user123")
                        .build()

                    await retryLog.enqueueForDelivery(secondEvent)
                    await mockApi.setFailure(true, error: URLError(.notConnectedToInternet))
                    _ = await retryLog.performFlush(forceSend: true)

                    await expect { await retryLog.getQueuedEventCount() }.to(equal(1))

                    await retryLog.close()
                }

                it("should handle partial batch success") {
                    let events = (0..<3).map { i in
                        TestEventBuilder(name: "event_\(i)")
                            .withDistinctId("user123")
                            .build()
                    }

                    for event in events {
                        await log.enqueueForDelivery(event)
                    }

                    // Configure partial success response
                    await mockApi.setBatchResponse(BatchResponse(
                        status: "partial",
                        processed: 2,
                        failed: 1,
                        total: 3,
                        errors: [
                            BatchError(index: 2, event: "event_2", error: "Invalid property")
                        ]
                    ))

                    let result = await log.performFlush(forceSend: true)

                    expect(result).to(beTrue())
                    await expect { await log.getQueuedEventCount() }.to(equal(1))
                    await expect { await mockApi.sendBatchCallCount }.to(equal(1))
                    await expect { await mockApi.lastBatchSent?.map(\.event) }.to(equal(["event_0", "event_1", "event_2"]))

                    await mockApi.setBatchResponse(BatchResponse(
                        status: "success",
                        processed: 1,
                        failed: 0,
                        total: 1,
                        errors: nil
                    ))

                    let retryResult = await log.performFlush(forceSend: true)

                    expect(retryResult).to(beTrue())
                    await expect { await log.getQueuedEventCount() }.to(equal(0))
                    await expect { await mockApi.sendBatchCallCount }.to(equal(2))
                    await expect { await mockApi.lastBatchSent?.map(\.event) }.to(equal(["event_2"]))
                }

                it("acknowledges nothing for malformed partial-batch metadata") {
                    let events = (0..<3).map {
                        TestEventBuilder(name: "malformed_\($0)")
                            .withDistinctId("user123")
                            .build()
                    }
                    for event in events {
                        await log.enqueueForDelivery(event)
                    }
                    await mockApi.setBatchResponse(BatchResponse(
                        status: "partial",
                        processed: 2,
                        failed: 1,
                        total: 4,
                        errors: [
                            BatchError(index: 7, event: "missing", error: "invalid")
                        ]
                    ))

                    _ = await log.performFlush(forceSend: true)

                    await expect { await log.getQueuedEventCount() }.to(equal(3))
                    expect(mockStore.deliveredIds).to(beEmpty())
                }

                it("acknowledges nothing for duplicate partial-batch indexes") {
                    let events = (0..<3).map {
                        TestEventBuilder(name: "duplicate_index_\($0)")
                            .withDistinctId("user123")
                            .build()
                    }
                    for event in events {
                        await log.enqueueForDelivery(event)
                    }
                    await mockApi.setBatchResponse(BatchResponse(
                        status: "partial",
                        processed: 1,
                        failed: 2,
                        total: 3,
                        errors: [
                            BatchError(index: 1, event: "duplicate", error: "invalid"),
                            BatchError(index: 1, event: "duplicate", error: "invalid"),
                        ]
                    ))

                    _ = await log.performFlush(forceSend: true)

                    await expect { await log.getQueuedEventCount() }.to(equal(3))
                    expect(mockStore.deliveredIds).to(beEmpty())
                }

                it("isolates a poison event without dropping valid neighbors") {
                    let events = ["valid_before", "poison", "valid_after"].map {
                        TestEventBuilder(name: $0)
                            .withDistinctId("user123")
                            .build()
                    }
                    for event in events {
                        await log.enqueueForDelivery(event)
                    }
                    await mockApi.setPoisonEventName("poison")

                    let drained = await log.deliveryFlushAll()

                    expect(drained).to(beTrue())
                    await expect { await log.getQueuedEventCount() }.to(equal(0))
                    expect(Set(mockStore.deliveredIds)).to(equal(Set(events.map(\.id))))
                    let successfulNames = await mockApi.allBatchesSent
                        .filter { !$0.contains(where: { $0.event == "poison" }) }
                        .flatMap { $0.map(\.event) }
                    expect(successfulNames).to(contain("valid_before", "valid_after"))
                }

                it("should back off when a partial batch makes no progress") {
                    let events = (0..<2).map { i in
                        TestEventBuilder(name: "event_\(i)")
                            .withDistinctId("user123")
                            .build()
                    }

                    for event in events {
                        await log.enqueueForDelivery(event)
                    }

                    await mockApi.setBatchResponse(BatchResponse(
                        status: "partial",
                        processed: 0,
                        failed: 2,
                        total: 2,
                        errors: nil
                    ))

                    let result = await log.performFlush(forceSend: true)

                    expect(result).to(beTrue())
                    await expect { await log.getQueuedEventCount() }.to(equal(2))
                    await expect { await mockApi.sendBatchCallCount }.to(equal(1))
                }

                it("caps repeated no-progress partial backoff at the configured retry ceiling") {
                    await log.close()
                    log = try await makeLog(maxRetries: 2, baseRetryDelay: 10)
                    await log.enqueueForDelivery(
                        TestEventBuilder(name: "no_progress")
                            .withDistinctId("user123")
                            .build()
                    )
                    await mockApi.setBatchResponse(BatchResponse(
                        status: "partial",
                        processed: 0,
                        failed: 1,
                        total: 1,
                        errors: nil
                    ))

                    for _ in 0..<8 {
                        _ = await log.performFlush(forceSend: true)
                    }

                    let state = await log.retryBackoffState()
                    expect(state.attempts).to(equal(8))
                    expect(state.remainingDelay).toNot(beNil())
                    expect(state.remainingDelay!).to(beGreaterThan(19))
                    expect(state.remainingDelay!).to(beLessThanOrEqualTo(20))
                    await expect { await log.getQueuedEventCount() }.to(equal(1))
                }
            }

            // MARK: - Offline Durability Tests

            describe("offline manual-flush durability") {
                beforeEach {
                    log = try await makeLog(
                        flushAt: 20,
                        maxRetries: 3,
                        baseRetryDelay: 0
                    )
                }

                it("makes one transport attempt, keeps the batch pending, and acks nothing when a manual flush fails offline") {
                    let events = (0..<3).map { i in
                        TestEventBuilder(name: "event_\(i)")
                            .withDistinctId("user123")
                            .build()
                    }
                    for event in events {
                        await log.enqueueForDelivery(event)
                    }

                    await mockApi.setFailure(true, error: URLError(.notConnectedToInternet))

                    let drained = await log.deliveryFlushAll()

                    expect(drained).to(beFalse())
                    // One attempt per cycle — the loop must not burn the retry
                    // budget back-to-back against a dead network.
                    await expect { await mockApi.sendBatchCallCount }.to(equal(1))
                    await expect { await log.getQueuedEventCount() }.to(equal(3))
                    expect(mockStore.deliveredIds).to(beEmpty())
                }

                it("never acks events for retry exhaustion across repeated failed cycles") {
                    let event = TestEventBuilder(name: "durable_event")
                        .withDistinctId("user123")
                        .build()
                    await log.enqueueForDelivery(event)

                    await mockApi.setFailure(true, error: URLError(.timedOut))

                    // maxRetries is 3; hammer more cycles than that. Every
                    // cycle fails, and the event must survive them all.
                    for _ in 0..<5 {
                        _ = await log.performFlush(forceSend: true)
                    }

                    await expect { await log.getQueuedEventCount() }.to(equal(1))
                    expect(mockStore.deliveredIds).to(beEmpty())
                }

                it("delivers and acks the retained batch on the next cycle once the transport recovers") {
                    let event = TestEventBuilder(name: "durable_event")
                        .withDistinctId("user123")
                        .build()
                    await log.enqueueForDelivery(event)

                    await mockApi.setFailure(true, error: URLError(.notConnectedToInternet))
                    for _ in 0..<4 {
                        _ = await log.performFlush(forceSend: true)
                    }
                    await expect { await log.getQueuedEventCount() }.to(equal(1))

                    await mockApi.setFailure(false)
                    let result = await log.performFlush(forceSend: true)

                    expect(result).to(beTrue())
                    await expect { await log.getQueuedEventCount() }.to(equal(0))
                    expect(mockStore.deliveredIds).to(equal([event.id]))
                }

                it("still permanently drops and acks a poison batch after earlier transport failures") {
                    let event = TestEventBuilder(name: "poison_after_outage")
                        .withDistinctId("user123")
                        .build()
                    await log.enqueueForDelivery(event)

                    // Transport failures retain the event...
                    await mockApi.setFailure(true, error: URLError(.notConnectedToInternet))
                    for _ in 0..<4 {
                        _ = await log.performFlush(forceSend: true)
                    }
                    await expect { await log.getQueuedEventCount() }.to(equal(1))

                    // ...but a permanent 4xx rejection is still a deliberate
                    // drop, acked so it never resurrects.
                    await mockApi.setFailure(true, error: NuxieNetworkError.httpError(statusCode: 400, message: "Bad Request"))
                    _ = await log.performFlush(forceSend: true)

                    await expect { await log.getQueuedEventCount() }.to(equal(0))
                    expect(mockStore.deliveredIds).to(equal([event.id]))
                }
            }

            // MARK: - Pause/Resume Tests

            describe("pause and resume") {
                beforeEach {
                    log = try await makeLog(flushAt: 5)
                }

                it("should pause automatic flushing") {
                    await log.pauseEventQueue()

                    // Add events that would normally trigger flush
                    let events = (0..<6).map { i in
                        TestEventBuilder(name: "event_\(i)")
                            .withDistinctId("user123")
                            .build()
                    }

                    for event in events {
                        await log.enqueueForDelivery(event)
                    }

                    // Wait briefly
                    try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds

                    // Should not flush while paused
                    await expect { await mockApi.sendBatchCalled }.to(beFalse())
                    await expect { await log.getQueuedEventCount() }.to(equal(6))
                }

                it("should resume and flush pending events") {
                    await log.pauseEventQueue()

                    // Add events while paused
                    let events = (0..<5).map { i in
                        TestEventBuilder(name: "event_\(i)")
                            .withDistinctId("user123")
                            .build()
                    }

                    for event in events {
                        await log.enqueueForDelivery(event)
                    }

                    // Resume should trigger flush
                    await log.resumeEventQueue()

                    // Use polling expectation for async flush
                    await expect { await mockApi.sendBatchCalled }
                        .toEventually(beTrue(), timeout: .seconds(1))
                    await expect { await log.getQueuedEventCount() }
                        .toEventually(equal(0), timeout: .seconds(1))
                }

                it("should allow manual flush while paused") {
                    // Manual flush intentionally works even when paused
                    // This is required for identity ordering where we need to flush
                    // the $identify event immediately regardless of pause state
                    await log.pauseEventQueue()

                    let event = TestEventBuilder(name: "test")
                        .withDistinctId("user123")
                        .build()
                    await log.enqueueForDelivery(event)

                    let result = await log.performFlush(forceSend: true)

                    expect(result).to(beTrue())
                    await expect { await mockApi.sendBatchCalled }.to(beTrue())
                    await expect { await mockApi.lastBatchSent?.count }.to(equal(1))
                }
            }

            // MARK: - Queue Management Tests

            describe("queue management") {
                beforeEach {
                    log = try await makeLog(flushAt: 20)
                }

                it("should clear all events") {
                    let events = (0..<5).map { i in
                        TestEventBuilder(name: "event_\(i)")
                            .withDistinctId("user123")
                            .build()
                    }

                    for event in events {
                        await log.enqueueForDelivery(event)
                    }

                    await log.clearDeliveryQueue()

                    await expect { await log.getQueuedEventCount() }.to(equal(0))
                }

                it("should report correct queue size") {
                    await expect { await log.getQueuedEventCount() }.to(equal(0))

                    await log.enqueueForDelivery(TestEventBuilder(name: "event1").withDistinctId("user123").build())
                    await expect { await log.getQueuedEventCount() }.to(equal(1))

                    await log.enqueueForDelivery(TestEventBuilder(name: "event2").withDistinctId("user123").build())
                    await expect { await log.getQueuedEventCount() }.to(equal(2))

                    await log.clearDeliveryQueue()
                    await expect { await log.getQueuedEventCount() }.to(equal(0))
                }
            }

            // MARK: - Event Conversion Tests

            describe("event to batch item conversion") {
                beforeEach {
                    log = try await makeLog(flushAt: 20)
                }

                it("should convert NuxieEvent to BatchEventItem correctly") {
                    let properties: [String: Any] = [
                        "screen": "home",
                        "button": "subscribe",
                        "value": 9.99,
                        "entityId": "entity123",
                        "idempotency_key": "key123",
                        "$anon_distinct_id": "anon456"
                    ]

                    let event = TestEventBuilder(name: "button_clicked")
                        .withDistinctId("user123")
                        .withProperties(properties)
                        .withTimestamp(Date())
                        .build()

                    await log.enqueueForDelivery(event)
                    let result = await log.performFlush(forceSend: true)

                    expect(result).to(beTrue())
                    await expect { await mockApi.lastBatchSent?.count }.to(equal(1))

                    let batchItem = await mockApi.lastBatchSent?.first
                    expect(batchItem?.event).to(equal("button_clicked"))
                    expect(batchItem?.distinctId).to(equal("user123"))
                    expect(batchItem?.anonDistinctId).to(equal("anon456"))
                    expect(batchItem?.value).to(equal(9.99))
                    expect(batchItem?.entityId).to(equal("entity123"))
                    // Delivery idempotency is keyed on the event's own id so
                    // retried batches dedupe server-side.
                    expect(batchItem?.idempotencyKey).to(equal(event.id))
                    expect(batchItem?.timestamp).toNot(beNil())
                }
            }

            // MARK: - Integration Tests

            describe("integration scenarios") {
                beforeEach {
                    log = try await makeLog(
                        flushAt: 10,  // Higher threshold to prevent auto-flush during test setup
                        maxQueueSize: 10,
                        maxBatchSize: 5
                    )
                }

                it("should handle rapid event ingestion") {
                    // Simulate rapid event ingestion
                    let events = (0..<20).map { i in
                        NuxieEvent(
                            id: "event_\(i)",
                            name: "rapid_event_\(i)",
                            distinctId: "user123"
                        )
                    }

                    for event in events {
                        await log.enqueueForDelivery(event)
                    }

                    // Should have triggered multiple flushes
                    // and dropped oldest events when queue was full
                    await expect { await mockApi.sendBatchCallCount }
                        .toEventually(beGreaterThan(0), timeout: .seconds(2))
                    await expect { await log.getQueuedEventCount() }
                        .toEventually(beLessThanOrEqualTo(10), timeout: .seconds(2))
                }

                it("should handle mixed success and failure scenarios") {
                    // Short retry delay for testing
                    let mixedLog = try await makeLog(
                        flushAt: 10,
                        maxQueueSize: 10,
                        maxBatchSize: 5,
                        baseRetryDelay: 0.1
                    )

                    let events = (0..<4).map { i in
                        TestEventBuilder(name: "event_\(i)")
                            .withDistinctId("user123")
                            .build()
                    }

                    for event in events {
                        await mixedLog.enqueueForDelivery(event)
                    }

                    // First flush fails
                    await mockApi.setFailure(true, error: URLError(.timedOut))

                    let result1 = await mixedLog.performFlush(forceSend: true)
                    expect(result1).to(beTrue())
                    await expect { await mixedLog.getQueuedEventCount() }.to(equal(4)) // Events retained after failure

                    // Wait for retry backoff to expire (0.1 seconds base delay)
                    try? await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds

                    // Second flush succeeds
                    await mockApi.setFailure(false)

                    let result2 = await mixedLog.performFlush(forceSend: true)
                    expect(result2).to(beTrue())
                    await expect { await mixedLog.getQueuedEventCount() }.to(equal(0)) // All events sent

                    await mixedLog.close()
                }
            }
        }
    }
}
