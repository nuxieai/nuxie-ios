import Foundation
import NuxieRuntimeSupport

enum ExperienceRuntimePackageAdapterError: LocalizedError, Equatable {
    case invalidAssetID(UInt64)
    case duplicateAssetID(UInt32)
    case duplicateAssetIdentity(String)
    case missingRequiredAsset(String)
    case assetSizeMismatch(String)
    case assetSHA256Mismatch(String)

    var errorDescription: String? {
        switch self {
        case .invalidAssetID(let value):
            "Runtime asset ID is outside the supported range: \(value)"
        case .duplicateAssetID(let value):
            "Runtime asset ID is duplicated: \(value)"
        case .duplicateAssetIdentity(let value):
            "Runtime asset identity is duplicated: \(value)"
        case .missingRequiredAsset(let value):
            "Required runtime asset was not prepared: \(value)"
        case .assetSizeMismatch(let value):
            "Runtime asset size changed after preparation: \(value)"
        case .assetSHA256Mismatch(let value):
            "Runtime asset digest changed after preparation: \(value)"
        }
    }
}

enum ExperienceRuntimePackageAdapter {
    static func makeImportRequest(
        from package: AcquiredExperiencePackage
    ) throws -> ExperienceRuntimeImportRequest {
        var assets: [ExperienceRuntimeExternalAsset] = []
        var assetIDs = Set<UInt32>()
        var uniqueNames = Set<String>()

        for asset in package.acquisition.metadata.externalAssets {
            assets.append(
                try makeAsset(
                    kind: asset.kind == .image ? .image : .font,
                    id: asset.riveAssetId,
                    uniqueName: asset.riveUniqueName,
                    key: asset.key,
                    sha256: asset.sha256,
                    sizeBytes: asset.sizeBytes,
                    required: asset.required,
                    package: package,
                    assetIDs: &assetIDs,
                    uniqueNames: &uniqueNames
                )
            )
        }

        let request = ExperienceRuntimeImportRequest(
            packageBytes: package.packageBytes,
            expectedExperienceId: package.remote.experienceId,
            expectedBuildId: package.remote.buildId,
            candidateKeys: package.authorizationKeys.map {
                ExperienceRuntimeAuthorizationKey(
                    keyId: $0.keyID,
                    ed25519PublicKeyBytes: $0.ed25519PublicKeyBytes
                )
            },
            externalAssets: assets
        )
        try request.validateNativeLimits()
        return request
    }

    private static func makeAsset(
        kind: ExperienceRuntimeExternalAssetKind,
        id: UInt32,
        uniqueName: String,
        key: String,
        sha256: String,
        sizeBytes: Int,
        required: Bool,
        package: AcquiredExperiencePackage,
        assetIDs: inout Set<UInt32>,
        uniqueNames: inout Set<String>
    ) throws -> ExperienceRuntimeExternalAsset {
        let assetID = id
        guard assetIDs.insert(assetID).inserted else {
            throw ExperienceRuntimePackageAdapterError.duplicateAssetID(assetID)
        }
        guard uniqueNames.insert(uniqueName).inserted else {
            throw ExperienceRuntimePackageAdapterError.duplicateAssetIdentity(uniqueName)
        }

        let content: ExperienceRuntimeExternalAssetContent
        if let url = package.localAssetURL(forRiveUniqueName: uniqueName) {
            let read = try BoundedFileIO.read(
                at: url,
                maximumBytes: NuxPackageLimits.externalAssetBytes
            )
            guard read.digest.byteCount == sizeBytes else {
                throw ExperienceRuntimePackageAdapterError.assetSizeMismatch(uniqueName)
            }
            guard read.digest.sha256 == sha256.lowercased() else {
                throw ExperienceRuntimePackageAdapterError.assetSHA256Mismatch(uniqueName)
            }
            content = .bytes(read.data)
        } else if required {
            throw ExperienceRuntimePackageAdapterError.missingRequiredAsset(uniqueName)
        } else {
            content = .omittedOptional
        }

        return ExperienceRuntimeExternalAsset(
            kind: kind,
            riveAssetId: assetID,
            riveUniqueName: uniqueName,
            sourceKey: key,
            expectedSHA256: sha256,
            required: required,
            content: content
        )
    }
}
