import Foundation
import Quick
import Nimble
import FactoryKit
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

private final class OrderingRecorder {
    private let lock = NSLock()
    private var _events: [String] = []

    func append(_ event: String) {
        lock.withLock {
            _events.append(event)
        }
    }

    func clear() {
        lock.withLock {
            _events.removeAll()
        }
    }

    var events: [String] {
        lock.withLock { _events }
    }
}

private final class OrderingJourneyStore: MockJourneyStore {
    private let recorder: OrderingRecorder

    init(recorder: OrderingRecorder) {
        self.recorder = recorder
        super.init()
    }

    override func recordCompletion(_ record: JourneyCompletionRecord) throws {
        try super.recordCompletion(record)
        recorder.append("complete:\(record.campaignId)")
    }
}

private class OrderingFlowPresentationService: MockExperiencePresentationService {
    private let recorder: OrderingRecorder

    init(recorder: OrderingRecorder) {
        self.recorder = recorder
        super.init()
    }

    @discardableResult
    @MainActor
    override func presentExperience(
        _ flowId: String,
        from journey: Journey?,
        runtimeDelegate: FlowRuntimeDelegate?
    ) async throws -> ExperienceViewController {
        recorder.append("present:\(flowId)")
        return try await super.presentExperience(
            flowId,
            from: journey,
            runtimeDelegate: runtimeDelegate
        )
    }

    @discardableResult
    @MainActor
    override func presentExperience(
        _ flowId: String,
        from journey: Journey?,
        runtimeDelegate: FlowRuntimeDelegate?,
        colorSchemeMode: ExperienceColorSchemeMode
    ) async throws -> ExperienceViewController {
        return try await super.presentExperience(
            flowId,
            from: journey,
            runtimeDelegate: runtimeDelegate,
            colorSchemeMode: colorSchemeMode
        )
    }
}

private final class DismissingOrderingFlowPresentationService: OrderingFlowPresentationService {
    private let dismissalRecorder: OrderingRecorder

    override init(recorder: OrderingRecorder) {
        self.dismissalRecorder = recorder
        super.init(recorder: recorder)
    }

    @discardableResult
    @MainActor
    override func presentExperience(
        _ flowId: String,
        from journey: Journey?,
        runtimeDelegate: FlowRuntimeDelegate?
    ) async throws -> ExperienceViewController {
        if isPresentingFlow {
            await dismissCurrentFlow()
            dismissalRecorder.append("dismiss-before-present")
        }
        return try await super.presentExperience(flowId, from: journey, runtimeDelegate: runtimeDelegate)
    }
}

private final class OrderingMockFlowViewController: MockFlowViewController {
    private let recorder: OrderingRecorder

    init(mockFlowId: String, recorder: OrderingRecorder) {
        self.recorder = recorder
        super.init(mockFlowId: mockFlowId)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func navigate(to screenId: String, transition: Any? = nil) {
        recorder.append("navigate:\(screenId)")
    }
}

private final class UnsupportedTrackingAuthorizationHandler: TrackingAuthorizationHandling {
    func authorizationStatus() -> TrackingAuthorizationStatus {
        .unsupported
    }

    func requestAuthorization() async -> TrackingAuthorizationStatus {
        .unsupported
    }
}

private final class DelayedTrackingAuthorizationHandler: TrackingAuthorizationHandling {
    let delayNanoseconds: UInt64
    let result: TrackingAuthorizationStatus

    init(delayNanoseconds: UInt64, result: TrackingAuthorizationStatus) {
        self.delayNanoseconds = delayNanoseconds
        self.result = result
    }

    func authorizationStatus() -> TrackingAuthorizationStatus {
        .notDetermined
    }

    func requestAuthorization() async -> TrackingAuthorizationStatus {
        try? await Task.sleep(nanoseconds: delayNanoseconds)
        return result
    }
}

final class JourneyServiceExitTimingTests: AsyncSpec {
    override class func spec() {
        var mocks: MockFactory!
        var journeyStore: MockJourneyStore!
        var service: JourneyService!
        var controller: MockFlowViewController!

        let distinctId = "user_1"
        let flowId = "flow-exit-timing"
        let campaignId = "camp-exit-timing"

        func makeGatePlanResponse(
            decision: String,
            flowId: String? = nil,
            featureId: String? = nil,
            policy: String? = nil,
            requiredBalance: Int? = nil
        ) -> EventResponse {
            var gatePayload: [String: Any] = ["decision": decision]
            if let flowId {
                gatePayload["flowId"] = flowId
            }
            if let featureId {
                gatePayload["featureId"] = featureId
            }
            if let policy {
                gatePayload["policy"] = policy
            }
            if let requiredBalance {
                gatePayload["requiredBalance"] = requiredBalance
            }

            return EventResponse(
                status: "ok",
                payload: ["gate": AnyCodable(gatePayload)],
                customer: nil,
                eventId: nil,
                message: nil,
                featuresMatched: nil,
                usage: nil,
                journey: nil,
                execution: nil
            )
        }

        func makeCampaign(
            id: String = campaignId,
            flowId: String = flowId,
            trigger: CampaignTrigger = .event(EventTriggerConfig(eventName: "paywall_trigger", condition: nil)),
            goal: GoalConfig?,
            exitPolicy: ExitPolicy?
        ) -> Campaign {
            Campaign(
                id: id,
                name: "Exit Timing Campaign",
                flowId: flowId,
                flowNumber: 1,
                flowName: nil,
                reentry: .everyTime,
                publishedAt: Date().ISO8601Format(),
                trigger: trigger,
                goal: goal,
                exitPolicy: exitPolicy,
                conversionAnchor: nil,
                campaignType: nil
            )
        }

        func makeFlow(flowId: String = flowId, handlers: RemoteFlowHandlerMap = [:]) -> Experience {
            var events: RemoteFlowEventMap = [:]
            for (hostId, hostHandlers) in handlers where hostId != RemoteFlow.journeyEventHostKey {
                for handler in hostHandlers {
                    events[hostId, default: []].append(
                        EventDeclaration(
                            id: "\(handler.id):event",
                            eventName: handler.eventName
                        )
                    )
                }
            }
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
                events: events,
                handlers: handlers,
                viewModelValues: nil
            )
            return Experience(screens: screens, products: [])
        }

        func pressHandlers(_ actions: [JourneyAction]) -> RemoteFlowHandlerMap {
            [
                "screen-1": [
                    JourneyEventHandler(
                        id: "press-host-action",
                        eventName: "__nuxie_test_press",
                        actions: actions
                    )
                ]
            ]
        }

        func emitScreenPress(_ controller: ExperienceViewController) {
            controller.runtimeDelegate?.flowViewController(
                controller,
                didEmitEvent: ExperienceRendererEvent(
                    name: "__nuxie_test_press",
                    properties: [:],
                    screenId: "screen-1",
                    componentId: nil,
                    instanceId: nil
                )
            )
        }

        func emitRendererEvent(_ controller: ExperienceViewController, name: String) {
            controller.runtimeDelegate?.flowViewController(
                controller,
                didEmitEvent: ExperienceRendererEvent(
                    name: name,
                    properties: [:],
                    screenId: "screen-1",
                    componentId: nil,
                    instanceId: nil
                )
            )
        }

        func emitTaggedRendererEvent(_ controller: ExperienceViewController, name: String) {
            controller.runtimeDelegate?.flowViewController(
                controller,
                didEmitEvent: ExperienceRendererEvent(
                    name: name,
                    properties: ["eventName": name],
                    screenId: "screen-1",
                    componentId: nil,
                    instanceId: nil
                )
            )
        }

        func primeProfile(campaign: Campaign, flow: Experience) async {
            await primeProfile(campaigns: [campaign], flows: [flow])
        }

        func primeProfile(campaigns: [Campaign], flows: [Experience]) async {
            mocks.identityService.setDistinctId(distinctId)
            for flow in flows {
                mocks.flowService.mockExperiences[flow.screens.id] = flow
            }
            mocks.profileService.setProfileResponse(
                ResponseBuilders.buildProfileResponse(
                    campaigns: campaigns,
                    flows: flows.map(\.screens)
                )
            )
            _ = try? await mocks.profileService.refetchProfile(distinctId: distinctId)
        }

        func startJourney() async -> Journey {
            let startEvent = NuxieEvent(
                id: "evt_origin",
                name: "paywall_trigger",
                distinctId: distinctId
            )
            let results = await service.handleEventForTrigger(startEvent)
            return results.compactMap { result -> Journey? in
                if case .started(let journey) = result {
                    return journey
                }
                return nil
            }.first!
        }

        beforeEach { @MainActor in
            mocks = MockFactory.shared
            mocks.registerAll()
            mocks.dateProvider.setCurrentDate(Date())

            journeyStore = MockJourneyStore()
            service = JourneyService(journeyStore: journeyStore)

            controller = MockFlowViewController(mockFlowId: flowId)
            mocks.flowPresentationService.defaultMockViewController = controller
        }

