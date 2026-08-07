import Foundation
import XCTest
import NuxieRuntime
@testable import Nuxie

final class NuxPackageReaderTests: XCTestCase {
    func testReadsManifestAndJourneyWithoutInterpretingScene() throws {
        let bytes = try fixtureBytes(named: "animation-event")
        let package = try NuxPackageReader.read(bytes)

        XCTAssertEqual(package.manifest.version, 1)
        XCTAssertEqual(
            package.manifest.identity.experienceId,
            "nuxie-sdk-fixture-animation-event"
        )
        XCTAssertEqual(package.journey.schemaVersion, package.manifest.journey.schemaVersion)
        XCTAssertNotNil(package.member(named: "scene"))
    }

    func testRejectsBadMagicVersionAndBounds() throws {
        let original = try fixtureBytes(named: "animation-event")

        var badMagic = original
        badMagic[0] = 0
        XCTAssertThrowsError(try NuxPackageReader.read(badMagic)) {
            XCTAssertEqual($0 as? NuxPackageReaderError, .badMagic)
        }

        var badVersion = original
        badVersion.replaceSubrange(8..<12, with: UInt32(2).littleEndianBytes)
        XCTAssertThrowsError(try NuxPackageReader.read(badVersion)) {
            XCTAssertEqual($0 as? NuxPackageReaderError, .unsupportedVersion(2))
        }

        XCTAssertThrowsError(try NuxPackageReader.read(original.prefix(32)))
    }

    func testRejectsUnsupportedJourneySchemaEvenWhenManifestAgrees() throws {
        var bytes = try fixtureBytes(named: "animation-event")
        let versionOne = Data("\"schemaVersion\":1".utf8)
        let versionTwo = Data("\"schemaVersion\":2".utf8)
        var searchStart = bytes.startIndex
        while let range = bytes.range(
            of: versionOne,
            options: [],
            in: searchStart..<bytes.endIndex
        ) {
            bytes.replaceSubrange(range, with: versionTwo)
            searchStart = range.upperBound
        }

        XCTAssertThrowsError(try NuxPackageReader.read(bytes)) {
            XCTAssertEqual(
                $0 as? NuxPackageReaderError,
                .unsupportedJourneyVersion(2)
            )
        }
    }
}

final class ExperienceTrustRootsTests: XCTestCase {
    func testDevelopmentUsesOnlyThePinnedTestKey() throws {
        let keys = try ExperienceTrustRoots.keys(for: .development)
        XCTAssertEqual(keys.map(\.keyId), ["TEST_ONLY_DEV_KEYPAIR"])
        XCTAssertEqual(keys.first?.ed25519PublicKeyBytes.count, 32)
    }

    func testStagingAndProductionUseTheSharedNuxieKey() throws {
        for environment in [Environment.staging, .production] {
            let keys = try ExperienceTrustRoots.keys(for: environment)
            XCTAssertEqual(keys.map(\.keyId), ["nuxie-experience-2026-07"])
            XCTAssertEqual(keys.first?.ed25519PublicKeyBytes.count, 32)
            XCTAssertNotEqual(
                keys.first?.ed25519PublicKeyBytes,
                try ExperienceTrustRoots.keys(for: .development).first?.ed25519PublicKeyBytes,
                "provisioned slots must never inherit the dev key"
            )
        }
    }

    func testCustomSlotFailsClosed() {
        XCTAssertThrowsError(try ExperienceTrustRoots.keys(for: .custom))
    }
}

final class ExperiencePackageStoreTests: XCTestCase {
    func testLoadsPackageAndSharedExternalAssetFromFileDelivery() async throws {
        let temporary = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let root = try fixtureRoot(named: "external-image")
        let remote = try remotePointer(at: root)
        let store = try makeStore(at: temporary)

        let loaded = try await store.getOrDownloadPackage(
            for: remote,
            assetBaseURL: root
        )

        XCTAssertEqual(loaded.source, .download)
        XCTAssertEqual(loaded.manifest.identity.experienceId, remote.experienceId)
        XCTAssertEqual(loaded.assetURLsByRiveUniqueName.count, 1)
        XCTAssertTrue(
            loaded.assetURLsByRiveUniqueName.values.allSatisfy {
                $0.deletingLastPathComponent()
                    == temporary.appendingPathComponent("assets", isDirectory: true)
            }
        )
    }

