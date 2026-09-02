import Foundation

protocol DeviceLegPresentationReservation: AnyObject, Sendable {
    @MainActor func release()
}

enum DeviceLegSurfaceOutcome: Equatable, Sendable {
    case dismissed
    case abandoned
}

enum DeviceLegProductFailureResult: Equatable, Sendable {
    case handled
    case completed
    case rejected
}

enum DeviceLegScreenDismissalResult: Equatable, Sendable {
    case handled
    case completed
    case rejected
}

extension ScreenEmissionValue {
    var releaseJSONValue: ExperienceReleaseJSONValue {
        switch self {
        case .null:
            return .null
        case .bool(let value):
            return .bool(value)
        case .number(let value):
            return .number(value)
        case .string(let value):
            return .string(value)
        case .array(let values):
            return .array(values.map(\.releaseJSONValue))
        case .object(let values):
            return .object(ExactJSONObject(
                values.mapValues(\.releaseJSONValue)
            ))
        }
    }
}

struct DeviceLegPresentationRequest: Sendable {
    let release: AuthenticatedDeviceLegRelease
    let delivery: ExperienceReleaseDelivery
    let screenId: String
    let journeyId: String
    let ownerDistinctId: String
    let reservation: (any DeviceLegPresentationReservation)?
    let onScreenChanged:
        @MainActor @Sendable (String) async -> Bool
    let onScreenDismissed:
        @MainActor @Sendable (String, String?, String) async
            -> DeviceLegScreenDismissalResult
    let onProductsUnavailable:
        @MainActor @Sendable (String) async -> DeviceLegProductFailureResult
    let onEmissionBatch:
        @MainActor @Sendable (ScreenEmissionBatch) async -> Bool
    let onPermissionEvent:
        @Sendable (
            String,
            UncheckedSendable<[String: Any]>
        ) -> Void
    let onPresentationRevealed:
        @MainActor @Sendable () async -> Void
    let onOutcome:
        @MainActor @Sendable (DeviceLegSurfaceOutcome, String?) async -> Bool
    let onPresentationFinished:
        @MainActor @Sendable () -> Void

    init(
        release: AuthenticatedDeviceLegRelease,
        delivery: ExperienceReleaseDelivery,
        screenId: String,
        journeyId: String,
        ownerDistinctId: String,
        reservation: (any DeviceLegPresentationReservation)?,
        onScreenChanged:
            @escaping @MainActor @Sendable (String) async -> Bool = { _ in true },
        onScreenDismissed:
            @escaping @MainActor @Sendable (String, String?, String) async
                -> DeviceLegScreenDismissalResult = { _, _, _ in
                .handled
            },
        onProductsUnavailable:
            @escaping @MainActor @Sendable (String) async -> DeviceLegProductFailureResult = {
                _ in .rejected
            },
        onEmissionBatch:
            @escaping @MainActor @Sendable (ScreenEmissionBatch) async -> Bool,
        onPermissionEvent:
            @escaping @Sendable (
                String,
                UncheckedSendable<[String: Any]>
            ) -> Void = { _, _ in },
        onPresentationRevealed:
            @escaping @MainActor @Sendable () async -> Void = {},
        onOutcome:
            @escaping @MainActor @Sendable (DeviceLegSurfaceOutcome, String?) async -> Bool,
        onPresentationFinished:
            @escaping @MainActor @Sendable () -> Void = {}
    ) {
        self.release = release
        self.delivery = delivery
        self.screenId = screenId
        self.journeyId = journeyId
        self.ownerDistinctId = ownerDistinctId
        self.reservation = reservation
        self.onScreenChanged = onScreenChanged
        self.onScreenDismissed = onScreenDismissed
        self.onProductsUnavailable = onProductsUnavailable
        self.onEmissionBatch = onEmissionBatch
        self.onPermissionEvent = onPermissionEvent
        self.onPresentationRevealed = onPresentationRevealed
        self.onOutcome = onOutcome
        self.onPresentationFinished = onPresentationFinished
    }
}

enum DeviceLegPresentationResult: Equatable, Sendable {
    case shown
    case declined
    case failed
}