        describe("journey start persistence") {
            it("emits journey_start through the durable event pipeline on enrollment") {
                let campaign = makeCampaign(goal: nil, exitPolicy: nil)
                let flow = makeFlow()
                await primeProfile(campaign: campaign, flow: flow)
                await service.initialize()

                let journey = await startJourney()

                let startEvent = mocks.eventLog.trackedEvents.first {
                    $0.name == "$journey_start"
                }
                expect(startEvent).toNot(beNil())
                let props = startEvent?.properties ?? [:]
                expect(props["session_id"] as? String).to(equal(journey.id))
                expect(props["campaign_id"] as? String).to(equal(campaign.id))
                expect(props["flow_id"] as? String).to(equal(campaign.flowId))
            }

            it("emits journey_start when a routed event starts a journey") {
                let campaign = makeCampaign(goal: nil, exitPolicy: nil)
                let flow = makeFlow()
                await primeProfile(campaign: campaign, flow: flow)
                await service.initialize()

                await service.handleEvent(
                    NuxieEvent(
                        id: "evt_origin",
                        name: "paywall_trigger",
                        distinctId: distinctId
                    )
                )

                // Local-first: no synchronous flush-before-start — the durable
                // queue owns delivery ordering and dedup.
                let startEvent = mocks.eventLog.trackedEvents.first {
                    $0.name == "$journey_start"
                }
                expect(startEvent).toNot(beNil())
            }

            it("starts the journey locally even when the network is down") {
                // Local-first enrollment: journeys run from cached config; the
                // server learns via the durable queue. The old server-RTT gate
                // meant offline users got no journeys at all.
                let campaign = makeCampaign(goal: nil, exitPolicy: nil)
                let flow = makeFlow()
                await primeProfile(campaign: campaign, flow: flow)
                await service.initialize()
                mocks.eventLog.trackWithResponseError = URLError(.notConnectedToInternet)

                let results = await service.handleEventForTrigger(
                    NuxieEvent(id: "evt_origin", name: "paywall_trigger", distinctId: distinctId)
                )

                let started = results.contains { result in
                    if case .started = result { return true }
                    return false
                }
                expect(started).to(beTrue())
                await expect {
                    await service.getActiveJourneys(for: distinctId).isEmpty
                }.toEventually(beFalse(), timeout: .seconds(2))
            }

            it("tracks renderer events once while routing them outside the source journey") {
                let ordering = OrderingRecorder()
                let eventController = OrderingMockFlowViewController(mockFlowId: flowId, recorder: ordering)
                controller = eventController
                mocks.flowPresentationService.defaultMockViewController = eventController

                let campaign = makeCampaign(goal: nil, exitPolicy: nil)
                let routedCampaign = makeCampaign(
                    id: "camp-renderer-event",
                    flowId: "flow-renderer-event",
                    trigger: .event(EventTriggerConfig(eventName: "renderer_event", condition: nil)),
                    goal: nil,
                    exitPolicy: nil
                )
                let flow = makeFlow(handlers: [
                    "screen-1": [
                        JourneyEventHandler(
                            id: "renderer-event-handler",
                            eventName: "renderer_event",
                            actions: [.navigate(NavigateAction(screenId: "screen-2", transition: nil))]
                        )
                    ]
                ])
                let routedFlow = makeFlow(flowId: "flow-renderer-event")
                await primeProfile(campaigns: [campaign, routedCampaign], flows: [flow, routedFlow])
                await service.initialize()
                let journey = await startJourney()
                journey.flowState.pendingAction = FlowPendingAction(
                    handlerId: "wait-renderer-event",
                    screenId: "screen-1",
                    componentId: nil,
                    actionIndex: 0,
                    kind: .waitUntil,
                    resumeAt: nil,
                    condition: nil,
                    maxTimeMs: nil,
                    startedAt: Date(),
                    resumeActions: [.navigate(NavigateAction(screenId: "screen-3", transition: nil))]
                )

                controller.runtimeDelegate?.flowViewController(controller, didChangeScreen: "screen-1")
                emitRendererEvent(controller, name: "renderer_event")

                await expect(ordering.events).toEventually(contain("navigate:screen-2"))
                await expect {
                    ordering.events.filter { $0 == "navigate:screen-2" }
                }.toEventually(equal(["navigate:screen-2"]), timeout: .seconds(2))
                await expect {
                    ordering.events
                }.toEventually(contain("navigate:screen-3"), timeout: .seconds(2))
                await expect {
                    await service.getActiveJourneys(for: distinctId).map(\.campaignId)
                }.toEventually(contain("camp-renderer-event"))
                await expect(mocks.eventLog.trackForTriggerCalls.map(\.event)).toEventually(contain("renderer_event"))
                let trackedRendererEvent = mocks.eventLog.routedEvents.first {
                    $0.name == "renderer_event"
                }
                let routedJourney = await service.getActiveJourneys(for: distinctId).first {
                    $0.campaignId == "camp-renderer-event"
                }
                expect(routedJourney?.getContext("_origin_event_id") as? String)
                    .to(equal(trackedRendererEvent?.id))
                expect(mocks.eventLog.trackedEvents.map(\.name)).toNot(contain("renderer_event"))
            }

            it("tracks tagged renderer events through the event routing path") {
                let ordering = OrderingRecorder()
                let eventController = OrderingMockFlowViewController(mockFlowId: flowId, recorder: ordering)
                controller = eventController
                mocks.flowPresentationService.defaultMockViewController = eventController

                let campaign = makeCampaign(goal: nil, exitPolicy: nil)
                let routedCampaign = makeCampaign(
                    id: "camp-tagged-renderer-event",
                    flowId: "flow-tagged-renderer-event",
                    trigger: .event(EventTriggerConfig(eventName: "tagged_renderer_event", condition: nil)),
                    goal: nil,
                    exitPolicy: nil
                )
                let flow = makeFlow(handlers: [
                    "screen-1": [
                        JourneyEventHandler(
                            id: "tagged-renderer-event-handler",
                            eventName: "tagged_renderer_event",
                            actions: [.navigate(NavigateAction(screenId: "screen-2", transition: nil))]
                        )
                    ]
                ])
                let routedFlow = makeFlow(flowId: "flow-tagged-renderer-event")
                await primeProfile(campaigns: [campaign, routedCampaign], flows: [flow, routedFlow])
                await service.initialize()
                _ = await startJourney()

                controller.runtimeDelegate?.flowViewController(controller, didChangeScreen: "screen-1")
                emitTaggedRendererEvent(controller, name: "tagged_renderer_event")

                await expect(ordering.events).toEventually(contain("navigate:screen-2"))
                await expect {
                    await service.getActiveJourneys(for: distinctId).map(\.campaignId)
                }.toEventually(contain("camp-tagged-renderer-event"))
                await expect(mocks.eventLog.trackForTriggerCalls.map(\.event))
                    .toEventually(contain("tagged_renderer_event"))
                let trackedRendererEvent = mocks.eventLog.routedEvents.first {
                    $0.name == "tagged_renderer_event"
                }
                let routedJourney = await service.getActiveJourneys(for: distinctId).first {
                    $0.campaignId == "camp-tagged-renderer-event"
                }
                expect(routedJourney?.getContext("_origin_event_id") as? String)
                    .to(equal(trackedRendererEvent?.id))
            }

            it("honors gate plans returned for renderer events") {
                let orderingPresentationService = OrderingFlowPresentationService(recorder: OrderingRecorder())
                orderingPresentationService.defaultMockViewController = controller
                Container.shared.flowPresentationService.register { @MainActor in orderingPresentationService }
                service = JourneyService(journeyStore: journeyStore)

                let campaign = makeCampaign(goal: nil, exitPolicy: nil)
                let flow = makeFlow()
                await primeProfile(campaign: campaign, flow: flow)
                await service.initialize()
                _ = await startJourney()
                mocks.eventLog.trackWithResponseResult = makeGatePlanResponse(
                    decision: "show_flow",
                    flowId: "gate-flow"
                )

                controller.runtimeDelegate?.flowViewController(controller, didChangeScreen: "screen-1")
                emitRendererEvent(controller, name: "renderer_gate_event")

                await expect {
                    await MainActor.run {
                        orderingPresentationService.wasFlowPresented("gate-flow")
                    }
                }.toEventually(beTrue(), timeout: .seconds(2))
                await expect(mocks.eventLog.trackForTriggerCalls.map(\.event))
                    .toEventually(contain("renderer_gate_event"))
            }

            it("evaluates source renderer event goals from snapshots when profile cache is missing") {
                let campaign = makeCampaign(
                    goal: GoalConfig(kind: .event, eventName: "renderer_goal_event"),
                    exitPolicy: ExitPolicy(mode: .onGoal)
                )
                let flow = makeFlow()
                await primeProfile(campaign: campaign, flow: flow)
                await service.initialize()
                let journey = await startJourney()
                await MainActor.run {
                    mocks.flowPresentationService.isPresentingFlow = false
                }
                await mocks.profileService.clearCache(distinctId: distinctId)

                controller.runtimeDelegate?.flowViewController(controller, didChangeScreen: "screen-1")
                emitRendererEvent(controller, name: "renderer_goal_event")

                await expect {
                    journeyStore.getCompletions(for: distinctId).last { $0.journeyId == journey.id }?.exitReason
                }.toEventually(equal(.goalMet), timeout: .seconds(2))
            }
        }

