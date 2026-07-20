import Foundation
@testable import Nuxie

// MARK: - Mock Window Provider

/// Mock window provider for testing
class MockWindowProvider: WindowProviderProtocol {
    
    // Configuration
    var canPresent = true
    var createdWindows: [MockPresentationWindow] = []
    var onWindowLifecycleEvent: ((String) -> Void)?
    
    @MainActor
    func canPresentWindow() -> Bool {
        return canPresent
    }
    
    @MainActor
    func createPresentationWindow() -> PresentationWindowProtocol? {
        guard canPresent else { return nil }
        
        let window = MockPresentationWindow()
        window.onLifecycleEvent = onWindowLifecycleEvent
        createdWindows.append(window)
        return window
    }
    
    func reset() {
        canPresent = true
        createdWindows.removeAll()
    }
    
    func simulateNoScene() {
        canPresent = false
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
