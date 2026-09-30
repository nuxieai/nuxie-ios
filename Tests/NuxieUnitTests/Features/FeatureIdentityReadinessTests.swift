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

/// One ordered log shared by the transition's collaborators.
private final class TransitionOrderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    func append(_ entry: String) { lock.withLock { recorded.append(entry) } }
    func reset() { lock.withLock { recorded.removeAll() } }
    var entries: [String] { lock.withLock { recorded } }
}

private final class OrderedProfileProbe: ProfileServiceProtocol, @unchecked Sendable {
    private let base = MockProfileService()
    private let log: TransitionOrderLog

    init(log: TransitionOrderLog) { self.log = log }

    func getCachedProfile(distinctId: String) async -> ProfileResponse? {
        await base.getCachedProfile(distinctId: distinctId)
    }
    func localeDidChange() async {}
    func clearCache(distinctId: String) async { await base.clearCache(distinctId: distinctId) }
    func clearAllCache() async { await base.clearAllCache() }
    func cleanupExpired() async -> Int { 0 }
    func refetchProfile(distinctId: String?) async throws -> ProfileResponse {
        try await base.refetchProfile(distinctId: distinctId)
    }
    func handleUserChange(from oldDistinctId: String, to newDistinctId: String) async {
        log.append("profile.handleUserChange")
        await base.handleUserChange(from: oldDistinctId, to: newDistinctId)
    }
    func onAppBecameActive() async {}
}

private actor OrderedJourneyProbe: JourneyServiceProtocol {
    private let log: TransitionOrderLog

    init(log: TransitionOrderLog) { self.log = log }

    func initialize() async {}
    func handleEvent(_ event: NuxieEvent) async { _ = event }
    func handleEvent(_ event: NuxieEvent, admittedProfileGeneration: UInt64?) async -> Bool {
        _ = event
        _ = admittedProfileGeneration
        return true
    }
    nonisolated func eventAdmissionGeneration() -> UInt64 { 0 }
    func onAppDidEnterBackground() async {}
    func onAppWillEnterForeground() async {}
    func onAppBecameActive() async {}
    func handleUserChange(from oldDistinctId: String, to newDistinctId: String) async {
        _ = oldDistinctId
        _ = newDistinctId
        log.append("journeys.handleUserChange")
    }
    func profileDidCommit(
        _ snapshot: JourneyProfileCatalog.Snapshot,
        artifacts: PreparedJourneyArtifacts?,
        authority: ProfileDeliveryAuthority,
        admissionGeneration: UInt64,
        distinctId: String
    ) async {}
    func profileDidWithdraw(
        authority: ProfileDeliveryAuthority?,
        admissionGeneration: UInt64,
        distinctId: String
    ) async {}
    func profileDidClear(distinctId: String, admissionGeneration: UInt64) async {}
    func profileDidClearAll(admissionGeneration: UInt64) async {}
}

@MainActor
final class FeatureIdentityReadinessTests: XCTestCase {
    /// Every identify and reset discards the departing user's prepared
    /// releases after Journeys retire that user's presentation and before the
    /// next profile admits. Only a reset clears the catalog.
    func testUserTransitionDiscardsPreparedReleasesInOrder() async {
        let log = TransitionOrderLog()
        let identity = MockIdentityService()
        let profile = OrderedProfileProbe(log: log)
        let experiences = MockExperienceService()
        experiences.preparationCallObserver = { call in
            switch call {
            case .discard(let departing):
                log.append("experiences.discardPreparedReleases(\(departing ?? "nil"))")
            case .clearCache:
                log.append("experiences.clearCache")
            default:
                break
            }
        }
        let features = FeatureService(api: ReadinessFeatureCheck(), identity: identity,
            profile: profile, dateProvider: MockDateProvider(), featureInfo: FeatureInfo(), cacheTTL: 300)
        let transitions = UserTransitionCoordinator(profile: profile,
            eventLog: ReadinessEventMigration(), features: features, experiences: experiences,
            journeys: OrderedJourneyProbe(log: log))

        let cases: [(UserTransitionCoordinator.Transition, [String])] = [
            (.init(kind: .identify, from: "anonymous", to: "customer", migrateEvents: true), [
                "journeys.handleUserChange",
                "experiences.discardPreparedReleases(anonymous)",
                "profile.handleUserChange",
            ]),
            (.init(kind: .identify, from: "customer", to: "other-customer", migrateEvents: false), [
                "journeys.handleUserChange",
                "experiences.discardPreparedReleases(customer)",
                "profile.handleUserChange",
            ]),
            (.init(kind: .reset, from: "other-customer", to: "anonymous-2", migrateEvents: false), [
                "journeys.handleUserChange",
                "experiences.discardPreparedReleases(other-customer)",
                "experiences.clearCache",
                "profile.handleUserChange",
            ]),
        ]
        for (transition, expected) in cases {
            log.reset()
            identity.setDistinctId(transition.to)
            transitions.enqueue(transition)
            await transitions.drain()
            XCTAssertEqual(log.entries, expected, "\(transition.kind) \(transition.from) -> \(transition.to)")
        }
    }

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
