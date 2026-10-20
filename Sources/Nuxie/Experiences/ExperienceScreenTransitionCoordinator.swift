#if canImport(UIKit)
import UIKit

@MainActor
final class ExperienceScreenTransitionCoordinator: NSObject, UIAdaptivePresentationControllerDelegate {
    typealias Completion = (
        _ result: ExperienceScreenNavigationResult,
        _ screenId: String
    ) -> Void

    private enum Lifecycle {
        case idle
        case installing
        case installed
        case tearingDown
        case tornDown
    }

    private struct NavigationRequest {
        let screenId: String
        let rawTransition: Any?
        let completion: Completion
        var backLayer: UINavigationController? = nil
        var backSteps: Int = 1
        var dismissLayer: Bool = false
        var admissionLayer: UINavigationController? = nil
    }

    private weak var hostViewController: UIViewController?
    private let experience: Experience
    private let artifact: LoadedExperienceArtifact
    private let runValues: ExperienceRunValues
    private let initialScreenID: String
    private let presentationDiagnosticsEnabled: Bool
    private weak var screenDelegate: ExperienceScreenViewControllerDelegate?
    private let onPresentedScreenDismissed: (
        _ dismissedScreenId: String,
        _ revealingScreenId: String?
    ) async -> Void
    private let onScreenHidden: (
        _ screenId: String,
        _ context: ExperienceScreenHiddenContext
    ) async -> Void
    private let onScreenActive: (_ screenId: String) async -> Void
    private let onProductsResolved: (_ products: [StoreProduct]) -> Void
    private let onProductsUnavailable: (_ screenId: String) async -> Void
    private let onRuntimeFailure: (_ screenId: String, _ error: Error) -> Void

    private final class ScreenCache {
        var controllers: [String: ExperienceScreenViewController] = [:]
    }

    private var navigationLayers: [UINavigationController] = []
    /// Sheet layers opened over another sheet, each presented from its own window.
    private var stackedSheetWindows: [ObjectIdentifier: ExperienceStackedSheetWindow] = [:]
    private var layerCaches: [ScreenCache] = [ScreenCache()]
    private var pendingModalCache: ScreenCache?
    private weak var closingLayer: UINavigationController?

    var hasPresentedLayer: Bool { navigationLayers.count > 1 }
    /// The top Journey layer above the base, where an in-app browser opened from it belongs.
    var topPresentedLayer: UIViewController? { hasPresentedLayer ? navigationLayers.last : nil }
    private var navigationController: UINavigationController? { navigationLayers.last }
    private var activeController: ExperienceScreenViewController? {
        navigationController?.topViewController as? ExperienceScreenViewController
    }
    private var activeCache: ScreenCache { pendingModalCache ?? layerCaches[layerCaches.count - 1] }
    private var cachedControllersByScreenId: [String: ExperienceScreenViewController] {
        get { activeCache.controllers }
        set { activeCache.controllers = newValue }
    }
    private var allScreenControllers: [ExperienceScreenViewController] {
        layerCaches.flatMap { Array($0.controllers.values) }
            + Array(pendingModalCache?.controllers.values ?? [:].values)
    }

    var layerScreenIds: [[String]] {
        navigationLayers.map { layer in
            layer.viewControllers.compactMap { ($0 as? ExperienceScreenViewController)?.screenId }
        }
    }

    func backTarget(steps: Int) -> String? {
        guard let screens = layerScreenIds.last, !screens.isEmpty else { return nil }
        return screens[max(0, screens.count - 1 - max(1, steps))]
    }
    private var mountingControllersByScreenId: [String: ExperienceScreenViewController] = [:]
    private let videoDecoderPool: ExperienceVideoDecoderPool?
    private var latestSnapshot: ExperienceViewModelSnapshot?
    private var contentHidden = true
    private var terminalScreenIds: Set<String> = []
    private var lifecycle: Lifecycle = .idle
    private var installationTask: Task<Void, Error>?
    private var navigationTask: Task<Void, Never>?
    private var teardownTask: Task<Void, Never>?
    private var navigationRequests: [NavigationRequest] = []
    /// Set when teardown begins: no drain may start and queued requests fail
    /// fast, so a cancelled task's completion cannot restart navigation.
    private var navigationAdmissionRevoked = false
    /// Marks execution ON the navigation drain task itself; teardown paths
    /// reached from inside the drain (lifecycle callback -> goal ->
    /// dismissal) must not await the task they are running on, while
    /// dismissals from other tasks still join a merely-suspended drain.
    @TaskLocal private static var isOnNavigationDrainTask = false
    private nonisolated(unsafe) var reduceMotionObserver: NSObjectProtocol?

    var activeScreenId: String? {
        activeController?.screenId
    }

    func owns(_ controller: ExperienceScreenViewController) -> Bool {
        allScreenControllers.contains { $0 === controller }
            || mountingControllersByScreenId.values.contains { $0 === controller }
    }

