import Quick
import Nimble
@testable import Nuxie
@testable import NuxieTestSupport

final class ProfileServiceCacheTests: AsyncSpec {
    override class func spec() {
        describe("ProfileService cache identity checks") {
            var mockFactory: MockFactory!
            var profileService: ProfileService!

            beforeEach {
                mockFactory = MockFactory.shared
                profileService = ProfileService(
                    cache: InMemoryCachedProfileStore(ttl: nil),
                    identity: mockFactory.identityService,
                    api: mockFactory.nuxieApi,
                    segments: mockFactory.segmentService,
                    flows: mockFactory.flowService,
                    eventLog: mockFactory.eventLog,
                    dateProvider: mockFactory.dateProvider,
                    sleepProvider: mockFactory.sleepProvider
                )
            }

            it("does not return another user's memory-cached profile") {
                mockFactory.identityService.setDistinctId("user-a")
                await mockFactory.nuxieApi.setProfileResponse(Self.makeProfile(experienceId: "experience-a"))
                _ = try await profileService.refetchProfile(distinctId: "user-a")

                let cached = await profileService.getCachedProfile(distinctId: "user-b")

                expect(cached).to(beNil())
            }

            it("refetches when the requested distinctId differs from the memory cache") {
                mockFactory.identityService.setDistinctId("user-a")
                await mockFactory.nuxieApi.setProfileResponse(Self.makeProfile(experienceId: "experience-a"))
                let initialFetchCount = await mockFactory.nuxieApi.fetchProfileCallCount
                let first = try await profileService.refetchProfile(distinctId: "user-a")

                mockFactory.identityService.setDistinctId("user-b")
                await mockFactory.nuxieApi.setProfileResponse(Self.makeProfile(experienceId: "experience-b"))
                let second = try await profileService.refetchProfile(distinctId: "user-b")

                expect(first.experiences.first?.id).to(equal("experience-a"))
                expect(second.experiences.first?.id).to(equal("experience-b"))
                await expect { await mockFactory.nuxieApi.fetchProfileCallCount }.to(equal(initialFetchCount + 2))
            }
        }
    }

    private static func makeProfile(experienceId: String) -> ProfileResponse {
        let experience = Experience(
            id: experienceId,
            name: "Experience \(experienceId)",
            flowId: "flow-\(experienceId)",
            flowNumber: 1,
            flowName: nil,
            reentry: .everyTime,
            publishedAt: "2024-01-01T00:00:00Z",
            trigger: .event(EventTriggerConfig(
                eventName: "test_event",
                condition: IREnvelope(
                    ir_version: 1,
                    engine_min: nil,
                    compiled_at: nil,
                    expr: .bool(true)
                )
            )),
            goal: nil,
            exitPolicy: nil,
            conversionAnchor: nil,
            experienceType: nil
        )

        return ProfileResponse(
            experiences: [experience],
            segments: [],
            pinnedVersions: [],
            userProperties: nil,
            experiments: nil,
            features: nil
        )
    }
}
