import Foundation
import XCTest
@_spi(Testing) @testable import Nuxie

final class DeviceLegProfileCatalogTests: XCTestCase {
    func testPublishesOnlyAfterCompleteAuthenticationAndReplayCommit() async throws {
        let fixture = try DeviceLegPlaneProfileTestFixture.load()
        let store = InMemoryExperienceReleaseHighWaterStore()
        let catalog = try makeCatalog(fixture, store: store)

        let prepared = try await catalog.prepare(fixture.profile)
        let beforeCommit = await catalog.snapshot(distinctId: "customer")
        XCTAssertNil(beforeCommit)
        let committed = try await catalog.commit(prepared, distinctId: "customer")
        XCTAssertTrue(committed)

        let committedSnapshot = await catalog.snapshot(distinctId: "customer")
        let snapshot = try XCTUnwrap(committedSnapshot)
        let release = try XCTUnwrap(snapshot.releasesByDigest.values.first)
        XCTAssertEqual(snapshot.profile.armedLegs.count, 1)
        XCTAssertEqual(snapshot.releasesByDigest.count, 1)
        XCTAssertEqual(release.descriptor.leg.id, fixture.profile.releases[0].locator.legId)
        let other = await catalog.snapshot(distinctId: "other")
        XCTAssertNil(other)
    }

    func testRejectedReplacementLeavesCurrentSnapshotAndReplayMarkUnchanged() async throws {
        let fixture = try DeviceLegPlaneProfileTestFixture.load()
        let store = InMemoryExperienceReleaseHighWaterStore()
        let catalog = try makeCatalog(fixture, store: store)
        let prepared = try await catalog.prepare(fixture.profile)
        let committed = try await catalog.commit(prepared, distinctId: "customer")
        XCTAssertTrue(committed)
        let currentSnapshot = await catalog.snapshot(distinctId: "customer")
        let current = try XCTUnwrap(currentSnapshot)
        let release = try XCTUnwrap(current.releasesByDigest.values.first)
        let key = ExperienceReleaseHighWaterKey(
            appId: release.descriptor.identity.appId,
            environment: release.descriptor.identity.environment,
            experienceId: release.descriptor.identity.experienceId
        )
        let storedMark = await store.highWater(for: key)
        let mark = try XCTUnwrap(storedMark)

        do {
            _ = try await catalog.prepare(fixture.invalidSignatureProfile())
            XCTFail("Expected invalid signature rejection")
        } catch {
            XCTAssertEqual(
                error as? ExperienceReleaseDescriptorAuthenticationError,
                .invalidSignature
            )
        }
        let retainedSnapshot = await catalog.snapshot(distinctId: "customer")
        let retained = try XCTUnwrap(retainedSnapshot)
        XCTAssertEqual(retained.releasesByDigest.keys, current.releasesByDigest.keys)
        let retainedMark = await store.highWater(for: key)
        XCTAssertEqual(retainedMark, mark)
    }

    func testPreparedProfileCannotReplaceANewerReplayMark() async throws {
        let fixture = try DeviceLegPlaneProfileTestFixture.load()
        let store = InMemoryExperienceReleaseHighWaterStore()
        let catalog = try makeCatalog(fixture, store: store)
        let prepared = try await catalog.prepare(fixture.profile)
        let identity = fixture.profile.releases[0].locator.identity
        let key = ExperienceReleaseHighWaterKey(
            appId: identity.appId,
            environment: identity.environment,
            experienceId: identity.experienceId
        )
        try await store.admitActiveBatch([key: ExperienceReleaseHighWaterMark(
            releaseSequence: identity.releaseSequence + 1,
            experienceVersionId: "newer-version",
            buildId: "newer-build",
            versionNumber: identity.versionNumber + 1,
            releaseCreatedAt: identity.releaseCreatedAt,
            descriptorSHA256: String(repeating: "b", count: 64)
        )])

        do {
            _ = try await catalog.commit(prepared, distinctId: "customer")
            XCTFail("Expected stale prepared profile rejection")
        } catch {
            XCTAssertEqual(
                error as? ExperienceReleaseDescriptorAuthenticationError,
                .replayRejected
            )
        }
        let snapshot = await catalog.snapshot(distinctId: "customer")
        XCTAssertNil(snapshot)
    }

    func testContinuationOnlyReleaseRemainsPinnedBehindNewerActiveMark() async throws {
        let fixture = try DeviceLegPlaneProfileTestFixture.load()
        let store = InMemoryExperienceReleaseHighWaterStore()
        let catalog = try makeCatalog(fixture, store: store)
        let identity = fixture.profile.releases[0].locator.identity
        let key = ExperienceReleaseHighWaterKey(
            appId: identity.appId,
            environment: identity.environment,
            experienceId: identity.experienceId
        )
        let newerMark = ExperienceReleaseHighWaterMark(
            releaseSequence: identity.releaseSequence + 1,
            experienceVersionId: "newer-version",
            buildId: "newer-build",
            versionNumber: identity.versionNumber + 1,
            releaseCreatedAt: identity.releaseCreatedAt,
            descriptorSHA256: String(repeating: "b", count: 64)
        )
        try await store.admitActiveBatch([key: newerMark])

        let prepared = try await catalog.prepare(fixture.continuationProfile())
        let committed = try await catalog.commit(prepared, distinctId: "customer")

        XCTAssertTrue(committed)
        let snapshot = await catalog.snapshot(distinctId: "customer")
        XCTAssertEqual(snapshot?.profile.armedLegs.first?.binding.type, .continuation)
        let retainedMark = await store.highWater(for: key)
        XCTAssertEqual(retainedMark, newerMark)
    }

