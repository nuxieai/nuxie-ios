#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import CryptoKit
import Foundation
import QuartzCore
import XCTest
@testable import Nuxie
@testable import NuxieRuntime
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

final class ExperienceInteractiveScreenTests: XCTestCase {
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
            manifest: payload.manifest,
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
                .listMove(owner, path: "items", from: 0, to: 3),
                .listRemove(owner, path: "items", index: 1),
            ],
            schemaIndexByReference: [first: 7, second: 7, third: 7],
            listIndexPathsBySchema: [7: ["position"]]
        )

        XCTAssertEqual(expanded, [
            .listMove(owner, path: "items", from: 0, to: 3),
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
            listIndexPathsBySchema: [7: ["position"]]
        ))
        let expanded = try planner.expand(
            [
                .listClear(owner, path: "items"),
                .listInsert(owner, path: "items", index: 0, value: row),
            ],
            schemaIndexByReference: [row: 7],
            listIndexPathsBySchema: [7: ["position"]]
        )
        XCTAssertEqual(expanded, [
            .listClear(owner, path: "items"),
            .listInsert(owner, path: "items", index: 0, value: row),
            .setListIndex(row, path: "position", value: 0),
        ])
        XCTAssertEqual(planner.itemsByList[identity], [row])
    }

    func testImageIdentityMapRejectsOneLookupKeyForDifferentAuthoredAssets() throws {
        let digest = String(repeating: "a", count: 64)
        let images = [
            NuxPackageImageAsset(
                location: .external(key: "shared-key"),
                riveAssetId: 1,
                riveUniqueName: "first",
                sha256: digest,
                sizeBytes: 1,
                contentType: "image/png",
                required: true
            ),
            NuxPackageImageAsset(
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

    private static func object(
        _ fields: [(String, ExperienceInteractiveValue)]
    ) -> ExperienceInteractiveValue {
        .object(fields.map { ExperienceInteractiveField(key: $0.0, value: $0.1) })
    }

    private func authenticatedScriptedPayload() async throws
        -> AuthenticatedRuntimePayload
    {
        let encoded = try fixture(named: "scripted_generic_commands", extension: "nux.base64")
        guard let bytes = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let acquisition = try NuxPackageReader.read(bytes)
        let identity = acquisition.metadata.identity
        let packageURL = URL(fileURLWithPath: "/authenticated-fixtures/scripted.nux")
        let acquired = AcquiredExperiencePackage(
            remote: RemoteExperience(
                experienceId: identity.experienceId,
                versionId: identity.buildId,
                buildId: identity.buildId,
                artifact: RemoteExperienceArtifact(
                    url: packageURL.absoluteString,
                    sha256: SHA256Provider.hexDigest(bytes),
                    sizeBytes: bytes.count
                ),
                name: identity.experienceId,
                reentry: .everyTime,
                publishedAt: "2026-08-08T00:00:00Z"
            ),
            packageURL: packageURL,
            packageBytes: bytes,
            acquisition: acquisition,
            assetURLsByRiveUniqueName: [:],
            source: .cache,
            authorizationKeys: try ExperienceTrustRoots.keys(for: .development)
        )
        return try await SwiftExperiencePackageAuthenticator().authenticate(acquired)
    }

    private func statePayload(
        defaultViewModelName: String,
        values: [JourneyViewModelValue]? = nil
    ) async throws -> AuthenticatedRuntimePayload {
        let scene = try fixture(named: "data_binding_test", extension: "riv")
        let catalog = try await NuxieNativeRuntime.inspectAssets(bytes: scene)
        var images: [NuxPackageImageAsset] = []
        var fonts: [NuxPackageFontAsset] = []
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
                images.append(NuxPackageImageAsset(
                    location: .embedded(member: member),
                    riveAssetId: UInt64(authoredID),
                    riveUniqueName: uniqueName,
                    sha256: assetHash,
                    sizeBytes: assetBytes.count,
                    contentType: "image/png",
                    required: true
                ))
            } else {
                fonts.append(NuxPackageFontAsset(
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
        let journey = JourneyDocument(
            screens: [JourneyScreen(
                id: "state-screen",
                defaultViewModelName: defaultViewModelName,
                defaultInstanceId: "root-sdk-id"
            )],
            viewModelValues: values ?? [
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
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let journeyBytes = try encoder.encode(journey)
        let sceneHash = SHA256Provider.hexDigest(scene)
        let journeyHash = SHA256Provider.hexDigest(journeyBytes)
        let manifest = NuxPackageManifestV1(
            version: 1,
            identity: .init(
                experienceId: "state-experience",
                buildId: "state-build",
                appId: "test-app",
                environment: "test"
            ),
            producer: .init(
                compilerCommit: "test",
                compilerVersion: "test",
                runtimeRevision: "test",
                luau: .init(revision: "test", bytecodeVersions: [3, 6]),
                minRuntime: "test"
            ),
            sceneFormat: .init(major: 7, minor: 0),
            requiredCapabilities: [],
            scene: .init(member: "scene", sha256: sceneHash, sizeBytes: scene.count),
            journey: .init(
                member: "journey",
                sha256: journeyHash,
                sizeBytes: journeyBytes.count,
                schemaVersion: 1
            ),
            entry: .init(screenId: "state-screen"),
            screens: [NuxPackageScreen(
                screenId: "state-screen",
                artboardId: "Artboard",
                artboardName: "Artboard",
                width: 100,
                height: 100
            )],
            textInputs: [],
            assets: .init(images: images, fonts: fonts),
            members: [
                .init(
                    name: "manifest",
                    role: "manifest",
                    sha256: String(repeating: "0", count: 64),
                    sizeBytes: 0,
                    contentType: "application/json"
                ),
                .init(
                    name: "scene",
                    role: "scene",
                    sha256: sceneHash,
                    sizeBytes: scene.count,
                    contentType: "application/vnd.nuxie.scene"
                ),
                .init(
                    name: "journey",
                    role: "journey",
                    sha256: journeyHash,
                    sizeBytes: journeyBytes.count,
                    contentType: "application/json"
                ),
            ] + assetMembers.map {
                .init(
                    name: $0.0,
                    role: "asset",
                    sha256: SHA256Provider.hexDigest($0.1),
                    sizeBytes: $0.1.count,
                    contentType: "application/octet-stream"
                )
            }
        )
        let manifestBytes = try encoder.encode(manifest)
        let privateKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(repeating: 0x42, count: 32)
        )
        let signature = try privateKey.signature(for: manifestBytes)
        let signatureBytes = try JSONSerialization.data(
            withJSONObject: [
                "algorithm": "ed25519",
                "keyId": "TEST_ONLY_DEV_KEYPAIR",
                "signatureBase64": signature.base64EncodedString(),
                "signs": "manifest",
                "version": 1,
            ],
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        let packageBytes = Self.encodeContainerMembers(
            [("manifest", manifestBytes), ("signature", signatureBytes),
             ("scene", scene), ("journey", journeyBytes)] + assetMembers
        )
        let acquisition = try NuxPackageReader.read(packageBytes)
        let packageURL = URL(fileURLWithPath: "/authenticated-fixtures/state.nux")
        let acquired = AcquiredExperiencePackage(
            remote: RemoteExperience(
                experienceId: "state-experience",
                versionId: "state-build",
                buildId: "state-build",
                artifact: RemoteExperienceArtifact(
                    url: packageURL.absoluteString,
                    sha256: SHA256Provider.hexDigest(packageBytes),
                    sizeBytes: packageBytes.count
                ),
                name: "state-experience",
                reentry: .everyTime,
                publishedAt: "2026-08-08T00:00:00Z"
            ),
            packageURL: packageURL,
            packageBytes: packageBytes,
            acquisition: acquisition,
            assetURLsByRiveUniqueName: [:],
            source: .cache,
            authorizationKeys: try ExperienceTrustRoots.keys(for: .development)
        )
        return try await SwiftExperiencePackageAuthenticator().authenticate(acquired)
    }

    private static func encodeContainerMembers(_ members: [(String, Data)]) -> Data {
        func aligned(_ value: Int) -> Int { ((value + 15) / 16) * 16 }
        let tableBytes = members.reduce(0) { $0 + 2 + $1.0.utf8.count + 16 }
        var nextOffset = aligned(16 + tableBytes)
        let offsets = members.map { member -> Int in
            defer { nextOffset = aligned(nextOffset + member.1.count) }
            return nextOffset
        }
        var result = Data([0x89, 0x4e, 0x55, 0x58, 0x0d, 0x0a, 0x1a, 0x0a])
        result.appendLittleEndian(UInt32(1))
        result.appendLittleEndian(UInt32(members.count))
        for ((name, payload), offset) in zip(members, offsets) {
            result.appendLittleEndian(UInt16(name.utf8.count))
            result.append(Data(name.utf8))
            result.appendLittleEndian(UInt64(offset))
            result.appendLittleEndian(UInt64(payload.count))
        }
        for ((_, payload), offset) in zip(members, offsets) {
            result.append(Data(repeating: 0, count: offset - result.count))
            result.append(payload)
        }
        return result
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
        let journey = Journey(experience: base, distinctId: "interactive-user", now: Date())
        journey.executionState.currentScreenId = "screen_1"
        let runtime = IRRuntime(dateProvider: mocks.dateProvider)
        let features = FeatureService(
            api: mocks.nuxieApi,
            identity: mocks.identityService,
            profile: mocks.profileService,
            dateProvider: mocks.dateProvider,
            featureInfo: FeatureInfo(),
            configProvider: { NuxieConfiguration(apiKey: "test-key") }
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
                experience: base,
                eventLog: mocks.eventLog,
                identity: mocks.identityService,
                segments: mocks.segmentService,
                features: features,
                profile: mocks.profileService,
                apiClient: mocks.nuxieApi,
                dateProvider: mocks.dateProvider,
                irRuntime: runtime
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
