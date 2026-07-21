import Foundation
@testable import Nuxie

/// Mock implementation of ExperiencePresentationService for testing
// @unchecked Sendable: all mutable state is serialized through `lock`.
// Non-final because integration tests subclass it to observe call ordering.
public class MockExperiencePresentationService: ExperiencePresentationServiceProtocol, @unchecked Sendable {

    private let lock = NSLock()

    // MARK: - Locked Storage

    private var _eventLog: EventLogProtocol?
    private var _presentedFlows: [(flowId: String, journey: Journey?)] = []
    private var _dismissedFlows: [String] = []
    private var _isPresentingFlow = false
    private var _mockViewControllers: [String: ExperienceViewController] = [:]
    private var _defaultMockViewController: ExperienceViewController?
    private var _shouldFailPresentation = false
    private var _presentationError: Error?
    private var _presentationDelay: TimeInterval = 0
    private var _presentFlowCallCount = 0
    private var _dismissCurrentFlowCallCount = 0

    public init() {}

    /// Event log used to emit journey dismissal events. When nil, dismissal
    /// tracking is skipped.
    public var eventLog: EventLogProtocol? {
        get { lock.withLock { _eventLog } }
        set { lock.withLock { _eventLog = newValue } }
    }

    // MARK: - Tracking Properties

    public var presentedFlows: [(flowId: String, journey: Journey?)] {
        get { lock.withLock { _presentedFlows } }
        set { lock.withLock { _presentedFlows = newValue } }
    }

    public var dismissedFlows: [String] {
        get { lock.withLock { _dismissedFlows } }
        set { lock.withLock { _dismissedFlows = newValue } }
    }

    public var isPresentingFlow: Bool {
        get { lock.withLock { _isPresentingFlow } }
        set { lock.withLock { _isPresentingFlow = newValue } }
    }

    public var mockViewControllers: [String: ExperienceViewController] {
        get { lock.withLock { _mockViewControllers } }
        set { lock.withLock { _mockViewControllers = newValue } }
    }

    public var defaultMockViewController: ExperienceViewController? {
        get { lock.withLock { _defaultMockViewController } }
        set { lock.withLock { _defaultMockViewController = newValue } }
    }

    // MARK: - Error Testing Properties

    public var shouldFailPresentation: Bool {
        get { lock.withLock { _shouldFailPresentation } }
        set { lock.withLock { _shouldFailPresentation = newValue } }
    }

    public var presentationError: Error? {
        get { lock.withLock { _presentationError } }
        set { lock.withLock { _presentationError = newValue } }
    }

    public var presentationDelay: TimeInterval {
        get { lock.withLock { _presentationDelay } }
        set { lock.withLock { _presentationDelay = newValue } }
    }

    // MARK: - Call Tracking

    public var presentFlowCallCount: Int {
        get { lock.withLock { _presentFlowCallCount } }
        set { lock.withLock { _presentFlowCallCount = newValue } }
    }

    public var dismissCurrentFlowCallCount: Int {
        get { lock.withLock { _dismissCurrentFlowCallCount } }
        set { lock.withLock { _dismissCurrentFlowCallCount = newValue } }
    }

    // MARK: - ExperiencePresentationServiceProtocol Implementation

    @MainActor
    public var isFlowPresented: Bool {
        return isPresentingFlow
    }

