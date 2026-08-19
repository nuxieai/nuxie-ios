import Foundation
import Nimble
import Quick
@testable import Nuxie
@testable import NuxieTestSupport

final class JourneyScreenControlRoutingTests: AsyncSpec {
    override class func spec() {
        nonisolated(unsafe) var mocks: MockFactory!
        nonisolated(unsafe) var store: MockJourneyStore!
        nonisolated(unsafe) var service: JourneyService!
        nonisolated(unsafe) var controller: MockExperienceViewController!

        let distinctId = "screen-control-user"
        let experienceId = "screen-control-experience"
        let versionId = "screen-control-version"

        func definition(eventName: String) -> ExperienceDefinitionV2 {
            ExperienceDefinitionV2(
                entryRouteEventName: "paywall_trigger",
                screens: [JourneyScreenV2(
                    id: "screen-1",
                    defaultViewModelName: nil,
                    defaultInstanceId: nil
                )],
                viewModelValues: [],
                routes: [:],
                executionPlans: [],
                responseSchema: nil,
                controlsByScreen: [
                    "screen-1": [
                        "submit": ScreenControlActionDefinition(
                            actionId: "submit",
                            binding: .declarative([
                                .emit(eventName: eventName, payload: [
                                    "answer": .invocationValue,
                                    "component": .componentId,
                                    "instance": .instanceId,
                                ])
                            ])
                        )
                    ]
                ]
            )
        }

        func signedExperience(
            definition: ExperienceDefinitionV2
        ) -> Experience {
            let identity = ExperienceReleaseIdentityV2(
                appId: "test-app",
                environment: "test",
                experienceId: experienceId,
                experienceVersionId: versionId,
                buildId: "signed-build",
                versionNumber: 1,
                publishedAt: "2026-08-13T00:00:00.000Z",
                publishedAtSeq: 1
            )
            return Experience(
                behavior: ExperienceBehaviorDefinition(
                    reference: .init(experienceId: experienceId, versionId: versionId),
                    buildId: identity.buildId,
                    artifactContentHash: String(repeating: "a", count: 64),
                    name: "Signed screen controls",
                    reentry: .everyTime,
                    publishedAt: identity.publishedAt,
                    trigger: .event(.init(eventName: "paywall_trigger", condition: nil)),
                    goal: nil,
                    exitPolicy: nil,
                    conversionAnchor: nil,
                    timeLimitSeconds: nil,
                    experienceType: nil,
                    presentationStyle: .fullScreen
                ),
                journey: definition.renderShell,
                definitionV2: definition,
                assetBaseURL: URL(string: "https://assets.nuxie.ai/")!,
                authenticatedReleaseID: .init(
                    identity: identity,
                    descriptorSHA256: String(repeating: "b", count: 64)
                )
            )
        }

        func install(_ experience: Experience) async {
            mocks.identityService.setDistinctId(distinctId)
            let reference = ExperienceReference(
                experienceId: experience.id,
                versionId: experience.versionId
            )
            mocks.profileService.effectiveExperienceReferences = [reference]
            mocks.profileService.activeExperienceReferences = [reference]
            mocks.experienceService.mockExperiences[experience.versionId] = experience
            mocks.profileService.setProfileResponse(
                ResponseBuilders.buildProfileResponse(experiences: [experience])
            )
            _ = try? await mocks.profileService.refetchProfile(distinctId: distinctId)
        }

        func start(_ experience: Experience) async -> Journey? {
            await install(experience)
            await service.initialize()
            let journey = await service.startJourney(for: experience, distinctId: distinctId)
            if let journey {
                await service.handleRuntimeReady(journeyId: journey.id, controller: controller)
            }
            return journey
        }

        beforeEach { @MainActor in
            mocks = MockFactory.shared
            mocks.dateProvider.setCurrentDate(Date())
            store = MockJourneyStore()
            service = mocks.makeJourneyService(journeyStore: store)
            controller = MockExperienceViewController(mockExperienceVersionId: versionId)
            mocks.experiencePresentationService.defaultMockViewController = controller
        }

        it("routes a generated control through its signed definition and journals the result") {
            let eventName = "survey_submitted"
            let experience = signedExperience(definition: definition(eventName: eventName))
            guard let journey = await start(experience) else {
                fail("expected signed journey")
                return
            }

            await service.handleRendererControlAction(
                journeyId: journey.id,
                screenId: "screen-1",
                invocation: ScreenActionInvocation(
                    actionId: "submit",
                    value: .string("premium"),
                    componentId: "submit-button",
                    instanceId: "survey-1"
                )
            )

            let routed = mocks.eventLog.routedEvents.first { $0.name == eventName }
            expect(routed?.properties["answer"] as? String).to(equal("premium"))
            expect(routed?.properties["component"] as? String).to(equal("submit-button"))
            let routing = (await journey.snapshot()).executionState.screenRouting
            expect(routing.eventRecords[routed?.id ?? ""]?.phase).to(equal(.finished))
            expect(routing.batchReceipts["0"]?.result.status).to(equal(.drained))
            expect(routing.pendingBatches).to(beEmpty())
            let encoded = try JSONEncoder().encode(await journey.snapshot())
            expect(encoded).toNot(beEmpty())
        }

        it("rejects an invocation captured from an older presentation epoch") {
            let eventName = "stale_control_must_not_emit"
            let experience = signedExperience(definition: definition(eventName: eventName))
            guard let journey = await start(experience),
                  let stale = await service.screenControlRunScope(journeyId: journey.id) else {
                fail("expected live signed run scope")
                return
            }
            await journey.update { $0.executionState.presentationEpoch &+= 1 }

            await service.handleRendererControlAction(
                journeyId: journey.id,
                scope: stale,
                invocation: ScreenActionInvocation(
                    actionId: "submit",
                    value: .string("ignored"),
                    componentId: "submit-button",
                    instanceId: "survey-1"
                )
            )

            expect(mocks.eventLog.routedEvents.map(\.name)).toNot(contain(eventName))
        }

        it("does not re-enroll the source experience from its own generated event") {
            let eventName = "paywall_trigger"
            let experience = signedExperience(definition: definition(eventName: eventName))
            guard let journey = await start(experience) else {
                fail("expected signed journey")
                return
            }

            await service.handleRendererControlAction(
                journeyId: journey.id,
                screenId: "screen-1",
                invocation: ScreenActionInvocation(
                    actionId: "submit",
                    value: .string("done"),
                    componentId: "submit-button",
                    instanceId: "survey-1"
                )
            )

            let active = await service.getActiveJourneys(for: distinctId)
            expect(active.map(\.id)).to(equal([journey.id]))
        }
    }
}
