import Foundation
import XCTest
@_spi(Testing) @testable import Nuxie
@testable import NuxieTestSupport

private actor DeviceLegProfileSequenceAPI: ProfileFetching {
    enum Item: Sendable {
        case response(ProfileResponse)
        case failure
    }

    private var items: [Item]
    private(set) var fetchCount = 0

    init(_ items: [Item]) {
        self.items = items
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
}

private actor RecordingDeviceLegProfileConsumer: DeviceLegProfileConsuming {
    private(set) var commits: [DeviceLegProfileCatalog.Snapshot] = []
    private(set) var clearedDistinctIds: [String] = []
    private(set) var clearAllCount = 0

    func profileDidCommit(
        _ snapshot: DeviceLegProfileCatalog.Snapshot,
        distinctId: String
    ) {
        _ = distinctId
        commits.append(snapshot)
    }

    func profileDidClear(distinctId: String) {
        clearedDistinctIds.append(distinctId)
    }

    func profileDidClearAll() {
        clearAllCount += 1
    }
}

final class DeviceLegProfileServiceTests: XCTestCase {
    func testForegroundAlwaysRevalidatesFreshCanonicalProfile() async throws {
        let fixture = try DeviceLegPlaneProfileTestFixture.load()
        let response = ProfileResponse(planeProfile: fixture.profile)
        let sleepProvider = MockSleepProvider()
        sleepProvider.shouldCompleteImmediately = true
        let api = DeviceLegProfileSequenceAPI([
            .response(response),
            .response(response),
        ])
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let service = makeService(
            cache: InMemoryCachedProfileStore(ttl: nil),
            identity: identity,
            api: api,
            experiences: MockExperienceService(),
            catalog: try makeCatalog(
                fixture,
                store: InMemoryExperienceReleaseHighWaterStore()
            ),
            sleepProvider: sleepProvider
        )

        _ = try await service.refetchProfile(distinctId: "customer")
        let initialFetchCount = await api.fetchCount
        XCTAssertEqual(initialFetchCount, 1)
        XCTAssertTrue(sleepProvider.sleepCalls.isEmpty)

        await service.onAppBecameActive()

        let foregroundFetchCount = await api.fetchCount
        XCTAssertEqual(foregroundFetchCount, 2)
        XCTAssertTrue(sleepProvider.sleepCalls.isEmpty)
    }

    func testLegacyPeriodicRefreshDoesNotSpinWhenSleepReturnsEarly() async throws {
        let fixture = try DeviceLegPlaneProfileTestFixture.load()
        let sleepProvider = MockSleepProvider()
        sleepProvider.shouldCompleteImmediately = true
        let api = DeviceLegProfileSequenceAPI([
            .response(ProfileResponse(segments: [])),
            .response(ProfileResponse(segments: [])),
        ])
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let service = makeService(
            cache: InMemoryCachedProfileStore(ttl: nil),
            identity: identity,
            api: api,
            experiences: MockExperienceService(),
            catalog: try makeCatalog(
                fixture,
                store: InMemoryExperienceReleaseHighWaterStore()
            ),
            sleepProvider: sleepProvider
        )

        _ = try await service.refetchProfile(distinctId: "customer")
        try await Task.sleep(nanoseconds: 20_000_000)

        let fetchCount = await api.fetchCount
        XCTAssertEqual(fetchCount, 1)
        XCTAssertEqual(sleepProvider.sleepCalls.count, 1)
    }

    func testAdmissionPublishesCanonicalAuthorityAndRejectedReplacementRetainsIt() async throws {
        let fixture = try DeviceLegPlaneProfileTestFixture.load()
        let invalid = try fixture.invalidSignatureProfile()
        let api = DeviceLegProfileSequenceAPI([
            .response(ProfileResponse(planeProfile: fixture.profile)),
            .response(ProfileResponse(planeProfile: invalid)),
            .response(ProfileResponse(segments: [])),
        ])
        let highWater = InMemoryExperienceReleaseHighWaterStore()
        let catalog = try makeCatalog(fixture, store: highWater)
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let cache = InMemoryCachedProfileStore(ttl: nil)
        let experiences = MockExperienceService()
        let runtime = RecordingDeviceLegProfileConsumer()
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
        XCTAssertNil(experiences.committedReleaseProfiles.last ?? nil)
        let initialRuntimeCommits = await runtime.commits
        XCTAssertEqual(initialRuntimeCommits.count, 1)
        XCTAssertEqual(initialRuntimeCommits.first?.releasesByDigest.count, 1)

        do {
            _ = try await service.refetchProfile(distinctId: "customer")
            XCTFail("Expected invalid signed replacement rejection")
        } catch {
            XCTAssertEqual(
                error as? ExperienceReleaseDescriptorAuthenticationError,
                .invalidSignature
            )
        }
        let retainedSnapshot = await catalog.snapshot(distinctId: "customer")
        let retained = try XCTUnwrap(retainedSnapshot)
        XCTAssertEqual(retained.releasesByDigest.keys, current.releasesByDigest.keys)
        let retainedProfile = await service.getCachedProfile(distinctId: "customer")
        XCTAssertNotNil(retainedProfile?.planeProfile)
        let retainedRuntimeCommits = await runtime.commits
        XCTAssertEqual(retainedRuntimeCommits.count, 1)

        _ = try await service.refetchProfile(distinctId: "customer")
        let cleared = await catalog.snapshot(distinctId: "customer")
        XCTAssertNil(cleared)
        let runtimeClears = await runtime.clearedDistinctIds
        XCTAssertEqual(runtimeClears, ["customer"])
    }

    func testDiskReloadReauthenticatesCanonicalAuthorityWhileOffline() async throws {
        let fixture = try DeviceLegPlaneProfileTestFixture.load()
        let cache = InMemoryCachedProfileStore(ttl: nil)
        let highWater = InMemoryExperienceReleaseHighWaterStore()
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let writerCatalog = try makeCatalog(fixture, store: highWater)
        let writer = makeService(
            cache: cache,
            identity: identity,
            api: DeviceLegProfileSequenceAPI([
                .response(ProfileResponse(planeProfile: fixture.profile))
            ]),
            experiences: MockExperienceService(),
            catalog: writerCatalog
        )
        _ = try await writer.refetchProfile(distinctId: "customer")

        let readerCatalog = try makeCatalog(fixture, store: highWater)
        let reader = makeService(
            cache: cache,
            identity: identity,
            api: DeviceLegProfileSequenceAPI([.failure]),
            experiences: MockExperienceService(),
            catalog: readerCatalog
        )
        let cached = await reader.getCachedProfile(distinctId: "customer")
        XCTAssertNotNil(cached?.planeProfile)
        let rehydrated = await readerCatalog.snapshot(distinctId: "customer")
        let snapshot = try XCTUnwrap(rehydrated)
        XCTAssertEqual(snapshot.releasesByDigest.count, 1)
    }

    private func makeService(
        cache: any CachedProfileStore,
        identity: MockIdentityService,
        api: ProfileFetching,
        experiences: MockExperienceService,
        catalog: DeviceLegProfileCatalog,
        runtime: (any DeviceLegProfileConsuming)? = nil,
        sleepProvider: MockSleepProvider = MockSleepProvider()
    ) -> ProfileService {
        ProfileService(
            cache: cache,
            identity: identity,
            api: api,
            segments: MockSegmentService(),
            experiences: experiences,
            deviceLegProfiles: catalog,
            deviceLegRuntime: runtime,
            eventLog: MockEventLog(),
            dateProvider: MockDateProvider(),
            sleepProvider: sleepProvider,
            localeProvider: ConfigurationLocaleIdentifierProvider(
                configuredLocale: { "en_US" }
            )
        )
    }

    private func makeCatalog(
        _ fixture: DeviceLegPlaneProfileTestFixture,
        store: any ExperienceReleaseHighWaterStore
    ) throws -> DeviceLegProfileCatalog {
        DeviceLegProfileCatalog(
            authorizationKeys: [ExperiencePackageAuthorizationKey(
                keyID: "TEST_ONLY_DEV_KEYPAIR",
                ed25519PublicKeyBytes: fixture.publicKey
            )],
            supportedRuntime: ExperienceReleaseRuntime.current,
            highWaterStore: store
        )
    }
}
