import XCTest
import StoreKit
@testable import Nuxie
import NuxieTestSupport

final class StoreProductResolverTests: XCTestCase {
    private let authorization = IntroEligibilityAuthorizationContext(
        distinctId: "customer-1",
        journeyId: "journey-1",
        legId: String(repeating: "a", count: 64),
        descriptorSha256: String(repeating: "b", count: 64)
    )
    func testPlacementDecodesExactIntroEligibilityAndBillingPlan() throws {
        let placement = try JSONDecoder().decode(
            JourneyReleasePlacementDocument.self,
            from: Data(
                #"{"id":"paywall:0","productId":"product_premium","appStore":{"introEligibility":"alwaysEligible","billingPlan":"monthly"}}"#.utf8
            )
        )

        XCTAssertEqual(placement.appStoreOptions.introEligibility, .alwaysEligible)
        XCTAssertEqual(placement.appStoreOptions.billingPlan, .monthly)
    }

    func testAutomaticEligibilityProjectsFreeIntroductoryTerms() async throws {
        let product = MockStoreProduct(
            id: "premium.annual",
            displayName: "Premium Annual",
            price: 59.99,
            displayPrice: "$59.99",
            productType: .autoRenewable,
            subscriptionPeriod: SubscriptionPeriod(value: 1, unit: .year),
            introductoryTerms: StoreProduct.IntroductoryTerms(
                price: "$0.00",
                period: .week,
                periodCount: 1,
                cycles: 1,
                paymentMode: .freeTrial,
                trialPeriodText: "1 week"
            ),
            eligibleForIntroOffer: true
        )

        let resolved = try await StoreProductResolver().resolve(
            experienceVersionId: "version_123",
            authorization: authorization,
            productId: "product_premium",
            placementId: "paywall:0",
            productType: .autoRenewable,
            appStoreProduct: product,
            options: .init(introEligibility: .automatic, billingPlan: .default)
        )

        XCTAssertEqual(resolved.price, "$59.99")
        XCTAssertEqual(resolved.renewalPrice, "$59.99")
        XCTAssertEqual(resolved.renewalPeriod, "1 year")
        XCTAssertTrue(resolved.hasIntroductoryOffer)
        XCTAssertTrue(resolved.hasFreeTrial)
        XCTAssertEqual(resolved.introductoryTerms?.price, "$0.00")
        XCTAssertEqual(resolved.introductoryTerms?.period, .week)
        XCTAssertEqual(resolved.introductoryTerms?.periodCount, 1)
        XCTAssertEqual(resolved.introductoryTerms?.cycles, 1)
        XCTAssertEqual(resolved.trialPeriodText, "1 week")
        XCTAssertEqual(resolved.billingPlan, .default)
    }

    func testAlwaysEligibleUsesSignedTokenAndSelectedMonthlyTerms() async throws {
        let tokenProvider = StubIntroEligibilityTokenProvider(token: "e30.e30.c2ln")
        let product = MockStoreProduct(
            id: "premium.annual",
            displayName: "Premium Annual",
            price: 59.99,
            displayPrice: "$59.99",
            productType: .autoRenewable,
            subscriptionPeriod: SubscriptionPeriod(value: 1, unit: .year),
            billingTerms: [
                MockStoreProduct.BillingTerms(
                    plan: .monthly,
                    displayPrice: "$4.99",
                    period: SubscriptionPeriod(value: 1, unit: .month),
                    commitmentPrice: "$59.88",
                    commitmentPeriod: SubscriptionPeriod(value: 1, unit: .year),
                    introductoryTerms: StoreProduct.IntroductoryTerms(
                        price: "$1.99",
                        period: .month,
                        periodCount: 1,
                        cycles: 3,
                        paymentMode: .payAsYouGo,
                        trialPeriodText: "3 months"
                    )
                ),
            ]
        )

        let resolved = try await StoreProductResolver(
            tokenProvider: tokenProvider
        ).resolve(
            experienceVersionId: "version_123",
            authorization: authorization,
            productId: "product_premium",
            placementId: "paywall:0",
            productType: .autoRenewable,
            appStoreProduct: product,
            options: .init(introEligibility: .alwaysEligible, billingPlan: .monthly)
        )

        XCTAssertEqual(resolved.price, "$4.99")
        XCTAssertEqual(resolved.period, .month)
        XCTAssertEqual(resolved.billingPlan, .monthly)
        XCTAssertEqual(resolved.commitmentPrice, "$59.88")
        XCTAssertEqual(resolved.commitmentPeriod, "1 year")
        XCTAssertEqual(resolved.introductoryTerms?.price, "$1.99")
        XCTAssertEqual(resolved.introductoryTerms?.cycles, 3)
        XCTAssertEqual(resolved.introductoryPaymentMode, .payAsYouGo)
        XCTAssertEqual(resolved.introOfferLabel, "")
        XCTAssertEqual(resolved.trialPeriodText, "3 months")
        XCTAssertEqual(
            resolved.introEligibilityTokenRequest,
            .init(
                experienceVersionId: "version_123",
                placementId: "paywall:0",
                authorization: authorization
            )
        )
        let requests = await tokenProvider.requests()
        XCTAssertEqual(requests, [
            .init(
                experienceVersionId: "version_123",
                placementId: "paywall:0",
                authorization: authorization
            ),
        ])
    }

