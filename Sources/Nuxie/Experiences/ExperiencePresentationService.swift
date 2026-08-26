import Foundation

/// Protocol for presenting experiences in dedicated windows
protocol ExperiencePresentationServiceProtocol: AnyObject, Sendable {
    /// Present a experience by ID in a dedicated window
    @discardableResult
    @MainActor func presentExperience(_ experienceVersionId: String, from journey: Journey?, runtimeDelegate: ExperienceRuntimeDelegate?) async throws -> ExperienceViewController

    /// Present a experience by ID in a dedicated window
    @discardableResult
    @MainActor func presentExperience(
        _ experienceVersionId: String,
        from journey: Journey?,
        runtimeDelegate: ExperienceRuntimeDelegate?,
        colorSchemeMode: ExperienceColorSchemeMode
    ) async throws -> ExperienceViewController

    @MainActor func presentExperience(
        _ experienceVersionId: String,
        from journey: Journey?,
        runtimeDelegate: ExperienceRuntimeDelegate?,
        colorSchemeMode: ExperienceColorSchemeMode,
        initialScreenID: String?
    ) async throws -> ExperienceViewController

    /// Presents the exact authenticated screen commit selected and persisted
    /// by journey control before renderer acquisition begins.
    @MainActor func presentExperience(
        _ experienceVersionId: String,
        from journey: Journey?,
        runtimeDelegate: ExperienceRuntimeDelegate?,
        colorSchemeMode: ExperienceColorSchemeMode,
        commit: JourneyPendingPresentation
    ) async throws -> ExperienceViewController
    
    /// Dismiss the currently presented experience
    @MainActor func dismissCurrentExperience() async
    @MainActor func dismissCurrentExperience(reason: CloseReason) async
    @MainActor func dismissCurrentExperienceFromHost() async
    
    /// Check if a experience is currently presented
    @MainActor var isExperiencePresented: Bool { get }
    @MainActor var presentedJourneyId: String? { get }
    
    /// Called when app becomes active - starts grace period
    @MainActor func onAppBecameActive()
    
    /// Called when app enters background - clears grace period
    @MainActor func onAppDidEnterBackground()
}

/// Service for presenting experiences in dedicated windows over the entire app
@MainActor
final class ExperiencePresentationService: ExperiencePresentationServiceProtocol {

    private struct PresentationOperationState {
        var presentationID: UUID?
    }

    private enum HostDismissalOwnership {
        case inProgress(presentationID: UUID)
        case retryRequired(presentationID: UUID)

        var presentationID: UUID {
            switch self {
            case .inProgress(let presentationID), .retryRequired(let presentationID):
                return presentationID
            }
        }

        var attemptIsInProgress: Bool {
            if case .inProgress = self { return true }
            return false
        }
    }
    
    // MARK: - Dependencies
    
    private let experienceService: ExperienceServiceProtocol
    private let eventLog: EventCapturing
    private let triggerBroker: TriggerBrokerProtocol
    private let dateProvider: DateProviderProtocol
    private let windowProvider: WindowProviderProtocol
    
    // MARK: - State
    
    internal var currentWindow: PresentationWindowProtocol?
    internal var currentExperienceId: String?
    internal var currentJourney: Journey?
    internal var currentExperienceViewController: ExperienceViewController?
    private var currentRuntimeDelegate: ExperienceRuntimeDelegate?
    private var currentRuntimeDelegateTraceToken: ExperiencePresentationTraceToken?
    private var currentPresentationID: UUID?
    private var presentationAttemptGeneration: UInt64 = 0
    private var presentationCleanupTask: Task<Void, Never>?
    private var hostDismissalOwnership: HostDismissalOwnership?
    private var hostDismissalOwnershipWaiters: [CheckedContinuation<Void, Never>] = []
    private var hostDismissalAttemptWaiters: [CheckedContinuation<Void, Never>] = []
    private var activePresentationOperations: [UUID: PresentationOperationState] = [:]
    private var presentationOperationWaiters:
        [UUID: [CheckedContinuation<Void, Never>]] = [:]
    
    // MARK: - Grace Period
    
    private let foregroundGracePeriod: TimeInterval = 0.75  // UX grace window
    private var gracePeriodEndTime: Date?
    
