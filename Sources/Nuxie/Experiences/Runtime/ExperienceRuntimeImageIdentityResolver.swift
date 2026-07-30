import Foundation

enum ExperienceRuntimeImageIdentityResolverError: LocalizedError, Equatable {
    case invalidAssetID(UInt64)
    case ambiguousAssetID(UInt64)
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

/// Resolves the three image identities accepted by the published experience
/// contract without exposing manifest lookup rules to state translation.
struct ExperienceRuntimeImageIdentityResolver: Equatable, Sendable {
    private let assetIDsByLookupKey: [String: UInt64]
    private let canonicalLookupKeysByAssetID: [UInt64: String]

    init(images: [NuxPackageImageAsset]) throws {
        var assetIDsByLookupKey: [String: UInt64] = [:]
        var canonicalLookupKeysByAssetID: [UInt64: String] = [:]
        for image in images {
            let assetID = image.riveAssetId
            for key in Set([
                image.location.contentAddressedPath,
                image.riveUniqueName,
            ]) where !key.isEmpty {
                if let existing = assetIDsByLookupKey[key], existing != assetID {
                    throw ExperienceRuntimeImageIdentityResolverError.ambiguousLookupKey(key)
                }
                assetIDsByLookupKey[key] = assetID
            }
            if let canonicalKey = [
                image.location.contentAddressedPath,
                image.riveUniqueName,
            ].first(where: { !$0.isEmpty }) {
                if let existing = canonicalLookupKeysByAssetID[assetID],
                   existing != canonicalKey {
                    throw ExperienceRuntimeImageIdentityResolverError.ambiguousAssetID(
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
