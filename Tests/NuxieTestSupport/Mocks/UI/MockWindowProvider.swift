import Foundation
@testable import Nuxie

// MARK: - Mock Window Provider

/// Mock window provider for testing
// @unchecked Sendable: all mutable state is serialized through `lock`.
final class MockWindowProvider: WindowProviderProtocol, @unchecked Sendable {

    private let lock = NSLock()
    private var _canPresent = true
    private var _createdWindows: [MockPresentationWindow] = []
    private var _onWindowLifecycleEvent: ((String) -> Void)?

    // Configuration
    var canPresent: Bool {
        get { lock.withLock { _canPresent } }
        set { lock.withLock { _canPresent = newValue } }
    }
    var createdWindows: [MockPresentationWindow] {
        get { lock.withLock { _createdWindows } }
        set { lock.withLock { _createdWindows = newValue } }
    }
    var onWindowLifecycleEvent: ((String) -> Void)? {
        get { lock.withLock { _onWindowLifecycleEvent } }
        set { lock.withLock { _onWindowLifecycleEvent = newValue } }
    }

    @MainActor
    func canPresentWindow() -> Bool {
        return canPresent
    }

    @MainActor
    func createPresentationWindow() -> PresentationWindowProtocol? {
        guard canPresent else { return nil }

        let window = MockPresentationWindow()
        window.onLifecycleEvent = onWindowLifecycleEvent
        lock.withLock { _createdWindows.append(window) }
        return window
    }

    func reset() {
        lock.withLock {
            _canPresent = true
            _createdWindows.removeAll()
        }
    }

    func simulateNoScene() {
        lock.withLock { _canPresent = false }
    }
}

// MARK: - Mock Presentation Window

/// Mock presentation window for testing
class MockPresentationWindow: PresentationWindowProtocol {
    
    // State tracking
    var presentedViewController: NuxiePlatformViewController?
    var presentCalled = false
    var presentAnimated = false
    var dismissCalled = false
    var dismissAnimated = false
    var destroyCalled = false
    var onLifecycleEvent: ((String) -> Void)?
    
    // Simulate presentation delays
    var presentDelay: TimeInterval = 0
    var dismissDelay: TimeInterval = 0
    
    @MainActor
    func present(_ viewController: NuxiePlatformViewController) async {
        presentCalled = true
        presentAnimated = true
        onLifecycleEvent?("window-present")
        
        if presentDelay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(presentDelay * 1_000_000_000))
        }
        
        presentedViewController = viewController
    }
    
    @MainActor
    func dismiss() async {
        guard presentedViewController != nil else { return }
        
        dismissCalled = true
        dismissAnimated = true
        onLifecycleEvent?("window-dismiss")
        
        if dismissDelay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(dismissDelay * 1_000_000_000))
        }
        
        presentedViewController = nil
    }
    
    @MainActor
    func destroy() {
        destroyCalled = true
        onLifecycleEvent?("window-destroy")
        presentedViewController = nil
    }
    
    @MainActor
    var isPresenting: Bool {
        return presentedViewController != nil
    }
    
    func reset() {
        presentedViewController = nil
        presentCalled = false
        presentAnimated = false
        dismissCalled = false
        dismissAnimated = false
        destroyCalled = false
        presentDelay = 0
        dismissDelay = 0
    }
}
