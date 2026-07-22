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

            it("keeps the pending queue intact across a manual flush while offline, then delivers it when the transport returns") {
                // Delivery-guarantee contract (docs/sdk-api-surface.md): a
                // failed batch is never acked for retry-exhaustion reasons.
                // An offline manual flush makes ONE attempt, leaves every row
                // pending, and reports failure; the same rows deliver on a
                // later flush — or on the next launch. The production
                // lifecycle calls flush on background/foreground, so an
                // offline background transition must not touch the durable
                // queue.
                await api.setShouldFailBatch(true)
                await api.configureTrackEventFailure()

                stack.eventLog.track(
                    "offline_trigger", properties: nil, userProperties: nil,
                    userPropertiesSetOnce: nil
                )
                await stack.eventLog.drain()
                let queuedBefore = await stack.eventLog.getQueuedEventCount()
                expect(queuedBefore).to(beGreaterThan(0))

                // One manual flush while offline: exactly one transport
                // attempt, nothing dropped, nothing acked.
                let attemptsBefore = await api.sendBatchCallCount
                let offlineFlush = await stack.eventLog.flushEvents()
                expect(offlineFlush).to(beFalse())
                await expect { await api.sendBatchCallCount }.to(equal(attemptsBefore + 1))
                await expect { await stack.eventLog.getQueuedEventCount() }
                    .to(equal(queuedBefore))

                // A second offline flush burns nothing either — still one
                // attempt per cycle, queue intact.
                _ = await stack.eventLog.flushEvents()
                await expect { await api.sendBatchCallCount }.to(equal(attemptsBefore + 2))
                await expect { await stack.eventLog.getQueuedEventCount() }
                    .to(equal(queuedBefore))

                // Transport returns: the SAME rows deliver and get acked.
                await api.setShouldFailBatch(false)
                let flushed = await stack.eventLog.flushEvents()
                expect(flushed).to(beTrue())
                await expect { await api.sentEvents.map(\.name) }.toEventually(
                    contain("offline_trigger"), timeout: .seconds(5)
                )
                await expect { await stack.eventLog.getQueuedEventCount() }
                    .toEventually(equal(0), timeout: .seconds(5))

                // Ack durability: a relaunch rehydrates nothing and a flush
                // re-sends nothing.
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

            it("runs the synchronous trigger path local-first: offline, it enrolls from cached config and queues the event durably") {
                // Delivery-guarantee contract (docs/sdk-api-surface.md): with
                // the transport down, `trigger()` degrades to local
                // evaluation — the event persists pending BEFORE the round
                // trip, journey routing runs from the local event and cached
                // config (no gate plan), no `.error` surfaces, and the
                // trigger event rides the durable queue to deliver later.
                await api.configureTrackEventFailure()
                await api.setShouldFailBatch(true)

                let box = await stack.trigger("offline_trigger")

                expect(box.errors).to(beEmpty())
                expect(box.startedCampaignIds).to(equal(["camp-offline"]))

                // The journey enrolled and ran to completion from cached
                // config — zero network.
                await expect { await stack.eventCount("$journey_start") }
                    .toEventually(equal(1), timeout: .seconds(5))
                await expect { await stack.eventCount("offline_effect") }
                    .toEventually(equal(1), timeout: .seconds(5))
                await expect { await stack.eventCount("$journey_completed") }
                    .toEventually(equal(1), timeout: .seconds(5))
                await expect { await stack.journeys.getActiveJourneys(for: user).count }
                    .toEventually(equal(0), timeout: .seconds(5))

                // In local history AND pending delivery: the trigger event
                // plus everything the journey emitted is queued durably.
                await expect { await stack.eventCount("offline_trigger") }
                    .toEventually(equal(1), timeout: .seconds(5))
                await expect { await stack.eventLog.getQueuedEventCount() }
                    .toEventually(beGreaterThanOrEqualTo(4), timeout: .seconds(5))

                // Transport returns: the trigger event delivers over the
                // batch path (idempotency-keyed by its event id) and acks.
                await api.setShouldFailBatch(false)
                let flushed = await stack.eventLog.flushEvents()
                expect(flushed).to(beTrue())
                await expect { await api.sentEvents.map(\.name) }.toEventually(
                    contain("offline_trigger", "$journey_start", "offline_effect", "$journey_completed"),
                    timeout: .seconds(5)
                )
                await expect { await stack.eventLog.getQueuedEventCount() }
                    .toEventually(equal(0), timeout: .seconds(5))
            }
        }
    }
}
