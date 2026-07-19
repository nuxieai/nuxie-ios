#if canImport(NuxieRuntime)
import Foundation
import NuxieRuntime

/// Owns the Swift values that are later pinned for the synchronous C import call.
struct NuxieRuntimeImportStorage: Sendable {
    fileprivate struct AuthorizationKey: Sendable {
        let keyId: [UInt8]
        let publicKey: Data
    }

    fileprivate struct ExternalAsset: Sendable {
        let kind: FlowRuntimeExternalAssetKind
        let assetId: UInt32
        let required: Bool
        let provided: Bool
        let uniqueName: [UInt8]
        let sourceKey: [UInt8]
        let expectedSHA256: [UInt8]
        let bytes: Data?
    }

    fileprivate let artifactBytes: Data
    fileprivate let expectedFlowId: [UInt8]?
    fileprivate let expectedBuildId: [UInt8]?
    fileprivate let manifestBytes: Data?
    fileprivate let signatureEnvelopeBytes: Data?
    fileprivate let authorizationKey: AuthorizationKey?
    fileprivate let externalAssets: [ExternalAsset]

    init(_ request: FlowRuntimeImportRequest) {
        artifactBytes = request.artifactBytes
        expectedFlowId = request.expectedIdentity.map { Array($0.flowId.utf8) }
        expectedBuildId = request.expectedIdentity.map { Array($0.buildId.utf8) }
        manifestBytes = request.authorizationEvidence?.signedContentBytes
        signatureEnvelopeBytes = request.authorizationEvidence?.signatureEnvelopeBytes
        authorizationKey = request.authorizationEvidence?
            .selectedKey
            .map {
                AuthorizationKey(
                    keyId: Array($0.keyId.utf8),
                    publicKey: $0.ed25519PublicKeyBytes
                )
            }
        externalAssets = request.externalAssets.map { asset in
            let provided: Bool
            let bytes: Data?
            switch asset.content {
            case .bytes(let data):
                provided = true
                bytes = data
            case .omittedOptional:
                provided = false
                bytes = nil
            }
            return ExternalAsset(
                kind: asset.kind,
                assetId: asset.riveAssetId,
                required: asset.required,
                provided: provided,
                uniqueName: Array(asset.riveUniqueName.utf8),
                sourceKey: Array(asset.sourceKey.utf8),
                expectedSHA256: Array(asset.expectedSHA256.utf8),
                bytes: bytes
            )
        }
    }
}

func withNuxieRuntimeImportRequest<T>(
    _ storage: NuxieRuntimeImportStorage,
    _ body: (UnsafePointer<NuxFlowImportRequest>) throws -> T
) rethrows -> T {
    let pinnedStorage = NuxieRuntimePinnedImportStorage(storage)
    return try pinnedStorage.withRequest(body)
}

/// Retains immutable Foundation byte storage while C borrows flat views into it.
///
/// `NSData.bytes` remains valid for the lifetime of the immutable object, so
/// importing 1,024 assets no longer requires 4,096 recursively nested Swift
/// `withUnsafeBytes` scopes. Bridging `Data` preserves its existing immutable
/// backing storage when Foundation can do so without a copy.
private final class NuxieRuntimePinnedBytes {
    private static let emptySentinel = Data([0]) as NSData

    private let storage: NSData
    let view: NuxByteView

    init(_ data: Data) {
        let storage = data as NSData
        self.storage = storage
        let pointer = data.isEmpty
            ? Self.emptySentinel.bytes.assumingMemoryBound(to: UInt8.self)
            : storage.bytes.assumingMemoryBound(to: UInt8.self)
        view = NuxByteView(data: pointer, len: UInt64(data.count))
    }

    convenience init(_ bytes: [UInt8]) {
        self.init(Data(bytes))
    }
}

private final class NuxieRuntimePinnedImportStorage {
    private struct AuthorizationKey {
        let keyId: NuxieRuntimePinnedBytes
        let publicKey: NuxieRuntimePinnedBytes

        var native: NuxFlowAuthorizationKey {
            NuxFlowAuthorizationKey(
                struct_size: UInt32(MemoryLayout<NuxFlowAuthorizationKey>.size),
                key_id: keyId.view,
                ed25519_public_key: publicKey.view
            )
        }
    }

    private struct ExternalAsset {
        let kind: FlowRuntimeExternalAssetKind
        let assetId: UInt32
        let required: Bool
        let provided: Bool
        let uniqueName: NuxieRuntimePinnedBytes
        let sourceKey: NuxieRuntimePinnedBytes
        let expectedSHA256: NuxieRuntimePinnedBytes
        let bytes: NuxieRuntimePinnedBytes?

