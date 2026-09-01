import Foundation
@testable import Nuxie

/// Mock implementation of ExperiencePresentationService for testing
// @unchecked Sendable: all mutable state is serialized through `lock`.
// Non-final because integration tests subclass it to observe call ordering.
class MockExperiencePresentationService: ExperiencePresentationServiceProtocol, @unchecked Sendable {

    private let lock = NSLock()

    // MARK: - Locked Storage

    private var _eventLog: EventLogProtocol?
    private var _presentedExperiences: [(experienceVersionId: String, journey: Journey?)] = []
    private var _dismissedExperiences: [String] = []
    private var _isPresentingExperience = false
    private var _mockViewControllers: [String: ExperienceViewController] = [:]
    private var _defaultMockViewController: ExperienceViewController?
    private var _shouldFailPresentation = false
    private var _presentationError: Error?
    private var _presentationDelay: TimeInterval = 0
    private var _presentExperienceCallCount = 0
    private var _dismissCurrentExperienceCallCount = 0
    private var _shutdownCurrentExperienceCallCount = 0
    private var _currentRuntimeDelegate: ExperienceRuntimeDelegate?
    private var _currentExperienceViewController: ExperienceViewController?
    private var _initialScreenIDs: [String?] = []

    public init() {}

    /// Event log used to emit journey dismissal events. When nil, dismissal
    /// tracking is skipped.
    public var eventLog: EventLogProtocol? {
        get { lock.withLock { _eventLog } }
        set { lock.withLock { _eventLog = newValue } }
    }

    // MARK: - Tracking Properties

    public var presentedExperiences: [(experienceVersionId: String, journey: Journey?)] {
        get { lock.withLock { _presentedExperiences } }
        set { lock.withLock { _presentedExperiences = newValue } }
    }

    public var dismissedExperiences: [String] {
        get { lock.withLock { _dismissedExperiences } }
        set { lock.withLock { _dismissedExperiences = newValue } }
    }

    public var isPresentingExperience: Bool {
        get { lock.withLock { _isPresentingExperience } }
        set { lock.withLock { _isPresentingExperience = newValue } }
    }

    var mockViewControllers: [String: ExperienceViewController] {
        get { lock.withLock { _mockViewControllers } }
        set { lock.withLock { _mockViewControllers = newValue } }
    }

