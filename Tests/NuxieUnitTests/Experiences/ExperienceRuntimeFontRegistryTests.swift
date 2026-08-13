import Foundation
import Nimble
import Quick
import NuxieRuntime
@testable import Nuxie

final class ExperienceRuntimeFontRegistryTests: QuickSpec {
    override class func spec() {
        describe("ExperienceRuntimeFontRegistry") {
            #if canImport(UIKit)
            it("keeps content-backed revisions with the same PostScript name") {
                let bundle = Bundle(for: Self.self)
                guard let fontURL = runtimeFixtureFontURL(in: bundle) else {
                    fail("published font fixture is missing")
                    return
                }
                let original = try Data(contentsOf: fontURL)
                var revised = original
                revised.append(0)
                let uniqueName = "font-revision-\(UUID().uuidString)"
                var firstScope: ExperienceRuntimeFontScope? = ExperienceRuntimeFontScope()
                var secondScope: ExperienceRuntimeFontScope? = ExperienceRuntimeFontScope()

                let firstName = ExperienceRuntimeFontRegistry.registerFont(
                    riveUniqueName: uniqueName,
                    data: original,
                    in: firstScope!
                )
                let secondName = ExperienceRuntimeFontRegistry.registerFont(
                    riveUniqueName: uniqueName,
                    data: revised,
                    in: secondScope!
                )

                expect(firstName).notTo(beNil())
                expect(secondName).to(equal(firstName))
                expect(
                    ExperienceRuntimeFontRegistry.font(
                        forRiveUniqueName: uniqueName,
                        contentSHA256: SHA256Provider.hexDigest(original),
                        size: 16
                    )
                ).notTo(beNil())
                expect(
                    ExperienceRuntimeFontRegistry.font(
                        forRiveUniqueName: uniqueName,
                        contentSHA256: SHA256Provider.hexDigest(revised),
                        size: 16
                    )
                ).notTo(beNil())

                firstScope = nil
                expect(
                    ExperienceRuntimeFontRegistry.font(
                        forRiveUniqueName: uniqueName,
                        contentSHA256: SHA256Provider.hexDigest(original),
                        size: 16
                    )
                ).to(beNil())
                expect(
                    ExperienceRuntimeFontRegistry.font(
                        forRiveUniqueName: uniqueName,
                        contentSHA256: SHA256Provider.hexDigest(revised),
                        size: 16
                    )
                ).notTo(beNil())

                secondScope = nil
                expect(
                    ExperienceRuntimeFontRegistry.font(
                        forRiveUniqueName: uniqueName,
                        contentSHA256: SHA256Provider.hexDigest(revised),
                        size: 16
                    )
                ).to(beNil())
            }

            it("retains exact font content until its last scope closes") {
                let bundle = Bundle(for: Self.self)
                guard let fontURL = runtimeFixtureFontURL(in: bundle) else {
                    fail("published font fixture is missing")
                    return
                }
                let data = try Data(contentsOf: fontURL)
                let uniqueName = "shared-font-\(UUID().uuidString)"
                var firstScope: ExperienceRuntimeFontScope? = ExperienceRuntimeFontScope()
                var secondScope: ExperienceRuntimeFontScope? = ExperienceRuntimeFontScope()
                let contentSHA256 = SHA256Provider.hexDigest(data)

                expect(
                    ExperienceRuntimeFontRegistry.registerFont(
                        riveUniqueName: uniqueName,
                        data: data,
                        in: firstScope!
                    )
                ).notTo(beNil())
                expect(
                    ExperienceRuntimeFontRegistry.registerFont(
                        riveUniqueName: uniqueName,
                        data: data,
                        in: secondScope!
                    )
                ).notTo(beNil())

                firstScope = nil
                expect(
                    ExperienceRuntimeFontRegistry.font(
                        forRiveUniqueName: uniqueName,
                        contentSHA256: contentSHA256,
                        size: 16
                    )
                ).notTo(beNil())

                secondScope = nil
                expect(
                    ExperienceRuntimeFontRegistry.font(
                        forRiveUniqueName: uniqueName,
                        contentSHA256: contentSHA256,
                        size: 16
                    )
                ).to(beNil())
            }
            #endif

            it("keeps builds with the same unique name scoped by content") {
                var catalog = ExperienceRuntimeRegisteredFontCatalog()

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

private func runtimeFixtureFontURL(in bundle: Bundle) -> URL? {
    let relativePath = "font-converter/assets/sha256/"
        + "b481b059ee94961c7b18585a596935aaa7cc44b68879c096d2cd06922e0431b1.ttf"
    return [
        bundle.resourceURL?
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent(relativePath),
        bundle.resourceURL?.appendingPathComponent(relativePath),
    ]
    .compactMap { $0 }
    .first(where: { FileManager.default.fileExists(atPath: $0.path) })
}