        var native: NuxFlowExternalAsset {
            NuxFlowExternalAsset(
                struct_size: UInt32(MemoryLayout<NuxFlowExternalAsset>.size),
                kind: kind == .image
                    ? UInt32(NUX_FLOW_EXTERNAL_ASSET_KIND_IMAGE)
                    : UInt32(NUX_FLOW_EXTERNAL_ASSET_KIND_FONT),
                asset_id: assetId,
                required: required,
                provided: provided,
                unique_name: uniqueName.view,
                source_key: sourceKey.view,
                expected_sha256: expectedSHA256.view,
                bytes: bytes?.view ?? NuxByteView(data: nil, len: 0)
            )
        }
    }

    private let artifactBytes: NuxieRuntimePinnedBytes
    private let expectedFlowId: NuxieRuntimePinnedBytes?
    private let expectedBuildId: NuxieRuntimePinnedBytes?
    private let manifestBytes: NuxieRuntimePinnedBytes?
    private let signatureEnvelopeBytes: NuxieRuntimePinnedBytes?
    private let authorizationKey: AuthorizationKey?
    private let externalAssets: [ExternalAsset]

    init(_ storage: NuxieRuntimeImportStorage) {
        artifactBytes = NuxieRuntimePinnedBytes(storage.artifactBytes)
        expectedFlowId = storage.expectedFlowId.map(NuxieRuntimePinnedBytes.init)
        expectedBuildId = storage.expectedBuildId.map(NuxieRuntimePinnedBytes.init)
        manifestBytes = storage.manifestBytes.map(NuxieRuntimePinnedBytes.init)
        signatureEnvelopeBytes = storage.signatureEnvelopeBytes.map(
            NuxieRuntimePinnedBytes.init
        )
        authorizationKey = storage.authorizationKey.map {
            AuthorizationKey(
                keyId: NuxieRuntimePinnedBytes($0.keyId),
                publicKey: NuxieRuntimePinnedBytes($0.publicKey)
            )
        }
        externalAssets = storage.externalAssets.map {
            ExternalAsset(
                kind: $0.kind,
                assetId: $0.assetId,
                required: $0.required,
                provided: $0.provided,
                uniqueName: NuxieRuntimePinnedBytes($0.uniqueName),
                sourceKey: NuxieRuntimePinnedBytes($0.sourceKey),
                expectedSHA256: NuxieRuntimePinnedBytes($0.expectedSHA256),
                bytes: $0.bytes.map(NuxieRuntimePinnedBytes.init)
            )
        }
    }

    func withRequest<T>(
        _ body: (UnsafePointer<NuxFlowImportRequest>) throws -> T
    ) rethrows -> T {
        let nativeAssets = externalAssets.map(\.native)
        return try nativeAssets.withUnsafeBufferPointer { assetBuffer in
            if var nativeKey = authorizationKey?.native {
                return try withUnsafePointer(to: &nativeKey) { keyPointer in
                    try call(
                        selectedKey: keyPointer,
                        externalAssets: assetBuffer.baseAddress,
                        externalAssetCount: UInt64(assetBuffer.count),
                        body
                    )
                }
            }
            return try call(
                selectedKey: nil,
                externalAssets: assetBuffer.baseAddress,
                externalAssetCount: UInt64(assetBuffer.count),
                body
            )
        }
    }

    private func call<T>(
        selectedKey: UnsafePointer<NuxFlowAuthorizationKey>?,
        externalAssets: UnsafePointer<NuxFlowExternalAsset>?,
        externalAssetCount: UInt64,
        _ body: (UnsafePointer<NuxFlowImportRequest>) throws -> T
    ) rethrows -> T {
        var request = NuxFlowImportRequest(
            struct_size: UInt32(MemoryLayout<NuxFlowImportRequest>.size),
            artifact_bytes: artifactBytes.view,
            expected_flow_id: expectedFlowId?.view ?? NuxByteView(data: nil, len: 0),
            expected_build_id: expectedBuildId?.view ?? NuxByteView(data: nil, len: 0),
            manifest_bytes: manifestBytes?.view ?? NuxByteView(data: nil, len: 0),
            signature_envelope_bytes: signatureEnvelopeBytes?.view
                ?? NuxByteView(data: nil, len: 0),
            selected_key: selectedKey,
            external_assets: externalAssets,
            external_asset_count: externalAssetCount
        )
        return try withUnsafePointer(to: &request, body)
    }
}

#endif
