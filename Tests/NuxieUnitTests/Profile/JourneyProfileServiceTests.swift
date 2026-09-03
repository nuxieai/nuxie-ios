import Foundation
import XCTest
@_spi(Testing) @testable import Nuxie
@testable import NuxieTestSupport

private actor JourneyProfileSequenceAPI: ProfileFetching {
    enum Item: Sendable {
        case response(ProfileResponse)
        case failure
    }

    private var items: [Item]
    private var authority: ProfileDeliveryAuthority?
    private(set) var fetchCount = 0

    init(
        _ items: [Item],
        authority: ProfileDeliveryAuthority? = nil
    ) {
        self.items = items
        self.authority = authority
    }

    func setAuthority(_ authority: ProfileDeliveryAuthority?) {
        self.authority = authority
    }

    func fetchProfile(for distinctId: String, locale: String?) async throws -> ProfileResponse {
        _ = distinctId
        _ = locale
        fetchCount += 1
        guard !items.isEmpty else { throw NuxieNetworkError.invalidResponse }
        switch items.removeFirst() {
        case .response(let response): return response
        case .failure: throw URLError(.notConnectedToInternet)
        }
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
        let response = try await fetchProfile(
            for: distinctId,
            locale: locale
        )
        return .modified(
            response,
            validator: ProfileCacheValidator(
                rawValue: "\"journey-profile-\(fetchCount)\"",
                authority: authority
            )
        )
    }
}

private actor RecordingJourneyProfileConsumer: JourneyProfileConsuming {
    private(set) var commits: [JourneyProfileCatalog.Snapshot] = []
    private(set) var authorities: [ProfileDeliveryAuthority] = []
    private(set) var withdrawnDistinctIds: [String] = []
    private(set) var clearedDistinctIds: [String] = []
    private(set) var clearAllCount = 0

    func profileDidCommit(
        _ snapshot: JourneyProfileCatalog.Snapshot,
        artifacts: PreparedJourneyArtifacts?,
        authority: ProfileDeliveryAuthority,
        admissionGeneration: UInt64,
        distinctId: String
    ) {
        _ = distinctId
        _ = artifacts
        _ = admissionGeneration
        commits.append(snapshot)
        authorities.append(authority)
    }

    func profileDidWithdraw(
        authority: ProfileDeliveryAuthority?,
        admissionGeneration: UInt64,
        distinctId: String
    ) {
        _ = authority
        _ = admissionGeneration
        withdrawnDistinctIds.append(distinctId)
    }

    func profileDidClear(
        distinctId: String,
        admissionGeneration: UInt64
    ) {
        _ = admissionGeneration
        clearedDistinctIds.append(distinctId)
    }

    func profileDidClearAll(admissionGeneration: UInt64) {
        _ = admissionGeneration
        clearAllCount += 1
    }
}

private actor RejectingHighWaterCommitStore {
    func admitActiveBatch(
        _ candidates: [JourneyReleaseHighWaterKey: JourneyReleaseHighWaterMark]
    ) throws {
        _ = candidates
        throw JourneyReleaseAuthenticationError.replayRejected
    }

    func highWater(
        for key: JourneyReleaseHighWaterKey
    ) -> JourneyReleaseHighWaterMark? {
        _ = key
        return nil
    }
}

extension RejectingHighWaterCommitStore: JourneyReleaseHighWaterStore {}

final class JourneyProfileServiceTests: XCTestCase {
    func testForegroundAlwaysRevalidatesFreshCanonicalProfile() async throws {
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let response = ProfileResponse(planeProfile: fixture.profile)
        let api = JourneyProfileSequenceAPI([
            .response(response),
            .response(response),
        ], authority: fixture.deliveryAuthority)
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let service = makeService(
            cache: InMemoryCachedProfileStore(ttl: nil),
            identity: identity,
            api: api,
            experiences: MockExperienceService(),
            catalog: try makeCatalog(
                fixture,
                store: InMemoryJourneyReleaseHighWaterStore()
            )
        )

        _ = try await service.refetchProfile(distinctId: "customer")
        let initialFetchCount = await api.fetchCount
        XCTAssertEqual(initialFetchCount, 1)

        await service.onAppBecameActive()

        let foregroundFetchCount = await api.fetchCount
        XCTAssertEqual(foregroundFetchCount, 2)
    }

