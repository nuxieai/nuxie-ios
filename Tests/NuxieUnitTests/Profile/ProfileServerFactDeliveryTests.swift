import XCTest
import FactoryKit

@testable import Nuxie
@testable import NuxieTestSupport

final class ProfileServerFactDeliveryTests: XCTestCase {
    func testProfileFetchCommitsDownFactsForFetchedIdentity() async throws {
        let mocks = MockFactory.shared
        await mocks.resetAll()
        mocks.registerAll()
        defer {
            mocks.resetAllFactories()
        }

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
        let service = ProfileService(cache: NullCachedProfileStore())

        _ = try await service.fetchProfile(distinctId: "user-1")

        let commits = mocks.eventService.committedServerFacts
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits.first?.distinctId, "user-1")
        XCTAssertEqual(commits.first?.facts, [fact])
        await service.clearAllCache()
    }

    func testProfileFetchAppliesAuthoritativeSegmentSeedWithServerEnteredAt() async throws {
        let mocks = MockFactory.shared
        await mocks.resetAll()
        mocks.registerAll()
        defer {
            mocks.resetAllFactories()
        }

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
        let service = ProfileService(cache: NullCachedProfileStore())

        _ = try await service.fetchProfile(distinctId: "user-1")

        let isMember = await mocks.segmentService.isInSegment(segment.id)
        let storedEnteredAt = await mocks.segmentService.enteredAt(segment.id)
        XCTAssertTrue(isMember)
        XCTAssertEqual(storedEnteredAt, enteredAt)
        await service.clearAllCache()
    }

    func testFreshInstallSeedPreservesHistoricalEnteredAtForEnteredWithin() async throws {
        let mocks = MockFactory.shared
        await mocks.resetAll()
        mocks.registerAll()
        defer {
            mocks.resetAllFactories()
        }

        let distinctId = "reinstall-user"
        let segmentId = "recent-purchasers"
        let enteredAt = Date(timeIntervalSince1970: 1_753_200_000)
        let now = enteredAt.addingTimeInterval(30 * 60)
        let realSegmentService = SegmentService()
        Container.shared.segmentService.register { realSegmentService }
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
        let service = ProfileService(cache: NullCachedProfileStore())

        let membershipsBeforeProfile = await realSegmentService.getCurrentMemberships()
        XCTAssertEqual(membershipsBeforeProfile.count, 0)
        _ = try await service.fetchProfile(distinctId: distinctId)

        let adapter = IRSegmentQueriesAdapter(segmentService: realSegmentService)
        let interpreter = IRInterpreter(ctx: EvalContext(now: now, segments: adapter))
        let withinHour = try await interpreter.evalBool(
            .segment(op: "entered_within", id: segmentId, within: .duration(60 * 60))
        )
        let withinTenMinutes = try await interpreter.evalBool(
            .segment(op: "entered_within", id: segmentId, within: .duration(10 * 60))
        )

        let restoredEnteredAt = await realSegmentService.enteredAt(segmentId)
        XCTAssertEqual(restoredEnteredAt, enteredAt)
        XCTAssertTrue(withinHour)
        XCTAssertFalse(withinTenMinutes)
        await realSegmentService.clearSegments(for: distinctId)
        await service.clearAllCache()
    }
}
