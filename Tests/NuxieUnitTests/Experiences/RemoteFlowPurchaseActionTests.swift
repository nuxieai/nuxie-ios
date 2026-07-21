import XCTest
@testable import Nuxie

final class RemoteFlowPurchaseActionTests: XCTestCase {
    func testDecodesPurchaseActionWithValueRefs() throws {
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
              "productId": {
                "ref": {
                  "kind": "path",
                  "viewModelName": "VM",
                  "path": "selectedProductId"
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
                purchase.placementIndex,
                AnyCodable([
                    "ref": [
                        "kind": "path",
                        "viewModelName": "VM",
                        "path": "selectedIndex",
                    ],
                ])
            )
            XCTAssertEqual(
                purchase.productId,
                AnyCodable([
                    "ref": [
                        "kind": "path",
                        "viewModelName": "VM",
                        "path": "selectedProductId",
                    ],
                ])
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

    func testPurchaseActionRequiresPlacementIndex() {
        let data = Data(
            """
            {
              "type": "purchase",
              "productId": {
                "ref": {
                  "kind": "path",
                  "viewModelName": "VM",
                  "path": "selectedProductId"
                }
              }
            }
            """.utf8
        )

        XCTAssertThrowsError(try JSONDecoder().decode(JourneyAction.self, from: data))
    }
}
