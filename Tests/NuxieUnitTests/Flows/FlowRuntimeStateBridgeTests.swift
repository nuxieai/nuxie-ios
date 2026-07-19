import XCTest
@testable import Nuxie

final class FlowRuntimeStateBridgeTests: XCTestCase {
    func testSnapshotBecomesOneTypedBatchAgainstTheScreenRootInstance() throws {
        let fixture = makeFixture()
        let coordinator = FlowViewModelStateCoordinator(remoteFlow: fixture.remoteFlow)
        let bridge = try FlowRuntimeStateBridge(
            remoteFlow: fixture.remoteFlow,
            screenID: "screen-1",
            bootstrap: fixture.bootstrap,
            coordinator: coordinator
        )

        let batch = try bridge.prepare(.snapshot(FlowViewModelSnapshot(values: [
            value(path: "title", "Welcome"),
            value(path: "count", 2),
            value(path: "enabled", true),
        ])))

        XCTAssertEqual(batch.hostMutationID, 1)
        XCTAssertEqual(batch.newInstances, [])
        XCTAssertEqual(batch.mutations, [
            .setValue(instance: .existing(instanceID(1)), path: "title", value: .string("Welcome")),
            .setValue(instance: .existing(instanceID(1)), path: "count", value: .number(2)),
            .setValue(instance: .existing(instanceID(1)), path: "enabled", value: .bool(true)),
        ])
    }

    func testNumberWritesUseTheExactRuntimeF32RepresentationForEchoSuppression() throws {
        let fixture = makeFixture()
        let bridge = try FlowRuntimeStateBridge(
            remoteFlow: fixture.remoteFlow,
            screenID: "screen-1",
            bootstrap: fixture.bootstrap,
            coordinator: FlowViewModelStateCoordinator(remoteFlow: fixture.remoteFlow)
        )
        let canonicalNumber = Double(Float(0.1))

        let batch = try bridge.prepare(.value(
            path: VmPathRef(viewModelName: "Main", path: "count"),
            value: 0.1,
            instanceID: "main-remote"
        ))

        XCTAssertEqual(batch.mutations, [
            .setValue(
                instance: .existing(instanceID(1)),
                path: "count",
                value: .number(canonicalNumber)
            ),
        ])
        XCTAssertTrue(try bridge.reconcile(FlowRuntimeOperationResult(
            renderOutcome: .notRequested,
            isDirty: true,
            isSettled: true,
            orderedOutputs: [
                output(sequence: 1, change: FlowRuntimeStateChange(
                    instanceID: instanceID(1),
                    path: "count",
                    value: .number(canonicalNumber),
                    originMutationID: batch.hostMutationID
                )),
            ]
        )).isEmpty)
    }

    func testNestedValueAndTriggerInputsUseTheCatalogTypeAndStableRoot() throws {
        let fixture = makeFixture()
        let coordinator = FlowViewModelStateCoordinator(remoteFlow: fixture.remoteFlow)
        let nestedBridge = try FlowRuntimeStateBridge(
            remoteFlow: fixture.remoteFlow,
            screenID: "screen-1",
            bootstrap: fixture.bootstrap,
            coordinator: coordinator
        )

        let nested = try nestedBridge.prepare(.value(
            path: VmPathRef(viewModelName: "Main", path: "settings/subtitle"),
            value: "After subtitle",
            instanceID: "main-remote"
        ))

        XCTAssertEqual(nested.mutations, [
            .setValue(
                instance: .existing(instanceID(1)),
                path: "settings/subtitle",
                value: .string("After subtitle")
            ),
        ])

        let triggerBridge = try FlowRuntimeStateBridge(
            remoteFlow: fixture.remoteFlow,
            screenID: "screen-1",
            bootstrap: fixture.bootstrap,
            coordinator: coordinator
        )
        let trigger = try triggerBridge.prepare(.trigger(
            path: VmPathRef(viewModelName: "Main", path: "pulse"),
            instanceID: "main-remote"
        ))
        XCTAssertEqual(trigger.mutations, [
            .fireTrigger(instance: .existing(instanceID(1)), path: "pulse"),
        ])
    }

