import Foundation
import Nimble
import Quick
@_spi(Testing) @testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

private actor RefreshingTriggerSegmentService: SegmentServiceProtocol {
    private let admitted: SegmentMembershipSeed
    private let refreshed: SegmentMembershipSeed
    private(set) var liveQueryCount = 0
    private(set) var snapshotCount = 0
    private var didRefresh = false

    init(admitted: SegmentMembershipSeed, refreshed: SegmentMembershipSeed) {
        self.admitted = admitted
        self.refreshed = refreshed
    }

    func replaceSnapshot(
        _ snapshot: SegmentMembershipSeed,
        definitions: [Segment],
        for distinctId: String
    ) async {}

    func snapshot(for distinctId: String) async -> SegmentMembershipSeed {
        snapshotCount += 1
        let result = didRefresh ? refreshed : admitted
        // Deterministically model a profile refresh immediately after the
        // caller captures this generation.
        didRefresh = true
        return result
    }

    func clearSnapshot(for distinctId: String) async {}

    func isInSegment(_ segmentId: String) async -> Bool {
        liveQueryCount += 1
        let result = admitted.memberships.contains { $0.segmentId == segmentId }
        didRefresh = true
        return result
    }

    func enteredAt(_ segmentId: String) async -> Date? {
        admitted.memberships.first { $0.segmentId == segmentId }?.enteredAt
    }

    func forceRefresh() {
        didRefresh = true
    }
}

