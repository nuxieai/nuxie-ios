import Foundation
import Quick
import Nimble
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

final class ExperimentResolverTests: QuickSpec {
    override class func spec() {
        func assignment(
            status: String,
            variantKey: String? = nil,
            isHoldout: Bool? = nil
        ) -> ExperimentAssignment {
            ExperimentAssignment(
                experimentKey: "exp",
                variantKey: variantKey,
                status: status,
                isHoldout: isHoldout
            )
        }

        describe("resolve") {
            it("skips entirely for empty variants") {
                let resolution = ExperimentResolver.resolve(
                    variantIds: [],
                    assignment: assignment(status: "running", variantKey: "a"),
                    frozenVariantKey: nil,
                    hasEmittedExposure: false
                )
                expect(resolution) == .skip
            }

            it("errors (and runs nothing) when a running assignment names a missing variant") {
                let resolution = ExperimentResolver.resolve(
                    variantIds: ["a", "b"],
                    assignment: assignment(status: "running", variantKey: "ghost"),
                    frozenVariantKey: nil,
                    hasEmittedExposure: false
                )
                expect(resolution.variantId).to(beNil())
                expect(resolution.errorAssignedVariantKey) == "ghost"
                expect(resolution.exposure) == ExperimentResolver.Exposure.none
            }

            it("runs the assigned variant with a real exposure and freezes it") {
                let resolution = ExperimentResolver.resolve(
                    variantIds: ["a", "b"],
                    assignment: assignment(status: "running", variantKey: "b", isHoldout: true),
                    frozenVariantKey: nil,
                    hasEmittedExposure: false
                )
                expect(resolution.variantId) == "b"
                expect(resolution.shouldFreezeVariant) == true
                expect(resolution.exposure) == .real(assignmentSource: "profile", isHoldout: true)
                expect(resolution.errorAssignedVariantKey).to(beNil())
            }

            it("prefers the frozen variant and sources the exposure from journey context") {
                let resolution = ExperimentResolver.resolve(
                    variantIds: ["a", "b"],
                    assignment: assignment(status: "running", variantKey: "b"),
                    frozenVariantKey: "b",
                    hasEmittedExposure: false
                )
                expect(resolution.variantId) == "b"
                // Already frozen: no re-freeze.
                expect(resolution.shouldFreezeVariant) == false
                expect(resolution.exposure) == .real(assignmentSource: "journey_context", isHoldout: false)
            }

            it("falls back to the first variant with a tagged exposure when offline") {
                let resolution = ExperimentResolver.resolve(
                    variantIds: ["a", "b"],
                    assignment: nil,
                    frozenVariantKey: nil,
                    hasEmittedExposure: false
                )
                expect(resolution.variantId) == "a"
                expect(resolution.shouldFreezeVariant) == false
                expect(resolution.exposure) == .fallback(assignmentSource: "no_assignment")
            }

            it("tags the fallback with the non-running status") {
                let resolution = ExperimentResolver.resolve(
                    variantIds: ["a"],
                    assignment: assignment(status: "paused", variantKey: "a"),
                    frozenVariantKey: nil,
                    hasEmittedExposure: false
                )
                expect(resolution.variantId) == "a"
                expect(resolution.exposure) == .fallback(assignmentSource: "status_paused")
            }

            it("uses the concluded assignment without freezing") {
                let resolution = ExperimentResolver.resolve(
                    variantIds: ["a", "b"],
                    assignment: assignment(status: "concluded", variantKey: "b"),
                    frozenVariantKey: nil,
                    hasEmittedExposure: false
                )
                expect(resolution.variantId) == "b"
                expect(resolution.shouldFreezeVariant) == false
                expect(resolution.exposure) == .fallback(assignmentSource: "status_concluded")
            }

            it("emits no exposure when one was already emitted") {
                let resolution = ExperimentResolver.resolve(
                    variantIds: ["a"],
                    assignment: assignment(status: "running", variantKey: "a"),
                    frozenVariantKey: nil,
                    hasEmittedExposure: true
                )
                expect(resolution.variantId) == "a"
                expect(resolution.exposure) == ExperimentResolver.Exposure.none
            }

            it("resolves through assignment when the frozen key no longer exists in the action") {
                let resolution = ExperimentResolver.resolve(
                    variantIds: ["a", "b"],
                    assignment: assignment(status: "running", variantKey: "a"),
                    frozenVariantKey: "removed",
                    hasEmittedExposure: false
                )
                expect(resolution.variantId) == "a"
                // frozenVariant missing → re-freeze is allowed.
                expect(resolution.shouldFreezeVariant) == true
                expect(resolution.exposure) == .real(assignmentSource: "profile", isHoldout: false)
            }
        }

        describe("journey-context coercion") {
            it("reads the frozen variant key") {
                let context: [String: Any] = ["exp": "b"]
                expect(ExperimentResolver.frozenVariantKey(in: context, experimentKey: "exp")) == "b"
                expect(ExperimentResolver.frozenVariantKey(in: context, experimentKey: "other")).to(beNil())
                expect(ExperimentResolver.frozenVariantKey(in: nil, experimentKey: "exp")).to(beNil())
            }

            it("coerces Bool, Int, and String exposure markers") {
                expect(ExperimentResolver.exposureEmitted(in: ["exp": true], experimentKey: "exp")) == true
                expect(ExperimentResolver.exposureEmitted(in: ["exp": 1], experimentKey: "exp")) == true
                expect(ExperimentResolver.exposureEmitted(in: ["exp": 0], experimentKey: "exp")) == false
                expect(ExperimentResolver.exposureEmitted(in: ["exp": "true"], experimentKey: "exp")) == true
                expect(ExperimentResolver.exposureEmitted(in: ["exp": "1"], experimentKey: "exp")) == true
                expect(ExperimentResolver.exposureEmitted(in: ["exp": "no"], experimentKey: "exp")) == false
                expect(ExperimentResolver.exposureEmitted(in: nil, experimentKey: "exp")) == false
            }
        }
    }
}
