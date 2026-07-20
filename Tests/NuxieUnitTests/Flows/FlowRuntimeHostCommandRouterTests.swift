import Foundation
import Nimble
import Quick
import XCTest
@testable import Nuxie

final class FlowRuntimeHostCommandRouterTests: QuickSpec {
    override class func spec() {
        // These tests intentionally stop at the typed FlowRuntimeHostEvent
        // seam. The native flow coordinator will consume it directly during
        // renderer cutover; this router must not project values through `Any`
        // or the legacy Rive event bridge.
        describe("FlowRuntimeHostCommandRouter") {
            it("drains creation and operation commands in one FIFO") {
                var router = FlowRuntimeHostCommandRouter()
                let checkout = FlowRuntimeHostObject(fields: [
                    FlowRuntimeHostObjectField(name: "plan", value: .string("pro")),
                ])
                let response = FlowRuntimeHostObject(fields: [
                    FlowRuntimeHostObjectField(name: "field", value: .string("goal")),
                    FlowRuntimeHostObjectField(name: "value", value: .string("lose_weight")),
                ])

                try router.enqueue([
                    FlowRuntimeOutput(
                        sequence: 7,
                        cycle: 0,
                        phase: .hostWork,
                        payload: .hostCommand(name: "checkout", payload: .object(checkout))
                    ),
                ])
                try router.enqueue([
                    FlowRuntimeOutput(
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
                var router = FlowRuntimeHostCommandRouter()
                let properties = FlowRuntimeHostObject(fields: [
                    FlowRuntimeHostObjectField(name: "component_id", value: .string("button-2")),
                    FlowRuntimeHostObjectField(name: "instanceId", value: .string("row-9")),
                    FlowRuntimeHostObjectField(name: "screen_id", value: .string("screen-authored")),
                    FlowRuntimeHostObjectField(name: "value", value: .number(3)),
                ])
                try router.enqueue([
                    FlowRuntimeOutput(
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
                expect(event.metadata).to(equal(FlowRuntimeHostCommandMetadata(
                    sequence: 22,
                    cycle: 4,
                    phase: .hostWork
                )))
            }

            it("rejects non-object commands without partially enqueuing the batch") {
                var router = FlowRuntimeHostCommandRouter()
                let valid = FlowRuntimeOutput(
                    sequence: 1,
                    cycle: 0,
                    phase: .hostWork,
                    payload: .hostCommand(name: "valid", payload: .object(.empty))
                )
                let invalid = FlowRuntimeOutput(
                    sequence: 2,
                    cycle: 0,
                    phase: .hostWork,
                    payload: .hostCommand(name: "invalid", payload: .string("wrong"))
                )

                expect { try router.enqueue([valid, invalid]) }.to(
                    throwError(FlowRuntimeHostCommandRouterError.nonObjectPayload(name: "invalid"))
                )
                expect(router.drain(currentScreenID: "screen-1")).to(beEmpty())
            }
        }
    }
}
