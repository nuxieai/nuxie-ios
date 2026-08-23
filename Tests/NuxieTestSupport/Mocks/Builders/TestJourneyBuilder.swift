import Foundation
@_spi(Testing) @testable import Nuxie

/// Builder for creating test journeys with fluent API
class TestJourneyBuilder {
    private var id: String
    private var experience: Experience
    private var distinctId: String
    private var status: JourneyStatus
    private var currentScreenId: String?
    private var context: [String: AnyCodable]
    private var startedAt: Date
    private var completedAt: Date?
    private var exitReason: JourneyExitReason?
    
    init(id: String = "test-journey") {
        self.id = id
        // Create a default experience
        self.experience = TestJourneyBuilder.makeExperience(id: "test-experience")
        self.distinctId = "test-user"
        self.status = .active
        self.currentScreenId = nil
        self.context = [:]
        self.startedAt = Date()
        self.completedAt = nil
        self.exitReason = nil
    }

    private static func makeExperience(id: String) -> Experience {
        let publishedAt = ISO8601DateFormatter().string(from: Date())
        return Experience(
            id: id,
            versionId: "flow-test",
            name: "Test Experience",
            reentry: .everyTime,
            publishedAt: publishedAt,
            trigger: .event(EventTriggerConfig(eventName: "app_opened", condition: nil)),
            goal: nil,
            exitPolicy: nil,
            conversionAnchor: nil,
            experienceType: nil
        )
    }
    
    func withId(_ id: String) -> TestJourneyBuilder {
        self.id = id
        return self
    }
    
    func withExperience(_ experience: Experience) -> TestJourneyBuilder {
        self.experience = experience
        return self
    }
    
    func withExperienceId(_ experienceId: String) -> TestJourneyBuilder {
        self.experience = TestJourneyBuilder.makeExperience(id: experienceId)
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
    
    func buildSnapshot() -> JourneySnapshot {
        var snapshot = JourneySnapshot(
            id: id,
            experience: experience,
            distinctId: distinctId,
            now: startedAt
        )
        snapshot.status = status
        snapshot.executionState.currentScreenId = currentScreenId
        snapshot.context = context
        snapshot.completedAt = completedAt
        snapshot.exitReason = exitReason
        snapshot.updatedAt = Date()
        return snapshot
    }

    func build() -> Journey {
        Journey(snapshot: buildSnapshot())
    }
}