    init(
        experience: Experience,
        artifact: LoadedExperienceArtifact,
        runValues: ExperienceRunValues = ExperienceRunValues(),
        initialScreenID: String? = nil,
        presentationDiagnosticsEnabled: Bool = false,
        videoDecoderPool: ExperienceVideoDecoderPool? = nil,
        hostViewController: UIViewController,
        screenDelegate: ExperienceScreenViewControllerDelegate,
        onPresentedScreenDismissed: @escaping (
            _ dismissedScreenId: String,
            _ revealingScreenId: String?
        ) async -> Void,
        onScreenHidden: @escaping (
            _ screenId: String,
            _ context: ExperienceScreenHiddenContext
        ) async -> Void,
        onScreenActive: @escaping (_ screenId: String) async -> Void,
        onProductsResolved: @escaping (_ products: [StoreProduct]) -> Void,
        onProductsUnavailable: @escaping (_ screenId: String) async -> Void,
        onRuntimeFailure: @escaping (_ screenId: String, _ error: Error) -> Void
    ) {
        self.experience = experience
        self.artifact = artifact
        self.runValues = runValues
        self.initialScreenID = initialScreenID ?? artifact.renderPlan.entry.screenId
        self.presentationDiagnosticsEnabled = presentationDiagnosticsEnabled
        self.videoDecoderPool = videoDecoderPool
        self.hostViewController = hostViewController
        self.screenDelegate = screenDelegate
        self.onPresentedScreenDismissed = onPresentedScreenDismissed
        self.onScreenHidden = onScreenHidden
        self.onScreenActive = onScreenActive
        self.onProductsResolved = onProductsResolved
        self.onProductsUnavailable = onProductsUnavailable
        self.onRuntimeFailure = onRuntimeFailure
        super.init()
        reduceMotionObserver = NotificationCenter.default.addObserver(
            forName: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshReduceMotionState()
            }
        }
    }

    deinit {
        if let reduceMotionObserver {
            NotificationCenter.default.removeObserver(reduceMotionObserver)
        }
    }

    func install() async throws {
        switch lifecycle {
        case .installed:
            return
        case .installing:
            guard let installationTask else { throw CancellationError() }
            try await installationTask.value
            return
        case .tearingDown, .tornDown:
            throw CancellationError()
        case .idle:
            break
        }

        lifecycle = .installing
        let task = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            try await self.performInstall()
            // The hierarchy install after the final cancellation check is a
            // synchronous commit point. A cancellation racing that commit is
            // treated as a completed install and a later teardown owns cleanup.
            guard self.lifecycle == .installing else {
                throw CancellationError()
            }
            self.lifecycle = .installed
            self.installationTask = nil
        }
        installationTask = task
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch {
            installationTask = nil
            if lifecycle == .installing {
                lifecycle = .idle
            }
            throw error
        }
    }

    private func performInstall() async throws {
        guard let hostViewController else {
            throw ExperienceScreenTransitionCoordinatorError.hostUnavailable
        }
        guard artifact.renderPlan.screens.contains(where: {
            $0.screenId == initialScreenID
        }) else {
            throw ExperienceScreenTransitionCoordinatorError.missingScreen(initialScreenID)
        }
        let entryController = try await ensureScreenController(
            for: initialScreenID
        )
        guard lifecycle == .installing, !Task.isCancelled else {
            await entryController.shutdownInteractiveScreen()
            cachedControllersByScreenId.removeValue(forKey: entryController.screenId)
            throw CancellationError()
        }
        let navigationController = UINavigationController(rootViewController: entryController)
        navigationController.setNavigationBarHidden(true, animated: false)
        navigationController.view.translatesAutoresizingMaskIntoConstraints = false
        navigationController.view.backgroundColor = .clear
        navigationController.view.isHidden = contentHidden

        hostViewController.addChild(navigationController)
        hostViewController.view.insertSubview(navigationController.view, at: 0)
        NSLayoutConstraint.activate([
            navigationController.view.topAnchor.constraint(equalTo: hostViewController.view.topAnchor),
            navigationController.view.leadingAnchor.constraint(equalTo: hostViewController.view.leadingAnchor),
            navigationController.view.trailingAnchor.constraint(equalTo: hostViewController.view.trailingAnchor),
            navigationController.view.bottomAnchor.constraint(equalTo: hostViewController.view.bottomAnchor)
        ])
        navigationController.didMove(toParent: hostViewController)

        self.navigationLayers = [navigationController]
        navigationController.loadViewIfNeeded()
        entryController.loadViewIfNeeded()
        navigationController.view.setNeedsLayout()
        navigationController.view.layoutIfNeeded()
        entryController.setContentHidden(contentHidden)
        let initialPresentation = (hostViewController as? ExperienceViewController)?.presentationShellContract?.layer
            ?? .init(kind: .fullscreen)
        var availableSize = hostViewController.view.bounds.size
        if initialPresentation.fitsContent, let scene = UIApplication.shared.activeWindowScene {
            availableSize = try await ExperienceLayerPresentationConfigurator.availableSheetSize(in: scene, above: nil)
            guard lifecycle == .installing, !Task.isCancelled else { throw CancellationError() }
            hostViewController.view.frame.size = availableSize
            hostViewController.view.layoutIfNeeded()
        }
        try await entryController.configurePresentationHeight(initialPresentation,
            target: hostViewController, availableSize: availableSize)
        (hostViewController as? ExperienceViewController)?.resolveInitialContentHeight()
        await entryController.enter(reduceMotion: reduceMotionEnabled)
    }

    func activateInitialScreen() async -> String? {
        guard lifecycle == .installed,
              let activeScreenId,
              let controller = activeController else {
            return nil
        }
        await controller.activate(reduceMotion: reduceMotionEnabled)
        return activeScreenId
    }

    func announceInitialScreenActive(_ screenId: String) async {
        guard lifecycle == .installed,
              activeScreenId == screenId else { return }
        await onScreenActive(screenId)
    }

    func exitActiveScreenForTeardown(reason: CloseReason?, alreadyDismissed: Bool = false) async {
        // Revoke navigation admission, fail queued requests, then cancel and
        // drain the in-flight task: a suspended exit handshake or watchdog
        // must not resume - nor may a queued request restart the drain - and
        // mount a destination after the teardown hidden event.
        navigationAdmissionRevoked = true
        let queuedRequests = navigationRequests
        navigationRequests.removeAll()
        queuedRequests.forEach { $0.completion(.failed, $0.screenId) }
        if let navigationTask {
            navigationTask.cancel()
            // Awaiting our own task would deadlock when dismissal is driven
            // from a lifecycle callback executing inside the drain; the
            // revoked admission and cancellation make the drain exit on its
            // own, and performTearDown joins it outside the callback chain.
            if !Self.isOnNavigationDrainTask {
                await navigationTask.value
                self.navigationTask = nil
            }
        }
        guard lifecycle == .installed,
              let activeScreenId,
              let controller = activeController,
              controller.lifecyclePhase != .hidden else {
            return
        }
        let reduceMotion = reduceMotionEnabled
        if alreadyDismissed {
            await controller.markExiting(reduceMotion: reduceMotion, exitReason: .dismissed)
        } else if controller.lifecyclePhase != .exiting || controller.lifecycleExitReason != .dismissed {
            await controller.performExitHandshake(reduceMotion: reduceMotion, exitReason: .dismissed)
        }
        await controller.hide(reduceMotion: reduceMotion)
        await onScreenHidden(activeScreenId, .teardown(reason: reason))
    }

    func tearDown() async {
        if lifecycle == .tornDown { return }
        if let teardownTask {
            await teardownTask.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performTearDown()
        }
        teardownTask = task
        await task.value
        teardownTask = nil
    }

    private func performTearDown() async {
        lifecycle = .tearingDown
        let installationTask = installationTask
        let navigationTask = navigationTask
        installationTask?.cancel()
        navigationTask?.cancel()

        let queuedRequests = navigationRequests
        navigationRequests.removeAll()
        queuedRequests.forEach { $0.completion(.failed, $0.screenId) }

        if let installationTask {
            _ = await installationTask.result
        }
        if let navigationTask {
            await navigationTask.value
        }

        for layer in navigationLayers.reversed() {
            guard let window = stackedSheetWindows.removeValue(forKey: ObjectIdentifier(layer)) else { continue }
            window.presenter.dismiss(animated: false)
            window.close()
        }
        // Teardown is the backstop for any window a host dismissal could not close.
        for window in stackedSheetWindows.values {
            window.presenter.dismiss(animated: false)
            window.close()
        }
        stackedSheetWindows.removeAll()
        navigationLayers.dropFirst().first?.presentingViewController?.dismiss(animated: false)
        if let base = navigationLayers.first {
            base.willMove(toParent: nil)
            base.view.removeFromSuperview()
            base.removeFromParent()
        }
        navigationLayers.removeAll()

        let controllers = allScreenControllers.sorted {
            $0.screenId.utf8.lexicographicallyPrecedes($1.screenId.utf8)
        }
        layerCaches = [ScreenCache()]
        pendingModalCache = nil
        mountingControllersByScreenId.removeAll()
        latestSnapshot = nil
        for controller in controllers {
            // Covered layers remained active until the Experience closed.
            // Retire them without replaying an authored exit off screen.
            if controller.lifecyclePhase != .hidden { await controller.hide(reduceMotion: reduceMotionEnabled) }
            await controller.shutdownInteractiveScreen()
        }
        self.installationTask = nil
        self.navigationTask = nil
        lifecycle = .tornDown
    }

    func setContentHidden(_ hidden: Bool) {
        contentHidden = hidden
        navigationLayers.forEach { $0.view.isHidden = hidden }
        allScreenControllers.forEach { $0.setContentHidden(hidden) }
    }

    func layoutTextInputs() {
        allScreenControllers.forEach { $0.layoutTextInputs() }
    }

    /// Re-reads each cached screen's own view insets and pushes them into
    /// that screen's bound view-model instance. Screens read their own view
    /// (not the host's) so modal sheets and pushed screens resolve their own
    /// safe-area environment.
    func syncSafeAreaInsets() {
        allScreenControllers.forEach { $0.syncSafeAreaInsets() }
    }

    @discardableResult
    func applySnapshot(_ snapshot: ExperienceViewModelSnapshot, screenId: String?) -> Bool {
        latestSnapshot = snapshot
        var didApply = false
        for controller in allScreenControllers {
            didApply = controller.applySnapshot(snapshot, screenId: screenId) || didApply
        }
        return didApply
    }

    @discardableResult
    func applyValue(
        path: VmPathRef,
        value: Any,
        screenId: String?,
        instanceId: String?
    ) -> Bool {
        var didApply = false
        do {
            for controller in try targetControllers(for: screenId) {
                didApply = controller.applyValue(
                    path: path,
                    value: value,
                    screenId: screenId,
                    instanceId: instanceId
                ) || didApply
            }
        } catch {
            LogWarning(
                """
                ExperienceScreenTransitionCoordinator: failed to apply value \
                to screen \(screenId ?? "<all>"): \(error)
                """
            )
        }
        return didApply
    }

    @discardableResult
    func applyListOperation(
        _ operation: ExperienceViewModelListOperation,
        path: VmPathRef,
        payload: [String: Any],
        screenId: String?,
        instanceId: String?
    ) -> Bool {
        var didApply = false
        do {
            for controller in try targetControllers(for: screenId) {
                didApply = controller.applyListOperation(
                    operation,
                    path: path,
                    payload: payload,
                    screenId: screenId,
                    instanceId: instanceId
                ) || didApply
            }
        } catch {
            LogWarning(
                """
                ExperienceScreenTransitionCoordinator: failed to apply list operation \
                to screen \(screenId ?? "<all>"): \(error)
                """
            )
        }
        return didApply
    }

    @discardableResult
    func fireTrigger(path: VmPathRef, screenId: String?, instanceId: String?) -> Bool {
        var didFire = false
        do {
            for controller in try targetControllers(for: screenId) {
                didFire = controller.fireTrigger(
                    path: path,
                    screenId: screenId,
                    instanceId: instanceId
                ) || didFire
            }
        } catch {
            LogWarning(
                """
                ExperienceScreenTransitionCoordinator: failed to fire trigger \
                on screen \(screenId ?? "<all>"): \(error)
                """
            )
        }
        return didFire
    }

    @discardableResult
    func navigate(to screenId: String, transition rawTransition: Any?, completion: @escaping Completion) -> Bool {
        let spec = ExperienceScreenTransitionSpec(raw: rawTransition)
        guard spec.kind != .modal || spec.isAvailable else {
            LogWarning("ExperienceScreenTransitionCoordinator: unsupported modal presentation")
            completion(.failed, screenId)
            return false
        }
        guard lifecycle == .installed,
              !navigationAdmissionRevoked,
              artifact.renderPlan.screens.contains(where: { $0.screenId == screenId }) else {
            return false
        }

        if terminalScreenIds.contains(screenId) {
            completion(.failed, screenId)
            return false
        }

        if activeScreenId == screenId,
           spec.kind != .modal,
           navigationTask == nil,
           navigationRequests.isEmpty {
            completion(.alreadyActive, screenId)
            return true
        }

        navigationRequests.append(NavigationRequest(
            screenId: screenId,
            rawTransition: rawTransition,
            completion: completion,
            admissionLayer: navigationController
        ))
        startNavigationDrainIfNeeded()
        return true
    }

    @discardableResult
    func back(to screenId: String, steps: Int, transition: Any? = nil, completion: @escaping Completion) -> Bool {
        guard lifecycle == .installed, !navigationAdmissionRevoked,
              backTarget(steps: steps) == screenId,
              let layer = navigationController else { return false }
        if activeScreenId == screenId {
            completion(.alreadyActive, screenId)
            return true
        }
        navigationRequests.append(NavigationRequest(
            screenId: screenId,
            rawTransition: transition ?? ["type": "push"],
            completion: completion,
            backLayer: layer,
            backSteps: steps
        ))
        startNavigationDrainIfNeeded()
        return true
    }

    /// Authored dismissal joins the navigation lane and keeps the native layer
    /// alive until the top screen's declared exit completes. A dismiss issued from
    /// a screen belongs to that screen's layer: when the person has already closed
    /// it, the dismiss is superseded rather than closing the next layer down.
    func closeTopLayer(issuedFrom issuingScreenId: String? = nil) async -> ExperienceScreenNavigationResult {
        guard lifecycle == .installed, !navigationAdmissionRevoked, hasPresentedLayer,
              let screenId = activeScreenId, let layer = navigationController else { return .failed }
        if let issuingScreenId, layerScreenIds.last?.contains(issuingScreenId) != true { return .superseded }
        return await withCheckedContinuation { continuation in
            navigationRequests.append(NavigationRequest(
                screenId: screenId, rawTransition: nil,
                completion: { result, _ in continuation.resume(returning: result) },
                backLayer: layer, dismissLayer: true))
            startNavigationDrainIfNeeded()
        }
    }

    private func startNavigationDrainIfNeeded() {
        guard !navigationAdmissionRevoked,
              navigationTask == nil,
              lifecycle == .installed,
              !navigationRequests.isEmpty else {
            return
        }
        navigationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await Self.$isOnNavigationDrainTask.withValue(true) {
                await self.drainNavigationRequests()
            }
        }
    }

    private func drainNavigationRequests() async {
        while lifecycle == .installed,
              !navigationAdmissionRevoked,
              !Task.isCancelled,
              !navigationRequests.isEmpty {
            let request = navigationRequests.removeFirst()
            if let admitted = request.admissionLayer,
               !navigationLayers.contains(where: { $0 === admitted }) {
                request.completion(.superseded, request.screenId)
                continue
            }
            if let backLayer = request.backLayer,
               (backLayer !== navigationController || (!request.dismissLayer && backTarget(steps: request.backSteps) != request.screenId)) {
                request.completion(.superseded, request.screenId)
                continue
            }
            let sourceLayer = navigationController
            do {
                if request.dismissLayer {
                    let closed = await performAuthoredLayerDismissal()
                    request.completion(closed ? .navigated : .superseded, request.screenId)
                    continue
                }
                let spec = ExperienceScreenTransitionSpec(raw: request.rawTransition)
                let opensLayer = request.backLayer == nil && spec.kind == .modal
                if opensLayer { pendingModalCache = ScreenCache() }
                _ = try await ensureScreenController(for: request.screenId)
                guard lifecycle == .installed, !Task.isCancelled,
                      !navigationAdmissionRevoked, navigationController === sourceLayer else {
                    await discardPendingModal()
                    request.completion(navigationController !== sourceLayer ? .superseded : .failed, request.screenId)
                    continue
                }
                let didNavigate = try await performMountedNavigation(
                    to: request.screenId,
                    transition: request.rawTransition,
                    isBack: request.backLayer != nil
                )
                if pendingModalCache != nil { await discardPendingModal() }
                let completed = lifecycle == .installed && !Task.isCancelled
                    && !navigationAdmissionRevoked && didNavigate
                request.completion(
                    completed ? .navigated : (navigationController !== sourceLayer ? .superseded : .failed),
                    request.screenId
                )
            } catch {
                await discardPendingModal()
                if navigationController !== sourceLayer {
                    request.completion(.superseded, request.screenId)
                    continue
                }
                if case ExperienceError.productsUnavailable = error {
                    request.completion(.productsUnavailable, request.screenId)
                    for queued in navigationRequests {
                        queued.completion(.failed, queued.screenId)
                    }
                    navigationRequests.removeAll()
                    await onProductsUnavailable(request.screenId)
                    break
                }
                LogWarning(
                    "ExperienceScreenTransitionCoordinator: failed to navigate to screen \(request.screenId): \(error)"
                )
                request.completion(navigationController !== sourceLayer ? .superseded : .failed, request.screenId)
            }
        }
        navigationTask = nil
        if lifecycle == .installed, !navigationRequests.isEmpty {
            startNavigationDrainIfNeeded()
        }
    }

    private func performMountedNavigation(
        to screenId: String,
        transition rawTransition: Any?,
        isBack: Bool
    ) async throws -> Bool {
        let sourceController = activeController
        let targetController = try screenController(for: screenId)
        let reduceMotion = reduceMotionEnabled
        let navigated = try await performNavigation(
            to: screenId,
            transition: rawTransition,
            sourceController: sourceController,
            targetController: targetController,
            reduceMotion: reduceMotion,
            isBack: isBack
        )

        return navigated
    }

    private func performNavigation(
        to screenId: String,
        transition rawTransition: Any?,
        sourceController: ExperienceScreenViewController?,
        targetController: ExperienceScreenViewController,
        reduceMotion: Bool,
        isBack: Bool = false
    ) async throws -> Bool {
        let sourceLayer = navigationController
        // The screen enters in the host's appearance now, though it waited out of the
        // window (behind another, or in a cache) while it changed.
        targetController.adoptHostTraits(hostViewController?.traitCollection)
        let spec = ExperienceScreenTransitionSpec(raw: rawTransition)
        let opensLayer = spec.kind == .modal && !isBack
        // Decided once, so the size measured and the window presented from always agree.
        let stacksSheet = opensLayer && opensStackedSheet(spec.presentation)
        let isRetainedTarget = sourceLayer?.viewControllers.contains(where: { $0 === targetController }) == true
        if opensLayer {
            guard ((sourceLayer as UIViewController?) ?? hostViewController)?.presentedViewController == nil else {
                throw ExperienceScreenTransitionCoordinatorError.presenterBusy
            }
            var available = hostViewController?.view.window?.bounds.size
                ?? hostViewController?.view.bounds.size ?? targetController.view.bounds.size
            if spec.presentation.fitsContent,
               let scene = hostViewController?.view.window?.windowScene ?? UIApplication.shared.activeWindowScene {
                available = try await ExperienceLayerPresentationConfigurator.availableSheetSize(in: scene,
                    above: stacksSheet ? nil : sourceLayer ?? hostViewController)
                guard lifecycle == .installed, !Task.isCancelled else { throw CancellationError() }
                targetController.view.frame.size = available
                targetController.view.layoutIfNeeded()
            }
            try await targetController.configurePresentationHeight(spec.presentation,
                target: targetController, availableSize: available)
        } else if !isRetainedTarget, let sourceLayer {
            try await targetController.configurePresentationHeight(.init(kind: .fullscreen),
                target: sourceLayer, availableSize: sourceLayer.view.bounds.size)
        }
        if let transitionId = spec.transitionId,
           let sourceController,
           sourceController !== targetController,
           let plan = ExperienceScreenCustomTransitionPlan.resolve(
               transitionId: transitionId,
               sourceScreenId: sourceController.screenId,
               destinationScreenId: targetController.screenId,
               declarations: artifact.renderPlan.transitions,
               reduceMotion: reduceMotion
           ) {
            return try await performCustomMountedNavigation(
                sourceController: sourceController,
                targetController: targetController,
                plan: plan,
                reduceMotion: reduceMotion
            )
        }
        return try await ExperienceScreenLifecycleNavigation.perform(
            targetEntering: {
                await targetController.enter(reduceMotion: reduceMotion)
            },
            sourceExiting: {
                if opensLayer {
                    sourceController?.setCoveredByLayer(true)
                } else {
                    await sourceController?.performExitHandshake(reduceMotion: reduceMotion, exitReason: .navigation)
                }
            },
            nativeOperation: {
                guard self.lifecycle == .installed, !Task.isCancelled,
                      self.navigationController === sourceLayer else {
                    throw CancellationError()
                }
                return try await withCheckedThrowingContinuation { continuation in
                    do {
                        try self.performNativeNavigation(
                            to: screenId,
                            transition: rawTransition,
                            reduceMotion: reduceMotion,
                            isBack: isBack,
                            stacksSheet: stacksSheet
                        ) { result, _ in
                            continuation.resume(returning: result.reachedTarget)
                        }
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            },
            sourceHidden: {
                if !opensLayer, let sourceController, sourceController !== targetController {
                    await sourceController.hide(reduceMotion: reduceMotion)
                    await self.onScreenHidden(
                        sourceController.screenId,
                        .navigation(revealingScreenId: targetController.screenId)
                    )
                }
            },
            targetActive: {
                await targetController.activate(reduceMotion: reduceMotion)
                await self.onScreenActive(targetController.screenId)
            },
            restoreAfterFailure: {
                await targetController.hide(reduceMotion: reduceMotion)
                if opensLayer { sourceController?.setCoveredByLayer(false) }
                if !opensLayer, self.navigationController === sourceLayer,
                   let sourceController, sourceController !== targetController {
                    await sourceController.activate(reduceMotion: reduceMotion)
                }
            }
        )
    }

    private func performNativeNavigation(
        to screenId: String,
        transition rawTransition: Any?,
        reduceMotion: Bool,
        isBack: Bool,
        stacksSheet: Bool,
        completion: @escaping Completion
    ) throws {
        let spec = ExperienceScreenTransitionSpec(raw: rawTransition)
        let animated = spec.shouldAnimate(reduceMotion: reduceMotion)

        switch spec.effectiveKind(reduceMotion: reduceMotion) {
        case .none:
            try replaceTop(with: screenId, completion: completion)
        case .push:
            try pushOrPop(to: screenId, animated: animated, completion: completion)
        case .modal:
            if isBack {
                try pushOrPop(to: screenId, animated: animated, completion: completion)
            } else {
                try present(screenId: screenId, presentation: spec.presentation, animated: animated,
                    stacksSheet: stacksSheet, completion: completion)
            }
        case .fade:
            if animated {
                try runLiveReplacementTransition(
                    to: screenId,
                    spec: spec,
                    completion: completion
                )
            } else {
                try replaceTop(with: screenId, completion: completion)
            }
        case .custom, .magicMove:
            // A custom spec reaches this switch only when its signed manifest
            // declaration did not match the active navigation edge.
            try replaceTop(with: screenId, completion: completion)
        }
    }

    private func performCustomMountedNavigation(
        sourceController: ExperienceScreenViewController,
        targetController: ExperienceScreenViewController,
        plan: ExperienceScreenCustomTransitionPlan,
        reduceMotion: Bool
    ) async throws -> Bool {
        let sourceLayer = navigationController
        try installLiveReplacementSurface(
            sourceController: sourceController,
            targetController: targetController,
            incomingOnTop: plan.incomingOnTop
        )
        let previousInteractionEnabled = sourceController.view.isUserInteractionEnabled
        let outgoingWaiter = sourceController.registerCompletionWaiter(
            eventName: plan.outgoingCompletionEventName
        )
        let incomingWaiter = targetController.registerCompletionWaiter(
            eventName: plan.incomingCompletionEventName
        )
        defer {
            sourceController.removeCompletionWaiter(outgoingWaiter)
            targetController.removeCompletionWaiter(incomingWaiter)
        }

        let didNavigate = await ExperienceScreenCustomTransitionExecution.perform(
            setOutgoingInputEnabled: { enabled in
                sourceController.view.isUserInteractionEnabled = enabled
                    ? previousInteractionEnabled
                    : false
            },
            writePhases: {
                async let outgoingPhase: Void = sourceController.writeCustomTransitionPhase(
                    .exiting,
                    transitionId: plan.transitionId,
                    reduceMotion: reduceMotion,
                    exitReason: .navigation
                )
                async let incomingPhase: Void = targetController.writeCustomTransitionPhase(
                    .entering,
                    transitionId: plan.transitionId,
                    reduceMotion: reduceMotion,
                    exitReason: .none
                )
                _ = await (outgoingPhase, incomingPhase)
            },
            awaitCompletion: {
                await ExperienceScreenExitWatchdog.wait(
                    for: [outgoingWaiter.stream, incomingWaiter.stream],
                    watchdogMilliseconds: plan.watchdogMilliseconds
                )
            },
            finalize: {
                // A destination whose runtime failed while completions were
                // awaited must never be installed as root: its exit waiters
                // close on teardown and the wait returns normally.
                guard self.lifecycle == .installed, !Task.isCancelled,
                      self.navigationController === sourceLayer,
                      !self.terminalScreenIds.contains(targetController.screenId) else {
                    self.removeLiveReplacementSurface(controller: targetController)
                    return false
                }
                do {
                    try self.finalizeLiveReplacementSurface(controller: targetController)
                } catch {
                    self.removeLiveReplacementSurface(controller: targetController)
                    return false
                }
                return await withCheckedContinuation { continuation in
                    self.completeNavigation(to: targetController.screenId) { result, _ in
                        continuation.resume(returning: result.reachedTarget)
                    }
                }
            }
        )
        guard didNavigate else {
            await targetController.hide(reduceMotion: reduceMotion)
            if navigationController === sourceLayer { await sourceController.activate(reduceMotion: reduceMotion) }
            return false
        }
        await sourceController.hide(reduceMotion: reduceMotion)
        await onScreenHidden(
            sourceController.screenId,
            .navigation(revealingScreenId: targetController.screenId)
        )
        await targetController.activate(reduceMotion: reduceMotion)
        await onScreenActive(targetController.screenId)
        return true
    }

    private func screenController(for screenId: String) throws -> ExperienceScreenViewController {
        if let cached = cachedControllersByScreenId[screenId] {
            return cached
        }
        throw ExperienceScreenTransitionCoordinatorError.screenNotMounted(screenId)
    }

    private func ensureScreenController(
        for screenId: String
    ) async throws -> ExperienceScreenViewController {
        guard !terminalScreenIds.contains(screenId) else {
            throw ExperienceScreenTransitionCoordinatorError.terminalScreen(screenId)
        }
        let cache = activeCache
        if let cached = cache.controllers[screenId] {
            // A cached screen re-enters in the host's appearance now, not the one it
            // mounted in.
            cached.adoptHostTraits(hostViewController?.traitCollection)
            return cached
        }
        guard let screen = artifact.renderPlan.screens.first(where: { $0.screenId == screenId }) else {
            throw ExperienceScreenTransitionCoordinatorError.missingScreen(screenId)
        }
        let screenArtifact = try await artifact.resolvingProducts(for: screenId)
        onProductsResolved(screenArtifact.acquired.products)
        let controller = ExperienceScreenViewController(
            experience: experience,
            artifact: screenArtifact,
            screen: screen,
            runValues: runValues,
            reduceMotion: reduceMotionEnabled,
            presentationDiagnosticsEnabled: presentationDiagnosticsEnabled,
            videoDecoderPool: videoDecoderPool,
            delegate: screenDelegate
        )
        mountingControllersByScreenId[screenId] = controller
        defer {
            if mountingControllersByScreenId[screenId] === controller {
                mountingControllersByScreenId.removeValue(forKey: screenId)
            }
        }
        controller.onRuntimeFailure = { [weak self, weak controller] error in
            guard let self, let controller else { return }
            Task { @MainActor [weak self, weak controller] in
                guard let self, let controller else { return }
                await self.reportTerminalFailure(error, for: controller.screenId)
            }
        }
        controller.setContentHidden(contentHidden)
        do {
            try await controller.mountInteractiveScreen(hostTraits: hostViewController?.traitCollection)
            guard lifecycle != .tearingDown,
                  lifecycle != .tornDown,
                  !Task.isCancelled,
                  layerCaches.contains(where: { $0 === cache }) || pendingModalCache === cache else {
                await controller.shutdownInteractiveScreen()
                throw CancellationError()
            }
            if let latestSnapshot {
                guard controller.applySnapshot(latestSnapshot, screenId: screenId) else {
                    throw ExperienceScreenTransitionCoordinatorError.screenNotMounted(screenId)
                }
            }
            controller.setContentHidden(contentHidden)
            cache.controllers[screenId] = controller
            return controller
        } catch {
            if !(error is CancellationError),
               lifecycle != .tearingDown,
               lifecycle != .tornDown {
                await reportTerminalFailure(error, for: screenId)
            }
            await controller.shutdownInteractiveScreen()
            throw error
        }
    }

    private func reportTerminalFailure(_ error: Error, for screenId: String) async {
        guard terminalScreenIds.insert(screenId).inserted else { return }
        if activeScreenId == screenId,
           let controller = activeController,
           controller.lifecyclePhase != .hidden {
            await controller.hide(reduceMotion: reduceMotionEnabled)
            await onScreenHidden(screenId, .runtimeFailure)
        }
        onRuntimeFailure(screenId, error)
    }

    private func targetControllers(for screenId: String?) throws -> [ExperienceScreenViewController] {
        if let screenId {
            guard let controller = layerCaches.reversed().lazy.compactMap({ $0.controllers[screenId] }).first else {
                throw ExperienceScreenTransitionCoordinatorError.screenNotMounted(screenId)
            }
            return [controller]
        }
        return allScreenControllers
    }

    private func replaceTop(with screenId: String, completion: Completion) throws {
        let controller = try screenController(for: screenId)
        try replaceTopController(controller)
        controller.loadViewIfNeeded()
        navigationController?.view.setNeedsLayout()
        navigationController?.view.layoutIfNeeded()
        controller.setContentHidden(contentHidden)
        controller.advance(delta: 0)
        completion(.navigated, screenId)
    }

    private func pushOrPop(
        to screenId: String,
        animated: Bool,
        completion: @escaping Completion
    ) throws {
        guard let navigationController else {
            try replaceTop(with: screenId, completion: completion)
            return
        }

        try performPushOrPop(
            to: screenId,
            in: navigationController,
            animated: animated,
            completion: completion
        )
    }

    private func performPushOrPop(
        to screenId: String,
        in navigationController: UINavigationController,
        animated: Bool,
        completion: @escaping Completion
    ) throws {
        if let existingController = navigationController.viewControllers
            .compactMap({ $0 as? ExperienceScreenViewController })
            .first(where: { $0.screenId == screenId }) {
            animateNavigationControllerOperation(screenId: screenId, completion: completion) {
                navigationController.popToViewController(existingController, animated: animated)
            }
            return
        }

        let controller = try screenController(for: screenId)
        controller.loadViewIfNeeded()
        controller.setContentHidden(contentHidden)
        animateNavigationControllerOperation(screenId: screenId, completion: completion) {
            navigationController.pushViewController(controller, animated: animated)
        }
    }

    private func present(
        screenId: String,
        presentation: ExperienceLayerPresentation,
        animated: Bool,
        stacksSheet: Bool,
        completion: @escaping Completion
    ) throws {
        // Present from the retained native layer container, not its screen child.
        // This makes UIKit's sheet presentation chain match Journey layer ownership.
        guard let presenter = (navigationController as UIViewController?) ?? hostViewController,
              let cache = pendingModalCache else {
            throw ExperienceScreenTransitionCoordinatorError.hostUnavailable
        }
        guard presenter.presentedViewController == nil, presenter.viewIfLoaded?.window != nil else {
            throw ExperienceScreenTransitionCoordinatorError.presenterBusy
        }
        let controller = try screenController(for: screenId)
        let layer = ExperienceLayerNavigationController(rootViewController: controller)
        layer.orientationHost = hostViewController
        layer.view.backgroundColor = UIColor(nuxieRGBAHex: experience.behaviorPresentation.backgroundColor)
        layer.setNavigationBarHidden(true, animated: false)
        let configurator = ExperienceLayerPresentationConfigurator(presentation: presentation)
        layer.preferredContentSize = controller.preferredContentSize
        configurator.configure(layer)
        controller.setHeightPresentationTarget(layer)
        layer.presentationController?.delegate = self
        controller.setContentHidden(contentHidden)
        let stackedWindow = stacksSheet
            ? ExperienceStackedSheetWindow(above: presenter.view.window, host: hostViewController) : nil
        (stackedWindow?.presenter ?? presenter).present(layer, animated: animated) {
            controller.advance(delta: 0)
            completion(.navigated, screenId)
        }
        guard layer.presentingViewController != nil else {
            stackedWindow?.close()
            throw ExperienceScreenTransitionCoordinatorError.presenterBusy
        }
        if let stackedWindow { stackedSheetWindows[ObjectIdentifier(layer)] = stackedWindow }
        navigationLayers.append(layer)
        layerCaches.append(cache)
        pendingModalCache = nil
    }

    private func discardPendingModal() async {
        let controllers = Array(pendingModalCache?.controllers.values ?? [:].values)
        pendingModalCache = nil
        for controller in controllers { await controller.shutdownInteractiveScreen() }
    }

    private func replaceTopController(_ controller: ExperienceScreenViewController) throws {
        guard let navigationController else {
            throw ExperienceScreenTransitionCoordinatorError.hostUnavailable
        }
        // E47 provisional decision: reuse an earlier screen and preserve its state.
        if let index = navigationController.viewControllers.firstIndex(where: { $0 === controller }) {
            navigationController.setViewControllers(Array(navigationController.viewControllers.prefix(index + 1)), animated: false)
            return
        }
        let preceding = Array(navigationController.viewControllers.dropLast())
        navigationController.setViewControllers(preceding + [controller], animated: false)
    }

    /// The Experience host is leaving the screen. UIKit takes the sheets it presented with it;
    /// sheets presented from their own windows go with them instead of waiting for teardown.
    /// Each window keeps its record until the window has really closed, so the swipe path and
    /// teardown can still find it if UIKit never runs a dismissal completion.
    func dismissStackedSheets(animated: Bool) {
        for layer in navigationLayers.reversed() {
            guard let window = stackedSheetWindows[ObjectIdentifier(layer)] else { continue }
            // UIKit skips the completion when the sheet has already left its presenter.
            if window.presenter.presentedViewController == nil {
                window.close()
            } else {
                window.presenter.dismiss(animated: animated) { window.close() }
            }
        }
    }

    /// UIKit hides a page sheet whenever another page sheet is presented from it, unless the
    /// lower sheet is at its large detent. A Journey sheet opened over a sheet leaves the lower
    /// sheet visible, so it is presented as the first sheet of its own window instead.
    private func opensStackedSheet(_ presentation: ExperienceLayerPresentation) -> Bool {
        guard presentation.kind == .sheet,
              let lower = hasPresentedLayer ? navigationController : hostViewController,
              lower.presentingViewController != nil else { return false }
        return lower.modalPresentationStyle == .pageSheet || lower.modalPresentationStyle == .formSheet
    }

    nonisolated func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        _ = MainActor.assumeIsolated {
            Task { @MainActor [weak self] in
                await self?.handlePresentedControllerDidDismiss(presentationController)
            }
        }
    }

    private func performAuthoredLayerDismissal() async -> Bool {
        guard hasPresentedLayer, let layer = navigationController,
              let controller = activeController, closingLayer == nil else { return false }
        closingLayer = layer
        layer.view.isUserInteractionEnabled = false
        // This is an authored close, including closedby none. UIKit must not
        // remove its surface while the declared exit is still drawing.
        layer.isModalInPresentation = true
        await controller.performExitHandshake(reduceMotion: reduceMotionEnabled, exitReason: .dismissed)
        guard lifecycle == .installed, !Task.isCancelled, navigationController === layer else {
            closingLayer = nil
            return false
        }
        layer.presentationController?.delegate = nil
        await withCheckedContinuation { continuation in
            layer.presentingViewController?.dismiss(animated: !reduceMotionEnabled) { continuation.resume() }
        }
        await finishLayerDismissal(layer, controller: controller, alreadyDismissed: false)
        closingLayer = nil
        return true
    }

    private func handlePresentedControllerDidDismiss(
        _ presentationController: UIPresentationController
    ) async {
        guard let layer = presentationController.presentedViewController as? UINavigationController,
              hasPresentedLayer, navigationController === layer, closingLayer !== layer,
              let controller = layer.topViewController as? ExperienceScreenViewController else { return }
        await finishLayerDismissal(layer, controller: controller, alreadyDismissed: true)
    }

    private func finishLayerDismissal(_ layer: UINavigationController,
                                      controller: ExperienceScreenViewController,
                                      alreadyDismissed: Bool) async {
        guard navigationController === layer, hasPresentedLayer else { return }
        layer.presentationController?.delegate = nil
        navigationLayers.removeLast()
        stackedSheetWindows.removeValue(forKey: ObjectIdentifier(layer))?.close()
        let cache = layerCaches.removeLast()
        let revealingController = activeController
        if alreadyDismissed {
            await controller.markExiting(reduceMotion: reduceMotionEnabled, exitReason: .dismissed)
        }
        await controller.hide(reduceMotion: reduceMotionEnabled)
        if alreadyDismissed {
            await onPresentedScreenDismissed(controller.screenId, revealingController?.screenId)
        } else {
            await onScreenHidden(controller.screenId,
                .init(revealingScreenId: revealingController?.screenId, method: "journey"))
        }
        revealingController?.setCoveredByLayer(false)
        // The retained screen never left active. This callback restores Journey
        // routing, without an entering edge, appearance increment or remount.
        if let screenId = revealingController?.screenId { await onScreenActive(screenId) }
        for controller in cache.controllers.values { await controller.shutdownInteractiveScreen() }
    }

    private func installLiveReplacementSurface(
        sourceController: ExperienceScreenViewController,
        targetController: ExperienceScreenViewController,
        incomingOnTop: Bool
    ) throws {
        guard let hostView = navigationController?.view ?? hostViewController?.view else {
            throw ExperienceScreenTransitionCoordinatorError.hostUnavailable
        }

        sourceController.loadViewIfNeeded()
        targetController.loadViewIfNeeded()
        let sourceView = sourceController.view!
        let container = sourceView.superview ?? hostView
        targetController.view.removeFromSuperview()
        targetController.view.frame = container.bounds
        targetController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        if sourceView.superview === container {
            if incomingOnTop {
                container.insertSubview(targetController.view, aboveSubview: sourceView)
            } else {
                container.insertSubview(targetController.view, belowSubview: sourceView)
            }
        } else if incomingOnTop {
            container.addSubview(targetController.view)
        } else {
            container.insertSubview(targetController.view, at: 0)
        }
        // Manual insertion bypasses UIKit's appearance callbacks, so the
        // controller would keep reporting itself invisible and the incoming
        // half of the overlap would advance without rendering. Walk the
        // appearance transition explicitly.
        targetController.beginAppearanceTransition(true, animated: false)
        targetController.endAppearanceTransition()
        targetController.setContentHidden(contentHidden)
        targetController.advance(delta: 0)
    }

    private func removeLiveReplacementSurface(
        controller: ExperienceScreenViewController
    ) {
        controller.view.removeFromSuperview()
    }

    private func finalizeLiveReplacementSurface(
        controller: ExperienceScreenViewController
    ) throws {
        removeLiveReplacementSurface(controller: controller)
        try replaceTopController(controller)
        controller.loadViewIfNeeded()
        navigationController?.view.setNeedsLayout()
        navigationController?.view.layoutIfNeeded()
        controller.setContentHidden(contentHidden)
    }

    private func runLiveReplacementTransition(
        to screenId: String,
        spec: ExperienceScreenTransitionSpec,
        completion: @escaping Completion
    ) throws {
        guard let currentController = activeController else {
            try replaceTop(with: screenId, completion: completion)
            return
        }
        let sourceLayer = navigationController
        let nextController = try screenController(for: screenId)
        try installLiveReplacementSurface(
            sourceController: currentController,
            targetController: nextController,
            incomingOnTop: true
        )
        let currentView = currentController.view!

        switch spec.kind {
        case .fade:
            nextController.view.alpha = 0
        case .none, .push, .modal, .custom, .magicMove:
            break
        }

        UIView.animate(
            withDuration: 0.3,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseInOut]
        ) {
            nextController.view.transform = .identity
            nextController.view.alpha = 1

            switch spec.kind {
            case .fade:
                currentView.alpha = 0
            case .none, .push, .modal, .custom, .magicMove:
                break
            }
        } completion: { [weak self, weak nextController] _ in
            guard let self,
                  let nextController else {
                completion(.failed, screenId)
                return
            }
            currentView.transform = .identity
            currentView.alpha = 1
            nextController.view.transform = .identity
            nextController.view.alpha = 1
            guard self.lifecycle == .installed, !self.navigationAdmissionRevoked,
                  self.navigationController === sourceLayer else {
                self.removeLiveReplacementSurface(controller: nextController)
                completion(.failed, screenId)
                return
            }
            do {
                try self.finalizeLiveReplacementSurface(controller: nextController)
                self.completeNavigation(to: screenId, completion: completion)
            } catch {
                self.removeLiveReplacementSurface(controller: nextController)
                completion(.failed, screenId)
            }
        }
    }

    private func animateNavigationControllerOperation(
        screenId: String,
        completion: @escaping Completion,
        operation: () -> Void
    ) {
        // UIKit can start an animated push or pop after this transaction
        // commits, so the transaction alone may report navigation while the
        // transition is still running, and an immediate back is then dropped.
        // Finish on the transition coordinator whenever UIKit provides one.
        let finish = ExperienceNavigationCompletion { [weak self] in
            self?.completeNavigation(to: screenId, completion: completion)
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            if !finish.awaitsTransition { finish.run() }
        }
        operation()
        if let transition = navigationController?.transitionCoordinator {
            finish.awaitsTransition = transition.animate(alongsideTransition: nil) { _ in finish.run() }
        }
        CATransaction.commit()
    }

    private func completeNavigation(to screenId: String, completion: Completion) {
        (cachedControllersByScreenId[screenId]
            ?? navigationController?.topViewController as? ExperienceScreenViewController)?
            .advance(delta: 0)
        completion(.navigated, screenId)
    }

    private var reduceMotionEnabled: Bool {
        UIAccessibility.isReduceMotionEnabled
    }

    private func refreshReduceMotionState() async {
        let value = reduceMotionEnabled
        for controller in allScreenControllers {
            await controller.updateReduceMotion(value)
        }
    }
}

