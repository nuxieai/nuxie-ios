import Foundation
#if canImport(UIKit)
import UIKit
#endif
import XCTest
@_spi(Testing) @testable import Nuxie
@testable import NuxieTestSupport
@testable import NuxieRuntime

final class JourneyRuntimeDelegateTests: JourneyTestCase {
    func testRuntimeDelegateForwardsScopedPresentationTraceMilestones() async throws {
        let fixture = try JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = try await authenticatedRenderedSnapshot(fixture)
        let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let release = try XCTUnwrap(snapshot.releasesByDigest[
            arm.reference.descriptorSha256
        ])
        let recorder = InMemoryExperiencePresentationTrace()
        let attempt = ExperiencePresentationAttempt(
            id: "journey-presentation",
            triggerEvent: "upgrade_tapped",
            startedAt: Date(timeIntervalSince1970: 10),
            startedAtMonotonicTime: 100
        )
        let request = JourneyPresentationRequest(fences: testPresentationFences(),
            release: release,
            delivery: snapshot.profile.delivery,
            screenId: "screen_welcome",
            owner: .init(
                journeyId: "journey-trace",
                distinctId: "customer-trace"
            ),
            reservation: nil,
            presentationTraceContext: .init(
                attempt: attempt,
                recorder: recorder
            ),
            onEmissionBatch: { _, _ in true },
            onOutcome: { _, _ in true }
        )
        let delegate = await MainActor.run {
            JourneyRuntimeDelegate(request: request)
        }
        let controller = await MainActor.run {
            MockExperienceViewController(mockExperienceVersionId: "version_golden")
        }
        let token = try await MainActor.run {
            try XCTUnwrap(delegate.activePresentationTraceToken)
        }

        await MainActor.run {
            delegate.experienceViewControllerDidBecomeReady(
                controller,
                traceToken: .init(id: UUID())
            )
            delegate.experienceViewControllerDidBecomeReady(
                controller,
                traceToken: token
            )
            delegate.experienceViewControllerDidPresentShell(
                controller,
                traceToken: token
            )
        }
        await delegate.experienceViewControllerDidReveal(
            controller,
            traceToken: token
        )
        await MainActor.run {
            delegate.experienceViewController(
                controller,
                didPresentDrawable: .init(
                    presentedTime: 101,
                    frameNumber: 7,
                    pixelWidth: 20,
                    pixelHeight: 30,
                    drawCalls: 4,
                    provenance: .injectedTestObserver
                ),
                screenId: "screen_welcome",
                frameNumber: 7,
                traceToken: token
            )
            delegate.experienceViewController(
                controller,
                didAcceptPointerInput: .init(eventCount: 2),
                screenId: "screen_welcome",
                traceToken: token
            )
            delegate.experienceViewControllerDidFinishPresentation(
                controller,
                traceToken: token
            )
        }

        XCTAssertEqual(recorder.events(for: attempt.id).map(\.stage), [
            .runtimeReady,
            .shellPresented,
            .revealed,
            .firstPresentedDrawable(
                screenId: "screen_welcome",
                frameNumber: 7,
                pixels: 600,
                drawCalls: 4,
                provenance: .injectedTestObserver
            ),
            .firstAcceptedInput(screenId: "screen_welcome", eventCount: 2),
            .presentationCleanupCompleted,
        ])
    }

    func testRuntimeDelegateProvidesIntroEligibilityAuthorizationForItsOwner() async throws {
        let fixture = try JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = try await authenticatedRenderedSnapshot(fixture)
        let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let release = try XCTUnwrap(snapshot.releasesByDigest[
            arm.reference.descriptorSha256
        ])
        let request = JourneyPresentationRequest(fences: testPresentationFences(),
            release: release,
            delivery: snapshot.profile.delivery,
            screenId: "screen_welcome",
            owner: .init(
                journeyId: "journey-authority",
                distinctId: "customer-authority"
            ),
            reservation: nil,
            onEmissionBatch: { _, _ in true },
            onOutcome: { _, _ in true }
        )
        let delegate = await MainActor.run {
            JourneyRuntimeDelegate(request: request)
        }
        let provider = delegate as any IntroEligibilityAuthorizationContextProviding

        XCTAssertEqual(
            provider.introEligibilityAuthorizationContext,
            IntroEligibilityAuthorizationContext(
                distinctId: "customer-authority",
                journeyId: "journey-authority",
                legId: release.descriptor.leg.id,
                descriptorSha256: release.descriptorSHA256
            )
        )
    }

