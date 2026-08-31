import Foundation
import Quick
import Nimble
@testable import Nuxie
@testable import NuxieTestSupport

private actor FeatureCheckFake: FeatureChecking {
    private var response: FeatureCheckResult?
    private var requestCount = 0

    func setResponse(_ response: FeatureCheckResult?) {
        self.response = response
    }

    func recordedRequestCount() -> Int {
        requestCount
    }

    func checkFeature(
        customerId: String,
        featureId: String,
        requiredBalance: Double?,
        entityId: String?
    ) async throws -> FeatureCheckResult {
        requestCount += 1
        guard let response else {
            throw NuxieNetworkError.invalidResponse
        }
        return response
    }
}
private actor ControlledFeatureCheckFake: FeatureChecking {
    private var responseContinuation: CheckedContinuation<FeatureCheckResult, Error>?
    private var startContinuations: [CheckedContinuation<Void, Never>] = []
    private var started = false

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startContinuations.append($0) }
    }

    func resolve(_ result: FeatureCheckResult) {
        responseContinuation?.resume(returning: result)
        responseContinuation = nil
    }

    func checkFeature(
        customerId: String,
        featureId: String,
        requiredBalance: Double?,
        entityId: String?
    ) async throws -> FeatureCheckResult {
        try await withCheckedThrowingContinuation { continuation in
            responseContinuation = continuation
            started = true
            let continuations = startContinuations
            startContinuations.removeAll()
            continuations.forEach { $0.resume() }
        }
    }
}

