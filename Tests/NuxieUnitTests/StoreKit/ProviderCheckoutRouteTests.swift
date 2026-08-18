#if NUXIE_PROVIDER_ADAPTER_TESTS
import XCTest
@testable import Nuxie

final class ProviderCheckoutRouteTests: XCTestCase {
    func testRevenueCatUsesProviderForDefaultPlanAndForwardsEligibilityJWS() {
        XCTAssertEqual(
            revenueCatCheckoutRoute(
                introEligibilityJWS: "header.payload.signature",
                billingPlan: .default
            ),
            .provider(introEligibilityJWS: "header.payload.signature")
        )
    }

    func testRevenueCatUsesNativeStoreKitForMonthlyTerms() {
        XCTAssertEqual(
            revenueCatCheckoutRoute(
                introEligibilityJWS: "header.payload.signature",
                billingPlan: .monthly
            ),
            .storeKit
        )
    }

    func testRevenueCatUsesNativeStoreKitForUpFrontTerms() {
        XCTAssertEqual(
            revenueCatCheckoutRoute(
                introEligibilityJWS: "header.payload.signature",
                billingPlan: .upFront
            ),
            .storeKit
        )
    }

    func testSuperwallAlwaysUsesObservedStoreKitCheckout() {
        XCTAssertEqual(
            superwallCheckoutRoute(),
            .storeKit
        )
    }
}
#endif
