import Foundation
@testable import Nuxie

/// Mock implementation of ExperienceService for testing
// @unchecked Sendable: all mutable state is serialized through `lock` (via withLock).
final class MockExperienceService: ExperienceServiceProtocol, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var _prefetchedExperiences: [ExperienceReference] = []
    private var _removedExperienceVersionIds: [String] = []
    private var _fetchedExperienceVersionIds: [String] = []
    private var _releaseProfiles: [ExperienceReleaseProfile?] = []
    private var _committedReleaseProfiles: [ExperienceReleaseProfile?] = []
    private var _committedDeviceLegReleaseCounts: [Int?] = []
    private var _latestProfileGeneration: UInt64 = 0
    private var _authenticatedReleaseReferences: [ExperienceReference]?
    private var _releaseProfileFailuresRemaining = 0
    private var _deviceLegArtifactPreparationFailuresRemaining = 0
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
    private var _viewControllerHandler: (@Sendable () async -> Void)?
    private var _productAuthorityResolution: ActiveProductEvidenceAuthorityResolution = .unavailable
    private var _deliverProductAuthorityOnHandlerRegistration = false
    private var _optimisticAllowancesByStoreProductId:
        [String: [OptimisticEntitlementAllowance]] = [:]

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

    public var releaseProfiles: [ExperienceReleaseProfile?] {
        withLock { _releaseProfiles }
    }

    public var committedReleaseProfiles: [ExperienceReleaseProfile?] {
        withLock { _committedReleaseProfiles }
    }

    var committedDeviceLegReleaseCounts: [Int?] {
        withLock { _committedDeviceLegReleaseCounts }
    }

    var authenticatedReleaseReferences: [ExperienceReference]? {
        get { withLock { _authenticatedReleaseReferences } }
        set { withLock { _authenticatedReleaseReferences = newValue } }
    }

    var releaseProfileFailuresRemaining: Int {
        get { withLock { _releaseProfileFailuresRemaining } }
        set { withLock { _releaseProfileFailuresRemaining = newValue } }
    }

    var deviceLegArtifactPreparationFailuresRemaining: Int {
        get { withLock { _deviceLegArtifactPreparationFailuresRemaining } }
        set { withLock { _deviceLegArtifactPreparationFailuresRemaining = newValue } }
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

    var mockExperiences: [String: Experience] {
        get { withLock { _mockExperiences } }
        set { withLock { _mockExperiences = newValue } }
    }

    var defaultMockExperience: Experience? {
        get { withLock { _defaultMockExperience } }
        set { withLock { _defaultMockExperience = newValue } }
    }

    var mockViewControllers: [String: ExperienceViewController] {
        get { withLock { _mockViewControllers } }
        set { withLock { _mockViewControllers = newValue } }
    }

    var defaultMockViewController: ExperienceViewController? {
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

    var optimisticAllowancesByStoreProductId:
        [String: [OptimisticEntitlementAllowance]] {
        get { withLock { _optimisticAllowancesByStoreProductId } }
        set { withLock { _optimisticAllowancesByStoreProductId = newValue } }
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

    var viewControllerHandler: (@Sendable () async -> Void)? {
        get { withLock { _viewControllerHandler } }
        set { withLock { _viewControllerHandler = newValue } }
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

    func configureEagerProductAuthorityAdmission(
        _ resolution: ActiveProductEvidenceAuthorityResolution
    ) {
        withLock {
            _productAuthorityResolution = resolution
            _deliverProductAuthorityOnHandlerRegistration = true
        }
    }

    public func purchaseEvidenceAuthority(
        storeProductId: String
    ) async -> ActiveProductEvidenceAuthorityResolution {
        _ = storeProductId
        return withLock { _productAuthorityResolution }
    }

    func optimisticEntitlementAllowances(
        releaseDescriptorSHA256: String?,
        productId: String?,
        storeProductId: String
    ) async -> [OptimisticEntitlementAllowance]? {
        _ = releaseDescriptorSHA256
        _ = productId
        return withLock { _optimisticAllowancesByStoreProductId[storeProductId] }
    }

    public func setProductAuthorityChangeHandler(
        _ handler: @escaping @Sendable () async -> Void
    ) {
        guard withLock({ _deliverProductAuthorityOnHandlerRegistration }) else { return }
        let delivered = DispatchSemaphore(value: 0)
        Task.detached {
            await handler()
            delivered.signal()
        }
        _ = delivered.wait(timeout: .now() + 1)
        // Model eager disk admission delivering its pending notification
        // before the composition root returns from registration.
        Thread.sleep(forTimeInterval: 0.05)
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
    
    public func prepareReleaseProfile(
        _ profile: ExperienceReleaseProfile?,
        deviceLegSnapshot: DeviceLegProfileCatalog.Snapshot?
    ) async throws -> PreparedExperienceReleaseProfile {
        withLock { _releaseProfiles.append(profile) }
        if deviceLegSnapshot != nil {
            let shouldFail = withLock { () -> Bool in
                guard _deviceLegArtifactPreparationFailuresRemaining > 0 else {
                    return false
                }
                _deviceLegArtifactPreparationFailuresRemaining -= 1
                return true
            }
            if shouldFail {
                throw URLError(.notConnectedToInternet)
            }
        }
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
        guard let profile else {
            return PreparedExperienceReleaseProfile(
                profile: nil,
                catalog: nil,
                deviceLegSnapshot: deviceLegSnapshot
            )
        }
        if let configured = withLock({ _authenticatedReleaseReferences }) {
            return PreparedExperienceReleaseProfile(
                profile: profile,
                catalog: nil,
                references: configured,
                deviceLegSnapshot: deviceLegSnapshot
            )
        }
        let references = (profile.active + profile.pinned).map {
            ExperienceReference(
                experienceId: $0.locator.experienceId,
                versionId: $0.locator.experienceVersionId
            )
        }
        return PreparedExperienceReleaseProfile(
            profile: profile,
            catalog: nil,
            references: references,
            deviceLegSnapshot: deviceLegSnapshot
        )
    }

    public func commitReleaseProfile(
        _ prepared: PreparedExperienceReleaseProfile,
        generation: UInt64
    ) async throws -> ExperienceRoutingCatalog? {
        let committed = withLock { () -> (
            references: [ExperienceReference],
            experiences: [String: Experience],
            fallback: Experience?
        )? in
            guard generation >= _latestProfileGeneration else { return nil }
            _latestProfileGeneration = generation
            _committedReleaseProfiles.append(prepared.profile)
            _committedDeviceLegReleaseCounts.append(
                prepared.deviceLegSnapshot?.releasesByDigest.count
            )
            return (
                prepared.references ?? [],
                _mockExperiences,
                _defaultMockExperience
            )
        }
        guard let committed else { return nil }
        return ExperienceRoutingCatalog(
            generation: generation,
            references: committed.references
        ) { experienceId, versionId in
            if let experience = committed.experiences[versionId],
               experience.id == experienceId {
                return experience
            }
            if let fallback = committed.fallback,
               fallback.id == experienceId,
               fallback.versionId == versionId {
                return fallback
            }
            throw MockExperienceServiceError.experienceNotFound(versionId)
        }
    }

    public func replaceReleaseProfile(
        _ profile: ExperienceReleaseProfile?
    ) async throws -> [ExperienceReference]? {
        let prepared = try await prepareReleaseProfile(profile)
        let committed = try await commitReleaseProfile(prepared, generation: 0)
        return profile == nil ? nil : committed?.references
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
    func viewController(for versionId: String) async throws -> ExperienceViewController {
        let (shouldFail, failure, mockVC, defaultVC, handler): (
            Bool,
            Error?,
            ExperienceViewController?,
            ExperienceViewController?,
            (@Sendable () async -> Void)?
        ) =
            withLock {
                _displayAttempts.append((versionId: versionId, timestamp: Date()))
                return (
                    _shouldFailExperienceDisplay, _failureError, _mockViewControllers[versionId],
                    _defaultMockViewController, _viewControllerHandler
                )
            }

        await handler?()

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
    func viewController(
        for versionId: String,
        colorSchemeMode: ExperienceColorSchemeMode
    ) async throws -> ExperienceViewController {
        let controller = try await viewController(for: versionId)
        controller.colorSchemeMode = colorSchemeMode
        return controller
    }

    @MainActor
    func viewController(
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
    func viewController(for versionId: String, runtimeDelegate: ExperienceRuntimeDelegate?) async throws -> ExperienceViewController {
        let controller = try await viewController(for: versionId)
        controller.runtimeDelegate = runtimeDelegate
        return controller
    }

    @MainActor
    func viewController(
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

    @MainActor
    func viewController(
        forDeviceLeg release: AuthenticatedDeviceLegRelease,
        delivery: ExperienceReleaseDelivery,
        runtimeDelegate: ExperienceRuntimeDelegate?,
        colorSchemeMode: ExperienceColorSchemeMode
    ) async throws -> ExperienceViewController {
        _ = delivery
        return try await viewController(
            for: release.descriptor.identity.experienceVersionId,
            runtimeDelegate: runtimeDelegate,
            colorSchemeMode: colorSchemeMode
        )
    }
    
    public func clearCache() async {
        withLock {
            _prefetchedExperiences = []
            _removedExperienceVersionIds = []
            _releaseProfiles.append(nil)
        }
    }
    
    public func reset() {
        withLock {
            _prefetchedExperiences = []
            _removedExperienceVersionIds = []
            _fetchedExperienceVersionIds = []
            _releaseProfiles = []
            _committedReleaseProfiles = []
            _latestProfileGeneration = 0
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
            _viewControllerHandler = nil
            _productAuthorityResolution = .unavailable
            _optimisticAllowancesByStoreProductId = [:]
            _deliverProductAuthorityOnHandlerRegistration = false
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
