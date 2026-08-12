import Foundation
import Quick
import Nimble
import NuxieRuntime
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

// @unchecked Sendable: `_events` is only accessed under `lock`.
private final class OrderingRecorder: @unchecked Sendable {
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

private final class OrderingJourneyStore: MockJourneyStore, @unchecked Sendable {
    private let recorder: OrderingRecorder

    init(recorder: OrderingRecorder) {
        self.recorder = recorder
        super.init()
    }

    override func recordCompletion(_ record: JourneyCompletionRecord) throws {
        try super.recordCompletion(record)
        recorder.append("complete:\(record.experienceId)")
    }
}

private class OrderingExperiencePresentationService: MockExperiencePresentationService, @unchecked Sendable {
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
        runtimeDelegate: ExperienceRuntimeDelegate?
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
        runtimeDelegate: ExperienceRuntimeDelegate?,
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

private final class DismissingOrderingExperiencePresentationService: OrderingExperiencePresentationService, @unchecked Sendable {
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
        runtimeDelegate: ExperienceRuntimeDelegate?
    ) async throws -> ExperienceViewController {
        if isPresentingExperience {
            await dismissCurrentExperience()
            dismissalRecorder.append("dismiss-before-present")
        }
        return try await super.presentExperience(flowId, from: journey, runtimeDelegate: runtimeDelegate)
    }
}

private final class OrderingMockExperienceViewController: MockExperienceViewController {
    private let recorder: OrderingRecorder

    init(mockExperienceVersionId: String, recorder: OrderingRecorder) {
        self.recorder = recorder
        super.init(mockExperienceVersionId: mockExperienceVersionId)
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
        // nonisolated(unsafe): Quick runs beforeEach and each example strictly
        // serially, so these spec-level fixtures are never accessed
        // concurrently despite being captured by @MainActor example closures.
        nonisolated(unsafe) var mocks: MockFactory!
        nonisolated(unsafe) var journeyStore: MockJourneyStore!
        nonisolated(unsafe) var service: JourneyService!
        nonisolated(unsafe) var controller: MockExperienceViewController!

        let distinctId = "user_1"
        let flowId = "flow-exit-timing"
        let experienceId = "camp-exit-timing"

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
            )
        }

        func makeExperience(
            id: String = experienceId,
            flowId: String = flowId,
            trigger: ExperienceTrigger = .event(EventTriggerConfig(eventName: "paywall_trigger", condition: nil)),
            goal: GoalConfig?,
            exitPolicy: ExitPolicy?
        ) -> Experience {
            Experience(
                id: id,
                versionId: flowId,
                name: "Exit Timing Experience",
                reentry: .everyTime,
                publishedAt: Date().ISO8601Format(),
                trigger: trigger,
                goal: goal,
                exitPolicy: exitPolicy,
                conversionAnchor: nil,
                experienceType: nil
            )
        }

        func makeLoadedExperience(flowId: String = flowId, handlers: JourneyHandlerMap = [:]) -> Experience {
            var events: JourneyEventMap = [:]
            for (hostId, hostHandlers) in handlers {
                for handler in hostHandlers {
                    events[hostId, default: []].append(
                        EventDeclaration(
                            id: "\(handler.id):event",
                            eventName: handler.eventName
                        )
                    )
                }
            }
            let screens = JourneyDocument(
                screens: [
                    JourneyScreen(
                        id: "screen-1",
                        defaultViewModelName: nil,
                        defaultInstanceId: nil
                    )
                ],
                events: events,
                handlers: handlers,
                viewModelValues: nil
            )
            return Experience.test(
                journey: screens,
                versionId: flowId,
                products: []
            )
        }