    func testReconcileSuppressesOnlyExactEchoesAndAppliesOrderedRuntimeChanges() throws {
        let fixture = makeFixture()
        let coordinator = FlowViewModelStateCoordinator(remoteFlow: fixture.remoteFlow)
        let bridge = try FlowRuntimeStateBridge(
            remoteFlow: fixture.remoteFlow,
            screenID: "screen-1",
            bootstrap: fixture.bootstrap,
            coordinator: coordinator
        )
        let batch = try bridge.prepare(.value(
            path: VmPathRef(viewModelName: "Main", path: "title"),
            value: "Host title",
            instanceID: "main-remote"
        ))

        let emitted = try bridge.reconcile(FlowRuntimeOperationResult(
            renderOutcome: .notRequested,
            isDirty: true,
            isSettled: true,
            orderedOutputs: [
                output(
                    sequence: 10,
                    change: FlowRuntimeStateChange(
                        instanceID: instanceID(1),
                        path: "title",
                        value: .string("Host title"),
                        originMutationID: batch.hostMutationID
                    )
                ),
                output(
                    sequence: 11,
                    change: FlowRuntimeStateChange(
                        instanceID: instanceID(1),
                        path: "count",
                        value: .number(3),
                        originMutationID: nil
                    )
                ),
                output(
                    sequence: 12,
                    change: FlowRuntimeStateChange(
                        instanceID: instanceID(1),
                        path: "safeArea/top",
                        value: .number(12),
                        originMutationID: nil
                    )
                ),
                output(
                    sequence: 13,
                    change: FlowRuntimeStateChange(
                        instanceID: instanceID(1),
                        path: "nuxieTextInputs/value",
                        value: .string("private host text"),
                        originMutationID: nil
                    )
                ),
            ]
        ))

        XCTAssertEqual(emitted.count, 1)
        XCTAssertEqual(emitted[0].path, VmPathRef(viewModelName: "Main", path: "count"))
        XCTAssertEqual(emitted[0].value as? Double, 3)
        XCTAssertEqual(emitted[0].source, "runtime")
        XCTAssertEqual(emitted[0].screenId, "screen-1")
        XCTAssertEqual(emitted[0].instanceId, "main-remote")
        XCTAssertFalse(emitted[0].isTrigger)
        XCTAssertEqual(
            coordinator.getValue(
                path: VmPathRef(viewModelName: "Main", path: "count"),
                screenId: "screen-1",
                instanceId: "main-remote"
            ) as? Double,
            3
        )
    }

    func testListInsertCreatesAndSettlesOneStableRemoteItemIdentity() throws {
        let fixture = makeFixture()
        let coordinator = FlowViewModelStateCoordinator(remoteFlow: fixture.remoteFlow)
        let bridge = try FlowRuntimeStateBridge(
            remoteFlow: fixture.remoteFlow,
            screenID: "screen-1",
            bootstrap: fixture.bootstrap,
            coordinator: coordinator
        )

        let batch = try bridge.prepare(.list(
            operation: .insert,
            path: VmPathRef(viewModelName: "Main", path: "items"),
            payload: [
                "value": [
                    "vmInstanceId": "item-c",
                    "viewModelId": "Item",
                    "values": ["label": "C", "rank": 2],
                ],
            ],
            instanceID: "main-remote"
        ))

        XCTAssertEqual(batch.newInstances, [
            FlowRuntimeNewInstance(localID: 1, schemaName: "Item", authoredInstanceName: nil),
        ])
        XCTAssertEqual(batch.mutations, [
            .setValue(instance: .new(localID: 1), path: "label", value: .string("C")),
            .setValue(instance: .new(localID: 1), path: "rank", value: .number(2)),
            .listInsert(
                instance: .existing(instanceID(1)),
                path: "items",
                index: 2,
                item: .new(localID: 1)
            ),
        ])

        let settledID = instanceID(4)
        let emitted = try bridge.reconcile(FlowRuntimeOperationResult(
            renderOutcome: .notRequested,
            isDirty: true,
            isSettled: true,
            orderedOutputs: [
                output(sequence: 20, change: FlowRuntimeStateChange(
                    instanceID: settledID,
                    path: "label",
                    value: .string("C"),
                    originMutationID: batch.hostMutationID
                )),
                output(sequence: 21, change: FlowRuntimeStateChange(
                    instanceID: settledID,
                    path: "rank",
                    value: .number(2),
                    originMutationID: batch.hostMutationID
                )),
                output(sequence: 22, change: FlowRuntimeStateChange(
                    instanceID: instanceID(1),
                    path: "items",
                    value: nil,
                    originMutationID: batch.hostMutationID
                )),
            ],
            createdInstances: [
                FlowRuntimeCreatedInstance(localID: 1, instanceID: settledID),
            ]
        ))
        XCTAssertTrue(emitted.isEmpty)

        let later = try bridge.prepare(.value(
            path: VmPathRef(viewModelName: "Item", path: "label"),
            value: "Updated C",
            instanceID: "item-c"
        ))
        XCTAssertEqual(later.mutations, [
            .setValue(instance: .existing(settledID), path: "label", value: .string("Updated C")),
        ])
    }

