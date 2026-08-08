import Foundation
import NuxieRuntime
@testable import Nuxie

extension ExperienceRuntimeImportRequest {
    static func testStub(
        packageBytes: Data = Data([0x89, 0x4E, 0x55, 0x58]),
        experienceId: String = "test-experience",
        buildId: String = "test-build"
    ) -> ExperienceRuntimeImportRequest {
        ExperienceRuntimeImportRequest(
            packageBytes: packageBytes,
            expectedExperienceId: experienceId,
            expectedBuildId: buildId,
            candidateKeys: [
                ExperienceRuntimeAuthorizationKey(
                    keyId: "test-key",
                    ed25519PublicKeyBytes: Data(repeating: 0, count: 32)
                ),
            ]
        )
    }
}

extension NuxPackageManifestV1 {
    static func test(
        experienceId: String = "test-experience",
        buildId: String = "test-build",
        entryScreenId: String,
        screens: [NuxPackageScreen],
        textInputs: [NuxPackageTextInput] = []
    ) -> NuxPackageManifestV1 {
        let zeroDigest = String(repeating: "0", count: 64)
        return NuxPackageManifestV1(
            version: 1,
            identity: Identity(
                experienceId: experienceId,
                buildId: buildId,
                appId: "test-app",
                environment: "development"
            ),
            producer: Producer(
                compilerCommit: "test",
                compilerVersion: "0.0.0",
                runtimeRevision: "test",
                luau: Producer.Luau(revision: "test", bytecodeVersions: []),
                minRuntime: "0.0.0"
            ),
            sceneFormat: SceneFormat(major: 1, minor: 0),
            requiredCapabilities: [],
            scene: Member(member: "scene", sha256: zeroDigest, sizeBytes: 4),
            journey: JourneyMember(
                member: "journey",
                sha256: zeroDigest,
                sizeBytes: 2,
                schemaVersion: 1
            ),
            entry: Entry(screenId: entryScreenId),
            screens: screens,
            textInputs: textInputs,
            assets: Assets(images: [], fonts: []),
            members: []
        )
    }
}

extension LoadedExperiencePackage {
    static func test(
        manifest: NuxPackageManifestV1,
        journey: JourneyDocument,
        packageBytes: Data = Data([0x89, 0x4E, 0x55, 0x58])
    ) -> LoadedExperiencePackage {
        let remote = RemoteExperience(
            experienceId: manifest.identity.experienceId,
            versionId: manifest.identity.buildId,
            buildId: manifest.identity.buildId,
            artifact: RemoteExperienceArtifact(
                url: "file:///test/experience.nux",
                sha256: SHA256Provider.hexDigest(packageBytes),
                sizeBytes: packageBytes.count
            ),
            name: manifest.identity.experienceId,
            reentry: .everyTime,
            publishedAt: "2026-07-29T00:00:00Z"
        )
        let acquisition = NuxPackageAcquisition(
            bytes: packageBytes,
            metadata: NuxPackageAcquisitionMetadataV1(
                contractVersion: NuxPackageLimits.acquisitionContractVersion,
                packageVersion: 1,
                identity: NuxPackageAcquisitionIdentity(
                    experienceId: manifest.identity.experienceId,
                    buildId: manifest.identity.buildId
                ),
                externalAssets: []
            )
        )
        let acquired = AcquiredExperiencePackage(
            remote: remote,
            packageURL: URL(fileURLWithPath: "/test/experience.nux"),
            packageBytes: packageBytes,
            acquisition: acquisition,
            assetURLsByRiveUniqueName: [:],
            source: .cache,
            authorizationKeys: []
        )
        return LoadedExperiencePackage(
            acquired: acquired,
            manifest: manifest,
            journey: journey
        )
    }

    var testExperience: Experience {
        Experience(
            remote: remote,
            journey: journey,
            assetBaseURL: packageURL.deletingLastPathComponent()
        )
    }

    func testScreen(id: String? = nil) -> NuxPackageScreen {
        let screenId = id ?? manifest.entry.screenId
        return manifest.screens.first { $0.screenId == screenId }!
    }
}
