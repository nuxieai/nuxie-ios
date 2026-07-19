import Foundation

enum FlowRuntimeImageIdentityResolverError: LocalizedError, Equatable {
    case invalidAssetID(Int)
    case ambiguousLookupKey(String)

    var errorDescription: String? {
        switch self {
        case .invalidAssetID(let value):
            "Runtime image asset ID is outside the supported range: \(value)"
        case .ambiguousLookupKey(let value):
            "Runtime image lookup key is ambiguous: \(value)"
        }
    }
}

/// Resolves the three image identities accepted by the published flow
/// contract without exposing manifest lookup rules to state translation.
struct FlowRuntimeImageIdentityResolver: Equatable, Sendable {
    private let assetIDsByLookupKey: [String: UInt64]

    init(images: [FlowArtifactImageAsset]) throws {
        var assetIDsByLookupKey: [String: UInt64] = [:]
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
        }
        self.assetIDsByLookupKey = assetIDsByLookupKey
    }

    func resolve(_ lookupKey: String) -> UInt64? {
        assetIDsByLookupKey[lookupKey]
    }
}