    func testCompositeSnapshotPreservesExistingListRowIdentityByPosition() throws {
        let fixture = makeFixture()
        let bridge = try FlowRuntimeStateBridge(
            remoteFlow: fixture.remoteFlow,
            screenID: "screen-1",
            bootstrap: fixture.bootstrap,
            coordinator: FlowViewModelStateCoordinator(remoteFlow: fixture.remoteFlow)
        )

        let batch = try bridge.prepare(.snapshot(FlowViewModelSnapshot(values: [
            value(path: "settings", ["subtitle": "Nested"]),
            value(path: "items", [
                [
                    "vmInstanceId": "item-a",
                    "viewModelId": "Item",
                    "values": ["label": "Updated A"],
                ],
                [
                    "vmInstanceId": "item-b",
                    "viewModelId": "Item",
                    "values": ["label": "Updated B"],
                ],
            ]),
        ])))

        XCTAssertTrue(batch.newInstances.isEmpty)
        XCTAssertEqual(batch.mutations, [
            .setValue(
                instance: .existing(instanceID(1)),
                path: "settings/subtitle",
                value: .string("Nested")
            ),
            .listClear(instance: .existing(instanceID(1)), path: "items"),
            .setValue(instance: .existing(instanceID(2)), path: "label", value: .string("Updated A")),
            .listInsert(
                instance: .existing(instanceID(1)),
                path: "items",
                index: 0,
                item: .existing(instanceID(2))
            ),
            .setValue(instance: .existing(instanceID(3)), path: "label", value: .string("Updated B")),
            .listInsert(
                instance: .existing(instanceID(1)),
                path: "items",
                index: 1,
                item: .existing(instanceID(3))
            ),
        ])
    }

    func testIdentityPreservingListReordersUseExactValidatedIndexes() throws {
        let fixture = makeFixture()
        func bridge() throws -> FlowRuntimeStateBridge {
            try FlowRuntimeStateBridge(
                remoteFlow: fixture.remoteFlow,
                screenID: "screen-1",
                bootstrap: fixture.bootstrap,
                coordinator: FlowViewModelStateCoordinator(remoteFlow: fixture.remoteFlow)
            )
        }
        let path = VmPathRef(viewModelName: "Main", path: "items")

        XCTAssertEqual(try bridge().prepare(.list(
            operation: .remove,
            path: path,
            payload: ["index": 0],
            instanceID: "main-remote"
        )).mutations, [
            .listRemove(instance: .existing(instanceID(1)), path: "items", index: 0),
        ])
        XCTAssertEqual(try bridge().prepare(.list(
            operation: .swap,
            path: path,
            payload: ["indexA": 0, "indexB": 1],
            instanceID: "main-remote"
        )).mutations, [
            .listSwap(
                instance: .existing(instanceID(1)),
                path: "items",
                first: 0,
                second: 1
            ),
        ])
        XCTAssertEqual(try bridge().prepare(.list(
            operation: .move,
            path: path,
            payload: ["from": 0, "to": 2],
            instanceID: "main-remote"
        )).mutations, [
            .listMove(
                instance: .existing(instanceID(1)),
                path: "items",
                from: 0,
                to: 1
            ),
        ])
        XCTAssertEqual(try bridge().prepare(.list(
            operation: .clear,
            path: path,
            payload: [:],
            instanceID: "main-remote"
        )).mutations, [
            .listClear(instance: .existing(instanceID(1)), path: "items"),
        ])

        XCTAssertThrowsError(try bridge().prepare(.list(
            operation: .remove,
            path: path,
            payload: ["index": 2],
            instanceID: "main-remote"
        ))) { error in
            XCTAssertEqual(
                error as? FlowRuntimeStateBridgeError,
                .invalidInput("List remove index 2 is out of range")
            )
        }
    }

