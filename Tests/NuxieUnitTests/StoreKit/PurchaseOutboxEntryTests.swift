import Foundation
import XCTest
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

/// The outbox reads only entries in its own format.
final class PurchaseOutboxEntryTests: XCTestCase {
    /// An entry in the previous SDK's format (its answer under
    /// `backendSyncedAt`, with no reason, customer kind, attempt count or
    /// admission) is dropped when the outbox is read: pre-GA local state,
    /// with no compatibility handling. The rest of the outbox still loads,
    /// and the next write leaves the old entry out.
    func testEntryInThePreviousFormatIsDroppedWhenTheOutboxIsRead() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("outbox-format-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = TransactionEvidenceStore(customStoragePath: root, scope: .testFixture)
        let current = StoredTransactionEvidence(
            transactionJws: "current-jws",
            transactionId: "current-transaction",
            originalTransactionId: "current-original",
            productId: "product",
            distinctId: "customer",
            recordedAt: Date(timeIntervalSince1970: 1_000_000_000),
            isRevoked: false
        )
        XCTAssertTrue(store.save([current.transactionId: current]))

        // Add an entry as the previous SDK wrote it.
        let file = PurchaseStorageScope.testFixture
            .storageDirectory(customStoragePath: root)
            .appendingPathComponent("transaction-evidence.json")
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        )
        var previous = try XCTUnwrap(object[current.transactionId] as? [String: Any])
        previous["transactionId"] = "previous-transaction"
        previous["transactionJws"] = ""
        previous["backendSyncedAt"] = "2001-09-09T01:46:40Z"
        for key in ["reason", "customerKind", "sendAttempts", "admissionId", "retryDueAt"] {
            previous.removeValue(forKey: key)
        }
        object["previous-transaction"] = previous
        try JSONSerialization.data(withJSONObject: object).write(to: file)

        let loaded = try XCTUnwrap(store.load().valueTreatingAbsentAsEmpty([:]))
        XCTAssertEqual(Set(loaded.keys), ["current-transaction"])
        XCTAssertEqual(loaded["current-transaction"], current)

        XCTAssertTrue(store.save(loaded))
        let rewritten = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        )
        XCTAssertEqual(Set(rewritten.keys), ["current-transaction"])
    }
}
