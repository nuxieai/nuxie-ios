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

    private weak var hostViewController: UIViewController?
    private let flow: Experience
    private let artifact: LoadedFlowArtifact
    private let runtimeContext: FlowRuntimeContext
    private weak var screenDelegate: FlowScreenViewControllerDelegate?
    private let onPresentedScreenDismissed: (_ dismissedScreenId: String, _ revealingScreenId: String?) -> Void
    private let onRuntimeFailure: (_ screenId: String, _ error: Error) -> Void

    private var navigationController: UINavigationController?
    private var activePresentedController: ExperienceScreenViewController?
    private var cachedControllersByScreenId: [String: ExperienceScreenViewController] = [:]
    private var mountingControllersByScreenId: [String: ExperienceScreenViewController] = [:]
    private var latestSnapshot: FlowViewModelSnapshot?
    private var contentHidden = true
    private var terminalScreenIds: Set<String> = []
    private var lifecycle: Lifecycle = .idle
    private var installationTask: Task<Void, Error>?
    private var navigationTask: Task<Void, Never>?
    private var teardownTask: Task<Void, Never>?
    private var navigationRequests: [NavigationRequest] = []

    var activeScreenId: String? {
        activePresentedController?.screenId
            ?? (navigationController?.topViewController as? ExperienceScreenViewController)?.screenId
    }

    func owns(_ controller: ExperienceScreenViewController) -> Bool {
        cachedControllersByScreenId.values.contains { $0 === controller }
            || mountingControllersByScreenId.values.contains { $0 === controller }
    }

    init(
        flow: Experience,
        artifact: LoadedFlowArtifact,
        runtimeContext: FlowRuntimeContext,
        hostViewController: UIViewController,
        screenDelegate: FlowScreenViewControllerDelegate,
        onPresentedScreenDismissed: @escaping (_ dismissedScreenId: String, _ revealingScreenId: String?) -> Void,
        onRuntimeFailure: @escaping (_ screenId: String, _ error: Error) -> Void
    ) {
        self.flow = flow
        self.artifact = artifact
        self.runtimeContext = runtimeContext
        self.hostViewController = hostViewController
        self.screenDelegate = screenDelegate
        self.onPresentedScreenDismissed = onPresentedScreenDismissed
        self.onRuntimeFailure = onRuntimeFailure
        super.init()
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
            throw FlowScreenTransitionCoordinatorError.hostUnavailable
        }
        let entryController = try await ensureScreenController(
            for: artifact.manifest.entry.screenId
        )
        guard lifecycle == .installing, !Task.isCancelled else {
            await entryController.shutdownRuntimeSession()
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
        entryController.advance(delta: 0)
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
            await controller.shutdownRuntimeSession()
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
    func applySnapshot(_ snapshot: FlowViewModelSnapshot, screenId: String?) -> Bool {
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
                "ExperienceScreenTransitionCoordinator: failed to apply value to screen \(screenId ?? "<all>"): \(error)"
            )
        }
        return didApply
    }

    @discardableResult
    func applyListOperation(
        _ operation: FlowViewModelListOperation,
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
                "ExperienceScreenTransitionCoordinator: failed to apply list operation to screen \(screenId ?? "<all>"): \(error)"
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
                "ExperienceScreenTransitionCoordinator: failed to fire trigger on screen \(screenId ?? "<all>"): \(error)"
            )
        }
        return didFire
    }

    @discardableResult
    func navigate(to screenId: String, transition rawTransition: Any?, completion: @escaping Completion) -> Bool {
        guard lifecycle == .installed,
              artifact.manifest.screens.contains(where: { $0.screenId == screenId }) else {
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
        guard navigationTask == nil,
              lifecycle == .installed,
              !navigationRequests.isEmpty else {
            return
        }
        navigationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.drainNavigationRequests()
        }
    }

    private func drainNavigationRequests() async {
        while lifecycle == .installed,
              !Task.isCancelled,
              !navigationRequests.isEmpty {
            let request = navigationRequests.removeFirst()
            do {
                _ = try await ensureScreenController(for: request.screenId)
                guard lifecycle == .installed, !Task.isCancelled else {
                    request.completion(false, request.screenId)
                    break
                }
                let didNavigate = try await performMountedNavigation(
                    to: request.screenId,
                    transition: request.rawTransition
                )
                request.completion(
                    lifecycle == .installed && !Task.isCancelled && didNavigate,
                    request.screenId
                )
            } catch {
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
        try await withCheckedThrowingContinuation { continuation in
            do {
                try performNavigation(
                    to: screenId,
                    transition: rawTransition
                ) { didNavigate, _ in
                    continuation.resume(returning: didNavigate)
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func performNavigation(
        to screenId: String,
        transition rawTransition: Any?,
        completion: @escaping Completion
    ) throws {
        let spec = ExperienceScreenTransitionSpec(raw: rawTransition)
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
            || Self.forceReduceMotionForTesting

        switch spec.kind {
        case .none:
            try replaceRoot(with: screenId, completion: completion)
        case .push:
            if reduceMotion || !spec.isAnimated {
                try replaceRoot(with: screenId, completion: completion)
            } else {
                try pushOrPop(to: screenId, completion: completion)
            }
        case .modal:
            if reduceMotion || !spec.isAnimated {
                try replaceRoot(with: screenId, completion: completion)
            } else {
                try present(screenId: screenId, completion: completion)
            }
        case .fade:
            if reduceMotion || !spec.isAnimated {
                try replaceRoot(with: screenId, completion: completion)
            } else {
                try runLiveReplacementTransition(
                    to: screenId,
                    spec: spec,
                    completion: completion
                )
            }
        }
    }

    private func screenController(for screenId: String) throws -> ExperienceScreenViewController {
        if let cached = cachedControllersByScreenId[screenId] {
            return cached
        }
        throw FlowScreenTransitionCoordinatorError.screenNotMounted(screenId)
    }

    private func ensureScreenController(
        for screenId: String
    ) async throws -> ExperienceScreenViewController {
        guard !terminalScreenIds.contains(screenId) else {
            throw FlowScreenTransitionCoordinatorError.terminalScreen(screenId)
        }
        if let cached = cachedControllersByScreenId[screenId] {
            return cached
        }
        guard let screen = artifact.manifest.screens.first(where: { $0.screenId == screenId }) else {
            throw FlowScreenTransitionCoordinatorError.missingScreen(screenId)
        }
        let controller = try ExperienceScreenViewController(
            flow: flow,
            artifact: artifact,
            screen: screen,
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
            self.reportTerminalFailure(error, for: controller.screenId)
        }
        controller.setContentHidden(contentHidden)
        if let latestSnapshot {
            _ = controller.applySnapshot(latestSnapshot, screenId: screenId)
        }
        do {
            let session = try await runtimeContext.makeSession(
                descriptor: FlowRenderSessionDescriptor(
                    artboardName: screen.artboardName
                )
            )
            do {
                try await controller.mountRuntimeSession(session)
            } catch {
                session.dispose()
                throw error
            }
            guard lifecycle != .tearingDown,
                  lifecycle != .tornDown,
                  !Task.isCancelled else {
                await controller.shutdownRuntimeSession()
                throw CancellationError()
            }
            cachedControllersByScreenId[screenId] = controller
            return controller
        } catch {
            if !(error is CancellationError),
               lifecycle != .tearingDown,
               lifecycle != .tornDown {
                reportTerminalFailure(error, for: screenId)
            }
            await controller.shutdownRuntimeSession()
            throw error
        }
    }

    private func reportTerminalFailure(_ error: Error, for screenId: String) {
        guard terminalScreenIds.insert(screenId).inserted else { return }
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

    private func pushOrPop(to screenId: String, completion: @escaping Completion) throws {
        guard let navigationController else {
            try replaceRoot(with: screenId, completion: completion)
            return
        }

        if activePresentedController != nil {
            dismissActivePresentedControllerIfNeeded(animated: true) { [weak self] in
                guard let self else { return }
                do {
                    try self.performPushOrPop(to: screenId, in: navigationController, completion: completion)
                } catch {
                    LogWarning(
                        "ExperienceScreenTransitionCoordinator: failed to navigate to screen \(screenId) after modal dismiss: \(error)"
                    )
                    completion(false, screenId)
                }
            }
            return
        }

        try performPushOrPop(to: screenId, in: navigationController, completion: completion)
    }

    private func performPushOrPop(
        to screenId: String,
        in navigationController: UINavigationController,
        completion: @escaping Completion
    ) throws {
        if let existingController = navigationController.viewControllers
            .compactMap({ $0 as? ExperienceScreenViewController })
            .first(where: { $0.screenId == screenId }) {
            animateNavigationControllerOperation(screenId: screenId, completion: completion) {
                navigationController.popToViewController(existingController, animated: true)
            }
            return
        }

        let controller = try screenController(for: screenId)
        controller.loadViewIfNeeded()
        controller.setContentHidden(contentHidden)
        animateNavigationControllerOperation(screenId: screenId, completion: completion) {
            navigationController.pushViewController(controller, animated: true)
        }
    }

    private func present(screenId: String, completion: @escaping Completion) throws {
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
        presenter.present(controller, animated: true) { [weak self] in
            self?.activePresentedController = controller
            controller.advance(delta: 0)
            completion(true, screenId)
        }
    }

    nonisolated func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        Task { @MainActor [weak self] in
            self?.handlePresentedControllerDidDismiss(presentationController)
        }
    }

    private func handlePresentedControllerDidDismiss(_ presentationController: UIPresentationController) {
        guard let dismissedController = presentationController.presentedViewController as? ExperienceScreenViewController,
              activePresentedController === dismissedController else {
            return
        }

        activePresentedController = activePresenterAfterDismissing(presentationController)
        dismissedController.presentationController?.delegate = nil

        let revealingScreenId = (presentationController.presentingViewController as? ExperienceScreenViewController)?.screenId
            ?? (navigationController?.topViewController as? ExperienceScreenViewController)?.screenId
        onPresentedScreenDismissed(dismissedController.screenId, revealingScreenId)
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
        case .none, .push, .modal:
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
            case .none, .push, .modal:
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
}

private enum FlowScreenTransitionCoordinatorError: LocalizedError {
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
            return "Experience screen \(screenId) has not mounted its runtime session."
        case .terminalScreen(let screenId):
            return "Experience screen \(screenId) previously encountered a terminal runtime failure."
        }
    }
}
#endif
