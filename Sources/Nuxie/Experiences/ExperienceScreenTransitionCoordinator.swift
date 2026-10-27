#if canImport(UIKit)
import UIKit

/// Owns the timing of native-page state; the coordinator owns the state writes.
@MainActor
final class ExperienceNativePageTransition {
    private enum State { case deciding, ready, starting, started, committing, committed, cancelled }
    private var state: State
    private var startTask: Task<Void, Never>?
    private var finishTask: Task<Void, Never>?
    private var cancellationTask: Task<Void, Never>?
    var retirementTimeoutNanoseconds = ExperienceRuntimeRetirement.timeoutNanoseconds
    var authoredTime: ExperienceAuthoredTime?
    @TaskLocal private static var executing: ObjectIdentifier?
    private let start: () async -> Void
    private let finish: () async -> Void
    private let abandon: () async -> Void
    private let onRetirementFailure: (Error) -> Void

    init(interactive: Bool, onRetirementFailure: @escaping (Error) -> Void = { LogError("Native page abort failed: \($0)") },
         start: @escaping () async -> Void,
         finish: @escaping () async -> Void, abandon: @escaping () async -> Void = {}) {
        state = interactive ? .deciding : .ready
        self.start = start
        self.finish = finish
        self.abandon = abandon
        self.onRetirementFailure = onRetirementFailure
    }

    func begin() async {
        if state == .ready {
            state = .starting
            startTask = Task { @MainActor in
                guard !Task.isCancelled else { return }
                await Self.$executing.withValue(ObjectIdentifier(self)) { await self.start() }
            }
        }
        await startTask?.value
        if state == .starting { state = .started }
    }

    func interactionEnded(cancelled: Bool) async {
        guard state == .deciding else { return }
        if cancelled { await cancel() }
        else { state = .ready; await begin() }
    }

    @discardableResult
    func commit() async -> Bool {
        if state == .deciding { state = .ready } // Completed delegate callback is authoritative.
        await begin()
        guard state == .started else { return false }
        state = .committing
        finishTask = Task { @MainActor in
            await Self.$executing.withValue(ObjectIdentifier(self)) { await self.finish() }
        }
        await finishTask?.value
        state = .committed
        return true
    }

    func cancel() async {
        if state == .cancelled || state == .committed { return }
        if cancellationTask == nil {
            cancellationTask = Task { @MainActor in await self.cancelUnbounded() }
        }
        guard let task = cancellationTask else { return }
        do {
            try await ExperienceRuntimeRetirement.wait(timeoutNanoseconds: retirementTimeoutNanoseconds,
                authoredTime: authoredTime) { await task.value }
        } catch { onRetirementFailure(error) }
    }

    private func cancelUnbounded() async {
        if state == .committing {
            if Self.executing != ObjectIdentifier(self) { await finishTask?.value }
            return
        }
        guard state != .committed, state != .cancelled else { return }
        let didStart = state == .starting || state == .started
        state = .cancelled
        startTask?.cancel()
        if Self.executing != ObjectIdentifier(self) { await startTask?.value }
        if didStart { await abandon() }
    }
}

