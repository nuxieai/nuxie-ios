import Foundation
import NuxieRuntime
@testable import Nuxie

/// Mock implementation of ExperienceService for testing
// @unchecked Sendable: all mutable state is serialized through `lock` (via withLock).
public final class MockExperienceService: ExperienceServiceProtocol, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var _prefetchedExperiences: [RemoteExperience] = []
    private var _removedExperienceVersionIds: [String] = []
    private var _fetchedExperienceVersionIds: [String] = []
    
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

    public var prefetchedExperiences: [RemoteExperience] {
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
    
    public func prefetchExperiences(
        _ remotes: [RemoteExperience],
        assetBaseURL: String
    ) async {
        withLock {
            _prefetchedExperiences.append(contentsOf: remotes)
        }
    }

    public func registerExperiences(
        _ remotes: [RemoteExperience],
        assetBaseURL: String
    ) async {
        _ = remotes
        _ = assetBaseURL
    }

    public func removeExperiences(_ versionIds: [String]) async {
        withLock {
            _removedExperienceVersionIds.append(contentsOf: versionIds)
        }
    }

    public func retainPackages(for remotes: [RemoteExperience]) async {}

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
            _shouldFailExperienceDisplay = false
            _failureError = nil
            _displayAttempts = []
            _properties = [:]
            _mockViewControllers = [:]
            _defaultMockViewController = nil
            _mockExperiences = [:]
            _defaultMockExperience = nil
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

public enum MockExperienceServiceError: Error {
    case experienceNotFound(String)
    case presentationFailed(String)
}
