import XCTest
@testable import Nuxie
@testable import NuxieTestSupport

private final class ReadinessEventMigration: EventIdentityMigrating {
    func reassignEvents(from: String, to: String) async throws -> Int { 0 }
}

private actor ReadinessFeatureCheck: FeatureChecking {
    func checkFeature(customerId: String, featureId: String, requiredBalance: Double?, entityId: String?) async throws -> FeatureCheckResult {
        throw NuxieNetworkError.invalidResponse
    }
}

@MainActor
final class FeatureIdentityReadinessTests: XCTestCase {
    func testResetAndReidentifyAdmitCurrentCustomerProfile() async {
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let profile = MockProfileService()
        let info = FeatureInfo()
        let features = FeatureService(api: ReadinessFeatureCheck(), identity: identity,
            profile: profile, dateProvider: MockDateProvider(), featureInfo: info, cacheTTL: 300)
        let transitions = UserTransitionCoordinator(profile: profile,
            eventLog: ReadinessEventMigration(), features: features, experiences: MockExperienceService())
        _ = try? await profile.refetchProfile(distinctId: "customer")
        await features.syncFeatureInfo()
        XCTAssertEqual(info.state, .ready)

        identity.setDistinctId("anonymous")
        transitions.enqueue(.init(kind: .reset, from: "customer", to: "anonymous", migrateEvents: false))
        await transitions.drain()
        XCTAssertEqual(info.state, .ready, "The new anonymous customer's admitted profile must publish readiness")

        identity.setDistinctId("customer")
        transitions.enqueue(.init(kind: .identify, from: "anonymous", to: "customer", migrateEvents: false))
        await transitions.drain()
        XCTAssertEqual(info.state, .ready, "Reidentification must admit and publish the current profile")
    }

    func testFailedIdentityRefreshWithoutCacheRemainsUnknown() async {
        let identity = MockIdentityService()
        identity.setDistinctId("new-customer")
        let profile = MockProfileService()
        profile.shouldThrow = true
        let info = FeatureInfo()
        let features = FeatureService(api: ReadinessFeatureCheck(), identity: identity,
            profile: profile, dateProvider: MockDateProvider(), featureInfo: info, cacheTTL: 300)
        let transitions = UserTransitionCoordinator(profile: profile,
            eventLog: ReadinessEventMigration(), features: features, experiences: MockExperienceService())
        transitions.enqueue(.init(kind: .identify, from: "previous", to: "new-customer", migrateEvents: false))
        await transitions.drain()
        XCTAssertEqual(info.state, .unknown)
        XCTAssertTrue(info.all.isEmpty)
    }

    func testMissingProfileCannotPublishReady() async {
        let identity = MockIdentityService()
        let profile = MockProfileService()
        let info = FeatureInfo()
        let features = FeatureService(api: ReadinessFeatureCheck(), identity: identity,
            profile: profile, dateProvider: MockDateProvider(), featureInfo: info, cacheTTL: 300)
        await features.syncFeatureInfo()
        XCTAssertEqual(info.state, .unknown)
    }
}