    // MARK: - Initialization
    
    /// Nonisolated so the composition root can construct the instance from
    /// any thread; all state access stays MainActor-isolated.
    nonisolated init(
        windowProvider: WindowProviderProtocol? = nil,
        experiences: ExperienceServiceProtocol,
        eventLog: EventCapturing,
        triggerBroker: TriggerBrokerProtocol,
        dateProvider: DateProviderProtocol
    ) {
        self.windowProvider = windowProvider ?? DefaultWindowProvider()
        self.experienceService = experiences
        self.eventLog = eventLog
        self.triggerBroker = triggerBroker
        self.dateProvider = dateProvider
    }
    
    // MARK: - Public API
    
    var isExperiencePresented: Bool {
        currentWindow != nil
    }

    var presentedJourneyId: String? {
        currentJourney?.id
    }

    @discardableResult
    func presentExperience(
        _ experienceVersionId: String,
        from journey: Journey?,
        runtimeDelegate: ExperienceRuntimeDelegate?
    ) async throws -> ExperienceViewController {
        try await presentExperience(
            experienceVersionId,
            from: journey,
            runtimeDelegate: runtimeDelegate,
            colorSchemeMode: .system
        )
    }

    @discardableResult
    func presentExperience(
        _ experienceVersionId: String,
        from journey: Journey?,
        runtimeDelegate: ExperienceRuntimeDelegate?,
        colorSchemeMode: ExperienceColorSchemeMode = .system
    ) async throws -> ExperienceViewController {
        try await presentExperience(
            experienceVersionId,
            from: journey,
            runtimeDelegate: runtimeDelegate,
            colorSchemeMode: colorSchemeMode,
            initialScreenID: nil
        )
    }

    @discardableResult
    func presentExperience(
        _ experienceVersionId: String,
        from journey: Journey?,
        runtimeDelegate: ExperienceRuntimeDelegate?,
        colorSchemeMode: ExperienceColorSchemeMode,
        initialScreenID: String?
    ) async throws -> ExperienceViewController {
        try await presentExperience(
            experienceVersionId,
            from: journey,
            runtimeDelegate: runtimeDelegate,
            colorSchemeMode: colorSchemeMode,
            initialScreenID: initialScreenID,
            expectedCommit: nil
        )
    }

    @discardableResult
    func presentExperience(
        _ experienceVersionId: String,
        from journey: Journey?,
        runtimeDelegate: ExperienceRuntimeDelegate?,
        colorSchemeMode: ExperienceColorSchemeMode,
        commit: JourneyPendingPresentation
    ) async throws -> ExperienceViewController {
        guard commit.experienceVersionId == experienceVersionId,
              await experienceService.validatesPresentationCommit(commit) else {
            throw ExperiencePresentationError.presentationSuperseded
        }
        return try await presentExperience(
            experienceVersionId,
            from: journey,
            runtimeDelegate: runtimeDelegate,
            colorSchemeMode: colorSchemeMode,
            initialScreenID: commit.screenId,
            expectedCommit: commit
        )
    }

