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
                    experiences: mockFactory.experienceService,
                    eventLog: mockFactory.eventLog,
                    dateProvider: mockFactory.dateProvider,
                    sleepProvider: mockFactory.sleepProvider,
                    localeProvider: ConfigurationLocaleIdentifierProvider(
                        configuredLocale: { "en_US" }
                    )
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

                expect(first.experiences.first?.experienceId).to(equal("experience-a"))
                expect(second.experiences.first?.experienceId).to(equal("experience-b"))
                await expect { await mockFactory.nuxieApi.fetchProfileCallCount }.to(equal(initialFetchCount + 2))
            }

            it("uses its injected locale without SDK singleton setup") {
                mockFactory.identityService.setDistinctId("locale-user")

                _ = try await profileService.refetchProfile(distinctId: "locale-user")

                await expect { await mockFactory.nuxieApi.lastProfileLocale }
                    .to(equal("en_US"))
            }
        }
    }

    private static func makeProfile(experienceId: String) -> ProfileResponse {
        let experience = Experience(
            id: experienceId,
            versionId: "flow-\(experienceId)",
            name: "Experience \(experienceId)",
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
            experiences: [experience.remote],
            segments: [],
            pinnedVersions: [],
            assetBaseUrl: "https://assets.nuxie.ai/",
            userProperties: nil,
            experiments: nil,
            features: nil
        )
    }
}
