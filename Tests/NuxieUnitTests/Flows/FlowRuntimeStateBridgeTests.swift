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

    func testSnapshotResolvesListIdentitiesBeforeAmbiguousItemValues() throws {
        let fixture = makeFixture()
        let bridge = try FlowRuntimeStateBridge(
            remoteFlow: fixture.remoteFlow,
            screenID: "screen-1",
            bootstrap: fixture.bootstrap,
            coordinator: FlowViewModelStateCoordinator(remoteFlow: fixture.remoteFlow)
        )

        let batch = try bridge.prepare(.snapshot(FlowViewModelSnapshot(values: [
            value(
                viewModelName: "Item",
                instanceID: "item-a",
                path: "label",
                "Updated A"
            ),
            value(
                viewModelName: "Item",
                instanceID: "item-b",
                path: "label",
                "Updated B"
            ),
            value(path: "items", [
                ["vmInstanceId": "item-a"],
                ["vmInstanceId": "item-b"],
            ]),
        ])))

        XCTAssertTrue(batch.newInstances.isEmpty)
        XCTAssertEqual(batch.mutations, [
            .listClear(instance: .existing(instanceID(1)), path: "items"),
            .listInsert(
                instance: .existing(instanceID(1)),
                path: "items",
                index: 0,
                item: .existing(instanceID(2))
            ),
            .listInsert(
                instance: .existing(instanceID(1)),
                path: "items",
                index: 1,
                item: .existing(instanceID(3))
            ),
            .setValue(
                instance: .existing(instanceID(2)),
                path: "label",
                value: .string("Updated A")
            ),
            .setValue(
                instance: .existing(instanceID(3)),
                path: "label",
                value: .string("Updated B")
            ),
        ])
    }

    func testSnapshotCreatesListItemLocalsBeforeApplyingFlattenedItemValues() throws {
        let fixture = makeFixture()
        let bridge = try FlowRuntimeStateBridge(
            remoteFlow: fixture.remoteFlow,
            screenID: "screen-1",
            bootstrap: bootstrapByRemovingFixtureItems(fixture.bootstrap),
            coordinator: FlowViewModelStateCoordinator(remoteFlow: fixture.remoteFlow)
        )

        let batch = try bridge.prepare(.snapshot(FlowViewModelSnapshot(values: [
            value(
                viewModelName: "Item",
                instanceID: "item-c",
                path: "label",
                "C"
            ),
            value(
                viewModelName: "Item",
                instanceID: "item-d",
                path: "label",
                "D"
            ),
            value(path: "items", [
                ["vmInstanceId": "item-c"],
                ["vmInstanceId": "item-d"],
            ]),
        ])))

        XCTAssertEqual(batch.newInstances, [
            FlowRuntimeNewInstance(localID: 1, schemaName: "Item", authoredInstanceName: nil),
            FlowRuntimeNewInstance(localID: 2, schemaName: "Item", authoredInstanceName: nil),
        ])
        XCTAssertEqual(batch.mutations, [
            .listClear(instance: .existing(instanceID(1)), path: "items"),
            .listInsert(
                instance: .existing(instanceID(1)),
                path: "items",
                index: 0,
                item: .new(localID: 1)
            ),
            .listInsert(
                instance: .existing(instanceID(1)),
                path: "items",
                index: 1,
                item: .new(localID: 2)
            ),
            .setValue(instance: .new(localID: 1), path: "label", value: .string("C")),
            .setValue(instance: .new(localID: 2), path: "label", value: .string("D")),
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

    func testImageWritesResolveAuthoredStringIdentitiesBeforeMutation() throws {
        let fixture = makeFixture()
        let imageProperty = FlowRuntimeSchemaProperty(
            schemaID: "Main",
            propertyID: "heroImage",
            name: "heroImage",
            kind: .image
        )
        let schemas = fixture.bootstrap.catalog.schemas.map { schema in
            guard schema.id == "Main" else { return schema }
            return FlowRuntimeSchema(
                id: schema.id,
                name: schema.name,
                properties: schema.properties + [imageProperty]
            )
        }
        let bootstrap = FlowRuntimeBootstrap(
            player: fixture.bootstrap.player,
            catalog: FlowRuntimeCatalog(
                schemas: schemas,
                templates: fixture.bootstrap.catalog.templates,
                instances: fixture.bootstrap.catalog.instances
            ),
            values: fixture.bootstrap.values
        )
        let resolver = try FlowRuntimeImageIdentityResolver(images: [
            FlowArtifactImageAsset(
                riveAssetId: 7,
                riveUniqueName: "hero-7",
                sourceAssetKey: "hero",
                path: "assets/images/hero.png",
                sha256: String(repeating: "a", count: 64),
                contentType: "image/png",
                width: 1,
                height: 1,
                required: true
            ),
        ])
        let coordinator = FlowViewModelStateCoordinator(remoteFlow: fixture.remoteFlow)
        let bridge = try FlowRuntimeStateBridge(
            remoteFlow: fixture.remoteFlow,
            screenID: "screen-1",
            bootstrap: bootstrap,
            coordinator: coordinator,
            imageIdentityResolver: resolver
        )

        let batch = try bridge.prepare(.value(
            path: VmPathRef(viewModelName: "Main", path: "heroImage"),
            value: "assets/images/hero.png",
            instanceID: "main-remote"
        ))

        XCTAssertEqual(batch.mutations, [
            .setValue(
                instance: .existing(instanceID(1)),
                path: "heroImage",
                value: .image(7)
            ),
        ])
        bridge.abandonPendingBatch()

        let emitted = try bridge.reconcile(FlowRuntimeOperationResult(
            renderOutcome: .notRequested,
            isDirty: true,
            isSettled: true,
            orderedOutputs: [
                output(sequence: 1, change: FlowRuntimeStateChange(
                    instanceID: instanceID(1),
                    path: "heroImage",
                    value: .image(7),
                    originMutationID: nil
                )),
            ]
        ))
        XCTAssertEqual(emitted.first?.value as? String, "hero")
        XCTAssertEqual(
            coordinator.getValue(
                path: VmPathRef(viewModelName: "Main", path: "heroImage"),
                screenId: "screen-1",
                instanceId: "main-remote"
            ) as? String,
            "hero"
        )
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

    func testListMutationReindexesEveryAuthoredListIndexProperty() throws {
        let fixture = makeFixture()
        let bootstrap = bootstrap(
            fixture.bootstrap,
            appending: FlowRuntimeSchemaProperty(
                schemaID: "Item",
                propertyID: "position",
                name: "position",
                kind: .listIndex
            ),
            toSchema: "Item"
        )
        let bridge = try FlowRuntimeStateBridge(
            remoteFlow: fixture.remoteFlow,
            screenID: "screen-1",
            bootstrap: bootstrap,
            coordinator: FlowViewModelStateCoordinator(remoteFlow: fixture.remoteFlow)
        )

        let batch = try bridge.prepare(.list(
            operation: .move,
            path: VmPathRef(viewModelName: "Main", path: "items"),
            payload: ["from": 0, "to": 2],
            instanceID: "main-remote"
        ))

        XCTAssertEqual(batch.mutations, [
            .listMove(
                instance: .existing(instanceID(1)),
                path: "items",
                from: 0,
                to: 1
            ),
            .setValue(
                instance: .existing(instanceID(3)),
                path: "position",
                value: .listIndex(0)
            ),
            .setValue(
                instance: .existing(instanceID(2)),
                path: "position",
                value: .listIndex(1)
            ),
        ])
    }

    func testAuthoredEnumLabelsRoundTripThroughRuntimeIdentities() throws {
        let fixture = makeFixture()
        let bootstrap = bootstrap(
            fixture.bootstrap,
            appending: FlowRuntimeSchemaProperty(
                schemaID: "Main",
                propertyID: "status",
                name: "status",
                kind: .enumeration,
                enumValues: ["idle", "active", "complete"]
            ),
            toSchema: "Main"
        )
        let coordinator = FlowViewModelStateCoordinator(remoteFlow: fixture.remoteFlow)
        let bridge = try FlowRuntimeStateBridge(
            remoteFlow: fixture.remoteFlow,
            screenID: "screen-1",
            bootstrap: bootstrap,
            coordinator: coordinator
        )

        let batch = try bridge.prepare(.value(
            path: VmPathRef(viewModelName: "Main", path: "status"),
            value: "active",
            instanceID: "main-remote"
        ))
        XCTAssertEqual(batch.mutations, [
            .setValue(
                instance: .existing(instanceID(1)),
                path: "status",
                value: .enumeration(1)
            ),
        ])
        bridge.abandonPendingBatch()

        let emitted = try bridge.reconcile(FlowRuntimeOperationResult(
            renderOutcome: .notRequested,
            isDirty: true,
            isSettled: true,
            orderedOutputs: [
                output(sequence: 1, change: FlowRuntimeStateChange(
                    instanceID: instanceID(1),
                    path: "status",
                    value: .enumeration(2),
                    originMutationID: nil
                )),
            ]
        ))

        XCTAssertEqual(emitted.count, 1)
        XCTAssertEqual(emitted[0].value as? String, "complete")
        XCTAssertEqual(
            coordinator.getValue(
                path: VmPathRef(viewModelName: "Main", path: "status"),
                screenId: "screen-1",
                instanceId: "main-remote"
            ) as? String,
            "complete"
        )
    }

    func testAuthoredEnumRejectsUnknownLabelsAndRawNumericIdentities() throws {
        let fixture = makeFixture()
        let bootstrap = bootstrap(
            fixture.bootstrap,
            appending: FlowRuntimeSchemaProperty(
                schemaID: "Main",
                propertyID: "status",
                name: "status",
                kind: .enumeration,
                enumValues: ["idle", "active"]
            ),
            toSchema: "Main"
        )
        let bridge = try FlowRuntimeStateBridge(
            remoteFlow: fixture.remoteFlow,
            screenID: "screen-1",
            bootstrap: bootstrap,
            coordinator: FlowViewModelStateCoordinator(remoteFlow: fixture.remoteFlow)
        )

        for invalidValue: Any in ["missing", 1] {
            XCTAssertThrowsError(try bridge.prepare(.value(
                path: VmPathRef(viewModelName: "Main", path: "status"),
                value: invalidValue,
                instanceID: "main-remote"
            )))
        }

        XCTAssertNoThrow(try bridge.prepare(.value(
            path: VmPathRef(viewModelName: "Main", path: "status"),
            value: "idle",
            instanceID: "main-remote"
        )))
    }

    func testOuterViewModelReplacementCreatesSettlesAndReusesStableIdentity() throws {
        let fixture = makeFixture()
        let bootstrap = bootstrapWithChildViewModel(fixture.bootstrap)
        let bridge = try FlowRuntimeStateBridge(
            remoteFlow: fixture.remoteFlow,
            screenID: "screen-1",
            bootstrap: bootstrap,
            coordinator: FlowViewModelStateCoordinator(remoteFlow: fixture.remoteFlow)
        )

        let first = try bridge.prepare(.value(
            path: VmPathRef(viewModelName: "Main", path: "child"),
            value: [
                "vmInstanceId": "child-a",
                "viewModelId": "Child",
                "values": ["name": "Ada"],
            ],
            instanceID: "main-remote"
        ))
        XCTAssertEqual(first.newInstances, [
            FlowRuntimeNewInstance(
                localID: 1,
                schemaName: "Child",
                authoredInstanceName: nil
            ),
        ])
        XCTAssertEqual(first.mutations, [
            .setValue(
                instance: .new(localID: 1),
                path: "name",
                value: .string("Ada")
            ),
            .setViewModel(
                instance: .existing(instanceID(1)),
                path: "child",
                value: .new(localID: 1)
            ),
        ])

        _ = try bridge.reconcile(FlowRuntimeOperationResult(
            renderOutcome: .notRequested,
            isDirty: true,
            isSettled: true,
            createdInstances: [
                FlowRuntimeCreatedInstance(localID: 1, instanceID: instanceID(4)),
            ]
        ))

        let second = try bridge.prepare(.value(
            path: VmPathRef(viewModelName: "Main", path: "child"),
            value: [
                "vmInstanceId": "child-a",
                "viewModelId": "Child",
                "values": ["name": "Grace"],
            ],
            instanceID: "main-remote"
        ))
        XCTAssertTrue(second.newInstances.isEmpty)
        XCTAssertEqual(second.mutations, [
            .setValue(
                instance: .existing(instanceID(4)),
                path: "name",
                value: .string("Grace")
            ),
            .setViewModel(
                instance: .existing(instanceID(1)),
                path: "child",
                value: .existing(instanceID(4))
            ),
        ])
    }

    func testOuterViewModelReplacementEchoMatchesTheSettledChildIdentity() throws {
        let fixture = makeFixture()
        let bridge = try FlowRuntimeStateBridge(
            remoteFlow: fixture.remoteFlow,
            screenID: "screen-1",
            bootstrap: bootstrapWithChildViewModel(fixture.bootstrap),
            coordinator: FlowViewModelStateCoordinator(remoteFlow: fixture.remoteFlow)
        )

        _ = try bridge.prepare(.value(
            path: VmPathRef(viewModelName: "Main", path: "child"),
            value: [
                "vmInstanceId": "child-a",
                "viewModelId": "Child",
                "values": ["name": "Ada"],
            ],
            instanceID: "main-remote"
        ))

        let emitted = try bridge.reconcile(FlowRuntimeOperationResult(
            renderOutcome: .notRequested,
            isDirty: true,
            isSettled: true,
            orderedOutputs: [
                output(sequence: 1, change: FlowRuntimeStateChange(
                    instanceID: instanceID(1),
                    path: "child",
                    value: nil,
                    viewModelReference: FlowRuntimeViewModelReference(
                        schemaID: "Child",
                        instanceID: instanceID(4)
                    ),
                    originMutationID: 1
                )),
            ],
            createdInstances: [
                FlowRuntimeCreatedInstance(localID: 1, instanceID: instanceID(4)),
            ]
        ))

        XCTAssertTrue(emitted.isEmpty)
    }

    func testOuterViewModelReplacementEchoDoesNotSuppressAnotherChildIdentity() throws {
        let fixture = makeFixture()
        let bridge = try FlowRuntimeStateBridge(
            remoteFlow: fixture.remoteFlow,
            screenID: "screen-1",
            bootstrap: bootstrapWithChildViewModel(fixture.bootstrap),
            coordinator: FlowViewModelStateCoordinator(remoteFlow: fixture.remoteFlow)
        )

        _ = try bridge.prepare(.value(
            path: VmPathRef(viewModelName: "Main", path: "child"),
            value: ["vmInstanceId": "child-a", "viewModelId": "Child"],
            instanceID: "main-remote"
        ))

        XCTAssertThrowsError(try bridge.reconcile(FlowRuntimeOperationResult(
            renderOutcome: .notRequested,
            isDirty: true,
            isSettled: true,
            orderedOutputs: [
                output(sequence: 1, change: FlowRuntimeStateChange(
                    instanceID: instanceID(1),
                    path: "child",
                    value: nil,
                    viewModelReference: FlowRuntimeViewModelReference(
                        schemaID: "Child",
                        instanceID: instanceID(5)
                    ),
                    originMutationID: 1
                )),
            ],
            createdInstances: [
                FlowRuntimeCreatedInstance(localID: 1, instanceID: instanceID(4)),
            ]
        )))
    }

    func testOuterViewModelReplacementEchoDoesNotSuppressAnotherSchema() throws {
        let fixture = makeFixture()
        let bridge = try FlowRuntimeStateBridge(
            remoteFlow: fixture.remoteFlow,
            screenID: "screen-1",
            bootstrap: bootstrapWithChildViewModel(fixture.bootstrap),
            coordinator: FlowViewModelStateCoordinator(remoteFlow: fixture.remoteFlow)
        )

        _ = try bridge.prepare(.value(
            path: VmPathRef(viewModelName: "Main", path: "child"),
            value: ["vmInstanceId": "child-a", "viewModelId": "Child"],
            instanceID: "main-remote"
        ))

        XCTAssertThrowsError(try bridge.reconcile(FlowRuntimeOperationResult(
            renderOutcome: .notRequested,
            isDirty: true,
            isSettled: true,
            orderedOutputs: [
                output(sequence: 1, change: FlowRuntimeStateChange(
                    instanceID: instanceID(1),
                    path: "child",
                    value: nil,
                    viewModelReference: FlowRuntimeViewModelReference(
                        schemaID: "Item",
                        instanceID: instanceID(4)
                    ),
                    originMutationID: 1
                )),
            ],
            createdInstances: [
                FlowRuntimeCreatedInstance(localID: 1, instanceID: instanceID(4)),
            ]
        )))
    }

    func testRuntimeOriginOuterViewModelReplacementUsesStableCanonicalIdentity() throws {
        let fixture = makeFixture()
        let coordinator = FlowViewModelStateCoordinator(remoteFlow: fixture.remoteFlow)
        let bridge = try FlowRuntimeStateBridge(
            remoteFlow: fixture.remoteFlow,
            screenID: "screen-1",
            bootstrap: bootstrapWithChildViewModel(fixture.bootstrap),
            coordinator: coordinator
        )

        _ = try bridge.prepare(.value(
            path: VmPathRef(viewModelName: "Main", path: "child"),
            value: [
                "vmInstanceId": "child-a",
                "viewModelId": "Child",
                "values": ["name": "Ada"],
            ],
            instanceID: "main-remote"
        ))
        _ = try bridge.reconcile(FlowRuntimeOperationResult(
            renderOutcome: .notRequested,
            isDirty: true,
            isSettled: true,
            createdInstances: [
                FlowRuntimeCreatedInstance(localID: 1, instanceID: instanceID(4)),
            ]
        ))

        let result = FlowRuntimeOperationResult(
            renderOutcome: .notRequested,
            isDirty: true,
            isSettled: true,
            orderedOutputs: [
                output(sequence: 2, change: FlowRuntimeStateChange(
                    instanceID: instanceID(1),
                    path: "child",
                    value: nil,
                    viewModelReference: FlowRuntimeViewModelReference(
                        schemaID: "Child",
                        instanceID: instanceID(4)
                    ),
                    originMutationID: nil
                )),
            ],
            values: arenaBySettingChild(
                fixture.bootstrap.values,
                instanceID: instanceID(4),
                name: "Ada"
            )
        )
        let first = try bridge.reconcile(result)
        let second = try bridge.reconcile(result)

        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(second.count, 1, "same-valued structural replacements remain observable")
        let envelope = try XCTUnwrap(first[0].value as? [String: Any])
        XCTAssertEqual(envelope["vmInstanceId"] as? String, "child-a")
        XCTAssertEqual(envelope["viewModelId"] as? String, "Child")
        XCTAssertEqual(
            coordinator.getValue(
                path: VmPathRef(viewModelName: "Main", path: "child"),
                screenId: "screen-1",
                instanceId: "main-remote"
            ) as? [String: String],
            ["vmInstanceId": "child-a", "viewModelId": "Child"]
        )
    }

    func testRuntimeOriginOuterReplacementPrecedesOneChildIdentityChange() throws {
        let fixture = makeFixture()
        let coordinator = FlowViewModelStateCoordinator(remoteFlow: fixture.remoteFlow)
        let bridge = try FlowRuntimeStateBridge(
            remoteFlow: fixture.remoteFlow,
            screenID: "screen-1",
            bootstrap: bootstrapWithChildViewModel(fixture.bootstrap),
            coordinator: coordinator
        )

        _ = try bridge.prepare(.value(
            path: VmPathRef(viewModelName: "Main", path: "child"),
            value: ["vmInstanceId": "child-a", "viewModelId": "Child"],
            instanceID: "main-remote"
        ))
        _ = try bridge.reconcile(FlowRuntimeOperationResult(
            renderOutcome: .notRequested,
            isDirty: true,
            isSettled: true,
            createdInstances: [
                FlowRuntimeCreatedInstance(localID: 1, instanceID: instanceID(4)),
            ]
        ))

        let emitted = try bridge.reconcile(FlowRuntimeOperationResult(
            renderOutcome: .notRequested,
            isDirty: true,
            isSettled: true,
            orderedOutputs: [
                output(sequence: 1, change: FlowRuntimeStateChange(
                    instanceID: instanceID(1),
                    path: "child",
                    value: nil,
                    viewModelReference: FlowRuntimeViewModelReference(
                        schemaID: "Child",
                        instanceID: instanceID(4)
                    ),
                    originMutationID: nil
                )),
                output(sequence: 2, change: FlowRuntimeStateChange(
                    instanceID: instanceID(4),
                    path: "name",
                    value: .string("Grace"),
                    originMutationID: nil
                )),
            ],
            values: arenaBySettingChild(
                fixture.bootstrap.values,
                instanceID: instanceID(4),
                name: "Grace"
            )
        ))

        XCTAssertEqual(emitted.count, 2)
        XCTAssertEqual(emitted[0].path, VmPathRef(viewModelName: "Main", path: "child"))
        XCTAssertEqual(emitted[0].instanceId, "main-remote")
        XCTAssertEqual(emitted[1].path, VmPathRef(viewModelName: "Child", path: "name"))
        XCTAssertEqual(emitted[1].instanceId, "child-a")
        XCTAssertEqual(emitted[1].value as? String, "Grace")
    }

    func testRuntimeOriginOuterViewModelReplacementFailsClosedOnInconsistentIdentity() throws {
        let fixture = makeFixture()
        let coordinator = FlowViewModelStateCoordinator(remoteFlow: fixture.remoteFlow)
        let bridge = try FlowRuntimeStateBridge(
            remoteFlow: fixture.remoteFlow,
            screenID: "screen-1",
            bootstrap: bootstrapWithChildViewModel(fixture.bootstrap),
            coordinator: coordinator
        )

        _ = try bridge.prepare(.value(
            path: VmPathRef(viewModelName: "Main", path: "child"),
            value: ["vmInstanceId": "child-a", "viewModelId": "Child"],
            instanceID: "main-remote"
        ))
        _ = try bridge.reconcile(FlowRuntimeOperationResult(
            renderOutcome: .notRequested,
            isDirty: true,
            isSettled: true,
            createdInstances: [
                FlowRuntimeCreatedInstance(localID: 1, instanceID: instanceID(4)),
            ]
        ))

        let change = FlowRuntimeStateChange(
            instanceID: instanceID(1),
            path: "child",
            value: nil,
            viewModelReference: FlowRuntimeViewModelReference(
                schemaID: "Child",
                instanceID: instanceID(4)
            ),
            originMutationID: nil
        )
        XCTAssertThrowsError(try bridge.reconcile(FlowRuntimeOperationResult(
            renderOutcome: .notRequested,
            isDirty: true,
            isSettled: true,
            orderedOutputs: [output(sequence: 1, change: change)]
        )))
        XCTAssertNil(coordinator.getValue(
            path: VmPathRef(viewModelName: "Main", path: "child"),
            screenId: "screen-1",
            instanceId: "main-remote"
        ))

        XCTAssertThrowsError(try bridge.reconcile(FlowRuntimeOperationResult(
            renderOutcome: .notRequested,
            isDirty: true,
            isSettled: true,
            orderedOutputs: [output(sequence: 2, change: change)],
            values: arenaBySettingChild(
                fixture.bootstrap.values,
                instanceID: instanceID(5),
                name: "Ada"
            )
        )))
        XCTAssertNil(coordinator.getValue(
            path: VmPathRef(viewModelName: "Main", path: "child"),
            screenId: "screen-1",
            instanceId: "main-remote"
        ))
    }

    func testOuterViewModelReplacementRejectsMissingOrWrongStableIdentity() throws {
        let fixture = makeFixture()
        let bootstrap = bootstrapWithChildViewModel(fixture.bootstrap)
        let bridge = try FlowRuntimeStateBridge(
            remoteFlow: fixture.remoteFlow,
            screenID: "screen-1",
            bootstrap: bootstrap,
            coordinator: FlowViewModelStateCoordinator(remoteFlow: fixture.remoteFlow)
        )

        for invalidValue: [String: Any] in [
            ["viewModelId": "Child", "values": ["name": "Ada"]],
            [
                "vmInstanceId": "child-a",
                "viewModelId": "Item",
                "values": ["label": "wrong schema"],
            ],
        ] {
            XCTAssertThrowsError(try bridge.prepare(.value(
                path: VmPathRef(viewModelName: "Main", path: "child"),
                value: invalidValue,
                instanceID: "main-remote"
            )))
        }
    }

    func testSnapshotResolvesOuterViewModelReferenceBeforeFlattenedChildValues() throws {
        let fixture = makeFixture()
        let bridge = try FlowRuntimeStateBridge(
            remoteFlow: fixture.remoteFlow,
            screenID: "screen-1",
            bootstrap: bootstrapWithChildViewModel(fixture.bootstrap),
            coordinator: FlowViewModelStateCoordinator(remoteFlow: fixture.remoteFlow)
        )

        let batch = try bridge.prepare(.snapshot(FlowViewModelSnapshot(values: [
            value(
                viewModelName: "Child",
                instanceID: "child-a",
                path: "name",
                "Ada"
            ),
            value(path: "child/vmInstanceId", "child-a"),
        ])))

        XCTAssertEqual(batch.newInstances, [
            FlowRuntimeNewInstance(
                localID: 1,
                schemaName: "Child",
                authoredInstanceName: nil
            ),
        ])
        XCTAssertEqual(batch.mutations, [
            .setViewModel(
                instance: .existing(instanceID(1)),
                path: "child",
                value: .new(localID: 1)
            ),
            .setValue(
                instance: .new(localID: 1),
                path: "name",
                value: .string("Ada")
            ),
        ])
    }

    func testSnapshotRejectsConflictingFlattenedOuterViewModelEnvelope() throws {
        let fixture = makeFixture()
        let bridge = try FlowRuntimeStateBridge(
            remoteFlow: fixture.remoteFlow,
            screenID: "screen-1",
            bootstrap: bootstrapWithChildViewModel(fixture.bootstrap),
            coordinator: FlowViewModelStateCoordinator(remoteFlow: fixture.remoteFlow)
        )

        XCTAssertThrowsError(try bridge.prepare(.snapshot(FlowViewModelSnapshot(values: [
            value(path: "child/vmInstanceId", "child-a"),
            value(path: "child/instanceId", "child-b"),
        ]))))

        XCTAssertNoThrow(try bridge.prepare(.value(
            path: VmPathRef(viewModelName: "Main", path: "title"),
            value: "Still usable",
            instanceID: "main-remote"
        )))
    }

    func testSnapshotReassemblesFullFlattenedOuterViewModelEnvelope() throws {
        let fixture = makeFixture()
        let bridge = try FlowRuntimeStateBridge(
            remoteFlow: fixture.remoteFlow,
            screenID: "screen-1",
            bootstrap: bootstrapWithChildViewModel(fixture.bootstrap),
            coordinator: FlowViewModelStateCoordinator(remoteFlow: fixture.remoteFlow)
        )

        let batch = try bridge.prepare(.snapshot(FlowViewModelSnapshot(values: [
            value(path: "child/viewModelId", "Child"),
            value(path: "child/instanceId", "child-a"),
            value(path: "child/values/name", "Ada"),
        ])))

        XCTAssertEqual(batch.newInstances, [
            FlowRuntimeNewInstance(
                localID: 1,
                schemaName: "Child",
                authoredInstanceName: nil
            ),
        ])
        XCTAssertEqual(batch.mutations, [
            .setValue(
                instance: .new(localID: 1),
                path: "name",
                value: .string("Ada")
            ),
            .setViewModel(
                instance: .existing(instanceID(1)),
                path: "child",
                value: .new(localID: 1)
            ),
        ])
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

    func testAbandonedPreparationDoesNotCommitPreferredExistingIdentity() throws {
        let fixture = makeFixture()
        let bridge = try FlowRuntimeStateBridge(
            remoteFlow: fixture.remoteFlow,
            screenID: "screen-1",
            bootstrap: fixture.bootstrap,
            coordinator: FlowViewModelStateCoordinator(remoteFlow: fixture.remoteFlow)
        )
        let rows: [[String: Any]] = [
            ["vmInstanceId": "item-a", "viewModelId": "Item", "values": ["label": "A"]],
            ["vmInstanceId": "item-b", "viewModelId": "Item", "values": ["label": "B"]],
        ]

        _ = try bridge.prepare(.snapshot(FlowViewModelSnapshot(values: [
            value(path: "items", rows),
        ])))
        bridge.abandonPendingBatch()

        XCTAssertThrowsError(try bridge.prepare(.value(
            path: VmPathRef(viewModelName: "Item", path: "label"),
            value: "must remain ambiguous",
            instanceID: "item-a"
        ))) { error in
            guard case .invalidInput(let message) = error as? FlowRuntimeStateBridgeError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("does not resolve to one live runtime instance"))
        }
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
        XCTAssertThrowsError(try bridge.prepare(.value(
            path: VmPathRef(viewModelName: "Main", path: "title"),
            value: "Must not alias the root",
            instanceID: "another-main"
        )))

        let valid = try bridge.prepare(.value(
            path: VmPathRef(viewModelName: "Main", path: "title"),
            value: "Still usable",
            instanceID: "main-remote"
        ))
        XCTAssertEqual(valid.hostMutationID, 5)
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

    func arenaBySettingChild(
        _ arena: FlowRuntimeValueArena,
        instanceID childInstanceID: FlowRuntimeInstanceID,
        name: String
    ) -> FlowRuntimeValueArena {
        var nodes = arena.nodes
        let childIndex = nodes.count
        let nameIndex = childIndex + 1
        nodes.append(FlowRuntimeValueNode(value: .viewModel(
            schemaID: "Child",
            instanceID: childInstanceID,
            fields: [FlowRuntimeValueEdge(key: "name", nodeIndex: nameIndex)]
        )))
        nodes.append(FlowRuntimeValueNode(value: .scalar(.string(name))))
        guard case .viewModel(let schemaID, let instanceID, let fields) = nodes[0].value else {
            return arena
        }
        nodes[0] = FlowRuntimeValueNode(value: .viewModel(
            schemaID: schemaID,
            instanceID: instanceID,
            fields: fields + [FlowRuntimeValueEdge(key: "child", nodeIndex: childIndex)]
        ))
        return FlowRuntimeValueArena(
            nodes: nodes,
            roots: arena.roots + [
                FlowRuntimeValueRoot(instanceID: childInstanceID, nodeIndex: childIndex),
            ]
        )
    }

    func bootstrapByRemovingFixtureItems(
        _ bootstrap: FlowRuntimeBootstrap
    ) -> FlowRuntimeBootstrap {
        var nodes = bootstrap.values.nodes
        nodes[7] = FlowRuntimeValueNode(value: .list(items: []))
        return FlowRuntimeBootstrap(
            player: bootstrap.player,
            catalog: FlowRuntimeCatalog(
                schemas: bootstrap.catalog.schemas,
                templates: bootstrap.catalog.templates,
                instances: bootstrap.catalog.instances.filter(\.isRoot)
            ),
            values: FlowRuntimeValueArena(
                nodes: nodes,
                roots: bootstrap.values.roots.filter { $0.instanceID == instanceID(1) }
            )
        )
    }

    func bootstrap(
        _ bootstrap: FlowRuntimeBootstrap,
        appending property: FlowRuntimeSchemaProperty,
        toSchema schemaID: String
    ) -> FlowRuntimeBootstrap {
        FlowRuntimeBootstrap(
            player: bootstrap.player,
            catalog: FlowRuntimeCatalog(
                schemas: bootstrap.catalog.schemas.map { schema in
                    guard schema.id == schemaID else { return schema }
                    return FlowRuntimeSchema(
                        id: schema.id,
                        name: schema.name,
                        properties: schema.properties + [property]
                    )
                },
                templates: bootstrap.catalog.templates,
                instances: bootstrap.catalog.instances
            ),
            values: bootstrap.values
        )
    }

    func bootstrapWithChildViewModel(
        _ bootstrap: FlowRuntimeBootstrap
    ) -> FlowRuntimeBootstrap {
        let childProperty = FlowRuntimeSchemaProperty(
            schemaID: "Main",
            propertyID: "child",
            name: "child",
            kind: .viewModel,
            referencedSchemaID: "Child"
        )
        let schemas = bootstrap.catalog.schemas.map { schema in
            guard schema.id == "Main" else { return schema }
            return FlowRuntimeSchema(
                id: schema.id,
                name: schema.name,
                properties: schema.properties + [childProperty]
            )
        } + [
            FlowRuntimeSchema(
                id: "Child",
                name: "Child",
                properties: [
                    FlowRuntimeSchemaProperty(
                        schemaID: "Child",
                        propertyID: "name",
                        name: "name",
                        kind: .string
                    ),
                ]
            ),
        ]
        return FlowRuntimeBootstrap(
            player: bootstrap.player,
            catalog: FlowRuntimeCatalog(
                schemas: schemas,
                templates: bootstrap.catalog.templates + [
                    FlowRuntimeInstanceTemplate(
                        schemaID: "Child",
                        authoredName: nil,
                        authoredIndex: 0
                    ),
                ],
                instances: bootstrap.catalog.instances
            ),
            values: bootstrap.values
        )
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
