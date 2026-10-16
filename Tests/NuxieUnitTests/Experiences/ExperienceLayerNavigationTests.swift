#if canImport(UIKit) && NUXIE_HOSTED_INPUT_TESTS
import UIKit
import XCTest
@_spi(Testing) @testable import Nuxie
@testable import NuxieTestSupport

final class ExperienceLayerNavigationTests: XCTestCase {
    @MainActor
    func testSharedLayerVectorsUseNativeNavigationStacksAndSeparateCopies() async throws {
        struct Transition: Decodable {
            let type: String
            let transitionId: String?
            var raw: [String: Any] {
                var result: [String: Any] = ["type": type]
                if let transitionId { result["transitionId"] = transitionId }
                return result
            }
        }
        struct Step: Decodable {
            let transition: Transition?
            let operation: String
            let screen: String?
            let count: Int?
            let layers: [[String]]
        }
        struct Case: Decodable { let name: String; let root: String; let steps: [Step] }
        struct Vector: Decodable { let cases: [Case] }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let vector = try JSONDecoder().decode(Vector.self, from: Data(contentsOf:
            root.appendingPathComponent("fixtures/journeys/planes/presentation-layers.json")))
        for item in vector.cases {
            let (experience, artifact) = try await TestExperienceRuntimeFixture.purchase(navigation: true)
            let host = UIViewController()
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
                "Layer navigation requires the app-hosted UIKit test target")
            let previousKey = scene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
            let presenter = UIViewController()
            window.rootViewController = presenter
            window.makeKeyAndVisible()
            host.modalPresentationStyle = .fullScreen
            await withCheckedContinuation { continuation in
                presenter.present(host, animated: false) { continuation.resume() }
            }
            let delegate = LayerNavigationDelegate()
            var lifecycle: [String] = []
            var reveal: XCTestExpectation?
            let coordinator = ExperienceScreenTransitionCoordinator(
                experience: experience, artifact: artifact, initialScreenID: item.root,
                hostViewController: host, screenDelegate: delegate,
                onPresentedScreenDismissed: { hidden, shown in
                    lifecycle.append("hidden:\(hidden):revealing:\(shown ?? "")")
                }, onScreenHidden: { hidden, _ in lifecycle.append("hidden:\(hidden)") },
                onScreenActive: { screen in
                    lifecycle.append("active:\(screen)")
                    reveal?.fulfill()
                    reveal = nil
                }, onProductsResolved: { _ in }, onProductsUnavailable: { _ in },
                onRuntimeFailure: { _, error in XCTFail("Layer runtime failure: \(error)") })
            addTeardownBlock {
                await coordinator.tearDown()
                await MainActor.run { window.isHidden = true; previousKey?.makeKey() }
            }
            try await coordinator.install()
            coordinator.setContentHidden(false)
            _ = await coordinator.activateInitialScreen()
            let base = try XCTUnwrap(host.children.first as? UINavigationController)
            let original = try XCTUnwrap(base.topViewController)
            var nativeLayers = [base]
            var roots = [ObjectIdentifier(base): original]
            for step in item.steps {
                if step.operation == "close" {
                    let closing = try XCTUnwrap(nativeLayers.popLast())
                    let presentation = try XCTUnwrap(closing.presentationController)
                    let shown = try XCTUnwrap(step.layers.last?.last)
                    let hidden = try XCTUnwrap((closing.topViewController as? ExperienceScreenViewController)?.screenId)
                    await withCheckedContinuation { continuation in
                        closing.dismiss(animated: false) { continuation.resume() }
                    }
                    lifecycle.removeAll()
                    let completed = expectation(description: "Reveal after closing layer")
                    reveal = completed
                    coordinator.presentationControllerDidDismiss(presentation)
                    await fulfillment(of: [completed], timeout: 10)
                    XCTAssertEqual(lifecycle, ["hidden:\(hidden):revealing:\(shown)", "active:\(shown)"])
                } else {
                    let completed = expectation(description: "\(item.name): \(step.operation)")
                    let result: ExperienceScreenTransitionCoordinator.Completion = { result, _ in
                        XCTAssertTrue(result.reachedTarget)
                        completed.fulfill()
                    }
                    if step.operation == "back" {
                        let target = try XCTUnwrap(coordinator.backTarget(steps: step.count ?? 1))
                        XCTAssertTrue(coordinator.back(to: target, steps: step.count ?? 1,
                            transition: step.transition?.raw, completion: result))
                    } else {
                        let target = try XCTUnwrap(step.screen)
                        let type = step.operation == "replace" ? "none" : step.operation
                        var transition: [String: Any] = ["type": type]
                        if type == "custom" { transition["transitionId"] = "not-declared" }
                        XCTAssertTrue(coordinator.navigate(to: target, transition: transition, completion: result))
                    }
                    await fulfillment(of: [completed], timeout: 10)
                    if step.operation == "modal" {
                        let presenter = try XCTUnwrap(nativeLayers.last?.topViewController)
                        // A sheet opened over a sheet is presented from its own window.
                        let candidates = [presenter.presentedViewController,
                            nativeLayers.last?.presentedViewController, host.presentedViewController]
                            + scene.windows.map { $0.rootViewController?.presentedViewController }
                        let layer = try XCTUnwrap(candidates.compactMap { $0 as? UINavigationController }
                            .first { candidate in !nativeLayers.contains(where: { $0 === candidate }) })
                        nativeLayers.append(layer)
                        roots[ObjectIdentifier(layer)] = layer.viewControllers.first
                    }
                }
                XCTAssertEqual(nativeLayers.map { layer in
                    layer.viewControllers.compactMap { ($0 as? ExperienceScreenViewController)?.screenId }
                }, step.layers)
                XCTAssertEqual(coordinator.layerScreenIds, step.layers)
                XCTAssertTrue(base.viewControllers.first === original)
                if ["back", "replace", "fade", "custom"].contains(step.operation),
                   let layer = nativeLayers.last, step.layers.last?.count == 1,
                   let root = roots[ObjectIdentifier(layer)],
                   (root as? ExperienceScreenViewController)?.screenId == step.layers.last?.first {
                    XCTAssertTrue(layer.topViewController === root)
                }
                if nativeLayers.count > 1, step.layers.last?.last == item.root {
                    XCTAssertFalse(nativeLayers.last?.topViewController === original)
                }
            }
            await coordinator.tearDown()
            XCTAssertTrue(presenter.presentedViewController === host,
                "Coordinator teardown removes its children and upper layers, not the Experience host")
            await withCheckedContinuation { continuation in
                presenter.dismiss(animated: false) { continuation.resume() }
            }
            window.isHidden = true
            previousKey?.makeKey()
        }
    }

    @MainActor
    func testSheetOverSheetLeavesTheLowerSheetDrawnAndRevealsIt() async throws {
        let (experience, artifact) = try await TestExperienceRuntimeFixture.purchase(navigation: true)
        let scene = try XCTUnwrap(UIApplication.shared.activeWindowScene)
        let previousKey = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        let delegate = LayerNavigationDelegate()
        var swiped: [String] = []
        var revealed: XCTestExpectation?
        let coordinator = ExperienceScreenTransitionCoordinator(
            experience: experience, artifact: artifact, initialScreenID: "screen",
            hostViewController: host, screenDelegate: delegate,
            onPresentedScreenDismissed: { hidden, shown in swiped.append("\(hidden):\(shown ?? "")") },
            onScreenHidden: { _, _ in }, onScreenActive: { _ in
                revealed?.fulfill()
                revealed = nil
            }, onProductsResolved: { _ in },
            onProductsUnavailable: { _ in }, onRuntimeFailure: { _, error in XCTFail("\(error)") })
        addTeardownBlock {
            await coordinator.tearDown()
            await MainActor.run { window.isHidden = true; previousKey?.makeKey() }
        }
        try await coordinator.install()
        coordinator.setContentHidden(false)
        _ = await coordinator.activateInitialScreen()
        func open(_ screen: String) async {
            let result = await withCheckedContinuation { continuation in
                XCTAssertTrue(coordinator.navigate(to: screen, transition: ["type": "modal", "present": "sheet",
                    "height": "medium", "closedby": "any"]) { result, _ in continuation.resume(returning: result) })
            }
            XCTAssertEqual(result, .navigated)
        }
        func layers() throws -> [UINavigationController] {
            try XCTUnwrap(Mirror(reflecting: coordinator).children.first { $0.label == "navigationLayers" }?.value
                as? [UINavigationController])
        }
        await open("details")
        let lower = try XCTUnwrap(try layers().last)
        let lowerSheet = try XCTUnwrap(lower.presentationController?.presentedView)
        let lowerFrame = lowerSheet.convert(lowerSheet.bounds, to: nil)
        await open("screen")
        let upper = try XCTUnwrap(try layers().last)
        XCTAssertFalse(upper === lower)
        XCTAssertEqual(upper.modalPresentationStyle, .pageSheet)
        if #available(iOS 16.0, *) {
            XCTAssertEqual(upper.sheetPresentationController?.detents.map(\.identifier), [.medium])
        }
        // A native sheet stack would fade the medium lower sheet out under the upper one.
        XCTAssertNotNil(lowerSheet.window)
        XCTAssertFalse(lowerSheet.isHidden)
        XCTAssertEqual(lowerSheet.alpha, 1)
        XCTAssertEqual(lowerSheet.convert(lowerSheet.bounds, to: nil), lowerFrame)
        // A native swipe on the upper sheet reveals the same lower sheet where it was.
        let presentation = try XCTUnwrap(upper.presentationController)
        await withCheckedContinuation { continuation in upper.dismiss(animated: false) { continuation.resume() } }
        let reveal = expectation(description: "The lower sheet is revealed")
        revealed = reveal
        coordinator.presentationControllerDidDismiss(presentation)
        await fulfillment(of: [reveal], timeout: 10)
        XCTAssertEqual(swiped, ["screen:details"])
        XCTAssertTrue(try layers().last === lower)
        XCTAssertEqual(lowerSheet.alpha, 1)
        XCTAssertEqual(lowerSheet.convert(lowerSheet.bounds, to: nil), lowerFrame)
        XCTAssertTrue(window.isKeyWindow, "The upper sheet's window is gone and the Experience window is key again")
    }

    @MainActor
    func testAuthoredCloseRetainsActivePresenterAndClosesOnlyTheTopLayer() async throws {
        let (experience, artifact) = try await TestExperienceRuntimeFixture.purchase(navigation: true)
        let scene = try XCTUnwrap(UIApplication.shared.activeWindowScene)
        let previousKey = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = PortraitLayerHostController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        let delegate = LayerNavigationDelegate()
        var dismissals: [String] = []
        var active: [String] = []
        let coordinator = ExperienceScreenTransitionCoordinator(
            experience: experience, artifact: artifact, initialScreenID: "screen",
            hostViewController: host, screenDelegate: delegate,
            onPresentedScreenDismissed: { hidden, shown in dismissals.append("\(hidden):\(shown ?? "")") },
            onScreenHidden: { hidden, context in
                XCTAssertEqual(context.method, "journey", "Covering a screen is not a hidden edge")
                dismissals.append("\(hidden):\(context.revealingScreenId ?? "")")
            },
            onScreenActive: { active.append($0) }, onProductsResolved: { _ in },
            onProductsUnavailable: { _ in }, onRuntimeFailure: { _, error in XCTFail("\(error)") })
        try await coordinator.install()
        coordinator.setContentHidden(false)
        _ = await coordinator.activateInitialScreen()
        let base = try XCTUnwrap(host.children.first as? UINavigationController)
        let lesson = try XCTUnwrap(base.topViewController as? ExperienceScreenViewController)
        func open(_ screen: String, closedby: String, present: String = "sheet") async {
            let result = await withCheckedContinuation { continuation in
                XCTAssertTrue(coordinator.navigate(to: screen, transition: ["type": "modal", "present": present,
                    "height": "medium", "closedby": closedby]) { result, _ in continuation.resume(returning: result) })
            }
            XCTAssertEqual(result, .navigated)
        }
        await open("details", closedby: "any")
        func layers() throws -> [UINavigationController] {
            try XCTUnwrap(Mirror(reflecting: coordinator).children.first { $0.label == "navigationLayers" }?.value as? [UINavigationController])
        }
        let offerLayer = try XCTUnwrap(try layers().last)
        let offer = try XCTUnwrap(offerLayer.topViewController as? ExperienceScreenViewController)
        XCTAssertEqual(lesson.lifecyclePhase, .active)
        XCTAssertTrue(coordinator.applyValue(path: VmPathRef(viewModelName: "Plan", path: "placementId"),
            value: "covered-plan", screenId: "screen", instanceId: "plan.second"),
            "Screen-targeted feedback must reach the mounted covered layer")
        await open("screen", closedby: "none", present: "fullscreen")
        let savedLayer = try XCTUnwrap(try layers().last)
        let saved = try XCTUnwrap(savedLayer.topViewController as? ExperienceScreenViewController)
        XCTAssertEqual(savedLayer.supportedInterfaceOrientations, .portrait)
        XCTAssertEqual(savedLayer.preferredInterfaceOrientationForPresentation, .portrait)
        XCTAssertEqual(savedLayer.view.backgroundColor, UIColor(nuxieRGBAHex: experience.behaviorPresentation.backgroundColor))
        XCTAssertEqual(offer.lifecyclePhase, .active)
        XCTAssertEqual(lesson.lifecyclePhase, .active)
        func appearances(_ controller: ExperienceScreenViewController) throws -> UInt64 {
            let state = try XCTUnwrap(Mirror(reflecting: controller).children.first {
                $0.label == "lifecycleState"
            }?.value as? ExperienceScreenLifecycleState)
            return state.snapshot.appearances
        }
        let beforeReveal = try appearances(offer)
        XCTAssertEqual(beforeReveal, 1)
        let count = active.count
        let firstClosed = await coordinator.closeTopLayer()
        XCTAssertTrue(firstClosed)
        XCTAssertEqual(coordinator.layerScreenIds, [["screen"], ["details"]])
        XCTAssertTrue(offerLayer.topViewController === offer)
        XCTAssertEqual(offer.lifecyclePhase, .active)
        XCTAssertEqual(saved.lifecyclePhase, .hidden)
        XCTAssertEqual(Array(active.dropFirst(count)), ["details"])
        let afterReveal = try appearances(offer)
        XCTAssertEqual(afterReveal, beforeReveal, "Revealing the retained presenter must not enter it again")
        XCTAssertEqual(dismissals, ["screen:details"])
        let secondClosed = await coordinator.closeTopLayer()
        XCTAssertTrue(secondClosed)
        XCTAssertTrue(base.topViewController === lesson)
        XCTAssertEqual(lesson.lifecyclePhase, .active)
        let baseClosed = await coordinator.closeTopLayer()
        XCTAssertFalse(baseClosed, "No modal remains: the service completes the Experience")
        let blocker = UIViewController()
        await withCheckedContinuation { continuation in lesson.present(blocker, animated: false) { continuation.resume() } }
        let rejected = await withCheckedContinuation { continuation in
            XCTAssertTrue(coordinator.navigate(to: "details", transition: ["type": "modal"]) { result, _ in continuation.resume(returning: result) })
        }
        XCTAssertEqual(rejected, .failed)
        XCTAssertEqual(coordinator.layerScreenIds, [["screen"]])
        XCTAssertEqual(lesson.lifecyclePhase, .active)
        await withCheckedContinuation { continuation in blocker.dismiss(animated: false) { continuation.resume() } }
        await coordinator.tearDown()
        window.isHidden = true
        previousKey?.makeKey()
    }

    @MainActor
    func testFitContentRootStillHugsAfterPushAndBack() async throws {
        let directory = experiencePreparationRepositoryRoot().appendingPathComponent("fixtures/runtime/fit-content")
        let bytes = try Data(contentsOf: directory.appendingPathComponent("dynamic-child.riv"))
        let base = try await statePayload(defaultViewModelName: "Root", values: [], scene: bytes, artboardName: "Sheet")
        let rootID = base.renderPlan.entry.screenId
        let screens = base.renderPlan.screens + [NativeExperienceScreen(screenId: "child", artboardId: "Sheet",
            artboardName: "Sheet", width: 300, height: 700, exit: nil)]
        let payload = AuthenticatedRuntimePayload(authenticatedKeyID: base.authenticatedKeyID,
            renderPlan: NativeExperienceRenderPlan(identity: base.renderPlan.identity, scene: base.renderPlan.scene,
                entry: base.renderPlan.entry, screens: screens, transitions: [], textInputs: [], images: [], fonts: []),
            journey: JourneyDocument(screens: screens.map {
                JourneyScreen(id: $0.screenId, defaultViewModelName: "Root", defaultInstanceId: "root-sdk-id")
            }, viewModelValues: []), sceneBytes: bytes, assets: [])
        let experience = Experience(id: "state-experience", versionId: "fit-return", buildId: "state-build",
            artifactContentHash: nil, authenticatedReleaseID: nil, behaviorPresentation: .standard,
            behaviorPresentationScreens: [:], assetBaseURL: directory, journey: payload.journey, definition: nil)
        let acquired = AcquiredExperienceArtifact(identity: .init(experienceId: experience.id, buildId: experience.buildId),
            sceneURL: directory.appendingPathComponent("dynamic-child.riv"), sceneBytes: bytes,
            assetURLsByUniqueName: [:], source: .cache, payload: payload,
            interactivePreparation: .init(cache: ExperienceInteractivePreparationCache(),
                provenance: "fit-return-\(UUID().uuidString)", payload: payload), products: [], resourceMetrics: .zero)
        let scene = try XCTUnwrap(UIApplication.shared.activeWindowScene)
        let previousKey = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        let delegate = LayerNavigationDelegate()
        let coordinator = ExperienceScreenTransitionCoordinator(experience: experience,
            artifact: LoadedExperienceArtifact(acquired: acquired), hostViewController: host, screenDelegate: delegate,
            onPresentedScreenDismissed: { _, _ in }, onScreenHidden: { _, _ in }, onScreenActive: { _ in },
            onProductsResolved: { _ in }, onProductsUnavailable: { _ in },
            onRuntimeFailure: { _, error in XCTFail("\(error)") })
        addTeardownBlock {
            await coordinator.tearDown()
            await MainActor.run { window.isHidden = true; previousKey?.makeKey() }
        }
        try await coordinator.install()
        coordinator.setContentHidden(false)
        _ = await coordinator.activateInitialScreen()
        func navigate(_ id: String, transition: [String: String]) async {
            let result = await withCheckedContinuation { continuation in
                XCTAssertTrue(coordinator.navigate(to: id, transition: transition) { value, _ in continuation.resume(returning: value) })
            }
            XCTAssertEqual(result, .navigated)
        }
        await navigate(rootID, transition: ["type": "modal", "present": "sheet", "height": "fit-content"])
        let layers = try XCTUnwrap(Mirror(reflecting: coordinator).children.first {
            $0.label == "navigationLayers"
        }?.value as? [UINavigationController])
        let sheet = try XCTUnwrap(layers.last)
        let retainedRoot = try XCTUnwrap(sheet.topViewController)
        await navigate("child", transition: ["type": "push"])
        let backed = await withCheckedContinuation { continuation in
            XCTAssertTrue(coordinator.back(to: rootID, steps: 1) { value, _ in continuation.resume(returning: value) })
        }
        XCTAssertEqual(backed, .navigated)
        XCTAssertTrue(sheet.topViewController === retainedRoot)
        XCTAssertTrue(coordinator.applyValue(path: .init(viewModelName: "Root", path: "contentHeight"), value: 240,
            screenId: rootID, instanceId: "root-sdk-id"))
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while sheet.preferredContentSize.height != 272 && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        // Source dynamic-child layout: 16 top + mutated 240 child + 16 bottom.
        XCTAssertEqual(sheet.preferredContentSize.height, 272)
    }
}

