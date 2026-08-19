import XCTest
@testable import Nuxie

final class TransactionProcessingPolicyTests: XCTestCase {
    func testExplicitStoreKitEntitlementSyncBypassesConfiguredProviderOwnership() {
        let policy = transactionProcessingPolicy(
            source: .nuxieEntitlementSync(distinctId: "customer-a"),
            delegateConfigured: true,
            observerMode: false
        )

        XCTAssertFalse(policy.providerOwnsTransaction)
        XCTAssertFalse(policy.finishAfterRecording)
        XCTAssertFalse(policy.resolvesPendingPurchase)
    }

    func testStoreUpdatesRemainProviderOwnedWhenDelegateIsConfigured() {
        let policy = transactionProcessingPolicy(
            source: .storeUpdates,
            delegateConfigured: true,
            observerMode: false
        )

        XCTAssertTrue(policy.providerOwnsTransaction)
        XCTAssertFalse(policy.finishAfterRecording)
    }
}
