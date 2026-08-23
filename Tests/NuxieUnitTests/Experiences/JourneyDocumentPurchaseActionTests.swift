import XCTest
@_spi(Testing) @testable import Nuxie

final class JourneyDocumentPurchaseActionTests: XCTestCase {
    func testDecodesPurchaseActionWithPlacementValueRef() throws {
        let data = Data(
            """
            {
              "type": "purchase",
              "placementId": {
                "ref": {
                  "kind": "path",
                  "path": "paywall.selectedProduct.placementId"
                }
              },
              "onCompleted": [],
              "onFailed": [],
              "onCancelled": []
            }
            """.utf8
        )

        let action = try JSONDecoder().decode(JourneyAction.self, from: data)

        switch action {
        case .purchase(let purchase):
            XCTAssertEqual(purchase.type, "purchase")
            let placement = try XCTUnwrap(purchase.placementId.value as? [String: Any])
            let reference = try XCTUnwrap(placement["ref"] as? [String: Any])
            XCTAssertEqual(reference["kind"] as? String, "path")
            XCTAssertEqual(reference["path"] as? String, "paywall.selectedProduct.placementId")
        default:
            XCTFail("Expected purchase action")
        }
    }

    func testPurchaseActionRequiresPlacementId() {
        let data = Data(
            """
            {
              "type": "purchase",
              "productId": {
                "type": "String",
                "value": "legacy-product"
              },
              "onCompleted": [],
              "onFailed": [],
              "onCancelled": []
            }
            """.utf8
        )

        XCTAssertThrowsError(try JSONDecoder().decode(JourneyAction.self, from: data))
    }

    func testPurchaseActionRejectsLegacyProductIdAndPlacementIndex() {
        let data = Data(
            """
            {
              "type": "purchase",
              "placementId": "placement-primary",
              "productId": {
                "type": "String",
                "value": "legacy-product"
              },
              "placementIndex": {
                "type": "Number",
                "value": 0
              },
              "onCompleted": [],
              "onFailed": [],
              "onCancelled": []
            }
            """.utf8
        )

        XCTAssertThrowsError(try JSONDecoder().decode(JourneyAction.self, from: data))
    }
}