final class JourneyTriggerResultTests: AsyncSpec {
    override class func spec() {
        describe("handleEventForTrigger") {
            it("produces a typed trigger failure when enrollment cannot persist") {
                let mocks = MockFactory.shared
                await mocks.resetAll()

                let reference = ExperienceReference(
                    experienceId: "start-failure-experience",
                    versionId: "start-failure-version"
                )
                let experience = Experience(
                    id: reference.experienceId,
                    versionId: reference.versionId,
                    name: "Start Failure",
                    reentry: .everyTime,
                    publishedAt: "2026-08-23T00:00:00Z",
                    trigger: .event(EventTriggerConfig(
                        eventName: "start_failure",
                        condition: nil
                    )),
                    goal: nil,
                    exitPolicy: nil,
                    conversionAnchor: nil,
                    experienceType: nil
                )
                mocks.profileService.effectiveExperienceReferences = [reference]
                mocks.profileService.activeExperienceReferences = [reference]
                mocks.experienceService.mockExperiences[reference.versionId] = experience
                mocks.eventLog.trackWithResponseError = NSError(
                    domain: "JourneyTriggerResultTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "enrollment persistence failed"]
                )
                let service = mocks.makeJourneyService(journeyStore: mocks.journeyStore)

                let results = await service.handleEventForTrigger(
                    TestEventBuilder(name: "start_failure")
                        .withDistinctId("start-failure-user")
                        .build()
                )
                await mocks.resetAll()

                guard case .error(let error) = results.first else {
                    return fail("expected a terminal trigger error")
                }
                expect(results).to(haveCount(1))
                expect(error.code).to(equal(.triggerFailed))
            }

            it("routes against the catalog generation captured by admission") {
                let mocks = MockFactory.shared
                await mocks.resetAll()

                let admittedReference = ExperienceReference(
                    experienceId: "admitted-experience",
                    versionId: "admitted-version"
                )
                let admittedExperience = Experience(
                    id: admittedReference.experienceId,
                    versionId: admittedReference.versionId,
                    name: "Admitted Generation",
                    reentry: .everyTime,
                    publishedAt: "2026-08-28T00:00:00Z",
                    trigger: .event(EventTriggerConfig(
                        eventName: "generation-pinned-trigger",
                        condition: nil
                    )),
                    goal: nil,
                    exitPolicy: nil,
                    conversionAnchor: nil,
                    experienceType: nil
                )
                mocks.experienceService.mockExperiences = [
                    admittedReference.versionId: admittedExperience
                ]
                let admittedCatalog = try await mocks.experienceService.commitReleaseProfile(
                    PreparedExperienceReleaseProfile(
                        profile: nil,
                        catalog: nil,
                        references: [admittedReference]
                    ),
                    generation: 1
                )
                guard let admittedCatalog else {
                    return fail("expected generation 1 to commit")
                }
                mocks.profileService.effectiveExperienceReferences = [admittedReference]
                mocks.profileService.activeExperienceReferences = [admittedReference]
                mocks.profileService.routingCatalog = admittedCatalog

                let replacementReference = ExperienceReference(
                    experienceId: "replacement-experience",
                    versionId: "replacement-version"
                )
                let replacementExperience = Experience(
                    id: replacementReference.experienceId,
                    versionId: replacementReference.versionId,
                    name: "Replacement Generation",
                    reentry: .everyTime,
                    publishedAt: "2026-08-28T00:00:01Z",
                    trigger: nil,
                    goal: nil,
                    exitPolicy: nil,
                    conversionAnchor: nil,
                    experienceType: nil
                )
                mocks.experienceService.mockExperiences = [
                    replacementReference.versionId: replacementExperience
                ]
                _ = try await mocks.experienceService.commitReleaseProfile(
                    PreparedExperienceReleaseProfile(
                        profile: nil,
                        catalog: nil,
                        references: [replacementReference]
                    ),
                    generation: 2
                )

                do {
                    _ = try await mocks.experienceService.experienceForJourneyControl(
                        experienceId: admittedReference.experienceId,
                        versionId: admittedReference.versionId
                    )
                    return fail("expected the live catalog to have replaced generation 1")
                } catch {
                    // The captured admission is now the only authority that
                    // can resolve the generation 1 trigger.
                }

                let service = mocks.makeJourneyService(journeyStore: mocks.journeyStore)
                let results = await service.handleEventForTrigger(
                    TestEventBuilder(name: "generation-pinned-trigger")
                        .withDistinctId("generation-pinned-user")
                        .build()
                )

                guard case .started(let journey) = results.first else {
                    await mocks.resetAll()
                    return fail("expected routing to start the admitted generation")
                }
                let snapshot = await journey.snapshot()
                expect(snapshot.experienceId).to(equal(admittedReference.experienceId))
                expect(results).to(haveCount(1))
                await mocks.resetAll()
            }

            it("pins one membership snapshot across trigger IR and journey creation") {
                let mocks = MockFactory.shared
                await mocks.resetAll()
                let segmentId = "admitted-segment"
                let admitted = SegmentMembershipSeed(
                    evaluatedAt: Date(timeIntervalSince1970: 10),
                    memberships: [SeededSegmentMembership(
                        segmentId: segmentId,
                        enteredAt: Date(timeIntervalSince1970: 5)
                    )]
                )
                let refreshed = SegmentMembershipSeed(
                    evaluatedAt: Date(timeIntervalSince1970: 20),
                    memberships: []
                )
                let segments = RefreshingTriggerSegmentService(
                    admitted: admitted,
                    refreshed: refreshed
                )
                let reference = ExperienceReference(
                    experienceId: "snapshot-experience",
                    versionId: "snapshot-version"
                )
                let experience = Experience(
                    id: reference.experienceId,
                    versionId: reference.versionId,
                    name: "Snapshot",
                    reentry: .everyTime,
                    publishedAt: "2026-08-23T00:00:00Z",
                    trigger: .event(EventTriggerConfig(
                        eventName: "snapshot-trigger",
                        condition: IREnvelope(
                            ir_version: 1,
                            engine_min: "1.0.0",
                            compiled_at: 1_700_000_000,
                            expr: .segment(op: "is_member", id: segmentId, within: nil)
                        )
                    )),
                    goal: nil,
                    exitPolicy: nil,
                    conversionAnchor: nil,
                    experienceType: nil
                )
                mocks.profileService.effectiveExperienceReferences = [reference]
                mocks.profileService.activeExperienceReferences = [reference]
                mocks.profileService.triggerSegmentMemberships = admitted
                mocks.experienceService.mockExperiences[reference.versionId] = experience
                let service = mocks.makeJourneyService(
                    journeyStore: mocks.journeyStore,
                    segments: segments
                )
                await segments.forceRefresh()

                let results = await service.handleEventForTrigger(
                    TestEventBuilder(name: "snapshot-trigger")
                        .withDistinctId("snapshot-user")
                        .build()
                )

                guard case .started(let journey) = results.first else {
                    return fail("expected the admitted snapshot to start a journey")
                }
                let snapshot = await journey.snapshot()
                expect(snapshot.segmentMemberships).to(equal(admitted))
                await expect { await segments.snapshotCount }.to(equal(0))
                await expect { await segments.liveQueryCount }.to(equal(0))
                await mocks.resetAll()
            }
        }
    }
}