private actor MultiControlledFeatureCheckFake: FeatureChecking {
    private var continuations: [
        String: CheckedContinuation<FeatureCheckResult, Error>
    ] = [:]
    private var startedEntities: Set<String> = []
    private var startContinuations: [
        String: [CheckedContinuation<Void, Never>]
    ] = [:]

    func waitUntilStarted(entityId: String) async {
        guard !startedEntities.contains(entityId) else { return }
        await withCheckedContinuation {
            startContinuations[entityId, default: []].append($0)
        }
    }

    func resolve(entityId: String, result: FeatureCheckResult) {
        continuations.removeValue(forKey: entityId)?.resume(returning: result)
    }

    func checkFeature(
        customerId: String,
        featureId: String,
        requiredBalance: Double?,
        entityId: String?
    ) async throws -> FeatureCheckResult {
        let key = entityId ?? ""
        return try await withCheckedThrowingContinuation { continuation in
            continuations[key] = continuation
            startedEntities.insert(key)
            startContinuations.removeValue(forKey: key)?.forEach { $0.resume() }
        }
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
            var featureInfo: FeatureInfo!
            var storageURLs: [URL] = []

            beforeEach {
                mockFactory = MockFactory.shared

                mockProfileService = mockFactory.profileService
                mockIdentityService = mockFactory.identityService
                featureCheck = FeatureCheckFake()
                featureInfo = FeatureInfo()
                featureService = FeatureService(
                    api: featureCheck,
                    identity: mockIdentityService,
                    profile: mockProfileService,
                    dateProvider: mockFactory.dateProvider,
                    featureInfo: featureInfo,
                    cacheTTL: 5 * 60
                )
                mockIdentityService.setDistinctId("customer-123")
            }

            afterEach {
                for storageURL in storageURLs {
                    try? FileManager.default.removeItem(at: storageURL)
                }
                storageURLs.removeAll()
            }

            it("keeps transitive credit units separate from requested feature access") {
                await featureService.applyAuthoritativeUse(
                    FeatureCheckResult(
                        customerId: "customer-123",
                        featureId: "credit_wallet",
                        requiredBalance: 1,
                        code: "feature_found",
                        allowed: false,
                        unlimited: false,
                        balance: 8,
                        type: .creditSystem,
                        preview: nil
                    ),
                    requestedFeatureId: "exports",
                    distinctId: "customer-123",
                    entityId: nil
                )

                let requested = await featureService.getCached(
                    featureId: "exports",
                    entityId: nil
                )
                let balanceSource = await featureService.getCached(
                    featureId: "credit_wallet",
                    entityId: nil
                )
                let publishedFeatureInfo = featureInfo!
                let published = await MainActor.run {
                    publishedFeatureInfo.all
                }
                let laterCheck = try await featureService.checkWithCache(
                    featureId: "exports",
                    requiredBalance: 1,
                    entityId: nil,
                    forceRefresh: false
                )
                await featureCheck.setResponse(
                    FeatureCheckResult(
                        customerId: "customer-123",
                        featureId: "credit_wallet",
                        requiredBalance: 2,
                        code: "feature_found",
                        allowed: false,
                        unlimited: false,
                        balance: 8,
                        type: .creditSystem,
                        preview: nil
                    )
                )
                let differentRequiredBalance = try await featureService.checkWithCache(
                    featureId: "exports",
                    requiredBalance: 2,
                    entityId: nil,
                    forceRefresh: false
                )
                let networkRequests = await featureCheck.recordedRequestCount()

                expect(requested?.allowed).to(beFalse())
                expect(requested?.balance).to(beNil())
                expect(requested?.type).to(equal(.metered))
                expect(balanceSource?.allowed).to(beTrue())
                expect(balanceSource?.balance).to(equal(8))
                expect(published["exports"]?.allowed).to(beFalse())
                expect(published["exports"]?.balance).to(beNil())
                expect(published["exports"]?.type).to(equal(.metered))
                expect(published["credit_wallet"]?.allowed).to(beTrue())
                expect(published["credit_wallet"]?.balance).to(equal(8))
                expect(laterCheck.allowed).to(beFalse())
                expect(differentRequiredBalance.allowed).to(beFalse())
                expect(networkRequests).to(equal(1))
            }

            it("reuses an opaque transitive decision only for its exact required balance") {
                await featureService.applyAuthoritativeUse(
                    FeatureCheckResult(
                        customerId: "customer-123",
                        featureId: "credit_wallet",
                        requiredBalance: 2,
                        code: "feature_found",
                        allowed: true,
                        unlimited: false,
                        balance: 8,
                        type: .creditSystem,
                        preview: nil
                    ),
                    requestedFeatureId: "exports",
                    distinctId: "customer-123",
                    entityId: nil
                )
                await featureService.syncFeatureInfo()

                let publishedFeatureInfo = featureInfo!
                let published = await MainActor.run {
                    publishedFeatureInfo.feature("exports")
                }
                let allCached = await featureService.getAllCached()
                let exactRequirement = try await featureService.checkWithCache(
                    featureId: "exports",
                    requiredBalance: 2,
                    entityId: nil,
                    forceRefresh: false
                )
                await featureCheck.setResponse(
                    FeatureCheckResult(
                        customerId: "customer-123",
                        featureId: "credit_wallet",
                        requiredBalance: 1,
                        code: "insufficient_balance",
                        allowed: false,
                        unlimited: false,
                        balance: 8,
                        type: .creditSystem,
                        preview: nil
                    )
                )
                let defaultRequirement = try await featureService.checkWithCache(
                    featureId: "exports",
                    requiredBalance: nil,
                    entityId: nil,
                    forceRefresh: false
                )
                let networkRequests = await featureCheck.recordedRequestCount()

                expect(published?.allowed).to(beTrue())
                expect(published?.balance).to(beNil())
                expect(allCached["exports"]?.allowed).to(beTrue())
                expect(allCached["exports"]?.balance).to(beNil())
                expect(exactRequirement.allowed).to(beTrue())
                expect(exactRequirement.balance).to(beNil())
                expect(defaultRequirement.allowed).to(beFalse())
                expect(networkRequests).to(equal(1))
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
                ], distinctId: "customer-123")

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
                ], distinctId: "customer-123")

                let cached = await featureService.getCached(featureId: featureId, entityId: nil)
                let allCached = await featureService.getAllCached()

                expect(cached?.allowed).to(beTrue())
                expect(cached?.unlimited).to(beTrue())
                expect(allCached[featureId]?.allowed).to(beTrue())
                expect(allCached[featureId]?.unlimited).to(beTrue())
            }

            it("returns a completed entity check while a newer check is still pending") {
                let featureId = "entity_exports"
                let controlledCheck = MultiControlledFeatureCheckFake()
                let isolatedService = FeatureService(
                    api: controlledCheck,
                    identity: mockIdentityService,
                    profile: mockProfileService,
                    dateProvider: mockFactory.dateProvider,
                    featureInfo: FeatureInfo(),
                    cacheTTL: 5 * 60
                )
                mockProfileService.setProfileResponse(
                    Self.makeProfileResponse(
                        feature: Feature(
                            id: featureId,
                            type: .metered,
                            balance: nil,
                            unlimited: false,
                            nextResetAt: nil,
                            interval: nil,
                            entities: [
                                "entity-a": EntityBalance(balance: 0),
                                "entity-b": EntityBalance(balance: 0),
                            ]
                        )
                    )
                )
                _ = try await mockProfileService.refetchProfile(
                    distinctId: "customer-123"
                )

                let first = Task {
                    try await isolatedService.checkWithCache(
                        featureId: featureId,
                        requiredBalance: 1,
                        entityId: "entity-a",
                        forceRefresh: true
                    )
                }
                await controlledCheck.waitUntilStarted(entityId: "entity-a")
                let second = Task {
                    try await isolatedService.checkWithCache(
                        featureId: featureId,
                        requiredBalance: 1,
                        entityId: "entity-b",
                        forceRefresh: true
                    )
                }
                await controlledCheck.waitUntilStarted(entityId: "entity-b")

                await controlledCheck.resolve(
                    entityId: "entity-a",
                    result: FeatureCheckResult(
                        customerId: "customer-123",
                        featureId: featureId,
                        requiredBalance: 1,
                        code: "ok",
                        allowed: true,
                        unlimited: false,
                        balance: 3,
                        type: .metered,
                        preview: nil
                    )
                )
                let firstResult = try await first.value
                expect(firstResult.allowed).to(beTrue())
                expect(firstResult.balance).to(equal(3))

                await controlledCheck.resolve(
                    entityId: "entity-b",
                    result: FeatureCheckResult(
                        customerId: "customer-123",
                        featureId: featureId,
                        requiredBalance: 1,
                        code: "ok",
                        allowed: true,
                        unlimited: false,
                        balance: 2,
                        type: .metered,
                        preview: nil
                    )
                )
                _ = try await second.value
            }

            it("cancels an in-flight check across an A to B to A identity cycle") {
                let controlledCheck = ControlledFeatureCheckFake()
                let isolatedService = FeatureService(
                    api: controlledCheck,
                    identity: mockIdentityService,
                    profile: mockProfileService,
                    dateProvider: mockFactory.dateProvider,
                    featureInfo: FeatureInfo(),
                    cacheTTL: 5 * 60
                )
                let checkTask = Task {
                    try await isolatedService.checkWithCache(
                        featureId: "private_export",
                        requiredBalance: 1,
                        entityId: nil,
                        forceRefresh: true
                    )
                }
                await controlledCheck.waitUntilStarted()

                mockIdentityService.setDistinctId("customer-b")
                await isolatedService.handleUserChange(
                    from: "customer-123",
                    to: "customer-b"
                )
                mockIdentityService.setDistinctId("customer-123")
                await isolatedService.handleUserChange(
                    from: "customer-b",
                    to: "customer-123"
                )
                await controlledCheck.resolve(
                    FeatureCheckResult(
                        customerId: "customer-123",
                        featureId: "private_export",
                        requiredBalance: 1,
                        code: "ok",
                        allowed: true,
                        unlimited: true,
                        balance: nil,
                        type: .boolean,
                        preview: nil
                    )
                )

                do {
                    _ = try await checkTask.value
                    fail("Expected the previous customer's check to be cancelled")
                } catch is CancellationError {
                    // Expected: customer-scoped results never cross identify/reset.
                }
                let cached = await isolatedService.getCached(
                    featureId: "private_export",
                    entityId: nil
                )
                expect(cached).to(beNil())
            }

            it("fails closed on an immediate feature read after identity changes") {
                let featureId = "customer_a_private_feature"
                await featureService.updateFromPurchase([
                    PurchaseFeature(
                        id: featureId,
                        extId: nil,
                        type: .boolean,
                        allowed: true,
                        balance: nil,
                        unlimited: true
                    ),
                ], distinctId: "customer-123")
                let publishedFeatureInfo = featureInfo!
                let allowedForCustomerA = await MainActor.run {
                    publishedFeatureInfo.isAllowed(featureId)
                }
                expect(allowedForCustomerA).to(beTrue())

                // IdentityService changes synchronously. The serialized user
                // transition has not reached FeatureService yet.
                mockIdentityService.setDistinctId("customer-b")

                let accessForCustomerB = await featureService.getCached(
                    featureId: featureId,
                    entityId: nil
                )
                let publishedForCustomerB = await MainActor.run {
                    publishedFeatureInfo.feature(featureId)
                }
                expect(accessForCustomerB).to(beNil())
                expect(publishedForCustomerB).to(beNil())
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
