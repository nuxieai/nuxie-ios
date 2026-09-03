import CryptoKit
import Foundation
import XCTest
@_spi(Testing) @testable import Nuxie

final class JourneyProfileCatalogTests: XCTestCase {
    private let signingKey = try! Curve25519.Signing.PrivateKey(
        rawRepresentation: Data(repeating: 0x42, count: 32)
    )

    func testPublishesOnlyAfterCompleteAuthenticationAndReplayCommit() async throws {
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let store = InMemoryJourneyReleaseHighWaterStore()
        let catalog = try makeCatalog(fixture, store: store)

        let prepared = try await catalog.prepare(
            fixture.profile,
            authority: fixture.deliveryAuthority
        )
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
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let store = InMemoryJourneyReleaseHighWaterStore()
        let catalog = try makeCatalog(fixture, store: store)
        let prepared = try await catalog.prepare(
            fixture.profile,
            authority: fixture.deliveryAuthority
        )
        let committed = try await catalog.commit(prepared, distinctId: "customer")
        XCTAssertTrue(committed)
        let currentSnapshot = await catalog.snapshot(distinctId: "customer")
        let current = try XCTUnwrap(currentSnapshot)
        let release = try XCTUnwrap(current.releasesByDigest.values.first)
        let key = JourneyReleaseHighWaterKey(
            appId: release.descriptor.identity.appId,
            environment: release.descriptor.identity.environment,
            experienceId: release.descriptor.identity.experienceId
        )
        let storedMark = await store.highWater(for: key)
        let mark = try XCTUnwrap(storedMark)

        do {
            _ = try await catalog.prepare(
                fixture.invalidSignatureProfile(),
                authority: fixture.deliveryAuthority
            )
            XCTFail("Expected invalid signature rejection")
        } catch {
            XCTAssertEqual(
                error as? JourneyReleaseAuthenticationError,
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
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let store = InMemoryJourneyReleaseHighWaterStore()
        let catalog = try makeCatalog(fixture, store: store)
        let prepared = try await catalog.prepare(
            fixture.profile,
            authority: fixture.deliveryAuthority
        )
        let identity = fixture.profile.releases[0].locator.identity
        let key = JourneyReleaseHighWaterKey(
            appId: identity.appId,
            environment: identity.environment,
            experienceId: identity.experienceId
        )
        try await store.admitActiveBatch([key: JourneyReleaseHighWaterMark(
            publishedAtSeq: identity.publishedAtSeq + 1,
            experienceVersionId: "newer-version",
            buildId: "newer-build",
            versionNumber: identity.versionNumber + 1,
            publishedAt: identity.publishedAt,
            descriptorSHA256: String(repeating: "b", count: 64)
        )])

        do {
            _ = try await catalog.commit(prepared, distinctId: "customer")
            XCTFail("Expected stale prepared profile rejection")
        } catch {
            XCTAssertEqual(
                error as? JourneyReleaseAuthenticationError,
                .replayRejected
            )
        }
        let snapshot = await catalog.snapshot(distinctId: "customer")
        XCTAssertNil(snapshot)
    }

    func testContinuationOnlyReleaseRemainsPinnedBehindNewerActiveMark() async throws {
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let store = InMemoryJourneyReleaseHighWaterStore()
        let catalog = try makeCatalog(fixture, store: store)
        let identity = fixture.profile.releases[0].locator.identity
        let key = JourneyReleaseHighWaterKey(
            appId: identity.appId,
            environment: identity.environment,
            experienceId: identity.experienceId
        )
        let newerMark = JourneyReleaseHighWaterMark(
            publishedAtSeq: identity.publishedAtSeq + 1,
            experienceVersionId: "newer-version",
            buildId: "newer-build",
            versionNumber: identity.versionNumber + 1,
            publishedAt: identity.publishedAt,
            descriptorSHA256: String(repeating: "b", count: 64)
        )
        try await store.admitActiveBatch([key: newerMark])

        let prepared = try await catalog.prepare(
            fixture.continuationProfile(),
            authority: fixture.deliveryAuthority
        )
        let committed = try await catalog.commit(prepared, distinctId: "customer")

        XCTAssertTrue(committed)
        let snapshot = await catalog.snapshot(distinctId: "customer")
        XCTAssertEqual(snapshot?.profile.armedLegs.first?.binding.type, .continuation)
        let retainedMark = await store.highWater(for: key)
        XCTAssertEqual(retainedMark, newerMark)
    }

    func testCurrentEnrollmentReentryPolicyWinsOverPinnedContinuation() async throws {
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let originalArm = try XCTUnwrap(fixture.profile.armedLegs.first)
        let current = try updatedRelease(
            fixture: fixture,
            reentry: ["type": "every_time"]
        )
        let continuation = ArmedJourney(
            reference: originalArm.reference,
            binding: .init(
                type: .continuation,
                journeyId: "00000000-0000-7000-8000-000000000001",
                generation: 4
            ),
            entryCondition: originalArm.entryCondition,
            context: originalArm.context
        )
        let enrollment = ArmedJourney(
            reference: current.reference,
            binding: .init(type: .new, journeyId: nil, generation: nil),
            entryCondition: originalArm.entryCondition,
            context: originalArm.context
        )

        for arms in [[continuation, enrollment], [enrollment, continuation]] {
            let catalog = try makeCatalog(
                fixture,
                store: InMemoryJourneyReleaseHighWaterStore()
            )
            let profile = JourneyPlaneProfile(
                schemaVersion: fixture.profile.schemaVersion,
                status: fixture.profile.status,
                delivery: fixture.profile.delivery,
                features: fixture.profile.features,
                facts: fixture.profile.facts,
                armedLegs: arms,
                releases: [current.entry, fixture.profile.releases[0]]
            )
            let prepared = try await catalog.prepare(
                profile,
                authority: fixture.deliveryAuthority
            )
            _ = try await catalog.commit(prepared, distinctId: "customer")
            let committed = await catalog.snapshot(distinctId: "customer")
            let snapshot = try XCTUnwrap(committed)
            let policy = try XCTUnwrap(
                snapshot.liveReentryPolicies[
                    fixture.profile.releases[0].locator.experienceId
                ]
            )

            XCTAssertEqual(policy.type, .everyTime)
            XCTAssertNil(policy.windowSeconds)
        }
    }

    func testReauthenticatesADurableReleaseUnderItsExactPinnedIdentity() async throws {
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let store = InMemoryJourneyReleaseHighWaterStore()
        let catalog = try makeCatalog(
            fixture,
            store: store
        )
        let entry = try XCTUnwrap(fixture.profile.releases.first)
        let reference = try XCTUnwrap(fixture.profile.armedLegs.first?.reference)
        let key = JourneyReleaseHighWaterKey(
            appId: entry.locator.appId,
            environment: entry.locator.environment,
            experienceId: entry.locator.experienceId
        )
        let newerMark = JourneyReleaseHighWaterMark(
            publishedAtSeq: entry.locator.publishedAtSeq + 1,
            experienceVersionId: "newer-version",
            buildId: "newer-build",
            versionNumber: entry.locator.versionNumber + 1,
            publishedAt: entry.locator.publishedAt,
            descriptorSHA256: String(repeating: "b", count: 64)
        )
        let prepared = try await catalog.prepare(
            fixture.profile,
            authority: fixture.deliveryAuthority
        )
        _ = try await catalog.commit(prepared, distinctId: "customer")
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
                error as? JourneyReleaseAuthenticationError,
                .invalidDescriptor
            )
        }
    }

