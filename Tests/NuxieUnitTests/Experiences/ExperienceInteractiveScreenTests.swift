#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import Foundation
import QuartzCore
import XCTest
@testable import Nuxie
@testable import NuxieRuntime
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

final class ExperienceInteractiveScreenTests: XCTestCase {
    #if canImport(UIKit)
    func testStepDeliveryOrdersCanonicalEffectsLayoutAndHostPhase() {
        let reported = ExperienceInteractiveEffect(
            sequence: 0,
            correlationID: 0,
            kind: .reportedEvent(ExperienceInteractiveReportedEvent(
                localIndex: 0,
                coreType: 0,
                name: "reported",
                url: "",
                target: "",
                delay: 0,
                properties: []
            ))
        )
        let viewModel = ExperienceInteractiveEffect(
            sequence: 1,
            correlationID: 0,
            kind: .viewModelChange(ExperienceInteractiveViewModelChange(
                origin: .runtime,
                correlationID: 0,
                ownerInstanceID: 1,
                propertyIndex: 0,
                value: .bytes(Data("canonical".utf8))
            ))
        )
        let navigation = ExperienceInteractiveEffect(
            sequence: 2,
            correlationID: 0,
            kind: .navigate(screenID: "next", transition: nil)
        )

        XCTAssertEqual(
            ExperienceInteractiveStepDeliveryPlanner.items(
                effects: [reported, viewModel, navigation],
                includesTextInputLayout: true
            ),
            [
                .effect(reported),
                .effect(viewModel),
                .textInputLayout,
                .effect(navigation),
            ]
        )
    }

    func testAuthenticatedExternalFontIsRegisteredForScreenLifetimeAndReleasedOnClose() async throws {
        let payload = try await authenticatedFixturePayload(named: "font-converter")
        let font = try XCTUnwrap(payload.renderPlan.fonts.first(where: {
            if case .external = $0.location { return true }
            return false
        }))
        XCTAssertNil(ExperienceRuntimeFontRegistry.font(
            forRiveUniqueName: font.riveUniqueName,
            contentSHA256: font.sha256,
            size: 16
        ))

        let screen = try await ExperienceInteractiveScreen.open(
            payload: payload,
            pixelWidth: 64,
            pixelHeight: 64
        )
        defer { Task { try? await screen.close() } }
        XCTAssertNotNil(ExperienceRuntimeFontRegistry.font(
            forRiveUniqueName: font.riveUniqueName,
            contentSHA256: font.sha256,
            size: 16
        ))

        try await screen.close()
        XCTAssertNil(ExperienceRuntimeFontRegistry.font(
            forRiveUniqueName: font.riveUniqueName,
            contentSHA256: font.sha256,
            size: 16
        ))
    }

    func testSignedFontConverterRendersThroughProductConfiguredImport() async throws {
        let payload = try await authenticatedFixturePayload(named: "font-converter")
        let screen = try await ExperienceInteractiveScreen.open(
            payload: payload,
            pixelWidth: 64,
            pixelHeight: 64
        )
        defer { Task { try? await screen.close() } }

        _ = try await renderAndWait(screen)
        try await screen.close()
    }

    @MainActor
    func testPresentationSessionDefersOrderedEffectsUntilMainActorDelivery() async throws {
        let payload = try await authenticatedScriptedPayload()
        let screen = try await ExperienceInteractiveScreen.open(
            payload: payload,
            player: .stateMachine("Generated Nuxie Pressable Interaction"),
            pixelWidth: 64,
            pixelHeight: 64
        )
        defer { Task { try? await screen.close() } }
        let delivered = InteractiveEffectRecorder()
        let session = screen.presentationSession { effects, _ in
            delivered.append(contentsOf: effects)
        }

        _ = try await render(screen)
        _ = try await session.perform(.step(ExperienceRuntimePresentationStep(
            elapsedSeconds: 0.016,
            pointers: []
        )))
        let result = try await session.perform(.step(ExperienceRuntimePresentationStep(
            elapsedSeconds: 0.016,
            pointers: [
                ExperienceInteractivePointerEvent(kind: .down, x: 100, y: 728, pointerID: 1),
                ExperienceInteractivePointerEvent(kind: .up, x: 100, y: 728, pointerID: 1),
            ]
        )))
        XCTAssertTrue(delivered.values.isEmpty)

        await result.deliver()
        XCTAssertEqual(delivered.values.map(\.sequence), Array(0...4))
    }

    @MainActor
    func testPresentationSessionCapturesSnapshotBeforeMainActorDelivery() async throws {
        let payload = try await statePayload(defaultViewModelName: "Test")
        let screen = try await ExperienceInteractiveScreen.open(
            payload: payload,
            pixelWidth: 64,
            pixelHeight: 64
        )
        defer { Task { try? await screen.close() } }
        var deliveredSnapshot: ExperienceInteractiveViewModelSnapshot?
        let session = screen.presentationSession(
            includesSnapshotAfterStep: true
        ) { _, snapshot in
            deliveredSnapshot = snapshot
        }

        let result = try await session.perform(.step(ExperienceRuntimePresentationStep(
            elapsedSeconds: 0.016,
            pointers: []
        )))
        XCTAssertNil(deliveredSnapshot)

        await result.deliver()
        XCTAssertNotNil(deliveredSnapshot)
    }
    #endif

    func testAuthenticatedScreenSurvivesRepeatedRendererDomainCycles() async throws {
        let payload = try await statePayload(defaultViewModelName: "Test")
        XCTAssertFalse(payload.renderPlan.images.isEmpty)
        XCTAssertFalse(payload.renderPlan.fonts.isEmpty)
        let screen = try await ExperienceInteractiveScreen.open(
            payload: payload,
            player: .stateMachine("State Machine 1"),
            pixelWidth: 64,
            pixelHeight: 64
        )
        defer { Task { try? await screen.close() } }

        for _ in 0..<3 {
            _ = try await renderAndWait(screen)
            let detached = try await screen.detachRenderer()
            XCTAssertEqual(detached.health, .healthy)
            let reattached = try await screen.reattachRenderer(pixelWidth: 64, pixelHeight: 64)
            XCTAssertEqual(reattached.disposition, .recreated)
            try await screen.resetPlayerRendererDomain()
            _ = try await screen.step(elapsedSeconds: 0)
        }

        let snapshot = try await screen.snapshot()
        XCTAssertEqual(snapshot.values.first { $0.name == "String" }?.value, .bytes(Data("signed-state".utf8)))
        _ = try await renderAndWait(screen)
        try await screen.close()
    }

    func testAuthenticatedExternalImageSurvivesRepeatedRendererDomainCycles() async throws {
        try await exerciseExternalAssetFixture(named: "external-image")
    }

    func testSignedEmbeddedAudioSurvivesRepeatedRendererDomainCycles() async throws {
        // Pinned from rive-app/rive-runtime@4ac7b32798da0482e441ef09304dc3b480ed3ee5
        // tests/unit_tests/assets/sound.riv.
        let encoded = try fixture(named: "sound_audio", extension: "riv.base64")
        let scene = try XCTUnwrap(Data(base64Encoded: encoded, options: .ignoreUnknownCharacters))
        let catalog = try await NuxieNativeRuntime.inspectAssets(bytes: scene)
        XCTAssertTrue(catalog.contains { $0.kind == .audio && $0.isEmbedded })
        let payload = try await statePayload(
            defaultViewModelName: nil,
            scene: scene,
            artboardName: "New Artboard"
        )
        let screen = try await ExperienceInteractiveScreen.open(
            payload: payload,
            player: .staticArtboard,
            pixelWidth: 64,
            pixelHeight: 64
        )
        defer { Task { try? await screen.close() } }

        for _ in 0..<2 {
            _ = try await renderAndWait(screen)
            let detached = try await screen.detachRenderer()
            XCTAssertEqual(detached.health, .healthy)
            let reattached = try await screen.reattachRenderer(
                pixelWidth: 64,
                pixelHeight: 64
            )
            XCTAssertEqual(reattached.disposition, .recreated)
            try await screen.resetPlayerRendererDomain()
        }
        _ = try await renderAndWait(screen)
        try await screen.close()
    }

    func testSignedEmbeddedScriptAndShaderOpenThroughConfiguredImport() async throws {
        let payload = try await authenticatedFixturePayload(
            named: "scripted-resources"
        )
        let catalog = try await NuxieNativeRuntime.inspectAssets(
            bytes: payload.sceneBytes
        )
        XCTAssertEqual(catalog.map(\.kind), [.script, .shader])
        XCTAssertTrue(catalog.allSatisfy { descriptor in
            descriptor.isEmbedded
                && descriptor.hasContentsRecord
                && descriptor.requiredProviderFlags == 0
        })

        let screen = try await ExperienceInteractiveScreen.open(
            payload: payload,
            pixelWidth: 64,
            pixelHeight: 64
        )
        defer { Task { try? await screen.close() } }

        _ = try await renderAndWait(screen)
        try await screen.close()
    }

    func testAuthenticatedScriptedScreenRoutesExactProductEffectsInAuthoredOrder() async throws {
        let payload = try await authenticatedScriptedPayload()
        XCTAssertEqual(payload.authenticatedKeyID, "TEST_ONLY_DEV_KEYPAIR")
        let screen = try await ExperienceInteractiveScreen.open(
            payload: payload,
            player: .stateMachine("Generated Nuxie Pressable Interaction"),
            pixelWidth: 64,
            pixelHeight: 64
        )
        defer { Task { try? await screen.close() } }

        _ = try await render(screen)
        _ = try await screen.step(elapsedSeconds: 0.016)
        let result = try await screen.step(
            pointers: [
                ExperienceInteractivePointerEvent(
                    kind: .down,
                    x: 100,
                    y: 728,
                    pointerID: 1
                ),
                ExperienceInteractivePointerEvent(
                    kind: .up,
                    x: 100,
                    y: 728,
                    pointerID: 1
                ),
            ],
            elapsedSeconds: 0.016,
            correlationID: 42
        )

        XCTAssertEqual(result.effects.map(\.sequence), Array(0...4))
        XCTAssertEqual(result.effects.map(\.correlationID), Array(repeating: 42, count: 5))
        XCTAssertEqual(
            result.effects.map(\.kind),
            [
                .responseSet(field: "plan", value: .string("pro")),
                .journeyEvent(name: "purchase_tapped", payload: Self.object([
                    ("placementIndex", .number(2)),
                    ("productId", .string("pro_annual")),
                ])),
                .hostCommand(name: "selection_changed", payload: Self.object([
                    ("value", .string("annual"))
                ])),
                .hostCommand(name: "custom.analytics", payload: Self.object([
                    ("channel", .string("editor")),
                    ("sampled", .bool(true)),
                ])),
                .rejectedHostCommand(
                    name: "$response_set",
                    reason: "expected a non-empty string field and a value"
                ),
            ]
        )

        let journey = try makeJourneyRunner(document: payload.journey)
        let navigated = InteractiveNavigatedScreenRecorder()
        await journey.runner.setOnShowScreen { screenID, _ in
            navigated.append(screenID)
        }
        for effect in result.effects {
            guard case .journeyEvent(let name, let payload) = effect.kind else { continue }
            _ = await journey.runner.dispatchScreenEvent(
                NuxieEvent(
                    name: name,
                    distinctId: "interactive-user",
                    properties: try Self.eventProperties(payload)
                ),
                screenId: "screen_1",
                componentId: nil,
                instanceId: nil
            )
        }
        XCTAssertEqual(navigated.values, ["screen_1"])
    }

    func testAuthenticatedFactoryRejectsScreenOutsideSignedManifest() async throws {
        let payload = try await authenticatedScriptedPayload()
        do {
            _ = try await ExperienceInteractiveScreen.open(
                payload: payload,
                screenID: "unsigned-screen",
                player: .staticArtboard,
                pixelWidth: 16,
                pixelHeight: 16
            )
            XCTFail("Expected an unsigned screen to be rejected")
        } catch {
            XCTAssertEqual(
                error as? ExperienceInteractiveScreenError,
                .screenNotFound("unsigned-screen")
            )
        }
    }

    func testAuthenticatedFactoryRejectsAssetOutsideSignedManifestAndSceneCatalog() async throws {
        let payload = try await authenticatedScriptedPayload()
        let tampered = AuthenticatedRuntimePayload(
            authenticatedKeyID: payload.authenticatedKeyID,
            renderPlan: payload.renderPlan,
            journey: payload.journey,
            sceneBytes: payload.sceneBytes,
            assets: [AuthenticatedRuntimeAsset(
                kind: .image,
                riveAssetID: 7,
                riveUniqueName: "unsigned-image-7",
                sourceKey: "assets/unsigned.png",
                contentType: "image/png",
                sha256: String(repeating: "0", count: 64),
                required: false,
                bytes: nil
            )]
        )
        do {
            _ = try await ExperienceInteractiveScreen.open(
                payload: tampered,
                player: .staticArtboard,
                pixelWidth: 16,
                pixelHeight: 16
            )
            XCTFail("Expected an unsigned asset to be rejected")
        } catch {
            XCTAssertEqual(
                error as? ExperienceInteractiveScreenError,
                .assetContract("unsigned-image-7")
            )
        }
    }

