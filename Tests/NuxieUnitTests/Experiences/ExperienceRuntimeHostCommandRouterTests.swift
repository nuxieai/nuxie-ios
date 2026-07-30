import Foundation
import Nimble
import Quick
import XCTest
@testable import Nuxie

final class ExperienceRuntimeHostCommandRouterTests: QuickSpec {
    override class func spec() {
        // These tests intentionally stop at the typed ExperienceRuntimeHostEvent
        // seam. The native flow coordinator will consume it directly during
        // renderer cutover; this router must not project values through `Any`
        // or a renderer-specific event bridge.
        describe("ExperienceRuntimeHostCommandRouter") {
            it("drains creation and operation commands in one FIFO") {
                var router = ExperienceRuntimeHostCommandRouter()
                let checkout = ExperienceRuntimeHostObject(fields: [
                    ExperienceRuntimeHostObjectField(name: "plan", value: .string("pro")),
                ])
                let response = ExperienceRuntimeHostObject(fields: [
                    ExperienceRuntimeHostObjectField(name: "field", value: .string("goal")),
                    ExperienceRuntimeHostObjectField(name: "value", value: .string("lose_weight")),
                ])

                try router.enqueue([
                    ExperienceRuntimeOutput(
                        sequence: 7,
                        cycle: 0,
                        phase: .hostWork,
                        payload: .hostCommand(name: "checkout", payload: .object(checkout))
                    ),
                ])
                try router.enqueue([
                    ExperienceRuntimeOutput(
                        sequence: 8,
                        cycle: 1,
                        phase: .hostWork,
                        payload: .hostCommand(
                            name: SystemEventNames.responseSet,
                            payload: .object(response)
                        )
                    ),
                ])

                let events = router.drain(currentScreenID: "screen-default")

                expect(events.map(\.name)).to(equal(["checkout", SystemEventNames.responseSet]))
                expect(events.map(\.metadata.sequence)).to(equal([7, 8]))
                expect(events.map(\.metadata.cycle)).to(equal([0, 1]))
                expect(events.map(\.screenID)).to(equal(["screen-default", "screen-default"]))
                expect(events[1].properties["field"]).to(equal(.string("goal")))
                expect(events[1].properties["value"]).to(equal(.string("lose_weight")))
                expect(router.drain(currentScreenID: "screen-default")).to(beEmpty())
            }

            it("preserves payload metadata and legacy metadata aliases") {
                var router = ExperienceRuntimeHostCommandRouter()
                let properties = ExperienceRuntimeHostObject(fields: [
                    ExperienceRuntimeHostObjectField(name: "component_id", value: .string("button-2")),
                    ExperienceRuntimeHostObjectField(name: "instanceId", value: .string("row-9")),
                    ExperienceRuntimeHostObjectField(name: "screen_id", value: .string("screen-authored")),
                    ExperienceRuntimeHostObjectField(name: "value", value: .number(3)),
                ])
                try router.enqueue([
                    ExperienceRuntimeOutput(
                        sequence: 22,
                        cycle: 4,
                        phase: .hostWork,
                        payload: .hostCommand(name: "selected", payload: .object(properties))
                    ),
                ])

                let event = try XCTUnwrap(
                    router.drain(currentScreenID: "screen-default").first
                )

                expect(event.screenID).to(equal("screen-authored"))
                expect(event.componentID).to(equal("button-2"))
                expect(event.instanceID).to(equal("row-9"))
                expect(event.properties).to(equal(properties))
                expect(event.metadata).to(equal(ExperienceRuntimeHostCommandMetadata(
                    sequence: 22,
                    cycle: 4,
                    phase: .hostWork
                )))
            }

            it("rejects non-object commands without partially enqueuing the batch") {
                var router = ExperienceRuntimeHostCommandRouter()
                let valid = ExperienceRuntimeOutput(
                    sequence: 1,
                    cycle: 0,
                    phase: .hostWork,
                    payload: .hostCommand(name: "valid", payload: .object(.empty))
                )
                let invalid = ExperienceRuntimeOutput(
                    sequence: 2,
                    cycle: 0,
                    phase: .hostWork,
                    payload: .hostCommand(name: "invalid", payload: .string("wrong"))
                )

                expect { try router.enqueue([valid, invalid]) }.to(
                    throwError(ExperienceRuntimeHostCommandRouterError.nonObjectPayload(name: "invalid"))
                )
                expect(router.drain(currentScreenID: "screen-1")).to(beEmpty())
            }
        }
    }
}