    func testTransportAuthorityRejectsAnotherAppsSignedProfileAndRetainedRelease() async throws {
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let catalog = try makeCatalog(
            fixture,
            store: InMemoryJourneyReleaseHighWaterStore()
        )
        let prepared = try await catalog.prepare(
            fixture.profile,
            authority: fixture.deliveryAuthority
        )
        _ = try await catalog.commit(prepared, distinctId: "customer")
        let other = try retainedRelease(
            fixture: fixture,
            appId: "app_other"
        )
        let unboundCatalog = try makeCatalog(
            fixture,
            store: InMemoryJourneyReleaseHighWaterStore()
        )
        let originalArm = try XCTUnwrap(fixture.profile.armedLegs.first)
        let otherProfile = JourneyPlaneProfile(
            schemaVersion: fixture.profile.schemaVersion,
            status: fixture.profile.status,
            delivery: fixture.profile.delivery,
            features: fixture.profile.features,
            facts: fixture.profile.facts,
            armedLegs: [ArmedJourney(
                reference: other.reference,
                binding: originalArm.binding,
                entryCondition: originalArm.entryCondition,
                context: originalArm.context
            )],
            releases: [other.entry]
        )

        do {
            _ = try await unboundCatalog.prepare(
                otherProfile,
                authority: fixture.deliveryAuthority
            )
            XCTFail("Expected transport app authority rejection")
        } catch {
            XCTAssertEqual(
                error as? JourneyReleaseAuthenticationError,
                .invalidDescriptor
            )
        }
        do {
            _ = try await unboundCatalog.authenticatePinnedRelease(
                other.entry,
                reference: other.reference
            )
            XCTFail("Expected unbound retained authority rejection")
        } catch {
            XCTAssertEqual(
                error as? JourneyReleaseAuthenticationError,
                .invalidDescriptor
            )
        }
        do {
            _ = try await catalog.authenticatePinnedRelease(
                other.entry,
                reference: other.reference
            )
            XCTFail("Expected configured app authority rejection")
        } catch {
            XCTAssertEqual(
                error as? JourneyReleaseAuthenticationError,
                .invalidDescriptor
            )
        }
    }

