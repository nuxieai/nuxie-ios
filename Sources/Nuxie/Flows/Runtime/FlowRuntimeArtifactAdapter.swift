import Foundation

enum FlowRuntimeArtifactAdapterError: LocalizedError, Equatable {
    case invalidAssetID(Int)
    case duplicateAssetIdentity(String)
    case missingRequiredAsset(String)
    case unreadableRequiredAsset(String)
    case assetSHA256Mismatch(String)
    case assetSizeMismatch(String)
    case invalidRequiredFont(String)

    var errorDescription: String? {
        switch self {
        case .invalidAssetID(let value):
            "Runtime asset ID is outside the supported range: \(value)"
        case .duplicateAssetIdentity(let value):
            "Runtime asset identity is duplicated: \(value)"
        case .missingRequiredAsset(let value):
            "Required runtime asset was not prepared: \(value)"
        case .unreadableRequiredAsset(let value):
            "Required runtime asset could not be read: \(value)"
        case .assetSHA256Mismatch(let value):
            "Runtime asset changed after preparation: \(value)"
        case .assetSizeMismatch(let value):
            "Runtime asset size changed after preparation: \(value)"
        case .invalidRequiredFont(let value):
            "Required runtime font could not be registered: \(value)"
        }
    }
}

/// Adapts the current `.riv` plus sidecars into the container-neutral runtime seam.
///
/// No URL or cache path escapes this type. A future `.nux` reader can produce
/// the same request without changing the context/session API.
enum FlowRuntimeArtifactAdapter {
    static func makeImportRequest(
        from artifact: LoadedFlowArtifact
    ) throws -> FlowRuntimeImportRequest {
        let artifactBytes = try Data(contentsOf: artifact.rivURL, options: .mappedIfSafe)
        return try makeImportRequest(
            artifactBytes: artifactBytes,
            manifest: artifact.manifest,
            expectedIdentity: FlowRuntimeArtifactIdentity(
                flowId: artifact.flow.id,
                buildId: artifact.flow.remoteFlow.flowArtifact.buildId
            ),
            authorizationEvidence: artifact.authorizationEvidence,
            assetURLsByRiveUniqueName: artifact.assetURLsByRiveUniqueName
        )
    }

    static func makeImportRequest(
        artifactBytes: Data,
        manifest: FlowArtifactManifest,
        expectedIdentity: FlowRuntimeArtifactIdentity,
        authorizationEvidence: FlowRuntimeAuthorizationEvidence,
        assetURLsByRiveUniqueName: [String: URL],
        externalAssetByteLimit: Int = FlowRuntimeImportLimits.externalAssetTotalBytes
    ) throws -> FlowRuntimeImportRequest {
        guard externalAssetByteLimit >= 0 else {
            throw FlowRuntimeImportValidationError.valueExceedsLimit(
                field: "aggregate external asset byte limit",
                actual: externalAssetByteLimit,
                limit: FlowRuntimeImportLimits.externalAssetTotalBytes
            )
        }
        let (assetCount, assetCountOverflowed) = manifest.assets.images.count
            .addingReportingOverflow(manifest.assets.fonts.count)
        guard !assetCountOverflowed else {
            throw FlowRuntimeImportValidationError.byteCountOverflow(
                field: "external asset count"
            )
        }
        try FlowRuntimeImportRequest.requireAtMost(
            assetCount,
            FlowRuntimeImportLimits.externalAssetCount,
            field: "external asset count"
        )
        try FlowRuntimeImportRequest(
            artifactBytes: artifactBytes,
            expectedIdentity: expectedIdentity,
            authorizationEvidence: authorizationEvidence
        ).validateNativeLimits()

        var identities = Set<String>()
        var assetIDs = Set<UInt32>()
        var externalAssets: [FlowRuntimeExternalAsset] = []
        var consumedAssetBytes = 0
        externalAssets.reserveCapacity(assetCount)

        for image in manifest.assets.images {
            let assetID = try validatedAssetID(image.riveAssetId)
            try reserveIdentity(
                kind: .image,
                assetID: assetID,
                uniqueName: image.riveUniqueName,
                identities: &identities,
                assetIDs: &assetIDs
            )
            let content = try preparedContent(
                uniqueName: image.riveUniqueName,
                expectedSHA256: image.sha256,
                expectedSize: nil,
                required: image.required,
                assetURLsByRiveUniqueName: assetURLsByRiveUniqueName,
                consumedAssetBytes: &consumedAssetBytes,
                externalAssetByteLimit: externalAssetByteLimit
            )
            externalAssets.append(
                FlowRuntimeExternalAsset(
                    kind: .image,
                    riveAssetId: assetID,
                    riveUniqueName: image.riveUniqueName,
                    sourceKey: image.sourceAssetKey,
                    expectedSHA256: image.sha256,
                    required: image.required,
                    content: content
                )
            )
        }

        for font in manifest.assets.fonts {
            let assetID = try validatedAssetID(font.riveAssetId)
            try reserveIdentity(
                kind: .font,
                assetID: assetID,
                uniqueName: font.riveUniqueName,
                identities: &identities,
                assetIDs: &assetIDs
            )
            var content = try preparedContent(
                uniqueName: font.riveUniqueName,
                expectedSHA256: font.sha256,
                expectedSize: font.sizeBytes,
                required: font.required,
                assetURLsByRiveUniqueName: assetURLsByRiveUniqueName,
                consumedAssetBytes: &consumedAssetBytes,
                externalAssetByteLimit: externalAssetByteLimit
            )
            if case .bytes(let bytes) = content,
               FlowRuntimeFontRegistry.registerFont(
                   riveUniqueName: font.riveUniqueName,
                   data: bytes
               ) == nil {
                if font.required {
                    throw FlowRuntimeArtifactAdapterError.invalidRequiredFont(font.riveUniqueName)
                }
                content = .omittedOptional
            }
            externalAssets.append(
                FlowRuntimeExternalAsset(
                    kind: .font,
                    riveAssetId: assetID,
                    riveUniqueName: font.riveUniqueName,
                    sourceKey: font.requestKey,
                    expectedSHA256: font.sha256,
                    required: font.required,
                    content: content
                )
            )
        }

        let request = FlowRuntimeImportRequest(
            artifactBytes: artifactBytes,
            expectedIdentity: expectedIdentity,
            authorizationEvidence: authorizationEvidence,
            externalAssets: externalAssets
        )
        try request.validateNativeLimits()
        return request
    }

