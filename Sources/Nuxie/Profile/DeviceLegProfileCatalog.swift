import CryptoKit
import Foundation

/// Authenticates one complete canonical profile before publishing any arm,
/// fact, or device-leg release to the executor.
actor DeviceLegProfileCatalog {
    struct Snapshot: Sendable {
        let profile: JourneyPlaneProfile
        let releasesByDigest: [String: AuthenticatedDeviceLegRelease]

        /// A current enrollment arm carries the live experience policy. A
        /// pinned continuation can legitimately retain an older version whose
        /// policy differs, so it is only authoritative when no enrollment arm
        /// for that experience is present. The remaining identity fields make
        /// malformed but authenticated ties deterministic.
        var liveReentryPolicies: [String: DeviceLeg.Reentry] {
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
            let reentry: DeviceLeg.Reentry

            init(
                isEnrollment: Bool,
                release: AuthenticatedDeviceLegRelease
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
        fileprivate let snapshot: Snapshot
        fileprivate let promotions:
            [ExperienceReleaseHighWaterKey: ExperienceReleaseHighWaterMark]
        fileprivate let authority: ProfileDeliveryAuthority
    }

    private let authorizationKeys: [ExperiencePackageAuthorizationKey]
    private let supportedRuntime: ExperienceReleaseSupportedRuntime
    private let highWaterStore: any ExperienceReleaseHighWaterStore
    private let verifier = ExperienceReleaseDescriptorVerifier()
    private var current: (distinctId: String, snapshot: Snapshot)?
    /// Bound to the transport-authenticated app/environment of the first
    /// committed canonical profile for this setup. Clearing customer delivery
    /// does not change configured app authority.
    private var authority: ProfileDeliveryAuthority?

    init(
        authorizationKeys: [ExperiencePackageAuthorizationKey],
        supportedRuntime: ExperienceReleaseSupportedRuntime,
        highWaterStore: any ExperienceReleaseHighWaterStore
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
            throw ExperienceReleaseDescriptorAuthenticationError.invalidDescriptor
        }
        // Cached profiles are decoded through ProfileResponse's synthesized
        // Codable conformance. Re-run the exact whole-profile decoder here so
        // disk reloads enforce the same shape, linkage, and cardinality rules
        // as fresh network bytes before any signed release is admitted.
        let validatedProfile = try JourneyPlaneProfile.decode(
            JSONEncoder().encode(profile)
        )
        var authenticated: [String: AuthenticatedDeviceLegRelease] = [:]
        var promotions: [
            ExperienceReleaseHighWaterKey: ExperienceReleaseHighWaterMark
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
                throw ExperienceReleaseDescriptorAuthenticationError.invalidDescriptor
            }
            let key = ExperienceReleaseHighWaterKey(
                appId: identity.appId,
                environment: identity.environment,
                experienceId: identity.experienceId
            )
            let isActive = activeDigests.contains(entry.envelope.descriptorSha256)
            let replayPolicy: ExperienceReleaseReplayPolicy
            if isActive {
                replayPolicy = .active(
                    minimumReleaseSequence:
                        try await highWaterStore.highWater(for: key)?.releaseSequence ?? 0
                )
            } else {
                replayPolicy = .pinned(
                    experienceVersionId: identity.experienceVersionId,
                    buildId: identity.buildId,
                    descriptorSHA256: entry.envelope.descriptorSha256
                )
            }
            let release = try verifier.authenticateDeviceLeg(
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
                throw ExperienceReleaseDescriptorAuthenticationError.invalidDescriptor
            }

            guard isActive else { continue }
            let mark = ExperienceReleaseHighWaterMark(
                releaseSequence: identity.releaseSequence,
                experienceVersionId: identity.experienceVersionId,
                buildId: identity.buildId,
                versionNumber: identity.versionNumber,
                releaseCreatedAt: identity.releaseCreatedAt,
                descriptorSHA256: Self.publicationDigest(identity)
            )
            if let previous = promotions[key], previous != mark {
                throw ExperienceReleaseDescriptorAuthenticationError.replayRejected
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
                throw ExperienceReleaseDescriptorAuthenticationError.invalidDescriptor
            }
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
            throw ExperienceReleaseDescriptorAuthenticationError.invalidDescriptor
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
        _ entry: DeviceLegReleaseProfileEntry,
        reference: ArmedDeviceLeg.Reference
    ) throws -> AuthenticatedDeviceLegRelease {
        guard entry.envelope.descriptorSha256
                == reference.descriptorSha256,
              entry.locator.experienceId == reference.experienceId,
              entry.locator.experienceVersionId == reference.versionId,
              entry.locator.legId == reference.legId else {
            throw ExperienceReleaseDescriptorAuthenticationError.invalidDescriptor
        }
        let identity = entry.locator.identity
        let entryAuthority = ProfileDeliveryAuthority(
            appId: identity.appId,
            environment: identity.environment
        )
        guard let authority, authority == entryAuthority else {
            throw ExperienceReleaseDescriptorAuthenticationError.invalidDescriptor
        }
        return try verifier.authenticateDeviceLeg(
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

    /// Device-leg descriptors from one publication have distinct digests. The
    /// replay ledger therefore records a stable publication identity digest,
    /// allowing every signed leg at that sequence to share one stream mark.
    private static func publicationDigest(_ identity: ExperienceReleaseIdentity) -> String {
        let value = [
            identity.appId,
            identity.environment,
            identity.experienceId,
            identity.experienceVersionId,
            identity.buildId,
            String(identity.versionNumber),
            identity.releaseCreatedAt,
            String(identity.releaseSequence),
        ].joined(separator: "\u{0}")
        return SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
