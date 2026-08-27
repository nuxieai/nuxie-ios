import Foundation
import Nimble
import Quick

@_spi(Testing) @testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

private actor FlowShownBeforeJourneyDecisionService: JourneyServiceProtocol {
    func registerDetachedPresentationOwner(distinctId: String) async {}

    private let broker: TriggerBrokerProtocol
    private let journey: Journey
    private let finalUpdate: JourneyUpdate

    init(broker: TriggerBrokerProtocol, journey: Journey, finalUpdate: JourneyUpdate) {
        self.broker = broker
        self.journey = journey
        self.finalUpdate = finalUpdate
    }

    func startJourney(for experience: Experience, distinctId: String, originEventId: String?) async -> Journey? {
        nil
    }

    func resumeJourney(_ journey: Journey) async {}


    func handleEvent(_ event: NuxieEvent) async {}

    func handleEventForTrigger(_ event: NuxieEvent) async -> [JourneyTriggerResult] {
        let ref = ExperienceRef(
            experienceId: journey.experienceId,
            experienceVersion: journey.experienceVersion,
            journeyId: journey.id
        )
        await broker.emit(eventId: event.id, update: .decision(.experienceShown(ref)))

        try? await Task.sleep(nanoseconds: 20_000_000)

        let broker = self.broker
        let finalUpdate = self.finalUpdate
        let eventId = event.id
        Task {
            try? await Task.sleep(nanoseconds: 20_000_000)
            await broker.emit(eventId: eventId, update: .journey(finalUpdate))
        }

        return [.started(journey)]
    }

    func handleSegmentChange(distinctId: String, segments: Set<String>) async {}

    func getActiveJourneys(for distinctId: String) async -> [Journey] {
        []
    }

    func checkExpiredTimers() async {}

    func initialize() async {}

    func onAppWillEnterForeground() async {}

    func onAppBecameActive() async {}

    func onAppDidEnterBackground() async {}

    func shutdown() async {}

    func handleUserChange(from oldDistinctId: String, to newDistinctId: String) async {}
}

