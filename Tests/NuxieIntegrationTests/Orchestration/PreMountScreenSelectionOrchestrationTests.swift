import Foundation
import Nimble
import Quick
import XCTest
@_spi(Testing) @testable import Nuxie
@testable import NuxieTestSupport

final class PreMountScreenSelectionOrchestrationTests: AsyncSpec {
    override class func spec() {
        describe("authenticated pre-mount journey control") {
            var storageURLs: [URL] = []
            var cores: [NuxieCore] = []

            beforeEach {
                StubURLProtocol.reset()
            }

            afterEach {
                for core in cores {
                    await core.journeys.shutdown()
                    await core.eventLog.close()
                }
                cores.removeAll()
                StubURLProtocol.reset()
                for url in storageURLs {
                    try? FileManager.default.removeItem(at: url)
                }
                storageURLs.removeAll()
            }

            it("selects either conditional entry screen before presentation") {
                for selectsSecondScreen in [false, true] {
                    let fixture = try ExperienceReleaseTestFixture.make(
                        selectSecondScreen: selectsSecondScreen
                    )
                    let storageURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent(
                            "nuxie-pre-mount-\(UUID().uuidString)",
                            isDirectory: true
                        )
                    storageURLs.append(storageURL)
                    let api = MockNuxieApi()
                    await api.setProfileResponse(ProfileResponse(
                        segments: [],
                        releases: .init(
                            delivery: fixture.delivery,
                            active: [fixture.entry],
                            pinned: []
                        )
                    ))
                    let presentation = MockExperiencePresentationService()
                    let core = try await makeCore(
                        storageURL: storageURL,
                        api: api,
                        presentation: presentation
                    )
                    cores.append(core)

                    _ = try await core.profile.refetchProfile(
                        distinctId: core.identity.getDistinctId()
                    )
                    core.eventLog.track(
                        SystemEventNames.appOpened,
                        properties: nil,
                        userProperties: nil,
                        userPropertiesSetOnce: nil
                    )
                    await core.eventLog.drain()

                    expect(presentation.presentExperienceCallCount).to(equal(1))
                    expect(presentation.initialScreenIDs.last ?? nil).to(equal(
                        selectsSecondScreen ? "screen_offer" : "screen_welcome"
                    ))
                    let journey = try XCTUnwrap(
                        presentation.presentedExperiences.last?.journey
                    )
                    let state = await journey.snapshot()
                    expect(state.executionState.currentScreenId).to(beNil())
                    expect(state.executionState.pendingPresentation?.screenId).to(equal(
                        selectsSecondScreen ? "screen_offer" : "screen_welcome"
                    ))
                }
            }

            it("admits a typed renderer batch through the production journey bridge") { @MainActor in
                let fixture = try ExperienceReleaseTestFixture.make()
                let storageURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(
                        "nuxie-renderer-batch-\(UUID().uuidString)",
                        isDirectory: true
                    )
                storageURLs.append(storageURL)
                let api = MockNuxieApi()
                await api.setProfileResponse(ProfileResponse(
                    segments: [],
                    releases: .init(
                        delivery: fixture.delivery,
                        active: [fixture.entry],
                        pinned: []
                    )
                ))
                let presentation = MockExperiencePresentationService()
                let core = try await makeCore(
                    storageURL: storageURL,
                    api: api,
                    presentation: presentation
                )
                cores.append(core)

                _ = try await core.profile.refetchProfile(
                    distinctId: core.identity.getDistinctId()
                )
                let signedExperience = try await core.experiences
                    .experienceForJourneyControl(
                        experienceId: fixture.entry.locator.experienceId,
                        versionId: fixture.entry.locator.experienceVersionId
                    )
                let controller = MockExperienceViewController(
                    mockExperienceVersionId: fixture.entry.locator.experienceVersionId,
                    mockExperience: signedExperience
                )
                presentation.defaultMockViewController = controller
                core.eventLog.track(
                    SystemEventNames.appOpened,
                    properties: nil,
                    userProperties: nil,
                    userPropertiesSetOnce: nil
                )
                await core.eventLog.drain()

                let service = try XCTUnwrap(core.journeys as? JourneyService)
                let journey = try XCTUnwrap(presentation.lastPresentedJourney)
                let bridge = try XCTUnwrap(controller.runtimeDelegate)
                let didActivateInitialScreen = await bridge
                    .experienceViewControllerWillActivateInitialScreen(
                        controller
                    )
                expect(didActivateInitialScreen).to(beTrue())
                let didDispatchInitialLifecycle = await bridge
                    .experienceViewControllerWillDispatchInitialScreenLifecycle(
                        controller,
                        screenId: "screen_welcome"
                    )
                expect(didDispatchInitialLifecycle).to(beTrue())
                await service.handleRuntimeReady(
                    journeyId: journey.id,
                    controller: controller
                )

                let runScope = await service.screenControlRunScope(journeyId: journey.id)
                let scope = try XCTUnwrap(runScope)
                expect(scope.screenId).to(equal("screen_welcome"))
                await controller.publishScreenInput(.control(
                    screenId: scope.screenId,
                    invocation: ScreenActionInvocation(actionId: "continue"),
                    additionalDrafts: []
                ))
                await core.eventLog.drain()
                let completionSettled = await service.waitForJourneyCompletion(
                    journeyId: journey.id
                )
                expect(completionSettled).to(beTrue())

                let stored = await core.eventLog.getRecentEvents(limit: 100)
                    .filter { $0.name == "continue" }
                expect(stored).to(haveCount(1))
                expect(stored.first?.id).toNot(beNil())
                // The routed control event completes the fixture journey, so the
                // durable trace is the completed marker, not an active snapshot.
                // Live batch-receipt durability is pinned by the routing suite.
                let terminalState = await journey.snapshot()
                expect(terminalState.status).to(equal(.completed))
                let completedDir = storageURL
                    .appendingPathComponent("nuxie/journeys/completed")
                let markers = (try? FileManager.default.subpathsOfDirectory(
                    atPath: completedDir.path
                )) ?? []
                expect(markers.contains { $0.hasSuffix(".json") }).to(beTrue())
            }
        }
    }

    private static func makeCore(
        storageURL: URL,
        api: MockNuxieApi,
        presentation: MockExperiencePresentationService
    ) async throws -> NuxieCore {
        try FileManager.default.createDirectory(
            at: storageURL,
            withIntermediateDirectories: true
        )
        let configuration = NuxieConfiguration(apiKey: "pre-mount-key")
        configuration.environment = .development
        configuration.testingOverrides.customStoragePath = storageURL
        configuration.testingOverrides.flushAt = 10_000
        configuration.testingOverrides.flushInterval = 3_600
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [StubURLProtocol.self]
        configuration.testingOverrides.urlSession = URLSession(configuration: sessionConfiguration)

        var overrides = NuxieCoreOverrides()
        overrides.api = api
        overrides.dateProvider = MockDateProvider()
        overrides.sleepProvider = MockSleepProvider()
        overrides.experiencePresentation = presentation
        let core = NuxieCore(configuration: configuration, overrides: overrides)
        core.identity.setDistinctId("pre-mount-user")
        let journeys = core.journeys
        await core.eventLog.subscribeCommitted { [weak journeys] event in
            await journeys?.handleEvent(event)
        }
        try await core.eventLog.configure(configuration: core.configuration)
        await journeys.initialize()
        return core
    }
}
