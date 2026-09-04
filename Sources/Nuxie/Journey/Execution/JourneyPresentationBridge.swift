import Foundation

protocol JourneyPresentationReservation: AnyObject, Sendable {
    @MainActor func release()
}

/// Stable identity for the journey presentation slot. A journey identifier is
/// only meaningful within the customer authority that owns its durable run.
struct JourneyPresentationOwner: Equatable, Hashable, Sendable {
    let journeyId: String
    let distinctId: String
}

enum JourneySurfaceOutcome: Equatable, Sendable {
    case dismissed
    case abandoned
}

enum JourneyProductFailureResult: Equatable, Sendable {
    case handled
    case completed
    case rejected
}

enum JourneyScreenDismissalResult: Equatable, Sendable {
    case handled
    case completed
    case rejected
}

extension ScreenEmissionValue {
    var releaseJSONValue: JourneyReleaseJSONValue {
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

struct JourneyPresentationRequest: Sendable {
    let release: AuthenticatedJourneyRelease
    let delivery: JourneyReleaseDelivery
    let pinnedArtifacts: JourneyPinnedReleaseArtifacts?
    let screenId: String
    let owner: JourneyPresentationOwner
    let reservation: (any JourneyPresentationReservation)?
    let presentationTraceContext: ExperiencePresentationTraceContext?
    let onScreenChanged:
        @MainActor @Sendable (String) async -> Bool
    let onScreenDismissed:
        @MainActor @Sendable (String, String?, String) async
            -> JourneyScreenDismissalResult
    let onProductsUnavailable:
        @MainActor @Sendable (String) async -> JourneyProductFailureResult
    let onEmissionBatch:
        @MainActor @Sendable (ScreenEmissionBatch) async -> Bool
    let onPermissionEvent:
        @Sendable (
            String,
            UncheckedSendable<[String: Any]>
        ) -> Void
    let onPresentationRevealed:
        @MainActor @Sendable (String) async -> Void
    let onOutcome:
        @MainActor @Sendable (JourneySurfaceOutcome, String?) async -> Bool
    let onPresentationFinished:
        @MainActor @Sendable () -> Void

    init(
        release: AuthenticatedJourneyRelease,
        delivery: JourneyReleaseDelivery,
        pinnedArtifacts: JourneyPinnedReleaseArtifacts? = nil,
        screenId: String,
        owner: JourneyPresentationOwner,
        reservation: (any JourneyPresentationReservation)?,
        presentationTraceContext: ExperiencePresentationTraceContext? = nil,
        onScreenChanged:
            @escaping @MainActor @Sendable (String) async -> Bool = { _ in true },
        onScreenDismissed:
            @escaping @MainActor @Sendable (String, String?, String) async
                -> JourneyScreenDismissalResult = { _, _, _ in
                .handled
            },
        onProductsUnavailable:
            @escaping @MainActor @Sendable (String) async -> JourneyProductFailureResult = {
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
            @escaping @MainActor @Sendable (String) async -> Void = { _ in },
        onOutcome:
            @escaping @MainActor @Sendable (JourneySurfaceOutcome, String?) async -> Bool,
        onPresentationFinished:
            @escaping @MainActor @Sendable () -> Void = {}
    ) {
        self.release = release
        self.delivery = delivery
        self.pinnedArtifacts = pinnedArtifacts
        self.screenId = screenId
        self.owner = owner
        self.reservation = reservation
        self.presentationTraceContext = presentationTraceContext
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

enum JourneyPresentationResult: Equatable, Sendable {
    case shown
    case declined
    case failed
}

enum JourneyPresentationNavigationResult: Equatable, Sendable {
    case navigated
    case alreadyActive
    case productsUnavailable
    case noPresentation
    case declined
    case failed
}

struct JourneyPresentationPermissionEvent: Equatable, Sendable {
    let name: String
    let properties: [String: String]
}

enum JourneyPresentationActionResult: Equatable, Sendable {
    case advanced(outlet: String)
    case permissionResolved(
        outlet: String,
        event: JourneyPresentationPermissionEvent
    )
    case awaitingOutcome
    case handled
    case productsUnavailable
    case noPresentation
    case declined
    case failed
}

protocol JourneyPresenting: AnyObject, Sendable {
    /// Re-opens presentation admission after foreground profile authority and
    /// its dependent projections are current.
    @MainActor
    func journeyProfileRefreshDidComplete()

    @MainActor
    func setJourneyPresentationAvailabilityHandler(
        _ handler: (@MainActor @Sendable () -> Void)?
    )

    @MainActor
    func reserveJourneyPresentation(
        ownerDistinctId: String
    ) -> (any JourneyPresentationReservation)?

    @MainActor
    func ownsJourneyPresentation(
        owner: JourneyPresentationOwner
    ) -> Bool

    @MainActor
    func presentJourney(
        _ request: JourneyPresentationRequest
    ) async -> JourneyPresentationResult

    @MainActor
    func navigateJourneyPresentation(
        owner: JourneyPresentationOwner,
        screenId: String,
        transition: JourneyReleaseJSONValue?
    ) async -> JourneyPresentationNavigationResult

    @MainActor
    func resolveJourneyPresentationAction(
        owner: JourneyPresentationOwner,
        action: [String: JourneyReleaseJSONValue],
        source: ScreenEmissionSource?
    ) -> [String: JourneyReleaseJSONValue]?

    @MainActor
    func dispatchJourneyPresentationAction(
        owner: JourneyPresentationOwner,
        action: [String: JourneyReleaseJSONValue],
        effectId: String
    ) async -> JourneyPresentationActionResult

    @MainActor
    func finishJourneyPresentation(
        owner: JourneyPresentationOwner
    ) async

    @MainActor
    func shutdownJourneyPresentation(ownerDistinctId: String) async
}

@MainActor
final class JourneyRuntimeDelegate {
    nonisolated let introEligibilityAuthorizationContext:
        IntroEligibilityAuthorizationContext
    nonisolated private let journeyId: String
    private(set) var presentationTraceContext:
        ExperiencePresentationTraceContext?
    private let presentationTraceToken: ExperiencePresentationTraceToken?
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
            -> JourneyScreenDismissalResult
    private let onProductsUnavailable:
        @MainActor @Sendable (String) async -> JourneyProductFailureResult
    private let onPresentationRevealed:
        @MainActor @Sendable (String) async -> Void
    private let onOutcome:
        @MainActor @Sendable (JourneySurfaceOutcome, String?) async -> Bool
    private let onPresentationFinished:
        @MainActor @Sendable () -> Void
    private let viewModelState: ExperienceViewModelStateCoordinator?
    private let initialScreenId: String
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

    init(request: JourneyPresentationRequest) {
        introEligibilityAuthorizationContext = .init(
            distinctId: request.owner.distinctId,
            journeyId: request.owner.journeyId,
            legId: request.release.descriptor.leg.id,
            descriptorSha256: request.release.descriptorSHA256
        )
        journeyId = request.owner.journeyId
        presentationTraceContext = request.presentationTraceContext
        presentationTraceToken = request.presentationTraceContext.map { _ in
            ExperiencePresentationTraceToken(id: UUID())
        }
        initialScreenId = request.screenId
        onScreenChanged = request.onScreenChanged
        onScreenDismissed = request.onScreenDismissed
        onProductsUnavailable = request.onProductsUnavailable
        onPresentationRevealed = request.onPresentationRevealed
        onEmissionBatch = request.onEmissionBatch
        onPermissionEvent = request.onPermissionEvent
        onOutcome = request.onOutcome
        onPresentationFinished = request.onPresentationFinished
        if let definition = try? ExperienceDefinition(
            journeyDescriptor: request.release.descriptor
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
            await onPresentationRevealed(screenId)
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
        await onPresentationRevealed(activeScreenId ?? initialScreenId)
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

    private func resolve(_ outcome: JourneySurfaceOutcome) async -> Bool {
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
        _ value: JourneyReleaseJSONValue,
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
            resolver.resolve(journeyFoundationValue(value) ?? NSNull())
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

extension JourneyRuntimeDelegate: ExperienceRuntimeDelegate {}

extension JourneyRuntimeDelegate: ExperiencePresentationTraceContextProviding {}

extension JourneyRuntimeDelegate: ExperiencePresentationScopedTraceDelegate {
    var activePresentationTraceToken: ExperiencePresentationTraceToken? {
        presentationTraceToken
    }

    func experienceViewControllerDidBecomeReady(
        _ controller: ExperienceViewController,
        traceToken: ExperiencePresentationTraceToken?
    ) {
        guard acceptsPresentationTraceToken(traceToken) else { return }
        presentationTraceContext?.record(.runtimeReady)
    }

    func experienceViewControllerDidPresentShell(
        _ controller: ExperienceViewController,
        traceToken: ExperiencePresentationTraceToken?
    ) {
        guard acceptsPresentationTraceToken(traceToken) else { return }
        presentationTraceContext?.record(.shellPresented)
    }

    func experienceViewControllerDidReveal(
        _ controller: ExperienceViewController,
        traceToken: ExperiencePresentationTraceToken?
    ) async {
        if acceptsPresentationTraceToken(traceToken) {
            presentationTraceContext?.record(.revealed)
        }
        await experienceViewControllerDidReveal(controller)
    }

    func experienceViewController(
        _ controller: ExperienceViewController,
        didPresentDrawable drawable: ExperienceRuntimePresentedDrawable,
        screenId: String,
        frameNumber: UInt64,
        traceToken: ExperiencePresentationTraceToken?
    ) {
        guard acceptsPresentationTraceToken(traceToken),
              let context = presentationTraceContext else { return }
        let observedAt = ExperiencePresentationTimestamp.now()
        context.recorder.record(
            attempt: context.attempt,
            stage: .firstPresentedDrawable(
                screenId: screenId,
                frameNumber: frameNumber,
                pixels: UInt64(drawable.pixelWidth) * UInt64(drawable.pixelHeight),
                drawCalls: drawable.drawCalls,
                provenance: drawable.provenance
            ),
            timestamp: .anchored(
                monotonicTime: drawable.presentedTime,
                observedAt: observedAt
            )
        )
    }

    func experienceViewController(
        _ controller: ExperienceViewController,
        didAcceptPointerInput input: ExperienceRuntimeAcceptedPointerInput,
        screenId: String,
        traceToken: ExperiencePresentationTraceToken?
    ) {
        guard acceptsPresentationTraceToken(traceToken) else { return }
        presentationTraceContext?.record(.firstAcceptedInput(
            screenId: screenId,
            eventCount: input.eventCount
        ))
    }

    func experienceViewControllerDidFinishPresentation(
        _ controller: ExperienceViewController,
        traceToken: ExperiencePresentationTraceToken?
    ) {
        if acceptsPresentationTraceToken(traceToken) {
            presentationTraceContext?.record(.presentationCleanupCompleted)
        }
        experienceViewControllerDidFinishPresentation(controller)
    }

    private func acceptsPresentationTraceToken(
        _ traceToken: ExperiencePresentationTraceToken?
    ) -> Bool {
        guard let presentationTraceToken else { return false }
        return traceToken == presentationTraceToken
    }
}

extension JourneyRuntimeDelegate:
    IntroEligibilityAuthorizationContextProviding {}

extension JourneyRuntimeDelegate: NotificationPermissionEventReceiver {}

extension JourneyRuntimeDelegate: RequestPermissionEventReceiver {}

extension JourneyRuntimeDelegate: TrackingPermissionEventReceiver {}

func journeyFoundationValue(
    _ value: JourneyReleaseJSONValue?
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
        return values.map { journeyFoundationValue($0) ?? NSNull() }
    case .object(let values):
        return values.dictionary.mapValues {
            journeyFoundationValue($0) ?? NSNull()
        }
    }
}

func journeyPresentationLiteralString(
    _ value: JourneyReleaseJSONValue?
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
