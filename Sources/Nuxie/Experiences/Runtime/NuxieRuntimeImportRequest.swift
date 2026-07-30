#if os(iOS) && !targetEnvironment(macCatalyst)
import Foundation
import NuxieRuntime

struct NuxieRuntimeImportStorage: Sendable {
    fileprivate struct ExternalAsset: Sendable {
        let kind: ExperienceRuntimeExternalAssetKind
        let assetId: UInt32
        let required: Bool
        let provided: Bool
        let uniqueName: Data
        let sourceKey: Data
        let expectedSHA256: Data
        let bytes: Data
    }

    fileprivate let packageBytes: Data
    fileprivate let expectedExperienceId: String
    fileprivate let expectedBuildId: String
    fileprivate let candidateKeys: [ExperienceRuntimeAuthorizationKey]
    fileprivate let externalAssets: [ExternalAsset]

    init(_ request: ExperienceRuntimeImportRequest) {
        packageBytes = request.packageBytes
        expectedExperienceId = request.expectedExperienceId
        expectedBuildId = request.expectedBuildId
        candidateKeys = request.candidateKeys
        externalAssets = request.externalAssets.map { asset in
            let provided: Bool
            let bytes: Data
            switch asset.content {
            case .bytes(let data):
                provided = true
                bytes = data
            case .omittedOptional:
                provided = false
                bytes = Data()
            }
            return ExternalAsset(
                kind: asset.kind,
                assetId: asset.riveAssetId,
                required: asset.required,
                provided: provided,
                uniqueName: Data(asset.riveUniqueName.utf8),
                sourceKey: Data(asset.sourceKey.utf8),
                expectedSHA256: Data(asset.expectedSHA256.utf8),
                bytes: bytes
            )
        }
    }
}

func withNuxieRuntimeImportRequest<T>(
    _ storage: NuxieRuntimeImportStorage,
    _ body: (UnsafePointer<NuxExperienceImportRequest>) throws -> T
) rethrows -> T {
    let pinned = NuxieRuntimePinnedImportStorage(storage)
    return try pinned.withRequest(body)
}

private final class NuxieRuntimePinnedBytes {
    private nonisolated(unsafe) static let emptySentinel = Data([0]) as NSData
    private let storage: NSData
    let view: NuxByteView

    init(_ data: Data) {
        storage = data as NSData
        let pointer = data.isEmpty
            ? Self.emptySentinel.bytes.assumingMemoryBound(to: UInt8.self)
            : storage.bytes.assumingMemoryBound(to: UInt8.self)
        view = NuxByteView(data: pointer, len: UInt64(data.count))
    }
}

private final class NuxieRuntimePinnedAuthorizationKey {
    private let keyId: NuxieRuntimePinnedBytes
    private let publicKey: NuxieRuntimePinnedBytes

    init(_ key: ExperienceRuntimeAuthorizationKey) {
        keyId = NuxieRuntimePinnedBytes(Data(key.keyId.utf8))
        publicKey = NuxieRuntimePinnedBytes(key.ed25519PublicKeyBytes)
    }

    var native: NuxExperienceAuthorizationKey {
        NuxExperienceAuthorizationKey(
            struct_size: UInt32(MemoryLayout<NuxExperienceAuthorizationKey>.size),
            key_id: keyId.view,
            ed25519_public_key: publicKey.view
        )
    }
}

private final class NuxieRuntimePinnedExternalAsset {
    private let asset: NuxieRuntimeImportStorage.ExternalAsset
    private let uniqueName: NuxieRuntimePinnedBytes
    private let sourceKey: NuxieRuntimePinnedBytes
    private let expectedSHA256: NuxieRuntimePinnedBytes
    private let bytes: NuxieRuntimePinnedBytes

    init(_ asset: NuxieRuntimeImportStorage.ExternalAsset) {
        self.asset = asset
        uniqueName = NuxieRuntimePinnedBytes(asset.uniqueName)
        sourceKey = NuxieRuntimePinnedBytes(asset.sourceKey)
        expectedSHA256 = NuxieRuntimePinnedBytes(asset.expectedSHA256)
        bytes = NuxieRuntimePinnedBytes(asset.bytes)
    }

    var native: NuxExperienceExternalAsset {
        NuxExperienceExternalAsset(
            struct_size: UInt32(MemoryLayout<NuxExperienceExternalAsset>.size),
            kind: asset.kind == .image
                ? UInt32(NUX_EXPERIENCE_EXTERNAL_ASSET_KIND_IMAGE)
                : UInt32(NUX_EXPERIENCE_EXTERNAL_ASSET_KIND_FONT),
            asset_id: asset.assetId,
            required: asset.required,
            provided: asset.provided,
            unique_name: uniqueName.view,
            source_key: sourceKey.view,
            expected_sha256: expectedSHA256.view,
            bytes: bytes.view
        )
    }
}

private final class NuxieRuntimePinnedImportStorage {
    private let source: NuxieRuntimeImportStorage
    private let packageBytes: NuxieRuntimePinnedBytes
    private let keys: [NuxieRuntimePinnedAuthorizationKey]
    private let assets: [NuxieRuntimePinnedExternalAsset]

    init(_ storage: NuxieRuntimeImportStorage) {
        source = storage
        packageBytes = NuxieRuntimePinnedBytes(storage.packageBytes)
        keys = storage.candidateKeys.map(NuxieRuntimePinnedAuthorizationKey.init)
        assets = storage.externalAssets.map(NuxieRuntimePinnedExternalAsset.init)
    }

    func withRequest<T>(
        _ body: (UnsafePointer<NuxExperienceImportRequest>) throws -> T
    ) rethrows -> T {
        let nativeKeys = keys.map(\.native)
        let nativeAssets = assets.map(\.native)
        return try source.expectedExperienceId.withCString { experienceId in
            try source.expectedBuildId.withCString { buildId in
                try nativeKeys.withUnsafeBufferPointer { keyBuffer in
                    try nativeAssets.withUnsafeBufferPointer { assetBuffer in
                        var request = NuxExperienceImportRequest(
                            struct_size: UInt32(
                                MemoryLayout<NuxExperienceImportRequest>.size
                            ),
                            package_bytes: packageBytes.view,
                            expected_experience_id: experienceId,
                            expected_build_id: buildId,
                            candidate_keys: keyBuffer.baseAddress,
                            candidate_key_count: UInt64(keyBuffer.count),
                            external_assets: assetBuffer.baseAddress,
                            external_asset_count: UInt64(assetBuffer.count)
                        )
                        return try withUnsafePointer(to: &request, body)
                    }
                }
            }
        }
    }
}
#endif
