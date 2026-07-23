import Foundation
import Quick
import Nimble
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

/// P6 orchestration: reentry policies across completion, cancellation and
/// error.
///
/// For every reentry variant in the schema (`every_time`, `one_time`,
/// `once_per_window`) the suite ends a journey three ways — genuine
/// completion, cancellation (logout-style user switch) and error (flow failed
/// to load) — and pins the re-trigger behavior through the production trigger
/// path. Current semantics under test: only genuine completions burn
/// one-time/windowed reentry; cancelled and errored journeys never do.
final class ReentryPolicyOrchestrationTests: AsyncSpec {
    override class func spec() {
        describe("reentry policies across journey end reasons (orchestration)") {
            let user = "orchestration-user"
            var storageURL: URL!
            var api: MockNuxieApi!
            var dateProvider: MockDateProvider!
            var sleepProvider: MockSleepProvider!
            var stack: OrchestrationStack!

            beforeEach {
                storageURL = URL(
                    fileURLWithPath: NSTemporaryDirectory(), isDirectory: true
                ).appendingPathComponent("nuxie-orch-reentry-\(UUID().uuidString)", isDirectory: true)
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
            }

            afterEach {
                await stack?.shutdownForCleanup()
                stack = nil
                sleepProvider?.reset()
                if let storageURL {
                    try? FileManager.default.removeItem(at: storageURL)
                }
            }

            // MARK: - Ended by genuine completion

            context("journey ended by completion") {
                beforeEach {
                    // One campaign per policy, each with its own trigger event
                    // and an entry chain that exits immediately.
                    try await stack.installProfile(
                        campaigns: [
                            OrchestrationFixtures.campaign(
                                id: "camp-every", flowId: "flow-every",
                                eventName: "evt_every", reentry: .everyTime),
                            OrchestrationFixtures.campaign(
                                id: "camp-once", flowId: "flow-once",
                                eventName: "evt_once", reentry: .oneTime),
                            OrchestrationFixtures.campaign(
                                id: "camp-window", flowId: "flow-window",
                                eventName: "evt_window",
                                reentry: .oncePerWindow(Window(amount: 1, unit: .hour))),
                        ],
                        flows: [
                            try OrchestrationFixtures.exitFlow(
                                id: "flow-every", trigger: "evt_every", effect: "fx_every"),
                            try OrchestrationFixtures.exitFlow(
                                id: "flow-once", trigger: "evt_once", effect: "fx_once"),
                            try OrchestrationFixtures.exitFlow(
                                id: "flow-window", trigger: "evt_window", effect: "fx_window"),
                        ]
                    )
                }

                func completeOnce(event: String, campaignId: String) async {
                    let box = await stack.trigger(event)
                    expect(box.startedCampaignIds).to(contain(campaignId))
                    await expect { await stack.journeys.getActiveJourneys(for: user).count }
                        .toEventually(equal(0), timeout: .seconds(5))
                    await expect { await stack.lastJourneyExitReason() }
                        .toEventually(equal("completed"), timeout: .seconds(5))
                }

                it("every_time re-enrolls after a completed journey") {
                    await completeOnce(event: "evt_every", campaignId: "camp-every")

                    let box = await stack.trigger("evt_every")
                    expect(box.startedCampaignIds).to(contain("camp-every"))
                    await expect { await stack.journeyStartCount(campaignId: "camp-every") }
                        .toEventually(equal(2), timeout: .seconds(5))
                }

                it("one_time suppresses re-enrollment after a completed journey") {
                    await completeOnce(event: "evt_once", campaignId: "camp-once")
                    expect(stack.journeyStoreOnDisk().hasCompletedCampaign(
                        distinctId: user, campaignId: "camp-once")).to(beTrue())

                    let box = await stack.trigger("evt_once")
                    expect(box.startedCampaignIds).to(beEmpty())
                    expect(box.suppressReasons).to(contain(.reentryLimited))
                    await expect { await stack.journeyStartCount(campaignId: "camp-once") }
                        .to(equal(1))
                }

                it("once_per_window suppresses inside the window and re-enrolls after it passes") {
                    await completeOnce(event: "evt_window", campaignId: "camp-window")

                    // Inside the 1h window: suppressed.
                    let suppressed = await stack.trigger("evt_window")
                    expect(suppressed.startedCampaignIds).to(beEmpty())
                    expect(suppressed.suppressReasons).to(contain(.reentryLimited))

                    // Past the window: allowed again.
                    stack.dateProvider.advance(by: 3_601)
                    let allowed = await stack.trigger("evt_window")
                    expect(allowed.startedCampaignIds).to(contain("camp-window"))
                    await expect { await stack.journeyStartCount(campaignId: "camp-window") }
                        .toEventually(equal(2), timeout: .seconds(5))
                }
            }

            // MARK: - Ended by cancellation (logout-style user switch)

            context("journey ended by cancellation") {
                beforeEach {
                    // Delay flows keep the journeys live until the user
                    // switch cancels them.
                    try await stack.installProfile(
                        campaigns: [
                            OrchestrationFixtures.campaign(
                                id: "camp-every", flowId: "flow-every",
                                eventName: "evt_every", reentry: .everyTime),
                            OrchestrationFixtures.campaign(
                                id: "camp-once", flowId: "flow-once",
                                eventName: "evt_once", reentry: .oneTime),
                            OrchestrationFixtures.campaign(
                                id: "camp-window", flowId: "flow-window",
                                eventName: "evt_window",
                                reentry: .oncePerWindow(Window(amount: 1, unit: .hour))),
                        ],
                        flows: [
                            try OrchestrationFixtures.delayFlow(
                                id: "flow-every", trigger: "evt_every",
                                delayMs: 600_000, effect: "fx_every"),
                            try OrchestrationFixtures.delayFlow(
                                id: "flow-once", trigger: "evt_once",
                                delayMs: 600_000, effect: "fx_once"),
                            try OrchestrationFixtures.delayFlow(
                                id: "flow-window", trigger: "evt_window",
                                delayMs: 600_000, effect: "fx_window"),
                        ]
                    )
                }

                /// Enroll into the delay, then cancel via a logout-style user
                /// switch and switch back.
                func cancelViaUserSwitch(event: String, campaignId: String) async {
                    let box = await stack.trigger(event)
                    expect(box.startedCampaignIds).to(contain(campaignId))
                    await expect { await stack.journeys.getActiveJourneys(for: user).count }
                        .toEventually(equal(1), timeout: .seconds(5))

                    await stack.switchUser(to: "someone-else")
                    await expect { await stack.lastJourneyExitReason() }
                        .toEventually(equal("cancelled"), timeout: .seconds(5))
                    await stack.switchUser(to: user)

                    // Cancellation must never count as a completion.
                    expect(stack.journeyStoreOnDisk().hasCompletedCampaign(
                        distinctId: user, campaignId: campaignId)).to(beFalse())
                }

                it("every_time re-enrolls after a cancelled journey") {
                    await cancelViaUserSwitch(event: "evt_every", campaignId: "camp-every")
                    let box = await stack.trigger("evt_every")
                    expect(box.startedCampaignIds).to(contain("camp-every"))
                }

                it("one_time re-enrolls after a cancelled journey (cancellation never burns a one-time campaign)") {
                    await cancelViaUserSwitch(event: "evt_once", campaignId: "camp-once")
                    let box = await stack.trigger("evt_once")
                    expect(box.startedCampaignIds).to(contain("camp-once"))
                    await expect { await stack.journeyStartCount(campaignId: "camp-once") }
                        .toEventually(equal(2), timeout: .seconds(5))
                }

                it("once_per_window re-enrolls immediately after a cancelled journey (cancellation does not start the window)") {
                    await cancelViaUserSwitch(event: "evt_window", campaignId: "camp-window")
                    // No clock advance — reentry is allowed right away.
                    let box = await stack.trigger("evt_window")
                    expect(box.startedCampaignIds).to(contain("camp-window"))
                }
            }

            // MARK: - Ended by error (flow failed to load)

            context("journey ended by error") {
                beforeEach {
                    // Campaigns reference flow bundles that never arrive: the
                    // enrollment starts, the runner cannot be built, and the
                    // journey exits with reason "error".
                    try await stack.installProfile(
                        campaigns: [
                            OrchestrationFixtures.campaign(
                                id: "camp-every", flowId: "flow-missing-every",
                                eventName: "evt_every", reentry: .everyTime),
                            OrchestrationFixtures.campaign(
                                id: "camp-once", flowId: "flow-missing-once",
                                eventName: "evt_once", reentry: .oneTime),
                            OrchestrationFixtures.campaign(
                                id: "camp-window", flowId: "flow-missing-window",
                                eventName: "evt_window",
                                reentry: .oncePerWindow(Window(amount: 1, unit: .hour))),
                        ],
                        flows: []
                    )
                }

                func errorOnce(event: String, campaignId: String) async {
                    // Current semantics: an errored start still reports
                    // `.journeyStarted` (the journey object was created and
                    // then completed with reason "error").
                    let box = await stack.trigger(event)
                    expect(box.startedCampaignIds).to(contain(campaignId))
                    await expect { await stack.lastJourneyExitReason() }
                        .toEventually(equal("error"), timeout: .seconds(5))
                    await expect { await stack.eventCount("$journey_exited") }
                        .toEventually(beGreaterThanOrEqualTo(1), timeout: .seconds(5))
                    await expect { await stack.journeys.getActiveJourneys(for: user).count }
                        .toEventually(equal(0), timeout: .seconds(5))

                    // An error must never count as a completion.
                    expect(stack.journeyStoreOnDisk().hasCompletedCampaign(
                        distinctId: user, campaignId: campaignId)).to(beFalse())
                }

                it("every_time re-enrolls after an errored journey") {
                    await errorOnce(event: "evt_every", campaignId: "camp-every")
                    let box = await stack.trigger("evt_every")
                    expect(box.startedCampaignIds).to(contain("camp-every"))
                    await expect { await stack.journeyStartCount(campaignId: "camp-every") }
                        .toEventually(equal(2), timeout: .seconds(5))
                }

                it("one_time re-enrolls after an errored journey (a load failure never burns a one-time campaign)") {
                    await errorOnce(event: "evt_once", campaignId: "camp-once")
                    let box = await stack.trigger("evt_once")
                    expect(box.startedCampaignIds).to(contain("camp-once"))
                    await expect { await stack.journeyStartCount(campaignId: "camp-once") }
                        .toEventually(equal(2), timeout: .seconds(5))
                }

                it("once_per_window re-enrolls immediately after an errored journey") {
                    await errorOnce(event: "evt_window", campaignId: "camp-window")
                    let box = await stack.trigger("evt_window")
                    expect(box.startedCampaignIds).to(contain("camp-window"))
                }
            }
        }
    }
}