    private func presentExperience(
        _ experienceVersionId: String,
        from journey: Journey?,
        runtimeDelegate: ExperienceRuntimeDelegate?,
        colorSchemeMode: ExperienceColorSchemeMode,
        initialScreenID: String?,
        expectedCommit: JourneyPendingPresentation?
    ) async throws -> ExperienceViewController {
        await waitForHostDismissalOwnershipIfNeeded()
        let presentationOperationID = beginPresentationOperation()
        defer { finishPresentationOperation(presentationOperationID) }
        LogInfo("ExperiencePresentationService: Presenting experience \(experienceVersionId)")
        presentationAttemptGeneration &+= 1
        let attemptGeneration = presentationAttemptGeneration
        
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
        
        // Dismiss any currently presented experience first
        if let presentationID = currentPresentationID {
            associatePresentationOperation(
                presentationOperationID,
                with: presentationID
            )
            LogWarning("ExperiencePresentationService: Dismissing existing experience before presenting new one")
            await finishPresentation(
                id: presentationID,
                reason: nil,
                dismissWindow: true
            )
        }
        try requireCurrentPresentationAttempt(attemptGeneration)
        
        // 1. Check if we can present
        guard windowProvider.canPresentWindow() else {
            LogError("ExperiencePresentationService: No active window available")
            throw ExperiencePresentationError.noActiveScene
        }
        
        // 2. Get experience view controller from ExperienceService
        let traceContext = (
            runtimeDelegate as? any ExperiencePresentationTraceContextProviding
        )?.presentationTraceContext
        let experienceViewController = try await experienceService.viewController(
            for: experienceVersionId,
            runtimeDelegate: runtimeDelegate,
            colorSchemeMode: colorSchemeMode,
            presentationTraceContext: traceContext,
            initialScreenID: initialScreenID
        )
        try requireCurrentPresentationAttempt(attemptGeneration)
        if let expectedCommit,
           await !experienceService.validatesPresentationCommit(expectedCommit) {
            throw ExperiencePresentationError.presentationSuperseded
        }
        let resolvedInitialScreenID = initialScreenID
            ?? (experienceViewController.experience.behaviorPresentationScreens.count == 1
                ? experienceViewController.experience.behaviorPresentationScreens.keys.first
                : nil)
        if experienceViewController.experience.authenticatedReleaseID != nil,
           resolvedInitialScreenID == nil {
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
        self.currentJourney = journey
        self.currentExperienceViewController = experienceViewController
        self.currentRuntimeDelegate = runtimeDelegate
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
            screenId: resolvedInitialScreenID
        )
        let warmReservation = await experienceService
            .reserveMemoryWarmPresentation(for: experienceViewController.experience)
        do {
            try await requireOwnedPresentation(
                presentationID,
                attemptGeneration: attemptGeneration,
                fallbackWindow: window
            )
        } catch {
            warmReservation?.release()
            throw error
        }
        experienceViewController.configurePresentationShell(
            shell,
            suppressLoadingTreatment: warmReservation != nil,
            warmReservation: warmReservation
        )

        // Every presentation owns freshly opened interactive screens, even
        // when ExperienceService returns a cached view controller.
        await experienceViewController.prepareForPresentation(
            traceToken: currentRuntimeDelegateTraceToken,
            initialScreenID: resolvedInitialScreenID
        )
        if let expectedCommit,
           await !experienceService.validatesPresentationCommit(expectedCommit) {
            await finishPresentation(
                id: presentationID,
                reason: nil,
                dismissWindow: true
            )
            throw ExperiencePresentationError.presentationSuperseded
        }
        try await requireOwnedPresentation(
            presentationID,
            attemptGeneration: attemptGeneration,
            fallbackWindow: window
        )
        // 6. Present experience
        if let expectedCommit,
           await !experienceService.validatesPresentationCommit(expectedCommit) {
            await finishPresentation(
                id: presentationID,
                reason: nil,
                dismissWindow: true
            )
            throw ExperiencePresentationError.presentationSuperseded
        }
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

        if let journey = journey {
            await journey.markExperienceShown(at: dateProvider.now())
            let state = await journey.snapshot()
            eventLog.track(
                JourneyEvents.experienceShown,
                properties: JourneyEvents.experienceShownProperties(
                    experienceVersion: experienceVersionId,
                    journey: state
                ),
                userProperties: nil,
                userPropertiesSetOnce: nil
            )
            if let originEventId = await journey.getContext("_origin_event_id")?.value as? String {
                let ref = ExperienceRef(
                    experienceId: journey.experienceId,
                    experienceVersion: journey.experienceVersion,
                    journeyId: journey.id
                )
                await triggerBroker.emit(eventId: originEventId, update: .decision(.experienceShown(ref)))
            }
        }

        try await requireOwnedPresentation(
            presentationID,
            attemptGeneration: attemptGeneration,
            fallbackWindow: window
        )

        LogDebug("ExperiencePresentationService: Successfully presented experience \(experienceVersionId)")
        return experienceViewController
    }
    