enum DeviceLegPresentationNavigationResult: Equatable, Sendable {
    case navigated
    case alreadyActive
    case productsUnavailable
    case noPresentation
    case declined
    case failed
}

struct DeviceLegPresentationPermissionEvent: Equatable, Sendable {
    let name: String
    let properties: [String: String]
}

enum DeviceLegPresentationActionResult: Equatable, Sendable {
    case advanced(outlet: String)
    case permissionResolved(
        outlet: String,
        event: DeviceLegPresentationPermissionEvent
    )
    case awaitingOutcome
    case handled
    case productsUnavailable
    case noPresentation
    case declined
    case failed
}

protocol DeviceLegPresenting: AnyObject, Sendable {
    @MainActor
    func setDeviceLegPresentationAvailabilityHandler(
        _ handler: (@MainActor @Sendable () -> Void)?
    )

    @MainActor
    func reserveDeviceLegPresentation(
        ownerDistinctId: String
    ) -> (any DeviceLegPresentationReservation)?

    @MainActor
    func ownsDeviceLegPresentation(
        journeyId: String,
        ownerDistinctId: String
    ) -> Bool

    @MainActor
    func presentDeviceLeg(
        _ request: DeviceLegPresentationRequest
    ) async -> DeviceLegPresentationResult

    @MainActor
    func navigateDeviceLegPresentation(
        journeyId: String,
        ownerDistinctId: String,
        screenId: String,
        transition: ExperienceReleaseJSONValue?
    ) async -> DeviceLegPresentationNavigationResult

    @MainActor
    func resolveDeviceLegPresentationAction(
        journeyId: String,
        ownerDistinctId: String,
        action: [String: ExperienceReleaseJSONValue],
        source: ScreenEmissionSource?
    ) -> [String: ExperienceReleaseJSONValue]?

    @MainActor
    func dispatchDeviceLegPresentationAction(
        journeyId: String,
        ownerDistinctId: String,
        action: [String: ExperienceReleaseJSONValue],
        effectId: String
    ) async -> DeviceLegPresentationActionResult

    @MainActor
    func finishDeviceLegPresentation(
        journeyId: String,
        ownerDistinctId: String
    ) async

    @MainActor
    func shutdownDeviceLegPresentation(ownerDistinctId: String) async
}

@MainActor
final class DeviceLegRuntimeDelegate {
    nonisolated let introEligibilityAuthorizationContext:
        IntroEligibilityAuthorizationContext
    nonisolated private let journeyId: String
    private let onEmissionBatch:
        @MainActor @Sendable (ScreenEmissionBatch) async -> Bool
    nonisolated private let onPermissionEvent:
        @Sendable (
            String,
            UncheckedSendable<[String: Any]>
        ) -> Void
    private let onScreenChanged:
        @MainActor @Sendable (String) async -> Bool
    private let onScreenDismissed:
        @MainActor @Sendable (String, String?, String) async
            -> DeviceLegScreenDismissalResult
    private let onProductsUnavailable:
        @MainActor @Sendable (String) async -> DeviceLegProductFailureResult
    private let onPresentationRevealed:
        @MainActor @Sendable () async -> Void
    private let onOutcome:
        @MainActor @Sendable (DeviceLegSurfaceOutcome, String?) async -> Bool
    private let onPresentationFinished:
        @MainActor @Sendable () -> Void
    private let viewModelState: ExperienceViewModelStateCoordinator?
    private var activeScreenId: String?
    private var navigationHistory: [String] = []
    private var pendingBackNavigation: (target: String, history: [String])?
    private var dismissedSurfaceScreenId: String?
    private var screenDismissalWasRejected = false
    private var topLevelScreenDismissalWasProcessed = false
    private var hostDismissalRequested = false
    private var presentationIsRevealed = false
    private var presentationEpoch: UInt64 = 0
    private var resolved = false
    private var resolutionWaiters: [CheckedContinuation<Bool, Never>]?

