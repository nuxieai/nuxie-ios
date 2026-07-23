import XCTest

@testable import Nuxie

final class SegmentSeedMirrorTests: XCTestCase {
    func testSeedIsAuthoritativeScopedIdempotentAndGenerationOrdered() async {
        let service = SegmentService()
        let distinctId = "seed-mirror-\(UUID().uuidString)"
        let segment = makeSegment(id: "segment-1")
        await service.updateSegments([segment], for: distinctId)
        let enteredAt = Date(timeIntervalSince1970: 1_746_178_320)
        let evaluatedAt = Date(timeIntervalSince1970: 1_753_207_451)
        let seed = SegmentMembershipSeed(
            evaluatedAt: evaluatedAt,
            memberships: [
                SeededSegmentMembership(segmentId: segment.id, enteredAt: enteredAt),
                SeededSegmentMembership(
                    segmentId: segment.id,
                    enteredAt: enteredAt.addingTimeInterval(60)
                ),
                SeededSegmentMembership(segmentId: "dangling", enteredAt: enteredAt),
            ]
        )

        let initial = await service.applySeed(seed, generation: 1, distinctId: distinctId)

        XCTAssertEqual(initial?.entered.map(\.id), [segment.id])
        let memberships = await service.getCurrentMemberships()
        let seededEnteredAt = await service.enteredAt(segment.id)
        XCTAssertEqual(memberships.map(\.segmentId), [segment.id])
        XCTAssertEqual(seededEnteredAt, enteredAt)

        let duplicate = await service.applySeed(
            SegmentMembershipSeed(evaluatedAt: evaluatedAt, memberships: []),
            generation: 1,
            distinctId: distinctId
        )
        XCTAssertNil(duplicate)
        let isMemberAfterDuplicate = await service.isInSegment(segment.id)
        XCTAssertTrue(isMemberAfterDuplicate)

        let absent = await service.applySeed(nil, generation: 2, distinctId: distinctId)
        XCTAssertNil(absent)
        let isMemberAfterAbsent = await service.isInSegment(segment.id)
        XCTAssertTrue(isMemberAfterAbsent)

        let emptied = await service.applySeed(
            SegmentMembershipSeed(evaluatedAt: evaluatedAt, memberships: []),
            generation: 2,
            distinctId: distinctId
        )
        XCTAssertEqual(emptied?.exited.map(\.id), [segment.id])
        let isMemberAfterEmpty = await service.isInSegment(segment.id)
        XCTAssertFalse(isMemberAfterEmpty)

        let stale = await service.applySeed(seed, generation: 1, distinctId: distinctId)
        XCTAssertNil(stale)
        let isMemberAfterStale = await service.isInSegment(segment.id)
        XCTAssertFalse(isMemberAfterStale)

        await service.clearSegments(for: distinctId)
    }

    func testNewGenerationWithIdenticalMembershipDoesNotEmitAChange() async {
        let service = SegmentService()
        let distinctId = "seed-idempotent-\(UUID().uuidString)"
        let segment = makeSegment(id: "segment-1")
        let enteredAt = Date(timeIntervalSince1970: 1_746_178_320)
        let seed = SegmentMembershipSeed(
            evaluatedAt: nil,
            memberships: [SeededSegmentMembership(segmentId: segment.id, enteredAt: enteredAt)]
        )
        await service.updateSegments([segment], for: distinctId)
        _ = await service.applySeed(seed, generation: 1, distinctId: distinctId)

        let reapplied = await service.applySeed(seed, generation: 2, distinctId: distinctId)

        XCTAssertEqual(reapplied?.hasChanges, false)
        XCTAssertEqual(reapplied?.remained.map(\.id), [segment.id])
        let persistedEnteredAt = await service.enteredAt(segment.id)
        XCTAssertEqual(persistedEnteredAt, enteredAt)
        await service.clearSegments(for: distinctId)
    }

    private func makeSegment(id: String) -> Segment {
        Segment(
            id: id,
            name: "Segment \(id)",
            condition: IREnvelope(
                ir_version: 1,
                engine_min: nil,
                compiled_at: nil,
                expr: .bool(true)
            ),
            evaluation: .server
        )
    }
}
