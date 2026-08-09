import Foundation
import XCTest
import NuxieRuntime
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

final class NuxPackageReaderTests: XCTestCase {
    func testSwiftContractMatchesCanonicalVersionedFixture() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(
            contentsOf: root.appendingPathComponent(
                "fixtures/nux/acquisition-contract-v1.json"
            )
        )
        let contract = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let limits = try XCTUnwrap(contract["limits"] as? [String: Int])
        let errors = try XCTUnwrap(contract["errors"] as? [String: String])

        XCTAssertEqual(
            contract["contractVersion"] as? Int,
            NuxPackageLimits.acquisitionContractVersion
        )
        XCTAssertEqual(contract["containerVersion"] as? Int, 1)
        XCTAssertEqual(limits["packageBytes"], NuxPackageLimits.packageBytes)
        XCTAssertEqual(limits["manifestBytes"], NuxPackageLimits.manifestBytes)
        XCTAssertEqual(limits["journeyBytes"], NuxPackageLimits.journeyBytes)
        XCTAssertEqual(limits["signatureBytes"], NuxPackageLimits.signatureBytes)
        XCTAssertEqual(limits["memberCount"], NuxPackageLimits.memberCount)
        XCTAssertEqual(limits["externalAssetBytes"], NuxPackageLimits.externalAssetBytes)
        XCTAssertEqual(limits["externalAssetCount"], NuxPackageLimits.externalAssetCount)
        XCTAssertEqual(
            limits["externalAssetTotalBytes"],
            NuxPackageLimits.externalAssetTotalBytes
        )
        XCTAssertEqual(limits["assetUniqueNameBytes"], NuxPackageLimits.assetUniqueNameBytes)
        XCTAssertEqual(limits["assetSourceKeyBytes"], NuxPackageLimits.assetSourceKeyBytes)
        XCTAssertEqual(
            errors["invalidContainer"],
            NuxPackageReaderError.badMagic.contractCode
        )
        XCTAssertEqual(
            errors["unsupportedVersion"],
            NuxPackageReaderError.unsupportedVersion(2).contractCode
        )
        XCTAssertEqual(
            errors["missingMember"],
            NuxPackageReaderError.missingMember("fixture").contractCode
        )
        XCTAssertEqual(
            errors["invalidManifest"],
            NuxPackageReaderError.invalidManifest.contractCode
        )
        XCTAssertEqual(
            errors["invalidExternalAsset"],
            NuxPackageReaderError.invalidExternalAsset("fixture").contractCode
        )
        XCTAssertEqual(
            errors["limitExceeded"],
            NuxPackageReaderError.memberTooLarge("fixture").contractCode
        )
        XCTAssertEqual(
            errors["identityMismatch"],
            ExperiencePackageStoreError.identityMismatch.contractCode
        )
        XCTAssertEqual(
            errors["missingRequiredAsset"],
            ExperiencePackageStoreError.requiredAssetUnavailable("fixture").contractCode
        )
        XCTAssertEqual(
            contract["requiredMembers"] as? [String],
            ["manifest", "signature", "scene", "journey"]
        )
        XCTAssertEqual(
            Set(contract["permittedPreAuthenticationFields"] as? [String] ?? []),
            Set([
                "identity.experienceId",
                "identity.buildId",
                "assets.images[].location",
                "assets.images[].riveAssetId",
                "assets.images[].riveUniqueName",
                "assets.images[].sha256",
                "assets.images[].sizeBytes",
                "assets.images[].required",
                "assets.fonts[].location",
                "assets.fonts[].riveAssetId",
                "assets.fonts[].riveUniqueName",
                "assets.fonts[].sha256",
                "assets.fonts[].sizeBytes",
                "assets.fonts[].required",
            ])
        )
        XCTAssertEqual(
            Set(contract["forbiddenPreAuthenticationUses"] as? [String] ?? []),
            Set([
                "journey hydration",
                "product lookup",
                "script execution",
                "screen or text-input hydration",
                "runtime execution",
            ])
        )
        let phaseCases = try XCTUnwrap(contract["phaseCases"] as? [[String: String]])
        XCTAssertEqual(
            phaseCases,
            [
                ["name": "valid-package", "acquisition": "success", "authentication": "success"],
                [
                    "name": "corrupt-package",
                    "acquisition": "acquisition.invalid_container",
                    "authentication": "not_run",
                ],
                [
                    "name": "oversized-package",
                    "acquisition": "acquisition.limit_exceeded",
                    "authentication": "not_run",
                ],
                [
                    "name": "identity-mismatch",
                    "acquisition": "acquisition.identity_mismatch",
                    "authentication": "not_run",
                ],
                [
                    "name": "missing-required-asset",
                    "acquisition": "acquisition.required_asset_missing",
                    "authentication": "not_run",
                ],
            ]
        )
    }

    func testReadsOnlyAcquisitionMetadataWithoutInterpretingExecutionContent() throws {
        let bytes = try fixtureBytes(named: "animation-event")
        let package = try NuxPackageReader.read(bytes)

        XCTAssertEqual(package.metadata.contractVersion, 1)
        XCTAssertEqual(
            package.metadata.identity.experienceId,
            "nuxie-sdk-fixture-animation-event"
        )
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

        let oversized = Data(count: NuxPackageLimits.packageBytes + 1)
        XCTAssertThrowsError(try NuxPackageReader.read(oversized)) {
            XCTAssertEqual(
                ($0 as? NuxPackageReaderError)?.contractCode,
                "acquisition.limit_exceeded"
            )
        }
    }

    func testAcquisitionDoesNotDecodeJourneyExecutionContent() throws {
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

        let acquisition = try NuxPackageReader.read(bytes)
        XCTAssertEqual(acquisition.metadata.contractVersion, 1)
    }

    func testExternalAssetIdentityUsesCanonicalLowercaseContentAddress() throws {
        var bytes = try fixtureBytes(named: "external-image")
        let lowercase = Data(".png\"".utf8)
        let uppercase = Data(".PNG\"".utf8)
        let range = try XCTUnwrap(bytes.range(of: lowercase))
        bytes.replaceSubrange(range, with: uppercase)

        XCTAssertThrowsError(try NuxPackageReader.read(bytes)) {
            XCTAssertEqual(
                ($0 as? NuxPackageReaderError)?.contractCode,
                "acquisition.invalid_external_asset"
            )
        }
    }

    func testAssetMutationVectorsUseStableErrorCodes() throws {
        let digest = String(repeating: "a", count: 64)
        try assertAcquisitionError(
            assets: [acquisitionAsset(sha256: "G\(digest.dropFirst())")],
            code: "acquisition.invalid_external_asset"
        )
        try assertAcquisitionError(
            assets: [acquisitionAsset(sizeBytes: -1)],
            code: "acquisition.invalid_manifest"
        )
        try assertAcquisitionError(
            assets: [
                acquisitionAsset(
                    key: "assets/sha256/\(digest).extra.png",
                    sha256: digest
                ),
            ],
            code: "acquisition.invalid_external_asset"
        )
        try assertAcquisitionError(
            assets: (0...NuxPackageLimits.externalAssetCount).map {
                acquisitionAsset(index: $0, sha256: digest)
            },
            code: "acquisition.limit_exceeded"
        )
        try assertAcquisitionError(
            assets: (0..<5).map {
                acquisitionAsset(
                    index: $0,
                    sha256: digest,
                    sizeBytes: NuxPackageLimits.externalAssetBytes
                )
            },
            code: "acquisition.limit_exceeded"
        )
    }

    private func assertAcquisitionError(
        assets: [[String: Any]],
        code: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let manifest = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "identity": ["experienceId": "fixture", "buildId": "build"],
            "assets": ["images": assets, "fonts": []],
        ])
        XCTAssertThrowsError(
            try NuxPackageReader.read(acquisitionContainer(manifest: manifest)),
            file: file,
            line: line
        ) {
            XCTAssertEqual(
                ($0 as? NuxPackageReaderError)?.contractCode,
                code,
                file: file,
                line: line
            )
        }
    }

    private func acquisitionAsset(
        index: Int = 0,
        key: String? = nil,
        sha256: String = String(repeating: "a", count: 64),
        sizeBytes: Int = 1
    ) -> [String: Any] {
        [
            "location": [
                "kind": "external",
                "key": key ?? "assets/sha256/\(sha256).png",
            ],
            "riveAssetId": index,
            "riveUniqueName": "asset-\(index)",
            "sha256": sha256,
            "sizeBytes": sizeBytes,
            "required": true,
        ]
    }
}

