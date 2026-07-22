import Foundation
import Quick
import Nimble
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

/// P6 orchestration: concurrent dispatch.
///
/// Fires a burst of concurrent triggers (same and different events, through
/// both production dispatch paths — the synchronous trigger pipeline and the
/// durable track pipeline) at a configured stack and asserts:
///   - no duplicate journeys for single-enrollment campaigns
///   - no lost enrollments for distinct campaigns
///   - a consistent final store state (disk view == in-memory view)
/// All waits are bounded polling expectations; no raw sleeps.
final class ConcurrentDispatchOrchestrationTests: AsyncSpec {
    override class func spec() {
        describe("concurrent trigger dispatch (orchestration)") {
            let user = "orchestration-user"
            var storageURL: URL!
            var api: MockNuxieApi!
            var dateProvider: MockDateProvider!
            var sleepProvider: MockSleepProvider!
            var stack: OrchestrationStack!

            beforeEach {
                storageURL = URL(
                    fileURLWithPath: NSTemporaryDirectory(), isDirectory: true
                ).appendingPathComponent("nuxie-orch-concurrent-\(UUID().uuidString)", isDirectory: true)
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

                // Three campaigns; long delay flows keep every journey live
                // through the burst so suppression (not completion timing)
                // decides re-enrollment.
                //   camp-single: one_time, trigger "burst"
                //   camp-multi:  every_time, trigger "burst" (same event)
                //   camp-other:  every_time, trigger "burst_other"
                try await stack.installProfile(
                    campaigns: [
                        OrchestrationFixtures.campaign(
                            id: "camp-single", flowId: "flow-single",
                            eventName: "burst", reentry: .oneTime),
                        OrchestrationFixtures.campaign(
                            id: "camp-multi", flowId: "flow-multi",
                            eventName: "burst", reentry: .everyTime),
                        OrchestrationFixtures.campaign(
                            id: "camp-other", flowId: "flow-other",
                            eventName: "burst_other", reentry: .everyTime),
                    ],
                    flows: [
                        try OrchestrationFixtures.delayFlow(
                            id: "flow-single", trigger: "burst",
                            delayMs: 600_000, effect: "fx_single"),
                        try OrchestrationFixtures.delayFlow(
                            id: "flow-multi", trigger: "burst",
                            delayMs: 600_000, effect: "fx_multi"),
                        try OrchestrationFixtures.delayFlow(
                            id: "flow-other", trigger: "burst_other",
                            delayMs: 600_000, effect: "fx_other"),
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

            it("enrolls exactly one journey per campaign under a concurrent burst and leaves a consistent store") {
                let triggers = stack.core.triggers
                let eventLog = stack.core.eventLog

                // 16 concurrent dispatches: 8 trigger("burst"),
                // 4 trigger("burst_other"), 4 durable track("burst") racing
                // the trigger path through the committed-event router.
                await withTaskGroup(of: Void.self) { group in
                    for index in 0..<8 {
                        group.addTask {
                            await triggers.trigger(
                                "burst",
                                properties: ["i": index],
                                userProperties: nil,
                                userPropertiesSetOnce: nil
                            ) { _ in }
                        }
                    }
                    for index in 0..<4 {
                        group.addTask {
                            await triggers.trigger(
                                "burst_other",
                                properties: ["i": index],
                                userProperties: nil,
                                userPropertiesSetOnce: nil
                            ) { _ in }
                        }
                    }
                    for index in 0..<4 {
                        group.addTask {
                            eventLog.track(
                                "burst",
                                properties: ["track_i": index],
                                userProperties: nil,
                                userPropertiesSetOnce: nil
                            )
                        }
                    }
                }
                await stack.eventLog.drain()

                // No lost enrollments: one live journey per distinct campaign.
                await expect { await stack.journeys.getActiveJourneys(for: user).count }
                    .toEventually(equal(3), timeout: .seconds(10))
                let active = await stack.journeys.getActiveJourneys(for: user)
                expect(Set(active.map(\.campaignId)))
                    .to(equal(Set(["camp-single", "camp-multi", "camp-other"])))

                // No duplicate enrollments: exactly one $journey_start per
                // campaign in the real event store.
                await expect { await stack.journeyStartCount(campaignId: "camp-single") }
                    .toEventually(equal(1), timeout: .seconds(5))
                await expect { await stack.journeyStartCount(campaignId: "camp-multi") }
                    .toEventually(equal(1), timeout: .seconds(5))
                await expect { await stack.journeyStartCount(campaignId: "camp-other") }
                    .toEventually(equal(1), timeout: .seconds(5))
                await expect { await stack.eventCount("$journey_start") }
                    .to(equal(3))

                // Consistent final store state: what is persisted matches
                // what the actor holds in memory, one file per journey.
                let onDisk = stack.journeyStoreOnDisk().loadActiveJourneys()
                expect(onDisk).to(haveCount(3))
                expect(Set(onDisk.map(\.id))).to(equal(Set(active.map(\.id))))
                expect(Set(onDisk.map(\.campaignId)))
                    .to(equal(Set(active.map(\.campaignId))))

                // Stability: a second, smaller concurrent burst while all
                // journeys are still live must be fully suppressed
                // (alreadyActive) — no new enrollments, no duplicates.
                await withTaskGroup(of: Void.self) { group in
                    for index in 0..<4 {
                        group.addTask {
                            await triggers.trigger(
                                "burst",
                                properties: ["second_wave": index],
                                userProperties: nil,
                                userPropertiesSetOnce: nil
                            ) { _ in }
                        }
                    }
                    for index in 0..<2 {
                        group.addTask {
                            await triggers.trigger(
                                "burst_other",
                                properties: ["second_wave": index],
                                userProperties: nil,
                                userPropertiesSetOnce: nil
                            ) { _ in }
                        }
                    }
                }
                await stack.eventLog.drain()

                await expect { await stack.journeys.getActiveJourneys(for: user).count }
                    .toEventually(equal(3), timeout: .seconds(5))
                await expect { await stack.eventCount("$journey_start") }.to(equal(3))
                expect(stack.journeyStoreOnDisk().loadActiveJourneys()).to(haveCount(3))
            }

            it("reports duplicate concurrent triggers as suppressed (alreadyActive), not as errors or extra journeys") {
                // Deterministic two-shot version of the burst: the first
                // trigger enrolls, the concurrent duplicate for the same
                // campaigns is suppressed with a taxonomized reason.
                let first = await stack.trigger("burst")
                expect(Set(first.startedCampaignIds))
                    .to(equal(Set(["camp-single", "camp-multi"])))

                let second = await stack.trigger("burst")
                expect(second.startedCampaignIds).to(beEmpty())
                expect(second.errors).to(beEmpty())
                expect(second.suppressReasons).to(contain(.alreadyActive))

                await expect { await stack.eventCount("$journey_start") }
                    .toEventually(equal(2), timeout: .seconds(5))
            }
        }
    }
}