    func testRuntimeOriginListChangeUsesAuthoritativeValuesAndReordersCanonicalRows() throws {
        let fixture = makeFixture()
        let coordinator = FlowViewModelStateCoordinator(remoteFlow: fixture.remoteFlow)
        let bridge = try FlowRuntimeStateBridge(
            remoteFlow: fixture.remoteFlow,
            screenID: "screen-1",
            bootstrap: fixture.bootstrap,
            coordinator: coordinator
        )
        let path = VmPathRef(viewModelName: "Main", path: "items")
        let rows: [[String: Any]] = [
            ["vmInstanceId": "item-a", "viewModelId": "Item", "values": ["label": "A"]],
            ["vmInstanceId": "item-b", "viewModelId": "Item", "values": ["label": "B"]],
        ]
        XCTAssertTrue(coordinator.setValue(
            path: path,
            value: rows,
            screenId: "screen-1",
            instanceId: "main-remote"
        ))
        _ = try bridge.prepare(.snapshot(FlowViewModelSnapshot(values: [
            value(path: "items", rows),
        ])))
        _ = try bridge.reconcile(FlowRuntimeOperationResult(
            renderOutcome: .notRequested,
            isDirty: true,
            isSettled: true,
            orderedOutputs: []
        ))

        let emitted = try bridge.reconcile(FlowRuntimeOperationResult(
            renderOutcome: .notRequested,
            isDirty: true,
            isSettled: true,
            orderedOutputs: [
                output(sequence: 20, change: FlowRuntimeStateChange(
                    instanceID: instanceID(1),
                    path: "items",
                    value: nil,
                    originMutationID: nil
                )),
            ],
            values: arenaByReversingFixtureItems(fixture.bootstrap.values)
        ))

        XCTAssertEqual(emitted.count, 1)
        let emittedRows = try XCTUnwrap(emitted[0].value as? [[String: Any]])
        XCTAssertEqual(emittedRows.compactMap { $0["vmInstanceId"] as? String }, [
            "item-b", "item-a",
        ])
        let canonicalRows = try XCTUnwrap(
            coordinator.getValue(
                path: path,
                screenId: "screen-1",
                instanceId: "main-remote"
            ) as? [[String: Any]]
        )
        XCTAssertEqual(canonicalRows.compactMap { $0["vmInstanceId"] as? String }, [
            "item-b", "item-a",
        ])
    }

