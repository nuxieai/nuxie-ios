import Foundation
import XCTest
@testable import Nuxie

final class JourneyEventContractTests: XCTestCase {
    func testEnrolledCarriesFrozenExecutionSettings() throws {
        let anchorAt = Date(timeIntervalSince1970: 1_700_000_000)
        let goal = GoalConfig(
            kind: .event,
            eventName: "purchase",
            eventFilter: IREnvelope(
                ir_version: 1,
                engine_min: nil,
                compiled_at: nil,
                expr: .bool(true)
            ),
            window: 300
        )
        let campaign = makeCampaign(
            goal: goal,
            exitPolicy: ExitPolicy(mode: .onGoal),
            conversionAnchor: "journey_start"
        )
        let journey = Journey(id: "journey-1", campaign: campaign, distinctId: "user-1")
        journey.conversionAnchorAt = anchorAt
        journey.conversionWindow = 300

        let properties = JourneyEvents.journeyEnrolledProperties(
            journey: journey,
            campaign: campaign,
            triggerRef: "fact-trigger"
        )

        XCTAssertEqual(Set(properties.keys), [
            "journey_id", "experience_id", "experience_version", "trigger_ref", "plane", "settings_snapshot",
        ])
        XCTAssertEqual(properties["journey_id"] as? String, "journey-1")
        XCTAssertEqual(properties["experience_id"] as? String, "campaign-1")
        XCTAssertEqual(properties["experience_version"] as? String, "flow-version-1")
        XCTAssertEqual(properties["trigger_ref"] as? String, "fact-trigger")
        XCTAssertEqual(properties["plane"] as? String, "device")

        let settings = try XCTUnwrap(properties["settings_snapshot"] as? [String: Any])
        XCTAssertEqual(Set(settings.keys), [
            "goal", "conversion_anchor", "conversion_anchor_at", "goal_window_ends_at", "end_on_goal",
        ])
        XCTAssertEqual(settings["conversion_anchor"] as? String, "journey_start")
        XCTAssertEqual(settings["conversion_anchor_at"] as? String, iso8601(anchorAt))
        XCTAssertEqual(settings["goal_window_ends_at"] as? String, iso8601(anchorAt.addingTimeInterval(300)))
        XCTAssertEqual(settings["end_on_goal"] as? Bool, true)
        let goalSnapshot = try XCTUnwrap(settings["goal"] as? [String: Any])
        let eventFilter = try XCTUnwrap(goalSnapshot["eventFilter"] as? [String: Any])
        XCTAssertEqual(eventFilter["ir_version"] as? Int, 1)

        let storedEvent = try StoredEvent(
            name: JourneyEvents.journeyEnrolled,
            properties: properties,
            distinctId: "user-1"
        )
        let storedProperties = storedEvent.getPropertiesDict()
        let storedSettings = try XCTUnwrap(storedProperties["settings_snapshot"] as? [String: Any])
        let storedGoal = try XCTUnwrap(storedSettings["goal"] as? [String: Any])
        let storedFilter = try XCTUnwrap(storedGoal["eventFilter"] as? [String: Any])
        XCTAssertEqual(storedFilter["ir_version"] as? Int, 1)
        let storedVersion = try XCTUnwrap(storedFilter["ir_version"] as? NSNumber)
        XCTAssertNotEqual(CFGetTypeID(storedVersion), CFBooleanGetTypeID())

        let request = EventRequest(
            event: JourneyEvents.journeyEnrolled,
            distinctId: "user-1",
            properties: storedProperties
        )
        let requestData = try JSONEncoder().encode(request)
        let requestObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: requestData) as? [String: Any]
        )
        let requestProperties = try XCTUnwrap(requestObject["properties"] as? [String: Any])
        let requestSettings = try XCTUnwrap(requestProperties["settings_snapshot"] as? [String: Any])
        let requestGoal = try XCTUnwrap(requestSettings["goal"] as? [String: Any])
        let requestFilter = try XCTUnwrap(requestGoal["eventFilter"] as? [String: Any])
        XCTAssertEqual(requestFilter["ir_version"] as? Int, 1)
        let requestVersion = try XCTUnwrap(requestFilter["ir_version"] as? NSNumber)
        XCTAssertNotEqual(CFGetTypeID(requestVersion), CFBooleanGetTypeID())
        XCTAssertTrue(
            try XCTUnwrap(String(data: requestData, encoding: .utf8))
                .contains("\"ir_version\":1")
        )
    }

    func testTransitionsHaveExactPropertiesAndMonotonicEpochs() {
        let campaign = makeCampaign()
        let journey = Journey(id: "journey-1", campaign: campaign, distinctId: "user-1")

        let first = JourneyEvents.journeyTransitionProperties(
            journey: journey,
            fromNode: nil,
            toNode: "screen-a"
        )
        let second = JourneyEvents.journeyTransitionProperties(
            journey: journey,
            fromNode: "screen-a",
            toNode: "screen-b"
        )

        XCTAssertEqual(Set(first.keys), ["journey_id", "epoch", "to_node", "region", "plane"])
        XCTAssertEqual(first["epoch"] as? Int, 0)
        XCTAssertNil(first["from_node"])
        XCTAssertEqual(first["to_node"] as? String, "screen-a")
        XCTAssertEqual(first["region"] as? String, "device-main")
        XCTAssertEqual(first["plane"] as? String, "device")

        XCTAssertEqual(Set(second.keys), ["journey_id", "epoch", "from_node", "to_node", "region", "plane"])
        XCTAssertEqual(second["epoch"] as? Int, 1)
        XCTAssertEqual(second["from_node"] as? String, "screen-a")
        XCTAssertEqual(second["to_node"] as? String, "screen-b")
    }

    func testMilestoneConvertedAndExitedUseCanonicalEnvelopes() {
        let at = Date(timeIntervalSince1970: 1_700_000_100)
        let campaign = makeCampaign()
        let journey = Journey(id: "journey-1", campaign: campaign, distinctId: "user-1")

        let milestone = JourneyEvents.journeyMilestoneProperties(journey: journey, milestoneId: "activated")
        XCTAssertEqual(milestone as NSDictionary, [
            "journey_id": "journey-1",
            "milestone_id": "activated",
        ] as NSDictionary)

        let converted = JourneyEvents.journeyConvertedProperties(
            journey: journey,
            at: at,
            sourceFactRef: "fact-1"
        )
        XCTAssertEqual(converted as NSDictionary, [
            "journey_id": "journey-1",
            "at": iso8601(at),
            "source_fact_ref": "fact-1",
        ] as NSDictionary)

        let exited = JourneyEvents.journeyExitedProperties(journey: journey, reason: .goalMet, at: at)
        XCTAssertEqual(exited as NSDictionary, [
            "journey_id": "journey-1",
            "reason": "converted_exit",
            "at": iso8601(at),
        ] as NSDictionary)
    }

    private func makeCampaign(
        goal: GoalConfig? = nil,
        exitPolicy: ExitPolicy? = nil,
        conversionAnchor: String? = nil
    ) -> Campaign {
        Campaign(
            id: "campaign-1",
            name: "Campaign",
            flowId: "flow-version-1",
            flowNumber: 1,
            flowName: nil,
            reentry: .everyTime,
            publishedAt: "2026-01-01T00:00:00Z",
            trigger: .event(EventTriggerConfig(eventName: "app_opened", condition: nil)),
            goal: goal,
            exitPolicy: exitPolicy,
            conversionAnchor: conversionAnchor,
            campaignType: nil
        )
    }

    private func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
