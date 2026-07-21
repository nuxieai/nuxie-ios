import Foundation
@testable import Nuxie

/// Mock implementation of ExperienceService for testing
public class MockExperienceService: ExperienceServiceProtocol {
    private let lock = NSRecursiveLock()
    private var _prefetchedFlows: [RemoteFlow] = []
    private var _removedFlowIds: [String] = []
    private var _fetchedFlowIds: [String] = []
    
    // Error testing properties
    private var _shouldFailFlowDisplay = false
    private var _failureError: Error?
    private var _displayAttempts: [(flowId: String, timestamp: Date)] = []

    private var _mockFlows: [String: Experience] = [:]
    private var _defaultMockFlow: Experience?
    
    // Property storage for testing
    private var _properties: [String: Any] = [:]
    
    // View controller generation for testing
    private var _mockViewControllers: [String: ExperienceViewController] = [:]
    private var _defaultMockViewController: ExperienceViewController?

    public var prefetchedFlows: [RemoteFlow] {
        get { withLock { _prefetchedFlows } }
        set { withLock { _prefetchedFlows = newValue } }
    }

    public var removedFlowIds: [String] {
        get { withLock { _removedFlowIds } }
        set { withLock { _removedFlowIds = newValue } }
    }

    public var fetchedFlowIds: [String] {
        get { withLock { _fetchedFlowIds } }
        set { withLock { _fetchedFlowIds = newValue } }
    }

    public var shouldFailFlowDisplay: Bool {
        get { withLock { _shouldFailFlowDisplay } }
        set { withLock { _shouldFailFlowDisplay = newValue } }
    }

    public var failureError: Error? {
        get { withLock { _failureError } }
        set { withLock { _failureError = newValue } }
    }

    public var displayAttempts: [(flowId: String, timestamp: Date)] {
        get { withLock { _displayAttempts } }
        set { withLock { _displayAttempts = newValue } }
    }

    public var mockExperiences: [String: Experience] {
        get { withLock { _mockFlows } }
        set { withLock { _mockFlows = newValue } }
    }

    public var defaultMockFlow: Experience? {
        get { withLock { _defaultMockFlow } }
        set { withLock { _defaultMockFlow = newValue } }
    }

    public var mockViewControllers: [String: ExperienceViewController] {
        get { withLock { _mockViewControllers } }
        set { withLock { _mockViewControllers = newValue } }
    }

    public var defaultMockViewController: ExperienceViewController? {
        get { withLock { _defaultMockViewController } }
        set { withLock { _defaultMockViewController = newValue } }
    }
    
    public func prefetchFlows(_ remoteFlows: [RemoteFlow]) {
        withLock {
            _prefetchedFlows.append(contentsOf: remoteFlows)
        }
    }
    
    public func removeFlows(_ flowIds: [String]) async {
        withLock {
            _removedFlowIds.append(contentsOf: flowIds)
        }
    }

    public func fetchExperience(id: String) async throws -> Experience {
        lock.lock()
        defer { lock.unlock() }

        _fetchedFlowIds.append(id)

        if let flow = _mockFlows[id] {
            return flow
        }
        if let flow = _defaultMockFlow {
            return flow
        }
        if let error = _failureError {
            throw error
        }
        throw MockFlowServiceError.flowNotFound(id)
    }
    
    @MainActor
    public func viewController(for flowId: String) async throws -> ExperienceViewController {
        lock.lock()
        defer { lock.unlock() }

        _displayAttempts.append((flowId: flowId, timestamp: Date()))
        
        if _shouldFailFlowDisplay {
            throw _failureError ?? MockFlowServiceError.flowNotFound(flowId)
        }
        
        if let mockVC = _mockViewControllers[flowId] {
            return mockVC
        }
        
        if let defaultVC = _defaultMockViewController {
            return defaultVC
        }
        
        // Create a basic mock view controller
        return MockFlowViewController(mockFlowId: flowId)
    }

    @MainActor
    public func viewController(
        for flowId: String,
        colorSchemeMode: ExperienceColorSchemeMode
    ) async throws -> ExperienceViewController {
        let controller = try await viewController(for: flowId)
        controller.colorSchemeMode = colorSchemeMode
        return controller
    }

    @MainActor
    public func viewController(for flowId: String, runtimeDelegate: FlowRuntimeDelegate?) async throws -> ExperienceViewController {
        let controller = try await viewController(for: flowId)
        controller.runtimeDelegate = runtimeDelegate
        return controller
    }

    @MainActor
    public func viewController(
        for flowId: String,
        runtimeDelegate: FlowRuntimeDelegate?,
        colorSchemeMode: ExperienceColorSchemeMode
    ) async throws -> ExperienceViewController {
        let controller = try await viewController(
            for: flowId,
            colorSchemeMode: colorSchemeMode
        )
        controller.runtimeDelegate = runtimeDelegate
        return controller
    }
    
    public func clearCache() async {
        withLock {
            _prefetchedFlows = []
            _removedFlowIds = []
        }
    }
    
    public func reset() {
        withLock {
            _prefetchedFlows = []
            _removedFlowIds = []
            _fetchedFlowIds = []
            _shouldFailFlowDisplay = false
            _failureError = nil
            _displayAttempts = []
            _properties = [:]
            _mockViewControllers = [:]
            _defaultMockViewController = nil
            _mockFlows = [:]
            _defaultMockFlow = nil
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

public enum MockFlowServiceError: Error {
    case flowNotFound(String)
    case presentationFailed(String)
}
