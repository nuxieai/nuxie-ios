import Foundation
import XCTest
@testable import Nuxie

final class CommerceStoreCorruptionTests: XCTestCase {
    private let scope = PurchaseStorageScope.testFixture

    func testTransactionEvidenceCorruptionIsUnknownAndCannotBeDiscarded() throws {
        let fixture = try corruptStoreFixture(fileName: "transaction-evidence.json")
        let store = TransactionEvidenceStore(
            customStoragePath: fixture.root,
            scope: scope
        )

        assertUnreadable(store.load())
        XCTAssertFalse(store.save([:]))
        XCTAssertEqual(try Data(contentsOf: fixture.file), fixture.contents)
    }

    func testPendingPurchaseCorruptionIsUnknownAndCannotBeDiscarded() throws {
        let fixture = try corruptStoreFixture(fileName: "pending-purchases.json")
        let store = PendingPurchaseStore(
            customStoragePath: fixture.root,
            scope: scope
        )

        assertUnreadable(store.load())
        XCTAssertFalse(store.save([:]))
        XCTAssertEqual(try Data(contentsOf: fixture.file), fixture.contents)
    }

    func testAccountOwnershipCorruptionIsUnknownAndCannotBeDiscarded() throws {
        let fixture = try corruptStoreFixture(fileName: "account-ownership.json")
        let store = PurchaseAccountOwnershipStore(
            customStoragePath: fixture.root,
            scope: scope
        )
        let token = scope.appAccountToken(distinctId: "customer-a")

        assertUnreadable(store.load())
        XCTAssertNil(store.owner(for: token, scope: scope))
        XCTAssertFalse(store.upsert(StoredPurchaseAccountOwnership(
            scope: scope,
            appAccountToken: token,
            distinctId: "customer-a"
        )))
        XCTAssertEqual(try Data(contentsOf: fixture.file), fixture.contents)
    }

    private func corruptStoreFixture(
        fileName: String
    ) throws -> (root: URL, file: URL, contents: Data) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("commerce-corruption-\(UUID().uuidString)")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let directory = scope.storageDirectory(customStoragePath: root)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let file = directory.appendingPathComponent(fileName)
        let contents = Data("{ unreadable".utf8)
        try contents.write(to: file)
        return (root, file, contents)
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
