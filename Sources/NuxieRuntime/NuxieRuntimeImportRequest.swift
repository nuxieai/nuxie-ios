#if os(iOS) && !targetEnvironment(macCatalyst)
import Foundation
import NuxieRuntimeSupport
import NuxieRuntimeFFI

/// Swift-owned package input copied into the runtime's C request for one call.
package struct NuxieRuntimeImportRequest: Sendable {
    package struct AuthorizationKey: Sendable {
        package let keyId: String
        package let ed25519PublicKeyBytes: Data

        package init(keyId: String, ed25519PublicKeyBytes: Data) {
            self.keyId = keyId
            self.ed25519PublicKeyBytes = ed25519PublicKeyBytes
        }
    }

    package struct ExternalAsset: Sendable {
        package enum Kind: Sendable {
            case image
            case font
        }

        package let kind: Kind
        package let assetId: UInt32
        package let required: Bool
        package let provided: Bool
        package let uniqueName: Data
        package let sourceKey: Data
        package let expectedSHA256: Data
        package let bytes: Data

        package init(
            kind: Kind,
            assetId: UInt32,
            required: Bool,
            provided: Bool,
            uniqueName: Data,
            sourceKey: Data,
            expectedSHA256: Data,
            bytes: Data
        ) {
            self.kind = kind
            self.assetId = assetId
            self.required = required
            self.provided = provided
            self.uniqueName = uniqueName
            self.sourceKey = sourceKey
            self.expectedSHA256 = expectedSHA256
            self.bytes = bytes
        }
    }

    fileprivate let packageBytes: Data
    fileprivate let expectedExperienceId: String
    fileprivate let expectedBuildId: String
    fileprivate let candidateKeys: [AuthorizationKey]
    fileprivate let externalAssets: [ExternalAsset]

    package init(
        packageBytes: Data,
        expectedExperienceId: String,
        expectedBuildId: String,
        candidateKeys: [AuthorizationKey],
        externalAssets: [ExternalAsset]
    ) {
        self.packageBytes = packageBytes
        self.expectedExperienceId = expectedExperienceId
        self.expectedBuildId = expectedBuildId
        self.candidateKeys = candidateKeys
        self.externalAssets = externalAssets
    }
}

/// Pins all Swift storage for exactly the duration of one synchronous FFI call.
package func withNuxieRuntimeFFIImportRequest<T>(
    _ request: NuxieRuntimeImportRequest,
    _ body: (UnsafePointer<NuxExperienceImportRequest>) throws -> T
) rethrows -> T {
    try NuxieRuntimePinnedImportRequest(request).withUnsafeRequest(body)
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

    init(_ key: NuxieRuntimeImportRequest.AuthorizationKey) {
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
    private let asset: NuxieRuntimeImportRequest.ExternalAsset
    private let uniqueName: NuxieRuntimePinnedBytes
    private let sourceKey: NuxieRuntimePinnedBytes
    private let expectedSHA256: NuxieRuntimePinnedBytes
    private let bytes: NuxieRuntimePinnedBytes

    init(_ asset: NuxieRuntimeImportRequest.ExternalAsset) {
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

private final class NuxieRuntimePinnedImportRequest {
    private let source: NuxieRuntimeImportRequest
    private let packageBytes: NuxieRuntimePinnedBytes
    private let keys: [NuxieRuntimePinnedAuthorizationKey]
    private let assets: [NuxieRuntimePinnedExternalAsset]

    init(_ request: NuxieRuntimeImportRequest) {
        source = request
        packageBytes = NuxieRuntimePinnedBytes(request.packageBytes)
        keys = request.candidateKeys.map(NuxieRuntimePinnedAuthorizationKey.init)
        assets = request.externalAssets.map(NuxieRuntimePinnedExternalAsset.init)
    }

    func withUnsafeRequest<T>(
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
