#if NUXIE_RUNTIME_ADAPTER_TESTS && !canImport(NuxieRuntime)
#error("runtime fixture traces require the packaged NuxieRuntime Clang module")
#endif

#if canImport(NuxieRuntime)
import Foundation
import NuxieRuntime
import XCTest

@testable import Nuxie

/// Binary-boundary evidence for the two authored behaviors Slice 3 replaces:
/// typed ViewModel exchange and pointer-driven interaction output.
@MainActor
final class NuxieRuntimeFixtureTraceTests: XCTestCase {
    func testDataBindingFixturePreservesTypedStateAndOrderedTrace() async throws {
        let artifact = try Self.dataBindingFixture()
        let contextAttachment = try await NuxieRuntimeAdapter().makeContext(
            for: try Self.unsignedRequest(
                artifact: artifact,
                flowID: "data-binding-trace"
            )
        )
        let context = contextAttachment.driver
        defer { context.dispose() }

        let sessionAttachment = try await context.makeSession(
            descriptor: FlowRenderSessionDescriptor(
                artboardName: "Artboard",
                stateMachineName: "State Machine 2"
            )
        )
        let session = sessionAttachment.driver
        defer { session.dispose() }

        let bootstrap = sessionAttachment.bootstrap
        XCTAssertEqual(bootstrap.player.artboardName, "Artboard")
        XCTAssertEqual(bootstrap.player.playerName, "State Machine 2")
        XCTAssertEqual(bootstrap.player.kind, .stateMachine)
        let root = try XCTUnwrap(bootstrap.catalog.rootInstance)
        XCTAssertEqual(root.schemaID, "Test")
        XCTAssertEqual(
            Set(bootstrap.catalog.schemas
                .first(where: { $0.id == root.schemaID })?
                .properties.map(\.name) ?? []),
            Set([
                "Boolean", "Color", "Enum", "Image", "List", "Nested",
                "Number", "SecondNested", "String", "Trigger Blue",
                "Trigger Green", "Trigger Red",
            ])
        )

        let mutationID: UInt64 = 7_001
        let stateResult = try await session.perform(
            .stateBatch(FlowRuntimeStateBatch(
                hostMutationID: mutationID,
                mutations: [
                    .setValue(
                        instance: .existing(root.id),
                        path: "String",
                        value: .string("rust-boundary")
                    ),
                    .setValue(
                        instance: .existing(root.id),
                        path: "Number",
                        value: .number(137)
                    ),
                    .setValue(
                        instance: .existing(root.id),
                        path: "Boolean",
                        value: .bool(true)
                    ),
                ]
            )),
            drawable: nil
        )

        XCTAssertEqual(stateResult.orderedOutputs.map(\.sequence), [1, 2, 3])
        XCTAssertEqual(Set(stateResult.orderedOutputs.map(\.cycle)), [1])
        XCTAssertEqual(
            stateResult.orderedOutputs.map(\.phase),
            [.viewModelChanges, .viewModelChanges, .viewModelChanges]
        )
        XCTAssertEqual(
            stateResult.orderedOutputs.compactMap(Self.stateChange),
            [
                FlowRuntimeStateChange(
                    instanceID: root.id,
                    path: "String",
                    value: .string("rust-boundary"),
                    originMutationID: mutationID
                ),
                FlowRuntimeStateChange(
                    instanceID: root.id,
                    path: "Number",
                    value: .number(137),
                    originMutationID: mutationID
                ),
                FlowRuntimeStateChange(
                    instanceID: root.id,
                    path: "Boolean",
                    value: .bool(true),
                    originMutationID: mutationID
                ),
            ]
        )

        let queryResult = try await session.perform(.query([.values]), drawable: nil)
        XCTAssertTrue(queryResult.orderedOutputs.isEmpty)
        let queriedValues = try XCTUnwrap(queryResult.values)
        XCTAssertEqual(
            Self.scalar(in: queriedValues, instanceID: root.id, path: "String"),
            .string("rust-boundary")
        )
        XCTAssertEqual(
            Self.scalar(in: queriedValues, instanceID: root.id, path: "Number"),
            .number(137)
        )
        XCTAssertEqual(
            Self.scalar(in: queriedValues, instanceID: root.id, path: "Boolean"),
            .bool(true)
        )

        let advanceResult = try await session.perform(
            .advance(FlowRuntimeFrameTime(timestamp: 10, delta: 0)),
            drawable: nil
        )
        XCTAssertEqual(advanceResult.orderedOutputs.first?.sequence, 4)
        XCTAssertEqual(advanceResult.orderedOutputs.first?.cycle, 2)
        XCTAssertEqual(advanceResult.orderedOutputs.first?.phase, .runtimeAdvance)
        XCTAssertEqual(
            advanceResult.orderedOutputs.first?.payload,
            .runtimeAdvanced(delta: 0)
        )
        Self.assertOrderedTrace(
            stateResult.orderedOutputs + advanceResult.orderedOutputs
        )
    }

