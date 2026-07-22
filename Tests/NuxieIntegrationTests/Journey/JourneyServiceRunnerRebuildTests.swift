import Foundation
import Quick
import Nimble
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

/// On-demand runner rebuild for restored journeys.
///
/// `JourneyService.initialize()` restores persisted journeys without runners;
/// historically only the timer-resume path rebuilt one, so an active restored
/// journey was deaf to events. Event dispatch now rebuilds the runner lazily
/// through the same `ensureRunner` path timer resume uses. These tests model
/// the relaunch with a SECOND JourneyService over the same journey store.
final class JourneyServiceRunnerRebuildTests: AsyncSpec {
    override class func spec() {
        var mocks: MockFactory!
        var journeyStore: MockJourneyStore!
        var service: JourneyService!

        let distinctId = "user_rebuild"
        let flowId = "flow-rebuild"
        let campaignId = "camp-rebuild"

        func makeCampaign() -> Campaign {
            Campaign(
                id: campaignId,
                name: "Runner Rebuild Campaign",
                flowId: flowId,
                flowNumber: 1,
                flowName: nil,
                reentry: .everyTime,
                publishedAt: Date().ISO8601Format(),
                trigger: .event(EventTriggerConfig(eventName: "rebuild_trigger", condition: nil)),
                goal: nil,
                exitPolicy: nil,
                conversionAnchor: nil,
                campaignType: nil
            )
        }

        /// A flow whose journey-level "poke" handler tracks an effect and
        /// exits — the handler a restored, runner-less journey used to miss.
        func makeFlow() -> Experience {
            let pokeHandler = JourneyEventHandler(
                id: "h-poke",
                eventName: "poke",
                actions: [
                    .sendEvent(SendEventAction(eventName: "poke_effect", properties: nil)),
                    .exit(ExitAction(reason: "completed")),
                ]
            )
            let screens = RemoteFlow(
                id: flowId,
                flowArtifact: FlowArtifact(
                    url: "https://example.com/flow/\(flowId)",
                    manifest: BuildManifest(
                        totalFiles: 1,
                        totalSize: 100,
                        contentHash: "test-hash",
                        files: [BuildFile(path: "index.html", size: 100, contentType: "text/html")]
                    )
                ),
                screens: [
                    RemoteFlowScreen(
                        id: "screen-1",
                        defaultViewModelName: nil,
                        defaultInstanceId: nil
                    )
                ],
                events: [:],
                handlers: [RemoteFlow.journeyEventHostKey: [pokeHandler]],
                viewModelValues: nil
            )
            return Experience(screens: screens, products: [])
        }

        func primeProfile(flow: Experience?) async {
            mocks.identityService.setDistinctId(distinctId)
            mocks.flowService.mockExperiences.removeAll()
            if let flow {
                mocks.flowService.mockExperiences[flowId] = flow
            }
            mocks.profileService.setProfileResponse(
                ResponseBuilders.buildProfileResponse(
                    campaigns: [makeCampaign()],
                    flows: [makeFlow().screens]
                )
            )
            _ = try? await mocks.profileService.refetchProfile(distinctId: distinctId)
        }

        /// Session 1: enroll a journey and leave it active + persisted, then
        /// drop the service (the "kill").
        func enrollAndDropService() async {
            await service.initialize()
            let startEvent = NuxieEvent(name: "rebuild_trigger", distinctId: distinctId)
            await service.handleEvent(startEvent)
            let active = await service.getActiveJourneys(for: distinctId)
            expect(active).to(haveCount(1))
            expect(journeyStore.loadActiveJourneys()).to(haveCount(1))
            await service.shutdown()
        }

        beforeEach { @MainActor in
            mocks = MockFactory.shared
            mocks.dateProvider.setCurrentDate(Date())
            journeyStore = MockJourneyStore()
            service = mocks.makeJourneyService(journeyStore: journeyStore)
        }

        afterEach {
            await service?.shutdown()
        }

        it("rebuilds a runner on demand when an event reaches a restored journey") {
            await primeProfile(flow: makeFlow())
            await enrollAndDropService()

            // "Relaunch": a fresh service over the same store restores the
            // journey without a runner.
            service = mocks.makeJourneyService(journeyStore: journeyStore)
            await service.initialize()
            await expect { await service.getActiveJourneys(for: distinctId) }
                .to(haveCount(1))

            // The first event to reach the restored journey rebuilds the
            // runner and dispatches: the persisted handler chain runs and the
            // journey completes.
            await service.handleEvent(NuxieEvent(name: "poke", distinctId: distinctId))

            await expect { mocks.eventLog.trackedEvents.map(\.name) }
                .toEventually(contain("poke_effect"), timeout: .seconds(2))
            await expect { await service.getActiveJourneys(for: distinctId) }
                .toEventually(beEmpty(), timeout: .seconds(2))
            expect(journeyStore.loadActiveJourneys()).to(beEmpty())
        }

        it("rebuilds the runner once and keeps dispatching on subsequent events") {
            await primeProfile(flow: makeFlow())
            await enrollAndDropService()

            service = mocks.makeJourneyService(journeyStore: journeyStore)
            await service.initialize()

            // An unrelated event first: rebuild happens, nothing dispatches.
            await service.handleEvent(NuxieEvent(name: "unrelated", distinctId: distinctId))
            await expect { await service.getActiveJourneys(for: distinctId) }
                .to(haveCount(1))
            expect(mocks.eventLog.trackedEvents.map(\.name)).toNot(contain("poke_effect"))

            // The matching event then runs the chain exactly once.
            await service.handleEvent(NuxieEvent(name: "poke", distinctId: distinctId))
            await expect {
                mocks.eventLog.trackedEvents.filter { $0.name == "poke_effect" }.count
            }.toEventually(equal(1), timeout: .seconds(2))
            await expect { await service.getActiveJourneys(for: distinctId) }
                .toEventually(beEmpty(), timeout: .seconds(2))
        }

        it("keeps the restored journey alive when the flow cannot be rebuilt (offline cache miss)") {
            await primeProfile(flow: makeFlow())
            await enrollAndDropService()

            // Relaunch with the flow bundle unavailable: rebuild fails, but
            // the journey must NOT be cancelled or errored out — dispatch
            // skips the event (previous runner-less behavior) and a later
            // launch with the bundle can still run it.
            await primeProfile(flow: nil)
            service = mocks.makeJourneyService(journeyStore: journeyStore)
            await service.initialize()

            await service.handleEvent(NuxieEvent(name: "poke", distinctId: distinctId))

            await expect { await service.getActiveJourneys(for: distinctId) }
                .to(haveCount(1))
            expect(journeyStore.loadActiveJourneys()).to(haveCount(1))
            expect(mocks.eventLog.trackedEvents.map(\.name)).toNot(contain("poke_effect"))
            expect(mocks.eventLog.trackedEvents.map(\.name)).toNot(contain("$journey_completed"))
        }
    }
}