    func testRefusesWrongPointerHash() async throws {
        let temporary = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let root = try fixtureRoot(named: "animation-event")
        let valid = try remotePointer(at: root)
        let remote = RemoteExperience(
            experienceId: valid.experienceId,
            versionId: valid.versionId,
            buildId: valid.buildId,
            artifact: RemoteExperienceArtifact(
                url: valid.artifact.url,
                sha256: String(repeating: "0", count: 64),
                sizeBytes: valid.artifact.sizeBytes
            ),
            name: valid.name,
            reentry: valid.reentry,
            publishedAt: valid.publishedAt
        )

        await XCTAssertThrowsErrorAsyncPackage {
            _ = try await self.makeStore(at: temporary).getOrDownloadPackage(
                for: remote,
                assetBaseURL: root
            )
        }
    }

    func testReverifiesCachedPackageOnEveryOpen() async throws {
        let temporary = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let root = try fixtureRoot(named: "animation-event")
        let remote = try remotePointer(at: root)
        let store = try makeStore(at: temporary)
        _ = try await store.getOrDownloadPackage(for: remote, assetBaseURL: root)

        let cached = temporary
            .appendingPathComponent("packages", isDirectory: true)
            .appendingPathComponent("\(remote.artifact.sha256).nux")
        var bytes = try Data(contentsOf: cached)
        bytes[bytes.index(before: bytes.endIndex)] ^= 0x01
        try bytes.write(to: cached, options: .atomic)

        await XCTAssertThrowsErrorAsyncPackage {
            _ = try await store.getCachedPackage(for: remote, assetBaseURL: root)
        }
    }

    func testRefusesPackageIdentityMismatch() async throws {
        let temporary = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let root = try fixtureRoot(named: "animation-event")
        let valid = try remotePointer(at: root)
        let replayed = RemoteExperience(
            experienceId: "different-experience",
            versionId: valid.versionId,
            buildId: valid.buildId,
            artifact: valid.artifact,
            name: valid.name,
            reentry: valid.reentry,
            publishedAt: valid.publishedAt
        )

        await XCTAssertThrowsErrorAsyncPackage {
            _ = try await self.makeStore(at: temporary).getOrDownloadPackage(
                for: replayed,
                assetBaseURL: root
            )
        }
    }

    func testConcurrentLoadsRemainBoundToEachPointersIdentity() async throws {
        let temporary = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let root = try fixtureRoot(named: "animation-event")
        let valid = try remotePointer(at: root)
        let replayed = RemoteExperience(
            experienceId: "different-experience",
            versionId: valid.versionId,
            buildId: valid.buildId,
            artifact: valid.artifact,
            name: valid.name,
            reentry: valid.reentry,
            publishedAt: valid.publishedAt
        )
        let store = try makeStore(at: temporary)

        async let validLoad = store.getOrDownloadPackage(
            for: valid,
            assetBaseURL: root
        )
        async let replayedLoad: Result<LoadedExperiencePackage, Error> = {
            do {
                return .success(
                    try await store.getOrDownloadPackage(
                        for: replayed,
                        assetBaseURL: root
                    )
                )
            } catch {
                return .failure(error)
            }
        }()

        let (loaded, replayedResult) = try await (validLoad, replayedLoad)
        XCTAssertEqual(loaded.remote.experienceId, valid.experienceId)
        XCTAssertThrowsError(try replayedResult.get())
    }

