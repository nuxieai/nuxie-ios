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

    /// Only an entry with no admission id is from the previous SDK. A
    /// current-format entry that cannot be read (here a malformed admission
    /// id) makes the whole outbox unreadable, as a malformed file does:
    /// nothing is dropped, nothing is written over the file, and the log
    /// names the entry and the field without their values. The outbox is
    /// then off for the session, so a purchase is still sent once.
    func testUnreadableCurrentFormatEntryMakesTheOutboxUnreadable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("outbox-format-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let logs = LogLines()
        let store = TransactionEvidenceStore(
            customStoragePath: root,
            scope: .testFixture,
            logger: NuxieLogger { _, message in logs.append(message) }
        )
        let valid = StoredTransactionEvidence(
            transactionJws: "valid-jws",
            transactionId: "valid-transaction",
            originalTransactionId: "valid-original",
            productId: "product",
            distinctId: "customer",
            recordedAt: Date(timeIntervalSince1970: 1_000_000_000),
            isRevoked: false
        )
        XCTAssertTrue(store.save([valid.transactionId: valid]))

        let file = PurchaseStorageScope.testFixture
            .storageDirectory(customStoragePath: root)
            .appendingPathComponent("transaction-evidence.json")
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        )
        var broken = try XCTUnwrap(object[valid.transactionId] as? [String: Any])
        broken["transactionId"] = "broken-transaction"
        broken["admissionId"] = "not-a-uuid"
        object["broken-transaction"] = broken
        let contents = try JSONSerialization.data(withJSONObject: object)
        try contents.write(to: file)

        guard case .unreadable = store.load() else {
            return XCTFail("a current-format entry that cannot be read fails closed")
        }
        XCTAssertFalse(store.save([valid.transactionId: valid]))
        XCTAssertEqual(try Data(contentsOf: file), contents, "nothing is written over it")

        let failure = logs.lines.joined(separator: "\n")
        XCTAssertTrue(failure.contains("broken-transaction"), failure)
        XCTAssertTrue(failure.contains("admissionId"), failure)
        XCTAssertFalse(failure.contains("not-a-uuid"), "the log never carries the stored value")
        XCTAssertFalse(failure.contains("valid-jws"), "the log never carries a signed transaction")

        // The observer fails closed on it too: no send, and no write.
        let mocks = MockFactory.shared
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let api = RecoverySyncAPI(succeeds: true)
        let observer = TransactionObserver(
            api: api,
            features: FeatureService(
                api: mocks.nuxieApi,
                identity: identity,
                profile: mocks.profileService,
                dateProvider: mocks.dateProvider,
                featureInfo: FeatureInfo(),
                cacheTTL: 300
            ),
            identity: identity,
            settings: NuxieRuntimeSettings(configuration: NuxieConfiguration(apiKey: "outbox-unreadable")),
            eventSink: RecoveryEventSink(),
            transactionServiceProvider: { fatalError("unused") },
            evidenceStore: store,
            dateProvider: mocks.dateProvider,
            unfinishedRecoveryTransactions: { [] },
            currentEntitlementRecoveryTransactions: { [] }
        )
        addTeardownBlock { await observer.stopListening() }
        await observer.retryStoredEvidence()
        let committed = await observer.commit(.verified(
            VerifiedPurchaseEvidence(
                transactionJws: "new-jws",
                transactionId: "new-transaction",
                originalTransactionId: "new-original",
                productId: "product",
                attributedDistinctId: "customer",
                resolvesPendingPurchase: false,
                allowsDurableCheckoutAuthority: false,
                requiresAuthorityResolution: false
            ),
            source: .transactionStream
        ))
        // The outbox is off for the session: the purchase is still sent
        // once, and nothing is written over the file.
        XCTAssertTrue(committed.committed)
        _ = await committed.syncTask?.value
        XCTAssertEqual(api.recordedCustomers, ["customer"])
        XCTAssertEqual(try Data(contentsOf: file), contents, "the file is left byte for byte")
    }
}

/// Collects log lines written by a test's own logger.
private final class LogLines: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ line: String) { lock.withLock { storage.append(line) } }
    var lines: [String] { lock.withLock { storage } }
}
