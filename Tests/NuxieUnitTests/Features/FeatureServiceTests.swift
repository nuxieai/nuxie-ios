import Foundation
import Quick
import Nimble
@testable import Nuxie
@testable import NuxieTestSupport

private actor FeatureCheckFake: FeatureChecking {
    private var response: FeatureCheckResult?

    func setResponse(_ response: FeatureCheckResult?) {
        self.response = response
    }

    func checkFeature(
        customerId: String,
        featureId: String,
        requiredBalance: Int?,
        entityId: String?
    ) async throws -> FeatureCheckResult {
        guard let response else {
            throw NuxieNetworkError.invalidResponse
        }
        return response
    }
}

final class FeatureServiceTests: AsyncSpec {
    override class func spec() {
        describe("FeatureService") {
            var featureService: FeatureService!
            var mockFactory: MockFactory!
            var mockProfileService: MockProfileService!
            var mockIdentityService: MockIdentityService!
            var featureCheck: FeatureCheckFake!

            beforeEach {
                mockFactory = MockFactory.shared

                mockProfileService = mockFactory.profileService
                mockIdentityService = mockFactory.identityService
                featureCheck = FeatureCheckFake()
                featureService = FeatureService(
                    api: featureCheck,
                    identity: mockIdentityService,
                    profile: mockProfileService,
                    dateProvider: mockFactory.dateProvider,
                    featureInfo: FeatureInfo(),
                    cacheTTL: 5 * 60
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

            it("applies a signed Product mapping locally once per transaction") {
                let grants = [
                    StoreProduct.LocalEntitlementGrant(
                        featureId: "feature_export",
                        featureExternalId: "exports",
                        allowanceType: "boolean",
                        allowance: nil
                    ),
                    StoreProduct.LocalEntitlementGrant(
                        featureId: "feature_credits",
                        featureExternalId: "credits",
                        allowanceType: "credit_system",
                        allowance: 4
                    ),
                ]

                await featureService.applyLocalPurchase(
                    grants: grants,
                    transactionId: "transaction-1",
                    observedAt: Date()
                )
                await featureService.applyLocalPurchase(
                    grants: grants,
                    transactionId: "transaction-1",
                    observedAt: Date()
                )

                let exports = await featureService.getCached(featureId: "exports", entityId: nil)
                let credits = await featureService.getCached(featureId: "credits", entityId: nil)
                expect(exports?.allowed).to(beTrue())
                expect(credits?.balance).to(equal(4))
                expect(credits?.type).to(equal(.creditSystem))
            }

            it("keeps verified purchase access after the real-time cache TTL") {
                let featureId = "offline_export"
                await featureService.applyLocalPurchase(
                    grants: [
                        StoreProduct.LocalEntitlementGrant(
                            featureId: featureId,
                            featureExternalId: nil,
                            allowanceType: "boolean",
                            allowance: nil
                        )
                    ],
                    transactionId: "transaction-offline",
                    observedAt: mockFactory.dateProvider.now()
                )

                mockFactory.dateProvider.advance(by: 60 * 60)

                let access = await featureService.getCached(
                    featureId: featureId,
                    entityId: nil
                )
                expect(access?.allowed).to(beTrue())
            }

            it("treats a null allowance type as boolean access") {
                await featureService.applyLocalPurchase(
                    grants: [
                        StoreProduct.LocalEntitlementGrant(
                            featureId: "feature_boolean",
                            featureExternalId: "boolean_access",
                            allowanceType: nil,
                            allowance: nil
                        )
                    ],
                    transactionId: "transaction-null-allowance",
                    observedAt: Date()
                )

                let access = await featureService.getCached(
                    featureId: "boolean_access",
                    entityId: nil
                )
                expect(access?.allowed).to(beTrue())
                expect(access?.unlimited).to(beFalse())
                expect(access?.type).to(equal(.boolean))
                expect(access?.balance).to(beNil())
            }

            it("recomputes metered cache overrides for lower required balances") {
                let featureId = "ai_generations"

                await featureCheck.setResponse(
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
            segments: [],
            userProperties: nil,
            experiments: nil,
            features: [feature]
        )
    }
}
