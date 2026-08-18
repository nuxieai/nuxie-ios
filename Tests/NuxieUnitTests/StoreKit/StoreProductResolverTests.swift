import XCTest
@testable import Nuxie
import NuxieTestSupport

final class StoreProductResolverTests: XCTestCase {
    private let authorization = IntroEligibilityAuthorizationContext(
        distinctId: "customer-1",
        journeyId: "journey-1"
    )
    func testPlacementDecodesExactIntroEligibilityAndBillingPlan() throws {
        let placement = try JSONDecoder().decode(
            ExperienceReleasePlacementDocument.self,
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

    func testMissingOverrideTokenMakesExplicitPlacementUnavailable() async throws {
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
            )
        )

        await XCTAssertThrowsErrorAsync(
            try await StoreProductResolver(
                tokenProvider: StubIntroEligibilityTokenProvider(token: nil)
            ).resolve(
                experienceVersionId: "version_123",
                authorization: authorization,
                productId: "product_premium",
                placementId: "paywall:0",
                productType: .autoRenewable,
                appStoreProduct: product,
                options: .init(introEligibility: .alwaysEligible, billingPlan: .monthly)
            )
        ) { error in
            XCTAssertEqual(error as? StoreKitError, .noProductsAvailable)
        }
    }

    func testMalformedOverrideTokenMakesExplicitPlacementUnavailable() async throws {
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

        await XCTAssertThrowsErrorAsync(
            try await StoreProductResolver(
                tokenProvider: StubIntroEligibilityTokenProvider(token: "not-a-jws")
            ).resolve(
                experienceVersionId: "version_123",
                authorization: authorization,
                productId: "product_premium",
                placementId: "paywall:0",
                productType: .autoRenewable,
                appStoreProduct: product,
                options: .init(introEligibility: .alwaysIneligible, billingPlan: .default)
            )
        ) { error in
            XCTAssertEqual(error as? StoreKitError, .noProductsAvailable)
        }
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

    func testOverrideWithoutServerJourneyAuthorityIsUnavailable() async throws {
        let tokenProvider = StubIntroEligibilityTokenProvider(token: "e30.e30.c2ln")
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

        await XCTAssertThrowsErrorAsync(
            try await StoreProductResolver(
                tokenProvider: tokenProvider
            ).resolve(
                experienceVersionId: "version_123",
                authorization: nil,
                productId: "product_premium",
                placementId: "paywall:0",
                productType: .autoRenewable,
                appStoreProduct: product,
                options: .init(
                    introEligibility: .alwaysIneligible,
                    billingPlan: .default
                )
            )
        ) { error in
            XCTAssertEqual(error as? StoreKitError, .noProductsAvailable)
        }
        let requests = await tokenProvider.requests()
        XCTAssertEqual(requests, [])
    }

    func testRejectedOverrideMakesTheNextPresentationUnavailable() async throws {
        let request = IntroEligibilityTokenRequest(
            experienceVersionId: "version_123",
            placementId: "paywall:0",
            authorization: authorization
        )
        let health = IntroEligibilityOverrideHealth()
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
        let resolver = StoreProductResolver(
            tokenProvider: StubIntroEligibilityTokenProvider(
                token: "e30.e30.ZGVueQ"
            ),
            overrideHealth: health
        )

        let overridden = try await resolver.resolve(
            experienceVersionId: request.experienceVersionId,
            authorization: authorization,
            productId: "product_premium",
            placementId: request.placementId,
            productType: .autoRenewable,
            appStoreProduct: product,
            options: .init(
                introEligibility: .alwaysIneligible,
                billingPlan: .default
            )
        )
        XCTAssertFalse(overridden.hasIntroductoryOffer)
        XCTAssertEqual(overridden.introEligibilityTokenRequest, request)

        await health.suppress(request)
        await XCTAssertThrowsErrorAsync(
            try await resolver.resolve(
                experienceVersionId: request.experienceVersionId,
                authorization: authorization,
                productId: "product_premium",
                placementId: request.placementId,
                productType: .autoRenewable,
                appStoreProduct: product,
                options: .init(
                    introEligibility: .alwaysIneligible,
                    billingPlan: .default
                )
            )
        ) { error in
            XCTAssertEqual(error as? StoreKitError, .noProductsAvailable)
        }
    }
}

private actor StubIntroEligibilityTokenProvider: IntroEligibilityTokenProviding {
    private let token: String?
    private var recorded: [IntroEligibilityTokenRequest] = []

    init(token: String?) { self.token = token }

    func token(for request: IntroEligibilityTokenRequest) async throws -> String? {
        recorded.append(request)
        return token
    }

    func requests() -> [IntroEligibilityTokenRequest] { recorded }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
