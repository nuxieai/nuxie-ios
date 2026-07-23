import Foundation
import XCTest
@testable import Nuxie

final class ExperienceExecutionFixtureTests: XCTestCase {
    func testTransitionFixtureProducesOrderedExactFacts() throws {
        let fixture = try loadObject("journeys/transitions/basic.json")
        let timeline = try XCTUnwrap(fixture["timeline"] as? [[String: Any]])
        let expected = try XCTUnwrap(fixture["expected"] as? [[String: Any]])
        let journeyId = try XCTUnwrap(fixture["journeyId"] as? String)
        let journey = Journey(id: journeyId, campaign: makeCampaign(), distinctId: "user-1")

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

        XCTAssertEqual(actual as NSArray, expected as NSArray)
    }

    func testServerSeedMirrorFixture() async throws {
        let fixture = try loadObject("segments/seed-mirror/server-mode.json")
        let distinctId = try XCTUnwrap(fixture["distinctId"] as? String)
        let definitions = try XCTUnwrap(fixture["definitions"] as? [[String: Any]])
        let timeline = try XCTUnwrap(fixture["timeline"] as? [[String: Any]])
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
            let result = await service.applySeed(seed, generation: generation, distinctId: distinctId)
            let memberships = await service.getCurrentMemberships()
            XCTAssertEqual(
                memberships.map(\.segmentId),
                step["expectedMembershipIds"] as? [String]
            )
            XCTAssertEqual(
                result?.entered.map(\.id) ?? [],
                step["expectedEnteredIds"] as? [String]
            )
            XCTAssertEqual(
                result?.exited.map(\.id) ?? [],
                step["expectedExitedIds"] as? [String]
            )
        }

        await service.clearSegments(for: distinctId)
    }

    func testDownFactAndGoldenVocabularyFixturesDecode() throws {
        let downFactFixture = try loadObject("events/down-facts/converted.json")
        let responseObject = try XCTUnwrap(downFactFixture["response"] as? [String: Any])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(
            EventResponse.self,
            from: JSONSerialization.data(withJSONObject: responseObject)
        )
        XCTAssertEqual(response.facts?.map(\.id), ["fact-converted-1", "fact-converted-1"])
        XCTAssertEqual(response.facts?.map(\.event), [.converted, .converted])

        let golden = try loadObject("golden-journey/basic.json")
        XCTAssertEqual(golden["events"] as? [String], [
            JourneyEvents.journeyEnrolled,
            JourneyEvents.journeyTransition,
            JourneyEvents.journeyMilestone,
            JourneyEvents.journeyConverted,
            JourneyEvents.journeyExited,
        ])
    }

    private func loadObject(_ path: String) throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("fixtures/\(path)"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func makeCampaign() -> Campaign {
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
