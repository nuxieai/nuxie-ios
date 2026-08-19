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
        requiredBalance: Int?,
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
        requiredBalance: Int?,
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
                    transactionId: "transaction-1"
                )
                await featureService.applyLocalPurchase(
                    grants: grants,
                    transactionId: "transaction-1"
                )

                let exports = await featureService.getCached(featureId: "exports", entityId: nil)
                let credits = await featureService.getCached(featureId: "credits", entityId: nil)
                expect(exports?.allowed).to(beTrue())
                expect(credits?.balance).to(equal(4))
                expect(credits?.type).to(equal(.creditSystem))
            }

            it("allows a later callback to enrich an empty transaction mapping") {
                await featureService.applyLocalPurchase(
                    grants: [],
                    transactionId: "transaction-race"
                )
                await featureService.applyLocalPurchase(
                    grants: [
                        StoreProduct.LocalEntitlementGrant(
                            featureId: "feature_export",
                            featureExternalId: "exports",
                            allowanceType: "boolean",
                            allowance: nil
                        )
                    ],
                    transactionId: "transaction-race"
                )

                let access = await featureService.getCached(
                    featureId: "exports",
                    entityId: nil
                )
                expect(access?.allowed).to(beTrue())
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
                    transactionId: "transaction-offline"
                )

                mockFactory.dateProvider.advance(by: 60 * 60)

                let access = await featureService.getCached(
                    featureId: featureId,
                    entityId: nil
                )
                expect(access?.allowed).to(beTrue())
            }

            it("lets a verified purchase replace an earlier real-time denial") {
                let featureId = "realtime_denied_export"
                await featureCheck.setResponse(
                    FeatureCheckResult(
                        customerId: "customer-123",
                        featureId: featureId,
                        requiredBalance: 1,
                        code: "not_entitled",
                        allowed: false,
                        unlimited: false,
                        balance: nil,
                        type: .boolean,
                        preview: nil
                    )
                )
                _ = try await featureService.check(
                    featureId: featureId,
                    requiredBalance: nil,
                    entityId: nil
                )

                await featureService.applyLocalPurchase(
                    grants: [
                        StoreProduct.LocalEntitlementGrant(
                            featureId: featureId,
                            featureExternalId: nil,
                            allowanceType: "boolean",
                            allowance: nil
                        )
                    ],
                    transactionId: "transaction-after-denial"
                )

                let access = await featureService.getCached(
                    featureId: featureId,
                    entityId: nil
                )
                expect(access?.allowed).to(beTrue())
            }

            it("does not let an in-flight denial erase a verified purchase") {
                let featureId = "inflight_denied_export"
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
                        featureId: featureId,
                        requiredBalance: 1,
                        entityId: nil,
                        forceRefresh: true
                    )
                }
                await controlledCheck.waitUntilStarted()

                await isolatedService.applyLocalPurchase(
                    grants: [
                        StoreProduct.LocalEntitlementGrant(
                            featureId: featureId,
                            featureExternalId: nil,
                            allowanceType: "boolean",
                            allowance: nil
                        )
                    ],
                    transactionId: "transaction-during-check"
                )
                await controlledCheck.resolve(
                    FeatureCheckResult(
                        customerId: "customer-123",
                        featureId: featureId,
                        requiredBalance: 1,
                        code: "not_entitled",
                        allowed: false,
                        unlimited: false,
                        balance: nil,
                        type: .boolean,
                        preview: nil
                    )
                )

                let returned = try await checkTask.value
                let cached = await isolatedService.getCached(
                    featureId: featureId,
                    entityId: nil
                )
                expect(returned.allowed).to(beTrue())
                expect(cached?.allowed).to(beTrue())
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

            it("cancels a remote allow that completes after revocation") {
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
                    try await isolatedService.check(
                        featureId: "revoked_remote_export",
                        requiredBalance: nil,
                        entityId: nil
                    )
                }
                await controlledCheck.waitUntilStarted()

                let grants = [StoreProduct.LocalEntitlementGrant(
                    featureId: "revoked_remote_export",
                    featureExternalId: nil,
                    allowanceType: "boolean",
                    allowance: nil
                )]
                await isolatedService.removeLocalPurchase(
                    transactionId: "revoked-before-remote-response",
                    grants: grants
                )
                await controlledCheck.resolve(
                    FeatureCheckResult(
                        customerId: "customer-123",
                        featureId: "revoked_remote_export",
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
                    fail("Expected the superseded remote result to be cancelled")
                } catch is CancellationError {
                    // Expected: the committed revocation is newer.
                }
                let cached = await isolatedService.getCached(
                    featureId: "revoked_remote_export",
                    entityId: nil
                )
                expect(cached?.allowed).to(beFalse())
            }

            it("denies revoked purchase access immediately") {
                let featureId = "revoked_export"
                await featureService.applyLocalPurchase(
                    grants: [
                        StoreProduct.LocalEntitlementGrant(
                            featureId: featureId,
                            featureExternalId: nil,
                            allowanceType: "boolean",
                            allowance: nil
                        )
                    ],
                    transactionId: "transaction-revoked"
                )

                await featureService.removeLocalPurchase(
                    transactionId: "transaction-revoked"
                )

                let access = await featureService.getCached(
                    featureId: featureId,
                    entityId: nil
                )
                expect(access?.allowed).to(beFalse())
            }

            it("keeps revoked access denied over an older allowed profile") {
                let featureId = "revoked_profile_export"
                mockProfileService.setProfileResponse(
                    Self.makeProfileResponse(
                        feature: Feature(
                            id: featureId,
                            type: .boolean,
                            balance: nil,
                            unlimited: true,
                            nextResetAt: nil,
                            interval: nil,
                            entities: nil
                        )
                    )
                )
                _ = try await mockProfileService.refetchProfile(
                    distinctId: "customer-123"
                )
                let grants = [StoreProduct.LocalEntitlementGrant(
                    featureId: featureId,
                    featureExternalId: nil,
                    allowanceType: "boolean",
                    allowance: nil
                )]
                await featureService.applyLocalPurchase(
                    grants: grants,
                    transactionId: "transaction-revoked-profile"
                )

                await featureService.removeLocalPurchase(
                    transactionId: "transaction-revoked-profile",
                    grants: grants
                )

                let access = await featureService.getCached(
                    featureId: featureId,
                    entityId: nil
                )
                let publishedFeatureInfo = featureInfo!
                let published = await MainActor.run {
                    publishedFeatureInfo.feature(featureId)
                }
                expect(access?.allowed).to(beFalse())
                expect(published?.allowed).to(beFalse())
            }

            it("clears published FeatureInfo together with service caches") {
                await featureService.applyLocalPurchase(
                    grants: [StoreProduct.LocalEntitlementGrant(
                        featureId: "private_feature",
                        featureExternalId: nil,
                        allowanceType: "boolean",
                        allowance: nil
                    )],
                    transactionId: "transaction-before-reset"
                )
                let publishedFeatureInfo = featureInfo!
                let allowedBefore = await MainActor.run {
                    publishedFeatureInfo.isAllowed("private_feature")
                }
                expect(allowedBefore).to(beTrue())

                await featureService.clearCache()

                let allowedAfter = await MainActor.run {
                    publishedFeatureInfo.isAllowed("private_feature")
                }
                expect(allowedAfter).to(beFalse())
            }

            it("lets a newer server balance replace optimistic purchase access") {
                let featureId = "metered_exports"
                await featureService.applyLocalPurchase(
                    grants: [
                        StoreProduct.LocalEntitlementGrant(
                            featureId: featureId,
                            featureExternalId: nil,
                            allowanceType: "metered",
                            allowance: 5
                        )
                    ],
                    transactionId: "transaction-server-reconcile"
                )

                await featureCheck.setResponse(
                    FeatureCheckResult(
                        customerId: "customer-123",
                        featureId: featureId,
                        requiredBalance: 1,
                        code: "insufficient_balance",
                        allowed: false,
                        unlimited: false,
                        balance: 0,
                        type: .metered,
                        preview: nil
                    )
                )

                _ = try await featureService.check(
                    featureId: featureId,
                    requiredBalance: 1,
                    entityId: nil
                )
                mockFactory.dateProvider.advance(by: 60 * 60)

                let access = await featureService.getCached(
                    featureId: featureId,
                    entityId: nil
                )
                expect(access).to(beNil())
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
                    transactionId: "transaction-null-allowance"
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