    private static func validatedAssetID(_ value: Int) throws -> UInt32 {
        guard let value = UInt32(exactly: value) else {
            throw FlowRuntimeArtifactAdapterError.invalidAssetID(value)
        }
        return value
    }

    private static func reserveIdentity(
        kind: FlowRuntimeExternalAssetKind,
        assetID: UInt32,
        uniqueName: String,
        identities: inout Set<String>,
        assetIDs: inout Set<UInt32>
    ) throws {
        guard !uniqueName.isEmpty, identities.insert(uniqueName).inserted else {
            throw FlowRuntimeArtifactAdapterError.duplicateAssetIdentity(uniqueName)
        }
        guard assetIDs.insert(assetID).inserted else {
            throw FlowRuntimeArtifactAdapterError.duplicateAssetIdentity(
                "assetId:\(assetID):kind:\(kind.rawValue)"
            )
        }
    }

    private static func preparedContent(
        uniqueName: String,
        expectedSHA256: String,
        expectedSize: Int?,
        required: Bool,
        assetURLsByRiveUniqueName: [String: URL],
        consumedAssetBytes: inout Int,
        externalAssetByteLimit: Int
    ) throws -> FlowRuntimeExternalAssetContent {
        guard let url = assetURLsByRiveUniqueName[uniqueName] else {
            if required {
                throw FlowRuntimeArtifactAdapterError.missingRequiredAsset(uniqueName)
            }
            return .omittedOptional
        }
        let bytes: Data
        do {
            bytes = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            if required {
                throw FlowRuntimeArtifactAdapterError.unreadableRequiredAsset(uniqueName)
            }
            return .omittedOptional
        }
        let (nextConsumedBytes, byteCountOverflowed) = consumedAssetBytes
            .addingReportingOverflow(bytes.count)
        guard !byteCountOverflowed else {
            throw FlowRuntimeImportValidationError.byteCountOverflow(
                field: "aggregate external assets"
            )
        }
        guard nextConsumedBytes <= externalAssetByteLimit else {
            if required {
                throw FlowRuntimeImportValidationError.valueExceedsLimit(
                    field: "aggregate external asset bytes",
                    actual: nextConsumedBytes,
                    limit: externalAssetByteLimit
                )
            }
            return .omittedOptional
        }
        // Consume the work budget before hashing or font registration. Invalid
        // optional inputs cannot reset the budget and force unbounded work.
        consumedAssetBytes = nextConsumedBytes
        if let expectedSize, bytes.count != expectedSize {
            if required {
                throw FlowRuntimeArtifactAdapterError.assetSizeMismatch(uniqueName)
            }
            return .omittedOptional
        }
        guard FlowArtifactStore.sha256Hex(bytes)
            .caseInsensitiveCompare(expectedSHA256) == .orderedSame else {
            if required {
                throw FlowRuntimeArtifactAdapterError.assetSHA256Mismatch(uniqueName)
            }
            return .omittedOptional
        }
        return .bytes(bytes)
    }
}
