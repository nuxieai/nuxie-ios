import Foundation
import Quick
import Nimble
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

private final class NoOpFeatureService: FeatureServiceProtocol {
    func getCached(featureId: String, entityId: String?) async -> FeatureAccess? { nil }
    func getAllCached() async -> [String: FeatureAccess] { [:] }
    func check(featureId: String, requiredBalance: Double?, entityId: String?) async throws -> FeatureCheckResult {
        throw NSError(domain: "GoalEvaluatorTests", code: 404, userInfo: [NSLocalizedDescriptionKey: "feature not found: \(featureId)"])
    }
    func checkWithCache(
        featureId: String,
        requiredBalance: Double?,
        entityId: String?,
        forceRefresh: Bool
    ) async throws -> FeatureAccess {
        .notFound
    }
    func clearCache() async {}
    func handleUserChange(from oldDistinctId: String, to newDistinctId: String) async {}
    func syncFeatureInfo() async {}
    func updateFromPurchase(
        _ features: [PurchaseFeature],
        distinctId: String
    ) async {}
}

final class GoalEvaluatorTests: AsyncSpec {
    override class func spec() {
        var eventLog: MockEventLog!
        var dateProvider: MockDateProvider!
        var identityService: MockIdentityService!

        // Builds a fresh evaluator against the current mocks, mirroring the
        // lazy resolution the old container registration provided.
        let makeGoalEvaluator: () -> GoalEvaluator = {
            let segments = MockSegmentService()
            let features = NoOpFeatureService()
            let irRuntime = IRRuntime(dateProvider: dateProvider)
            irRuntime.wire(
                identity: identityService,
                eventLog: eventLog,
                segments: segments,
                features: features
            )
            return GoalEvaluator(
                eventLog: eventLog,
                segments: segments,
                features: features,
                identity: identityService,
                dateProvider: dateProvider,
                irRuntime: irRuntime
            )
        }

        beforeEach {
            eventLog = MockEventLog()
            dateProvider = MockDateProvider(initialDate: Date(timeIntervalSince1970: 20))
            identityService = MockIdentityService()
        }

        describe("GoalEvaluator") {
            it("uses the IR runtime clock for lifecycle event operators") {
                let fixedNow = Date(timeIntervalSince1970: 200)
                dateProvider.setCurrentDate(fixedNow)
                await eventLog.route(
                    TestEventBuilder(name: "recent_activity")
                        .withDistinctId("user_1")
                        .withTimestamp(Date(timeIntervalSince1970: 190))
                        .build()
                )

                let goal = GoalConfig(
                    kind: .attribute,
                    attributeExpr: IREnvelope(
                        ir_version: 1,
                        engine_min: nil,
                        compiled_at: nil,
                        expr: .eventsStopped(
                            name: "recent_activity",
                            inactiveFor: .duration(50),
                            where_: nil
                        )
                    ),
                    window: 1_000
                )
                let experience = Experience(
                    id: "clock-campaign",
                    versionId: "clock-flow",
                    name: "Clock",
                    reentry: .everyTime,
                    publishedAt: "2026-01-01T00:00:00Z",
                    trigger: .event(EventTriggerConfig(eventName: "app_opened", condition: nil)),
                    goal: goal,
                    exitPolicy: nil,
                    conversionAnchor: nil,
                    experienceType: nil
                )
                var journey = JourneySnapshot(
                    id: "clock-journey",
                    experience: experience,
                    distinctId: "user_1",
                    now: fixedNow
                )
                journey.conversionAnchorAt = Date(timeIntervalSince1970: 0)
                journey.conversionWindow = 1_000

                let result = await makeGoalEvaluator().isGoalMet(journey: journey)

                expect(result.met).to(beFalse())
            }

            it("uses event-time semantics for event-only attribute goals after the window ends") {
                let anchor = Date(timeIntervalSince1970: 10)
                let purchaseAt = Date(timeIntervalSince1970: 11)
                let restoreAt = Date(timeIntervalSince1970: 11.5)
                dateProvider.setCurrentDate(Date(timeIntervalSince1970: 20))

                await eventLog.route(
                    TestEventBuilder(name: "$purchase_completed")
                        .withDistinctId("user_1")
                        .withTimestamp(purchaseAt)
                        .withProperties(["journey_id": "journey_1"])
                        .build()
                )
                await eventLog.route(
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

                let experience = Experience(
                    id: "camp_1",
                    versionId: "flow_1",
                    name: "Experience",
                    reentry: .everyTime,
                    publishedAt: "2026-01-01T00:00:00Z",
                    trigger: .event(EventTriggerConfig(eventName: "app_opened", condition: nil)),
                    goal: goal,
                    exitPolicy: nil,
                    conversionAnchor: nil,
                    experienceType: nil
                )
                var journey = JourneySnapshot(id: "journey_1", experience: experience, distinctId: "user_1", now: Date())
                journey.conversionAnchorAt = anchor
                journey.conversionWindow = 2

                let result = await makeGoalEvaluator().isGoalMet(journey: journey)

                expect(result.met).to(beTrue())
                expect(result.at).to(equal(restoreAt))
            }

            it("matches contains predicates in event-only attribute goals") {
                let anchor = Date(timeIntervalSince1970: 10)
                let purchaseAt = Date(timeIntervalSince1970: 11)
                dateProvider.setCurrentDate(Date(timeIntervalSince1970: 20))

                await eventLog.route(
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

                let experience = Experience(
                    id: "camp_1",
                    versionId: "flow_1",
                    name: "Experience",
                    reentry: .everyTime,
                    publishedAt: "2026-01-01T00:00:00Z",
                    trigger: .event(EventTriggerConfig(eventName: "app_opened", condition: nil)),
                    goal: goal,
                    exitPolicy: nil,
                    conversionAnchor: nil,
                    experienceType: nil
                )
                var journey = JourneySnapshot(id: "journey_1", experience: experience, distinctId: "user_1", now: Date())
                journey.conversionAnchorAt = anchor
                journey.conversionWindow = 2

                let result = await makeGoalEvaluator().isGoalMet(journey: journey)

                expect(result.met).to(beTrue())
                expect(result.at).to(equal(purchaseAt))
            }

            it("does not satisfy is_not_set event goals from corrupt transient properties") {
                let anchor = Date(timeIntervalSince1970: 10)
                let corruptEvent = StoredEvent(
                    id: "corrupt-purchase",
                    name: "purchase",
                    properties: Data("not-json".utf8),
                    timestamp: anchor.addingTimeInterval(1),
                    distinctId: "user_1",
                )
                let goal = GoalConfig(
                    kind: .event,
                    eventName: "purchase",
                    eventFilter: IREnvelope(
                        ir_version: 1,
                        engine_min: nil,
                        compiled_at: nil,
                        expr: .event(
                            op: "is_not_set",
                            key: "properties.plan",
                            value: nil
                        )
                    ),
                    window: 20
                )
                let experience = Experience(
                    id: "corrupt-goal-campaign",
                    versionId: "corrupt-goal-flow",
                    name: "Corrupt goal",
                    reentry: .everyTime,
                    publishedAt: "2026-01-01T00:00:00Z",
                    trigger: .event(EventTriggerConfig(eventName: "app_opened", condition: nil)),
                    goal: goal,
                    exitPolicy: nil,
                    conversionAnchor: nil,
                    experienceType: nil
                )
                var journey = JourneySnapshot(
                    id: "corrupt-goal-journey",
                    experience: experience,
                    distinctId: "user_1",
                    now: anchor
                )
                journey.conversionAnchorAt = anchor
                journey.conversionWindow = 20

                let result = await makeGoalEvaluator().isGoalMet(
                    journey: journey,
                    transientEvents: [corruptEvent]
                )

                expect(result.met).to(beFalse())
                expect(result.sourceFactRef).to(beNil())
            }

            it("does not load event history for non-event attribute goals") {
                let now = Date(timeIntervalSince1970: 50)
                dateProvider.setCurrentDate(now)
                identityService.setUserProperty("plan", value: "pro")

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

                let experience = Experience(
                    id: "camp_1",
                    versionId: "flow_1",
                    name: "Experience",
                    reentry: .everyTime,
                    publishedAt: "2026-01-01T00:00:00Z",
                    trigger: .event(EventTriggerConfig(eventName: "app_opened", condition: nil)),
                    goal: goal,
                    exitPolicy: nil,
                    conversionAnchor: nil,
                    experienceType: nil
                )
                var journey = JourneySnapshot(id: "journey_1", experience: experience, distinctId: "user_1", now: Date())
                journey.conversionAnchorAt = now
                journey.conversionWindow = 10

                let result = await makeGoalEvaluator().isGoalMet(journey: journey)

                expect(result.met).to(beTrue())
                expect(result.at).to(equal(now))
                expect(eventLog.getEventsForUserCallCount).to(equal(0))
            }

            it("selects the earliest qualifying event and its stable fact ref") {
                let anchor = Date(timeIntervalSince1970: 10)
                let earliestAt = Date(timeIntervalSince1970: 11)
                let laterAt = Date(timeIntervalSince1970: 12)
                dateProvider.setCurrentDate(Date(timeIntervalSince1970: 20))

                await eventLog.route(
                    NuxieEvent(
                        id: "fact-later",
                        name: "$notifications_enabled",
                        distinctId: "user_1",
                        timestamp: laterAt
                    )
                )
                await eventLog.route(
                    NuxieEvent(
                        id: "fact-earliest",
                        name: "$notifications_enabled",
                        distinctId: "user_1",
                        timestamp: earliestAt
                    )
                )

                let goal = GoalConfig(
                    kind: .event,
                    eventName: "$notifications_enabled",
                    eventFilter: nil,
                    window: 20
                )

                let experience = Experience(
                    id: "camp_1",
                    versionId: "flow_1",
                    name: "Experience",
                    reentry: .everyTime,
                    publishedAt: "2026-01-01T00:00:00Z",
                    trigger: .event(EventTriggerConfig(eventName: "app_opened", condition: nil)),
                    goal: goal,
                    exitPolicy: nil,
                    conversionAnchor: nil,
                    experienceType: nil
                )
                var journey = JourneySnapshot(id: "journey_1", experience: experience, distinctId: "user_1", now: Date())
                journey.conversionAnchorAt = anchor
                journey.conversionWindow = 20

                let result = await makeGoalEvaluator().isGoalMet(journey: journey)

                expect(result.met).to(beTrue())
                expect(result.at).to(equal(earliestAt))
                expect(result.sourceFactRef).to(equal("fact-earliest"))
                expect(eventLog.getEventsForUserCallCount).to(equal(1))
            }

            it("matches milestone goals by milestone ID") {
                let anchor = Date(timeIntervalSince1970: 10)
                let milestoneAt = Date(timeIntervalSince1970: 11)
                await eventLog.route(
                    NuxieEvent(
                        id: "fact-milestone",
                        name: JourneyEvents.journeyMilestone,
                        distinctId: "user_1",
                        properties: ["milestone_id": "activated"],
                        timestamp: milestoneAt
                    )
                )
                await eventLog.route(
                    NuxieEvent(
                        id: "fact-other-milestone",
                        name: JourneyEvents.journeyMilestone,
                        distinctId: "user_1",
                        properties: ["milestone_id": "ignored"],
                        timestamp: Date(timeIntervalSince1970: 10.5)
                    )
                )

                let goal = GoalConfig(
                    kind: .milestone,
                    milestoneId: "activated",
                    window: 20
                )
                let experience = Experience(
                    id: "camp_1",
                    versionId: "version_1",
                    name: "Experience",
                    reentry: .everyTime,
                    publishedAt: "2026-01-01T00:00:00Z",
                    trigger: .event(
                        EventTriggerConfig(eventName: "app_opened", condition: nil)
                    ),
                    goal: goal,
                    exitPolicy: nil,
                    conversionAnchor: nil,
                    experienceType: nil
                )
                var journey = JourneySnapshot(
                    id: "journey_1",
                    experience: experience,
                    distinctId: "user_1",
                    now: anchor
                )
                journey.conversionAnchorAt = anchor
                journey.conversionWindow = 20

                let result = await makeGoalEvaluator().isGoalMet(journey: journey)

                expect(result.met).to(beTrue())
                expect(result.at).to(equal(milestoneAt))
                expect(result.sourceFactRef).to(equal("fact-milestone"))
            }
        }
    }
}
