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
    
    /// Dismiss the currently presented experience
    @MainActor func dismissCurrentExperience() async
    @MainActor func dismissCurrentExperience(reason: CloseReason) async
    
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
    private var currentPresentationID: UUID?
    private var presentationAttemptGeneration: UInt64 = 0
    private var presentationCleanupTask: Task<Void, Never>?
    
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
            colorSchemeMode: .light
        )
    }

    @discardableResult
    func presentExperience(
        _ experienceVersionId: String,
        from journey: Journey?,
        runtimeDelegate: ExperienceRuntimeDelegate?,
        colorSchemeMode: ExperienceColorSchemeMode = .light
    ) async throws -> ExperienceViewController {
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
        let experienceViewController = try await experienceService.viewController(
            for: experienceVersionId,
            runtimeDelegate: runtimeDelegate,
            colorSchemeMode: colorSchemeMode
        )
        try requireCurrentPresentationAttempt(attemptGeneration)
        
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
        self.currentPresentationID = presentationID

        // Every presentation owns freshly opened interactive screens, even
        // when ExperienceService returns a cached view controller.
        await experienceViewController.prepareForPresentation()
        try await requireOwnedPresentation(
            presentationID,
            attemptGeneration: attemptGeneration,
            fallbackWindow: window
        )
        
        // 6. Present experience
        await window.present(experienceViewController)
        try await requireOwnedPresentation(
            presentationID,
            attemptGeneration: attemptGeneration,
            fallbackWindow: window
        )

        if let journey = journey {
            journey.markExperienceShown(at: dateProvider.now())
            eventLog.track(
                JourneyEvents.experienceShown,
                properties: JourneyEvents.experienceShownProperties(
                    experienceVersion: experienceVersionId,
                    journey: journey
                ),
                userProperties: nil,
                userPropertiesSetOnce: nil
            )
            if let originEventId = journey.getContext("_origin_event_id") as? String {
                let ref = JourneyRef(
                    journeyId: journey.id,
                    experienceId: journey.experienceId,
                    experienceVersion: journey.experienceVersion
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
        presentationAttemptGeneration &+= 1
        guard let presentationID = currentPresentationID else {
            LogDebug("ExperiencePresentationService: No experience to dismiss")
            return
        }
        
        LogInfo("ExperiencePresentationService: Dismissing current experience")
        
        await finishPresentation(
            id: presentationID,
            reason: nil,
            dismissWindow: true
        )
    }

    func dismissCurrentExperience(reason: CloseReason) async {
        presentationAttemptGeneration &+= 1
        guard let presentationID = currentPresentationID else {
            LogDebug("ExperiencePresentationService: No experience to dismiss")
            return
        }

        LogInfo("ExperiencePresentationService: Dismissing current experience with reason \(reason)")

        await finishPresentation(
            id: presentationID,
            reason: reason,
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
        guard currentPresentationID == presentationID else {
            LogDebug("ExperiencePresentationService: Ignoring stale experience dismissal callback")
            return
        }
        LogDebug("ExperiencePresentationService: Cleaning up presentation")

        let window = currentWindow
        let experienceViewController = currentExperienceViewController
        let experienceVersionId = currentExperienceId ?? "unknown"
        let journey = currentJourney

        // Revoke ownership before suspension so callbacks from this
        // presentation become stale immediately.
        currentPresentationID = nil
        currentWindow = nil
        currentExperienceId = nil
        currentJourney = nil
        currentExperienceViewController = nil
        experienceViewController?.onClose = nil

        if let reason {
            LogInfo("ExperiencePresentationService: Experience \(experienceVersionId) dismissed with reason: \(reason)")
            trackDismissal(reason, experienceVersionId: experienceVersionId, journey: journey)
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
    }

    private func requireCurrentPresentationAttempt(_ generation: UInt64) throws {
        try Task.checkCancellation()
        guard presentationAttemptGeneration == generation else {
            throw CancellationError()
        }
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
    ) {
        guard let journey else { return }

        switch reason {
        case .userDismissed, .goalMet:
            eventLog.track(
                JourneyEvents.experienceDismissed,
                properties: JourneyEvents.experienceDismissedProperties(
                    experienceVersion: experienceVersionId,
                    journey: journey
                ),
                userProperties: nil,
                userPropertiesSetOnce: nil
            )
        case .purchaseCompleted:
            eventLog.track(
                JourneyEvents.experiencePurchased,
                properties: JourneyEvents.experiencePurchasedProperties(
                    experienceVersion: experienceVersionId,
                    journey: journey,
                    productId: nil
                ),
                userProperties: nil,
                userPropertiesSetOnce: nil
            )
        case .timeout:
            eventLog.track(
                JourneyEvents.experienceTimedOut,
                properties: JourneyEvents.experienceTimedOutProperties(
                    experienceVersion: experienceVersionId,
                    journey: journey
                ),
                userProperties: nil,
                userPropertiesSetOnce: nil
            )
        case .error(let error):
            eventLog.track(
                JourneyEvents.experienceErrored,
                properties: JourneyEvents.experienceErroredProperties(
                    experienceVersion: experienceVersionId,
                    journey: journey,
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
    
    var errorDescription: String? {
        switch self {
        case .noActiveScene:
            return "No active window available for presentation"
        case .experienceNotFound(let experienceVersionId):
            return "Experience not found: \(experienceVersionId)"
        case .presentationFailed(let error):
            return "Experience presentation failed: \(error.localizedDescription)"
        }
    }
}
