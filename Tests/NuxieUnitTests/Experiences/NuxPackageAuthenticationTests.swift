import CryptoKit
import Foundation
import XCTest
@testable import Nuxie

final class NuxPackageAuthenticationTests: XCTestCase {
    func testAuthenticatesSignedFixtureIntoOwnedRuntimePayload() async throws {
        let fixture = try fixtureRoot(named: "animation-event")
        let packageURL = fixture.appendingPathComponent("experience.nux")
        let packageBytes = try Data(contentsOf: packageURL)
        XCTAssertEqual(
            SHA256Provider.hexDigest(packageBytes),
            "b9189d08cb77b87bbdcc90021efd05a54ab653f23ee00a0a5f95faaff1acc782",
            "The language-neutral signed golden vector changed without review"
        )
        let acquisition = try NuxPackageReader.read(packageBytes)
        let remote = RemoteExperience(
            experienceId: acquisition.metadata.identity.experienceId,
            versionId: acquisition.metadata.identity.buildId,
            buildId: acquisition.metadata.identity.buildId,
            artifact: RemoteExperienceArtifact(
                url: packageURL.absoluteString,
                sha256: SHA256Provider.hexDigest(packageBytes),
                sizeBytes: packageBytes.count
            ),
            name: "animation-event",
            reentry: .everyTime,
            publishedAt: "2026-07-29T00:00:00Z"
        )
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("nux-package-authentication-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cache) }
        let store = ExperiencePackageStore(
            cacheDirectory: cache.appendingPathComponent("packages", isDirectory: true),
            assetCacheDirectory: cache.appendingPathComponent("assets", isDirectory: true),
            authorizationKeys: try ExperienceTrustRoots.keys(for: .development)
        )
        let acquired = try await store.getOrDownloadPackage(
            for: remote,
            assetBaseURL: fixture
        )

        let payload = try await SwiftExperiencePackageAuthenticator().authenticate(acquired)

        XCTAssertEqual(payload.authenticatedKeyID, "TEST_ONLY_DEV_KEYPAIR")
        XCTAssertEqual(payload.manifest.identity.experienceId, remote.experienceId)
        XCTAssertEqual(payload.manifest.identity.buildId, remote.buildId)
        XCTAssertEqual(payload.manifest.entry.screenId, "screen")
        XCTAssertEqual(payload.journey.schemaVersion, 1)
        XCTAssertTrue(payload.sceneBytes.starts(with: Data("RIVE".utf8)))
        XCTAssertTrue(payload.assets.isEmpty)
    }

    func testRejectsBadSignatureBeforeDecodingMalformedJourney() async throws {
        let fixture = try fixtureRoot(named: "animation-event")
        var bytes = try Data(
            contentsOf: fixture.appendingPathComponent("experience.nux")
        )
        let signatureMarker = Data("\"signatureBase64\":\"".utf8)
        let signatureField = try XCTUnwrap(bytes.range(of: signatureMarker))
        let signatureByte = signatureField.upperBound
        bytes[signatureByte] = bytes[signatureByte] == 0x41 ? 0x42 : 0x41
        let original = try acquiredPackage(
            bytes: try Data(contentsOf: fixture.appendingPathComponent("experience.nux")),
            fixture: fixture
        )
        let acquired = replacingPackageBytes(original, with: bytes)
        let decoder = JourneyDecoderSpy()

        await XCTAssertThrowsErrorAsync {
            _ = try await SwiftExperiencePackageAuthenticator(
                journeyDecoder: { try decoder.decode($0) }
            ).authenticate(acquired)
        } verify: {
            XCTAssertEqual(
                ($0 as? ExperiencePackageAuthenticationError)?.contractCode,
                "package.signature.bad_signature"
            )
        }
        XCTAssertEqual(decoder.callCount, 0)
    }

    func testRejectsMissingSignatureWithCanonicalAuthenticationCode() async throws {
        let fixture = try fixtureRoot(named: "animation-event")
        let originalBytes = try Data(
            contentsOf: fixture.appendingPathComponent("experience.nux")
        )
        let original = try acquiredPackage(bytes: originalBytes, fixture: fixture)
        var missingSignature = originalBytes
        let memberName = try XCTUnwrap(missingSignature.range(of: Data("signature".utf8)))
        missingSignature[memberName.lowerBound] = Character("x").asciiValue!
        let decoder = JourneyDecoderSpy()

        await XCTAssertThrowsErrorAsync {
            _ = try await SwiftExperiencePackageAuthenticator(
                journeyDecoder: { try decoder.decode($0) }
            ).authenticate(self.replacingPackageBytes(original, with: missingSignature))
        } verify: {
            XCTAssertEqual(
                ($0 as? ExperiencePackageAuthenticationError)?.contractCode,
                "package.signature.missing"
            )
        }
        XCTAssertEqual(decoder.callCount, 0)
    }

    func testRejectsOversizedExactPackageBeforeAuthenticationWork() async throws {
        let fixture = try fixtureRoot(named: "animation-event")
        let original = try acquiredPackage(
            bytes: try Data(contentsOf: fixture.appendingPathComponent("experience.nux")),
            fixture: fixture
        )
        let decoder = JourneyDecoderSpy()
        let oversized = replacingPackageBytes(
            original,
            with: Data(count: NuxPackageLimits.packageBytes + 1)
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await SwiftExperiencePackageAuthenticator(
                journeyDecoder: { try decoder.decode($0) }
            ).authenticate(oversized)
        } verify: {
            XCTAssertEqual(
                ($0 as? NuxPackageReaderError)?.contractCode,
                "acquisition.limit_exceeded"
            )
        }
        XCTAssertEqual(decoder.callCount, 0)
    }

    func testRejectsNonIntegerJourneySchemaBeforeSignatureAndAssetWork() async throws {
        let fixture = try fixtureRoot(named: "animation-event")
        let originalBytes = try Data(
            contentsOf: fixture.appendingPathComponent("experience.nux")
        )
        let original = try acquiredPackage(bytes: originalBytes, fixture: fixture)

        for schemaValue in ["true", "1.5"] {
            let bytes = try resigningPackage(
                originalBytes,
                replacingJourneySchemaWith: schemaValue
            )
            let decoder = JourneyDecoderSpy()

            await XCTAssertThrowsErrorAsync {
                _ = try await SwiftExperiencePackageAuthenticator(
                    journeyDecoder: { try decoder.decode($0) }
                ).authenticate(self.replacingPackageBytes(original, with: bytes))
            } verify: {
                XCTAssertEqual(
                    ($0 as? ExperiencePackageAuthenticationError)?.contractCode,
                    "package.manifest.invalid"
                )
            }
            XCTAssertEqual(decoder.callCount, 0)
        }
    }

    func testRejectsUnknownSignatureKeyBeforeJourneyDecode() async throws {
        let fixture = try fixtureRoot(named: "animation-event")
        let originalBytes = try Data(
            contentsOf: fixture.appendingPathComponent("experience.nux")
        )
        var bytes = originalBytes
        let key = try XCTUnwrap(bytes.range(of: Data("TEST_ONLY_DEV_KEYPAIR".utf8)))
        bytes.replaceSubrange(key, with: Data("UNKNOWN_TEST_KEY_0000".utf8))
        let original = try acquiredPackage(bytes: originalBytes, fixture: fixture)
        let acquired = replacingPackageBytes(original, with: bytes)
        let decoder = JourneyDecoderSpy()

        await XCTAssertThrowsErrorAsync {
            _ = try await SwiftExperiencePackageAuthenticator(
                journeyDecoder: { try decoder.decode($0) }
            ).authenticate(acquired)
        } verify: {
            XCTAssertEqual(
                ($0 as? ExperiencePackageAuthenticationError)?.contractCode,
                "package.signature.unknown_key"
            )
        }
        XCTAssertEqual(decoder.callCount, 0)
    }

    func testAuthenticatesAndOwnsRequiredExternalAssetBytes() async throws {
        let fixture = try fixtureRoot(named: "external-image")
        let packageURL = fixture.appendingPathComponent("experience.nux")
        let bytes = try Data(contentsOf: packageURL)
        let parsed = try NuxPackageReader.read(bytes)
        let remote = RemoteExperience(
            experienceId: parsed.metadata.identity.experienceId,
            versionId: parsed.metadata.identity.buildId,
            buildId: parsed.metadata.identity.buildId,
            artifact: RemoteExperienceArtifact(
                url: packageURL.absoluteString,
                sha256: SHA256Provider.hexDigest(bytes),
                sizeBytes: bytes.count
            ),
            name: "external-image",
            reentry: .everyTime,
            publishedAt: "2026-07-29T00:00:00Z"
        )
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let store = ExperiencePackageStore(
            cacheDirectory: temporary.appendingPathComponent("packages"),
            assetCacheDirectory: temporary.appendingPathComponent("assets"),
            authorizationKeys: try ExperienceTrustRoots.keys(for: .development)
        )
        let acquired = try await store.getOrDownloadPackage(
            for: remote,
            assetBaseURL: fixture
        )

        let payload = try await SwiftExperiencePackageAuthenticator().authenticate(acquired)

        let asset = try XCTUnwrap(payload.assets.first)
        XCTAssertEqual(asset.kind, .image)
        XCTAssertEqual(
            asset.riveUniqueName,
            parsed.metadata.externalAssets.first?.riveUniqueName
        )
        XCTAssertEqual(asset.sha256, SHA256Provider.hexDigest(try XCTUnwrap(asset.bytes)))
    }

    func testEmbeddedAssetMayExceedExternalAssetByteLimit() async throws {
        let fixture = try fixtureRoot(named: "animation-event")
        let originalBytes = try Data(
            contentsOf: fixture.appendingPathComponent("experience.nux")
        )
        let embeddedBytes = Data(count: NuxPackageLimits.externalAssetBytes + 1)
        let bytes = try resigningPackage(
            originalBytes,
            addingEmbeddedImage: embeddedBytes
        )
        let package = try acquiredPackage(bytes: bytes, fixture: fixture)

        let payload = try await SwiftExperiencePackageAuthenticator().authenticate(package)

        let asset = try XCTUnwrap(payload.assets.first)
        XCTAssertEqual(asset.kind, .image)
        XCTAssertEqual(asset.riveUniqueName, "large-embedded")
        XCTAssertEqual(asset.bytes?.count, embeddedBytes.count)
    }

    func testAuthenticationRechecksRequiredExternalAssetEvidenceBeforeJourneyDecode() async throws {
        let fixture = try fixtureRoot(named: "external-image")
        let bytes = try Data(contentsOf: fixture.appendingPathComponent("experience.nux"))
        let parsed = try NuxPackageReader.read(bytes)
        let valid = try acquiredPackage(bytes: bytes, fixture: fixture)
        let missing = AcquiredExperiencePackage(
            remote: valid.remote,
            packageURL: valid.packageURL,
            packageBytes: valid.packageBytes,
            acquisition: valid.acquisition,
            assetURLsByRiveUniqueName: [:],
            source: valid.source,
            authorizationKeys: valid.authorizationKeys
        )
        let decoder = JourneyDecoderSpy()

        await XCTAssertThrowsErrorAsync {
            _ = try await SwiftExperiencePackageAuthenticator(
                journeyDecoder: { try decoder.decode($0) }
            ).authenticate(missing)
        } verify: {
            XCTAssertEqual(
                $0 as? ExperiencePackageAuthenticationError,
                .invalidAsset(parsed.metadata.externalAssets.first?.riveUniqueName ?? "")
            )
        }
        XCTAssertEqual(decoder.callCount, 0)
    }

    func testRejectsSignedIdentityReplayBeforeJourneyDecode() async throws {
        let fixture = try fixtureRoot(named: "animation-event")
        let bytes = try Data(contentsOf: fixture.appendingPathComponent("experience.nux"))
        let original = try acquiredPackage(bytes: bytes, fixture: fixture)
        let replayed = AcquiredExperiencePackage(
            remote: RemoteExperience(
                experienceId: "replayed-experience",
                versionId: original.remote.versionId,
                buildId: original.remote.buildId,
                artifact: original.remote.artifact,
                name: original.remote.name,
                reentry: original.remote.reentry,
                publishedAt: original.remote.publishedAt
            ),
            packageURL: original.packageURL,
            packageBytes: original.packageBytes,
            acquisition: original.acquisition,
            assetURLsByRiveUniqueName: original.assetURLsByRiveUniqueName,
            source: original.source,
            authorizationKeys: original.authorizationKeys
        )
        let decoder = JourneyDecoderSpy()

        await XCTAssertThrowsErrorAsync {
            _ = try await SwiftExperiencePackageAuthenticator(
                journeyDecoder: { try decoder.decode($0) }
            ).authenticate(replayed)
        } verify: {
            XCTAssertEqual($0 as? ExperiencePackageAuthenticationError, .identityMismatch)
        }
        XCTAssertEqual(decoder.callCount, 0)
    }

    func testStrictSignatureRejectsUnknownAndDuplicateFieldsBeforeJourneyDecode() async throws {
        let fixture = try fixtureRoot(named: "animation-event")
        let original = try Data(contentsOf: fixture.appendingPathComponent("experience.nux"))
        for replacement in ["xxxxx", "keyId"] {
            var bytes = original
            let field = try XCTUnwrap(bytes.range(of: Data("\"signs\"".utf8)))
            bytes.replaceSubrange(field, with: Data("\"\(replacement)\"".utf8))
            let acquired = try acquiredPackage(bytes: bytes, fixture: fixture)
            let decoder = JourneyDecoderSpy()

            await XCTAssertThrowsErrorAsync {
                _ = try await SwiftExperiencePackageAuthenticator(
                    journeyDecoder: { try decoder.decode($0) }
                ).authenticate(acquired)
            } verify: {
                XCTAssertEqual(
                    ($0 as? ExperiencePackageAuthenticationError)?.contractCode,
                    "package.signature.malformed"
                )
            }
            XCTAssertEqual(decoder.callCount, 0)
        }
    }

    func testStrictManifestRejectsUnknownFieldsBeforeSignatureAndJourney() async throws {
        let fixture = try fixtureRoot(named: "animation-event")
        let originalBytes = try Data(
            contentsOf: fixture.appendingPathComponent("experience.nux")
        )
        let original = try acquiredPackage(
            bytes: originalBytes,
            fixture: fixture
        )
        for replacement in ["xxxxx", "scene"] {
            var bytes = originalBytes
            let field = try XCTUnwrap(bytes.range(of: Data("\"entry\"".utf8)))
            bytes.replaceSubrange(field, with: Data("\"\(replacement)\"".utf8))
            let acquired = replacingPackageBytes(original, with: bytes)
            let decoder = JourneyDecoderSpy()

            await XCTAssertThrowsErrorAsync {
                _ = try await SwiftExperiencePackageAuthenticator(
                    journeyDecoder: { try decoder.decode($0) }
                ).authenticate(acquired)
            } verify: {
                XCTAssertEqual(
                    ($0 as? ExperiencePackageAuthenticationError)?.contractCode,
                    "package.manifest.invalid"
                )
            }
            XCTAssertEqual(decoder.callCount, 0)
        }
    }

    #if os(iOS) && !targetEnvironment(macCatalyst)
    @MainActor
    func testSwiftAndPublishedNativeOracleAgreeOnGoldenSignedFixture() async throws {
        let fixture = try fixtureRoot(named: "animation-event")
        let package = try acquiredPackage(
            bytes: try Data(contentsOf: fixture.appendingPathComponent("experience.nux")),
            fixture: fixture
        )

        let swift = try await SwiftExperiencePackageAuthenticator().authenticate(package)
        let native = try await NativeExperiencePackageAuthenticator().authenticate(package)

        XCTAssertEqual(swift.authenticatedKeyID, "TEST_ONLY_DEV_KEYPAIR")
        XCTAssertEqual(swift.manifest, native.manifest)
        XCTAssertEqual(swift.journey.schemaVersion, native.journey.schemaVersion)
    }
    #endif

    func testInventoryCorruptionPrecedesSignatureAndJourneyWork() async throws {
        let fixture = try fixtureRoot(named: "animation-event")
        var bytes = try Data(contentsOf: fixture.appendingPathComponent("experience.nux"))
        let scene = try XCTUnwrap(bytes.range(of: Data("RIVE".utf8)))
        bytes[scene.lowerBound] ^= 0x01
        let acquired = try acquiredPackage(bytes: bytes, fixture: fixture)
        let decoder = JourneyDecoderSpy()

        await XCTAssertThrowsErrorAsync {
            _ = try await SwiftExperiencePackageAuthenticator(
                journeyDecoder: { try decoder.decode($0) }
            ).authenticate(acquired)
        } verify: {
            XCTAssertEqual(
                ($0 as? ExperiencePackageAuthenticationError)?.contractCode,
                "package.inventory.invalid"
            )
        }
        XCTAssertEqual(decoder.callCount, 0)
    }

    func testRejectsCandidateKeyLimitBeforeParsingPackageBytes() async throws {
        let fixture = try fixtureRoot(named: "animation-event")
        let valid = try acquiredPackage(
            bytes: try Data(contentsOf: fixture.appendingPathComponent("experience.nux")),
            fixture: fixture
        )
        let invalid = AcquiredExperiencePackage(
            remote: valid.remote,
            packageURL: valid.packageURL,
            packageBytes: Data([0]),
            acquisition: valid.acquisition,
            assetURLsByRiveUniqueName: [:],
            source: .cache,
            authorizationKeys: (0...256).map {
                ExperiencePackageAuthorizationKey(
                    keyID: "key-\($0)",
                    ed25519PublicKeyBytes: Data(repeating: UInt8($0 % 255), count: 32)
                )
            }
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await SwiftExperiencePackageAuthenticator().authenticate(invalid)
        } verify: {
            XCTAssertEqual(
                ($0 as? ExperiencePackageAuthenticationError)?.contractCode,
                "package.authorization.invalid_keys"
            )
        }
    }

    private func fixtureRoot(named name: String) throws -> URL {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ExperienceRuntimeHostApp/Fixtures", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        let bundled = Bundle(for: Self.self).resourceURL?
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        for candidate in [bundled, source].compactMap({ $0 }) {
            if FileManager.default.fileExists(
                atPath: candidate.appendingPathComponent("experience.nux").path
            ) {
                return candidate
            }
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private func acquiredPackage(
        bytes: Data,
        fixture: URL
    ) throws -> AcquiredExperiencePackage {
        let acquisition = try NuxPackageReader.read(bytes)
        let identity = acquisition.metadata.identity
        let packageURL = fixture.appendingPathComponent("experience.nux")
        return AcquiredExperiencePackage(
            remote: RemoteExperience(
                experienceId: identity.experienceId,
                versionId: identity.buildId,
                buildId: identity.buildId,
                artifact: RemoteExperienceArtifact(
                    url: packageURL.absoluteString,
                    sha256: SHA256Provider.hexDigest(bytes),
                    sizeBytes: bytes.count
                ),
                name: identity.experienceId,
                reentry: .everyTime,
                publishedAt: "2026-07-29T00:00:00Z"
            ),
            packageURL: packageURL,
            packageBytes: bytes,
            acquisition: acquisition,
            assetURLsByRiveUniqueName: [:],
            source: .cache,
            authorizationKeys: try ExperienceTrustRoots.keys(for: .development)
        )
    }

    private func replacingPackageBytes(
        _ package: AcquiredExperiencePackage,
        with bytes: Data
    ) -> AcquiredExperiencePackage {
        AcquiredExperiencePackage(
            remote: package.remote,
            packageURL: package.packageURL,
            packageBytes: bytes,
            acquisition: package.acquisition,
            assetURLsByRiveUniqueName: package.assetURLsByRiveUniqueName,
            source: package.source,
            authorizationKeys: package.authorizationKeys
        )
    }

    private func resigningPackage(
        _ packageBytes: Data,
        replacingJourneySchemaWith schemaValue: String
    ) throws -> Data {
        var members = try decodeContainerMembers(packageBytes)
        let journeyIndex = try XCTUnwrap(members.firstIndex { $0.0 == "journey" })
        var journey = members[journeyIndex].1
        let schema = try XCTUnwrap(journey.range(of: Data("\"schemaVersion\":1".utf8)))
        journey.replaceSubrange(schema, with: Data("\"schemaVersion\":\(schemaValue)".utf8))
        members[journeyIndex].1 = journey

        let manifestIndex = try XCTUnwrap(members.firstIndex { $0.0 == "manifest" })
        var manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: members[manifestIndex].1) as? [String: Any]
        )
        var journeyRecord = try XCTUnwrap(manifest["journey"] as? [String: Any])
        journeyRecord["sha256"] = SHA256Provider.hexDigest(journey)
        journeyRecord["sizeBytes"] = journey.count
        manifest["journey"] = journeyRecord
        var inventory = try XCTUnwrap(manifest["members"] as? [[String: Any]])
        let inventoryIndex = try XCTUnwrap(inventory.firstIndex {
            ($0["name"] as? String) == "journey"
        })
        inventory[inventoryIndex]["sha256"] = SHA256Provider.hexDigest(journey)
        inventory[inventoryIndex]["sizeBytes"] = journey.count
        manifest["members"] = inventory
        return try signedContainer(members: members, manifest: manifest)
    }

    private func resigningPackage(
        _ packageBytes: Data,
        addingEmbeddedImage bytes: Data
    ) throws -> Data {
        var members = try decodeContainerMembers(packageBytes)
        let manifestIndex = try XCTUnwrap(members.firstIndex { $0.0 == "manifest" })
        var manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: members[manifestIndex].1) as? [String: Any]
        )
        let hash = SHA256Provider.hexDigest(bytes)
        let memberName = "assets/sha256/\(hash).png"
        var assets = try XCTUnwrap(manifest["assets"] as? [String: Any])
        var images = try XCTUnwrap(assets["images"] as? [[String: Any]])
        images.append([
            "location": ["kind": "embedded", "member": memberName],
            "riveAssetId": 4_294_967_000,
            "riveUniqueName": "large-embedded",
            "sha256": hash,
            "sizeBytes": bytes.count,
            "contentType": "image/png",
            "required": true,
        ])
        assets["images"] = images
        manifest["assets"] = assets
        var inventory = try XCTUnwrap(manifest["members"] as? [[String: Any]])
        inventory.append([
            "name": memberName,
            "role": "asset",
            "sha256": hash,
            "sizeBytes": bytes.count,
            "contentType": "image/png",
        ])
        manifest["members"] = inventory
        members.append((memberName, bytes))
        return try signedContainer(members: members, manifest: manifest)
    }

    private func signedContainer(
        members originalMembers: [(String, Data)],
        manifest: [String: Any]
    ) throws -> Data {
        var members = originalMembers
        let manifestIndex = try XCTUnwrap(members.firstIndex { $0.0 == "manifest" })
        let manifestBytes = try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        members[manifestIndex].1 = manifestBytes
        let signatureIndex = try XCTUnwrap(members.firstIndex { $0.0 == "signature" })
        let privateKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(repeating: 0x42, count: 32)
        )
        let signature = try privateKey.signature(for: manifestBytes)
        let envelope: [String: Any] = [
            "algorithm": "ed25519",
            "keyId": "TEST_ONLY_DEV_KEYPAIR",
            "signatureBase64": signature.base64EncodedString(),
            "signs": "manifest",
            "version": 1,
        ]
        members[signatureIndex].1 = try JSONSerialization.data(
            withJSONObject: envelope,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return encodeContainerMembers(members)
    }

    private func decodeContainerMembers(_ data: Data) throws -> [(String, Data)] {
        var cursor = 16
        let count = Int(data.readLittleEndian(UInt32.self, at: 12))
        var table: [(String, Int, Int)] = []
        for _ in 0..<count {
            let nameLength = Int(data.readLittleEndian(UInt16.self, at: cursor))
            cursor += 2
            let nameEnd = cursor + nameLength
            let name = try XCTUnwrap(String(data: data[cursor..<nameEnd], encoding: .utf8))
            cursor = nameEnd
            let offset = Int(data.readLittleEndian(UInt64.self, at: cursor))
            cursor += 8
            let length = Int(data.readLittleEndian(UInt64.self, at: cursor))
            cursor += 8
            table.append((name, offset, length))
        }
        return table.map { ($0.0, data.subdata(in: $0.1..<($0.1 + $0.2))) }
    }

    private func encodeContainerMembers(_ members: [(String, Data)]) -> Data {
        func aligned(_ value: Int) -> Int { ((value + 15) / 16) * 16 }
        let tableBytes = members.reduce(0) { $0 + 2 + $1.0.utf8.count + 16 }
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
}

private final class JourneyDecoderSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var callCount: Int { lock.withLock { calls } }

    func decode(_ data: Data) throws -> JourneyDocument {
        lock.withLock { calls += 1 }
        throw CocoaError(.fileReadCorruptFile)
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @escaping () async throws -> Void,
    verify: (Error) -> Void
) async {
    do {
        try await expression()
        XCTFail("Expected expression to throw")
    } catch {
        verify(error)
    }
}

private extension Data {
    func readLittleEndian<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        var value: T = 0
        _ = Swift.withUnsafeMutableBytes(of: &value) { destination in
            copyBytes(to: destination, from: offset..<(offset + MemoryLayout<T>.size))
        }
        return T(littleEndian: value)
    }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
