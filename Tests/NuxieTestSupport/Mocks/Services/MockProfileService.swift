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
        // Create default profile response matching MockNuxieApi
        let campaign = Campaign(
            id: "campaign-1",
            name: "Test Campaign",
            flowId: "flow-1",
            flowNumber: 1,
            flowName: nil,
            reentry: .everyTime,
            publishedAt: "2024-01-01T00:00:00Z",
            trigger: .event(EventTriggerConfig(
                eventName: "test_event",
                condition: IREnvelope(
                    ir_version: 1,
                    engine_min: nil,
                    compiled_at: nil,
                    expr: .bool(true)
                )
            )),
            goal: nil,
            exitPolicy: nil,
            conversionAnchor: nil,
            campaignType: nil
        )
        
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
            campaigns: [campaign],
            segments: [segment],
            flows: [ResponseBuilders.buildRemoteFlow()],
            userProperties: nil,
            experiments: nil,
            features: nil,
            journeys: nil
        )
    }
    
    public func refetchProfile(distinctId: String?) async throws -> ProfileResponse {
        let distinctId = distinctId ?? "mock-user"
        return try lock.withLock {
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
    
    // Test helpers
    public func reset() {
        setupDefaultProfileResponse()
        lock.withLock {
            _shouldThrow = false
            _fetchCallCount = 0
            _cache.removeAll()
        }
    }
    
    // Test helper method to set campaigns
    public func setCampaigns(_ campaigns: [Campaign]) {
        guard let response = profileResponse else { return }
        profileResponse = ProfileResponse(
            campaigns: campaigns,
            segments: response.segments,
            flows: response.flows,
            userProperties: response.userProperties,
            experiments: response.experiments,
            features: response.features,
            journeys: response.journeys
        )
    }
    
    public func setProfileResponse(_ response: ProfileResponse) {
        profileResponse = response
    }
}
