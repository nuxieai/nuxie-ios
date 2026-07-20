import Foundation
import Quick
import Nimble
@testable import Nuxie
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
    
    // Response configuration
    var shouldFailSendBatch = false
    var sendBatchError: Error?
    var sendBatchResponse: BatchResponse = BatchResponse(
        status: "success",
        processed: 0,
        failed: 0,
        total: 0,
        errors: nil
    )
    
    // Delay configuration for testing timing
    var sendBatchDelay: TimeInterval = 0
    
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
            campaigns: [],
            segments: [],
            flows: [],
            userProperties: nil,
            experiments: nil,
            features: nil,
            journeys: nil
        )
    }

    func fetchProfileWithTimeout(for distinctId: String, locale: String?, timeout: TimeInterval) async throws -> ProfileResponse {
        return ProfileResponse(
            campaigns: [],
            segments: [],
            flows: [],
            userProperties: nil,
            experiments: nil,
            features: nil,
            journeys: nil
        )
    }

    func fetchFlow(flowId: String) async throws -> RemoteFlow {
        fatalError("Not implemented for tests")
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
            execution: nil
        )
    }

    func checkFeature(customerId: String, featureId: String, requiredBalance: Int?, entityId: String?) async throws -> FeatureCheckResult {
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
        journeySessionId: String,
        responseSchemaId: String,
        schemaVersion: Int?,
        key: String,
        value: Any
    ) async throws -> ResponseWriteResponse {
        return ResponseWriteResponse(status: "ok", response: nil, version: nil)
    }

    func submitResponse(
        distinctId: String,
        journeySessionId: String,
        responseSchemaId: String,
        schemaVersion: Int?
    ) async throws -> ResponseSubmitResponse {
        return ResponseSubmitResponse(status: "ok", response: nil)
    }

    func abandonResponses(
        distinctId: String,
        journeySessionId: String
    ) async throws -> ResponseAbandonResponse {
        return ResponseAbandonResponse(status: "ok", responses: [])
    }
    func reset() {
        sendBatchCalled = false
        sendBatchCallCount = 0
        lastBatchSent = nil
        allBatchesSent.removeAll()
        shouldFailSendBatch = false
        sendBatchError = nil
        sendBatchDelay = 0
    }
    
    // Helper functions for setting mock state
    func setSendBatchDelay(_ delay: TimeInterval) {
        sendBatchDelay = delay
    }
    
    func setFailure(_ shouldFail: Bool, error: Error? = nil) {
        shouldFailSendBatch = shouldFail
        sendBatchError = error
    }
    
    func setBatchResponse(_ response: BatchResponse) {
        sendBatchResponse = response
    }
}

// MARK: - Test Spec

