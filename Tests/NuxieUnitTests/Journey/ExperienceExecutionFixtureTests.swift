import Foundation
import Nimble
import Quick

@testable import Nuxie

final class ExperienceExecutionFixtureTests: AsyncSpec {
    override class func spec() {
        describe("E1 shared fixtures") {
            it("produces exact ordered transition facts") {
                let fixture = try Self.loadObject("journeys/transitions/basic.json")
                let timeline: [[String: Any]] = try Self.required(
                    fixture["timeline"] as? [[String: Any]],
                    "timeline"
                )
                let expected: [[String: Any]] = try Self.required(
                    fixture["expected"] as? [[String: Any]],
                    "expected"
                )
                let journeyId: String = try Self.required(
                    fixture["journeyId"] as? String,
                    "journeyId"
                )
                let journey = Journey(
                    id: journeyId,
                    campaign: Self.makeCampaign(),
                    distinctId: "user-1"
                )

                let actual = timeline.map { step -> [String: Any] in
                    let fromNode = step["fromNode"] as? String
                    let toNode = step["toNode"] as! String
                    return [
                        "event": JourneyEvents.journeyTransition,
                        "properties": JourneyEvents.journeyTransitionProperties(
                            journey: journey,
                            fromNode: fromNode,
                            toNode: toNode
                        ),
                    ]
                }

                expect(actual as NSArray).to(equal(expected as NSArray))
            }

            it("mirrors the server seed timeline") {
                let fixture = try Self.loadObject("segments/seed-mirror/server-mode.json")
                let distinctId: String = try Self.required(
                    fixture["distinctId"] as? String,
                    "distinctId"
                )
                let definitions: [[String: Any]] = try Self.required(
                    fixture["definitions"] as? [[String: Any]],
                    "definitions"
                )
                let timeline: [[String: Any]] = try Self.required(
                    fixture["timeline"] as? [[String: Any]],
                    "timeline"
                )
                let service = SegmentService()
                let segments = definitions.map { definition in
                    Segment(
                        id: definition["id"] as! String,
                        name: definition["name"] as! String,
                        condition: IREnvelope(
                            ir_version: 1,
                            engine_min: nil,
                            compiled_at: nil,
                            expr: .bool(true)
                        ),
                        evaluation: .server
                    )
                }
                await service.updateSegments(segments, for: distinctId)

                for step in timeline {
                    let generation = (step["generation"] as! NSNumber).uint64Value
                    let seed: SegmentMembershipSeed?
                    if let seedObject = step["seed"] as? [String: Any] {
                        let decoder = JSONDecoder()
                        decoder.dateDecodingStrategy = .iso8601
                        seed = try decoder.decode(
                            SegmentMembershipSeed.self,
                            from: JSONSerialization.data(withJSONObject: seedObject)
                        )
                    } else {
                        seed = nil
                    }
                    let result = await service.applySeed(
                        seed,
                        generation: generation,
                        distinctId: distinctId
                    )
                    let memberships = await service.getCurrentMemberships()
                    expect(memberships.map(\.segmentId))
                        .to(equal(step["expectedMembershipIds"] as? [String]))
                    expect(result?.entered.map(\.id) ?? [])
                        .to(equal(step["expectedEnteredIds"] as? [String]))
                    expect(result?.exited.map(\.id) ?? [])
                        .to(equal(step["expectedExitedIds"] as? [String]))
                }

                await service.clearSegments(for: distinctId)
            }

            it("decodes down-fact and golden-vocabulary fixtures") {
                let downFactFixture = try Self.loadObject("events/down-facts/converted.json")
                let responseObject: [String: Any] = try Self.required(
                    downFactFixture["response"] as? [String: Any],
                    "response"
                )
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let response = try decoder.decode(
                    EventResponse.self,
                    from: JSONSerialization.data(withJSONObject: responseObject)
                )
                expect(response.facts?.map(\.id))
                    .to(equal(["fact-converted-1", "fact-converted-1"]))
                expect(response.facts?.map(\.event)).to(equal([.converted, .converted]))

                let golden = try Self.loadObject("golden-journey/basic.json")
                expect(golden["events"] as? [String]).to(equal([
                    JourneyEvents.journeyEnrolled,
                    JourneyEvents.journeyTransition,
                    JourneyEvents.journeyMilestone,
                    JourneyEvents.journeyConverted,
                    JourneyEvents.journeyExited,
                ]))
            }
        }
    }

    private enum FixtureError: Error {
        case missing(String)
    }

    private static func required<T>(_ value: T?, _ label: String) throws -> T {
        guard let value else { throw FixtureError.missing(label) }
        return value
    }

    private static func loadObject(_ path: String) throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("fixtures/\(path)"))
        return try required(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
            path
        )
    }

    private static func makeCampaign() -> Campaign {
        Campaign(
            id: "campaign-1",
            name: "Campaign",
            flowId: "flow-version-1",
            flowNumber: 1,
            flowName: nil,
            reentry: .everyTime,
            publishedAt: "2026-01-01T00:00:00Z",
            trigger: .event(EventTriggerConfig(eventName: "app_opened", condition: nil)),
            goal: nil,
            exitPolicy: nil,
            conversionAnchor: nil,
            campaignType: nil
        )
    }
}