final class ExperienceTrustRootsTests: XCTestCase {
    func testDevelopmentUsesOnlyThePinnedTestKey() throws {
        let keys = try ExperienceTrustRoots.keys(for: .development)
        XCTAssertEqual(keys.map(\.keyID), ["TEST_ONLY_DEV_KEYPAIR"])
        XCTAssertEqual(keys.first?.ed25519PublicKeyBytes.count, 32)
    }

    func testStagingAndProductionUseTheSharedNuxieKey() throws {
        for environment in [Environment.staging, .production] {
            let keys = try ExperienceTrustRoots.keys(for: environment)
            XCTAssertEqual(keys.map(\.keyID), ["nuxie-experience-2026-07"])
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
        XCTAssertEqual(loaded.acquisition.metadata.identity.experienceId, remote.experienceId)
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
        async let replayedLoad: Result<AcquiredExperiencePackage, Error> = {
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

    func testRefusesMissingRequiredExternalAsset() async throws {
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
        let key = try XCTUnwrap(package.metadata.externalAssets.first).key
        try FileManager.default.removeItem(at: copiedFixture.appendingPathComponent(key))
        let remote = try remotePointer(at: copiedFixture)

        await XCTAssertThrowsErrorAsyncPackage(
            expectedContractCode: "acquisition.required_asset_missing"
        ) {
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

#if os(iOS) && !targetEnvironment(macCatalyst)
@MainActor
final class ExperiencePackageTrustPhaseTests: XCTestCase {
    func testValidPackageCrossesAcquisitionThenAuthenticationBeforeHydration() async throws {
        let temporary = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let root = try fixtureRoot(named: "animation-event")
        let remote = try remotePointer(at: root)
        let packageStore = ExperiencePackageStore(
            cacheDirectory: temporary.appendingPathComponent("packages"),
            assetCacheDirectory: temporary.appendingPathComponent("assets"),
            authorizationKeys: try ExperienceTrustRoots.keys(for: .development)
        )
        let authenticator = TrustPhaseAuthenticationSpy()
        let store = ExperienceStore(
            api: MockNuxieApi(),
            productService: ProductService(),
            packageStore: packageStore,
            packageAuthenticator: authenticator
        )
        await store.registerExperiences([remote], assetBaseURL: root)

        let experience = try await store.experience(
            experienceId: remote.experienceId,
            versionId: remote.versionId
        )
        XCTAssertEqual(experience.id, remote.experienceId)
        XCTAssertEqual(authenticator.callCount, 1)
    }

    func testCanonicalPhaseCasesStopBeforeAuthenticationOnAcquisitionFailure() async throws {
        try await assertExperienceStorePhase(
            named: "corrupt-package",
            expectedCode: "acquisition.invalid_container"
        ) { root, remote in
            let packageURL = root.appendingPathComponent("experience.nux")
            var bytes = try Data(contentsOf: packageURL)
            bytes[bytes.startIndex] ^= 0xff
            try bytes.write(to: packageURL, options: .atomic)
            return pointer(remote, packageBytes: bytes)
        }

        try await assertExperienceStorePhase(
            named: "oversized-package",
            expectedCode: "acquisition.limit_exceeded"
        ) { root, remote in
            let bytes = Data(count: NuxPackageLimits.packageBytes + 1)
            try bytes.write(
                to: root.appendingPathComponent("experience.nux"),
                options: .atomic
            )
            return pointer(remote, packageBytes: bytes)
        }

        try await assertExperienceStorePhase(
            named: "identity-mismatch",
            expectedCode: "acquisition.identity_mismatch"
        ) { _, remote in
            RemoteExperience(
                experienceId: "replayed-\(remote.experienceId)",
                versionId: remote.versionId,
                buildId: remote.buildId,
                artifact: remote.artifact,
                name: remote.name,
                reentry: remote.reentry,
                publishedAt: remote.publishedAt
            )
        }

        try await assertExperienceStorePhase(
            named: "missing-required-asset",
            fixture: "external-image",
            expectedCode: "acquisition.required_asset_missing"
        ) { root, remote in
            let acquisition = try NuxPackageReader.read(
                Data(contentsOf: root.appendingPathComponent("experience.nux"))
            )
            let key = try XCTUnwrap(acquisition.metadata.externalAssets.first?.key)
            try FileManager.default.removeItem(at: root.appendingPathComponent(key))
            return remote
        }
    }

    private func assertExperienceStorePhase(
        named: String,
        fixture: String = "animation-event",
        expectedCode: String,
        mutate: (URL, RemoteExperience) throws -> RemoteExperience
    ) async throws {
        let temporary = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let root = temporary.appendingPathComponent("fixture", isDirectory: true)
        try FileManager.default.copyItem(at: fixtureRoot(named: fixture), to: root)
        let remote = try mutate(root, remotePointer(at: root))
        let authenticator = TrustPhaseAuthenticationSpy()
        let packageStore = ExperiencePackageStore(
            cacheDirectory: temporary.appendingPathComponent("packages"),
            assetCacheDirectory: temporary.appendingPathComponent("assets"),
            authorizationKeys: try ExperienceTrustRoots.keys(for: .development)
        )
        let store = ExperienceStore(
            api: MockNuxieApi(),
            productService: ProductService(),
            packageStore: packageStore,
            packageAuthenticator: authenticator
        )
        await store.registerExperiences([remote], assetBaseURL: root)

        do {
            _ = try await store.experience(
                experienceId: remote.experienceId,
                versionId: remote.versionId
            )
            XCTFail("\(named) should fail during acquisition")
        } catch {
            XCTAssertEqual(acquisitionContractCode(for: error), expectedCode, named)
        }
        XCTAssertEqual(authenticator.callCount, 0, "\(named) must not authenticate")
    }
}
#endif

@MainActor
private final class TrustPhaseAuthenticationSpy: @unchecked Sendable,
    ExperiencePackageAuthenticating {
    private(set) var callCount = 0

    func authenticate(_ package: AcquiredExperiencePackage) async throws
        -> AuthenticatedRuntimePayload {
        callCount += 1
        return try await SwiftExperiencePackageAuthenticator().authenticate(package)
    }
}

private func pointer(
    _ remote: RemoteExperience,
    packageBytes: Data
) -> RemoteExperience {
    RemoteExperience(
        experienceId: remote.experienceId,
        versionId: remote.versionId,
        buildId: remote.buildId,
        artifact: RemoteExperienceArtifact(
            url: remote.artifact.url,
            sha256: SHA256Provider.hexDigest(packageBytes),
            sizeBytes: packageBytes.count,
            packageVersion: remote.artifact.packageVersion
        ),
        name: remote.name,
        reentry: remote.reentry,
        publishedAt: remote.publishedAt
    )
}

private func acquisitionContractCode(for error: Error) -> String? {
    if let error = error as? NuxPackageReaderError {
        return error.contractCode
    }
    if let error = error as? ExperiencePackageStoreError {
        return error.contractCode
    }
    return nil
}

private func acquisitionContainer(manifest: Data) -> Data {
    let members: [(String, Data)] = [
        ("manifest", manifest),
        ("signature", Data([1])),
        ("scene", Data([1])),
        ("journey", Data([1])),
    ]
    let tableBytes = members.reduce(0) { $0 + 2 + $1.0.utf8.count + 16 }
    func aligned(_ value: Int) -> Int { ((value + 15) / 16) * 16 }
    var nextOffset = aligned(16 + tableBytes)
    let offsets = members.map { member -> Int in
        defer { nextOffset = aligned(nextOffset + member.1.count) }
        return nextOffset
    }

    var result = Data([0x89, 0x4e, 0x55, 0x58, 0x0d, 0x0a, 0x1a, 0x0a])
    result.appendLittleEndian(UInt32(1))
    result.appendLittleEndian(UInt32(members.count))
    for ((name, payload), offset) in zip(members, offsets) {
        let nameBytes = Data(name.utf8)
        result.appendLittleEndian(UInt16(nameBytes.count))
        result.append(nameBytes)
        result.appendLittleEndian(UInt64(offset))
        result.appendLittleEndian(UInt64(payload.count))
    }
    for ((_, payload), offset) in zip(members, offsets) {
        result.append(Data(repeating: 0, count: offset - result.count))
        result.append(payload)
    }
    return result
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
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
        experienceId: package.metadata.identity.experienceId,
        versionId: package.metadata.identity.buildId,
        buildId: package.metadata.identity.buildId,
        artifact: RemoteExperienceArtifact(
            url: packageURL.absoluteString,
            sha256: SHA256Provider.hexDigest(bytes),
            sizeBytes: bytes.count
        ),
        name: package.metadata.identity.experienceId,
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
    expectedContractCode: String? = nil,
    _ expression: @escaping () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        if let expectedContractCode {
            XCTAssertEqual(
                (error as? ExperiencePackageStoreError)?.contractCode,
                expectedContractCode,
                file: file,
                line: line
            )
        }
    }
}

private extension UInt32 {
    var littleEndianBytes: [UInt8] {
        withUnsafeBytes(of: littleEndian, Array.init)
    }
}
