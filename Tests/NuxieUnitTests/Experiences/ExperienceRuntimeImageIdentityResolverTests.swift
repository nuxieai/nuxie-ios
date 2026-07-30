import Foundation
import Nimble
import Quick
@testable import Nuxie

final class ExperienceRuntimeImageIdentityResolverTests: QuickSpec {
    override class func spec() {
        describe("ExperienceRuntimeImageIdentityResolver") {
            it("resolves every authored image identity to the runtime asset ID") {
                let manifest = try Self.manifest(imagesJSON: """
                [
                  {
                    "location": {
                      "kind": "external",
                      "key": "assets/sha256/\(String(repeating: "a", count: 64)).png"
                    },
                    "riveAssetId": 7,
                    "riveUniqueName": "hero-7",
                    "sha256": "\(String(repeating: "a", count: 64))",
                    "sizeBytes": 1,
                    "contentType": "image/png",
                    "required": true
                  }
                ]
                """)

                let resolver = try ExperienceRuntimeImageIdentityResolver(
                    images: manifest
                )

                expect(resolver.resolve("hero-7")).to(equal(7))
                expect(
                    resolver.resolve("assets/sha256/\(String(repeating: "a", count: 64)).png")
                ).to(equal(7))
                expect(resolver.resolve("missing")).to(beNil())
                expect(resolver.canonicalLookupKey(for: 7)).to(
                    equal("assets/sha256/\(String(repeating: "a", count: 64)).png")
                )
                expect(resolver.canonicalLookupKey(for: 8)).to(beNil())
            }

            it("rejects an identity shared by different runtime assets") {
                let hash = String(repeating: "a", count: 64)
                let manifest = try Self.manifest(imagesJSON: """
                [
                  {
                    "location": {
                      "kind": "external",
                      "key": "assets/sha256/\(hash).png"
                    },
                    "riveAssetId": 7,
                    "riveUniqueName": "hero-7",
                    "sha256": "\(hash)",
                    "sizeBytes": 1,
                    "contentType": "image/png",
                    "required": true
                  },
                  {
                    "location": {
                      "kind": "external",
                      "key": "assets/sha256/\(hash).png"
                    },
                    "riveAssetId": 8,
                    "riveUniqueName": "badge-8",
                    "sha256": "\(hash)",
                    "sizeBytes": 1,
                    "contentType": "image/png",
                    "required": true
                  }
                ]
                """)

                expect {
                    try ExperienceRuntimeImageIdentityResolver(images: manifest)
                }.to(throwError(
                    ExperienceRuntimeImageIdentityResolverError.ambiguousLookupKey(
                        "assets/sha256/\(hash).png"
                    )
                ))
            }
        }
    }

    private static func manifest(imagesJSON: String) throws -> [NuxPackageImageAsset] {
        try JSONDecoder().decode(
            [NuxPackageImageAsset].self,
            from: Data(imagesJSON.utf8)
        )
    }
}
