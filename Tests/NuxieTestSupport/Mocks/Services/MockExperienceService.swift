import Foundation
@testable import Nuxie

/// Mock implementation of ExperienceService for testing
// @unchecked Sendable: all mutable state is serialized through `lock` (via withLock).
public final class MockExperienceService: ExperienceServiceProtocol, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var _prefetchedExperiences: [ExperienceReference] = []
    private var _removedExperienceVersionIds: [String] = []
    private var _fetchedExperienceVersionIds: [String] = []
    private var _releaseProfiles: [ExperienceReleaseProfileV1?] = []
    private var _authenticatedReleaseReferences: [ExperienceReference]?
    private var _releaseProfileFailuresRemaining = 0
    private var _releaseProfileAuthenticationGate: ReleaseProfileAuthenticationGate?
    
    // Error testing properties
    private var _shouldFailExperienceDisplay = false
    private var _failureError: Error?
    private var _displayAttempts: [(versionId: String, timestamp: Date)] = []

    private var _mockExperiences: [String: Experience] = [:]
    private var _defaultMockExperience: Experience?
    
    // Property storage for testing
    private var _properties: [String: Any] = [:]
    
    // View controller generation for testing
    private var _mockViewControllers: [String: ExperienceViewController] = [:]
    private var _defaultMockViewController: ExperienceViewController?
    private var _presentationCommitIsValid = true
    private var _presentationCommitValidationResults: [Bool] = []
    private var _presentationCommitIsMemoryWarm = false
    private var _backgroundPreparationPauseCallCount = 0
    private var _foregroundPreparationResumeCallCount = 0
    private var _onAppBecameActiveHandler: (@Sendable () async -> Void)?

    public var prefetchedExperiences: [ExperienceReference] {
        get { withLock { _prefetchedExperiences } }
        set { withLock { _prefetchedExperiences = newValue } }
    }

    public var removedExperienceVersionIds: [String] {
        get { withLock { _removedExperienceVersionIds } }
        set { withLock { _removedExperienceVersionIds = newValue } }
    }

    public var fetchedExperienceVersionIds: [String] {
        get { withLock { _fetchedExperienceVersionIds } }
        set { withLock { _fetchedExperienceVersionIds = newValue } }
    }

    public var releaseProfiles: [ExperienceReleaseProfileV1?] {
        withLock { _releaseProfiles }
    }

    var authenticatedReleaseReferences: [ExperienceReference]? {
        get { withLock { _authenticatedReleaseReferences } }
        set { withLock { _authenticatedReleaseReferences = newValue } }
    }

    var releaseProfileFailuresRemaining: Int {
        get { withLock { _releaseProfileFailuresRemaining } }
        set { withLock { _releaseProfileFailuresRemaining = newValue } }
    }

    var releaseProfileAuthenticationGate: ReleaseProfileAuthenticationGate? {
        get { withLock { _releaseProfileAuthenticationGate } }
        set { withLock { _releaseProfileAuthenticationGate = newValue } }
    }

    public var shouldFailExperienceDisplay: Bool {
        get { withLock { _shouldFailExperienceDisplay } }
        set { withLock { _shouldFailExperienceDisplay = newValue } }
    }

    public var failureError: Error? {
        get { withLock { _failureError } }
        set { withLock { _failureError = newValue } }
    }

    public var displayAttempts: [(versionId: String, timestamp: Date)] {
        get { withLock { _displayAttempts } }
        set { withLock { _displayAttempts = newValue } }
    }

    public var mockExperiences: [String: Experience] {
        get { withLock { _mockExperiences } }
        set { withLock { _mockExperiences = newValue } }
    }

    public var defaultMockExperience: Experience? {
        get { withLock { _defaultMockExperience } }
        set { withLock { _defaultMockExperience = newValue } }
    }

    public var mockViewControllers: [String: ExperienceViewController] {
        get { withLock { _mockViewControllers } }
        set { withLock { _mockViewControllers = newValue } }
    }

    public var defaultMockViewController: ExperienceViewController? {
        get { withLock { _defaultMockViewController } }
        set { withLock { _defaultMockViewController = newValue } }
    }

    var presentationCommitIsValid: Bool {
        get { withLock { _presentationCommitIsValid } }
        set { withLock { _presentationCommitIsValid = newValue } }
    }

    var presentationCommitValidationResults: [Bool] {
        get { withLock { _presentationCommitValidationResults } }
        set { withLock { _presentationCommitValidationResults = newValue } }
    }

    var presentationCommitIsMemoryWarm: Bool {
        get { withLock { _presentationCommitIsMemoryWarm } }
        set { withLock { _presentationCommitIsMemoryWarm = newValue } }
    }

    var backgroundPreparationPauseCallCount: Int {
        withLock { _backgroundPreparationPauseCallCount }
    }

    var foregroundPreparationResumeCallCount: Int {
        withLock { _foregroundPreparationResumeCallCount }
    }

    var onAppBecameActiveHandler: (@Sendable () async -> Void)? {
        get { withLock { _onAppBecameActiveHandler } }
        set { withLock { _onAppBecameActiveHandler = newValue } }
    }

    public func onAppDidEnterBackground() async {
        withLock { _backgroundPreparationPauseCallCount += 1 }
    }

    public func onAppBecameActive() async {
        let handler = withLock {
            _foregroundPreparationResumeCallCount += 1
            return _onAppBecameActiveHandler
        }
        await handler?()
    }

    public func validatesPresentationCommit(
        _ commit: JourneyPendingPresentation
    ) async -> Bool {
        _ = commit
        return withLock {
            if !_presentationCommitValidationResults.isEmpty {
                return _presentationCommitValidationResults.removeFirst()
            }
            return _presentationCommitIsValid
        }
    }

    public func isPresentationMemoryWarm(
        _ commit: JourneyPendingPresentation
    ) async -> Bool {
        _ = commit
        return withLock { _presentationCommitIsMemoryWarm }
    }

    public func isPresentationMemoryWarm(
        for experience: Experience
    ) async -> Bool {
        _ = experience
        return withLock { _presentationCommitIsMemoryWarm }
    }

    public func reserveMemoryWarmPresentation(
        for experience: Experience
    ) async -> ExperiencePresentationWarmReservation? {
        _ = experience
        guard withLock({ _presentationCommitIsMemoryWarm }) else { return nil }
        return ExperiencePresentationWarmReservation(release: {})
    }
    
    public func replaceReleaseProfile(
        _ profile: ExperienceReleaseProfileV1?
    ) async throws -> [ExperienceReference]? {
        withLock { _releaseProfiles.append(profile) }
        if profile != nil {
            let shouldFail = withLock { () -> Bool in
                guard _releaseProfileFailuresRemaining > 0 else { return false }
                _releaseProfileFailuresRemaining -= 1
                return true
            }
            let gate = withLock { _releaseProfileAuthenticationGate }
            await gate?.suspendFirstAuthentication()
            if shouldFail {
                throw NuxieError.invalidConfiguration(
                    "test cached release authentication failure"
                )
            }
        }
        guard let profile else { return nil }
        if let configured = withLock({ _authenticatedReleaseReferences }) {
            return configured
        }
        return (profile.active + profile.pinned).map {
            ExperienceReference(
                experienceId: $0.locator.experienceId,
                versionId: $0.locator.experienceVersionId
            )
        }
    }

    public func removeExperiences(_ versionIds: [String]) async {
        withLock {
            _removedExperienceVersionIds.append(contentsOf: versionIds)
        }
    }

    public func fetchExperience(id: String) async throws -> Experience {
        return try withLock {
            _fetchedExperienceVersionIds.append(id)

            if let experience = _mockExperiences[id] {
                return experience
            }
            if let experience = _defaultMockExperience {
                return experience
            }
            if let error = _failureError {
                throw error
            }
            throw MockExperienceServiceError.experienceNotFound(id)
        }
    }

    public func fetchExperience(
        experienceId: String,
        versionId: String
    ) async throws -> Experience {
        try await fetchExperience(id: versionId)
    }
    
    @MainActor
    public func viewController(for versionId: String) async throws -> ExperienceViewController {
        let (shouldFail, failure, mockVC, defaultVC): (Bool, Error?, ExperienceViewController?, ExperienceViewController?) =
            withLock {
                _displayAttempts.append((versionId: versionId, timestamp: Date()))
                return (
                    _shouldFailExperienceDisplay, _failureError, _mockViewControllers[versionId],
                    _defaultMockViewController
                )
            }

        if shouldFail {
            throw failure ?? MockExperienceServiceError.experienceNotFound(versionId)
        }

        if let mockVC {
            return mockVC
        }

        if let defaultVC {
            return defaultVC
        }

        // Create a basic mock view controller
        return MockExperienceViewController(mockExperienceVersionId: versionId)
    }

    @MainActor
    public func viewController(
        for versionId: String,
        colorSchemeMode: ExperienceColorSchemeMode
    ) async throws -> ExperienceViewController {
        let controller = try await viewController(for: versionId)
        controller.colorSchemeMode = colorSchemeMode
        return controller
    }

    @MainActor
    public func viewController(
        for versionId: String,
        runtimeDelegate: ExperienceRuntimeDelegate?,
        colorSchemeMode: ExperienceColorSchemeMode,
        presentationTraceContext: ExperiencePresentationTraceContext?,
        initialScreenID: String?
    ) async throws -> ExperienceViewController {
        let controller = try await viewController(
            for: versionId,
            runtimeDelegate: runtimeDelegate,
            colorSchemeMode: colorSchemeMode
        )
        controller.presentationTraceContext = presentationTraceContext
        _ = initialScreenID
        return controller
    }

    @MainActor
    public func viewController(for versionId: String, runtimeDelegate: ExperienceRuntimeDelegate?) async throws -> ExperienceViewController {
        let controller = try await viewController(for: versionId)
        controller.runtimeDelegate = runtimeDelegate
        return controller
    }

    @MainActor
    public func viewController(
        for versionId: String,
        runtimeDelegate: ExperienceRuntimeDelegate?,
        colorSchemeMode: ExperienceColorSchemeMode
    ) async throws -> ExperienceViewController {
        let controller = try await viewController(
            for: versionId,
            colorSchemeMode: colorSchemeMode
        )
        controller.runtimeDelegate = runtimeDelegate
        return controller
    }
    
    public func clearCache() async {
        withLock {
            _prefetchedExperiences = []
            _removedExperienceVersionIds = []
        }
    }
    
    public func reset() {
        withLock {
            _prefetchedExperiences = []
            _removedExperienceVersionIds = []
            _fetchedExperienceVersionIds = []
            _releaseProfiles = []
            _authenticatedReleaseReferences = nil
            _releaseProfileFailuresRemaining = 0
            _releaseProfileAuthenticationGate = nil
            _shouldFailExperienceDisplay = false
            _failureError = nil
            _displayAttempts = []
            _properties = [:]
            _mockViewControllers = [:]
            _defaultMockViewController = nil
            _mockExperiences = [:]
            _defaultMockExperience = nil
            _presentationCommitIsValid = true
            _presentationCommitValidationResults = []
            _backgroundPreparationPauseCallCount = 0
            _foregroundPreparationResumeCallCount = 0
        }
    }
    
    // Property storage methods for testing
    public func getProperty(_ key: String) -> Any? {
        return withLock { _properties[key] }
    }
    
    public func setProperty(_ key: String, value: Any?) {
        withLock {
            _properties[key] = value
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

actor ReleaseProfileAuthenticationGate {
    private var didSuspend = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    func suspendFirstAuthentication() async {
        guard !didSuspend else { return }
        didSuspend = true
        startedWaiters.forEach { $0.resume() }
        startedWaiters.removeAll()
        await withCheckedContinuation { resumeContinuation = $0 }
    }

    func waitUntilSuspended() async {
        guard !didSuspend else { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func resume() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}

public enum MockExperienceServiceError: Error {
    case experienceNotFound(String)
    case presentationFailed(String)
}
