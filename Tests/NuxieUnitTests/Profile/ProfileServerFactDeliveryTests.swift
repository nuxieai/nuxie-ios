import Foundation
import Nimble
import Quick

@testable import Nuxie
@testable import NuxieTestSupport

final class ProfileServerFactDeliveryTests: AsyncSpec {
    override class func spec() {
        func makeService(
            _ mocks: MockFactory,
            segments: SegmentServiceProtocol? = nil
        ) -> ProfileService {
            ProfileService(
                cache: NullCachedProfileStore(),
                identity: mocks.identityService,
                api: mocks.nuxieApi,
                segments: segments ?? mocks.segmentService,
                flows: mocks.flowService,
                eventLog: mocks.eventLog,
                dateProvider: mocks.dateProvider,
                sleepProvider: mocks.sleepProvider
            )
        }

        describe("profile server facts and segment seeds") {
            it("commits down facts for the fetched identity") {
                let mocks = MockFactory.shared
                await mocks.resetAll()

                mocks.identityService.setDistinctId("user-1")
                let fact = JourneyDownFact(
                    id: "fact-profile-1",
                    event: .converted,
                    timestamp: Date(timeIntervalSince1970: 1_753_207_451),
                    properties: JourneyConvertedProperties(
                        journeyId: "journey-1",
                        at: Date(timeIntervalSince1970: 1_753_207_450),
                        sourceFactRef: "purchase-1"
                    )
                )
                await mocks.nuxieApi.setProfileResponse(ProfileResponse(
                    campaigns: [],
                    segments: [],
                    flows: [],
                    facts: [fact]
                ))
                let service = makeService(mocks)

                _ = try await service.refetchProfile(distinctId: "user-1")

                let commits = mocks.eventLog.committedServerFacts
                expect(commits).to(haveCount(1))
                expect(commits.first?.distinctId).to(equal("user-1"))
                expect(commits.first?.facts).to(equal([fact]))
                await service.clearAllCache()
            }

            it("applies authoritative segment seeds with server entry times") {
                let mocks = MockFactory.shared
                await mocks.resetAll()

                mocks.identityService.setDistinctId("user-1")
                let enteredAt = Date(timeIntervalSince1970: 1_746_178_320)
                let segment = Segment(
                    id: "segment-1",
                    name: "Purchasers",
                    condition: IREnvelope(
                        ir_version: 1,
                        engine_min: nil,
                        compiled_at: nil,
                        expr: .bool(true)
                    )
                )
                await mocks.nuxieApi.setProfileResponse(ProfileResponse(
                    campaigns: [],
                    segments: [segment],
                    flows: [],
                    segmentMemberships: SegmentMembershipSeed(
                        evaluatedAt: Date(timeIntervalSince1970: 1_753_207_451),
                        memberships: [
                            SeededSegmentMembership(segmentId: segment.id, enteredAt: enteredAt)
                        ]
                    )
                ))
                let service = makeService(mocks)

                _ = try await service.refetchProfile(distinctId: "user-1")

                await expect { await mocks.segmentService.isInSegment(segment.id) }.to(beTrue())
                await expect { await mocks.segmentService.enteredAt(segment.id) }.to(equal(enteredAt))
                await service.clearAllCache()
            }

            it("preserves historical entry time for entered_within after a fresh install") {
                let mocks = MockFactory.shared
                await mocks.resetAll()

                let distinctId = "reinstall-user"
                let segmentId = "recent-purchasers"
                let enteredAt = Date(timeIntervalSince1970: 1_753_200_000)
                let now = enteredAt.addingTimeInterval(30 * 60)
                let realSegmentService = SegmentService()
                mocks.identityService.setDistinctId(distinctId)
                await mocks.nuxieApi.setProfileResponse(ProfileResponse(
                    campaigns: [],
                    segments: [
                        Segment(
                            id: segmentId,
                            name: "Recent purchasers",
                            condition: IREnvelope(
                                ir_version: 1,
                                engine_min: nil,
                                compiled_at: nil,
                                expr: .bool(true)
                            ),
                            evaluation: .server
                        )
                    ],
                    flows: [],
                    segmentMemberships: SegmentMembershipSeed(
                        evaluatedAt: now,
                        memberships: [
                            SeededSegmentMembership(segmentId: segmentId, enteredAt: enteredAt)
                        ]
                    )
                ))
                let service = makeService(mocks, segments: realSegmentService)

                await expect { await realSegmentService.getCurrentMemberships() }.to(beEmpty())
                _ = try await service.refetchProfile(distinctId: distinctId)

                let adapter = IRSegmentQueriesAdapter(segmentService: realSegmentService)
                let interpreter = IRInterpreter(ctx: EvalContext(now: now, segments: adapter))
                let withinHour = try await interpreter.evalBool(
                    .segment(op: "entered_within", id: segmentId, within: .duration(60 * 60))
                )
                let withinTenMinutes = try await interpreter.evalBool(
                    .segment(op: "entered_within", id: segmentId, within: .duration(10 * 60))
                )

                await expect { await realSegmentService.enteredAt(segmentId) }.to(equal(enteredAt))
                expect(withinHour).to(beTrue())
                expect(withinTenMinutes).to(beFalse())
                await realSegmentService.clearSegments(for: distinctId)
                await service.clearAllCache()
            }
        }
    }
}
