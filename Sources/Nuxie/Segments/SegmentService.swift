import Foundation

/// Read boundary for the current identity's admitted segment membership snapshot.
protocol SegmentServiceProtocol: AnyObject, Sendable {
    /// Replaces membership reads with one admitted profile snapshot.
    func replaceSnapshot(
        _ snapshot: SegmentMembershipSeed,
        definitions: [Segment],
        for distinctId: String
    ) async
    /// Returns the admitted snapshot only when it belongs to the requested identity.
    func snapshot(for distinctId: String) async -> SegmentMembershipSeed
    /// Clears the admitted snapshot when it belongs to this identity.
    func clearSnapshot(for distinctId: String) async
    /// Returns whether the current identity belongs to a segment.
    func isInSegment(_ segmentId: String) async -> Bool
    /// Returns the server-owned segment entry time, when known.
    func enteredAt(_ segmentId: String) async -> Date?
}

/// Exposes only the membership value admitted with the current profile.
///
/// There is deliberately no independent persistence, expiry policy, evaluator, or change
/// stream. Offline hydration re-enters through ProfileService's persisted profile snapshot.
actor SegmentService: SegmentServiceProtocol {
    private var activeDistinctId: String?
    private var admittedSnapshot = SegmentMembershipSeed.empty

    func replaceSnapshot(
        _ snapshot: SegmentMembershipSeed,
        definitions: [Segment],
        for distinctId: String
    ) async {
        activeDistinctId = distinctId
        admittedSnapshot = snapshot.filtered(to: definitions)
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

    fileprivate func filtered(to definitions: [Segment]) -> SegmentMembershipSeed {
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