    func testRefusesExternalAssetDigestMismatch() async throws {
        let temporary = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let copiedFixture = temporary.appendingPathComponent("fixture", isDirectory: true)
        try FileManager.default.copyItem(
            at: fixtureRoot(named: "external-image"),
            to: copiedFixture
        )
        let package = try NuxPackageReader.read(
            Data(contentsOf: copiedFixture.appendingPathComponent("experience.nux"))
        )
        guard case .external(let key) = try XCTUnwrap(
            package.manifest.assets.images.first
        ).location else {
            return XCTFail("Expected external image fixture")
        }
        try Data([0]).write(to: copiedFixture.appendingPathComponent(key), options: .atomic)
        let remote = try remotePointer(at: copiedFixture)

        await XCTAssertThrowsErrorAsyncPackage {
            _ = try await self.makeStore(at: temporary).getOrDownloadPackage(
                for: remote,
                assetBaseURL: copiedFixture
            )
        }
    }

    func testEvictsPackagesOutsideCurrentProfile() async throws {
        let temporary = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let firstRoot = try fixtureRoot(named: "animation-event")
        let secondRoot = try fixtureRoot(named: "multi-screen")
        let first = try remotePointer(at: firstRoot)
        let second = try remotePointer(at: secondRoot)
        let store = try makeStore(at: temporary)
        _ = try await store.getOrDownloadPackage(for: first, assetBaseURL: firstRoot)
        _ = try await store.getOrDownloadPackage(for: second, assetBaseURL: secondRoot)

        await store.evictUnreferencedPackages(retaining: [second])

        let packageDirectory = temporary.appendingPathComponent("packages")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: packageDirectory.appendingPathComponent("\(first.artifact.sha256).nux").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: packageDirectory.appendingPathComponent("\(second.artifact.sha256).nux").path
            )
        )
    }

    private func makeStore(at root: URL) throws -> ExperiencePackageStore {
        ExperiencePackageStore(
            cacheDirectory: root.appendingPathComponent("packages"),
            assetCacheDirectory: root.appendingPathComponent("assets"),
            authorizationKeys: try ExperienceTrustRoots.keys(for: .development)
        )
    }
}

private func fixtureBytes(named name: String) throws -> Data {
    try Data(
        contentsOf: fixtureRoot(named: name).appendingPathComponent("experience.nux")
    )
}

private func fixtureRoot(named name: String) throws -> URL {
    let sourceRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("ExperienceRuntimeHostApp/Fixtures", isDirectory: true)
        .appendingPathComponent(name, isDirectory: true)
    let bundleRoot = Bundle(for: ExperiencePackageStoreTests.self).resourceURL?
        .appendingPathComponent("Fixtures", isDirectory: true)
        .appendingPathComponent(name, isDirectory: true)
    for candidate in [bundleRoot, sourceRoot].compactMap({ $0 }) {
        if FileManager.default.fileExists(
            atPath: candidate.appendingPathComponent("experience.nux").path
        ) {
            return candidate
        }
    }
    throw CocoaError(.fileNoSuchFile)
}

private func remotePointer(at root: URL) throws -> RemoteExperience {
    let packageURL = root.appendingPathComponent("experience.nux")
    let bytes = try Data(contentsOf: packageURL)
    let package = try NuxPackageReader.read(bytes)
    return RemoteExperience(
        experienceId: package.manifest.identity.experienceId,
        versionId: package.manifest.identity.buildId,
        buildId: package.manifest.identity.buildId,
        artifact: RemoteExperienceArtifact(
            url: packageURL.absoluteString,
            sha256: SHA256Provider.hexDigest(bytes),
            sizeBytes: bytes.count
        ),
        name: package.manifest.identity.experienceId,
        reentry: .everyTime,
        publishedAt: "2026-07-29T00:00:00Z"
    )
}

private func temporaryDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("nux-package-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try! FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    return directory
}

private func XCTAssertThrowsErrorAsyncPackage(
    _ expression: @escaping () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        // Expected.
    }
}

private extension UInt32 {
    var littleEndianBytes: [UInt8] {
        withUnsafeBytes(of: littleEndian, Array.init)
    }
}
