import Foundation

/// Read boundary for the current identity's admitted segment membership snapshot.
protocol SegmentServiceProtocol: AnyObject, Sendable {
    /// Replaces membership reads with one admitted profile snapshot.
    func replaceSnapshot(
        _ snapshot: SegmentMembershipSeed,
        definitions: [Segment],
        for distinctId: String
    ) async
    /// Installs a profile-owned snapshot only if its generation is not older
    /// than the snapshot already admitted by that ProfileService.
    @discardableResult
    func replaceSnapshot(
        _ snapshot: SegmentMembershipSeed,
        definitions: [Segment],
        for distinctId: String,
        profileGeneration: UInt64
    ) async -> Bool
    /// Installs a profile-owned snapshot, additionally evaluating the
    /// supplied admission at the mutation point so an invalidated admission
    /// (identity or locale change) is rejected even before any newer commit
    /// has raised the generation floor.
    @discardableResult
    func replaceSnapshot(
        _ snapshot: SegmentMembershipSeed,
        definitions: [Segment],
        for distinctId: String,
        profileGeneration: UInt64,
        admission: ProfileSideEffectAdmission?
    ) async -> Bool
    /// Returns the admitted snapshot only when it belongs to the requested identity.
    func snapshot(for distinctId: String) async -> SegmentMembershipSeed
    /// Clears the admitted snapshot when it belongs to this identity.
    func clearSnapshot(for distinctId: String) async
    /// Returns whether the current identity belongs to a segment.
    func isInSegment(_ segmentId: String) async -> Bool
    /// Returns the server-owned segment entry time, when known.
    func enteredAt(_ segmentId: String) async -> Date?
}

extension SegmentServiceProtocol {
    @discardableResult
    func replaceSnapshot(
        _ snapshot: SegmentMembershipSeed,
        definitions: [Segment],
        for distinctId: String,
        profileGeneration: UInt64
    ) async -> Bool {
        _ = profileGeneration
        await replaceSnapshot(snapshot, definitions: definitions, for: distinctId)
        return true
    }

    @discardableResult
    func replaceSnapshot(
        _ snapshot: SegmentMembershipSeed,
        definitions: [Segment],
        for distinctId: String,
        profileGeneration: UInt64,
        admission: ProfileSideEffectAdmission?
    ) async -> Bool {
        if let admission, !admission() { return false }
        return await replaceSnapshot(
            snapshot,
            definitions: definitions,
            for: distinctId,
            profileGeneration: profileGeneration
        )
    }
}

/// Exposes only the membership value admitted with the current profile.
///
/// There is deliberately no independent persistence, expiry policy, evaluator, or change
/// stream. Offline hydration re-enters through ProfileService's persisted profile snapshot.
actor SegmentService: SegmentServiceProtocol {
    private var activeDistinctId: String?
    private var admittedSnapshot = SegmentMembershipSeed.empty
    private var latestProfileGeneration: UInt64 = 0

    func replaceSnapshot(
        _ snapshot: SegmentMembershipSeed,
        definitions: [Segment],
        for distinctId: String
    ) async {
        activeDistinctId = distinctId
        admittedSnapshot = snapshot.filtered(to: definitions)
    }

    func replaceSnapshot(
        _ snapshot: SegmentMembershipSeed,
        definitions: [Segment],
        for distinctId: String,
        profileGeneration: UInt64,
        admission: ProfileSideEffectAdmission?
    ) async -> Bool {
        guard profileGeneration >= latestProfileGeneration else { return false }
        // Mutation-point admission: rejects an invalidated (identity or
        // locale) admission before any newer commit raises the floor.
        if let admission, !admission() { return false }
        latestProfileGeneration = profileGeneration
        activeDistinctId = distinctId
        admittedSnapshot = snapshot.filtered(to: definitions)
        return true
    }

    func replaceSnapshot(
        _ snapshot: SegmentMembershipSeed,
        definitions: [Segment],
        for distinctId: String,
        profileGeneration: UInt64
    ) async -> Bool {
        await replaceSnapshot(
            snapshot,
            definitions: definitions,
            for: distinctId,
            profileGeneration: profileGeneration,
            admission: nil
        )
    }

    func snapshot(for distinctId: String) async -> SegmentMembershipSeed {
        guard activeDistinctId == distinctId else { return .empty }
        return admittedSnapshot
    }

    func clearSnapshot(for distinctId: String) async {
        guard activeDistinctId == distinctId else { return }
        activeDistinctId = nil
        admittedSnapshot = .empty
    }

    func isInSegment(_ segmentId: String) async -> Bool {
        admittedSnapshot.memberships.contains { $0.segmentId == segmentId }
    }

    func enteredAt(_ segmentId: String) async -> Date? {
        admittedSnapshot.memberships.first { $0.segmentId == segmentId }?.enteredAt
    }
}

extension SegmentMembershipSeed {
    static let empty = SegmentMembershipSeed(evaluatedAt: nil, memberships: [])

    func filtered(to definitions: [Segment]) -> SegmentMembershipSeed {
        let deliveredIds = Set(definitions.map(\.id))
        var earliestById: [String: SeededSegmentMembership] = [:]
        for membership in memberships where deliveredIds.contains(membership.segmentId) {
            if let existing = earliestById[membership.segmentId],
               existing.enteredAt <= membership.enteredAt {
                continue
            }
            earliestById[membership.segmentId] = membership
        }
        return SegmentMembershipSeed(
            evaluatedAt: evaluatedAt,
            memberships: earliestById.values.sorted { $0.segmentId < $1.segmentId }
        )
    }
}
