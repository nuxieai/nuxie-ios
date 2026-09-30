import XCTest
@_spi(Testing) @testable import Nuxie
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

#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
/// Serves one signed fixture profile to whoever asks.
private actor FixtureProfileAPI: ProfileFetching {
    private let profile: JourneyPlaneProfile
    private let authority: ProfileDeliveryAuthority
    private var fetchCount = 0

    init(profile: JourneyPlaneProfile, authority: ProfileDeliveryAuthority) {
        self.profile = profile
        self.authority = authority
    }

    func fetchProfile(for distinctId: String, locale: String?) async throws -> ProfileResponse {
        _ = distinctId
        _ = locale
        return ProfileResponse(planeProfile: profile)
    }

    func fetchProfileWithTimeout(
        for distinctId: String,
        locale: String?,
        timeout: TimeInterval
    ) async throws -> ProfileResponse {
        _ = timeout
        return try await fetchProfile(for: distinctId, locale: locale)
    }

    func fetchProfile(
        for distinctId: String,
        locale: String?,
        revalidating validator: ProfileCacheValidator?
    ) async throws -> ProfileFetchResult {
        _ = validator
        fetchCount += 1
        return .modified(
            try await fetchProfile(for: distinctId, locale: locale),
            validator: ProfileCacheValidator(
                rawValue: "\"identity-profile-\(fetchCount)\"",
                authority: authority
            )
        )
    }
}
#endif

