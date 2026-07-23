import Foundation
import Nimble
import Quick

@testable import Nuxie

final class JourneyEventContractTests: QuickSpec {
    override class func spec() {
        describe("canonical journey event contracts") {
            it("includes frozen execution settings on enrollment") {
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
                let campaign = Self.makeCampaign(
                    goal: goal,
                    exitPolicy: ExitPolicy(mode: .onGoal),
                    conversionAnchor: "journey_start"
                )
                let journey = Journey(
                    id: "journey-1",
                    campaign: campaign,
                    distinctId: "user-1"
                )
                journey.conversionAnchorAt = anchorAt
                journey.conversionWindow = 300

                let properties = JourneyEvents.journeyEnrolledProperties(
                    journey: journey,
                    campaign: campaign,
                    triggerRef: "fact-trigger"
                )

                expect(Set(properties.keys)).to(equal(Set([
                    "journey_id", "experience_id", "experience_version", "trigger_ref",
                    "plane", "settings_snapshot",
                ])))
                expect(properties["journey_id"] as? String).to(equal("journey-1"))
                expect(properties["experience_id"] as? String).to(equal("campaign-1"))
                expect(properties["experience_version"] as? String).to(equal("flow-version-1"))
                expect(properties["trigger_ref"] as? String).to(equal("fact-trigger"))
                expect(properties["plane"] as? String).to(equal("device"))

                let settings: [String: Any] = try Self.required(
                    properties["settings_snapshot"] as? [String: Any],
                    "settings_snapshot"
                )
                expect(Set(settings.keys)).to(equal(Set([
                    "goal", "conversion_anchor", "conversion_anchor_at",
                    "goal_window_ends_at", "end_on_goal",
                ])))
                expect(settings["conversion_anchor"] as? String).to(equal("journey_start"))
                expect(settings["conversion_anchor_at"] as? String)
                    .to(equal(Self.iso8601(anchorAt)))
                expect(settings["goal_window_ends_at"] as? String)
                    .to(equal(Self.iso8601(anchorAt.addingTimeInterval(300))))
                expect(settings["end_on_goal"] as? Bool).to(beTrue())
                let goalSnapshot: [String: Any] = try Self.required(
                    settings["goal"] as? [String: Any],
                    "goal"
                )
                let eventFilter: [String: Any] = try Self.required(
                    goalSnapshot["eventFilter"] as? [String: Any],
                    "eventFilter"
                )
                expect(eventFilter["ir_version"] as? Int).to(equal(1))

                let storedEvent = try StoredEvent(
                    name: JourneyEvents.journeyEnrolled,
                    properties: properties,
                    distinctId: "user-1"
                )
                let storedProperties = storedEvent.getPropertiesDict()
                let storedSettings: [String: Any] = try Self.required(
                    storedProperties["settings_snapshot"] as? [String: Any],
                    "stored settings"
                )
                let storedGoal: [String: Any] = try Self.required(
                    storedSettings["goal"] as? [String: Any],
                    "stored goal"
                )
                let storedFilter: [String: Any] = try Self.required(
                    storedGoal["eventFilter"] as? [String: Any],
                    "stored eventFilter"
                )
                expect(storedFilter["ir_version"] as? Int).to(equal(1))
                let storedVersion: NSNumber = try Self.required(
                    storedFilter["ir_version"] as? NSNumber,
                    "stored ir_version"
                )
                expect(CFGetTypeID(storedVersion)).toNot(equal(CFBooleanGetTypeID()))

                let request = EventRequest(
                    event: JourneyEvents.journeyEnrolled,
                    distinctId: "user-1",
                    properties: storedProperties
                )
                let requestData = try JSONEncoder().encode(request)
                let requestObject: [String: Any] = try Self.required(
                    JSONSerialization.jsonObject(with: requestData) as? [String: Any],
                    "request"
                )
                let requestProperties: [String: Any] = try Self.required(
                    requestObject["properties"] as? [String: Any],
                    "request properties"
                )
                let requestSettings: [String: Any] = try Self.required(
                    requestProperties["settings_snapshot"] as? [String: Any],
                    "request settings"
                )
                let requestGoal: [String: Any] = try Self.required(
                    requestSettings["goal"] as? [String: Any],
                    "request goal"
                )
                let requestFilter: [String: Any] = try Self.required(
                    requestGoal["eventFilter"] as? [String: Any],
                    "request eventFilter"
                )
                expect(requestFilter["ir_version"] as? Int).to(equal(1))
                let requestVersion: NSNumber = try Self.required(
                    requestFilter["ir_version"] as? NSNumber,
                    "request ir_version"
                )
                expect(CFGetTypeID(requestVersion)).toNot(equal(CFBooleanGetTypeID()))
                let requestJSON: String = try Self.required(
                    String(data: requestData, encoding: .utf8),
                    "request JSON"
                )
                expect(requestJSON).to(contain("\"ir_version\":1"))
            }

            it("uses exact transition properties and monotonic epochs") {
                let campaign = Self.makeCampaign()
                let journey = Journey(
                    id: "journey-1",
                    campaign: campaign,
                    distinctId: "user-1"
                )

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

                expect(Set(first.keys)).to(equal(Set([
                    "journey_id", "epoch", "to_node", "region", "plane",
                ])))
                expect(first["epoch"] as? Int).to(equal(0))
                expect(first["from_node"]).to(beNil())
                expect(first["to_node"] as? String).to(equal("screen-a"))
                expect(first["region"] as? String).to(equal("device-main"))
                expect(first["plane"] as? String).to(equal("device"))

                expect(Set(second.keys)).to(equal(Set([
                    "journey_id", "epoch", "from_node", "to_node", "region", "plane",
                ])))
                expect(second["epoch"] as? Int).to(equal(1))
                expect(second["from_node"] as? String).to(equal("screen-a"))
                expect(second["to_node"] as? String).to(equal("screen-b"))
            }

            it("uses canonical milestone, converted, and exited envelopes") {
                let at = Date(timeIntervalSince1970: 1_700_000_100)
                let campaign = Self.makeCampaign()
                let journey = Journey(
                    id: "journey-1",
                    campaign: campaign,
                    distinctId: "user-1"
                )

                let milestone = JourneyEvents.journeyMilestoneProperties(
                    journey: journey,
                    milestoneId: "activated"
                )
                expect(milestone as NSDictionary).to(equal([
                    "journey_id": "journey-1",
                    "milestone_id": "activated",
                ] as NSDictionary))

                let converted = JourneyEvents.journeyConvertedProperties(
                    journey: journey,
                    at: at,
                    sourceFactRef: "fact-1"
                )
                expect(converted as NSDictionary).to(equal([
                    "journey_id": "journey-1",
                    "at": Self.iso8601(at),
                    "source_fact_ref": "fact-1",
                ] as NSDictionary))

                let exited = JourneyEvents.journeyExitedProperties(
                    journey: journey,
                    reason: .goalMet,
                    at: at
                )
                expect(exited as NSDictionary).to(equal([
                    "journey_id": "journey-1",
                    "reason": "converted_exit",
                    "at": Self.iso8601(at),
                ] as NSDictionary))
            }
        }
    }

    private enum ContractError: Error {
        case missing(String)
    }

    private static func required<T>(_ value: T?, _ label: String) throws -> T {
        guard let value else { throw ContractError.missing(label) }
        return value
    }

    private static func makeCampaign(
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

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