    func testFactoryValidatesRootSchemaAndAtomicallyAppliesSignedSDKState() async throws {
        let payload = try await statePayload(defaultViewModelName: "Test")
        XCTAssertEqual(payload.authenticatedKeyID, "TEST_ONLY_DEV_KEYPAIR")
        let screen = try await ExperienceInteractiveScreen.open(
            payload: payload,
            player: .stateMachine("State Machine 1"),
            pixelWidth: 16,
            pixelHeight: 16
        )
        defer { Task { try? await screen.close() } }

        let root = try await screen.rootViewModel()
        let resolved = try await screen.viewModel(named: "Test", instanceID: "root-sdk-id")
        let snapshot = try await screen.snapshot()
        XCTAssertEqual(root, resolved)
        XCTAssertEqual(
            snapshot.values.first(where: { $0.name == "Number" })?.value,
            .number(23)
        )
        XCTAssertEqual(
            snapshot.values.first(where: { $0.name == "Boolean" })?.value,
            .bool(true)
        )
        XCTAssertEqual(
            snapshot.values.first(where: { $0.name == "String" })?.value,
            .bytes(Data("signed-state".utf8))
        )
    }

    func testFactoryHydratesFlattenedViewModelAndListStateInOneSignedPayload() async throws {
        let payload = try await statePayload(
            defaultViewModelName: "Test",
            values: [
                JourneyViewModelValue(
                    viewModelName: "Test",
                    instanceId: "root-sdk-id",
                    path: "Nested/vmInstanceId",
                    value: AnyCodable("nested-sdk-id")
                ),
                JourneyViewModelValue(
                    viewModelName: "Test",
                    instanceId: "root-sdk-id",
                    path: "Nested/values/String",
                    value: AnyCodable("nested-signed")
                ),
                JourneyViewModelValue(
                    viewModelName: "Test",
                    instanceId: "root-sdk-id",
                    path: "List",
                    value: AnyCodable([[
                        "vmInstanceId": "row-sdk-id",
                        "viewModelId": "Nested",
                        "values": ["String": "row-signed"],
                    ]])
                ),
            ]
        )
        let screen = try await ExperienceInteractiveScreen.open(
            payload: payload,
            player: .stateMachine("State Machine 1"),
            pixelWidth: 16,
            pixelHeight: 16
        )
        defer { Task { try? await screen.close() } }

        let root = try await screen.rootViewModel()
        let nested = try await screen.viewModel(named: "Nested", instanceID: "nested-sdk-id")
        let row = try await screen.viewModel(named: "Nested", instanceID: "row-sdk-id")
        let snapshot = try await screen.snapshot()
        let rootValues = snapshot.values.filter { $0.ownerInstanceID == root.rawValue }
        guard case .referencedInstance(let linkedNested) = rootValues.first(where: {
            $0.name == "Nested"
        })?.value,
        case .list(let linkedRows) = rootValues.first(where: {
            $0.name == "List"
        })?.value,
        let linkedRow = linkedRows.first else {
            return XCTFail("Expected signed structural state")
        }
        XCTAssertEqual(
            snapshot.values.first(where: {
                $0.ownerInstanceID == linkedNested && $0.name == "String"
            })?.value,
            .bytes(Data("nested-signed".utf8))
        )
        XCTAssertEqual(
            snapshot.values.first(where: {
                $0.ownerInstanceID == linkedRow && $0.name == "String"
            })?.value,
            .bytes(Data("row-signed".utf8))
        )

        _ = try await screen.mutateState(
            [.setString(nested, path: "String", value: Data("nested-sdk".utf8))],
            correlationID: 91
        )
        _ = try await screen.mutateState(
            [.setString(row, path: "String", value: Data("row-sdk".utf8))],
            correlationID: 92
        )
        let mutated = try await screen.snapshot()
        XCTAssertEqual(
            mutated.values.first(where: {
                $0.ownerInstanceID == linkedNested && $0.name == "String"
            })?.value,
            .bytes(Data("nested-sdk".utf8))
        )
        XCTAssertEqual(
            mutated.values.first(where: {
                $0.ownerInstanceID == linkedRow && $0.name == "String"
            })?.value,
            .bytes(Data("row-sdk".utf8))
        )

        do {
            _ = try await screen.mutateState(
                [
                    .listRemove(root, path: "List", index: 0),
                    .setNumber(root, path: "missing", value: 1),
                ],
                correlationID: 93
            )
            XCTFail("Expected the mixed native batch to roll back")
        } catch {}
        _ = try await screen.mutateState(
            [.listRemove(root, path: "List", index: 0)],
            correlationID: 94
        )
        let removed = try await screen.snapshot()
        XCTAssertEqual(
            removed.values.first(where: {
                $0.ownerInstanceID == root.rawValue && $0.name == "List"
            })?.value,
            .list([])
        )
        _ = try await screen.mutateState(
            [.listInsert(root, path: "List", index: 0, value: row)],
            correlationID: 95
        )
        let reinserted = try await screen.snapshot()
        XCTAssertEqual(
            reinserted.values.first(where: {
                $0.ownerInstanceID == root.rawValue && $0.name == "List"
            })?.value,
            .list([linkedRow])
        )
    }

    func testSwiftProductStateCommandResolvesSignedIdentityAndCommitsTypedBatch() async throws {
        let payload = try await statePayload(
            defaultViewModelName: "Test",
            values: [
                JourneyViewModelValue(
                    viewModelName: "Test",
                    instanceId: "root-sdk-id",
                    path: "Number",
                    value: AnyCodable(1)
                ),
                JourneyViewModelValue(
                    viewModelName: "Test",
                    instanceId: "root-sdk-id",
                    path: "Boolean",
                    value: AnyCodable(false)
                ),
                JourneyViewModelValue(
                    viewModelName: "Test",
                    instanceId: "root-sdk-id",
                    path: "String",
                    value: AnyCodable("before")
                ),
            ]
        )
        let screen = try await ExperienceInteractiveScreen.open(
            payload: payload,
            player: .stateMachine("State Machine 1"),
            pixelWidth: 16,
            pixelHeight: 16
        )
        defer { Task { try? await screen.close() } }

        let result = try await screen.applyStateCommand(
            .snapshot([
                .init(
                    viewModelName: "Test",
                    instanceID: "root-sdk-id",
                    instanceName: nil,
                    path: "Number",
                    value: .number(42)
                ),
                .init(
                    viewModelName: "Test",
                    instanceID: "root-sdk-id",
                    instanceName: nil,
                    path: "Boolean",
                    value: .bool(true)
                ),
                .init(
                    viewModelName: "Test",
                    instanceID: "root-sdk-id",
                    instanceName: nil,
                    path: "String",
                    value: .string("after")
                ),
            ]),
            correlationID: 501
        )
        let snapshot = try await screen.snapshot()

        XCTAssertEqual(result.appliedCount, 3)
        XCTAssertEqual(result.correlationID, 501)
        XCTAssertEqual(
            snapshot.values.first(where: { $0.name == "Number" })?.value,
            .number(42)
        )
        XCTAssertEqual(
            snapshot.values.first(where: { $0.name == "Boolean" })?.value,
            .bool(true)
        )
        XCTAssertEqual(
            snapshot.values.first(where: { $0.name == "String" })?.value,
            .bytes(Data("after".utf8))
        )
    }

    func testSwiftStateCommandsExpandObjectValuesAtTheSchemaRoot() async throws {
        let payload = try await statePayload(defaultViewModelName: "Test")
        let screen = try await ExperienceInteractiveScreen.open(
            payload: payload,
            player: .stateMachine("State Machine 1"),
            pixelWidth: 16,
            pixelHeight: 16
        )
        defer { Task { try? await screen.close() } }

        _ = try await screen.applyStateCommand(.value(.init(
            viewModelName: "Test",
            instanceID: "root-sdk-id",
            instanceName: nil,
            path: "",
            value: Self.object([
                ("Number", .number(12)),
                ("String", .string("from-value")),
            ])
        )))
        var snapshot = try await screen.snapshot()
        XCTAssertEqual(
            snapshot.values.first(where: { $0.name == "Number" })?.value,
            .number(12)
        )
        XCTAssertEqual(
            snapshot.values.first(where: { $0.name == "String" })?.value,
            .bytes(Data("from-value".utf8))
        )

        _ = try await screen.applyStateCommand(.snapshot([.init(
            viewModelName: "Test",
            instanceID: "root-sdk-id",
            instanceName: nil,
            path: "",
            value: Self.object([
                ("Boolean", .bool(true)),
                ("String", .string("from-snapshot")),
            ])
        )]))
        snapshot = try await screen.snapshot()
        XCTAssertEqual(
            snapshot.values.first(where: { $0.name == "Boolean" })?.value,
            .bool(true)
        )
        XCTAssertEqual(
            snapshot.values.first(where: { $0.name == "String" })?.value,
            .bytes(Data("from-snapshot".utf8))
        )
    }

    func testSwiftSnapshotReplaysFlattenedViewModelAndCanonicalListAtomically() async throws {
        let payload = try await statePayload(
            defaultViewModelName: "Test",
            values: [
                JourneyViewModelValue(
                    viewModelName: "Test",
                    instanceId: "root-sdk-id",
                    path: "Nested/vmInstanceId",
                    value: AnyCodable("nested-sdk-id")
                ),
                JourneyViewModelValue(
                    viewModelName: "Test",
                    instanceId: "root-sdk-id",
                    path: "Nested/values/String",
                    value: AnyCodable("before-nested")
                ),
                JourneyViewModelValue(
                    viewModelName: "Test",
                    instanceId: "root-sdk-id",
                    path: "List",
                    value: AnyCodable([[
                        "vmInstanceId": "row-sdk-id",
                        "viewModelId": "Nested",
                        "values": ["String": "before-row"],
                    ]])
                ),
            ]
        )
        let screen = try await ExperienceInteractiveScreen.open(
            payload: payload,
            player: .stateMachine("State Machine 1"),
            pixelWidth: 16,
            pixelHeight: 16
        )
        defer { Task { try? await screen.close() } }

        _ = try await screen.applyStateCommand(.snapshot([
            .init(
                viewModelName: "Test",
                instanceID: "root-sdk-id",
                instanceName: nil,
                path: "Nested/vmInstanceId",
                value: .string("nested-sdk-id")
            ),
            .init(
                viewModelName: "Test",
                instanceID: "root-sdk-id",
                instanceName: nil,
                path: "Nested/values/String",
                value: .string("after-nested")
            ),
            .init(
                viewModelName: "Test",
                instanceID: "root-sdk-id",
                instanceName: nil,
                path: "List",
                value: .list([Self.object([
                    ("viewModelId", .string("Nested")),
                    ("vmInstanceId", .string("row-sdk-id")),
                    ("values", Self.object([("String", .string("after-row"))])),
                ])])
            ),
        ]))

        let root = try await screen.rootViewModel()
        let snapshot = try await screen.snapshot()
        guard case .referencedInstance(let nestedID) = snapshot.values.first(where: {
            $0.ownerInstanceID == root.rawValue && $0.name == "Nested"
        })?.value,
        case .list(let rowIDs) = snapshot.values.first(where: {
            $0.ownerInstanceID == root.rawValue && $0.name == "List"
        })?.value,
        let rowID = rowIDs.first else {
            return XCTFail("Expected canonical composite topology")
        }
        XCTAssertEqual(
            snapshot.values.first(where: {
                $0.ownerInstanceID == nestedID && $0.name == "String"
            })?.value,
            .bytes(Data("after-nested".utf8))
        )
        XCTAssertEqual(
            snapshot.values.first(where: {
                $0.ownerInstanceID == rowID && $0.name == "String"
            })?.value,
            .bytes(Data("after-row".utf8))
        )
    }

    func testLiveStateInfersAndAllocatesReferencedSchemaFromOwningProperty() async throws {
        let payload = try await statePayload(
            defaultViewModelName: "Test",
            values: [JourneyViewModelValue(
                viewModelName: "Test",
                instanceId: "root-sdk-id",
                path: "Number",
                value: AnyCodable(1)
            )]
        )
        let screen = try await ExperienceInteractiveScreen.open(
            payload: payload,
            player: .stateMachine("State Machine 1"),
            pixelWidth: 16,
            pixelHeight: 16
        )
        defer { Task { try? await screen.close() } }

        _ = try await screen.applyStateCommand(.value(.init(
            viewModelName: "Test",
            instanceID: "root-sdk-id",
            instanceName: nil,
            path: "Nested",
            value: Self.object([
                ("vmInstanceId", .string("inferred-child")),
                ("values", Self.object([("String", .string("inferred"))])),
            ])
        )))

        let root = try await screen.rootViewModel()
        let snapshot = try await screen.snapshot()
        guard case .referencedInstance(let childID) = snapshot.values.first(where: {
            $0.ownerInstanceID == root.rawValue && $0.name == "Nested"
        })?.value else {
            return XCTFail("Expected the inferred child to be linked")
        }
        XCTAssertEqual(
            snapshot.values.first(where: {
                $0.ownerInstanceID == childID && $0.name == "String"
            })?.value,
            .bytes(Data("inferred".utf8))
        )
    }

