#if os(iOS) && !targetEnvironment(macCatalyst)
import Foundation
import UIKit
import XCTest
@_spi(Testing) @testable import Nuxie

@MainActor
final class ExperienceScreenExitReasonControllerTests: XCTestCase {
    func testControllerWritesBothReasonsAndKeepsLegacyLifecycleWritesWorking() async throws {
        for variant in ["dismissed-only", "field-absent"] {
            try await withController(variant) { controller in
                XCTAssertEqual(try self.field(controller, "lifecycleIncludesExitReason", as: Bool.self),
                               variant == "dismissed-only")
                for reason in [ExperienceScreenExitReason.navigation, .dismissed] {
                    await controller.enter(reduceMotion: false)
                    await controller.activate(reduceMotion: false)
                    await controller.markExiting(reduceMotion: false, exitReason: reason)
                    let values = try await self.screenValues(controller)
                    XCTAssertEqual(values["phase"], .integer(3))
                    if variant == "dismissed-only" {
                        XCTAssertEqual(values["exitReason"], .integer(reason == .dismissed ? 1 : 2))
                    } else {
                        XCTAssertNil(values["exitReason"])
                    }
                    await controller.hide(reduceMotion: false)
                }
                await controller.enter(reduceMotion: false)
                await controller.activate(reduceMotion: false)
                await controller.updateReduceMotion(true)
                let values = try await self.screenValues(controller)
                XCTAssertEqual(values["phase"], .integer(2))
                XCTAssertEqual(values["appearances"], .number(3))
                XCTAssertFalse(try self.field(controller, "lifecycleWritesUnavailable", as: Bool.self),
                               "The legacy path must omit the undeclared field, not reject the lifecycle batch")
            }
        }
    }

    func testDismissedOnlyNavigationReturnsOnTheImmediateNativeCompletion() async throws {
        try await withController("dismissed-only") { controller in
            await controller.enter(reduceMotion: false)
            await controller.activate(reduceMotion: false)
            let screen = try self.field(controller, "screen", as: NativeExperienceScreen.self)
            let declaration = try XCTUnwrap(screen.exit)
            let watchdog = try XCTUnwrap(ExperienceScreenExitPlan(
                declaration: declaration, reduceMotion: false
            ).watchdogMilliseconds)
            let completion = controller.registerCompletionWaiter(eventName: declaration.completeEventName)
            let started = ProcessInfo.processInfo.systemUptime
            await controller.performExitHandshake(reduceMotion: false, exitReason: .navigation)
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            controller.removeCompletionWaiter(completion)
            var events = completion.stream.makeAsyncIterator()
            let nativeCompletion = await events.next()
            XCTAssertNotNil(nativeCompletion, "The zero-delta navigation step must emit completion")
            XCTAssertLessThan(elapsed, Double(watchdog) / 1_000, "Navigation must not wait for the watchdog")
            let values = try await self.screenValues(controller)
            XCTAssertEqual(values["exitReason"], .integer(2))
        }
    }

    func testCoordinatorDismissalWritesDismissedThroughTheController() async throws {
        try await withCoordinator { coordinator, source, probe in
            let finished = self.expectation(description: "bounded dismissal finishes")
            var closed = false
            let close = Task { @MainActor in
                await coordinator.exitActiveScreenForTeardown(reason: nil)
                closed = true
                finished.fulfill()
            }
            defer { close.cancel() }
            try await self.waitUntil {
                if closed { return true }
                return try await self.screenValues(source)["exitReason"] == .integer(1)
            }
            XCTAssertFalse(closed, "Dismissal must perform its exit handshake before hiding")
            XCTAssertEqual(source.lifecyclePhase, .exiting)
            XCTAssertEqual(source.lifecycleExitReason, .dismissed)
            await self.fulfillment(of: [finished], timeout: 2)
            if !closed { close.cancel() }
            await close.value
            XCTAssertEqual(source.lifecyclePhase, .hidden)
            XCTAssertEqual(probe.hidden, [source.screenId])
        }
    }

