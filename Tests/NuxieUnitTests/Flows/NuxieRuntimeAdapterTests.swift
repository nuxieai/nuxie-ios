#if NUXIE_RUNTIME_ADAPTER_TESTS && !canImport(NuxieRuntime)
#error("test-runtime-adapter requires the packaged NuxieRuntime Clang module")
#endif

#if canImport(NuxieRuntime)
import CryptoKit
import Foundation
import Metal
import Nimble
import NuxieRuntime
import Quick
import UIKit
import XCTest
@testable import Nuxie

final class NuxieRuntimeAdapterTests: AsyncSpec {
    override class func spec() {
        describe("NuxieRuntimeAdapter") {
            it("validates the packaged ABI and maps every declared fixed-width value") {
                expect { try NuxieRuntimeABI.validate() }.notTo(throwError())
                expect {
                    try NuxieRuntimeABI.validate(
                        minimumMinor: NuxieRuntimeABI.sessionMinimumMinor
                    )
                }.notTo(throwError())

                expect(nuxieRuntimeStatus(NUX_STATUS_OK)).to(equal(.ok))
                expect(nuxieRuntimeStatus(NUX_STATUS_NULL_ARGUMENT)).to(equal(.nullArgument))
                expect(nuxieRuntimeStatus(NUX_STATUS_IMPORT_ERROR)).to(equal(.importError))
                expect(nuxieRuntimeStatus(NUX_STATUS_NOT_FOUND)).to(equal(.notFound))
                expect(nuxieRuntimeStatus(NUX_STATUS_RUNTIME_ERROR)).to(equal(.runtimeError))
                expect(nuxieRuntimeStatus(NUX_STATUS_INVALID_ARGUMENT)).to(equal(.invalidArgument))
                expect(nuxieRuntimeStatus(NUX_STATUS_ABI_MISMATCH)).to(equal(.abiMismatch))
                expect(nuxieRuntimeStatus(NUX_STATUS_SURFACE_ERROR)).to(equal(.surfaceError))
                expect(nuxieRuntimeStatus(UInt32.max)).to(equal(.unknown(UInt32.max)))

                let dispositions: [(UInt32, FlowRuntimeSurfaceDisposition)] = [
                    (NUX_SURFACE_DISPOSITION_NONE, .none),
                    (NUX_SURFACE_DISPOSITION_PRESENTED, .presented),
                    (NUX_SURFACE_DISPOSITION_SKIPPED_ZERO_SIZE, .skippedZeroSize),
                    (NUX_SURFACE_DISPOSITION_SKIPPED_TIMEOUT, .skippedTimeout),
                    (NUX_SURFACE_DISPOSITION_SKIPPED_OCCLUDED, .skippedOccluded),
                    (NUX_SURFACE_DISPOSITION_RECONFIGURED, .reconfigured),
                    (NUX_SURFACE_DISPOSITION_RECREATED, .recreated),
                    (NUX_SURFACE_DISPOSITION_DEVICE_LOST, .deviceLost),
                    (NUX_SURFACE_DISPOSITION_OUT_OF_MEMORY, .outOfMemory),
                    (NUX_SURFACE_DISPOSITION_FATAL, .fatal),
                ]
                for (rawValue, expected) in dispositions {
                    expect(nuxieRuntimeSurfaceDisposition(rawValue)).to(equal(expected))
                }
                expect(nuxieRuntimeSurfaceDisposition(UInt32.max))
                    .to(equal(.unknown(UInt32.max)))

                let widerThanFloat = Double(Float.greatestFiniteMagnitude) * 2
                expect(nuxieFlowResultNumberIsValid(widerThanFloat)).to(beTrue())
                expect(nuxieFlowResultNumberIsValid(.infinity)).to(beFalse())

                let missingRun = NuxieRuntimeAdapterError.callFailed(
                    status: .notFound,
                    diagnostic: FlowRuntimeDiagnostic(
                        severity: .fatal,
                        code: "nux_runtime.not_found",
                        message: "root TextValueRun was not found"
                    )
                )
                let invalidWrite = NuxieRuntimeAdapterError.callFailed(
                    status: .invalidArgument,
                    diagnostic: FlowRuntimeDiagnostic(
                        severity: .fatal,
                        code: "nux_runtime.invalid_argument",
                        message: "text-run name must not be empty"
                    )
                )
                let resourceFailure = NuxieRuntimeAdapterError.callFailed(
                    status: .runtimeError,
                    diagnostic: FlowRuntimeDiagnostic(
                        severity: .fatal,
                        code: "nux_runtime.script_resource_exceeded",
                        message: "script resource limit exceeded"
                    )
                )
                let panicFailure = NuxieRuntimeAdapterError.callFailed(
                    status: .runtimeError,
                    diagnostic: FlowRuntimeDiagnostic(
                        severity: .fatal,
                        code: "nux_runtime.runtime_error",
                        message: "runtime panicked; the affected flow session is terminated"
                    )
                )
                let genericRuntimeFailure = NuxieRuntimeAdapterError.callFailed(
                    status: .runtimeError,
                    diagnostic: FlowRuntimeDiagnostic(
                        severity: .fatal,
                        code: "nux_runtime.runtime_error",
                        message: "runtime operation failed"
                    )
                )
                expect(missingRun.invalidatesSession).to(beFalse())
                expect(invalidWrite.invalidatesSession).to(beFalse())
                expect(resourceFailure.invalidatesSession).to(beTrue())
                expect(panicFailure.invalidatesSession).to(beTrue())
                expect(genericRuntimeFailure.invalidatesSession).to(beTrue())
                for status: NuxieRuntimeStatus in [
                    .ok,
                    .nullArgument,
                    .importError,
                    .abiMismatch,
                    .surfaceError,
                    .unknown(UInt32.max),
                ] {
                    let failure = NuxieRuntimeAdapterError.callFailed(
                        status: status,
                        diagnostic: FlowRuntimeDiagnostic(
                            severity: .fatal,
                            code: "nux_runtime.unexpected_status",
                            message: "unexpected ABI status"
                        )
                    )
                    expect(failure.invalidatesSession).to(beTrue())
                }
            }

            it("keeps only outbound Swift request validation operation-local") {
                let sharedValidation = FlowRuntimeSessionValueError.invalidValue(
                    "text-run name must not be empty"
                )
                expect(flowRuntimeOperationFailureInvalidatesSession(sharedValidation)).to(
                    beTrue()
                )

                let outbound = NuxieRuntimeAdapterError.invalidOperation(sharedValidation)
                expect(outbound.invalidatesSession).to(beFalse())
                expect(flowRuntimeOperationFailureInvalidatesSession(outbound)).to(beFalse())
            }

            it("fails closed on malformed catalog relationships and output phases") {
                let property = FlowRuntimeSchemaProperty(
                    schemaID: "Main",
                    propertyID: "title",
                    name: "title",
                    kind: .string
                )
                let schema = FlowRuntimeSchema(
                    id: "Main",
                    name: "Main",
                    properties: [property]
                )
                let root = FlowRuntimeInstance(
                    id: FlowRuntimeInstanceID(rawValue: 1)!,
                    schemaID: "Main",
                    name: nil,
                    isRoot: true,
                    valueRootIndex: nil
                )
                let validCatalog = FlowRuntimeCatalog(
                    schemas: [schema],
                    templates: [FlowRuntimeInstanceTemplate(
                        schemaID: "Main",
                        authoredName: nil,
                        authoredIndex: 0
                    )],
                    instances: [root]
                )

                expect {
                    try validateNuxieFlowCatalogShape(validCatalog, isPresent: true)
                }.notTo(throwError())
                expect {
                    try validateNuxieFlowCatalogShape(
                        FlowRuntimeCatalog(schemas: [], templates: [], instances: []),
                        isPresent: false
                    )
                }.notTo(throwError())
                expect {
                    try validateNuxieFlowCatalogShape(validCatalog, isPresent: false)
                }.to(throwError())
                expect {
                    try validateNuxieFlowCatalogShape(
                        FlowRuntimeCatalog(
                            schemas: [schema, schema],
                            templates: [],
                            instances: []
                        ),
                        isPresent: true
                    )
                }.to(throwError())
                expect {
                    try validateNuxieFlowCatalogShape(
                        FlowRuntimeCatalog(
                            schemas: [FlowRuntimeSchema(
                                id: "Main",
                                name: "Main",
                                properties: [property, property]
                            )],
                            templates: [],
                            instances: []
                        ),
                        isPresent: true
                    )
                }.to(throwError())
                expect {
                    try validateNuxieFlowCatalogShape(
                        FlowRuntimeCatalog(
                            schemas: [FlowRuntimeSchema(
                                id: "Main",
                                name: "Main",
                                properties: [FlowRuntimeSchemaProperty(
                                    schemaID: "Missing",
                                    propertyID: "title",
                                    name: "title",
                                    kind: .string
                                )]
                            )],
                            templates: [],
                            instances: []
                        ),
                        isPresent: true
                    )
                }.to(throwError())
                expect {
                    try validateNuxieFlowCatalogShape(
                        FlowRuntimeCatalog(
                            schemas: [schema],
                            templates: [FlowRuntimeInstanceTemplate(
                                schemaID: "Missing",
                                authoredName: nil,
                                authoredIndex: 0
                            )],
                            instances: []
                        ),
                        isPresent: true
                    )
                }.to(throwError())
                expect {
                    try validateNuxieFlowCatalogShape(
                        FlowRuntimeCatalog(
                            schemas: [schema],
                            templates: [],
                            instances: [FlowRuntimeInstance(
                                id: FlowRuntimeInstanceID(rawValue: 2)!,
                                schemaID: "Missing",
                                name: nil,
                                isRoot: false,
                                valueRootIndex: nil
                            )]
                        ),
                        isPresent: true
                    )
                }.to(throwError())
                expect {
                    try validateNuxieFlowCatalogShape(
                        FlowRuntimeCatalog(
                            schemas: [schema],
                            templates: [],
                            instances: [
                                root,
                                FlowRuntimeInstance(
                                    id: FlowRuntimeInstanceID(rawValue: 2)!,
                                    schemaID: "Main",
                                    name: nil,
                                    isRoot: true,
                                    valueRootIndex: nil
                                ),
                            ]
                        ),
                        isPresent: true
                    )
                }.to(throwError())

                let change = FlowRuntimeStateChange(
                    instanceID: nil,
                    path: "title",
                    value: .string("hello"),
                    originMutationID: nil
                )
                let phaseCases: [(FlowRuntimeOutputPayload, FlowRuntimeOutputPhase)] = [
                    (.reportedEvent(
                        name: nil,
                        eventType: 0,
                        delay: 0,
                        properties: [],
                        openURL: FlowRuntimeOpenURL(
                            url: "https://example.com",
                            target: "_blank"
                        )
                    ),
                     .reportedEvents),
                    (.runtimeAdvanced(delta: 0), .runtimeAdvance),
                    (.stateChange(change), .viewModelChanges),
                    (.viewModelChange(change), .viewModelChanges),
                    (.hostCommand(name: "open", payload: .object(.empty)), .hostWork),
                    (.renderRequest, .render),
                ]
                for (index, (payload, expectedPhase)) in phaseCases.enumerated() {
                    expect {
                        try validateNuxieFlowOutputPhase(
                            expectedPhase,
                            payload: payload,
                            outputIndex: index
                        )
                    }.notTo(throwError())
                    let wrongPhase: FlowRuntimeOutputPhase = expectedPhase == .render
                        ? .hostWork
                        : .render
                    expect {
                        try validateNuxieFlowOutputPhase(
                            wrongPhase,
                            payload: payload,
                            outputIndex: index
                        )
                    }.to(throwError())
                }

                let hostArena = FlowRuntimeValueArena(
                    nodes: [
                        FlowRuntimeValueNode(
                            value: .object(
                                schemaID: nil,
                                fields: [FlowRuntimeValueEdge(key: "value", nodeIndex: 1)]
                            )
                        ),
                        FlowRuntimeValueNode(value: .scalar(.number(42))),
                    ],
                    roots: []
                )
                expect {
                    try decodeNuxieFlowHostCommand(
                        name: "checkout",
                        payloadRoot: 0,
                        opaquePayload: Data(),
                        arena: hostArena,
                        outputIndex: 4
                    )
                }.to(equal(.hostCommand(
                    name: "checkout",
                    payload: .object(FlowRuntimeHostObject(fields: [
                        FlowRuntimeHostObjectField(name: "value", value: .number(42)),
                    ]))
                )))
                expect {
                    try decodeNuxieFlowHostCommand(
                        name: "checkout",
                        payloadRoot: nil,
                        opaquePayload: Data(),
                        arena: hostArena,
                        outputIndex: 4
                    )
                }.to(throwError())
                expect {
                    try decodeNuxieFlowHostCommand(
                        name: "checkout",
                        payloadRoot: 0,
                        opaquePayload: Data([0xff]),
                        arena: hostArena,
                        outputIndex: 4
                    )
                }.to(throwError())
                expect {
                    try decodeNuxieFlowHostCommand(
                        name: "checkout",
                        payloadRoot: 1,
                        opaquePayload: Data(),
                        arena: hostArena,
                        outputIndex: 4
                    )
                }.to(throwError())

                for target in ["", "_blank", "_parent", "_self", "_top"] {
                    expect {
                        try validateNuxieFlowOpenURLTarget(target)
                    }.notTo(throwError())
                }
                expect {
                    try validateNuxieFlowOpenURLTarget("named-frame")
                }.to(throwError())
            }

            it("validates authored enum labels and nested schema references") {
                let child = FlowRuntimeSchema(
                    id: "Child",
                    name: "Child",
                    properties: []
                )
                let validProperties = [
                    FlowRuntimeSchemaProperty(
                        schemaID: "Main",
                        propertyID: "state",
                        name: "state",
                        kind: .enumeration,
                        enumValues: ["idle", "active"]
                    ),
                    FlowRuntimeSchemaProperty(
                        schemaID: "Main",
                        propertyID: "child",
                        name: "child",
                        kind: .viewModel,
                        referencedSchemaID: "Child"
                    ),
                ]
                func catalog(
                    _ properties: [FlowRuntimeSchemaProperty],
                    includeChild: Bool = true
                ) -> FlowRuntimeCatalog {
                    FlowRuntimeCatalog(
                        schemas: [
                            FlowRuntimeSchema(
                                id: "Main",
                                name: "Main",
                                properties: properties
                            ),
                        ] + (includeChild ? [child] : []),
                        templates: [],
                        instances: []
                    )
                }

                expect {
                    try validateNuxieFlowCatalogShape(
                        catalog(validProperties),
                        isPresent: true
                    )
                }.notTo(throwError())
                expect {
                    try validateNuxieFlowCatalogShape(
                        catalog([
                            FlowRuntimeSchemaProperty(
                                schemaID: "Main",
                                propertyID: "state",
                                name: "state",
                                kind: .enumeration,
                                enumValues: ["same", "same"]
                            ),
                        ]),
                        isPresent: true
                    )
                }.to(throwError())
                expect {
                    try validateNuxieFlowCatalogShape(
                        catalog([
                            FlowRuntimeSchemaProperty(
                                schemaID: "Main",
                                propertyID: "title",
                                name: "title",
                                kind: .string,
                                enumValues: ["invalid"]
                            ),
                        ]),
                        isPresent: true
                    )
                }.to(throwError())
                expect {
                    try validateNuxieFlowCatalogShape(
                        catalog([
                            FlowRuntimeSchemaProperty(
                                schemaID: "Main",
                                propertyID: "child",
                                name: "child",
                                kind: .viewModel
                            ),
                        ]),
                        isPresent: true
                    )
                }.to(throwError())
                expect {
                    try validateNuxieFlowCatalogShape(
                        catalog(validProperties, includeChild: false),
                        isPresent: true
                    )
                }.to(throwError())
                expect {
                    try validateNuxieFlowCatalogShape(
                        catalog([
                            FlowRuntimeSchemaProperty(
                                schemaID: "Main",
                                propertyID: "title",
                                name: "title",
                                kind: .string,
                                referencedSchemaID: "Child"
                            ),
                        ]),
                        isPresent: true
                    )
                }.to(throwError())
            }

            it("distinguishes absent values from output-only arena nodes") {
                let outputOnlyArena = FlowRuntimeValueArena(
                    nodes: [FlowRuntimeValueNode(value: .scalar(.string("event payload")))],
                    roots: []
                )
                expect {
                    try validateNuxieFlowValuesPresence(
                        outputOnlyArena,
                        isPresent: false
                    )
                }.notTo(throwError())

                let instanceID = FlowRuntimeInstanceID(rawValue: 1)!
                let valueSnapshotArena = FlowRuntimeValueArena(
                    nodes: [FlowRuntimeValueNode(value: .viewModel(
                        schemaID: "Main",
                        instanceID: instanceID,
                        fields: []
                    ))],
                    roots: [FlowRuntimeValueRoot(instanceID: instanceID, nodeIndex: 0)]
                )
                expect {
                    try validateNuxieFlowValuesPresence(
                        valueSnapshotArena,
                        isPresent: false
                    )
                }.to(throwError { error in
                    guard case NuxieRuntimeAdapterError.invalidNativeResult(let message) = error
                    else {
                        fail("unexpected error: \(String(reflecting: error))")
                        return
                    }
                    expect(message).to(contain("value roots"))
                    expect(message).to(contain("without marking them present"))
                })
            }

            it("encodes canonical ABI 1.4+ state storage with stable nested pointers") {
                let existing = FlowRuntimeInstanceID(rawValue: 42)!
                let batch = FlowRuntimeStateBatch(
                    hostMutationID: 0,
                    newInstances: [
                        FlowRuntimeNewInstance(
                            localID: 7,
                            schemaName: "Card",
                            authoredInstanceName: nil
                        ),
                    ],
                    mutations: [
                        .setInputBool(name: "enabled", value: true),
                        .setInputNumber(name: "progress", value: 0.5),
                        .fireInputTrigger(name: "submit"),
                        .setValue(
                            instance: .existing(existing),
                            path: "title",
                            value: .string("hello")
                        ),
                        .fireTrigger(instance: .existing(existing), path: "refresh"),
                        .listInsert(
                            instance: .existing(existing),
                            path: "cards",
                            index: 2,
                            item: .new(localID: 7)
                        ),
                        .listRemove(instance: .existing(existing), path: "cards", index: 1),
                        .listSwap(
                            instance: .existing(existing),
                            path: "cards",
                            first: 0,
                            second: 1
                        ),
                        .listMove(
                            instance: .existing(existing),
                            path: "cards",
                            from: 1,
                            to: 0
                        ),
                        .listSet(
                            instance: .existing(existing),
                            path: "cards",
                            index: 0,
                            item: .new(localID: 7)
                        ),
                        .listClear(instance: .existing(existing), path: "cards"),
                    ]
                )
                let storage = try NuxieRuntimeSessionOperationStorage(
                    operation: .stateBatch(batch),
                    hasDrawable: false
                )

                try storage.withOperation(
                    appleDrawable: nil,
                    completionContext: nil,
                    completionCallback: nil
                ) { operation in
                    let operation = operation.pointee
                    expect(operation.required_abi_major).to(equal(UInt16(1)))
                    expect(operation.minimum_abi_minor).to(
                        equal(NuxieRuntimeABI.sessionMinimumMinor)
                    )
                    expect(operation.kind).to(
                        equal(UInt32(NUX_FLOW_SESSION_OPERATION_KIND_STATE_BATCH))
                    )
                    expect(operation.pointer_batch).to(beNil())
                    expect(operation.advance).to(beNil())
                    expect(operation.query_batch).to(beNil())

                    let nativeBatch = try XCTUnwrap(operation.state_batch?.pointee)
                    expect(nativeBatch.has_host_mutation_id).to(equal(UInt32(1)))
                    expect(nativeBatch.host_mutation_id).to(equal(UInt64(0)))
                    expect(nativeBatch.new_instance_count).to(equal(UInt64(1)))
                    expect(nativeBatch.mutation_count).to(equal(UInt64(11)))
                    expect(nativeBatch.value_arena?.pointee.node_count).to(equal(UInt64(3)))

                    let mutations = try XCTUnwrap(nativeBatch.mutations)
                    expect(mutations[0].kind).to(
                        equal(UInt32(NUX_FLOW_STATE_MUTATION_KIND_SET_INPUT_BOOL))
                    )
                    expect(mutations[3].kind).to(
                        equal(UInt32(NUX_FLOW_STATE_MUTATION_KIND_SET))
                    )
                    expect(mutations[5].item.kind).to(
                        equal(UInt32(NUX_FLOW_INSTANCE_REFERENCE_KIND_NEW))
                    )
                    expect(mutations[5].item.local_id).to(equal(UInt32(7)))
                    let path = mutations[5].path
                    let pathBytes = UnsafeBufferPointer(
                        start: path.data,
                        count: Int(path.len)
                    )
                    expect(String(decoding: pathBytes, as: UTF8.self)).to(equal("cards"))

                    let nodes = try XCTUnwrap(nativeBatch.value_arena?.pointee.nodes)
                    expect(nodes[0].kind).to(equal(UInt32(NUX_FLOW_VALUE_KIND_BOOL)))
                    expect(nodes[0].bool_value).to(equal(UInt32(1)))
                    expect(nodes[1].kind).to(equal(UInt32(NUX_FLOW_VALUE_KIND_NUMBER)))
                    expect(nodes[1].number_value).to(equal(0.5))
                    expect(nodes[2].kind).to(equal(UInt32(NUX_FLOW_VALUE_KIND_STRING)))
                    let string = nodes[2].string_value
                    let stringBytes = UnsafeBufferPointer(
                        start: string.data,
                        count: Int(string.len)
                    )
                    expect(String(decoding: stringBytes, as: UTF8.self)).to(equal("hello"))
                }
            }

            it("encodes ABI 1.5 text-run batches with byte-exact UTF-8 identity") {
                let composedName = "Caf\u{00e9}"
                let decomposedName = "Cafe\u{0301}"
                let mutations = [
                    FlowRuntimeTextRunMutation(name: composedName, text: "Hello \u{1f44b}"),
                    FlowRuntimeTextRunMutation(name: decomposedName, text: ""),
                ]
                let storage = try NuxieRuntimeSessionOperationStorage(
                    operation: .textRunBatch(FlowRuntimeTextRunBatch(mutations: mutations)),
                    hasDrawable: false
                )

                try storage.withOperation(
                    appleDrawable: nil,
                    completionContext: nil,
                    completionCallback: nil
                ) { operation in
                    let operation = operation.pointee
                    expect(operation.required_abi_major).to(equal(UInt16(1)))
                    expect(operation.minimum_abi_minor).to(
                        equal(NuxieRuntimeABI.sessionMinimumMinor)
                    )
                    expect(operation.kind).to(
                        equal(UInt32(NUX_FLOW_SESSION_OPERATION_KIND_TEXT_RUN_BATCH))
                    )
                    expect(operation.state_batch).to(beNil())
                    expect(operation.pointer_batch).to(beNil())
                    expect(operation.advance).to(beNil())
                    expect(operation.query_batch).to(beNil())

                    let batch = try XCTUnwrap(operation.text_run_batch?.pointee)
                    expect(batch.mutation_count).to(equal(UInt64(2)))
                    let nativeMutations = try XCTUnwrap(batch.mutations)
                    let firstName = UnsafeBufferPointer(
                        start: nativeMutations[0].name.data,
                        count: Int(nativeMutations[0].name.len)
                    )
                    let firstText = UnsafeBufferPointer(
                        start: nativeMutations[0].text.data,
                        count: Int(nativeMutations[0].text.len)
                    )
                    let secondName = UnsafeBufferPointer(
                        start: nativeMutations[1].name.data,
                        count: Int(nativeMutations[1].name.len)
                    )
                    expect(Array(firstName)).to(equal(Array(composedName.utf8)))
                    expect(Array(firstText)).to(equal(Array("Hello \u{1f44b}".utf8)))
                    expect(Array(secondName)).to(equal(Array(decomposedName.utf8)))
                    expect(nativeMutations[1].text.len).to(equal(UInt64(0)))
                    expect(MemoryLayout<NuxFlowTextRunMutation>.size).to(equal(40))
                    expect(MemoryLayout<NuxFlowTextRunMutation>.offset(of: \.struct_size))
                        .to(equal(0))
                    expect(MemoryLayout<NuxFlowTextRunMutation>.offset(of: \.name))
                        .to(equal(8))
                    expect(MemoryLayout<NuxFlowTextRunMutation>.offset(of: \.text))
                        .to(equal(24))
                    expect(MemoryLayout<NuxFlowTextRunBatch>.size).to(equal(24))
                    expect(MemoryLayout<NuxFlowTextRunBatch>.offset(of: \.struct_size))
                        .to(equal(0))
                    expect(MemoryLayout<NuxFlowTextRunBatch>.offset(of: \.mutations))
                        .to(equal(8))
                    expect(MemoryLayout<NuxFlowTextRunBatch>.offset(of: \.mutation_count))
                        .to(equal(16))
                    expect(MemoryLayout<NuxFlowSessionOperation>.size).to(equal(56))
                    expect(MemoryLayout<NuxFlowSessionOperation>.offset(of: \.text_run_batch))
                        .to(equal(48))
                }

                let emptyStorage = try NuxieRuntimeSessionOperationStorage(
                    operation: .textRunBatch(FlowRuntimeTextRunBatch(mutations: [])),
                    hasDrawable: false
                )
                try emptyStorage.withOperation(
                    appleDrawable: nil,
                    completionContext: nil,
                    completionCallback: nil
                ) { operation in
                    let batch = try XCTUnwrap(operation.pointee.text_run_batch?.pointee)
                    expect(batch.mutations).to(beNil())
                    expect(batch.mutation_count).to(equal(0))
                }
            }

            it("encodes pointer, query, and exact f32 advance operation shapes") {
                let pointerStorage = try NuxieRuntimeSessionOperationStorage(
                    operation: .pointerBatch([
                        FlowRuntimePointerEvent(
                            kind: .down,
                            pointerID: 9,
                            x: 1.25,
                            y: -2.5,
                            timestampSeconds: 12.5
                        ),
                        FlowRuntimePointerEvent(
                            kind: .up,
                            pointerID: 9,
                            x: 2,
                            y: 3,
                            timestampSeconds: 13.25
                        ),
                    ]),
                    hasDrawable: false
                )
                try pointerStorage.withOperation(
                    appleDrawable: nil,
                    completionContext: nil,
                    completionCallback: nil
                ) { operation in
                    expect(operation.pointee.kind).to(
                        equal(UInt32(NUX_FLOW_SESSION_OPERATION_KIND_POINTER_BATCH))
                    )
                    let batch = try XCTUnwrap(operation.pointee.pointer_batch?.pointee)
                    expect(batch.event_count).to(equal(UInt64(2)))
                    let events = try XCTUnwrap(batch.events)
                    expect(events[0].kind).to(
                        equal(UInt32(NUX_FLOW_POINTER_EVENT_KIND_DOWN))
                    )
                    expect(events[0].pointer_id).to(equal(Int32(9)))
                    expect(events[0].x).to(equal(Float(1.25)))
                    expect(events[0].y).to(equal(Float(-2.5)))
                    expect(events[0].timestamp_seconds).to(equal(Float(12.5)))
                    expect(MemoryLayout<NuxFlowPointerEvent>.size).to(equal(24))
                }

                let queryStorage = try NuxieRuntimeSessionOperationStorage(
                    operation: .query([.bootstrap, .values, .catalog, .playerInputs]),
                    hasDrawable: false
                )
                try queryStorage.withOperation(
                    appleDrawable: nil,
                    completionContext: nil,
                    completionCallback: nil
                ) { operation in
                    let batch = try XCTUnwrap(operation.pointee.query_batch?.pointee)
                    expect(batch.query_count).to(equal(UInt64(4)))
                    let queries = try XCTUnwrap(batch.queries)
                    expect(queries[0].kind).to(equal(UInt32(NUX_FLOW_QUERY_KIND_BOOTSTRAP)))
                    expect(queries[1].kind).to(equal(UInt32(NUX_FLOW_QUERY_KIND_VALUES)))
                    expect(queries[2].kind).to(equal(UInt32(NUX_FLOW_QUERY_KIND_CATALOG)))
                    expect(queries[3].kind).to(equal(UInt32(NUX_FLOW_QUERY_KIND_PLAYER_INPUTS)))
                }

                let advanceStorage = try NuxieRuntimeSessionOperationStorage(
                    operation: .advanceAndRender(
                        FlowRuntimeFrameTime(timestamp: 123.5, delta: 0.125)
                    ),
                    hasDrawable: false
                )
                expect(advanceStorage.renderRequested).to(beTrue())
                try advanceStorage.withOperation(
                    appleDrawable: nil,
                    completionContext: nil,
                    completionCallback: nil
                ) { operation in
                    expect(operation.pointee.kind).to(
                        equal(UInt32(NUX_FLOW_SESSION_OPERATION_KIND_ADVANCE))
                    )
                    let advance = try XCTUnwrap(operation.pointee.advance?.pointee)
                    expect(advance.timestamp_seconds).to(equal(123.5))
                    expect(advance.delta_seconds).to(equal(Float(0.125)))
                    expect(advance.render).to(equal(UInt32(1)))
                }
            }

            it("rejects malformed ABI 1.5 requests before crossing into Rust") {
                expect {
                    try NuxieRuntimeSessionOperationStorage(
                        operation: .textRunBatch(FlowRuntimeTextRunBatch(mutations: [
                            FlowRuntimeTextRunMutation(name: "", text: "value"),
                        ])),
                        hasDrawable: false
                    )
                }.to(throwError())
                expect {
                    try NuxieRuntimeSessionOperationStorage(
                        operation: .textRunBatch(FlowRuntimeTextRunBatch(
                            mutations: (0...4_096).map { _ in
                                FlowRuntimeTextRunMutation(name: "n", text: "")
                            }
                        )),
                        hasDrawable: false
                    )
                }.to(throwError())
                let oneMiB = String(repeating: "t", count: 1_048_576)
                expect {
                    try NuxieRuntimeSessionOperationStorage(
                        operation: .textRunBatch(FlowRuntimeTextRunBatch(
                            mutations: (0..<5).map { index in
                                FlowRuntimeTextRunMutation(
                                    name: "Body\(index)",
                                    text: oneMiB
                                )
                            }
                        )),
                        hasDrawable: false
                    )
                }.to(throwError())
                expect {
                    try NuxieRuntimeSessionOperationStorage(
                        operation: .textRunBatch(FlowRuntimeTextRunBatch(mutations: [
                            FlowRuntimeTextRunMutation(
                                name: String(repeating: "n", count: 4_097),
                                text: "value"
                            ),
                        ])),
                        hasDrawable: false
                    )
                }.to(throwError())
                expect {
                    try NuxieRuntimeSessionOperationStorage(
                        operation: .textRunBatch(FlowRuntimeTextRunBatch(mutations: [
                            FlowRuntimeTextRunMutation(
                                name: "Body",
                                text: String(repeating: "t", count: 1_048_577)
                            ),
                        ])),
                        hasDrawable: false
                    )
                }.to(throwError())
                expect {
                    try NuxieRuntimeSessionOperationStorage(
                        operation: .textRunBatch(FlowRuntimeTextRunBatch(mutations: [
                            FlowRuntimeTextRunMutation(name: "Body", text: "value"),
                        ])),
                        hasDrawable: true
                    )
                }.to(throwError())
                expect {
                    try NuxieRuntimeSessionOperationStorage(
                        operation: .pointerBatch([]),
                        hasDrawable: false
                    )
                }.to(throwError())
                expect {
                    try NuxieRuntimeSessionOperationStorage(
                        operation: .pointerBatch([
                            FlowRuntimePointerEvent(kind: .move, pointerID: 0, x: 0, y: 0),
                        ]),
                        hasDrawable: false
                    )
                }.to(throwError())
                for timestamp in [
                    -1.0,
                    Double.infinity,
                    Double.nan,
                    Double(Float.greatestFiniteMagnitude) * 2,
                ] {
                    expect {
                        try NuxieRuntimeSessionOperationStorage(
                            operation: .pointerBatch([
                                FlowRuntimePointerEvent(
                                    kind: .move,
                                    pointerID: 1,
                                    x: 0,
                                    y: 0,
                                    timestampSeconds: timestamp
                                ),
                            ]),
                            hasDrawable: false
                        )
                    }.to(throwError())
                }
                expect {
                    try NuxieRuntimeSessionOperationStorage(
                        operation: .pointerBatch(
                            (1...33).map {
                                FlowRuntimePointerEvent(
                                    kind: .move,
                                    pointerID: Int32($0),
                                    x: 0,
                                    y: 0
                                )
                            }
                        ),
                        hasDrawable: false
                    )
                }.to(throwError())
                expect {
                    try NuxieRuntimeSessionOperationStorage(
                        operation: .query([]),
                        hasDrawable: false
                    )
                }.to(throwError())
                expect {
                    try NuxieRuntimeSessionOperationStorage(
                        operation: .stateBatch(FlowRuntimeStateBatch(mutations: [])),
                        hasDrawable: false
                    )
                }.to(throwError())
                expect {
                    try NuxieRuntimeSessionOperationStorage(
                        operation: .stateBatch(
                            FlowRuntimeStateBatch(
                                newInstances: (0...4_096).map {
                                    FlowRuntimeNewInstance(
                                        localID: UInt32($0),
                                        schemaName: "Card",
                                        authoredInstanceName: nil
                                    )
                                },
                                mutations: []
                            )
                        ),
                        hasDrawable: false
                    )
                }.to(throwError())
                expect {
                    try NuxieRuntimeSessionOperationStorage(
                        operation: .stateBatch(
                            FlowRuntimeStateBatch(
                                mutations: [
                                    .setValue(
                                        instance: .existing(FlowRuntimeInstanceID(rawValue: 1)!),
                                        path: "nested//value",
                                        value: .bool(true)
                                    ),
                                ]
                            )
                        ),
                        hasDrawable: false
                    )
                }.to(throwError())
                expect {
                    try NuxieRuntimeSessionOperationStorage(
                        operation: .stateBatch(
                            FlowRuntimeStateBatch(
                                mutations: [
                                    .setValue(
                                        instance: .existing(
                                            FlowRuntimeInstanceID(rawValue: 1)!
                                        ),
                                        path: "value",
                                        value: .number(
                                            Double(Float.greatestFiniteMagnitude) * 2
                                        )
                                    ),
                                ]
                            )
                        ),
                        hasDrawable: false
                    )
                }.to(throwError())
                expect {
                    try NuxieRuntimeSessionOperationStorage(
                        operation: .stateBatch(
                            FlowRuntimeStateBatch(
                                mutations: [
                                    .setValue(
                                        instance: .existing(FlowRuntimeInstanceID(rawValue: 1)!),
                                        path: "value",
                                        value: .trigger(1)
                                    ),
                                ]
                            )
                        ),
                        hasDrawable: false
                    )
                }.to(throwError())
                expect {
                    try NuxieRuntimeSessionOperationStorage(
                        operation: .advance(
                            FlowRuntimeFrameTime(timestamp: -.infinity, delta: 0)
                        ),
                        hasDrawable: false
                    )
                }.to(
                    throwError(NuxieRuntimeAdapterError.invalidFrameTimestamp(-.infinity))
                )
                expect {
                    try NuxieRuntimeSessionOperationStorage(
                        operation: .query([.values]),
                        hasDrawable: true
                    )
                }.to(throwError())
            }

            it("fails closed when a native call omits its owned result") {
                var missingResult: OpaquePointer?
                expect {
                    try copyNuxieRuntimeResult(
                        callStatus: NUX_STATUS_OK,
                        result: &missingResult,
                        renderRequested: false
                    )
                }.to(throwError(NuxieRuntimeAdapterError.missingOperationResult))

                expect {
                    try copyNuxieRuntimeResult(
                        callStatus: NUX_STATUS_INVALID_ARGUMENT,
                        result: &missingResult,
                        renderRequested: false
                    )
                }.to(throwError { error in
                    guard case NuxieRuntimeAdapterError.callFailed(let status, let diagnostic) = error else {
                        fail("unexpected error: \(error)")
                        return
                    }
                    expect(status).to(equal(.invalidArgument))
                    expect(diagnostic.code).to(equal("nux_runtime.invalid_argument"))
                    expect(diagnostic.message).to(contain("no diagnostic result"))
                })

                var missingSessionResult: OpaquePointer?
                expect {
                    try copyNuxieFlowSessionResult(
                        callStatus: NUX_STATUS_OK,
                        result: &missingSessionResult,
                        renderRequested: false
                    )
                }.to(throwError(NuxieRuntimeAdapterError.missingOperationResult))

                expect {
                    try copyNuxieFlowSessionResult(
                        callStatus: NUX_STATUS_RUNTIME_ERROR,
                        result: &missingSessionResult,
                        renderRequested: false
                    )
                }.to(throwError { error in
                    guard case NuxieRuntimeAdapterError.callFailed(
                        let status,
                        let diagnostic
                    ) = error else {
                        fail("unexpected error: \(String(reflecting: error))")
                        return
                    }
                    expect(status).to(equal(.runtimeError))
                    expect(diagnostic.code).to(equal("nux_runtime.runtime_error"))
                    expect(diagnostic.message).to(contain("no session diagnostic result"))
                })
            }

            it("copies the native diagnostic for an invalid artifact") { @MainActor in
                let adapter = NuxieRuntimeAdapter()
                do {
                    _ = try await adapter.makeContext(
                        for: try Self.unsignedRequest(
                            artifactBytes: Data([0x00, 0x01, 0x02])
                        )
                    )
                    fail("expected import to fail")
                } catch NuxieRuntimeAdapterError.callFailed(let status, let diagnostic) {
                    expect(status).to(equal(.importError))
                    expect(diagnostic.code).to(equal("artifact.riv.import_failed"))
                    expect(diagnostic.message).notTo(beEmpty())
                } catch {
                    fail("unexpected error: \(error)")
                }
            }

            it("copies native not-found diagnostics and rejects invalid frame deltas") { @MainActor in
                let fixtureBytes = try Self.fixtureBytes()
                let adapter = NuxieRuntimeAdapter()
                let contextAttachment = try await adapter.makeContext(
                    for: try Self.unsignedRequest(artifactBytes: fixtureBytes)
                )
                expect(contextAttachment.importResult.scriptAuthorization).to(equal(.visualOnly))
                expect(contextAttachment.importResult.diagnostics.map(\.code)).to(
                    contain("artifact.authentication.missing")
                )
                let context = contextAttachment.driver
                defer { context.dispose() }

                do {
                    _ = try await context.makeSession(
                        descriptor: FlowRenderSessionDescriptor(artboardName: "")
                    )
                    fail("expected the empty selector to fail Swift preflight")
                } catch FlowRuntimeSessionValueError.invalidValue(let message) {
                    expect(message).to(contain("artboard name"))
                } catch {
                    fail("unexpected selector error: \(String(reflecting: error))")
                }

                do {
                    _ = try await context.makeSession(
                        descriptor: FlowRenderSessionDescriptor(artboardName: "Missing")
                    )
                    fail("expected missing artboard selection to fail")
                } catch NuxieRuntimeAdapterError.callFailed(let status, let diagnostic) {
                    expect(status).to(equal(.notFound))
                    expect(diagnostic.code).to(equal("nux_runtime.not_found"))
                    expect(diagnostic.message).to(contain("Missing"))
                } catch {
                    fail("unexpected error: \(error)")
                }

                let sessionAttachment: FlowRuntimeSessionDriverAttachment
                do {
                    sessionAttachment = try await context.makeSession(
                        descriptor: FlowRenderSessionDescriptor(artboardName: "Two")
                    )
                } catch {
                    fail("valid configured session failed: \(String(reflecting: error))")
                    return
                }
                let creationBootstrap = try XCTUnwrap(
                    sessionAttachment.creationResult.bootstrap
                )
                expect(creationBootstrap.player.artboardName).to(equal("Two"))
                expect(creationBootstrap.player.kind).to(equal(.staticArtboard))
                let session = sessionAttachment.driver
                defer { session.dispose() }

                let queryResult = try await session.perform(
                    .query([.bootstrap, .values, .catalog, .playerInputs]),
                    drawable: nil
                )
                expect(queryResult.bootstrap?.player.artboardName).to(equal("Two"))
                expect(queryResult.values).notTo(beNil())
                expect(queryResult.catalog).notTo(beNil())
                expect(queryResult.playerInputs).notTo(beNil())

                do {
                    _ = try await session.perform(
                        .advance(FlowRuntimeFrameTime(timestamp: 1, delta: -.infinity)),
                        drawable: nil
                    )
                    fail("expected the invalid frame delta to fail")
                } catch NuxieRuntimeAdapterError.invalidFrameDelta(let delta) {
                    expect(delta).to(equal(-.infinity))
                } catch {
                    fail("unexpected error: \(error)")
                }
            }

            it("keeps Swift operation-storage validation local to the rejected request") { @MainActor in
                let adapter = NuxieRuntimeAdapter()
                let contextAttachment = try await adapter.makeContext(
                    for: try Self.unsignedRequest(artifactBytes: Self.fixtureBytes())
                )
                let context = contextAttachment.driver
                defer { context.dispose() }
                let sessionAttachment = try await context.makeSession(
                    descriptor: FlowRenderSessionDescriptor(artboardName: "Two")
                )
                let session = sessionAttachment.driver
                defer { session.dispose() }

                do {
                    _ = try await session.perform(
                        .textRunBatch(FlowRuntimeTextRunBatch(mutations: [
                            FlowRuntimeTextRunMutation(name: "", text: "value"),
                        ])),
                        drawable: nil
                    )
                    fail("expected outbound operation validation to fail")
                } catch NuxieRuntimeAdapterError.invalidOperation(let validation) {
                    expect(validation).to(equal(.invalidValue(
                        "Runtime text-run name must not be empty"
                    )))
                    expect(flowRuntimeOperationFailureInvalidatesSession(
                        NuxieRuntimeAdapterError.invalidOperation(validation)
                    )).to(beFalse())
                } catch {
                    fail("unexpected outbound validation error: \(String(reflecting: error))")
                }

                let recovered = try await session.perform(
                    .query([.bootstrap]),
                    drawable: nil
                )
                expect(recovered.bootstrap?.player.artboardName).to(equal("Two"))
            }

            it("authenticates the exact manifest with the Nuxie-selected key") { @MainActor in
                let fixtureBytes = try Self.fixtureBytes()
                let adapter = NuxieRuntimeAdapter()
                let attachment = try await adapter.makeContext(
                    for: try Self.authenticatedRequest(artifactBytes: fixtureBytes)
                )
                defer { attachment.driver.dispose() }

                expect(attachment.importResult.scriptAuthorization).to(
                    equal(.authorized(keyId: "runtime-adapter-test-key"))
                )
                expect(attachment.importResult.diagnostics).to(beEmpty())
            }

            it("preserves an empty signature envelope as malformed rather than absent") { @MainActor in
                let base = try Self.unsignedRequest(artifactBytes: Self.fixtureBytes())
                guard let evidence = base.authorizationEvidence else {
                    fail("expected unsigned evidence")
                    return
                }
                let request = FlowRuntimeImportRequest(
                    artifactBytes: base.artifactBytes,
                    expectedIdentity: base.expectedIdentity,
                    authorizationEvidence: FlowRuntimeAuthorizationEvidence(
                        signedContentBytes: evidence.signedContentBytes,
                        signatureEnvelopeBytes: Data(),
                        selectedKey: nil
                    )
                )

                let attachment = try await NuxieRuntimeAdapter().makeContext(for: request)
                defer { attachment.driver.dispose() }
                expect(attachment.importResult.scriptAuthorization).to(equal(.visualOnly))
                expect(attachment.importResult.diagnostics.map(\.code)).to(
                    contain("artifact.authentication.malformed")
                )
                expect(attachment.importResult.diagnostics.map(\.code)).notTo(
                    contain("artifact.authentication.missing")
                )
            }

            it("downgrades an oversized signature envelope to visual-only") { @MainActor in
                let base = try Self.unsignedRequest(artifactBytes: Self.fixtureBytes())
                guard let evidence = base.authorizationEvidence else {
                    fail("expected unsigned evidence")
                    return
                }
                let request = FlowRuntimeImportRequest(
                    artifactBytes: base.artifactBytes,
                    expectedIdentity: base.expectedIdentity,
                    authorizationEvidence: FlowRuntimeAuthorizationEvidence(
                        signedContentBytes: evidence.signedContentBytes,
                        signatureEnvelopeBytes: Data(
                            repeating: 0,
                            count: FlowRuntimeImportLimits.signatureEnvelopeBytes + 1
                        ),
                        selectedKey: nil
                    )
                )

                let attachment = try await NuxieRuntimeAdapter().makeContext(for: request)
                defer { attachment.driver.dispose() }
                expect(attachment.importResult.scriptAuthorization).to(equal(.visualOnly))
                expect(attachment.importResult.diagnostics.map(\.code)).to(
                    contain("artifact.authentication.malformed")
                )
            }

            it("downgrades unusable selected key material to visual-only") { @MainActor in
                let base = try Self.authenticatedRequest(artifactBytes: Self.fixtureBytes())
                guard let evidence = base.authorizationEvidence else {
                    fail("expected authenticated evidence")
                    return
                }
                let request = FlowRuntimeImportRequest(
                    artifactBytes: base.artifactBytes,
                    expectedIdentity: base.expectedIdentity,
                    authorizationEvidence: FlowRuntimeAuthorizationEvidence(
                        signedContentBytes: evidence.signedContentBytes,
                        signatureEnvelopeBytes: evidence.signatureEnvelopeBytes,
                        selectedKey: FlowRuntimeAuthorizationKey(
                            keyId: "runtime-adapter-test-key",
                            ed25519PublicKeyBytes: Data(repeating: 7, count: 31)
                        )
                    )
                )

                let attachment = try await NuxieRuntimeAdapter().makeContext(for: request)
                defer { attachment.driver.dispose() }
                expect(attachment.importResult.scriptAuthorization).to(equal(.visualOnly))
                expect(attachment.importResult.diagnostics.map(\.code)).to(
                    contain("artifact.authentication.missing_key")
                )
            }

            it("rejects replay when acquisition flow or build identity differs") { @MainActor in
                let fixtureBytes = try Self.fixtureBytes()
                let original = try Self.unsignedRequest(artifactBytes: fixtureBytes)
                for (identity, expectedCode) in [
                    (
                        FlowRuntimeArtifactIdentity(
                            flowId: "different-flow",
                            buildId: "runtime-adapter-build"
                        ),
                        "artifact.identity.flow_mismatch"
                    ),
                    (
                        FlowRuntimeArtifactIdentity(
                            flowId: "runtime-adapter-flow",
                            buildId: "different-build"
                        ),
                        "artifact.identity.build_mismatch"
                    ),
                ] {
                    let replay = FlowRuntimeImportRequest(
                        artifactBytes: original.artifactBytes,
                        expectedIdentity: identity,
                        authorizationEvidence: original.authorizationEvidence
                    )
                    do {
                        _ = try await NuxieRuntimeAdapter().makeContext(for: replay)
                        fail("expected replay identity mismatch")
                    } catch NuxieRuntimeAdapterError.callFailed(let status, let diagnostic) {
                        expect(status).to(equal(.importError))
                        expect(diagnostic.code).to(equal(expectedCode))
                    } catch {
                        fail("unexpected error: \(error)")
                    }
                }
            }

            it("imports a real image and font fixture through the flat C asset seam") { @MainActor in
                let fixture = try Self.publishedFontFixture()
                let request = try FlowRuntimeArtifactAdapter.makeImportRequest(
                    artifactBytes: fixture.artifactBytes,
                    manifest: fixture.manifest,
                    expectedIdentity: FlowRuntimeArtifactIdentity(
                        flowId: fixture.manifest.flowId,
                        buildId: fixture.manifest.buildId
                    ),
                    authorizationEvidence: FlowRuntimeAuthorizationEvidence(
                        signedContentBytes: fixture.manifestBytes,
                        signatureEnvelopeBytes: nil,
                        selectedKey: nil
                    ),
                    assetURLsByRiveUniqueName: fixture.assetURLs
                )

                let attachment = try await NuxieRuntimeAdapter().makeContext(for: request)
                defer { attachment.driver.dispose() }
                expect(attachment.importResult.scriptAuthorization).to(equal(.visualOnly))
                expect(attachment.importResult.diagnostics.map(\.severity)).notTo(contain(.fatal))

                let sessionAttachment = try await attachment.driver.makeSession(
                    descriptor: FlowRenderSessionDescriptor(
                        artboardName: fixture.manifest.entry.artboardName
                    )
                )
                let session = sessionAttachment.driver
                defer { session.dispose() }
                let firstAdvance = try await session.perform(
                    .advance(FlowRuntimeFrameTime(timestamp: 0, delta: 0)),
                    drawable: nil
                )
                expect(firstAdvance.diagnostics.map(\.severity)).notTo(contain(.fatal))
            }

            it("updates an authored text run through ABI 1.5 and keeps local misses recoverable") { @MainActor in
                let fixture = try Self.publishedFontFixture(
                    fixtureName: "text-input-motion"
                )
                let request = try FlowRuntimeArtifactAdapter.makeImportRequest(
                    artifactBytes: fixture.artifactBytes,
                    manifest: fixture.manifest,
                    expectedIdentity: FlowRuntimeArtifactIdentity(
                        flowId: fixture.manifest.flowId,
                        buildId: fixture.manifest.buildId
                    ),
                    authorizationEvidence: FlowRuntimeAuthorizationEvidence(
                        signedContentBytes: fixture.manifestBytes,
                        signatureEnvelopeBytes: nil,
                        selectedKey: nil
                    ),
                    assetURLsByRiveUniqueName: fixture.assetURLs
                )

                let contextAttachment = try await NuxieRuntimeAdapter().makeContext(for: request)
                let context = contextAttachment.driver
                defer { context.dispose() }
                let sessionAttachment = try await context.makeSession(
                    descriptor: FlowRenderSessionDescriptor(
                        artboardName: fixture.manifest.entry.artboardName
                    )
                )
                let session = sessionAttachment.driver
                defer { session.dispose() }

                let bootstrap = try XCTUnwrap(sessionAttachment.creationResult.bootstrap)
                expect(bootstrap.player.bounds).to(equal(
                    FlowRuntimeArtboardBounds(minX: 0, minY: 0, maxX: 390, maxY: 844)
                ))
                let root = try XCTUnwrap(bootstrap.catalog.rootInstance)
                let input = try XCTUnwrap(fixture.manifest.textInputs.first)
                expect(Self.number(
                    in: bootstrap.values,
                    instanceID: root.id,
                    path: input.geometry.widthPath
                )).to(equal(294))
                expect(Self.number(
                    in: bootstrap.values,
                    instanceID: root.id,
                    path: input.geometry.heightPath
                )).to(equal(24))

                let initialized = try await session.perform(
                    .advance(FlowRuntimeFrameTime(timestamp: 0, delta: 0)),
                    drawable: nil
                )
                expect(initialized.diagnostics.map(\.severity)).notTo(contain(.fatal))

                let changed = try await session.perform(
                    .textRunBatch(FlowRuntimeTextRunBatch(mutations: [
                        FlowRuntimeTextRunMutation(
                            name: input.riveTextRunName,
                            text: "swift@nuxie.dev"
                        ),
                    ])),
                    drawable: nil
                )
                expect(changed.isDirty).to(beTrue())
                expect(changed.wakeAfter).to(equal(0))

                do {
                    _ = try await session.perform(
                        .textRunBatch(FlowRuntimeTextRunBatch(mutations: [
                            FlowRuntimeTextRunMutation(
                                name: "Missing Run",
                                text: "missing@nuxie.dev"
                            ),
                        ])),
                        drawable: nil
                    )
                    fail("expected the missing authored text run to fail")
                } catch NuxieRuntimeAdapterError.callFailed(let status, _) {
                    expect(status).to(equal(.notFound))
                } catch {
                    fail("unexpected error: \(error)")
                }

                let recovered = try await session.perform(
                    .textRunBatch(FlowRuntimeTextRunBatch(mutations: [
                        FlowRuntimeTextRunMutation(
                            name: input.riveTextRunName,
                            text: "recovered@nuxie.dev"
                        ),
                    ])),
                    drawable: nil
                )
                expect(recovered.isDirty).to(beTrue())
                expect(recovered.wakeAfter).to(equal(0))
            }

            it("imports a declared optional asset omission through C") { @MainActor in
                let fixture = try Self.publishedFontFixture(omitOptionalFont: true)
                let request = try FlowRuntimeArtifactAdapter.makeImportRequest(
                    artifactBytes: fixture.artifactBytes,
                    manifest: fixture.manifest,
                    expectedIdentity: FlowRuntimeArtifactIdentity(
                        flowId: fixture.manifest.flowId,
                        buildId: fixture.manifest.buildId
                    ),
                    authorizationEvidence: FlowRuntimeAuthorizationEvidence(
                        signedContentBytes: fixture.manifestBytes,
                        signatureEnvelopeBytes: nil,
                        selectedKey: nil
                    ),
                    assetURLsByRiveUniqueName: fixture.assetURLs
                )

                let attachment = try await NuxieRuntimeAdapter().makeContext(for: request)
                defer { attachment.driver.dispose() }
                expect(attachment.importResult.diagnostics.map(\.code)).to(
                    contain("artifact.asset.optional_missing")
                )
            }

            it("marshals the exact native asset limit without recursive stack growth") { @MainActor in
                let base = try Self.unsignedRequest(artifactBytes: Self.fixtureBytes())
                let assets = (0..<FlowRuntimeImportLimits.externalAssetCount).map { index in
                    FlowRuntimeExternalAsset(
                        kind: .image,
                        riveAssetId: UInt32(index),
                        riveUniqueName: "optional-\(index)",
                        sourceKey: "source-\(index)",
                        expectedSHA256: String(repeating: "a", count: 64),
                        required: false,
                        content: .omittedOptional
                    )
                }
                let request = FlowRuntimeImportRequest(
                    artifactBytes: base.artifactBytes,
                    expectedIdentity: base.expectedIdentity,
                    authorizationEvidence: base.authorizationEvidence,
                    externalAssets: assets
                )

                do {
                    _ = try await NuxieRuntimeAdapter().makeContext(for: request)
                    fail("expected undeclared fixture assets to fail native validation")
                } catch NuxieRuntimeAdapterError.callFailed(let status, let diagnostic) {
                    expect(status).to(equal(.importError))
                    expect(diagnostic.code).to(equal("artifact.asset.undeclared"))
                } catch {
                    fail("unexpected error: \(error)")
                }
            }

            it("presents a known fixture and recovers the packaged surface lifecycle") { @MainActor in
                let fixtureBytes = try Self.fixtureBytes()
                let adapter = NuxieRuntimeAdapter()
                let factory = FlowRuntimeContextFactory(adapter: adapter)
                let context = try await factory.makeContext(
                    for: try Self.unsignedRequest(artifactBytes: fixtureBytes)
                )
                let session = try await context.makeSession(
                    descriptor: FlowRenderSessionDescriptor(artboardName: "Two")
                )
                defer {
                    session.dispose()
                }

                let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 96, height: 96))
                let viewController = UIViewController()
                let view = FlowRuntimeSurfaceView(frame: window.bounds)
                viewController.view.addSubview(view)
                window.rootViewController = viewController
                window.makeKeyAndVisible()
                view.layoutIfNeeded()
                let size = FlowRuntimeSurfaceSizing.pixels(
                    width: view.bounds.width,
                    height: view.bounds.height,
                    scale: view.metalLayer.contentsScale
                )
                let surface: FlowRenderSurface
                do {
                    surface = try await session.attachAppleSurface(
                        to: FlowRuntimeAppleSurfaceTarget(layer: view.metalLayer, size: size)
                    )
                } catch {
                    fail("surface attach failed: \(String(reflecting: error))")
                    return
                }
                defer { surface.dispose() }
                expect(surface.attachmentResult.renderOutcome).to(equal(.notRequested))
                expect(surface.attachmentResult.surfaceDisposition).to(equal(.recreated))
                expect(view.metalLayer.device).notTo(beNil())
                expect(view.metalLayer.pixelFormat).to(equal(.bgra8Unorm))
                let initialDrawableSize = CGSize(
                    width: CGFloat(size.pixelWidth),
                    height: CGFloat(size.pixelHeight)
                )
                expect(view.metalLayer.drawableSize).to(equal(initialDrawableSize))

                let unavailable = try await session.perform(
                    .advanceAndRender(FlowRuntimeFrameTime(timestamp: 1, delta: 0))
                )
                expect(unavailable.renderOutcome).to(equal(.skipped))
                expect(unavailable.surfaceDisposition).to(equal(.skippedTimeout))

                let result: FlowRuntimeOperationResult
                do {
                    guard let drawable = view.metalLayer.nextDrawable() else {
                        fail("configured CAMetalLayer did not vend a drawable")
                        return
                    }
                    result = try await session.perform(
                        .advanceAndRender(FlowRuntimeFrameTime(timestamp: 2, delta: 0)),
                        drawable: surface.makeDrawableTarget(drawable, onCompleted: {})
                    )
                } catch {
                    fail("surface render failed: \(String(reflecting: error))")
                    return
                }
                expect(result.renderOutcome).to(equal(.presented))
                expect(result.surfaceDisposition).to(equal(.presented))

                let zeroSize = try await surface.resize(
                    to: FlowRuntimeSurfaceSize(pixelWidth: 0, pixelHeight: 0)
                )
                expect(zeroSize.surfaceDisposition).to(equal(.skippedZeroSize))
                expect(view.metalLayer.drawableSize).to(equal(initialDrawableSize))

                let zeroSizeFrame = try await session.perform(
                    .advanceAndRender(FlowRuntimeFrameTime(timestamp: 3, delta: 0))
                )
                expect(zeroSizeFrame.renderOutcome).to(equal(.skipped))
                expect(zeroSizeFrame.surfaceDisposition).to(equal(.skippedZeroSize))

                let resized = try await surface.resize(
                    to: FlowRuntimeSurfaceSize(pixelWidth: 64, pixelHeight: 48)
                )
                expect(resized.surfaceDisposition).to(equal(.reconfigured))
                expect(view.metalLayer.drawableSize).to(equal(CGSize(width: 64, height: 48)))

                let detached = try await surface.detach()
                expect(detached.surfaceDisposition).to(
                    equal(FlowRuntimeSurfaceDisposition.none)
                )
                expect(view.metalLayer.device).to(beNil())
                do {
                    _ = try await session.perform(
                        .advanceAndRender(FlowRuntimeFrameTime(timestamp: 4, delta: 0))
                    )
                    fail("expected rendering a detached surface to fail")
                } catch NuxieRuntimeAdapterError.callFailed(let status, let diagnostic) {
                    expect(status).to(equal(.surfaceError))
                    expect(diagnostic.code).to(equal("nux_runtime.surface_error"))
                    expect(diagnostic.message).to(contain("not attached"))
                } catch {
                    fail("unexpected error: \(error)")
                }

                let reattached = try await surface.reattach(
                    to: FlowRuntimeAppleSurfaceTarget(
                        layer: view.metalLayer,
                        size: FlowRuntimeSurfaceSize(pixelWidth: 64, pixelHeight: 48)
                    )
                )
                expect(reattached.surfaceDisposition).to(equal(.recreated))
                expect(view.metalLayer.device).notTo(beNil())

                guard let recoveredDrawable = view.metalLayer.nextDrawable() else {
                    fail("reattached CAMetalLayer did not vend a drawable")
                    return
                }
                let recovered = try await session.perform(
                    .advanceAndRender(FlowRuntimeFrameTime(timestamp: 5, delta: 0)),
                    drawable: surface.makeDrawableTarget(recoveredDrawable, onCompleted: {})
                )
                expect(recovered.renderOutcome).to(equal(.presented))
                expect(recovered.surfaceDisposition).to(equal(.presented))
            }

