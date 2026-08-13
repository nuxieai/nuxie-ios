import Foundation
import Quick
import Nimble
@testable import Nuxie
@testable import NuxieTestSupport

final class ProfileServiceCacheTests: AsyncSpec {
    override class func spec() {
        describe("ProfileService cache identity checks") {
            var mockFactory: MockFactory!
            var profileService: ProfileService!

            beforeEach {
                mockFactory = MockFactory.shared
                mockFactory.experienceService.reset()
                profileService = ProfileService(
                    cache: InMemoryCachedProfileStore(ttl: nil),
                    identity: mockFactory.identityService,
                    api: mockFactory.nuxieApi,
                    segments: mockFactory.segmentService,
                    experiences: mockFactory.experienceService,
                    eventLog: mockFactory.eventLog,
                    dateProvider: mockFactory.dateProvider,
                    sleepProvider: mockFactory.sleepProvider,
                    localeProvider: ConfigurationLocaleIdentifierProvider(
                        configuredLocale: { "en_US" }
                    )
                )
            }

            it("does not return another user's memory-cached profile") {
                mockFactory.identityService.setDistinctId("user-a")
                await mockFactory.nuxieApi.setProfileResponse(Self.makeProfile(experienceId: "experience-a"))
                _ = try await profileService.refetchProfile(distinctId: "user-a")

                let cached = await profileService.getCachedProfile(distinctId: "user-b")

                expect(cached).to(beNil())
            }

            it("refetches when the requested distinctId differs from the memory cache") {
                mockFactory.identityService.setDistinctId("user-a")
                await mockFactory.nuxieApi.setProfileResponse(Self.makeProfile(experienceId: "experience-a"))
                let initialFetchCount = await mockFactory.nuxieApi.fetchProfileCallCount
                let first = try await profileService.refetchProfile(distinctId: "user-a")

                mockFactory.identityService.setDistinctId("user-b")
                await mockFactory.nuxieApi.setProfileResponse(Self.makeProfile(experienceId: "experience-b"))
                let second = try await profileService.refetchProfile(distinctId: "user-b")

                expect(first.releases?.active.first?.locator.experienceId)
                    .to(equal("experience-a"))
                expect(second.releases?.active.first?.locator.experienceId)
                    .to(equal("experience-b"))
                await expect { await mockFactory.nuxieApi.fetchProfileCallCount }.to(equal(initialFetchCount + 2))
            }

            it("uses its injected locale without SDK singleton setup") {
                mockFactory.identityService.setDistinctId("locale-user")

                _ = try await profileService.refetchProfile(distinctId: "locale-user")

                await expect { await mockFactory.nuxieApi.lastProfileLocale }
                    .to(equal("en_US"))
            }

            it("re-registers signed releases from the disk cache before use") {
                let cache = InMemoryCachedProfileStore(ttl: nil)
                let profile = Self.makeProfile(
                    experienceId: "cached-release",
                    releases: Self.releaseProfile(
                        experienceId: "cached-release",
                        versionId: "flow-cached-release"
                    )
                )
                mockFactory.identityService.setDistinctId("cached-user")
                try await cache.store(
                    CachedProfile(
                        response: profile,
                        distinctId: "cached-user",
                        cachedAt: Date()
                    ),
                    forKey: "cached-user"
                )
                profileService = ProfileService(
                    cache: cache,
                    identity: mockFactory.identityService,
                    api: mockFactory.nuxieApi,
                    segments: mockFactory.segmentService,
                    experiences: mockFactory.experienceService,
                    eventLog: mockFactory.eventLog,
                    dateProvider: mockFactory.dateProvider,
                    sleepProvider: mockFactory.sleepProvider,
                    localeProvider: ConfigurationLocaleIdentifierProvider(
                        configuredLocale: { "en_US" }
                    )
                )

                _ = await profileService.getCachedProfile(distinctId: "cached-user")

                expect(mockFactory.experienceService.releaseProfiles.last ?? nil)
                    .to(equal(profile.releases))
                expect(mockFactory.experienceService.prefetchedExperiences).to(beEmpty())
            }

            it("evicts an unauthentic cached release and recovers from the network") {
                let cache = InMemoryCachedProfileStore(ttl: nil)
                let distinctId = "cache-recovery-user"
                let invalidCached = Self.makeProfile(
                    experienceId: "poisoned-cache",
                    releases: Self.releaseProfile(
                        experienceId: "poisoned-cache",
                        versionId: "poisoned-version"
                    )
                )
                let validNetwork = Self.makeProfile(
                    experienceId: "recovered-network",
                    releases: Self.releaseProfile(
                        experienceId: "recovered-network",
                        versionId: "recovered-version"
                    )
                )
                try await cache.store(
                    CachedProfile(
                        response: invalidCached,
                        distinctId: distinctId,
                        cachedAt: Date()
                    ),
                    forKey: distinctId
                )
                mockFactory.identityService.setDistinctId(distinctId)
                mockFactory.experienceService.releaseProfileFailuresRemaining = 1
                mockFactory.experienceService.authenticatedReleaseReferences = [
                    ExperienceReference(
                        experienceId: "recovered-network",
                        versionId: "recovered-version"
                    )
                ]
                await mockFactory.nuxieApi.setProfileResponse(validNetwork)
                profileService = ProfileService(
                    cache: cache,
                    identity: mockFactory.identityService,
                    api: mockFactory.nuxieApi,
                    segments: mockFactory.segmentService,
                    experiences: mockFactory.experienceService,
                    eventLog: mockFactory.eventLog,
                    dateProvider: mockFactory.dateProvider,
                    sleepProvider: mockFactory.sleepProvider,
                    localeProvider: ConfigurationLocaleIdentifierProvider(
                        configuredLocale: { "en_US" }
                    )
                )

                let recovered = await profileService.getCachedProfile(
                    distinctId: distinctId
                )

                expect(recovered?.releases?.active.first?.locator.experienceId)
                    .to(equal("recovered-network"))
                await expect { await mockFactory.nuxieApi.fetchProfileCallCount }
                    .toEventually(beGreaterThan(0))
                let stored = await cache.retrieve(
                    forKey: distinctId,
                    allowStale: true
                )
                expect(stored?.response.releases?.active.first?.locator.experienceId)
                    .to(equal("recovered-network"))
                let effective = await profileService.getEffectiveExperienceReferences(
                    distinctId: distinctId
                )
                expect(effective).to(equal([ExperienceReference(
                    experienceId: "recovered-network",
                    versionId: "recovered-version"
                )]))
            }

            it("does not clear a new user's profile when old cached authentication resumes") {
                let cache = InMemoryCachedProfileStore(ttl: nil)
                let oldId = "old-cache-user"
                let newId = "new-cache-user"
                try await cache.store(
                    CachedProfile(
                        response: Self.makeProfile(
                            experienceId: "old-poison",
                            releases: Self.releaseProfile(
                                experienceId: "old-poison",
                                versionId: "old-version"
                            )
                        ),
                        distinctId: oldId,
                        cachedAt: Date()
                    ),
                    forKey: oldId
                )
                let newRelease = Self.releaseProfile(
                    experienceId: "new-valid",
                    versionId: "new-valid-version"
                )
                let newProfile = Self.makeProfile(
                    experienceId: "new-valid",
                    releases: newRelease
                )
                try await cache.store(
                    CachedProfile(
                        response: newProfile,
                        distinctId: newId,
                        cachedAt: Date()
                    ),
                    forKey: newId
                )
                let gate = ReleaseProfileAuthenticationGate()
                mockFactory.identityService.setDistinctId(oldId)
                mockFactory.experienceService.releaseProfileFailuresRemaining = 1
                mockFactory.experienceService.authenticatedReleaseReferences = [
                    ExperienceReference(
                        experienceId: "new-valid",
                        versionId: "new-valid-version"
                    )
                ]
                mockFactory.experienceService.releaseProfileAuthenticationGate = gate
                profileService = ProfileService(
                    cache: cache,
                    identity: mockFactory.identityService,
                    api: mockFactory.nuxieApi,
                    segments: mockFactory.segmentService,
                    experiences: mockFactory.experienceService,
                    eventLog: mockFactory.eventLog,
                    dateProvider: mockFactory.dateProvider,
                    sleepProvider: mockFactory.sleepProvider,
                    localeProvider: ConfigurationLocaleIdentifierProvider(
                        configuredLocale: { "en_US" }
                    )
                )

                let oldLoad = Task {
                    await profileService.getCachedProfile(distinctId: oldId)
                }
                await gate.waitUntilSuspended()
                mockFactory.identityService.setDistinctId(newId)
                await profileService.handleUserChange(from: oldId, to: newId)
                await gate.resume()
                _ = await oldLoad.value

                let retained = await profileService.getCachedProfile(distinctId: newId)
                expect(retained?.releases?.active.first?.locator.experienceId)
                    .to(equal("new-valid"))
                let newEffective = await profileService
                    .getEffectiveExperienceReferences(distinctId: newId)
                expect(newEffective).to(equal([ExperienceReference(
                    experienceId: "new-valid",
                    versionId: "new-valid-version"
                )]))
                expect(mockFactory.experienceService.releaseProfiles.last ?? nil)
                    .to(equal(newRelease))
                let evictedOld = await cache.retrieve(
                    forKey: oldId,
                    allowStale: true
                )
                expect(evictedOld).to(beNil())
            }

            it("does not retry a poisoned cached release after network recovery fails") {
                let cache = InMemoryCachedProfileStore(ttl: nil)
                let distinctId = "offline-poison-user"
                let poisoned = Self.makeProfile(
                    experienceId: "offline-poison",
                    releases: Self.releaseProfile(
                        experienceId: "offline-poison",
                        versionId: "offline-poison-version"
                    )
                )
                try await cache.store(
                    CachedProfile(
                        response: poisoned,
                        distinctId: distinctId,
                        cachedAt: Date()
                    ),
                    forKey: distinctId
                )
                mockFactory.identityService.setDistinctId(distinctId)
                mockFactory.experienceService.releaseProfileFailuresRemaining = 1
                await mockFactory.nuxieApi.setShouldFailProfile(true)
                profileService = ProfileService(
                    cache: cache,
                    identity: mockFactory.identityService,
                    api: mockFactory.nuxieApi,
                    segments: mockFactory.segmentService,
                    experiences: mockFactory.experienceService,
                    eventLog: mockFactory.eventLog,
                    dateProvider: mockFactory.dateProvider,
                    sleepProvider: mockFactory.sleepProvider,
                    localeProvider: ConfigurationLocaleIdentifierProvider(
                        configuredLocale: { "en_US" }
                    )
                )

                let cached = await profileService.getCachedProfile(
                    distinctId: distinctId
                )
                expect(cached).to(beNil())
                let removed = await cache.retrieve(
                    forKey: distinctId,
                    allowStale: true
                )
                expect(removed).to(beNil())
                let effective = await profileService.getEffectiveExperienceReferences(
                    distinctId: distinctId
                )
                let active = await profileService.getActiveExperienceReferences(
                    distinctId: distinctId
                )
                expect(effective).to(beNil())
                expect(active).to(beNil())
                let authenticationAttempts = mockFactory.experienceService
                    .releaseProfiles.compactMap { $0 }.count
                expect(authenticationAttempts).to(equal(1))

                profileService = ProfileService(
                    cache: cache,
                    identity: mockFactory.identityService,
                    api: mockFactory.nuxieApi,
                    segments: mockFactory.segmentService,
                    experiences: mockFactory.experienceService,
                    eventLog: mockFactory.eventLog,
                    dateProvider: mockFactory.dateProvider,
                    sleepProvider: mockFactory.sleepProvider,
                    localeProvider: ConfigurationLocaleIdentifierProvider(
                        configuredLocale: { "en_US" }
                    )
                )
                let recreatedCached = await profileService.getCachedProfile(
                    distinctId: distinctId
                )
                expect(recreatedCached).to(beNil())
                expect(mockFactory.experienceService.releaseProfiles.compactMap { $0 }.count)
                    .to(equal(authenticationAttempts))
            }

            it("clears stale signed release authority when a network profile omits releases") {
                mockFactory.identityService.setDistinctId("network-user")
                await mockFactory.nuxieApi.setProfileResponse(
                    Self.makeProfile(
                        experienceId: "with-release",
                        releases: Self.releaseProfile()
                    )
                )
                _ = try await profileService.refetchProfile(distinctId: "network-user")
                await mockFactory.nuxieApi.setProfileResponse(
                    Self.makeProfile(experienceId: "without-release")
                )

                _ = try await profileService.refetchProfile(distinctId: "network-user")

                expect(mockFactory.experienceService.releaseProfiles.last ?? nil).to(beNil())
                expect(mockFactory.experienceService.prefetchedExperiences).to(beEmpty())
            }

            it("routes only authenticated release identities over conflicting legacy metadata") {
                mockFactory.identityService.setDistinctId("authority-user")
                let legacy = Self.makeProfile(
                    experienceId: "signed-experience",
                    releases: Self.releaseProfile(
                        experienceId: "signed-experience",
                        versionId: "signed-version"
                    )
                )
                let authenticated = ExperienceReference(
                    experienceId: "signed-experience",
                    versionId: "signed-version"
                )
                mockFactory.experienceService.authenticatedReleaseReferences = [authenticated]
                await mockFactory.nuxieApi.setProfileResponse(legacy)

                _ = try await profileService.refetchProfile(distinctId: "authority-user")

                let effective = await profileService.getEffectiveExperienceReferences(
                    distinctId: "authority-user"
                )
                expect(effective?.map(\.experienceId)).to(equal(["signed-experience"]))
                expect(effective?.map(\.versionId)).to(equal(["signed-version"]))
            }

            it("registers a release-only network profile with no legacy experience") {
                mockFactory.identityService.setDistinctId("release-only-user")
                let releases = Self.releaseProfile(
                    experienceId: "release-only",
                    versionId: "release-only-version"
                )
                let authenticated = ExperienceReference(
                    experienceId: "release-only",
                    versionId: "release-only-version"
                )
                mockFactory.experienceService.authenticatedReleaseReferences = [authenticated]
                let response = ProfileResponse(
                    segments: [],
                    releases: releases,
                    userProperties: nil,
                    experiments: nil,
                    features: nil
                )
                await mockFactory.nuxieApi.setProfileResponse(response)

                _ = try await profileService.refetchProfile(distinctId: "release-only-user")

                let effective = await profileService.getEffectiveExperienceReferences(
                    distinctId: "release-only-user"
                )
                expect(effective?.map(\.experienceId)).to(equal(["release-only"]))
                expect(mockFactory.experienceService.prefetchedExperiences).to(beEmpty())
            }

            it("exposes pinned releases for exact lookup but only active releases for enrollment") {
                mockFactory.identityService.setDistinctId("active-pinned-user")
                let releases = Self.releaseProfile(
                    experienceId: "active-release",
                    versionId: "active-version",
                    pinnedExperienceId: "pinned-release",
                    pinnedVersionId: "pinned-version"
                )
                mockFactory.experienceService.authenticatedReleaseReferences = [
                    ExperienceReference(
                        experienceId: "active-release",
                        versionId: "active-version"
                    ),
                    ExperienceReference(
                        experienceId: "pinned-release",
                        versionId: "pinned-version"
                    ),
                ]
                await mockFactory.nuxieApi.setProfileResponse(ProfileResponse(
                    segments: [],
                    releases: releases,
                    userProperties: nil,
                    experiments: nil,
                    features: nil
                ))

                _ = try await profileService.refetchProfile(distinctId: "active-pinned-user")

                let all = await profileService.getEffectiveExperienceReferences(
                    distinctId: "active-pinned-user"
                )
                let active = await profileService.getActiveExperienceReferences(
                    distinctId: "active-pinned-user"
                )
                expect(Set(all ?? [])).to(equal(Set([
                    ExperienceReference(
                        experienceId: "active-release",
                        versionId: "active-version"
                    ),
                    ExperienceReference(
                        experienceId: "pinned-release",
                        versionId: "pinned-version"
                    ),
                ])))
                expect(active).to(equal([ExperienceReference(
                    experienceId: "active-release",
                    versionId: "active-version"
                )]))
            }
        }
    }

