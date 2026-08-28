import Foundation
import Quick
import Nimble
@_spi(Testing) @testable import Nuxie
@testable import NuxieTestSupport

private actor ConditionalProfileAPI: ProfileFetching {
    private let result: ProfileFetchResult
    private(set) var lastValidator: ProfileCacheValidator?

    init(result: ProfileFetchResult) {
        self.result = result
    }

    func fetchProfile(for distinctId: String, locale: String?) async throws -> ProfileResponse {
        switch result {
        case .modified(let profile, _):
            return profile
        case .notModified:
            throw NuxieNetworkError.invalidResponse
        }
    }

    func fetchProfile(
        for distinctId: String,
        locale: String?,
        revalidating validator: ProfileCacheValidator?
    ) async throws -> ProfileFetchResult {
        lastValidator = validator
        return result
    }

    func fetchProfileWithTimeout(
        for distinctId: String,
        locale: String?,
        timeout: TimeInterval
    ) async throws -> ProfileResponse {
        try await fetchProfile(for: distinctId, locale: locale)
    }
}

final class ProfileServiceCacheTests: AsyncSpec {
    override class func spec() {
        describe("ProfileService cache identity checks") {
            var mockFactory: MockFactory!
            var profileService: ProfileService!

            beforeEach {
                mockFactory = MockFactory.shared
                await mockFactory.nuxieApi.reset()
                mockFactory.experienceService.reset()
                await mockFactory.segmentService.reset()
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

            it("cancels a stale fetch without reporting a configuration error") {
                mockFactory.identityService.setDistinctId("user-a")
                await mockFactory.nuxieApi.setProfileDelay(0.1)

                let fetch = Task {
                    try await profileService.refetchProfile(distinctId: "user-a")
                }
                await expect { await mockFactory.nuxieApi.fetchProfileCallCount }
                    .toEventually(equal(1), timeout: .seconds(1))
                mockFactory.identityService.setDistinctId("user-b")

                do {
                    _ = try await fetch.value
                    fail("expected the stale fetch to be cancelled")
                } catch {
                    expect(error).to(beAKindOf(ProfileRefreshCancellationError.self))
                    expect(error).notTo(beAKindOf(NuxieError.self))
                }
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

            it("hydrates membership only from the persisted admitted profile snapshot") {
                let cache = InMemoryCachedProfileStore(ttl: nil)
                let distinctId = "offline-membership-user"
                let segment = Segment(id: "offline-segment", name: "Offline")
                let enteredAt = Date(timeIntervalSince1970: 1_746_178_320)
                let profile = ProfileResponse(
                    segments: [segment],
                    segmentMemberships: SegmentMembershipSeed(
                        evaluatedAt: enteredAt,
                        memberships: [
                            SeededSegmentMembership(
                                segmentId: segment.id,
                                enteredAt: enteredAt
                            )
                        ]
                    )
                )
                try await cache.store(
                    CachedProfile(
                        response: profile,
                        distinctId: distinctId,
                        cachedAt: mockFactory.dateProvider.now()
                    ),
                    forKey: distinctId
                )
                let realSegmentService = SegmentService()
                mockFactory.identityService.setDistinctId(distinctId)
                profileService = ProfileService(
                    cache: cache,
                    identity: mockFactory.identityService,
                    api: mockFactory.nuxieApi,
                    segments: realSegmentService,
                    experiences: mockFactory.experienceService,
                    eventLog: mockFactory.eventLog,
                    dateProvider: mockFactory.dateProvider,
                    sleepProvider: mockFactory.sleepProvider,
                    localeProvider: ConfigurationLocaleIdentifierProvider(
                        configuredLocale: { "en_US" }
                    )
                )

                _ = await profileService.getCachedProfile(distinctId: distinctId)

                await expect { await realSegmentService.isInSegment(segment.id) }
                    .to(beTrue())
                await expect { await realSegmentService.enteredAt(segment.id) }
                    .to(equal(enteredAt))
            }

            it("keeps the newest membership when same-user refreshes complete out of order") {
                let distinctId = "overlapping-membership-user"
                let oldSegment = Segment(id: "old-segment", name: "Old")
                let newSegment = Segment(id: "new-segment", name: "New")
                let gate = ReleaseProfileAuthenticationGate()
                let realSegmentService = SegmentService()
                mockFactory.identityService.setDistinctId(distinctId)
                mockFactory.experienceService.releaseProfileAuthenticationGate = gate
                profileService = ProfileService(
                    cache: InMemoryCachedProfileStore(ttl: nil),
                    identity: mockFactory.identityService,
                    api: mockFactory.nuxieApi,
                    segments: realSegmentService,
                    experiences: mockFactory.experienceService,
                    eventLog: mockFactory.eventLog,
                    dateProvider: mockFactory.dateProvider,
                    sleepProvider: mockFactory.sleepProvider,
                    localeProvider: ConfigurationLocaleIdentifierProvider(
                        configuredLocale: { "en_US" }
                    )
                )
                await mockFactory.nuxieApi.setProfileResponse(ProfileResponse(
                    segments: [oldSegment],
                    releases: Self.releaseProfile(experienceId: "old-release"),
                    segmentMemberships: SegmentMembershipSeed(
                        evaluatedAt: nil,
                        memberships: [SeededSegmentMembership(
                            segmentId: oldSegment.id,
                            enteredAt: Date(timeIntervalSince1970: 10)
                        )]
                    )
                ))
                let service = profileService!
                let olderRefresh = Task {
                    try await service.refetchProfile(distinctId: distinctId)
                }
                await gate.waitUntilSuspended()
                await mockFactory.nuxieApi.setProfileResponse(ProfileResponse(
                    segments: [newSegment],
                    releases: Self.releaseProfile(experienceId: "new-release"),
                    segmentMemberships: SegmentMembershipSeed(
                        evaluatedAt: nil,
                        memberships: [SeededSegmentMembership(
                            segmentId: newSegment.id,
                            enteredAt: Date(timeIntervalSince1970: 20)
                        )]
                    )
                ))

                _ = try await service.refetchProfile(distinctId: distinctId)
                await gate.resume()
                _ = try await olderRefresh.value

                await expect { await realSegmentService.isInSegment(newSegment.id) }
                    .to(beTrue())
                await expect { await realSegmentService.isInSegment(oldSegment.id) }
                    .to(beFalse())
                let cached = await profileService.getCachedProfile(distinctId: distinctId)
                expect(cached?.segments.first?.id).to(equal(newSegment.id))
                expect((mockFactory.experienceService.committedReleaseProfiles.last ?? nil)?
                    .active.first?.locator.experienceId).to(equal("new-release"))
            }

            it("keeps the old complete generation observable while a replacement is suspended") {
                let distinctId = "atomic-admission-user"
                let oldSegment = Segment(id: "atomic-old", name: "Old")
                let newSegment = Segment(id: "atomic-new", name: "New")
                let segments = SegmentService()
                mockFactory.identityService.setDistinctId(distinctId)
                profileService = ProfileService(
                    cache: InMemoryCachedProfileStore(ttl: nil),
                    identity: mockFactory.identityService,
                    api: mockFactory.nuxieApi,
                    segments: segments,
                    experiences: mockFactory.experienceService,
                    eventLog: mockFactory.eventLog,
                    dateProvider: mockFactory.dateProvider,
                    sleepProvider: mockFactory.sleepProvider,
                    localeProvider: ConfigurationLocaleIdentifierProvider(
                        configuredLocale: { "en_US" }
                    )
                )
                let oldProfile = ProfileResponse(
                    segments: [oldSegment],
                    releases: Self.releaseProfile(experienceId: "atomic-old-release"),
                    userProperties: ["profile_generation": AnyCodable("old")],
                    segmentMemberships: SegmentMembershipSeed(
                        evaluatedAt: Date(timeIntervalSince1970: 10),
                        memberships: [SeededSegmentMembership(
                            segmentId: oldSegment.id,
                            enteredAt: Date(timeIntervalSince1970: 5)
                        )]
                    )
                )
                await mockFactory.nuxieApi.setProfileResponse(oldProfile)
                _ = try await profileService.refetchProfile(distinctId: distinctId)

                let gate = ReleaseProfileAuthenticationGate()
                mockFactory.experienceService.releaseProfileAuthenticationGate = gate
                let newProfile = ProfileResponse(
                    segments: [newSegment],
                    releases: Self.releaseProfile(experienceId: "atomic-new-release"),
                    userProperties: ["profile_generation": AnyCodable("new")],
                    segmentMemberships: SegmentMembershipSeed(
                        evaluatedAt: Date(timeIntervalSince1970: 20),
                        memberships: [SeededSegmentMembership(
                            segmentId: newSegment.id,
                            enteredAt: Date(timeIntervalSince1970: 15)
                        )]
                    )
                )
                await mockFactory.nuxieApi.setProfileResponse(newProfile)
                let service = profileService!
                let refresh = Task {
                    try await service.refetchProfile(distinctId: distinctId)
                }
                await gate.waitUntilSuspended()

                let during = await profileService.getCachedProfile(distinctId: distinctId)
                let duringReferences = await profileService.getActiveExperienceReferences(
                    distinctId: distinctId
                )
                expect(during?.segments.first?.id).to(equal(oldSegment.id))
                expect(duringReferences?.first?.experienceId).to(equal("atomic-old-release"))
                await expect { await segments.snapshot(for: distinctId) }
                    .to(equal(oldProfile.segmentMemberships))
                expect(mockFactory.identityService.getUserProperties()["profile_generation"] as? String)
                    .to(equal("old"))
                expect((mockFactory.experienceService.committedReleaseProfiles.last ?? nil)?
                    .active.first?.locator.experienceId).to(equal("atomic-old-release"))

                await gate.resume()
                _ = try await refresh.value

                let admitted = await profileService.getCachedProfile(distinctId: distinctId)
                expect(admitted?.segments.first?.id).to(equal(newSegment.id))
                await expect { await segments.snapshot(for: distinctId) }
                    .to(equal(newProfile.segmentMemberships))
            }

            it("keeps routing absent until the first atomic admission commits") {
                let distinctId = "cold-routing-admission-user"
                let gate = ReleaseProfileAuthenticationGate()
                mockFactory.identityService.setDistinctId(distinctId)
                mockFactory.experienceService.authenticatedReleaseReferences = []
                mockFactory.experienceService.releaseProfileAuthenticationGate = gate
                await mockFactory.nuxieApi.setProfileResponse(Self.makeProfile(
                    experienceId: "authoritative-empty"
                ))

                let service = profileService!
                let refresh = Task {
                    try await service.refetchProfile(distinctId: distinctId)
                }
                await gate.waitUntilSuspended()

                let pendingAdmission = await service.getTriggerAdmission(distinctId: distinctId)
                let pendingEffective = await service.getEffectiveExperienceReferences(
                    distinctId: distinctId
                )
                let pendingActive = await service.getActiveExperienceReferences(
                    distinctId: distinctId
                )
                expect(pendingAdmission).to(beNil())
                expect(pendingEffective).to(beNil())
                expect(pendingActive).to(beNil())

                await gate.resume()
                _ = try await refresh.value

                let admitted = await service.getTriggerAdmission(distinctId: distinctId)
                let effective = await service.getEffectiveExperienceReferences(
                    distinctId: distinctId
                )
                let active = await service.getActiveExperienceReferences(
                    distinctId: distinctId
                )
                expect(admitted).notTo(beNil())
                expect(admitted?.effectiveExperienceReferences).to(beEmpty())
                expect(admitted?.activeExperienceReferences).to(beEmpty())
                expect(effective).to(beEmpty())
                expect(active).to(beEmpty())
            }

            it("revalidates a fresh disk profile and keeps its cached authority on 304") {
                let cache = InMemoryCachedProfileStore(ttl: nil)
                let distinctId = "cached-validator-user"
                let profile = Self.makeProfile(experienceId: "cached-validator")
                let validator = ProfileCacheValidator(rawValue: "\"profile-v1\"")
                let cachedAt = mockFactory.dateProvider.now()
                try await cache.store(
                    CachedProfile(
                        response: profile,
                        distinctId: distinctId,
                        cachedAt: cachedAt,
                        validator: validator,
                        locale: "en_US"
                    ),
                    forKey: distinctId
                )
                mockFactory.identityService.setDistinctId(distinctId)
                let api = ConditionalProfileAPI(result: .notModified)
                profileService = ProfileService(
                    cache: cache,
                    identity: mockFactory.identityService,
                    api: api,
                    segments: mockFactory.segmentService,
                    experiences: mockFactory.experienceService,
                    eventLog: mockFactory.eventLog,
                    dateProvider: mockFactory.dateProvider,
                    sleepProvider: mockFactory.sleepProvider,
                    localeProvider: ConfigurationLocaleIdentifierProvider(
                        configuredLocale: { "en_US" }
                    )
                )
                mockFactory.dateProvider.advance(by: 60)

                let refreshed = try await profileService.refetchProfile(
                    distinctId: distinctId
                )

                expect(refreshed.releases).to(equal(profile.releases))
                await expect { await api.lastValidator }
                    .to(equal(validator))
                let stored = await cache.retrieve(forKey: distinctId, allowStale: true)
                expect(stored?.cachedAt).to(equal(mockFactory.dateProvider.now()))
                expect(stored?.response.releases).to(equal(profile.releases))
            }

            it("does not reuse a validator from another locale") {
                let cache = InMemoryCachedProfileStore(ttl: nil)
                let distinctId = "locale-validator-user"
                let oldValidator = ProfileCacheValidator(rawValue: "\"profile-en\"")
                let newValidator = ProfileCacheValidator(rawValue: "\"profile-fr\"")
                try await cache.store(
                    CachedProfile(
                        response: Self.makeProfile(experienceId: "english-profile"),
                        distinctId: distinctId,
                        cachedAt: mockFactory.dateProvider.now(),
                        validator: oldValidator,
                        locale: "en_US"
                    ),
                    forKey: distinctId
                )
                mockFactory.identityService.setDistinctId(distinctId)
                let api = ConditionalProfileAPI(
                    result: .modified(
                        Self.makeProfile(experienceId: "french-profile"),
                        validator: newValidator
                    )
                )
                profileService = ProfileService(
                    cache: cache,
                    identity: mockFactory.identityService,
                    api: api,
                    segments: mockFactory.segmentService,
                    experiences: mockFactory.experienceService,
                    eventLog: mockFactory.eventLog,
                    dateProvider: mockFactory.dateProvider,
                    sleepProvider: mockFactory.sleepProvider,
                    localeProvider: ConfigurationLocaleIdentifierProvider(
                        configuredLocale: { "fr_FR" }
                    )
                )

                let refreshed = try await profileService.refetchProfile(
                    distinctId: distinctId
                )

                expect(refreshed.releases?.active.first?.locator.experienceId)
                    .to(equal("french-profile"))
                await expect { await api.lastValidator }
                    .to(beNil())
                let stored = await cache.retrieve(forKey: distinctId, allowStale: true)
                expect(stored?.validator).to(equal(newValidator))
                expect(stored?.locale).to(equal("fr_FR"))
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

                let service = profileService!
                let oldLoad = Task {
                    await service.getCachedProfile(distinctId: oldId)
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

            it("does not let successful startup hydration overwrite a user transition") {
                let cache = InMemoryCachedProfileStore(ttl: nil)
                let segments = SegmentService()
                let oldId = "startup-old-user"
                let newId = "startup-new-user"
                let oldSegment = Segment(id: "startup-old-segment", name: "Old")
                let newSegment = Segment(id: "startup-new-segment", name: "New")
                let oldProfile = ProfileResponse(
                    segments: [oldSegment],
                    releases: Self.releaseProfile(experienceId: "startup-old-release"),
                    userProperties: ["startup_generation": AnyCodable("old")],
                    segmentMemberships: SegmentMembershipSeed(
                        evaluatedAt: nil,
                        memberships: [SeededSegmentMembership(
                            segmentId: oldSegment.id,
                            enteredAt: Date(timeIntervalSince1970: 10)
                        )]
                    )
                )
                let newProfile = ProfileResponse(
                    segments: [newSegment],
                    releases: Self.releaseProfile(experienceId: "startup-new-release"),
                    userProperties: ["startup_generation": AnyCodable("new")],
                    segmentMemberships: SegmentMembershipSeed(
                        evaluatedAt: nil,
                        memberships: [SeededSegmentMembership(
                            segmentId: newSegment.id,
                            enteredAt: Date(timeIntervalSince1970: 20)
                        )]
                    )
                )
                try await cache.store(
                    CachedProfile(response: oldProfile, distinctId: oldId, cachedAt: Date()),
                    forKey: oldId
                )
                try await cache.store(
                    CachedProfile(response: newProfile, distinctId: newId, cachedAt: Date()),
                    forKey: newId
                )
                let gate = ReleaseProfileAuthenticationGate()
                mockFactory.identityService.setDistinctId(oldId)
                mockFactory.experienceService.releaseProfileAuthenticationGate = gate
                profileService = ProfileService(
                    cache: cache,
                    identity: mockFactory.identityService,
                    api: mockFactory.nuxieApi,
                    segments: segments,
                    experiences: mockFactory.experienceService,
                    eventLog: mockFactory.eventLog,
                    dateProvider: mockFactory.dateProvider,
                    sleepProvider: mockFactory.sleepProvider,
                    localeProvider: ConfigurationLocaleIdentifierProvider(
                        configuredLocale: { "en_US" }
                    )
                )

                let service = profileService!
                let startup = Task {
                    await service.getCachedProfile(distinctId: oldId)
                }
                await gate.waitUntilSuspended()
                mockFactory.identityService.setDistinctId(newId)
                await profileService.handleUserChange(from: oldId, to: newId)
                await gate.resume()
                _ = await startup.value

                let retained = await profileService.getCachedProfile(distinctId: newId)
                expect(retained?.segments.first?.id).to(equal(newSegment.id))
                let effective = await profileService.getEffectiveExperienceReferences(
                    distinctId: newId
                )
                expect(effective?.first?.experienceId).to(equal("startup-new-release"))
                await expect { await segments.snapshot(for: newId) }
                    .to(equal(newProfile.segmentMemberships))
                expect(mockFactory.identityService.getUserProperties()["startup_generation"] as? String)
                    .to(equal("new"))
                expect((mockFactory.experienceService.committedReleaseProfiles.last ?? nil)?
                    .active.first?.locator.experienceId).to(equal("startup-new-release"))
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

            it("never installs an expired signed cache while offline") {
                let cache = InMemoryCachedProfileStore(ttl: nil)
                let distinctId = "expired-offline-user"
                let expired = Self.makeProfile(
                    experienceId: "expired-release",
                    releases: Self.releaseProfile(
                        experienceId: "expired-release",
                        versionId: "expired-version"
                    )
                )
                try await cache.store(
                    CachedProfile(
                        response: expired,
                        distinctId: distinctId,
                        cachedAt: mockFactory.dateProvider.now()
                            .addingTimeInterval(-(24 * 60 * 60 + 1))
                    ),
                    forKey: distinctId
                )
                mockFactory.identityService.setDistinctId(distinctId)
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
                expect(mockFactory.experienceService.releaseProfiles.compactMap { $0 })
                    .to(beEmpty())
                let removed = await cache.retrieve(forKey: distinctId, allowStale: true)
                expect(removed).to(beNil())
                await expect { await mockFactory.nuxieApi.fetchProfileCallCount }
                    .toEventually(beGreaterThan(0))
            }

            it("removes resident signed authority when it expires offline") {
                let distinctId = "resident-expiry-user"
                let release = Self.releaseProfile(
                    experienceId: "resident-release",
                    versionId: "resident-version"
                )
                mockFactory.identityService.setDistinctId(distinctId)
                mockFactory.experienceService.authenticatedReleaseReferences = [
                    ExperienceReference(
                        experienceId: "resident-release",
                        versionId: "resident-version"
                    )
                ]
                await mockFactory.nuxieApi.setProfileResponse(Self.makeProfile(
                    experienceId: "resident-release",
                    releases: release
                ))
                _ = try await profileService.refetchProfile(distinctId: distinctId)
                mockFactory.dateProvider.advance(by: 24 * 60 * 60 + 1)
                await mockFactory.nuxieApi.setShouldFailProfile(true)

                await profileService.onAppBecameActive()

                let cached = await profileService.getCachedProfile(distinctId: distinctId)
                expect(cached).to(beNil())
                let effective = await profileService.getEffectiveExperienceReferences(
                    distinctId: distinctId
                )
                expect(effective).to(beNil())
                expect(mockFactory.experienceService.releaseProfiles.last ?? release)
                    .to(beNil())
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
                    ProfileResponse(segments: [], releases: nil)
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
        releases: ExperienceReleaseProfile? = nil
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
    ) -> ExperienceReleaseProfile {
        let digest = String(repeating: "a", count: 64)
        func entry(experienceId: String, versionId: String) -> ExperienceReleaseProfileEntry {
            ExperienceReleaseProfileEntry(
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
            envelopeBytes: try! JSONEncoder().encode(ExperienceReleaseDescriptorEnvelope(
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
        let pinnedEntry: ExperienceReleaseProfileEntry? = if let pinnedExperienceId,
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
