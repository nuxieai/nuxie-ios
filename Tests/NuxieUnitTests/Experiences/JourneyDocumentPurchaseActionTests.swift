import XCTest
@testable import Nuxie

final class JourneyDocumentPurchaseActionTests: XCTestCase {
    func testDecodesPurchaseActionWithValueRefs() throws {
        let data = Data(
            """
            {
              "type": "purchase",
              "productId": {
                "type": "Response.Field",
                "key": "selectedProductId"
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
            XCTAssertEqual(
                purchase.productId,
                JourneyValue.responseField("selectedProductId")
            )
        default:
            XCTFail("Expected purchase action")
        }
    }

    func testPurchaseActionRequiresProductId() {
        let data = Data(
            """
            {
              "type": "purchase",
              "placementId": "legacy-placement",
              "onCompleted": [],
              "onFailed": [],
              "onCancelled": []
            }
            """.utf8
        )

        XCTAssertThrowsError(try JSONDecoder().decode(JourneyAction.self, from: data))
    }

    func testPurchaseActionRejectsLegacyPlacementIndex() {
        let data = Data(
            """
            {
              "type": "purchase",
              "placementIndex": {
                "ref": {
                  "kind": "path",
                  "viewModelName": "VM",
                  "path": "selectedIndex"
                }
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
