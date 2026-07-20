import Foundation
import FactoryKit

/// Protocol for presenting flows in dedicated windows
protocol FlowPresentationServiceProtocol: AnyObject {
    /// Present a flow by ID in a dedicated window
    @discardableResult
    @MainActor func presentFlow(_ flowId: String, from journey: Journey?, runtimeDelegate: FlowRuntimeDelegate?) async throws -> FlowViewController

    /// Present a flow by ID in a dedicated window
    @discardableResult
    @MainActor func presentFlow(
        _ flowId: String,
        from journey: Journey?,
        runtimeDelegate: FlowRuntimeDelegate?,
        colorSchemeMode: FlowColorSchemeMode
    ) async throws -> FlowViewController
    
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
final class FlowPresentationService: FlowPresentationServiceProtocol {
    
    // MARK: - Dependencies
    
    @Injected(\.flowService) private var flowService: FlowServiceProtocol
    @Injected(\.eventService) private var eventService: EventServiceProtocol
    @Injected(\.triggerBroker) private var triggerBroker: TriggerBrokerProtocol
    @Injected(\.dateProvider) private var dateProvider: DateProviderProtocol
    private let windowProvider: WindowProviderProtocol
    
    // MARK: - State
    
    internal var currentWindow: PresentationWindowProtocol?
    internal var currentFlowId: String?
    internal var currentJourney: Journey?
    /// The VC whose onClose is allowed to tear down the current presentation.
    private weak var currentViewController: FlowViewController?
    /// Reentrancy guard: presentFlow has multiple suspension points (grace
    /// period, VC load) — two concurrent calls must not both pass the
    /// isFlowPresented check and each create a window.
    private var isPresentationInProgress = false
    
    // MARK: - Grace Period
    
    private let foregroundGracePeriod: TimeInterval = 0.75  // UX grace window
    private var gracePeriodEndTime: Date?
    
    // MARK: - Initialization
    
    init(windowProvider: WindowProviderProtocol? = nil) {
        self.windowProvider = windowProvider ?? DefaultWindowProvider()
    }
    
    // MARK: - Public API
    
    var isFlowPresented: Bool {
        currentWindow?.isPresenting ?? false
    }

    var presentedJourneyId: String? {
        currentJourney?.id
    }

    @discardableResult
    func presentFlow(
        _ flowId: String,
        from journey: Journey?,
        runtimeDelegate: FlowRuntimeDelegate?
    ) async throws -> FlowViewController {
        try await presentFlow(
            flowId,
            from: journey,
            runtimeDelegate: runtimeDelegate,
            colorSchemeMode: .light
        )
    }

