import Foundation
import Quick
import Nimble
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

final class ProfileServiceFlowInvalidationTests: QuickSpec {
    override class func spec() {
        func makeManifest(hash: String) -> BuildManifest {
            BuildManifest(
                totalFiles: 1,
                totalSize: 128,
                contentHash: hash,
                files: [BuildFile(path: "flow.riv", size: 128, contentType: "application/octet-stream")]
            )
        }

        func makeArtifact(
            url: String,
            buildId: String,
            hash: String
        ) -> FlowArtifact {
            FlowArtifact(
                url: url,
                buildId: buildId,
                manifest: makeManifest(hash: hash)
            )
        }

        func makeFlow(
            url: String = "https://cdn.example/flow/",
            buildId: String = "build-v1",
            hash: String = "hash-v1"
        ) -> RemoteFlow {
            RemoteFlow(
                id: "flow-1",
                flowArtifact: makeArtifact(url: url, buildId: buildId, hash: hash),
                screens: [
                    RemoteFlowScreen(
                        id: "screen-1",
                        defaultViewModelName: nil,
                        defaultInstanceId: nil
                    ),
                ],
                viewModelValues: nil
            )
        }

        describe("ProfileService flow cache invalidation") {
            it("refreshes when artifact hash changes") {
                let previous = makeFlow(buildId: "build-v1", hash: "hash-v1")
                let next = makeFlow(buildId: "build-v2", hash: "hash-v2")

                expect(ProfileService.shouldRefreshCachedFlow(previous: previous, next: next)).to(beTrue())
            }

            it("refreshes when artifact URL changes but hash stays the same") {
                let previous = makeFlow(
                    url: "https://cdn.example/build-v1/",
                    buildId: "build-v1",
                    hash: "same-hash"
                )
                let next = makeFlow(
                    url: "https://cdn.example/build-v2/",
                    buildId: "build-v2",
                    hash: "same-hash"
                )

                expect(ProfileService.shouldRefreshCachedFlow(previous: previous, next: next)).to(beTrue())
            }

            it("refreshes when artifact build id changes but URL and hash are unchanged") {
                let previous = makeFlow(buildId: "build-v1", hash: "same-hash")
                let next = makeFlow(buildId: "build-v2", hash: "same-hash")

                expect(ProfileService.shouldRefreshCachedFlow(previous: previous, next: next)).to(beTrue())
            }

            it("does not refresh when artifact is unchanged") {
                let previous = makeFlow(buildId: "build-v1", hash: "same-hash")
                let next = makeFlow(buildId: "build-v1", hash: "same-hash")

                expect(ProfileService.shouldRefreshCachedFlow(previous: previous, next: next)).to(beFalse())
            }
        }
    }
}
