import Foundation
import Nimble
import Quick
@testable import Nuxie

final class FlowRuntimeFontRegistryTests: QuickSpec {
    override class func spec() {
        describe("FlowRuntimeFontRegistry") {
            #if canImport(UIKit)
            it("keeps content-backed revisions with the same PostScript name") {
                let bundle = Bundle(for: Self.self)
                guard let fixtureRoot = bundle.url(
                    forResource: "published-font",
                    withExtension: nil
                ) else {
                    fail("published font fixture is missing")
                    return
                }
                let fontURL = fixtureRoot
                    .appendingPathComponent("assets/fonts")
                    .appendingPathComponent("inter-400-normal.ttf")
                let original = try Data(contentsOf: fontURL)
                var revised = original
                revised.append(0)
                let uniqueName = "font-revision-\(UUID().uuidString)"
                var firstScope: FlowRuntimeFontScope? = FlowRuntimeFontScope()
                var secondScope: FlowRuntimeFontScope? = FlowRuntimeFontScope()

                let firstName = FlowRuntimeFontRegistry.registerFont(
                    riveUniqueName: uniqueName,
                    data: original,
                    in: firstScope!
                )
                let secondName = FlowRuntimeFontRegistry.registerFont(
                    riveUniqueName: uniqueName,
                    data: revised,
                    in: secondScope!
                )

                expect(firstName).notTo(beNil())
                expect(secondName).to(equal(firstName))
                expect(
                    FlowRuntimeFontRegistry.font(
                        forRiveUniqueName: uniqueName,
                        contentSHA256: FlowArtifactStore.sha256Hex(original),
                        size: 16
                    )
                ).notTo(beNil())
                expect(
                    FlowRuntimeFontRegistry.font(
                        forRiveUniqueName: uniqueName,
                        contentSHA256: FlowArtifactStore.sha256Hex(revised),
                        size: 16
                    )
                ).notTo(beNil())

                firstScope = nil
                expect(
                    FlowRuntimeFontRegistry.font(
                        forRiveUniqueName: uniqueName,
                        contentSHA256: FlowArtifactStore.sha256Hex(original),
                        size: 16
                    )
                ).to(beNil())
                expect(
                    FlowRuntimeFontRegistry.font(
                        forRiveUniqueName: uniqueName,
                        contentSHA256: FlowArtifactStore.sha256Hex(revised),
                        size: 16
                    )
                ).notTo(beNil())

                secondScope = nil
                expect(
                    FlowRuntimeFontRegistry.font(
                        forRiveUniqueName: uniqueName,
                        contentSHA256: FlowArtifactStore.sha256Hex(revised),
                        size: 16
                    )
                ).to(beNil())
            }

            it("retains exact font content until its last scope closes") {
                let bundle = Bundle(for: Self.self)
                guard let fixtureRoot = bundle.url(
                    forResource: "published-font",
                    withExtension: nil
                ) else {
                    fail("published font fixture is missing")
                    return
                }
                let data = try Data(
                    contentsOf: fixtureRoot
                        .appendingPathComponent("assets/fonts")
                        .appendingPathComponent("inter-400-normal.ttf")
                )
                let uniqueName = "shared-font-\(UUID().uuidString)"
                var firstScope: FlowRuntimeFontScope? = FlowRuntimeFontScope()
                var secondScope: FlowRuntimeFontScope? = FlowRuntimeFontScope()
                let contentSHA256 = FlowArtifactStore.sha256Hex(data)

                expect(
                    FlowRuntimeFontRegistry.registerFont(
                        riveUniqueName: uniqueName,
                        data: data,
                        in: firstScope!
                    )
                ).notTo(beNil())
                expect(
                    FlowRuntimeFontRegistry.registerFont(
                        riveUniqueName: uniqueName,
                        data: data,
                        in: secondScope!
                    )
                ).notTo(beNil())

                firstScope = nil
                expect(
                    FlowRuntimeFontRegistry.font(
                        forRiveUniqueName: uniqueName,
                        contentSHA256: contentSHA256,
                        size: 16
                    )
                ).notTo(beNil())

                secondScope = nil
                expect(
                    FlowRuntimeFontRegistry.font(
                        forRiveUniqueName: uniqueName,
                        contentSHA256: contentSHA256,
                        size: 16
                    )
                ).to(beNil())
            }
            #endif

            it("keeps builds with the same unique name scoped by content") {
                var catalog = FlowRuntimeRegisteredFontCatalog()

                catalog.record(
                    riveUniqueName: "font-inter-400",
                    contentSHA256: "AAAA",
                    postScriptName: "Inter-Regular-v1"
                )
                catalog.record(
                    riveUniqueName: "font-inter-400",
                    contentSHA256: "BBBB",
                    postScriptName: "Inter-Regular-v2"
                )

                expect(
                    catalog.postScriptName(
                        forRiveUniqueName: "font-inter-400",
                        contentSHA256: "aaaa"
                    )
                ).to(equal("Inter-Regular-v1"))
                expect(
                    catalog.postScriptName(
                        forRiveUniqueName: "font-inter-400",
                        contentSHA256: "bbbb"
                    )
                ).to(equal("Inter-Regular-v2"))
                expect(
                    catalog.postScriptName(
                        forRiveUniqueName: "font-inter-400",
                        contentSHA256: "cccc"
                    )
                ).to(beNil())
            }
        }
    }
}