    private static func makeProfile(
        experienceId: String,
        releases: ExperienceReleaseProfileV1? = nil
    ) -> ProfileResponse {
        return ProfileResponse(
            segments: [],
            releases: releases ?? releaseProfile(
                experienceId: experienceId,
                versionId: "flow-\(experienceId)"
            ),
            userProperties: nil,
            experiments: nil,
            features: nil
        )
    }

    private static func releaseProfile(
        experienceId: String = "experience_release",
        versionId: String = "version_release",
        pinnedExperienceId: String? = nil,
        pinnedVersionId: String? = nil
    ) -> ExperienceReleaseProfileV1 {
        let digest = String(repeating: "a", count: 64)
        func entry(experienceId: String, versionId: String) -> ExperienceReleaseProfileEntryV1 {
            ExperienceReleaseProfileEntryV1(
            locator: .init(
                appId: "app_test",
                environment: "test",
                experienceId: experienceId,
                experienceVersionId: versionId,
                buildId: "build_release",
                versionNumber: 1,
                publishedAt: "2026-08-12T00:00:00Z",
                publishedAtSeq: 1
            ),
            descriptorSha256: digest,
            envelopeBytes: try! JSONEncoder().encode(ExperienceReleaseDescriptorEnvelopeV1(
                mediaType: ExperienceReleaseDescriptorLimits.mediaType,
                encoding: "base64",
                descriptorSha256: digest,
                descriptorSizeBytes: 2,
                descriptorBytesBase64: "e30=",
                signature: .init(
                    version: 1,
                    algorithm: "ed25519",
                    keyId: "test",
                    signatureBase64: "signature"
                )
            ))
            )
        }
        let activeEntry = entry(experienceId: experienceId, versionId: versionId)
        let pinnedEntry: ExperienceReleaseProfileEntryV1? = if let pinnedExperienceId,
                                                               let pinnedVersionId {
            entry(experienceId: pinnedExperienceId, versionId: pinnedVersionId)
        } else {
            nil
        }
        return .init(
            delivery: .init(
                renderBaseUrl: "https://cdn.nuxie.test/renders/",
                assetBaseUrl: "https://cdn.nuxie.test/assets/"
            ),
            active: [activeEntry],
            pinned: pinnedEntry.map { [$0] } ?? []
        )
    }
}
