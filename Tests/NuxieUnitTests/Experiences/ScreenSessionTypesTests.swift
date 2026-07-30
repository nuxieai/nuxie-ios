import Foundation
import Nimble
import Quick
@testable import Nuxie

final class ScreenSessionTypesTests: QuickSpec {
    override class func spec() {
        func instanceID(_ value: UInt64) -> ExperienceRuntimeInstanceID {
            ExperienceRuntimeInstanceID(rawValue: value)!
        }

        describe("ExperienceRuntimeValueArena") {
            it("preserves authored list indexes as their own scalar kind") {
                let arena = ExperienceRuntimeValueArena(
                    nodes: [ExperienceRuntimeValueNode(value: .scalar(.listIndex(3)))],
                    roots: [ExperienceRuntimeValueRoot(instanceID: instanceID(1), nodeIndex: 0)]
                )

                expect { try arena.validate() }.toNot(throwError())
                expect(arena.nodes.first?.value).to(equal(.scalar(.listIndex(3))))
            }

            it("preserves shared value identity across roots and list rows") {
                let shared = ExperienceRuntimeValueNode(
                    value: .viewModel(
                        schemaID: "Reason",
                        instanceID: instanceID(2),
                        fields: [ExperienceRuntimeValueEdge(key: "title", nodeIndex: 2)]
                    )
                )
                let arena = ExperienceRuntimeValueArena(
                    nodes: [
                        ExperienceRuntimeValueNode(
                            value: .list(items: [
                                ExperienceRuntimeValueEdge(key: nil, nodeIndex: 1),
                            ])
                        ),
                        shared,
                        ExperienceRuntimeValueNode(value: .scalar(.string("Too expensive"))),
                    ],
                    roots: [
                        ExperienceRuntimeValueRoot(instanceID: instanceID(1), nodeIndex: 0),
                        ExperienceRuntimeValueRoot(instanceID: instanceID(2), nodeIndex: 1),
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
                let cyclic = ExperienceRuntimeValueArena(
                    nodes: [
                        ExperienceRuntimeValueNode(
                            value: .list(items: [ExperienceRuntimeValueEdge(key: nil, nodeIndex: 0)])
                        ),
                    ],
                    roots: [ExperienceRuntimeValueRoot(instanceID: instanceID(1), nodeIndex: 0)]
                )
                expect { try cyclic.validate() }.to(
                    throwError(
                        ScreenSessionValueError.invalidGraph(
                            "Runtime value graph contains a cycle"
                        )
                    )
                )

                let missing = ExperienceRuntimeValueArena(
                    nodes: [
                        ExperienceRuntimeValueNode(
                            value: .list(items: [ExperienceRuntimeValueEdge(key: nil, nodeIndex: 4)])
                        ),
                    ],
                    roots: [ExperienceRuntimeValueRoot(instanceID: instanceID(1), nodeIndex: 0)]
                )
                expect { try missing.validate() }.to(
                    throwError(
                        ScreenSessionValueError.invalidGraph(
                            "Runtime value edge references a missing node"
                        )
                    )
                )

                let duplicate = ExperienceRuntimeValueArena(
                    nodes: [ExperienceRuntimeValueNode(value: .scalar(.null))],
                    roots: [
                        ExperienceRuntimeValueRoot(instanceID: instanceID(1), nodeIndex: 0),
                        ExperienceRuntimeValueRoot(instanceID: instanceID(1), nodeIndex: 0),
                    ]
                )
                expect { try duplicate.validate() }.to(
                    throwError(
                        ScreenSessionValueError.invalidGraph(
                            "Runtime value arena contains a duplicate instance root"
                        )
                    )
                )
            }

            it("rejects invalid composite edge keys and nonfinite numbers") {
                let keyedList = ExperienceRuntimeValueArena(
                    nodes: [
                        ExperienceRuntimeValueNode(
                            value: .list(items: [ExperienceRuntimeValueEdge(key: "wrong", nodeIndex: 1)])
                        ),
                        ExperienceRuntimeValueNode(value: .scalar(.null)),
                    ],
                    roots: [ExperienceRuntimeValueRoot(instanceID: instanceID(1), nodeIndex: 0)]
                )
                expect { try keyedList.validate() }.to(
                    throwError(
                        ScreenSessionValueError.invalidGraph(
                            "Runtime list edge unexpectedly has a field key"
                        )
                    )
                )

                let nonfinite = ExperienceRuntimeValueArena(
                    nodes: [ExperienceRuntimeValueNode(value: .scalar(.number(.infinity)))],
                    roots: [ExperienceRuntimeValueRoot(instanceID: instanceID(1), nodeIndex: 0)]
                )
                expect { try nonfinite.validate() }.to(
                    throwError(
                        ScreenSessionValueError.invalidValue(
                            "Runtime number must be finite"
                        )
                    )
                )
            }

            it("decodes recursive host values with deterministic object fields") {
                let arena = ExperienceRuntimeValueArena(
                    nodes: [
                        ExperienceRuntimeValueNode(
                            value: .object(
                                schemaID: nil,
                                fields: [
                                    ExperienceRuntimeValueEdge(key: "zeta", nodeIndex: 1),
                                    ExperienceRuntimeValueEdge(key: "alpha", nodeIndex: 2),
                                ]
                            )
                        ),
                        ExperienceRuntimeValueNode(
                            value: .list(items: [
                                ExperienceRuntimeValueEdge(key: nil, nodeIndex: 3),
                                ExperienceRuntimeValueEdge(key: nil, nodeIndex: 4),
                            ])
                        ),
                        ExperienceRuntimeValueNode(value: .scalar(.string("first"))),
                        ExperienceRuntimeValueNode(value: .scalar(.bool(true))),
                        ExperienceRuntimeValueNode(value: .scalar(.number(42))),
                    ],
                    roots: []
                )

                let payload = try arena.hostValue(at: 0)

                expect(payload).to(equal(.object(ExperienceRuntimeHostObject(fields: [
                    ExperienceRuntimeHostObjectField(name: "alpha", value: .string("first")),
                    ExperienceRuntimeHostObjectField(
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
                let arena = ExperienceRuntimeValueArena(
                    nodes: [
                        ExperienceRuntimeValueNode(
                            value: .object(
                                schemaID: nil,
                                fields: [ExperienceRuntimeValueEdge(key: "value", nodeIndex: 1)]
                            )
                        ),
                        ExperienceRuntimeValueNode(value: .scalar(.number(value))),
                    ],
                    roots: []
                )

                expect { try arena.hostValue(at: 0) }.to(equal(.object(
                    ExperienceRuntimeHostObject(fields: [
                        ExperienceRuntimeHostObjectField(name: "value", value: .number(value)),
                    ])
                )))
            }

            it("preserves canonically equivalent object keys by exact UTF-8 identity") {
                let composed = "\u{00e9}"
                let decomposed = "e\u{0301}"
                let object = ExperienceRuntimeHostObject(fields: [
                    ExperienceRuntimeHostObjectField(name: composed, value: .string("composed")),
                    ExperienceRuntimeHostObjectField(name: decomposed, value: .string("decomposed")),
                ])

                expect(object.fields.map { Array($0.name.utf8) }).to(equal([
                    Array(decomposed.utf8),
                    Array(composed.utf8),
                ]))
                expect(object[composed]).to(equal(.string("composed")))
                expect(object[decomposed]).to(equal(.string("decomposed")))
                expect(object.fields[0]).toNot(equal(object.fields[1]))

                let arena = ExperienceRuntimeValueArena(
                    nodes: [
                        ExperienceRuntimeValueNode(value: .object(
                            schemaID: nil,
                            fields: [
                                ExperienceRuntimeValueEdge(key: composed, nodeIndex: 1),
                                ExperienceRuntimeValueEdge(key: decomposed, nodeIndex: 2),
                            ]
                        )),
                        ExperienceRuntimeValueNode(value: .scalar(.string("composed"))),
                        ExperienceRuntimeValueNode(value: .scalar(.string("decomposed"))),
                    ],
                    roots: []
                )
                expect { try arena.hostValue(at: 0) }.to(equal(.object(object)))
            }

            it("rejects runtime-only scalar and ViewModel values as host payloads") {
                let runtimeScalar = ExperienceRuntimeValueArena(
                    nodes: [ExperienceRuntimeValueNode(value: .scalar(.color(0xff00ffff)))],
                    roots: []
                )
                expect { try runtimeScalar.hostValue(at: 0) }.to(
                    throwError(
                        ScreenSessionValueError.invalidValue(
                            "Runtime host value node 0 has unsupported scalar kind"
                        )
                    )
                )

                let viewModel = ExperienceRuntimeValueArena(
                    nodes: [
                        ExperienceRuntimeValueNode(
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
                        ScreenSessionValueError.invalidValue(
                            "Runtime host value node 0 cannot be a ViewModel"
                        )
                    )
                )
            }

            it("rejects aliased host nodes before recursively materializing them") {
                let arena = ExperienceRuntimeValueArena(
                    nodes: [
                        ExperienceRuntimeValueNode(value: .object(
                            schemaID: nil,
                            fields: [
                                ExperienceRuntimeValueEdge(key: "first", nodeIndex: 1),
                                ExperienceRuntimeValueEdge(key: "second", nodeIndex: 1),
                            ]
                        )),
                        ExperienceRuntimeValueNode(value: .scalar(.bool(true))),
                    ],
                    roots: []
                )

                expect { try arena.hostValue(at: 0) }.to(
                    throwError(
                        ScreenSessionValueError.invalidGraph(
                            "Runtime host value graph contains an alias or cycle"
                        )
                    )
                )
            }

            it("uses the runtime's one-based thirty-two-level host-value depth bound") {
                func nestedHostArena(depth: Int) -> ExperienceRuntimeValueArena {
                    let nodes = (0..<depth).map { index in
                        if index == depth - 1 {
                            return ExperienceRuntimeValueNode(value: .scalar(.bool(true)))
                        }
                        return ExperienceRuntimeValueNode(value: .list(items: [
                            ExperienceRuntimeValueEdge(key: nil, nodeIndex: index + 1),
                        ]))
                    }
                    return ExperienceRuntimeValueArena(nodes: nodes, roots: [])
                }

                expect { try nestedHostArena(depth: 32).hostValue(at: 0) }.toNot(throwError())
                expect { try nestedHostArena(depth: 33).hostValue(at: 0) }.to(
                    throwError(
                        ScreenSessionValueError.limitExceeded(
                            "Runtime host value graph depth limit exceeded"
                        )
                    )
                )
            }
        }

        describe("ExperienceRuntimeMutationEchoSuppressor") {
            it("suppresses only an exact mutation-id, instance, path, and value echo") {
                let expected = ExperienceRuntimeMutationEchoSuppressor.Expected(
                    instanceID: instanceID(7),
                    path: "checkout/quantity",
                    value: .number(2)
                )
                var suppressor = ExperienceRuntimeMutationEchoSuppressor()
                suppressor.register(mutationID: 41, expected: [expected])

                expect(suppressor.shouldSuppress(ExperienceRuntimeStateChange(
                    instanceID: instanceID(7),
                    path: "checkout/quantity",
                    value: .number(3),
                    originMutationID: 41
                ))).to(beFalse())
                expect(suppressor.shouldSuppress(ExperienceRuntimeStateChange(
                    instanceID: instanceID(7),
                    path: "checkout/quantity",
                    value: .number(2),
                    originMutationID: nil
                ))).to(beFalse())
                expect(suppressor.shouldSuppress(ExperienceRuntimeStateChange(
                    instanceID: instanceID(7),
                    path: "checkout/quantity",
                    value: .number(2),
                    originMutationID: 41
                ))).to(beTrue())

                // The exact direct echo is consumed once; authored follow-up
                // effects with the same value are still observable.
                expect(suppressor.shouldSuppress(ExperienceRuntimeStateChange(
                    instanceID: instanceID(7),
                    path: "checkout/quantity",
                    value: .number(2),
                    originMutationID: 41
                ))).to(beFalse())
            }

            it("tracks repeated equal writes as distinct direct echoes") {
                let expected = ExperienceRuntimeMutationEchoSuppressor.Expected(
                    instanceID: nil,
                    path: "enabled",
                    value: .bool(true)
                )
                var suppressor = ExperienceRuntimeMutationEchoSuppressor()
                suppressor.register(mutationID: 9, expected: [expected, expected])

                let echo = ExperienceRuntimeStateChange(
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
                let child = ExperienceRuntimeViewModelReference(
                    schemaID: "Child",
                    instanceID: instanceID(9)
                )
                var suppressor = ExperienceRuntimeMutationEchoSuppressor()
                suppressor.register(mutationID: 12, expected: [
                    ExperienceRuntimeMutationEchoSuppressor.Expected(
                        instanceID: instanceID(1),
                        path: "child",
                        value: nil,
                        viewModelReference: child
                    ),
                ])

                expect(suppressor.shouldSuppress(ExperienceRuntimeStateChange(
                    instanceID: instanceID(1),
                    path: "child",
                    value: nil,
                    viewModelReference: ExperienceRuntimeViewModelReference(
                        schemaID: "Child",
                        instanceID: instanceID(10)
                    ),
                    originMutationID: 12
                ))).to(beFalse())
                expect(suppressor.shouldSuppress(ExperienceRuntimeStateChange(
                    instanceID: instanceID(1),
                    path: "child",
                    value: nil,
                    viewModelReference: child,
                    originMutationID: 12
                ))).to(beTrue())
            }
        }

        describe("ExperienceRuntimeInstanceID") {
            it("rejects the ABI null identity") {
                expect(ExperienceRuntimeInstanceID(rawValue: 0)).to(beNil())
                expect(ExperienceRuntimeInstanceID(rawValue: 1)?.rawValue).to(equal(1))
            }
        }

        describe("ExperienceRuntimeSchemaProperty") {
            it("retains authored enum labels and nested schema identity") {
                let enumeration = ExperienceRuntimeSchemaProperty(
                    schemaID: "Main",
                    propertyID: "state",
                    name: "state",
                    kind: .enumeration,
                    enumValues: ["red", "green", "blue"]
                )
                let child = ExperienceRuntimeSchemaProperty(
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
