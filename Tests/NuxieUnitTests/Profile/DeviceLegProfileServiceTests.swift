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
                rawValue: "\"device-leg-profile-\(fetchCount)\"",
                authority: authority
            )
        )
    }
}

private actor RecordingDeviceLegProfileConsumer: DeviceLegProfileConsuming {
    private(set) var commits: [DeviceLegProfileCatalog.Snapshot] = []
    private(set) var authorities: [ProfileDeliveryAuthority] = []
    private(set) var clearedDistinctIds: [String] = []
    private(set) var clearAllCount = 0

    func profileDidCommit(
        _ snapshot: DeviceLegProfileCatalog.Snapshot,
        authority: ProfileDeliveryAuthority,
        distinctId: String
    ) {
        _ = distinctId
        commits.append(snapshot)
        authorities.append(authority)
    }

    func profileDidClear(distinctId: String) {
        clearedDistinctIds.append(distinctId)
    }

    func profileDidClearAll() {
        clearAllCount += 1
    }
}

private actor RejectingHighWaterCommitStore: ExperienceReleaseHighWaterStore {
    func admitActiveBatch(
        _ candidates: [ExperienceReleaseHighWaterKey: ExperienceReleaseHighWaterMark]
    ) throws {
        _ = candidates
        throw ExperienceReleaseDescriptorAuthenticationError.replayRejected
    }

    func highWater(
        for key: ExperienceReleaseHighWaterKey
    ) -> ExperienceReleaseHighWaterMark? {
        _ = key
        return nil
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
        ], authority: fixture.deliveryAuthority)
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
        XCTAssertEqual(experiences.committedDeviceLegReleaseCounts, [1])
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
        XCTAssertEqual(experiences.committedDeviceLegReleaseCounts, [1])

        _ = try await service.refetchProfile(distinctId: "customer")
        let cleared = await catalog.snapshot(distinctId: "customer")
        XCTAssertNil(cleared)
        XCTAssertEqual(experiences.committedDeviceLegReleaseCounts, [1, nil])
        let runtimeClears = await runtime.clearedDistinctIds
        XCTAssertEqual(runtimeClears, ["customer"])
    }

    func testHighWaterCommitFailureDoesNotPublishDeviceProductAuthority() async throws {
        let fixture = try DeviceLegPlaneProfileTestFixture.load()
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let experiences = MockExperienceService()
        let runtime = RecordingDeviceLegProfileConsumer()
        let catalog = try makeCatalog(
            fixture,
            store: RejectingHighWaterCommitStore()
        )
        let service = makeService(
            cache: InMemoryCachedProfileStore(ttl: nil),
            identity: identity,
            api: DeviceLegProfileSequenceAPI([
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
                error as? ExperienceReleaseDescriptorAuthenticationError,
                .replayRejected
            )
        }

        let catalogSnapshot = await catalog.snapshot(distinctId: "customer")
        let runtimeCommits = await runtime.commits
        XCTAssertNil(catalogSnapshot)
        XCTAssertTrue(runtimeCommits.isEmpty)
        XCTAssertTrue(experiences.committedReleaseProfiles.isEmpty)
        XCTAssertTrue(experiences.committedDeviceLegReleaseCounts.isEmpty)
    }

    func testDeviceLegPreparationFailureWithholdsCanonicalProfileAuthority() async throws {
        let fixture = try DeviceLegPlaneProfileTestFixture.load()
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let cache = InMemoryCachedProfileStore(ttl: nil)
        let experiences = MockExperienceService()
        experiences.deviceLegArtifactPreparationFailuresRemaining = 1
        let runtime = RecordingDeviceLegProfileConsumer()
        let catalog = try makeCatalog(
            fixture,
            store: InMemoryExperienceReleaseHighWaterStore()
        )
        let service = makeService(
            cache: cache,
            identity: identity,
            api: DeviceLegProfileSequenceAPI([
                .response(ProfileResponse(planeProfile: fixture.profile))
            ], authority: fixture.deliveryAuthority),
            experiences: experiences,
            catalog: catalog,
            runtime: runtime
        )

        do {
            _ = try await service.refetchProfile(distinctId: "customer")
            XCTFail("Expected required device-leg artifact acquisition to fail")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }

        let catalogSnapshot = await catalog.snapshot(distinctId: "customer")
        let runtimeCommits = await runtime.commits
        let cachedProfile = await cache.retrieve(
            forKey: "customer",
            allowStale: true
        )
        let triggerAdmission = await service.getTriggerAdmission(
            distinctId: "customer"
        )
        XCTAssertNil(catalogSnapshot)
        XCTAssertTrue(runtimeCommits.isEmpty)
        XCTAssertTrue(experiences.committedDeviceLegReleaseCounts.isEmpty)
        XCTAssertNil(cachedProfile)
        XCTAssertNil(triggerAdmission)
    }

    func testDiskReloadReauthenticatesCanonicalAuthorityWhileOffline() async throws {
        let fixture = try DeviceLegPlaneProfileTestFixture.load()
        let cache = InMemoryCachedProfileStore(ttl: nil)
        let highWater = InMemoryExperienceReleaseHighWaterStore()
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let authorityStore = InMemoryProfileAuthorityBindingStore()
        let writerCatalog = try makeCatalog(fixture, store: highWater)
        let writer = makeService(
            cache: cache,
            identity: identity,
            api: DeviceLegProfileSequenceAPI([
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
            api: DeviceLegProfileSequenceAPI(
                [.failure],
                authority: fixture.deliveryAuthority
            ),
            experiences: MockExperienceService(),
            catalog: readerCatalog,
            authorityStore: authorityStore
        )
        let cached = await reader.getCachedProfile(distinctId: "customer")
        XCTAssertNotNil(cached?.planeProfile)
        let rehydrated = await readerCatalog.snapshot(distinctId: "customer")
        let snapshot = try XCTUnwrap(rehydrated)
        XCTAssertEqual(snapshot.releasesByDigest.count, 1)
    }

    func testCrossAuthorityReplacementIsRejectedBeforeCacheAndCannotWinAfterRestart() async throws {
        let fixture = try DeviceLegPlaneProfileTestFixture.load()
        let cache = InMemoryCachedProfileStore(ttl: nil)
        let authorityStore = InMemoryProfileAuthorityBindingStore()
        let highWater = InMemoryExperienceReleaseHighWaterStore()
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let api = DeviceLegProfileSequenceAPI([
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
                error as? ExperienceReleaseDescriptorAuthenticationError,
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
            api: DeviceLegProfileSequenceAPI([.failure]),
            experiences: MockExperienceService(),
            catalog: readerCatalog,
            authorityStore: authorityStore
        )
        let restored = await reader.getCachedProfile(distinctId: "customer")
        XCTAssertNotNil(restored?.planeProfile)
        let restoredSnapshot = await readerCatalog.snapshot(
            distinctId: "customer"
        )
        XCTAssertNotNil(restoredSnapshot)
    }

    func testExpiredCanonicalProfileRemainsInstalledWhileForegroundRevalidationFails() async throws {
        let fixture = try DeviceLegPlaneProfileTestFixture.load()
        let dateProvider = MockDateProvider()
        let runtime = RecordingDeviceLegProfileConsumer()
        let catalog = try makeCatalog(
            fixture,
            store: InMemoryExperienceReleaseHighWaterStore()
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let service = makeService(
            cache: InMemoryCachedProfileStore(ttl: nil),
            identity: identity,
            api: DeviceLegProfileSequenceAPI([
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
        let clearedDistinctIds = await runtime.clearedDistinctIds
        let retainedProfile = await service.getCachedProfile(
            distinctId: "customer"
        )
        XCTAssertNotNil(retainedSnapshot)
        XCTAssertTrue(clearedDistinctIds.isEmpty)
        XCTAssertNotNil(retainedProfile?.planeProfile)
    }

    func testProductionStorageDeletesUnsafeUnscopedLegacyCache() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacyCache = directory
            .appendingPathComponent("nuxie", isDirectory: true)
            .appendingPathComponent("profiles", isDirectory: true)
        try FileManager.default.createDirectory(
            at: legacyCache,
            withIntermediateDirectories: true
        )
        try Data("unsafe-cross-app-profile".utf8).write(
            to: legacyCache.appendingPathComponent("profile.json")
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")

        let service = ProfileService(
            identity: identity,
            api: DeviceLegProfileSequenceAPI([]),
            segments: MockSegmentService(),
            experiences: MockExperienceService(),
            eventLog: MockEventLog(),
            dateProvider: MockDateProvider(),
            sleepProvider: MockSleepProvider(),
            localeProvider: ConfigurationLocaleIdentifierProvider(
                configuredLocale: { "en_US" }
            ),
            storageScope: .init(
                apiKey: "pk_test_scoped",
                environment: .development
            ),
            customStoragePath: directory
        )

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: legacyCache.path)
        )
        _ = service
    }

    private func makeService(
        cache: any CachedProfileStore,
        identity: MockIdentityService,
        api: ProfileFetching,
        experiences: MockExperienceService,
        catalog: DeviceLegProfileCatalog,
        runtime: (any DeviceLegProfileConsuming)? = nil,
        sleepProvider: MockSleepProvider = MockSleepProvider(),
        dateProvider: MockDateProvider = MockDateProvider(),
        authorityStore: any ProfileAuthorityBindingStore =
            InMemoryProfileAuthorityBindingStore()
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
            dateProvider: dateProvider,
            sleepProvider: sleepProvider,
            localeProvider: ConfigurationLocaleIdentifierProvider(
                configuredLocale: { "en_US" }
            ),
            authorityStore: authorityStore
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
