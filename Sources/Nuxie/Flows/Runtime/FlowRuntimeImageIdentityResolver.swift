import Foundation

enum FlowRuntimeImageIdentityResolverError: LocalizedError, Equatable {
    case invalidAssetID(Int)
    case ambiguousAssetID(Int)
    case ambiguousLookupKey(String)

    var errorDescription: String? {
        switch self {
        case .invalidAssetID(let value):
            "Runtime image asset ID is outside the supported range: \(value)"
        case .ambiguousAssetID(let value):
            "Runtime image asset ID maps to more than one canonical source key: \(value)"
        case .ambiguousLookupKey(let value):
            "Runtime image lookup key is ambiguous: \(value)"
        }
    }
}

/// Resolves the three image identities accepted by the published flow
/// contract without exposing manifest lookup rules to state translation.
struct FlowRuntimeImageIdentityResolver: Equatable, Sendable {
    private let assetIDsByLookupKey: [String: UInt64]
    private let canonicalLookupKeysByAssetID: [UInt64: String]

    init(images: [FlowArtifactImageAsset]) throws {
        var assetIDsByLookupKey: [String: UInt64] = [:]
        var canonicalLookupKeysByAssetID: [UInt64: String] = [:]
        for image in images {
            guard let assetID = UInt64(exactly: image.riveAssetId) else {
                throw FlowRuntimeImageIdentityResolverError.invalidAssetID(
                    image.riveAssetId
                )
            }
            for key in Set([
                image.sourceAssetKey,
                image.riveUniqueName,
                image.path,
            ]) where !key.isEmpty {
                if let existing = assetIDsByLookupKey[key], existing != assetID {
                    throw FlowRuntimeImageIdentityResolverError.ambiguousLookupKey(key)
                }
                assetIDsByLookupKey[key] = assetID
            }
            if let canonicalKey = [
                image.sourceAssetKey,
                image.riveUniqueName,
                image.path,
            ].first(where: { !$0.isEmpty }) {
                if let existing = canonicalLookupKeysByAssetID[assetID],
                   existing != canonicalKey {
                    throw FlowRuntimeImageIdentityResolverError.ambiguousAssetID(
                        image.riveAssetId
                    )
                }
                canonicalLookupKeysByAssetID[assetID] = canonicalKey
            }
        }
        self.assetIDsByLookupKey = assetIDsByLookupKey
        self.canonicalLookupKeysByAssetID = canonicalLookupKeysByAssetID
    }

    func resolve(_ lookupKey: String) -> UInt64? {
        assetIDsByLookupKey[lookupKey]
    }

    func canonicalLookupKey(for assetID: UInt64) -> String? {
        canonicalLookupKeysByAssetID[assetID]
    }
}