    func testAdmissionPublishesCanonicalAuthorityAndRejectedReplacementRetainsIt() async throws {
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let invalid = try fixture.invalidSignatureProfile()
        let api = JourneyProfileSequenceAPI([
            .response(ProfileResponse(planeProfile: fixture.profile)),
            .response(ProfileResponse(planeProfile: invalid)),
            .response(TestJourneyProfile.response()),
        ], authority: fixture.deliveryAuthority)
        let highWater = InMemoryJourneyReleaseHighWaterStore()
        let catalog = try makeCatalog(fixture, store: highWater)
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let cache = InMemoryCachedProfileStore(ttl: nil)
        let experiences = MockExperienceService()
        let runtime = RecordingJourneyProfileConsumer()
        let service = makeService(
            cache: cache,
            identity: identity,
            api: api,
            experiences: experiences,
            catalog: catalog,
            runtime: runtime
        )

        _ = try await service.refetchProfile(distinctId: "customer")
        let currentSnapshot = await catalog.snapshot(distinctId: "customer")
        let current = try XCTUnwrap(currentSnapshot)
        XCTAssertEqual(current.releasesByDigest.count, 1)
        XCTAssertEqual(experiences.committedJourneyReleaseCounts, [1])
        let initialRuntimeCommits = await runtime.commits
        XCTAssertEqual(initialRuntimeCommits.count, 1)
        XCTAssertEqual(initialRuntimeCommits.first?.releasesByDigest.count, 1)
        let initialRuntimeAuthorities = await runtime.authorities
        XCTAssertEqual(initialRuntimeAuthorities, [fixture.deliveryAuthority])

        do {
            _ = try await service.refetchProfile(distinctId: "customer")
            XCTFail("Expected invalid signed replacement rejection")
        } catch {
            XCTAssertEqual(
                error as? JourneyReleaseAuthenticationError,
                .invalidSignature
            )
        }
        let retainedSnapshot = await catalog.snapshot(distinctId: "customer")
        let retained = try XCTUnwrap(retainedSnapshot)
        XCTAssertEqual(retained.releasesByDigest.keys, current.releasesByDigest.keys)
        let retainedProfile = await service.getCachedProfile(distinctId: "customer")
        XCTAssertEqual(retainedProfile?.planeProfile.releases.count, 1)
        let retainedRuntimeCommits = await runtime.commits
        XCTAssertEqual(retainedRuntimeCommits.count, 1)
        XCTAssertEqual(experiences.committedJourneyReleaseCounts, [1])

        _ = try await service.refetchProfile(distinctId: "customer")
        let empty = await catalog.snapshot(distinctId: "customer")
        XCTAssertEqual(empty?.releasesByDigest.count, 0)
        XCTAssertEqual(experiences.committedJourneyReleaseCounts, [1, 0])
        let runtimeCommits = await runtime.commits
        XCTAssertEqual(runtimeCommits.map { $0.profile.releases.count }, [1, 0])
    }

    func testHighWaterCommitFailureDoesNotPublishJourneyProductAuthority() async throws {
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let experiences = MockExperienceService()
        let runtime = RecordingJourneyProfileConsumer()
        let catalog = try makeCatalog(
            fixture,
            store: RejectingHighWaterCommitStore()
        )
        let service = makeService(
            cache: InMemoryCachedProfileStore(ttl: nil),
            identity: identity,
            api: JourneyProfileSequenceAPI([
                .response(ProfileResponse(planeProfile: fixture.profile))
            ], authority: fixture.deliveryAuthority),
            experiences: experiences,
            catalog: catalog,
            runtime: runtime
        )

        do {
            _ = try await service.refetchProfile(distinctId: "customer")
            XCTFail("Expected replay high-water rejection")
        } catch {
            XCTAssertEqual(
                error as? JourneyReleaseAuthenticationError,
                .replayRejected
            )
        }

        let catalogSnapshot = await catalog.snapshot(distinctId: "customer")
        let runtimeCommits = await runtime.commits
        XCTAssertNil(catalogSnapshot)
        XCTAssertTrue(runtimeCommits.isEmpty)
        XCTAssertTrue(experiences.committedJourneyReleaseCounts.isEmpty)
    }