    func testRuntimeOriginListChangeFailsClosedWithoutAuthoritativeValues() throws {
        let fixture = makeFixture()
        let bridge = try FlowRuntimeStateBridge(
            remoteFlow: fixture.remoteFlow,
            screenID: "screen-1",
            bootstrap: fixture.bootstrap,
            coordinator: FlowViewModelStateCoordinator(remoteFlow: fixture.remoteFlow)
        )

        XCTAssertThrowsError(try bridge.reconcile(FlowRuntimeOperationResult(
            renderOutcome: .notRequested,
            isDirty: true,
            isSettled: true,
            orderedOutputs: [
                output(sequence: 1, change: FlowRuntimeStateChange(
                    instanceID: instanceID(1),
                    path: "items",
                    value: nil,
                    originMutationID: nil
                )),
            ]
        ))) { error in
            guard case .inconsistentResult(let message) = error as? FlowRuntimeStateBridgeError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("authoritative value snapshot"))
        }
    }

    func testFailedReconciliationDoesNotCommitSettledIdentityOrListState() throws {
        let fixture = makeFixture()
        let coordinator = FlowViewModelStateCoordinator(remoteFlow: fixture.remoteFlow)
        let bridge = try FlowRuntimeStateBridge(
            remoteFlow: fixture.remoteFlow,
            screenID: "screen-1",
            bootstrap: fixture.bootstrap,
            coordinator: coordinator
        )
        _ = try bridge.prepare(.list(
            operation: .insert,
            path: VmPathRef(viewModelName: "Main", path: "items"),
            payload: [
                "value": [
                    "vmInstanceId": "item-c",
                    "viewModelId": "Item",
                    "values": ["label": "C"],
                ],
            ],
            instanceID: "main-remote"
        ))

        XCTAssertThrowsError(try bridge.reconcile(FlowRuntimeOperationResult(
            renderOutcome: .notRequested,
            isDirty: true,
            isSettled: true,
            orderedOutputs: [
                output(sequence: 1, change: FlowRuntimeStateChange(
                    instanceID: instanceID(1),
                    path: "count",
                    value: .number(9),
                    originMutationID: nil
                )),
                output(sequence: 2, change: FlowRuntimeStateChange(
                    instanceID: instanceID(1),
                    path: "missing",
                    value: .string("invalid"),
                    originMutationID: nil
                )),
            ],
            createdInstances: [
                FlowRuntimeCreatedInstance(localID: 1, instanceID: instanceID(4)),
            ]
        )))

        XCTAssertNil(coordinator.getValue(
            path: VmPathRef(viewModelName: "Main", path: "count"),
            screenId: "screen-1",
            instanceId: "main-remote"
        ))
        XCTAssertThrowsError(try bridge.prepare(.value(
            path: VmPathRef(viewModelName: "Item", path: "label"),
            value: "must not resolve",
            instanceID: "item-c"
        )))
        XCTAssertThrowsError(try bridge.prepare(.list(
            operation: .remove,
            path: VmPathRef(viewModelName: "Main", path: "items"),
            payload: ["index": 2],
            instanceID: "main-remote"
        )))
    }

    func testRuntimeTriggerOutputBecomesOneCanonicalTrueDelta() throws {
        let fixture = makeFixture()
        let coordinator = FlowViewModelStateCoordinator(remoteFlow: fixture.remoteFlow)
        let bridge = try FlowRuntimeStateBridge(
            remoteFlow: fixture.remoteFlow,
            screenID: "screen-1",
            bootstrap: fixture.bootstrap,
            coordinator: coordinator
        )

        let emitted = try bridge.reconcile(FlowRuntimeOperationResult(
            renderOutcome: .notRequested,
            isDirty: true,
            isSettled: true,
            orderedOutputs: [
                output(sequence: 30, change: FlowRuntimeStateChange(
                    instanceID: instanceID(1),
                    path: "pulse",
                    value: .enumeration(4),
                    originMutationID: nil
                )),
            ]
        ))

        XCTAssertEqual(emitted.count, 1)
        XCTAssertEqual(emitted[0].value as? Bool, true)
        XCTAssertEqual(emitted[0].source, "runtime")
        XCTAssertTrue(emitted[0].isTrigger)
        XCTAssertEqual(
            coordinator.getValue(
                path: VmPathRef(viewModelName: "Main", path: "pulse"),
                screenId: "screen-1",
                instanceId: "main-remote"
            ) as? Bool,
            true
        )
    }

    func testInvalidSchemaPathAndTypeAreRejectedWithoutLeavingAPendingBatch() throws {
        let fixture = makeFixture()
        let bridge = try FlowRuntimeStateBridge(
            remoteFlow: fixture.remoteFlow,
            screenID: "screen-1",
            bootstrap: fixture.bootstrap,
            coordinator: FlowViewModelStateCoordinator(remoteFlow: fixture.remoteFlow)
        )

        XCTAssertThrowsError(try bridge.prepare(.value(
            path: VmPathRef(viewModelName: "Missing", path: "title"),
            value: "Nope",
            instanceID: "main-remote"
        )))
        XCTAssertThrowsError(try bridge.prepare(.value(
            path: VmPathRef(viewModelName: "Main", path: "missing"),
            value: "Nope",
            instanceID: "main-remote"
        )))
        XCTAssertThrowsError(try bridge.prepare(.value(
            path: VmPathRef(viewModelName: "Main", path: "count"),
            value: true,
            instanceID: "main-remote"
        )))

        let valid = try bridge.prepare(.value(
            path: VmPathRef(viewModelName: "Main", path: "title"),
            value: "Still usable",
            instanceID: "main-remote"
        ))
        XCTAssertEqual(valid.hostMutationID, 4)
    }

    func testPendingBatchMustBeReconciledOrExplicitlyAbandoned() throws {
        let fixture = makeFixture()
        let bridge = try FlowRuntimeStateBridge(
            remoteFlow: fixture.remoteFlow,
            screenID: "screen-1",
            bootstrap: fixture.bootstrap,
            coordinator: FlowViewModelStateCoordinator(remoteFlow: fixture.remoteFlow)
        )
        let input = FlowRuntimeCanonicalStateInput.value(
            path: VmPathRef(viewModelName: "Main", path: "title"),
            value: "Value",
            instanceID: "main-remote"
        )

        _ = try bridge.prepare(input)
        XCTAssertThrowsError(try bridge.prepare(input)) { error in
            XCTAssertEqual(error as? FlowRuntimeStateBridgeError, .operationPending)
        }
        bridge.abandonPendingBatch()
        XCTAssertNoThrow(try bridge.prepare(input))
    }
}

