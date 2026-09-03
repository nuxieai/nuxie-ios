import Foundation

/// Host control for the single Journey-owned presentation surface.
protocol ExperiencePresentationServiceProtocol: AnyObject, Sendable {
    /// Dismiss the currently presented experience
    @MainActor func dismissCurrentExperience() async
    @MainActor func dismissCurrentExperience(reason: CloseReason) async
    @MainActor func dismissCurrentExperienceFromHost() async
    @MainActor func shutdownCurrentExperience() async
    
    /// Check if a experience is currently presented
    @MainActor var isExperiencePresented: Bool { get }
    @MainActor var presentedJourneyId: String? { get }
    
    /// Called when app becomes active - starts grace period
    @MainActor func onAppBecameActive()

    /// Called when app enters background - clears grace period
    @MainActor func onAppDidEnterBackground()
}

@MainActor
private final class JourneyReservation {
    let id: UUID
    let ownerDistinctId: String
    private let service: ExperiencePresentationService

    init(
        id: UUID,
        ownerDistinctId: String,
        service: ExperiencePresentationService
    ) {
        self.id = id
        self.ownerDistinctId = ownerDistinctId
        self.service = service
    }

    func release() {
        service.releaseJourneyReservation(id: id)
    }
}

extension JourneyReservation: JourneyPresentationReservation {}

/// Service for presenting experiences in dedicated windows over the entire app
@MainActor
final class ExperiencePresentationService {

    private struct JourneyPresentationContext {
        let owner: JourneyPresentationOwner
        let experienceId: String
    }

    private enum JourneyPresentationAdmission<Prepared> {
        case admitted(
            presentationID: UUID,
            controller: ExperienceViewController,
            prepared: Prepared
        )
        case noPresentation
        case declined
        case rejected
    }

    private struct PendingJourneyReservation {
        let id: UUID
        let ownerDistinctId: String
        var wasContended: Bool
    }

    private struct PresentationOperationState {
        var presentationID: UUID?
        var owner: PresentationOwner?
        var journeyOwnerDistinctId: String?
    }

    /// Production presentations are owned by the Journey identity. The owner
    /// remains occupied until the attempt finishes; screen movement for that
    /// owner uses the dedicated navigation seam instead of another present.
    private enum PresentationOwner: Equatable {
        case journey(JourneyPresentationOwner)
    }

    /// State retained after host surface control has synchronously detached a
    /// presentation. Durable Journey input and renderer teardown may outlive
    /// the visible window and continue to occupy its sole presentation slot.
    private struct DetachedHostPresentation {
        let id: UUID
        let window: PresentationWindowProtocol?
        let experienceVersionId: String
        let journeyContext: JourneyPresentationContext?
        let viewController: ExperienceViewController
        let runtimeDelegate: ExperienceRuntimeDelegate?
        let runtimeDelegateTraceToken: ExperiencePresentationTraceToken?
    }
    
    // MARK: - Dependencies
    
    private let experienceService: ExperienceServiceProtocol
    private let eventLog: EventCapturing
    private let windowProvider: WindowProviderProtocol
    
    // MARK: - State
    