    func testJourneyPreparationFailureWithholdsCanonicalProfileAuthority() async throws {
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let cache = InMemoryCachedProfileStore(ttl: nil)
        let experiences = MockExperienceService()
        experiences.journeyArtifactPreparationFailuresRemaining = 1
        let runtime = RecordingJourneyProfileConsumer()
        let catalog = try makeCatalog(
            fixture,
            store: InMemoryJourneyReleaseHighWaterStore()
        )
        let service = makeService(
            cache: cache,
            identity: identity,
            api: JourneyProfileSequenceAPI([
                .response(ProfileResponse(planeProfile: fixture.profile))
            ], authority: fixture.deliveryAuthority),
            experiences: experiences,
            catalog: catalog,
            runtime: runtime
        )

        do {
            _ = try await service.refetchProfile(distinctId: "customer")
            XCTFail("Expected required Journey artifact acquisition to fail")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }

        let catalogSnapshot = await catalog.snapshot(distinctId: "customer")
        let runtimeCommits = await runtime.commits
        let cachedProfile = await cache.retrieve(
            forKey: "customer",
            allowStale: true
        )
        XCTAssertNil(catalogSnapshot)
        XCTAssertTrue(runtimeCommits.isEmpty)
        XCTAssertTrue(experiences.committedJourneyReleaseCounts.isEmpty)
        XCTAssertNil(cachedProfile)
    }

    func testDiskReloadReauthenticatesCanonicalAuthorityWhileOffline() async throws {
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let cache = InMemoryCachedProfileStore(ttl: nil)
        let highWater = InMemoryJourneyReleaseHighWaterStore()
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let authorityStore = InMemoryProfileAuthorityBindingStore()
        let writerCatalog = try makeCatalog(fixture, store: highWater)
        let writer = makeService(
            cache: cache,
            identity: identity,
            api: JourneyProfileSequenceAPI([
                .response(ProfileResponse(planeProfile: fixture.profile))
            ], authority: fixture.deliveryAuthority),
            experiences: MockExperienceService(),
            catalog: writerCatalog,
            authorityStore: authorityStore
        )
        _ = try await writer.refetchProfile(distinctId: "customer")

        let readerCatalog = try makeCatalog(fixture, store: highWater)
        let reader = makeService(
            cache: cache,
            identity: identity,
            api: JourneyProfileSequenceAPI(
                [.failure],
                authority: fixture.deliveryAuthority
            ),
            experiences: MockExperienceService(),
            catalog: readerCatalog,
            authorityStore: authorityStore
        )
        let cached = await reader.getCachedProfile(distinctId: "customer")
        XCTAssertEqual(cached?.planeProfile.releases.count, 1)
        let rehydrated = await readerCatalog.snapshot(distinctId: "customer")
        let snapshot = try XCTUnwrap(rehydrated)
        XCTAssertEqual(snapshot.releasesByDigest.count, 1)
    }

