import Foundation
@testable import Nuxie
import FactoryKit

/// Builder for creating test journeys with fluent API
class TestJourneyBuilder {
    private var id: String
    private var campaign: Campaign
    private var distinctId: String
    private var status: JourneyStatus
    private var currentScreenId: String?
    private var context: [String: AnyCodable]
    private var startedAt: Date
    private var completedAt: Date?
    private var exitReason: JourneyExitReason?
    
    init(id: String = "test-journey") {
        self.id = id
        // Create a default campaign
        self.campaign = TestJourneyBuilder.makeCampaign(id: "test-campaign")
        self.distinctId = "test-user"
        self.status = .active
        self.currentScreenId = nil
        self.context = [:]
        self.startedAt = Date()
        self.completedAt = nil
        self.exitReason = nil
    }

    private static func makeCampaign(id: String) -> Campaign {
        let publishedAt = ISO8601DateFormatter().string(from: Date())
        return Campaign(
            id: id,
            name: "Test Campaign",
            flowId: "flow-test",
            flowNumber: 1,
            flowName: nil,
            reentry: .everyTime,
            publishedAt: publishedAt,
            trigger: .event(EventTriggerConfig(eventName: "app_opened", condition: nil)),
            goal: nil,
            exitPolicy: nil,
            conversionAnchor: nil,
            campaignType: nil
        )
    }
    
    func withId(_ id: String) -> TestJourneyBuilder {
        self.id = id
        return self
    }
    
    func withCampaign(_ campaign: Campaign) -> TestJourneyBuilder {
        self.campaign = campaign
        return self
    }
    
    func withCampaignId(_ campaignId: String) -> TestJourneyBuilder {
        self.campaign = TestJourneyBuilder.makeCampaign(id: campaignId)
        return self
    }
    
    func withDistinctId(_ distinctId: String) -> TestJourneyBuilder {
        self.distinctId = distinctId
        return self
    }
    
    func withStatus(_ status: JourneyStatus) -> TestJourneyBuilder {
        self.status = status
        return self
    }
    
    func withCurrentNodeId(_ nodeId: String?) -> TestJourneyBuilder {
        self.currentScreenId = nodeId
        return self
    }
    
    func withContext(_ context: [String: AnyCodable]) -> TestJourneyBuilder {
        self.context = context
        return self
    }
    
    
    func withStartedAt(_ date: Date) -> TestJourneyBuilder {
        self.startedAt = date
        return self
    }
    
    func withCompletedAt(_ date: Date?) -> TestJourneyBuilder {
        self.completedAt = date
        return self
    }
    
    func withExitReason(_ reason: JourneyExitReason?) -> TestJourneyBuilder {
        self.exitReason = reason
        return self
    }
    
    func build() -> Journey {
        let journey = Journey(id: id, campaign: campaign, distinctId: distinctId, now: startedAt)
        journey.status = status
        journey.flowState.currentScreenId = currentScreenId
        journey.context = context
        journey.completedAt = completedAt
        journey.exitReason = exitReason
        journey.updatedAt = Date()
        return journey
    }
}
