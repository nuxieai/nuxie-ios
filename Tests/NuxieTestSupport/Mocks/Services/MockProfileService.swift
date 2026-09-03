import Foundation
@testable import Nuxie

public final class MockProfileService: ProfileServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var profileResponse = TestJourneyProfile.response()
    private var cache: [String: ProfileResponse] = [:]
    private var activeHandler: (@Sendable () async -> Void)?

    public var shouldThrow = false
    public var fetchCallCount = 0

    public init() {}

    public func refetchProfile(
        distinctId: String?
    ) async throws -> ProfileResponse {
        try lock.withLock {
            fetchCallCount += 1
            if shouldThrow {
                throw NSError(
                    domain: "MockProfileService",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Mock profile fetch error"]
                )
            }
            let distinctId = distinctId ?? "mock-user"
            cache[distinctId] = profileResponse
            return profileResponse
        }
    }

    public func localeDidChange() async {}

    public func getCachedProfile(
        distinctId: String
    ) async -> ProfileResponse? {
        lock.withLock { cache[distinctId] }
    }

    public func clearCache(distinctId: String) async {
        _ = lock.withLock { cache.removeValue(forKey: distinctId) }
    }

    public func clearAllCache() async {
        lock.withLock { cache.removeAll() }
    }

    public func cleanupExpired() async -> Int { 0 }

    public func handleUserChange(
        from oldDistinctId: String,
        to newDistinctId: String
    ) async {
        _ = lock.withLock { cache.removeValue(forKey: oldDistinctId) }
        _ = newDistinctId
    }

    public func onAppBecameActive() async {
        let handler = lock.withLock { activeHandler }
        await handler?()
    }

    func setProfileResponse(_ response: ProfileResponse) {
        lock.withLock { profileResponse = response }
    }

    func setOnAppBecameActive(
        _ handler: (@Sendable () async -> Void)?
    ) {
        lock.withLock { activeHandler = handler }
    }

    public func reset() {
        lock.withLock {
            profileResponse = TestJourneyProfile.response()
            cache.removeAll()
            activeHandler = nil
            shouldThrow = false
            fetchCallCount = 0
        }
    }
}