    init(request: DeviceLegPresentationRequest) {
        introEligibilityAuthorizationContext = .init(
            distinctId: request.ownerDistinctId,
            journeyId: request.journeyId
        )
        journeyId = request.journeyId
        onScreenChanged = request.onScreenChanged
        onScreenDismissed = request.onScreenDismissed
        onProductsUnavailable = request.onProductsUnavailable
        onPresentationRevealed = request.onPresentationRevealed
        onEmissionBatch = request.onEmissionBatch
        onPermissionEvent = request.onPermissionEvent
        onOutcome = request.onOutcome
        onPresentationFinished = request.onPresentationFinished
        if let definition = try? ExperienceDefinition(
            deviceLegDescriptor: request.release.descriptor
        ) {
            viewModelState = ExperienceViewModelStateCoordinator(
                screens: definition.renderShell
            )
        } else {
            viewModelState = nil
        }
    }

    func experienceViewController(
        _ controller: ExperienceViewController,
        didChangeScreen screenId: String
    ) async {
        let becameVisible = activeScreenId != screenId
        presentationEpoch &+= 1
        dismissedSurfaceScreenId = nil
        screenDismissalWasRejected = false
        topLevelScreenDismissalWasProcessed = false
        if let pendingBackNavigation,
           pendingBackNavigation.target == screenId {
            navigationHistory = pendingBackNavigation.history
            self.pendingBackNavigation = nil
        } else if let activeScreenId,
                  activeScreenId != screenId {
            navigationHistory.append(activeScreenId)
            pendingBackNavigation = nil
        }
        if presentationIsRevealed, becameVisible {
            // Once the outer surface is revealed, screen activation is the
            // visibility boundary for later variants. The navigation request
            // result alone is only control-flow acknowledgement.
            await onPresentationRevealed()
        }
        let committed = await onScreenChanged(screenId)
        guard !resolved, committed else {
            await controller.configureScreenEmissionRun(nil)
            if !committed, !resolved {
                let accepted = await resolve(.abandoned)
                if accepted {
                    controller.performDismiss(
                        reason: .error(ExperienceError.invalidManifest)
                    )
                }
            }
            return
        }
        activeScreenId = screenId
        await controller.configureScreenEmissionRun(
            screenControlScope(screenId: screenId)
        )
    }

    func experienceViewController(
        _ controller: ExperienceViewController,
        didDismissScreen screenId: String,
        revealingScreenId: String?,
        method: String
    ) async {
        if hostDismissalRequested, revealingScreenId == nil {
            // Host surface control is its own authored input. Teardown still
            // closes the native screen, but routing `$screen_dismissed` here
            // could complete the run before `host_dismissed` is delivered.
            dismissedSurfaceScreenId = screenId
            pendingBackNavigation = nil
            activeScreenId = nil
            await controller.configureScreenEmissionRun(nil)
            return
        }
        let result = await onScreenDismissed(
            screenId,
            revealingScreenId,
            method
        )
        if revealingScreenId == nil {
            dismissedSurfaceScreenId = screenId
            topLevelScreenDismissalWasProcessed = result != .rejected
        }
        if let revealingScreenId {
            if let revealIndex = navigationHistory.lastIndex(of: revealingScreenId) {
                navigationHistory = Array(navigationHistory[..<revealIndex])
            } else if let activeScreenId,
                      activeScreenId == screenId,
                      activeScreenId != revealingScreenId {
                // The transition coordinator dismisses the source before it
                // reports the destination as active. Preserve that source now
                // so the following screen-change callback cannot erase the
                // authored back path by observing the destination twice.
                navigationHistory.append(activeScreenId)
            }
        }
        pendingBackNavigation = nil
        // The transition coordinator reports the destination as active in a
        // separate callback. Keep this interval ownerless so that callback is
        // the sole visibility edge for exposure and emission admission.
        activeScreenId = nil
        if revealingScreenId != nil {
            presentationEpoch &+= 1
        }
        switch result {
        case .handled:
            await controller.configureScreenEmissionRun(
                revealingScreenId.map(screenControlScope(screenId:))
            )
        case .completed:
            resolved = true
            await controller.configureScreenEmissionRun(nil)
        case .rejected:
            screenDismissalWasRejected = true
            await controller.configureScreenEmissionRun(nil)
            let accepted = await resolve(.abandoned)
            if accepted {
                controller.performDismiss(
                    reason: .error(ExperienceError.invalidManifest)
                )
            }
        }
    }

