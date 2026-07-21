import Foundation
import Quick
import Nimble
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

final class FlowEventsTests: AsyncSpec {
    override class func spec() {
        describe("Experience events") {
            var journey: Journey!

            beforeEach {
                journey = TestJourneyBuilder(id: "test-journey-123")
                    .withCampaignId("test-campaign-456")
                    .build()
            }

            it("flowShownProperties includes ids") {
                let properties = JourneyEvents.flowShownProperties(
                    flowId: "flow-abc",
                    journey: journey
                )

                expect(properties["journey_id"] as? String).to(equal(journey.id))
                expect(properties["campaign_id"] as? String).to(equal(journey.campaignId))
                expect(properties["flow_id"] as? String).to(equal("flow-abc"))
            }

            it("flowPurchasedProperties includes product id when provided") {
                let properties = JourneyEvents.flowPurchasedProperties(
                    flowId: "flow-abc",
                    journey: journey,
                    productId: "product-123"
                )

                expect(properties["product_id"] as? String).to(equal("product-123"))
            }

            it("flowErroredProperties includes error message when provided") {
                let properties = JourneyEvents.flowErroredProperties(
                    flowId: "flow-abc",
                    journey: journey,
                    errorMessage: "oops"
                )

                expect(properties["error_message"] as? String).to(equal("oops"))
            }

            it("flowArtifactLoadSucceededProperties includes artifact metadata") {
                let properties = JourneyEvents.flowArtifactLoadSucceededProperties(
                    flowId: "flow-abc",
                    artifactBuildId: "build-1",
                    artifactSource: "cached_artifact",
                    artifactContentHash: "hash-123"
                )

                expect(properties["flow_id"] as? String).to(equal("flow-abc"))
                expect(properties["artifact_build_id"] as? String).to(equal("build-1"))
                expect(properties["artifact_source"] as? String).to(equal("cached_artifact"))
                expect(properties["artifact_content_hash"] as? String).to(equal("hash-123"))
            }

            it("flowArtifactLoadFailedProperties includes error message when provided") {
                let properties = JourneyEvents.flowArtifactLoadFailedProperties(
                    flowId: "flow-abc",
                    artifactBuildId: "build-1",
                    artifactSource: "downloaded_artifact",
                    artifactContentHash: "hash-123",
                    errorMessage: "loading_timeout"
                )

                expect(properties["error_message"] as? String).to(equal("loading_timeout"))
                expect(properties["artifact_build_id"] as? String).to(equal("build-1"))
            }
        }
    }
}
