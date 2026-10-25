import Foundation
import XCTest
@testable import Nuxie

final class CustomerStorePinTests: XCTestCase {
    func testCommittedReferencesOwnExistingFilesAndProtectSharedPinsDuringCollection() async throws {
        let disk = try CustomerStoreTestDatabase()
        defer { try? disk.remove() }
        let store = SQLiteEventStore()
        try await store.initialize(path: disk.root)
        let owner = CustomerStoreOwner(scope: .testFixture, userId: "customer")
        try disk.seedJourney(owner: owner)
        try disk.seedJourney(owner: owner, journeyId: "other-journey", experience: "other-experience")
        let files = CustomerPinFileOwner(journalRoot: disk.root.appendingPathComponent("journey-journal-v2"))
        let sha = String(repeating: "a", count: 64)
        let orphanSHA = String(repeating: "b", count: 64)
        let relative = owner.scope.customerDigest(distinctId: owner.userId) + "/" + sha + ".json"
        let file = files.root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data("existing descriptor bytes".utf8)
        try bytes.write(to: file)
        let orphan = file.deletingLastPathComponent().appendingPathComponent(orphanSHA + ".artifact")
        try Data("orphan".utf8).write(to: orphan)
        let pin = try files.reference(owner: owner, sha256: sha, kind: .descriptor)
        let first = CustomerJourneyKey(owner: owner, journeyId: "journey", legGeneration: 0)
        let second = CustomerJourneyKey(owner: owner, journeyId: "other-journey", legGeneration: 0)
        try await store.replaceReleasePins(for: first, pins: [pin])
        try await store.replaceReleasePins(for: second, pins: [pin])
        let references = try await store.committedReleasePinPaths()
        XCTAssertEqual(references, [relative])
        let removed = try await files.collectOrphans(in: store)
        XCTAssertEqual(removed, [owner.scope.customerDigest(distinctId: owner.userId) + "/" + orphanSHA + ".artifact"])
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        try await store.replaceReleasePins(for: first, pins: [])
        let stillOwned = try await files.collectOrphans(in: store)
        XCTAssertTrue(stillOwned.isEmpty)
        await store.close()
        try await store.initialize(path: disk.root)
        let restored = try await store.releasePins(for: second)
        XCTAssertEqual(restored, [pin])
        try await store.replaceReleasePins(for: second, pins: [])
        let collected = try await files.collectOrphans(in: store)
        XCTAssertEqual(collected, [relative])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        await store.close()
    }

    func testFailedReferenceReadCannotCollectFilesAndForeignPathsCannotCommit() async throws {
        let disk = try CustomerStoreTestDatabase()
        defer { try? disk.remove() }
        let store = SQLiteEventStore()
        try await store.initialize(path: disk.root)
        let owner = CustomerStoreOwner(scope: .testFixture, userId: "customer")
        try disk.seedJourney(owner: owner)
        let key = CustomerJourneyKey(owner: owner, journeyId: "journey", legGeneration: 0)
        let sha = String(repeating: "a", count: 64)
        let files = CustomerPinFileOwner(journalRoot: disk.root)
        let path = owner.scope.customerDigest(distinctId: owner.userId) + "/" + sha + ".artifact"
        let file = files.root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: file)
        let pin = try files.reference(owner: owner, sha256: sha, kind: .artifact)
        try await store.replaceReleasePins(for: key, pins: [pin])
        let foreign = CustomerReleasePin(objectSHA256: sha, kind: .artifact, relativePath: "../escape", sizeBytes: 4)
        do { try await store.replaceReleasePins(for: key, pins: [foreign]); XCTFail("Foreign paths must not replace owned references") } catch CustomerStoreError.wrongOwner { }
        let after = try await store.releasePins(for: key)
        XCTAssertEqual(after, [pin])
        try disk.execute("DROP TABLE journey_release_pins;")
        do { _ = try await files.collectOrphans(in: store); XCTFail("A failed reference query must prevent collection") } catch { }
        XCTAssertEqual(try Data(contentsOf: file), Data("keep".utf8))
        await store.close()
    }
}