    func testUnusableForcedEligibilityFallsBackToAutomatic() async throws {
        for mode in [AppStorePlacementOptions.IntroEligibility.alwaysEligible, .alwaysIneligible] {
            for unavailable in ["noAuthorization", "failure", "empty", "malformed", "suppressed"] {
                for automaticEligible in [true, false] {
                    let provider = StubIntroEligibilityTokenProvider(
                        token: unavailable == "empty" ? nil
                            : unavailable == "malformed" ? "not-a-jws" : "e30.e30.c2ln",
                        fails: unavailable == "failure"
                    )
                    let health = IntroEligibilityOverrideHealth()
                    let request = IntroEligibilityTokenRequest(
                        experienceVersionId: "version_123",
                        placementId: "paywall:0",
                        authorization: authorization
                    )
                    if unavailable == "suppressed" { await health.suppress(request) }
                    let resolved = try await StoreProductResolver(
                        tokenProvider: provider,
                        overrideHealth: health
                    ).resolve(
                        experienceVersionId: request.experienceVersionId,
                        authorization: unavailable == "noAuthorization" ? nil : authorization,
                        productId: "product_premium",
                        placementId: request.placementId,
                        productType: .autoRenewable,
                        appStoreProduct: introProduct(eligible: automaticEligible),
                        options: .init(introEligibility: mode, billingPlan: .default)
                    )
                    let scenario = "\(mode): \(unavailable), automatic=\(automaticEligible)"
                    XCTAssertEqual(resolved.hasIntroductoryOffer, automaticEligible, scenario)
                    XCTAssertEqual(resolved.hasFreeTrial, automaticEligible, scenario)
                    XCTAssertEqual(resolved.trialLabel, automaticEligible ? "1 week" : "", scenario)
                    XCTAssertEqual(resolved.trialPeriodText, automaticEligible ? "1 week" : "", scenario)
                    XCTAssertNil(resolved.introEligibilityTokenRequest, scenario)
                    let requests = await provider.requests()
                    XCTAssertEqual(
                        requests.count,
                        ["noAuthorization", "suppressed"].contains(unavailable) ? 0 : 1,
                        scenario
                    )
                }
            }
        }
    }

    func testAutomaticEligibilityChecksEverySubscriptionInTheGroup() async throws {
        let cases: [(String, [Product.SubscriptionInfo.RenewalState], Bool)] = [
            ("no subscription", [], true),
            ("subscribed", [.subscribed], false),
            ("grace period", [.inGracePeriod], false),
            ("billing retry", [.inBillingRetryPeriod], false),
            ("expired", [.expired], true),
            ("revoked", [.revoked], true),
            ("another active subscription", [.expired, .subscribed], false),
        ]
        for (name, states, expected) in cases {
            for mode in [AppStorePlacementOptions.IntroEligibility.automatic, .alwaysEligible, .alwaysIneligible] {
                let resolved = try await StoreProductResolver().resolve(
                    experienceVersionId: "version_123",
                    authorization: nil,
                    productId: "product_premium",
                    placementId: "paywall:0",
                    productType: .autoRenewable,
                    appStoreProduct: introProduct(eligible: true, states: states),
                    options: .init(introEligibility: mode, billingPlan: .default)
                )
                XCTAssertEqual(resolved.hasIntroductoryOffer, expected, "\(mode): \(name)")
                XCTAssertEqual(resolved.hasFreeTrial, expected, "\(mode): \(name)")
                XCTAssertEqual(resolved.trialLabel, expected ? "1 week" : "", name)
                XCTAssertEqual(resolved.trialPeriodText, expected ? "1 week" : "", name)
                XCTAssertNil(resolved.introEligibilityTokenRequest, name)
            }
        }
    }

