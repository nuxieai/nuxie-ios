import Quick
import Nimble
@testable import Nuxie
@testable import NuxieTestSupport

final class FeatureServiceTests: AsyncSpec {
    override class func spec() {
        describe("FeatureService") {
            var featureService: FeatureService!
            var mockFactory: MockFactory!
            var mockProfileService: MockProfileService!
            var mockIdentityService: MockIdentityService!
            var mockApi: MockNuxieApi!

            beforeEach {
                mockFactory = MockFactory.shared

                mockProfileService = mockFactory.profileService
                mockIdentityService = mockFactory.identityService
                mockApi = mockFactory.nuxieApi
                featureService = FeatureService(
                    api: mockApi,
                    identity: mockIdentityService,
                    profile: mockProfileService,
                    dateProvider: mockFactory.dateProvider,
                    featureInfo: FeatureInfo(),
                    configProvider: { NuxieConfiguration(apiKey: "test-api-key") }
                )
                mockIdentityService.setDistinctId("customer-123")
            }

            it("prefers purchase-synced access over stale profile cache") {
                let featureId = "premium_export"

                mockProfileService.setProfileResponse(
                    Self.makeProfileResponse(
                        feature: Feature(
                            id: featureId,
                            type: .metered,
                            balance: 0,
                            unlimited: false,
                            nextResetAt: nil,
                            interval: nil,
                            entities: nil
                        )
                    )
                )

                _ = try await mockProfileService.refetchProfile(distinctId: "customer-123")

                await featureService.updateFromPurchase([
                    PurchaseFeature(
                        id: featureId,
                        extId: nil,
                        type: .metered,
                        allowed: true,
                        balance: 5,
                        unlimited: false
                    )
                ])

                let cached = await featureService.getCached(featureId: featureId, entityId: nil)
                let allCached = await featureService.getAllCached()

                expect(cached?.allowed).to(beTrue())
                expect(cached?.balance).to(equal(5))
                expect(allCached[featureId]?.allowed).to(beTrue())
                expect(allCached[featureId]?.balance).to(equal(5))
            }

            it("exposes purchase-synced access even when no profile is cached") {
                let featureId = "plan:team_members"

                await featureService.updateFromPurchase([
                    PurchaseFeature(
                        id: featureId,
                        extId: nil,
                        type: .boolean,
                        allowed: true,
                        balance: nil,
                        unlimited: true
                    )
                ])

                let cached = await featureService.getCached(featureId: featureId, entityId: nil)
                let allCached = await featureService.getAllCached()

                expect(cached?.allowed).to(beTrue())
                expect(cached?.unlimited).to(beTrue())
                expect(allCached[featureId]?.allowed).to(beTrue())
                expect(allCached[featureId]?.unlimited).to(beTrue())
            }

            it("recomputes metered cache overrides for lower required balances") {
                let featureId = "ai_generations"

                await mockApi.setCheckFeatureResponse(
                    FeatureCheckResult(
                        customerId: "customer-123",
                        featureId: featureId,
                        requiredBalance: 10,
                        code: "insufficient_balance",
                        allowed: false,
                        unlimited: false,
                        balance: 5,
                        type: .metered,
                        preview: nil
                    )
                )

                let first = try await featureService.checkWithCache(
                    featureId: featureId,
                    requiredBalance: 10,
                    entityId: nil,
                    forceRefresh: true
                )

                let second = try await featureService.checkWithCache(
                    featureId: featureId,
                    requiredBalance: 1,
                    entityId: nil,
                    forceRefresh: false
                )

                expect(first.allowed).to(beFalse())
                expect(first.balance).to(equal(5))
                expect(second.allowed).to(beTrue())
                expect(second.balance).to(equal(5))
            }
        }
    }

    private static func makeProfileResponse(feature: Feature) -> ProfileResponse {
        ProfileResponse(
            campaigns: [],
            segments: [],
            flows: [],
            userProperties: nil,
            experiments: nil,
            features: [feature],
            journeys: nil
        )
    }
}
