import Foundation
import Quick
import Nimble
@_spi(Testing) @testable import Nuxie
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
                testConfig.testingOverrides.flushAt = 100  // manual flush only

                mockStore = MockEventStore()
                mockApi = MockNuxieApi()
                mockIdentity = MockIdentityService()

                log = EventLog(
                    identity: mockIdentity,
                    dateProvider: MockDateProvider(),
                    apiClient: mockApi,
                    store: mockStore
                )
            }

            afterEach {
                await log?.close()
                log = nil
            }

            it("fails setup closed when the event-store schema is unsupported") {
                mockStore.initializeFailure = .invalidSchema

                await expect {
                    try await log.configure(configuration: testConfig)
                }.to(throwError { error in
                    guard case EventStorageError.invalidSchema = error else {
                        return fail("Expected invalidSchema, got \(error)")
                    }
                })
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

                it("does not let a stable capture overtake accepted fire-and-forget work") {
                    let received = ReceivedEvents()
                    await log.subscribeCommitted { event in
                        await received.append(event.name)
                    }
                    try await log.configure(configuration: testConfig)
                    mockStore.suspendNextInsert()

                    log.track(
                        "ordinary-before-stable",
                        properties: nil,
                        userProperties: nil,
                        userPropertiesSetOnce: nil
                    )
                    await expect { mockStore.waitingInsertIds.isEmpty }
                        .toEventually(beFalse(), timeout: .seconds(1))
                    guard let ordinaryID = mockStore.waitingInsertIds.first else {
                        return fail("Expected the ordinary insert to be suspended")
                    }
                    defer { mockStore.resumeInsert(id: ordinaryID) }

                    let stableTask = Task {
                        await log.captureAndRouteSystemEvent(
                            .init(
                                name: JourneyEvents.journeyLegStarted,
                                properties: nil,
                                eventId: "stable-after-ordinary",
                                distinctId: "customer-a"
                            )
                        )
                    }
                    for _ in 0..<10 { await Task.yield() }

                    expect(mockStore.stableCaptureCommitCallCount).to(equal(0))
                    expect(mockStore.storedEvents.map(\.name))
                        .toNot(contain(JourneyEvents.journeyLegStarted))

                    mockStore.resumeInsert(id: ordinaryID)
                    guard await stableTask.value != nil else {
                        return fail("Expected stable capture")
                    }
                    await log.drain()

                    expect(mockStore.storedEvents.map(\.name)).to(equal([
                        "ordinary-before-stable",
                        JourneyEvents.journeyLegStarted,
                    ]))
                    await expect { await received.names }.to(equal([
                        "ordinary-before-stable",
                        JourneyEvents.journeyLegStarted,
                    ]))
                }

                it("allows a committed subscriber to durably capture another routed event") {
                    let received = ReceivedEvents()
                    let sink = TriggerSystemEventSink(
                        routedEvents: log,
                        triggerProvider: { MockTriggerService() }
                    )
                    await log.subscribeCommitted { event in
                        await received.append(event.name)
                        guard event.name == "outer" else { return }
                        let committed = await sink.capture(
                            .init(
                                name: "nested",
                                properties: nil,
                                eventId: "nested-from-committed-subscriber",
                                distinctId: event.distinctId
                            )
                        )
                        expect(committed).to(beTrue())
                    }
                    try await log.configure(configuration: testConfig)

                    log.track(
                        "outer",
                        properties: nil,
                        userProperties: nil,
                        userPropertiesSetOnce: nil
                    )
                    await log.drain()

                    await expect { await received.names }.to(equal(["outer", "nested"]))
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

                it("delivers the subscriber admission captured at the track boundary") {
                    let generation = AdmissionGeneration(1)
                    let received = ReceivedAdmissions()
                    await log.subscribeCommitted(
                        admission: { generation.value }
                    ) { event, admission in
                        await received.append(
                            event: event.name,
                            admission: admission
                        )
                    }

                    log.track(
                        "captured_before_replacement",
                        properties: nil,
                        userProperties: nil,
                        userPropertiesSetOnce: nil
                    )
                    generation.set(2)
                    try await log.configure(configuration: testConfig)
                    await log.drain()

                    await expect { await received.values }.to(equal([
                        .init(
                            event: "captured_before_replacement",
                            admission: 1
                        ),
                    ]))
                }

                it("preserves admission reserved before a late pre-configure subscription") {
                    let generation = AdmissionGeneration(7)
                    let received = ReceivedAdmissions()
                    let reservation = log.reserveCommittedAdmission {
                        generation.value
                    }

                    log.track(
                        "captured_before_subscription",
                        properties: nil,
                        userProperties: nil,
                        userPropertiesSetOnce: nil
                    )
                    generation.set(8)
                    await log.subscribeCommitted(
                        reservation: reservation
                    ) { event, admission in
                        await received.append(
                            event: event.name,
                            admission: admission
                        )
                    }
                    try await log.configure(configuration: testConfig)
                    await log.drain()

                    await expect { await received.values }.to(equal([
                        .init(
                            event: "captured_before_subscription",
                            admission: 7
                        ),
                    ]))
                }

                it("preserves commit order when a routed stable capture resumes after a later capture") {
                    let received = ReceivedEvents()
                    await log.subscribeCommitted { event in
                        await received.append(event.name)
                    }
                    try await log.configure(configuration: testConfig)
                    let stableId = "stable-before-later"
                    mockStore.suspendStableCaptureAfterCommit(id: stableId)
                    defer { mockStore.resumeStableCaptureAfterCommit(id: stableId) }
                    let stableTask = Task {
                        await log.captureAndRouteSystemEvent(
                            .init(
                                name: JourneyEvents.journeyLegStarted,
                                properties: nil,
                                eventId: stableId,
                                distinctId: "customer-a"
                            )
                        )
                    }
                    await expect {
                        mockStore.isStableCaptureAfterCommitWaiting(id: stableId)
                    }.toEventually(beTrue(), timeout: .seconds(1))

                    log.track("later", properties: nil, userProperties: nil, userPropertiesSetOnce: nil)
                    await expect {
                        mockStore.storedEvents.contains { $0.name == "later" }
                    }.toEventually(beTrue(), timeout: .seconds(1))
                    await expect { await received.names }.to(equal([]))

                    mockStore.resumeStableCaptureAfterCommit(id: stableId)
                    guard await stableTask.value != nil else {
                        return fail("Expected stable capture")
                    }
                    await log.drain()

                    await expect { await received.names }.to(equal([
                        JourneyEvents.journeyLegStarted,
                        "later",
                    ]))
                }

                it("routes a stable event batch only after every item commits") {
                    mockIdentity.setDistinctId("customer-a")
                    guard let identityFence = mockIdentity.performWithCurrentIdentityFence(
                        "customer-a",
                        { _ in () }
                    ) else {
                        return fail("Expected current identity fence")
                    }
                    let executionFence = DeviceLegProfileFence()
                    let generation = executionFence.advance()
                    guard let executionToken = executionFence.token(
                        ifCurrent: generation
                    ) else {
                        return fail("Expected current execution fence")
                    }
                    let admission = DeviceLegCommitAdmission(
                        identity: mockIdentity,
                        identityFenceToken: identityFence.token,
                        executionFence: executionFence,
                        executionFenceToken: executionToken
                    )
                    let received = ReceivedEvents()
                    await log.subscribeCommitted { event in
                        await received.append(event.name)
                    }
                    try await log.configure(configuration: testConfig)
                    let batch = [
                        RoutedStableSystemEventBatchItem(
                            request: .init(
                                name: "first",
                                properties: [:],
                                eventId: "stable-batch:first",
                                distinctId: "customer-a"
                            ),
                            occurredAt: Date(timeIntervalSince1970: 1_000)
                        ),
                        RoutedStableSystemEventBatchItem(
                            request: .init(
                                name: "second",
                                properties: [:],
                                eventId: "stable-batch:second",
                                distinctId: "customer-a"
                            ),
                            occurredAt: Date(timeIntervalSince1970: 1_001)
                        ),
                    ]

                    mockStore.stableCaptureBatchFailureIndex = 1
                    let failed = await log.captureAndRouteSystemEventBatch(
                        batch,
                        admission: admission
                    )
                    expect(failed).to(beNil())
                    expect(mockStore.storedEvents).to(beEmpty())
                    await expect { await received.names }.to(beEmpty())

                    mockStore.stableCaptureBatchFailureIndex = nil
                    mockStore.suspendNextInsert()
                    log.track(
                        "ordinary-before-batch",
                        properties: nil,
                        userProperties: nil,
                        userPropertiesSetOnce: nil
                    )
                    await expect { mockStore.waitingInsertIds.isEmpty }
                        .toEventually(beFalse(), timeout: .seconds(1))
                    guard let ordinaryID = mockStore.waitingInsertIds.first else {
                        return fail("Expected the ordinary insert to be suspended")
                    }
                    defer { mockStore.resumeInsert(id: ordinaryID) }
                    let batchTask = Task {
                        await log.captureAndRouteSystemEventBatch(
                            batch,
                            admission: admission
                        )
                    }
                    for _ in 0..<10 { await Task.yield() }
                    expect(mockStore.storedEvents.map(\.name)).toNot(contain("first"))
                    expect(mockStore.storedEvents.map(\.name)).toNot(contain("second"))

                    mockStore.resumeInsert(id: ordinaryID)
                    let committed = await batchTask.value
                    expect(committed).toNot(beNil())
                    expect(committed?["stable-batch:first"]?.routesLocally)
                        .to(beTrue())
                    expect(committed?["stable-batch:second"]?.routesLocally)
                        .to(beTrue())
                    await log.drain()
                    expect(mockStore.storedEvents.map(\.name)).to(equal([
                        "ordinary-before-batch",
                        "first",
                        "second",
                    ]))
                    await expect { await received.names }.to(equal([
                        "ordinary-before-batch",
                        "first",
                        "second",
                    ]))
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
                        JourneyEvents.journeyTransition,
                        properties: ["version": "1.0.0"]
                    )

                    let stored = mockStore.storedEvents.first {
                        $0.name == JourneyEvents.journeyTransition
                    }
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

                it("retains authentication-rejected direct journey facts") {
                    await mockApi.configureTrackEventFailure(
                        error: NuxieNetworkError.httpError(
                            statusCode: 401,
                            message: "Unauthorized"
                        )
                    )
                    try await log.configure(configuration: testConfig)

                    await expect {
                        try await log.trackWithResponse(
                            JourneyEvents.journeyTransition,
                            properties: nil
                        )
                    }.to(throwError())

                    expect(mockStore.pendingIds).to(haveCount(1))
                    expect(mockStore.deliveredIds).to(beEmpty())
                    await expect { await log.deliveryHealthState() }
                        .to(equal("unhealthy_authentication"))
                }

                it("retains a retryable direct fact in memory when persistence fails") {
                    mockStore.shouldFailStore = true
                    await mockApi.configureTrackEventFailure(
                        error: NuxieNetworkError.httpError(
                            statusCode: 401,
                            message: "Unauthorized"
                        )
                    )
                    try await log.configure(configuration: testConfig)

                    await expect {
                        try await log.trackWithResponse(
                            JourneyEvents.journeyTransition,
                            properties: nil
                        )
                    }.to(throwError())
                    await expect { await log.getQueuedEventCount() }.to(equal(1))
                    expect(mockStore.pendingIds).to(beEmpty())

                    await mockApi.reset()
                    _ = await log.performFlush(forceSend: true)
                    await expect { await log.getQueuedEventCount() }.to(equal(0))
                }

                it("retains rate-limited direct journey facts") {
                    await mockApi.configureTrackEventFailure(
                        error: NuxieNetworkError.httpError(
                            statusCode: 429,
                            message: "Too Many Requests",
                            retryAfter: "60"
                        )
                    )
                    try await log.configure(configuration: testConfig)

                    await expect {
                        try await log.trackWithResponse(
                            JourneyEvents.journeyTransition,
                            properties: nil
                        )
                    }.to(throwError())

                    expect(mockStore.pendingIds).to(haveCount(1))
                    expect(mockStore.deliveredIds).to(beEmpty())
                    let retry = await log.retryBackoffState()
                    expect(retry.remainingDelay).toNot(beNil())
                }

                it("terminally retires a singleton oversized direct journey fact") {
                    await mockApi.configureTrackEventFailure(
                        error: NuxieNetworkError.httpError(
                            statusCode: 413,
                            message: "Payload Too Large"
                        )
                    )
                    try await log.configure(configuration: testConfig)

                    await expect {
                        try await log.trackWithResponse(
                            JourneyEvents.journeyTransition,
                            properties: nil
                        )
                    }.to(throwError())

                    expect(mockStore.pendingIds).to(beEmpty())
                    expect(mockStore.deliveredIds).to(haveCount(1))
                }
            }

            // MARK: - Retention

            describe("retention") {
                it("caps stored history at maxEventsStored") {
                    let cappedLog = EventLog(
                        identity: MockIdentityService(),
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

            describe("event-history horizon") {
                it("starts fresh coverage at first open and never moves it backward across restart or clock rollback") {
                    let firstOpen = Date(timeIntervalSince1970: 1_786_550_400)
                    let dateProvider = MockDateProvider(initialDate: firstOpen)
                    let firstLog = EventLog(
                        identity: mockIdentity,
                        dateProvider: dateProvider,
                        apiClient: mockApi,
                        store: mockStore
                    )
                    try await firstLog.configure(configuration: testConfig)
                    let initialCoverage = try await firstLog.historyCoverage()
                    expect(initialCoverage).to(equal(
                        .retainedWindow(startingAt: firstOpen)
                    ))
                    await firstLog.close()

                    dateProvider.advance(by: 86_400)
                    let relaunchedLog = EventLog(
                        identity: mockIdentity,
                        dateProvider: dateProvider,
                        apiClient: mockApi,
                        store: mockStore
                    )
                    try await relaunchedLog.configure(configuration: testConfig)
                    let relaunchedCoverage = try await relaunchedLog.historyCoverage()
                    expect(relaunchedCoverage).to(equal(
                        .retainedWindow(startingAt: firstOpen)
                    ))

                    dateProvider.setCurrentDate(firstOpen.addingTimeInterval(-86_400))
                    let rollbackCoverage = try await relaunchedLog.historyCoverage()
                    expect(rollbackCoverage).to(equal(
                        .retainedWindow(startingAt: firstOpen)
                    ))
                    await relaunchedLog.close()
                }

                it("persists a fail-closed fence when a history write fails and survives recovery and relaunch") {
                    let firstOpen = Date(timeIntervalSince1970: 1_786_550_400)
                    let failedEvent = NuxieEvent(
                        id: "failed-history-event",
                        name: "purchase",
                        distinctId: mockIdentity.getDistinctId(),
                        properties: ["plan": "pro"],
                        timestamp: firstOpen.addingTimeInterval(60)
                    )
                    let firstLog = EventLog(
                        identity: mockIdentity,
                        dateProvider: MockDateProvider(initialDate: firstOpen),
                        apiClient: mockApi,
                        store: mockStore
                    )
                    try await firstLog.configure(configuration: testConfig)
                    mockStore.shouldFailStore = true
                    await firstLog.storePreparedEventInHistory(failedEvent)
                    mockStore.shouldFailStore = false

                    guard case .retainedWindow(let fencedAt) = try await firstLog.historyCoverage() else {
                        await firstLog.close()
                        return fail("production history must remain retention-bounded")
                    }
                    expect(fencedAt).to(beGreaterThan(failedEvent.timestamp))
                    await firstLog.close()

                    let evaluationTime = failedEvent.timestamp.addingTimeInterval(60)
                    let relaunchedLog = EventLog(
                        identity: mockIdentity,
                        dateProvider: MockDateProvider(initialDate: evaluationTime),
                        apiClient: mockApi,
                        store: mockStore
                    )
                    try await relaunchedLog.configure(configuration: testConfig)
                    let boundedCountIsZero = IRExpr.compare(
                        op: "==",
                        left: .eventsCount(
                            name: "purchase",
                            since: nil,
                            until: nil,
                            within: .duration(180),
                            where_: .pred(op: "eq", key: "plan", value: .string("pro"))
                        ),
                        right: .number(0)
                    )
                    let result = await IRRuntime(
                        dateProvider: MockDateProvider(initialDate: evaluationTime)
                    ).eval(
                        .init(
                            ir_version: 1,
                            engine_min: nil,
                            compiled_at: nil,
                            expr: .not(boundedCountIsZero)
                        ),
                        .init(
                            now: evaluationTime,
                            events: IREventQueriesAdapter(eventLog: relaunchedLog)
                        )
                    )

                    expect(result).to(beFalse())
                    await relaunchedLog.close()
                }

                it("treats corrupt persisted properties as unknown instead of satisfying is_not_set") {
                    let now = Date(timeIntervalSince1970: 1_786_550_400)
                    mockStore.historyCoverageStart = now.addingTimeInterval(-3_600)
                    mockStore.storedEvents = [StoredEvent(
                        id: "corrupt-properties",
                        name: "purchase",
                        properties: Data("not-json".utf8),
                        timestamp: now.addingTimeInterval(-60),
                        distinctId: mockIdentity.getDistinctId(),
                    )]
                    let corruptLog = EventLog(
                        identity: mockIdentity,
                        dateProvider: MockDateProvider(initialDate: now),
                        apiClient: mockApi,
                        store: mockStore
                    )
                    try await corruptLog.configure(configuration: testConfig)
                    let value = try await IRInterpreter(ctx: .init(
                        now: now,
                        events: IREventQueriesAdapter(eventLog: corruptLog)
                    )).evalValue(.eventsCount(
                        name: "purchase",
                        since: nil,
                        until: nil,
                        within: .duration(600),
                        where_: .pred(op: "is_not_set", key: "plan", value: nil)
                    ))

                    expect(value).to(equal(.unknown))
                    await corruptLog.close()
                }

                it("treats a lower bound before the retained age horizon as unknown") {
                    let now = Date(timeIntervalSince1970: 1_786_550_400)
                    let horizonLog = EventLog(
                        identity: mockIdentity,
                        dateProvider: MockDateProvider(initialDate: now),
                        apiClient: mockApi,
                        store: mockStore
                    )
                    let userId = mockIdentity.getDistinctId()
                    mockStore.storedEvents = [try StoredEvent(
                        id: "recent-purchase",
                        name: "purchase",
                        properties: ["plan": "pro"],
                        timestamp: now.addingTimeInterval(-60),
                        distinctId: userId
                    )]
                    try await horizonLog.configure(configuration: testConfig)
                    let interpreter = IRInterpreter(ctx: EvalContext(
                        now: now,
                        events: IREventQueriesAdapter(eventLog: horizonLog)
                    ))

                    let value = try await interpreter.evalValue(.eventsCount(
                        name: "purchase",
                        since: nil,
                        until: nil,
                        within: .duration(31 * 86_400),
                        where_: .pred(op: "eq", key: "plan", value: .string("pro"))
                    ))

                    expect(value).to(equal(.unknown))
                    await horizonLog.close()
                }

                it("advances the retained horizon past the count-retention boundary") {
                    let now = Date(timeIntervalSince1970: 1_786_550_400)
                    let cappedLog = EventLog(
                        identity: mockIdentity,
                        dateProvider: MockDateProvider(initialDate: now),
                        apiClient: mockApi,
                        store: mockStore,
                        maxEventsStored: 3,
                        cleanupCheckInterval: 1
                    )
                    let userId = mockIdentity.getDistinctId()
                    mockStore.historyCoverageStart = now.addingTimeInterval(-3_600)
                    mockStore.storedEvents = try [10, 5, 1].map { minutesAgo in
                        try StoredEvent(
                            id: "purchase-\(minutesAgo)",
                            name: "purchase",
                            properties: ["plan": "pro"],
                            timestamp: now.addingTimeInterval(TimeInterval(-minutesAgo * 60)),
                            distinctId: userId
                        )
                    }
                    try await cappedLog.configure(configuration: testConfig)
                    await cappedLog.storePreparedEventInHistory(NuxieEvent(
                        id: "purchase-now",
                        name: "purchase",
                        distinctId: userId,
                        properties: ["plan": "pro"],
                        timestamp: now
                    ))
                    let interpreter = IRInterpreter(ctx: EvalContext(
                        now: now,
                        events: IREventQueriesAdapter(eventLog: cappedLog)
                    ))

                    let crossingBoundary = try await interpreter.evalValue(.eventsCount(
                        name: "purchase",
                        since: nil,
                        until: nil,
                        within: .duration(11 * 60),
                        where_: .pred(op: "eq", key: "plan", value: .string("pro"))
                    ))
                    let coveredWindow = try await interpreter.evalValue(.eventsCount(
                        name: "purchase",
                        since: nil,
                        until: nil,
                        within: .duration(9 * 60),
                        where_: .pred(op: "eq", key: "plan", value: .string("pro"))
                    ))

                    expect(crossingBoundary).to(equal(.unknown))
                    expect(coveredWindow).to(equal(.number(3)))
                    await cappedLog.close()
                }

                it("treats a saturated bounded predicate query as unknown") {
                    let now = Date(timeIntervalSince1970: 1_786_550_400)
                    let saturatedLog = EventLog(
                        identity: mockIdentity,
                        dateProvider: MockDateProvider(initialDate: now),
                        apiClient: mockApi,
                        store: mockStore,
                        maxEventsStored: 20_000
                    )
                    let userId = mockIdentity.getDistinctId()
                    mockStore.storedEvents = try (0...10_000).map { index in
                        try StoredEvent(
                            id: "bounded-\(index)",
                            name: "purchase",
                            properties: ["plan": "pro"],
                            timestamp: now.addingTimeInterval(TimeInterval(-index)),
                            distinctId: userId
                        )
                    }
                    try await saturatedLog.configure(configuration: testConfig)
                    let interpreter = IRInterpreter(ctx: EvalContext(
                        now: now,
                        events: IREventQueriesAdapter(eventLog: saturatedLog)
                    ))

                    let value = try await interpreter.evalValue(.eventsCount(
                        name: "purchase",
                        since: nil,
                        until: nil,
                        within: .duration(86_400),
                        where_: .pred(op: "eq", key: "plan", value: .string("pro"))
                    ))

                    expect(value).to(equal(.unknown))
                    await saturatedLog.close()
                }

                it("propagates an event-store predicate query failure as unknown") {
                    let now = Date(timeIntervalSince1970: 1_786_550_400)
                    let failureLog = EventLog(
                        identity: mockIdentity,
                        dateProvider: MockDateProvider(initialDate: now),
                        apiClient: mockApi,
                        store: mockStore
                    )
                    let userId = mockIdentity.getDistinctId()
                    mockStore.storedEvents = [try StoredEvent(
                        id: "recent-purchase",
                        name: "purchase",
                        properties: ["plan": "pro"],
                        timestamp: now.addingTimeInterval(-60),
                        distinctId: userId
                    )]
                    try await failureLog.configure(configuration: testConfig)
                    mockStore.shouldFailIRQuery = true
                    let interpreter = IRInterpreter(ctx: EvalContext(
                        now: now,
                        events: IREventQueriesAdapter(eventLog: failureLog)
                    ))

                    let value = try await interpreter.evalValue(.eventsCount(
                        name: "purchase",
                        since: nil,
                        until: nil,
                        within: .duration(86_400),
                        where_: .pred(op: "eq", key: "plan", value: .string("pro"))
                    ))

                    expect(value).to(equal(.unknown))
                    await failureLog.close()
                }

                it("does not let negation or a nested predicate authorize after a query failure") {
                    let now = Date(timeIntervalSince1970: 1_786_550_400)
                    let failureLog = EventLog(
                        identity: mockIdentity,
                        dateProvider: MockDateProvider(initialDate: now),
                        apiClient: mockApi,
                        store: mockStore
                    )
                    let userId = mockIdentity.getDistinctId()
                    mockStore.storedEvents = [try StoredEvent(
                        id: "recent-purchase",
                        name: "purchase",
                        properties: ["amount": 5],
                        timestamp: now.addingTimeInterval(-60),
                        distinctId: userId
                    )]
                    try await failureLog.configure(configuration: testConfig)
                    mockStore.shouldFailIRQuery = true
                    let queries = IREventQueriesAdapter(eventLog: failureLog)
                    let runtime = IRRuntime(dateProvider: MockDateProvider(initialDate: now))
                    let boundedCount = IRExpr.eventsCount(
                        name: "purchase",
                        since: nil,
                        until: nil,
                        within: .duration(86_400),
                        where_: .pred(op: "eq", key: "amount", value: .number(5))
                    )
                    let nestedCount = IRExpr.eventsCount(
                        name: "purchase",
                        since: nil,
                        until: nil,
                        within: .duration(86_400),
                        where_: .pred(
                            op: "eq",
                            key: "amount",
                            value: .eventsAggregate(
                                agg: "sum",
                                name: "purchase",
                                prop: "amount",
                                since: nil,
                                until: nil,
                                within: .duration(86_400),
                                where_: nil
                            )
                        )
                    )

                    for expression in [IRExpr.not(boundedCount), .not(nestedCount)] {
                        let result = await runtime.eval(
                            .init(
                                ir_version: 1,
                                engine_min: nil,
                                compiled_at: nil,
                                expr: expression
                            ),
                            .init(now: now, events: queries)
                        )
                        expect(result).to(beFalse())
                    }
                    await failureLog.close()
                }

                it("does not turn a truncated lifetime predicate count into a definitive comparison") {
                    let userId = mockIdentity.getDistinctId()
                    mockStore.storedEvents = try (0...10_000).map { index in
                        try StoredEvent(
                            id: "retained-\(index)",
                            name: "purchase",
                            properties: ["plan": "pro"],
                            timestamp: Date(timeIntervalSince1970: TimeInterval(index)),
                            distinctId: userId
                        )
                    }
                    try await log.configure(configuration: testConfig)
                    let interpreter = IRInterpreter(ctx: EvalContext(
                        now: Date(timeIntervalSince1970: 20_000),
                        events: IREventQueriesAdapter(eventLog: log)
                    ))
                    let lifetimeCountIsBelowExactTotal = IRExpr.compare(
                        op: "<",
                        left: .eventsCount(
                            name: "purchase",
                            since: nil,
                            until: nil,
                            within: nil,
                            where_: .pred(op: "eq", key: "plan", value: .string("pro"))
                        ),
                        right: .number(10_001)
                    )

                    do {
                        _ = try await interpreter.evalBool(lifetimeCountIsBelowExactTotal)
                        fail("Expected retained-only lifetime history to be unknown")
                    } catch IRError.incompleteEventHistory {
                        // The interpreter preserves unknown; IRRuntime below
                        // turns it into the authored fail-closed result.
                    }

                    let runtime = IRRuntime(dateProvider: MockDateProvider())
                    let negated = IREnvelope(
                        ir_version: 1,
                        engine_min: nil,
                        compiled_at: nil,
                        expr: .not(lifetimeCountIsBelowExactTotal)
                    )
                    let runtimeResult = await runtime.eval(
                        negated,
                        .init(
                            now: Date(timeIntervalSince1970: 20_000),
                            events: IREventQueriesAdapter(eventLog: log)
                        )
                    )
                    expect(runtimeResult).to(beFalse())
                }

                it("marks lifetime first-time and aggregate values unknown when data spans the age cutoff") {
                    let now = Date(timeIntervalSince1970: 1_786_550_400)
                    let userId = mockIdentity.getDistinctId()
                    mockStore.storedEvents = [
                        try StoredEvent(
                            id: "older-than-retention",
                            name: "purchase",
                            properties: ["plan": "pro", "amount": 100],
                            timestamp: now.addingTimeInterval(-31 * 86_400),
                            distinctId: userId
                        ),
                        try StoredEvent(
                            id: "inside-retention",
                            name: "purchase",
                            properties: ["plan": "pro", "amount": 5],
                            timestamp: now.addingTimeInterval(-60),
                            distinctId: userId
                        )
                    ]
                    try await log.configure(configuration: testConfig)
                    let queries = IREventQueriesAdapter(eventLog: log)
                    let interpreter = IRInterpreter(ctx: EvalContext(now: now, events: queries))
                    let predicate = IRExpr.pred(
                        op: "eq", key: "plan", value: .string("pro")
                    )

                    let coverage = try await queries.historyCoverage()
                    guard case .retainedWindow = coverage else {
                        fail("Expected production history to report a retained horizon")
                        return
                    }
                    await expect {
                        try await interpreter.evalValue(
                            .eventsFirstTime(name: "purchase", where_: predicate)
                        )
                    }.to(equal(.unknown))
                    await expect {
                        try await interpreter.evalValue(
                            .eventsLastTime(name: "purchase", where_: predicate)
                        )
                    }.to(equal(.unknown))
                    await expect {
                        try await interpreter.evalValue(.eventsAggregate(
                            agg: "sum",
                            name: "purchase",
                            prop: "amount",
                            since: nil,
                            until: nil,
                            within: nil,
                            where_: predicate
                        ))
                    }.to(equal(.unknown))

                    await expect {
                        try await interpreter.evalValue(.eventsAggregate(
                            agg: "sum",
                            name: "purchase",
                            prop: "amount",
                            since: nil,
                            until: nil,
                            within: .duration(30 * 86_400),
                            where_: predicate
                        ))
                    }.to(equal(.number(5)))
                }

                it("keeps lower-bounded predicates deterministic over the retained window") {
                    let now = Date(timeIntervalSince1970: 1_786_550_400)
                    let userId = mockIdentity.getDistinctId()
                    mockStore.storedEvents = [try StoredEvent(
                        id: "recent-purchase",
                        name: "purchase",
                        properties: ["plan": "pro"],
                        timestamp: now.addingTimeInterval(-60),
                        distinctId: userId
                    )]
                    try await log.configure(configuration: testConfig)
                    let interpreter = IRInterpreter(ctx: EvalContext(
                        now: now,
                        events: IREventQueriesAdapter(eventLog: log)
                    ))
                    let boundedCount = IRExpr.compare(
                        op: "==",
                        left: .eventsCount(
                            name: "purchase",
                            since: nil,
                            until: nil,
                            within: .duration(86_400),
                            where_: .pred(op: "eq", key: "plan", value: .string("pro"))
                        ),
                        right: .number(1)
                    )

                    await expect { try await interpreter.evalBool(boundedCount) }.to(beTrue())
                }

                it("does not coerce unknown lifetime values inside a bounded predicate") {
                    let now = Date(timeIntervalSince1970: 1_786_550_400)
                    let userId = mockIdentity.getDistinctId()
                    mockStore.storedEvents = [try StoredEvent(
                        id: "recent-purchase",
                        name: "purchase",
                        properties: ["amount": 5],
                        timestamp: now.addingTimeInterval(-60),
                        distinctId: userId
                    )]
                    try await log.configure(configuration: testConfig)
                    let runtime = IRRuntime(dateProvider: MockDateProvider())
                    let predicateUsesLifetimeAggregate = IRExpr.eventsCount(
                        name: "purchase",
                        since: nil,
                        until: nil,
                        within: .duration(86_400),
                        where_: .pred(
                            op: "neq",
                            key: "amount",
                            value: .eventsAggregate(
                                agg: "sum",
                                name: "purchase",
                                prop: "amount",
                                since: nil,
                                until: nil,
                                within: nil,
                                where_: nil
                            )
                        )
                    )
                    let result = await runtime.eval(
                        .init(
                            ir_version: 1,
                            engine_min: nil,
                            compiled_at: nil,
                            expr: .not(predicateUsesLifetimeAggregate)
                        ),
                        .init(
                            now: now,
                            events: IREventQueriesAdapter(eventLog: log)
                        )
                    )

                    expect(result).to(beFalse())
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

                it("does not deadlock a queued ownership decision behind a waiting trigger") {
                    let transport = DecisionPredecessorPreparedEventTransport()
                    let orderedLog = EventLog(
                        identity: MockIdentityService(),
                        dateProvider: MockDateProvider(),
                        apiClient: transport,
                        store: mockStore
                    )
                    log = orderedLog
                    try await orderedLog.configure(configuration: testConfig)
                    let callback = DecisionOwnershipCallbackRecorder()
                    let decisionStore = mockStore!
                    await orderedLog.setJourneyHandoffDeliveredHandler { journeyId in
                        await callback.record(
                            journeyId: journeyId,
                            sourceWasAcknowledged: decisionStore.deliveredIds.contains(
                                "queued-handoff-before-prepared"
                            )
                        )
                    }

                    await orderedLog.enqueueForDelivery(NuxieEvent(
                        id: "queued-handoff-before-prepared",
                        name: JourneyEvents.journeyHandoff,
                        distinctId: "test-distinct-id",
                        properties: [
                            "journey_id": "deadlock-journey",
                            "epoch": 0,
                        ]
                    ))
                    let prepared = await orderedLog.commitPreparedTriggerEvent(
                        NuxieEvent(
                            id: "prepared-after-handoff-id",
                            name: "prepared_first",
                            distinctId: "test-distinct-id"
                        )
                    )
                    await transport.waitUntilDecisionStarted()
                    let waitingTrigger = Task {
                        try await orderedLog.trackForTrigger("direct_second")
                    }
                    await expect { await orderedLog.triggerDeliveryIsHeld() }
                        .toEventually(beTrue())

                    await transport.releaseDecision()

                    _ = await prepared.response.value
                    _ = try await waitingTrigger.value
                    await expect { await transport.startedNames }.to(equal([
                        JourneyEvents.journeyHandoff,
                        "prepared_first",
                        "direct_second",
                    ]))
                    await expect { await callback.journeyIds }
                        .to(equal(["deadlock-journey"]))
                    await expect { await callback.sourceWasAcknowledgedAtCallback }
                        .to(equal([false]))
                    expect(mockStore.deliveredIds)
                        .to(contain("queued-handoff-before-prepared"))
                }

                it("keeps later prepared events behind an older failed delivery") {
                    let transport = FailedPredecessorPreparedEventTransport()
                    let orderedLog = EventLog(
                        identity: MockIdentityService(),
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

                it("cancels only the old identity's prepared delivery and releases its row") {
                    let transport = ScopedCancellationEventTransport()
                    let orderedLog = EventLog(
                        identity: MockIdentityService(),
                        dateProvider: MockDateProvider(),
                        apiClient: transport,
                        store: mockStore
                    )
                    log = orderedLog
                    try await orderedLog.configure(configuration: testConfig)

                    let old = await orderedLog.commitPreparedTriggerEvent(
                        NuxieEvent(
                            id: "old-prepared-id",
                            name: "old_prepared",
                            distinctId: "old-user"
                        )
                    )
                    await transport.waitUntilOldStarted()
                    let new = await orderedLog.commitPreparedTriggerEvent(
                        NuxieEvent(
                            id: "new-prepared-id",
                            name: "new_prepared",
                            distinctId: "new-user"
                        )
                    )

                    await orderedLog.cancelPreparedResponseDeliveries(for: "old-user")

                    let oldResponse = await old.response.value
                    let newResponse = await new.response.value
                    expect(oldResponse.status).to(equal("offline"))
                    expect(newResponse.status).to(equal("ok"))
                    await expect { await transport.directNames }
                        .to(equal(["old_prepared", "new_prepared"]))
                    await expect { await transport.batchNames }
                        .to(equal([["old_prepared"]]))
                    expect(mockStore.deliveredIds)
                        .to(contain("old-prepared-id", "new-prepared-id"))
                }

                it("settles an in-flight authored delivery before closing its store") {
                    let transport = CancellableEventTransport()
                    let closingStore = MockEventStore()
                    let closingLog = EventLog(
                        identity: MockIdentityService(),
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

private final class AdmissionGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: UInt64

    init(_ value: UInt64) {
        stored = value
    }

    var value: UInt64 { lock.withLock { stored } }

    func set(_ value: UInt64) {
        lock.withLock { stored = value }
    }
}

private actor ReceivedAdmissions {
    struct Value: Equatable {
        let event: String
        let admission: UInt64?
    }

    private(set) var values: [Value] = []

    func append(event: String, admission: UInt64?) {
        values.append(.init(event: event, admission: admission))
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

private actor ScopedCancellationEventTransport: EventTransport {
    private var oldStarted = false
    private var oldStartWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var directNames: [String] = []
    private(set) var batchNames: [[String]] = []

    func waitUntilOldStarted() async {
        guard !oldStarted else { return }
        await withCheckedContinuation { oldStartWaiters.append($0) }
    }

    func sendBatch(events: [BatchEventItem]) async throws -> BatchResponse {
        batchNames.append(events.map(\.event))
        return BatchResponse(
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
        EventResponse(status: "ok", eventId: event)
    }

    func trackEvent(_ event: NuxieEvent) async throws -> EventResponse {
        directNames.append(event.name)
        if event.distinctId == "old-user" {
            oldStarted = true
            oldStartWaiters.forEach { $0.resume() }
            oldStartWaiters.removeAll()
            try await Task.sleep(nanoseconds: 30_000_000_000)
        }
        return EventResponse(status: "ok", eventId: event.id)
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

private actor DecisionPredecessorPreparedEventTransport: EventTransport {
    private var started: [String] = []
    private var decisionStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var decisionRelease: CheckedContinuation<Void, Never>?
    private var decisionReleased = false

    var startedNames: [String] { started }

    func waitUntilDecisionStarted() async {
        guard !started.contains(JourneyEvents.journeyHandoff) else { return }
        await withCheckedContinuation { decisionStartWaiters.append($0) }
    }

    func releaseDecision() {
        decisionReleased = true
        decisionRelease?.resume()
        decisionRelease = nil
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
        guard name == JourneyEvents.journeyHandoff else {
            return EventResponse(status: "ok", eventId: id)
        }
        decisionStartWaiters.forEach { $0.resume() }
        decisionStartWaiters.removeAll()
        if !decisionReleased {
            await withCheckedContinuation { decisionRelease = $0 }
        }
        return EventResponse(
            status: "ok",
            eventId: id,
            journeyOwnership: .init(
                journeyId: "deadlock-journey",
                accepted: true,
                epoch: 1
            )
        )
    }
}

private actor DecisionOwnershipCallbackRecorder {
    private(set) var journeyIds: [String] = []
    private(set) var sourceWasAcknowledgedAtCallback: [Bool] = []

    func record(journeyId: String, sourceWasAcknowledged: Bool) {
        journeyIds.append(journeyId)
        sourceWasAcknowledgedAtCallback.append(sourceWasAcknowledged)
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
