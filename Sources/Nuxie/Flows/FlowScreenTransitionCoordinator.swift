#if canImport(RiveRuntime) && canImport(UIKit)
import UIKit

@MainActor
final class FlowScreenTransitionCoordinator: NSObject, UIAdaptivePresentationControllerDelegate {
    typealias Completion = (_ didNavigate: Bool, _ screenId: String) -> Void

    private weak var hostViewController: FlowViewController?
    private let flow: Flow
    private let artifact: LoadedFlowArtifact
    private weak var screenDelegate: FlowScreenViewControllerDelegate?
    private let onPresentedScreenDismissed: (_ dismissedScreenId: String, _ revealingScreenId: String?) -> Void

    private var navigationController: UINavigationController?
    private var activePresentedController: FlowScreenViewController?
    private var cachedControllersByScreenId: [String: FlowScreenViewController] = [:]
    private var latestSnapshot: FlowViewModelSnapshot?
    private var contentHidden = true
    private var activeTransitionCompletion: Completion?

    var activeScreenId: String? {
        activePresentedController?.screenId
            ?? (navigationController?.topViewController as? FlowScreenViewController)?.screenId
    }

    init(
        flow: Flow,
        artifact: LoadedFlowArtifact,
        hostViewController: FlowViewController,
        screenDelegate: FlowScreenViewControllerDelegate,
        onPresentedScreenDismissed: @escaping (_ dismissedScreenId: String, _ revealingScreenId: String?) -> Void
    ) {
        self.flow = flow
        self.artifact = artifact
        self.hostViewController = hostViewController
        self.screenDelegate = screenDelegate
        self.onPresentedScreenDismissed = onPresentedScreenDismissed
        super.init()
    }

    func install() throws {
        guard let hostViewController else { return }
        let entryController = try screenController(for: artifact.manifest.entry.screenId)
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

    func tearDown() {
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

        cachedControllersByScreenId.removeAll()
        latestSnapshot = nil
        activeTransitionCompletion = nil
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
                "FlowScreenTransitionCoordinator: failed to apply value to screen \(screenId ?? "<all>"): \(error)"
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
                "FlowScreenTransitionCoordinator: failed to apply list operation to screen \(screenId ?? "<all>"): \(error)"
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
                "FlowScreenTransitionCoordinator: failed to fire trigger on screen \(screenId ?? "<all>"): \(error)"
            )
        }
        return didFire
    }

    @discardableResult
    func navigate(to screenId: String, transition rawTransition: Any?, completion: @escaping Completion) -> Bool {
        guard artifact.manifest.screens.contains(where: { $0.screenId == screenId }) else {
            return false
        }

        if activeScreenId == screenId {
            completion(true, screenId)
            return true
        }

        let spec = FlowScreenTransitionSpec(raw: rawTransition)
        let reduceMotion = UIAccessibility.isReduceMotionEnabled || Self.forceReduceMotionForTesting

        do {
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
                    try runLiveReplacementTransition(to: screenId, spec: spec, completion: completion)
                }
            }
            return true
        } catch {
            LogWarning("FlowScreenTransitionCoordinator: failed to navigate to screen \(screenId): \(error)")
            completion(false, screenId)
            return false
        }
    }

    private func screenController(for screenId: String) throws -> FlowScreenViewController {
        if let cached = cachedControllersByScreenId[screenId] {
            return cached
        }
        guard let screen = artifact.manifest.screens.first(where: { $0.screenId == screenId }) else {
            throw FlowScreenTransitionCoordinatorError.missingScreen(screenId)
        }
        let controller = try FlowScreenViewController(
            flow: flow,
            artifact: artifact,
            screen: screen,
            delegate: screenDelegate
        )
        controller.setContentHidden(contentHidden)
        if let latestSnapshot {
            _ = controller.applySnapshot(latestSnapshot, screenId: screenId)
        }
        cachedControllersByScreenId[screenId] = controller
        return controller
    }

    private func targetControllers(for screenId: String?) throws -> [FlowScreenViewController] {
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
                        "FlowScreenTransitionCoordinator: failed to navigate to screen \(screenId) after modal dismiss: \(error)"
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
            .compactMap({ $0 as? FlowScreenViewController })
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
        guard let dismissedController = presentationController.presentedViewController as? FlowScreenViewController,
              activePresentedController === dismissedController else {
            return
        }

        activePresentedController = activePresenterAfterDismissing(presentationController)
        dismissedController.presentationController?.delegate = nil

        let revealingScreenId = (presentationController.presentingViewController as? FlowScreenViewController)?.screenId
            ?? (navigationController?.topViewController as? FlowScreenViewController)?.screenId
        onPresentedScreenDismissed(dismissedController.screenId, revealingScreenId)
    }

    private func activePresenterAfterDismissing(
        _ presentationController: UIPresentationController
    ) -> FlowScreenViewController? {
        guard let presenter = presentationController.presentingViewController as? FlowScreenViewController else {
            return nil
        }
        let presenterIsNavigationScreen = navigationController?.viewControllers.contains {
            $0 === presenter
        } ?? false
        return presenterIsNavigationScreen ? nil : presenter
    }

    private func runLiveReplacementTransition(
        to screenId: String,
        spec: FlowScreenTransitionSpec,
        completion: @escaping Completion
    ) throws {
        guard let hostView = navigationController?.view ?? hostViewController?.view,
              let currentView = activePresentedController?.view
                ?? (navigationController?.topViewController as? FlowScreenViewController)?.view else {
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
            ?? navigationController?.topViewController as? FlowScreenViewController)?
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
    case missingScreen(String)

    var errorDescription: String? {
        switch self {
        case .missingScreen(let screenId):
            return "Flow artifact does not contain screen \(screenId)."
        }
    }
}
#endif