    func testPrepareStrictlyRevalidatesCachedTypedProfile() async throws {
        let fixture = try JourneyPlaneProfileTestFixture.load()
        var malformedRoot = fixture.root
        let arms = try XCTUnwrap(malformedRoot["armedLegs"] as? [[String: Any]])
        malformedRoot["armedLegs"] = arms + arms
        let cachedTypedProfile = try JSONDecoder().decode(
            JourneyPlaneProfile.self,
            from: JSONSerialization.data(withJSONObject: malformedRoot)
        )
        let catalog = try makeCatalog(
            fixture,
            store: InMemoryJourneyReleaseHighWaterStore()
        )

        do {
            _ = try await catalog.prepare(
                cachedTypedProfile,
                authority: fixture.deliveryAuthority
            )
            XCTFail("Expected duplicate cached arm rejection")
        } catch {
            XCTAssertEqual(
                error as? JourneyReleaseAuthenticationError,
                .invalidDescriptor
            )
        }
    }

    func testProfileCannotRewriteTheSignedLegEntryCondition() async throws {
        let fixture = try JourneyPlaneProfileTestFixture.load()
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
            store: InMemoryJourneyReleaseHighWaterStore()
        )

        do {
            _ = try await catalog.prepare(
                profile,
                authority: fixture.deliveryAuthority
            )
            XCTFail("Expected signed entry-condition mismatch rejection")
        } catch {
            XCTAssertEqual(
                error as? JourneyReleaseAuthenticationError,
                .invalidDescriptor
            )
        }
    }

    func testPrepareRequiresTheExactAuthenticatedFactReferenceUnion() async throws {
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let updated = try updatedRelease(
            fixture: fixture,
            reentry: ["type": "one_time"],
            factReferences: [
                "propertyKeys": ["plan"],
                "segmentIds": [],
                "experimentIds": [],
            ],
            entryCondition: [
                "type": "app_foregrounded",
                "condition": [
                    "ir_version": 1,
                    "expr": [
                        "type": "User",
                        "op": "is_set",
                        "key": "plan",
                    ],
                ],
            ]
        )
        let originalArm = try XCTUnwrap(fixture.profile.armedLegs.first)
        let entryCondition = JourneyEntryCondition(
            type: .appForegrounded,
            eventName: nil,
            segmentId: nil,
            member: nil,
            condition: IREnvelope(
                ir_version: 1,
                engine_min: nil,
                compiled_at: nil,
                expr: .user(op: "is_set", key: "plan", value: nil)
            )
        )
        let arm = ArmedJourney(
            reference: updated.reference,
            binding: originalArm.binding,
            entryCondition: entryCondition,
            context: originalArm.context
        )
        func profile(facts: JourneyFactTable) -> JourneyPlaneProfile {
            JourneyPlaneProfile(
                schemaVersion: fixture.profile.schemaVersion,
                status: fixture.profile.status,
                delivery: fixture.profile.delivery,
                features: fixture.profile.features,
                facts: facts,
                armedLegs: [arm],
                releases: [updated.entry]
            )
        }
        let matchingFacts = JourneyFactTable(
            properties: [
                "plan": .init(present: true, value: AnyCodable("pro"))
            ],
            memberships: [:],
            assignments: [:]
        )
        let catalog = try makeCatalog(
            fixture,
            store: InMemoryJourneyReleaseHighWaterStore()
        )
        _ = try await catalog.prepare(
            profile(facts: matchingFacts),
            authority: fixture.deliveryAuthority
        )

        let invalidFacts = [
            JourneyFactTable(
                properties: [:],
                memberships: matchingFacts.memberships,
                assignments: matchingFacts.assignments
            ),
            JourneyFactTable(
                properties: [
                    "plan": .init(
                        present: true,
                        value: AnyCodable("pro")
                    ),
                    "unreferenced": .init(
                        present: true,
                        value: AnyCodable(true)
                    ),
                ],
                memberships: matchingFacts.memberships,
                assignments: matchingFacts.assignments
            ),
        ]
        for facts in invalidFacts {
            do {
                _ = try await catalog.prepare(
                    profile(facts: facts),
                    authority: fixture.deliveryAuthority
                )
                XCTFail("Expected non-exact fact projection rejection")
            } catch {
                XCTAssertEqual(
                    error as? JourneyReleaseAuthenticationError,
                    .invalidDescriptor
                )
            }
        }
    }

    func testCachedProfileRoundTripsCanonicalPlaneValues() throws {
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let cached = CachedProfile(
            response: ProfileResponse(planeProfile: fixture.profile),
            distinctId: "customer",
            cachedAt: Date(timeIntervalSince1970: 1_000),
            validator: ProfileCacheValidator(
                rawValue: "\"profile\"",
                authority: fixture.deliveryAuthority
            ),
            locale: "en_US"
        )
        let decoded = try JSONDecoder().decode(
            CachedProfile.self,
            from: JSONEncoder().encode(cached)
        )
        XCTAssertEqual(decoded.response.planeProfile.armedLegs.count, 1)
        XCTAssertEqual(decoded.response.planeProfile.facts.properties.count, 0)
        XCTAssertEqual(decoded.response.planeProfile.releases.count, 1)
        XCTAssertEqual(decoded.validator?.authority, fixture.deliveryAuthority)
    }

    func testEmptyCanonicalProfileRejectsMalformedCachedAuthority() async throws {
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let empty = JourneyPlaneProfile(
            schemaVersion: fixture.profile.schemaVersion,
            status: fixture.profile.status,
            delivery: fixture.profile.delivery,
            features: fixture.profile.features,
            facts: fixture.profile.facts,
            armedLegs: [],
            releases: []
        )
        let catalog = try makeCatalog(
            fixture,
            store: InMemoryJourneyReleaseHighWaterStore()
        )

        do {
            _ = try await catalog.prepare(
                empty,
                authority: ProfileDeliveryAuthority(
                    appId: "app\u{0001}poison",
                    environment: "live"
                )
            )
            XCTFail("Expected malformed transport authority rejection")
        } catch {
            XCTAssertEqual(
                error as? JourneyReleaseAuthenticationError,
                .invalidDescriptor
            )
        }
    }

    func testProfileCacheNamespaceIsCredentialAndEnvironmentScoped() {
        let first = ProfileStorageScope(
            apiKey: "pk_live_first_secret",
            environment: .production
        )
        let second = ProfileStorageScope(
            apiKey: "pk_live_second_secret",
            environment: .production
        )
        let development = ProfileStorageScope(
            apiKey: "pk_live_first_secret",
            environment: .development
        )

        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(first, development)
        XCTAssertFalse(first.cacheSubdirectory.contains("first_secret"))
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

    private func retainedRelease(
        fixture: JourneyPlaneProfileTestFixture,
        appId: String
    ) throws -> (
        entry: JourneyReleaseProfileEntry,
        reference: ArmedJourney.Reference
    ) {
        let original = try XCTUnwrap(fixture.profile.releases.first)
        let descriptorBytes = try XCTUnwrap(
            Data(base64Encoded: original.envelope.descriptorBytesBase64)
        )
        var descriptor = try XCTUnwrap(
            JSONSerialization.jsonObject(with: descriptorBytes)
                as? [String: Any]
        )
        var identity = try XCTUnwrap(
            descriptor["identity"] as? [String: Any]
        )
        identity["appId"] = appId
        descriptor["identity"] = identity
        let resignedBytes = try JSONSerialization.data(
            withJSONObject: descriptor
        )
        let descriptorSHA256 = SHA256Provider.hexDigest(resignedBytes)
        let signature = try signingKey.signature(
            for: Data(JourneyReleaseDescriptor.signatureDomain.utf8)
                + resignedBytes
        )
        let entry = JourneyReleaseProfileEntry(
            locator: .init(
                appId: appId,
                environment: original.locator.environment,
                experienceId: original.locator.experienceId,
                experienceVersionId: original.locator.experienceVersionId,
                versionNumber: original.locator.versionNumber,
                buildId: original.locator.buildId,
                publishedAt: original.locator.publishedAt,
                publishedAtSeq: original.locator.publishedAtSeq,
                legId: original.locator.legId
            ),
            envelope: .init(
                mediaType: JourneyReleaseDescriptor.mediaType,
                encoding: "base64",
                descriptorSha256: descriptorSHA256,
                descriptorSizeBytes: resignedBytes.count,
                descriptorBytesBase64: resignedBytes.base64EncodedString(),
                signature: .init(
                    version: 1,
                    algorithm: "ed25519",
                    keyId: "TEST_ONLY_DEV_KEYPAIR",
                    signatureBase64: signature.base64EncodedString()
                )
            )
        )
        return (
            entry,
            .init(
                experienceId: original.locator.experienceId,
                versionId: original.locator.experienceVersionId,
                legId: original.locator.legId,
                descriptorSha256: descriptorSHA256
            )
        )
    }

    private func updatedRelease(
        fixture: JourneyPlaneProfileTestFixture,
        reentry: [String: Any],
        factReferences: [String: Any]? = nil,
        entryCondition: [String: Any]? = nil
    ) throws -> (
        entry: JourneyReleaseProfileEntry,
        reference: ArmedJourney.Reference
    ) {
        let original = try XCTUnwrap(fixture.profile.releases.first)
        let descriptorBytes = try XCTUnwrap(
            Data(base64Encoded: original.envelope.descriptorBytesBase64)
        )
        var descriptor = try XCTUnwrap(
            JSONSerialization.jsonObject(with: descriptorBytes)
                as? [String: Any]
        )
        var identity = try XCTUnwrap(
            descriptor["identity"] as? [String: Any]
        )
        identity["experienceVersionId"] = "version_current"
        identity["versionNumber"] = original.locator.versionNumber + 1
        identity["buildId"] = "build_current"
        identity["publishedAt"] = "2026-08-30T12:00:00.000Z"
        identity["publishedAtSeq"] = original.locator.publishedAtSeq + 1
        descriptor["identity"] = identity
        var leg = try XCTUnwrap(descriptor["leg"] as? [String: Any])
        leg["reentry"] = reentry
        if let factReferences {
            leg["facts"] = factReferences
        }
        if let entryCondition {
            leg["entryCondition"] = entryCondition
        }
        descriptor["leg"] = leg
        let resignedBytes = try JSONSerialization.data(
            withJSONObject: descriptor
        )
        let descriptorSHA256 = SHA256Provider.hexDigest(resignedBytes)
        let signature = try signingKey.signature(
            for: Data(JourneyReleaseDescriptor.signatureDomain.utf8)
                + resignedBytes
        )
        let entry = JourneyReleaseProfileEntry(
            locator: .init(
                appId: original.locator.appId,
                environment: original.locator.environment,
                experienceId: original.locator.experienceId,
                experienceVersionId: "version_current",
                versionNumber: original.locator.versionNumber + 1,
                buildId: "build_current",
                publishedAt: "2026-08-30T12:00:00.000Z",
                publishedAtSeq: original.locator.publishedAtSeq + 1,
                legId: original.locator.legId
            ),
            envelope: .init(
                mediaType: JourneyReleaseDescriptor.mediaType,
                encoding: "base64",
                descriptorSha256: descriptorSHA256,
                descriptorSizeBytes: resignedBytes.count,
                descriptorBytesBase64: resignedBytes.base64EncodedString(),
                signature: .init(
                    version: 1,
                    algorithm: "ed25519",
                    keyId: "TEST_ONLY_DEV_KEYPAIR",
                    signatureBase64: signature.base64EncodedString()
                )
            )
        )
        return (
            entry,
            .init(
                experienceId: entry.locator.experienceId,
                versionId: entry.locator.experienceVersionId,
                legId: entry.locator.legId,
                descriptorSha256: descriptorSHA256
            )
        )
    }
}
