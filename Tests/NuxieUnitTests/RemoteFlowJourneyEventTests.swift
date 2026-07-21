import XCTest
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

final class RemoteFlowJourneyEventTests: XCTestCase {
    override func setUp() {
        super.setUp()
        #if SWIFT_PACKAGE
        MockFactory.shared.registerAll()
        #endif
    }

    func testDecodesPublishedJourneyEventContractWithoutInteractions() throws {
        let json = """
        {
          "id": "flow-1",
          "flowArtifact": {
            "url": "https://example.com/flow",
            "buildId": "build-1",
            "manifest": {
              "totalFiles": 1,
              "totalSize": 10,
              "contentHash": "hash-1",
              "files": [
                {
                  "path": "flow.riv",
                  "size": 10,
                  "contentType": "application/octet-stream"
                }
              ]
            }
          },
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
            "screen-1": {
              "id": "script-ref-1",
              "scriptId": "script-1",
              "assetId": "asset-1",
              "protocol": "listenerAction",
              "eventNames": ["select_product"]
            }
          }
        }
        """.data(using: .utf8)!

        let flow = try JSONDecoder().decode(RemoteFlow.self, from: json)

        XCTAssertNil(flow.handlers[RemoteFlow.journeyEventHostKey])
        XCTAssertEqual(flow.events["screen-1"]?.first?.payloadSchema?["productId"], .string)
        XCTAssertEqual(flow.handlers["screen-1"]?.first?.eventName, "select_product")
        XCTAssertEqual(flow.scripts["screen-1"]?.assetId, "asset-1")

        let encoded = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(flow)
        ) as? [String: Any]
        XCTAssertNil(encoded?["interactions"])
    }

    func testDispatchesDeclaredScreenEventAndResolvesPayloadRefs() async throws {
        let flowId = "flow-screen-event"
        let screens = makeRemoteFlow(
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
        let campaign = makeCampaign(flowId: flowId)
        let journey = Journey(campaign: campaign, distinctId: "user-1")
        journey.flowState.currentScreenId = "screen-1"
        let runner = JourneyRunner(
            journey: journey,
            campaign: campaign,
            flow: Experience(screens: screens, products: [])
        )

        var navigatedScreens: [String] = []
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

        XCTAssertEqual(navigatedScreens, ["screen-2"])
    }

    func testRejectsScreenEventWithInvalidPayload() async throws {
        let flowId = "flow-invalid-payload"
        let screens = makeRemoteFlow(
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
        let campaign = makeCampaign(flowId: flowId)
        let journey = Journey(campaign: campaign, distinctId: "user-1")
        journey.flowState.currentScreenId = "screen-1"
        let runner = JourneyRunner(
            journey: journey,
            campaign: campaign,
            flow: Experience(screens: screens, products: [])
        )

        var navigatedScreens: [String] = []
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

        XCTAssertTrue(navigatedScreens.isEmpty)
    }

    func testDuplicateHandlerIdsDoNotCrashRunnerInitialization() async throws {
        let flowId = "flow-duplicate-handlers"
        let screens = makeRemoteFlow(
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
        let campaign = makeCampaign(flowId: flowId)
        let journey = Journey(campaign: campaign, distinctId: "user-1")
        journey.flowState.currentScreenId = "screen-1"
        let runner = JourneyRunner(
            journey: journey,
            campaign: campaign,
            flow: Experience(screens: screens, products: [])
        )

        var navigatedScreens: [String] = []
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

        XCTAssertEqual(navigatedScreens, ["screen-2"])
    }

    private func makeRemoteFlow(
        flowId: String,
        events: [String: [EventDeclaration]],
        handlers: [String: [JourneyEventHandler]]
    ) -> RemoteFlow {
        RemoteFlow(
            id: flowId,
            flowArtifact: FlowArtifact(
                url: "https://example.com/flow/\(flowId)",
                manifest: BuildManifest(
                    totalFiles: 1,
                    totalSize: 10,
                    contentHash: "hash-\(flowId)",
                    files: [
                        BuildFile(
                            path: "flow.riv",
                            size: 10,
                            contentType: "application/octet-stream"
                        )
                    ]
                )
            ),
            screens: [
                RemoteFlowScreen(id: "screen-1"),
                RemoteFlowScreen(id: "screen-2"),
            ],
            events: events,
            handlers: handlers,
            scripts: [:],
            viewModelValues: nil
        )
    }

    private func makeCampaign(flowId: String) -> Campaign {
        Campaign(
            id: "campaign-\(flowId)",
            name: "Campaign",
            flowId: flowId,
            flowNumber: 1,
            flowName: nil,
            reentry: .oneTime,
            publishedAt: ISO8601DateFormatter().string(from: Date()),
            trigger: .event(EventTriggerConfig(eventName: "$app_opened", condition: nil)),
            goal: nil,
            exitPolicy: nil,
            conversionAnchor: nil,
            campaignType: nil
        )
    }
}