    internal var currentWindow: PresentationWindowProtocol?
    internal var currentExperienceId: String?
    internal var currentExperienceViewController: ExperienceViewController?
    private var currentRuntimeDelegate: ExperienceRuntimeDelegate?
    private var currentJourneyContext: JourneyPresentationContext?
    private var currentRuntimeDelegateTraceToken: ExperiencePresentationTraceToken?
    private var currentPresentationID: UUID?
    private var presentationOwner: PresentationOwner?
    private var presentationAttemptGeneration: UInt64 = 0
    private var presentationShutdownGeneration: UInt64 = 0
    private var presentationCleanupTask: Task<Void, Never>?
    private var detachedHostPresentations: [UUID: DetachedHostPresentation] = [:]
    private var detachedHostDismissalTasks: [UUID: Task<Void, Never>] = [:]
    private var presentationTeardownIDs: Set<UUID> = []
    private var activePresentationOperations: [UUID: PresentationOperationState] = [:]
    private var pendingJourneyReservation: PendingJourneyReservation?
    private var journeyPresentationAvailabilityHandler:
        (@MainActor @Sendable () -> Void)?
    private var journeyPresentationCapacityWasAvailable = true
    private var presentationOperationWaiters:
        [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private var journeyPresentationOperationWaiters:
        [String: [CheckedContinuation<Void, Never>]] = [:]
    private var allPresentationOperationWaiters: [CheckedContinuation<Void, Never>] = []
    private var journeyForegroundAuthorityWaiters: [
        UUID: [CheckedContinuation<Bool, Never>]
    ] = [:]
    private var appIsForeground = true
    private var journeyForegroundAuthorityReady = true
    
    // MARK: - Grace Period
    
    private let foregroundGracePeriod: TimeInterval = 0.75  // UX grace window
    private var gracePeriodEndTime: Date?
    
    // MARK: - Initialization
    
    /// Nonisolated so the composition root can construct the instance from
    /// any thread; all state access stays MainActor-isolated.
    nonisolated init(
        windowProvider: WindowProviderProtocol? = nil,
        experiences: ExperienceServiceProtocol,
        eventLog: EventCapturing
    ) {
        self.windowProvider = windowProvider ?? DefaultWindowProvider()
        self.experienceService = experiences
        self.eventLog = eventLog
    }
    
    // MARK: - Public API
    
    var isExperiencePresented: Bool {
        currentWindow != nil
    }

    var presentedJourneyId: String? {
        currentJourneyContext?.owner.journeyId
    }

    private func presentJourneyExperience(
        _ experienceVersionId: String,
        runtimeDelegate: ExperienceRuntimeDelegate?,
        colorSchemeMode: ExperienceColorSchemeMode,
        initialScreenID: String,
        owner: PresentationOwner,
        journeyContext: JourneyPresentationContext,
        journeyReservation: JourneyReservation? = nil,
        viewControllerProvider:
            @MainActor () async throws -> ExperienceViewController
    ) async throws -> ExperienceViewController {
        let presentationOperationID = beginPresentationOperation()
        defer { finishPresentationOperation(presentationOperationID) }
        try claimPresentationOwnership(
            owner,
            operationID: presentationOperationID,
            journeyReservation: journeyReservation,
            requiresJourneyReservation: true,
            journeyOwnerDistinctId: journeyContext.owner.distinctId
        )
        let shutdownGeneration = presentationShutdownGeneration
        try Task.checkCancellation()
        guard presentationShutdownGeneration == shutdownGeneration else {
            throw CancellationError()
        }
        presentationAttemptGeneration &+= 1
        let attemptGeneration = presentationAttemptGeneration
        LogInfo("ExperiencePresentationService: Presenting experience \(experienceVersionId)")
        
        // Check if we're within the grace period
        if let gracePeriodEnd = gracePeriodEndTime {
            let now = Date()
            if now < gracePeriodEnd {
                let delaySeconds = gracePeriodEnd.timeIntervalSince(now)
                LogDebug("ExperiencePresentationService: Delaying experience presentation by \(delaySeconds) seconds (grace period)")
                try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            }
        }
        await presentationCleanupTask?.value
        try requireCurrentPresentationAttempt(attemptGeneration)
        
        // 1. Check if we can present
        guard windowProvider.canPresentWindow() else {
            LogError("ExperiencePresentationService: No active window available")
            throw ExperiencePresentationError.noActiveScene
        }
        
        // 2. Build the controller from the exact release selected by Journey.
        let traceContext = (
            runtimeDelegate as? any ExperiencePresentationTraceContextProviding
        )?.presentationTraceContext
        let experienceViewController = try await viewControllerProvider()
        try requireCurrentPresentationAttempt(attemptGeneration)
        guard experienceViewController.experience
                .behaviorPresentationScreens[initialScreenID] != nil else {
            throw ExperiencePresentationError.presentationSuperseded
        }
        
        // 3. Create presentation window
        guard let window = windowProvider.createPresentationWindow() else {
            LogError("ExperiencePresentationService: Failed to create presentation window")
            throw ExperiencePresentationError.noActiveScene
        }
        
        // 4. Set up a presentation-scoped dismissal handler. Cached view
        // controllers can be reused, so an old callback must never tear down a
        // newer presentation of the same controller.
        let presentationID = UUID()
        experienceViewController.onClose = { [weak self] reason in
            Task { @MainActor in
                await self?.handleExperienceDismissal(
                    reason: reason,
                    presentationID: presentationID
                )
            }
        }

        // 5. Store state before presenting to avoid race conditions
        self.currentWindow = window
        self.currentExperienceId = experienceVersionId
        self.currentExperienceViewController = experienceViewController
        self.currentRuntimeDelegate = runtimeDelegate
        self.currentJourneyContext = journeyContext
        self.currentRuntimeDelegateTraceToken = (
            runtimeDelegate as? any ExperiencePresentationScopedTraceDelegate
        )?.activePresentationTraceToken
        self.currentPresentationID = presentationID
        associatePresentationOperation(
            presentationOperationID,
            with: presentationID
        )

        // Journey persistence is not an authentication boundary. Always
        // rebuild presentation geometry and behavior from the currently
        // authenticated release carried by the loaded Experience.
        let shell = experienceViewController.experience.shellContract(
            screenId: initialScreenID
        )
        try await requireOwnedPresentation(
            presentationID,
            attemptGeneration: attemptGeneration,
            fallbackWindow: window
        )
        experienceViewController.configurePresentationShell(
            shell,
            suppressLoadingTreatment: false,
            warmReservation: nil
        )

        // Every presentation owns freshly opened interactive screens, even
        // when ExperienceService returns a cached view controller.
        await experienceViewController.prepareForPresentation(
            traceToken: currentRuntimeDelegateTraceToken,
            initialScreenID: initialScreenID
        )
        try await requireOwnedPresentation(
            presentationID,
            attemptGeneration: attemptGeneration,
            fallbackWindow: window
        )
        // 6. Present experience
        let shellPresentationSpan = traceContext?.begin(
            .displayPresentation,
            attributes: ["phase": "shell"]
        )
        await window.present(experienceViewController, shell: shell)
        do {
            try await requireOwnedPresentation(
                presentationID,
                attemptGeneration: attemptGeneration,
                fallbackWindow: window
            )
        } catch {
            if let shellPresentationSpan {
                traceContext?.fail(
                    shellPresentationSpan,
                    error: error,
                    attributes: ["phase": "shell"]
                )
            }
            throw error
        }
        experienceViewController.markPresentationShellPresented(
            traceToken: currentRuntimeDelegateTraceToken
        )
        if let shellPresentationSpan {
            traceContext?.complete(
                shellPresentationSpan,
                attributes: ["phase": "shell"]
            )
        }

        trackExperienceShown(
            properties: journeyExperienceProperties(
                experienceVersionId: experienceVersionId,
                context: journeyContext
            ),
            distinctId: journeyContext.owner.distinctId
        )

        try await requireOwnedPresentation(
            presentationID,
            attemptGeneration: attemptGeneration,
            fallbackWindow: window
        )

        LogDebug("ExperiencePresentationService: Successfully presented experience \(experienceVersionId)")
        return experienceViewController
    }

    private func trackExperienceShown(
        properties: [String: Any],
        distinctId: String
    ) {
        eventLog.track(
            JourneyEvents.experienceShown,
            properties: properties,
            userProperties: nil,
            userPropertiesSetOnce: nil,
            distinctIdOverride: distinctId
        )
    }

    func reserveJourneyPresentation(
        ownerDistinctId: String
    ) -> (any JourneyPresentationReservation)? {
        guard !ownerDistinctId.isEmpty else { return nil }
        if pendingJourneyReservation != nil {
            pendingJourneyReservation?.wasContended = true
            return nil
        }
        guard appIsForeground,
              journeyForegroundAuthorityReady,
              windowProvider.canPresentWindow(),
              presentationOwner == nil,
              currentPresentationID == nil,
              activePresentationOperations.isEmpty else {
            return nil
        }
        let reservation = PendingJourneyReservation(
            id: UUID(),
            ownerDistinctId: ownerDistinctId,
            wasContended: false
        )
        pendingJourneyReservation = reservation
        refreshJourneyPresentationCapacity()
        return JourneyReservation(
            id: reservation.id,
            ownerDistinctId: ownerDistinctId,
            service: self
        )
    }

    func setJourneyPresentationAvailabilityHandler(
        _ handler: (@MainActor @Sendable () -> Void)?
    ) {
        journeyPresentationAvailabilityHandler = handler
        journeyPresentationCapacityWasAvailable =
            journeyPresentationCapacityIsAvailable
    }

    func ownsJourneyPresentation(
        owner: JourneyPresentationOwner
    ) -> Bool {
        ownsCurrentJourneyPresentation(owner)
    }

    func presentJourney(
        _ request: JourneyPresentationRequest
    ) async -> JourneyPresentationResult {
        guard appIsForeground,
              journeyForegroundAuthorityReady else {
            request.reservation?.release()
            return .declined
        }
        guard request.release.descriptor.leg.screens.contains(where: {
            $0.id == request.screenId
        }) else {
            request.reservation?.release()
            return .failed
        }
        let reservation = request.reservation as? JourneyReservation
        guard request.reservation == nil || reservation != nil,
              reservation?.ownerDistinctId == request.owner.distinctId
                || reservation == nil else {
            request.reservation?.release()
            return .declined
        }
        defer { reservation?.release() }
        let runtimeDelegate = JourneyRuntimeDelegate(request: request)
        do {
            _ = try await presentJourneyExperience(
                request.release.descriptor.identity.experienceVersionId,
                runtimeDelegate: runtimeDelegate,
                colorSchemeMode: .system,
                initialScreenID: request.screenId,
                owner: .journey(request.owner),
                journeyContext: .init(
                    owner: request.owner,
                    experienceId: request.release.descriptor.identity.experienceId
                ),
                journeyReservation: reservation,
                viewControllerProvider: { [experienceService] in
                    try await experienceService.viewController(
                        forJourney: request.release,
                        delivery: request.delivery,
                        pinnedArtifacts: request.pinnedArtifacts,
                        runtimeDelegate: runtimeDelegate,
                        colorSchemeMode: .system
                    )
                }
            )
            return .shown
        } catch ExperiencePresentationError.presentationDeclined {
            return .declined
        } catch ExperiencePresentationError.presentationSuperseded {
            return .declined
        } catch is CancellationError {
            return appIsForeground && journeyForegroundAuthorityReady
                ? .failed
                : .declined
        } catch {
            return .failed
        }
    }

    func navigateJourneyPresentation(
        owner: JourneyPresentationOwner,
        screenId: String,
        transition: JourneyReleaseJSONValue?
    ) async -> JourneyPresentationNavigationResult {
        let admission = await admitJourneyPresentation(
            owner: owner,
            prepare: { () }
        )
        let presentationID: UUID
        let controller: ExperienceViewController
        switch admission {
        case .admitted(let admittedID, let admittedController, _):
            presentationID = admittedID
            controller = admittedController
        case .noPresentation:
            return .noPresentation
        case .declined:
            return .declined
        case .rejected:
            return .failed
        }
        let navigationResult = await controller.navigateAndWaitResult(
            to: screenId,
            transition: journeyFoundationValue(transition)
        )
        guard ownsCurrentJourneyPresentation(
            owner,
            presentationID: presentationID
        ) else {
            return .failed
        }
        switch navigationResult {
        case .navigated:
            return .navigated
        case .alreadyActive:
            return .alreadyActive
        case .productsUnavailable:
            return .productsUnavailable
        case .failed:
            return .failed
        }
    }

    func resolveJourneyPresentationAction(
        owner: JourneyPresentationOwner,
        action: [String: JourneyReleaseJSONValue],
        source: ScreenEmissionSource?
    ) -> [String: JourneyReleaseJSONValue]? {
        guard ownsCurrentJourneyPresentation(owner),
              let type = JourneyActionType(action: action) else {
            return nil
        }
        guard type == .purchase else { return action }
        guard let placementValue = action["placementId"],
              let delegate = currentRuntimeDelegate as? JourneyRuntimeDelegate,
              let placementId = delegate.resolvePresentationString(
                placementValue,
                source: source
              ), !placementId.isEmpty else {
            return nil
        }
        var resolved = action
        resolved["placementId"] = .string(placementId)
        return resolved
    }

    func dispatchJourneyPresentationAction(
        owner: JourneyPresentationOwner,
        action: [String: JourneyReleaseJSONValue],
        effectId: String
    ) async -> JourneyPresentationActionResult {
        let admission: JourneyPresentationAdmission<JourneyActionType> =
            await admitJourneyPresentation(
                owner: owner,
                prepare: {
                    guard let type = JourneyActionType(action: action),
                          type.isPresentationOwned else {
                        return nil
                    }
                    return type
                }
            )
        let presentationID: UUID
        let controller: ExperienceViewController
        let type: JourneyActionType
        switch admission {
        case .admitted(
            let admittedID,
            let admittedController,
            let admittedType
        ):
            presentationID = admittedID
            controller = admittedController
            type = admittedType
        case .noPresentation:
            return .noPresentation
        case .declined:
            return .declined
        case .rejected:
            return .failed
        }
        let result: JourneyPresentationActionResult
        switch type {
        case .back:
            let steps: Int
            if case .number(let value)? = action["steps"],
               value.isFinite,
               value.rounded(.towardZero) == value,
               value >= 1,
               value <= 256 {
                steps = Int(value)
            } else if action["steps"] == nil {
                steps = 1
            } else {
                return .failed
            }
            guard let delegate = currentRuntimeDelegate as? JourneyRuntimeDelegate,
                  let target = delegate.prepareBackNavigation(steps: steps) else {
                return .failed
            }
            switch await controller.navigateAndWaitResult(
                to: target,
                transition: journeyFoundationValue(action["transition"])
            ) {
            case .navigated, .alreadyActive:
                result = .handled
            case .productsUnavailable:
                delegate.cancelBackNavigation()
                result = .productsUnavailable
            case .failed:
                delegate.cancelBackNavigation()
                result = .failed
            }

        case .purchase:
            guard let placementValue = action["placementId"],
                  let delegate = currentRuntimeDelegate as? JourneyRuntimeDelegate,
                  let placementId = delegate.resolvePresentationString(
                    placementValue,
                    source: nil
                  ), !placementId.isEmpty else {
                return .failed
            }
            controller.performPurchase(
                placementId: placementId,
                outcomeCorrelation: CommerceOutcomeCorrelation(
                    eventId: effectId,
                    distinctId: owner.distinctId
                )
            )
            result = .awaitingOutcome

        case .restore:
            controller.performRestore(outcomeCorrelation: CommerceOutcomeCorrelation(
                eventId: effectId,
                distinctId: owner.distinctId
            ))
            result = .awaitingOutcome

        case .requestNotifications:
            result = .permissionResolved(
                outlet: "next",
                event: await controller.resolveJourneyNotificationPermissionEvent(
                    journeyId: owner.journeyId
                )
            )

        case .requestPermission:
            guard case .string(let permissionType)? = action["permissionType"],
                  !permissionType.isEmpty else {
                return .failed
            }
            result = .permissionResolved(
                outlet: "next",
                event: await controller.resolveJourneyRequestPermissionEvent(
                    permissionType: permissionType,
                    journeyId: owner.journeyId
                )
            )

        case .requestTracking:
            result = .permissionResolved(
                outlet: "next",
                event: await controller.resolveJourneyTrackingPermissionEvent(
                    journeyId: owner.journeyId
                )
            )

        case .openLink:
            guard case .string(let url)? = action["url"],
                  !url.isEmpty,
                  case .string(let target)? = action["target"] else {
                return .failed
            }
            controller.performOpenLink(urlString: url, target: target)
            result = .advanced(outlet: "next")

        case .dismiss:
            controller.performDismiss(reason: .userDismissed)
            result = .handled

        default:
            return .failed
        }

        guard ownsCurrentJourneyPresentation(
            owner,
            presentationID: presentationID
        ) else {
            return .failed
        }
        return result
    }

    func finishJourneyPresentation(
        owner: JourneyPresentationOwner
    ) async {
        guard let presentationID = currentPresentationID,
              ownsCurrentJourneyPresentation(
                owner,
                presentationID: presentationID
              ) else {
            return
        }
        presentationAttemptGeneration &+= 1
        await finishPresentation(
            id: presentationID,
            reason: nil,
            dismissWindow: true
        )
    }

    func shutdownJourneyPresentation(ownerDistinctId: String) async {
        let ownsPendingReservation =
            pendingJourneyReservation?.ownerDistinctId == ownerDistinctId
        let ownsInFlightOperation = activePresentationOperations.values.contains(where: {
            $0.journeyOwnerDistinctId == ownerDistinctId
        })
        let ownedCurrentPresentationID =
            currentJourneyContext?.owner.distinctId == ownerDistinctId
                ? currentPresentationID
                : nil
        let detachedTasks = detachedHostPresentations.compactMap {
            id, presentation -> Task<Void, Never>? in
            guard presentation.journeyContext?.owner.distinctId
                    == ownerDistinctId else {
                return nil
            }
            return detachedHostDismissalTasks[id]
        }
        if ownsPendingReservation {
            pendingJourneyReservation = nil
        }
        if ownsInFlightOperation || ownedCurrentPresentationID != nil {
            presentationAttemptGeneration &+= 1
        }
        detachedTasks.forEach { $0.cancel() }
        if let ownedCurrentPresentationID {
            await finishPresentation(
                id: ownedCurrentPresentationID,
                reason: nil,
                dismissWindow: true
            )
        }
        await waitForJourneyPresentationOperationsToFinish(
            ownerDistinctId: ownerDistinctId
        )
        for task in detachedTasks {
            await task.value
        }
        releasePresentationOwnershipIfIdle()
        refreshJourneyPresentationCapacity()
    }

    fileprivate func releaseJourneyReservation(id: UUID) {
        guard let reservation = pendingJourneyReservation,
              reservation.id == id else { return }
        pendingJourneyReservation = nil
        if reservation.wasContended {
            refreshJourneyPresentationCapacity()
        } else {
            // Releasing an uncontended reservation is part of unwinding the
            // current admission attempt. Publishing a callback here would
            // immediately retry the same state arm before its eligibility can
            // change.
            journeyPresentationCapacityWasAvailable =
                journeyPresentationCapacityIsAvailable
        }
    }
    
    func dismissCurrentExperience() async {
        guard let presentationID = currentPresentationID else {
            LogDebug("ExperiencePresentationService: No experience to dismiss")
            return
        }
        let presentationOperationID = beginPresentationOperation()
        associatePresentationOperation(
            presentationOperationID,
            with: presentationID
        )
        defer { finishPresentationOperation(presentationOperationID) }
        guard currentPresentationID == presentationID else { return }
        presentationAttemptGeneration &+= 1
        
        LogInfo("ExperiencePresentationService: Dismissing current experience")
        
        await finishPresentation(
            id: presentationID,
            reason: nil,
            dismissWindow: true
        )
    }

    func dismissCurrentExperience(reason: CloseReason) async {
        guard let presentationID = currentPresentationID else {
            LogDebug("ExperiencePresentationService: No experience to dismiss")
            return
        }
        let presentationOperationID = beginPresentationOperation()
        associatePresentationOperation(
            presentationOperationID,
            with: presentationID
        )
        defer { finishPresentationOperation(presentationOperationID) }
        guard currentPresentationID == presentationID else { return }
        presentationAttemptGeneration &+= 1

        LogInfo("ExperiencePresentationService: Dismissing current experience with reason \(reason)")

        await finishPresentation(
            id: presentationID,
            reason: reason,
            dismissWindow: true
        )
    }

    func shutdownCurrentExperience() async {
        pendingJourneyReservation = nil
        presentationShutdownGeneration &+= 1
        presentationAttemptGeneration &+= 1
        let detachedTasks = Array(detachedHostDismissalTasks.values)
        detachedTasks.forEach { $0.cancel() }
        if let presentationID = currentPresentationID {
            await finishPresentation(
                id: presentationID,
                reason: nil,
                dismissWindow: true
            )
        } else {
            await presentationCleanupTask?.value
        }
        await waitForAllPresentationOperationsToFinish()
        await presentationCleanupTask?.value
        for task in detachedTasks {
            await task.value
        }
    }

    func dismissCurrentExperienceFromHost() async {
        guard let presentationID = currentPresentationID,
              let experienceViewController = currentExperienceViewController else {
            LogDebug("ExperiencePresentationService: No experience to dismiss")
            return
        }

        let presentation = DetachedHostPresentation(
            id: presentationID,
            window: currentWindow,
            experienceVersionId: currentExperienceId ?? "unknown",
            journeyContext: currentJourneyContext,
            viewController: experienceViewController,
            runtimeDelegate: currentRuntimeDelegate,
            runtimeDelegateTraceToken: currentRuntimeDelegateTraceToken
        )
        presentationAttemptGeneration &+= 1
        experienceViewController.beginHostDismissal()

        // Surface control is synchronous with respect to callback ownership.
        // The presentation slot remains occupied until Journey, commerce, and
        // renderer teardown all settle.
        presentationTeardownIDs.insert(presentationID)
        resumeJourneyForegroundAuthorityWaiters(
            presentationID: presentationID,
            authorized: false
        )
        currentPresentationID = nil
        currentWindow = nil
        currentExperienceId = nil
        currentJourneyContext = nil
        currentExperienceViewController = nil
        currentRuntimeDelegate = nil
        currentRuntimeDelegateTraceToken = nil
        experienceViewController.onClose = nil

        // Hide the visible window immediately, then keep the public await and
        // presentation capacity tied to the complete host-dismissal contract.
        let surfaceTask = Task<Void, Never> { @MainActor in
            await presentation.window?.dismiss()
            presentation.window?.destroy()
        }
        let completionTask = Task<Void, Never> { @MainActor [weak self] in
            await surfaceTask.value
            guard let self else {
                presentation.window?.destroy()
                return
            }
            await self.completeDetachedHostPresentation(presentation)
            self.detachedHostPresentations.removeValue(forKey: presentationID)
            self.detachedHostDismissalTasks.removeValue(forKey: presentationID)
            self.presentationTeardownIDs.remove(presentationID)
            self.releasePresentationOwnershipIfIdle()
            self.refreshJourneyPresentationCapacity()
        }
        detachedHostPresentations[presentationID] = presentation
        detachedHostDismissalTasks[presentationID] = completionTask
        await completionTask.value
    }
    
    func onAppBecameActive() {
        guard !appIsForeground else { return }
        LogDebug("ExperiencePresentationService: App became active, starting grace period")
        appIsForeground = true
        journeyForegroundAuthorityReady = false
        // Set grace period end time
        gracePeriodEndTime = Date().addingTimeInterval(foregroundGracePeriod)
        refreshJourneyPresentationCapacity()
    }

    func journeyProfileRefreshDidComplete() {
        guard appIsForeground else { return }
        journeyForegroundAuthorityReady = true
        if let currentPresentationID {
            resumeJourneyForegroundAuthorityWaiters(
                presentationID: currentPresentationID,
                authorized: true
            )
        }
        refreshJourneyPresentationCapacity()
    }
    
    func onAppDidEnterBackground() {
        LogDebug("ExperiencePresentationService: App entered background, clearing grace period")
        appIsForeground = false
        journeyForegroundAuthorityReady = false
        pendingJourneyReservation = nil
        if activePresentationOperations.values.contains(where: {
            $0.journeyOwnerDistinctId != nil
        }) {
            presentationAttemptGeneration &+= 1
        }
        // Clear grace period when going to background
        gracePeriodEndTime = nil
        refreshJourneyPresentationCapacity()
    }
    
    // MARK: - Private Methods
    
    private func handleExperienceDismissal(
        reason: CloseReason,
        presentationID: UUID
    ) async {
        let presentationOperationID = beginPresentationOperation()
        associatePresentationOperation(
            presentationOperationID,
            with: presentationID
        )
        defer { finishPresentationOperation(presentationOperationID) }
        await finishPresentation(
            id: presentationID,
            reason: reason,
            dismissWindow: false
        )
    }

    private func finishPresentation(
        id presentationID: UUID,
        reason: CloseReason?,
        dismissWindow: Bool,
        screenLifecyclePrepared: Bool = false
    ) async {
        guard currentPresentationID == presentationID else {
            LogDebug("ExperiencePresentationService: Ignoring stale experience dismissal callback")
            return
        }
        LogDebug("ExperiencePresentationService: Cleaning up presentation")
        presentationTeardownIDs.insert(presentationID)

        let window = currentWindow
        let experienceViewController = currentExperienceViewController
        let experienceVersionId = currentExperienceId ?? "unknown"
        let journeyContext = currentJourneyContext
        let runtimeDelegate = currentRuntimeDelegate
        let runtimeDelegateTraceToken = currentRuntimeDelegateTraceToken

        // The active screen reaches hidden and delivers its lifecycle analytics
        // before presentation ownership is revoked or its runtime is torn down.
        if !screenLifecyclePrepared {
            await experienceViewController?.prepareForDismissal(reason: reason)
        }
        guard currentPresentationID == presentationID else { return }

        // Revoke ownership before suspension so callbacks from this
        // presentation become stale immediately.
        resumeJourneyForegroundAuthorityWaiters(
            presentationID: presentationID,
            authorized: false
        )
        currentPresentationID = nil
        currentWindow = nil
        currentExperienceId = nil
        currentJourneyContext = nil
        currentExperienceViewController = nil
        currentRuntimeDelegate = nil
        currentRuntimeDelegateTraceToken = nil
        experienceViewController?.onClose = nil

        if let reason {
            LogInfo("ExperiencePresentationService: Experience \(experienceVersionId) dismissed with reason: \(reason)")
            if let journeyContext {
                trackJourneyDismissal(
                    reason,
                    experienceVersionId: experienceVersionId,
                    context: journeyContext
                )
            }
        }

        // Renderer-bound sessions must close before the host window is
        // destroyed so every imported child is released before its renderer.
        let previousCleanupTask = presentationCleanupTask
        let cleanupTask = Task<Void, Never> { @MainActor in
            await previousCleanupTask?.value
            if dismissWindow {
                await window?.dismiss()
            }
            await experienceViewController?.shutdownRuntime()
            window?.destroy()
        }
        presentationCleanupTask = cleanupTask
        await cleanupTask.value
        if let experienceViewController {
            if let scopedTraceDelegate = runtimeDelegate as? any ExperiencePresentationScopedTraceDelegate {
                scopedTraceDelegate.experienceViewControllerDidFinishPresentation(
                    experienceViewController,
                    traceToken: runtimeDelegateTraceToken
                )
            } else {
                runtimeDelegate?.experienceViewControllerDidFinishPresentation(
                    experienceViewController
                )
            }
        }
        presentationTeardownIDs.remove(presentationID)
        releasePresentationOwnershipIfIdle()
        refreshJourneyPresentationCapacity()
    }

    private func requireCurrentPresentationAttempt(_ generation: UInt64) throws {
        try Task.checkCancellation()
        guard presentationAttemptGeneration == generation else {
            throw CancellationError()
        }
    }

    private func completeDetachedHostPresentation(
        _ presentation: DetachedHostPresentation
    ) async {
        let viewController = presentation.viewController
        let runtimeDelegate = presentation.runtimeDelegate
        var accepted = false

        if !Task.isCancelled {
            // Reserve host input before authored screen teardown can dispatch
            // lifecycle callbacks into the same Journey.
            await runtimeDelegate?.experienceViewControllerWillRequestHostDismiss(
                viewController
            )
            await waitForPresentationOperationsToFinish(
                presentationID: presentation.id
            )
        }
        if !Task.isCancelled {
            await viewController.waitForInFlightPurchaseBeforeHostDismissal()
        }
        if !Task.isCancelled {
            await viewController.prepareForDismissal(reason: .hostDismissed)
        }

        if !Task.isCancelled {
            if let runtimeDelegate {
                while !Task.isCancelled {
                    accepted = await runtimeDelegate
                        .experienceViewControllerDidRequestHostDismiss(
                            viewController
                        )
                    if accepted { break }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            } else {
                accepted = true
            }
        }

        if accepted {
            let experienceVersionId = presentation.experienceVersionId
            LogInfo(
                "ExperiencePresentationService: Experience \(experienceVersionId) host dismissed"
            )
            if let journeyContext = presentation.journeyContext {
                trackJourneyDismissal(
                    .hostDismissed,
                    experienceVersionId: presentation.experienceVersionId,
                    context: journeyContext
                )
            }
        }

        await viewController.shutdownRuntime()
        if let scopedTraceDelegate = runtimeDelegate
            as? any ExperiencePresentationScopedTraceDelegate {
            scopedTraceDelegate.experienceViewControllerDidFinishPresentation(
                viewController,
                traceToken: presentation.runtimeDelegateTraceToken
            )
        } else {
            runtimeDelegate?.experienceViewControllerDidFinishPresentation(
                viewController
            )
        }
    }

    private func beginPresentationOperation() -> UUID {
        let operationID = UUID()
        activePresentationOperations[operationID] = PresentationOperationState(
            presentationID: nil,
            owner: nil,
            journeyOwnerDistinctId: nil
        )
        refreshJourneyPresentationCapacity()
        return operationID
    }

    private func claimPresentationOwnership(
        _ requestedOwner: PresentationOwner,
        operationID: UUID,
        journeyReservation: JourneyReservation? = nil,
        requiresJourneyReservation: Bool = false,
        journeyOwnerDistinctId: String? = nil
    ) throws {
        if presentationOwner != nil || !presentationTeardownIDs.isEmpty {
            throw ExperiencePresentationError.presentationDeclined
        }
        if presentationOwner == nil, requiresJourneyReservation {
            guard let journeyReservation,
                  pendingJourneyReservation?.id == journeyReservation.id,
                  pendingJourneyReservation?.ownerDistinctId
                    == journeyReservation.ownerDistinctId else {
                throw ExperiencePresentationError.presentationDeclined
            }
            pendingJourneyReservation = nil
        } else if let pendingJourneyReservation,
                  pendingJourneyReservation.id != journeyReservation?.id {
            throw ExperiencePresentationError.presentationDeclined
        }
        presentationOwner = requestedOwner
        guard var operation = activePresentationOperations[operationID] else {
            throw CancellationError()
        }
        operation.owner = requestedOwner
        operation.journeyOwnerDistinctId = journeyOwnerDistinctId
        activePresentationOperations[operationID] = operation
    }

    private func releasePresentationOwnershipIfIdle() {
        guard currentPresentationID == nil,
              presentationTeardownIDs.isEmpty,
              let presentationOwner,
              !activePresentationOperations.values.contains(where: {
                $0.owner == presentationOwner
              }) else { return }
        self.presentationOwner = nil
        refreshJourneyPresentationCapacity()
    }

    private func ownsCurrentJourneyPresentation(
        _ owner: JourneyPresentationOwner,
        presentationID expectedPresentationID: UUID? = nil
    ) -> Bool {
        guard let currentPresentationID,
              expectedPresentationID == nil
                || expectedPresentationID == currentPresentationID else {
            return false
        }
        return currentJourneyContext?.owner == owner
            && presentationOwner == .journey(owner)
    }

    private func admitJourneyPresentation<Prepared>(
        owner: JourneyPresentationOwner,
        prepare: () -> Prepared?
    ) async -> JourneyPresentationAdmission<Prepared> {
        guard let presentationID = currentPresentationID,
              let context = currentJourneyContext,
              let controller = currentExperienceViewController else {
            return .noPresentation
        }
        guard context.owner == owner,
              ownsCurrentJourneyPresentation(owner) else {
            return .declined
        }
        guard let prepared = prepare() else {
            return .rejected
        }
        guard await waitForJourneyForegroundAuthority(
            presentationID: presentationID
        ) else {
            return .noPresentation
        }
        guard ownsCurrentJourneyPresentation(
            owner,
            presentationID: presentationID
        ) else {
            return .noPresentation
        }
        return .admitted(
            presentationID: presentationID,
            controller: controller,
            prepared: prepared
        )
    }

    private func associatePresentationOperation(
        _ operationID: UUID,
        with presentationID: UUID
    ) {
        guard var operation = activePresentationOperations[operationID] else { return }
        let previousPresentationID = operation.presentationID
        operation.presentationID = presentationID
        activePresentationOperations[operationID] = operation
        if let previousPresentationID,
           previousPresentationID != presentationID {
            resumePresentationOperationWaitersIfReady(
                presentationID: previousPresentationID
            )
        }
    }

    private func finishPresentationOperation(_ operationID: UUID) {
        let operation = activePresentationOperations.removeValue(forKey: operationID)
        if let presentationID = operation?.presentationID {
            resumePresentationOperationWaitersIfReady(
                presentationID: presentationID
            )
        }
        if let ownerDistinctId = operation?.journeyOwnerDistinctId,
           !activePresentationOperations.values.contains(where: {
               $0.journeyOwnerDistinctId == ownerDistinctId
           }) {
            let waiters = journeyPresentationOperationWaiters
                .removeValue(forKey: ownerDistinctId) ?? []
            waiters.forEach { $0.resume() }
        }
        if activePresentationOperations.isEmpty {
            let waiters = allPresentationOperationWaiters
            allPresentationOperationWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        releasePresentationOwnershipIfIdle()
        refreshJourneyPresentationCapacity()
    }

    private var journeyPresentationCapacityIsAvailable: Bool {
        appIsForeground
            && journeyForegroundAuthorityReady
            && windowProvider.canPresentWindow()
            && presentationOwner == nil
            && currentPresentationID == nil
            && presentationTeardownIDs.isEmpty
            && pendingJourneyReservation == nil
            && activePresentationOperations.isEmpty
    }

    private func refreshJourneyPresentationCapacity() {
        let isAvailable = journeyPresentationCapacityIsAvailable
        guard isAvailable != journeyPresentationCapacityWasAvailable else {
            return
        }
        journeyPresentationCapacityWasAvailable = isAvailable
        if isAvailable {
            journeyPresentationAvailabilityHandler?()
        }
    }

    private func waitForAllPresentationOperationsToFinish() async {
        guard !activePresentationOperations.isEmpty else { return }
        await withCheckedContinuation { continuation in
            allPresentationOperationWaiters.append(continuation)
        }
    }

    private func waitForJourneyPresentationOperationsToFinish(
        ownerDistinctId: String
    ) async {
        guard activePresentationOperations.values.contains(where: {
            $0.journeyOwnerDistinctId == ownerDistinctId
        }) else { return }
        await withCheckedContinuation { continuation in
            journeyPresentationOperationWaiters[
                ownerDistinctId,
                default: []
            ].append(continuation)
        }
    }

    private func waitForJourneyForegroundAuthority(
        presentationID: UUID
    ) async -> Bool {
        guard currentPresentationID == presentationID else { return false }
        if appIsForeground && journeyForegroundAuthorityReady {
            return true
        }
        return await withCheckedContinuation { continuation in
            guard currentPresentationID == presentationID else {
                continuation.resume(returning: false)
                return
            }
            journeyForegroundAuthorityWaiters[
                presentationID,
                default: []
            ].append(continuation)
        }
    }

    private func resumeJourneyForegroundAuthorityWaiters(
        presentationID: UUID,
        authorized: Bool
    ) {
        let waiters = journeyForegroundAuthorityWaiters
            .removeValue(forKey: presentationID) ?? []
        waiters.forEach { $0.resume(returning: authorized) }
    }

    private func waitForPresentationOperationsToFinish(
        presentationID: UUID
    ) async {
        guard activePresentationOperations.values.contains(where: {
            $0.presentationID == presentationID
        }) else { return }
        await withCheckedContinuation { continuation in
            presentationOperationWaiters[presentationID, default: []]
                .append(continuation)
        }
    }

    private func resumePresentationOperationWaitersIfReady(
        presentationID: UUID
    ) {
        guard !activePresentationOperations.values.contains(where: {
            $0.presentationID == presentationID
        }) else { return }
        let waiters = presentationOperationWaiters
            .removeValue(forKey: presentationID) ?? []
        waiters.forEach { $0.resume() }
    }

    private func requireOwnedPresentation(
        _ presentationID: UUID,
        attemptGeneration: UInt64,
        fallbackWindow: PresentationWindowProtocol
    ) async throws {
        guard !Task.isCancelled,
              presentationAttemptGeneration == attemptGeneration,
              currentPresentationID == presentationID else {
            if currentPresentationID == presentationID {
                await finishPresentation(
                    id: presentationID,
                    reason: nil,
                    dismissWindow: true
                )
            } else {
                fallbackWindow.destroy()
            }
            throw CancellationError()
        }
    }

    private func trackJourneyDismissal(
        _ reason: CloseReason,
        experienceVersionId: String,
        context: JourneyPresentationContext
    ) {
        var properties = journeyExperienceProperties(
            experienceVersionId: experienceVersionId,
            context: context
        )
        switch reason {
        case .userDismissed:
            properties["reason"] = "user"
        case .goalMet:
            properties["reason"] = "goal_met"
        case .hostDismissed:
            properties["reason"] = "host"
        case .error(let error):
            properties["error_message"] = error.localizedDescription
            eventLog.track(
                JourneyEvents.experienceErrored,
                properties: properties,
                userProperties: nil,
                userPropertiesSetOnce: nil,
                distinctIdOverride: context.owner.distinctId
            )
            return
        }
        eventLog.track(
            JourneyEvents.experienceDismissed,
            properties: properties,
            userProperties: nil,
            userPropertiesSetOnce: nil,
            distinctIdOverride: context.owner.distinctId
        )
    }

    private func journeyExperienceProperties(
        experienceVersionId: String,
        context: JourneyPresentationContext
    ) -> [String: Any] {
        [
            "journey_id": context.owner.journeyId,
            "experience_id": context.experienceId,
            "experience_version": experienceVersionId,
        ]
    }
}

extension ExperiencePresentationService: ExperiencePresentationServiceProtocol {}
extension ExperiencePresentationService: JourneyPresenting {}

// MARK: - Errors

enum ExperiencePresentationError: LocalizedError {
    case noActiveScene
    case experienceNotFound(String)
    case presentationFailed(Error)
    case presentationSuperseded
    case presentationDeclined
    
    var errorDescription: String? {
        switch self {
        case .noActiveScene:
            return "No active window available for presentation"
        case .experienceNotFound(let experienceVersionId):
            return "Experience not found: \(experienceVersionId)"
        case .presentationFailed(let error):
            return "Experience presentation failed: \(error.localizedDescription)"
        case .presentationSuperseded:
            return "The authenticated presentation commit was superseded"
        case .presentationDeclined:
            return "Another Journey owns the presentation surface"
        }
    }
}
