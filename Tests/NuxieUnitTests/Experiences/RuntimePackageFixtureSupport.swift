#if os(iOS) && !targetEnvironment(macCatalyst)
import Foundation
import NuxieRuntimeSupport
@testable import Nuxie

enum RuntimePackageFixtureSupport {
    static func root(named name: String, bundle: Bundle) throws -> URL {
        let candidates = [
            bundle.resourceURL?
                .appendingPathComponent("Fixtures", isDirectory: true)
                .appendingPathComponent(name, isDirectory: true),
            bundle.resourceURL?.appendingPathComponent(name, isDirectory: true),
        ].compactMap { $0 }
        guard let root = candidates.first(where: {
            FileManager.default.fileExists(
                atPath: $0.appendingPathComponent("experience.nux").path
            )
        }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return root
    }

    static func acquiredPackage(
        named name: String,
        bundle: Bundle,
        expectedExperienceId: String? = nil,
        expectedBuildId: String? = nil,
        mutatePackage: ((inout Data, NuxPackageAcquisition) -> Void)? = nil
    ) throws -> AcquiredExperiencePackage {
        let root = try root(named: name, bundle: bundle)
        let packageURL = root.appendingPathComponent("experience.nux")
        var bytes = try Data(contentsOf: packageURL)
        let original = try NuxPackageReader.read(bytes)
        mutatePackage?(&bytes, original)
        // Mutation tests deliberately corrupt signature bytes or the signature
        // ToC name. Retain only the already-read acquisition metadata to build
        // the native request; the whole mutated package is what the runtime
        // authenticates and must refuse.
        let acquisition = mutatePackage == nil
            ? try NuxPackageReader.read(bytes)
            : original
        let identity = acquisition.metadata.identity
        let remote = RemoteExperience(
            experienceId: expectedExperienceId ?? identity.experienceId,
            versionId: identity.buildId,
            buildId: expectedBuildId ?? identity.buildId,
            artifact: RemoteExperienceArtifact(
                url: packageURL.absoluteString,
                sha256: SHA256Provider.hexDigest(bytes),
                sizeBytes: bytes.count
            ),
            name: name,
            reentry: .everyTime,
            publishedAt: "2026-07-29T00:00:00Z"
        )

        var assets: [String: URL] = [:]
        for asset in acquisition.metadata.externalAssets {
            assets[asset.riveUniqueName] = root.appendingPathComponent(asset.key)
        }
        return AcquiredExperiencePackage(
            remote: remote,
            packageURL: packageURL,
            packageBytes: bytes,
            acquisition: acquisition,
            assetURLsByRiveUniqueName: assets,
            source: .cache,
            authorizationKeys: try ExperienceTrustRoots.keys(for: .development)
        )
    }

    static func loadedPackage(
        named name: String,
        bundle: Bundle,
        expectedExperienceId: String? = nil,
        expectedBuildId: String? = nil
    ) async throws -> LoadedExperiencePackage {
        let acquired = try acquiredPackage(
            named: name,
            bundle: bundle,
            expectedExperienceId: expectedExperienceId,
            expectedBuildId: expectedBuildId
        )
        return try await NativeExperiencePackageAuthenticator().authenticate(acquired)
    }

    static func request(
        named name: String,
        bundle: Bundle,
        expectedExperienceId: String? = nil,
        expectedBuildId: String? = nil,
        mutatePackage: ((inout Data, NuxPackageAcquisition) -> Void)? = nil
    ) throws -> ExperienceRuntimeImportRequest {
        try ExperienceRuntimePackageAdapter.makeImportRequest(
            from: acquiredPackage(
                named: name,
                bundle: bundle,
                expectedExperienceId: expectedExperienceId,
                expectedBuildId: expectedBuildId,
                mutatePackage: mutatePackage
            )
        )
    }
}
#endif
