import Foundation
@testable import Nuxie

/// Mock implementation of SessionService for testing
public class MockSessionService: SessionServiceProtocol {
    // MARK: - Properties

    private var currentSessionId: String?
    private var isInBackground: Bool = false
    private let lock = NSLock()

    // MARK: - Call Tracking

    public private(set) var getSessionIdCallCount = 0
    public private(set) var startSessionCallCount = 0
    public private(set) var endSessionCallCount = 0
    public private(set) var resetSessionCallCount = 0
    public private(set) var touchSessionCallCount = 0
    public private(set) var onAppDidEnterBackgroundCallCount = 0
    public private(set) var onAppBecameActiveCallCount = 0

    // MARK: - State Tracking

    public private(set) var lastGetSessionIdDate: Date?
    public private(set) var lastGetSessionIdReadOnly: Bool?

    // MARK: - Initialization

    public init() {}

    // MARK: - SessionServiceProtocol

    public func getSessionId(at date: Date, readOnly: Bool) -> String? {
        lock.lock()
        defer { lock.unlock() }

        getSessionIdCallCount += 1
        lastGetSessionIdDate = date
        lastGetSessionIdReadOnly = readOnly

        if currentSessionId == nil && !readOnly {
            currentSessionId = UUID.v7().uuidString
        }

        return currentSessionId
    }


    public func setSessionId(_ sessionId: String) {
        lock.lock()
        defer { lock.unlock() }

        currentSessionId = sessionId
    }

    public func startSession() {
        lock.lock()
        defer { lock.unlock() }

        startSessionCallCount += 1
        currentSessionId = UUID.v7().uuidString
    }

    public func endSession() {
        lock.lock()
        defer { lock.unlock() }

        endSessionCallCount += 1
        currentSessionId = nil
    }

    public func resetSession() {
        lock.lock()
        defer { lock.unlock() }

        resetSessionCallCount += 1
        currentSessionId = UUID.v7().uuidString
    }

    public func touchSession() {
        lock.lock()
        defer { lock.unlock() }

        touchSessionCallCount += 1
    }

    public func onAppDidEnterBackground() {
        lock.lock()
        defer { lock.unlock() }

        onAppDidEnterBackgroundCallCount += 1
        isInBackground = true
    }

    public func onAppBecameActive() {
        lock.lock()
        defer { lock.unlock() }

        onAppBecameActiveCallCount += 1
        isInBackground = false
    }

    // MARK: - Test Helpers

    public func reset() {
        lock.lock()
        defer { lock.unlock() }

        currentSessionId = nil
        isInBackground = false
        getSessionIdCallCount = 0
        startSessionCallCount = 0
        endSessionCallCount = 0
        resetSessionCallCount = 0
        touchSessionCallCount = 0
        onAppDidEnterBackgroundCallCount = 0
        onAppBecameActiveCallCount = 0
        lastGetSessionIdDate = nil
        lastGetSessionIdReadOnly = nil
    }

    public func setCurrentSessionId(_ sessionId: String?) {
        lock.lock()
        defer { lock.unlock() }

        currentSessionId = sessionId
    }

    public func getCurrentSessionId() -> String? {
        lock.lock()
        defer { lock.unlock() }

        return currentSessionId
    }

    public func getIsInBackground() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        return isInBackground
    }
}
