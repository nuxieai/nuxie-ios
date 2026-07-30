import Foundation

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
        from package: LoadedExperiencePackage
    ) throws -> ExperienceRuntimeImportRequest {
        try validateManifestAssetBounds(package.manifest)
        var assets: [ExperienceRuntimeExternalAsset] = []
        var assetIDs = Set<UInt32>()
        var uniqueNames = Set<String>()

        for image in package.manifest.assets.images {
            guard case .external(let key) = image.location else { continue }
            assets.append(
                try makeAsset(
                    kind: .image,
                    id: image.riveAssetId,
                    uniqueName: image.riveUniqueName,
                    key: key,
                    sha256: image.sha256,
                    sizeBytes: image.sizeBytes,
                    required: image.required,
                    package: package,
                    assetIDs: &assetIDs,
                    uniqueNames: &uniqueNames
                )
            )
        }
        for font in package.manifest.assets.fonts {
            guard case .external(let key) = font.location else { continue }
            assets.append(
                try makeAsset(
                    kind: .font,
                    id: font.riveAssetId,
                    uniqueName: font.riveUniqueName,
                    key: key,
                    sha256: font.sha256,
                    sizeBytes: font.sizeBytes,
                    required: font.required,
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
            candidateKeys: package.authorizationKeys,
            externalAssets: assets
        )
        try request.validateNativeLimits()
        return request
    }

    /// Rejects an oversized external-asset table before any asset file is
    /// downloaded or materialized as `Data`.
    static func validateManifestAssetBounds(
        _ manifest: NuxPackageManifestV1
    ) throws {
        var count = 0
        var totalBytes = 0

        func include(location: NuxPackageAssetLocation, sizeBytes: Int) throws {
            guard case .external = location else { return }
            count += 1
            let (nextTotal, overflowed) = totalBytes.addingReportingOverflow(sizeBytes)
            guard sizeBytes >= 0, !overflowed else {
                throw ExperienceRuntimeImportValidationError.byteCountOverflow(
                    field: "aggregate external assets"
                )
            }
            totalBytes = nextTotal
        }

        for image in manifest.assets.images {
            try include(location: image.location, sizeBytes: image.sizeBytes)
        }
        for font in manifest.assets.fonts {
            try include(location: font.location, sizeBytes: font.sizeBytes)
        }
        try ExperienceRuntimeImportRequest.requireAtMost(
            count,
            ExperienceRuntimeImportLimits.externalAssetCount,
            field: "external asset count"
        )
        try ExperienceRuntimeImportRequest.requireAtMost(
            totalBytes,
            ExperienceRuntimeImportLimits.externalAssetTotalBytes,
            field: "aggregate external asset bytes"
        )
    }

    private static func makeAsset(
        kind: ExperienceRuntimeExternalAssetKind,
        id: UInt64,
        uniqueName: String,
        key: String,
        sha256: String,
        sizeBytes: Int,
        required: Bool,
        package: LoadedExperiencePackage,
        assetIDs: inout Set<UInt32>,
        uniqueNames: inout Set<String>
    ) throws -> ExperienceRuntimeExternalAsset {
        guard let assetID = UInt32(exactly: id) else {
            throw ExperienceRuntimePackageAdapterError.invalidAssetID(id)
        }
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