    func testRuntimeDelegateReportsInitialRevealAndLaterVisibleScreenChanges() async throws {
        let fixture = try JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = try await authenticatedRenderedSnapshot(fixture)
        let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let release = try XCTUnwrap(snapshot.releasesByDigest[
            arm.reference.descriptorSha256
        ])
        let reveals = JourneyRevealRecorder()
        let request = JourneyPresentationRequest(fences: testPresentationFences(),
            release: release,
            delivery: snapshot.profile.delivery,
            screenId: "screen_welcome",
            owner: .init(
                journeyId: "journey-reveal",
                distinctId: "customer-reveal"
            ),
            reservation: nil,
            onScreenChanged: { _ in true },
            onEmissionBatch: { _, _ in true },
            onPresentationRevealed: { _ in
                await reveals.record()
            },
            onOutcome: { _, _ in true }
        )
        let delegate = await MainActor.run {
            JourneyRuntimeDelegate(request: request)
        }
        let controller = await MainActor.run {
            MockExperienceViewController(mockExperienceVersionId: "version_golden")
        }

        await delegate.experienceViewController(
            controller,
            didChangeScreen: "screen_welcome"
        )
        let revealsBeforePresentation = await reveals.count()
        XCTAssertEqual(revealsBeforePresentation, 0)

        await delegate.experienceViewControllerDidReveal(controller)
        for _ in 0..<100 {
            if await reveals.count() == 1 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let revealsAfterPresentation = await reveals.count()
        XCTAssertEqual(revealsAfterPresentation, 1)

        await delegate.experienceViewController(
            controller,
            didDismissScreen: "screen_welcome",
            revealingScreenId: "screen_details",
            method: "navigate"
        )
        let revealsAfterSourceDismissal = await reveals.count()
        XCTAssertEqual(revealsAfterSourceDismissal, 1)

        await delegate.experienceViewController(
            controller,
            didChangeScreen: "screen_details"
        )
        let revealsAfterNavigation = await reveals.count()
        XCTAssertEqual(revealsAfterNavigation, 2)

        await delegate.experienceViewController(
            controller,
            didChangeScreen: "screen_details"
        )
        let revealsAfterRepeatedCallback = await reveals.count()
        XCTAssertEqual(revealsAfterRepeatedCallback, 2)
    }

    func testRuntimeDelegateJoinsInitialRevealCallback() async throws {
        let fixture = try JourneyPlaneProfileTestFixture.load(
            entryKey: "renderedEntry"
        )
        let snapshot = try await authenticatedRenderedSnapshot(fixture)
        let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let release = try XCTUnwrap(snapshot.releasesByDigest[
            arm.reference.descriptorSha256
        ])
        let gate = JourneyScreenCommitGate()
        let request = JourneyPresentationRequest(fences: testPresentationFences(),
            release: release,
            delivery: snapshot.profile.delivery,
            screenId: "screen_welcome",
            owner: .init(
                journeyId: "journey-reveal-join",
                distinctId: "customer-reveal-join"
            ),
            reservation: nil,
            onEmissionBatch: { _, _ in true },
            onPresentationRevealed: { _ in
                await gate.suspend()
            },
            onOutcome: { _, _ in true }
        )
        let delegate = await MainActor.run {
            JourneyRuntimeDelegate(request: request)
        }
        let controller = await MainActor.run {
            MockExperienceViewController(mockExperienceVersionId: "version_golden")
        }
        let completion = JourneyCompletionFlag()

        let reveal = Task {
            await delegate.experienceViewControllerDidReveal(controller)
            completion.finish()
        }
        await gate.waitUntilEntered()

        XCTAssertFalse(completion.isCompleted)
        await gate.release()
        await reveal.value
        XCTAssertTrue(completion.isCompleted)
    }

    private func frameSource(model: String, value: String, nested: Bool) -> ExperienceResolvedEventSource {
        let values: [ExperienceInteractiveViewModelSnapshot.Value] = nested
            ? [.init(ownerInstanceID: 2, propertyIndex: 0, name: "product", value: .referencedInstance(3)),
               .init(ownerInstanceID: 3, propertyIndex: 0, name: "placementId", value: .bytes(Data(value.utf8)))]
            : [.init(ownerInstanceID: 2, propertyIndex: 0, name: "placementId", value: .bytes(Data(value.utf8)))]
        return ExperienceResolvedEventSource(nativeID: 2, snapshot: .init(rootInstanceID: 1,
            instances: [1, 2, 3].map { .init(id: $0, schemaIndex: 0, valueRange: 0..<0) },
            values: values), schemaNames: [0: model])
    }

    func testSignedPurchaseScopeChoosesTheDeclaredInstance() async throws {
        for (directory, expected) in [("rendered-purchase-scopes", "plan:lifetime"),
                                      ("rendered-purchase-absolute", "plan:monthly")] {
            let fixture = try JourneyPlaneProfileTestFixture.load(journeyEntryPath: "\(directory)/release-entry.json")
            let snapshot = try await authenticatedRenderedSnapshot(fixture)
            let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
            let release = try XCTUnwrap(snapshot.releasesByDigest[arm.reference.descriptorSha256])
            let reference = try XCTUnwrap(release.descriptor.leg.steps.first { $0.id == "purchase" }?.action?["placementId"])
            let (_, artifact) = try await TestExperienceRuntimeFixture.purchase(navigation: false,
                absolute: directory == "rendered-purchase-absolute")
            let row = try await openFixturePageRow(payload: artifact.payload, pixelWidth: 320, pixelHeight: 100)
            defer { Task { try? await closeFixturePageRow(row) } }
            let root = try await row.rootViewModel()
            _ = try await row.mutateState([.setString(root, path: "second/placementId", value: Data("plan:lifetime".utf8))])
            let rowSnapshot = try await row.snapshot()
            let second = try fixtureRowReference("second", in: rowSnapshot)
            let file = try await NuxieNativePreparedFile.prepare(bytes: artifact.payload.sceneBytes)
            let catalog = await file.viewModelCatalog()
            let schemaIndex = try XCTUnwrap(rowSnapshot.instances.first { $0.id == second }?.schemaIndex)
            let model = try XCTUnwrap(catalog.schemas.first { $0.index == schemaIndex }?.name)
            let source = ExperienceResolvedEventSource(nativeID: second, snapshot: rowSnapshot,
                schemaNames: Dictionary(uniqueKeysWithValues: catalog.schemas.map { ($0.index, $0.name) }))
            let screenID = artifact.renderPlan.entry.screenId
            let request = JourneyPresentationRequest(fences: testPresentationFences(), release: release, delivery: snapshot.profile.delivery,
                screenId: screenID, owner: .init(journeyId: "journey", distinctId: "customer"),
                reservation: nil, onEmissionBatch: { _, _ in true }, onOutcome: { _, _ in true })
            let delegate = await MainActor.run { JourneyRuntimeDelegate(request: request) }
            let controller = await MainActor.run { MockExperienceViewController(mockExperienceVersionId: "version") }
            await delegate.experienceViewController(controller, didChangeScreen: screenID)
            let selected = await delegate.resolvePresentationString(reference, source:
                ScreenEmissionSource(screenId: screenID, actionId: "buy", componentId: "buy", instanceId: nil),
                eventSource: source)
            XCTAssertEqual(selected, expected, directory)
            if directory == "rendered-purchase-scopes" {
                let withoutFrame = await delegate.resolvePresentationString(reference,
                    source: ScreenEmissionSource(screenId: screenID, actionId: "buy", componentId: "buy", instanceId: nil))
                XCTAssertNil(withoutFrame)
            }
            let ambiguous = JourneyReleaseJSONValue.object(["ref": .object([
                "kind": .string("path"), "path": .string("placementId"),
                "viewModelName": .string(model), "isRelative": .bool(false),
            ])])
            let ambiguousSelection = await delegate.resolvePresentationString(ambiguous)
            XCTAssertNil(ambiguousSelection, "Two Plan instances have no unique absolute model selection")
        }
    }

    func testPathReferenceRoundTripPreservesExplicitScope() throws {
        for relative: Bool? in [nil, false, true] {
            let reference = VmPathRef(path: "product.placementId", isRelative: relative)
            let encoded = try JSONEncoder().encode(reference)
            let decoded = try JSONDecoder().decode(VmPathRef.self, from: encoded)
            XCTAssertEqual(decoded.isRelative, relative)
        }
    }

    func testPlanWriteBeforeScreenCommitStillDecidesThePurchase() async throws {
        let fixture = try JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let scenarioURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/journeys/planes/file-paywall-selection.json")
        let scenario = try JSONDecoder().decode(FilePaywallSelectionScenario.self, from: Data(contentsOf: scenarioURL))
        let model = try XCTUnwrap(scenario.screen.defaultViewModelName)
        let root = try XCTUnwrap(scenario.screen.defaultInstanceId)
        let snapshot = replacing(try await authenticatedRenderedSnapshot(fixture),
            screens: [scenario.screen], viewModelValues: scenario.viewModelValues)
        let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let release = try XCTUnwrap(snapshot.releasesByDigest[arm.reference.descriptorSha256])
        let gate = JourneyScreenCommitGate()
        let request = JourneyPresentationRequest(fences: testPresentationFences(),
            release: release, delivery: snapshot.profile.delivery,
            screenId: "screen_welcome", owner: .init(journeyId: "journey", distinctId: "customer"),
            reservation: nil, onScreenChanged: { _ in await gate.suspend(); return true }, onEmissionBatch: { _, _ in true }, onOutcome: { _, _ in true })
        let delegate = await MainActor.run { JourneyRuntimeDelegate(request: request) }
        let controller = await MainActor.run { PaywallValueRecordingController(mockExperienceVersionId: "version") }
        let activation = Task { @MainActor in
            await delegate.experienceViewController(controller, didChangeScreen: scenario.screen.id)
        }
        await gate.waitUntilEntered()
        await delegate.experienceViewController(controller, didEmitViewModelChange:
            .init(path: .init(viewModelName: model, path: "paywall/selectedProductId"),
                  value: "product-annual", source: "runtime", screenId: scenario.screen.id,
                  instanceId: root, isTrigger: false))
        let sent = await controller.recordedValues
        XCTAssertTrue(sent.contains { $0.path == "paywall/selectedProduct" })
        let writingScreens = await controller.writingScreens
        XCTAssertFalse(writingScreens.isEmpty)
        XCTAssertTrue(writingScreens.allSatisfy { $0 == scenario.screen.id })
        await gate.release()
        await activation.value
        let selected = await delegate.resolvePresentationString(scenario.purchaseReference)
        XCTAssertEqual(selected, "placement-annual")
    }

    func testFilePaywallPlanTapChangesTheJourneyPurchasePlacement() async throws {
        let fixture = try JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let scenarioURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/journeys/planes/file-paywall-selection.json")
        let scenario = try JSONDecoder().decode(FilePaywallSelectionScenario.self, from: Data(contentsOf: scenarioURL))
        let model = try XCTUnwrap(scenario.screen.defaultViewModelName)
        let root = try XCTUnwrap(scenario.screen.defaultInstanceId)
        let snapshot = replacing(try await authenticatedRenderedSnapshot(fixture),
            screens: [scenario.screen], viewModelValues: scenario.viewModelValues)
        let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let release = try XCTUnwrap(snapshot.releasesByDigest[arm.reference.descriptorSha256])
        let request = JourneyPresentationRequest(fences: testPresentationFences(),
            release: release, delivery: snapshot.profile.delivery,
            screenId: "screen_welcome", owner: .init(journeyId: "journey", distinctId: "customer"),
            reservation: nil, onEmissionBatch: { _, _ in true }, onOutcome: { _, _ in true })
        let delegate = await MainActor.run { JourneyRuntimeDelegate(request: request) }
        let controller = await MainActor.run { PaywallValueRecordingController(mockExperienceVersionId: "version") }
        await delegate.experienceViewController(controller, didChangeScreen: scenario.screen.id)
        let initial = await delegate.resolvePresentationString(scenario.purchaseReference)
        XCTAssertEqual(initial, scenario.initialPlacement)

        // This is the production callback for the native tap's selectedProductId
        // write. The test never writes selectedProduct or a purchase placement.
        for write in scenario.writes {
            await delegate.experienceViewController(controller, didEmitViewModelChange:
                .init(path: .init(viewModelName: model, path: "paywall/selectedProductId"),
                      value: write.selectedProductId, source: "runtime", screenId: scenario.screen.id,
                      instanceId: root, isTrigger: false))
            let selected = await delegate.resolvePresentationString(scenario.purchaseReference)
            XCTAssertEqual(selected, write.expectedPlacement, write.selectedProductId)
        }
    }

    func testNativePlanTapChangesPurchaseThroughTheRuntimeDelegate() async throws {
        try await assertNativePlanTapChangesPurchase()
    }

    func testNativePlacementTapChangesPurchaseThroughTheRuntimeDelegate() async throws {
        try await assertNativePlanTapChangesPurchase(fixtureDirectory: "paywall-placement-selection",
            selectorPath: "paywall/selectedPlacementId", duplicateProductID: true)
    }

    func testNativePlanTapReadsSignedIdentityAfterStoreCatalogMapping() async throws {
        try await assertNativePlanTapChangesPurchase(fixtureDirectory: "paywall-catalog-selection", hydrateCatalog: true)
    }

    private func assertNativePlanTapChangesPurchase(
        fixtureDirectory: String = "paywall-selection", selectorPath: String = "paywall/selectedProductId",
        duplicateProductID: Bool = false, hydrateCatalog: Bool = false
    ) async throws {
        let fixtureRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures")
        let scenario = try JSONDecoder().decode(FilePaywallSelectionScenario.self,
            from: Data(contentsOf: fixtureRoot.appendingPathComponent("journeys/planes/file-paywall-selection.json")))
        // The native fixture's root is named Runtime. Its rows have the same
        // flat structure as a file-made screen; the callback case also pins
        // the generated per-screen model name.
        let sourceRows = try JSONDecoder().decode([JourneyViewModelValue].self,
            from: JSONEncoder().encode(scenario.viewModelValues))
        var values = sourceRows.map { value in
            JourneyViewModelValue(
                viewModelName: value.viewModelName == scenario.screen.defaultViewModelName ? "Runtime" : value.viewModelName,
                instanceId: value.instanceId == scenario.screen.defaultInstanceId ? "root-sdk-id" : value.instanceId,
                instanceName: value.viewModelName == "PaywallProduct" ? value.instanceId?.capitalized : nil,
                path: value.path, value: value.value)
        }
        if fixtureDirectory != "paywall-selection" {
            values.append(.init(viewModelName: "Runtime", instanceId: "root-sdk-id", path: "annual",
                                value: AnyCodable(["vmInstanceId": "annual"])))
        }
        if duplicateProductID {
            values = values.map { row in
                if row.path == "productId" || row.path == "paywall/selectedProductId" {
                    return .init(viewModelName: row.viewModelName, instanceId: row.instanceId, instanceName: row.instanceName,
                                 path: row.path, value: AnyCodable("product-pro"))
                }
                return row
            }
            values.append(.init(viewModelName: "Runtime", instanceId: "root-sdk-id", path: "paywall/selectedPlacementId",
                                value: AnyCodable("placement-monthly")))
        }
        let nativeValues = hydrateCatalog ? StoreProductViewModelProjection.apply(["monthly", "annual"].map { plan in
            StoreProduct(productId: "target-environment-\(plan)", storeProductId: "com.example.\(plan)", placementId: "placement-\(plan)",
                         name: plan, price: "$9.99", period: .month, productType: .autoRenewable)
        }, to: values) : values
        let payload = try await statePayload(defaultViewModelName: "Runtime", values: nativeValues,
            scene: Data(contentsOf: fixtureRoot.appendingPathComponent("runtime/\(fixtureDirectory)/screen.riv")),
            artboardName: "Paywall")
        let screen = try await ExperienceInteractiveScreen.open(payload: payload, pixelWidth: 320, pixelHeight: 100)
        defer { Task { try? await screen.close() } }
        let snapshot = replacing(try await authenticatedRenderedSnapshot(
            JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")),
            screens: [.init(id: "state-screen", defaultViewModelName: "Runtime",
                            defaultInstanceId: "root-sdk-id", responseCaptures: [])],
            viewModelValues: try JSONDecoder().decode([[String: JourneyReleaseJSONValue]].self,
                from: JSONEncoder().encode(values)))
        let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let release = try XCTUnwrap(snapshot.releasesByDigest[arm.reference.descriptorSha256])
        let request = JourneyPresentationRequest(fences: testPresentationFences(),
            release: release, delivery: snapshot.profile.delivery,
            screenId: "state-screen", owner: .init(journeyId: "journey", distinctId: "customer"),
            reservation: nil, onEmissionBatch: { _, _ in true }, onOutcome: { _, _ in true })
        let delegate = await MainActor.run { JourneyRuntimeDelegate(request: request) }
        let controller = await MainActor.run { PaywallValueRecordingController(mockExperienceVersionId: "version") }
        await delegate.experienceViewController(controller, didChangeScreen: "state-screen")
        let initial = await delegate.resolvePresentationString(scenario.purchaseReference)
        XCTAssertEqual(initial, scenario.initialPlacement)
        if hydrateCatalog {
            let annual = try await screen.viewModel(named: "PaywallProduct", instanceID: "annual")
            let native = try await screen.snapshot()
            XCTAssertEqual(native.values.first { $0.ownerInstanceID == annual.rawValue && $0.name == "productId" }?.value,
                           .bytes(Data("product-annual".utf8)))
        }
        for _ in 0..<20 {
            let opening = try await screen.step(elapsedSeconds: 0.016)
            for effect in opening.effects {
                guard case .viewModelChange(let change) = effect.kind, change.origin == .runtime else { continue }
                let resolved = try await screen.resolveViewModelChange(change)
                XCTAssertFalse(["paywall/selectedProductId", "paywall/selectedPlacementId"].contains(resolved.path),
                               "Opening the scene must not select another plan")
                await delegate.experienceViewController(controller, didEmitViewModelChange:
                    .init(path: .init(viewModelName: resolved.viewModelName, path: resolved.path),
                          value: nativeTapValue(resolved.value), source: "runtime", screenId: "state-screen",
                          instanceId: resolved.instanceID, isTrigger: resolved.isTrigger))
            }
        }
        let afterOpening = await delegate.resolvePresentationString(scenario.purchaseReference)
        XCTAssertEqual(afterOpening, scenario.initialPlacement)
        let down = try await screen.step(pointers: [.init(kind: .down, x: 80, y: 40)], elapsedSeconds: 0)
        let up = try await screen.step(pointers: [.init(kind: .up, x: 80, y: 40, timestamp: 0.1)], elapsedSeconds: 0)
        let settled = try await screen.step(elapsedSeconds: 0.016)
        var selectionWrites = 0
        for effect in down.effects + up.effects + settled.effects {
            guard case .viewModelChange(let change) = effect.kind, change.origin == .runtime else { continue }
            let resolved = try await screen.resolveViewModelChange(change)
            if resolved.path == selectorPath, case .string(let id) = resolved.value {
                selectionWrites += 1
                XCTAssertEqual(id, selectorPath == "paywall/selectedPlacementId" ? "placement-annual" : "product-annual")
            }
            await delegate.experienceViewController(controller, didEmitViewModelChange:
                .init(path: .init(viewModelName: resolved.viewModelName, path: resolved.path),
                      value: nativeTapValue(resolved.value), source: "runtime", screenId: "state-screen",
                      instanceId: resolved.instanceID, isTrigger: resolved.isTrigger))
        }
        XCTAssertGreaterThan(selectionWrites, 0, "The real pointer must emit the selection write")
        let afterTap = await delegate.resolvePresentationString(scenario.purchaseReference)
        XCTAssertEqual(afterTap, scenario.writes[0].expectedPlacement)
        let sent = await controller.recordedValues
        XCTAssertTrue(sent.contains { $0.path == "paywall/selectedProduct" })
        for update in try ExperienceInteractiveStateCompiler.signedValues(sent) {
            _ = try await screen.applyStateCommand(.value(update))
        }
        let feedbackFrame = try await screen.step(elapsedSeconds: 0.016)
        for effect in feedbackFrame.effects {
            guard case .viewModelChange(let change) = effect.kind, change.origin == .runtime else { continue }
            let resolved = try await screen.resolveViewModelChange(change)
            await delegate.experienceViewController(controller, didEmitViewModelChange:
                .init(path: .init(viewModelName: resolved.viewModelName, path: resolved.path),
                      value: nativeTapValue(resolved.value), source: "runtime", screenId: "state-screen",
                      instanceId: resolved.instanceID, isTrigger: resolved.isTrigger))
        }
        let afterFeedback = await delegate.resolvePresentationString(scenario.purchaseReference)
        XCTAssertEqual(afterFeedback, scenario.writes[0].expectedPlacement,
                       "Native feedback must not be treated as another plan tap")
        let nativeSelection = try await screen.snapshot()
        guard case .referencedInstance(let parent) = nativeSelection.values.first(where: {
            $0.ownerInstanceID == nativeSelection.rootInstanceID && $0.name == "paywall"
        })?.value else { return XCTFail("Expected the paywall parent") }
        let annual = try await screen.viewModel(named: "PaywallProduct", instanceID: "annual")
        XCTAssertEqual(nativeSelection.values.first { $0.ownerInstanceID == parent && $0.name == "selectedProduct" }?.value,
            .referencedInstance(annual.rawValue))
        XCTAssertEqual(nativeSelection.values.first { $0.ownerInstanceID == parent && $0.name == "selectedIndex" }?.value, .number(1))
        let monthly = try await screen.viewModel(named: "PaywallProduct", instanceID: "monthly")
        XCTAssertEqual(nativeSelection.values.first { $0.ownerInstanceID == annual.rawValue && $0.name == "isSelected" }?.value, .bool(true))
        XCTAssertEqual(nativeSelection.values.first { $0.ownerInstanceID == monthly.rawValue && $0.name == "isSelected" }?.value, .bool(false))
    }

    private func nativeTapValue(_ value: ExperienceInteractiveValue) -> Any {
        switch value {
        case .null: NSNull()
        case .bool(let value): value
        case .number(let value): value
        case .string(let value): value
        case .bytes(let value): value
        case .list(let values): values.map(nativeTapValue)
        case .object(let fields): Dictionary(uniqueKeysWithValues: fields.map { ($0.key, nativeTapValue($0.value)) })
        }
    }

    func testRuntimeDelegateResolvesDynamicPurchasePlacementFromActiveScreenState() async throws {
        let fixture = try JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/journeys/planes/purchase-reference-scopes.json")
        let scopes = try JSONDecoder().decode(PurchaseReferenceScopes.self, from: Data(contentsOf: fixtureURL))
        let snapshot = replacing(
            try await authenticatedRenderedSnapshot(fixture),
            viewModelValues: scopes.values
        )
        let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let release = try XCTUnwrap(snapshot.releasesByDigest[
            arm.reference.descriptorSha256
        ])
        let request = JourneyPresentationRequest(fences: testPresentationFences(),
            release: release,
            delivery: snapshot.profile.delivery,
            screenId: "screen_welcome",
            owner: .init(
                journeyId: "journey",
                distinctId: "customer"
            ),
            reservation: nil,
            onEmissionBatch: { _, _ in true },
            onOutcome: { _, _ in true }
        )
        let delegate = await MainActor.run {
            JourneyRuntimeDelegate(request: request)
        }
        let controller = await MainActor.run {
            MockExperienceViewController(mockExperienceVersionId: "version_golden")
        }
        let placementReference = JourneyReleaseJSONValue.object([
            "ref": .object([
                "kind": .string("path"),
                "path": .string("product.placementId"),
            ])
        ])

        await delegate.experienceViewController(
            controller,
            didChangeScreen: "screen_welcome"
        )
        let initialPlacement = await delegate.resolvePresentationString(
            placementReference
        )
        await delegate.experienceViewController(
            controller,
            didEmitViewModelChange: ExperienceRendererViewModelChange(
                path: VmPathRef(path: "product.placementId"),
                value: "golden:monthly",
                source: "runtime",
                screenId: "screen_welcome",
                instanceId: "welcome",
                isTrigger: false
            )
        )
        let changedPlacement = await delegate.resolvePresentationString(
            placementReference
        )
        let secondaryPlacement = await delegate.resolvePresentationString(
            placementReference,
            source: ScreenEmissionSource(
                screenId: "screen_welcome",
                actionId: "purchase-secondary",
                componentId: "secondary-button",
                instanceId: "secondary"
            )
        )

        XCTAssertEqual(initialPlacement, "golden:yearly")
        XCTAssertEqual(changedPlacement, "golden:monthly")
        XCTAssertEqual(secondaryPlacement, "golden:secondary")
        for vector in scopes.cases {
            let source = vector.instanceId.map {
                ScreenEmissionSource(screenId: "screen_welcome", actionId: "purchase",
                    componentId: "buy", instanceId: $0)
            }
            let resolved = await delegate.resolvePresentationString(vector.reference, source: source)
            XCTAssertEqual(resolved, vector.expected, vector.name)
        }
    }

    func testOnlySuccessfulOpensReachTheRunRecorder() async throws {
        let snapshot = try await authenticatedRenderedSnapshot(JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry"))
        let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let release = try XCTUnwrap(snapshot.releasesByDigest[arm.reference.descriptorSha256])
        let recorded = OpenedLinkRecorder()
        let request = JourneyPresentationRequest(fences: testPresentationFences(), release: release, delivery: snapshot.profile.delivery,
            screenId: "screen_welcome", owner: .init(journeyId: "journey", distinctId: "customer"),
            reservation: nil, onLinkOpened: { recorded.append($0) }, onEmissionBatch: { _, _ in true },
            onOutcome: { _, _ in true })
        let delegate = await MainActor.run { JourneyRuntimeDelegate(request: request, openLink: { _, link in
                guard ExperienceLinkRouting.destination(urlString: link.urlString, target: link.target) != nil else { return nil }
                return link
            }) }
        let controller = await MainActor.run { MockExperienceViewController(mockExperienceVersionId: "version") }
        await delegate.experienceViewController(controller, didChangeScreen: "screen_welcome")
        for url in ["https://example.test/account", "not a url"] {
            await delegate.experienceViewController(controller, didRequestOpenLink: .init(urlString: url,
                target: "_self", screenId: "screen_welcome", instanceId: nil))
        }
        XCTAssertEqual(recorded.values().map(\.urlString), ["https://example.test/account"])
        XCTAssertEqual(recorded.values().first?.screenId, "screen_welcome")
    }

    func testRuntimeDelegateForwardsRendererOpenLinksToTheStateRouter() async throws {
        let fixture = try JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = try await authenticatedRenderedSnapshot(fixture)
        let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let release = try XCTUnwrap(snapshot.releasesByDigest[
            arm.reference.descriptorSha256
        ])
        let recorded = OpenedLinkRecorder()
        let request = JourneyPresentationRequest(fences: testPresentationFences(),
            release: release,
            delivery: snapshot.profile.delivery,
            screenId: "screen_welcome",
            owner: .init(
                journeyId: "journey",
                distinctId: "customer"
            ),
            reservation: nil,
            onLinkOpened: { recorded.append($0) },
            onEmissionBatch: { _, _ in true },
            onOutcome: { _, _ in true }
        )
        let delegate = await MainActor.run {
            JourneyRuntimeDelegate(request: request, openLink: { _, link in
                guard ExperienceLinkRouting.destination(urlString: link.urlString, target: link.target) != nil else { return nil }
                return link
            })
        }
        let controller = await MainActor.run {
            MockExperienceViewController(mockExperienceVersionId: "version_golden")
        }

        await delegate.experienceViewController(
            controller,
            didChangeScreen: "screen_welcome"
        )
        await delegate.experienceViewController(
            controller,
            didRequestOpenLink: ExperienceRendererOpenLinkRequest(
                urlString: "https://example.com/account",
                target: "in_app",
                screenId: "screen_welcome",
                instanceId: "secondary"
            )
        )
        await delegate.experienceViewController(
            controller,
            didRequestOpenLink: ExperienceRendererOpenLinkRequest(
                urlString: "https://example.com/stale",
                target: "external",
                screenId: "screen_details",
                instanceId: nil
            )
        )

        let links = recorded.values()
        XCTAssertEqual(links.count, 2)
        XCTAssertEqual(links.first?.urlString, "https://example.com/account")
        XCTAssertEqual(links.first?.target, "in_app")
    }

    func testRuntimeDelegateRoutesPermissionResultsWithTheCapturedOwnerAfterDismissal() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = try await authenticatedRenderedSnapshot(fixture)
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let presenter = await MainActor.run { RecordingJourneyPresenter() }
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            presenter: presenter
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        let presentedRequest = await MainActor.run { presenter.request }
        let request = try XCTUnwrap(presentedRequest)
        let delegate = await MainActor.run {
            JourneyRuntimeDelegate(request: request)
        }
        let controller = await MainActor.run {
            MockExperienceViewController(mockExperienceVersionId: "version_golden")
        }
        let hostDismissed = await delegate
            .experienceViewControllerDidRequestHostDismiss(controller)
        XCTAssertTrue(hostDismissed)

        let captured = expectation(description: "permission events captured")
        captured.expectedFulfillmentCount = 4
        let expectedNames: Set<String> = [
            SystemEventNames.notificationsEnabled,
            SystemEventNames.permissionGranted,
            SystemEventNames.trackingAuthorized,
            SystemEventNames.permissionDenied,
        ]
        events.addEventHandler(pattern: "*") { event in
            if expectedNames.contains(event.name) {
                captured.fulfill()
            }
        }

        await MainActor.run {
            delegate.experienceViewController(
                controller,
                didResolveNotificationPermissionEvent:
                    SystemEventNames.notificationsEnabled,
                properties: ["journey_id": "spoofed"],
                journeyId: request.owner.journeyId
            )
            delegate.experienceViewController(
                controller,
                didResolveRequestPermissionEvent:
                    SystemEventNames.permissionGranted,
                properties: ["type": "camera"],
                journeyId: request.owner.journeyId
            )
            delegate.experienceViewController(
                controller,
                didResolveTrackingPermissionEvent:
                    SystemEventNames.trackingAuthorized,
                properties: [:],
                journeyId: request.owner.journeyId
            )
            delegate.experienceViewController(
                controller,
                didIgnoreUnsupportedRequestPermissionType: "unsupported-sensor",
                journeyId: request.owner.journeyId
            )
        }
        await fulfillment(of: [captured], timeout: 2)

        let permissionEvents = events.routedEvents.filter {
            expectedNames.contains($0.name)
        }
        XCTAssertEqual(permissionEvents.count, 4)
        for event in permissionEvents {
            XCTAssertEqual(event.distinctId, "customer")
            XCTAssertEqual(event.properties["journey_id"] as? String, request.owner.journeyId)
            XCTAssertEqual(event.properties["experience_id"] as? String, "experience_golden")
            XCTAssertEqual(event.properties["experience_version_id"] as? String, "version_golden")
        }
        let unsupported = try XCTUnwrap(permissionEvents.first {
            $0.name == SystemEventNames.permissionDenied
        })
        XCTAssertEqual(unsupported.properties["type"] as? String, "unsupported-sensor")

        let misattributed = expectation(
            description: "departing-owner permission is not reassigned"
        )
        misattributed.isInverted = true
        events.addEventHandler(pattern: SystemEventNames.trackingDenied) { _ in
            misattributed.fulfill()
        }
        identity.setDistinctId("other-customer")
        identity.setDistinctId("customer")
        await MainActor.run {
            delegate.experienceViewController(
                controller,
                didResolveTrackingPermissionEvent:
                    SystemEventNames.trackingDenied,
                properties: [:],
                journeyId: request.owner.journeyId
            )
        }
        await fulfillment(of: [misattributed], timeout: 0.2)
    }

    func testRuntimeDelegatePreservesTheTopLayerBackTarget() async throws {
        let fixture = try JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = try await authenticatedRenderedSnapshot(fixture)
        let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let release = try XCTUnwrap(snapshot.releasesByDigest[
            arm.reference.descriptorSha256
        ])
        let request = JourneyPresentationRequest(fences: testPresentationFences(),
            release: release,
            delivery: snapshot.profile.delivery,
            screenId: "screen_welcome",
            owner: .init(
                journeyId: "journey",
                distinctId: "customer"
            ),
            reservation: nil,
            onEmissionBatch: { _, _ in true },
            onOutcome: { _, _ in true }
        )
        let delegate = await MainActor.run {
            JourneyRuntimeDelegate(request: request)
        }
        let controller = await MainActor.run {
            MockExperienceViewController(mockExperienceVersionId: "version_golden")
        }

        await delegate.experienceViewController(
            controller,
            didChangeScreen: "screen_welcome"
        )
        await delegate.experienceViewController(
            controller,
            didDismissScreen: "screen_welcome",
            revealingScreenId: "screen_details",
            method: "navigate"
        )
        await delegate.experienceViewController(
            controller,
            didChangeScreen: "screen_details"
        )

        let backTarget = await MainActor.run {
            delegate.prepareBackNavigation(steps: 1, target: "screen_welcome")
        }
        XCTAssertEqual(backTarget, "screen_welcome")
        await MainActor.run {
            #if canImport(UIKit)
            XCTAssertEqual(delegate.consumeBackNavigation(target: "screen_welcome"), 1)
            #else
            XCTAssertNil(delegate.consumeBackNavigation(target: "screen_welcome"))
            #endif
            XCTAssertNil(delegate.consumeBackNavigation(target: "screen_welcome"))
            _ = delegate.prepareBackNavigation(steps: 2, target: "screen_welcome")
        }
        await delegate.experienceViewController(controller, didChangeScreen: "screen_details")
        await MainActor.run {
            XCTAssertNil(delegate.consumeBackNavigation(target: "screen_welcome"))
        }
    }

    func testRuntimeDelegateGivesHostDismissalPrecedenceOverTopLevelScreenDismissal() async throws {
        let fixture = try JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = try await authenticatedRenderedSnapshot(fixture)
        let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let release = try XCTUnwrap(snapshot.releasesByDigest[
            arm.reference.descriptorSha256
        ])
        let screenDismissals = JourneyOutcomeCallRecorder()
        let outcomes = JourneyOutcomeCallRecorder()
        let request = JourneyPresentationRequest(fences: testPresentationFences(),
            release: release,
            delivery: snapshot.profile.delivery,
            screenId: "screen_welcome",
            owner: .init(
                journeyId: "journey",
                distinctId: "customer"
            ),
            reservation: nil,
            onScreenDismissed: { screenId, _, _ in
                await screenDismissals.record(
                    outcome: .dismissed,
                    screenId: screenId
                )
                return .completed
            },
            onEmissionBatch: { _, _ in true },
            onOutcome: { outcome, screenId in
                await outcomes.record(outcome: outcome, screenId: screenId)
                return true
            }
        )
        let delegate = await MainActor.run {
            JourneyRuntimeDelegate(request: request)
        }
        let controller = await MainActor.run {
            MockExperienceViewController(mockExperienceVersionId: "version_golden")
        }

        await delegate.experienceViewController(
            controller,
            didChangeScreen: "screen_welcome"
        )
        await delegate.experienceViewControllerWillRequestHostDismiss(controller)
        await delegate.experienceViewController(
            controller,
            didDismissScreen: "screen_welcome",
            revealingScreenId: nil,
            method: "host"
        )

        let screenDismissalCount = await screenDismissals.count()
        XCTAssertEqual(screenDismissalCount, 0)
        let accepted = await delegate
            .experienceViewControllerDidRequestHostDismiss(controller)
        XCTAssertTrue(accepted)
        let hostOutcome = await outcomes.onlyCall()
        XCTAssertEqual(hostOutcome?.outcome, .dismissed)
        XCTAssertEqual(hostOutcome?.screenId, "screen_welcome")
    }

    func testRuntimeDelegateCoalescesConcurrentSurfaceResolution() async throws {
        let fixture = try JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = try await authenticatedRenderedSnapshot(fixture)
        let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let release = try XCTUnwrap(snapshot.releasesByDigest[
            arm.reference.descriptorSha256
        ])
        let gate = JourneyScreenCommitGate()
        let calls = JourneyOutcomeCallRecorder()
        let request = JourneyPresentationRequest(fences: testPresentationFences(),
            release: release,
            delivery: snapshot.profile.delivery,
            screenId: "screen_welcome",
            owner: .init(
                journeyId: "journey",
                distinctId: "customer"
            ),
            reservation: nil,
            onEmissionBatch: { _, _ in true },
            onOutcome: { outcome, screenId in
                await calls.record(outcome: outcome, screenId: screenId)
                await gate.suspend()
                return true
            }
        )
        let delegate = await MainActor.run {
            JourneyRuntimeDelegate(request: request)
        }
        let controller = await MainActor.run {
            MockExperienceViewController(mockExperienceVersionId: "version_golden")
        }
        let firstHostDismissal = Task { @MainActor in
            await delegate.experienceViewControllerDidRequestHostDismiss(controller)
        }

        await gate.waitUntilEntered()
        let secondHostDismissal = Task { @MainActor in
            await delegate.experienceViewControllerDidRequestHostDismiss(controller)
        }
        for _ in 0..<20 {
            await Task.yield()
        }
        let callsBeforeRelease = await calls.count()
        XCTAssertEqual(callsBeforeRelease, 1)

        await gate.release()
        let firstAccepted = await firstHostDismissal.value
        let secondAccepted = await secondHostDismissal.value
        let finalCallCount = await calls.count()

        XCTAssertTrue(firstAccepted)
        XCTAssertTrue(secondAccepted)
        XCTAssertEqual(finalCallCount, 1)
    }

    func testRuntimeDelegateAcknowledgesOrdinaryCloseWithoutHostOutcome() async throws {
        let fixture = try JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = try await authenticatedRenderedSnapshot(fixture)
        let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let release = try XCTUnwrap(snapshot.releasesByDigest[
            arm.reference.descriptorSha256
        ])
        let screenDismissals = JourneyOutcomeCallRecorder()
        let outcomes = JourneyOutcomeCallRecorder()
        let request = JourneyPresentationRequest(fences: testPresentationFences(),
            release: release,
            delivery: snapshot.profile.delivery,
            screenId: "screen_welcome",
            owner: .init(
                journeyId: "journey",
                distinctId: "customer"
            ),
            reservation: nil,
            onScreenDismissed: { screenId, _, _ in
                await screenDismissals.record(
                    outcome: .dismissed,
                    screenId: screenId
                )
                return .handled
            },
            onEmissionBatch: { _, _ in true },
            onOutcome: { outcome, screenId in
                await outcomes.record(outcome: outcome, screenId: screenId)
                return true
            }
        )
        let delegate = await MainActor.run {
            JourneyRuntimeDelegate(request: request)
        }
        let controller = await MainActor.run {
            MockExperienceViewController(mockExperienceVersionId: "version_golden")
        }

        await delegate.experienceViewController(
            controller,
            didChangeScreen: "screen_welcome"
        )
        await delegate.experienceViewController(
            controller,
            didDismissScreen: "screen_welcome",
            revealingScreenId: nil,
            method: "user"
        )
        let accepted = await delegate.experienceViewControllerDidRequestDismiss(
            controller,
            reason: .userDismissed
        )

        XCTAssertTrue(accepted)
        let screenDismissalCount = await screenDismissals.count()
        let outcomeCount = await outcomes.count()
        XCTAssertEqual(screenDismissalCount, 1)
        XCTAssertEqual(outcomeCount, 0)
    }

    func testRuntimeDelegateEnablesScreenEmissionsOnlyAfterLifecycleCommit() async throws {
        let fixture = try JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = try await authenticatedRenderedSnapshot(fixture)
        let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let release = try XCTUnwrap(snapshot.releasesByDigest[
            arm.reference.descriptorSha256
        ])
        let gate = JourneyScreenCommitGate()
        let request = JourneyPresentationRequest(fences: testPresentationFences(),
            release: release,
            delivery: snapshot.profile.delivery,
            screenId: "screen_welcome",
            owner: .init(
                journeyId: "journey",
                distinctId: "customer"
            ),
            reservation: nil,
            onScreenChanged: { _ in
                await gate.suspend()
                return true
            },
            onEmissionBatch: { _, _ in true },
            onOutcome: { _, _ in true }
        )
        let delegate = await MainActor.run {
            JourneyRuntimeDelegate(request: request)
        }
        let controller = await MainActor.run {
            MockExperienceViewController(mockExperienceVersionId: "version_golden")
        }
        let activation = Task { @MainActor in
            await delegate.experienceViewController(
                controller,
                didChangeScreen: "screen_welcome"
            )
        }

        await gate.waitUntilEntered()
        let scopeBeforeCommit = await MainActor.run {
            controller.captureScreenEmissionRun()
        }
        XCTAssertNil(scopeBeforeCommit)

        await gate.release()
        await activation.value

        let scopeAfterCommit = await MainActor.run {
            controller.captureScreenEmissionRun()
        }
        XCTAssertEqual(scopeAfterCommit?.journeyId, "journey")
        XCTAssertEqual(scopeAfterCommit?.presentationEpoch, 1)
    }

    func testRuntimeDelegateRejectsABatchFromAnEarlierVisitToTheSameScreen() async throws {
        let fixture = try JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = try await authenticatedRenderedSnapshot(fixture)
        let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let release = try XCTUnwrap(snapshot.releasesByDigest[
            arm.reference.descriptorSha256
        ])
        let recorder = JourneyEmissionBatchRecorder()
        let request = JourneyPresentationRequest(fences: testPresentationFences(),
            release: release,
            delivery: snapshot.profile.delivery,
            screenId: "screen_welcome",
            owner: .init(
                journeyId: "journey",
                distinctId: "customer"
            ),
            reservation: nil,
            onScreenChanged: { _ in true },
            onEmissionBatch: { batch, _ in
                await recorder.accept(batch)
            },
            onOutcome: { _, _ in true }
        )
        let delegate = await MainActor.run {
            JourneyRuntimeDelegate(request: request)
        }
        let controller = await MainActor.run {
            MockExperienceViewController(mockExperienceVersionId: "version_golden")
        }

        await delegate.experienceViewController(
            controller,
            didChangeScreen: "screen_welcome"
        )
        let staleBatch = presentationBatch(
            request: request,
            presentationEpoch: 1,
            invocationId: "stale-return",
            emissions: []
        )
        await delegate.experienceViewController(
            controller,
            didChangeScreen: "screen_details"
        )
        await delegate.experienceViewController(
            controller,
            didChangeScreen: "screen_welcome"
        )

        let staleAccepted = await delegate.experienceViewController(
            controller,
            didEmitScreenEmissionBatch: staleBatch
        )
        let currentAccepted = await delegate.experienceViewController(
            controller,
            didEmitScreenEmissionBatch: presentationBatch(
                request: request,
                presentationEpoch: 3,
                invocationId: "current-return",
                emissions: []
            )
        )

        XCTAssertFalse(staleAccepted)
        XCTAssertTrue(currentAccepted)
        let invocationIds = await recorder.invocationIds()
        XCTAssertEqual(invocationIds, ["current-return"])
    }

    func testRuntimeDelegateClosesSurfaceWhenInitialLifecycleCommitIsRejected() async throws {
        let fixture = try JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = try await authenticatedRenderedSnapshot(fixture)
        let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let release = try XCTUnwrap(snapshot.releasesByDigest[
            arm.reference.descriptorSha256
        ])
        let request = JourneyPresentationRequest(fences: testPresentationFences(),
            release: release,
            delivery: snapshot.profile.delivery,
            screenId: "screen_welcome",
            owner: .init(
                journeyId: "journey",
                distinctId: "customer"
            ),
            reservation: nil,
            onScreenChanged: { _ in false },
            onEmissionBatch: { _, _ in true },
            onOutcome: { outcome, _ in outcome == .abandoned }
        )
        let delegate = await MainActor.run {
            JourneyRuntimeDelegate(request: request)
        }
        let controller = await MainActor.run {
            MockExperienceViewController(mockExperienceVersionId: "version_golden")
        }

        await delegate.experienceViewController(
            controller,
            didChangeScreen: "screen_welcome"
        )

        let reasons = await MainActor.run { controller.performDismissReasons }
        XCTAssertEqual(reasons.count, 1)
        guard case .error(ExperienceError.invalidManifest)? = reasons.first else {
            return XCTFail("Expected invalid-manifest dismissal")
        }
    }

    func testRuntimeDelegateClosesSurfaceWhenProductFailureCannotBeCommitted() async throws {
        let fixture = try JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = try await authenticatedRenderedSnapshot(fixture)
        let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let release = try XCTUnwrap(snapshot.releasesByDigest[
            arm.reference.descriptorSha256
        ])
        let request = JourneyPresentationRequest(fences: testPresentationFences(),
            release: release,
            delivery: snapshot.profile.delivery,
            screenId: "screen_welcome",
            owner: .init(
                journeyId: "journey",
                distinctId: "customer"
            ),
            reservation: nil,
            onProductsUnavailable: { _ in .rejected },
            onEmissionBatch: { _, _ in true },
            onOutcome: { outcome, _ in outcome == .abandoned }
        )
        let delegate = await MainActor.run {
            JourneyRuntimeDelegate(request: request)
        }
        let controller = await MainActor.run {
            MockExperienceViewController(mockExperienceVersionId: "version_golden")
        }

        await delegate.experienceViewController(
            controller,
            didFailToResolveProductsFor: "screen_welcome"
        )

        let reasons = await MainActor.run { controller.performDismissReasons }
        XCTAssertEqual(reasons.count, 1)
        guard case .error(ExperienceError.productsUnavailable)? = reasons.first else {
            return XCTFail("Expected products-unavailable dismissal")
        }
    }

    func testProductResolutionFailureRoutesThroughTheRuntimeDelegateAndCompletes() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = try await authenticatedRenderedSnapshot(fixture)
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let presenter = await MainActor.run { RecordingJourneyPresenter() }
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            presenter: presenter
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        let presentedRequest = await MainActor.run { presenter.request }
        let request = try XCTUnwrap(presentedRequest)
        let completionCommitted = expectation(description: "product failure completed")
        events.addEventHandler(pattern: JourneyEvents.journeyCompleted) { _ in
            completionCommitted.fulfill()
        }
        let delegate = await MainActor.run {
            JourneyRuntimeDelegate(request: request)
        }
        let controller = await MainActor.run {
            MockExperienceViewController(mockExperienceVersionId: "version_golden")
        }

        await delegate.experienceViewController(
            controller,
            didFailToResolveProductsFor: "screen_welcome"
        )
        await fulfillment(of: [completionCommitted], timeout: 2)

        let dismissalReasons = await MainActor.run {
            controller.performDismissReasons
        }
        let finishedOwners = await MainActor.run {
            presenter.finishedOwners
        }
        XCTAssertEqual(dismissalReasons.count, 1)
        if let reason = dismissalReasons.first, case .error = reason {
            // Expected: teardown is queued only after the product callback
            // returns to the navigation drain.
        } else {
            XCTFail("Expected product failure to request error dismissal")
        }
        XCTAssertTrue(finishedOwners.isEmpty)

        XCTAssertEqual(events.routedEvents.map(\.name), [
            JourneyEvents.journeyStarted,
            SystemEventNames.productsUnavailable,
            JourneyEvents.journeyCompleted,
        ])
        let unavailable = try XCTUnwrap(events.routedEvents.first {
            $0.name == SystemEventNames.productsUnavailable
        })
        XCTAssertEqual(
            Set(unavailable.properties["product_ids"] as? [String] ?? []),
            ["monthly", "yearly"]
        )
        XCTAssertEqual(
            unavailable.properties["experience_version_id"] as? String,
            "version_golden"
        )
        XCTAssertEqual(
            events.routedEvents.last?.properties["outcome"] as? String,
            "products_unavailable"
        )
    }
}

private struct PurchaseReferenceScopes: Decodable {
    let values: [[String: JourneyReleaseJSONValue]]
    let cases: [Case]

