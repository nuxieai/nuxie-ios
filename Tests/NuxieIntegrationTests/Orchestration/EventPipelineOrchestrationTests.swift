import Foundation
import Quick
import Nimble
@_spi(Testing) @testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

private actor OrchestrationForwardingRecorder {
    private var events: [DurableForwardingEvent] = []

    func record(_ event: DurableForwardingEvent) {
        events.append(event)
    }

    func snapshot() -> [String] { events.map(\.event.forwardingName) }
    func idSnapshot() -> [String] { events.map(\.event.id) }
}

private actor OrchestrationCommittedRecorder {
    private var events: [NuxieEvent] = []

    func record(_ event: NuxieEvent) {
        events.append(event)
    }

    func names() -> [String] { events.map(\.name) }
}

/// Orchestration harness (cleanup plan, Phase 1).
///
/// Unlike the unit suites — which mock EventLog itself and therefore can
/// never observe delivery loss — these tests run the REAL event pipeline:
/// real `EventLog` (capture, SQLite persistence, folded delivery queue) over
/// a temp directory. Only the HTTP transport (`MockNuxieApi`) is mocked.
///
/// Phase 4 (EventLog rebuild) extends this harness with relaunch-persistence
/// and offline-delivery coverage; the assertions here pin the end-to-end
/// capture → enrich → persist → batch-upload loop that must keep working
/// through that rebuild.
final class EventPipelineOrchestrationTests: AsyncSpec {
    override class func spec() {
        describe("event pipeline orchestration") {
            var eventLog: EventLog!
            var api: MockNuxieApi!
            var storagePath: String!
            var config: NuxieConfiguration!
            var identity: MockIdentityService!
            var dateProvider: SystemDateProvider!

            beforeEach {
                // Isolated on-disk store per test
                storagePath = NSTemporaryDirectory() + "nuxie-orchestration-\(UUID().uuidString)"

                config = NuxieConfiguration(apiKey: "orchestration-test-key")
                config.testingOverrides.customStoragePath = URL(fileURLWithPath: storagePath)
                config.testingOverrides.flushAt = 100  // manual flush only
                config.testingOverrides.flushInterval = 3600
                config.testingOverrides.retryCount = 1
                config.testingOverrides.retryDelay = 0.01
                identity = MockIdentityService()
                dateProvider = SystemDateProvider()

                api = MockNuxieApi()

                eventLog = EventLog(
                    identity: identity,
                    dateProvider: dateProvider,
                    apiClient: api
                )
                try await eventLog.configure(configuration: config)
            }

            afterEach {
                await eventLog.close()
                if let path = storagePath {
                    try? FileManager.default.removeItem(atPath: path)
                }
            }

            it("persists a tracked event locally and delivers it in a batch") {
                eventLog.track(
                    "orchestrated_event",
                    properties: ["source": "harness"],
                    userProperties: nil,
                    userPropertiesSetOnce: nil
                )
                await eventLog.drain()

                // Locally persisted (journey/segment evaluation reads this)
                let stored = await eventLog.getRecentEvents(limit: 10)
                expect(stored.map(\.name)).to(contain("orchestrated_event"))

                // Delivered over the wire on flush
                let flushed = await eventLog.flushEvents()
                expect(flushed).to(beTrue())
                await expect { await api.sentEvents.map(\.name) }
                    .to(contain("orchestrated_event"))
            }

            it("delivers events persisted in a previous session after relaunch") {
                // "Session 1": track an event, let it persist, but never flush —
                // then close (simulating app kill before delivery).
                eventLog.track(
                    "undelivered_event",
                    properties: nil,
                    userProperties: nil,
                    userPropertiesSetOnce: nil
                )
                await eventLog.drain()
                await eventLog.close()
                await expect { await api.sentEvents.map(\.name) }
                    .toNot(contain("undelivered_event"))

                // "Session 2": fresh log over the SAME storage path.
                let relaunchService = EventLog(
                    identity: identity,
                    dateProvider: dateProvider,
                    apiClient: api
                )
                try await relaunchService.configure(configuration: config)

                // Rehydrated pending events must deliver on flush.
                _ = await relaunchService.flushEvents()
                await expect { await api.sentEvents.map(\.name) }
                    .to(contain("undelivered_event"))

                // And must not deliver twice on a subsequent flush.
                let deliveredCount = await api.sentEvents.filter { $0.name == "undelivered_event" }.count
                _ = await relaunchService.flushEvents()
                await expect { await api.sentEvents.filter { $0.name == "undelivered_event" }.count }
                    .to(equal(deliveredCount))

                await relaunchService.close()
            }

            it("retains local history when batch delivery fails") {
                await api.setShouldFailBatch(true)

                eventLog.track(
                    "offline_event",
                    properties: nil,
                    userProperties: nil,
                    userPropertiesSetOnce: nil
                )
                await eventLog.drain()

                _ = await eventLog.flushEvents()

                // Local history must survive delivery failure — evaluation
                // correctness cannot depend on the network.
                let stored = await eventLog.getRecentEvents(limit: 10)
                expect(stored.map(\.name)).to(contain("offline_event"))
            }

            it("keeps authentication-rejected rows pending across relaunch") {
                eventLog.track(
                    "auth_retained_event",
                    properties: nil,
                    userProperties: nil,
                    userPropertiesSetOnce: nil
                )
                await eventLog.drain()
                await api.setBatchError(
                    NuxieNetworkError.httpError(
                        statusCode: 401,
                        message: "Unauthorized"
                    )
                )

                _ = await eventLog.flushEvents()
                await expect { await eventLog.deliveryHealthState() }
                    .to(equal("unhealthy_authentication"))
                await eventLog.close()

                await api.setBatchError(nil)
                let relaunchService = EventLog(
                    identity: identity,
                    dateProvider: dateProvider,
                    apiClient: api
                )
                eventLog = relaunchService
                try await relaunchService.configure(configuration: config)

                _ = await relaunchService.flushEvents()
                await expect {
                    await api.sentEvents.filter {
                        $0.name == "auth_retained_event"
                    }.count
                }.to(equal(2))

                _ = await relaunchService.flushEvents()
                await expect {
                    await api.sentEvents.filter {
                        $0.name == "auth_retained_event"
                    }.count
                }.to(equal(2))
            }

            it("retries a failed response-bearing event after relaunch with its stored identity") {
                let forwarding = OrchestrationForwardingRecorder()
                await eventLog.subscribeForwarding { event in
                    await forwarding.record(event)
                }
                await api.configureTrackEventFailure(
                    error: NuxieNetworkError.httpError(
                        statusCode: 500,
                        message: "offline"
                    )
                )

                await expect {
                    try await eventLog.trackWithResponse(
                        JourneyEvents.journeyTransition,
                        properties: ["journey_id": "journey-durable-identity"],
                        flushStrategy: .none
                    )
                }.to(throwError())

                let recentEvents = await eventLog.getRecentEvents(limit: 10)
                let stored = try unwrap(recentEvents.first {
                    $0.name == JourneyEvents.journeyTransition
                })
                let sentEvents = await api.sentEvents
                let firstWireId = try unwrap(sentEvents.last?.id)
                expect(firstWireId).to(equal(stored.id))
                await eventLog.close()

                await api.reset()
                let relaunched = EventLog(
                    identity: identity,
                    dateProvider: dateProvider,
                    apiClient: api
                )
                eventLog = relaunched
                await relaunched.subscribeForwarding { event in
                    await forwarding.record(event)
                }
                try await relaunched.configure(configuration: config)

                let didFlush = await relaunched.flushEvents()
                expect(didFlush).to(beTrue())
                let retriedEvents = await api.sentEvents
                let retried = try unwrap(retriedEvents.last)
                expect(retried.id).to(equal(stored.id))
                expect(retried.timestamp).to(equal(stored.timestamp))
                let queuedEventCount = await relaunched.getQueuedEventCount()
                expect(queuedEventCount).to(equal(0))
                let forwardedIds = await forwarding.idSnapshot()
                expect(forwardedIds).to(equal([stored.id]))
            }

            it("forwards a durable capture once and does not replay it after relaunch") {
                let firstRecorder = OrchestrationForwardingRecorder()
                await eventLog.subscribeForwarding { event in
                    await firstRecorder.record(event)
                }
                eventLog.track(
                    SystemEventNames.appOpened,
                    properties: nil,
                    userProperties: nil,
                    userPropertiesSetOnce: nil
                )
                await eventLog.drain()
                await expect { await firstRecorder.snapshot() }
                    .to(equal([SystemEventNames.appOpened]))
                await eventLog.close()

                let replayRecorder = OrchestrationForwardingRecorder()
                let relaunchService = EventLog(
                    identity: identity,
                    dateProvider: dateProvider,
                    apiClient: api
                )
                await relaunchService.subscribeForwarding { event in
                    await replayRecorder.record(event)
                }
                try await relaunchService.configure(configuration: config)
                _ = await relaunchService.flushEvents()
                await relaunchService.drain()
                await expect { await replayRecorder.snapshot() }.to(beEmpty())
                await relaunchService.close()
            }

            it("orders a real stable batch and deduplicates it across relaunch") {
                identity.setDistinctId("customer-a")
                guard let identityFence = identity.performWithCurrentIdentityFence(
                    "customer-a",
                    { _ in () }
                ) else {
                    return fail("Expected current identity fence")
                }
                let executionFence = DeviceLegProfileFence()
                let generation = executionFence.advance()
                guard let executionToken = executionFence.token(ifCurrent: generation) else {
                    return fail("Expected current execution fence")
                }
                let admission = DeviceLegCommitAdmission(
                    identity: identity,
                    identityFenceToken: identityFence.token,
                    executionFence: executionFence,
                    executionFenceToken: executionToken
                )
                let initialRoutes = OrchestrationCommittedRecorder()
                await eventLog.subscribeCommitted { event in
                    await initialRoutes.record(event)
                }
                let batch = [
                    RoutedStableSystemEventBatchItem(
                        name: "renderer-first",
                        properties: [:],
                        eventId: "orchestration-renderer:first",
                        distinctId: "customer-a",
                        occurredAt: Date(timeIntervalSince1970: 1_000)
                    ),
                    RoutedStableSystemEventBatchItem(
                        name: "renderer-second",
                        properties: [:],
                        eventId: "orchestration-renderer:second",
                        distinctId: "customer-a",
                        occurredAt: Date(timeIntervalSince1970: 1_001)
                    ),
                ]

                eventLog.track(
                    "ordinary-before-renderer-batch",
                    properties: nil,
                    userProperties: nil,
                    userPropertiesSetOnce: nil
                )
                let firstCapture = await eventLog.captureAndRouteSystemEventBatch(
                    batch,
                    admission: admission
                )
                expect(firstCapture?["orchestration-renderer:first"]?.isNewlyCommitted)
                    .to(beTrue())
                expect(firstCapture?["orchestration-renderer:second"]?.isNewlyCommitted)
                    .to(beTrue())
                await eventLog.drain()
                await expect { await initialRoutes.names() }.to(equal([
                    "ordinary-before-renderer-batch",
                    "renderer-first",
                    "renderer-second",
                ]))
                await eventLog.close()

                let replayRoutes = OrchestrationCommittedRecorder()
                let relaunched = EventLog(
                    identity: identity,
                    dateProvider: dateProvider,
                    apiClient: api
                )
                eventLog = relaunched
                await relaunched.subscribeCommitted { event in
                    await replayRoutes.record(event)
                }
                try await relaunched.configure(configuration: config)
                let replayCapture = await relaunched.captureAndRouteSystemEventBatch(
                    batch,
                    admission: admission
                )
                expect(replayCapture?["orchestration-renderer:first"]?.isNewlyCommitted)
                    .to(beFalse())
                expect(replayCapture?["orchestration-renderer:second"]?.isNewlyCommitted)
                    .to(beFalse())
                await relaunched.drain()
                await expect { await replayRoutes.names() }.to(beEmpty())

                let stored = await relaunched.getRecentEvents(limit: 20)
                expect(stored.filter {
                    $0.id == "orchestration-renderer:first"
                }.count).to(equal(1))
                expect(stored.filter {
                    $0.id == "orchestration-renderer:second"
                }.count).to(equal(1))
            }
        }
    }
}