/// Runs one native navigation completion once, from whichever UIKit signal owns it.
@MainActor
private final class ExperienceNavigationCompletion {
    var awaitsTransition = false
    private var action: (() -> Void)?

    init(_ action: @escaping () -> Void) { self.action = action }

    func run() {
        let action = self.action
        self.action = nil
        action?()
    }
}

@MainActor
private final class ExperienceLayerNavigationController: UINavigationController {
    weak var orientationHost: UIViewController?
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        orientationHost?.supportedInterfaceOrientations ?? super.supportedInterfaceOrientations
    }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        orientationHost?.preferredInterfaceOrientationForPresentation ?? super.preferredInterfaceOrientationForPresentation
    }
}

/// A transparent window whose root presents one Journey sheet above a lower sheet, so UIKit
/// does not stack the two and the lower sheet stays drawn beneath. The sheet keeps its native
/// page-sheet presentation, detents, drag dismissal and dismissal rules.
@MainActor
private final class ExperienceStackedSheetWindow {
    let presenter = ExperienceStackedSheetPresenter()
    private let window: UIWindow
    private weak var lowerWindow: UIWindow?
    private let lowerWindowHidAccessibility: Bool
    /// The window that was key before this one opened; an embedded host's window may not be.
    private weak var previousKeyWindow: UIWindow?
    private var isClosed = false