    struct Case: Decodable {
        let name: String
        let reference: JourneyReleaseJSONValue
        let instanceId: String?
        let expected: String?
    }
}

private final class OpenedLinkRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var links: [ExperienceRendererOpenLinkRequest] = []
    func append(_ link: ExperienceRendererOpenLinkRequest) { lock.withLock { links.append(link) } }
    func values() -> [ExperienceRendererOpenLinkRequest] { lock.withLock { links } }
}

#if canImport(UIKit)
@MainActor
private final class OccupiedLinkController: MockExperienceViewController {
    private let occupied = UIViewController()
    override var presentedViewController: UIViewController? { occupied }
}
#endif

private struct FilePaywallSelectionScenario: Decodable {
    let screen: Journey.Screen
    let viewModelValues: [[String: JourneyReleaseJSONValue]]
    let purchaseReference: JourneyReleaseJSONValue
    let initialPlacement: String
    let writes: [Write]

    struct Write: Decodable {
        let selectedProductId: String
        let expectedPlacement: String?
    }
}

@MainActor
private final class PaywallValueRecordingController: MockExperienceViewController {
    private(set) var recordedValues: [JourneyViewModelValue] = []
    private(set) var writingScreens: [String?] = []
    override func applyViewModelValue(path: VmPathRef, value: Any, screenId: String? = nil, instanceId: String? = nil) {
        writingScreens.append(screenId)
        recordedValues.append(.init(viewModelName: path.viewModelName ?? "Runtime", instanceId: instanceId,
                                    path: path.path, value: AnyCodable(value)))
    }
}
