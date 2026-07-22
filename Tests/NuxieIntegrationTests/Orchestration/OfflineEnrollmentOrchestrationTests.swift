import Foundation
import Quick
import Nimble
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

/// P6 orchestration: offline enrollment + later ack.
///
/// Real stack (see OrchestrationHarness). With the transport failing every
/// request, an event tracked through the durable pipeline must still enroll
/// and run a journey from cached config; the `$journey_*` events persist
/// pending in the real SQLite store; when the transport returns and a flush
/// happens they deliver, get acked (delivery_state = delivered), and never
/// redeliver — including across a relaunch.
final class OfflineEnrollmentOrchestrationTests: AsyncSpec {
    override class func spec() {
        describe("offline journey enrollment (orchestration)") {
            let user = "orchestration-user"
            var storageURL: URL!
            var api: MockNuxieApi!
            var dateProvider: MockDateProvider!
            var sleepProvider: MockSleepProvider!
            var stack: OrchestrationStack!

            beforeEach {
                storageURL = URL(
                    fileURLWithPath: NSTemporaryDirectory(), isDirectory: true
                ).appendingPathComponent("nuxie-orch-offline-\(UUID().uuidString)", isDirectory: true)
                api = MockNuxieApi()
                dateProvider = MockDateProvider()
                sleepProvider = MockSleepProvider()

                stack = try await OrchestrationStack.boot(
                    storageURL: storageURL,
                    api: api,
                    dateProvider: dateProvider,
                    sleepProvider: sleepProvider,
                    distinctId: user
                )

                // Config was cached while "online": one successful profile
                // fetch, exactly like a normal earlier launch.
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

            it("enrolls and completes a journey from cached config while fully offline, then delivers and acks the pending events when the transport returns") {
                // Airplane mode: every transport request fails.
                await api.setShouldFailBatch(true)
                await api.setShouldFailProfile(true)
                await api.configureTrackEventFailure()
                let batchAttemptsBefore = await api.sendBatchCallCount

                stack.eventLog.track(
                    "offline_trigger",
                    properties: ["source": "orchestration"],
                    userProperties: nil,
                    userPropertiesSetOnce: nil
                )
                await stack.eventLog.drain()

                // The journey enrolled from cached config and ran its entry
                // actions to completion — zero network.
                await expect { await stack.eventCount("$journey_start") }
                    .toEventually(equal(1), timeout: .seconds(5))
                await expect { await stack.eventCount("offline_effect") }
                    .toEventually(equal(1), timeout: .seconds(5))
                await expect { await stack.eventCount("$journey_completed") }
                    .toEventually(equal(1), timeout: .seconds(5))
                await expect { await stack.journeys.getActiveJourneys(for: user).count }
                    .toEventually(equal(0), timeout: .seconds(5))

                // Everything persisted pending in SQLite; nothing was even
                // attempted over the wire (delivery is manual-flush here).
                let queued = await stack.eventLog.getQueuedEventCount()
                expect(queued).to(beGreaterThanOrEqualTo(4))  // trigger + $journey_* set
                await expect { await api.sendBatchCallCount }.to(equal(batchAttemptsBefore))

                // Transport returns: flush delivers the whole pending set and
                // the store acks it.
                await api.setShouldFailBatch(false)
                let flushed = await stack.eventLog.flushEvents()
                expect(flushed).to(beTrue())
                await expect { await api.sentEvents.map(\.name) }.toEventually(
                    contain("offline_trigger", "$journey_start", "offline_effect", "$journey_completed"),
                    timeout: .seconds(5)
                )
                await expect { await stack.eventLog.getQueuedEventCount() }
                    .toEventually(equal(0), timeout: .seconds(5))

                // Ack durability: relaunch over the same storage; the
                // delivered rows must not rehydrate into the queue or
                // redeliver on the next flush.
                let deliveredCount = await api.sentEvents.count
                await stack.kill()
                stack = try await OrchestrationStack.boot(
                    storageURL: storageURL,
                    api: api,
                    dateProvider: dateProvider,
                    sleepProvider: sleepProvider,
                    distinctId: user
                )
                await expect { await stack.eventLog.getQueuedEventCount() }
                    .toEventually(equal(0), timeout: .seconds(5))
                _ = await stack.eventLog.flushEvents()
                await expect { await api.sentEvents.count }.to(equal(deliveredCount))
            }

            it("documents current behavior: a manual flush while offline permanently drops and false-acks the pending queue") {
                // Pin of current behavior, not an endorsement. `flushEvents`
                // drains via deliveryFlushAll, which loops performFlush with
                // forceSend (ignoring retry backoff); every loop iteration
                // burns one retry, so a single offline flush call exhausts
                // maxRetries immediately, DROPS the whole batch, and marks
                // the rows delivered in SQLite ("deliberate drop") — they
                // never redeliver, not even after relaunch. The production
                // lifecycle calls flush on background/foreground, so an
                // offline background transition destroys the durable queue.
                await api.setShouldFailBatch(true)
                await api.configureTrackEventFailure()

                stack.eventLog.track(
                    "offline_trigger", properties: nil, userProperties: nil,
                    userPropertiesSetOnce: nil
                )
                await stack.eventLog.drain()
                await expect { await stack.eventLog.getQueuedEventCount() }
                    .toEventually(beGreaterThan(0), timeout: .seconds(5))

                // One manual flush while offline: retryCount(1) + 1 failed
                // attempts, then the queue is dropped and false-acked.
                _ = await stack.eventLog.flushEvents()
                await expect { await stack.eventLog.getQueuedEventCount() }
                    .toEventually(equal(0), timeout: .seconds(5))

                // Transport returns — there is nothing left to deliver.
                await api.setShouldFailBatch(false)
                let attemptsAfterDrop = await api.sendBatchCallCount
                let flushed = await stack.eventLog.flushEvents()
                expect(flushed).to(beFalse())
                await expect { await api.sendBatchCallCount }.to(equal(attemptsAfterDrop))

                // Not even a relaunch resurrects them: the rows were marked
                // delivered, so configure() rehydrates nothing.
                await stack.kill()
                stack = try await OrchestrationStack.boot(
                    storageURL: storageURL,
                    api: api,
                    dateProvider: dateProvider,
                    sleepProvider: sleepProvider,
                    distinctId: user
                )
                await expect { await stack.eventLog.getQueuedEventCount() }
                    .toEventually(equal(0), timeout: .seconds(5))
                _ = await stack.eventLog.flushEvents()
                await expect { await api.sendBatchCallCount }.to(equal(attemptsAfterDrop))
            }

            it("documents that the synchronous trigger path is NOT local-first: offline, it reports an error and enrolls nothing") {
                // Pin of current behavior, not an endorsement: TriggerService
                // routes journeys only after the /i/event round trip, so with
                // the transport down `trigger()` surfaces `.error` and never
                // reaches journey routing. (The durable `track` path above IS
                // local-first.) The event is still written to local history —
                // as an already-"delivered" history row, so it is never
                // queued for later delivery either.
                await api.configureTrackEventFailure()
                await api.setShouldFailBatch(true)

                let queuedBefore = await stack.eventLog.getQueuedEventCount()
                let box = await stack.trigger("offline_trigger")

                expect(box.errors).toNot(beEmpty())
                expect(box.startedCampaignIds).to(beEmpty())

                await expect { await stack.eventCount("$journey_start") }.to(equal(0))
                await expect { await stack.journeys.getActiveJourneys(for: user).count }
                    .to(equal(0))

                // In local history, but not pending delivery.
                await expect { await stack.eventCount("offline_trigger") }
                    .toEventually(equal(1), timeout: .seconds(5))
                await expect { await stack.eventLog.getQueuedEventCount() }
                    .to(equal(queuedBefore))
            }
        }
    }
}