    func dismissCurrentExperience() async {
        guard let presentationID = currentPresentationID else {
            LogDebug("ExperiencePresentationService: No experience to dismiss")
            return
        }
        await waitForHostDismissalOwnershipIfNeeded()
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
        await waitForHostDismissalOwnershipIfNeeded()
        guard currentPresentationID == presentationID else { return }
        presentationAttemptGeneration &+= 1

        LogInfo("ExperiencePresentationService: Dismissing current experience with reason \(reason)")

        await finishPresentation(
            id: presentationID,
            reason: reason,
            dismissWindow: true
        )
    }

    func dismissCurrentExperienceFromHost() async {
        if hostDismissalOwnership?.attemptIsInProgress == true {
            await waitForHostDismissalAttemptIfNeeded()
            return
        }
        guard let presentationID = currentPresentationID,
              let experienceViewController = currentExperienceViewController else {
            LogDebug("ExperiencePresentationService: No experience to dismiss")
            return
        }

        let runtimeDelegate = currentRuntimeDelegate
        if let ownedPresentationID = hostDismissalOwnership?.presentationID,
           ownedPresentationID != presentationID {
            finishHostDismissalOwnership(presentationID: ownedPresentationID)
        }
        hostDismissalOwnership = .inProgress(presentationID: presentationID)
        experienceViewController.beginHostDismissal()
        var retryRequired = false
        defer {
            if retryRequired, currentPresentationID == presentationID {
                hostDismissalOwnership = .retryRequired(
                    presentationID: presentationID
                )
            } else {
                finishHostDismissalOwnership(presentationID: presentationID)
            }
            finishHostDismissalAttempt()
        }
        presentationAttemptGeneration &+= 1

        await runtimeDelegate?.experienceViewControllerWillRequestHostDismiss(
            experienceViewController
        )
        guard currentPresentationID == presentationID else { return }

        await waitForPresentationOperationsToFinish(
            presentationID: presentationID
        )
        guard currentPresentationID == presentationID else { return }

        await experienceViewController.waitForInFlightCommerceBeforeHostDismissal()
        guard currentPresentationID == presentationID else { return }

        let terminalized = await runtimeDelegate?.experienceViewControllerDidRequestHostDismiss(
            experienceViewController
        ) ?? true
        guard currentPresentationID == presentationID else { return }
        guard terminalized else {
            // A false result normally means that the journey's terminal write
            // should be retried. An identity change can instead have already
            // cancelled and removed the journey while its host presentation is
            // still visible. There is then nothing left to terminalize, so do
            // not retain host-dismissal ownership and wedge later presents.
            if let journey = currentJourney,
               !(await journey.snapshot()).status.isLive {
                await finishPresentation(
                    id: presentationID,
                    reason: .hostDismissed,
                    dismissWindow: true
                )
                return
            }
            experienceViewController.cancelHostDismissal()
            retryRequired = true
            return
        }

        await finishPresentation(
            id: presentationID,
            reason: .hostDismissed,
            dismissWindow: true
        )
    }
    
    func onAppBecameActive() {
        LogDebug("ExperiencePresentationService: App became active, starting grace period")
        // Set grace period end time
        gracePeriodEndTime = Date().addingTimeInterval(foregroundGracePeriod)
    }
    
    func onAppDidEnterBackground() {
        LogDebug("ExperiencePresentationService: App entered background, clearing grace period")
        // Clear grace period when going to background
        gracePeriodEndTime = nil
    }
    
    // MARK: - Private Methods
    
    private func handleExperienceDismissal(
        reason: CloseReason,
        presentationID: UUID
    ) async {
        if hostDismissalOwnership?.presentationID == presentationID {
            await waitForHostDismissalOwnershipIfNeeded()
            return
        }
        await finishPresentation(
            id: presentationID,
            reason: reason,
            dismissWindow: false
        )
    }

