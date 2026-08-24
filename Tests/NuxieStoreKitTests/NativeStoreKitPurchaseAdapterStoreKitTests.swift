import StoreKit
import StoreKitTest
import XCTest
@testable import Nuxie

final class NativeStoreKitPurchaseAdapterStoreKitTests: NativeStoreKitTestCase {
    func testSuccessfulPurchaseReturnsVerifiedNativeEvidence() async throws {
        let product = try await store.product(id: .consumable)
        let result = await NativeStoreKitPurchaseAdapter().purchase(product: product)

        let evidence = try XCTUnwrap(result.purchasedEvidence)
        XCTAssertEqual(evidence.productId, NativeStoreKitTestProduct.consumable.rawValue)
        XCTAssertFalse(evidence.transactionJws.isEmpty)

        await evidence.finish()
        try await store.assertEventuallyUnfinished(transactionId: evidence.transactionId, exists: false)
    }

    func testInjectedUserCancellationMapsToCancelled() async throws {
        try await store.simulateUserCancellation()
        let product = try await store.product(id: .consumable)

        let result = await NativeStoreKitPurchaseAdapter().purchase(product: product)

        XCTAssertTrue(result.isCancelled)
    }

    func testAskToBuyReturnsPendingThenPublishesApprovedTransaction() async throws {
        store.enableAskToBuy()
        let product = try await store.product(id: .consumable)

        let result = await NativeStoreKitPurchaseAdapter().purchase(product: product)

        XCTAssertTrue(result.isPending)
        let transactionId = try store.approveAskToBuy(for: .consumable)
        try await store.assertEventuallyUnfinished(
            transactionId: String(transactionId),
            exists: true
        )
    }

    func testRestoreFindsCurrentNonConsumable() async throws {
        let transaction = try await store.buyExternally(.lifetime)
        await transaction.finish()

        let result = await NativeStoreKitPurchaseAdapter().restorePurchases()

        XCTAssertTrue(result.isRestored)
    }

    func testRefundedNonConsumableIsNotRestoredOrTreatedAsOwned() async throws {
        let transaction = try await store.buyExternally(.lifetime)
        await transaction.finish()
        try store.refund(transactionId: transaction.id)
        try await store.assertEventuallyRevoked(productId: .lifetime)

        let restore = await NativeStoreKitPurchaseAdapter().restorePurchases()
        let repurchase = await NativeStoreKitPurchaseAdapter().purchase(
            product: try await store.product(id: .lifetime)
        )

        XCTAssertTrue(restore.isNoPurchases)
        XCTAssertFalse(repurchase.isAlreadyOwned)
        let evidence = try XCTUnwrap(repurchase.purchasedEvidence)
        await evidence.finish()
    }
}