private extension FlowRuntimeStateBridgeTests {
    struct Fixture {
        let remoteFlow: RemoteFlow
        let bootstrap: FlowRuntimeBootstrap
    }

    func instanceID(_ rawValue: UInt64) -> FlowRuntimeInstanceID {
        FlowRuntimeInstanceID(rawValue: rawValue)!
    }

    func value(
        viewModelName: String = "Main",
        instanceID: String? = "main-remote",
        instanceName: String? = nil,
        path: String,
        _ rawValue: Any
    ) -> RemoteFlowViewModelValue {
        RemoteFlowViewModelValue(
            viewModelName: viewModelName,
            instanceId: instanceID,
            instanceName: instanceName,
            path: path,
            value: AnyCodable(rawValue)
        )
    }

    func output(
        sequence: UInt64,
        change: FlowRuntimeStateChange
    ) -> FlowRuntimeOutput {
        FlowRuntimeOutput(
            sequence: sequence,
            cycle: 1,
            phase: .viewModelChanges,
            payload: .viewModelChange(change)
        )
    }

    func arenaByReversingFixtureItems(
        _ arena: FlowRuntimeValueArena
    ) -> FlowRuntimeValueArena {
        var nodes = arena.nodes
        nodes[7] = FlowRuntimeValueNode(value: .list(items: [
            FlowRuntimeValueEdge(key: nil, nodeIndex: 10),
            FlowRuntimeValueEdge(key: nil, nodeIndex: 8),
        ]))
        return FlowRuntimeValueArena(nodes: nodes, roots: arena.roots)
    }

