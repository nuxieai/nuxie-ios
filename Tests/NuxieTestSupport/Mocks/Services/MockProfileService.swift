import Foundation
@testable import Nuxie

/// Mock implementation of ProfileService for testing.
///
/// Thread safety: committed-event subscriptions and trigger tasks read this
/// mock from background executors while teardown/reset mutates it — every
/// state access is lock-guarded (an unsynchronized dictionary here was the
/// CI-only segfault caught by the Swift backtracer at getCachedProfile).
public final class MockProfileService: ProfileServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _profileResponse: ProfileResponse?
    private var _shouldThrow = false
    private var _fetchCallCount = 0
    private var _cache: [String: ProfileResponse] = [:]
    private var _journeyMailboxHandler:
        (@Sendable ([JourneyMailboxEntry], String) async -> Void)?

    public var profileResponse: ProfileResponse? {
        get { lock.withLock { _profileResponse } }
        set { lock.withLock { _profileResponse = newValue } }
    }
    public var shouldThrow: Bool {
        get { lock.withLock { _shouldThrow } }
        set { lock.withLock { _shouldThrow = newValue } }
    }
    public var fetchCallCount: Int {
        get { lock.withLock { _fetchCallCount } }
        set { lock.withLock { _fetchCallCount = newValue } }
    }

    public init() {
        setupDefaultProfileResponse()
    }
    
    private func setupDefaultProfileResponse() {
        let segment = Segment(
            id: "segment-1",
            name: "Test Segment",
            condition: IREnvelope(
                ir_version: 1,
                engine_min: nil,
                compiled_at: nil,
                expr: .bool(true)  // Simple test expression
            )
        )
        
        self.profileResponse = ProfileResponse(
            segments: [segment],
            userProperties: nil,
            experiments: nil,
            features: nil
        )
    }
    
    public func refetchProfile(distinctId: String?) async throws -> ProfileResponse {
        let distinctId = distinctId ?? "mock-user"
        let response = try lock.withLock {
            _fetchCallCount += 1

            if _shouldThrow {
                throw NSError(domain: "TestError", code: 3, userInfo: [NSLocalizedDescriptionKey: "Mock profile fetch error"])
            }

            guard let response = _profileResponse else {
                throw NSError(domain: "TestError", code: 4, userInfo: [NSLocalizedDescriptionKey: "No mock profile configured"])
            }

            _cache[distinctId] = response
            return response
        }
        if let mailbox = response.mailbox {
            let handler = lock.withLock { _journeyMailboxHandler }
            await handler?(mailbox, distinctId)
        }
        return response
    }

    public func getCachedProfile(distinctId: String) async -> ProfileResponse? {
        lock.withLock { _cache[distinctId] }
    }

    public func clearCache(distinctId: String) async {
        lock.withLock { _ = _cache.removeValue(forKey: distinctId) }
    }

    public func clearAllCache() async {
        lock.withLock { _cache.removeAll() }
    }

    public func cleanupExpired() async -> Int {
        lock.withLock {
            let count = _cache.count
            _cache.removeAll()
            return count
        }
    }
    
    
    
    public func handleUserChange(from oldDistinctId: String, to newDistinctId: String) async {
        // Clear cache for old user
        lock.withLock { _ = _cache.removeValue(forKey: oldDistinctId) }
        // No-op for other aspects in mock
    }
    
    public func onAppBecameActive() async {
        // Mock implementation - no-op for tests
    }

    public func setJourneyMailboxHandler(
        _ handler: (@Sendable ([JourneyMailboxEntry], String) async -> Void)?
    ) async {
        lock.withLock {
            _journeyMailboxHandler = handler
        }
    }
    
    // Test helpers
    public func reset() {
        setupDefaultProfileResponse()
        lock.withLock {
            _shouldThrow = false
            _fetchCallCount = 0
            _cache.removeAll()
            _journeyMailboxHandler = nil
        }
    }
    
    // Retained for call-site compatibility; signed release fixtures are set
    // through setProfileResponse.
    public func setExperiences(_ experiences: [Experience]) {
        _ = experiences
    }
    
    public func setProfileResponse(_ response: ProfileResponse) {
        profileResponse = response
    }
}
