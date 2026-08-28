import Foundation
@testable import Nuxie

/// Mock implementation of IdentityService for testing.
///
/// Thread safety: EventLog reads identity from nonisolated `track` callers,
/// its capture worker, and enrichment tasks while tests mutate it mid-test
/// (identify/reset scenarios), so every access is lock-guarded.
public final class MockIdentityService: IdentityServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private let distinctIdReadSuspended = DispatchSemaphore(value: 0)
    private let distinctIdReadResume = DispatchSemaphore(value: 0)
    private var _distinctId = "test-user"
    private var _anonymousId = "test-anonymous-id"
    private var _userProperties: [String: Any] = [:]
    private var _isUserIdentified = true
    private var _shouldSuspendNextDistinctIdRead = false
    private var _shouldSuspendNextDistinctIdReadAfterSnapshot = false

    public init() {}

    public func getDistinctId() -> String {
        let read: (shouldSuspend: Bool, snapshot: String?) = lock.withLock {
            if _shouldSuspendNextDistinctIdReadAfterSnapshot {
                _shouldSuspendNextDistinctIdReadAfterSnapshot = false
                return (shouldSuspend: true, snapshot: _distinctId)
            }
            let shouldSuspend = _shouldSuspendNextDistinctIdRead
            _shouldSuspendNextDistinctIdRead = false
            return (shouldSuspend: shouldSuspend, snapshot: nil)
        }
        if read.shouldSuspend {
            distinctIdReadSuspended.signal()
            distinctIdReadResume.wait()
        }
        if let snapshot = read.snapshot { return snapshot }
        return lock.withLock { _distinctId }
    }

    public func suspendNextDistinctIdRead() {
        lock.withLock { _shouldSuspendNextDistinctIdRead = true }
    }

    func suspendNextDistinctIdReadAfterSnapshot() {
        lock.withLock { _shouldSuspendNextDistinctIdReadAfterSnapshot = true }
    }

    public func waitForSuspendedDistinctIdRead() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [distinctIdReadSuspended] in
                distinctIdReadSuspended.wait()
                continuation.resume()
            }
        }
    }

    public func resumeSuspendedDistinctIdRead() {
        distinctIdReadResume.signal()
    }

    public func getRawDistinctId() -> String? {
        lock.withLock { _isUserIdentified ? _distinctId : nil }
    }

    public func getAnonymousId() -> String {
        lock.withLock { _anonymousId }
    }

    public var isIdentified: Bool {
        lock.withLock { _isUserIdentified }
    }

    public func setDistinctId(_ distinctId: String) {
        lock.withLock {
            _distinctId = distinctId
            _isUserIdentified = true
        }
    }

    public func reset(keepAnonymousId: Bool) {
        lock.withLock {
            if !keepAnonymousId {
                _anonymousId = UUID.v7().uuidString
            }
            _distinctId = _anonymousId
            _userProperties.removeAll()
            _isUserIdentified = false
        }
    }

    public func clearUserCache(distinctId: String?) {
        // No-op for tests
    }

    public func getUserProperties() -> [String: Any] {
        lock.withLock { _userProperties }
    }

    public func setUserProperties(_ properties: [String: Any]) {
        lock.withLock {
            for (key, value) in properties {
                _userProperties[key] = value
            }
        }
    }

    @discardableResult
    public func setUserProperties(
        _ properties: [String: Any],
        ifCurrentDistinctIdMatches expectedDistinctId: String
    ) -> Bool {
        lock.withLock {
            guard _distinctId == expectedDistinctId else { return false }
            for (key, value) in properties {
                _userProperties[key] = value
            }
            return true
        }
    }

    public func performIfCurrentDistinctIdMatches<T>(
        _ expectedDistinctId: String,
        _ work: (IdentitySnapshot) throws -> T
    ) rethrows -> T? {
        try lock.withLock {
            guard _distinctId == expectedDistinctId else { return nil }
            return try work(IdentitySnapshot(
                distinctId: _distinctId,
                userId: _isUserIdentified ? _distinctId : nil,
                anonymousId: _anonymousId,
                isIdentified: _isUserIdentified
            ))
        }
    }

    public func setOnceUserProperties(_ properties: [String: Any]) {
        lock.withLock {
            for (key, value) in properties {
                if _userProperties[key] == nil {
                    _userProperties[key] = value
                }
            }
        }
    }

    public func userProperty(for key: String) async -> Any? {
        lock.withLock { _userProperties[key] }
    }

    // Test helpers
    public func reset() {
        reset(keepAnonymousId: false)
        lock.withLock { _userProperties.removeAll() }
    }

    public func setUserProperty(_ key: String, value: Any) {
        lock.withLock { _userProperties[key] = value }
    }

    public func setIsIdentified(_ identified: Bool) {
        lock.withLock { _isUserIdentified = identified }
    }

    public func setAnonymousId(_ id: String) {
        lock.withLock {
            _anonymousId = id
            // If user is not identified, update distinctId to match anonymous ID
            if !_isUserIdentified {
                _distinctId = id
            }
        }
    }
}
