import Foundation
@testable import Nuxie

/// Mock implementation of IdentityService for testing.
///
/// Thread safety: EventLog reads identity from nonisolated `track` callers,
/// its capture worker, and enrichment tasks while tests mutate it mid-test
/// (identify/reset scenarios), so every access is lock-guarded.
public final class MockIdentityService: IdentityServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _distinctId = "test-user"
    private var _anonymousId = "test-anonymous-id"
    private var _userProperties: [String: Any] = [:]
    private var _isUserIdentified = true

    public init() {}

    public func getDistinctId() -> String {
        lock.withLock { _distinctId }
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
