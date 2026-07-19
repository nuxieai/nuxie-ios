import Foundation
import Nimble
import Quick
@testable import Nuxie

final class FlowRuntimeSessionTypesTests: QuickSpec {
    override class func spec() {
        func instanceID(_ value: UInt64) -> FlowRuntimeInstanceID {
            FlowRuntimeInstanceID(rawValue: value)!
        }

        describe("FlowRuntimeValueArena") {
            it("preserves authored list indexes as their own scalar kind") {
                let arena = FlowRuntimeValueArena(
                    nodes: [FlowRuntimeValueNode(value: .scalar(.listIndex(3)))],
                    roots: [FlowRuntimeValueRoot(instanceID: instanceID(1), nodeIndex: 0)]
                )

                expect { try arena.validate() }.toNot(throwError())
                expect(arena.nodes.first?.value).to(equal(.scalar(.listIndex(3))))
            }

            it("preserves shared value identity across roots and list rows") {
                let shared = FlowRuntimeValueNode(
                    value: .viewModel(
                        schemaID: "Reason",
                        instanceID: instanceID(2),
                        fields: [FlowRuntimeValueEdge(key: "title", nodeIndex: 2)]
                    )
                )
                let arena = FlowRuntimeValueArena(
                    nodes: [
                        FlowRuntimeValueNode(
                            value: .list(items: [
                                FlowRuntimeValueEdge(key: nil, nodeIndex: 1),
                            ])
                        ),
                        shared,
                        FlowRuntimeValueNode(value: .scalar(.string("Too expensive"))),
                    ],
                    roots: [
                        FlowRuntimeValueRoot(instanceID: instanceID(1), nodeIndex: 0),
                        FlowRuntimeValueRoot(instanceID: instanceID(2), nodeIndex: 1),
                    ]
                )

                expect { try arena.validate() }.toNot(throwError())
                guard case .list(let rows) = arena.nodes[0].value else {
                    fail("expected list root")
                    return
                }
                expect(rows.first?.nodeIndex).to(equal(arena.roots[1].nodeIndex))
            }

            it("rejects cycles, missing nodes, and duplicate stable roots") {
                let cyclic = FlowRuntimeValueArena(
                    nodes: [
                        FlowRuntimeValueNode(
                            value: .list(items: [FlowRuntimeValueEdge(key: nil, nodeIndex: 0)])
                        ),
                    ],
                    roots: [FlowRuntimeValueRoot(instanceID: instanceID(1), nodeIndex: 0)]
                )
                expect { try cyclic.validate() }.to(
                    throwError(
                        FlowRuntimeSessionValueError.invalidGraph(
                            "Runtime value graph contains a cycle"
                        )
                    )
                )

                let missing = FlowRuntimeValueArena(
                    nodes: [
                        FlowRuntimeValueNode(
                            value: .list(items: [FlowRuntimeValueEdge(key: nil, nodeIndex: 4)])
                        ),
                    ],
                    roots: [FlowRuntimeValueRoot(instanceID: instanceID(1), nodeIndex: 0)]
                )
                expect { try missing.validate() }.to(
                    throwError(
                        FlowRuntimeSessionValueError.invalidGraph(
                            "Runtime value edge references a missing node"
                        )
                    )
                )

                let duplicate = FlowRuntimeValueArena(
                    nodes: [FlowRuntimeValueNode(value: .scalar(.null))],
                    roots: [
                        FlowRuntimeValueRoot(instanceID: instanceID(1), nodeIndex: 0),
                        FlowRuntimeValueRoot(instanceID: instanceID(1), nodeIndex: 0),
                    ]
                )
                expect { try duplicate.validate() }.to(
                    throwError(
                        FlowRuntimeSessionValueError.invalidGraph(
                            "Runtime value arena contains a duplicate instance root"
                        )
                    )
                )
            }

            it("rejects invalid composite edge keys and nonfinite numbers") {
                let keyedList = FlowRuntimeValueArena(
                    nodes: [
                        FlowRuntimeValueNode(
                            value: .list(items: [FlowRuntimeValueEdge(key: "wrong", nodeIndex: 1)])
                        ),
                        FlowRuntimeValueNode(value: .scalar(.null)),
                    ],
                    roots: [FlowRuntimeValueRoot(instanceID: instanceID(1), nodeIndex: 0)]
                )
                expect { try keyedList.validate() }.to(
                    throwError(
                        FlowRuntimeSessionValueError.invalidGraph(
                            "Runtime list edge unexpectedly has a field key"
                        )
                    )
                )

                let nonfinite = FlowRuntimeValueArena(
                    nodes: [FlowRuntimeValueNode(value: .scalar(.number(.infinity)))],
                    roots: [FlowRuntimeValueRoot(instanceID: instanceID(1), nodeIndex: 0)]
                )
                expect { try nonfinite.validate() }.to(
                    throwError(
                        FlowRuntimeSessionValueError.invalidValue(
                            "Runtime number must be finite"
                        )
                    )
                )
            }
        }

        describe("FlowRuntimeMutationEchoSuppressor") {
            it("suppresses only an exact mutation-id, instance, path, and value echo") {
                let expected = FlowRuntimeMutationEchoSuppressor.Expected(
                    instanceID: instanceID(7),
                    path: "checkout/quantity",
                    value: .number(2)
                )
                var suppressor = FlowRuntimeMutationEchoSuppressor()
                suppressor.register(mutationID: 41, expected: [expected])

                expect(suppressor.shouldSuppress(FlowRuntimeStateChange(
                    instanceID: instanceID(7),
                    path: "checkout/quantity",
                    value: .number(3),
                    originMutationID: 41
                ))).to(beFalse())
                expect(suppressor.shouldSuppress(FlowRuntimeStateChange(
                    instanceID: instanceID(7),
                    path: "checkout/quantity",
                    value: .number(2),
                    originMutationID: nil
                ))).to(beFalse())
                expect(suppressor.shouldSuppress(FlowRuntimeStateChange(
                    instanceID: instanceID(7),
                    path: "checkout/quantity",
                    value: .number(2),
                    originMutationID: 41
                ))).to(beTrue())

                // The exact direct echo is consumed once; authored follow-up
                // effects with the same value are still observable.
                expect(suppressor.shouldSuppress(FlowRuntimeStateChange(
                    instanceID: instanceID(7),
                    path: "checkout/quantity",
                    value: .number(2),
                    originMutationID: 41
                ))).to(beFalse())
            }

            it("tracks repeated equal writes as distinct direct echoes") {
                let expected = FlowRuntimeMutationEchoSuppressor.Expected(
                    instanceID: nil,
                    path: "enabled",
                    value: .bool(true)
                )
                var suppressor = FlowRuntimeMutationEchoSuppressor()
                suppressor.register(mutationID: 9, expected: [expected, expected])

                let echo = FlowRuntimeStateChange(
                    instanceID: nil,
                    path: "enabled",
                    value: .bool(true),
                    originMutationID: 9
                )
                expect(suppressor.shouldSuppress(echo)).to(beTrue())
                expect(suppressor.shouldSuppress(echo)).to(beTrue())
                expect(suppressor.shouldSuppress(echo)).to(beFalse())
            }
        }

        describe("FlowRuntimeInstanceID") {
            it("rejects the ABI null identity") {
                expect(FlowRuntimeInstanceID(rawValue: 0)).to(beNil())
                expect(FlowRuntimeInstanceID(rawValue: 1)?.rawValue).to(equal(1))
            }
        }

        describe("FlowRuntimeSchemaProperty") {
            it("retains authored enum labels and nested schema identity") {
                let enumeration = FlowRuntimeSchemaProperty(
                    schemaID: "Main",
                    propertyID: "state",
                    name: "state",
                    kind: .enumeration,
                    enumValues: ["red", "green", "blue"]
                )
                let child = FlowRuntimeSchemaProperty(
                    schemaID: "Main",
                    propertyID: "child",
                    name: "child",
                    kind: .viewModel,
                    referencedSchemaID: "Child"
                )

                expect(enumeration.enumValues).to(equal(["red", "green", "blue"]))
                expect(enumeration.referencedSchemaID).to(beNil())
                expect(child.enumValues).to(beEmpty())
                expect(child.referencedSchemaID).to(equal("Child"))
            }
        }
    }
}