    func testSignedAndLiveCompilersRejectWrongReferencedSchema() {
        let wrongEnvelope = Self.object([
            ("viewModelId", .string("Root")),
            ("vmInstanceId", .string("wrong-row")),
        ])
        for policy in [
            ExperienceInteractiveStateCompiler.Policy.signedPackage,
            .liveCommand,
        ] {
            let compiler = ExperienceInteractiveStateCompiler(
                catalog: Self.stateCompilerCatalog,
                policy: policy
            )
            XCTAssertThrowsError(try compiler.envelope(
                from: wrongEnvelope,
                expectedSchemaIndex: 1,
                path: "rows"
            ))
        }
    }

    func testRuntimeCompositeChangesProjectStablePublisherIdentities() async throws {
        let payload = try await statePayload(
            defaultViewModelName: "Test",
            values: [
                JourneyViewModelValue(
                    viewModelName: "Test",
                    instanceId: "root-sdk-id",
                    path: "Nested/vmInstanceId",
                    value: AnyCodable("nested-sdk-id")
                ),
                JourneyViewModelValue(
                    viewModelName: "Test",
                    instanceId: "root-sdk-id",
                    path: "Nested/values/String",
                    value: AnyCodable("nested-value")
                ),
                JourneyViewModelValue(
                    viewModelName: "Test",
                    instanceId: "root-sdk-id",
                    path: "List",
                    value: AnyCodable([[
                        "vmInstanceId": "row-sdk-id",
                        "viewModelId": "Nested",
                        "values": ["String": "row"],
                    ]])
                ),
            ]
        )
        let screen = try await ExperienceInteractiveScreen.open(
            payload: payload,
            player: .stateMachine("State Machine 1"),
            pixelWidth: 16,
            pixelHeight: 16
        )
        defer { Task { try? await screen.close() } }
        let root = try await screen.rootViewModel()
        let nestedReference = try await screen.viewModel(
            named: "Nested",
            instanceID: "nested-sdk-id"
        )
        let rowReference = try await screen.viewModel(named: "Nested", instanceID: "row-sdk-id")
        let snapshot = try await screen.snapshot()
        let nestedValue = try XCTUnwrap(snapshot.values.first(where: {
            $0.ownerInstanceID == root.rawValue && $0.name == "Nested"
        }))
        let listValue = try XCTUnwrap(snapshot.values.first(where: {
            $0.ownerInstanceID == root.rawValue && $0.name == "List"
        }))

        let nested = try await screen.resolveViewModelChange(.init(
            origin: .runtime,
            correlationID: 1,
            ownerInstanceID: root.rawValue,
            propertyIndex: nestedValue.propertyIndex,
            value: .referencedInstance(nestedReference.rawValue)
        ))
        let list = try await screen.resolveViewModelChange(.init(
            origin: .runtime,
            correlationID: 2,
            ownerInstanceID: root.rawValue,
            propertyIndex: listValue.propertyIndex,
            value: .list([rowReference.rawValue])
        ))
        XCTAssertEqual(nested.value["vmInstanceId"], .string("nested-sdk-id"))
        XCTAssertEqual(nested.value["values"]?["String"], .string("nested-value"))
        guard case .list(let rows) = list.value else {
            return XCTFail("Expected canonical list identities")
        }
        XCTAssertEqual(rows.first?["vmInstanceId"], .string("row-sdk-id"))
        XCTAssertEqual(rows.first?["values"]?["String"], .string("row"))
    }

    func testSnapshotAllocatesDynamicInlineListIdentityAndRejectsConflictingFields() async throws {
        let payload = try await statePayload(
            defaultViewModelName: "Test",
            values: [JourneyViewModelValue(
                viewModelName: "Test",
                instanceId: "root-sdk-id",
                path: "Number",
                value: AnyCodable(1)
            )]
        )
        let screen = try await ExperienceInteractiveScreen.open(
            payload: payload,
            player: .stateMachine("State Machine 1"),
            pixelWidth: 16,
            pixelHeight: 16
        )
        defer { Task { try? await screen.close() } }

        _ = try await screen.applyStateCommand(.snapshot([.init(
            viewModelName: "Test",
            instanceID: "root-sdk-id",
            instanceName: nil,
            path: "List",
            value: .list([Self.object([
                ("viewModelId", .string("Nested")),
                ("vmInstanceId", .string("dynamic-row")),
                ("String", .string("inline-row")),
            ])])
        )]))

        let root = try await screen.rootViewModel()
        let dynamic = try await screen.viewModel(named: "Nested", instanceID: "dynamic-row")
        let snapshot = try await screen.snapshot()
        guard case .list(let rowIDs) = snapshot.values.first(where: {
            $0.ownerInstanceID == root.rawValue && $0.name == "List"
        })?.value else {
            return XCTFail("Expected dynamic list row")
        }
        XCTAssertEqual(rowIDs.count, 1)
        XCTAssertEqual(
            snapshot.values.first(where: {
                $0.ownerInstanceID == rowIDs[0] && $0.name == "String"
            })?.value,
            .bytes(Data("inline-row".utf8))
        )
        XCTAssertEqual(dynamic.rawValue != 0, true)

        _ = try await screen.applyStateCommand(.list(
            viewModelName: "Test",
            instanceID: "root-sdk-id",
            instanceName: nil,
            path: "List",
            edit: .insert(index: 0, value: Self.object([
                ("viewModelId", .string("Nested")),
                ("vmInstanceId", .string("inserted-row")),
                ("values", Self.object([("String", .string("inserted-value"))])),
            ]))
        ))
        _ = try await screen.applyStateCommand(.list(
            viewModelName: "Test",
            instanceID: "root-sdk-id",
            instanceName: nil,
            path: "List",
            edit: .set(index: 1, value: Self.object([
                ("viewModelId", .string("Nested")),
                ("vmInstanceId", .string("dynamic-row")),
                ("String", .string("set-value")),
            ]))
        ))
        let edited = try await screen.snapshot()
        guard case .list(let editedRowIDs) = edited.values.first(where: {
            $0.ownerInstanceID == root.rawValue && $0.name == "List"
        })?.value else {
            return XCTFail("Expected incrementally edited list")
        }
        XCTAssertEqual(editedRowIDs.count, 2)
        XCTAssertEqual(
            edited.values.first(where: {
                $0.ownerInstanceID == editedRowIDs[0] && $0.name == "String"
            })?.value,
            .bytes(Data("inserted-value".utf8))
        )
        XCTAssertEqual(
            edited.values.first(where: {
                $0.ownerInstanceID == editedRowIDs[1] && $0.name == "String"
            })?.value,
            .bytes(Data("set-value".utf8))
        )
        do {
            _ = try await screen.applyStateCommand(.snapshot([.init(
                viewModelName: "Test",
                instanceID: "root-sdk-id",
                instanceName: nil,
                path: "List",
                value: .list([Self.object([
                    ("viewModelId", .string("Nested")),
                    ("vmInstanceId", .string("conflicting-row")),
                    ("String", .string("inline")),
                    ("values", Self.object([("String", .string("nested"))])),
                ])])
            )]))
            XCTFail("Expected conflicting inline and nested values to fail")
        } catch {
            guard case .stateContract(let reason) = error as? ExperienceInteractiveScreenError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(reason.contains("conflicts on 'String'"))
        }
        do {
            _ = try await screen.viewModel(
                named: "Nested",
                instanceID: "conflicting-row"
            )
            XCTFail("Expected failed allocation to remain uncommitted")
        } catch {}
    }

    func testUnsignedStateConversionRejectsRoundedValueAboveUInt64Max() {
        XCTAssertNil(ExperienceInteractiveScreen.exactUnsignedStateValue(pow(2, 64)))
        XCTAssertEqual(ExperienceInteractiveScreen.exactUnsignedStateValue(42), 42)
    }

    func testSignedAndLiveStateCompilersProduceEquivalentTypedCommands() throws {
        let catalog = Self.stateCompilerCatalog
        let signed = ExperienceInteractiveStateCompiler(
            catalog: catalog,
            imageIDsByName: ["hero": 91],
            policy: .signedPackage
        )
        let live = ExperienceInteractiveStateCompiler(
            catalog: catalog,
            imageIDsByName: ["hero": 91],
            policy: .liveCommand
        )
        let cases: [(String, Any, ExperienceInteractiveValue)] = [
            ("title", "hello", .string("hello")),
            ("amount", NSNumber(value: 1.25), .number(1.25)),
            ("enabled", true, .bool(true)),
            ("tint", 4_294_967_295, .number(4_294_967_295)),
            ("mode", "ready", .string("ready")),
            ("hero", "hero", .string("hero")),
            ("child/title", "nested", .string("nested")),
        ]

        for (path, raw, liveValue) in cases {
            let signedProperty = try signed.property(at: path, startingWith: 0)
            let liveProperty = try live.property(at: path, startingWith: 0)
            XCTAssertEqual(signedProperty, liveProperty, path)
            XCTAssertEqual(
                try signed.scalar(
                    for: signedProperty,
                    value: ExperienceInteractiveStateCompiler.decode(raw),
                    path: path
                ),
                try live.scalar(for: liveProperty, value: liveValue, path: path),
                path
            )
        }
    }

    func testSignedAndLiveStateCompilersNormalizeEquivalentIdentityEnvelopes() throws {
        let signed = ExperienceInteractiveStateCompiler(
            catalog: Self.stateCompilerCatalog,
            policy: .signedPackage
        )
        let live = ExperienceInteractiveStateCompiler(
            catalog: Self.stateCompilerCatalog,
            policy: .liveCommand
        )
        let signedValues = try ExperienceInteractiveStateCompiler.signedValues([
            JourneyViewModelValue(
                viewModelName: "Root",
                instanceId: "root-id",
                path: "child/vmInstanceId",
                value: AnyCodable("child-id")
            ),
            JourneyViewModelValue(
                viewModelName: "Root",
                instanceId: "root-id",
                path: "child/values/title",
                value: AnyCodable("nested")
            ),
        ])
        let liveValues: [ExperienceInteractiveStateCommand.Value] = [
            .init(
                viewModelName: "Root",
                instanceID: "root-id",
                instanceName: nil,
                path: "child/vmInstanceId",
                value: .string("child-id")
            ),
            .init(
                viewModelName: "Root",
                instanceID: "root-id",
                instanceName: nil,
                path: "child/values/title",
                value: .string("nested")
            ),
        ]

        let signedNormalized = try signed.normalizeFlattenedEnvelopes(signedValues)
        let liveNormalized = try live.normalizeFlattenedEnvelopes(liveValues)
        XCTAssertEqual(signedNormalized, liveNormalized)
        XCTAssertEqual(signedNormalized.count, 1)
        XCTAssertEqual(signedNormalized.first?.path, "child")
        XCTAssertEqual(signedNormalized.first?.value["viewModelId"], .string("Child"))
        XCTAssertEqual(signedNormalized.first?.value["vmInstanceId"], .string("child-id"))
        XCTAssertEqual(signedNormalized.first?.value["values"]?["title"], .string("nested"))
    }

    func testSharedStateCompilerRejectsInvalidPathsAndScalarEdgesConsistently() throws {
        for policy in [
            ExperienceInteractiveStateCompiler.Policy.signedPackage,
            .liveCommand,
        ] {
            let compiler = ExperienceInteractiveStateCompiler(
                catalog: Self.stateCompilerCatalog,
                policy: policy
            )
            XCTAssertThrowsError(try compiler.property(at: "child//title", startingWith: 0))
            let tint = try compiler.property(at: "tint", startingWith: 0)
            XCTAssertThrowsError(try compiler.scalar(
                for: tint,
                value: .number(1.5),
                path: "tint"
            ))
            let mode = try compiler.property(at: "mode", startingWith: 0)
            XCTAssertThrowsError(try compiler.scalar(
                for: mode,
                value: .string("missing"),
                path: "mode"
            ))
        }

        let ambiguousCatalog = NuxieNativeViewModelCatalog(
            schemas: Self.stateCompilerCatalog.schemas,
            properties: Self.stateCompilerCatalog.properties + [.init(
                schemaIndex: 0,
                index: 8,
                name: "title",
                kind: .string,
                referencedSchemaIndex: nil,
                enumLabels: []
            )],
            authoredInstances: []
        )
        for policy in [
            ExperienceInteractiveStateCompiler.Policy.signedPackage,
            .liveCommand,
        ] {
            let compiler = ExperienceInteractiveStateCompiler(
                catalog: ambiguousCatalog,
                policy: policy
            )
            XCTAssertThrowsError(try compiler.property(at: "title", startingWith: 0))
        }
    }