@MainActor
private final class PortraitLayerHostController: UIViewController {
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .portrait }
}

@MainActor
private final class LayerNavigationDelegate: ExperienceScreenViewControllerDelegate {
    func experienceScreenViewControllerDidAdvance(_ controller: ExperienceScreenViewController) {}
    func screenEmissionRun(for controller: ExperienceScreenViewController) -> ScreenEmissionRun? { nil }
    func experienceScreenViewController(_ controller: ExperienceScreenViewController,
        didEmitScreenEmission input: ExperienceRuntimeScreenEmission, originatingRun: ScreenEmissionRun?, frameSources: ExperienceEmissionSources?) async {}
    func experienceScreenViewController(_ controller: ExperienceScreenViewController,
        didEmitViewModelChange change: ExperienceRendererViewModelChange) {}
    func experienceScreenViewController(_ controller: ExperienceScreenViewController,
        didRequestOpenLink request: ExperienceRendererOpenLinkRequest) {}
    func experienceScreenViewController(_ controller: ExperienceScreenViewController,
        didPresentDrawable drawable: ExperienceRuntimePresentedDrawable, frameNumber: UInt64) {}
    func experienceScreenViewController(_ controller: ExperienceScreenViewController,
        didAcceptPointerInput input: ExperienceRuntimeAcceptedPointerInput) {}
}
#endif
