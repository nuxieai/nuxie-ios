import Foundation
import Nimble
import Quick
import XCTest
@testable import Nuxie
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

            it("keeps wait, handoff, and exit headless") {
                let falseCondition = try JSONSerialization.jsonObject(
                    with: JSONEncoder().encode(IREnvelope(
                        ir_version: 1,
                        engine_min: "1.0.0",
                        compiled_at: 0,
                        expr: .bool(false)
                    ))
                )
                let terminalPrograms: [[[String: Any]]] = [
                    [["type": "delay", "durationMs": 60_000]],
                    [[
                        "type": "wait_until",
                        "condition": falseCondition,
                        "maxTimeMs": 60_000,
                    ]],
                    [[
                        "type": "time_window",
                        "startTime": "00:00",
                        "endTime": "23:59",
                        "timezone": "UTC",
                        "daysOfWeek": [0, 1, 2, 3, 4, 5, 6],
                    ]],
                    [[
                        "type": "handoff", "nodeId": "handoff-node",
                        "edgeId": "handoff-edge", "direction": "device_to_server",
                        "toRegionId": "server", "toNodeId": "server-entry"
                    ]],
                    [["type": "exit", "reason": "completed"]],
                ]
                for program in terminalPrograms {
                    let fixture = try ExperienceReleaseTestFixture.make(
                        entryActionsOverride: program
                    )
                    let storageURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent("nuxie-headless-\(UUID())")
                    storageURLs.append(storageURL)
                    let api = MockNuxieApi()
                    await api.setProfileResponse(ProfileResponse(
                        segments: [],
                        releases: .init(
                            delivery: fixture.delivery,
                            active: [fixture.entry], pinned: []
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
                    expect(presentation.presentExperienceCallCount).to(equal(0))
                }
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
        configuration.customStoragePath = storageURL
        configuration.flushAt = 10_000
        configuration.flushInterval = 3_600
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [StubURLProtocol.self]
        configuration.urlSession = URLSession(configuration: sessionConfiguration)

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
        try await core.eventLog.configure(configuration: configuration)
        await journeys.initialize()
        return core
    }
}
