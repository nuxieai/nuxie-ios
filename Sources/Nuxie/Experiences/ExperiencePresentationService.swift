import Foundation
import FactoryKit

/// Protocol for presenting flows in dedicated windows
protocol ExperiencePresentationServiceProtocol: AnyObject {
    /// Present a flow by ID in a dedicated window
    @discardableResult
    @MainActor func presentExperience(_ flowId: String, from journey: Journey?, runtimeDelegate: FlowRuntimeDelegate?) async throws -> ExperienceViewController

    /// Present a flow by ID in a dedicated window
    @discardableResult
    @MainActor func presentExperience(
        _ flowId: String,
        from journey: Journey?,
        runtimeDelegate: FlowRuntimeDelegate?,
        colorSchemeMode: ExperienceColorSchemeMode
    ) async throws -> ExperienceViewController
    
    /// Dismiss the currently presented flow
    @MainActor func dismissCurrentFlow() async
    @MainActor func dismissCurrentFlow(reason: CloseReason) async
    
    /// Check if a flow is currently presented
    @MainActor var isFlowPresented: Bool { get }
    @MainActor var presentedJourneyId: String? { get }
    
    /// Called when app becomes active - starts grace period
    @MainActor func onAppBecameActive()
    
    /// Called when app enters background - clears grace period
    @MainActor func onAppDidEnterBackground()
}

/// Service for presenting flows in dedicated windows over the entire app
@MainActor
final class ExperiencePresentationService: ExperiencePresentationServiceProtocol {
    
    // MARK: - Dependencies
    
    private let flowService: ExperienceServiceProtocol
    private let eventLog: EventLogProtocol
    private let triggerBroker: TriggerBrokerProtocol
    private let dateProvider: DateProviderProtocol
    private let windowProvider: WindowProviderProtocol
    
    // MARK: - State
    
    internal var currentWindow: PresentationWindowProtocol?
    internal var currentFlowId: String?
    internal var currentJourney: Journey?
    internal var currentFlowViewController: ExperienceViewController?
    private var currentPresentationID: UUID?
    private var presentationAttemptGeneration: UInt64 = 0
    private var presentationCleanupTask: Task<Void, Never>?
    
    // MARK: - Grace Period
    
    private let foregroundGracePeriod: TimeInterval = 0.75  // UX grace window
    private var gracePeriodEndTime: Date?
    
    // MARK: - Initialization
    
    init(
        windowProvider: WindowProviderProtocol? = nil,
        flows: ExperienceServiceProtocol = Container.shared.flowService(),
        eventLog: EventLogProtocol = Container.shared.eventLog(),
        triggerBroker: TriggerBrokerProtocol = Container.shared.triggerBroker(),
        dateProvider: DateProviderProtocol = Container.shared.dateProvider()
    ) {
        self.windowProvider = windowProvider ?? DefaultWindowProvider()
        self.flowService = flows
        self.eventLog = eventLog
        self.triggerBroker = triggerBroker
        self.dateProvider = dateProvider
    }
    
    // MARK: - Public API
    
    var isFlowPresented: Bool {
        currentWindow != nil
    }

    var presentedJourneyId: String? {
        currentJourney?.id
    }

    @discardableResult
    func presentExperience(
        _ flowId: String,
        from journey: Journey?,
        runtimeDelegate: FlowRuntimeDelegate?
    ) async throws -> ExperienceViewController {
        try await presentExperience(
            flowId,
            from: journey,
            runtimeDelegate: runtimeDelegate,
            colorSchemeMode: .light
        )
    }

