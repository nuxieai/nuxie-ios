import Foundation
import Nimble
import Quick

@testable import Nuxie

final class SegmentSeedMirrorTests: AsyncSpec {
    override class func spec() {
        describe("server segment seed mirror") {
            it("is authoritative, scoped, idempotent, and generation ordered") {
                let service = SegmentService()
                let distinctId = "seed-mirror-\(UUID().uuidString)"
                let segment = Self.makeSegment(id: "segment-1")
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

                expect(initial?.entered.map(\.id)).to(equal([segment.id]))
                let memberships = await service.getCurrentMemberships()
                let seededEnteredAt = await service.enteredAt(segment.id)
                expect(memberships.map(\.segmentId)).to(equal([segment.id]))
                expect(seededEnteredAt).to(equal(enteredAt))

                let duplicate = await service.applySeed(
                    SegmentMembershipSeed(evaluatedAt: evaluatedAt, memberships: []),
                    generation: 1,
                    distinctId: distinctId
                )
                expect(duplicate).to(beNil())
                await expect { await service.isInSegment(segment.id) }.to(beTrue())

                let absent = await service.applySeed(nil, generation: 2, distinctId: distinctId)
                expect(absent).to(beNil())
                await expect { await service.isInSegment(segment.id) }.to(beTrue())

                let emptied = await service.applySeed(
                    SegmentMembershipSeed(evaluatedAt: evaluatedAt, memberships: []),
                    generation: 2,
                    distinctId: distinctId
                )
                expect(emptied?.exited.map(\.id)).to(equal([segment.id]))
                await expect { await service.isInSegment(segment.id) }.to(beFalse())

                let stale = await service.applySeed(seed, generation: 1, distinctId: distinctId)
                expect(stale).to(beNil())
                await expect { await service.isInSegment(segment.id) }.to(beFalse())

                await service.clearSegments(for: distinctId)
            }

            it("does not emit a change for an identical new generation") {
                let service = SegmentService()
                let distinctId = "seed-idempotent-\(UUID().uuidString)"
                let segment = Self.makeSegment(id: "segment-1")
                let enteredAt = Date(timeIntervalSince1970: 1_746_178_320)
                let seed = SegmentMembershipSeed(
                    evaluatedAt: nil,
                    memberships: [
                        SeededSegmentMembership(segmentId: segment.id, enteredAt: enteredAt)
                    ]
                )
                await service.updateSegments([segment], for: distinctId)
                _ = await service.applySeed(seed, generation: 1, distinctId: distinctId)

                let reapplied = await service.applySeed(
                    seed,
                    generation: 2,
                    distinctId: distinctId
                )

                expect(reapplied?.hasChanges).to(beFalse())
                expect(reapplied?.remained.map(\.id)).to(equal([segment.id]))
                await expect { await service.enteredAt(segment.id) }.to(equal(enteredAt))
                await service.clearSegments(for: distinctId)
            }
        }
    }

    private static func makeSegment(id: String) -> Segment {
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
