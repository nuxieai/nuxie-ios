#if LEGACY_JOURNEY_TESTS
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
        let experienceId = "experience-rebuild"

        func makeExperience(versionId: String = flowId) -> Experience {
            Experience(
                id: experienceId,
                versionId: versionId,
                name: "Runner Rebuild Experience",
                reentry: .everyTime,
                publishedAt: Date().ISO8601Format(),
                trigger: .event(EventTriggerConfig(eventName: "rebuild_trigger", condition: nil)),
                goal: nil,
                exitPolicy: nil,
                conversionAnchor: nil,
                experienceType: nil
            )
        }

        /// A flow whose journey-level "poke" handler tracks an effect and
        /// exits — the handler a restored, runner-less journey used to miss.
        func makeLoadedExperience(
            id: String = flowId,
            effectEventName: String = "poke_effect"
        ) -> Experience {
            let pokeHandler = JourneyEventHandler(
                id: "h-poke",
                eventName: "poke",
                actions: [
                    .sendEvent(SendEventAction(eventName: effectEventName, properties: nil)),
                    .exit(ExitAction(reason: "completed")),
                ]
            )
            let screens = JourneyDocument(
                screens: [
                    JourneyScreen(
                        id: "screen-1",
                        defaultViewModelName: nil,
                        defaultInstanceId: nil
                    )
                ],
                events: [
                    JourneyDocument.journeyEventHostKey: [
                        EventDeclaration(id: "event-poke", eventName: "poke")
                    ]
                ],
                handlers: [JourneyDocument.journeyEventHostKey: [pokeHandler]],
                viewModelValues: nil
            )
            return Experience.test(
                journey: screens,
                experienceId: experienceId,
                versionId: id,
                products: []
            )
        }

        func primeProfile(package: Experience?) async {
            mocks.identityService.setDistinctId(distinctId)
            mocks.experienceService.mockExperiences.removeAll()
            if let package {
                let metadata = makeExperience(versionId: package.versionId)
                mocks.experienceService.mockExperiences[package.versionId] = Experience(
                    metadata: metadata,
                    journey: package.journey,
                    assetBaseURL: package.assetBaseURL
                )
            }
            let reference = ExperienceReference(
                experienceId: experienceId,
                versionId: flowId
            )
            mocks.profileService.effectiveExperienceReferences = [reference]
            mocks.profileService.activeExperienceReferences = [reference]
            mocks.profileService.setProfileResponse(
                ProfileResponse(segments: [])
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
            await primeProfile(package: makeLoadedExperience())
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
            await primeProfile(package: makeLoadedExperience())
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

        it("rebuilds a restored runner with its pinned version after the active version advances") {
            let pinnedFlow = makeLoadedExperience()
            await primeProfile(package: pinnedFlow)
            await enrollAndDropService()

            let activeVersionId = "flow-rebuild-v2"
            let activeFlow = makeLoadedExperience(
                id: activeVersionId,
                effectEventName: "poke_effect_v2"
            )
            mocks.experienceService.mockExperiences = [
                flowId: Experience(
                    metadata: makeExperience(),
                    journey: pinnedFlow.journey,
                    assetBaseURL: pinnedFlow.assetBaseURL
                ),
                activeVersionId: Experience(
                    metadata: makeExperience(versionId: activeVersionId),
                    journey: activeFlow.journey,
                    assetBaseURL: activeFlow.assetBaseURL
                ),
            ]
            mocks.profileService.effectiveExperienceReferences = [
                ExperienceReference(experienceId: experienceId, versionId: activeVersionId),
                ExperienceReference(experienceId: experienceId, versionId: flowId),
            ]
            mocks.profileService.activeExperienceReferences = [
                ExperienceReference(experienceId: experienceId, versionId: activeVersionId)
            ]
            mocks.profileService.setProfileResponse(
                ProfileResponse(
                    segments: [],
                )
            )
            _ = try? await mocks.profileService.refetchProfile(distinctId: distinctId)

            service = mocks.makeJourneyService(journeyStore: journeyStore)
            await service.initialize()
            await service.handleEvent(NuxieEvent(name: "poke", distinctId: distinctId))

            await expect { mocks.eventLog.trackedEvents.map(\.name) }
                .toEventually(contain("poke_effect"), timeout: .seconds(2))
            expect(mocks.eventLog.trackedEvents.map(\.name))
                .toNot(contain("poke_effect_v2"))
        }

        it("keeps the restored journey alive when the flow cannot be rebuilt (offline cache miss)") {
            await primeProfile(package: makeLoadedExperience())
            await enrollAndDropService()

            // Relaunch with the flow bundle unavailable: rebuild fails, but
            // the journey must NOT be cancelled or errored out — dispatch
            // skips the event (previous runner-less behavior) and a later
            // launch with the bundle can still run it.
            await primeProfile(package: nil)
            service = mocks.makeJourneyService(journeyStore: journeyStore)
            await service.initialize()

            await service.handleEvent(NuxieEvent(name: "poke", distinctId: distinctId))

            await expect { await service.getActiveJourneys(for: distinctId) }
                .to(haveCount(1))
            expect(journeyStore.loadActiveJourneys()).to(haveCount(1))
            expect(mocks.eventLog.trackedEvents.map(\.name)).toNot(contain("poke_effect"))
            expect(mocks.eventLog.trackedEvents.map(\.name)).toNot(contain("$journey_exited"))
        }

        it("does not replay a canonical entry side effect after a crash and JourneyStore restore") { @MainActor in
            let tempRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("nuxie-entry-claim-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: tempRoot) }

            let entrySideEffect = "canonical_entry_side_effect"
            let entryDocument = JourneyDocument(
                screens: [JourneyScreen(id: "screen-1")],
                events: [
                    JourneyDocument.journeyEventHostKey: [
                        EventDeclaration(
                            id: "event-journey-started",
                            eventName: SystemEventNames.journeyStarted
                        )
                    ]
                ],
                handlers: [
                    JourneyDocument.journeyEventHostKey: [
                        JourneyEventHandler(
                            id: "canonical-entry",
                            eventName: SystemEventNames.journeyStarted,
                            actions: [
                                .sendEvent(SendEventAction(
                                    eventName: entrySideEffect,
                                    properties: nil
                                ))
                            ]
                        )
                    ]
                ]
            )
            let loadedExperience = Experience.test(
                journey: entryDocument,
                experienceId: experienceId,
                versionId: flowId,
                products: []
            )
            await primeProfile(package: loadedExperience)

            let persistentStore = JourneyStore(
                customStoragePath: tempRoot,
                dateProvider: mocks.dateProvider
            )
            let controller = MockExperienceViewController(mockExperienceVersionId: flowId)
            mocks.experiencePresentationService.defaultMockViewController = controller
            service = mocks.makeJourneyService(journeyStore: persistentStore)
            await service.initialize()
            await service.handleEvent(NuxieEvent(name: "rebuild_trigger", distinctId: distinctId))

            let active = await service.getActiveJourneys(for: distinctId)
            expect(active).to(haveCount(1))
            guard let journey = active.first else { return }

            await service.handleRuntimeReady(journeyId: journey.id, controller: controller)
            await expect {
                mocks.eventLog.trackedEvents.filter { $0.name == entrySideEffect }
            }.toEventually(haveCount(1), timeout: .seconds(2))
            expect(
                persistentStore.loadJourney(id: journey.id)?
                    .context["_entry_actions_ran"]?.value as? Bool
            ).to(beTrue())

            // Model a process death: shutdown only cancels timers and does not
            // take a graceful background snapshot. A new service must restore
            // the durable entry claim before rebuilding the runner.
            await service.shutdown()
            service = mocks.makeJourneyService(journeyStore: persistentStore)
            await service.initialize()
            await service.handleEvent(NuxieEvent(name: "unrelated", distinctId: distinctId))

            let restored = await service.getActiveJourneys(for: distinctId)
            expect(restored).to(haveCount(1))
            guard let restoredJourney = restored.first else { return }
            await service.handleRuntimeReady(
                journeyId: restoredJourney.id,
                controller: controller
            )

            await expect {
                mocks.eventLog.trackedEvents.filter { $0.name == entrySideEffect }
            }.toAlways(haveCount(1), until: .milliseconds(200))
        }
    }
}
#endif