    @MainActor
    func testLiveStateDecoderPreservesUnsupportedValueDetail() {
        XCTAssertThrowsError(try ExperienceInteractiveStateCommand.value(
            path: VmPathRef(viewModelName: "Root", path: "title"),
            rawValue: Date(timeIntervalSince1970: 0),
            instanceID: nil,
            defaultViewModelName: nil
        )) { error in
            guard case .invalidValue(let reason) = error as? ExperienceInteractiveStateCommandError
            else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertTrue(reason.contains("Date"), reason)
        }
    }

    private static let stateCompilerCatalog = NuxieNativeViewModelCatalog(
        schemas: [
            .init(
                index: 0,
                name: "Root",
                propertyRange: 0..<7,
                authoredInstanceRange: 0..<0,
                defaultAuthoredInstance: nil,
                isGlobal: false
            ),
            .init(
                index: 1,
                name: "Child",
                propertyRange: 7..<8,
                authoredInstanceRange: 0..<0,
                defaultAuthoredInstance: nil,
                isGlobal: false
            ),
        ],
        properties: [
            .init(
                schemaIndex: 0,
                index: 0,
                name: "title",
                kind: .string,
                referencedSchemaIndex: nil,
                enumLabels: []
            ),
            .init(
                schemaIndex: 0,
                index: 1,
                name: "amount",
                kind: .number,
                referencedSchemaIndex: nil,
                enumLabels: []
            ),
            .init(
                schemaIndex: 0,
                index: 2,
                name: "enabled",
                kind: .bool,
                referencedSchemaIndex: nil,
                enumLabels: []
            ),
            .init(
                schemaIndex: 0,
                index: 3,
                name: "tint",
                kind: .color,
                referencedSchemaIndex: nil,
                enumLabels: []
            ),
            .init(
                schemaIndex: 0,
                index: 4,
                name: "mode",
                kind: .enumeration,
                referencedSchemaIndex: nil,
                enumLabels: ["idle", "ready"]
            ),
            .init(
                schemaIndex: 0,
                index: 5,
                name: "hero",
                kind: .image,
                referencedSchemaIndex: nil,
                enumLabels: []
            ),
            .init(
                schemaIndex: 0,
                index: 6,
                name: "child",
                kind: .viewModel,
                referencedSchemaIndex: 1,
                enumLabels: []
            ),
            .init(
                schemaIndex: 1,
                index: 7,
                name: "title",
                kind: .string,
                referencedSchemaIndex: nil,
                enumLabels: []
            ),
        ],
        authoredInstances: []
    )

    @MainActor
    func testListCommandClampsNegativeInsertIndexToZero() throws {
        let command = try ExperienceInteractiveStateCommand.list(
            operation: .insert,
            path: VmPathRef(viewModelName: "Test", path: "List"),
            payload: [
                "index": -12,
                "value": ["viewModelId": "Nested", "vmInstanceId": "row"],
            ],
            instanceID: "root-sdk-id",
            defaultViewModelName: nil
        )
        guard case .list(_, _, _, _, .insert(let index, _)) = command else {
            return XCTFail("Expected insert command")
        }
        XCTAssertEqual(index, 0)
    }

