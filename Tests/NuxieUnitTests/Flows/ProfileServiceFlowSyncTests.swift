import Foundation
import Quick
import Nimble
@testable import Nuxie
@testable import NuxieTestSupport

final class ProfileServiceFlowSyncTests: AsyncSpec {
    override class func spec() {
        describe("ProfileService profile-driven flow sync") {
            var mockFactory: MockFactory!
            var profileService: ProfileService!

            beforeEach {
                mockFactory = MockFactory.shared
                await mockFactory.resetAll()
                mockFactory.registerAll()
                mockFactory.identityService.setDistinctId("user-1")
                profileService = ProfileService(cache: NullCachedProfileStore())
            }

            afterEach {
                await profileService.clearAllCache()
                await mockFactory.resetAll()
                mockFactory.resetAllFactories()
            }

            it("prefetches newly assigned profile flows and removes flows missing from the refreshed profile") {
                let firstFlow = makeFlow(id: "flow-old", buildId: "build-old", hash: "hash-old")
                await mockFactory.nuxieApi.setProfileResponse(makeProfile(flows: [firstFlow]))

                _ = try await profileService.refetchProfile(distinctId: "user-1")

                expect(mockFactory.flowService.prefetchedFlows.map(\.id)).to(contain("flow-old"))

                mockFactory.flowService.prefetchedFlows = []
                let replacementFlow = makeFlow(id: "flow-new", buildId: "build-new", hash: "hash-new")
                await mockFactory.nuxieApi.setProfileResponse(makeProfile(flows: [replacementFlow]))

                _ = try await profileService.refetchProfile()

                expect(mockFactory.flowService.removedFlowIds).to(equal(["flow-old"]))
                expect(mockFactory.flowService.prefetchedFlows.map(\.id)).to(contain("flow-new"))
            }
        }

        func makeManifest(hash: String) -> BuildManifest {
            BuildManifest(
                totalFiles: 1,
                totalSize: 128,
                contentHash: hash,
                files: [BuildFile(path: "flow.riv", size: 128, contentType: "application/octet-stream")]
            )
        }

        func makeArtifact(buildId: String, hash: String) -> FlowArtifact {
            FlowArtifact(
                url: "https://cdn.example/\(buildId)/",
                buildId: buildId,
                manifest: makeManifest(hash: hash)
            )
        }

        func makeFlow(id: String, buildId: String, hash: String) -> RemoteFlow {
            RemoteFlow(
                id: id,
                flowArtifact: makeArtifact(buildId: buildId, hash: hash),
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

        func makeProfile(flows: [RemoteFlow]) -> ProfileResponse {
            ProfileResponse(
                campaigns: [],
                segments: [],
                flows: flows,
                userProperties: nil,
                experiments: nil,
                features: nil,
                journeys: nil
            )
        }
    }
}
