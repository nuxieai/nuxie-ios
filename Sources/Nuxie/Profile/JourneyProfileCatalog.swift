import CryptoKit
import Foundation

/// Authenticates one complete canonical profile before publishing any arm,
/// fact, or journey release to the executor.
actor JourneyProfileCatalog {
    struct Snapshot: Sendable {
        let profile: JourneyPlaneProfile
        let releasesByDigest: [String: AuthenticatedJourneyRelease]

        /// A current enrollment arm carries the live experience policy. A
        /// pinned continuation can legitimately retain an older version whose
        /// policy differs, so it is only authoritative when no enrollment arm
        /// for that experience is present. The remaining identity fields make
        /// malformed but authenticated ties deterministic.
        var liveReentryPolicies: [String: Journey.Reentry] {
            var selected: [String: ReentryCandidate] = [:]
            for arm in profile.armedLegs {
                guard let release = releasesByDigest[
                    arm.reference.descriptorSha256
                ] else { continue }
                let candidate = ReentryCandidate(
                    isEnrollment: arm.binding.type == .new,
                    release: release
                )
                let experienceId = release.descriptor.identity.experienceId
                if let current = selected[experienceId],
                   !candidate.outranks(current) {
                    continue
                }
                selected[experienceId] = candidate
            }
            return selected.mapValues(\.reentry)
        }

        private struct ReentryCandidate {
            let isEnrollment: Bool
            let publishedAtSeq: Int
            let versionNumber: Int
            let publishedAt: String
            let versionId: String
            let buildId: String
            let descriptorSHA256: String
            let reentry: Journey.Reentry

            init(
                isEnrollment: Bool,
                release: AuthenticatedJourneyRelease
            ) {
                let identity = release.descriptor.identity
                self.isEnrollment = isEnrollment
                publishedAtSeq = identity.publishedAtSeq
                versionNumber = identity.versionNumber
                publishedAt = identity.publishedAt
                versionId = identity.experienceVersionId
                buildId = identity.buildId
                descriptorSHA256 = release.descriptorSHA256
                reentry = release.descriptor.leg.reentry
            }

            func outranks(_ other: Self) -> Bool {
                if isEnrollment != other.isEnrollment {
                    return isEnrollment
                }
                if publishedAtSeq != other.publishedAtSeq {
                    return publishedAtSeq > other.publishedAtSeq
                }
                if versionNumber != other.versionNumber {
                    return versionNumber > other.versionNumber
                }
                if publishedAt != other.publishedAt {
                    return publishedAt > other.publishedAt
                }
                if versionId != other.versionId {
                    return versionId > other.versionId
                }
                if buildId != other.buildId {
                    return buildId > other.buildId
                }
                return descriptorSHA256 > other.descriptorSHA256
            }
        }
    }

    struct Prepared: Sendable {
        let snapshot: Snapshot
        fileprivate let promotions:
            [JourneyReleaseHighWaterKey: JourneyReleaseHighWaterMark]
        let authority: ProfileDeliveryAuthority
    }

    private let authorizationKeys: [JourneyPackageAuthorizationKey]
    private let supportedRuntime: JourneyReleaseSupportedRuntime
    private let highWaterStore: any JourneyReleaseHighWaterStore
    private let verifier = JourneyReleaseVerifier()
    private var current: (distinctId: String, snapshot: Snapshot)?
    /// Bound to the transport-authenticated app/environment of the first
    /// committed canonical profile for this setup. Clearing customer delivery
    /// does not change configured app authority.
    private var authority: ProfileDeliveryAuthority?

    init(
        authorizationKeys: [JourneyPackageAuthorizationKey],
        supportedRuntime: JourneyReleaseSupportedRuntime,
        highWaterStore: any JourneyReleaseHighWaterStore
    ) {
        self.authorizationKeys = authorizationKeys
        self.supportedRuntime = supportedRuntime
        self.highWaterStore = highWaterStore
    }

    func prepare(
        _ profile: JourneyPlaneProfile,
        authority deliveryAuthority: ProfileDeliveryAuthority
    ) async throws -> Prepared {
        guard deliveryAuthority.isValid,
              authority == nil || authority == deliveryAuthority else {
            throw JourneyReleaseAuthenticationError.invalidDescriptor
        }
        // Cached profiles are decoded through ProfileResponse's transparent
        // Codable wrapper. Re-run the exact whole-profile decoder here so
        // disk reloads enforce the same shape, linkage, and cardinality rules
        // as fresh network bytes before any signed release is admitted.
        let validatedProfile = try JourneyPlaneProfile.decode(
            JSONEncoder().encode(profile)
        )
        var authenticated: [String: AuthenticatedJourneyRelease] = [:]
        var promotions: [
            JourneyReleaseHighWaterKey: JourneyReleaseHighWaterMark
        ] = [:]
        let activeDigests = Set(
            validatedProfile.armedLegs.compactMap { arm in
                arm.binding.type == .new
                    ? arm.reference.descriptorSha256
                    : nil
            }
        )
        authenticated.reserveCapacity(validatedProfile.releases.count)

        for entry in validatedProfile.releases {
            let identity = entry.locator.identity
            let entryAuthority = ProfileDeliveryAuthority(
                appId: identity.appId,
                environment: identity.environment
            )
            guard deliveryAuthority == entryAuthority else {
                throw JourneyReleaseAuthenticationError.invalidDescriptor
            }
            let key = JourneyReleaseHighWaterKey(
                appId: identity.appId,
                environment: identity.environment,
                experienceId: identity.experienceId
            )
            let isActive = activeDigests.contains(entry.envelope.descriptorSha256)
            let replayPolicy: JourneyReleaseReplayPolicy
            if isActive {
                replayPolicy = .active(
                    minimumPublishedAtSeq:
                        try await highWaterStore.highWater(for: key)?.publishedAtSeq ?? 0
                )
            } else {
                replayPolicy = .pinned(
                    experienceVersionId: identity.experienceVersionId,
                    buildId: identity.buildId,
                    descriptorSHA256: entry.envelope.descriptorSha256
                )
            }
            let release = try verifier.authenticateJourney(
                envelopeBytes: JSONEncoder().encode(entry.envelope),
                authorizationKeys: authorizationKeys,
                expectedIdentity: identity,
                expectedLegId: entry.locator.legId,
                supportedRuntime: supportedRuntime,
                replayPolicy: replayPolicy
            )
            guard authenticated.updateValue(
                release,
                forKey: release.descriptorSHA256
            ) == nil else {
                throw JourneyReleaseAuthenticationError.invalidDescriptor
            }

            guard isActive else { continue }
            let mark = JourneyReleaseHighWaterMark(
                publishedAtSeq: identity.publishedAtSeq,
                experienceVersionId: identity.experienceVersionId,
                buildId: identity.buildId,
                versionNumber: identity.versionNumber,
                publishedAt: identity.publishedAt,
                descriptorSHA256: Self.publicationDigest(identity)
            )
            if let previous = promotions[key], previous != mark {
                throw JourneyReleaseAuthenticationError.replayRejected
            }
            promotions[key] = mark
        }

        // The profile may arm or bind an authenticated leg, but it cannot
        // rewrite that signed program's authored trigger. Otherwise delivery
        // could turn arrival itself into different execution authority.
        for arm in validatedProfile.armedLegs {
            guard let release = authenticated[
                arm.reference.descriptorSha256
            ], try ExactJSONCodec.encode(arm.entryCondition)
                == ExactJSONCodec.encode(
                    release.descriptor.leg.entryCondition
                ) else {
                throw JourneyReleaseAuthenticationError.invalidDescriptor
            }
        }

        var referencedPropertyKeys: [String] = []
        var referencedSegmentIds: [String] = []
        var referencedExperimentIds: [String] = []
        for release in authenticated.values {
            referencedPropertyKeys.append(
                contentsOf: release.descriptor.leg.facts.propertyKeys
            )
            referencedSegmentIds.append(
                contentsOf: release.descriptor.leg.facts.segmentIds
            )
            referencedExperimentIds.append(
                contentsOf: release.descriptor.leg.facts.experimentIds
            )
        }
        guard Self.exactKeySet(validatedProfile.facts.properties.keys)
                == Self.exactKeySet(referencedPropertyKeys),
              Self.exactKeySet(validatedProfile.facts.memberships.keys)
                == Self.exactKeySet(referencedSegmentIds),
              Self.exactKeySet(validatedProfile.facts.assignments.keys)
                == Self.exactKeySet(referencedExperimentIds) else {
            throw JourneyReleaseAuthenticationError.invalidDescriptor
        }

        return Prepared(
            snapshot: Snapshot(
                profile: validatedProfile,
                releasesByDigest: authenticated
            ),
            promotions: promotions,
            authority: deliveryAuthority
        )
    }

    @discardableResult
    func commit(
        _ prepared: Prepared,
        distinctId: String,
        admission: ProfileSideEffectAdmission? = nil
    ) async throws -> Bool {
        guard admission?() ?? true else { return false }
        guard authority == nil || authority == prepared.authority else {
            throw JourneyReleaseAuthenticationError.invalidDescriptor
        }
        // Establish before the first suspension so two reentrant commits
        // cannot publish different app authorities through one setup. Empty
        // canonical deliveries bind authority too.
        authority = prepared.authority
        try await highWaterStore.admitActiveBatch(prepared.promotions)
        guard admission?() ?? true else { return false }
        current = (distinctId, prepared.snapshot)
        return true
    }

    func snapshot(distinctId: String) -> Snapshot? {
        guard current?.distinctId == distinctId else { return nil }
        return current?.snapshot
    }

    /// Re-authenticate a release retained by a durable run after delivery no
    /// longer includes it. The run's exact content identity is the replay
    /// authority; this path never promotes or consults the active high-water
    /// stream.
    func authenticatePinnedRelease(
        _ entry: JourneyReleaseProfileEntry,
        reference: ArmedJourney.Reference
    ) throws -> AuthenticatedJourneyRelease {
        guard entry.envelope.descriptorSha256
                == reference.descriptorSha256,
              entry.locator.experienceId == reference.experienceId,
              entry.locator.experienceVersionId == reference.versionId,
              entry.locator.legId == reference.legId else {
            throw JourneyReleaseAuthenticationError.invalidDescriptor
        }
        let identity = entry.locator.identity
        let entryAuthority = ProfileDeliveryAuthority(
            appId: identity.appId,
            environment: identity.environment
        )
        guard let authority, authority == entryAuthority else {
            throw JourneyReleaseAuthenticationError.invalidDescriptor
        }
        return try verifier.authenticateJourney(
            envelopeBytes: JSONEncoder().encode(entry.envelope),
            authorizationKeys: authorizationKeys,
            expectedIdentity: identity,
            expectedLegId: entry.locator.legId,
            supportedRuntime: supportedRuntime,
            replayPolicy: .pinned(
                experienceVersionId: identity.experienceVersionId,
                buildId: identity.buildId,
                descriptorSHA256: entry.envelope.descriptorSha256
            )
        )
    }

    @discardableResult
    func clear(
        distinctId: String,
        admission: ProfileSideEffectAdmission? = nil
    ) -> Bool {
        guard admission?() ?? true else { return false }
        if current?.distinctId == distinctId { current = nil }
        return true
    }

    func clearAll() {
        current = nil
    }

    /// Journey releases from one publication have distinct digests. The
    /// replay ledger therefore records a stable publication identity digest,
    /// allowing every signed leg at that sequence to share one stream mark.
    private static func publicationDigest(_ identity: JourneyReleaseIdentity) -> String {
        let value = [
            identity.appId,
            identity.environment,
            identity.experienceId,
            identity.experienceVersionId,
            identity.buildId,
            String(identity.versionNumber),
            identity.publishedAt,
            String(identity.publishedAtSeq),
        ].joined(separator: "\u{0}")
        return SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Swift String equality normalizes canonically equivalent spellings,
    /// while JSON object keys and compiled fact references use code-unit
    /// identity. Compare their UTF-16 spellings to preserve that boundary.
    private static func exactKeySet(_ keys: [String]) -> Set<[UInt16]> {
        Set(keys.map { Array($0.utf16) })
    }
}