        describe("exit deferral during active flow presentation") {
            it("keeps goal-met journeys live until dismiss, then exits as goal_met") {
                let campaign = makeCampaign(
                    goal: GoalConfig(kind: .segmentEnter, segmentId: "goal-segment"),
                    exitPolicy: ExitPolicy(mode: .onGoal)
                )
                let flow = makeFlow()
                await primeProfile(campaign: campaign, flow: flow)
                await service.initialize()

                let journey = await startJourney()
                await mocks.segmentService.setMembership("goal-segment", isMember: true)
                _ = await service.handleEventForTrigger(
                    NuxieEvent(id: "evt_noop", name: "noop_event", distinctId: distinctId)
                )

                let activeJourneys = await service.getActiveJourneys(for: distinctId)
                expect(activeJourneys.map(\.id)).to(equal([journey.id]))
                expect(activeJourneys.first?.convertedAt).toNot(beNil())
                expect(journeyStore.getCompletions(for: distinctId)).to(beEmpty())

                let dismissController = controller!
                await MainActor.run {
                    dismissController.runtimeDelegate?.flowViewControllerDidRequestDismiss(
                        dismissController,
                        reason: .userDismissed
                    )
                }

                await expect {
                    journeyStore.getCompletions(for: distinctId).last?.exitReason
                }.toEventually(equal(.goalMet), timeout: .seconds(2))
                await expect {
                    await service.getActiveJourneys(for: distinctId).count
                }.toEventually(equal(0), timeout: .seconds(2))
            }

            it("reevaluates goals triggered by dismiss handlers before falling back to dismissed") {
                let dismissGoal = JourneyEventHandler(
                    id: "dismiss-goal",
                    eventName: SystemEventNames.screenDismissed,
                    actions: [
                        .updateCustomer(
                            UpdateCustomerAction(attributes: ["dismissed": AnyCodable(true)])
                        )
                    ]
                )
                let campaign = makeCampaign(
                    goal: GoalConfig(
                        kind: .attribute,
                        attributeExpr: IREnvelope(
                            ir_version: 1,
                            engine_min: nil,
                            compiled_at: nil,
                            expr: .user(op: "eq", key: "dismissed", value: .bool(true))
                        )
                    ),
                    exitPolicy: ExitPolicy(mode: .onGoal)
                )
                let flow = makeFlow(handlers: [RemoteFlow.journeyEventHostKey: [dismissGoal]])
                await primeProfile(campaign: campaign, flow: flow)
                await service.initialize()

                _ = await startJourney()
                let activeJourneys = await service.getActiveJourneys(for: distinctId)
                expect(activeJourneys.first?.convertedAt).to(beNil())

                let dismissController = controller!
                await MainActor.run {
                    dismissController.runtimeDelegate?.flowViewControllerDidRequestDismiss(
                        dismissController,
                        reason: .userDismissed
                    )
                }

                await expect {
                    journeyStore.getCompletions(for: distinctId).last?.exitReason
                }.toEventually(equal(.goalMet), timeout: .seconds(2))
                expect(journeyStore.getCompletions(for: distinctId).last?.exitReason).toNot(equal(.dismissed))
            }

            it("starts matching campaigns from scoped notification outcomes") {
                let notificationCampaign = makeCampaign(
                    id: "camp-notifications",
                    flowId: "flow-notifications",
                    trigger: .event(EventTriggerConfig(eventName: SystemEventNames.notificationsEnabled, condition: nil)),
                    goal: nil,
                    exitPolicy: nil
                )
                let primaryCampaign = makeCampaign(goal: nil, exitPolicy: nil)
                let primaryFlow = makeFlow()
                let notificationFlow = makeFlow(flowId: "flow-notifications")

                await primeProfile(
                    campaigns: [primaryCampaign, notificationCampaign],
                    flows: [primaryFlow, notificationFlow]
                )
                await service.initialize()

                let journey = await startJourney()

                await MainActor.run {
                    (controller.runtimeDelegate as? NotificationPermissionEventReceiver)?.flowViewController(
                        controller,
                        didResolveNotificationPermissionEvent: SystemEventNames.notificationsEnabled,
                        properties: ["journey_id": journey.id],
                        journeyId: journey.id
                    )
                }

                await expect {
                    await service.getActiveJourneys(for: distinctId).map(\.campaignId).sorted()
                }.toEventually(equal([campaignId, "camp-notifications"].sorted()), timeout: .seconds(2))
            }

            it("completes presented journeys when scoped goal actions fire") {
                let campaign = makeCampaign(
                    goal: GoalConfig(kind: .event, eventName: JourneyEvents.journeyGoalHit),
                    exitPolicy: ExitPolicy(mode: .onGoal)
                )
                let flow = makeFlow()
                await primeProfile(campaign: campaign, flow: flow)
                await service.initialize()

                let journey = await startJourney()

                await service.handleScopedGoalEvent(
                    journeyId: journey.id,
                    goalId: "signup_complete",
                    goalLabel: "Signed Up",
                    screenId: "screen-1"
                )

                await expect {
                    await service.getActiveJourneys(for: distinctId).isEmpty
                }.toEventually(beTrue(), timeout: .seconds(2))
                await expect {
                    await MainActor.run { mocks.flowPresentationService.dismissCurrentFlowCallCount }
                }.toEventually(equal(1), timeout: .seconds(2))
                expect(mocks.eventLog.trackForTriggerCalls.last?.properties?["journey_id"] as? String)
                    .to(equal(journey.id))
                expect(mocks.eventLog.trackForTriggerCalls.last?.properties?["campaign_id"] as? String)
                    .to(equal(campaign.id))
                expect(mocks.eventLog.trackForTriggerCalls.last?.properties?["goal_id"] as? String)
                    .to(equal("signup_complete"))
                expect(mocks.eventLog.trackForTriggerCalls.last?.properties?["goal_label"] as? String)
                    .to(equal("Signed Up"))
                expect(mocks.eventLog.trackForTriggerCalls.last?.properties?["journeyId"]).to(beNil())
                expect(mocks.eventLog.trackForTriggerCalls.last?.properties?["goalId"]).to(beNil())

                await expect {
                    journeyStore.getCompletions(for: distinctId).last?.exitReason
                }.toEventually(equal(.goalMet), timeout: .seconds(2))
            }

            it("persists scoped goal hits for multi-step attribute goals") {
                let campaign = makeCampaign(
                    goal: GoalConfig(
                        kind: .attribute,
                        attributeExpr: IREnvelope(
                            ir_version: 1,
                            engine_min: nil,
                            compiled_at: nil,
                            expr: .and([
                                .eventsExists(
                                    name: JourneyEvents.journeyGoalHit,
                                    since: nil,
                                    until: nil,
                                    within: nil,
                                    where_: .pred(
                                        op: "eq",
                                        key: "goal_id",
                                        value: .string("signup_started")
                                    )
                                ),
                                .eventsExists(
                                    name: JourneyEvents.journeyGoalHit,
                                    since: nil,
                                    until: nil,
                                    within: nil,
                                    where_: .pred(
                                        op: "eq",
                                        key: "goal_id",
                                        value: .string("signup_completed")
                                    )
                                ),
                            ])
                        )
                    ),
                    exitPolicy: nil
                )
                let flow = makeFlow()
                await primeProfile(campaign: campaign, flow: flow)
                await service.initialize()

                let journey = await startJourney()
                expect(journey.convertedAt).to(beNil())

                await service.handleScopedGoalEvent(
                    journeyId: journey.id,
                    goalId: "signup_started",
                    goalLabel: nil,
                    screenId: "screen-1"
                )

                let journeyAfterFirstGoal = await service.getActiveJourneys(for: distinctId).first {
                    $0.id == journey.id
                }
                expect(journeyAfterFirstGoal?.convertedAt).to(beNil())

                await service.handleScopedGoalEvent(
                    journeyId: journey.id,
                    goalId: "signup_completed",
                    goalLabel: nil,
                    screenId: "screen-1"
                )

                await expect {
                    (await service.getActiveJourneys(for: distinctId).first {
                        $0.id == journey.id
                    })?.convertedAt
                }.toEventuallyNot(beNil(), timeout: .seconds(2))
            }

            it("routes goal-driven closures through dismissal hooks and flow dismissal tracking") {
                let dismissFollowUp = JourneyEventHandler(
                    id: "dismiss-follow-up",
                    eventName: SystemEventNames.screenDismissed,
                    actions: [
                        .sendEvent(
                            SendEventAction(
                                eventName: "dismiss_hook_ran",
                                properties: nil
                            )
                        )
                    ]
                )
                let campaign = makeCampaign(
                    goal: GoalConfig(kind: .event, eventName: JourneyEvents.journeyGoalHit),
                    exitPolicy: ExitPolicy(mode: .onGoal)
                )
                let flow = makeFlow(handlers: [RemoteFlow.journeyEventHostKey: [dismissFollowUp]])
                await primeProfile(campaign: campaign, flow: flow)
                await service.initialize()

                let journey = await startJourney()
                let dismissNotifications = OrderingRecorder()
                let observer = NotificationCenter.default.addObserver(
                    forName: .nuxieDismiss,
                    object: nil,
                    queue: nil
                ) { notification in
                    if let reason = notification.userInfo?["reason"] as? String {
                        dismissNotifications.append(reason)
                    }
                }
                defer {
                    NotificationCenter.default.removeObserver(observer)
                }

                await service.handleScopedGoalEvent(
                    journeyId: journey.id,
                    goalId: "signup_complete",
                    goalLabel: "Signed Up",
                    screenId: "screen-1"
                )

                await expect {
                    journeyStore.getCompletions(for: distinctId).last?.exitReason
                }.toEventually(equal(.goalMet), timeout: .seconds(2))
                await expect {
                    mocks.eventLog.trackedEvents.map(\.name)
                }.toEventually(contain(JourneyEvents.flowDismissed), timeout: .seconds(2))
                await expect {
                    mocks.eventLog.trackedEvents.map(\.name)
                }.toEventually(contain("dismiss_hook_ran"), timeout: .seconds(2))
                await expect {
                    dismissNotifications.events.last
                }.toEventually(equal("goal_met"), timeout: .seconds(2))
            }

            it("completes presented journeys before scoped goal tracking returns") {
                let campaign = makeCampaign(
                    goal: GoalConfig(kind: .event, eventName: JourneyEvents.journeyGoalHit),
                    exitPolicy: ExitPolicy(mode: .onGoal)
                )
                let flow = makeFlow()
                await primeProfile(campaign: campaign, flow: flow)
                await service.initialize()

                let journey = await startJourney()
                mocks.eventLog.trackForTriggerDelayNanoseconds = 750_000_000

                let scopedGoalTask = Task {
                    await service.handleScopedGoalEvent(
                        journeyId: journey.id,
                        goalId: "signup_complete",
                        goalLabel: "Signed Up",
                        screenId: "screen-1"
                    )
                }

                await expect {
                    await service.getActiveJourneys(for: distinctId).isEmpty
                }.toEventually(beTrue(), timeout: .milliseconds(250))
                await expect {
                    await MainActor.run { mocks.flowPresentationService.dismissCurrentFlowCallCount }
                }.toEventually(equal(1), timeout: .milliseconds(250))
                await expect {
                    journeyStore.getCompletions(for: distinctId).last?.exitReason
                }.toEventually(equal(.goalMet), timeout: .milliseconds(250))

                await scopedGoalTask.value
            }

            it("uses journey snapshots when scoped goal actions outlive the cached profile") {
                let campaign = makeCampaign(
                    goal: GoalConfig(kind: .event, eventName: JourneyEvents.journeyGoalHit),
                    exitPolicy: ExitPolicy(mode: .onGoal)
                )
                let flow = makeFlow()
                await primeProfile(campaign: campaign, flow: flow)
                await service.initialize()

                let journey = await startJourney()
                await mocks.profileService.clearCache(distinctId: distinctId)

                await service.handleScopedGoalEvent(
                    journeyId: journey.id,
                    goalId: "signup_complete",
                    goalLabel: "Signed Up",
                    screenId: "screen-1"
                )

                await expect {
                    await service.getActiveJourneys(for: distinctId).isEmpty
                }.toEventually(beTrue(), timeout: .seconds(2))
                await expect {
                    journeyStore.getCompletions(for: distinctId).last?.journeyId
                }.toEventually(equal(journey.id), timeout: .seconds(2))
                await expect {
                    journeyStore.getCompletions(for: distinctId).last?.exitReason
                }.toEventually(equal(.goalMet), timeout: .seconds(2))
            }

            it("preserves segment triggers in snapshot-backed sibling goal fallbacks") {
                let primaryCampaign = makeCampaign(
                    id: "camp-primary-fallback",
                    flowId: "flow-primary-fallback",
                    goal: nil,
                    exitPolicy: nil
                )
                let siblingCampaign = makeCampaign(
                    id: "camp-sibling-fallback",
                    flowId: "flow-sibling-fallback",
                    goal: nil,
                    exitPolicy: ExitPolicy(mode: .onGoalOrStop)
                )

                await primeProfile(
                    campaigns: [primaryCampaign, siblingCampaign],
                    flows: [
                        makeFlow(flowId: "flow-primary-fallback"),
                        makeFlow(flowId: "flow-sibling-fallback"),
                    ]
                )
                await service.initialize()

                _ = await service.handleEventForTrigger(
                    NuxieEvent(id: "evt_segment_fallback", name: "paywall_trigger", distinctId: distinctId)
                )

                let activeJourneys = await service.getActiveJourneys(for: distinctId)
                let primaryJourney = activeJourneys.first { $0.campaignId == "camp-primary-fallback" }
                let siblingJourney = activeJourneys.first { $0.campaignId == "camp-sibling-fallback" }
                expect(primaryJourney).toNot(beNil())
                expect(siblingJourney).toNot(beNil())

                siblingJourney?.triggerSnapshot = .segment(
                    SegmentTriggerConfig(
                        condition: IREnvelope(
                            ir_version: 1,
                            engine_min: nil,
                            compiled_at: nil,
                            expr: .segment(op: "in", id: "premium", within: nil)
                        )
                    )
                )

                await MainActor.run {
                    mocks.flowPresentationService.presentedFlows = [
                        (flowId: "flow-primary-fallback", journey: primaryJourney!)
                    ]
                    mocks.flowPresentationService.isPresentingFlow = true
                }
                await mocks.profileService.clearCache(distinctId: distinctId)
                await mocks.segmentService.setMembership("premium", isMember: false)

                await service.handleScopedGoalEvent(
                    journeyId: primaryJourney!.id,
                    goalId: "signup_complete",
                    goalLabel: "Signed Up",
                    screenId: "screen-1"
                )

                await expect {
                    await service.getActiveJourneys(for: distinctId).contains { $0.id == siblingJourney?.id }
                }.toEventually(beFalse(), timeout: .seconds(2))
                await expect {
                    journeyStore.getCompletions(for: distinctId)
                        .last { $0.journeyId == siblingJourney?.id }?
                        .exitReason
                }.toEventually(equal(.triggerUnmatched), timeout: .seconds(2))
            }

            it("replays source goal-hit handlers after the scoped profile cache expires") {
                let goalHitFollowUp = JourneyEventHandler(
                    id: "goal-hit-follow-up",
                    eventName: JourneyEvents.journeyGoalHit,
                    actions: [
                        .sendEvent(
                            SendEventAction(
                                eventName: "goal_follow_up",
                                properties: nil
                            )
                        )
                    ]
                )
                let campaign = makeCampaign(goal: nil, exitPolicy: nil)
                let flow = makeFlow(handlers: [RemoteFlow.journeyEventHostKey: [goalHitFollowUp]])
                await primeProfile(campaign: campaign, flow: flow)
                await service.initialize()

                let journey = await startJourney()
                await mocks.profileService.clearCache(distinctId: distinctId)

                await service.handleScopedGoalEvent(
                    journeyId: journey.id,
                    goalId: "signup_complete",
                    goalLabel: "Signed Up",
                    screenId: "screen-1"
                )

                await expect {
                    mocks.eventLog.trackedEvents.map(\.name)
                }.toEventually(contain("goal_follow_up"), timeout: .seconds(2))
            }

            it("does not replay scoped goal actions back into the source journey after goal completion") {
                let goalHitFollowUp = JourneyEventHandler(
                    id: "goal-hit-follow-up",
                    eventName: JourneyEvents.journeyGoalHit,
                    actions: [
                        .sendEvent(
                            SendEventAction(
                                eventName: "should_not_run",
                                properties: nil
                            )
                        )
                    ]
                )
                let campaign = makeCampaign(
                    goal: GoalConfig(kind: .event, eventName: JourneyEvents.journeyGoalHit),
                    exitPolicy: ExitPolicy(mode: .onGoal)
                )
                let flow = makeFlow(handlers: [RemoteFlow.journeyEventHostKey: [goalHitFollowUp]])
                await primeProfile(campaign: campaign, flow: flow)
                await service.initialize()

                let journey = await startJourney()

                await service.handleScopedGoalEvent(
                    journeyId: journey.id,
                    goalId: "signup_complete",
                    goalLabel: "Signed Up",
                    screenId: "screen-1"
                )
                try? await Task.sleep(nanoseconds: 200_000_000)

                expect(mocks.eventLog.trackedEvents.map(\.name)).toNot(contain("should_not_run"))
                await expect {
                    await service.getActiveJourneys(for: distinctId).isEmpty
                }.toEventually(beTrue(), timeout: .seconds(2))
            }

            it("starts matching campaigns from scoped goal actions") {
                let goalCampaign = makeCampaign(
                    id: "camp-goal-trigger",
                    flowId: "flow-goal-trigger",
                    trigger: .event(EventTriggerConfig(eventName: JourneyEvents.journeyGoalHit, condition: nil)),
                    goal: nil,
                    exitPolicy: nil
                )
                let primaryCampaign = makeCampaign(goal: nil, exitPolicy: nil)
                let primaryFlow = makeFlow()
                let goalFlow = makeFlow(flowId: "flow-goal-trigger")

                await primeProfile(
                    campaigns: [primaryCampaign, goalCampaign],
                    flows: [primaryFlow, goalFlow]
                )
                await service.initialize()

                let journey = await startJourney()

                await service.handleScopedGoalEvent(
                    journeyId: journey.id,
                    goalId: "signup_complete",
                    goalLabel: "Signed Up",
                    screenId: "screen-1"
                )

                await expect {
                    await service.getActiveJourneys(for: distinctId).map(\.campaignId).sorted()
                }.toEventually(equal([campaignId, "camp-goal-trigger"].sorted()), timeout: .seconds(2))
            }

            it("dispatches source goal-hit handlers before starting goal-triggered flows") {
                let ordering = OrderingRecorder()
                let orderingPresentationService = DismissingOrderingFlowPresentationService(recorder: ordering)
                let sourceController = OrderingMockFlowViewController(mockFlowId: flowId, recorder: ordering)
                orderingPresentationService.mockViewControllers[flowId] = sourceController
                orderingPresentationService.mockViewControllers["flow-goal-trigger"] =
                    MockFlowViewController(mockFlowId: "flow-goal-trigger")
                Container.shared.flowPresentationService.register { @MainActor in orderingPresentationService }
                service = JourneyService(journeyStore: journeyStore)

                let goalHitFollowUp = JourneyEventHandler(
                    id: "goal-hit-follow-up",
                    eventName: JourneyEvents.journeyGoalHit,
                    actions: [
                        .navigate(NavigateAction(screenId: "screen-2", transition: nil))
                    ]
                )
                let goalCampaign = makeCampaign(
                    id: "camp-goal-trigger",
                    flowId: "flow-goal-trigger",
                    trigger: .event(EventTriggerConfig(eventName: JourneyEvents.journeyGoalHit, condition: nil)),
                    goal: nil,
                    exitPolicy: nil
                )
                let primaryCampaign = makeCampaign(goal: nil, exitPolicy: nil)
                let primaryFlow = makeFlow(handlers: [RemoteFlow.journeyEventHostKey: [goalHitFollowUp]])
                let goalFlow = makeFlow(flowId: "flow-goal-trigger")

                await primeProfile(
                    campaigns: [primaryCampaign, goalCampaign],
                    flows: [primaryFlow, goalFlow]
                )
                await service.initialize()

                let journey = await startJourney()
                ordering.clear()

                await service.handleScopedGoalEvent(
                    journeyId: journey.id,
                    goalId: "signup_complete",
                    goalLabel: "Signed Up",
                    screenId: "screen-1"
                )

                await expect {
                    ordering.events
                }.toEventually(equal(["navigate:screen-2", "dismiss-before-present", "present:flow-goal-trigger"]), timeout: .seconds(2))
            }

            it("primes newly started journeys from the tracked scoped goal event") {
                let goalCampaign = makeCampaign(
                    id: "camp-goal-triggered-complete",
                    flowId: "flow-goal-triggered-complete",
                    trigger: .event(EventTriggerConfig(eventName: JourneyEvents.journeyGoalHit, condition: nil)),
                    goal: GoalConfig(kind: .event, eventName: JourneyEvents.journeyGoalHit),
                    exitPolicy: ExitPolicy(mode: .onGoal)
                )
                let primaryCampaign = makeCampaign(goal: nil, exitPolicy: nil)
                let primaryFlow = makeFlow()
                let goalFlow = makeFlow(flowId: "flow-goal-triggered-complete")

                await primeProfile(
                    campaigns: [primaryCampaign, goalCampaign],
                    flows: [primaryFlow, goalFlow]
                )
                await service.initialize()

                let journey = await startJourney()
                mocks.eventLog.trackForTriggerDelayNanoseconds = 200_000_000

                await service.handleScopedGoalEvent(
                    journeyId: journey.id,
                    goalId: "signup_complete",
                    goalLabel: "Signed Up",
                    screenId: "screen-1"
                )

                await expect {
                    (await service.getActiveJourneys(for: distinctId).first {
                        $0.campaignId == "camp-goal-triggered-complete"
                    })?.convertedAt
                }.toEventuallyNot(beNil(), timeout: .seconds(2))
            }

            it("dismisses the source flow before starting goal-triggered flows") {
                let goalCampaign = makeCampaign(
                    id: "camp-goal-trigger",
                    flowId: "flow-goal-trigger",
                    trigger: .event(EventTriggerConfig(eventName: JourneyEvents.journeyGoalHit, condition: nil)),
                    goal: nil,
                    exitPolicy: nil
                )
                let primaryCampaign = makeCampaign(
                    goal: GoalConfig(kind: .event, eventName: JourneyEvents.journeyGoalHit),
                    exitPolicy: ExitPolicy(mode: .onGoal)
                )
                let primaryFlow = makeFlow()
                let goalFlow = makeFlow(flowId: "flow-goal-trigger")

                await primeProfile(
                    campaigns: [primaryCampaign, goalCampaign],
                    flows: [primaryFlow, goalFlow]
                )
                await service.initialize()

                let journey = await startJourney()

                await service.handleScopedGoalEvent(
                    journeyId: journey.id,
                    goalId: "signup_complete",
                    goalLabel: "Signed Up",
                    screenId: "screen-1"
                )

                await expect {
                    await service.getActiveJourneys(for: distinctId).map(\.campaignId)
                }.toEventually(equal(["camp-goal-trigger"]), timeout: .seconds(2))
                await expect {
                    await MainActor.run { mocks.flowPresentationService.dismissedFlows.last }
                }.toEventually(equal(flowId), timeout: .seconds(2))
                await expect {
                    await MainActor.run { mocks.flowPresentationService.presentedFlows.last?.flowId }
                }.toEventually(equal("flow-goal-trigger"), timeout: .seconds(2))
            }

            it("feeds scoped goal actions into all active journeys for goal evaluation") {
                let primaryCampaign = makeCampaign(
                    id: "camp-primary-goal",
                    flowId: "flow-primary-goal",
                    goal: nil,
                    exitPolicy: nil
                )
                let secondaryCampaign = makeCampaign(
                    id: "camp-secondary-goal",
                    flowId: "flow-secondary-goal",
                    goal: GoalConfig(kind: .event, eventName: JourneyEvents.journeyGoalHit),
                    exitPolicy: nil
                )

                await primeProfile(
                    campaigns: [primaryCampaign, secondaryCampaign],
                    flows: [
                        makeFlow(flowId: "flow-primary-goal"),
                        makeFlow(flowId: "flow-secondary-goal"),
                    ]
                )
                await service.initialize()

                _ = await service.handleEventForTrigger(
                    NuxieEvent(id: "evt_goal_scope", name: "paywall_trigger", distinctId: distinctId)
                )

                let activeJourneys = await service.getActiveJourneys(for: distinctId)
                let primaryJourney = activeJourneys.first(where: { $0.campaignId == "camp-primary-goal" })
                let secondaryJourney = activeJourneys.first(where: { $0.campaignId == "camp-secondary-goal" })
                expect(primaryJourney).toNot(beNil())
                expect(secondaryJourney?.convertedAt).to(beNil())

                await service.handleScopedGoalEvent(
                    journeyId: primaryJourney!.id,
                    goalId: "signup_complete",
                    goalLabel: "Signed Up",
                    screenId: "screen-1"
                )

                await expect {
                    (await service.getActiveJourneys(for: distinctId).first {
                        $0.id == secondaryJourney?.id
                    })?.convertedAt
                }.toEventuallyNot(beNil(), timeout: .seconds(2))
            }

            it("re-evaluates sibling goal exits while another flow stays presented") {
                let primaryCampaign = makeCampaign(
                    id: "camp-primary-presented",
                    flowId: "flow-primary-presented",
                    goal: nil,
                    exitPolicy: nil
                )
                let siblingCampaign = makeCampaign(
                    id: "camp-sibling-goal",
                    flowId: "flow-sibling-goal",
                    goal: GoalConfig(kind: .event, eventName: JourneyEvents.journeyGoalHit),
                    exitPolicy: ExitPolicy(mode: .onGoal)
                )

                await primeProfile(
                    campaigns: [primaryCampaign, siblingCampaign],
                    flows: [
                        makeFlow(flowId: "flow-primary-presented"),
                        makeFlow(flowId: "flow-sibling-goal"),
                    ]
                )

                let siblingJourney = Journey(campaign: siblingCampaign, distinctId: distinctId)
                siblingJourney.status = .active
                try? journeyStore.saveJourney(siblingJourney)

                await service.initialize()

                let primaryJourney = await service.startJourney(
                    for: primaryCampaign,
                    distinctId: distinctId
                )
                expect(primaryJourney).toNot(beNil())

                await service.handleScopedGoalEvent(
                    journeyId: primaryJourney!.id,
                    goalId: "signup_complete",
                    goalLabel: "Signed Up",
                    screenId: "screen-1"
                )

                await expect {
                    await service.getActiveJourneys(for: distinctId).map(\.campaignId).sorted()
                }.toEventually(equal(["camp-primary-presented"]), timeout: .seconds(2))
                await expect {
                    journeyStore.getCompletions(for: distinctId).first(where: {
                        $0.journeyId == siblingJourney.id
                    })?.exitReason
                }.toEventually(equal(.goalMet), timeout: .seconds(2))
            }

            it("re-evaluates sibling goal exits from journey snapshots after the cache expires") {
                let primaryCampaign = makeCampaign(
                    id: "camp-primary-stale",
                    flowId: "flow-primary-stale",
                    goal: nil,
                    exitPolicy: nil
                )
                let siblingCampaign = makeCampaign(
                    id: "camp-sibling-stale",
                    flowId: "flow-sibling-stale",
                    goal: GoalConfig(kind: .event, eventName: JourneyEvents.journeyGoalHit),
                    exitPolicy: ExitPolicy(mode: .onGoal)
                )

                await primeProfile(
                    campaigns: [primaryCampaign, siblingCampaign],
                    flows: [
                        makeFlow(flowId: "flow-primary-stale"),
                        makeFlow(flowId: "flow-sibling-stale"),
                    ]
                )

                let siblingJourney = Journey(campaign: siblingCampaign, distinctId: distinctId)
                siblingJourney.status = .active
                try? journeyStore.saveJourney(siblingJourney)

                await service.initialize()

                let primaryJourney = await service.startJourney(
                    for: primaryCampaign,
                    distinctId: distinctId
                )
                expect(primaryJourney).toNot(beNil())

                await mocks.profileService.clearCache(distinctId: distinctId)

                await service.handleScopedGoalEvent(
                    journeyId: primaryJourney!.id,
                    goalId: "signup_complete",
                    goalLabel: "Signed Up",
                    screenId: "screen-1"
                )

                await expect {
                    await service.getActiveJourneys(for: distinctId).map(\.campaignId).sorted()
                }.toEventually(equal(["camp-primary-stale"]), timeout: .seconds(2))
                await expect {
                    journeyStore.getCompletions(for: distinctId).first(where: {
                        $0.journeyId == siblingJourney.id
                    })?.exitReason
                }.toEventually(equal(.goalMet), timeout: .seconds(2))
            }

            it("dispatches goal-hit triggers into sibling runners after the cache expires") {
                let siblingFollowUp = JourneyEventHandler(
                    id: "goal-hit-sibling-follow-up",
                    eventName: JourneyEvents.journeyGoalHit,
                    actions: [
                        .sendEvent(
                            SendEventAction(
                                eventName: "sibling_follow_up",
                                properties: nil
                            )
                        )
                    ]
                )
                let primaryCampaign = makeCampaign(
                    id: "camp-primary-sibling-dispatch",
                    flowId: "flow-primary-sibling-dispatch",
                    goal: nil,
                    exitPolicy: nil
                )
                let siblingCampaign = makeCampaign(
                    id: "camp-sibling-dispatch",
                    flowId: "flow-sibling-dispatch",
                    goal: nil,
                    exitPolicy: nil
                )

                await primeProfile(
                    campaigns: [primaryCampaign, siblingCampaign],
                    flows: [
                        makeFlow(flowId: "flow-primary-sibling-dispatch"),
                        makeFlow(
                            flowId: "flow-sibling-dispatch",
                            handlers: [RemoteFlow.journeyEventHostKey: [siblingFollowUp]]
                        ),
                    ]
                )
                await service.initialize()

                let primaryJourney = await service.startJourney(
                    for: primaryCampaign,
                    distinctId: distinctId
                )
                let siblingJourney = await service.startJourney(
                    for: siblingCampaign,
                    distinctId: distinctId
                )
                expect(primaryJourney).toNot(beNil())
                expect(siblingJourney).toNot(beNil())

                await mocks.profileService.clearCache(distinctId: distinctId)

                await service.handleScopedGoalEvent(
                    journeyId: primaryJourney!.id,
                    goalId: "signup_complete",
                    goalLabel: "Signed Up",
                    screenId: "screen-1"
                )

                await expect {
                    mocks.eventLog.trackedEvents.map(\.name)
                }.toEventually(contain("sibling_follow_up"), timeout: .seconds(2))
            }

            it("replays scoped notification outcomes into newly started journeys") {
                let notificationCampaign = makeCampaign(
                    id: "camp-notifications-replay",
                    flowId: "flow-notifications-replay",
                    trigger: .event(EventTriggerConfig(eventName: SystemEventNames.notificationsEnabled, condition: nil)),
                    goal: GoalConfig(
                        kind: .event,
                        eventName: SystemEventNames.notificationsEnabled,
                        eventFilter: nil,
                        window: 60
                    ),
                    exitPolicy: ExitPolicy(mode: .onGoal)
                )
                let primaryCampaign = makeCampaign(goal: nil, exitPolicy: nil)
                let primaryFlow = makeFlow()
                let notificationFlow = makeFlow(flowId: "flow-notifications-replay")

                await primeProfile(
                    campaigns: [primaryCampaign, notificationCampaign],
                    flows: [primaryFlow, notificationFlow]
                )
                await service.initialize()

                let journey = await startJourney()

                await MainActor.run {
                    (controller.runtimeDelegate as? NotificationPermissionEventReceiver)?.flowViewController(
                        controller,
                        didResolveNotificationPermissionEvent: SystemEventNames.notificationsEnabled,
                        properties: ["journey_id": journey.id],
                        journeyId: journey.id
                    )
                }

                await expect {
                    await service.getActiveJourneys(for: distinctId).first {
                        $0.campaignId == "camp-notifications-replay"
                    }?.convertedAt
                }.toEventuallyNot(beNil(), timeout: .seconds(2))
            }

            it("replays scoped tracking outcomes into newly started journeys") {
                let trackingCampaign = makeCampaign(
                    id: "camp-tracking-replay",
                    flowId: "flow-tracking-replay",
                    trigger: .event(EventTriggerConfig(eventName: SystemEventNames.trackingAuthorized, condition: nil)),
                    goal: GoalConfig(
                        kind: .event,
                        eventName: SystemEventNames.trackingAuthorized,
                        eventFilter: nil,
                        window: 60
                    ),
                    exitPolicy: ExitPolicy(mode: .onGoal)
                )
                let primaryCampaign = makeCampaign(goal: nil, exitPolicy: nil)
                let primaryFlow = makeFlow()
                let trackingFlow = makeFlow(flowId: "flow-tracking-replay")

                await primeProfile(
                    campaigns: [primaryCampaign, trackingCampaign],
                    flows: [primaryFlow, trackingFlow]
                )
                await service.initialize()

                let journey = await startJourney()

                await MainActor.run {
                    (controller.runtimeDelegate as? TrackingPermissionEventReceiver)?.flowViewController(
                        controller,
                        didResolveTrackingPermissionEvent: SystemEventNames.trackingAuthorized,
                        properties: ["journey_id": journey.id],
                        journeyId: journey.id
                    )
                }

                await expect {
                    await service.getActiveJourneys(for: distinctId).first {
                        $0.campaignId == "camp-tracking-replay"
                    }?.convertedAt
                }.toEventuallyNot(beNil(), timeout: .seconds(2))
            }

            it("replays unsupported scoped tracking outcomes into newly started journeys") {
                let trackingCampaign = makeCampaign(
                    id: "camp-tracking-denied-replay",
                    flowId: "flow-tracking-denied-replay",
                    trigger: .event(EventTriggerConfig(eventName: SystemEventNames.trackingDenied, condition: nil)),
                    goal: GoalConfig(
                        kind: .event,
                        eventName: SystemEventNames.trackingDenied,
                        eventFilter: nil,
                        window: 60
                    ),
                    exitPolicy: ExitPolicy(mode: .onGoal)
                )
                let primaryCampaign = makeCampaign(goal: nil, exitPolicy: nil)
                let primaryFlow = makeFlow(
                    handlers: pressHandlers([
                        .requestTracking(RequestTrackingAction())
                    ])
                )
                let trackingFlow = makeFlow(flowId: "flow-tracking-denied-replay")

                await primeProfile(
                    campaigns: [primaryCampaign, trackingCampaign],
                    flows: [primaryFlow, trackingFlow]
                )
                await service.initialize()

                _ = await startJourney()
                await MainActor.run {
                    controller.trackingAuthorizationHandler = UnsupportedTrackingAuthorizationHandler()
                    emitScreenPress(controller)
                }

                await expect {
                    await service.getActiveJourneys(for: distinctId).first {
                        $0.campaignId == "camp-tracking-denied-replay"
                    }?.convertedAt
                }.toEventuallyNot(beNil(), timeout: .seconds(2))
            }

            it("completes dismissed journeys after unsupported tracking requests") {
                let campaign = makeCampaign(goal: nil, exitPolicy: nil)
                let flow = makeFlow(
                    handlers: pressHandlers([
                        .requestTracking(RequestTrackingAction())
                    ])
                )
                await primeProfile(campaign: campaign, flow: flow)
                await service.initialize()

                let journey = await startJourney()
                await MainActor.run {
                    controller.trackingAuthorizationHandler = UnsupportedTrackingAuthorizationHandler()
                }

                await MainActor.run {
                    emitScreenPress(controller)
                }

                try? await Task.sleep(nanoseconds: 50_000_000)

                await MainActor.run {
                    controller.runtimeDelegate?.flowViewControllerDidRequestDismiss(
                        controller,
                        reason: .userDismissed
                    )
                }

                await expect {
                    await service.getActiveJourneys(for: distinctId).contains { $0.id == journey.id }
                }.toEventually(beFalse(), timeout: .seconds(2))

                await expect {
                    journeyStore.getCompletions(for: distinctId).last?.exitReason
                }.toEventually(equal(.dismissed), timeout: .seconds(2))
            }

            it("does not defer dismissals for non-permission pending work") {
                let campaign = makeCampaign(goal: nil, exitPolicy: nil)
                let flow = makeFlow()
                await primeProfile(campaign: campaign, flow: flow)
                await service.initialize()

                let journey = await startJourney()
                journey.flowState.pendingAction = FlowPendingAction(
                    handlerId: "wait-generic-dismiss",
                    screenId: nil,
                    componentId: nil,
                    actionIndex: 0,
                    kind: .waitUntil,
                    resumeAt: nil,
                    condition: nil,
                    maxTimeMs: nil,
                    startedAt: Date(),
                    resumeActions: [.exit(ExitAction(reason: "completed"))]
                )

                await MainActor.run {
                    controller.runtimeDelegate?.flowViewControllerDidRequestDismiss(
                        controller,
                        reason: .userDismissed
                    )
                }

                await expect {
                    await service.getActiveJourneys(for: distinctId).contains { $0.id == journey.id }
                }.toEventually(beFalse(), timeout: .seconds(2))

                await expect {
                    journeyStore.getCompletions(for: distinctId)
                        .first(where: { $0.journeyId == journey.id })?.exitReason
                }.toEventually(equal(.dismissed), timeout: .seconds(2))
            }

            it("completes deferred dismissals after scoped tracking outcomes resolve") {
                let campaign = makeCampaign(goal: nil, exitPolicy: nil)
                let flow = makeFlow(
                    handlers: pressHandlers([
                        .requestTracking(RequestTrackingAction())
                    ])
                )
                await primeProfile(campaign: campaign, flow: flow)
                await service.initialize()

                let journey = await startJourney()
                mocks.eventLog.trackForTriggerDelayNanoseconds = 750_000_000

                await MainActor.run {
                    controller.trackingAuthorizationHandler = DelayedTrackingAuthorizationHandler(
                        delayNanoseconds: 100_000_000,
                        result: .authorized
                    )
                    emitScreenPress(controller)
                    controller.runtimeDelegate?.flowViewControllerDidRequestDismiss(
                        controller,
                        reason: .userDismissed
                    )
                }

                await expect {
                    await service.getActiveJourneys(for: distinctId).contains { $0.id == journey.id }
                }.toEventually(beFalse(), timeout: .milliseconds(500))

                await expect {
                    journeyStore.getCompletions(for: distinctId)
                        .first(where: { $0.journeyId == journey.id })?.exitReason
                }.toEventually(equal(.dismissed), timeout: .milliseconds(500))

                try? await Task.sleep(nanoseconds: 800_000_000)
            }

            it("completes dismissed journeys after unsupported request permission kinds") {
                let campaign = makeCampaign(goal: nil, exitPolicy: nil)
                let flow = makeFlow(
                    handlers: pressHandlers([
                        .requestPermission(RequestPermissionAction(permissionType: "location_always"))
                    ])
                )
                await primeProfile(campaign: campaign, flow: flow)
                await service.initialize()

                let journey = await startJourney()

                await MainActor.run {
                    emitScreenPress(controller)
                }

                try? await Task.sleep(nanoseconds: 50_000_000)

                await MainActor.run {
                    controller.runtimeDelegate?.flowViewControllerDidRequestDismiss(
                        controller,
                        reason: .userDismissed
                    )
                }

                await expect {
                    await service.getActiveJourneys(for: distinctId).contains { $0.id == journey.id }
                }.toEventually(beFalse(), timeout: .milliseconds(500))

                await expect {
                    journeyStore.getCompletions(for: distinctId)
                        .first(where: { $0.journeyId == journey.id })?.exitReason
                }.toEventually(equal(.dismissed), timeout: .milliseconds(500))
            }

            it("keeps deferred dismiss waiting when another request permission is still pending") {
                let campaign = makeCampaign(goal: nil, exitPolicy: nil)
                let flow = makeFlow(
                    handlers: pressHandlers([
                        .requestPermission(RequestPermissionAction(permissionType: "location_always")),
                        .requestPermission(RequestPermissionAction(permissionType: "camera"))
                    ])
                )
                await primeProfile(campaign: campaign, flow: flow)
                await service.initialize()

                let journey = await startJourney()

                await MainActor.run {
                    controller.cameraPermissionAuthorizationHandler = DelayedRequestPermissionAuthorizationHandler(
                        initialStatus: .notDetermined,
                        delayNanoseconds: 200_000_000,
                        result: .granted
                    )
                    controller.cameraUsageDescriptionProvider = { "Camera usage description" }
                    emitScreenPress(controller)
                }

                try? await Task.sleep(nanoseconds: 50_000_000)

                await MainActor.run {
                    controller.runtimeDelegate?.flowViewControllerDidRequestDismiss(
                        controller,
                        reason: .userDismissed
                    )
                }

                try? await Task.sleep(nanoseconds: 75_000_000)
                let isStillActive = await service.getActiveJourneys(for: distinctId).contains { $0.id == journey.id }
                expect(isStillActive).to(beTrue())

                await expect {
                    await service.getActiveJourneys(for: distinctId).contains { $0.id == journey.id }
                }.toEventually(beFalse(), timeout: .seconds(2))

                await expect {
                    journeyStore.getCompletions(for: distinctId)
                        .first(where: { $0.journeyId == journey.id })?.exitReason
                }.toEventually(equal(.dismissed), timeout: .seconds(2))
            }

            it("resumes wait_until work on unsupported tracking requests") {
                let campaign = makeCampaign(goal: nil, exitPolicy: nil)
                let flow = makeFlow(
                    handlers: pressHandlers([
                        .requestTracking(RequestTrackingAction())
                    ])
                )
                await primeProfile(campaign: campaign, flow: flow)
                await service.initialize()

                let journey = await startJourney()
                journey.flowState.pendingAction = FlowPendingAction(
                    handlerId: "wait-unsupported-tracking",
                    screenId: nil,
                    componentId: nil,
                    actionIndex: 0,
                    kind: .waitUntil,
                    resumeAt: nil,
                    condition: nil,
                    maxTimeMs: nil,
                    startedAt: Date(),
                    resumeActions: [.exit(ExitAction(reason: "completed"))]
                )

                await MainActor.run {
                    controller.trackingAuthorizationHandler = UnsupportedTrackingAuthorizationHandler()
                    emitScreenPress(controller)
                }

                await expect {
                    journeyStore.getCompletions(for: distinctId)
                        .first(where: { $0.journeyId == journey.id })?.exitReason
                }.toEventually(equal(.completed), timeout: .seconds(2))
            }

            it("tracks scoped notification outcomes against the original user across identify races") {
                let campaign = makeCampaign(goal: nil, exitPolicy: nil)
                let flow = makeFlow()
                await primeProfile(campaign: campaign, flow: flow)
                await service.initialize()

                let journey = await startJourney()
                mocks.identityService.setDistinctId("user_2")

                await MainActor.run {
                    (controller.runtimeDelegate as? NotificationPermissionEventReceiver)?.flowViewController(
                        controller,
                        didResolveNotificationPermissionEvent: SystemEventNames.notificationsEnabled,
                        properties: ["journey_id": journey.id],
                        journeyId: journey.id
                    )
                }

                await expect {
                    mocks.eventLog.trackForTriggerCalls.last?.distinctIdOverride
                }.toEventually(equal(distinctId), timeout: .seconds(2))
            }

            it("still tracks scoped notification outcomes after the original journey is cancelled") {
                let campaign = makeCampaign(goal: nil, exitPolicy: nil)
                let flow = makeFlow()
                await primeProfile(campaign: campaign, flow: flow)
                await service.initialize()

                let journey = await startJourney()
                await service.handleUserChange(from: distinctId, to: "user_2")

                await MainActor.run {
                    (controller.runtimeDelegate as? NotificationPermissionEventReceiver)?.flowViewController(
                        controller,
                        didResolveNotificationPermissionEvent: SystemEventNames.notificationsEnabled,
                        properties: ["journey_id": journey.id],
                        journeyId: journey.id
                    )
                }

                await expect {
                    mocks.eventLog.trackForTriggerCalls.last?.distinctIdOverride
                }.toEventually(equal(distinctId), timeout: .seconds(2))
            }

            it("tracks unsupported scoped tracking outcomes against the original user across identify races") {
                let campaign = makeCampaign(goal: nil, exitPolicy: nil)
                let flow = makeFlow(
                    handlers: pressHandlers([
                        .requestTracking(RequestTrackingAction())
                    ])
                )
                await primeProfile(campaign: campaign, flow: flow)
                await service.initialize()

                _ = await startJourney()
                mocks.identityService.setDistinctId("user_2")

                await MainActor.run {
                    controller.trackingAuthorizationHandler = UnsupportedTrackingAuthorizationHandler()
                    emitScreenPress(controller)
                }

                await expect {
                    mocks.eventLog.trackForTriggerCalls.last?.distinctIdOverride
                }.toEventually(equal(distinctId), timeout: .seconds(2))
            }

            it("tracks unsupported scoped request permission outcomes against the original user across identify races") {
                let campaign = makeCampaign(goal: nil, exitPolicy: nil)
                let flow = makeFlow(
                    handlers: pressHandlers([
                        .requestPermission(RequestPermissionAction(permissionType: "camera"))
                    ])
                )
                await primeProfile(campaign: campaign, flow: flow)
                await service.initialize()

                _ = await startJourney()
                mocks.identityService.setDistinctId("user_2")

                await MainActor.run {
                    controller.cameraPermissionAuthorizationHandler = UnsupportedRequestPermissionAuthorizationHandler()
                    emitScreenPress(controller)
                }

                await expect {
                    mocks.eventLog.trackForTriggerCalls.last?.distinctIdOverride
                }.toEventually(equal(distinctId), timeout: .seconds(2))
            }

            it("resumes wait_until work on scoped notification outcomes") {
                let campaign = makeCampaign(goal: nil, exitPolicy: nil)
                let flow = makeFlow()
                await primeProfile(campaign: campaign, flow: flow)
                await service.initialize()

                let journey = await startJourney()
                journey.flowState.pendingAction = FlowPendingAction(
                    handlerId: "wait-notifications",
                    screenId: nil,
                    componentId: nil,
                    actionIndex: 0,
                    kind: .waitUntil,
                    resumeAt: nil,
                    condition: nil,
                    maxTimeMs: nil,
                    startedAt: Date(),
                    resumeActions: [.exit(ExitAction(reason: "completed"))]
                )

                await MainActor.run {
                    (controller.runtimeDelegate as? NotificationPermissionEventReceiver)?.flowViewController(
                        controller,
                        didResolveNotificationPermissionEvent: SystemEventNames.notificationsEnabled,
                        properties: ["journey_id": journey.id],
                        journeyId: journey.id
                    )
                }

                await expect {
                    journeyStore.getCompletions(for: distinctId).last?.exitReason
                }.toEventually(equal(.completed), timeout: .seconds(2))
            }

            it("resumes wait_until work on scoped tracking outcomes") {
                let campaign = makeCampaign(goal: nil, exitPolicy: nil)
                let flow = makeFlow()
                await primeProfile(campaign: campaign, flow: flow)
                await service.initialize()

                let journey = await startJourney()
                journey.flowState.pendingAction = FlowPendingAction(
                    handlerId: "wait-tracking",
                    screenId: nil,
                    componentId: nil,
                    actionIndex: 0,
                    kind: .waitUntil,
                    resumeAt: nil,
                    condition: nil,
                    maxTimeMs: nil,
                    startedAt: Date(),
                    resumeActions: [.exit(ExitAction(reason: "completed"))]
                )

                await MainActor.run {
                    (controller.runtimeDelegate as? TrackingPermissionEventReceiver)?.flowViewController(
                        controller,
                        didResolveTrackingPermissionEvent: SystemEventNames.trackingAuthorized,
                        properties: ["journey_id": journey.id],
                        journeyId: journey.id
                    )
                }

                await expect {
                    journeyStore.getCompletions(for: distinctId).last?.exitReason
                }.toEventually(equal(.completed), timeout: .seconds(2))
            }

            it("resumes wait_until work on scoped request permission outcomes") {
                let campaign = makeCampaign(goal: nil, exitPolicy: nil)
                let flow = makeFlow()
                await primeProfile(campaign: campaign, flow: flow)
                await service.initialize()

                let journey = await startJourney()
                journey.flowState.pendingAction = FlowPendingAction(
                    handlerId: "wait-permission",
                    screenId: nil,
                    componentId: nil,
                    actionIndex: 0,
                    kind: .waitUntil,
                    resumeAt: nil,
                    condition: nil,
                    maxTimeMs: nil,
                    startedAt: Date(),
                    resumeActions: [.exit(ExitAction(reason: "completed"))]
                )

                await MainActor.run {
                    (controller.runtimeDelegate as? RequestPermissionEventReceiver)?.flowViewController(
                        controller,
                        didResolveRequestPermissionEvent: SystemEventNames.permissionGranted,
                        properties: [
                            "journey_id": journey.id,
                            "type": "camera"
                        ],
                        journeyId: journey.id
                    )
                }

                await expect {
                    journeyStore.getCompletions(for: distinctId).last?.exitReason
                }.toEventually(equal(.completed), timeout: .seconds(2))
            }

            it("resumes wait_until work on unsupported request permission kinds") {
                let campaign = makeCampaign(goal: nil, exitPolicy: nil)
                let flow = makeFlow()
                await primeProfile(campaign: campaign, flow: flow)
                await service.initialize()

                let journey = await startJourney()
                journey.flowState.pendingAction = FlowPendingAction(
                    handlerId: "wait-unsupported-permission",
                    screenId: nil,
                    componentId: nil,
                    actionIndex: 0,
                    kind: .waitUntil,
                    resumeAt: nil,
                    condition: nil,
                    maxTimeMs: nil,
                    startedAt: Date(),
                    resumeActions: [.exit(ExitAction(reason: "completed"))]
                )

                await MainActor.run {
                    (controller.runtimeDelegate as? RequestPermissionEventReceiver)?.flowViewController(
                        controller,
                        didIgnoreUnsupportedRequestPermissionType: "location_always",
                        journeyId: journey.id
                    )
                }

                await expect {
                    journeyStore.getCompletions(for: distinctId).last?.exitReason
                }.toEventually(equal(.completed), timeout: .seconds(2))
            }

            it("honors gate plans from unsupported scoped request permission outcomes") {
                let orderingPresentationService = OrderingFlowPresentationService(recorder: OrderingRecorder())
                orderingPresentationService.defaultMockViewController = controller
                Container.shared.flowPresentationService.register { @MainActor in orderingPresentationService }
                service = JourneyService(journeyStore: journeyStore)

                let campaign = makeCampaign(goal: nil, exitPolicy: nil)
                let flow = makeFlow()
                await primeProfile(campaign: campaign, flow: flow)
                await service.initialize()

                let journey = await startJourney()
                mocks.eventLog.trackWithResponseResult = makeGatePlanResponse(
                    decision: "show_flow",
                    flowId: "gate-flow"
                )

                await MainActor.run {
                    (controller.runtimeDelegate as? RequestPermissionEventReceiver)?.flowViewController(
                        controller,
                        didIgnoreUnsupportedRequestPermissionType: "location_always",
                        journeyId: journey.id
                    )
                }

                await expect {
                    await MainActor.run {
                        orderingPresentationService.wasFlowPresented("gate-flow")
                    }
                }.toEventually(beTrue(), timeout: .seconds(2))
            }

            it("honors gate plans from scoped goal actions") {
                let orderingPresentationService = OrderingFlowPresentationService(recorder: OrderingRecorder())
                orderingPresentationService.defaultMockViewController = controller
                Container.shared.flowPresentationService.register { @MainActor in orderingPresentationService }
                service = JourneyService(journeyStore: journeyStore)

                let campaign = makeCampaign(goal: nil, exitPolicy: nil)
                let flow = makeFlow()
                await primeProfile(campaign: campaign, flow: flow)
                await service.initialize()

                let journey = await startJourney()
                mocks.eventLog.trackWithResponseResult = makeGatePlanResponse(
                    decision: "show_flow",
                    flowId: "gate-flow"
                )

                await service.handleScopedGoalEvent(
                    journeyId: journey.id,
                    goalId: "signup_complete",
                    goalLabel: "Signed Up",
                    screenId: "screen-1"
                )

                await expect {
                    await MainActor.run {
                        orderingPresentationService.wasFlowPresented("gate-flow")
                    }
                }.toEventually(beTrue(), timeout: .seconds(2))
            }

            it("closes the source journey before presenting goal gate-plan flows") {
                let ordering = OrderingRecorder()
                let orderingStore = OrderingJourneyStore(recorder: ordering)
                let orderingPresentationService = OrderingFlowPresentationService(recorder: ordering)
                orderingPresentationService.defaultMockViewController = controller
                Container.shared.flowPresentationService.register { @MainActor in orderingPresentationService }
                service = JourneyService(journeyStore: orderingStore)
                journeyStore = orderingStore

                let campaign = makeCampaign(goal: nil, exitPolicy: nil)
                let flow = makeFlow()
                await primeProfile(campaign: campaign, flow: flow)
                await service.initialize()

                let journey = await startJourney()
                mocks.eventLog.trackWithResponseResult = makeGatePlanResponse(
                    decision: "show_flow",
                    flowId: "gate-flow"
                )

                ordering.clear()

                await service.handleScopedGoalEvent(
                    journeyId: journey.id,
                    goalId: "signup_complete",
                    goalLabel: "Signed Up",
                    screenId: "screen-1"
                )

                await expect {
                    ordering.events
                }.toEventually(equal(["complete:\(campaignId)", "present:gate-flow"]), timeout: .seconds(2))
                await expect {
                    await service.getActiveJourneys(for: distinctId).isEmpty
                }.toEventually(beTrue(), timeout: .seconds(2))
            }

            it("resumes wait_until work before scoped notification tracking returns") {
                let campaign = makeCampaign(goal: nil, exitPolicy: nil)
                let flow = makeFlow()
                await primeProfile(campaign: campaign, flow: flow)
                await service.initialize()

                let journey = await startJourney()
                journey.flowState.pendingAction = FlowPendingAction(
                    handlerId: "wait-notifications",
                    screenId: nil,
                    componentId: nil,
                    actionIndex: 0,
                    kind: .waitUntil,
                    resumeAt: nil,
                    condition: nil,
                    maxTimeMs: nil,
                    startedAt: Date(),
                    resumeActions: [.exit(ExitAction(reason: "completed"))]
                )
                mocks.eventLog.trackForTriggerDelayNanoseconds = 750_000_000

                await MainActor.run {
                    (controller.runtimeDelegate as? NotificationPermissionEventReceiver)?.flowViewController(
                        controller,
                        didResolveNotificationPermissionEvent: SystemEventNames.notificationsEnabled,
                        properties: ["journey_id": journey.id],
                        journeyId: journey.id
                    )
                }

                await expect {
                    journeyStore.getCompletions(for: distinctId).last?.exitReason
                }.toEventually(equal(.completed), timeout: .milliseconds(250))

                try? await Task.sleep(nanoseconds: 800_000_000)
            }

            it("uses enriched scoped notification properties during immediate local goal evaluation") {
                Container.shared.sessionService().setSessionId("session-notification")

                let notificationGoal = GoalConfig(
                    kind: .event,
                    eventName: SystemEventNames.notificationsEnabled,
                    eventFilter: IREnvelope(
                        ir_version: 1,
                        engine_min: nil,
                        compiled_at: nil,
                        expr: .pred(
                            op: "eq",
                            key: "properties.$session_id",
                            value: .string("session-notification")
                        )
                    ),
                    window: 60
                )
                let campaign = makeCampaign(
                    id: "camp-session-filter",
                    flowId: "flow-session-filter",
                    goal: notificationGoal,
                    exitPolicy: nil
                )

                await primeProfile(
                    campaigns: [campaign],
                    flows: [makeFlow(flowId: "flow-session-filter")]
                )
                await service.initialize()

                let journey = await startJourney()
                mocks.eventLog.trackForTriggerDelayNanoseconds = 750_000_000

                await MainActor.run {
                    (controller.runtimeDelegate as? NotificationPermissionEventReceiver)?.flowViewController(
                        controller,
                        didResolveNotificationPermissionEvent: SystemEventNames.notificationsEnabled,
                        properties: ["journey_id": journey.id],
                        journeyId: journey.id
                    )
                }

                await expect {
                    (await service.getActiveJourneys(for: distinctId).first {
                        $0.id == journey.id
                    })?.convertedAt
                }.toEventuallyNot(beNil(), timeout: .milliseconds(250))

                try? await Task.sleep(nanoseconds: 800_000_000)
            }

            it("feeds scoped notification outcomes into all active journeys for goal evaluation") {
                let notificationGoal = GoalConfig(
                    kind: .event,
                    eventName: SystemEventNames.notificationsEnabled,
                    eventFilter: nil,
                    window: 60
                )
                let primaryCampaign = makeCampaign(
                    id: "camp-primary",
                    flowId: "flow-primary",
                    goal: nil,
                    exitPolicy: nil
                )
                let secondaryCampaign = makeCampaign(
                    id: "camp-secondary",
                    flowId: "flow-secondary",
                    goal: notificationGoal,
                    exitPolicy: nil
                )

                await primeProfile(
                    campaigns: [primaryCampaign, secondaryCampaign],
                    flows: [
                        makeFlow(flowId: "flow-primary"),
                        makeFlow(flowId: "flow-secondary"),
                    ]
                )
                await service.initialize()

                _ = await service.handleEventForTrigger(
                    NuxieEvent(id: "evt_origin", name: "paywall_trigger", distinctId: distinctId)
                )

                let activeJourneys = await service.getActiveJourneys(for: distinctId)
                let primaryJourney = activeJourneys.first(where: { $0.campaignId == "camp-primary" })
                let secondaryJourney = activeJourneys.first(where: { $0.campaignId == "camp-secondary" })
                expect(primaryJourney).toNot(beNil())
                expect(secondaryJourney?.convertedAt).to(beNil())

                await MainActor.run {
                    (controller.runtimeDelegate as? NotificationPermissionEventReceiver)?.flowViewController(
                        controller,
                        didResolveNotificationPermissionEvent: SystemEventNames.notificationsEnabled,
                        properties: ["journey_id": primaryJourney!.id],
                        journeyId: primaryJourney!.id
                    )
                }

                await expect {
                    (await service.getActiveJourneys(for: distinctId).first {
                        $0.campaignId == "camp-secondary"
                    })?.convertedAt
                }.toEventuallyNot(beNil(), timeout: .seconds(2))
            }

            it("feeds scoped notification outcomes into mixed attribute goals") {
                let notificationGoal = GoalConfig(
                    kind: .attribute,
                    attributeExpr: IREnvelope(
                        ir_version: 1,
                        engine_min: nil,
                        compiled_at: nil,
                        expr: .and([
                            .eventsExists(
                                name: SystemEventNames.notificationsEnabled,
                                since: nil,
                                until: nil,
                                within: nil,
                                where_: .pred(
                                    op: "eq",
                                    key: "journey_id",
                                    value: .journeyId
                                )
                            ),
                            .user(op: "eq", key: "plan", value: .string("pro"))
                        ])
                    ),
                    window: 60
                )
                let campaign = makeCampaign(
                    id: "camp-mixed",
                    flowId: "flow-mixed",
                    goal: notificationGoal,
                    exitPolicy: nil
                )

                await primeProfile(
                    campaigns: [campaign],
                    flows: [makeFlow(flowId: "flow-mixed")]
                )
                await service.initialize()
                mocks.identityService.setUserProperty("plan", value: "pro")

                let journey = await startJourney()
                expect(journey.convertedAt).to(beNil())

                await MainActor.run {
                    (controller.runtimeDelegate as? NotificationPermissionEventReceiver)?.flowViewController(
                        controller,
                        didResolveNotificationPermissionEvent: SystemEventNames.notificationsEnabled,
                        properties: ["journey_id": journey.id],
                        journeyId: journey.id
                    )
                }

                await expect {
                    (await service.getActiveJourneys(for: distinctId).first {
                        $0.id == journey.id
                    })?.convertedAt
                }.toEventuallyNot(beNil(), timeout: .seconds(2))
            }

            it("processes active journeys before presenting scoped gate flows") {
                let ordering = OrderingRecorder()
                let orderingStore = OrderingJourneyStore(recorder: ordering)
                let orderingPresentationService = OrderingFlowPresentationService(recorder: ordering)
                orderingPresentationService.defaultMockViewController = controller
                Container.shared.flowPresentationService.register { @MainActor in orderingPresentationService }
                service = JourneyService(journeyStore: orderingStore)
                journeyStore = orderingStore

                let campaign = makeCampaign(goal: nil, exitPolicy: nil)
                let flow = makeFlow()

                await primeProfile(campaign: campaign, flow: flow)
                await service.initialize()

                let journey = await startJourney()
                journey.flowState.pendingAction = FlowPendingAction(
                    handlerId: "wait-notifications",
                    screenId: nil,
                    componentId: nil,
                    actionIndex: 0,
                    kind: .waitUntil,
                    resumeAt: nil,
                    condition: nil,
                    maxTimeMs: nil,
                    startedAt: Date(),
                    resumeActions: [.exit(ExitAction(reason: "completed"))]
                )
                mocks.eventLog.trackWithResponseResult = makeGatePlanResponse(
                    decision: "show_flow",
                    flowId: "gate-flow"
                )

                ordering.clear()

                await MainActor.run {
                    (controller.runtimeDelegate as? NotificationPermissionEventReceiver)?.flowViewController(
                        controller,
                        didResolveNotificationPermissionEvent: SystemEventNames.notificationsEnabled,
                        properties: ["journey_id": journey.id],
                        journeyId: journey.id
                    )
                }

                await expect {
                    ordering.events
                }.toEventually(equal(["complete:\(campaignId)", "present:gate-flow"]), timeout: .seconds(2))
            }

            it("does not present scoped require_feature cache-only flows on deny") {
                let orderingPresentationService = OrderingFlowPresentationService(recorder: OrderingRecorder())
                orderingPresentationService.defaultMockViewController = controller
                Container.shared.flowPresentationService.register { @MainActor in orderingPresentationService }

                let campaign = makeCampaign(goal: nil, exitPolicy: nil)
                let flow = makeFlow()
                await primeProfile(campaign: campaign, flow: flow)
                await service.initialize()

                let journey = await startJourney()
                let baselinePresentations = orderingPresentationService.presentFlowCallCount
                mocks.eventLog.trackWithResponseResult = makeGatePlanResponse(
                    decision: "require_feature",
                    flowId: "gate-flow",
                    featureId: "premium",
                    policy: "cache_only"
                )

                await MainActor.run {
                    (controller.runtimeDelegate as? NotificationPermissionEventReceiver)?.flowViewController(
                        controller,
                        didResolveNotificationPermissionEvent: SystemEventNames.notificationsEnabled,
                        properties: ["journey_id": journey.id],
                        journeyId: journey.id
                    )
                }

                await expect {
                    orderingPresentationService.presentFlowCallCount
                }.toEventually(equal(baselinePresentations), timeout: .seconds(2))
                expect(orderingPresentationService.wasFlowPresented("gate-flow")).to(beFalse())
            }
        }
    }
}

private final class DelayedRequestPermissionAuthorizationHandler: PermissionAuthorizationHandling {
    let initialStatus: PermissionAuthorizationStatus
    let delayNanoseconds: UInt64
    let result: PermissionAuthorizationStatus

    init(
        initialStatus: PermissionAuthorizationStatus,
        delayNanoseconds: UInt64,
        result: PermissionAuthorizationStatus
    ) {
        self.initialStatus = initialStatus
        self.delayNanoseconds = delayNanoseconds
        self.result = result
    }

    func authorizationStatus() -> PermissionAuthorizationStatus {
        initialStatus
    }

    func requestAuthorization() async -> PermissionAuthorizationStatus {
        try? await Task.sleep(nanoseconds: delayNanoseconds)
        return result
    }
}

private final class UnsupportedRequestPermissionAuthorizationHandler: PermissionAuthorizationHandling {
    func authorizationStatus() -> PermissionAuthorizationStatus {
        .unsupported
    }

    func requestAuthorization() async -> PermissionAuthorizationStatus {
        .unsupported
    }
}
