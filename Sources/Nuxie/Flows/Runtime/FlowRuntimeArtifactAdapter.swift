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
    private struct AssetDescriptor {
        let kind: FlowRuntimeExternalAssetKind
        let riveAssetId: UInt32
        let riveUniqueName: String
        let sourceKey: String
        let expectedSHA256: String
        let expectedSize: Int?
        let required: Bool
    }

    static func makeImportRequest(
        from artifact: LoadedFlowArtifact
    ) throws -> FlowRuntimeImportRequest {
        let artifactBytes = try readBoundedFile(
            at: artifact.rivURL,
            alreadyConsumedBytes: 0,
            totalByteLimit: FlowRuntimeImportLimits.artifactBytes,
            field: "artifact"
        )
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
        guard externalAssetByteLimit >= 0,
              externalAssetByteLimit <= FlowRuntimeImportLimits.externalAssetTotalBytes else {
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
        var descriptors: [AssetDescriptor] = []
        descriptors.reserveCapacity(assetCount)

        for image in manifest.assets.images {
            let assetID = try validatedAssetID(image.riveAssetId)
            try reserveIdentity(
                kind: .image,
                assetID: assetID,
                uniqueName: image.riveUniqueName,
                identities: &identities,
                assetIDs: &assetIDs
            )
            descriptors.append(
                AssetDescriptor(
                    kind: .image,
                    riveAssetId: assetID,
                    riveUniqueName: image.riveUniqueName,
                    sourceKey: image.sourceAssetKey,
                    expectedSHA256: image.sha256,
                    expectedSize: nil,
                    required: image.required
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
            descriptors.append(
                AssetDescriptor(
                    kind: .font,
                    riveAssetId: assetID,
                    riveUniqueName: font.riveUniqueName,
                    sourceKey: font.requestKey,
                    expectedSHA256: font.sha256,
                    expectedSize: font.sizeBytes,
                    required: font.required
                )
            )
        }

        // Validate the complete native metadata envelope before opening any
        // external asset. Content is represented as omitted because only the
        // descriptor fields are relevant during this preflight.
        let metadataOnlyAssets = descriptors.map { descriptor in
            FlowRuntimeExternalAsset(
                kind: descriptor.kind,
                riveAssetId: descriptor.riveAssetId,
                riveUniqueName: descriptor.riveUniqueName,
                sourceKey: descriptor.sourceKey,
                expectedSHA256: descriptor.expectedSHA256,
                required: descriptor.required,
                content: .omittedOptional
            )
        }
        try FlowRuntimeImportRequest(
            artifactBytes: artifactBytes,
            expectedIdentity: expectedIdentity,
            authorizationEvidence: authorizationEvidence,
            externalAssets: metadataOnlyAssets
        ).validateNativeLimits()

        var preparedContents = [FlowRuntimeExternalAssetContent?](
            repeating: nil,
            count: descriptors.count
        )
        var acceptedAssetBytes = 0
        var inspectedAssetBytes = 0
        // Rejected optional content does not consume the native content budget,
        // but hashing/decoding it is still capped at one additional native envelope.
        let (inspectionByteLimit, inspectionLimitOverflowed) = externalAssetByteLimit
            .addingReportingOverflow(FlowRuntimeImportLimits.externalAssetTotalBytes)
        guard !inspectionLimitOverflowed else {
            throw FlowRuntimeImportValidationError.byteCountOverflow(
                field: "external asset inspection byte limit"
            )
        }
        for required in [true, false] {
            for (index, descriptor) in descriptors.enumerated()
            where descriptor.required == required {
                preparedContents[index] = try preparedContent(
                    for: descriptor,
                    assetURLsByRiveUniqueName: assetURLsByRiveUniqueName,
                    acceptedAssetBytes: &acceptedAssetBytes,
                    externalAssetByteLimit: externalAssetByteLimit,
                    inspectedAssetBytes: &inspectedAssetBytes,
                    inspectionByteLimit: inspectionByteLimit
                )
            }
        }
        let externalAssets = descriptors.enumerated().map { index, descriptor in
            guard let content = preparedContents[index] else {
                preconditionFailure("Every runtime asset descriptor must be prepared")
            }
            return FlowRuntimeExternalAsset(
                kind: descriptor.kind,
                riveAssetId: descriptor.riveAssetId,
                riveUniqueName: descriptor.riveUniqueName,
                sourceKey: descriptor.sourceKey,
                expectedSHA256: descriptor.expectedSHA256,
                required: descriptor.required,
                content: content
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

    private static func preparedContent(
        for descriptor: AssetDescriptor,
        assetURLsByRiveUniqueName: [String: URL],
        acceptedAssetBytes: inout Int,
        externalAssetByteLimit: Int,
        inspectedAssetBytes: inout Int,
        inspectionByteLimit: Int
    ) throws -> FlowRuntimeExternalAssetContent {
        guard let url = assetURLsByRiveUniqueName[descriptor.riveUniqueName] else {
            if descriptor.required {
                throw FlowRuntimeArtifactAdapterError.missingRequiredAsset(descriptor.riveUniqueName)
            }
            return .omittedOptional
        }

        let bytes: Data
        do {
            bytes = try readAssetFile(
                at: url,
                acceptedAssetBytes: acceptedAssetBytes,
                externalAssetByteLimit: externalAssetByteLimit,
                inspectedAssetBytes: &inspectedAssetBytes,
                inspectionByteLimit: inspectionByteLimit
            )
        } catch let error as FlowRuntimeImportValidationError {
            if descriptor.required {
                throw error
            }
            return .omittedOptional
        } catch {
            if descriptor.required {
                throw FlowRuntimeArtifactAdapterError.unreadableRequiredAsset(
                    descriptor.riveUniqueName
                )
            }
            return .omittedOptional
        }

        if let expectedSize = descriptor.expectedSize,
           bytes.count != expectedSize {
            if descriptor.required {
                throw FlowRuntimeArtifactAdapterError.assetSizeMismatch(
                    descriptor.riveUniqueName
                )
            }
            return .omittedOptional
        }
        guard FlowArtifactStore.sha256Hex(bytes)
            .caseInsensitiveCompare(descriptor.expectedSHA256) == .orderedSame else {
            if descriptor.required {
                throw FlowRuntimeArtifactAdapterError.assetSHA256Mismatch(
                    descriptor.riveUniqueName
                )
            }
            return .omittedOptional
        }
        if descriptor.kind == .font,
           !FlowRuntimeFontRegistry.isValidFontData(bytes) {
            if descriptor.required {
                throw FlowRuntimeArtifactAdapterError.invalidRequiredFont(
                    descriptor.riveUniqueName
                )
            }
            return .omittedOptional
        }

        let (nextAcceptedBytes, overflowed) = acceptedAssetBytes
            .addingReportingOverflow(bytes.count)
        guard !overflowed else {
            throw FlowRuntimeImportValidationError.byteCountOverflow(
                field: "aggregate external assets"
            )
        }
        precondition(nextAcceptedBytes <= externalAssetByteLimit)
        acceptedAssetBytes = nextAcceptedBytes
        return .bytes(bytes)
    }

    private static func readAssetFile(
        at url: URL,
        acceptedAssetBytes: Int,
        externalAssetByteLimit: Int,
        inspectedAssetBytes: inout Int,
        inspectionByteLimit: Int
    ) throws -> Data {
        precondition(acceptedAssetBytes >= 0)
        precondition(acceptedAssetBytes <= externalAssetByteLimit)
        precondition(inspectedAssetBytes >= 0)
        precondition(inspectedAssetBytes <= inspectionByteLimit)

        let remainingContentBytes = externalAssetByteLimit - acceptedAssetBytes
        let remainingInspectionBytes = inspectionByteLimit - inspectedAssetBytes
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let fileSize = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        guard fileSize <= UInt64(remainingContentBytes) else {
            throw FlowRuntimeImportValidationError.valueExceedsLimit(
                field: "aggregate external asset bytes",
                actual: boundedAggregateByteCount(
                    alreadyConsumedBytes: acceptedAssetBytes,
                    nextFileBytes: fileSize
                ),
                limit: externalAssetByteLimit
            )
        }
        guard fileSize <= UInt64(remainingInspectionBytes) else {
            throw FlowRuntimeImportValidationError.valueExceedsLimit(
                field: "external asset inspection bytes",
                actual: boundedAggregateByteCount(
                    alreadyConsumedBytes: inspectedAssetBytes,
                    nextFileBytes: fileSize
                ),
                limit: inspectionByteLimit
            )
        }

        let maximumReadBytes = min(remainingContentBytes, remainingInspectionBytes)
        let bytes = try handle.read(upToCount: maximumReadBytes + 1) ?? Data()
        let (nextInspectedBytes, inspectionOverflowed) = inspectedAssetBytes
            .addingReportingOverflow(bytes.count)
        inspectedAssetBytes = inspectionOverflowed
            ? inspectionByteLimit
            : min(nextInspectedBytes, inspectionByteLimit)
        guard bytes.count <= remainingContentBytes else {
            throw FlowRuntimeImportValidationError.valueExceedsLimit(
                field: "aggregate external asset bytes",
                actual: boundedAggregateByteCount(
                    alreadyConsumedBytes: acceptedAssetBytes,
                    nextFileBytes: UInt64(bytes.count)
                ),
                limit: externalAssetByteLimit
            )
        }
        guard bytes.count <= remainingInspectionBytes else {
            throw FlowRuntimeImportValidationError.valueExceedsLimit(
                field: "external asset inspection bytes",
                actual: boundedAggregateByteCount(
                    alreadyConsumedBytes: inspectionByteLimit,
                    nextFileBytes: 1
                ),
                limit: inspectionByteLimit
            )
        }
        return bytes
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

    private static func readBoundedFile(
        at url: URL,
        alreadyConsumedBytes: Int,
        totalByteLimit: Int,
        field: String
    ) throws -> Data {
        precondition(alreadyConsumedBytes >= 0)
        precondition(alreadyConsumedBytes <= totalByteLimit)
        let remainingBytes = totalByteLimit - alreadyConsumedBytes
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let fileSize = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        guard fileSize <= UInt64(remainingBytes) else {
            throw FlowRuntimeImportValidationError.valueExceedsLimit(
                field: field,
                actual: boundedAggregateByteCount(
                    alreadyConsumedBytes: alreadyConsumedBytes,
                    nextFileBytes: fileSize
                ),
                limit: totalByteLimit
            )
        }

        // The metadata check avoids mapping an oversized file. The +1 read
        // also closes the race where the file grows after the size check.
        let bytes = try handle.read(upToCount: remainingBytes + 1) ?? Data()
        guard bytes.count <= remainingBytes else {
            throw FlowRuntimeImportValidationError.valueExceedsLimit(
                field: field,
                actual: boundedAggregateByteCount(
                    alreadyConsumedBytes: alreadyConsumedBytes,
                    nextFileBytes: UInt64(bytes.count)
                ),
                limit: totalByteLimit
            )
        }
        return bytes
    }

    private static func boundedAggregateByteCount(
        alreadyConsumedBytes: Int,
        nextFileBytes: UInt64
    ) -> Int {
        let available = UInt64(Int.max - alreadyConsumedBytes)
        guard nextFileBytes <= available else { return Int.max }
        return alreadyConsumedBytes + Int(nextFileBytes)
    }
}