    init?(above lowerWindow: UIWindow?, host: UIViewController?) {
        guard let lowerWindow, let scene = lowerWindow.windowScene else { return nil }
        self.lowerWindow = lowerWindow
        lowerWindowHidAccessibility = lowerWindow.accessibilityElementsHidden
        previousKeyWindow = scene.keyWindow
        window = UIWindow(windowScene: scene)
        window.backgroundColor = .clear
        window.windowLevel = UIWindow.Level(rawValue: lowerWindow.windowLevel.rawValue + 1)
        presenter.orientationHost = host
        // The root of the topmost full-screen window decides the status bar. In one window that
        // followed the Experience controller's forced light or dark style, so this root carries it.
        presenter.overrideUserInterfaceStyle = host?.overrideUserInterfaceStyle ?? .unspecified
        presenter.view.backgroundColor = .clear
        window.rootViewController = presenter
        window.makeKeyAndVisible()
        // UIKit keeps VoiceOver inside the top sheet only among views of one window. Hide the
        // window below, so VoiceOver cannot reach, or escape-dismiss, the covered sheets in it.
        // Each stacked window hides only the one below it, so nested windows unwind in turn.
        lowerWindow.accessibilityElementsHidden = true
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        window.isHidden = true
        window.rootViewController = nil
        lowerWindow?.accessibilityElementsHidden = lowerWindowHidAccessibility
        if let previousKeyWindow, !previousKeyWindow.isHidden { previousKeyWindow.makeKey() }
        // The revealed sheet is a new screen for VoiceOver to land on.
        UIAccessibility.post(notification: .screenChanged, argument: nil)
    }
}

@MainActor
private final class ExperienceStackedSheetPresenter: UIViewController {
    weak var orientationHost: UIViewController?
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        orientationHost?.supportedInterfaceOrientations ?? super.supportedInterfaceOrientations
    }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        orientationHost?.preferredInterfaceOrientationForPresentation ?? super.preferredInterfaceOrientationForPresentation
    }
}

private enum ExperienceScreenTransitionCoordinatorError: LocalizedError {
    case hostUnavailable
    case presenterBusy
    case missingScreen(String)
    case screenNotMounted(String)
    case terminalScreen(String)

    var errorDescription: String? {
        switch self {
        case .presenterBusy:
            return "Experience layer presenter already has a presented controller."
        case .hostUnavailable:
            return "Experience screen coordinator lost its host view controller."
        case .missingScreen(let screenId):
            return "Experience artifact does not contain screen \(screenId)."
        case .screenNotMounted(let screenId):
            return "Experience screen \(screenId) has not mounted its interactive runtime."
        case .terminalScreen(let screenId):
            return "Experience screen \(screenId) previously encountered a terminal runtime failure."
        }
    }
}
#endif
