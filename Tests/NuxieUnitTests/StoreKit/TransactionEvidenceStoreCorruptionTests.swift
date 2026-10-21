import Foundation
import XCTest
@testable import Nuxie

/// A purchase store file that was read but does not decode is corrupt: it is
/// renamed aside, never read again, and an empty store takes its place. One
/// that cannot be read right now is left as it is and reads as unreadable.
final class TransactionEvidenceStoreCorruptionTests: XCTestCase {
    private let scope = PurchaseStorageScope.testFixture

    func testCorruptTransactionEvidenceIsSetAsideAndAnEmptyStoreTakesItsPlace() throws {
        let fixture = try corruptStoreFixture(fileName: "transaction-evidence.json")
        let logs = StoreLogLines()
        let store = TransactionEvidenceStore(
            customStoragePath: fixture.root,
            scope: scope,
            logger: logs.logger
        )

        assertAbsent(store.load())
        let quarantined = try XCTUnwrap(quarantinedFiles(of: fixture.file).first)
        XCTAssertEqual(try Data(contentsOf: quarantined), fixture.contents, "the corrupt bytes are kept aside")
        XCTAssertTrue(quarantined.lastPathComponent.hasPrefix("transaction-evidence.unreadable-"))
        XCTAssertEqual(quarantined.pathExtension, "json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.file.path))

        let entry = evidence("after-quarantine")
        XCTAssertTrue(store.save([entry.transactionId: entry]), "the empty store takes writes")
        XCTAssertEqual(store.load().readableValue, [entry.transactionId: entry])
        XCTAssertEqual(quarantinedFiles(of: fixture.file), [quarantined], "the set-aside file is never read again")

        XCTAssertEqual(logs.lines.count, 1, "one log per quarantine")
        XCTAssertTrue(logs.lines[0].contains("the file is not valid JSON"), logs.lines[0])
        XCTAssertTrue(logs.lines[0].contains(quarantined.lastPathComponent), logs.lines[0])
    }

    func testCorruptPendingPurchasesAreSetAsideAndAnEmptyStoreTakesItsPlace() throws {
        let fixture = try corruptStoreFixture(fileName: "pending-purchases.json")
        let store = PendingPurchaseStore(
            customStoragePath: fixture.root,
            scope: scope
        )

        assertAbsent(store.load())
        XCTAssertEqual(quarantinedFiles(of: fixture.file).count, 1)
        XCTAssertTrue(store.save([:]))
    }

    func testCorruptAccountOwnershipIsSetAsideAndAnEmptyStoreTakesItsPlace() throws {
        let fixture = try corruptStoreFixture(fileName: "account-ownership.json")
        let store = PurchaseAccountOwnershipStore(
            customStoragePath: fixture.root,
            scope: scope
        )
        let token = scope.appAccountToken(distinctId: "customer-a")

        XCTAssertNil(store.evidenceAuthority(for: token, productId: "product", scope: scope))
        XCTAssertEqual(quarantinedFiles(of: fixture.file).count, 1)
        XCTAssertTrue(store.upsert(StoredPurchaseAccountOwnership(
            scope: scope,
            appAccountToken: token,
            distinctId: "customer-a",
            productAuthorities: ["product": .nativeStoreKit]
        )))
        XCTAssertEqual(
            store.evidenceAuthority(for: token, productId: "product", scope: scope),
            .nativeStoreKit
        )
    }

    /// A current-format entry the decoder rejects makes the file corrupt.
    /// The log names the entry and the field that failed, never their
    /// values.
    func testRejectedEntryLogsItsIdAndFieldWithoutItsValue() throws {
        let fixture = try corruptStoreFixture(fileName: "transaction-evidence.json")
        let logs = StoreLogLines()
        let store = TransactionEvidenceStore(
            customStoragePath: fixture.root,
            scope: scope,
            logger: logs.logger
        )
        let valid = evidence("valid-transaction")
        try FileManager.default.removeItem(at: fixture.file)
        XCTAssertTrue(store.save([valid.transactionId: valid]))
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixture.file)) as? [String: Any]
        )
        var broken = try XCTUnwrap(object[valid.transactionId] as? [String: Any])
        broken["transactionId"] = "broken-transaction"
        broken["admissionId"] = "not-a-uuid"
        object["broken-transaction"] = broken
        try JSONSerialization.data(withJSONObject: object).write(to: fixture.file)

        assertAbsent(store.load())
        XCTAssertEqual(quarantinedFiles(of: fixture.file).count, 1)
        let line = logs.lines.joined(separator: "\n")
        XCTAssertEqual(logs.lines.count, 1)
        XCTAssertTrue(line.contains("entry broken-transaction at admissionId"), line)
        XCTAssertFalse(line.contains("not-a-uuid"), "the log never carries the stored value")
        XCTAssertFalse(line.contains("signed-valid-transaction"), "the log never carries a signed transaction")
    }

    /// Each quarantine deletes the older quarantined files of the store, so
    /// only the newest is kept, and each one logs once.
    func testRepeatedCorruptionKeepsOnlyTheNewestQuarantinedFile() throws {
        let fixture = try corruptStoreFixture(fileName: "transaction-evidence.json")
        let logs = StoreLogLines()
        let firstLaunch = TransactionEvidenceStore(
            customStoragePath: fixture.root,
            scope: scope,
            logger: logs.logger
        )
        assertAbsent(firstLaunch.load())
        let first = try XCTUnwrap(quarantinedFiles(of: fixture.file).first)

        let second = Data("{ corrupt again".utf8)
        try second.write(to: fixture.file)
        let secondLaunch = TransactionEvidenceStore(
            customStoragePath: fixture.root,
            scope: scope,
            logger: logs.logger
        )
        assertAbsent(secondLaunch.load())

        let kept = quarantinedFiles(of: fixture.file)
        XCTAssertEqual(kept.count, 1, "only the newest quarantined file is kept")
        XCTAssertNotEqual(kept.first, first)
        XCTAssertEqual(try kept.first.map { try Data(contentsOf: $0) }, second)
        XCTAssertEqual(logs.lines.count, 2, "one log per quarantine")
    }

    /// A store file that cannot be read right now (here its permissions deny
    /// reading, as data protection does before the first unlock) is not
    /// corrupt: no bytes were read. It is not renamed, reads as unreadable,
    /// and takes no writes.
    func testStoreThatCannotBeReadNowIsLeftAsItIs() throws {
        let fixture = try corruptStoreFixture(fileName: "transaction-evidence.json")
        let logs = StoreLogLines()
        let valid = evidence("kept-transaction")
        try FileManager.default.removeItem(at: fixture.file)
        let writer = TransactionEvidenceStore(customStoragePath: fixture.root, scope: scope)
        XCTAssertTrue(writer.save([valid.transactionId: valid]))
        let contents = try Data(contentsOf: fixture.file)
        try denyReading(fixture.file)

        let store = TransactionEvidenceStore(
            customStoragePath: fixture.root,
            scope: scope,
            logger: logs.logger
        )
        assertUnreadable(store.load())
        XCTAssertFalse(store.save([:]))
        XCTAssertTrue(quarantinedFiles(of: fixture.file).isEmpty, "a file that cannot be read now is not renamed")

        try allowReading(fixture.file)
        XCTAssertEqual(try Data(contentsOf: fixture.file), contents, "it is left byte for byte")
        XCTAssertEqual(store.load().readableValue, [valid.transactionId: valid], "the next read finds it")
    }

    private func evidence(_ transactionId: String) -> StoredTransactionEvidence {
        StoredTransactionEvidence(
            scope: scope,
            transactionJws: "signed-\(transactionId)",
            transactionId: transactionId,
            originalTransactionId: "original-\(transactionId)",
            productId: "product",
            distinctId: "customer",
            recordedAt: Date(timeIntervalSince1970: 1_000_000_000),
            isRevoked: false
        )
    }

    private func corruptStoreFixture(
        fileName: String
    ) throws -> (root: URL, file: URL, contents: Data) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("purchase-corruption-\(UUID().uuidString)")
        let directory = scope.storageDirectory(customStoragePath: root)
        let file = directory.appendingPathComponent(fileName)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let contents = Data("{ unreadable".utf8)
        try contents.write(to: file)
        return (root, file, contents)
    }

    private func quarantinedFiles(of file: URL) -> [URL] {
        let directory = file.deletingLastPathComponent()
        let prefix = file.deletingPathExtension().lastPathComponent + ".unreadable-"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasPrefix(prefix) }.sorted()
            .map { directory.appendingPathComponent($0) }
    }

    private func denyReading(_ file: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
    }

    private func allowReading(_ file: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
    }

    private func assertAbsent<Value: Sendable>(
        _ result: StoreReadResult<Value>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .absent = result else {
            XCTFail("Expected an empty store in place of the corrupt one", file: file, line: line)
            return
        }
    }

    private func assertUnreadable<Value: Sendable>(
        _ result: StoreReadResult<Value>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .unreadable = result else {
            XCTFail("Expected unreadable store state", file: file, line: line)
            return
        }
    }
}

/// Collects the lines a test's own store logger writes.
private final class StoreLogLines: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var lines: [String] { lock.withLock { storage } }

    var logger: NuxieLogger {
        NuxieLogger { _, message in self.append(message) }
    }

    private func append(_ line: String) { lock.withLock { storage.append(line) } }
}
