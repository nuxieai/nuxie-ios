import Foundation
import Quick
import Nimble
import XCTest
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

        func makeExperience() -> Experience {
            Experience(
                id: "experience_1",
                versionId: "flow_1",
                name: "Experience",
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
                experienceType: "paywall"
            )
        }

        describe("cached profile persistence") {
            it("encodes and decodes profile responses containing IR") {
                let cachedProfile = CachedProfile(
                    response: ProfileResponse(
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
                expect(decoded.response.segments).to(haveCount(1))
                expect(decoded.response.segments[0].condition).to(equal(cachedProfile.response.segments[0].condition))
            }
        }

        describe("journey persistence") {
            var tempRoot: URL!

            func onlyActiveJourneyFile() throws -> URL {
                let directory = tempRoot.appendingPathComponent("nuxie/journeys/active")
                return try XCTUnwrap(
                    FileManager.default.contentsOfDirectory(
                        at: directory,
                        includingPropertiesForKeys: nil
                    ).first
                )
            }

            beforeEach {
                tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
                    "nuxie-ir-persistence-\(UUID().uuidString)",
                    isDirectory: true
                )
            }

            afterEach {
                try? FileManager.default.removeItem(at: tempRoot)
            }

            it("saves and loads journeys with typed snapshots and pending actions") {
                let experience = makeExperience()
                let waitCondition = JourneyCondition.compare(
                    op: "==",
                    left: .eventField("sku"),
                    right: .string("premium")
                )

                var journey = JourneySnapshot(id: "journey_1", experience: experience, distinctId: "user_1", now: Date())
                journey.executionState.pendingAction = JourneyPendingAction(
                    handlerId: "handler_1",
                    screenId: "screen_1",
                    componentId: "component_1",
                    actionIndex: 2,
                    kind: .waitUntil,
                    resumeAt: Date(timeIntervalSince1970: 1_723_780_600),
                    journeyCondition: waitCondition,
                    journeyWaitTrigger: .event(
                        eventName: "purchase_completed",
                        payloadSchema: nil
                    ),
                    maxTimeMs: 15_000,
                    startedAt: Date(timeIntervalSince1970: 1_723_780_100)
                )

                let store = JourneyStore(customStoragePath: tempRoot, dateProvider: SystemDateProvider())
                try store.saveJourney(journey)

                let loaded = store.loadJourney(id: journey.id)

                expect(loaded).notTo(beNil())
                expect(loaded?.goalSnapshot?.attributeExpr).to(equal(journey.goalSnapshot?.attributeExpr))
                expect(loaded?.executionState.pendingAction?.journeyCondition).to(equal(waitCondition))
                expect(loaded?.executionState.pendingAction?.maxTimeMs).to(equal(15_000))
                expect(loaded?.stateVersion).to(equal(JourneyStateEnvelope.currentVersion))
                expect(loaded?.epoch).to(equal(0))

                guard case .event(let loadedTrigger)? = loaded?.triggerSnapshot else {
                    fail("Expected event trigger snapshot")
                    return
                }

                expect(loadedTrigger.eventName).to(equal("app_opened"))
                expect(loadedTrigger.condition).to(equal(({
                    guard case .event(let trigger)? = experience.trigger else { return nil }
                    return trigger.condition
                })()))
            }

            it("drops snapshots that contain retired pending-action schemas") {
                for retiredKey in ["condition", "resumeActions"] {
                    var journey = JourneySnapshot(
                        id: "journey_\(retiredKey)",
                        experience: makeExperience(),
                        distinctId: "user_1",
                        now: Date()
                    )
                    journey.executionState.pendingAction = JourneyPendingAction(
                        handlerId: "handler_1",
                        screenId: "screen_1",
                        componentId: nil,
                        actionIndex: 0,
                        kind: .delay,
                        resumeAt: Date(timeIntervalSince1970: 1_723_780_600),
                        maxTimeMs: nil,
                        startedAt: Date(timeIntervalSince1970: 1_723_780_100)
                    )
                    let store = JourneyStore(
                        customStoragePath: tempRoot,
                        dateProvider: SystemDateProvider()
                    )
                    try store.saveJourney(journey)
                    let file = try onlyActiveJourneyFile()
                    let data = try Data(contentsOf: file)
                    var object = try XCTUnwrap(
                        JSONSerialization.jsonObject(with: data) as? [String: Any]
                    )
                    var executionState = try XCTUnwrap(
                        object["executionState"] as? [String: Any]
                    )
                    var pending = try XCTUnwrap(
                        executionState["pendingAction"] as? [String: Any]
                    )
                    pending[retiredKey] = retiredKey == "condition" ? [:] : []
                    executionState["pendingAction"] = pending
                    object["executionState"] = executionState
                    try JSONSerialization.data(withJSONObject: object).write(
                        to: file,
                        options: .atomic
                    )

                    expect(store.loadActiveJourneys()).to(beEmpty())
                    expect(FileManager.default.fileExists(atPath: file.path)).to(beFalse())
                }
            }

            it("persists captured-event routing receipts across service instances") {
                let handledAt = Date(timeIntervalSince1970: 1_723_780_000)
                let first = JourneyStore(
                    customStoragePath: tempRoot,
                    dateProvider: SystemDateProvider()
                )
                try first.recordHandledEvent(
                    id: "purchase-completed:transaction-1",
                    handledAt: handledAt
                )

                let relaunched = JourneyStore(
                    customStoragePath: tempRoot,
                    dateProvider: SystemDateProvider()
                )

                expect(relaunched.hasHandledEvent(
                    id: "purchase-completed:transaction-1"
                )).to(beTrue())
                expect(relaunched.hasHandledEvent(
                    id: "purchase-completed:transaction-2"
                )).to(beFalse())
            }

            it("fences suspended continuations by exact response version") {
                let delay = JourneyPendingAction(
                    handlerId: "delay-handler",
                    screenId: "screen_1",
                    componentId: nil,
                    actionIndex: 0,
                    kind: .delay,
                    resumeAt: Date(),
                    maxTimeMs: nil,
                    startedAt: Date(),
                    responseVersion: 3
                )
                let wait = JourneyPendingAction(
                    handlerId: "wait-handler",
                    screenId: "screen_1",
                    componentId: nil,
                    actionIndex: 0,
                    kind: .waitUntil,
                    resumeAt: Date(),
                    maxTimeMs: nil,
                    startedAt: Date(),
                    responseVersion: 3,
                    allowsResponseVersionRefresh: true
                )

                expect(delay.hasResponseSnapshotConflict(currentVersion: 3)).to(beFalse())
                expect(delay.hasResponseSnapshotConflict(currentVersion: 4)).to(beTrue())
                expect(wait.hasResponseSnapshotConflict(currentVersion: 4)).to(beFalse())
            }

            it("retains an active journey file with an unknown state version") {
                let journey = JourneySnapshot(
                    id: "journey_unknown",
                    experience: makeExperience(),
                    distinctId: "user_1",
                    now: Date()
                )
                let store = JourneyStore(
                    customStoragePath: tempRoot,
                    dateProvider: SystemDateProvider()
                )
                try store.saveJourney(journey)
                let file = try onlyActiveJourneyFile()
                var object = try JSONSerialization.jsonObject(
                    with: Data(contentsOf: file)
                ) as! [String: Any]
                object["stateVersion"] = 99
                try JSONSerialization.data(withJSONObject: object).write(
                    to: file,
                    options: .atomic
                )

                expect(store.loadJourney(id: journey.id)).to(beNil())
                expect(FileManager.default.fileExists(atPath: file.path)).to(beTrue())
                expect(store.loadActiveJourneys()).to(beEmpty())
                expect(FileManager.default.fileExists(atPath: file.path)).to(beTrue())
            }

            it("rejects versionless journey snapshots") {
                let journey = JourneySnapshot(
                    id: "journey_versionless",
                    experience: makeExperience(),
                    distinctId: "user_1",
                    now: Date()
                )
                let store = JourneyStore(
                    customStoragePath: tempRoot,
                    dateProvider: SystemDateProvider()
                )
                try store.saveJourney(journey)
                let file = try onlyActiveJourneyFile()
                var object = try JSONSerialization.jsonObject(
                    with: Data(contentsOf: file)
                ) as! [String: Any]
                object.removeValue(forKey: "stateVersion")
                object.removeValue(forKey: "epoch")
                object.removeValue(forKey: "isGhost")
                try JSONSerialization.data(withJSONObject: object).write(
                    to: file,
                    options: .atomic
                )

                expect(store.loadJourney(id: journey.id)).to(beNil())
                expect(store.loadActiveJourneys()).to(beEmpty())
                expect(FileManager.default.fileExists(atPath: file.path)).to(beTrue())
            }
        }
    }
}
