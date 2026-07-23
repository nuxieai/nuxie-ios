import Foundation
import Quick
import Nimble
@testable import Nuxie

final class IRPersistenceTests: AsyncSpec {
    override class func spec() {
        func makeEnvelope(_ expr: IRExpr) -> IREnvelope {
            IREnvelope(
                ir_version: 1,
                engine_min: "1.0.0",
                compiled_at: 1_723_780_000,
                expr: expr
            )
        }

        func makeCampaign() -> Campaign {
            Campaign(
                id: "campaign_1",
                name: "Campaign",
                flowId: "flow_1",
                flowNumber: 1,
                flowName: "Paywall",
                reentry: .everyTime,
                publishedAt: "2026-01-01T00:00:00Z",
                trigger: .event(EventTriggerConfig(
                    eventName: "app_opened",
                    condition: makeEnvelope(.pred(op: "eq", key: "source", value: .string("push")))
                )),
                goal: GoalConfig(
                    kind: .attribute,
                    attributeExpr: makeEnvelope(.feature(op: "gte", id: "credits", value: .number(10))),
                    window: 86_400
                ),
                exitPolicy: ExitPolicy(mode: .onGoal),
                conversionAnchor: "last_flow_shown",
                campaignType: "paywall"
            )
        }

        describe("cached profile persistence") {
            it("encodes and decodes profile responses containing IR") {
                let cachedProfile = CachedProfile(
                    response: ProfileResponse(
                        campaigns: [makeCampaign()],
                        segments: [
                            Segment(
                                id: "segment_1",
                                name: "High Intent",
                                condition: makeEnvelope(.eventsCount(
                                    name: "paywall_viewed",
                                    since: .timeAgo(duration: .duration(86_400)),
                                    until: .timeNow,
                                    within: nil,
                                    where_: .pred(op: "eq", key: "screen", value: .string("premium"))
                                ))
                            ),
                        ],
                        flows: [],
                        userProperties: nil,
                        experiments: nil,
                        features: nil
                    ),
                    distinctId: "user_1",
                    cachedAt: Date(timeIntervalSince1970: 1_723_780_000)
                )

                let data = try JSONEncoder().encode(cachedProfile)
                let decoded = try JSONDecoder().decode(CachedProfile.self, from: data)

                expect(decoded.distinctId).to(equal("user_1"))
                expect(decoded.response.campaigns).to(haveCount(1))
                expect(decoded.response.segments).to(haveCount(1))
                expect(decoded.response.campaigns[0].goal?.attributeExpr).to(equal(cachedProfile.response.campaigns[0].goal?.attributeExpr))
                expect(decoded.response.segments[0].condition).to(equal(cachedProfile.response.segments[0].condition))
            }
        }

        describe("journey persistence") {
            var tempRoot: URL!

            beforeEach {
                tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
                    "nuxie-ir-persistence-\(UUID().uuidString)",
                    isDirectory: true
                )
            }

            afterEach {
                try? FileManager.default.removeItem(at: tempRoot)
            }

            it("saves and loads journeys with IR-backed snapshots and pending actions") {
                let campaign = makeCampaign()
                let waitCondition = makeEnvelope(.compare(
                    op: ">=",
                    left: .eventsCount(
                        name: "purchase_completed",
                        since: .timeAgo(duration: .duration(3_600)),
                        until: .timeNow,
                        within: nil,
                        where_: .pred(op: "eq", key: "sku", value: .string("premium"))
                    ),
                    right: .number(1)
                ))

                let journey = Journey(id: "journey_1", campaign: campaign, distinctId: "user_1", now: Date())
                journey.flowState.pendingAction = FlowPendingAction(
                    handlerId: "handler_1",
                    screenId: "screen_1",
                    componentId: "component_1",
                    actionIndex: 2,
                    kind: .waitUntil,
                    resumeAt: Date(timeIntervalSince1970: 1_723_780_600),
                    condition: waitCondition,
                    maxTimeMs: 15_000,
                    startedAt: Date(timeIntervalSince1970: 1_723_780_100),
                    resumeActions: nil
                )

                let store = JourneyStore(customStoragePath: tempRoot, dateProvider: SystemDateProvider())
                try store.saveJourney(journey)

                let loaded = store.loadJourney(id: journey.id)

                expect(loaded).notTo(beNil())
                expect(loaded?.goalSnapshot?.attributeExpr).to(equal(journey.goalSnapshot?.attributeExpr))
                expect(loaded?.flowState.pendingAction?.condition).to(equal(waitCondition))
                expect(loaded?.flowState.pendingAction?.maxTimeMs).to(equal(15_000))

                guard case .event(let loadedTrigger)? = loaded?.triggerSnapshot else {
                    fail("Expected event trigger snapshot")
                    return
                }

                expect(loadedTrigger.eventName).to(equal("app_opened"))
                expect(loadedTrigger.condition).to(equal(({
                    guard case .event(let trigger) = campaign.trigger else { return nil }
                    return trigger.condition
                })()))
            }
        }
    }
}
