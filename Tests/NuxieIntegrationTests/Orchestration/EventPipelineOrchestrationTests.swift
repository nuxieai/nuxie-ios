import Foundation
import Quick
import Nimble
@_spi(Testing) @testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

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
            var sessions: SessionService!
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
                config.beforeSend = { event in
                    switch event.id {
                    case "integration-server-fact-drop":
                        return nil
                    case "integration-server-fact-rename":
                        return NuxieEvent(
                            id: event.id,
                            name: "host_renamed_server_fact",
                            distinctId: "hijacked-user",
                            properties: ["journey_id": "hijacked-journey"],
                            timestamp: event.timestamp.addingTimeInterval(60)
                        )
                    default:
                        return event
                    }
                }
                identity = MockIdentityService()
                sessions = SessionService()
                dateProvider = SystemDateProvider()

                api = MockNuxieApi()

                eventLog = EventLog(
                    identity: identity,
                    sessions: sessions,
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
                    sessions: sessions,
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

            it("persists and routes canonical server facts across beforeSend gates") {
                let routed = OrchestrationEventRecorder()
                let forwarded = OrchestrationCaptureRecorder()
                await eventLog.subscribeCommitted { event in
                    await routed.append(event)
                }
                await eventLog.subscribeCommitted(when: { true }) { capture in
                    await forwarded.append(capture)
                }

                let droppedForwardingFact = JourneyDownFact(
                    id: "integration-server-fact-drop",
                    event: .converted,
                    timestamp: Date(timeIntervalSince1970: 1_900_001_000),
                    properties: JourneyConvertedProperties(
                        journeyId: "journey-drop",
                        at: Date(timeIntervalSince1970: 1_900_000_990),
                        sourceFactRef: "source-drop"
                    )
                )
                let renamedForwardingFact = JourneyDownFact(
                    id: "integration-server-fact-rename",
                    event: .converted,
                    timestamp: Date(timeIntervalSince1970: 1_900_002_000),
                    properties: JourneyConvertedProperties(
                        journeyId: "journey-rename",
                        at: Date(timeIntervalSince1970: 1_900_001_990),
                        sourceFactRef: "source-rename"
                    )
                )

                await eventLog.commitServerFacts(
                    [droppedForwardingFact, renamedForwardingFact],
                    distinctId: "canonical-user"
                )
                await eventLog.drain()

                let storedById = Dictionary(
                    uniqueKeysWithValues: await eventLog.getRecentEvents(limit: 10)
                        .map { ($0.id, $0) }
                )
                for (id, journeyId) in [
                    (droppedForwardingFact.id, "journey-drop"),
                    (renamedForwardingFact.id, "journey-rename"),
                ] {
                    let stored = storedById[id]
                    expect(stored?.name).to(equal(JourneyEvents.journeyConverted))
                    expect(stored?.distinctId).to(equal("canonical-user"))
                    expect(stored?.getPropertiesDict()["journey_id"] as? String)
                        .to(equal(journeyId))
                }

                let routedById = await routed.valuesById
                expect(routedById[droppedForwardingFact.id]?.name)
                    .to(equal(JourneyEvents.journeyConverted))
                expect(routedById[renamedForwardingFact.id]?.name)
                    .to(equal(JourneyEvents.journeyConverted))

                let forwardedById = await forwarded.valuesById
                expect(forwardedById[droppedForwardingFact.id]).to(beNil())
                expect(forwardedById[renamedForwardingFact.id]?.canonicalName)
                    .to(equal(JourneyEvents.journeyConverted))
                expect(forwardedById[renamedForwardingFact.id]?.event.name)
                    .to(equal(JourneyEvents.journeyConverted))
            }

            it("drains an accepted fire-and-forget capture before shutdown") {
                let routed = OrchestrationEventRecorder()
                await eventLog.subscribeCommitted { event in
                    await routed.append(event)
                }

                eventLog.track(
                    "queued_during_orchestration_close",
                    properties: nil,
                    userProperties: nil,
                    userPropertiesSetOnce: nil
                )
                await eventLog.close()

                let routedNames = await routed.valuesById.values.map(\.name)
                expect(routedNames)
                    .to(contain("queued_during_orchestration_close"))

                let relaunchService = EventLog(
                    identity: identity,
                    sessions: sessions,
                    dateProvider: dateProvider,
                    apiClient: api
                )
                try await relaunchService.configure(configuration: config)
                let stored = await relaunchService.getRecentEvents(limit: 10)
                expect(stored.map(\.name))
                    .to(contain("queued_during_orchestration_close"))
                let queuedCount = await relaunchService.getQueuedEventCount()
                expect(queuedCount).to(equal(1))
                await relaunchService.close()
            }
        }
    }
}

private actor OrchestrationEventRecorder {
    private var events: [NuxieEvent] = []

    func append(_ event: NuxieEvent) {
        events.append(event)
    }

    var valuesById: [String: NuxieEvent] {
        Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) })
    }
}

private actor OrchestrationCaptureRecorder {
    private var captures: [CommittedCapture] = []

    func append(_ capture: CommittedCapture) {
        captures.append(capture)
    }

    var valuesById: [String: CommittedCapture] {
        Dictionary(uniqueKeysWithValues: captures.map { ($0.event.id, $0) })
    }
}
