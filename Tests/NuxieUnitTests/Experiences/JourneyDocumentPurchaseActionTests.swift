import XCTest
@testable import Nuxie

final class JourneyDocumentPurchaseActionTests: XCTestCase {
    func testDecodesPurchaseActionWithValueRefs() throws {
        let data = Data(
            """
            {
              "type": "purchase",
              "placementId": {
                "ref": {
                  "kind": "path",
                  "viewModelName": "VM",
                  "path": "selectedPlacementId"
                }
              }
            }
            """.utf8
        )

        let action = try JSONDecoder().decode(JourneyAction.self, from: data)

        switch action {
        case .purchase(let purchase):
            XCTAssertEqual(purchase.type, "purchase")
            XCTAssertEqual(
                purchase.placementId,
                AnyCodable([
                    "ref": [
                        "kind": "path",
                        "viewModelName": "VM",
                        "path": "selectedPlacementId",
                    ],
                ])
            )
        default:
            XCTFail("Expected purchase action")
        }
    }

    func testPurchaseActionRequiresPlacementId() {
        let data = Data(
            """
            {
              "type": "purchase",
              "productId": "legacy-product"
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
              }
            }
            """.utf8
        )

        XCTAssertThrowsError(try JSONDecoder().decode(JourneyAction.self, from: data))
    }
}
