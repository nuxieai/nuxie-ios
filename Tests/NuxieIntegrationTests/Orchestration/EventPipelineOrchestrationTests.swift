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

            beforeEach {
                // Isolated on-disk store per test
                storagePath = NSTemporaryDirectory() + "nuxie-orchestration-\(UUID().uuidString)"

                config = NuxieConfiguration(apiKey: "orchestration-test-key")
                config.customStoragePath = URL(fileURLWithPath: storagePath)
                config.flushAt = 100  // manual flush only
                config.flushInterval = 3600
                config.retryCount = 1
                config.retryDelay = 0.01
                Container.shared.sdkConfiguration.register { config }
                Container.shared.identityService.register { MockIdentityService() }

                api = MockNuxieApi()
                Container.shared.nuxieApi.register { api }

                eventLog = EventLog(
                    identity: Container.shared.identityService(),
                    sessions: Container.shared.sessionService(),
                    dateProvider: Container.shared.dateProvider(),
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
                    identity: Container.shared.identityService(),
                    sessions: Container.shared.sessionService(),
                    dateProvider: Container.shared.dateProvider(),
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
        }
    }
}