    func testFractionalColorStateIsRejected() async throws {
        let payload = try await statePayload(
            defaultViewModelName: "Test",
            values: [JourneyViewModelValue(
                viewModelName: "Test",
                instanceId: "root-sdk-id",
                path: "Number",
                value: AnyCodable(1)
            )]
        )
        let screen = try await ExperienceInteractiveScreen.open(
            payload: payload,
            player: .stateMachine("State Machine 1"),
            pixelWidth: 16,
            pixelHeight: 16
        )
        defer { Task { try? await screen.close() } }

        do {
            _ = try await screen.applyStateCommand(.value(.init(
                viewModelName: "Test",
                instanceID: "root-sdk-id",
                instanceName: nil,
                path: "Color",
                value: .number(1.9)
            )))
            XCTFail("Expected fractional color to be rejected")
        } catch {
            guard case .stateContract = error as? ExperienceInteractiveScreenError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testFactoryRejectsConflictingAuthoredSelectorsForOneRemoteIdentity() async throws {
        let payload = try await statePayload(
            defaultViewModelName: "Test",
            values: [
                JourneyViewModelValue(
                    viewModelName: "Nested",
                    instanceId: "nested-sdk-id",
                    instanceName: "Default",
                    path: "String",
                    value: AnyCodable("first")
                ),
                JourneyViewModelValue(
                    viewModelName: "Nested",
                    instanceId: "nested-sdk-id",
                    instanceName: "Another",
                    path: "String",
                    value: AnyCodable("second")
                ),
            ]
        )
        do {
            _ = try await ExperienceInteractiveScreen.open(
                payload: payload,
                player: .stateMachine("State Machine 1"),
                pixelWidth: 16,
                pixelHeight: 16
            )
            XCTFail("Expected conflicting authored selectors to fail")
        } catch {
            guard case .stateContract(let reason) = error as? ExperienceInteractiveScreenError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(reason.contains("conflicting authored instance selectors"))
        }
    }

    func testFactoryRejectsSignedReferenceWithNonObjectValues() async throws {
        let payload = try await statePayload(
            defaultViewModelName: "Test",
            values: [JourneyViewModelValue(
                viewModelName: "Test",
                instanceId: "root-sdk-id",
                path: "List",
                value: AnyCodable([[
                    "vmInstanceId": "row-sdk-id",
                    "viewModelId": "Nested",
                    "values": "not-an-object",
                ]])
            )]
        )
        do {
            _ = try await ExperienceInteractiveScreen.open(
                payload: payload,
                player: .stateMachine("State Machine 1"),
                pixelWidth: 16,
                pixelHeight: 16
            )
            XCTFail("Expected malformed signed row values to fail")
        } catch {
            guard case .stateContract(let reason) = error as? ExperienceInteractiveScreenError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(reason.contains("non-object values"))
        }
    }

    func testListIndexPlannerWritesEveryAuthoredIndexAndIgnoresOtherProperties() throws {
        let reference = try XCTUnwrap(NuxieNativeViewModelReference(rawValue: 7))
        let properties = [
            NuxieNativeViewModelCatalog.Property(
                schemaIndex: 2,
                index: 0,
                name: "position",
                kind: .listIndex,
                referencedSchemaIndex: nil,
                enumLabels: []
            ),
            NuxieNativeViewModelCatalog.Property(
                schemaIndex: 2,
                index: 1,
                name: "label",
                kind: .string,
                referencedSchemaIndex: nil,
                enumLabels: []
            ),
            NuxieNativeViewModelCatalog.Property(
                schemaIndex: 3,
                index: 0,
                name: "otherPosition",
                kind: .listIndex,
                referencedSchemaIndex: nil,
                enumLabels: []
            ),
        ]
        XCTAssertEqual(
            ExperienceInteractiveListIndexPlanner.mutations(
                reference: reference,
                schemaIndex: 2,
                properties: properties,
                index: 4
            ),
            [.setListIndex(instance: reference, path: "position", value: 4)]
        )
    }

    func testTrackedListPlannerReindexesEveryRowAfterEachStructuralMutation() throws {
        let owner = try XCTUnwrap(ExperienceInteractiveViewModelReference(rawValue: 1))
        let first = try XCTUnwrap(ExperienceInteractiveViewModelReference(rawValue: 2))
        let second = try XCTUnwrap(ExperienceInteractiveViewModelReference(rawValue: 3))
        let third = try XCTUnwrap(ExperienceInteractiveViewModelReference(rawValue: 4))
        let identity = ExperienceInteractiveListIdentity(owner: owner, path: "items")
        var planner = ExperienceInteractiveTrackedListPlanner(
            itemsByList: [identity: [first, second, third]]
        )

        let expanded = try planner.expand(
            [
                .listMove(owner, path: "items", from: 0, to: 2),
                .listRemove(owner, path: "items", index: 1),
            ],
            schemaIndexByReference: [first: 7, second: 7, third: 7],
            listIndexPathsBySchema: [7: ["position"]],
            settableReferences: [first, second, third]
        )

        XCTAssertEqual(expanded, [
            .listMove(owner, path: "items", from: 0, to: 2),
            .setListIndex(second, path: "position", value: 0),
            .setListIndex(third, path: "position", value: 1),
            .setListIndex(first, path: "position", value: 2),
            .listRemove(owner, path: "items", index: 1),
            .setListIndex(second, path: "position", value: 0),
            .setListIndex(first, path: "position", value: 1),
        ])
        XCTAssertEqual(planner.itemsByList[identity], [second, first])
    }

    func testTrackedListPlannerStagesClearThenInsertAndRejectsUnknownTopology() throws {
        let owner = try XCTUnwrap(ExperienceInteractiveViewModelReference(rawValue: 1))
        let row = try XCTUnwrap(ExperienceInteractiveViewModelReference(rawValue: 2))
        let identity = ExperienceInteractiveListIdentity(owner: owner, path: "items")
        var planner = ExperienceInteractiveTrackedListPlanner()

        XCTAssertThrowsError(try planner.expand(
            [.listInsert(owner, path: "items", index: 0, value: row)],
            schemaIndexByReference: [row: 7],
            listIndexPathsBySchema: [7: ["position"]],
            settableReferences: [row]
        ))
        let expanded = try planner.expand(
            [
                .listClear(owner, path: "items"),
                .listInsert(owner, path: "items", index: 0, value: row),
            ],
            schemaIndexByReference: [row: 7],
            listIndexPathsBySchema: [7: ["position"]],
            settableReferences: [row]
        )
        XCTAssertEqual(expanded, [
            .listClear(owner, path: "items"),
            .listInsert(owner, path: "items", index: 0, value: row),
            .setListIndex(row, path: "position", value: 0),
        ])
        XCTAssertEqual(planner.itemsByList[identity], [row])
    }

    func testSnapshotTopologySeedsAuthoredListAndReconcilesRuntimeReorder() throws {
        let root = try XCTUnwrap(ExperienceInteractiveViewModelReference(rawValue: 1))
        let identity = ExperienceInteractiveListIdentity(owner: root, path: "items")
        var schemas = [root: 0]
        var topology = ExperienceInteractiveSnapshotTopology()
        var planner = try topology.reconcile(
            snapshot: Self.listSnapshot(items: [2, 3]),
            rootReference: root,
            schemaIndexByReference: &schemas
        )
        let authoredRows = try XCTUnwrap(planner.itemsByList[identity])
        XCTAssertEqual(authoredRows.count, 2)
        XCTAssertEqual(Set(authoredRows).count, 2)

        XCTAssertNoThrow(try planner.expand(
            [.listSwap(root, path: "items", first: 0, second: 1)],
            schemaIndexByReference: schemas,
            listIndexPathsBySchema: [:],
            settableReferences: [root]
        ))

        planner = try topology.reconcile(
            snapshot: Self.listSnapshot(items: [3, 2]),
            rootReference: root,
            schemaIndexByReference: &schemas
        )
        XCTAssertEqual(planner.itemsByList[identity], authoredRows.reversed())
    }

    func testSnapshotTopologyMapsSignedRowsBackToStableSettableReferences() throws {
        let root = try XCTUnwrap(ExperienceInteractiveViewModelReference(rawValue: 1))
        let first = try XCTUnwrap(ExperienceInteractiveViewModelReference(rawValue: 10))
        let second = try XCTUnwrap(ExperienceInteractiveViewModelReference(rawValue: 11))
        let identity = ExperienceInteractiveListIdentity(owner: root, path: "items")
        var schemas = [root: 0, first: 7, second: 7]
        var topology = ExperienceInteractiveSnapshotTopology()
        var planner = try topology.reconcile(
            snapshot: Self.listSnapshot(items: [2, 3]),
            rootReference: root,
            preferredLists: [identity: [first, second]],
            schemaIndexByReference: &schemas
        )
        XCTAssertEqual(planner.itemsByList[identity], [first, second])
        XCTAssertEqual(
            try planner.expand(
                [.listMove(root, path: "items", from: 0, to: 2)],
                schemaIndexByReference: schemas,
                listIndexPathsBySchema: [7: ["position"]],
                settableReferences: [root, first, second]
            ),
            [
                .listMove(root, path: "items", from: 0, to: 1),
                .setListIndex(second, path: "position", value: 0),
                .setListIndex(first, path: "position", value: 1),
            ]
        )
    }

    func testReservedProjectionSuppressesSafeAreaDescendantsButPreservesPublicSibling() {
        let snapshot = NuxieNativeViewModelSnapshot(
            rootInstanceID: 1,
            instances: [
                .init(id: 1, schemaIndex: 0, valueRange: 0..<2),
                .init(id: 2, schemaIndex: 1, valueRange: 2..<3),
                .init(id: 3, schemaIndex: 1, valueRange: 3..<4),
            ],
            values: [
                .init(
                    ownerInstanceID: 1,
                    propertyIndex: 0,
                    name: "safeArea",
                    value: .referencedInstance(2)
                ),
                .init(
                    ownerInstanceID: 1,
                    propertyIndex: 1,
                    name: "content",
                    value: .referencedInstance(3)
                ),
                .init(
                    ownerInstanceID: 2,
                    propertyIndex: 0,
                    name: "top",
                    value: .number(12)
                ),
                .init(
                    ownerInstanceID: 3,
                    propertyIndex: 0,
                    name: "title",
                    value: .bytes(Data("hello".utf8))
                ),
            ]
        )
        var filter = ExperienceInteractiveReservedChangeFilter(
            snapshot: snapshot,
            catalog: Self.reservedChangeCatalog
        )

        XCTAssertTrue(filter.shouldSuppress(Self.change(owner: 2, property: 0, value: .number(20))))
        XCTAssertFalse(filter.shouldSuppress(Self.change(owner: 3, property: 0, value: .bytes(Data()))))
    }

    func testReservedProjectionSuppressesScreenAndEnvironmentDescendants() {
        let snapshot = NuxieNativeViewModelSnapshot(
            rootInstanceID: 1,
            instances: [
                .init(id: 1, schemaIndex: 0, valueRange: 0..<2),
                .init(id: 4, schemaIndex: 1, valueRange: 2..<3),
                .init(id: 5, schemaIndex: 1, valueRange: 3..<4),
            ],
            values: [
                .init(
                    ownerInstanceID: 1,
                    propertyIndex: 3,
                    name: "screen",
                    value: .referencedInstance(4)
                ),
                .init(
                    ownerInstanceID: 1,
                    propertyIndex: 4,
                    name: "env",
                    value: .referencedInstance(5)
                ),
                .init(ownerInstanceID: 4, propertyIndex: 0, name: "phase", value: .unsupported),
                .init(ownerInstanceID: 5, propertyIndex: 0, name: "reduceMotion", value: .bool(false)),
            ]
        )
        var filter = ExperienceInteractiveReservedChangeFilter(
            snapshot: snapshot,
            catalog: Self.reservedChangeCatalog
        )

        XCTAssertTrue(filter.shouldSuppress(Self.change(owner: 4, property: 0, value: .unsupported)))
        XCTAssertTrue(filter.shouldSuppress(Self.change(owner: 5, property: 0, value: .bool(true))))
    }

    func testReservedProjectionSuppressesAdvertisedReplacementSubtree() {
        var filter = ExperienceInteractiveReservedChangeFilter(
            snapshot: NuxieNativeViewModelSnapshot(
                rootInstanceID: 1,
                instances: [.init(id: 1, schemaIndex: 0, valueRange: 0..<1)],
                values: [.init(
                    ownerInstanceID: 1,
                    propertyIndex: 2,
                    name: "nuxieTextInputs",
                    value: .unsupported
                )]
            ),
            catalog: Self.reservedChangeCatalog
        )

        XCTAssertTrue(filter.shouldSuppress(Self.change(
            owner: 1,
            property: 2,
            value: .referencedInstance(10)
        )))
        XCTAssertTrue(filter.shouldSuppress(Self.change(
            owner: 10,
            property: 0,
            value: .list([11])
        )))
        XCTAssertTrue(filter.shouldSuppress(Self.change(
            owner: 11,
            property: 0,
            value: .bytes(Data("private".utf8))
        )))
    }

    func testReservedProjectionSuppressesDetachedPreviousSubtreeInOperationOrder() {
        var filter = ExperienceInteractiveReservedChangeFilter(
            snapshot: NuxieNativeViewModelSnapshot(
                rootInstanceID: 1,
                instances: [
                    .init(id: 1, schemaIndex: 0, valueRange: 0..<1),
                    .init(id: 10, schemaIndex: 1, valueRange: 1..<2),
                ],
                values: [
                    .init(
                        ownerInstanceID: 1,
                        propertyIndex: 2,
                        name: "nuxieTextInputs",
                        value: .referencedInstance(10)
                    ),
                    .init(
                        ownerInstanceID: 10,
                        propertyIndex: 0,
                        name: "value",
                        value: .bytes(Data("old".utf8))
                    ),
                ]
            ),
            catalog: Self.reservedChangeCatalog
        )

        XCTAssertTrue(filter.shouldSuppress(Self.change(
            owner: 10,
            property: 0,
            value: .bytes(Data("changed-before-detach".utf8))
        )))
        XCTAssertTrue(filter.shouldSuppress(Self.change(
            owner: 1,
            property: 2,
            value: .unsupported
        )))
        filter = ExperienceInteractiveReservedChangeFilter(
            snapshot: NuxieNativeViewModelSnapshot(
                rootInstanceID: 1,
                instances: [.init(id: 1, schemaIndex: 0, valueRange: 0..<1)],
                values: [.init(
                    ownerInstanceID: 1,
                    propertyIndex: 2,
                    name: "nuxieTextInputs",
                    value: .unsupported
                )]
            ),
            catalog: Self.reservedChangeCatalog,
            preserving: filter
        )
        XCTAssertTrue(filter.shouldSuppress(Self.change(
            owner: 10,
            property: 0,
            value: .bytes(Data("late-old-publisher".utf8))
        )))
    }

    func testReservedProjectionAllowsCatalogWithoutReservedRoots() {
        let catalog = NuxieNativeViewModelCatalog(
            schemas: [.init(
                index: 0,
                name: "Root",
                propertyRange: 0..<1,
                authoredInstanceRange: 0..<0,
                defaultAuthoredInstance: nil,
                isGlobal: false
            )],
            properties: [.init(
                schemaIndex: 0,
                index: 0,
                name: "content",
                kind: .viewModel,
                referencedSchemaIndex: nil,
                enumLabels: []
            )],
            authoredInstances: []
        )
        var filter = ExperienceInteractiveReservedChangeFilter(
            snapshot: NuxieNativeViewModelSnapshot(
                rootInstanceID: 1,
                instances: [.init(id: 1, schemaIndex: 0, valueRange: 0..<1)],
                values: []
            ),
            catalog: catalog
        )
        XCTAssertFalse(filter.shouldSuppress(Self.change(
            owner: 1,
            property: 0,
            value: .referencedInstance(2)
        )))
    }

    func testJourneyStateCommandsCannotWriteLifecycleReservedNamespaces() {
        let publicValue = ExperienceInteractiveStateCommand.Value(
            viewModelName: "Root",
            instanceID: "root",
            instanceName: nil,
            path: "content/title",
            value: .string("kept")
        )
        let command = ExperienceInteractiveStateCommand.snapshot([
            .init(
                viewModelName: "Root",
                instanceID: "root",
                instanceName: nil,
                path: "screen/phase",
                value: .string("hidden")
            ),
            .init(
                viewModelName: "Root",
                instanceID: "root",
                instanceName: nil,
                path: "env/reduceMotion",
                value: .bool(false)
            ),
            publicValue,
        ])

        XCTAssertEqual(
            command.suppressingLifecycleReservedJourneyWrites(rootViewModelName: "Root", rootInstanceID: "root"),
            .snapshot([publicValue])
        )
        XCTAssertNil(ExperienceInteractiveStateCommand.value(.init(
            viewModelName: "Root",
            instanceID: "root",
            instanceName: nil,
            path: "screen/appearances",
            value: .number(99)
        )).suppressingLifecycleReservedJourneyWrites(rootViewModelName: "Root", rootInstanceID: "root"))
        // A non-root ViewModel may legitimately own screen/env-prefixed
        // paths; reservation applies only to the screen's root model.
        XCTAssertNotNil(ExperienceInteractiveStateCommand.value(.init(
            viewModelName: "Sidebar",
            instanceID: "sidebar",
            instanceName: nil,
            path: "screen/appearances",
            value: .number(99)
        )).suppressingLifecycleReservedJourneyWrites(rootViewModelName: "Root", rootInstanceID: "root"))
        // Without a known root instance id, explicit ids stay writable.
        XCTAssertNotNil(ExperienceInteractiveStateCommand.value(.init(
            viewModelName: "Root",
            instanceID: "explicit",
            instanceName: nil,
            path: "screen/appearances",
            value: .number(99)
        )).suppressingLifecycleReservedJourneyWrites(rootViewModelName: "Root", rootInstanceID: nil))
        // A non-root INSTANCE of the root schema is not reserved either.
        XCTAssertNotNil(ExperienceInteractiveStateCommand.value(.init(
            viewModelName: "Root",
            instanceID: "detail",
            instanceName: nil,
            path: "screen/appearances",
            value: .number(99)
        )).suppressingLifecycleReservedJourneyWrites(rootViewModelName: "Root", rootInstanceID: "root"))
        XCTAssertNil(ExperienceInteractiveStateCommand.value(.init(
            viewModelName: "Root",
            instanceID: "root",
            instanceName: nil,
            path: "env",
            value: .object([
                .init(key: "reduceMotion", value: .bool(false))
            ])
        )).suppressingLifecycleReservedJourneyWrites(rootViewModelName: "Root", rootInstanceID: "root"))
        XCTAssertNil(ExperienceInteractiveStateCommand.trigger(
            viewModelName: "Root",
            instanceID: "root",
            instanceName: nil,
            path: "screen/reset"
        ).suppressingLifecycleReservedJourneyWrites(rootViewModelName: "Root", rootInstanceID: "root"))
        XCTAssertNil(ExperienceInteractiveStateCommand.list(
            viewModelName: "Root",
            instanceID: "root",
            instanceName: nil,
            path: "env/options",
            edit: .clear
        ).suppressingLifecycleReservedJourneyWrites(rootViewModelName: "Root", rootInstanceID: "root"))
        XCTAssertEqual(
            ExperienceInteractiveStateCommand.value(.init(
                viewModelName: "Root",
                instanceID: "root",
                instanceName: nil,
                path: "",
                value: .object([
                    .init(key: "screen", value: .object([])),
                    .init(key: "content", value: .string("kept")),
                ])
            )).suppressingLifecycleReservedJourneyWrites(rootViewModelName: "Root", rootInstanceID: "root"),
            .value(.init(
                viewModelName: "Root",
                instanceID: "root",
                instanceName: nil,
                path: "",
                value: .object([
                    .init(key: "content", value: .string("kept"))
                ])
            ))
        )
    }

    func testSnapshotTopologyPreservesNewlyAttachedViewModelReference() throws {
        let root = try XCTUnwrap(ExperienceInteractiveViewModelReference(rawValue: 1))
        let attached = try XCTUnwrap(ExperienceInteractiveViewModelReference(rawValue: 10))
        let row = try XCTUnwrap(ExperienceInteractiveViewModelReference(rawValue: 11))
        let childIdentity = ExperienceInteractiveViewModelPropertyIdentity(
            owner: root,
            path: "child"
        )
        let listIdentity = ExperienceInteractiveListIdentity(owner: attached, path: "items")
        var schemas = [root: 0, attached: 7, row: 8]
        var topology = ExperienceInteractiveSnapshotTopology()
        let snapshot = NuxieNativeViewModelSnapshot(
            rootInstanceID: 1,
            instances: [
                .init(id: 1, schemaIndex: 0, valueRange: 0..<1),
                .init(id: 2, schemaIndex: 7, valueRange: 1..<2),
                .init(id: 3, schemaIndex: 8, valueRange: 2..<3),
            ],
            values: [
                .init(
                    ownerInstanceID: 1,
                    propertyIndex: 0,
                    name: "child",
                    value: .referencedInstance(2)
                ),
                .init(
                    ownerInstanceID: 2,
                    propertyIndex: 0,
                    name: "items",
                    value: .list([3])
                ),
                .init(
                    ownerInstanceID: 3,
                    propertyIndex: 0,
                    name: "position",
                    value: .integer(0)
                ),
            ]
        )
        let preferences = try ExperienceInteractiveMutationTopologyPreferences(
            mutations: [.setViewModel(root, path: "child", value: attached)],
            snapshot: snapshot,
            topology: topology
        )

        let planner = try topology.reconcile(
            snapshot: snapshot,
            rootReference: root,
            preferredLists: [listIdentity: [row]],
            preferredViewModels: preferences.viewModelsByProperty,
            schemaIndexByReference: &schemas
        )

        XCTAssertEqual(preferences.viewModelsByProperty[childIdentity], attached)
        XCTAssertEqual(topology.reference(forSnapshotID: 2), attached)
        XCTAssertEqual(planner.itemsByList[listIdentity], [row])
    }

    func testSnapshotTopologyCanonicalizesNestedAttachedViewModelReference() throws {
        let root = try XCTUnwrap(ExperienceInteractiveViewModelReference(rawValue: 1))
        let container = try XCTUnwrap(ExperienceInteractiveViewModelReference(rawValue: 10))
        let attached = try XCTUnwrap(ExperienceInteractiveViewModelReference(rawValue: 11))
        let row = try XCTUnwrap(ExperienceInteractiveViewModelReference(rawValue: 12))
        var schemas = [root: 0, container: 7, attached: 8, row: 9]
        var topology = ExperienceInteractiveSnapshotTopology()
        let before = NuxieNativeViewModelSnapshot(
            rootInstanceID: 1,
            instances: [
                .init(id: 1, schemaIndex: 0, valueRange: 0..<1),
                .init(id: 2, schemaIndex: 7, valueRange: 1..<2),
            ],
            values: [
                .init(
                    ownerInstanceID: 1,
                    propertyIndex: 0,
                    name: "child",
                    value: .referencedInstance(2)
                ),
                .init(
                    ownerInstanceID: 2,
                    propertyIndex: 0,
                    name: "label",
                    value: .bytes(Data("before".utf8))
                ),
            ]
        )
        _ = try topology.reconcile(
            snapshot: before,
            rootReference: root,
            preferredViewModels: [
                .init(owner: root, path: "child"): container,
            ],
            schemaIndexByReference: &schemas
        )

        let preferences = try ExperienceInteractiveMutationTopologyPreferences(
            mutations: [
                .setViewModel(root, path: "child/grandchild", value: attached),
            ],
            snapshot: before,
            topology: topology
        )
        let directIdentity = ExperienceInteractiveViewModelPropertyIdentity(
            owner: container,
            path: "grandchild"
        )
        XCTAssertEqual(preferences.viewModelsByProperty[directIdentity], attached)

        let after = NuxieNativeViewModelSnapshot(
            rootInstanceID: 1,
            instances: [
                .init(id: 1, schemaIndex: 0, valueRange: 0..<1),
                .init(id: 2, schemaIndex: 7, valueRange: 1..<2),
                .init(id: 3, schemaIndex: 8, valueRange: 2..<3),
                .init(id: 4, schemaIndex: 9, valueRange: 3..<4),
            ],
            values: [
                .init(
                    ownerInstanceID: 1,
                    propertyIndex: 0,
                    name: "child",
                    value: .referencedInstance(2)
                ),
                .init(
                    ownerInstanceID: 2,
                    propertyIndex: 0,
                    name: "grandchild",
                    value: .referencedInstance(3)
                ),
                .init(
                    ownerInstanceID: 3,
                    propertyIndex: 0,
                    name: "items",
                    value: .list([4])
                ),
                .init(
                    ownerInstanceID: 4,
                    propertyIndex: 0,
                    name: "position",
                    value: .integer(0)
                ),
            ]
        )
        let listIdentity = ExperienceInteractiveListIdentity(owner: attached, path: "items")
        let planner = try topology.reconcile(
            snapshot: after,
            rootReference: root,
            preferredLists: [listIdentity: [row]],
            preferredViewModels: preferences.viewModelsByProperty,
            schemaIndexByReference: &schemas
        )

        XCTAssertEqual(topology.reference(forSnapshotID: 3), attached)
        XCTAssertEqual(planner.itemsByList[listIdentity], [row])
    }

    func testSnapshotTopologyRollsBackEveryMapAfterLateValidationFailure() throws {
        let root = try XCTUnwrap(ExperienceInteractiveViewModelReference(rawValue: 1))
        let stable = try XCTUnwrap(ExperienceInteractiveViewModelReference(rawValue: 10))
        let identity = ExperienceInteractiveListIdentity(owner: root, path: "items")
        var schemas = [root: 0, stable: 7]
        var topology = ExperienceInteractiveSnapshotTopology()
        _ = try topology.reconcile(
            snapshot: Self.listSnapshot(items: [2]),
            rootReference: root,
            preferredLists: [identity: [stable]],
            schemaIndexByReference: &schemas
        )
        let schemasBeforeFailure = schemas

        let invalid = NuxieNativeViewModelSnapshot(
            rootInstanceID: 1,
            instances: [
                .init(id: 1, schemaIndex: 0, valueRange: 0..<1),
                .init(id: 2, schemaIndex: 7, valueRange: 1..<2),
            ],
            values: [
                .init(
                    ownerInstanceID: 1,
                    propertyIndex: 0,
                    name: "items",
                    value: .list([2, 99])
                ),
                .init(
                    ownerInstanceID: 2,
                    propertyIndex: 0,
                    name: "position",
                    value: .integer(0)
                ),
            ]
        )
        XCTAssertThrowsError(try topology.reconcile(
            snapshot: invalid,
            rootReference: root,
            schemaIndexByReference: &schemas
        ))
        XCTAssertEqual(schemas, schemasBeforeFailure)

        let recovered = try topology.reconcile(
            snapshot: Self.listSnapshot(items: [2]),
            rootReference: root,
            schemaIndexByReference: &schemas
        )
        XCTAssertEqual(recovered.itemsByList[identity], [stable])
    }

    func testSnapshotTopologyPrunesSyntheticSchemasAfterRowsDisappear() throws {
        let root = try XCTUnwrap(ExperienceInteractiveViewModelReference(rawValue: 1))
        let identity = ExperienceInteractiveListIdentity(owner: root, path: "items")
        var schemas = [root: 0]
        var topology = ExperienceInteractiveSnapshotTopology()

        let populated = try topology.reconcile(
            snapshot: Self.listSnapshot(items: [2]),
            rootReference: root,
            preservingReferences: [root],
            schemaIndexByReference: &schemas
        )
        let synthetic = try XCTUnwrap(populated.itemsByList[identity]?.first)
        XCTAssertEqual(schemas[synthetic], 7)

        _ = try topology.reconcile(
            snapshot: Self.listSnapshot(items: []),
            rootReference: root,
            preservingReferences: [root],
            schemaIndexByReference: &schemas
        )

        XCTAssertNil(schemas[synthetic])
        XCTAssertEqual(schemas, [root: 0])
    }

    func testMaterializationCloneScopeExcludesUnrelatedRootSubgraphs() throws {
        let snapshot = NuxieNativeViewModelSnapshot(
            rootInstanceID: 1,
            instances: [
                .init(id: 1, schemaIndex: 0, valueRange: 0..<2),
                .init(id: 2, schemaIndex: 7, valueRange: 2..<3),
                .init(id: 3, schemaIndex: 8, valueRange: 3..<5),
            ],
            values: [
                .init(ownerInstanceID: 1, propertyIndex: 0, name: "items", value: .list([2])),
                .init(
                    ownerInstanceID: 1,
                    propertyIndex: 1,
                    name: "unrelated",
                    value: .referencedInstance(3)
                ),
                .init(ownerInstanceID: 2, propertyIndex: 0, name: "position", value: .integer(0)),
                .init(ownerInstanceID: 3, propertyIndex: 0, name: "font", value: .integer(4)),
                .init(
                    ownerInstanceID: 3,
                    propertyIndex: 1,
                    name: "cycle",
                    value: .referencedInstance(3)
                ),
            ]
        )

        XCTAssertEqual(
            try ExperienceInteractiveSnapshotCloneScope.snapshotIDs(
                containing: [2],
                snapshot: snapshot,
                stoppingAt: [1]
            ),
            [2]
        )
    }

    func testRealScreenListMoveUsesNativeFinalIndexSemantics() async throws {
        let rows = (0..<3).map { index in
            [
                "vmInstanceId": "row-\(index)",
                "viewModelId": "Nested",
                "values": ["String": "row-\(index)"],
            ]
        }
        let payload = try await statePayload(
            defaultViewModelName: "Test",
            values: [JourneyViewModelValue(
                viewModelName: "Test",
                instanceId: "root-sdk-id",
                path: "List",
                value: AnyCodable(rows)
            )]
        )
        let screen = try await ExperienceInteractiveScreen.open(
            payload: payload,
            player: .stateMachine("State Machine 1"),
            pixelWidth: 16,
            pixelHeight: 16
        )
        defer { Task { try? await screen.close() } }
        let root = try await screen.rootViewModel()

        _ = try await screen.mutateState(
            [.listMove(root, path: "List", from: 0, to: rows.count)],
            correlationID: 120
        )
        let snapshot = try await screen.snapshot()
        guard case .list(let rowIDs) = snapshot.values.first(where: {
            $0.ownerInstanceID == root.rawValue && $0.name == "List"
        })?.value else { return XCTFail("Expected moved list") }
        let strings = rowIDs.map { rowID in
            snapshot.values.first(where: {
                $0.ownerInstanceID == rowID && $0.name == "String"
            })?.value
        }
        XCTAssertEqual(strings, [
            .bytes(Data("row-1".utf8)),
            .bytes(Data("row-2".utf8)),
            .bytes(Data("row-0".utf8)),
        ])
    }

    func testImageIdentityMapRejectsOneLookupKeyForDifferentAuthoredAssets() throws {
        let digest = String(repeating: "a", count: 64)
        let images = [
            NativeExperienceImageAsset(
                location: .external(key: "shared-key"),
                riveAssetId: 1,
                riveUniqueName: "first",
                sha256: digest,
                sizeBytes: 1,
                contentType: "image/png",
                required: true
            ),
            NativeExperienceImageAsset(
                location: .external(key: "shared-key"),
                riveAssetId: 2,
                riveUniqueName: "second",
                sha256: digest,
                sizeBytes: 1,
                contentType: "image/png",
                required: true
            ),
        ]
        XCTAssertThrowsError(try ExperienceInteractiveImageIdentityMap.make(images: images)) {
            guard case .stateContract(let reason) = $0 as? ExperienceInteractiveScreenError else {
                return XCTFail("Unexpected error: \($0)")
            }
            XCTAssertTrue(reason.contains("maps to multiple authored assets"))
        }
    }

    func testFactoryRejectsSignedViewModelNameThatDoesNotMatchAuthoredRoot() async throws {
        let payload = try await statePayload(defaultViewModelName: "Wrong")
        do {
            _ = try await ExperienceInteractiveScreen.open(
                payload: payload,
                player: .stateMachine("State Machine 1"),
                pixelWidth: 16,
                pixelHeight: 16
            )
            XCTFail("Expected the signed schema mismatch to fail")
        } catch {
            guard case .stateContract(let reason) = error as? ExperienceInteractiveScreenError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(reason.contains("does not match"))
        }
    }

    func testScreenWithoutDefaultMutatesDetachedViewModel() async throws {
        let payload = try await statePayload(defaultViewModelName: nil)
        let inspection = try await NuxieNativeRuntime.open(
            bytes: payload.sceneBytes,
            artboardName: "Artboard",
            player: .stateMachine("State Machine 1"),
            pixelWidth: 16,
            pixelHeight: 16
        )
        let catalog = try await inspection.viewModelCatalog()
        let parentSchema = try XCTUnwrap(catalog.schemas.first { $0.name == "Test" })
        let nestedProperty = try XCTUnwrap(catalog.properties.first {
            $0.schemaIndex == parentSchema.index && $0.name == "Nested"
        })
        let childSchemaIndex = try XCTUnwrap(nestedProperty.referencedSchemaIndex)
        try await inspection.close()
        let screen = try await ExperienceInteractiveScreen.open(
            payload: payload,
            player: .stateMachine("State Machine 1"),
            pixelWidth: 16,
            pixelHeight: 16
        )
        defer { Task { try? await screen.close() } }
        let detached = try await screen.makeViewModel(schemaIndex: childSchemaIndex)

        let result = try await screen.mutateState(
            [.setString(detached, path: "String", value: Data("detached".utf8))],
            correlationID: 121
        )

        XCTAssertEqual(result.appliedCount, 1)
        XCTAssertEqual(result.correlationID, 121)
        XCTAssertEqual(result.effects.count, 1)

        let detachedParent = try await screen.makeViewModel(schemaIndex: parentSchema.index)
        let attachment = try await screen.mutateState(
            [.setViewModel(detachedParent, path: "Nested", value: detached)],
            correlationID: 122
        )
        XCTAssertEqual(attachment.appliedCount, 1)
        XCTAssertEqual(attachment.correlationID, 122)
        XCTAssertEqual(attachment.effects.count, 1)
    }

    func testOperationGateRetainsCompletionOrderAcrossSuspension() async throws {
        let gate = ExperienceInteractiveOperationGate()
        let latch = InteractiveOperationLatch()
        let first = Task {
            await gate.withLock {
                await latch.enterFirst()
                await latch.waitForRelease()
                return 1
            }
        }
        await latch.waitForFirstEntry()
        let second = Task {
            await gate.withLock {
                await latch.enterSecond()
                return 2
            }
        }
        for _ in 0..<20 { await Task.yield() }
        let enteredBeforeRelease = await latch.didEnterSecond
        XCTAssertFalse(enteredBeforeRelease)
        await latch.releaseFirst()
        let firstValue = await first.value
        let secondValue = await second.value
        let entries = await latch.entries
        XCTAssertEqual(firstValue, 1)
        XCTAssertEqual(secondValue, 2)
        XCTAssertEqual(entries, ["first", "second"])
    }

    func testRouterPreservesPhaseAndCommandOrderWithExactCorrelations() {
        var router = ExperienceInteractiveEffectRouter()
        let reported = ExperienceInteractiveReportedEvent(
            localIndex: 0,
            coreType: 128,
            name: "opened",
            url: "",
            target: "",
            delay: 0,
            properties: []
        )
        let stateChange = ExperienceInteractiveStateChange(
            layerIndex: 1,
            coreType: 7,
            globalID: 9
        )
        let change = ExperienceInteractiveViewModelChange(
            origin: .runtime,
            correlationID: 77,
            ownerInstanceID: 4,
            propertyIndex: 2,
            value: .number(5)
        )
        let effects = router.project(
            reportedEvents: [reported],
            stateChanges: [stateChange],
            viewModelChanges: [change],
            hostCommands: scriptedCommands,
            declaredEventNames: ["purchase_tapped", "selection_changed"],
            validScreenIDs: ["screen_1", "screen_2"],
            correlationID: 42
        )

        XCTAssertEqual(effects.map(\.sequence), Array(0...7))
        XCTAssertEqual(effects.map(\.correlationID), [42, 42, 77, 42, 42, 42, 42, 42])
        XCTAssertEqual(
            effects.map(\.kind),
            [
                .reportedEvent(reported),
                .stateChange(stateChange),
                .viewModelChange(change),
                .responseSet(field: "plan", value: .string("pro")),
                .journeyEvent(name: "purchase_tapped", payload: Self.object([
                    ("placementIndex", .number(2)),
                    ("productId", .string("pro_annual")),
                ])),
                .journeyEvent(name: "selection_changed", payload: Self.object([
                    ("value", .string("annual"))
                ])),
                .hostCommand(name: "custom.analytics", payload: Self.object([
                    ("channel", .string("editor")),
                    ("sampled", .bool(true)),
                ])),
                .rejectedHostCommand(
                    name: "$response_set",
                    reason: "expected a non-empty string field and a value"
                ),
            ]
        )

        let next = router.project(
            reportedEvents: [],
            viewModelChanges: [],
            hostCommands: [ExperienceInteractiveHostCommand(
                name: "$navigate",
                payload: Self.object([
                    ("screenId", .string("screen_2")),
                    ("transition", Self.object([("type", .string("push"))])),
                ])
            )],
            declaredEventNames: [],
            validScreenIDs: ["screen_1", "screen_2"],
            correlationID: 100
        )
        XCTAssertEqual(next, [ExperienceInteractiveEffect(
            sequence: 8,
            correlationID: 100,
            kind: .navigate(
                screenID: "screen_2",
                transition: Self.object([("type", .string("push"))])
            )
        )])
    }

    func testMalformedNavigationIsAProductRejectionAndDoesNotDropItsSiblings() {
        var router = ExperienceInteractiveEffectRouter()
        let effects = router.project(
            reportedEvents: [],
            viewModelChanges: [],
            hostCommands: [
                ExperienceInteractiveHostCommand(
                    name: "$navigate",
                    payload: Self.object([("screenId", .string("unsigned-screen"))])
                ),
                ExperienceInteractiveHostCommand(
                    name: "custom.after",
                    payload: .null
                ),
            ],
            declaredEventNames: [],
            validScreenIDs: ["screen_1"],
            correlationID: 9
        )

        XCTAssertEqual(effects, [
            ExperienceInteractiveEffect(
                sequence: 0,
                correlationID: 9,
                kind: .rejectedHostCommand(
                    name: "$navigate",
                    reason: "expected a declared screenId"
                )
            ),
            ExperienceInteractiveEffect(
                sequence: 1,
                correlationID: 9,
                kind: .hostCommand(name: "custom.after", payload: .null)
            ),
        ])
    }

    private var scriptedCommands: [ExperienceInteractiveHostCommand] {
        [
            ExperienceInteractiveHostCommand(
                name: "$response_set",
                payload: Self.object([
                    ("field", .string("plan")),
                    ("value", .string("pro")),
                ])
            ),
            ExperienceInteractiveHostCommand(
                name: "purchase_tapped",
                payload: Self.object([
                    ("placementIndex", .number(2)),
                    ("productId", .string("pro_annual")),
                ])
            ),
            ExperienceInteractiveHostCommand(
                name: "selection_changed",
                payload: Self.object([("value", .string("annual"))])
            ),
            ExperienceInteractiveHostCommand(
                name: "custom.analytics",
                payload: Self.object([
                    ("channel", .string("editor")),
                    ("sampled", .bool(true)),
                ])
            ),
            ExperienceInteractiveHostCommand(
                name: "$response_set",
                payload: Self.object([
                    ("field", .number(42)),
                    ("value", .string("rejected-in-swift")),
                ])
            ),
        ]
    }

    private static func listSnapshot(items: [UInt64]) -> NuxieNativeViewModelSnapshot {
        let instances = [
            NuxieNativeViewModelSnapshot.Instance(id: 1, schemaIndex: 0, valueRange: 0..<1)
        ] + items.enumerated().map { offset, id in
            NuxieNativeViewModelSnapshot.Instance(
                id: id,
                schemaIndex: 7,
                valueRange: (offset + 1)..<(offset + 2)
            )
        }
        let values = [NuxieNativeViewModelSnapshot.Value(
            ownerInstanceID: 1,
            propertyIndex: 0,
            name: "items",
            value: .list(items)
        )] + items.enumerated().map { offset, id in
            NuxieNativeViewModelSnapshot.Value(
                ownerInstanceID: id,
                propertyIndex: 0,
                name: "position",
                value: .integer(UInt64(offset))
            )
        }
        return NuxieNativeViewModelSnapshot(
            rootInstanceID: 1,
            instances: instances,
            values: values
        )
    }

    private static let reservedChangeCatalog = NuxieNativeViewModelCatalog(
        schemas: [
            .init(
                index: 0,
                name: "Root",
                propertyRange: 0..<5,
                authoredInstanceRange: 0..<0,
                defaultAuthoredInstance: nil,
                isGlobal: false
            ),
            .init(
                index: 1,
                name: "Child",
                propertyRange: 5..<6,
                authoredInstanceRange: 0..<0,
                defaultAuthoredInstance: nil,
                isGlobal: false
            ),
        ],
        properties: [
            .init(
                schemaIndex: 0,
                index: 0,
                name: "safeArea",
                kind: .viewModel,
                referencedSchemaIndex: 1,
                enumLabels: []
            ),
            .init(
                schemaIndex: 0,
                index: 1,
                name: "content",
                kind: .viewModel,
                referencedSchemaIndex: 1,
                enumLabels: []
            ),
            .init(
                schemaIndex: 0,
                index: 2,
                name: "nuxieTextInputs",
                kind: .viewModel,
                referencedSchemaIndex: 1,
                enumLabels: []
            ),
            .init(
                schemaIndex: 0,
                index: 3,
                name: "screen",
                kind: .viewModel,
                referencedSchemaIndex: 1,
                enumLabels: []
            ),
            .init(
                schemaIndex: 0,
                index: 4,
                name: "env",
                kind: .viewModel,
                referencedSchemaIndex: 1,
                enumLabels: []
            ),
            .init(
                schemaIndex: 1,
                index: 0,
                name: "value",
                kind: .string,
                referencedSchemaIndex: nil,
                enumLabels: []
            ),
        ],
        authoredInstances: []
    )

    private static func change(
        owner: UInt64,
        property: Int,
        value: ExperienceInteractiveViewModelValue
    ) -> ExperienceInteractiveViewModelChange {
        ExperienceInteractiveViewModelChange(
            origin: .runtime,
            correlationID: 0,
            ownerInstanceID: owner,
            propertyIndex: property,
            value: value
        )
    }

    private static func object(
        _ fields: [(String, ExperienceInteractiveValue)]
    ) -> ExperienceInteractiveValue {
        .object(fields.map { ExperienceInteractiveField(key: $0.0, value: $0.1) })
    }

    private func authenticatedScriptedPayload() async throws
        -> AuthenticatedRuntimePayload
    {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/scripted-generic-commands", isDirectory: true)
        return try descriptorNativePayload(in: directory, assetRoot: directory)
    }

    private func authenticatedFixturePayload(named name: String) async throws
        -> AuthenticatedRuntimePayload
    {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ExperienceRuntimeHostApp/Fixtures", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        let profile = try JSONDecoder().decode(
            ExperienceReleaseProfileV1.self,
            from: Data(contentsOf: fixture.appendingPathComponent("profile.json"))
        )
        let host = try XCTUnwrap(URL(string: profile.delivery.renderBaseUrl)?.host)
        StubURLProtocol.register(matcher: { $0.url?.host == host }) { request in
            let file = fixture.appendingPathComponent(String(request.url!.path.dropFirst()))
            let bytes = try Data(contentsOf: file)
            let contentType: String
            switch file.pathExtension {
            case "riv": contentType = "application/vnd.rive"
            case "png": contentType = "image/png"
            case "ttf": contentType = "font/ttf"
            default: contentType = "application/octet-stream"
            }
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Type": contentType,
                        "Content-Length": String(bytes.count),
                    ]
                )!,
                bytes
            )
        }
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(
            "authenticated-fixture-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: cache,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: cache) }
        let store = ExperienceReleaseAcquisitionStore(
            cacheDirectory: cache,
            urlSession: TestURLSessionProvider.createTestSession(),
            authorizationKeys: try ExperienceTrustRoots.keys(for: .development),
            supportedCompatibility: ExperienceReleaseRuntimeCompatibility.current,
            admission: ExperienceReleaseAdmission(store: InMemoryExperienceReleaseHighWaterStore())
        )
        let catalog = try await store.authenticateProfile(profile)
        let definition = try XCTUnwrap(catalog.definitions.first)
        let screenID = try XCTUnwrap(definition.journey.screens.first?.id)
        return try await store.acquire(
            definition: definition,
            initialScreenID: screenID
        ).payload
    }

    private struct RuntimePlanFixture: Decodable {
        struct Identity: Decodable {
            let experienceId: String
            let buildId: String
            let appId: String
            let environment: String
        }
        struct Entry: Decodable { let screenId: String }
        struct Screen: Decodable {
            let screenId: String
            let artboardId: String
            let artboardName: String
            let width: Double
            let height: Double
        }
        struct Location: Decodable {
            let kind: String
            let key: String?
            let member: String?

            var path: String {
                get throws {
                    if kind == "external", let key { return key }
                    if kind == "embedded", let member { return member }
                    throw CocoaError(.fileReadCorruptFile)
                }
            }
        }
        struct Image: Decodable {
            let location: Location
            let riveAssetId: UInt64
            let riveUniqueName: String
            let sha256: String
            let sizeBytes: Int
            let contentType: String
            let required: Bool
        }
        struct Font: Decodable {
            let location: Location
            let riveAssetId: UInt64
            let riveUniqueName: String
            let family: String
            let weight: String
            let style: String
            let sha256: String
            let sizeBytes: Int
            let contentType: String
            let format: String
            let required: Bool
        }
        struct Assets: Decodable {
            let images: [Image]
            let fonts: [Font]
        }

        let identity: Identity
        let entry: Entry
        let screens: [Screen]
        let assets: Assets
    }

    private func descriptorNativePayload(
        in directory: URL,
        assetRoot: URL
    ) throws -> AuthenticatedRuntimePayload {
        let plan = try JSONDecoder().decode(
            RuntimePlanFixture.self,
            from: Data(contentsOf: directory.appendingPathComponent("runtime-plan.json"))
        )
        let scene = try Data(contentsOf: directory.appendingPathComponent("scene.riv"))
        let journey = try JSONDecoder().decode(
            JourneyDocument.self,
            from: Data(contentsOf: directory.appendingPathComponent("journey.json"))
        )
        let images = try plan.assets.images.map { image in
            NativeExperienceImageAsset(
                location: image.location.kind == "external"
                    ? .external(key: try image.location.path)
                    : .embedded(member: try image.location.path),
                riveAssetId: image.riveAssetId,
                riveUniqueName: image.riveUniqueName,
                sha256: image.sha256,
                sizeBytes: image.sizeBytes,
                contentType: image.contentType,
                required: image.required
            )
        }
        let fonts = try plan.assets.fonts.map { font in
            NativeExperienceFontAsset(
                location: font.location.kind == "external"
                    ? .external(key: try font.location.path)
                    : .embedded(member: try font.location.path),
                riveAssetId: font.riveAssetId,
                riveUniqueName: font.riveUniqueName,
                family: font.family,
                weight: font.weight,
                style: font.style,
                sha256: font.sha256,
                sizeBytes: font.sizeBytes,
                contentType: font.contentType,
                format: font.format,
                required: font.required
            )
        }
        func bytes(for path: String) throws -> Data {
            try Data(contentsOf: assetRoot.appendingPathComponent(path))
        }
        let runtimeAssets = try plan.assets.images.map { image in
            AuthenticatedRuntimeAsset(
                kind: .image,
                riveAssetID: try XCTUnwrap(UInt32(exactly: image.riveAssetId)),
                riveUniqueName: image.riveUniqueName,
                sourceKey: try image.location.path,
                contentType: image.contentType,
                sha256: image.sha256,
                required: image.required,
                bytes: try bytes(for: image.location.path)
            )
        } + plan.assets.fonts.map { font in
            AuthenticatedRuntimeAsset(
                kind: .font,
                riveAssetID: try XCTUnwrap(UInt32(exactly: font.riveAssetId)),
                riveUniqueName: font.riveUniqueName,
                sourceKey: try font.location.path,
                contentType: font.contentType,
                sha256: font.sha256,
                required: font.required,
                bytes: try bytes(for: font.location.path)
            )
        }
        return AuthenticatedRuntimePayload(
            authenticatedKeyID: "TEST_ONLY_DEV_KEYPAIR",
            renderPlan: NativeExperienceRenderPlan(
                identity: .init(
                    experienceId: plan.identity.experienceId,
                    buildId: plan.identity.buildId,
                    appId: plan.identity.appId,
                    environment: plan.identity.environment
                ),
                scene: .init(
                    key: "scene.riv",
                    sha256: SHA256Provider.hexDigest(scene),
                    sizeBytes: scene.count
                ),
                entry: .init(screenId: plan.entry.screenId),
                screens: plan.screens.map {
                    NativeExperienceScreen(
                        screenId: $0.screenId,
                        artboardId: $0.artboardId,
                        artboardName: $0.artboardName,
                        width: $0.width,
                        height: $0.height,
                        exit: nil
                    )
                },
                transitions: [],
                textInputs: [],
                images: images,
                fonts: fonts
            ),
            journey: journey,
            sceneBytes: scene,
            assets: runtimeAssets
        )
    }

    private func exerciseExternalAssetFixture(named name: String) async throws {
        let payload = try await authenticatedFixturePayload(named: name)
        XCTAssertTrue(payload.assets.contains { asset in
            asset.bytes != nil && asset.sourceKey.hasPrefix("assets/sha256/")
        })
        let screen = try await ExperienceInteractiveScreen.open(
            payload: payload,
            pixelWidth: 64,
            pixelHeight: 64
        )
        defer { Task { try? await screen.close() } }
        for _ in 0..<2 {
            _ = try await renderAndWait(screen)
            let detached = try await screen.detachRenderer()
            XCTAssertEqual(detached.health, .healthy)
            let reattached = try await screen.reattachRenderer(
                pixelWidth: 64,
                pixelHeight: 64
            )
            XCTAssertEqual(reattached.disposition, .recreated)
            try await screen.resetPlayerRendererDomain()
        }
        _ = try await renderAndWait(screen)
        try await screen.close()
    }

    private func statePayload(
        defaultViewModelName: String?,
        values: [JourneyViewModelValue]? = nil,
        scene suppliedScene: Data? = nil,
        artboardName: String = "Artboard"
    ) async throws -> AuthenticatedRuntimePayload {
        let scene = try suppliedScene ?? fixture(named: "data_binding_test", extension: "riv")
        let catalog = try await NuxieNativeRuntime.inspectAssets(bytes: scene)
        var images: [NativeExperienceImageAsset] = []
        var fonts: [NativeExperienceFontAsset] = []
        var assetMembers: [(String, Data)] = []
        for descriptor in catalog where descriptor.kind == .image || descriptor.kind == .font {
            guard descriptor.isEmbedded, let authoredID = descriptor.authoredID else {
                throw XCTSkip("State fixture requires only embedded identified assets")
            }
            let uniqueName = "\(descriptor.name)-\(authoredID)"
            let assetBytes = Data("asset-\(descriptor.ordinal)".utf8)
            let assetHash = SHA256Provider.hexDigest(assetBytes)
            let fileExtension = descriptor.kind == .image ? "png" : "ttf"
            let member = "assets/sha256/\(assetHash).\(fileExtension)"
            assetMembers.append((member, assetBytes))
            if descriptor.kind == .image {
                images.append(NativeExperienceImageAsset(
                    location: .embedded(member: member),
                    riveAssetId: UInt64(authoredID),
                    riveUniqueName: uniqueName,
                    sha256: assetHash,
                    sizeBytes: assetBytes.count,
                    contentType: "image/png",
                    required: true
                ))
            } else {
                fonts.append(NativeExperienceFontAsset(
                    location: .embedded(member: member),
                    riveAssetId: UInt64(authoredID),
                    riveUniqueName: uniqueName,
                    family: "Inter",
                    weight: "400",
                    style: "normal",
                    sha256: assetHash,
                    sizeBytes: assetBytes.count,
                    contentType: "font/ttf",
                    format: "ttf",
                    required: true
                ))
            }
        }
        let defaultValues: [JourneyViewModelValue]
        if let defaultViewModelName {
            defaultValues = [
                JourneyViewModelValue(
                    viewModelName: defaultViewModelName,
                    instanceId: "root-sdk-id",
                    path: "Number",
                    value: AnyCodable(23)
                ),
                JourneyViewModelValue(
                    viewModelName: defaultViewModelName,
                    instanceId: "root-sdk-id",
                    path: "Boolean",
                    value: AnyCodable(true)
                ),
                JourneyViewModelValue(
                    viewModelName: defaultViewModelName,
                    instanceId: "root-sdk-id",
                    path: "String",
                    value: AnyCodable("signed-state")
                ),
            ]
        } else {
            defaultValues = []
        }
        let journey = JourneyDocument(
            screens: [JourneyScreen(
                id: "state-screen",
                defaultViewModelName: defaultViewModelName,
                defaultInstanceId: defaultViewModelName == nil ? nil : "root-sdk-id"
            )],
            viewModelValues: values ?? defaultValues
        )
        let sceneHash = SHA256Provider.hexDigest(scene)
        let bytesByPath = Dictionary(uniqueKeysWithValues: assetMembers)
        let runtimeAssets = try images.map { image in
            AuthenticatedRuntimeAsset(
                kind: .image,
                riveAssetID: try XCTUnwrap(UInt32(exactly: image.riveAssetId)),
                riveUniqueName: image.riveUniqueName,
                sourceKey: image.location.contentAddressedPath,
                contentType: image.contentType,
                sha256: image.sha256,
                required: image.required,
                bytes: bytesByPath[image.location.contentAddressedPath]
            )
        } + fonts.map { font in
            AuthenticatedRuntimeAsset(
                kind: .font,
                riveAssetID: try XCTUnwrap(UInt32(exactly: font.riveAssetId)),
                riveUniqueName: font.riveUniqueName,
                sourceKey: font.location.contentAddressedPath,
                contentType: font.contentType,
                sha256: font.sha256,
                required: font.required,
                bytes: bytesByPath[font.location.contentAddressedPath]
            )
        }
        return AuthenticatedRuntimePayload(
            authenticatedKeyID: "TEST_ONLY_DEV_KEYPAIR",
            renderPlan: NativeExperienceRenderPlan(
                identity: .init(
                    experienceId: "state-experience",
                    buildId: "state-build",
                    appId: "test-app",
                    environment: "test"
                ),
                scene: .init(key: "scene.riv", sha256: sceneHash, sizeBytes: scene.count),
                entry: .init(screenId: "state-screen"),
                screens: [NativeExperienceScreen(
                    screenId: "state-screen",
                    artboardId: artboardName,
                    artboardName: artboardName,
                    width: 100,
                    height: 100,
                    exit: nil
                )],
                transitions: [],
                textInputs: [],
                images: images,
                fonts: fonts
            ),
            journey: journey,
            sceneBytes: scene,
            assets: runtimeAssets
        )
    }

    private func makeJourneyRunner(
        document: JourneyDocument
    ) throws -> (runner: JourneyRunner, journey: Journey) {
        let mocks = MockFactory.shared
        let base = Experience(
            id: "interactive-experience",
            versionId: "interactive-build",
            name: "Interactive",
            reentry: .oneTime,
            publishedAt: "2026-08-08T00:00:00Z",
            trigger: nil,
            goal: nil,
            exitPolicy: nil,
            conversionAnchor: nil,
            experienceType: nil,
            journey: document
        )
        var initialState = JourneySnapshot(
            experience: base,
            distinctId: "interactive-user",
            now: Date()
        )
        initialState.executionState.currentScreenId = "screen_1"
        let journey = Journey(snapshot: initialState)
        let runtime = IRRuntime(dateProvider: mocks.dateProvider)
        let features = FeatureService(
            api: mocks.nuxieApi,
            identity: mocks.identityService,
            profile: mocks.profileService,
            dateProvider: mocks.dateProvider,
            featureInfo: FeatureInfo(),
            cacheTTL: 5 * 60
        )
        runtime.wire(
            identity: mocks.identityService,
            eventLog: mocks.eventLog,
            segments: mocks.segmentService,
            features: features
        )
        return (
            JourneyRunner(
                journey: journey,
                initialState: initialState,
                experience: base,
                eventLog: mocks.eventLog,
                identity: mocks.identityService,
                segments: mocks.segmentService,
                features: features,
                profile: mocks.profileService,
                apiClient: mocks.nuxieApi,
                dateProvider: mocks.dateProvider,
                irRuntime: runtime,
                persistEntryActionClaim: { _ in true }
            ),
            journey
        )
    }

    private static func eventProperties(
        _ value: ExperienceInteractiveValue
    ) throws -> [String: Any] {
        guard case .object(let fields) = value else {
            throw CocoaError(.coderInvalidValue)
        }
        return Dictionary(uniqueKeysWithValues: try fields.map {
            ($0.key, try eventValue($0.value))
        })
    }

    private static func eventValue(_ value: ExperienceInteractiveValue) throws -> Any {
        switch value {
        case .null: NSNull()
        case .bool(let value): value
        case .number(let value): value
        case .string(let value): value
        case .bytes(let value): value
        case .list(let values): try values.map(eventValue)
        case .object(let fields): Dictionary(uniqueKeysWithValues: try fields.map {
            ($0.key, try eventValue($0.value))
        })
        }
    }

    private func render(_ screen: ExperienceInteractiveScreen) async throws
        -> ExperienceInteractiveRenderOutcome
    {
        let device = try await screen.metalDevice()
        let layer = CAMetalLayer()
        layer.device = device.value
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.drawableSize = CGSize(width: 64, height: 64)
        layer.maximumDrawableCount = 2
        layer.allowsNextDrawableTimeout = true
        guard let drawable = layer.nextDrawable() else {
            throw XCTSkip("This host cannot vend a CAMetalDrawable")
        }
        return try await screen.render(
            drawable: ExperienceInteractiveDrawable(drawable),
            clearColor: 0xFF11_2233
        )
    }

    private func renderAndWait(_ screen: ExperienceInteractiveScreen) async throws
        -> ExperienceInteractiveRenderOutcome
    {
        let device = try await screen.metalDevice()
        let layer = CAMetalLayer()
        layer.device = device.value
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.drawableSize = CGSize(width: 64, height: 64)
        layer.maximumDrawableCount = 2
        layer.allowsNextDrawableTimeout = true
        guard let drawable = layer.nextDrawable() else {
            throw XCTSkip("This host cannot vend a CAMetalDrawable")
        }
        let completion = expectation(description: "native frame completion")
        let outcome = try await screen.render(
            drawable: ExperienceInteractiveDrawable(drawable),
            clearColor: 0xFF11_2233,
            completion: { completion.fulfill() }
        )
        await fulfillment(of: [completion], timeout: 2)
        return outcome
    }

    private func fixture(named name: String, extension fileExtension: String) throws -> Data {
        let testBundle = Bundle(for: Self.self)
        if let url = testBundle.url(forResource: name, withExtension: fileExtension) {
            return try Data(contentsOf: url)
        }
        let siblings = try FileManager.default.contentsOfDirectory(
            at: testBundle.bundleURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )
        for sibling in siblings where sibling.pathExtension == "bundle" {
            if let url = Bundle(url: sibling)?.url(
                forResource: name,
                withExtension: fileExtension
            ) {
                return try Data(contentsOf: url)
            }
        }
        throw CocoaError(.fileNoSuchFile)
    }
}

@MainActor
private final class InteractiveEffectRecorder {
    private(set) var values: [ExperienceInteractiveEffect] = []

    func append(contentsOf effects: [ExperienceInteractiveEffect]) {
        values.append(contentsOf: effects)
    }
}

private final class InteractiveNavigatedScreenRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    func append(_ value: String) {
        lock.withLock { recorded.append(value) }
    }

    var values: [String] { lock.withLock { recorded } }
}

private actor InteractiveOperationLatch {
    private var firstEntryContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private(set) var entries: [String] = []
    private(set) var didEnterSecond = false

    func enterFirst() {
        entries.append("first")
        firstEntryContinuation?.resume()
        firstEntryContinuation = nil
    }

    func waitForFirstEntry() async {
        if !entries.isEmpty { return }
        await withCheckedContinuation { firstEntryContinuation = $0 }
    }

    func waitForRelease() async {
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func releaseFirst() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func enterSecond() {
        didEnterSecond = true
        entries.append("second")
    }
}

private extension Data {
    mutating func appendLittleEndian<Integer: FixedWidthInteger>(_ value: Integer) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
#endif
