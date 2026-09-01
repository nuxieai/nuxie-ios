import CryptoKit
import Foundation

/// Authenticates one complete canonical profile before publishing any arm,
/// fact, or device-leg release to the executor.
actor DeviceLegProfileCatalog {
    struct Snapshot: Sendable {
        let profile: JourneyPlaneProfile
        let releasesByDigest: [String: AuthenticatedDeviceLegRelease]
    }

    struct Prepared: Sendable {
        fileprivate let snapshot: Snapshot
        fileprivate let promotions:
            [ExperienceReleaseHighWaterKey: ExperienceReleaseHighWaterMark]
    }

    private let authorizationKeys: [ExperiencePackageAuthorizationKey]
    private let supportedRuntime: ExperienceReleaseSupportedRuntime
    private let highWaterStore: any ExperienceReleaseHighWaterStore
    private let verifier = ExperienceReleaseDescriptorVerifier()
    private var current: (distinctId: String, snapshot: Snapshot)?

    init(
        authorizationKeys: [ExperiencePackageAuthorizationKey],
        supportedRuntime: ExperienceReleaseSupportedRuntime,
        highWaterStore: any ExperienceReleaseHighWaterStore
    ) {
        self.authorizationKeys = authorizationKeys
        self.supportedRuntime = supportedRuntime
        self.highWaterStore = highWaterStore
    }

    func prepare(_ profile: JourneyPlaneProfile) async throws -> Prepared {
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
            let key = ExperienceReleaseHighWaterKey(
                appId: identity.appId,
                environment: identity.environment,
                experienceId: identity.experienceId
            )
            let isActive = activeDigests.contains(entry.envelope.descriptorSha256)
            let replayPolicy: ExperienceReleaseReplayPolicy
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
                publishedAtSeq: identity.publishedAtSeq,
                experienceVersionId: identity.experienceVersionId,
                buildId: identity.buildId,
                versionNumber: identity.versionNumber,
                publishedAt: identity.publishedAt,
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
            promotions: promotions
        )
    }

    @discardableResult
    func commit(
        _ prepared: Prepared,
        distinctId: String,
        admission: ProfileSideEffectAdmission? = nil
    ) async throws -> Bool {
        guard admission?() ?? true else { return false }
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
            identity.publishedAt,
            String(identity.publishedAtSeq),
        ].joined(separator: "\u{0}")
        return SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