    func makeFixture() -> Fixture {
        let mainProperties: [(String, FlowRuntimeSchemaPropertyKind)] = [
            ("title", .string),
            ("count", .number),
            ("enabled", .bool),
            ("pulse", .trigger),
            ("settings", .object),
            ("items", .list),
            ("safeArea", .object),
            ("nuxieTextInputs", .viewModel),
        ]
        let schemas = [
            FlowRuntimeSchema(
                id: "Main",
                name: "Main",
                properties: mainProperties.map {
                    FlowRuntimeSchemaProperty(
                        schemaID: "Main",
                        propertyID: $0.0,
                        name: $0.0,
                        kind: $0.1
                    )
                }
            ),
            FlowRuntimeSchema(
                id: "Item",
                name: "Item",
                properties: [
                    FlowRuntimeSchemaProperty(
                        schemaID: "Item",
                        propertyID: "label",
                        name: "label",
                        kind: .string
                    ),
                    FlowRuntimeSchemaProperty(
                        schemaID: "Item",
                        propertyID: "rank",
                        name: "rank",
                        kind: .number
                    ),
                ]
            ),
        ]
        let nodes = [
            FlowRuntimeValueNode(value: .viewModel(
                schemaID: "Main",
                instanceID: instanceID(1),
                fields: [
                    FlowRuntimeValueEdge(key: "title", nodeIndex: 1),
                    FlowRuntimeValueEdge(key: "count", nodeIndex: 2),
                    FlowRuntimeValueEdge(key: "enabled", nodeIndex: 3),
                    FlowRuntimeValueEdge(key: "pulse", nodeIndex: 4),
                    FlowRuntimeValueEdge(key: "settings", nodeIndex: 5),
                    FlowRuntimeValueEdge(key: "items", nodeIndex: 7),
                    FlowRuntimeValueEdge(key: "safeArea", nodeIndex: 12),
                    FlowRuntimeValueEdge(key: "nuxieTextInputs", nodeIndex: 14),
                ]
            )),
            FlowRuntimeValueNode(value: .scalar(.string("Before"))),
            FlowRuntimeValueNode(value: .scalar(.number(0))),
            FlowRuntimeValueNode(value: .scalar(.bool(false))),
            FlowRuntimeValueNode(value: .scalar(.enumeration(0))),
            FlowRuntimeValueNode(value: .object(
                schemaID: nil,
                fields: [FlowRuntimeValueEdge(key: "subtitle", nodeIndex: 6)]
            )),
            FlowRuntimeValueNode(value: .scalar(.string("Before subtitle"))),
            FlowRuntimeValueNode(value: .list(items: [
                FlowRuntimeValueEdge(key: nil, nodeIndex: 8),
                FlowRuntimeValueEdge(key: nil, nodeIndex: 10),
            ])),
            FlowRuntimeValueNode(value: .viewModel(
                schemaID: "Item",
                instanceID: instanceID(2),
                fields: [FlowRuntimeValueEdge(key: "label", nodeIndex: 9)]
            )),
            FlowRuntimeValueNode(value: .scalar(.string("A"))),
            FlowRuntimeValueNode(value: .viewModel(
                schemaID: "Item",
                instanceID: instanceID(3),
                fields: [FlowRuntimeValueEdge(key: "label", nodeIndex: 11)]
            )),
            FlowRuntimeValueNode(value: .scalar(.string("B"))),
            FlowRuntimeValueNode(value: .object(
                schemaID: nil,
                fields: [FlowRuntimeValueEdge(key: "top", nodeIndex: 13)]
            )),
            FlowRuntimeValueNode(value: .scalar(.number(0))),
            FlowRuntimeValueNode(value: .viewModel(
                schemaID: nil,
                instanceID: nil,
                fields: [FlowRuntimeValueEdge(key: "value", nodeIndex: 15)]
            )),
            FlowRuntimeValueNode(value: .scalar(.string(""))),
        ]
        let arena = FlowRuntimeValueArena(
            nodes: nodes,
            roots: [
                FlowRuntimeValueRoot(instanceID: instanceID(1), nodeIndex: 0),
                FlowRuntimeValueRoot(instanceID: instanceID(2), nodeIndex: 8),
                FlowRuntimeValueRoot(instanceID: instanceID(3), nodeIndex: 10),
            ]
        )
        let catalog = FlowRuntimeCatalog(
            schemas: schemas,
            templates: [
                FlowRuntimeInstanceTemplate(schemaID: "Main", authoredName: "Default", authoredIndex: 0),
                FlowRuntimeInstanceTemplate(schemaID: "Item", authoredName: nil, authoredIndex: 0),
            ],
            instances: [
                FlowRuntimeInstance(
                    id: instanceID(1),
                    schemaID: "Main",
                    name: "Default",
                    isRoot: true,
                    valueRootIndex: 0
                ),
                FlowRuntimeInstance(
                    id: instanceID(2),
                    schemaID: "Item",
                    name: nil,
                    isRoot: false,
                    valueRootIndex: 8
                ),
                FlowRuntimeInstance(
                    id: instanceID(3),
                    schemaID: "Item",
                    name: nil,
                    isRoot: false,
                    valueRootIndex: 10
                ),
            ]
        )
        let bootstrap = FlowRuntimeBootstrap(
            player: FlowRuntimePlayerMetadata(
                kind: .stateMachine,
                selection: .authoredDefaultStateMachine,
                index: 0,
                artboardName: "Entry",
                playerName: "Main",
                bounds: FlowRuntimeArtboardBounds(minX: 0, minY: 0, maxX: 100, maxY: 100)
            ),
            catalog: catalog,
            values: arena
        )
        let remoteFlow = RemoteFlow(
            id: "flow",
            flowArtifact: FlowArtifact(
                url: "https://example.com/flow.riv",
                manifest: BuildManifest(
                    totalFiles: 1,
                    totalSize: 1,
                    contentHash: "hash",
                    files: [BuildFile(path: "flow.riv", size: 1, contentType: "application/octet-stream")]
                )
            ),
            screens: [
                RemoteFlowScreen(
                    id: "screen-1",
                    defaultViewModelName: "Main",
                    defaultInstanceId: "main-remote"
                ),
            ]
        )
        return Fixture(remoteFlow: remoteFlow, bootstrap: bootstrap)
    }
}
