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
                                name: JourneyEvents.journeyStarted,
                                properties: nil,
                                eventId: "stable-after-ordinary",
                                distinctId: "customer-a"
                            )
                        )
                    }
                    for _ in 0..<10 { await Task.yield() }

                    expect(mockStore.stableCaptureCommitCallCount).to(equal(0))
                    expect(mockStore.storedEvents.map(\.name))
                        .toNot(contain(JourneyEvents.journeyStarted))

                    mockStore.resumeInsert(id: ordinaryID)
                    guard await stableTask.value != nil else {
                        return fail("Expected stable capture")
                    }
                    await log.drain()

                    expect(mockStore.storedEvents.map(\.name)).to(equal([
                        "ordinary-before-stable",
                        JourneyEvents.journeyStarted,
                    ]))
                    await expect { await received.names }.to(equal([
                        "ordinary-before-stable",
                        JourneyEvents.journeyStarted,
                    ]))
                }

                it("allows a committed subscriber to durably capture another routed event") {
                    let received = ReceivedEvents()
                    await log.subscribeCommitted { event in
                        await received.append(event.name)
                        guard event.name == "outer" else { return }
                        let committed = await log.captureAndRouteSystemEvent(
                            .init(
                                name: "nested",
                                properties: nil,
                                eventId: "nested-from-committed-subscriber",
                                distinctId: event.distinctId
                            )
                        )
                        // A nested capture cannot drain the route worker that
                        // is currently invoking this subscriber. Its owner
                        // must retain retry evidence until a later attempt can
                        // observe the completed durable route receipt.
                        expect(committed).toNot(beNil())
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
                    await expect { mockStore.pendingStableRouteIds }
                        .toEventually(beEmpty())
                }

                it("replays a stable local route left pending by a prior process") {
                    let received = ReceivedEvents()
                    await log.subscribeCommitted { event in
                        await received.append(event.name)
                    }
                    try await log.configure(configuration: testConfig)
                    let stored = try StoredEvent(
                        id: "stable-route-from-prior-process",
                        name: "recovered-local-route",
                        properties: ["source": "recovery"],
                        timestamp: Date(timeIntervalSince1970: 1_000),
                        distinctId: "customer-a"
                    )
                    let committed = try await mockStore
                        .commitStableCaptureAndStageRoute(
                            eventId: stored.id,
                            event: stored,
                            recordedAt: stored.timestamp,
                            assigningCommitSequence: false,
                            admission: nil
                        )
                    expect(committed.localRoutePending).to(beTrue())

                    let replayed = await log.replayPendingStableRoutes(
                        distinctId: "customer-a"
                    )
                    let replayedAgain = await log.replayPendingStableRoutes(
                        distinctId: "customer-a"
                    )

                    expect(replayed).to(beTrue())
                    expect(replayedAgain).to(beTrue())
                    await expect { await received.names }.to(equal([
                        "recovered-local-route",
                    ]))
                    expect(mockStore.pendingStableRouteIds).to(beEmpty())
                }

                it("retries a failed stable-route acknowledgement without rerouting") {
                    let received = ReceivedEvents()
                    await log.subscribeCommitted { event in
                        await received.append(event.name)
                    }
                    try await log.configure(configuration: testConfig)
                    mockStore.shouldFailMarkDelivered = true
                    let request = StableSystemEventCaptureRequest(
                        name: "route-with-transient-ack-failure",
                        properties: nil,
                        eventId: "stable-route-ack-retry",
                        distinctId: "customer-a"
                    )

                    let first = await log.captureAndRouteSystemEvent(request)
                    let firstDrain = await log.drainCommittedRouting()
                    let duplicate = await log.captureAndRouteSystemEvent(request)
                    let duplicateDrain = await log.drainCommittedRouting()

                    expect(first?.isNewlyCommitted).to(beTrue())
                    expect(first?.localRoutePending).to(beTrue())
                    expect(firstDrain).to(beFalse())
                    expect(duplicate?.isNewlyCommitted).to(beFalse())
                    expect(duplicate?.localRoutePending).to(beTrue())
                    expect(duplicateDrain).to(beFalse())
                    await expect { await received.names }.to(equal([
                        "route-with-transient-ack-failure",
                    ]))
                    expect(mockStore.pendingStableRouteIds).to(equal([
                        request.eventId,
                    ]))

                    mockStore.shouldFailMarkDelivered = false
                    let recovered = await log.drainCommittedRouting()

                    expect(recovered).to(beTrue())
                    expect(mockStore.pendingStableRouteIds).to(beEmpty())
                    await expect { await received.names }.to(equal([
                        "route-with-transient-ack-failure",
                    ]))
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
                                name: JourneyEvents.journeyStarted,
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
                        JourneyEvents.journeyStarted,
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
                    let executionFence = JourneyProfileFence()
                    let generation = executionFence.advance()
                    guard let executionToken = executionFence.token(
                        ifCurrent: generation
                    ) else {
                        return fail("Expected current execution fence")
                    }
                    let admission = JourneyCommitAdmission(
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
                    let result = (try? await IRInterpreter(
                        ctx: .init(
                            now: evaluationTime,
                            events: IREventQueriesAdapter(eventLog: relaunchedLog)
                        )
                    ).evalBool(.not(boundedCountIsZero))) ?? false

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
                        let result = (try? await IRInterpreter(
                            ctx: .init(now: now, events: queries)
                        ).evalBool(expression)) ?? false
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
                        // The interpreter preserves unknown; callers fail closed.
                    }

                    let runtimeResult = (try? await IRInterpreter(
                        ctx: .init(
                            now: Date(timeIntervalSince1970: 20_000),
                            events: IREventQueriesAdapter(eventLog: log)
                        )
                    ).evalBool(.not(lifetimeCountIsBelowExactTotal))) ?? false
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
                    let result = (try? await IRInterpreter(
                        ctx: .init(
                            now: now,
                            events: IREventQueriesAdapter(eventLog: log)
                        )
                    ).evalBool(.not(predicateUsesLifetimeAggregate))) ?? false

                    expect(result).to(beFalse())
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