    @discardableResult
    func presentFlow(
        _ flowId: String,
        from journey: Journey?,
        runtimeDelegate: FlowRuntimeDelegate?,
        colorSchemeMode: FlowColorSchemeMode = .light
    ) async throws -> FlowViewController {
        LogInfo("FlowPresentationService: Presenting flow \(flowId)")
        
        // Check if we're within the grace period
        if let gracePeriodEnd = gracePeriodEndTime {
            let now = Date()
            if now < gracePeriodEnd {
                let delaySeconds = gracePeriodEnd.timeIntervalSince(now)
                LogDebug("FlowPresentationService: Delaying flow presentation by \(delaySeconds) seconds (grace period)")
                try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            }
        }
        
        guard !isPresentationInProgress else {
            LogWarning("FlowPresentationService: Presentation already in progress, rejecting \(flowId)")
            throw FlowPresentationError.presentationInProgress
        }
        isPresentationInProgress = true
        defer { isPresentationInProgress = false }

        // Dismiss any currently presented flow first
        if isFlowPresented {
            LogWarning("FlowPresentationService: Dismissing existing flow before presenting new one")
            await dismissCurrentFlow()
        }
        
        // 1. Check if we can present
        guard windowProvider.canPresentWindow() else {
            LogError("FlowPresentationService: No active window available")
            throw FlowPresentationError.noActiveScene
        }
        
        // 2. Get flow view controller from FlowService
        let flowViewController = try await flowService.viewController(
            for: flowId,
            runtimeDelegate: runtimeDelegate,
            colorSchemeMode: colorSchemeMode
        )
        
        // 3. Create presentation window
        guard let window = windowProvider.createPresentationWindow() else {
            LogError("FlowPresentationService: Failed to create presentation window")
            throw FlowPresentationError.noActiveScene
        }
        
        // 4. Set up dismissal handler. The closure is identity-stamped: a
        // stale onClose from a previously-presented VC (late completion,
        // fallback timer) must not tear down a NEWER flow's window.
        flowViewController.onClose = { [weak self, weak flowViewController] reason in
            Task { @MainActor in
                guard let self, let flowViewController else { return }
                await self.handleFlowDismissal(reason: reason, from: flowViewController)
            }
        }

        // 5. Store state before presenting to avoid race conditions
        self.currentWindow = window
        self.currentFlowId = flowId
        self.currentJourney = journey
        self.currentViewController = flowViewController
        
        // 6. Present flow
        await window.present(flowViewController)

        if let journey = journey {
            journey.markFlowShown(at: dateProvider.now())
            eventService.track(
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

        LogDebug("FlowPresentationService: Successfully presented flow \(flowId)")
        return flowViewController
    }
    
    func dismissCurrentFlow() async {
        guard let window = currentWindow else {
            LogDebug("FlowPresentationService: No flow to dismiss")
            return
        }
        
        LogInfo("FlowPresentationService: Dismissing current flow")
        
        // Dismiss the presented view controller
        await window.dismiss()
        
        // Clean up window and state
        await cleanupPresentation()
    }

    func dismissCurrentFlow(reason: CloseReason) async {
        guard let window = currentWindow else {
            LogDebug("FlowPresentationService: No flow to dismiss")
            return
        }

        LogInfo("FlowPresentationService: Dismissing current flow with reason \(reason)")

        await window.dismiss()
        await handleFlowDismissal(reason: reason)
    }
    
    func onAppBecameActive() {
        LogDebug("FlowPresentationService: App became active, starting grace period")
        // Set grace period end time
        gracePeriodEndTime = Date().addingTimeInterval(foregroundGracePeriod)
    }
    
    func onAppDidEnterBackground() {
        LogDebug("FlowPresentationService: App entered background, clearing grace period")
        // Clear grace period when going to background
        gracePeriodEndTime = nil
    }
    
    // MARK: - Private Methods
    
    private func handleFlowDismissal(reason: CloseReason, from viewController: FlowViewController? = nil) async {
        // Ignore closes from a VC that is no longer the presented one.
        if let viewController, let current = currentViewController, viewController !== current {
            LogDebug("FlowPresentationService: Ignoring stale onClose from a previous presentation")
            return
        }

        let flowId = currentFlowId ?? "unknown"
        let journey = currentJourney

        LogInfo("FlowPresentationService: Flow \(flowId) dismissed with reason: \(reason)")

        // Track specific flow event based on reason
        if let journey = journey {
            switch reason {
            case .userDismissed:
                eventService.track(
                    JourneyEvents.flowDismissed,
                    properties: JourneyEvents.flowDismissedProperties(flowId: flowId, journey: journey),
                    userProperties: nil,
                    userPropertiesSetOnce: nil
                )

            case .goalMet:
                eventService.track(
                    JourneyEvents.flowDismissed,
                    properties: JourneyEvents.flowDismissedProperties(flowId: flowId, journey: journey),
                    userProperties: nil,
                    userPropertiesSetOnce: nil
                )

            case .purchaseCompleted:
                eventService.track(
                    JourneyEvents.flowPurchased,
                    properties: JourneyEvents.flowPurchasedProperties(flowId: flowId, journey: journey, productId: nil),
                    userProperties: nil,
                    userPropertiesSetOnce: nil
                )

            case .timeout:
                eventService.track(
                    JourneyEvents.flowTimedOut,
                    properties: JourneyEvents.flowTimedOutProperties(flowId: flowId, journey: journey),
                    userProperties: nil,
                    userPropertiesSetOnce: nil
                )

            case .error(let error):
                eventService.track(
                    JourneyEvents.flowErrored,
                    properties: JourneyEvents.flowErroredProperties(flowId: flowId, journey: journey, errorMessage: error.localizedDescription),
                    userProperties: nil,
                    userPropertiesSetOnce: nil
                )
            }
        }

        // Clean up
        await cleanupPresentation()
    }
    
    private func cleanupPresentation() async {
        LogDebug("FlowPresentationService: Cleaning up presentation")
        
        // Destroy window
        currentWindow?.destroy()
        currentWindow = nil
        
        // Reset state
        currentFlowId = nil
        currentJourney = nil
    }
}

// MARK: - Errors

enum FlowPresentationError: LocalizedError {
    case noActiveScene
    case flowNotFound(String)
    case presentationInProgress
    case presentationFailed(Error)
    
    var errorDescription: String? {
        switch self {
        case .noActiveScene:
            return "No active window available for presentation"
        case .flowNotFound(let flowId):
            return "Flow not found: \(flowId)"
        case .presentationFailed(let error):
            return "Flow presentation failed: \(error.localizedDescription)"
        case .presentationInProgress:
            return "A flow presentation is already in progress"
        }
    }
}
