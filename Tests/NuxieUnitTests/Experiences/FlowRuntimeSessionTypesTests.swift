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

            it("decodes recursive host values with deterministic object fields") {
                let arena = FlowRuntimeValueArena(
                    nodes: [
                        FlowRuntimeValueNode(
                            value: .object(
                                schemaID: nil,
                                fields: [
                                    FlowRuntimeValueEdge(key: "zeta", nodeIndex: 1),
                                    FlowRuntimeValueEdge(key: "alpha", nodeIndex: 2),
                                ]
                            )
                        ),
                        FlowRuntimeValueNode(
                            value: .list(items: [
                                FlowRuntimeValueEdge(key: nil, nodeIndex: 3),
                                FlowRuntimeValueEdge(key: nil, nodeIndex: 4),
                            ])
                        ),
                        FlowRuntimeValueNode(value: .scalar(.string("first"))),
                        FlowRuntimeValueNode(value: .scalar(.bool(true))),
                        FlowRuntimeValueNode(value: .scalar(.number(42))),
                    ],
                    roots: []
                )

                let payload = try arena.hostValue(at: 0)

                expect(payload).to(equal(.object(FlowRuntimeHostObject(fields: [
                    FlowRuntimeHostObjectField(name: "alpha", value: .string("first")),
                    FlowRuntimeHostObjectField(
                        name: "zeta",
                        value: .array([.bool(true), .number(42)])
                    ),
                ]))))
                guard case .object(let object) = payload else {
                    fail("expected an object payload")
                    return
                }
                expect(object.fields.map(\.name)).to(equal(["alpha", "zeta"]))
            }

            it("preserves finite host numbers across the full f64 result domain") {
                let value = Double(Float.greatestFiniteMagnitude) * 2
                let arena = FlowRuntimeValueArena(
                    nodes: [
                        FlowRuntimeValueNode(
                            value: .object(
                                schemaID: nil,
                                fields: [FlowRuntimeValueEdge(key: "value", nodeIndex: 1)]
                            )
                        ),
                        FlowRuntimeValueNode(value: .scalar(.number(value))),
                    ],
                    roots: []
                )

                expect { try arena.hostValue(at: 0) }.to(equal(.object(
                    FlowRuntimeHostObject(fields: [
                        FlowRuntimeHostObjectField(name: "value", value: .number(value)),
                    ])
                )))
            }

            it("preserves canonically equivalent object keys by exact UTF-8 identity") {
                let composed = "\u{00e9}"
                let decomposed = "e\u{0301}"
                let object = FlowRuntimeHostObject(fields: [
                    FlowRuntimeHostObjectField(name: composed, value: .string("composed")),
                    FlowRuntimeHostObjectField(name: decomposed, value: .string("decomposed")),
                ])

                expect(object.fields.map { Array($0.name.utf8) }).to(equal([
                    Array(decomposed.utf8),
                    Array(composed.utf8),
                ]))
                expect(object[composed]).to(equal(.string("composed")))
                expect(object[decomposed]).to(equal(.string("decomposed")))
                expect(object.fields[0]).toNot(equal(object.fields[1]))

                let arena = FlowRuntimeValueArena(
                    nodes: [
                        FlowRuntimeValueNode(value: .object(
                            schemaID: nil,
                            fields: [
                                FlowRuntimeValueEdge(key: composed, nodeIndex: 1),
                                FlowRuntimeValueEdge(key: decomposed, nodeIndex: 2),
                            ]
                        )),
                        FlowRuntimeValueNode(value: .scalar(.string("composed"))),
                        FlowRuntimeValueNode(value: .scalar(.string("decomposed"))),
                    ],
                    roots: []
                )
                expect { try arena.hostValue(at: 0) }.to(equal(.object(object)))
            }

            it("rejects runtime-only scalar and ViewModel values as host payloads") {
                let runtimeScalar = FlowRuntimeValueArena(
                    nodes: [FlowRuntimeValueNode(value: .scalar(.color(0xff00ffff)))],
                    roots: []
                )
                expect { try runtimeScalar.hostValue(at: 0) }.to(
                    throwError(
                        FlowRuntimeSessionValueError.invalidValue(
                            "Runtime host value node 0 has unsupported scalar kind"
                        )
                    )
                )

                let viewModel = FlowRuntimeValueArena(
                    nodes: [
                        FlowRuntimeValueNode(
                            value: .viewModel(
                                schemaID: "Payload",
                                instanceID: instanceID(2),
                                fields: []
                            )
                        ),
                    ],
                    roots: []
                )
                expect { try viewModel.hostValue(at: 0) }.to(
                    throwError(
                        FlowRuntimeSessionValueError.invalidValue(
                            "Runtime host value node 0 cannot be a ViewModel"
                        )
                    )
                )
            }

            it("rejects aliased host nodes before recursively materializing them") {
                let arena = FlowRuntimeValueArena(
                    nodes: [
                        FlowRuntimeValueNode(value: .object(
                            schemaID: nil,
                            fields: [
                                FlowRuntimeValueEdge(key: "first", nodeIndex: 1),
                                FlowRuntimeValueEdge(key: "second", nodeIndex: 1),
                            ]
                        )),
                        FlowRuntimeValueNode(value: .scalar(.bool(true))),
                    ],
                    roots: []
                )

                expect { try arena.hostValue(at: 0) }.to(
                    throwError(
                        FlowRuntimeSessionValueError.invalidGraph(
                            "Runtime host value graph contains an alias or cycle"
                        )
                    )
                )
            }

            it("uses the runtime's one-based thirty-two-level host-value depth bound") {
                func nestedHostArena(depth: Int) -> FlowRuntimeValueArena {
                    let nodes = (0..<depth).map { index in
                        if index == depth - 1 {
                            return FlowRuntimeValueNode(value: .scalar(.bool(true)))
                        }
                        return FlowRuntimeValueNode(value: .list(items: [
                            FlowRuntimeValueEdge(key: nil, nodeIndex: index + 1),
                        ]))
                    }
                    return FlowRuntimeValueArena(nodes: nodes, roots: [])
                }

                expect { try nestedHostArena(depth: 32).hostValue(at: 0) }.toNot(throwError())
                expect { try nestedHostArena(depth: 33).hostValue(at: 0) }.to(
                    throwError(
                        FlowRuntimeSessionValueError.limitExceeded(
                            "Runtime host value graph depth limit exceeded"
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

            it("matches view-model replacement echoes by child identity") {
                let child = FlowRuntimeViewModelReference(
                    schemaID: "Child",
                    instanceID: instanceID(9)
                )
                var suppressor = FlowRuntimeMutationEchoSuppressor()
                suppressor.register(mutationID: 12, expected: [
                    FlowRuntimeMutationEchoSuppressor.Expected(
                        instanceID: instanceID(1),
                        path: "child",
                        value: nil,
                        viewModelReference: child
                    ),
                ])

                expect(suppressor.shouldSuppress(FlowRuntimeStateChange(
                    instanceID: instanceID(1),
                    path: "child",
                    value: nil,
                    viewModelReference: FlowRuntimeViewModelReference(
                        schemaID: "Child",
                        instanceID: instanceID(10)
                    ),
                    originMutationID: 12
                ))).to(beFalse())
                expect(suppressor.shouldSuppress(FlowRuntimeStateChange(
                    instanceID: instanceID(1),
                    path: "child",
                    value: nil,
                    viewModelReference: child,
                    originMutationID: 12
                ))).to(beTrue())
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