    func testCloseCancelsNavigationAndRunsTheDismissalHandshake() async throws {
        try await withCoordinator { coordinator, source, probe in
            // Warm both controllers before holding the source's ordinary runtime lane.
            try await self.navigate(coordinator, to: "reason-target")
            try await self.navigate(coordinator, to: source.screenId)
            probe.hidden.removeAll()
            probe.active.removeAll()
            let loop = try self.field(source, "presentationLoop", as: ExperienceRuntimePresentationLoop.self)
            let gate = AsyncStream<Void>.makeStream()
            defer { gate.continuation.yield(()); gate.continuation.finish() }
            XCTAssertTrue(loop.enqueue(ExperienceRuntimePresentationQueuedWork {
                for await _ in gate.stream { break }
                return .work(requestsFrame: false) {}
            }))
            var navigationResult: ExperienceScreenNavigationResult?
            XCTAssertTrue(coordinator.navigate(to: "reason-target", transition: nil) { result, _ in
                navigationResult = result
            })
            try await self.waitUntil { source.lifecyclePhase == .exiting }
            XCTAssertEqual(source.lifecycleExitReason, .navigation,
                           "The coordinator must label its navigation exit")
            let finished = self.expectation(description: "Close finishes after cancelling navigation")
            var closed = false
            let close = Task { @MainActor in
                await coordinator.exitActiveScreenForTeardown(reason: nil)
                closed = true
                finished.fulfill()
            }
            defer { close.cancel() }
            try await self.waitUntil {
                let task: Task<Void, Never> = try self.field(coordinator, "navigationTask", as: Task<Void, Never>.self)
                return task.isCancelled
            }
            gate.continuation.yield(())
            gate.continuation.finish()
            try await self.waitUntil {
                if closed { return true }
                return try await self.screenValues(source)["exitReason"] == .integer(1)
            }
            XCTAssertFalse(closed, "Close must run the dismissed handshake, not just hide a navigation exit")
            XCTAssertEqual(source.lifecyclePhase, .exiting)
            XCTAssertEqual(source.lifecycleExitReason, .dismissed)
            await self.fulfillment(of: [finished], timeout: 2)
            if !closed { close.cancel() }
            await close.value
            XCTAssertEqual(navigationResult, .failed)
            XCTAssertEqual(coordinator.activeScreenId, source.screenId)
            XCTAssertEqual(source.lifecyclePhase, .hidden)
            XCTAssertEqual(probe.hidden, [source.screenId])
            XCTAssertTrue(probe.active.isEmpty, "The cancelled drain must not activate the destination")
        }
    }

    #if NUXIE_HOSTED_INPUT_TESTS
    func testAuthoredLayerCloseWaitsForDismissedExitWithNativeSheetStillMounted() async throws {
        try await withCoordinator(useNativeWindow: true) { coordinator, source, probe in
            try await self.navigate(coordinator, to: source.screenId,
                transition: ["type": "modal", "present": "sheet", "closedby": "none"])
            let layers = try self.field(coordinator, "navigationLayers", as: [UINavigationController].self)
            let sheet = try XCTUnwrap(layers.last)
            let closing = try XCTUnwrap(sheet.topViewController as? ExperienceScreenViewController)
            XCTAssertFalse(closing === source)
            let close = Task { @MainActor in await coordinator.closeTopLayer() }
            try await self.waitUntil { closing.lifecyclePhase == .exiting }
            XCTAssertEqual(closing.lifecycleExitReason, .dismissed)
            XCTAssertNotNil(sheet.presentingViewController, "Authored exit draws in the retained native sheet")
            XCTAssertEqual(source.lifecyclePhase, .active)
            let closed = await close.value
            XCTAssertTrue(closed)
            XCTAssertEqual(coordinator.layerScreenIds, [[source.screenId]])
            XCTAssertNil(sheet.presentingViewController)
            XCTAssertEqual(source.lifecyclePhase, .active)
            XCTAssertEqual(probe.active.filter { $0 == source.screenId }.count, 2,
                "One modal activation and one routing reveal, without re-entering the retained screen")
        }
    }

    func testCompletedSwipeSupersedesNavigationExitWithoutReactivatingTheRemovedLayer() async throws {
        try await withCoordinator(useNativeWindow: true) { coordinator, source, probe in
            try await self.navigate(coordinator, to: source.screenId,
                transition: ["type": "modal", "present": "sheet"])
            let layers = try self.field(coordinator, "navigationLayers", as: [UINavigationController].self)
            let sheet = try XCTUnwrap(layers.last)
            let closing = try XCTUnwrap(sheet.topViewController as? ExperienceScreenViewController)
            let presentation = try XCTUnwrap(sheet.presentationController)
            var result: ExperienceScreenNavigationResult?
            XCTAssertTrue(coordinator.navigate(to: "reason-target", transition: nil) { value, _ in result = value })
            try await self.waitUntil { closing.lifecyclePhase == .exiting }
            await withCheckedContinuation { continuation in sheet.dismiss(animated: false) { continuation.resume() } }
            coordinator.presentationControllerDidDismiss(presentation)
            try await self.waitUntil { result != nil }
            XCTAssertEqual(result, .superseded)
            XCTAssertEqual(coordinator.layerScreenIds, [[source.screenId]])
            XCTAssertEqual(source.lifecyclePhase, .active)
            XCTAssertFalse(probe.active.contains("reason-target"))
        }
    }
    #endif

