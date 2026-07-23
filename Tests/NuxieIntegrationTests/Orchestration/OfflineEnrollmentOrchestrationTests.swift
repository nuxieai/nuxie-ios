import Foundation
import Nimble
import Quick

@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

/// E1 orchestration coverage for an unavailable synchronous decision lane.
///
/// The trigger event remains durable, but a journey is not admitted until its
/// `$journey_enrolled` fact has been accepted synchronously.
final class OfflineEnrollmentOrchestrationTests: AsyncSpec {
    override class func spec() {
        describe("offline E1 enrollment (orchestration)") {
            let user = "orchestration-user"
            var storageURL: URL!
            var api: MockNuxieApi!
            var sleepProvider: MockSleepProvider!
            var stack: OrchestrationStack!

            beforeEach {
                storageURL = URL(
                    fileURLWithPath: NSTemporaryDirectory(), isDirectory: true
                ).appendingPathComponent("nuxie-orch-offline-\(UUID().uuidString)", isDirectory: true)
                api = MockNuxieApi()
                sleepProvider = MockSleepProvider()

                stack = try await OrchestrationStack.boot(
                    storageURL: storageURL,
                    api: api,
                    dateProvider: MockDateProvider(),
                    sleepProvider: sleepProvider,
                    distinctId: user
                )
                try await stack.installProfile(
                    campaigns: [
                        OrchestrationFixtures.campaign(
                            id: "camp-offline",
                            flowId: "flow-offline",
                            eventName: "offline_trigger",
                            reentry: .everyTime
                        )
                    ],
                    flows: [
                        try OrchestrationFixtures.exitFlow(
                            id: "flow-offline",
                            trigger: "offline_trigger",
                            effect: "offline_effect"
                        )
                    ]
                )
            }

            afterEach {
                await stack?.shutdownForCleanup()
                stack = nil
                sleepProvider?.reset()
                if let storageURL {
                    try? FileManager.default.removeItem(at: storageURL)
                }
            }

            it("keeps the trigger durable without admitting a journey when enrollment persistence fails") {
                await api.setShouldFailBatch(true)
                await api.configureTrackEventFailure()

                await stack.trackAndDrain("offline_trigger")

                await expect { await stack.eventCount("offline_trigger") }
                    .toEventually(equal(1), timeout: .seconds(5))
                // The attempted fact remains in local history for diagnosis,
                // but the failed decision does not create a local run.
                await expect { await stack.eventCount("$journey_enrolled") }
                    .toEventually(equal(1), timeout: .seconds(5))
                await expect { await stack.eventCount("offline_effect") }
                    .toEventually(equal(0), timeout: .seconds(5))
                await expect { await stack.journeys.getActiveJourneys(for: user) }
                    .toEventually(beEmpty(), timeout: .seconds(5))
                let queued = await stack.eventLog.getQueuedEventCount()
                expect(queued).to(beGreaterThan(0))
            }

            it("keeps a failed manual-flush batch pending and delivers it after recovery") {
                await api.setShouldFailBatch(true)
                stack.eventLog.track(
                    "durable_offline_event",
                    properties: nil,
                    userProperties: nil,
                    userPropertiesSetOnce: nil
                )
                await stack.eventLog.drain()

                let queuedBefore = await stack.eventLog.getQueuedEventCount()
                let attemptsBefore = await api.sendBatchCallCount
                let offlineFlush = await stack.eventLog.flushEvents()
                let attemptsAfterOfflineFlush = await api.sendBatchCallCount
                let queuedAfterOfflineFlush = await stack.eventLog.getQueuedEventCount()
                expect(offlineFlush).to(beFalse())
                expect(attemptsAfterOfflineFlush).to(equal(attemptsBefore + 1))
                expect(queuedAfterOfflineFlush).to(equal(queuedBefore))

                await api.setShouldFailBatch(false)
                let recoveredFlush = await stack.eventLog.flushEvents()
                expect(recoveredFlush).to(beTrue())
                await expect { await api.sentEvents.map(\.name) }
                    .toEventually(contain("durable_offline_event"), timeout: .seconds(5))
                await expect { await stack.eventLog.getQueuedEventCount() }
                    .toEventually(equal(0), timeout: .seconds(5))
            }
        }
    }
}
