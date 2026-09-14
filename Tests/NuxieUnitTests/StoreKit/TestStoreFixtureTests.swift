import Foundation
import XCTest
@testable import Nuxie

final class TestStoreFixtureTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Case: Decodable {
            struct Action: Decodable {
                let operation: String
                let customer: String
                let product: String?
                let storeProduct: String?
                let choice: String
                let expectedOutcome: String
                let expectedTransaction: Bool?
                let expectedProducts: [String]?
            }
            let name: String
            let actions: [Action]
        }
        let cases: [Case]
    }

    func testSharedLocalOutcomeContract() async throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/purchases/test-store.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        for scenario in fixture.cases {
            let store = NuxieTestStore()
            var transactions = Set<String>()
            for action in scenario.actions {
                if action.operation == "purchase" {
                    let choices: [String: TestStorePurchaseChoice] = [
                        "purchased": .purchased, "pending": .pending,
                        "cancelled": .cancelled, "failed": .failed,
                    ]
                    let productId = try XCTUnwrap(action.product)
                    let product = StoreProduct(
                        productId: productId, storeProductId: try XCTUnwrap(action.storeProduct),
                        placementId: "test-placement", name: productId, price: "$1.00", period: nil
                    )
                    let response = await store.purchaseResponse(
                        for: try XCTUnwrap(choices[action.choice]),
                        product: product, distinctId: action.customer
                    )
                    let outcome: String
                    switch response.result {
                    case .purchased(let evidence):
                        outcome = "purchased"
                        XCTAssertNil(evidence, scenario.name)
                    case .pending: outcome = "pending"
                    case .cancelled: outcome = "cancelled"
                    case .failed: outcome = "failed"
                    default: outcome = "unexpected"
                    }
                    XCTAssertEqual(outcome, action.expectedOutcome, scenario.name)
                    XCTAssertEqual(response.transactionId != nil, action.expectedTransaction, scenario.name)
                    if let transaction = response.transactionId {
                        XCTAssertTrue(transaction.hasPrefix("nuxie-test-"), scenario.name)
                        XCTAssertTrue(transactions.insert(transaction).inserted, scenario.name)
                    }
                } else {
                    XCTAssertEqual(action.operation, "restore")
                    let choices: [String: TestStoreRestoreChoice] = [
                        "restored": .restored, "no_purchases": .noPurchases, "failed": .failed,
                    ]
                    let response = await store.restoreResponse(
                        for: try XCTUnwrap(choices[action.choice]), distinctId: action.customer
                    )
                    let outcome: String
                    switch response.result {
                    case .restored: outcome = "restored"
                    case .noPurchases: outcome = "no_purchases"
                    case .failed: outcome = "failed"
                    }
                    XCTAssertEqual(outcome, action.expectedOutcome, scenario.name)
                    XCTAssertEqual(response.products.map(\.storeProductId).sorted(), action.expectedProducts, scenario.name)
                }
            }
        }
    }
}