final class NuxieNetworkQueueTests: AsyncSpec {
    override class func spec() {
        describe("NuxieNetworkQueue") {
            var queue: NuxieNetworkQueue!
            var mockApi: MockNuxieApiForQueue!
            
            beforeEach {
                mockApi = MockNuxieApiForQueue()
            }
            
            afterEach {
                if queue != nil {
                    await queue.shutdown()
                    queue = nil
                }
                await mockApi?.reset()
                mockApi = nil
            }
            
            // MARK: - Initialization Tests
            
            describe("initialization") {
                it("should initialize with default configuration") {
                    queue = NuxieNetworkQueue(apiClient: mockApi)
                    await expect { await queue.getQueueSize() }.to(equal(0))
                }
                
                it("should initialize with custom configuration") {
                    queue = NuxieNetworkQueue(
                        flushAt: 10,
                        flushIntervalSeconds: 60,
                        maxQueueSize: 500,
                        maxBatchSize: 25,
                        maxRetries: 5,
                        baseRetryDelay: 10,
                        apiClient: mockApi
                    )
                    await expect { await queue.getQueueSize() }.to(equal(0))
                }
                
                it("should not start timer in test environment") {
                    // The test environment check is already built into the NuxieNetworkQueue init
                    queue = NuxieNetworkQueue(apiClient: mockApi)
                    
                    // Queue should be created but timer shouldn't be running
                    await expect { await queue.getQueueSize() }.to(equal(0))
                }
            }
            
            // MARK: - Enqueue Tests
            
            describe("enqueue") {
                beforeEach {
                    queue = NuxieNetworkQueue(
                        flushAt: 20,  // Increase to prevent auto-flush during testing
                        maxQueueSize: 10,
                        apiClient: mockApi
                    )
                }
                
                it("should enqueue events") {
                    let event = TestEventBuilder(name: "test_event")
                        .withDistinctId("user123")
                        .build()
                    
                    await queue.enqueue(event)
                    
                    await expect { await queue.getQueueSize() }.to(equal(1))
                }
                
                it("should handle multiple enqueues") {
                    let events = (0..<3).map { i in
                        TestEventBuilder(name: "event_\(i)")
                            .withDistinctId("user123")
                            .build()
                    }
                    
                    for event in events {
                        await queue.enqueue(event)
                    }
                    
                    await expect { await queue.getQueueSize() }.to(equal(3))
                }
                
                it("should drop oldest events when queue is full") {
                    // Fill queue to max capacity
                    let events = (0..<12).map { i in
                        NuxieEvent(
                            id: "event_\(i)",
                            name: "event_\(i)",
                            distinctId: "user123"
                        )
                    }
                    
                    for event in events {
                        await queue.enqueue(event)
                    }
                    
                    // Queue max is 10, so we should have dropped 2 oldest events
                    await expect { await queue.getQueueSize() }.to(equal(10))
                }
                
                it("should trigger flush when threshold is reached") {
                    // Create a queue with lower threshold for this test
                    let testQueue = NuxieNetworkQueue(
                        flushAt: 5,
                        maxQueueSize: 100,
                        apiClient: mockApi
                    )
                    
                    let events = (0..<5).map { i in
                        TestEventBuilder(name: "event_\(i)")
                            .withDistinctId("user123")
                            .build()
                    }
                    
                    for event in events {
                        await testQueue.enqueue(event)
                    }
                    
                    await expect { await mockApi.sendBatchCalled }
                        .toEventually(beTrue(), timeout: .seconds(2))
                    await expect { await mockApi.lastBatchSent?.count }
                        .toEventually(equal(5), timeout: .seconds(2))
                    
                    await testQueue.shutdown()
                }
            }
            
            // MARK: - Flush Tests
            
            describe("flush") {
                beforeEach {
                    queue = NuxieNetworkQueue(
                        flushAt: 20,
                        maxBatchSize: 10,
                        apiClient: mockApi
                    )
                }
                
                it("uses the event id as the batch idempotency key") {
                    let event = TestEventBuilder(name: "keyed_event")
                        .withDistinctId("user123")
                        .build()

                    await queue.enqueue(event)
                    let result = await queue.flush()

                    expect(result).to(beTrue())
                    await expect { await mockApi.lastBatchSent?.first?.idempotencyKey }
                        .to(equal(event.id))
                }

                it("should flush events manually") {
                    let events = (0..<3).map { i in
                        TestEventBuilder(name: "event_\(i)")
                            .withDistinctId("user123")
                            .build()
                    }
                    
                    for event in events {
                        await queue.enqueue(event)
                    }
                    
                    let result = await queue.flush()
                    
                    expect(result).to(beTrue())
                    await expect { await mockApi.sendBatchCalled }.to(beTrue())
                    await expect { await mockApi.lastBatchSent?.count }.to(equal(3))
                    await expect { await queue.getQueueSize() }.to(equal(0))
                }
                
                it("should handle empty queue flush") {
                    let result = await queue.flush()
                    
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
                        await queue.enqueue(event)
                    }
                    
                    let result = await queue.flush()
                    
                    expect(result).to(beTrue())
                    await expect { await mockApi.lastBatchSent?.count }.to(equal(10)) // maxBatchSize
                    await expect { await queue.getQueueSize() }.to(equal(5)) // Remaining events
                }

                it("should flush all events across multiple batches") {
                    queue = NuxieNetworkQueue(
                        flushAt: 20,
                        maxBatchSize: 2,
                        apiClient: mockApi
                    )

                    let events = (0..<5).map { i in
                        TestEventBuilder(name: "event_\(i)")
                            .withDistinctId("user123")
                            .build()
                    }

                    for event in events {
                        await queue.enqueue(event)
                    }

                    let result = await queue.flushAll()

                    expect(result).to(beTrue())
                    await expect { await mockApi.sendBatchCallCount }.to(equal(3))
                    await expect { await queue.getQueueSize() }.to(equal(0))
                }

                it("should wait for an in-flight flush and drain the remaining tail") {
                    queue = NuxieNetworkQueue(
                        flushAt: 2,
                        flushIntervalSeconds: 30,
                        maxBatchSize: 1,
                        apiClient: mockApi
                    )
                    await mockApi.setSendBatchDelay(0.1)

                    await queue.enqueue(TestEventBuilder(name: "event_1").withDistinctId("user123").build())
                    await queue.enqueue(TestEventBuilder(name: "event_2").withDistinctId("user123").build())

                    await expect { await mockApi.sendBatchCallCount }
                        .toEventually(equal(1), timeout: .seconds(2))

                    let result = await queue.flushAll()

                    expect(result).to(beTrue())
                    await expect { await mockApi.sendBatchCallCount }.to(equal(2))
                    await expect { await queue.getQueueSize() }.to(equal(0))
                }
                
                it("should handle concurrent flush attempts") {
                    let events = (0..<5).map { i in
                        TestEventBuilder(name: "event_\(i)")
                            .withDistinctId("user123")
                            .build()
                    }
                    
                    for event in events {
                        await queue.enqueue(event)
                    }
                    
                    // Add delay to simulate slow network
                    await mockApi.setSendBatchDelay(0.5)
                    
                    // Start two concurrent flushes
                    async let flush1 = queue.flush()
                    async let flush2 = queue.flush()
                    
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
                    queue = NuxieNetworkQueue(
                        flushAt: 20,
                        maxRetries: 3,
                        baseRetryDelay: 0.1,
                        apiClient: mockApi
                    )
                }
                
                it("should handle temporary network errors with retry") {
                    let events = (0..<2).map { i in
                        TestEventBuilder(name: "event_\(i)")
                            .withDistinctId("user123")
                            .build()
                    }
                    
                    for event in events {
                        await queue.enqueue(event)
                    }
                    
                    // Configure temporary error
                    await mockApi.setFailure(true, error: URLError(.notConnectedToInternet))
                    
                    let result = await queue.flush()
                    
                    expect(result).to(beTrue())
                    await expect { await mockApi.sendBatchCalled }.to(beTrue())
                    // Events should still be in queue for retry
                    await expect { await queue.getQueueSize() }.to(equal(2))
                }
                
                it("should drop events on permanent error (4xx)") {
                    let events = (0..<2).map { i in
                        TestEventBuilder(name: "event_\(i)")
                            .withDistinctId("user123")
                            .build()
                    }
                    
                    for event in events {
                        await queue.enqueue(event)
                    }
                    
                    // Configure the same HTTP 400 error shape that NuxieApi throws
                    await mockApi.setFailure(true, error: NuxieNetworkError.httpError(statusCode: 400, message: "Bad Request"))
                    
                    let result = await queue.flush()
                    
                    expect(result).to(beTrue())
                    await expect { await mockApi.sendBatchCalled }.to(beTrue())
                    // Events should be dropped
                    await expect { await queue.getQueueSize() }.to(equal(0))
                }

                it("should reset retry state after dropping a permanent error") {
                    queue = NuxieNetworkQueue(
                        flushAt: 20,
                        maxRetries: 1,
                        baseRetryDelay: 0,
                        apiClient: mockApi
                    )

                    let firstEvent = TestEventBuilder(name: "temp_then_permanent")
                        .withDistinctId("user123")
                        .build()

                    await queue.enqueue(firstEvent)
                    await mockApi.setFailure(true, error: URLError(.notConnectedToInternet))
                    _ = await queue.flush()
                    await expect { await queue.getQueueSize() }.to(equal(1))

                    await mockApi.setFailure(true, error: NuxieNetworkError.httpError(statusCode: 400, message: "Bad Request"))
                    _ = await queue.flush()
                    await expect { await queue.getQueueSize() }.to(equal(0))

                    let secondEvent = TestEventBuilder(name: "fresh_retry_budget")
                        .withDistinctId("user123")
                        .build()

                    await queue.enqueue(secondEvent)
                    await mockApi.setFailure(true, error: URLError(.notConnectedToInternet))
                    _ = await queue.flush()

                    await expect { await queue.getQueueSize() }.to(equal(1))
                }
                
                it("should handle partial batch success") {
                    let events = (0..<3).map { i in
                        TestEventBuilder(name: "event_\(i)")
                            .withDistinctId("user123")
                            .build()
                    }
                    
                    for event in events {
                        await queue.enqueue(event)
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
                    
                    let result = await queue.flush()
                    
                    expect(result).to(beTrue())
                    await expect { await queue.getQueueSize() }.to(equal(1))
                    await expect { await mockApi.sendBatchCallCount }.to(equal(1))
                    await expect { await mockApi.lastBatchSent?.map(\.event) }.to(equal(["event_0", "event_1", "event_2"]))

                    await mockApi.setBatchResponse(BatchResponse(
                        status: "success",
                        processed: 1,
                        failed: 0,
                        total: 1,
                        errors: nil
                    ))

                    let retryResult = await queue.flush()

                    expect(retryResult).to(beTrue())
                    await expect { await queue.getQueueSize() }.to(equal(0))
                    await expect { await mockApi.sendBatchCallCount }.to(equal(2))
                    await expect { await mockApi.lastBatchSent?.map(\.event) }.to(equal(["event_2"]))
                }

                it("should back off when a partial batch makes no progress") {
                    queue = NuxieNetworkQueue(
                        flushAt: 20,
                        maxRetries: 3,
                        baseRetryDelay: 0.1,
                        apiClient: mockApi
                    )

                    let events = (0..<2).map { i in
                        TestEventBuilder(name: "event_\(i)")
                            .withDistinctId("user123")
                            .build()
                    }

                    for event in events {
                        await queue.enqueue(event)
                    }

                    await mockApi.setBatchResponse(BatchResponse(
                        status: "partial",
                        processed: 0,
                        failed: 2,
                        total: 2,
                        errors: nil
                    ))

                    let result = await queue.flush()

                    expect(result).to(beTrue())
                    await expect { await queue.getQueueSize() }.to(equal(2))
                    await expect { await mockApi.sendBatchCallCount }.to(equal(1))
                }
            }
            
            // MARK: - Pause/Resume Tests
            
            describe("pause and resume") {
                beforeEach {
                    queue = NuxieNetworkQueue(
                        flushAt: 5,
                        apiClient: mockApi
                    )
                }
                
                it("should pause automatic flushing") {
                    await queue.pause()
                    
                    // Add events that would normally trigger flush
                    let events = (0..<6).map { i in
                        TestEventBuilder(name: "event_\(i)")
                            .withDistinctId("user123")
                            .build()
                    }
                    
                    for event in events {
                        await queue.enqueue(event)
                    }
                    
                    // Wait briefly
                    try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                    
                    // Should not flush while paused
                    await expect { await mockApi.sendBatchCalled }.to(beFalse())
                    await expect { await queue.getQueueSize() }.to(equal(6))
                }
                
                it("should resume and flush pending events") {
                    await queue.pause()
                    
                    // Add events while paused
                    let events = (0..<5).map { i in
                        TestEventBuilder(name: "event_\(i)")
                            .withDistinctId("user123")
                            .build()
                    }
                    
                    for event in events {
                        await queue.enqueue(event)
                    }
                    
                    // Resume should trigger flush
                    await queue.resume()
                    
                    // Use polling expectation for async flush
                    await expect { await mockApi.sendBatchCalled }
                        .toEventually(beTrue(), timeout: .seconds(1))
                    await expect { await queue.getQueueSize() }
                        .toEventually(equal(0), timeout: .seconds(1))
                }
                
                it("should allow manual flush while paused") {
                    // Manual flush intentionally works even when paused
                    // This is required for identity ordering where we need to flush
                    // the $identify event immediately regardless of pause state
                    await queue.pause()
                    
                    let event = TestEventBuilder(name: "test")
                        .withDistinctId("user123")
                        .build()
                    await queue.enqueue(event)
                    
                    let result = await queue.flush()
                    
                    expect(result).to(beTrue())
                    await expect { await mockApi.sendBatchCalled }.to(beTrue())
                    await expect { await mockApi.lastBatchSent?.count }.to(equal(1))
                }
            }
            
            // MARK: - Queue Management Tests
            
            describe("queue management") {
                beforeEach {
                    queue = NuxieNetworkQueue(
                        flushAt: 20,
                        apiClient: mockApi
                    )
                }
                
                it("should clear all events") {
                    let events = (0..<5).map { i in
                        TestEventBuilder(name: "event_\(i)")
                            .withDistinctId("user123")
                            .build()
                    }
                    
                    for event in events {
                        await queue.enqueue(event)
                    }
                    
                    await queue.clear()
                    
                    await expect { await queue.getQueueSize() }.to(equal(0))
                }
                
                it("should report correct queue size") {
                    await expect { await queue.getQueueSize() }.to(equal(0))
                    
                    await queue.enqueue(TestEventBuilder(name: "event1").withDistinctId("user123").build())
                    await expect { await queue.getQueueSize() }.to(equal(1))
                    
                    await queue.enqueue(TestEventBuilder(name: "event2").withDistinctId("user123").build())
                    await expect { await queue.getQueueSize() }.to(equal(2))
                    
                    await queue.clear()
                    await expect { await queue.getQueueSize() }.to(equal(0))
                }
            }
            
            // MARK: - Event Conversion Tests
            
            describe("event to batch item conversion") {
                beforeEach {
                    queue = NuxieNetworkQueue(
                        flushAt: 20,
                        apiClient: mockApi
                    )
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
                    
                    var propertiesWithSession = properties
                    propertiesWithSession["$session_id"] = "session456"
                    let event = TestEventBuilder(name: "button_clicked")
                        .withDistinctId("user123")
                        .withProperties(propertiesWithSession)
                        .withTimestamp(Date())
                        .build()
                    
                    await queue.enqueue(event)
                    let result = await queue.flush()
                    
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
            
            // MARK: - Shutdown Tests
            
            describe("shutdown") {
                beforeEach {
                    queue = NuxieNetworkQueue(
                        flushAt: 20,
                        apiClient: mockApi
                    )
                }
                
                it("should handle shutdown gracefully") {
                    let events = (0..<3).map { i in
                        TestEventBuilder(name: "event_\(i)")
                            .withDistinctId("user123")
                            .build()
                    }
                    
                    for event in events {
                        await queue.enqueue(event)
                    }
                    
                    await queue.shutdown()
                    
                    // Queue should still have events but won't flush
                    await expect { await queue.getQueueSize() }.to(equal(3))
                }
            }
            
            // MARK: - Integration Tests
            
            describe("integration scenarios") {
                beforeEach {
                    queue = NuxieNetworkQueue(
                        flushAt: 10,  // Higher threshold to prevent auto-flush during test setup
                        flushIntervalSeconds: 30,
                        maxQueueSize: 10,
                        maxBatchSize: 5,
                        apiClient: mockApi
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
                        await queue.enqueue(event)
                    }
                    
                    // Should have triggered multiple flushes
                    // and dropped oldest events when queue was full
                    await expect { await mockApi.sendBatchCallCount }
                        .toEventually(beGreaterThan(0), timeout: .seconds(2))
                    await expect { await queue.getQueueSize() }
                        .toEventually(beLessThanOrEqualTo(10), timeout: .seconds(2))
                }
                
                it("should handle mixed success and failure scenarios") {
                    // Create a queue with shorter retry delay for testing
                    let testQueue = NuxieNetworkQueue(
                        flushAt: 10,
                        flushIntervalSeconds: 30,
                        maxQueueSize: 10,
                        maxBatchSize: 5,
                        baseRetryDelay: 0.1,  // Short retry delay for testing
                        apiClient: mockApi
                    )
                    
                    let events = (0..<4).map { i in
                        TestEventBuilder(name: "event_\(i)")
                            .withDistinctId("user123")
                            .build()
                    }
                    
                    for event in events {
                        await testQueue.enqueue(event)
                    }
                    
                    // First flush fails
                    await mockApi.setFailure(true, error: URLError(.timedOut))
                    
                    let result1 = await testQueue.flush()
                    expect(result1).to(beTrue())
                    await expect { await testQueue.getQueueSize() }.to(equal(4)) // Events retained after failure
                    
                    // Wait for retry backoff to expire (0.1 seconds base delay)
                    try? await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds
                    
                    // Second flush succeeds
                    await mockApi.setFailure(false)
                    
                    let result2 = await testQueue.flush()
                    expect(result2).to(beTrue())
                    await expect { await testQueue.getQueueSize() }.to(equal(0)) // All events sent
                    
                    await testQueue.shutdown()
                }
            }
        }
    }
}
