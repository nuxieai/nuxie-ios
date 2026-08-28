import Foundation
import Nimble
import Quick

@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

final class SegmentSeedMirrorTests: AsyncSpec {
    override class func spec() {
        describe("admitted segment membership snapshots") {
            it("replaces membership state and treats an explicit empty snapshot as authoritative") {
                let service = SegmentService()
                let distinctId = "snapshot-user"
                let segment = Segment(id: "segment-1", name: "Segment 1")
                let enteredAt = Date(timeIntervalSince1970: 1_746_178_320)
                let evaluatedAt = Date(timeIntervalSince1970: 1_753_207_451)

                await service.replaceSnapshot(
                    SegmentMembershipSeed(
                        evaluatedAt: evaluatedAt,
                        memberships: [
                            SeededSegmentMembership(
                                segmentId: segment.id,
                                enteredAt: enteredAt
                            ),
                            SeededSegmentMembership(
                                segmentId: "dangling",
                                enteredAt: enteredAt
                            ),
                        ]
                    ),
                    definitions: [segment],
                    for: distinctId
                )

                await expect { await service.isInSegment(segment.id) }.to(beTrue())
                await expect { await service.isInSegment("dangling") }.to(beFalse())
                await expect { await service.enteredAt(segment.id) }.to(equal(enteredAt))

                await service.replaceSnapshot(
                    SegmentMembershipSeed(evaluatedAt: evaluatedAt, memberships: []),
                    definitions: [segment],
                    for: distinctId
                )

                await expect { await service.isInSegment(segment.id) }.to(beFalse())
                await expect { await service.snapshot(for: distinctId).memberships }.to(beEmpty())
            }

            it("never exposes one identity's membership through another identity") {
                let service = SegmentService()
                let segment = Segment(id: "segment-1", name: "Segment 1")
                let enteredAt = Date(timeIntervalSince1970: 1_746_178_320)

                await service.replaceSnapshot(
                    SegmentMembershipSeed(
                        evaluatedAt: nil,
                        memberships: [
                            SeededSegmentMembership(
                                segmentId: segment.id,
                                enteredAt: enteredAt
                            )
                        ]
                    ),
                    definitions: [segment],
                    for: "user-a"
                )

                await expect { await service.snapshot(for: "user-b").memberships }
                    .to(beEmpty())

                await service.replaceSnapshot(
                    SegmentMembershipSeed(evaluatedAt: nil, memberships: []),
                    definitions: [segment],
                    for: "user-b"
                )

                await expect { await service.isInSegment(segment.id) }.to(beFalse())
            }

            it("never enrolls a journey when membership changes") {
                let mocks = MockFactory.shared
                await mocks.resetAll()
                let distinctId = "membership-change-user"
                let segment = Segment(id: "segment-1", name: "Segment 1")
                mocks.identityService.setDistinctId(distinctId)
                let journeys = mocks.makeJourneyService(journeyStore: mocks.journeyStore)

                await mocks.segmentService.replaceSnapshot(
                    SegmentMembershipSeed(
                        evaluatedAt: nil,
                        memberships: [SeededSegmentMembership(
                            segmentId: segment.id,
                            enteredAt: Date(timeIntervalSince1970: 10)
                        )]
                    ),
                    definitions: [segment],
                    for: distinctId
                )
                await mocks.segmentService.replaceSnapshot(
                    .empty,
                    definitions: [segment],
                    for: distinctId
                )

                await expect { await journeys.getActiveJourneys(for: distinctId) }
                    .to(beEmpty())
                await journeys.shutdown()
                await mocks.resetAll()
            }
        }
    }
}