    private func finishPresentation(
        id presentationID: UUID,
        reason: CloseReason?,
        dismissWindow: Bool
    ) async {
        if shouldYieldPresentationToHost(presentationID, reason: reason) {
            return
        }
        guard currentPresentationID == presentationID else {
            LogDebug("ExperiencePresentationService: Ignoring stale experience dismissal callback")
            return
        }
        LogDebug("ExperiencePresentationService: Cleaning up presentation")

        let window = currentWindow
        let experienceViewController = currentExperienceViewController
        let experienceVersionId = currentExperienceId ?? "unknown"
        let journey = currentJourney
        let runtimeDelegate = currentRuntimeDelegate
        let runtimeDelegateTraceToken = currentRuntimeDelegateTraceToken

        // The active screen reaches hidden and delivers its lifecycle analytics
        // before presentation ownership is revoked or its runtime is torn down.
        await experienceViewController?.prepareForDismissal(reason: reason)
        if shouldYieldPresentationToHost(presentationID, reason: reason) {
            return
        }
        guard currentPresentationID == presentationID else { return }

        // Revoke ownership before suspension so callbacks from this
        // presentation become stale immediately.
        currentPresentationID = nil
        currentWindow = nil
        currentExperienceId = nil
        currentJourney = nil
        currentExperienceViewController = nil
        currentRuntimeDelegate = nil
        currentRuntimeDelegateTraceToken = nil
        experienceViewController?.onClose = nil

        if let reason {
            LogInfo("ExperiencePresentationService: Experience \(experienceVersionId) dismissed with reason: \(reason)")
            await trackDismissal(reason, experienceVersionId: experienceVersionId, journey: journey)
        }

        // Sessions and their Apple surfaces must be detached before the host
        // window is destroyed.
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
    }

    private func requireCurrentPresentationAttempt(_ generation: UInt64) throws {
        try Task.checkCancellation()
        guard presentationAttemptGeneration == generation else {
            throw CancellationError()
        }
    }

    private func waitForHostDismissalOwnershipIfNeeded() async {
        guard hostDismissalOwnership != nil else { return }
        await withCheckedContinuation { continuation in
            hostDismissalOwnershipWaiters.append(continuation)
        }
    }

    private func waitForHostDismissalAttemptIfNeeded() async {
        guard hostDismissalOwnership?.attemptIsInProgress == true else { return }
        await withCheckedContinuation { continuation in
            hostDismissalAttemptWaiters.append(continuation)
        }
    }

    private func finishHostDismissalOwnership(presentationID: UUID) {
        guard hostDismissalOwnership?.presentationID == presentationID else { return }
        hostDismissalOwnership = nil
        let waiters = hostDismissalOwnershipWaiters
        hostDismissalOwnershipWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func finishHostDismissalAttempt() {
        let waiters = hostDismissalAttemptWaiters
        hostDismissalAttemptWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func shouldYieldPresentationToHost(
        _ presentationID: UUID,
        reason: CloseReason?
    ) -> Bool {
        guard hostDismissalOwnership?.presentationID == presentationID else { return false }
        return reason != .hostDismissed
    }

    private func beginPresentationOperation() -> UUID {
        let operationID = UUID()
        activePresentationOperations[operationID] = PresentationOperationState(
            presentationID: nil
        )
        return operationID
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
        let presentationID = activePresentationOperations
            .removeValue(forKey: operationID)?
            .presentationID
        if let presentationID {
            resumePresentationOperationWaitersIfReady(
                presentationID: presentationID
            )
        }
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
        if hostDismissalOwnership?.presentationID == presentationID {
            throw CancellationError()
        }
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

    private func trackDismissal(
        _ reason: CloseReason,
        experienceVersionId: String,
        journey: Journey?
    ) async {
        guard let journey else { return }
        let state = await journey.snapshot()

        switch reason {
        case .userDismissed, .goalMet, .hostDismissed:
            eventLog.track(
                JourneyEvents.experienceDismissed,
                properties: JourneyEvents.experienceDismissedProperties(
                    experienceVersion: experienceVersionId,
                    journey: state,
                    reason: reason
                ),
                userProperties: nil,
                userPropertiesSetOnce: nil,
                distinctIdOverride: journey.distinctId
            )
        case .error(let error):
            eventLog.track(
                JourneyEvents.experienceErrored,
                properties: JourneyEvents.experienceErroredProperties(
                    experienceVersion: experienceVersionId,
                    journey: state,
                    errorMessage: error.localizedDescription
                ),
                userProperties: nil,
                userPropertiesSetOnce: nil
            )
        }
    }
}

// MARK: - Errors

enum ExperiencePresentationError: LocalizedError {
    case noActiveScene
    case experienceNotFound(String)
    case presentationFailed(Error)
    case presentationSuperseded
    
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
        }
    }
}