@MainActor
final class FeatureIdentityReadinessTests: XCTestCase {
    /// After Journeys retire the departing user's presentation and before the
    /// next profile admits, a first sign-in hands the prepared releases to
    /// the signed-in user, while a switch between identified users and a
    /// reset discard them (decision 16). Only a reset clears the catalog.
    func testUserTransitionHandsOverOrDiscardsPreparedReleasesInOrder() async {
        let log = TransitionOrderLog()
        let identity = MockIdentityService()
        let profile = OrderedProfileProbe(log: log)
        let experiences = MockExperienceService()
        experiences.preparationCallObserver = { call in
            switch call {
            case .discard(let departing):
                log.append("experiences.discardPreparedReleases(\(departing ?? "nil"))")
            case .transfer(let departing, let arriving):
                log.append("experiences.transferPreparedReleases(\(departing)->\(arriving))")
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
                "experiences.transferPreparedReleases(anonymous->customer)",
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

    #if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
    /// End to end through the real profile, Experience, and transition
    /// services: a first sign-in keeps the anonymous user's prepared release,
    /// whether the signed-in user's profile commits before or after the queued
    /// transition runs. A later switch between identified users and a reset
    /// each discard it, so it is prepared again.
    func testFirstSignInKeepsPreparedReleaseWhileSwitchAndResetDiscardInEitherOrder() async throws {
        for profileCommitsFirst in [false, true] {
            try await assertPreparedReleaseAcrossUserChanges(
                profileCommitsFirst: profileCommitsFirst
            )
        }
    }

    private func assertPreparedReleaseAcrossUserChanges(
        profileCommitsFirst: Bool
    ) async throws {
        let order = profileCommitsFirst ? "profile first" : "transition first"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "identity-preparation-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            StubURLProtocol.reset()
            try? FileManager.default.removeItem(at: directory)
        }
        let fixture = experiencePreparationRepositoryRoot()
            .appendingPathComponent("Tests/ExperienceRuntimeHostApp/Fixtures/multi-screen")
        let profile = try JourneyPlaneProfile.decode(
            Data(contentsOf: fixture.appendingPathComponent("profile.json"))
        )
        let host = try XCTUnwrap(URL(string: profile.delivery.renderBaseUrl)?.host)
        StubURLProtocol.reset()
        serveSignedFixtureObjects(at: fixture, host: host)
        let entry = try XCTUnwrap(profile.releases.first)
        let placeholderPayload = try await statePayload(defaultViewModelName: "Test")

        let gate = ConcurrencyProbeGate()
        let experiences = ExperienceService(
            productService: ProductService(),
            eventLog: MockEventLog(),
            transactionServiceProvider: {
                fatalError("preparation needs no transaction service")
            },
            systemEventSink: DiscardingSystemEventSink(),
            releaseStore: JourneyReleaseAcquisitionStore(
                cacheDirectory: directory,
                urlSession: TestURLSessionProvider.createTestSession()
            ),
            automaticPreparation: true,
            preparationCache: probedPreparationCache(gate)
        )
        let identity = MockIdentityService()
        identity.reset(keepAnonymousId: false)
        let profiles = ProfileService(
            cache: InMemoryCachedProfileStore(ttl: nil),
            identity: identity,
            api: FixtureProfileAPI(
                profile: profile,
                authority: ProfileDeliveryAuthority(
                    appId: entry.locator.appId,
                    environment: entry.locator.environment
                )
            ),
            experiences: experiences,
            journeyProfiles: JourneyProfileCatalog(
                authorizationKeys: try JourneyTrustRoots.keys(for: .development),
                supportedRuntime: JourneyReleaseRuntime.current,
                highWaterStore: InMemoryJourneyReleaseHighWaterStore()
            ),
            dateProvider: MockDateProvider(),
            localeProvider: ConfigurationLocaleIdentifierProvider(
                configuredLocale: { "en_US" }
            )
        )
        let features = FeatureService(api: ReadinessFeatureCheck(), identity: identity,
            profile: profiles, dateProvider: MockDateProvider(), featureInfo: FeatureInfo(), cacheTTL: 300)
        let transitions = UserTransitionCoordinator(profile: profiles,
            eventLog: ReadinessEventMigration(), features: features, experiences: experiences)
        let store = experiences.preparedReleaseStore

        /// Moves identity the way `identify` and `reset` do, then delivers
        /// the arriving user's profile and the queued transition in this
        /// run's order.
        func changeUser(
            _ kind: UserTransitionCoordinator.Kind,
            identifyingAs distinctId: String? = nil
        ) async throws {
            let from = identity.getDistinctId()
            let wasIdentified = identity.isIdentified
            switch kind {
            case .identify: identity.setDistinctId(try XCTUnwrap(distinctId))
            case .reset: identity.reset(keepAnonymousId: false)
            }
            let to = identity.getDistinctId()
            if profileCommitsFirst {
                _ = try await profiles.refetchProfile(distinctId: to)
            }
            transitions.enqueue(.init(
                kind: kind,
                from: from,
                to: to,
                migrateEvents: kind == .identify && !wasIdentified
            ))
            await transitions.drain()
            await experiences.waitForPreparationIdle()
        }

        _ = try await profiles.refetchProfile(distinctId: identity.getDistinctId())
        await experiences.waitForPreparationIdle()
        let armed = await store.inspection().armed
        let descriptorSHA256 = try XCTUnwrap(armed.first, order)
        let anonymousPreparation = try await heldPreparation(
            descriptorSHA256, in: store, placeholder: placeholderPayload, order)

        try await changeUser(.identify, identifyingAs: "customer")
        let signedIn = try await heldPreparation(
            descriptorSHA256, in: store, placeholder: placeholderPayload, order)
        XCTAssertTrue(signedIn === anonymousPreparation, "\(order): a first sign-in keeps it")
        var starts = await gate.startLog.count
        XCTAssertEqual(starts, 1, "\(order): a first sign-in prepares nothing again")
        let signedInOwner = await store.inspection().ownerDistinctId
        XCTAssertEqual(signedInOwner, "customer", order)

        try await changeUser(.identify, identifyingAs: "other-customer")
        let switched = try await heldPreparation(
            descriptorSHA256, in: store, placeholder: placeholderPayload, order)
        XCTAssertFalse(switched === anonymousPreparation, "\(order): a switch discards it")
        starts = await gate.startLog.count
        XCTAssertEqual(starts, 2, order)

        try await changeUser(.reset)
        let reset = try await heldPreparation(
            descriptorSHA256, in: store, placeholder: placeholderPayload, order)
        XCTAssertFalse(reset === switched, "\(order): a reset discards it")
        starts = await gate.startLog.count
        XCTAssertEqual(starts, 3, order)

        await experiences.shutdownPreparation()
    }

    /// The native preparation the store holds for a release, without starting
    /// another. The cache coalesces by provenance, so once the release is
    /// prepared the payload is never read.
    private func heldPreparation(
        _ descriptorSHA256: String,
        in store: JourneyPreparedReleaseStore,
        placeholder: AuthenticatedRuntimePayload,
        _ message: String
    ) async throws -> ExperienceInteractivePreparation {
        struct NotPrepared: Error {}
        let status = await store.cache.status(for: descriptorSHA256)
        guard status == .prepared else {
            XCTFail("\(message): expected a prepared release, found \(status)")
            throw NotPrepared()
        }
        return try await store.cache.preparation(
            provenance: descriptorSHA256,
            payload: placeholder
        )
    }
    #endif

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