    private func field<T>(_ value: Any, _ name: String, as type: T.Type) throws -> T {
        try XCTUnwrap(Mirror(reflecting: value).children.first { $0.label == name }?.value as? T)
    }

    private func screenValues(_ controller: ExperienceScreenViewController) async throws
        -> [String: ExperienceInteractiveViewModelValue] {
        let snapshot = try await controller.runtimeSnapshot()
        let group = try XCTUnwrap(snapshot.values.first {
            $0.ownerInstanceID == snapshot.rootInstanceID && $0.name == "screen"
        })
        guard case .referencedInstance(let owner) = group.value else {
            throw CocoaError(.coderInvalidValue)
        }
        return Dictionary(uniqueKeysWithValues: snapshot.values.filter { $0.ownerInstanceID == owner }
            .map { ($0.name, $0.value) })
    }

    private func waitUntil(_ condition: @MainActor () async throws -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while ProcessInfo.processInfo.systemUptime < deadline {
            if try await condition() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Controller did not reach the expected lifecycle edge")
        throw CocoaError(.coderInvalidValue)
    }

    private func navigate(_ coordinator: ExperienceScreenTransitionCoordinator, to screenID: String, transition: Any? = nil) async throws {
        let finished = expectation(description: "navigate to \(screenID)")
        var result: ExperienceScreenNavigationResult?
        XCTAssertTrue(coordinator.navigate(to: screenID, transition: transition) { value, _ in
            result = value
            finished.fulfill()
        })
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(result, .navigated)
    }

    private func withController(
        _ variant: String,
        body: @MainActor (ExperienceScreenViewController) async throws -> Void
    ) async throws {
        let fixture = try await fixture(variant)
        let controller = ExperienceScreenViewController(
            experience: fixture.0, artifact: fixture.1,
            screen: try XCTUnwrap(fixture.1.renderPlan.screens.first), reduceMotion: false,
            usesSystemDisplayLink: false, acquireDrawable: { _ in nil }, delegate: nil
        )
        try await controller.mountInteractiveScreen()
        do { try await body(controller) }
        catch { await controller.shutdownInteractiveScreen(); throw error }
        await controller.shutdownInteractiveScreen()
        XCTAssertFalse(try field(controller, "lifecycleIncludesExitReason", as: Bool.self))
    }

    private func withCoordinator(
        useNativeWindow: Bool = false,
        body: @MainActor (ExperienceScreenTransitionCoordinator, ExperienceScreenViewController, ExitReasonProbe) async throws -> Void
    ) async throws {
        let fixture = try await fixture("dismissed-only")
        let host = UIViewController()
        host.loadViewIfNeeded()
        host.view.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        var window: UIWindow?
        var previousKey: UIWindow?
        if useNativeWindow {
            let scene = try XCTUnwrap(UIApplication.shared.activeWindowScene)
            previousKey = scene.windows.first(where: \.isKeyWindow)
            window = UIWindow(windowScene: scene)
            window?.rootViewController = host
            window?.makeKeyAndVisible()
        }
        defer { window?.isHidden = true; previousKey?.makeKey(); _ = host.view }
        let probe = ExitReasonProbe()
        let coordinator = ExperienceScreenTransitionCoordinator(
            experience: fixture.0, artifact: fixture.1, hostViewController: host, screenDelegate: probe,
            onPresentedScreenDismissed: { _, _ in },
            onScreenHidden: { id, _ in probe.hidden.append(id) },
            onScreenActive: { probe.active.append($0) },
            onProductsResolved: { _ in }, onProductsUnavailable: { _ in XCTFail("Unexpected products") },
            onRuntimeFailure: { _, error in probe.failures.append(error) }
        )
        try await coordinator.install()
        if useNativeWindow { coordinator.setContentHidden(false) }
        _ = await coordinator.activateInitialScreen()
        probe.active.removeAll()
        // The coordinator keeps one controller cache per presentation layer; the entry screen is in the base layer.
        let layerCaches = try field(coordinator, "layerCaches", as: [Any].self)
        let controllers = try field(XCTUnwrap(layerCaches.first), "controllers",
                                    as: [String: ExperienceScreenViewController].self)
        let source = try XCTUnwrap(controllers[fixture.1.renderPlan.entry.screenId])
        do { try await body(coordinator, source, probe) }
        catch { await coordinator.tearDown(); throw error }
        XCTAssertTrue(probe.failures.isEmpty)
        await coordinator.tearDown()
    }

    private func fixture(_ variant: String) async throws -> (Experience, LoadedExperienceArtifact) {
        let directory = experiencePreparationRepositoryRoot()
            .appendingPathComponent("fixtures/runtime/screen-exit-reason/\(variant)")
        let descriptor = try XCTUnwrap(JSONSerialization.jsonObject(with:
            Data(contentsOf: directory.appendingPathComponent("mounted-screen.json"))) as? [String: Any])
        let leg = try XCTUnwrap(descriptor["leg"] as? [String: Any])
        let binding = try XCTUnwrap((leg["screens"] as? [[String: Any]])?.first)
        let name = try XCTUnwrap(binding["defaultViewModelName"] as? String)
        let sourceID = try XCTUnwrap(binding["id"] as? String)
        let render = try XCTUnwrap(descriptor["render"] as? [String: Any])
        let mounted = try XCTUnwrap((render["screens"] as? [[String: Any]])?.first)
        let exit = try (mounted["exit"] as? [String: Any]).map {
            NativeExperienceScreenExit(completeEventName: try XCTUnwrap($0["completeEventName"] as? String),
                                       durationMs: try XCTUnwrap($0["durationMs"] as? Int))
        }
        let base = try await statePayload(defaultViewModelName: name, values: [],
            scene: Data(contentsOf: directory.appendingPathComponent("screen.nux")), artboardName: "tap")
        let screens = [sourceID, "reason-target"].map { id in
            NativeExperienceScreen(screenId: id, artboardId: "tap", artboardName: "tap", width: 100, height: 100,
                                   exit: id == sourceID ? exit : nil)
        }
        let payload = AuthenticatedRuntimePayload(
            authenticatedKeyID: base.authenticatedKeyID,
            renderPlan: NativeExperienceRenderPlan(identity: base.renderPlan.identity, scene: base.renderPlan.scene,
                entry: .init(screenId: sourceID), screens: screens, transitions: [], textInputs: [], images: [], fonts: []),
            journey: JourneyDocument(screens: screens.map {
                JourneyScreen(id: $0.screenId, defaultViewModelName: name, defaultInstanceId: "root-sdk-id")
            }, viewModelValues: []), sceneBytes: base.sceneBytes, assets: base.assets
        )
        let experience = Experience(id: "state-experience", versionId: "exit-reason-version", buildId: "state-build",
            artifactContentHash: nil, authenticatedReleaseID: nil, behaviorPresentation: .standard,
            behaviorPresentationScreens: [:], assetBaseURL: directory, journey: payload.journey, definition: nil)
        let acquired = AcquiredExperienceArtifact(identity: .init(experienceId: experience.id, buildId: experience.buildId),
            sceneURL: directory.appendingPathComponent("screen.nux"), sceneBytes: payload.sceneBytes,
            assetURLsByUniqueName: [:], source: .cache, payload: payload,
            interactivePreparation: .init(cache: ExperienceInteractivePreparationCache(),
                provenance: "exit-reason-controller-\(UUID().uuidString)", payload: payload),
            products: [], resourceMetrics: .zero)
        return (experience, LoadedExperienceArtifact(acquired: acquired))
    }
}

@MainActor
private final class ExitReasonProbe: ExperienceScreenViewControllerDelegate {
    var hidden: [String] = []
    var active: [String] = []
    var failures: [Error] = []
    func experienceScreenViewControllerDidAdvance(_ controller: ExperienceScreenViewController) {}
    func screenEmissionRun(for controller: ExperienceScreenViewController) -> ScreenEmissionRun? { nil }
    func experienceScreenViewController(_ controller: ExperienceScreenViewController,
        didEmitScreenEmission input: ExperienceRuntimeScreenEmission, originatingRun: ScreenEmissionRun?, frameSources: ExperienceEmissionSources?) async {}
    func experienceScreenViewController(_ controller: ExperienceScreenViewController,
        didEmitViewModelChange change: ExperienceRendererViewModelChange) {}
    func experienceScreenViewController(_ controller: ExperienceScreenViewController,
        didRequestOpenLink request: ExperienceRendererOpenLinkRequest) async {}
    func experienceScreenViewController(_ controller: ExperienceScreenViewController,
        didPresentDrawable drawable: ExperienceRuntimePresentedDrawable, frameNumber: UInt64) {}
    func experienceScreenViewController(_ controller: ExperienceScreenViewController,
        didAcceptPointerInput input: ExperienceRuntimeAcceptedPointerInput) {}
}
#endif
