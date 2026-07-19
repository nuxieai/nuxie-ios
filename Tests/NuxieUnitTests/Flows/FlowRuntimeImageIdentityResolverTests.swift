import Foundation
import Nimble
import Quick
@testable import Nuxie

final class FlowRuntimeImageIdentityResolverTests: QuickSpec {
    override class func spec() {
        describe("FlowRuntimeImageIdentityResolver") {
            it("resolves every authored image identity to the runtime asset ID") {
                let manifest = try Self.manifest(imagesJSON: """
                [
                  {
                    "riveAssetId": 7,
                    "riveUniqueName": "hero-7",
                    "sourceAssetKey": "hero",
                    "path": "assets/images/hero.png",
                    "sha256": "\(String(repeating: "a", count: 64))",
                    "contentType": "image/png",
                    "width": 1,
                    "height": 1,
                    "required": true
                  }
                ]
                """)

                let resolver = try FlowRuntimeImageIdentityResolver(
                    images: manifest.assets.images
                )

                expect(resolver.resolve("hero")).to(equal(7))
                expect(resolver.resolve("hero-7")).to(equal(7))
                expect(resolver.resolve("assets/images/hero.png")).to(equal(7))
                expect(resolver.resolve("missing")).to(beNil())
            }

            it("rejects an identity shared by different runtime assets") {
                let hash = String(repeating: "a", count: 64)
                let manifest = try Self.manifest(imagesJSON: """
                [
                  {
                    "riveAssetId": 7,
                    "riveUniqueName": "hero-7",
                    "sourceAssetKey": "shared",
                    "path": "assets/images/hero.png",
                    "sha256": "\(hash)",
                    "contentType": "image/png",
                    "width": 1,
                    "height": 1,
                    "required": true
                  },
                  {
                    "riveAssetId": 8,
                    "riveUniqueName": "badge-8",
                    "sourceAssetKey": "shared",
                    "path": "assets/images/badge.png",
                    "sha256": "\(hash)",
                    "contentType": "image/png",
                    "width": 1,
                    "height": 1,
                    "required": true
                  }
                ]
                """)

                expect {
                    try FlowRuntimeImageIdentityResolver(images: manifest.assets.images)
                }.to(throwError(
                    FlowRuntimeImageIdentityResolverError.ambiguousLookupKey("shared")
                ))
            }
        }
    }

    private static func manifest(imagesJSON: String) throws -> FlowArtifactManifest {
        let json = """
        {
          "version": 1,
          "flowId": "flow-1",
          "buildId": "build-1",
          "renderer": "rive",
          "riv": {
            "path": "flow.riv",
            "sha256": "\(String(repeating: "0", count: 64))",
            "sizeBytes": 3
          },
          "entry": {
            "screenId": "screen-1",
            "artboardId": "screen-1",
            "artboardName": "Entry",
            "width": 100,
            "height": 100
          },
          "screens": [],
          "assets": { "images": \(imagesJSON), "fonts": [] },
          "textInputs": []
        }
        """
        return try JSONDecoder().decode(FlowArtifactManifest.self, from: Data(json.utf8))
    }
}
