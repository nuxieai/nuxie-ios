import Foundation
import XCTest

final class StoreKitConfigurationContractTests: XCTestCase {
    func testCheckedInConfigurationContainsQualificationProducts() throws {
        let bundle = Bundle(for: NativeStoreKitTestHarness.self)
        let url = try XCTUnwrap(
            bundle.url(
                forResource: "NuxieNativeCommerce",
                withExtension: "storekit"
            )
        )
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        let root = try XCTUnwrap(object as? [String: Any])
        let products = try XCTUnwrap(root["products"] as? [[String: Any]])
        let pairs: [(String, String)] = products.compactMap {
            guard let id = $0["productID"] as? String,
                  let type = $0["type"] as? String else { return nil }
            return (id, type)
        }
        let typesById = Dictionary(uniqueKeysWithValues: pairs)

        XCTAssertEqual(
            typesById[NativeStoreKitTestProduct.consumable.rawValue],
            "Consumable"
        )
        XCTAssertEqual(
            typesById[NativeStoreKitTestProduct.lifetime.rawValue],
            "NonConsumable"
        )
    }
}
