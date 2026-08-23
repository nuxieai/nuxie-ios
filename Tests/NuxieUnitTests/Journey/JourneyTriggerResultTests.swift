import Foundation
import Nimble
import Quick
@_spi(Testing) @testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

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
        }
    }
}
