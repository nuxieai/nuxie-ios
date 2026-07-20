import Foundation
import Quick
import Nimble
import FactoryKit
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

private final class NoOpFeatureService: FeatureServiceProtocol {
    func getCached(featureId: String, entityId: String?) async -> FeatureAccess? { nil }
    func getAllCached() async -> [String: FeatureAccess] { [:] }
    func check(featureId: String, requiredBalance: Int?, entityId: String?) async throws -> FeatureCheckResult {
        throw NSError(domain: "GoalEvaluatorTests", code: 404, userInfo: [NSLocalizedDescriptionKey: "feature not found: \(featureId)"])
    }
    func checkWithCache(
        featureId: String,
        requiredBalance: Int?,
        entityId: String?,
        forceRefresh: Bool
    ) async throws -> FeatureAccess {
        .notFound
    }
    func clearCache() async {}
    func handleUserChange(from oldDistinctId: String, to newDistinctId: String) async {}
    func syncFeatureInfo() async {}
    func updateFromPurchase(_ features: [PurchaseFeature]) async {}
}

final class GoalEvaluatorTests: AsyncSpec {
    override class func spec() {
        var eventService: MockEventService!
        var dateProvider: MockDateProvider!

        beforeEach {
            let eventServiceInstance = MockEventService()
            let dateProviderInstance = MockDateProvider(initialDate: Date(timeIntervalSince1970: 20))

            eventService = eventServiceInstance
            dateProvider = dateProviderInstance

            Container.shared.eventService.register { eventServiceInstance }
            Container.shared.segmentService.register { MockSegmentService() }
            Container.shared.identityService.register { MockIdentityService() }
            Container.shared.featureService.register { NoOpFeatureService() }
            Container.shared.irRuntime.register { IRRuntime() }
            Container.shared.dateProvider.register { dateProviderInstance }
        }

        describe("GoalEvaluator") {
            it("uses event-time semantics for event-only attribute goals after the window ends") {
                let anchor = Date(timeIntervalSince1970: 10)
                let purchaseAt = Date(timeIntervalSince1970: 11)
                let restoreAt = Date(timeIntervalSince1970: 11.5)
                dateProvider.setCurrentDate(Date(timeIntervalSince1970: 20))

                await eventService.route(
                    TestEventBuilder(name: "$purchase_completed")
                        .withDistinctId("user_1")
                        .withTimestamp(purchaseAt)
                        .withProperties(["journey_id": "journey_1"])
                        .build()
                )
                await eventService.route(
                    TestEventBuilder(name: "$restore_completed")
                        .withDistinctId("user_1")
                        .withTimestamp(restoreAt)
                        .withProperties(["journey_id": "journey_1"])
                        .build()
                )

                let goal = GoalConfig(
                    kind: .attribute,
                    attributeExpr: IREnvelope(
                        ir_version: 1,
                        engine_min: nil,
                        compiled_at: nil,
                        expr: .and([
                            .eventsExists(
                                name: "$purchase_completed",
                                since: nil,
                                until: nil,
                                within: nil,
                                where_: .pred(
                                    op: "eq",
                                    key: "journey_id",
                                    value: .journeyId
                                )
                            ),
                            .eventsExists(
                                name: "$restore_completed",
                                since: nil,
                                until: nil,
                                within: nil,
                                where_: .pred(
                                    op: "eq",
                                    key: "journey_id",
                                    value: .journeyId
                                )
                            ),
                        ])
                    ),
                    window: 2
                )

                let campaign = Campaign(
                    id: "camp_1",
                    name: "Campaign",
                    flowId: "flow_1",
                    flowNumber: 1,
                    flowName: nil,
                    reentry: .everyTime,
                    publishedAt: "2026-01-01T00:00:00Z",
                    trigger: .event(EventTriggerConfig(eventName: "app_opened", condition: nil)),
                    goal: goal,
                    exitPolicy: nil,
                    conversionAnchor: nil,
                    campaignType: nil
                )
                let journey = Journey(id: "journey_1", campaign: campaign, distinctId: "user_1")
                journey.conversionAnchorAt = anchor
                journey.conversionWindow = 2

                let result = await GoalEvaluator().isGoalMet(journey: journey, campaign: campaign)

                expect(result.met).to(beTrue())
                expect(result.at).to(equal(restoreAt))
            }

            it("matches contains predicates in event-only attribute goals") {
                let anchor = Date(timeIntervalSince1970: 10)
                let purchaseAt = Date(timeIntervalSince1970: 11)
                dateProvider.setCurrentDate(Date(timeIntervalSince1970: 20))

                await eventService.route(
                    TestEventBuilder(name: "$purchase_completed")
                        .withDistinctId("user_1")
                        .withTimestamp(purchaseAt)
                        .withProperties([
                            "journey_id": "journey_1",
                            "product_name": "Annual Pro"
                        ])
                        .build()
                )

                let goal = GoalConfig(
                    kind: .attribute,
                    attributeExpr: IREnvelope(
                        ir_version: 1,
                        engine_min: nil,
                        compiled_at: nil,
                        expr: .eventsExists(
                            name: "$purchase_completed",
                            since: nil,
                            until: nil,
                            within: nil,
                            where_: .predAnd([
                                .pred(
                                    op: "eq",
                                    key: "journey_id",
                                    value: .journeyId
                                ),
                                .pred(
                                    op: "contains",
                                    key: "product_name",
                                    value: .string("annual")
                                ),
                            ])
                        )
                    ),
                    window: 2
                )

                let campaign = Campaign(
                    id: "camp_1",
                    name: "Campaign",
                    flowId: "flow_1",
                    flowNumber: 1,
                    flowName: nil,
                    reentry: .everyTime,
                    publishedAt: "2026-01-01T00:00:00Z",
                    trigger: .event(EventTriggerConfig(eventName: "app_opened", condition: nil)),
                    goal: goal,
                    exitPolicy: nil,
                    conversionAnchor: nil,
                    campaignType: nil
                )
                let journey = Journey(id: "journey_1", campaign: campaign, distinctId: "user_1")
                journey.conversionAnchorAt = anchor
                journey.conversionWindow = 2

                let result = await GoalEvaluator().isGoalMet(journey: journey, campaign: campaign)

                expect(result.met).to(beTrue())
                expect(result.at).to(equal(purchaseAt))
            }

            it("does not load event history for non-event attribute goals") {
                let now = Date(timeIntervalSince1970: 50)
                dateProvider.setCurrentDate(now)
                let identityService = MockIdentityService()
                identityService.setUserProperty("plan", value: "pro")
                Container.shared.identityService.register { identityService }

                let goal = GoalConfig(
                    kind: .attribute,
                    attributeExpr: IREnvelope(
                        ir_version: 1,
                        engine_min: nil,
                        compiled_at: nil,
                        expr: .user(op: "eq", key: "plan", value: .string("pro"))
                    ),
                    window: 10
                )

                let campaign = Campaign(
                    id: "camp_1",
                    name: "Campaign",
                    flowId: "flow_1",
                    flowNumber: 1,
                    flowName: nil,
                    reentry: .everyTime,
                    publishedAt: "2026-01-01T00:00:00Z",
                    trigger: .event(EventTriggerConfig(eventName: "app_opened", condition: nil)),
                    goal: goal,
                    exitPolicy: nil,
                    conversionAnchor: nil,
                    campaignType: nil
                )
                let journey = Journey(id: "journey_1", campaign: campaign, distinctId: "user_1")
                journey.conversionAnchorAt = now
                journey.conversionWindow = 10

                let result = await GoalEvaluator().isGoalMet(journey: journey, campaign: campaign)

                expect(result.met).to(beTrue())
                expect(result.at).to(equal(now))
                expect(eventService.getEventsForUserCallCount).to(equal(0))
            }

            it("preserves full-history lookup for unfiltered event goals") {
                let anchor = Date(timeIntervalSince1970: 10)
                let goalEventAt = Date(timeIntervalSince1970: 11)
                dateProvider.setCurrentDate(Date(timeIntervalSince1970: 20))

                eventService.setLastEventTime(
                    name: "$notifications_enabled",
                    distinctId: "user_1",
                    time: goalEventAt
                )

                let goal = GoalConfig(
                    kind: .event,
                    eventName: "$notifications_enabled",
                    eventFilter: nil,
                    window: 20
                )

                let campaign = Campaign(
                    id: "camp_1",
                    name: "Campaign",
                    flowId: "flow_1",
                    flowNumber: 1,
                    flowName: nil,
                    reentry: .everyTime,
                    publishedAt: "2026-01-01T00:00:00Z",
                    trigger: .event(EventTriggerConfig(eventName: "app_opened", condition: nil)),
                    goal: goal,
                    exitPolicy: nil,
                    conversionAnchor: nil,
                    campaignType: nil
                )
                let journey = Journey(id: "journey_1", campaign: campaign, distinctId: "user_1")
                journey.conversionAnchorAt = anchor
                journey.conversionWindow = 20

                let result = await GoalEvaluator().isGoalMet(journey: journey, campaign: campaign)

                expect(result.met).to(beTrue())
                expect(result.at).to(equal(goalEventAt))
                expect(eventService.getEventsForUserCallCount).to(equal(0))
            }
        }
    }
}