        func pressHandlers(_ actions: [JourneyAction]) -> JourneyHandlerMap {
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

        func primeProfile(experience: Experience, package: Experience) async {
            await primeProfile(experiences: [experience], packages: [package])
        }

        func primeProfile(experiences: [Experience], packages: [Experience]) async {
            mocks.identityService.setDistinctId(distinctId)
            let metadataByVersion = Dictionary(
                uniqueKeysWithValues: experiences.map { ($0.versionId, $0) }
            )
            for package in packages {
                guard let metadata = metadataByVersion[package.versionId] else { continue }
                mocks.experienceService.mockExperiences[package.versionId] = Experience(
                    remote: metadata.remote,
                    journey: package.journey,
                    assetBaseURL: package.assetBaseURL,
                    products: package.products
                )
            }
            mocks.profileService.setProfileResponse(
                ResponseBuilders.buildProfileResponse(
                    experiences: experiences
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

        func convertedAt(of journey: Journey?) async -> Date? {
            await journey?.snapshot().convertedAt
        }

        beforeEach { @MainActor in
            mocks = MockFactory.shared
            mocks.dateProvider.setCurrentDate(Date())

            journeyStore = MockJourneyStore()
            service = mocks.makeJourneyService(journeyStore: journeyStore)

            controller = MockExperienceViewController(mockExperienceVersionId: flowId)
            mocks.experiencePresentationService.defaultMockViewController = controller
        }

        describe("journey start persistence") {
            it("persists journey enrollment synchronously before returning a started journey") {
                let experience = makeExperience(goal: nil, exitPolicy: nil)
                let flow = makeLoadedExperience()
                await primeProfile(experience: experience, package: flow)
                await service.initialize()

                let journey = await startJourney()

                let enrollment = mocks.eventLog.trackWithResponseCalls.first {
                    $0.event == JourneyEvents.journeyEnrolled
                }
                expect(enrollment).toNot(beNil())
                expect(enrollment?.properties?["journey_id"] as? String).to(equal(journey.id))
                expect(enrollment?.properties?["experience_id"] as? String).to(equal(experience.id))
                expect(enrollment?.properties?["experience_version"] as? String).to(equal(experience.versionId))
                expect(enrollment?.properties?["trigger_ref"] as? String).to(equal("evt_origin"))
                expect(enrollment?.properties?["plane"] as? String).to(equal("device"))
                expect(enrollment?.properties?["settings_snapshot"] as? [String: Any]).toNot(beNil())
                expect(enrollment?.flushPendingEvents).to(beTrue())
                expect(enrollment?.flushStrategy).to(equal(.eventLog))
            }

            it("flushes pending events when a routed event starts a journey") {
                let experience = makeExperience(goal: nil, exitPolicy: nil)
                let flow = makeLoadedExperience()
                await primeProfile(experience: experience, package: flow)
                await service.initialize()

                await service.handleEvent(
                    NuxieEvent(
                        id: "evt_origin",
                        name: "paywall_trigger",
                        distinctId: distinctId
                    )
                )

                let enrollment = mocks.eventLog.trackWithResponseCalls.first {
                    $0.event == JourneyEvents.journeyEnrolled
                }
                expect(enrollment).toNot(beNil())
                expect(enrollment?.flushPendingEvents).to(beTrue())
                expect(enrollment?.flushStrategy).to(equal(.eventLog))
            }

            it("does not start a local journey when enrollment persistence fails") {
                let experience = makeExperience(goal: nil, exitPolicy: nil)
                let flow = makeLoadedExperience()
                await primeProfile(experience: experience, package: flow)
                await service.initialize()
                mocks.eventLog.trackWithResponseError = URLError(.notConnectedToInternet)

                let results = await service.handleEventForTrigger(
                    NuxieEvent(id: "evt_origin", name: "paywall_trigger", distinctId: distinctId)
                )

                let started = results.contains { result in
                    if case .started = result { return true }
                    return false
                }
                let suppressedStartFailure = results.contains { result in
                    if case .suppressed(.unknown("start_failed")) = result { return true }
                    return false
                }
                expect(started).to(beFalse())
                expect(suppressedStartFailure).to(beTrue())
                await polling(expect {
                    await service.getActiveJourneys(for: distinctId).isEmpty
                }).value.toEventually(beTrue(), timeout: .seconds(2))
            }

            it("tracks renderer events once while routing them outside the source journey") { @MainActor in
                let ordering = OrderingRecorder()
                let eventController = OrderingMockExperienceViewController(mockExperienceVersionId: flowId, recorder: ordering)
                controller = eventController
                mocks.experiencePresentationService.defaultMockViewController = eventController

                let experience = makeExperience(goal: nil, exitPolicy: nil)
                let routedExperience = makeExperience(
                    id: "camp-renderer-event",
                    flowId: "flow-renderer-event",
                    trigger: .event(EventTriggerConfig(eventName: "renderer_event", condition: nil)),
                    goal: nil,
                    exitPolicy: nil
                )
                let flow = makeLoadedExperience(handlers: [
                    "screen-1": [
                        JourneyEventHandler(
                            id: "renderer-event-handler",
                            eventName: "renderer_event",
                            actions: [.navigate(NavigateAction(screenId: "screen-2", transition: nil))]
                        )
                    ]
                ])
                let routedFlow = makeLoadedExperience(flowId: "flow-renderer-event")
                await primeProfile(experiences: [experience, routedExperience], packages: [flow, routedFlow])
                await service.initialize()
                let journey = await startJourney()
                let pending = JourneyPendingAction(
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
                await journey.update { $0.executionState.pendingAction = pending }

                await controller.runtimeDelegate?.experienceViewController(
                    controller,
                    didChangeScreen: "screen-1"
                )
                emitRendererEvent(controller, name: "renderer_event")

                await polling(expect(ordering.events)).value.toEventually(contain("navigate:screen-2"))
                await polling(expect {
                    ordering.events.filter { $0 == "navigate:screen-2" }
                }).value.toEventually(equal(["navigate:screen-2"]), timeout: .seconds(2))
                await polling(expect {
                    ordering.events
                }).value.toEventually(contain("navigate:screen-3"), timeout: .seconds(2))
                await polling(expect {
                    await service.getActiveJourneys(for: distinctId).map(\.experienceId)
                }).value.toEventually(contain("camp-renderer-event"))
                await polling(expect(mocks.eventLog.trackForTriggerCalls.map(\.event))).value.toEventually(contain("renderer_event"))
                let trackedRendererEvent = mocks.eventLog.routedEvents.first {
                    $0.name == "renderer_event"
                }
                let routedJourney = await service.getActiveJourneys(for: distinctId).first {
                    $0.experienceId == "camp-renderer-event"
                }
                let originEventId = await routedJourney?.getContext("_origin_event_id")?.value as? String
                expect(originEventId)
                    .to(equal(trackedRendererEvent?.id))
                expect(mocks.eventLog.trackedEvents.map(\.name)).toNot(contain("renderer_event"))
            }

            it("tracks tagged renderer events through the event routing path") { @MainActor in
                let ordering = OrderingRecorder()
                let eventController = OrderingMockExperienceViewController(mockExperienceVersionId: flowId, recorder: ordering)
                controller = eventController
                mocks.experiencePresentationService.defaultMockViewController = eventController

                let experience = makeExperience(goal: nil, exitPolicy: nil)
                let routedExperience = makeExperience(
                    id: "camp-tagged-renderer-event",
                    flowId: "flow-tagged-renderer-event",
                    trigger: .event(EventTriggerConfig(eventName: "tagged_renderer_event", condition: nil)),
                    goal: nil,
                    exitPolicy: nil
                )
                let flow = makeLoadedExperience(handlers: [
                    "screen-1": [
                        JourneyEventHandler(
                            id: "tagged-renderer-event-handler",
                            eventName: "tagged_renderer_event",
                            actions: [.navigate(NavigateAction(screenId: "screen-2", transition: nil))]
                        )
                    ]
                ])
                let routedFlow = makeLoadedExperience(flowId: "flow-tagged-renderer-event")
                await primeProfile(experiences: [experience, routedExperience], packages: [flow, routedFlow])
                await service.initialize()
                _ = await startJourney()

                await controller.runtimeDelegate?.experienceViewController(
                    controller,
                    didChangeScreen: "screen-1"
                )
                emitTaggedRendererEvent(controller, name: "tagged_renderer_event")

                await polling(expect(ordering.events)).value.toEventually(contain("navigate:screen-2"))
                await polling(expect {
                    await service.getActiveJourneys(for: distinctId).map(\.experienceId)
                }).value.toEventually(contain("camp-tagged-renderer-event"))
                await polling(expect(mocks.eventLog.trackForTriggerCalls.map(\.event))).value
                    .toEventually(contain("tagged_renderer_event"))
                let trackedRendererEvent = mocks.eventLog.routedEvents.first {
                    $0.name == "tagged_renderer_event"
                }
                let routedJourney = await service.getActiveJourneys(for: distinctId).first {
                    $0.experienceId == "camp-tagged-renderer-event"
                }
                let originEventId = await routedJourney?.getContext("_origin_event_id")?.value as? String
                expect(originEventId)
                    .to(equal(trackedRendererEvent?.id))
            }

            it("honors gate plans returned for renderer events") {
                let orderingPresentationService = OrderingExperiencePresentationService(recorder: OrderingRecorder())
                orderingPresentationService.defaultMockViewController = controller
                service = mocks.makeJourneyService(
                    journeyStore: journeyStore,
                    experiencePresentation: orderingPresentationService
                )

                let experience = makeExperience(goal: nil, exitPolicy: nil)
                let flow = makeLoadedExperience()
                await primeProfile(experience: experience, package: flow)
                await service.initialize()
                _ = await startJourney()
                mocks.eventLog.trackWithResponseResult = makeGatePlanResponse(
                    decision: "show_flow",
                    flowId: "gate-flow"
                )

                let gateController = controller!
                await gateController.runtimeDelegate?.experienceViewController(
                    gateController,
                    didChangeScreen: "screen-1"
                )
                await MainActor.run {
                    emitRendererEvent(gateController, name: "renderer_gate_event")
                }

                await polling(expect {
                    await MainActor.run {
                        orderingPresentationService.wasExperiencePresented("gate-flow")
                    }
                }).value.toEventually(beTrue(), timeout: .seconds(2))
                await polling(expect(mocks.eventLog.trackForTriggerCalls.map(\.event))).value
                    .toEventually(contain("renderer_gate_event"))
            }

            it("evaluates source renderer event goals from snapshots when profile cache is missing") {
                let experience = makeExperience(
                    goal: GoalConfig(kind: .event, eventName: "renderer_goal_event"),
                    exitPolicy: ExitPolicy(mode: .onGoal)
                )
                let flow = makeLoadedExperience()
                await primeProfile(experience: experience, package: flow)
                await service.initialize()
                let journey = await startJourney()
                await MainActor.run { [mocks = mocks!] in
                    mocks.experiencePresentationService.isPresentingExperience = false
                }
                await mocks.profileService.clearCache(distinctId: distinctId)

                let goalController = controller!
                await goalController.runtimeDelegate?.experienceViewController(
                    goalController,
                    didChangeScreen: "screen-1"
                )
                await MainActor.run {
                    emitRendererEvent(goalController, name: "renderer_goal_event")
                }

                await polling(expect {
                    journeyStore.getCompletions(for: distinctId).last { $0.journeyId == journey.id }?.exitReason
                }).value.toEventually(equal(.goalMet), timeout: .seconds(2))
            }
        }

        describe("exit deferral during active flow presentation") {
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
                let experience = makeExperience(
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
                let flow = makeLoadedExperience(handlers: [JourneyDocument.journeyEventHostKey: [dismissGoal]])
                await primeProfile(experience: experience, package: flow)
                await service.initialize()

                _ = await startJourney()
                let activeJourneys = await service.getActiveJourneys(for: distinctId)
                let initialState = await activeJourneys.first?.snapshot()
                expect(initialState?.convertedAt).to(beNil())

                let dismissController = controller!
                await dismissController.prepareForDismissal()
                await MainActor.run {
                    dismissController.runtimeDelegate?.experienceViewControllerDidRequestDismiss(
                        dismissController,
                        reason: .userDismissed
                    )
                }

                await polling(expect {
                    journeyStore.getCompletions(for: distinctId).last?.exitReason
                }).value.toEventually(equal(.goalMet), timeout: .seconds(2))
                expect(journeyStore.getCompletions(for: distinctId).last?.exitReason).toNot(equal(.dismissed))
            }

            it("starts matching experiences from scoped notification outcomes") {
                let notificationExperience = makeExperience(
                    id: "camp-notifications",
                    flowId: "flow-notifications",
                    trigger: .event(EventTriggerConfig(eventName: SystemEventNames.notificationsEnabled, condition: nil)),
                    goal: nil,
                    exitPolicy: nil
                )
                let primaryExperience = makeExperience(goal: nil, exitPolicy: nil)
                let primaryFlow = makeLoadedExperience()
                let notificationFlow = makeLoadedExperience(flowId: "flow-notifications")

                await primeProfile(
                    experiences: [primaryExperience, notificationExperience],
                    packages: [primaryFlow, notificationFlow]
                )
                await service.initialize()

                let journey = await startJourney()

                await MainActor.run { [controller = controller!] in
                    (controller.runtimeDelegate as? NotificationPermissionEventReceiver)?.experienceViewController(
                        controller,
                        didResolveNotificationPermissionEvent: SystemEventNames.notificationsEnabled,
                        properties: ["journey_id": journey.id],
                        journeyId: journey.id
                    )
                }

                await polling(expect {
                    await service.getActiveJourneys(for: distinctId).map(\.experienceId).sorted()
                }).value.toEventually(equal([experienceId, "camp-notifications"].sorted()), timeout: .seconds(2))
            }

            it("completes presented journeys when scoped goal actions fire") {
                let experience = makeExperience(
                    goal: GoalConfig(kind: .event, eventName: JourneyEvents.journeyMilestone),
                    exitPolicy: ExitPolicy(mode: .onGoal)
                )
                let flow = makeLoadedExperience()
                await primeProfile(experience: experience, package: flow)
                await service.initialize()

                let journey = await startJourney()

                await service.handleScopedMilestoneEvent(
                    journeyId: journey.id,
                    milestoneId: "signup_complete",
                    milestoneLabel: "Signed Up",
                    screenId: "screen-1"
                )

                await polling(expect {
                    await service.getActiveJourneys(for: distinctId).isEmpty
                }).value.toEventually(beTrue(), timeout: .seconds(2))
                await polling(expect {
                    await MainActor.run { [mocks = mocks!] in mocks.experiencePresentationService.dismissCurrentExperienceCallCount }
                }).value.toEventually(equal(1), timeout: .seconds(2))
                expect(mocks.eventLog.trackForTriggerCalls.last?.properties?["journey_id"] as? String)
                    .to(equal(journey.id))
                expect(mocks.eventLog.trackForTriggerCalls.last?.properties?["milestone_id"] as? String)
                    .to(equal("signup_complete"))
                expect(mocks.eventLog.trackForTriggerCalls.last?.properties?["epoch"] as? Int).to(equal(0))
                expect(mocks.eventLog.trackForTriggerCalls.last?.properties).to(haveCount(3))

                await polling(expect {
                    journeyStore.getCompletions(for: distinctId).last?.exitReason
                }).value.toEventually(equal(.goalMet), timeout: .seconds(2))
            }

            it("persists scoped goal hits for multi-step attribute goals") {
                let experience = makeExperience(
                    goal: GoalConfig(
                        kind: .attribute,
                        attributeExpr: IREnvelope(
                            ir_version: 1,
                            engine_min: nil,
                            compiled_at: nil,
                            expr: .and([
                                .eventsExists(
                                    name: JourneyEvents.journeyMilestone,
                                    since: nil,
                                    until: nil,
                                    within: nil,
                                    where_: .pred(
                                        op: "eq",
                                        key: "milestone_id",
                                        value: .string("signup_started")
                                    )
                                ),
                                .eventsExists(
                                    name: JourneyEvents.journeyMilestone,
                                    since: nil,
                                    until: nil,
                                    within: nil,
                                    where_: .pred(
                                        op: "eq",
                                        key: "milestone_id",
                                        value: .string("signup_completed")
                                    )
                                ),
                            ])
                        )
                    ),
                    exitPolicy: nil
                )
                let flow = makeLoadedExperience()
                await primeProfile(experience: experience, package: flow)
                await service.initialize()

                let journey = await startJourney()
                let initialState = await journey.snapshot()
                expect(initialState.convertedAt).to(beNil())

                await service.handleScopedMilestoneEvent(
                    journeyId: journey.id,
                    milestoneId: "signup_started",
                    milestoneLabel: nil,
                    screenId: "screen-1"
                )

                let journeyAfterFirstGoal = await service.getActiveJourneys(for: distinctId).first {
                    $0.id == journey.id
                }
                let stateAfterFirstGoal = await journeyAfterFirstGoal?.snapshot()
                expect(stateAfterFirstGoal?.convertedAt).to(beNil())

                await service.handleScopedMilestoneEvent(
                    journeyId: journey.id,
                    milestoneId: "signup_completed",
                    milestoneLabel: nil,
                    screenId: "screen-1"
                )

                await polling(expect {
                    let matchingJourney = await service.getActiveJourneys(for: distinctId).first {
                        $0.id == journey.id
                    }
                    return await matchingJourney?.snapshot().convertedAt
                }).value.toEventuallyNot(beNil(), timeout: .seconds(2))
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
                let experience = makeExperience(
                    goal: GoalConfig(kind: .event, eventName: JourneyEvents.journeyMilestone),
                    exitPolicy: ExitPolicy(mode: .onGoal)
                )
                let flow = makeLoadedExperience(handlers: [JourneyDocument.journeyEventHostKey: [dismissFollowUp]])
                await primeProfile(experience: experience, package: flow)
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

                await service.handleScopedMilestoneEvent(
                    journeyId: journey.id,
                    milestoneId: "signup_complete",
                    milestoneLabel: "Signed Up",
                    screenId: "screen-1"
                )

                await polling(expect {
                    journeyStore.getCompletions(for: distinctId).last?.exitReason
                }).value.toEventually(equal(.goalMet), timeout: .seconds(2))
                await polling(expect {
                    mocks.eventLog.trackedEvents.map(\.name)
                }).value.toEventually(contain(JourneyEvents.experienceDismissed), timeout: .seconds(2))
                await polling(expect {
                    mocks.eventLog.trackedEvents.map(\.name)
                }).value.toEventually(contain("dismiss_hook_ran"), timeout: .seconds(2))
                await polling(expect {
                    dismissNotifications.events.last
                }).value.toEventually(equal("goal_met"), timeout: .seconds(2))
            }

            it("completes presented journeys before scoped goal tracking returns") {
                let experience = makeExperience(
                    goal: GoalConfig(kind: .event, eventName: JourneyEvents.journeyMilestone),
                    exitPolicy: ExitPolicy(mode: .onGoal)
                )
                let flow = makeLoadedExperience()
                await primeProfile(experience: experience, package: flow)
                await service.initialize()

                let journey = await startJourney()
                mocks.eventLog.trackForTriggerDelayNanoseconds = 750_000_000

                let scopedGoalTask = Task {
                    await service.handleScopedMilestoneEvent(
                        journeyId: journey.id,
                        milestoneId: "signup_complete",
                        milestoneLabel: "Signed Up",
                        screenId: "screen-1"
                    )
                }

                await polling(expect {
                    await service.getActiveJourneys(for: distinctId).isEmpty
                }).value.toEventually(beTrue(), timeout: .milliseconds(250))
                await polling(expect {
                    await MainActor.run { [mocks = mocks!] in mocks.experiencePresentationService.dismissCurrentExperienceCallCount }
                }).value.toEventually(equal(1), timeout: .milliseconds(250))
                await polling(expect {
                    journeyStore.getCompletions(for: distinctId).last?.exitReason
                }).value.toEventually(equal(.goalMet), timeout: .milliseconds(250))

                await scopedGoalTask.value
            }

            it("uses journey snapshots when scoped goal actions outlive the cached profile") {
                let experience = makeExperience(
                    goal: GoalConfig(kind: .event, eventName: JourneyEvents.journeyMilestone),
                    exitPolicy: ExitPolicy(mode: .onGoal)
                )
                let flow = makeLoadedExperience()
                await primeProfile(experience: experience, package: flow)
                await service.initialize()

                let journey = await startJourney()
                await mocks.profileService.clearCache(distinctId: distinctId)

                await service.handleScopedMilestoneEvent(
                    journeyId: journey.id,
                    milestoneId: "signup_complete",
                    milestoneLabel: "Signed Up",
                    screenId: "screen-1"
                )

                await polling(expect {
                    await service.getActiveJourneys(for: distinctId).isEmpty
                }).value.toEventually(beTrue(), timeout: .seconds(2))
                await polling(expect {
                    journeyStore.getCompletions(for: distinctId).last?.journeyId
                }).value.toEventually(equal(journey.id), timeout: .seconds(2))
                await polling(expect {
                    journeyStore.getCompletions(for: distinctId).last?.exitReason
                }).value.toEventually(equal(.goalMet), timeout: .seconds(2))
            }

            it("replays source goal-hit handlers after the scoped profile cache expires") {
                let goalHitFollowUp = JourneyEventHandler(
                    id: "goal-hit-follow-up",
                    eventName: JourneyEvents.journeyMilestone,
                    actions: [
                        .sendEvent(
                            SendEventAction(
                                eventName: "goal_follow_up",
                                properties: nil
                            )
                        )
                    ]
                )
                let experience = makeExperience(goal: nil, exitPolicy: nil)
                let flow = makeLoadedExperience(handlers: [JourneyDocument.journeyEventHostKey: [goalHitFollowUp]])
                await primeProfile(experience: experience, package: flow)
                await service.initialize()

                let journey = await startJourney()
                await mocks.profileService.clearCache(distinctId: distinctId)

                await service.handleScopedMilestoneEvent(
                    journeyId: journey.id,
                    milestoneId: "signup_complete",
                    milestoneLabel: "Signed Up",
                    screenId: "screen-1"
                )

                await polling(expect {
                    mocks.eventLog.trackedEvents.map(\.name)
                }).value.toEventually(contain("goal_follow_up"), timeout: .seconds(2))
            }

            it("does not replay scoped goal actions back into the source journey after goal completion") {
                let goalHitFollowUp = JourneyEventHandler(
                    id: "goal-hit-follow-up",
                    eventName: JourneyEvents.journeyMilestone,
                    actions: [
                        .sendEvent(
                            SendEventAction(
                                eventName: "should_not_run",
                                properties: nil
                            )
                        )
                    ]
                )
                let experience = makeExperience(
                    goal: GoalConfig(kind: .event, eventName: JourneyEvents.journeyMilestone),
                    exitPolicy: ExitPolicy(mode: .onGoal)
                )
                let flow = makeLoadedExperience(handlers: [JourneyDocument.journeyEventHostKey: [goalHitFollowUp]])
                await primeProfile(experience: experience, package: flow)
                await service.initialize()

                let journey = await startJourney()

                await service.handleScopedMilestoneEvent(
                    journeyId: journey.id,
                    milestoneId: "signup_complete",
                    milestoneLabel: "Signed Up",
                    screenId: "screen-1"
                )
                try? await Task.sleep(nanoseconds: 200_000_000)

                expect(mocks.eventLog.trackedEvents.map(\.name)).toNot(contain("should_not_run"))
                await polling(expect {
                    await service.getActiveJourneys(for: distinctId).isEmpty
                }).value.toEventually(beTrue(), timeout: .seconds(2))
            }

            it("starts matching experiences from scoped goal actions") {
                let goalExperience = makeExperience(
                    id: "camp-goal-trigger",
                    flowId: "flow-goal-trigger",
                    trigger: .event(EventTriggerConfig(eventName: JourneyEvents.journeyMilestone, condition: nil)),
                    goal: nil,
                    exitPolicy: nil
                )
                let primaryExperience = makeExperience(goal: nil, exitPolicy: nil)
                let primaryFlow = makeLoadedExperience()
                let goalFlow = makeLoadedExperience(flowId: "flow-goal-trigger")

                await primeProfile(
                    experiences: [primaryExperience, goalExperience],
                    packages: [primaryFlow, goalFlow]
                )
                await service.initialize()

                let journey = await startJourney()

                await service.handleScopedMilestoneEvent(
                    journeyId: journey.id,
                    milestoneId: "signup_complete",
                    milestoneLabel: "Signed Up",
                    screenId: "screen-1"
                )

                await polling(expect {
                    await service.getActiveJourneys(for: distinctId).map(\.experienceId).sorted()
                }).value.toEventually(equal([experienceId, "camp-goal-trigger"].sorted()), timeout: .seconds(2))
            }

            it("dispatches source goal-hit handlers before starting goal-triggered flows") { @MainActor in
                let ordering = OrderingRecorder()
                let orderingPresentationService = DismissingOrderingExperiencePresentationService(recorder: ordering)
                let sourceController = OrderingMockExperienceViewController(mockExperienceVersionId: flowId, recorder: ordering)
                orderingPresentationService.mockViewControllers[flowId] = sourceController
                orderingPresentationService.mockViewControllers["flow-goal-trigger"] =
                    MockExperienceViewController(mockExperienceVersionId: "flow-goal-trigger")
                service = mocks.makeJourneyService(
                    journeyStore: journeyStore,
                    experiencePresentation: orderingPresentationService
                )

                let goalHitFollowUp = JourneyEventHandler(
                    id: "goal-hit-follow-up",
                    eventName: JourneyEvents.journeyMilestone,
                    actions: [
                        .navigate(NavigateAction(screenId: "screen-2", transition: nil))
                    ]
                )
                let goalExperience = makeExperience(
                    id: "camp-goal-trigger",
                    flowId: "flow-goal-trigger",
                    trigger: .event(EventTriggerConfig(eventName: JourneyEvents.journeyMilestone, condition: nil)),
                    goal: nil,
                    exitPolicy: nil
                )
                let primaryExperience = makeExperience(goal: nil, exitPolicy: nil)
                let primaryFlow = makeLoadedExperience(handlers: [JourneyDocument.journeyEventHostKey: [goalHitFollowUp]])
                let goalFlow = makeLoadedExperience(flowId: "flow-goal-trigger")

                await primeProfile(
                    experiences: [primaryExperience, goalExperience],
                    packages: [primaryFlow, goalFlow]
                )
                await service.initialize()

                let journey = await startJourney()
                ordering.clear()

                await service.handleScopedMilestoneEvent(
                    journeyId: journey.id,
                    milestoneId: "signup_complete",
                    milestoneLabel: "Signed Up",
                    screenId: "screen-1"
                )

                await polling(expect {
                    ordering.events
                }).value.toEventually(equal(["navigate:screen-2", "dismiss-before-present", "present:flow-goal-trigger"]), timeout: .seconds(2))
            }

            it("primes newly started journeys from the tracked scoped goal event") {
                let goalExperience = makeExperience(
                    id: "camp-goal-triggered-complete",
                    flowId: "flow-goal-triggered-complete",
                    trigger: .event(EventTriggerConfig(eventName: JourneyEvents.journeyMilestone, condition: nil)),
                    goal: GoalConfig(kind: .event, eventName: JourneyEvents.journeyMilestone),
                    exitPolicy: ExitPolicy(mode: .onGoal)
                )
                let primaryExperience = makeExperience(goal: nil, exitPolicy: nil)
                let primaryFlow = makeLoadedExperience()
                let goalFlow = makeLoadedExperience(flowId: "flow-goal-triggered-complete")

                await primeProfile(
                    experiences: [primaryExperience, goalExperience],
                    packages: [primaryFlow, goalFlow]
                )
                await service.initialize()

                let journey = await startJourney()
                mocks.eventLog.trackForTriggerDelayNanoseconds = 200_000_000

                await service.handleScopedMilestoneEvent(
                    journeyId: journey.id,
                    milestoneId: "signup_complete",
                    milestoneLabel: "Signed Up",
                    screenId: "screen-1"
                )

                await polling(expect {
                    let matchingJourney = await service.getActiveJourneys(for: distinctId).first {
                        $0.experienceId == "camp-goal-triggered-complete"
                    }
                    return await matchingJourney?.snapshot().convertedAt
                }).value.toEventuallyNot(beNil(), timeout: .seconds(2))
            }

            it("dismisses the source flow before starting goal-triggered flows") {
                let goalExperience = makeExperience(
                    id: "camp-goal-trigger",
                    flowId: "flow-goal-trigger",
                    trigger: .event(EventTriggerConfig(eventName: JourneyEvents.journeyMilestone, condition: nil)),
                    goal: nil,
                    exitPolicy: nil
                )
                let primaryExperience = makeExperience(
                    goal: GoalConfig(kind: .event, eventName: JourneyEvents.journeyMilestone),
                    exitPolicy: ExitPolicy(mode: .onGoal)
                )
                let primaryFlow = makeLoadedExperience()
                let goalFlow = makeLoadedExperience(flowId: "flow-goal-trigger")

                await primeProfile(
                    experiences: [primaryExperience, goalExperience],
                    packages: [primaryFlow, goalFlow]
                )
                await service.initialize()

                let journey = await startJourney()

                await service.handleScopedMilestoneEvent(
                    journeyId: journey.id,
                    milestoneId: "signup_complete",
                    milestoneLabel: "Signed Up",
                    screenId: "screen-1"
                )

                await polling(expect {
                    await service.getActiveJourneys(for: distinctId).map(\.experienceId)
                }).value.toEventually(equal(["camp-goal-trigger"]), timeout: .seconds(2))
                await polling(expect {
                    await MainActor.run { [mocks = mocks!] in mocks.experiencePresentationService.dismissedExperiences.last }
                }).value.toEventually(equal(flowId), timeout: .seconds(2))
                await polling(expect {
                    await MainActor.run { [mocks = mocks!] in mocks.experiencePresentationService.presentedExperiences.last?.experienceVersionId }
                }).value.toEventually(equal("flow-goal-trigger"), timeout: .seconds(2))
            }

            it("feeds scoped goal actions into all active journeys for goal evaluation") {
                let primaryExperience = makeExperience(
                    id: "camp-primary-goal",
                    flowId: "flow-primary-goal",
                    goal: nil,
                    exitPolicy: nil
                )
                let secondaryExperience = makeExperience(
                    id: "camp-secondary-goal",
                    flowId: "flow-secondary-goal",
                    goal: GoalConfig(kind: .event, eventName: JourneyEvents.journeyMilestone),
                    exitPolicy: nil
                )

                await primeProfile(
                    experiences: [primaryExperience, secondaryExperience],
                    packages: [
                        makeLoadedExperience(flowId: "flow-primary-goal"),
                        makeLoadedExperience(flowId: "flow-secondary-goal"),
                    ]
                )
                await service.initialize()

                _ = await service.handleEventForTrigger(
                    NuxieEvent(id: "evt_goal_scope", name: "paywall_trigger", distinctId: distinctId)
                )

                let activeJourneys = await service.getActiveJourneys(for: distinctId)
                let primaryJourney = activeJourneys.first(where: { $0.experienceId == "camp-primary-goal" })
                let secondaryJourney = activeJourneys.first(where: { $0.experienceId == "camp-secondary-goal" })
                expect(primaryJourney).toNot(beNil())
                let secondaryConvertedAt = await convertedAt(of: secondaryJourney)
                expect(secondaryConvertedAt).to(beNil())

                await service.handleScopedMilestoneEvent(
                    journeyId: primaryJourney!.id,
                    milestoneId: "signup_complete",
                    milestoneLabel: "Signed Up",
                    screenId: "screen-1"
                )

                await polling(expect {
                    let matchingJourney = await service.getActiveJourneys(for: distinctId).first {
                        $0.id == secondaryJourney?.id
                    }
                    return await convertedAt(of: matchingJourney)
                }).value.toEventuallyNot(beNil(), timeout: .seconds(2))
            }

            it("re-evaluates sibling goal exits while another flow stays presented") {
                let primaryExperience = makeExperience(
                    id: "camp-primary-presented",
                    flowId: "flow-primary-presented",
                    goal: nil,
                    exitPolicy: nil
                )
                let siblingExperience = makeExperience(
                    id: "camp-sibling-goal",
                    flowId: "flow-sibling-goal",
                    goal: GoalConfig(kind: .event, eventName: JourneyEvents.journeyMilestone),
                    exitPolicy: ExitPolicy(mode: .onGoal)
                )

                await primeProfile(
                    experiences: [primaryExperience, siblingExperience],
                    packages: [
                        makeLoadedExperience(flowId: "flow-primary-presented"),
                        makeLoadedExperience(flowId: "flow-sibling-goal"),
                    ]
                )

                var siblingJourney = JourneySnapshot(experience: siblingExperience, distinctId: distinctId, now: mocks.dateProvider.now())
                siblingJourney.status = .active
                try? journeyStore.saveJourney(siblingJourney)

                await service.initialize()

                let primaryJourney = await service.startJourney(
                    for: primaryExperience,
                    distinctId: distinctId
                )
                expect(primaryJourney).toNot(beNil())

                await service.handleScopedMilestoneEvent(
                    journeyId: primaryJourney!.id,
                    milestoneId: "signup_complete",
                    milestoneLabel: "Signed Up",
                    screenId: "screen-1"
                )

                await polling(expect {
                    await service.getActiveJourneys(for: distinctId).map(\.experienceId).sorted()
                }).value.toEventually(equal(["camp-primary-presented"]), timeout: .seconds(2))
                await polling(expect {
                    journeyStore.getCompletions(for: distinctId).first(where: {
                        $0.journeyId == siblingJourney.id
                    })?.exitReason
                }).value.toEventually(equal(.goalMet), timeout: .seconds(2))
            }

            it("re-evaluates sibling goal exits from journey snapshots after the cache expires") {
                let primaryExperience = makeExperience(
                    id: "camp-primary-stale",
                    flowId: "flow-primary-stale",
                    goal: nil,
                    exitPolicy: nil
                )
                let siblingExperience = makeExperience(
                    id: "camp-sibling-stale",
                    flowId: "flow-sibling-stale",
                    goal: GoalConfig(kind: .event, eventName: JourneyEvents.journeyMilestone),
                    exitPolicy: ExitPolicy(mode: .onGoal)
                )

                await primeProfile(
                    experiences: [primaryExperience, siblingExperience],
                    packages: [
                        makeLoadedExperience(flowId: "flow-primary-stale"),
                        makeLoadedExperience(flowId: "flow-sibling-stale"),
                    ]
                )

                var siblingJourney = JourneySnapshot(experience: siblingExperience, distinctId: distinctId, now: mocks.dateProvider.now())
                siblingJourney.status = .active
                try? journeyStore.saveJourney(siblingJourney)

                await service.initialize()

                let primaryJourney = await service.startJourney(
                    for: primaryExperience,
                    distinctId: distinctId
                )
                expect(primaryJourney).toNot(beNil())

                await mocks.profileService.clearCache(distinctId: distinctId)

                await service.handleScopedMilestoneEvent(
                    journeyId: primaryJourney!.id,
                    milestoneId: "signup_complete",
                    milestoneLabel: "Signed Up",
                    screenId: "screen-1"
                )

                await polling(expect {
                    await service.getActiveJourneys(for: distinctId).map(\.experienceId).sorted()
                }).value.toEventually(equal(["camp-primary-stale"]), timeout: .seconds(2))
                await polling(expect {
                    journeyStore.getCompletions(for: distinctId).first(where: {
                        $0.journeyId == siblingJourney.id
                    })?.exitReason
                }).value.toEventually(equal(.goalMet), timeout: .seconds(2))
            }

            it("dispatches goal-hit triggers into sibling runners after the cache expires") {
                let siblingFollowUp = JourneyEventHandler(
                    id: "goal-hit-sibling-follow-up",
                    eventName: JourneyEvents.journeyMilestone,
                    actions: [
                        .sendEvent(
                            SendEventAction(
                                eventName: "sibling_follow_up",
                                properties: nil
                            )
                        )
                    ]
                )
                let primaryExperience = makeExperience(
                    id: "camp-primary-sibling-dispatch",
                    flowId: "flow-primary-sibling-dispatch",
                    goal: nil,
                    exitPolicy: nil
                )
                let siblingExperience = makeExperience(
                    id: "camp-sibling-dispatch",
                    flowId: "flow-sibling-dispatch",
                    goal: nil,
                    exitPolicy: nil
                )

                await primeProfile(
                    experiences: [primaryExperience, siblingExperience],
                    packages: [
                        makeLoadedExperience(flowId: "flow-primary-sibling-dispatch"),
                        makeLoadedExperience(
                            flowId: "flow-sibling-dispatch",
                            handlers: [JourneyDocument.journeyEventHostKey: [siblingFollowUp]]
                        ),
                    ]
                )
                await service.initialize()

                let primaryJourney = await service.startJourney(
                    for: primaryExperience,
                    distinctId: distinctId
                )
                let siblingJourney = await service.startJourney(
                    for: siblingExperience,
                    distinctId: distinctId
                )
                expect(primaryJourney).toNot(beNil())
                expect(siblingJourney).toNot(beNil())

                await mocks.profileService.clearCache(distinctId: distinctId)

                await service.handleScopedMilestoneEvent(
                    journeyId: primaryJourney!.id,
                    milestoneId: "signup_complete",
                    milestoneLabel: "Signed Up",
                    screenId: "screen-1"
                )

                await polling(expect {
                    mocks.eventLog.trackedEvents.map(\.name)
                }).value.toEventually(contain("sibling_follow_up"), timeout: .seconds(2))
            }

            it("replays scoped notification outcomes into newly started journeys") {
                let notificationExperience = makeExperience(
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
                let primaryExperience = makeExperience(goal: nil, exitPolicy: nil)
                let primaryFlow = makeLoadedExperience()
                let notificationFlow = makeLoadedExperience(flowId: "flow-notifications-replay")

                await primeProfile(
                    experiences: [primaryExperience, notificationExperience],
                    packages: [primaryFlow, notificationFlow]
                )
                await service.initialize()

                let journey = await startJourney()

                await MainActor.run { [controller = controller!] in
                    (controller.runtimeDelegate as? NotificationPermissionEventReceiver)?.experienceViewController(
                        controller,
                        didResolveNotificationPermissionEvent: SystemEventNames.notificationsEnabled,
                        properties: ["journey_id": journey.id],
                        journeyId: journey.id
                    )
                }

                await polling(expect {
                    let matchingJourney = await service.getActiveJourneys(for: distinctId).first {
                        $0.experienceId == "camp-notifications-replay"
                    }
                    return await convertedAt(of: matchingJourney)
                }).value.toEventuallyNot(beNil(), timeout: .seconds(2))
            }

            it("replays scoped tracking outcomes into newly started journeys") {
                let trackingExperience = makeExperience(
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
                let primaryExperience = makeExperience(goal: nil, exitPolicy: nil)
                let primaryFlow = makeLoadedExperience()
                let trackingFlow = makeLoadedExperience(flowId: "flow-tracking-replay")

                await primeProfile(
                    experiences: [primaryExperience, trackingExperience],
                    packages: [primaryFlow, trackingFlow]
                )
                await service.initialize()

                let journey = await startJourney()

                await MainActor.run { [controller = controller!] in
                    (controller.runtimeDelegate as? TrackingPermissionEventReceiver)?.experienceViewController(
                        controller,
                        didResolveTrackingPermissionEvent: SystemEventNames.trackingAuthorized,
                        properties: ["journey_id": journey.id],
                        journeyId: journey.id
                    )
                }

                await polling(expect {
                    let matchingJourney = await service.getActiveJourneys(for: distinctId).first {
                        $0.experienceId == "camp-tracking-replay"
                    }
                    return await convertedAt(of: matchingJourney)
                }).value.toEventuallyNot(beNil(), timeout: .seconds(2))
            }

            it("replays unsupported scoped tracking outcomes into newly started journeys") {
                let trackingExperience = makeExperience(
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
                let primaryExperience = makeExperience(goal: nil, exitPolicy: nil)
                let primaryFlow = makeLoadedExperience(
                    handlers: pressHandlers([
                        .requestTracking(RequestTrackingAction())
                    ])
                )
                let trackingFlow = makeLoadedExperience(flowId: "flow-tracking-denied-replay")

                await primeProfile(
                    experiences: [primaryExperience, trackingExperience],
                    packages: [primaryFlow, trackingFlow]
                )
                await service.initialize()

                _ = await startJourney()
                await MainActor.run { [controller = controller!] in
                    controller.trackingAuthorizationHandler = UnsupportedTrackingAuthorizationHandler()
                    emitScreenPress(controller)
                }

                await polling(expect {
                    let matchingJourney = await service.getActiveJourneys(for: distinctId).first {
                        $0.experienceId == "camp-tracking-denied-replay"
                    }
                    return await convertedAt(of: matchingJourney)
                }).value.toEventuallyNot(beNil(), timeout: .seconds(2))
            }

            it("completes dismissed journeys after unsupported tracking requests") {
                let experience = makeExperience(goal: nil, exitPolicy: nil)
                let flow = makeLoadedExperience(
                    handlers: pressHandlers([
                        .requestTracking(RequestTrackingAction())
                    ])
                )
                await primeProfile(experience: experience, package: flow)
                await service.initialize()

                let journey = await startJourney()
                await MainActor.run { [controller = controller!] in
                    controller.trackingAuthorizationHandler = UnsupportedTrackingAuthorizationHandler()
                }

                await MainActor.run { [controller = controller!] in
                    emitScreenPress(controller)
                }

                try? await Task.sleep(nanoseconds: 50_000_000)

                await MainActor.run { [controller = controller!] in
                    controller.runtimeDelegate?.experienceViewControllerDidRequestDismiss(
                        controller,
                        reason: .userDismissed
                    )
                }

                await polling(expect {
                    await service.getActiveJourneys(for: distinctId).contains { $0.id == journey.id }
                }).value.toEventually(beFalse(), timeout: .seconds(2))

                await polling(expect {
                    journeyStore.getCompletions(for: distinctId).last?.exitReason
                }).value.toEventually(equal(.dismissed), timeout: .seconds(2))
            }

            it("does not defer dismissals for non-permission pending work") {
                let experience = makeExperience(goal: nil, exitPolicy: nil)
                let flow = makeLoadedExperience()
                await primeProfile(experience: experience, package: flow)
                await service.initialize()

                let journey = await startJourney()
                await journey.update { $0.executionState.pendingAction = JourneyPendingAction(
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
                ) }

                await MainActor.run { [controller = controller!] in
                    controller.runtimeDelegate?.experienceViewControllerDidRequestDismiss(
                        controller,
                        reason: .userDismissed
                    )
                }

                await polling(expect {
                    await service.getActiveJourneys(for: distinctId).contains { $0.id == journey.id }
                }).value.toEventually(beFalse(), timeout: .seconds(2))

                await polling(expect {
                    journeyStore.getCompletions(for: distinctId)
                        .first(where: { $0.journeyId == journey.id })?.exitReason
                }).value.toEventually(equal(.dismissed), timeout: .seconds(2))
            }

            it("completes deferred dismissals after scoped tracking outcomes resolve") {
                let experience = makeExperience(goal: nil, exitPolicy: nil)
                let flow = makeLoadedExperience(
                    handlers: pressHandlers([
                        .requestTracking(RequestTrackingAction())
                    ])
                )
                await primeProfile(experience: experience, package: flow)
                await service.initialize()

                let journey = await startJourney()
                mocks.eventLog.trackForTriggerDelayNanoseconds = 750_000_000

                await MainActor.run { [controller = controller!] in
                    controller.trackingAuthorizationHandler = DelayedTrackingAuthorizationHandler(
                        delayNanoseconds: 100_000_000,
                        result: .authorized
                    )
                    emitScreenPress(controller)
                    controller.runtimeDelegate?.experienceViewControllerDidRequestDismiss(
                        controller,
                        reason: .userDismissed
                    )
                }

                await polling(expect {
                    await service.getActiveJourneys(for: distinctId).contains { $0.id == journey.id }
                }).value.toEventually(beFalse(), timeout: .milliseconds(500))

                await polling(expect {
                    journeyStore.getCompletions(for: distinctId)
                        .first(where: { $0.journeyId == journey.id })?.exitReason
                }).value.toEventually(equal(.dismissed), timeout: .milliseconds(500))

                try? await Task.sleep(nanoseconds: 800_000_000)
            }

            it("completes dismissed journeys after unsupported request permission kinds") {
                let experience = makeExperience(goal: nil, exitPolicy: nil)
                let flow = makeLoadedExperience(
                    handlers: pressHandlers([
                        .requestPermission(RequestPermissionAction(permissionType: "location_always"))
                    ])
                )
                await primeProfile(experience: experience, package: flow)
                await service.initialize()

                let journey = await startJourney()

                await MainActor.run { [controller = controller!] in
                    emitScreenPress(controller)
                }

                try? await Task.sleep(nanoseconds: 50_000_000)

                await MainActor.run { [controller = controller!] in
                    controller.runtimeDelegate?.experienceViewControllerDidRequestDismiss(
                        controller,
                        reason: .userDismissed
                    )
                }

                await polling(expect {
                    await service.getActiveJourneys(for: distinctId).contains { $0.id == journey.id }
                }).value.toEventually(beFalse(), timeout: .milliseconds(500))

                await polling(expect {
                    journeyStore.getCompletions(for: distinctId)
                        .first(where: { $0.journeyId == journey.id })?.exitReason
                }).value.toEventually(equal(.dismissed), timeout: .milliseconds(500))
            }

            it("keeps deferred dismiss waiting when another request permission is still pending") {
                let experience = makeExperience(goal: nil, exitPolicy: nil)
                let flow = makeLoadedExperience(
                    handlers: pressHandlers([
                        .requestPermission(RequestPermissionAction(permissionType: "location_always")),
                        .requestPermission(RequestPermissionAction(permissionType: "camera"))
                    ])
                )
                await primeProfile(experience: experience, package: flow)
                await service.initialize()

                let journey = await startJourney()

                await MainActor.run { [controller = controller!] in
                    controller.cameraPermissionAuthorizationHandler = DelayedRequestPermissionAuthorizationHandler(
                        initialStatus: .notDetermined,
                        delayNanoseconds: 200_000_000,
                        result: .granted
                    )
                    controller.cameraUsageDescriptionProvider = { "Camera usage description" }
                    emitScreenPress(controller)
                }

                try? await Task.sleep(nanoseconds: 50_000_000)

                await MainActor.run { [controller = controller!] in
                    controller.runtimeDelegate?.experienceViewControllerDidRequestDismiss(
                        controller,
                        reason: .userDismissed
                    )
                }

                try? await Task.sleep(nanoseconds: 75_000_000)
                let isStillActive = await service.getActiveJourneys(for: distinctId).contains { $0.id == journey.id }
                expect(isStillActive).to(beTrue())

                await polling(expect {
                    await service.getActiveJourneys(for: distinctId).contains { $0.id == journey.id }
                }).value.toEventually(beFalse(), timeout: .seconds(2))

                await polling(expect {
                    journeyStore.getCompletions(for: distinctId)
                        .first(where: { $0.journeyId == journey.id })?.exitReason
                }).value.toEventually(equal(.dismissed), timeout: .seconds(2))
            }

            it("resumes wait_until work on unsupported tracking requests") {
                let experience = makeExperience(goal: nil, exitPolicy: nil)
                let flow = makeLoadedExperience(
                    handlers: pressHandlers([
                        .requestTracking(RequestTrackingAction())
                    ])
                )
                await primeProfile(experience: experience, package: flow)
                await service.initialize()

                let journey = await startJourney()
                await journey.update { $0.executionState.pendingAction = JourneyPendingAction(
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
                ) }

                await MainActor.run { [controller = controller!] in
                    controller.trackingAuthorizationHandler = UnsupportedTrackingAuthorizationHandler()
                    emitScreenPress(controller)
                }

                await polling(expect {
                    journeyStore.getCompletions(for: distinctId)
                        .first(where: { $0.journeyId == journey.id })?.exitReason
                }).value.toEventually(equal(.completed), timeout: .seconds(2))
            }

            it("tracks scoped notification outcomes against the original user across identify races") {
                let experience = makeExperience(goal: nil, exitPolicy: nil)
                let flow = makeLoadedExperience()
                await primeProfile(experience: experience, package: flow)
                await service.initialize()

                let journey = await startJourney()
                mocks.identityService.setDistinctId("user_2")

                await MainActor.run { [controller = controller!] in
                    (controller.runtimeDelegate as? NotificationPermissionEventReceiver)?.experienceViewController(
                        controller,
                        didResolveNotificationPermissionEvent: SystemEventNames.notificationsEnabled,
                        properties: ["journey_id": journey.id],
                        journeyId: journey.id
                    )
                }

                await polling(expect {
                    mocks.eventLog.trackForTriggerCalls.last?.distinctIdOverride
                }).value.toEventually(equal(distinctId), timeout: .seconds(2))
            }

            it("still tracks scoped notification outcomes after the original journey is cancelled") {
                let experience = makeExperience(goal: nil, exitPolicy: nil)
                let flow = makeLoadedExperience()
                await primeProfile(experience: experience, package: flow)
                await service.initialize()

                let journey = await startJourney()
                await service.handleUserChange(from: distinctId, to: "user_2")

                await MainActor.run { [controller = controller!] in
                    (controller.runtimeDelegate as? NotificationPermissionEventReceiver)?.experienceViewController(
                        controller,
                        didResolveNotificationPermissionEvent: SystemEventNames.notificationsEnabled,
                        properties: ["journey_id": journey.id],
                        journeyId: journey.id
                    )
                }

                await polling(expect {
                    mocks.eventLog.trackForTriggerCalls.last?.distinctIdOverride
                }).value.toEventually(equal(distinctId), timeout: .seconds(2))
            }

            it("tracks unsupported scoped tracking outcomes against the original user across identify races") {
                let experience = makeExperience(goal: nil, exitPolicy: nil)
                let flow = makeLoadedExperience(
                    handlers: pressHandlers([
                        .requestTracking(RequestTrackingAction())
                    ])
                )
                await primeProfile(experience: experience, package: flow)
                await service.initialize()

                _ = await startJourney()
                mocks.identityService.setDistinctId("user_2")

                await MainActor.run { [controller = controller!] in
                    controller.trackingAuthorizationHandler = UnsupportedTrackingAuthorizationHandler()
                    emitScreenPress(controller)
                }

                await polling(expect {
                    mocks.eventLog.trackForTriggerCalls.last?.distinctIdOverride
                }).value.toEventually(equal(distinctId), timeout: .seconds(2))
            }

            it("tracks unsupported scoped request permission outcomes against the original user across identify races") {
                let experience = makeExperience(goal: nil, exitPolicy: nil)
                let flow = makeLoadedExperience(
                    handlers: pressHandlers([
                        .requestPermission(RequestPermissionAction(permissionType: "camera"))
                    ])
                )
                await primeProfile(experience: experience, package: flow)
                await service.initialize()

                _ = await startJourney()
                mocks.identityService.setDistinctId("user_2")

                await MainActor.run { [controller = controller!] in
                    controller.cameraPermissionAuthorizationHandler = UnsupportedRequestPermissionAuthorizationHandler()
                    emitScreenPress(controller)
                }

                await polling(expect {
                    mocks.eventLog.trackForTriggerCalls.last?.distinctIdOverride
                }).value.toEventually(equal(distinctId), timeout: .seconds(2))
            }

            it("resumes wait_until work on scoped notification outcomes") {
                let experience = makeExperience(goal: nil, exitPolicy: nil)
                let flow = makeLoadedExperience()
                await primeProfile(experience: experience, package: flow)
                await service.initialize()

                let journey = await startJourney()
                await journey.update { $0.executionState.pendingAction = JourneyPendingAction(
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
                ) }

                await MainActor.run { [controller = controller!] in
                    (controller.runtimeDelegate as? NotificationPermissionEventReceiver)?.experienceViewController(
                        controller,
                        didResolveNotificationPermissionEvent: SystemEventNames.notificationsEnabled,
                        properties: ["journey_id": journey.id],
                        journeyId: journey.id
                    )
                }

                await polling(expect {
                    journeyStore.getCompletions(for: distinctId).last?.exitReason
                }).value.toEventually(equal(.completed), timeout: .seconds(2))
            }

            it("resumes wait_until work on scoped tracking outcomes") {
                let experience = makeExperience(goal: nil, exitPolicy: nil)
                let flow = makeLoadedExperience()
                await primeProfile(experience: experience, package: flow)
                await service.initialize()

                let journey = await startJourney()
                await journey.update { $0.executionState.pendingAction = JourneyPendingAction(
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
                ) }

                await MainActor.run { [controller = controller!] in
                    (controller.runtimeDelegate as? TrackingPermissionEventReceiver)?.experienceViewController(
                        controller,
                        didResolveTrackingPermissionEvent: SystemEventNames.trackingAuthorized,
                        properties: ["journey_id": journey.id],
                        journeyId: journey.id
                    )
                }

                await polling(expect {
                    journeyStore.getCompletions(for: distinctId).last?.exitReason
                }).value.toEventually(equal(.completed), timeout: .seconds(2))
            }

            it("resumes wait_until work on scoped request permission outcomes") {
                let experience = makeExperience(goal: nil, exitPolicy: nil)
                let flow = makeLoadedExperience()
                await primeProfile(experience: experience, package: flow)
                await service.initialize()

                let journey = await startJourney()
                await journey.update { $0.executionState.pendingAction = JourneyPendingAction(
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
                ) }

                await MainActor.run { [controller = controller!] in
                    (controller.runtimeDelegate as? RequestPermissionEventReceiver)?.experienceViewController(
                        controller,
                        didResolveRequestPermissionEvent: SystemEventNames.permissionGranted,
                        properties: [
                            "journey_id": journey.id,
                            "type": "camera"
                        ],
                        journeyId: journey.id
                    )
                }

                await polling(expect {
                    journeyStore.getCompletions(for: distinctId).last?.exitReason
                }).value.toEventually(equal(.completed), timeout: .seconds(2))
            }

            it("resumes wait_until work on unsupported request permission kinds") {
                let experience = makeExperience(goal: nil, exitPolicy: nil)
                let flow = makeLoadedExperience()
                await primeProfile(experience: experience, package: flow)
                await service.initialize()

                let journey = await startJourney()
                await journey.update { $0.executionState.pendingAction = JourneyPendingAction(
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
                ) }

                await MainActor.run { [controller = controller!] in
                    (controller.runtimeDelegate as? RequestPermissionEventReceiver)?.experienceViewController(
                        controller,
                        didIgnoreUnsupportedRequestPermissionType: "location_always",
                        journeyId: journey.id
                    )
                }

                await polling(expect {
                    journeyStore.getCompletions(for: distinctId).last?.exitReason
                }).value.toEventually(equal(.completed), timeout: .seconds(2))
            }

            it("honors gate plans from unsupported scoped request permission outcomes") {
                let orderingPresentationService = OrderingExperiencePresentationService(recorder: OrderingRecorder())
                orderingPresentationService.defaultMockViewController = controller
                service = mocks.makeJourneyService(
                    journeyStore: journeyStore,
                    experiencePresentation: orderingPresentationService
                )

                let experience = makeExperience(goal: nil, exitPolicy: nil)
                let flow = makeLoadedExperience()
                await primeProfile(experience: experience, package: flow)
                await service.initialize()

                let journey = await startJourney()
                mocks.eventLog.trackWithResponseResult = makeGatePlanResponse(
                    decision: "show_flow",
                    flowId: "gate-flow"
                )

                await MainActor.run { [controller = controller!] in
                    (controller.runtimeDelegate as? RequestPermissionEventReceiver)?.experienceViewController(
                        controller,
                        didIgnoreUnsupportedRequestPermissionType: "location_always",
                        journeyId: journey.id
                    )
                }

                await polling(expect {
                    await MainActor.run {
                        orderingPresentationService.wasExperiencePresented("gate-flow")
                    }
                }).value.toEventually(beTrue(), timeout: .seconds(2))
            }

            it("honors gate plans from scoped goal actions") {
                let orderingPresentationService = OrderingExperiencePresentationService(recorder: OrderingRecorder())
                orderingPresentationService.defaultMockViewController = controller
                service = mocks.makeJourneyService(
                    journeyStore: journeyStore,
                    experiencePresentation: orderingPresentationService
                )

                let experience = makeExperience(goal: nil, exitPolicy: nil)
                let flow = makeLoadedExperience()
                await primeProfile(experience: experience, package: flow)
                await service.initialize()

                let journey = await startJourney()
                mocks.eventLog.trackWithResponseResult = makeGatePlanResponse(
                    decision: "show_flow",
                    flowId: "gate-flow"
                )

                await service.handleScopedMilestoneEvent(
                    journeyId: journey.id,
                    milestoneId: "signup_complete",
                    milestoneLabel: "Signed Up",
                    screenId: "screen-1"
                )

                await polling(expect {
                    await MainActor.run {
                        orderingPresentationService.wasExperiencePresented("gate-flow")
                    }
                }).value.toEventually(beTrue(), timeout: .seconds(2))
            }

            it("closes the source journey before presenting goal gate-plan flows") {
                let ordering = OrderingRecorder()
                let orderingStore = OrderingJourneyStore(recorder: ordering)
                let orderingPresentationService = OrderingExperiencePresentationService(recorder: ordering)
                orderingPresentationService.defaultMockViewController = controller
                service = mocks.makeJourneyService(
                    journeyStore: orderingStore,
                    experiencePresentation: orderingPresentationService
                )
                journeyStore = orderingStore

                let experience = makeExperience(goal: nil, exitPolicy: nil)
                let flow = makeLoadedExperience()
                await primeProfile(experience: experience, package: flow)
                await service.initialize()

                let journey = await startJourney()
                mocks.eventLog.trackWithResponseResult = makeGatePlanResponse(
                    decision: "show_flow",
                    flowId: "gate-flow"
                )

                ordering.clear()

                await service.handleScopedMilestoneEvent(
                    journeyId: journey.id,
                    milestoneId: "signup_complete",
                    milestoneLabel: "Signed Up",
                    screenId: "screen-1"
                )

                await polling(expect {
                    ordering.events
                }).value.toEventually(equal(["complete:\(experienceId)", "present:gate-flow"]), timeout: .seconds(2))
                await polling(expect {
                    await service.getActiveJourneys(for: distinctId).isEmpty
                }).value.toEventually(beTrue(), timeout: .seconds(2))
            }

            it("resumes wait_until work before scoped notification tracking returns") {
                let experience = makeExperience(goal: nil, exitPolicy: nil)
                let flow = makeLoadedExperience()
                await primeProfile(experience: experience, package: flow)
                await service.initialize()

                let journey = await startJourney()
                await journey.update { $0.executionState.pendingAction = JourneyPendingAction(
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
                ) }
                mocks.eventLog.trackForTriggerDelayNanoseconds = 750_000_000

                await MainActor.run { [controller = controller!] in
                    (controller.runtimeDelegate as? NotificationPermissionEventReceiver)?.experienceViewController(
                        controller,
                        didResolveNotificationPermissionEvent: SystemEventNames.notificationsEnabled,
                        properties: ["journey_id": journey.id],
                        journeyId: journey.id
                    )
                }

                await polling(expect {
                    journeyStore.getCompletions(for: distinctId).last?.exitReason
                }).value.toEventually(equal(.completed), timeout: .milliseconds(250))

                try? await Task.sleep(nanoseconds: 800_000_000)
            }

            it("uses enriched scoped notification properties during immediate local goal evaluation") {
                let sessionService = MockSessionService()
                sessionService.setSessionId("session-notification")
                mocks.eventLog.sessions = sessionService

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
                let experience = makeExperience(
                    id: "camp-session-filter",
                    flowId: "flow-session-filter",
                    goal: notificationGoal,
                    exitPolicy: nil
                )

                await primeProfile(
                    experiences: [experience],
                    packages: [makeLoadedExperience(flowId: "flow-session-filter")]
                )
                await service.initialize()

                let journey = await startJourney()
                // The delayed track is the discriminator: conversion must land
                // from the IMMEDIATE local goal evaluation (enriched
                // properties), well before the delayed track's evaluation
                // could. 2s delay vs 750ms window keeps that discrimination
                // with scheduling slack (Swift 6 executors made 250ms flaky).
                mocks.eventLog.trackForTriggerDelayNanoseconds = 2_000_000_000

                await MainActor.run { [controller = controller!] in
                    (controller.runtimeDelegate as? NotificationPermissionEventReceiver)?.experienceViewController(
                        controller,
                        didResolveNotificationPermissionEvent: SystemEventNames.notificationsEnabled,
                        properties: ["journey_id": journey.id],
                        journeyId: journey.id
                    )
                }

                await polling(expect {
                    let matchingJourney = await service.getActiveJourneys(for: distinctId).first {
                        $0.id == journey.id
                    }
                    return await convertedAt(of: matchingJourney)
                }).value.toEventuallyNot(beNil(), timeout: .milliseconds(750))

                try? await Task.sleep(nanoseconds: 2_100_000_000)
            }

            it("feeds scoped notification outcomes into all active journeys for goal evaluation") {
                let notificationGoal = GoalConfig(
                    kind: .event,
                    eventName: SystemEventNames.notificationsEnabled,
                    eventFilter: nil,
                    window: 60
                )
                let primaryExperience = makeExperience(
                    id: "camp-primary",
                    flowId: "flow-primary",
                    goal: nil,
                    exitPolicy: nil
                )
                let secondaryExperience = makeExperience(
                    id: "camp-secondary",
                    flowId: "flow-secondary",
                    goal: notificationGoal,
                    exitPolicy: nil
                )

                await primeProfile(
                    experiences: [primaryExperience, secondaryExperience],
                    packages: [
                        makeLoadedExperience(flowId: "flow-primary"),
                        makeLoadedExperience(flowId: "flow-secondary"),
                    ]
                )
                await service.initialize()

                _ = await service.handleEventForTrigger(
                    NuxieEvent(id: "evt_origin", name: "paywall_trigger", distinctId: distinctId)
                )

                let activeJourneys = await service.getActiveJourneys(for: distinctId)
                let primaryJourney = activeJourneys.first(where: { $0.experienceId == "camp-primary" })
                let secondaryJourney = activeJourneys.first(where: { $0.experienceId == "camp-secondary" })
                expect(primaryJourney).toNot(beNil())
                let secondaryConvertedAt = await convertedAt(of: secondaryJourney)
                expect(secondaryConvertedAt).to(beNil())

                await MainActor.run { [controller = controller!] in
                    (controller.runtimeDelegate as? NotificationPermissionEventReceiver)?.experienceViewController(
                        controller,
                        didResolveNotificationPermissionEvent: SystemEventNames.notificationsEnabled,
                        properties: ["journey_id": primaryJourney!.id],
                        journeyId: primaryJourney!.id
                    )
                }

                await polling(expect {
                    let matchingJourney = await service.getActiveJourneys(for: distinctId).first {
                        $0.experienceId == "camp-secondary"
                    }
                    return await convertedAt(of: matchingJourney)
                }).value.toEventuallyNot(beNil(), timeout: .seconds(2))
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
                let experience = makeExperience(
                    id: "camp-mixed",
                    flowId: "flow-mixed",
                    goal: notificationGoal,
                    exitPolicy: nil
                )

                await primeProfile(
                    experiences: [experience],
                    packages: [makeLoadedExperience(flowId: "flow-mixed")]
                )
                await service.initialize()
                mocks.identityService.setUserProperty("plan", value: "pro")

                let journey = await startJourney()
                let initialConvertedAt = await convertedAt(of: journey)
                expect(initialConvertedAt).to(beNil())

                await MainActor.run { [controller = controller!] in
                    (controller.runtimeDelegate as? NotificationPermissionEventReceiver)?.experienceViewController(
                        controller,
                        didResolveNotificationPermissionEvent: SystemEventNames.notificationsEnabled,
                        properties: ["journey_id": journey.id],
                        journeyId: journey.id
                    )
                }

                await polling(expect {
                    let matchingJourney = await service.getActiveJourneys(for: distinctId).first {
                        $0.id == journey.id
                    }
                    return await convertedAt(of: matchingJourney)
                }).value.toEventuallyNot(beNil(), timeout: .seconds(2))
            }

            it("processes active journeys before presenting scoped gate flows") {
                let ordering = OrderingRecorder()
                let orderingStore = OrderingJourneyStore(recorder: ordering)
                let orderingPresentationService = OrderingExperiencePresentationService(recorder: ordering)
                orderingPresentationService.defaultMockViewController = controller
                service = mocks.makeJourneyService(
                    journeyStore: orderingStore,
                    experiencePresentation: orderingPresentationService
                )
                journeyStore = orderingStore

                let experience = makeExperience(goal: nil, exitPolicy: nil)
                let flow = makeLoadedExperience()

                await primeProfile(experience: experience, package: flow)
                await service.initialize()

                let journey = await startJourney()
                await journey.update { $0.executionState.pendingAction = JourneyPendingAction(
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
                ) }
                mocks.eventLog.trackWithResponseResult = makeGatePlanResponse(
                    decision: "show_flow",
                    flowId: "gate-flow"
                )

                ordering.clear()

                await MainActor.run { [controller = controller!] in
                    (controller.runtimeDelegate as? NotificationPermissionEventReceiver)?.experienceViewController(
                        controller,
                        didResolveNotificationPermissionEvent: SystemEventNames.notificationsEnabled,
                        properties: ["journey_id": journey.id],
                        journeyId: journey.id
                    )
                }

                await polling(expect {
                    ordering.events
                }).value.toEventually(equal(["complete:\(experienceId)", "present:gate-flow"]), timeout: .seconds(2))
            }

            it("does not present scoped require_feature cache-only flows on deny") {
                let orderingPresentationService = OrderingExperiencePresentationService(recorder: OrderingRecorder())
                orderingPresentationService.defaultMockViewController = controller
                service = mocks.makeJourneyService(
                    journeyStore: journeyStore,
                    experiencePresentation: orderingPresentationService
                )

                let experience = makeExperience(goal: nil, exitPolicy: nil)
                let flow = makeLoadedExperience()
                await primeProfile(experience: experience, package: flow)
                await service.initialize()

                let journey = await startJourney()
                let baselinePresentations = orderingPresentationService.presentExperienceCallCount
                mocks.eventLog.trackWithResponseResult = makeGatePlanResponse(
                    decision: "require_feature",
                    flowId: "gate-flow",
                    featureId: "premium",
                    policy: "cache_only"
                )

                await MainActor.run { [controller = controller!] in
                    (controller.runtimeDelegate as? NotificationPermissionEventReceiver)?.experienceViewController(
                        controller,
                        didResolveNotificationPermissionEvent: SystemEventNames.notificationsEnabled,
                        properties: ["journey_id": journey.id],
                        journeyId: journey.id
                    )
                }

                await polling(expect {
                    orderingPresentationService.presentExperienceCallCount
                }).value.toEventually(equal(baselinePresentations), timeout: .seconds(2))
                expect(orderingPresentationService.wasExperiencePresented("gate-flow")).to(beFalse())
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


// File-scope helpers (not local functions) so @Sendable closures can call
// them without capturing; MainActor-isolated because they drive the
// MainActor-isolated ExperienceRuntimeDelegate.
@MainActor
private func emitScreenPress(_ controller: ExperienceViewController) {
    controller.runtimeDelegate?.experienceViewController(
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

@MainActor
private func emitRendererEvent(_ controller: ExperienceViewController, name: String) {
    controller.runtimeDelegate?.experienceViewController(
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

@MainActor
private func emitTaggedRendererEvent(_ controller: ExperienceViewController, name: String) {
    controller.runtimeDelegate?.experienceViewController(
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
