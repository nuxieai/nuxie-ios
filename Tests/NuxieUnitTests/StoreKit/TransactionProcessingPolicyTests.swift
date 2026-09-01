import XCTest
@testable import Nuxie

final class TransactionProcessingPolicyTests: XCTestCase {
    func testProviderEvidenceRemainsProviderOwned() {
        let policy = transactionProcessingPolicy(
            resolvesPendingPurchase: false,
            evidenceAuthority: .providerConnector,
            observerMode: false
        )

        XCTAssertTrue(policy.providerOwnsTransaction)
        XCTAssertFalse(policy.finishAfterRecording)
        XCTAssertFalse(policy.resolvesPendingPurchase)
    }

    func testNativeEvidenceRemainsSDKOwned() {
        let policy = transactionProcessingPolicy(
            resolvesPendingPurchase: false,
            evidenceAuthority: .nativeStoreKit,
            observerMode: false
        )

        XCTAssertFalse(policy.providerOwnsTransaction)
        XCTAssertTrue(policy.finishAfterRecording)
        XCTAssertFalse(policy.resolvesPendingPurchase)
    }

    func testProviderDeferredUpdateRetainsPendingResolutionIntent() {
        let policy = transactionProcessingPolicy(
            resolvesPendingPurchase: true,
            evidenceAuthority: .providerConnector,
            observerMode: false
        )

        XCTAssertTrue(policy.providerOwnsTransaction)
        XCTAssertFalse(policy.finishAfterRecording)
        XCTAssertTrue(policy.resolvesPendingPurchase)
    }

    func testNativeDeferredUpdateFinishesAndResolvesPendingPurchase() {
        let policy = transactionProcessingPolicy(
            resolvesPendingPurchase: true,
            evidenceAuthority: .nativeStoreKit,
            observerMode: false
        )

        XCTAssertFalse(policy.providerOwnsTransaction)
        XCTAssertTrue(policy.finishAfterRecording)
        XCTAssertTrue(policy.resolvesPendingPurchase)
    }

    func testConflictingActiveProductAuthorityFailsClosed() {
        let policy = transactionProcessingPolicy(
            resolvesPendingPurchase: false,
            evidenceAuthority: .ambiguous,
            observerMode: false
        )

        XCTAssertTrue(policy.providerOwnsTransaction)
        XCTAssertFalse(policy.finishAfterRecording)
        XCTAssertFalse(policy.resolvesPendingPurchase)
    }
}
