import CoreGraphics
import Nimble
import Quick
@testable import Nuxie

final class FlowContainCenterTransformTests: QuickSpec {
    override class func spec() {
        describe("FlowContainCenterTransform") {
            it("centers a contained artboard and preserves a nonzero authored origin") {
                let transform = FlowContainCenterTransform(
                    artboardBounds: CGRect(x: 10, y: -20, width: 100, height: 50),
                    viewportBounds: CGRect(x: 0, y: 0, width: 300, height: 300)
                )!

                expect(transform.scale).to(beCloseTo(3))
                expect(transform.contentBounds).to(
                    equal(CGRect(x: 0, y: 75, width: 300, height: 150))
                )
                expect(transform.artboardPoint(fromViewport: CGPoint(x: 0, y: 75))).to(
                    equal(CGPoint(x: 10, y: -20))
                )
                expect(transform.viewportPoint(fromArtboard: CGPoint(x: 110, y: 30))).to(
                    equal(CGPoint(x: 300, y: 225))
                )
            }

            it("does not clamp points in the letterbox or beyond the viewport") {
                let transform = FlowContainCenterTransform(
                    artboardBounds: CGRect(x: 10, y: 20, width: 100, height: 100),
                    viewportBounds: CGRect(x: 0, y: 0, width: 300, height: 200)
                )!

                expect(transform.artboardPoint(fromViewport: CGPoint(x: 25, y: -10))).to(
                    equal(CGPoint(x: -2.5, y: 15))
                )
                expect(transform.artboardPoint(fromViewport: CGPoint(x: 325, y: 210))).to(
                    equal(CGPoint(x: 147.5, y: 125))
                )
            }

            it("round trips points and rectangles through offset viewport bounds") {
                let transform = FlowContainCenterTransform(
                    artboardBounds: CGRect(x: -40, y: 80, width: 120, height: 240),
                    viewportBounds: CGRect(x: 20, y: 30, width: 400, height: 300)
                )!
                let point = CGPoint(x: -10, y: 200)
                let rect = CGRect(x: -20, y: 100, width: 40, height: 60)

                let viewportPoint = transform.viewportPoint(fromArtboard: point)
                expect(transform.artboardPoint(fromViewport: viewportPoint)).to(
                    equal(point)
                )

                let viewportRect = transform.viewportRect(fromArtboard: rect)
                expect(transform.artboardRect(fromViewport: viewportRect)).to(
                    equal(rect)
                )
            }

            it("rejects empty, nonfinite, and degenerate geometry") {
                let validViewport = CGRect(x: 0, y: 0, width: 100, height: 100)
                let invalidBounds = [
                    CGRect(x: 0, y: 0, width: 0, height: 10),
                    CGRect(x: 0, y: 0, width: 10, height: 0),
                    CGRect(x: CGFloat.infinity, y: 0, width: 10, height: 10),
                    CGRect(x: 0, y: 0, width: CGFloat.nan, height: 10),
                ]

                for bounds in invalidBounds {
                    expect(
                        FlowContainCenterTransform(
                            artboardBounds: bounds,
                            viewportBounds: validViewport
                        )
                    ).to(beNil())
                }
                expect(
                    FlowContainCenterTransform(
                        artboardBounds: CGRect(x: 0, y: 0, width: 10, height: 10),
                        viewportBounds: CGRect(
                            x: 0,
                            y: 0,
                            width: CGFloat.infinity,
                            height: 100
                        )
                    )
                ).to(beNil())
            }
        }
    }
}