    func testReauthenticatesADurableReleaseUnderItsExactPinnedIdentity() async throws {
        let fixture = try DeviceLegPlaneProfileTestFixture.load()
        let store = InMemoryExperienceReleaseHighWaterStore()
        let catalog = try makeCatalog(
            fixture,
            store: store
        )
        let entry = try XCTUnwrap(fixture.profile.releases.first)
        let reference = try XCTUnwrap(fixture.profile.armedLegs.first?.reference)
        let key = ExperienceReleaseHighWaterKey(
            appId: entry.locator.appId,
            environment: entry.locator.environment,
            experienceId: entry.locator.experienceId
        )
        let newerMark = ExperienceReleaseHighWaterMark(
            publishedAtSeq: entry.locator.publishedAtSeq + 1,
            experienceVersionId: "newer-version",
            buildId: "newer-build",
            versionNumber: entry.locator.versionNumber + 1,
            publishedAt: entry.locator.publishedAt,
            descriptorSHA256: String(repeating: "b", count: 64)
        )
        try await store.admitActiveBatch([key: newerMark])

        let release = try await catalog.authenticatePinnedRelease(
            entry,
            reference: reference
        )

        XCTAssertEqual(release.descriptorSHA256, reference.descriptorSha256)
        XCTAssertEqual(release.descriptor.identity, entry.locator.identity)
        XCTAssertEqual(release.descriptor.leg.id, reference.legId)
        XCTAssertNil(release.publishedAtSeqToPromote)
        let retainedMark = await store.highWater(for: key)
        XCTAssertEqual(retainedMark, newerMark)

        do {
            _ = try await catalog.authenticatePinnedRelease(
                entry,
                reference: .init(
                    experienceId: reference.experienceId,
                    versionId: "other-version",
                    legId: reference.legId,
                    descriptorSha256: reference.descriptorSha256
                )
            )
            XCTFail("Expected retained release linkage rejection")
        } catch {
            XCTAssertEqual(
                error as? ExperienceReleaseDescriptorAuthenticationError,
                .invalidDescriptor
            )
        }
    }

    func testPrepareStrictlyRevalidatesCachedTypedProfile() async throws {
        let fixture = try DeviceLegPlaneProfileTestFixture.load()
        var malformedRoot = fixture.root
        let arms = try XCTUnwrap(malformedRoot["armedLegs"] as? [[String: Any]])
        malformedRoot["armedLegs"] = arms + arms
        let cachedTypedProfile = try JSONDecoder().decode(
            JourneyPlaneProfile.self,
            from: JSONSerialization.data(withJSONObject: malformedRoot)
        )
        let catalog = try makeCatalog(
            fixture,
            store: InMemoryExperienceReleaseHighWaterStore()
        )

        do {
            _ = try await catalog.prepare(cachedTypedProfile)
            XCTFail("Expected duplicate cached arm rejection")
        } catch {
            XCTAssertEqual(
                error as? ExperienceReleaseDescriptorAuthenticationError,
                .invalidDescriptor
            )
        }
    }

    func testProfileCannotRewriteTheSignedLegEntryCondition() async throws {
        let fixture = try DeviceLegPlaneProfileTestFixture.load()
        var changedRoot = fixture.root
        var arms = try XCTUnwrap(
            changedRoot["armedLegs"] as? [[String: Any]]
        )
        arms[0]["entryCondition"] = [
            "type": "event",
            "eventName": "rewritten_trigger",
        ]
        changedRoot["armedLegs"] = arms
        let profile = try JourneyPlaneProfile.decode(
            JSONSerialization.data(withJSONObject: changedRoot)
        )
        let catalog = try makeCatalog(
            fixture,
            store: InMemoryExperienceReleaseHighWaterStore()
        )

        do {
            _ = try await catalog.prepare(profile)
            XCTFail("Expected signed entry-condition mismatch rejection")
        } catch {
            XCTAssertEqual(
                error as? ExperienceReleaseDescriptorAuthenticationError,
                .invalidDescriptor
            )
        }
    }

    func testCachedProfileRoundTripsCanonicalPlaneValues() throws {
        let fixture = try DeviceLegPlaneProfileTestFixture.load()
        let cached = CachedProfile(
            response: ProfileResponse(planeProfile: fixture.profile),
            distinctId: "customer",
            cachedAt: Date(timeIntervalSince1970: 1_000),
            locale: "en_US"
        )
        let decoded = try JSONDecoder().decode(
            CachedProfile.self,
            from: JSONEncoder().encode(cached)
        )
        XCTAssertEqual(decoded.response.planeProfile?.armedLegs.count, 1)
        XCTAssertEqual(decoded.response.planeProfile?.facts.properties["ready"]?.present, true)
        XCTAssertNil(decoded.response.releases)
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
