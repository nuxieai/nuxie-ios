import Foundation
@testable import Nuxie

/// In-memory admitted membership snapshot for tests.
public actor MockSegmentService: SegmentServiceProtocol {
    private var activeDistinctId: String?
    private var admittedSnapshot = SegmentMembershipSeed.empty

    public init() {}

    public func replaceSnapshot(
        _ snapshot: SegmentMembershipSeed,
        definitions: [Segment],
        for distinctId: String
    ) async {
        let deliveredIds = Set(definitions.map(\.id))
        activeDistinctId = distinctId
        admittedSnapshot = SegmentMembershipSeed(
            evaluatedAt: snapshot.evaluatedAt,
            memberships: snapshot.memberships.filter {
                deliveredIds.contains($0.segmentId)
            }
        )
    }

    public func snapshot(for distinctId: String) async -> SegmentMembershipSeed {
        activeDistinctId == distinctId ? admittedSnapshot : .empty
    }

    public func clearSnapshot(for distinctId: String) async {
        guard activeDistinctId == distinctId else { return }
        activeDistinctId = nil
        admittedSnapshot = .empty
    }

    public func isInSegment(_ segmentId: String) async -> Bool {
        admittedSnapshot.memberships.contains { $0.segmentId == segmentId }
    }

    public func enteredAt(_ segmentId: String) async -> Date? {
        admittedSnapshot.memberships.first { $0.segmentId == segmentId }?.enteredAt
    }

    public func reset() async {
        activeDistinctId = nil
        admittedSnapshot = .empty
    }

    public func setMembership(_ segmentId: String, isMember: Bool) async {
        var memberships = admittedSnapshot.memberships.filter {
            $0.segmentId != segmentId
        }
        if isMember {
            memberships.append(
                SeededSegmentMembership(segmentId: segmentId, enteredAt: Date())
            )
        }
        activeDistinctId = activeDistinctId ?? "test-user"
        admittedSnapshot = SegmentMembershipSeed(
            evaluatedAt: admittedSnapshot.evaluatedAt,
            memberships: memberships
        )
    }
}
