import XCTest
@testable import Nuxie

final class TransactionOwnershipStoreKitTests: NativeStoreKitTestCase {
    func testFullModeFinishesVerifiedNativePurchase() async throws {
        let fixture = NativeStoreKitServiceFixture(mode: .full)
        let product = try await fixture.preparedProduct(from: store)

        let result = try await fixture.service.purchase(product)
        if let syncTask = result.syncTask {
            let synced = await syncTask.value
            XCTAssertTrue(synced)
        }

        let recordedIds = await fixture.directObserver.recordedPurchaseIds
        let transactionId = try XCTUnwrap(recordedIds.first)
        let finishRequirements = await fixture.directObserver
            .recordedPurchaseFinishRequirements
        XCTAssertEqual(finishRequirements, [true])
        try await store.assertEventuallyUnfinished(
            transactionId: transactionId,
            exists: false
        )
    }

    func testObserverModeLeavesVerifiedNativePurchaseUnfinished() async throws {
        let fixture = NativeStoreKitServiceFixture(mode: .observer)
        let product = try await fixture.preparedProduct(from: store)

        let result = try await fixture.service.purchase(product)
        if let syncTask = result.syncTask {
            let synced = await syncTask.value
            XCTAssertTrue(synced)
        }

        let recordedIds = await fixture.directObserver.recordedPurchaseIds
        let transactionId = try XCTUnwrap(recordedIds.first)
        let finishRequirements = await fixture.directObserver
            .recordedPurchaseFinishRequirements
        XCTAssertEqual(finishRequirements, [false])
        try await store.assertEventuallyUnfinished(
            transactionId: transactionId,
            exists: true
        )
    }

    func testFullModeRecoversAndFinishesObserverModeUnfinishedPurchase() async throws {
        let fixture = NativeStoreKitServiceFixture(mode: .observer)
        let product = try await fixture.preparedProduct(from: store)
        let directResult = try await fixture.service.purchase(product)
        if let syncTask = directResult.syncTask {
            let synced = await syncTask.value
            XCTAssertTrue(synced)
        }
        let recordedIds = await fixture.directObserver.recordedPurchaseIds
        let transactionId = try XCTUnwrap(recordedIds.first)
        try await store.assertEventuallyUnfinished(
            transactionId: transactionId,
            exists: true
        )

        fixture.settings.setPurchaseHandlingMode(.full)
        let api = StoreKitRecordingPurchaseAPI()
        let recoveringObserver = fixture.makeRecoveryObserver(api: api)
        await recoveringObserver.retryStoredEvidence()

        let apiCallCount = await api.callCount()
        XCTAssertEqual(apiCallCount, 1)
        try await store.assertEventuallyUnfinished(
            transactionId: transactionId,
            exists: false
        )
    }

    func testProviderDelegateRemainsSoleReceiptAndFinishOwner() async throws {
        let delegate = StoreKitProviderPurchaseDelegate()
        let fixture = NativeStoreKitServiceFixture(
            mode: .full,
            delegate: delegate
        )
        let product = try await fixture.preparedProduct(
            from: store,
            providerFeatureAccess: "revenuecat"
        )

        _ = try await fixture.service.purchase(product)
        let transactionId = try XCTUnwrap(delegate.transactionId)
        let api = StoreKitRecordingPurchaseAPI()
        let observingNuxie = fixture.makeRecoveryObserver(api: api)
        await observingNuxie.retryStoredEvidence()

        XCTAssertEqual(delegate.purchaseCallCount, 1)
        XCTAssertEqual(store.transactionCount(for: .consumable), 1)
        let apiCallCount = await api.callCount()
        XCTAssertEqual(apiCallCount, 0)
        try await store.assertEventuallyUnfinished(
            transactionId: transactionId,
            exists: true
        )
    }
}
