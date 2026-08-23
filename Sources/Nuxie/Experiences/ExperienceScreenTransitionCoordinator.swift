#if canImport(UIKit)
import UIKit

@MainActor
final class ExperienceScreenTransitionCoordinator: NSObject, UIAdaptivePresentationControllerDelegate {
    typealias Completion = (_ didNavigate: Bool, _ screenId: String) -> Void

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
    }

    private struct LiveReplacementSurface {
        let controllerWasAddedAsChild: Bool
    }

    private weak var hostViewController: UIViewController?
    private let experience: Experience
    private let artifact: LoadedExperienceArtifact
    private let initialScreenID: String
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
    private let onProductsUnavailable: (
        _ screenId: String,
        _ productIds: [String]
    ) async -> Void
    private let onRuntimeFailure: (_ screenId: String, _ error: Error) -> Void

    private var navigationController: UINavigationController?
    private var activePresentedController: ExperienceScreenViewController?
    private var cachedControllersByScreenId: [String: ExperienceScreenViewController] = [:]
    private var mountingControllersByScreenId: [String: ExperienceScreenViewController] = [:]
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
        activePresentedController?.screenId
            ?? (navigationController?.topViewController as? ExperienceScreenViewController)?.screenId
    }

    func owns(_ controller: ExperienceScreenViewController) -> Bool {
        cachedControllersByScreenId.values.contains { $0 === controller }
            || mountingControllersByScreenId.values.contains { $0 === controller }
    }

    init(
        experience: Experience,
        artifact: LoadedExperienceArtifact,
        initialScreenID: String? = nil,
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
        onProductsUnavailable: @escaping (
            _ screenId: String,
            _ productIds: [String]
        ) async -> Void,
        onRuntimeFailure: @escaping (_ screenId: String, _ error: Error) -> Void
    ) {
        self.experience = experience
        self.artifact = artifact
        self.initialScreenID = initialScreenID ?? artifact.renderPlan.entry.screenId
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

        self.navigationController = navigationController
        navigationController.loadViewIfNeeded()
        entryController.loadViewIfNeeded()
        navigationController.view.setNeedsLayout()
        navigationController.view.layoutIfNeeded()
        entryController.setContentHidden(contentHidden)
        await entryController.enter(reduceMotion: reduceMotionEnabled)
    }

    func activateInitialScreen() async -> String? {
        guard lifecycle == .installed,
              let activeScreenId,
              let controller = cachedControllersByScreenId[activeScreenId] else {
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

    func exitActiveScreenForTeardown(reason: CloseReason?) async {
        // Revoke navigation admission, fail queued requests, then cancel and
        // drain the in-flight task: a suspended exit handshake or watchdog
        // must not resume - nor may a queued request restart the drain - and
        // mount a destination after the teardown hidden event.
        navigationAdmissionRevoked = true
        let queuedRequests = navigationRequests
        navigationRequests.removeAll()
        queuedRequests.forEach { $0.completion(false, $0.screenId) }
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
              let controller = cachedControllersByScreenId[activeScreenId],
              controller.lifecyclePhase != .hidden else {
            return
        }
        let reduceMotion = reduceMotionEnabled
        if controller.lifecyclePhase != .exiting {
            await controller.performExitHandshake(reduceMotion: reduceMotion)
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
        queuedRequests.forEach { $0.completion(false, $0.screenId) }

        if let installationTask {
            _ = await installationTask.result
        }
        if let navigationTask {
            await navigationTask.value
        }

        if let activePresentedController {
            activePresentedController.dismiss(animated: false)
            self.activePresentedController = nil
        }

        if let navigationController {
            navigationController.willMove(toParent: nil)
            navigationController.view.removeFromSuperview()
            navigationController.removeFromParent()
            self.navigationController = nil
        }

        let controllers = cachedControllersByScreenId.values.sorted {
            $0.screenId.utf8.lexicographicallyPrecedes($1.screenId.utf8)
        }
        cachedControllersByScreenId.removeAll()
        mountingControllersByScreenId.removeAll()
        latestSnapshot = nil
        for controller in controllers {
            await controller.shutdownInteractiveScreen()
        }
        self.installationTask = nil
        self.navigationTask = nil
        lifecycle = .tornDown
    }

    func setContentHidden(_ hidden: Bool) {
        contentHidden = hidden
        navigationController?.view.isHidden = hidden
        activePresentedController?.setContentHidden(hidden)
        cachedControllersByScreenId.values.forEach { $0.setContentHidden(hidden) }
    }

    func layoutTextInputs() {
        cachedControllersByScreenId.values.forEach { $0.layoutTextInputs() }
    }

    /// Re-reads each cached screen's own view insets and pushes them into
    /// that screen's bound view-model instance. Screens read their own view
    /// (not the host's) so modal sheets and pushed screens resolve their own
    /// safe-area environment.
    func syncSafeAreaInsets() {
        cachedControllersByScreenId.values.forEach { $0.syncSafeAreaInsets() }
    }

    @discardableResult
    func applySnapshot(_ snapshot: ExperienceViewModelSnapshot, screenId: String?) -> Bool {
        latestSnapshot = snapshot
        var didApply = false
        for controller in cachedControllersByScreenId.values {
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
        guard lifecycle == .installed,
              !navigationAdmissionRevoked,
              artifact.renderPlan.screens.contains(where: { $0.screenId == screenId }) else {
            return false
        }

        if terminalScreenIds.contains(screenId) {
            completion(false, screenId)
            return false
        }

        if activeScreenId == screenId,
           navigationTask == nil,
           navigationRequests.isEmpty {
            completion(true, screenId)
            return true
        }

        navigationRequests.append(NavigationRequest(
            screenId: screenId,
            rawTransition: rawTransition,
            completion: completion
        ))
        startNavigationDrainIfNeeded()
        return true
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
            do {
                _ = try await ensureScreenController(for: request.screenId)
                guard lifecycle == .installed, !Task.isCancelled,
                      !navigationAdmissionRevoked else {
                    request.completion(false, request.screenId)
                    break
                }
                let didNavigate = try await performMountedNavigation(
                    to: request.screenId,
                    transition: request.rawTransition
                )
                request.completion(
                    lifecycle == .installed && !Task.isCancelled
                        && !navigationAdmissionRevoked && didNavigate,
                    request.screenId
                )
            } catch {
                if case ExperienceError.productsUnavailable(let productIds) = error {
                    request.completion(false, request.screenId)
                    for queued in navigationRequests {
                        queued.completion(false, queued.screenId)
                    }
                    navigationRequests.removeAll()
                    await onProductsUnavailable(request.screenId, productIds)
                    break
                }
                LogWarning(
                    "ExperienceScreenTransitionCoordinator: failed to navigate to screen \(request.screenId): \(error)"
                )
                request.completion(false, request.screenId)
            }
        }
        navigationTask = nil
        if lifecycle == .installed, !navigationRequests.isEmpty {
            startNavigationDrainIfNeeded()
        }
    }

    private func performMountedNavigation(
        to screenId: String,
        transition rawTransition: Any?
    ) async throws -> Bool {
        let sourceController = activeScreenId.flatMap { cachedControllersByScreenId[$0] }
        let targetController = try screenController(for: screenId)
        let reduceMotion = reduceMotionEnabled
        return try await performNavigation(
            to: screenId,
            transition: rawTransition,
            sourceController: sourceController,
            targetController: targetController,
            reduceMotion: reduceMotion
        )
    }

    private func performNavigation(
        to screenId: String,
        transition rawTransition: Any?,
        sourceController: ExperienceScreenViewController?,
        targetController: ExperienceScreenViewController,
        reduceMotion: Bool
    ) async throws -> Bool {
        let spec = ExperienceScreenTransitionSpec(raw: rawTransition)
        if case .custom(let transitionId) = spec.kind,
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
                await sourceController?.performExitHandshake(reduceMotion: reduceMotion)
            },
            nativeOperation: {
                guard self.lifecycle == .installed, !Task.isCancelled else {
                    throw CancellationError()
                }
                return try await withCheckedThrowingContinuation { continuation in
                    do {
                        try self.performNativeNavigation(
                            to: screenId,
                            transition: rawTransition,
                            reduceMotion: reduceMotion
                        ) { didNavigate, _ in
                            continuation.resume(returning: didNavigate)
                        }
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            },
            sourceHidden: {
                if let sourceController, sourceController !== targetController {
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
                if let sourceController, sourceController !== targetController {
                    await sourceController.activate(reduceMotion: reduceMotion)
                }
            }
        )
    }

    private func performNativeNavigation(
        to screenId: String,
        transition rawTransition: Any?,
        reduceMotion: Bool,
        completion: @escaping Completion
    ) throws {
        let spec = ExperienceScreenTransitionSpec(raw: rawTransition)
        let animated = spec.shouldAnimate(reduceMotion: reduceMotion)

        switch spec.effectiveKind(reduceMotion: reduceMotion) {
        case .none:
            try replaceRoot(with: screenId, completion: completion)
        case .push:
            try pushOrPop(to: screenId, animated: animated, completion: completion)
        case .modal:
            try present(screenId: screenId, animated: animated, completion: completion)
        case .fade:
            if animated {
                try runLiveReplacementTransition(
                    to: screenId,
                    spec: spec,
                    completion: completion
                )
            } else {
                try replaceRoot(with: screenId, completion: completion)
            }
        case .custom:
            // A custom spec reaches this switch only when its signed manifest
            // declaration did not match the active navigation edge.
            try replaceRoot(with: screenId, completion: completion)
        }
    }

    private func performCustomMountedNavigation(
        sourceController: ExperienceScreenViewController,
        targetController: ExperienceScreenViewController,
        plan: ExperienceScreenCustomTransitionPlan,
        reduceMotion: Bool
    ) async throws -> Bool {
        let surface = try installLiveReplacementSurface(
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
                    reduceMotion: reduceMotion
                )
                async let incomingPhase: Void = targetController.writeCustomTransitionPhase(
                    .entering,
                    transitionId: plan.transitionId,
                    reduceMotion: reduceMotion
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
                      !self.terminalScreenIds.contains(targetController.screenId) else {
                    self.removeLiveReplacementSurface(surface, controller: targetController)
                    return false
                }
                self.finalizeLiveReplacementSurface(surface, controller: targetController)
                return await withCheckedContinuation { continuation in
                    self.completeNavigation(to: targetController.screenId) { didNavigate, _ in
                        continuation.resume(returning: didNavigate)
                    }
                }
            }
        )
        guard didNavigate else {
            await targetController.hide(reduceMotion: reduceMotion)
            await sourceController.activate(reduceMotion: reduceMotion)
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
        if let cached = cachedControllersByScreenId[screenId] {
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
            reduceMotion: reduceMotionEnabled,
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
            try await controller.mountInteractiveScreen()
            guard lifecycle != .tearingDown,
                  lifecycle != .tornDown,
                  !Task.isCancelled else {
                await controller.shutdownInteractiveScreen()
                throw CancellationError()
            }
            if let latestSnapshot {
                guard controller.applySnapshot(latestSnapshot, screenId: screenId) else {
                    throw ExperienceScreenTransitionCoordinatorError.screenNotMounted(screenId)
                }
            }
            cachedControllersByScreenId[screenId] = controller
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
           let controller = cachedControllersByScreenId[screenId],
           controller.lifecyclePhase != .hidden {
            await controller.hide(reduceMotion: reduceMotionEnabled)
            await onScreenHidden(screenId, .runtimeFailure)
        }
        onRuntimeFailure(screenId, error)
    }

    private func targetControllers(for screenId: String?) throws -> [ExperienceScreenViewController] {
        if let screenId {
            return [try screenController(for: screenId)]
        }
        return Array(cachedControllersByScreenId.values)
    }

    private func replaceRoot(with screenId: String, completion: Completion) throws {
        let controller = try screenController(for: screenId)
        dismissActivePresentedControllerIfNeeded(animated: false)
        navigationController?.setViewControllers([controller], animated: false)
        controller.loadViewIfNeeded()
        navigationController?.view.setNeedsLayout()
        navigationController?.view.layoutIfNeeded()
        controller.setContentHidden(contentHidden)
        controller.advance(delta: 0)
        completion(true, screenId)
    }

    private func pushOrPop(
        to screenId: String,
        animated: Bool,
        completion: @escaping Completion
    ) throws {
        guard let navigationController else {
            try replaceRoot(with: screenId, completion: completion)
            return
        }

        if activePresentedController != nil {
            dismissActivePresentedControllerIfNeeded(animated: animated) { [weak self] in
                guard let self else { return }
                do {
                    try self.performPushOrPop(
                        to: screenId,
                        in: navigationController,
                        animated: animated,
                        completion: completion
                    )
                } catch {
                    LogWarning(
                        """
                        ExperienceScreenTransitionCoordinator: failed to navigate \
                        to screen \(screenId) after modal dismiss: \(error)
                        """
                    )
                    completion(false, screenId)
                }
            }
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
        animated: Bool,
        completion: @escaping Completion
    ) throws {
        guard let presenter = activePresentedController
            ?? navigationController?.topViewController
            ?? hostViewController else {
            try replaceRoot(with: screenId, completion: completion)
            return
        }

        let controller = try screenController(for: screenId)
        controller.loadViewIfNeeded()
        controller.modalPresentationStyle = .pageSheet
        controller.view.backgroundColor = .systemBackground
        controller.sheetPresentationController?.detents = [.large()]
        controller.sheetPresentationController?.prefersGrabberVisible = true
        controller.presentationController?.delegate = self
        controller.setContentHidden(contentHidden)
        presenter.present(controller, animated: animated) { [weak self] in
            self?.activePresentedController = controller
            controller.advance(delta: 0)
            completion(true, screenId)
        }
    }

    nonisolated func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        _ = MainActor.assumeIsolated {
            Task { @MainActor [weak self] in
                await self?.handlePresentedControllerDidDismiss(presentationController)
            }
        }
    }

    private func handlePresentedControllerDidDismiss(
        _ presentationController: UIPresentationController
    ) async {
        guard let dismissedController = presentationController.presentedViewController
            as? ExperienceScreenViewController,
              activePresentedController === dismissedController else {
            return
        }

        activePresentedController = activePresenterAfterDismissing(presentationController)
        dismissedController.presentationController?.delegate = nil

        let revealingScreenId = (
            presentationController.presentingViewController as? ExperienceScreenViewController
        )?.screenId
            ?? (navigationController?.topViewController as? ExperienceScreenViewController)?.screenId
        let reduceMotion = reduceMotionEnabled
        let revealingController = revealingScreenId.flatMap { cachedControllersByScreenId[$0] }
        await ExperienceScreenLifecycleSheetDismissal.perform(
            dismissedExiting: {
                await dismissedController.markExiting(reduceMotion: reduceMotion)
            },
            dismissedHidden: {
                await dismissedController.hide(reduceMotion: reduceMotion)
            },
            hiddenAnalytics: {
                await self.onPresentedScreenDismissed(
                    dismissedController.screenId,
                    revealingScreenId
                )
            },
            revealedEntering: {
                await revealingController?.enter(reduceMotion: reduceMotion)
            },
            revealedActive: {
                guard let revealingScreenId, let revealingController else { return }
                await revealingController.activate(reduceMotion: reduceMotion)
                await self.onScreenActive(revealingScreenId)
            }
        )
    }

    private func activePresenterAfterDismissing(
        _ presentationController: UIPresentationController
    ) -> ExperienceScreenViewController? {
        guard let presenter = presentationController.presentingViewController as? ExperienceScreenViewController else {
            return nil
        }
        let presenterIsNavigationScreen = navigationController?.viewControllers.contains {
            $0 === presenter
        } ?? false
        return presenterIsNavigationScreen ? nil : presenter
    }

    private func installLiveReplacementSurface(
        sourceController: ExperienceScreenViewController,
        targetController: ExperienceScreenViewController,
        incomingOnTop: Bool
    ) throws -> LiveReplacementSurface {
        guard let hostView = navigationController?.view ?? hostViewController?.view,
              let hostViewController else {
            throw ExperienceScreenTransitionCoordinatorError.hostUnavailable
        }

        sourceController.loadViewIfNeeded()
        targetController.loadViewIfNeeded()
        let sourceView = sourceController.view!
        let container = sourceView.superview ?? hostView
        let controllerWasAddedAsChild = targetController.parent == nil
        if controllerWasAddedAsChild {
            hostViewController.addChild(targetController)
        }
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
        if controllerWasAddedAsChild {
            targetController.didMove(toParent: hostViewController)
        }
        // Manual insertion bypasses UIKit's appearance callbacks, so the
        // controller would keep reporting itself invisible and the incoming
        // half of the overlap would advance without rendering. Walk the
        // appearance transition explicitly.
        targetController.beginAppearanceTransition(true, animated: false)
        targetController.endAppearanceTransition()
        targetController.setContentHidden(contentHidden)
        targetController.advance(delta: 0)
        return LiveReplacementSurface(
            controllerWasAddedAsChild: controllerWasAddedAsChild
        )
    }

    private func removeLiveReplacementSurface(
        _ surface: LiveReplacementSurface,
        controller: ExperienceScreenViewController
    ) {
        if surface.controllerWasAddedAsChild {
            controller.willMove(toParent: nil)
        }
        controller.view.removeFromSuperview()
        if surface.controllerWasAddedAsChild {
            controller.removeFromParent()
        }
    }

    private func finalizeLiveReplacementSurface(
        _ surface: LiveReplacementSurface,
        controller: ExperienceScreenViewController
    ) {
        removeLiveReplacementSurface(surface, controller: controller)
        dismissActivePresentedControllerIfNeeded(animated: false)
        navigationController?.setViewControllers([controller], animated: false)
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
        guard let hostView = navigationController?.view ?? hostViewController?.view,
              let currentView = activePresentedController?.view
                ?? (navigationController?.topViewController as? ExperienceScreenViewController)?.view else {
            try replaceRoot(with: screenId, completion: completion)
            return
        }

        dismissActivePresentedControllerIfNeeded(animated: false)

        let nextController = try screenController(for: screenId)
        nextController.loadViewIfNeeded()
        guard let hostViewController else {
            try replaceRoot(with: screenId, completion: completion)
            return
        }

        hostViewController.addChild(nextController)
        nextController.view.frame = hostView.bounds
        nextController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        hostView.addSubview(nextController.view)
        nextController.didMove(toParent: hostViewController)
        nextController.setContentHidden(contentHidden)
        nextController.advance(delta: 0)

        switch spec.kind {
        case .fade:
            nextController.view.alpha = 0
        case .none, .push, .modal, .custom:
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
            case .none, .push, .modal, .custom:
                break
            }
        } completion: { [weak self, weak nextController] _ in
            guard let self,
                  let nextController else {
                completion(false, screenId)
                return
            }
            currentView.transform = .identity
            currentView.alpha = 1
            nextController.view.transform = .identity
            nextController.view.alpha = 1
            nextController.willMove(toParent: nil)
            nextController.view.removeFromSuperview()
            nextController.removeFromParent()
            self.navigationController?.setViewControllers([nextController], animated: false)
            self.completeNavigation(to: screenId, completion: completion)
        }
    }

    private func animateNavigationControllerOperation(
        screenId: String,
        completion: @escaping Completion,
        operation: () -> Void
    ) {
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            self?.completeNavigation(to: screenId, completion: completion)
        }
        operation()
        CATransaction.commit()
    }

    private func completeNavigation(to screenId: String, completion: Completion) {
        (cachedControllersByScreenId[screenId]
            ?? activePresentedController
            ?? navigationController?.topViewController as? ExperienceScreenViewController)?
            .advance(delta: 0)
        completion(true, screenId)
    }

    private func dismissActivePresentedControllerIfNeeded(
        animated: Bool,
        completion: (() -> Void)? = nil
    ) {
        guard let activePresentedController else {
            completion?()
            return
        }
        self.activePresentedController = nil
        activePresentedController.dismiss(animated: animated, completion: completion)
    }

    private static var forceReduceMotionForTesting: Bool {
        ProcessInfo.processInfo.arguments.contains("--nuxie-force-reduce-motion")
            || ProcessInfo.processInfo.environment["NUXIE_FORCE_REDUCE_MOTION"] == "1"
    }

    private var reduceMotionEnabled: Bool {
        UIAccessibility.isReduceMotionEnabled || Self.forceReduceMotionForTesting
    }

    private func refreshReduceMotionState() async {
        let value = reduceMotionEnabled
        for controller in cachedControllersByScreenId.values {
            await controller.updateReduceMotion(value)
        }
    }
}

private enum ExperienceScreenTransitionCoordinatorError: LocalizedError {
    case hostUnavailable
    case missingScreen(String)
    case screenNotMounted(String)
    case terminalScreen(String)

    var errorDescription: String? {
        switch self {
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
