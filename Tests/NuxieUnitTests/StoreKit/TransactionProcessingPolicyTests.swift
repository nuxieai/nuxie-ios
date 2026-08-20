import XCTest
@testable import Nuxie

final class TransactionProcessingPolicyTests: XCTestCase {
    func testSignedConnectorEntitlementSyncRemainsProviderOwned() {
        let policy = transactionProcessingPolicy(
            source: .nuxieEntitlementSync(distinctId: "customer-a"),
            evidenceAuthority: .providerConnector,
            observerMode: false
        )

        XCTAssertTrue(policy.providerOwnsTransaction)
        XCTAssertFalse(policy.finishAfterRecording)
        XCTAssertFalse(policy.resolvesPendingPurchase)
    }

    func testOutcomeOnlyEntitlementSyncRemainsNativeSDKOwned() {
        let policy = transactionProcessingPolicy(
            source: .nuxieEntitlementSync(distinctId: "customer-a"),
            evidenceAuthority: .nativeStoreKit,
            observerMode: false
        )

        XCTAssertFalse(policy.providerOwnsTransaction)
        XCTAssertTrue(policy.finishAfterRecording)
        XCTAssertFalse(policy.resolvesPendingPurchase)
    }

    func testSignedConnectorStoreUpdatesRemainProviderOwned() {
        let policy = transactionProcessingPolicy(
            source: .storeUpdates,
            evidenceAuthority: .providerConnector,
            observerMode: false
        )

        XCTAssertTrue(policy.providerOwnsTransaction)
        XCTAssertFalse(policy.finishAfterRecording)
    }

    func testOutcomeOnlyDelegateStoreUpdatesRemainNativeSDKOwned() {
        let policy = transactionProcessingPolicy(
            source: .storeUpdates,
            evidenceAuthority: .nativeStoreKit,
            observerMode: false
        )

        XCTAssertFalse(policy.providerOwnsTransaction)
        XCTAssertTrue(policy.finishAfterRecording)
    }

    func testConflictingActiveProductAuthorityFailsClosedForEntitlementSync() {
        let policy = transactionProcessingPolicy(
            source: .nuxieEntitlementSync(distinctId: "customer-a"),
            evidenceAuthority: .ambiguous,
            observerMode: false
        )

        XCTAssertTrue(policy.providerOwnsTransaction)
        XCTAssertFalse(policy.finishAfterRecording)
        XCTAssertFalse(policy.resolvesPendingPurchase)
    }
}
