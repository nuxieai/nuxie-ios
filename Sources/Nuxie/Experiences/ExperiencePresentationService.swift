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
private final class PresentationScreenGone {
    private var isFinished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isFinished else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func finish() {
        guard !isFinished else { return }
        isFinished = true
        let waiters = waiters
        self.waiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

/// Service for presenting experiences in dedicated windows over the entire app
@MainActor
final class ExperiencePresentationService: ExperiencePresentationServiceProtocol {

    private struct PresentationOperationState {
        var presentationID: UUID?
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
    private var currentExperienceShownTracked = false
    private var inFlightHostDismissalCompletion: PresentationScreenGone?
    private var presentationAttemptGeneration: UInt64 = 0
    private var presentationShutdownGeneration: UInt64 = 0
    private var presentationCleanupTask: Task<Void, Never>?
    private var activePresentationOperations: [UUID: PresentationOperationState] = [:]
    private var presentationOperationWaiters:
        [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private var allPresentationOperationWaiters: [CheckedContinuation<Void, Never>] = []
    
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
        guard commit.experienceVersionId == experienceVersionId else {
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
        let presentationOperationID = beginPresentationOperation()
        defer { finishPresentationOperation(presentationOperationID) }
        let shutdownGeneration = presentationShutdownGeneration
        try Task.checkCancellation()
        guard presentationShutdownGeneration == shutdownGeneration else {
            throw CancellationError()
        }
        // Validate the commit BEFORE advancing the attempt generation: an
        // invalid request must not supersede a valid suspended presentation.
        // The operation stays registered above either way, so shutdown still
        // joins this call.
        if let expectedCommit {
            guard await experienceService.validatesPresentationCommit(expectedCommit) else {
                throw ExperiencePresentationError.presentationSuperseded
            }
            guard presentationShutdownGeneration == shutdownGeneration else {
                throw CancellationError()
            }
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
        try requireCurrentPresentationAttempt(attemptGeneration)
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
        self.currentExperienceShownTracked = false
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
            try await requireOwnedPresentation(
                presentationID,
                attemptGeneration: attemptGeneration,
                fallbackWindow: window
            )
            let state = await journey.snapshot()
            try await requireOwnedPresentation(
                presentationID,
                attemptGeneration: attemptGeneration,
                fallbackWindow: window
            )
            currentExperienceShownTracked = true
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
                try await requireOwnedPresentation(
                    presentationID,
                    attemptGeneration: attemptGeneration,
                    fallbackWindow: window
                )
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
        presentationShutdownGeneration &+= 1
        presentationAttemptGeneration &+= 1
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
    }

    func dismissCurrentExperienceFromHost() async {
        if let inFlightHostDismissalCompletion {
            await inFlightHostDismissalCompletion.wait()
            return
        }
        guard let presentationID = currentPresentationID,
              let experienceViewController = currentExperienceViewController else {
            LogDebug("ExperiencePresentationService: No experience to dismiss")
            return
        }

        let dismissalCompletion = PresentationScreenGone()
        inFlightHostDismissalCompletion = dismissalCompletion
        defer {
            dismissalCompletion.finish()
            if inFlightHostDismissalCompletion === dismissalCompletion {
                inFlightHostDismissalCompletion = nil
            }
        }

        let runtimeDelegate = currentRuntimeDelegate
        let experienceVersionId = currentExperienceId ?? "unknown"
        let journey = currentJourney
        let experienceShownWasTracked = currentExperienceShownTracked
        experienceViewController.beginHostDismissal()
        presentationAttemptGeneration &+= 1

        // Revoke presentation identity and begin teardown before asking the run
        // to select its terminal outcome. The screen is never retained for a
        // failed write or a competing outcome, and commerce continues through
        // its transaction observers independently of this presentation.
        guard let screenGone = beginPresentationTeardown(
            id: presentationID,
            reason: .hostDismissed,
            dismissWindow: true,
            trackDismissalFact: false,
            joinPresentationOperationsBeforeClose: true
        ) else { return }

        let selected = await runtimeDelegate?.experienceViewControllerDidRequestHostDismiss(
            experienceViewController
        ) ?? true
        if selected, experienceShownWasTracked {
            Task { @MainActor [weak self] in
                await self?.trackDismissal(
                    .hostDismissed,
                    experienceVersionId: experienceVersionId,
                    journey: journey
                )
            }
        }
        await screenGone.wait()
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
        dismissWindow: Bool
    ) async {
        guard let screenGone = beginPresentationTeardown(
            id: presentationID,
            reason: reason,
            dismissWindow: dismissWindow,
            trackDismissalFact: true,
            joinPresentationOperationsBeforeClose: false
        ) else { return }
        await screenGone.wait()
        await presentationCleanupTask?.value
    }

    private func beginPresentationTeardown(
        id presentationID: UUID,
        reason: CloseReason?,
        dismissWindow: Bool,
        trackDismissalFact: Bool,
        joinPresentationOperationsBeforeClose: Bool
    ) -> PresentationScreenGone? {
        guard currentPresentationID == presentationID else {
            LogDebug("ExperiencePresentationService: Ignoring stale experience dismissal callback")
            return nil
        }
        LogDebug("ExperiencePresentationService: Cleaning up presentation")

        let window = currentWindow
        let experienceViewController = currentExperienceViewController
        let experienceVersionId = currentExperienceId ?? "unknown"
        let journey = currentJourney
        let runtimeDelegate = currentRuntimeDelegate
        let runtimeDelegateTraceToken = currentRuntimeDelegateTraceToken
        let experienceShownWasTracked = currentExperienceShownTracked

        // Revoke ownership synchronously so callbacks from this presentation
        // become stale and a subsequent presentation cannot inherit its result.
        currentPresentationID = nil
        currentWindow = nil
        currentExperienceId = nil
        currentJourney = nil
        currentExperienceViewController = nil
        currentRuntimeDelegate = nil
        currentRuntimeDelegateTraceToken = nil
        currentExperienceShownTracked = false
        experienceViewController?.onClose = nil

        let screenGone = PresentationScreenGone()
        let previousCleanupTask = presentationCleanupTask
        let cleanupTask = Task<Void, Never> { @MainActor in
            await previousCleanupTask?.value
            // The active screen reaches hidden and delivers its lifecycle
            // analytics before its runtime is torn down.
            await experienceViewController?.prepareForDismissal(reason: reason)
            if joinPresentationOperationsBeforeClose {
                await self.waitForPresentationOperationsToFinish(
                    presentationID: presentationID
                )
            }
            if trackDismissalFact, experienceShownWasTracked, let reason {
                LogInfo("ExperiencePresentationService: Experience \(experienceVersionId) dismissed with reason: \(reason)")
                await self.trackDismissal(
                    reason,
                    experienceVersionId: experienceVersionId,
                    journey: journey
                )
            }
            if dismissWindow {
                await window?.dismiss()
            }
            screenGone.finish()
            // Sessions and their Apple surfaces must be detached before the
            // host window is destroyed. This native cleanup is write-behind
            // from the dismiss caller's screen-gone return boundary.
            await experienceViewController?.shutdownRuntime()
            window?.destroy()
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
        presentationCleanupTask = cleanupTask
        return screenGone
    }

    private func requireCurrentPresentationAttempt(_ generation: UInt64) throws {
        try Task.checkCancellation()
        guard presentationAttemptGeneration == generation else {
            throw CancellationError()
        }
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
        if activePresentationOperations.isEmpty {
            let waiters = allPresentationOperationWaiters
            allPresentationOperationWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    private func waitForAllPresentationOperationsToFinish() async {
        guard !activePresentationOperations.isEmpty else { return }
        await withCheckedContinuation { continuation in
            allPresentationOperationWaiters.append(continuation)
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