    @discardableResult
    func presentExperience(
        _ flowId: String,
        from journey: Journey?,
        runtimeDelegate: FlowRuntimeDelegate?,
        colorSchemeMode: ExperienceColorSchemeMode = .light
    ) async throws -> ExperienceViewController {
        LogInfo("ExperiencePresentationService: Presenting flow \(flowId)")
        presentationAttemptGeneration &+= 1
        let attemptGeneration = presentationAttemptGeneration
        
        // Check if we're within the grace period
        if let gracePeriodEnd = gracePeriodEndTime {
            let now = Date()
            if now < gracePeriodEnd {
                let delaySeconds = gracePeriodEnd.timeIntervalSince(now)
                LogDebug("ExperiencePresentationService: Delaying flow presentation by \(delaySeconds) seconds (grace period)")
                try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            }
        }
        await presentationCleanupTask?.value
        try requireCurrentPresentationAttempt(attemptGeneration)
        
        // Dismiss any currently presented flow first
        if let presentationID = currentPresentationID {
            LogWarning("ExperiencePresentationService: Dismissing existing flow before presenting new one")
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
            throw FlowPresentationError.noActiveScene
        }
        
        // 2. Get flow view controller from ExperienceService
        let flowViewController = try await flowService.viewController(
            for: flowId,
            runtimeDelegate: runtimeDelegate,
            colorSchemeMode: colorSchemeMode
        )
        try requireCurrentPresentationAttempt(attemptGeneration)
        
        // 3. Create presentation window
        guard let window = windowProvider.createPresentationWindow() else {
            LogError("ExperiencePresentationService: Failed to create presentation window")
            throw FlowPresentationError.noActiveScene
        }
        
        // 4. Set up a presentation-scoped dismissal handler. Cached view
        // controllers can be reused, so an old callback must never tear down a
        // newer presentation of the same controller.
        let presentationID = UUID()
        flowViewController.onClose = { [weak self] reason in
            Task { @MainActor in
                await self?.handleFlowDismissal(
                    reason: reason,
                    presentationID: presentationID
                )
            }
        }

        // 5. Store state before presenting to avoid race conditions
        self.currentWindow = window
        self.currentFlowId = flowId
        self.currentJourney = journey
        self.currentFlowViewController = flowViewController
        self.currentPresentationID = presentationID

        // Every presentation owns a freshly imported runtime context, even
        // when ExperienceService returns a cached view controller.
        await flowViewController.prepareForPresentation()
        try await requireOwnedPresentation(
            presentationID,
            attemptGeneration: attemptGeneration,
            fallbackWindow: window
        )
        
        // 6. Present flow
        await window.present(flowViewController)
        try await requireOwnedPresentation(
            presentationID,
            attemptGeneration: attemptGeneration,
            fallbackWindow: window
        )

        if let journey = journey {
            journey.markFlowShown(at: dateProvider.now())
            eventLog.track(
                JourneyEvents.flowShown,
                properties: JourneyEvents.flowShownProperties(flowId: flowId, journey: journey),
                userProperties: nil,
                userPropertiesSetOnce: nil
            )
            if let originEventId = journey.getContext("_origin_event_id") as? String {
                let ref = JourneyRef(
                    journeyId: journey.id,
                    campaignId: journey.campaignId,
                    flowId: journey.flowId
                )
                await triggerBroker.emit(eventId: originEventId, update: .decision(.flowShown(ref)))
            }
        }

        try await requireOwnedPresentation(
            presentationID,
            attemptGeneration: attemptGeneration,
            fallbackWindow: window
        )

        LogDebug("ExperiencePresentationService: Successfully presented flow \(flowId)")
        return flowViewController
    }
    
    func dismissCurrentFlow() async {
        presentationAttemptGeneration &+= 1
        guard let presentationID = currentPresentationID else {
            LogDebug("ExperiencePresentationService: No flow to dismiss")
            return
        }
        
        LogInfo("ExperiencePresentationService: Dismissing current flow")
        
        await finishPresentation(
            id: presentationID,
            reason: nil,
            dismissWindow: true
        )
    }

    func dismissCurrentFlow(reason: CloseReason) async {
        presentationAttemptGeneration &+= 1
        guard let presentationID = currentPresentationID else {
            LogDebug("ExperiencePresentationService: No flow to dismiss")
            return
        }

        LogInfo("ExperiencePresentationService: Dismissing current flow with reason \(reason)")

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
    
    private func handleFlowDismissal(
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
            LogDebug("ExperiencePresentationService: Ignoring stale flow dismissal callback")
            return
        }
        LogDebug("ExperiencePresentationService: Cleaning up presentation")

        let window = currentWindow
        let flowViewController = currentFlowViewController
        let flowId = currentFlowId ?? "unknown"
        let journey = currentJourney

        // Revoke ownership before suspension so callbacks from this
        // presentation become stale immediately.
        currentPresentationID = nil
        currentWindow = nil
        currentFlowId = nil
        currentJourney = nil
        currentFlowViewController = nil
        flowViewController?.onClose = nil

        if let reason {
            LogInfo("ExperiencePresentationService: Experience \(flowId) dismissed with reason: \(reason)")
            trackDismissal(reason, flowId: flowId, journey: journey)
        }

        // Sessions and their Apple surfaces must be detached before the host
        // window is destroyed.
        let previousCleanupTask = presentationCleanupTask
        let cleanupTask = Task<Void, Never> { @MainActor in
            await previousCleanupTask?.value
            if dismissWindow {
                await window?.dismiss()
            }
            await flowViewController?.shutdownRuntime()
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
        flowId: String,
        journey: Journey?
    ) {
        guard let journey else { return }

        switch reason {
        case .userDismissed, .goalMet:
            eventLog.track(
                JourneyEvents.flowDismissed,
                properties: JourneyEvents.flowDismissedProperties(flowId: flowId, journey: journey),
                userProperties: nil,
                userPropertiesSetOnce: nil
            )
        case .purchaseCompleted:
            eventLog.track(
                JourneyEvents.flowPurchased,
                properties: JourneyEvents.flowPurchasedProperties(flowId: flowId, journey: journey, productId: nil),
                userProperties: nil,
                userPropertiesSetOnce: nil
            )
        case .timeout:
            eventLog.track(
                JourneyEvents.flowTimedOut,
                properties: JourneyEvents.flowTimedOutProperties(flowId: flowId, journey: journey),
                userProperties: nil,
                userPropertiesSetOnce: nil
            )
        case .error(let error):
            eventLog.track(
                JourneyEvents.flowErrored,
                properties: JourneyEvents.flowErroredProperties(
                    flowId: flowId,
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

enum FlowPresentationError: LocalizedError {
    case noActiveScene
    case flowNotFound(String)
    case presentationFailed(Error)
    
    var errorDescription: String? {
        switch self {
        case .noActiveScene:
            return "No active window available for presentation"
        case .flowNotFound(let flowId):
            return "Experience not found: \(flowId)"
        case .presentationFailed(let error):
            return "Experience presentation failed: \(error.localizedDescription)"
        }
    }
}