            it("preserves native children across parent-first disposal without borrowing the layer") { @MainActor in
                let fixtureBytes = try Self.fixtureBytes()
                let adapter = NuxieRuntimeAdapter()
                let contextAttachment = try await adapter.makeContext(
                    for: try Self.unsignedRequest(artifactBytes: fixtureBytes)
                )
                let context = contextAttachment.driver
                let sessionAttachment = try await context.makeSession(
                    descriptor: FlowRenderSessionDescriptor(artboardName: "Two")
                )
                let session = sessionAttachment.driver
                var layer: CAMetalLayer? = CAMetalLayer()
                let weakLayer = WeakReference(layer)
                let attachment: FlowRuntimeSurfaceDriverAttachment
                if let layer {
                    attachment = try await session.attachAppleSurface(
                        to: FlowRuntimeAppleSurfaceTarget(
                            layer: layer,
                            size: FlowRuntimeSurfaceSize(pixelWidth: 8, pixelHeight: 8)
                        )
                    )
                } else {
                    fail("expected a live CAMetalLayer")
                    return
                }
                let surface = attachment.driver
                defer {
                    surface.dispose()
                    session.dispose()
                    context.dispose()
                }
                layer = nil
                expect(weakLayer.value).to(beNil())

                context.dispose()
                context.dispose()
                let childAfterContext = try await session.perform(
                    .advance(FlowRuntimeFrameTime(timestamp: 1, delta: 0)),
                    drawable: nil
                )
                expect(childAfterContext.surfaceDisposition).to(
                    equal(FlowRuntimeSurfaceDisposition.none)
                )
                do {
                    _ = try await context.makeSession(
                        descriptor: FlowRenderSessionDescriptor(artboardName: "Two")
                    )
                    fail("expected the disposed context handle to be unavailable")
                } catch NuxieRuntimeAdapterError.missingHandle(let name) {
                    expect(name).to(equal("runtime context"))
                } catch {
                    fail("unexpected error: \(error)")
                }

                session.dispose()
                session.dispose()
                let childAfterSession = try await surface.resize(
                    to: FlowRuntimeSurfaceSize(pixelWidth: 10, pixelHeight: 10)
                )
                expect(childAfterSession.surfaceDisposition).to(equal(.reconfigured))
                do {
                    _ = try await session.perform(
                        .advance(FlowRuntimeFrameTime(timestamp: 2, delta: 0)),
                        drawable: nil
                    )
                    fail("expected the disposed session handle to be unavailable")
                } catch NuxieRuntimeAdapterError.missingHandle(let name) {
                    expect(name).to(equal("render session"))
                } catch {
                    fail("unexpected error: \(error)")
                }

                surface.dispose()
                surface.dispose()
                do {
                    _ = try await surface.resize(
                        to: FlowRuntimeSurfaceSize(pixelWidth: 12, pixelHeight: 12)
                    )
                    fail("expected the disposed surface handle to be unavailable")
                } catch NuxieRuntimeAdapterError.missingHandle(let name) {
                    expect(name).to(equal("Apple surface"))
                } catch {
                    fail("unexpected error: \(error)")
                }
            }
        }
    }

    private static func fixtureBytes() throws -> Data {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(
            forResource: "nuxie_runtime_two_artboards.riv",
            withExtension: "base64",
            subdirectory: "Fixtures"
        ) ?? bundle.url(
            forResource: "nuxie_runtime_two_artboards.riv",
            withExtension: "base64"
        ) else {
            throw FixtureError.missing
        }
        let encoded = try Data(contentsOf: url)
        guard let decoded = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) else {
            throw FixtureError.invalidBase64
        }
        return decoded
    }

    private static func unsignedRequest(
        artifactBytes: Data,
        flowId: String = "runtime-adapter-flow",
        buildId: String = "runtime-adapter-build"
    ) throws -> FlowRuntimeImportRequest {
        let manifestBytes = try JSONSerialization.data(
            withJSONObject: [
                "version": 1,
                "flowId": flowId,
                "buildId": buildId,
                "renderer": "rive",
                "riv": [
                    "path": "flow.riv",
                    "sha256": FlowArtifactStore.sha256Hex(artifactBytes),
                    "sizeBytes": artifactBytes.count,
                ],
                "assets": ["images": [], "fonts": []],
            ],
            options: [.sortedKeys]
        )
        return FlowRuntimeImportRequest(
            artifactBytes: artifactBytes,
            expectedIdentity: FlowRuntimeArtifactIdentity(
                flowId: flowId,
                buildId: buildId
            ),
            authorizationEvidence: FlowRuntimeAuthorizationEvidence(
                signedContentBytes: manifestBytes,
                signatureEnvelopeBytes: nil,
                selectedKey: nil
            )
        )
    }

    private static func authenticatedRequest(
        artifactBytes: Data
    ) throws -> FlowRuntimeImportRequest {
        let unsigned = try unsignedRequest(artifactBytes: artifactBytes)
        guard let unsignedEvidence = unsigned.authorizationEvidence,
              let identity = unsigned.expectedIdentity else {
            throw FixtureError.invalidRequest
        }
        let privateKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(repeating: 9, count: 32)
        )
        let keyId = "runtime-adapter-test-key"
        let signature = try privateKey.signature(
            for: unsignedEvidence.signedContentBytes
        )
        let signatureEnvelopeBytes = try JSONSerialization.data(
            withJSONObject: [
                "version": 1,
                "signs": "nuxie-manifest.json",
                "algorithm": "ed25519",
                "keyId": keyId,
                "signatureBase64": signature.base64EncodedString(),
            ],
            options: [.sortedKeys]
        )
        return FlowRuntimeImportRequest(
            artifactBytes: artifactBytes,
            expectedIdentity: identity,
            authorizationEvidence: FlowRuntimeAuthorizationEvidence(
                signedContentBytes: unsignedEvidence.signedContentBytes,
                signatureEnvelopeBytes: signatureEnvelopeBytes,
                selectedKey: FlowRuntimeAuthorizationKey(
                    keyId: keyId,
                    ed25519PublicKeyBytes: privateKey.publicKey.rawRepresentation
                )
            )
        )
    }

    private struct PublishedFontFixture {
        let artifactBytes: Data
        let manifestBytes: Data
        let manifest: FlowArtifactManifest
        let assetURLs: [String: URL]
    }

    private static func publishedFontFixture(
        fixtureName: String = "published-font",
        omitOptionalFont: Bool = false
    ) throws -> PublishedFontFixture {
        let bundle = Bundle(for: Self.self)
        guard let root = bundle.url(
            forResource: fixtureName,
            withExtension: nil
        ) else {
            throw FixtureError.missing
        }
        let rivURL = root.appendingPathComponent("flow.riv")
        let manifestURL = root.appendingPathComponent("nuxie-manifest.json")
        let artifactBytes = try Data(contentsOf: rivURL, options: .mappedIfSafe)
        var manifestBytes = try Data(contentsOf: manifestURL)

        if omitOptionalFont {
            guard var object = try JSONSerialization.jsonObject(with: manifestBytes)
                as? [String: Any],
                var assets = object["assets"] as? [String: Any],
                var fonts = assets["fonts"] as? [[String: Any]],
                !fonts.isEmpty else {
                throw FixtureError.invalidRequest
            }
            fonts[0]["required"] = false
            assets["fonts"] = fonts
            object["assets"] = assets
            manifestBytes = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            )
        }

        let manifest = try JSONDecoder().decode(
            FlowArtifactManifest.self,
            from: manifestBytes
        )
        var assetURLs: [String: URL] = [:]
        for image in manifest.assets.images {
            assetURLs[image.riveUniqueName] = root.appendingPathComponent(image.path)
        }
        if !omitOptionalFont {
            for font in manifest.assets.fonts {
                guard let filename = URL(string: font.assetUrl)?.lastPathComponent,
                      !filename.isEmpty else {
                    throw FixtureError.invalidRequest
                }
                assetURLs[font.riveUniqueName] = root
                    .appendingPathComponent("assets/fonts")
                    .appendingPathComponent(filename)
            }
        }
        return PublishedFontFixture(
            artifactBytes: artifactBytes,
            manifestBytes: manifestBytes,
            manifest: manifest,
            assetURLs: assetURLs
        )
    }

    private static func number(
        in arena: FlowRuntimeValueArena,
        instanceID: FlowRuntimeInstanceID,
        path: String
    ) -> Double? {
        guard var nodeIndex = arena.roots.first(where: {
            $0.instanceID == instanceID
        })?.nodeIndex else {
            return nil
        }
        for component in path.split(separator: "/").map(String.init) {
            guard arena.nodes.indices.contains(nodeIndex) else { return nil }
            let fields: [FlowRuntimeValueEdge]
            switch arena.nodes[nodeIndex].value {
            case .object(_, let value), .viewModel(_, _, let value):
                fields = value
            case .scalar, .list:
                return nil
            }
            guard let next = fields.first(where: { $0.key == component }) else {
                return nil
            }
            nodeIndex = next.nodeIndex
        }
        guard arena.nodes.indices.contains(nodeIndex),
              case .scalar(.number(let value)) = arena.nodes[nodeIndex].value,
              value.isFinite else {
            return nil
        }
        return value
    }
}

private enum FixtureError: Error {
    case missing
    case invalidBase64
    case invalidRequest
}

private final class WeakReference<Value: AnyObject> {
    private(set) weak var value: Value?

    init(_ value: Value?) {
        self.value = value
    }
}
#endif