    func testPressableFixtureEmitsReleaseEventBeforeAdvanceInStableOrder() async throws {
        let artifact = try Self.pressableFixture()
        XCTAssertEqual(
            FlowArtifactStore.sha256Hex(artifact),
            "059005e09d1aa868f82f48e65d865f953cef69991e97a77edde7aa7ebdfe6c2a"
        )
        let contextAttachment = try await NuxieRuntimeAdapter().makeContext(
            for: try Self.unsignedRequest(
                artifact: artifact,
                flowID: "pressable-interaction"
            )
        )
        let context = contextAttachment.driver
        defer { context.dispose() }

        let sessionAttachment = try await context.makeSession(
            descriptor: FlowRenderSessionDescriptor(
                artboardName: "Pressable",
                stateMachineName: "Generated Nuxie Pressable Visual State"
            )
        )
        let session = sessionAttachment.driver
        defer { session.dispose() }

        XCTAssertEqual(sessionAttachment.bootstrap.player.kind, .stateMachine)
        XCTAssertEqual(
            sessionAttachment.bootstrap.player.bounds,
            FlowRuntimeArtboardBounds(minX: 0, minY: 0, maxX: 390, maxY: 844)
        )

        let inputs = try await session.perform(.query([.playerInputs]), drawable: nil)
        XCTAssertTrue(inputs.orderedOutputs.isEmpty)
        XCTAssertEqual(inputs.playerInputs, [
            FlowRuntimePlayerInput(
                name: "__nuxie_pressable_cta_pressable_is_pressed",
                kind: .bool,
                value: .bool(false)
            ),
        ])

        let initialAdvance = try await session.perform(
            .advance(FlowRuntimeFrameTime(timestamp: 0, delta: 0)),
            drawable: nil
        )
        XCTAssertEqual(initialAdvance.orderedOutputs.map(\.sequence), [1])
        XCTAssertEqual(initialAdvance.orderedOutputs.map(\.cycle), [1])
        XCTAssertEqual(initialAdvance.orderedOutputs.map(\.phase), [.runtimeAdvance])
        XCTAssertEqual(
            initialAdvance.orderedOutputs.map(\.payload),
            [.runtimeAdvanced(delta: 0)]
        )

        let down = try await session.perform(
            .pointerBatch([
                FlowRuntimePointerEvent(kind: .down, pointerID: 1, x: 195, y: 422),
            ]),
            drawable: nil
        )
        XCTAssertEqual(down.orderedOutputs.map(\.sequence), [2])
        XCTAssertEqual(down.orderedOutputs.map(\.cycle), [2])
        XCTAssertEqual(down.orderedOutputs.map(\.phase), [.runtimeAdvance])
        XCTAssertEqual(down.orderedOutputs.map(\.payload), [.runtimeAdvanced(delta: 0)])

        let up = try await session.perform(
            .pointerBatch([
                FlowRuntimePointerEvent(kind: .up, pointerID: 1, x: 195, y: 422),
            ]),
            drawable: nil
        )
        XCTAssertEqual(up.orderedOutputs.map(\.sequence), [3, 4])
        XCTAssertEqual(up.orderedOutputs.map(\.cycle), [3, 3])
        XCTAssertEqual(up.orderedOutputs.map(\.phase), [.reportedEvents, .runtimeAdvance])
        XCTAssertEqual(up.orderedOutputs.last?.payload, .runtimeAdvanced(delta: 0))
        XCTAssertNil(up.wakeAfter)

        let zeroAdvance = try await session.perform(
            .advance(FlowRuntimeFrameTime(timestamp: 20, delta: 0)),
            drawable: nil
        )
        XCTAssertEqual(zeroAdvance.orderedOutputs.map(\.sequence), [5])
        XCTAssertEqual(zeroAdvance.orderedOutputs.map(\.cycle), [4])
        XCTAssertEqual(zeroAdvance.orderedOutputs.map(\.phase), [.runtimeAdvance])
        XCTAssertEqual(zeroAdvance.orderedOutputs.map(\.payload), [.runtimeAdvanced(delta: 0)])

        guard case .reportedEvent(
            let eventName,
            let eventType,
            let delay,
            let properties
        ) = up.orderedOutputs.first?.payload else {
            return XCTFail("release did not report the interaction event first")
        }
        XCTAssertEqual(eventName, "Nuxie Interaction")
        XCTAssertEqual(eventType, 128)
        XCTAssertEqual(delay, 0)
        XCTAssertEqual(properties, [
            FlowRuntimeEventProperty(name: "nuxieTrigger", value: .string("press")),
            FlowRuntimeEventProperty(name: "componentId", value: .string("cta_pressable")),
        ])
        Self.assertOrderedTrace(
            initialAdvance.orderedOutputs + down.orderedOutputs
                + up.orderedOutputs + zeroAdvance.orderedOutputs
        )
    }

