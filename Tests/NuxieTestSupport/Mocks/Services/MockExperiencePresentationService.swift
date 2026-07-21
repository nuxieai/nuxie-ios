import Foundation
import FactoryKit
@testable import Nuxie

/// Mock implementation of ExperiencePresentationService for testing
public class MockExperiencePresentationService: ExperiencePresentationServiceProtocol {
    
    // MARK: - Tracking Properties
    
    public var presentedFlows: [(flowId: String, journey: Journey?)] = []
    public var dismissedFlows: [String] = []
    public var isPresentingFlow = false
    public var mockViewControllers: [String: ExperienceViewController] = [:]
    public var defaultMockViewController: ExperienceViewController?
    
    // MARK: - Error Testing Properties
    
    public var shouldFailPresentation = false
    public var presentationError: Error?
    public var presentationDelay: TimeInterval = 0
    
    // MARK: - Call Tracking
    
    public var presentFlowCallCount = 0
    public var dismissCurrentFlowCallCount = 0
    
    // MARK: - ExperiencePresentationServiceProtocol Implementation
    
    @MainActor
    public var isFlowPresented: Bool {
        return isPresentingFlow
    }

    @MainActor
    public var presentedJourneyId: String? {
        guard isPresentingFlow else { return nil }
        return presentedFlows.last?.journey?.id
    }
    
    @discardableResult
    @MainActor
    public func presentExperience(_ flowId: String, from journey: Journey?, runtimeDelegate: FlowRuntimeDelegate?) async throws -> ExperienceViewController {
        try await presentExperience(
            flowId,
            from: journey,
            runtimeDelegate: runtimeDelegate,
            colorSchemeMode: .light
        )
    }

    @discardableResult
    @MainActor
    public func presentExperience(
        _ flowId: String,
        from journey: Journey?,
        runtimeDelegate: FlowRuntimeDelegate?,
        colorSchemeMode: ExperienceColorSchemeMode
    ) async throws -> ExperienceViewController {
        LogDebug("[MockExperiencePresentationService] presentExperience called with flowId: \(flowId), journey: \(journey?.id ?? "nil")")
        presentFlowCallCount += 1
        
        // Add delay if specified (for testing timing)
        if presentationDelay > 0 {
            LogDebug("[MockExperiencePresentationService] Adding delay of \(presentationDelay)s before presentation")
            try await Task.sleep(nanoseconds: UInt64(presentationDelay * 1_000_000_000))
        }
        
        // Check if we should fail
        if shouldFailPresentation {
            let error = presentationError ?? FlowPresentationError.noActiveScene
            LogWarning("[MockExperiencePresentationService] Failing presentation as configured: \(error)")
            throw error
        }
        
        // Track the presentation attempt
        LogInfo("[MockExperiencePresentationService] Successfully presenting flow: \(flowId)")
        presentedFlows.append((flowId: flowId, journey: journey))
        isPresentingFlow = true

        let controller = mockViewControllers[flowId]
            ?? defaultMockViewController
            ?? MockFlowViewController(mockFlowId: flowId)
        controller.runtimeDelegate = runtimeDelegate
        controller.colorSchemeMode = colorSchemeMode
        return controller
    }
    
    @MainActor
    public func dismissCurrentFlow() async {
        dismissCurrentFlowCallCount += 1
        
        // Track dismissal if there's a current flow
        if let lastFlow = presentedFlows.last {
            dismissedFlows.append(lastFlow.flowId)
        }
        
        isPresentingFlow = false
    }

    @MainActor
    public func dismissCurrentFlow(reason: CloseReason) async {
        dismissCurrentFlowCallCount += 1

        if let lastFlow = presentedFlows.last {
            dismissedFlows.append(lastFlow.flowId)
            if let journey = lastFlow.journey {
                let eventLog = Container.shared.eventLog()
                switch reason {
                case .userDismissed, .goalMet:
                    eventLog.track(
                        JourneyEvents.flowDismissed,
                        properties: JourneyEvents.flowDismissedProperties(flowId: lastFlow.flowId, journey: journey),
                        userProperties: nil,
                        userPropertiesSetOnce: nil
                    )
                case .purchaseCompleted:
                    eventLog.track(
                        JourneyEvents.flowPurchased,
                        properties: JourneyEvents.flowPurchasedProperties(flowId: lastFlow.flowId, journey: journey, productId: nil),
                        userProperties: nil,
                        userPropertiesSetOnce: nil
                    )
                case .timeout:
                    eventLog.track(
                        JourneyEvents.flowTimedOut,
                        properties: JourneyEvents.flowTimedOutProperties(flowId: lastFlow.flowId, journey: journey),
                        userProperties: nil,
                        userPropertiesSetOnce: nil
                    )
                case .error(let error):
                    eventLog.track(
                        JourneyEvents.flowErrored,
                        properties: JourneyEvents.flowErroredProperties(flowId: lastFlow.flowId, journey: journey, errorMessage: error.localizedDescription),
                        userProperties: nil,
                        userPropertiesSetOnce: nil
                    )
                }
            }
        }

        isPresentingFlow = false
    }
    
    @MainActor
    public func onAppBecameActive() {
        // Mock implementation - no-op for tests
    }
    
    @MainActor
    public func onAppDidEnterBackground() {
        // Mock implementation - no-op for tests
    }
    
    // MARK: - Test Helper Methods
    
    /// Simulate successful flow presentation
    public func simulateSuccessfulPresentation(flowId: String, journey: Journey? = nil) {
        presentedFlows.append((flowId: flowId, journey: journey))
        isPresentingFlow = true
        presentFlowCallCount += 1
    }
    
    /// Simulate flow dismissal
    public func simulateDismissal() {
        if let lastFlow = presentedFlows.last {
            dismissedFlows.append(lastFlow.flowId)
        }
        isPresentingFlow = false
        dismissCurrentFlowCallCount += 1
    }
    
    /// Configure the mock to fail on next presentation
    public func configureToFail(with error: Error? = nil) {
        shouldFailPresentation = true
        presentationError = error ?? FlowPresentationError.noActiveScene
    }
    
    /// Configure the mock to succeed on next presentation
    public func configureToSucceed() {
        shouldFailPresentation = false
        presentationError = nil
    }
    
    /// Set presentation delay for testing timing scenarios
    public func setDelay(_ delay: TimeInterval) {
        presentationDelay = delay
    }
    
    /// Get the last presented flow ID
    public var lastPresentedFlowId: String? {
        return presentedFlows.last?.flowId
    }
    
    /// Get the last presented journey
    public var lastPresentedJourney: Journey? {
        return presentedFlows.last?.journey
    }
    
    /// Check if a specific flow was presented
    public func wasFlowPresented(_ flowId: String) -> Bool {
        return presentedFlows.contains { $0.flowId == flowId }
    }
    
    /// Check if a specific flow was dismissed
    public func wasFlowDismissed(_ flowId: String) -> Bool {
        return dismissedFlows.contains(flowId)
    }
    
    /// Get all presented flow IDs
    public var allPresentedFlowIds: [String] {
        return presentedFlows.map { $0.flowId }
    }
    
    /// Reset all mock state
    public func reset() {
        presentedFlows = []
        dismissedFlows = []
        isPresentingFlow = false
        shouldFailPresentation = false
        presentationError = nil
        presentationDelay = 0
        presentFlowCallCount = 0
        dismissCurrentFlowCallCount = 0
        mockViewControllers = [:]
        defaultMockViewController = nil
    }
}