    func testAutomaticIneligibilityStillBlocksAnExpiredSubscription() async throws {
        let resolved = try await StoreProductResolver().resolve(
            experienceVersionId: "version_123",
            authorization: authorization,
            productId: "product_premium",
            placementId: "paywall:0",
            productType: .autoRenewable,
            appStoreProduct: introProduct(eligible: false, states: [.expired]),
            options: .default
        )
        XCTAssertFalse(resolved.hasIntroductoryOffer)
        XCTAssertEqual(resolved.trialLabel, "")
    }

    private func introProduct(
        eligible: Bool,
        states: [Product.SubscriptionInfo.RenewalState] = []
    ) -> MockStoreProduct {
        MockStoreProduct(
            id: "premium.annual",
            displayName: "Premium Annual",
            price: 59.99,
            displayPrice: "$59.99",
            productType: .autoRenewable,
            subscriptionPeriod: .init(value: 1, unit: .year),
            introductoryTerms: .init(
                price: "$0.00", period: .week, periodCount: 1, cycles: 1,
                paymentMode: .freeTrial, trialPeriodText: "1 week"
            ),
            eligibleForIntroOffer: eligible,
            subscriptionGroupRenewalStates: states
        )
    }

    func testAlwaysIneligibleSignsFalseAndSuppressesAutomaticEligibility() async throws {
        let tokenProvider = StubIntroEligibilityTokenProvider(token: "e30.e30.ZGVueQ")
        let product = MockStoreProduct(
            id: "premium.annual",
            displayName: "Premium Annual",
            price: 59.99,
            displayPrice: "$59.99",
            productType: .autoRenewable,
            subscriptionPeriod: SubscriptionPeriod(value: 1, unit: .year),
            introductoryTerms: StoreProduct.IntroductoryTerms(
                price: "$0.00",
                period: .week,
                periodCount: 1,
                cycles: 1,
                paymentMode: .freeTrial,
                trialPeriodText: "1 week"
            ),
            eligibleForIntroOffer: true
        )

        let resolved = try await StoreProductResolver(
            tokenProvider: tokenProvider
        ).resolve(
            experienceVersionId: "version_123",
            authorization: authorization,
            productId: "product_premium",
            placementId: "paywall:0",
            productType: .autoRenewable,
            appStoreProduct: product,
            options: .init(introEligibility: .alwaysIneligible, billingPlan: .default)
        )

        XCTAssertFalse(resolved.hasIntroductoryOffer)
        XCTAssertEqual(
            resolved.introEligibilityTokenRequest,
            .init(
                experienceVersionId: "version_123",
                placementId: "paywall:0",
                authorization: authorization
            )
        )
        let requests = await tokenProvider.requests()
        XCTAssertEqual(requests, [
            .init(
                experienceVersionId: "version_123",
                placementId: "paywall:0",
                authorization: authorization
            ),
        ])
    }

    func testOverrideWithoutIntroductoryOfferDoesNotAttachPurchaseOption() async throws {
        let tokenProvider = StubIntroEligibilityTokenProvider(token: "e30.e30.c2ln")
        let product = MockStoreProduct(
            id: "premium.annual",
            displayName: "Premium Annual",
            price: 59.99,
            displayPrice: "$59.99",
            productType: .autoRenewable,
            subscriptionPeriod: SubscriptionPeriod(value: 1, unit: .year)
        )

        let resolved = try await StoreProductResolver(
            tokenProvider: tokenProvider
        ).resolve(
            experienceVersionId: "version_123",
            authorization: authorization,
            productId: "product_premium",
            placementId: "paywall:0",
            productType: .autoRenewable,
            appStoreProduct: product,
            options: .init(
                introEligibility: .alwaysEligible,
                billingPlan: .default
            )
        )

        XCTAssertFalse(resolved.hasIntroductoryOffer)
        XCTAssertNil(resolved.introEligibilityTokenRequest)
        let requests = await tokenProvider.requests()
        XCTAssertEqual(requests, [])
    }
}

private actor StubIntroEligibilityTokenProvider: IntroEligibilityTokenProviding {
    private let token: String?
    private let fails: Bool
    private var recorded: [IntroEligibilityTokenRequest] = []

    init(token: String?, fails: Bool = false) {
        self.token = token
        self.fails = fails
    }

    func token(for request: IntroEligibilityTokenRequest) async throws -> String? {
        recorded.append(request)
        if fails { throw StoreKitError.networkUnavailable }
        return token
    }

    func requests() -> [IntroEligibilityTokenRequest] { recorded }
}
