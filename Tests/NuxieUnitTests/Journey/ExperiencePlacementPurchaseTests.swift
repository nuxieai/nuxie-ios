import Foundation
import XCTest
@_spi(Testing) @testable import Nuxie
@testable import NuxieTestSupport

final class ExperiencePlacementPurchaseTests: JourneyTestCase {
    @MainActor
    func testNativePlanThenBuyDispatchesEachPlacementOfOneProduct() async throws {
        let writer = ProcessInfo.processInfo.environment["NUXIE_E2E_PAYWALL_WRITER"] ?? "placement"
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/runtime/paywall-two-placement-\(writer)")
        let values = try JSONDecoder().decode([JourneyViewModelValue].self,
            from: Data(contentsOf: directory.appendingPathComponent("view-model-values.json")))
        let payload = try await statePayload(defaultViewModelName: "Runtime", values: values,
            scene: Data(contentsOf: directory.appendingPathComponent("screen.riv")), artboardName: "Paywall")
        let screen = try await ExperienceInteractiveScreen.open(payload: payload, pixelWidth: 320, pixelHeight: 150)
        let snapshot = replacing(try await authenticatedRenderedSnapshot(JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")),
            screens: [.init(id: "state-screen", defaultViewModelName: "Runtime", defaultInstanceId: "root-sdk-id", responseCaptures: [])],
            viewModelValues: try JSONDecoder().decode([[String: JourneyReleaseJSONValue]].self, from: JSONEncoder().encode(values)))
        let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let release = try XCTUnwrap(snapshot.releasesByDigest[arm.reference.descriptorSha256])
        let identity = MockIdentityService(); identity.setDistinctId("customer")
        let events = MockEventLog(); events.identity = identity
        let controller = PlacementPurchaseController(mockExperienceVersionId: release.descriptor.identity.experienceVersionId, mockScreenId: "state-screen")
        let experiences = MockExperienceService()
        experiences.mockViewControllers[release.descriptor.identity.experienceVersionId] = controller
        let service = ExperiencePresentationService(windowProvider: MockWindowProvider(), experiences: experiences, eventLog: events, identity: identity)
        let owner = JourneyPresentationOwner(journeyId: "journey", distinctId: "customer")
        let request = JourneyPresentationRequest(fences: testPresentationFences(), release: release, delivery: snapshot.profile.delivery,
            screenId: "state-screen", owner: owner, reservation: service.reserveJourneyPresentation(ownerDistinctId: "customer"),
            onEmissionBatch: { _, _ in true }, onOutcome: { _, _ in true })
        let shown = await service.presentJourney(request)
        XCTAssertEqual(shown, .shown)
        await controller.runtimeDelegate?.experienceViewController(controller, didChangeScreen: "state-screen")
        for _ in 0..<20 { _ = try await screen.step(elapsedSeconds: 0.016) }
        func tap(_ x: Float, _ y: Float) async throws -> [ExperienceInteractiveEffect] {
            let down = try await screen.step(pointers: [.init(kind: .down, x: x, y: y)], elapsedSeconds: 0)
            let up = try await screen.step(pointers: [.init(kind: .up, x: x, y: y, timestamp: 0.1)], elapsedSeconds: 0)
            let settled = try await screen.step(elapsedSeconds: 0.016)
            return down.effects + up.effects + settled.effects
        }
        let purchase: [String: JourneyReleaseJSONValue] = ["type": .string("purchase"), "placementId": .object([
            "ref": .object(["kind": .string("path"), "path": .string("paywall.selectedProduct.placementId"), "isRelative": .bool(false)])])]
        for (index, plan) in [(0, "annual"), (1, "monthly")] {
            for effect in try await tap(plan == "annual" ? 240 : 80, 40) {
                guard case .viewModelChange(let change) = effect.kind, change.origin == .runtime else { continue }
                let resolved = try await screen.resolveViewModelChange(change)
                let value: Any
                switch resolved.value {
                case .string(let text): value = text
                case .bytes(let bytes): value = bytes
                default: continue
                }
                controller.runtimeDelegate?.experienceViewController(controller, didEmitViewModelChange:
                    .init(path: .init(viewModelName: resolved.viewModelName, path: resolved.path), value: value,
                        source: "runtime", screenId: "state-screen", instanceId: resolved.instanceID, isTrigger: false))
            }
            for update in try ExperienceInteractiveStateCompiler.signedValues(controller.takeFeedback()) {
                _ = try await screen.applyStateCommand(.value(update))
            }
            let buy = try await tap(160, 120)
            XCTAssertTrue(buy.contains { if case .controlAction(let id, _) = $0.kind { return id == "buy" }; return false }, "Buy must come from a native pointer")
            let action = service.resolveJourneyPresentationAction(owner: owner, action: purchase,
                source: .init(screenId: "state-screen", actionId: "buy", componentId: "buy"), eventSource: nil)
            XCTAssertEqual(action?["placementId"], .string("placement-\(plan)"))
            if let action {
                let result = await service.dispatchJourneyPresentationAction(owner: owner, action: action, effectId: "buy-\(index)")
                XCTAssertEqual(result, .awaitingOutcome)
            }
        }
        XCTAssertEqual(controller.purchases, ["placement-annual", "placement-monthly"])
        await service.shutdownJourneyPresentation(ownerDistinctId: "customer")
        try await screen.close()
    }
}

@MainActor
private final class PlacementPurchaseController: MockExperienceViewController {
    private(set) var purchases: [String] = []
    private(set) var feedback: [JourneyViewModelValue] = []
    func takeFeedback() -> [JourneyViewModelValue] {
        let values = feedback
        feedback.removeAll()
        return values
    }
    override func performPurchase(placementId: String, outcomeCorrelation: CommerceOutcomeCorrelation?) { purchases.append(placementId) }
    override func applyViewModelValue(path: VmPathRef, value: Any, screenId: String? = nil, instanceId: String? = nil) {
        feedback.append(.init(viewModelName: path.viewModelName ?? "Runtime", instanceId: instanceId, path: path.path, value: AnyCodable(value)))
    }
}
