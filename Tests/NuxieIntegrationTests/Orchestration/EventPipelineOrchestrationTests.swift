import Foundation
import Quick
import Nimble
import FactoryKit
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

/// Orchestration harness (cleanup plan, Phase 1).
///
/// Unlike the unit suites — which mock EventService itself and therefore can
/// never observe delivery loss — these tests run the REAL event pipeline:
/// real `EventService`, real SQLite-backed store over a temp directory, real
/// `NuxieNetworkQueue`. Only the HTTP transport (`MockNuxieApi`) is mocked.
///
/// Phase 4 (EventLog rebuild) extends this harness with relaunch-persistence
/// and offline-delivery coverage; the assertions here pin the end-to-end
/// capture → enrich → persist → batch-upload loop that must keep working
/// through that rebuild.
final class EventPipelineOrchestrationTests: AsyncSpec {
    override class func spec() {
        describe("event pipeline orchestration") {
            var eventService: EventService!
            var networkQueue: NuxieNetworkQueue!
            var api: MockNuxieApi!
            var storagePath: String!

            beforeEach {
                // Isolated on-disk store per test
                storagePath = NSTemporaryDirectory() + "nuxie-orchestration-\(UUID().uuidString)"

                let config = NuxieConfiguration(apiKey: "orchestration-test-key")
                config.customStoragePath = URL(fileURLWithPath: storagePath)
                Container.shared.sdkConfiguration.register { config }
                Container.shared.identityService.register { MockIdentityService() }

                api = MockNuxieApi()
                networkQueue = NuxieNetworkQueue(
                    flushAt: 100,  // manual flush only
                    flushIntervalSeconds: 3600,
                    maxQueueSize: 1000,
                    maxBatchSize: 50,
                    maxRetries: 1,
                    baseRetryDelay: 0.01,
                    apiClient: api
                )

                let identityService = Container.shared.identityService()
                let contextBuilder = NuxieContextBuilder(
                    identityService: identityService,
                    configuration: config
                )

                eventService = EventService()
                try await eventService.configure(
                    networkQueue: networkQueue,
                    journeyService: nil,
                    contextBuilder: contextBuilder,
                    configuration: config
                )
            }

            afterEach {
                await eventService.close()
                await networkQueue.shutdown()
                if let path = storagePath {
                    try? FileManager.default.removeItem(atPath: path)
                }
            }

            it("persists a tracked event locally and delivers it in a batch") {
                eventService.track(
                    "orchestrated_event",
                    properties: ["source": "harness"],
                    userProperties: nil,
                    userPropertiesSetOnce: nil
                )
                await eventService.drain()

                // Locally persisted (journey/segment evaluation reads this)
                let stored = await eventService.getRecentEvents(limit: 10)
                expect(stored.map(\.name)).to(contain("orchestrated_event"))

                // Delivered over the wire on flush
                let flushed = await eventService.flushEvents()
                expect(flushed).to(beTrue())
                await expect { await api.sentEvents.map(\.name) }
                    .to(contain("orchestrated_event"))
            }

            it("delivers events persisted in a previous session after relaunch") {
                // "Session 1": track an event, let it persist, but never flush —
                // then close (simulating app kill before delivery).
                eventService.track(
                    "undelivered_event",
                    properties: nil,
                    userProperties: nil,
                    userPropertiesSetOnce: nil
                )
                await eventService.drain()
                await eventService.close()
                await networkQueue.shutdown()
                await expect { await api.sentEvents.map(\.name) }
                    .toNot(contain("undelivered_event"))

                // "Session 2": fresh service + queue over the SAME storage path.
                let config = NuxieConfiguration(apiKey: "orchestration-test-key")
                config.customStoragePath = URL(fileURLWithPath: storagePath)
                let relaunchQueue = NuxieNetworkQueue(
                    flushAt: 100,
                    flushIntervalSeconds: 3600,
                    maxQueueSize: 1000,
                    maxBatchSize: 50,
                    maxRetries: 1,
                    baseRetryDelay: 0.01,
                    apiClient: api
                )
                let relaunchService = EventService()
                try await relaunchService.configure(
                    networkQueue: relaunchQueue,
                    journeyService: nil,
                    contextBuilder: nil,
                    configuration: config
                )

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
                await relaunchQueue.shutdown()
            }

            it("retains local history when batch delivery fails") {
                await api.setShouldFailBatch(true)

                eventService.track(
                    "offline_event",
                    properties: nil,
                    userProperties: nil,
                    userPropertiesSetOnce: nil
                )
                await eventService.drain()

                _ = await eventService.flushEvents()

                // Local history must survive delivery failure — evaluation
                // correctness cannot depend on the network.
                let stored = await eventService.getRecentEvents(limit: 10)
                expect(stored.map(\.name)).to(contain("offline_event"))
            }
        }
    }
}
