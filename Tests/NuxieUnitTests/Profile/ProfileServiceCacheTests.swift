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
                    dateProvider: mockFactory.dateProvider,
                    sleepProvider: mockFactory.sleepProvider
                )
            }

            it("does not return another user's memory-cached profile") {
                mockFactory.identityService.setDistinctId("user-a")
                await mockFactory.nuxieApi.setProfileResponse(Self.makeProfile(campaignId: "campaign-a"))
                _ = try await profileService.refetchProfile(distinctId: "user-a")

                let cached = await profileService.getCachedProfile(distinctId: "user-b")

                expect(cached).to(beNil())
            }

            it("refetches when the requested distinctId differs from the memory cache") {
                mockFactory.identityService.setDistinctId("user-a")
                await mockFactory.nuxieApi.setProfileResponse(Self.makeProfile(campaignId: "campaign-a"))
                let initialFetchCount = await mockFactory.nuxieApi.fetchProfileCallCount
                let first = try await profileService.refetchProfile(distinctId: "user-a")

                mockFactory.identityService.setDistinctId("user-b")
                await mockFactory.nuxieApi.setProfileResponse(Self.makeProfile(campaignId: "campaign-b"))
                let second = try await profileService.refetchProfile(distinctId: "user-b")

                expect(first.campaigns.first?.id).to(equal("campaign-a"))
                expect(second.campaigns.first?.id).to(equal("campaign-b"))
                await expect { await mockFactory.nuxieApi.fetchProfileCallCount }.to(equal(initialFetchCount + 2))
            }
        }
    }

    private static func makeProfile(campaignId: String) -> ProfileResponse {
        let campaign = Campaign(
            id: campaignId,
            name: "Campaign \(campaignId)",
            flowId: "flow-\(campaignId)",
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
            campaignType: nil
        )

        return ProfileResponse(
            campaigns: [campaign],
            segments: [],
            flows: [],
            userProperties: nil,
            experiments: nil,
            features: nil
        )
    }
}