@MainActor
/// Every move, a person's included, holds one queue slot until it has fully
/// landed (nuxie-handoff pages/magic-move/design-reset/sdk-ios-move-queue.md).
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
        var screenId: String
        let rawTransition: Any?
        let completion: Completion
        var backLayer: UIViewController? = nil
        var backSteps: Int = 1
        var dismissLayer: Bool = false
        var admissionLayer: UIViewController? = nil
        /// A sheet the person is swiping away; it lands, or not, when UIKit says how the swipe ended.
        var swipe: ObjectIdentifier? = nil
        /// A VoiceOver escape asked for during a move; where it goes is worked out when it starts.
        var escape = false
    }

    private enum SwipeEnd { case finished, cancelled }

    /// A swipe from UIKit's commitment (`WillDismiss`) until UIKit reports its end.
    private final class Swipe {
        var end: SwipeEnd?
        var waiters: [CheckedContinuation<SwipeEnd, Never>] = []
        /// The finger's hold on the sheet is authored time until it lifts.
        private var hold: ExperienceAuthoredTime?

        init(holding time: ExperienceAuthoredTime?) {
            hold = time
            hold?.begin()
        }

        /// What UIKit animates after the finger lifts is native time.
        func lift() {
            hold?.end()
            hold = nil
        }

        deinit { lift() }
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
    private let onScreenWillNavigate: (_ source: String, _ target: String) async -> JourneyScreenDismissalResult
    private let onProductsResolved: (_ products: [StoreProduct]) -> Void
    private let onProductsUnavailable: (_ screenId: String) async -> Void
    private let onRuntimeFailure: (_ screenId: String, _ error: Error) -> Void

    private var navigationLayers: [UIViewController] = []
    /// Sheet layers opened over another sheet, each presented from its own window.
    private var stackedSheetWindows: [ObjectIdentifier: ExperienceStackedSheetWindow] = [:]
    // Owned only while a navigation transaction mounts a controller, before stack insertion.
    private var preparedController: ExperienceScreenViewController?
    private var preparingModal = false
    private var swipes: [ObjectIdentifier: Swipe] = [:]
    private weak var closingLayer: UIViewController?

    var hasPresentedLayer: Bool { navigationLayers.count > 1 }
    /// The top Journey layer above the base, where an in-app browser opened from it belongs.
    var topPresentedLayer: UIViewController? { hasPresentedLayer ? navigationLayers.last : nil }
    private var presentationLayer: UIViewController? { navigationLayers.last }
    private var navigationController: UINavigationController? { presentationLayer as? UINavigationController }
    private var activeController: ExperienceScreenViewController? {
        (presentationLayer as? ExperienceScreenViewController)
            ?? navigationController?.topViewController as? ExperienceScreenViewController
    }
    private func screenControllers(in layer: UIViewController) -> [ExperienceScreenViewController] {
        if let navigation = layer as? UINavigationController {
            return navigation.viewControllers.compactMap { $0 as? ExperienceScreenViewController }
        }
        return (layer as? ExperienceScreenViewController).map { [$0] } ?? []
    }

    private var allScreenControllers: [ExperienceScreenViewController] {
        var seen = Set<ObjectIdentifier>()
        return navigationLayers.flatMap { screenControllers(in: $0) }.filter {
            seen.insert(ObjectIdentifier($0)).inserted
        }
    }

    var layerScreenIds: [[String]] {
        navigationLayers.map { layer in
            if let controller = layer as? ExperienceScreenViewController { return controller.pageHistory.screenIDs }
            return (layer as? UINavigationController)?.viewControllers.flatMap {
                guard let controller = $0 as? ExperienceScreenViewController else { return [String]() }
                return controller.isPageController ? controller.pageHistory.screenIDs : [controller.screenId]
            } ?? []
        }
    }

    private var nativePages: [ExperienceScreenViewController] { allScreenControllers }

    private func pageBackLocation(steps: Int) -> ExperiencePageStack.Location? {
        ExperiencePageStack.back(steps: steps, histories: nativePages.map { $0.pageHistory.screenIDs })
    }

    func backTarget(steps: Int) -> String? {
        let screens = activeController?.isPageController == true ? layerScreenIds.flatMap { $0 } : (layerScreenIds.last ?? [])
        guard !screens.isEmpty else { return nil }
        return screens[max(0, screens.count - 1 - max(1, steps))]
    }
    private var mountingControllersByScreenId: [String: ExperienceScreenViewController] = [:]
    private let videoDecoderPool: ExperienceVideoDecoderPool?
    private let authoredTime: ExperienceAuthoredTime
    /// The native time a close or teardown may take; tests shorten it.
    var retirementTimeoutNanoseconds = ExperienceRuntimeRetirement.timeoutNanoseconds
    private var latestSnapshot: ExperienceViewModelSnapshot?
    private var contentHidden = true
    private var terminalScreenIds: Set<String> = []
    private var lifecycle: Lifecycle = .idle
    private var installationTask: Task<Void, Error>?
    private var navigationTask: Task<Void, Never>?
    private var teardownTask: Task<Void, Never>?
    private var exitRetirementTask: Task<Void, Never>?
    private var pageDeparture: (controller: ObjectIdentifier, source: String, target: String,
        task: Task<JourneyScreenDismissalResult, Never>)?
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
            || preparedController === controller
            || mountingControllersByScreenId.values.contains { $0 === controller }
    }

    init(
        experience: Experience,
        artifact: LoadedExperienceArtifact,
        runValues: ExperienceRunValues = ExperienceRunValues(),
        initialScreenID: String? = nil,
        presentationDiagnosticsEnabled: Bool = false,
        videoDecoderPool: ExperienceVideoDecoderPool? = nil,
        authoredTime: ExperienceAuthoredTime = ExperienceAuthoredTime(),
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
        onScreenWillNavigate: @escaping (_ source: String, _ target: String) async -> JourneyScreenDismissalResult = { _, _ in .handled },
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
        self.authoredTime = authoredTime
        self.hostViewController = hostViewController
        self.screenDelegate = screenDelegate
        self.onPresentedScreenDismissed = onPresentedScreenDismissed
        self.onScreenHidden = onScreenHidden
        self.onScreenWillNavigate = onScreenWillNavigate
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
            preparedController = nil
            throw CancellationError()
        }
        let navigationController: UIViewController
        let navigation = ExperienceLayerNavigationController(rootViewController: entryController)
        navigation.orientationHost = hostViewController
        navigation.setNavigationBarHidden(true, animated: false)
        navigation.onEscape = { [weak self] in self?.performEscape() ?? false }
        navigationController = navigation
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
        preparedController = nil
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

    private func coverPage(_ controller: ExperienceScreenViewController, restoring snapshot: ExperienceScreenLifecycleSnapshot? = nil) async {
        await controller.coverPage(reduceMotion: reduceMotionEnabled, restoring: snapshot)
    }

    private func revealPage(_ controller: ExperienceScreenViewController, starting: Bool = false, announce: Bool = true) async {
        await controller.revealPage(reduceMotion: reduceMotionEnabled, starting: starting)
        if !starting && announce { await onScreenActive(controller.screenId) }
    }

    func activateInitialScreen() async -> String? {
        guard lifecycle == .installed,
              let activeScreenId,
              let controller = activeController else {
            return nil
        }
        if controller.isPageController { await revealPage(controller, announce: false) }
        else { await controller.activate(reduceMotion: reduceMotionEnabled) }
        return activeScreenId
    }

    func announceInitialScreenActive(_ screenId: String) async {
        guard lifecycle == .installed,
              activeScreenId == screenId else { return }
        await onScreenActive(screenId)
    }

    func exitActiveScreenForTeardown(reason: CloseReason?, alreadyDismissed: Bool = false) async {
        if exitRetirementTask == nil {
            exitRetirementTask = Task { @MainActor in
                await self.exitActiveScreenForTeardownUnbounded(reason: reason, alreadyDismissed: alreadyDismissed)
            }
        }
        guard let task = exitRetirementTask else { return }
        do { try await ExperienceRuntimeRetirement.wait(timeoutNanoseconds: retirementTimeoutNanoseconds,
            authoredTime: authoredTime) { await task.value } }
        catch { onRuntimeFailure(activeScreenId ?? initialScreenID, error) }
    }

    private func exitActiveScreenForTeardownUnbounded(reason: CloseReason?, alreadyDismissed: Bool) async {
        // Revoke navigation admission and fail queued requests: no queued
        // request may restart the drain and mount a destination after the
        // teardown hidden event. A page step already under way lands first,
        // and the dismissal exits the Screen it landed on, at most the step's
        // watchdog later; nothing is undone halfway. Other navigation, and a
        // dismissal raised by the step's own callbacks, is cancelled.
        revokeNavigationAdmission()
        if let navigationTask {
            let landsPageStep = activeController?.isPageController == true && !Self.isOnNavigationDrainTask
            if !landsPageStep { navigationTask.cancel() }
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
        if controller.isPageController { await coverPage(controller) }
        else { await controller.hide(reduceMotion: reduceMotion) }
        await onScreenHidden(activeScreenId, .teardown(reason: reason))
    }

    private func revokeNavigationAdmission() {
        navigationAdmissionRevoked = true
        let queuedRequests = navigationRequests
        navigationRequests.removeAll()
        queuedRequests.forEach { $0.completion(.failed, $0.screenId) }
    }

    func tearDown() async {
        if lifecycle == .tornDown { return }
        if teardownTask == nil {
            teardownTask = Task { @MainActor in await self.performTearDown() }
        }
        guard let task = teardownTask else { return }
        do { try await ExperienceRuntimeRetirement.wait(timeoutNanoseconds: retirementTimeoutNanoseconds,
            authoredTime: authoredTime) { await task.value } }
        catch { onRuntimeFailure(activeScreenId ?? initialScreenID, error) }
        if lifecycle == .tornDown { teardownTask = nil }
    }

    private func performTearDown() async {
        lifecycle = .tearingDown
        let transitions = Array(platformTransitions.values)
        platformTransitions.removeAll()
        for transition in transitions { await transition.cancel() }
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

        var seen = Set<ObjectIdentifier>()
        let controllers = (allScreenControllers + [preparedController].compactMap { $0 }).filter {
            seen.insert(ObjectIdentifier($0)).inserted
        }
        preparedController = nil
        preparingModal = false

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
        let pendingSwipes = swipes.keys
        for id in pendingSwipes { releaseSwipeWaiters(id) }
        swipes.removeAll()

        mountingControllersByScreenId.removeAll()
        latestSnapshot = nil
        for controller in controllers {
            // Retire retained pages without replaying an authored exit off screen.
            if controller.isPageController { await coverPage(controller) }
            else if controller.lifecyclePhase != .hidden { await controller.hide(reduceMotion: reduceMotionEnabled) }
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

    /// Re-reads each live screen's own view insets and pushes them into
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
           spec.kind != .modal, (spec.kind != .push || activeController?.isPageController != true),
           navigationTask == nil,
           navigationRequests.isEmpty {
            completion(.alreadyActive, screenId)
            return true
        }

        navigationRequests.append(NavigationRequest(
            screenId: screenId,
            rawTransition: rawTransition,
            completion: completion,
            admissionLayer: presentationLayer
        ))
        startNavigationDrainIfNeeded()
        return true
    }

    @discardableResult
    func back(to screenId: String, steps: Int, transition: Any? = nil, completion: @escaping Completion) -> Bool {
        guard lifecycle == .installed, !navigationAdmissionRevoked,
              (activeController?.isPageController == true || backTarget(steps: steps) == screenId),
              let layer = presentationLayer else { return false }
        if activeScreenId == screenId, activeController?.isPageController != true {
            completion(.alreadyActive, screenId)
            return true
        }
        navigationRequests.append(NavigationRequest(
            screenId: screenId,
            rawTransition: activeController?.isPageController == true ? transition : (transition ?? ["type": "push"]),
            completion: completion,
            backLayer: layer,
            backSteps: steps
        ))
        startNavigationDrainIfNeeded()
        return true
    }

    /// A VoiceOver escape is the person's Back 1, so the Journey is asked first.
    /// At the root of a sheet it may dismiss, it closes that sheet. It returns
    /// false when there is nowhere to go, so VoiceOver passes the escape on.
    func performEscape() -> Bool {
        guard lifecycle == .installed, !navigationAdmissionRevoked, let screenId = activeScreenId else { return false }
        let request: NavigationRequest
        if navigationTask != nil || !navigationRequests.isEmpty {
            // Like a tap on Back during a move, it waits its turn.
            request = NavigationRequest(screenId: screenId, rawTransition: nil, completion: { _, _ in }, escape: true)
        } else {
            guard let resolved = escapeRequest() else { return false }
            request = resolved
        }
        navigationRequests.append(request)
        startNavigationDrainIfNeeded()
        return true
    }

    /// Back 1 while the top layer has somewhere to go back to; at the root of a
    /// sheet the person may dismiss, a close of that sheet.
    private func escapeRequest() -> NavigationRequest? {
        guard let layer = presentationLayer, let screenId = activeScreenId else { return nil }
        if (layerScreenIds.last?.count ?? 0) > 1, let target = backTarget(steps: 1) {
            // A pushed page may show the same Screen: a page goes back by position.
            // The per-Screen path treats a Back to its own Screen as already there.
            guard activeController?.isPageController == true || target != screenId else { return nil }
            return NavigationRequest(screenId: target,
                rawTransition: activeController?.isPageController == true ? nil : ["type": "push"],
                completion: { _, _ in }, backLayer: layer)
        }
        guard hasPresentedLayer, !layer.isModalInPresentation else { return nil }
        return NavigationRequest(screenId: screenId, rawTransition: nil, completion: { _, _ in },
            backLayer: layer, dismissLayer: true)
    }

    /// Authored dismissal joins the navigation lane and keeps the native layer
    /// alive until the top screen's declared exit completes. A dismiss issued from
    /// a screen belongs to that screen's layer: when the person has already closed
    /// it, the dismiss is superseded rather than closing the next layer down.
    func closeTopLayer(issuedFrom issuingScreenId: String? = nil) async -> ExperienceScreenNavigationResult {
        guard lifecycle == .installed, !navigationAdmissionRevoked, hasPresentedLayer,
              let screenId = activeScreenId, let layer = presentationLayer else { return .failed }
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
            if let swiped = request.swipe {
                await landSwipe(swiped)
                continue
            }
            if request.escape {
                if let resolved = escapeRequest() { navigationRequests.insert(resolved, at: 0) }
                continue
            }
            let before = allScreenControllers
            let keepsDraining = await perform(request)
            // A move has landed only once every page it removed is shut down.
            for page in before where !page.hasStartedShutdown && !allScreenControllers.contains(where: { $0 === page }) {
                await page.shutdownInteractiveScreen()
            }
            if !keepsDraining { break }
        }
        navigationTask = nil
        if lifecycle == .installed, !navigationRequests.isEmpty {
            startNavigationDrainIfNeeded()
        }
    }

    /// Runs one queued move; false stops the drain.
    private func perform(_ queued: NavigationRequest) async -> Bool {
        var request = queued
        if request.backLayer != nil, !request.dismissLayer, activeController?.isPageController == true,
           let target = backTarget(steps: request.backSteps) { request.screenId = target }
        if let admitted = request.admissionLayer,
           !navigationLayers.contains(where: { $0 === admitted }) {
            request.completion(.superseded, request.screenId)
            return true
        }
        if let backLayer = request.backLayer,
           (backLayer !== presentationLayer || (!request.dismissLayer && backTarget(steps: request.backSteps) != request.screenId)) {
            request.completion(.superseded, request.screenId)
            return true
        }
        let sourceLayer = presentationLayer
        do {
            if request.dismissLayer {
                let closed = await performAuthoredLayerDismissal()
                request.completion(closed ? .navigated : .superseded, request.screenId)
                return true
            }
            let spec = ExperienceScreenTransitionSpec(raw: request.rawTransition)
            if activeController?.isPageController == true, activeScreenId == request.screenId,
               spec.kind != .modal, spec.kind != .push, request.backLayer == nil {
                request.completion(.alreadyActive, request.screenId)
                return true
            }
            let opensLayer = request.backLayer == nil && spec.kind == .modal
            preparingModal = opensLayer
            if request.backLayer == nil || activeController?.isPageController != true {
                _ = try await ensureScreenController(for: request.screenId,
                    opensPage: activeController?.isPageController == true && (spec.kind == .push || spec.kind == .modal))
            }
            guard lifecycle == .installed, !Task.isCancelled,
                  !navigationAdmissionRevoked, presentationLayer === sourceLayer else {
                await discardUncommittedController()
                request.completion(presentationLayer !== sourceLayer ? .superseded : .failed, request.screenId)
                return true
            }
            let pageStep = activeController?.isPageController == true
            let didNavigate = try await performMountedNavigation(
                to: request.screenId,
                transition: request.rawTransition,
                isBack: request.backLayer != nil,
                backSteps: request.backSteps
            )
            if didNavigate { pageDeparture = nil }
            await discardUncommittedController()
            // A page step that started lands even after admission is revoked.
            let completed = lifecycle == .installed && !Task.isCancelled
                && (!navigationAdmissionRevoked || pageStep) && didNavigate
            request.completion(
                completed ? .navigated : (presentationLayer !== sourceLayer ? .superseded : .failed),
                request.screenId
            )
        } catch {
            await discardUncommittedController()
            if presentationLayer !== sourceLayer {
                request.completion(.superseded, request.screenId)
                return true
            }
            if case ExperienceError.productsUnavailable = error {
                request.completion(.productsUnavailable, request.screenId)
                for queued in navigationRequests {
                    queued.completion(.failed, queued.screenId)
                }
                navigationRequests.removeAll()
                await onProductsUnavailable(request.screenId)
                return false
            }
            LogWarning(
                "ExperienceScreenTransitionCoordinator: failed to navigate to screen \(request.screenId): \(error)"
            )
            request.completion(presentationLayer !== sourceLayer ? .superseded : .failed, request.screenId)
        }
        return true
    }

    private func performMountedNavigation(
        to screenId: String,
        transition rawTransition: Any?,
        isBack: Bool,
        backSteps: Int = 1
    ) async throws -> Bool {
        if let controller = activeController, controller.isPageController {
            let spec = ExperienceScreenTransitionSpec.pageTransition(raw: rawTransition,
                sourceScreenID: controller.screenId, isBack: isBack,
                inferredBack: isBack ? controller.pageHistory.backTransition(steps: backSteps, target: screenId,
                    declarations: artifact.renderPlan.transitions) : .none)
            return try await performPageNavigation(to: screenId, rawTransition: rawTransition,
                spec: spec,
                isBack: isBack, backSteps: backSteps)
        }
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

    private func performPageNavigation(to screenID: String, rawTransition: Any?,
                                       spec: ExperienceScreenTransitionSpec, isBack: Bool, backSteps: Int) async throws -> Bool {
        guard let source = activeController else { return false }
        let reduceMotion = reduceMotionEnabled
        let container = presentationLayer
        let backLocation = isBack ? pageBackLocation(steps: backSteps) : nil
        let lower = backLocation.flatMap { nativePages.indices.contains($0.page) ? nativePages[$0.page] : nil }
        let opensLayer = !isBack && (spec.kind == .push || spec.kind == .modal)
        if !opensLayer && (source.screenId != screenID || lower.map({ $0 !== source }) == true) {
            // Settle the durable Journey checkpoint before any exit or page step.
            // Opening a layer only covers its presenter; it is not a dismissal.
            source.setPageInputEnabled(false)
            source.setCheckpointHold(true)
            let task: Task<JourneyScreenDismissalResult, Never>
            if let prepared = pageDeparture, prepared.controller == ObjectIdentifier(source),
               prepared.source == source.screenId, prepared.target == screenID {
                task = prepared.task
            } else {
                let sourceID = source.screenId
                task = Task { @MainActor in
                    return await self.onScreenWillNavigate(sourceID, screenID)
                }
                pageDeparture = (controller: ObjectIdentifier(source), source: sourceID, target: screenID, task: task)
            }
            let result = await task.value
            source.setCheckpointHold(false)
            guard result == .handled, lifecycle == .installed, !Task.isCancelled,
                  !navigationAdmissionRevoked, activeController === source else { return false }
            source.setPageInputEnabled(true)
        }
        if isBack, let lower, lower !== source {
            try await ExperiencePageBack.perform(cut: {
                if lower.screenId != screenID || lower.pageHistory.entries.count - 1 != backLocation?.entry {
                    guard let page = lower.interactivePage else { throw CancellationError() }
                    let products = try await page.products(screenID: screenID)
                    try await lower.preparePageRow(screenID: screenID, products: products)
                    // A page under a sheet keeps playing, so it is hidden before its Screen changes unseen.
                    // A trim to an earlier entry of the same Screen writes no phase and leaves it playing.
                    if lower.screenId != screenID, lower.isUnderLayer { await self.coverPage(lower) }
                    try await lower.navigatePage(to: screenID, spec: .none, isBack: true, reduceMotion: true,
                        backSteps: lower.pageHistory.entries.count - 1 - (backLocation?.entry ?? 0), coveredCut: true,
                        isEligible: { self.lifecycle == .installed && !self.navigationAdmissionRevoked },
                        isLive: { self.lifecycle == .installed },
                        onHidden: {}, onActive: {})
                }
            }, pop: {
                let transition = self.pageTransition(revealing: lower, covering: nil, interactive: false)
                do {
                    while self.presentationLayer !== lower.navigationController, self.hasPresentedLayer {
                        // Back owns activation after all modal dismissals and the final pop. The
                        // destination's reveal starts where UIKit uncovers it: the last dismissal, or the pop.
                        let uncovers = self.pageBelowPresentedLayer === lower
                        guard await self.performAuthoredLayerDismissal(activateRevealedPage: false,
                            beginning: uncovers ? transition : nil) else { throw CancellationError() }
                    }
                    guard let navigation = lower.navigationController else { throw CancellationError() }
                    if navigation.topViewController !== lower {
                        let leaving = self.activeController
                        if let leaving {
                            await leaving.performExitHandshake(reduceMotion: reduceMotion, exitReason: .navigation)
                        }
                        await transition.begin()
                        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                            self.animateNavigationControllerOperation(screenId: screenID, completion: { result, _ in
                                if result.reachedTarget { continuation.resume() }
                                else { continuation.resume(throwing: CancellationError()) }
                            }) { navigation.popToViewController(lower, animated: !reduceMotion) }
                        }
                        if let leaving { await self.coverPage(leaving) }
                        if let leaving { await self.onScreenHidden(leaving.screenId, .navigation(revealingScreenId: screenID)) }
                    }
                    await transition.commit()
                } catch {
                    await transition.cancel()
                    throw error
                }
            })
            return true
        }
        if spec.kind != .push && spec.kind != .modal || isBack {
            let sourceID = source.screenId
            try await source.navigatePage(to: screenID, spec: spec, isBack: isBack, reduceMotion: reduceMotion,
                backSteps: backSteps, isEligible: { self.lifecycle == .installed && !self.navigationAdmissionRevoked
                    && self.activeController === source && !self.terminalScreenIds.contains(screenID) },
                isLive: { self.lifecycle == .installed && self.activeController === source },
                onHidden: { await self.onScreenHidden(sourceID, .navigation(revealingScreenId: screenID)) },
                onActive: { await self.onScreenActive(screenID) })
            return true
        }
        let target = try screenController(for: screenID)
        let modal = spec.kind == .modal
        let stacksSheet = modal && opensStackedSheet(spec.presentation)
        let available = container?.view.bounds.size ?? target.view.bounds.size
        try await target.configurePresentationHeight(modal ? spec.presentation : .init(kind: .fullscreen),
            target: target, availableSize: available)
        try await target.preparePagePresentationPhase(.entering, reduceMotion: reduceMotion)
        let transition = pageTransition(revealing: target, covering: source, interactive: false, opensLayer: modal)
        await transition.begin()
        let completed: Bool
        do {
            completed = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                do {
                    let completion: Completion = { result, _ in continuation.resume(returning: result.reachedTarget) }
                    if modal {
                        try present(screenId: screenID, presentation: spec.presentation,
                            animated: spec.shouldAnimate(reduceMotion: reduceMotion), stacksSheet: stacksSheet, completion: completion)
                    } else {
                        guard let navigationController else { throw ExperienceScreenTransitionCoordinatorError.hostUnavailable }
                        animateNavigationControllerOperation(screenId: screenID, completion: completion) {
                            navigationController.pushViewController(target, animated: spec.shouldAnimate(reduceMotion: reduceMotion))
                        }
                    }
                } catch { continuation.resume(throwing: error) }
            }
        } catch {
            await transition.cancel()
            throw error
        }
        guard completed else {
            await transition.cancel()
            return false
        }
        await transition.commit()
        return true
    }

    private var platformTransitions: [ObjectIdentifier: ExperienceNativePageTransition] = [:]

    // Internal so hosted tests can drive the same UIKit decision boundary deterministically.
    func pageTransition(revealing page: ExperienceScreenViewController,
                        covering outgoing: ExperienceScreenViewController?, interactive: Bool,
                        announce: Bool = true, opensLayer: Bool = false) -> ExperienceNativePageTransition {
        let previous = page.pageLifecycleSnapshot
        let underLayer = page.isUnderLayer
        let transition = ExperienceNativePageTransition(interactive: interactive, onRetirementFailure: { [weak self] error in
            self?.onRuntimeFailure(page.screenId, error)
        }, start: { [weak self] in
            guard let self, self.lifecycle == .installed else { return }
            // As on SDK main, a layer covers its presenter before UIKit presents it, so the
            // presenter keeps drawing through the animation.
            if opensLayer { outgoing?.coverPageByLayer() }
            await self.revealPage(page, starting: true)
        }, finish: { [weak self] in
            guard let self, self.lifecycle == .installed else { return }
            if let outgoing, !opensLayer { await self.coverPage(outgoing) }
            await self.revealPage(page, announce: announce)
        }, abandon: { [weak self] in
            guard let self, self.lifecycle == .installed else { return }
            if previous.phase == .hidden { await self.coverPage(page, restoring: previous) }
            else if underLayer { page.coverPageByLayer() }
            else { await self.coverPage(page) }
            if let outgoing { await self.revealPage(outgoing, announce: false) }
        })
        transition.authoredTime = authoredTime
        return transition
    }

    private func observe(_ transition: ExperienceNativePageTransition,
                         coordinator: (any UIViewControllerTransitionCoordinator)?) {
        Task { @MainActor in await transition.begin() }
        guard let coordinator else { return }
        if coordinator.isInteractive {
            coordinator.notifyWhenInteractionChanges { context in
                let cancelled = context.isCancelled
                Task { @MainActor in await transition.interactionEnded(cancelled: cancelled) }
            }
        }
        coordinator.animate(alongsideTransition: nil) { context in
            let cancelled = context.isCancelled
            Task { @MainActor in
                if cancelled { await transition.cancel() }
                // Successful completion is committed by the move or swipe that lands, after stack bookkeeping.
            }
        }
    }

    private func performNavigation(
        to screenId: String,
        transition rawTransition: Any?,
        sourceController: ExperienceScreenViewController?,
        targetController: ExperienceScreenViewController,
        reduceMotion: Bool,
        isBack: Bool = false
    ) async throws -> Bool {
        let sourceLayer = presentationLayer
        // The screen enters in the host's appearance now, though it waited out of the
        // window (behind another) while it changed.
        targetController.adoptHostTraits(hostViewController?.traitCollection)
        let spec = ExperienceScreenTransitionSpec(raw: rawTransition)
        let opensLayer = spec.kind == .modal && !isBack
        // Decided once, so the size measured and the window presented from always agree.
        let stacksSheet = opensLayer && opensStackedSheet(spec.presentation)
        let isRetainedTarget = (sourceLayer as? UINavigationController)?.viewControllers.contains(where: { $0 === targetController }) == true
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
                      self.presentationLayer === sourceLayer else {
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
                if !opensLayer, self.presentationLayer === sourceLayer,
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
            awaitCompletion: { [authoredTime] in
                await ExperienceAuthoredTime.during(authoredTime) {
                    await ExperienceScreenExitWatchdog.wait(
                        for: [outgoingWaiter.stream, incomingWaiter.stream],
                        watchdogMilliseconds: plan.watchdogMilliseconds
                    )
                }
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
        if let preparedController, preparedController.retainedScreenIDs.contains(screenId) { return preparedController }
        if let live = allScreenControllers.reversed().first(where: { $0.retainedScreenIDs.contains(screenId) }) {
            return live
        }
        throw ExperienceScreenTransitionCoordinatorError.screenNotMounted(screenId)
    }

    private func ensureScreenController(
        for screenId: String, opensPage: Bool = false
    ) async throws -> ExperienceScreenViewController {
        guard !terminalScreenIds.contains(screenId) else {
            throw ExperienceScreenTransitionCoordinatorError.terminalScreen(screenId)
        }
        if !opensPage, !preparingModal, let controller = activeController, controller.isPageController {
            guard let layer = controller.interactivePage else {
                throw ExperienceScreenTransitionCoordinatorError.screenNotMounted(screenId)
            }
            let isFirstPreparation = !controller.retainedScreenIDs.contains(screenId)
            let products: [StoreProduct]
            if isFirstPreparation {
                products = try await artifact.resolvingProducts(for: screenId).acquired.products
            } else {
                products = try await layer.products(screenID: screenId)
            }
            onProductsResolved(products)
            try await controller.preparePageRow(screenID: screenId, products: products)
            if isFirstPreparation, let latestSnapshot {
                _ = controller.applySnapshot(latestSnapshot, screenId: screenId)
            }
            return controller
        }
        if !opensPage, !preparingModal, let layer = presentationLayer,
           let existing = screenControllers(in: layer).reversed().first(where: { $0.screenId == screenId && !$0.isPageController }) {
            existing.adoptHostTraits(hostViewController?.traitCollection)
            return existing
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
        controller.authoredTime = authoredTime
        mountingControllersByScreenId[screenId] = controller
        defer {
            if mountingControllersByScreenId[screenId] === controller {
                mountingControllersByScreenId.removeValue(forKey: screenId)
            }
        }
        controller.onRuntimeFailure = { [weak self, weak controller] error in
            guard let self, let controller else { return }
            let screenIDs = controller.retainedScreenIDs
            Task { @MainActor [weak self] in
                guard let self else { return }
                for id in screenIDs { await self.reportTerminalFailure(error, for: id) }
            }
        }
        controller.setContentHidden(contentHidden)
        do {
            try await controller.mountInteractiveScreen(hostTraits: hostViewController?.traitCollection)
            guard lifecycle != .tearingDown,
                  lifecycle != .tornDown,
                  !Task.isCancelled else {
                throw CancellationError()
            }
            if let latestSnapshot {
                guard controller.applySnapshot(latestSnapshot, screenId: screenId) else {
                    throw ExperienceScreenTransitionCoordinatorError.screenNotMounted(screenId)
                }
            }
            controller.setContentHidden(contentHidden)
            preparedController = controller
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
            if controller.isPageController { await coverPage(controller) }
            else { await controller.hide(reduceMotion: reduceMotionEnabled) }
            await onScreenHidden(screenId, .runtimeFailure)
        }
        onRuntimeFailure(screenId, error)
    }

    private func targetControllers(for screenId: String?) throws -> [ExperienceScreenViewController] {
        if let screenId {
            // Topmost live page containing the row wins, including duplicate Screen ids.
            guard let controller = allScreenControllers.reversed().first(where: { $0.retainedScreenIDs.contains(screenId) }) else {
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
        guard let presenter = presentationLayer ?? hostViewController,
              preparingModal else {
            throw ExperienceScreenTransitionCoordinatorError.hostUnavailable
        }
        guard presenter.presentedViewController == nil, presenter.viewIfLoaded?.window != nil else {
            throw ExperienceScreenTransitionCoordinatorError.presenterBusy
        }
        let controller = try screenController(for: screenId)
        let layer: UIViewController
        let navigation = ExperienceLayerNavigationController(rootViewController: controller)
        navigation.orientationHost = hostViewController
        navigation.setNavigationBarHidden(true, animated: false)
        navigation.onEscape = { [weak self] in self?.performEscape() ?? false }
        navigation.onAppear = { [weak self, weak navigation] in
            if let self, let navigation { self.layerDidAppear(navigation) }
        }
        layer = navigation
        layer.view.backgroundColor = UIColor(nuxieRGBAHex: experience.behaviorPresentation.backgroundColor)
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
        preparingModal = false
    }

    private func discardUncommittedController() async {
        let controller = preparedController
        preparedController = nil
        preparingModal = false
        if let controller, !allScreenControllers.contains(where: { $0 === controller }) {
            await controller.shutdownInteractiveScreen()
        }
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
              let lower = hasPresentedLayer ? presentationLayer : hostViewController,
              lower.presentingViewController != nil else { return false }
        return lower.modalPresentationStyle == .pageSheet || lower.modalPresentationStyle == .formSheet
    }

    nonisolated func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        MainActor.assumeIsolated { handlePresentedControllerDidDismiss(presentationController) }
    }

    private func performAuthoredLayerDismissal(activateRevealedPage: Bool = true,
                                               beginning reveal: ExperienceNativePageTransition? = nil) async -> Bool {
        guard hasPresentedLayer, let layer = presentationLayer,
              let controller = activeController, closingLayer == nil else { return false }
        closingLayer = layer
        layer.view.isUserInteractionEnabled = false
        // This is an authored close, including closedby none. UIKit must not
        // remove its surface while the declared exit is still drawing.
        layer.isModalInPresentation = true
        await controller.performExitHandshake(reduceMotion: reduceMotionEnabled, exitReason: .dismissed)
        guard lifecycle == .installed, !Task.isCancelled, presentationLayer === layer else {
            closingLayer = nil
            return false
        }
        if let reveal { await reveal.begin() }
        else if activateRevealedPage, let revealed = pageBelowPresentedLayer, revealed.isPageController {
            let transition = pageTransition(revealing: revealed, covering: controller, interactive: false)
            platformTransitions[ObjectIdentifier(layer)] = transition
            await transition.begin()
        }
        let id = ObjectIdentifier(layer)
        if swipes[id] != nil {
            // The person is already swiping this sheet away: this move takes the
            // swipe over and lands on UIKit's end instead of dismissing again.
            navigationRequests.removeAll { $0.swipe == id }
            let end = await swipeEnd(id)
            swipes.removeValue(forKey: id)
            if end == .finished || layer.presentingViewController == nil {
                await finishLayerDismissal(layer, controller: controller, alreadyDismissed: true,
                    activateRevealedPage: activateRevealedPage)
                closingLayer = nil
                return true
            }
        }
        layer.presentationController?.delegate = nil
        // Never wait on a presenter that has already let the sheet go.
        if let presenter = layer.presentingViewController {
            await withCheckedContinuation { continuation in
                presenter.dismiss(animated: !reduceMotionEnabled) { continuation.resume() }
            }
        }
        await finishLayerDismissal(layer, controller: controller, alreadyDismissed: false,
            activateRevealedPage: activateRevealedPage)
        closingLayer = nil
        return true
    }

    private var pageBelowPresentedLayer: ExperienceScreenViewController? {
        guard navigationLayers.count > 1 else { return nil }
        let layer = navigationLayers[navigationLayers.count - 2]
        return (layer as? UINavigationController)?.topViewController as? ExperienceScreenViewController
    }

    /// UIKit's question takes nothing, since it may never dismiss: a swipe may
    /// start only while no move runs or waits.
    var acceptsSwipe: Bool {
        lifecycle == .installed && !navigationAdmissionRevoked && navigationTask == nil
            && navigationRequests.isEmpty && swipes.isEmpty
    }

    nonisolated func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
        MainActor.assumeIsolated { acceptsSwipe }
    }

    nonisolated func presentationControllerWillDismiss(_ presentationController: UIPresentationController) {
        MainActor.assumeIsolated {
            let layer = presentationController.presentedViewController
            guard presentationLayer === layer else { return }
            beginSwipe(of: layer, revealsPageBelow: true)
        }
    }

    /// UIKit has committed to a swipe. It takes the queue's slot, or waits first
    /// in line behind the move already running, until UIKit reports its end.
    /// `platform` lets hosted tests supply UIKit's transition coordinator.
    func beginSwipe(of layer: UIViewController, revealsPageBelow: Bool,
                    platform suppliedPlatform: (any UIViewControllerTransitionCoordinator)? = nil) {
        let id = ObjectIdentifier(layer)
        guard lifecycle == .installed, swipes[id] == nil else { return }
        let idle = navigationTask == nil
        let platform = suppliedPlatform ?? layer.transitionCoordinator
        // Only a swipe UIKit says a finger drives pauses the clock, since UIKit
        // then also says when the finger lifts.
        let holding = platform?.isInteractive == true
        let swipe = Swipe(holding: holding ? authoredTime : nil)
        swipes[id] = swipe
        navigationRequests.insert(NavigationRequest(screenId: activeScreenId ?? initialScreenID, rawTransition: nil,
            completion: { _, _ in }, swipe: id), at: 0)
        if holding {
            platform?.notifyWhenInteractionChanges { [weak swipe] _ in swipe?.lift() }
        }
        // Only an idle queue lets the page below start under the person's finger.
        if idle, revealsPageBelow, let page = pageBelowPresentedLayer, page.isPageController,
           let outgoing = activeController {
            // Without a coordinator, wait for UIKit's end rather than speculate.
            let transition = pageTransition(revealing: page, covering: outgoing,
                interactive: platform?.isInteractive ?? true)
            platformTransitions[id] = transition
            observe(transition, coordinator: platform)
        }
        platform?.animate(alongsideTransition: nil) { [weak self] context in
            guard context.isCancelled else { return }
            MainActor.assumeIsolated { self?.endSwipe(id, .cancelled) }
        }
        startNavigationDrainIfNeeded()
    }

    /// The Experience's own sheet has been swiped away. The close that follows
    /// fails anything queued during the drag before the swipe gives up its slot.
    func closeAfterSwipe(of layer: UIViewController) {
        revokeNavigationAdmission()
        endSwipe(ObjectIdentifier(layer), .finished)
    }

    /// UIKit shows a sheet again when the person cancels its dismissal, with or
    /// without a transition coordinator.
    func layerDidAppear(_ layer: UIViewController) {
        guard layer.presentingViewController != nil, !layer.isBeingDismissed else { return }
        endSwipe(ObjectIdentifier(layer), .cancelled)
    }

    private func endSwipe(_ id: ObjectIdentifier, _ end: SwipeEnd) {
        guard let swipe = swipes[id], swipe.end == nil else { return }
        swipe.end = end
        swipe.lift()
        let waiters = swipe.waiters
        swipe.waiters.removeAll()
        waiters.forEach { $0.resume(returning: end) }
    }

    private func releaseSwipeWaiters(_ id: ObjectIdentifier) {
        guard let swipe = swipes[id] else { return }
        let waiters = swipe.waiters
        swipe.waiters.removeAll()
        waiters.forEach { $0.resume(returning: .cancelled) }
    }

    /// The finger's hold pauses the clock (see `Swipe`); the rest of the wait is native time.
    private func swipeEnd(_ id: ObjectIdentifier) async -> SwipeEnd {
        guard let swipe = swipes[id] else { return .cancelled }
        if let end = swipe.end { return end }
        if Task.isCancelled { return .cancelled }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { swipe.waiters.append($0) }
        } onCancel: {
            Task { @MainActor [weak self] in self?.releaseSwipeWaiters(id) }
        }
    }

    /// A swipe holds the slot until UIKit reports its end. A finished one lands
    /// like a close of its layer; a cancelled one undoes the page it started.
    private func landSwipe(_ id: ObjectIdentifier) async {
        let end = await swipeEnd(id)
        swipes.removeValue(forKey: id)
        guard end == .finished else {
            await platformTransitions.removeValue(forKey: id)?.cancel()
            return
        }
        guard lifecycle == .installed,
              let layer = navigationLayers.first(where: { ObjectIdentifier($0) == id }),
              let controller = (layer as? ExperienceScreenViewController)
                ?? (layer as? UINavigationController)?.topViewController as? ExperienceScreenViewController else { return }
        await finishLayerDismissal(layer, controller: controller, alreadyDismissed: true)
    }

    nonisolated func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
        MainActor.assumeIsolated {
            let transition = platformTransitions.removeValue(forKey: ObjectIdentifier(presentationController.presentedViewController))
            Task { @MainActor in await transition?.cancel() }
        }
    }

    private func handlePresentedControllerDidDismiss(_ presentationController: UIPresentationController) {
        let layer = presentationController.presentedViewController
        let id = ObjectIdentifier(layer)
        guard lifecycle == .installed, navigationLayers.dropFirst().contains(where: { $0 === layer }) else { return }
        if swipes[id] == nil {
            // UIKit removed the sheet without asking: it lands after the running
            // move and before anything queued.
            swipes[id] = Swipe(holding: nil)
            navigationRequests.insert(NavigationRequest(screenId: activeScreenId ?? initialScreenID, rawTransition: nil,
                completion: { _, _ in }, swipe: id), at: 0)
        }
        endSwipe(id, .finished)
        startNavigationDrainIfNeeded()
    }

    private func finishLayerDismissal(_ layer: UIViewController,
                                      controller: ExperienceScreenViewController,
                                      alreadyDismissed: Bool,
                                      activateRevealedPage: Bool = true) async {
        guard presentationLayer === layer, hasPresentedLayer else { return }
        let retiringPages = screenControllers(in: layer)
        layer.presentationController?.delegate = nil
        navigationLayers.removeLast()
        stackedSheetWindows.removeValue(forKey: ObjectIdentifier(layer))?.close()
        let revealingController = activeController
        if alreadyDismissed {
            await controller.markExiting(reduceMotion: reduceMotionEnabled, exitReason: .dismissed)
        }
        if controller.isPageController { await coverPage(controller) }
        else { await controller.hide(reduceMotion: reduceMotionEnabled) }
        if alreadyDismissed {
            await onPresentedScreenDismissed(controller.screenId, revealingController?.screenId)
        } else {
            await onScreenHidden(controller.screenId,
                .init(revealingScreenId: revealingController?.screenId, method: "journey"))
        }
        if activateRevealedPage, let revealingController {
            if revealingController.isPageController {
                let transition = platformTransitions.removeValue(forKey: ObjectIdentifier(layer))
                    ?? pageTransition(revealing: revealingController, covering: nil, interactive: false)
                await transition.commit()
            }
            else {
                revealingController.setCoveredByLayer(false)
                await onScreenActive(revealingController.screenId)
            }
        }
        var retired = Set<ObjectIdentifier>()
        for controller in retiringPages where retired.insert(ObjectIdentifier(controller)).inserted {
            await controller.shutdownInteractiveScreen()
        }
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
        var cancelled = false
        let finish = ExperienceNavigationCompletion { [weak self] in
            if cancelled { completion(.superseded, screenId) }
            else { self?.completeNavigation(to: screenId, completion: completion) }
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            if !finish.awaitsTransition { finish.run() }
        }
        operation()
        if let transition = navigationController?.transitionCoordinator {
            finish.awaitsTransition = transition.animate(alongsideTransition: nil) { context in
                cancelled = context.isCancelled
                finish.run()
            }
        }
        CATransaction.commit()
    }

    private func completeNavigation(to screenId: String, completion: Completion) {
        (allScreenControllers.reversed().first { $0.retainedScreenIDs.contains(screenId) })?
            .advance(delta: 0)
        completion(.navigated, screenId)
    }

    private var reduceMotionEnabled: Bool {
        UIAccessibility.isReduceMotionEnabled
    }

    private func refreshReduceMotionState() async {
        await updateReduceMotion(reduceMotionEnabled)
    }

    func updateReduceMotion(_ value: Bool) async {
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
    /// Every pop is the queue's own: an escape becomes a queued Back.
    var onEscape: (() -> Bool)?
    /// UIKit shows a sheet again when the person cancels its dismissal.
    var onAppear: (() -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        // The bar is hidden, which already turns the edge swipe off; this does not rely on that.
        interactivePopGestureRecognizer?.isEnabled = false
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        onAppear?()
    }

    override func accessibilityPerformEscape() -> Bool { onEscape?() ?? false }

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