    var defaultMockViewController: ExperienceViewController? {
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

    public var presentExperienceCallCount: Int {
        get { lock.withLock { _presentExperienceCallCount } }
        set { lock.withLock { _presentExperienceCallCount = newValue } }
    }

    public var dismissCurrentExperienceCallCount: Int {
        get { lock.withLock { _dismissCurrentExperienceCallCount } }
        set { lock.withLock { _dismissCurrentExperienceCallCount = newValue } }
    }

    /// Number of coordinated shutdown requests received by the mock.
    public var shutdownCurrentExperienceCallCount: Int {
        get { lock.withLock { _shutdownCurrentExperienceCallCount } }
        set { lock.withLock { _shutdownCurrentExperienceCallCount = newValue } }
    }

    var currentRuntimeDelegate: ExperienceRuntimeDelegate? {
        lock.withLock { _currentRuntimeDelegate }
    }

    public var initialScreenIDs: [String?] {
        lock.withLock { _initialScreenIDs }
    }

    // MARK: - ExperiencePresentationServiceProtocol Implementation

    @MainActor
    public var isExperiencePresented: Bool {
        return isPresentingExperience
    }

    @MainActor
    public var presentedJourneyId: String? {
        return lock.withLock {
            guard _isPresentingExperience else { return nil }
            return _presentedExperiences.last?.journey?.id
        }
    }

    @discardableResult
    @MainActor
    func presentExperience(_ experienceVersionId: String, from journey: Journey?, runtimeDelegate: ExperienceRuntimeDelegate?) async throws -> ExperienceViewController {
        try await presentExperience(
            experienceVersionId,
            from: journey,
            runtimeDelegate: runtimeDelegate,
            colorSchemeMode: .system
        )
    }

    @discardableResult
    @MainActor
    func presentExperience(
        _ experienceVersionId: String,
        from journey: Journey?,
        runtimeDelegate: ExperienceRuntimeDelegate?,
        colorSchemeMode: ExperienceColorSchemeMode
    ) async throws -> ExperienceViewController {
        LogDebug("[MockExperiencePresentationService] presentExperience called with experienceVersionId: \(experienceVersionId), journey: \(journey?.id ?? "nil")")
        let (delay, shouldFail, configuredError): (TimeInterval, Bool, Error?) = lock.withLock {
            _presentExperienceCallCount += 1
            return (_presentationDelay, _shouldFailPresentation, _presentationError)
        }

        // Add delay if specified (for testing timing)
        if delay > 0 {
            LogDebug("[MockExperiencePresentationService] Adding delay of \(delay)s before presentation")
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }

        // Check if we should fail
        if shouldFail {
            lock.withLock { _currentRuntimeDelegate = runtimeDelegate }
            let error = configuredError ?? ExperiencePresentationError.noActiveScene
            LogWarning("[MockExperiencePresentationService] Failing presentation as configured: \(error)")
            throw error
        }

        // Track the presentation attempt
        LogInfo("[MockExperiencePresentationService] Successfully presenting flow: \(experienceVersionId)")
        let (mockVC, defaultVC): (ExperienceViewController?, ExperienceViewController?) = lock.withLock {
            _presentedExperiences.append((experienceVersionId: experienceVersionId, journey: journey))
            _isPresentingExperience = true
            _currentRuntimeDelegate = runtimeDelegate
            return (_mockViewControllers[experienceVersionId], _defaultMockViewController)
        }

        let controller = mockVC
            ?? defaultVC
            ?? MockExperienceViewController(mockExperienceVersionId: experienceVersionId)
        controller.runtimeDelegate = runtimeDelegate
        controller.colorSchemeMode = colorSchemeMode
        lock.withLock { _currentExperienceViewController = controller }
        return controller
    }

    @discardableResult
    @MainActor
    func presentExperience(
        _ experienceVersionId: String,
        from journey: Journey?,
        runtimeDelegate: ExperienceRuntimeDelegate?,
        colorSchemeMode: ExperienceColorSchemeMode,
        initialScreenID: String?
    ) async throws -> ExperienceViewController {
        lock.withLock { _initialScreenIDs.append(initialScreenID) }
        return try await presentExperience(
            experienceVersionId,
            from: journey,
            runtimeDelegate: runtimeDelegate,
            colorSchemeMode: colorSchemeMode
        )
    }

    @discardableResult
    @MainActor
    func presentExperience(
        _ experienceVersionId: String,
        from journey: Journey?,
        runtimeDelegate: ExperienceRuntimeDelegate?,
        colorSchemeMode: ExperienceColorSchemeMode,
        commit: JourneyPendingPresentation
    ) async throws -> ExperienceViewController {
        try await presentExperience(
            experienceVersionId,
            from: journey,
            runtimeDelegate: runtimeDelegate,
            colorSchemeMode: colorSchemeMode,
            initialScreenID: commit.screenId
        )
    }

    @MainActor
    public func dismissCurrentExperience() async {
        lock.withLock {
            _dismissCurrentExperienceCallCount += 1

            // Track dismissal if there's a current experience
            if let lastPresentation = _presentedExperiences.last {
                _dismissedExperiences.append(lastPresentation.experienceVersionId)
            }

            _isPresentingExperience = false
            _currentRuntimeDelegate = nil
            _currentExperienceViewController = nil
        }
    }

    @MainActor
    func shutdownCurrentExperience() async {
        lock.withLock { _shutdownCurrentExperienceCallCount += 1 }
        if isExperiencePresented {
            await dismissCurrentExperience()
        }
    }

    @MainActor
    func dismissCurrentExperience(reason: CloseReason) async {
        let (lastPresentation, eventLog): ((experienceVersionId: String, journey: Journey?)?, EventLogProtocol?) = lock.withLock {
            _dismissCurrentExperienceCallCount += 1

            let last = _presentedExperiences.last
            if let last {
                _dismissedExperiences.append(last.experienceVersionId)
            }
            _isPresentingExperience = false
            _currentRuntimeDelegate = nil
            _currentExperienceViewController = nil
            return (last, _eventLog)
        }

        if let lastPresentation, let journey = lastPresentation.journey, let eventLog {
            let state = await journey.snapshot()
            switch reason {
            case .userDismissed, .goalMet, .hostDismissed:
                eventLog.track(
                    JourneyEvents.experienceDismissed,
                    properties: JourneyEvents.experienceDismissedProperties(
                        experienceVersion: lastPresentation.experienceVersionId,
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
                        experienceVersion: lastPresentation.experienceVersionId,
                        journey: state,
                        errorMessage: error.localizedDescription
                    ),
                    userProperties: nil,
                    userPropertiesSetOnce: nil
                )
            }
        }
    }

    @MainActor
    public func dismissCurrentExperienceFromHost() async {
        let (controller, delegate) = lock.withLock {
            (_currentExperienceViewController, _currentRuntimeDelegate)
        }
        var terminalized = true
        if let controller {
            controller.beginHostDismissal()
            await delegate?.experienceViewControllerWillRequestHostDismiss(controller)
            await controller.waitForInFlightPurchaseBeforeHostDismissal()
            terminalized = await delegate?.experienceViewControllerDidRequestHostDismiss(
                controller
            ) ?? true
            if terminalized {
                await controller.prepareForDismissal(reason: .hostDismissed)
            } else {
                controller.cancelHostDismissal()
            }
        }
        guard terminalized else { return }
        await dismissCurrentExperience(reason: .hostDismissed)
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
    public func simulateSuccessfulPresentation(experienceVersionId: String, journey: Journey? = nil) {
        lock.withLock {
            _presentedExperiences.append((experienceVersionId: experienceVersionId, journey: journey))
            _isPresentingExperience = true
            _presentExperienceCallCount += 1
        }
    }

    /// Simulate experience dismissal
    public func simulateDismissal() {
        lock.withLock {
            if let lastPresentation = _presentedExperiences.last {
                _dismissedExperiences.append(lastPresentation.experienceVersionId)
            }
            _isPresentingExperience = false
            _currentRuntimeDelegate = nil
            _currentExperienceViewController = nil
            _dismissCurrentExperienceCallCount += 1
        }
    }

    /// Configure the mock to fail on next presentation
    public func configureToFail(with error: Error? = nil) {
        lock.withLock {
            _shouldFailPresentation = true
            _presentationError = error ?? ExperiencePresentationError.noActiveScene
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

    /// Get the last presented experience version ID
    public var lastPresentedExperienceVersionId: String? {
        return lock.withLock { _presentedExperiences.last?.experienceVersionId }
    }

    /// Get the last presented journey
    public var lastPresentedJourney: Journey? {
        return lock.withLock { _presentedExperiences.last?.journey }
    }

    /// Check if a specific experience was presented
    public func wasExperiencePresented(_ experienceVersionId: String) -> Bool {
        return lock.withLock { _presentedExperiences.contains { $0.experienceVersionId == experienceVersionId } }
    }

    /// Check if a specific experience was dismissed
    public func wasExperienceDismissed(_ experienceVersionId: String) -> Bool {
        return lock.withLock { _dismissedExperiences.contains(experienceVersionId) }
    }

    /// Get all presented experience version IDs
    public var allPresentedExperienceVersionIds: [String] {
        return lock.withLock { _presentedExperiences.map { $0.experienceVersionId } }
    }

    /// Reset all mock state
    public func reset() {
        lock.withLock {
            _presentedExperiences = []
            _dismissedExperiences = []
            _isPresentingExperience = false
            _shouldFailPresentation = false
            _presentationError = nil
            _presentationDelay = 0
            _presentExperienceCallCount = 0
            _dismissCurrentExperienceCallCount = 0
            _shutdownCurrentExperienceCallCount = 0
            _mockViewControllers = [:]
            _defaultMockViewController = nil
            _currentRuntimeDelegate = nil
            _currentExperienceViewController = nil
        }
    }
}
