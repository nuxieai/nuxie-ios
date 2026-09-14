import Foundation
import XCTest
@testable import Nuxie

final class TestStorePreviewFixtureTests: XCTestCase {
    func testSharedDisplayVectorsThroughProductionProductConstruction() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/purchases/test-store-preview.json")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let cases = try XCTUnwrap(root["cases"] as? [[String: Any]])
        for scenario in cases {
            let previewData = try JSONSerialization.data(withJSONObject: XCTUnwrap(scenario["preview"]))
            let preview = try JSONDecoder().decode(JourneyReleaseProductDocument.Preview.self, from: previewData)
            let product = JourneyReleaseCatalog.makeTestStoreProduct(
                productId: "pro", storeProductId: "store-pro", placementId: "primary",
                preview: preview, productType: .autoRenewable
            )
            let actual: [String: Any] = [
                "name": product.name,
                "description": product.description,
                "price": product.price,
                "period": product.period?.rawValue ?? "",
                "periodCount": product.periodCount ?? 0,
                "periodLabel": product.periodLabel,
                "hasTrial": product.hasTrial,
                "trialLabel": product.trialLabel,
                "introOfferLabel": product.introOfferLabel,
                "renewalLabel": product.renewalLabel,
                "renewalPrice": product.renewalPrice,
                "renewalPeriod": product.renewalPeriod,
                "hasIntroductoryOffer": product.hasIntroductoryOffer,
                "hasFreeTrial": product.hasFreeTrial,
                "introductoryPrice": product.introductoryTerms?.price ?? "",
                "introductoryPeriod": product.introductoryTerms?.period.rawValue ?? "",
                "introductoryPeriodCount": product.introductoryTerms?.periodCount ?? 0,
                "introductoryCycles": product.introductoryTerms?.cycles ?? 0,
                "introductoryPaymentMode": product.introductoryPaymentMode?.rawValue ?? "",
                "trialPeriodText": product.trialPeriodText,
            ]
            let expected = try XCTUnwrap(scenario["expected"] as? [String: Any])
            XCTAssertEqual(actual as NSDictionary, expected as NSDictionary, scenario["name"] as? String ?? "")
            XCTAssertTrue(product.isTestStoreProduct)
            XCTAssertNil(product.rawProduct)
            XCTAssertEqual(product.productId, "pro")
            XCTAssertEqual(product.placementId, "primary")
        }
    }
}
