import Foundation
import Quick
import Nimble
import FactoryKit
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

/// Phase 9 segment semantics: evaluation scoped to experience-referenced
/// segments, event-driven re-evaluation off the committed-events stream,
/// deletions propagated by empty updates, engine gating fail-closed.
final class SegmentServiceTests: AsyncSpec {
    override class func spec() {
        describe("SegmentService") {
            var service: SegmentService!
            var mockIdentity: MockIdentityService!

            func envelope(_ expr: IRExpr, engineMin: String? = nil) -> IREnvelope {
                IREnvelope(ir_version: 1, engine_min: engineMin, compiled_at: nil, expr: expr)
            }

            func segment(_ id: String, _ expr: IRExpr, engineMin: String? = nil) -> Segment {
                Segment(id: id, name: id, condition: envelope(expr, engineMin: engineMin))
            }

            func campaign(referencing expr: IRExpr, goalSegmentId: String? = nil) -> Campaign {
                let goal: GoalConfig? = goalSegmentId.map {
                    GoalConfig(kind: .segmentEnter, segmentId: $0)
                }
                return Campaign(
                    id: "campaign-1",
                    name: "Test Campaign",
                    flowId: "flow-1",
                    flowNumber: 1,
                    flowName: nil,
                    reentry: .everyTime,
                    publishedAt: ISO8601DateFormatter().string(from: Date()),
                    trigger: .segment(SegmentTriggerConfig(condition: envelope(expr))),
                    goal: goal,
                    exitPolicy: nil,
                    conversionAnchor: nil,
                    campaignType: nil
                )
            }

            beforeEach {
                let testConfig = NuxieConfiguration(apiKey: "test-api-key")
                Container.shared.sdkConfiguration.register { testConfig }

                mockIdentity = MockIdentityService()
                // Unique identity per test: memberships persist to a real
                // disk cache keyed by distinctId, and stale entries would
                // turn "entered" into "remained".
                mockIdentity.setDistinctId("seg-test-\(UUID.v7().uuidString)")
                Container.shared.identityService.register { mockIdentity }
                Container.shared.eventLog.register { MockEventLog() }
                Container.shared.dateProvider.register { MockDateProvider() }

                service = SegmentService(
                    identity: mockIdentity,
                    dateProvider: Container.shared.dateProvider(),
                    irRuntime: Container.shared.irRuntime()
                )
            }

            afterEach {
                await service.clearSegments(for: mockIdentity.getDistinctId())
                service = nil
            }

            describe("experience scoping") {
                it("evaluates only segments referenced by cached experiences") {
                    let referenced = segment("seg-referenced", .bool(true))
                    let unreferenced = segment("seg-unreferenced", .bool(true))
                    let exp = campaign(
                        referencing: .segment(op: "in", id: "seg-referenced", within: nil))

                    await service.updateSegments(
                        [referenced, unreferenced], referencedBy: [exp],
                        for: mockIdentity.getDistinctId())

                    await expect { await service.isInSegment("seg-referenced") }.to(beTrue())
                    // Qualifying condition, but no experience observes it —
                    // never evaluated, never a member.
                    await expect { await service.isInSegment("seg-unreferenced") }.to(beFalse())
                }

                it("expands references transitively through segment conditions") {
                    // campaign → seg-a; seg-a's condition → seg-b
                    let a = segment(
                        "seg-a",
                        .or([.bool(true), .segment(op: "in", id: "seg-b", within: nil)]))
                    let b = segment("seg-b", .bool(true))
                    let exp = campaign(referencing: .segment(op: "in", id: "seg-a", within: nil))

                    await service.updateSegments(
                        [a, b], referencedBy: [exp], for: mockIdentity.getDistinctId())

                    await expect { await service.isInSegment("seg-a") }.to(beTrue())
                    await expect { await service.isInSegment("seg-b") }.to(beTrue())
                }

                it("includes goal segment references") {
                    let goalSegment = segment("seg-goal", .bool(true))
                    let exp = campaign(referencing: .bool(false), goalSegmentId: "seg-goal")

                    await service.updateSegments(
                        [goalSegment], referencedBy: [exp], for: mockIdentity.getDistinctId())

                    await expect { await service.isInSegment("seg-goal") }.to(beTrue())
                }
            }

            describe("membership transitions") {
                it("emits entered then exited as conditions change") {
                    mockIdentity.setUserProperty("plan", value: "premium")
                    let premium = segment(
                        "seg-premium",
                        .user(op: "eq", key: "plan", value: .string("premium")))
                    let exp = campaign(
                        referencing: .segment(op: "in", id: "seg-premium", within: nil))

                    await service.updateSegments(
                        [premium], referencedBy: [exp], for: mockIdentity.getDistinctId())
                    await expect { await service.isInSegment("seg-premium") }.to(beTrue())

                    // Condition stops matching; the committed-events stream is
                    // the only mid-session change detector.
                    mockIdentity.setUserProperty("plan", value: "free")
                    let event = TestEventBuilder(name: "plan_changed")
                        .withDistinctId(mockIdentity.getDistinctId())
                        .build()
                    await service.handleCommittedEvent(event)

                    await expect { await service.isInSegment("seg-premium") }.to(beFalse())
                }

                it("ignores committed events captured under a different identity") {
                    mockIdentity.setUserProperty("plan", value: "premium")
                    let premium = segment(
                        "seg-premium",
                        .user(op: "eq", key: "plan", value: .string("premium")))
                    let exp = campaign(
                        referencing: .segment(op: "in", id: "seg-premium", within: nil))

                    await service.updateSegments(
                        [premium], referencedBy: [exp], for: mockIdentity.getDistinctId())

                    mockIdentity.setUserProperty("plan", value: "free")
                    let strangerEvent = TestEventBuilder(name: "plan_changed")
                        .withDistinctId("someone-else")
                        .build()
                    await service.handleCommittedEvent(strangerEvent)

                    // No evaluation ran, membership unchanged
                    await expect { await service.isInSegment("seg-premium") }.to(beTrue())
                }
            }

            describe("deletions") {
                it("clears memberships when the server delivers an empty list") {
                    let s = segment("seg-a", .bool(true))
                    let exp = campaign(referencing: .segment(op: "in", id: "seg-a", within: nil))
                    await service.updateSegments(
                        [s], referencedBy: [exp], for: mockIdentity.getDistinctId())
                    await expect { await service.isInSegment("seg-a") }.to(beTrue())

                    await service.updateSegments(
                        [], referencedBy: [], for: mockIdentity.getDistinctId())

                    await expect { await service.isInSegment("seg-a") }.to(beFalse())
                    await expect { await service.getCurrentMemberships() }.to(beEmpty())
                }
            }

            describe("engine gating") {
                it("fails closed for segments requiring a newer engine") {
                    let future = segment("seg-future", .bool(true), engineMin: "99")
                    let exp = campaign(
                        referencing: .segment(op: "in", id: "seg-future", within: nil))

                    await service.updateSegments(
                        [future], referencedBy: [exp], for: mockIdentity.getDistinctId())

                    await expect { await service.isInSegment("seg-future") }.to(beFalse())
                }
            }

            describe("change stream") {
                it("yields evaluation results with entered segments") {
                    let s = segment("seg-a", .bool(true))
                    let exp = campaign(referencing: .segment(op: "in", id: "seg-a", within: nil))

                    let changes = await service.segmentChanges
                    async let firstChange = changes.first { $0.hasChanges }

                    await service.updateSegments(
                        [s], referencedBy: [exp], for: mockIdentity.getDistinctId())

                    let result = await firstChange
                    expect(result?.entered.map(\.id)).to(equal(["seg-a"]))
                    expect(result?.distinctId).to(equal(mockIdentity.getDistinctId()))
                }
            }
        }
    }
}
