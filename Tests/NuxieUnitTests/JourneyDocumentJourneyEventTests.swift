#if LEGACY_JOURNEY_TESTS
import XCTest
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

final class JourneyDocumentJourneyEventTests: XCTestCase {
    func testDecodesPublishedJourneyEventContractWithoutInteractions() throws {
        let json = """
        {
          "schemaVersion": 1,
          "screens": [
            { "id": "screen-1" },
            { "id": "screen-2" }
          ],
          "events": {
            "screen-1": [
              {
                "id": "event-select-product",
                "eventName": "select_product",
                "payloadSchema": { "productId": "string" }
              }
            ]
          },
          "handlers": {
            "screen-1": [
              {
                "id": "handler-select-product",
                "eventName": "select_product",
                "actions": [
                  { "type": "navigate", "screenId": "screen-2" }
                ]
              }
            ]
          },
          "scripts": {
            "screen-1": [
              {
                "id": "script-ref-1",
                "scriptId": "script-1",
                "assetId": "asset-1",
                "protocol": "listenerAction",
                "eventNames": ["select_product"]
              },
              {
                "id": "script-ref-2",
                "scriptId": "script-2",
                "assetId": "asset-2",
                "protocol": "listenerAction",
                "eventNames": ["show_details"]
              }
            ]
          }
        }
        """.data(using: .utf8)!

        let flow = try JSONDecoder().decode(JourneyDocument.self, from: json)

        XCTAssertNil(flow.handlers[JourneyDocument.journeyEventHostKey])
        XCTAssertEqual(flow.events["screen-1"]?.first?.payloadSchema?["productId"], .string)
        XCTAssertEqual(flow.handlers["screen-1"]?.first?.eventName, "select_product")
        XCTAssertEqual(flow.scripts.count, 1)

        let encoded = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(flow)
        ) as? [String: Any]
        XCTAssertNil(encoded?["interactions"])
        let encodedScripts = encoded?["scripts"] as? [String: [[String: Any]]]
        XCTAssertEqual(
            encodedScripts?["screen-1"]?.compactMap { $0["assetId"] as? String },
            ["asset-1", "asset-2"]
        )
    }

    func testDispatchesDeclaredScreenEventAndResolvesPayloadRefs() async throws {
        let flowId = "flow-screen-event"
        let screens = makeJourneyDocument(
            flowId: flowId,
            events: [
                "screen-1": [
                    EventDeclaration(
                        id: "event-product",
                        eventName: "select_product",
                        payloadSchema: ["productId": .string]
                    )
                ]
            ],
            handlers: [
                "screen-1": [
                    JourneyEventHandler(
                        id: "handler-product",
                        eventName: "select_product",
                        actions: [
                            .sendEvent(
                                SendEventAction(
                                    eventName: "product_selected",
                                    properties: [
                                        "productId": AnyCodable([
                                            "ref": [
                                                "kind": "payload",
                                                "path": "productId"
                                            ]
                                        ])
                                    ]
                                )
                            ),
                            .navigate(NavigateAction(screenId: "screen-2", transition: nil)),
                        ]
                    )
                ]
            ]
        )
        let experience = makeExperience(flowId: flowId)
        var initialState = JourneySnapshot(experience: experience, distinctId: "user-1", now: Date())
        initialState.executionState.currentScreenId = "screen-1"
        let journey = Journey(snapshot: initialState)
        let runner = makeRunner(
            journey: journey,
            initialState: initialState,
            experience: experience,
            flow: Experience.test(journey: screens, products: [])
        )

        let navigatedScreens = NavigatedScreenRecorder()
        await runner.setOnShowScreen { screenId, _ in
            navigatedScreens.append(screenId)
        }

        _ = await runner.dispatchScreenEvent(
            NuxieEvent(
                name: "select_product",
                distinctId: "user-1",
                properties: ["productId": "pro_monthly"]
            ),
            screenId: "screen-1",
            componentId: "button-1",
            instanceId: nil
        )

        XCTAssertEqual(navigatedScreens.values, ["screen-2"])
    }

    func testRejectsScreenEventWithInvalidPayload() async throws {
        let flowId = "flow-invalid-payload"
        let screens = makeJourneyDocument(
            flowId: flowId,
            events: [
                "screen-1": [
                    EventDeclaration(
                        id: "event-product",
                        eventName: "select_product",
                        payloadSchema: ["productId": .string]
                    )
                ]
            ],
            handlers: [
                "screen-1": [
                    JourneyEventHandler(
                        id: "handler-product",
                        eventName: "select_product",
                        actions: [.navigate(NavigateAction(screenId: "screen-2", transition: nil))]
                    )
                ]
            ]
        )
        let experience = makeExperience(flowId: flowId)
        var initialState = JourneySnapshot(experience: experience, distinctId: "user-1", now: Date())
        initialState.executionState.currentScreenId = "screen-1"
        let journey = Journey(snapshot: initialState)
        let runner = makeRunner(
            journey: journey,
            initialState: initialState,
            experience: experience,
            flow: Experience.test(journey: screens, products: [])
        )

        let navigatedScreens = NavigatedScreenRecorder()
        await runner.setOnShowScreen { screenId, _ in
            navigatedScreens.append(screenId)
        }

        _ = await runner.dispatchScreenEvent(
            NuxieEvent(
                name: "select_product",
                distinctId: "user-1",
                properties: ["productId": 42]
            ),
            screenId: "screen-1",
            componentId: nil,
            instanceId: nil
        )

        XCTAssertTrue(navigatedScreens.values.isEmpty)
    }

    func testResponseWriteFailureAbortsSiblingActions() async throws {
        let mocks = MockFactory.shared
        await mocks.resetAll()
        await mocks.nuxieApi.setResponseWriteError(
            NSError(domain: "response", code: 1, userInfo: [NSLocalizedDescriptionKey: "offline"])
        )
        let flowId = "flow-response-write-failure"
        let screens = makeJourneyDocument(
            flowId: flowId,
            events: ["screen-1": [EventDeclaration(id: "event-submit", eventName: "submit")]],
            handlers: [
                "screen-1": [
                    JourneyEventHandler(
                        id: "handler-submit",
                        eventName: "submit",
                        actions: [
                            .setResponseField(
                                SetResponseFieldAction(
                                    responseSchemaId: "response",
                                    key: "reason",
                                    value: AnyCodable("price")
                                )
                            ),
                            .navigate(NavigateAction(screenId: "screen-2", transition: nil)),
                        ]
                    ),
                ]
            ]
        )
        let experience = makeExperience(flowId: flowId)
        var initialState = JourneySnapshot(experience: experience, distinctId: "user-1", now: Date())
        initialState.executionState.currentScreenId = "screen-1"
        let journey = Journey(snapshot: initialState)
        let runner = makeRunner(
            journey: journey,
            initialState: initialState,
            experience: experience,
            flow: Experience.test(journey: screens, products: [])
        )
        let navigatedScreens = NavigatedScreenRecorder()
        await runner.setOnShowScreen { screenId, _ in navigatedScreens.append(screenId) }

        _ = await runner.dispatchScreenEvent(
            NuxieEvent(name: "submit", distinctId: "user-1", properties: [:]),
            screenId: "screen-1",
            componentId: nil,
            instanceId: nil
        )

        XCTAssertTrue(navigatedScreens.values.isEmpty)
    }

    func testResponseSubmitFailureAbortsSiblingActions() async throws {
        let mocks = MockFactory.shared
        await mocks.resetAll()
        await mocks.nuxieApi.setResponseSubmitError(
            NSError(domain: "response", code: 2, userInfo: [NSLocalizedDescriptionKey: "offline"])
        )
        let flowId = "flow-response-submit-failure"
        let screens = makeJourneyDocument(
            flowId: flowId,
            events: ["screen-1": [EventDeclaration(id: "event-submit", eventName: "submit")]],
            handlers: [
                "screen-1": [
                    JourneyEventHandler(
                        id: "handler-submit",
                        eventName: "submit",
                        actions: [
                            .submitResponse(SubmitResponseAction(responseSchemaId: "response")),
                            .navigate(NavigateAction(screenId: "screen-2", transition: nil)),
                        ]
                    ),
                ]
            ]
        )
        let experience = makeExperience(flowId: flowId)
        var initialState = JourneySnapshot(experience: experience, distinctId: "user-1", now: Date())
        initialState.executionState.currentScreenId = "screen-1"
        let journey = Journey(snapshot: initialState)
        let runner = makeRunner(
            journey: journey,
            initialState: initialState,
            experience: experience,
            flow: Experience.test(journey: screens, products: [])
        )
        let navigatedScreens = NavigatedScreenRecorder()
        await runner.setOnShowScreen { screenId, _ in navigatedScreens.append(screenId) }

        _ = await runner.dispatchScreenEvent(
            NuxieEvent(name: "submit", distinctId: "user-1", properties: [:]),
            screenId: "screen-1",
            componentId: nil,
            instanceId: nil
        )

        XCTAssertTrue(navigatedScreens.values.isEmpty)
    }

    func testDuplicateHandlerIdsDoNotCrashRunnerInitialization() async throws {
        let flowId = "flow-duplicate-handlers"
        let screens = makeJourneyDocument(
            flowId: flowId,
            events: [
                "screen-1": [
                    EventDeclaration(
                        id: "event-product",
                        eventName: "select_product"
                    )
                ]
            ],
            handlers: [
                "screen-1": [
                    JourneyEventHandler(
                        id: "duplicate-handler",
                        eventName: "select_product",
                        actions: [.navigate(NavigateAction(screenId: "screen-2", transition: nil))]
                    ),
                    JourneyEventHandler(
                        id: "duplicate-handler",
                        eventName: "select_product",
                        actions: [.sendEvent(SendEventAction(eventName: "duplicate_seen", properties: [:]))]
                    ),
                ]
            ]
        )
        let experience = makeExperience(flowId: flowId)
        var initialState = JourneySnapshot(experience: experience, distinctId: "user-1", now: Date())
        initialState.executionState.currentScreenId = "screen-1"
        let journey = Journey(snapshot: initialState)
        let runner = makeRunner(
            journey: journey,
            initialState: initialState,
            experience: experience,
            flow: Experience.test(journey: screens, products: [])
        )

        let navigatedScreens = NavigatedScreenRecorder()
        await runner.setOnShowScreen { screenId, _ in
            navigatedScreens.append(screenId)
        }

        _ = await runner.dispatchScreenEvent(
            NuxieEvent(
                name: "select_product",
                distinctId: "user-1",
                properties: [:]
            ),
            screenId: "screen-1",
            componentId: nil,
            instanceId: nil
        )

        XCTAssertEqual(navigatedScreens.values, ["screen-2"])
    }

    private func makeJourneyDocument(
        flowId: String,
        events: [String: [EventDeclaration]],
        handlers: [String: [JourneyEventHandler]]
    ) -> JourneyDocument {
        JourneyDocument(
            screens: [
                JourneyScreen(id: "screen-1"),
                JourneyScreen(id: "screen-2"),
            ],
            events: events,
            handlers: handlers,
            scripts: [:],
            viewModelValues: nil
        )
    }

    private func makeExperience(flowId: String) -> Experience {
        Experience(
            id: "experience-\(flowId)",
            versionId: flowId,
            name: "Experience",
            reentry: .oneTime,
            publishedAt: ISO8601DateFormatter().string(from: Date()),
            trigger: .event(EventTriggerConfig(eventName: "$app_opened", condition: nil)),
            goal: nil,
            exitPolicy: nil,
            conversionAnchor: nil,
            experienceType: nil
        )
    }

    /// Builds a runner over the shared mocks plus a real feature service and
    /// wired IR runtime, mirroring the old container defaults.
    private func makeRunner(
        journey: Journey,
        initialState: JourneySnapshot,
        experience: Experience,
        flow: Experience
    ) -> JourneyRunner {
        let mocks = MockFactory.shared
        let featureInfo = FeatureInfo()
        let irRuntime = IRRuntime(dateProvider: mocks.dateProvider)
        let features = FeatureService(
            api: mocks.nuxieApi,
            identity: mocks.identityService,
            profile: mocks.profileService,
            dateProvider: mocks.dateProvider,
            featureInfo: featureInfo,
            cacheTTL: 5 * 60
        )
        irRuntime.wire(
            identity: mocks.identityService,
            eventLog: mocks.eventLog,
            segments: mocks.segmentService,
            features: features
        )
        let hydratedExperience = Experience(
            id: experience.id,
            versionId: flow.versionId,
            buildId: flow.buildId,
            name: experience.name,
            reentry: experience.reentry,
            publishedAt: experience.publishedAt,
            trigger: experience.trigger,
            goal: experience.goal,
            exitPolicy: experience.exitPolicy,
            conversionAnchor: experience.conversionAnchor,
            timeLimitSeconds: experience.timeLimitSeconds,
            experienceType: experience.experienceType,
            journey: flow.journey,
            products: flow.products
        )
        return JourneyRunner(
            journey: journey,
            initialState: initialState,
            experience: hydratedExperience,
            eventLog: mocks.eventLog,
            identity: mocks.identityService,
            segments: mocks.segmentService,
            features: features,
            profile: mocks.profileService,
            apiClient: mocks.nuxieApi,
            dateProvider: mocks.dateProvider,
            irRuntime: irRuntime,
            persistEntryActionClaim: { _ in true }
        )
    }
}

/// Lock-guarded recorder for @Sendable show-screen callbacks.
// @unchecked Sendable: `_values` is only accessed under `lock`.
private final class NavigatedScreenRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [String] = []

    func append(_ screenId: String) {
        lock.withLock { _values.append(screenId) }
    }

    var values: [String] {
        lock.withLock { _values }
    }
}
#endif