    func experienceViewController(
        _ controller: ExperienceViewController,
        didEmitScreenEmissionBatch batch: ScreenEmissionBatch
    ) async -> Bool {
        guard !resolved,
              batch.journeyId == journeyId,
              batch.source.screenId == activeScreenId,
              batch.presentationEpoch == presentationEpoch else {
            return false
        }
        return await onEmissionBatch(batch)
    }

    func experienceViewController(
        _ controller: ExperienceViewController,
        didEmitViewModelChange change: ExperienceRendererViewModelChange
    ) {
        _ = controller
        _ = viewModelState?.setValue(
            path: change.path,
            value: change.value,
            screenId: change.screenId,
            instanceId: change.instanceId
        )
    }

    func experienceViewController(
        _ controller: ExperienceViewController,
        didRequestOpenLink request: ExperienceRendererOpenLinkRequest
    ) {
        guard !resolved,
              request.screenId == nil || request.screenId == activeScreenId else {
            return
        }
        controller.performOpenLink(
            urlString: request.urlString,
            target: request.target
        )
    }

    nonisolated func experienceViewController(
        _ controller: ExperienceViewController,
        didResolveNotificationPermissionEvent eventName: String,
        properties: sending [String: Any],
        journeyId: String
    ) {
        forwardPermissionEvent(
            eventName,
            properties: properties,
            journeyId: journeyId
        )
    }

    nonisolated func experienceViewController(
        _ controller: ExperienceViewController,
        didResolveRequestPermissionEvent eventName: String,
        properties: sending [String: Any],
        journeyId: String
    ) {
        forwardPermissionEvent(
            eventName,
            properties: properties,
            journeyId: journeyId
        )
    }

    nonisolated func experienceViewController(
        _ controller: ExperienceViewController,
        didIgnoreUnsupportedRequestPermissionType permissionType: String,
        journeyId: String
    ) {
        guard journeyId == self.journeyId else { return }
        onPermissionEvent(
            SystemEventNames.permissionDenied,
            UncheckedSendable([
                "journey_id": journeyId,
                "type": permissionType,
            ])
        )
    }

    nonisolated func experienceViewController(
        _ controller: ExperienceViewController,
        didResolveTrackingPermissionEvent eventName: String,
        properties: sending [String: Any],
        journeyId: String
    ) {
        forwardPermissionEvent(
            eventName,
            properties: properties,
            journeyId: journeyId
        )
    }

    func experienceViewController(
        _ controller: ExperienceViewController,
        didFailToResolveProductsFor screenId: String
    ) async {
        guard !resolved else { return }
        await controller.configureScreenEmissionRun(nil)
        switch await onProductsUnavailable(screenId) {
        case .handled:
            return
        case .completed:
            resolved = true
            // Product resolution reports from inside the navigation drain.
            // Queue ordinary dismissal so that callback can unwind before
            // runtime teardown joins the drain.
            controller.performDismiss(
                reason: .error(ExperienceError.productsUnavailable)
            )
        case .rejected:
            let accepted = await resolve(.abandoned)
            if accepted {
                controller.performDismiss(
                    reason: .error(ExperienceError.productsUnavailable)
                )
            }
        }
    }

    @discardableResult
    func experienceViewControllerDidRequestDismiss(
        _ controller: ExperienceViewController,
        reason: CloseReason
    ) async -> Bool {
        _ = controller
        if screenDismissalWasRejected {
            return await resolve(.abandoned)
        }
        if case .error = reason {
            return await resolve(.abandoned)
        }
        // `prepareForDismissal` has already delivered `$screen_dismissed`.
        // A handled user close only needs to acknowledge removal of the native
        // surface; feeding it through `onOutcome` would inject a second,
        // unrelated `host_dismissed` input into the Journey.
        guard topLevelScreenDismissalWasProcessed || resolved else {
            return await resolve(.abandoned)
        }
        return true
    }

    func experienceViewControllerDidReveal(
        _ controller: ExperienceViewController
    ) async {
        _ = controller
        guard !presentationIsRevealed else { return }
        presentationIsRevealed = true
        await onPresentationRevealed()
    }