    private static func stateChange(_ output: FlowRuntimeOutput) -> FlowRuntimeStateChange? {
        switch output.payload {
        case .stateChange(let change), .viewModelChange(let change):
            change
        case .delayedEvent, .reportedEvent, .hostCommand, .renderRequest,
             .runtimeAdvanced:
            nil
        }
    }

    private static func scalar(
        in arena: FlowRuntimeValueArena,
        instanceID: FlowRuntimeInstanceID,
        path: String
    ) -> FlowRuntimeScalarValue? {
        guard var nodeIndex = arena.roots.first(where: {
            $0.instanceID == instanceID
        })?.nodeIndex else {
            return nil
        }
        for component in path.split(separator: "/").map(String.init) {
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
        guard case .scalar(let value) = arena.nodes[nodeIndex].value else {
            return nil
        }
        return value
    }

    private static func assertOrderedTrace(
        _ outputs: [FlowRuntimeOutput],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for pair in zip(outputs, outputs.dropFirst()) {
            XCTAssertGreaterThan(pair.1.sequence, pair.0.sequence, file: file, line: line)
            XCTAssertGreaterThanOrEqual(pair.1.cycle, pair.0.cycle, file: file, line: line)
            if pair.1.cycle == pair.0.cycle {
                XCTAssertGreaterThanOrEqual(
                    pair.1.phase.rawValue,
                    pair.0.phase.rawValue,
                    file: file,
                    line: line
                )
            }
        }
    }

    private static func unsignedRequest(
        artifact: Data,
        flowID: String
    ) throws -> FlowRuntimeImportRequest {
        let buildID = "slice-3-fixture-trace"
        let manifest = try JSONSerialization.data(
            withJSONObject: [
                "version": 1,
                "flowId": flowID,
                "buildId": buildID,
                "renderer": "rive",
                "riv": [
                    "path": "flow.riv",
                    "sha256": FlowArtifactStore.sha256Hex(artifact),
                    "sizeBytes": artifact.count,
                ],
                "assets": ["images": [], "fonts": []],
            ],
            options: [.sortedKeys]
        )
        return FlowRuntimeImportRequest(
            artifactBytes: artifact,
            expectedIdentity: FlowRuntimeArtifactIdentity(
                flowId: flowID,
                buildId: buildID
            ),
            authorizationEvidence: FlowRuntimeAuthorizationEvidence(
                signedContentBytes: manifest,
                signatureEnvelopeBytes: nil,
                selectedKey: nil
            )
        )
    }

    private static func dataBindingFixture() throws -> Data {
        let bundle = Bundle(for: Self.self)
        let url = bundle.url(
            forResource: "data_binding_test",
            withExtension: "riv",
            subdirectory: "Fixtures"
        ) ?? bundle.url(forResource: "data_binding_test", withExtension: "riv")
        return try Data(contentsOf: XCTUnwrap(url))
    }

    private static func pressableFixture() throws -> Data {
        let bundle = Bundle(for: Self.self)
        let url = bundle.url(
            forResource: "flow",
            withExtension: "riv",
            subdirectory: "pressable-interaction"
        ) ?? bundle.url(forResource: "flow", withExtension: "riv")
        return try Data(contentsOf: XCTUnwrap(url))
    }
}
#endif