    func testCrossAuthorityReplacementIsRejectedBeforeCacheAndCannotWinAfterRestart() async throws {
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let cache = InMemoryCachedProfileStore(ttl: nil)
        let authorityStore = InMemoryProfileAuthorityBindingStore()
        let highWater = InMemoryJourneyReleaseHighWaterStore()
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let api = JourneyProfileSequenceAPI([
            .response(ProfileResponse(planeProfile: fixture.profile)),
            .response(ProfileResponse(planeProfile: fixture.profile)),
        ], authority: fixture.deliveryAuthority)
        let writer = makeService(
            cache: cache,
            identity: identity,
            api: api,
            experiences: MockExperienceService(),
            catalog: try makeCatalog(fixture, store: highWater),
            authorityStore: authorityStore
        )
        _ = try await writer.refetchProfile(distinctId: "customer")

        await api.setAuthority(ProfileDeliveryAuthority(
            appId: "other_app",
            environment: fixture.deliveryAuthority.environment
        ))
        do {
            _ = try await writer.refetchProfile(distinctId: "customer")
            XCTFail("Expected cross-authority profile rejection")
        } catch {
            XCTAssertEqual(
                error as? JourneyReleaseAuthenticationError,
                .invalidDescriptor
            )
        }

        let cachedItem = await cache.retrieve(
            forKey: "customer",
            allowStale: true
        )
        XCTAssertEqual(
            cachedItem?.validator?.authority,
            fixture.deliveryAuthority
        )

        let readerCatalog = try makeCatalog(fixture, store: highWater)
        let reader = makeService(
            cache: cache,
            identity: identity,
            api: JourneyProfileSequenceAPI([.failure]),
            experiences: MockExperienceService(),
            catalog: readerCatalog,
            authorityStore: authorityStore
        )
        let restored = await reader.getCachedProfile(distinctId: "customer")
        XCTAssertEqual(restored?.planeProfile.releases.count, 1)
        let restoredSnapshot = await readerCatalog.snapshot(
            distinctId: "customer"
        )
        XCTAssertNotNil(restoredSnapshot)
    }

    func testExpiredCanonicalProfileRemainsInstalledWhileForegroundRevalidationFails() async throws {
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let dateProvider = MockDateProvider()
        let runtime = RecordingJourneyProfileConsumer()
        let catalog = try makeCatalog(
            fixture,
            store: InMemoryJourneyReleaseHighWaterStore()
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let service = makeService(
            cache: InMemoryCachedProfileStore(ttl: nil),
            identity: identity,
            api: JourneyProfileSequenceAPI([
                .response(ProfileResponse(planeProfile: fixture.profile)),
                .failure,
            ], authority: fixture.deliveryAuthority),
            experiences: MockExperienceService(),
            catalog: catalog,
            runtime: runtime,
            dateProvider: dateProvider
        )
        _ = try await service.refetchProfile(distinctId: "customer")
        dateProvider.advance(by: 25 * 60 * 60)

        await service.onAppBecameActive()

        let retainedSnapshot = await catalog.snapshot(distinctId: "customer")
        let withdrawnDistinctIds = await runtime.withdrawnDistinctIds
        let retainedProfile = await service.getCachedProfile(
            distinctId: "customer"
        )
        XCTAssertNotNil(retainedSnapshot)
        XCTAssertTrue(withdrawnDistinctIds.isEmpty)
        XCTAssertEqual(retainedProfile?.planeProfile.releases.count, 1)
    }

    private func makeService(
        cache: any CachedProfileStore,
        identity: MockIdentityService,
        api: ProfileFetching,
        experiences: MockExperienceService,
        catalog: JourneyProfileCatalog,
        runtime: (any JourneyProfileConsuming)? = nil,
        dateProvider: MockDateProvider = MockDateProvider(),
        authorityStore: any ProfileAuthorityBindingStore =
            InMemoryProfileAuthorityBindingStore()
    ) -> ProfileService {
        ProfileService(
            cache: cache,
            authorityStore: authorityStore,
            identity: identity,
            api: api,
            experiences: experiences,
            journeyProfiles: catalog,
            journeyRuntime: runtime,
            dateProvider: dateProvider,
            localeProvider: ConfigurationLocaleIdentifierProvider(
                configuredLocale: { "en_US" }
            )
        )
    }

    private func makeCatalog(
        _ fixture: JourneyPlaneProfileTestFixture,
        store: any JourneyReleaseHighWaterStore
    ) throws -> JourneyProfileCatalog {
        JourneyProfileCatalog(
            authorizationKeys: [JourneyPackageAuthorizationKey(
                keyID: "TEST_ONLY_DEV_KEYPAIR",
                ed25519PublicKeyBytes: fixture.publicKey
            )],
            supportedRuntime: JourneyReleaseRuntime.current,
            highWaterStore: store
        )
    }
}