    func experienceViewControllerDidRequestHostDismiss(
        _ controller: ExperienceViewController
    ) async -> Bool {
        _ = controller
        return await resolve(
            screenDismissalWasRejected ? .abandoned : .dismissed
        )
    }

    func experienceViewControllerWillRequestHostDismiss(
        _ controller: ExperienceViewController
    ) async {
        _ = controller
        hostDismissalRequested = true
    }

    func experienceViewControllerDidFinishPresentation(
        _ controller: ExperienceViewController
    ) {
        _ = controller
        onPresentationFinished()
    }

    private func resolve(_ outcome: DeviceLegSurfaceOutcome) async -> Bool {
        guard !resolved else { return true }
        if resolutionWaiters != nil {
            return await withCheckedContinuation { continuation in
                resolutionWaiters?.append(continuation)
            }
        }
        resolutionWaiters = []
        let accepted = await onOutcome(
            outcome,
            activeScreenId ?? dismissedSurfaceScreenId
        )
        let waiters = resolutionWaiters ?? []
        resolutionWaiters = nil
        if accepted {
            resolved = true
        }
        waiters.forEach { $0.resume(returning: accepted) }
        return accepted
    }

    private func screenControlScope(screenId: String) -> ScreenControlRunScope {
        ScreenControlRunScope(
            journeyId: journeyId,
            screenId: screenId,
            executionOwnershipEpoch: 0,
            lifecycleGeneration: 0,
            presentationEpoch: presentationEpoch,
            nextBatchSequence: 0,
            nextEmissionSequence: 0
        )
    }

    func resolvePresentationString(
        _ value: ExperienceReleaseJSONValue,
        source: ScreenEmissionSource? = nil
    ) -> String? {
        let screenId = source?.screenId ?? activeScreenId
        let instanceId = source?.instanceId
        let resolver = ValueRefResolver(
            payload: nil,
            context: nil,
            lookup: { [viewModelState] path in
                viewModelState?.getValue(
                    path: path,
                    screenId: screenId,
                    instanceId: instanceId
                )
            }
        )
        return ValueRefResolver.unwrapRuntimeValue(
            resolver.resolve(deviceLegFoundationValue(value) ?? NSNull())
        ) as? String
    }

    nonisolated private func forwardPermissionEvent(
        _ eventName: String,
        properties: sending [String: Any],
        journeyId: String
    ) {
        guard journeyId == self.journeyId else { return }
        onPermissionEvent(eventName, UncheckedSendable(properties))
    }

    func prepareBackNavigation(steps: Int) -> String? {
        guard !resolved, !navigationHistory.isEmpty else { return nil }
        let targetIndex = max(0, navigationHistory.count - max(1, steps))
        let target = navigationHistory[targetIndex]
        pendingBackNavigation = (
            target: target,
            history: Array(navigationHistory[..<targetIndex])
        )
        return target
    }

    func cancelBackNavigation() {
        pendingBackNavigation = nil
    }
}

extension DeviceLegRuntimeDelegate: ExperienceRuntimeDelegate {}

extension DeviceLegRuntimeDelegate:
    IntroEligibilityAuthorizationContextProviding {}

extension DeviceLegRuntimeDelegate: NotificationPermissionEventReceiver {}

extension DeviceLegRuntimeDelegate: RequestPermissionEventReceiver {}

extension DeviceLegRuntimeDelegate: TrackingPermissionEventReceiver {}

func deviceLegFoundationValue(
    _ value: ExperienceReleaseJSONValue?
) -> Any? {
    guard let value else { return nil }
    switch value {
    case .null:
        return nil
    case .bool(let value):
        return value
    case .number(let value):
        return value
    case .string(let value):
        return value
    case .array(let values):
        return values.map { deviceLegFoundationValue($0) ?? NSNull() }
    case .object(let values):
        return values.dictionary.mapValues {
            deviceLegFoundationValue($0) ?? NSNull()
        }
    }
}

func deviceLegPresentationLiteralString(
    _ value: ExperienceReleaseJSONValue?
) -> String? {
    switch value {
    case .string(let value):
        return value
    case .object(let fields):
        guard fields.count == 1,
              case .string(let value)? = fields["literal"] else {
            return nil
        }
        return value
    default:
        return nil
    }
}
