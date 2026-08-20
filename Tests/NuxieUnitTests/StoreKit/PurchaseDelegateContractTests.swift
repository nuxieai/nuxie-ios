import XCTest
@testable import Nuxie

final class PurchaseDelegateContractTests: XCTestCase {
    func testPurchaseDelegateReportsOnlyCustomerVisibleOutcomes() {
        XCTAssertEqual(PurchaseResult.purchased, .purchased)
        XCTAssertEqual(PurchaseResult.pending, .pending)
        XCTAssertEqual(PurchaseResult.cancelled, .cancelled)
        XCTAssertEqual(
            PurchaseResult.failed(StoreKitError.purchaseCancelled),
            .failed(StoreKitError.purchaseCancelled)
        )

        XCTAssertEqual(RestoreResult.restored, .restored)
        XCTAssertEqual(RestoreResult.noPurchases, .noPurchases)
        XCTAssertEqual(
            RestoreResult.failed(StoreKitError.purchaseCancelled),
            .failed(StoreKitError.purchaseCancelled)
        )
    }
}