final class TriggerServiceTests: AsyncSpec {
    override class func spec() {
        var mockEventLog: MockEventLog!
        var mockJourneyService: MockJourneyService!
        var mockFlowPresentationService: MockExperiencePresentationService!
        var mockSleepProvider: MockSleepProvider!
        var mockDateProvider: MockDateProvider!
        var mockFeatureApi: MockNuxieApi!
        var featureInfo: FeatureInfo!
        var featureService: FeatureService!
        var triggerBroker: TriggerBroker!
        var triggerService: TriggerServiceProtocol!
        var presentationTrace: InMemoryExperiencePresentationTrace!

        beforeEach {
            mockEventLog = MockEventLog()
            mockJourneyService = MockJourneyService()
            mockFlowPresentationService = MockExperiencePresentationService()
            mockSleepProvider = MockSleepProvider()
            mockSleepProvider.shouldCompleteImmediately = true
            mockDateProvider = MockDateProvider()
            mockFeatureApi = MockNuxieApi()
            featureInfo = FeatureInfo()
            featureService = FeatureService(
                api: mockFeatureApi,
                identity: MockIdentityService(),
                profile: MockProfileService(),
                dateProvider: mockDateProvider,
                featureInfo: featureInfo,
                cacheTTL: NuxieInternalConfiguration().featureCacheTTL
            )
            triggerBroker = TriggerBroker()
            presentationTrace = InMemoryExperiencePresentationTrace()

            triggerService = TriggerService(
                eventLog: mockEventLog,
                journeys: mockJourneyService,
                features: featureService,
                experiencePresentation: mockFlowPresentationService,
                featureInfo: featureInfo,
                triggerBroker: triggerBroker,
                sleepProvider: mockSleepProvider,
                dateProvider: mockDateProvider,
                presentationTrace: presentationTrace
            )
        }

        describe("trigger") {
            it("keeps cold captured-event recovery pending until Journey routing is available") {
                await mockJourneyService.setCapturedEventRoutingAvailable(false)

                let coldAttempt = await triggerService.captureSystemEvent(
                    "$purchase_completed",
                    properties: ["transaction_id": "transaction-1"],
                    eventId: "purchase-completed:transaction-1",
                    distinctId: "customer-a"
                )

                expect(coldAttempt).to(beFalse())

                await mockJourneyService.setCapturedEventRoutingAvailable(true)
                let recoveredAttempt = await triggerService.captureSystemEvent(
                    "$purchase_completed",
                    properties: ["transaction_id": "transaction-1"],
                    eventId: "purchase-completed:transaction-1",
                    distinctId: "customer-a"
                )

                expect(recoveredAttempt).to(beTrue())
            }

            it("emits allowedImmediate for allow gate plan") {
                let payload: [String: AnyCodable] = [
                    "gate": AnyCodable([
                        "decision": "allow"
                    ])
                ]
                mockEventLog.trackWithResponseResult = EventResponse(
                    status: "ok",
                    payload: payload,
                    customer: nil,
                    eventId: "event-1",
                    message: nil,
                    featuresMatched: nil,
                    usage: nil,
                    journey: nil,
                )

                let updates = TriggerUpdateRecorder()

                await triggerService.trigger("test_event") { update in
                    updates.append(update)
                }

                expect(updates.values).to(contain(.decision(.allowedImmediate)))
            }

            it("emits noMatch when gate plan is missing and no journeys start") {
                mockEventLog.trackWithResponseResult = .success()

                let updates = TriggerUpdateRecorder()

                await triggerService.trigger("test_event") { update in
                    updates.append(update)
                }

                expect(updates.values).to(contain(.decision(.noMatch)))
            }

            it("converts an internal routing failure to TriggerError") {
                mockEventLog.trackWithResponseError = EventRoutingError.eventRoutingFailed
                let updates = TriggerUpdateRecorder()

                await triggerService.trigger("test_event") { update in
                    updates.append(update)
                }

                let failure = updates.values.compactMap { update -> TriggerError? in
                    guard case .error(let error) = update else { return nil }
                    return error
                }.first
                expect(failure?.code).to(equal(.triggerFailed))
                expect(failure?.message).to(equal("Event routing failed"))
            }

            it("treats a beforeSend drop as a terminal no-match") {
                mockEventLog.trackWithResponseError = EventBeforeSendDropError()
                let updates = TriggerUpdateRecorder()

                await triggerService.trigger("$app_opened") { update in
                    updates.append(update)
                }

                expect(updates.values).to(contain(.decision(.noMatch)))
                expect(updates.values.contains { update in
                    if case .error = update { return true }
                    return false
                }).to(beFalse())
            }

            it("reports a typed experienceMissing error when show_flow has no experience") {
                mockEventLog.trackWithResponseResult = EventResponse(
                    status: "ok",
                    payload: ["gate": AnyCodable(["decision": "show_flow"])],
                    customer: nil,
                    eventId: "event-missing-experience",
                    message: nil,
                    featuresMatched: nil,
                    usage: nil,
                    journey: nil
                )
                let updates = TriggerUpdateRecorder()

                await triggerService.trigger("test_event") { updates.append($0) }

                expect(updates.errorCodes).to(contain(.experienceMissing))
            }

            it("reports a typed featureMissing error when require_feature has no feature") {
                mockEventLog.trackWithResponseResult = EventResponse(
                    status: "ok",
                    payload: ["gate": AnyCodable(["decision": "require_feature"])],
                    customer: nil,
                    eventId: "event-missing-feature",
                    message: nil,
                    featuresMatched: nil,
                    usage: nil,
                    journey: nil
                )
                let updates = TriggerUpdateRecorder()

                await triggerService.trigger("test_event") { updates.append($0) }

                expect(updates.errorCodes).to(contain(.featureMissing))
            }

            it("reports featureAccessTimeout after pending access does not arrive") {
                await mockFeatureApi.setCheckFeatureResponse(FeatureCheckResult(
                    customerId: "customer",
                    featureId: "pro",
                    requiredBalance: 1,
                    code: "denied",
                    allowed: false,
                    unlimited: false,
                    balance: 0,
                    type: .boolean,
                    preview: nil
                ))
                mockEventLog.trackWithResponseResult = EventResponse(
                    status: "ok",
                    payload: [
                        "gate": AnyCodable([
                            "decision": "require_feature",
                            "featureId": "pro",
                            "policy": "hard",
                            "timeoutMs": 1
                        ])
                    ],
                    customer: nil,
                    eventId: "event-feature-timeout",
                    message: nil,
                    featuresMatched: nil,
                    usage: nil,
                    journey: nil
                )
                let updates = TriggerUpdateRecorder()

                await triggerService.trigger("test_event") { updates.append($0) }

                expect(updates.values).to(contain(.featureAccess(.pending)))
                expect(updates.errorCodes).to(contain(.featureAccessTimeout))
            }

            it("reports triggerFailed when event tracking throws") {
                mockEventLog.trackWithResponseError = NSError(
                    domain: "TriggerServiceTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "tracking failed"]
                )
                let updates = TriggerUpdateRecorder()

                await triggerService.trigger("test_event") { updates.append($0) }

                expect(updates.errorCodes).to(contain(.triggerFailed))
            }

            it("reports journey start failures as terminal trigger errors") {
                await mockJourneyService.setTriggerResults([
                    .suppressed(.alreadyActive),
                    .error(TriggerError(code: .triggerFailed, message: "start failed")),
                    .suppressed(.reentryLimited)
                ])
                mockEventLog.trackWithResponseResult = EventResponse(
                    status: "ok",
                    payload: nil,
                    customer: nil,
                    eventId: "event-start-failed",
                    message: nil,
                    featuresMatched: nil,
                    usage: nil,
                    journey: nil
                )
                let updates = TriggerUpdateRecorder()

                await triggerService.trigger("test_event") { updates.append($0) }

                expect(updates.errorCodes).to(contain(.triggerFailed))
                expect(updates.values).toNot(contain(.decision(.allowedImmediate)))
                expect(updates.values).toNot(contain(.decision(.noMatch)))
                expect(updates.values).to(contain(.decision(.suppressed(.alreadyActive))))
                expect(updates.values).toNot(contain(.decision(.suppressed(.reentryLimited))))
            }

            it("does not emit a journey after a terminal start error") {
                let laterJourney = TestJourneyBuilder().build()
                await mockJourneyService.setTriggerResults([
                    .error(TriggerError(code: .triggerFailed, message: "start failed")),
                    .started(laterJourney)
                ])
                mockEventLog.trackWithResponseResult = EventResponse(
                    status: "ok",
                    payload: ["gate": AnyCodable(["decision": "allow"])],
                    customer: nil,
                    eventId: "event-start-failed-before-journey",
                    message: nil,
                    featuresMatched: nil,
                    usage: nil,
                    journey: nil
                )
                let updates = TriggerUpdateRecorder()

                await triggerService.trigger("test_event") { updates.append($0) }

                let emittedLaterJourney = updates.values.contains { update in
                    guard case .decision(.journeyStarted(let ref)) = update else { return false }
                    return ref.journeyId == laterJourney.id
                }
                expect(updates.errorCodes).to(contain(.triggerFailed))
                expect(emittedLaterJourney).to(beFalse())
                expect(updates.values).toNot(contain(.decision(.allowedImmediate)))
            }

            it("emits journeyStarted when a journey starts") {
                let journey = TestJourneyBuilder().build()
                await mockJourneyService.setTriggerResults([.started(journey)])
                mockEventLog.trackWithResponseResult = .success()

                let updates = TriggerUpdateRecorder()

                await triggerService.trigger("test_event") { update in
                    updates.append(update)
                }

                let expectedRef = ExperienceRef(
                    experienceId: journey.experienceId,
                    experienceVersion: journey.experienceVersion,
                    journeyId: journey.id
                )
                expect(updates.values).to(contain(.decision(.journeyStarted(expectedRef))))
            }

            it("keeps the broker alive when a journey experienceShown arrives before journeyStarted") {
                let journey = TestJourneyBuilder().build()
                let expectedRef = ExperienceRef(
                    experienceId: journey.experienceId,
                    experienceVersion: journey.experienceVersion,
                    journeyId: journey.id
                )
                let finalUpdate = JourneyUpdate(
                    journeyId: journey.id,
                    experienceId: journey.experienceId,
                    experienceVersion: journey.experienceVersion,
                    exitReason: .completed,
                    goalMet: false
                )
                let broker = triggerBroker!
                let journeyService = FlowShownBeforeJourneyDecisionService(
                    broker: broker,
                    journey: journey,
                    finalUpdate: finalUpdate
                )
                triggerService = TriggerService(
                    eventLog: mockEventLog,
                    journeys: journeyService,
                    features: featureService,
                    experiencePresentation: mockFlowPresentationService,
                    featureInfo: featureInfo,
                    triggerBroker: broker,
                    sleepProvider: mockSleepProvider,
                    dateProvider: mockDateProvider
                )
                mockEventLog.trackWithResponseResult = .success()

                let updates = TriggerUpdateRecorder()

                await triggerService.trigger("test_event") { update in
                    updates.append(update)
                }

                await expect { updates.values }
                    .toEventually(contain(.journey(finalUpdate)), timeout: .seconds(2))
                expect(updates.values).to(contain(.decision(.experienceShown(expectedRef))))
                expect(updates.values).to(contain(.decision(.journeyStarted(expectedRef))))
                expect(updates.values).to(contain(.journey(finalUpdate)))
            }

            it("keeps the broker alive for mixed journey start and suppression results") {
                let journey = TestJourneyBuilder().build()
                await mockJourneyService.setTriggerResults([
                    .started(journey),
                    .suppressed(.alreadyActive)
                ])
                mockEventLog.trackWithResponseResult = EventResponse(
                    status: "ok",
                    payload: nil,
                    customer: nil,
                    eventId: "event-mixed",
                    message: nil,
                    featuresMatched: nil,
                    usage: nil,
                    journey: nil,
                )

                let finalUpdate = JourneyUpdate(
                    journeyId: journey.id,
                    experienceId: journey.experienceId,
                    experienceVersion: journey.experienceVersion,
                    exitReason: .completed,
                    goalMet: false
                )
                let updates = TriggerUpdateRecorder()

                await triggerService.trigger("test_event") { update in
                    updates.append(update)
                }

                let eventId = await mockJourneyService.lastHandledEvent?.id
                expect(eventId).toNot(beNil())
                if let eventId {
                    await triggerBroker.emit(eventId: eventId, update: .journey(finalUpdate))
                }

                expect(updates.values).to(contain(.decision(.suppressed(.alreadyActive))))
                expect(updates.values).to(contain(.journey(finalUpdate)))
            }

            it("continues show_flow gate plans after local journey suppression") {
                await mockJourneyService.setTriggerResults([.suppressed(.alreadyActive)])
                let presentedExperience = Experience(
                    id: "stable-server-experience",
                    versionId: "published-server-version",
                    name: "Server Experience",
                    reentry: .everyTime,
                    publishedAt: "2026-08-23T00:00:00Z",
                    trigger: nil,
                    goal: nil,
                    exitPolicy: nil,
                    conversionAnchor: nil,
                    experienceType: nil
                )
                let presentedController = await MainActor.run {
                    MockExperienceViewController(
                        mockExperienceVersionId: presentedExperience.versionId,
                        mockExperience: presentedExperience
                    )
                }
                mockFlowPresentationService.mockViewControllers["server-flow"] = presentedController
                mockEventLog.trackWithResponseResult = EventResponse(
                    status: "ok",
                    payload: [
                        "gate": AnyCodable([
                            "decision": "show_flow",
                            "flowId": "server-flow"
                        ])
                    ],
                    customer: nil,
                    eventId: "event-flow",
                    message: nil,
                    featuresMatched: nil,
                    usage: nil,
                    journey: nil,
                )

                let updates = TriggerUpdateRecorder()

                await triggerService.trigger("test_event") { update in
                    updates.append(update)
                }

                expect(updates.values).to(contain(.decision(.suppressed(.alreadyActive))))
                expect(mockFlowPresentationService.presentExperienceCallCount).to(equal(1))
                expect(mockFlowPresentationService.lastPresentedExperienceVersionId).to(equal("server-flow"))
                let showedServerFlow = updates.values.contains { update in
                    guard case .decision(.experienceShown(let ref)) = update else { return false }
                    return ref.experienceId == "stable-server-experience"
                        && ref.experienceVersion == "published-server-version"
                        && ref.journeyId == nil
                }
                expect(showedServerFlow).to(beTrue())
            }

            it("carries one presentation attempt through tracking and direct presentation") {
                await mockJourneyService.setTriggerResults([.suppressed(.alreadyActive)])
                mockEventLog.trackWithResponseResult = EventResponse(
                    status: "ok",
                    payload: [
                        "gate": AnyCodable([
                            "decision": "show_flow",
                            "flowId": "server-flow"
                        ])
                    ],
                    customer: nil,
                    eventId: "event-flow",
                    message: nil,
                    featuresMatched: nil,
                    usage: nil,
                    journey: nil
                )
                let attempt = ExperiencePresentationAttempt(
                    id: "attempt-direct",
                    triggerEvent: "upgrade_tapped",
                    startedAt: Date(timeIntervalSince1970: 1)
                )

                let tracedTriggerService = triggerService as! any PresentationAttemptTriggerServiceProtocol
                await tracedTriggerService.trigger(
                    "upgrade_tapped",
                    properties: nil,
                    presentationAttempt: attempt
                ) { _ in }

                let events = presentationTrace.events(for: attempt.id)
                let trackedEventId = await mockJourneyService.lastHandledEvent?.id
                expect(events.map(\.attempt.id)).to(
                    equal(Array(repeating: attempt.id, count: events.count))
                )
                expect(trackedEventId).toNot(beNil())
                expect(events.map(\.stage)).to(contain(
                    .eventTracked(eventId: trackedEventId ?? "missing"),
                    .presentationRequested(
                        experienceVersionId: "server-flow",
                        route: .direct
                    )
                ))
            }

            it("traces the direct presentation through reveal, first drawable, first input, and completion") {
                mockEventLog.trackWithResponseResult = EventResponse(
                    status: "ok",
                    payload: [
                        "gate": AnyCodable([
                            "decision": "show_flow",
                            "flowId": "server-flow"
                        ])
                    ],
                    customer: nil,
                    eventId: "event-flow",
                    message: nil,
                    featuresMatched: nil,
                    usage: nil,
                    journey: nil
                )
                let attempt = ExperiencePresentationAttempt(
                    id: "attempt-direct-lifecycle",
                    triggerEvent: "upgrade_tapped",
                    startedAt: Date(timeIntervalSince1970: 1),
                    startedAtMonotonicTime: 1
                )

                let tracedTriggerService = triggerService as! any PresentationAttemptTriggerServiceProtocol
                await tracedTriggerService.trigger(
                    "upgrade_tapped",
                    properties: nil,
                    presentationAttempt: attempt
                ) { _ in }

                let controller = await MainActor.run {
                    MockExperienceViewController(mockExperienceVersionId: "server-flow")
                }
                let presentedTime = ExperiencePresentationTimestamp.monotonicNow()
                let drawable = ExperienceRuntimePresentedDrawable(
                    presentedTime: presentedTime,
                    pixelWidth: 20,
                    pixelHeight: 30,
                    drawCalls: 4,
                    provenance: .injectedTestObserver
                )
                let delegate = mockFlowPresentationService.currentRuntimeDelegate
                expect(delegate).toNot(beNil())

                await MainActor.run {
                    delegate?.experienceViewControllerDidBecomeReady(controller)
                    delegate?.experienceViewControllerDidBecomeReady(controller)
                    delegate?.experienceViewControllerDidPresentShell(controller)
                    delegate?.experienceViewControllerDidReveal(controller)
                    delegate?.experienceViewController(
                        controller,
                        didPresentDrawable: drawable,
                        screenId: "entry",
                        frameNumber: 7
                    )
                    delegate?.experienceViewController(
                        controller,
                        didPresentDrawable: drawable,
                        screenId: "entry",
                        frameNumber: 8
                    )
                    delegate?.experienceViewController(
                        controller,
                        didAcceptPointerInput: ExperienceRuntimeAcceptedPointerInput(eventCount: 2),
                        screenId: "entry"
                    )
                    delegate?.experienceViewControllerDidFinishPresentation(controller)
                }

                let events = presentationTrace.events(for: attempt.id)
                expect(events.map(\.stage)).to(contain(
                    .runtimeReady,
                    .shellPresented,
                    .revealed,
                    .firstPresentedDrawable(
                        screenId: "entry",
                        frameNumber: 7,
                        pixels: 600,
                        drawCalls: 4,
                        provenance: .injectedTestObserver
                    ),
                    .firstAcceptedInput(screenId: "entry", eventCount: 2),
                    .presentationCleanupCompleted
                ))
                expect(events.filter { stageEvent in
                    if case .firstPresentedDrawable = stageEvent.stage { return true }
                    return false
                }).to(haveCount(1))
                expect(events.first { stageEvent in
                    if case .firstPresentedDrawable = stageEvent.stage { return true }
                    return false
                }?.monotonicTime).to(equal(presentedTime))
            }

            it("records a terminal direct presentation failure on the same attempt") {
                mockEventLog.trackWithResponseResult = EventResponse(
                    status: "ok",
                    payload: [
                        "gate": AnyCodable([
                            "decision": "show_flow",
                            "flowId": "server-flow"
                        ])
                    ],
                    customer: nil,
                    eventId: "event-flow",
                    message: nil,
                    featuresMatched: nil,
                    usage: nil,
                    journey: nil
                )
                mockFlowPresentationService.shouldFailPresentation = true
                mockFlowPresentationService.presentationError =
                    ExperiencePresentationError.noActiveScene
                let attempt = ExperiencePresentationAttempt(
                    id: "attempt-direct-failure",
                    triggerEvent: "upgrade_tapped",
                    startedAt: Date(timeIntervalSince1970: 1)
                )
                let updates = TriggerUpdateRecorder()

                let traced = triggerService as! any PresentationAttemptTriggerServiceProtocol
                await traced.trigger(
                    "upgrade_tapped",
                    properties: nil,
                    presentationAttempt: attempt
                ) { updates.append($0) }

                expect(presentationTrace.events(for: attempt.id).map(\.stage))
                    .to(contain(
                        .presentationFailed(
                            route: .direct,
                            errorCode: String(
                                reflecting: ExperiencePresentationError.self
                            )
                        )
                    ))
                expect(updates.errorCodes).to(contain(.experiencePresentFailed))
            }

            it("keeps handling immediate gate plans after a journey starts") {
                let journey = TestJourneyBuilder().build()
                await mockJourneyService.setTriggerResults([.started(journey)])
                mockEventLog.trackWithResponseResult = EventResponse(
                    status: "ok",
                    payload: [
                        "gate": AnyCodable([
                            "decision": "allow"
                        ])
                    ],
                    customer: nil,
                    eventId: "event-allow",
                    message: nil,
                    featuresMatched: nil,
                    usage: nil,
                    journey: nil,
                )

                let updates = TriggerUpdateRecorder()

                await triggerService.trigger("test_event") { update in
                    updates.append(update)
                }

                let expectedRef = ExperienceRef(
                    experienceId: journey.experienceId,
                    experienceVersion: journey.experienceVersion,
                    journeyId: journey.id
                )
                expect(updates.values).to(contain(.decision(.journeyStarted(expectedRef))))
                expect(updates.values).to(contain(.decision(.allowedImmediate)))
            }

            it("keeps handling immediate gate plans after a journey suppression") {
                await mockJourneyService.setTriggerResults([.suppressed(.alreadyActive)])
                mockEventLog.trackWithResponseResult = EventResponse(
                    status: "ok",
                    payload: [
                        "gate": AnyCodable([
                            "decision": "allow"
                        ])
                    ],
                    customer: nil,
                    eventId: "event-allow",
                    message: nil,
                    featuresMatched: nil,
                    usage: nil,
                    journey: nil,
                )

                let updates = TriggerUpdateRecorder()

                await triggerService.trigger("test_event") { update in
                    updates.append(update)
                }

                expect(updates.values).to(contain(.decision(.suppressed(.alreadyActive))))
                expect(updates.values).to(contain(.decision(.allowedImmediate)))
            }

            it("keeps handling require_feature gate plans after a journey starts") {
                let journey = TestJourneyBuilder().build()
                await mockJourneyService.setTriggerResults([.started(journey)])
                mockEventLog.trackWithResponseResult = EventResponse(
                    status: "ok",
                    payload: [
                        "gate": AnyCodable([
                            "decision": "require_feature",
                            "featureId": "pro",
                            "policy": "cache_only"
                        ])
                    ],
                    customer: nil,
                    eventId: "event-feature",
                    message: nil,
                    featuresMatched: nil,
                    usage: nil,
                    journey: nil,
                )

                let info = featureInfo!
                await MainActor.run {
                    info.update([
                        "pro": FeatureAccess.withBalance(1, unlimited: false, type: .metered)
                    ])
                }

                let updates = TriggerUpdateRecorder()

                await triggerService.trigger("test_event") { update in
                    updates.append(update)
                }

                let expectedRef = ExperienceRef(
                    experienceId: journey.experienceId,
                    experienceVersion: journey.experienceVersion,
                    journeyId: journey.id
                )
                expect(updates.values).to(contain(.decision(.journeyStarted(expectedRef))))
                expect(updates.values).to(contain(.featureAccess(.allowed)))
            }

            it("emits feature access allowed for cache_only gate plan with cached access") {
                let payload: [String: AnyCodable] = [
                    "gate": AnyCodable([
                        "decision": "require_feature",
                        "featureId": "pro",
                        "policy": "cache_only"
                    ])
                ]
                mockEventLog.trackWithResponseResult = EventResponse(
                    status: "ok",
                    payload: payload,
                    customer: nil,
                    eventId: "event-2",
                    message: nil,
                    featuresMatched: nil,
                    usage: nil,
                    journey: nil,
                )

                let info = featureInfo!
                await MainActor.run {
                    info.update([
                        "pro": FeatureAccess.withBalance(1, unlimited: false, type: .metered)
                    ])
                }

                let updates = TriggerUpdateRecorder()

                await triggerService.trigger("test_event") { update in
                    updates.append(update)
                }

                expect(updates.values).to(contain(.featureAccess(.allowed)))
            }

            it("allows an exact authoritative opaque cache_only decision") {
                let payload: [String: AnyCodable] = [
                    "gate": AnyCodable([
                        "decision": "require_feature",
                        "featureId": "exports",
                        "requiredBalance": 2,
                        "policy": "cache_only"
                    ])
                ]
                mockEventLog.trackWithResponseResult = EventResponse(
                    status: "ok",
                    payload: payload,
                    customer: nil,
                    eventId: "event-opaque-allow",
                    message: nil,
                    featuresMatched: nil,
                    usage: nil,
                    journey: nil
                )
                await featureService.applyAuthoritativeUse(
                    FeatureCheckResult(
                        customerId: "customer-123",
                        featureId: "credit_wallet",
                        requiredBalance: 2,
                        code: "feature_found",
                        allowed: true,
                        unlimited: false,
                        balance: 8,
                        type: .creditSystem,
                        preview: nil
                    ),
                    requestedFeatureId: "exports",
                    distinctId: "test-user",
                    entityId: nil
                )
                await featureService.syncFeatureInfo()

                let updates = TriggerUpdateRecorder()
                await triggerService.trigger("test_event") { updates.append($0) }

                expect(updates.values).to(contain(.featureAccess(.allowed)))
            }

            it("denies an ordinary metered cache_only record with no balance") {
                let payload: [String: AnyCodable] = [
                    "gate": AnyCodable([
                        "decision": "require_feature",
                        "featureId": "exports",
                        "requiredBalance": 2,
                        "policy": "cache_only"
                    ])
                ]
                mockEventLog.trackWithResponseResult = EventResponse(
                    status: "ok",
                    payload: payload,
                    customer: nil,
                    eventId: "event-ordinary-deny",
                    message: nil,
                    featuresMatched: nil,
                    usage: nil,
                    journey: nil
                )
                let info = featureInfo!
                await MainActor.run {
                    info.update([
                        "exports": FeatureAccess(
                            allowed: true,
                            unlimited: false,
                            balance: nil,
                            type: .metered
                        )
                    ])
                }

                let updates = TriggerUpdateRecorder()
                await triggerService.trigger("test_event") { updates.append($0) }

                expect(updates.values).to(contain(.featureAccess(.denied)))
            }

            it("emits feature access denied for cache_only gate plan without access") {
                let payload: [String: AnyCodable] = [
                    "gate": AnyCodable([
                        "decision": "require_feature",
                        "featureId": "pro",
                        "policy": "cache_only"
                    ])
                ]
                mockEventLog.trackWithResponseResult = EventResponse(
                    status: "ok",
                    payload: payload,
                    customer: nil,
                    eventId: "event-3",
                    message: nil,
                    featuresMatched: nil,
                    usage: nil,
                    journey: nil,
                )

                let updates = TriggerUpdateRecorder()

                await triggerService.trigger("test_event") { update in
                    updates.append(update)
                }

                expect(updates.values).to(contain(.featureAccess(.denied)))
            }
        }
    }
}


/// Lock-guarded recorder for @Sendable trigger-update handlers.
// @unchecked Sendable: `_values` is only accessed under `lock`.
private final class TriggerUpdateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [TriggerUpdate] = []

    func append(_ update: TriggerUpdate) {
        lock.withLock { _values.append(update) }
    }

    var values: [TriggerUpdate] {
        lock.withLock { _values }
    }

    var errorCodes: [TriggerError.Code] {
        values.compactMap { update in
            guard case .error(let error) = update else { return nil }
            return error.code
        }
    }
}
