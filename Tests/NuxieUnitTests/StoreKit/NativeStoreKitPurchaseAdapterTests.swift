import StoreKit
import XCTest
@testable import Nuxie
import NuxieTestSupport

final class NativeStoreKitPurchaseAdapterTests: XCTestCase {
    func testCheckoutCarriesExactEligibilityTokenAndBillingPlan() {
        let appStoreProduct = MockStoreProduct(
            id: "premium.annual",
            displayName: "Premium Annual",
            price: 59.99,
            displayPrice: "$59.99",
            productType: .autoRenewable
        )
        let product = StoreProduct(
            productId: "product_premium",
            storeProductId: appStoreProduct.id,
            placementId: "paywall:0",
            name: appStoreProduct.displayName,
            price: appStoreProduct.displayPrice,
            period: .year,
            productType: .autoRenewable,
            billingPlan: .monthly,
            introEligibilityTokenRequest: .init(
                experienceVersionId: "version_123",
                placementId: "paywall:0",
                authorization: .init(
                    distinctId: "customer-1",
                    journeyId: "journey-1"
                )
            ),
            appStoreProduct: appStoreProduct
        )

        let token = "e30.e30.Y2hlY2tvdXQ"
        let options = product.preparedForCheckout(
            introEligibilityToken: token
        ).storeKitPurchaseOptions
        var expected = Set<Product.PurchaseOption>()
        #if compiler(>=6.1)
        expected.insert(.introductoryOfferEligibility(compactJWS: token))
        #endif

        #if compiler(>=6.3.2)
        if #available(iOS 26.4, macOS 26.4, tvOS 26.4, watchOS 26.4, *) {
            expected.insert(.billingPlanType(.monthly))
        }
        #endif

        XCTAssertEqual(options, expected)
    }

    func testAutomaticBaseCheckoutCarriesNoStoreKitOptions() {
        let product = StoreProduct(
            productId: "product_premium",
            placementId: "paywall:0",
            name: "Premium Annual",
            price: "$59.99",
            period: .year,
            productType: .autoRenewable,
            appStoreProduct: MockStoreProduct(
                id: "premium.annual",
                displayName: "Premium Annual",
                price: 59.99,
                displayPrice: "$59.99",
                productType: .autoRenewable
            )
        )

        XCTAssertEqual(product.storeKitPurchaseOptions, [])
    }
}
