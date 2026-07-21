import Foundation
import Quick
import Nimble
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

final class FlowStoreTests: AsyncSpec {
    override class func spec() {
        var mocks: MockFactory!

        beforeEach {
            mocks = MockFactory.shared
            mocks.registerAll()
        }

        func makeRemoteFlow(
            flowId: String = "flow-store",
            values: [RemoteFlowViewModelValue]
        ) -> RemoteFlow {
            RemoteFlow(
                id: flowId,
                flowArtifact: FlowArtifact(
                    url: "https://example.com/flow/\(flowId)",
                    manifest: BuildManifest(
                        totalFiles: 1,
                        totalSize: 100,
                        contentHash: "flow-store-hash",
                        files: [
                            BuildFile(
                                path: "flow.riv",
                                size: 100,
                                contentType: "application/octet-stream"
                            ),
                        ]
                    )
                ),
                screens: [
                    RemoteFlowScreen(
                        id: "screen-1",
                        defaultViewModelName: "Runtime",
                        defaultInstanceId: "runtime-instance"
                    ),
                ],
                viewModelValues: values
            )
        }

        func value(path: String, _ rawValue: Any) -> RemoteFlowViewModelValue {
            RemoteFlowViewModelValue(
                viewModelName: "Runtime",
                instanceId: "runtime-instance",
                instanceName: "Runtime",
                path: path,
                value: AnyCodable(rawValue)
            )
        }

        describe("ExperienceStore") {
            it("does not prefetch arbitrary string view model values as products") {
                let store = ExperienceStore()
                let screens = makeRemoteFlow(values: [
                    value(path: "title", "Welcome"),
                ])

                await store.preloadFlows([screens])

                expect(mocks.productService.fetchProductsCalled).to(beFalse())
            }

            it("prefetches products only from productId view model paths") {
                mocks.productService.mockProducts = [
                    MockStoreProduct(
                        id: "prod_1",
                        displayName: "Pro",
                        price: Decimal(9.99),
                        displayPrice: "$9.99"
                    ),
                ]
                let store = ExperienceStore()
                let screens = makeRemoteFlow(values: [
                    value(path: "title", "prod_not_a_product"),
                    value(path: "paywall/productId", "prod_1"),
                ])

                await store.preloadFlows([screens])

                expect(mocks.productService.requestedProductIds).to(equal(["prod_1"]))
            }
        }
    }
}