    @MainActor
    public var presentedJourneyId: String? {
        return lock.withLock {
            guard _isPresentingFlow else { return nil }
            return _presentedFlows.last?.journey?.id
        }
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
        let (delay, shouldFail, configuredError): (TimeInterval, Bool, Error?) = lock.withLock {
            _presentFlowCallCount += 1
            return (_presentationDelay, _shouldFailPresentation, _presentationError)
        }

        // Add delay if specified (for testing timing)
        if delay > 0 {
            LogDebug("[MockExperiencePresentationService] Adding delay of \(delay)s before presentation")
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }

        // Check if we should fail
        if shouldFail {
            let error = configuredError ?? FlowPresentationError.noActiveScene
            LogWarning("[MockExperiencePresentationService] Failing presentation as configured: \(error)")
            throw error
        }

        // Track the presentation attempt
        LogInfo("[MockExperiencePresentationService] Successfully presenting flow: \(flowId)")
        let (mockVC, defaultVC): (ExperienceViewController?, ExperienceViewController?) = lock.withLock {
            _presentedFlows.append((flowId: flowId, journey: journey))
            _isPresentingFlow = true
            return (_mockViewControllers[flowId], _defaultMockViewController)
        }

        let controller = mockVC
            ?? defaultVC
            ?? MockFlowViewController(mockFlowId: flowId)
        controller.runtimeDelegate = runtimeDelegate
        controller.colorSchemeMode = colorSchemeMode
        return controller
    }

    @MainActor
    public func dismissCurrentFlow() async {
        lock.withLock {
            _dismissCurrentFlowCallCount += 1

            // Track dismissal if there's a current flow
            if let lastFlow = _presentedFlows.last {
                _dismissedFlows.append(lastFlow.flowId)
            }

            _isPresentingFlow = false
        }
    }

    @MainActor
    public func dismissCurrentFlow(reason: CloseReason) async {
        let (lastFlow, eventLog): ((flowId: String, journey: Journey?)?, EventLogProtocol?) = lock.withLock {
            _dismissCurrentFlowCallCount += 1

            let last = _presentedFlows.last
            if let last {
                _dismissedFlows.append(last.flowId)
            }
            _isPresentingFlow = false
            return (last, _eventLog)
        }

        if let lastFlow, let journey = lastFlow.journey, let eventLog {
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
        lock.withLock {
            _presentedFlows.append((flowId: flowId, journey: journey))
            _isPresentingFlow = true
            _presentFlowCallCount += 1
        }
    }

    /// Simulate flow dismissal
    public func simulateDismissal() {
        lock.withLock {
            if let lastFlow = _presentedFlows.last {
                _dismissedFlows.append(lastFlow.flowId)
            }
            _isPresentingFlow = false
            _dismissCurrentFlowCallCount += 1
        }
    }

    /// Configure the mock to fail on next presentation
    public func configureToFail(with error: Error? = nil) {
        lock.withLock {
            _shouldFailPresentation = true
            _presentationError = error ?? FlowPresentationError.noActiveScene
        }
    }

    /// Configure the mock to succeed on next presentation
    public func configureToSucceed() {
        lock.withLock {
            _shouldFailPresentation = false
            _presentationError = nil
        }
    }

    /// Set presentation delay for testing timing scenarios
    public func setDelay(_ delay: TimeInterval) {
        lock.withLock {
            _presentationDelay = delay
        }
    }

    /// Get the last presented flow ID
    public var lastPresentedFlowId: String? {
        return lock.withLock { _presentedFlows.last?.flowId }
    }

    /// Get the last presented journey
    public var lastPresentedJourney: Journey? {
        return lock.withLock { _presentedFlows.last?.journey }
    }

    /// Check if a specific flow was presented
    public func wasFlowPresented(_ flowId: String) -> Bool {
        return lock.withLock { _presentedFlows.contains { $0.flowId == flowId } }
    }

    /// Check if a specific flow was dismissed
    public func wasFlowDismissed(_ flowId: String) -> Bool {
        return lock.withLock { _dismissedFlows.contains(flowId) }
    }

    /// Get all presented flow IDs
    public var allPresentedFlowIds: [String] {
        return lock.withLock { _presentedFlows.map { $0.flowId } }
    }

    /// Reset all mock state
    public func reset() {
        lock.withLock {
            _presentedFlows = []
            _dismissedFlows = []
            _isPresentingFlow = false
            _shouldFailPresentation = false
            _presentationError = nil
            _presentationDelay = 0
            _presentFlowCallCount = 0
            _dismissCurrentFlowCallCount = 0
            _mockViewControllers = [:]
            _defaultMockViewController = nil
        }
    }
}
